extends LightningSorcerer
class_name LightningSorcererLayeredSemanticHarness

## Keeps the authored Lightning scene, shared warning service and real chain
## damage intact. Only world-dependent target/LOS/navigation answers are
## scripted so every simulation policy replays one deterministic transcript.

const FIXED_PHYSICS_DELTA := 1.0 / 60.0

var forced_target: Node2D = null
var forced_los_clear := true
var forced_move_direction := Vector2.RIGHT

var phase_context: StringName = &""
var cooldown_update_deltas: Array[float] = []
var windup_start_phases: Array[StringName] = []
var strike_resolve_phases: Array[StringName] = []
var cancel_phases: Array[StringName] = []
var warning_update_phases: Array[StringName] = []
var warning_clear_phases: Array[StringName] = []
var warning_progress_log := PackedInt32Array()
var warning_position_log := PackedStringArray()
var warning_retry_deadline_log := PackedStringArray()
var action_log := PackedStringArray()
var presentation_log := PackedStringArray()
var damage_log := PackedStringArray()
var chain_path_log := PackedStringArray()
var movement_submission_count := 0
var los_query_count := 0


func reset_semantic_trace() -> void:
	phase_context = &""
	cooldown_update_deltas.clear()
	windup_start_phases.clear()
	strike_resolve_phases.clear()
	cancel_phases.clear()
	warning_update_phases.clear()
	warning_clear_phases.clear()
	warning_progress_log.clear()
	warning_position_log.clear()
	warning_retry_deadline_log.clear()
	action_log.clear()
	presentation_log.clear()
	damage_log.clear()
	chain_path_log.clear()
	movement_submission_count = 0
	los_query_count = 0
	action_sequence = 0


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
	cooldown_update_deltas.append(delta)
	super._update_attack_cooldown(delta)


func _try_start_windup(
	attack_target: Node2D,
	lightning_config: LightningSorcererConfig
) -> bool:
	var started := super._try_start_windup(attack_target, lightning_config)
	if started:
		windup_start_phases.append(phase_context)
	return started


func _finish_windup_and_strike(
	lightning_config: LightningSorcererConfig
) -> void:
	strike_resolve_phases.append(phase_context)
	super._finish_windup_and_strike(lightning_config)


func _cancel_windup(restore_move_animation := true) -> void:
	if combat_state == CombatState.WINDUP:
		cancel_phases.append(phase_context)
	super._cancel_windup(restore_move_animation)


func _select_nearest_attack_target(
	fallback_target: Node2D,
	_lightning_config: LightningSorcererConfig,
	allow_runtime_refresh: bool
) -> Node2D:
	if not _is_ranged_combat_target_valid(cached_runtime_attack_target):
		cached_runtime_attack_target = null
		attack_target_refresh_left = 0.0
	if allow_runtime_refresh and attack_target_refresh_left <= 0.0:
		attack_target_refresh_left = ATTACK_TARGET_REFRESH_INTERVAL
		cached_runtime_attack_target = _query_runtime_attack_target(
			global_position,
			INF
		)
	if cached_runtime_attack_target != null:
		return cached_runtime_attack_target
	return (
		fallback_target
		if _is_ranged_combat_target_valid(fallback_target)
		else null
	)


func _query_runtime_attack_target(
	from_position: Vector2,
	max_distance: float,
	excluded_instance_ids: Dictionary = {}
) -> Node2D:
	if (
		forced_target == null
		or not is_instance_valid(forced_target)
		or excluded_instance_ids.has(forced_target.get_instance_id())
		or from_position.distance_squared_to(forced_target.global_position)
			> max_distance * max_distance
		or not _is_frozen_source_hostile_target_valid(forced_target)
	):
		return null
	return forced_target


func _has_ranged_combat_line(
	target: Node2D,
	_collision_mask_value: int = 1,
	_force_refresh: bool = false
) -> bool:
	los_query_count += 1
	return (
		forced_los_clear
		and _is_frozen_source_hostile_target_valid(target)
	)


func refresh_dynamic_combat_target_decision(_simulation_tick: int) -> void:
	# The golden authors every target/faction edge. Production Lightning keeps
	# Enemy's dynamic-target refresh unchanged.
	pass


func _get_navigation_move_direction(_delta: float) -> Vector2:
	return forced_move_direction.normalized()


func _move_after_confirmed_no_contact(delta: float = -1.0) -> void:
	if velocity == Vector2.ZERO:
		return
	movement_submission_count += 1
	var motion_delta := delta if delta >= 0.0 else FIXED_PHYSICS_DELTA
	global_position += velocity * motion_delta


func _write_target_warning(world_position: Vector2, progress: float) -> bool:
	var written := super._write_target_warning(world_position, progress)
	warning_update_phases.append(phase_context)
	warning_progress_log.append(roundi(clampf(progress, 0.0, 1.0) * 1_000.0))
	warning_position_log.append(
		"%d,%d" % [_quantize(world_position.x), _quantize(world_position.y)]
	)
	return written


func _clear_target_warning() -> void:
	if target_warning_handle > 0:
		warning_clear_phases.append(phase_context)
	super._clear_target_warning()


func _update_windup_warning_retry(delta: float) -> void:
	var retry_was_pending := not warning_retry_sent
	var retry_time_before := warning_retry_time_left
	var frozen_relation_eligible := _is_frozen_source_hostile_target_valid(
		cast_target
	)
	var action_log_size_before := action_log.size()
	super._update_windup_warning_retry(delta)
	if (
		retry_was_pending
		and retry_time_before > 0.0
		and warning_retry_sent
	):
		warning_retry_deadline_log.append(
			"%d:%d:%d"
			% [
				action_sequence,
				1 if frozen_relation_eligible else 0,
				1 if action_log.size() > action_log_size_before else 0,
			]
		)


func _broadcast_enemy_target_action(
	action_name: StringName,
	target: Node2D
) -> void:
	super._broadcast_enemy_target_action(action_name, target)
	action_log.append(
		"%d:target:%s:%d"
		% [action_sequence, String(action_name), _target_net_id(target)]
	)


func _broadcast_enemy_action(
	action_name: StringName,
	direction: Vector2
) -> void:
	super._broadcast_enemy_action(action_name, direction)
	action_log.append(
		"%d:action:%s:%d,%d"
		% [
			action_sequence,
			String(action_name),
			_quantize(direction.x),
			_quantize(direction.y),
		]
	)


func _broadcast_windup_start(target: Node2D, is_retry: bool) -> void:
	super._broadcast_windup_start(target, is_retry)
	if is_retry:
		action_log.append(
			"%d:retry:%d" % [action_sequence, _target_net_id(target)]
		)


func _broadcast_windup_presentation_state(
	phase: int,
	target: Node2D,
	duration_seconds: float
) -> void:
	super._broadcast_windup_presentation_state(
		phase,
		target,
		duration_seconds
	)
	presentation_log.append(
		"%d:%d:%d:%d"
		% [
			action_sequence,
			phase,
			_target_net_id(target),
			_quantize(duration_seconds),
		]
	)


func _resolve_chain_hits(
	first_target: Node2D,
	lightning_config: LightningSorcererConfig,
	damage_source_id: int
) -> PackedVector2Array:
	var world_path := super._resolve_chain_hits(
		first_target,
		lightning_config,
		damage_source_id
	)
	var points := PackedStringArray()
	for point in world_path:
		points.append("%d,%d" % [_quantize(point.x), _quantize(point.y)])
	chain_path_log.append(";".join(points))
	return world_path


func _apply_chain_damage(
	target: Node2D,
	damage: int,
	damage_source_id: int,
	source_position: Vector2
) -> bool:
	var snapshot := cast_damage_source_snapshot
	var accepted := super._apply_chain_damage(
		target,
		damage,
		damage_source_id,
		source_position
	)
	damage_log.append(
		"%d:%d:%d:%d:%d:%d:%s:%d"
		% [
			_target_net_id(target),
			damage,
			snapshot.source_faction_id if snapshot != null else -1,
			snapshot.credit_peer_id if snapshot != null else 0,
			snapshot.instigator_entity_id if snapshot != null else 0,
			snapshot.event_source_id if snapshot != null else 0,
			String(snapshot.source_type) if snapshot != null else "",
			1 if accepted else 0,
		]
	)
	return accepted


func _target_net_id(target: Node2D) -> int:
	return (
		int(target.get_meta(&"net_id", 0))
		if target != null and is_instance_valid(target)
		else 0
	)


func _quantize(value: float) -> int:
	return roundi(value * 1_000_000.0)
