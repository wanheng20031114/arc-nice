# 多人模式稳定化审查记录（历史）

> 本文件保留历次稳定化工作的背景与验证记录，不再作为实时债务清单。
> 当前协议基线为 v9；2026-07-15 的债务收口状态见文末“当前债务状态”。

## 目标边界

本轮目标是在不重写当前可玩多人模式的前提下，做协议梳理、低/中风险加固和回归测试。现有设计继续保留：Host 权威、客户端输入上报、Host 快照同步、可靠事件确认。

参考基线：

- Godot High-level multiplayer: https://docs.godotengine.org/en/stable/tutorials/networking/high_level_multiplayer.html
- Godot ENetMultiplayerPeer: https://docs.godotengine.org/en/stable/classes/class_enetmultiplayerpeer.html
- Gaffer Snapshot Interpolation: https://gafferongames.com/post/snapshot_interpolation/
- clumsy network simulator: https://jagt.github.io/clumsy/
- clumsy command line arguments: https://github.com/jagt/clumsy/wiki/Command-Line-Arguments

## 当前 v9 协议地图

- `CH_AUTH`：认证、加载和完整状态恢复。
- `CH_INPUT`：Client -> Host 的玩家输入上报。
- `CH_PLAYER_STATE`：Host -> Client 的玩家实时快照。
- `CH_ENEMY_STATE`：Host -> Client 的敌人分块快照。
- `CH_PROJECTILE`：投射物请求与高频战斗表现。
- `CH_WORLD_EVENT`：敌人、植物、地形和基地等持久世界事件。
- `CH_TRANSACTION`：库存、经济、洛茜和仓库事务。
- `CH_FEEDBACK`：允许丢弃的伤害与血量视觉反馈。

## 权威边界

- Host 权威：波次生命周期、敌人 AI、敌人生成/移除、敌人受击确认、玩家死亡/复活、普通掉落、击杀息壤奖金、升级和技能购买。
- Client 上报：本地输入、玩家移动状态、射击方向、客户端投射物生成和命中报告。
- Client 展示：玩家/敌人插值、伤害数字、死亡/复活倒计时、HUD。

## 本轮已加固

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

## 剩余高优先级风险

- 客户端玩家实时状态已改为 Host 保有权威值；`100ms-2`、`200ms-2`、`200ms-5` 的 4 进程 clumsy 自动矩阵已覆盖 cheat、升级、技能购买、死亡/复活和远端死亡视图。剩余风险是实际真人键鼠操作下 skill1 充能、释放反馈与客户端预测的一致性还需要手动确认。
- 玩家 projectile 参数已改为 Host 重建，无 record 的命中报告会被拒绝，projectile id namespace、spawn 位置和方向已校验；`100ms-2`、`200ms-2`、`200ms-5` 自动矩阵已覆盖客户端移动上报和基础敌人/掉落事件。剩余风险是高延迟真人连续射击时的位置容忍窗口是否需要调参。
- 游戏中断线清理已补第一层本地状态释放，但还需要 1 host + 3 client 手动验证：客户端断开后其他客户端的 HUD/镜头/敌人目标是否自然恢复，host 断开后客户端是否稳定回大厅。
- `_apply_enemy_hit_report()` 在工具/测试直接调用且节点未入树时不会再尝试 RPC，避免无网络树上下文下的 `ERR_UNCONFIGURED`。
- 升级、技能购买和 cheat 的 Host 入口会拒绝无效 sender；内部 `_apply_upgrade_for_peer()` / `_apply_skill1_purchase_for_peer()` 也会拒绝 `peer_id <= 0` 或已离开的 peer，避免迟到事件污染 run state。
- 玩家和敌人快照现已使用按 peer 的 delta baseline、周期 keyframe 与敌人分块；旧的“仍是全量快照”债务已经关闭。

## 保守后续顺序

1. 做 1 host + 3 client 的 LAN 断线/重连手动验证，记录 skill1 充能、释放和 projectile 位置窗口是否误拒。
2. 持续观察既有 delta/keyframe、分块和包大小 telemetry，再按真实数据调参。
3. 根据高延迟手测结果调整 projectile spawn 位置容忍窗口。

## 本轮追加加固

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

## 当前债务状态（2026-07-15）

- 已关闭：terrain repair 等待状态具备无进展 watchdog；合法分块会续期，完整快照会停表。
- 已关闭：植物 CH5 出生与 CH7 血量极端乱序由有界最高-revision 欠账和删除 tombstone 收敛。
- 已关闭：协议快照测试内容基线已同步为 v9（历史测试路径保留），旧信道迁移别名已移除。
- 已关闭：敌人终态、逃逸与拾取物删除的重复抑制状态按生命周期释放，不再随长局线性增长。
- 已关闭：所有字面量 outbound RPC 的 telemetry 分类会由 smoke 自动对照实际 `@rpc` 通道，避免指标与 Relay 真实通道漂移。
- 有意保留：完整 runtime-state 不设置频率配额，以保留大状态同步策略；正常客户端每局只请求一次，Host 仅接受已注册在局 peer。剩余威胁是恶意在局客户端主动重复请求造成放大流量，若公开房间威胁模型提高，应改为请求合并或独立滥用防护。
- 下次破坏性协议升级统一处理：移除已无生产发送者的 `net_luoxi_collectible_refresh_confirmed`、`net_enemy_defeated/removed/escaped`、`net_enemy_damage_applied`、`net_plant_health_changed`、`net_enemy_spawned`，以及 inventory/Luoxi/debug confirmation 中仅供旧直接调用的默认参数与空 snapshot 兼容面；届时应一起升级协议并同步 Relay stub，避免在 v8 内做半套 wire 变更。
- 仍需人工验证：真人高延迟连续射击的位置容忍窗口、技能充能反馈，以及 1 Host + 3 Client 的断线视觉收尾。
