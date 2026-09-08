-- control/input_reader.lua
-- 读取玩家原始输入（键盘+手柄统一处理）
-- 手柄摇杆通过连续值自然支持：优先用摇杆模拟值，退化为按键判定

local InputReader = {}

local ButtonAction = ButtonAction

--- 是否为移动类动作（MC_INPUT_ACTION 判定用）
function InputReader.isMoveAction(action)
    return action == ButtonAction.ACTION_LEFT
        or action == ButtonAction.ACTION_RIGHT
        or action == ButtonAction.ACTION_UP
        or action == ButtonAction.ACTION_DOWN
end

--- 方向 → 轴值（7.5.1）。含死区处理
local DEADZONE = 0.2
function InputReader.actionValue(action, dir)
    local x, y = dir.X, dir.Y
    if action == ButtonAction.ACTION_LEFT then
        return (x < -DEADZONE) and math.min(1, -x) or 0
    elseif action == ButtonAction.ACTION_RIGHT then
        return (x > DEADZONE) and math.min(1, x) or 0
    elseif action == ButtonAction.ACTION_UP then
        return (y < -DEADZONE) and math.min(1, -y) or 0
    elseif action == ButtonAction.ACTION_DOWN then
        return (y > DEADZONE) and math.min(1, y) or 0
    end
    return 0
end

--- 读取玩家当前移动输入向量（-1..1 每轴，含摇杆力度）
function InputReader.readMoveVector(controllerIndex)
    local x = Input.GetActionValue(ButtonAction.ACTION_LEFT, controllerIndex) * -1
        + Input.GetActionValue(ButtonAction.ACTION_RIGHT, controllerIndex)
    local y = Input.GetActionValue(ButtonAction.ACTION_UP, controllerIndex) * -1
        + Input.GetActionValue(ButtonAction.ACTION_DOWN, controllerIndex)
    return Vector(x, y)
end

return InputReader
