extends CapooSniper
class_name CapooSniperLayeredSemanticHarness

## The authored Sniper scene, warning services and direct-damage path stay
## intact. This fixture replaces only world-dependent target, LOS, navigation
## and body-motion answers so all four policies replay one deterministic script.

const FIXED_PHYSICS_DELTA := 1.0 / 60.0

var forced_target: Node2D = null
var forced_target_valid := true
var forced_los_clear := true
var forced_move_direction := Vector2.RIGHT

var phase_context: StringName = &""
var touch_update_deltas: Array[float] = []
var cooldown_update_deltas: Array[float] = []
var event_order_log := PackedStringArray()
var lock_start_phases: Array[StringName] = []
var fire_commit_phases: Array[StringName] = []
var movement_submission_count := 0
var action_log := PackedStringArray()
var presentation_log := PackedStringArray()
var damage_records: Array[Dictionary] = []
var los_query_count := 0
var warning_update_count := 0
var last_warning_position := Vector2.ZERO
var last_warning_progress := 0.0
var warning_clear_count := 0


func _is_exact_layered_sniper_family() -> bool:
	# Test-only authored subclass: exercise the production family hooks while the
	# production exact-script gate remains fail-closed for arbitrary subclasses.
	return true


func reset_semantic_trace() -> void:
	phase_context = &""
	touch_update_deltas.clear()
	cooldown_update_deltas.clear()
	event_order_log.clear()
	lock_start_phases.clear()
	fire_commit_phases.clear()
	movement_submission_count = 0
	action_log.clear()
	presentation_log.clear()
	action_sequence = 0
	damage_records.clear()
	los_query_count = 0
	warning_update_count = 0
	last_warning_position = Vector2.ZERO
	last_warning_progress = 0.0
	warning_clear_count = 0


func _run_authoritative_physics_step(delta: float) -> void:
	phase_context = &"legacy"
	super._run_authoritative_physics_step(delta)
	phase_context = &""


func _advance_layered_ranged_event_phase(delta: float) -> void:
	phase_context = &"event"
	super._advance_layered_ranged_event_phase(delta)
	phase_context = &""


func _try_consume_layered_ranged_decision_phase(delta: float) -> bool:
	phase_context = &"decision"
	var consumed := super._try_consume_layered_ranged_decision_phase(delta)
	phase_context = &""
	return consumed


func _update_attack_cooldown(delta: float) -> void:
	event_order_log.append("cooldown")
	cooldown_update_deltas.append(delta)
	super._update_attack_cooldown(delta)


func _update_touch_damage(delta: float) -> void:
	event_order_log.append("touch")
	touch_update_deltas.append(delta)
	super._update_touch_damage(delta)


func _advance_lock_state(delta: float) -> bool:
	event_order_log.append("lock")
	return super._advance_lock_state(delta)


func _try_start_lock(candidate_target: Node2D = null) -> bool:
	var started := super._try_start_lock(candidate_target)
	if started:
		lock_start_phases.append(phase_context)
	return started


func _fire_locked_shot(direction: Vector2) -> void:
	var previous_action_count := action_log.size()
	super._fire_locked_shot(direction)
	if (
		action_log.size() > previous_action_count
		and action_log[-1].contains(":sniper_lock_fire:")
	):
		fire_commit_phases.append(phase_context)


func _get_preferred_ranged_combat_target() -> Node2D:
	return forced_target


func _is_ranged_combat_target_valid(target: Node2D) -> bool:
	return (
		forced_target_valid
		and target != null
		and target == forced_target
		and is_instance_valid(target)
		and can_attack_combat_target(target)
	)


func _is_ranged_combat_target_in_range(
	target: Node2D,
	attack_range: float
) -> bool:
	if not _is_ranged_combat_target_valid(target):
		return false
	var safe_range := maxf(attack_range, 0.0)
	return (
		global_position.distance_squared_to(target.global_position)
		<= safe_range * safe_range
	)


func _has_ranged_combat_line(
	target: Node2D,
	_collision_mask_value: int = 1,
	_force_refresh: bool = false
) -> bool:
	los_query_count += 1
	# A committed lock validates relation through its frozen source snapshot.
	# LOS itself must remain a geometric answer if the live caster changes side.
	return forced_los_clear and target != null and is_instance_valid(target)


func _has_frozen_lock_combat_line(
	target: Node2D,
	_collision_mask_value: int,
	_force_refresh: bool
) -> bool:
	los_query_count += 1
	return (
		forced_target_valid
		and forced_los_clear
		and target != null
		and is_instance_valid(target)
		and bool(call(&"_is_frozen_lock_target_valid", target))
	)


func refresh_dynamic_combat_target_decision(_simulation_tick: int) -> void:
	# The test script authors each target/faction edge. Production Sniper still
	# inherits Enemy's dynamic-target refresh unchanged.
	pass


func _get_navigation_move_direction(_delta: float) -> Vector2:
	return forced_move_direction.normalized()


func _move_after_confirmed_no_contact(delta: float = -1.0) -> void:
	if velocity == Vector2.ZERO:
		return
	movement_submission_count += 1
	var motion_delta := delta if delta >= 0.0 else FIXED_PHYSICS_DELTA
	global_position += velocity * motion_delta


func _broadcast_enemy_target_action(
	action_name: StringName,
	target: Node2D
) -> void:
	super._broadcast_enemy_target_action(action_name, target)
	var target_id := (
		int(target.get_meta(&"net_id", 0))
		if target != null and is_instance_valid(target)
		else 0
	)
	action_log.append(
		"%d:%s:%d"
		% [action_sequence, String(action_name), target_id]
	)


func _broadcast_lock_presentation_state(
	phase: int,
	target: Node2D,
	duration_seconds: float
) -> void:
	super._broadcast_lock_presentation_state(phase, target, duration_seconds)
	var target_id := (
		int(target.get_meta(&"net_id", 0))
		if target != null and is_instance_valid(target)
		else 0
	)
	presentation_log.append(
		"%d:%d:%d:%d"
		% [
			action_sequence,
			phase,
			target_id,
			_quantize(duration_seconds),
		]
	)


func _make_lock_damage_request(
	outgoing_damage: int,
	direction: Vector2
) -> DamageRequest:
	var request := super._make_lock_damage_request(outgoing_damage, direction)
	var snapshot := request.source_snapshot
	damage_records.append({
		"damage": request.amount,
		"damage_type": request.damage_type,
		"direction_x": _quantize(direction.x),
		"direction_y": _quantize(direction.y),
		"target_id": (
			int(locked_target.get_meta(&"net_id", 0))
			if locked_target != null and is_instance_valid(locked_target)
			else 0
		),
		"source_faction": (
			snapshot.source_faction_id if snapshot != null else -1
		),
		"instigator_id": (
			snapshot.instigator_entity_id if snapshot != null else 0
		),
		"event_source_id": (
			snapshot.event_source_id if snapshot != null else 0
		),
		"source_type": (
			String(snapshot.source_type) if snapshot != null else ""
		),
	})
	return request


func _update_lock_warning(
	target_world_position: Vector2,
	progress: float
) -> void:
	warning_update_count += 1
	last_warning_position = target_world_position
	last_warning_progress = clampf(progress, 0.0, 1.0)
	super._update_lock_warning(target_world_position, progress)


func _clear_lock_warning() -> void:
	warning_clear_count += 1
	super._clear_lock_warning()


func _quantize(value: float) -> int:
	return roundi(value * 1_000_000.0)
