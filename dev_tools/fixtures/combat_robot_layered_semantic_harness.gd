extends CombatRobot
class_name CombatRobotLayeredSemanticHarness

## Preserve the authored dash state machine, touch pipeline and presentation.
## Only world-dependent target/navigation/collision answers are deterministic so
## the same fixed script can be replayed under all four simulation policies.

const FIXED_PHYSICS_DELTA := 1.0 / 60.0

var forced_target: Node2D = null
var forced_target_valid := true
var forced_target_in_range := true
var forced_move_direction := Vector2.RIGHT
var forced_decision_interval_frames := 1
var semantic_tick := 0
var collision_on_dash_submission := -1

var phase_context: StringName = &""
var movement_submission_count := 0
var dash_submission_count := 0
var touch_update_count := 0
var cooldown_update_count := 0
var windup_start_ticks: Array[int] = []
var windup_start_phases: Array[String] = []
var dash_start_ticks: Array[int] = []
var dash_finish_ticks: Array[int] = []
var action_log: Array[String] = []


func _is_exact_layered_combat_robot_family() -> bool:
	# The production capability deliberately rejects derived scripts. This one
	# authored test double opts in explicitly to exercise the production phases.
	return true


func get_layered_area_decision_interval_frames() -> int:
	return maxi(forced_decision_interval_frames, 1)


func reset_semantic_trace() -> void:
	phase_context = &""
	movement_submission_count = 0
	dash_submission_count = 0
	touch_update_count = 0
	cooldown_update_count = 0
	windup_start_ticks.clear()
	windup_start_phases.clear()
	dash_start_ticks.clear()
	dash_finish_ticks.clear()
	action_log.clear()
	action_sequence = 0


func _run_authoritative_physics_step(delta: float) -> void:
	phase_context = &"compat"
	super._run_authoritative_physics_step(delta)
	phase_context = &""


func _advance_layered_area_family_event_phase(delta: float) -> void:
	phase_context = &"event"
	super._advance_layered_area_family_event_phase(delta)
	phase_context = &""


func _try_consume_layered_area_family_decision_phase(delta: float) -> bool:
	phase_context = &"decision"
	var consumed := super._try_consume_layered_area_family_decision_phase(delta)
	phase_context = &""
	return consumed


func _simulate_layered_area_motion_body(delta: float) -> bool:
	phase_context = &"motion"
	var completed := super._simulate_layered_area_motion_body(delta)
	phase_context = &""
	return completed


func refresh_dynamic_combat_target_decision(_simulation_tick: int) -> void:
	# The regression authors target and faction edges explicitly.
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


func _get_safe_navigation_move_direction(
	_target_node: Node2D,
	_shared_pathfinder: Node,
	_waypoint_arrival_distance: float
) -> Vector2:
	return forced_move_direction.normalized()


func _move_after_confirmed_no_contact(delta: float = -1.0) -> void:
	if velocity == Vector2.ZERO:
		return
	movement_submission_count += 1
	var motion_delta := delta if delta >= 0.0 else FIXED_PHYSICS_DELTA
	global_position += velocity * motion_delta


func _submit_dash_motion(motion: Vector2) -> bool:
	dash_submission_count += 1
	var collides := dash_submission_count == collision_on_dash_submission
	global_position += motion * (0.5 if collides else 1.0)
	return collides


func _update_touch_damage(delta: float) -> void:
	touch_update_count += 1
	super._update_touch_damage(delta)


func _update_dash_cooldown(delta: float) -> void:
	cooldown_update_count += 1
	super._update_dash_cooldown(delta)


func _try_start_windup(candidate_target: Node2D = null) -> bool:
	var started := super._try_start_windup(candidate_target)
	if started:
		windup_start_ticks.append(semantic_tick)
		windup_start_phases.append(String(phase_context))
	return started


func _start_dash() -> void:
	var previous_state := combat_state
	super._start_dash()
	if previous_state != CombatState.DASH and combat_state == CombatState.DASH:
		dash_start_ticks.append(semantic_tick)


func _finish_dash() -> void:
	var was_dashing := combat_state == CombatState.DASH
	super._finish_dash()
	if was_dashing and combat_state == CombatState.CHASE:
		dash_finish_ticks.append(semantic_tick)


func _broadcast_enemy_action(
	action_name: StringName,
	direction: Vector2
) -> void:
	super._broadcast_enemy_action(action_name, direction)
	action_log.append(
		"%d:%s:%d:%d" % [
			action_sequence,
			String(action_name),
			roundi(direction.x * 1_000_000.0),
			roundi(direction.y * 1_000_000.0),
		]
	)
