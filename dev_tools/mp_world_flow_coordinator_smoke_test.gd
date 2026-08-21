extends SceneTree

const WORLD_FLOW_COORDINATOR_SCENE := preload(
	"res://scene/multiplayer/world_flow/mp_world_flow_coordinator.tscn"
)
const MpWorldFlowCoordinatorScript := preload(
	"res://scene/multiplayer/world_flow/mp_world_flow_coordinator.gd"
)
const MP_GAME_SCRIPT_PATH := "res://scene/multiplayer/mp_game.gd"
const BOSS_CONFIG_PATH := "res://resources/config/bosses/boss_01_linglan.tres"
const PICKUP_CONFIG_PATH := "res://resources/config/materials/material_wood.tres"
const IMMEDIATE_PICKUP_CONFIG_PATH := (
	"res://resources/config/pickup_triggered_items/speed_boots.tres"
)
const OUTSIDE_PICKUP_PATH := (
	"res://dev_tools/fixtures/runtime_content_catalog_outside_pickup.tres"
)


class ProbeRuntime:
	extends WaveCombatRuntimeBase

	func _connect_mode_dynamic_pickup_containers() -> void:
		pass

	func _register_static_multiplayer_pickups() -> void:
		pass

	func _configure_singleplayer_player() -> void:
		pass

	func _configure_multiplayer_players() -> void:
		pass

	func _connect_mode_singleplayer_player_death_signal() -> void:
		pass

	func _update_multiplayer_remote_player_passive_state(_delta: float) -> void:
		pass

	func configure_multiplayer(
		_mode: int,
		_local_peer_id: int,
		_player_names: Dictionary,
		_player_character_ids: Dictionary = {}
	) -> void:
		pass

	func get_player_for_peer(peer_id: int) -> Player:
		return peer_players.get(peer_id) as Player

	func get_enemy_for_net_id(net_id: int) -> Enemy:
		return get_network_enemy(net_id)

	func get_pickup_for_net_id(net_id: int) -> Pickup:
		return get_network_pickup(net_id)

	func remove_multiplayer_player(peer_id: int) -> void:
		peer_players.erase(peer_id)

	func ensure_reconnected_multiplayer_player(
		_old_peer_id: int,
		new_peer_id: int,
		_player_name: String,
		_character_id: StringName,
		_state: SnapshotManager.PlayerState,
		_spawn_slot_index: int,
		_reconnect_state: Dictionary = {}
	) -> CombatRuntimeBase.ReconnectedPlayerProjection:
		var player := get_player_for_peer(new_peer_id)
		return CombatRuntimeBase.ReconnectedPlayerProjection.new(
			(
				CombatRuntimeBase.ReconnectedPlayerProjectionStatus.EXISTING_CURRENT
				if player != null
				else CombatRuntimeBase.ReconnectedPlayerProjectionStatus.CREATE_FAILED
			),
			player
		)

	func collect_player_snapshot_states() -> Array[SnapshotManager.PlayerState]:
		return []

	func collect_enemy_snapshot_states() -> Array[SnapshotManager.EnemyState]:
		return []

	func play_remote_enemy_spawn_effect(_spawn_global_position: Vector2) -> void:
		pass


class ProbeEnemyCoordinator:
	extends MpEnemyCoordinator

	var remote_count := 0

	func get_remote_enemy_count() -> int:
		return remote_count


class ProbePlayer:
	extends Player

	var immediate_apply_count := 0
	var immediate_apply_healing := true
	var inventory_feedback_count := 0
	var last_pickup_config: PickupConfig = null

	func apply_pickup(
		config: PickupConfig,
		apply_healing: bool = true
	) -> bool:
		immediate_apply_count += 1
		immediate_apply_healing = apply_healing
		last_pickup_config = config
		return config != null

	func play_world_inventory_pickup_feedback(config: PickupConfig) -> void:
		inventory_feedback_count += 1
		last_pickup_config = config


class ProbeModeAdapter:
	extends MultiplayerModeAdapter

	var wave_start_peer_id := 0
	var merchant_state := false
	var flow_state: Dictionary = {}
	var boss_net_id := 0
	var defeat_reason := ""
	var defeat_apply_count := 0
	var victory_apply_count := 0
	var enemy_count_apply_count := 0
	var last_enemy_count := -1
	var wave_apply_count := 0
	var last_wave_progress: Dictionary = {}
	var wave_snapshot := {
		"wave_number": 3,
		"defeated": 4,
		"escaped": 1,
		"resolved": 5,
		"total": 9,
	}

	func supports_multiplayer_wave_progress() -> bool:
		return true

	func request_authoritative_wave_start(requester_peer_id: int) -> bool:
		wave_start_peer_id = requester_peer_id
		return true

	func get_wave_progress_snapshot() -> Dictionary:
		return wave_snapshot.duplicate()

	func get_flow_state_snapshot() -> Dictionary:
		return {
			"step_id": &"wave_active",
			"state": 2,
			"countdown_seconds": 0,
		}

	func get_multiplayer_defeat_reason() -> String:
		return "base_destroyed"

	func apply_remote_merchant_active(active: bool) -> void:
		merchant_state = active

	func apply_remote_flow_state(
		step_id: StringName,
		state: int,
		seconds: int
	) -> void:
		flow_state = {
			"step_id": step_id,
			"state": state,
			"countdown_seconds": seconds,
		}

	func apply_remote_boss_started(
		net_id: int,
		_boss_config: BossConfig,
		_spawn_position: Vector2
	) -> void:
		boss_net_id = net_id

	func apply_remote_defeat_with_reason(reason: String) -> void:
		defeat_reason = reason
		defeat_apply_count += 1

	func apply_remote_victory() -> void:
		victory_apply_count += 1

	func apply_remote_enemy_count(alive_count: int) -> void:
		last_enemy_count = alive_count
		enemy_count_apply_count += 1

	func apply_remote_wave_progress(
		wave_number: int,
		defeated: int,
		escaped: int,
		resolved: int,
		total: int
	) -> void:
		last_wave_progress = {
			"wave_number": wave_number,
			"defeated": defeated,
			"escaped": escaped,
			"resolved": resolved,
			"total": total,
		}
		wave_apply_count += 1


var failures: Array[String] = []


func _init() -> void:
	call_deferred(&"_run")


func _run() -> void:
	var coordinator: MpWorldFlowCoordinatorScript = (
		WORLD_FLOW_COORDINATOR_SCENE.instantiate()
	)
	var runtime := ProbeRuntime.new()
	var mode_adapter := ProbeModeAdapter.new()
	var enemy_coordinator := ProbeEnemyCoordinator.new()
	var gameplay_gateway := MultiplayerGameplayGateway.new()
	var run_state := RunStateStore.new()
	var net_manager := NetManagerStore.new()
	var merchant_transactions := MpMerchantTransactionsCoordinator.new()
	var pickup_container := Node2D.new()
	runtime.add_child(pickup_container)
	runtime.enemy_container = pickup_container
	_expect(coordinator != null, "WorldFlowCoordinator 场景必须可实例化。")
	var mp_game_script := load(MP_GAME_SCRIPT_PATH) as Script
	var mp_game_rpc_config: Dictionary = mp_game_script.get_rpc_config()
	var pickup_spawn_rpc := mp_game_rpc_config.get(&"net_pickup_spawned", {}) as Dictionary
	var pickup_collect_rpc := mp_game_rpc_config.get(&"net_pickup_collected", {}) as Dictionary
	_expect(
		int(pickup_spawn_rpc.get("channel", -1)) == 5
		and int(pickup_collect_rpc.get("channel", -1)) == 5,
		"Pickup spawn/collect 必须共享可靠 CH5，保证动态实体先生成再原子终结。"
	)
	if coordinator == null:
		quit(1)
		return

	var host_events: Array[StringName] = []
	var progress_packets: Array[Dictionary] = []
	var terminal_events: Array[bool] = []
	var pickup_broadcast_packets: Array[Dictionary] = []
	var pickup_peer_packets: Array[Dictionary] = []
	coordinator.rpc_broadcast_requested.connect(
		func(method_name: StringName, arguments: Array) -> void:
			host_events.append(method_name)
			pickup_broadcast_packets.append({
				"method_name": method_name,
				"arguments": arguments.duplicate(true),
			})
	)
	coordinator.rpc_to_peer_requested.connect(
		func(peer_id: int, method_name: StringName, arguments: Array) -> void:
			pickup_peer_packets.append({
				"peer_id": peer_id,
				"method_name": method_name,
				"arguments": arguments.duplicate(true),
			})
	)
	coordinator.merchant_active_broadcast_requested.connect(
		func(_active: bool) -> void:
			host_events.append(&"merchant")
	)
	coordinator.wave_progress_broadcast_requested.connect(
		func(progress: Dictionary, reliable: bool) -> void:
			progress_packets.append({
				"progress": progress.duplicate(),
				"reliable": reliable,
			})
			host_events.append(&"wave_keyframe" if reliable else &"wave_delta")
	)
	coordinator.flow_state_broadcast_requested.connect(
		func(_step_id: StringName, _state: int, _seconds: int) -> void:
			host_events.append(&"flow")
	)
	coordinator.boss_started_broadcast_requested.connect(
		func(_net_id: int, _path: String, _position: Vector2) -> void:
			host_events.append(&"boss")
	)
	coordinator.defeat_broadcast_requested.connect(
		func(_reason: String) -> void:
			host_events.append(&"defeat")
	)
	coordinator.victory_broadcast_requested.connect(
		func() -> void:
			host_events.append(&"victory")
	)
	coordinator.terminal_flow_started.connect(
		func() -> void:
			terminal_events.append(true)
	)

	run_state.begin_new_run(&"weishidaier", false)
	net_manager.net_role = NetManagerStore.NetRole.HOST
	runtime.runtime_mode = CombatRuntimeBase.RuntimeMode.HOST_AUTHORITY
	coordinator.bind_runtime(
		runtime,
		mode_adapter,
		enemy_coordinator,
		gameplay_gateway,
		run_state,
		net_manager
	)
	coordinator.bind_merchant_transactions_coordinator(merchant_transactions)
	_expect(coordinator.is_bound(), "协调器必须绑定全部六个强类型运行时依赖。")
	_expect(
		coordinator.request_authoritative_wave_start(7)
		and mode_adapter.wave_start_peer_id == 7,
		"Host 开波请求必须只经模式适配器提交。"
	)
	mode_adapter.wave_progress_changed.emit(2, 1, 0, 1, 8)
	_expect(
		coordinator.update_host(0.1)
		and progress_packets.size() == 1
		and not bool(progress_packets[0].get("reliable", true)),
		"波次进度必须继续按 0.1 秒窗口合并为不可靠包。"
	)
	mode_adapter.wave_progress_changed.emit(2, 2, 0, 2, 8)
	mode_adapter.flow_state_changed.emit(&"wave_active", 2, 0)
	_expect(
		host_events.slice(host_events.size() - 3) == [
			&"wave_delta",
			&"wave_keyframe",
			&"flow",
		],
		"流转前必须依次刷新波次增量、可靠关键帧，再发送流状态。"
	)

	var pickup_config := load(PICKUP_CONFIG_PATH) as PickupConfig
	var boss_config := load(BOSS_CONFIG_PATH) as BossConfig
	_expect(pickup_config != null and boss_config != null, "smoke 配置必须可加载。")
	if boss_config != null:
		var boss_flow_graph := FlowGraphConfig.new()
		boss_flow_graph.start_step = boss_config
		boss_flow_graph.steps = [boss_config]
		runtime.flow_graph = boss_flow_graph
		runtime.current_flow_step = boss_config
	var authoritative_inventory_snapshot: Dictionary = {}
	var live_pickup: Pickup = null
	if pickup_config != null:
		live_pickup = Pickup.new()
		live_pickup.config = pickup_config
		live_pickup.global_position = Vector2(11, 12)
		runtime.register_network_pickup(32, live_pickup)
		_expect(
			coordinator.send_live_pickup_roster_to_peer(9) == 1
			and pickup_peer_packets.size() == 1
			and int(pickup_peer_packets[0].get("peer_id", 0)) == 9
			and StringName(
				pickup_peer_packets[0].get("method_name", &"")
			) == &"net_pickup_spawned"
			and pickup_peer_packets[0].get("arguments", []) == [
				32,
				PICKUP_CONFIG_PATH,
				11.0,
				12.0,
			],
			"迟加入拾取物清单必须按固定参数顺序向目标 peer 出站。"
		)
		run_state.register_multiplayer_peer_state(7)
		_expect(
			run_state.try_add_item_for_peer(7, pickup_config),
			"Host smoke 必须先构造已提交的拾取物背包状态。"
		)
		gameplay_gateway.pickup_spawned.emit(31, pickup_config, Vector2(4, 5))
		gameplay_gateway.pickup_collected.emit(31, 7, pickup_config, false)
		if not pickup_broadcast_packets.is_empty():
			var collected_packet := pickup_broadcast_packets.back() as Dictionary
			var collected_arguments := (
				collected_packet.get("arguments", []) as Array
			)
			if collected_arguments.size() == 5:
				authoritative_inventory_snapshot = (
					collected_arguments[4] as Dictionary
				).duplicate(true)
			_expect(
				StringName(collected_packet.get("method_name", &""))
				== &"net_pickup_collected"
				and collected_arguments.size() == 5
				and int(authoritative_inventory_snapshot.get("revision", -1))
				== run_state.get_inventory_revision_for_peer(7),
				"Host 收集事件必须携带已提交 revision 的权威背包快照。"
			)
		gameplay_gateway.pickup_spawned.emit(33, pickup_config, Vector2(6, 7))
		gameplay_gateway.pickup_removed.emit(33)
	mode_adapter.merchant_active_changed.emit(true)
	if boss_config != null:
		mode_adapter.boss_started.emit(91, boss_config, Vector2(8, 9))
	mode_adapter.defeat_started.emit()
	mode_adapter.victory_started.emit()
	_expect(
		host_events.slice(host_events.size() - 8) == [
			&"net_pickup_spawned",
			&"net_pickup_collected",
			&"net_pickup_spawned",
			&"net_pickup_removed",
			&"merchant",
			&"boss",
			&"defeat",
			&"victory",
		]
		and terminal_events.size() == 2,
		"Host 原子拾取、独立移除、Boss 与胜败必须保持统一有序出站。"
	)

	coordinator.unbind_runtime(runtime)
	runtime.unregister_network_pickup(32, live_pickup)
	if live_pickup != null:
		live_pickup.free()
	run_state.begin_new_run(&"weishidaier", false)
	net_manager.net_role = NetManagerStore.NetRole.CLIENT
	runtime.runtime_mode = CombatRuntimeBase.RuntimeMode.CLIENT_VIEW
	coordinator.bind_runtime(
		runtime,
		mode_adapter,
		enemy_coordinator,
		gameplay_gateway,
		run_state,
		net_manager
	)
	var collector := ProbePlayer.new()
	runtime.peer_players[7] = collector
	var immediate_pickup_config := load(
		IMMEDIATE_PICKUP_CONFIG_PATH
	) as PickupConfig
	_expect(immediate_pickup_config != null, "即时拾取配置必须可加载。")
	coordinator.receive_pickup_spawned(140, OUTSIDE_PICKUP_PATH, Vector2.ZERO)
	_expect(
		not runtime.has_network_pickup(140),
		"目录外合法 PickupConfig 路径不得创建任何客户端世界实体。"
	)
	if pickup_config != null and immediate_pickup_config != null:
		coordinator.receive_pickup_spawned(
			46,
			PICKUP_CONFIG_PATH,
			Vector2.ZERO
		)
		_expect(
			not coordinator.receive_pickup_collected(46, 7, "", false, {})
			and runtime.has_network_pickup(46),
			"无效配置的拾取结果必须零写，不能提前移除世界掉落。"
		)
		coordinator.receive_pickup_spawned(
			47,
			PICKUP_CONFIG_PATH,
			Vector2.ZERO
		)
		_expect(
			not coordinator.receive_pickup_collected(
				47,
				7,
				PICKUP_CONFIG_PATH,
				false,
				{}
			)
			and runtime.has_network_pickup(47),
			"无效背包快照的拾取结果必须零写，不能留下世界/账本半提交。"
		)
		coordinator.receive_pickup_removed(46)
		coordinator.receive_pickup_removed(47)

		coordinator.receive_pickup_spawned(
			41,
			PICKUP_CONFIG_PATH,
			Vector2(21, 22)
		)
		var spawned_pickup := runtime.get_pickup_for_net_id(41)
		_expect(
			spawned_pickup != null
			and spawned_pickup.config == pickup_config
			and spawned_pickup.global_position == Vector2(21, 22)
			and spawned_pickup.collision_layer == 0
			and spawned_pickup.collision_mask == 0,
			"客户端生成拾取物必须加载配置、定位并关闭本地碰撞。"
		)
		coordinator.receive_pickup_removed(41)
		_expect(
			not runtime.has_network_pickup(41),
			"客户端移除事件必须立即清理拾取物索引。"
		)

		coordinator.receive_pickup_spawned(
			42,
			IMMEDIATE_PICKUP_CONFIG_PATH,
			Vector2.ZERO
		)
		var immediate_pickup_applied := coordinator.receive_pickup_collected(
			42,
			7,
			IMMEDIATE_PICKUP_CONFIG_PATH,
			true
		)
		_expect(
			immediate_pickup_applied
			and not runtime.has_network_pickup(42)
			and collector.immediate_apply_count == 1
			and not collector.immediate_apply_healing
			and collector.last_pickup_config == immediate_pickup_config,
			"即时拾取必须成功重放效果后再终结世界实例，并禁用重复治疗。"
		)
		_expect(
			not coordinator.receive_pickup_collected(
				42,
				7,
				IMMEDIATE_PICKUP_CONFIG_PATH,
				true
			)
			and collector.immediate_apply_count == 1,
			"即时拾取可靠重放即使越过 applied LRU，也必须由世界实例 fence 阻止重复效果。"
		)
		_expect(
			not coordinator.receive_pickup_collected(
				49,
				7,
				IMMEDIATE_PICKUP_CONFIG_PATH,
				true
			)
			and collector.immediate_apply_count == 1,
			"CH6 collect 先于 CH5 spawn 时不得提前应用即时效果，应等待完整状态修复。"
		)

		coordinator.receive_pickup_spawned(
			48,
			IMMEDIATE_PICKUP_CONFIG_PATH,
			Vector2.ZERO
		)
		runtime.peer_players.erase(7)
		_expect(
			not coordinator.receive_pickup_collected(
				48,
				7,
				IMMEDIATE_PICKUP_CONFIG_PATH,
				true
			)
			and runtime.has_network_pickup(48),
			"即时效果缺少 Player 投影时必须零写，等待完整状态修复同时收敛效果与世界实体。"
		)
		runtime.peer_players[7] = collector
		coordinator.receive_pickup_removed(48)

		run_state.register_multiplayer_peer_state(7)
		coordinator.receive_pickup_spawned(
			43,
			PICKUP_CONFIG_PATH,
			Vector2.ZERO
		)
		var inventory_pickup_applied := coordinator.receive_pickup_collected(
			43,
			7,
			PICKUP_CONFIG_PATH,
			false,
			authoritative_inventory_snapshot
		)
		var applied_inventory_revision := (
			run_state.get_inventory_revision_for_peer(7)
		)
		_expect(
			inventory_pickup_applied
			and not runtime.has_network_pickup(43)
			and applied_inventory_revision
			== int(authoritative_inventory_snapshot.get("revision", -1))
			and collector.inventory_feedback_count == 1
			and collector.last_pickup_config == pickup_config,
			"有效背包必须先提交账本，再移除掉落并只播放一次收入反馈。"
		)
		coordinator.receive_pickup_spawned(
			44,
			PICKUP_CONFIG_PATH,
			Vector2.ZERO
		)
		coordinator.receive_pickup_collected(
			44,
			7,
			PICKUP_CONFIG_PATH,
			false,
			authoritative_inventory_snapshot
		)
		_expect(
			not runtime.has_network_pickup(44)
			and run_state.get_inventory_revision_for_peer(7)
			== applied_inventory_revision
			and collector.inventory_feedback_count == 1,
			"重复或同 revision 背包快照不得重复播放拾取反馈。"
		)
		var lifecycle_gap_snapshot := authoritative_inventory_snapshot.duplicate(true)
		lifecycle_gap_snapshot["revision"] = applied_inventory_revision + 1
		var lifecycle_gap_slots: Array = []
		for raw_slot in lifecycle_gap_snapshot["slots"] as Array:
			var slot := (raw_slot as Dictionary).duplicate(true)
			slot["revision"] = applied_inventory_revision + 1
			lifecycle_gap_slots.append(slot)
		lifecycle_gap_snapshot["slots"] = lifecycle_gap_slots
		coordinator.receive_pickup_spawned(
			45,
			PICKUP_CONFIG_PATH,
			Vector2.ZERO
		)
		runtime.peer_players.erase(7)
		coordinator.receive_pickup_collected(
			45,
			7,
			PICKUP_CONFIG_PATH,
			false,
			lifecycle_gap_snapshot
		)
		_expect(
			run_state.get_inventory_revision_for_peer(7)
			== applied_inventory_revision + 1
			and not runtime.has_network_pickup(45)
			and collector.inventory_feedback_count == 1,
			"Player 节点缺席时，拾取结果仍必须推进背包账本且不伪造表现。"
		)
	coordinator.receive_merchant_active(true)
	coordinator.receive_flow_state(&"wave_active", 2, 3)
	enemy_coordinator.remote_count = 12
	var first_enemy_apply: bool = coordinator.update_client_enemy_count()
	var duplicate_enemy_apply: bool = coordinator.update_client_enemy_count()
	coordinator.receive_flow_state(&"wave_active", 2, 2)
	var invalidated_enemy_apply: bool = coordinator.update_client_enemy_count()
	coordinator.receive_wave_progress(4, 6, 1, 7, 10)
	var active_boss_step := runtime.current_flow_step as BossConfig
	runtime.flow_graph.steps.clear()
	coordinator.receive_boss_started(97, BOSS_CONFIG_PATH, Vector2.ZERO, 4.0)
	_expect(
		mode_adapter.boss_net_id == 0,
		"即使路径指向全局合法 BossConfig，不属于当前活动 flow 也必须拒绝。"
	)
	if active_boss_step != null:
		runtime.flow_graph.steps = [active_boss_step]
	coordinator.receive_boss_started(98, OUTSIDE_PICKUP_PATH, Vector2.ZERO, 4.0)
	_expect(
		mode_adapter.boss_net_id == 0,
		"Boss 实例事件只能引用当前活动 flow 中的精确 BossConfig。"
	)
	coordinator.receive_boss_started(99, BOSS_CONFIG_PATH, Vector2.ZERO, 4.0)
	coordinator.receive_defeat("timeout")
	coordinator.receive_victory()
	_expect(
		mode_adapter.merchant_state
		and StringName(mode_adapter.flow_state.get("step_id", &"")) == &"wave_active"
		and first_enemy_apply
		and not duplicate_enemy_apply
		and invalidated_enemy_apply
		and mode_adapter.enemy_count_apply_count == 2
		and mode_adapter.last_enemy_count == 12,
		"客户端敌人数只应在变化或流转失效后重绘。"
	)
	_expect(
		mode_adapter.wave_apply_count == 1
		and mode_adapter.last_wave_progress == {
			"wave_number": 4,
			"defeated": 6,
			"escaped": 1,
			"resolved": 7,
			"total": 10,
		}
		and mode_adapter.boss_net_id == 99
		and mode_adapter.defeat_reason == "timeout"
		and mode_adapter.defeat_apply_count == 1
		and mode_adapter.victory_apply_count == 1,
		"客户端流转、Boss 与胜败必须只经模式适配器应用。"
	)

	coordinator.unbind_runtime(runtime)
	var metrics: Dictionary = coordinator.get_state_metrics()
	_expect(
		not coordinator.is_bound()
		and int(metrics.get("pending_wave_progress", -1)) == 0
		and not bool(metrics.get("client_has_received_flow_state", true))
		and int(metrics.get("last_applied_remote_enemy_count", 0)) == -1,
		"解绑必须清空所有会话态。"
	)
	_test_pickup_delegation_contract()

	coordinator.free()
	gameplay_gateway.free()
	enemy_coordinator.free()
	mode_adapter.free()
	merchant_transactions.free()
	runtime.peer_players.erase(7)
	collector.free()
	runtime.free()
	run_state.free()
	net_manager.free()
	if failures.is_empty():
		print("MP_WORLD_FLOW_COORDINATOR_SMOKE_TEST_OK")
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	quit(1)


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)


func _test_pickup_delegation_contract() -> void:
	var root_source := FileAccess.get_file_as_string(
		"res://scene/multiplayer/mp_game.gd"
	)
	var session_source := FileAccess.get_file_as_string(
		"res://scene/multiplayer/session/mp_session_coordinator.gd"
	)
	var coordinator_source := FileAccess.get_file_as_string(
		"res://scene/multiplayer/world_flow/mp_world_flow_coordinator.gd"
	)
	_expect(
		session_source.contains(
			"_world_flow_coordinator.send_live_pickup_roster_to_peer(peer_id)"
		)
		and root_source.contains(
			"world_flow_coordinator.receive_pickup_collected("
		)
		and not root_source.contains("func _on_host_pickup_collected("),
		"Session/MpGame 必须把迟加入清单和收集应用收口为 WorldFlow 薄门面。"
	)
	_expect(
		coordinator_source.contains(
			"_gameplay_gateway.pickup_collected, _on_host_pickup_collected"
		)
		and coordinator_source.contains(
			"_run_state.prepare_inventory_snapshot_for_peer("
		)
		and coordinator_source.contains(
			"_run_state.commit_prepared_inventory_snapshot_for_peer("
		)
		and coordinator_source.contains("signal rpc_to_peer_requested(")
		and coordinator_source.contains("signal rpc_broadcast_requested("),
		"WorldFlow 必须拥有强类型拾取信号、背包 revision 与统一出站边界。"
	)
