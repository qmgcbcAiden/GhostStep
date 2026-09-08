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
    for i = 1, #recent do
        local s=recent[i]
        if s.threat and s.threat>dangerPeak then dangerPeak=s.threat end
        if s.layer and s.layer~="none" then activeCount=activeCount+1 end
    end
    for i = 1, #recent, step do
        local s = recent[i]
        -- 附加威胁类型计数（非零才打，避免行过长）——分析漏判时定位是哪类传感器
        local extra = ""
        if (s.laser or 0) > 0 then extra = extra .. " 激光" .. s.laser end
        if (s.bomb or 0) > 0 then extra = extra .. " 炸弹" .. s.bomb end
        if (s.effect or 0) > 0 then extra = extra .. " 效果" .. s.effect end
        if (s.npcatk or 0) > 0 then extra = extra .. " 前兆" .. s.npcatk end
        local hpTxt = s.hp ~= nil and (" hp=" .. s.hp) or ""
        -- 墙距（blocked/lowWeight 归因复核：贴墙时 w 低是钳制、w 高还挨打是被挡）
        local wallTxt = ""
        if s.wallDist ~= nil and s.wallDist >= 0 and s.wallDist < 9000 then
            wallTxt = " wall=" .. string.format("%.0f", s.wallDist)
        end
        lines[#lines + 1] = string.format(
            "[GhostStep3] f%d room%d | threat=%.2f hit=%s proj=%d enemy=%s layer=%s w=%.2f pos=(%.0f,%.0f)%s%s%s",
            s.frame or -1, s.room or -1, s.threat or 0, tostring(s.hitFrame or -1),
            s.proj or 0, tostring(s.enemy or 0), s.layer or "?", s.weight or 0,
            s.px or 0, s.py or 0, hpTxt, extra, wallTxt)
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
