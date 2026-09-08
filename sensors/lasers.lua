-- sensors/lasers.lua
-- 激光威胁采集（Phase 3.1）
-- 激光 = 线段威胁，不同于弹幕的圆威胁
-- 几何模型：起点→终点线段，碰撞 = 点到线段距离 ≤ 激光半径+玩家半径
-- API 来源：auto_dodge_helper 验证过的 EntityLaser 属性（pcall 包裹 GetEndPoint）

local LaserSensor = {}

local EntityType = EntityType

--- 是否为敌方激光（排除玩家/跟班发射）
local function isHostileLaser(e)
    if e.Type ~= EntityType.ENTITY_LASER then return false end
    -- 玩家/跟班发射的跳过
    local st = e.SpawnerType or 0
    if st == EntityType.ENTITY_PLAYER or st == EntityType.ENTITY_FAMILIAR then
        return false
    end
    return true
end

--- 安全读取属性（pcall 防御，出错返回 fallback）
local function safeGet(entity, getter, fallback)
    local ok, v = pcall(getter, entity)
    if ok and v ~= nil then return v end
    return fallback
end

--- 采集当帧敌方激光并喂给追踪器
-- 激光的几何信息存储在 entry 的特殊字段：
--   entry.kind = "laser"
--   entry.pos = 起点
--   entry.vel = 方向×长度（作为终点偏移代理；静态激光vel=0，退化为圆碰撞）
--   entry.radius = 激光宽度/2
function LaserSensor.collect(player, tracker, frame, config)
    if not config.hazardLasers then
        if tracker.count > 0 then tracker:clear() end
        return
    end

    local okFind, entities = pcall(Isaac.FindByType, EntityType.ENTITY_LASER, -1, -1, false)
    if not okFind or entities == nil then return end

    local entries = {}
    local count = 0
    for i = 1, #entities do
        local e = entities[i]
        if isHostileLaser(e) then
            local isDead = safeGet(e, function(x) return x:IsDead() end, true)
            if not isDead then
                count = count + 1
                local laser = safeGet(e, function(x) return x:ToLaser() end, nil)
                local radius = 6 -- 默认宽度/2
                if laser then
                    radius = safeGet(laser, function(l) return l.Radius or 6 end, 6)
                end
                -- 激光方向/终点：用 Position + AngleDegrees × Length 估算
                -- 有 vel 的激光（扫描型）直接用 vel
                entries[count] = {
                    index = e.Index,
                    pos = e.Position,
                    vel = e.Velocity, -- 扫描/移动激光有速度
                    speed = e.Velocity:Length(),
                    radius = radius,
                    kind = "laser",
                }
            end
        end
    end

    tracker:update(entries, frame, "laser")
end

return LaserSensor
