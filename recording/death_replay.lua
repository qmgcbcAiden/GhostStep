-- recording/death_replay.lua
-- 死亡回放：玩家死亡时输出最后 N 秒的威胁演变到日志（调参依据）
-- Phase 4 可扩展 JSONL 持久化导出（需 --luadebug）

local DeathReplay = {}

--- 生成回放摘要行数组（死亡自动回放与 gs replay 手动导出共用）
--- ringBuffer: RingBuffer 实例；seconds: 回放时长
function DeathReplay.dumpLines(ringBuffer, seconds)
    local lines = {}
    local frames = ringBuffer.count
    if frames == 0 then
        lines[#lines + 1] = "[GhostStep3] 回放缓冲为空（未开启录制或刚进房间）"
        return lines
    end

    local take = math.min(math.floor(seconds * 30), frames)
    local recent = ringBuffer:getRecent(take)

    lines[#lines + 1] = "[GhostStep3] ===== 回放 (最近 " .. take .. " 帧) ====="

    -- 采样输出（每5帧一条，避免刷屏）
    local step = math.max(1, math.floor(take / 60))
    local dangerPeak = 0
    local activeCount = 0
    for i = 1, #recent, step do
        local s = recent[i]
        if s.threat and s.threat > dangerPeak then dangerPeak = s.threat end
        if s.layer ~= "none" then activeCount = activeCount + 1 end
        lines[#lines + 1] = string.format(
            "[GhostStep3] f%d room%d | threat=%.2f hit=%s proj=%d enemy=%s layer=%s w=%.2f pos=(%.0f,%.0f)",
            s.frame or -1, s.room or -1, s.threat or 0, tostring(s.hitFrame or -1),
            s.proj or 0, tostring(s.enemy or 0), s.layer or "?", s.weight or 0,
            s.px or 0, s.py or 0)
    end

    lines[#lines + 1] = string.format("[GhostStep3] 回放统计: 峰值威胁=%.2f 决策活跃帧=%d/%d",
        dangerPeak, activeCount, #recent)
    lines[#lines + 1] = "[GhostStep3] ===== 回放结束 ====="
    return lines
end

--- 死亡回放：输出到日志
function DeathReplay.dump(ringBuffer, seconds, logFn)
    logFn = logFn or Isaac.DebugString
    local lines = DeathReplay.dumpLines(ringBuffer, seconds)
    for i = 1, #lines do
        logFn(lines[i])
    end
end

return DeathReplay
