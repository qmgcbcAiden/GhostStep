-- sensors/bombs.lua
-- 炸弹威胁采集（Phase 3.2）
-- 炸弹 = 引信倒计时后爆炸的圆形威胁
-- 危险模型：frameCount >= bombDangerFrameStart 后视为危险（auto_dodge: 120帧≈4秒）
-- 爆炸半径 = 90px × RadiusMultiplier，投掷中的炸弹用 vel 外推位置

local BombSensor = {}

local EntityType = EntityType

local BOMB_DANGER_FRAME = 120 -- 引信开始危险的帧数（auto_dodge 验证值）
local BOMB_FUSE_TOTAL = 150   -- 普通炸弹总引信时长（帧，~5秒@30fps）
local BOMB_EXPLOSION_RADIUS = 90 -- 基础爆炸半径（像素）

--- 是否为敌方炸弹
local function isHostileBomb(e)
    if e.Type ~= EntityType.ENTITY_BOMB then return false end
    local st = e.SpawnerType or 0
    if st == EntityType.ENTITY_PLAYER or st == EntityType.ENTITY_FAMILIAR then
        return false
    end
    return true
end

local function safeGet(entity, getter, fallback)
    local ok, v = pcall(getter, entity)
    if ok and v ~= nil then return v end
    return fallback
end

--- 采集当帧敌方炸弹并喂给追踪器
function BombSensor.collect(player, tracker, frame, config)
    if not config.hazardBombs then
        if tracker.count > 0 then tracker:clear() end
        return
    end

    local okFind, entities = pcall(Isaac.FindByType, EntityType.ENTITY_BOMB, -1, -1, false)
    if not okFind or entities == nil then return end

    local entries = {}
    local count = 0
    for i = 1, #entities do
        local e = entities[i]
        if isHostileBomb(e) then
            local isDead = safeGet(e, function(x) return x:IsDead() end, true)
            if not isDead then
                -- 引信检查：太早的炸弹不算威胁（auto_dodge 模式）
                local fc = safeGet(e, function(x) return x.FrameCount or 0 end, 0)
                if fc >= BOMB_DANGER_FRAME then
                    count = count + 1
                    local bomb = safeGet(e, function(x) return x:ToBomb() end, nil)
                    local radiusMul = 1
                    local explosionDamage = 12
                    if bomb then
                        radiusMul = safeGet(bomb, function(b) return b.RadiusMultiplier or 1 end, 1)
                        explosionDamage = safeGet(bomb, function(b) return b.ExplosionDamage or 12 end, 12)
                    end
                    entries[count] = {
                        index = e.Index,
                        pos = e.Position,
                        vel = e.Velocity,
                        speed = e.Velocity:Length(),
                        radius = BOMB_EXPLOSION_RADIUS * radiusMul,
                        kind = "bomb",
                        damage = explosionDamage,
                        -- 引信剩余帧估算：总长 150 帧 - 已燃帧数（clamp≥0）。
                        -- Rep+ 无社区验证的倒计时 API，FrameCount 推算已够威胁分级用
                        fuseFrames = math.max(0, BOMB_FUSE_TOTAL - fc),
                    }
                end
            end
        end
    end

    tracker:update(entries, frame, "bomb")
end

return BombSensor
