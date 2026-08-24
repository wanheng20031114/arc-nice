extends CombatRobotMainBattleElite
class_name CombatRobotMainBattleLayeredSemanticHarness

## Keep the production main-battle state machine intact while replacing only
## world-dependent perception, navigation and hit enumeration with a fixed
## replay surface. This lets all four simulation policies consume the same
## authored state transitions without depending on PhysicsServer query order.

const FIXED_PHYSICS_DELTA := 1.0 / 60.0

var forced_target: Node2D = null
var forced_target_valid := true
var forced_target_in_range := true
var forced_move_direction := Vector2.RIGHT
var forced_contact := false
var force_every_tick_combat_sense := true
var semantic_tick := 0
var phase_context: StringName = &""
var compat_runner_active := false

var touch_update_count := 0
var contact_query_count := 0
var chase_motion_count := 0
var skill1_motion_count := 0
var skill2_motion_count := 0
var shape_damage_count := 0
var dynamic_refresh_count := 0
var decision_phase_count := 0
var dynamic_refresh_ticks: Array[int] = []
var decision_phase_ticks: Array[int] = []
var action_log: Array[String] = []
var action_phase_log: Array[String] = []


func _is_exact_layered_main_battle_family() -> bool:
	# Production intentionally rejects unknown derived scripts. This authored
	# deterministic harness is the sole test double allowed to exercise phases.
	return true


func get_layered_area_decision_interval_frames() -> int:
	if force_every_tick_combat_sense:
		return 1
	return super.get_layered_area_decision_interval_frames()


func get_layered_area_decision_phase_offset() -> int:
	if force_every_tick_combat_sense:
		return 0
	return super.get_layered_area_decision_phase_offset()


func reset_semantic_trace() -> void:
	phase_context = &""
	touch_update_count = 0
	contact_query_count = 0
	chase_motion_count = 0
	skill1_motion_count = 0
	skill2_motion_count = 0
	shape_damage_count = 0
	dynamic_refresh_count = 0
	decision_phase_count = 0
	dynamic_refresh_ticks.clear()
	decision_phase_ticks.clear()
	action_log.clear()
	action_phase_log.clear()
	action_sequence = 0


func _run_authoritative_physics_step(delta: float) -> void:
	var previous_phase := phase_context
	compat_runner_active = true
	phase_context = &"compat"
	super._run_authoritative_physics_step(delta)
	phase_context = previous_phase
	compat_runner_active = false


func simulate_pre_refactor_authoritative_step(delta: float) -> void:
	# Frozen copy of the pre-migration `_physics_process` runner. It deliberately
	# does not call the new event/decision/motion helpers, so a shared regression
	# in those helpers cannot make every policy agree on the same wrong behavior.
	var previous_phase := phase_context
	phase_context = &"oracle"
	if is_dead:
		velocity = Vector2.ZERO
		phase_context = previous_phase
		return
	var safe_delta := maxf(delta, 0.0)
	_update_cooldowns(safe_delta)
	match combat_state:
		CombatState.ATTACK_WINDUP:
			_update_attack_windup(safe_delta)
			phase_context = previous_phase
			return
		CombatState.ATTACK_SLASH:
			_update_attack_slash(safe_delta)
			phase_context = previous_phase
			return
		CombatState.SKILL1_WINDUP:
			_update_skill1_windup(safe_delta)
			phase_context = previous_phase
			return
		CombatState.SKILL1_DASH:
			_update_skill1_dash(safe_delta)
			phase_context = previous_phase
			return
		CombatState.SKILL1_CIRCLE:
			_update_recovery(safe_delta, true)
			phase_context = previous_phase
			return
		CombatState.SKILL2_TAKEOFF:
			_update_skill2_takeoff(safe_delta)
			phase_context = previous_phase
			return
		CombatState.SKILL2_TRACK:
			_update_skill2_tracking(safe_delta)
			phase_context = previous_phase
			return
		CombatState.SKILL2_DROP:
			_update_skill2_drop(safe_delta)
			phase_context = previous_phase
			return
		CombatState.SKILL2_RECOVERY:
			_update_recovery(safe_delta, false)
			phase_context = previous_phase
			return

	_update_touch_damage(safe_delta)
	if _is_combat_sense_refresh_due() and _try_start_ready_action():
		phase_context = previous_phase
		return
	if _has_player_contact():
		velocity = Vector2.ZERO
		actual_motion_since_last_stomp = false
		phase_context = previous_phase
		return
	if not is_instance_valid(objective_target):
		velocity = Vector2.ZERO
		actual_motion_since_last_stomp = false
		_move_until_player_contact_with_audio_tracking()
		phase_context = previous_phase
		return
	var move_direction := _get_safe_navigation_move_direction(
		objective_target,
		pathfinder,
		waypoint_arrival_distance
	)
	_update_facing(move_direction)
	velocity = move_direction * get_effective_move_speed()
	_move_until_player_contact_with_audio_tracking()
	phase_context = previous_phase


func _advance_layered_event_body(delta: float) -> void:
	if compat_runner_active:
		super._advance_layered_event_body(delta)
		return
	var previous_phase := phase_context
	phase_context = &"event"
	super._advance_layered_event_body(delta)
	phase_context = previous_phase


func _advance_layered_decision_body(
	delta: float,
	refresh_dynamic_target: bool
) -> void:
	if compat_runner_active:
		super._advance_layered_decision_body(delta, refresh_dynamic_target)
		return
	decision_phase_count += 1
	decision_phase_ticks.append(semantic_tick)
	var previous_phase := phase_context
	phase_context = &"decision"
	super._advance_layered_decision_body(delta, refresh_dynamic_target)
	phase_context = previous_phase


func _advance_layered_motion_body(delta: float) -> void:
	if compat_runner_active:
		super._advance_layered_motion_body(delta)
		return
	var previous_phase := phase_context
	phase_context = &"motion"
	super._advance_layered_motion_body(delta)
	phase_context = previous_phase


func refresh_dynamic_combat_target_decision(_simulation_tick: int) -> void:
	# The fixed replay authors target and faction revisions explicitly.
	dynamic_refresh_count += 1
	dynamic_refresh_ticks.append(semantic_tick)


func _is_combat_sense_refresh_due() -> bool:
	if force_every_tick_combat_sense:
		return true
	return super._is_combat_sense_refresh_due()


func _get_preferred_ranged_combat_target() -> Node2D:
	return forced_target if forced_target_valid else null


func _get_skill2_priority_target() -> Node2D:
	return forced_target if _is_ranged_combat_target_valid(forced_target) else null


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


func _has_player_contact() -> bool:
	contact_query_count += 1
	return forced_contact


func _update_touch_damage(_delta: float) -> void:
	touch_update_count += 1


func _move_until_player_contact_with_audio_tracking() -> void:
	if velocity == Vector2.ZERO:
		return
	chase_motion_count += 1
	global_position += velocity * FIXED_PHYSICS_DELTA
	actual_motion_since_last_stomp = true


func _update_skill1_dash(delta: float) -> void:
	skill1_motion_count += 1
	super._update_skill1_dash(delta)


func _update_skill2_tracking(delta: float) -> void:
	skill2_motion_count += 1
	super._update_skill2_tracking(delta)


func _apply_shape_damage(
	_radius: float,
	_angle_degrees: float,
	_damage: int,
	_source_type: StringName,
	_apply_burn: bool,
	_apply_slow: bool
) -> void:
	shape_damage_count += 1


func _broadcast_action(action_name: StringName, direction: Vector2) -> void:
	super._broadcast_action(action_name, direction)
	action_log.append(
		"%d:%s:%d:%d" % [
			action_sequence,
			String(action_name),
			roundi(direction.x * 1_000_000.0),
			roundi(direction.y * 1_000_000.0),
		]
	)
	_record_action_phase(action_name)


func _broadcast_target_action(action_name: StringName, target: Node2D) -> void:
	super._broadcast_target_action(action_name, target)
	action_log.append(
		"%d:%s:target:%d" % [
			action_sequence,
			String(action_name),
			int(target.get_meta(&"net_id", 0)) if target != null else 0,
		]
	)
	_record_action_phase(action_name)


func _record_action_phase(action_name: StringName) -> void:
	action_phase_log.append(
		"%d:%s:%s" % [
			semantic_tick,
			String(action_name),
			String(phase_context),
		]
	)
