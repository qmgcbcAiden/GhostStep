-- utils/math_ext.lua
-- 数学扩展：叉积、平滑、重映射、平滑衰减
-- 所有函数纯函数，无状态

local MathExt = {}

--- 叉积（二维标量叉积）
function MathExt.cross(a, b)
    return a.X * b.Y - a.Y * b.X
end

--- 点积
function MathExt.dot(a, b)
    return a.X * b.X + a.Y * b.Y
end

--- 限制到 [min, max]
function MathExt.clamp(v, min, max)
    if v < min then return min end
    if v > max then return max end
    return v
end

--- 线性重映射：将 v 从 [inMin, inMax] 映射到 [outMin, outMax]，自动钳位
function MathExt.remap(v, inMin, inMax, outMin, outMax)
    if inMax <= inMin then return outMin end
    local t = (v - inMin) / (inMax - inMin)
    t = MathExt.clamp(t, 0, 1)
    return outMin + (outMax - outMin) * t
end

--- smoothstep 平滑阶梯（Hermite 插值），x 自动钳位到 [0,1]
function MathExt.smoothstep(x)
    x = MathExt.clamp(x, 0, 1)
    return x * x * (3 - 2 * x)
end

--- 指数移动平均（EMA）
function MathExt.ema(prev, new, alpha)
    return prev + (new - prev) * alpha
end

--- 方向向量的平滑过渡：按角度插值，避免 180° 翻转抖动
--- 返回新 Vector
function MathExt.slerpFlat(from, to, t)
    local len = from:Length() * (1 - t) + to:Length() * t
    if len < 0.001 then return Vector(0, 0) end
    local merged = from * (1 - t) + to * t
    if merged:Length() < 0.001 then return Vector(0, 0) end
    return merged:Normalized() * len
end

--- 最短角度差 [-pi, pi]
function MathExt.angleDelta(a, b)
    local d = (b - a) % (2 * math.pi)
    if d > math.pi then d = d - 2 * math.pi end
    return d
end

return MathExt
