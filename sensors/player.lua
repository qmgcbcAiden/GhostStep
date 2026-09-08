-- sensors/player.lua
-- 玩家状态采集（P1 only，确认决策：不做联机）
-- 注意：真正的输入方向在决策阶段通过 Input API 读取，这里只采集物理状态

local PlayerSensor = {}

function PlayerSensor.create()
    return {}
end

--- 采集玩家状态到 state.player
--- 返回玩家实体（无效时 nil）
function PlayerSensor.collect(state, frame)
    local game = Game()
    if game:GetNumPlayers() < 1 then
        state.player.valid = false
        return nil
    end

    -- 只处理 P1
    local player = Isaac.GetPlayer(0)
    if not player or player.Parent ~= nil then
        state.player.valid = false
        return nil
    end

    local p = state.player
    p.valid = true
    p.controllerIndex = player.ControllerIndex
    p.canFly = player.CanFly or player:IsFlying()
    p.position = player.Position
    p.velocity = player.Velocity
    p.radius = player.Size
    -- 注: Rep+ 无 EntityPlayer:IsDamageEnabled()；无敌状态检测留给 Phase 3（EntityFlags）

    return player
end

return PlayerSensor
