-- recording/ring_buffer.lua
-- 录制环形缓冲（SocketBridge 模式8 + 7.5.7 表池复用防 GC）
-- 内存中保留最近 N 秒帧快照，供死亡回放与离线分析

local RingBuffer = {}

--- 表池：预分配复用，避免每帧新建表产生 GC 压力（7.5.7）
local function createPool()
    local pool = { free = {} }
    function pool:acquire()
        return table.remove(self.free) or {}
    end
    function pool:release(t)
        for k in pairs(t) do t[k] = nil end
        self.free[#self.free + 1] = t
    end
    return pool
end

--- 创建环形缓冲（方法通过模块元表挂载）
--- capacity: 快照条数（如 30fps × 30秒 = 900）
function RingBuffer.create(capacity)
    local pool = createPool()
    local self = {
        data = {},
        maxSize = capacity,
        head = 1,
        count = 0,
        _pool = pool,
    }
    return setmetatable(self, { __index = RingBuffer })
end

--- 压入帧快照。snapshot: 平铺 key-value 表（浅拷贝值）
function RingBuffer.push(self, snapshot)
    -- 满了：最旧条目回池
    if self.count >= self.maxSize then
        local old = self.data[self.head]
        if old then self._pool:release(old) end
    end
    local snap = self._pool:acquire()
    for k, v in pairs(snapshot) do
        snap[k] = v
    end
    self.data[self.head] = snap
    self.head = (self.head % self.maxSize) + 1
    if self.count < self.maxSize then self.count = self.count + 1 end
end

--- 取最近 n 条（旧→新）。返回新数组（浅引用快照表，只读）
function RingBuffer.getRecent(self, n)
    local result = {}
    local take = math.min(n, self.count)
    local start = ((self.head - 1 - take) % self.maxSize) + 1
    for i = 0, take - 1 do
        local idx = ((start - 1 + i) % self.maxSize) + 1
        result[#result + 1] = self.data[idx]
    end
    return result
end

--- 按帧号查找
function RingBuffer.getFrame(self, targetFrame)
    for i = 1, self.count do
        local snap = self.data[i]
        if snap and snap.frame == targetFrame then return snap end
    end
    return nil
end

--- 清空（房间切换可选保留；回放输出后可清）
function RingBuffer.clear(self)
    for i = 1, self.maxSize do
        if self.data[i] then
            self._pool:release(self.data[i])
            self.data[i] = nil
        end
    end
    self.head = 1
    self.count = 0
end

return RingBuffer
