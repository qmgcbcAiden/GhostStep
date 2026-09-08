-- threat/spatial.lua
-- 空间分桶哈希（auto_dodge_helper 最佳实践#2）
-- O(n) 建桶 → O(1) 平均查询。弹幕多时性能关键（原则4）

local Spatial = {}

local CELL_SIZE = 80 -- 分桶格子边长（像素）

--- 构建空间分桶
--- hazards: {{ pos, vel, speed, radius, kind? }} 追踪器活跃弹幕的浅拷贝
--- 返回: { cellSize, buckets = {[bx] = {[by] = {entity...}}}, all = hazards }
function Spatial.build(hazards, predictedRadius)
    local buckets = {}
    local r = predictedRadius or CELL_SIZE -- 预测半径内的格子都登记

    for i = 1, #hazards do
        local h = hazards[i]
        local pos = h.pos
        local bx = math.floor(pos.X / CELL_SIZE)
        local by = math.floor(pos.Y / CELL_SIZE)
        local col = buckets[bx]
        if not col then
            col = {}
            buckets[bx] = col
        end
        local bucket = col[by]
        if not bucket then
            bucket = {}
            col[by] = bucket
        end
        bucket[#bucket + 1] = h
    end

    return {
        cellSize = CELL_SIZE,
        buckets = buckets,
        all = hazards,
    }
end

--- 查询点周围（含自身与8邻域）的所有弹幕
--- 返回数组（可能是复用缓冲，调用方只读，不要跨帧持有）
local queryResult = {}
function Spatial.queryNear(grid, pos)
    -- 清空复用缓冲
    for i = #queryResult, 1, -1 do queryResult[i] = nil end

    local bx = math.floor(pos.X / CELL_SIZE)
    local by = math.floor(pos.Y / CELL_SIZE)
    for dx = -1, 1 do
        local col = grid.buckets[bx + dx]
        if col then
            for dy = -1, 1 do
                local bucket = col[by + dy]
                if bucket then
                    for i = 1, #bucket do
                        queryResult[#queryResult + 1] = bucket[i]
                    end
                end
            end
        end
    end
    return queryResult
end

return Spatial
