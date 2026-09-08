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
--- inDangerZone: 当前帧已与威胁重叠（hit=0，如被敌人围住）。
---   此时墙角钳制减半放宽（0.3→0.6）：原则5的本意是"卡墙时让玩家自己挣脱"，
---   但被围+不操作=必掉血，逃命优先（配合 fallback 的远离墙壁偏向选朝房间中心的方向）
local function weightFor(threatLevel, config, wallDist, inDangerZone)
    local maxW = config.maxDodgeWeight

    -- 原则5第二层：靠墙 → 挣脱模式，大幅降权
    if wallDist < config.wallStuckThreshold then
        local cap = config.wallEscapeWeight
        if inDangerZone then
            cap = math.min(config.maxDodgeWeight, cap * 2)
        end
        maxW = math.min(maxW, cap)
    end

    -- S 曲线：从 threatLow 到 threatHigh 平滑爬升
    local t = mathext.remap(threatLevel, config.threatLow, config.threatHigh, 0, 1)
    return mathext.smoothstep(t) * maxW, maxW
end

--- 主入口：合成输出方向
--- playerInput: 玩家原始输入向量（长度0~√2，可为零向量=站立）
--- dodgeDir:    AI闪避方向（归一化）或 nil
--- inDangerZone: 可选，当前帧已与威胁重叠（hit=0），被围时放宽墙角钳制
--- 返回: 合成方向 Vector（长度≤1），本帧权重 w
function InputSynthesizer.synthesize(playerInput, dodgeDir, threatLevel, config, wallDist, inDangerZone)
    -- 无闪避方向或无威胁 → 纯玩家输入
    if not dodgeDir or threatLevel < config.threatLow then
        return playerInput, 0
    end

    local w = weightFor(threatLevel, config, wallDist, inDangerZone)
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
