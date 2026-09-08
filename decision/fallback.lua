-- decision/fallback.lua
-- 轻量 DWA 候选评分（Phase 2.4 升级版 + 性能重构版 + Tier 1 时空轨迹评分）
-- 两阶段评估: 粗评(16方向×1速度,无轨迹评分) → 精评(top5方向×3速度+轨迹评分)
-- 计算量约为全量版(51候选×清晰度)的 1/6 —— 实测 14 敌人场景全量版 7-21ms
-- 超预算(原则4)，重构后回到 1ms 量级
--
-- 评分维度: 碰撞时间 / 弹道线逃逸 / 墙壁惩罚 / 时空轨迹评分(仅精评) / 趋势对齐 / 输入对齐
--
-- DWA 升级点（相对 Phase 1 版）：
--   1. 多速度候选（慢2/中5/快8 px/帧）—— 能找到窄间隙低速穿过的路径
--   2. 时空轨迹评分（Tier 1）—— 分级 horizon {4,8,16,24} 外推，近期保命+远期择路
--   3. 趋势对齐 —— 与弹幕场梯度规避方向对齐加分（更聪明的"朝安全区走"）

local Fallback = {}

local mathext = require("utils/math_ext")

local CANDIDATE_DIR_COUNT = 16 -- 方向采样数（弹幕>50时降级到8）
local SPEED_LEVELS = { 2, 5, 8 } -- 多速度候选（慢/中/快，像素/帧）
local COARSE_SPEED = 5 -- 粗评用的中速档
local TOP_REFINE = 5 -- 精评的方向数
-- 轨迹评分: 分级 horizon 外推（Tier 1，替代旧版2档线性清晰度）
-- 近期保命 + 远期择路 + 远期收敛奖励
local FutureMotion = require("threat/future_motion")
local HORIZONS = { 4, 8, 16, 24 }
local HORIZON_WEIGHT = { 1.0, 0.7, 0.5, 0.4 }   -- 近期重、远期轻
local CONVERGE_BONUS_T = 24                        -- 远期收敛奖励档
local CONVERGE_CLEARANCE = 60                      -- px（远期 clearance > 此值 → 奖励）
local CONVERGE_BONUS = 12                          -- 收敛奖励分值
local SCAN_RADIUS = 400                            -- 威胁纳入半径（预过滤一次，替代逐候选重复距离过滤）

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
        -- 嵌墙(wallDistCurrent<0): 已在墙壁碰撞体内
        -- 非通行方向重罚 + 可通行方向奖励（引导找到逃生通道）
        if ctx.wallDistCurrent and ctx.wallDistCurrent < 0 then
            local probe20 = playerPos + dir * 20
            if not ctx.terrain:isWalkableAt(probe20) then
                score = score + 2000 -- 嵌墙时朝墙方向：硬拒绝
            else
                score = score - 500 -- 嵌墙时可通行方向：大额奖励（引导逃生）
            end
        end
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
        -- 贴墙+敌人时奖励大幅加强：敌人封住退路，必须尽快离开墙壁区域
        -- 实测(2026-09-08死亡局) escape_lock 方向正确但推不动→墙壁逃脱奖励不足
        -- 奖励基数50 vs 碰撞惩罚180 → 朝房间中心方向获得显著净收益
        if ctx.wallDistCurrent and ctx.wallDistCurrent < ctx.wallStuckThreshold then
            local awayDir = ctx.roomCenter - playerPos
            if awayDir:Length() > 1 then
                awayDir = awayDir:Normalized()
                local awayAlign = mathext.dot(dir, awayDir)
                -- 靠墙越近，远离墙壁的奖励越大；贴墙(<阈值一半)时翻倍
                local urgency = math.max(0.3, 1 - (ctx.wallDistCurrent / ctx.wallStuckThreshold))
                local wallCloseness = ctx.wallDistCurrent < ctx.wallStuckThreshold * 0.5 and 2 or 1
                -- 敌人在场时墙壁逃脱奖励翻倍（每个敌人+50%，最多3倍）
                local enemyBoost = 1 + math.min((ctx.enemyNearCount or 0) * 0.5, 2)
                score = score - awayAlign * urgency * 50 * wallCloseness * enemyBoost -- 负分 = 奖励
            end
        end
    end

    -- 4. 时空轨迹评分（Tier 1 核心，仅精评阶段）：分级 horizon 检查沿候选路径
    --    各威胁按自身运动模型外推后的位置，近期权重高（保命）、远期权重低（择路）。
    --    远期收敛奖励：t=24 处 clearance > 60px 的候选给大额奖励——"移动到未来的洞"
    if withClarity then
        local minClearance = math.huge
        local convergeClearance = math.huge -- t=CONVERGE_BONUS_T 处的 clearance
        for hi = 1, #HORIZONS do
            local t = HORIZONS[hi]
            local futurePos = playerPos + simVel * t
            local w = HORIZON_WEIGHT[hi]
            for i = 1, #hazards do
                local h = hazards[i]
                local hp, hp2 = FutureMotion.pos(h, t, ctx.frame)
                if hp then
                    local dist
                    if hp2 then
                        -- laser: hp2 是线段第二端点，用点到线段距离
                        local dSq = FutureMotion._pointSegmentDistSq(
                            futurePos.X, futurePos.Y,
                            hp.X, hp.Y, hp2.X, hp2.Y)
                        dist = math.sqrt(dSq) - playerRadius - h.radius
                    else
                        dist = futurePos:Distance(hp) - playerRadius - h.radius
                    end
                    local penalty = dist * w -- 加权距离（近期更敏感）
                    if penalty < minClearance then
                        minClearance = penalty
                    end
                    if t == CONVERGE_BONUS_T and dist < convergeClearance then
                        convergeClearance = dist
                    end
                end
            end
        end
        if minClearance < 40 then
            local penalty = (40 - minClearance) * 0.5
            score = score + penalty * penalty * 0.1
        end
        -- 远期收敛奖励：t=24 处所有威胁都离得远 → "移动到安全洞"
        if convergeClearance > CONVERGE_CLEARANCE then
            score = score - CONVERGE_BONUS
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
    local playerPos = player.position
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
        frame = frame, -- Tier 1: 圆弧缓存需要当前帧号
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

    -- 贴墙+敌人时加大墙壁逃脱奖励（快速计数，O(n) 但 n≤SCAN_RADIUS 过滤后很小）
    local enemyNearCount = 0
    for i = 1, #nearHazards do
        if nearHazards[i].kind == "enemy" then enemyNearCount = enemyNearCount + 1 end
    end
    ctx.enemyNearCount = enemyNearCount

    -- 嵌墙紧急覆写：wallDistCurrent < 0 = 玩家已在墙壁碰撞体内
    -- 探测8方向找可通行逃生路径（不盲目朝房间中心推——狭窄缝隙中该方向可能被阻挡）
    if ctx.wallDistCurrent and ctx.wallDistCurrent < 0 and ctx.terrain.valid then
        local bestEscapeDir = nil
        local bestEscapeScore = -math.huge
        for i = 1, 8 do
            local angle = (i - 1) * (2 * math.pi / 8)
            local dir = Vector(math.cos(angle), math.sin(angle))
            local probe = playerPos + dir * 30
            if ctx.terrain:isWalkableAt(probe) then
                local alignScore = 0
                if ctx.roomCenter and (ctx.roomCenter - playerPos):Length() > 1 then
                    alignScore = mathext.dot(dir, (ctx.roomCenter - playerPos):Normalized())
                end
                local midProbe = playerPos + dir * 15
                local midBonus = ctx.terrain:isWalkableAt(midProbe) and 2 or 0
                local score = alignScore + midBonus
                if score > bestEscapeScore then
                    bestEscapeScore = score
                    bestEscapeDir = dir
                end
            end
        end
        if bestEscapeDir then
            state.decision.degraded = false
            if traceOut then traceOut.best = -9999 end
            return bestEscapeDir
        end
        -- 无路可走：不覆写，让评分流程选最优（可能有微小通道）
    end

    -- ===== 阶段1: 粗评（n方向×1中速，无清晰度）=====
    -- 近墙时追加自适应方向：在远离墙壁方向附近加密采样（±22.5°偏移），
    -- 确保直角角落总有一个方向与两面墙都成45°以上夹角
    local coarse = {}
    for i = 1, n do
        local angle = (i - 1) * (2 * math.pi / n)
        local dir = Vector(math.cos(angle), math.sin(angle))
        coarse[i] = { dir = dir, score = scoreCandidate(dir, COARSE_SPEED, ctx, false),
                      ang = (i - 1) * (360 / n) }
    end
    -- 近墙自适应追加：wallDist<80px时在朝房间中心方向追加±22.5°偏移候选
    if ctx.wallDistCurrent and ctx.wallDistCurrent < 80 and ctx.roomCenter then
        local toCenter = ctx.roomCenter - playerPos
        if toCenter:Length() > 1 then
            local centerAngle = math.atan(toCenter.Y, toCenter.X)
            local offsets = { -math.pi / 8, math.pi / 8, -math.pi / 4, math.pi / 4 }
            for oi = 1, #offsets do
                local a = centerAngle + offsets[oi]
                local dir = Vector(math.cos(a), math.sin(a))
                coarse[#coarse + 1] = { dir = dir, score = scoreCandidate(dir, COARSE_SPEED, ctx, false),
                    ang = math.deg(a) % 360 }
            end
        end
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
