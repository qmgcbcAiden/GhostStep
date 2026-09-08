-- utils/safe_call.lua
-- pcall 包装器：任何模块错误都不能导致游戏崩溃（原则：防御性编码）

local SafeCall = {}

local errorCounts = {}   -- [tag] = 次数
local lastErrorFrame = {} -- [tag] = 帧号
local ERROR_COOLDOWN = 300 -- 同一错误 300 帧只记录一次

--- 安全调用。失败时返回 nil 并静默记录（限制日志频率）
--- tag: 用于错误去重的字符串标签
function SafeCall.call(tag, fn, ...)
    local ok, result = pcall(fn, ...)
    if not ok then
        local frame = Isaac.GetFrameCount()
        if (frame - (lastErrorFrame[tag] or -9999)) > ERROR_COOLDOWN then
            lastErrorFrame[tag] = frame
            errorCounts[tag] = (errorCounts[tag] or 0) + 1
            Isaac.DebugString("[GhostStep3] ERROR " .. tag .. " #" .. errorCounts[tag] .. ": " .. tostring(result))
        end
        return nil
    end
    return result
end

--- 安全调用，失败时返回 fallback
function SafeCall.callOr(tag, fn, fallback, ...)
    local result = SafeCall.call(tag, fn, ...)
    if result == nil then return fallback end
    return result
end

--- 连续错误计数（诊断用）
function SafeCall.getErrorCount(tag)
    return errorCounts[tag] or 0
end

return SafeCall
