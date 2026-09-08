-- decision/pipeline.lua
-- 决策管线调度器（Phase 2 版: gradient / escape_lock / early_dodge / fallback）
-- Phase 2 后续: vo_dwa 替代 fallback 成为主力
-- 每层有预算检查：超过预算的 70% 时跳过复杂层（原则4）

local Pipeline = {}

local EarlyDodge = require("decision/early_dodge")
local Fallback = require("decision/fallback")
local EscapeLock = require("decision/escape_lock")
local DirectionSmooth = require("decision/direction_smooth")

--- 运行决策管线。结果写入 state.decision
--- deps = { config, tracker, hazardQuery, terrain, escapeLock }
function Pipeline.run(state, deps, frame)
    local threat = state.threat
    local decision = state.decision
    local config = deps.config

    decision.usedBudgetMs = 0
    decision.degraded = false
    decision.lastTrace = nil

    -- 级别4录制: 候选评分 trace 表（Fallback 填充，Snapshot.finalize 读取）
    local trace = config.snapshotDetail >= 4 and {} or nil

    -- 帧预算计时（原则4：每帧决策总耗时不超过 budgetMs）
    local budgetMs = config.budgetMs or 1.0
    local startTime = Isaac.GetTime()

    -- 威胁分级（4.4节三级响应）
    local level = threat.level
    local layer = "none"
    local rawDir = nil

    if level < config.threatLow then
        -- 安全区：不决策，玩家完全控制
        layer = "none"
    elseif level < config.threatMedium then
        -- ★ 提前规避：弹幕场梯度微调（原则6+7），权重小
        layer = "gradient"
        rawDir = threat.gradientDir
        -- 梯度为 nil（均匀分布）时退回 fallback 找稀疏方向
        if not rawDir and threat.projectileCount > 0 then
            rawDir = Fallback.compute(state, deps, frame, trace)
            if rawDir then layer = "gradient_fallback" end
        end
    else
        local conditions = {
            hazardCount = threat.hazardCount or threat.projectileCount or 0,
            framesUntilHit = threat.framesUntilHit >= 0 and threat.framesUntilHit or nil,
            threatLevel = level,
            threatHigh = config.threatHigh,
            enemyCount = threat.enemyCount or 0,
        }
        if deps.escapeLock and EscapeLock.applies(conditions) then
            -- Layer 2: 逃离锁定——站在危险区内，锁定方向往外冲（防抖）
            layer = "escape_lock"
            rawDir = deps.escapeLock:process(frame, function()
                return Fallback.compute(state, deps, frame, trace)
            end, state.player.position)
            if not rawDir then layer = "fallback" end
        elseif EarlyDodge.applies(conditions) then
            -- Layer 1: 单弹幕垂直闪避（快速路径）
            layer = "early_dodge"
            local _, hitEntry = deps.hazardQuery:firstCollision(
                state.player.position, state.player.velocity,
                state.player.radius, 28, deps.terrain)
            if hitEntry then
                rawDir = EarlyDodge.compute(hitEntry, state.player.position)
            end
            if not rawDir then
                if (Isaac.GetTime() - startTime) < budgetMs * 0.7 then
                    layer = "fallback"
                    rawDir = Fallback.compute(state, deps, frame, trace)
                else
                    decision.degraded = true
                end
            end
        else
            -- 降级保底：候选评分（Phase 2 后续由 VO+DWA 替代为主力）
            if (Isaac.GetTime() - startTime) < budgetMs * 0.7 then
                layer = "fallback"
                rawDir = Fallback.compute(state, deps, frame, trace)
            else
                decision.degraded = true
            end
        end
    end

    -- 方向平滑 + 防抖
    local finalDir = DirectionSmooth.process(decision, config, rawDir, frame)
    decision.layer = finalDir and layer or "none"
    decision.usedBudgetMs = Isaac.GetTime() - startTime
    -- 仅 Fallback 真正跑过（trace.cand 已填）时留痕，避免梯度层录到陈旧候选
    if trace and trace.cand then
        decision.lastTrace = trace
    end

    return decision.layer, finalDir
end

return Pipeline
