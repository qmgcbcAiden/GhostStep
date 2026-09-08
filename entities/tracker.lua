-- entities/tracker.lua
-- 跨帧实体追踪器（SocketBridge 模式3：按 entity.Index 追踪、按类型过期、历史环形缓冲）
-- 没有跨帧追踪就无法预测弹幕轨迹；历史缓冲直接支持弧线预测（Phase 2 三点圆拟合）

local Tracker = {}

local HISTORY_MAX = 10 -- 每实体历史条数上限

-- 按类型配置过期帧数（弹幕移动极快，短暂未见即过期）
local EXPIRY = {
    projectile = 5,
    enemy = 10,
    pickup = 30,
}

--- 创建追踪器实例（方法通过模块元表挂载，实例:method() 可用）
function Tracker.create()
    local self = {
        tracked = {},  -- [entity.Index] = { pos, vel, speed, radius, firstFrame, lastFrame, history }
        count = 0,
    }
    return setmetatable(self, { __index = Tracker })
end

local function newEntry(entry, frame)
    -- 全字段复制（pos/vel 之外 sensors 提供的 damage/fuseFrames/endPos/angle/kind 等都要带上）
    local t = {}
    for k, v in pairs(entry) do
        if k ~= "index" then t[k] = v end
    end
    t.firstFrame = frame
    t.lastFrame = frame
    t.historyCount = 1
    -- 历史环形缓冲：定长数组复用，避免 table.remove 的 O(n) 与 GC 压力
    t.history = { { pos = entry.pos, vel = entry.vel, frame = frame } }
    t.historyHead = 2 -- 初始条目在 slot 1，下一条写入 slot 2
    return t
end

--- 用当帧实体列表更新追踪器。entries: {{index, pos, vel, speed, radius, kind}}
function Tracker.update(self, entries, frame, expiryKind)
    local expiry = EXPIRY[expiryKind] or 10
    local tracked = self.tracked
    local seen = {}

    for i = 1, #entries do
        local e = entries[i]
        local t = tracked[e.index]
        seen[e.index] = true
        if t then
            -- 已追踪：同步全部数据字段（pos/vel 之外的 kind/damage/endPos/angle 等每帧可变），
            -- 再追加历史
            for k, v in pairs(e) do
                if k ~= "index" then t[k] = v end
            end
            t.lastFrame = frame
            local head = t.historyHead
            local slot = t.history[head]
            if slot then
                slot.pos = e.pos
                slot.vel = e.vel
                slot.frame = frame
            else
                t.history[head] = { pos = e.pos, vel = e.vel, frame = frame }
            end
            t.historyHead = head % HISTORY_MAX + 1
            if t.historyCount < HISTORY_MAX then t.historyCount = t.historyCount + 1 end
        else
            tracked[e.index] = newEntry(e, frame)
            self.count = self.count + 1
        end
    end

    -- 过期清理：帧数未见的实体移除
    for index, t in pairs(tracked) do
        if not seen[index] and (frame - t.lastFrame) > expiry then
            tracked[index] = nil
            self.count = self.count - 1
        end
    end
end

--- 获取一个实体的历史（旧→新）。返回数组（调用方只读）
function Tracker.getHistory(self, index)
    local t = self.tracked[index]
    if not t or t.historyCount == 0 then return nil end
    local ordered = {}
    local n = t.historyCount
    for i = 1, n do
        local idx
        if n < HISTORY_MAX then
            idx = i -- 未满：按写入顺序 1..n
        else
            -- 已满：head 是最旧（即将被覆盖）的位置
            idx = (t.historyHead + i - 2) % HISTORY_MAX + 1
        end
        ordered[#ordered + 1] = t.history[idx]
    end
    return ordered
end

--- 实体新鲜度：距上次见过了几帧；不存在返回 nil
function Tracker.getStaleness(self, index, frame)
    local t = self.tracked[index]
    if not t then return nil end
    return frame - t.lastFrame
end

--- 清空
function Tracker.clear(self)
    self.tracked = {}
    self.count = 0
end

--- 获取 N 帧内见过的活跃实体（用于决策时的宽容读取）
function Tracker.getActive(self, maxStale, frame)
    local result = {}
    for _, t in pairs(self.tracked) do
        if (frame - t.lastFrame) <= maxStale then
            result[#result + 1] = t
        end
    end
    return result
end

return Tracker
