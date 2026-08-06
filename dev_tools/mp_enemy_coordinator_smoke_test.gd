extends SceneTree

const ENEMY_COORDINATOR_SCENE := preload(
	"res://scene/multiplayer/enemy/mp_enemy_coordinator.tscn"
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

	func get_enemy_for_net_id(net_id: int) -> Enemy:
		return multiplayer_enemies_by_net_id.get(net_id) as Enemy

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
	var coordinator := ENEMY_COORDINATOR_SCENE.instantiate() as MpEnemyCoordinator
	var runtime := ProbeRuntime.new()
	_expect(coordinator != null, "EnemyCoordinator 场景必须可实例化。")
	if coordinator == null:
		quit(1)
		return
	coordinator.bind_runtime(runtime)
	_expect(coordinator.is_bound(), "EnemyCoordinator 必须强类型绑定战斗运行时。")

	runtime.runtime_mode = CombatRuntimeBase.RuntimeMode.HOST_AUTHORITY
	var states: Array[SnapshotManager.EnemyState] = []
	for net_id in range(1, 49):
		var state := SnapshotManager.EnemyState.new()
		state.net_id = net_id
		state.position = Vector2(net_id * 3.0, net_id * -2.0)
		state.velocity = Vector2(4.0, -1.0)
		state.locomotion_state = 1
		state.health = 100 - net_id
		state.health_revision = net_id
		states.append(state)
	var peers: Array[int] = [2, 3]
	var snapshot_batch := coordinator.build_host_snapshot_batch(states, peers, 12.5)
	_expect(
		snapshot_batch != null
		and snapshot_batch.peer_ids == peers
		and snapshot_batch.chunk_count == 2
		and snapshot_batch.chunks.size() == 2,
		"48 个敌人必须沿既有线协议拆成两个有序快照块。"
	)
	if snapshot_batch != null and not snapshot_batch.chunks.is_empty():
		var decoder := SnapshotManager.new()
		var decoded := decoder.decode_enemy_snapshots_with_baseline(
			snapshot_batch.chunks[0].data,
			false
		)
		_expect(
			decoded.size() == MpEnemyCoordinator.ENEMY_SNAPSHOT_CHUNK_MAX_ENTITIES,
			"首个快照块必须保持既有 46 实体 MTU 上限。"
		)

	coordinator.queue_damage_feedback(
		7,
		80,
		1,
		12,
		Vector2.LEFT,
		EnemyConfig.DamageType.PHYSICAL,
		false
	)
	coordinator.queue_damage_feedback(
		7,
		65,
		2,
		15,
		Vector2.RIGHT,
		EnemyConfig.DamageType.MAGIC,
		true
	)
	var feedback_batches := coordinator.drain_damage_feedback_batches()
	_expect(
		feedback_batches.size() == 1
		and feedback_batches[0].net_ids == PackedInt32Array([7])
		and feedback_batches[0].health_values == PackedInt32Array([65])
		and feedback_batches[0].health_revisions == PackedInt32Array([2])
		and feedback_batches[0].damage_values == PackedInt32Array([27])
		and feedback_batches[0].damage_types == PackedByteArray([
			EnemyConfig.DamageType.MAGIC
		])
		and feedback_batches[0].particle_flags == PackedByteArray([1]),
		"同一敌人的不可靠伤害反馈必须合并最终生命、revision、总伤害与粒子标记。"
	)

	runtime.runtime_mode = CombatRuntimeBase.RuntimeMode.CLIENT_VIEW
	coordinator.receive_enemy_target_action(
		401,
		&"windup",
		2,
		Vector2(10.0, 20.0),
		9,
		20.1,
		20.2,
		100.0
	)
	coordinator.receive_enemy_target_action(
		401,
		&"windup_retry",
		2,
		Vector2(11.0, 21.0),
		9,
		20.15,
		20.2,
		100.1
	)
	coordinator.receive_enemy_target_action(
		401,
		&"stale_retry",
		2,
		Vector2(12.0, 22.0),
		9,
		20.05,
		20.2,
		99.9
	)
	var pending := coordinator.pending_enemy_actions.get(401, {}) as Dictionary
	_expect(
		coordinator.pending_enemy_actions.size() == 1
		and StringName(pending.get("action_name", &"")) == &"windup_retry",
		"未生成敌人的同 action-id 重试必须只保留 Host 时间较新的记录。"
	)
	coordinator.receive_enemy_terminal(
		401,
		MpEnemyCoordinator.ENEMY_TERMINAL_REMOVED,
		Vector2.ZERO,
		0,
		0,
		0,
		Vector2.ZERO,
		EnemyConfig.DamageType.PHYSICAL,
		false
	)
	coordinator.receive_enemy_action(
		401,
		&"late_cancel",
		Vector2.RIGHT,
		Vector2.ZERO,
		10,
		20.3,
		20.3,
		100.2
	)
	_expect(
		coordinator.client_terminal_enemy_ids.has(401)
		and not coordinator.pending_enemy_actions.has(401),
		"可靠终结墓碑必须阻止较晚到达的 CH7 动作重建等待状态。"
	)

	coordinator.reset_session_state()
	_expect(
		coordinator.pending_enemy_actions.is_empty()
		and coordinator.client_terminal_enemy_ids.is_empty()
		and int(coordinator.get_snapshot_metrics().get(
			"enemy_snapshot_chunk_encode_count",
			-1
		)) == 0,
		"会话重置必须同时释放敌人动作、终结墓碑和快照计数。"
	)
	coordinator.unbind_runtime(runtime)
	_expect(not coordinator.is_bound(), "解绑后不得保留旧战斗运行时。")
	runtime.free()
	coordinator.free()

	if failures.is_empty():
		print("MP_ENEMY_COORDINATOR_SMOKE_TEST_OK")
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	quit(1)


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
