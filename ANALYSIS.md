# 以撒的结合 自动闪避Mod — 三项目综合分析报告

> **目标版本**: The Binding of Isaac: Repentance
> **目标效果**: 无人机式自动避障 — 当危险来临时，自动在玩家输入中叠加偏移量实现走位躲避，不打断玩家操作
> **分析日期**: 2026-09-06

---

## 一、三个项目总览

| 维度               | auto_dodge_helper (Steam ID: 3769075414) | GhostStep                               | SocketBridge-refactor-v2       |
| ------------------ | ---------------------------------------- | --------------------------------------- | ------------------------------ |
| **定位**     | 纯Lua单文件自动闪避Mod                   | Lua多模块自动闪避Mod (VO+DWA)           | Lua↔Python 实时数据桥接框架   |
| **语言**     | Lua (4400行，单文件)                     | Lua (18模块，分层架构)                  | Lua 1700行 + Python 4000+行    |
| **算法**     | 候选方向评分系统                         | VO(速度障碍)+DWA(动态窗口)+候选评分降级 | 无活跃AI实现（仅基础设施）     |
| **状态**     | 成熟可用 (v0.2.12)                       | 开发中                                  | 基础设施完成，AI未接入         |
| **核心强项** | 威胁覆盖全面、弹道线逃逸惩罚、空间哈希   | 模块化架构、VO+DWA决策、MPC长期规划     | 传感器系统、实体追踪、录制回放 |
| **核心弱项** | 单文件、无寻路、魔法数字                 | 路径模拟代码重复、全局可变状态          | 无活跃AI实现                   |

---

## 〇、设计哲学与硬约束

> 以下7条原则贯穿整个系统设计，任何算法和实现都不得违反。

### 原则1: 借鉴思路，不照抄代码

GhostStep 随着迭代变得越来越难用，根本原因是**代码复杂度失控**。

- 只提取算法思想(VO/DWA/三层管线)，不复制实现
- 每个模块必须有清晰的输入/输出接口，不通过全局状态耦合
- 任何模块都必须能独立测试和替换

### 原则2: 永远保留玩家控制权

这是最核心的用户体验约束。程序**永远不能**让玩家失去对角色的控制。

- MAX_DODGE_WEIGHT = 0.85（最大值，不是默认值）
- 弹幕密集时也不能突破此上限
- 玩家持续向一个方向输入时，AI偏移只能让角色偏离该方向，不能完全逆转
- 紧急情况(如被墙角卡住)时，应**降低**AI介入权重，让玩家自行挣脱

### 原则3: 不修改角色数据

系统是纯**输入叠加**，绝不触碰以下内容：

- ❌ 不修改角色位置 (SetPosition)
- ❌ 不修改角色速度 (SetVelocity)
- ❌ 不修改角色属性 (Damage, Speed, Range等)
- ❌ 不修改角色状态 (EntityFlag, TearFlag等)
- ✅ 只做一件事: 在 MC_INPUT_ACTION 中返回偏移后的移动方向值

### 原则4: 性能底线 — 弹幕再多也不卡

大量弹幕时的性能是硬性要求：

- **空间分桶**: O(1)碰撞查询，不是O(n)遍历
- **动态节流**: 非威胁实体(掉落物/可交互物)不需要每帧扫描
- **采样降级**: 弹幕>50个时自动减少候选方向采样数(24→12)
- **预算机制**: 每帧决策总耗时不超过1ms(30fps下占3%)
- **性能监控**: 内置profiler，超过阈值时自动降级

### 原则5: 不卡墙角 + 能挣脱

墙角问题是所有闪避AI的通病。解决方案是**三层防御**：

**第一层 — 预防**: 评估候选方向时，对靠近墙壁的方向施加惩罚

```lua
-- 距墙壁越近，惩罚越大 (指数增长)
wall_penalty = base * math.exp(-dist_to_wall / wall_threshold)
```

**第二层 — 检测**: 如果角色已经靠墙(距墙壁<安全距离)，切换到"挣脱模式"

```lua
-- 挣脱模式: 大幅降低AI介入权重，让玩家自行操作
if dist_to_nearest_wall < WALL_STUCK_THRESHOLD then
    max_weight = 0.3  -- 从0.85降到0.3
end
```

**第三层 — 偏向**: 必须闪避时，优先选择远离墙壁的方向

```lua
-- 候选评分中加入"远离墙壁"奖励
away_bonus = dot(candidate_dir, away_from_wall_dir) * bonus_weight
```

### 原则6: 提前规避 > 极限闪避

现有的两个项目都有一个共性问题：**倾向于在最后一刻极限躲避**，而不是提前让角色处于安全位置。

实际玩家的行为模式是**规避**(evasion)而非**闪避**(dodge)：

- 闪避: 弹幕快打到时才移动 (reactive)
- 规避: 提前站到弹幕密度低的区域 (proactive)

系统应优先采用规避策略：

```lua
-- 威胁等级计算中，"弹幕密度"比"碰撞时间"权重更高
-- 碰撞时间5帧以内 → 紧急闪避 (Layer 2 escape_lock)
-- 碰撞时间5-15帧 → 提前规避 (向弹幕稀疏区移动)
-- 碰撞时间>15帧 → 微调站位 (保持玩家意图，轻微偏向安全区)
```

具体实现：**弹幕场梯度**

```lua
-- 计算当前位置周围的弹幕密度梯度
-- 梯度方向 = 弹幕密度增长最快的方向
-- 规避方向 = -梯度 (朝弹幕密度降低的方向)
-- 这比"离最近弹幕最远"更聪明：考虑了弹幕的整体分布
```

### 原则7: 最小移动原则

闪避移动应尽可能小，保持角色在合理位置，但这是**软约束**不是硬限制：

- **优先微调**: 威胁不紧急时，小幅偏移就够了，不要大范围跑动
- **保持射击方向**: 角色正在射击时，闪避不应大幅改变朝向
- **特殊攻击例外**: 妈妈的手/脚等大范围攻击确实需要大距离移动
- **威胁越高，允许移动越大**: 低威胁时偏好小幅调整，高威胁时不限制移动幅度
- **不要绝对化**: 不设硬性角度上限，避免限制算法在真正需要时的响应能力

```lua
-- 实现思路: 通过权重自然控制移动幅度，而非硬截断
-- 低威胁: w很小(0.1-0.3) → 自然产生小幅偏移
-- 中威胁: w中等(0.3-0.65) → 中等偏移
-- 高威胁: w最大(0.85) → 允许大范围移动
-- 不需要额外的clamp/角度限制，权重本身就是幅度控制器
```

---

## 二、逐项目深度分析

### 2.1 auto_dodge_helper (Steam ID: 3769075414)

#### 架构

```
单文件 main.lua (4400行)
├── CONFIG 表 (~120个可调参数)
├── State 表 (中央可变状态)
├── Terrain System (房间网格地图)
├── Entity Collector (实体收集与分类)
├── HazardQuery 类 (空间危险查询，含空间分桶)
├── Candidate Evaluator (候选方向生成与评分)
├── Control System (MC_INPUT_ACTION 输入拦截)
├── Safe Arrow Guide (可视化安全方向)
└── Console Command System (iad 命令系统)
```

#### 核心算法流程

```
每帧 MC_POST_PLAYER_UPDATE:
  1. 构建/缓存房间地形网格 (可通行性、危险类型、代价)
  2. 收集并分类所有实体:
     - 弹幕 (6种运动模式: 直线/曲线/轨道/正弦/追踪/爆炸)
     - 激光 (含旋转)
     - 炸弹 (含爆炸半径)
     - 效果 (水坑、冲击波、火焰)
     - NPC攻击前兆 (妈妈的手、Daddy Long Legs等动画检测)
  3. 构建 HazardQuery (空间分桶哈希)
  4. 决策:
     a. 模拟当前路径 → 检查是否碰撞
     b. 生成24个候选方向 (压力方向、切线方向、玩家输入方向、16方位采样)
     c. 对每个候选评分:
        - 地形清障 (不可通行 → 拒绝)
        - 碰撞惩罚 (紧急/普通模式不同权重)
        - ★ 弹道线逃逸惩罚 (沿弹幕轨迹方向重罚，base=900,000)
        - 多威胁间距惩罚 (二次距离衰减)
        - 与玩家输入方向对齐加分
     d. 选最低分方向
  5. 通过 MC_INPUT_ACTION 覆写移动输入
```

#### ★ 最佳实践 — 弹道线逃逸惩罚

```lua
-- 使用叉积判断玩家在弹幕轨迹的哪一侧
-- 惩罚沿弹幕方向的移动，鼓励垂直逃离
local side = cross(travel, rel)
local lateral = cross(travel, normalizedDirection)
local escape = lateral
if math.abs(side) <= onLineDistance then
    escape = math.abs(lateral)      -- 在弹道线上，任何垂直方向都算逃离
elseif side < 0 then
    escape = -lateral                -- 确保逃离方向始终为正
end
if escape < minPerp then
    penalty = penalty + basePenalty + deficit * deficitPenalty
end
```

**为什么优秀**: 解决了弹幕游戏AI的经典问题——"沿着弹幕流方向躲避"。900,000的基础惩罚使算法几乎不可能选择沿弹幕方向移动。

#### ★ 最佳实践 — 空间分桶哈希

```lua
-- 预计算弹幕未来位置到空间网格
-- cellSize=80, range=1 (检查自身+邻居)
-- 快速弹幕(speed>=12)使用扫掠线段分桶
-- O(n) 碰撞检查 → O(1) 平均查找
```

#### ★ 最佳实践 — 弧线弹幕预测

```lua
-- 三点圆拟合，预测曲线/轨道弹幕
local d = 2 * (ax * (by - cy) + bx * (cy - ay) + cx * (ay - by))
-- 求外接圆中心 → 弧线轨迹预测
```

#### 问题清单

| # | 问题                   | 严重性  | 说明                                        |
| - | ---------------------- | ------- | ------------------------------------------- |
| 1 | **完全接管输入** | ⚠️ 高 | 闪避时直接替换玩家输入方向，玩家失去控制感  |
| 2 | 无寻路                 | 中      | 只评估直线方向，无法绕过障碍物              |
| 3 | 弹幕预测忽略墙壁       | 中      | 长距离预测在墙后产生虚假危险区              |
| 4 | 正弦弹幕预测简化       | 低      | 固定振幅14/周期18，不匹配所有摆动类型       |
| 5 | 预测视野限制           | 低      | 最大28帧(~0.93秒@30fps)，远距离慢弹幕反应迟 |
| 6 | 4400行单文件           | 低      | 不影响功能，但难以维护                      |
| 7 | 大量魔法数字           | 低      | 评分函数中嵌入50万/10万等硬编码常数         |

---

### 2.2 GhostStep (用户自有项目)

#### 架构

```
GhostStep/
├── main.lua                    # 入口，加载顺序控制，注册5个回调
├── core/
│   ├── config.lua              # 200+配置参数
│   ├── state.lua               # 全局可变状态
│   └── constants.lua           # 常量定义
├── entities/
│   ├── collector.lua           # 实体收集
│   ├── hazard_query.lua        # 空间危险查询
│   └── projectile_tracker.lua  # 弹幕追踪(历史记录)
├── decision/
│   ├── candidates.lua          # 候选方向生成
│   ├── scoring.lua             # 候选评分
│   ├── vo_planner.lua          # ★ 速度障碍(VO)规划器
│   ├── dwa_planner.lua         # ★ 动态窗口(DWA)规划器
│   └── mpc_planner.lua         # 模型预测控制(MPC)
├── motion/
│   ├── motion_model.lua        # 运动模型
│   └── path_sim.lua            # 路径模拟
├── input/
│   └── controller.lua          # 输入控制
├── render/
│   └── debug_render.lua        # 调试渲染
├── utils/
│   ├── math_utils.lua          # 数学工具
│   ├── spatial.lua             # 空间分桶
│   └── pcall_wrapper.lua       # 安全调用
└── data/
    └── entity_defs.lua         # 实体定义数据
```

#### 核心算法 — 三层决策管线

```
Layer 1: 早期垂直闪避 (1-2个弹幕时)
  → 快速路径：分析弹幕轨迹，直接计算垂直逃离方向

Layer 2: 逃离锁定 (玩家在危险区内时)
  → 带方向记忆的逃离模式，保持逃离方向直到脱离危险

Layer 3: VO + DWA 速度空间规划 (复杂弹幕场景)
  → VO: 将每个弹幕映射为"速度障碍锥"，排除会碰撞的速度
  → DWA: 在可达速度窗口内搜索最优速度
  → 目标函数: G(v) = α·Heading + β·Clearance + γ·Velocity
  → 降级: VO+DWA失败时回退到候选评分系统(类似auto_dodge_helper)

可选: MPC 长期目标方向
  → 提供中期(10-20帧)的最优移动方向建议
```

#### ★ 最佳实践 — VO速度障碍

```
概念：每个弹幕定义一个"禁止速度区"(速度锥)
      如果角色以某速度移动会与弹幕碰撞，则该速度被禁止

弹幕 B 在位置 pB，速度 vB
角色在位置 pA，考虑速度 vA
相对速度 vRel = vA - vB
如果 vRel 指向弹幕碰撞区域 → vA 被禁止

优势：天然考虑弹幕运动，无需逐帧模拟
```

#### ★ 最佳实践 — DWA动态窗口

```
受机器人避障算法启发：
1. 根据角色当前速度和加速度限制，计算下一帧可达速度窗口
2. 在速度窗口内采样多个(vx, vy)组合
3. 对每个采样速度模拟未来N帧轨迹
4. 评分: 目标方向 + 安全间距 + 速度
5. 选择最优速度

优势：尊重角色物理限制，输出平滑自然
```

#### 问题清单

| # | 问题                       | 严重性  | 说明                                          |
| - | -------------------------- | ------- | --------------------------------------------- |
| 1 | **完全接管输入**     | ⚠️ 高 | 与auto_dodge_helper相同问题，未实现"叠加偏移" |
| 2 | 路径模拟代码重复           | 中      | 4个模块中存在相同的路径模拟逻辑               |
| 3 | 全局可变状态               | 中      | state.lua被多个模块直接读写，隐式耦合         |
| 4 | 200+配置参数相互依赖       | 中      | 调参困难，参数间关系不明确                    |
| 5 | VO+DWA在极度弹幕密集时性能 | 低      | 速度空间采样数量需动态调整                    |

---

### 2.3 SocketBridge-refactor-v2

#### 架构

```
SocketBridge-refactor-v2/
├── main.lua                    # Lua端: 12个传感器 + TCP通信 (1717行)
├── python/
│   ├── facade.py               # 统一异步入口
│   ├── connection/server.py    # asyncio TCP服务器 (端口9527)
│   ├── protocol/schema.py      # Pydantic数据模型
│   ├── sensors/                # 传感器解析器
│   ├── entities/tracker.py     # 实体状态跟踪器
│   ├── persistence/            # 录制/回放系统
│   ├── validation/             # 质量监控
│   └── apps/                   # 应用工具 (控制台/录制/可视化)
```

#### 核心能力

- **12类传感器**: 玩家位置、敌人、弹幕(敌方/己方/激光)、房间布局、炸弹、火焰、掉落物、可交互物
- **动态节流**: 战斗中每帧采集，空闲时每15帧
- **实体状态追踪**: `EntityStateManager<T>` 跨帧追踪实体身份
- **录制回放**: gzip压缩JSONL，支持离线训练和调试
- **多客户端Hub**: 多个Python应用同时连接同一游戏

#### ★ 深度挖掘 — 可直接移植的设计模式

SocketBridge 最大的价值不在于它的AI（它没有），而在于它为实时游戏数据采集设计的**工程模式**。
以下8个模式全部来自其 Lua 端代码(main.lua, 1717行)，可直接移植到纯Lua闪避mod中：

**模式1: 传感器注册表 (Sensor Registry)**

每个传感器是一个自描述表，注册到统一注册表中：

```lua
-- 定义传感器 (已经是纯Lua代码，可直接复用)
{
    name = "ENEMIES",
    search = {
        strategy = "partition",          -- "partition" | "callback" | "hybrid"
        partitions = EntityPartition.ENEMY, -- Isaac.FindInRadius 的位掩码
        radius = 20,                     -- 格子单位，*40转像素
        sort_by_distance = true,
    },
    throttle = {
        dynamic = true,                  -- 启用战斗/空闲动态切换
        combat_interval = 1,             -- 战斗中每帧采集
        idle_interval = 15,              -- 空闲时每15帧
    },
    cache = { strategy = "hash" },       -- 哈希变更检测
    triggers = { "MC_POST_NPC_DEATH", "MC_POST_NEW_ROOM" },  -- 事件触发强制采集
    extract = function(entity, player) ... end,
}
```

**价值**: 数据采集的标准化框架。注册一次，自动处理节流/缓存/触发，传感器代码无需关心时序。

**模式2: 动态节流 (Dynamic Throttle)**

战斗中敌人和弹幕**每帧**采集，空闲时**每15帧**：

```lua
-- 战斗检测: room:GetAliveEnemiesCount() > 0
-- 每个传感器有独立帧计数器
-- ENEMIES/PROJECTILES: combat=1, idle=15
-- PLAYER_POSITION: 始终=1
-- PLAYER_INVENTORY: 固定=90
```

**价值**: 闪避mod最核心的性能优化。空闲时不浪费CPU扫描实体，战斗中不遗漏任何弹幕。

**模式3: 实体状态追踪器 (Entity State Tracker)**

按 entity.Index 跨帧追踪实体身份，含**按类型过期**和**历史环形缓冲**：

```lua
-- 按类型配置过期帧数
local EXPIRY = {
    enemy_projectiles = 5,   -- 弹幕移动极快，5帧未见即过期
    enemies = 10,            -- 敌人10帧
    pickups = 30,            -- 掉落物相对静止
    grid_entities = -1,      -- 地形永不过期
}

-- 追踪器核心逻辑
local tracked = {}  -- keyed by entity.Index
local function updateEntities(newList, frame)
    local seen = {}
    for _, e in ipairs(newList) do
        seen[e.Index] = true
        if tracked[e.Index] then
            tracked[e.Index].data = e
            tracked[e.Index].last_frame = frame
            tracked[e.Index].update_count = tracked[e.Index].update_count + 1
            -- 追加到历史环形缓冲 (最多10条)
            local hist = tracked[e.Index].history
            hist[#hist + 1] = {pos = e.Position, vel = e.Velocity, frame = frame}
            if #hist > 10 then table.remove(hist, 1) end
        else
            tracked[e.Index] = {
                data = e, first_frame = frame, last_frame = frame,
                update_count = 1,
                history = {{pos = e.Position, vel = e.Velocity, frame = frame}},
            }
        end
    end
    -- 过期清理
    for id, t in pairs(tracked) do
        local expiry = EXPIRY[entity_type] or 10
        if expiry > 0 and not seen[id] and (frame - t.last_frame) > expiry then
            tracked[id] = nil
        end
    end
end

-- 查询接口
-- get_active(max_stale) — 获取N帧内见过的实体
-- get_history(id) — 获取位置/速度历史，用于轨迹预测
-- get_staleness(id) — 距上次见过了几帧
```

**价值**: 没有跨帧追踪就无法预测弹幕轨迹。历史环形缓冲直接支持弧线预测(三点圆拟合)。

**模式4: 哈希变更检测**

递归拼接所有键值对为字符串，帧间比较：

```lua
local function simpleHash(data)
    if type(data) ~= "table" then return tostring(data) end
    local parts = {}
    for k, v in pairs(data) do
        parts[#parts + 1] = k .. simpleHash(v)
    end
    table.sort(parts)  -- 保证顺序一致
    return table.concat(parts)
end
-- 数据未变 → 跳过后续处理
```

**价值**: 空闲时地形/静态实体不变，直接跳过重建空间分桶的开销。

**模式5: 传感器触发器 (Sensor Triggers)**

将 Isaac 回调映射到强制传感器采集，绕过节流：

```lua
local TRIGGERS = {
    MC_POST_NPC_DEATH   = {"ENEMIES"},           -- 敌人死亡立即刷新
    MC_POST_NEW_ROOM    = {"ROOM_LAYOUT","ENEMIES","PICKUPS"},  -- 进房间全量采集
    MC_POST_PICKUP_INIT = {"PICKUPS"},            -- 掉落物生成立即刷新
}
-- forcePending 表确保强制数据在下一帧 collectAll() 中被包含
```

**价值**: 事件驱动替代轮询。敌人死亡立即更新威胁评估，不用等下一帧节流周期。

**模式6: 房间切换延迟提交**

房间Index变化时不立即使用新房间数据，先验证 GetRoom() 有效：

```lua
if room:GetRoom() ~= nil then
    State.currentRoom = newRoomIndex  -- 提交
else
    -- 延迟到下一帧重试 (房间过渡动画中)
end
```

**价值**: 防止在房间过渡动画中读取到nil数据导致崩溃。

**模式7: 双帧计数器 (来自EID最佳实践)**

```lua
State.updateCount = 0  -- MC_POST_UPDATE (30fps, 暂停时停止)
State.renderCount = 0  -- MC_POST_RENDER (60fps, 暂停时继续)
-- 所有游戏逻辑用 updateCount (暂停时不执行)
-- 所有UI渲染用 renderCount (暂停时仍显示)
```

**价值**: Isaac modding 标准实践，防止暂停时逻辑继续跑。

**模式8: 录制环形缓冲 (Ring Buffer)**

不是完整的录制/回放系统，而是保留最近N秒的传感器快照：

```lua
local RingBuffer = {data = {}, maxSize = 900}  -- 30fps × 30秒

function RingBuffer:push(snapshot)
    self.data[self.head] = snapshot
    self.head = (self.head + 1) % self.maxSize
    if self.count < self.maxSize then self.count = self.count + 1 end
end

function RingBuffer:getRecent(n)
    -- 返回最近n条快照，用于死亡回放分析
end

function RingBuffer:getFrame(targetFrame)
    -- 按帧号精确查找，用于调试
end

-- 每帧快照内容:
{
    frame = 12345,
    player_pos = Vector(100, 200),
    player_vel = Vector(1, 0),
    player_input = Vector(1, 0),
    projectiles = { ... },      -- 当帧所有弹幕状态
    enemies = { ... },          -- 当帧所有敌人状态
    threat_level = 0.72,
    dodge_dir = Vector(-0.3, 0.95),
    dodge_weight = 0.65,
    decision_layer = "vo_dwa",  -- 使用了哪层决策
}
```

**用途**:

- **死亡回放**: 玩家死亡时自动输出最后30秒的威胁演变，帮助调参
- **离线分析**: 导出为JSONL(类似SocketBridge的格式)，可用Python脚本分析
- **训练数据**: 为未来AI训练提供人类/自动闪避的行为数据

**录制系统扩展方案** (可选，Phase 4实现):

```lua
-- 可选: 持久化录制 (需要 --luadebug)
local Recorder = {}

function Recorder:startSession()
    self.sessionDir = "ghoststep_sessions/" .. os.date("%Y%m%d_%H%M%S")
    self.buffer = {}
    self.frameCount = 0
end

function Recorder:recordFrame(snapshot)
    self.buffer[#self.buffer + 1] = snapshot
    self.frameCount = self.frameCount + 1
    -- 每500帧刷盘
    if #self.buffer >= 500 then self:flush() end
end

function Recorder:flush()
    -- 写入 JSONL 文件 (一行一条JSON)
    -- 不压缩 (Lua无gzip)，但JSONL格式便于流式读取
    local filepath = self.sessionDir .. "/frames_" .. os.time() .. ".jsonl"
    local f = io.open(filepath, "a")
    for _, snap in ipairs(self.buffer) do
        f:write(json.encode(snap) .. "\n")
    end
    f:close()
    self.buffer = {}
end

function Recorder:stopSession()
    self:flush()
    -- 写入 metadata.json
    local meta = {
        start_frame = self.startFrame,
        end_frame = self.startFrame + self.frameCount,
        total_frames = self.frameCount,
        rooms_visited = self.roomsVisited,
        damage_taken = self.damageTaken,
    }
    -- 保存元数据...
end
```

#### 问题清单

| # | 问题                   | 严重性  | 说明                                  |
| - | ---------------------- | ------- | ------------------------------------- |
| 1 | **无活跃AI实现** | ⚠️ 高 | 归档代码与v3.0架构不兼容              |
| 2 | 调试代码残留           | 低      | 多处print到stderr                     |
| 3 | Lua端阻塞socket        | 低      | 连接时可能导致掉帧                    |
| 4 | 需要--luadebug启动参数 | 中      | LuaSocket依赖                         |
| 5 | 哈希函数非确定性       | 低      | pairs()遍历顺序不确定，需加table.sort |

---

## 三、交叉对比：精华与糟粕

### 3.1 精华 — 必须采纳的技术

| #  | 技术                          | 来源              | 采纳理由                                         |
| -- | ----------------------------- | ----------------- | ------------------------------------------------ |
| 1  | **弹道线逃逸惩罚**      | auto_dodge_helper | 解决"沿弹幕流躲避"的经典AI问题，数学上优雅       |
| 2  | **空间分桶哈希**        | auto_dodge_helper | O(1)碰撞检查，性能关键                           |
| 3  | **三点圆拟合弧线预测**  | auto_dodge_helper | 精确预测曲线/轨道弹幕                            |
| 4  | **VO速度障碍决策**      | GhostStep         | 天然处理动态弹幕，比纯候选评分更智能             |
| 5  | **DWA动态窗口**         | GhostStep         | 尊重角色物理限制，输出平滑                       |
| 6  | **多层决策管线**        | GhostStep         | 简单场景快速路径，复杂场景精细规划               |
| 7  | **模块化架构**          | GhostStep         | 可维护、可测试、可独立优化                       |
| 8  | **NPC攻击动画检测**     | auto_dodge_helper | 妈妈的手/脚等预警式躲避                          |
| 9  | **防御性编码 (pcall)**  | 全部              | 防止mod崩溃导致游戏崩溃                          |
| 10 | **★ 传感器注册表**     | SocketBridge      | 数据采集标准化框架，注册一次自动处理时序         |
| 11 | **★ 动态节流**         | SocketBridge      | 战斗每帧/空闲每15帧，闪避mod最核心的性能优化     |
| 12 | **★ 实体状态追踪器**   | SocketBridge      | 跨帧追踪entity.Index，含按类型过期和历史环形缓冲 |
| 13 | **★ 哈希变更检测**     | SocketBridge      | 数据未变时跳过处理，空闲时几乎零开销             |
| 14 | **★ 传感器触发器**     | SocketBridge      | 事件驱动(死亡/进房)替代轮询，立即响应不延迟      |
| 15 | **★ 房间切换延迟提交** | SocketBridge      | 防止过渡动画中读nil数据崩溃                      |
| 16 | **★ 双帧计数器**       | SocketBridge(EID) | update逻辑暂停时停止，render不受影响             |
| 17 | **★ 录制环形缓冲**     | SocketBridge      | 最近30秒快照，死亡回放+调参+离线分析             |

### 3.2 糟粕 — 必须摒弃的做法

| # | 做法                       | 来源                         | 摒弃理由                  | 替代方案                 |
| - | -------------------------- | ---------------------------- | ------------------------- | ------------------------ |
| 1 | **完全接管玩家输入** | auto_dodge_helper, GhostStep | 与需求"叠加偏移"冲突      | 偏移叠加模式（见第四节） |
| 2 | 4400行单文件               | auto_dodge_helper            | 不可维护                  | 模块化拆分               |
| 3 | 全局可变State表            | GhostStep                    | 隐式耦合                  | 局部状态 + 显式参数传递  |
| 4 | 200+扁平配置               | GhostStep                    | 参数间关系不明            | 分组配置 + 预设档位      |
| 5 | 路径模拟代码重复           | GhostStep                    | 维护成本                  | 抽取为公共模块           |
| 6 | 弹幕预测忽略墙壁           | auto_dodge_helper            | 产生虚假危险区            | 加入墙壁碰撞检测         |
| 7 | 无威胁等级区分             | auto_dodge_helper            | 1点伤害和10点伤害同等对待 | 按伤害权重评分           |
| 8 | 魔法数字硬编码             | auto_dodge_helper            | 调参困难                  | 全部收归CONFIG           |

---

## 四、核心设计方案：叠加偏移模式

> 详见第〇节"设计哲学与硬约束"中的7条原则。本节聚焦数学模型。

### 4.1 问题定义

```
传统模式 (auto_dodge_helper / GhostStep):
  玩家输入 → [被丢弃] → AI完全接管 → 输出移动方向
  结果：玩家感觉失控，操作被打断

目标模式 (你要的"无人机避障"):
  玩家输入 → [保留] + [AI偏移叠加] → 合成输出
  结果：玩家仍在操控，但危险时自动"推开"角色
  约束：永远保留≥15%玩家影响力 (原则2)
        只修改输入值，不碰角色数据 (原则3)
```

### 4.2 数学模型

```lua
-- 输入合成公式 (受原则2/3/5/7约束)
-- P = 玩家输入方向 (归一化向量)
-- D = AI计算的闪避方向 (归一化向量)
-- t = 威胁等级 [0, 1]
-- w = 混合权重 (由威胁等级通过S曲线平滑映射)
--
-- output = normalize(P + w(t) * D)
--
-- w(t) 设计:
--   t < 0.25 (低威胁):  w = 0         → 完全由玩家控制
--   0.25 ≤ t < 0.65 (中威胁): w = smoothstep过渡  → 轻微偏移
--   t ≥ 0.65 (高威胁):  w → 0.85      → 强偏移，但仍保留玩家输入分量
--
-- 关键约束 (原则2): MAX_DODGE_WEIGHT = 0.85，永远不为1.0
-- 关键约束 (原则5): 靠墙时 max_weight 降到 0.3，让玩家自行挣脱
-- 关键约束 (原则7): 通过权重自然控制移动幅度，不设硬性角度限制
```

### 4.3 威胁等级计算 — 含弹幕场梯度(原则6: 提前规避)

```lua
-- 两级威胁评估:

-- Level 1: 紧急碰撞检测 (逃不过才触发)
--   firstCollisionFrame(player_input_path) → frames_until_hit
--   if frames_until_hit ≤ 5:  威胁等级 = 紧急(>0.8)

-- Level 2: 弹幕场密度梯度 (提前规避的依据，原则6核心)
--   统计角色周围R像素内各方向的弹幕数量×速度
--   gradient = 弹幕密度增长最快的方向
--   avoidance_dir = -gradient (朝密度降低的方向)
--   density_score = local_density / max_expected_density → [0, 1]

-- 综合威胁等级:
--   threat_level = max(碰撞紧急度, 密度分数×0.7)
--   密度分数乘0.7是因为密度威胁不如碰撞紧急，但更早触发规避

-- 防御性规则 (来自SocketBridge已知问题):
--   enemy_hp = max(0, raw_hp)   -- 敌人HP可能短暂为负
--   aim_dir 处理零向量
```

### 4.4 三级响应模式 (原则6的体现: 规避 > 闪避)

```lua
-- 不同威胁等级对应不同响应策略:

if threat_level < THREAT_LOW then
    -- 安全区: 完全由玩家控制
    output = playerInput

elseif threat_level < THREAT_MEDIUM then
    -- ★ 提前规避: 微调方向，朝弹幕稀疏区偏移 (原则6+7)
    -- 这是"预防"阶段，玩家几乎感觉不到介入
    local deviation = computeGradientAvoidance()  -- 弹幕场梯度的反方向
    local w = smoothstep(remap(t, LOW, MED, 0, 1)) * 0.3  -- 最大30%权重
    output = normalize(P + w * deviation)

elseif threat_level < THREAT_HIGH then
    -- 主动闪避: 中等偏移，向安全区移动
    local dodge = computeDodgeDirection()  -- 决策管线输出
    local w = smoothstep(remap(t, MED, HIGH, 0, 1)) * 0.65  -- 最大65%权重
    output = normalize(P + w * dodge)

else
    -- 紧急闪避: 最大偏移，但仍保留15%玩家控制 (原则2)
    local dodge = computeDodgeDirection()
    local w = MAX_DODGE_WEIGHT  -- 0.85
    -- 墙角检测: 靠墙时降权 (原则5)
    if dist_to_nearest_wall < WALL_STUCK_THRESHOLD then
        w = math.min(w, 0.3)
    end
    output = normalize(P + w * dodge)
end
```

### 4.5 输入合成核心代码

```lua
function synthesizeInput(playerInput, dodgeDir, threatLevel, wallDist)
    -- 无威胁
    if threatLevel < THREAT_LOW then
        return playerInput
    end

    -- 墙角挣脱模式 (原则5)
    local maxW = MAX_DODGE_WEIGHT
    if wallDist < WALL_STUCK_THRESHOLD then
        maxW = 0.3  -- 大幅降低AI介入，让玩家自行操作
    end

    -- S曲线平滑过渡
    local t = remap(threatLevel, THREAT_LOW, THREAT_HIGH, 0, 1)
    local w = smoothstep(t) * maxW

    -- 偏移合成: 权重w本身就是幅度控制器 (原则7)
    -- 低威胁→小w→自然小幅度，高威胁→大w→允许大范围移动
    local combined = playerInput * (1 - w) + dodgeDir * w

    -- 归一化 (保持移动速度)
    if combined:Length() > 0.01 then
        return combined:Normalized()
    end
    return Vector(0, 0)
end
```

### 4.6 边界情况处理

| 情况                   | 处理                                             | 原则     |
| ---------------------- | ------------------------------------------------ | -------- |
| 玩家未输入 (站立不动)  | AI偏移仍生效，角色被"推开"                       | —       |
| 玩家输入与闪避方向相反 | 按权重混合，低威胁时只做小幅偏移，高威胁时不限制 | 原则7    |
| 玩家输入与闪避方向相同 | 增强效果，角色更快到达安全区                     | —       |
| 多方向威胁 (弹幕风暴)  | 权重最高0.85，优先弹幕稀疏区(规避>闪避)          | 原则2, 6 |
| 威胁消失               | w平滑回0，避免突然的控制感切换                   | —       |
| 角色靠墙               | max_weight降到0.3，让玩家自行挣脱                | 原则5    |
| 大范围特殊攻击         | 高威胁等级自然产生大权重，允许大范围移动         | 原则7    |
| 弹幕密度极高           | 采样降级+预算控制，保证不卡                      | 原则4    |
| 帧预算超时             | 跳过VO+DWA，直接用快速路径                       | 原则4    |

---

## 五、推荐架构设计

### 5.1 整体管线

```
┌──────────────────────────────────────────────────────────────┐
│                     GhostStep v3 架构                         │
├──────────────────────────────────────────────────────────────┤
│                                                               │
│  ┌──────────┐   ┌──────────────┐   ┌──────────────────────┐  │
│  │ Sensors  │ → │ Threat Engine│ → │ Decision Pipeline    │  │
│  │ (数据层) │   │ (威胁评估层) │   │ (决策层)             │  │
│  └──────────┘   └──────────────┘   └──────────────────────┘  │
│       │              │                      │                 │
│       ▼              ▼                      ▼                 │
│  ┌──────────┐   ┌──────────────┐   ┌──────────────────────┐  │
│  │ Terrain  │   │ Threat Level │   │ Input Synthesizer    │  │
│  │ (地形层) │   │ Calculator   │   │ (输入合成层) ★核心  │  │
│  └──────────┘   └──────────────┘   └──────────────────────┘  │
│                                           │                   │
│                                           ▼                   │
│                              ┌──────────────────────┐        │
│                              │ MC_INPUT_ACTION      │        │
│                              │ (叠加输出到游戏)     │        │
│                              └──────────────────────┘        │
│                                                               │
│  ┌───────────────────────────────────────────────────────┐   │
│  │ Debug / Render (调试渲染层, 可开关)                    │   │
│  └───────────────────────────────────────────────────────┘   │
└──────────────────────────────────────────────────────────────┘
```

### 5.2 模块划分

```
GhostStep/
├── main.lua                    # 入口，加载模块，注册回调，双帧计数器
│
├── config/
│   ├── defaults.lua            # 默认配置 (分组: sensors/threat/decision/control/render)
│   ├── presets.lua             # 预设档位 (安全/平衡/激进)
│   ├── mcm.lua                 # ★ Mod Config Menu 集成 (所有设置接入MCM菜单)
│   └── runtime.lua             # 运行时状态 (ALT开关、当前档位)
│
├── sensors/                    # ── 数据采集层 (来自SocketBridge传感器模式) ──
│   ├── registry.lua            # ★ 传感器注册表 (统一采集/节流/缓存/触发框架)
│   ├── terrain.lua             # 地形网格 (房间进入时缓存，格子级可通行/危险/代价)
│   ├── projectiles.lua         # 弹幕采集与分类 (6种运动模式: 直线/曲线/轨道/正弦/追踪/爆炸)
│   ├── hazards.lua             # 非弹幕威胁 (激光/炸弹/水坑/火焰)
│   ├── npc_attacks.lua         # NPC攻击前兆检测 (动画字符串匹配)
│   └── player.lua              # 玩家状态 (位置/速度/输入方向)
│
├── entities/                   # ── 实体追踪层 (来自SocketBridge EntityTracker) ──
│   └── tracker.lua             # ★ 跨帧实体追踪器 (按Index追踪，按类型过期，历史环形缓冲)
│
├── threat/                     # ── 威胁评估层 ──
│   ├── hazard_query.lua        # 空间危险查询 (空间分桶哈希)
│   ├── projectile_predict.lua  # 弹幕轨迹预测 (直线/曲线/追踪/正弦/加速)
│   ├── threat_level.lua        # 综合威胁等级 [0,1]
│   └── spatial.lua             # 空间分桶工具
│
├── decision/                   # ── 决策层 ──
│   ├── pipeline.lua            # 三层决策管线调度器
│   ├── early_dodge.lua         # Layer 1: 单弹幕快速垂直闪避
│   ├── escape_lock.lua         # Layer 2: 危险区内逃离锁定
│   ├── vo_dwa.lua              # Layer 3: VO+DWA速度空间规划
│   ├── fallback.lua            # 降级: 候选方向评分
│   └── direction_smooth.lua    # 方向平滑与时序混合(防抖动)
│
├── control/                    # ── 控制层 ──
│   ├── input_reader.lua        # 读取玩家原始输入
│   ├── input_synthesizer.lua   # ★ 叠加偏移合成 (核心创新)
│   └── input_writer.lua        # MC_INPUT_ACTION 输出 (GET_ACTION_VALUE返回0.0-1.0)
│
├── render/                     # ── 渲染层 (可开关) ──
│   ├── overlay.lua             # 总控渲染 (用renderCount, 不用updateCount)
│   ├── threat_indicator.lua    # 威胁等级条
│   ├── dodge_arrow.lua         # 闪避方向箭头
│   ├── weight_display.lua      # 当前AI介入权重显示
│   └── status_indicator.lua    # 启用/禁用状态显示 (ALT键切换)
│
├── debug/
│   ├── console.lua             # 控制台命令 (gs ...)
│   ├── profiler.lua            # 性能分析 (EMA指数移动平均)
│   └── diagnostics.lua         # 诊断事件
│
├── recording/                  # ── 录制层 (来自SocketBridge录制模式) ──
│   ├── ring_buffer.lua         # ★ 环形缓冲 (内存中保留最近30秒快照)
│   ├── snapshot.lua            # 帧快照采集 (player/projectiles/threat/decision)
│   ├── death_replay.lua        # 死亡回放 (自动输出最后30秒威胁演变)
│   └── session_recorder.lua    # 可选: 持久化JSONL录制 (需--luadebug)
│
└── utils/
    ├── math_ext.lua            # 数学扩展 (叉积/圆拟合/平滑/哈希)
    ├── vector.lua              # 向量工具
    └── safe_call.lua           # pcall包装器
```

### 5.3 决策层详细流程

```
每帧更新 (预算上限: 1ms):

  1. Sensors 采集
     → terrain:    房间进入时缓存，格子级(可通行/危险/代价)
     → projectiles: 每帧更新，实体追踪器记录历史(用于弧线预测)
     → hazards:    每帧更新，激光/炸弹/水坑/火焰
     → npc_attacks: 每帧检测动画状态字符串
     → player:     每帧更新 (位置/速度/输入方向)

  2. Threat Engine 评估 (两级)
     → 碰撞检测:    模拟玩家当前路径，找firstCollisionFrame
     → 弹幕场梯度:  统计R像素内各方向弹幕密度×速度
                    gradient = 密度增长最快方向
                    avoidance_dir = -gradient (原则6: 提前规避)
     → 综合威胁等级: max(碰撞紧急度, 密度分数×0.7) → [0,1]

  3. Decision Pipeline (分层，每层有预算检查)
     [预算检查: 已用 > 0.7ms → 跳过复杂层，直接用快速路径]

     IF 威胁等级 < THREAT_LOW:
         → 不决策，玩家完全控制

     ELIF 威胁等级 < THREAT_MEDIUM:
         → ★ 弹幕场梯度微调 (新! 原则6+7)
         → 仅计算梯度方向，最大30%权重偏移
         → 玩家几乎感觉不到介入

     ELIF 弹幕数 ≤ 2 AND 非复杂场景:
         → early_dodge: 快速计算垂直逃离方向 (Layer 1)

     ELIF 玩家当前在危险区 (frame 0 就命中):
         → escape_lock: 带记忆的逃离方向 (Layer 2)

     ELSE:
         → vo_dwa: VO排除危险速度 → DWA搜索最优 (Layer 3)
         IF vo_dwa 无解 OR 超时:
             → fallback: 候选方向评分 (降级保底)

     → direction_smooth: 方向低通滤波，防抖动
     → wall_check: 靠墙时降权到0.3 (原则5)

  4. Input Synthesizer (核心创新)
     → 读取玩家原始输入 P
     → 读取闪避方向 D 和威胁等级 t
     → 墙角检测: dist_to_wall < threshold → max_weight=0.3
     → 权重控制幅度: w本身就是移动幅度控制器 (原则7)
     → output = normalize(P*(1-w) + D*w)
     → 通过 MC_INPUT_ACTION 写入游戏
```

---

## 六、用户确认结果

| 问题                 | 决定                                                         |
| -------------------- | ------------------------------------------------------------ |
| **视觉反馈**   | ✅ 需要显示(威胁等级、闪避方向、AI权重)，可在设置中开关      |
| **开关控制**   | ✅ ALT键切换，按一下开/按一下关，显示状态指示(类似GhostStep) |
| **开发优先级** | ✅ 先做核心体验 (输入叠加模式)，再扩展威胁类型               |
| **代码基础**   | ✅ 重新开始，参考两个项目的精华                              |
| **输入方式**   | ✅ 键盘+手柄（手柄摇杆是连续浮点值，需正确处理）             |
| **Co-op**      | ✅ 不需要联机支持，只处理P1                                  |
| **飞行角色**   | ✅ 第一版就需要支持（不同地形通行规则、免受地刺伤害）        |

---

## 七、开发路线图

### Phase 1: 核心体验 (第一优先级)

**目标**: 实现可用的叠加偏移闪避，覆盖最常见威胁

| #    | 任务                                            | 来源                           | 依赖       | 估时 |
| ---- | ----------------------------------------------- | ------------------------------ | ---------- | ---- |
| 1.1  | 项目骨架搭建 (main.lua + 模块加载 + 双帧计数器) | SocketBridge                   | 无         | 小   |
| 1.2  | config/defaults.lua — 分组配置                 | GhostStep                      | 无         | 小   |
| 1.3  | sensors/registry.lua — 传感器注册表框架        | ★ SocketBridge                | 无         | 中   |
| 1.4  | entities/tracker.lua — 跨帧实体追踪器          | ★ SocketBridge                | 无         | 中   |
| 1.5  | sensors/terrain.lua — 地形网格                 | auto_dodge_helper              | 无         | 中   |
| 1.6  | sensors/projectiles.lua — 弹幕采集(直线弹幕)   | SocketBridge+auto_dodge_helper | 1.3, 1.4   | 中   |
| 1.7  | sensors/player.lua — 玩家输入读取              | SocketBridge                   | 无         | 小   |
| 1.8  | threat/hazard_query.lua — 空间分桶哈希         | auto_dodge_helper              | 1.5, 1.6   | 中   |
| 1.9  | threat/projectile_predict.lua — 直线弹幕预测   | auto_dodge_helper              | 1.4, 1.6   | 小   |
| 1.10 | threat/threat_level.lua — 威胁等级计算         | 新设计                         | 1.8, 1.9   | 小   |
| 1.11 | decision/early_dodge.lua — 垂直闪避            | GhostStep                      | 1.9        | 中   |
| 1.12 | decision/fallback.lua — 候选评分(简化版)       | auto_dodge_helper              | 1.8        | 中   |
| 1.13 | decision/pipeline.lua — 管线调度               | GhostStep                      | 1.11, 1.12 | 小   |
| 1.14 | ★ control/input_synthesizer.lua — 叠加偏移    | 新设计(核心)                   | 1.13       | 中   |
| 1.15 | control/input_writer.lua — MC_INPUT_ACTION     | SocketBridge                   | 1.14       | 小   |
| 1.16 | ALT键开关 + 状态显示                            | SocketBridge                   | 1.15       | 小   |
| 1.17 | recording/ring_buffer.lua — 环形缓冲           | ★ SocketBridge                | 1.6, 1.10  | 小   |
| 1.18 | recording/death_replay.lua — 死亡回放          | ★ SocketBridge                | 1.17       | 小   |
| 1.19 | 测试：基础房间直线弹幕闪避 + 死亡回放验证       | 全部                           | —         | 中   |

**里程碑1**: 能在基础房间中自动偏移躲避直线弹幕，不打断玩家操作，死亡时可查看最后30秒威胁回放

### Phase 2: 决策增强

**目标**: 提升闪避质量和适应性

| #   | 任务                                     | 依赖     |
| --- | ---------------------------------------- | -------- |
| 2.1 | 弹幕运动模式扩展 (曲线/追踪/正弦/加速)   | Phase 1  |
| 2.2 | 弧线弹幕预测 (三点圆拟合)                | 2.1      |
| 2.3 | 弹道线逃逸惩罚 (从auto_dodge_helper移植) | 1.10     |
| 2.4 | decision/vo_dwa.lua — VO+DWA规划器      | 2.3      |
| 2.5 | decision/escape_lock.lua — 逃离锁定     | Phase 1  |
| 2.6 | pipeline三层决策集成                     | 2.4, 2.5 |
| 2.7 | 方向低通滤波 (防抖动)                    | 2.6      |

**里程碑2**: 复杂弹幕场景下闪避智能、平滑，方向不抖动

### Phase 3: 威胁覆盖扩展

| #   | 任务                                |
| --- | ----------------------------------- |
| 3.1 | 激光威胁 (含旋转激光)               |
| 3.2 | 炸弹威胁 (含爆炸半径)               |
| 3.3 | 效果威胁 (水坑/火焰/冲击波)         |
| 3.4 | NPC攻击前兆 (妈妈的手/脚等动画检测) |
| 3.5 | 弹幕预测加入墙壁碰撞                |
| 3.6 | 威胁等级按伤害权重区分              |

### Phase 4: 体验打磨

| #   | 任务                                        |
| --- | ------------------------------------------- |
| 4.1 | 调试渲染 (威胁等级条、闪避方向箭头、AI权重) |
| 4.2 | MCM配置菜单集成 (所有设置接入ModConfigMenu) |
| 4.3 | 控制台命令 (调试用)                         |
| 4.4 | 预设档位 (安全/平衡/激进)                   |
| 4.5 | 性能优化 (热点分析)                         |
| 4.6 | 边界情况测试 (墙角/密集弹幕/boss特殊攻击)   |

---

## 七.五、技术实现细节补遗 (审查补充)

> 本节补充审查中发现的8个遗漏的技术细节。

### 7.5.1 MC_INPUT_ACTION 实际调用方式 (关键)

`MC_INPUT_ACTION` 是**按轴逐一调用**的，不是一次性返回方向向量。

```
实际调用流程 (每帧):
  → onInputAction(entity, GET_ACTION_VALUE, ACTION_LEFT)  → 0.0 或 0.7
  → onInputAction(entity, GET_ACTION_VALUE, ACTION_RIGHT) → 0.0 或 0.3
  → onInputAction(entity, GET_ACTION_VALUE, ACTION_UP)    → 0.0
  → onInputAction(entity, GET_ACTION_VALUE, ACTION_DOWN)  → 0.0
```

实现方案：

```lua
-- 在 MC_POST_PLAYER_UPDATE 中: 计算合成方向，存到状态
State.control.direction = synthesizeInput(playerInput, dodgeDir, threatLevel, wallDist)
State.control.frame = Isaac.GetFrameCount()

-- 在 MC_INPUT_ACTION 中: 按轴提取分量
function onInputAction(entity, inputHook, action)
    if not entity or entity.Type ~= EntityType.ENTITY_PLAYER then return nil end
    if Isaac.GetFrameCount() - State.control.frame > 2 then return nil end
    if not isMoveAction(action) then return nil end  -- 只拦截 LEFT/RIGHT/UP/DOWN

    local dir = State.control.direction
    local value = actionValueForDirection(action, dir)

    if inputHook == InputHook.GET_ACTION_VALUE then
        return value          -- float [0, 1]
    elseif inputHook == InputHook.IS_ACTION_PRESSED
        or inputHook == InputHook.IS_ACTION_TRIGGERED then
        return value > 0      -- boolean
    end
    return nil                -- 不拦截其他 hook 类型
end

function actionValueForDirection(action, direction)
    local DEADZONE = 0.2
    if action == ButtonAction.ACTION_LEFT then
        return direction.X < -DEADZONE and math.min(1, -direction.X) or 0
    elseif action == ButtonAction.ACTION_RIGHT then
        return direction.X > DEADZONE and math.min(1, direction.X) or 0
    elseif action == ButtonAction.ACTION_UP then
        return direction.Y < -DEADZONE and math.min(1, -direction.Y) or 0
    elseif action == ButtonAction.ACTION_DOWN then
        return direction.Y > DEADZONE and math.min(1, direction.Y) or 0
    end
    return 0
end
```

**手柄摇杆注意**: 手柄摇杆输入是连续浮点值（-1到1），但我们的 hook 只覆盖 LEFT/RIGHT/UP/DOWN 四个离散动作。Isaac 内部会将摇杆映射到这四个动作的值上，所以 `GET_ACTION_VALUE` 返回的就是 0-1 的浮点数，天然支持手柄。

### 7.5.2 与其他 mod 的 MC_INPUT_ACTION 冲突

Isaac 回调系统按注册顺序处理，**第一个返回非 nil 的 hook 胜出**。

策略：**只在需要介入时返回非 nil**。

```lua
-- 无威胁时返回 nil，让其他 mod 正常工作
if State.control.mode == "none" then
    return nil  -- 不拦截
end
```

这与 auto_dodge_helper 和 GhostStep 的做法一致。mod 不会在安全时抢夺控制权。

### 7.5.3 飞行角色地形通行 (第一版就需要)

来自 auto_dodge_helper 的实现：

```lua
-- 通行性检查 — 飞行角色有不同的规则
function isCollisionWalkable(collision, canFly)
    if canFly then
        -- 飞行: 只有墙壁和实心格子阻挡
        return collision ~= GridCollisionClass.COLLISION_SOLID
           and collision ~= GridCollisionClass.COLLISION_WALL
    end
    -- 地面: 坑洞、物体、墙壁、实心都阻挡
    return collision ~= GridCollisionClass.COLLISION_OBJECT
       and collision ~= GridCollisionClass.COLLISION_SOLID
       and collision ~= GridCollisionClass.COLLISION_WALL
       and collision ~= GridCollisionClass.COLLISION_PIT
end

-- 地刺检查 — 飞行角色完全豁免
if isSpikeGridType(gridType) and playerState.canFly then
    return false  -- 不危险
end

-- canFly 收集方式:
canFly = player.CanFly or player:IsFlying()
```

### 7.5.4 地形特殊格子检测

```lua
-- 可伸缩地刺: state==0 时伸出(危险)，state~=0 时缩回(安全)
-- 包括 GRID_SPIKES (普通地刺) 和 GRID_SPIKES_ONOFF (可伸缩地刺)
function isSpikeDangerous(gridType, state, collision)
    if gridType == GridEntityType.GRID_ROCK_SPIKED then
        return collision ~= GridCollisionClass.COLLISION_NONE
    end
    if gridType == GridEntityType.GRID_SPIKES
    or gridType == GridEntityType.GRID_SPIKES_ONOFF then
        return (state or 0) == 0  -- state==0 → 伸出 → 危险
    end
    return false
end

-- TNT 装弹检测: State>1 或 VarData>0 → 已装弹 → 视为危险(爆炸半径90px)
function isArmedTnt(grid)
    if not grid then return false end
    return (grid.State or 0) > 1 or (grid.VarData or 0) > 0
end
```

### 7.5.5 弹幕归属判定 — 链式追踪

这是决定"哪些弹幕需要躲避"的核心逻辑。错误会导致躲避自己的眼泪或忽略敌方弹幕。

```lua
-- NPC 归属检测: 递归遍历 Parent → ParentNPC → SpawnerEntity，深度≤4
function hasNpcOwnerInChain(entity, depth)
    if not entity or (depth or 0) > 4 then return false end
    if entity.Type == EntityType.ENTITY_PLAYER
    or entity.Type == EntityType.ENTITY_FAMILIAR then
        return false  -- 玩家/跟班不是NPC
    end
    if entity:ToNPC() then return true end
    if entity.IsEnemy and entity:IsEnemy() then return true end
    -- 递归向上追踪
    return hasNpcOwnerInChain(entity.Parent, depth + 1)
        or hasNpcOwnerInChain(entity.ParentNPC, depth + 1)
        or hasNpcOwnerInChain(entity.SpawnerEntity, depth + 1)
end

-- 判定逻辑: NPC优先 → 玩家次之
function classifyProjectile(proj)
    -- 1. 先检查是否NPC发射的 (优先级高)
    if hasNpcOwnerInChain(proj, 0) then return "hostile" end
    -- 2. 再检查是否玩家/跟班发射的
    if proj.SpawnerType == EntityType.ENTITY_PLAYER
    or proj.SpawnerType == EntityType.ENTITY_FAMILIAR then
        return "friendly"
    end
    -- 3. 都不是 → 默认视为敌方 (安全优先)
    return "hostile"
end

-- 结果缓存: 180帧TTL, NPC归属一旦确认不可覆盖
-- 所有 entity 访问都用 pcall 包裹防止崩溃
```

### 7.5.6 房间过渡状态重置

```lua
function onNewRoom()
    -- 重置控制
    State.control.mode = "none"
    State.control.direction = Vector(0, 0)

    -- 失效地形缓存，立即重建
    State.terrain.valid = false
    buildTerrain()

    -- 清空弹幕追踪
    EntityTracker.clear("enemy_projectiles")
    EntityTracker.clear("enemies")

    -- 清空弹幕归属缓存
    State.projectileOwnership = {}

    -- 延迟提交: 验证房间数据有效
    if Game():GetRoom() ~= nil then
        State.currentRoom = Game():GetLevel():GetCurrentRoomIndex()
    end
    -- 否则下一帧重试
end
```

### 7.5.7 环形缓冲 GC 优化

```lua
-- 方案: 预分配表池，每帧重用，避免 GC 压力
local SnapshotPool = {free = {}, used = {}}

function SnapshotPool:acquire()
    local snap = table.remove(self.free) or {}
    return snap
end

function SnapshotPool:release(snap)
    -- 清空但不释放内存
    for k in pairs(snap) do snap[k] = nil end
    self.free[#self.free + 1] = snap
end

-- 使用:
function RingBuffer:push(newData)
    -- 释放最旧的快照回池
    if self.count >= self.maxSize then
        local old = self.data[self.head]
        if old then SnapshotPool:release(old) end
    end
    -- 从池中获取并复制数据
    local snap = SnapshotPool:acquire()
    for k, v in pairs(newData) do snap[k] = v end
    self.data[self.head] = snap
    self.head = (self.head + 1) % self.maxSize
    self.count = math.min(self.count + 1, self.maxSize)
end
```

### 7.5.8 弹幕场梯度具体计算方法

```lua
-- 参数
local GRADIENT_RADIUS = 120   -- 采样半径(像素)
local GRADIENT_BINS = 8       -- 8个方向bin(每45度一个)
local GRADIENT_WEIGHT_VEL = true  -- 按弹幕速度加权

function computeProjectileGradient(playerPos, projectiles)
    local bins = {}  -- bins[1..8]，每个累加密度×速度
    for i = 1, GRADIENT_BINS do bins[i] = 0 end

    for _, proj in ipairs(projectiles) do
        local delta = proj.Position - playerPos
        local dist = delta:Length()
        if dist < GRADIENT_RADIUS and dist > 1 then
            -- 距离衰减: 越近的弹幕权重越大
            local distWeight = 1 - (dist / GRADIENT_RADIUS)
            -- 速度加权: 快速弹幕威胁更大
            local speedWeight = GRADIENT_WEIGHT_VEL
                and (proj.Velocity:Length() / 10) or 1
            local weight = distWeight * math.min(speedWeight, 3)

            -- 映射到方向bin
            local angle = math.atan2(delta.Y, delta.X)
            local bin = math.floor(((angle + math.pi) / (2 * math.pi)) * GRADIENT_BINS) % GRADIENT_BINS + 1
            bins[bin] = bins[bin] + weight
        end
    end

    -- 计算梯度: 相邻bin的差值 → 密度增长最快的方向
    local gradX, gradY = 0, 0
    for i = 1, GRADIENT_BINS do
        local next_i = i % GRADIENT_BINS + 1
        local prev_i = (i - 2) % GRADIENT_BINS + 1
        local gradient = (bins[next_i] - bins[prev_i]) / 2
        local angle = (i - 1) * (2 * math.pi / GRADIENT_BINS)
        gradX = gradX + math.cos(angle) * gradient
        gradY = gradY + math.sin(angle) * gradient
    end

    -- 规避方向 = -梯度方向 (朝密度降低的方向)
    local len = math.sqrt(gradX * gradX + gradY * gradY)
    if len > 0.01 then
        return Vector(-gradX / len, -gradY / len)
    end
    return nil  -- 均匀分布，无梯度
end
```

**与 VO/DWA 的融合方式**: 弹幕场梯度只用于 THREAT_LOW 到 THREAT_MEDIUM 的"提前规避"阶段，权重最大30%。当威胁升级到 THREAT_MEDIUM 以上时，切换到 VO/DWA 决策——两者不会同时竞争控制权。

---

## 八、技术参考

### Isaac Modding API 关键回调

| 回调                      | 用途       | 说明                                                |
| ------------------------- | ---------- | --------------------------------------------------- |
| `MC_POST_PLAYER_UPDATE` | 主逻辑更新 | 每个玩家每帧触发 (30fps)                            |
| `MC_INPUT_ACTION`       | 输入叠加   | 返回数字(0-1)可做偏移叠加，返回true/false做完全替换 |
| `MC_POST_RENDER`        | UI渲染     | 每帧触发 (60fps)，仅用于显示                        |
| `MC_POST_NEW_ROOM`      | 房间切换   | 重建地形缓存                                        |
| `MC_ENTITY_TAKE_DMG`    | 受伤事件   | 用于诊断和调优                                      |

### DWA算法核心公式

参考 Fox et al. 1997 "The Dynamic Window Approach to Collision Avoidance":

```
目标函数: G(v,ω) = α·heading(v,ω) + β·clearance(v,ω) + γ·velocity(v,ω)

- heading:    朝向目标方向的程度
- clearance:  距最近障碍物的距离
- velocity:   当前速度(鼓励移动而非停滞)

在以撒中适配:
- v,ω → (vx, vy) 二维速度向量
- heading → 朝向安全区域(非固定目标)
- clearance → 距最近弹幕的距离
- velocity → 保持玩家期望的移动速度
```

### VO速度障碍核心概念

参考 Fiorini & Shiller 1998 "Motion Planning in Dynamic Environments Using Velocity Obstacles":

```
对于每个弹幕 B (位置 pB, 速度 vB, 碰撞半径 rB):
  角色 A (位置 pA) 考虑速度 vA 时:
  相对速度: vRel = vA - vB
  碰撞锥: 从 pA 指向 pB±rB 的锥形区域
  如果 vRel 落在碰撞锥内 → vA 被禁止

优势: 一次性排除所有会碰撞的速度，无需逐帧模拟
```

---

## 九、风险与对策

| 风险                | 影响              | 对策                                           | 原则 |
| ------------------- | ----------------- | ---------------------------------------------- | ---- |
| 输入延迟 (30fps)    | 偏移可能有1帧延迟 | 决策在MC_POST_PLAYER_UPDATE中同步完成          | —   |
| 过度修正 (AI主导)   | 玩家感觉"不听话"  | MAX_DODGE_WEIGHT=0.85 + 权重控制幅度           | 2, 7 |
| 修正不足 (轻威胁)   | 仍会受伤          | 弹幕场梯度提前规避，不等碰撞才反应             | 6    |
| 方向抖动 (密集弹幕) | 角色来回摆动      | 方向低通滤波 + 最小保持时间(3帧)               | —   |
| 卡墙角 (靠墙)       | 角色撞墙          | 三层防御: 墙壁惩罚/挣脱模式/远离偏向           | 5    |
| 性能问题 (大量弹幕) | 掉帧              | 空间分桶+动态节流+采样降级+帧预算1ms           | 4    |
| 极限闪避而非规避    | 玩家总在危险边缘  | 弹幕场梯度驱动提前规避，低威胁就开始微调       | 6    |
| 大范围移动破坏走位  | 角色跑太远        | 低威胁时权重低自然小幅度，高威胁不限制         | 7    |
| 误修改角色数据      | 游戏状态被破坏    | 只在MC_INPUT_ACTION返回值，不调用SetPosition等 | 3    |
| 代码越迭代越难维护  | GhostStep式退化   | 模块独立+无全局状态+清晰接口                   | 1    |

---

## 十、Mod Config Menu (MCM) 集成设计

> 所有配置项接入 `mod_config_menu_cn_2494192799`，与 GhostStep 现有的 MCM 集成模式一致。

### 10.1 MCM API 使用规范

```lua
-- 全局变量，不需要 require，只需检查是否存在
if ModConfigMenu == nil then return end

local CAT = "GhostStep"  -- 侧边栏分类名
local json = require("json")

-- 设置类型
ModConfigMenu.OptionType.BOOLEAN         -- 布尔开关
ModConfigMenu.OptionType.NUMBER          -- 数值滑块 (min/max/step)
ModConfigMenu.OptionType.SCROLL          -- 滚动条 (0-10, 11档)
ModConfigMenu.OptionType.KEYBIND_KEYBOARD -- 键盘按键绑定
ModConfigMenu.OptionType.KEYBIND_CONTROLLER -- 手柄按键绑定
```

**生命周期**:

1. 加载时: 调用 `register()` 注册所有设置
2. `MC_POST_GAME_STARTED`: 调用 `applyAllFromMCM()` 恢复持久化值
3. `MC_PRE_GAME_EXIT`: 调用 `saveSettings()` 保存当前值
4. `OnChange` 回调中: 立即写入运行时 Config + 触发副作用

**数据流**: MCM菜单 → OnChange → Config + 副作用 → 运行时生效
**持久化**: `mod:SaveData(json.encode(settings))`，MCM 不自动保存

### 10.2 菜单结构 (6个子分类)

```
┌─ GhostStep (侧边栏) ─────────────────────────────┐
│                                                     │
│  [常规] [危险源] [躲避] [显示] [录制] [调试]       │
│                                                     │
│  ┌─ 常规 ──────────────────────────────────────┐  │
│  │ GhostStep v1.0                               │  │
│  │ ─────────────────────────────                │  │
│  │ ▸ 自动躲避:              [开启/关闭]         │  │
│  │ ▸ 开启/关闭快捷键:       [ALT]              │  │
│  │ ▸ 预设档位:              [平衡]             │  │
│  │   安全 / 平衡 / 激进                         │  │
│  └──────────────────────────────────────────────┘  │
│                                                     │
│  ┌─ 危险源 ────────────────────────────────────┐  │
│  │ 弹幕                   [开启]                │  │
│  │ 激光                   [开启]                │  │
│  │ 炸弹                   [开启]                │  │
│  │ 水坑/火焰              [开启]                │  │
│  │ NPC攻击前兆            [开启]                │  │
│  │ 地刺                   [开启]                │  │
│  │ TNT                    [开启]                │  │
│  │ Ultra Greed硬币        [开启]                │  │
│  └──────────────────────────────────────────────┘  │
│                                                     │
│  ┌─ 躲避 ──────────────────────────────────────┐  │
│  │ 最大AI权重:            [85%]  (50-100)      │  │
│  │ 威胁感知灵敏度:        [平衡]               │  │
│  │   低 / 平衡 / 高                              │  │
│  │ 提前规避强度:          [5]    (0-10滚动条)  │  │
│  │ 墙角挣脱灵敏度:        [中]                 │  │
│  │   低 / 中 / 高                                │  │
│  │ 方向平滑度:            [3帧]  (1-10)        │  │
│  └──────────────────────────────────────────────┘  │
│                                                     │
│  ┌─ 显示 ──────────────────────────────────────┐  │
│  │ 总开关                 [关闭]                │  │
│  │ 威胁等级指示器         [开启]                │  │
│  │ 闪避方向箭头           [开启]                │  │
│  │ AI权重显示             [开启]                │  │
│  │ 弹幕场梯度可视化       [关闭]                │  │
│  │ ─────────────────────────────                │  │
│  │ 纯净模式               [关闭]               │  │
│  │   关闭所有视觉效果                            │  │
│  └──────────────────────────────────────────────┘  │
│                                                     │
│  ┌─ 录制 ──────────────────────────────────────┐  │
│  │ 录制功能               [关闭]                │  │
│  │ 死亡自动回放           [开启]                │  │
│  │ 回放缓冲大小:          [30秒] (10-120)      │  │
│  │ 快照详情级别:          [标准]               │  │
│  │   最小 / 标准 / 详细                          │  │
│  └──────────────────────────────────────────────┘  │
│                                                     │
│  ┌─ 调试 ──────────────────────────────────────┐  │
│  │ 观察模式               [关闭]               │  │
│  │   只采集数据，不控制角色                      │  │
│  │ 性能分析器             [关闭]                │  │
│  │ 诊断事件日志           [关闭]                │  │
│  │ ─────────────────────────────                │  │
│  │ 当前帧耗时:            0.3ms                 │  │
│  │ 当前威胁等级:          0.42                  │  │
│  │ 当前决策层:            弹幕场梯度            │  │
│  │ 活跃弹幕数:            12                    │  │
│  └──────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────┘
```

### 10.3 MCM 模块实现

```lua
-- config/mcm.lua
local MCM = {}
local CAT = "GhostStep"
local json = require("json")

-- 配置定义表: 每个设置一行声明
local SETTINGS = {
    -- {子分类, 属性名, 类型, 默认值, 参数}
    -- 常规
    {"常规", "enabled",               "bool",   true,  "自动躲避总开关"},
    {"常规", "toggleKey",             "key",    56,    "开启/关闭快捷键 (默认ALT)"},
    {"常规", "preset",                "number", 2,     min=1, max=3, step=1, names={"安全","平衡","激进"}},
    -- 危险源
    {"危险源", "hazardProjectiles",   "bool",   true,  "躲避敌方弹幕"},
    {"危险源", "hazardLasers",        "bool",   true,  "躲避激光"},
    {"危险源", "hazardBombs",         "bool",   true,  "躲避炸弹爆炸"},
    {"危险源", "hazardCreep",         "bool",   true,  "躲避水坑/火焰"},
    {"危险源", "hazardNpcAttacks",    "bool",   true,  "躲避NPC攻击前兆"},
    {"危险源", "hazardSpikes",        "bool",   true,  "躲避地刺"},
    {"危险源", "hazardTnt",           "bool",   true,  "躲避TNT爆炸"},
    {"危险源", "hazardGreedCoins",    "bool",   true,  "躲避Ultra Greed硬币"},
    -- 躲避
    {"躲避", "maxDodgeWeight",        "number", 85,    min=50, max=100, step=5, suffix="%"},
    {"躲避", "threatSensitivity",     "number", 2,     min=1, max=3, step=1, names={"低","平衡","高"}},
    {"躲避", "anticipateStrength",    "scroll", 5,     "提前规避强度"},
    {"躲避", "wallEscapeSensitivity", "number", 2,     min=1, max=3, step=1, names={"低","中","高"}},
    {"躲避", "directionSmoothFrames", "number", 3,     min=1, max=10, step=1},
    -- 显示
    {"显示", "renderEnabled",         "bool",   false, "显示总开关"},
    {"显示", "renderThreatBar",       "bool",   true,  "威胁等级指示器"},
    {"显示", "renderDodgeArrow",      "bool",   true,  "闪避方向箭头"},
    {"显示", "renderWeight",          "bool",   true,  "AI介入权重显示"},
    {"显示", "renderGradient",        "bool",   false, "弹幕场梯度可视化"},
    {"显示", "pureMode",              "bool",   false, "纯净模式: 关闭所有视觉效果"},
    -- 录制
    {"录制", "recordingEnabled",      "bool",   false, "录制功能"},
    {"录制", "deathReplayEnabled",    "bool",   true,  "死亡自动回放"},
    {"录制", "replayBufferSeconds",   "number", 30,    min=10, max=120, step=10, suffix="秒"},
    {"录制", "snapshotDetail",        "number", 2,     min=1, max=3, step=1, names={"最小","标准","详细"}},
    -- 调试
    {"调试", "observationMode",       "bool",   false, "观察模式: 只采集不控制"},
    {"调试", "profilerEnabled",       "bool",   false, "性能分析器"},
    {"调试", "diagnosticsEnabled",    "bool",   false, "诊断事件日志"},
}

-- 运行时统计 (只读，显示在调试页)
local STATS = {
    {"当前帧耗时",   function() return string.format("%.1fms", State.profiler.lastFrameMs or 0) end},
    {"当前威胁等级", function() return string.format("%.2f", State.threat.level or 0) end},
    {"当前决策层",   function() return State.decision.layerName or "无" end},
    {"活跃弹幕数",   function() return State.projectileCount or 0 end},
}

function MCM.register()
    if not ModConfigMenu then return end

    -- 创建分类信息
    ModConfigMenu.UpdateCategory(CAT, {
        Info = {"GhostStep - 以撒自动闪避Mod | 叠加偏移模式", "按ALT键开关自动躲避"}
    })

    -- 遍历注册所有设置
    for _, s in ipairs(SETTINGS) do
        local sub, attr, typ, default, infoOrName = s[1], s[2], s[3], s[4], s[5]
        if typ == "bool" then
            addBooleanSetting(sub, attr, default, infoOrName)
        elseif typ == "number" then
            addNumberSetting(sub, attr, default, s)
        elseif typ == "scroll" then
            addScrollSetting(sub, attr, default, infoOrName)
        elseif typ == "key" then
            addKeybindSetting(sub, attr, default, infoOrName)
        end
    end

    -- 调试页: 只读统计信息
    ModConfigMenu.AddSpace(CAT, "调试")
    ModConfigMenu.AddText(CAT, "调试", "── 运行时统计 (只读) ──")
    for _, stat in ipairs(STATS) do
        ModConfigMenu.AddText(CAT, "调试", function()
            return stat[1] .. ": " .. stat[2]()
        end)
    end
end

-- 核心: OnChange → Config + 副作用 + 持久化
local function onChange(attr, val)
    Config[attr] = val
    -- 特殊副作用
    if attr == "pureMode" then applyPureMode(val) end
    if attr == "observationMode" then clearPlayerControl() end
    if attr == "enabled" and not val then clearPlayerControl() end
    -- 持久化
    saveSettings()
end

function saveSettings()
    local data = {}
    for _, s in ipairs(SETTINGS) do
        data[s[2]] = Config[s[2]]
    end
    GhostStep:SaveData(json.encode(data))
end

function loadSettings()
    if not GhostStep:HasData() then return end
    local ok, data = pcall(json.decode, GhostStep:LoadData())
    if not ok then return end
    for k, v in pairs(data) do
        if Config[k] ~= nil then Config[k] = v end
    end
end

function MCM.applyAllFromMCM()
    -- 游戏启动时，从Config恢复所有值
    for _, s in ipairs(SETTINGS) do
        Config[s[2]] = Config[s[2]] or s[4]  -- 用默认值填充缺失
    end
end

return MCM
```

### 10.4 数据持久化方案

```
存储位置: Isaac 的 mod save data 目录
格式: JSON
文件: 由 Isaac 的 SaveData/LoadData 自动管理

数据流:
  首次安装 → Config 使用代码默认值
  MCM 修改 → OnChange → Config + SaveData
  游戏重启 → HasData + LoadData → Config
  缺失字段 → 自动用代码默认值填充
```

### 10.5 预设档位系统

```lua
-- config/presets.lua
local PRESETS = {
    [1] = {  -- 安全
        name = "安全",
        maxDodgeWeight = 70,        -- 更低的AI权重
        anticipateStrength = 7,     -- 更强的提前规避
        wallEscapeSensitivity = 3,  -- 更敏感的墙角检测
        directionSmoothFrames = 5,  -- 更平滑的方向变化
    },
    [2] = {  -- 平衡 (默认)
        name = "平衡",
        maxDodgeWeight = 85,
        anticipateStrength = 5,
        wallEscapeSensitivity = 2,
        directionSmoothFrames = 3,
    },
    [3] = {  -- 激进
        name = "激进",
        maxDodgeWeight = 95,        -- 更高的AI权重
        anticipateStrength = 3,     -- 更弱的提前规避(更依赖紧急闪避)
        wallEscapeSensitivity = 1,  -- 不太在意墙角
        directionSmoothFrames = 2,  -- 更快的方向响应
    },
}

function applyPreset(index)
    local preset = PRESETS[index]
    if not preset then return end
    for k, v in pairs(preset) do
        if k ~= "name" and Config[k] ~= nil then
            Config[k] = v
        end
    end
end
```

---

## 十一、SocketBridge 设计模式移植总览

SocketBridge 从"基础设施项目"升格为**核心设计模式来源**。以下是从中提取并适配到纯Lua闪避mod的完整清单：

| 模式         | SocketBridge实现                 | Lua闪避mod适配                 | 优先级  |
| ------------ | -------------------------------- | ------------------------------ | ------- |
| 传感器注册表 | `SensorRegistry:register()`    | 直接复用，去掉订阅过滤         | Phase 1 |
| 动态节流     | `_shouldCollect()` combat/idle | 直接复用，敌人数>0为战斗       | Phase 1 |
| 实体追踪器   | `EntityStateManager[T]`        | 纯Lua表实现，含历史环形缓冲    | Phase 1 |
| 哈希变更检测 | `Helpers.simpleHash()`         | 加table.sort保证顺序一致       | Phase 1 |
| 传感器触发器 | `SensorTriggers` 回调映射      | 直接复用                       | Phase 1 |
| 房间延迟提交 | `State.currentRoom` 延迟验证   | 直接复用                       | Phase 1 |
| 双帧计数器   | updateCount/renderCount          | 直接复用                       | Phase 1 |
| 录制环形缓冲 | Python SessionRecorder           | 纯Lua表环形缓冲，可选JSONL导出 | Phase 1 |
| 持久化录制   | gzip JSONL + session管理         | 纯JSONL(无gzip)，可选Phase 4   | Phase 4 |
| 输入注入     | `MC_INPUT_ACTION` hook         | 改为叠加偏移而非全量替换       | Phase 1 |
| 控制模式切换 | F3 MANUAL/AUTO/FORCE_AI          | ALT键 ON/OFF + 状态指示        | Phase 1 |
| 已知问题规则 | `KnownIssueRegistry`           | 内联防御代码 (HP clamp等)      | Phase 1 |
| 公开API      | `mod.SensorRegistry = ...`     | 可选，为未来扩展预留           | Phase 4 |

---

*文档完成。三个项目的精华已全部整合，SocketBridge的设计模式已深度提取并适配为纯Lua方案。*
*后续开发按 Phase 1-4 路线图执行。*
