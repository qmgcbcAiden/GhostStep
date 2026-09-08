-- threat/hazard_query.lua
-- 空间危险查询：组合所有威胁类型，按 kind 路由碰撞检测
-- Phase 1: 弹幕/敌人 (闭式解 + 弧线解)
-- Phase 3: 激光 (线段距离), 炸弹 (圆碰撞), 效果 (圆碰撞)
-- 3.5 接线版: 弹幕闭式解后做墙壁抽查截断（墙后虚假危险区消除）
-- 激光真几何: 起点→终点线段，旋转激光按 rotSpd 外推未来扫掠线段
--
-- 原则: Spatial 空间分桶对所有 kind 通用（pos 是圆心，查询半径足够大即行）
-- 不同 kind 的碰撞几何在 firstCollision 中路由

local HazardQuery = {}

local Spatial = require("threat/spatial")
local Predict = require("threat/projectile_predict")
local FutureMotion = require("threat/future_motion")

-- atan2 兼容: Lua 5.1 有 math.atan2，5.3 合并进 math.atan(y,x)
local atan2 = math.atan2 or function(y, x) return math.atan(y, x) end

function HazardQuery.create()
    local self = {
        grid = nil,
    }
    return setmetatable(self, { __index = HazardQuery })
end

--- 每帧更新空间分桶
function HazardQuery.update(self, hazards)
    self.grid = Spatial.build(hazards)
end

--- 查询 pos 附近弹幕（复用缓冲，只读）
function HazardQuery.near(self, pos)
    if not self.grid then return {} end
    return Spatial.queryNear(self.grid, pos)
end

--- 点到线段最短距离（激光碰撞核心）
local function pointSegmentDistanceSq(px, py, ax, ay, bx, by)
    local dx, dy = bx - ax, by - ay
    local lenSq = dx * dx + dy * dy
    if lenSq < 0.01 then
        -- 退化为点
        local ex, ey = px - ax, py - ay
        return ex * ex + ey * ey
    end
    -- 投影参数 t = clamp(dot(ap, ab) / |ab|^2, 0, 1)
    local apx, apy = px - ax, py - ay
    local t = (apx * dx + apy * dy) / lenSq
    if t < 0 then t = 0 elseif t > 1 then t = 1 end
    local cx, cy = ax + t * dx, ay + t * dy
    local ex, ey = px - cx, py - cy
    return ex * ex + ey * ey
end

--- t 帧后的激光线段（移动+旋转外推）
--- 静止激光: 起点→终点；旋转激光: 终点绕起点按 rotSpd*t 度旋转；
--- 数据完全缺失（无 endPos 无 length）时退化为 pos→pos+vel 线段
--- （vel 短≈点碰撞，vel 长≈终点偏移，兼容几何数据读不到的激光）
--- 共用 future_motion.laserSegmentAt，避免代码重复
local function laserSegmentAt(entry, t)
    return FutureMotion.laserSegmentAt(entry, t)
end

--- 激光命中帧：步进 2 帧检查玩家未来位置到激光线段的距离
local function timeToHitLaser(entry, playerPos, playerVel, playerRadius, horizon)
    local combined = entry.radius + playerRadius
    local combinedSq = combined * combined
    for t = 0, horizon, 2 do
        local a, b = laserSegmentAt(entry, t)
        local px = playerPos.X + playerVel.X * t
        local py = playerPos.Y + playerVel.Y * t
        local dSq = pointSegmentDistanceSq(px, py, a.X, a.Y, b.X, b.Y)
        if dSq <= combinedSq then return t end
    end
    return nil
end

--- 碰撞检测：按 kind 路由
--- entry: 追踪器条目 {pos, vel, speed, radius, kind?, variant?}
--- playerPos, playerVel, playerRadius, horizon
--- terrain: 可选，Terrain 实例（弹幕墙壁截断用；nil/invalid 不截断）
--- 返回: 命中帧数 t（nil=无碰撞）
local function timeToHitForEntry(entry, playerPos, playerVel, playerRadius, horizon, terrain)
    local kind = entry.kind or "projectile"

    if kind == "laser" then
        return timeToHitLaser(entry, playerPos, playerVel, playerRadius, horizon)

    elseif kind == "bomb" then
        -- 炸弹：圆碰撞（用当前 pos+vel*t 外推炸弹位置）
        -- 引信已过滤（sensors只采集frameCount>=120的）
        return Predict.timeToHitMoving(entry, playerPos, playerVel, playerRadius, horizon)

    elseif kind == "effect" or kind == "npc_attack" then
        -- 效果/NPC攻击前兆：圆碰撞（creep/火焰静态，冲击波/跳跃移动）
        return Predict.timeToHitMoving(entry, playerPos, playerVel, playerRadius, horizon)

    else
        -- 默认：弹幕/敌人闭式解 + 弧线解
        local t
        if Predict.isCurved(entry) then
            t = Predict.timeToHitArc(entry, playerPos, playerVel, playerRadius, horizon)
        elseif Predict.isTracking(entry) then
            t = Predict.timeToHitTracking(entry, playerPos, playerVel, playerRadius, horizon)
        else
            t = Predict.timeToHitMoving(entry, playerPos, playerVel, playerRadius, horizon)
        end
        -- 3.5 墙壁截断：命中路径穿墙 → 该弹幕会先撞墙，不构成墙后威胁
        if t and t > 0 and Predict.pathBlockedByWall(entry, t, terrain) then
            return nil
        end
        return t
    end
end

--- 沿玩家移动方向的首次碰撞帧数（Level 1: 紧急碰撞检测）
--- 返回: framesUntilHit（nil=无碰撞）, hitEntry（命中的威胁）
function HazardQuery.firstCollision(self, playerPos, playerVel, playerRadius, horizon, terrain)
    if not self.grid then return nil, nil end
    local near = Spatial.queryNear(self.grid, playerPos)
    local bestT, bestEntry = nil, nil
    for i = 1, #near do
        local entry = near[i]
        local t = timeToHitForEntry(entry, playerPos, playerVel, playerRadius, horizon, terrain)
        if t and (not bestT or t < bestT) then
            bestT = t
            bestEntry = entry
        end
    end
    return bestT, bestEntry
end

--- 静止玩家当前位置是否已被威胁覆盖（frame 0 命中）
function HazardQuery.isInDanger(self, playerPos, playerRadius, terrain)
    if not self.grid then return false end
    local near = Spatial.queryNear(self.grid, playerPos)
    for i = 1, #near do
        local entry = near[i]
        local t = timeToHitForEntry(entry, playerPos, Vector(0, 0), playerRadius, 0, terrain)
        if t == 0 then return true, entry end
    end
    return false
end

return HazardQuery
