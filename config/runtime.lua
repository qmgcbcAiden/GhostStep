-- config/runtime.lua
-- 运行时状态容器。唯一的全局状态入口，由 main.lua 持有并显式传递给各模块
-- （糟粕#3 的替代方案：局部状态 + 显式参数传递）

local Runtime = {}

--- 创建运行时状态表
function Runtime.create(config)
    return {
        config = config,        -- 配置引用（defaults + MCM/存档覆盖后的实例）

        -- 双帧计数器（模式7：update 30fps 暂停停止 / render 60fps 暂停继续）
        updateCount = 0,
        renderCount = 0,

        -- 开关
        userEnabled = true,     -- ALT 键切换的运行时开关（与 Config.enabled 是 AND 关系）
        statusToastUntil = 0,   -- 状态提示显示截止（renderCount）

        -- 房间
        currentRoomIndex = -1,
        roomCommitPending = false, -- 房间切换延迟提交标记（模式6）

        -- 玩家
        player = {
            valid = false,
            controllerIndex = 0,
            canFly = false,
            position = Vector(0, 0),
            velocity = Vector(0, 0),
            inputDir = Vector(0, 0),   -- 本帧玩家原始输入方向（归一化前）
            radius = 10,
        },

        -- 威胁评估输出
        threat = {
            level = 0,          -- 综合威胁等级 [0,1]
            collisionUrgency = 0, -- 碰撞紧急度 [0,1]
            densityScore = 0,   -- 弹幕场密度分数 [0,1]
            framesUntilHit = -1, -- 沿当前路径首次碰撞帧数（-1 无碰撞）
            gradientDir = nil,  -- 弹幕场梯度规避方向（Vector 或 nil）
            projectileCount = 0,
            enemyCount = 0,     -- 接触威胁敌人数
            laserCount = 0,     -- 激光威胁数
            bombCount = 0,      -- 炸弹威胁数
            effectCount = 0,    -- 效果/水坑/火焰数
            npcAttackCount = 0, -- NPC攻击前兆数
            hazardCount = 0,    -- 活跃威胁实体总数（所有类型）
        },

        -- 决策输出
        decision = {
            layer = "none",     -- none / gradient / early_dodge / escape / fallback
            dodgeDir = nil,     -- 本帧闪避方向（Vector，归一化）
            dodgeDirPrev = nil, -- 上帧方向（平滑用）
            holdFramesLeft = 0, -- 方向保持剩余帧
            usedBudgetMs = 0,   -- 本帧决策耗时
            degraded = false,   -- 本帧是否采样降级
        },

        -- 控制（MC_INPUT_ACTION 读取）
        control = {
            active = false,     -- 本帧是否介入
            direction = Vector(0, 0), -- 合成后的输出方向
            weight = 0,         -- 本帧权重
            frame = -1,         -- 决策帧号（超时失效保护）
        },

        -- 性能
        profiler = {
            lastFrameMs = 0,
            avgFrameMs = 0,
        },
    }
end

--- 房间切换时重置状态（7.5.6）
function Runtime.onNewRoom(state)
    state.control.active = false
    state.control.direction = Vector(0, 0)
    state.control.weight = 0
    state.threat.level = 0
    state.threat.collisionUrgency = 0
    state.threat.densityScore = 0
    state.threat.framesUntilHit = -1
    state.threat.gradientDir = nil
    state.decision.layer = "none"
    state.decision.dodgeDir = nil
    state.decision.dodgeDirPrev = nil
    state.decision.holdFramesLeft = 0
end

--- 判定是否真正启用（总开关 AND ALT 开关 AND 非观察模式）
function Runtime.isDodgeActive(state)
    return state.config.enabled and state.userEnabled
end

return Runtime
