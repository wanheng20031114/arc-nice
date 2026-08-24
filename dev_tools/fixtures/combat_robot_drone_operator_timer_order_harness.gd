extends CombatRobotDroneOperator
class_name CombatRobotDroneOperatorTimerOrderHarness

## Real-SceneTree ordering probe for all three authored physics Timer nodes.
## Selection and movement endpoints are deterministic, but callback ownership,
## parent/coordinator dispatch and Timer timeout delivery remain production code.

const FIXED_PHYSICS_DELTA := 1.0 / 60.0

var forced_move_direction := Vector2.RIGHT
var force_infinite_event_sleep_certificate := false
var force_world_segment_blocked := false
var production_selection_attempts_remaining := 0
var timer_trace_enabled := false
var timer_trace_sequence := 0
var timer_trace_phase: StringName = &""
var timer_order_trace: Array[Dictionary] = []


func _is_exact_layered_drone_operator_family() -> bool:
	return true


func _get_navigation_move_direction(_delta: float) -> Vector2:
	return forced_move_direction.normalized()


func _get_operator_navigation_move_direction(_target: Node2D) -> Vector2:
	return forced_move_direction.normalized()


func refresh_dynamic_combat_target_decision(_simulation_tick: int) -> void:
	# This fixture observes Timer ownership only. Dynamic target refresh has its
	# own regressions and must not manufacture an unrelated selection transition.
	pass


func _can_enter_layered_area_event_sleep() -> bool:
	if force_infinite_event_sleep_certificate:
		return (
			layered_operator_clock_authority
			and combat_state == CombatState.TRACKING_READY
			and not layered_blocked_retry_armed
			and not is_dead
			and not is_multiplayer_proxy
		)
	return super._can_enter_layered_area_event_sleep()


func _is_world_segment_clear(
	target_position: Vector2,
	collision_mask_value: int = 1
) -> bool:
	if force_world_segment_blocked:
		return false
	return super._is_world_segment_clear(target_position, collision_mask_value)


func begin_timer_order_trace() -> void:
	timer_order_trace.clear()
	timer_trace_sequence = 0
	timer_trace_phase = &""
	timer_trace_enabled = true


func mark_timer_order_trace(tag: StringName) -> void:
	_record_timer_order(tag)


func _physics_process(delta: float) -> void:
	_record_timer_order(&"parent_begin")
	var previous_phase := timer_trace_phase
	timer_trace_phase = &"individual"
	super._physics_process(delta)
	timer_trace_phase = previous_phase
	_record_timer_order(&"parent_end")


func _run_authoritative_physics_step(delta: float) -> void:
	_record_timer_order(&"runner_begin")
	_record_timer_order(_behavior_tag())
	var previous_phase := timer_trace_phase
	timer_trace_phase = &"runner"
	super._run_authoritative_physics_step(delta)
	timer_trace_phase = previous_phase
	_record_timer_order(&"runner_end")


func _advance_layered_area_family_event_phase(delta: float) -> void:
	_record_timer_order(&"event_begin")
	var previous_phase := timer_trace_phase
	timer_trace_phase = &"event"
	super._advance_layered_area_family_event_phase(delta)
	timer_trace_phase = previous_phase
	_record_timer_order(&"event_end")


func _simulate_layered_area_decision_body(delta: float) -> bool:
	var previous_phase := timer_trace_phase
	timer_trace_phase = &"decision"
	var completed := super._simulate_layered_area_decision_body(delta)
	_record_timer_order(_behavior_tag())
	timer_trace_phase = previous_phase
	return completed


func _simulate_layered_area_motion_body(delta: float) -> bool:
	_record_timer_order(&"motion_lane_begin")
	var previous_phase := timer_trace_phase
	timer_trace_phase = &"motion"
	var completed := super._simulate_layered_area_motion_body(delta)
	timer_trace_phase = previous_phase
	_record_timer_order(&"motion_lane_end")
	return completed


func _move_until_player_contact(delta: float = -1.0) -> void:
	_submit_timer_probe_motion(delta)


func _move_after_confirmed_no_contact(delta: float = -1.0) -> void:
	_submit_timer_probe_motion(delta)


func _submit_timer_probe_motion(delta: float) -> void:
	if velocity == Vector2.ZERO:
		return
	_record_timer_order(&"motion")
	var motion_delta := delta if delta >= 0.0 else FIXED_PHYSICS_DELTA
	global_position += velocity * motion_delta


func _complete_deploy_phase() -> void:
	_record_timer_order(&"deploy_commit")
	super._complete_deploy_phase()


func _complete_cooldown_phase() -> void:
	_record_timer_order(&"cooldown_commit")
	super._complete_cooldown_phase()


func _on_blocked_retry_timer_timeout() -> void:
	_record_timer_order(&"retry_timeout")
	super._on_blocked_retry_timer_timeout()


func _complete_blocked_retry_phase() -> void:
	_record_timer_order(&"retry_commit")
	super._complete_blocked_retry_phase()


func _try_select_and_begin_deploy() -> bool:
	_record_timer_order(&"selection_attempt")
	if production_selection_attempts_remaining > 0:
		production_selection_attempts_remaining -= 1
		return super._try_select_and_begin_deploy()
	return false


func _behavior_tag() -> StringName:
	match combat_state:
		CombatState.DEPLOY:
			return &"behavior_deploy"
		CombatState.TRACKING_COOLDOWN:
			return &"behavior_cooldown"
		_:
			return &"behavior_ready"


func _record_timer_order(tag: StringName) -> void:
	if not timer_trace_enabled:
		return
	timer_trace_sequence += 1
	timer_order_trace.append({
		"sequence": timer_trace_sequence,
		"frame": Engine.get_physics_frames(),
		"tag": String(tag),
		"phase": String(timer_trace_phase),
		"state": int(combat_state),
		"layered_clock": layered_operator_clock_authority,
		"retry_armed": layered_blocked_retry_armed,
	})
