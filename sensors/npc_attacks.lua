-- sensors/npc_attacks.lua
-- NPC 攻击前兆检测（Phase 3.4）
-- 通过动画字符串匹配识别 Boss/NPC 的攻击准备动作，提前生成威胁区域
-- 动画数据库移植自 auto_dodge_helper（~20种关键 Boss 动画，社区验证）
--
-- 工作原理：每帧扫描活跃 NPC，读取当前动画名称（小写），匹配到已知攻击动画时
-- 生成一个"即将发生的威胁区域"条目（带位置/半径/运动方向），喂入追踪器。
-- 决策管线在威胁区域真正造成伤害之前就开始绕开——这就是"提前规避"（原则6）。
--
-- 覆盖的 Boss/NPC（按伤害频率排序）：
--   落点型: Mom's Hand/Dead Hand, Daddy Long Legs (脚/臂/踩踏), Widow, Leaper, Hopper
--   射击型: Horf (蓄力射击)
--   激光型: Vis, Maw, Bloat, Adversary (蓄力激光/Brimstone)
--   跳跃型: Widow/Leaper/Hopper (落地冲击)
-- 未覆盖（Phase 3b 增量扩展）：其他需要动画数据库的 Boss

local NpcAttackSensor = {}

local EntityType = EntityType

-- ===== NPC 类型常量（auto_dodge 验证值）=====
local TYPE_MOMS_HAND = 213
local TYPE_MOMS_DEAD_HAND = 287
local TYPE_DADDYLONGLEGS = 101
local TYPE_WIDOW = 100
local TYPE_LEAPER = 34
local TYPE_HOPPER = 29
local TYPE_HORF = 12
local TYPE_VIS = 246 -- ENTITY_VIS (Isaac variant 246, not nil — 用数值避免 enum 问题)
local TYPE_MAW = 21   -- ENTITY_MAW
local TYPE_BLOAT = 72 -- ENTITY_BLOAT (The Bloat)
local TYPE_ADVERSARY = 273 -- ENTITY_ADVERSARY

-- ===== 威胁配置（auto_dodge CONFIG 值，已验证）=====
local FALLING_IMPACT_RADIUS = 62  -- 妈妈手/脚落点半径
local STOMP_IMPACT_RADIUS = 64    -- Daddy Long Legs 踩踏半径
local JUMP_LANDING_RADIUS = 54    -- Widow/Leaper 落地半径
local SMALL_JUMP_RADIUS = 42      -- Hopper 小跳落地半径
local SHOOTER_WINDUP_RADIUS = 54  -- Horf 蓄力射击半径
local LASER_WINDUP_RADIUS = 28    -- 激光/Brimstone 蓄力半径
local LASER_WINDUP_LENGTH = 480   -- 激光预测长度（像素）
local JUMP_VELOCITY_SCALE = 0.75  -- 跳跃落点速度缩放

-- ===== 动画匹配工具 =====

--- 安全读取动画名称（小写），出错返回""
local function safeAnimationLower(entity)
    local okSprite, sprite = pcall(function() return entity:GetSprite() end)
    if not okSprite or sprite == nil then return "" end
    local okAnim, anim = pcall(function() return sprite:GetAnimation() end)
    if not okAnim or type(anim) ~= "string" then return "" end
    return string.lower(anim)
end

--- 动画字符串包含任一 token
local function hasToken(anim, tokens)
    for i = 1, #tokens do
        if string.find(anim, tokens[i], 1, true) then return true end
    end
    return false
end

-- ===== 攻击判定：返回 {kind, radius, vel?, expands?, ...} 或 nil =====

local function detectAttack(entity)
    local t = entity.Type
    local anim = safeAnimationLower(entity)
    if anim == "" then return nil end

    -- 落点型：妈妈的手
    if t == TYPE_MOMS_HAND then
        if hasToken(anim, {"jumpdown"}) then
            return { kind = "falling_impact", radius = FALLING_IMPACT_RADIUS,
                     pos = entity.Position, vel = Vector(0, 0), speed = 0,
                     expands = true, initialRadius = 6, growthFrames = 12 }
        end
    -- 落点型：妈妈的死手
    elseif t == TYPE_MOMS_DEAD_HAND then
        if hasToken(anim, {"jumpdown"}) then
            return { kind = "falling_impact", radius = FALLING_IMPACT_RADIUS + 4,
                     pos = entity.Position, vel = Vector(0, 0), speed = 0,
                     expands = true, initialRadius = 6, growthFrames = 12 }
        end
    -- 踩踏型：Daddy Long Legs
    elseif t == TYPE_DADDYLONGLEGS then
        if hasToken(anim, {"stompleg", "stomparm", "stomp"}) then
            return { kind = "stomp_impact", radius = STOMP_IMPACT_RADIUS,
                     pos = entity.Position, vel = Vector(0, 0), speed = 0,
                     expands = true, initialRadius = 8, growthFrames = 8 }
        end
    -- 跳跃型：Widow（排除"appear"动画）
    elseif t == TYPE_WIDOW then
        if hasToken(anim, {"jump"}) and not hasToken(anim, {"appear"}) then
            local vel = entity.Velocity * JUMP_VELOCITY_SCALE
            return { kind = "jump_landing", radius = JUMP_LANDING_RADIUS,
                     pos = entity.Position, vel = vel, speed = vel:Length() }
        end
    -- 跳跃型：Leaper/Hopper
    elseif t == TYPE_LEAPER or t == TYPE_HOPPER then
        if hasToken(anim, {"hop", "jump"}) and not hasToken(anim, {"appear"}) then
            local vel = entity.Velocity * JUMP_VELOCITY_SCALE
            return { kind = "jump_landing", radius = t == TYPE_LEAPER and JUMP_LANDING_RADIUS or SMALL_JUMP_RADIUS,
                     pos = entity.Position, vel = vel, speed = vel:Length() }
        end
    -- 射击型：Horf 蓄力
    elseif t == TYPE_HORF then
        if hasToken(anim, {"attack"}) then
            return { kind = "shooter_windup", radius = SHOOTER_WINDUP_RADIUS,
                     pos = entity.Position, vel = Vector(0, 0), speed = 0 }
        end
    -- 激光型：Vis/Maw/Bloat/Adversary 蓄力 Brimstone
    elseif t == TYPE_VIS or t == TYPE_MAW or t == TYPE_BLOAT or t == TYPE_ADVERSARY then
        if hasToken(anim, {"death", "appear"}) then return nil end -- 排除死亡/出现动画
        if hasToken(anim, {"laser", "brim", "beam", "charge"}) then
            -- 激光方向：从 NPC 朝玩家方向预测路径
            local dir = Vector(0, 0)
            local okPlayer, player = pcall(Isaac.GetPlayer, 0)
            if okPlayer and player then
                local delta = player.Position - entity.Position
                if delta:Length() > 1 then dir = delta:Normalized() end
            end
            return { kind = "laser_windup", radius = LASER_WINDUP_RADIUS,
                     pos = entity.Position,
                     vel = dir * LASER_WINDUP_LENGTH, -- 终点偏移
                     speed = 0 }
        end
    end

    return nil
end

-- ===== 采集 =====

--- 采集当帧活跃 NPC 的攻击前兆，喂入追踪器
function NpcAttackSensor.collect(player, tracker, frame, config)
    if not config.hazardNpcAttacks then
        if tracker.count > 0 then tracker:clear() end
        return
    end

    local okAll, entities = pcall(Isaac.GetRoomEntities)
    if not okAll or entities == nil then return end

    local entries = {}
    local count = 0
    for i = 1, #entities do
        local e = entities[i]
        -- 只检查活跃敌方 NPC
        local okNpc, isNpc = pcall(function()
            return e:ToNPC() ~= nil and e:IsActiveEnemy() and not e:IsDead()
                and not e:HasEntityFlags(EntityFlag.FLAG_FRIENDLY)
        end)
        if okNpc and isNpc then
            local okDetect, attack = pcall(detectAttack, e)
            if okDetect and attack then
                count = count + 1
                entries[count] = {
                    index = e.Index + 10000, -- 偏移避免与实体 Index 冲突
                    pos = attack.pos,
                    vel = attack.vel,
                    speed = attack.speed,
                    radius = attack.radius,
                    kind = attack.kind,
                }
            end
        end
    end

    tracker:update(entries, frame, "npc_attack")
end

function NpcAttackSensor.resetRoom()
    -- 无状态，预留接口
end

return NpcAttackSensor
