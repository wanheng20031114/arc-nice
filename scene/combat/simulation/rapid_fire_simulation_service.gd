extends Node
class_name RapidFireSimulationService

## Data-oriented simulation and authoritative contact boundary for high-volume
## rapid-fire projectiles. Production AK routing remains deliberately outside
## this service: callers register scalar records and consume completion records.

enum Mode {
	DISABLED,
	SHADOW,
	DATA,
}

enum Profile {
	INVALID,
	AK,
	GUNNER,
	GUNNER_ELITE,
}

enum SlotState {
	EMPTY,
	PENDING_ACTIVATION,
	ACTIVE,
	TOMBSTONE,
}

enum CompletionReason {
	NONE,
	LIFETIME,
	WORLD,
	TARGET,
}

enum TargetKind {
	NONE,
	WORLD,
	PLAYER,
	PLANT,
	ENEMY,
}

const PROFILE_AK := &"ak"
const PROFILE_GUNNER := &"gunner"
const PROFILE_GUNNER_ELITE := &"gunner_elite"
const AK_SOURCE_TYPE := &"capoo_ak47_bullet"
const GUNNER_SOURCE_TYPE := &"combat_robot_gunner_bullet"
const GUNNER_ELITE_SOURCE_TYPE := &"combat_robot_gunner_elite_bullet"
const AK_WORLD_COLLISION_MASK := 1
const AK_WORLD_CHECK_INTERVAL := 2
const AK_COLLISION_SIZE := Vector2(5.0, 2.0)
const AK_COLLISION_CENTER_FORWARD_OFFSET := 0.5
const BROAD_PHASE_CLOSED_BOUNDARY_EPSILON := 0.001
const GUNNER_WORLD_COLLISION_MASK := 1
const GUNNER_WORLD_CHECK_INTERVAL := 2
const GUNNER_COLLISION_SIZE := Vector2(9.0, 3.0)
const GUNNER_COLLISION_CENTER_FORWARD_OFFSET := 0.0
const INVALID_HANDLE := 0
const INVALID_SLOT := -1
const HANDLE_SLOT_BITS := 32
const HANDLE_SLOT_MASK := 0xFFFFFFFF
const MAX_HANDLE_GENERATION := 0x7FFFFFFF
const MIN_GROWTH_CAPACITY := 64

var _combat_runtime: CombatRuntimeBase = null
var _enemy_simulation_coordinator: EnemySimulationCoordinator = null
var _enemy_damageable_spatial_index: EnemyDamageableSpatialIndex = null
var _combat_target_index: CombatTargetIndex = null
var _combat_relation_service: CombatRelationService = null
var _grid_pathfinder: GridPathfinder = null
var _teardown_prepared := false
var _teardown_count := 0

## Disabled by default, matching the legacy projectile. When enabled, only a
## positive GridPathfinder certificate suppresses the native ray query;
## unavailable or uncertain certificates always fall back to PhysicsServer2D.
static var world_collision_certificate_enabled := false

var _ak_collision_shape := RectangleShape2D.new()
var _gunner_collision_shape := RectangleShape2D.new()
var _world_ray_query := PhysicsRayQueryParameters2D.create(
	Vector2.ZERO,
	Vector2.ZERO,
	AK_WORLD_COLLISION_MASK
)
var _plant_query_results: Array = []
var _enemy_query_results: Array[Enemy] = []
var _endpoint_target: Node2D = null
var _endpoint_target_kind := TargetKind.NONE
var _endpoint_target_id := 0
var _world_hit_position := Vector2.ZERO

# Dense simulation records. `_record_count` is the initialized prefix; storage
# is resized ahead of use so the physics loop never grows a container.
var _positions := PackedVector2Array()
var _directions := PackedVector2Array()
var _speeds := PackedFloat64Array()
var _remaining_lifetimes := PackedFloat64Array()
var _damages := PackedInt32Array()
var _source_enemy_ids := PackedInt64Array()
var _projectile_ids := PackedInt64Array()
var _source_faction_ids := PackedInt32Array()
var _source_credit_peer_ids := PackedInt64Array()
var _source_instigator_entity_ids := PackedInt64Array()
var _source_event_ids := PackedInt64Array()
var _source_types := PackedStringArray()
var _spawn_physics_frames := PackedInt64Array()
var _states := PackedInt32Array()
var _record_generations := PackedInt32Array()
var _profiles := PackedInt32Array()
var _world_check_intervals := PackedInt32Array()
var _world_check_phases := PackedInt32Array()
var _world_step_indices := PackedInt32Array()
var _world_query_due_states := PackedByteArray()
var _world_collision_anchors := PackedVector2Array()
var _pending_target_instance_ids := PackedInt64Array()
var _pending_target_kinds := PackedInt32Array()
var _pending_target_ids := PackedInt64Array()
var _pending_target_positions := PackedVector2Array()
var _modes := PackedInt32Array()
var _handle_slots := PackedInt32Array()
var _simulation_ticks := PackedInt32Array()
var _spawn_sequences := PackedInt64Array()
var _record_capacity := 0
var _record_count := 0
var _active_slot_count := 0
var _pending_activation_count := 0
var _shadow_slot_count := 0
var _data_slot_count := 0
var _tombstone_count := 0

# Handles use a stable logical slot. Dense rows may move during stable
# compaction; this indirection is updated without changing the public handle.
var _handle_generations := PackedInt32Array()
var _dense_slots_by_handle_slot := PackedInt32Array()
var _free_handle_slots := PackedInt32Array()
var _handle_capacity := 0
var _next_handle_slot := 0
var _free_handle_count := 0
var _next_handle_generation := 1
var _next_spawn_sequence := 1

# Frame-local completion output, kept in the same stable order as simulation.
var _completion_handles := PackedInt64Array()
var _completion_projectile_ids := PackedInt64Array()
var _completion_positions := PackedVector2Array()
var _completion_directions := PackedVector2Array()
var _completion_spawn_sequences := PackedInt64Array()
var _completion_reasons := PackedInt32Array()
var _completion_target_kinds := PackedInt32Array()
var _completion_target_ids := PackedInt64Array()
var _completion_damage_applied_states := PackedByteArray()
var _completion_modes := PackedInt32Array()
var _completion_profiles := PackedInt32Array()
var _completion_capacity := 0
var _completion_count := 0

# Shadow comparison records are scalar snapshots. Read APIs return copies of
# individual values rather than mutable backing arrays.
var _difference_handles := PackedInt64Array()
var _difference_projectile_ids := PackedInt64Array()
var _difference_position_deltas := PackedVector2Array()
var _difference_lifetime_deltas := PackedFloat64Array()
var _difference_physics_frames := PackedInt64Array()
var _difference_capacity := 0
var _difference_count := 0

var _metric_registrations := 0
var _metric_registration_rejections := 0
var _metric_releases := 0
var _metric_physics_ticks := 0
var _metric_activation_skips := 0
var _metric_activations := 0
var _metric_advances := 0
var _metric_lifetime_completions := 0
var _metric_world_completions := 0
var _metric_target_completions := 0
var _metric_world_queries := 0
var _metric_world_certificates := 0
var _metric_plant_broad_queries := 0
var _metric_plant_exact_queries := 0
var _metric_player_exact_queries := 0
var _metric_enemy_broad_queries := 0
var _metric_enemy_exact_queries := 0
var _metric_damage_applications := 0
var _metric_compactions := 0
var _metric_compacted_tombstones := 0
var _metric_difference_records := 0


func _init() -> void:
	set_physics_process(false)
	_ak_collision_shape.size = AK_COLLISION_SIZE
	_gunner_collision_shape.size = GUNNER_COLLISION_SIZE
	_world_ray_query.collide_with_bodies = true
	_world_ray_query.collide_with_areas = false


func bind_context(
	combat_runtime: CombatRuntimeBase,
	coordinator: EnemySimulationCoordinator
) -> bool:
	if _teardown_prepared:
		return false
	if (
		combat_runtime == null
		or coordinator == null
		or not is_instance_valid(combat_runtime)
		or not is_instance_valid(coordinator)
		or coordinator.get_parent() != combat_runtime
	):
		return false
	if (
		_combat_runtime != null
		and (
			_combat_runtime != combat_runtime
			or _enemy_simulation_coordinator != coordinator
		)
	):
		return false
	_combat_runtime = combat_runtime
	_enemy_simulation_coordinator = coordinator
	_grid_pathfinder = combat_runtime.get_node_or_null(
		"GridPathfinder"
	) as GridPathfinder
	var combat_services := get_parent() as EnemyCombatServices
	_enemy_damageable_spatial_index = (
		combat_services.get_enemy_damageable_spatial_index()
		if combat_services != null
		else null
	)
	_combat_target_index = combat_runtime.combat_target_index
	_combat_relation_service = combat_runtime.get_combat_relation_service()
	if (
		_enemy_damageable_spatial_index == null
		or _combat_target_index == null
		or _combat_relation_service == null
	):
		_combat_runtime = null
		_enemy_simulation_coordinator = null
		_grid_pathfinder = null
		_enemy_damageable_spatial_index = null
		_combat_target_index = null
		_combat_relation_service = null
		return false
	return true


func is_bound() -> bool:
	return (
		_combat_runtime != null
		and _enemy_simulation_coordinator != null
		and is_instance_valid(_combat_runtime)
		and is_instance_valid(_enemy_simulation_coordinator)
	)


func is_bound_to(
	combat_runtime: CombatRuntimeBase,
	coordinator: EnemySimulationCoordinator
) -> bool:
	return (
		is_bound()
		and _combat_runtime == combat_runtime
		and _enemy_simulation_coordinator == coordinator
	)


func reserve_projectile_capacity(minimum_capacity: int) -> bool:
	if _teardown_prepared or minimum_capacity < _record_count:
		return false
	if minimum_capacity <= _record_capacity:
		return true
	_resize_record_storage(minimum_capacity)
	_resize_handle_storage(minimum_capacity)
	_resize_completion_storage(minimum_capacity)
	_resize_difference_storage(minimum_capacity)
	return true


func register_projectile(
	mode: Mode,
	profile: Profile,
	position: Vector2,
	direction: Vector2,
	speed: float,
	lifetime: float,
	damage: int,
	source_enemy_id: int,
	projectile_id: int,
	world_check_interval: int,
	world_check_phase: int,
	damage_source_snapshot: DamageSourceSnapshot = null
) -> int:
	if not _is_valid_registration(
		mode,
		profile,
		position,
		direction,
		speed,
		lifetime,
		damage,
		source_enemy_id,
		projectile_id,
		world_check_interval,
		world_check_phase,
		damage_source_snapshot
	):
		_metric_registration_rejections += 1
		return INVALID_HANDLE
	if not _ensure_projectile_capacity(_record_count + 1):
		_metric_registration_rejections += 1
		return INVALID_HANDLE

	var handle_slot := _acquire_handle_slot()
	if handle_slot < 0:
		_metric_registration_rejections += 1
		return INVALID_HANDLE
	var generation := int(_handle_generations[handle_slot])
	var dense_slot := _record_count
	_record_count += 1
	_positions[dense_slot] = position
	_directions[dense_slot] = direction.normalized()
	_speeds[dense_slot] = speed
	_remaining_lifetimes[dense_slot] = lifetime
	_damages[dense_slot] = damage
	_source_enemy_ids[dense_slot] = source_enemy_id
	_projectile_ids[dense_slot] = projectile_id
	_write_damage_source_snapshot(
		dense_slot,
		profile,
		source_enemy_id,
		projectile_id,
		damage_source_snapshot
	)
	_spawn_physics_frames[dense_slot] = Engine.get_physics_frames()
	_states[dense_slot] = SlotState.PENDING_ACTIVATION
	_record_generations[dense_slot] = generation
	_profiles[dense_slot] = profile
	_world_check_intervals[dense_slot] = world_check_interval
	_world_check_phases[dense_slot] = world_check_phase
	_world_step_indices[dense_slot] = 0
	_world_query_due_states[dense_slot] = 0
	_world_collision_anchors[dense_slot] = position
	_pending_target_instance_ids[dense_slot] = 0
	_pending_target_kinds[dense_slot] = TargetKind.NONE
	_pending_target_ids[dense_slot] = 0
	_pending_target_positions[dense_slot] = Vector2.ZERO
	_modes[dense_slot] = mode
	_handle_slots[dense_slot] = handle_slot
	_simulation_ticks[dense_slot] = 0
	_spawn_sequences[dense_slot] = _next_spawn_sequence
	_next_spawn_sequence += 1
	_dense_slots_by_handle_slot[handle_slot] = dense_slot

	_active_slot_count += 1
	_pending_activation_count += 1
	if mode == Mode.SHADOW:
		_shadow_slot_count += 1
	else:
		_data_slot_count += 1
	_metric_registrations += 1
	set_physics_process(true)
	return _encode_handle(handle_slot, generation)


## Multiplayer identity is assigned while the record is still inert. The
## write is atomic with the registered Profile cadence and never rewinds it.
func assign_projectile_identity(handle: int, projectile_id: int) -> bool:
	if projectile_id <= 0:
		return false
	var dense_slot := _resolve_dense_slot(handle)
	if dense_slot < 0 or _states[dense_slot] != SlotState.PENDING_ACTIVATION:
		return false
	var world_check_interval := int(_world_check_intervals[dense_slot])
	if world_check_interval <= 0:
		return false
	var current_projectile_id := int(_projectile_ids[dense_slot])
	if current_projectile_id > 0:
		if current_projectile_id != projectile_id:
			return false
		_source_event_ids[dense_slot] = projectile_id
		_world_check_phases[dense_slot] = (
			projectile_id % world_check_interval
		)
		return true
	_projectile_ids[dense_slot] = projectile_id
	_source_event_ids[dense_slot] = projectile_id
	_world_check_phases[dense_slot] = projectile_id % world_check_interval
	return true


func release_projectile(handle: int) -> bool:
	var dense_slot := _resolve_dense_slot(handle)
	if dense_slot < 0:
		return false
	_mark_tombstone(dense_slot)
	_metric_releases += 1
	set_physics_process(true)
	return true


func is_handle_live(handle: int) -> bool:
	return _resolve_dense_slot(handle) >= 0


func get_handle_slot(handle: int) -> int:
	if handle <= INVALID_HANDLE:
		return INVALID_SLOT
	return int(handle & HANDLE_SLOT_MASK) - 1


func get_handle_generation(handle: int) -> int:
	if handle <= INVALID_HANDLE:
		return 0
	return int(handle >> HANDLE_SLOT_BITS)


func get_mode() -> Mode:
	if _data_slot_count > 0:
		return Mode.DATA
	if _shadow_slot_count > 0:
		return Mode.SHADOW
	return Mode.DISABLED


func get_active_slot_count() -> int:
	return _active_slot_count


func get_dense_record_count() -> int:
	return _record_count


func get_tombstone_count() -> int:
	return _tombstone_count


func get_reserved_capacity() -> int:
	return _record_capacity


func has_physics_work() -> bool:
	return _record_count > 0


func get_handle_at_stable_index(index: int) -> int:
	if index < 0 or index >= _record_count:
		return INVALID_HANDLE
	if (
		_states[index] == SlotState.EMPTY
		or _states[index] == SlotState.TOMBSTONE
	):
		return INVALID_HANDLE
	return _encode_handle(
		int(_handle_slots[index]),
		int(_record_generations[index])
	)


func get_position(handle: int) -> Vector2:
	var dense_slot := _resolve_dense_slot(handle)
	return _positions[dense_slot] if dense_slot >= 0 else Vector2.ZERO


func get_direction(handle: int) -> Vector2:
	var dense_slot := _resolve_dense_slot(handle)
	return _directions[dense_slot] if dense_slot >= 0 else Vector2.ZERO


func get_remaining_lifetime(handle: int) -> float:
	var dense_slot := _resolve_dense_slot(handle)
	return _remaining_lifetimes[dense_slot] if dense_slot >= 0 else 0.0


func get_projectile_id(handle: int) -> int:
	var dense_slot := _resolve_dense_slot(handle)
	return int(_projectile_ids[dense_slot]) if dense_slot >= 0 else 0


func get_source_enemy_id(handle: int) -> int:
	var dense_slot := _resolve_dense_slot(handle)
	return int(_source_enemy_ids[dense_slot]) if dense_slot >= 0 else 0


func get_damage(handle: int) -> int:
	var dense_slot := _resolve_dense_slot(handle)
	return int(_damages[dense_slot]) if dense_slot >= 0 else 0


func get_damage_source_snapshot(handle: int) -> DamageSourceSnapshot:
	var dense_slot := _resolve_dense_slot(handle)
	return (
		_make_damage_source_snapshot(dense_slot)
		if dense_slot >= 0
		else null
	)


func get_spawn_physics_frame(handle: int) -> int:
	var dense_slot := _resolve_dense_slot(handle)
	return int(_spawn_physics_frames[dense_slot]) if dense_slot >= 0 else -1


func get_slot_state(handle: int) -> SlotState:
	var dense_slot := _resolve_dense_slot(handle)
	return (
		int(_states[dense_slot]) as SlotState
		if dense_slot >= 0
		else SlotState.EMPTY
	)


func get_slot_mode(handle: int) -> Mode:
	var dense_slot := _resolve_dense_slot(handle)
	return (
		int(_modes[dense_slot]) as Mode
		if dense_slot >= 0
		else Mode.DISABLED
	)


func get_slot_profile(handle: int) -> Profile:
	var dense_slot := _resolve_dense_slot(handle)
	return (
		int(_profiles[dense_slot]) as Profile
		if dense_slot >= 0
		else Profile.INVALID
	)


func get_world_check_interval(handle: int) -> int:
	var dense_slot := _resolve_dense_slot(handle)
	return int(_world_check_intervals[dense_slot]) if dense_slot >= 0 else 0


func get_world_check_phase(handle: int) -> int:
	var dense_slot := _resolve_dense_slot(handle)
	return int(_world_check_phases[dense_slot]) if dense_slot >= 0 else -1


func get_world_step_index(handle: int) -> int:
	var dense_slot := _resolve_dense_slot(handle)
	return int(_world_step_indices[dense_slot]) if dense_slot >= 0 else -1


func is_world_query_due(handle: int) -> bool:
	var dense_slot := _resolve_dense_slot(handle)
	return dense_slot >= 0 and _world_query_due_states[dense_slot] != 0


func get_spawn_sequence(handle: int) -> int:
	var dense_slot := _resolve_dense_slot(handle)
	return int(_spawn_sequences[dense_slot]) if dense_slot >= 0 else 0


func get_ak_collision_size() -> Vector2:
	return get_profile_collision_size(Profile.AK)


func get_ak_collision_center_forward_offset() -> float:
	return get_profile_collision_center_forward_offset(Profile.AK)


func get_profile_collision_size(profile: Profile) -> Vector2:
	match profile:
		Profile.AK:
			return AK_COLLISION_SIZE
		Profile.GUNNER, Profile.GUNNER_ELITE:
			return GUNNER_COLLISION_SIZE
		_:
			return Vector2.ZERO


func get_profile_collision_center_forward_offset(profile: Profile) -> float:
	match profile:
		Profile.AK:
			return AK_COLLISION_CENTER_FORWARD_OFFSET
		Profile.GUNNER, Profile.GUNNER_ELITE:
			return GUNNER_COLLISION_CENTER_FORWARD_OFFSET
		_:
			return 0.0


func get_profile_world_collision_mask(profile: Profile) -> int:
	match profile:
		Profile.AK:
			return AK_WORLD_COLLISION_MASK
		Profile.GUNNER, Profile.GUNNER_ELITE:
			return GUNNER_WORLD_COLLISION_MASK
		_:
			return 0


func get_profile_world_check_interval(profile: Profile) -> int:
	match profile:
		Profile.AK:
			return AK_WORLD_CHECK_INTERVAL
		Profile.GUNNER, Profile.GUNNER_ELITE:
			return GUNNER_WORLD_CHECK_INTERVAL
		_:
			return 0


func get_profile_source_type(profile: Profile) -> StringName:
	match profile:
		Profile.AK:
			return AK_SOURCE_TYPE
		Profile.GUNNER:
			return GUNNER_SOURCE_TYPE
		Profile.GUNNER_ELITE:
			return GUNNER_ELITE_SOURCE_TYPE
		_:
			return &""


func clear_completion_records() -> void:
	_completion_count = 0


func get_completion_count() -> int:
	return _completion_count


func get_completion_handle(index: int) -> int:
	return (
		int(_completion_handles[index])
		if index >= 0 and index < _completion_count
		else INVALID_HANDLE
	)


func get_completion_projectile_id(index: int) -> int:
	return (
		int(_completion_projectile_ids[index])
		if index >= 0 and index < _completion_count
		else 0
	)


func get_completion_position(index: int) -> Vector2:
	return (
		_completion_positions[index]
		if index >= 0 and index < _completion_count
		else Vector2.ZERO
	)


func get_completion_direction(index: int) -> Vector2:
	return (
		_completion_directions[index]
		if index >= 0 and index < _completion_count
		else Vector2.ZERO
	)


func get_completion_spawn_sequence(index: int) -> int:
	return (
		int(_completion_spawn_sequences[index])
		if index >= 0 and index < _completion_count
		else 0
	)


func get_completion_reason(index: int) -> CompletionReason:
	return (
		int(_completion_reasons[index]) as CompletionReason
		if index >= 0 and index < _completion_count
		else CompletionReason.NONE
	)


func get_completion_target_kind(index: int) -> TargetKind:
	return (
		int(_completion_target_kinds[index]) as TargetKind
		if index >= 0 and index < _completion_count
		else TargetKind.NONE
	)


func get_completion_target_id(index: int) -> int:
	return (
		int(_completion_target_ids[index])
		if index >= 0 and index < _completion_count
		else 0
	)


func get_completion_damage_applied(index: int) -> bool:
	return (
		_completion_damage_applied_states[index] != 0
		if index >= 0 and index < _completion_count
		else false
	)


func get_completion_mode(index: int) -> Mode:
	return (
		int(_completion_modes[index]) as Mode
		if index >= 0 and index < _completion_count
		else Mode.DISABLED
	)


func get_completion_profile(index: int) -> Profile:
	return (
		int(_completion_profiles[index]) as Profile
		if index >= 0 and index < _completion_count
		else Profile.INVALID
	)


func clear_difference_records() -> void:
	_difference_count = 0


func record_shadow_observation(
	handle: int,
	observed_position: Vector2,
	observed_remaining_lifetime: float
) -> bool:
	var dense_slot := _resolve_dense_slot(handle)
	if (
		dense_slot < 0
		or _modes[dense_slot] != Mode.SHADOW
		or not observed_position.is_finite()
		or not is_finite(observed_remaining_lifetime)
		or observed_remaining_lifetime < 0.0
		or _difference_count >= _difference_capacity
	):
		return false
	var difference_index := _difference_count
	_difference_count += 1
	_difference_handles[difference_index] = handle
	_difference_projectile_ids[difference_index] = _projectile_ids[dense_slot]
	_difference_position_deltas[difference_index] = (
		observed_position - _positions[dense_slot]
	)
	_difference_lifetime_deltas[difference_index] = (
		observed_remaining_lifetime - _remaining_lifetimes[dense_slot]
	)
	_difference_physics_frames[difference_index] = Engine.get_physics_frames()
	_metric_difference_records += 1
	return true


func get_difference_count() -> int:
	return _difference_count


func get_difference_handle(index: int) -> int:
	return (
		int(_difference_handles[index])
		if index >= 0 and index < _difference_count
		else INVALID_HANDLE
	)


func get_difference_projectile_id(index: int) -> int:
	return (
		int(_difference_projectile_ids[index])
		if index >= 0 and index < _difference_count
		else 0
	)


func get_difference_position_delta(index: int) -> Vector2:
	return (
		_difference_position_deltas[index]
		if index >= 0 and index < _difference_count
		else Vector2.ZERO
	)


func get_difference_lifetime_delta(index: int) -> float:
	return (
		_difference_lifetime_deltas[index]
		if index >= 0 and index < _difference_count
		else 0.0
	)


func get_difference_physics_frame(index: int) -> int:
	return (
		int(_difference_physics_frames[index])
		if index >= 0 and index < _difference_count
		else -1
	)


func prepare_for_runtime_teardown() -> void:
	if _teardown_prepared:
		return
	_teardown_prepared = true
	_teardown_count += 1
	clear()
	_enemy_damageable_spatial_index = null
	_combat_target_index = null
	_combat_relation_service = null
	_grid_pathfinder = null
	_combat_runtime = null
	_enemy_simulation_coordinator = null


func clear() -> void:
	set_physics_process(false)
	_positions.resize(0)
	_directions.resize(0)
	_speeds.resize(0)
	_remaining_lifetimes.resize(0)
	_damages.resize(0)
	_source_enemy_ids.resize(0)
	_projectile_ids.resize(0)
	_source_faction_ids.resize(0)
	_source_credit_peer_ids.resize(0)
	_source_instigator_entity_ids.resize(0)
	_source_event_ids.resize(0)
	_source_types.resize(0)
	_spawn_physics_frames.resize(0)
	_states.resize(0)
	_record_generations.resize(0)
	_profiles.resize(0)
	_world_check_intervals.resize(0)
	_world_check_phases.resize(0)
	_world_step_indices.resize(0)
	_world_query_due_states.resize(0)
	_world_collision_anchors.resize(0)
	_pending_target_instance_ids.resize(0)
	_pending_target_kinds.resize(0)
	_pending_target_ids.resize(0)
	_pending_target_positions.resize(0)
	_modes.resize(0)
	_handle_slots.resize(0)
	_simulation_ticks.resize(0)
	_spawn_sequences.resize(0)
	_handle_generations.resize(0)
	_dense_slots_by_handle_slot.resize(0)
	_free_handle_slots.resize(0)
	_completion_handles.resize(0)
	_completion_projectile_ids.resize(0)
	_completion_positions.resize(0)
	_completion_directions.resize(0)
	_completion_spawn_sequences.resize(0)
	_completion_reasons.resize(0)
	_completion_target_kinds.resize(0)
	_completion_target_ids.resize(0)
	_completion_damage_applied_states.resize(0)
	_completion_modes.resize(0)
	_completion_profiles.resize(0)
	_difference_handles.resize(0)
	_difference_projectile_ids.resize(0)
	_difference_position_deltas.resize(0)
	_difference_lifetime_deltas.resize(0)
	_difference_physics_frames.resize(0)
	_record_capacity = 0
	_record_count = 0
	_active_slot_count = 0
	_pending_activation_count = 0
	_shadow_slot_count = 0
	_data_slot_count = 0
	_tombstone_count = 0
	_handle_capacity = 0
	_next_handle_slot = 0
	_free_handle_count = 0
	_completion_capacity = 0
	_completion_count = 0
	_difference_capacity = 0
	_difference_count = 0
	_plant_query_results.clear()
	_enemy_query_results.clear()
	_endpoint_target = null
	_endpoint_target_kind = TargetKind.NONE
	_endpoint_target_id = 0
	_reset_kernel_metrics()


func get_metrics() -> Dictionary:
	return {
		"profile": PROFILE_AK,
		"mode": int(get_mode()),
		"active_slots": _active_slot_count,
		"pending_slots": _pending_activation_count,
		"shadow_slots": _shadow_slot_count,
		"data_slots": _data_slot_count,
		"dense_records": _record_count,
		"tombstones": _tombstone_count,
		"reserved_capacity": _record_capacity,
		"completion_records": _completion_count,
		"difference_records": _difference_count,
		"physics_processing": is_physics_processing(),
		"bound": is_bound(),
		"teardown_prepared": _teardown_prepared,
		"teardown_count": _teardown_count,
		"registrations": _metric_registrations,
		"registration_rejections": _metric_registration_rejections,
		"releases": _metric_releases,
		"physics_ticks": _metric_physics_ticks,
		"activation_skips": _metric_activation_skips,
		"activations": _metric_activations,
		"advances": _metric_advances,
		"lifetime_completions": _metric_lifetime_completions,
		"world_completions": _metric_world_completions,
		"target_completions": _metric_target_completions,
		"world_queries": _metric_world_queries,
		"world_certificates": _metric_world_certificates,
		"plant_broad_queries": _metric_plant_broad_queries,
		"plant_exact_queries": _metric_plant_exact_queries,
		"player_exact_queries": _metric_player_exact_queries,
		"enemy_broad_queries": _metric_enemy_broad_queries,
		"enemy_exact_queries": _metric_enemy_exact_queries,
		"damage_applications": _metric_damage_applications,
		"compactions": _metric_compactions,
		"compacted_tombstones": _metric_compacted_tombstones,
		"recorded_differences": _metric_difference_records,
	}


func _physics_process(delta: float) -> void:
	_completion_count = 0
	# SHADOW observations belong to the immediately preceding physics result.
	# Priority 4 clears them before advancing; the priority 5 legacy batch then
	# writes the current frame's comparison set for post-physics consumers.
	_difference_count = 0
	if _record_count <= 0:
		set_physics_process(false)
		return
	var valid_delta := is_finite(delta) and delta > 0.0
	var physics_frame := Engine.get_physics_frames()
	var initial_record_count := _record_count
	var resolve_contacts := (
		is_bound()
		and _combat_runtime.is_inside_tree()
		and _enemy_damageable_spatial_index != null
		and is_instance_valid(_enemy_damageable_spatial_index)
	)
	_metric_physics_ticks += 1
	for dense_slot in range(initial_record_count):
		var state := int(_states[dense_slot])
		if state == SlotState.EMPTY or state == SlotState.TOMBSTONE:
			continue
		if physics_frame <= int(_spawn_physics_frames[dense_slot]):
			_metric_activation_skips += 1
			continue
		if not valid_delta:
			continue
		if state == SlotState.PENDING_ACTIVATION:
			_states[dense_slot] = SlotState.ACTIVE
			_pending_activation_count = maxi(_pending_activation_count - 1, 0)
			_metric_activations += 1
			# Legacy Area2D can consume an overlap on its first live frame before
			# its first motion step. This is still endpoint-only: no path is swept.
			if resolve_contacts and _find_endpoint_target(
				dense_slot,
				_positions[dense_slot],
				_directions[dense_slot]
			):
				_complete_target_contact(dense_slot, _positions[dense_slot])
				continue
		if (
			resolve_contacts
			and _pending_target_kinds[dense_slot] != TargetKind.NONE
			and _resolve_pending_target_contact(dense_slot)
		):
			continue
		var current_check_phase := int(_world_step_indices[dense_slot])
		var world_check_interval := int(_world_check_intervals[dense_slot])
		_world_step_indices[dense_slot] = (
			current_check_phase + 1
		) % world_check_interval
		_world_query_due_states[dense_slot] = int(
			current_check_phase == int(_world_check_phases[dense_slot])
		)
		var remaining_after_step := _remaining_lifetimes[dense_slot] - delta
		var endpoint := _positions[dense_slot] + (
			_directions[dense_slot]
			* _speeds[dense_slot]
			* delta
		)
		_positions[dense_slot] = endpoint
		_remaining_lifetimes[dense_slot] = maxf(
			remaining_after_step,
			0.0
		)
		_simulation_ticks[dense_slot] += 1
		_metric_advances += 1

		var must_validate_world := (
			_world_query_due_states[dense_slot] != 0
			or remaining_after_step <= 0.0
		)
		if resolve_contacts and must_validate_world:
			if _resolve_world_contact(
				dense_slot,
				_world_collision_anchors[dense_slot],
				endpoint
			):
				_positions[dense_slot] = _world_hit_position
				_append_completion(
					dense_slot,
					CompletionReason.WORLD,
					TargetKind.WORLD,
					0,
					_world_hit_position,
					false
				)
				_mark_tombstone(dense_slot)
				_metric_world_completions += 1
				continue
			_world_collision_anchors[dense_slot] = endpoint
		if remaining_after_step <= 0.0:
			_append_completion(
				dense_slot,
				CompletionReason.LIFETIME,
				TargetKind.NONE,
				0,
				endpoint,
				false
			)
			_mark_tombstone(dense_slot)
			_metric_lifetime_completions += 1
			continue

		if resolve_contacts and _find_endpoint_target(
			dense_slot,
			endpoint,
			_directions[dense_slot]
		):
			_cache_pending_target(dense_slot, endpoint)

	if _tombstone_count > 0:
		_stable_compact_tombstones()
	set_physics_process(_record_count > 0)


func _resolve_world_contact(
	dense_slot: int,
	from_position: Vector2,
	to_position: Vector2
) -> bool:
	_world_hit_position = to_position
	if from_position.is_equal_approx(to_position):
		return false
	if (
		world_collision_certificate_enabled
		and _grid_pathfinder != null
		and is_instance_valid(_grid_pathfinder)
		and _grid_pathfinder.is_world_collision_segment_certified_clear(
			from_position,
			to_position
		)
	):
		_metric_world_certificates += 1
		return false
	_world_ray_query.from = from_position
	_world_ray_query.to = to_position
	_world_ray_query.collision_mask = get_profile_world_collision_mask(
		int(_profiles[dense_slot]) as Profile
	)
	_metric_world_queries += 1
	var hit := _combat_runtime.get_world_2d().direct_space_state.intersect_ray(
		_world_ray_query
	)
	if hit.is_empty():
		return false
	_world_hit_position = hit.get(&"position", to_position) as Vector2
	return true


func _find_endpoint_target(
	dense_slot: int,
	endpoint: Vector2,
	direction: Vector2
) -> bool:
	_endpoint_target = null
	_endpoint_target_kind = TargetKind.NONE
	_endpoint_target_id = 0
	var profile := int(_profiles[dense_slot]) as Profile
	var projectile_shape := _get_profile_collision_shape(profile)
	if projectile_shape == null:
		return false
	var projectile_transform := Transform2D(
		direction.angle(),
		endpoint + direction * get_profile_collision_center_forward_offset(profile)
	)
	if _find_endpoint_player(dense_slot, projectile_transform):
		return true
	if _find_endpoint_plant(dense_slot, projectile_transform, direction):
		return true
	return _find_endpoint_enemy(dense_slot, projectile_transform, direction)


func _cache_pending_target(dense_slot: int, endpoint: Vector2) -> void:
	_pending_target_instance_ids[dense_slot] = (
		_endpoint_target.get_instance_id()
		if _endpoint_target != null
		else 0
	)
	_pending_target_kinds[dense_slot] = _endpoint_target_kind
	_pending_target_ids[dense_slot] = _endpoint_target_id
	_pending_target_positions[dense_slot] = endpoint


func _resolve_pending_target_contact(dense_slot: int) -> bool:
	var target_position := _pending_target_positions[dense_slot]
	# This reproduces Area2D's one-physics-flush delivery: the endpoint was
	# observed last tick, but the unchecked world suffix is adjudicated now.
	if _resolve_world_contact(
		dense_slot,
		_world_collision_anchors[dense_slot],
		target_position
	):
		_positions[dense_slot] = _world_hit_position
		_append_completion(
			dense_slot,
			CompletionReason.WORLD,
			TargetKind.WORLD,
			0,
			_world_hit_position,
			false
		)
		_clear_pending_target(dense_slot)
		_mark_tombstone(dense_slot)
		_metric_world_completions += 1
		return true
	_world_collision_anchors[dense_slot] = target_position

	var target_kind := int(_pending_target_kinds[dense_slot])
	var target := instance_from_id(
		int(_pending_target_instance_ids[dense_slot])
	) as Node2D
	if target_kind == TargetKind.PLANT:
		var plant := target as PlantDefense
		if (
			plant == null
			or not is_instance_valid(plant)
			or plant.is_queued_for_deletion()
			or plant.is_dead
			or plant.is_removing
		):
			_clear_pending_target(dense_slot)
			return false
	elif target_kind == TargetKind.PLAYER:
		var player := target as Player
		if (
			player == null
			or not is_instance_valid(player)
			or player.is_queued_for_deletion()
			or player.is_dead
		):
			_clear_pending_target(dense_slot)
			return false
	elif target_kind == TargetKind.ENEMY:
		var enemy := target as Enemy
		if (
			enemy == null
			or not is_instance_valid(enemy)
			or enemy.is_queued_for_deletion()
			or enemy.is_dead
		):
			_clear_pending_target(dense_slot)
			return false
	else:
		_clear_pending_target(dense_slot)
		return false
	if not _is_target_hostile_for_slot(dense_slot, target):
		# Legacy Area2D contacts also leave a non-hostile projectile live. Recheck
		# after the one-tick delivery delay because the target may have changed
		# faction since the endpoint overlap was cached.
		_clear_pending_target(dense_slot)
		return false

	_endpoint_target = target
	_endpoint_target_kind = target_kind
	_endpoint_target_id = int(_pending_target_ids[dense_slot])
	_clear_pending_target(dense_slot)
	_complete_target_contact(dense_slot, target_position)
	return true


func _clear_pending_target(dense_slot: int) -> void:
	_pending_target_instance_ids[dense_slot] = 0
	_pending_target_kinds[dense_slot] = TargetKind.NONE
	_pending_target_ids[dense_slot] = 0
	_pending_target_positions[dense_slot] = Vector2.ZERO


func _get_profile_collision_shape(profile: Profile) -> RectangleShape2D:
	match profile:
		Profile.AK:
			return _ak_collision_shape
		Profile.GUNNER, Profile.GUNNER_ELITE:
			return _gunner_collision_shape
		_:
			return null


func _find_endpoint_player(
	dense_slot: int,
	projectile_transform: Transform2D
) -> bool:
	var projectile_shape := _get_profile_collision_shape(
		int(_profiles[dense_slot]) as Profile
	)
	if projectile_shape == null:
		return false
	var local_player := _combat_runtime.player
	_consider_endpoint_player(
		dense_slot,
		local_player,
		_get_player_stable_id(local_player, _combat_runtime.multiplayer_local_peer_id),
		projectile_shape,
		projectile_transform
	)
	for peer_id_variant in _combat_runtime.peer_players:
		var player := _combat_runtime.peer_players.get(peer_id_variant) as Player
		if player == local_player:
			continue
		_consider_endpoint_player(
			dense_slot,
			player,
			_get_player_stable_id(player, int(peer_id_variant)),
			projectile_shape,
			projectile_transform
		)
	return _endpoint_target != null


func _consider_endpoint_player(
	dense_slot: int,
	player: Player,
	stable_id: int,
	projectile_shape: RectangleShape2D,
	projectile_transform: Transform2D
) -> void:
	if (
		player == null
		or not is_instance_valid(player)
		or player.is_queued_for_deletion()
		or player.is_dead
		or not _is_target_hostile_for_slot(dense_slot, player)
		or player.collision_shape == null
		or player.collision_shape.disabled
		or player.collision_shape.shape == null
	):
		return
	_metric_player_exact_queries += 1
	if not projectile_shape.collide(
		projectile_transform,
		player.collision_shape.shape,
		player.collision_shape.global_transform
	):
		return
	var resolved_stable_id := stable_id
	if resolved_stable_id <= 0:
		resolved_stable_id = int(player.get_instance_id())
	if (
		_endpoint_target == null
		or resolved_stable_id < _endpoint_target_id
		or (
			resolved_stable_id == _endpoint_target_id
			and player.get_instance_id() < _endpoint_target.get_instance_id()
		)
	):
		_endpoint_target = player
		_endpoint_target_kind = TargetKind.PLAYER
		_endpoint_target_id = resolved_stable_id


func _find_endpoint_plant(
	dense_slot: int,
	projectile_transform: Transform2D,
	direction: Vector2
) -> bool:
	var profile := int(_profiles[dense_slot]) as Profile
	var projectile_shape := _get_profile_collision_shape(profile)
	var collision_size := get_profile_collision_size(profile)
	if projectile_shape == null or collision_size.is_zero_approx():
		return false
	var half_size := collision_size * 0.5
	var world_extents := Vector2(
		absf(direction.x) * half_size.x + absf(direction.y) * half_size.y,
		absf(direction.y) * half_size.x + absf(direction.x) * half_size.y
	)
	var center := projectile_transform.origin
	_metric_plant_broad_queries += 1
	_enemy_damageable_spatial_index.query_world_aabb_into(
		Rect2(center - world_extents, world_extents * 2.0),
		_plant_query_results
	)
	var selected_instance_id := 0
	for candidate_variant in _plant_query_results:
		var plant := candidate_variant as PlantDefense
		if (
			plant == null
			or not is_instance_valid(plant)
			or plant.is_queued_for_deletion()
			or plant.is_dead
			or plant.is_removing
			or not _is_target_hostile_for_slot(dense_slot, plant)
		):
			continue
		_metric_plant_exact_queries += 1
		if not _enemy_damageable_spatial_index.damageable_overlaps_shape(
			plant,
			projectile_shape,
			projectile_transform
		):
			continue
		var stable_id := int(plant.get_meta(&"net_id", 0))
		if stable_id <= 0:
			stable_id = int(plant.get_instance_id())
		var instance_id := int(plant.get_instance_id())
		if (
			_endpoint_target == null
			or stable_id < _endpoint_target_id
			or (
				stable_id == _endpoint_target_id
				and instance_id < selected_instance_id
			)
		):
			_endpoint_target = plant
			_endpoint_target_kind = TargetKind.PLANT
			_endpoint_target_id = stable_id
			selected_instance_id = instance_id
	return _endpoint_target != null


func _find_endpoint_enemy(
	dense_slot: int,
	projectile_transform: Transform2D,
	direction: Vector2
) -> bool:
	if _combat_target_index == null:
		return false
	var profile := int(_profiles[dense_slot]) as Profile
	var projectile_shape := _get_profile_collision_shape(profile)
	var collision_size := get_profile_collision_size(profile)
	if projectile_shape == null or collision_size.is_zero_approx():
		return false
	var half_size := collision_size * 0.5
	var world_extents := Vector2(
		absf(direction.x) * half_size.x + absf(direction.y) * half_size.y,
		absf(direction.y) * half_size.x + absf(direction.x) * half_size.y
	)
	var center := projectile_transform.origin
	var maximum_target_extent := (
		_combat_target_index.get_maximum_body_collision_extent_radius()
	)
	var query_aabb := Rect2(
		center - world_extents,
		world_extents * 2.0
	).grow(maximum_target_extent + BROAD_PHASE_CLOSED_BOUNDARY_EPSILON)
	var source_enemy := _get_indexed_source_enemy(dense_slot)
	_metric_enemy_broad_queries += 1
	_combat_target_index.query_hostile_world_aabb_unordered_into(
		query_aabb,
		int(_source_faction_ids[dense_slot]),
		_enemy_query_results,
		source_enemy,
		_combat_relation_service
	)
	var selected_instance_id := 0
	for enemy in _enemy_query_results:
		if (
			enemy == null
			or not is_instance_valid(enemy)
			or enemy.is_queued_for_deletion()
			or enemy.is_dead
			or _is_source_enemy_for_slot(dense_slot, enemy)
			or not _is_target_hostile_for_slot(dense_slot, enemy)
		):
			continue
		_metric_enemy_exact_queries += 1
		if not _enemy_body_overlaps_projectile(
			enemy,
			projectile_shape,
			projectile_transform
		):
			continue
		var stable_id := _get_enemy_stable_id(enemy)
		var instance_id := int(enemy.get_instance_id())
		if (
			_endpoint_target == null
			or stable_id < _endpoint_target_id
			or (
				stable_id == _endpoint_target_id
				and instance_id < selected_instance_id
			)
		):
			_endpoint_target = enemy
			_endpoint_target_kind = TargetKind.ENEMY
			_endpoint_target_id = stable_id
			selected_instance_id = instance_id
	return _endpoint_target != null


func _enemy_body_overlaps_projectile(
	enemy: Enemy,
	projectile_shape: RectangleShape2D,
	projectile_transform: Transform2D
) -> bool:
	for shape_node in enemy.body_collision_shapes:
		if (
			shape_node == null
			or not is_instance_valid(shape_node)
			or shape_node.disabled
			or shape_node.shape == null
		):
			continue
		if projectile_shape.collide(
			projectile_transform,
			shape_node.shape,
			shape_node.global_transform
		):
			return true
	return false


func _get_indexed_source_enemy(dense_slot: int) -> Enemy:
	if _combat_target_index == null:
		return null
	var source_enemy_id := int(_source_enemy_ids[dense_slot])
	return (
		_combat_target_index.get_enemy(source_enemy_id)
		if source_enemy_id > 0
		else null
	)


func _is_source_enemy_for_slot(dense_slot: int, enemy: Enemy) -> bool:
	if enemy == null:
		return false
	var source_enemy_id := int(_source_enemy_ids[dense_slot])
	if source_enemy_id <= 0:
		return false
	return (
		_get_enemy_stable_id(enemy) == source_enemy_id
		or int(enemy.get_instance_id()) == source_enemy_id
	)


func _get_enemy_stable_id(enemy: Enemy) -> int:
	if enemy == null:
		return 0
	var stable_id := enemy.combat_target_index_net_id
	if stable_id <= 0:
		stable_id = int(enemy.get_meta(&"net_id", 0))
	if stable_id <= 0:
		stable_id = int(enemy.get_instance_id())
	return stable_id


func _is_target_hostile_for_slot(
	dense_slot: int,
	target: Node
) -> bool:
	if (
		dense_slot < 0
		or dense_slot >= _record_count
		or target == null
		or not is_instance_valid(target)
		or not target.has_method(&"get_combat_faction_id")
	):
		return false
	var source_faction_id := int(_source_faction_ids[dense_slot])
	var target_faction_id := int(target.call(&"get_combat_faction_id"))
	if (
		not CombatRelationService.is_valid_faction_id(source_faction_id)
		or not CombatRelationService.is_valid_faction_id(target_faction_id)
	):
		return false
	return (
		_combat_relation_service.is_hostile(
			source_faction_id,
			target_faction_id
		)
		if _combat_relation_service != null
		else CombatRelationService.is_default_hostile(
			source_faction_id,
			target_faction_id
		)
	)


func _get_player_stable_id(player: Player, roster_peer_id: int) -> int:
	if roster_peer_id > 0:
		return roster_peer_id
	if player != null and player.peer_id > 0:
		return player.peer_id
	if player == _combat_runtime.player:
		return 1
	return 0


func _complete_target_contact(dense_slot: int, position: Vector2) -> void:
	var damage_applied := false
	if (
		_modes[dense_slot] == Mode.DATA
		and _combat_runtime.runtime_mode
			!= CombatRuntimeBase.RuntimeMode.CLIENT_VIEW
		and _damages[dense_slot] > 0
	):
		damage_applied = _apply_authoritative_damage(dense_slot)
		if damage_applied:
			_metric_damage_applications += 1
	_append_completion(
		dense_slot,
		CompletionReason.TARGET,
		_endpoint_target_kind,
		_endpoint_target_id,
		position,
		damage_applied
	)
	_mark_tombstone(dense_slot)
	_metric_target_completions += 1


func _apply_authoritative_damage(dense_slot: int) -> bool:
	var source_type := StringName(_source_types[dense_slot])
	if source_type.is_empty():
		return false
	if _endpoint_target_kind == TargetKind.PLANT:
		var plant := _endpoint_target as PlantDefense
		return (
			plant != null
			and not plant.is_dead
			and not plant.is_removing
			and plant.apply_combat_damage(
				_make_damage_request(dense_slot)
			).accepted
		)
	if _endpoint_target_kind == TargetKind.ENEMY:
		var enemy := _endpoint_target as Enemy
		return (
			enemy != null
			and not enemy.is_dead
			and enemy.apply_combat_damage(
				_make_damage_request(dense_slot)
			).accepted
		)
	if _endpoint_target_kind == TargetKind.PLAYER:
		var player := _endpoint_target as Player
		if player == null or player.is_dead:
			return false
		if (
			_combat_runtime.runtime_mode
			== CombatRuntimeBase.RuntimeMode.SINGLEPLAYER
		):
			return player.apply_combat_damage(
				_make_damage_request(dense_slot)
			).accepted
		var projectile_id := int(_projectile_ids[dense_slot])
		var source_snapshot := _make_damage_source_snapshot(dense_slot)
		var gateway := _combat_runtime.get_multiplayer_gameplay_gateway()
		return (
			projectile_id > 0
			and player.peer_id > 0
			and gateway != null
			and is_instance_valid(gateway)
			and gateway.request_player_damage(
				projectile_id,
				player.peer_id,
				int(_damages[dense_slot]),
				source_type,
				EnemyConfig.DamageType.PHYSICAL,
				-_directions[dense_slot],
				true,
				false,
				source_snapshot
			)
		)
	return false


func _make_damage_request(dense_slot: int) -> DamageRequest:
	var source_type := StringName(_source_types[dense_slot])
	return (
		DamageRequest.new(
			int(_damages[dense_slot]),
			CombatTypes.DamageType.PHYSICAL
		)
		.with_stable_source(
			int(_source_enemy_ids[dense_slot]),
			int(_projectile_ids[dense_slot]),
			source_type,
			_make_damage_source_snapshot(dense_slot)
		)
		.with_directions(
			_directions[dense_slot],
			-_directions[dense_slot]
		)
		.with_flag(CombatTypes.DamageFlag.RANGED)
	)


func _make_damage_source_snapshot(dense_slot: int) -> DamageSourceSnapshot:
	return DamageSourceSnapshot.create(
		int(_source_faction_ids[dense_slot]),
		int(_source_credit_peer_ids[dense_slot]),
		int(_source_instigator_entity_ids[dense_slot]),
		int(_source_event_ids[dense_slot]),
		StringName(_source_types[dense_slot])
	)


func _write_damage_source_snapshot(
	dense_slot: int,
	profile: int,
	source_enemy_id: int,
	projectile_id: int,
	damage_source_snapshot: DamageSourceSnapshot
) -> void:
	var profile_source_type := get_profile_source_type(profile as Profile)
	if damage_source_snapshot != null:
		_source_faction_ids[dense_slot] = (
			damage_source_snapshot.source_faction_id
		)
		_source_credit_peer_ids[dense_slot] = (
			damage_source_snapshot.credit_peer_id
		)
		_source_instigator_entity_ids[dense_slot] = (
			damage_source_snapshot.instigator_entity_id
		)
		_source_event_ids[dense_slot] = (
			projectile_id
			if projectile_id > 0
			else damage_source_snapshot.event_source_id
		)
		_source_types[dense_slot] = String(
			damage_source_snapshot.source_type
			if damage_source_snapshot.source_type != &""
			else profile_source_type
		)
		return

	# Optional snapshots keep old fixtures source-compatible. The profile fallback
	# is nevertheless explicit and hostile, so a data record can never inherit a
	# player-owned default merely because it has no live projectile Node.
	_source_faction_ids[dense_slot] = CombatRelationService.HOSTILE_WAVE
	_source_credit_peer_ids[dense_slot] = 0
	_source_instigator_entity_ids[dense_slot] = source_enemy_id
	_source_event_ids[dense_slot] = projectile_id
	_source_types[dense_slot] = String(profile_source_type)


func _is_valid_registration(
	mode: int,
	profile: int,
	position: Vector2,
	direction: Vector2,
	speed: float,
	lifetime: float,
	damage: int,
	source_enemy_id: int,
	projectile_id: int,
	world_check_interval: int,
	world_check_phase: int,
	damage_source_snapshot: DamageSourceSnapshot
) -> bool:
	var supported_profile := (
		profile == Profile.AK
		or profile == Profile.GUNNER
		or profile == Profile.GUNNER_ELITE
	)
	var expected_world_check_interval := (
		get_profile_world_check_interval(profile as Profile)
		if supported_profile
		else 0
	)
	return (
		not _teardown_prepared
		and (mode == Mode.SHADOW or mode == Mode.DATA)
		and supported_profile
		and position.is_finite()
		and direction.is_finite()
		and direction.length_squared() > 0.0
		and is_finite(speed)
		and speed >= 0.0
		and is_finite(lifetime)
		and lifetime > 0.0
		and damage >= 0
		and source_enemy_id >= 0
		and projectile_id >= 0
		and world_check_interval == expected_world_check_interval
		and world_check_phase >= 0
		and world_check_phase < world_check_interval
		and (
			damage_source_snapshot == null
			or damage_source_snapshot.is_valid()
		)
	)


func _ensure_projectile_capacity(required_capacity: int) -> bool:
	if required_capacity <= _record_capacity:
		return true
	var grown_capacity := maxi(_record_capacity, MIN_GROWTH_CAPACITY)
	while grown_capacity < required_capacity:
		grown_capacity = maxi(grown_capacity * 2, required_capacity)
	return reserve_projectile_capacity(grown_capacity)


func _resize_record_storage(new_capacity: int) -> void:
	var previous_capacity := _record_capacity
	_positions.resize(new_capacity)
	_directions.resize(new_capacity)
	_speeds.resize(new_capacity)
	_remaining_lifetimes.resize(new_capacity)
	_damages.resize(new_capacity)
	_source_enemy_ids.resize(new_capacity)
	_projectile_ids.resize(new_capacity)
	_source_faction_ids.resize(new_capacity)
	_source_credit_peer_ids.resize(new_capacity)
	_source_instigator_entity_ids.resize(new_capacity)
	_source_event_ids.resize(new_capacity)
	_source_types.resize(new_capacity)
	_spawn_physics_frames.resize(new_capacity)
	_states.resize(new_capacity)
	_record_generations.resize(new_capacity)
	_profiles.resize(new_capacity)
	_world_check_intervals.resize(new_capacity)
	_world_check_phases.resize(new_capacity)
	_world_step_indices.resize(new_capacity)
	_world_query_due_states.resize(new_capacity)
	_world_collision_anchors.resize(new_capacity)
	_pending_target_instance_ids.resize(new_capacity)
	_pending_target_kinds.resize(new_capacity)
	_pending_target_ids.resize(new_capacity)
	_pending_target_positions.resize(new_capacity)
	_modes.resize(new_capacity)
	_handle_slots.resize(new_capacity)
	_simulation_ticks.resize(new_capacity)
	_spawn_sequences.resize(new_capacity)
	for dense_slot in range(previous_capacity, new_capacity):
		_states[dense_slot] = SlotState.EMPTY
		_handle_slots[dense_slot] = INVALID_SLOT
	_record_capacity = new_capacity


func _resize_handle_storage(new_capacity: int) -> void:
	var previous_capacity := _handle_capacity
	_handle_generations.resize(new_capacity)
	_dense_slots_by_handle_slot.resize(new_capacity)
	_free_handle_slots.resize(new_capacity)
	for handle_slot in range(previous_capacity, new_capacity):
		_handle_generations[handle_slot] = 0
		_dense_slots_by_handle_slot[handle_slot] = INVALID_SLOT
		_free_handle_slots[handle_slot] = INVALID_SLOT
	_handle_capacity = new_capacity


func _resize_completion_storage(new_capacity: int) -> void:
	_completion_handles.resize(new_capacity)
	_completion_projectile_ids.resize(new_capacity)
	_completion_positions.resize(new_capacity)
	_completion_directions.resize(new_capacity)
	_completion_spawn_sequences.resize(new_capacity)
	_completion_reasons.resize(new_capacity)
	_completion_target_kinds.resize(new_capacity)
	_completion_target_ids.resize(new_capacity)
	_completion_damage_applied_states.resize(new_capacity)
	_completion_modes.resize(new_capacity)
	_completion_profiles.resize(new_capacity)
	_completion_capacity = new_capacity


func _resize_difference_storage(new_capacity: int) -> void:
	_difference_handles.resize(new_capacity)
	_difference_projectile_ids.resize(new_capacity)
	_difference_position_deltas.resize(new_capacity)
	_difference_lifetime_deltas.resize(new_capacity)
	_difference_physics_frames.resize(new_capacity)
	_difference_capacity = new_capacity


func _acquire_handle_slot() -> int:
	var handle_slot := INVALID_SLOT
	if _free_handle_count > 0:
		_free_handle_count -= 1
		handle_slot = int(_free_handle_slots[_free_handle_count])
		_free_handle_slots[_free_handle_count] = INVALID_SLOT
	else:
		if _next_handle_slot >= _handle_capacity:
			return INVALID_SLOT
		handle_slot = _next_handle_slot
		_next_handle_slot += 1
	if _next_handle_generation > MAX_HANDLE_GENERATION:
		return INVALID_SLOT
	_handle_generations[handle_slot] = _next_handle_generation
	_next_handle_generation += 1
	return handle_slot


func _encode_handle(handle_slot: int, generation: int) -> int:
	if handle_slot < 0 or generation <= 0:
		return INVALID_HANDLE
	return (generation << HANDLE_SLOT_BITS) | (handle_slot + 1)


func _resolve_dense_slot(handle: int) -> int:
	var handle_slot := get_handle_slot(handle)
	var generation := get_handle_generation(handle)
	if (
		handle_slot < 0
		or handle_slot >= _next_handle_slot
		or generation <= 0
		or generation != int(_handle_generations[handle_slot])
	):
		return INVALID_SLOT
	var dense_slot := int(_dense_slots_by_handle_slot[handle_slot])
	if (
		dense_slot < 0
		or dense_slot >= _record_count
		or _states[dense_slot] == SlotState.EMPTY
		or _states[dense_slot] == SlotState.TOMBSTONE
		or int(_handle_slots[dense_slot]) != handle_slot
		or int(_record_generations[dense_slot]) != generation
	):
		return INVALID_SLOT
	return dense_slot


func _append_completion(
	dense_slot: int,
	reason: CompletionReason,
	target_kind: TargetKind,
	target_id: int,
	position: Vector2,
	damage_applied: bool
) -> void:
	if _completion_count >= _completion_capacity:
		push_error("RapidFireSimulationService completion storage invariant failed.")
		return
	var completion_index := _completion_count
	_completion_count += 1
	_completion_handles[completion_index] = _encode_handle(
		int(_handle_slots[dense_slot]),
		int(_record_generations[dense_slot])
	)
	_completion_projectile_ids[completion_index] = _projectile_ids[dense_slot]
	_completion_positions[completion_index] = position
	_completion_directions[completion_index] = _directions[dense_slot]
	_completion_spawn_sequences[completion_index] = _spawn_sequences[dense_slot]
	_completion_reasons[completion_index] = reason
	_completion_target_kinds[completion_index] = target_kind
	_completion_target_ids[completion_index] = target_id
	_completion_damage_applied_states[completion_index] = int(damage_applied)
	_completion_modes[completion_index] = _modes[dense_slot]
	_completion_profiles[completion_index] = _profiles[dense_slot]


func _mark_tombstone(dense_slot: int) -> void:
	var state := int(_states[dense_slot])
	if state == SlotState.EMPTY or state == SlotState.TOMBSTONE:
		return
	if state == SlotState.PENDING_ACTIVATION:
		_pending_activation_count = maxi(_pending_activation_count - 1, 0)
	var mode := int(_modes[dense_slot])
	if mode == Mode.SHADOW:
		_shadow_slot_count = maxi(_shadow_slot_count - 1, 0)
	elif mode == Mode.DATA:
		_data_slot_count = maxi(_data_slot_count - 1, 0)
	_states[dense_slot] = SlotState.TOMBSTONE
	_active_slot_count = maxi(_active_slot_count - 1, 0)
	_tombstone_count += 1

	var handle_slot := int(_handle_slots[dense_slot])
	var generation := int(_record_generations[dense_slot])
	if (
		handle_slot >= 0
		and handle_slot < _handle_capacity
		and int(_dense_slots_by_handle_slot[handle_slot]) == dense_slot
		and int(_handle_generations[handle_slot]) == generation
	):
		_dense_slots_by_handle_slot[handle_slot] = INVALID_SLOT
		if _free_handle_count < _free_handle_slots.size():
			_free_handle_slots[_free_handle_count] = handle_slot
			_free_handle_count += 1


func _stable_compact_tombstones() -> void:
	var previous_record_count := _record_count
	var previous_tombstone_count := _tombstone_count
	var write_slot := 0
	for read_slot in range(previous_record_count):
		if _states[read_slot] == SlotState.TOMBSTONE:
			continue
		if write_slot != read_slot:
			_copy_record(read_slot, write_slot)
		var handle_slot := int(_handle_slots[write_slot])
		if handle_slot >= 0:
			_dense_slots_by_handle_slot[handle_slot] = write_slot
		write_slot += 1
	for clear_slot in range(write_slot, previous_record_count):
		_clear_record_row(clear_slot)
	_record_count = write_slot
	_tombstone_count = 0
	_metric_compactions += 1
	_metric_compacted_tombstones += previous_tombstone_count


func _copy_record(from_slot: int, to_slot: int) -> void:
	_positions[to_slot] = _positions[from_slot]
	_directions[to_slot] = _directions[from_slot]
	_speeds[to_slot] = _speeds[from_slot]
	_remaining_lifetimes[to_slot] = _remaining_lifetimes[from_slot]
	_damages[to_slot] = _damages[from_slot]
	_source_enemy_ids[to_slot] = _source_enemy_ids[from_slot]
	_projectile_ids[to_slot] = _projectile_ids[from_slot]
	_source_faction_ids[to_slot] = _source_faction_ids[from_slot]
	_source_credit_peer_ids[to_slot] = _source_credit_peer_ids[from_slot]
	_source_instigator_entity_ids[to_slot] = (
		_source_instigator_entity_ids[from_slot]
	)
	_source_event_ids[to_slot] = _source_event_ids[from_slot]
	_source_types[to_slot] = _source_types[from_slot]
	_spawn_physics_frames[to_slot] = _spawn_physics_frames[from_slot]
	_states[to_slot] = _states[from_slot]
	_record_generations[to_slot] = _record_generations[from_slot]
	_profiles[to_slot] = _profiles[from_slot]
	_world_check_intervals[to_slot] = _world_check_intervals[from_slot]
	_world_check_phases[to_slot] = _world_check_phases[from_slot]
	_world_step_indices[to_slot] = _world_step_indices[from_slot]
	_world_query_due_states[to_slot] = _world_query_due_states[from_slot]
	_world_collision_anchors[to_slot] = _world_collision_anchors[from_slot]
	_pending_target_instance_ids[to_slot] = _pending_target_instance_ids[from_slot]
	_pending_target_kinds[to_slot] = _pending_target_kinds[from_slot]
	_pending_target_ids[to_slot] = _pending_target_ids[from_slot]
	_pending_target_positions[to_slot] = _pending_target_positions[from_slot]
	_modes[to_slot] = _modes[from_slot]
	_handle_slots[to_slot] = _handle_slots[from_slot]
	_simulation_ticks[to_slot] = _simulation_ticks[from_slot]
	_spawn_sequences[to_slot] = _spawn_sequences[from_slot]


func _clear_record_row(dense_slot: int) -> void:
	_positions[dense_slot] = Vector2.ZERO
	_directions[dense_slot] = Vector2.ZERO
	_speeds[dense_slot] = 0.0
	_remaining_lifetimes[dense_slot] = 0.0
	_damages[dense_slot] = 0
	_source_enemy_ids[dense_slot] = 0
	_projectile_ids[dense_slot] = 0
	_source_faction_ids[dense_slot] = CombatRelationService.NEUTRAL
	_source_credit_peer_ids[dense_slot] = 0
	_source_instigator_entity_ids[dense_slot] = 0
	_source_event_ids[dense_slot] = 0
	_source_types[dense_slot] = ""
	_spawn_physics_frames[dense_slot] = 0
	_states[dense_slot] = SlotState.EMPTY
	_record_generations[dense_slot] = 0
	_profiles[dense_slot] = Profile.INVALID
	_world_check_intervals[dense_slot] = 0
	_world_check_phases[dense_slot] = 0
	_world_step_indices[dense_slot] = 0
	_world_query_due_states[dense_slot] = 0
	_world_collision_anchors[dense_slot] = Vector2.ZERO
	_pending_target_instance_ids[dense_slot] = 0
	_pending_target_kinds[dense_slot] = TargetKind.NONE
	_pending_target_ids[dense_slot] = 0
	_pending_target_positions[dense_slot] = Vector2.ZERO
	_modes[dense_slot] = Mode.DISABLED
	_handle_slots[dense_slot] = INVALID_SLOT
	_simulation_ticks[dense_slot] = 0
	_spawn_sequences[dense_slot] = 0


func _reset_kernel_metrics() -> void:
	_metric_registrations = 0
	_metric_registration_rejections = 0
	_metric_releases = 0
	_metric_physics_ticks = 0
	_metric_activation_skips = 0
	_metric_activations = 0
	_metric_advances = 0
	_metric_lifetime_completions = 0
	_metric_world_completions = 0
	_metric_target_completions = 0
	_metric_world_queries = 0
	_metric_world_certificates = 0
	_metric_plant_broad_queries = 0
	_metric_plant_exact_queries = 0
	_metric_player_exact_queries = 0
	_metric_enemy_broad_queries = 0
	_metric_enemy_exact_queries = 0
	_metric_damage_applications = 0
	_metric_compactions = 0
	_metric_compacted_tombstones = 0
	_metric_difference_records = 0


func _exit_tree() -> void:
	prepare_for_runtime_teardown()
