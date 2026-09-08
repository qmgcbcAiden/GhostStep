-- render/overlay.lua
-- 调试渲染总控（用 renderCount，不用 updateCount —— 模式7）
-- 内容: 威胁等级条 / 闪避方向箭头 / AI权重 / 启用状态提示
-- 纯净模式(pureMode) 或 renderEnabled=false 时全部关闭

local Overlay = {}

local mathext = require("utils/math_ext")

--- 渲染主入口（MC_POST_RENDER 每帧调用）
--- mod 参数预留（Sprite/字体资源挂载用）
function Overlay.render(state, mod, frame)
    local config = state.config
    if config.pureMode or not config.renderEnabled then
        -- REC 指示与状态提示独立于视觉总开关（但受纯净模式压制）
        Overlay.renderRec(state)
        Overlay.renderToast(state)
        return
    end

    local player = state.player
    if not player.valid then return end

    if config.renderThreatBar then Overlay.renderThreatBar(state) end
    if config.renderDodgeArrow then Overlay.renderDodgeArrow(state, mod) end
    if config.renderWeight then Overlay.renderWeight(state) end
    if config.renderGradient then Overlay.renderGradient(state, mod) end

    Overlay.renderRec(state)
    Overlay.renderToast(state)
end

--- REC 录制指示（屏幕右下角，录制开启时可见——让"有没有在录"一目了然）
function Overlay.renderRec(state)
    local config = state.config
    if not config.recordingEnabled then return end
    local n = state.ringBuffer and state.ringBuffer.count or 0
    -- 帧号闪烁做呼吸效果（区分于静态 UI）
    local blink = (state.renderCount % 60) < 40
    local alpha = blink and 0.8 or 0.35
    local label = "REC " .. n
    local x = Isaac.GetScreenWidth() - 70
    local y = Isaac.GetScreenHeight() - 22
    Isaac.RenderText(label, x, y, 1, 0.25, 0.25, alpha)
end

--- 威胁等级条（屏幕左下角）
function Overlay.renderThreatBar(state)
    local level = state.threat.level
    local x, y = 30, Isaac.GetScreenHeight() - 50
    local w = 120

    -- 颜色: 绿→黄→红
    local r = mathext.clamp(level * 2, 0, 1)
    local g = mathext.clamp(2 - level * 2, 0, 1)
    Isaac.RenderText("THREAT", x, y - 14, 0.6, 0.6, 0.6, 0.8)
    for i = 0, w, 2 do
        local frac = i / w
        if frac <= level then
            Isaac.RenderText("|", x + i, y, r, g, 0.1, 0.9)
        else
            Isaac.RenderText("|", x + i, y, 0.2, 0.2, 0.2, 0.4)
        end
    end
end

--- 闪避方向箭头（世界坐标→屏幕坐标画在玩家旁）
function Overlay.renderDodgeArrow(state, mod)
    local decision = state.decision
    if not decision.dodgeDir then return end
    local pos = Isaac.WorldToScreen(state.player.position)
    local dir = decision.dodgeDir
    -- 箭头: 从玩家位置延伸 30px
    local tip = pos + dir * 40
    for i = 0, 10 do
        local p = pos + dir * (i * 4)
        Isaac.RenderText("+", p.X, p.Y, 0.3, 0.9, 1.0, 0.8)
    end
    Isaac.RenderText(">", tip.X, tip.Y, 0.3, 0.9, 1.0, 1.0)
end

--- AI 权重显示（威胁条下方）
function Overlay.renderWeight(state)
    local w = state.control.weight
    local layer = state.decision.layer
    local x, y = 30, Isaac.GetScreenHeight() - 26
    local label = string.format("AI %.0f%% [%s]", w * 100, layer)
    local alpha = w > 0 and 0.95 or 0.4
    Isaac.RenderText(label, x, y, 0.9, 0.9, 0.3, alpha)
end

--- 弹幕场梯度可视化（渐变方向线）
function Overlay.renderGradient(state, mod)
    local dir = state.threat.gradientDir
    if not dir then return end
    local pos = Isaac.WorldToScreen(state.player.position)
    for i = 2, 8 do
        local p = pos + dir * (i * 12)
        Isaac.RenderText(".", p.X, p.Y, 0.5, 1.0, 0.5, 0.7)
    end
end

--- ALT 切换提示（toast，1.5秒后消失）
function Overlay.renderToast(state)
    local now = state.renderCount
    if now > state.statusToastUntil then return end
    local remain = state.statusToastUntil - now
    local alpha = math.min(1, remain / 30)
    local msg = state.userEnabled and "GhostStep: ON" or "GhostStep: OFF"
    local x = (Isaac.GetScreenWidth() - #msg * 7) / 2
    Isaac.RenderText(msg, x, 60, 1, 1, 1, alpha)
end

return Overlay
