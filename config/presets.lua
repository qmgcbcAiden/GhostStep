-- config/presets.lua
-- 预设档位：安全 / 平衡 / 激进，一键切换一组相关参数

local Presets = {}

-- 每个预设只覆盖与档位相关的参数，其余维持当前值
Presets.list = {
    {
        name = "安全",
        maxDodgeWeight = 0.70,       -- 更保守的 AI 介入
        anticipateStrength = 7,      -- 更强的提前规避
        threatMedium = 0.40,         -- 更早进入规避
        wallStuckThreshold = 55,     -- 更敏感的墙角检测
        directionSmoothFrames = 5,   -- 更平滑
    },
    {
        name = "平衡",
        maxDodgeWeight = 0.85,
        anticipateStrength = 5,
        threatMedium = 0.45,
        wallStuckThreshold = 40,
        directionSmoothFrames = 3,
    },
    {
        name = "激进",
        maxDodgeWeight = 0.95,
        anticipateStrength = 3,      -- 更依赖紧急闪避
        threatMedium = 0.50,         -- 更晚介入，更贴玩家意图
        wallStuckThreshold = 30,
        directionSmoothFrames = 2,   -- 更快响应
    },
}

--- 应用预设到 Config（返回被覆盖的旧值，供 MCM 显示）
function Presets.apply(config, index)
    local preset = Presets.list[index]
    if not preset then return nil end
    local old = {}
    for k, v in pairs(preset) do
        if k ~= "name" and config[k] ~= nil then
            old[k] = config[k]
            config[k] = v
        end
    end
    return old
end

function Presets.getName(index)
    local p = Presets.list[index]
    return p and p.name or "?"
end

return Presets
