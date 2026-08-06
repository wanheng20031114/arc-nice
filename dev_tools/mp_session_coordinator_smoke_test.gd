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
