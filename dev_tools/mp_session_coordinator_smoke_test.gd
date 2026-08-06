extends SceneTree

const SESSION_SCENE := preload(
	"res://scene/multiplayer/session/mp_session_coordinator.tscn"
)
const NetConstants := preload("res://scene/multiplayer/net_constants.gd")


class ProbeRuntime:
	extends CombatRuntimeBase

	var players: Dictionary[int, Player] = {}
	var lookup_count := 0

	func configure_multiplayer(
		_mode: int,
		_local_peer_id: int,
		_player_names: Dictionary,
		_player_character_ids: Dictionary = {}
	) -> void:
		pass

	func get_player_for_peer(peer_id: int) -> Player:
		lookup_count += 1
		return players.get(peer_id) as Player

	func get_enemy_for_net_id(_net_id: int) -> Enemy:
		return null

	func get_pickup_for_net_id(_net_id: int) -> Pickup:
		return null

	func remove_multiplayer_player(_peer_id: int) -> void:
		pass

	func collect_player_snapshot_states() -> Array[SnapshotManager.PlayerState]:
		return []

	func collect_enemy_snapshot_states() -> Array[SnapshotManager.EnemyState]:
		return []

	func play_remote_enemy_spawn_effect(_spawn_global_position: Vector2) -> void:
		pass


class ProbeWorldFlowCoordinator:
	extends MpWorldFlowCoordinator

	var events: Array[String] = []

	func receive_pickup_removed(net_id: int) -> void:
		events.append("pickup:%d" % net_id)


class ProbeEnemyCoordinator:
	extends MpEnemyCoordinator

	var events: Array[String] = []
	var last_live_enemy_ids: Dictionary = {}

	func remove_enemies_missing_from_manifest(live_enemy_ids: Dictionary) -> void:
		last_live_enemy_ids = live_enemy_ids.duplicate()
		events.append("enemy")


class ProbeTowerWorldCoordinator:
	extends MpTowerWorldCoordinator

	var events: Array[String] = []
	var last_plant_id_set: Dictionary = {}
	var last_positive_plant_ids := PackedInt32Array()
	var removed_ids := PackedInt32Array([8, 10])

	func is_bound() -> bool:
		return true

	func find_live_plant_ids_missing_from_manifest(
		plant_id_set: Dictionary
	) -> PackedInt32Array:
		last_plant_id_set = plant_id_set.duplicate()
		events.append("find_plants")
		return removed_ids.duplicate()

	func reconcile_runtime_manifest(
		plant_id_set: Dictionary,
		positive_plant_ids: PackedInt32Array,
		_manifest_removed_ids: PackedInt32Array
	) -> void:
		last_plant_id_set = plant_id_set.duplicate()
		last_positive_plant_ids = positive_plant_ids.duplicate()
		events.append("reconcile_plants")


class ProbeTowerEconomyCoordinator:
	extends MpTowerEconomyCoordinator

	var events: Array[String] = []

	func notify_plant_removed(net_id: int) -> void:
		events.append("plant_removed:%d" % net_id)

	func notify_plant_available(net_id: int) -> void:
		events.append("plant_available:%d" % net_id)

	func try_apply_pending_warehouse_snapshots_atomically() -> bool:
		events.append("apply_warehouse")
		return true


var failures: Array[String] = []


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	var coordinator := SESSION_SCENE.instantiate() as MpSessionCoordinator
	var runtime := ProbeRuntime.new()
	var player := Player.new()
	runtime.players[7] = player

	_expect(coordinator != null, "SessionCoordinator 场景必须可实例化。")
	_expect(
		not coordinator.try_begin_client_runtime_state_request(true, true),
		"未绑定运行时时不得锁定客户端修复请求。"
	)
	coordinator.bind_runtime(runtime)
	_expect(coordinator.is_bound(), "SessionCoordinator 必须绑定强类型运行时。")
	_expect(
		coordinator.try_begin_client_runtime_state_request(true, true),
		"客户端在 Host ready 后必须允许首个修复请求。"
	)
	_expect(
		not coordinator.try_begin_client_runtime_state_request(true, true),
		"同一会话只能发起一次初始修复请求。"
	)

	_expect(
		coordinator.admit_authoritative_runtime_state_request(true, 7, 10.0),
		"Host 必须接受 burst 内第一个已登录玩家请求。"
	)
	_expect(
		coordinator.admit_authoritative_runtime_state_request(true, 7, 10.0),
		"Host 必须接受 burst 内第二个已登录玩家请求。"
	)
	_expect(
		not coordinator.admit_authoritative_runtime_state_request(true, 7, 10.0),
		"同一时刻第三个修复请求必须被限流。"
	)
	_expect(runtime.lookup_count == 2, "限流必须发生在玩家解析之前。")
	coordinator.clear_peer(7)
	_expect(
		coordinator.admit_authoritative_runtime_state_request(true, 7, 10.0),
		"清理 peer 后必须恢复该玩家独立 burst。"
	)
	_expect(
		not coordinator.admit_authoritative_runtime_state_request(true, 8, 10.0),
		"不存在的玩家不得触发完整状态发送。"
	)

	var manifest := coordinator.parse_runtime_world_manifest(
		PackedInt32Array([-1, 0, 2, 2, 4]),
		PackedInt32Array([0, 3, 3]),
		PackedInt32Array([-5, 6, 6, 0, 9])
	)
	_expect(
		manifest.enemy_id_set.keys() == [2, 4]
		and manifest.pickup_id_set.keys() == [3]
		and manifest.plant_id_set.keys() == [6, 9],
		"manifest membership 必须过滤非正 ID 并去重。"
	)
	_expect(
		manifest.positive_plant_ids == PackedInt32Array([6, 6, 9]),
		"plant marker 清理序列必须保留输入顺序与重复项。"
	)

	var net_manager := NetManagerStore.new()
	var keepalive_request := HTTPRequest.new()
	coordinator.bind_transport_dependencies(net_manager, keepalive_request)
	var manifest_events: Array[String] = []
	var world_flow_coordinator := ProbeWorldFlowCoordinator.new()
	var enemy_coordinator := ProbeEnemyCoordinator.new()
	var tower_world_coordinator := ProbeTowerWorldCoordinator.new()
	var tower_economy_coordinator := ProbeTowerEconomyCoordinator.new()
	world_flow_coordinator.events = manifest_events
	enemy_coordinator.events = manifest_events
	tower_world_coordinator.events = manifest_events
	tower_economy_coordinator.events = manifest_events
	coordinator.bind_world_manifest_dependencies(
		world_flow_coordinator,
		enemy_coordinator,
		tower_world_coordinator,
		tower_economy_coordinator
	)
	runtime.multiplayer_pickups[3] = null
	runtime.multiplayer_pickups[4] = null
	_expect(
		coordinator.apply_runtime_world_manifest(
			PackedInt32Array([2, 7]),
			PackedInt32Array([4]),
			PackedInt32Array([6, 6, 9])
		),
		"客户端完整 manifest 必须由 SessionCoordinator 接管。"
	)
	_expect(
		manifest_events == [
			"enemy",
			"pickup:3",
			"plant_available:6",
			"plant_available:6",
			"plant_available:9",
			"find_plants",
			"plant_removed:8",
			"plant_removed:10",
			"reconcile_plants",
			"apply_warehouse",
		],
		"manifest 必须保持敌人、拾取、植物 marker、移除、重建、仓库补交顺序。"
	)
	_expect(
		enemy_coordinator.last_live_enemy_ids.keys() == [2, 7]
		and tower_world_coordinator.last_plant_id_set.keys() == [6, 9]
		and tower_world_coordinator.last_positive_plant_ids
		== PackedInt32Array([6, 6, 9]),
		"manifest 迁移不得改变成员去重或正植物 ID 的重复顺序。"
	)
	_expect(
		keepalive_request.request_completed.is_connected(
			Callable(coordinator, "_on_public_room_keepalive_completed")
		),
		"静态 HTTPRequest 必须由 SessionCoordinator 接管完成信号。"
	)
	_expect(
		coordinator.get_net_time() >= 0.0,
		"绑定传输依赖后，本地网络时钟必须从非负时间开始。"
	)
	var unsynchronized_host_time := coordinator.get_net_time() - 0.5
	var first_mapped_time := coordinator.map_host_timestamp_to_client_time(
		unsynchronized_host_time
	)
	var first_offset := coordinator.get_host_to_client_time_offset()
	_expect(
		coordinator.has_host_time_offset()
		and first_offset >= 0.49
		and first_offset <= 0.55
		and absf(first_mapped_time - coordinator.get_net_time()) <= 0.02,
		"首个 Host 时间样本必须直接建立本地偏移。"
	)
	var second_host_time := coordinator.get_net_time() - 1.5
	coordinator.map_host_timestamp_to_client_time(second_host_time)
	var smoothed_offset := coordinator.get_host_to_client_time_offset()
	_expect(
		smoothed_offset >= first_offset + 0.07
		and smoothed_offset <= first_offset + 0.09,
		"后续 Host 时间样本必须严格使用 0.08 权重平滑。"
	)
	var stable_host_time := 12.5
	_expect(
		is_equal_approx(
			coordinator.map_host_timestamp_to_client_time(stable_host_time, false),
			stable_host_time + smoothed_offset
		),
		"禁用偏移更新时必须复用既有 Host→Client 映射。"
	)

	_expect(
		not coordinator.should_send_public_room_keepalive(),
		"无公网 Host 上下文时不得发送房间续租。"
	)
	net_manager.net_role = NetManagerStore.NetRole.HOST
	net_manager.conn_mode = NetManagerStore.ConnMode.RELAY
	net_manager.set_public_room_context(" room-a ", " token-a ", true)
	_expect(
		coordinator.should_send_public_room_keepalive(),
		"Relay 公网房主且房间与令牌完整时必须具备续租资格。"
	)
	coordinator.call(
		"_on_public_room_keepalive_completed",
		HTTPRequest.RESULT_SUCCESS,
		204,
		PackedStringArray(),
		'{"relay_running":true}'.to_utf8_buffer()
	)
	_expect(
		is_equal_approx(
			coordinator.get_public_room_keepalive_time_left(),
			NetConstants.PUBLIC_ROOM_KEEPALIVE_INTERVAL_SECONDS
		)
		and not coordinator.is_public_room_keepalive_in_flight(),
		"成功完成续租后必须恢复既有 60 秒计时并解除 in-flight。"
	)
	coordinator.reset_transport_state()
	_expect(
		not coordinator.has_host_time_offset()
		and is_zero_approx(coordinator.get_host_to_client_time_offset())
		and is_zero_approx(coordinator.get_public_room_keepalive_time_left())
		and not coordinator.is_public_room_keepalive_in_flight(),
		"传输 reset 必须清理时钟映射、续租计时与 in-flight。"
	)
	net_manager.net_role = NetManagerStore.NetRole.CLIENT
	_expect(
		not coordinator.should_send_public_room_keepalive(),
		"Relay 客户端即使持有房间上下文也不得发送续租。"
	)
	coordinator.update_transport(1.0)
	_expect(
		is_zero_approx(coordinator.get_public_room_keepalive_time_left()),
		"不具备续租资格时 update 必须保持计时归零。"
	)
	_test_static_delegation_contract()

	coordinator.unbind_runtime(runtime)
	_expect(not coordinator.is_bound(), "解绑后不得继续持有旧战斗运行时。")
	_expect(
		not coordinator.has_world_manifest_dependencies(),
		"解绑运行时必须同时释放 manifest 强类型依赖。"
	)
	_expect(
		not coordinator.has_requested_runtime_state(),
		"解绑必须清理会话级客户端 latch。"
	)
	coordinator.unbind_transport_dependencies()
	_expect(
		not keepalive_request.request_completed.is_connected(
			Callable(coordinator, "_on_public_room_keepalive_completed")
		),
		"解绑传输依赖必须断开静态 HTTPRequest 完成信号。"
	)
	player.free()
	runtime.free()
	net_manager.free()
	keepalive_request.free()
	world_flow_coordinator.free()
	enemy_coordinator.free()
	tower_world_coordinator.free()
	tower_economy_coordinator.free()
	coordinator.free()

	if failures.is_empty():
		print("MP_SESSION_COORDINATOR_SMOKE_TEST_OK")
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	quit(1)


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)


func _test_static_delegation_contract() -> void:
	var root_source := FileAccess.get_file_as_string(
		"res://scene/multiplayer/mp_game.gd"
	)
	var coordinator_source := FileAccess.get_file_as_string(
		"res://scene/multiplayer/session/mp_session_coordinator.gd"
	)
	var player_source := FileAccess.get_file_as_string(
		"res://scene/multiplayer/player/mp_player_coordinator.gd"
	)
	var transactions_source := FileAccess.get_file_as_string(
		"res://scene/multiplayer/transactions/mp_transactions_coordinator.gd"
	)
	var world_flow_source := FileAccess.get_file_as_string(
		"res://scene/multiplayer/world_flow/mp_world_flow_coordinator.gd"
	)
	_expect(
		root_source.contains("session_coordinator.update_transport(delta)")
		and root_source.contains("return session_coordinator.get_net_time()")
		and root_source.contains(
			"return session_coordinator.map_host_timestamp_to_client_time("
		)
		and not root_source.contains("var _public_room_keepalive_time_left")
		and not root_source.contains("var _host_to_client_time_offset"),
		"MpGame 必须仅保留时钟薄门面并将 process 委托给会话协调器。"
	)
	_expect(
		coordinator_source.contains("_NetConstants.PUBLIC_LOBBY_API_BASE_URL")
		and coordinator_source.contains(
			"JSON.stringify({\"host_token\": host_token})"
		)
		and coordinator_source.contains(
			"const HOST_TIME_OFFSET_SMOOTH_WEIGHT := 0.08"
		),
		"会话协调器必须保留既有 API、JSON 载荷与 0.08 平滑常量。"
	)
	var repair_start := coordinator_source.find(
		"func send_authoritative_runtime_state_to_peer("
	)
	var repair_end := coordinator_source.find(
		"func _send_runtime_world_manifest_to_peer(",
		repair_start
	)
	var repair_source := coordinator_source.substr(
		repair_start,
		repair_end - repair_start
	)
	_expect(
		repair_start >= 0
		and repair_end > repair_start
		and _contains_in_order(
			repair_source,
			[
				"record_state_repair()",
				"request_terrain_snapshot_for_peer(peer_id)",
				"runtime_repair_plant_roster_requested.emit(peer_id)",
				"build_runtime_repair_inventory_rpc_arguments()",
				"send_offer_state_if_present(peer_id)",
				"send_live_spawn_roster_to_peer(peer_id)",
				"send_live_pickup_roster_to_peer(peer_id)",
				"request_base_health_snapshot_for_peer(peer_id)",
				"get_wave_progress_snapshot()",
				"send_fate_state_to_peer(peer_id)",
				"send_authoritative_positions_to_peer(peer_id)",
				"request_test_arena_manual_night_for_peer(",
				"get_flow_state_snapshot()",
				"send_active_tango_electric_surges_to_peer(peer_id)",
				"send_active_tiyi_high_noon_to_peer(peer_id)",
				"_send_runtime_world_manifest_to_peer(peer_id)",
			]
		),
		"完整状态修复必须由 SessionCoordinator 保持原跨模块发送顺序。"
	)
	_expect(
		not root_source.contains("func _send_runtime_world_manifest_to_peer(")
		and not root_source.contains("func _send_runtime_state_to_peer(")
		and root_source.contains(
			"return session_coordinator.handle_authoritative_runtime_state_request("
		)
		and root_source.contains(
			"return session_coordinator.get_connected_client_peer_ids("
		)
		and root_source.contains(
			"tower_world_coordinator.send_live_plant_roster_to_peer(peer_id)"
		),
		"MpGame 必须只保留状态修复、peer 筛选与植物 roster 薄门面。"
	)
	_expect(
		player_source.contains(
			"func send_authoritative_positions_to_peer(target_peer_id: int)"
		)
		and transactions_source.contains(
			"func build_runtime_repair_inventory_rpc_arguments() -> Array[Array]"
		)
		and world_flow_source.contains(
			"_merchant_transactions_coordinator.clear_offer_states()"
		)
		and not root_source.contains(
			"merchant_transactions_coordinator.clear_offer_states()"
		),
		"位置、背包与商人 offer 生命周期必须由各自协调器负责。"
	)


func _contains_in_order(source: String, tokens: Array[String]) -> bool:
	var cursor := 0
	for token in tokens:
		var token_index := source.find(token, cursor)
		if token_index < 0:
			return false
		cursor = token_index + token.length()
	return true
