-- config/defaults.lua
-- 分组默认配置。所有可调参数收归此处，杜绝魔法数字（糟粕#8）
-- 运行时实例为 Config 表，由 main.lua 创建并传递给各模块

local Defaults = {}

--- 全部默认配置（按分组）
function Defaults.get()
    return {
        ---------------------------------------------------------------
        -- 常规
        ---------------------------------------------------------------
        enabled = true,             -- 自动躲避总开关
        toggleKey = 56,             -- 键盘键值（默认左Alt = 56）
        preset = 2,                 -- 1安全 2平衡 3激进

        ---------------------------------------------------------------
        -- 危险源（威胁类型开关）
        ---------------------------------------------------------------
        hazardProjectiles = true,   -- 敌方弹幕
        hazardContact = true,       -- 敌人接触伤害
        hazardLasers = true,        -- 激光（Phase 3 实装，先占位）
        hazardBombs = true,         -- 炸弹（Phase 3 实装，先占位）
        hazardCreep = true,         -- 水坑/火焰（Phase 3 实装，先占位）
        hazardNpcAttacks = true,    -- NPC攻击前兆（Phase 3 实装，先占位）
        hazardSpikes = true,        -- 地刺
        hazardTnt = true,           -- TNT 爆炸

        ---------------------------------------------------------------
        -- 躲避（算法核心参数）
        ---------------------------------------------------------------
        maxDodgeWeight = 0.85,      -- AI 权重上限（原则2：永不 1.0）
        threatLow = 0.25,           -- 低威胁阈值：低于此完全不介入
        threatMedium = 0.45,        -- 中威胁阈值：提前规避阶段上限
        threatHigh = 0.65,          -- 高威胁阈值：紧急闪避
        threatSensitivity = 2,      -- 威胁感知灵敏度 1低/2平衡/3高（联动上面三个阈值）
        anticipateStrength = 5,     -- 提前规避强度 0-10（弹幕场梯度权重）
        gradientRadius = 120,       -- 弹幕场梯度采样半径（像素）
        gradientBins = 8,           -- 梯度方向 bin 数
        wallStuckThreshold = 60,    -- 靠墙判定距离（像素），低于此降权（含房间边界检测）
        wallEscapeSensitivity = 2,  -- 墙角挣脱灵敏度 1低/2中/3高（联动 wallStuckThreshold）
        wallEscapeWeight = 0.3,     -- 挣脱模式下的 AI 权重上限（原则5）
        wallPenaltyBase = 1.0,      -- 候选方向墙壁惩罚基数
        wallPenaltyThreshold = 100, -- 墙壁惩罚衰减距离（像素）
        directionSmoothFrames = 3,  -- 方向平滑帧数
        minHoldFrames = 3,          -- 最小方向保持帧数（防抖）

        ---------------------------------------------------------------
        -- 传感器
        ---------------------------------------------------------------
        combatFrameInterval = 1,    -- 战斗中采集间隔（帧）
        idleFrameInterval = 15,     -- 空闲时采集间隔（帧）
        projectileExpiry = 5,       -- 弹幕追踪过期帧数
        enemyExpiry = 10,           -- 敌人追踪过期帧数
        ownershipCacheTtl = 180,    -- 弹幕归属缓存帧数
        maxProjectiles = 300,       -- 弹幕采集上限（防御）
        degradeThreshold = 50,      -- 弹幕数超过此值 → 采样降级
        budgetMs = 1.5,             -- 每帧决策预算（毫秒，原则4；Tier 1 轨迹评分需要更大预算）

        ---------------------------------------------------------------
        -- 显示
        ---------------------------------------------------------------
        renderEnabled = false,      -- 视觉反馈总开关
        renderThreatBar = true,     -- 威胁等级条
        renderDodgeArrow = true,    -- 闪避方向箭头
        renderWeight = true,        -- AI 权重显示
        renderGradient = false,     -- 弹幕场梯度可视化
        pureMode = false,           -- 纯净模式：关闭所有视觉

        ---------------------------------------------------------------
        -- 录制
        ---------------------------------------------------------------
        recordingEnabled = true,    -- 环形缓冲录制（默认开：玩的过程发现问题要能回查数据；
                                    --   无 --luadebug 时自动降级为纯内存，无副作用）
        deathReplayEnabled = true,  -- 死亡时输出回放
        replayBufferSeconds = 30,   -- 缓冲时长（秒）
        snapshotDetail = 2,         -- 1最小 2标准 3详细 4全量诊断（逐威胁明细+候选评分）
        traceHazardMax = 16,        -- 级别4逐威胁明细条数上限
        traceHazardRadius = 300,    -- 级别4逐威胁纳入半径（像素，相对玩家）

        ---------------------------------------------------------------
        -- 调试
        ---------------------------------------------------------------
        observationMode = false,    -- 观察模式：只采集不控制
        profilerEnabled = false,    -- 性能分析
        diagnosticsEnabled = false, -- 诊断事件日志
        logEnabled = false,         -- 控制台日志
    }
end

return Defaults
