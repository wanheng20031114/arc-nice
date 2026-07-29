# 敌人系统全量审计

> 审计对象：当前工作树中的敌人配置、敌人/弹丸场景、运行时脚本、塔防目标选择、联机同步与 Boss 专属流程。
> 审计方式：静态源码逐项追踪；本子报告不包含实机压测结果，因此“性能风险”表示由调用频率、查询上限、节点数量及网络事件量推导出的风险级别。
> 数值口径：`物防`为点数减伤，`魔防`为百分比；两者最终都至少承受 1 点伤害。`攻`是配置中的 `attack_damage`，不一定等于一次完整技能的总伤害。

## 一、结论摘要

- 当前有 **28 个可实例化敌人配置**：原石虫 8、史莱姆 4、Capoo 8、术士 5、人造物 2、铃兰 Boss 1。配置入口均位于 `resources/config/enemies/*.tres`。
- 公共底座已经做了较多规模化优化：导航默认按 6 个物理帧采样（约 10 Hz）、远处静态目标按 8 帧采样；战斗感知可按 3 帧采样（约 20 Hz）；接触伤害在没有接触且没有冷却时快速退出；状态持续伤害交给集中截止时间调度器；多人客户端代理关闭本地物理与伤害碰撞。证据见 `scene/enemy/enemy.gd:57-83,132-145,474-505,796-825,1613-1845,3222-3301,3623-3675`。
- 最高性能风险是铃兰技能 1：当前参数静态计算约为 **360 发/秒、单次技能约 6120 发、稳态约 720 个同时存活弹丸**；虽有对象池和“整圈批量注册”，每颗弹丸仍独立执行物理移动与世界射线。证据见 `resources/config/bosses/linglan_skill_config.gd:21-30`、`resources/config/bosses/linglan_skill1.tres:7-12`、`scene/boss/linglan/linglan_boss.gd:445-503`、`scene/boss/linglan/linglan_skill1_sakura_bullet.gd:149-168`。
- 有三项明确的实现一致性问题：
  1. 翠壳光环只保存一个 `aura_touched_player`，多人同时站入时后进入者覆盖前者，离开事件也可能让仍在范围内的玩家停止受伤；见 `scene/enemy/yuanshi_insect/yuanshi_insect_aura.gd:262-317`。
  2. 自爆原石虫的爆炸场景掩码是 `6`（玩家层 2 + 敌人层 4），实现也只处理 `Player`/`Enemy`，不会伤害植物，却会伤害友军敌人；且打玩家使用减攻快照、打敌人使用未减攻的原始爆炸伤害；见 `scene/enemy/yuanshi_insect/yuanshi_insect_bomber.tscn:76-82`、`scene/enemy/yuanshi_insect/yuanshi_insect_exploder.gd:97-161`。
  3. “火焰弹原石虫”的弹丸硬编码为物理伤害且不附加燃烧；命名/表现与机制不一致；见 `scene/enemy/yuanshi_insect/yuanshi_insect_fire_projectile.gd:121-143`。
- `attack_damage` 同时承担接触、斩击、弹丸或单颗法球等不同语义，导致配置表难以直接比较：火术士一次发 3 颗，每颗都是完整 `attack_damage`；石头人的同一数值同时用于 0.5 秒一次的接触伤害和范围砸地。该字段应被视为“单次命中基数”，而非单位 DPS。

## 二、公共架构与实际调用链

### 2.1 从配置到运行时

1. `EnemyConfig` 定义类别、场景、生命/攻击/双防/速度/Home 伤害、地形能力、死亡爆炸、息壤奖励及掉落表；默认值见 `resources/config/enemies/enemy_config.gd:15-66`。
2. 每个 `.tres` 指向一个完整敌人场景；大多数场景继承 `scene/enemy/enemy.tscn`。公共本体是 `CharacterBody2D`，碰撞层 4、掩码 2049；接触伤害 `Area2D` 在层 8、掩码 514，见 `scene/enemy/enemy.tscn:37-51`。
3. 生成后由 `Enemy.setup()` 应用配置、目标玩家和共享寻路器，见 `scene/enemy/enemy.gd:514-536`。塔防运行时以约 0.60 秒的预算化轮询重新指定玩家与植物目标，见 `scene/game_tower_defense.gd:4569-4583`。
4. 具体子类拥有 `_physics_process()`；公共 `Enemy` 本身没有物理帧入口。各子类每帧推进接触、攻击状态机和移动，但导航方向通常复用采样结果。
5. 远程单位通过 `_get_preferred_ranged_combat_target()` 和 `_has_ranged_combat_line()` 决定站位；LOS 射线默认每 6 个物理帧、按实例错峰刷新，并在目标/自身移动超过 8 像素或导航代际变化时失效，见 `scene/enemy/enemy.gd:624-718`。
6. 普通目标导航先尝试经过碰撞认证的直线移动，否则查询共享流场，再落回 `move_and_slide()`；见 `scene/enemy/enemy.gd:2467-2811,3416-3468`。远处 Home 目标采样间隔可升至 8 帧，战斗感知默认 3 帧，见 `scene/enemy/enemy.gd:3222-3301`。

### 2.2 伤害、状态与死亡

- 敌人受物理伤害：`max(原始伤害 - 有效物防, 1)`；受法术伤害：`max(floor(原始伤害 × (100-魔防)/100), 1)`；之后再乘所有“承伤倍率”的乘积且最低 1，见 `scene/enemy/enemy.gd:1613-1624`。
- 物防来源按点数相加；移速倍率和承伤倍率分别相乘；“对外攻击减伤”只取所有来源中最强的一个（最低倍率），避免多个 20% 减攻叠成指数下降，见 `scene/enemy/enemy.gd:1041-1174,1230-1267`。
- 弹丸/技能在攻击提交时调用 `get_effective_attack_damage()` 固化减攻后的伤害快照，避免减攻效果在飞行中结束造成主客端分歧，见 `scene/enemy/enemy.gd:1150-1159`。
- 寒冷最多 4 层，由全局调度器维护；燃烧固定每 1 秒造成法术伤害，流血默认每 0.5 秒造成物理伤害；持续状态使用集中截止时间调度，不要求每个敌人持续运行 `_process()`，见 `scene/enemy/enemy.gd:44-54,1176-1227,1409-1468,1627-1845`。
- 公共接触伤害间隔为 0.5 秒。进入 `Area2D` 时立即尝试一次，此后只有存在接触或冷却尚未结束才做更新；植物优先于玩家，见 `scene/enemy/enemy.gd:132-134,3543-3724`。
- 死亡时先锁定 `is_dead`，再清状态、结算息壤与掉落、发 `defeated`、关闭碰撞/物理，最后播放死亡序列，见 `scene/enemy/enemy.gd:3781-3807`。
- 默认掉落表中各条规则独立投掷：木材 2%、白水晶 0.2%、树苗 1%、Capoo 蓝水晶 1%（仅 Capoo）、术士紫粉 1%（仅术士）、速度/攻速/天妇罗/治疗各 0.4%、螺旋 0.2%；见 `resources/config/enemies/default_enemy_drop_table.tres:16-78`、`resources/config/enemies/enemy_drop_table.gd:20-61`。所有未显式覆盖 `drop_table` 的敌人，包括铃兰，都会继承此默认表。

### 2.3 目标查询规模

- 基础运行时的“最近攻击目标”扫描本地玩家和联机玩家，复杂度为 O(玩家数)，见 `scene/game_runtime_base.gd:315-368`。
- 塔防覆写再合并 `PlantSystem` 返回的最近存活植物，见 `scene/game_tower_defense.gd:4602-4638`。
- 敌人空间索引使用 96 像素桶；注册后靠变换通知在跨桶时迁移，并按 32 个目标阈值选择线性扫描或桶环查询，见 `scene/combat_target_index.gd:4-32,45-90`。守护光环等敌人对敌人的范围查询使用此索引。

## 三、配置总表

评级口径：性能“低/中/高/极高”指同类单位大量出现时的热点风险；耦合“低/中/高”指脚本对运行时动态方法、专用联机协议和场景节点名的依赖程度。

### 3.1 原石虫（8 种）

| 敌人 / 配置 | HP | 攻 | 物/魔防 | 速 | Home / 奖励 | 实际专属机制 | 性能 / 耦合 |
|---|---:|---:|---:|---:|---:|---|---|
| 基础原石虫 `yuanshi_insect_basic.tres:9-13` | 40 | 10 | 0/0 | 20 | 1 / 1 | 物理接触 | 低 / 低 |
| 迅捷原石虫 `yuanshi_insect_fast.tres:9-15` | 35 | 10 | 0/0 | 40 | 1 / 1 | 仅速度翻倍 | 低 / 低 |
| 硬壳原石虫 `yuanshi_insect_shell.tres:9-18` | 140 | 14 | 3/0 | 20 | 2 / 2 | 高生命、少量点数物防 | 低 / 低 |
| 自爆原石虫 `yuanshi_insect_bomber.tres:9-18` | 30 | 10 | 0/0 | 18 | 1 / 1 | 死亡后 30 伤、30 半径爆炸 | 中 / 中 |
| 紫晶自爆原石虫 `yuanshi_insect_purple_bomber.tres:9-20` | 40 | 10 | 0/0 | 32 | 1 / 2 | 死亡后 30 伤、40 半径爆炸 | 中 / 中 |
| 翠壳原石虫 `yuanshi_insect_green_shell.tres:11-24` | 200 | 20 | 5/0 | 15 | 5 / 2 | 半径 30、每 1 秒一次的物理玩家伤害光环；本体仍有接触伤害 | 中 / 高 |
| 守护者原石虫 `yuanshi_insect_guardian.tres:11-24` | 150 | 10 | 5/0 | 20 | 5 / 2 | 半径 46，给范围敌人 +3 物防；本地粒子关闭 | 中 / 高 |
| 火焰弹原石虫 `yuanshi_insect_fire_ranged.tres:13-20` | 40 | 25 | 0/0 | 22 | 2 / 1 | 172.8 射程，1.35 秒间隔，帧 2 发射；弹丸 142.5 速、2 秒寿命；实际物理且无燃烧 | 中 / 高 |

### 3.2 史莱姆（4 种）

| 敌人 / 配置 | HP | 攻 | 物/魔防 | 速 | Home / 奖励 | 实际专属机制 | 性能 / 耦合 |
|---|---:|---:|---:|---:|---:|---|---|
| 史莱姆 `slime.tres:9-14` | 100 | 10 | 0/0 | 20 | 1 / 1 | 物理接触 | 低 / 低 |
| 火焰史莱姆 `slime_fire.tres:8-16` | 200 | 10 | 0/0 | 20 | 1 / 1 | 接触改为魔法；成功命中后施加 3 秒、等级 10 的燃烧 | 低 / 中 |
| 寒冰史莱姆 `slime_frost.tres:8-16` | 200 | 10 | 0/0 | 20 | 1 / 1 | 接触改为魔法；玩家叠寒冷，植物只承受直接伤害 | 低 / 中 |
| 黄金史莱姆 `slime_golden.tres:8-16` | 1000 | 50 | 0/0 | 20 | 1 / 1 | 无元素状态，仍是物理接触 | 低 / 低 |

### 3.3 Capoo（8 种）

| 敌人 / 配置 | HP | 攻 | 物/魔防 | 速 | Home / 奖励 | 攻击参数与完整语义 | 性能 / 耦合 |
|---|---:|---:|---:|---:|---:|---|---|
| AK 猫猫虫 `capoo_ak47.tres:13-20` | 150 | 20 | 0/0 | 18 | 2 / 20 | 170 射程；1.5 秒前摇；10 发连射、发间 0.08 秒；3.5 秒间隔；每发物理 | 高 / 高 |
| 骑士猫猫虫 `capoo_knight.tres:13-21` | 200 | 28 | 10/0 | 34 | 5 / 20 | 48 射程；0.35 秒前摇；4 秒间隔；6.5~48、60°扇形物理斩击 | 中 / 高 |
| 精英骑士 `capoo_knight_elite.tres:11-22` | 350 | 28 | 15/0 | 34 | 8 / 20 | 与骑士相同，攻击间隔缩至 2 秒 | 中 / 高 |
| 剑客猫猫虫 `capoo_swordsman.tres:11-25` | 400 | 24 | 5/0 | 38 | 5 / 20 | 骑士空子类；64 射程、3 秒间隔、6.5~64、80°扇形 | 中 / 高 |
| 法师 Capoo `capoo_mage.tres:13-20` | 200 | 35 | 0/0 | 24 | 5 / 30 | 接触与火球均为魔法；640 射程、1 秒前摇、4 秒间隔；155 速、4 秒寿命、半径 10.5、转向率 0.65 的追踪 AoE | 中 / 高 |
| RPG 猫猫虫 `capoo_rpg.tres:13-21` | 200 | 20 | 0/0 | 16 | 5 / 24 | 320 射程、0.5 秒前摇、6 秒间隔；210 速、3 秒寿命；44 半径物理爆炸 | 中 / 高 |
| 冲锋枪 Capoo `capoo_smg.tres:13-20` | 200 | 30 | 0/0 | 100 | 2 / 25 | 移动中射击；48 射程、0.1 秒一发、20°散布；生产路径为短距物理 hitscan | 高 / 高 |
| 狙击手 Capoo `capoo_sniper.tres:13-21` | 100 | 200 | 20/0 | 80 | 2 / 35 | 720 射程、锁定 3 秒、4.5 秒间隔；锁定结束直接物理命中 | 中 / 高 |

### 3.4 术士（5 种）

| 敌人 / 配置 | HP | 攻 | 物/魔防 | 速 | Home / 奖励 | 攻击参数与完整语义 | 性能 / 耦合 |
|---|---:|---:|---:|---:|---:|---|---|
| 火焰术士 `fire_sorcerer.tres:13-22` | 200 | 40 | 20/80 | 24 | 5 / 35 | 672 射程、0.6 秒召唤、3 秒间隔；一次 3 球，每球 40 魔法并燃烧 5 秒/等级 5，因此全中直接伤害为 120 | 高 / 高 |
| 精英火焰术士 `fire_sorcerer_elite.tres:10-29` | 300 | 70 | 40/80 | 24 | 5 / 35 | 3 球，每球 70 魔法；球速 115；燃烧等级 10；全中直接伤害 210 | 高 / 高 |
| 寒冰术士 `frost_sorcerer.tres:11-20` | 200 | 50 | 20/80 | 24 | 5 / 35 | 672 射程、0.6 秒召唤、3 秒间隔；100 速冰锥，魔法命中并给玩家叠寒冷 | 中 / 高 |
| 精英冰霜术士 `frost_sorcerer_elite.tres:10-22` | 300 | 80 | 20/80 | 24 | 5 / 35 | 间隔 2 秒、冰锥速度 125，其余继承普通冰术士 | 中 / 高 |
| 雷电术士 `lightning_sorcerer.tres:9-18` | 200 | 50 | 20/80 | 24 | 5 / 35 | 112 初始射程、0.6 秒前摇、3 秒间隔；48 跳跃范围，最多 4 次跳跃，即最多 5 个不同目标；每个目标承受完整 50 魔法 | 中 / 高 |

### 3.5 人造物与 Boss

| 敌人 / 配置 | HP | 攻 | 物/魔防 | 速 | Home / 奖励 | 攻击参数与完整语义 | 性能 / 耦合 |
|---|---:|---:|---:|---:|---:|---|---|
| 石头人 `stone_golem.tres:9-24` | 1000 | 100 | 50/0 | 15 | 25 / 50 | 0.8 秒前摇，44 半径 360°物理砸地；初始攻击错峰上限 0.35 秒；同时保留每 0.5 秒一次的 100 接触伤害 | 中 / 高 |
| 精英石头人 `stone_golem_elite.tres:9-24` | 1800 | 150 | 75/0 | 15 | 25 / 50 | 前摇缩至 0.6 秒；150 接触 + 150 范围砸地 | 中 / 高 |
| 铃兰 `linglan_boss.tres:8-17` | 100000 | 20 | 20/50 | 0 | 1 / 500 | 公共接触 20；自身移动速度由技能配置的 120 驱动；四技能轮换，半血后每 10 秒空投一个狙击手 | 极高 / 高 |

## 四、逐家族实现审计

### 4.1 原石虫家族

#### 公共移动

`YuanshiInsect` 的物理帧流程非常直接：更新接触伤害、校验目标/接触、取得缓存导航方向、乘有效速度、移动，见 `scene/enemy/yuanshi_insect/yuanshi_insect.gd:13-31`。基础/迅捷/硬壳只改配置，因此没有额外每帧开销。

#### 自爆与紫晶自爆

- `_die()` 在公共状态被清除前快照减攻后的爆炸伤害，死亡动画完成后再进入爆炸序列；见 `scene/enemy/yuanshi_insect/yuanshi_insect_exploder.gd:34-94`。
- 爆炸使用 `CompleteShapeQuery2D.intersect_shape_all()`，分页批大小 64，能够完整取得密集范围内对象，见同文件 `97-132`。查询只发生一次，单体风险中等、群体同帧死亡时会形成查询尖峰。
- 严重语义偏差：场景 `ExplosionArea` 掩码为 6，而植物层不在其中；代码只分支 `Player` 和 `Enemy`。若设计目标是“自爆攻击防线”，当前并未实现。更进一步，玩家使用 `outgoing_explosion_damage_snapshot`，敌人却用 `config.explosion_damage`，减攻效果对两类目标不一致，见同文件 `149-161`。

#### 翠壳伤害光环

- 光环 `Area2D` 只监测玩家层，半径默认为 30；进入时立即命中，之后按配置 1 秒冷却；本体仍执行普通接触，见 `scene/enemy/yuanshi_insect/yuanshi_insect_aura.gd:37-74,262-317`、`resources/config/enemies/yuanshi_insect_green_shell_config.gd:4-6`。
- **多人正确性问题**：字段是单个 `aura_touched_player` 而非按 instance id 维护的集合。玩家 B 进入会覆盖 A；B 离开时字段置空，即使 A 仍在光环内也不再受伤。该问题不是性能优化取舍，而是目标跟踪模型不完整。
- 粒子为场景内 `GPUParticles2D`，配置量 32、寿命 0.85；不是逐次攻击实例化，开销相对稳定。证据见 `resources/config/enemies/yuanshi_insect_green_shell.tres:11-13`、`scene/enemy/yuanshi_insect/yuanshi_insect_aura.gd:74-135`。

#### 守护者防御光环

- 守护效果没有让每个守护者持续做物理重叠查询，而是由 `GuardianAuraSystem` 集中管理；系统每 0.2 秒积累刷新债务，每渲染帧最多处理 32 个来源并受 2500 微秒预算约束，见 `scene/enemy/yuanshi_insect/guardian_aura_system.gd:1-46,205-369`。
- 候选从完整 `CombatTargetIndex` 中按半径取回，再用敌人的实际碰撞形状做精确圆形相交测试；生产路径没有全容器 O(N²) 兜底，见同文件 `671-853,1070-1141`。
- 每个守护者以独立 `source_id` 给目标加 +3 物防，覆盖差分只增删变化项；守护者死亡、目标退出容器时同步清理，见同文件 `403-428,856-953`。这是敌人家族中结构最健壮的一套群体增益实现，但对 `CombatTargetIndex` 完整注册和容器信号有较高耦合。
- 守护者点光源做全局名额限制，最多 12 个；`get_nodes_in_group()` 只在尝试申领名额时使用，不是每帧扫描，见 `scene/enemy/yuanshi_insect/yuanshi_insect_aura.gd:223-258`。

#### 火焰弹远程原石虫

- 物理帧用 20 Hz 战斗感知检查射程/LOS，攻击动画到配置帧 2 时发射；攻击提交时强制精确 LOS，见 `scene/enemy/yuanshi_insect/yuanshi_insect_fire_ranged.gd:34-57,83-120,208-220`。
- 弹丸支持会话对象池；每个物理帧移动并做一次世界射线，依靠 `Area2D.body_entered` 对玩家或植物命中，见 `scene/enemy/yuanshi_insect/yuanshi_insect_fire_projectile.gd:31-118`。
- 伤害硬编码为物理，且没有调用任何燃烧状态接口，见同文件 `121-143`。若“火焰”只是视觉命名，应在数据说明中明确；若预期元素攻击，则实现未对齐。

### 4.2 史莱姆家族

- 所有史莱姆继承 `YuanshiInsect`，仅 `SlimeConfig.variant` 决定接触类型/状态，见 `resources/config/enemies/slime_config.gd:1-13`、`scene/enemy/slime/slime.gd:1-73`。
- 火/冰史莱姆将直接伤害改为魔法；火焰成功命中玩家或植物后附加 3 秒、等级 10 燃烧；寒冰只对玩家叠寒冷，因为植物没有移动状态。联机玩家命中由 `MPGame` 根据 `source_type` 再强制成魔法并执行元素状态，见 `scene/enemy/slime/slime.gd:10-58`、`scene/multiplayer/mp_game.gd:7101-7115`。
- 这套实现没有额外范围查询或弹丸，性能低风险。主要耦合来自字符串协议 `fire_slime_touch` / `frost_slime_touch` 同时存在于敌人脚本与多人入口。

### 4.3 Capoo 家族

#### AK 猫猫虫

- 追击/站位感知按 20 Hz 刷新，前摇和连射仍在 60 Hz 推进；同批敌人使用确定性的 ±2 物理帧攻击相位偏移，降低同帧齐射尖峰，见 `scene/enemy/capoo/capoo_ak47.gd:51-126`。
- 1.5 秒前摇后进入 10 发 burst，内部 `while` 补偿长帧，发间 0.08 秒；见同文件 `218-289`。
- 子弹优先走对象池，并注册到一个集中 `CapooProjectileMotionSystem`；系统用密集数组和 swap-remove 在一个 `_physics_process()` 中批量推进，见 `scene/enemy/capoo/capoo_ak47.gd:294-353`、`scene/enemy/capoo/capoo_projectile_motion_system.gd:23-124`。
- 每颗子弹仍有自己的 `Area2D`；世界碰撞射线按两帧一次调度，并在伤害前补验未检查线段，兼顾性能和穿墙正确性，见 `scene/enemy/capoo/capoo_ak47_bullet.gd:161-249,271-330`。大量 AK 的压力主要来自弹丸节点、Area 接触与联机投射物事件，而不是脚本 `_physics_process` 数量。

#### 骑士、精英骑士、剑客

- 三者共用 `capoo_knight.gd` 状态机；剑客脚本本身是空子类，完全由配置扩展半径/角度/间隔。物理帧战斗感知按 20 Hz，前摇/斩击时序为 60 Hz，见 `scene/enemy/capoo/capoo_knight.gd:44-79,121-212`、`scene/enemy/capoo/capoo_swordsman.gd:1-2`。
- 斩击用一次圆形 `intersect_shape(query, 16)`，再在脚本中筛内外半径与扇形角度，见 `scene/enemy/capoo/capoo_knight.gd:215-268`。
- **密集场景正确性风险**：Godot 只返回最多 16 个形状结果，且筛角度发生在查询之后。圆内若先返回 16 个不在扇形内的碰撞体，真正位于斩击扇形内的目标可能完全没有机会进入结果。石头人已经采用完整分页查询，骑士系尚未统一。
- 骑士系显式关闭公共接触攻击，只靠斩击；见同文件 `437-444`。动作通过 `broadcast_enemy_action` 同步前摇和斩击视觉。

#### SMG

- 生产模式为移动中短距 hitscan，不生成配置里仍保留的 bullet 场景；每 0.1 秒可发一次，命中范围由 `13 + 190×0.18 ≈ 47.2` 像素的旧弹丸行程推导，接近配置 48 射程，见 `resources/config/enemies/capoo_smg_config.gd:4-13`、`scene/enemy/capoo/capoo_smg.gd:10-12,48-82,297-336`。
- 单个单位最高约 10 次物理射线/秒、原始 300 DPS；无弹丸节点分配，CPU 本地路径较轻。但每枪都会同步一次敌人动作/枪口火光，大群 SMG 的网络事件和客户端特效频率为高风险。

#### RPG

- 每个物理帧尝试检查攻击条件；LOS 本身由公共 6 帧缓存降低射线频率。0.5 秒前摇后发一枚对象池火箭，见 `scene/enemy/capoo/capoo_rpg.gd:41-73,107-192`。
- 火箭每个物理帧做世界射线；爆炸用完整分页形状查询（批 64），对玩家/植物造成物理伤害，见 `scene/enemy/capoo/capoo_rpg_rocket.gd:152-248`。
- 火箭对象池化，但爆炸表现仍直接 `instantiate()`，见同文件 `252-264`；同帧多枚爆炸会产生短时节点分配和音效压力。

#### 法师 Capoo

- 接触和火球都是魔法。640 射程下每物理帧检查站位/攻击提交，公共 LOS 缓存避免每帧射线；见 `scene/enemy/capoo/capoo_mage.gd:32-85`。
- 火球对象池化、每物理帧追踪转向并做世界射线；爆炸采用完整分页查询、法术伤害；命中特效严格走池且可按视口裁剪，见 `scene/enemy/capoo/capoo_mage_fireball.gd:172-218,250-332`。风险主要随在途火球数线性增长。

#### 狙击手 Capoo

- 目标进入 720 射程并确认 LOS 后开始 3 秒锁定；锁定期间每物理帧校验目标和距离，开火前再做一次精确 LOS，之后直接命中，无弹丸，见 `scene/enemy/capoo/capoo_sniper.gd:129-265`。
- 锁定标记每次通过场景实例化、结束后释放，见同文件 `294-317`；大量狙击手反复取消/重锁时有可避免的节点抖动。
- 客户端代理仅在锁定视觉活动时启用 `_process()`，其余时间回到公共代理关闭状态，见同文件 `88-96,375-400`。

### 4.4 术士家族

#### 公共模式与重复代码

- 火、冰、雷脚本各自复制了“从运行时寻找最近玩家/植物目标”的代码和 0.35 秒缓存；分别见 `scene/enemy/sorcerer/fire_sorcerer.gd:10-138`、`frost_sorcerer.gd:7-129`、`lightning_sorcerer.gd:13-138`。
- 三者都在攻击提交时强制精确 LOS；平时站位使用公共 6 帧缓存。每个实例的目标查询最频繁约 2.86 次/秒，而非 60 次/秒，但三份实现增加了行为漂移风险。
- 普通/精英火术士共享同一主脚本但使用不同 volley 场景；普通/精英冰术士共享同一主脚本和冰锥场景。精英差异主要由配置子类和 `.tres` 覆盖。

#### 火焰术士

- 0.6 秒召唤结束生成一个“三球合一”的 volley 节点，而不是 3 个独立顶层节点；单节点每帧循环 3 个球，见 `scene/enemy/sorcerer/fire_sorcerer.gd:274-448`、`scene/enemy/sorcerer/fire_sorcerer_fireball_volley.gd:224-315`。
- 每颗球都保留完整 `attack_damage`，分别消费一次碰撞并附加燃烧；普通全中 120、精英全中 210，且燃烧分别为等级 5/10，见 volley 脚本 `427-486`。
- 追踪目标死亡后才每 0.35 秒重选；普通飞行主要依赖 Area 接触，补偿模拟时才做形状 sweep，见同文件 `244-365`。当前速度 100/115 像素/秒不算高速，但若以后只提高速度而不调整连续碰撞策略，会增加穿越风险。
- volley 对象池化；联机为三颗球使用不同 `source_type` 位，确保独立碰撞去重，见同文件 `600-643`。

#### 寒冰术士

- 召唤后生成一枚对象池冰锥；冰锥对玩家/植物均造成法术伤害，但寒冷只作用于玩家，见 `scene/enemy/sorcerer/frost_sorcerer.gd:252-413`、`scene/enemy/sorcerer/frost_sorcerer_ice_spike.gd:195-240`。
- 每物理帧移动；只有位移超过 4 像素或进行网络补偿模拟时才做 sweep，常规低速路径依赖 Area 接触，见冰锥脚本 `135-179`。普通 100、精英 125 像素/秒时单帧位移远低于 4 像素，属于有意减少射线/形状查询的设计。

#### 雷电术士

- 前摇后从初始目标开始，逐跳调用运行时最近目标查询并用排除字典确保目标不重复；`max_chain_bounces=4` 意味着“首目标 + 4 跳 = 最多 5 个”，见 `scene/enemy/sorcerer/lightning_sorcerer.gd:350-465`、`resources/config/enemies/lightning_sorcerer_config.gd:8-17`。
- 每一跳都使用完整 50 法术伤害，没有衰减；一次攻击最多做 5 次有界最近目标查询。单体开销中等，在大量术士同步攻击时查询会形成可见尖峰。
- 联机用专门的链路点数组广播 VFX；目标警告因普通敌人动作通道是 `unreliable_ordered`，在前摇 0.2 秒后重发一次，见 `scene/enemy/sorcerer/lightning_sorcerer.gd:519-572`、`scene/multiplayer/mp_game.gd:8722-8728`。

### 4.5 石头人家族

- 石头人复用骑士状态机，但重新启用公共接触伤害；`_physics_process()` 只在存在接触或接触冷却尚未归零时调用接触更新，避免无接触时的空工作，见 `scene/enemy/artificial_creation/stone_golem.gd:69-84`。
- 砸地使用 `CompleteShapeQuery2D.intersect_shape_all()`、默认分页 64，并维护唯一目标表；不会出现骑士 16 结果截断，见同文件 `112-213`。
- 冲击视觉是场景内复用的 `Line2D`，在伤害帧激活，不为每次砸地生成临时节点；见同文件 `215-217,311-408`。
- 配置中的 `attack_damage` 同时驱动接触与砸地。普通石头人贴身持续接触的理论原始 DPS 为 200，精英为 300，另加每次范围砸地；如果平衡表把 100/150 当作“每轮技能伤害”，实际威胁会被低估。

### 4.6 铃兰 Boss

#### 主状态机

- 首轮固定按技能 1→2→3→4，每个技能后停 2 秒；之后从“可用且不与上一招相同”的技能中选使用次数最少者，平局随机，见 `scene/boss/linglan/linglan_boss.gd:13-19,264-374`。
- Boss 活跃时每物理帧仍更新公共接触伤害，再推进技能阶段；半血以下启动 10 秒一次的狙击手空投，预警 1.2 秒、下落 0.5 秒，见同文件 `180-205,377-405`。塔防宿主只在 Boss 阶段执行空投，见 `scene/game_tower_defense.gd:3404-3424`。
- 基础配置速度为 0，但技能 2/3/4 的移动阶段各用技能配置 `move_speed=120` 再乘有效移速倍率，因此减速仍有效；见 `scene/boss/linglan/linglan_boss.gd:728-749,1003-1024,1156-1181`。

#### 技能 1：樱花弹幕

- 配置：起手延迟 5 秒、20 个方向；射速参数 1800 经 `100/attack_speed` 转为 0.05556 秒一圈；固定方向 2 秒 + 每秒旋转 6°的 15 秒，共 17 秒；每弹 50、速度 300、寿命 2 秒，见 `resources/config/bosses/linglan_skill_config.gd:4-30`、`linglan_skill1.tres:7-12`。
- 静态数量推导：18 圈/秒 × 20 发 = 360 发/秒；17 秒约 306 圈，即约 6120 发；寿命 2 秒时稳态约 720 发同时存在。主循环用 `while` 补偿长帧，见 `scene/boss/linglan/linglan_boss.gd:445-503`。
- 优点：弹丸走会话对象池；一整圈通过 `register_local_linglan_skill1_ring()` 批量进入多人系统，避免 20 个独立注册 RPC，见同文件 `513-595`、`scene/multiplayer/mp_game.gd:4482-4555`。
- 风险：每颗弹丸仍独立 `_physics_process()`，每物理帧做世界射线；每圈也仍产生一次网络批事件。该技能是当前敌人系统最可能主导物理帧、Area2D 数量、射线次数和网络带宽的路径。

#### 技能 2：追踪火箭与召唤

- 移动到格 `(15,2)`；共 10 轮、间隔 1 秒。每轮立即在 `Spawn4`/`Spawn5` 各生成一只硬壳原石虫，并在 0.35 秒预警后发一枚火箭，因此一轮技能为 **20 只增援 + 10 枚火箭**，见 `resources/config/bosses/linglan_skill2_config.gd:5-26`、`linglan_skill2.tres:6-12`、`scene/boss/linglan/linglan_boss.gd:763-808,964-972`。
- 火箭速度 210、寿命 5 秒、转向率 1.2、伤害 80、爆炸半径 78；每物理帧射线，爆炸用完整分页形状查询，见 `scene/boss/linglan/linglan_skill2_sakura_rocket.gd:220-375`。Boss 正常路径只伤玩家；同脚本还支持 `enemies_only` 收藏品复用模式，耦合面较大。

#### 技能 3：成长光球

- 移动到格 `(0,1)`；持续 10 秒、每 0.2 秒一颗，共 50 颗。方向在 0°~90°随机；速度 90、伤害 50、半径由 15 扩到 45，随机 2.2~3.6 秒后膨胀并维持 0.5 秒，见 `resources/config/bosses/linglan_skill3_config.gd:5-30`、`scene/boss/linglan/linglan_boss.gd:1036-1093`。
- 每颗球仅对每个玩家伤害一次，以字典去重；膨胀时额外 `intersect_shape(query, 16)` 捕获已经位于新半径内的玩家，见 `scene/boss/linglan/linglan_skill3_light_orb.gd:101-190`。玩家数远少于 16 时上限合理，但它依然是硬编码容量。
- 技能 3 光球直接 `instantiate()`，没有会话对象池；峰值并发约 20 颗，风险中等。

#### 技能 4：收缩激光场与横向光球

- 激光预警 1.6 秒、收缩 3 秒，再延迟 0.5 秒开始光球；光球阶段 14 秒、每 2 秒一波，共 7 波。配置每侧取 7 行，因此一轮为 **7 波 × 14 颗 = 98 颗光球**，见 `resources/config/bosses/linglan_skill4_config.gd:9-46`、`linglan_skill4.tres:7-11`、`scene/boss/linglan/linglan_boss.gd:1194-1261`。
- 激光是单个场景内 `Area2D`，为每个重叠玩家维护独立 0.5 秒伤害冷却；每物理帧只迭代重叠玩家字典并更新几何，见 `scene/boss/linglan/linglan_skill4_laser_field.gd:58-170,277-346`。伤害固定为魔法。
- 名为“预警”的前 1.6 秒并没有关闭伤害碰撞：宿主创建字段时传入 `enable_damage=true`，`_ready/setup()` 随即启用 monitoring 和四条碰撞形状，只是把线宽缩到 `warning_core_width`；因此玩家碰到细预警线也会受伤。若“预警”按设计应当纯提示，这是一个明确的时序错误；若允许伤害，则命名和玩家预期需要澄清。证据见 `scene/boss/linglan/linglan_boss.gd:1184-1191,1290-1324`、`scene/boss/linglan/linglan_skill4_laser_field.gd:74-139,240-255`。
- 光球速度 40、寿命 10 秒、伤害 50、可视半径 8/伤害半径 6；每颗球是独立 Area 节点，直接实例化，无对象池，见 `scene/boss/linglan/linglan_skill4_light_orb.gd:7-79`。稳态最多约 70 颗在场，风险高于技能 3、远低于技能 1。

## 五、多人同步审计

### 5.1 权威模型

- 敌人 AI、目标、物理和攻击由宿主运行。客户端按配置路径实例化相同场景后调用 `configure_multiplayer_proxy()`，关闭物理/脚本处理和所有 Area 监测，仅保留本体碰撞层用于视觉/必要查询；见 `scene/multiplayer/mp_game.gd:9654-9697`、`scene/enemy/enemy.gd:796-825`。
- 宿主按敌人数选择普通/高压快照频率，将敌人状态分块编码并发给所有客户端；客户端只在完整批次到齐后对 roster 做回收，位置交给插值器，生命与视觉状态掩码直接同步，见 `scene/multiplayer/mp_game.gd:2890-2909,2969-3032,3668-3766`。
- 前摇、开火、斩击、锁定等离散动作走 `net_enemy_action` 或 `net_enemy_target_action`，客户端按 `action_id` 去重并可依据宿主时间补偿动画进度；见 `scene/multiplayer/mp_game.gd:8692-8719,10098-10212`。
- 玩家受伤使用 `(source_id, target_peer_id, source_type)` 组成去重键。客户端只在目标是本地玩家时先应用伤害并回报宿主，宿主玩家则直接由宿主应用；见 `scene/multiplayer/mp_game.gd:7076-7213`。
- 远程弹丸由宿主创建并通过 `register_local_projectile()` 注册；客户端生成视觉/本地接触副本，部分投射物另有“接触位消费”协议，防止同一三球/冰锥重复上报。铃兰技能 1 使用整圈批协议，雷术士使用专用链路点广播。

### 5.2 各家族同步方式

| 家族/攻击 | 宿主权威内容 | 客户端表现路径 | 风险 |
|---|---|---|---|
| 基础原石虫/史莱姆/翠壳接触 | 移动、目标、接触判定、状态类型 | 快照运动；本地玩家伤害回报 | 元素依赖 `source_type` 字符串分支 |
| 自爆原石虫 | 死亡与爆炸查询 | 终结同步 + 死亡/爆炸动画 | 当前爆炸目标层语义有误，联机并不会修正 |
| 守护者 | 宿主集中计算物防来源，敌人受伤仍宿主权威 | 只看快照生命/视觉状态 | 客户端不需要重建物防来源，结构正确 |
| AK/火弹/RPG/法师/火冰术士 | 攻击提交、伤害快照、投射物初态 | 专用 projectile type 重建并做接触协议 | `MPGame` 对具体场景与 source type 有大量显式分支 |
| 骑士/剑客/石头人 | 宿主范围查询与伤害 | generic action 重放前摇/攻击/冲击 | 查询上限问题会在宿主成为一致的“漏伤” |
| SMG | 宿主 hitscan 与每枪动作 | 每枪枪口动作；本地玩家命中回报 | 10 发/秒/单位的动作广播量 |
| 狙击手 | 宿主锁定与最终直伤 | target action 绑定目标玩家、generic action 播放射击 | 目标植物与玩家使用两类动作接口，耦合高 |
| 雷术士 | 宿主决定完整链与伤害 | 专用点数组 VFX + 目标警告重发 | 独立协议，难复用但结果确定 |
| 铃兰 | 宿主技能状态、召唤、伤害 | 通用动作 + 4 类专用弹丸/激光视觉；技能 1 整圈批同步 | 协议面最大，技能 1 带宽/节点量极高 |

### 5.3 网络耦合点

敌人脚本普遍通过 `get_tree().current_scene.has_method(...)` 调用 `broadcast_enemy_action`、`register_local_projectile`、`request_multiplayer_player_damage`、Boss 目标格/召唤接口。这样能兼容单机和轻量测试场景，但本质上是动态服务定位器：接口参数改变无法由静态类型检查捕获，且 source type 的字符串必须在敌人脚本、弹丸脚本和 `MPGame` 三处保持一致。代表证据：`scene/enemy/enemy.gd:3706-3715`、`scene/enemy/capoo/capoo_ak47.gd:464-476`、`scene/boss/linglan/linglan_boss.gd:1473-1495`。

## 六、性能热点与评级依据

### 6.1 已有的良好规模化结构

1. **导航错峰与认证直行**：默认 10 Hz 导航、20 Hz 战斗感知、远目标 7.5 Hz；直线路径被完整扫掠认证后直接改 transform，障碍时才落回 `move_and_slide()`，见 `scene/enemy/enemy.gd:57-83,3222-3301,3416-3468`。
2. **LOS 缓存**：远程视线按 6 帧错峰，移动 8 像素/目标变化/地图代际变化才提前失效，见 `scene/enemy/enemy.gd:658-718`。
3. **事件驱动接触和状态**：没有接触时接触更新立即退出；慢速视觉按需要启停 `_process()`；DoT/寒冷均为集中调度，见 `scene/enemy/enemy.gd:474-505,1176-1227,1627-1845,3623-3675`。
4. **空间索引与完整范围查询**：敌人空间桶按跨桶事件更新；守护光环使用索引；自爆、RPG、法师火球、石头人砸地使用分页完整查询，避免密集场景静默截断。
5. **投射物池与 AK 批移动**：常规高频弹丸均有会话对象池；AK 进一步合并脚本物理循环。视觉特效中法师命中特效也走池和视口裁剪。

### 6.2 按优先级的风险清单

| 优先级 | 风险 | 证据与影响 | 建议方向 |
|---|---|---|---|
| P0 | 铃兰技能 1 约 720 同时在途 Area/脚本，约 6120 发/技能 | `linglan_skill1.tres:9` + `get_fire_interval()` + 17 秒总时长；每弹每帧射线 | 首先实测物理帧/射线/网络包；考虑批量弹幕模拟或降低方向×频率乘积，而不是只扩大对象池 |
| P1 | 翠壳只跟踪一个光环玩家 | `yuanshi_insect_aura.gd:262-317` | 改为按玩家 id 集合及每玩家冷却；复用激光场已有的数据结构模式 |
| P1 | 自爆层掩码/目标类型与塔防语义冲突 | bomber 场景掩码 6；脚本只处理 Player/Enemy | 明确设计后统一为玩家+植物或保留友伤；两类目标都使用同一伤害快照 |
| P1 | 骑士/剑客斩击固定最多 16 个原始碰撞结果 | `capoo_knight.gd:223-253` | 复用 `CompleteShapeQuery2D` 或直接用扇形候选索引，避免筛选前截断 |
| P1 | 火焰弹原石虫实际物理且无燃烧 | `yuanshi_insect_fire_projectile.gd:121-143` | 将元素语义数据化，或更名/写清楚“火焰仅视觉” |
| P1 | 铃兰技能 4 的“预警线”从出现起就有伤害碰撞 | `linglan_skill4_laser_field.gd:74-139` | 若预警应无伤，分开 visual/warning 与 damage-enabled 阶段；若有伤则重新命名并明确反馈 |
| P1 | SMG 每单位每秒最多 10 个动作同步 | `capoo_smg_config.gd:6`、`capoo_smg.gd:297-336` | 压测多 SMG 网络；可按短窗口批量化枪口事件/只同步随机种子和开始结束状态 |
| P2 | RPG 爆炸、狙击标记、Boss 技能 2 火箭及技能 3/4 光球直接实例化 | 对应脚本的 `instantiate()` 路径 | 高频或 Boss 重复技能时纳入对象池，先以遥测确认分配尖峰 |
| P2 | 火/冰/雷目标查询与状态机重复 | 三份脚本各自维护 0.35 秒缓存和运行时查找 | 抽取有类型的术士远程基类/组件，防止未来修复只落一份 |
| P2 | 不同弹丸采用不同连续碰撞策略 | AK 两帧射线补验；RPG/法师逐帧射线；冰锥阈值 sweep；火三球主要 Area | 建立按“速度×半径×物理步长”选策略的统一投射物碰撞规范 |
| P2 | 动态 `current_scene.has_method` 服务接口 | 广泛存在于敌人、弹丸、Boss | 引入明确的运行时接口/注册服务，至少集中 source type 与参数定义 |

## 七、尚未统一的设计与代码语义

1. **攻击力字段语义不统一**：接触、单发、三球中的每球、连锁每跳、范围砸地都读取 `attack_damage`。建议把配置层拆成 `touch_damage` 与技能伤害，或明确所有表格均展示“单命中伤害”。
2. **伤害类型位置不统一**：部分由配置控制（石头人 `slam_damage_type`），部分由敌人覆写（法师/术士/元素史莱姆），部分硬编码在弹丸（火弹物理、RPG 物理、法师火球魔法）。这使换皮/精英变体无法只靠资源安全改元素类型。
3. **攻击冷却起点不统一**：有的在提交攻击时开始，有的在开火或完整动作结束后开始；配置中的“间隔”无法直接横向比较实际周期。
4. **战斗感知节流不统一**：AK、骑士、火弹原石虫显式使用 20 Hz；RPG、法师、狙击和术士主分支仍每物理帧进入判断，虽由 LOS/目标缓存降低昂贵查询，却有不同的 CPU 模型。
5. **范围查询完整性不统一**：石头人/RPG/法师/自爆用分页完整查询；骑士固定 16；Boss 技能 3 也固定 16。当前玩家数量使 Boss 技能 3 基本安全，但 API 习惯不一致。
6. **投射物生命周期不统一**：常规敌人高频弹丸大多池化；Boss 技能 3/4 光球与部分爆炸/锁定视觉直接实例化；同类压力下 GC/分配表现差异较大。
7. **目标能力不统一**：AK、RPG、火弹原石虫显式允许水上植物目标；其他远程单位依赖公共默认。此能力散落在脚本覆写而非配置数据。
8. **Boss 基础移速与技能移速分离**：铃兰 `EnemyConfig.move_speed=0`，技能配置各自保存 120；减速通过倍率仍能作用，但通用敌人数据面板无法展示 Boss 实际移动能力。
9. **奖励/掉落隐式默认**：低阶原石虫、史莱姆以及铃兰省略 Home/奖励/掉落字段时继承默认值。铃兰因此会造成默认 1 点 Home 伤害并参与普通材料掉落表；需要确认是否是明确设计。
10. **联机 source type 分散**：元素状态、三火球独立消费、冰锥消费、Boss 弹丸都由字符串分支驱动。新增敌人时很容易出现“本地正确、联机类型/状态错误”。
11. **基础原石虫缺少展示名**：`yuanshi_insect_basic.tres` 是 28 个配置中唯一未赋值 `display_name` 的资源，会继承 `EnemyConfig` 的默认“敌人”；若该字段进入波次 UI、图鉴或日志，将显示为泛称。见 `resources/config/enemies/yuanshi_insect_basic.tres:7-14`、`resources/config/enemies/enemy_config.gd:15-21`。

## 八、逐敌人场景/脚本映射

| 配置族 | 主场景与脚本 | 共享/专属附属场景 |
|---|---|---|
| 原石虫基础/快/壳 | `scene/enemy/yuanshi_insect/yuanshi_insect*.tscn` → `yuanshi_insect.gd` | 公共 `enemy.tscn` |
| 自爆/紫晶自爆 | 对应 bomber 场景 → `yuanshi_insect_exploder.gd` | 场景内 `ExplosionArea` 与爆炸动画 |
| 翠壳/守护者 | 对应 aura 场景 → `yuanshi_insect_aura.gd` | `guardian_aura_system.tscn/.gd` 仅守护者集中增益 |
| 火弹原石虫 | `yuanshi_insect_fire_ranged.tscn/.gd` | `yuanshi_insect_fire_projectile.tscn/.gd` |
| 四种史莱姆 | 变体场景继承 `slime.tscn` → `slime.gd` → `YuanshiInsect` | 无独立弹丸 |
| AK | `capoo_ak47.tscn/.gd` | `capoo_ak47_bullet.tscn/.gd`、`capoo_projectile_motion_system.tscn/.gd` |
| 骑士/精英/剑客 | 各场景 → `capoo_knight.gd`；剑客为其空子类 | 两种 slash effect 场景 |
| SMG | `capoo_smg.tscn/.gd` | 保留 legacy bullet 资源，生产攻击为 hitscan |
| RPG | `capoo_rpg.tscn/.gd` | `capoo_rpg_rocket.tscn/.gd`、`capoo_rpg_explosion.tscn/.gd` |
| 法师 | `capoo_mage.tscn/.gd` | `capoo_mage_fireball.tscn/.gd`、impact 场景 |
| 狙击手 | `capoo_sniper.tscn/.gd` | lock reticle 场景与 visual coordinator |
| 火术士/精英 | 各主场景 → `fire_sorcerer.gd` | 普通/精英三球 volley 场景，共用 volley 脚本 |
| 冰术士/精英 | 各主场景 → `frost_sorcerer.gd` | 共享 `frost_sorcerer_ice_spike.tscn/.gd` |
| 雷术士 | `lightning_sorcerer.tscn/.gd` | lightning VFX、target warning 场景 |
| 石头人/精英 | 各场景 → `stone_golem.gd` / 空精英子类 | 场景内预警多边形和复用冲击 Line2D |
| 铃兰 | `scene/boss/linglan/linglan_boss.tscn/.gd` | 技能 1 弹/预警线、技能 2 火箭/爆炸/箭头、技能 3 光球、技能 4 激光场/光球、空投预警、Boss HUD/入场特效 |

## 九、审计边界

- 本文覆盖当前源码中所有 `resources/config/enemies/*.tres` 的敌人配置；`default_enemy_drop_table.tres` 是掉落资源，不计作敌人。
- 敌人由关卡/波次在何时、以多少数量组合生成，属于流程与关卡审计；这里只追踪了敌人自身及铃兰技能直接生成的增援。
- 性能级别是源码结构推导，不替代实际 60 Hz profiler、物理查询计数、对象池命中率、快照字节和 RPC 频率数据。尤其铃兰技能 1、SMG 群、术士群应在综合性能报告中用真实场景复核。
