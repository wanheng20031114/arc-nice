# 近期新增敌人性能逐项审查（2026-08-13）

## 结论

- 已在 `origin/main` 最新快照 `098fdfba4fa9bbc59944688d1884e16d271ca368` 上完成审查。
- 按用户确认，21 个石蚀变体不纳入本轮；范围为 14 个真正新增行为、技能或资源负载的敌人实现。
- 15 个真实塔防场景压力组合全部通过，当前机器上整帧 wall-time p95 均低于 5 ms。
- 找到并落地 4 项低风险热路径优化；同进程固定 fixture 的 A/B 均保持行为一致并达到门禁。
- 枪手机器人是本批普通敌人中持续 CPU/弹丸压力最高者；正式高密度“皮箱之战”已使用 480 发专用池并通过压力测试，不需要再扩大通用池。
- 主战机器人没有 CPU 瓶颈，但高分辨率 atlas 带来约 35.7 MiB 的理论 RGBA8 纹理负载。这是现有人工审核通过的保真策略，本轮不擅自降采样。

## 范围与方法

范围：

- `lightning_sorcerer_elite`
- `cardboard_monster`、`cardboard_monster_large`
- `combat_robot`、`combat_robot_elite`
- `combat_robot_gunner`、`combat_robot_gunner_elite`
- `combat_robot_drone_operator`、`combat_robot_drone_operator_elite`
- `combat_robot_shield_bearer`、`combat_robot_shield_bearer_elite`
- `combat_robot_ninja`、`combat_robot_ninja_elite`
- `combat_robot_main_battle_elite`

压力矩阵使用生产塔防场景和生产敌人场景，固定种子 `20260813`、固定 60 FPS、预热 60 帧、采样 120 帧。数字是无头模式下当前机器的整帧 wall time，适合做 CPU 相对比较，不代表最终带渲染构建的 GPU 帧时。

原始机器可读结果：`dev_tools/output/recent_enemy_performance_matrix_20260813.json`。

## 逐项结果

| 敌人 | 场景负载（采样期最少存活/请求） | p50 / p95 / p99（ms） | 审查结论 |
| --- | ---: | ---: | --- |
| `lightning_sorcerer_elite` | 24/24，交战 | 1.895 / 2.249 / 2.379 | 连锁查询有上限，短时闪电 VFX 会重建几何，但本负载无 CPU 阻塞；暂不改。 |
| `cardboard_monster` | 40/40，交战 | 2.466 / 3.478 / 3.845 | 继承骑士斩击；已消除非感知帧目标解析并复用斩击查询/去重字典。 |
| `cardboard_monster_large` | 40/40，交战 | 2.218 / 2.587 / 2.768 | 与普通纸箱同一热路径，已一并优化。 |
| `combat_robot` | 40/40，交战 | 1.874 / 2.437 / 2.595 | 已消除非感知帧的目标解析；冲刺物理路径没有发现可直接等价替换的问题。 |
| `combat_robot_elite` | 40/40，交战 | 1.959 / 2.551 / 2.877 | 共享普通战斗机器人实现，已一并优化。 |
| `combat_robot_gunner` | 40/40，交战 | 2.729 / 4.848 / 5.179 | 本批普通怪最高持续压力；瓶颈来自 12 发连射和射线/弹丸规模，不做改变战斗节奏的重构。 |
| `combat_robot_gunner_elite` | 40/40，交战 | 2.725 / 4.973 / 5.333 | 同上；通用 fixture 出现 40 次池溢出，但正式皮箱场景有 480 发专用池并已验证零溢出。 |
| `combat_robot_drone_operator` | 40/40，交战 | 2.212 / 2.638 / 3.124 | 候选数和 LOS 次数有界，无人机运动集中批处理，爆炸查询已缓存；无需改。 |
| `combat_robot_drone_operator_elite` | 40/40，交战 | 2.230 / 2.808 / 3.144 | 与普通版同结论。 |
| `combat_robot_shield_bearer` | 94/96，接近 | 2.663 / 3.489 / 4.488 | 盾牌 Area 为被动拦截器，没有常驻扫描；节点增量可接受。 |
| `combat_robot_shield_bearer_elite` | 90/96，接近 | 2.680 / 3.542 / 3.914 | 与普通版同结论。 |
| `combat_robot_ninja` | 73/96，接近 | 2.863 / 3.827 / 4.025 | Boost 时更新 shader 方向，碰撞形状仅状态切换时同步；当前负载可接受。 |
| `combat_robot_ninja_elite` | 73/96，接近 | 2.833 / 3.593 / 4.009 | 与普通版同结论。 |
| `combat_robot_main_battle_elite` | 1/1，交战 | 1.201 / 1.490 / 1.563 | CPU 余量充足；已短路技能冷却期查询并复用预警线两点。内存是主要代价。 |
| `combat_robot_main_battle_elite`（8 体压力） | 8/8，交战 | 1.464 / 1.795 / 2.199 | 超出常规设计数量仍无 CPU 异常；中位内存约 352.9 MiB。 |

## 已落地优化与 A/B 证据

### 1. 感知未到期时不解析目标

`CapooKnight`（覆盖两个纸箱怪）和 `CombatRobot` 原先每个物理帧都先解析目标，再检查感知刷新是否到期。现在只在刷新到期时解析。

固定活体玩家目标、每样本 240,000 次调用的同进程 A/B；两臂都直接调用生产 `_physics_process(0.0)`，legacy 仅在入口前恢复旧的无条件目标解析：

| 路径 | Legacy | Optimized | 加速 | 行为 |
| --- | ---: | ---: | ---: | --- |
| 纸箱/骑士 | paired ratio 1.000 | 0.563 | 1.79x | checksum、状态、速度一致；目标解析 2,640,000 → 0 |
| 战斗机器人 | paired ratio 1.000 | 0.542 | 1.84x | checksum、状态、速度一致；目标解析 2,640,000 → 0 |

### 2. 主战机器人冷却期提前返回

技能 2 处于冷却时，旧实现仍先执行完整分页 `Physics2D` 圆形查询；当三种动作都在冷却时也会继续解析常规目标。现在先看冷却，再决定是否查询。

固定 96 个真实物理目标、11 对 AB/BA，optimized 直接调用生产 `_try_start_ready_action()`：paired ratio `0.002413`，约 `413.9x`；shape query 与目标解析均由 `2112 → 0`，动作状态和 checksum 一致。

### 3. 主战机器人 Skill1 预警线复用已创作的两个点

旧实现每次更新都新建 `PackedVector2Array`；现在使用 `set_point_position()` 原位更新。

每样本 120,000 次更新、11 对 AB/BA，optimized 直接调用生产 `_update_skill1_warning_line()`：paired ratio `0.738438`，约 `1.35x`；4096 次逐点行为校验及最终点一致。

### 4. 骑士/纸箱斩击复用查询对象和命中去重字典

旧实现每次斩击新建 `PhysicsShapeQueryParameters2D` 和 `Dictionary`；现在随实例持有并在每次查询前更新/清空。

真实 Physics2D fixture（16 个真实 `PlantDefense`、每目标 2 shapes、生产上限每查询 16 results、去重后 8 命中），optimized 直接调用生产 `_apply_slash_damage()`。30 对 AB/BA 中 30/30 获胜；paired median ratio `0.9565`（约 `1.045x`），paired p90 ratio `0.9670`。逐目标命中、伤害、来源、方向和伤害类型全部一致。

对应的可重复性能证书：

- `dev_tools/recent_enemy_hot_path_performance_ab.gd`
- `dev_tools/capoo_slash_query_performance_ab.gd`

## 观察到但未直接改动的风险

### 枪手机器人弹丸池

通用 40 体 fixture 使用默认池时，普通/精英分别记录 26/40 次 overflow，说明默认容量不适合刻意构造的高密度持续齐射。但正式高密度皮箱场景在单人和多人协调器中都将精英弹池容量、预热数设为 480；`rogue_suitcase_combat_stress_smoke_test.gd` 连续两轮验证 480 个唯一租约复用且累计 overflow 为 0。本轮实跑该测试通过，因此不扩大所有模式的常驻池。

### 主战机器人内存

atlas 为 3216×2909，按 RGBA8 估算约 35.7 MiB；矩阵中该场景的进程内存比多数普通敌人组合高约 34 MiB。资产发布审计明确要求 `high_resolution_source_preserved_linear_display`、运行缩放 0.125，并禁止 resize/resample。自动降采样会违反已批准的视觉合同，所以这里只记录为明确的内存/画质权衡。

### 凌兰 Skill1 旧探针（范围外邻接发现）

凌兰不是本轮“近期新增敌人”。盘点时发现其池性能探针仍硬断言旧的 2.0 秒/720 发峰值；当前配置为 1.2 秒飞行期，且寿命结束后还有 0.2 秒缩小回收期，因此旧探针的模型和断言都不再代表生产生命周期。本轮没有把这个既有 Boss 扩入改动范围，也没有用该探针为近期敌人结论背书；应另立 Boss 专项，以真实发环节奏和池隔离帧重建容量/射线压力证书。

## 验证与基线说明

通过：

- Godot `--check-only`。
- 15/15 个非石蚀真实场景性能组合。
- 两个新 A/B 性能证书及其行为等价门禁。
- `capoo_knight`、两个 cardboard core、`combat_robot`、`combat_robot_elite`、主战机器人 core/integration/network、全敌人 scene contract。
- 皮箱之战 480 发池压力测试。
- `git diff --check`。

扩展回归还发现 4 个与本次改动无依赖交叉的既有 smoke 失败：`lightning_sorcerer_elite_smoke_test.gd`、`combat_robot_drone_operator_smoke_test.gd`、`combat_robot_ninja_smoke_test.gd`、`combat_robot_ninja_elite_core_smoke_test.gd`。已在干净的 `098fdfba4fa9` worktree 上逐条复现相同断言，因此它们是最新远端快照的基线测试债务，不是本轮性能改动引入的回归。
