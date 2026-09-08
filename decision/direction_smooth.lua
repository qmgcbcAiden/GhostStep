-- 兼容旧调用的幅度平滑。主规划器直接验证最终输入，不再后处理方向。
local Smooth = {}
function Smooth.process(decision, config, raw, frame)
    local prev = decision.dodgeDir
    if not raw or raw:Length() < 0.01 then
        decision.dodgeDir, decision.dodgeDirPrev = raw, nil
        decision.holdFramesLeft = 0
        return raw
    end
    local alpha = 1 / math.max(1, config.directionSmoothFrames or 1)
    local nextDir = prev and (prev * (1 - alpha) + raw * alpha) or raw
    -- 不在插值后归一化，否则 180 度换向会永久锁在旧方向。
    decision.dodgeDirPrev, decision.dodgeDir = prev, nextDir
    decision.holdFramesLeft = 0
    return nextDir
end
return Smooth
