-- threat/threat_level.lua
-- 综合威胁等级计算（4.3节两级评估）
--   Level 1: 碰撞紧急度 — 沿当前路径的首次碰撞帧数
--   Level 2: 弹幕场密度梯度 — 提前规避的依据（原则6核心，7.5.8实现）
--   综合: threat = max(collisionUrgency, densityScore * 0.7)

local ThreatLevel = {}

local mathext = require("utils/math_ext")

--- 碰撞紧急度：碰撞帧数 → [0,1]
--- framesUntilHit: 首次碰撞帧数（nil=无碰撞）
--- horizon: 预测窗口（帧）
local function collisionUrgency(framesUntilHit, horizon)
    if not framesUntilHit then return 0 end
    -- 5帧内→紧急(>0.8)，15帧→低，超过窗口→0
    if framesUntilHit <= 5 then
        return 0.8 + 0.2 * (1 - framesUntilHit / 5)
    end
    return mathext.remap(framesUntilHit, 5, horizon, 0.65, 0)
end

--- 弹幕场梯度（7.5.8）
--- 返回: avoidanceDir（Vector 或 nil）, densityScore [0,1]
local function computeGradient(playerPos, hazards, config)
    local radius = config.gradientRadius
    local binCount = config.gradientBins
    local bins = {}
    for i = 1, binCount do bins[i] = 0 end
    local totalWeight = 0

    for i = 1, #hazards do
        local h = hazards[i]
        local delta = h.pos - playerPos
        local dist = delta:Length()
        if dist < radius and dist > 1 then
            local distWeight = 1 - (dist / radius)
            -- 速度加权但保底0.3：静止弹幕(如ipecac落地弹/驻留弹)仍算入密度场
            local speedWeight = math.max(0.3, math.min(h.speed / 10, 3))
            local weight = distWeight * speedWeight
            -- 方向 bin：以玩家为中心，弹幕在哪个方位
            local angle = math.atan(delta.Y, delta.X)
            local bin = math.floor(((angle + math.pi) / (2 * math.pi)) * binCount) % binCount + 1
            bins[bin] = bins[bin] + weight
            totalWeight = totalWeight + weight
        end
    end

    -- 密度分数：总权重 / 预期满密度（8bin × 3 = 24 归一化基准）
    local densityScore = mathext.clamp(totalWeight / 24, 0, 1)

    -- 梯度向量：密度质心方向（质量加权平均）
    -- 比相邻bin差分更稳健——对称弹幕簇的差分梯度会互相抵消，质心不会
    local gradX, gradY = 0, 0
    local stepAngle = 2 * math.pi / binCount
    for i = 1, binCount do
        if bins[i] > 0 then
            -- bin i 的中心角度（与bin映射公式严格对应: i=1 → -π）
            local angle = (i - 1) * stepAngle - math.pi + stepAngle / 2
            gradX = gradX + math.cos(angle) * bins[i]
            gradY = gradY + math.sin(angle) * bins[i]
        end
    end

    local len = math.sqrt(gradX * gradX + gradY * gradY)
    if len > 0.05 then
        -- 规避方向 = -质心方向（朝密度降低方向）
        return Vector(-gradX / len, -gradY / len), densityScore
    end
    return nil, densityScore
end

--- 主入口：计算综合威胁等级，写入 state.threat
--- deps = { hazardQuery, tracker, trackerEnemies, trackerLasers, trackerBombs, trackerEffects,
---          getHazards, terrain, config }
function ThreatLevel.evaluate(state, deps, frame)
    local config = deps.config
    local player = state.player
    local threat = state.threat
    local horizon = 28 -- 预测窗口（帧，~0.93秒@30fps）

    -- 活跃威胁（追踪器宽容读取：2帧内见过）；按类型分别计数
    local hazards = deps.getHazards(frame)
    threat.projectileCount = deps.tracker and deps.tracker.count or 0
    threat.enemyCount = deps.trackerEnemies and deps.trackerEnemies.count or 0
    threat.laserCount = deps.trackerLasers and deps.trackerLasers.count or 0
    threat.bombCount = deps.trackerBombs and deps.trackerBombs.count or 0
    threat.effectCount = deps.trackerEffects and deps.trackerEffects.count or 0
    threat.npcAttackCount = deps.trackerNpcAttacks and deps.trackerNpcAttacks.count or 0
    threat.hazardCount = #hazards

    -- Level 2: 弹幕场梯度
    local avoidanceDir, densityScore = computeGradient(player.position, hazards, config)
    threat.gradientDir = avoidanceDir
    threat.densityScore = densityScore

    -- Level 1: 碰撞紧急度
    -- 移动中: 沿速度方向做相对碰撞预测（含来袭弹幕）
    -- 站立时: 静止重叠检测 + 来袭弹幕命中时间（弹幕会撞上不动的玩家）
    local urgency = 0
    local hitFrame = nil
    local t
    if player.velocity:Length() > 0.5 then
        t = deps.hazardQuery:firstCollision(
            player.position, player.velocity, player.radius, horizon)
    else
        t = deps.hazardQuery:firstCollision(
            player.position, Vector(0, 0), player.radius, horizon)
    end
    if t then
        hitFrame = t
        urgency = collisionUrgency(t, horizon)
        -- Phase 3.6 伤害加权：高伤害威胁更早触发闪避
        -- hitEntry.kind == "bomb"(爆炸)和 boss 效果(妈妈脚等)伤害远高于普通弹幕
        -- urgency 乘以 damageMultiplier（clamp 0.5-3.0），确保1伤害弹幕和12伤害炸弹有区分度
        if hitEntry then
            local damage = hitEntry.damage or 1
            local damageMult = mathext.clamp(damage / 1, 0.5, 3.0) -- baseDamage=1
            urgency = math.min(urgency * damageMult, 1.0)
        end
    end
    threat.collisionUrgency = urgency
    threat.framesUntilHit = hitFrame or -1

    -- 地形危险（站上地刺/TNT 格子）：直接给高威胁
    if deps.terrain.valid then
        local danger = deps.terrain:dangerAt(player.position)
        if danger then
            urgency = math.max(urgency, 0.9)
            threat.collisionUrgency = urgency
        end
    end

    -- 墙壁+敌人复合威胁：贴墙且附近有敌人时，强制 AI 介入推离墙壁
    -- （卡墙问题的核心修复：单纯靠碰撞检测不够，需要主动远离墙壁）
    if deps.terrain.valid and threat.enemyCount > 0 then
        local wallDist = deps.terrain:minWallDistance(player.position)
        if wallDist < config.wallStuckThreshold then
            local wallUrgency = mathext.remap(wallDist, 0, config.wallStuckThreshold, 0.5, 0.1)
            urgency = math.max(urgency, wallUrgency)
            threat.collisionUrgency = math.max(threat.collisionUrgency, wallUrgency)
        end
    end

    -- 综合：密度威胁乘 0.7（密度不如碰撞紧急，但更早触发，原则6）
    threat.level = math.max(urgency, densityScore * 0.7)

    return threat.level
end

return ThreatLevel
