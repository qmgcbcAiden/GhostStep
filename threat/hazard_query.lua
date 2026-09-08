-- threat/hazard_query.lua
-- 空间危险查询：组合所有威胁类型，按 kind 路由碰撞检测
-- Phase 1: 弹幕/敌人 (闭式解 + 弧线解)
-- Phase 3: 激光 (线段距离), 炸弹 (圆碰撞), 效果 (圆碰撞)
--
-- 原则: Spatial 空间分桶对所有 kind 通用（pos 是圆心，查询半径足够大即行）
-- 不同 kind 的碰撞几何在 firstCollision 中路由

local HazardQuery = {}

local Spatial = require("threat/spatial")
local Predict = require("threat/projectile_predict")

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

--- 碰撞检测：按 kind 路由
--- entry: 追踪器条目 {pos, vel, speed, radius, kind?, variant?}
--- playerPos, playerVel, playerRadius, horizon
--- 返回: 命中帧数 t（nil=无碰撞）
local function timeToHitForEntry(entry, playerPos, playerVel, playerRadius, horizon)
    local kind = entry.kind or "projectile"

    if kind == "laser" then
        -- 激光：线段距离碰撞
        -- 静态激光：线段=pos→pos（退化为圆）
        -- 扫描激光：用vel近似扫描方向（简化：当前帧线段 vs 玩家移动路径）
        local combined = entry.radius + playerRadius
        local combinedSq = combined * combined
        -- 静止玩家检查
        local dSq = pointSegmentDistanceSq(
            playerPos.X, playerPos.Y,
            entry.pos.X, entry.pos.Y,
            entry.pos.X + entry.vel.X, entry.pos.Y + entry.vel.Y)
        if dSq <= combinedSq then return 0 end
        -- 移动玩家：沿路径步进（步长2帧，精度足够）
        for t = 2, horizon, 2 do
            local px = playerPos.X + playerVel.X * t
            local py = playerPos.Y + playerVel.Y * t
            local ex = entry.pos.X + entry.vel.X * (t / horizon) -- 近似激光移动
            local ey = entry.pos.Y + entry.vel.Y * (t / horizon)
            local dd = pointSegmentDistanceSq(px, py,
                entry.pos.X, entry.pos.Y, ex, ey)
            if dd <= combinedSq then return t end
        end
        return nil

    elseif kind == "bomb" then
        -- 炸弹：圆碰撞（用当前 pos+vel*t 外推炸弹位置）
        -- 引信已过滤（sensors只采集frameCount>=120的）
        return Predict.timeToHitMoving(entry, playerPos, playerVel, playerRadius, horizon)

    elseif kind == "effect" or kind == "npc_attack" then
        -- 效果/NPC攻击前兆：圆碰撞（creep/火焰静态，冲击波/跳跃移动）
        return Predict.timeToHitMoving(entry, playerPos, playerVel, playerRadius, horizon)

    else
        -- 默认：弹幕/敌人闭式解 + 弧线解
        if Predict.isCurved(entry) then
            return Predict.timeToHitArc(entry, playerPos, playerVel, playerRadius, horizon)
        elseif Predict.isTracking(entry) then
            return Predict.timeToHitTracking(entry, playerPos, playerVel, playerRadius, horizon)
        else
            return Predict.timeToHitMoving(entry, playerPos, playerVel, playerRadius, horizon)
        end
    end
end

--- 沿玩家移动方向的首次碰撞帧数（Level 1: 紧急碰撞检测）
--- 返回: framesUntilHit（nil=无碰撞）, hitEntry（命中的威胁）
function HazardQuery.firstCollision(self, playerPos, playerVel, playerRadius, horizon)
    if not self.grid then return nil, nil end
    local near = Spatial.queryNear(self.grid, playerPos)
    local bestT, bestEntry = nil, nil
    for i = 1, #near do
        local entry = near[i]
        local t = timeToHitForEntry(entry, playerPos, playerVel, playerRadius, horizon)
        if t and (not bestT or t < bestT) then
            bestT = t
            bestEntry = entry
        end
    end
    return bestT, bestEntry
end

--- 静止玩家当前位置是否已被威胁覆盖（frame 0 命中）
function HazardQuery.isInDanger(self, playerPos, playerRadius)
    if not self.grid then return false end
    local near = Spatial.queryNear(self.grid, playerPos)
    for i = 1, #near do
        local entry = near[i]
        local t = timeToHitForEntry(entry, playerPos, Vector(0, 0), playerRadius, 0)
        if t == 0 then return true, entry end
    end
    return false
end

return HazardQuery
