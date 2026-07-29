# 统一伤害结算架构与验证报告

> 日期：2026-07-26
> 范围：玩家、敌人、植物、基地的伤害数值结算；多人玩家受伤的 Host 权威边界；伤害反馈、死亡和生命同步的相关路径。
> 协议版本：v21。

## 1. 结论

本轮没有继续在各个攻击脚本中复制公式，而是把伤害域拆成四层：

1. `DamageRequest`：一次可信伤害请求的统一输入；
2. `DamageTargetProfile`：目标把自身防御和倍率显式折叠为数值阶段；
3. `DamageResolver`：无节点、无随机、无表现、无网络副作用的纯结算器；
4. `DamageResult`：统一返回接纳状态、拒绝原因、各阶段数值、真实生命差和致死结果。

`Player`、`Enemy`、`PlantDefense` 现在都公开同名的 `apply_combat_damage(request)`，基地也直接调用同一解析器。旧的 `apply_damage`、`receive_damage` 等接口保留为兼容适配器，但不再各自重建物理/法术防御公式。

多人玩家受伤也从“客户端上报伤害、扣血后生命和死亡结果”改为“客户端只维护本地弹体表现，Host live simulation 独占命中、闪避、生命和死亡结算”。客户端 player-hit 与 enemy-hit claim 均已完全禁用；本地假阳性接触只让对应视觉弹体退场，不再预测生命、死亡、无敌或闪避结果。这样同时关闭了权威漏洞，并把两条命中声明的生产上行流量降为零。

## 2. 调查范围与基线问题

调查覆盖：

- 敌方接触、弹体、范围、射线、Boss 技能和状态跳伤；
- 玩家普通攻击、技能、收藏品、植物塔、批伤和持续伤害；
- 玩家、敌人、植物、基地四类承伤目标；
- 闪避、无敌、正背面远程修正、物防、魔防、额外减伤、承伤倍率和最低伤害；
- 伤害数字、音效、生命信号、死亡、奖励、掉落和多人反馈；
- 客户端命中报告、Host 攻击记录、去重、生命 revision、快照和可靠终结事件；
- 既有 smoke test、真实实体 fixture、协议契约和可用于 shadow A/B 的旧公式。

完整只读证据分别保存在：

- `reports/_audit_work/damage_enemies.md`
- `reports/_audit_work/damage_players_plants.md`
- `reports/_audit_work/damage_multiplayer_tests.md`
- `reports/_audit_work/damage_snapshot_ordering.md`

基线的根因不是配置没有资源化，而是相同概念没有唯一所有者：

- 物理/魔法公式在 Player、Enemy、PlantDefense 和基地分别实现；
- 闪避、无敌、方向修正、状态和死亡副作用与数值公式混在同一入口；
- `bool` 同时表达“扣血成功”“事件已消费”“本端不负责”等互斥语义；
- 单击和批伤依赖 `last_damage_taken` 这样的可变旁路字段传递结果；
- 伤害类型定义在敌人配置域，却被玩家、植物、基地和网络共同使用；
- 多人玩家受伤让客户端发送最终血量、死亡和实际伤害，Host 没有真正重算；
- source type 以字符串和多处硬编码表存在，元素状态数值可能和资源配置漂移；
- 多条网络 channel 会写同一个生命字段，但原先没有统一的跨通道因果依据。

## 3. 新的领域契约

### 3.1 CombatTypes

`scene/combat/combat_types.gd` 统一了：

- `DamageType`：显式 `PHYSICAL = 0`、`MAGIC = 1`，保持旧枚举和 wire ABI；
- `DamageFlag`：周期、远程、绕过无敌、绕过闪避、绕过防御、不授予受击无敌、抑制粒子；
- `RoundingMode`：floor、nearest、ceil；
- `DamageRejectionReason`：无效请求、无效伤害、死亡目标、不可用目标、非权威端、无敌、闪避、重复事件、不可信来源。

未知伤害类型在当前兼容期仍归一为物理。以后若新增真实伤害等类型，必须通过显式 wire ID 和协议升级扩展，不能依赖枚举顺序。

### 3.2 DamageRequest

`scene/combat/damage_request.gd` 携带：

- 原始伤害与类型；
- 本地 source Node、稳定 source ID、受限 source type；
- impact direction 与 source direction；
- 行为 flags。

方向在写入和读取时都做有限数检查并归一化。Node 引用不跨网络，网络只传稳定标量身份。

### 3.3 DamageBatchRequest

`scene/combat/damage_batch_request.gd` 是 `DamageRequest` 的有序批伤子类型，保存配对的 `damage_amounts` 与 `hit_counts`。它没有另起第二套入口或解析器：目标仍调用同一个 `apply_combat_damage(request)`，`DamageResolver.resolve()` 在纯函数层识别批请求。

批请求的 `requested_*` 表达完整有效意图，`accepted_*` 表达致死前实际消费的有序前缀；目标不可用、非权威或已经死亡时，拒绝结果也不会丢失原始总伤害和总命中数。最低伤害允许为 0 的零伤害组会显式拒绝，不会进入除零路径。

### 3.4 DamageTargetProfile

`scene/combat/damage_target_profile.gd` 把目标差异收敛为显式阶段：

```text
raw amount
  -> pre-mitigation multiplier + rounding
  -> physical flat defense / magic percentage defense
  -> post-mitigation multiplier + rounding
  -> cap by current health
```

玩家的远程正背面倍率属于防御前阶段；玩家收藏品额外减伤和敌人承伤倍率属于防御后阶段。各目标原有取整顺序因此可以在共用解析器内保持，而不是强行改成一套错误的近似公式。

### 3.5 DamageResult

`scene/combat/damage_result.gd` 明确区分：

- `requested_amount`：完整有效输入的请求总量，即使 batch 在中途致死也不截断；
- `adjusted_amount`：防御前倍率后的值；
- `mitigated_damage`：物防/魔防后的值；
- `resolved_damage`：完整公式结果；
- `applied_damage`：实际生命差，封顶到剩余生命；
- `health_before` / `health_after`；
- `accepted` / `rejection_reason` / `lethal`；
- batch 的请求命中数与实际接纳命中数。

表现、网络、统计若表达真实扣血，应使用 `applied_damage`。理论爆发或 overkill 必须显式使用 `resolved_damage`。

### 3.6 DamageResolver

`scene/combat/damage_resolver.gd` 是纯函数层，刻意不拥有：

- Node 或场景树；
- 随机闪避；
- 无敌状态；
- 动画、粒子、音效或伤害数字；
- 信号和死亡生命周期；
- RPC、revision 或奖励。

这样同一输入可被单元测试、Host、回放、shadow A/B 和未来确定性模拟复用。

批伤按“每击先减防，再乘命中数”的旧语义结算，并在致死处停止接纳后续命中。`requested_*` 始终统计所有有效配对输入，`accepted_*` 只统计致死前真正消费的有序前缀。它不会把整批伤害先相加后只减一次防御。

## 4. 目标端统一入口

### Player

`Player.apply_combat_damage()` 的顺序为：

1. 请求、死亡、伤害量校验；
2. 冲刺/受击无敌判定；
3. 通用闪避与远程收藏品闪避；
4. 构造目标 profile；
5. 调用纯解析器；
6. 应用生命、数字、血条、信号和收藏品受伤效果；
7. 致死或按 flag 授予受击无敌。

周期伤害使用明确组合：

```text
PERIODIC
| BYPASS_INVULNERABILITY
| BYPASS_DODGE
| NO_HIT_INVINCIBILITY
```

它仍经过防御与最强额外减伤，保持旧玩法。

### Enemy

`Enemy.apply_combat_damage()` 同时接收单击 `DamageRequest` 和有序 `DamageBatchRequest`，实体仍负责受击反馈、音效、死亡和同步钩子。旧 `apply_damage_batch()` 仅构造批请求再进入同一入口，不再存在平行的实体级批结算接口。`last_damage_result` 在同步死亡信号前写入，因此可靠 terminal 可以读取最后一次结构化致死结果。

### PlantDefense

`PlantDefense.apply_combat_damage()` 会显式拒绝客户端 proxy，并统一处理普通伤害与 `BYPASS_MITIGATION` 伤害。生命 signal、health revision、状态钩子和死亡仍只在权威端触发。

### 基地

基地扣血通过同一 resolver，以 `BYPASS_MITIGATION` 表达当前无防御规则；基地失败生命周期仍归塔防运行时所有。

### 兼容层

既有攻击脚本仍可调用：

- `Player.apply_damage()` / `apply_periodic_damage()`；
- `Enemy.apply_damage()` / `apply_damage_batch()`；
- `PlantDefense.receive_damage()` / `receive_unmitigated_damage()`。

这些函数现在只负责把旧参数转换成 `DamageRequest`，所有数值规则最终汇入新入口。这样避免一次性改动数百个攻击调用点，同时阻止新旧公式继续分叉。

## 5. Host 权威和通信协议

### 5.1 明确信任边界

玩家受伤的最终边界是：客户端只维护本地弹体/接触表现，Host 的 live projectile/contact/hitscan/area 模拟是唯一命中事实，只有 Host 本地代码能构造并提交可信 `DamageRequest`。客户端不会先扣血、先死亡或重跑闪避 RNG；Host 确认 `DODGED` 后，客户端只播放一次无状态闪避反馈。

客户端不再发送：

- damage；
- damage type；
- 扣血后 health；
- dead；
- applied damage；
- 自增 hit revision；
- 任意 source type 字符串。
- player-hit claim 本身。

协议 v21 仍保留五字段 `_rpc_player_hit_report` 兼容签名：

```text
source_id
player_peer_id
attack_wire_id
impact_direction
damage_flags
```

但发送端 `request_player_hit_report()` 和 Host RPC handler 都是 fail-closed no-op：当前客户端不会发送，旧版或恶意客户端即使直接调用，Host 也不会进入伤害结算。Host 本地碰撞回调直接进入 `_apply_player_hit_report()` 的可信路径。

敌人受伤采用同一边界。客户端发射请求只包含发射证据，Host 重建实际弹体并使用 Host 碰撞结果选择敌人；`request_enemy_hit_report()` 在客户端不发 RPC，保留的 `_rpc_enemy_hit_report` 兼容壳同样 fail closed。真实联机探针已验证“客户端发射 → Host 重建 → Host 碰撞扣血 → 所有端收到一致生命结果”。

### 5.2 有界攻击注册表

`scene/combat/combat_attack_registry.gd` 保留 16 类弹体的显式稳定兼容 ID，避免协议壳或未来审计工具因枚举重排产生歧义；这些 ID 当前不具备伤害 admission 权限。接触、弹体、hitscan 和范围攻击全部由 Host 模拟。

注册表同时统一：

- wire ID 与 source type 双向映射；
- Host 记录中的 projectile type；
- 伤害类型；
- 火史莱姆、普通/精英火术士燃烧数值；
- 冰系 cold 归类。

火术士燃烧直接读取资源配置，避免联机常量与 `.tres` 漂移。

### 5.3 为什么没有采用“96 像素近似证书”

实现中间态曾尝试用“Host record 存在、类型匹配、未过期、live Node 距目标不超过 96 像素”接纳客户端命中。严格复审后没有保留这个方案，因为它仍不是碰撞证明：

- 没有 claim 时间戳、轨迹历史、swept shape 或障碍物顺序；
- 火术士真正移动的是三个 child Area，父 Node2D 中心不能代表单球接触；
- 单发、per-target、AOE、component mask 需要不同的原子消费策略；
- 客户端可提前 claim，在闪避/无敌时消费投射物，压掉稍后的真实 Host 接触。

因此本轮选择直接禁用该入口，而不是用“看起来像校验”的距离判断冒充 Host 权威。若未来确需延迟补偿，必须同时引入 Host 轨迹回滚、具体碰撞形状和按攻击定义的 hit-consumption policy。

### 5.4 协议压力 A/B

在相同 Godot Variant framing 下：

- 旧 10 字段客户端结果报告：124 bytes；
- 五字段兼容壳若编码：52 bytes；
- 当前生产 player-hit claim 上行：0 bytes；
- 当前生产 enemy-hit claim 上行：0 bytes（禁用壳若编码同为 52 bytes）；
- 高频客户端状态 RPC：188 bytes -> 104 bytes，移除了 health/dead/invincibility/xirang/技能和战斗形态等 Host 权威字段；
- 两条命中声明相对旧结果上报都减少 100%。

当前协议为 v21，relay stub 和 RPC parity 契约已同步更新。

### 5.5 跨通道生命顺序

可靠伤害/治疗/复活事件和实时玩家快照位于不同 ENet channel，单独依靠每条 channel 内有序并不能阻止旧快照覆盖新伤害。本轮为 `SnapshotManager.PlayerState` 增加了与可靠事件共用的 `health_revision`：

- Host 把同一 `_player_health_revisions` 写入实时快照；
- 客户端分别维护“已处理可靠事件游标”和“已应用生命状态游标”；
- 可靠结果先到时，旧快照只更新移动、技能等实时字段，不回滚生命；
- 新快照先到时，旧可靠结果不回滚生命，但仍可播放对应伤害反馈；
- revive 保留可靠生命周期语义，不由普通快照偷偷替代复活动画和清理流程。

Player meta 从 38 增加到 42 bytes，即每个快照实体增加 4 bytes。绿色史莱姆引入同一 net-id 生命周期内的权威回血后，Enemy 也使用显式 `health_revision`：Host 的伤害、回血、可靠反馈与实时快照共用敌人节点上的递增修订号，Client 只接受比当前代理更新的生命状态。完整敌人 keyframe 记录因此为 24 bytes；每包上限调整为 46 条，连同 `uint16` 计数共 1106 bytes，仍低于 1200-byte 应用层预算。该屏障允许生命合法上升，同时拒绝旧伤害反馈或旧快照回滚新状态。

## 6. 兼容性与有意变化

下列语义由自动 A/B 锁定：

- 物理伤害：`max(amount - physical_defense, 1)`；
- 法术伤害：`max(floor(amount * (100 - magic_defense) / 100), 1)`；
- 玩家远程方向倍率：防御前 `roundi`；
- 玩家额外减伤：防御后 `floori`，多个来源只取最强，最高 95%；
- 敌人承伤倍率：防御后 `roundi`；
- batch：逐击减防并在致死时停止；
- Player DoT：绕过无敌与闪避，不授予新无敌，但仍吃防御和额外减伤；
- Plant proxy：返回 `NOT_AUTHORITY`，不改变生命；
- Linglan：每次成功伤害仍只发一次 health changed。

有一项有意修正：Enemy 过量伤害的数字和网络反馈现在显示真实 `applied_damage`，生命稳定为 0；旧实现可能显示完整 overkill，并短暂留下负生命。新的行为与 Player、Plant 和结构化结果契约一致。

## 7. 测试策略与结果

### 7.1 纯公式 shadow A/B

`dev_tools/damage_resolver_ab_smoke_test.gd`

- 固定 seed：20260726；
- 3000 个随机单次案例；
- 400 个随机 batch 案例；
- 对比迁移前玩家、敌人、植物公式和批伤 oracle；
- 覆盖防御边界、倍率、取整、最低伤害、过量伤害和 lethal short-circuit。

结果：通过。

### 7.2 真实实体流水线

`dev_tools/damage_pipeline_smoke_test.gd`

覆盖 Player、Enemy、Agave PlantDefense 和 Linglan 的真实场景实例，包括旧 wrapper 等价性、物理/魔法、方向倍率、周期 flag、proxy 拒绝、绕防、health revision、过量伤害和单次死亡信号。

结果：通过。

### 7.3 Host admission 与协议安全

`dev_tools/damage_claim_admission_smoke_test.gd`

覆盖：

- 16 个 wire ID 的全量双向映射；
- 未知/Host-only source fail closed；
- RPC 精确五字段，禁止客户端结果字段；
- player/enemy 客户发送壳都不会调用 RPC；
- player/enemy Host RPC 壳都不会调用 canonical sink；
- 客户端假阳性接触不会写生命、死亡、无敌或闪避状态；
- 高频客户端状态 RPC 不再携带 Host 权威战斗字段；
- 旧/新 wire payload 编码 A/B。

结果：通过，旧命中结果 124 bytes -> 当前生产 0 bytes；保留的五字段兼容形态为 52 bytes，但不发送。客户端状态包同时由 188 bytes 降到 104 bytes。

### 7.4 跨模块回归

通过的重点测试包括：

- multiplayer game mode、runtime metrics、protocol snapshot、relay RPC parity；
- fire/frost sorcerer network contact；
- terminal ID lifecycle 与真实 batch 致死 terminal；
- damage-over-time status targets；
- enemy/plant combat、bamboo mortar combat system；
- slime variants、stone golem/elite、yuanshi fire；
- collectible effects/runtime/cache；
- Linglan boss 与 skill 1-4；
- damage number、slime、plant 等迁移早期聚焦 smoke test；
- Hoe Cat 近战/旋转剑与 Corn Machine Gun 防御轮次测试已迁移到统一结果/解析器契约并通过。

`dev_tools/damage_snapshot_ordering_smoke_test.gd` 另外枚举了可靠事件先到、快照先到、等 revision、旧事件只保留反馈、敌人 CH3/CH7 生命反序等场景，结果通过。

真实 `Host + 3 clients` LAN full probe 连续两次通过，四端 stderr 均为空。该探针覆盖：客户端移动与发射、Host 重建真实弹体并碰撞权威敌人、全端敌人生命/移除/奖励同步、Host 通过统一 `_apply_player_hit_report` 对 client2 产生结构化致死结果，以及三台客户端按同一 health revision 观察死亡、复活和复活无敌结束。探针敌人仅冻结 AI 移动并对齐真实碰撞体，没有用测试代码替代弹体命中或敌人伤害结算；另有独立 `death_revive` 四端场景用于隔离回归。

多人全量加载测试仅命中两个与本次改造无关的既有失败：陈旧 enemy action 仍播放动作动画、陈旧 target action 仍启动锁定视觉。使用独立干净 HEAD worktree 重跑后得到完全相同的两项失败，因此不是本轮回归。临时 worktree 已删除。

## 8. 尚未伪装成“已解决”的边界

本轮统一了数值结算和玩家受伤权威链，但以下事项仍需要后续独立阶段：

### P1：source 到 KillContext 尚未全贯通

`DamageRequest` 已具备 source/source_id/source_type，部分玩家弹体、收藏品和植物 batch 已开始填写；但塔、DoT、区域连锁和若干技能还没有统一的 killer/cause/team/outbox。现有奖励、掉落和收藏品 on-kill 仍有各自调用链。

### P1：死亡玩家周期效果生命周期

当前 Host 仍可能让死亡玩家推进周期收藏品并攻击或治疗队友。应在权威周期调度入口统一增加 alive policy，而不是逐个效果打补丁。

### P1：全局受击无敌帧的多段语义

普通玩家伤害共享受击无敌，AK/SMG/火球三连/Boss 弹幕的实际承伤会被节流。这是既有玩法规则，不应在架构迁移中静默改平衡；需要单独确认后再引入 attack group 或 per-source invulnerability policy。

### P2：治疗还没有结构化结果

治疗仍使用 bool 与 `last_healing_received` 旁路字段。未来的治疗增益、减疗、吸收、过量治疗、来源统计和 Host outbox 应通过 `HealRequest/HealResult` 单独统一。

### P2：旧 Variant 联机适配器

`request_multiplayer_player_damage()` 为兼容大量敌方脚本仍接收 Variant 形态参数，但进入权威结算后会立即归一为 DamageRequest。后续应按攻击类别迁移为有类型的 helper，最终删除 Variant 重载。

## 9. 推荐后续顺序

1. 将 source identity 贯通到 `KillContext` 和统一 combat outbox；
2. 修复死亡玩家周期调度的 alive policy，并增加死亡/复活生命周期测试；
3. 设计 attack group / invulnerability policy，再单独调整多段伤害平衡；
4. 将治疗迁移为结构化请求/结果；
5. 最后删除旧 bool/last-damage/Variant 兼容壳。

这一顺序让当前可运行内容继续兼容，同时每一阶段都能以纯解析器、实体流水线、网络 admission 和跨通道 ordering 测试独立验收。
