-- decision/fallback.lua
-- 轻量 DWA 候选评分（Phase 2.4 升级版）
-- 16方位 × 3速度 + 玩家输入 + 零速 + 当前速度方向 = 最多51个候选
-- 评分维度: 碰撞时间 / 弹道线逃逸 / 墙壁惩罚 / 路径清晰度 / 趋势对齐 / 输入对齐
--
-- DWA 升级点（相对 Phase 1 版）：
--   1. 多速度候选（慢2/中5/快8 px/帧）—— 能找到窄间隙低速穿过的路径
--   2. 路径清晰度评分 —— 沿候选路径N帧内距最近威胁的最小距离（越大越好）
--   3. 趋势对齐 —— 与弹幕场梯度规避方向对齐加分（更聪明的"朝安全区走"）

local Fallback = {}

local mathext = require("utils/math_ext")

local CANDIDATE_DIR_COUNT = 16 -- 方向采样数（弹幕>50时降级到8）
local SPEED_LEVELS = { 2, 5, 8 } -- 多速度候选（慢/中/快，像素/帧）
local CLARITY_FRAMES = 8 -- 路径清晰度检查帧数
local CLARITY_STEP = 2 -- 清晰度步进帧数（性能换精度）

--- 评估单个候选方向+速度
--- 返回分数（越低越好）
local function scoreCandidate(dir, speed, ctx)
    local score = 0
    local playerPos = ctx.playerPos
    local playerRadius = ctx.playerRadius
    local simVel = dir * speed

    -- 1. 碰撞时间惩罚：越早撞分数越高（差）
    local minT = nil
    local nearest = nil
    for i = 1, #ctx.hazards do
        local h = ctx.hazards[i]
        local d = h.pos:Distance(playerPos)
        if d < ctx.scanRadius then
            local t = Predict_timeToHitMoving(h, playerPos, simVel, playerRadius, ctx.horizon)
            if t then
                if not minT or t < minT then
                    minT = t
                    nearest = h
                end
            end
        end
    end
    if minT then
        score = score + (ctx.horizon - minT) * 10 -- 早撞重罚
    end

    -- 2. 弹道线逃逸惩罚（auto_dodge_helper 精华#1）
    if nearest and nearest.vel:Length() > 0.1 then
        local travel = nearest.vel:Normalized()
        local rel = playerPos - nearest.pos
        local side = travel.X * rel.Y - travel.Y * rel.X
        local lateral = travel.X * dir.Y - travel.Y * dir.X
        local escape = lateral
        if math.abs(side) <= ctx.onLineDistance then
            escape = math.abs(lateral)
        elseif side < 0 then
            escape = -lateral
        end
        if escape < ctx.minPerp then
            local deficit = ctx.minPerp - escape
            score = score + 15 + deficit * deficit * 20
        end
    end

    -- 3. 墙壁惩罚（原则5第一层：预防）+ 远离墙壁偏向（原则5第三层）
    if ctx.terrain.valid then
        local wallDist = ctx.terrain:distanceToWall(playerPos, dir)
        local threshold = ctx.wallPenaltyThreshold
        if wallDist < threshold then
            local closeness = 1 - (wallDist / threshold)
            score = score + ctx.wallPenaltyBase * closeness * closeness * 30
        end
        if wallDist < 15 then
            score = score + 1000 -- 硬拒绝：1步就撞墙
        end
        local probe = playerPos + dir * 40
        if ctx.terrain:dangerAt(probe) then
            score = score + 200
        end
        -- 原则5第三层：远离墙壁偏向——如果玩家当前靠墙，奖励朝房间中心走的方向
        if ctx.wallDistCurrent and ctx.wallDistCurrent < ctx.wallStuckThreshold then
            local awayDir = ctx.roomCenter - playerPos
            if awayDir:Length() > 1 then
                awayDir = awayDir:Normalized()
                local awayAlign = mathext.dot(dir, awayDir)
                -- 靠墙越近，远离墙壁的奖励越大
                local urgency = 1 - (ctx.wallDistCurrent / ctx.wallStuckThreshold)
                score = score - awayAlign * urgency * 15 -- 负分 = 奖励
            end
        end
    end

    -- 4. 路径清晰度评分（DWA 核心升级）：沿候选路径N帧步进，
    --    每步检查距所有近距威胁的最小距离，最小值即"路径清晰度"
    --    清晰度低 = 路径上有威胁 = 罚分；清晰度高 = 安全通道 = 加分
    local minClearance = math.huge
    for t = CLARITY_STEP, CLARITY_FRAMES, CLARITY_STEP do
        local futurePos = playerPos + simVel * t
        for i = 1, #ctx.hazards do
            local h = ctx.hazards[i]
            if h.pos:Distance(playerPos) < ctx.scanRadius then
                -- 威胁未来位置（线性外推）
                local hFuture = h.pos + h.vel * t
                local dist = futurePos:Distance(hFuture) - playerRadius - h.radius
                if dist < minClearance then
                    minClearance = dist
                end
            end
        end
    end
    if minClearance < 40 then -- 40px 内有威胁
        local penalty = (40 - minClearance) * 0.5
        score = score + penalty * penalty * 0.1
    end

    -- 5. 趋势对齐：与弹幕场梯度规避方向对齐加分
    if ctx.avoidanceDir and ctx.avoidanceDir:Length() > 0.1 then
        local align = mathext.dot(dir, ctx.avoidanceDir:Normalized())
        score = score - align * 5 -- 负分 = 奖励（朝安全方向走）
    end

    -- 6. 与玩家输入方向对齐加分
    if ctx.playerInput and ctx.playerInput:Length() > 0.1 then
        local align = mathext.dot(dir, ctx.playerInput:Normalized())
        score = score - align * 8
    end

    return score
end

--- 相对碰撞时间（内联，避免 require 顺序问题）
function Predict_timeToHitMoving(entry, playerPos, playerVel, playerRadius, horizon)
    local rel = playerPos - entry.pos
    local vrelX = playerVel.X - entry.vel.X
    local vrelY = playerVel.Y - entry.vel.Y
    local combined = entry.radius + playerRadius
    local a = vrelX * vrelX + vrelY * vrelY
    local rx, ry = rel.X, rel.Y
    local b = rx * vrelX + ry * vrelY
    local c = rx * rx + ry * ry - combined * combined
    if c <= 0 then return 0 end
    if a < 0.0001 then return nil end
    local disc = b * b - a * c
    if disc < 0 then return nil end
    local sq = math.sqrt(disc)
    local t = (-b - sq) / a
    if t < 0 then
        t = (-b + sq) / a
        if t < 0 then return nil end
    end
    if t > horizon then return nil end
    return t
end

--- 主入口：返回最优方向+速度（归一化 Vector）或 nil
function Fallback.compute(state, deps, frame)
    local player = state.player
    local config = deps.config
    local hazards = deps.getHazards(frame)

    local degraded = #hazards > config.degradeThreshold
    local n = degraded and 8 or CANDIDATE_DIR_COUNT

    local ctx = {
        playerPos = player.position,
        playerRadius = player.radius,
        playerInput = player.inputDir,
        hazards = hazards,
        horizon = 28,
        scanRadius = 400,
        onLineDistance = 10,
        minPerp = 0.3,
        terrain = deps.terrain,
        wallPenaltyBase = config.wallPenaltyBase,
        wallPenaltyThreshold = config.wallPenaltyThreshold,
        avoidanceDir = state.threat.gradientDir,
        -- 墙壁挣脱参数（原则5第三层：远离墙壁偏向）
        wallStuckThreshold = config.wallStuckThreshold,
        wallDistCurrent = deps.terrain.valid and deps.terrain:minWallDistance(player.position) or 9999,
        roomCenter = deps.terrain.valid and deps.terrain.topLeft
            and (deps.terrain.topLeft + Vector(deps.terrain.sizeX * 20, deps.terrain.sizeY * 20))
            or player.position,
    }

    local bestDir, bestScore = nil, math.huge

    -- 16方向 × 3速度 = 48个候选
    for i = 1, n do
        local angle = (i - 1) * (2 * math.pi / n)
        local dir = Vector(math.cos(angle), math.sin(angle))
        for _, speed in ipairs(SPEED_LEVELS) do
            local s = scoreCandidate(dir, speed, ctx)
            if s < bestScore then
                bestScore = s
                bestDir = dir
            end
        end
    end

    -- 追加：零速候选（原地不动——有时是最优选择）
    local s0 = scoreCandidate(Vector(0, 0), 0, ctx)
    if s0 < bestScore then
        bestScore = s0
        bestDir = Vector(0, 0)
    end

    -- 追加：玩家输入方向候选（可能不是16方位之一）
    if player.inputDir and player.inputDir:Length() > 0.1 then
        local dir = player.inputDir:Normalized()
        for _, speed in ipairs(SPEED_LEVELS) do
            local s = scoreCandidate(dir, speed, ctx)
            if s < bestScore then
                bestScore = s
                bestDir = dir
            end
        end
    end

    state.decision.degraded = degraded
    return bestDir
end

return Fallback
