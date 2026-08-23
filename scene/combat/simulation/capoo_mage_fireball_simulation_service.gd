extends Node
class_name CapooMageFireballSimulationService

const CompleteShapeQuery2D := preload(
	"res://scene/combat/physics/complete_shape_query_2d.gd"
)

## Fixed-storage motion kernel for Capoo Mage fireballs. The kernel owns no
## presentation and applies no damage. DATA completion records retain a copied
## damage snapshot for the authoritative explosion-resolution consumer;
## REPLICA records always complete with zero damage.

enum SlotState {
	EMPTY,
	PENDING_ACTIVATION,
	ACTIVE,
	TOMBSTONE,
}

enum Mode {
	DATA,
	REPLICA,
}

enum Profile {
	INVALID,
	NORMAL,
}

enum CompletionReason {
	NONE,
	WORLD,
	DIRECT_HIT,
	LIFETIME,
}

const INVALID_HANDLE := 0
const INVALID_SLOT := -1
const HANDLE_SLOT_BITS := 32
const HANDLE_SLOT_MASK := 0xFFFFFFFF
const MAX_HANDLE_GENERATION := 0x7FFFFFFF
const WORLD_COLLISION_MASK := 1
const DAMAGEABLE_COLLISION_MASK := 2 | 4 | 512
const DIRECT_CONTACT_BATCH_SIZE := 64
const DEFAULT_RADIUS := 10.5
const DEFAULT_HOMING_TURN_RATE := 0.65
const SOURCE_TYPE := &"capoo_mage_fireball"

var _combat_runtime: CombatRuntimeBase = null
var _enemy_simulation_coordinator: EnemySimulationCoordinator = null
var _combat_relation_service: CombatRelationService = null
var _teardown_prepared := false

var _positions := PackedVector2Array()
var _directions := PackedVector2Array()
var _speeds := PackedFloat64Array()
var _remaining_lifetimes := PackedFloat64Array()
var _damages := PackedInt32Array()
var _radii := PackedFloat64Array()
var _homing_turn_rates := PackedFloat64Array()
var _projectile_ids := PackedInt64Array()
var _spawn_physics_frames := PackedInt64Array()
var _visual_ages := PackedFloat64Array()
var _states := PackedInt32Array()
var _modes := PackedInt32Array()
var _profiles := PackedInt32Array()
var _record_generations := PackedInt32Array()
var _handle_slots := PackedInt32Array()
var _target_instance_ids := PackedInt64Array()
var _target_unavailable_reported := PackedByteArray()
var _target_refs: Array[WeakRef] = []
var _source_snapshots: Array[DamageSourceSnapshot] = []
var _record_capacity := 0
var _record_count := 0
var _live_count := 0
var _data_live_count := 0
var _replica_live_count := 0
var _tombstone_count := 0

var _handle_generations := PackedInt32Array()
var _dense_slots_by_handle_slot := PackedInt32Array()
var _free_handle_slots := PackedInt32Array()
var _handle_capacity := 0
var _next_handle_slot := 0
var _free_handle_count := 0
var _next_handle_generation := 1

var _completion_handles := PackedInt64Array()
var _completion_projectile_ids := PackedInt64Array()
var _completion_positions := PackedVector2Array()
var _completion_directions := PackedVector2Array()
var _completion_reasons := PackedInt32Array()
var _completion_modes := PackedInt32Array()
var _completion_profiles := PackedInt32Array()
var _completion_damages := PackedInt32Array()
var _completion_radii := PackedFloat64Array()
var _completion_target_instance_ids := PackedInt64Array()
var _completion_direct_hits: Array[Node2D] = []
var _completion_source_snapshots: Array[DamageSourceSnapshot] = []
var _completion_capacity := 0
var _completion_count := 0

var _world_query := PhysicsRayQueryParameters2D.create(
	Vector2.ZERO,
	Vector2.ZERO,
	WORLD_COLLISION_MASK
)
var _direct_shape := CircleShape2D.new()
var _direct_query := PhysicsShapeQueryParameters2D.new()

var _metric_reserves := 0
var _metric_reserve_rejections := 0
var _metric_spawns := 0
var _metric_spawn_rejections := 0
var _metric_releases := 0
var _metric_activation_skips := 0
var _metric_activations := 0
var _metric_ticks := 0
var _metric_advances := 0
var _metric_homing_updates := 0
var _metric_homing_targets_lost := 0
var _metric_replica_target_rebinds := 0
var _metric_replica_target_rebind_noops := 0
var _metric_replica_target_rebind_rejections := 0
var _metric_world_queries := 0
var _metric_direct_queries := 0
var _metric_world_completions := 0
var _metric_direct_completions := 0
var _metric_lifetime_completions := 0
var _metric_compactions := 0
var _metric_compacted_tombstones := 0
var _metric_drains := 0
var _metric_drained_completions := 0
var _metric_clears := 0
var _metric_teardowns := 0


func _init() -> void:
	set_physics_process(false)
	_world_query.collide_with_bodies = true
	_world_query.collide_with_areas = false
	_direct_shape.radius = DEFAULT_RADIUS
	_direct_query.shape = _direct_shape
	_direct_query.collision_mask = DAMAGEABLE_COLLISION_MASK
	_direct_query.collide_with_bodies = true
	_direct_query.collide_with_areas = false


func bind_context(
	combat_runtime: CombatRuntimeBase,
	coordinator: EnemySimulationCoordinator
) -> bool:
	if (
		_teardown_prepared
		or combat_runtime == null
		or coordinator == null
		or not is_instance_valid(combat_runtime)
		or not is_instance_valid(coordinator)
		or coordinator.get_parent() != combat_runtime
	):
		return false
	if _combat_runtime != null and (
		_combat_runtime != combat_runtime
		or _enemy_simulation_coordinator != coordinator
	):
		return false
	_combat_runtime = combat_runtime
	_enemy_simulation_coordinator = coordinator
	_combat_relation_service = combat_runtime.get_combat_relation_service()
	if _combat_relation_service == null:
		_combat_runtime = null
		_enemy_simulation_coordinator = null
		return false
	return true


func is_bound() -> bool:
	return (
		not _teardown_prepared
		and _combat_runtime != null
		and _enemy_simulation_coordinator != null
		and is_instance_valid(_combat_runtime)
		and is_instance_valid(_enemy_simulation_coordinator)
	)


func reserve(minimum_capacity: int) -> bool:
	if _teardown_prepared or minimum_capacity < 0:
		_metric_reserve_rejections += 1
		return false
	if minimum_capacity <= _record_capacity:
		return true
	_resize_record_storage(minimum_capacity)
	_resize_handle_storage(minimum_capacity)
	_resize_completion_storage(minimum_capacity)
	_metric_reserves += 1
	return true


func spawn_authoritative(
	position: Vector2,
	direction: Vector2,
	damage: int,
	speed: float,
	lifetime: float,
	radius: float,
	target: Node2D,
	homing_turn_rate: float,
	damage_source_snapshot: DamageSourceSnapshot,
	profile: Profile = Profile.NORMAL
) -> int:
	return _spawn_record(
		Mode.DATA,
		0,
		position,
		direction,
		damage,
		speed,
		lifetime,
		radius,
		target,
		homing_turn_rate,
		0.0,
		damage_source_snapshot,
		profile
	)


func spawn_replica(
	projectile_id: int,
	position: Vector2,
	direction: Vector2,
	speed: float,
	lifetime: float,
	radius: float,
	target: Node2D,
	homing_turn_rate: float,
	transit_age: float,
	profile: Profile = Profile.NORMAL,
	damage_source_snapshot: DamageSourceSnapshot = null,
	authoritative_visual_age: float = -1.0
) -> int:
	var normalized_direction := direction.normalized()
	var compensated_position := position + normalized_direction * speed * transit_age
	var compensated_lifetime := lifetime - transit_age
	var resolved_visual_age := transit_age
	if authoritative_visual_age >= 0.0:
		resolved_visual_age = authoritative_visual_age + transit_age
	var replica_source := (
		DamageSourceSnapshot.create(
			damage_source_snapshot.source_faction_id,
			damage_source_snapshot.credit_peer_id,
			damage_source_snapshot.instigator_entity_id,
			projectile_id,
			damage_source_snapshot.source_type
		)
		if damage_source_snapshot != null
		else DamageSourceSnapshot.create(
			CombatRelationService.HOSTILE_WAVE,
			0,
			0,
			projectile_id,
			SOURCE_TYPE
		)
	)
	return _spawn_record(
		Mode.REPLICA,
		projectile_id,
		compensated_position,
		normalized_direction,
		0,
		speed,
		compensated_lifetime,
		radius,
		target,
		homing_turn_rate,
		resolved_visual_age,
		replica_source,
		profile
	)


func _spawn_record(
	mode: Mode,
	projectile_id: int,
	position: Vector2,
	direction: Vector2,
	damage: int,
	speed: float,
	lifetime: float,
	radius: float,
	target: Node2D,
	homing_turn_rate: float,
	visual_age: float,
	damage_source_snapshot: DamageSourceSnapshot,
	profile: Profile
) -> int:
	if not _is_valid_spawn(
		mode, projectile_id, position, direction, damage, speed, lifetime,
		radius, target, homing_turn_rate, visual_age, damage_source_snapshot,
		profile
	):
		_metric_spawn_rejections += 1
		return INVALID_HANDLE
	var handle_slot := _acquire_handle_slot()
	if handle_slot < 0:
		_metric_spawn_rejections += 1
		return INVALID_HANDLE
	var dense_slot := _record_count
	var generation := int(_handle_generations[handle_slot])
	_record_count += 1
	_live_count += 1
	if mode == Mode.DATA:
		_data_live_count += 1
	else:
		_replica_live_count += 1
	_positions[dense_slot] = position
	_directions[dense_slot] = direction.normalized()
	_speeds[dense_slot] = speed
	_remaining_lifetimes[dense_slot] = lifetime
	_damages[dense_slot] = damage if mode == Mode.DATA else 0
	_radii[dense_slot] = radius
	_homing_turn_rates[dense_slot] = homing_turn_rate
	_projectile_ids[dense_slot] = projectile_id
	_spawn_physics_frames[dense_slot] = Engine.get_physics_frames()
	_visual_ages[dense_slot] = visual_age
	_states[dense_slot] = SlotState.PENDING_ACTIVATION
	_modes[dense_slot] = mode
	_profiles[dense_slot] = profile
	_record_generations[dense_slot] = generation
	_handle_slots[dense_slot] = handle_slot
	_target_instance_ids[dense_slot] = target.get_instance_id() if target != null else 0
	_target_unavailable_reported[dense_slot] = 0
	_target_refs[dense_slot] = weakref(target) if target != null else null
	_source_snapshots[dense_slot] = damage_source_snapshot.duplicate_snapshot()
	_dense_slots_by_handle_slot[handle_slot] = dense_slot
	_metric_spawns += 1
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
	var snapshot := _source_snapshots[dense_slot]
	_source_snapshots[dense_slot] = DamageSourceSnapshot.create(
		snapshot.source_faction_id,
		snapshot.credit_peer_id,
		snapshot.instigator_entity_id,
		projectile_id,
		snapshot.source_type
	)
	return true


func release(handle: int) -> bool:
	var dense_slot := _resolve_dense_slot(handle)
	if dense_slot < 0:
		return false
	_mark_tombstone(dense_slot)
	_stable_compact_tombstones()
	_metric_releases += 1
	set_physics_process(_record_count > 0)
	return true


func is_handle_live(handle: int) -> bool:
	return _resolve_dense_slot(handle) >= 0


func get_position(handle: int) -> Vector2:
	var dense_slot := _resolve_dense_slot(handle)
	return _positions[dense_slot] if dense_slot >= 0 else Vector2.ZERO


func get_direction(handle: int) -> Vector2:
	var dense_slot := _resolve_dense_slot(handle)
	return _directions[dense_slot] if dense_slot >= 0 else Vector2.ZERO


func get_speed(handle: int) -> float:
	var dense_slot := _resolve_dense_slot(handle)
	return _speeds[dense_slot] if dense_slot >= 0 else 0.0


func get_damage(handle: int) -> int:
	var dense_slot := _resolve_dense_slot(handle)
	return int(_damages[dense_slot]) if dense_slot >= 0 else 0


func get_remaining_lifetime(handle: int) -> float:
	var dense_slot := _resolve_dense_slot(handle)
	return _remaining_lifetimes[dense_slot] if dense_slot >= 0 else 0.0


func get_radius(handle: int) -> float:
	var dense_slot := _resolve_dense_slot(handle)
	return _radii[dense_slot] if dense_slot >= 0 else 0.0


func get_homing_turn_rate(handle: int) -> float:
	var dense_slot := _resolve_dense_slot(handle)
	return _homing_turn_rates[dense_slot] if dense_slot >= 0 else 0.0


func get_visual_age(handle: int) -> float:
	var dense_slot := _resolve_dense_slot(handle)
	return _visual_ages[dense_slot] if dense_slot >= 0 else 0.0


func get_projectile_id(handle: int) -> int:
	var dense_slot := _resolve_dense_slot(handle)
	return int(_projectile_ids[dense_slot]) if dense_slot >= 0 else 0


func get_slot_mode(handle: int) -> Mode:
	var dense_slot := _resolve_dense_slot(handle)
	return int(_modes[dense_slot]) as Mode if dense_slot >= 0 else Mode.DATA


func get_slot_profile(handle: int) -> Profile:
	var dense_slot := _resolve_dense_slot(handle)
	return int(_profiles[dense_slot]) as Profile if dense_slot >= 0 else Profile.INVALID


func get_target(handle: int) -> Node2D:
	var dense_slot := _resolve_dense_slot(handle)
	return _get_live_homing_target(dense_slot) if dense_slot >= 0 else null


func get_target_instance_id(handle: int) -> int:
	var dense_slot := _resolve_dense_slot(handle)
	return int(_target_instance_ids[dense_slot]) if dense_slot >= 0 else 0


func rebind_replica_target(handle: int, target: Node2D) -> bool:
	var dense_slot := _resolve_dense_slot(handle)
	if (
		dense_slot < 0
		or int(_modes[dense_slot]) != Mode.REPLICA
		or target == null
		or not is_instance_valid(target)
		or not (target is Player or target is PlantDefense or target is Enemy)
	):
		_metric_replica_target_rebind_rejections += 1
		return false
	var target_instance_id := target.get_instance_id()
	var current_ref := _target_refs[dense_slot]
	var current_target := (
		current_ref.get_ref() as Node2D
		if current_ref != null
		else null
	)
	if (
		int(_target_instance_ids[dense_slot]) == target_instance_id
		and current_target == target
		and is_instance_valid(current_target)
	):
		_metric_replica_target_rebind_noops += 1
		return true
	_target_instance_ids[dense_slot] = target_instance_id
	_target_unavailable_reported[dense_slot] = 0
	_target_refs[dense_slot] = weakref(target)
	_metric_replica_target_rebinds += 1
	return true


func get_damage_source_snapshot(handle: int) -> DamageSourceSnapshot:
	var dense_slot := _resolve_dense_slot(handle)
	if dense_slot < 0 or _source_snapshots[dense_slot] == null:
		return null
	return _source_snapshots[dense_slot].duplicate_snapshot()


func get_live_count() -> int:
	return _live_count


func get_dense_record_count() -> int:
	return _record_count


func get_reserved_capacity() -> int:
	return _record_capacity


func get_handle_at_stable_index(index: int) -> int:
	if index < 0 or index >= _record_count or _states[index] == SlotState.TOMBSTONE:
		return INVALID_HANDLE
	return _encode_handle(_handle_slots[index], _record_generations[index])


func get_position_at_stable_index(index: int) -> Vector2:
	return _positions[index] if index >= 0 and index < _record_count else Vector2.ZERO


func get_direction_at_stable_index(index: int) -> Vector2:
	return _directions[index] if index >= 0 and index < _record_count else Vector2.ZERO


func get_visual_age_at_stable_index(index: int) -> float:
	return _visual_ages[index] if index >= 0 and index < _record_count else 0.0


func get_spawn_physics_frame_at_stable_index(index: int) -> int:
	return int(_spawn_physics_frames[index]) if index >= 0 and index < _record_count else -1


func get_mode_at_stable_index(index: int) -> Mode:
	return int(_modes[index]) as Mode if index >= 0 and index < _record_count else Mode.DATA


func get_profile_at_stable_index(index: int) -> Profile:
	return int(_profiles[index]) as Profile if index >= 0 and index < _record_count else Profile.INVALID


func get_target_at_stable_index(index: int) -> Node2D:
	return _get_live_homing_target(index) if index >= 0 and index < _record_count else null


func _physics_process(delta: float) -> void:
	advance(delta)


func advance(delta: float) -> void:
	if not is_bound() or _record_count <= 0:
		set_physics_process(false)
		return
	var valid_delta := maxf(delta, 0.0) if is_finite(delta) else 0.0
	var physics_frame := Engine.get_physics_frames()
	var initial_count := _record_count
	_metric_ticks += 1
	for dense_slot in range(initial_count):
		if _states[dense_slot] == SlotState.TOMBSTONE:
			continue
		if physics_frame <= _spawn_physics_frames[dense_slot]:
			_metric_activation_skips += 1
			continue
		if _states[dense_slot] == SlotState.PENDING_ACTIVATION:
			_states[dense_slot] = SlotState.ACTIVE
			_metric_activations += 1
		if valid_delta > 0.0:
			_advance_record(dense_slot, valid_delta)
	if _tombstone_count > 0:
		_stable_compact_tombstones()
	set_physics_process(_record_count > 0)


func _advance_record(dense_slot: int, delta: float) -> void:
	_metric_advances += 1
	_visual_ages[dense_slot] += delta
	_update_homing(dense_slot, delta)
	var current_position := _positions[dense_slot]
	var next_position := current_position + _directions[dense_slot] * _speeds[dense_slot] * delta
	var world_hit := _query_world_hit(current_position, next_position)
	if not world_hit.is_empty():
		_complete_record(
			dense_slot,
			CompletionReason.WORLD,
			world_hit.get("position", next_position) as Vector2,
			null
		)
		return
	var direct_hit := _query_direct_hit(dense_slot, next_position)
	if direct_hit != null:
		_complete_record(dense_slot, CompletionReason.DIRECT_HIT, next_position, direct_hit)
		return
	_positions[dense_slot] = next_position
	_remaining_lifetimes[dense_slot] = maxf(_remaining_lifetimes[dense_slot] - delta, 0.0)
	if _remaining_lifetimes[dense_slot] <= 0.0:
		_complete_record(dense_slot, CompletionReason.LIFETIME, next_position, null)


func _update_homing(dense_slot: int, delta: float) -> void:
	var turn_rate := float(_homing_turn_rates[dense_slot])
	if turn_rate <= 0.0:
		return
	var target := _get_live_homing_target(dense_slot)
	if target == null:
		return
	var desired_direction := _positions[dense_slot].direction_to(target.global_position)
	if desired_direction == Vector2.ZERO:
		return
	var direction := _directions[dense_slot]
	var angle_delta := direction.angle_to(desired_direction)
	var max_turn := turn_rate * delta
	_directions[dense_slot] = direction.rotated(
		clampf(angle_delta, -max_turn, max_turn)
	).normalized()
	_metric_homing_updates += 1


func _get_live_homing_target(dense_slot: int) -> Node2D:
	if dense_slot < 0 or dense_slot >= _record_count:
		return null
	var target_ref := _target_refs[dense_slot]
	if target_ref == null:
		return null
	var target := target_ref.get_ref() as Node2D
	if target == null or not is_instance_valid(target):
		_record_homing_target_unavailable(dense_slot)
		_target_refs[dense_slot] = null
		return null
	var player := target as Player
	var plant := target as PlantDefense
	var enemy := target as Enemy
	var alive := (
		(player != null and not player.is_dead)
		or (plant != null and not plant.is_dead and not plant.is_removing)
		or (enemy != null and not enemy.is_dead)
	)
	if not alive:
		_record_homing_target_unavailable(dense_slot)
		return null
	_target_unavailable_reported[dense_slot] = 0
	return target


func _record_homing_target_unavailable(dense_slot: int) -> void:
	if _target_unavailable_reported[dense_slot] != 0:
		return
	_target_unavailable_reported[dense_slot] = 1
	_metric_homing_targets_lost += 1


func _query_world_hit(from_position: Vector2, to_position: Vector2) -> Dictionary:
	_metric_world_queries += 1
	_world_query.from = from_position
	_world_query.to = to_position
	return _combat_runtime.get_world_2d().direct_space_state.intersect_ray(_world_query)


func _query_direct_hit(dense_slot: int, to_position: Vector2) -> Node2D:
	_metric_direct_queries += 1
	_direct_shape.radius = _radii[dense_slot]
	_direct_query.transform = Transform2D(0.0, to_position)
	var hits := CompleteShapeQuery2D.intersect_shape_all(
		_combat_runtime.get_world_2d().direct_space_state,
		_direct_query,
		DIRECT_CONTACT_BATCH_SIZE
	)
	for hit in hits:
		var body := hit.get("collider") as Node2D
		if _is_direct_hit_admitted(dense_slot, body):
			return body
	return null


func _is_direct_hit_admitted(dense_slot: int, body: Node2D) -> bool:
	if body == null or not is_instance_valid(body):
		return false
	var player := body as Player
	var plant := body as PlantDefense
	var enemy := body as Enemy
	if player == null and plant == null and enemy == null:
		# The legacy Area2D exploded on every PhysicsBody2D admitted by its
		# damageable collision mask, even when that body did not receive damage.
		# Keep that contact semantic; the shared explosion resolver still decides
		# independently which typed bodies may take authoritative damage.
		return true
	if int(_modes[dense_slot]) == Mode.REPLICA:
		return true
	var target_faction_id := (
		player.get_combat_faction_id()
		if player != null
		else plant.get_combat_faction_id() if plant != null else enemy.get_combat_faction_id()
	)
	var source_snapshot := _source_snapshots[dense_slot]
	return (
		source_snapshot != null
		and source_snapshot.is_valid()
		and _combat_relation_service.is_hostile(
			source_snapshot.source_faction_id,
			target_faction_id
		)
	)


func _complete_record(
	dense_slot: int,
	reason: CompletionReason,
	position: Vector2,
	direct_hit: Node2D
) -> void:
	if _completion_count >= _completion_capacity:
		push_error("CapooMageFireballSimulationService completion reserve exhausted.")
		return
	var completion_index := _completion_count
	_completion_count += 1
	_completion_handles[completion_index] = _encode_handle(
		int(_handle_slots[dense_slot]), int(_record_generations[dense_slot])
	)
	_completion_projectile_ids[completion_index] = _projectile_ids[dense_slot]
	_completion_positions[completion_index] = position
	_completion_directions[completion_index] = _directions[dense_slot]
	_completion_reasons[completion_index] = reason
	_completion_modes[completion_index] = _modes[dense_slot]
	_completion_profiles[completion_index] = _profiles[dense_slot]
	_completion_damages[completion_index] = _damages[dense_slot]
	_completion_radii[completion_index] = _radii[dense_slot]
	_completion_target_instance_ids[completion_index] = _target_instance_ids[dense_slot]
	_completion_direct_hits[completion_index] = direct_hit
	_completion_source_snapshots[completion_index] = _source_snapshots[dense_slot].duplicate_snapshot()
	if reason == CompletionReason.WORLD:
		_metric_world_completions += 1
	elif reason == CompletionReason.DIRECT_HIT:
		_metric_direct_completions += 1
	elif reason == CompletionReason.LIFETIME:
		_metric_lifetime_completions += 1
	_mark_tombstone(dense_slot)


func get_completion_count() -> int:
	return _completion_count


func get_completion_handle(index: int) -> int:
	return int(_completion_handles[index]) if _valid_completion(index) else INVALID_HANDLE


func get_completion_projectile_id(index: int) -> int:
	return int(_completion_projectile_ids[index]) if _valid_completion(index) else 0


func get_completion_position(index: int) -> Vector2:
	return _completion_positions[index] if _valid_completion(index) else Vector2.ZERO


func get_completion_direction(index: int) -> Vector2:
	return _completion_directions[index] if _valid_completion(index) else Vector2.ZERO


func get_completion_reason(index: int) -> CompletionReason:
	return int(_completion_reasons[index]) as CompletionReason if _valid_completion(index) else CompletionReason.NONE


func get_completion_mode(index: int) -> Mode:
	return int(_completion_modes[index]) as Mode if _valid_completion(index) else Mode.DATA


func get_completion_profile(index: int) -> Profile:
	return int(_completion_profiles[index]) as Profile if _valid_completion(index) else Profile.INVALID


func get_completion_damage(index: int) -> int:
	return int(_completion_damages[index]) if _valid_completion(index) else 0


func get_completion_radius(index: int) -> float:
	return float(_completion_radii[index]) if _valid_completion(index) else 0.0


func get_completion_direct_hit(index: int) -> Node2D:
	return _completion_direct_hits[index] if _valid_completion(index) else null


func get_completion_target_instance_id(index: int) -> int:
	return int(_completion_target_instance_ids[index]) if _valid_completion(index) else 0


func get_completion_damage_source_snapshot(index: int) -> DamageSourceSnapshot:
	if not _valid_completion(index) or _completion_source_snapshots[index] == null:
		return null
	return _completion_source_snapshots[index].duplicate_snapshot()


func drain_completions(result: Array[Dictionary]) -> int:
	result.clear()
	for index in range(_completion_count):
		result.append({
			"handle": int(_completion_handles[index]),
			"projectile_id": int(_completion_projectile_ids[index]),
			"position": _completion_positions[index],
			"direction": _completion_directions[index],
			"reason": int(_completion_reasons[index]) as CompletionReason,
			"mode": int(_completion_modes[index]) as Mode,
			"profile": int(_completion_profiles[index]) as Profile,
			"damage": int(_completion_damages[index]),
			"radius": float(_completion_radii[index]),
			"target_instance_id": int(_completion_target_instance_ids[index]),
			"direct_hit": _completion_direct_hits[index],
			"damage_source_snapshot": _completion_source_snapshots[index].duplicate_snapshot(),
		})
	var drained_count := _completion_count
	clear_completion_records()
	_metric_drains += 1
	_metric_drained_completions += drained_count
	return drained_count


func clear_completion_records() -> void:
	for index in range(_completion_count):
		_completion_direct_hits[index] = null
		_completion_source_snapshots[index] = null
	_completion_count = 0


func _valid_completion(index: int) -> bool:
	return index >= 0 and index < _completion_count


func clear() -> void:
	for dense_slot in range(_record_count):
		_clear_record_row(dense_slot)
	for handle_slot in range(_next_handle_slot):
		_dense_slots_by_handle_slot[handle_slot] = INVALID_SLOT
		_free_handle_slots[handle_slot] = INVALID_SLOT
	clear_completion_records()
	_record_count = 0
	_live_count = 0
	_data_live_count = 0
	_replica_live_count = 0
	_tombstone_count = 0
	_next_handle_slot = 0
	_free_handle_count = 0
	set_physics_process(false)
	_metric_clears += 1


func teardown() -> void:
	if _teardown_prepared:
		return
	clear()
	_teardown_prepared = true
	_combat_runtime = null
	_enemy_simulation_coordinator = null
	_combat_relation_service = null
	_metric_teardowns += 1


func get_metrics() -> Dictionary:
	return {
		"bound": is_bound(),
		"teardown_prepared": _teardown_prepared,
		"reserved_capacity": _record_capacity,
		"dense_record_count": _record_count,
		"live_count": _live_count,
		"data_live_count": _data_live_count,
		"replica_live_count": _replica_live_count,
		"pending_completions": _completion_count,
		"reserves": _metric_reserves,
		"reserve_rejections": _metric_reserve_rejections,
		"spawns": _metric_spawns,
		"spawn_rejections": _metric_spawn_rejections,
		"releases": _metric_releases,
		"activation_skips": _metric_activation_skips,
		"activations": _metric_activations,
		"ticks": _metric_ticks,
		"advances": _metric_advances,
		"homing_updates": _metric_homing_updates,
		"homing_targets_lost": _metric_homing_targets_lost,
		"replica_target_rebinds": _metric_replica_target_rebinds,
		"replica_target_rebind_noops": _metric_replica_target_rebind_noops,
		"replica_target_rebind_rejections": (
			_metric_replica_target_rebind_rejections
		),
		"world_queries": _metric_world_queries,
		"direct_queries": _metric_direct_queries,
		"world_completions": _metric_world_completions,
		"direct_completions": _metric_direct_completions,
		"lifetime_completions": _metric_lifetime_completions,
		"compactions": _metric_compactions,
		"compacted_tombstones": _metric_compacted_tombstones,
		"drains": _metric_drains,
		"drained_completions": _metric_drained_completions,
		"clears": _metric_clears,
		"teardowns": _metric_teardowns,
	}


func _mark_tombstone(dense_slot: int) -> void:
	if _states[dense_slot] == SlotState.EMPTY or _states[dense_slot] == SlotState.TOMBSTONE:
		return
	_states[dense_slot] = SlotState.TOMBSTONE
	_live_count = maxi(_live_count - 1, 0)
	if int(_modes[dense_slot]) == Mode.DATA:
		_data_live_count = maxi(_data_live_count - 1, 0)
	else:
		_replica_live_count = maxi(_replica_live_count - 1, 0)
	_tombstone_count += 1
	var handle_slot := int(_handle_slots[dense_slot])
	var generation := int(_record_generations[dense_slot])
	if (
		handle_slot >= 0
		and int(_dense_slots_by_handle_slot[handle_slot]) == dense_slot
		and int(_handle_generations[handle_slot]) == generation
	):
		_dense_slots_by_handle_slot[handle_slot] = INVALID_SLOT
		_free_handle_slots[_free_handle_count] = handle_slot
		_free_handle_count += 1


func _stable_compact_tombstones() -> void:
	var previous_record_count := _record_count
	var compacted := _tombstone_count
	var write_slot := 0
	for read_slot in range(previous_record_count):
		if _states[read_slot] == SlotState.TOMBSTONE:
			continue
		if write_slot != read_slot:
			_copy_record(read_slot, write_slot)
		var handle_slot := int(_handle_slots[write_slot])
		_dense_slots_by_handle_slot[handle_slot] = write_slot
		write_slot += 1
	for clear_slot in range(write_slot, previous_record_count):
		_clear_record_row(clear_slot)
	_record_count = write_slot
	_tombstone_count = 0
	_metric_compactions += 1
	_metric_compacted_tombstones += compacted


func _copy_record(from_slot: int, to_slot: int) -> void:
	_positions[to_slot] = _positions[from_slot]
	_directions[to_slot] = _directions[from_slot]
	_speeds[to_slot] = _speeds[from_slot]
	_remaining_lifetimes[to_slot] = _remaining_lifetimes[from_slot]
	_damages[to_slot] = _damages[from_slot]
	_radii[to_slot] = _radii[from_slot]
	_homing_turn_rates[to_slot] = _homing_turn_rates[from_slot]
	_projectile_ids[to_slot] = _projectile_ids[from_slot]
	_spawn_physics_frames[to_slot] = _spawn_physics_frames[from_slot]
	_visual_ages[to_slot] = _visual_ages[from_slot]
	_states[to_slot] = _states[from_slot]
	_modes[to_slot] = _modes[from_slot]
	_profiles[to_slot] = _profiles[from_slot]
	_record_generations[to_slot] = _record_generations[from_slot]
	_handle_slots[to_slot] = _handle_slots[from_slot]
	_target_instance_ids[to_slot] = _target_instance_ids[from_slot]
	_target_unavailable_reported[to_slot] = _target_unavailable_reported[from_slot]
	_target_refs[to_slot] = _target_refs[from_slot]
	_source_snapshots[to_slot] = _source_snapshots[from_slot]


func _clear_record_row(dense_slot: int) -> void:
	_positions[dense_slot] = Vector2.ZERO
	_directions[dense_slot] = Vector2.ZERO
	_speeds[dense_slot] = 0.0
	_remaining_lifetimes[dense_slot] = 0.0
	_damages[dense_slot] = 0
	_radii[dense_slot] = 0.0
	_homing_turn_rates[dense_slot] = 0.0
	_projectile_ids[dense_slot] = 0
	_spawn_physics_frames[dense_slot] = 0
	_visual_ages[dense_slot] = 0.0
	_states[dense_slot] = SlotState.EMPTY
	_modes[dense_slot] = Mode.DATA
	_profiles[dense_slot] = Profile.INVALID
	_record_generations[dense_slot] = 0
	_handle_slots[dense_slot] = INVALID_SLOT
	_target_instance_ids[dense_slot] = 0
	_target_unavailable_reported[dense_slot] = 0
	_target_refs[dense_slot] = null
	_source_snapshots[dense_slot] = null


func _is_valid_spawn(
	mode: Mode,
	projectile_id: int,
	position: Vector2,
	direction: Vector2,
	damage: int,
	speed: float,
	lifetime: float,
	radius: float,
	target: Node2D,
	homing_turn_rate: float,
	visual_age: float,
	damage_source_snapshot: DamageSourceSnapshot,
	profile: Profile
) -> bool:
	return (
		is_bound()
		and _record_count < _record_capacity
		and _live_count + _completion_count < _completion_capacity
		and projectile_id >= 0
		and (mode == Mode.DATA or projectile_id > 0)
		and position.is_finite()
		and direction.is_finite()
		and direction != Vector2.ZERO
		and damage >= 0
		and is_finite(speed)
		and speed >= 0.0
		and is_finite(lifetime)
		and lifetime > 0.0
		and is_finite(radius)
		and radius >= 1.0
		and is_finite(homing_turn_rate)
		and homing_turn_rate >= 0.0
		and is_finite(visual_age)
		and visual_age >= 0.0
		and (target == null or is_instance_valid(target))
		and damage_source_snapshot != null
		and damage_source_snapshot.is_valid()
		and profile == Profile.NORMAL
	)


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
	if handle <= 0:
		return INVALID_SLOT
	var handle_slot := int(handle & HANDLE_SLOT_MASK) - 1
	var generation := int(handle >> HANDLE_SLOT_BITS)
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
		or int(_record_generations[dense_slot]) != generation
		or int(_handle_slots[dense_slot]) != handle_slot
	):
		return INVALID_SLOT
	return dense_slot


func _resize_record_storage(new_capacity: int) -> void:
	_positions.resize(new_capacity)
	_directions.resize(new_capacity)
	_speeds.resize(new_capacity)
	_remaining_lifetimes.resize(new_capacity)
	_damages.resize(new_capacity)
	_radii.resize(new_capacity)
	_homing_turn_rates.resize(new_capacity)
	_projectile_ids.resize(new_capacity)
	_spawn_physics_frames.resize(new_capacity)
	_visual_ages.resize(new_capacity)
	_states.resize(new_capacity)
	_modes.resize(new_capacity)
	_profiles.resize(new_capacity)
	_record_generations.resize(new_capacity)
	_handle_slots.resize(new_capacity)
	_target_instance_ids.resize(new_capacity)
	_target_unavailable_reported.resize(new_capacity)
	_target_refs.resize(new_capacity)
	_source_snapshots.resize(new_capacity)
	for index in range(_record_capacity, new_capacity):
		_handle_slots[index] = INVALID_SLOT
	_record_capacity = new_capacity


func _resize_handle_storage(new_capacity: int) -> void:
	var previous_capacity := _handle_capacity
	_handle_generations.resize(new_capacity)
	_dense_slots_by_handle_slot.resize(new_capacity)
	_free_handle_slots.resize(new_capacity)
	for index in range(previous_capacity, new_capacity):
		_dense_slots_by_handle_slot[index] = INVALID_SLOT
		_free_handle_slots[index] = INVALID_SLOT
	_handle_capacity = new_capacity


func _resize_completion_storage(new_capacity: int) -> void:
	_completion_handles.resize(new_capacity)
	_completion_projectile_ids.resize(new_capacity)
	_completion_positions.resize(new_capacity)
	_completion_directions.resize(new_capacity)
	_completion_reasons.resize(new_capacity)
	_completion_modes.resize(new_capacity)
	_completion_profiles.resize(new_capacity)
	_completion_damages.resize(new_capacity)
	_completion_radii.resize(new_capacity)
	_completion_target_instance_ids.resize(new_capacity)
	_completion_direct_hits.resize(new_capacity)
	_completion_source_snapshots.resize(new_capacity)
	_completion_capacity = new_capacity
