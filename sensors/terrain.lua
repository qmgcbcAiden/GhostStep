-- sensors/terrain.lua
-- 地形网格：房间进入时缓存格子级通行性/危险类型
-- 含飞行角色规则（7.5.3）与特殊格子检测（7.5.4：地刺/TNT）
-- 结构: Grid[sizeX*sizeY] = { walkable, dangerType } dangerType: nil|"spike"|"tnt"

local Terrain = {}

local CELL = 40 -- Isaac 格子边长（像素）

local GridEntityType = GridEntityType
local GridCollisionClass = GridCollisionClass

--- 地刺格子类型
local SPIKE_TYPES = {
    [GridEntityType.GRID_SPIKES] = true,
    [GridEntityType.GRID_SPIKES_ONOFF] = true,
    [GridEntityType.GRID_ROCK_SPIKED] = true,
    [GridEntityType.GRID_SPIDERWEB] = false, -- 占位：web 不危险
}

--- 通行性检查 — 飞行角色规则不同（7.5.3）
local function isWalkable(collision, canFly)
    if canFly then
        return collision ~= GridCollisionClass.COLLISION_SOLID
           and collision ~= GridCollisionClass.COLLISION_WALL
    end
    return collision ~= GridCollisionClass.COLLISION_OBJECT
       and collision ~= GridCollisionClass.COLLISION_SOLID
       and collision ~= GridCollisionClass.COLLISION_WALL
       and collision ~= GridCollisionClass.COLLISION_PIT
end

--- 地刺危险性（7.5.4）：可伸缩地刺 state==0 为伸出（危险）
local function isSpikeDangerous(gridType, state, collision)
    if gridType == GridEntityType.GRID_ROCK_SPIKED then
        return collision ~= GridCollisionClass.COLLISION_NONE
    end
    if gridType == GridEntityType.GRID_SPIKES
        or gridType == GridEntityType.GRID_SPIKES_ONOFF then
        return (state or 0) == 0
    end
    return false
end

--- TNT 装弹检测（7.5.4）：State>1 或 VarData>0 → 已装弹
local function isArmedTnt(grid)
    if not grid then return false end
    return (grid.State or 0) > 1 or (grid.VarData or 0) > 0
end

function Terrain.create()
    local self = {
        valid = false,
        roomIndex = -1,
        sizeX = 0,
        sizeY = 0,
        topLeft = nil,   -- 房间左上角世界坐标（像素）
        grid = {},       -- [y*sizeX+x+1] = { walkable=bool, danger=nil|"spike"|"tnt" }
    }
    return setmetatable(self, { __index = Terrain })
end

--- 重建地形缓存。canFly 由玩家状态决定；房间数据无效时返回 false
function Terrain.build(self, room, canFly, config)
    if not room then return false end -- 过渡期房间无效（模式6：延迟提交）

    -- Isaac API: GetGridSize() 返回格子总数(单值)，GetGridWidth() 返回宽
    local total = room:GetGridSize()
    local sizeX = room:GetGridWidth()
    if not total or not sizeX or sizeX <= 0 then return false end
    local sizeY = math.floor(total / sizeX)
    if sizeY <= 0 then return false end

    local cfg = config
    local grid = {}
    for y = 0, sizeY - 1 do
        for x = 0, sizeX - 1 do
            local gi = y * sizeX + x + 1
            local g = room:GetGridEntity(x, y)
            local walkable = true
            local danger = nil
            if g then
                local collision = g.Collision
                walkable = isWalkable(collision, canFly)
                local gtype = g.Type
                -- 地刺：飞行角色完全豁免（7.5.3）
                if cfg.hazardSpikes and SPIKE_TYPES[gtype] and not canFly then
                    if isSpikeDangerous(gtype, g.State, collision) then
                        danger = "spike"
                    end
                end
                -- TNT
                if cfg.hazardTnt and gtype == GridEntityType.GRID_TNT then
                    if isArmedTnt(g) then
                        danger = "tnt"
                        walkable = false
                    end
                end
            end
            grid[gi] = { walkable = walkable, danger = danger }
        end
    end

    self.grid = grid
    self.sizeX = sizeX
    self.sizeY = sizeY
    self.topLeft = room:GetGridPosition(0) - Vector(CELL / 2, CELL / 2)
    self.roomIndex = Game():GetLevel():GetCurrentRoomIndex()
    self.valid = true
    return true
end

--- 世界坐标 → 格子下标（1-based），越界返回 nil
function Terrain.cellAt(self, worldPos)
    if not self.valid then return nil end
    local rel = worldPos - self.topLeft
    local x = math.floor(rel.X / CELL)
    local y = math.floor(rel.Y / CELL)
    if x < 0 or y < 0 or x >= self.sizeX or y >= self.sizeY then return nil end
    return y * self.sizeX + x + 1
end

--- 格子中心世界坐标
function Terrain.cellCenter(self, cx, cy)
    return self.topLeft + Vector(cx * CELL + CELL / 2, cy * CELL + CELL / 2)
end

--- 通行性查询
function Terrain.isWalkableAt(self, worldPos)
    local idx = Terrain.cellAt(self, worldPos)
    if not idx then return true end -- 房间外默认可通行（由调用方处理墙壁）
    local cell = self.grid[idx]
    return cell and cell.walkable or true
end

--- 危险格子查询
function Terrain.dangerAt(self, worldPos)
    local idx = Terrain.cellAt(self, worldPos)
    if not idx then return nil end
    local cell = self.grid[idx]
    return cell and cell.danger or nil
end

--- 距最近墙壁距离（像素）。用向外射线步进估算，用于墙角检测（原则5）
function Terrain.distanceToWall(self, pos, dir)
    if not self.valid then return 9999 end
    local step = 20
    local dist = 0
    local maxDist = 400
    while dist < maxDist do
        dist = dist + step
        local probe = pos + dir * dist
        if not Terrain.isWalkableAt(self, probe) then
            return dist - step / 2
        end
    end
    return maxDist
end

--- 四方向最小墙壁距离（格子墙壁 + 房间边界）
function Terrain.minWallDistance(self, pos)
    local dirs = { Vector(1, 0), Vector(-1, 0), Vector(0, 1), Vector(0, -1) }
    local min = 9999
    for i = 1, 4 do
        local d = Terrain.distanceToWall(self, pos, dirs[i])
        if d < min then min = d end
    end
    -- 房间边界距离（Isaac 的不可见外墙，格子墙壁检测不到）
    -- 这是卡墙问题的根源：格子墙壁检测返回最大值，但玩家实际贴着房间边界
    local ok, room = pcall(function() return Game():GetRoom() end)
    if ok and room then
        local okTL, tl = pcall(function() return room:GetTopLeftPos() end)
        local okBR, br = pcall(function() return room:GetBottomRightPos() end)
        if okTL and tl and okBR and br then
            local margin = 20 -- 房间内边距（边缘区域有碰撞但不是格子）
            local distL = pos.X - tl.X - margin
            local distR = br.X - pos.X - margin
            local distT = pos.Y - tl.Y - margin
            local distB = br.Y - pos.Y - margin
            local boundaryMin = math.min(distL, distR, distT, distB)
            if boundaryMin < min then min = boundaryMin end
        end
    end
    return min
end

--- 失效缓存
function Terrain.invalidate(self)
    self.valid = false
end

return Terrain
