# 多人联机、网络协议与 Relay 审计

审查快照：2026-07-26，Git HEAD `f029e2d`，并包含当前工作区未提交变更。本文是静态源码审计，不把“源码中存在测试”写成“测试已经运行通过”；本次没有启动 Godot、Relay 或网络服务，也没有修改游戏业务代码。

## 1. 结论摘要

当前联机不是简单的“把单机节点同步出去”，而是一套完整的 Host 权威、客户端预测、手写二进制快照、可靠世界事件、事务 revision、状态修复和公网 Relay 体系。成熟点包括：8 个用途分离的 ENet 信道、严格协议版本、加载屏障、玩家/敌人 delta + keyframe、敌人分块、事务速率限制、地形 watchdog、实体 tombstone/pending cache、Relay RPC 表面对齐测试，以及针对 1,200 字节包体预算的批处理。

但它现在也有几处必须在公开联机前处理的高风险边界：

1. **客户端可直接调用两个正式注册的作弊 RPC。** 任意已加入客户端都可经 CH6 请求 Host 增加 1,000 息壤，或向背包加入白名单收藏品；没有 debug-build、房主身份或权限开关（`scene/multiplayer/mp_game.gd:10841-10858, 11649-11680`）。
2. **公网大厅存在无令牌的关房接口。** `/rooms/{id}/leave` 只凭公开的 `player_name`；用房主名调用就会删除房间并停止 Relay（`relay_servers/lobby_api/main.py:187-196`，`room_manager.py:89-105`）。
3. **公网 API 明文 HTTP，且创建房间无认证/速率限制。** Host token、续租和状态更新都走硬编码 `http://47.123.6.127:8000`；匿名请求可创建最多 100 个、最低存活 10 小时的 Relay 进程（`scene/multiplayer/net_constants.gd:19-20`，`relay_servers/lobby_api/main.py:129-145`，`config.py:28-49`）。
4. **命中权威不完整。** Host 重建投射物伤害和属性，但普通客户端投射物命中报告没有验证投射物与目标的几何/时空接触；穿透弹可对任意不同敌人提交一次命中（`scene/multiplayer/mp_game.gd:6243-6352`）。玩家受击协议也会采用客户端上报的受击后生命，而不是对所有来源独立重算（`scene/multiplayer/mp_game.gd:7332-7554`）。
5. **断线重连和中途加入被明确拒绝。** 现有完整状态修复只服务已经进入本局的客户端，不是 reconnect/late-join 流程；Host 断开即结束，没有 Host migration（`scene/multiplayer/net_manager.gd:532-572, 699-755`）。
6. **CH5 的可靠队列职责过宽。** 地形大快照、实体生灭、流程/基地、植物状态，以及冲刺/锄头/提伊等时序敏感动作共用一个可靠信道；大修复期间存在队头阻塞风险。
7. **敌人 CH3 是无序不可靠，但 delta 发送基线会在发送时前进。** 丢包会让只改变一次的 health/status 等字段保持旧值，直到最多约 0.5 秒后的 full keyframe；分块批次一旦看到新批次，晚到旧块会被直接丢弃（`scene/multiplayer/mp_game.gd:2969-3036, 3667-3774`）。

综合判断：局域网合作玩法的架构基础较强，公网“可信好友房”也可工作；但若目标包含开放公网匹配或对抗作弊，当前安全边界还不能视为完成。

## 2. 可验证规模与拓扑

- 协议版本：`19`，注册时只接受完全相等版本；没有兼容版本区间（`scene/multiplayer/net_constants.gd:3-4`，`net_manager.gd:699-751`）。
- 最大玩家：8；默认直连 UDP 端口 29170；Relay 端口 40001–40100（`net_constants.gd:6-18`）。
- 直连超时 3 秒，Relay 超时 5 秒；声明了 2 秒 UPnP 超时，但全仓库没有 UPnP 实现，当前是未使用常量（`net_constants.gd:10-13`）。
- `NetManager`：1,094 行、9 个 RPC；`MpGame`：11,990 行、102 个 RPC；合计 **111 个 RPC**。
- Relay mirror：`relay_mp_game_stub.gd` 799 行/102 RPC，`relay_net_manager_stub.gd` 55 行/9 RPC。
- `mp_game.tscn` 只有 `Node2D` 根和 `HTTPRequest`；仓库中没有 `MultiplayerSpawner`/`MultiplayerSynchronizer`。生成、销毁、快照、重放和修复全部由手写 RPC 管理（`scene/multiplayer/mp_game.tscn:1-10`）。
- 直连 Host 是 ENet server、固定 peer 1；Relay Host 本身也是 Relay 的 ENet client，连接后取得动态 peer ID，再把 `NetManager`/`MpGame` authority 切到这个 ID（`scene/multiplayer/net_manager.gd:142-220, 228-315, 586-603`）。
- Relay 进程开启 Godot `server_relay`；第一个连接者被设置为两个 stub 的 authority（`relay_servers/relay_godot_project/relay_server.gd:40-55, 85-95`）。

静态统计口径：RPC 数量来自 `@rpc` 声明；“发送调用点”统计直接 `.rpc()`/`.rpc_id()` 以及 `_rpc_to_connected_clients()` 的源码调用点。它不是运行时包数：一次广播调用会按客户端数展开，而高频快照同一调用点每秒执行几十次。

## 3. 8 个 ENet 信道与 RPC 分布

`scene/multiplayer/net_constants.gd:22-39` 定义 8 个信道。全部 RPC 都是 `call_remote`，没有 `call_local`：

| 信道 | 语义 | RPC 数 | 发送调用点 | authority/any_peer 与可靠性 |
|---|---|---:|---:|---|
| CH0 AUTH | 认证、加载、完整状态修复 | 11 | 13 | authority reliable 6；any_peer reliable 5 |
| CH1 INPUT | 客户端输入/预测姿态 | 1 | 1 | any_peer unreliable_ordered 1 |
| CH2 PLAYER_STATE | 玩家快照 | 1 | 1 | authority unreliable_ordered 1 |
| CH3 ENEMY_STATE | 敌人分块快照 | 1 | 1 | authority unreliable 1 |
| CH4 PROJECTILE | 投射物意图与表现 | 7 | 9 | any_peer reliable 2；authority reliable 1；authority unreliable_ordered 4 |
| CH5 WORLD_EVENT | 持久世界事件 | 44 | 51 | any_peer reliable 8；authority reliable 36 |
| CH6 TRANSACTION | 库存、经济、仓库、洛茜事务 | 35 | 39 | any_peer reliable 16；authority reliable 19 |
| CH7 FEEDBACK | 可丢弃反馈/表现 | 11 | 9 | authority unreliable 4；authority unreliable_ordered 7 |
| **合计** |  | **111** | **124** | reliable 93；unreliable_ordered 13；unreliable 5 |

方向说明：`authority` 是 Host→Client；`any_peer` 在实际调用边界中是 Client→Host。`@rpc("any_peer")` 本身不是授权，安全性依赖每个处理函数内的 `is_host()`、`get_remote_sender_id()`、资源所有权、revision 和速率校验。

### 3.1 CH0：认证、加载与修复（11）

| RPC | 源码 | 方向 | 用途 |
|---|---|---|---|
| `_rpc_register_player` | `net_manager.gd:699` | C→H reliable | 玩家名、角色、确认状态、协议版本 |
| `_rpc_protocol_rejected` | `net_manager.gd:769` | H→C reliable | 严格版本拒绝 |
| `_rpc_join_rejected` | `net_manager.gd:780` | H→C reliable | 满员/已开局/晚加入拒绝 |
| `_rpc_set_player_character` | `net_manager.gd:791` | C→H reliable | 大厅角色与确认 |
| `_rpc_sync_player_list` | `net_manager.gd:807` | H→C reliable | 大厅 roster/角色同步 |
| `_rpc_start_game` | `net_manager.gd:879` | H→C reliable | game mode + loading session |
| `_rpc_host_game_ready` | `net_manager.gd:900` | H→C reliable | Host 放行进入游戏 |
| `_rpc_report_game_loaded` | `net_manager.gd:911` | C→H reliable | 客户端加载屏障回执 |
| `_rpc_game_load_progress` | `net_manager.gd:919` | H→C reliable | ready/total 进度 |
| `net_runtime_state_requested` | `mp_game.gd:8853` | C→H reliable | 全运行时状态修复请求 |
| `net_terrain_snapshot_requested` | `mp_game.gd:8884` | C→H reliable | 地形专项修复请求 |

### 3.2 CH1–CH4：实时输入、快照和投射物（10）

| 信道 | RPC | 源码 | 方向/可靠性 |
|---|---|---|---|
| CH1 | `_rpc_client_player_state` | `mp_game.gd:3804` | C→H unreliable_ordered |
| CH2 | `_rpc_receive_player_snapshot` | `mp_game.gd:3537` | H→C unreliable_ordered |
| CH3 | `_rpc_receive_enemy_snapshot` | `mp_game.gd:3667` | H→C unreliable |
| CH4 | `_rpc_projectile_fired_from_client` | `mp_game.gd:4631` | C→H reliable |
| CH4 | `net_projectile_fired` | `mp_game.gd:4743` | H→C unreliable_ordered |
| CH4 | `net_linglan_skill1_ring_batch` | `mp_game.gd:4811` | H→C unreliable_ordered |
| CH4 | `_rpc_enemy_hit_report` | `mp_game.gd:6243` | C→H reliable |
| CH4 | `net_tiyi_sniper_hit_confirmed` | `mp_game.gd:6391` | H→C reliable |
| CH4 | `net_plant_projectile_visual` | `mp_game.gd:9924` | H→C unreliable_ordered |
| CH4 | `net_corn_machine_gun_burst_batch` | `mp_game.gd:10056` | H→C unreliable_ordered |

### 3.3 CH5：可靠世界事件（44）

| RPC | 源码 | 方向 | 语义 |
|---|---|---|---|
| `net_player_dash_requested` | `mp_game.gd:3896` | C→H | 冲刺意图 |
| `net_player_dash_confirmed` | `mp_game.gd:3967` | H→C | 冲刺确认 |
| `net_hoe_primary_attack_requested` | `mp_game.gd:3991` | C→H | 锄头普攻意图 |
| `net_hoe_whirlwind_requested` | `mp_game.gd:4001` | C→H | 旋风意图 |
| `net_hoe_action_confirmed` | `mp_game.gd:4070` | H→C | 锄头动作确认 |
| `net_tiyi_high_noon_requested` | `mp_game.gd:4106` | C→H | 提伊大招意图 |
| `net_tiyi_high_noon_started` | `mp_game.gd:4143` | H→C | 大招开始 |
| `net_tiyi_high_noon_finished` | `mp_game.gd:4186` | H→C | 大招完成 |
| `net_tiyi_high_noon_cancelled` | `mp_game.gd:4228` | H→C | 大招取消 |
| `net_player_state_corrected` | `mp_game.gd:4316` | H→C | 客户端姿态纠正 |
| `_rpc_player_hit_report` | `mp_game.gd:7373` | C→H | 玩家受击报告 |
| `net_player_damage_applied` | `mp_game.gd:7581` | H→C | 权威玩家生命/死亡 |
| `net_player_healed` | `mp_game.gd:7699` | H→C | 权威治疗 |
| `net_xirang_orb_spawned` | `mp_game.gd:7725` | H→C | 遗留息壤球生成壳 |
| `net_xirang_orb_removed` | `mp_game.gd:7740` | H→C | 遗留移除壳 |
| `net_player_revive_countdown` | `mp_game.gd:8139` | H→C | 复活倒计时 |
| `net_player_revived` | `mp_game.gd:8152` | H→C | 复活结果 |
| `net_terrain_snapshot_chunk` | `mp_game.gd:8906` | H→C | 地形快照分块 |
| `net_terrain_delta` | `mp_game.gd:9011` | H→C | 地形 revision delta |
| `net_runtime_world_manifest` | `mp_game.gd:9044` | H→C | 敌人/掉落/植物最终清单 |
| `net_plant_placement_requested` | `mp_game.gd:9091` | C→H | 直接植物放置事务 |
| `net_inventory_plant_placement_requested` | `mp_game.gd:9108` | C→H | 背包植物放置事务 |
| `net_enemy_spawned` | `mp_game.gd:9653` | H→C | 单敌生成解码入口 |
| `net_enemy_spawned_batch` | `mp_game.gd:9701` | H→C | 敌人批量生成 |
| `net_enemy_terminal` | `mp_game.gd:9722` | H→C | 统一死亡/移除/逃脱终态 |
| `net_enemy_defeated` | `mp_game.gd:9761` | H→C | 遗留死亡壳 |
| `net_enemy_removed` | `mp_game.gd:9772` | H→C | 遗留移除壳 |
| `net_enemy_escaped` | `mp_game.gd:9780` | H→C | 遗留逃脱壳 |
| `net_base_health_changed` | `mp_game.gd:9789` | H→C | 基地生命 revision |
| `net_tower_defense_wave_progress_keyframe` | `mp_game.gd:9819` | H→C | 波次进度关键帧 |
| `net_plant_spawned` | `mp_game.gd:9836` | H→C | 植物生成 + 运行状态 |
| `net_plant_placement_rejected` | `mp_game.gd:9876` | H→C | 放置失败回执 |
| `net_plant_damage_status_changed` | `mp_game.gd:9900` | H→C | 植物伤害状态 revision |
| `net_plant_removed` | `mp_game.gd:9914` | H→C | 植物移除/摧毁 |
| `net_bamboo_mortar_visual_batch` | `mp_game.gd:9966` | H→C | 竹炮表现批次 |
| `net_hydrangea_rain_visual` | `mp_game.gd:10018` | H→C | 紫阳花雨幕表现 |
| `net_pickup_removed` | `mp_game.gd:10524` | H→C | 掉落移除 |
| `net_pickup_spawned` | `mp_game.gd:10536` | H→C | 掉落生成 |
| `net_merchant_active_changed` | `mp_game.gd:10597` | H→C | 商人可用状态 |
| `net_flow_state_changed` | `mp_game.gd:10605` | H→C | 流程状态 |
| `net_boss_started` | `mp_game.gd:10616` | H→C | Boss 生成/开始 |
| `net_game_defeated` | `mp_game.gd:10633` | H→C | 失败终态 |
| `net_game_victory` | `mp_game.gd:10641` | H→C | 胜利终态 |
| `net_tower_defense_start_wave_requested` | `mp_game.gd:10758` | C→H | 塔防开波请求 |

### 3.4 CH6：可靠事务（35）

| RPC | 源码 | 方向 | 语义 |
|---|---|---|---|
| `_rpc_xirang_orb_collected` | `mp_game.gd:7730` | C→H | 遗留收集壳 |
| `net_xirang_granted_all` | `mp_game.gd:7735` | H→C | 遗留全员发放壳 |
| `net_warehouse_command_requested` | `mp_game.gd:9131` | C→H | 仓库命令 |
| `net_warehouse_snapshot_requested` | `mp_game.gd:9141` | C→H | 仓库快照请求 |
| `net_production_command_requested` | `mp_game.gd:9207` | C→H | 生产命令 |
| `net_research_command_requested` | `mp_game.gd:9217` | C→H | 研究命令 |
| `net_production_snapshot_requested` | `mp_game.gd:9227` | C→H | 生产快照请求 |
| `net_warehouse_command_result` | `mp_game.gd:9281` | H→C | 仓库事务结果 |
| `net_production_command_result` | `mp_game.gd:9323` | H→C | 生产事务结果 |
| `net_production_state_batch` | `mp_game.gd:9359` | H→C | 生产状态批次 |
| `net_inventory_snapshot` | `mp_game.gd:9410` | H→C | 玩家背包 revision 快照 |
| `net_warehouse_storage_snapshot` | `mp_game.gd:9425` | H→C | 仓库 revision 快照 |
| `net_research_command_result` | `mp_game.gd:9430` | H→C | 研究事务结果 |
| `net_research_state_updated` | `mp_game.gd:9445` | H→C | 研究全局状态 |
| `net_pickup_collected` | `mp_game.gd:10557` | H→C | 拾取结算/背包结果 |
| `net_upgrade_selected` | `mp_game.gd:10649` | C→H | 属性升级请求 |
| `net_inventory_item_use_requested` | `mp_game.gd:10661` | C→H | 物品使用 + expected revision |
| `net_inventory_item_discard_requested` | `mp_game.gd:10694` | C→H | 物品丢弃 + expected revision |
| `net_simple_crafting_requested` | `mp_game.gd:10727` | C→H | 简易合成事务 |
| `net_skill1_purchase_requested` | `mp_game.gd:10746` | C→H | 技能购买 |
| `net_luoxi_collectible_offer_requested` | `mp_game.gd:10772` | C→H | 洛茜报价请求 |
| `net_luoxi_collectible_choice_requested` | `mp_game.gd:10792` | C→H | 洛茜选择 + offer revision |
| `net_luoxi_collectible_refresh_requested` | `mp_game.gd:10821` | C→H | 洛茜刷新 + offer revision |
| `net_cheat_xirang_requested` | `mp_game.gd:10841` | C→H | **作弊：增加息壤** |
| `net_debug_collectible_requested` | `mp_game.gd:10851` | C→H | **调试：发收藏品** |
| `net_upgrade_confirmed` | `mp_game.gd:10861` | H→C | 升级确认 |
| `net_inventory_item_used` | `mp_game.gd:10888` | H→C | 使用结果 |
| `net_inventory_item_discarded` | `mp_game.gd:10928` | H→C | 丢弃结果 |
| `net_simple_crafting_result` | `mp_game.gd:10954` | H→C | 合成结果 |
| `net_skill1_purchase_confirmed` | `mp_game.gd:11029` | H→C | 技能购买结果 |
| `net_luoxi_collectible_offer_state` | `mp_game.gd:11051` | H→C | 洛茜报价状态 |
| `net_luoxi_collectible_confirmed` | `mp_game.gd:11079` | H→C | 洛茜选择结果 |
| `net_luoxi_collectible_refresh_confirmed` | `mp_game.gd:11108` | H→C | 遗留刷新确认壳 |
| `net_cheat_xirang_confirmed` | `mp_game.gd:11174` | H→C | 作弊结果 |
| `net_debug_collectible_granted` | `mp_game.gd:11185` | H→C | 调试发放结果 |

### 3.5 CH7：可丢弃反馈（11）

| RPC | 源码 | 方向/可靠性 | 语义 |
|---|---|---|---|
| `net_tiyi_high_noon_targets` | `mp_game.gd:4165` | H→C unreliable_ordered | 提伊目标表现 |
| `net_plant_health_batch` | `mp_game.gd:6788` | H→C unreliable_ordered | 植物生命批量 delta |
| `net_enemy_damage_feedback_batch` | `mp_game.gd:7010` | H→C unreliable | 敌人伤害数字/反馈 |
| `net_enemy_damage_applied` | `mp_game.gd:7046` | H→C unreliable | 遗留单条敌伤入口 |
| `net_tower_defense_wave_progress_changed` | `mp_game.gd:9800` | H→C unreliable_ordered | 高频波次进度 |
| `net_plant_health_changed` | `mp_game.gd:9883` | H→C unreliable_ordered | 遗留单植物生命入口 |
| `net_enemy_action` | `mp_game.gd:10097` | H→C unreliable_ordered | 敌人无目标动作 |
| `net_enemy_target_action` | `mp_game.gd:10119` | H→C unreliable_ordered | 敌人目标动作 |
| `net_enemy_lightning_chain` | `mp_game.gd:10403` | H→C unreliable_ordered | 闪电端点表现 |
| `net_collectible_visual_effect` | `mp_game.gd:11128` | H→C unreliable | 收藏品瞬时表现 |
| `net_collectible_follow_visual_effect` | `mp_game.gd:11142` | H→C unreliable | 收藏品跟随表现 |

### 3.6 无网络发送点的 RPC 壳

静态审查发现 11 个注解没有网络发送调用点：`net_enemy_damage_applied`；四个 v19 息壤球遗留入口；`net_enemy_spawned`（只被批量接收器本地调用）；`net_enemy_defeated`、`net_enemy_removed`、`net_enemy_escaped`；`net_plant_health_changed`；`net_luoxi_collectible_refresh_confirmed`。它们仍被 Relay stub 和 parity 契约维护。

这不是向旧客户端提供兼容，因为注册层要求 `protocol_version == 19`。遗留壳只增加协议表面积、stub 同步成本和误调用机会。应维护机器可读的“active / local decoder / deprecated shell”清单，并在一次明确协议升级中删除，而不是无限保留。

## 4. 连接、加载和一局游戏的网络时间线

### 4.1 建连

1. LAN Host 创建 8-channel ENet server；LAN Client 连接固定 peer 1（`net_manager.gd:142-220`）。
2. 公网 Host 先从大厅取得 Relay 地址/令牌，再作为 ENet client 连接 Relay；连接成功后把自己的动态 peer ID 登记到大厅。其他客户端从大厅响应得到该 ID，并把它设为 authority（`net_manager.gd:228-315, 586-615`；`multiplayer_lobby.gd:805-821`）。
3. Client 向 Host 发送姓名、角色、确认状态和协议 v19。Host 校验版本、人数、注册窗口后登记并广播 roster（`net_manager.gd:699-755, 950-961`）。
4. 代码只配置 ENet 和 RPC sender 校验，没有应用层账号、房间口令、签名或传输加密。LAN 可视为可信网段；公网 Relay 不能因此自动获得可信身份。

### 4.2 开局屏障

1. Host 只在所有玩家确认角色后开局。
2. `host_start_game()` 增加 `loading_session_id`，冻结当时的 peer roster 到 `_expected_game_load_peers`，状态进入 `LOADING_GAME`（`net_manager.gd:351-367`）。
3. 每端加载并实例化标准/塔防战斗场景；Host 连接所有权威世界信号，Client 使用 client-view runtime（`mp_game.gd:2510-2582`）。
4. 每个 peer 准备完成后可靠回报同一 session ID。Host 只有在冻结 roster 全部 ready 后才进入 `IN_GAME` 并广播放行；重复/旧 start 或 ready 被 session/state 拒绝（`net_manager.gd:879-935, 986-1013`）。
5. 加载期间有人断开，会从 expected roster 删除，避免全局卡死（`net_manager.gd:554-564`）。

这个屏障的结构是健壮的：它冻结参与者、防重复、带 session ID，并允许加载途中掉线。但它同时把本局设计锁定为“开局 roster 固定”。

### 4.3 进入游戏后的初始修复

Client 在收到 Host ready 后只自动请求一次运行时状态。Host 顺序发送：地形、完整植物、所有玩家背包、该客户端洛茜报价、敌人、掉落、基地/波次、流程，最后发送 enemy/pickup/plant manifest 进行清单对账（`mp_game.gd:2585-2657, 2837-2877`）。Host 在最初 0.5 秒暂停实时快照，让可靠生成/修复事件先建立代理（`mp_game.gd:160-170, 2880-2898`）。

修复请求有每 peer 0.5 次/秒、burst 2 的 token bucket；地形专项请求为 1 次/秒、burst 2（`mp_game.gd:204-239, 8861-8903`）。这是良好的放大攻击防护。

不足是没有一个覆盖 CH5+CH6 的 `repair_session_id`、总块数、完成 ACK 或全局 watchdog。`_runtime_state_requested` 设置后不会因部分响应丢失自动重发；只有地形有独立的 2 秒 watchdog。当前所有核心修复响应使用 reliable，因此正常丢包由 ENet 重传，但跨信道处理失败、资源加载失败或逻辑拒绝不会触发全局修复完成判定。

### 4.4 稳态每帧

- `NetManager._physics_process()` 每个物理帧推进 frame counter，并轮询连接/Relay 注册（`net_manager.gd:63-67`）。
- `MpGame._physics_process()` 只在 `IN_GAME` 运行：清事件缓存、更新包体告警、刷新批处理；Host 发快照，Client 发输入（`mp_game.gd:580-590`）。
- Host 玩家快照 60 Hz；敌人通常 30 Hz，敌人达到 200 后降到 20 Hz；开局宽限结束后每物理帧刷新待发送敌人生成（`mp_game.gd:2880-2909`）。
- Client 每帧采样输入；输入改变、按钮事件、活动状态会以最高 60 Hz 发送，纯静止时每 6 帧即 10 Hz keepalive（`mp_game.gd:3366-3441`）。输入 RPC 有 20 个 Variant 参数，不是紧凑二进制包。
- 渲染帧对远端玩家和敌人插值；相机外敌人按 15 Hz、64 个确定性相位更新，视野预算每 0.2 秒重算（`mp_game.gd:613-670, 3455-3534`）。
- 战斗反馈、竹炮、玉米连发、植物生命按 0.05 秒批量；波次进度/提伊目标按 0.1 秒批量（`mp_game.gd:171-190, 6549-6577`）。

### 4.5 离线与掉线

- 非 Host 掉线：删除 roster，发 `player_left`，`MpGame` 清除此 peer 的输入序列、快照、投射物、事务 bucket、pending 结果等状态；正在游戏时不再广播大厅 roster，但战斗节点被移除（`net_manager.gd:554-573`，`mp_game.gd:11825-11887`）。
- Relay Client 观察到 Host peer 离开会立即报错并断开；直连通过 `server_disconnected` 处理。没有 Host migration（`net_manager.gd:567-570, 628-633`）。
- 游戏内“返回大厅”只调用 `disconnect_from_game()`；没有调用公网 DELETE/leave（`mp_game.gd:8846-8850`）。这与 Relay 进程/房间泄漏风险直接相关，见第 10 节。

## 5. Host 权威边界

| 子系统 | 实际权威 | Client 可提交 | Host 校验 | 结论 |
|---|---|---|---|---|
| 玩家位移 | 混合：Client 预测并上报最终 pose | position、velocity、输入、冲刺证据 | sequence、finite、距离/速度包络、dash allowance、`test_move()` | 不是纯 Host 模拟；体验低延迟，但可在容差内逐步偏移 |
| 玩家生命/死亡 | 名义 Host | 受击后生命、死亡、实际伤害、来源 | sender=受击玩家、事件去重、部分来源 contact record | 普通来源仍过度相信 Client |
| 玩家射击 | Host 参数权威，Client 预测表现 | projectile ID/type/spawn/direction | owner lane、速率、方向、生成距离、类型白名单、Host 重建伤害/速度/寿命/弹药 | 参数边界较强 |
| 投射物→敌人命中 | Host 结算伤害，Client 报碰撞 | projectile/enemy ID | 归属、存在、去重、伤害重建；无几何命中验证 | 穿透弹存在伪造命中面 |
| 敌人 AI/移动/生命/终态 | Host | 无状态写入 | Client 仅重放快照/动作 | 权威清晰 |
| 敌人/植物对玩家伤害 | Host + Client contact report 混合 | 玩家受击报告 | 特定火球/冰刺有一次性 contact record；其他来源较弱 | 需统一 Host 命中事实源 |
| 植物、地形、基地、波次、Boss | Host | 放置/开波等意图 | sender、team limit、资源/格子、request ID、速率 | 权威较强 |
| 拾取 | Host | 本地碰撞不会直接改共享状态 | Host 决定 spawn/remove/collect，发背包结果 | 权威清晰 |
| 库存/仓库/生产/研究/洛茜 | Host | 带 request ID、expected revision 的命令 | schema、revision、距离、building ownership/state、双层 token bucket | 本项目最成熟的网络域 |
| 瞬时 VFX/数字 | Host 选择事件，Client 重放 | 无 | CH4/CH7 可丢弃 | 合理 |

### 5.1 玩家移动是“受约束的客户端权威 pose”

Client 每包同时发送输入和最终 `global_position/velocity`。Host 并不从输入重跑移动，而是在接受后把 Host proxy 设置到报告位置，再把这个 pose 放进玩家快照（`mp_game.gd:3804-3880, 4350-4416`）。校验包络为：

`allowed = move_speed × elapsed × 1.75 + 24`，最近冲刺再加 dash distance，单次最高 2,048；elapsed 最高只累计 0.25 秒；速度上限约为 `3 × move_speed + 24`。最后用 Host proxy 的当前 transform 对整段 delta 做 `test_move()`。

优点是输入延迟低，并能拒绝 NaN、巨幅跳跃、明显超速和穿过静态碰撞。风险是：Host 没有重放加速度、减速、地图约束和逐帧碰撞路径；恶意客户端可以沿容差边缘持续移动，且一次 `test_move(delta)` 不是完整的客户端运动状态证明。报告与源码注释中的“Host owns”应精确改成“Host validates client-authoritative motion envelope”。

### 5.2 投射物参数强，碰撞证明弱

客户端开火请求有较完整的防线：sender 必须等于 owner；projectile ID 必须落在该玩家命名空间；token bucket 256/s、burst 64；方向长度必须 0.2–1.5；普通生成点在玩家/已接受 pose 周围 224 px + 枪口距离内；Host 从角色配置重建伤害、速度、寿命、穿透、归巢目标（`mp_game.gd:4631-4808, 5897-5978`）。这是正确的“意图上报、规则由 Host 重建”。

但 `_rpc_enemy_hit_report` 只验证 projectile record、owner、单弹/单敌去重和权威 damage；随后直接对 `enemy_net_id` 应用伤害。代码没有比较 Host 投射物位置、轨迹、寿命窗口、目标碰撞形状或最大射程（`mp_game.gd:6243-6352`）。非穿透普通弹只能消费第一次确认命中，限制了伤害放大；穿透弹则可对任意多个不同敌人各报一次。

建议保持客户端预测 VFX，但 Host 应在接受命中时至少验证：投射物在 Host 时间轴仍存活、目标点到重建线段/扫掠形状小于容差、命中顺序/穿透预算有效。更强方案是 Host 自己模拟玩法命中，Client 报告只作为“候选加速”。

### 5.3 玩家受击采用客户端报告结果

Client 报 `reported_health_after`、`reported_is_dead`、`reported_applied_damage`。Host 确保 sender 是被击玩家、事件未重复、生命不能上升，并对火法火球/冰刺等特定来源消费 Host contact record；最终仍以报告生命为基础 `set_multiplayer_health_state()`（`mp_game.gd:7373-7554`）。客户端可以少报伤害或干脆不报告某些只在 Client 代理检测到的接触。

应统一为 `source_id + source_type + target + contact token`，Host 从攻击规则注册表重算 armor/magic mitigation、无敌和状态；Client 上报生命只能用于诊断，不参与结算。

### 5.4 两个公开作弊入口是 P0

`net_cheat_xirang_requested()` 与 `net_debug_collectible_requested(config_path)` 都是 `any_peer/reliable/CH6`。处理器只检查当前端是 Host、sender > 0，随后分别增加 1,000 息壤或从收藏品注册表加载路径并加入该 peer 背包。它们也没有经过 CH6 共享的 32/s、burst 48 admission bucket（`mp_game.gd:10841-10858, 11649-11680`）。

最低修复标准：release export 不注册/不执行；开发环境也必须要求 Host 本地触发，远端 sender 永远拒绝。只做 UI 隐藏不是安全措施。

## 6. 快照、delta、时间戳与插值

### 6.1 玩家快照

玩家完整记录由 9 字节 header（peer ID 4、sequence 4、mask 1）、position 4、velocity 4、facing 1、anim 1、meta 38 组成，即 **57 字节/玩家**。batch 头是 1 字节 count，8 人 full payload 为 **457 字节**（`scene/multiplayer/snapshot_manager.gd:28-50, 112-177, 612-642`）。

meta 包含：当前/最大生命、息壤、死亡、无敌剩余、技能解锁/充能/时长/等级、形态、射击模式、弹匣/当前子弹/装填进度、角色 ID、普攻 cooldown ratio、有效移速倍率。字段覆盖广，避免再开许多小 RPC；但充能、无敌、装填进度等连续字段变化时会让 38 字节 meta 高频出现。

- Host 60 Hz 发送，CH2 `unreliable_ordered`。
- 每 0.5 秒强制 full；cohort 成员变化时全 cohort 强制 full，之后所有客户端复用同一份编码数据（`mp_game.gd:2912-2948, 3078-3111`）。
- 无变化 8 人 payload 最低 73 B；全部只移动约 137 B；若每人的 meta 也变化可到约 441 B，full 457 B。按 60 Hz 是每客户端约 4.3–26.8 KiB/s 的自定义 payload 区间，未计 RPC/ENet/UDP 开销。
- Client 本地玩家不插值位置，但会应用 Host 的生命、弹药、技能等实时状态；远端玩家用 2 个 snapshot interval 的渲染延迟，即约 33 ms（`mp_game.gd:3537-3625`，`net_constants.gd:44,57`）。

玩家流虽然 ordered，但仍是 unreliable。某包中的“只变化一次”字段若丢失，sender baseline 已前进，下一包可能不再带该字段；周期 full 把错误窗口限制在约 0.5 秒。对位置/速度影响较小，因为移动时下一包通常再次带绝对值；对一次性 health/status/meta 更敏感。

### 6.2 敌人快照

敌人完整记录：5 字节 header（net ID 4、mask 1）+ position 4 + velocity 4 + locomotion 1 + health 4 + dead 1 + visual status 1 = **20 字节/敌人**。移动 delta 常见为 13 字节（header + position + velocity）；batch 头为 u16 count（`snapshot_manager.gd:28-58, 284-417, 729-822`）。

- 通常 30 Hz；实体数达到 200 后降为 20 Hz。
- 每块最多 56 个；full chunk 为 `2 + 56×20 = 1,122 B`，低于项目 1,200 B warning 阈值。
- 每 0.5 秒 full keyframe；同一 batch 带 batch ID、chunk index/count、实际 snapshot Hz（`mp_game.gd:2969-3036`）。
- Client 可见敌人按当前 render frame 插值；离屏代理仍保留逻辑样本，但只在 15 Hz 相位槽应用视觉 transform。
- 敌人插值延迟为 2.5 个 interval：30 Hz 时约 83 ms，20 Hz 时约 125 ms；最大外推 120 ms（`net_constants.gd:55-61`，`mp_game.gd:3358-3363`）。

CH3 使用 plain `unreliable`，有两个相互叠加的丢包行为：

1. Host 编码后立即推进共享发送 baseline，不知道 UDP 包是否到达。记录里的字段是绝对值而非数学增量，因此不会无限累计误差；但丢失包中改变一次、随后保持不变的字段会在 Client 保持旧值，直到 full keyframe。
2. Client 一看到更大的 batch ID，就把后来到达的旧 batch chunk 判为 stale；旧批次即使只差一个块，也不会再完成 roster reconcile（`mp_game.gd:3680-3717`）。已收到 chunk 会立即更新 receive baseline，未收到 chunk 的实体不会更新；不完整批次只在落后超过两个批次时计数并淘汰（`mp_game.gd:3717-3774`）。

建议两种方向二选一：

- 若继续 delta：CH3 改 `unreliable_ordered`，每个 chunk 维持独立 baseline/sequence，或让 delta 显式引用 base keyframe ID，base 不匹配就跳过并请求 full。
- 若保留 unordered：每包对关键字段采用自足记录（至少 health/dead/status 总是携带，position/velocity 可 delta），每块可独立解码，不让一个块的丢失污染其他块语义。

### 6.3 量化范围

位置和速度以 ×10 四舍五入进 int16，精度 0.1，范围 ±3276.7；超范围直接 clamp（`snapshot_manager.gd:7-10, 42-43, 444-449`）。当前地图若保证所有网络实体都在该局部范围内没有问题；协议没有 world origin/chunk origin。如果未来扩地图、滚屏关卡或坐标偏置超过范围，客户端会看到实体粘在边界。地图构建/CI 应显式断言网络坐标范围，或改为相对 chunk/32-bit 坐标。

### 6.4 插值缓冲

常量名 `INTERPOLATION_BUFFER_SIZE = 6`，实际 `NetInterpolator` 把最大 ring 设为 `6×3 = 18` 帧（`scene/multiplayer/net_interpolator.gd:21-29`）。它对顺序到达走 O(1) append，对少量乱序做有序插入；渲染时间位于样本间时线性插值，超过最新样本时按速度外推并封顶（`net_interpolator.gd:71-184, 226-296`）。

18 帧容量能容纳约 300 ms 玩家历史、600–900 ms 敌人历史，远大于当前渲染延迟，抗轻微抖动足够。命名应区分“目标缓冲帧数”和“物理 ring 容量”，否则调参者会误以为只有 6 帧。

### 6.5 Host 时间映射不是时钟同步

Client 用 `receive_time - host_timestamp` 作为 offset 样本，首次直接采用，以后按 0.08 权重 EWMA（`mp_game.gd:11791-11811`）。没有 ping/pong、RTT、最小延迟样本或 NTP 式偏移估计。

因此 offset 实际是“时钟差 + 当前单程延迟”。稳定 80 ms 延迟下，Host 的事件时间会被映射到接收时刻附近，而不是 80 ms 之前：

- 对插值，这相当于以到达时间建时间轴，配合固定 delay 可以平滑，功能上可接受。
- 对 `projectile age`、植物运行态 elapsed、敌人动作 elapsed 等延迟补偿，稳定网络延迟会被 offset 吃掉，计算 age 接近 0；只有相对 EWMA 的延迟抖动被部分看见。Host 最多 0.25 秒的投射物补偿因此常常低估真实单程时延（`mp_game.gd:4945-4952, 8642-8677, 10392-10400`）。
- Client 开火 RPC 虽携带 `_client_fire_timestamp`，Host 处理器没有使用它，而是按收到请求的时刻生成 `host_fire_timestamp`（`mp_game.gd:4631-4693`），所以上行延迟不被补偿。

建议建立低频 ping/pong，估计 RTT 与 clock offset；快照仍可使用 arrival-smoothed timeline，但玩法事件应使用经 RTT 校正的 Host 时间和明确的最大 rewind 窗口。

## 7. 实体生成、销毁和状态修复

### 7.1 玩家

玩家节点在 `_setup_game()` 时依据冻结的 `connected_players` 和角色 map 一次性创建。60 Hz full/delta 快照更新实时状态，完整可解码 roster 会删除未出现的远端玩家；peer 断开另有明确清理（`mp_game.gd:2510-2576, 3537-3664`）。

快照无法创建缺失玩家，创建依赖大厅 roster；这与“拒绝晚加入”一致，但也说明现有运行时修复不能直接升级成 reconnect，必须新增身份恢复和玩家 spawn manifest。

### 7.2 敌人

- Host 用可靠 CH5 `net_enemy_spawned_batch`，每批最多 16 个，携带 net ID、config resource path、位置和 Host spawn time（`mp_game.gd:168-190, 2763-2804, 9653-9720`）。
- CH3 快照可能跨信道先到；Client 会先建立 interpolator，spawn 后再接上已有样本。动作事件先于 spawn 时进入最多 512 条、5 秒的 pending cache（`mp_game.gd:10141-10330`）。
- 死亡/移除/逃脱已合并为可靠 `net_enemy_terminal`，并保留最多 512 个终态 tombstone，避免迟到 spawn/action 复活实体（`mp_game.gd:9722-9758, 10340-10390`）。
- full 快照在批次完整时做 roster reconcile，清理由于漏掉 terminal 而泄漏的 proxy，但不播放死亡表现（`mp_game.gd:10478-10522`）。

设计整体健壮。主要耦合点是把 `config.resource_path` 直接作为 wire ID 并在 Client `load()`；Host/Client 必须有完全相同的资源路径和内容，协议 v19 没有 content manifest/hash。

### 7.3 植物

植物生成可靠携带 owner、net ID、plant ID、anchor、生命 revision、runtime dictionary 和 Host sample time。移除、伤害状态、紫阳花/竹炮表现分别走 CH5；高频生命变更走 CH7 0.05 秒批次，单包最多 24 条，按源码注释约 984 raw bytes（`mp_game.gd:184-190, 2660-2697, 9836-10040`）。

生产、仓库、研究状态走 CH6；若 CH6 状态先于 CH5 spawn，会放入有上限的 pending cache，植物建立后消费。removed tombstone 防止迟到健康/生产状态重新污染已删除植物（`mp_game.gd:195-203, 1654-1702, 6923-6991, 9504-9594`）。

这里的跨信道乱序处理比玩家/敌人协议更明确。值得统一的问题是：玉米/普通植物投射物表现用 CH4 可丢弃，植物生命用 CH7 可丢弃，但竹炮和紫阳花纯表现使用可靠 CH5；纯视觉不应阻塞持久世界事件，除非其时间轴对玩法判定有硬依赖。

### 7.4 地形

- full snapshot 每块 96 cells，最多 4,096 块，即协议允许 393,216 cells；可靠 CH5。
- 每个 snapshot 有 ID、revision、chunk index/count；Client 验证长度、重复 cell、terrain type、块一致性，全部收齐才提交。
- 地形 delta 带 revision；发现 gap 会请求 full。
- 等待期间每个有效块重置 2 秒 watchdog；无进展时丢弃半成品并重请求（`mp_game.gd:235-240, 2700-2760, 8906-9041, 11705-11763`）。

这是本项目最完整的 repair protocol。风险是理论上一个 full 可在 CH5 排队 4,096 个可靠 RPC；应按实际地图上限收紧协议上限，或把大快照移到专用可靠信道/压缩 blob，并设置发送预算和进度 ACK。

### 7.5 掉落、背包、仓库、生产、研究

- 掉落 spawn/remove 走可靠 CH5，collect 及背包结果走可靠 CH6。Host 代码同步发 remove 再发 collect，但跨信道无全局顺序；两个接收器都幂等删除掉落，因此视觉删除安全，背包则由 revision 决定是否应用（`mp_game.gd:10524-10594`；权威发射点在 `scene/game.gd:2272-2309` 和 `scene/game_tower_defense.gd:4443-4480`）。
- 物品使用/丢弃要求 `expected_inventory_revision`。远端省略 revision 时，Host 故意替换成不可能的未来 revision，不能绕过乐观并发（`mp_game.gd:10661-10724`）。
- 放置、仓库、生产、研究、合成、洛茜都使用 sender 派生 peer、schema canonicalization、单调 request ID/revision、结果缓存/重放和功能专用 token bucket；所有远端事务还共享 32/s、burst 48 ingress bucket，防止交替 RPC 类型放大吞吐（`mp_game.gd:1194-1333, 1750-1805, 1931-1975`）。
- 建筑交互另外校验 Host 侧玩家、建筑存活/运行状态和 48 px 距离。

建议把这套事务框架抽成统一组件；它比战斗命中协议更接近可复用的权威范式。

## 8. 中途加入、断线重连和 Host migration

当前行为是明确的“均不支持”，不是偶然缺功能：

- Host 在 `LOADING_GAME` 冻结 roster，之后 `_is_registration_open()` 为 false。
- 新 transport peer 会收到“暂不支持中途加入或断线重连”并被断开。
- 已登记 peer 的延迟/重放 registration 是幂等忽略，避免误踢正常玩家，但同一个玩家用新 peer ID 返回不会被识别。
- identity 就是本次 ENet peer ID；没有 account/session ID、重连 token、旧 peer→新 peer 迁移或输入/事务 sequence 恢复。
- Host 断开后 Client 直接结束连接；Relay 不重选 authority。

证据：`scene/multiplayer/net_manager.gd:532-572, 699-755`。

现有 `_send_runtime_state_to_peer()` 已覆盖大部分世界内容，是实现 late join 的良好基础，但仍缺少：

1. 稳定玩家身份和一次性重连凭证；
2. Host 侧旧 peer 状态保留期限及新 peer 接管；
3. 玩家节点/角色/死亡/复活/技能 cooldown 的完整 spawn state；
4. 统一 repair session 与完成 ACK；
5. CH5/CH6 事务 sequence/revision 重基线；
6. 可靠事件在修复期间的 cut-over barrier，避免“快照采样前事件在 manifest 后到达”的竞态；
7. Relay/大厅将新 peer ID 绑定到原房间玩家的认证流程。

在这些完成前，UI 应把“不支持断线重连”当作产品约束明确提示，而不是只在失败后显示拒绝文本。

## 9. Relay stub 对齐与协议维护

Relay 项目依靠与主项目完全同名、同路径、同注解、同签名的空 RPC stub，让 Godot `server_relay` 转发。`dev_tools/relay_rpc_parity_smoke_test.gd:141-158` 比较主/Relay RPC 数量及整个 annotation/signature；`481-587` 检查信道范围及关键映射。静态计数当前相等：MpGame 102↔102，NetManager 9↔9，Relay server 也配置 8 channels（`relay_server.gd:7-11, 40-55`）。

这是必要的契约测试，但维护方式仍高度耦合：每加一个 RPC，要同时编辑主脚本、stub、信道分类、诊断映射和测试。`MpGame` 已有 102 个 RPC，手工 mirror 是持续漂移源。

已经出现文档/命名老化：

- `relay_servers/README.md:28` 仍称协议 v18；源码是 v19。
- parity test `:126-129` 断言 v19，但相关失败文字仍提 v18。
- 函数仍叫 `_test_gameplay_v17_transaction_contract`（`relay_rpc_parity_smoke_test.gd:85,226`）。

建议从一个机器可读协议 manifest 生成：RPC stub、信道表、方向/可靠性文档和 parity fixtures。主脚本可以继续保留 Godot 原生 `@rpc`，生成器从源码抽取并在 CI 中验证生成物无差异。另应给 build/content 加 hash；只有整数协议版本无法发现“代码版本同为 19，但资源 path/content 不同”。

## 10. 公网大厅和 Relay 服务风险

### 10.1 P0：任何人可冒充房主离开并关闭房间

房间列表公开 `host_name`；`POST /rooms/{room_id}/leave` 只接收 `player_name`。`RoomManager.leave_room()` 以字符串比较 `player_name == host_name`，相等就删除房间；API 随后停止 Relay（`models.py:71-83`，`main.py:187-196`，`room_manager.py:89-105`）。攻击者只需房间 ID 和公开房主名，不需要 host token。

修复：所有 leave 都必须使用 server-issued player reservation token；Host 关闭必须只允许 host token。传输连接后还要把 reservation token 绑定到 ENet peer，而不是只在 HTTP roster 中记名字。

### 10.2 P0：明文 Host token

客户端硬编码 `http://47.123.6.127:8000`。创建响应返回 24-byte URL-safe host token，后续 host_ready、PATCH status、keepalive、DELETE 都在 HTTP body 发送（`net_constants.gd:19`，`models.py:36-50,85-100`，`mp_game.gd:3303-3319`）。链路上的被动观察者可取得 token 并控制房间。

必须改 HTTPS，并在服务端强制 TLS；不要只依赖部署侧可能存在但客户端 URL 未使用的反向代理。token 应限定房间、用途、过期时间，可轮换且不写日志。

### 10.3 P0/P1：匿名创建 Relay 可耗尽进程和端口

`POST /rooms` 和 quick match 自动建房都无认证、验证码、IP/账号速率限制；每次创建立即启动一个 Godot headless 进程。默认最多 100 房，Relay/房间空闲超时被强制至少 36,000 秒（10 小时）（`main.py:90-109, 129-145, 268-291`，`config.py:28-49`）。一名远端请求者可以占满全部端口和 100 个进程。

修复：网关和应用双层限速；按 IP/账号限制并发房间；Host 必须在短时间内完成经过签名的 ENet challenge，否则 30–60 秒回收；不要让“从未连接的匿名房间”享受 10 小时存活。

### 10.4 P1：Relay authority 是“首个网络连接者”

Relay 将第一个 ENet peer 设置为 stub authority；大厅 `host_ready` 只验证 token 和 `host_peer_id > 0`，不向 Relay 查询“这个 ID 是否确为首个/授权 Host”（`relay_server.gd:85-95`，`room_manager.py:142-156`）。Relay 端口范围公开且固定；抢先连接可能让 Relay stub authority 与大厅广告的 Host ID 不一致，导致 authority RPC 被拒绝或房间失效。

修复：Relay 启动时注入一次性 Host secret；第一条经过 challenge 验证的连接才成为 Host。大厅从 Relay 控制面读取 peer ID，而不是信任客户端自报。

### 10.5 P1：HTTP roster 与 ENet transport 没有绑定

加入 API 只校验房间状态、模式、人数和重名，返回 Relay 地址；Host 的 `_rpc_register_player` 不验证该 peer 是否在 HTTP roster，也没有 reservation token（`room_manager.py:68-87`，`net_manager.gd:699-746`）。知道/扫描到端口的人可以直接连 ENet，或先用任意名字调用 join 后占满 Host 的 8 个连接。HTTP “房间人数”不是网络层准入控制。

修复：join 返回短期、单次、绑定 room/player 的 ticket；Client registration 提交 ticket，Host 通过 Relay/大厅签名公钥本地验证，消费后不可重放。

### 10.6 P1：死 Relay 条目和游戏内退出会长期占用端口

`RelayLauncher.allocate_port()` 只检查 port 是否存在于 `_processes`；`is_relay_running()` 发现 Popen 已退出时不删除字典项/关闭日志（`relay_launcher.py:20-32, 128-139`）。Relay 在“曾有人连接、之后全空”1 秒后自动退出（`relay_server.gd:58-80`），但 launcher 条目仍保留。

周期 cleanup 的注释说清理“房间和死亡 Relay”，实现却只清理超过 10 小时的房间，再对那些房间 `stop_relay()`（`main.py:31-39`，`room_manager.py:199-214`）。游戏内返回大厅又不调用公网 DELETE，因此一个正常结束的公网局可能留下 room + dead Popen entry，最长 10 小时占一个端口。

修复：每轮主动 reap `poll()!=None` 的进程、关闭日志、释放端口并标记对应房间不可加入；游戏退出时 Host 使用保存的 token best-effort DELETE；服务端也应依据 Relay callback/进程退出立即清房。

### 10.7 P2：房间状态机可被置于不可恢复状态

PATCH 接受任意 `RoomStatus`，只验 host token，没有合法 transition graph（`room_manager.py:116-130`）。客户端开始公网游戏时先 PATCH `in_game`，成功后才调用 `host_start_game()`；如果本地开局检查随后失败，只显示“开局已取消”，没有把房间回滚到 waiting（`multiplayer_lobby.gd:664-675, 981-997`）。房间会从可加入列表消失并保持 in_game。

修复：服务端状态机限定 starting→waiting→loading→in_game→closed；开始请求由 Host 的 loading session 驱动，失败必须显式 rollback，或直到 Host/全员 ready 才由服务端切 in_game。

### 10.8 其他服务风险

- 房间状态只在内存；大厅进程重启会丢失 room/token 映射，而 Relay 进程可能仍活着。
- Host keepalive 每 60 秒；若响应说 Relay 已死，只 warning，不自动请求新 Relay或结束游戏（`mp_game.gd:3276-3347`）。游戏中 Relay 重启也无法保留 ENet peer/session，因此“请求新 Relay”只能用于大厅前阶段。
- 没有部署侧访问日志脱敏、审计、封禁、健康恢复或容量 backpressure 的代码证据。
- `status`、create、join、leave 等 API 没有应用层 rate limiter。即使前置网关目前有限速，也应作为部署契约写入仓库。

## 11. 带宽、包率与性能

### 11.1 敌人快照场景估算

以下只计自定义 PackedByteArray，假设每个移动敌人的 position+velocity 每帧都变化（13 B delta），每秒 2 次 full（20 B），每 chunk 另有 2 B count；不含 RPC 参数、ENet、UDP/IP 头、重传和其他事件：

| 敌人数 | 频率/块数 | 每客户端 payload | 每客户端包率 | 7 客户端 Host 下行 payload |
|---:|---|---:|---:|---:|
| 199 | 30 Hz / 4 块 | ≈80,636 B/s（78.7 KiB/s） | 120 pkt/s | ≈551 KiB/s |
| 200 | 20 Hz / 4 块 | ≈54,960 B/s（53.7 KiB/s） | 80 pkt/s | ≈376 KiB/s |
| 500 | 20 Hz / 9 块 | ≈137,360 B/s（134 KiB/s） | 180 pkt/s | ≈939 KiB/s |

200 敌人阈值能降低包率/带宽，但从 199→200 会突然改变插值延迟（约 83→125 ms）和状态采样。建议用滞回阈值或按带宽预算平滑选择 30/25/20 Hz；更进一步按距离/可见性做 interest management，而不是对每个 Client 广播同一全局敌人集。

### 11.2 玩家与输入

- 8 人玩家快照 60 Hz，约 4.3–26.8 KiB/s/Client 自定义 payload；Host 对最多 7 个 Client 重复发送。共享 cohort 只编码一次是好优化，但 `_rpc_to_connected_clients`/直接循环仍逐 peer 序列化和发包（`mp_game.gd:2912-2948, 3133-3140`）。
- 每个活跃 Client 最多 60 个 CH1 包/s，7 人为 420 inbound RPC/s；每包 20 个 Variant 参数，包含多个 Vector2、float、bool/int。建议为输入定义 PackedByteArray/固定 wire struct，并把低频角色 meta 从输入包移除；Host 目前也不消费其中多数 health/xirang/skill 字段。
- Host 最大实时包率粗略可达：玩家快照 7×60=420 pps + 199 敌人 7×120=840 pps，尚未计输入回包、事件和协议开销。

### 11.3 批处理与可靠队列

成熟点：伤害反馈最多 40 条、植物生命 24、竹炮 24、玉米 32、敌人生成 16；flush 频率 20/10 Hz，包体 warning 1,200 B（`mp_game.gd:159-190, 6549-6577`）。

风险：

- CH5 集中 44 个 reliable RPC。地形最多 4,096 块、world repair、植物生灭和玩家动作共享可靠顺序；一次大地形/丢包重传可能让 dash confirm、治疗、紫阳花表现等晚到。
- CH6 集中 35 个 reliable RPC。多数事务有限速，但两个 debug/cheat RPC 没进共享 bucket，可制造可靠队列和 Host 工作量。
- `_rpc_to_connected_clients` 对 N 客户端逐个 `rpc_id`；没有队列长度、每帧可靠发送预算或 backpressure。
- 敌人全量 interest set 对所有客户端相同。离屏只降低 Client transform 应用成本，不降低网络和 Host 编码/发送成本。

建议把 CH5 至少拆成 durable world repair 与 timing-critical confirmed action 两个可靠信道；纯 VFX 移至 CH7/CH4。若保持 8 信道，可重新划分 CH0 的“只在加载使用”容量，或把地形修复改成独立 bulk transfer 窗口。

### 11.4 运行时指标不等于真实线速

`MultiplayerRuntimeMetrics` 能按 8 信道记录 packet、payload、最大包、repair、不完整 batch 和最近 256 次事务延迟 p95（`scene/multiplayer/multiplayer_runtime_metrics.gd:1-122`）。但默认 `_rpc_payload_diagnostics_enabled = false`；此时 wrapper 只增加 packet count，payload 记 0。开启后也只是每方法首包/每 64 次用 `var_to_bytes(args)+16` 抽样估算，不是 Godot 实际 wire bytes（`mp_game.gd:483, 3143-3180`）。

此外：

- 快照大小记录较可信，因为直接取 PackedByteArray size，再加固定 16/24 估计；
- 只有走 `_rpc_to_connected_clients` 或手工 `_record_outbound_rpc` 的路径被计数，很多直接 `.rpc_id()`、全部 Client→Host 输入/事务没有完整覆盖；
- 没有 RTT、丢包率、重传、可靠队列深度、每 peer 带宽、jitter、快照 age 或 correction magnitude。

指标 UI/报告必须标注“应用层估算”。建议从 `MultiplayerPeer`/ENet 可用统计或抓包建立线速基准，并按 peer/信道记录输入包率、丢包、keyframe healing 次数、CH5 queue delay。

## 12. 结构耦合与协议一致性

### 12.1 MpGame 是单点协调巨石

11,990 行/481 个函数/102 RPC 同时负责：战场实例化、输入、移动验证、快照、插值、投射物、敌人/玩家伤害、复活、植物、地形、仓库、生产、研究、背包、洛茜、Boss、反馈批处理、完整修复和公网 keepalive。新增一种塔或角色动作很容易同时触碰信道、Host 验证、Client 表现、repair、stub 和 parity test。

建议保留一个 Godot multiplayer root，但把实现委托给明确拥有信道/状态的组件：

- `RealtimeSyncProtocol`：CH1–CH3、baseline、time sync、interpolator；
- `CombatProtocol`：CH4、伤害/接触 token、动作确认；
- `WorldProtocol`：CH5、entity registry、terrain/manifest；
- `TransactionProtocol`：CH6、revision、request cache、rate admission；
- `FeedbackProtocol`：CH7、batch/VFX；
- `RepairCoordinator`：跨组件 repair session/ACK/cut-over。

拆分时先保持 RPC 名与 wire 完全不变，仅把 handler 委托出去，可避免一次性协议升级。

### 12.2 Game 与 GameTowerDefense 的复制会造成联机漂移

标准 `scene/game.gd` 2,698 行/176 函数，塔防 `scene/game_tower_defense.gd` 5,089 行/293 函数；有 174 个同名函数。多人 Host 通过共同 signal/API 连接两套根场景，但实体注册、拾取、波次、Boss、状态导出等实现仍是复制式演进。某模式漏发 signal 或 revision，就会表现成“只有该模式联机不同步”。

应上移 `MultiplayerWorldRegistry`、波次/Boss 控制和 pickup lifecycle 到 `GameRuntimeBase` 组件；模式脚本只提供策略差异。

### 12.3 字符串/资源路径协议缺少内容契约

敌人、Boss、掉落、收藏品等通过 `res://...` path 或字符串 type 在 wire 上传递，Client 本地 `load()`。优点是实现快；缺点是重命名、导出裁剪、不同构建资源内容不一致会静默拒绝/表现错误。严格 v19 只比较整数，不能发现内容差异。

建议为每次构建生成 protocol content manifest：稳定数值/短字符串 ID→资源 hash；大厅注册时比较 manifest hash。wire 不再发送任意资源 path，只发送注册 ID。

### 12.4 信道语义不完全一致

- 竹炮/紫阳花纯表现是 CH5 reliable，玉米/植物投射物表现是 CH4 unreliable_ordered，收藏品表现是 CH7 unreliable；应按“是否影响玩法恢复”统一，而不是按开发时所在功能选择。
- 植物放置请求在 CH5，库存/仓库事务在 CH6；库存植物放置同时跨两个域。现有 revision/pending cache 缓解乱序，但所有交易型意图最好统一 CH6。
- complete repair 请求在 CH0，响应跨 CH5/CH6，却没有总 session/完成确认。
- 93/111 RPC 是 reliable，说明信道隔离很重要；不能把“用了 ENet reliable”当作延迟免费。

## 13. 风险清单与建议优先级

| 优先级 | 问题 | 影响 | 建议验收标准 |
|---|---|---|---|
| P0 | 远端作弊息壤/收藏品 RPC | 任意 Client 修改自身经济/背包，可刷可靠队列 | release 远端调用永远无效；Host 本地 debug 仍可用；契约测试覆盖 |
| P0 | `/leave` 只凭房主名可关房 | 任意人终止公开房间 | player/host token 强校验；公开名字不能授权；攻击回归测试 |
| P0 | HTTP 明文传 host token | 房间控制权可被窃取 | 客户端仅 HTTPS；服务端强制 TLS/HSTS；token 过期/用途限制 |
| P0/P1 | 匿名建房启动 10h 进程 | 100 端口/进程资源耗尽 | IP/账号限速、短期未验证回收、并发 quota、容量告警 |
| P1 | 普通/穿透弹命中无几何验证 | 伪造对任意敌人的命中 | Host sweep/rewind 校验；穿透预算/顺序；作弊用例拒绝 |
| P1 | 玩家生命采用 Client 报告 | 少报/不报伤害 | Host 由 source/contact token 重算生命与状态 |
| P1 | Relay 首连接即 authority | 抢连导致 authority 不一致/房间失效 | 一次性 Host secret challenge；控制面确认 peer ID |
| P1 | HTTP roster 未绑定 ENet | 绕过房间名单、占满连接 | join ticket 在 `_rpc_register_player` 中验证并一次性消费 |
| P1 | dead Popen/游戏内退出不回收 | 端口和房间最长泄漏 10h | 进程 reap、Relay exit callback、Host best-effort DELETE |
| P1 | CH3 unordered delta 丢包窗口 | health/status 最长约 0.5s 陈旧，批次不完整 | base ID/独立 chunk baseline，或关键字段自足；损耗测试 |
| P1 | 无 reconnect/late join/host migration | 网络抖动即永久离局/整局结束 | 产品明确约束，或完成稳定身份+repair barrier+session 恢复 |
| P2 | CH5 reliable 职责过宽 | bulk repair 阻塞动作/状态/VFX | durable bulk 与实时确认分流；可靠队列延迟指标 |
| P2 | 时间 offset 吞掉单程延迟 | 事件 age/补偿低估 | ping/pong RTT+offset，玩法事件使用校正时间 |
| P2 | 量化范围 ±3276.7 | 大地图坐标 clamp | CI 地图范围断言或 chunk-relative/32-bit 坐标 |
| P2 | 指标不是 wire telemetry | 无法真实评估带宽/丢包/HOL | 抓包基线、per-peer RTT/loss/queue/correction 指标 |
| P2 | 资源 path 作为 wire ID | 不同构建静默不一致 | 稳定 registry ID + content manifest hash |
| P2 | 102 RPC 手工 Relay mirror | 协议漂移、文档老化 | manifest 生成 stub/文档；CI 强制无差异 |
| P2 | MpGame 巨石、模式根复制 | 新机制容易漏 sync/repair | 按信道/所有权拆协议组件；公共 world registry 上移 |

## 14. 推荐验证矩阵

在修复之前和之后，至少建立以下自动/半自动网络故障矩阵：

1. 0/1/3/5/10% 丢包，20/80/180 ms RTT，0/20/80 ms jitter；分别跑 8 玩家、199/200/500 敌人。
2. 专门丢 CH2 的一次性 health/meta 包，确认 0.5 秒 keyframe 能修复且 UI 不永久错误。
3. 对 CH3 每个 chunk index 定点丢包/乱序，验证 health/dead/status、roster reconcile 和 incomplete metrics。
4. 在 4,096/实际最大地形块修复时触发 dash、治疗、植物生成和胜负事件，测 CH5 端到端延迟。
5. 让 enemy action、terminal、spawn、snapshot 以所有跨信道顺序到达，验证 pending/tombstone。
6. 对每个 CH6 命令重放旧 request ID、错误 revision、越界 slot/path、超距建筑、交替 RPC flood。
7. 从非 Host peer 调用两个 debug RPC，release 构建必须拒绝且不广播结果。
8. 公网 API：无 token host leave、窃取名字、100 并发 create、dead Relay reap、非法状态跳转、Host 抢连。
9. Host/Client 使用相同 v19 但不同 content manifest，必须在进游戏前明确拒绝。
10. 断开 Host、断开 Client、加载中断开、游戏中返回大厅，确认 Relay/房间/进程在短 SLA 内回收。

## 15. 最终判断

联机层已经具备值得保留的核心：自定义快照的包体控制、cohort 单次编码、0.5 秒 keyframe、自适应敌人频率、分块、事务 revision/速率限制、地形 watchdog、实体 pending/tombstone 和严格 Relay parity。这不是应推倒重做的系统。

正确的下一步是收紧权威与服务边界：先关闭远端 debug 能力、修复大厅授权/TLS/资源回收，再让 Host 验证命中和玩家伤害；随后处理 CH3 loss semantics、时间同步和 CH5 队列隔离。最后通过协议组件化、manifest 生成和 content hash 降低 111 个 RPC 的长期维护成本。这样可以在不改变现有玩法表现的前提下，把“可信好友局可用”推进到“公开联机可运维、可防滥用、可诊断”。
