# 多人伤害结果与快照跨通道顺序审计

## 结论

审计确认重构后的 Host 伤害数值已经权威化，但生命状态曾缺少跨通道顺序屏障：

- 玩家生命结果使用可靠通道 5，玩家快照使用 `unreliable_ordered` 通道 2。旧快照可能在可靠伤害结果之后到达，并把 `health/dead/invincibility` 覆盖回旧值。
- 敌人非致死伤害反馈使用不可靠通道 7，敌人快照使用不可靠通道 3。较旧的反馈或快照可能把客户端代理生命抬高。致死终态没有复活风险，因为可靠 terminal 事件建立 tombstone 并移除代理。

本次用局部改动封闭了两类竞态：玩家把既有 Host `health_revision` 纳入快照，并把“可靠事件去重修订号”和“已应用生命状态修订号”拆开；敌人在当前无治疗/复活的 net-id 生命周期内强制客户端代理生命单调不增。

## 编码、发送、应用路径

### 玩家快照（通道 2）

1. `Game` / `GameTowerDefense.collect_player_snapshot_states()` 采集 `current_health/max_health/is_dead/invincibility` 等状态。
2. `MpGame._host_broadcast_player_snapshots()` 写入全局 snapshot sequence，并从 `_player_health_revisions` 写入每个 `PlayerState.health_revision`。
3. `SnapshotManager.encode_player_snapshots_for_cohort()` 对 `PlayerState` 做 delta 编码。
4. `_rpc_receive_player_snapshot()` 在客户端解码后调用 `_apply_player_realtime_snapshot()`。
5. `_apply_player_realtime_snapshot()` 只有在快照 revision 不旧于 `_player_applied_health_revisions[peer]` 时才应用生命、死亡和无敌时间；移动、技能、弹药等无关实时字段仍然正常应用。

`PlayerState.health_revision` 位于 `MASK_PLAYER_META`，占 4 bytes；`PLAYER_META_BYTES` 从 38 增至 42。仅当 meta 变化或 keyframe 时产生这 4 bytes，不增加纯位置/速度 delta 的包体。

### 玩家可靠生命事件（通道 5）

- 伤害：Host `_next_player_health_revision()` → `net_player_damage_applied()`。
- 治疗：Host `report_multiplayer_player_healing()` → `net_player_healed()`。
- 复活：Host `_revive_player_peer()` → `net_player_revived()`。
- 权威纠正也走 `net_player_damage_applied()` 并分配新 revision。

客户端现在维护两个不同含义的游标：

- `_player_health_revisions[peer]`：最后处理的可靠生命事件。它负责事件去重和保证伤害数字、状态等表现只消费一次；快照不得推进它。
- `_player_applied_health_revisions[peer]`：最后实际写入 `health/dead/invincibility` 的 revision。快照和可靠事件都可推进它。

可靠事件满足 `revision > event_cursor` 时仍会消费一次表现；只有 `revision >= applied_cursor` 时才写生命状态。因此“新快照先到、旧可靠事件后到”不会让生命倒退，同时旧事件的伤害数字不会因快照抢先而丢失。

复活是例外的可靠生命周期边界：`Player.apply_multiplayer_realtime_state()` 本来就拒绝用普通 alive 快照解除塔防死亡展示，所以 `net_player_revived()` 始终执行复活，再更新 applied cursor。否则新 alive 快照先到但被 Player 拒绝后，会错误地抑制真正的可靠复活。

### 敌人快照（通道 3）

1. `GameRuntimeBase.collect_reused_enemy_snapshot_states()` 采集 `health/is_dead`。
2. `_host_broadcast_enemy_snapshots()` 分块编码并附加单调 `batch_id`。
3. `_rpc_receive_enemy_snapshot()` 拒绝旧 batch/chunk，应用插值和 `_apply_enemy_network_health()`。

### 敌人反馈与终态

- 非致死：`_apply_confirmed_enemy_damage[_batch]()` → `_queue_enemy_damage_feedback()` → `net_enemy_damage_feedback_batch()`（通道 7，不可靠）。
- 旧的单条 `net_enemy_damage_applied()` 也是通道 7 表现路径。
- 致死/移除/逃逸：`net_enemy_terminal()`（通道 5，可靠），客户端建立 terminal marker 后移除代理。

敌人当前不存在同一 net-id 生命周期内的治疗或复活。`_apply_enemy_network_health()` 因此拒绝任何高于当前代理生命的值：

`client_health_next = min(client_health_current, incoming_health)`

这同时覆盖“旧反馈晚到”和“旧快照晚到”，且不为大规模敌人快照增加 per-enemy revision 带宽。将来若加入敌人治疗，必须移除此不变量，并为敌人反馈与快照共同增加显式 health revision。

## 原竞态与修复后的行为

### 可靠伤害先到，旧玩家快照后到

- 原行为：结果 revision 5 把生命设为 60；旧快照无 revision，把生命恢复到 90。
- 新行为：结果推进 event/applied cursor 到 5；旧快照 revision 4 只更新非生命实时字段。

### 新玩家快照先到，较旧可靠事件后到

- 原始单游标方案的危险：若快照推进事件游标，稍后的伤害数字会被吞；若不推进任何游标，较旧结果会让生命倒退。
- 新行为：快照 revision 7 只推进 applied cursor；事件 revision 6 仍消费一次表现，但不覆盖 revision 7 的生命。

### 敌人反馈/快照乱序

- 原行为：客户端已显示 40 HP，旧包的 55 HP 可把代理生命抬回 55。
- 新行为：55 大于当前 40，被单调屏障拒绝。

## 测试

新增 `dev_tools/damage_snapshot_ordering_smoke_test.gd`，覆盖：

1. 玩家 keyframe 和 revision-only delta 的 `health_revision` 编解码。
2. 可靠结果先到后，旧玩家快照不能恢复生命或清除命中无敌。
3. 同 revision 快照仍可正常应用。
4. 新快照先到时，只推进 applied cursor，不吞可靠事件游标。
5. 较旧可靠事件不能覆盖更新快照的生命。
6. 敌人较低生命可应用，较旧较高生命被拒绝。

验证结果：

- `damage_snapshot_ordering_smoke_test.gd`：通过。
- `protocol_v8_snapshot_smoke_test.gd`：通过，包含 delta、复用、包体预算检查。
- `multiplayer_game_mode_smoke_test.gd`：通过。
- `multiplayer_load_smoke_test.gd`：其快照/生命相关部分未报告失败，但整套测试仍因两个既有的 enemy action / target action 陈旧动画断言失败；失败路径与本次生命编码和顺序屏障无调用关系，未在本子任务中改动该业务。

## 剩余约束

1. 所有 Host 玩家伤害、治疗、复活、纠正事件必须继续通过 `_next_player_health_revision()` 分配 revision。
2. 玩家快照必须继续从同一个 `_player_health_revisions` 填充 revision，不能另建独立计数器。
3. 敌人单调屏障依赖“同一 net-id 生命周期无治疗/复活”。新增敌人治疗时应升级为显式 revision 协议并增加乱序测试。
4. 玩家与敌人 terminal/spawn 的可靠 tombstone 逻辑仍是实体生命周期边界，不能仅依赖实时快照恢复实体。
