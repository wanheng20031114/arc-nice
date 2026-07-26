# 统一伤害重构严格代码审查

审查基线：当前工作区（HEAD `f029e2d` 加未提交的伤害重构）。范围限定为 `scene/combat/*`、`Enemy` / `Player` / `PlantDefense` 迁移、`MpGame` 的 player-hit claim / certificate / result，以及直接覆盖这些路径的测试。

## 结论

- 未发现会直接破坏存档、崩溃整个会话或让客户端任意指定生命值的 P0 问题。
- 纯数值 resolver、三类实体的普通伤害/减伤/过量伤害迁移，以及新加入的跨通道生命 revision fence，整体结构清楚；现有 A/B 与场景测试对这些部分提供了较强的回归保护。
- 仍有 **4 个 P1**，全部集中在“客户端命中声明被 Host 采纳”的边界：客户端仍能影响权威方向倍率；证书没有证明真实接触；不同投射物互斥的消费语义没有建模；拒绝/纠正路径会产生可靠广播放大和错误的本地无敌帧。
- 另有 **3 个 P2**：代理实体的权威接口不一致、batch result 的字段契约不自洽、现有 claim 测试绕过了真正的 RPC→结算→纠正链。

## Findings（按严重度排序）

### [P1] Host 仍使用客户端提供的方向参与权威伤害倍率

证据：

- `scene/multiplayer/mp_game.gd:7369-7405` 的 RPC 直接接收 `impact_direction`。
- `scene/multiplayer/mp_game.gd:7441-7465` 的 certificate 只覆盖 `damage`、`damage_type`、`source_type`，重新构造 request 时仍保留客户端方向。
- `scene/multiplayer/mp_game.gd:7338-7341` 把该方向反向写成 `DamageRequest.source_direction`。
- `scene/player/player.gd:1120-1134` 用 `source_direction` 计算正面/背面远程伤害倍率。
- 当前实际配置中 `resources/config/collectibles/collectible_nine_eleven.tres:19-20` 正面倍率为 `1.3`，背面倍率为 `0.5`。因此客户端可以把真实正面命中伪报为背面，将 Host 的权威结算从 1.3 倍改成 0.5 倍；发送零向量也能绕开方向倍率。

影响：

- 伤害数值已经不再由客户端直接上报，但客户端仍能通过方向字段改变 Host 最终 `applied_damage`，Host 权威边界没有闭合。
- 这是可主动利用的减伤漏洞，不只是表现误差。

最小修复建议：

- certificate 必须返回 Host 推导的 `impact_direction/source_direction`；`_apply_player_hit_report` 在 require-certificate 分支完全忽略客户端方向。
- 对普通投射物可从 Host 投射物速度/上一帧到当前帧的运动段推导；复合投射物必须使用实际命中的 component，而不是父节点中心。
- 增加测试：同一个合法 certificate 分别提交相反方向和非有限/零方向，Host 的 `resolved_damage/applied_damage` 必须完全相同，并与 Host 几何方向一致。

### [P1] certificate 只证明“节点在 96 像素内”，没有证明接触；claim 又在结算前消费事件

证据：

- `scene/multiplayer/mp_game.gd:7626-7670` 只检查记录存在、未过期、类型匹配、Host 节点存活，以及“投射物节点中心距离玩家不超过 96”。RPC 没有 contact timestamp、客户端命中位置或 Host 历史状态，因此无法做回滚/扫掠验证。
- `scene/multiplayer/mp_game.gd:7510-7552` 在调用 `player_node.apply_combat_damage()` 之前，先设置 fire/frost 的 consumed 状态，并把普通事件写入 `_processed_player_hit_ids`。
- `scene/enemy/sorcerer/fire_sorcerer_fireball_volley.gd:302-314` 实际移动的是 3 个 child `Area2D`；父 `Node2D.global_position` 不随火球移动。certificate 却检查 `_known_projectiles[source_id]` 的父节点位置。这会同时产生两类错误：真实远距离 child 接触被误拒；父节点附近但 child 根本没接触时被误收。

可复现风险：

1. 玩家处于 Host 无敌帧或必定闪避状态。
2. 某个可声明投射物进入 96 像素宽容区，但尚未真实接触。
3. 客户端提前 claim；Host 先消费 source/contact，随后 `Player.apply_combat_damage` 因无敌/闪避拒绝。
4. 稍后 Host 的真实碰撞因 dedup/consumed 已被写入而不再结算。客户端由此可以主动“吃掉”未来命中。

影响：

- claim 从“提示 Host 检查”变成了“客户端选择命中时刻”；96 像素范围远大于实际碰撞形状。
- fire volley 的父/子结构让当前证书在正常网络下也可能系统性误拒合法 claim。

最小修复建议：

- 最稳妥的最小策略是：client claim 只作为 hint 唤醒 Host 检查，只有 Host 的 shape/sweep 判定具体 component 与目标相交后才创建 `DamageRequest` 并消费事件。
- 若必须做延迟补偿，wire 至少需要有界的 Host-time/sequence；Host 保存短窗口的玩家与投射物/component 运动历史，再对碰撞形状做回滚扫掠。单纯扩大距离阈值不能作为攻击证书。
- consumed/dedup 应在“几何接触证书成立”之后原子提交；伤害因真实接触时的无敌/闪避被拒绝，仍可消费投射物，但不能让提前伪造的接触先消费。
- 增加测试：96 像素内但 shape 未相交必须拒绝；真实 child 火球远离 parent 仍可认证；无敌期间的提前 claim 不能阻止随后 Host 的真实 contact 流程。

### [P1] registry 没有建模 single-hit / per-target / component-mask / Host-area 的互斥消费语义

证据：

- `scene/multiplayer/mp_game.gd:5717-5727` 对 fire/frost 使用 source 级 key，而其余攻击统一使用 `source_id:target_peer_id:source_type`，默认允许同一 source 对不同玩家各结算一次。
- `scene/multiplayer/mp_game.gd:7626-7670` 的通用 certificate 不检查也不原子更新 projectile record 中已有的 `confirmed_hit_consumed`，claim 成功后也不 retire Host 投射物。
- 单发投射物本体的语义不同：`scene/enemy/capoo/capoo_ak47_bullet.gd:271-299` 和 `scene/enemy/yuanshi_insect/yuanshi_insect_fire_projectile.gd:121-155` 都在首次 body contact 后 consume 整个投射物。
- 另一方面，RPG / mage explosion、Linglan orb 又确实是 per-target/area 语义，不能用一个全局 boolean 粗暴统一。

影响：

- 两个位置重叠/相近的远端玩家可以分别提交同一 AK 或元始单发弹的 claim，Host 会按两个 target key 分别结算；这与 Host 本体“首碰即销毁”语义不一致。
- 如果简单补一个通用 `confirmed_hit_consumed`，又会破坏 RPG/orb 的合法多目标伤害。当前宽 registry 缺少的正是这组互斥规则。

最小修复建议：

- 在 `CombatAttackRegistry` 的 certificate 定义中显式加入命中策略，例如 `SINGLE_CONSUME`、`PER_TARGET`、`COMPONENT_MASK`、`HOST_AREA_ONLY`。
- `SINGLE_CONSUME` 在 Host admission 时原子 claim record 并 retire/disable Host 投射物；`PER_TARGET` 使用有界 target set；`COMPONENT_MASK` 使用具体 component bit；`HOST_AREA_ONLY` 不开放 client claim。
- 增加表驱动测试，至少覆盖：同 source 两玩家、同 target 重复、三火球 component bit、RPG/orb 多目标；每个 wire ID 都必须声明且验证一种策略。

### [P1] rejected claim 会推进生命 revision 并可靠广播所有客户端；correction 还隐式授予本地 hit invincibility

证据：

- `scene/multiplayer/mp_game.gd:7447-7452`、`7497-7503`、`7522-7530`、`7541-7549` 在无效证书或重复 contact 时调用 `_send_authoritative_player_health_correction()`。
- `scene/multiplayer/mp_game.gd:7673-7694` 每次 correction 都 `_next_player_health_revision()`，然后通过 `_rpc_to_connected_clients` 可靠广播给所有客户端，即使生命、死亡和状态都没有变化。
- correction 只发送 7 个参数；`scene/multiplayer/mp_game.gd:7698-7708` 的第 8 个参数 `grant_hit_invincibility` 默认是 `true`。因此目标客户端收到零伤害 correction 时，只要尚未满血，仍可能在 `scene/multiplayer/mp_game.gd:7745-7753` 启动本地 hit invincibility。
- `scene/multiplayer/mp_game.gd:132-136` 允许每个 peer 每秒 128 个 claim、burst 48。无效 claim 因而可放大成 `O(客户端数 × claim 数)` 的可靠广播和 revision-only snapshot delta。
- `combat_outcome` 虽已上 wire，但 `scene/multiplayer/mp_game.gd:7709-7710` 立即丢弃，不能驱动客户端有针对性的 prediction rollback。

影响：

- 恶意或故障客户端能制造持续的可靠流量、revision churn 和所有观察端的无意义生命事件，和本次“降低通信压力”的目标相反。
- correction 会短暂/反复制造错误的本地无敌表现和预测状态；Host canonical iframe 没有同步增长，因此会进一步增加预测抖动。

最小修复建议：

- 没有权威状态变化的 rejected claim 不应广播给其他观察端，也不应占用 canonical health revision。
- 若目标客户端确需撤销预测，使用 target-only、带 `source_id/claim_sequence` 的 correction/ack；显式 `grant_hit_invincibility=false` 并传递 rejection outcome。可对同目标 correction 合并/限频。
- 若暂时不新增 wire，至少立即把 correction 改为 target-only，并完整传第 8-10 参数（`false, false, reason`）；同时降低 invalid admission 的纠正频率。
- 增加测试：连续 48/128 个 invalid certificate 不得产生全员可靠广播或 48/128 次 health revision；零伤害 correction 不得改变 invincibility；客户端必须能区分 `UNTRUSTED_SOURCE/DUPLICATE_EVENT/INVULNERABLE/DODGED`。

### [P2] “统一权威 sink”在三类实体上仍不是同一接口契约

证据：

- `scene/plant_defense/plant_defense.gd:158-178` 在 `apply_combat_damage` 内显式拒绝 multiplayer proxy，并返回 `NOT_AUTHORITY`。
- `scene/enemy/enemy.gd:912-953` 在同名 sink 中没有 proxy/authority 检查；client proxy 可直接改变 health 并触发反馈/死亡。
- `scene/bullet.gd:238-253` 在 multiplayer report 因 net-id/场景接口等原因失败时，会直接调用 Enemy sink，因此 spawn/routing 异常可以退化为仅客户端修改代理敌人。
- `Player.apply_combat_damage` 同时承担 Host canonical 和 client prediction；`DamageResult` 本身没有 execution provenance，调用方无法从类型上区分“预测接受”与“权威接受”。

影响：

- 同名 API 对 Plant 表示“只允许权威结算”，对 Enemy 表示“任何实例都可结算”，对 Player 则同时表示 prediction/canonical。统一接口无法真正成为 Host 权威边界，未来调用方很容易把预测 result 当作 canonical result。

最小修复建议：

- 将 authority admission 放到统一 gateway，或给 request 加由本地代码生成、不可上 wire 的 execution context；canonical sink 对 proxy 一律返回 `NOT_AUTHORITY`。
- Player prediction 使用显式 `predict_combat_damage()` / presentation-only result，不触发 canonical lifecycle；Host 才调用 canonical sink。
- 增加 proxy contract 测试：Enemy/Plant canonical sink 都不得改 proxy health；Player prediction result 必须标记 `predicted=true`，且不能被 Host result consumer 当成确认结果。

### [P2] batch result 的 requested 字段只统计“死亡前处理到的前缀”，与字段名和 scalar 契约不一致

证据：

- `scene/combat/damage_resolver.gd:87-93` 在处理每一组时才累加 `requested_amount/requested_hit_count`。
- `scene/combat/damage_resolver.gd:126-127` 一旦目标死亡立即 break，因此后续合法输入组完全不计入 requested 字段。
- 同时 batch 的 `DamageRequest.amount` 通常为 0（例如 Enemy wrapper），真实输入另由两个平行数组承载；`DamageResult.request` 因而不能完整重放该请求。

影响：

- `requested_hit_count` 对 `[致死组, 后续组]` 返回的是前缀而非调用方实际请求总数；统计、反作弊审计和网络聚合无法依赖统一 result 字段。
- scalar 与 batch 虽共享类型，语义并不相同，后续很容易再次重建解释规则。

最小修复建议：

- 先独立扫描所有有效 group，计算完整 requested totals，再执行有 lethal short-circuit 的 accepted/resolved 计算。
- 更稳妥的是新增强类型 `DamageBatchRequest` / `DamageHitGroup`，让 result 持有可重放的完整请求；避免 `request.amount == 0` 加平行数组的半统一接口。
- 增加“第一组致死、后两组仍合法”的断言：requested totals 覆盖全部输入，accepted totals 只覆盖致死前缀。

### [P2] 当前 claim 测试只测静态 admission，没有覆盖真正的权威链路

证据：

- `dev_tools/damage_claim_admission_smoke_test.gd:3-5` 明确说明测试“不对 gameplay entity 应用伤害”。
- `dev_tools/damage_claim_admission_smoke_test.gd:213-297` 只用裸 `Node2D`，并把离玩家 32 像素的节点视为合法；它没有实际碰撞形状、运动段、component、Player 正背面倍率或 projectile consume 生命周期。
- 代码库中对 `_rpc_player_hit_report/_apply_player_hit_report` 的其它测试主要是源码签名/参数捕获；没有通过真实 remote sender 身份完成 claim→certificate→DamageRequest→DamageResult→correction 的两端测试。

影响：

- 当前测试会把“96 像素内即合法”固化为正确行为，同时无法发现本报告前四项问题。

最小修复建议：

- 新增至少一个真实 ENet Host + Client 的小场景测试，使用正式 projectile scene 和 Player scene，不用裸 Node 伪造 certificate。
- 表格至少包含：伪造方向、未接触但在容差内、父/子 volley、同 source 两 target、iframe/dodge 前置、重复 claim、invalid spam、accepted/rejected result 的 revision 与 correction。
- A/B 除带宽大小外，还要比较旧 Host 模拟路径与新 claim 路径在同一 Host 世界状态下的 `accepted/reason/resolved/applied/health/death/status`。

## 审查确认通过的部分

- `DamageResolver` 的物理 flat defense、魔法百分比 defense、Player ranged pre-multiplier、Player strongest reduction post-multiplier、Enemy post-multiplier及对应 rounding 顺序，与迁移前实现一致；现有随机 A/B 对 scalar/batch 已覆盖大量组合。
- Enemy / Player / Plant 的 overkill 统一为实际 health delta，重复 lethal request 不会重复触发死亡；Linglan 非致死 health signal 迁移有场景测试。
- Player snapshot 的 `health_revision` 已进入 codec，并通过独立 applied cursor 防止跨 channel 回退；Enemy 代理在“当前无治疗/复活”不变量下使用生命单调下降 fence。此次复核未再发现该部分的高风险顺序错误。

## 建议修复顺序

1. 先关闭客户端方向对数值结算的影响（P1-1），这是最直接的 Host 权威漏洞。
2. 将 claim 改成 Host 几何验证后的 hint，并调整 consume 提交时点（P1-2）。
3. 在 registry 中引入明确 hit policy，逐个 wire ID 迁移（P1-3）。
4. 把 rejected correction 改为 target-only、无 iframe、可合并的 prediction ack（P1-4）。
5. 补真实双端测试后，再收紧 proxy/canonical API 和 batch request 类型。

## 快速复核附录（P1-1 / P1-4 修复后）

### P1-1：已封闭客户端直接控制权威方向倍率

- `scene/multiplayer/mp_game.gd:7458-7469` 已用 certificate 返回的 `impact_direction` 覆盖 RPC 输入，再构造 `DamageRequest`。
- `scene/multiplayer/mp_game.gd:7678-7684` 的方向由 Host 投射物位置指向 Host 玩家位置，语义与现有 impact/source-direction 约定一致。
- 因此客户端伪造相反方向或零方向已不能改变 Player 的正面/背面倍率。剩余的“当前时刻点距离”和 fire-volley parent/component 不匹配属于 P1-2 的几何准确性，不再是客户端直接控制数值。

### P1-4：主要问题已修复；保留 claim 时仍有短暂 prediction iframe 残留

- `scene/multiplayer/mp_game.gd:7688-7739` 已复用当前 health revision、只回复目标 peer、显式传 `grant_hit_invincibility=false` 和 rejection reason，不再产生全员广播及 revision churn。
- `scene/multiplayer/mp_game.gd:7762-7782` 对 correction 使用独立分支，同 revision 可用于恢复预测 health，又不会占用 reliable presentation cursor；与 snapshot 的 applied cursor 顺序兼容。
- 剩余限制：`Player.set_multiplayer_health_state()` 只修正 health/death，不清除客户端预测命中已经启动的 `invincibility_time_left`。下一份 realtime snapshot 会纠正它；不能在 correction 中无条件清零，否则可能误清此前真实 Host 命中的合法 iframe。若继续保留 claim，需要 claim sequence/prediction token 才能精确回滚对应 iframe。

### 本轮最安全决定：直接禁用 client → Host player-hit claim lane

建议本轮禁用，而不是继续以 96 像素阈值上线。理由：

1. certificate 已要求 `_known_projectiles[source_id]` 中存在 Host 活投射物；这证明所有可通过该 lane 的攻击本来就有 Host 模拟实例，不存在“只有客户端知道的权威命中”。
2. contact、hitscan、area 已明确 Host-only；Linglan skill1 客户端代码也已经主动不上报。关闭 lane 不会移除唯一权威来源。
3. P1-2 要安全修复需要具体 component 的碰撞形状、时间戳和 Host 历史扫掠；P1-3 需要逐攻击的 `SINGLE/PER_TARGET/COMPONENT_MASK/HOST_AREA` 策略。这两者都不适合用本轮临时补丁伪装完成。
4. 关闭后仍可保留客户端本地 health/受击预测；Host 实际命中走现有 `request_multiplayer_player_damage` 的 Host 分支，误预测会被同 revision realtime snapshot 收敛。

建议采用双保险 fail-closed：

- `request_player_hit_report()` 不再发送 RPC；
- `_rpc_player_hit_report()` 保留协议签名但立即拒绝，以防旧版或恶意客户端直接调用；
- Host 本地 `_apply_player_hit_report(... require_attack_certificate=false)` 保持不变；
- 不必为此再次更改协议参数，relay parity 也可保持；测试应改为断言 client request 不出包、直接 RPC 不改变 health/revision/contact record。

如未来重新启用，必须先同时完成 P1-2 与 P1-3，并用真实双端/真实 projectile scene 测试，而不是恢复 96 像素 proximity admission。

## 最终处置状态

上述最安全决定已经落地：

- 客户预测路径不再调用 `request_player_hit_report()`；
- `request_player_hit_report()` 保留为不发送的协议兼容壳；
- `_rpc_player_hit_report()` 保留五字段签名但立即返回，不进入 canonical sink；
- 96 像素 certificate、claim rate bucket、claim correction 和远端消费路径均已删除；
- Host 本地 live projectile/contact 模拟仍直接进入可信结算入口；
- `damage_claim_admission_smoke_test.gd` 现在锁定“发送端不出包 + Host RPC fail closed”，生产 player-hit claim 上行为 0 bytes。

因此本报告 P1-1 与 P1-4 已直接修复，P1-2 与 P1-3 对 player-hit claim 的攻击面已通过禁用 lane 消除。若未来重新开启，该风险会重新成立，必须先完成真实 Host 几何证书和逐攻击消费策略。
