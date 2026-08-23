extends Node
class_name FireSorcererVolleySimulationService

## Dense, data-oriented simulation for the three independently moving balls in
## a Fire Sorcerer volley. Handles remain stable while dense rows compact.

enum Mode {
	INVALID,
	SHADOW,
	DATA,
	REPLICA,
}

enum Profile {
	INVALID,
	NORMAL,
	ELITE,
}

enum SlotState {
	EMPTY,
	PENDING_ACTIVATION,
	ACTIVE,
	TOMBSTONE,
}

enum EffectKind {
	NONE,
	IMPACT,
	EXPIRE,
}

enum TargetKind {
	NONE,
	PLAYER,
	PLANT,
	ENEMY,
}

const BALL_COUNT := 3
const ALL_BALLS_MASK := (1 << BALL_COUNT) - 1
const INVALID_HANDLE := 0
const INVALID_SLOT := -1
const HANDLE_SLOT_BITS := 32
const HANDLE_SLOT_MASK := 0xFFFFFFFF
const MAX_HANDLE_GENERATION := 0x7FFFFFFF
const COMPENSATION_STEP := 1.0 / 60.0
const TARGET_REFRESH_INTERVAL := 0.35
const IMPACT_EFFECT_DURATION := 4.0 / 12.0
const EXPIRE_EFFECT_DURATION := 4.0 / 12.0
const BALL_COLLISION_RADIUS := 3.5
const BALL_COLLISION_FORWARD_OFFSET := 5.0
const WORLD_COLLISION_MASK := 1
const DAMAGEABLE_COLLISION_MASK := 2 | 4 | 512
const AUTHORED_COLLISION_MASK := WORLD_COLLISION_MASK | DAMAGEABLE_COLLISION_MASK
const BROAD_PHASE_CLOSED_BOUNDARY_EPSILON := 0.001
const NORMAL_FAMILY_SOURCE_TYPE := &"fire_sorcerer_fireball_volley"
const ELITE_FAMILY_SOURCE_TYPE := &"fire_sorcerer_elite_fireball_volley"
const NORMAL_BALL_SOURCE_TYPES := [
	&"fire_sorcerer_fireball_a",
	&"fire_sorcerer_fireball_b",
	&"fire_sorcerer_fireball_c",
]
const ELITE_BALL_SOURCE_TYPES := [
	&"fire_sorcerer_elite_fireball_a",
	&"fire_sorcerer_elite_fireball_b",
	&"fire_sorcerer_elite_fireball_c",
]

var _combat_runtime: CombatRuntimeBase = null
var _enemy_simulation_coordinator: EnemySimulationCoordinator = null
var _enemy_damageable_spatial_index: EnemyDamageableSpatialIndex = null
var _combat_target_index: CombatTargetIndex = null
var _combat_relation_service: CombatRelationService = null
var _teardown_prepared := false
var _teardown_count := 0

var _collision_shape := CircleShape2D.new()
var _endpoint_query := PhysicsShapeQueryParameters2D.new()
var _damageable_query_results: Array = []
var _enemy_query_results: Array[Enemy] = []
var _endpoint_target: Node2D = null
var _endpoint_target_kind := TargetKind.NONE
var _endpoint_target_id := 0

# Per-volley packed structure-of-arrays. No simulation-time resize is allowed.
var _modes := PackedInt32Array()
var _profiles := PackedInt32Array()
var _states := PackedInt32Array()
var _record_generations := PackedInt32Array()
var _handle_slots := PackedInt32Array()
var _spawn_physics_frames := PackedInt64Array()
var _spawn_sequences := PackedInt64Array()
var _speeds := PackedFloat64Array()
var _remaining_lifetimes := PackedFloat64Array()
var _homing_turn_rates := PackedFloat64Array()
var _damages := PackedInt32Array()
var _source_enemy_ids := PackedInt64Array()
var _projectile_ids := PackedInt64Array()
var _target_instance_ids := PackedInt64Array()
var _target_refresh_left := PackedFloat64Array()
var _burn_durations := PackedFloat64Array()
var _burn_levels := PackedInt32Array()
var _source_faction_ids := PackedInt32Array()
var _source_credit_peer_ids := PackedInt64Array()
var _source_instigator_entity_ids := PackedInt64Array()
var _source_event_ids := PackedInt64Array()
var _active_ball_masks := PackedInt32Array()
var _visible_effect_masks := PackedInt32Array()

# Per-ball packed SoA; row offset is dense_slot * BALL_COUNT.
var _ball_positions := PackedVector2Array()
var _ball_directions := PackedVector2Array()
var _ball_visual_ages := PackedFloat64Array()
var _ball_effect_elapsed := PackedFloat64Array()
var _ball_effect_durations := PackedFloat64Array()
var _ball_effect_kinds := PackedInt32Array()

var _record_capacity := 0
var _record_count := 0
var _active_slot_count := 0
var _tombstone_count := 0
var _next_spawn_sequence := 1

# Stable logical handles point into the compacted dense prefix.
var _handle_generations := PackedInt32Array()
var _dense_slots_by_handle_slot := PackedInt32Array()
var _free_handle_slots := PackedInt32Array()
var _handle_capacity := 0
var _next_handle_slot := 0
var _free_handle_count := 0
var _next_handle_generation := 1

# Per-ball contact/lifetime records. These are emitted when an effect begins.
var _completion_handles := PackedInt64Array()
var _completion_projectile_ids := PackedInt64Array()
var _completion_ball_indices := PackedInt32Array()
var _completion_effect_kinds := PackedInt32Array()
var _completion_positions := PackedVector2Array()
var _completion_directions := PackedVector2Array()
var _completion_source_types := PackedStringArray()
var _completion_damage_applied := PackedByteArray()
var _completion_count := 0
var _completion_capacity := 0

# Whole-volley terminal records outlive the handle invalidation/compaction.
var _terminal_handles := PackedInt64Array()
var _terminal_projectile_ids := PackedInt64Array()
var _terminal_spawn_sequences := PackedInt64Array()
var _terminal_modes := PackedInt32Array()
var _terminal_profiles := PackedInt32Array()
var _terminal_count := 0
var _terminal_capacity := 0

var _metric_registrations := 0
var _metric_registration_rejections := 0
var _metric_releases := 0
var _metric_physics_ticks := 0
var _metric_activation_skips := 0
var _metric_activations := 0
var _metric_ball_advances := 0
var _metric_homing_updates := 0
var _metric_retargets := 0
var _metric_endpoint_queries := 0
var _metric_player_exact_queries := 0
var _metric_plant_broad_queries := 0
var _metric_plant_exact_queries := 0
var _metric_enemy_broad_queries := 0
var _metric_enemy_exact_queries := 0
var _metric_compensation_sweeps := 0
var _metric_damage_applications := 0
var _metric_burn_applications := 0
var _metric_compactions := 0
var _metric_compacted_tombstones := 0


func _init() -> void:
	set_physics_process(false)
	_collision_shape.radius = BALL_COLLISION_RADIUS
	_endpoint_query.shape = _collision_shape
	_endpoint_query.collide_with_bodies = true
	_endpoint_query.collide_with_areas = false
	_endpoint_query.collision_mask = WORLD_COLLISION_MASK


func bind_context(
	runtime: CombatRuntimeBase,
	coordinator: EnemySimulationCoordinator,
	spatial_index: EnemyDamageableSpatialIndex
) -> bool:
	if (
		_teardown_prepared
		or runtime == null
		or coordinator == null
		or spatial_index == null
		or not is_instance_valid(runtime)
		or not is_instance_valid(coordinator)
		or not is_instance_valid(spatial_index)
		or coordinator.get_parent() != runtime
	):
		return false
	if (
		_combat_runtime != null
		and (
			_combat_runtime != runtime
			or _enemy_simulation_coordinator != coordinator
			or _enemy_damageable_spatial_index != spatial_index
		)
	):
		return false
	_combat_runtime = runtime
	_enemy_simulation_coordinator = coordinator
	_enemy_damageable_spatial_index = spatial_index
	_combat_target_index = runtime.combat_target_index
	_combat_relation_service = runtime.get_combat_relation_service()
	if _combat_target_index == null or _combat_relation_service == null:
		_combat_runtime = null
		_enemy_simulation_coordinator = null
		_enemy_damageable_spatial_index = null
		_combat_target_index = null
		_combat_relation_service = null
		return false
	return true


func is_bound() -> bool:
	return (
		_combat_runtime != null
		and _enemy_simulation_coordinator != null
		and _enemy_damageable_spatial_index != null
		and _combat_target_index != null
		and _combat_relation_service != null
		and is_instance_valid(_combat_runtime)
		and is_instance_valid(_enemy_simulation_coordinator)
		and is_instance_valid(_enemy_damageable_spatial_index)
	)


func reserve_volley_capacity(minimum_capacity: int) -> bool:
	if _teardown_prepared or minimum_capacity < _record_count:
		return false
	if minimum_capacity <= _record_capacity:
		return true
	_resize_record_storage(minimum_capacity)
	_resize_handle_storage(minimum_capacity)
	_resize_completion_storage(minimum_capacity * BALL_COUNT)
	_resize_terminal_storage(minimum_capacity)
	return true


func reserve_capacity(minimum_capacity: int) -> bool:
	return reserve_volley_capacity(minimum_capacity)


func register_volley(
	mode: Mode,
	profile: Profile,
	three_positions: PackedVector2Array,
	three_directions: PackedVector2Array,
	speed: float,
	lifetime: float,
	homing_turn_rate: float,
	damage: int,
	source_enemy_id: int,
	projectile_id: int,
	target: Node2D = null,
	burn_duration: float = 5.0,
	burn_level: int = 5,
	damage_source_snapshot: DamageSourceSnapshot = null
) -> int:
	if not _is_valid_registration(
		mode,
		profile,
		three_positions,
		three_directions,
		speed,
		lifetime,
		homing_turn_rate,
		damage,
		source_enemy_id,
		projectile_id,
		target,
		burn_duration,
		burn_level,
		damage_source_snapshot
	):
		_metric_registration_rejections += 1
		return INVALID_HANDLE
	var handle_slot := _acquire_handle_slot()
	if handle_slot < 0:
		_metric_registration_rejections += 1
		return INVALID_HANDLE
	var dense_slot := _record_count
	var generation := _allocate_generation()
	_record_count += 1
	_active_slot_count += 1
	_modes[dense_slot] = mode
	_profiles[dense_slot] = profile
	_states[dense_slot] = SlotState.PENDING_ACTIVATION
	_record_generations[dense_slot] = generation
	_handle_slots[dense_slot] = handle_slot
	_handle_generations[handle_slot] = generation
	_dense_slots_by_handle_slot[handle_slot] = dense_slot
	_spawn_physics_frames[dense_slot] = Engine.get_physics_frames()
	_spawn_sequences[dense_slot] = _next_spawn_sequence
	_next_spawn_sequence += 1
	_speeds[dense_slot] = speed
	_remaining_lifetimes[dense_slot] = maxf(lifetime, 0.01)
	_homing_turn_rates[dense_slot] = homing_turn_rate
	_damages[dense_slot] = damage
	_source_enemy_ids[dense_slot] = source_enemy_id
	_projectile_ids[dense_slot] = projectile_id
	_target_instance_ids[dense_slot] = (
		target.get_instance_id() if target != null else 0
	)
	_target_refresh_left[dense_slot] = 0.0
	_burn_durations[dense_slot] = burn_duration
	_burn_levels[dense_slot] = burn_level
	_write_snapshot(dense_slot, profile, projectile_id, damage_source_snapshot)
	_active_ball_masks[dense_slot] = ALL_BALLS_MASK
	_visible_effect_masks[dense_slot] = 0
	for ball_index in range(BALL_COUNT):
		var ball_slot := _ball_slot(dense_slot, ball_index)
		_ball_positions[ball_slot] = three_positions[ball_index]
		_ball_directions[ball_slot] = three_directions[ball_index].normalized()
		_ball_visual_ages[ball_slot] = 0.0
		_ball_effect_elapsed[ball_slot] = 0.0
		_ball_effect_durations[ball_slot] = 0.0
		_ball_effect_kinds[ball_slot] = EffectKind.NONE
	_metric_registrations += 1
	set_physics_process(true)
	return _encode_handle(handle_slot, generation)


func assign_projectile_identity(handle: int, projectile_id: int) -> bool:
	if projectile_id <= 0:
		return false
	var dense_slot := _resolve_dense_slot(handle)
	if dense_slot < 0 or _states[dense_slot] != SlotState.PENDING_ACTIVATION:
		return false
	var current_id := int(_projectile_ids[dense_slot])
	if current_id > 0 and current_id != projectile_id:
		return false
	_projectile_ids[dense_slot] = projectile_id
	_source_event_ids[dense_slot] = projectile_id
	return true


func release_volley(handle: int) -> bool:
	var dense_slot := _resolve_dense_slot(handle)
	if dense_slot < 0:
		return false
	_mark_tombstone(dense_slot, false)
	_metric_releases += 1
	set_physics_process(true)
	return true


func release(handle: int) -> bool:
	return release_volley(handle)


func is_handle_live(handle: int) -> bool:
	return _resolve_dense_slot(handle) >= 0


func get_handle_slot(handle: int) -> int:
	return int(handle & HANDLE_SLOT_MASK) - 1 if handle > 0 else INVALID_SLOT


func get_handle_generation(handle: int) -> int:
	return int(handle >> HANDLE_SLOT_BITS) if handle > 0 else 0


func get_dense_record_count() -> int:
	return _record_count


func get_active_slot_count() -> int:
	return _active_slot_count


func get_tombstone_count() -> int:
	return _tombstone_count


func get_reserved_capacity() -> int:
	return _record_capacity


func get_handle_at_stable_index(index: int) -> int:
	if index < 0 or index >= _record_count:
		return INVALID_HANDLE
	if _states[index] == SlotState.TOMBSTONE:
		return INVALID_HANDLE
	return _encode_handle(_handle_slots[index], _record_generations[index])


func get_slot_mode(handle: int) -> Mode:
	var dense_slot := _resolve_dense_slot(handle)
	return int(_modes[dense_slot]) as Mode if dense_slot >= 0 else Mode.INVALID


func get_slot_profile(handle: int) -> Profile:
	var dense_slot := _resolve_dense_slot(handle)
	return int(_profiles[dense_slot]) as Profile if dense_slot >= 0 else Profile.INVALID


func get_slot_state(handle: int) -> SlotState:
	var dense_slot := _resolve_dense_slot(handle)
	return int(_states[dense_slot]) as SlotState if dense_slot >= 0 else SlotState.EMPTY


func get_active_ball_mask(handle: int) -> int:
	var dense_slot := _resolve_dense_slot(handle)
	return int(_active_ball_masks[dense_slot]) if dense_slot >= 0 else 0


func get_visible_effect_mask(handle: int) -> int:
	var dense_slot := _resolve_dense_slot(handle)
	return int(_visible_effect_masks[dense_slot]) if dense_slot >= 0 else 0


func get_ball_position(handle: int, ball: int) -> Vector2:
	var dense_slot := _resolve_dense_slot(handle)
	return (
		_ball_positions[_ball_slot(dense_slot, ball)]
		if dense_slot >= 0 and ball >= 0 and ball < BALL_COUNT
		else Vector2.ZERO
	)


func get_ball_direction(handle: int, ball: int) -> Vector2:
	var dense_slot := _resolve_dense_slot(handle)
	return (
		_ball_directions[_ball_slot(dense_slot, ball)]
		if dense_slot >= 0 and ball >= 0 and ball < BALL_COUNT
		else Vector2.ZERO
	)


func get_ball_visual_age_seconds(handle: int, ball: int) -> float:
	var dense_slot := _resolve_dense_slot(handle)
	return (
		_ball_visual_ages[_ball_slot(dense_slot, ball)]
		if dense_slot >= 0 and ball >= 0 and ball < BALL_COUNT
		else 0.0
	)


func get_ball_effect_progress(handle: int, ball: int) -> float:
	var dense_slot := _resolve_dense_slot(handle)
	if dense_slot < 0 or ball < 0 or ball >= BALL_COUNT:
		return 0.0
	var ball_slot := _ball_slot(dense_slot, ball)
	var duration := _ball_effect_durations[ball_slot]
	return clampf(_ball_effect_elapsed[ball_slot] / duration, 0.0, 1.0) if duration > 0.0 else 0.0


func get_ball_effect_kind(handle: int, ball: int) -> EffectKind:
	var dense_slot := _resolve_dense_slot(handle)
	return (
		int(_ball_effect_kinds[_ball_slot(dense_slot, ball)]) as EffectKind
		if dense_slot >= 0 and ball >= 0 and ball < BALL_COUNT
		else EffectKind.NONE
	)


func get_remaining_lifetime(handle: int) -> float:
	var dense_slot := _resolve_dense_slot(handle)
	return _remaining_lifetimes[dense_slot] if dense_slot >= 0 else 0.0


func get_projectile_id(handle: int) -> int:
	var dense_slot := _resolve_dense_slot(handle)
	return int(_projectile_ids[dense_slot]) if dense_slot >= 0 else 0


func get_spawn_physics_frame(handle: int) -> int:
	var dense_slot := _resolve_dense_slot(handle)
	return int(_spawn_physics_frames[dense_slot]) if dense_slot >= 0 else -1


func clear_completion_records() -> void:
	_completion_count = 0
	_terminal_count = 0


func get_completion_count() -> int:
	return _completion_count


func get_completion_handle(index: int) -> int:
	return int(_completion_handles[index]) if _valid_completion(index) else INVALID_HANDLE


func get_completion_projectile_id(index: int) -> int:
	return int(_completion_projectile_ids[index]) if _valid_completion(index) else 0


func get_completion_ball_index(index: int) -> int:
	return int(_completion_ball_indices[index]) if _valid_completion(index) else -1


func get_completion_effect_kind(index: int) -> EffectKind:
	return int(_completion_effect_kinds[index]) as EffectKind if _valid_completion(index) else EffectKind.NONE


func get_completion_position(index: int) -> Vector2:
	return _completion_positions[index] if _valid_completion(index) else Vector2.ZERO


func get_completion_direction(index: int) -> Vector2:
	return _completion_directions[index] if _valid_completion(index) else Vector2.ZERO


func get_completion_source_type(index: int) -> StringName:
	return StringName(_completion_source_types[index]) if _valid_completion(index) else &""


func get_completion_damage_applied(index: int) -> bool:
	return _completion_damage_applied[index] != 0 if _valid_completion(index) else false


func get_terminal_completion_count() -> int:
	return _terminal_count


func get_terminal_completion_handle(index: int) -> int:
	return int(_terminal_handles[index]) if _valid_terminal(index) else INVALID_HANDLE


func get_terminal_completion_projectile_id(index: int) -> int:
	return int(_terminal_projectile_ids[index]) if _valid_terminal(index) else 0


func get_terminal_completion_spawn_sequence(index: int) -> int:
	return int(_terminal_spawn_sequences[index]) if _valid_terminal(index) else 0


func get_terminal_completion_mode(index: int) -> Mode:
	return int(_terminal_modes[index]) as Mode if _valid_terminal(index) else Mode.INVALID


func get_terminal_completion_profile(index: int) -> Profile:
	return int(_terminal_profiles[index]) as Profile if _valid_terminal(index) else Profile.INVALID


func _physics_process(delta: float) -> void:
	advance_authoritative(delta)


func advance_authoritative(delta: float) -> void:
	_completion_count = 0
	_terminal_count = 0
	if _record_count <= 0:
		set_physics_process(false)
		return
	var valid_delta := maxf(delta, 0.0) if is_finite(delta) else 0.0
	var physics_frame := Engine.get_physics_frames()
	var initial_count := _record_count
	_metric_physics_ticks += 1
	for dense_slot in range(initial_count):
		if _states[dense_slot] == SlotState.TOMBSTONE:
			continue
		if physics_frame <= _spawn_physics_frames[dense_slot]:
			_metric_activation_skips += 1
			continue
		if _states[dense_slot] == SlotState.PENDING_ACTIVATION:
			_states[dense_slot] = SlotState.ACTIVE
			_metric_activations += 1
		_advance_record(dense_slot, valid_delta, false)
	if _tombstone_count > 0:
		_stable_compact_tombstones()
	set_physics_process(_record_count > 0)


func advance_compensated(handle: int, seconds: float) -> bool:
	var dense_slot := _resolve_dense_slot(handle)
	if dense_slot < 0 or not is_finite(seconds) or seconds < 0.0:
		return false
	var time_left := minf(seconds, maxf(_remaining_lifetimes[dense_slot], 0.0))
	while time_left > 0.0 and _active_ball_masks[dense_slot] != 0:
		var step := minf(time_left, COMPENSATION_STEP)
		_advance_record(dense_slot, step, true)
		time_left -= step
	return true


func advance_compensated_all(seconds: float) -> bool:
	if not is_finite(seconds) or seconds < 0.0:
		return false
	for dense_slot in range(_record_count):
		if _states[dense_slot] != SlotState.TOMBSTONE:
			advance_compensated(
				_encode_handle(_handle_slots[dense_slot], _record_generations[dense_slot]),
				seconds
			)
	return true


func _advance_record(dense_slot: int, delta: float, compensated: bool) -> void:
	if delta <= 0.0:
		return
	_update_target(dense_slot, delta)
	var target := _get_live_target(dense_slot)
	for ball_index in range(BALL_COUNT):
		var bit := 1 << ball_index
		var ball_slot := _ball_slot(dense_slot, ball_index)
		if (
			(_active_ball_masks[dense_slot] & bit) != 0
			or (_visible_effect_masks[dense_slot] & bit) != 0
		):
			_ball_visual_ages[ball_slot] += delta
		if (_active_ball_masks[dense_slot] & bit) != 0:
			_metric_ball_advances += 1
			_update_ball_direction(dense_slot, ball_slot, target, delta)
			var start := _ball_positions[ball_slot]
			var motion := _ball_directions[ball_slot] * _speeds[dense_slot] * delta
			if compensated:
				_advance_compensated_ball(dense_slot, ball_index, start, motion)
			else:
				_ball_positions[ball_slot] = start + motion
				_resolve_endpoint_contact(dense_slot, ball_index)
	if compensated:
		return
	_remaining_lifetimes[dense_slot] = maxf(_remaining_lifetimes[dense_slot] - delta, 0.0)
	if _remaining_lifetimes[dense_slot] <= 0.0:
		for ball_index in range(BALL_COUNT):
			if (_active_ball_masks[dense_slot] & (1 << ball_index)) != 0:
				_begin_ball_effect(dense_slot, ball_index, EffectKind.EXPIRE, false)
	for ball_index in range(BALL_COUNT):
		var bit := 1 << ball_index
		if (_visible_effect_masks[dense_slot] & bit) == 0:
			continue
		var ball_slot := _ball_slot(dense_slot, ball_index)
		_ball_effect_elapsed[ball_slot] += delta
		if _ball_effect_elapsed[ball_slot] >= _ball_effect_durations[ball_slot]:
			_visible_effect_masks[dense_slot] &= ~bit
	if _active_ball_masks[dense_slot] == 0 and _visible_effect_masks[dense_slot] == 0:
		_append_terminal(dense_slot)
		_mark_tombstone(dense_slot, true)


func _update_ball_direction(
	dense_slot: int,
	ball_slot: int,
	target: Node2D,
	delta: float
) -> void:
	if target == null or _homing_turn_rates[dense_slot] <= 0.0:
		return
	var desired := _ball_positions[ball_slot].direction_to(target.global_position)
	if desired == Vector2.ZERO:
		return
	var current := _ball_directions[ball_slot]
	var maximum_turn := _homing_turn_rates[dense_slot] * delta
	_ball_directions[ball_slot] = current.rotated(
		clampf(current.angle_to(desired), -maximum_turn, maximum_turn)
	).normalized()
	_metric_homing_updates += 1


func _update_target(dense_slot: int, delta: float) -> void:
	if _get_live_target(dense_slot) != null:
		_target_refresh_left[dense_slot] = 0.0
		return
	_target_instance_ids[dense_slot] = 0
	_target_refresh_left[dense_slot] = maxf(_target_refresh_left[dense_slot] - delta, 0.0)
	if _target_refresh_left[dense_slot] > 0.0:
		return
	_target_refresh_left[dense_slot] = TARGET_REFRESH_INTERVAL
	if (
		_combat_runtime == null
		or not is_instance_valid(_combat_runtime)
	):
		return
	var center := _get_active_ball_center(dense_slot)
	var reach := maxf(_speeds[dense_slot] * _remaining_lifetimes[dense_slot], 0.0)
	var candidate := _combat_runtime.find_nearest_hostile_enemy_attack_target_world(
		center,
		reach,
		int(_source_faction_ids[dense_slot])
	)
	if _is_damage_target_alive(dense_slot, candidate):
		_target_instance_ids[dense_slot] = candidate.get_instance_id()
		_target_refresh_left[dense_slot] = 0.0
		_metric_retargets += 1


func _get_active_ball_center(dense_slot: int) -> Vector2:
	var sum := Vector2.ZERO
	var count := 0
	for ball_index in range(BALL_COUNT):
		if (_active_ball_masks[dense_slot] & (1 << ball_index)) != 0:
			sum += _ball_positions[_ball_slot(dense_slot, ball_index)]
			count += 1
	return sum / float(count) if count > 0 else Vector2.ZERO


func _get_live_target(dense_slot: int) -> Node2D:
	var instance_id := int(_target_instance_ids[dense_slot])
	if instance_id <= 0:
		return null
	var candidate := instance_from_id(instance_id) as Node2D
	return candidate if _is_damage_target_alive(dense_slot, candidate) else null


func _is_damage_target_alive(dense_slot: int, candidate: Node2D) -> bool:
	if candidate == null or not is_instance_valid(candidate) or candidate.is_queued_for_deletion():
		return false
	var player := candidate as Player
	if player != null:
		return not player.is_dead and _is_target_hostile_for_slot(dense_slot, player)
	var plant := candidate as PlantDefense
	if plant != null:
		return (
			not plant.is_dead
			and not plant.is_removing
			and _is_target_hostile_for_slot(dense_slot, plant)
		)
	var enemy := candidate as Enemy
	return (
		enemy != null
		and not enemy.is_dead
		and not _is_source_enemy_for_slot(dense_slot, enemy)
		and _is_target_hostile_for_slot(dense_slot, enemy)
	)


func _resolve_endpoint_contact(dense_slot: int, ball_index: int) -> void:
	if not is_bound():
		return
	var ball_slot := _ball_slot(dense_slot, ball_index)
	var direction := _ball_directions[ball_slot]
	var shape_transform := Transform2D(
		direction.angle(),
		_ball_positions[ball_slot] + direction * BALL_COLLISION_FORWARD_OFFSET
	)
	if _endpoint_hits_world(shape_transform):
		_try_consume_multiplayer_contact(dense_slot, ball_index)
		_begin_ball_effect(dense_slot, ball_index, EffectKind.EXPIRE, false)
		return
	if _find_endpoint_target(dense_slot, shape_transform, direction):
		var contact_consumed := _try_consume_multiplayer_contact(
			dense_slot,
			ball_index
		)
		var applied := _apply_authoritative_damage(
			dense_slot,
			ball_index,
			contact_consumed
		)
		_begin_ball_effect(dense_slot, ball_index, EffectKind.IMPACT, applied)


func _endpoint_hits_world(shape_transform: Transform2D) -> bool:
	if not _has_space_state():
		return false
	_endpoint_query.transform = shape_transform
	_endpoint_query.motion = Vector2.ZERO
	_endpoint_query.collision_mask = WORLD_COLLISION_MASK
	_metric_endpoint_queries += 1
	return not _combat_runtime.get_world_2d().direct_space_state.intersect_shape(
		_endpoint_query,
		1
	).is_empty()


func _find_endpoint_target(
	dense_slot: int,
	shape_transform: Transform2D,
	direction: Vector2
) -> bool:
	_endpoint_target = null
	_endpoint_target_kind = TargetKind.NONE
	_endpoint_target_id = 0
	if _find_endpoint_player(dense_slot, shape_transform):
		return true
	if _find_endpoint_plant(dense_slot, shape_transform):
		return true
	return _find_endpoint_enemy(dense_slot, shape_transform, direction)


func _find_endpoint_player(dense_slot: int, shape_transform: Transform2D) -> bool:
	var local_player := _combat_runtime.player
	_consider_endpoint_player(
		dense_slot,
		local_player,
		_get_player_stable_id(local_player, _combat_runtime.multiplayer_local_peer_id),
		shape_transform
	)
	for peer_id_variant in _combat_runtime.peer_players:
		var player := _combat_runtime.peer_players.get(peer_id_variant) as Player
		if player == local_player:
			continue
		_consider_endpoint_player(
			dense_slot,
			player,
			_get_player_stable_id(player, int(peer_id_variant)),
			shape_transform
		)
	return _endpoint_target != null


func _consider_endpoint_player(
	dense_slot: int,
	player: Player,
	stable_id: int,
	shape_transform: Transform2D
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
	if not _collision_shape.collide(
		shape_transform,
		player.collision_shape.shape,
		player.collision_shape.global_transform
	):
		return
	var resolved_id := stable_id if stable_id > 0 else int(player.get_instance_id())
	if (
		_endpoint_target == null
		or resolved_id < _endpoint_target_id
		or (
			resolved_id == _endpoint_target_id
			and player.get_instance_id() < _endpoint_target.get_instance_id()
		)
	):
		_endpoint_target = player
		_endpoint_target_kind = TargetKind.PLAYER
		_endpoint_target_id = resolved_id


func _find_endpoint_plant(dense_slot: int, shape_transform: Transform2D) -> bool:
	var center := shape_transform.origin
	var diameter := BALL_COLLISION_RADIUS * 2.0
	_metric_plant_broad_queries += 1
	_enemy_damageable_spatial_index.query_world_aabb_into(
		Rect2(center - Vector2.ONE * BALL_COLLISION_RADIUS, Vector2.ONE * diameter),
		_damageable_query_results
	)
	var selected_instance_id := 0
	for candidate_variant in _damageable_query_results:
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
			_collision_shape,
			shape_transform
		):
			continue
		var stable_id := int(plant.get_meta(&"net_id", 0))
		if stable_id <= 0:
			stable_id = int(plant.get_instance_id())
		var instance_id := int(plant.get_instance_id())
		if (
			_endpoint_target == null
			or stable_id < _endpoint_target_id
			or (stable_id == _endpoint_target_id and instance_id < selected_instance_id)
		):
			_endpoint_target = plant
			_endpoint_target_kind = TargetKind.PLANT
			_endpoint_target_id = stable_id
			selected_instance_id = instance_id
	return _endpoint_target != null


func _find_endpoint_enemy(
	dense_slot: int,
	shape_transform: Transform2D,
	_direction: Vector2
) -> bool:
	if _combat_target_index == null:
		return false
	var center := shape_transform.origin
	var projectile_aabb := Rect2(
		center - Vector2.ONE * BALL_COLLISION_RADIUS,
		Vector2.ONE * BALL_COLLISION_RADIUS * 2.0
	).grow(
		_combat_target_index.get_maximum_body_collision_extent_radius()
		+ BROAD_PHASE_CLOSED_BOUNDARY_EPSILON
	)
	_metric_enemy_broad_queries += 1
	_combat_target_index.query_hostile_world_aabb_unordered_into(
		projectile_aabb,
		int(_source_faction_ids[dense_slot]),
		_enemy_query_results,
		_get_indexed_source_enemy(dense_slot),
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
		if not _enemy_body_overlaps_projectile(enemy, shape_transform):
			continue
		var stable_id := _get_enemy_stable_id(enemy)
		var instance_id := int(enemy.get_instance_id())
		if (
			_endpoint_target == null
			or stable_id < _endpoint_target_id
			or (stable_id == _endpoint_target_id and instance_id < selected_instance_id)
		):
			_endpoint_target = enemy
			_endpoint_target_kind = TargetKind.ENEMY
			_endpoint_target_id = stable_id
			selected_instance_id = instance_id
	return _endpoint_target != null


func _enemy_body_overlaps_projectile(
	enemy: Enemy,
	shape_transform: Transform2D
) -> bool:
	for shape_node in enemy.body_collision_shapes:
		if (
			shape_node == null
			or not is_instance_valid(shape_node)
			or shape_node.disabled
			or shape_node.shape == null
		):
			continue
		if _collision_shape.collide(
			shape_transform,
			shape_node.shape,
			shape_node.global_transform
		):
			return true
	return false


func _get_indexed_source_enemy(dense_slot: int) -> Enemy:
	var source_enemy_id := int(_source_enemy_ids[dense_slot])
	return _combat_target_index.get_enemy(source_enemy_id) if source_enemy_id > 0 else null


func _is_source_enemy_for_slot(dense_slot: int, enemy: Enemy) -> bool:
	if enemy == null:
		return false
	var source_enemy_id := int(_source_enemy_ids[dense_slot])
	return source_enemy_id > 0 and (
		_get_enemy_stable_id(enemy) == source_enemy_id
		or int(enemy.get_instance_id()) == source_enemy_id
	)


func _get_enemy_stable_id(enemy: Enemy) -> int:
	var stable_id := enemy.combat_target_index_net_id
	if stable_id <= 0:
		stable_id = int(enemy.get_meta(&"net_id", 0))
	return stable_id if stable_id > 0 else int(enemy.get_instance_id())


func _get_player_stable_id(player: Player, roster_peer_id: int) -> int:
	if roster_peer_id > 0:
		return roster_peer_id
	if player != null and player.peer_id > 0:
		return player.peer_id
	if player == _combat_runtime.player:
		return 1
	return 0


func _is_target_hostile_for_slot(dense_slot: int, target: Node) -> bool:
	if target == null or not is_instance_valid(target):
		return false
	var source_faction_id := int(_source_faction_ids[dense_slot])
	var target_faction_id := CombatRelationService.NEUTRAL
	var player := target as Player
	var plant := target as PlantDefense
	var enemy := target as Enemy
	if player != null:
		target_faction_id = player.get_combat_faction_id()
	elif plant != null:
		target_faction_id = plant.get_combat_faction_id()
	elif enemy != null:
		target_faction_id = enemy.get_combat_faction_id()
	else:
		return false
	return (
		CombatRelationService.is_valid_faction_id(source_faction_id)
		and CombatRelationService.is_valid_faction_id(target_faction_id)
		and (
			_combat_relation_service.is_hostile(source_faction_id, target_faction_id)
			if _combat_relation_service != null
			else CombatRelationService.is_default_hostile(
				source_faction_id,
				target_faction_id
			)
		)
	)


func _advance_compensated_ball(
	dense_slot: int,
	ball_index: int,
	start: Vector2,
	motion: Vector2
) -> void:
	var ball_slot := _ball_slot(dense_slot, ball_index)
	if not _has_space_state() or motion == Vector2.ZERO:
		_ball_positions[ball_slot] = start + motion
		return
	var direction := _ball_directions[ball_slot]
	_endpoint_query.transform = Transform2D(
		direction.angle(),
		start + direction * BALL_COLLISION_FORWARD_OFFSET
	)
	_endpoint_query.motion = motion
	_endpoint_query.collision_mask = AUTHORED_COLLISION_MASK
	_metric_compensation_sweeps += 1
	var fractions: PackedFloat32Array = (
		_combat_runtime.get_world_2d().direct_space_state.cast_motion(
			_endpoint_query
		)
	)
	var unsafe_fraction := float(fractions[1]) if fractions.size() >= 2 else 1.0
	_ball_positions[ball_slot] = start + motion * unsafe_fraction
	if unsafe_fraction >= 1.0:
		return
	var contact_transform := Transform2D(
		direction.angle(),
		_ball_positions[ball_slot] + direction * BALL_COLLISION_FORWARD_OFFSET
	)
	if _find_endpoint_target(dense_slot, contact_transform, direction):
		var contact_consumed := _try_consume_multiplayer_contact(
			dense_slot,
			ball_index
		)
		var applied := _apply_authoritative_damage(
			dense_slot,
			ball_index,
			contact_consumed
		)
		_begin_ball_effect(dense_slot, ball_index, EffectKind.IMPACT, applied)
	elif _endpoint_hits_world(contact_transform):
		_try_consume_multiplayer_contact(dense_slot, ball_index)
		_begin_ball_effect(dense_slot, ball_index, EffectKind.EXPIRE, false)
	# A cast can stop on a friendly Player/Plant/Enemy. Legacy Area2D admission
	# leaves that ball active and does not consume its multiplayer contact.


func _apply_authoritative_damage(
	dense_slot: int,
	ball_index: int,
	contact_consumed: bool
) -> bool:
	if (
		_modes[dense_slot] != Mode.DATA
		or not contact_consumed
		or _combat_runtime.runtime_mode == CombatRuntimeBase.RuntimeMode.CLIENT_VIEW
		or _damages[dense_slot] <= 0
		or _endpoint_target == null
		or not _is_target_hostile_for_slot(dense_slot, _endpoint_target)
	):
		return false
	var source_type := get_profile_ball_source_type(
		int(_profiles[dense_slot]) as Profile,
		ball_index
	)
	var request := DamageRequest.new(
		int(_damages[dense_slot]),
		CombatTypes.DamageType.MAGIC
	).with_stable_source(
		int(_source_enemy_ids[dense_slot]),
		int(_projectile_ids[dense_slot]),
		source_type,
		_make_ball_source_snapshot(dense_slot, ball_index)
	).with_directions(
		_ball_directions[_ball_slot(dense_slot, ball_index)],
		-_ball_directions[_ball_slot(dense_slot, ball_index)]
	).with_flag(CombatTypes.DamageFlag.RANGED)
	var accepted := false
	var player := _endpoint_target as Player
	var plant := _endpoint_target as PlantDefense
	var enemy := _endpoint_target as Enemy
	if player != null:
		if player.is_dead:
			return false
		if _combat_runtime.runtime_mode == CombatRuntimeBase.RuntimeMode.SINGLEPLAYER:
			accepted = player.apply_combat_damage(request).accepted
		else:
			var gateway := _combat_runtime.get_multiplayer_gameplay_gateway()
			accepted = (
				_projectile_ids[dense_slot] > 0
				and player.peer_id > 0
				and gateway != null
				and is_instance_valid(gateway)
				and gateway.request_player_damage(
					int(_projectile_ids[dense_slot]),
					player.peer_id,
					int(_damages[dense_slot]),
					source_type,
					EnemyConfig.DamageType.MAGIC,
					player.global_position.direction_to(
						_ball_positions[_ball_slot(dense_slot, ball_index)]
					),
					true,
					true,
					_make_ball_source_snapshot(dense_slot, ball_index)
				)
			)
	elif plant != null:
		accepted = (
			not plant.is_dead
			and not plant.is_removing
			and plant.apply_combat_damage(request).accepted
		)
	elif enemy != null:
		accepted = (
			not enemy.is_dead
			and not _is_source_enemy_for_slot(dense_slot, enemy)
			and enemy.apply_combat_damage(request).accepted
		)
	if not accepted:
		return false
	_metric_damage_applications += 1
	# Multiplayer player damage derives burn family/duration/level from the ball
	# source_type in MpPlayerCoordinator via CombatAttackRegistry.
	if player != null and _combat_runtime.runtime_mode != CombatRuntimeBase.RuntimeMode.SINGLEPLAYER:
		_metric_burn_applications += 1
		return true
	if (
		_burn_durations[dense_slot] > 0.0
		and _burn_levels[dense_slot] > 0
		and _apply_direct_burn(dense_slot, player, plant, enemy, request)
	):
		_metric_burn_applications += 1
	return true


func _apply_direct_burn(
	dense_slot: int,
	player: Player,
	plant: PlantDefense,
	enemy: Enemy,
	request: DamageRequest
) -> bool:
	var family := get_profile_family_source_type(int(_profiles[dense_slot]) as Profile)
	var duration := float(_burn_durations[dense_slot])
	var level := int(_burn_levels[dense_slot])
	var snapshot := request.get_source_snapshot_copy()
	if player != null:
		return player.apply_burn_status(family, duration, level, snapshot)
	if plant != null:
		return plant.apply_burn_status(family, duration, level, snapshot)
	return enemy != null and enemy.apply_burn_status(family, duration, level, snapshot)


func _try_consume_multiplayer_contact(dense_slot: int, ball_index: int) -> bool:
	if _modes[dense_slot] != Mode.DATA:
		return true
	var projectile_id := int(_projectile_ids[dense_slot])
	if projectile_id <= 0:
		return true
	var gateway := _combat_runtime.get_multiplayer_gameplay_gateway()
	return (
		gateway != null
		and is_instance_valid(gateway)
		and gateway.try_consume_fire_sorcerer_fireball_contact(
			projectile_id,
			get_profile_ball_source_type(
				int(_profiles[dense_slot]) as Profile,
				ball_index
			)
		)
	)


func _begin_ball_effect(
	dense_slot: int,
	ball_index: int,
	effect_kind: EffectKind,
	damage_applied: bool
) -> void:
	var bit := 1 << ball_index
	if (_active_ball_masks[dense_slot] & bit) == 0:
		return
	var ball_slot := _ball_slot(dense_slot, ball_index)
	_active_ball_masks[dense_slot] &= ~bit
	_visible_effect_masks[dense_slot] |= bit
	_ball_effect_kinds[ball_slot] = effect_kind
	_ball_effect_elapsed[ball_slot] = 0.0
	_ball_effect_durations[ball_slot] = (
		IMPACT_EFFECT_DURATION
		if effect_kind == EffectKind.IMPACT
		else EXPIRE_EFFECT_DURATION
	)
	_append_completion(dense_slot, ball_index, effect_kind, damage_applied)


func _append_completion(
	dense_slot: int,
	ball_index: int,
	effect_kind: EffectKind,
	damage_applied: bool
) -> void:
	if _completion_count >= _completion_capacity:
		push_error("FireSorcererVolley completion storage invariant failed.")
		return
	var index := _completion_count
	_completion_count += 1
	var ball_slot := _ball_slot(dense_slot, ball_index)
	_completion_handles[index] = _encode_handle(
		_handle_slots[dense_slot], _record_generations[dense_slot]
	)
	_completion_projectile_ids[index] = _projectile_ids[dense_slot]
	_completion_ball_indices[index] = ball_index
	_completion_effect_kinds[index] = effect_kind
	_completion_positions[index] = _ball_positions[ball_slot]
	_completion_directions[index] = _ball_directions[ball_slot]
	_completion_source_types[index] = String(
		get_profile_ball_source_type(
			int(_profiles[dense_slot]) as Profile,
			ball_index
		)
	)
	_completion_damage_applied[index] = int(damage_applied)


func _append_terminal(dense_slot: int) -> void:
	if _terminal_count >= _terminal_capacity:
		push_error("FireSorcererVolley terminal storage invariant failed.")
		return
	var index := _terminal_count
	_terminal_count += 1
	_terminal_handles[index] = _encode_handle(
		_handle_slots[dense_slot], _record_generations[dense_slot]
	)
	_terminal_projectile_ids[index] = _projectile_ids[dense_slot]
	_terminal_spawn_sequences[index] = _spawn_sequences[dense_slot]
	_terminal_modes[index] = _modes[dense_slot]
	_terminal_profiles[index] = _profiles[dense_slot]


func get_profile_family_source_type(profile: Profile) -> StringName:
	return ELITE_FAMILY_SOURCE_TYPE if profile == Profile.ELITE else NORMAL_FAMILY_SOURCE_TYPE


func get_profile_ball_source_type(profile: Profile, ball_index: int) -> StringName:
	if ball_index < 0 or ball_index >= BALL_COUNT:
		return &""
	return (
		ELITE_BALL_SOURCE_TYPES[ball_index]
		if profile == Profile.ELITE
		else NORMAL_BALL_SOURCE_TYPES[ball_index]
	)


func _make_ball_source_snapshot(
	dense_slot: int,
	ball_index: int
) -> DamageSourceSnapshot:
	return DamageSourceSnapshot.create(
		int(_source_faction_ids[dense_slot]),
		int(_source_credit_peer_ids[dense_slot]),
		int(_source_instigator_entity_ids[dense_slot]),
		int(_source_event_ids[dense_slot]),
		get_profile_ball_source_type(
			int(_profiles[dense_slot]) as Profile,
			ball_index
		)
	)


func _write_snapshot(
	dense_slot: int,
	profile: Profile,
	projectile_id: int,
	snapshot: DamageSourceSnapshot
) -> void:
	if snapshot != null:
		_source_faction_ids[dense_slot] = snapshot.source_faction_id
		_source_credit_peer_ids[dense_slot] = snapshot.credit_peer_id
		_source_instigator_entity_ids[dense_slot] = snapshot.instigator_entity_id
		_source_event_ids[dense_slot] = projectile_id if projectile_id > 0 else snapshot.event_source_id
		return
	_source_faction_ids[dense_slot] = CombatRelationService.HOSTILE_WAVE
	_source_credit_peer_ids[dense_slot] = 0
	_source_instigator_entity_ids[dense_slot] = int(_source_enemy_ids[dense_slot])
	_source_event_ids[dense_slot] = projectile_id


func _has_space_state() -> bool:
	return (
		is_bound()
		and _combat_runtime.is_inside_tree()
	)


func _is_valid_registration(
	mode: Mode,
	profile: Profile,
	positions: PackedVector2Array,
	directions: PackedVector2Array,
	speed: float,
	lifetime: float,
	homing_turn_rate: float,
	damage: int,
	source_enemy_id: int,
	projectile_id: int,
	target: Node2D,
	burn_duration: float,
	burn_level: int,
	snapshot: DamageSourceSnapshot
) -> bool:
	if (
		_teardown_prepared
		or _record_count >= _record_capacity
		or mode <= Mode.INVALID
		or mode > Mode.REPLICA
		or profile <= Profile.INVALID
		or profile > Profile.ELITE
		or positions.size() != BALL_COUNT
		or directions.size() != BALL_COUNT
		or not is_finite(speed)
		or speed < 0.0
		or not is_finite(lifetime)
		or lifetime <= 0.0
		or not is_finite(homing_turn_rate)
		or homing_turn_rate < 0.0
		or damage < 0
		or source_enemy_id < 0
		or projectile_id < 0
		or not is_finite(burn_duration)
		or burn_duration < 0.0
		or burn_level < 0
		or (target != null and not is_instance_valid(target))
	):
		return false
	for index in range(BALL_COUNT):
		if (
			not positions[index].is_finite()
			or not directions[index].is_finite()
			or directions[index] == Vector2.ZERO
		):
			return false
	if snapshot != null and not snapshot.is_valid():
		return false
	return true


func _mark_tombstone(dense_slot: int, terminal: bool) -> void:
	if dense_slot < 0 or dense_slot >= _record_count or _states[dense_slot] == SlotState.TOMBSTONE:
		return
	_states[dense_slot] = SlotState.TOMBSTONE
	_tombstone_count += 1
	_active_slot_count = maxi(_active_slot_count - 1, 0)
	var handle_slot := int(_handle_slots[dense_slot])
	_dense_slots_by_handle_slot[handle_slot] = INVALID_SLOT
	_free_handle_slots[_free_handle_count] = handle_slot
	_free_handle_count += 1
	if not terminal:
		_active_ball_masks[dense_slot] = 0
		_visible_effect_masks[dense_slot] = 0


func _stable_compact_tombstones() -> void:
	var write_slot := 0
	var old_count := _record_count
	for read_slot in range(old_count):
		if _states[read_slot] == SlotState.TOMBSTONE:
			continue
		if write_slot != read_slot:
			_copy_record(read_slot, write_slot)
		_dense_slots_by_handle_slot[_handle_slots[write_slot]] = write_slot
		write_slot += 1
	for clear_slot in range(write_slot, old_count):
		_states[clear_slot] = SlotState.EMPTY
	_record_count = write_slot
	_metric_compactions += 1
	_metric_compacted_tombstones += _tombstone_count
	_tombstone_count = 0


func _copy_record(source: int, destination: int) -> void:
	_modes[destination] = _modes[source]
	_profiles[destination] = _profiles[source]
	_states[destination] = _states[source]
	_record_generations[destination] = _record_generations[source]
	_handle_slots[destination] = _handle_slots[source]
	_spawn_physics_frames[destination] = _spawn_physics_frames[source]
	_spawn_sequences[destination] = _spawn_sequences[source]
	_speeds[destination] = _speeds[source]
	_remaining_lifetimes[destination] = _remaining_lifetimes[source]
	_homing_turn_rates[destination] = _homing_turn_rates[source]
	_damages[destination] = _damages[source]
	_source_enemy_ids[destination] = _source_enemy_ids[source]
	_projectile_ids[destination] = _projectile_ids[source]
	_target_instance_ids[destination] = _target_instance_ids[source]
	_target_refresh_left[destination] = _target_refresh_left[source]
	_burn_durations[destination] = _burn_durations[source]
	_burn_levels[destination] = _burn_levels[source]
	_source_faction_ids[destination] = _source_faction_ids[source]
	_source_credit_peer_ids[destination] = _source_credit_peer_ids[source]
	_source_instigator_entity_ids[destination] = _source_instigator_entity_ids[source]
	_source_event_ids[destination] = _source_event_ids[source]
	_active_ball_masks[destination] = _active_ball_masks[source]
	_visible_effect_masks[destination] = _visible_effect_masks[source]
	for ball_index in range(BALL_COUNT):
		var source_ball := _ball_slot(source, ball_index)
		var destination_ball := _ball_slot(destination, ball_index)
		_ball_positions[destination_ball] = _ball_positions[source_ball]
		_ball_directions[destination_ball] = _ball_directions[source_ball]
		_ball_visual_ages[destination_ball] = _ball_visual_ages[source_ball]
		_ball_effect_elapsed[destination_ball] = _ball_effect_elapsed[source_ball]
		_ball_effect_durations[destination_ball] = _ball_effect_durations[source_ball]
		_ball_effect_kinds[destination_ball] = _ball_effect_kinds[source_ball]


func _acquire_handle_slot() -> int:
	if _free_handle_count > 0:
		_free_handle_count -= 1
		return int(_free_handle_slots[_free_handle_count])
	if _next_handle_slot >= _handle_capacity:
		return INVALID_SLOT
	var slot := _next_handle_slot
	_next_handle_slot += 1
	return slot


func _allocate_generation() -> int:
	var generation := _next_handle_generation
	_next_handle_generation += 1
	if _next_handle_generation > MAX_HANDLE_GENERATION:
		_next_handle_generation = 1
	return generation


func _resolve_dense_slot(handle: int) -> int:
	var handle_slot := get_handle_slot(handle)
	if handle_slot < 0 or handle_slot >= _handle_capacity:
		return INVALID_SLOT
	var generation := get_handle_generation(handle)
	if generation <= 0 or _handle_generations[handle_slot] != generation:
		return INVALID_SLOT
	var dense_slot := int(_dense_slots_by_handle_slot[handle_slot])
	if dense_slot < 0 or dense_slot >= _record_count:
		return INVALID_SLOT
	if _states[dense_slot] == SlotState.TOMBSTONE:
		return INVALID_SLOT
	return dense_slot


func _encode_handle(handle_slot: int, generation: int) -> int:
	return (generation << HANDLE_SLOT_BITS) | (handle_slot + 1)


func _ball_slot(dense_slot: int, ball_index: int) -> int:
	return dense_slot * BALL_COUNT + ball_index


func _valid_completion(index: int) -> bool:
	return index >= 0 and index < _completion_count


func _valid_terminal(index: int) -> bool:
	return index >= 0 and index < _terminal_count


func _resize_record_storage(capacity: int) -> void:
	_modes.resize(capacity)
	_profiles.resize(capacity)
	_states.resize(capacity)
	_record_generations.resize(capacity)
	_handle_slots.resize(capacity)
	_spawn_physics_frames.resize(capacity)
	_spawn_sequences.resize(capacity)
	_speeds.resize(capacity)
	_remaining_lifetimes.resize(capacity)
	_homing_turn_rates.resize(capacity)
	_damages.resize(capacity)
	_source_enemy_ids.resize(capacity)
	_projectile_ids.resize(capacity)
	_target_instance_ids.resize(capacity)
	_target_refresh_left.resize(capacity)
	_burn_durations.resize(capacity)
	_burn_levels.resize(capacity)
	_source_faction_ids.resize(capacity)
	_source_credit_peer_ids.resize(capacity)
	_source_instigator_entity_ids.resize(capacity)
	_source_event_ids.resize(capacity)
	_active_ball_masks.resize(capacity)
	_visible_effect_masks.resize(capacity)
	var ball_capacity := capacity * BALL_COUNT
	_ball_positions.resize(ball_capacity)
	_ball_directions.resize(ball_capacity)
	_ball_visual_ages.resize(ball_capacity)
	_ball_effect_elapsed.resize(ball_capacity)
	_ball_effect_durations.resize(ball_capacity)
	_ball_effect_kinds.resize(ball_capacity)
	_record_capacity = capacity


func _resize_handle_storage(capacity: int) -> void:
	var old_capacity := _handle_capacity
	_handle_generations.resize(capacity)
	_dense_slots_by_handle_slot.resize(capacity)
	_free_handle_slots.resize(capacity)
	for slot in range(old_capacity, capacity):
		_dense_slots_by_handle_slot[slot] = INVALID_SLOT
	_handle_capacity = capacity


func _resize_completion_storage(capacity: int) -> void:
	_completion_handles.resize(capacity)
	_completion_projectile_ids.resize(capacity)
	_completion_ball_indices.resize(capacity)
	_completion_effect_kinds.resize(capacity)
	_completion_positions.resize(capacity)
	_completion_directions.resize(capacity)
	_completion_source_types.resize(capacity)
	_completion_damage_applied.resize(capacity)
	_completion_capacity = capacity


func _resize_terminal_storage(capacity: int) -> void:
	_terminal_handles.resize(capacity)
	_terminal_projectile_ids.resize(capacity)
	_terminal_spawn_sequences.resize(capacity)
	_terminal_modes.resize(capacity)
	_terminal_profiles.resize(capacity)
	_terminal_capacity = capacity


func prepare_for_runtime_teardown() -> void:
	if _teardown_prepared:
		return
	_teardown_prepared = true
	_teardown_count += 1
	clear()
	_enemy_damageable_spatial_index = null
	_combat_target_index = null
	_combat_relation_service = null
	_enemy_simulation_coordinator = null
	_combat_runtime = null


func clear() -> void:
	set_physics_process(false)
	_modes.resize(0)
	_profiles.resize(0)
	_states.resize(0)
	_record_generations.resize(0)
	_handle_slots.resize(0)
	_spawn_physics_frames.resize(0)
	_spawn_sequences.resize(0)
	_speeds.resize(0)
	_remaining_lifetimes.resize(0)
	_homing_turn_rates.resize(0)
	_damages.resize(0)
	_source_enemy_ids.resize(0)
	_projectile_ids.resize(0)
	_target_instance_ids.resize(0)
	_target_refresh_left.resize(0)
	_burn_durations.resize(0)
	_burn_levels.resize(0)
	_source_faction_ids.resize(0)
	_source_credit_peer_ids.resize(0)
	_source_instigator_entity_ids.resize(0)
	_source_event_ids.resize(0)
	_active_ball_masks.resize(0)
	_visible_effect_masks.resize(0)
	_ball_positions.resize(0)
	_ball_directions.resize(0)
	_ball_visual_ages.resize(0)
	_ball_effect_elapsed.resize(0)
	_ball_effect_durations.resize(0)
	_ball_effect_kinds.resize(0)
	_handle_generations.resize(0)
	_dense_slots_by_handle_slot.resize(0)
	_free_handle_slots.resize(0)
	_completion_handles.resize(0)
	_completion_projectile_ids.resize(0)
	_completion_ball_indices.resize(0)
	_completion_effect_kinds.resize(0)
	_completion_positions.resize(0)
	_completion_directions.resize(0)
	_completion_source_types.resize(0)
	_completion_damage_applied.resize(0)
	_terminal_handles.resize(0)
	_terminal_projectile_ids.resize(0)
	_terminal_spawn_sequences.resize(0)
	_terminal_modes.resize(0)
	_terminal_profiles.resize(0)
	_damageable_query_results.clear()
	_enemy_query_results.clear()
	_endpoint_target = null
	_endpoint_target_kind = TargetKind.NONE
	_endpoint_target_id = 0
	_record_capacity = 0
	_record_count = 0
	_active_slot_count = 0
	_tombstone_count = 0
	_handle_capacity = 0
	_next_handle_slot = 0
	_free_handle_count = 0
	_completion_capacity = 0
	_completion_count = 0
	_terminal_capacity = 0
	_terminal_count = 0


func get_metrics() -> Dictionary:
	return {
		"dense_records": _record_count,
		"active_slots": _active_slot_count,
		"tombstones": _tombstone_count,
		"reserved_capacity": _record_capacity,
		"completion_records": _completion_count,
		"terminal_records": _terminal_count,
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
		"ball_advances": _metric_ball_advances,
		"homing_updates": _metric_homing_updates,
		"retargets": _metric_retargets,
		"endpoint_queries": _metric_endpoint_queries,
		"player_exact_queries": _metric_player_exact_queries,
		"plant_broad_queries": _metric_plant_broad_queries,
		"plant_exact_queries": _metric_plant_exact_queries,
		"enemy_broad_queries": _metric_enemy_broad_queries,
		"enemy_exact_queries": _metric_enemy_exact_queries,
		"compensation_sweeps": _metric_compensation_sweeps,
		"damage_applications": _metric_damage_applications,
		"burn_applications": _metric_burn_applications,
		"compactions": _metric_compactions,
		"compacted_tombstones": _metric_compacted_tombstones,
	}


func _exit_tree() -> void:
	prepare_for_runtime_teardown()
