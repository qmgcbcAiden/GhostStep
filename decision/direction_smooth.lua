-- decision/direction_smooth.lua
-- 方向平滑与防抖（GhostStep escape lock 思路简化版）
-- - 最小保持时间（minHoldFrames）内不换方向
-- - 换方向时按 smoothFrames 指数插值，避免抖动
-- - 无低通滤波堆积延迟（糟粕：GhostStep 越叠越钝）

local DirectionSmooth = {}

local mathext = require("utils/math_ext")

--- 处理一帧决策方向
--- 返回本帧实际使用的方向（Vector 或 nil）
function DirectionSmooth.process(decision, config, rawDir, frame)
    if not rawDir then
        -- 无方向：清状态，权重自然回落（合成层处理）
        decision.dodgeDir = nil
        decision.dodgeDirPrev = nil
        decision.holdFramesLeft = 0
        return nil
    end

    -- 最小保持：换向前必须保持 N 帧，防止逐帧翻转抖动
    if decision.holdFramesLeft > 0 and decision.dodgeDir then
        local changed = false
        if decision.dodgeDir:Length() > 0.01 and rawDir:Length() > 0.01 then
            local dot = mathext.dot(decision.dodgeDir:Normalized(), rawDir:Normalized())
            if dot < 0.5 then changed = true end -- 夹角>60°视为换方向
        end
        if not changed then
            decision.holdFramesLeft = config.minHoldFrames
        else
            decision.holdFramesLeft = decision.holdFramesLeft - 1
        end
        -- 保持期内继续用旧方向
        return decision.dodgeDir
    end

    -- 平滑插值到新方向
    local smoothFrames = math.max(1, config.directionSmoothFrames)
    local alpha = 1 / smoothFrames
    local prev = decision.dodgeDir
    local smoothed
    if prev and prev:Length() > 0.01 then
        smoothed = prev * (1 - alpha) + rawDir * alpha
        if smoothed:Length() > 0.01 then
            smoothed = smoothed:Normalized()
        else
            smoothed = rawDir:Normalized()
        end
    else
        smoothed = rawDir:Normalized()
    end

    decision.dodgeDirPrev = prev
    decision.dodgeDir = smoothed
    decision.holdFramesLeft = config.minHoldFrames
    return smoothed
end

return DirectionSmooth
