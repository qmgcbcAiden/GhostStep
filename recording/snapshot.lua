-- recording/snapshot.lua
-- 帧快照采集（详情级别: 1最小 2标准 3详细）

local Snapshot = {}

--- 采集一帧快照（返回平铺表，用于 RingBuffer.push）
function Snapshot.capture(state, frame, detailLevel)
    local snap = {
        frame = frame,
        room = state.currentRoomIndex,
    }

    local player = state.player
    local threat = state.threat
    local decision = state.decision
    local control = state.control

    if detailLevel >= 1 then
        -- 最小
        snap.px = player.position.X
        snap.py = player.position.Y
        snap.threat = threat.level
    end
    if detailLevel >= 2 then
        -- 标准
        snap.vx = player.velocity.X
        snap.vy = player.velocity.Y
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
        -- 详细
        snap.collision = threat.collisionUrgency
        snap.density = threat.densityScore
        snap.hitFrame = threat.framesUntilHit
        snap.budgetMs = decision.usedBudgetMs
        snap.canFly = player.canFly
        -- 命中威胁明细（受击归因离线分析用）
        if threat.hitKind then
            snap.hitKind = threat.hitKind
            snap.hitDmg = threat.hitDamage
            snap.hitDist = threat.hitDist
        end
        -- 合成输出（诊断"AI 是否压制玩家"的关键三元组：P/D/输出）
        snap.cx = control.direction.X
        snap.cy = control.direction.Y
    end

    return snap
end

return Snapshot
