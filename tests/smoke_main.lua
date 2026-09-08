-- tests/smoke_main.lua
-- 冒烟测试主体：加载各模块并模拟数据流
-- 前置: tests/smoke.lua 已注入模拟 Isaac 环境

local results = {}
local failures = 0

local function check(name, fn)
    local ok, err = pcall(fn)
    if ok then
        results[#results + 1] = "PASS " .. name
    else
        failures = failures + 1
        results[#results + 1] = "FAIL " .. name .. " :: " .. tostring(err)
    end
end

-- ===== Vector 基础 =====
check("vector ops", function()
    local a = Vector(3, 4)
    assert(a:Length() == 5, "length")
    local n = a:Normalized()
    assert(math.abs(n.X - 0.6) < 0.001 and math.abs(n.Y - 0.8) < 0.001, "normalized")
    assert((Vector(1, 0) + Vector(0, 1)):Length() == math.sqrt(2), "add")
    assert((Vector(1, 2) * 3).X == 3, "mul")
end)

-- ===== math_ext =====
local mathext = require("utils/math_ext")
check("math_ext", function()
    assert(mathext.clamp(5, 0, 1) == 1)
    assert(mathext.clamp(-1, 0, 1) == 0)
    assert(mathext.remap(0.5, 0, 1, 0, 10) == 5)
    assert(mathext.smoothstep(0) == 0 and mathext.smoothstep(1) == 1)
    assert(mathext.dot(Vector(1, 0), Vector(0, 1)) == 0)
    assert(mathext.cross(Vector(1, 0), Vector(0, 1)) == 1)
end)

-- ===== tracker =====
local Tracker = require("entities/tracker")
check("tracker update+expiry+history", function()
    local t = Tracker.create()
    t:update({ { index = 1, pos = Vector(0, 0), vel = Vector(1, 0), speed = 1, radius = 5 } }, 100, "projectile")
    assert(t.count == 1, "count after add")
    t:update({ { index = 1, pos = Vector(10, 0), vel = Vector(1, 0), speed = 1, radius = 5 } }, 101, "projectile")
    local hist = t:getHistory(1)
    assert(hist and #hist == 2, "history len=" .. tostring(hist and #hist))
    assert(hist[1].pos.X == 0 and hist[2].pos.X == 10, "history order")
    -- 过期: 6帧未见
    t:update({}, 108, "projectile")
    assert(t.count == 0, "expired")
end)

check("tracker ring history >10", function()
    local t = Tracker.create()
    for f = 1, 15 do
        t:update({ { index = 1, pos = Vector(f, 0), vel = Vector(1, 0), speed = 1, radius = 5 } }, f, "projectile")
    end
    local hist = t:getHistory(1)
    assert(#hist == 10, "capped at 10, got " .. #hist)
    assert(hist[1].pos.X == 6, "oldest kept = frame6, got " .. hist[1].pos.X)
    assert(hist[10].pos.X == 15, "newest = frame15")
end)

-- ===== ring buffer =====
local RingBuffer = require("recording/ring_buffer")
check("ring buffer", function()
    local rb = RingBuffer.create(5)
    for i = 1, 8 do
        rb:push({ frame = i, threat = i / 10 })
    end
    assert(rb.count == 5, "count capped: " .. rb.count)
    local recent = rb:getRecent(3)
    assert(#recent == 3 and recent[1].frame == 6 and recent[3].frame == 8, "recent order")
    assert(rb:getFrame(7) ~= nil and rb:getFrame(2) == nil, "getFrame")
end)

-- ===== spatial =====
local Spatial = require("threat/spatial")
check("spatial buckets", function()
    local grid = Spatial.build({
        { pos = Vector(0, 0), vel = Vector(1, 0), speed = 1, radius = 5 },
        { pos = Vector(500, 500), vel = Vector(0, 1), speed = 1, radius = 5 },
    })
    local near = Spatial.queryNear(grid, Vector(10, 10))
    assert(#near == 1, "near count: " .. #near)
    local near2 = Spatial.queryNear(grid, Vector(490, 490))
    assert(#near2 == 1, "far bucket: " .. #near2)
end)

-- ===== predict =====
local Predict = require("threat/projectile_predict")
check("predict timeToHit", function()
    -- 弹幕从(100,0)向左飞行 v=(-5,0)，玩家在(50,0) r=10, 弹幕r=5 → combined=15
    -- 相对距离50, 相对速度+5/s朝玩家 → t = (50-15)/5 = 7
    local t = Predict.timeToHit(
        { pos = Vector(100, 0), vel = Vector(-5, 0), radius = 5 },
        Vector(50, 0), 10, 28)
    assert(math.abs(t - 7) < 0.01, "t=" .. tostring(t))
    -- 不相交
    local t2 = Predict.timeToHit(
        { pos = Vector(100, 100), vel = Vector(0, 5), radius = 5 },
        Vector(50, 0), 10, 28)
    assert(t2 == nil, "no hit")
end)

-- ===== threat level（模拟弹幕接近场景）=====
mock = mock or {}
local ThreatLevel = require("threat/threat_level")
local HazardQuery = require("threat/hazard_query")
local Tracker2 = require("entities/tracker")
local Terrain = require("sensors/terrain")

check("threat level collision urgency", function()
    local tracker = Tracker2.create()
    -- 弹幕朝玩家飞来，4帧后命中 → urgency > 0.8
    tracker:update({ { index = 1, pos = Vector(100, 0), vel = Vector(-20, 0), speed = 20, radius = 8 } }, 0, "projectile")
    local hq = HazardQuery.create()
    local hazards = tracker:getActive(2, 0)
    hq:update(hazards)

    local config = require("config/defaults").get()
    local state = {
        player = { position = Vector(20, 0), velocity = Vector(0, 0), radius = 10 },
        threat = {},
    }
    local terrain = Terrain.create()
    local emptyTracker = Tracker2.create()
    ThreatLevel.evaluate(state, {
        config = config, tracker = tracker, trackerEnemies = emptyTracker,
        getHazards = function() return tracker:getActive(2, 0) end,
        hazardQuery = hq, terrain = terrain,
    }, 0)
    assert(state.threat.collisionUrgency >= 0.8,
        "urgency=" .. tostring(state.threat.collisionUrgency))
    assert(state.threat.level >= 0.8, "level=" .. tostring(state.threat.level))
end)

check("threat level gradient", function()
    local tracker = Tracker2.create()
    -- 弹幕集中在玩家右侧 → 梯度规避方向应朝左
    tracker:update({
        { index = 1, pos = Vector(60, 0), vel = Vector(0, 0), speed = 0, radius = 8 },
        { index = 2, pos = Vector(70, 10), vel = Vector(0, 0), speed = 0, radius = 8 },
        { index = 3, pos = Vector(65, -10), vel = Vector(0, 0), speed = 0, radius = 8 },
    }, 0, "projectile")
    local hq = HazardQuery.create()
    local config = require("config/defaults").get()
    local state = {
        player = { position = Vector(0, 0), velocity = Vector(0, 0), radius = 10 },
        threat = {},
    }
    ThreatLevel.evaluate(state, {
        config = config, tracker = tracker, trackerEnemies = Tracker2.create(),
        getHazards = function() return tracker:getActive(2, 0) end,
        hazardQuery = hq,
        terrain = Terrain.create(),
    }, 0)
    local g = state.threat.gradientDir
    assert(g, "gradient should exist")
    assert(g.X < -0.5, "avoidance points left, got " .. tostring(g.X))
    assert(state.threat.densityScore > 0, "density > 0")
end)

-- ===== input synthesizer（核心公式）=====
local InputSynthesizer = require("control/input_synthesizer")
local config = require("config/defaults").get()

check("synth: no threat returns player input", function()
    local out, w = InputSynthesizer.synthesize(Vector(1, 0), Vector(0, 1), 0.1, config, 999)
    assert(out.X == 1 and w == 0, "passthrough")
end)

check("synth: max threat respects 0.85 cap", function()
    local out, w = InputSynthesizer.synthesize(Vector(1, 0), Vector(-1, 0), 1.0, config, 999)
    assert(w <= 0.85 + 0.0001, "w=" .. tostring(w))
    -- P=(1,0) w=0.85 D=(-1,0): combined = 0.15*(1,0) + 0.85*(-1,0) = (-0.7, 0) → 归一化(-1,0)
    assert(out.X < -0.99, "direction=" .. tostring(out.X))
end)

check("synth: wall escape clamps to 0.3", function()
    local _, w = InputSynthesizer.synthesize(Vector(1, 0), Vector(-1, 0), 1.0, config, 10)
    assert(w <= 0.3 + 0.0001, "w=" .. tostring(w))
end)

check("synth: standing player gets pure dodge", function()
    local out, w = InputSynthesizer.synthesize(Vector(0, 0), Vector(0, 1), 0.9, config, 999)
    assert(w > 0, "weight")
    assert(out.Y > 0.99, "pushed down: " .. tostring(out.Y))
end)

check("synth: partial threat partial weight", function()
    local _, w = InputSynthesizer.synthesize(Vector(1, 0), Vector(0, 1), 0.45, config, 999)
    assert(w > 0 and w < 0.85, "middle weight w=" .. tostring(w))
end)

-- ===== direction smooth =====
local DirectionSmooth = require("decision/direction_smooth")
check("direction smooth anti-flip", function()
    local decision = { dodgeDir = nil, holdFramesLeft = 0 }
    local d1 = DirectionSmooth.process(decision, config, Vector(1, 0), 1)
    assert(d1.X > 0.9, "first dir")
    -- 试图翻转到反方向 → 保持期内仍用旧方向
    local d2 = DirectionSmooth.process(decision, config, Vector(-1, 0), 2)
    assert(d2.X > 0.9, "hold: still right, got " .. tostring(d2.X))
end)

-- ===== fallback =====
local Fallback = require("decision/fallback")
check("fallback avoids incoming projectile", function()
    local tracker = Tracker2.create()
    tracker:update({ { index = 1, pos = Vector(60, 0), vel = Vector(-10, 0), speed = 10, radius = 8 } }, 0, "projectile")
    local state = {
        player = { position = Vector(0, 0), velocity = Vector(0, 0), radius = 10,
                   inputDir = Vector(1, 0) },
        decision = {},
        threat = {}, -- 新版 fallback 读取 threat.gradientDir
    }
    local terrain = Terrain.create()
    local dir = Fallback.compute(state, {
        config = config, tracker = tracker,
        getHazards = function() return tracker:getActive(2, 0) end,
        hazardQuery = nil, terrain = terrain,
    }, 0)
    assert(dir, "produced direction")
    -- 弹幕从右飞来：应该垂直逃离（向上或向下），而不是朝右迎弹
    assert(math.abs(dir.Y) > 0.7 or dir.X < 0, "escape dir: " .. tostring(dir.X) .. "," .. tostring(dir.Y))
end)

-- ===== early dodge =====
local EarlyDodge = require("decision/early_dodge")
check("early dodge perpendicular", function()
    local dir = EarlyDodge.compute(
        { pos = Vector(100, 5), vel = Vector(-20, 0), radius = 8 },
        Vector(0, 0))
    assert(dir, "computed")
    assert(math.abs(dir.X) < 0.1, "perpendicular X~0: " .. tostring(dir.X))
    assert(dir.Y > 0.9 or dir.Y < -0.9, "vertical: " .. tostring(dir.Y))
end)

-- ===== pipeline end-to-end =====
local Pipeline = require("decision/pipeline")
check("pipeline: gradient layer at low-mid threat", function()
    local tracker = Tracker2.create()
    tracker:update({
        { index = 1, pos = Vector(70, 0), vel = Vector(0, 0), speed = 0, radius = 8 },
        { index = 2, pos = Vector(75, 5), vel = Vector(0, 0), speed = 0, radius = 8 },
    }, 0, "projectile")
    local hq = HazardQuery.create()
    hq:update(tracker:getActive(2, 0))
    local state = {
        player = { position = Vector(0, 0), velocity = Vector(0, 0), radius = 10,
                   inputDir = Vector(0, 0) },
        threat = { level = 0.3, gradientDir = Vector(-1, 0), projectileCount = 2,
                   hazardCount = 2, framesUntilHit = -1 },
        decision = { holdFramesLeft = 0 },
    }
    local layer, dir = Pipeline.run(state, {
        config = config, tracker = tracker, hazardQuery = hq, terrain = Terrain.create(),
    }, 0)
    assert(layer == "gradient", "layer=" .. tostring(layer))
    assert(dir.X < -0.5, "moves away from cluster")
end)

check("pipeline: none layer when safe", function()
    local state = {
        player = { position = Vector(0, 0), velocity = Vector(0, 0), radius = 10 },
        threat = { level = 0.05, gradientDir = nil, projectileCount = 0, framesUntilHit = -1 },
        decision = { holdFramesLeft = 0 },
    }
    local layer = Pipeline.run(state, {
        config = config, tracker = Tracker2.create(),
        hazardQuery = HazardQuery.create(), terrain = Terrain.create(),
    }, 0)
    assert(layer == "none", "layer=" .. tostring(layer))
end)

-- ===== registry =====
local Registry = require("sensors/registry")
check("registry throttle combat/idle", function()
    local collected = {}
    local reg = Registry.create({
        config = { combatFrameInterval = 1, idleFrameInterval = 15 },
        isCombat = function() return false end,
    })
    reg:register({ name = "test", collect = function() collected[#collected + 1] = 1 end })
    reg:collectAll({}, 1) -- 首帧立即采集（设计如此）
    for f = 2, 15 do reg:collectAll({}, f) end
    assert(#collected == 1, "idle: only initial, got " .. #collected)
    reg:collectAll({}, 16) -- 距上次(帧1)已15帧
    assert(#collected == 2, "interval 15 collected, got " .. #collected)
    reg:force("test")
    reg:collectAll({}, 17)
    assert(#collected == 3, "force trigger works, got " .. #collected)
end)

-- ===== input reader =====
local InputReader = require("control/input_reader")
check("input reader axis values", function()
    assert(InputReader.actionValue(0, Vector(-0.5, 0)) == 0.5, "left half")
    assert(InputReader.actionValue(0, Vector(-0.1, 0)) == 0, "deadzone")
    assert(InputReader.actionValue(1, Vector(1, 0)) == 1, "right full")
    assert(InputReader.actionValue(2, Vector(0, -0.7)) == 0.7, "up")
end)

-- ===== projectile sensor 采集路径（GetRoomEntities 过滤 + 归属分类）=====
local ProjSensor = require("sensors/projectiles")
check("projectile sensor collect filters+classifies", function()
    local tracker2 = Tracker.create()
    SMOKE.entities = {
        { -- 敌方弹幕(NPC发射) → 采集
            Type = 1000, Index = 100, Position = Vector(50, 0),
            Velocity = Vector(-5, 0), Size = 8, SpawnerType = 33,
            IsDead = function() return false end },
        { -- 未知归属弹幕 → 默认敌方 → 采集
            Type = 1000, Index = 101, Position = Vector(60, 0),
            Velocity = Vector(-5, 0), Size = 8, SpawnerType = 0,
            IsDead = function() return false end },
        { -- 已死亡弹幕 → 跳过
            Type = 1000, Index = 102, Position = Vector(0, 0),
            Velocity = Vector(0, 0), Size = 8, SpawnerType = 0,
            IsDead = function() return true end },
        { -- 玩家发射 → 友方 → 跳过
            Type = 1000, Index = 103, Position = Vector(70, 0),
            Velocity = Vector(5, 0), Size = 8, SpawnerType = 9,
            IsDead = function() return false end },
        { -- 非弹幕实体 → 跳过
            Type = 33, Index = 104, Position = Vector(80, 0),
            Velocity = Vector(0, 0), Size = 10, SpawnerType = 0,
            IsDead = function() return false end },
    }
    ProjSensor.collect(nil, tracker2, 10, {
        hazardProjectiles = true, maxProjectiles = 300, ownershipCacheTtl = 180 })
    assert(tracker2.count == 2, "count=" .. tracker2.count)
    assert(tracker2.tracked[100], "npc-spawned tracked")
    assert(tracker2.tracked[101], "unknown default-hostile tracked")
    assert(not tracker2.tracked[102], "dead skipped")
    assert(not tracker2.tracked[103], "player-spawned skipped")
    assert(not tracker2.tracked[104], "non-projectile skipped")
    SMOKE.entities = {}
    ProjSensor.clearOwnership()
end)

-- ===== escape lock =====
local EscapeLock = require("decision/escape_lock")
check("escape lock holds direction", function()
    local el = EscapeLock.create()
    local dir = el:process(100, function() return Vector(1, 0) end)
    assert(dir and dir.X > 0.9, "initial dir")
    -- 锁定期内(初始+5帧=6次评估)即使 baseDirFn 想反转，仍保持原方向
    for f = 101, 105 do
        dir = el:process(f, function() return Vector(-1, 0) end)
        assert(dir.X > 0.9, "locked at frame " .. f .. ", got X=" .. tostring(dir.X))
    end
    -- 锁过期后重新评估 → 用新方向与记忆混合
    dir = el:process(106, function() return Vector(-1, 0) end)
    assert(dir.X < 0, "after lock expires, flips (with memory blend): X=" .. tostring(dir.X))
end)

check("escape lock memory blends nearby re-locks", function()
    local el = EscapeLock.create()
    el:process(100, function() return Vector(0, 1) end) -- 锁定向下
    for f = 101, 105 do el:process(f, function() return Vector(0, 1) end) end
    el:process(106, function() return Vector(1, 0) end) -- 重锁: 0.7*(0,1)+0.3*(1,0)后归一化
    local dir = el.lockedDir
    local len = math.sqrt(0.3 * 0.3 + 0.7 * 0.7)
    assert(math.abs(dir.X - 0.3 / len) < 0.01 and math.abs(dir.Y - 0.7 / len) < 0.01,
        "blend normalized (0.3,0.7)/" .. len .. ", got (" .. dir.X .. "," .. dir.Y .. ")")
end)

check("escape lock reset", function()
    local el = EscapeLock.create()
    el:process(100, function() return Vector(1, 0) end)
    el:reset()
    assert(el.framesLeft == 0 and el.lockedDir == nil and el.lastDir == nil)
    -- reset 后无记忆，立即接受新方向
    local dir = el:process(101, function() return Vector(-1, 0) end)
    assert(dir.X < -0.9, "fresh after reset")
end)

-- ===== 弧线弹幕预测（三点圆拟合）=====
local Predict2 = require("threat/projectile_predict")
check("arc prediction detects curved shot and hits", function()
    -- 构造圆弧运动历史: 圆心(0,0) 半径100, 每3帧转5度
    local history = {}
    local entry = {
        pos = nil, vel = nil, radius = 5,
        history = history, historyCount = 10,
    }
    for i = 1, 10 do
        local ang = (i - 1) * math.rad(5) * 3 -- 每3帧+15度? 简化: 每帧5度
        ang = (i - 1) * math.rad(5)
        history[i] = { pos = Vector(100 * math.cos(ang), 100 * math.sin(ang)), frame = i }
    end
    -- 最新点
    entry.pos = history[10].pos
    entry.vel = Vector(0, 0) -- 直线闭式解用不到（isCurved 先行）
    assert(Predict2.isCurved(entry), "curvature detected")
    -- 玩家站在弧线路径前方某点: 圆心(0,0) r=100, 角速度5度/帧
    -- 最新样本角度 = 9*5度=45度，未来 t 帧角度 = 45°+5°*t；取 95 度处 ≈ t=10
    local targetAng = math.rad(95)
    local pPos = Vector(100 * math.cos(targetAng), 100 * math.sin(targetAng))
    local t = Predict2.timeToHitArc(entry, pPos, Vector(0, 0), 8, 28)
    assert(t and t <= 12, "arc hit within horizon, t=" .. tostring(t))
end)

check("tracking projectile detected from velocity trend", function()
    -- 模拟追踪型弹幕：速度方向持续变化（每帧转向5度）
    local history = {}
    for i = 1, 6 do
        local ang = (i - 1) * math.rad(5)
        history[i] = {
            pos = Vector(i * 5, 0),
            vel = Vector(10 * math.cos(ang), 10 * math.sin(ang)),
            frame = i,
        }
    end
    local entry = {
        pos = history[6].pos, vel = history[6].vel, radius = 5,
        history = history, historyCount = 6,
    }
    assert(Predict2.isTracking(entry), "curved velocity detected as tracking")
    -- 直线弹幕不误判
    local straightHistory = {}
    for i = 1, 6 do
        straightHistory[i] = { pos = Vector(i * 10, 0), vel = Vector(10, 0), frame = i }
    end
    local straight = {
        pos = Vector(60, 0), vel = Vector(10, 0), radius = 5,
        history = straightHistory, historyCount = 6,
    }
    assert(not Predict2.isTracking(straight), "straight not tracking")
end)

check("arc prediction: straight shot not flagged curved", function()
    local history = {}
    for i = 1, 10 do
        history[i] = { pos = Vector(i * 10, 0), frame = i }
    end
    local entry = { pos = Vector(100, 0), vel = Vector(10, 0), radius = 5,
                    history = history, historyCount = 10 }
    assert(not Predict2.isCurved(entry), "straight = not curved")
    -- 直线弹幕走闭式解路径正常
    local t = Predict2.timeToHitMoving(entry, Vector(150, 0), Vector(0, 0), 8, 28)
    assert(t and t > 0, "linear solve still works, t=" .. tostring(t))
end)

-- ===== enemy sensor 采集（接触威胁）=====
local EnemySensor = require("sensors/enemies")
local function mockNpc(overrides)
    local e = {
        Type = 33, Index = 500, Position = Vector(40, 0),
        Velocity = Vector(-3, 0), Size = 12, SpawnerType = 0,
        ToNPC = function() return {} end,
        IsDead = function() return false end,
        IsActiveEnemy = function() return true end,
        HasEntityFlags = function() return false end,
    }
    for k, v in pairs(overrides or {}) do e[k] = v end
    return e
end

check("enemy sensor collect filters contact threats", function()
    local trk = Tracker.create()
    SMOKE.entities = {
        mockNpc({}),                                        -- 活敌 → 采集
        mockNpc({ Index = 501, IsDead = function() return true end }),        -- 死亡 → 跳过
        mockNpc({ Index = 502, HasEntityFlags = function() return true end }), -- 友方 → 跳过
        mockNpc({ Index = 503, IsActiveEnemy = function() return false end }), -- 非活跃 → 跳过
        mockNpc({ Index = 504, ToNPC = function() return nil end }),          -- 非NPC → 跳过
        { Type = 9, Index = 505, Position = Vector(0, 0), Velocity = Vector(0, 0),
          Size = 10, IsDead = function() return false end }, -- 玩家(无ToNPC) → 跳过
    }
    EnemySensor.collect(nil, trk, 10, { hazardContact = true })
    assert(trk.count == 1, "count=" .. trk.count)
    assert(trk.tracked[500], "living enemy tracked")
    SMOKE.entities = {}
end)

check("enemy sensor respects hazardContact=false", function()
    local trk = Tracker.create()
    trk:update({ { index = 999, pos = Vector(0, 0), vel = Vector(0, 0), speed = 0, radius = 5 } }, 5, "enemy")
    EnemySensor.collect(nil, trk, 10, { hazardContact = false })
    assert(trk.count == 0, "cleared when disabled")
end)

-- ===== 混合威胁：敌人+弹幕进入同一威胁评估 =====
check("merged hazards: chasing enemy triggers collision urgency", function()
    local trkProj = Tracker2.create()
    local trkEnemy = Tracker2.create()
    -- 追踪型敌人从右侧逼近: 速度3px/f, 距玩家50px, combined=12+10=22 → t≈(50-22)/3≈9.3帧
    trkEnemy:update({ { index = 1, pos = Vector(50, 0), vel = Vector(-3, 0), speed = 3, radius = 12 } }, 0, "enemy")
    local hq = HazardQuery.create()
    local merged = trkProj:getActive(2, 0)
    for _, e in ipairs(trkEnemy:getActive(2, 0)) do merged[#merged + 1] = e end
    hq:update(merged)
    local cfg = require("config/defaults").get()
    local state = {
        player = { position = Vector(0, 0), velocity = Vector(0, 0), radius = 10 },
        threat = {},
    }
    ThreatLevel.evaluate(state, {
        config = cfg, tracker = trkProj, trackerEnemies = trkEnemy,
        getHazards = function() return merged end,
        hazardQuery = hq, terrain = Terrain.create(),
    }, 0)
    assert(state.threat.enemyCount == 1, "enemyCount=" .. tostring(state.threat.enemyCount))
    assert(state.threat.hazardCount == 1, "hazardCount=" .. tostring(state.threat.hazardCount))
    assert(state.threat.collisionUrgency > 0.3,
        "urgency=" .. tostring(state.threat.collisionUrgency))
    assert(state.threat.level > cfg.threatLow, "level=" .. tostring(state.threat.level))
    -- 梯度也应指向远离敌人的左侧
    local g = state.threat.gradientDir
    assert(g and g.X < -0.5, "avoid enemy leftward, got " .. (g and tostring(g.X) or "nil"))
end)

-- ===== session recorder（文件输出，io 不可用时优雅降级）=====
local SessionRecorder = require("recording/session_recorder")
check("session recorder degrades without io/debug path", function()
    local sr = SessionRecorder.create()
    -- lupa 环境有 io 但 chunk 名非 @路径 → scriptDirectory nil → available=false
    -- 无论降级与否，所有操作都应无错
    sr:startSession("ABCD 1234")
    sr:push({ frame = 1, threat = 0.5 }, function(t) return "{}" end)
    sr:event({ ev = "hit", dmg = 1 })
    sr:flush()
    sr:closeFile()
    local text = sr:statusText()
    assert(type(text) == "string" and #text > 0, "statusText ok")
    -- 不带 jsonEncoder 的 push（json 加载失败场景）也不崩
    sr:push({ frame = 2 }, nil)
end)

-- ===== laser/bomb/effect sensor 采集 + 碰撞分流 =====
local LaserSensor = require("sensors/lasers")
local BombSensor = require("sensors/bombs")
local EffectSensor = require("sensors/effects")
local HazardQuery = require("threat/hazard_query")

check("laser sensor filters hostile vs friendly", function()
    local trk = Tracker.create()
    SMOKE.entities = {
        { Type = 7, Index = 800, Position = Vector(0, 0), Velocity = Vector(0, 0),
          Size = 8, SpawnerType = 0, IsDead = function() return false end },
        { Type = 7, Index = 801, Position = Vector(10, 0), Velocity = Vector(0, 0),
          Size = 8, SpawnerType = 9, IsDead = function() return false end }, -- 玩家发射
    }
    LaserSensor.collect(nil, trk, 10, { hazardLasers = true })
    assert(trk.count == 1, "hostile only: count=" .. trk.count)
    assert(trk.tracked[800], "hostile tracked")
    assert(not trk.tracked[801], "player-owned skipped")
    SMOKE.entities = {}
end)

check("bomb sensor filters by fuse time", function()
    local trk = Tracker.create()
    -- 玩家炸弹跳过
    SMOKE.entities = {
        { Type = 4, Index = 810, Position = Vector(50, 0), Velocity = Vector(0, 0),
          Size = 10, SpawnerType = 0, FrameCount = 150, -- 已到危险时间
          IsDead = function() return false end },
        { Type = 4, Index = 811, Position = Vector(60, 0), Velocity = Vector(0, 0),
          Size = 10, SpawnerType = 0, FrameCount = 50, -- 还早
          IsDead = function() return false end },
    }
    BombSensor.collect(nil, trk, 10, { hazardBombs = true })
    assert(trk.count == 1, "fuse filter: count=" .. trk.count)
    assert(trk.tracked[810], "mature bomb tracked")
    assert(not trk.tracked[811], "immature bomb skipped")
    SMOKE.entities = {}
end)

check("effect sensor classifies creep vs visual-only", function()
    local trk = Tracker.create()
    SMOKE.entities = {
        { Type = 1000, Index = 820, Position = Vector(40, 0), Velocity = Vector(0, 0),
          Size = 12, Variant = 22, IsDead = function() return false end }, -- CREEP_RED
        { Type = 1000, Index = 821, Position = Vector(50, 0), Velocity = Vector(0, 0),
          Size = 5, Variant = 61, IsDead = function() return false end },  -- SHOCKWAVE
        { Type = 1000, Index = 822, Position = Vector(60, 0), Velocity = Vector(0, 0),
          Size = 2, Variant = 11, IsDead = function() return false end },  -- BULLET_POOF (visual)
    }
    EffectSensor.collect(nil, trk, 10, { hazardCreep = true })
    assert(trk.count == 2, "creep+shockwave: count=" .. trk.count)
    assert(trk.tracked[820], "creep_red tracked")
    assert(trk.tracked[821], "shockwave tracked")
    assert(not trk.tracked[822], "bullet_poof filtered")
    SMOKE.entities = {}
end)

check("hazard_query routes laser by segment distance", function()
    -- 激光水平从左到右，玩家在激光上方近距离
    local hz = {
        { index = 1, pos = Vector(0, 10), vel = Vector(100, 0), speed = 0,
          radius = 5, kind = "laser" },
    }
    local hq = HazardQuery.create()
    hq:update(hz)
    -- 玩家在激光正上方距离5px（恰好重叠），静止
    local t, entry = hq:firstCollision(Vector(50, 5), Vector(0, 0), 3, 10)
    assert(t == 0, "laser hit at frame 0, got t=" .. tostring(t))
    -- 玩家远离激光下方
    local t2 = hq:firstCollision(Vector(50, 100), Vector(0, 0), 3, 10)
    assert(t2 == nil, "far from laser: no hit")
end)

-- ===== NPC attack sensor 检测 =====
local NpcAttackSensor = require("sensors/npc_attacks")

local function mockNpcAttack(overrides)
    local e = {
        Type = 33, Index = 900, Position = Vector(50, 0),
        Velocity = Vector(0, 0), Size = 12, SpawnerType = 0,
        ToNPC = function() return {} end,
        IsDead = function() return false end,
        IsActiveEnemy = function() return true end,
        HasEntityFlags = function() return false end,
        GetSprite = function() return { GetAnimation = function() return "idle" end } end,
    }
    for k, v in pairs(overrides or {}) do e[k] = v end
    return e
end

check("npc_attack sensor detects Mom's Hand jumpdown", function()
    local trk = Tracker.create()
    SMOKE.entities = {
        mockNpcAttack({ Type = 213, -- MOMS_HAND
            GetSprite = function() return { GetAnimation = function() return "JumpDown" end } end }),
        mockNpcAttack({ Index = 901, Type = 213, -- same NPC but idle
            GetSprite = function() return { GetAnimation = function() return "idle" end } end }),
    }
    NpcAttackSensor.collect(nil, trk, 10, { hazardNpcAttacks = true })
    assert(trk.count == 1, "jumpdown detected: count=" .. trk.count)
    -- 落点半径应>=60
    for _, entry in pairs(trk.tracked) do
        assert(entry.radius >= 60, "radius=" .. entry.radius)
    end
    SMOKE.entities = {}
end)

check("npc_attack sensor detects Horf attack windup", function()
    local trk = Tracker.create()
    SMOKE.entities = {
        mockNpcAttack({ Type = 12, -- HORF
            GetSprite = function() return { GetAnimation = function() return "Attack" end } end }),
    }
    NpcAttackSensor.collect(nil, trk, 10, { hazardNpcAttacks = true })
    assert(trk.count == 1, "horf attack detected")
    SMOKE.entities = {}
end)

check("npc_attack sensor detects laser windup (Vis/Brimstone)", function()
    local trk = Tracker.create()
    SMOKE.entities = {
        mockNpcAttack({ Type = 246, -- VIS
            GetSprite = function() return { GetAnimation = function() return "Laser" end } end }),
        mockNpcAttack({ Index = 901, Type = 246, -- VIS death anim (excluded)
            GetSprite = function() return { GetAnimation = function() return "Death" end } end }),
    }
    NpcAttackSensor.collect(nil, trk, 10, { hazardNpcAttacks = true })
    assert(trk.count == 1, "laser windup detected, death excluded: count=" .. trk.count)
    SMOKE.entities = {}
end)

check("npc_attack sensor disabled by config", function()
    local trk = Tracker.create()
    trk:update({ { index = 999, pos = Vector(0, 0), vel = Vector(0, 0), speed = 0, radius = 5 } }, 5, "npc_attack")
    NpcAttackSensor.collect(nil, trk, 10, { hazardNpcAttacks = false })
    assert(trk.count == 0, "cleared when disabled")
end)

-- ===== 第一批改进回归：伤害加权 / 墙壁截断 / 旋转激光 / 引信紧迫度 =====

-- 手工构造带墙地形: 5x1 格（每格40px），x=2 格（80-120px）为墙
local function walledTerrain()
    local ter = Terrain.create()
    ter.valid = true
    ter.sizeX = 5
    ter.sizeY = 1
    ter.topLeft = Vector(0, 0)
    ter.grid = {}
    for x = 0, 4 do
        ter.grid[x + 1] = { walkable = (x ~= 2), danger = nil }
    end
    return ter
end

check("damage weighting: high damage raises urgency (3.6)", function()
    local function urgencyFor(dmg)
        local tracker = Tracker2.create()
        -- 弹幕从右向左 3.5 帧后命中玩家
        tracker:update({ { index = 1, pos = Vector(90, 0), vel = Vector(-20, 0), speed = 20, radius = 8,
                           damage = dmg } }, 0, "projectile")
        local hq = HazardQuery.create()
        hq:update(tracker:getActive(2, 0))
        local cfg = require("config/defaults").get()
        local state = { player = { position = Vector(20, 0), velocity = Vector(0, 0), radius = 10 }, threat = {} }
        ThreatLevel.evaluate(state, {
            config = cfg, tracker = tracker, trackerEnemies = Tracker2.create(),
            getHazards = function() return tracker:getActive(2, 0) end,
            hazardQuery = hq, terrain = Terrain.create(),
        }, 0)
        return state.threat.collisionUrgency, state.threat.hitDamage
    end
    local u1, hd1 = urgencyFor(1)
    local u3, hd3 = urgencyFor(3)
    assert(u1 >= 0.8, "base urgency=" .. tostring(u1))
    assert(u3 > u1 + 0.05, "damage weighting: u3=" .. tostring(u3) .. " u1=" .. tostring(u1))
    assert(hd3 == 3 and hd1 == 1, "hitEntry damage passed through")
end)

check("wall truncation: projectile behind wall is not a threat (3.5)", function()
    local hz = { { index = 1, pos = Vector(0, 0), vel = Vector(3, 0), speed = 3, radius = 5 } }
    local hq = HazardQuery.create()
    hq:update(hz)
    local ter = walledTerrain()
    -- 玩家在墙后 x=130（墙格 80-120px）：命中路径穿墙 → 截断为 nil
    local tWall = hq:firstCollision(Vector(130, 0), Vector(0, 0), 5, 50, ter)
    assert(tWall == nil, "wall should truncate, got t=" .. tostring(tWall))
    -- 无墙地形（invalid）同几何 → 正常解出
    local tOpen = hq:firstCollision(Vector(130, 0), Vector(0, 0), 5, 50, Terrain.create())
    assert(tOpen ~= nil and tOpen > 0, "no wall: should hit, got " .. tostring(tOpen))
end)

check("rotating laser: sweep predicts future hit", function()
    -- 激光起点(0,0)，终点(100,0)，顺时针旋转2度/帧；玩家在(70,20)静止
    -- 激光扫过玩家方位角 atan2(20,70)≈15.9° → 约8帧后扫到
    local hz = { { index = 1, pos = Vector(0, 0), vel = Vector(0, 0), speed = 0, radius = 5,
                   kind = "laser", endPos = Vector(100, 0), angle = 0, rotSpd = 2, length = 100 } }
    local hq = HazardQuery.create()
    hq:update(hz)
    local t = hq:firstCollision(Vector(70, 20), Vector(0, 0), 3, 28)
    assert(t ~= nil and t <= 12, "sweep should hit within 12 frames, got " .. tostring(t))
    -- 不旋转的激光永远指向 +x，玩家在上方 20px 外 → 无命中
    local hz2 = { { index = 1, pos = Vector(0, 0), vel = Vector(0, 0), speed = 0, radius = 5,
                    kind = "laser", endPos = Vector(100, 0), angle = 0, rotSpd = 0, length = 100 } }
    local hq2 = HazardQuery.create()
    hq2:update(hz2)
    local t2 = hq2:firstCollision(Vector(70, 20), Vector(0, 0), 3, 28)
    assert(t2 == nil, "static laser pointing away should not hit")
end)

check("bomb fuse urgency: imminent explosion dominates (batch1)", function()
    -- 炸弹距玩家80px、以2px/帧逼近（约15帧后进入爆炸半径，基础 urgency≈0.37），
    -- 但引信只剩 5 帧 → fuse urgency≈0.93 应占主导
    local tracker = Tracker2.create()
    tracker:update({ { index = 1, pos = Vector(80, 0), vel = Vector(-2, 0), speed = 2, radius = 40,
                       kind = "bomb", damage = 1, fuseFrames = 5 } }, 0, "enemy")
    local hq = HazardQuery.create()
    hq:update(tracker:getActive(2, 0))
    local cfg = require("config/defaults").get()
    local state = { player = { position = Vector(0, 0), velocity = Vector(0, 0), radius = 10 }, threat = {} }
    ThreatLevel.evaluate(state, {
        config = cfg, tracker = Tracker2.create(), trackerEnemies = tracker,
        getHazards = function() return tracker:getActive(2, 0) end,
        hazardQuery = hq, terrain = Terrain.create(),
    }, 0)
    assert(state.threat.collisionUrgency >= 0.9,
        "fuse urgency=" .. tostring(state.threat.collisionUrgency))
    assert(state.threat.hitKind == "bomb", "hitKind=" .. tostring(state.threat.hitKind))
end)

-- ===== 输出结果 =====
print("========== SMOKE RESULTS ==========")
for i = 1, #results do
    print(results[i])
end
print(string.format("========== %d pass, %d fail ==========", #results - failures, failures))
if failures > 0 then
    error("SMOKE TEST FAILED")
end
