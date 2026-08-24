extends CombatRobotNinja
class_name CombatRobotNinjaTimerOrderHarness

## Real-SceneTree ordering probe. Unlike the semantic replay harness, this node
## never invokes an authoritative parent step itself: Godot dispatches either the
## enemy callback, the coordinator, or the native physics Timer children.

const FIXED_PHYSICS_DELTA := 1.0 / 60.0

var forced_move_direction := Vector2.RIGHT
var forced_existing_contact := false
var suppress_dynamic_target_refresh := false
var timer_trace_enabled := false
var timer_trace_sequence := 0
var timer_trace_phase: StringName = &""
var timer_order_trace: Array[Dictionary] = []


func _is_exact_layered_ninja_family() -> bool:
	return true


func get_layered_area_decision_interval_frames() -> int:
	return 1


func _get_navigation_move_direction(_delta: float) -> Vector2:
	return forced_move_direction.normalized()


func _get_safe_navigation_move_direction(
	_target_node: Node2D,
	_shared_pathfinder: Node,
	_waypoint_arrival_distance: float
) -> Vector2:
	return forced_move_direction.normalized()


func refresh_dynamic_combat_target_decision(simulation_tick: int) -> void:
	if suppress_dynamic_target_refresh:
		return
	super.refresh_dynamic_combat_target_decision(simulation_tick)


func set_objective_target(target: Node2D) -> void:
	if suppress_dynamic_target_refresh and target != null:
		return
	super.set_objective_target(target)


func _has_player_contact() -> bool:
	return forced_existing_contact or super._has_player_contact()


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
	_record_timer_order(&"decision_begin")
	var previous_phase := timer_trace_phase
	timer_trace_phase = &"decision"
	var completed := super._simulate_layered_area_decision_body(delta)
	timer_trace_phase = previous_phase
	_record_timer_order(&"decision_end")
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
	_record_timer_order(&"motion_boost" if boost_active else &"motion_base")
	var motion_delta := delta if delta >= 0.0 else FIXED_PHYSICS_DELTA
	global_position += velocity * motion_delta


func _on_boost_timer_timeout() -> void:
	_record_timer_order(&"boost_timeout")
	super._on_boost_timer_timeout()
	_record_timer_order(&"boost_commit")


func _on_cooldown_timer_timeout() -> void:
	_record_timer_order(&"cooldown_timeout")
	super._on_cooldown_timer_timeout()
	_record_timer_order(&"cooldown_commit")


func _play_boost_audio(_start_offset: float = 0.0) -> void:
	pass


func _record_timer_order(tag: StringName) -> void:
	if not timer_trace_enabled:
		return
	timer_trace_sequence += 1
	timer_order_trace.append({
		"sequence": timer_trace_sequence,
		"frame": Engine.get_physics_frames(),
		"tag": String(tag),
		"phase": String(timer_trace_phase),
		"boost": boost_active,
		"cooldown": boost_cooldown_active,
		"layered_clock": layered_ninja_timer_authority_active,
	})
