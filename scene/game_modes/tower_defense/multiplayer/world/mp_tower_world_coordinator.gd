extends Node
class_name MpTowerWorldCoordinator

const _NetConstants := preload("res://scene/multiplayer/net_constants.gd")

const PLANT_HEALTH_FLUSH_INTERVAL_SECONDS := 0.05
# Each record carries 41 raw packed bytes before RPC/ENet framing. Twenty-four
# records stay below the multiplayer packet warning budget.
const PLANT_HEALTH_MAX_RECORDS_PER_PACKET := 24
const MULTIPLAYER_TEAM_PLANT_LIMIT := 256
const CLIENT_PENDING_PLANT_HEALTH_MAX_ENTRIES := MULTIPLAYER_TEAM_PLANT_LIMIT
const CLIENT_REMOVED_PLANT_TOMBSTONE_MAX_ENTRIES := MULTIPLAYER_TEAM_PLANT_LIMIT * 2
const PLANT_PLACEMENT_RATE_PER_SECOND := 4.0
const PLANT_PLACEMENT_RATE_BURST := 8.0
const PLANT_DESTRUCTION_RATE_PER_SECOND := 4.0
const PLANT_DESTRUCTION_RATE_BURST := 6.0
const PLANT_ID_WIRE_MAX_LENGTH := 128
const INVENTORY_ITEM_CONFIG_PATH_WIRE_MAX_LENGTH := 256
const TERRAIN_SNAPSHOT_CHUNK_MAX_CELLS := 96
const TERRAIN_SNAPSHOT_MAX_CHUNKS := 4096
const TERRAIN_DELTA_MAX_CELLS := 96
const TERRAIN_SNAPSHOT_REQUEST_RATE_PER_SECOND := 1.0
const TERRAIN_SNAPSHOT_REQUEST_RATE_BURST := 2.0
const TERRAIN_SNAPSHOT_REPAIR_WATCHDOG_SECONDS := 2.0
const TERRAIN_TYPE_EMPTY := -1
const TERRAIN_TYPE_GRASS := 1
const TERRAIN_TYPE_DIRT := 2
const AGAVE_CANNONBALL_SCENE_PATH := (
	"res://scene/plant_defense/agave_cannonball.tscn"
)
const BAMBOO_MORTAR_VISUAL_FLUSH_INTERVAL_SECONDS := 0.05
const CORN_MACHINE_GUN_BURST_FLUSH_INTERVAL_SECONDS := 0.05
const BAMBOO_MORTAR_VISUAL_MAX_RECORDS_PER_PACKET := 24
const CORN_MACHINE_GUN_BURST_MAX_RECORDS_PER_PACKET := 32

signal plant_placement_request_to_host(
	request_id: int,
	plant_id: String,
	anchor: Vector2i
)
signal inventory_plant_placement_request_to_host(
	request_id: int,
	plant_id: String,
	anchor: Vector2i,
	slot_index: int,
	expected_inventory_revision: int,
	item_config_path: String
)
signal nearest_plant_destruction_request_to_host(
	request_id: int,
	target_net_id: int
)
signal rpc_to_peer_requested(
	peer_id: int,
	method_name: StringName,
	args: Array
)
signal rpc_broadcast_requested(method_name: StringName, args: Array)
signal plant_health_batch_broadcast_requested(
	net_ids: PackedInt32Array,
	health_values: PackedInt32Array,
	maximum_values: PackedInt32Array,
	revisions: PackedInt32Array,
	damage_values: PackedInt32Array,
	healing_values: PackedInt32Array,
	directions: PackedVector2Array,
	damage_types: PackedByteArray,
	world_positions: PackedVector2Array
)
signal plant_damage_status_broadcast_requested(
	net_id: int,
	status_mask: int,
	status_revision: int
)
signal terrain_snapshot_request_to_host(known_revision: int)
signal base_health_send_requested(
	target_peer_id: int,
	current_health: int,
	maximum_health: int,
	revision: int
)
signal terrain_snapshot_chunk_send_requested(
	target_peer_id: int,
	snapshot_id: int,
	revision: int,
	chunk_index: int,
	chunk_count: int,
	cell_xy: PackedInt32Array,
	terrain_types: PackedInt32Array
)
signal terrain_delta_broadcast_requested(
	revision: int,
	cell_xy: PackedInt32Array,
	terrain_types: PackedInt32Array
)
signal test_arena_manual_night_send_requested(
	target_peer_id: int,
	enabled: bool
)
signal plant_projectile_visual_broadcast_requested(
	spawn_position: Vector2,
	direction: Vector2,
	speed: float,
	explosion_radius: float,
	lifetime: float
)
signal bamboo_mortar_visual_batch_broadcast_requested(
	plant_net_ids: PackedInt32Array,
	action_ids: PackedInt32Array,
	stages: PackedByteArray,
	spawn_positions: PackedVector2Array,
	landing_positions: PackedVector2Array,
	committed_windup_durations: PackedFloat32Array,
	host_action_times: PackedFloat64Array
)
signal hydrangea_rain_visual_broadcast_requested(
	plant_net_id: int,
	action_id: int,
	target_position: Vector2,
	host_action_time: float
)
signal corn_machine_gun_burst_batch_broadcast_requested(
	plant_net_ids: PackedInt32Array,
	action_ids: PackedInt32Array,
	shot_counts: PackedByteArray,
	directions: PackedVector2Array,
	host_action_times: PackedFloat64Array
)

var _session: MultiplayerGameplaySession = null
var _session_coordinator: MpSessionCoordinator = null
var _runtime: CombatRuntimeBase = null
var _mode_adapter: TowerDefenseMultiplayerModeAdapter = null
var _net_manager: NetManagerStore = null
var _transactions: MpTransactionsCoordinator = null
var _enemy_coordinator: MpEnemyCoordinator = null
var _tower_economy: MpTowerEconomyCoordinator = null

var _last_plant_placement_request_ids: Dictionary = {}
var _plant_placement_rate_buckets: Dictionary = {}
var _next_local_plant_destruction_request_id := 1
var _last_plant_destruction_request_ids: Dictionary = {}
var _plant_destruction_rate_buckets: Dictionary = {}
var _pending_plant_health_updates: Dictionary = {}
var _plant_health_flush_time_left := PLANT_HEALTH_FLUSH_INTERVAL_SECONDS

# CH5 spawn/removal and CH7 health feedback have independent delivery order.
# All three client-side maps are insertion-bounded to reject unbounded unknown ids.
var _pending_remote_plant_health_updates: Dictionary = {}
var _pending_remote_plant_health_order: Array[int] = []
var _removed_remote_plant_ids: Dictionary = {}
var _removed_remote_plant_id_order: Array[int] = []
var _remote_plant_feedback_revisions: Dictionary = {}
var _remote_plant_feedback_revision_order: Array[int] = []

var _terrain_snapshot_request_rate_buckets: Dictionary = {}
var _next_terrain_snapshot_id := 1
var _last_host_terrain_revision_broadcast := 0
var _client_terrain_revision := -1
var _client_has_terrain_snapshot := false
var _client_waiting_for_terrain_snapshot := false
var _terrain_snapshot_repair_watchdog_time_left := 0.0
var _last_completed_terrain_snapshot_id := 0
var _pending_terrain_snapshot_batches: Dictionary = {}
var _agave_cannonball_scene: PackedScene = null
var _pending_bamboo_mortar_visuals := PackedInt32Array()
var _pending_bamboo_mortar_action_ids := PackedInt32Array()
var _pending_bamboo_mortar_stages := PackedByteArray()
var _pending_bamboo_mortar_spawn_positions := PackedVector2Array()
var _pending_bamboo_mortar_landing_positions := PackedVector2Array()
var _pending_bamboo_mortar_windup_durations := PackedFloat32Array()
var _pending_bamboo_mortar_host_times := PackedFloat64Array()
var _bamboo_mortar_visual_flush_time_left := (
	BAMBOO_MORTAR_VISUAL_FLUSH_INTERVAL_SECONDS
)
var _pending_corn_machine_gun_burst_visuals := PackedInt32Array()
var _pending_corn_machine_gun_burst_action_ids := PackedInt32Array()
var _pending_corn_machine_gun_burst_shot_counts := PackedByteArray()
var _pending_corn_machine_gun_burst_directions := PackedVector2Array()
var _pending_corn_machine_gun_burst_host_times := PackedFloat64Array()
var _corn_machine_gun_burst_flush_time_left := (
	CORN_MACHINE_GUN_BURST_FLUSH_INTERVAL_SECONDS
)


func bind_session(
	session: MultiplayerGameplaySession,
	session_coordinator: MpSessionCoordinator,
	runtime: CombatRuntimeBase,
	mode_adapter: TowerDefenseMultiplayerModeAdapter,
	net_manager: NetManagerStore,
	transactions: MpTransactionsCoordinator,
	enemy_coordinator: MpEnemyCoordinator,
	tower_economy: MpTowerEconomyCoordinator
) -> void:
	assert(session != null, "MpTowerWorldCoordinator 缺少多人会话。")
	assert(session_coordinator != null, "MpTowerWorldCoordinator 缺少会话时钟。")
	assert(runtime != null, "MpTowerWorldCoordinator 缺少战斗运行时。")
	assert(mode_adapter != null, "MpTowerWorldCoordinator 缺少塔防模式适配器。")
	assert(net_manager != null, "MpTowerWorldCoordinator 缺少网络管理器。")
	assert(transactions != null, "MpTowerWorldCoordinator 缺少事务协调器。")
	assert(enemy_coordinator != null, "MpTowerWorldCoordinator 缺少敌人协调器。")
	assert(tower_economy != null, "MpTowerWorldCoordinator 缺少塔防经济协调器。")
	var initialize_terrain_state := (
		_session != session
		or _session_coordinator != session_coordinator
		or _runtime != runtime
		or _mode_adapter != mode_adapter
		or _net_manager != net_manager
		or _enemy_coordinator != enemy_coordinator
		or _tower_economy != tower_economy
	)
	if _session != null and _session != session:
		_disconnect_mode_adapter()
		reset_session_state()
	_session = session
	_session_coordinator = session_coordinator
	_runtime = runtime
	_mode_adapter = mode_adapter
	_net_manager = net_manager
	_transactions = transactions
	_enemy_coordinator = enemy_coordinator
	_tower_economy = tower_economy
	if initialize_terrain_state:
		_reset_terrain_session_state()
		_client_has_terrain_snapshot = (
			_net_manager.is_client()
			and not _mode_adapter.supports_terrain_state()
		)
	_connect_mode_adapter()


func unbind_session(session: MultiplayerGameplaySession) -> void:
	if _session != session:
		return
	_disconnect_mode_adapter()
	reset_session_state()
	_session = null
	_session_coordinator = null
	_runtime = null
	_mode_adapter = null
	_net_manager = null
	_transactions = null
	_enemy_coordinator = null
	_tower_economy = null


func is_bound() -> bool:
	return (
		_session != null
		and is_instance_valid(_session)
		and _session_coordinator != null
		and is_instance_valid(_session_coordinator)
		and _runtime != null
		and is_instance_valid(_runtime)
		and _mode_adapter != null
		and is_instance_valid(_mode_adapter)
		and _net_manager != null
		and is_instance_valid(_net_manager)
		and _transactions != null
		and is_instance_valid(_transactions)
		and _enemy_coordinator != null
		and is_instance_valid(_enemy_coordinator)
		and _tower_economy != null
		and is_instance_valid(_tower_economy)
	)


func reset_session_state() -> void:
	_last_plant_placement_request_ids.clear()
	_plant_placement_rate_buckets.clear()
	_next_local_plant_destruction_request_id = 1
	_last_plant_destruction_request_ids.clear()
	_plant_destruction_rate_buckets.clear()
	_pending_plant_health_updates.clear()
	_plant_health_flush_time_left = PLANT_HEALTH_FLUSH_INTERVAL_SECONDS
	_clear_remote_plant_health_state()
	_reset_terrain_session_state()
	_clear_plant_combat_network_state()


func clear_peer(peer_id: int) -> void:
	if peer_id <= 0:
		return
	_last_plant_placement_request_ids.erase(peer_id)
	_plant_placement_rate_buckets.erase(peer_id)
	_last_plant_destruction_request_ids.erase(peer_id)
	_plant_destruction_rate_buckets.erase(peer_id)
	_terrain_snapshot_request_rate_buckets.erase(peer_id)


func update_host(delta: float) -> void:
	if not is_bound() or not _net_manager.is_host():
		return
	var safe_delta := maxf(delta, 0.0)
	_bamboo_mortar_visual_flush_time_left -= safe_delta
	if _bamboo_mortar_visual_flush_time_left <= 0.0:
		_bamboo_mortar_visual_flush_time_left = (
			BAMBOO_MORTAR_VISUAL_FLUSH_INTERVAL_SECONDS
		)
		_flush_bamboo_mortar_visuals()
	_corn_machine_gun_burst_flush_time_left -= safe_delta
	if _corn_machine_gun_burst_flush_time_left <= 0.0:
		_corn_machine_gun_burst_flush_time_left = (
			CORN_MACHINE_GUN_BURST_FLUSH_INTERVAL_SECONDS
		)
		_flush_corn_machine_gun_burst_visuals()
	_plant_health_flush_time_left -= safe_delta
	if _plant_health_flush_time_left <= 0.0:
		_plant_health_flush_time_left = PLANT_HEALTH_FLUSH_INTERVAL_SECONDS
		_flush_plant_health_updates()


func update_client(delta: float) -> void:
	if not _is_client_bound():
		return
	_update_terrain_snapshot_repair_watchdog(delta)


func broadcast_plant_projectile_visual(
	_plant_net_id: int,
	spawn_position: Vector2,
	direction: Vector2,
	speed: float,
	explosion_radius: float,
	lifetime: float
) -> void:
	if (
		not _is_host_bound()
		or not spawn_position.is_finite()
		or not direction.is_finite()
		or direction.length_squared() <= 0.001
	):
		return
	plant_projectile_visual_broadcast_requested.emit(
		spawn_position,
		direction.normalized(),
		maxf(speed, 0.0),
		maxf(explosion_radius, 1.0),
		maxf(lifetime, 0.01)
	)


func queue_bamboo_mortar_visual(
	plant_net_id: int,
	action_id: int,
	stage: int,
	spawn_position: Vector2,
	landing_position: Vector2,
	committed_windup_duration_seconds: float,
	host_action_time: float
) -> void:
	if (
		not _is_host_bound()
		or not is_inside_tree()
		or plant_net_id <= 0
		or action_id <= 0
		or stage < 0
		or stage > 1
		or not spawn_position.is_finite()
		or not landing_position.is_finite()
		or not is_finite(committed_windup_duration_seconds)
		or committed_windup_duration_seconds
			< BambooMortar.MIN_COMMITTED_WINDUP_DURATION_SECONDS
		or committed_windup_duration_seconds
			> BambooMortar.WINDUP_DURATION_SECONDS
		or not is_finite(host_action_time)
		or host_action_time < 0.0
	):
		return
	var mortar := get_plant(plant_net_id) as BambooMortar
	if mortar == null or not is_instance_valid(mortar):
		return
	_pending_bamboo_mortar_visuals.append(plant_net_id)
	_pending_bamboo_mortar_action_ids.append(action_id)
	_pending_bamboo_mortar_stages.append(stage)
	_pending_bamboo_mortar_spawn_positions.append(spawn_position)
	_pending_bamboo_mortar_landing_positions.append(landing_position)
	_pending_bamboo_mortar_windup_durations.append(
		committed_windup_duration_seconds
	)
	_pending_bamboo_mortar_host_times.append(host_action_time)


func queue_hydrangea_rain_visual(
	plant_net_id: int,
	action_id: int,
	target_position: Vector2,
	action_elapsed_seconds: float,
	host_now: float
) -> void:
	if (
		not _is_host_bound()
		or not is_inside_tree()
		or plant_net_id <= 0
		or action_id <= 0
		or not target_position.is_finite()
		or not is_finite(action_elapsed_seconds)
		or action_elapsed_seconds < 0.0
		or not is_finite(host_now)
	):
		return
	var hydrangea := get_plant(plant_net_id) as HydrangeaRainTower
	if hydrangea == null or not is_instance_valid(hydrangea):
		return
	hydrangea_rain_visual_broadcast_requested.emit(
		plant_net_id,
		action_id,
		target_position,
		host_now - action_elapsed_seconds
	)


func queue_corn_machine_gun_burst_visual(
	plant_net_id: int,
	action_id: int,
	direction: Vector2,
	shot_count: int,
	host_action_time: float
) -> void:
	if (
		not _is_host_bound()
		or not is_inside_tree()
		or plant_net_id <= 0
		or action_id <= 0
		or not direction.is_finite()
		or direction.length_squared() <= 0.001
		or shot_count <= 0
		or shot_count > _NetConstants.CORN_MACHINE_GUN_BURST_SHOT_COUNT_MAX
		or not is_finite(host_action_time)
		or host_action_time < 0.0
	):
		return
	var corn := get_plant(plant_net_id) as CornMachineGun
	if corn == null or not is_instance_valid(corn):
		return
	_pending_corn_machine_gun_burst_visuals.append(plant_net_id)
	_pending_corn_machine_gun_burst_action_ids.append(action_id)
	_pending_corn_machine_gun_burst_shot_counts.append(shot_count)
	_pending_corn_machine_gun_burst_directions.append(direction.normalized())
	_pending_corn_machine_gun_burst_host_times.append(host_action_time)


func apply_authoritative_plant_enemy_damage(
	damage_source_id: int,
	enemy: Enemy,
	damage: int,
	impact_direction: Vector2,
	damage_type: EnemyConfig.DamageType
) -> bool:
	if not _is_host_bound() or enemy == null or damage <= 0:
		return false
	var safe_direction := (
		impact_direction if impact_direction.is_finite() else Vector2.ZERO
	)
	var request := DamageRequest.new(damage, int(damage_type))
	request.with_source_snapshot(_create_plant_damage_source_snapshot(
		damage_source_id,
		&"plant_attack"
	))
	request.with_directions(safe_direction)
	return _apply_authoritative_plant_damage_request(
		enemy,
		request,
		safe_direction,
		damage_type
	)


func apply_authoritative_plant_enemy_damage_batch(
	damage_source_id: int,
	enemy: Enemy,
	damage_amounts: PackedInt64Array,
	hit_counts: PackedInt32Array,
	impact_direction: Vector2,
	damage_type: EnemyConfig.DamageType
) -> bool:
	if (
		not _is_host_bound()
		or enemy == null
		or damage_amounts.is_empty()
	):
		return false
	var safe_direction := (
		impact_direction if impact_direction.is_finite() else Vector2.ZERO
	)
	var request := DamageBatchRequest.new(
		damage_amounts,
		hit_counts,
		int(damage_type)
	)
	request.with_source_snapshot(_create_plant_damage_source_snapshot(
		damage_source_id,
		&"plant_damage_batch"
	))
	request.with_directions(safe_direction)
	return _apply_authoritative_plant_damage_request(
		enemy,
		request,
		safe_direction,
		damage_type
	)


func request_bamboo_mortar_target(
	owner: Node2D,
	minimum_range: float,
	maximum_range: float,
	callback: Callable
) -> bool:
	if not _is_host_bound():
		return false
	return _mode_adapter.request_runtime_bamboo_mortar_target(
		owner,
		minimum_range,
		maximum_range,
		callback
	)


func cancel_bamboo_mortar_target_request(owner: Node) -> void:
	if not is_bound():
		return
	_mode_adapter.cancel_runtime_bamboo_mortar_target_request(owner)


func select_bamboo_mortar_target_sync_for_fixture(
	center: Vector2,
	minimum_range: float,
	maximum_range: float
) -> Enemy:
	if not _is_host_bound():
		return null
	return _mode_adapter.select_runtime_bamboo_mortar_target_sync_for_fixture(
		center,
		minimum_range,
		maximum_range
	)


func queue_bamboo_mortar_explosion(
	landing_position: Vector2,
	inner_radius: float,
	outer_radius: float,
	inner_damage: int,
	outer_damage: int,
	damage_source_id: int
) -> bool:
	if not _is_host_bound():
		return false
	return _mode_adapter.queue_runtime_bamboo_mortar_explosion(
		landing_position,
		inner_radius,
		outer_radius,
		inner_damage,
		outer_damage,
		damage_source_id
	)


func get_bamboo_mortar_combat_metrics() -> Dictionary:
	if not is_bound():
		return {}
	return _mode_adapter.get_runtime_bamboo_mortar_combat_metrics()


func receive_plant_projectile_visual(
	spawn_position: Vector2,
	direction: Vector2,
	speed: float,
	explosion_radius: float,
	lifetime: float
) -> void:
	if (
		not _is_client_bound()
		or not spawn_position.is_finite()
		or not direction.is_finite()
		or direction.length_squared() <= 0.001
	):
		return
	if _agave_cannonball_scene == null:
		_agave_cannonball_scene = load(
			AGAVE_CANNONBALL_SCENE_PATH
		) as PackedScene
	if _agave_cannonball_scene == null:
		return
	var projectile := _acquire_or_instantiate_projectile(
		_agave_cannonball_scene
	) as AgaveCannonball
	if projectile == null:
		return
	projectile.top_level = true
	if projectile.get_parent() == null:
		_session.add_child(projectile)
	projectile.global_position = spawn_position
	projectile.setup(
		direction.normalized(),
		0,
		maxf(speed, 0.0),
		maxf(explosion_radius, 1.0),
		maxf(lifetime, 0.01),
		false,
		0
	)
	projectile.reset_physics_interpolation()


func receive_bamboo_mortar_visual_batch(
	plant_net_ids: PackedInt32Array,
	action_ids: PackedInt32Array,
	stages: PackedByteArray,
	spawn_positions: PackedVector2Array,
	landing_positions: PackedVector2Array,
	committed_windup_durations: PackedFloat32Array,
	host_action_times: PackedFloat64Array,
	local_net_time: float,
	has_host_time_offset: bool,
	host_to_client_time_offset: float
) -> void:
	if (
		not _is_client_bound()
		or not _is_valid_bamboo_mortar_visual_payload(
			plant_net_ids,
			action_ids,
			stages,
			spawn_positions,
			landing_positions,
			committed_windup_durations,
			host_action_times
		)
	):
		return
	for record_index in range(plant_net_ids.size()):
		var mortar := get_plant(plant_net_ids[record_index]) as BambooMortar
		if mortar == null or not is_instance_valid(mortar):
			continue
		var elapsed := _get_remote_action_elapsed(
			host_action_times[record_index],
			local_net_time,
			has_host_time_offset,
			host_to_client_time_offset
		)
		if not is_finite(elapsed):
			continue
		mortar.play_multiplayer_action(
			int(stages[record_index]),
			action_ids[record_index],
			spawn_positions[record_index],
			landing_positions[record_index],
			elapsed,
			committed_windup_durations[record_index]
		)


func receive_hydrangea_rain_visual(
	plant_net_id: int,
	action_id: int,
	target_position: Vector2,
	host_action_time: float,
	local_net_time: float,
	has_host_time_offset: bool,
	host_to_client_time_offset: float
) -> void:
	if (
		not _is_client_bound()
		or plant_net_id <= 0
		or action_id <= 0
		or not target_position.is_finite()
		or not is_finite(host_action_time)
	):
		return
	var hydrangea := get_plant(plant_net_id) as HydrangeaRainTower
	if hydrangea == null or not is_instance_valid(hydrangea):
		return
	var elapsed := _get_remote_action_elapsed(
		host_action_time,
		local_net_time,
		has_host_time_offset,
		host_to_client_time_offset
	)
	if not is_finite(elapsed):
		return
	hydrangea.play_multiplayer_rain_action(
		action_id,
		target_position,
		elapsed
	)


func receive_corn_machine_gun_burst_batch(
	plant_net_ids: PackedInt32Array,
	action_ids: PackedInt32Array,
	shot_counts: PackedByteArray,
	directions: PackedVector2Array,
	host_action_times: PackedFloat64Array,
	local_net_time: float,
	has_host_time_offset: bool,
	host_to_client_time_offset: float
) -> void:
	if (
		not _is_client_bound()
		or not _is_valid_corn_machine_gun_burst_payload(
			plant_net_ids,
			action_ids,
			shot_counts,
			directions,
			host_action_times
		)
	):
		return
	for record_index in range(plant_net_ids.size()):
		var corn := get_plant(plant_net_ids[record_index]) as CornMachineGun
		if corn == null or not is_instance_valid(corn):
			continue
		var elapsed := _get_remote_action_elapsed(
			host_action_times[record_index],
			local_net_time,
			has_host_time_offset,
			host_to_client_time_offset
		)
		if not is_finite(elapsed):
			continue
		corn.play_multiplayer_burst(
			directions[record_index].normalized(),
			action_ids[record_index],
			elapsed,
			shot_counts[record_index]
		)


func begin_runtime_state_request() -> void:
	if not _is_client_bound() or not _mode_adapter.supports_terrain_state():
		return
	_client_waiting_for_terrain_snapshot = true
	_arm_terrain_snapshot_repair_watchdog()


func broadcast_base_health_snapshot() -> void:
	if not _is_host_bound():
		return
	var snapshot := _mode_adapter.get_base_health_snapshot()
	if snapshot.is_empty():
		return
	_on_host_base_health_changed(
		int(snapshot.get("current_health", 0)),
		int(snapshot.get("maximum_health", 1)),
		int(snapshot.get("revision", 0))
	)


func request_base_health_snapshot_for_peer(target_peer_id: int) -> void:
	if not _is_host_bound() or target_peer_id <= 0:
		return
	var snapshot := _mode_adapter.get_base_health_snapshot()
	if snapshot.is_empty():
		return
	base_health_send_requested.emit(
		target_peer_id,
		int(snapshot.get("current_health", 0)),
		int(snapshot.get("maximum_health", 1)),
		int(snapshot.get("revision", 0))
	)


func request_test_arena_manual_night_for_peer(target_peer_id: int) -> void:
	if (
		not _is_host_bound()
		or target_peer_id <= 0
		or not _mode_adapter.supports_test_arena_manual_night_sync()
	):
		return
	test_arena_manual_night_send_requested.emit(
		target_peer_id,
		_mode_adapter.get_test_arena_manual_night_enabled()
	)


func request_terrain_snapshot_for_peer(target_peer_id: int) -> void:
	if (
		not _is_host_bound()
		or target_peer_id <= 0
		or not _mode_adapter.supports_terrain_state()
	):
		return
	var snapshot := _mode_adapter.get_terrain_snapshot()
	var revision := int(snapshot.get("revision", -1))
	var cell_xy: PackedInt32Array = snapshot.get(
		"cell_xy",
		PackedInt32Array()
	)
	var terrain_types: PackedInt32Array = snapshot.get(
		"terrain_types",
		PackedInt32Array()
	)
	if (
		revision < 0
		or not _is_valid_terrain_payload(
			cell_xy,
			terrain_types,
			TERRAIN_SNAPSHOT_CHUNK_MAX_CELLS * TERRAIN_SNAPSHOT_MAX_CHUNKS
		)
	):
		push_error("MpTowerWorldCoordinator: authoritative terrain snapshot is invalid.")
		return
	var snapshot_id := _next_terrain_snapshot_id
	_next_terrain_snapshot_id += 1
	var cell_count := terrain_types.size()
	var chunk_count := maxi(
		ceili(float(cell_count) / float(TERRAIN_SNAPSHOT_CHUNK_MAX_CELLS)),
		1
	)
	for chunk_index in range(chunk_count):
		var start_cell := chunk_index * TERRAIN_SNAPSHOT_CHUNK_MAX_CELLS
		var end_cell := mini(
			start_cell + TERRAIN_SNAPSHOT_CHUNK_MAX_CELLS,
			cell_count
		)
		var chunk_cell_xy := PackedInt32Array()
		var chunk_terrain_types := PackedInt32Array()
		for cell_index in range(start_cell, end_cell):
			chunk_cell_xy.append(cell_xy[cell_index * 2])
			chunk_cell_xy.append(cell_xy[cell_index * 2 + 1])
			chunk_terrain_types.append(terrain_types[cell_index])
		terrain_snapshot_chunk_send_requested.emit(
			target_peer_id,
			snapshot_id,
			revision,
			chunk_index,
			chunk_count,
			chunk_cell_xy,
			chunk_terrain_types
		)


func handle_remote_terrain_snapshot_request(
	sender_id: int,
	known_revision: int
) -> void:
	if (
		not _is_host_bound()
		or not _mode_adapter.supports_terrain_state()
		or known_revision < -1
		or sender_id <= 0
		or _runtime.get_player_for_peer(sender_id) == null
	):
		return
	if not _consume_terrain_snapshot_request_token(sender_id):
		return
	request_terrain_snapshot_for_peer(sender_id)


func receive_terrain_snapshot_chunk(
	snapshot_id: int,
	revision: int,
	chunk_index: int,
	chunk_count: int,
	cell_xy: PackedInt32Array,
	terrain_types: PackedInt32Array
) -> void:
	if not _is_client_terrain_bound():
		return
	if snapshot_id <= _last_completed_terrain_snapshot_id:
		return
	if (
		snapshot_id <= 0
		or revision < 0
		or chunk_count <= 0
		or chunk_count > TERRAIN_SNAPSHOT_MAX_CHUNKS
		or chunk_index < 0
		or chunk_index >= chunk_count
		or not _is_valid_terrain_payload(
			cell_xy,
			terrain_types,
			TERRAIN_SNAPSHOT_CHUNK_MAX_CELLS
		)
		or (
			chunk_index < chunk_count - 1
			and terrain_types.size() != TERRAIN_SNAPSHOT_CHUNK_MAX_CELLS
		)
		or (
			terrain_types.is_empty()
			and (chunk_count != 1 or chunk_index != 0)
		)
	):
		_restart_terrain_snapshot_repair()
		return
	_arm_terrain_snapshot_repair_watchdog()

	var batch := _pending_terrain_snapshot_batches.get(
		snapshot_id,
		{}
	) as Dictionary
	if batch.is_empty():
		batch = {
			"revision": revision,
			"chunk_count": chunk_count,
			"chunks": {},
		}
		_pending_terrain_snapshot_batches[snapshot_id] = batch
	elif (
		int(batch.get("revision", -1)) != revision
		or int(batch.get("chunk_count", 0)) != chunk_count
	):
		_restart_terrain_snapshot_repair()
		return

	var chunks := batch.get("chunks", {}) as Dictionary
	if chunks.has(chunk_index):
		var previous := chunks[chunk_index] as Dictionary
		if (
			(previous.get("cell_xy", PackedInt32Array()) as PackedInt32Array)
			== cell_xy
			and (
				previous.get("terrain_types", PackedInt32Array())
				as PackedInt32Array
			) == terrain_types
		):
			return
		_restart_terrain_snapshot_repair()
		return
	chunks[chunk_index] = {
		"cell_xy": cell_xy.duplicate(),
		"terrain_types": terrain_types.duplicate(),
	}
	if chunks.size() < chunk_count:
		return

	var complete_cell_xy := PackedInt32Array()
	var complete_terrain_types := PackedInt32Array()
	for ordered_chunk_index in range(chunk_count):
		if not chunks.has(ordered_chunk_index):
			_restart_terrain_snapshot_repair()
			return
		var chunk := chunks[ordered_chunk_index] as Dictionary
		var ordered_cell_xy: PackedInt32Array = chunk.get(
			"cell_xy",
			PackedInt32Array()
		)
		var ordered_terrain_types: PackedInt32Array = chunk.get(
			"terrain_types",
			PackedInt32Array()
		)
		complete_cell_xy.append_array(ordered_cell_xy)
		complete_terrain_types.append_array(ordered_terrain_types)
	if not _is_valid_terrain_payload(
		complete_cell_xy,
		complete_terrain_types
	):
		_restart_terrain_snapshot_repair()
		return
	if _client_has_terrain_snapshot and revision < _client_terrain_revision:
		_pending_terrain_snapshot_batches.erase(snapshot_id)
		_client_waiting_for_terrain_snapshot = false
		_terrain_snapshot_repair_watchdog_time_left = 0.0
		return
	if not _mode_adapter.apply_remote_terrain_snapshot(
		revision,
		complete_cell_xy,
		complete_terrain_types
	):
		_restart_terrain_snapshot_repair()
		return
	_client_terrain_revision = revision
	_client_has_terrain_snapshot = true
	_client_waiting_for_terrain_snapshot = false
	_terrain_snapshot_repair_watchdog_time_left = 0.0
	_last_completed_terrain_snapshot_id = snapshot_id
	for pending_id_variant in _pending_terrain_snapshot_batches.keys():
		if int(pending_id_variant) <= snapshot_id:
			_pending_terrain_snapshot_batches.erase(pending_id_variant)


func receive_terrain_delta(
	revision: int,
	cell_xy: PackedInt32Array,
	terrain_types: PackedInt32Array
) -> void:
	if not _is_client_terrain_bound():
		return
	if (
		revision <= 0
		or terrain_types.is_empty()
		or not _is_valid_terrain_payload(
			cell_xy,
			terrain_types,
			TERRAIN_DELTA_MAX_CELLS
		)
	):
		_restart_terrain_snapshot_repair()
		return
	if _client_has_terrain_snapshot and revision <= _client_terrain_revision:
		return
	if not _client_has_terrain_snapshot or _client_waiting_for_terrain_snapshot:
		_request_terrain_snapshot_repair()
		return
	if revision != _client_terrain_revision + 1:
		_request_terrain_snapshot_repair()
		return
	if not _mode_adapter.apply_remote_terrain_delta(
		revision,
		cell_xy,
		terrain_types
	):
		_request_terrain_snapshot_repair()
		return
	_client_terrain_revision = revision


func receive_base_health_changed(
	current_health: int,
	maximum_health: int,
	revision: int
) -> void:
	if (
		not _is_client_bound()
		or not _NetConstants.is_valid_network_combat_value(current_health)
		or not _NetConstants.is_valid_network_combat_value(maximum_health)
		or not _NetConstants.is_valid_network_combat_value(revision)
	):
		return
	_mode_adapter.apply_remote_base_health(
		current_health,
		maximum_health,
		revision
	)


func receive_test_arena_manual_night_changed(
	sender_id: int,
	enabled: bool
) -> void:
	if (
		not _is_client_bound()
		or sender_id != _net_manager.get_host_peer_id()
		or not _mode_adapter.supports_test_arena_manual_night_sync()
	):
		return
	_mode_adapter.apply_remote_test_arena_manual_night(enabled)


func _on_host_base_health_changed(
	current_health: int,
	maximum_health: int,
	revision: int
) -> void:
	if not _is_host_bound():
		return
	if (
		not _NetConstants.is_valid_network_combat_value(current_health)
		or not _NetConstants.is_valid_network_combat_value(maximum_health)
		or not _NetConstants.is_valid_network_combat_value(revision)
	):
		push_error("MpTowerWorldCoordinator: 基地生命快照超出 signed int32 契约。")
		return
	base_health_send_requested.emit(
		0,
		current_health,
		maximum_health,
		revision
	)


func _on_host_test_arena_manual_night_changed(enabled: bool) -> void:
	if (
		not _is_host_bound()
		or not _mode_adapter.supports_test_arena_manual_night_sync()
	):
		return
	test_arena_manual_night_send_requested.emit(0, enabled)


func _on_host_terrain_delta(
	revision: int,
	cell_xy: PackedInt32Array,
	terrain_types: PackedInt32Array
) -> void:
	if (
		not _is_host_bound()
		or revision <= _last_host_terrain_revision_broadcast
		or terrain_types.is_empty()
		or not _is_valid_terrain_payload(
			cell_xy,
			terrain_types,
			TERRAIN_DELTA_MAX_CELLS
		)
	):
		return
	_last_host_terrain_revision_broadcast = revision
	terrain_delta_broadcast_requested.emit(
		revision,
		cell_xy,
		terrain_types
	)


func handle_remote_plant_placement_request(
	sender_id: int,
	request_id: int,
	plant_id: String,
	anchor: Vector2i
) -> void:
	_handle_authoritative_plant_placement_request(
		sender_id,
		request_id,
		plant_id,
		anchor
	)


func handle_remote_inventory_plant_placement_request(
	sender_id: int,
	request_id: int,
	plant_id: String,
	anchor: Vector2i,
	slot_index: int,
	expected_inventory_revision: int,
	item_config_path: String
) -> void:
	_handle_authoritative_inventory_plant_placement_request(
		sender_id,
		request_id,
		plant_id,
		anchor,
		slot_index,
		expected_inventory_revision,
		item_config_path
	)


func build_live_plant_records() -> Array[Dictionary]:
	if not is_bound():
		return []
	var records: Array[Dictionary] = []
	for snapshot in _mode_adapter.get_multiplayer_plant_snapshots():
		var net_id := int(snapshot.get("net_id", 0))
		if net_id <= 0:
			continue
		records.append(snapshot.duplicate(true))
	records.sort_custom(
		func(a: Dictionary, b: Dictionary) -> bool:
			return int(a.get("net_id", 0)) < int(b.get("net_id", 0))
	)
	return records


func build_live_plant_ids() -> PackedInt32Array:
	var live_ids := PackedInt32Array()
	for record in build_live_plant_records():
		live_ids.append(int(record.get("net_id", 0)))
	return live_ids


func send_live_plant_roster_to_peer(peer_id: int) -> void:
	if (
		not _is_host_bound()
		or peer_id <= 0
		or not _net_manager.is_peer_send_ready(peer_id)
	):
		return
	var warehouse_snapshots_by_net_id: Dictionary = {}
	for plant_snapshot in build_live_plant_records():
		var plant_net_id := int(plant_snapshot.get("net_id", 0))
		var plant := get_plant(plant_net_id)
		_tower_economy.configure_warehouse_network(plant, true)
		_tower_economy.configure_production_network(plant, true)
		_tower_economy.configure_research_network(plant)
		var runtime_state := export_plant_runtime_state(plant)
		var host_sample_time := _session_coordinator.get_net_time()
		rpc_to_peer_requested.emit(
			peer_id,
			&"net_plant_spawned",
			[
				0,
				int(plant_snapshot.get("owner_peer_id", 0)),
				plant_net_id,
				String(plant_snapshot.get("plant_id", &"")),
				plant_snapshot.get("anchor", Vector2i.ZERO) as Vector2i,
				int(plant_snapshot.get("current_health", 0)),
				int(plant_snapshot.get("maximum_health", 1)),
				int(plant_snapshot.get("health_revision", 0)),
				runtime_state,
				host_sample_time,
			]
		)
		var warehouse := plant as OakWarehouse
		if warehouse != null and is_instance_valid(warehouse):
			warehouse_snapshots_by_net_id[plant_net_id] = (
				warehouse.export_storage_snapshot()
			)
	var warehouse_ids := warehouse_snapshots_by_net_id.keys()
	warehouse_ids.sort()
	if not warehouse_ids.is_empty():
		var warehouse_net_ids := PackedInt32Array()
		var warehouse_snapshots: Array = []
		for warehouse_id_variant in warehouse_ids:
			var warehouse_net_id := int(warehouse_id_variant)
			warehouse_net_ids.append(warehouse_net_id)
			warehouse_snapshots.append(
				warehouse_snapshots_by_net_id[warehouse_net_id]
			)
		rpc_to_peer_requested.emit(
			peer_id,
			&"net_warehouse_storage_snapshot_batch",
			[warehouse_net_ids, warehouse_snapshots]
		)
	rpc_to_peer_requested.emit(
		peer_id,
		&"net_research_state_updated",
		[_mode_adapter.get_research_runtime_state(), 0, -1]
	)


func get_plant(net_id: int) -> PlantDefense:
	if not is_bound() or net_id <= 0:
		return null
	return _mode_adapter.get_multiplayer_plant_node(net_id)


func is_remote_plant_removed(net_id: int) -> bool:
	return net_id > 0 and _removed_remote_plant_ids.has(net_id)


func find_live_plant_ids_missing_from_manifest(
	plant_id_set: Dictionary
) -> PackedInt32Array:
	var removed_ids := PackedInt32Array()
	if not is_bound() or _net_manager.is_host():
		return removed_ids
	for plant_snapshot in build_live_plant_records():
		var plant_net_id := int(plant_snapshot.get("net_id", 0))
		if plant_net_id > 0 and not plant_id_set.has(plant_net_id):
			removed_ids.append(plant_net_id)
	return removed_ids


func reconcile_runtime_manifest(
	plant_id_set: Dictionary,
	positive_plant_ids: PackedInt32Array,
	removed_ids: PackedInt32Array
) -> void:
	if not is_bound() or _net_manager.is_host():
		return
	for net_id in positive_plant_ids:
		_clear_remote_plant_removed_marker(net_id)
	for plant_net_id in removed_ids:
		if plant_net_id > 0 and not plant_id_set.has(plant_net_id):
			_mark_remote_plant_removed(plant_net_id)
			_mode_adapter.apply_remote_plant_removed(plant_net_id, false, true)
	for plant_snapshot in build_live_plant_records():
		var plant_net_id := int(plant_snapshot.get("net_id", 0))
		if plant_net_id > 0 and plant_id_set.has(plant_net_id):
			apply_pending_remote_plant_health(plant_net_id)


func receive_plant_spawn(
	request_id: int,
	owner_peer_id: int,
	net_id: int,
	plant_id: String,
	anchor: Vector2i,
	current_health: int,
	maximum_health: int,
	health_revision: int,
	runtime_state: Dictionary,
	host_sample_time: float
) -> PlantDefense:
	if (
		not _is_client_bound()
		or net_id <= 0
		or not _NetConstants.is_valid_network_combat_value(current_health)
		or not _NetConstants.is_valid_network_combat_value(maximum_health)
		or not _NetConstants.is_valid_network_combat_value(health_revision)
	):
		return null
	_clear_remote_plant_removed_marker(net_id)
	_mode_adapter.apply_remote_plant_spawn(
		request_id,
		owner_peer_id,
		net_id,
		StringName(plant_id),
		anchor,
		current_health,
		maximum_health,
		health_revision
	)
	var plant := get_plant(net_id)
	if plant == null or not is_instance_valid(plant):
		return null
	_tower_economy.notify_plant_available(net_id)
	_tower_economy.configure_production_network(plant, false)
	_tower_economy.configure_research_network(plant)
	apply_plant_runtime_state(plant, runtime_state, host_sample_time)
	var production_building := plant as ProductionBuilding
	if (
		production_building != null
		and not production_building.multiplayer_production_snapshot_ready
	):
		production_building.request_multiplayer_production_snapshot()
	_tower_economy.configure_warehouse_network(plant, false)
	apply_pending_remote_plant_health(net_id)
	return plant


func export_plant_runtime_state(plant: PlantDefense) -> Dictionary:
	if plant == null or not is_instance_valid(plant):
		return {}
	var runtime_state := plant.export_multiplayer_runtime_state().duplicate(true)
	runtime_state["damage_status_mask"] = plant.get_damage_status_mask()
	runtime_state["damage_status_revision"] = plant.damage_status_revision
	return runtime_state


func apply_plant_runtime_state(
	plant: PlantDefense,
	runtime_state: Dictionary,
	host_sample_time: float
) -> void:
	if plant == null or not is_instance_valid(plant) or not is_finite(host_sample_time):
		return
	var corrected_state := runtime_state.duplicate(true)
	if (
		corrected_state.has("damage_status_mask")
		and corrected_state.has("damage_status_revision")
	):
		plant.apply_remote_damage_status_mask(
			int(corrected_state.get("damage_status_mask", 0)),
			int(corrected_state.get("damage_status_revision", 0))
		)
	var mapped_sample_time := (
		_session_coordinator.map_host_timestamp_to_client_time(
			host_sample_time,
			false
		)
	)
	var sample_age := maxf(
		_session_coordinator.get_net_time() - mapped_sample_time,
		0.0
	)
	if corrected_state.has("spread_elapsed_seconds"):
		var spread_elapsed := float(
			corrected_state.get("spread_elapsed_seconds", 0.0)
		)
		var spread_speed_multiplier := float(
			corrected_state.get("spread_speed_multiplier", 0.0)
		)
		if (
			not is_finite(spread_elapsed)
			or not is_finite(spread_speed_multiplier)
			or spread_speed_multiplier
			< VegetationStake.MIN_SPREAD_SPEED_MULTIPLIER
		):
			return
		corrected_state["spread_elapsed_seconds"] = (
			maxf(spread_elapsed, 0.0)
				+ sample_age * spread_speed_multiplier
		)
	for elapsed_key in [
		"windup_elapsed_seconds",
		"projectile_elapsed_seconds",
		"cycle_elapsed_seconds",
		"rain_elapsed_seconds",
		"ground_effect_elapsed_seconds",
	]:
		if not corrected_state.has(elapsed_key):
			continue
		var elapsed_seconds := float(corrected_state.get(elapsed_key, 0.0))
		if not is_finite(elapsed_seconds):
			return
		corrected_state[elapsed_key] = maxf(elapsed_seconds, 0.0) + sample_age
	var production_building := plant as ProductionBuilding
	if production_building != null:
		production_building.apply_multiplayer_runtime_state_with_host_sample(
			corrected_state,
			GameplayPause.get_gameplay_time_seconds() - sample_age,
			host_sample_time
		)
	else:
		plant.apply_multiplayer_runtime_state(
			corrected_state,
			GameplayPause.get_gameplay_time_seconds()
		)


func receive_plant_placement_rejected(request_id: int, reason: String) -> void:
	if not _is_client_bound():
		return
	_mode_adapter.apply_remote_plant_placement_rejected(
		request_id,
		StringName(reason)
	)


func receive_plant_health_changed(
	net_id: int,
	current_health: int,
	maximum_health: int,
	health_revision: int
) -> void:
	if (
		not _is_client_bound()
		or net_id <= 0
		or not _NetConstants.is_valid_network_combat_value(current_health)
		or not _NetConstants.is_valid_network_combat_value(maximum_health)
		or not _NetConstants.is_valid_network_combat_value(health_revision)
	):
		return
	_apply_or_defer_remote_plant_health(
		net_id,
		current_health,
		maximum_health,
		health_revision
	)


func receive_plant_health_batch(
	net_ids: PackedInt32Array,
	health_values: PackedInt32Array,
	maximum_values: PackedInt32Array,
	revisions: PackedInt32Array,
	damage_values: PackedInt32Array,
	healing_values: PackedInt32Array,
	directions: PackedVector2Array,
	damage_types: PackedByteArray,
	world_positions: PackedVector2Array
) -> void:
	if not _is_client_bound():
		return
	var record_count := mini(
		net_ids.size(),
		mini(
			health_values.size(),
			mini(
				maximum_values.size(),
				mini(
					revisions.size(),
					mini(
						damage_values.size(),
						mini(
							healing_values.size(),
							mini(
								directions.size(),
								mini(damage_types.size(), world_positions.size())
							)
						)
					)
				)
			)
		)
	)
	for record_index in range(record_count):
		var net_id := net_ids[record_index]
		var health_revision := revisions[record_index]
		if (
			net_id <= 0
			or not _NetConstants.is_valid_network_combat_value(health_values[record_index])
			or not _NetConstants.is_valid_network_combat_value(maximum_values[record_index])
			or not _NetConstants.is_valid_network_combat_value(health_revision)
			or not _NetConstants.is_valid_network_combat_value(damage_values[record_index])
			or not _NetConstants.is_valid_network_combat_value(healing_values[record_index])
		):
			continue
		var live_plant_before := get_plant(net_id)
		var stale_for_live_plant := (
			live_plant_before != null
			and is_instance_valid(live_plant_before)
			and health_revision <= live_plant_before.health_revision
		)
		_apply_or_defer_remote_plant_health(
			net_id,
			health_values[record_index],
			maximum_values[record_index],
			health_revision
		)
		var applied_damage := damage_values[record_index]
		var applied_healing := healing_values[record_index]
		if applied_damage <= 0 and applied_healing <= 0:
			continue
		if not _accept_remote_plant_feedback_revision(net_id, health_revision):
			continue
		if stale_for_live_plant:
			continue
		if applied_damage > 0:
			_runtime.show_combat_number(
				applied_damage,
				world_positions[record_index],
				DamageNumberPool.CombatNumberKind.DAMAGE,
				directions[record_index],
				int(damage_types[record_index]) as EnemyConfig.DamageType,
				DamageNumberPool.DisplayPriority.IMPORTANT
			)
		if applied_healing > 0:
			_runtime.show_combat_number(
				applied_healing,
				world_positions[record_index],
				DamageNumberPool.CombatNumberKind.HEALING,
				Vector2.ZERO,
				EnemyConfig.DamageType.PHYSICAL,
				DamageNumberPool.DisplayPriority.IMPORTANT
			)


func receive_plant_damage_status_changed(
	net_id: int,
	status_mask: int,
	status_revision: int
) -> void:
	if not _is_client_bound() or net_id <= 0:
		return
	var plant := get_plant(net_id)
	if plant == null or not is_instance_valid(plant):
		return
	plant.apply_remote_damage_status_mask(status_mask, status_revision)


func receive_plant_removed(net_id: int, was_destroyed: bool = false) -> void:
	if not is_bound() or _net_manager.is_host():
		return
	_tower_economy.notify_plant_removed(net_id)
	if net_id > 0:
		_mark_remote_plant_removed(net_id)
		_mode_adapter.apply_remote_plant_removed(net_id, was_destroyed)
	_tower_economy.try_apply_pending_warehouse_snapshots_atomically()


func apply_pending_remote_plant_health(net_id: int) -> void:
	if not _is_client_bound():
		return
	var pending := _pending_remote_plant_health_updates.get(net_id, {}) as Dictionary
	if pending.is_empty():
		return
	var plant := get_plant(net_id)
	if plant == null or not is_instance_valid(plant):
		return
	_erase_pending_remote_plant_health(net_id)
	_mode_adapter.apply_remote_plant_health(
		net_id,
		int(pending.get("current_health", 0)),
		int(pending.get("maximum_health", 1)),
		int(pending.get("health_revision", -1))
	)


func _on_local_plant_placement_requested(
	request_id: int,
	plant_id: StringName,
	anchor: Vector2i
) -> void:
	if not is_bound():
		return
	if _net_manager.is_host():
		_handle_authoritative_plant_placement_request(
			_net_manager.get_local_peer_id(),
			request_id,
			String(plant_id),
			anchor
		)
	elif _net_manager.is_client():
		plant_placement_request_to_host.emit(request_id, String(plant_id), anchor)


func _on_local_inventory_plant_placement_requested(
	request_id: int,
	plant_id: StringName,
	anchor: Vector2i,
	slot_index: int,
	expected_inventory_revision: int,
	item_config_path: String
) -> void:
	if not is_bound():
		return
	if _net_manager.is_host():
		_handle_authoritative_inventory_plant_placement_request(
			_net_manager.get_local_peer_id(),
			request_id,
			String(plant_id),
			anchor,
			slot_index,
			expected_inventory_revision,
			item_config_path
		)
	elif _net_manager.is_client():
		inventory_plant_placement_request_to_host.emit(
			request_id,
			String(plant_id),
			anchor,
			slot_index,
			expected_inventory_revision,
			item_config_path
		)


func _on_local_nearest_plant_destruction_requested(target_net_id: int) -> void:
	if not is_bound() or target_net_id <= 0:
		return
	var request_id := _next_local_plant_destruction_request_id
	_next_local_plant_destruction_request_id += 1
	if _net_manager.is_host():
		_handle_authoritative_nearest_plant_destruction_request(
			_net_manager.get_local_peer_id(),
			request_id,
			target_net_id
		)
	elif _net_manager.is_client():
		nearest_plant_destruction_request_to_host.emit(
			request_id,
			target_net_id
		)


func handle_remote_nearest_plant_destruction_request(
	requester_peer_id: int,
	request_id: int,
	target_net_id: int
) -> void:
	_handle_authoritative_nearest_plant_destruction_request(
		requester_peer_id,
		request_id,
		target_net_id
	)


func _handle_authoritative_nearest_plant_destruction_request(
	requester_peer_id: int,
	request_id: int,
	target_net_id: int
) -> void:
	if not _is_host_bound():
		return
	if not _transactions.consume_remote_transaction_admission(requester_peer_id):
		return
	if request_id <= 0 or target_net_id <= 0:
		return
	if not _consume_plant_destruction_rate_token(requester_peer_id):
		return
	var last_request_id := int(
		_last_plant_destruction_request_ids.get(requester_peer_id, 0)
	)
	if request_id <= last_request_id:
		return
	_last_plant_destruction_request_ids[requester_peer_id] = request_id
	_mode_adapter.request_authoritative_nearest_plant_destruction(
		requester_peer_id,
		target_net_id
	)


func _handle_authoritative_plant_placement_request(
	requester_peer_id: int,
	request_id: int,
	plant_id_wire: String,
	anchor: Vector2i
) -> void:
	if not _is_host_bound():
		return
	if not _transactions.consume_remote_transaction_admission(requester_peer_id):
		return
	if (
		request_id <= 0
		or plant_id_wire.is_empty()
		or plant_id_wire.length() > PLANT_ID_WIRE_MAX_LENGTH
	):
		return
	if not _consume_peer_rate_token(requester_peer_id):
		return
	var last_request_id := int(_last_plant_placement_request_ids.get(requester_peer_id, 0))
	if request_id <= last_request_id:
		_request_placement_rejection(requester_peer_id, request_id, &"stale_request")
		return
	_last_plant_placement_request_ids[requester_peer_id] = request_id
	if _get_authoritative_team_plant_count() >= MULTIPLAYER_TEAM_PLANT_LIMIT:
		_request_placement_rejection(
			requester_peer_id,
			request_id,
			&"team_limit_reached"
		)
		return
	_mode_adapter.request_authoritative_plant_placement(
		requester_peer_id,
		request_id,
		StringName(plant_id_wire),
		anchor
	)


func _handle_authoritative_inventory_plant_placement_request(
	requester_peer_id: int,
	request_id: int,
	plant_id_wire: String,
	anchor: Vector2i,
	slot_index: int,
	expected_inventory_revision: int,
	item_config_path: String
) -> void:
	if not _is_host_bound():
		return
	if not _transactions.consume_remote_transaction_admission(requester_peer_id):
		return
	if (
		request_id <= 0
		or plant_id_wire.is_empty()
		or plant_id_wire.length() > PLANT_ID_WIRE_MAX_LENGTH
		or slot_index < 0
		or slot_index >= RunStateStore.INVENTORY_CAPACITY
		or expected_inventory_revision < 0
		or item_config_path.is_empty()
		or item_config_path.length() > INVENTORY_ITEM_CONFIG_PATH_WIRE_MAX_LENGTH
	):
		return
	if not _consume_peer_rate_token(requester_peer_id):
		return
	var last_request_id := int(_last_plant_placement_request_ids.get(requester_peer_id, 0))
	if request_id <= last_request_id:
		_request_placement_rejection(requester_peer_id, request_id, &"stale_request")
		return
	_last_plant_placement_request_ids[requester_peer_id] = request_id
	if _get_authoritative_team_plant_count() >= MULTIPLAYER_TEAM_PLANT_LIMIT:
		_request_placement_rejection(
			requester_peer_id,
			request_id,
			&"team_limit_reached"
		)
		return
	_mode_adapter.request_authoritative_inventory_plant_placement(
		requester_peer_id,
		request_id,
		StringName(plant_id_wire),
		anchor,
		slot_index,
		expected_inventory_revision,
		item_config_path
	)


func _get_authoritative_team_plant_count() -> int:
	var plant_count := _mode_adapter.get_authoritative_team_plant_count()
	# A Host without its authoritative registry must fail closed.
	return MULTIPLAYER_TEAM_PLANT_LIMIT if plant_count < 0 else plant_count


func _request_placement_rejection(
	requester_peer_id: int,
	request_id: int,
	reason: StringName
) -> void:
	send_plant_placement_rejected(requester_peer_id, request_id, reason)


func send_plant_placement_rejected(
	requester_peer_id: int,
	request_id: int,
	reason: StringName
) -> void:
	if not _is_host_bound() or requester_peer_id <= 0:
		return
	if requester_peer_id == _net_manager.get_local_peer_id():
		_mode_adapter.apply_remote_plant_placement_rejected(request_id, reason)
		return
	if not _net_manager.is_peer_send_ready(requester_peer_id):
		return
	rpc_to_peer_requested.emit(
		requester_peer_id,
		&"net_plant_placement_rejected",
		[request_id, String(reason)]
	)


func _consume_peer_rate_token(peer_id: int, now_seconds: float = -1.0) -> bool:
	if peer_id <= 0:
		return false
	var now := Time.get_ticks_msec() / 1000.0 if now_seconds < 0.0 else now_seconds
	var bucket: Dictionary
	if _plant_placement_rate_buckets.has(peer_id):
		bucket = _plant_placement_rate_buckets[peer_id] as Dictionary
	else:
		bucket = {
			"tokens": PLANT_PLACEMENT_RATE_BURST,
			"last_time": now,
		}
		_plant_placement_rate_buckets[peer_id] = bucket
	var tokens := float(bucket.get("tokens", PLANT_PLACEMENT_RATE_BURST))
	var last_time := float(bucket.get("last_time", now))
	tokens = minf(
		PLANT_PLACEMENT_RATE_BURST,
		tokens + maxf(now - last_time, 0.0) * PLANT_PLACEMENT_RATE_PER_SECOND
	)
	var accepted := tokens >= 1.0
	if accepted:
		tokens -= 1.0
	bucket["tokens"] = tokens
	bucket["last_time"] = now
	return accepted


func _consume_plant_destruction_rate_token(
	peer_id: int,
	now_seconds: float = -1.0
) -> bool:
	if peer_id <= 0:
		return false
	var now := Time.get_ticks_msec() / 1000.0 if now_seconds < 0.0 else now_seconds
	var bucket: Dictionary
	if _plant_destruction_rate_buckets.has(peer_id):
		bucket = _plant_destruction_rate_buckets[peer_id] as Dictionary
	else:
		bucket = {
			"tokens": PLANT_DESTRUCTION_RATE_BURST,
			"last_time": now,
		}
		_plant_destruction_rate_buckets[peer_id] = bucket
	var tokens := float(bucket.get("tokens", PLANT_DESTRUCTION_RATE_BURST))
	var last_time := float(bucket.get("last_time", now))
	tokens = minf(
		PLANT_DESTRUCTION_RATE_BURST,
		tokens
		+ maxf(now - last_time, 0.0) * PLANT_DESTRUCTION_RATE_PER_SECOND
	)
	var accepted := tokens >= 1.0
	if accepted:
		tokens -= 1.0
	bucket["tokens"] = tokens
	bucket["last_time"] = now
	return accepted


func _on_host_plant_spawned(
	request_id: int,
	owner_peer_id: int,
	net_id: int,
	plant_id: StringName,
	anchor: Vector2i,
	current_health: int,
	maximum_health: int,
	health_revision: int
) -> void:
	if not _is_host_bound():
		return
	if (
		net_id <= 0
		or not _NetConstants.is_valid_network_combat_value(current_health)
		or not _NetConstants.is_valid_network_combat_value(maximum_health)
		or not _NetConstants.is_valid_network_combat_value(health_revision)
	):
		push_error("MpTowerWorldCoordinator: 植物生成生命值超出 signed int32 契约。")
		return
	_tower_economy.notify_plant_available(net_id)
	var plant := get_plant(net_id)
	_tower_economy.configure_warehouse_network(plant, true)
	_tower_economy.configure_production_network(plant, true)
	_tower_economy.configure_research_network(plant)
	var runtime_state := export_plant_runtime_state(plant)
	var host_sample_time := _session_coordinator.get_net_time()
	rpc_broadcast_requested.emit(
		&"net_plant_spawned",
		[
			request_id,
			owner_peer_id,
			net_id,
			String(plant_id),
			anchor,
			current_health,
			maximum_health,
			health_revision,
			runtime_state,
			host_sample_time,
		]
	)
	var warehouse := plant as OakWarehouse
	if warehouse != null:
		_tower_economy.broadcast_warehouse_snapshot(warehouse)


func _on_host_plant_placement_rejected(
	request_id: int,
	requester_peer_id: int,
	reason: StringName
) -> void:
	if _is_host_bound():
		_request_placement_rejection(requester_peer_id, request_id, reason)


func _on_host_plant_health_changed(
	net_id: int,
	current_health: int,
	maximum_health: int,
	health_revision: int
) -> void:
	if not _is_host_bound():
		return
	if (
		net_id <= 0
		or not _NetConstants.is_valid_network_combat_value(current_health)
		or not _NetConstants.is_valid_network_combat_value(maximum_health)
		or not _NetConstants.is_valid_network_combat_value(health_revision)
	):
		push_error("MpTowerWorldCoordinator: 植物生命更新超出 signed int32 契约。")
		return
	var previous := _pending_plant_health_updates.get(net_id, {}) as Dictionary
	if int(previous.get("health_revision", -1)) > health_revision:
		return
	previous["current_health"] = current_health
	previous["maximum_health"] = maximum_health
	previous["health_revision"] = health_revision
	_pending_plant_health_updates[net_id] = previous


func _on_host_plant_damage_status_changed(
	net_id: int,
	status_mask: int,
	status_revision: int
) -> void:
	if not _is_host_bound() or net_id <= 0 or status_revision <= 0:
		return
	plant_damage_status_broadcast_requested.emit(
		net_id,
		status_mask,
		status_revision
	)


func _on_host_plant_damage_applied(
	net_id: int,
	applied_damage: int,
	impact_direction: Vector2,
	damage_type: EnemyConfig.DamageType,
	world_position: Vector2
) -> void:
	if (
		not _is_host_bound()
		or net_id <= 0
		or applied_damage <= 0
		or not impact_direction.is_finite()
		or not world_position.is_finite()
	):
		return
	var update := _pending_plant_health_updates.get(net_id, {}) as Dictionary
	if update.is_empty():
		return
	var safe_damage_type := (
		EnemyConfig.DamageType.MAGIC
		if damage_type == EnemyConfig.DamageType.MAGIC
		else EnemyConfig.DamageType.PHYSICAL
	)
	if safe_damage_type == EnemyConfig.DamageType.MAGIC:
		update["magic_damage"] = int(update.get("magic_damage", 0)) + applied_damage
		update["magic_direction"] = impact_direction
	else:
		update["physical_damage"] = int(update.get("physical_damage", 0)) + applied_damage
		update["physical_direction"] = impact_direction
	var physical_damage := int(update.get("physical_damage", 0))
	var magic_damage := int(update.get("magic_damage", 0))
	var use_magic := magic_damage > physical_damage
	update["damage"] = physical_damage + magic_damage
	update["impact_direction"] = (
		update.get("magic_direction", Vector2.ZERO)
		if use_magic
		else update.get("physical_direction", Vector2.ZERO)
	)
	update["damage_type"] = int(
		EnemyConfig.DamageType.MAGIC
		if use_magic
		else EnemyConfig.DamageType.PHYSICAL
	)
	update["world_position"] = world_position
	_pending_plant_health_updates[net_id] = update


func _on_host_plant_healing_applied(
	net_id: int,
	applied_healing: int,
	world_position: Vector2
) -> void:
	if (
		not _is_host_bound()
		or net_id <= 0
		or applied_healing <= 0
		or not world_position.is_finite()
	):
		return
	var update := _pending_plant_health_updates.get(net_id, {}) as Dictionary
	if update.is_empty():
		return
	update["healing"] = int(update.get("healing", 0)) + applied_healing
	update["world_position"] = world_position
	_pending_plant_health_updates[net_id] = update


func _on_host_plant_removed(net_id: int, was_destroyed: bool = false) -> void:
	if not _is_host_bound() or net_id <= 0:
		return
	if _pending_plant_health_updates.has(net_id):
		_send_pending_plant_health_updates([net_id])
	_pending_plant_health_updates.erase(net_id)
	# Shell visuals share the ordered world-event channel with removal. Flush
	# committed FIRE records while the corresponding plant proxy still exists.
	_flush_bamboo_mortar_visuals()
	_tower_economy.notify_plant_removed(net_id)
	rpc_broadcast_requested.emit(
		&"net_plant_removed",
		[net_id, was_destroyed]
	)


func _flush_plant_health_updates() -> void:
	if not _is_host_bound() or _pending_plant_health_updates.is_empty():
		return
	var net_ids: Array[int] = []
	for net_id_variant in _pending_plant_health_updates.keys():
		var net_id := int(net_id_variant)
		if not _NetConstants.is_valid_network_combat_value(net_id):
			push_error("MpTowerWorldCoordinator: 拒绝序列化越界植物 net_id。")
			_pending_plant_health_updates.erase(net_id_variant)
			continue
		net_ids.append(net_id)
	net_ids.sort()
	_send_pending_plant_health_updates(net_ids)
	for net_id in net_ids:
		_pending_plant_health_updates.erase(net_id)


func _send_pending_plant_health_updates(net_ids: Array[int]) -> void:
	for chunk_start in range(0, net_ids.size(), PLANT_HEALTH_MAX_RECORDS_PER_PACKET):
		var chunk_end := mini(
			chunk_start + PLANT_HEALTH_MAX_RECORDS_PER_PACKET,
			net_ids.size()
		)
		var chunk_ids := PackedInt32Array()
		var health_values := PackedInt32Array()
		var maximum_values := PackedInt32Array()
		var revisions := PackedInt32Array()
		var damage_values := PackedInt32Array()
		var healing_values := PackedInt32Array()
		var directions := PackedVector2Array()
		var damage_types := PackedByteArray()
		var world_positions := PackedVector2Array()
		for record_index in range(chunk_start, chunk_end):
			var net_id := net_ids[record_index]
			var update := _pending_plant_health_updates.get(net_id, {}) as Dictionary
			if update.is_empty():
				continue
			var current_health := int(update.get("current_health", 0))
			var maximum_health := int(update.get("maximum_health", 1))
			var health_revision := int(update.get("health_revision", 0))
			var applied_damage := int(update.get("damage", 0))
			var applied_healing := int(update.get("healing", 0))
			if (
				not _NetConstants.is_valid_network_combat_value(net_id)
				or not _NetConstants.is_valid_network_combat_value(current_health)
				or not _NetConstants.is_valid_network_combat_value(maximum_health)
				or not _NetConstants.is_valid_network_combat_value(health_revision)
				or not _NetConstants.is_valid_network_combat_value(applied_damage)
				or not _NetConstants.is_valid_network_combat_value(applied_healing)
			):
				push_error("MpTowerWorldCoordinator: 拒绝序列化越界植物战斗值。")
				continue
			chunk_ids.append(net_id)
			health_values.append(current_health)
			maximum_values.append(maximum_health)
			revisions.append(health_revision)
			damage_values.append(applied_damage)
			healing_values.append(applied_healing)
			directions.append(update.get("impact_direction", Vector2.ZERO) as Vector2)
			damage_types.append(int(update.get("damage_type", EnemyConfig.DamageType.PHYSICAL)))
			world_positions.append(update.get("world_position", Vector2.ZERO) as Vector2)
		if chunk_ids.is_empty():
			continue
		plant_health_batch_broadcast_requested.emit(
			chunk_ids,
			health_values,
			maximum_values,
			revisions,
			damage_values,
			healing_values,
			directions,
			damage_types,
			world_positions
		)


func _apply_or_defer_remote_plant_health(
	net_id: int,
	current_health: int,
	maximum_health: int,
	health_revision: int
) -> void:
	if not _is_client_bound() or net_id <= 0 or health_revision < 0:
		return
	if _removed_remote_plant_ids.has(net_id):
		return
	var plant := get_plant(net_id)
	if plant == null or not is_instance_valid(plant):
		_cache_remote_plant_health(
			net_id,
			current_health,
			maximum_health,
			health_revision
		)
		return
	var pending := _pending_remote_plant_health_updates.get(net_id, {}) as Dictionary
	var selected_health := current_health
	var selected_maximum := maximum_health
	var selected_revision := health_revision
	if int(pending.get("health_revision", -1)) >= health_revision:
		selected_health = int(pending.get("current_health", current_health))
		selected_maximum = int(pending.get("maximum_health", maximum_health))
		selected_revision = int(pending.get("health_revision", health_revision))
	_erase_pending_remote_plant_health(net_id)
	_mode_adapter.apply_remote_plant_health(
		net_id,
		selected_health,
		selected_maximum,
		selected_revision
	)


func _cache_remote_plant_health(
	net_id: int,
	current_health: int,
	maximum_health: int,
	health_revision: int
) -> void:
	var previous := _pending_remote_plant_health_updates.get(net_id, {}) as Dictionary
	if int(previous.get("health_revision", -1)) >= health_revision:
		return
	if previous.is_empty():
		while (
			_pending_remote_plant_health_updates.size()
			>= CLIENT_PENDING_PLANT_HEALTH_MAX_ENTRIES
			and not _pending_remote_plant_health_order.is_empty()
		):
			var evicted_net_id := int(_pending_remote_plant_health_order.pop_front())
			_pending_remote_plant_health_updates.erase(evicted_net_id)
		_pending_remote_plant_health_order.append(net_id)
	_pending_remote_plant_health_updates[net_id] = {
		"current_health": current_health,
		"maximum_health": maximum_health,
		"health_revision": health_revision,
	}


func _erase_pending_remote_plant_health(net_id: int) -> void:
	if not _pending_remote_plant_health_updates.erase(net_id):
		return
	_pending_remote_plant_health_order.erase(net_id)


func _mark_remote_plant_removed(net_id: int) -> void:
	if net_id <= 0:
		return
	_erase_pending_remote_plant_health(net_id)
	if _removed_remote_plant_ids.has(net_id):
		return
	while (
		_removed_remote_plant_ids.size()
		>= CLIENT_REMOVED_PLANT_TOMBSTONE_MAX_ENTRIES
		and not _removed_remote_plant_id_order.is_empty()
	):
		var evicted_net_id := int(_removed_remote_plant_id_order.pop_front())
		_removed_remote_plant_ids.erase(evicted_net_id)
	_removed_remote_plant_ids[net_id] = true
	_removed_remote_plant_id_order.append(net_id)


func _clear_remote_plant_removed_marker(net_id: int) -> void:
	if net_id <= 0 or not _removed_remote_plant_ids.erase(net_id):
		return
	_removed_remote_plant_id_order.erase(net_id)


func _accept_remote_plant_feedback_revision(net_id: int, health_revision: int) -> bool:
	if net_id <= 0 or health_revision < 0:
		return false
	if health_revision <= int(_remote_plant_feedback_revisions.get(net_id, -1)):
		return false
	if not _remote_plant_feedback_revisions.has(net_id):
		while (
			_remote_plant_feedback_revisions.size()
			>= CLIENT_REMOVED_PLANT_TOMBSTONE_MAX_ENTRIES
			and not _remote_plant_feedback_revision_order.is_empty()
		):
			var evicted_net_id := int(_remote_plant_feedback_revision_order.pop_front())
			_remote_plant_feedback_revisions.erase(evicted_net_id)
		_remote_plant_feedback_revision_order.append(net_id)
	_remote_plant_feedback_revisions[net_id] = health_revision
	return true


func _clear_remote_plant_health_state() -> void:
	_pending_remote_plant_health_updates.clear()
	_pending_remote_plant_health_order.clear()
	_removed_remote_plant_ids.clear()
	_removed_remote_plant_id_order.clear()
	_remote_plant_feedback_revisions.clear()
	_remote_plant_feedback_revision_order.clear()


func _apply_authoritative_plant_damage_request(
	enemy: Enemy,
	request: DamageRequest,
	impact_direction: Vector2,
	damage_type: EnemyConfig.DamageType
) -> bool:
	if enemy == null or not is_instance_valid(enemy) or request == null:
		return false
	var enemy_net_id := _runtime.get_network_enemy_net_id_by_instance_id(
		enemy.get_instance_id()
	)
	if enemy_net_id <= 0:
		return false
	request.with_flag(CombatTypes.DamageFlag.SUPPRESS_HIT_PARTICLES, false)
	var presentation_flags := CombatTypes.DamageFeedbackFlag.DIRECT_HIT_FLASH
	if impact_direction != Vector2.ZERO:
		presentation_flags |= CombatTypes.DamageFeedbackFlag.HIT_PARTICLES
	_enemy_coordinator.set_active_damage_feedback_context(
		enemy_net_id,
		impact_direction,
		damage_type,
		presentation_flags
	)
	var result := enemy.apply_combat_damage(request)
	_enemy_coordinator.clear_active_damage_feedback_context(enemy_net_id)
	if not result.accepted:
		return false
	if result.applied_damage <= 0:
		presentation_flags = 0
	if result.lethal:
		# The synchronous defeated signal already carries the final confirmed hit.
		return true
	if is_inside_tree():
		_enemy_coordinator.queue_damage_feedback(
			enemy_net_id,
			result.health_after,
			enemy.health_revision,
			clampi(
				result.resolved_damage,
				_NetConstants.NETWORK_COMBAT_VALUE_MIN,
				_NetConstants.NETWORK_COMBAT_VALUE_MAX
			),
			impact_direction,
			damage_type,
			presentation_flags
		)
	return true


func _create_plant_damage_source_snapshot(
	damage_source_id: int,
	source_type: StringName
) -> DamageSourceSnapshot:
	var source_plant := get_plant(damage_source_id)
	if source_plant != null and is_instance_valid(source_plant):
		return source_plant.create_damage_source_snapshot(
			damage_source_id,
			source_type
		)
	return DamageSourceSnapshot.create(
		CombatRelationService.PLAYER_ALLIED,
		0,
		maxi(damage_source_id, 0),
		maxi(damage_source_id, 0),
		source_type
	)


func _flush_bamboo_mortar_visuals() -> void:
	if _pending_bamboo_mortar_visuals.is_empty():
		return
	assert(
		_pending_bamboo_mortar_action_ids.size()
		== _pending_bamboo_mortar_visuals.size()
		and _pending_bamboo_mortar_stages.size()
		== _pending_bamboo_mortar_visuals.size()
		and _pending_bamboo_mortar_spawn_positions.size()
		== _pending_bamboo_mortar_visuals.size()
		and _pending_bamboo_mortar_landing_positions.size()
		== _pending_bamboo_mortar_visuals.size()
		and _pending_bamboo_mortar_windup_durations.size()
		== _pending_bamboo_mortar_visuals.size()
		and _pending_bamboo_mortar_host_times.size()
		== _pending_bamboo_mortar_visuals.size()
	)
	for chunk_start in range(
		0,
		_pending_bamboo_mortar_visuals.size(),
		BAMBOO_MORTAR_VISUAL_MAX_RECORDS_PER_PACKET
	):
		var chunk_end := mini(
			chunk_start + BAMBOO_MORTAR_VISUAL_MAX_RECORDS_PER_PACKET,
			_pending_bamboo_mortar_visuals.size()
		)
		bamboo_mortar_visual_batch_broadcast_requested.emit(
			_pending_bamboo_mortar_visuals.slice(chunk_start, chunk_end),
			_pending_bamboo_mortar_action_ids.slice(chunk_start, chunk_end),
			_pending_bamboo_mortar_stages.slice(chunk_start, chunk_end),
			_pending_bamboo_mortar_spawn_positions.slice(
				chunk_start,
				chunk_end
			),
			_pending_bamboo_mortar_landing_positions.slice(
				chunk_start,
				chunk_end
			),
			_pending_bamboo_mortar_windup_durations.slice(
				chunk_start,
				chunk_end
			),
			_pending_bamboo_mortar_host_times.slice(chunk_start, chunk_end)
		)
	_clear_bamboo_mortar_visuals()


func _flush_corn_machine_gun_burst_visuals() -> void:
	if _pending_corn_machine_gun_burst_visuals.is_empty():
		return
	assert(
		_pending_corn_machine_gun_burst_action_ids.size()
		== _pending_corn_machine_gun_burst_visuals.size()
		and _pending_corn_machine_gun_burst_shot_counts.size()
		== _pending_corn_machine_gun_burst_visuals.size()
		and _pending_corn_machine_gun_burst_directions.size()
		== _pending_corn_machine_gun_burst_visuals.size()
		and _pending_corn_machine_gun_burst_host_times.size()
		== _pending_corn_machine_gun_burst_visuals.size()
	)
	for chunk_start in range(
		0,
		_pending_corn_machine_gun_burst_visuals.size(),
		CORN_MACHINE_GUN_BURST_MAX_RECORDS_PER_PACKET
	):
		var chunk_end := mini(
			chunk_start + CORN_MACHINE_GUN_BURST_MAX_RECORDS_PER_PACKET,
			_pending_corn_machine_gun_burst_visuals.size()
		)
		corn_machine_gun_burst_batch_broadcast_requested.emit(
			_pending_corn_machine_gun_burst_visuals.slice(
				chunk_start,
				chunk_end
			),
			_pending_corn_machine_gun_burst_action_ids.slice(
				chunk_start,
				chunk_end
			),
			_pending_corn_machine_gun_burst_shot_counts.slice(
				chunk_start,
				chunk_end
			),
			_pending_corn_machine_gun_burst_directions.slice(
				chunk_start,
				chunk_end
			),
			_pending_corn_machine_gun_burst_host_times.slice(
				chunk_start,
				chunk_end
			)
		)
	_clear_corn_machine_gun_burst_visuals()


func _clear_bamboo_mortar_visuals() -> void:
	_pending_bamboo_mortar_visuals.clear()
	_pending_bamboo_mortar_action_ids.clear()
	_pending_bamboo_mortar_stages.clear()
	_pending_bamboo_mortar_spawn_positions.clear()
	_pending_bamboo_mortar_landing_positions.clear()
	_pending_bamboo_mortar_windup_durations.clear()
	_pending_bamboo_mortar_host_times.clear()


func _clear_corn_machine_gun_burst_visuals() -> void:
	_pending_corn_machine_gun_burst_visuals.clear()
	_pending_corn_machine_gun_burst_action_ids.clear()
	_pending_corn_machine_gun_burst_shot_counts.clear()
	_pending_corn_machine_gun_burst_directions.clear()
	_pending_corn_machine_gun_burst_host_times.clear()


func _clear_plant_combat_network_state() -> void:
	_clear_bamboo_mortar_visuals()
	_clear_corn_machine_gun_burst_visuals()
	_bamboo_mortar_visual_flush_time_left = (
		BAMBOO_MORTAR_VISUAL_FLUSH_INTERVAL_SECONDS
	)
	_corn_machine_gun_burst_flush_time_left = (
		CORN_MACHINE_GUN_BURST_FLUSH_INTERVAL_SECONDS
	)


func _is_valid_bamboo_mortar_visual_payload(
	plant_net_ids: PackedInt32Array,
	action_ids: PackedInt32Array,
	stages: PackedByteArray,
	spawn_positions: PackedVector2Array,
	landing_positions: PackedVector2Array,
	committed_windup_durations: PackedFloat32Array,
	host_action_times: PackedFloat64Array
) -> bool:
	var record_count := plant_net_ids.size()
	if (
		record_count <= 0
		or record_count > BAMBOO_MORTAR_VISUAL_MAX_RECORDS_PER_PACKET
		or action_ids.size() != record_count
		or stages.size() != record_count
		or spawn_positions.size() != record_count
		or landing_positions.size() != record_count
		or committed_windup_durations.size() != record_count
		or host_action_times.size() != record_count
	):
		return false
	for record_index in range(record_count):
		if (
			plant_net_ids[record_index] <= 0
			or action_ids[record_index] <= 0
			or stages[record_index] > 1
			or not spawn_positions[record_index].is_finite()
			or not landing_positions[record_index].is_finite()
			or not is_finite(committed_windup_durations[record_index])
			or committed_windup_durations[record_index]
				< BambooMortar.MIN_COMMITTED_WINDUP_DURATION_SECONDS
			or committed_windup_durations[record_index]
				> BambooMortar.WINDUP_DURATION_SECONDS
			or not is_finite(host_action_times[record_index])
			or host_action_times[record_index] < 0.0
		):
			return false
	return true


func _is_valid_corn_machine_gun_burst_payload(
	plant_net_ids: PackedInt32Array,
	action_ids: PackedInt32Array,
	shot_counts: PackedByteArray,
	directions: PackedVector2Array,
	host_action_times: PackedFloat64Array
) -> bool:
	var record_count := plant_net_ids.size()
	if (
		record_count <= 0
		or record_count > CORN_MACHINE_GUN_BURST_MAX_RECORDS_PER_PACKET
		or action_ids.size() != record_count
		or shot_counts.size() != record_count
		or directions.size() != record_count
		or host_action_times.size() != record_count
	):
		return false
	for record_index in range(record_count):
		var direction := directions[record_index]
		var host_action_time := host_action_times[record_index]
		if (
			plant_net_ids[record_index] <= 0
			or action_ids[record_index] <= 0
			or shot_counts[record_index] <= 0
			or shot_counts[record_index]
				> _NetConstants.CORN_MACHINE_GUN_BURST_SHOT_COUNT_MAX
			or not direction.is_finite()
			or direction.length_squared() <= 0.001
			or not is_finite(host_action_time)
			or host_action_time < 0.0
		):
			return false
	return true


func _get_remote_action_elapsed(
	host_action_time: float,
	local_net_time: float,
	has_host_time_offset: bool,
	host_to_client_time_offset: float
) -> float:
	if not is_finite(local_net_time):
		return INF
	var mapped_action_time := local_net_time
	if has_host_time_offset:
		if not is_finite(host_to_client_time_offset):
			return INF
		mapped_action_time = host_action_time + host_to_client_time_offset
	return maxf(local_net_time - mapped_action_time, 0.0)


func _acquire_or_instantiate_projectile(scene: PackedScene) -> Node:
	if scene == null:
		return null
	if _runtime.has_session_object_pool_scene(scene):
		return _runtime.acquire_session_object(scene, false)
	return scene.instantiate()


func _request_terrain_snapshot_repair() -> void:
	if (
		_client_waiting_for_terrain_snapshot
		or not _is_client_terrain_bound()
	):
		return
	_send_terrain_snapshot_repair_request()


func _send_terrain_snapshot_repair_request() -> void:
	_client_waiting_for_terrain_snapshot = true
	_arm_terrain_snapshot_repair_watchdog()
	terrain_snapshot_request_to_host.emit(_client_terrain_revision)


func _arm_terrain_snapshot_repair_watchdog() -> void:
	_terrain_snapshot_repair_watchdog_time_left = (
		TERRAIN_SNAPSHOT_REPAIR_WATCHDOG_SECONDS
	)


func _update_terrain_snapshot_repair_watchdog(delta: float) -> void:
	if not _client_waiting_for_terrain_snapshot:
		_terrain_snapshot_repair_watchdog_time_left = 0.0
		return
	if not _is_client_terrain_bound():
		return
	_terrain_snapshot_repair_watchdog_time_left = maxf(
		_terrain_snapshot_repair_watchdog_time_left - maxf(delta, 0.0),
		0.0
	)
	if _terrain_snapshot_repair_watchdog_time_left > 0.0:
		return
	# Valid chunks re-arm the watchdog. A stalled or rate-limited repair retries
	# no more than once per watchdog interval and discards incomplete assembly.
	_pending_terrain_snapshot_batches.clear()
	_send_terrain_snapshot_repair_request()


func _restart_terrain_snapshot_repair() -> void:
	_pending_terrain_snapshot_batches.clear()
	_client_waiting_for_terrain_snapshot = false
	_terrain_snapshot_repair_watchdog_time_left = 0.0
	_request_terrain_snapshot_repair()


func _consume_terrain_snapshot_request_token(
	peer_id: int,
	now_seconds: float = -1.0
) -> bool:
	if peer_id <= 0:
		return false
	var now := (
		Time.get_ticks_msec() / 1000.0
		if now_seconds < 0.0
		else now_seconds
	)
	var bucket: Dictionary
	if _terrain_snapshot_request_rate_buckets.has(peer_id):
		bucket = _terrain_snapshot_request_rate_buckets[peer_id] as Dictionary
	else:
		bucket = {
			"tokens": TERRAIN_SNAPSHOT_REQUEST_RATE_BURST,
			"last_time": now,
		}
		_terrain_snapshot_request_rate_buckets[peer_id] = bucket
	var tokens := float(
		bucket.get("tokens", TERRAIN_SNAPSHOT_REQUEST_RATE_BURST)
	)
	var last_time := float(bucket.get("last_time", now))
	tokens = minf(
		TERRAIN_SNAPSHOT_REQUEST_RATE_BURST,
		tokens
		+ maxf(now - last_time, 0.0)
		* TERRAIN_SNAPSHOT_REQUEST_RATE_PER_SECOND
	)
	var accepted := tokens >= 1.0
	if accepted:
		tokens -= 1.0
	bucket["tokens"] = tokens
	bucket["last_time"] = now
	return accepted


func _is_valid_terrain_payload(
	cell_xy: PackedInt32Array,
	terrain_types: PackedInt32Array,
	maximum_cells: int = 0
) -> bool:
	if cell_xy.size() != terrain_types.size() * 2:
		return false
	if maximum_cells > 0 and terrain_types.size() > maximum_cells:
		return false
	var seen_cells: Dictionary = {}
	for cell_index in range(terrain_types.size()):
		var terrain_type := terrain_types[cell_index]
		if (
			terrain_type != TERRAIN_TYPE_EMPTY
			and terrain_type != TERRAIN_TYPE_GRASS
			and terrain_type != TERRAIN_TYPE_DIRT
		):
			return false
		var cell := Vector2i(
			cell_xy[cell_index * 2],
			cell_xy[cell_index * 2 + 1]
		)
		if seen_cells.has(cell):
			return false
		seen_cells[cell] = true
	return true


func _reset_terrain_session_state() -> void:
	_terrain_snapshot_request_rate_buckets.clear()
	_next_terrain_snapshot_id = 1
	_last_host_terrain_revision_broadcast = 0
	_client_terrain_revision = -1
	_client_has_terrain_snapshot = false
	_client_waiting_for_terrain_snapshot = false
	_terrain_snapshot_repair_watchdog_time_left = 0.0
	_last_completed_terrain_snapshot_id = 0
	_pending_terrain_snapshot_batches.clear()


func _connect_mode_adapter() -> void:
	var bindings: Array[Array] = [
		[_mode_adapter.plant_placement_requested, _on_local_plant_placement_requested],
		[
			_mode_adapter.inventory_plant_placement_requested,
			_on_local_inventory_plant_placement_requested,
		],
		[
			_mode_adapter.nearest_plant_destruction_requested,
			_on_local_nearest_plant_destruction_requested,
		],
		[_mode_adapter.plant_spawned, _on_host_plant_spawned],
		[_mode_adapter.plant_placement_rejected, _on_host_plant_placement_rejected],
		[_mode_adapter.plant_health_changed, _on_host_plant_health_changed],
		[
			_mode_adapter.plant_damage_status_changed,
			_on_host_plant_damage_status_changed,
		],
		[_mode_adapter.plant_damage_applied, _on_host_plant_damage_applied],
		[_mode_adapter.plant_healing_applied, _on_host_plant_healing_applied],
		[_mode_adapter.plant_removed, _on_host_plant_removed],
		[_mode_adapter.base_health_changed, _on_host_base_health_changed],
		[_mode_adapter.terrain_delta, _on_host_terrain_delta],
		[
			_mode_adapter.test_arena_manual_night_changed,
			_on_host_test_arena_manual_night_changed,
		],
	]
	for binding in bindings:
		var source: Signal = binding[0]
		var target: Callable = binding[1]
		if not source.is_connected(target):
			source.connect(target)


func _disconnect_mode_adapter() -> void:
	if _mode_adapter == null or not is_instance_valid(_mode_adapter):
		return
	var bindings: Array[Array] = [
		[_mode_adapter.plant_placement_requested, _on_local_plant_placement_requested],
		[
			_mode_adapter.inventory_plant_placement_requested,
			_on_local_inventory_plant_placement_requested,
		],
		[
			_mode_adapter.nearest_plant_destruction_requested,
			_on_local_nearest_plant_destruction_requested,
		],
		[_mode_adapter.plant_spawned, _on_host_plant_spawned],
		[_mode_adapter.plant_placement_rejected, _on_host_plant_placement_rejected],
		[_mode_adapter.plant_health_changed, _on_host_plant_health_changed],
		[
			_mode_adapter.plant_damage_status_changed,
			_on_host_plant_damage_status_changed,
		],
		[_mode_adapter.plant_damage_applied, _on_host_plant_damage_applied],
		[_mode_adapter.plant_healing_applied, _on_host_plant_healing_applied],
		[_mode_adapter.plant_removed, _on_host_plant_removed],
		[_mode_adapter.base_health_changed, _on_host_base_health_changed],
		[_mode_adapter.terrain_delta, _on_host_terrain_delta],
		[
			_mode_adapter.test_arena_manual_night_changed,
			_on_host_test_arena_manual_night_changed,
		],
	]
	for binding in bindings:
		var source: Signal = binding[0]
		var target: Callable = binding[1]
		if source.is_connected(target):
			source.disconnect(target)


func _is_host_bound() -> bool:
	return is_bound() and _net_manager.is_host()


func _is_client_bound() -> bool:
	return is_bound() and _net_manager.is_client() and not _net_manager.is_host()


func _is_client_terrain_bound() -> bool:
	return _is_client_bound() and _mode_adapter.supports_terrain_state()
