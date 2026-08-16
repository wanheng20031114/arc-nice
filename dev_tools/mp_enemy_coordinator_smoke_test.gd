extends SceneTree

const ENEMY_COORDINATOR_SCENE := preload(
	"res://scene/multiplayer/enemy/mp_enemy_coordinator.tscn"
)
const PROJECTILE_COORDINATOR_SCENE := preload(
	"res://scene/multiplayer/projectile/mp_projectile_coordinator.tscn"
)
const TEST_ENEMY_CONFIG_PATH := "res://resources/config/enemies/capoo_ak47.tres"
const SECOND_ENEMY_CONFIG_PATH := "res://resources/config/enemies/slime.tres"
const BATCH_REPLACEMENT_ENEMY_CONFIG_PATH := (
	"res://resources/config/enemies/slime_green.tres"
)
const OUTSIDE_ENEMY_PATH := (
	"res://dev_tools/fixtures/runtime_content_catalog_outside_enemy.tres"
)
const WRONG_ENEMY_SCENE := preload("res://scene/combat/pickups/pickup.tscn")
const ATOMIC_SPAWN_CALLBACK_NONE := 0
const ATOMIC_SPAWN_CALLBACK_QUEUE_FREE := 1
const ATOMIC_SPAWN_CALLBACK_UNBIND := 2


class ProbeRuntime:
	extends CombatRuntimeBase
	var lightning_chain_replay_count := 0
	var enemy_snapshot_states: Array[SnapshotManager.EnemyState] = []
	var enemy_spawn_effect_positions: Array[Vector2] = []

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

	func get_pickup_for_net_id(_net_id: int) -> Pickup:
		return null

	func remove_multiplayer_player(peer_id: int) -> void:
		peer_players.erase(peer_id)

	func collect_player_snapshot_states() -> Array[SnapshotManager.PlayerState]:
		return []

	func collect_enemy_snapshot_states() -> Array[SnapshotManager.EnemyState]:
		return enemy_snapshot_states

	func play_remote_enemy_spawn_effect(spawn_global_position: Vector2) -> void:
		enemy_spawn_effect_positions.append(spawn_global_position)

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


class FeedbackProbeEnemy:
	extends Enemy
	var feedback_count := 0
	var last_feedback_flags := 0
	var last_impact_direction := Vector2.INF

	func play_multiplayer_damage_feedback(
		impact_direction: Vector2 = Vector2.ZERO,
		feedback_flags: int = 0
	) -> void:
		feedback_count += 1
		last_feedback_flags = feedback_flags
		last_impact_direction = impact_direction


var failures: Array[String] = []
var _probe_net_time := 30.0
var _lifecycle_broadcasts: Array[Dictionary] = []
var _lifecycle_peer_sends: Array[Dictionary] = []
var _damage_broadcasts: Array[Dictionary] = []
var _enemy_snapshot_sends: Array[Dictionary] = []
var _atomic_spawn_runtime: ProbeRuntime = null
var _atomic_spawn_coordinator: MpEnemyCoordinator = null
var _atomic_spawn_expected_ids := PackedInt32Array()
var _atomic_spawn_callback_count := 0
var _atomic_spawn_first_callback_saw_full_registry := false
var _atomic_spawn_callback_action := ATOMIC_SPAWN_CALLBACK_NONE


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
	coordinator.enemy_snapshot_send_requested.connect(_probe_on_enemy_snapshot_send)
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
		runtime.register_network_enemy(900, live_enemy)
		coordinator.send_live_spawn_roster_to_peer(8)
		_expect(
			_lifecycle_peer_sends.size() == 1
			and int(_lifecycle_peer_sends[0].get("peer_id", 0)) == 8
			and StringName(_lifecycle_peer_sends[0].get("method", &""))
			== &"net_enemy_spawned_batch",
			"迟加入修复必须定向发送当前 live enemy roster。"
		)
		runtime.unregister_network_enemy(900, live_enemy)
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
	runtime.enemy_snapshot_states.assign(states)
	var snapshot_send_count := coordinator.broadcast_host_enemy_snapshots(
		peers,
		12.5
	)
	_expect(
		snapshot_send_count == 4
		and _enemy_snapshot_sends.size() == 4
		and int(_enemy_snapshot_sends[0].get("peer_id", 0)) == 2
		and int(_enemy_snapshot_sends[1].get("peer_id", 0)) == 3
		and int(_enemy_snapshot_sends[2].get("peer_id", 0)) == 2
		and int(_enemy_snapshot_sends[3].get("peer_id", 0)) == 3
		and int(_enemy_snapshot_sends[0].get("chunk_count", 0)) == 2,
		"48 个敌人的两个有序块必须由协调器编排为四次逐 peer 发送请求。"
	)
	if not _enemy_snapshot_sends.is_empty():
		var decoder := SnapshotManager.new()
		var decoded := decoder.decode_enemy_snapshots_with_baseline(
			_enemy_snapshot_sends[0].get("data", PackedByteArray()) as PackedByteArray,
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
		CombatTypes.DamageFeedbackFlag.DIRECT_HIT_FLASH
	)
	coordinator.queue_damage_feedback(
		7,
		65,
		2,
		15,
		Vector2.RIGHT,
		EnemyConfig.DamageType.MAGIC,
		(
			CombatTypes.DamageFeedbackFlag.HIT_PARTICLES
			| CombatTypes.DamageFeedbackFlag.DIRECT_HIT_FLASH
		)
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
		and feedback_batches[0].presentation_flags == PackedByteArray([3]),
		"同一敌人的不可靠伤害反馈必须合并最终生命、revision、总伤害与表现位集。"
	)
	coordinator.pending_enemy_damage_feedback[808] = {
		"current_health": 10,
		"health_revision": 3,
		"damage": 9,
		"impact_direction": Vector2.LEFT,
		"damage_type": int(EnemyConfig.DamageType.MAGIC),
		"presentation_flags": CombatTypes.DamageFeedbackFlag.DIRECT_HIT_FLASH,
	}
	coordinator.active_enemy_damage_feedback_context[808] = {
		"impact_direction": Vector2.RIGHT,
		"damage_type": int(EnemyConfig.DamageType.PHYSICAL),
		"presentation_flags": (
			CombatTypes.DamageFeedbackFlag.HIT_PARTICLES
			| CombatTypes.DamageFeedbackFlag.DIRECT_HIT_FLASH
		),
	}
	var frozen_terminal_feedback := coordinator.collect_terminal_feedback(808)
	_expect(
		int(frozen_terminal_feedback.get("presentation_flags", 0)) == 3
		and frozen_terminal_feedback.get("impact_direction", Vector2.ZERO)
		== Vector2.RIGHT
		and int(frozen_terminal_feedback.get("damage_type", -1))
		== int(EnemyConfig.DamageType.PHYSICAL)
		and not coordinator.pending_enemy_damage_feedback.has(808),
		"可靠致死反馈必须冻结并合并待发送记录与活动命中上下文的表现位。"
	)
	coordinator.clear_active_damage_feedback_context(808)
	if enemy_config != null:
		var damage_enemy := Enemy.new()
		damage_enemy.config = enemy_config
		damage_enemy.current_health = 1000
		runtime.register_network_enemy(950, damage_enemy)
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
			== &"net_enemy_damage_feedback_batch"
			and (_damage_broadcasts[0].get("arguments", []) as Array).size() == 7
			and (
				(_damage_broadcasts[0].get("arguments", []) as Array)[6]
				as PackedByteArray
			) == PackedByteArray([3]),
			"已确认敌人伤害必须按50ms节流汇入一次同时携带粒子与闪红表现位的批广播。"
		)
		runtime.unregister_network_enemy(950, damage_enemy)
		damage_enemy.free()

	runtime.runtime_mode = CombatRuntimeBase.RuntimeMode.CLIENT_VIEW
	net_manager.host_mode = false
	net_manager.client_mode = true
	var client_enemy_container := Node2D.new()
	get_root().add_child(client_enemy_container)
	runtime.enemy_container = client_enemy_container
	var second_enemy_config := ResourceLoader.load(
		SECOND_ENEMY_CONFIG_PATH
	) as EnemyConfig
	var preserved_enemy := Enemy.new()
	preserved_enemy.config = second_enemy_config
	runtime.register_network_enemy(970, preserved_enemy)
	var original_enemy_scene := enemy_config.enemy_scene
	enemy_config.enemy_scene = null
	coordinator.receive_enemy_spawn(
		970,
		TEST_ENEMY_CONFIG_PATH,
		Vector2(12, 16),
		1.0,
		1.0
	)
	_expect(
		runtime.get_network_enemy(970) == preserved_enemy,
		"目录内配置临时缺少 enemy_scene 时必须保留旧 net-id 实体。"
	)
	enemy_config.enemy_scene = WRONG_ENEMY_SCENE
	coordinator.receive_enemy_spawn(
		970,
		TEST_ENEMY_CONFIG_PATH,
		Vector2(12, 16),
		1.0,
		1.0
	)
	_expect(
		runtime.get_network_enemy(970) == preserved_enemy,
		"enemy_scene 根节点类型错误时必须释放候选并保留旧 net-id 实体。"
	)
	enemy_config.enemy_scene = original_enemy_scene
	var outside_enemy_config := ResourceLoader.load(
		OUTSIDE_ENEMY_PATH
	) as EnemyConfig
	var outside_enemy_instance: Node = null
	if outside_enemy_config != null and outside_enemy_config.enemy_scene != null:
		outside_enemy_instance = outside_enemy_config.enemy_scene.instantiate()
	_expect(
		outside_enemy_instance is Enemy,
		"目录外敌人夹具本身必须是可实例化的正确 EnemyConfig。"
	)
	if outside_enemy_instance != null and is_instance_valid(outside_enemy_instance):
		outside_enemy_instance.free()
	coordinator.receive_enemy_spawn(
		970,
		OUTSIDE_ENEMY_PATH,
		Vector2(12, 16),
		1.0,
		1.0
	)
	_expect(
		runtime.get_network_enemy(970) == preserved_enemy,
		"可实例化但目录外的 EnemyConfig 仍必须在替换旧实体前拒绝。"
	)
	var original_second_enemy_scene := (
		second_enemy_config.enemy_scene if second_enemy_config != null else null
	)
	if second_enemy_config != null:
		second_enemy_config.enemy_scene = null
	var children_before_failed_batch := client_enemy_container.get_child_count()
	coordinator.receive_enemy_spawn_batch(
		PackedInt32Array([970, 971, 972]),
		PackedStringArray([
			BATCH_REPLACEMENT_ENEMY_CONFIG_PATH,
			TEST_ENEMY_CONFIG_PATH,
			SECOND_ENEMY_CONFIG_PATH,
		]),
		PackedVector2Array([Vector2.ZERO, Vector2.ONE, Vector2(2, 2)]),
		PackedFloat64Array([1.0, 1.0, 1.0]),
		1.0,
		false,
		0.0
	)
	if second_enemy_config != null:
		second_enemy_config.enemy_scene = original_second_enemy_scene
	_expect(
		not runtime.has_network_enemy(971)
		and not runtime.has_network_enemy(972)
		and runtime.get_network_enemy(970) == preserved_enemy
		and client_enemy_container.get_child_count()
		== children_before_failed_batch,
		"批次后项准备失败时必须释放全部候选、保留旧实体并保持注册表零写。"
	)
	coordinator.receive_enemy_spawn_batch(
		PackedInt32Array([973, 973]),
		PackedStringArray([TEST_ENEMY_CONFIG_PATH, TEST_ENEMY_CONFIG_PATH]),
		PackedVector2Array([Vector2.ZERO, Vector2.ONE]),
		PackedFloat64Array([1.0, 1.0]),
		1.0,
		false,
		0.0
	)
	_expect(
		not runtime.has_network_enemy(973),
		"同一生成批次内重复 net-id 必须在实例化前整批拒绝。"
	)
	coordinator.receive_enemy_spawn_packet(
		952,
		OUTSIDE_ENEMY_PATH,
		Vector2.ZERO,
		1.0,
		1.0,
		false,
		0.0
	)
	_expect(
		not runtime.has_network_enemy(952),
		"目录外资源路径必须在敌人实例化和注册前 fail-close。"
	)
	coordinator.receive_enemy_spawn_batch(
		PackedInt32Array([953, 954]),
		PackedStringArray([TEST_ENEMY_CONFIG_PATH, OUTSIDE_ENEMY_PATH]),
		PackedVector2Array([Vector2.ZERO, Vector2.ONE]),
		PackedFloat64Array([1.0, 1.0]),
		1.0,
		false,
		0.0
	)
	_expect(
		not runtime.has_network_enemy(953)
		and not runtime.has_network_enemy(954),
		"敌人批次含一个目录外路径时必须整批预检失败，不能部分生成。"
	)
	runtime.unregister_network_enemy(970, preserved_enemy)
	preserved_enemy.free()
	_atomic_spawn_runtime = runtime
	_atomic_spawn_coordinator = coordinator
	_atomic_spawn_expected_ids = PackedInt32Array([974, 975])
	_atomic_spawn_callback_count = 0
	_atomic_spawn_first_callback_saw_full_registry = false
	_atomic_spawn_callback_action = ATOMIC_SPAWN_CALLBACK_NONE
	var spawn_effect_count_before_atomic_batch := (
		runtime.enemy_spawn_effect_positions.size()
	)
	coordinator.remote_enemy_spawned.connect(_on_atomic_spawn_probe)
	coordinator.receive_enemy_spawn_batch(
		_atomic_spawn_expected_ids,
		PackedStringArray([TEST_ENEMY_CONFIG_PATH, SECOND_ENEMY_CONFIG_PATH]),
		PackedVector2Array([Vector2(3, 4), Vector2(5, 6)]),
		PackedFloat64Array([1.0, 1.0]),
		1.0,
		false,
		0.0
	)
	coordinator.remote_enemy_spawned.disconnect(_on_atomic_spawn_probe)
	_expect(
		_atomic_spawn_callback_count == 2
		and _atomic_spawn_first_callback_saw_full_registry
		and runtime.get_network_enemy(974) != null
		and runtime.get_network_enemy(975) != null
		and runtime.enemy_spawn_effect_positions.size()
		== spawn_effect_count_before_atomic_batch + 2,
		"首个公开生成回调前，完整 batch 必须已配置、注册并可统一发布。"
	)
	_atomic_spawn_expected_ids = PackedInt32Array([976, 977])
	_atomic_spawn_callback_count = 0
	_atomic_spawn_first_callback_saw_full_registry = false
	_atomic_spawn_callback_action = ATOMIC_SPAWN_CALLBACK_QUEUE_FREE
	var spawn_effect_count_before_destructive_callback := (
		runtime.enemy_spawn_effect_positions.size()
	)
	var child_count_before_queue_free_batch := (
		client_enemy_container.get_child_count()
	)
	coordinator.remote_enemy_spawned.connect(_on_atomic_spawn_probe)
	coordinator.receive_enemy_spawn_batch(
		_atomic_spawn_expected_ids,
		PackedStringArray([TEST_ENEMY_CONFIG_PATH, SECOND_ENEMY_CONFIG_PATH]),
		PackedVector2Array([Vector2(7, 8), Vector2(9, 10)]),
		PackedFloat64Array([1.0, 1.0]),
		1.0,
		false,
		0.0
	)
	coordinator.remote_enemy_spawned.disconnect(_on_atomic_spawn_probe)
	_expect(
		_atomic_spawn_callback_count == 1
		and _atomic_spawn_first_callback_saw_full_registry
		and not runtime.has_network_enemy(976)
		and not runtime.has_network_enemy(977)
		and coordinator.is_bound()
		and runtime.enemy_spawn_effect_positions.size()
		== spawn_effect_count_before_destructive_callback,
		"首个回调 queue_free 实体时必须清除同批其余注册，不得留下半批或后置表现。"
	)
	await process_frame
	_expect(
		client_enemy_container.get_child_count()
		== child_count_before_queue_free_batch,
		"queue_free 中止后必须在下一帧释放整批暂存实体。"
	)

	var pending_idempotent_action := {
		"kind": MpEnemyCoordinator.CLIENT_ENEMY_ACTION_KIND_GENERIC,
		"net_id": 975,
		"action_name": &"catalog_atomic_retry",
		"direction": Vector2.RIGHT,
		"action_position": Vector2(5, 6),
		"action_id": 81,
		"action_time": 1.0,
		"received_at": 1.0,
		"host_action_timestamp": 1.0,
	}
	_expect(
		bool(coordinator.call(
			"_cache_pending_enemy_action",
			pending_idempotent_action
		)),
		"混合 batch 测试必须先把后项动作放入 FIFO。"
	)
	var retained_idempotent_enemy := runtime.get_network_enemy(975)
	_atomic_spawn_expected_ids = PackedInt32Array([980, 975])
	_atomic_spawn_callback_count = 0
	_atomic_spawn_first_callback_saw_full_registry = false
	_atomic_spawn_callback_action = ATOMIC_SPAWN_CALLBACK_QUEUE_FREE
	var spawn_effect_count_before_mixed_callback := (
		runtime.enemy_spawn_effect_positions.size()
	)
	coordinator.remote_enemy_spawned.connect(_on_atomic_spawn_probe)
	coordinator.receive_enemy_spawn_batch(
		_atomic_spawn_expected_ids,
		PackedStringArray([TEST_ENEMY_CONFIG_PATH, SECOND_ENEMY_CONFIG_PATH]),
		PackedVector2Array([Vector2(15, 16), Vector2(5, 6)]),
		PackedFloat64Array([1.0, 1.0]),
		1.0,
		false,
		0.0
	)
	coordinator.remote_enemy_spawned.disconnect(_on_atomic_spawn_probe)
	_expect(
		_atomic_spawn_callback_count == 1
		and _atomic_spawn_first_callback_saw_full_registry
		and not runtime.has_network_enemy(980)
		and runtime.get_network_enemy(975) == retained_idempotent_enemy
		and coordinator.pending_enemy_actions.get(975, {})
		== pending_idempotent_action
		and runtime.enemy_spawn_effect_positions.size()
		== spawn_effect_count_before_mixed_callback,
		"首项回调中止混合 batch 时，后项既有实体的 FIFO 动作不得被提前取走。"
	)
	await process_frame

	var idempotent_child_entries: Array[Node] = []
	var idempotent_child_callback := func(child: Node) -> void:
		idempotent_child_entries.append(child)
	client_enemy_container.child_entered_tree.connect(idempotent_child_callback)
	var idempotent_child_count_before := client_enemy_container.get_child_count()
	var navigation_phase_before_idempotent := Enemy._next_navigation_phase_offset
	coordinator.receive_enemy_spawn(
		975,
		SECOND_ENEMY_CONFIG_PATH,
		Vector2(5, 6),
		1.0,
		1.0
	)
	client_enemy_container.child_entered_tree.disconnect(idempotent_child_callback)
	_expect(
		runtime.get_network_enemy(975) == retained_idempotent_enemy
		and not coordinator.pending_enemy_actions.has(975)
		and idempotent_child_entries.is_empty()
		and client_enemy_container.get_child_count()
		== idempotent_child_count_before
		and Enemy._next_navigation_phase_offset
		== navigation_phase_before_idempotent,
		"同配置同 net-id 必须在实例化前幂等短路，并可随后交付 FIFO 动作且无入树或导航调度副作用。"
	)
	coordinator.remove_client_enemy(974, false)
	coordinator.remove_client_enemy(975, false)
	await process_frame

	_atomic_spawn_expected_ids = PackedInt32Array([978, 979])
	_atomic_spawn_callback_count = 0
	_atomic_spawn_first_callback_saw_full_registry = false
	_atomic_spawn_callback_action = ATOMIC_SPAWN_CALLBACK_UNBIND
	var spawn_effect_count_before_unbind_callback := (
		runtime.enemy_spawn_effect_positions.size()
	)
	coordinator.remote_enemy_spawned.connect(_on_atomic_spawn_probe)
	coordinator.receive_enemy_spawn_batch(
		_atomic_spawn_expected_ids,
		PackedStringArray([TEST_ENEMY_CONFIG_PATH, SECOND_ENEMY_CONFIG_PATH]),
		PackedVector2Array([Vector2(11, 12), Vector2(13, 14)]),
		PackedFloat64Array([1.0, 1.0]),
		1.0,
		false,
		0.0
	)
	coordinator.remote_enemy_spawned.disconnect(_on_atomic_spawn_probe)
	_expect(
		_atomic_spawn_callback_count == 1
		and _atomic_spawn_first_callback_saw_full_registry
		and not runtime.has_network_enemy(978)
		and not runtime.has_network_enemy(979)
		and not coordinator.is_bound()
		and runtime.enemy_spawn_effect_positions.size()
		== spawn_effect_count_before_unbind_callback,
		"首个回调解绑时必须从完整 batch 原子归零，不得继续发布或遗留半批。"
	)
	await process_frame
	coordinator.bind_runtime(runtime)
	coordinator.bind_damage_dependencies(projectile_coordinator, presentation_parent)
	coordinator.bind_lifecycle_dependencies(
		net_manager,
		gameplay_gateway,
		_probe_get_net_time
	)
	_atomic_spawn_runtime = null
	_atomic_spawn_coordinator = null
	_atomic_spawn_expected_ids = PackedInt32Array()
	_atomic_spawn_callback_action = ATOMIC_SPAWN_CALLBACK_NONE
	var feedback_probe := FeedbackProbeEnemy.new()
	coordinator.register_client_enemy(951, feedback_probe, 0.0)
	coordinator.apply_damage_feedback_batch(
		PackedInt32Array([951]),
		PackedInt32Array([90]),
		PackedInt32Array([1]),
		PackedInt32Array([10]),
		PackedVector2Array([Vector2.ZERO]),
		PackedByteArray([EnemyConfig.DamageType.PHYSICAL]),
		PackedByteArray([3])
	)
	_expect(
		feedback_probe.feedback_count == 1
		and feedback_probe.last_feedback_flags
		== CombatTypes.DamageFeedbackFlag.DIRECT_HIT_FLASH
		and feedback_probe.last_impact_direction == Vector2.ZERO,
		"零方向权威命中必须保留闪红并剥离定向粒子表现位。"
	)
	var applied_new_health := coordinator.apply_network_health(feedback_probe, 80, 2)
	var rejected_stale_health := coordinator.apply_network_health(feedback_probe, 70, 1)
	var rejected_equal_health := coordinator.apply_network_health(feedback_probe, 60, 2)
	_expect(
		applied_new_health
		and not rejected_stale_health
		and not rejected_equal_health
		and feedback_probe.current_health == 80
		and feedback_probe.health_revision == 2
		and feedback_probe.feedback_count == 1,
		"血量快照必须原子更新状态/版本并拒绝 stale/equal revision，且不得重放命中闪红。"
	)
	runtime.unregister_network_enemy(951, feedback_probe)
	feedback_probe.free()
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
		0
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
	client_enemy_container.free()
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


func _on_atomic_spawn_probe(enemy: Enemy) -> void:
	_atomic_spawn_callback_count += 1
	if _atomic_spawn_callback_count != 1:
		return
	var saw_full_registry := (
		_atomic_spawn_runtime != null
		and is_instance_valid(_atomic_spawn_runtime)
	)
	if saw_full_registry:
		for net_id in _atomic_spawn_expected_ids:
			var registered_enemy: Enemy = (
				_atomic_spawn_runtime.get_network_enemy(net_id)
			)
			if (
				registered_enemy == null
				or not is_instance_valid(registered_enemy)
				or registered_enemy.config == null
				or not registered_enemy.is_multiplayer_proxy
			):
				saw_full_registry = false
				break
	_atomic_spawn_first_callback_saw_full_registry = saw_full_registry
	if _atomic_spawn_callback_action == ATOMIC_SPAWN_CALLBACK_NONE:
		return
	if (
		(_atomic_spawn_callback_action & ATOMIC_SPAWN_CALLBACK_QUEUE_FREE) != 0
		and enemy != null
		and is_instance_valid(enemy)
	):
		enemy.queue_free()
	if (
		(_atomic_spawn_callback_action & ATOMIC_SPAWN_CALLBACK_UNBIND) != 0
		and _atomic_spawn_coordinator != null
		and is_instance_valid(_atomic_spawn_coordinator)
		and _atomic_spawn_runtime != null
		and is_instance_valid(_atomic_spawn_runtime)
	):
		_atomic_spawn_coordinator.unbind_runtime(_atomic_spawn_runtime)


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


func _probe_on_enemy_snapshot_send(
	peer_id: int,
	host_timestamp: float,
	data: PackedByteArray,
	batch_id: int,
	chunk_index: int,
	chunk_count: int,
	snapshot_hz: int,
	entity_count: int
) -> void:
	_enemy_snapshot_sends.append({
		"peer_id": peer_id,
		"host_timestamp": host_timestamp,
		"data": data,
		"batch_id": batch_id,
		"chunk_index": chunk_index,
		"chunk_count": chunk_count,
		"snapshot_hz": snapshot_hz,
		"entity_count": entity_count,
	})
