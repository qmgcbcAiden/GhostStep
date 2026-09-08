-- decision/early_dodge.lua
-- Layer 1: 单弹幕快速垂直闪避（GhostStep 思路，不照抄实现）
-- 场景: 少量弹幕（≤2）且即将命中 → 直接计算垂直于弹幕轨迹的逃离方向
-- 附加弹道线逃逸惩罚思想：绝不沿弹幕飞行方向移动

local EarlyDodge = {}

--- 计算垂直闪避方向
--- entry: 命中弹幕 { pos, vel, ... }；playerPos: 玩家位置
--- 返回: 归一化逃离方向 或 nil（无法计算）
function EarlyDodge.compute(entry, playerPos)
    local rel = playerPos - entry.pos
    local vel = entry.vel
    if vel:Length() < 0.01 then
        -- 静止弹幕：直接远离
        if rel:Length() > 0.01 then
            return rel:Normalized()
        end
        return nil
    end

    local travel = vel:Normalized()
    -- 玩家在弹幕轨迹的哪一侧（叉积符号）
    local side = travel.X * rel.Y - travel.Y * rel.X
    -- 垂直于轨迹的两个方向
    local perp
    if side >= 0 then
        perp = Vector(-travel.Y, travel.X)
    else
        perp = Vector(travel.Y, -travel.X)
    end
    -- 始终朝远离弹道线的一侧逃离
    if perp:Length() < 0.01 then return nil end
    return perp:Normalized()
end

--- 快速判定：是否适用本层
--- conditions: { hazardCount(威胁实体总数), framesUntilHit, threatLevel }
function EarlyDodge.applies(conditions)
    return conditions.hazardCount ~= nil
        and conditions.hazardCount <= 2
        and conditions.framesUntilHit ~= nil
        and conditions.framesUntilHit >= 0
        and conditions.framesUntilHit <= 12
end

return EarlyDodge
