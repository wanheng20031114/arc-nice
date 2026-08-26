# 多人模式稳定化全量审计记录

> 2026-08-26 当前网络基线为协议 v96。应用层继续使用 CH0..CH8 九条逻辑信道；公网 Relay 的认证感知 `MultiplayerPeerExtension` 另外使用可靠 CH9 依次发布拓扑并承载 Relay 服务控制，公网 ENet 最大信道索引为 9。v96 新增深海遗迹遭遇并将每局神奇遭遇节点从 4 扩展为 5，同时保留 v95 的宿主权威暂停与既有 wire 合同；文中的 v95、v94、v93、v92、v91、v90 与 v9 小节均为历史快照，不能据此判断当前协议状态。
>
> 本文提到的旧烟测、探针及 runner 已于 2026-08-26 删除；相关路径和结果只保留为历史记录，不能作为当前可执行验证入口。

## 2026-08-26 当前 v96 增量摘要

v96 将神奇遭遇固定节点与正式内容池由 4 扩展为 5，新增 `deep_sea_ruins` 及 `take_crystals` / `take_rings` 稳定 ID。这会改变同种子下的路线内容映射与运行时内容摘要；v95 及更旧客户端缺少该内容 ID 和五节点契约，不能与 v96 混联。

## 2026-08-24 当前 v95 增量摘要

v95 将暂停实现为会话级绝对状态 `{session_id, revision, paused, actor_peer_id}`。任意 ACTIVE 玩家可经 reliable CH0 请求暂停或恢复，Host 使用 expected revision 执行 CAS 并广播最终状态；加载与重连先缓存暂停快照，进入 IN_GAME 后才冻结 SceneTree。暂停期间玩法 RPC 入站关闭，而恢复请求、连接维护、成员重连和安全离场继续运行；玩法网络时钟排除暂停时长，控制面超时仍使用单调墙钟。v94 及更旧客户端缺少该 RPC 与时钟合同，不能与 v95 混联。

## 2026-08-24 当前 v94 增量摘要

v94 在敌人全量快照和出生名册中同步 `faction_id` 与 `faction_revision`，通过 reliable CH5 有序复制运行时阵营变化，并由快照修复晚加入和断线重连。敌人目标动作改为通用目标描述符，Host 发射投射物时冻结来源阵营、奖励 peer、发起实体、事件来源和来源类型；v93 客户端无法解析新的敌人记录和 RPC 表面，因此不能与 v94 混联。

v94 同时保持 Host 逐发执行权威数据弹体模拟，客户端仅从带首发服务器时间戳的 burst 描述重建无碰撞、无伤害的视觉 row。每段最多 100 发且描述符不超过 1200B；命中与取消使用 reliable CH5 终止批次，运行时修复与重连使用同信道分块快照，乱序块完整收齐后才原子替换旧视觉集合。敌人终止会保留已开火视觉、取消未来尾弹，并在短期终止租约内按 Host 时间拒绝迟到 burst。

## 2026-08-21 当前 v93 增量摘要

v93 给 PlayerState 增加逐帧绝对的最终开火间隔和 burn/bleed/slow/haste/hide 表现位，避免强化射速、临时着色、尾迹和隐藏表现因跨信道乱序、丢包或晚加入永久偏离；这些位只驱动 CLIENT_VIEW 表现，不重放 Host 的伤害或倍率状态机。天依 High Noon 的目标列表同时迁入 reliable CH5，与 started/finished/cancelled 同信道有序。重连恢复额外统一清除场景临时形态、无敌、普通 Tango 蓄力、网络移速/射速覆盖，并在投影当前成长后释放旧弹容量快照覆盖。

## 历史记录：2026-08-21 v92 增量摘要

v92 把拾取消费收敛为单一 collected 终端，并让 spawn/collected/remove 共用 reliable CH5；旧 v91 使用不同的 RPC 信道注解，必须在准入阶段拒绝混联。

公网 Relay 的容量合同继续保持最小 2 人、默认 4 人、最大 8 人（均含 Host）。大厅 API、RoomManager、Launcher、Relay 启动参数、认证后业务容量检查与客户端房间 UI 共享同一 2..8 边界；DIRECT/LAN 的最大人数同样为 8。发行门禁仍应在目标 Godot 二进制上完成 Host + 7 members 的真实 E2E、断线、重连、丢包与长时 soak，不能只凭静态常量宣称动态链路已经稳定。

v91 不再依赖 `SceneMultiplayer.server_relay` 的私有 mesh。Relay 只把验票成功的物理 peer 加入认证感知包装层的可路由集合，并显式发布幂等 ADD/REMOVE 拓扑帧与转发业务数据：

- CH0..CH8 仍是游戏应用协议，其中 CH8 只承载注册接纳/拒绝和权威大厅名单等成员业务。
- CH9 是包装层专用可靠信道，先承载 ADD/REMOVE，再承载注册转发、踢人和身份查询/结果 RPC；它不进入应用诊断的九信道计数。
- 公网 Relay 创建 ENet 时传最大信道索引 9；DIRECT/LAN 仍传应用最大信道索引 8。

## 历史记录：2026-08-20 v90 全量审计摘要

> 以下内容记录 v90 当时的真实结论。当时公网因 stock Godot 4.6 的第三 transport 发现停滞而 fail-closed 为 2 人；该限制已由 v91 的认证感知包装层取代，不是当前容量合同。

结论：多人模式已经形成可辨认的 Host 权威骨架、静态协调器分层和明确的九信道协议，基础结构总体健壮；但它还不是“无债务”状态。公网 Relay 当前因 stock Godot 4.6 的三 transport 认证/发现缺陷而 fail-closed 为 2 人，LAN 仍保留 8 人能力。公网 admission、投射物权威边界和诊断清单是本轮主要收口点，跨信道 repair、可靠信道队头阻塞、迁移/重连以及场景资源泄漏仍须后续专项处理。

### Host 权威骨架

- `NetManager` 与大厅层只负责连接、Relay admission、玩家名册和进入加载流程；`MpGame` 是游戏内门面，具体同步职责下沉到固定场景树中的 coordinator，避免在运行时临时拼装整套网络节点。
- Host 接收 Client 输入或业务请求后，按 sender、会话 incarnation、revision / sequence、对象所有权和业务状态做校验；敌人、经济、世界持久状态、玩家生命与关键动作结果由 Host 计算并广播确认或快照。
- Client 只提交输入、方向或事务意图；展示层消费 Host 快照、确认事件和可丢弃反馈。投射物请求也不能把 Client 上报的伤害、出生点或特权类型直接当成权威事实。
- 进入游戏前由协议版本、内容摘要、玩家登记和加载 barrier 共同设门；`PeerLedger` 保留 peer 生命周期与会话代次，降低迟到 RPC 污染新会话的风险。
- 公网 Relay admission 位于业务 RPC 之前：只有认证完成的 peer 才应进入玩家登记和游戏信道。Host 断线视为房间终止，目前不支持 Host migration。

### 当时九条逻辑信道地图

| 信道 | 常量 | 传输语义 | 当前职责 |
| --- | --- | --- | --- |
| 0 | `CH_AUTH` | reliable | 加载、repair 控制与 manifest；原生 auth / ADD_PEER 系统包也使用底层 CH0，各业务域 repair 正文仍落在 CH5 / CH6。 |
| 1 | `CH_INPUT` | unreliable_ordered | Client -> Host 的玩家输入流。 |
| 2 | `CH_PLAYER_STATE` | unreliable_ordered | Host -> Client 的玩家实时状态与插值快照。 |
| 3 | `CH_ENEMY_STATE` | unreliable | Host -> Client 的敌人分块状态；允许后续快照覆盖旧包。 |
| 4 | `CH_PROJECTILE` | reliable / unreliable_ordered 混合 | 投射物生成请求、权威确认与高频表现；可靠性由具体 RPC 语义决定。 |
| 5 | `CH_WORLD_EVENT` | reliable | 玩家可靠动作，以及敌人、植物、地形、基地等持久世界事件。 |
| 6 | `CH_TRANSACTION` | reliable | 库存、经济、洛茜和仓库事务。 |
| 7 | `CH_FEEDBACK` | unreliable | 允许丢弃的伤害、血量和其他即时战斗反馈。 |
| 8 | `CH_MEMBERSHIP` | reliable | Relay 注册转发/完成、身份查询/结果、踢人、注册接纳/拒绝与权威大厅名单；与 CH0 系统包隔离。 |

信道定义以 `NetConstants` 和脚本实际 `@rpc` 配置为唯一事实源。诊断层不再维护另一份易漂移的手写方法表，也不会把未知 RPC 静默归入 CH5。

### 当轮已修复或收口

- 客户端 `collectible_arrow` 注入：移除 Client 选择 Host 周期性特权箭的入口，普通 Client 请求不能再借类型参数触发 Host 专属投射物。
- 投射物权威出生点：Host 依据权威玩家位置、方向和 muzzle 距离重建出生点；Client 上报位置只参与有限合法性检查，不能决定最终生成坐标。
- Relay admission / replay / name binding：引入短期 HMAC admission ticket、角色与房间声明、一次性 nonce 和有界 replay ledger；v90 把完整注册元组并入原生认证数据，Relay 认证后只在 CH8 向 Host 有界重放这份原始元组，Host 再查询 peer 1 的票据身份，Client 仅在 accepted 与自身 ACTIVE roster 都提交后回报注册完成。公网动态结论以真实 2 人端到端探针为准；3 人及以上在引擎转发层修复前必须拒绝创建，不能宣称已支持。
- 公网大厅 HTTPS fail-closed：Release 缺失公网服务配置或使用非 HTTPS 地址时拒绝继续；URL authority 校验拒绝 userinfo、控制字符、反斜杠、空主机和非法端口，Debug 仅保留明确的本地 HTTP 测试例外。
- 网络诊断映射：从脚本的实际 RPC 配置提取 method / channel；未知方法明确记为未分类和错误，不再用默认 CH5 掩盖漂移。
- 过时测试与假绿：多人 ledger、replay cache、高压、传送、围栏、石磨、虚空电池、稀有宝箱和地下商店等 smoke 已按当前 coordinator / RunState 契约更新；删除若干无消费者信号、空方法和重复清理代码。

### 当时尚未闭合的结构债务

- 公网 Relay 暂限 2 人：stock Godot 4.6 的 `auth_callback + server_relay` 在第 3 个 transport 上可复现成员发现/CH0 停滞；当前通过大厅与 Relay 双层容量门 fail-close，LAN 的 8 人上限不变。恢复公网 3..8 人需要引擎修复或经过独立证明的转发层方案。
- 跨 CH0 / CH5 / CH6 repair fence：控制/manifest 与多个业务域正文分布在三条可靠信道，目前没有“所有域均已应用”的跨信道统一完成栅栏；短 lease 到期可能触发重复 repair 请求。
- CH5 队头阻塞（HOL）：玩家可靠动作与体积较大的地形/世界 repair 共用 CH5，大包或突发修复会拖延同信道小型关键动作。拆分需要协议升级并同步 Relay stub。
- 无 Host migration：Host 一旦离线，当前房间应结束；不能把 90 秒席位保留误解为主机迁移能力。
- 公网 Client 自动重连尚未接通：Host 侧只有约 90 秒的成员席位/状态重投影基础，公网 Client 仍缺从掉线、刷新短票据、重新 admission 到安全重载当前多人场景的完整状态机。
- provisional confirm 尚未贯通 Relay/Host 撤销：已持有效 member ticket 的成员若完成 ENet/Host 注册后故意不调用 `/acquisitions/confirm`，目录中的 60 秒 provisional 占位会过期，但当前没有服务端撤销消息把该 transport 从 Relay 与 Host 名册同步踢出；因此不能宣称 provisional 到 ACTIVE 的端到端成员生命周期已闭合，正式容量统计仍需后续统一 proof/revocation 协议。
- ENet payload 未加密：HTTPS 只保护大厅控制面，ticket 只提供 admission 能力；Relay 上的 ENet 游戏流量仍没有端到端机密性。
- Legacy RPC 与协议升级债务：无生产发送者的兼容 RPC、默认参数和 Relay stub 仍应在一次协调的破坏性版本升级中统一删除，不能在 v90 内做半套 wire 变更。
- Tower / Rogue 资源泄漏：若干完整场景和 smoke 退出时仍报告大量 resource / RID / ObjectDB 残留；直接启动产品场景也可复现，不能只靠放宽测试或堆兜底清理隐藏。

---

## 历史记录：早期稳定化目标边界

> 以下内容描述早期 v9 阶段的当时状态；其中“当前”“本轮”“剩余”等措辞均应按历史时间点理解。

本轮目标是在不重写当前可玩多人模式的前提下，做协议梳理、低/中风险加固和回归测试。现有设计继续保留：Host 权威、客户端输入上报、Host 快照同步、可靠事件确认。

参考基线：

- Godot High-level multiplayer: https://docs.godotengine.org/en/stable/tutorials/networking/high_level_multiplayer.html
- Godot ENetMultiplayerPeer: https://docs.godotengine.org/en/stable/classes/class_enetmultiplayerpeer.html
- Gaffer Snapshot Interpolation: https://gafferongames.com/post/snapshot_interpolation/
- clumsy network simulator: https://jagt.github.io/clumsy/
- clumsy command line arguments: https://github.com/jagt/clumsy/wiki/Command-Line-Arguments

## 历史记录：v9 协议地图

- `CH_AUTH`：认证、加载和完整状态恢复。
- `CH_INPUT`：Client -> Host 的玩家输入上报。
- `CH_PLAYER_STATE`：Host -> Client 的玩家实时快照。
- `CH_ENEMY_STATE`：Host -> Client 的敌人分块快照。
- `CH_PROJECTILE`：投射物请求与高频战斗表现。
- `CH_WORLD_EVENT`：敌人、植物、地形和基地等持久世界事件。
- `CH_TRANSACTION`：库存、经济、洛茜和仓库事务。
- `CH_FEEDBACK`：允许丢弃的伤害与血量视觉反馈。

## 历史记录：v9 权威边界

- Host 权威：波次生命周期、敌人 AI、敌人生成/移除、敌人受击确认、玩家死亡/复活、普通掉落、击杀息壤奖金、升级和技能购买。
- Client 上报：本地输入、玩家移动状态、射击方向、客户端投射物生成和命中报告。
- Client 展示：玩家/敌人插值、伤害数字、死亡/复活倒计时、HUD。

## 历史记录：早期已加固

- 快照解码边界：`SnapshotManager` 在解析玩家/敌人快照前先计算单条快照长度，截断包会停止解码，不再读取部分状态。
- 插值缓存遍历：`MpGame._client_interpolate_entities()` 改为遍历 `Dictionary.keys()` 快照，避免插值过程中清理敌人缓存导致遍历状态被修改。
- 断线清理：`NetManager.player_left` 进入 `MpGame` 后会清理对应 peer 的插值器、输入序列、接受位置、血量 revision、复活倒计时和本地 projectile 索引；`Game` 显式移除远端玩家节点和名字索引。
- 投射物参数：Client -> Host 的玩家 projectile spawn 不再使用客户端上报的 `damage/speed/lifetime`，Host 按玩家权威属性和 projectile 场景默认值重建；生成与命中报告在同一 reliable 通道保持顺序，敌人命中必须具有 Host projectile record，并使用其中的 damage、owner 与穿透属性；projectile id 必须落在 owner peer 的 namespace。
- 投射物 spawn 边界：Client projectile 的方向必须是有限且长度合理的向量，Host 会规范化后广播；spawn 位置必须靠近 Host 当前或最近接受的玩家位置，容忍窗口为高延迟/速度 buff 留余量。
- 远端玩家权威状态：Host 现在会被动 tick 远端玩家的无敌、buff 和 skill1 充能；`_rpc_client_player_state` 保留协议字段但不再用客户端上报覆盖 Host 的 invincibility、skill charge、form 和 shot pattern；Host 接受 `skill1_bomb` 时要求并消耗 Host 侧 skill1 充能。
- 4 人自动覆盖：`multiplayer_load_smoke_test.gd` 现在覆盖 4 peer Host runtime、4 人 player snapshot、升级确认、技能购买确认、死亡/过期 revision/复活确认、远端 skill1 被动充能、Host 权威击杀奖金的全员帧末结算。
- 事件覆盖：`multiplayer_load_smoke_test.gd` 现在直接覆盖敌人命中去重、客户端 enemy removed 清理、客户端 pickup spawn/collect 确认和即时拾取效果应用。
- Snapshot 边界：玩家/敌人的 position 和 velocity 在 int16 打包前显式饱和到协议可表示范围，避免大地图或异常速度导致二进制回绕。
- Snapshot 监控：`MpGame` 记录玩家/敌人快照最大包大小和超阈值次数；应用层 payload 超过 `1200 bytes` 时低频 warning，给 4 人 LAN 与高延迟/丢包手测提供带宽压力信号，不改变同步协议。
- 测试覆盖：`multiplayer_load_smoke_test.gd` 增加玩家/敌人截断快照、只有 count 无 payload、snapshot int16 饱和、断线 peer 清理、Host projectile 参数重建、owner/namespace 校验、spawn 位置/方向校验、skill1 充能消耗、敌人 despawn、拾取确认和命中去重断言。

## 历史记录：当时剩余高优先级风险

- 客户端玩家实时状态已改为 Host 保有权威值；`100ms-2`、`200ms-2`、`200ms-5` 的 4 进程 clumsy 自动矩阵已覆盖 cheat、升级、技能购买、死亡/复活和远端死亡视图。剩余风险是实际真人键鼠操作下 skill1 充能、释放反馈与客户端预测的一致性还需要手动确认。
- 玩家 projectile 参数已改为 Host 重建，无 record 的命中报告会被拒绝，projectile id namespace、spawn 位置和方向已校验；`100ms-2`、`200ms-2`、`200ms-5` 自动矩阵已覆盖客户端移动上报和基础敌人/掉落事件。剩余风险是高延迟真人连续射击时的位置容忍窗口是否需要调参。
- 游戏中断线清理已补第一层本地状态释放，但还需要 1 host + 3 client 手动验证：客户端断开后其他客户端的 HUD/镜头/敌人目标是否自然恢复，host 断开后客户端是否稳定回大厅。
- `_apply_enemy_hit_report()` 在工具/测试直接调用且节点未入树时不会再尝试 RPC，避免无网络树上下文下的 `ERR_UNCONFIGURED`。
- 升级、技能购买和 cheat 的 Host 入口会拒绝无效 sender；内部 `_apply_upgrade_for_peer()` / `_apply_skill1_purchase_for_peer()` 也会拒绝 `peer_id <= 0` 或已离开的 peer，避免迟到事件污染 run state。
- 玩家和敌人快照现已使用按 peer 的 delta baseline、周期 keyframe 与敌人分块；旧的“仍是全量快照”债务已经关闭。

## 历史记录：当时建议的后续顺序

1. 做 1 host + 3 client 的 LAN 断线/重连手动验证，记录 skill1 充能、释放和 projectile 位置窗口是否误拒。
2. 持续观察既有 delta/keyframe、分块和包大小 telemetry，再按真实数据调参。
3. 根据高延迟手测结果调整 projectile spawn 位置容忍窗口。

## 历史记录：早期追加加固

- 客户端玩家名册收敛：`MpGame._rpc_receive_player_snapshot()` 现在会在玩家快照完整解码时记录 Host 快照里存在的 peer，并在 `CLIENT_VIEW` 中清理不再出现的远端玩家。该逻辑跳过本地玩家，只处理完整批次，避免截断包导致误删。
- 断线兜底范围：如果 `NetManager.player_left` 事件迟到或丢失，客户端仍可通过后续 Host 玩家快照释放旧玩家节点、插值器、血量 revision、复活状态和该 peer 的 projectile 索引。
- 测试覆盖：`multiplayer_load_smoke_test.gd` 增加 4 人客户端视角 roster reconcile 断言，覆盖空 roster 不清理、缺失 peer 清理、本地 peer 保留、projectile 与 record 同步释放。
- 大厅 RPC 权限：`NetManager._rpc_sync_player_list()` 和 `_rpc_start_game()` 从 `any_peer` 收紧为 `authority`，保留函数内 sender 校验，避免非 Host peer 伪造玩家列表或开始游戏事件。
- 敌人快照收敛：`MpGame._rpc_receive_enemy_snapshot()` 现在只在完整敌人快照批次上做 roster reconcile；截断批次仍可更新已解出的敌人插值，但不会把没解出的敌人误判为 stale 后移除。
- 场景退出清理：`MpGame._exit_tree()` 显式断开 `NetManager.connection_state_changed`、`NetManager.player_left` 和 `Game.return_to_lobby_requested`，降低返回大厅或重开局时旧回调残留的风险。
- 玩家健康 revision 清理：`net_player_damage_applied()` / `net_player_revived()` 现在会先确认 peer id 和玩家节点有效，再写入 `_player_health_revisions`，避免迟到可靠包指向已离开 peer 时污染后续状态。
- 息壤击杀奖金：已删除球体生成、吸附、收集、状态表和业务 RPC；Host 在敌人权威死亡时按帧聚合，并给每位当前玩家完整奖金，Client 通过已有绝对玩家快照收敛。四个旧 orb RPC 仍仅保留同签名的无副作用兼容壳。
- v9：玩家的可靠受伤确认携带实际伤害、方向与类型；植物的 50 ms 血量批次携带按建筑聚合的同类反馈，并在致死移除前刷新最终记录。
- 升级确认入口：`net_upgrade_confirmed()` 现在先确认 peer id 和玩家节点有效，再写入 `RunState.multiplayer_upgrade_levels`，避免不存在 peer 的迟到/异常确认创建升级状态。
- 手动验证清单：新增 `dev_tools/multiplayer_manual_validation_checklist.md`，固定 4 人 LAN、断线、死亡复活、拾取/升级/技能购买、cheat 和高延迟/轻丢包档位的验证步骤，避免后续手测遗漏关键边界。
- 玩家列表断线同步：Host 在大厅/加载阶段 `_on_peer_disconnected()` 后会向剩余 Client 同步新的玩家列表；Client 的 `_rpc_sync_player_list()` 会按差异 emit `player_left` / `player_joined`。游戏内断线清理由 `MpGame.player_left` 和 Host 玩家快照 roster 收敛兜底，避免关闭中的 peer 触发大厅 RPC 发送错误。
- 大厅信号清理：`multiplayer_lobby.gd` 增加显式 NetManager 信号连接/断开 helper，返回大厅或离开多人界面时不保留旧 UI 回调。
- 开始游戏竞态：`NetManager.host_start_game()` 现在只进入 loading；Host 侧 `MpGame._ready()` 在 `/root/MpGame` 已经存在后再广播 `_rpc_start_game()`，避免 Client 先进入游戏并向尚未入树的 Host `MpGame` 发送输入 RPC。
- 快照启动宽限：Host `MpGame` 启动后会等待 `0.5s` 再发送玩家/敌人快照，给 Client 从大厅切换到 `/root/MpGame` 留出缓冲，避免可靠 start 事件后紧跟的快照打到尚未存在的 Client 节点。
- 真实 LAN 探针：`dev_tools/multiplayer_lan_probe_peer.gd` 与 `dev_tools/run_multiplayer_lan_probe.ps1` 可启动 1 Host + 3 Client headless Godot 进程，验证真实 ENet 注册、玩家列表、开始游戏、玩家快照、客户端移动状态上报、敌人生成/移除同步、Host 实际击杀后四端收到配置奖金、死亡/复活状态同步。探针会把 `Node not found`、`Invalid packet received`、`ERR_UNCONFIGURED` 等网络竞态错误视为失败。
- 真实可靠事件探针：`run_multiplayer_lan_probe.ps1` 会让 `client2` 在真实 ENet 连接中依次请求 cheat、攻击升级、技能购买，并等待 Host 确认回写；当前通过日志包含 `LAN_PROBE_EVENT cheat_confirmed`、`upgrade_confirmed`、`skill1_confirmed`。
- Client 中途离开探针：`run_multiplayer_lan_probe.ps1 -Scenario leave` 会让 `client4` 入局后主动断开，Host、`client2`、`client3` 必须确认该 peer 被清理；当前端口 `29309` 通过，四端均输出 `LAN_PROBE_OK`。
- 探针退出清理：`multiplayer_lan_probe_peer.gd` 退出前会在断开网络后释放 `MpGame`，并多轮清理断线流程可能切出的 `current_scene` / `MultiplayerLobby` 测试根节点；端口 `29309` / `29310` 的 4 进程验证 stderr 为空。`run_multiplayer_lan_probe.ps1` 现在会把 `ObjectDB instances leaked` / `resources still in use` 也视为失败。
- 波次同步探针：`run_multiplayer_lan_probe.ps1 -Scenario wave` 会在 1 Host + 3 Client 真实 ENet 连接中用测试侧临时双波配置启动第 1 波，验证 Host 开波、敌人生成、Client 收到 `net_wave_started` / `net_enemy_spawned`、敌人移除、进入休整和商店激活。端口 `29461` 已通过，四端 stderr 为空。
- 多轮 soak：`dev_tools/run_multiplayer_lan_probe_soak.ps1` 现在按 `full` / `leave` / `wave` 连续跑 4 进程探针。端口 `29470` / `29471` / `29472` 已通过一轮 soak，覆盖 full、leave、wave 连续执行后的收尾竞态。
- 断线收尾防护：`NetManager` 增加断开中状态，`is_host()` / `is_client()` 在断开过程中立即返回 false；`is_peer_send_ready(peer_id)` 会检查底层 ENet peer 仍为 `STATE_CONNECTED`，Host 快照和玩家列表广播发送前会跳过正在断开的 peer，避免 leave soak 中出现 `Unable to send packet on channel 0, max channels: 0`。
- 网络条件脚本：新增 `dev_tools/run_multiplayer_clumsy_probe.ps1`，用于在 clumsy 可用时包裹 `run_multiplayer_lan_probe.ps1` 执行 `100ms-2`、`200ms-2`、`200ms-5` 档位。
- 网络条件矩阵：新增 `dev_tools/run_multiplayer_clumsy_matrix.ps1`，用于批量执行 clumsy profile 与 probe scenario 组合。本轮从官方 release 临时下载 `clumsy-0.3-win64-a.zip` 到 `%TEMP%`，未写入仓库；`100ms-2` 端口 `29520` / `29521` / `29522`、`200ms-2` 端口 `29530` / `29531` / `29532`、`200ms-5` 端口 `29540` / `29541` / `29542` 均通过 `full` / `wave` / `leave`，四端 stderr 为空。
- Smoke 稳定性：`multiplayer_load_smoke_test.gd` 的 proxy action animation restore 断言从固定 24 帧等待改为 1 秒内等待目标动画恢复，避免 headless 下帧时间波动导致 windup tween 尚未走完的假阴性；真正卡住仍会超时失败。

## 历史记录：2026-07-15 债务状态

- 已关闭：terrain repair 等待状态具备无进展 watchdog；合法分块会续期，完整快照会停表。
- 已关闭：植物 CH5 出生与 CH7 血量极端乱序由有界最高-revision 欠账和删除 tombstone 收敛。
- 已关闭：协议快照测试内容基线已同步为 v9（历史测试路径保留），旧信道迁移别名已移除。
- 已关闭：敌人终态、逃逸与拾取物删除的重复抑制状态按生命周期释放，不再随长局线性增长。
- 已关闭：所有字面量 outbound RPC 的 telemetry 分类会由 smoke 自动对照实际 `@rpc` 通道，避免指标与 Relay 真实通道漂移。
- 有意保留：完整 runtime-state 不设置频率配额，以保留大状态同步策略；正常客户端每局只请求一次，Host 仅接受已注册在局 peer。剩余威胁是恶意在局客户端主动重复请求造成放大流量，若公开房间威胁模型提高，应改为请求合并或独立滥用防护。
- 下次破坏性协议升级统一处理：移除已无生产发送者的 `net_luoxi_collectible_refresh_confirmed`、`net_enemy_defeated/removed/escaped`、`net_enemy_damage_applied`、`net_plant_health_changed`、`net_enemy_spawned`，以及 inventory/Luoxi/debug confirmation 中仅供旧直接调用的默认参数与空 snapshot 兼容面；届时应一起升级协议并同步 Relay stub，避免在 v8 内做半套 wire 变更。
- 仍需人工验证：真人高延迟连续射击的位置容忍窗口、技能充能反馈，以及 1 Host + 3 Client 的断线视觉收尾。
