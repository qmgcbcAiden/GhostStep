-- decision/escape_lock.lua
-- Layer 2: 危险区内逃离锁定（Phase 2.5，老GhostStep思路重写）
-- 玩家已被弹幕覆盖(frame 0 命中)时锁定一个逃离方向保持数帧，
-- 重锁时与历史方向混合(0.7旧+0.3新)，避免逐帧换向的原地抖动（原则5: 能挣脱）
--
-- 老GhostStep经验参数: escape lock 5帧 + escape memory 45帧，无低通滤波
--
-- 嵌墙逃生（2026-09-08 重写）:
--   wallDist < 0 时探测8方向地形可通行性，选最佳逃生方向。
--   不再盲目朝房间中心推（实测：狭窄缝隙中该方向被物理引擎阻挡，
--   84% escape_lock帧 vx≈0，玩家被卡595帧）。

local EscapeLock = {}

local LOCK_FRAMES = 5     -- 锁定保持帧数
local MEMORY_FRAMES = 45  -- 方向记忆窗口
local MEMORY_OLD = 0.7    -- 重锁时旧方向权重
local MEMORY_NEW = 0.3

-- 嵌墙逃生参数
local ESCAPE_PROBE_DIST = 30   -- 探测距离（px）：30px内可通行=有逃生通道
local ESCAPE_PROBE_COUNT = 8   -- 探测方向数
local NET_DISPLACEMENT_WINDOW = 10 -- 净位移检测窗口（帧）
local NET_DISPLACEMENT_THRESHOLD = 3.0 -- 窗口内净位移<此值=真卡死

--- 嵌墙逃生：探测8方向找最佳可通行方向
--- terrain: Terrain实例（.valid==true时才有效）
--- playerPos: 当前位置
--- roomCenter: 房间中心（方向偏好用）
--- 返回: 最佳逃生方向(Vector) 或 nil（无路可走）
local function probeEscapeDirection(terrain, playerPos, roomCenter)
    if not terrain or not terrain.valid then return nil end

    local bestDir = nil
    local bestScore = -math.huge

    for i = 1, ESCAPE_PROBE_COUNT do
        local angle = (i - 1) * (2 * math.pi / ESCAPE_PROBE_COUNT)
        local dir = Vector(math.cos(angle), math.sin(angle))
        local probe = playerPos + dir * ESCAPE_PROBE_DIST

        if terrain:isWalkableAt(probe) then
            -- 可通行方向：按朝房间中心的对齐度评分（偏好远离墙壁的方向）
            local alignScore = 0
            if roomCenter and (roomCenter - playerPos):Length() > 1 then
                local toCenter = (roomCenter - playerPos):Normalized()
                alignScore = dir.X * toCenter.X + dir.Y * toCenter.Y
            end
            -- 每个可通行中间点额外加分（证明通道宽度足够）
            local midProbe = playerPos + dir * (ESCAPE_PROBE_DIST / 2)
            local midBonus = terrain:isWalkableAt(midProbe) and 2 or 0
            local score = alignScore + midBonus

            if score > bestScore then
                bestScore = score
                bestDir = dir
            end
        end
    end
    return bestDir
end

--- 创建实例
function EscapeLock.create()
    local self = {
        lockedDir = nil,      -- 当前锁定方向
        framesLeft = 0,       -- 锁定剩余帧
        lastDir = nil,        -- 上一次锁定方向（记忆混合用）
        lastActiveFrame = -9999,
        -- 多帧净位移检测（比逐帧检测更可靠）
        posHistory = {},      -- 最近N帧位置环形缓冲
        posHistoryIdx = 0,
        posHistoryFull = false,
        stuckFrames = 0,      -- 连续净位移过小的窗口数
    }
    return setmetatable(self, { __index = EscapeLock })
end

--- 是否适用：两种情况触发逃离锁定
--- 1. 已被弹幕/敌人覆盖(frame 0 命中)且威胁高档 — 原逻辑
--- 2. 威胁高档 + 有敌人在场 — 提前锁定逃离方向，不等被打才反应
---    （实测 2026-09-08: threat 0.65→1.0 仅2帧，frame 0 时才锁已来不及）
--- conditions = { hazardCount, framesUntilHit, threatLevel, threatHigh, enemyCount }
function EscapeLock.applies(conditions)
    -- 已在危险区内（frame 0）：原逻辑
    if conditions.framesUntilHit == 0
        and conditions.threatLevel >= conditions.threatHigh then
        return true
    end
    -- 有敌人 + 威胁高档：提前锁定（不等被打）
    if (conditions.enemyCount or 0) > 0
        and conditions.threatLevel >= conditions.threatHigh then
        return true
    end
    return false
end

--- 更新位置历史并检测是否真正卡死
--- 返回: true = 真卡死（净位移极小）
local function updateStuckDetection(self, playerPos)
    if not playerPos then return false end

    -- 更新环形缓冲
    self.posHistoryIdx = self.posHistoryIdx + 1
    if self.posHistoryIdx > NET_DISPLACEMENT_WINDOW then
        self.posHistoryIdx = 1
        self.posHistoryFull = true
    end
    self.posHistory[self.posHistoryIdx] = Vector(playerPos.X, playerPos.Y)

    -- 计算窗口内净位移（首→当前，而非逐帧累加）
    local count = self.posHistoryFull and NET_DISPLACEMENT_WINDOW or self.posHistoryIdx
    if count < NET_DISPLACEMENT_WINDOW then return false end

    local firstIdx = self.posHistoryFull
        and ((self.posHistoryIdx % NET_DISPLACEMENT_WINDOW) + 1)
        or 1
    local firstPos = self.posHistory[firstIdx]
    if not firstPos then return false end

    local netDist = playerPos:Distance(firstPos)
    return netDist < NET_DISPLACEMENT_THRESHOLD
end

--- 处理一帧。baseDirFn() 返回当前最优逃离方向（通常为 Fallback.compute）
--- playerPos: 本帧玩家位置
--- ctx: { roomCenter=Vector, wallStuckThreshold=number, wallDist=number, terrain=Terrain }
---   嵌墙(wallDist<0)时：探测地形找可通行逃生方向
--- 返回本帧使用的方向（Vector 或 nil）
function EscapeLock.process(self, frame, baseDirFn, playerPos, ctx)
    -- 嵌墙紧急逃生：wallDist < 0 = 玩家已嵌入墙壁碰撞体
    -- 探测8方向地形找可通行逃生路径（不盲目朝房间中心推）
    if ctx and ctx.wallDist and ctx.wallDist < 0 and ctx.terrain and playerPos then
        local escapeDir = probeEscapeDirection(ctx.terrain, playerPos, ctx.roomCenter)
        if escapeDir then
            -- 找到可通行方向：清除锁定状态，用逃生方向
            self.lockedDir = nil
            self.lastDir = nil
            self.framesLeft = 0
            self.stuckFrames = 0
            self.posHistoryIdx = 0
            self.posHistoryFull = false
            return escapeDir
        end
        -- 无路可走：清除锁定状态，让玩家自行控制
        -- （强行推方向=被物理引擎阻挡，更糟）
        self.lockedDir = nil
        self.lastDir = nil
        self.framesLeft = 0
        return nil
    end

    -- 锁定期内：保持方向（期间不重新评估，防止抖动）
    if self.framesLeft > 0 and self.lockedDir then
        self.framesLeft = self.framesLeft - 1

        -- 多帧净位移卡死检测（窗口=10帧，阈值=3px）
        -- 比逐帧检测更可靠：Isaac碰撞微振荡(0.3-0.7px/帧)在逐帧检测中看起来像移动，
        -- 但10帧净位移仍<3px说明确实卡住了
        if updateStuckDetection(self, playerPos) then
            self.stuckFrames = self.stuckFrames + 1
            -- 靠墙2帧，远离墙3帧
            local nearWall = ctx and ctx.wallStuckThreshold
                and ctx.wallDist and ctx.wallDist < ctx.wallStuckThreshold
            local threshold = nearWall and 2 or 3
            if self.stuckFrames >= threshold then
                self.lockedDir = nil
                self.lastDir = nil
                self.framesLeft = 0
                self.stuckFrames = 0
                self.posHistoryIdx = 0
                self.posHistoryFull = false
            end
        else
            self.stuckFrames = 0
        end

        if self.lockedDir then
            return self.lockedDir
        end
        -- 强制解锁后本帧立刻重评（走下方 baseDirFn 路径）
    end

    local dir = baseDirFn()
    if not dir then
        self.lockedDir = nil
        return nil
    end

    -- 记忆混合: 45帧窗口内重锁 → 大部分沿用旧方向，只吸收少量新方向
    -- 例外: 新旧方向接近相反(dot < -0.3)时跳过混合直接用新方向——
    -- 否则 0.7 旧权重的不动点会让 180° 反转永远无法收敛
    if (frame - self.lastActiveFrame) <= MEMORY_FRAMES and self.lastDir then
        local dot = self.lastDir.X * dir.X + self.lastDir.Y * dir.Y
        if dot >= -0.3 then
            local blended = self.lastDir * MEMORY_OLD + dir * MEMORY_NEW
            if blended:Length() > 0.01 then
                dir = blended:Normalized()
            end
        end
    end

    self.lockedDir = dir
    self.lastDir = dir
    self.framesLeft = LOCK_FRAMES
    self.lastActiveFrame = frame
    return dir
end

--- 状态重置（房间切换）
function EscapeLock.reset(self)
    self.lockedDir = nil
    self.framesLeft = 0
    self.lastDir = nil
    self.lastActiveFrame = -9999
    self.posHistory = {}
    self.posHistoryIdx = 0
    self.posHistoryFull = false
    self.stuckFrames = 0
end

return EscapeLock
