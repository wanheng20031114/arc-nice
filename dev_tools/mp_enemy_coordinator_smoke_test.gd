extends SceneTree

const ENEMY_COORDINATOR_SCENE := preload(
	"res://scene/multiplayer/enemy/mp_enemy_coordinator.tscn"
)
const PROJECTILE_COORDINATOR_SCENE := preload(
	"res://scene/multiplayer/projectile/mp_projectile_coordinator.tscn"
)
const TEST_ENEMY_CONFIG_PATH := "res://resources/config/enemies/capoo_ak47.tres"


class ProbeRuntime:
	extends CombatRuntimeBase
	var lightning_chain_replay_count := 0

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

	func play_lightning_sorcerer_chain_vfx(_world_path: PackedVector2Array) -> bool:
		lightning_chain_replay_count += 1
		return true


class ProbeNetManager:
	extends NetManagerStore
	var host_mode := true
	var client_mode := false

	func is_host() -> bool:
		return host_mode

	func is_client() -> bool:
		return client_mode


var failures: Array[String] = []
var _probe_net_time := 30.0
var _lifecycle_broadcasts: Array[Dictionary] = []
var _lifecycle_peer_sends: Array[Dictionary] = []
var _damage_broadcasts: Array[Dictionary] = []


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	var coordinator := ENEMY_COORDINATOR_SCENE.instantiate() as MpEnemyCoordinator
	var runtime := ProbeRuntime.new()
	_expect(coordinator != null, "EnemyCoordinator 场景必须可实例化。")
	if coordinator == null:
		quit(1)
		return
	get_root().add_child(coordinator)
	coordinator.bind_runtime(runtime)
	_expect(coordinator.is_bound(), "EnemyCoordinator 必须强类型绑定战斗运行时。")
	var projectile_coordinator := (
		PROJECTILE_COORDINATOR_SCENE.instantiate() as MpProjectileCoordinator
	)
	var presentation_parent := Node2D.new()
	get_root().add_child(projectile_coordinator)
	get_root().add_child(presentation_parent)
	projectile_coordinator.bind_runtime(runtime)
	coordinator.bind_damage_dependencies(projectile_coordinator, presentation_parent)
	var net_manager := ProbeNetManager.new()
	var gameplay_gateway := MultiplayerGameplayGateway.new()
	gameplay_gateway.bind_runtime(runtime)
	coordinator.bind_lifecycle_dependencies(
		net_manager,
		gameplay_gateway,
		_probe_get_net_time
	)
	coordinator.lifecycle_rpc_broadcast_requested.connect(
		_probe_on_lifecycle_broadcast
	)
	coordinator.lifecycle_rpc_to_peer_requested.connect(
		_probe_on_lifecycle_peer_send
	)
	coordinator.damage_rpc_broadcast_requested.connect(_probe_on_damage_broadcast)
	_expect(
		coordinator.has_lifecycle_dependencies(),
		"EnemyCoordinator 必须显式绑定网络、Gateway 与网络时钟。"
	)
	_expect(
		coordinator.has_damage_dependencies(),
		"EnemyCoordinator 必须显式绑定 ProjectileCoordinator 与表现父节点。"
	)

	runtime.runtime_mode = CombatRuntimeBase.RuntimeMode.HOST_AUTHORITY
	var enemy_config := load(TEST_ENEMY_CONFIG_PATH) as EnemyConfig
	_expect(enemy_config != null, "专项测试必须能加载稳定敌人配置。")
	if enemy_config != null:
		gameplay_gateway.enemy_spawned.emit(
			701,
			enemy_config,
			Vector2(48.0, 64.0)
		)
		coordinator.update_host()
		_expect(
			_lifecycle_broadcasts.size() == 1
			and StringName(_lifecycle_broadcasts[0].get("method", &""))
			== &"net_enemy_spawned_batch",
			"Host Gateway 生成事件必须汇入一次有界批广播。"
		)
		var live_enemy := Enemy.new()
		live_enemy.config = enemy_config
		live_enemy.global_position = Vector2(96.0, 112.0)
		runtime.multiplayer_enemies_by_net_id[900] = live_enemy
		coordinator.send_live_spawn_roster_to_peer(8)
		_expect(
			_lifecycle_peer_sends.size() == 1
			and int(_lifecycle_peer_sends[0].get("peer_id", 0)) == 8
			and StringName(_lifecycle_peer_sends[0].get("method", &""))
			== &"net_enemy_spawned_batch",
			"迟加入修复必须定向发送当前 live enemy roster。"
		)
		runtime.multiplayer_enemies_by_net_id.erase(900)
		live_enemy.free()

	coordinator.broadcast_enemy_action(
		701,
		&"attack",
		Vector2.RIGHT,
		Vector2(48.0, 64.0),
		1
	)
	coordinator.broadcast_enemy_target_action(
		701,
		&"target_attack",
		2,
		Vector2(48.0, 64.0),
		2
	)
	coordinator.broadcast_enemy_lightning_chain(
		PackedVector2Array([Vector2.ZERO, Vector2(16.0, 8.0)])
	)
	_expect(
		_lifecycle_broadcasts.size() == 4
		and StringName(_lifecycle_broadcasts[1].get("method", &""))
		== &"net_enemy_action"
		and StringName(_lifecycle_broadcasts[2].get("method", &""))
		== &"net_enemy_target_action"
		and StringName(_lifecycle_broadcasts[3].get("method", &""))
		== &"net_enemy_lightning_chain",
		"敌人普通动作、目标动作与闪电链必须由协调器统一广播。"
	)
	gameplay_gateway.enemy_defeated.emit(701, Vector2(48.0, 64.0))
	gameplay_gateway.enemy_removed.emit(701)
	gameplay_gateway.enemy_removed.emit(702)
	gameplay_gateway.enemy_escaped.emit(703)
	var terminal_broadcast_count := 0
	for record in _lifecycle_broadcasts:
		if StringName(record.get("method", &"")) == &"net_enemy_terminal":
			terminal_broadcast_count += 1
	_expect(
		terminal_broadcast_count == 3,
		"defeated 后的配对 removed 必须去重，独立 removed/escaped 仍各广播一次。"
	)

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
	if enemy_config != null:
		var damage_enemy := Enemy.new()
		damage_enemy.config = enemy_config
		damage_enemy.current_health = 1000
		runtime.multiplayer_enemies_by_net_id[950] = damage_enemy
		var projectile_id := MpProjectileCoordinator.encode_projectile_id(2, 17)
		projectile_coordinator.remember_projectile_record(
			projectile_id,
			2,
			&"player_bullet",
			23,
			2.0,
			false,
			_probe_net_time
		)
		var health_before_hit := damage_enemy.current_health
		coordinator.apply_host_enemy_hit_report(
			projectile_id,
			2,
			950,
			999,
			Vector2.LEFT
		)
		var health_after_first_hit := damage_enemy.current_health
		coordinator.apply_host_enemy_hit_report(
			projectile_id,
			2,
			950,
			999,
			Vector2.LEFT
		)
		coordinator.update_damage_feedback(
			MpEnemyCoordinator.COMBAT_FEEDBACK_FLUSH_INTERVAL_SECONDS
		)
		_expect(
			health_after_first_hit < health_before_hit
			and damage_enemy.current_health == health_after_first_hit,
			"Host 敌人命中必须采用弹体账本伤害，且同一非穿透弹体只结算一次。"
		)
		_expect(
			_damage_broadcasts.size() == 1
			and StringName(_damage_broadcasts[0].get("method", &""))
			== &"net_enemy_damage_feedback_batch",
			"已确认敌人伤害必须按既有 50ms 节流汇入一次批广播。"
		)
		runtime.multiplayer_enemies_by_net_id.erase(950)
		damage_enemy.free()

	runtime.runtime_mode = CombatRuntimeBase.RuntimeMode.CLIENT_VIEW
	net_manager.host_mode = false
	net_manager.client_mode = true
	coordinator.receive_enemy_lightning_chain(
		PackedVector2Array([Vector2.ZERO, Vector2(4.0, 4.0)])
	)
	_expect(
		runtime.lightning_chain_replay_count == 1,
		"客户端只应重放合法闪电链表现。"
	)
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
	_expect(
		not coordinator.is_bound()
		and not coordinator.has_lifecycle_dependencies()
		and not coordinator.has_damage_dependencies(),
		"解绑后不得保留旧战斗运行时、生命周期或伤害依赖。"
	)
	gameplay_gateway.free()
	net_manager.free()
	presentation_parent.free()
	projectile_coordinator.free()
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


func _probe_get_net_time() -> float:
	_probe_net_time += 0.25
	return _probe_net_time


func _probe_on_lifecycle_broadcast(
	method_name: StringName,
	arguments: Array
) -> void:
	_lifecycle_broadcasts.append({
		"method": method_name,
		"arguments": arguments.duplicate(true),
	})


func _probe_on_lifecycle_peer_send(
	peer_id: int,
	method_name: StringName,
	arguments: Array
) -> void:
	_lifecycle_peer_sends.append({
		"peer_id": peer_id,
		"method": method_name,
		"arguments": arguments.duplicate(true),
	})


func _probe_on_damage_broadcast(
	method_name: StringName,
	arguments: Array
) -> void:
	_damage_broadcasts.append({
		"method": method_name,
		"arguments": arguments.duplicate(true),
	})
