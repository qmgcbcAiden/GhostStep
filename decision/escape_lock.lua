-- decision/escape_lock.lua
-- Layer 2: 危险区内逃离锁定（Phase 2.5，老GhostStep思路重写）
-- 玩家已被弹幕覆盖(frame 0 命中)时锁定一个逃离方向保持数帧，
-- 重锁时与历史方向混合(0.7旧+0.3新)，避免逐帧换向的原地抖动（原则5: 能挣脱）
--
-- 老GhostStep经验参数: escape lock 5帧 + escape memory 45帧，无低通滤波

local EscapeLock = {}

local LOCK_FRAMES = 5     -- 锁定保持帧数
local MEMORY_FRAMES = 45  -- 方向记忆窗口
local MEMORY_OLD = 0.7    -- 重锁时旧方向权重
local MEMORY_NEW = 0.3

--- 创建实例
function EscapeLock.create()
    local self = {
        lockedDir = nil,      -- 当前锁定方向
        framesLeft = 0,       -- 锁定剩余帧
        lastDir = nil,        -- 上一次锁定方向（记忆混合用）
        lastActiveFrame = -9999,
        lastPos = nil,        -- 上帧玩家位置（卡死检测用）
        stuckFrames = 0,      -- 连续位移过小的帧数
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

--- 处理一帧。baseDirFn() 返回当前最优逃离方向（通常为 Fallback.compute）
--- playerPos: 可选，本帧玩家位置——锁定期内实际位移过小（顶墙/顶人墙）连续3帧
---   → 强制提前解锁并清空方向记忆，让 fallback 的远离墙壁偏向接管
--- 返回本帧使用的方向（Vector 或 nil）
function EscapeLock.process(self, frame, baseDirFn, playerPos)
    -- 锁定期内：保持方向（期间不重新评估，防止抖动）
    if self.framesLeft > 0 and self.lockedDir then
        self.framesLeft = self.framesLeft - 1
        -- 卡死检测（实测 2026-09-08：被围时 x 钉墙 160 帧，锁死方向顶着墙走不动）
        if playerPos then
            if self.lastPos and playerPos:Distance(self.lastPos) < 1.5 then
                self.stuckFrames = self.stuckFrames + 1
                if self.stuckFrames >= 3 then
                    -- 撞墙撞人墙：解锁 + 清记忆（记忆混合的不动点会让墙向方向反复胜出）
                    self.lockedDir = nil
                    self.lastDir = nil
                    self.framesLeft = 0
                    self.stuckFrames = 0
                end
            else
                self.stuckFrames = 0
            end
            self.lastPos = playerPos
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
    self.lastPos = nil
    self.stuckFrames = 0
end

return EscapeLock
