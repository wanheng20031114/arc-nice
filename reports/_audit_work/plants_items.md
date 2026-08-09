# 植物防御塔与物品系统全量审计

审计对象：当前工作树（包含尚未提交的葡萄电弧塔、紫阳花雨幕调整）。本报告只做静态源码/资源链路审计，没有修改业务代码。路径均以仓库根目录为基准，行号对应本次审计时的工作树。

## 1. 结论摘要

### 高优先级

1. **葡萄电弧塔已经进入植物注册表，却还没有进入物品/生产闭环。** `PlantDefenseRegistry` 已注册 `grape_arc_tower`（`resources/config/plant_defense/plant_defense_registry.gd:15,50-52,65,86`），但 `resources/config/buildings/` 只有 11 个建筑箱，没有 `building_grape_arc_tower.tres`；植物培育中心也只配置龙舌兰、玉米、竹筒、紫阳花四条塔配方（`scene/plant_defense/plant_cultivation_center.tscn:8-19,117`）。因此普通流程无法制造/获得葡萄塔，只能走调试免费放置或直接调用注册表。
2. **本地交互建筑存在重复的全组扫描。** 橡木仓库、生产建筑、科研中心在玩家进入范围后各自每 `0.08s` 调用 `get_tree().get_nodes_in_group()` 并重选最近交互对象（`oak_warehouse.gd:10,59-69,1271-1313`；`production_building.gd:11,73-83,822-862`；`research_center.gd:13,74-84,469-509`）。同一玩家同时覆盖 N 个建筑时会由 N 个节点重复扫描全部 B 个交互建筑，趋近 `O(N×B)`/80ms。`PlantSystem` 已有空间索引版最近交互建筑查询（`plant_system.gd:578-624`），但这些本地路径没有复用。
3. **玩法数值仍分散在资源和脚本常量两处。** 龙舌兰、玉米、竹筒均在 `.tres` 之外保留同值默认常量；竹筒的最小射程、外圈伤害、蓄力，龙舌兰的炮弹速度/爆炸半径等只在脚本。紫阳花和葡萄已经采用子类配置，结构更稳健。继续新增塔时应把全部“会改变结算”的数值收进强类型配置，脚本只保留纯视觉常量。
4. **`PickupConfig` 是过度承载的单体资源。** 一个类同时表示拾取触发道具、消耗品、材料、建筑箱和收藏品，并携带约 120 行收藏品 DSL 字段（`resources/config/pickup_config.gd`）。它没有统一 `is_valid()`，收藏品又由文件名前缀隐式注册，新增错类型/空 effect ID/未知字符串时运行时可静默无效。
5. **葡萄塔空场轮询偏频繁，且客户端代理也做同样索敌。** 找不到目标时每 `0.18s` 重新查询，约 `5.56` 次/秒/塔（`grape_arc_tower.gd:8,233-250`）；多人代理也启动该计时器并查询复制敌人，只是不结算伤害（`:164-168`）。大量葡萄塔且空场时，这一频率远高于其 1.6 秒攻击节奏。

### 中优先级

- 背包 `inventory_changed` 不带 peer/差量信息；任一玩家背包变化都会触发所有已连接 Player 重建各自 20 槽收藏品缓存，也会唤醒生产协调器检查（`run_state.gd:4`，`player.gd:431-432,2286-2289,2462-2514`，`production_coordinator.gd:113-115,898-918`）。当前上限小，正确性没问题，但多人扩展会放大无关工作。
- 白色水晶、卡普蓝晶、术士紫晶粉目前只有敌人掉落来源，没有生产、合成、科研或消费端；它们是可积累的死端材料。
- 放置模式每 0.2 秒重新遍历候选锚点，每个锚点还会新建矩形 Shape/Query 并执行一次 `intersect_shape`；随后每帧线性扫描有效标记找鼠标最近点（`plant_placement_controller.gd:182-195,250-294`；`plant_system.gd:117-181,940-957`）。放置区域现在较小，但扩大地图/放置半径后会成为明显热点。
- 竹筒迫击炮集中结算系统已膨胀到约 1650 行。其批处理、缓存和预算都很扎实，但复杂度已高于其他整套植物系统，应拆成“索敌批处理/爆炸聚合/伤害派发/指标”几个职责明确的组件。
- `PlantDefenseConfig.REQUIRED_FOOTPRINT_SIZE=(2,2)` 名称暗示硬约束，`is_valid()` 实际只要求正数；植被桩、木头加工站合法使用 1×1（`plant_defense_config.gd:5,31,41-54`）。应改名为默认值，避免未来误用。
- 研究协调器仍保留一组旧常量和旧材料数组，实际效果/投入已改为资源驱动（`research_coordinator.gd:24-40,410-454`）；继续保留会制造漂移入口。
- `drop_weight` 已明确是兼容字段，实际掉落使用 `EnemyDropRule.chance` 独立掷骰（`pickup_config.gd:119-120`；`enemy_drop_table.gd:20-69`），旧字段仍大量序列化，容易误导策划。

### 已确认正确的紫阳花时间轴

- 施法时刻 `0.00s`；目标雨滴开始发射 `0.24s`；雨滴固定下落 `0.44s`；首个落地与玩法效果同时在 `0.68s` 开始（`hydrangea_rain_tower_config.gd:4-8`）。
- 玩法效果持续 5 秒，在动作时间 `5.68s` 结束；5 次治疗/减攻跳点为 `0.68/1.68/2.68/3.68/4.68s`（`hydrangea_rain_tower.gd:450-509`）。所以“5 秒治疗与减攻结束点是 5.68s”当前代码成立。
- 地面 `GroundDewRise` 从 0.68s 持续到 5.68s；5.68s 停止发射后再以 `max(1.15s, particle lifetime)` 消散，当前 lifetime=1.0s，因此完全清理约在 `6.83s`（`hydrangea_rain_tower.gd:601-629,995-1035`；`hydrangea_rain_tower.tscn:360-366`）。这满足“地面粒子至少持续到地面玩法效果消失，并保留消散期”。
- 6 秒循环的下一次施法会在旧露珠尾迹尚未完全清理时开始；代码刻意让旧粒子使用 world-space 完成尾迹（`hydrangea_rain_tower.gd:702-704`），视觉可叠但不会延长玩法效果。

## 2. 植物注册、基类与统一结算

注册表硬编码 12 项，入口为 `resources/config/plant_defense/plant_defense_registry.gd:4-110`。所有当前配置均声明 `supports_multiplayer=true`。实例化只验证 ID、显示名、图标、场景、生命、连发和正占格；子类配置负责补充攻击合法性。

`PlantDefense` 是 `StaticBody2D` 基类（`scene/plant_defense/plant_defense.gd:1-139`）：

- setup 时把配置复制为运行时生命/防御/攻击字段；构造和移除由约 0.7 秒 Tween 管理，不存在常驻 `_process/_physics_process`。
- 物防为 `max(伤害-物防,1)`；魔防为 `max(floor(伤害×(100-魔防)/100),1)`（`plant_defense.gd:604-610`）。
- 燃烧/流血交给全局状态调度器；伤害和治疗数字按同一 deferred frame 聚合，避免多跳同帧制造大量数字节点（`plant_defense.gd:621-703`）。
- 多人代理拒绝本地伤害/治疗，宿主通过 health revision、状态 bitmask 和动作快照复制。

### 2.1 全部 12 个配置/场景/脚本

攻击速度单位为 100；间隔=`100/attack_speed`（`plant_defense_config.gd:4,35-38`）。一格按现有地图为 16px。

| ID / 配置 | 场景 / 主脚本 | HP / 物防 / 魔防 | 攻击与范围 | 占格/地形 | 实际职责 |
| --- | --- | ---: | --- | --- | --- |
| `agave_cannon` (`agave_cannon.tres:9-20`) | `agave_cannon.tscn` / `agave_cannon.gd` | 2000 / 10 / 20 | 25 物理，2.0s，130px | 2×2 草 | 直射炮弹+18px 范围爆炸 |
| `bamboo_mortar` (`bamboo_mortar.tres:9-22`) | `bamboo_mortar.tscn` / `bamboo_mortar.gd` | 2000 / 10 / 20 | 内100/外50，64~192px，4s 蓄力 | 2×2 草 | 远程定点双圈范围伤害 |
| `corn_machine_gun` (`corn_machine_gun.tres:9-23`) | `corn_machine_gun.tscn` / `corn_machine_gun.gd` | 2500 / 10 / 20 | 30×6，0.9s 一轮，轮内 0.06s，160px | 2×2 草 | 锁向 hitscan 六连射 |
| `grape_arc_tower` (`grape_arc_tower.tres:9-25`) | `grape_arc_tower.tscn` / `grape_arc_tower.gd` | 2600 / 8 / 30 | 72 法术，1.6s，96px；最多4目标，跳72px | 2×2 草 | 0.42s 充能后最近邻连锁 |
| `hydrangea_rain_tower` (`hydrangea_rain_tower.tres:9-20`) | `hydrangea_rain_tower.tscn` / `hydrangea_rain_tower.gd` | 6000 / 10 / 40 | 每跳治疗50；落雨阶段法伤5；6s循环 | 2×2 草 | 12格选点、3格雨区，5s治疗/敌减攻20% |
| `oak_warehouse` (`oak_warehouse.tres:9-21`) | `oak_warehouse.tscn` / `oak_warehouse.gd` | 2000 / 0 / 0 | 无 | 2×2 草 | 20槽共享仓库、交易修订 |
| `plant_cultivation_center` (`plant_cultivation_center.tres:9-20`) | `plant_cultivation_center.tscn` / `plant_cultivation_center.gd` | 1500 / 10 / 10 | 无 | 2×2 草 | 木制核心培育战斗塔建筑箱 |
| `planting_base` (`planting_base.tres:9-21`) | `planting_base.tscn` / `planting_base.gd` | 2000 / 5 / 10 | 无 | 2×2 草 | 树苗繁育/转木材 |
| `research_center` (`research_center.tres:9-21`) | `research_center.tscn` / `research_center.gd` | 2800 / 5 / 20 | 无 | 2×2 草 | 全局科研与个人息壤科技 |
| `vegetation_stake` (`vegetation_stake.tres:9-22`) | `vegetation_stake.tscn` / `vegetation_stake.gd` | 4000 / 10 / 50 | 无 | 1×1 草 | 每10s扩一环，5格/50s植被化 |
| `water_collector` (`water_collector.tres:9-22`) | `water_collector.tscn` / `water_collector.gd` | 2000 / 10 / 0 | 无 | 2×2 水 | 环境水源→水瓶 |
| `wood_processing_station` (`wood_processing_station.tres:9-22`) | `wood_processing_station.tscn` / `wood_processing_station.gd` | 2000 / 10 / 0 | 无 | 1×1 草 | 木板/核心/四类功能建筑组装 |

## 3. 五个战斗/支援塔逐项运行审计

### 3.1 龙舌兰加农炮

- 数值来源：`.tres` 提供伤害/间隔/射程；脚本再次保留 `25/130/2.0` 默认值，并独占炮速180、爆炸半径18（`agave_cannon.gd:4-18`）。
- 攻击 Timer 每 2 秒索敌一次；优先空间索引最近目标，再对遮挡目标做有限线性尝试。场景中原有 `TargetingArea` broad phase 会在 setup 后关闭，实际索敌走游戏运行时接口（`agave_cannon.gd:53-91,142-167,300-349`）。
- 炮弹飞行期间才开启 `_physics_process`；每物理帧强制刷新 `ShapeCast2D`，爆炸时通过完整 shape query 收集半径内敌人，64 个一批（`agave_cannonball.gd:112-136,181-227`）。炮弹走游戏会话池，生命周期有限。
- 性能结论：塔空闲成本低；主要成本与在途炮弹数成正比。可移除/简化已经停用的场景 TargetingArea 与遗留信号，减少误读。

### 3.2 竹筒迫击炮

- 数值来源分裂：`.tres` 只有内圈100和最大射程192；脚本独有外圈50、最小射程64、4秒蓄力、0.5秒跟踪、无目标2秒重试（`bamboo_mortar.gd:19-32`）。配置 `attack_speed=0`，完全绕过基类攻击间隔。
- 流程：请求集中索敌→锁定并蓄力4秒→每0.5秒更新落点→动画发射→弹体飞行0.28~0.55秒→16px内圈100、32px外圈50（`bamboo_mortar.gd:276-340,361-523`；`bamboo_mortar_shell.gd:15-32,198-278`）。发射后 deferred 立即请求下一目标，没有额外冷却。
- `BambooMortarCombatSystem` 在宿主始终开 `_physics_process`，每帧处理索敌队列和爆炸批；默认最多12个索敌请求/帧、预算6000µs，64px 索敌缓存、32px 爆炸网格、4个爆炸以上走聚合（`bamboo_mortar_combat_system.gd:4-18,219-306,321-357`）。空队列只是常数检查。
- 性能结论：已有针对100塔同步压力的限额和指标，是当前战斗塔中扩展性最强、同时也是维护复杂度最高的一套。应保留集中批处理思想，但拆分职责并把结算数值配置化。

### 3.3 玉米机枪塔

- `.tres`：30伤害，0.9秒一轮，6发、间隔0.06秒、160px；脚本仍镜像同值常量（`corn_machine_gun.gd:8-24`）。一轮全中为180伤害，连续稳定输出名义约200 DPS。
- 攻击轮开始只索敌一次并锁定方向约0.3秒，不追踪移动目标；每发直接做一次 world+enemy ray query，最多6条射线（`corn_machine_gun.gd:211-393,475-541`）。
- `_physics_process` 默认关闭，只在一轮 burst 中打开，结束立即关闭（`corn_machine_gun.gd:81-92,301,449-461`）。初次射击用稳定 ID 的黄金比例错相，避免大量塔同帧齐射。
- 性能结论：空闲成本很好；高密度塔的成本约为每塔每秒6.67次物理射线。锁向设计会让移动目标躲掉后续弹，属于玩法而非查询错误。

### 3.4 葡萄电弧塔

- 强类型配置完整：伤害72法术、间隔1.6秒、攻击半径96px（6格）、最多4个不同敌人、跳跃72px、充能0.42秒（`grape_arc_tower.tres:15-25`；`grape_arc_tower_config.gd:4-21`）。
- 主目标用 `max_count=1` 的空间索引最近查询，成本近似候选桶线性；后续每一跳用 `max_count=0` 查72px内全部目标并按距离排序，再跳过已命中者（`grape_arc_tower.gd:309-372`；底层排序见 `combat_target_index.gd:259-282,400-410`）。最多3次完整候选排序，密集敌群下比“最近且排除集合”接口昂贵。
- 结算逐目标提交72法术伤害，最多总计288；每段使用复用的 Line2D 生成7点抖动电弧（`grape_arc_tower.gd:375-490`）。
- 闲置蓝色扫描完全独立于敌人：初始错相0.75~2.75秒，0.72秒扫描+0.16秒淡出，随后3.2秒冷却；只更新两个实例 shader 参数，无索敌/伤害（`grape_arc_tower.gd:16-24,504-621`）。这满足静态场景也反复充能扫描的要求。
- 性能问题：无目标时0.18秒重试；代理也做视觉用索敌。建议宿主空场至少按攻击间隔/全局敌人 roster 信号退避，代理的攻击动作直接由宿主动作复制，不自行5.56Hz选目标。

### 3.5 紫阳花雨幕塔

- 配置：6秒循环、雨幕可见阶段1.5秒、玩法持续5秒、每秒一跳、每跳治疗50/法伤5、敌攻击倍率0.8、选点半径12格、效果半径48px（`hydrangea_rain_tower_config.gd:10-19`）。验证要求循环间隔≥0.68+5=5.68秒（`:22-43`）。
- 可治疗建筑缓存只在植物放置/移除时按12格空间索引重建，静态建筑无需每次施法扫描全表（`hydrangea_rain_tower.gd:180-221`）。选点优先非满血，再按**当前绝对生命值**最低、stable ID 最小；不是最低生命比例（`:224-263`）。
- 每次效果有5跳；每跳分别查询敌人、植物、玩家三个空间集合，共15次半径查询/施法（`:511-598`）。落雨命中窗口从首滴落地持续1.26秒，因此第0和第1跳造成法伤，共10原始法伤；五跳均治疗并刷新敌减攻到剩余效果时长。
- 粒子量：雨场72、波纹112、目标雨滴144、地面露珠96（`hydrangea_rain_tower.tscn:319-366`）。频率低，但多塔重叠施法时 GPU 粒子量比其他塔高。
- 时间轴/多人恢复采用单一 action duration 和 schema=3 快照，当前“玩法5.68结束、视觉尾迹更晚消失”的结构是健壮的，不需要再补独立延迟补丁。

## 4. 建筑、生产、科研与植被

### 4.1 放置、占格、空间索引

- `PlantSystem` 用 `occupied_cells`、`plant_footprints`、`reserved_cells` 管理落位，放置同时检查地形、占用和实体物理空间（`plant_system.gd:117-181,940-984`）。
- 静态植物单次注册到48px bucket 的 `PlantTargetSpatialIndex`；最近植物、逻辑格圆形、世界圆形、交互建筑都复用同一个 broad phase（`plant_system.gd:389-739`；`plant_target_spatial_index.gd:11,101-130,202-314,456+`）。植物不移动，因此没有每帧迁移成本。
- 地形失去支撑后，每1秒全量扫描植物足迹；不支持的植物受到 `max(当前生命×10%,50)` 的无视防御伤害（`plant_system.gd:339-386`；`game_tower_defense.gd:1072-1075,2796-2808`；Timer 在 `game_tower_defense.tscn:449`）。
- `game_tower_defense.gd:960-1037` 通过一组 concrete-type 分支把仓库、生产、科研、紫阳花、植被桩接到各协调器，是主要集中耦合点；每新增建筑类型都需修改主场景脚本。

### 4.2 橡木仓库

- 每座20槽，资源+并行数量数组+`storage_revision`；支持单槽搬运、快速移动、生产批量改写和多人快照（`oak_warehouse.gd:8-35,141-1202`）。
- 生产改写使用预期 revision，事务失败可回滚；UI/网络请求超时4秒。数据完整性优于直接逐槽写。
- 常驻 `_process` 关闭，仅玩家进入交互 Area 后按80ms重选；性能问题是前述重复全组扫描。
- UI 的逐帧路径均按可见/交互状态启停：生产面板只在打开时每帧外推进度条（`production_building_panel.gd:109-158,177-185`）；仓库面板只在手柄拖拽时逐帧移动虚拟光标（`oak_warehouse_panel.gd:184-227,309-330`），不会常驻扫描物品。

### 4.3 四类生产建筑与 17 条配方

`ProductionBuilding` 用共享状态机；宿主由 `ProductionCoordinator` 的1秒 Timer推进所有建筑（`production_coordinator.gd:7,81,343-460,850-860`）。协调器维护稳定仓库顺序、材料总量缓存、revision journal，并在材料/仓容变化时只重试相应阻塞建筑（`:665-849,861-980`）。等待原料或输出满时不会每帧忙轮询。

| 配方（资源） | 输入 → 输出 | 时长 | 实际入口 |
| --- | --- | ---: | --- |
| `wood_to_plank` | 木头1 → 木板2 | 10s | 木头加工站 |
| `wooden_core_assembly` | 木板10+树苗1+水瓶5 → 木制核心1 | 10s | 木头加工站 |
| `water_collector_assembly` | 木板10 → 水源采集器箱1 | 30s | 木头加工站，输出玩家背包 |
| `planting_base_assembly` | 木板20+树苗5+水瓶5 → 种植基地箱1 | 30s | 木头加工站，输出玩家背包 |
| `plant_cultivation_center_assembly` | 木板30+水瓶10 → 培育中心箱1 | 30s | 木头加工站，输出玩家背包 |
| `research_center_assembly` | 木板30+水瓶10 → 科研中心箱1 | 30s | 木头加工站，输出玩家背包 |
| `sapling_propagation` | 树苗1 → 树苗2 | 30s | 种植基地 |
| `sapling_to_wood` | 树苗1 → 木头5 | 60s | 种植基地 |
| `water_to_bottle` | 环境水源0 → 水瓶1 | 20s | 水源采集器，自动选择 |
| `wooden_core_to_agave_cannon` | 木制核心1 → 龙舌兰箱1 | 20s | 植物培育中心，输出玩家背包 |
| `wooden_core_to_corn_machine_gun` | 木制核心1 → 玉米箱1 | 20s | 植物培育中心，输出玩家背包 |
| `wooden_core_to_bamboo_mortar` | 木制核心1 → 竹筒箱1 | 30s | 植物培育中心，输出玩家背包 |
| `wooden_core_to_hydrangea_rain_tower` | 木制核心1 → 紫阳花箱1 | 30s | 植物培育中心，输出玩家背包 |
| `simple_herbal_health_potion` | 树苗1+水瓶1 → 生命药瓶1 | 0.1s | 玩家即时合成 |
| `simple_wood_processing_station` | 木头5 → 木头加工站箱1 | 0.1s | 玩家即时合成 |
| `simple_oak_warehouse` | 木头10 → 橡木仓库箱1 | 0.1s | 玩家即时合成 |
| `simple_vegetation_stake` | 木板10+树苗1 → 植被桩箱1 | 0.1s | 玩家即时合成 |

配方 schema 最多3入3出；单一投入数量0表示环境源，且校验要求来自共享仓库（`production_recipe.gd:4-85`）。玩家即时合成只注册最后四条（`simple_crafting_registry.gd:4-66`），通过背包副本模拟“先耗输入、再放输出”，一次 revision 原子提交（`run_state.gd:1468-1497`）。

### 4.4 科研

- 注册2项：建筑结构强化（木板50+树苗20+水瓶20，60s，全建筑物防+10）和机动训练（水瓶50，60s，全玩家移速+15）；资源入口为 `resources/config/research/*.tres`，注册表见 `global_research_registry.gd:4-50`。
- 同时只能有一个全局项目；开始时由生产协调器原子消费共享仓库，1秒 Timer 推进；完成后重新汇总已完成配置的 effect amount（`research_coordinator.gd:185-243,410-454,487-499`）。
- 个人科技走玩家息壤、等级和 `Player.RESEARCH_TECHNOLOGY_COSTS`，不是物品消耗（`:246-262`）。

### 4.5 植被桩

- `VegetationSpreadSystem` 预计算5个圆环；每10秒仅处理尚未完成的下一环，0.1秒更新只在有活动源/overlay dirty时开启（`vegetation_spread_system.gd:9-18,275-304,346-478,559`）。
- `_generated_cells` 保存原地形和所有 owner，重叠桩移除一个不会错误恢复仍被其他桩覆盖的格子（`:99-176,485-490`）。
- `TOTAL_SPREAD_SECONDS=50` 同时出现在桩脚本和系统脚本（`vegetation_stake.gd:7`、`vegetation_spread_system.gd:15`），应由系统导出/配置单源化。

## 5. 物品定义与注册全貌

### 5.1 类型与数量

`PickupConfig.PickupType` 共8类：SPEED、RAPID、SPIRAL、TENPURA、HEALTH、COLLECTIBLE、MATERIAL、BUILDING（`pickup_config.gd:6-15`）。当前资源计数：

| 类别 | 数量 | 注册/发现方式 | 入背包 |
| --- | ---: | --- | --- |
| 基础世界道具 | 5 | 默认敌人掉落表显式引用 | 仅生命药瓶可存、可999叠 |
| 材料 | 8 | 敌人掉落/生产/配方/科研显式 preload | 全部可999叠（环境水源不是这8项） |
| 建筑箱 | 11 | 配方资源显式引用 | 可存、不可叠、每箱一槽 |
| 收藏品 | 123 | `LuoxiMerchant` 扫描 `collectible_*.tres` | 全部可存、不可叠、每件一槽 |
| 环境水源占位 | 1 | `water_to_bottle.tres` | 类型 MATERIAL，但不可存，数量0表示环境 |

物品相等/叠加先比较同一 Resource 对象，再比较非空 `resource_path`；单槽上限钳制1~999（`pickup_config.gd:128-164`）。这让多人快照和不同 preload 实例能稳定识别同一配置。

### 5.2 八种材料

| 资源 | 来源 | 消费/产出用途 | 审计结论 |
| --- | --- | --- | --- |
| `material_wood` 木头 | 开局5；普通敌人独立2%；树苗转木头 | 木板；即时木头加工站/仓库 | 闭环正常 |
| `material_sapling` 树苗 | 敌人独立1%；种植基地增殖 | 核心、种植基地、研究、药瓶、植被桩；可转木头 | 闭环正常 |
| `material_plank` 木板 | 木头加工站 1木→2板 | 核心、功能建筑、科研、植被桩 | 闭环正常 |
| `material_water_bottle` 水瓶 | 水源采集器20s产1 | 核心、功能建筑、两项研究、药瓶 | 闭环正常 |
| `material_wooden_core` 木制核心 | 木板10+树苗1+水5，10s | 四种战斗/支援塔箱 | **缺葡萄塔消费配方** |
| `material_white_crystal` 白色水晶 | 所有敌人独立0.2% | 无 | 死端库存 |
| `material_capoo_blue_crystal` 卡普蓝晶 | `capoo` 敌人独立1% | 无 | 死端库存 |
| `material_sorcerer_violet_powder` 术士紫晶粉 | `sorcerer` 敌人独立1% | 无 | 死端库存 |

后三者目前只在 `default_enemy_drop_table.tres:5-9,22-44` 被引用，仓库/背包可以无限期累积但没有价值出口。

### 5.3 十一个建筑箱及真实消费路径

全部位于 `resources/config/buildings/`，均 `pickup_type=BUILDING`、可入背包、不可叠、world lifetime=24s。映射如下：

| 建筑箱 | `placeable_plant_id` | 获得路径 |
| --- | --- | --- |
| `building_agave_cannon` | `agave_cannon` | 培育中心20s |
| `building_bamboo_mortar` | `bamboo_mortar` | 培育中心30s |
| `building_corn_machine_gun` | `corn_machine_gun` | 培育中心20s |
| `building_hydrangea_rain_tower` | `hydrangea_rain_tower` | 培育中心30s |
| `building_oak_warehouse` | `oak_warehouse` | 玩家即时合成 |
| `building_plant_cultivation_center` | `plant_cultivation_center` | 木头加工站30s |
| `building_planting_base` | `planting_base` | 木头加工站30s |
| `building_research_center` | `research_center` | 木头加工站30s |
| `building_vegetation_stake` | `vegetation_stake` | 玩家即时合成 |
| `building_water_collector` | `water_collector` | 木头加工站30s |
| `building_wood_processing_station` | `wood_processing_station` | 玩家即时合成 |

使用建筑箱不会先消耗再让玩家找位置。`GameTowerDefense` 先验证类型、资源路径、plant ID、revision 和可放置位置；确认后用 compare-and-swap 消耗1件，再生成建筑；生成失败会把物品放回原槽（单机 `game_tower_defense.gd:1175-1311`；宿主多人 `:1400-1485`）。该链路正确且抗重复请求。

### 5.4 五种世界道具

| 配置 | 效果 | 默认表概率 | 入背包/使用 |
| --- | --- | ---: | --- |
| `pickup_speed` | 5s 移速×1.25 | 0.4% | 不存，碰触立即覆盖/刷新 |
| `pickup_rapid` | 5s 射速×2 | 0.4% | 不存，碰触立即覆盖/刷新 |
| `pickup_spiral` | 5s 武装螺旋；远程射速×10/近战四剑 | 0.2% | 不存，碰触立即切形态 |
| `pickup_tenpura` | 5s 攻击×1.1 | 0.4% | 不存，重复只刷新时长 |
| `pickup_health` | 治疗20 | 0.4% | 满血时存入背包，999叠；使用成功才消耗1 |

实际字段见 `resources/config/pickup_triggered_items/*.tres` 与 `resources/config/consumables/*.tres`。`Player.apply_pickup()` 明确拒绝非即时效果分类，消耗品由背包使用事务调用；收藏品不会被通用“使用”入口消耗。

### 5.5 123 个收藏品：注册、数量与运行时

- 全部是 type=COLLECTIBLE、可入背包、不可叠；重复副本占不同槽。34个设置“逐份生效”，其余按 `collectible_effect_id` 只让首份生效；上限特殊项：苹果≤5、香蕉≤4、橙子≤10，简易/加长/鼓式弹匣及纯净充能水晶≤5。
- 稀有度：普通41、稀有43、史诗26、传说13；123个 effect ID 均非空且无重复。本次静态解析与现有 `dev_tools/collectible_audit_report.md:1-8` 一致。
- 兼容标记：8个要求投射物普攻、12个要求弹药系统，其中1个同时要求两者；候选池在商人生成/领取时调用 `Player.is_collectible_compatible()`（`player.gd:620-635`；`luoxi_merchant.gd:740-760`）。
- 注册不是显式表：`LuoxiMerchant` 枚举目录内所有 `collectible_*.tres`，按路径排序并 `load()` 缓存（`luoxi_merchant.gd:99-148,764-773`）。缓存入口不校验 pickup_type、effect ID、未知枚举字符串或配置数值；目前正确性依赖离线审计脚本。
- 每轮每玩家最多领1件，先验证 offer/兼容，再原子加入对应 peer 背包；满包返回失败，不消耗领取次数（`luoxi_merchant.gd:582-608`）。
- Player 仅在背包/息壤变化时重建统计；扫描固定20槽，按 effect ID 去重/展开副本，并缓存周期项和最近 deadline（`player.gd:2286-2514`）。每帧入口有 O(1) deadline 快路；只有到期才遍历当前周期项（`:2925-2976`）。
- 普攻/受伤/技能/命中/击杀事件会遍历有效收藏品，最多受20槽上限约束（`:2635-2764`）。区域伤害使用敌人空间索引；区域友军治疗的 `_collect_alive_players()` 仍递归整棵当前场景树（`:3651-3665`），可改用现有玩家查询接口。
- 周期家族统计：archer 3、frost 3、heal 4、sakura_rocket 1、thunder 4。触发家族5件；命中家族22件；击杀家族9件。未知字符串在大 `match` 中会静默 no-op，建议在配置加载/CI 做 allow-list 验证。

逐项 ID/名称/稀有度/主效果通道列在附录 A；完整数值、设计说明和图标像素审计可交叉查看 `dev_tools/collectible_audit_report.md`。

## 6. 掉落、拾取、背包、合成与多人路径

### 6.1 敌人掉落

- `EnemyConfig.drop_table` 默认 preload 同一张默认表，因此未覆写的所有敌人都使用它（`enemy_config.gd:66`）。每条规则独立掷骰，单个敌人可同时掉多个物品；required tags 是全包含匹配（`enemy_drop_rule.gd:5-13`；`enemy_drop_table.gd:20-69`）。
- 默认表：木头2%、白晶0.2%、树苗1%、卡普蓝晶1%（capoo）、术士粉1%（sorcerer）、速/射速/天妇罗/生命各0.4%、螺旋0.2%（`default_enemy_drop_table.tres:16-78`）。
- 敌人死亡仅宿主解析掉落，并 deferred 实例化普通 `Pickup` 节点；当前总概率很低，未池化问题不大（`scene/enemy/enemy.gd:3819-3857`）。

### 6.2 世界拾取

- `Pickup` 没有逐帧逻辑：one-shot lifetime Timer + blink Timer；默认世界寿命12秒，建筑箱24秒（`scene/combat/pickups/pickup.gd:29-73`）。
- Area body entered 后客户端直接拒绝结算；宿主/单机先尝试即时 apply，失败再尝试入背包。满血生命瓶由此自然入包；满包时道具留在世界直到过期（`:75-100`）。
- 成功变更后先把 lifecycle 设为 CONSUMED、关碰撞，再发 signal，避免同一物理帧多人重入双领（`:102-123`）。

### 6.3 背包/堆叠/丢弃

- 固定20槽；新局默认木头5；本地数组和每 peer 数组均有独立 revision（`run_state.gd:8-56,77-102`）。
- 加入时先补同资源栈，再找空槽；所有核心操作最多扫描20槽。批量加入/合成先复制两个20元素数组模拟，成功才一次提交（`:1295-1497`）。
- 使用普通物品必须 `player.apply_pickup` 成功才减1；材料/建筑/收藏品不会被通用“使用”误消耗（`:267-288`）。丢弃会直接清空**整槽/整栈**且不会生成世界掉落（`:291-303`），UI文案需要明确。
- `active_multiplayer_peer_id` 让同一无 peer 参数 API 根据全局上下文路由到本地或某个 peer（`:50,111-128,267-269,382-385`）；调用方便但语义隐式，后台系统应优先使用显式 `*_for_peer` API。

### 6.4 快照与网络

- 快照固定20个 slot 字典，包含 peer、revision、config_path、stack_count；接收端拒绝旧 revision、重复/越界槽、不可存资源和超 stack limit，然后通过 `load(config_path)` 恢复 Resource（`run_state.gd:1120-1217`）。
- 它验证“路径能加载且可存”，没有中央物品 allow-list。安全边界依赖快照只由宿主发送；若未来持久化/外部输入复用该解码器，应增加已注册资源白名单。
- 宿主广播拾取生成/领取与背包快照（`mp_game.gd:8737-8775,10537-10594`）；使用、丢弃、合成均是 request ID/revision 的宿主权威事务，结果携带新快照（`:680-746,2200-2331,10728-10987,11230-11311`）。建筑放置另有上述 CAS+回滚链。
- 收藏品效果只在单机或宿主运行，客户端接收伤害/治疗/VFX；权威判定见 `player.gd:3668-3673`。

## 7. 统一化建议（按收益排序）

1. 为葡萄塔补齐 `building_grape_arc_tower.tres`、木核→葡萄配方、培育中心场景引用，以及相应背包/多人冒烟测试；这是当前唯一注册植物与经济链断开的问题。
2. 抽一个 `InteractionSelectionService`：本地和宿主都调用 `PlantSystem.find_nearest_operational_interaction_building_world()`；由玩家或服务每80ms只查询一次，再通知目标建筑，删除三个近乎相同的组扫描实现。
3. 以 `AgaveCannonConfig/BambooMortarConfig/CornMachineGunConfig` 承载炮速、爆炸半径、最小射程、外圈伤害、蓄力/跟踪等全部结算值；消除 `.tres` 与脚本同值默认常量。视觉帧数、Tween 曲线仍留脚本/场景。
4. 将 `PickupConfig` 拆为公共 `ItemConfig` + `ConsumableConfig/MaterialConfig/BuildingItemConfig/CollectibleConfig`，或至少增加按 pickup_type 分派的严格 `is_valid()` 和显式 `ItemRegistry`。收藏品目录扫描可保留作工具发现，但运行时只消费验证后的清单。
5. 把 `inventory_changed` 改为携带 peer ID、revision、change mask；Player 只响应自己的 peer，生产协调器只响应等待该 peer 输出的建筑。现有20槽扫描可以保留。
6. 葡萄连锁用 `find_nearest_alive_excluding(center,72,hit_ids)` 逐跳，避免每跳取全量排序；无敌时指数退避/按 enemy roster 唤醒；代理只重放宿主 action。
7. 为三种稀有材料设计消费端，或在未上线前从默认掉落表移除，避免玩家获得无用途库存。
8. 放置预览复用 Shape/Query，玩家/占用/地形 revision 未变化时不重算全部锚点；鼠标 hover 直接 map_to_local 得到候选格，避免每帧遍历全部 marker。
9. 删除/迁移 `drop_weight`、研究旧常量、植被50秒重复常量和停用 TargetingArea 等兼容债务；在 CI 中加入“注册植物都有建筑箱或显式 debug_only”“所有材料至少一个消费/终端标签”“收藏品字符串属于 allow-list”检查。

## 附录 A：123 个收藏品索引

说明：`唯一`表示相同 effect ID 仅首件生效；`逐份∞/≤N`表示不同背包槽中的重复副本逐份生效。每件仍不可在单槽堆叠。

| 资源 ID | 名称 | 稀有度 | 生效份数 | 主通道 |
| --- | --- | --- | --- | --- |
| `collectible_admin_doll` | 管理员人偶 | 传说 | 唯一 | 专用：庄方宜技能升级免费 |
| `collectible_alchemist_vial` | 炼金小瓶 | 稀有 | 唯一 | 常驻：基础升级免耗率 |
| `collectible_amethyst` | 紫宝石 | 稀有 | 逐份∞ | 常驻属性 |
| `collectible_apple` | 苹果 | 史诗 | 逐份≤5 | 常驻：穿透率 |
| `collectible_apprentice_scroll` | 学徒卷轴 | 普通 | 逐份∞ | 常驻：技力回复 |
| `collectible_archer` | 弓箭手 | 史诗 | 唯一 | 周期 `archer` |
| `collectible_archer_sigil` | 神射徽记 | 史诗 | 唯一 | 周期 `archer` |
| `collectible_auto_loader` | 自动装填器 | 史诗 | 唯一 | 专用：换弹缩短 |
| `collectible_banana` | 香蕉 | 稀有 | 逐份≤4 | 常驻：追踪率 |
| `collectible_battle_standard` | 战旗 | 稀有 | 唯一 | 击杀 `haste` |
| `collectible_blink_crystal` | 闪现水晶 | 史诗 | 唯一 | 技能 `swift` |
| `collectible_blood_trident` | 血色三叉戟 | 稀有 | 唯一 | 专用：流血目标乘区 |
| `collectible_blue_mushroom` | 蓝蘑菇 | 普通 | 唯一 | 命中 `chill` |
| `collectible_blue_quartz` | 蓝石英 | 普通 | 逐份∞ | 常驻：技力回复 |
| `collectible_bone_needle` | 骨针 | 普通 | 唯一 | 命中 `bleed` |
| `collectible_campfire_coal` | 篝火余烬 | 稀有 | 唯一 | 命中 `burn` |
| `collectible_candle_stub` | 蜡烛头 | 普通 | 唯一 | 命中 `burn` |
| `collectible_capacity_spring` | 扩容弹簧 | 普通 | 唯一 | 专用：弹匣百分比 |
| `collectible_celestial_ring` | 星界戒指 | 史诗 | 唯一 | 击杀 `charge` |
| `collectible_charged_jade_pendant` | 充能玉佩 | 稀有 | 逐份∞ | 常驻：技力回复 |
| `collectible_chipped_ruby` | 裂纹红玉 | 普通 | 唯一 | 命中 `burn` |
| `collectible_clay_totem` | 陶土小像 | 普通 | 唯一 | 条件 `health_below` |
| `collectible_copper_gear` | 铜齿轮 | 普通 | 唯一 | 常驻：息壤攻速 |
| `collectible_copper_sword` | 铜短剑 | 普通 | 逐份∞ | 常驻属性 |
| `collectible_crystal_compass` | 水晶罗盘 | 稀有 | 唯一 | 命中 `xirang` |
| `collectible_dragon_heart` | 龙心 | 史诗 | 唯一 | 击杀 `burst` |
| `collectible_drum_magazine` | 鼓式弹匣 | 史诗 | 逐份≤5 | 专用：弹匣加算 |
| `collectible_dual_ammo_chamber` | 双联弹仓 | 史诗 | 唯一 | 专用：弹匣百分比 |
| `collectible_dual_row_feeder` | 双排供弹器 | 稀有 | 唯一 | 专用：弹匣百分比 |
| `collectible_echo_drum` | 回声小鼓 | 稀有 | 唯一 | 常驻：息壤攻速 |
| `collectible_eclipse_amulet` | 蚀月护符 | 史诗 | 唯一 | 技能 `moon_shield` |
| `collectible_ember_leaf` | 余烬叶 | 普通 | 唯一 | 命中 `burn` |
| `collectible_emerald` | 绿宝石 | 普通 | 逐份∞ | 常驻属性 |
| `collectible_extended_magazine` | 加长弹匣 | 稀有 | 逐份≤5 | 专用：弹匣加算 |
| `collectible_flame_trident` | 火焰三叉戟 | 稀有 | 唯一 | 专用：燃烧目标乘区 |
| `collectible_fox_coin` | 狐纹铜币 | 普通 | 唯一 | 常驻：基础升级免耗率 |
| `collectible_frost_crystal` | 寒霜水晶 | 史诗 | 唯一 | 周期 `frost` |
| `collectible_frost_totem` | 寒霜图腾 | 稀有 | 唯一 | 周期 `frost` |
| `collectible_glacier_orb` | 冰川宝珠 | 史诗 | 唯一 | 周期 `frost` |
| `collectible_glass_marble` | 玻璃弹珠 | 普通 | 唯一 | 常驻：穿透率 |
| `collectible_goat_horn` | 山羊角 | 普通 | 唯一 | 命中 `execute` |
| `collectible_gold_apple` | 金苹果 | 稀有 | 唯一 | 击杀 `heal` |
| `collectible_gold_wine_cup` | 金酒之杯 | 传说 | 唯一 | 常驻：息壤攻击 |
| `collectible_gray_gem` | 灰宝石 | 普通 | 逐份∞ | 常驻属性 |
| `collectible_guardian_badge` | 守卫徽章 | 稀有 | 唯一 | 受伤触发 `hurt_thunder` |
| `collectible_gun_oil` | 润滑枪油 | 普通 | 唯一 | 专用：换弹缩短 |
| `collectible_heavy_gauntlet` | 重拳套 | 稀有 | 逐份∞ | 常驻属性 |
| `collectible_herbal_bundle` | 草药束 | 普通 | 唯一 | 命中 `bloom` |
| `collectible_high_speed_loader` | 高速装填器 | 传说 | 唯一 | 专用：换弹缩短 |
| `collectible_hunters_bow` | 猎人短弓 | 稀有 | 唯一 | 周期 `archer` |
| `collectible_iron_dagger` | 铁匕首 | 普通 | 唯一 | 命中 `bleed` |
| `collectible_ironwood_seed` | 铁木种子 | 稀有 | 逐份∞ | 常驻属性 |
| `collectible_jade_fish` | 玉鱼 | 稀有 | 唯一 | 击杀 `charge` |
| `collectible_kingslayer_blade` | 弑王刃 | 传说 | 唯一 | 命中 `execute` |
| `collectible_leaf_cloak` | 叶片披风 | 普通 | 唯一 | 击杀 `haste` |
| `collectible_life_crystal` | 生命水晶 | 史诗 | 唯一 | 周期 `heal` |
| `collectible_life_ring` | 生命戒指 | 稀有 | 逐份∞ | 常驻属性 |
| `collectible_lucky_gem` | 幸运宝石 | 稀有 | 唯一 | 常驻：掉落/升级相关 |
| `collectible_magic_ring` | 魔法戒指 | 稀有 | 逐份∞ | 常驻属性 |
| `collectible_medieval_shield` | 中世纪盾牌 | 稀有 | 唯一 | 常驻：远程减伤 |
| `collectible_mirror_shield` | 镜面盾 | 史诗 | 唯一 | 受伤触发 `hurt_frost` |
| `collectible_moon_amulet` | 月亮护符 | 史诗 | 唯一 | 技能 `moon_shield` |
| `collectible_moon_pin` | 月纹胸针 | 稀有 | 唯一 | 技能 `moon_shield` |
| `collectible_moss_agate` | 苔纹玛瑙 | 普通 | 逐份∞ | 常驻属性 |
| `collectible_nine_eleven` | 911 | 传说 | 唯一 | 专用：高额弹匣 |
| `collectible_obsidian_key` | 黑曜钥匙 | 稀有 | 唯一 | 命中 `execute` |
| `collectible_oil_lamp` | 油灯 | 稀有 | 唯一 | 命中 `burn` |
| `collectible_oracle_cube` | 先知方块 | 传说 | 唯一 | 命中 `mark` |
| `collectible_orange` | 橙子 | 稀有 | 逐份≤10 | 常驻：免弹率 |
| `collectible_pebble_shield` | 卵石小盾 | 普通 | 逐份∞ | 常驻属性 |
| `collectible_philosopher_stone` | 贤者石 | 史诗 | 唯一 | 常驻：息壤/升级相关 |
| `collectible_phoenix_feather` | 凤凰羽 | 史诗 | 唯一 | 周期 `heal` |
| `collectible_physical_ring` | 物理戒指 | 稀有 | 逐份∞ | 常驻属性 |
| `collectible_pocket_anvil` | 口袋铁砧 | 普通 | 唯一 | 命中 `crack` |
| `collectible_power_ring` | 力量戒指 | 稀有 | 逐份∞ | 常驻属性 |
| `collectible_power_wheel` | 加力轮子 | 史诗 | 唯一 | 常驻属性 |
| `collectible_prism_lens` | 棱镜镜片 | 稀有 | 唯一 | 常驻：穿透/投射物 |
| `collectible_pure_charge_crystal` | 纯净充能水晶 | 传说 | 逐份≤5 | 专用：技能保留 |
| `collectible_quick_feather` | 轻羽 | 普通 | 逐份∞ | 常驻属性 |
| `collectible_quick_load_belt` | 快装弹带 | 稀有 | 唯一 | 专用：换弹缩短 |
| `collectible_rain_bead` | 雨珠 | 普通 | 唯一 | 命中 `chill` |
| `collectible_red_mushroom` | 红蘑菇 | 普通 | 唯一 | 命中 `leech` |
| `collectible_river_shell` | 河贝壳 | 普通 | 逐份∞ | 常驻属性 |
| `collectible_roller_skates` | 轮滑鞋 | 稀有 | 唯一 | 常驻属性 |
| `collectible_royal_goblet` | 王家圣杯 | 史诗 | 唯一 | 常驻属性 |
| `collectible_ruby` | 红宝石 | 普通 | 逐份∞ | 常驻属性 |
| `collectible_ruby_crown` | 红玉小冠 | 稀有 | 逐份∞ | 常驻属性 |
| `collectible_runed_book` | 符文书 | 稀有 | 逐份∞ | 常驻属性 |
| `collectible_rusty_helm` | 生锈头盔 | 普通 | 逐份∞ | 常驻属性 |
| `collectible_sakura` | 樱花 | 传说 | 唯一 | 周期 `sakura_rocket` |
| `collectible_salt_charm` | 盐晶符 | 普通 | 唯一 | 命中 `mark` |
| `collectible_sapphire_ring` | 蓝宝石戒指 | 稀有 | 唯一 | 命中 `chill` |
| `collectible_silver_mask` | 银面具 | 稀有 | 唯一 | 专用：远程方位防御 |
| `collectible_simple_magazine` | 简易弹匣 | 普通 | 逐份≤5 | 专用：弹匣加算 |
| `collectible_spark_bottle` | 电火瓶 | 稀有 | 唯一 | 周期 `thunder` |
| `collectible_speed_ring` | 速度戒指 | 稀有 | 逐份∞ | 常驻属性 |
| `collectible_spellblade` | 咒刃 | 史诗 | 唯一 | 命中 `mark` |
| `collectible_steel_longsword` | 钢长剑 | 稀有 | 逐份∞ | 常驻属性 |
| `collectible_stone_tablet` | 石刻片 | 普通 | 唯一 | 常驻属性 |
| `collectible_storm_core` | 风暴核心 | 史诗 | 唯一 | 周期 `thunder` |
| `collectible_sun_brooch` | 日纹胸针 | 稀有 | 唯一 | 周期 `heal` |
| `collectible_sun_moon_relic` | 日月遗物 | 传说 | 唯一 | 技能 `moon_shield` |
| `collectible_swift_boot` | 疾行靴 | 稀有 | 逐份∞ | 常驻属性 |
| `collectible_swift_crystal` | 迅捷水晶 | 史诗 | 唯一 | 技能 `swift` |
| `collectible_tarnished_medal` | 旧勋章 | 普通 | 唯一 | 击杀 `xirang` |
| `collectible_thorn_shield` | 荆棘盾 | 稀有 | 唯一 | 受伤触发 `hurt_thunder` |
| `collectible_thunder_crown` | 雷冠 | 史诗 | 唯一 | 技能触发 `skill_thunder` |
| `collectible_thunder_crystal` | 雷鸣水晶 | 史诗 | 唯一 | 周期 `thunder` |
| `collectible_thunder_god_idol` | 雷神像 | 传说 | 唯一 | 周期 `thunder` |
| `collectible_tianshi_stake` | 天师桩 | 史诗 | 唯一 | 常驻：基础升级免耗 |
| `collectible_tin_ring` | 锡戒指 | 普通 | 逐份∞ | 常驻属性 |
| `collectible_tiny_bell` | 小铃铛 | 普通 | 唯一 | 击杀 `charge` |
| `collectible_titan_helm` | 泰坦头盔 | 史诗 | 唯一 | 常驻属性 |
| `collectible_topaz` | 黄宝石 | 普通 | 逐份∞ | 常驻属性 |
| `collectible_topaz_chip` | 黄玉碎片 | 普通 | 逐份∞ | 常驻属性 |
| `collectible_training_arrow` | 练习箭 | 普通 | 唯一 | 命中 `mark` |
| `collectible_triple_ammo_chamber` | 三联弹仓 | 传说 | 唯一 | 专用：弹匣百分比 |
| `collectible_void_crown` | 虚空王冠 | 传说 | 唯一 | 命中 `execute` |
| `collectible_warm_bread` | 烤面包 | 普通 | 唯一 | 击杀 `heal` |
| `collectible_wind_charm` | 风行符 | 稀有 | 唯一 | 技能 `swift` |
| `collectible_wooden_buckler` | 木圆盾 | 普通 | 唯一 | 常驻属性 |
| `collectible_wool_charm` | 羊毛护符 | 普通 | 唯一 | 受伤触发 `hurt_heal` |
| `collectible_world_seed` | 世界树种 | 传说 | 唯一 | 周期 `heal` |
