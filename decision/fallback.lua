-- decision/fallback.lua
-- 轻量 DWA 候选评分（Phase 2.4 升级版 + 性能重构版）
-- 两阶段评估: 粗评(16方向×1速度,无清晰度) → 精评(top5方向×3速度+清晰度)
-- 计算量约为全量版(51候选×清晰度)的 1/6 —— 实测 14 敌人场景全量版 7-21ms
-- 超预算(原则4)，重构后回到 1ms 量级
--
-- 评分维度: 碰撞时间 / 弹道线逃逸 / 墙壁惩罚 / 路径清晰度(仅精评) / 趋势对齐 / 输入对齐
--
-- DWA 升级点（相对 Phase 1 版）：
--   1. 多速度候选（慢2/中5/快8 px/帧）—— 能找到窄间隙低速穿过的路径
--   2. 路径清晰度评分 —— 沿候选路径N帧内距最近威胁的最小距离（越大越好）
--   3. 趋势对齐 —— 与弹幕场梯度规避方向对齐加分（更聪明的"朝安全区走"）

local Fallback = {}

local mathext = require("utils/math_ext")

local CANDIDATE_DIR_COUNT = 16 -- 方向采样数（弹幕>50时降级到8）
local SPEED_LEVELS = { 2, 5, 8 } -- 多速度候选（慢/中/快，像素/帧）
local COARSE_SPEED = 5 -- 粗评用的中速档
local TOP_REFINE = 5 -- 精评的方向数
local CLARITY_FRAMES = 8 -- 路径清晰度检查帧数
local CLARITY_STEP = 4 -- 清晰度步进帧数（性能换精度；步长4=2步）
local SCAN_RADIUS = 400 -- 威胁纳入半径（预过滤一次，替代逐候选重复距离过滤）

--- 评估单个候选方向+速度。withClarity=false 时跳过清晰度评分（粗评用）
--- 返回分数（越低越好）
local function scoreCandidate(dir, speed, ctx, withClarity)
    local score = 0
    local playerPos = ctx.playerPos
    local playerRadius = ctx.playerRadius
    local simVel = dir * speed
    local hazards = ctx.nearHazards

    -- 1. 碰撞时间惩罚：越早撞分数越高（差）
    local minT = nil
    local nearest = nil
    for i = 1, #hazards do
        local h = hazards[i]
        local t = Predict_timeToHitMoving(h, playerPos, simVel, playerRadius, ctx.horizon)
        if t then
            if not minT or t < minT then
                minT = t
                nearest = h
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
        -- 原则5第三层：远离墙壁偏向——如果玩家当前靠墙，奖励朝房间中心走的方向。
        -- 实测(2026-09-08死亡局)贴墙滑行被两侧夹击而死 → 贴得越近奖励越强(系数×2)
        if ctx.wallDistCurrent and ctx.wallDistCurrent < ctx.wallStuckThreshold then
            local awayDir = ctx.roomCenter - playerPos
            if awayDir:Length() > 1 then
                awayDir = awayDir:Normalized()
                local awayAlign = mathext.dot(dir, awayDir)
                -- 靠墙越近，远离墙壁的奖励越大；贴墙(<阈值一半)时翻倍
                local urgency = 1 - (ctx.wallDistCurrent / ctx.wallStuckThreshold)
                local wallCloseness = ctx.wallDistCurrent < ctx.wallStuckThreshold * 0.5 and 2 or 1
                score = score - awayAlign * urgency * 15 * wallCloseness -- 负分 = 奖励
            end
        end
    end

    -- 4. 路径清晰度评分（DWA 核心，仅精评阶段）：沿候选路径步进检查距
    --    所有近距威胁的最小距离，最小值即"路径清晰度"
    if withClarity then
        local minClearance = math.huge
        for t = CLARITY_STEP, CLARITY_FRAMES, CLARITY_STEP do
            local futurePos = playerPos + simVel * t
            for i = 1, #hazards do
                local h = hazards[i]
                -- 威胁未来位置（线性外推）
                local hFuture = h.pos + h.vel * t
                local dist = futurePos:Distance(hFuture) - playerRadius - h.radius
                if dist < minClearance then
                    minClearance = dist
                end
            end
        end
        if minClearance < 40 then -- 40px 内有威胁
            local penalty = (40 - minClearance) * 0.5
            score = score + penalty * penalty * 0.1
        end
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
--- traceOut: 可选表（级别4录制用），粗评排序后填 cand（top候选角度+分数）、
---           精评结束填 best（最优分）——离线回答"为什么往这躲"
function Fallback.compute(state, deps, frame, traceOut)
    local player = state.player
    local config = deps.config
    local hazards = deps.getHazards(frame)
    local budgetMs = config.budgetMs or 1.0
    local startTime = Isaac.GetTime()

    local degraded = #hazards > config.degradeThreshold
    local n = degraded and 8 or CANDIDATE_DIR_COUNT

    -- 预过滤：只留玩家附近的威胁（替代旧版每候选循环内重复的距离过滤，
    -- 51候选×N威胁的重复计算 → 一次 O(n) 过滤）
    local nearHazards = {}
    for i = 1, #hazards do
        local h = hazards[i]
        if h.pos:Distance(player.position) < SCAN_RADIUS then
            nearHazards[#nearHazards + 1] = h
        end
    end

    local ctx = {
        playerPos = player.position,
        playerRadius = player.radius,
        playerInput = player.inputDir,
        nearHazards = nearHazards,
        horizon = 28,
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

    -- ===== 阶段1: 粗评（n方向×1中速，无清晰度）=====
    local coarse = {}
    for i = 1, n do
        local angle = (i - 1) * (2 * math.pi / n)
        local dir = Vector(math.cos(angle), math.sin(angle))
        -- ang 记录角度（度）：级别4录制直接取，避免 Lua 5.1/5.4 atan 兼容问题
        coarse[i] = { dir = dir, score = scoreCandidate(dir, COARSE_SPEED, ctx, false),
                      ang = (i - 1) * (360 / n) }
    end
    -- 粗分排序取 top（n≤16）
    table.sort(coarse, function(a, b) return a.score < b.score end)
    local refineCount = math.min(TOP_REFINE, #coarse)

    -- 级别4录制: 粗评 top 候选（进入精评的方向集）留痕
    if traceOut then
        local cand = {}
        for i = 1, math.min(6, #coarse) do
            cand[i] = { a = coarse[i].ang, s = coarse[i].score }
        end
        traceOut.cand = cand
    end

    -- ===== 阶段2: 精评（top5方向×3速度 + 清晰度），带超时熔断（原则4）=====
    local bestDir, bestScore = nil, math.huge
    local evaluated = 0
    local budgetOut = false
    for i = 1, refineCount do
        local dir = coarse[i].dir
        for _, speed in ipairs(SPEED_LEVELS) do
            local s = scoreCandidate(dir, speed, ctx, true)
            if s < bestScore then
                bestScore = s
                bestDir = dir
            end
            -- 预算用尽即用当前最优，宁可次优不可超时
            evaluated = evaluated + 1
            if evaluated % 6 == 0 and (Isaac.GetTime() - startTime) > budgetMs * 0.8 then
                budgetOut = true
                break
            end
        end
        if budgetOut then break end
    end

    if not budgetOut then
        -- 追加：零速候选（原地不动——有时是最优选择）
        local s0 = scoreCandidate(Vector(0, 0), 0, ctx, true)
        if s0 < bestScore then
            bestScore = s0
            bestDir = Vector(0, 0)
        end

        -- 追加：玩家输入方向候选（可能不是16方位之一）
        if player.inputDir and player.inputDir:Length() > 0.1 then
            local dir = player.inputDir:Normalized()
            for _, speed in ipairs(SPEED_LEVELS) do
                local s = scoreCandidate(dir, speed, ctx, true)
                if s < bestScore then
                    bestScore = s
                    bestDir = dir
                end
            end
        end
    end

    state.decision.degraded = degraded or budgetOut
    if traceOut then
        traceOut.best = bestDir ~= nil and bestScore or nil
    end
    return bestDir
end

return Fallback
