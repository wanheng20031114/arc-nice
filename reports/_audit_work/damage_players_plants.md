# 玩家、植物、塔、道具、治疗与护盾伤害域深度审计

> 审计日期：2026-07-26
> 审计对象：当前工作树，包含本轮新增的 CombatTypes、DamageRequest、DamageTargetProfile、DamageResolver、DamageResult，以及已经迁移后的玩家、植物、敌人和基地承伤入口。
> 方法：只读追踪配置、调用链、生命周期和多人协议；没有修改业务代码，也没有启动 Godot。
> 路径均以仓库根目录为基准；行号对应本报告生成时的共享工作树。

## 1. 结论摘要

### 1.1 已经统一且应保持的部分

本轮迁移已经把玩家、植物、敌人和基地的纯数值结算收敛到同一个解析器：

- DamageRequest 明确携带伤害量、物理/魔法类型、来源、两个方向和行为 flag（scene/combat/damage_request.gd:4-13）。
- DamageTargetProfile 明确区分防御前倍率、防御、防御后倍率和各自取整方式（scene/combat/damage_target_profile.gd:4-14）。
- DamageResolver 的固定顺序是：防御前倍率 → 物防/魔防 → 防御后倍率 → 以剩余生命封顶（scene/combat/damage_resolver.gd:31-55,168-171）。
- Player、PlantDefense、Enemy 都保留自己的闪避、无敌、表现、信号、死亡和联机副作用，但不再复制纯伤害公式（scene/player/player.gd:750-820；scene/plant_defense/plant_defense.gd:155-209；scene/enemy/enemy.gd:910-953）。
- 联机玩家普通受伤已不再信任客户端上报的生命结果。客户端只报告受击接触，Host 从攻击证书恢复伤害并在 Host Player 上执行 apply_combat_damage，再以 health revision 广播结果（scene/multiplayer/mp_game.gd:7335-7609）。
- 本地收藏品伤害 fallback 已开始构造带 source Player、instance ID 和 collectible_effect 类型的 DamageRequest（scene/player/player.gd:3537-3566）；这说明来源迁移已经启动，但塔桥、玩家弹体和多人已注册敌人的确认入口仍未贯通来源。

### 1.2 仍需优先处理的风险

| 优先级 | 发现 | 影响 |
| --- | --- | --- |
| P1 | 死亡玩家仍在 Host 上推进并触发周期收藏品 | Player 每帧先更新收藏品周期效果，之后才检查 is_dead；权威判定又只检查“单机或 Host”，不检查存活。尸体可继续放雷、冰霜、樱花火箭、弓箭，并从尸体位置周期治疗活着的队友。证据：scene/player/player.gd:491-502,3015-3066,3232-3240,3765-3770。 |
| P1 | 伤害来源和击杀归属尚未进入真正的结果链 | DamageRequest 已有 source/source_id/source_type；本地收藏品 fallback 已填入来源，但塔、普通玩家弹体、多人已注册敌人和多数技能桥仍只传 amount/type/direction。塔计算出的 damage_source_id 在 GameTowerDefense 和 MPGame 中被参数名以下划线显式丢弃。DoT、塔、区域连锁和普通玩家命中的击杀副作用仍分属不同调用链。证据：scene/game_tower_defense.gd:558-584；scene/multiplayer/mp_game.gd:1500-1521,1606-1641,6443-6529；scene/player/player.gd:2839-2854,3537-3566；scene/enemy/enemy.gd:3828-3854。 |
| P2 | Hoe Cat 的两种直接挥砍漏掉“对燃烧/流血目标增伤” | 普通子弹、雪狼剑环、魏世岱尔炸弹和 Tiyi High Noon 都调用 resolve_attack_damage_against_enemy；Hoe 主挥砍和旋风只快照 get_outgoing_damage 后直接提交，却仍会触发普通 on-hit/kill。相同收藏品在不同主攻击形态上表现不一致。证据：scene/player/hoe_cat/player_hoe_cat.gd:81-89,272-350；scene/bullet.gd:240-256；scene/player/hoe_cat/hoe_cat_snow_wolf_sword_orbit.gd:188-211。 |
| P2 | 同来源 DoT 刷新会同时重置首跳倒计时 | 高频重复施加同一个 source_family 时，可以不断把首跳推迟，造成“状态一直显示但不跳伤”。这是当前明确语义，不是帧率误差。证据：scene/periodic_damage_status_scheduler.gd:172-193。 |
| P2 | 来源死亡/移除与已生成效果的生命周期并未统一 | 月盾是玩家子节点，玩家死亡不会清理；它会继续保护尸体附近队友。紫阳花被移除会停止自身玩法，但已经写入敌人的定时减攻继续到自身期限。发射前快照的敌方投射物也不会因减攻或施法者死亡而重算。 |
| P2 | 治疗仍是 bool + 可变旁路字段 | 玩家和植物没有 HealRequest/HealResult；玩家多人治疗依赖 last_healing_received 这一可变字段把实际治疗量从 Player 交给 MPGame。以后加入治疗增益、减疗、吸收、来源统计或过量治疗时会再次分叉。证据：scene/player/player.gd:2206-2234；scene/multiplayer/mp_game.gd:7761-7827。 |
| P2 | 客户端预测与 Host 都会独立掷闪避随机数 | Host 已是最终权威，这是正确修复；但客户端预测也执行两次 randf 闪避检查，因此同一事件可能本地命中、Host 闪避，或反过来，随后再被可靠生命事件纠正。需要接受这种短时回滚，或以后引入事件随机种子/只预测确定部分。证据：scene/player/player.gd:778-792,1072-1077；scene/multiplayer/mp_game.gd:7164-7191,7398-7609。 |

### 1.3 重要兼容变化

旧 Enemy 单击伤害会把防御后的完整过量伤害写进 last_damage_taken、伤害数字和联机反馈，生命甚至可先变成负值；新 DamageResult.applied_damage 明确封顶到 health_before，Enemy 现在用 applied_damage 表现和复制，生命稳定停在 0（scene/combat/damage_result.gd:4-17；scene/combat/damage_resolver.gd:168-171；scene/enemy/enemy.gd:937-949）。

这应视为有意修正后的新契约：

- resolved_damage 是公式结果，可大于剩余生命；
- applied_damage 是真实生命差，永远不大于剩余生命；
- 伤害数字、网络确认、击杀统计若表达“实际扣血”应使用 applied_damage；
- 需要展示理论爆发或 overkill 的系统应显式使用 resolved_damage，不能再依赖 last_damage_taken 的旧副作用。

## 2. 统一伤害对象与精确结算顺序

### 2.1 类型 ABI

CombatTypes.DamageType 只有 PHYSICAL=0、MAGIC=1，并刻意保持与 EnemyConfig.DamageType 及多人 wire 的 0/1 ABI 相同（scene/combat/combat_types.gd:4-9）。normalize_damage_type 会把任何非 1 值归一为物理（scene/combat/combat_types.gd:41-42）。

兼容约束：

- 不得调整两个枚举的数值或插入新成员改变序号。
- 若以后增加真实伤害、治疗伤害等类型，应使用显式 wire ID 和版本迁移，不能让旧客户端把未知值静默归为物理。
- 现阶段旧 API 仍接受 EnemyConfig.DamageType，新域内部使用 int；迁移完成前必须保留 0/1 对齐。

### 2.2 DamageRequest

字段见 scene/combat/damage_request.gd:6-13：

| 字段 | 当前含义 |
| --- | --- |
| amount | 原始单击伤害；batch 包装器当前为 0，真实组数据另传。 |
| damage_type | 归一后的物理/魔法类型。 |
| source | 本地 Node 引用，不跨网络。 |
| source_id | 稳定来源身份，适合去重、归属、状态来源；当前尚未贯通。 |
| source_type | 受限语义类别，如 burn family、投射物类型；当前只在部分联机玩家受伤链生效。 |
| impact_direction | 受击表现方向。 |
| source_direction | 从目标指向来源，用于玩家正面/背面远程修正。 |
| flags | 命中政策与表现标志。 |

方向在写入和读取时都经过有限数检查与归一化；零向量保持为零（scene/combat/damage_request.gd:35-40,56-67）。

### 2.3 Flag 的真实语义

Flag 定义在 scene/combat/combat_types.gd:11-18：

- PERIODIC 目前只是分类元数据，本身不会自动绕过无敌、闪避或受击无敌。
- RANGED 让 Player 启用正面/背面承伤倍率和远程收藏品闪避。
- BYPASS_INVULNERABILITY 只绕过冲刺无敌和普通受击无敌。
- BYPASS_DODGE 同时绕过基础闪避与远程收藏品闪避。
- BYPASS_MITIGATION 只跳过物防/魔防阶段；仍会经过防御前方向倍率和防御后最强减伤。它不是完整“真实伤害”。
- NO_HIT_INVINCIBILITY 让一次成功非致死伤害不授予普通受击无敌。
- SUPPRESS_HIT_PARTICLES 只控制 Enemy 受击粒子，不改变数字、音效或伤害。

因此当前周期伤害必须组合 PERIODIC | BYPASS_INVULNERABILITY | BYPASS_DODGE | NO_HIT_INVINCIBILITY 才能复现旧语义（scene/player/player.gd:826-837；scene/multiplayer/mp_game.gd:7267-7274）。

### 2.4 纯数值阶段

单击解析见 scene/combat/damage_resolver.gd:31-55：

1. amount 乘 pre_mitigation_multiplier，并按 profile 指定方式取整，至少 minimum_damage。
2. 若非 BYPASS_MITIGATION：
   - 物理：max(调整后伤害 - max(物防,0), minimum_damage)；
   - 魔法：max(floor(调整后伤害 × (100-clamp(魔防,0,100))/100), minimum_damage)。
3. 防御后结果乘 post_mitigation_multiplier，再按 profile 指定方式取整，至少 minimum_damage。
4. applied_damage=min(resolved_damage,current_health)，health_after=max(health_before-applied_damage,0)。

批量解析按每一组的每一击单独完成同样的防御和最低伤害语义，再按顺序累加，致死后停止；不能先合并原始伤害再只减一次物防（scene/combat/damage_resolver.gd:77-135）。

批量接口的兼容注意：

- Enemy.apply_damage_batch 构造的 request.amount 为 0（scene/enemy/enemy.gd:956-973）。
- DamageResult.requested_amount 会从各组聚合，但 result.request.amount 仍为 0。
- 未来 hook 若读取 result.request.amount，会把合法 batch 误判为空伤害；批伤 hook 应读取 result.requested_amount、requested_hit_count 和 accepted_hit_count。

## 3. 玩家承伤入口

### 3.1 普通直伤顺序

旧兼容入口 Player.apply_damage 把 Dictionary 中的 is_ranged 和 source_direction 立即转换为 DamageRequest，然后转入 apply_combat_damage（scene/player/player.gd:731-747）。

权威入口顺序见 scene/player/player.gd:753-820：

1. 清空 last_damage_taken。
2. request 为空、玩家已死、amount≤0 时显式拒绝并写 last_damage_result。
3. 未设置 BYPASS_INVULNERABILITY 时，冲刺无敌或 invincibility_time_left>0 拒绝。
4. 未设置 BYPASS_DODGE 时，先掷基础 dodge_chance，再掷仅限 RANGED 的 collectible_ranged_dodge_chance；任一成功都会播放闪避反馈并开启无敌。
5. 建立 Player profile 并调用 DamageResolver。
6. 写 current_health、last_damage_taken、血条、health_changed 和收藏品条件属性。
7. 致死立即进入 _die，不触发 hurt 收藏品，也不授予新受击无敌。
8. 非致死触发 hurt 收藏品；若未设置 NO_HIT_INVINCIBILITY，再开启普通受击无敌。

### 3.2 玩家属性修正顺序

Player profile 在 scene/player/player.gd:1219-1236：

1. RANGED 且来源方向有效时，按玩家 facing 与来源方向 dot 判断正面/背面；正面、背面倍率来自全部收藏品的乘积，使用 roundi，至少 1（scene/player/player.gd:1120-1134,2450-2454）。
2. 进入统一物防或魔防。
3. damage_reduction_modifiers 只取最大 reduction，不相乘；最大钳到 95%，防御后使用 floori，至少 1（scene/player/player.gd:1229-1235,1370-1377）。
4. 最后封顶到当前生命。

基础和收藏品属性重建顺序见 scene/player/player.gd:2385-2517：

- attack_damage=ceil((round(base_attack)+通用攻击加值)×临时攻击倍率)，至少 1；
- 物防=基础物防+收藏品+息壤动态防御+研究临时防御，至少 0；
- 魔防=基础魔防+收藏品，钳制 0..100；
- 物理/魔法伤害加值不并入 attack_damage，而是保留为类型专属 flat；
- 远程正/背倍率相乘，远程闪避率相加后钳制 0..1；
- 对燃烧/流血目标的倍率分别相乘后缓存。

### 3.3 普通伤害与周期伤害差异

| 行为 | 普通直伤 | Player 周期伤害 |
| --- | --- | --- |
| 冲刺/普通无敌 | 遵守 | 绕过 |
| 基础闪避 | 遵守 | 绕过 |
| 远程收藏品闪避 | RANGED 时遵守 | 绕过 |
| 正面/背面修正 | RANGED 时生效 | 不设置 RANGED，因此不生效 |
| 物防/魔防 | 生效 | 生效 |
| 最强额外减伤 | 生效 | 生效 |
| hurt 收藏品 | 非致死成功时触发 | 非致死成功时同样触发 |
| 授予受击无敌 | 默认授予 | 不授予 |

周期入口和 flag 见 scene/player/player.gd:823-837。DoT 因此不是“无视所有防御”的真实伤害。

### 3.4 月盾与玩家减伤

CollectibleMoonShield 是跟随施法玩家的 Area2D：

- 固定减伤 50%，不是配置字段（scene/collectible_moon_shield.gd:4）。
- 进入时以 shield 实例 ID 写入 Player.damage_reduction_modifiers，离开或 shield free 时删除（scene/collectible_moon_shield.gd:23-33,44-84）。
- 四个道具只配置半径/时长：月纹胸针 48/4s、月亮护符 64/8s、蚀月护符 72/8s、日月遗物 96/10s（resources/config/collectibles/collectible_moon_pin.tres:20-22；collectible_moon_amulet.tres:19-21；collectible_eclipse_amulet.tres:20-22；collectible_sun_moon_relic.tres:20-22）。
- 多个月盾重叠仍只取 50% 最强项，不会变成 75%、87.5%。
- Player 死亡流程不清空 damage_reduction_modifiers，也不 free 月盾；月盾作为子节点继续计时并检测其他玩家。因此尸体附近队友仍受保护，若玩家在 shield 到期前复活，自身也继续保留保护。

这是明确的来源生命周期边界；若设计不允许尸体施放持续光环，需要在死亡时销毁或停用，而不是在 DamageResolver 里补条件。

## 4. 联机玩家承伤与治疗

### 4.1 当前 Host 权威直伤

当前链路：

客户端本地碰撞/预测
→ request_player_hit_report 只发 source_id、target、受限 wire ID、方向和 RANGED flag
→ Host 校验 sender、token bucket、wire ID、投射物记录、时效、实体和接触距离
→ Host 从证书恢复 damage/type
→ Host Player.apply_combat_damage
→ Host 附加合法 burn/cold
→ health revision 可靠广播
→ 客户端 set_multiplayer_health_state 和表现回放

证据：

- 旧 Variant 适配器仍在入口立即归一化参数（scene/multiplayer/mp_game.gd:7083-7126）。
- 客户端预测即使被本地闪避/无敌拒绝，也仍发送接触声称，Host 独立决定（scene/multiplayer/mp_game.gd:7164-7191）。
- 可由客户端声称的来源使用稳定小整数 wire ID，Host-only 接触/hitscan/area 来源没有 wire ID（scene/combat/combat_attack_registry.gd:4-25,42-76）。
- RPC 校验 sender、每 peer 速率桶和受限来源（scene/multiplayer/mp_game.gd:7360-7395）。
- Host 证书校验投射物类型、expires_at、存活节点以及与玩家的接触容差，并从 Host 记录恢复 damage/type（scene/multiplayer/mp_game.gd:7616-7660）。
- 最终生命、实际伤害、死亡、状态和 rejection reason 均来自 Host DamageResult（scene/multiplayer/mp_game.gd:7541-7609）。

仍需保留的兼容性：

- 玩家受击方向必须以同一坐标约定构造：impact_direction 指向被击退/数字方向，source_direction=-impact_direction。
- 客户端 prediction 的闪避随机结果不应产生权威 hurt 收藏品；Player._trigger_collectible_hurt_effects 内部还会检查 authority（scene/player/player.gd:2744-2749）。
- Host 必须恰好执行一次 hurt/死亡/状态副作用；客户端只重放已确认表现，不能再次调用完整 apply_combat_damage。
- request_multiplayer_player_damage 的 Variant 重载仍是迁移壳，调用点应逐步改成明确的 DamageRequest 或强类型参数，避免第 5/6 参数错位（scene/multiplayer/mp_game.gd:7083-7109）。

### 4.2 Host 权威 DoT

Player 的 burn/bleed scheduler 在 Host 到期后调用 request_multiplayer_player_damage_over_time_tick。该入口：

- 只允许 Host 本地调用，不是客户端 RPC；
- burn 会验证 family 和 tick_damage 与联机信任表完全相同；
- burn 为魔法，bleed 为物理；
- 构造四 flag 周期请求；
- 用 DamageResult.applied_damage、health_after 和 lethal 可靠复制；
- 不在客户端授予普通受击无敌。

证据：scene/multiplayer/mp_game.gd:7227-7317。

### 4.3 联机治疗

Host 路径：

- apply_multiplayer_player_heal 调 Player._try_heal(amount,false)；
- 再读取 target_player.last_healing_received；
- report_multiplayer_player_healing 生成共享 health revision，排治疗数字并发送 net_player_healed；
- 客户端拒绝旧 revision 和死亡目标。

证据：scene/multiplayer/mp_game.gd:7761-7827。

正确点：多人治疗不接受客户端提供的最终生命或实际治疗量。结构风险：last_healing_received 是一次调用之间的共享可变状态，不是不可变结果；嵌套回调或未来异步化容易读错。

## 5. 植物与生产建筑承伤

### 5.1 唯一权威入口

旧 receive_damage 只负责把 Node 来源、冲击方向和类型打包为 DamageRequest（scene/plant_defense/plant_defense.gd:143-152）。apply_combat_damage 的顺序：

1. request 为空拒绝；
2. multiplayer proxy 拒绝 NOT_AUTHORITY；
3. is_dead 拒绝；
4. is_removing 拒绝；
5. 使用当前生命、有效物防、有效魔防解析；
6. 写生命，先 emit health_changed，再 bump health_revision；
7. 上报实际伤害数字和网络反馈；
8. 依据 BYPASS_MITIGATION 选择 unmitigated 或普通子类 hook；
9. lethal 时 _begin_death。

证据：scene/plant_defense/plant_defense.gd:158-209。

### 5.2 植物公式与状态

- 物防=配置物防+全局建筑结构强化，至少 0（scene/plant_defense/plant_defense.gd:504-509）。
- 魔防只取配置，钳制 0..100（scene/plant_defense/plant_defense.gd:512-513）。
- 无闪避、无普通无敌帧、无方向倍率、无通用减伤/护盾层。
- 燃烧跳伤按魔法、流血跳伤按物理，再次经过正常防御（scene/plant_defense/plant_defense.gd:440-461）。
- receive_unmitigated_damage 仅设置 BYPASS_MITIGATION，仍保留 revision、信号、反馈、子类 hook 和死亡（scene/plant_defense/plant_defense.gd:464-473）。
- 当前无植物冷冻状态；元素冰只对玩家附加移动减速。

无视防御来源：

- 地形失去支撑：每秒 max(ceil(当前生命×10%),50)，以当前生命递减，见 scene/plant_defense/plant_system.gd:22-23,339-384。
- 测试场景 Delete 快捷键：直接以 current_health 作为 unmitigated 伤害，半径 3 格内一键摧毁，见 scene/test_arena/test_grass_arena.gd:15,66,77-100。

### 5.3 植物治疗和死亡

receive_healing：

- proxy、死亡、移除中、非正数、满血时拒绝；
- 按 max_health 封顶；
- emit health_changed、bump revision、emit healing_applied；
- 同帧治疗数字聚合；
- 调用子类 _on_healing_received。

证据：scene/plant_defense/plant_defense.gd:476-495。

死亡：

- _begin_death 先置 is_dead、清 DoT、生命归零并 emit died；
- begin_removal 再置 is_removing/is_operational=false、停建造、关碰撞；
- 普通模式以约 0.7 秒动画移除，静默模式立即 queue_free。

证据：scene/plant_defense/plant_defense.gd:760-796,884-896。

植物没有复活、吸收盾或死亡保护。已发射的塔弹体拥有独立生命周期，来源塔死亡并不会自动撤销已经排入世界/集中战斗系统的结算。

## 6. 玩家对敌伤害来源与属性顺序

### 6.1 公共出伤层

Player.get_outgoing_damage 只在传入 base_amount 上加物理或魔法 flat，至少 1（scene/player/player.gd:1307-1316）。通用 attack bonus 和临时攻击倍率已经预先体现在 attack_damage；固定收藏品伤害若直接以配置值为 base，不会额外获得通用 attack bonus，只获得类型 flat。

对目标状态倍率由 resolve_attack_damage_against_enemy 单独处理：

- burn 倍率和 bleed 倍率可以相乘；
- 对最终值 roundi，至少 1；
- 必须由每个攻击实现主动调用。

证据：scene/player/player.gd:1319-1329。

### 6.2 主攻击和技能枚举

| 来源 | 原始/倍率构造 | 目标 burn/bleed 增伤 | 普通 on-hit/kill |
| --- | --- | --- | --- |
| 普通 Bullet | 角色在生成时给 damage；命中时再解析目标状态 | 是，scene/bullet.gd:240-249 | 是，命中接受后调用，scene/bullet.gd:256 |
| Hoe 主挥砍 | get_outgoing_damage(attack_damage,物理) | **否** | 是，scene/player/hoe_cat/player_hoe_cat.gd:341-350 |
| Hoe 旋风 | floor(attack_damage×3.0) 后加物理 flat | **否** | 是；无论命中数都会再治疗 5，scene/player/hoe_cat/player_hoe_cat.gd:10-11,521-539 |
| Hoe 雪狼剑环 | 固定 contact damage 先加物理 flat | 是 | 是，scene/player/hoe_cat/hoe_cat_snow_wolf_sword_orbit.gd:188-211 |
| 魏世岱尔炸弹 | floor(attack_damage×3.3) 后加类型 flat | 是 | 否；另行施加研究 burn，scene/player/weishidaier/player_weishidaier.gd:61-64；weishidaier_skill1_bomb.gd:122-172 |
| Tiyi High Noon | floor(attack_damage×3.5) 后加类型 flat | 是 | 否，scene/player/tiyi/player_tiyi.gd:19,227-232,445-454 |
| 收藏品周期/触发/击杀范围伤害 | 配置 base 或 attack_damage 派生值 + 类型 flat | 通常否 | 不递归触发新的 on-hit/kill，scene/player/player.gd:3070-3258,3601-3726 |

兼容判断：

- “技能是否属于普通命中”当前答案不是统一的是/否：Hoe 旋风会触发普通命中收藏品，魏世岱尔炸弹和 High Noon 不会。
- 在统一 AttackRequest 之前，应保留每个来源的 can_trigger_on_hit、can_trigger_kill、can_gain_target_status_bonus 显式政策，不能简单让所有 DamageRequest 自动触发。

### 6.3 on-hit 与 kill 的顺序

apply_collectible_attack_hit_effects 的顺序（scene/player/player.gd:2839-2854）：

1. 基础攻击已经结算；
2. 若目标仍活着，按当前有效收藏品顺序逐个执行 on-hit；
3. 某个 on-hit 杀死目标后立即停止剩余 on-hit；
4. 若最终死亡，再遍历全部 kill effect。

影响：

- mark/crack 在基础命中之后才附加，不增幅触发它们的那一下；但同一 on-hit 序列中更晚的 shock/execute 可能吃到前一个状态，结果依赖槽位/缓存顺序。
- DoT tick 直接调用 Enemy.apply_damage，不回到 owner Player，因此 DoT 击杀不触发玩家 kill effect。
- 塔、收藏品区域连锁、敌人友伤也没有 player kill context。
- 敌人公共 _die 无论 killer 是谁都会排全队息壤奖励和掉落（scene/enemy/enemy.gd:3828-3863）；玩家个人 kill effect 是另一条链。

### 6.4 死后弹体

已发射的普通 Bullet 仍持有 collectible_owner。Player 死亡不会让 apply_collectible_attack_hit_effects 自身拒绝 is_dead（scene/player/player.gd:2839-2854）。因此死前发出的慢速/追踪/穿透弹在死后命中时，仍可能：

- 施加 burn/bleed/mark/crack；
- 触发 shock、execute、范围治疗或息壤；
- 触发 kill area damage。

部分自我收益内部会因死亡拒绝，例如 _try_heal 和技能充能；但团队/世界副作用仍可能发生。是否允许“遗弹击杀”应由 AttackContext 快照政策决定，而不是由各效果偶然的 is_dead 检查决定。

## 7. 植物塔对敌伤害来源

| 塔 | 当前数值与类型 | 提交点 |
| --- | --- | --- |
| 龙舌兰加农炮 | 25 物理，半径 18；2 秒一次 | resources/config/plant_defense/agave_cannon.tres:11,18-20；scene/plant_defense/agave_cannonball.gd:181-227 |
| 玉米机枪塔 | 30 物理×6；0.9 秒一轮，轮内 0.06 秒 | resources/config/plant_defense/corn_machine_gun.tres:11,18-22；scene/plant_defense/corn_machine_gun.gd:361-378 |
| 竹筒迫击炮 | 内圈 100、外圈 50 物理；4 秒蓄力 | resources/config/plant_defense/bamboo_mortar.tres:11,18-20；scene/plant_defense/bamboo_mortar_shell.gd:367-397 |
| 葡萄电弧塔 | 72 魔法；1.6 秒；96px 主范围；最多 4 个不同敌人；跳 72px；充能 0.42 秒 | resources/config/plant_defense/grape_arc_tower.tres:11,18-25；scene/plant_defense/grape_arc_tower.gd:375-407 |
| 紫阳花雨幕 | 5 魔法，只有雨滴冲击窗内的第 0/1 跳；每跳同时刷新敌减攻 | resources/config/plant_defense/hydrangea_rain_tower_config.gd:13-19；scene/plant_defense/hydrangea_rain_tower.gd:511-573 |

现有数据结构差异：

- 葡萄和紫阳花使用强类型子配置，并验证额外字段（resources/config/plant_defense/grape_arc_tower_config.gd:4-21；hydrangea_rain_tower_config.gd:10-43）。
- 龙舌兰、玉米、竹筒仍在脚本保留默认伤害/范围/节奏常量；竹筒外圈 50、最小射程和蓄力还没有全部进入同一配置资源。

来源丢失：

- 每个塔已经计算/传递 source_id，例如葡萄使用 net_id 或 instance_id（scene/plant_defense/grape_arc_tower.gd:375-398）。
- GameTowerDefense batch 接口把参数命名为 _damage_source_id 后直接调用旧 Enemy.apply_damage_batch（scene/game_tower_defense.gd:558-584）。
- MPGame single/batch 同样忽略 source ID，再在 _apply_confirmed_enemy_damage(_batch) 中新建没有 source 的 DamageRequest（scene/multiplayer/mp_game.gd:1500-1521,1606-1641,6443-6513）。
- 已由本轮解决的一小段是：Player 的单机/无多人桥 fallback 现在会给收藏品伤害写 source=self、source_id=player instance ID、source_type=collectible_effect；MPGame 对无 net ID 敌人至少保留 source_type，但 source_id 仍为 0（scene/player/player.gd:3537-3566；scene/multiplayer/mp_game.gd:6221-6249）。
- 这仍是粗粒度归属：同一玩家的所有收藏品伤害共用 player instance ID 和通用 collectible_effect 类型，无法区分具体 item/effect/application。它适合证明来源管线可行，不足以支撑逐道具统计、去重和 kill credit。

这是最直接的迁移调用点：桥接层应构造带 source_id/source_type/source Node 的 DamageRequest，再把同一个 result 用于归属、网络和死亡事件。

## 8. DoT 与持续状态

### 8.1 玩家/植物共用调度器

PeriodicDamageStatusScheduler 是事件堆调度器，而不是每个目标每帧轮询（scene/periodic_damage_status_scheduler.gd:4-12,31-51）。

精确语义：

- 同一 source_family 再次施加：更新 duration、tick_damage、tick_interval，并把 tick_time_left 完整重置为新间隔（:172-193）。
- burn 通道使用 STRONGEST_SOURCE：只有最高 tick_damage 来源推进跳伤相位；较弱来源的跳伤相位暂停，但持续时间仍继续消耗（:537-592）。
- 相同 burn 伤害用 source_family 的字典序稳定决胜（:638-653）。
- bleed 通道使用 ALL_SOURCES，各来源独立推进和跳伤（:594-635）。
- 到期与跳伤同一精确时刻时，先移除状态，不执行端点跳伤（:560-573,604-622）。

因此：

- duration=3、interval=1 的状态只在 1s、2s 跳两次；
- duration=5、interval=1 的状态只在 1s、2s、3s、4s 跳四次；
- 高频同族刷新可能无限推迟首跳；
- 较弱 burn 可能在一直被压制期间直接到期，从未跳伤。

### 8.2 当前敌方施加到玩家/植物的 DoT

| 来源 | 状态 | 实际跳数与总原始 DoT |
| --- | --- | --- |
| 火焰史莱姆接触 | burn 3s、10/秒 | 2 跳，共 20；scene/enemy/slime/slime.gd:4-7,34-50 |
| 火焰术士三球 | burn 5s，普通 5/秒、精英 10/秒 | 4 跳，共 20/40；scene/enemy/sorcerer/fire_sorcerer_fireball_volley.gd:33-34,455-481 |
| 外部/未来 bleed | API 已存在 | 当前未找到敌方向玩家/植物施加 bleed 的生产调用点 |

这些 tick 对玩家遵循周期 flag，对植物仍走普通防御。死亡/离树/复活/植物移除会清理调度器目标。

### 8.3 玩家收藏品施加到敌人的状态

Enemy 使用另一套 deadline 状态表（scene/enemy/enemy.gd:1674-1767）：

- effect key 是 source_id:status_id；同 key 重施会先移除旧 modifier，再完整创建新状态。
- burn 无视配置传入的 tick_interval，固定强制为 1.0 秒（:1705-1729）。
- 到期也先于同刻跳伤（:1797-1818）。
- burn 同样只让最高 tick_damage 来源运行；较弱相位暂停（:1822-1866,1911-1941）。
- 相同伤害的 burn 只保留“字典当前迭代遇到的第一个”，没有全局调度器的 source 字典序 tie-break（:1962-1980）。

因此两个 burn 调度器在相同伤害并列时可能选择不同来源；若来源还携带不同统计/归属，行为会不稳定。应共享 StatusSourceKey 和同一比较函数。

魏世岱尔研究 burn 会传入 0.5 秒，但 Enemy 对 burn 强制改成 1 秒；这是现状兼容语义，不应在迁移时误改成双倍跳频（scene/player/weishidaier/weishidaier_skill1_bomb.gd:156-173；scene/enemy/enemy.gd:1707-1709）。

## 9. 治疗、周期治疗与紫阳花时间轴

### 9.1 治疗原语

Player._try_heal（scene/player/player.gd:2206-2234）：

- 死亡、非正数、满血拒绝；
- 封顶 max_health；
- last_healing_received 保存真实差值；
- 更新血条、health_changed、收藏品条件；
- 单机排治疗数字，多人交给 Host report。

PlantDefense.receive_healing 语义相同，但额外拒绝 proxy/removing，并拥有 revision、healing_applied 和 source Node hook（scene/plant_defense/plant_defense.gd:476-495）。

当前没有：

- 通用 HoT 状态调度器；
- 治疗强度、受疗倍率、减疗；
- 过量治疗记录；
- 吸收护盾/临时生命；
- 治疗触发复活。

所谓“周期治疗”都是收藏品或塔在定时点发起一次普通离散 heal。

### 9.2 全部当前玩家治疗来源

| 来源 | 数值/节奏 | 证据 |
| --- | --- | --- |
| 生命药瓶 | 20 | resources/config/pickups/pickup_health.tres:9,16；scene/player/player.gd:685-693 |
| Hoe 旋风 | 5，每次技能结算后；不要求击中敌人 | scene/player/hoe_cat/player_hoe_cat.gd:10-11,521-539 |
| 紫阳花 | 每跳 50，共 5 跳 | resources/config/plant_defense/hydrangea_rain_tower_config.gd:13-16；scene/plant_defense/hydrangea_rain_tower.gd:575-598 |
| 羊毛护符 | 受伤后 4，10s cooldown | resources/config/collectibles/collectible_wool_charm.tres:20-22 |
| 红蘑菇 | 普通 on-hit 吸血 2 | resources/config/collectibles/collectible_red_mushroom.tres:20-23 |
| 草药束 | on-hit 在敌人位置范围治疗 3 | resources/config/collectibles/collectible_herbal_bundle.tres:20-24 |
| 金苹果 / 烤面包 | 击杀治疗 7 / 2 | resources/config/collectibles/collectible_gold_apple.tres:20-22；collectible_warm_bread.tres:20-22 |
| 生命水晶 | 每 15s、半径 56、治疗 10 | resources/config/collectibles/collectible_life_crystal.tres:20-23 |
| 凤凰羽 | 每 15s、半径 72、治疗 14 | resources/config/collectibles/collectible_phoenix_feather.tres:20-23 |
| 日纹胸针 | 每 18s、半径 56、治疗 8 | resources/config/collectibles/collectible_sun_brooch.tres:20-23 |
| 世界树种 | 每 12s、半径 96、治疗 20 | resources/config/collectibles/collectible_world_seed.tres:20-23 |

周期收藏品第一次等待完整 interval；帧跨过 deadline 时只触发一次，然后从当前 runtime time 重新排下次，不追补漏掉的多个周期（scene/player/player.gd:3040-3065）。

### 9.3 紫阳花玩法和粒子时间轴

配置单源：

- 雨滴发射延迟 0.24s；
- 下落 0.44s；
- 玩法效果开始点 0.68s；
- 玩法持续 5.0s；
- 每 1.0s 一跳；
- 整个动作玩法结束点 5.68s。

证据：resources/config/plant_defense/hydrangea_rain_tower_config.gd:4-19,31-35。

当前准确跳点：

- 0.68s：第 0 跳，治疗、减攻、法伤；
- 1.68s：第 1 跳，治疗、减攻、法伤；
- 2.68s：第 2 跳，治疗、减攻；
- 3.68s：第 3 跳，治疗、减攻；
- 4.68s：第 4 跳，治疗、减攻；
- 5.68s：玩法结束，不再额外跳一次。

实现依据：效果启动立即执行 current_tick_index，然后按绝对动作时间安排后续跳点（scene/plant_defense/hydrangea_rain_tower.gd:450-509）。法伤窗口为 rain_duration 1.5 - 发射延迟 0.24 = 1.26s，所以只有效果相对时间 0s 和 1s 的两跳造成 5 点魔法伤害（:538-559,1094-1100）。

地面粒子匹配正确：

- ground_effect_end_timer 使用 action duration=0.68+5=5.68s（:103-110,1103-1109）。
- 落地时开始 GroundDewRise 发射，直到 5.68s 才停止（:601-629,750-772,995-1016）。
- 停止后再用 max(1.15s,particle lifetime) 淡出；当前 lifetime=1.0s，因此完全消散约为 6.83s（:22,1016-1035；scene/plant_defense/hydrangea_rain_tower.tscn:364-366）。

这符合“地面粒子至少持续到 5 秒治疗/减攻结束，并保留粒子消散期”。不应把 gameplay effect 延长到 6.83s；6.83s 只是视觉尾迹结束。

## 10. 敌人减攻、承伤增幅与持续来源

### 10.1 紫阳花减攻

每个雨幕 tick 对范围内存活敌人施加同一 source_id 的定时 outgoing_attack_damage_multiplier，duration 使用本次动作剩余时间（scene/plant_defense/hydrangea_rain_tower.gd:523-573）。

语义：

- 它是“进入时写入的定时状态”，不是每帧成员资格 aura。
- 敌人离开雨区后仍保留到 5.68s；稍后进入的敌人只得到剩余时长。
- 同一塔每跳以同 source/status key 刷新状态和 expiry。
- 多个紫阳花使用不同 source；Enemy 只取最低 multiplier，即最强减攻，不相乘（scene/enemy/enemy.gd:1149-1208）。
- 默认 multiplier=0.8，多个雨幕不会叠成 0.64。

Enemy.get_effective_attack_damage 在攻击提交时 roundi(base×最强倍率)，至少 1（scene/enemy/enemy.gd:1185-1194）。投射物通常在发射时快照该值：

- 减攻开始后，已经在飞行的旧弹仍保留原伤害；
- 减攻到期后，减攻期间发射的弹仍保留降低后的伤害；
- 近身、hitscan、光环等在各自 commit 点读取。

紫阳花被移除会立即停止自身 gameplay timer 和视觉（scene/plant_defense/hydrangea_rain_tower.gd:326-349），但已经写入敌人的定时减攻不与塔节点生命周期绑定，仍自然到期。

### 10.2 敌人承伤增幅

Enemy 的 mark 等 damage_taken_multiplier 来源是全部相乘，而不是取最强（scene/enemy/enemy.gd:1114-1146）。其 profile 在物防/魔防后乘缓存总倍率，并用 roundi（scene/enemy/enemy.gd:1659-1667）。

这与两类“最强项”不同：

- Player.damage_reduction：取最大 reduction；
- Enemy.outgoing_attack_damage_multiplier：取最低 multiplier；
- Enemy.damage_taken_multiplier：所有来源相乘。

统一状态层必须保留每个属性的合并政策，不能用一个通用“modifier list”默认全部相加或全部相乘。

## 11. 死亡、复活和生命周期副作用

### 11.1 玩家死亡后的周期效果漏洞

Player._physics_process 顺序是：

1. 更新无敌；
2. 更新临时 pickup buff；
3. 更新收藏品 runtime；
4. 更新技能充能；
5. 更新角色资源；
6. 最后才检查 is_dead 并 return。

证据：scene/player/player.gd:491-502。

具体后果：

- _collectible_runtime_elapsed 和 _collectible_periodic_elapsed 在死亡期间继续前进；
- Host 仍满足 _should_run_authoritative_collectible_effects（只看网络角色，scene/player/player.gd:3765-3770）；
- thunder/frost/archer/sakura 等周期攻击可从尸体触发；
- life crystal 等周期治疗会排除死亡自己，但仍能治疗范围内活队友；
- trigger cooldown 会继续过期；
- speed/rapid/attack 临时 pickup buff 会在死亡期间正常倒计时和失效（scene/player/player.gd:4254-4271）；
- 技能充能本身有单独 is_dead 检查，所以暂停（scene/player/player.gd:2245-2256）。

建议的结构修复点不是在每个周期效果里堆 is_dead，而是在 Player runtime 更新顺序或 authority predicate 建立统一 can_run_alive_combat_effects 条件，并明确哪些纯视觉/冷却时间允许死亡期间推进。

### 11.2 玩家死亡与复活保留/清除清单

本地死亡和多人死亡都会：

- 清 burn/bleed 与 cold；
- 结束 dash；
- 清普通无敌；
- 停射击和角色专属战斗；
- 隐藏/关闭生命与碰撞表现。

证据：scene/player/player.gd:1859-1912,4639-4666。

不会清：

- damage_reduction_modifiers；
- 已存在的月盾节点；
- 收藏品 periodic deadlines/runtime clocks；
- 收藏品 trigger cooldown 字典；
- 临时 pickup buff 剩余时间；
- 已发射的子弹和已生成的世界效果。

revive_multiplayer 会再次清 DoT/cold、恢复位置/生命/资源和可碰撞性，但不会重建或清除上述收藏品时钟/盾来源（scene/player/player.gd:1811-1847）。

### 11.3 敌人死亡

Enemy._die：

- 先置 is_dead 防重入；
- 清 cold 和全部 collectible status；
- 无条件排配置息壤奖励和配置掉落；
- emit defeated；
- 关闭 process、physics、接触集合和碰撞；
- 播放死亡音效/序列。

证据：scene/enemy/enemy.gd:3828-3854。

伤害结果目前没有 killer/cause，因此“全队奖励/掉落”和“玩家个人 kill effect”无法通过同一个 terminal intent 原子决定。统一伤害域下一阶段应让致死 DamageResult 生成 KillContext，再由 Enemy death 一次性消费；不得在多个调用点重复猜 killer。

## 12. 配置重复、隐式 DSL 与迁移调用点

### 12.1 配置重复

1. **伤害类型归属错误。** DamageType 仍定义在 EnemyConfig，但玩家、植物、基地、塔和网络共同使用；CombatTypes 已建立正确域级枚举，但旧 API 仍依赖 EnemyConfig。迁移期间必须保持 ABI，最终应让 EnemyConfig 引用域类型而不是反向拥有全局概念。
2. **玩家基础与运行时字段分裂。** PlayerCharacterConfig 配置起始生命、攻击、攻速、移速和攻击升级（resources/config/players/player_character_config.gd:22-29）；Player 场景脚本仍 export 物防、魔防、无敌时长，并硬编码技能升级/研究数组（scene/player/player.gd:15-23,95-102）。
3. **PickupConfig 过度承载。** 同一个资源同时定义基础 heal/buff、通用战斗属性、周期伤害/治疗、技能盾、条件、受伤触发、on-hit 和 kill effect，字段集中在 resources/config/pickups/pickup_config.gd:187-327。effect ID 是字符串 DSL，未知字符串在大 match 中静默 no-op。
4. **月盾减伤不在配置。** 四个道具配置半径和时长，但 50% 减伤固定在 scene/collectible_moon_shield.gd:4。
5. **旧塔脚本/资源双源。** 龙舌兰、玉米、竹筒仍保留同值默认常量和只存在于脚本的战斗数值；葡萄、紫阳花的强类型子配置是更稳健范式。
6. **敌方 burn 数值重复已由本轮解决。** CombatAttackRegistry 现在从 FireSorcererConfig 读取 burn duration/tick，并集中定义 slime burn（scene/combat/combat_attack_registry.gd:27-38,155-194）；MPGame 的 family/level/duration helper 已改成委托该注册表（scene/multiplayer/mp_game.gd:5608-5630）。MPGame 仍保留 volley family 名称和三球 source-bit 消费协议，这是接触去重/wire 语义，不再是第二份玩法数值。

### 12.2 来源 ID 风险

Player 收藏品稳定来源 ID 使用 abs(hash(runtime key))+salt+player instance ID（scene/player/player.gd:3589-3592）。Enemy 再从 source_id 通过固定偏移和 status hash 派生 slow/defense/damage multiplier/outgoing multiplier ID（scene/enemy/enemy.gd:1737-1759）。

风险：

- 整数加法/hash 可碰撞；
- 不同 modifier domain 依靠人工 salt 不重叠；
- instance ID 只在本进程稳定，不能直接作为跨会话持久身份；
- removal 只能凭同一派生公式找到来源。

应迁移为复合 StatusSourceKey，例如 owner_peer/net_entity + ability/effect ID + application serial + modifier channel；本地字典可再为 key 分配紧凑整数，不要把业务身份本身压进算术 ID。

### 12.3 建议迁移表

| 当前调用点 | 目标接口 | 必须保留的政策 |
| --- | --- | --- |
| Player.apply_damage Dictionary 壳 | DamageRequest | source_direction 约定、RANGED、拒绝原因 |
| Player.apply_periodic_damage | DamageRequest + 明确 HitPolicy | 绕过无敌/闪避、不授予无敌，但保留防御/减伤/hurt |
| Enemy.apply_damage / batch | typed request / batch spec | per-hit 防御、最低 1、overkill applied 封顶 |
| GameTowerDefense / MPGame 塔桥 | 带 source 的 DamageRequest | tower net ID、塔类型、action ID、Host-only |
| Player 收藏品/技能伤害桥 | AttackContext + DamageRequest | 是否吃 burn/bleed bonus、on-hit、kill、递归政策 |
| Enemy.apply_collectible_status | StatusRequest/StatusResult | source key、刷新、叠加、tie-break、expiry-before-tick |
| Player._try_heal / Plant.receive_healing | HealRequest/HealResult | 实际治疗封顶、来源、拒绝原因、revision、表现 |
| Enemy._die | KillContext/TerminalIntent | killer、cause、奖励、掉落、个人 kill effect 恰好一次 |
| MPGame Variant 伤害适配器 | 明确强类型 wire DTO | 不信任客户端 amount/type，稳定 wire ID，Host 重算 |

## 13. 必须锁定的兼容性约束

后续迁移或重构至少需要把以下行为写成测试：

1. 物理与魔法防御后始终至少 1 点，除非请求本身无效。
2. 玩家 RANGED 正/背倍率在防御前、roundi；玩家最强减伤在防御后、floori。
3. Enemy damage_taken_multiplier 在防御后相乘、roundi。
4. Player/Enemy/Plant 最终 applied_damage 封顶到剩余生命，生命不为负。
5. 普通玩家直伤遵守无敌/闪避并授予受击无敌；周期伤害绕过三者但保留防御和最强减伤。
6. 致死玩家伤害不触发 hurt 收藏品、不授予新的受击无敌。
7. batch 对每一击单独减物防/魔防并在致死后停止；不可把六发玉米先合并再只减一次物防。
8. burn 只运行最强来源，bleed 全来源独立；同来源刷新同时重置持续时间与首跳。
9. 状态到期与跳伤同刻时先到期；5s/1s 恰好只有 4 跳。
10. Enemy collectible burn 固定 1s；不得因调用方传 0.5s 自动变成两倍频率。
11. 玩家减伤和敌人减攻都取最强，不相乘；Enemy 承伤倍率才全部相乘。
12. 已发射投射物保留 commit 时的敌人减攻快照。
13. on-hit 在基础命中之后；某个 on-hit 杀死目标后停止剩余 on-hit，再执行 kill effects。
14. DoT、塔、区域伤害目前不会自动触发玩家 kill effects；在引入 KillContext 前不能意外改变。
15. 紫阳花玩法从 0.68s 到 5.68s，跳点为 0.68/1.68/2.68/3.68/4.68；地面粒子约 6.83s 才完全消散。
16. 联机 Host 是唯一最终生命权威；客户端预测不得提交最终生命，也不得执行权威 hurt/kill/reward 副作用。
17. DamageType 的 0/1 wire ABI 必须保持。
18. 新 overkill 契约以 applied_damage 表示真实扣血；需要理论伤害的 UI/统计显式读 resolved_damage。

## 14. 建议回归测试矩阵

### 14.1 纯解析器

- Player：方向倍率×物防/魔防×最强减伤的边界取整。
- Plant：全局物防 bonus、100 魔防、BYPASS_MITIGATION。
- Enemy：多个 damage_taken multiplier、单击 overkill、batch 逐击致死。
- request.amount=0 的 batch 仍得到正确 requested_amount/hit counts。

### 14.2 生命周期

- 玩家死亡期间 30 秒不得生成任何新权威周期攻击或团队治疗；允许推进的纯冷却另行断言。
- 死前弹体死后命中时，按明确设计断言是否触发 on-hit/kill。
- 月盾施法者死亡/复活、队友进出、自然到期的 modifier 恰好增删一次。
- 紫阳花被摧毁时，现有敌减攻按设计是立即移除还是保留到 expiry，并锁定唯一答案。
- Plant death 清 DoT、关闭 operational/collision，已在途弹体是否继续结算按来源政策测试。

### 14.3 状态

- 同 burn family 高频刷新时首跳重置。
- 两个 burn 不同伤害的暂停/接班相位。
- 相同伤害 burn 的稳定 tie-break。
- 3s 与 5s 端点无额外 tick。
- Wei burn 传 0.5s 仍按 1s。

### 14.4 多人

- 客户端预测命中/Host 闪避、客户端预测闪避/Host 命中，两种都收敛到 Host health revision。
- 非法 wire ID、无证书、过期证书、错误 projectile type、超接触容差均拒绝并下发 health correction。
- 普通、DoT、治疗、死亡、复活共享单调 player health revision。
- tower source_id 从塔提交一直保留到 lethal terminal。
- Host hurt、状态、kill/reward/drop 副作用恰好一次，客户端只重放表现。

## 15. 最终判断

纯伤害公式层已经具备可扩展的正确核心；当前剩余问题主要不在 DamageResolver，而在三类上层语义：

1. **来源与归属**：塔、收藏品、DoT、技能和玩家击杀仍没有统一 AttackContext/KillContext；
2. **生命周期**：尸体周期效果、遗留弹体、月盾和已写入减攻各自独立存活；
3. **治疗与状态结果**：仍使用 bool、可变旁路字段和字符串 DSL，没有与 DamageResult 对等的强类型结果。

下一步应优先修复死亡玩家仍触发权威周期效果，并贯通 source_id/source_type 到敌人 DamageRequest 和 lethal terminal；这两项完成后，再迁移 HealResult 与 StatusSourceKey，收益会明显高于继续扩展 DamageResolver 本身。
