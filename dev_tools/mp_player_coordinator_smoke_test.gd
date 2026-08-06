extends SceneTree

const PLAYER_COORDINATOR_SCENE := preload(
	"res://scene/multiplayer/player/mp_player_coordinator.tscn"
)


class ProbeRuntime:
	extends CombatRuntimeBase

	func configure_multiplayer(
		_mode: int,
		_local_peer_id: int,
		_player_names: Dictionary,
		_player_character_ids: Dictionary = {}
	) -> void:
		pass

	func get_player_for_peer(peer_id: int) -> Player:
		return peer_players.get(peer_id) as Player

	func get_enemy_for_net_id(_net_id: int) -> Enemy:
		return null

	func get_pickup_for_net_id(_net_id: int) -> Pickup:
		return null

	func remove_multiplayer_player(peer_id: int) -> void:
		peer_players.erase(peer_id)

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
	var coordinator := (
		PLAYER_COORDINATOR_SCENE.instantiate() as MpPlayerCoordinator
	)
	var runtime := ProbeRuntime.new()
	_expect(coordinator != null, "PlayerCoordinator 场景必须可实例化。")
	var prebind_target := Vector2(320.0, 180.0)
	_expect(
		coordinator.queue_authoritative_teleport(
			9,
			prebind_target,
			4,
			3,
			1.0
		),
		"运行时装配前到达的可靠传送必须进入等待队列。"
	)
	coordinator.bind_runtime(runtime)
	_expect(coordinator.is_bound(), "PlayerCoordinator 必须强类型绑定战斗运行时。")
	_expect(
		coordinator.has_pending_authoritative_teleport(9),
		"首次绑定运行时不得清除更早到达的可靠传送。"
	)
	var prebind_player := Player.new()
	runtime.runtime_mode = CombatRuntimeBase.RuntimeMode.CLIENT_VIEW
	runtime.multiplayer_local_peer_id = 3
	runtime.peer_players[9] = prebind_player
	_expect(
		coordinator.try_apply_pending_authoritative_teleport(9, 3, 1.5),
		"玩家装配后必须补交绑定前缓存的可靠传送。"
	)
	_expect(
		prebind_player.global_position == prebind_target
		and not coordinator.has_pending_authoritative_teleport(9),
		"补交后的可靠传送位置或等待队列状态错误。"
	)
	coordinator.clear_peer(9)
	runtime.peer_players.erase(9)
	prebind_player.free()

	runtime.runtime_mode = CombatRuntimeBase.RuntimeMode.HOST_AUTHORITY
	coordinator.remember_latest_client_state(
		true,
		2,
		Vector2(88.0, 42.0),
		Vector2(5.0, -3.0),
		3,
		7
	)
	var state := SnapshotManager.PlayerState.new()
	state.peer_id = 2
	state.character_id = &"weishidaier"
	state.position = Vector2(1.0, 2.0)
	state.velocity = Vector2.ZERO
	state.current_health = 80
	state.max_health = 100
	var states: Array[SnapshotManager.PlayerState] = [state]
	var ready_peers: Array[int] = [2, 3]
	coordinator.sync_snapshot_cohort_readiness(ready_peers)
	var batch := coordinator.build_host_snapshot_batch(
		states,
		ready_peers,
		12.5,
		{2: 9}
	)
	_expect(batch != null and not batch.is_empty(), "Host 必须生成玩家快照批次。")
	if batch != null:
		_expect(batch.peer_ids == ready_peers, "批次接收者顺序必须保持不变。")
		var receiver := SnapshotManager.new()
		var decoded := receiver.decode_player_snapshots_with_baseline(batch.data)
		_expect(decoded.size() == 1, "玩家快照必须可由现有协议解码。")
		if decoded.size() == 1:
			var decoded_state := decoded[0] as SnapshotManager.PlayerState
			_expect(decoded_state.sequence == 1, "首批 Host 快照序列必须为 1。")
			_expect(decoded_state.health_revision == 9, "可靠生命 revision 必须写入快照。")
			_expect(
				decoded_state.position.distance_to(Vector2(88.0, 42.0)) < 0.12,
				"Host 快照必须采用最新已接纳的客户端位置。"
			)
	_expect(coordinator.get_snapshot_encode_count() == 1, "编码计数必须由协调器持有。")
	_expect(coordinator.get_snapshot_cohort_size() == 2, "cohort 成员必须由协调器持有。")

	var remote_player := Player.new()
	runtime.runtime_mode = CombatRuntimeBase.RuntimeMode.CLIENT_VIEW
	runtime.multiplayer_local_peer_id = 3
	runtime.peer_players[2] = remote_player
	var target_position := Vector2(4096.0, 3072.0)
	_expect(
		coordinator.queue_authoritative_teleport(
			2,
			target_position,
			17,
			3,
			20.0
		),
		"可靠传送必须被玩家协调器接受。"
	)
	_expect(
		remote_player.global_position == target_position,
		"可靠传送必须立即写入已存在的远端玩家。"
	)
	var interpolator := coordinator.get_visual_interpolator(2)
	_expect(
		interpolator != null and interpolator.get_buffer_size() == 1,
		"可靠传送必须重置远端视觉插值历史。"
	)
	_expect(
		not coordinator.accept_snapshot_motion_after_teleport(2, 17),
		"跨信道到达的旧快照不得回拉已传送玩家。"
	)
	_expect(
		coordinator.accept_snapshot_motion_after_teleport(2, 18),
		"首个较新快照必须释放传送屏障。"
	)
	coordinator.mark_health_revision_applied(2, 6)
	coordinator.mark_health_revision_applied(2, 4)
	_expect(
		coordinator.get_applied_health_revision(2) == 6,
		"快照生命 revision 栅栏不得回退。"
	)
	coordinator.clear_peer(2)
	_expect(
		not coordinator.has_visual_interpolator(2)
		and not coordinator.has_latest_client_state(2)
		and coordinator.get_applied_health_revision(2) == 0,
		"peer 清理必须释放全部玩家快照专属状态。"
	)

	runtime.peer_players.clear()
	remote_player.free()
	coordinator.unbind_runtime(runtime)
	_expect(not coordinator.is_bound(), "解绑后不得保留旧战斗运行时。")
	runtime.free()
	coordinator.free()

	if failures.is_empty():
		print("MP_PLAYER_COORDINATOR_SMOKE_TEST_OK")
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	quit(1)


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
