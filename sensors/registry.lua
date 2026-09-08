-- sensors/registry.lua
-- 传感器注册表（SocketBridge 模式1+2+5）
-- 每个传感器自描述（采集函数 + 战斗/空闲节流 + 事件触发），注册一次，
-- 框架统一处理时序。传感器代码无需关心"这帧该不该跑"。

-- 前置依赖（由 main.lua 在加载时注入，避免 require 路径问题）
local Registry = {}

--- 创建注册表实例
--- 参数: deps = { config, isCombat() }
function Registry.create(deps)
    local config = deps.config
    local sensors = {}   -- [name] = sensor 定义
    local order = {}     -- 注册顺序
    local counters = {}  -- [name] = 距上次采集帧数
    local pending = {}   -- [name] = true（事件触发强制采集）

    local self = {}

    --- 注册传感器
    --- def = { name, combatInterval(可选), idleInterval(可选), collect(state) }
    function self.register(_, def)
        assert(def and def.name and def.collect, "sensor def requires name+collect")
        sensors[def.name] = def
        order[#order + 1] = def.name
        counters[def.name] = 9999 -- 首帧立即采集
    end

    --- 事件触发：标记传感器下帧强制采集（模式5）
    function self.force(_, name)
        pending[name] = true
    end

    --- 战斗状态变化时调用（预留：当前节流按间隔自然过渡）
    function self.onCombatChanged()
    end

    local function shouldCollect(name, def, frame)
        -- 事件触发优先
        if pending[name] then
            pending[name] = nil
            return true
        end
        -- 节流：战斗/空闲不同间隔（模式2）
        local interval
        if deps.isCombat() then
            interval = def.combatInterval or config.combatFrameInterval
        else
            interval = def.idleInterval or config.idleFrameInterval
        end
        counters[name] = counters[name] + 1
        if counters[name] >= interval then
            counters[name] = 0
            return true
        end
        return false
    end

    --- 每帧调用：按节流规则采集所有到期传感器
    --- state: Runtime 状态表（透传给 collect）
    function self.collectAll(_, state, frame)
        for i = 1, #order do
            local name = order[i]
            local def = sensors[name]
            if shouldCollect(name, def, frame) then
                def.collect(state, frame)
            end
        end
    end

    --- 重置所有计数器（进房间时全量采集）
    function self.reset()
        for i = 1, #order do
            counters[order[i]] = 9999
        end
    end

    return self
end

return Registry
