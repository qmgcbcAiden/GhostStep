-- JSONL 有界队列。帧内缓冲写入，不强制 fflush；慢 I/O 暂停本局文件输出。
local Recorder={}
local okJson,json=pcall(require,"json")
local encode=okJson and json.encode or require("utils/json_encode")
local sep=package.config and package.config:sub(1,1) or '/'
local function rootDir()
    if not io or not io.open or not debug or not debug.getinfo then return nil end
    local source=debug.getinfo(1,'S').source
    local dir=source:match('^@(.*)[/\\][^/\\]+$')
    for _=1,5 do
        if not dir then return nil end
        local f=io.open(dir..sep..'metadata.xml','r')
        if f then f:close(); return dir end
        dir=dir:match('^(.*)[/\\][^/\\]+$')
    end
end
function Recorder.create(config)
    local dir=rootDir()
    return setmetatable({available=dir~=nil,dir=dir,lines={},lineCount=0,queuedBytes=0,totalFrames=0,
        totalBytes=0,dropped=0,sequence=0,config=config or {},encoder=encode,framesSinceFlush=0},{__index=Recorder})
end
function Recorder.unavailableReason(self)
    return self.lastError or "需 --luadebug 和可写的 recordings 目录；当前保留内存回放"
end
function Recorder.fail(self,reason)
    self.failed=true; self.lastError=tostring(reason)
    Isaac.DebugString('[GhostStep3] 录制已停止: '..self.lastError..'；待写队列已保留，文件尾部可能不完整')
    return false
end
function Recorder.startSession(self,seed,meta)
    if not self.available then return false end
    self:closeFile()
    local dir=self.dir..sep..'recordings'
    local stamp=os and os.date and os.date('%Y%m%d_%H%M%S') or 'session'
    local safeSeed=tostring(seed or ''):gsub('[^%w]','')
    self.sessionIndex=(self.sessionIndex or 0)+1
    local path=dir..sep..'session_'..stamp..'_'..safeSeed..'_'..tostring(Isaac.GetTime())..'_'..self.sessionIndex..'.jsonl'
    local ok,file,err=pcall(io.open,path,'a')
    -- 优先直接打开；目录存在时不启动 shell（开新局不应重复 mkdir）。
    if not ok or not file then
        local mkdir
        if sep=='\\' then mkdir='md "'..dir:gsub('"','')..'" >nul 2>&1'
        else mkdir="mkdir -p '"..dir:gsub("'","'\\''").."'" end
        if os and os.execute then pcall(os.execute,mkdir) end
        ok,file,err=pcall(io.open,path,'a')
    end
    if not ok or not file then return self:fail(err or file or 'open failed') end
    self.file,self.filePath=file,path
    self.lines,self.lineCount,self.queuedBytes={},0,0
    self.recent={}; self.recentFirst=1; self.recentLast=0
    self.failed,self.lastError=false,nil
    self.ioPaused,self.lastWriteMs,self.maxWriteMs=false,0,0
    if file.setvbuf then pcall(file.setvbuf,file,"full",65536) end
    self.sequence,self.totalFrames,self.totalBytes,self.dropped=0,0,0,0
    local fields={ev='session_start',seed=tostring(seed or ''),schemaVersion=2,
        clock='Isaac.GetTime',clockResolutionMs=1}
    for k,v in pairs(meta or {}) do fields[k]=v end
    self:event(fields)
    return self:flush()
end
local function evictRecent(self)
    local first=self.recentFirst or 1
    local line=self.recent and self.recent[first]
    if not line then return false end
    self.queuedBytes=self.queuedBytes-#line-1
    self.recent[first]=nil; self.recentFirst=first+1
    self.dropped=self.dropped+1
    return true
end
function Recorder.writeLine(self,line,critical)
    if not self.file or self.failed then return false end
    local max=self.config.recorderMaxBytes or 1048576
    local size=#line+1
    local reserve=math.min(65536,math.floor(max*0.1))
    local limit=critical and max or max-reserve
    local maxLine=self.config.recorderMaxLineBytes or 32768
    -- 暂停 I/O 时滚动保留最新快照，关键事件留在主队列，避免只剩开局数据。
    if self.ioPaused and size<=maxLine then
        while self.queuedBytes+size>limit and evictRecent(self) do end
    end
    if size>maxLine or self.queuedBytes+size>limit then
        self.dropped=self.dropped+1
        if critical then self.lastError='queue_overflow: important event omitted' end
        return false
    end
    if self.ioPaused and not critical then
        self.recent=self.recent or {}; self.recentFirst=self.recentFirst or 1
        self.recentLast=(self.recentLast or 0)+1; self.recent[self.recentLast]=line
    else
        self.lineCount=self.lineCount+1; self.lines[self.lineCount]=line
    end
    self.queuedBytes=self.queuedBytes+size
    return true
end
function Recorder.flush(self,maxBytes,buffered)
    if self.failed then return false end
    if not self.file or self.lineCount==0 then return true end
    local count,bytes=0,0
    local limit=maxBytes or self.config.recorderBatchBytes or 32768
    for i=1,self.lineCount do
        if i>1 and bytes+#self.lines[i]+1>limit then break end
        count=i; bytes=bytes+#self.lines[i]+1
    end
    local payload=table.concat(self.lines,'\n',1,count)..'\n'
    local ok,res,err=pcall(self.file.write,self.file,payload)
    if not ok or res==nil or res==false then return self:fail(err or res or 'write failed') end
    if not buffered then
        local fok,fres,ferr=pcall(self.file.flush,self.file)
        if not fok or fres==nil or fres==false then return self:fail(ferr or fres or 'flush failed') end
    end
    for i=count+1,self.lineCount do self.lines[i-count]=self.lines[i] end
    for i=self.lineCount-count+1,self.lineCount do self.lines[i]=nil end
    self.lineCount=self.lineCount-count; self.queuedBytes=self.queuedBytes-bytes
    self.totalBytes=self.totalBytes+bytes
    return true
end
function Recorder.encode(self,obj,jsonEncoder)
    self.sequence=self.sequence+1
    obj.seq=self.sequence; obj.schemaVersion=2
    local ok,line=pcall(jsonEncoder or self.encoder,obj)
    if not ok or type(line)~='string' then self.dropped=self.dropped+1; self.lastError='encode failed'; return nil end
    return line
end
function Recorder.push(self,snapshot,jsonEncoder)
    self.totalFrames=self.totalFrames+1
    local line=self:encode(snapshot,jsonEncoder)
    if line then self:writeLine(line,false) end
    return line -- 同一不可变字符串供事件前后文缓存复用。
end
function Recorder.event(self,fields)
    if not self.file then return false end
    fields.frame=fields.frame or self.frame
    fields.tick=fields.tick or self.tick
    fields.decisionId=fields.decisionId or self.tick
    local line=self:encode(fields)
    return line and self:writeLine(line,true) or false
end
function Recorder.eventJson(self,obj,jsonEncoder) return self:event(obj) end
function Recorder.context(self,eventId,line)
    -- line 已由同一编码器产生；封套仅含受控的整数及字段名。
    self.sequence=self.sequence+1
    return self:writeLine('{"ev":"context","schemaVersion":2,"seq":'..self.sequence..',"eventId":'..eventId..',"snapshot":'..line..'}',false)
end
function Recorder.tickWriter(self)
    self.lastWriteMs=0
    if self.ioPaused or self.failed or self.lineCount==0 then return end
    local begin=Isaac.GetTime()
    local ok=self:flush(self.config.recorderBatchBytes or 32768,true)
    self.lastWriteMs=Isaac.GetTime()-begin
    self.maxWriteMs=math.max(self.maxWriteMs or 0,self.lastWriteMs)
    if ok and self.lastWriteMs>(self.config.recorderSlowWriteMs or 8) then
        -- 同步 I/O 无法在调用中打断；第一次慢写后停止后续写盘，不在战斗中重试。
        self.ioPaused=true
        self:event({ev="recording_io_paused",writeMs=self.lastWriteMs})
        Isaac.DebugString('[GhostStep3] 文件写入耗时 '..self.lastWriteMs..'ms，已暂停本局文件输出；内存回放继续，重新开关录制可恢复')
    end
end
function Recorder.closeFile(self)
    if not self.file then return end
    for i=self.recentFirst or 1,self.recentLast or 0 do
        self.lineCount=self.lineCount+1; self.lines[self.lineCount]=self.recent[i]
    end
    self.recent={};self.recentFirst=1;self.recentLast=0
    -- 仅关闭文件时合并关键事件与保留快照，按原 seq 排序，帧内不排序、不写盘。
    table.sort(self.lines,function(a,b)
        return (tonumber(a:match('"seq"%s*:%s*(%d+)')) or 0)<(tonumber(b:match('"seq"%s*:%s*(%d+)')) or 0)
    end)
    while self.lineCount>0 and not self.failed do self:flush() end
    pcall(self.file.close,self.file); self.file=nil
end
function Recorder.statusText(self)
    if self.ioPaused then return '文件输出: 慢写盘已暂停，内存回放继续；丢弃 '..self.dropped end
    if self.lastError then return '文件输出: '..self.lastError..' 丢弃 '..self.dropped end
    if not self.available then return '文件输出: '..self:unavailableReason() end
    return self.file and ('录制 '..self.totalFrames..' 帧，队列 '..self.queuedBytes..' 字节，丢弃 '..self.dropped) or '文件输出: 就绪'
end
return Recorder
