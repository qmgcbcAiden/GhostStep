-- main.lua
-- GhostStep3（幽步 v3）— 叠加偏移式自动闪避
-- 架构: Sensors → Threat Engine → Decision Pipeline → Input Synthesizer → MC_INPUT_ACTION
--
-- 7条硬约束（ANALYSIS.md 第〇节）:
--  1 借鉴思路不照抄  2 永远保留玩家控制权(≤0.85)  3 不修改角色数据
--  4 帧预算1ms  5 不卡墙角+能挣脱  6 提前规避>极限闪避  7 最小移动(权重即幅度)

local GhostStep3 = RegisterMod("GhostStep3", 1)
_G.GhostStep3 = GhostStep3

-- ===== 模块加载（require 路径以 mod 根目录为基准）=====
local Defaults          = require("config/defaults")
local Presets           = require("config/presets")
local Runtime           = require("config/runtime")
local SafeCall          = require("utils/safe_call")
local Tracker           = require("entities/tracker")
local Registry          = require("sensors/registry")
local Terrain           = require("sensors/terrain")
local ProjectileSensor  = require("sensors/projectiles")
local EnemySensor       = require("sensors/enemies")
local LaserSensor       = require("sensors/lasers")
local BombSensor        = require("sensors/bombs")
local EffectSensor      = require("sensors/effects")
local NpcAttackSensor   = require("sensors/npc_attacks")
local PlayerSensor      = require("sensors/player")
local HazardQuery       = require("threat/hazard_query")
local ThreatLevel       = require("threat/threat_level")
local Pipeline          = require("decision/pipeline")
local EscapeLock        = require("decision/escape_lock")
local InputReader       = require("control/input_reader")
local InputSynthesizer  = require("control/input_synthesizer")
local InputWriter       = require("control/input_writer")
local Overlay           = require("render/overlay")
local RingBuffer        = require("recording/ring_buffer")
local Snapshot          = require("recording/snapshot")
local DeathReplay       = require("recording/death_replay")
local SessionRecorder   = require("recording/session_recorder")
local MCM               = require("config/mcm")

-- json 为游戏内置模块；加载失败则文件录制自动禁用
local hasJson, json = pcall(require, "json")
local jsonEncode = hasJson and json.encode or nil

-- ===== 全局装配 =====
local Config = Defaults.get()
local state = Runtime.create(Config)

local tracker = Tracker.create()
local trackerEnemies = Tracker.create() -- 敌人接触威胁（独立过期周期）
local trackerLasers = Tracker.create()  -- 激光威胁（kind=laser）
local trackerBombs = Tracker.create()   -- 炸弹威胁（kind=bomb）
local trackerEffects = Tracker.create() -- 效果威胁（kind=effect）
local trackerNpcAttacks = Tracker.create() -- NPC攻击前兆（kind=npc_attack）
local terrain = Terrain.create()
local hazardQuery = HazardQuery.create()
local escapeLock = EscapeLock.create()

-- 战斗状态（动态节流用，模式2）
-- 注: Room:GetAliveEnemiesCount 在 Rep+ 未验证，用社区通用 IsClear()
local wasCombat = false
local function isCombat()
    local ok, room = pcall(function() return Game():GetRoom() end)
    if not ok or room == nil then return false end
    local okClear, isClear = pcall(function() return room:IsClear() end)
    if not okClear then return false end
    return not isClear
end

-- 传感器注册表（模式1+2+5）
local registry = Registry.create({
    config = Config,
    isCombat = isCombat,
})

-- 威胁合并视图：弹幕 + 敌人 + 激光 + 炸弹 + 效果 + NPC攻击前兆
local function getHazards(frame)
    local hz = tracker:getActive(2, frame)
    local sources = { trackerEnemies, trackerLasers, trackerBombs, trackerEffects, trackerNpcAttacks }
    for _, src in ipairs(sources) do
        local items = src:getActive(2, frame)
        for i = 1, #items do hz[#hz + 1] = items[i] end
    end
    return hz
end

registry:register({
    name = "player",
    combatInterval = 1,
    idleInterval = 1, -- 玩家状态永远每帧
    collect = function(st, frame)
        PlayerSensor.collect(st, frame)
    end,
})
registry:register({
    name = "projectiles",
    collect = function(st, frame)
        ProjectileSensor.collect(nil, tracker, frame, Config)
    end,
})
registry:register({
    name = "enemies",
    collect = function(st, frame)
        EnemySensor.collect(nil, trackerEnemies, frame, Config)
    end,
})
registry:register({
    name = "lasers",
    collect = function(st, frame)
        LaserSensor.collect(nil, trackerLasers, frame, Config)
    end,
})
registry:register({
    name = "bombs",
    collect = function(st, frame)
        BombSensor.collect(nil, trackerBombs, frame, Config)
    end,
})
registry:register({
    name = "effects",
    collect = function(st, frame)
        EffectSensor.collect(nil, trackerEffects, frame, Config)
    end,
})
registry:register({
    name = "npc_attacks",
    collect = function(st, frame)
        NpcAttackSensor.collect(nil, trackerNpcAttacks, frame, Config)
    end,
})

-- 录制
local ringBuffer = RingBuffer.create(Config.replayBufferSeconds * 30)
state.ringBuffer = ringBuffer -- MCM 调试页只读展示用
local sessionRecorder = SessionRecorder.create()
state.sessionRecorder = sessionRecorder -- MCM 录制页只读展示用

-- MCM（未安装时静默降级）
MCM.register({ mod = GhostStep3, state = state, presets = Presets })
MCM.loadSettings()

-- ===== 房间切换（模式6 延迟提交 + 7.5.6 重置）=====
-- 注: 过渡期 Game():GetRoom() 本身可能返回 nil（SocketBridge 已知问题），
-- Room 对象没有 GetRoom() 方法
local function rebuildTerrain()
    local ok, room = pcall(function() return Game():GetRoom() end)
    if not ok or room == nil then return end
    Terrain.build(terrain, room, state.player.canFly, Config)
end

local function onNewRoom()
    Runtime.onNewRoom(state)
    Terrain.invalidate(terrain)
    ProjectileSensor.clearOwnership()
    tracker:clear()
    trackerEnemies:clear()
    trackerLasers:clear()
    trackerBombs:clear()
    trackerEffects:clear()
    trackerNpcAttacks:clear()
    EnemySensor.resetRoom()
    escapeLock:reset()
    -- 延迟提交：先验证房间数据有效，无效下一帧重试
    local ok, room = pcall(function() return Game():GetRoom() end)
    if ok and room ~= nil then
        state.currentRoomIndex = Game():GetLevel():GetCurrentRoomIndex()
        rebuildTerrain()
        state.roomCommitPending = false
    else
        state.roomCommitPending = true
    end
    ringBuffer:clear()
    sessionRecorder:event({ ev = "room", idx = state.currentRoomIndex })
    -- 配置持久化（MCM SaveHelper 策略：菜单里 SaveData 不可靠，随游戏存档点重存）
    MCM.saveSettings()
end

-- ===== 死亡回放（MC_POST_UPDATE 检测，Rep+ MC_POST_PLAYER_UPDATE 在死后停发）=====
local deathHandled = false
local function onPlayerDeath()
    if not Config.deathReplayEnabled then return end
    if not Config.recordingEnabled then
        Isaac.DebugString("[GhostStep3] 死亡回放跳过: 录制功能未开启 (MCM→GhostStep3→录制)")
        return
    end
    if ringBuffer.count > 0 then
        Isaac.DebugString("[GhostStep3] === 死亡回放 ===")
        DeathReplay.dump(ringBuffer, Config.replayBufferSeconds, Isaac.DebugString)
    end
    sessionRecorder:event({ ev = "death", frame = state.updateCount })
end

-- ===== 主更新（MC_POST_PLAYER_UPDATE, 30fps）=====
local function onPlayerUpdate(player)
    state.updateCount = Isaac.GetFrameCount()

    -- 多人/联机守卫：完全休眠（网络层只同步硬件输入）
    if Game():GetNumPlayers() > 1 then
        state.control.active = false
        state.player.valid = false
        return
    end

    -- 死亡时跳过传感器/威胁（死亡检测在 MC_POST_UPDATE，死后此回调可能停发）
    local okDead, isDead = pcall(function() return player:IsDead() end)
    if okDead and isDead then
        state.control.active = false
        return
    end

    -- 传感器采集（内部带节流）
    registry:collectAll(state, state.updateCount)

    -- 房间延迟提交重试
    if state.roomCommitPending then
        onNewRoom()
    end

    -- 开关检测（ALT）
    if Input.IsButtonTriggered(Config.toggleKey, 0) then
        state.userEnabled = not state.userEnabled
        state.statusToastUntil = state.renderCount + 90 -- ~1.5秒 @60fps
        if not state.userEnabled then
            state.control.active = false
            state.control.direction = Vector(0, 0)
        end
    end

    -- 战斗状态变化 → 通知传感器
    local combat = isCombat()
    if combat ~= wasCombat then
        wasCombat = combat
        registry:onCombatChanged()
    end

    -- 未启用 / 玩家无效 → 清控制并结束
    if not state.player.valid or not Runtime.isDodgeActive(state) then
        state.control.active = false
        state.threat.level = 0
        state.decision.layer = "none"
        return
    end

    -- 帧预算计时开始（原则4）
    local startTime = Isaac.GetTime()

    -- 1. 读取玩家原始输入
    state.player.inputDir = InputReader.readMoveVector(state.player.controllerIndex)

    -- 2. 威胁评估
    ThreatLevel.evaluate(state, {
        config = Config, tracker = tracker, trackerEnemies = trackerEnemies,
        trackerLasers = trackerLasers, trackerBombs = trackerBombs,
        trackerEffects = trackerEffects, trackerNpcAttacks = trackerNpcAttacks,
        getHazards = getHazards,
        hazardQuery = hazardQuery, terrain = terrain,
    }, state.updateCount)

    -- 空间分桶更新（威胁评估后、决策前）
    hazardQuery:update(getHazards(state.updateCount))

    -- 3. 决策管线
    local _, dodgeDir = Pipeline.run(state, {
        config = Config, tracker = tracker, trackerEnemies = trackerEnemies,
        getHazards = getHazards,
        hazardQuery = hazardQuery, terrain = terrain,
        escapeLock = escapeLock,
    }, state.updateCount)

    -- 4. 输入合成（★核心）
    if dodgeDir and state.threat.level >= Config.threatLow then
        local wallDist = terrain:minWallDistance(state.player.position)
        local combined, w = InputSynthesizer.synthesize(
            state.player.inputDir, dodgeDir, state.threat.level, Config, wallDist)

        state.control.direction = combined
        state.control.weight = w
        state.control.active = Config.enabled and not Config.observationMode
            and combined:Length() > 0.01
        state.control.frame = Isaac.GetFrameCount()
    else
        state.control.active = false
        state.control.weight = 0
    end

    -- 5. 性能统计
    local elapsed = Isaac.GetTime() - startTime
    state.profiler.lastFrameMs = elapsed
    if state.profiler.avgFrameMs == 0 then
        state.profiler.avgFrameMs = elapsed
    else
        state.profiler.avgFrameMs = state.profiler.avgFrameMs * 0.95 + elapsed * 0.05
    end

    -- 6. 录制（内存环形缓冲 + 可选 JSONL 文件输出）
    if Config.recordingEnabled then
        local snap = Snapshot.capture(state, state.updateCount, Config.snapshotDetail)
        RingBuffer.push(ringBuffer, snap)
        if jsonEncode then
            sessionRecorder:push(snap, jsonEncode)
        end
    end
end

-- ===== 受击自动归因（挨打时自动诊断"为什么没躲掉"——调参仪表盘核心）=====
-- MC_ENTITY_TAKE_DMG 在伤害应用前触发，state 里还是受击前那帧的判断，
-- 正好用来归因：是没看见、看见太晚、躲错方向、权重被钳、还是来不及
local ATTR_KIND_NAMES = {
    undetected = "未检测",
    late = "检测太晚",
    wrongDir = "方向错误",
    lowWeight = "权重不足(墙角)",
    tooFast = "反应时间不足",
}

local function attributeHit(dmg, source)
    local a = state.hitAttribution
    a.total = a.total + 1

    -- 伤害来源（EntityRef: .Type/.Variant/.Entity）
    local srcType, srcVariant, srcPos = "?", "?", nil
    if source then
        if source.Type ~= nil then srcType = tostring(source.Type) end
        if source.Variant ~= nil then srcVariant = tostring(source.Variant) end
        local e = source.Entity
        if e then
            local okPos, p = pcall(function() return e.Position end)
            if okPos and p then srcPos = p end
        end
    end

    local t = state.threat
    local level = t.level or 0
    local w = state.control.weight or 0
    local layer = state.decision.layer or "none"
    local D = state.decision.dodgeDir

    -- 分类（优先级: 未检测 > 方向错误 > 权重钳制 > 检测太晚 > 来不及）
    local kind, advice
    if level < Config.threatLow then
        kind = "undetected"
        advice = string.format(
            "威胁=%.2f 低于介入阈值%.2f → 来源 type=%s var=%s 未被传感器识别或被过滤，检查危险源开关",
            level, Config.threatLow, srcType, srcVariant)
    elseif D and srcPos then
        local away = state.player.position - srcPos
        if away:Length() > 1 then
            away = away:Normalized()
            local dot = away.X * D.X + away.Y * D.Y
            if dot < 0 then
                kind = "wrongDir"
                advice = string.format(
                    "闪避方向与远离来源方向夹角>90°(dot=%.2f) → 弹道线逃逸惩罚权重↑或候选采样加密", dot)
            end
        end
    end
    if not kind then
        local wallDist = terrain:minWallDistance(state.player.position)
        if w < 0.35 and wallDist < Config.wallStuckThreshold then
            kind = "lowWeight"
            advice = string.format(
                "墙角钳制 w=%.2f wallDist=%.0f → wallEscape 灵敏度↑或远离墙壁偏向加强", w, wallDist)
        elseif level < Config.threatMedium then
            kind = "late"
            advice = string.format(
                "威胁=%.2f 偏低(中阈%.2f) → threatSensitivity 调高 或 anticipateStrength↑",
                level, Config.threatMedium)
        else
            kind = "tooFast"
            advice = "高威胁仍被打 → 需更长预测视野（时空轨迹评分/Tier 1）"
        end
    end
    a[kind] = (a[kind] or 0) + 1

    Isaac.DebugString(string.format(
        "[GhostStep3] 受击归因#%d: %s | 来源 type=%s var=%s dmg=%.1f 距离=%s | threat=%.2f w=%.2f 层=%s 命中预测=%s",
        a.total, ATTR_KIND_NAMES[kind] or kind, srcType, srcVariant, dmg,
        srcPos and string.format("%.0fpx", srcPos:Distance(state.player.position)) or "?",
        level, w, layer, tostring(t.framesUntilHit)))
    if advice then
        Isaac.DebugString("[GhostStep3]   → " .. advice)
    end
end

-- ===== 受伤诊断 + 受击自动回放（MC_ENTITY_TAKE_DMG）=====
local lastHitDumpFrame = -9999
local takeDmgLogged = false -- 首次触发诊断日志（任意实体）
local takeDmgPlayerLogged = false -- 首次玩家受伤诊断
local function onEntityTakeDmg(tookDamage, dmg, damageFlags, damageSource)
    -- dmg 在 Rep+ 中可能是 userdata 而非 number（回调签名变了）
    local dmg = tonumber(dmg) or 0
    -- 诊断：确认回调是否触发（任意实体，只打一次）
    if not takeDmgLogged then
        takeDmgLogged = true
        local etype = tookDamage and tookDamage.Type or "nil"
        Isaac.DebugString(string.format(
            "[GhostStep3] MC_ENTITY_TAKE_DMG 回调已触发: entity.Type=%s dmg=%.1f",
            tostring(etype), dmg or 0))
    end
    if tookDamage == nil then return end
    if tookDamage.Type ~= EntityType.ENTITY_PLAYER then return end

    if not takeDmgPlayerLogged then
        takeDmgPlayerLogged = true
        Isaac.DebugString(string.format(
            "[GhostStep3] 玩家受伤确认: dmg=%.1f recording=%s buffer=%d帧",
            dmg, tostring(Config.recordingEnabled), ringBuffer.count))
    end

    -- 受击自动归因：每次挨打都打（轻量一行+建议），回放 dump 才有冷却
    SafeCall.call("attrHit", attributeHit, dmg, damageSource)

    if Config.diagnosticsEnabled then
        Isaac.DebugString(string.format(
            "[GhostStep3] 受伤 dmg=%.1f threat=%.2f layer=%s proj=%d w=%.2f",
            dmg, state.threat.level, state.decision.layer,
            state.threat.projectileCount, state.control.weight))
    end

    -- 受击自动回放：录制开启时，每次挨打把最近5秒写进 log.txt（5秒冷却防刷屏）
    -- 这是调参的主要数据来源——不用死亡、不用控制台
    if Config.recordingEnabled and ringBuffer.count > 0
        and (Isaac.GetFrameCount() - lastHitDumpFrame) > 150 then
        lastHitDumpFrame = Isaac.GetFrameCount()
        Isaac.DebugString(string.format(
            "[GhostStep3] === 受击回放 (dmg=%.1f threat=%.2f layer=%s) ===",
            dmg, state.threat.level, state.decision.layer))
        DeathReplay.dump(ringBuffer, 5, Isaac.DebugString)
        sessionRecorder:event({ ev = "hit", dmg = dmg,
            threat = state.threat.level, layer = state.decision.layer })
    elseif Config.recordingEnabled and ringBuffer.count == 0 then
        -- 缓冲为空但录制已开：房间刚切换、还没有帧被采集时被打
        Isaac.DebugString(string.format(
            "[GhostStep3] 受击回放跳过: buffer=0 (dmg=%.1f, 房间刚加载?)", dmg))
    end
end

-- ===== 控制台命令（gs，用法: 游戏~键开控制台 → gs / gs status / gs replay / gs on|off）=====
local function onCommand(cmd, params)
    if cmd ~= "gs" then return nil end -- 只响应 gs，其他命令放行
    local arg = (params or ""):match("^%s*(%S+)") or "help"

    if arg == "status" then
        local t = state.threat
        return string.format(
            "[GhostStep3] enabled=%s(ALT开关:%s) threat=%.2f hit=%d layer=%s 权重=%.0f%% | 弹幕=%d 敌=%d | 帧耗时=%.2fms 录制缓冲=%d帧",
            tostring(Runtime.isDodgeActive(state)), tostring(state.userEnabled),
            t.level or 0, t.framesUntilHit or -1, state.decision.layer or "?",
            (state.control.weight or 0) * 100,
            t.projectileCount or 0, t.enemyCount or 0,
            state.profiler.lastFrameMs or 0,
            (state.ringBuffer and state.ringBuffer.count) or 0)
    elseif arg == "replay" or arg == "record" then
        if not Config.recordingEnabled then
            return "[GhostStep3] 录制未开启（MCM→GhostStep3→录制→录制功能），开启后进房间打几秒再试"
        end
        local lines = DeathReplay.dumpLines(ringBuffer, Config.replayBufferSeconds)
        for i = 1, #lines do Isaac.DebugString(lines[i]) end
        return table.concat(lines, "\n")
    elseif arg == "on" then
        state.userEnabled = true
        state.statusToastUntil = state.renderCount + 90
        return "[GhostStep3] 开启自动躲避"
    elseif arg == "off" then
        state.userEnabled = false
        state.control.active = false
        state.control.direction = Vector(0, 0)
        return "[GhostStep3] 关闭自动躲避"
    end
    return "[GhostStep3] 命令: gs status 状态 | gs replay 导出回放(也写log.txt) | gs on/off 开关 | ALT键同效"
end

-- ===== 受伤诊断 + 受击自动回放（MC_ENTITY_TAKE_DMG）=====
-- 防御: Rep+ 回调常量可能缺失/更名——nil 时跳过注册而不是让整个 mod 加载失败
-- （教训: MC_POST_PLAYER_DEATH 为 nil 时 AddCallback 在游戏引导脚本里
--   callbacks[nil] = {} → "table index is nil" → main.lua 中途夭折）
local function safeAddCallback(cb, fn)
    if cb == nil then
        Isaac.DebugString("[GhostStep3] WARN: callback constant is nil, skipped")
        return
    end
    GhostStep3:AddCallback(cb, fn)
end

safeAddCallback(ModCallbacks.MC_POST_PLAYER_UPDATE, function(player)
    SafeCall.call("playerUpdate", onPlayerUpdate, player)
end)

safeAddCallback(ModCallbacks.MC_INPUT_ACTION, function(_, entity, inputHook, action)
    return SafeCall.callOr("inputAction",
        InputWriter.onInputAction, nil,
        state.control, Config.observationMode, entity, inputHook, action)
end)

safeAddCallback(ModCallbacks.MC_POST_NEW_ROOM, function()
    SafeCall.call("newRoom", onNewRoom)
end)

safeAddCallback(ModCallbacks.MC_POST_RENDER, function()
    state.renderCount = state.renderCount + 1
    SafeCall.call("render", Overlay.render, state, GhostStep3, state.renderCount)
end)

safeAddCallback(ModCallbacks.MC_ENTITY_TAKE_DMG, function(tookDamage, amount, flags, source)
    SafeCall.call("takeDmg", onEntityTakeDmg, tookDamage, amount, flags, source)
    return nil -- 不修改伤害
end)

safeAddCallback(ModCallbacks.MC_POST_GAME_STARTED, function()
    -- 开局重载配置（上一局存档点写入的数据此时可读）并立即回存（MCM OnGameStarted 同款）
    SafeCall.call("gameStarted", function()
        MCM.loadSettings()
        MCM.saveSettings()
        Runtime.resetHitStats(state) -- 归因统计按局累积，新对局清零
        -- 开新录制会话（io 可用时创建 JSONL 文件）
        if Config.recordingEnabled then
            local okSeed, seed = pcall(function()
                return Game():GetSeeds():GetStartSeed()
            end)
            sessionRecorder:startSession(okSeed and seed or "")
        end
    end)
end)

safeAddCallback(ModCallbacks.MC_POST_NEW_LEVEL, function()
    SafeCall.call("newLevel", MCM.saveSettings)
end)

-- 死亡检测（全局回调，死亡后仍触发；Rep+ 的 MC_POST_PLAYER_UPDATE 玩家死后停发）
safeAddCallback(ModCallbacks.MC_POST_UPDATE, function()
    SafeCall.call("deathDetect", function()
        local ok, player = pcall(Isaac.GetPlayer, 0)
        if not ok or player == nil then return end
        local okDead, isDead = pcall(function() return player:IsDead() end)
        if okDead and isDead then
            if not deathHandled then
                deathHandled = true
                onPlayerDeath()
            end
        else
            deathHandled = false
        end
    end)
end)

safeAddCallback(ModCallbacks.MC_PRE_GAME_EXIT, function()
    SafeCall.call("preExit", function()
        MCM.saveSettings()
        sessionRecorder:closeFile()
    end)
end)

safeAddCallback(ModCallbacks.MC_EXECUTE_CMD, function(cmd, params)
    return SafeCall.callOr("execCmd", onCommand, nil, cmd, params)
end)

-- 导出供 MCM/外部调试
GhostStep3.State = state
GhostStep3.Config = Config

Isaac.DebugString("[GhostStep3] v3.0.0 loaded — 叠加偏移式自动闪避")
