extends CombatRobotGunner
class_name CombatRobotGunnerLayeredSemanticHarness

## Preserve Gunner's real burst scheduler, spread/pitch RNG, action sequence,
## faction snapshot and composite animation. World navigation/motion and the
## DATA backend registration are deterministic records for four-policy replay.

const FIXED_PHYSICS_DELTA := 1.0 / 60.0

var forced_target: Node2D = null
var forced_target_valid := true
var forced_target_in_range := true
var forced_move_direction := Vector2.RIGHT
var force_straight_contact_plan_certified := true
var semantic_tick := 0
var phase_context: StringName = &""

var movement_submission_count := 0
var touch_update_count := 0
var shot_attempt_count := 0
var failed_attempts: Dictionary[int, bool] = {}
var shot_records: Array[Dictionary] = []
var shot_phases: Array[String] = []
var burst_start_ticks: Array[int] = []
var burst_start_phases: Array[String] = []
var burst_finish_ticks: Array[int] = []
var action_log: Array[String] = []


func _supports_layered_ranged_authoritative_simulation() -> bool:
	# Production rejects inherited scripts. This authored test double opts in to
	# exercise the exact production event/decision/motion implementation.
	return true


func _supports_layered_ranged_contact_authority() -> bool:
	# Production admits only its exact script path. This test double independently
	# opts into the same shared-contact motion path; indexed Player/Plant authority
	# deliberately remains inherited false.
	return true


func is_layered_area_contact_plan_certified(
	_delta: float,
	_counterpart: Node2D
) -> bool:
	return force_straight_contact_plan_certified


func reset_semantic_trace() -> void:
	phase_context = &""
	movement_submission_count = 0
	touch_update_count = 0
	shot_attempt_count = 0
	failed_attempts = {3: true}
	shot_records.clear()
	shot_phases.clear()
	burst_start_ticks.clear()
	burst_start_phases.clear()
	burst_finish_ticks.clear()
	action_log.clear()
	action_sequence = 0


func _run_authoritative_physics_step(delta: float) -> void:
	phase_context = &"compat"
	super._run_authoritative_physics_step(delta)
	phase_context = &""


func _advance_layered_ranged_event_phase(delta: float) -> void:
	phase_context = &"event"
	super._advance_layered_ranged_event_phase(delta)
	phase_context = &""


func _simulate_layered_area_decision_body(delta: float) -> bool:
	phase_context = &"decision"
	var completed := super._simulate_layered_area_decision_body(delta)
	phase_context = &""
	return completed


func _simulate_layered_area_motion_body(delta: float) -> bool:
	phase_context = &"motion"
	var completed := super._simulate_layered_area_motion_body(delta)
	phase_context = &""
	return completed


func refresh_dynamic_combat_target_decision(_simulation_tick: int) -> void:
	pass


func _is_combat_sense_refresh_due() -> bool:
	return true


func _get_preferred_ranged_combat_target() -> Node2D:
	return forced_target if forced_target_valid else null


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
	_attack_range: float
) -> bool:
	return forced_target_in_range and _is_ranged_combat_target_valid(target)


func _get_gunner_navigation_move_direction(_target: Node2D) -> Vector2:
	return forced_move_direction.normalized()


func _move_after_confirmed_no_contact(delta: float = -1.0) -> void:
	if velocity == Vector2.ZERO:
		return
	movement_submission_count += 1
	var motion_delta := delta if delta >= 0.0 else FIXED_PHYSICS_DELTA
	global_position += velocity * motion_delta


func _get_safe_muzzle_spawn_position() -> Vector2:
	return global_position + Vector2(
		-MUZZLE_RIGHT_POSITION.x if facing_left else MUZZLE_RIGHT_POSITION.x,
		MUZZLE_RIGHT_POSITION.y
	)


func _fire_data_projectile(shot_direction: Vector2) -> bool:
	shot_attempt_count += 1
	if failed_attempts.has(shot_attempt_count):
		failed_attempts.erase(shot_attempt_count)
		return false
	var source_type := gunner_config_cache.projectile_type
	var snapshot := create_damage_source_snapshot(0, source_type)
	shot_records.append({
		"tick": semantic_tick,
		"position_x": _quantize(_get_safe_muzzle_spawn_position().x),
		"position_y": _quantize(_get_safe_muzzle_spawn_position().y),
		"direction_x": _quantize(shot_direction.x),
		"direction_y": _quantize(shot_direction.y),
		"damage": get_effective_attack_damage(gunner_config_cache.attack_damage),
		"source_faction": snapshot.source_faction_id,
		"credit_peer": snapshot.credit_peer_id,
		"instigator": snapshot.instigator_entity_id,
		"source_type": String(snapshot.source_type),
	})
	shot_phases.append(String(phase_context))
	return true


func _update_touch_damage(delta: float) -> void:
	touch_update_count += 1
	super._update_touch_damage(delta)


func _try_start_burst(candidate_target: Node2D = null) -> bool:
	var started := super._try_start_burst(candidate_target)
	if started:
		burst_start_ticks.append(semantic_tick)
		burst_start_phases.append(String(phase_context))
	return started


func _finish_burst() -> void:
	var was_burst := combat_state == CombatState.BURST
	super._finish_burst()
	if was_burst and combat_state == CombatState.TRACKING_COOLDOWN:
		burst_finish_ticks.append(semantic_tick)


func _broadcast_enemy_action(
	action_name: StringName,
	direction: Vector2
) -> void:
	super._broadcast_enemy_action(action_name, direction)
	action_log.append(
		"%d:%s:%d:%d:%d:%d" % [
			action_sequence,
			String(action_name),
			_quantize(direction.x),
			_quantize(direction.y),
			_quantize(global_position.x),
			_quantize(global_position.y),
		]
	)


func _quantize(value: float) -> int:
	return roundi(value * 1_000_000.0)
