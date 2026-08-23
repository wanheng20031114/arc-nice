extends SceneTree

const ENEMY_COORDINATOR_SCENE := preload(
	"res://scene/multiplayer/enemy/mp_enemy_coordinator.tscn"
)
const NET_CONSTANTS := preload("res://scene/multiplayer/net_constants.gd")
const TARGET_DESCRIPTOR := preload(
	"res://scene/combat/targeting/combat_target_descriptor.gd"
)
const COMBAT_RELATIONS := preload(
	"res://scene/combat/faction/combat_relation_service.gd"
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
	var probe_plants: Dictionary[int, PlantDefense] = {}

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

	func resolve_probe_plant(net_id: int) -> PlantDefense:
		return probe_plants.get(net_id) as PlantDefense

	func query_probe_plants_into(
		_center: Vector2,
		_radius: float,
		result: Array[PlantDefense]
	) -> void:
		result.clear()

	func get_probe_plant_id(plant: PlantDefense) -> int:
		for net_id_variant in probe_plants.keys():
			var net_id := int(net_id_variant)
			if probe_plants.get(net_id) == plant:
				return net_id
		return 0


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


class TargetActionProbeEnemy:
	extends Enemy
	var target_action_count := 0
	var last_target: Node2D = null
	var last_target_action_id := 0
	var presentation_state_count := 0
	var last_presentation_phase := Enemy.TargetPresentationPhase.NONE
	var last_presentation_target: Node2D = null
	var last_presentation_revision := 0
	var last_presentation_elapsed := 0.0
	var last_presentation_remaining := 0.0
	var generic_action_count := 0
	var last_generic_action_id := 0

	func play_multiplayer_enemy_target_action_with_context(
		_action_name: StringName,
		target: Node2D,
		_action_position: Vector2,
		action_id: int,
		_action_elapsed: float
	) -> void:
		target_action_count += 1
		last_target = target
		last_target_action_id = action_id

	func play_multiplayer_enemy_action_with_context(
		action_name: StringName,
		_direction: Vector2,
		_action_position: Vector2,
		action_id: int,
		_action_elapsed: float
	) -> void:
		generic_action_count += 1
		last_generic_action_id = action_id
		# 模拟 Sniper/Lightning 在 fire/cancel CH7 边沿立刻清视觉，便于
		# 验证随后到达的旧 CH5 ACTIVE 不会把表现重新打开。
		if action_name == &"presentation_clear":
			last_presentation_phase = Enemy.TargetPresentationPhase.NONE
			last_presentation_target = null

	func apply_multiplayer_target_presentation_state(
		phase: int,
		target: Node2D,
		_action_position: Vector2,
		state_revision: int,
		elapsed_seconds: float,
		remaining_seconds: float
	) -> void:
		presentation_state_count += 1
		last_presentation_phase = phase
		last_presentation_target = target
		last_presentation_revision = state_revision
		last_presentation_elapsed = elapsed_seconds
		last_presentation_remaining = remaining_seconds


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
	var unbound_enemy_ids: Array[int] = coordinator.get_remote_enemy_ids()
	_expect(
		unbound_enemy_ids.is_empty()
		and unbound_enemy_ids.is_typed()
		and unbound_enemy_ids.get_typed_builtin() == TYPE_INT,
		"EnemyCoordinator 未绑定时必须返回显式 Array[int] 空集合。"
	)
	coordinator.bind_runtime(runtime)
	runtime.get_combat_query_facade().bind_plant_query_port(
		Callable(runtime, &"resolve_probe_plant"),
		Callable(runtime, &"query_probe_plants_into"),
		Callable(),
		Callable(runtime, &"get_probe_plant_id")
	)
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
			== &"net_enemy_spawned_batch"
			and (_lifecycle_broadcasts[0].get("arguments", []) as Array).size() == 6,
			"Host Gateway 生成事件必须汇入一次携带阵营状态的有界批广播。"
		)
		var old_incarnation_send_state := SnapshotManager.EnemyState.new()
		old_incarnation_send_state.net_id = 704
		old_incarnation_send_state.position = Vector2(10.0, 12.0)
		old_incarnation_send_state.health = 90
		old_incarnation_send_state.health_revision = 8
		var incarnation_states: Array[SnapshotManager.EnemyState] = [
			old_incarnation_send_state
		]
		coordinator._snapshot_manager.encode_enemy_snapshot_range_for_cohort(
			MpEnemyCoordinator.SHARED_SNAPSHOT_COHORT_ID,
			incarnation_states,
			0,
			1,
			true
		)
		coordinator.queue_host_spawn(
			704,
			enemy_config,
			Vector2(20.0, 24.0),
			2.0
		)
		var new_incarnation_send_state := SnapshotManager.EnemyState.new()
		new_incarnation_send_state.net_id = 704
		new_incarnation_send_state.position = Vector2(20.0, 24.0)
		new_incarnation_send_state.health = 120
		new_incarnation_send_state.health_revision = 0
		var new_incarnation_states: Array[SnapshotManager.EnemyState] = [
			new_incarnation_send_state
		]
		var first_new_incarnation_packet := (
			coordinator._snapshot_manager.encode_enemy_snapshot_range_for_cohort(
				MpEnemyCoordinator.SHARED_SNAPSHOT_COHORT_ID,
				new_incarnation_states,
				0,
				1,
				false
			)
		)
		var fresh_incarnation_receiver := SnapshotManager.new()
		var first_new_incarnation_states := (
			fresh_incarnation_receiver.decode_enemy_snapshots_with_baseline(
				first_new_incarnation_packet
			)
		)
		_expect(
			first_new_incarnation_states.size() == 1
			and first_new_incarnation_states[0].health == 120
			and first_new_incarnation_states[0].health_revision == 0,
			"Host 发布同 net-id 新 incarnation 时必须清发送基线，使首个普通快照仍为可独立解码的 full。"
		)
		var terminal_before_spawn_flush := coordinator.build_host_terminal_event(
			704,
			MpEnemyCoordinator.ENEMY_TERMINAL_REMOVED,
			Vector2(20.0, 24.0)
		)
		_expect(
			not terminal_before_spawn_flush.is_empty()
			and coordinator._pending_host_spawns.is_empty(),
			"Host 敌人在 spawn flush 前终结时必须撤销陈旧 spawn，不能在 terminal 后复活代理。"
		)
		var live_enemy := Enemy.new()
		live_enemy.config = enemy_config
		live_enemy.global_position = Vector2(96.0, 112.0)
		runtime.register_network_enemy(900, live_enemy)
		var bound_enemy_ids: Array[int] = coordinator.get_remote_enemy_ids()
		_expect(
			bound_enemy_ids == [900]
			and bound_enemy_ids.is_typed()
			and bound_enemy_ids.get_typed_builtin() == TYPE_INT,
			"EnemyCoordinator 绑定后必须返回保留内容的显式 Array[int]。"
		)
		coordinator.send_live_spawn_roster_to_peer(8)
		var live_roster_arguments: Array = (
			_lifecycle_peer_sends[0].get("arguments", []) as Array
			if not _lifecycle_peer_sends.is_empty()
			else []
		)
		_expect(
			_lifecycle_peer_sends.size() == 1
			and int(_lifecycle_peer_sends[0].get("peer_id", 0)) == 8
			and StringName(_lifecycle_peer_sends[0].get("method", &""))
			== &"net_enemy_spawned_batch"
			and live_roster_arguments.size() == 6
			and live_roster_arguments[4] == PackedByteArray([
				COMBAT_RELATIONS.HOSTILE_WAVE
			])
			and live_roster_arguments[5] == PackedInt32Array([0]),
			"迟加入修复必须定向发送含 faction/revision 的当前 live enemy roster。"
		)
		var first_live_spawn_token := float(live_roster_arguments[3][0])
		var repair_batches := coordinator.build_live_spawn_batches(
			_probe_get_net_time() + 10.0
		)
		_expect(
			repair_batches.size() == 1
			and repair_batches[0].spawn_times.size() == 1
			and is_equal_approx(
				repair_batches[0].spawn_times[0],
				first_live_spawn_token
			),
			"迟加入 roster 必须复用实体原始出生令牌，不能把每次 repair 时间伪装成新 incarnation。"
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
		TARGET_DESCRIPTOR.create_player(2, 0, Vector2(72.0, 64.0)),
		Vector2(48.0, 64.0),
		2
	)
	coordinator.broadcast_enemy_lightning_chain(
		PackedVector2Array([Vector2.ZERO, Vector2(16.0, 8.0)])
	)
	var target_action_arguments: Array = (
		_lifecycle_broadcasts[2].get("arguments", []) as Array
		if _lifecycle_broadcasts.size() > 2
		else []
	)
	_expect(
		_lifecycle_broadcasts.size() == 4
		and StringName(_lifecycle_broadcasts[1].get("method", &""))
		== &"net_enemy_action"
		and StringName(_lifecycle_broadcasts[2].get("method", &""))
		== &"net_enemy_target_action"
		and StringName(_lifecycle_broadcasts[3].get("method", &""))
		== &"net_enemy_lightning_chain"
		and target_action_arguments.size() == 9
		and int(target_action_arguments[2]) == TARGET_DESCRIPTOR.Kind.PLAYER
		and int(target_action_arguments[3]) == 2
		and int(target_action_arguments[4]) == 0
		and target_action_arguments[5] == Vector2(72.0, 64.0),
		"敌人目标动作必须按 kind/id/entity revision/fallback 展开后统一广播。"
	)
	var broadcast_count_before_null_descriptor := _lifecycle_broadcasts.size()
	coordinator.broadcast_enemy_target_action(
		701,
		&"invalid_target",
		null,
		Vector2.ZERO,
		3
	)
	_expect(
		_lifecycle_broadcasts.size() == broadcast_count_before_null_descriptor,
		"Host 必须在读取字段前拒绝 null 目标描述符。"
	)
	if enemy_config != null:
		var presentation_host_enemy := Enemy.new()
		presentation_host_enemy.config = enemy_config
		runtime.register_network_enemy(902, presentation_host_enemy)
		var presentation_broadcast_base := _lifecycle_broadcasts.size()
		_expect(
			coordinator.set_host_enemy_target_presentation_state(
				902,
				Enemy.TargetPresentationPhase.SNIPER_LOCK,
				TARGET_DESCRIPTOR.create_player(2, 0, Vector2(72.0, 64.0)),
				2.0,
				Vector2(96.0, 112.0),
				1
			),
			"Host 必须接受带通用 descriptor 的 ACTIVE 持续目标表现。"
		)
		coordinator.update_host()
		var active_presentation_broadcast := (
			_lifecycle_broadcasts.back() as Dictionary
		)
		var active_presentation_arguments := (
			active_presentation_broadcast.get("arguments", []) as Array
		)
		_expect(
			_lifecycle_broadcasts.size() == presentation_broadcast_base + 1
			and StringName(active_presentation_broadcast.get("method", &""))
			== &"net_enemy_target_presentation_state_batch"
			and active_presentation_arguments.size() == 10
			and active_presentation_arguments[0] == PackedInt32Array([902])
			and active_presentation_arguments[1] == PackedInt32Array([1])
			and active_presentation_arguments[2] == PackedByteArray([
				Enemy.TargetPresentationPhase.SNIPER_LOCK
			])
			and active_presentation_arguments[3] == PackedByteArray([
				TARGET_DESCRIPTOR.Kind.PLAYER
			]),
			"Host ACTIVE 必须按稳定 net-id 和 state revision 可靠批播。"
		)
		_expect(
			coordinator.set_host_enemy_target_presentation_state(
				902,
				Enemy.TargetPresentationPhase.NONE,
				TARGET_DESCRIPTOR.create_none(),
				0.0,
				Vector2(96.0, 112.0),
				2
			),
			"Host 必须缓存并可靠广播显式 NONE 收敛态。"
		)
		coordinator.update_host()
		var clear_presentation_broadcast := (
			_lifecycle_broadcasts.back() as Dictionary
		)
		var clear_presentation_arguments := (
			clear_presentation_broadcast.get("arguments", []) as Array
		)
		_expect(
			StringName(clear_presentation_broadcast.get("method", &""))
			== &"net_enemy_target_presentation_state_batch"
			and clear_presentation_arguments[1] == PackedInt32Array([2])
			and clear_presentation_arguments[2] == PackedByteArray([
				Enemy.TargetPresentationPhase.NONE
			])
			and clear_presentation_arguments[3] == PackedByteArray([
				TARGET_DESCRIPTOR.Kind.NONE
			]),
			"fire/cancel 后的 NONE 必须以新 revision 覆盖 ACTIVE。"
		)
		var peer_send_base := _lifecycle_peer_sends.size()
		coordinator.send_live_spawn_roster_to_peer(9)
		_expect(
			_lifecycle_peer_sends.size() == peer_send_base + 2
			and StringName(_lifecycle_peer_sends[peer_send_base].get(
				"method",
				&""
			)) == &"net_enemy_spawned_batch"
			and StringName(_lifecycle_peer_sends[peer_send_base + 1].get(
				"method",
				&""
			)) == &"net_enemy_target_presentation_state_batch"
			and ((_lifecycle_peer_sends[peer_send_base + 1].get(
				"arguments",
				[]
			) as Array)[1]) == PackedInt32Array([2])
			and ((_lifecycle_peer_sends[peer_send_base + 1].get(
				"arguments",
				[]
			) as Array)[2]) == PackedByteArray([
				Enemy.TargetPresentationPhase.NONE
			]),
			"迟加入 roster 后必须定向重放包含 NONE 的持续表现缓存。"
		)
		coordinator.build_host_terminal_event(
			902,
			MpEnemyCoordinator.ENEMY_TERMINAL_REMOVED,
			Vector2.ZERO
		)
		_expect(
			not coordinator._host_target_presentation_states.has(902)
			and not coordinator._pending_host_target_presentation_states.has(902),
			"Host 终态必须清除 ACTIVE/NONE 持续表现缓存。"
		)
		runtime.unregister_network_enemy(902, presentation_host_enemy)
		presentation_host_enemy.free()
		var target_cache_source := Enemy.new()
		target_cache_source.config = enemy_config
		var target_cache_enemy := Enemy.new()
		target_cache_enemy.config = enemy_config
		runtime.register_network_enemy(903, target_cache_source)
		runtime.register_network_enemy(904, target_cache_enemy)
		coordinator.set_host_enemy_target_presentation_state(
			903,
			Enemy.TargetPresentationPhase.SNIPER_LOCK,
			TARGET_DESCRIPTOR.create_enemy(904, 0, Vector2(120.0, 80.0)),
			2.0,
			Vector2(100.0, 80.0),
			7
		)
		coordinator.build_host_terminal_event(
			904,
			MpEnemyCoordinator.ENEMY_TERMINAL_REMOVED,
			Vector2(120.0, 80.0)
		)
		var cleared_enemy_target_cache := (
			coordinator._host_target_presentation_states.get(903, {})
			as Dictionary
		)
		var pending_enemy_target_cache := (
			coordinator._pending_host_target_presentation_states.get(903, {})
			as Dictionary
		)
		_expect(
			int(cleared_enemy_target_cache.get("phase", -1))
			== Enemy.TargetPresentationPhase.NONE
			and int(cleared_enemy_target_cache.get("state_revision", 0)) == 7
			and int(pending_enemy_target_cache.get("phase", -1))
			== Enemy.TargetPresentationPhase.NONE,
			"Host 目标敌人终结时必须把所有引用它的 ACTIVE cache 以同 revision 收敛为 NONE。"
		)
		coordinator.drain_host_target_presentation_batches()
		var player_cache_source := Enemy.new()
		player_cache_source.config = enemy_config
		runtime.register_network_enemy(905, player_cache_source)
		coordinator.set_host_enemy_target_presentation_state(
			905,
			Enemy.TargetPresentationPhase.LIGHTNING_WINDUP,
			TARGET_DESCRIPTOR.create_player(2, 0, Vector2(140.0, 80.0)),
			2.0,
			Vector2(110.0, 80.0),
			8
		)
		coordinator.clear_peer(2)
		var cleared_player_target_cache := (
			coordinator._host_target_presentation_states.get(905, {})
			as Dictionary
		)
		_expect(
			int(cleared_player_target_cache.get("phase", -1))
			== Enemy.TargetPresentationPhase.NONE
			and int(cleared_player_target_cache.get("state_revision", 0)) == 8,
			"玩家断连时 Host 必须可靠清除所有引用该 peer 的持续目标表现。"
		)
		coordinator.build_host_terminal_event(
			903,
			MpEnemyCoordinator.ENEMY_TERMINAL_REMOVED,
			Vector2.ZERO
		)
		coordinator.build_host_terminal_event(
			905,
			MpEnemyCoordinator.ENEMY_TERMINAL_REMOVED,
			Vector2.ZERO
		)
		runtime.unregister_network_enemy(903, target_cache_source)
		runtime.unregister_network_enemy(904, target_cache_enemy)
		runtime.unregister_network_enemy(905, player_cache_source)
		target_cache_source.free()
		target_cache_enemy.free()
		player_cache_source.free()
	if enemy_config != null:
		var faction_host_enemy := Enemy.new()
		faction_host_enemy.config = enemy_config
		runtime.register_network_enemy(901, faction_host_enemy)
		coordinator.build_live_spawn_batches(_probe_get_net_time())
		faction_host_enemy.set_combat_faction_id(
			COMBAT_RELATIONS.PLAYER_ALLIED,
			1,
			true
		)
		coordinator.update_host()
		var faction_broadcast := _lifecycle_broadcasts.back() as Dictionary
		var faction_arguments := faction_broadcast.get("arguments", []) as Array
		_expect(
			StringName(faction_broadcast.get("method", &""))
			== &"net_enemy_faction_changed_batch"
			and faction_arguments.size() == 3
			and faction_arguments[0] == PackedInt32Array([901])
			and faction_arguments[1] == PackedByteArray([
				COMBAT_RELATIONS.PLAYER_ALLIED
			])
			and faction_arguments[2] == PackedInt32Array([1]),
			"Host 必须按 net-id 稳定顺序可靠批播运行时阵营 revision。"
		)
		gameplay_gateway.enemy_removed.emit(901)
		runtime.unregister_network_enemy(901, faction_host_enemy)
		faction_host_enemy.free()
	gameplay_gateway.enemy_defeated.emit(701, Vector2(48.0, 64.0))
	gameplay_gateway.enemy_removed.emit(701)
	gameplay_gateway.enemy_removed.emit(702)
	gameplay_gateway.enemy_escaped.emit(703)
	var terminal_broadcast_count := 0
	for record in _lifecycle_broadcasts:
		if StringName(record.get("method", &"")) == &"net_enemy_terminal":
			terminal_broadcast_count += 1
	_expect(
		terminal_broadcast_count == 4,
		"defeated 后的配对 removed 必须去重，独立 removed/escaped 与阵营实体终态仍各广播一次。"
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
			"首个 v94 快照块必须保持 41 实体/1191-byte MTU 上限。"
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
	coordinator.queue_damage_feedback(
		8,
		1,
		1,
		NET_CONSTANTS.NETWORK_COMBAT_VALUE_MAX,
		Vector2.ZERO,
		EnemyConfig.DamageType.PHYSICAL,
		0
	)
	coordinator.queue_damage_feedback(
		8,
		0,
		2,
		1,
		Vector2.ZERO,
		EnemyConfig.DamageType.PHYSICAL,
		0
	)
	var saturated_feedback_batches := coordinator.drain_damage_feedback_batches()
	_expect(
		saturated_feedback_batches.size() == 1
		and saturated_feedback_batches[0].damage_values
		== PackedInt32Array([NET_CONSTANTS.NETWORK_COMBAT_VALUE_MAX]),
		"极端伤害聚合必须饱和到网络int32上限，不能丢失整条反馈。"
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
	coordinator.receive_enemy_spawn_packet(
		978,
		TEST_ENEMY_CONFIG_PATH,
		Vector2(18.0, 19.0),
		1.0,
		1.0,
		false,
		0.0,
		-1,
		-1,
		true
	)
	coordinator.receive_enemy_spawn_batch(
		PackedInt32Array([979]),
		PackedStringArray([TEST_ENEMY_CONFIG_PATH]),
		PackedVector2Array([Vector2(19.0, 20.0)]),
		PackedFloat64Array([1.0]),
		1.0,
		false,
		0.0,
		PackedByteArray(),
		PackedInt32Array(),
		true
	)
	_expect(
		not runtime.has_network_enemy(978)
		and not runtime.has_network_enemy(979),
		"v94 RPC 严格入口必须拒绝 single=-1 与缺失 faction arrays，不能回退配置默认。"
	)
	coordinator.receive_enemy_faction_changed_batch(
		PackedInt32Array([981]),
		PackedByteArray([COMBAT_RELATIONS.PLAYER_ALLIED]),
		PackedInt32Array([4])
	)
	_expect(
		coordinator.pending_enemy_faction_changes.has(981),
		"可靠阵营变更先于出生时必须按 net-id 暂存。"
	)
	coordinator.receive_enemy_spawn(
		981,
		TEST_ENEMY_CONFIG_PATH,
		Vector2(21.0, 22.0),
		1.0,
		1.0,
		COMBAT_RELATIONS.HOSTILE_WAVE,
		0
	)
	var faction_spawn_enemy := runtime.get_network_enemy(981)
	_expect(
		faction_spawn_enemy != null
		and faction_spawn_enemy.get_combat_faction_id()
		== COMBAT_RELATIONS.PLAYER_ALLIED
		and faction_spawn_enemy.get_faction_revision() == 4
		and not coordinator.pending_enemy_faction_changes.has(981),
		"出生事务必须先应用 roster 初值，再消费更高 revision 的 pending 阵营。"
	)
	coordinator.receive_enemy_faction_changed_batch(
		PackedInt32Array([981]),
		PackedByteArray([COMBAT_RELATIONS.HOSTILE_WAVE]),
		PackedInt32Array([3])
	)
	coordinator.receive_enemy_faction_changed_batch(
		PackedInt32Array([981]),
		PackedByteArray([COMBAT_RELATIONS.HOSTILE_WAVE]),
		PackedInt32Array([5])
	)
	_expect(
		faction_spawn_enemy.get_combat_faction_id()
		== COMBAT_RELATIONS.HOSTILE_WAVE
		and faction_spawn_enemy.get_faction_revision() == 5,
		"客户端阵营同步必须拒绝 stale revision 并接纳严格更新。"
	)
	coordinator.receive_enemy_spawn(
		982,
		TEST_ENEMY_CONFIG_PATH,
		Vector2(22.0, 23.0),
		1.0,
		1.0,
		COMBAT_RELATIONS.PLAYER_ALLIED,
		5,
		10.0
	)
	var first_same_config_incarnation := runtime.get_network_enemy(982)
	coordinator._client_enemy_action_revisions[982] = 9
	coordinator._client_target_presentation_revisions[982] = 9
	coordinator.receive_enemy_spawn(
		982,
		TEST_ENEMY_CONFIG_PATH,
		Vector2(24.0, 25.0),
		2.0,
		2.0,
		COMBAT_RELATIONS.HOSTILE_WAVE,
		0,
		11.0
	)
	var second_same_config_incarnation := runtime.get_network_enemy(982)
	_expect(
		first_same_config_incarnation != null
		and second_same_config_incarnation != null
		and second_same_config_incarnation != first_same_config_incarnation
		and second_same_config_incarnation.get_faction_revision() == 0
		and second_same_config_incarnation.get_combat_faction_id()
		== COMBAT_RELATIONS.HOSTILE_WAVE
		and not coordinator._client_enemy_action_revisions.has(982)
		and not coordinator._client_target_presentation_revisions.has(982)
		and is_equal_approx(
			float(coordinator.enemy_spawn_incarnation_tokens.get(982, -1.0)),
			11.0
		),
		"同 net-id、同配置但出生令牌更新时必须替换代理，并清空上一 incarnation 的阵营与动作水位。"
	)
	coordinator.receive_enemy_action(
		982,
		&"old_incarnation_high_revision",
		Vector2.RIGHT,
		Vector2(24.0, 25.0),
		99,
		50.0,
		50.0,
		10.5
	)
	_expect(
		not coordinator._client_enemy_action_revisions.has(982)
		and not coordinator.pending_enemy_actions.has(982),
		"旧 source incarnation 的高 action-id 必须按 raw Host 时间拒绝，不能污染新实体水位。"
	)
	coordinator.remove_client_enemy(982, false)
	coordinator.receive_enemy_action(
		981,
		&"revision_probe",
		Vector2.RIGHT,
		faction_spawn_enemy.global_position,
		1,
		1.1,
		1.1,
		10.1
	)
	coordinator.receive_enemy_target_action(
		981,
		&"pending_target_probe",
		TARGET_DESCRIPTOR.create_enemy(1999, 0, Vector2(40.0, 40.0)),
		faction_spawn_enemy.global_position,
		2,
		1.2,
		1.2,
		10.2
	)
	_expect(
		coordinator.pending_enemy_actions.has(981)
		and int(coordinator._client_enemy_action_revisions.get(981, 0)) == 1,
		"移除前夹具必须同时建立 target pending 与已交付 assignment revision。"
	)
	coordinator.remove_client_enemy(981, false)
	_expect(
		not coordinator.pending_enemy_actions.has(981)
		and not coordinator.pending_enemy_faction_changes.has(981)
		and not coordinator._client_enemy_action_revisions.has(981)
		and not coordinator.client_terminal_enemy_ids.has(981),
		"通用名册移除必须清理 faction/target pending、assignment revision 与旧终态。"
	)
	await process_frame
	coordinator.receive_enemy_spawn(
		981,
		TEST_ENEMY_CONFIG_PATH,
		Vector2(23.0, 24.0),
		2.0,
		2.0,
		COMBAT_RELATIONS.HOSTILE_WAVE,
		0
	)
	var respawned_faction_enemy := runtime.get_network_enemy(981)
	_expect(
		respawned_faction_enemy != null
		and respawned_faction_enemy.get_faction_revision() == 0
		and respawned_faction_enemy.get_combat_faction_id()
		== COMBAT_RELATIONS.HOSTILE_WAVE,
		"名册淘汰后同 net-id 重生必须从新出生 revision 开始，不能继承旧阵营状态。"
	)
	var old_incarnation_state := SnapshotManager.EnemyState.new()
	old_incarnation_state.net_id = 981
	old_incarnation_state.position = Vector2(999.0, 999.0)
	old_incarnation_state.health = 0
	old_incarnation_state.health_revision = 99
	old_incarnation_state.is_dead = true
	old_incarnation_state.faction_id = COMBAT_RELATIONS.PLAYER_ALLIED
	old_incarnation_state.faction_revision = 99
	var preserved_roster_state := SnapshotManager.EnemyState.new()
	preserved_roster_state.net_id = 970
	preserved_roster_state.position = preserved_enemy.global_position
	preserved_roster_state.health = preserved_enemy.current_health
	preserved_roster_state.health_revision = preserved_enemy.health_revision
	preserved_roster_state.faction_id = preserved_enemy.get_combat_faction_id()
	preserved_roster_state.faction_revision = preserved_enemy.get_faction_revision()
	var old_incarnation_codec := SnapshotManager.new()
	var old_incarnation_states: Array[SnapshotManager.EnemyState] = [
		old_incarnation_state,
		preserved_roster_state,
	]
	coordinator.apply_authoritative_snapshot(
		1.5,
		old_incarnation_codec.encode_all_enemy_snapshots(
			old_incarnation_states
		),
		0,
		0,
		1,
		NET_CONSTANTS.ENEMY_SNAPSHOT_HZ
	)
	_expect(
		runtime.get_network_enemy(981) == respawned_faction_enemy
		and respawned_faction_enemy.get_faction_revision() == 0
		and respawned_faction_enemy.get_combat_faction_id()
		== COMBAT_RELATIONS.HOSTILE_WAVE
		and not respawned_faction_enemy.is_dead
		and not coordinator.client_terminal_enemy_ids.has(981),
		"旧 incarnation 快照即使携带更高 revision/is_dead，也不得污染或删除 spawn 后同 net-id 新实体。"
	)
	var new_incarnation_state := SnapshotManager.EnemyState.new()
	new_incarnation_state.net_id = 981
	new_incarnation_state.position = Vector2(24.0, 25.0)
	new_incarnation_state.health = 130
	new_incarnation_state.health_revision = 1
	new_incarnation_state.faction_id = COMBAT_RELATIONS.PLAYER_ALLIED
	new_incarnation_state.faction_revision = 1
	var new_incarnation_sender := SnapshotManager.new()
	var new_incarnation_states: Array[SnapshotManager.EnemyState] = [
		new_incarnation_state,
		preserved_roster_state,
	]
	coordinator.apply_authoritative_snapshot(
		2.1,
		new_incarnation_sender.encode_enemy_snapshots_for_peer(
			77,
			new_incarnation_states,
			true
		),
		0,
		0,
		1,
		NET_CONSTANTS.ENEMY_SNAPSHOT_HZ
	)
	new_incarnation_state.health = 120
	new_incarnation_state.health_revision = 2
	new_incarnation_state.faction_id = COMBAT_RELATIONS.HOSTILE_WAVE
	new_incarnation_state.faction_revision = 2
	# 普通敌人 delta 不携带阵营字段；实时变化先由 reliable CH5 收敛，
	# 后续 full keyframe 再负责重连修复。这里保持生产协议顺序，只让 delta
	# 验证旧 incarnation baseline 已被清除后仍可继续恢复生命修订。
	coordinator.receive_enemy_faction_changed_batch(
		PackedInt32Array([981]),
		PackedByteArray([COMBAT_RELATIONS.HOSTILE_WAVE]),
		PackedInt32Array([2])
	)
	coordinator.apply_authoritative_snapshot(
		2.2,
		new_incarnation_sender.encode_enemy_snapshots_for_peer(
			77,
			new_incarnation_states,
			false
		),
		0,
		0,
		1,
		NET_CONSTANTS.ENEMY_SNAPSHOT_HZ
	)
	var recovered_incarnation_baseline := (
		coordinator._snapshot_manager.enemy_receive_baselines.get(981)
		as SnapshotManager.EnemyState
	)
	_expect(
		respawned_faction_enemy.current_health == 120
		and respawned_faction_enemy.health_revision == 2
		and respawned_faction_enemy.get_combat_faction_id()
		== COMBAT_RELATIONS.HOSTILE_WAVE
		and respawned_faction_enemy.get_faction_revision() == 2
		and recovered_incarnation_baseline != null
		and recovered_incarnation_baseline.health == 120
		and recovered_incarnation_baseline.health_revision == 2,
		"拒绝旧 incarnation 后必须清空接收基线，并允许新 keyframe/delta 正常重建。"
	)
	var malformed_empty_roster := PackedByteArray([0, 0, 123])
	coordinator.apply_authoritative_snapshot(
		2.3,
		malformed_empty_roster,
		0,
		0,
		1,
		NET_CONSTANTS.ENEMY_SNAPSHOT_HZ
	)
	_expect(
		runtime.get_network_enemy(981) == respawned_faction_enemy
		and runtime.get_network_enemy(970) == preserved_enemy,
		"count=0 且携带 trailing bytes 的非法空 roster 不得被误认完整快照并清场。"
	)
	coordinator.remove_client_enemy(981, false)
	coordinator.receive_enemy_faction_changed_batch(
		PackedInt32Array([982]),
		PackedByteArray([COMBAT_RELATIONS.PLAYER_ALLIED]),
		PackedInt32Array([7])
	)
	coordinator.receive_enemy_terminal(
		982,
		MpEnemyCoordinator.ENEMY_TERMINAL_REMOVED,
		Vector2.ZERO,
		0,
		0,
		0,
		Vector2.ZERO,
		EnemyConfig.DamageType.PHYSICAL,
		0
	)
	_expect(
		not coordinator.pending_enemy_faction_changes.has(982)
		and coordinator.client_terminal_enemy_ids.has(982),
		"可靠终态必须清理 spawn 前阵营 pending 并建立墓碑。"
	)
	coordinator.receive_enemy_spawn(
		982,
		TEST_ENEMY_CONFIG_PATH,
		Vector2(25.0, 26.0),
		3.0,
		3.0,
		COMBAT_RELATIONS.HOSTILE_WAVE,
		0
	)
	_expect(
		runtime.get_network_enemy(982) != null
		and not coordinator.client_terminal_enemy_ids.has(982),
		"同 net-id 权威重生必须在实体公开前清掉上一 incarnation 的终态墓碑。"
	)
	coordinator.remove_client_enemy(982, false)

	# 使用独立客户端运行时验证 raw Host 时间的 incarnation/roster CAS，避免
	# offset 重估让迟到快照在 mapped 时间轴上反而显得比可靠 spawn 更新。
	var snapshot_cas_coordinator := (
		ENEMY_COORDINATOR_SCENE.instantiate() as MpEnemyCoordinator
	)
	var snapshot_cas_runtime := ProbeRuntime.new()
	var snapshot_cas_container := Node2D.new()
	get_root().add_child(snapshot_cas_coordinator)
	get_root().add_child(snapshot_cas_container)
	snapshot_cas_runtime.runtime_mode = CombatRuntimeBase.RuntimeMode.CLIENT_VIEW
	snapshot_cas_runtime.enemy_container = snapshot_cas_container
	snapshot_cas_coordinator.bind_runtime(snapshot_cas_runtime)
	snapshot_cas_coordinator.receive_enemy_spawn(
		983,
		TEST_ENEMY_CONFIG_PATH,
		Vector2(30.0, 31.0),
		100.0,
		100.0,
		COMBAT_RELATIONS.HOSTILE_WAVE,
		0,
		100.0
	)
	var no_offset_spawn_enemy := snapshot_cas_runtime.get_network_enemy(983)
	var empty_full_roster := PackedByteArray([0, 0])
	snapshot_cas_coordinator.apply_authoritative_snapshot(
		99.0,
		empty_full_roster,
		0,
		0,
		1,
		NET_CONSTANTS.ENEMY_SNAPSHOT_HZ,
		99.0
	)
	_expect(
		no_offset_spawn_enemy != null
		and snapshot_cas_runtime.get_network_enemy(983) == no_offset_spawn_enemy
		and not snapshot_cas_coordinator.client_terminal_enemy_ids.has(983),
		"无 offset 时，spawn 前的旧 full roster 不得删除可靠名册刚建立的新 incarnation。"
	)
	snapshot_cas_coordinator.receive_enemy_spawn(
		984,
		TEST_ENEMY_CONFIG_PATH,
		Vector2(32.0, 33.0),
		200.0,
		200.0,
		COMBAT_RELATIONS.HOSTILE_WAVE,
		0,
		200.0
	)
	var drift_spawn_enemy := snapshot_cas_runtime.get_network_enemy(984)
	var drift_seed_state := SnapshotManager.EnemyState.new()
	drift_seed_state.net_id = 984
	drift_seed_state.position = Vector2(32.0, 33.0)
	drift_seed_state.health = drift_spawn_enemy.current_health
	drift_seed_state.health_revision = drift_spawn_enemy.health_revision
	var drift_seed_states: Array[SnapshotManager.EnemyState] = [drift_seed_state]
	var drift_seed_codec := SnapshotManager.new()
	snapshot_cas_coordinator.apply_authoritative_snapshot(
		200.0,
		drift_seed_codec.encode_all_enemy_snapshots(drift_seed_states),
		0,
		0,
		1,
		NET_CONSTANTS.ENEMY_SNAPSHOT_HZ,
		200.0
	)
	var drift_seed_baseline := (
		snapshot_cas_coordinator._snapshot_manager.enemy_receive_baselines.get(984)
		as SnapshotManager.EnemyState
	)
	snapshot_cas_coordinator.apply_authoritative_snapshot(
		1200.0,
		empty_full_roster,
		0,
		0,
		1,
		NET_CONSTANTS.ENEMY_SNAPSHOT_HZ,
		199.0
	)
	var drift_preserved_baseline := (
		snapshot_cas_coordinator._snapshot_manager.enemy_receive_baselines.get(984)
		as SnapshotManager.EnemyState
	)
	_expect(
		drift_spawn_enemy != null
		and snapshot_cas_runtime.get_network_enemy(984) == drift_spawn_enemy
		and drift_seed_baseline != null
		and drift_preserved_baseline != null
		and drift_preserved_baseline.health_revision
		== drift_seed_baseline.health_revision
		and not snapshot_cas_coordinator.client_terminal_enemy_ids.has(984),
		"offset 漂移即使令旧 roster 的 mapped 时间更晚，也必须按 raw spawn token 同时保留实体与新基线。"
	)

	snapshot_cas_coordinator.receive_enemy_spawn(
		985,
		TEST_ENEMY_CONFIG_PATH,
		Vector2(34.0, 35.0),
		300.0,
		300.0,
		COMBAT_RELATIONS.HOSTILE_WAVE,
		0,
		300.0
	)
	snapshot_cas_coordinator.receive_enemy_terminal(
		985,
		MpEnemyCoordinator.ENEMY_TERMINAL_REMOVED,
		Vector2(34.0, 35.0),
		0,
		1,
		0,
		Vector2.ZERO,
		EnemyConfig.DamageType.PHYSICAL,
		0
	)
	var terminal_old_state := SnapshotManager.EnemyState.new()
	terminal_old_state.net_id = 985
	terminal_old_state.position = Vector2(999.0, 999.0)
	terminal_old_state.health = 999
	terminal_old_state.health_revision = 99
	terminal_old_state.faction_id = COMBAT_RELATIONS.PLAYER_ALLIED
	terminal_old_state.faction_revision = 99
	var terminal_old_states: Array[SnapshotManager.EnemyState] = [
		terminal_old_state,
	]
	var terminal_old_codec := SnapshotManager.new()
	var terminal_old_packet := terminal_old_codec.encode_all_enemy_snapshots(
		terminal_old_states
	)
	snapshot_cas_coordinator.apply_authoritative_snapshot(
		5000.0,
		terminal_old_packet,
		0,
		0,
		1,
		NET_CONSTANTS.ENEMY_SNAPSHOT_HZ,
		299.0
	)
	_expect(
		not snapshot_cas_runtime.has_network_enemy(985)
		and snapshot_cas_coordinator.client_terminal_enemy_ids.has(985)
		and not snapshot_cas_coordinator.enemy_interpolators.has(985)
		and not snapshot_cas_coordinator.pending_enemy_faction_changes.has(985)
		and not snapshot_cas_coordinator._snapshot_manager.enemy_receive_baselines.has(985),
		"terminal 墓碑必须拒绝迟到 alive 快照，不能重建插值器、阵营 pending 或接收基线。"
	)
	snapshot_cas_coordinator.receive_enemy_spawn(
		985,
		TEST_ENEMY_CONFIG_PATH,
		Vector2(36.0, 37.0),
		301.0,
		301.0,
		COMBAT_RELATIONS.HOSTILE_WAVE,
		0,
		301.0
	)
	var terminal_respawn_enemy := snapshot_cas_runtime.get_network_enemy(985)
	snapshot_cas_coordinator.apply_authoritative_snapshot(
		6000.0,
		terminal_old_packet,
		0,
		0,
		1,
		NET_CONSTANTS.ENEMY_SNAPSHOT_HZ,
		299.0
	)
	_expect(
		terminal_respawn_enemy != null
		and snapshot_cas_runtime.get_network_enemy(985) == terminal_respawn_enemy
		and terminal_respawn_enemy.get_combat_faction_id()
		== COMBAT_RELATIONS.HOSTILE_WAVE
		and terminal_respawn_enemy.get_faction_revision() == 0
		and not terminal_respawn_enemy.is_dead
		and not snapshot_cas_coordinator.client_terminal_enemy_ids.has(985)
		and not snapshot_cas_coordinator._snapshot_manager.enemy_receive_baselines.has(985),
		"同 ID 新 spawn 清墓碑后，上一 incarnation 的高 revision 快照仍必须按 raw token 拒绝。"
	)

	# 表现墓碑只保留有限条目，但 incarnation raw 水位必须持续阻断同 ID 的
	# 旧 CH3。否则墓碑淘汰后的 alive 快照会提前建立插值器并缓存高 revision
	# 阵营，随后真正的新 spawn 会继承上一 incarnation 的位置/阵营。
	snapshot_cas_coordinator.reset_session_state()
	var evicted_terminal_id := 986
	snapshot_cas_coordinator.receive_enemy_spawn(
		evicted_terminal_id,
		TEST_ENEMY_CONFIG_PATH,
		Vector2(38.0, 39.0),
		800.0,
		800.0,
		COMBAT_RELATIONS.HOSTILE_WAVE,
		0,
		800.0
	)
	snapshot_cas_coordinator.receive_enemy_terminal(
		evicted_terminal_id,
		MpEnemyCoordinator.ENEMY_TERMINAL_REMOVED,
		Vector2(38.0, 39.0),
		0,
		1,
		0,
		Vector2.ZERO,
		EnemyConfig.DamageType.PHYSICAL,
		0
	)
	for tombstone_index in range(
		MpEnemyCoordinator.CLIENT_TERMINAL_ENEMY_TOMBSTONE_MAX_ENTRIES
	):
		snapshot_cas_coordinator.mark_client_terminal(20000 + tombstone_index)
	var evicted_terminal_raw_token := float(
		snapshot_cas_coordinator.client_terminal_enemy_incarnation_tokens.get(
			evicted_terminal_id,
			-1.0
		)
	)
	_expect(
		not snapshot_cas_coordinator.client_terminal_enemy_ids.has(
			evicted_terminal_id
		)
		and snapshot_cas_coordinator.client_terminal_enemy_incarnation_tokens.has(
			evicted_terminal_id
		)
		and is_equal_approx(evicted_terminal_raw_token, 800.0)
		and not snapshot_cas_runtime.has_network_enemy(evicted_terminal_id),
		"有限表现墓碑淘汰后必须保留终态 incarnation raw 水位。"
	)
	var evicted_terminal_old_state := SnapshotManager.EnemyState.new()
	evicted_terminal_old_state.net_id = evicted_terminal_id
	evicted_terminal_old_state.position = Vector2(999.0, 999.0)
	evicted_terminal_old_state.health = 999
	evicted_terminal_old_state.health_revision = 99
	evicted_terminal_old_state.faction_id = COMBAT_RELATIONS.PLAYER_ALLIED
	evicted_terminal_old_state.faction_revision = 99
	var evicted_terminal_old_states: Array[SnapshotManager.EnemyState] = [
		evicted_terminal_old_state,
	]
	var evicted_terminal_codec := SnapshotManager.new()
	var evicted_terminal_old_packet := (
		evicted_terminal_codec.encode_all_enemy_snapshots(
			evicted_terminal_old_states
		)
	)
	snapshot_cas_coordinator.apply_authoritative_snapshot(
		805.0,
		evicted_terminal_old_packet,
		0,
		0,
		1,
		NET_CONSTANTS.ENEMY_SNAPSHOT_HZ,
		805.0
	)
	var evicted_terminal_has_baseline := (
		snapshot_cas_coordinator._snapshot_manager.enemy_receive_baselines.has(
			evicted_terminal_id
		)
	)
	_expect(
		not snapshot_cas_runtime.has_network_enemy(evicted_terminal_id)
		and not snapshot_cas_coordinator.enemy_interpolators.has(
			evicted_terminal_id
		)
		and not snapshot_cas_coordinator.pending_enemy_faction_changes.has(
			evicted_terminal_id
		)
		and not evicted_terminal_has_baseline,
		"墓碑淘汰后的旧 CH3 仍必须由 raw 水位拒绝，不能污染插值器、阵营 pending 或接收基线。"
	)
	snapshot_cas_coordinator.receive_enemy_spawn(
		evicted_terminal_id,
		TEST_ENEMY_CONFIG_PATH,
		Vector2(40.0, 41.0),
		806.0,
		806.0,
		COMBAT_RELATIONS.HOSTILE_WAVE,
		0,
		800.0
	)
	_expect(
		not snapshot_cas_runtime.has_network_enemy(evicted_terminal_id)
		and snapshot_cas_coordinator.client_terminal_enemy_incarnation_tokens.has(
			evicted_terminal_id
		),
		"表现墓碑淘汰后，同 raw token 的迟到 spawn 仍不能伪造新 incarnation。"
	)
	var evicted_terminal_respawn_position := Vector2(42.0, 43.0)
	snapshot_cas_coordinator.receive_enemy_spawn(
		evicted_terminal_id,
		TEST_ENEMY_CONFIG_PATH,
		evicted_terminal_respawn_position,
		810.0,
		810.0,
		COMBAT_RELATIONS.HOSTILE_WAVE,
		0,
		810.0
	)
	var evicted_terminal_respawn := (
		snapshot_cas_runtime.get_network_enemy(evicted_terminal_id)
	)
	_expect(
		evicted_terminal_respawn != null
		and evicted_terminal_respawn.global_position
		== evicted_terminal_respawn_position
		and evicted_terminal_respawn.get_combat_faction_id()
		== COMBAT_RELATIONS.HOSTILE_WAVE
		and evicted_terminal_respawn.get_faction_revision() == 0
		and not snapshot_cas_coordinator.client_terminal_enemy_ids.has(
			evicted_terminal_id
		)
		and not snapshot_cas_coordinator.client_terminal_enemy_incarnation_tokens.has(
			evicted_terminal_id
		)
		and not snapshot_cas_coordinator.pending_enemy_faction_changes.has(
			evicted_terminal_id
		),
		"只有严格更新的 spawn token 才能提交同 ID 新 incarnation，并在消费 pending 前清 raw 水位。"
	)

	# 非末 chunk 固定 41 条。第二 chunk 故意重复第一块的实体并携带更高
	# revision；跨块 ID 预扫应在正式 decode 前终止，不能污染已提交 baseline。
	snapshot_cas_coordinator.reset_session_state()
	snapshot_cas_coordinator.receive_enemy_spawn(
		10000,
		TEST_ENEMY_CONFIG_PATH,
		Vector2(40.0, 41.0),
		650.0,
		650.0,
		COMBAT_RELATIONS.HOSTILE_WAVE,
		0,
		650.0
	)
	var duplicate_chunk_states: Array[SnapshotManager.EnemyState] = []
	for state_offset in range(
		MpEnemyCoordinator.ENEMY_SNAPSHOT_CHUNK_MAX_ENTITIES
	):
		var chunk_state := SnapshotManager.EnemyState.new()
		chunk_state.net_id = 10000 + state_offset
		chunk_state.position = Vector2(40.0 + state_offset, 41.0)
		chunk_state.health = 80
		chunk_state.health_revision = 1
		duplicate_chunk_states.append(chunk_state)
	var duplicate_chunk_sender := SnapshotManager.new()
	var first_duplicate_batch_chunk := (
		duplicate_chunk_sender.encode_enemy_snapshots_for_peer(
			91,
			duplicate_chunk_states,
			true
		)
	)
	snapshot_cas_coordinator.apply_authoritative_snapshot(
		700.0,
		first_duplicate_batch_chunk,
		700,
		0,
		2,
		NET_CONSTANTS.ENEMY_SNAPSHOT_HZ,
		700.0
	)
	var poison_state := SnapshotManager.EnemyState.new()
	poison_state.net_id = 10000
	poison_state.position = Vector2(777.0, 777.0)
	poison_state.health = 777
	poison_state.health_revision = 77
	poison_state.faction_id = COMBAT_RELATIONS.PLAYER_ALLIED
	poison_state.faction_revision = 77
	var poison_states: Array[SnapshotManager.EnemyState] = [poison_state]
	var poison_codec := SnapshotManager.new()
	snapshot_cas_coordinator.apply_authoritative_snapshot(
		700.0,
		poison_codec.encode_all_enemy_snapshots(poison_states),
		700,
		1,
		2,
		NET_CONSTANTS.ENEMY_SNAPSHOT_HZ,
		700.0
	)
	var baseline_after_duplicate_rejection := (
		snapshot_cas_coordinator._snapshot_manager.enemy_receive_baselines.get(10000)
		as SnapshotManager.EnemyState
	)
	_expect(
		baseline_after_duplicate_rejection != null
		and baseline_after_duplicate_rejection.health == 80
		and baseline_after_duplicate_rejection.health_revision == 1
		and baseline_after_duplicate_rejection.faction_id
		== COMBAT_RELATIONS.HOSTILE_WAVE
		and not snapshot_cas_coordinator.pending_enemy_snapshot_batches.has(700),
		"跨 chunk 重复实体必须整块拒绝，不能先把恶意高 revision 写入 decode baseline。"
	)
	var continuation_sender := SnapshotManager.new()
	var continuation_state := SnapshotManager.EnemyState.new()
	continuation_state.net_id = 10000
	continuation_state.position = Vector2(40.0, 41.0)
	continuation_state.health = 80
	continuation_state.health_revision = 1
	var continuation_states: Array[SnapshotManager.EnemyState] = [
		continuation_state,
	]
	continuation_sender.encode_enemy_snapshots_for_peer(
		92,
		continuation_states,
		true
	)
	continuation_state.health = 70
	continuation_state.health_revision = 2
	snapshot_cas_coordinator.apply_authoritative_snapshot(
		701.0,
		continuation_sender.encode_enemy_snapshots_for_peer(
			92,
			continuation_states,
			false
		),
		0,
		0,
		1,
		NET_CONSTANTS.ENEMY_SNAPSHOT_HZ,
		701.0
	)
	var recovered_duplicate_baseline := (
		snapshot_cas_coordinator._snapshot_manager.enemy_receive_baselines.get(10000)
		as SnapshotManager.EnemyState
	)
	var duplicate_probe_enemy := snapshot_cas_runtime.get_network_enemy(10000)
	_expect(
		recovered_duplicate_baseline != null
		and recovered_duplicate_baseline.health == 70
		and recovered_duplicate_baseline.health_revision == 2
		and duplicate_probe_enemy != null
		and duplicate_probe_enemy.current_health == 70
		and duplicate_probe_enemy.health_revision == 2,
		"拒绝重复块后，合法后续 delta 必须沿未污染 baseline 正常收敛。"
	)
	snapshot_cas_coordinator.reset_session_state()
	snapshot_cas_coordinator.unbind_runtime(snapshot_cas_runtime)
	snapshot_cas_container.free()
	snapshot_cas_runtime.free()
	snapshot_cas_coordinator.free()
	await process_frame
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
		0.0,
		PackedByteArray([
			COMBAT_RELATIONS.PLAYER_ALLIED,
			COMBAT_RELATIONS.HOSTILE_WAVE,
		]),
		PackedInt32Array([3, 0])
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
		0.0,
		PackedByteArray([
			COMBAT_RELATIONS.PLAYER_ALLIED,
			COMBAT_RELATIONS.HOSTILE_WAVE,
		]),
		PackedInt32Array([3, 0])
	)
	coordinator.remote_enemy_spawned.disconnect(_on_atomic_spawn_probe)
	_expect(
		_atomic_spawn_callback_count == 2
		and _atomic_spawn_first_callback_saw_full_registry
		and runtime.get_network_enemy(974) != null
		and runtime.get_network_enemy(975) != null
		and runtime.get_network_enemy(974).get_combat_faction_id()
		== COMBAT_RELATIONS.PLAYER_ALLIED
		and runtime.get_network_enemy(974).get_faction_revision() == 3
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
	var faction_snapshot_state := SnapshotManager.EnemyState.new()
	faction_snapshot_state.net_id = 951
	faction_snapshot_state.position = Vector2(18.0, 24.0)
	faction_snapshot_state.health = 75
	faction_snapshot_state.health_revision = 3
	faction_snapshot_state.faction_id = COMBAT_RELATIONS.PLAYER_ALLIED
	faction_snapshot_state.faction_revision = 5
	var faction_snapshot_codec := SnapshotManager.new()
	var faction_snapshot_states: Array[SnapshotManager.EnemyState] = [
		faction_snapshot_state
	]
	var faction_snapshot_data := faction_snapshot_codec.encode_all_enemy_snapshots(
		faction_snapshot_states
	)
	coordinator.apply_authoritative_snapshot(
		30.0,
		faction_snapshot_data,
		0,
		0,
		1,
		NET_CONSTANTS.ENEMY_SNAPSHOT_HZ
	)
	_expect(
		feedback_probe.get_combat_faction_id() == COMBAT_RELATIONS.PLAYER_ALLIED
		and feedback_probe.get_faction_revision() == 5,
		"full keyframe 必须修复客户端敌人阵营与 entity revision。"
	)
	coordinator.receive_enemy_faction_changed_batch(
		PackedInt32Array([951]),
		PackedByteArray([COMBAT_RELATIONS.HOSTILE_WAVE]),
		PackedInt32Array([6])
	)
	coordinator.apply_authoritative_snapshot(
		30.1,
		faction_snapshot_data,
		0,
		0,
		1,
		NET_CONSTANTS.ENEMY_SNAPSHOT_HZ
	)
	_expect(
		feedback_probe.get_combat_faction_id() == COMBAT_RELATIONS.HOSTILE_WAVE
		and feedback_probe.get_faction_revision() == 6,
		"较旧 full keyframe 必须服从 faction revision CAS，不能覆盖较新的可靠变更。"
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
	var target_action_source := TargetActionProbeEnemy.new()
	coordinator.register_client_enemy(1101, target_action_source, 40.0)
	var late_enemy_descriptor := TARGET_DESCRIPTOR.create_enemy(
		1102,
		2,
		Vector2(80.0, 24.0)
	)
	coordinator.receive_enemy_target_action(
		1101,
		&"late_enemy_target",
		late_enemy_descriptor,
		Vector2(32.0, 24.0),
		1,
		40.1,
		40.1,
		200.1
	)
	_expect(
		coordinator.pending_enemy_actions.has(1101)
		and target_action_source.target_action_count == 0,
		"动作源已存在但动态目标尚未生成时，必须保留通用目标动作而非只用 fallback。"
	)
	var late_enemy_target := Enemy.new()
	late_enemy_target.set_combat_faction_id(
		COMBAT_RELATIONS.HOSTILE_WAVE,
		2,
		true
	)
	coordinator.register_client_enemy(1102, late_enemy_target, 40.2)
	coordinator.interpolate_remote_enemies(40.2)
	_expect(
		target_action_source.target_action_count == 1
		and target_action_source.last_target == late_enemy_target
		and target_action_source.last_target_action_id == 1
		and not coordinator.pending_enemy_actions.has(1101),
		"Enemy 目标进入稳定 net-id 注册表后，pending 动作必须按原 assignment revision 重放。"
	)
	coordinator.receive_enemy_target_action(
		1101,
		&"stale_entity_revision",
		TARGET_DESCRIPTOR.create_enemy(1102, 1, late_enemy_target.global_position),
		Vector2(33.0, 24.0),
		2,
		40.3,
		40.3,
		200.2
	)
	coordinator.receive_enemy_target_action(
		1101,
		&"current_enemy_revision",
		late_enemy_descriptor,
		Vector2(34.0, 24.0),
		3,
		40.4,
		40.4,
		200.3
	)
	_expect(
		target_action_source.target_action_count == 2
		and target_action_source.last_target_action_id == 3,
		"旧 entity revision 的动作必须丢弃，但更新 assignment revision 仍可稳定解析同一 Enemy。"
	)
	var player_target := Player.new()
	runtime.peer_players[2] = player_target
	var no_offset_active_source := TargetActionProbeEnemy.new()
	var no_offset_none_source := TargetActionProbeEnemy.new()
	coordinator.register_client_enemy(1127, no_offset_active_source, 40.5)
	coordinator.register_client_enemy(1128, no_offset_none_source, 40.5)
	coordinator.receive_enemy_target_presentation_state_batch_packet(
		PackedInt32Array([1127, 1128]),
		PackedInt32Array([1, 1]),
		PackedByteArray([
			Enemy.TargetPresentationPhase.SNIPER_LOCK,
			Enemy.TargetPresentationPhase.NONE,
		]),
		PackedByteArray([
			TARGET_DESCRIPTOR.Kind.PLAYER,
			TARGET_DESCRIPTOR.Kind.NONE,
		]),
		PackedInt32Array([2, 0]),
		PackedInt32Array([0, 0]),
		PackedVector2Array([player_target.global_position, Vector2.ZERO]),
		PackedFloat64Array([100.0, 102.0]),
		PackedFloat64Array([103.0, 102.0]),
		PackedVector2Array([Vector2(35.0, 24.0), Vector2(36.0, 24.0)]),
		40.5,
		false,
		0.0
	)
	_expect(
		no_offset_active_source.presentation_state_count == 1
		and no_offset_active_source.last_presentation_phase
		== Enemy.TargetPresentationPhase.SNIPER_LOCK
		and no_offset_active_source.last_presentation_target == player_target
		and is_equal_approx(no_offset_active_source.last_presentation_remaining, 3.0)
		and no_offset_none_source.presentation_state_count == 1
		and no_offset_none_source.last_presentation_phase
		== Enemy.TargetPresentationPhase.NONE,
		"Host 时钟偏移尚未建立时，混合 ACTIVE/NONE 批次必须保留 Host 持续时长并原子应用。"
	)
	coordinator.receive_enemy_target_action(
		1101,
		&"player_target",
		TARGET_DESCRIPTOR.create_player(2, 0, player_target.global_position),
		Vector2(35.0, 24.0),
		4,
		40.5,
		40.5,
		200.4
	)
	var plant_target := PlantDefense.new()
	runtime.probe_plants[77] = plant_target
	coordinator.receive_enemy_target_action(
		1101,
		&"plant_target",
		TARGET_DESCRIPTOR.create_plant(77, 0, plant_target.global_position),
		Vector2(36.0, 24.0),
		5,
		40.6,
		40.6,
		200.5
	)
	_expect(
		target_action_source.target_action_count == 4
		and target_action_source.last_target == plant_target
		and target_action_source.last_target_action_id == 5,
		"通用目标动作必须按稳定 ID 解析 Player 与 Plant，而不是继续假设 peer-only。"
	)
	coordinator.receive_enemy_target_action(
		1101,
		&"future_enemy_revision",
		TARGET_DESCRIPTOR.create_enemy(1102, 3, late_enemy_target.global_position),
		Vector2(37.0, 24.0),
		6,
		40.7,
		40.7,
		200.6
	)
	coordinator.receive_enemy_faction_changed_batch(
		PackedInt32Array([1102]),
		PackedByteArray([COMBAT_RELATIONS.PLAYER_ALLIED]),
		PackedInt32Array([3])
	)
	coordinator.interpolate_remote_enemies(40.8)
	_expect(
		target_action_source.target_action_count == 5
		and target_action_source.last_target == late_enemy_target
		and target_action_source.last_target_action_id == 6,
		"目标 faction revision 尚未收敛时必须等待，可靠阵营状态到达后再重放。"
	)
	var start_repair_source := TargetActionProbeEnemy.new()
	coordinator.register_client_enemy(1120, start_repair_source, 40.8)
	coordinator.receive_enemy_target_action(
		1120,
		&"presentation_start",
		TARGET_DESCRIPTOR.create_enemy(
			1102,
			3,
			late_enemy_target.global_position
		),
		Vector2(40.0, 24.0),
		10,
		40.81,
		40.81,
		200.71
	)
	_receive_target_presentation_state(
		coordinator,
		_make_target_presentation_record(
			1120,
			10,
			Enemy.TargetPresentationPhase.SNIPER_LOCK,
			TARGET_DESCRIPTOR.create_enemy(
				1102,
				3,
				late_enemy_target.global_position
			),
			40.81,
			42.81,
			Vector2(40.0, 24.0)
		),
		40.9
	)
	_expect(
		start_repair_source.target_action_count == 1
		and start_repair_source.presentation_state_count == 1
		and start_repair_source.last_presentation_phase
		== Enemy.TargetPresentationPhase.SNIPER_LOCK
		and start_repair_source.last_presentation_target == late_enemy_target
		and start_repair_source.last_presentation_revision == 10,
		"CH7 start rev10 先到时，同 revision 的 CH5 ACTIVE 仍必须可靠修复持续表现。"
	)
	_receive_target_presentation_state(
		coordinator,
		_make_target_presentation_record(
			1120,
			10,
			Enemy.TargetPresentationPhase.NONE,
			TARGET_DESCRIPTOR.create_none(),
			42.81,
			42.81,
			Vector2(40.0, 24.0)
		),
		41.0
	)
	_expect(
		start_repair_source.presentation_state_count == 2
		and start_repair_source.last_presentation_phase
		== Enemy.TargetPresentationPhase.NONE
		and start_repair_source.last_presentation_revision == 10,
		"Host 超时生成的同 revision NONE 必须能覆盖 ACTIVE 并可靠清理视觉。"
	)
	var fire_before_active_source := TargetActionProbeEnemy.new()
	coordinator.register_client_enemy(1121, fire_before_active_source, 40.8)
	coordinator.receive_enemy_action(
		1121,
		&"presentation_clear",
		Vector2.RIGHT,
		Vector2(41.0, 24.0),
		11,
		40.91,
		40.91,
		200.72
	)
	_receive_target_presentation_state(
		coordinator,
		_make_target_presentation_record(
			1121,
			10,
			Enemy.TargetPresentationPhase.SNIPER_LOCK,
			TARGET_DESCRIPTOR.create_enemy(
				1102,
				3,
				late_enemy_target.global_position
			),
			40.8,
			42.8,
			Vector2(41.0, 24.0)
		),
		41.0
	)
	_expect(
		fire_before_active_source.presentation_state_count == 0
		and fire_before_active_source.last_presentation_phase
		== Enemy.TargetPresentationPhase.NONE
		and not coordinator.pending_enemy_target_presentation_states.has(1121),
		"CH7 fire/cancel rev11 先到后，CH5 ACTIVE rev10 必须被跨信道水位拒绝且绝不重开。"
	)
	var clear_before_active_source := TargetActionProbeEnemy.new()
	coordinator.register_client_enemy(1122, clear_before_active_source, 41.0)
	_receive_target_presentation_state(
		coordinator,
		_make_target_presentation_record(
			1122,
			11,
			Enemy.TargetPresentationPhase.NONE,
			TARGET_DESCRIPTOR.create_none(),
			41.0,
			41.0,
			Vector2(42.0, 24.0)
		),
		41.0
	)
	coordinator.receive_enemy_action(
		1122,
		&"presentation_clear",
		Vector2.LEFT,
		Vector2(42.0, 24.0),
		10,
		41.005,
		41.005,
		200.7205
	)
	coordinator.receive_enemy_action(
		1122,
		&"presentation_clear",
		Vector2.RIGHT,
		Vector2(42.0, 24.0),
		11,
		41.01,
		41.01,
		200.721
	)
	_receive_target_presentation_state(
		coordinator,
		_make_target_presentation_record(
			1122,
			10,
			Enemy.TargetPresentationPhase.LIGHTNING_WINDUP,
			TARGET_DESCRIPTOR.create_player(
				2,
				0,
				player_target.global_position
			),
			40.0,
			42.0,
			Vector2(42.0, 24.0)
		),
		41.0
	)
	_expect(
		clear_before_active_source.presentation_state_count == 1
		and clear_before_active_source.generic_action_count == 1
		and clear_before_active_source.last_generic_action_id == 11
		and clear_before_active_source.last_presentation_phase
		== Enemy.TargetPresentationPhase.NONE
		and clear_before_active_source.last_presentation_revision == 11,
		"可靠 NONE rev11 不得吞掉同 revision CH7 fire/cancel；随后乱序 ACTIVE rev10 仍不得复活旧预警。"
	)
	var pending_presentation_source := TargetActionProbeEnemy.new()
	coordinator.register_client_enemy(1123, pending_presentation_source, 41.0)
	_receive_target_presentation_state(
		coordinator,
		_make_target_presentation_record(
			1123,
			1,
			Enemy.TargetPresentationPhase.LIGHTNING_WINDUP,
			TARGET_DESCRIPTOR.create_enemy(1190, 2, Vector2(90.0, 40.0)),
			41.0,
			44.0,
			Vector2(43.0, 24.0)
		),
		41.1
	)
	_expect(
		pending_presentation_source.presentation_state_count == 0
		and coordinator.pending_enemy_target_presentation_states.has(1123),
		"持续表现的 Enemy 目标未生成或 revision 未到时必须独立 pending。"
	)
	var pending_presentation_target := Enemy.new()
	pending_presentation_target.set_combat_faction_id(
		COMBAT_RELATIONS.PLAYER_ALLIED,
		2,
		true
	)
	coordinator.register_client_enemy(1190, pending_presentation_target, 41.2)
	coordinator.interpolate_remote_enemies(41.2)
	_expect(
		pending_presentation_source.presentation_state_count == 1
		and pending_presentation_source.last_presentation_phase
		== Enemy.TargetPresentationPhase.LIGHTNING_WINDUP
		and pending_presentation_source.last_presentation_target
		== pending_presentation_target
		and not coordinator.pending_enemy_target_presentation_states.has(1123),
		"目标进入稳定注册表且 entity revision 收敛后，持续表现必须按原 revision 重放。"
	)
	var source_late_presentation_record := _make_target_presentation_record(
		1124,
		1,
		Enemy.TargetPresentationPhase.SNIPER_LOCK,
		TARGET_DESCRIPTOR.create_player(2, 0, player_target.global_position),
		41.1,
		43.1,
		Vector2(44.0, 24.0)
	)
	_receive_target_presentation_state(
		coordinator,
		source_late_presentation_record,
		41.2
	)
	var source_late_presentation_enemy := TargetActionProbeEnemy.new()
	coordinator.register_client_enemy(1124, source_late_presentation_enemy, 41.3)
	_expect(
		source_late_presentation_enemy.presentation_state_count == 1
		and source_late_presentation_enemy.last_presentation_target == player_target
		and source_late_presentation_enemy.last_presentation_remaining > 0.0,
		"持续表现来源晚生成时必须 replay，并按当前时间恢复 elapsed/remaining。"
	)
	var expired_presentation_source := TargetActionProbeEnemy.new()
	coordinator.register_client_enemy(1125, expired_presentation_source, 41.0)
	_receive_target_presentation_state(
		coordinator,
		_make_target_presentation_record(
			1125,
			1,
			Enemy.TargetPresentationPhase.SNIPER_LOCK,
			TARGET_DESCRIPTOR.create_player(2, 0, player_target.global_position),
			38.0,
			40.0,
			Vector2(45.0, 24.0)
		),
		41.0
	)
	_expect(
		expired_presentation_source.presentation_state_count == 1
		and expired_presentation_source.last_presentation_phase
		== Enemy.TargetPresentationPhase.NONE
		and expired_presentation_source.last_presentation_revision == 1
		and not coordinator.pending_enemy_target_presentation_states.has(1125),
		"迟加入收到已过期 ACTIVE 时必须按同 revision 直接清理，不能闪现旧锁定。"
	)
	var pending_then_fire_source := TargetActionProbeEnemy.new()
	coordinator.register_client_enemy(1126, pending_then_fire_source, 41.0)
	_receive_target_presentation_state(
		coordinator,
		_make_target_presentation_record(
			1126,
			10,
			Enemy.TargetPresentationPhase.LIGHTNING_WINDUP,
			TARGET_DESCRIPTOR.create_enemy(1191, 1, Vector2(92.0, 40.0)),
			41.0,
			44.0,
			Vector2(46.0, 24.0)
		),
		41.1
	)
	coordinator.receive_enemy_action(
		1126,
		&"presentation_clear",
		Vector2.RIGHT,
		Vector2(46.0, 24.0),
		11,
		41.2,
		41.2,
		200.73
	)
	var pending_then_fire_target := Enemy.new()
	pending_then_fire_target.set_combat_faction_id(
		COMBAT_RELATIONS.PLAYER_ALLIED,
		1,
		true
	)
	coordinator.register_client_enemy(1191, pending_then_fire_target, 41.3)
	coordinator.interpolate_remote_enemies(41.3)
	_expect(
		pending_then_fire_source.presentation_state_count == 0
		and pending_then_fire_source.last_presentation_phase
		== Enemy.TargetPresentationPhase.NONE
		and not coordinator.pending_enemy_target_presentation_states.has(1126),
		"ACTIVE 等待目标期间若 CH7 已推进到 fire/cancel，晚生成目标不得绕过 CAS 复活状态。"
	)
	var pending_start_then_none_source := TargetActionProbeEnemy.new()
	coordinator.register_client_enemy(1129, pending_start_then_none_source, 41.3)
	coordinator.receive_enemy_target_action(
		1129,
		&"lightning_windup",
		TARGET_DESCRIPTOR.create_enemy(1192, 1, Vector2(94.0, 40.0)),
		Vector2(47.0, 24.0),
		10,
		41.31,
		41.31,
		200.74
	)
	_expect(
		coordinator.pending_enemy_actions.has(1129),
		"目标尚未生成时，CH7 start 必须先进入有界 pending。"
	)
	_receive_target_presentation_state(
		coordinator,
		_make_target_presentation_record(
			1129,
			10,
			Enemy.TargetPresentationPhase.NONE,
			TARGET_DESCRIPTOR.create_none(),
			41.32,
			41.32,
			Vector2(47.0, 24.0)
		),
		41.32
	)
	_expect(
		not coordinator.pending_enemy_actions.has(1129)
		and pending_start_then_none_source.presentation_state_count == 1
		and pending_start_then_none_source.last_presentation_phase
		== Enemy.TargetPresentationPhase.NONE
		and int(coordinator._client_target_presentation_terminal_revisions.get(
			1129,
			0
		)) == 10,
		"可靠 NONE 必须只淘汰不晚于其 revision 的表现 start pending，不能等待目标后复活。"
	)
	var pending_start_then_none_target := Enemy.new()
	pending_start_then_none_target.set_combat_faction_id(
		COMBAT_RELATIONS.PLAYER_ALLIED,
		1,
		true
	)
	coordinator.register_client_enemy(1192, pending_start_then_none_target, 41.4)
	coordinator.interpolate_remote_enemies(41.4)
	_expect(
		pending_start_then_none_source.target_action_count == 0,
		"NONE 后目标/阵营再收敛时，已终结的 start 不得重新交付。"
	)
	var presentation_net_ids: Array[int] = [
		1120,
		1121,
		1122,
		1123,
		1124,
		1125,
		1126,
		1127,
		1128,
		1129,
		1190,
		1191,
		1192,
	]
	for presentation_net_id in presentation_net_ids:
		coordinator.remove_client_enemy(presentation_net_id, false)
	coordinator.receive_enemy_target_action(
		1101,
		&"terminal_target",
		TARGET_DESCRIPTOR.create_enemy(1200, 0, Vector2(90.0, 24.0)),
		Vector2(38.0, 24.0),
		7,
		40.9,
		40.9,
		200.7
	)
	coordinator.receive_enemy_terminal(
		1200,
		MpEnemyCoordinator.ENEMY_TERMINAL_REMOVED,
		Vector2.ZERO,
		0,
		0,
		0,
		Vector2.ZERO,
		EnemyConfig.DamageType.PHYSICAL,
		0
	)
	_expect(
		not coordinator.pending_enemy_actions.has(1101),
		"动态目标终结必须清掉所有引用该稳定 Enemy ID 的 pending 动作。"
	)
	var source_late_descriptor := TARGET_DESCRIPTOR.create_player(
		2,
		0,
		player_target.global_position
	)
	coordinator.receive_enemy_target_action(
		1103,
		&"source_late",
		source_late_descriptor,
		Vector2(39.0, 24.0),
		1,
		41.0,
		41.0,
		201.0
	)
	var late_action_source := TargetActionProbeEnemy.new()
	coordinator.register_client_enemy(1103, late_action_source, 41.1)
	_expect(
		late_action_source.target_action_count == 1
		and late_action_source.last_target == player_target,
		"动作源晚生成时也必须通过同一 descriptor 解析与 replay 路径交付。"
	)
	coordinator.receive_enemy_target_action(
		1103,
		&"legacy_player_target",
		2,
		Vector2(39.5, 24.0),
		2,
		41.2,
		41.2,
		201.1
	)
	_expect(
		late_action_source.target_action_count == 2
		and late_action_source.last_target == player_target
		and late_action_source.last_target_action_id == 2,
		"旧 peer-id 入口必须在边界转换为 Player descriptor，并复用通用交付路径。"
	)
	coordinator.remove_client_enemy(1101, false)
	coordinator.remove_client_enemy(1102, false)
	coordinator.remove_client_enemy(1103, false)
	runtime.peer_players.erase(2)
	runtime.probe_plants.erase(77)
	player_target.free()
	plant_target.free()
	await process_frame
	var exited_target_source := TargetActionProbeEnemy.new()
	coordinator.register_client_enemy(1110, exited_target_source, 44.0)
	coordinator.receive_enemy_spawn(
		1111,
		TEST_ENEMY_CONFIG_PATH,
		Vector2(50.0, 24.0),
		44.0,
		44.0,
		COMBAT_RELATIONS.HOSTILE_WAVE,
		0
	)
	var externally_exited_target := runtime.get_network_enemy(1111)
	coordinator.receive_enemy_target_action(
		1110,
		&"future_revision_before_target_exit",
		TARGET_DESCRIPTOR.create_enemy(1111, 1, Vector2(50.0, 24.0)),
		Vector2(49.0, 24.0),
		1,
		44.1,
		44.1,
		203.0
	)
	_expect(
		coordinator.pending_enemy_actions.has(1110),
		"目标退出夹具必须先建立等待其 entity revision 的 pending 动作。"
	)
	if externally_exited_target != null:
		externally_exited_target.queue_free()
	await process_frame
	_expect(
		not coordinator.pending_enemy_actions.has(1110)
		and not runtime.has_network_enemy(1111),
		"Enemy tree-exit 必须清理所有引用该稳定 ID 的 pending descriptor。"
	)
	coordinator.receive_enemy_spawn(
		1111,
		TEST_ENEMY_CONFIG_PATH,
		Vector2(52.0, 24.0),
		45.0,
		45.0,
		COMBAT_RELATIONS.PLAYER_ALLIED,
		1,
		45.0
	)
	var replacement_target := runtime.get_network_enemy(1111)
	coordinator.receive_enemy_target_action(
		1110,
		&"late_old_target_incarnation",
		TARGET_DESCRIPTOR.create_enemy(1111, 1, Vector2(52.0, 24.0)),
		Vector2(51.0, 24.0),
		2,
		46.0,
		46.0,
		44.5
	)
	coordinator.interpolate_remote_enemies(45.1)
	_expect(
		exited_target_source.target_action_count == 0
		and not coordinator.pending_enemy_actions.has(1110),
		"旧 descriptor 不得在同 net-id 目标重生后绑定到新 incarnation。"
	)
	coordinator.receive_enemy_target_action(
		1110,
		&"current_target_incarnation",
		TARGET_DESCRIPTOR.create_enemy(1111, 1, Vector2(52.0, 24.0)),
		Vector2(51.0, 24.0),
		3,
		46.1,
		46.1,
		45.1
	)
	var stale_target_presentation := _make_target_presentation_record(
		1110,
		4,
		Enemy.TargetPresentationPhase.SNIPER_LOCK,
		TARGET_DESCRIPTOR.create_enemy(1111, 1, Vector2(52.0, 24.0)),
		46.2,
		47.2,
		Vector2(51.0, 24.0)
	)
	stale_target_presentation["host_reference_timestamp"] = 44.5
	_receive_target_presentation_state(
		coordinator,
		stale_target_presentation,
		46.2
	)
	var current_target_presentation := _make_target_presentation_record(
		1110,
		5,
		Enemy.TargetPresentationPhase.SNIPER_LOCK,
		TARGET_DESCRIPTOR.create_enemy(1111, 1, Vector2(52.0, 24.0)),
		46.3,
		47.3,
		Vector2(51.0, 24.0)
	)
	current_target_presentation["host_reference_timestamp"] = 45.1
	_receive_target_presentation_state(
		coordinator,
		current_target_presentation,
		46.3
	)
	_expect(
		replacement_target != null
		and exited_target_source.target_action_count == 1
		and exited_target_source.last_target == replacement_target
		and exited_target_source.last_target_action_id == 3
		and exited_target_source.presentation_state_count == 2
		and exited_target_source.last_presentation_phase
		== Enemy.TargetPresentationPhase.SNIPER_LOCK
		and exited_target_source.last_presentation_target == replacement_target,
		"raw Host 时间必须让旧 CH7/CH5 目标记录收敛为 stale，同时允许新 incarnation 记录正常绑定。"
	)
	coordinator.remove_client_enemy(1110, false)
	coordinator.remove_client_enemy(1111, false)
	await process_frame
	var manifest_removed_source := TargetActionProbeEnemy.new()
	coordinator.register_client_enemy(1104, manifest_removed_source, 42.0)
	coordinator.receive_enemy_target_action(
		1104,
		&"manifest_pending_target",
		TARGET_DESCRIPTOR.create_enemy(1998, 0, Vector2(60.0, 60.0)),
		Vector2(40.0, 24.0),
		1,
		42.1,
		42.1,
		202.0
	)
	coordinator.reconcile_roster({}, 42.2)
	coordinator.receive_enemy_action(
		1104,
		&"late_after_manifest",
		Vector2.RIGHT,
		Vector2(41.0, 24.0),
		2,
		42.15,
		42.2,
		202.1
	)
	_expect(
		coordinator.client_terminal_enemy_ids.has(1104)
		and not coordinator.pending_enemy_actions.has(1104)
		and not runtime.has_network_enemy(1104),
		"full roster 缺失必须形成 incarnation 墓碑，并阻止跨 CH7 的旧动作重建 pending。"
	)
	await process_frame
	coordinator.receive_enemy_spawn(
		1104,
		TEST_ENEMY_CONFIG_PATH,
		Vector2(42.0, 24.0),
		43.0,
		43.0,
		COMBAT_RELATIONS.HOSTILE_WAVE,
		0
	)
	_expect(
		runtime.has_network_enemy(1104)
		and not coordinator.client_terminal_enemy_ids.has(1104),
		"同 net-id 后续权威 spawn 必须清除 manifest 墓碑并公开新 incarnation。"
	)
	coordinator.remove_client_enemy(1104, false)
	await process_frame
	coordinator.receive_enemy_target_action(
		401,
		&"windup",
		TARGET_DESCRIPTOR.create_player(2, 0, Vector2(10.0, 20.0)),
		Vector2(10.0, 20.0),
		9,
		20.1,
		20.2,
		100.0
	)
	coordinator.receive_enemy_target_action(
		401,
		&"windup_retry",
		TARGET_DESCRIPTOR.create_player(2, 0, Vector2(11.0, 21.0)),
		Vector2(11.0, 21.0),
		9,
		20.15,
		20.2,
		100.1
	)
	coordinator.receive_enemy_target_action(
		401,
		&"stale_retry",
		TARGET_DESCRIPTOR.create_player(2, 0, Vector2(12.0, 22.0)),
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
		and coordinator.pending_enemy_faction_changes.is_empty()
		and coordinator.pending_enemy_target_presentation_states.is_empty()
		and coordinator._client_enemy_action_revisions.is_empty()
		and coordinator._client_target_presentation_revisions.is_empty()
		and coordinator._host_target_presentation_states.is_empty()
		and coordinator.enemy_spawn_incarnation_tokens.is_empty()
		and coordinator._host_enemy_spawn_times.is_empty()
		and coordinator.client_terminal_enemy_ids.is_empty()
		and int(coordinator.get_snapshot_metrics().get(
			"enemy_snapshot_chunk_encode_count",
			-1
		)) == 0,
		"会话重置必须同时释放敌人动作、持续表现、终结墓碑和快照计数。"
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


func _make_target_presentation_record(
	net_id: int,
	state_revision: int,
	phase: int,
	descriptor: CombatTargetDescriptor,
	start_time: float,
	end_time: float,
	action_position: Vector2
) -> Dictionary:
	return {
		"net_id": net_id,
		"state_revision": state_revision,
		"phase": phase,
		"target_kind": descriptor.kind,
		"target_id": descriptor.id,
		"target_revision": descriptor.revision,
		"target_fallback_position": descriptor.fallback_position,
		"start_time": start_time,
		"end_time": end_time,
		"action_position": action_position,
	}


func _receive_target_presentation_state(
	coordinator: MpEnemyCoordinator,
	record: Dictionary,
	current_time: float
) -> void:
	var records: Array[Dictionary] = [record]
	coordinator.receive_enemy_target_presentation_states(records, current_time)


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
