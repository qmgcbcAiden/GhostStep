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
    }
    return setmetatable(self, { __index = EscapeLock })
end

--- 是否适用：威胁已达高档且当前帧就命中（站在危险区内）
--- conditions = { framesUntilHit, threatLevel, threatHigh }
function EscapeLock.applies(conditions)
    return conditions.framesUntilHit == 0
        and conditions.threatLevel >= conditions.threatHigh
end

--- 处理一帧。baseDirFn() 返回当前最优逃离方向（通常为 Fallback.compute）
--- 返回本帧使用的方向（Vector 或 nil）
function EscapeLock.process(self, frame, baseDirFn)
    -- 锁定期内：保持方向（期间不重新评估，防止抖动）
    if self.framesLeft > 0 and self.lockedDir then
        self.framesLeft = self.framesLeft - 1
        return self.lockedDir
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
end

return EscapeLock
