extends SceneTree

const SESSION_SCENE := preload(
	"res://scene/multiplayer/session/mp_session_coordinator.tscn"
)


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

	coordinator.unbind_runtime(runtime)
	_expect(not coordinator.is_bound(), "解绑后不得继续持有旧战斗运行时。")
	_expect(
		not coordinator.has_requested_runtime_state(),
		"解绑必须清理会话级客户端 latch。"
	)
	player.free()
	runtime.free()
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
