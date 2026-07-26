# 核心运行时、逐帧、数值框架与耦合审查

审查快照：2026-07-26，Git HEAD `f029e2d`，并包含当前工作区未提交变更。项目声明 Godot 4.6、Forward Plus，`run/max_fps=60`。`project.godot` 没有显式声明 `physics/common/physics_ticks_per_second`，因此“物理 60 Hz”是基于 Godot 默认值及项目自身 `NetConstants.HOST_PHYSICS_HZ = 60` 的一致性推断，不把它伪装成项目文件里的显式配置。

## 1. 代码库与运行入口

- 仓库文件：2,823。
- 运行时审查范围（`scene/`、`resources/`、`relay_servers/` 中的 GDScript）：226 个 `.gd`，92,368 行，4,945 个函数。
- 场景：157 个 `.tscn`；资源：376 个 `.tres`；着色器：27 个 `.gdshader`。
- 主场景：`scene/main_menu.tscn`。标准战斗场景为 `scene/game.tscn`，塔防战斗场景为 `scene/game_tower_defense.tscn`；多人以 `scene/multiplayer/mp_game.tscn` 为外壳，并在 `_setup_game()` 中动态实例化对应战斗场景。
- 10 个 Autoload：`UserSettings`、`RunState`、`NetManager`、`UIAudio`、`GameLoadCoordinator`、`StatusEffectExpiryScheduler`、`BurnStatusScheduler`、`BleedStatusScheduler`、`ColdStatusScheduler`、`EnemyCollectibleStatusScheduler`。
- 物理/渲染层共 12 个语义层：World、Player、EnemyBody、EnemySensor、Bullet、Pickup、Explosion、EnemyProjectile、BossBody、PlantBody、TowerCore、WaterTerrain。

核心入口证据：

- `project.godot:9-34`：项目、主场景、60 FPS 上限、Autoload。
- `scene/game_runtime_base.gd:122-168`：三种运行模式、共享运行时状态。
- `scene/game.gd:126-251`：标准模式初始化与 Host 物理帧。
- `scene/game_tower_defense.gd:253-462`：塔防物理插值、初始化与物理帧。
- `scene/multiplayer/mp_game.gd:494-623`：多人外壳初始化、物理帧和渲染帧。

## 2. 每帧究竟发生什么

### 2.1 全局事实

- 36 个脚本声明 `_process()`，45 个脚本声明 `_physics_process()`，去重后 76 个脚本拥有至少一种逐帧入口。
- 这不等于 76 次固定调用：许多脚本用 `set_process(false)` / `set_physics_process(false)` 休眠，投射物和敌人脚本则会按活跃实例数放大。
- 25 个场景共声明 46 个 `Timer` 节点。标准游戏有 2 个，塔防根场景有 3 个；紫阳花 6 个、锄头猫 5 个、葡萄电弧塔和玉米机枪各 3 个。
- 显式物理优先级只有三处：Capoo 投射物共享系统 5、守护光环 10、竹子迫击炮共享系统 50；其余大多为默认 0。由此形成“普通实体 → 共享投射物 → 守护光环 → 竹炮系统”的意图顺序。
- 塔防进入树时打开 SceneTree 物理插值，退出时恢复原值（`scene/game_tower_defense.gd:253-262`）。

### 2.2 输入阶段

- `Player._input()` 只维护鼠标位置与左键释放状态；`_unhandled_input()` 处理作弊息壤、技能、换弹及左键按下（`scene/player/player.gd:444-486`）。
- 根游戏处理全屏与收藏品调试窗；塔防测试场另有 Delete 键清除植物的临时入口。
- 多人客户端在 `MpGame._client_physics_tick()` 中读移动/射击/换弹/冲刺；输入变化时立即发，静止时每 6 个物理帧 keepalive，活动状态可保持 60 Hz（`scene/multiplayer/mp_game.gd:3366-3441`）。

### 2.3 每个物理帧（权威/单机战斗）

1. Autoload `NetManager` 自增网络物理帧并轮询待连接或 Relay 注册（`scene/multiplayer/net_manager.gd:63-67`）。
2. 多人外壳 `MpGame`：清理事件缓存、更新包体警告、按 0.05/0.1 秒批处理反馈；Host 进行复活检查和快照发送，Client 发送输入（`scene/multiplayer/mp_game.gd:580-590, 6549-6577`）。
3. 游戏根：
   - 标准 Host 每帧更新远端玩家被动状态；每 0.35 秒对所有敌人重新选最近玩家，当前实现为同步 O(敌人数 × 玩家数) 扫描（`scene/game.gd:248-251, 2364-2389`）。
   - 塔防每帧更新观战相机/单机复活；非 Client 每 0.60 秒启动一次敌人目标刷新，每物理帧最多处理 16 个敌人，将一次全量扫描摊开（`scene/game_tower_defense.gd:456-462, 4535-4583`）。
4. 玩家实例：先推进无敌、临时拾取 Buff、收藏品周期效果、技能充能、角色资源和攻击条；死亡/锁控会提前返回；否则读输入、冲刺或 `move_and_slide()`、攻击、朝向和动画（`scene/player/player.gd:490-552`）。
5. 每个活跃敌人实例：具体子类以 60 Hz 推进接触伤害、攻击状态机与位移。寻路方向默认仅每 6 个物理帧（10 Hz）刷新，攻击感知默认每 3 帧刷新；位移本身仍为物理帧频率（`scene/enemy/enemy.gd:57-83, 132-144`）。
6. 每个活跃投射物或技能场推进命中、寿命和视觉；部分 Capoo 投射物交由 `CapooProjectileMotionSystem` 批量推进。
7. 共享状态调度器按需运行：燃烧/流血使用事件堆；寒冷和敌人收藏品状态使用截止时间堆，队列空时关闭物理处理。
8. `SessionObjectPool` 每物理帧结算延迟一帧可复用的对象与指标信号（`scene/session_object_pool.gd:140-167`）。
9. 塔防的物理 Timer 每秒对不受支持地形上的植物结算一次伤害（`scene/game_tower_defense.tscn:449-450`, `scene/game_tower_defense.gd:1072-1075`）。

多人场景中 `MpGame` 是战斗场景的父节点（`scene/multiplayer/mp_game.gd:2510-2576`）。在默认同优先级/树序下，其 Host 快照采集发生在战斗子树本物理帧更新之前，因此线上的某帧快照逻辑上代表进入该物理帧时的状态；这是一帧以内的管线延迟，不是状态丢失。

### 2.4 降频工作

- 标准模式敌人改目标：0.35 秒一次全量。
- 塔防敌人改目标：0.60 秒一轮，每物理帧最多 16 个。
- 敌人导航方向：默认每 6 物理帧；攻击感知：默认每 3 帧；远程 LOS：默认每 6 帧。
- Host 玩家快照：60 Hz；敌人快照：通常 30 Hz，敌人达到 200 时降到 20 Hz；敌人每块最多 56 个（`scene/multiplayer/net_constants.gd`, `scene/multiplayer/mp_game.gd:2880-3025`）。
- 客户端离屏敌人视觉插值：15 Hz，并按 64 个确定性相位错开（`scene/multiplayer/mp_game.gd:3511-3534`）。
- 战斗反馈、竹炮表现、玉米机枪连发表现、植物生命：20 Hz 批量；波次进度和 Tiyi 目标：10 Hz。
- 客户端可见性预算：每 0.2 秒重算一次视口外代理。

### 2.5 每个渲染帧

1. `MpGame` 更新公网房间续租；Host/Client 都对玩家和敌人代理插值；Client 还跑地形修复看门狗、每 0.2 秒可见性预算和远端敌人数 UI（`scene/multiplayer/mp_game.gd:613-670`）。
2. `Player._process()` 推进远端冲刺视觉、网络平滑、名字牌屏幕位置和角色特有战斗状态（`scene/player/player.gd:437-441`）。
3. `GridPathfinder` 仅在存在运行时构建任务时启用；每帧最多 192 次展开且总预算约 1,000 µs，并用优先级服务周期防止动态目标饿死静态/后台任务（`scene/grid_pathfinder.gd:31-65, 2060-2117`）。
4. `Enemy._process()` 默认关闭；只有加速类移动状态需要跟随速度更新拖尾时才打开。纯减速着色器为静态参数，不再让每个敌人持续占用渲染帧（`scene/enemy/enemy.gd:474-511`）。
5. 数字池、闪电 VFX、锁定线、场景 UI、生产/研究面板等按可见性或活动状态运行。
6. `StatusEffectExpiryScheduler` 只在有批量到期任务时运行，每帧最多 128 个目标、1,500 µs、每作业轮转 8 个，避免同步过期尖峰（`scene/status_effect_expiry_scheduler.gd:1-145`）。

### 2.6 波次和 Timer

- `EnemySpawnTimer` 与 `StateTimer` 未覆盖 `process_callback`，按 Godot Timer 默认 idle 回调；波次倒计时每秒一次，生成回调调用 `_spawn_wave_batch()`。
- 每次生成最多受 `WaveConfig.spawn_count_per_tick` 与根脚本常量 `MAX_WAVE_SPAWN_COUNT_PER_TICK = 4` 双重限制；并受 `max_alive_enemies` 限制（`scene/game.gd:1497-1528`；塔防为完全相同的复制实现）。
- 生产、研究、植物攻击大量采用场景 Timer，因此其工作由到期事件而非全体建筑逐帧轮询触发；个别共享战斗系统（竹炮）仍在物理帧运行。

## 3. 性能框架的成熟点

- 敌人空间索引以 96 px 桶维护，敌人只有跨桶时触碰共享字典；局部最近/无序查询走索引，单机小规模全量排序查询保留直接容器扫描，达到 512 敌人后切换批量索引（`scene/game_runtime_base.gd:431-655`, `scene/enemy/enemy.gd:358-448`）。
- 塔防强制所有有界敌人查询走桶索引，适合多个独立塔同时索敌（`scene/game_tower_defense.gd:354-356`）。
- 寻路把 TileMap 采样转为不可变字节快照和障碍积分图；运行时 Flow Field 构建有时间/展开双预算。
- 对象池区分“弹性获取”（不丢玩法事件）与“严格视觉预算获取”（可丢表现），并通过一物理帧隔离避免同帧复用碰撞对象。
- 燃烧/流血/寒冷/收藏品状态都从“一目标一 Timer”方向转向共享堆调度；队列空时停机。
- 网络使用 delta/keyframe、分块、批处理、包体警告、离屏代理降频、事件去重与修复清单。

## 4. 性能风险

### P1：标准模式敌人改目标仍为周期性全量尖峰

`scene/game.gd:2364-2389` 每 0.35 秒在同一物理帧遍历全部敌人，并为每个敌人遍历玩家。塔防已经有“每帧最多 16 个”的预算式版本，但标准模式没有复用。敌人数高时会出现周期性 frame-time 齿形。建议把预算式重定向上移到 `GameRuntimeBase`，模式只提供候选目标策略。

### P1：四个超大型协调中心形成变更热点

- `MpGame`: 11,990 行 / 481 函数 / 102 RPC。
- `GameTowerDefense`: 5,089 行 / 293 函数。
- `Player`: 4,610 行 / 322 函数。
- `Enemy`: 3,943 行 / 195 函数。
- `GridPathfinder`: 4,749 行 / 146 函数。

性能本身已有大量预算化，但代码尺寸使任何新机制容易绕过已有预算或复制网络验证逻辑。首要拆分不是“按文件变小”，而是按所有权：快照/事务/战斗反馈、玩家收藏品执行器、运行时波次控制器、伤害/状态域。

### P2：逐实例物理回调仍是大规模敌群的固定成本

每个敌人子类仍各自拥有 `_physics_process()`，即使寻路方向和感知已降频，分派、状态分支、接触表检查、动画朝向和移动仍按实例 × 60 Hz 执行。当前项目已为投射物、竹炮、光环做共享系统，说明可继续对同质近战敌人做“批量调度/分相感知”，但不应牺牲 `CharacterBody2D` 的碰撞正确性。

### P2：某些渲染帧遍历与实体数量线性相关

客户端插值仍需遍历全部 `enemy_interpolators`；离屏只降低每个实体的实际插值频率，并没有消除字典遍历。200+ 敌人时可接受，但若目标扩大到千级，需要把相位桶本身做成待处理列表，而非每帧先扫全表再判定相位。

## 5. 数值相关框架

### 5.1 已有数据驱动层

- 45 个配置脚本，508 行导出字段，其中 275 个 `@export_range`。
- 敌人：基础 `EnemyConfig` + 22 个特化配置脚本，29 个 `.tres`。
- 植物：`PlantDefenseConfig` + 紫阳花/葡萄特化配置，注册 12 种植物。
- 玩家：`PlayerCharacterConfig` 注册 3 个角色。
- Boss：基础 Boss + 灵兰技能 1–4 配置，共 5 个 `.tres`。
- 波次/流程：`FlowGraphConfig`、`FlowStepConfig`、`WaveConfig`、`WaveEnemyEntry`；campaign 目录 59 个 `.tres`。
- 生产：`ProductionRecipe` 与注册表；18 个 `.tres`。
- 全局研究：`GlobalResearchConfig` 与注册表，当前 2 项。
- 物品：一个非常宽的 `PickupConfig`，125 个导出字段。

### 5.2 数值所有权较清晰的部分

- 敌人基础生命/攻击/防御/速度/基地伤害、场景、掉落表在 `EnemyConfig`。
- 植物基础生命/防御/攻击/射速/范围/连发/占格在 `PlantDefenseConfig`；统一用 `100 / attack_speed` 得出攻击间隔。
- 玩家初始生命、攻击、射速、移速和每级攻击成长在 `PlayerCharacterConfig`。
- 波次构成、生成间隔、每批数量、上限由 `WaveConfig` 与 `WaveEnemyEntry` 控制。
- 生产投入/产出/时长、全局研究投入/时长/效果已转为资源配置。

### 5.3 明显应该统一但尚未统一

#### A. 伤害域被错误地挂在 EnemyConfig 上

`DamageType` 定义在 `EnemyConfig`，但玩家、植物、Boss、数字池、多人协议全部引用 `EnemyConfig.DamageType`。这让一个全局战斗概念依赖“敌人配置”命名空间。建议迁到 `CombatTypes`/`DamageSpec` 独立资源或 RefCounted，并为网络 wire enum 固定显式值。

#### B. 同一防御公式存在三份

- 玩家：`scene/player/player.gd:1136-1154`。
- 敌人：`scene/enemy/enemy.gd:1613-1624`。
- 植物：`scene/plant_defense/plant_defense.gd:604-610`。

三者目前都采用“物防减算、魔防百分比、最少 1”，但玩家另叠 strongest reduction、敌人另叠 damage-taken multiplier。应抽出纯函数 `mitigate_base_damage(amount, type, physical, magic)`，实体自己应用后置乘区。这样既保留差异，又消除底层舍入规则漂移风险。

#### C. 攻速单位约定重复

植物写死 `ATTACK_SPEED_UNITS_PER_SECOND = 100`；玩家配置与玩家实例分别保存 `attack_speed_units_per_attack = 100`。本质都是“每秒攻速点数 / 100”。应有一个战斗速率值对象或至少一个共享常量/换算函数，避免 UI、塔和角色出现不同舍入。

#### D. 角色成长分散在三处

- 初始数值/攻击成长：`PlayerCharacterConfig`。
- 通用升级上限与 4 套成本曲线：`RunState.MAX_UPGRADE_LEVELS/UPGRADE_COSTS`。
- 技能升级成本、每级减充能、角色科技成本与三角色科技效果：`Player` 的常量数组。

这使新角色或平衡修改必须同时改资源、RunState 与 Player。建议 `PlayerProgressionConfig`：通用升级曲线、技能曲线、角色科技曲线全部资源化，`RunState` 只存等级。

#### E. 状态定义散落且多人端再次镜像

- `burn`/`bleed` ID 和 tick interval 在 Player、Enemy、调度器多处出现。
- 火法燃烧时长/等级同时存在于 `FireSorcererConfig`、火球脚本的导出默认值、`MpGame` 常量。
- 火/冰史莱姆 source ID、3 秒时长、燃烧 10 点同时存在于 `Slime` 与 `MpGame`。

多人端的镜像用于“不信任客户端”是合理的，但不应靠复制魔法数。建议权威端通过 `EnemyAttackSpecRegistry` 以 source type 查固定配置；客户端报告只带 source/实例/事件 ID，Host 从注册表重建伤害与状态。

#### F. 全局研究存在“资源化后遗留常量”

`ResearchCoordinator` 仍暴露 `GLOBAL_RESEARCH_DURATION_SECONDS`、防御/移速效果量和旧材料需求；生产逻辑实际读取 `GlobalResearchConfig`，部分旧常量只有测试引用。应将兼容 API 明确标记 deprecated，测试改为读取注册配置，随后删除双源。

#### G. PickupConfig 是宽表 + 字符串效果 DSL

125 个导出字段将基础掉落、背包、建筑、Buff、收藏品、周期、技能、条件、触发、命中、击杀全部塞进一个资源；效果类型由字符串 ID 与 Player 内部 `match` 解释。优点是资源编辑快速，缺点是无关字段大量为空、组合合法性难验证、网络端还要镜像字符串语义。建议保持 `PickupConfig` 作为物品头，效果改成 `Array[ItemEffectConfig]` 的判别联合（StatModifier/Periodic/OnHit/OnKill/PlaceBuilding 等）。

#### H. 根模式脚本含大量玩法常量

运行时脚本共 1,371 个 `const`；并非都应该数据化（协议、预算、颜色、掩码适合常量），但 `MpGame` 124 个、`Player` 46 个、`GameTowerDefense` 39 个数值常量中混有玩法数值。建议建立“协议/性能预算必须代码常量，平衡数值必须资源，纯视觉可脚本导出”的约束和 CI 检查，而不是机械地把所有常量搬入资源。

## 6. 耦合审查

### 6.1 量化（启发式，不冒充静态类型证明）

226 个运行时脚本中统计到：289 个直接 `res://` 资源依赖、51 个 `/root/Autoload` 引用、122 个精确 `get_tree().current_scene`、601 次 `.call()` + `has_method()`、397 次 signal connect、141 个 signal 声明。

以“资源依赖 + 2×Autoload + 3×current_scene + 2×动态调用 + connect”作为仅供排序的耦合指标，最高为：

1. `MpGame` 260。
2. `Player` 192。
3. `GameTowerDefense` 159。
4. `Game` 126。
5. `LinglanBoss` 92。
6. `GameLoadCoordinator` 81。
7. `MultiplayerLobby` 80。
8. `Enemy` 76。

这个指标不表示 signal 天生有害；它只是定位变更热点。真正的问题集中在 current-scene 动态协议和重复所有权。

### 6.2 合理耦合

- `GameRuntimeBase` 提供查询、治疗、对象池、战斗数字、运行模式等稳定门面；玩家/植物通过门面查询敌人，方向正确。
- `PlantSystem` 维护植物占格/空间索引，建筑不自行扫描场景树。
- 调度器以 Autoload 提供跨场景生命周期，适合状态持续时间不应依赖单个战斗节点的需求。
- Host 游戏通过 signal 向 `MpGame` 发布世界事件；权威层不直接发 RPC，边界清晰。
- 配置注册表对玩家、植物、研究、简易配方提供稳定 ID 与资源映射。

### 6.3 过度耦合

#### Game 与 GameTowerDefense 是复制式继承

两者共享 174 个同名函数；其中 117 个函数文本完全相同，至少 1,320 行精确重复。`Game` 176 个函数中只有 2 个函数名不在塔防脚本中。重复覆盖波次、Boss、多人实体注册、商店、快照、音乐等核心逻辑，任何 bugfix 都有双改风险。

建议把以下组件上移/拆出：`WaveFlowController`、`BossRuntimeController`、`MultiplayerWorldRegistry`、`MusicStateController`。`Game` 与塔防只组装组件，并提供“基地/植物/地形”等差异策略。

#### Player 是运行时服务定位器

`Player` 有 19 处精确 `get_tree().current_scene`，用于投射物注册、多人伤害/治疗、目标查询、特效广播、冲刺通知等。它通过 `has_method/call` 猜测当前根场景能力，既绕过类型检查，又把单机与多人分支散落到玩家内部。

建议初始化时注入一个类型化 `CombatRuntimePort`（目标查询、伤害、生成、网络事件、数字显示），Player 不再知道当前场景是 `Game` 还是 `MpGame`。

#### MpGame 同时承担协议、验证、事务、表现和世界修复

11,990 行中包含：连接后战场建立、输入验证、快照编码调度、投射物验证、玩家/敌人伤害、植物、地形、库存、生产、仓库、研究、洛茜、Boss、表现批处理、修复看门狗。102 个 RPC 全在单文件，Relay stub 也必须同名镜像。

建议不改变单一 `MultiplayerAPI` 根节点，但按逻辑拆成子节点/服务：`RealtimeSyncProtocol`、`CombatProtocol`、`WorldProtocol`、`TransactionProtocol`、`SnapshotRepairProtocol`。每个服务显式拥有一组信道和 RPC；根节点只做路由与共享 peer/session context。

#### LinglanBoss 与 Enemy 使用 current_scene 作为生成器/网络桥

Boss 10 处 current scene，Enemy 3 处，主要用于生成投射物和广播动作。应由 setup 注入 `ProjectileSpawner`/`EnemyRuntimePort`，或由 game 连接“请求生成/请求广播”信号。

### 6.4 欠耦合/协议重复

多人权威验证为了安全不得信任客户端，但目前通过在 `MpGame` 再实现一份 source-type → 伤害/状态规则来做到。这不是“解耦”，而是两个事实源。正确方向是共享只读规则注册表，Host 读取规则、客户端只消费表现。

## 7. 建议优先级

### P0：建立行为基线后再拆

先为伤害舍入、状态持续、波次切换、网络 source 验证、库存 revision、所有实体注册表建立数据驱动的契约测试。当前大型脚本已有大量隐式时序，直接搬文件风险高。

### P1：合并 Game/GameTowerDefense 公共控制器

目标是消除 117 个完全相同函数和 1,320+ 行精确重复；优先抽波次、Boss、音乐、多人物体注册，不先动塔防特有植物逻辑。

### P1：独立 CombatDomain

迁移 `DamageType`、基础减伤纯函数、攻击速率换算、状态 ID/AttackSpec 注册。第一阶段保持原 API 包装，逐步替换引用。

### P1：拆 MpGame 的四类协议

保留 RPC 名和 wire 结构以避免协议大改，只将实现委托给组件；同步生成 Relay stub/协议清单，防止 102 RPC 手工漂移。

### P2：Player 注入 RuntimePort，收藏品效果组件化

先替换 current_scene + has_method，随后把宽表字符串 `match` 拆为类型化效果资源。两步分开，避免同时改变调用图和数值语义。

### P2：标准模式复用预算式敌人重定向

把塔防每帧 16 个的机制上移；配置每轮间隔和预算，消除 0.35 秒全量尖峰。

### P3：清理遗留常量与建立数值所有权检查

测试不再依赖 `ResearchCoordinator` 旧常量；为“平衡数值只能来自配置/AttackSpec，协议预算只能来自 NetConstants/性能配置”建立简单审查脚本。
