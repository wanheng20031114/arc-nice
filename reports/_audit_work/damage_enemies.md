# 敌人、投射物与敌方攻击伤害域深度审计

> 审计日期：2026-07-26
> 范围：敌方攻击提交、投射物/范围命中、玩家/植物/敌人/基地承伤、状态伤害、重复结算、联机命中、死亡与击杀副作用。
> 方法：静态追踪当前源码和资源配置；未启动 Godot，未修改业务代码。

> **时点说明**：本报告主体记录的是本轮统一伤害改造开始时的基线。审计进行期间，共享工作树并行新增了 `scene/combat/`，并把玩家、植物、敌人的数值解析接到 `DamageRequest` / `DamageResolver` / `DamageResult`。为避免把迁移前问题误写成迁移后现状，文末“十三、并行迁移即时对照”单独列出已经落地与仍未迁移的部分；前十二节仍保留为调用点清单、兼容性基线和回归依据。

## 一、结论摘要

当前工程没有一个统一的“伤害事件 → 规则解析 → 结算结果”入口，而是四套承伤端点：

1. 玩家：`Player.apply_damage()` / `apply_periodic_damage()`；
2. 植物：`PlantDefense.receive_damage()`；
3. 敌人：`Enemy.apply_damage()` / `apply_damage_batch()`；
4. 基地：`GameTowerDefense._apply_base_damage()`。

它们共享“物理点数减伤、魔法百分比减伤、正伤害至少 1 点”的大体语义，但在闪避、无敌帧、方向修正、额外减伤、承伤倍率、批伤、表现、联机权威和死亡归属上各自实现。伤害类型本身也定义在 `EnemyConfig` 内，却被玩家、植物、基地流程和联机协议共同依赖，见 `resources/config/enemies/enemy_config.gd:10-13`。

最关键风险如下：

| 优先级 | 风险 | 直接影响 |
|---|---|---|
| P1 | 玩家所有普通直伤共享 1 秒全局无敌帧 | AK 十连发、SMG 10 发/秒、火术士三球、铃兰弹幕与 0.5 秒激光对玩家的有效 DPS 被全局节流；植物没有无敌帧，会吃满全部段数。平衡表中的“每发伤害 × 发数”不能代表玩家实际承伤。证据：`scene/player/player.gd:17,730-775,4438-4440`。 |
| P1 | 联机玩家受伤协议可采用受击客户端上报的生命结果 | Host 校验 sender、去重和少数投射物 token，但普通来源不从攻击记录、命中几何和玩家防御重新计算；只在客户端检测的命中可以被少报或不报。证据：`scene/multiplayer/mp_game.gd:7332-7554`。 |
| P1 | 自爆原石虫的目标层和减攻语义不一致 | 爆炸掩码为玩家层 + 敌人层，不伤植物却会伤友军；玩家吃减攻快照，敌人吃原始伤害。友军死亡还会触发奖励、掉落、波次结算和可能的连锁自爆。证据：`scene/enemy/yuanshi_insect/yuanshi_insect_bomber.tscn:76-82`、`scene/enemy/yuanshi_insect/yuanshi_insect_exploder.gd:97-161`。 |
| P1 | 击杀归属不在伤害/死亡事件中 | 敌人死亡无论来源都给全队息壤并投掉落；玩家收藏品击杀效果则只由“某次玩家命中之后”的调用点触发。DoT、植物、友伤、自爆造成的死亡没有统一 killer/cause。证据：`scene/enemy/enemy.gd:3781-3828`、`scene/game_runtime_base.gd:914-920,971-984`、`scene/player/player.gd:2749-2764`。 |
| P1 | 元素/状态协议重复硬编码 | 火术士燃烧、火史莱姆燃烧及冰系 source type、时长、等级在敌人配置/脚本和 `MPGame` 中分别维护；资源数值改动可能让联机 DoT 校验拒绝合法跳伤。证据：`scene/multiplayer/mp_game.gd:136-152,5570-5623,7234-7276`。 |
| P2 | `request_multiplayer_player_damage()` 使用 `Variant` 重载参数 | 第 5/6 参数可分别解释为伤害类型、方向或 ranged 布尔，编译期无法发现错位；铃兰技能 2 等调用只传方向，未来若改成魔法伤害，联机路径仍会默认物理。证据：`scene/multiplayer/mp_game.gd:7076-7100`、`scene/boss/linglan/linglan_skill2_sakura_rocket.gd:402-415`。 |
| P2 | 攻击类型、状态和返回值语义分散 | `bool` 有时表示“实际扣血”，有时表示“请求已处理/已去重/目标不归本端”，投射物据此销毁；状态附加又依赖调用点是否理解这一差异。 |

源码中不存在敌方攻击暴击、暴击倍率、护甲/魔抗穿透或防御忽略。搜索到的“穿透”是玩家普通子弹穿过多个敌人的投射物行为，不是防御穿透。敌方攻击的随机性来自玩家闪避、枪械散布或目标选择，而不是暴击。

## 二、完整伤害调用链

### 2.1 单机/Host 本地目标

典型调用链是：

```text
敌人攻击状态机
  → get_effective_attack_damage(base_damage) 计算/快照减攻后的原始伤害
  → Area2D / ray / shape query / hitscan 判定命中
  → Player.apply_damage 或 PlantDefense.receive_damage
  → 防御、闪避/无敌、额外减伤
  → 扣生命、伤害数字/音效/信号
  → _die / _begin_death
```

攻击力减益的公共入口是 `Enemy.get_effective_attack_damage()`：多个减攻来源只取最低倍率，最终用 `roundi(base × multiplier)` 且至少 1。弹丸通常在发射时固化这个值，接触、光环、斩击和砸地则在每次结算时读取，见 `scene/enemy/enemy.gd:1114-1174,3685-3686`。紫阳花雨幕以状态方式写入 `outgoing_attack_damage_multiplier`，默认倍率 0.8，见 `scene/plant_defense/hydrangea_rain_tower.gd:537-573`、`resources/config/plant_defense/hydrangea_rain_tower_config.gd:17`。

因此同一减攻状态的时序语义并不完全相同：

- 已发射的弹丸在飞行途中减攻开始/结束，不改变它的伤害；
- 接触、光环、斩击、连锁和砸地按命中时状态计算；
- 自爆原石虫在死亡入口快照，等死亡动画结束后才结算爆炸；
- 铃兰激光场在字段生成时取得一次伤害值，整个字段沿用该快照。

### 2.2 联机玩家目标

敌方脚本普遍通过 `get_tree().current_scene.has_method("request_multiplayer_player_damage")` 动态寻找联机入口；不存在时直接调用玩家。代表调用点：

- 公共接触：`scene/enemy/enemy.gd:3706-3723`；
- 骑士/石头人/自爆/光环公共 helper：`scene/enemy/yuanshi_insect/yuanshi_insect.gd:53-76`、`scene/enemy/capoo/capoo_knight.gd:386-404`；
- 投射物：`scene/enemy/capoo/capoo_ak47_bullet.gd:416-435`、`capoo_rpg_rocket.gd:271-298`、`capoo_mage_fireball.gd:339-367`；
- Boss：`scene/boss/linglan/linglan_skill1_sakura_bullet.gd:246-266`、`linglan_skill2_sakura_rocket.gd:398-422`、`linglan_skill3_light_orb.gd:195-214`、`linglan_skill4_light_orb.gd:125-143`、`linglan_skill4_laser_field.gd:328-347`。

`MPGame.request_multiplayer_player_damage()` 将伤害类型、来源方向、远程标志组装成 `damage_context`，再调用 `Player.apply_damage()`。普通去重键为 `(source_id, target_peer_id, source_type)`；三火球的每一球和冰锥故意去掉 target，使一个投射物接触位全局只消费一次，缓存保留 30 秒，见 `scene/multiplayer/mp_game.gd:114,5700-5710,6150-6191,7076-7213`。

### 2.3 植物和敌人目标

植物承伤只在 Host/单机执行，`damage_applied` 和生命 revision 再由塔防运行时复制；客户端 proxy 会在入口立即拒绝，见 `scene/plant_defense/plant_defense.gd:142-157`、`scene/game_tower_defense.gd:960-973,1571-1609`。

敌人承伤由 Host 权威；普通玩家投射物报告会先校验 projectile owner/record、从 Host 记录重建伤害、以 `(projectile_id, enemy_id)` 去重，再进入敌人承伤入口，见 `scene/multiplayer/mp_game.gd:6259-6352`。这比玩家受伤协议更接近统一的权威伤害链，但仍缺少命中几何验证。

## 三、所有承伤入口与精确顺序

### 3.1 玩家普通直伤

入口：`scene/player/player.gd:730-775`。

顺序严格为：

1. 重置 `last_damage_taken`；死亡或非正伤害拒绝；
2. 冲刺无敌或全局受击无敌拒绝；
3. 通用闪避随机判定；成功后仍开启 1 秒全局无敌；
4. 仅远程攻击的收藏品闪避；成功后同样开启全局无敌；
5. 若 `damage_context.is_ranged`，按面对来源的前/后方向倍率修正原始伤害；
6. 按物理/魔法防御减伤；
7. 取所有 `damage_reduction_modifiers` 中最强的一项，最多 95% 额外减伤；
8. 扣血、伤害数字、生命信号、刷新生命阈值收藏品；
9. 死亡则 `_die()`；否则触发受伤收藏品效果，并开启默认 1 秒全局无敌。

公式：

- 物理：`max(amount - max(physical_defense, 0), 1)`；
- 魔法：`max(floor(amount × (100 - clamp(magic_defense, 0, 100)) / 100), 1)`；
- 再额外减伤：`max(floor(防御后伤害 × (1 - clamp(最强减伤, 0, 0.95))), 1)`。

证据：`scene/player/player.gd:1034-1079,1136-1154,1280-1287,2295-2424`。

`source_direction` 的约定是“从玩家指向伤害来源”，伤害数字的冲击方向再取反。这个约定只存在于 Dictionary 字段和各调用点，没有类型约束，见 `scene/player/player.gd:1063-1079`。

### 3.2 玩家周期伤害

入口：`scene/player/player.gd:781-807`。

它故意绕过：冲刺/受击无敌、通用闪避、远程闪避、方向倍率，也不会授予普通受击无敌；但仍使用物理/魔法防御和最强额外减伤，并触发受伤收藏品效果。燃烧/流血回调最终进入这里，见 `scene/player/player.gd:981-1030`。

这意味着“同一个数值的直伤”和“同一个数值的 DoT”在玩家端具有不同的命中许可策略，而现有参数中没有明确的 `hit_policy` 字段。

### 3.3 植物

入口：`scene/plant_defense/plant_defense.gd:142-157`。

- proxy、死亡、移除中、非正伤害拒绝；
- 物理：`max(amount - (physical_defense + global_physical_defense_bonus), 1)`；
- 魔法：`max(floor(amount × (100 - clamp(magic_defense, 0, 100)) / 100), 1)`；
- 没有闪避、无敌帧、方向倍率或通用伤害减免；
- 每次攻击都完整结算，燃烧/流血跳伤也重新走相同防御公式，见 `scene/plant_defense/plant_defense.gd:388-409,458-467,604-617`。

另有 `receive_unmitigated_damage()`，绕过双防但保留生命 revision、信号和死亡生命周期；当前用于环境/地形规则，不是敌方攻击入口，见 `scene/plant_defense/plant_defense.gd:412-427`。

同一帧的植物物理/魔法伤害数字会分别累积后合成一个总数，并采用数值更大的伤害类型/方向显示；混合伤害因此不会逐类型展示，见 `scene/plant_defense/plant_defense.gd:621-702`。

### 3.4 敌人

单次入口：`scene/enemy/enemy.gd:894-917`；批量入口：`scene/enemy/enemy.gd:920-988`。

- 物理：`max(amount - effective_physical_defense, 1)`；
- 魔法：`max(floor(amount × (100 - effective_magic_defense) / 100), 1)`；
- 之后乘所有承伤倍率的乘积，并以 `roundi` 取整、至少 1；
- 物防修正按点数相加，魔防只读配置并钳制 0~100，承伤倍率按来源相乘，见 `scene/enemy/enemy.gd:1041-1111,1613-1624`。

`apply_damage_batch()` 对每一组先按“单次命中”减伤，再乘命中次数，并把致死聚合钳制到当前生命；这保持了多段物理防御语义，避免先合并原始伤害导致只减一次物防，见 `scene/enemy/enemy.gd:937-987`。但一个 batch 只能携带一个伤害类型，无法表达混合物理/魔法批次。

### 3.5 基地/Home

敌人进入 Home 后，以实例 ID 集合防重复，读取 `config.home_damage`，移除敌人并调用 `_apply_base_damage()`；基地直接做整数减法，没有伤害类型、防御、减攻、来源归属或伤害结果对象，见 `scene/game_tower_defense.gd:763-829`。

这是敌人造成的第五种玩法结果，但没有复用任何 Combat API。若未来要支持基地护甲、屏障、来源统计或“减攻也降低撞门伤害”，必须单独补逻辑。

## 四、伤害类型、暴击、穿透、减伤与状态

### 4.1 类型与取整

全工程共享的玩法伤害类型只有：

```gdscript
EnemyConfig.DamageType.PHYSICAL
EnemyConfig.DamageType.MAGIC
```

证据：`resources/config/enemies/enemy_config.gd:10-13`。

未发现敌方攻击暴击率、暴击伤害、护甲穿透、魔抗穿透或防御忽略。所有承伤端点对正伤害都设置至少 1 点，因此：100 魔防、极高物防、100% 敌人承伤倍率减免或玩家 95% 额外减伤都不能形成真正免疫。

伤害取整并不完全统一：

- 魔防阶段统一 `floori`；
- 玩家额外减伤再 `floori`；
- 敌人承伤倍率使用 `roundi`；
- 敌人对外减攻快照使用 `roundi`；
- 玩家远程方向倍率使用 `roundi`。

统一解析器需要明确每一层的取整边界，否则把乘法重排会改变低数值伤害。

### 4.2 敌人减攻

多个 `outgoing_attack_damage_multiplier` 来源只取最低倍率，不相乘；默认紫阳花为 0.8。此规则本身清晰，问题是所有攻击必须主动在提交点调用 `get_effective_attack_damage()`。当前主要攻击已这样做，调用枚举见 `scene/enemy/enemy.gd:3686`、`scene/enemy/capoo/*.gd`、`scene/enemy/sorcerer/*.gd`、`scene/enemy/artificial_creation/stone_golem.gd:146`、`scene/boss/linglan/linglan_boss.gd:491,891,1067,1249,1306`。

例外是自爆伤害敌人时绕回了 `config.explosion_damage`，跳过快照，见 `scene/enemy/yuanshi_insect/yuanshi_insect_exploder.gd:149-161`。

### 4.3 燃烧、流血和寒冷

玩家和植物共用集中式周期伤害调度器：

- 燃烧固定 1 秒一跳；所有来源族只让当前最强 tick 来源推进和造成伤害，见 `scene/burn_status_scheduler.gd:3-22`；
- 流血默认 0.5 秒一跳，各来源族全部独立跳伤，见 `scene/bleed_status_scheduler.gd:3-24`；
- 同来源再次命中会完整刷新持续时间和首跳倒计时，见 `scene/periodic_damage_status_scheduler.gd:172-193`；
- 到期和跳伤同刻时到期优先，因此持续 5 秒、1 秒间隔的状态只在 1/2/3/4 秒跳 4 次，不在第 5 秒再跳，见 `scene/periodic_damage_status_scheduler.gd:546-587`。

敌人也支持 burn/bleed，但使用自身 `EnemyCollectibleStatusScheduler` deadline 链；同样先处理精确到期，再处理该时刻跳伤，见 `scene/enemy/enemy.gd:1409-1468,1627-1845`。

当前敌方状态来源：

| 来源 | 直伤 | 附加状态 |
|---|---|---|
| 火焰史莱姆接触 | 魔法 10 | 直伤实际接受后，燃烧 3 秒、10/跳；按到期优先实际最多 2 跳。玩家/植物都可燃烧。`scene/enemy/slime/slime.gd:4-50` |
| 寒冰史莱姆接触 | 魔法 10 | 直伤接受后仅玩家叠寒冷；植物无寒冷运行时。`scene/enemy/slime/slime.gd:53-58` |
| 火焰术士三球 | 每球魔法 40，精英 70 | 该球直伤实际接受后，燃烧 5 秒；普通 5/跳、精英 10/跳，按到期优先为 4 跳。玩家/植物均可燃烧。`scene/enemy/sorcerer/fire_sorcerer_fireball_volley.gd:427-482` |
| 冰霜术士冰锥 | 魔法 50，精英 80 | 仅玩家叠寒冷。`scene/enemy/sorcerer/frost_sorcerer_ice_spike.gd:195-240` |
| “火焰弹原石虫”弹丸 | 物理 25 | 不附加燃烧；名称/视觉与玩法不一致。`scene/enemy/yuanshi_insect/yuanshi_insect_fire_projectile.gd:121-143` |

玩家寒冷和敌人寒冷最多 4 层，属于移速状态，不直接改伤害；玩家见 `scene/player/player.gd:935-978`，敌人见 `scene/enemy/enemy.gd:1176-1227`。

### 4.4 联机状态注册表漂移

`MPGame` 再次硬编码：火术士燃烧 5 秒、普通等级 5、精英 10；火史莱姆 3 秒、等级 10；并以 source type 字符串把三颗球映射回普通/精英家族，见 `scene/multiplayer/mp_game.gd:136-152,5570-5623`。

Host 对玩家燃烧跳伤要求 `tick_damage == trusted_burn_level`，否则拒绝，见 `scene/multiplayer/mp_game.gd:7234-7276`。因此只改 `.tres` 或敌人脚本数值、不改联机常量，会出现单机正确、联机状态被拒的静默漂移。

## 五、敌方伤害来源完整枚举

### 5.1 公共接触与 Home

公共接触入口位于 `scene/enemy/enemy.gd:3543-3724`，默认 0.5 秒一次；进入 Area 时立即尝试。它维护一个全局冷却和当前选中目标，植物优先于玩家，不是按目标独立冷却。

| 伤害来源 | 当前原始数值 | 类型与目标 | 结算备注 |
|---|---|---|---|
| 基础/迅捷/硬壳/自爆/紫晶自爆/翠壳/守护者原石虫接触 | 10 / 10 / 14 / 10 / 10 / 20 / 10 | 物理；玩家或植物 | 共同走 0.5 秒接触；配置见 `resources/config/enemies/yuanshi_insect_*.tres`。 |
| 火焰弹原石虫接触 | 25 | 物理；玩家或植物 | 它除远程弹丸外仍更新公共接触。`scene/enemy/yuanshi_insect/yuanshi_insect_fire_ranged.gd:34-57` |
| 普通/黄金史莱姆接触 | 10 / 50 | 物理；玩家或植物 | 无附加状态。 |
| 火焰/寒冰史莱姆接触 | 10 / 10 | 魔法；玩家或植物 | 成功直伤后按上节附加状态。`scene/enemy/slime/slime.gd:10-58` |
| AK / RPG / SMG / 狙击 Capoo 接触 | 20 / 20 / 30 / 200 | 物理；玩家或植物 | 远程单位仍会在贴身时运行公共接触。 |
| 法师 Capoo 接触 | 35 | 魔法；玩家或植物 | `scene/enemy/capoo/capoo_mage.gd:32-41` |
| 骑士/精英骑士/剑客接触 | 无 | — | 该家族覆写并禁用继承接触，只使用扇形斩击。`scene/enemy/capoo/capoo_knight.gd:437-444` |
| 火/精英火、冰/精英冰、雷术士接触 | 40 / 70 / 50 / 80 / 50 | 魔法；玩家或植物 | 三个术士脚本覆写 `_get_touch_damage_type()`。 |
| 石头人/精英石头人接触 | 100 / 150 | 物理；玩家或植物 | 重新启用骑士家族禁掉的公共接触，同时还有砸地。`scene/enemy/artificial_creation/stone_golem.gd:69-84` |
| 铃兰接触 | 20 | 物理；玩家或植物 | Boss 活跃时持续更新公共接触。`scene/boss/linglan/linglan_boss.gd:180-205` |
| 敌人进入 Home | 各配置 `home_damage`，默认 1；石头人 25 等 | 基地原始整数伤害 | 不经过减攻或任一承伤器；以敌人实例 ID 防重复。`scene/game_tower_defense.gd:763-829` |

由于玩家接触直伤会授予 1 秒全局无敌，而接触尝试每 0.5 秒一次，同一敌人通常表现为“命中一次、下一次被无敌拒绝、约 1 秒后再命中”。多个敌人同时贴身时还会互相争用这一个全局无敌窗口。植物则会稳定吃到 2 次/秒。

### 5.2 原石虫专属攻击

| 来源 | 数值/频率 | 类型、目标、ranged | 命中与重复规则 | 证据 |
|---|---|---|---|---|
| 翠壳伤害光环 | 20；进入立即一次，之后每 1 秒 | 物理；仅玩家；非 ranged | 单字段 `aura_touched_player` + 单冷却；多人同时进入会覆盖/丢目标 | `scene/enemy/yuanshi_insect/yuanshi_insect_aura.gd:262-317` |
| 自爆/紫晶自爆 | 死亡后 30；半径 30/40 | 默认物理；当前玩家 + 敌人；非 ranged | 完整分页 shape query，单次 `explosion_damage_done`，按 collider ID 去重 | `scene/enemy/yuanshi_insect/yuanshi_insect_exploder.gd:34-161` |
| 火焰弹 | 25；约 1.35 秒一发 | 实际物理；玩家/植物；ranged | 每物理帧世界射线 + Area 接触；单投射物消耗 | `scene/enemy/yuanshi_insect/yuanshi_insect_fire_ranged.gd:83-220`、`yuanshi_insect_fire_projectile.gd:97-182` |

自爆有额外时序：`_die()` 先快照减攻、调用公共死亡，公共死亡立即发奖励/掉落/`defeated`；死亡动画结束后才产生爆炸伤害，见 `scene/enemy/yuanshi_insect/yuanshi_insect_exploder.gd:34-94`。因此波次已把该敌人计作解决后，仍可能发生友军死亡、奖励和连锁自爆。

### 5.3 Capoo 攻击

| 来源 | 当前伤害与节奏 | 类型/目标/ranged | 命中与重复规则 | 证据 |
|---|---|---|---|---|
| AK 十连发 | 每发 20；10 发、间隔 0.08 秒 | 物理；玩家/植物；ranged | 每颗独立 `has_hit`/池状态；两物理帧世界射线补验 + Area；命中即消费 | `scene/enemy/capoo/capoo_ak47.gd:294-353`、`capoo_ak47_bullet.gd:173-299,320-435` |
| 骑士/精英/剑客斩击 | 28 / 28 / 24；各自 4/2/3 秒攻击间隔 | 物理；玩家/植物；非 ranged | 每次斩击按 instance ID 去重；但 `intersect_shape(query, 16)` 在距离/扇角筛选前截断，密集场景会漏合法目标 | `scene/enemy/capoo/capoo_knight.gd:215-268` |
| SMG hitscan | 每枪 30；0.1 秒一枪 | 物理；玩家/植物；ranged | 生产路径为 hitscan，每枪拥有动作序列 source ID；无投射物持续接触 | `scene/enemy/capoo/capoo_smg.gd:297-369` |
| RPG 火箭 | 20；半径 44；约 6 秒一发 | 物理；玩家/植物；ranged | 每帧世界射线；爆炸完整分页查询；`explosion_damaged_bodies` 保证单次爆炸每实体一次 | `scene/enemy/capoo/capoo_rpg_rocket.gd:152-248,271-298` |
| 法师追踪火球 | 35；半径 10.5；约 4 秒一发 | 魔法；玩家/植物；ranged | 追踪 + 每帧射线；完整分页 AoE；每次爆炸按 collider 去重 | `scene/enemy/capoo/capoo_mage_fireball.gd:172-297,339-367` |
| 狙击 | 200；锁定 3 秒、约 4.5 秒间隔 | 物理；玩家/植物；ranged | 锁定结束经精确 LOS 后直接结算一次，没有飞行投射物 | `scene/enemy/capoo/capoo_sniper.gd:206-265` |

玩家与植物的多段差异尤其明显：

- AK 的 10 发发生在约 0.72 秒内，玩家第一发成功后其余通常被 1 秒无敌拒绝；植物可承受全部 10 发；
- SMG 理论发射 10 发/秒，玩家通常约每秒仅接受一发，植物接受全部命中；
- 这些被无敌拒绝的弹丸仍会被自身命中逻辑消费，不会等待无敌结束后重复伤害。

### 5.4 术士与人造物

| 来源 | 当前伤害与节奏 | 类型/目标/ranged | 命中与重复规则 | 证据 |
|---|---|---|---|---|
| 火术士三球 | 普通每球 40、精英每球 70；一次 3 球 | 魔法；玩家/植物；ranged；成功后燃烧 | A/B/C 各有独立 source bit，单球只消费一次；不是 AoE | `scene/enemy/sorcerer/fire_sorcerer_fireball_volley.gd:427-486,600-657` |
| 冰术士冰锥 | 普通 50、精英 80 | 魔法；玩家/植物；ranged；玩家成功后寒冷 | 联机有单 contact token；命中后投射物消费 | `scene/enemy/sorcerer/frost_sorcerer_ice_spike.gd:195-281` |
| 雷术士连锁 | 每个目标完整 50；首目标 + 最多 4 跳，即最多 5 个不同目标 | 魔法；玩家/植物；ranged | `excluded_target_ids` 保证同一次链不重复目标；每跳重新选附近对象 | `scene/enemy/sorcerer/lightning_sorcerer.gd:350-465` |
| 石头人/精英砸地 | 100 / 150；半径 44、360° | 配置默认物理；玩家/植物；非 ranged | 完整分页 shape query，每次动作按目标 ID 去重 | `scene/enemy/artificial_creation/stone_golem.gd:112-183` |

火术士三球对植物可形成 3 倍直伤并各自尝试刷新同一燃烧家族；对玩家通常只有第一颗实际扣血和加燃烧，另外两颗被全局无敌拒绝但仍消费。配置表若写“全中 120/210”，只对没有玩家无敌帧的目标成立。

石头人存在潜在类型契约错误：植物路径明确传 `golem_config.slam_damage_type`，玩家路径复用骑士 helper，最终 `hit_player.apply_damage(damage_amount)` 或联机默认值，固定按物理结算，见 `scene/enemy/artificial_creation/stone_golem.gd:170-182`、`scene/enemy/capoo/capoo_knight.gd:386-404`。当前配置恰好是物理，所以尚未显现；未来把 `slam_damage_type` 改为魔法会只影响植物。

### 5.5 铃兰 Boss

| 来源 | 当前伤害与规模 | 类型/目标/ranged | 命中与重复规则 | 证据 |
|---|---|---|---|---|
| 技能 1 樱花弹 | 每弹 50；约 360 发/秒，17 秒约 6120 发 | 物理；玩家；ranged | 每颗 `has_hit`；客户端铃兰专用路径只回报本地接触，Host 结算/去重 | `resources/config/bosses/linglan_skill_config.gd:13`、`scene/boss/linglan/linglan_boss.gd:445-595`、`linglan_skill1_sakura_bullet.gd:149-266` |
| 技能 2 追踪火箭 | 80；10 轮；爆炸半径 78 | 默认物理；正常 Boss 路径仅玩家；ranged | 每帧射线、完整分页 AoE、按目标 ID 一次；同脚本还支持收藏品 `enemies_only` 模式 | `scene/boss/linglan/linglan_skill2_sakura_rocket.gd:220-375,398-483` |
| 技能 3 成长光球 | 每球 50；每 0.2 秒一颗、共约 50 颗 | 魔法；玩家；ranged | 每球 `damaged_player_ids`；膨胀时额外 `intersect_shape(query, 16)` 捕获新增覆盖 | `scene/boss/linglan/linglan_skill3_light_orb.gd:101-214` |
| 技能 4 激光场 | 每次 50；每玩家 0.5 秒冷却 | 魔法；玩家；非 ranged | 每个玩家独立 next-damage deadline；字段从“预警”生成时已经启用伤害碰撞 | `scene/boss/linglan/linglan_skill4_laser_field.gd:13-14,74-170,277-347` |
| 技能 4 横向光球 | 每球 50；7 波，每波左右各 7 个（当前资源），共 98 颗 | 魔法；玩家；ranged | 每颗光球对每玩家至多一次 | `resources/config/bosses/linglan_skill4_config.gd:18-28`、`scene/boss/linglan/linglan_skill4_light_orb.gd:70-143` |
| 半血狙击手空投 | 普通狙击手 200 | 物理；玩家/植物；ranged | 复用上述狙击逻辑，不是 Boss 独立伤害类型 | `scene/boss/linglan/linglan_boss.gd:377-405` |

技能 4 激光在命中尝试前就推进该玩家的 0.5 秒 deadline，随后才调用 `apply_damage()`，见 `scene/boss/linglan/linglan_skill4_laser_field.gd:312-324`。如果玩家仍在 1 秒全局无敌中，这次尝试虽然不扣血，激光自己的冷却仍被消费；实际承伤通常受全局无敌限制到约 1 次/秒。

“预警阶段是否应伤害”目前由实现回答为“会”：Boss 以 `enable_damage=true` 创建字段，`_ready/setup()` 立即开启 monitoring；只是线宽较细，见 `scene/boss/linglan/linglan_boss.gd:1184-1191,1290-1324`、`scene/boss/linglan/linglan_skill4_laser_field.gd:74-139,240-255`。

## 六、重复结算与多段命中规则

当前去重分为六层，彼此没有统一抽象：

1. **攻击节奏层**：公共接触一个冷却；光环一个冷却；激光每玩家一个 deadline。
2. **投射物生命周期层**：AK、原石虫火弹、Boss 弹等用 `has_hit`/active flag，命中即销毁或回池。
3. **范围攻击层**：RPG、法师火球、自爆、Boss 火箭用 `damaged_ids`，确保一次爆炸每实体一次。
4. **技能目标层**：雷链排除已跳目标；Boss 光球按玩家 ID；骑士/石头人按该次攻击目标 ID。
5. **联机 contact token 层**：火术士 A/B/C 三个位、冰锥一个位；消费发生后即使玩家无敌，也不会让另一个客户端再次报告。
6. **联机事件缓存层**：`_processed_player_hit_ids` / `_processed_enemy_hit_ids` 保留 30 秒。

另外还有玩家自身的 1 秒全局无敌，它不是来源去重，却对所有普通直伤形成跨来源、跨攻击的全局互斥窗口。一次成功闪避也会开启这个窗口，见 `scene/player/player.gd:742-753`。

目前 `bool` 返回值混合了三种语义：

- `Player.apply_damage()`：是否实际接受了这次直伤；
- `PlantDefense.receive_damage()` / `Enemy.apply_damage()`：合法正伤害是否进入结算；
- `MPGame.request_multiplayer_player_damage()`：请求是否由本端处理/忽略/已去重，目标非本地、目标已死、重复命中也可能返回 `true`。

投射物常把第三种 `true` 当作“可以消费”，这是合理的传输行为，却不能拿它判断是否扣血或是否应附加状态。火球/史莱姆不得不在 `MPGame` 内按 source type 再实现一次状态确认逻辑。统一接口应返回结构化结果，而不是继续扩展布尔约定。

建议结果至少包含：

```text
handled / accepted / applied_damage / blocked_reason
killed / target_health_after
contact_consumed / event_id
statuses_applied
```

## 七、联机结算与权威边界

### 7.1 玩家受伤

`request_multiplayer_player_damage()` 的参数 5/6 是动态重载：

```gdscript
damage_type_or_source_direction: Variant
source_direction_or_is_ranged: Variant
```

如果第 5 参数是 `Vector2`，伤害类型保持默认物理；如果是 int 才当伤害类型。证据：`scene/multiplayer/mp_game.gd:7076-7100`。这让老签名兼容，但使新攻击很容易在联机中悄悄丢失元素类型。

客户端受击报告携带 `reported_health_after`、`reported_is_dead`、`reported_applied_damage`。Host 的主要校验是：

- sender 必须等于被击玩家；
- source/target/type 去重；
- 火术士三球和冰锥消费 Host projectile record；
- 冰锥从记录取权威原始伤害；
- 生命不能高于 Host 当前生命。

但普通来源最终仍采用 `confirmed_health = min(reported_health_after, host_current_health)`，没有从 Host 端玩家防御、无敌、闪避、方向修正和攻击记录重新计算，见 `scene/multiplayer/mp_game.gd:7373-7505`。这意味着客户端不能通过报告把生命抬高，却可以在只靠本地接触报告的路径少报或不报。

燃烧/流血跳伤则是 Host 直接调用 `Player.apply_periodic_damage()`，并验证受信来源和等级，再广播 health revision；权威性明显更强，见 `scene/multiplayer/mp_game.gd:7234-7316`。

### 7.2 敌人受伤

玩家投射物打敌人时，Host 校验 owner、projectile record、投射物类型、第一次命中消费和 `(projectile_id, enemy_id)` 去重，并重建权威伤害，再进入敌人承伤，见 `scene/multiplayer/mp_game.gd:6259-6352`。

这里仍缺少“Host 轨迹/目标碰撞几何”验证，客户端可为仍有效的穿透弹报告不合理目标；但至少伤害数值和归属不是直接信任客户端。统一 Combat 协议应让玩家受伤也采用同一模式：Client 只报告候选 contact，Host 根据 AttackRecord + TargetState 决定结果。

### 7.3 source type 字符串注册表

`source_type` 同时承担：

- 去重命名空间；
- 元素类型纠正；
- 火/冰状态附加；
- 三火球、冰锥 contact 消费；
- Host projectile record 映射；
- 表现协议分支。

这些字符串散落在敌人脚本、投射物脚本和 `MPGame`。新增攻击若漏掉任一处分支，会出现“单机正确、联机物理/魔法错误、状态不生效或重复命中”。这应改为有类型的 `AttackDefinition`/注册表生成协议数据，而不是继续增加字符串 match。

## 八、死亡、击杀与副作用

### 8.1 敌人死亡

`Enemy._die()` 先检查并设置 `is_dead`，因此同一实体的公共死亡副作用具备幂等性；随后顺序为：

1. 清寒冷与收藏品状态；
2. 请求配置的全队息壤击杀奖励；
3. 解析并延迟生成掉落；
4. 发出 `defeated(self)`；
5. 关闭处理、速度和碰撞；
6. 播放死亡音效/动画并最终释放。

证据：`scene/enemy/enemy.gd:3781-3925`。

`grant_xirang_kill_reward()` 在同一帧延迟批量发放：单机给玩家，联机给所有 peer 玩家，不检查 killer，见 `scene/game_runtime_base.gd:914-920,971-984`。

塔防的 `defeated` 监听会推进 defeated/resolved、广播终态并检查波次完成；Boss 死亡还会无奖励地 `queue_free()` 剩余 adds，见 `scene/game_tower_defense.gd:3635-3646,3951-4007`。

玩家收藏品的 on-kill 效果不监听 `Enemy.defeated`，而是在某次玩家攻击完成后调用 `Player.apply_collectible_attack_hit_effects()`，如果此时 `enemy.is_dead` 才执行治疗、息壤、充能、雷击、冰霜、加速等，见 `scene/player/player.gd:2749-2764,2878-2915`。

由此产生的归属规则是：

- 公共息壤/掉落：所有死亡都有，且全队共享；
- 玩家 kill effect：只有经过对应玩家命中调用点的死亡才有；
- 敌人 DoT、植物攻击、友军自爆、环境或另一玩家造成的死亡，没有统一 killer/cause；
- DoT tick 调用 `Enemy.apply_damage()` 时已丢失最初施加者，无法在死亡时补归属。

### 8.2 玩家死亡

本地玩家死亡会清 DoT/寒冷、冲刺、战斗输入和无敌，停止射击并发 `died`，见 `scene/player/player.gd:4542-4569`。联机确认死亡后，Host 对特定角色清投射物记录并安排复活，见 `scene/multiplayer/mp_game.gd:7286-7311,7524-7529,7981-8018`。

死亡函数不接收 `DamageSource`，无法记录“被何种攻击、哪只敌人、直伤还是 DoT”击杀。

### 8.3 植物死亡

植物死亡先锁 `is_dead`、清 DoT、置 0、发 `died`，再进入动画移除并关闭碰撞，见 `scene/plant_defense/plant_defense.gd:706-742`。`receive_damage()` 虽带 `source: Node` 给 hook 使用，死亡入口没有保留 killer；DoT tick 还会把 source 置为 null，见 `scene/plant_defense/plant_defense.gd:388-409`。

### 8.4 基地失败

基地生命归零直接进入 defeat；没有来源或最后一击信息，见 `scene/game_tower_defense.gd:813-829`。敌人 escape 本身也不是 `Enemy._die()`，不会触发正常击杀奖励/掉落。

## 九、明确的一致性问题

### 9.1 多段攻击与玩家无敌帧

这不是单一脚本 bug，而是缺少攻击级命中策略：

| 攻击 | 作者数值语义 | 玩家实际常见语义 | 植物实际语义 |
|---|---|---|---|
| AK 10 × 20 | 十连发 | 通常 1 发扣血，其余被 1 秒无敌拒绝 | 最多 10 发全结算 |
| 火术士 3 × 40/70 | 三球全中 | 通常第一球扣血/燃烧，另外两球只消费 | 3 球全结算，燃烧刷新 |
| SMG 30 / 0.1 秒 | 300 原始 DPS | 通常约 30 原始伤害/秒 | 命中时约 300 原始 DPS |
| 铃兰激光 50 / 0.5 秒 | 100 原始 DPS | 通常受全局无敌限制为约 50/秒 | 激光不打植物 |
| 铃兰高密弹幕 | 弹幕碰撞 | 1 秒全局伤害窗口 | 不打植物 |

若这是明确设计，应把攻击的“对玩家有效段数”写进配置/设计工具并建立测试；若希望某些持续攻击按自身间隔结算，则需要 `invulnerability_policy`，不能在调用点绕过 `apply_damage()`。

### 9.2 远程上下文不完整会改变收藏品效果

玩家的远程闪避和前/后伤害倍率完全依赖 Dictionary 的 `is_ranged/source_direction`。当前大部分弹丸、hitscan、狙击、雷链和 Boss 光球正确标为 ranged；接触、光环、斩击、砸地、自爆和激光不标记。

任何新调用若忘传上下文，就会被当成非远程，而且静态类型/测试不会自动提醒。`DamageEvent` 应强制来源分类与方向字段。

### 9.3 伤害类型分散

- 公共接触由虚函数决定；
- 石头人砸地部分读配置；
- RPG/原石虫火弹/AK/SMG/狙击在脚本中固定物理；
- 法师、术士和 Boss 光球在脚本中固定魔法；
- 联机入口又可能按 source type 覆写。

同一攻击的类型没有单一事实源。火焰弹原石虫和石头人玩家路径已经展示了这种漂移风险。

### 9.4 查询上限先截断再过滤

骑士/剑客斩击先取最多 16 个 shape 结果，再做目标类型、内外半径和扇角过滤；范围内碰撞体密集时可能让合法目标根本不在前 16 个，见 `scene/enemy/capoo/capoo_knight.gd:223-253`。Boss 技能 3 膨胀补验同样固定 16，但只查玩家，当前玩家规模下风险较低，见 `scene/boss/linglan/linglan_skill3_light_orb.gd:161-175`。

### 9.5 植物混合伤害数字

植物同帧把物理与魔法总额合并成一个数字，并以较大一类决定颜色/方向；真实扣血正确，但调试和玩家反馈会丢失类型拆分，见 `scene/plant_defense/plant_defense.gd:653-690`。统一 `DamageResult` 可保留逐类型明细，同时继续在 UI 层决定是否合并。

## 十、可迁移到统一接口的具体调用点

### 10.1 第一层：共享类型与纯解析器

把 `DamageType` 从 `EnemyConfig` 移到独立 `CombatTypes`，建立纯函数 `DamageResolver.resolve(event, target_stats) -> DamageResult`。先只迁移重复公式，不改生命周期：

- `scene/player/player.gd:1136-1154`；
- `scene/plant_defense/plant_defense.gd:604-610`；
- `scene/enemy/enemy.gd:1613-1624`；
- `scene/enemy/enemy.gd:937-965` 的逐 hit 批解析。

解析器必须显式保留现有层序：远程方向倍率 → 双防 → 目标额外减伤/承伤倍率，以及各层 floor/round。

### 10.2 第二层：结构化 `DamageEvent`

建议字段：

```text
event_id / attack_id / hit_index
source_entity / source_net_id / source_peer_id
source_type / attack_definition_id
target_entity
raw_damage / damage_type
source_position / source_direction
delivery: CONTACT | PROJECTILE | HITSCAN | AREA | CHAIN | PERIODIC | HOME
is_ranged
invulnerability_policy / dodge_policy / defense_policy
status_payloads[]
kill_credit
```

优先迁移所有敌方攻击提交点：

- 公共接触：`scene/enemy/enemy.gd:3678-3724`；
- 翠壳、自爆、火弹：`scene/enemy/yuanshi_insect/yuanshi_insect_aura.gd:304-317`、`yuanshi_insect_exploder.gd:97-161`、`yuanshi_insect_fire_projectile.gd:121-182`；
- AK/骑士/SMG/RPG/法师/狙击：`scene/enemy/capoo/capoo_ak47_bullet.gd:271-299`、`capoo_knight.gd:215-268`、`capoo_smg.gd:297-369`、`capoo_rpg_rocket.gd:201-298`、`capoo_mage_fireball.gd:250-367`、`capoo_sniper.gd:206-265`；
- 火/冰/雷术士：`scene/enemy/sorcerer/fire_sorcerer_fireball_volley.gd:427-482`、`frost_sorcerer_ice_spike.gd:195-281`、`lightning_sorcerer.gd:350-465`；
- 石头人：`scene/enemy/artificial_creation/stone_golem.gd:112-183`；
- 铃兰四技能：`scene/boss/linglan/linglan_skill1_sakura_bullet.gd:149-266`、`linglan_skill2_sakura_rocket.gd:220-422`、`linglan_skill3_light_orb.gd:101-214`、`linglan_skill4_light_orb.gd:70-143`、`linglan_skill4_laser_field.gd:277-347`；
- Home：`scene/game_tower_defense.gd:763-829`，可使用独立 `BaseDamageEvent` 但共享来源/结果模型。

### 10.3 第三层：有类型的目标接口

目标仍应拥有自己的生命和死亡生命周期，但统一接受事件并返回结果，例如：

```text
Damageable.resolve_damage(event) -> DamageResult
```

替换：

- `Player.apply_damage()` 与 `apply_periodic_damage()`；
- `PlantDefense.receive_damage()` 与必要的 `receive_unmitigated_damage()` policy；
- `Enemy.apply_damage()` / `apply_damage_batch()`；
- 直接依赖 `last_damage_taken` 的调用点。

不要把所有目标差异塞进宽泛 fallback。玩家的闪避/无敌、植物的 revision、敌人的承伤倍率应是明确的 target policy/component。

### 10.4 第四层：AttackRecord 与联机 Host 结算

在攻击提交时注册不可变 `AttackRecord`：权威伤害、类型、ranged、状态、允许目标、生命周期、命中预算和 contact policy。客户端只回报：`attack_id + target_id + contact_time/position`。

迁移入口：

- `scene/multiplayer/mp_game.gd:5540-5776` 的 projectile/contact 特例；
- `scene/multiplayer/mp_game.gd:7076-7213` 的 Variant 请求；
- `scene/multiplayer/mp_game.gd:7332-7554` 的玩家生命报告；
- `scene/multiplayer/mp_game.gd:6259-6352` 的敌人命中报告。

Host 应从 AttackRecord 和 TargetState 重算伤害、无敌、状态与死亡；客户端生命只能作为诊断值。先保持现有 RPC 名和 wire，再在 handler 内委托给 Combat service，可以降低协议迁移风险。

### 10.5 第五层：状态定义注册表

把火术士/史莱姆的 duration、tick、type、stacking policy 从 `MPGame` 常量迁到共享 `AttackDefinition`/`StatusDefinition`。联机只传稳定 ID，Host 查同一资源定义，消除：

- `scene/multiplayer/mp_game.gd:136-152`；
- `scene/multiplayer/mp_game.gd:5570-5623`；
- `scene/multiplayer/mp_game.gd:7507-7517` 的字符串状态分支。

### 10.6 第六层：击杀上下文

将 `DamageResult` 的致死结果连同 `KillContext` 交给统一死亡结算：

```text
killer_entity / owner_player / team
attack_definition_id
cause: DIRECT | PERIODIC | ENVIRONMENT | FRIENDLY_FIRE | HOME
assists / timestamp
```

迁移：

- `scene/enemy/enemy.gd:3781-3828` 的奖励/掉落；
- `scene/player/player.gd:2749-2764,2878-2915` 的玩家 kill effects；
- `scene/plant_defense/plant_defense.gd:706-742`；
- `scene/player/player.gd:4542-4569`；
- `scene/game_tower_defense.gd:813-829`。

可保留“全队共享息壤”的产品规则，但它应是明确的 reward policy，而不是因为死亡入口没有 killer 才被迫全局发放。

## 十一、建议的落地顺序与回归断言

1. **先建立纯 `DamageResolver` 和 golden tests**，保持现有结果逐点一致；不要先改联网协议。
2. **引入 `DamageEvent/DamageResult`，以适配器包住四个旧入口**；新攻击禁止直接调用旧签名。
3. **把所有 source type/status 元数据迁入 AttackDefinition**，生成/校验联机注册表。
4. **Host 重算玩家受伤**，客户端报告只作为候选 contact；保留旧 RPC wire 过渡。
5. **最后统一 KillContext 和奖励/收藏品击杀效果**，因为它会改变产品语义，需要专项确认。

必须有的回归断言：

- 玩家 1 秒无敌下，AK、三火球、SMG、激光的实际命中次数与当前版本一致；
- 植物仍吃满多段，物防按每 hit 扣减而非先合并；
- 100 魔防/高物防仍至少 1 点；
- 魔防 floor、敌人承伤 round、玩家额外减伤 floor 的边界不变；
- 紫阳花减攻在发射前/飞行中到期的弹丸快照不变；
- 燃烧 5 秒只跳 4 次、同族刷新首跳、不同 burn 族只取最强；
- 火术士 A/B/C 和冰锥 contact 只消费一次；
- 同一爆炸每实体一次，雷链不重复目标；
- 单机与联机对伤害类型、方向倍率、状态和死亡结果完全一致；
- DoT、植物、友伤、自爆和玩家直伤都有明确 `KillContext`，不会重复奖励或 kill effect。

## 十二、审计边界

- 已覆盖当前 28 个可实例化敌人配置及铃兰四技能直接产生的伤害；守护者原石虫只有防御光环，没有额外伤害源。
- 玩家/植物对敌人的所有具体武器和塔数值不在本报告逐项展开，但其最终敌人承伤入口、联机报告和死亡副作用已覆盖。
- 地形枯萎等环境无视防御伤害只作为非敌方入口注明，未归入敌方攻击清单。
- 本报告是静态审计；多段攻击的“通常每秒一次”是由源码中的 1 秒全局无敌和攻击节奏推导，仍应在目标帧率、延迟和多人场景用确定性测试复核。

## 十三、并行迁移即时对照

审计末尾对共享工作树做了第二次只读核对。当前已经新增：

- `scene/combat/combat_types.gd`：显式 0/1 ABI 的物理/魔法类型、伤害 flags、取整模式、拒绝原因；
- `scene/combat/damage_request.gd`：伤害值、类型、来源、source ID/type、冲击/来源方向和 flags；
- `scene/combat/damage_target_profile.gd`：生命、双防、最小伤害、前/后倍率和取整模式；
- `scene/combat/damage_resolver.gd`：纯单次/批量解析，保留逐 hit 防御和最低伤害；
- `scene/combat/damage_result.gd`：requested/adjusted/mitigated/resolved/applied、生命前后、致死和命中计数；
- `Player.apply_combat_damage()`、`PlantDefense.apply_combat_damage()`、`Enemy.apply_combat_damage()`；旧入口成为兼容 wrapper；
- 铃兰 Boss 改用 `_on_combat_damage_applied(result)` hook 发生命变化；
- Host 确认敌人伤害的 `_apply_confirmed_enemy_damage()` 已直接消费 `DamageResult`。

即时公式对照未发现明显语义偏移：玩家前方/背后倍率仍在双防前 `roundi`，玩家最强额外减伤仍在双防后 `floori`，敌人承伤倍率仍在双防后 `roundi`，批伤仍逐 hit 减防并钳制到剩余生命；周期伤害通过 BYPASS_INVULNERABILITY/BYPASS_DODGE/NO_HIT_INVINCIBILITY flags 保留原行为。

但这只是“数值解析器 + 三个目标 sink”阶段，以下基线风险仍然存在：

1. 所有敌方攻击脚本仍调用旧 `apply_damage()` / `receive_damage()` 或动态 `request_multiplayer_player_damage()`，尚未构造携带攻击定义、状态、命中策略和击杀归属的结构化事件。
2. `MPGame.request_multiplayer_player_damage()` 的 Variant 参数重载、客户端生命报告和 source type 字符串状态分支尚未迁移。
3. 1 秒玩家全局无敌、多段攻击对玩家/植物的巨大差异仍按旧规则保留；这是兼容正确，但仍需要产品层确认。
4. `EnemyConfig.DamageType` 与 `CombatTypes.DamageType` 暂时双份存在，只依靠相同 0/1 ABI 兼容；应把前者明确标成过渡别名或最终移除，防止未来增加类型时漂移。
5. 旧 wrapper 仍只返回 `bool accepted`；攻击调用点尚无法直接区分 invulnerable、dodged、duplicate/contact consumed。`DamageResult` 已提供拒绝原因，但未贯穿投射物消费协议。
6. `DamageRequest` 当前没有 delivery、状态 payload、target、owner player 或 KillContext；死亡奖励、玩家 kill effect 和 DoT 归属仍未统一。
7. 自爆目标层/友伤、翠壳单玩家字段、石头人玩家伤害类型、骑士查询上限、铃兰预警激光伤害等攻击源级问题不由数值解析器自动修复。
8. Home/基地伤害仍完全在统一 sink 之外。

因此，当前并行改造已经完成本报告 10.1 和 10.3 的主要骨架，并开始覆盖 10.4 的敌人承伤侧；10.2 的完整攻击事件、10.4 的玩家 Host 权威结算、10.5 状态注册表和 10.6 击杀上下文仍是下一阶段。
