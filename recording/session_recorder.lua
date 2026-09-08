-- recording/session_recorder.lua
-- 可选持久化录制：写 JSONL 独立文件（Phase 4 提前实装，用户点名要文件输出）
--
-- 关键约束: Isaac 的 Lua 沙箱默认没有 io/debug 库——写文件必须用 --luadebug 启动游戏
--   (Steam → 以撒 → 属性 → 启动选项填 --luadebug)
-- 降级策略: io 不可用时静默退回纯内存环形缓冲（现状），MCM 录制页会显示原因
--
-- 输出: <mod根>/recordings/session_<时间戳>_<种子>.jsonl
--   mod根 = 从脚本位置向上找到 metadata.xml 的目录（不硬编码任何机器路径）
--   recordings/ 为录制数据专属目录，与代码目录完全隔离；建不出来时退回内存模式
--   每帧一行 JSON（Snapshot.capture 的平铺表）
--   事件行: {"ev":"hit"/"death"/"room"/"session_start", ...}
--
-- 文件写入模式参考 auto_dodge_helper 的 diag export（io nil 检测 + debug.getinfo 定位
-- mod 目录），为已验证的社区实践

local SessionRecorder = {}

local FLUSH_EVERY = 150 -- 每150帧(5秒)刷盘；事件立即刷

--- 检测 io/debug 可用性（沙箱内为 nil，访问 nil 全局不报错）
local function ioAvailable()
    local ok, res = pcall(function()
        return type(io) == "table" and type(io.open) == "function"
    end)
    return ok and res
end

--- 定位脚本自身目录（--luadebug 下 debug.getinfo 的 source 是 @绝对路径）
local function scriptDirectory()
    local ok, info = pcall(function() return debug.getinfo(1, "S") end)
    if not ok or info == nil or info.source == nil then return nil end
    local source = info.source
    if string.sub(source, 1, 1) ~= "@" then return nil end
    return string.match(string.sub(source, 2), "^(.*)[/\\][^/\\]+$")
end

--- 从脚本目录向上找 metadata.xml（每个 Isaac mod 根目录必有），定位 mod 根
--- 最多向上 4 层，兼容未来脚本层级调整；找不到返回 nil（退回内存模式）
local function modRootDirectory()
    local dir = scriptDirectory()
    for _ = 1, 4 do
        if dir == nil then return nil end
        local okOpen, f = pcall(io.open, dir .. "\\metadata.xml", "r")
        if okOpen and f ~= nil then
            f:close()
            return dir
        end
        dir = string.match(dir, "^(.*)[/\\][^/\\]+$")
    end
    return nil
end

--- 确保目录存在（Lua 无 mkdir，借 os.execute 调系统命令；已存在时静默）
local function ensureDirectory(path)
    return pcall(function()
        os.execute('md "' .. path .. '" >nul 2>&1')
    end)
end

--- 创建实例
function SessionRecorder.create()
    local self = {
        available = ioAvailable(),
        file = nil,          -- 打开的文件句柄
        filePath = nil,      -- 当前文件路径（MCM 展示用）
        lines = {},          -- 待写缓冲
        lineCount = 0,
        framesSinceFlush = 0,
        totalFrames = 0,
        dir = nil,
    }
    if self.available then
        self.dir = modRootDirectory()
        if self.dir == nil then
            self.available = false
        end
    end
    return setmetatable(self, { __index = SessionRecorder })
end

--- 不可用原因（MCM 展示）
function SessionRecorder.unavailableReason(self)
    return "不可用 — 需用 --luadebug 启动游戏 (Steam→属性→启动选项)"
end

--- 开始一个新录制会话（每局一个文件）
function SessionRecorder.startSession(self, seedString)
    if not self.available then return false end
    self:closeFile()

    local stamp = "s"
    local okT, res = pcall(function() return os.date("%Y%m%d_%H%M%S") end)
    if okT and type(res) == "string" then stamp = res end
    local safeSeed = string.gsub(tostring(seedString or ""), "[^%w]", "")

    -- 专属数据目录 <mod根>/recordings/，与代码目录隔离；
    -- 目录建不出来或不可写 → 退回内存模式，绝不写入代码所在目录
    local recordingsDir = self.dir .. "\\recordings"
    ensureDirectory(recordingsDir)
    local path = recordingsDir .. "\\session_" .. stamp .. "_" .. safeSeed .. ".jsonl"
    local okOpen, file = pcall(io.open, path, "a")
    if okOpen and file ~= nil then
        self.file = file
        self.filePath = path
        self.lines = {}
        self.lineCount = 0
        self.framesSinceFlush = 0
        self.totalFrames = 0
        self:writeLine('{"ev":"session_start","seed":"' .. tostring(seedString or "") .. '"}')
        self:flush()
        Isaac.DebugString("[GhostStep3] 录制文件: " .. path)
        return true
    end
    self.available = false
    Isaac.DebugString("[GhostStep3] 录制目录不可用: " .. recordingsDir .. "，退回内存模式")
    return false
end

--- 写一行（暂存缓冲）
function SessionRecorder.writeLine(self, line)
    if not self.file then return end
    self.lineCount = self.lineCount + 1
    self.lines[self.lineCount] = line
end

--- 刷盘
function SessionRecorder.flush(self)
    if not self.file or self.lineCount == 0 then return true end
    for i = 1, self.lineCount do
        pcall(function() self.file:write(self.lines[i], "\n") end)
    end
    pcall(function() self.file:flush() end)
    self.lines = {}
    self.lineCount = 0
    self.framesSinceFlush = 0
    return true
end

--- 压入一帧快照（snapshot 为平铺表，jsonEncoder = json.encode）
function SessionRecorder.push(self, snapshot, jsonEncoder)
    if not self.file then return end
    self.totalFrames = self.totalFrames + 1
    self.framesSinceFlush = self.framesSinceFlush + 1
    local ok, line = pcall(jsonEncoder, snapshot)
    if ok and type(line) == "string" then
        self:writeLine(line)
    end
    if self.framesSinceFlush >= FLUSH_EVERY then
        self:flush()
    end
end

--- 记录事件（hit/death/room），立即刷盘
function SessionRecorder.event(self, fields)
    if not self.file then return end
    local parts = {}
    for k, v in pairs(fields or {}) do
        if type(v) == "number" then
            parts[#parts + 1] = '"' .. k .. '":' .. string.format("%.2f", v)
        else
            parts[#parts + 1] = '"' .. k .. '":"' .. tostring(v) .. '"'
        end
    end
    self:writeLine('{' .. table.concat(parts, ",") .. "}")
    self:flush()
end

--- 关闭文件
function SessionRecorder.closeFile(self)
    if self.file then
        self:flush()
        pcall(function() self.file:close() end)
        self.file = nil
    end
end

--- 状态摘要（MCM 录制/调试页）
function SessionRecorder.statusText(self)
    if not self.available then
        return "文件输出: " .. self:unavailableReason()
    end
    if self.file then
        return "文件输出: 录制中 " .. self.totalFrames .. " 帧"
    end
    return "文件输出: 就绪（进入对局后创建文件）"
end

return SessionRecorder
