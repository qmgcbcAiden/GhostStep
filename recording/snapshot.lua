-- recording/snapshot.lua
-- 帧快照采集（详情级别: 1最小 2标准 3详细 4全量诊断）
--
-- 两阶段采集（修时序错位：旧版在决策管线前一次性采集，录到的威胁/决策/控制
-- 是上一帧的值而位置是本帧值，离线对齐分析会被误导一帧）：
--   capture  — 管线前调用，只采传感器当帧就绪的字段（位置/速度/血量）
--   finalize — 决策+合成后调用，采威胁/决策/控制字段（本帧值）
-- 两个阶段在 main.lua 中间夹着威胁评估与决策管线；ALT 关闭等提前退出分支
-- 也走 finalize+push（清零后定稿），保证录制连续不断流

local Snapshot = {}

-- 级别4 hz 条目的 kind 单字母代号（省 JSONL 体积；replay_viewer 反查）
local KIND_CODE = {
    projectile = "p",
    enemy = "e",
    laser = "l",
    bomb = "b",
    effect = "f",
    npc_attack = "n",
}

--- 阶段1: 采集管线前就绪的字段（返回平铺表）
function Snapshot.capture(state, frame, detailLevel)
    local snap = {
        frame = frame,
        room = state.currentRoomIndex,
    }

    local player = state.player

    if detailLevel >= 1 then
        -- 最小
        snap.px = player.position.X
        snap.py = player.position.Y
        snap.hp = player.hp -- 受伤时刻判定（回放对齐掉血帧）
    end
    if detailLevel >= 2 then
        -- 标准
        snap.vx = player.velocity.X
        snap.vy = player.velocity.Y
        snap.cmb = state.inCombat and 1 or 0
    end
    if detailLevel >= 3 then
        -- 详细
        snap.canFly = player.canFly
    end

    return snap
end

--- 阶段2: 定稿管线后才有的字段（威胁评估/决策/输入合成/性能统计的输出）
--- hazards/config: 级别4逐威胁明细用（可省略）
function Snapshot.finalize(snap, state, detailLevel, hazards, config)
    local player = state.player
    local threat = state.threat
    local decision = state.decision
    local control = state.control

    if detailLevel >= 1 then
        snap.threat = threat.level
    end
    if detailLevel >= 2 then
        snap.ix = player.inputDir.X
        snap.iy = player.inputDir.Y
        snap.proj = threat.projectileCount
        snap.enemy = threat.enemyCount
        snap.laser = threat.laserCount or 0
        snap.bomb = threat.bombCount or 0
        snap.effect = threat.effectCount or 0
        snap.npcatk = threat.npcAttackCount or 0
        snap.layer = decision.layer
        snap.weight = control.weight
        local dd = decision.dodgeDir
        if dd then
            snap.dx = dd.X
            snap.dy = dd.Y
        end
    end
    if detailLevel >= 3 then
        snap.collision = threat.collisionUrgency
        snap.density = threat.densityScore
        snap.hitFrame = threat.framesUntilHit
        snap.budgetMs = decision.usedBudgetMs
        -- 命中威胁明细（受击归因离线分析用）
        if threat.hitKind then
            snap.hitKind = threat.hitKind
            snap.hitDmg = threat.hitDamage
            snap.hitDist = threat.hitDist
        end
        -- 合成输出（诊断"AI 是否压制玩家"的关键三元组：P/D/输出）
        snap.cx = control.direction.X
        snap.cy = control.direction.Y
        -- 调参补充: 墙距（blocked/lowWeight 归因离线复核）/ 全程帧耗时 /
        -- 采样降级标记 / 方向保持剩余帧
        snap.wallDist = control.wallDist or -1
        snap.frameMs = state.profiler.lastFrameMs
        snap.degraded = decision.degraded and 1 or 0
        snap.holdFrames = decision.holdFramesLeft
    end
    if detailLevel >= 4 then
        -- 逐威胁明细: 距离升序前 N 个、相对玩家坐标（离线重建弹幕场/可视化/
        -- 未来离线重算的基础数据）。条目为紧凑数组:
        --   { kind代号, variant, rx, ry, vx, vy, radius, damage }
        if hazards and config then
            local px, py = player.position.X, player.position.Y
            local maxN = config.traceHazardMax or 16
            local range = config.traceHazardRadius or 300
            local list = {}
            for i = 1, #hazards do
                local h = hazards[i]
                if h.pos and h.vel then
                    local dx = h.pos.X - px
                    local dy = h.pos.Y - py
                    local dist = math.sqrt(dx * dx + dy * dy)
                    if dist <= range then
                        list[#list + 1] = { dist, h, dx, dy }
                    end
                end
            end
            table.sort(list, function(a, b) return a[1] < b[1] end)
            local hz = {}
            local n = math.min(#list, maxN)
            for i = 1, n do
                local e = list[i]
                local h = e[2]
                hz[i] = {
                    KIND_CODE[h.kind] or "?",
                    h.variant or -1,
                    e[3], e[4],
                    h.vel.X, h.vel.Y,
                    h.radius or 0,
                    h.damage or 1,
                }
            end
            snap.hz = hz
        end
        -- 候选评分（决策透明度: 为什么往这躲、其他候选分多少）
        local trace = decision.lastTrace
        if trace and trace.cand then
            snap.cand = trace.cand
            snap.bestScore = trace.best
        end
    end

    return snap
end

return Snapshot
