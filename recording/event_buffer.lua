-- 编码后的不可变快照环。前后文真实预采集；重叠触发合并，每帧最多转交两个快照。
local Events={}
function Events.create(config)
    return setmetatable({config=config,ring={},head=1,count=0,bytes=0,id=0,dropped=0,seq=0},{__index=Events})
end
function Events.record(self,line,frame)
    if not self.config.eventRecording or not line then return end
    local maxBytes=self.config.eventMaxBytes or 2097152
    local capacity=(self.config.eventPreFrames or 60)+(self.config.eventPostFrames or 30)+1
    if #line>maxBytes then self.dropped=self.dropped+1; return end
    while self.count>0 and (self.bytes+#line>maxBytes or self.count>=capacity) do
        local old=self.ring[self.head]
        self.bytes=self.bytes-#old.line; self.ring[self.head]=nil
        self.head=self.head+1; self.count=self.count-1
        if self.nextExport and self.nextExport<self.head then self.dropped=self.dropped+1; self.nextExport=self.head end
    end
    self.ring[self.head+self.count]={line=line,frame=frame}
    self.count=self.count+1; self.bytes=self.bytes+#line
    -- 定期归整，索引不会无限增大。
    if self.head>4096 then
        local compact={}
        for i=0,self.count-1 do compact[i+1]=self.ring[self.head+i] end
        if self.nextExport then self.nextExport=self.nextExport-self.head+1 end
        self.ring,self.head=compact,1
    end
end
function Events.trigger(self,reason,frame,recorder)
    if not self.config.eventRecording then return end
    if not self.nextExport then
        self.id=self.id+1
        self.nextExport=self.head
        local cutoff=frame-(self.config.eventPreFrames or 60)
        while self.nextExport<self.head+self.count and self.ring[self.nextExport].frame<cutoff do self.nextExport=self.nextExport+1 end
    end
    self.untilFrame=frame+(self.config.eventPostFrames or 30)
    recorder:event({ev='diagnostic_trigger',reason=reason,eventId=self.id,frame=frame,preDetail=4,droppedContext=self.dropped})
end
function Events.drain(self,frame,recorder)
    if not self.nextExport then return end
    for _=1,2 do
        local item=self.ring[self.nextExport]
        if not item then break end
        if item.frame>self.untilFrame then self.nextExport=nil; break end
        if not recorder:context(self.id,item.line) then self.dropped=self.dropped+1 end
        self.nextExport=self.nextExport+1
    end
    if self.nextExport and frame>self.untilFrame and self.nextExport>=self.head+self.count then self.nextExport=nil end
end
function Events.reset(self)
    self.ring,self.head,self.count,self.bytes={},1,0,0
    self.nextExport,self.untilFrame=nil,nil
end
return Events
