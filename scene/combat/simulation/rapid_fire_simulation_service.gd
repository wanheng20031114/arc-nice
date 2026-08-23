extends Node
class_name RapidFireSimulationService

## Data-oriented simulation boundary for high-volume rapid-fire projectiles.
## The kernel owns only scalar simulation state. It does not discover or retain
## projectile Nodes and does not write damage, networking, presentation, or pool
## outcomes. Production AK routing remains outside this phase.

enum Mode {
	DISABLED,
	SHADOW,
	DATA,
}

enum Profile {
	INVALID,
	AK,
}

enum SlotState {
	EMPTY,
	PENDING_ACTIVATION,
	ACTIVE,
	TOMBSTONE,
}

const PROFILE_AK := &"ak"
const INVALID_HANDLE := 0
const INVALID_SLOT := -1
const HANDLE_SLOT_BITS := 32
const HANDLE_SLOT_MASK := 0xFFFFFFFF
const MAX_HANDLE_GENERATION := 0x7FFFFFFF
const MIN_GROWTH_CAPACITY := 64

var _combat_runtime: CombatRuntimeBase = null
var _enemy_simulation_coordinator: EnemySimulationCoordinator = null
var _teardown_prepared := false
var _teardown_count := 0

# Dense simulation records. `_record_count` is the initialized prefix; storage
# is resized ahead of use so the physics loop never grows a container.
var _positions := PackedVector2Array()
var _directions := PackedVector2Array()
var _speeds := PackedFloat64Array()
var _remaining_lifetimes := PackedFloat64Array()
var _damages := PackedInt32Array()
var _source_enemy_ids := PackedInt64Array()
var _projectile_ids := PackedInt64Array()
var _spawn_physics_frames := PackedInt64Array()
var _states := PackedInt32Array()
var _record_generations := PackedInt32Array()
var _profiles := PackedInt32Array()
var _world_check_intervals := PackedInt32Array()
var _world_check_phases := PackedInt32Array()
var _world_step_indices := PackedInt32Array()
var _world_query_due_states := PackedByteArray()
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
var _completion_spawn_sequences := PackedInt64Array()
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
var _metric_compactions := 0
var _metric_compacted_tombstones := 0
var _metric_difference_records := 0


func _init() -> void:
	set_physics_process(false)


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
	world_check_phase: int
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
		world_check_phase
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
	_spawn_physics_frames[dense_slot] = Engine.get_physics_frames()
	_states[dense_slot] = SlotState.PENDING_ACTIVATION
	_record_generations[dense_slot] = generation
	_profiles[dense_slot] = profile
	_world_check_intervals[dense_slot] = world_check_interval
	_world_check_phases[dense_slot] = world_check_phase
	_world_step_indices[dense_slot] = 0
	_world_query_due_states[dense_slot] = 0
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


func get_completion_spawn_sequence(index: int) -> int:
	return (
		int(_completion_spawn_sequences[index])
		if index >= 0 and index < _completion_count
		else 0
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
	_spawn_physics_frames.resize(0)
	_states.resize(0)
	_record_generations.resize(0)
	_profiles.resize(0)
	_world_check_intervals.resize(0)
	_world_check_phases.resize(0)
	_world_step_indices.resize(0)
	_world_query_due_states.resize(0)
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
	_completion_spawn_sequences.resize(0)
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
		"compactions": _metric_compactions,
		"compacted_tombstones": _metric_compacted_tombstones,
		"recorded_differences": _metric_difference_records,
	}


func _physics_process(delta: float) -> void:
	_completion_count = 0
	if _record_count <= 0:
		set_physics_process(false)
		return
	var valid_delta := is_finite(delta) and delta > 0.0
	var physics_frame := Engine.get_physics_frames()
	var initial_record_count := _record_count
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
		var current_check_phase := int(_world_step_indices[dense_slot])
		var world_check_interval := int(_world_check_intervals[dense_slot])
		_world_step_indices[dense_slot] = (
			current_check_phase + 1
		) % world_check_interval
		_world_query_due_states[dense_slot] = int(
			current_check_phase == int(_world_check_phases[dense_slot])
		)
		var remaining_after_step := _remaining_lifetimes[dense_slot] - delta
		_positions[dense_slot] += (
			_directions[dense_slot]
			* _speeds[dense_slot]
			* delta
		)
		_remaining_lifetimes[dense_slot] = maxf(
			remaining_after_step,
			0.0
		)
		_simulation_ticks[dense_slot] += 1
		_metric_advances += 1
		if remaining_after_step <= 0.0:
			_append_completion(dense_slot)
			_mark_tombstone(dense_slot)
			_metric_lifetime_completions += 1
	if _tombstone_count > 0:
		_stable_compact_tombstones()
	set_physics_process(_record_count > 0)


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
	world_check_phase: int
) -> bool:
	return (
		not _teardown_prepared
		and (mode == Mode.SHADOW or mode == Mode.DATA)
		and profile == Profile.AK
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
		and world_check_interval > 0
		and world_check_phase >= 0
		and world_check_phase < world_check_interval
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
	_spawn_physics_frames.resize(new_capacity)
	_states.resize(new_capacity)
	_record_generations.resize(new_capacity)
	_profiles.resize(new_capacity)
	_world_check_intervals.resize(new_capacity)
	_world_check_phases.resize(new_capacity)
	_world_step_indices.resize(new_capacity)
	_world_query_due_states.resize(new_capacity)
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
	_completion_spawn_sequences.resize(new_capacity)
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


func _append_completion(dense_slot: int) -> void:
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
	_completion_positions[completion_index] = _positions[dense_slot]
	_completion_spawn_sequences[completion_index] = _spawn_sequences[dense_slot]


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
	_spawn_physics_frames[to_slot] = _spawn_physics_frames[from_slot]
	_states[to_slot] = _states[from_slot]
	_record_generations[to_slot] = _record_generations[from_slot]
	_profiles[to_slot] = _profiles[from_slot]
	_world_check_intervals[to_slot] = _world_check_intervals[from_slot]
	_world_check_phases[to_slot] = _world_check_phases[from_slot]
	_world_step_indices[to_slot] = _world_step_indices[from_slot]
	_world_query_due_states[to_slot] = _world_query_due_states[from_slot]
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
	_spawn_physics_frames[dense_slot] = 0
	_states[dense_slot] = SlotState.EMPTY
	_record_generations[dense_slot] = 0
	_profiles[dense_slot] = Profile.INVALID
	_world_check_intervals[dense_slot] = 0
	_world_check_phases[dense_slot] = 0
	_world_step_indices[dense_slot] = 0
	_world_query_due_states[dense_slot] = 0
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
	_metric_compactions = 0
	_metric_compacted_tombstones = 0
	_metric_difference_records = 0


func _exit_tree() -> void:
	prepare_for_runtime_teardown()
