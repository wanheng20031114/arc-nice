# 伤害域多人权威、通信与测试基础深度审计

> 范围：`mp_game` 中玩家/敌人/植物的伤害入口、命中报告、Host 结算、生命/死亡/复活、终结事件、掉落同步、反馈批与快照；同时盘点现有测试资产，并提出统一结算接口及网络边界。
> 方法：只读源码审计，没有修改业务代码，也没有启动 Godot、服务器或网络探针。
> 协议基线：当前为 protocol v19，8 条 ENet channel（`scene/multiplayer/net_constants.gd:3-4,22-39`）。

## 1. 结论先行

当前实现不是“完全不权威”，而是形成了两种质量差异很大的权威模型：

1. **植物、收藏品、DOT 对敌人的伤害，以及 Host 本地玩家伤害**已经基本走 Host 实体的真实 `apply_damage`，最终反馈使用真实扣血值；敌人终结也有可靠事件兜底。这个方向正确。
2. **客户端玩家弹体打敌人**时，Host 会重建弹体伤害，但没有验证碰撞几何。客户端仍能选择“哪一个敌人被命中”；穿透弹体尤其可对任意多个不同敌人各报一次命中。
3. **敌人打远端玩家**是最严重的权威缺口：客户端先本地扣血，再向 Host 上报“扣血后生命、死亡、实际伤害与状态来源”；Host 对普通来源直接接受这些结果。客户端可以不报告来免伤，也可以报告 0 血来自杀并驱动团队死亡/复活状态。
4. 玩家可靠生命事件有 revision，植物生命批也有 revision；但玩家 CH2 快照、敌人 CH3 快照与敌人 CH7 反馈仍在写同一生命字段且没有共享 revision。跨 channel 重排时，旧值可以短暂覆盖新值。
5. 敌人终结、植物移除、掉落生成/移除的“持久状态”大体放在可靠 CH5，拾取事务在可靠 CH6；方向合理。终结事件还会收拢最后一击反馈，避免致死数字完全依赖不可靠包。
6. 现有测试资产丰富，但主要是独立 `SceneTree` smoke test、源码契约断言、局部 fixture 和真实 LAN 探针；缺少统一伤害语义 oracle、恶意命中报告测试、跨 channel 全排列测试，以及旧/新结算器的 shadow A/B。

风险排序：

- **P0：远端玩家受伤结果由客户端报告决定，破坏 Host 权威。**
- **P0/P1：玩家弹体命中敌人的目标/几何由客户端决定，可跨地图选目标或扩大穿透命中集合。**
- **P1：玩家/敌人生命在多个 channel 上没有统一 revision，存在短暂回滚、假复活或血条反涨。**
- **P1：`_rpc_player_hit_report` 无速率限制、普通来源无证书、字符串无有界 wire ID，可形成可靠广播放大与短期去重表膨胀。**
- **P2：弹体记录只在周期清理时过期，命中入口本身不检查 `expires_at`，实际可接受窗口比设计值再多接近 5 秒。**

## 2. 信道与伤害 RPC 清单

信道设计定义在 `scene/multiplayer/net_constants.gd:22-39`：CH2 玩家状态、CH3 敌人状态、CH4 弹体、CH5 持久世界事件、CH6 事务、CH7 可丢弃战斗反馈。玩家快照 60 Hz、敌人默认 30 Hz（`scene/multiplayer/net_constants.gd:41-52`），高压力下敌人降到 20 Hz（`scene/multiplayer/mp_game.gd:168-170,2892-2907`）。

| RPC | 方向/模式 | channel | 语义与审计判断 |
|---|---|---:|---|
| `_rpc_enemy_hit_report` | any peer、reliable | 4 | 客户端声称弹体命中敌人；身份和伤害有校验，几何无校验（`mp_game.gd:6243-6256`）。 |
| `net_tiyi_sniper_hit_confirmed` | authority、reliable | 4 | Tiyi 命中可靠确认，主要用于表现/预测和解（`mp_game.gd:6391-6431`）。 |
| `_rpc_player_hit_report` | any peer、reliable | 5 | 客户端上报自身受到的伤害结果；当前最危险入口（`mp_game.gd:7373-7402`）。 |
| `net_player_damage_applied` | authority、reliable | 5 | revisioned 玩家伤害/死亡确认（`mp_game.gd:7581-7628`）。 |
| `net_player_healed` | authority、reliable | 5 | revisioned 玩家治疗确认（`mp_game.gd:7699-7719`）。 |
| `net_player_revive_countdown` / `net_player_revived` | authority、reliable | 5 | 倒计时与 revisioned 复活（`mp_game.gd:8139-8183`）。 |
| `net_enemy_damage_feedback_batch` | authority、unreliable | 7 | 伤害数字、受击表现，同时也携带无 revision 的生命（`mp_game.gd:7010-7043`）。 |
| `net_enemy_damage_applied` | authority、unreliable | 7 | 旧单条兼容壳；未发现当前发送调用（`mp_game.gd:7046-7068`）。 |
| `net_plant_health_batch` | authority、unreliable ordered | 7 | revisioned 植物生命与伤害/治疗反馈（`mp_game.gd:6788-6867`）。 |
| `net_plant_health_changed` | authority、unreliable ordered | 7 | 旧单条兼容壳；当前主路径走 batch（`mp_game.gd:9883-9897`）。 |
| `net_plant_damage_status_changed` | authority、reliable | 5 | 植物伤害状态 mask + status revision（`mp_game.gd:9900-9911`）。 |
| `net_plant_removed` | authority、reliable | 5 | 植物持久移除（`mp_game.gd:9914-9921`）。 |
| `net_enemy_terminal` | authority、reliable | 5 | defeated / escaped / removed 统一终结，含最后伤害反馈（`mp_game.gd:9722-9758`）。 |
| `net_enemy_defeated/removed/escaped` | authority、reliable | 5 | 旧兼容壳，当前统一入口已取代（`mp_game.gd:9761-9786`）。 |
| `net_pickup_spawned` / `net_pickup_removed` | authority、reliable | 5 | 掉落实体持久生命周期（`mp_game.gd:10524-10554`）。 |
| `net_pickup_collected` | authority、reliable | 6 | 拾取效果/库存快照事务（`mp_game.gd:10557-10594`）。 |

此外，CH2 玩家快照和 CH3 敌人快照都携带生命与死亡字段（`scene/multiplayer/snapshot_manager.gd:66-77,150-187,284-331,352-395`），这正是跨信道生命版本分裂的来源。

## 3. 端到端伤害链路

### 3.1 客户端玩家弹体 -> 敌人

链路：

`客户端开火请求` -> `Host 接纳弹体身份/参数` -> `客户端报告 enemy_net_id` -> `Host 查弹体记录并结算` -> `CH7 反馈 / CH5 terminal`

已有强项：

- 客户端开火入口验证 sender、owner 与 projectile ID lane，并在进入参数重建前消费请求身份（`scene/multiplayer/mp_game.gd:4631-4654`）。
- 方向、出生位置、允许的弹体类型均被筛选；伤害、速度、寿命、穿透与追踪目标从 Host 玩家状态和场景默认值重建，而不是采用客户端传值（`mp_game.gd:4655-4723,5400-5512`）。
- 弹体记录保存 Host 伤害、owner、类型、穿透和过期时间（`mp_game.gd:5540-5560`）。
- 命中报告要求 owner lane 正确、记录存在；非穿透普通子弹只能消费第一次确认命中，重复的 projectile/enemy 组合保留 30 秒去重（`mp_game.gd:6286-6324,6341-6352`）。
- 最终调用敌人真实 `apply_damage`，反馈使用 `enemy.last_damage_taken`，而不是客户端声称的伤害（`mp_game.gd:6434-6471`）。
- Tiyi sniper 与 skill1 bomb 明确禁止客户端报告，改由 Host 模拟结算（`mp_game.gd:6259-6283`）。

关键缺口：

#### P0/P1：命中“事实”和目标仍由客户端决定

`_apply_enemy_hit_report` 只检查 ID/owner/记录/去重/敌人存在；没有检查：

- 敌人是否位于该弹体从上一次 Host 样本到当前时刻的 swept shape 内；
- 命中点与敌人碰撞体/弹体轨迹的距离；
- 报告时间是否落在可接受 RTT 补偿窗；
- 障碍物/世界碰撞是否先于敌人；
- homing 目标约束；
- 穿透弹体沿路径可合法接触的敌人顺序和集合。

证据是入口在 `mp_game.gd:6293-6347` 直接解析 `enemy_net_id` 后调用结算，过程中没有位置、时刻或 world certificate。结果是：

- 非穿透弹体虽然只能伤一个敌人，但恶意客户端能把这一击交给地图上任意存活敌人。
- 穿透弹体的 `confirmed_hit_consumed` 不生效，只靠 `projectile_id:enemy_id` 去重；客户端可以对任意多个不同敌人各报一次（`mp_game.gd:6303-6309,6318-6324`）。
- Host 重建伤害只能阻止“改数值”，不能阻止“伪造命中数量与目标”。死亡、奖励和掉落随后都在 Host 上合法发生，因此影响是实际玩法状态而非纯表现。

#### P2：过期在清理器检查，不在命中入口检查

弹体记录的 `expires_at` 为 `lifetime + 5s`（`mp_game.gd:117,5540-5556`），但命中入口读取记录时不比较当前时间。记录每 5 秒批量清理一次（`mp_game.gd:116,6150-6162`）。因此最坏情况下，命中声称可在设计到期后再被接受接近 5 秒。应在 claim admission 当场检查 `expires_at >= now - allowed_lag`，周期清理只负责内存回收。

### 3.2 植物/收藏品 -> 敌人

这是当前最接近正确 Host 权威的链路：

- `apply_authoritative_plant_enemy_damage` 与 batch 入口要求 Host，并最终走 `_apply_confirmed_enemy_damage(_batch)`（`scene/multiplayer/mp_game.gd:1501-1522,1607-1635`）。
- 收藏品入口同样要求 Host；有 net ID 时走统一确认入口，无 net ID 时至少仍在 Host 上直接调用敌人 `apply_damage`（`mp_game.gd:6214-6240`）。
- 单击和 batch 都以敌人真实 `last_damage_taken` 生成反馈（`mp_game.gd:6434-6517`）。

主要问题不是权威性，而是**调用面分叉**：有 net ID、无 net ID、单击、batch、植物、收藏品分别有不同入口。后续新增免疫、暴击、状态、伤害来源审计时容易遗漏某一条。统一接口应收敛这些入口，但保留 batch 的性能表达。

### 3.3 敌人/敌方投射物 -> 玩家

链路：

`客户端本地碰撞` -> `客户端 Player.apply_damage` -> `客户端上报 post-health/dead/applied_damage` -> `Host 直接写生命` -> `CH5 广播`

代码在 `request_multiplayer_player_damage` 中明确分叉：客户端只处理自己的 target，先本地 `apply_damage`，然后报告当前生命、死亡与 `last_damage_taken`（`scene/multiplayer/mp_game.gd:7156-7184`）；Host 自己的玩家则本地应用后进入同一后处理路径（`mp_game.gd:7185-7212`）。

#### P0：普通玩家伤害报告实质上是客户端权威

RPC 只验证 `sender_id == player_peer_id`（`mp_game.gd:7373-7402`）。普通 source 进入 `_apply_player_hit_report` 后：

- `hit_revision` 参数被命名为 `_hit_revision` 且完全未使用（`mp_game.gd:7405-7416`）。
- 除火球和冰刺外，不要求来源记录、敌人存在、攻击配置、接触距离或时刻。
- `reported_health_after` 只做 `[0,max]` clamp，并与 Host 当前生命取 `min`；这能防止报告“加血”，但不能证明应扣多少血（`mp_game.gd:7484-7488`）。
- `reported_applied_damage` 普通来源只 clamp 到 max health，可驱动任意大小的伤害数字与状态逻辑；只有 frost ice spike 再 cap 到权威 damage（`mp_game.gd:7489-7517`）。
- Host 随后直接 `set_multiplayer_health_state(confirmed_health, confirmed_dead)`，死亡会安排复活并可靠广播（`mp_game.gd:7505-7554`）。

可利用语义：

- 客户端不发送碰撞报告即可免疫由该客户端负责检测的伤害。
- 报告 unchanged health 可让 Host 接受“命中但 0 实际扣血”；没有 Host 侧 `Player.apply_damage` 重新结算。
- 报告 `health=0` / `reported_is_dead=true` 可自杀，触发 Host 清理、死亡广播和复活调度。
- 任意正整数 `source_id` + 普通 `source_type` 可绕过来源证书；用持续新 ID 可绕过去重。

这不是理论死代码：真实 LAN probe 主动在客户端调用普通来源 `probe_death`，传入 `max_health + 999` 并等待 Host 观察到死亡/复活（`dev_tools/multiplayer_lan_probe_peer.gd:1325-1342`）。也就是说该信任边界已成为现有测试依赖的正式行为。

#### P1：可靠入口无流控，存在放大与内存压力

`_rpc_player_hit_report` 是 any-peer reliable CH5；未见 token bucket、每 peer inflight 上限、source type 长度上限或允许来源枚举（`mp_game.gd:7373-7402`）。每个新 `(source_id,target,source_type)`：

1. 在 `_processed_player_hit_ids` 中保留 30 秒（`mp_game.gd:114,7434-7443,7484`）；
2. 可能生成一次对所有客户端的可靠 `net_player_damage_applied`；
3. 可能附带状态、死亡和复活事件。

因此单个客户端可以把一条 client->Host RPC 放大成 Host->all reliable 广播，并制造 CH5 head-of-line 阻塞。客户端弹体“开火请求”已有 token bucket 测试，但“命中报告”没有同等 admission。

已有的局部权威例外：

- frost ice spike 从 Host 记录恢复 damage，并全局消费第一次接触（`mp_game.gd:7101-7114,7423-7483`）。
- fire sorcerer volley 具有来源 bitmask/首次接触消费；fire/frost smoke tests 覆盖这部分。
- 玩家 burn DOT 入口明确只允许 Host，验证 family/tick 后在 Host 调用 `apply_periodic_damage`，再以真实差值和 health revision 广播（`mp_game.gd:7232-7316`）。这应成为普通伤害重构的参考方向。

### 3.4 玩家生命、治疗、死亡与复活复制

可靠事件本身设计较好：

- damage、heal、revive 共用 `_player_health_revisions` 单调域；客户端拒绝 `<= current` 的事件（`mp_game.gd:7581-7603,7699-7719,7975-7978,8152-8174`）。
- 治疗只从 Host 的真实 `_try_heal` 或“已应用权威治疗”入口进入，确认量由 Host 传出（`mp_game.gd:7653-7692`）。
- 死亡由 Host 安排倒计时，复活位置和生命由 Host 决定并可靠广播（`mp_game.gd:7981-8030,8072-8118`）。
- 普通 client state 包虽然仍携带 health/dead，但 Host 只用它们拒绝死亡客户端继续移动，不会把客户端该字段写入权威 Player（`mp_game.gd:3804-3865`）。

#### P1：CH2 快照绕过 health revision

PlayerState codec 携带 health/max/dead，却没有 health revision（`scene/multiplayer/snapshot_manager.gd:66-77,150-187,231-246`）。客户端接收后直接调用 `Player.apply_multiplayer_realtime_state`（`scene/multiplayer/mp_game.gd:3537-3625`），该方法直接更新/死亡/复活，而不咨询 `_player_health_revisions`（`scene/player/player.gd:1550-1630`）。

后果：

- CH5 新 damage/heal/revive 已应用后，排队中的旧 CH2 快照仍可能把生命覆盖为旧值。
- 塔防死亡表现对“旧 alive 快照复活死人”有专门保护（`scene/player/player.gd:1612-1618,1696-1705`）；标准模式仍可能短暂调用 `revive_multiplayer`。
- 下一份快照或可靠事件通常会收敛，因此更像视觉/短时状态故障，但它可能触发依赖 `is_dead`、输入、HUD 或状态清理的本地副作用。

必须把 health revision 放入 CH2 state，并让所有生命写入经过同一个 client-side arbiter；不能只在可靠 RPC handler 内比较 revision。

### 3.5 敌人生命反馈与终结

非致死反馈每 0.05 秒按敌人聚合；同窗口内伤害求和，生命/方向/类型取最新，最多每包 40 条（`scene/multiplayer/mp_game.gd:171,184,6520-6555,6695-6726`）。这是合理的表现降频。

#### P1：CH3 与 CH7 对敌人生命无共享版本

- CH3 EnemyState 含 health/dead，无 health revision（`scene/multiplayer/snapshot_manager.gd:284-331,352-395`）。
- CH7 feedback 同样只有 health，无 revision/sequence/event ID（`scene/multiplayer/mp_game.gd:7010-7043`）。
- 两路最终都调用 `_apply_enemy_network_health`，普通敌人直接赋值；Boss 也只是赋值后发 signal（`mp_game.gd:3729-3751,3795-3801`；`scene/boss/linglan/linglan_boss.gd:233-239`）。

所以跨 channel 到达顺序可导致旧 health 覆盖新 health，甚至血条暂时反涨。CH7 还是 plain `unreliable`，并不提供本 channel 内顺序保证。建议二选一：

1. CH7 只带 `damage_event_id/amount/VFX`，完全不写生命；生命只由 versioned CH3/CH5 写入；或
2. CH3、CH7、terminal 全部携带同一个 `enemy_health_revision`，由统一 arbiter 应用。

#### 终结链路是当前亮点

- `Enemy._die` 先设置 `is_dead`，再排队奖励/掉落，随后同步 emit `defeated`，天然防重入（`scene/enemy/enemy.gd:3781-3807`）。
- MpGame 用 `_host_terminal_enemy_ids` 配对 defeated 后的 tree-exit removal，只发一个有效 terminal（`scene/multiplayer/mp_game.gd:8226-8262`）。
- 因 `defeated` 在 `enemy.apply_damage` 返回前同步发出，terminal 收集器从 active context 取最后一击，并把尚未 flush 的反馈一起打入可靠 CH5（`mp_game.gd:8263-8359`）。
- 客户端先应用最终生命和伤害反馈，再执行死亡/移除，并建立 terminal tombstone（`mp_game.gd:9722-9758`）。
- 真实 batch damage -> defeated -> reliable terminal 已有专门测试（`dev_tools/terminal_id_lifecycle_smoke_test.gd:293-439`）。

改进点：terminal 仍没有 health revision/entity generation。当前 net ID 单会话单调且 tombstone 有界，通常安全；统一状态版本后应让 terminal 携带最终 revision，并把 terminal 设为该 entity generation 的吸收态。

### 3.6 植物生命、反馈、状态与移除

植物链路的可靠性明显优于敌人反馈：

- `PlantDefense` 每次扣血先修改生命并 `_bump_health_revision`，随后才 emit `damage_applied`；治疗同样先 bump 再 emit healing（`scene/plant_defense/plant_defense.gd:142-157,430-448,599-636`）。
- MpGame 的 health handler 先建立/更新 pending record，damage/heal handler 再向该 revision 聚合反馈（`scene/multiplayer/mp_game.gd:8490-8591`）。当前信号顺序满足这项隐含契约。
- CH7 batch 同时携带 health revision 和 feedback；客户端独立去重 feedback revision，且不会让旧反馈覆盖更新的 live plant（`mp_game.gd:6788-6867`）。
- health 在 spawn 前到达时会暂存最高 revision，remove 后以 tombstone 拒绝迟到 CH7，相关 map 均有上限（`mp_game.gd:6870-7007`）。
- Host 移除植物前会先 flush 其最终 health record，再发可靠 removal（`mp_game.gd:8594-8606`）。尽管 CH7/CH5 跨信道不能保证先后，客户端 tombstone 与 world-position feedback 让最终状态仍能收敛。

风险与改进：

- `_on_host_plant_damage_applied` / healing 在 pending health record 为空时直接丢反馈（`mp_game.gd:8541-8543,8586-8588`）。当前基类信号顺序正确，但这是未类型化的时序耦合；子类若绕过 `_apply_damage_to_health` 或更改 signal 顺序，反馈会静默消失。统一 `DamageResult` 应原子携带 state + feedback，避免依靠两个 signal 的先后。
- status change 在可靠 CH5 到达时若 plant 尚不存在会直接丢弃（`mp_game.gd:9900-9911`）。正常 spawn/status 同 CH5 有序，late join runtime state 也带 status mask，所以当前可接受；仍建议与 pending state 使用同一个 entity-state debt 机制。

### 3.7 死亡、奖励与掉落同步

- 敌人在 `defeated.emit` 之前已确定奖励和 drop config，实际 Pickup 用 deferred 方式生成（`scene/enemy/enemy.gd:3785-3792,3810-3857`）。因此 Host 的 terminal 会先排入可靠 CH5，随后掉落注册/生成再进入 CH5，单信道顺序稳定。
- Game 与 GameTowerDefense 在 Host 注册 Pickup，spawn/remove/collect 都有 net ID；消费先发 remove，再发 collect，tree-exit marker 抑制重复 remove（`scene/game.gd:2259-2310`；`scene/game_tower_defense.gd:4430-4481`）。
- MpGame 将 spawn/remove 放在 CH5，将 collect/库存结果放在 CH6（`scene/multiplayer/mp_game.gd:8731-8777,10524-10594`）。跨 channel 到达可反转，但客户端两个 handler 都容忍 Pickup 已不存在，因此基本幂等。
- `terminal_id_lifecycle_smoke_test` 已覆盖 enemy pairing 与 pickup tree-exit marker（`dev_tools/terminal_id_lifecycle_smoke_test.gd:102-262`）。

仍缺两类强契约：

1. seeded drop table 在旧/新结算器下必须产生相同 drop intents，且一次 terminal 只提交一次奖励/掉落；
2. terminal、spawn、remove、collect 在所有允许跨 channel 排列下，客户端最终实体/库存一致且视觉最多一次。

## 4. Host 权威边界判定

| 决策 | 当前权威方 | 评价 |
|---|---|---|
| 客户端开火是否合法 | Host | 良好：身份、频率、弹药/技能、参数重建。 |
| 弹体基础伤害 | Host record | 良好。 |
| 弹体是否命中、命中谁 | Client claim | **不合格**：缺几何/时刻证书。 |
| 敌人最终扣血、抗性、死亡 | Host Enemy | 良好，但前置命中事实可能伪造。 |
| 植物/收藏品伤害敌人 | Host | 良好。 |
| 远端玩家是否受到普通敌伤 | Client | **不合格**：可不报告。 |
| 远端玩家扣血后 health/dead | Client report -> Host 接受 | **P0**。 |
| 玩家 DOT | Host | 良好。 |
| 玩家治疗/复活 | Host | 良好。 |
| 敌人 terminal/奖励/drop | Host | 良好，终结去重较完整。 |
| 客户端最终生命收敛 | 混合 CH2/3/5/7 | **需统一 revision**。 |

## 5. 现有测试基础盘点

### 5.1 框架形态

仓库没有表现为 GUT/WAT 一类集中式测试框架；主流形式是独立脚本：

- `extends SceneTree`；
- `_init()` 里 `call_deferred("_run")`；
- fixture/double 直接实例化脚本或场景；
- `failures: Array[String]` 聚合断言；
- 打印唯一 `*_OK` sentinel 并 `quit(0/1)`。

例如 `dev_tools/client_projectile_rate_limit_smoke_test.gd:1-37`、`dev_tools/terminal_id_lifecycle_smoke_test.gd:77-99`。优点是运行轻、容易做源码契约和微型语义测试；缺点是没有统一 discovery、tag、timeout、结果协议与覆盖率门槛。

真实网络使用 PowerShell 拉起多进程：`run_multiplayer_lan_probe.ps1` 组装 `--headless --path --script` 并 `Start-Process`（`dev_tools/run_multiplayer_lan_probe.ps1:37-59`）；relay 和 clumsy 分别有独立 runner。它们适合 E2E，但成本高，不能替代纯函数/fixture 级对抗测试。

### 5.2 与本审计直接相关的覆盖

| 测试资产 | 已覆盖 |
|---|---|
| `client_projectile_rate_limit_smoke_test.gd:40-209` | 开火请求 token bucket 的 burst/refill、peer isolation、合法持续速率、重复 ID 不消费 token、清理与入口作用域。**不覆盖 hit report 流控。** |
| `protocol_v8_snapshot_smoke_test.gd:122-135,299-398,958-1311` | 8 channel 常量、player/enemy codec、projectile ID lane、enemy packet budget。文件名仍是 v8，但断言当前 v19。 |
| `relay_rpc_parity_smoke_test.gd:17-150,481-564` | 主项目与 relay 全 RPC surface parity、所有 RPC channel 范围、关键 CH4/5/6/7 分配。 |
| `fire_sorcerer_network_contact_smoke_test.gd:170-810` | volley source bitmask、首次接触、burn、无敌时消费、客户端零伤报告、玩家/植物/世界碰撞补偿。 |
| `frost_sorcerer_network_contact_smoke_test.gd:134-596` | ice spike 全局消费、记录终结、寿命补偿、Host damage/cold guard、客户端确认与 revision 去重。 |
| `terminal_id_lifecycle_smoke_test.gd:102-439` | defeated->removed pairing、escape、pickup marker、可靠 terminal 最后一击 payload、真实 batch lethal chain。 |
| `multiplayer_high_pressure_smoke_test.gd:1015-1599` | 敌人 unordered chunk 收敛/repair、plant health revision、spawn debt、remove tombstone、feedback 去重、Host 聚合与致死 flush。 |
| `multiplayer_lan_probe_peer.gd:495-756,914-1065,1161-1283,1325-1342` | 真实 ENet 下基地/逃逸、植物->敌人、植物受伤/移除、敌人生命/terminal、客户端弹体报告、玩家死亡/复活。 |
| `run_multiplayer_clumsy_probe.ps1` / matrix | 可注入真实网络损耗、延迟、乱序；适合作为最终网络收敛验收。 |
| `damage_over_time_status_targets_smoke_test.gd:59-390` 与 burn/bleed/cold scheduler tests | 玩家/植物/敌人 DOT/状态语义与调度。 |
| `cold_status_scheduler_semantic_oracle.gd:114-196` | 固定 seed 随机事件 oracle，可直接仿制为统一伤害语义 oracle。 |
| `cold_status_scheduler_performance_ab.gd:205-366`、`damage_number_batch_performance_ab.gd:67-216` | 同进程 A/B 和 median/perf guard 的现成模板。 |
| `capoo_projectile_world_certificate_smoke_test.gd:63-620` | projectile/world ray schedule、thin wall 与 motion equivalence；可复用为“命中证书”几何 oracle 的基础。 |

### 5.3 明显测试空白

1. 没有测试证明普通 `_rpc_player_hit_report` 不能伪造 source、health、dead、status；现有 LAN probe 反而依赖它自杀。
2. 没有测试敌人命中报告的 target 必须接近弹体路径、在 TTL/lag window 内、且未被墙先阻挡。
3. 没有测试穿透弹体可命中集合/顺序的几何上限。
4. 没有对 `_rpc_player_hit_report` 的 token bucket、string/wire ID 上限、30 秒去重表上限和 broadcast amplification 测试。
5. 没有将 CH2 snapshot 与 CH5 damage/heal/revive 做排列/丢包测试。
6. 没有将 CH3 snapshot、CH7 feedback、CH5 terminal 做排列/丢包测试；敌人 health rollback 因而未被捕获。
7. 植物已有较好的 revision/reorder 测试，但没有验证“基类 health signal 必须先于 damage/heal signal”的显式契约。
8. 没有统一 Player/Enemy/Plant 的防御、最小伤害、实际扣血、死亡一次性、反馈值一致性测试。
9. 没有 seeded reward/drop intent 的旧/新 A/B。
10. 没有 battle feedback 0/1/40/41/80 边界、包大小、同敌人聚合与 terminal 抢占的完整组合测试。

## 6. 建议的统一结算接口

### 6.1 区分“不可信 Claim”与“可信 DamageRequest”

不要让 RPC 参数直接成为伤害请求。建议分两层：

```text
HitClaim（来自客户端，不可信）
  claimant_peer_id
  attack_event_id / projectile_id
  target_entity_ref
  client_tick
  claimed_contact_point（可选）

DamageRequest（只由 Host 构造）
  event_id
  source_entity_ref
  source_ability_wire_id
  target_entity_ref
  base_damage
  damage_type
  impact_direction
  flags / tags
  host_tick
  source_certificate

DamageResult（Host 单次原子结算输出）
  accepted / rejection_reason
  health_before / health_after / health_revision
  requested / mitigated / actual_damage
  killed
  status_deltas
  feedback_descriptor
  terminal_intent
  reward_intents / drop_intents
```

`HitClaim` 绝不能携带或决定 `reported_health_after`、`reported_is_dead`、`reported_applied_damage`、damage type 或状态 family。Host 使用 `attack_event_id` 查 `AttackCertificate` 后才能构造 `DamageRequest`。

### 6.2 统一入口建议

概念接口：

```text
CombatAuthority.validate_claim(claim) -> ClaimValidation
CombatAuthority.build_request(validation) -> DamageRequest
CombatResolver.settle(request, receiver) -> DamageResult
CombatEventOutbox.commit(result)
```

关键约束：

- `CombatResolver.settle` 只在 Host/单机权威环境可调用；客户端只有 prediction，不写 canonical health。
- Player、Enemy、Plant 通过 `DamageReceiver` adapter 暴露防御、免疫、闪避、状态与死亡操作；先保留各实体当前成熟逻辑，统一的是事务边界与结果，不要求第一步就把所有公式塞进一个巨型类。
- `DamageResult` 原子包含 health state 与 feedback，替代植物当前“health signal 后再 damage signal”的隐含配对。
- 单击和 batch 共用相同 semantic kernel；batch 允许预聚合输入，但必须输出可审计 actual total 与一次 terminal。
- reward/drop 由唯一 terminal transition 生成 intent，再由 Host outbox 提交一次。不得让多个调用点分别观察 `is_dead` 后各自产生副作用。
- 来源类型改用有限 `wire_id` / enum + Host registry；不允许任意网络字符串参与 dedupe key、状态选择或资源加载。

### 6.3 AttackCertificate / 命中证书

弹体或敌方攻击在 Host 接纳/生成时登记：

```text
AttackCertificate
  event_id, owner/source, ability_wire_id
  spawn_tick, expiry_tick, lag_compensation_window
  origin, initial_velocity, radius/shape
  damage spec
  collision mask / world-collision policy
  pierce budget
  consumed target ledger
```

远端 claim 到达时，Host 必须验证 owner、时间窗、target generation，并基于 Host 保存的轨迹样本或确定性 swept query 验证接触。可接受的工程折中是“宽松几何容差 + 有界 RTT 回溯”，但不能是“只要 projectile ID 和 enemy ID 存在就接受”。

对敌人打玩家，优先改成 Host 模拟碰撞并直接构造 DamageRequest。若为了延迟保留客户端 contact hint，也必须走同一 certificate，客户端只能提示接触，不能报告生命结果。

## 7. 建议的网络边界

### Client -> Host

只允许：

- 输入/移动意图；
- 开火/技能意图；
- 有界 `HitClaim`（event ID、target ID、tick、有限 contact evidence）；
- 事务请求。

所有入口统一执行：sender ownership、wire enum、数值有限性、长度/数组上限、per-peer token bucket、session/entity generation、certificate/TTL、幂等 event ID。拒绝原因应计数到 metrics，但不要向客户端泄露可用于探测的内部细节。

### Host -> Client

建议将数据拆成三类：

1. **Canonical state**：health/dead/status + monotonic revision。CH2/CH3 快照可丢，但必须带 revision。
2. **Durable transition**：death/revive/terminal/remove/reward transaction。可靠 CH5/CH6，携带最终 revision/event ID。
3. **Ephemeral presentation**：damage number、hit particle、arc/flash。CH7 可丢，携带 event ID 或 `(entity generation, health revision, feedback sub-index)` 只用于去重；不应无版本地覆写 health。

统一 client arbiter：

```text
apply_entity_state(entity_ref, revision, state):
  revision <= last_revision -> ignore state
  terminal generation already seen -> ignore nonterminal state
  otherwise apply and advance

apply_feedback(event_id):
  already shown -> ignore
  entity state may be absent/terminal；仅按策略显示 world-space feedback
```

Player CH2、damage/heal/revive CH5 必须进入同一 arbiter；Enemy CH3、CH7、terminal CH5 同理。Plant 现有 revision/debt/tombstone 机制可以作为实现样板。

## 8. 可立即落地的契约测试与 A/B 方案

### 8.1 P0 安全契约：`damage_claim_admission_smoke_test.gd`

表驱动覆盖：

- sender != target/owner；
- 不存在、错误 lane、Host-origin、过期 projectile/event；
- 重复 event；
- 普通 source 无证书；
- far target、墙后 target、TTL 外 target；
- non-pierce 第二目标、pierce 重复目标、超过 pierce budget；
- NaN/Inf direction/contact；
- 超长 source/string（重构后应无网络字符串）；
- 每 peer burst/refill/隔离与断线清理；
- 被拒 claim 不产生 health revision、feedback、terminal、reward 或 drop。

可复用 `client_projectile_rate_limit_smoke_test.gd` 的 fake clock/bucket fixture，以及 `capoo_projectile_world_certificate_smoke_test.gd` 的 geometry schedule。

### 8.2 统一语义 oracle：`damage_resolver_semantic_oracle.gd`

固定 seed 生成事件序列，分别喂给 Player/Enemy/Plant receiver：

- physical/magic defense 边界；
- 0、负数、1、溢出前大数；
- invincible/dodge/immune；
- actual damage 不超过 health；
- 状态只在 accepted + actual > 0 时应用；
- lethal transition、terminal、reward/drop 只一次；
- heal 与 damage 的 revision 严格递增；
- batch 等价于定义明确的 sequential semantic。

直接仿照 `cold_status_scheduler_semantic_oracle.gd:158-196` 的固定 seed randomized oracle，并保留可重放的失败 event log。

### 8.3 旧/新 shadow A/B

迁移期让同一 Host 输入同时执行：

- A：当前实体入口，但在 disposable model/fixture 上运行；
- B：新 `CombatResolver`；

比较：accepted、actual damage、health、dead、status、feedback amount/type、terminal count、reward/drop intents。先在测试进程做，随后可在 debug Host 做“B 只计算不提交”的 shadow metrics。任何不一致必须有明确 allowlist，禁止用宽泛 fallback 掩盖。

### 8.4 跨信道排列契约：`damage_replication_ordering_smoke_test.gd`

对每组事件枚举所有合法排列，并对可丢包丢弃任意 CH7/快照子集：

- Player：CH2 old/new snapshot + CH5 damage + heal + revive；
- Enemy：CH3 old/new snapshot + CH7 feedback + CH5 terminal；
- Plant：CH7 health/feedback + CH5 spawn/status/remove；
- Drop：CH5 terminal/spawn/remove + CH6 collected。

不变量：最终 canonical state 与最高 revision 一致、terminal 不可逆、不会假复活、反馈至多一次、Pickup/库存最终一致。这个测试应是纯 handler fixture，不需要真实 ENet，运行会很快。

### 8.5 反馈 batch 边界/性能 A/B

语义边界：0/1/40/41/80 enemy records、0/1/24/25/48 plant records；同目标多次聚合；nonlethal pending 后 lethal；flush 与 terminal 竞争；空列/错位列只允许内部 assert，网络 authority handler保持有界。

性能指标：

- 每 1,000 次伤害的 allocation、pack CPU、bytes、RPC 数；
- 1/4/8 clients 下 Host outbound bytes；
- 旧分散路径 vs 统一 outbox；
- metrics on/off 分开，语义断言始终开启。

可复用 `damage_number_batch_performance_ab.gd:67-179` 的 warmup/median 模板和 `cold_status_scheduler_performance_ab.gd:205-366` 的同进程 A/B 结构。

### 8.6 真实网络验收

扩展现有 LAN probe，不再通过 `probe_death` 直接提交 health，而是让 Host 生成合法 attack certificate/伤害：

- 1 Host + 3 Client；
- client projectile 合法命中、伪造远目标被拒；
- Host enemy damage、死亡、倒计时、复活；
- enemy lethal + terminal + deterministic drop + collect；
- CH7 丢失时 canonical health/terminal 仍收敛；
- clumsy matrix 覆盖 latency/loss/reorder；
- 断言 Host 与所有客户端的 `(entity_ref,health_revision,health,dead)` 最终一致。

## 9. 推荐迁移顺序

1. **先补测试，不改语义**：锁定 Player/Enemy/Plant 当前防御、状态、死亡、奖励、drop 语义；新增 cross-channel ordering test。
2. **引入类型和 shadow resolver**：DamageRequest/Result、Receiver、Outbox；先迁移 Host-only 植物/收藏品/DOT，风险最低。
3. **修客户端弹体命中**：引入 AttackCertificate、TTL 当场检查、几何/穿透 ledger；保留客户端表现预测。
4. **修远端玩家受伤**：RPC 从“DamageResult report”改为“HitClaim”；Host 调用 Player receiver 算 canonical result。现有 `probe_death` 改为 Host 测试控制入口。
5. **统一生命 revision**：扩展 PlayerState/EnemyState codec；CH2/CH3/CH5/CH7 进入同一 arbiter。CH7 不再无版本写生命。
6. **协议升级并删兼容壳**：这是 wire contract 变化，应提升 protocol version；在 relay parity 同步后删除 dormant single-hit/legacy terminal RPC，缩小攻击面和维护面。
7. **真实 LAN/relay/clumsy + soak**：验证最终收敛、带宽、无重复 terminal/drop、无可靠 channel 放大。

## 10. 验收红线

重构完成不能只以“看起来同步了”为准，至少满足：

- 客户端永远不能提交 canonical damage、health-after、dead、status 或 drop 结果。
- 任意 accepted damage 都可追溯到 Host source certificate 或 Host 本地 source。
- 同一 attack event 对同一 target generation 最多结算一次；pierce 集合有证书和预算。
- `DamageResult.actual_damage == health_before - health_after`，所有数字/VFX/吸血/状态/奖励只消费该 result。
- 所有 health writer 共享 revision；旧 snapshot/feedback 不能回滚新状态。
- terminal 是吸收态且一次性；reward/drop intents 一次提交。
- 丢失所有 CH7 反馈后，CH2/CH3 + reliable terminal/repair 仍能收敛正确 canonical state。
- 任意 peer 的 claim 洪泛受到独立、可测、可清理的 admission 上限，不可放大为无界 Host reliable 广播。
