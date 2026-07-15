@abstract
extends Node2D
class_name GameRuntimeBase

const CombatTargetIndexScript := preload("res://scene/combat_target_index.gd")
const EnemySpawnEffectBudgetScript := preload("res://scene/enemy_spawn_effect_budget.gd")
const ENEMY_SPAWN_EFFECT_SCENE := preload(
	"res://scene/enemy/yuanshi_insect_spawn_effect.tscn"
)
const BULLET_HIT_EFFECT_POOL_SCENE := preload("res://scene/bullet_hit_effect.tscn")
const ENEMY_HIT_EFFECT_POOL_SCENE := preload("res://scene/enemy/enemy_hit_effect.tscn")

const ENEMY_SPAWN_EFFECT_PREWARM_COUNT := 16
const ENEMY_SPAWN_EFFECT_RETAINED_CAPACITY := 32
const BULLET_HIT_EFFECT_CAPACITY := 64
const ENEMY_HIT_EFFECT_CAPACITY := 128

signal multiplayer_enemy_spawned(net_id: int, enemy_config: EnemyConfig, spawn_position: Vector2)
signal multiplayer_enemy_defeated(net_id: int, defeat_position: Vector2)
signal multiplayer_enemy_removed(net_id: int)
signal multiplayer_enemy_escaped(net_id: int)
signal multiplayer_pickup_spawned(net_id: int, pickup_config: PickupConfig, spawn_position: Vector2)
signal multiplayer_pickup_collected(
	net_id: int,
	collector_peer_id: int,
	pickup_config: PickupConfig,
	applied_immediately: bool
)
signal multiplayer_pickup_removed(net_id: int)
signal multiplayer_merchant_active_changed(active: bool)
signal multiplayer_flow_state_changed(step_id: StringName, state: int, countdown_seconds: int)
signal multiplayer_boss_started(net_id: int, boss_config: BossConfig, spawn_position: Vector2)
signal multiplayer_defeat_started
signal multiplayer_victory_started
signal multiplayer_revive_all_requested
signal multiplayer_base_health_changed(current_health: int, maximum_health: int, revision: int)
signal multiplayer_tower_defense_wave_progress_changed(
	wave_number: int,
	defeated: int,
	escaped: int,
	resolved: int,
	total: int
)
signal multiplayer_plant_spawned(
	request_id: int,
	owner_peer_id: int,
	net_id: int,
	plant_id: StringName,
	anchor: Vector2i,
	current_health: int,
	maximum_health: int,
	health_revision: int
)
signal multiplayer_plant_placement_rejected(
	request_id: int,
	requester_peer_id: int,
	reason: StringName
)
signal multiplayer_plant_health_changed(
	net_id: int,
	current_health: int,
	maximum_health: int,
	health_revision: int
)
signal multiplayer_plant_removed(net_id: int)
## Authoritative terrain batches are already committed locally when emitted.
## Revisions must be positive, strictly monotonic, and advance exactly once per
## non-empty batch. cell_xy stores x/y pairs parallel to terrain_types.
signal multiplayer_terrain_delta(
	revision: int,
	cell_xy: PackedInt32Array,
	terrain_types: PackedInt32Array
)
signal multiplayer_plant_placement_requested(
	request_id: int,
	plant_id: StringName,
	anchor: Vector2i
)
signal return_to_lobby_requested
signal runtime_preparation_progress_changed(stage: String, completed: int, total: int)
signal runtime_preparation_completed

enum RuntimeMode {
	SINGLEPLAYER,
	HOST_AUTHORITY,
	CLIENT_VIEW,
}

enum WaveState {
	PRE_WAVE,
	WAVE_ACTIVE,
	INTERMISSION,
	VICTORY,
	DEFEAT,
	BOSS_INTRO,
	BOSS_ACTIVE,
}

@export var runtime_mode: RuntimeMode = RuntimeMode.SINGLEPLAYER

@onready var enemy_container: Node2D = $EnemyContainer
@onready var grid_pathfinder: Node = $GridPathfinder

var player: Player = null
var wave_state: WaveState = WaveState.PRE_WAVE
var multiplayer_local_peer_id: int = 0
var peer_players: Dictionary = {}
var multiplayer_pickups: Dictionary = {}
var multiplayer_enemy_ids_by_instance: Dictionary = {}
var multiplayer_enemies_by_net_id: Dictionary = {}
var combat_target_index = CombatTargetIndexScript.new()
var _enemy_snapshot_states_by_net_id: Dictionary = {}
var _enemy_snapshot_output: Array[SnapshotManager.EnemyState] = []
var _enemy_snapshot_live_ids: Dictionary = {}
var _stale_enemy_snapshot_ids: Array[int] = []
var _enemy_spawn_effect_budget = EnemySpawnEffectBudgetScript.new()
var runtime_activation_deferred := false
var runtime_activated := false
var runtime_preparation_complete := false
var runtime_preparation_stage := "等待场景初始化"
var runtime_preparation_completed_steps := 0
var runtime_preparation_total_steps := 1


@abstract func configure_multiplayer(
	mode: int,
	local_peer_id: int,
	player_names: Dictionary,
	player_character_ids: Dictionary = {}
) -> void


@abstract func get_player_for_peer(peer_id: int) -> Player
@abstract func get_enemy_for_net_id(net_id: int) -> Enemy
@abstract func get_pickup_for_net_id(net_id: int) -> Pickup
@abstract func remove_multiplayer_player(peer_id: int) -> void
@abstract func collect_player_snapshot_states() -> Array[SnapshotManager.PlayerState]
@abstract func collect_enemy_snapshot_states() -> Array[SnapshotManager.EnemyState]
@abstract func apply_remote_flow_state(step_id: StringName, state: int, seconds: int) -> void
@abstract func get_flow_state_snapshot() -> Dictionary
@abstract func apply_remote_boss_started(
	net_id: int,
	boss_config: BossConfig,
	spawn_position: Vector2
) -> void
@abstract func apply_remote_defeat() -> void
@abstract func apply_remote_victory() -> void
@abstract func apply_remote_enemy_count(alive_count: int) -> void
@abstract func apply_remote_merchant_active(active: bool) -> void
@abstract func play_remote_enemy_spawn_effect(spawn_global_position: Vector2) -> void
@abstract func try_purchase_skill1_for_peer(peer_id: int) -> int
@abstract func apply_skill1_purchase_state(
	peer_id: int,
	current_xirang: int,
	skill1_unlocked: bool,
	skill1_upgrade_level: int = -1,
	skill1_charge_duration: float = -1.0
) -> void
@abstract func show_local_skill1_purchase_result(result_code: int) -> void
@abstract func try_refresh_luoxi_collectibles_for_peer(peer_id: int) -> int
@abstract func get_luoxi_collectible_refresh_count(peer_id: int) -> int
@abstract func try_claim_luoxi_collectible_for_peer(
	peer_id: int,
	config_path_or_choice: Variant
) -> int
@abstract func has_luoxi_collectible_claimed(peer_id: int) -> bool
@abstract func record_luoxi_collectible_claim(peer_id: int) -> void
@abstract func mark_luoxi_collectible_claimed(peer_id: int) -> void
@abstract func show_local_luoxi_collectible_result(result_code: int) -> void
@abstract func show_local_luoxi_refresh_result(
	result_code: int,
	refresh_count: int,
	current_xirang: int
) -> void
@abstract func show_debug_collectible_grant_result(config_path: String, success: bool) -> void


static func register_common_visual_effect_pools(pool: SessionObjectPool) -> void:
	pool.register_scene(
		ENEMY_SPAWN_EFFECT_SCENE,
		ENEMY_SPAWN_EFFECT_PREWARM_COUNT,
		ENEMY_SPAWN_EFFECT_RETAINED_CAPACITY
	)
	pool.register_scene(
		BULLET_HIT_EFFECT_POOL_SCENE,
		BULLET_HIT_EFFECT_CAPACITY,
		BULLET_HIT_EFFECT_CAPACITY
	)
	pool.register_scene(
		ENEMY_HIT_EFFECT_POOL_SCENE,
		ENEMY_HIT_EFFECT_CAPACITY,
		ENEMY_HIT_EFFECT_CAPACITY
	)


func try_reserve_enemy_spawn_effect(
	spawn_global_position: Vector2,
	sample_time_seconds: float = -1.0
) -> bool:
	return _enemy_spawn_effect_budget.try_reserve(
		self,
		spawn_global_position,
		sample_time_seconds
	)


func register_combat_target(net_id: int, enemy: Enemy) -> void:
	combat_target_index.register_enemy(net_id, enemy)


func unregister_combat_target(net_id: int) -> void:
	combat_target_index.unregister_enemy(net_id)


func get_all_combat_targets() -> Array[Enemy]:
	if runtime_mode == RuntimeMode.SINGLEPLAYER:
		var result: Array[Enemy] = []
		_collect_combat_targets_from_container(enemy_container, result)
		_collect_combat_targets_from_container(get_node_or_null("BossContainer"), result)
		return result
	return combat_target_index.get_all_alive()


func query_combat_targets(center: Vector2, radius: float, max_count: int = 0) -> Array[Enemy]:
	var result: Array[Enemy] = []
	query_combat_targets_into(center, radius, result, max_count)
	return result


func query_combat_targets_into(
	center: Vector2,
	radius: float,
	result: Array[Enemy],
	max_count: int = 0
) -> void:
	result.clear()
	if runtime_mode == RuntimeMode.SINGLEPLAYER:
		var safe_radius := maxf(radius, 0.0)
		var radius_squared := safe_radius * safe_radius
		_append_combat_targets_in_radius(enemy_container, center, safe_radius, radius_squared, result)
		_append_combat_targets_in_radius(
			get_node_or_null("BossContainer"),
			center,
			safe_radius,
			radius_squared,
			result
		)
		if max_count == 1:
			_retain_nearest_combat_target(result, center)
			return
		result.sort_custom(
			func(a: Enemy, b: Enemy) -> bool:
				var a_distance := center.distance_squared_to(a.global_position)
				var b_distance := center.distance_squared_to(b.global_position)
				if not is_equal_approx(a_distance, b_distance):
					return a_distance < b_distance
				return a.get_instance_id() < b.get_instance_id()
		)
		if max_count > 0 and result.size() > max_count:
			result.resize(max_count)
		return
	combat_target_index.query_radius_into(center, radius, result, max_count)


func query_combat_targets_unordered_into(
	center: Vector2,
	radius: float,
	result: Array[Enemy]
) -> void:
	result.clear()
	if runtime_mode == RuntimeMode.SINGLEPLAYER:
		var safe_radius := maxf(radius, 0.0)
		var radius_squared := safe_radius * safe_radius
		_append_combat_targets_in_radius(
			enemy_container,
			center,
			safe_radius,
			radius_squared,
			result
		)
		_append_combat_targets_in_radius(
			get_node_or_null("BossContainer"),
			center,
			safe_radius,
			radius_squared,
			result
		)
		return
	combat_target_index.query_radius_unordered_into(center, radius, result)


func get_multiplayer_plant_node(_net_id: int) -> PlantDefense:
	return null


func _collect_combat_targets_from_container(container: Node, result: Array[Enemy]) -> void:
	if container == null:
		return
	for child in container.get_children():
		var enemy := child as Enemy
		if enemy != null and is_instance_valid(enemy) and not enemy.is_dead:
			result.append(enemy)


func _append_combat_targets_in_radius(
	container: Node,
	center: Vector2,
	safe_radius: float,
	radius_squared: float,
	result: Array[Enemy]
) -> void:
	if container == null:
		return
	for child in container.get_children():
		var enemy := child as Enemy
		if enemy == null or not is_instance_valid(enemy) or enemy.is_dead:
			continue
		if safe_radius > 0.0 and center.distance_squared_to(enemy.global_position) > radius_squared:
			continue
		result.append(enemy)


func _retain_nearest_combat_target(
	result: Array[Enemy],
	center: Vector2
) -> void:
	if result.size() <= 1:
		return
	var nearest := result[0]
	var nearest_distance := center.distance_squared_to(nearest.global_position)
	var nearest_instance_id := nearest.get_instance_id()
	for candidate_index in range(1, result.size()):
		var candidate := result[candidate_index]
		var candidate_distance := center.distance_squared_to(candidate.global_position)
		var candidate_instance_id := candidate.get_instance_id()
		if (
			candidate_distance < nearest_distance
			and not is_equal_approx(candidate_distance, nearest_distance)
		) or (
			is_equal_approx(candidate_distance, nearest_distance)
			and candidate_instance_id < nearest_instance_id
		):
			nearest = candidate
			nearest_distance = candidate_distance
			nearest_instance_id = candidate_instance_id
	result[0] = nearest
	result.resize(1)


func collect_reused_enemy_snapshot_states(
	primary_container: Node,
	secondary_container: Node = null
) -> Array[SnapshotManager.EnemyState]:
	_enemy_snapshot_output.clear()
	_append_enemy_snapshot_states_from_container(primary_container)
	_append_enemy_snapshot_states_from_container(secondary_container)
	# With unique authoritative net IDs, adding every live state makes the cache
	# larger than the output if and only if at least one old ID went stale. The
	# common no-spawn/no-removal snapshot therefore skips all live-ID hash writes.
	if _enemy_snapshot_states_by_net_id.size() == _enemy_snapshot_output.size():
		return _enemy_snapshot_output
	_enemy_snapshot_live_ids.clear()
	for live_state in _enemy_snapshot_output:
		_enemy_snapshot_live_ids[live_state.net_id] = true
	_stale_enemy_snapshot_ids.clear()
	# Direct Dictionary traversal avoids allocating keys() every snapshot. Erase
	# only after traversal so the cached state table remains mutation-safe.
	for cached_id_variant in _enemy_snapshot_states_by_net_id:
		var cached_id := int(cached_id_variant)
		if not _enemy_snapshot_live_ids.has(cached_id):
			_stale_enemy_snapshot_ids.append(cached_id)
	for stale_id in _stale_enemy_snapshot_ids:
		_enemy_snapshot_states_by_net_id.erase(stale_id)
	return _enemy_snapshot_output


func _append_enemy_snapshot_states_from_container(container: Node) -> void:
	if container == null:
		return
	# Godot materializes this child list in one native call. Despite its small
	# temporary Array, this is materially faster at horde scale than crossing the
	# script/native boundary once per child with get_child(index).
	for child in container.get_children():
		var enemy := child as Enemy
		if enemy == null or not is_instance_valid(enemy):
			continue
		var net_id := int(enemy.get_meta(&"net_id", enemy.get_instance_id()))
		if net_id <= 0:
			continue
		var state := (
			_enemy_snapshot_states_by_net_id.get(net_id)
			as SnapshotManager.EnemyState
		)
		if state == null:
			state = SnapshotManager.EnemyState.new()
			_enemy_snapshot_states_by_net_id[net_id] = state
		state.net_id = net_id
		state.position = enemy.global_position
		state.velocity = enemy.velocity
		state.health = enemy.current_health
		state.is_dead = enemy.is_dead
		state.visual_status_mask = enemy.get_collectible_visual_status_mask()
		_enemy_snapshot_output.append(state)


func defer_runtime_activation() -> void:
	runtime_activation_deferred = true
	runtime_activated = false
	process_mode = Node.PROCESS_MODE_DISABLED


func activate_runtime() -> void:
	if runtime_activated:
		return
	runtime_activation_deferred = false
	runtime_activated = true
	process_mode = Node.PROCESS_MODE_INHERIT
	_on_runtime_activated()


func _on_runtime_activated() -> void:
	pass


func update_runtime_preparation_progress(stage: String, completed: int, total: int) -> void:
	runtime_preparation_stage = stage
	runtime_preparation_total_steps = maxi(total, 1)
	runtime_preparation_completed_steps = clampi(
		completed,
		0,
		runtime_preparation_total_steps
	)
	runtime_preparation_progress_changed.emit(
		runtime_preparation_stage,
		runtime_preparation_completed_steps,
		runtime_preparation_total_steps
	)


func mark_runtime_preparation_complete() -> void:
	if runtime_preparation_complete:
		return
	runtime_preparation_complete = true
	update_runtime_preparation_progress("战场准备完成", 1, 1)
	runtime_preparation_completed.emit()


func is_runtime_preparation_complete() -> bool:
	return runtime_preparation_complete


func get_runtime_preparation_progress() -> Dictionary:
	return {
		"stage": runtime_preparation_stage,
		"completed": runtime_preparation_completed_steps,
		"total": runtime_preparation_total_steps,
	}


func prewarm_shared_runtime_data() -> void:
	if LuoxiMerchant.is_collectible_cache_ready():
		return
	var config_paths := LuoxiMerchant.get_collectible_config_paths()
	const CONFIGS_PER_FRAME := 8
	var total_batches := maxi(ceili(float(config_paths.size()) / CONFIGS_PER_FRAME), 1)
	var completed_batches := 0
	for batch_start in range(0, config_paths.size(), CONFIGS_PER_FRAME):
		var batch_end := mini(batch_start + CONFIGS_PER_FRAME, config_paths.size())
		for config_index in range(batch_start, batch_end):
			var config := load(config_paths[config_index]) as PickupConfig
			LuoxiMerchant.cache_collectible_config(config)
		completed_batches += 1
		update_runtime_preparation_progress(
			"缓存收藏品配置…",
			completed_batches,
			total_batches
		)
		await get_tree().process_frame
		if not is_inside_tree():
			return
	LuoxiMerchant.finish_collectible_cache_warmup()


func prepare_shared_runtime_data_and_complete() -> void:
	await prewarm_shared_runtime_data()
	if is_inside_tree():
		mark_runtime_preparation_complete()


func has_session_object_pool_scene(scene: PackedScene) -> bool:
	var pool := get_node_or_null("SessionObjectPool") as SessionObjectPool
	return pool != null and pool.is_registered(scene)


func acquire_session_object(scene: PackedScene, strict: bool = false) -> Node:
	var pool := get_node_or_null("SessionObjectPool") as SessionObjectPool
	if pool == null or not pool.is_registered(scene):
		return null
	if strict:
		return pool.try_acquire(scene)
	return pool.acquire(scene)


func release_session_object(instance: Node) -> bool:
	var pool := get_node_or_null("SessionObjectPool") as SessionObjectPool
	return pool != null and pool.release(instance)


func spawn_xirang_reward(
	amount: int,
	target_player: Player,
	spawn_position: Vector2,
	landing_offset: Vector2 = Vector2.ZERO,
	preferred_visual_count: int = 1
) -> bool:
	var drop_manager := get_node_or_null("XirangDropManager") as XirangDropManager
	if drop_manager == null:
		return false
	return drop_manager.spawn_reward(
		amount,
		target_player,
		spawn_position,
		landing_offset,
		preferred_visual_count
	)


func supports_tower_defense() -> bool:
	return false


func request_tower_defense_wave_start(_requester_peer_id: int = 0) -> bool:
	return false


func consume_next_player_respawn_delay(_peer_id: int) -> float:
	return 10.0


func update_player_respawn_countdown(_peer_id: int, _seconds_left: int) -> void:
	pass


func clear_player_respawn_countdown(_peer_id: int) -> void:
	pass


## Runtime modes with a fixed multiplayer respawn layout can return a world-space
## position here. Returning null preserves the standard mode's living-player
## revive behavior.
func get_fixed_multiplayer_respawn_position(_peer_id: int) -> Variant:
	return null


func get_base_health_snapshot() -> Dictionary:
	return {}


func apply_remote_base_health(
	_current_health: int,
	_maximum_health: int,
	_revision: int
) -> void:
	pass


func apply_remote_enemy_escape(_net_id: int) -> void:
	pass


func request_multiplayer_plant_placement(
	_requester_peer_id: int,
	_request_id: int,
	_plant_id: StringName,
	_anchor: Vector2i
) -> void:
	pass


func apply_remote_plant_spawn(
	_request_id: int,
	_owner_peer_id: int,
	_net_id: int,
	_plant_id: StringName,
	_anchor: Vector2i,
	_current_health: int,
	_maximum_health: int,
	_health_revision: int
) -> void:
	pass


func apply_remote_plant_health(
	_net_id: int,
	_current_health: int,
	_maximum_health: int,
	_health_revision: int
) -> void:
	pass


func apply_remote_plant_removed(_net_id: int) -> void:
	pass


## Complete-state repair uses this path to prune a stale local replica without
## presenting the correction as a newly observed gameplay removal. Runtimes
## without a distinct visual lifecycle retain the existing removal behavior.
func apply_remote_plant_removed_silently(net_id: int) -> void:
	apply_remote_plant_removed(net_id)


func apply_remote_plant_placement_rejected(_request_id: int, _reason: StringName) -> void:
	pass


func has_multiplayer_plant(_net_id: int) -> bool:
	return false


func get_multiplayer_plant_snapshots() -> Array[Dictionary]:
	return []


## Only runtimes that own replicated terrain overrides should opt in. The
## standard runtime deliberately keeps the no-op contract below.
func supports_multiplayer_terrain_state() -> bool:
	return false


## Returns the complete authoritative override set relative to the authored
## map: {revision: int, cell_xy: PackedInt32Array, terrain_types: PackedInt32Array}.
## EMPTY (-1) is a valid terrain value and must not be discarded.
func get_multiplayer_terrain_snapshot() -> Dictionary:
	return {
		"revision": 0,
		"cell_xy": PackedInt32Array(),
		"terrain_types": PackedInt32Array(),
	}


## Client-view implementations must replace the complete override set
## atomically and return false without mutation when the payload is invalid.
func apply_remote_terrain_snapshot(
	_revision: int,
	_cell_xy: PackedInt32Array,
	_terrain_types: PackedInt32Array
) -> bool:
	return false


## Client-view implementations must apply the whole revision atomically and
## return false without mutation when the payload is invalid.
func apply_remote_terrain_delta(
	_revision: int,
	_cell_xy: PackedInt32Array,
	_terrain_types: PackedInt32Array
) -> bool:
	return false


func get_tower_defense_wave_progress_snapshot() -> Dictionary:
	return {}


func apply_remote_tower_defense_wave_progress(
	_wave_number: int,
	_defeated: int,
	_escaped: int,
	_resolved: int,
	_total: int
) -> void:
	pass
