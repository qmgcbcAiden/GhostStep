-- sensors/enemies.lua
-- 敌人接触威胁采集（用户点名的"碰撞"伤害）
-- 敌人本体 = 移动威胁圆：喂给追踪器后，闭式碰撞解与密度梯度场直接复用
-- 判定模式参考 autoaim（IsActiveEnemy/IsDead/FLAG_FRIENDLY 为已验证 API），
-- 但不做 IsVulnerable/IsInvincible 过滤——无敌敌人（龟缩Host等）仍可能有接触伤害，
-- 威胁检测安全优先

local EnemySensor = {}

local _enemyLoggedThisRoom = false
local _enemyLastCount = -1

-- 特殊实体类型（auto_dodge 验证值）
local TYPE_ULTRA_GREED_COIN = 293 -- Ultra Greed 扔的硬币，有接触伤害
local TYPE_WIZOOB = 219           -- 幽灵敌人，appear 动画时无接触伤害

--- 安全读取动画名称（小写）
local function safeAnimLower(entity)
    local ok, sprite = pcall(function() return entity:GetSprite() end)
    if not ok or sprite == nil then return "" end
    local ok2, anim = pcall(function() return sprite:GetAnimation() end)
    if ok2 and type(anim) == "string" then return string.lower(anim) end
    return ""
end

--- 是否为接触威胁（活着且有敌意的 NPC 本体）
local function isContactThreat(e)
    -- 特殊类型：Ultra Greed 硬币直接视为接触威胁（可能没有 ToNPC）
    if e.Type == TYPE_ULTRA_GREED_COIN then
        local okDead, dead = pcall(function() return e:IsDead() end)
        return not (okDead and dead)
    end

    local okNpc, npc = pcall(function() return e:ToNPC() end)
    if not okNpc or npc == nil then return false end

    local okDead, dead = pcall(function() return e:IsDead() end)
    if okDead and dead then return false end

    -- Wizoob 出现动画免疫（幽灵传送出现时不造成接触伤害）
    if e.Type == TYPE_WIZOOB then
        local anim = safeAnimLower(e)
        if string.find(anim, "appear", 1, true) then return false end
    end

    -- 非活跃敌人（死亡动画/被清除中）排除；API 不可用时不过滤（安全优先）
    local okActive, active = pcall(function() return e:IsActiveEnemy() end)
    if okActive and active == false then return false end

    -- 被魅惑/友方化的敌人不具威胁
    local okFriendly, friendly = pcall(function()
        return e:HasEntityFlags(EntityFlag.FLAG_FRIENDLY)
    end)
    if okFriendly and friendly then return false end

    return true
end

--- 采集当帧接触威胁并喂给追踪器（kind=enemy，过期10帧）
function EnemySensor.collect(player, tracker, frame, config)
    if not config.hazardContact then
        if tracker.count > 0 then tracker:clear() end
        return
    end

    local okAll, entities = pcall(Isaac.GetRoomEntities)
    if not okAll or entities == nil then return end

    local entries = {}
    local count = 0
    for i = 1, #entities do
        local e = entities[i]
        if isContactThreat(e) then
            count = count + 1
            entries[count] = {
                index = e.Index,
                pos = e.Position,
                vel = e.Velocity,
                speed = e.Velocity:Length(),
                radius = e.Size,
                -- 接触伤害值（auto_dodge: entity.CollisionDamage or 1；读不到按 1 保守处理）
                damage = (function()
                    local okCd, cd = pcall(function() return e.CollisionDamage end)
                    if okCd and type(cd) == "number" and cd > 0 then return cd end
                    return 1
                end)(),
            }
        end
    end

    -- 诊断：只在敌人数变化时打日志（0→N，N→0），避免刷屏
    if not _enemyLoggedThisRoom or count ~= (_enemyLastCount or 0) then
        Isaac.DebugString(string.format(
            "[GhostStep3] 敌人采集: GetRoomEntities=%d 接触威胁=%d 帧=%d",
            #entities, count, frame))
        _enemyLoggedThisRoom = true
        _enemyLastCount = count
    end

    tracker:update(entries, frame, "enemy")
end

function EnemySensor.resetRoom()
    _enemyLoggedThisRoom = false
    _enemyLastCount = -1
end

return EnemySensor
