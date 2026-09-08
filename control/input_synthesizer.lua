-- control/input_synthesizer.lua
-- ★ 叠加偏移合成（核心创新，4.2/4.5节）
--
--   output = normalize(P * (1-w) + D * w)
--
--   P = 玩家输入方向, D = AI闪避方向, w = S曲线映射的权重
--   硬约束:
--     原则2: w ≤ MAX_DODGE_WEIGHT (0.85)，弹幕再多也不突破
--     原则5: 靠墙时 w 上限降到 0.3（挣脱模式）
--     原则7: 权重本身即幅度控制器，不设硬性角度限制

local InputSynthesizer = {}

local mathext = require("utils/math_ext")

--- 权重 S 曲线映射（4.5节）
--- threatLevel → w ∈ [0, maxW]
local function weightFor(threatLevel, config, wallDist)
    local maxW = config.maxDodgeWeight

    -- 原则5第二层：靠墙 → 挣脱模式，大幅降权
    if wallDist < config.wallStuckThreshold then
        maxW = math.min(maxW, config.wallEscapeWeight)
    end

    -- S 曲线：从 threatLow 到 threatHigh 平滑爬升
    local t = mathext.remap(threatLevel, config.threatLow, config.threatHigh, 0, 1)
    return mathext.smoothstep(t) * maxW, maxW
end

--- 主入口：合成输出方向
--- playerInput: 玩家原始输入向量（长度0~√2，可为零向量=站立）
--- dodgeDir:    AI闪避方向（归一化）或 nil
--- 返回: 合成方向 Vector（长度≤1），本帧权重 w
function InputSynthesizer.synthesize(playerInput, dodgeDir, threatLevel, config, wallDist)
    -- 无闪避方向或无威胁 → 纯玩家输入
    if not dodgeDir or threatLevel < config.threatLow then
        return playerInput, 0
    end

    local w, cappedMax = weightFor(threatLevel, config, wallDist)
    if w <= 0 then
        return playerInput, 0
    end

    -- 归一化玩家输入方向（保留力度概念：站立时 P=0，只受 AI 推动）
    local P = playerInput
    if P:Length() > 1.001 then
        P = P:Normalized()
    end
    local D = dodgeDir

    -- 合成（4.2公式）
    local combined = P * (1 - w) + D * w

    -- 归一化保持移动速度
    -- 站立时(P=0) 输出 AI 方向满速；有输入时输出方向归一化（力度=1）
    local len = combined:Length()
    if len > 0.01 then
        combined = combined:Normalized()
    else
        combined = D
    end

    return combined, w
end

return InputSynthesizer
