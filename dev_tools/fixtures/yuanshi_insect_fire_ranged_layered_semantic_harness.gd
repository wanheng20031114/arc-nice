extends YuanshiInsectFireRanged
class_name YuanshiInsectFireRangedLayeredSemanticHarness

## The authored scene, animation resource, collision shapes and family state
## machine stay intact. Only nondeterministic world inputs and projectile side
## effects are replaced so the test can drive exact physics ticks.

var forced_target: Node2D = null
var forced_target_valid := true
var forced_target_in_range := true
var forced_world_line_clear := true
var forced_combat_sense_due := false
var forced_move_direction := Vector2.RIGHT

var phase_context: StringName = &""
var attack_start_phases: Array[StringName] = []
var touch_update_deltas: Array[float] = []
var movement_submission_count := 0
var projectile_fire_attempt_count := 0
var action_broadcast_count := 0
var navigation_clear_count := 0


func _run_authoritative_physics_step(delta: float) -> void:
	phase_context = &"legacy"
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


func _try_start_ranged_attack(candidate_target: Node2D = null) -> bool:
	var started := super._try_start_ranged_attack(candidate_target)
	if started:
		attack_start_phases.append(phase_context)
	return started


func _get_preferred_ranged_combat_target() -> Node2D:
	return forced_target


func _is_ranged_combat_target_valid(target: Node2D) -> bool:
	return (
		forced_target_valid
		and target != null
		and target == forced_target
		and is_instance_valid(target)
	)


func _is_ranged_combat_target_in_range(
	target: Node2D,
	_attack_range: float
) -> bool:
	return forced_target_in_range and _is_ranged_combat_target_valid(target)


func _has_clear_world_line_to_target(attack_target: Node2D) -> bool:
	return (
		forced_world_line_clear
		and _is_ranged_combat_target_valid(attack_target)
	)


func _is_combat_sense_refresh_due() -> bool:
	return forced_combat_sense_due


func _has_player_contact() -> bool:
	return false


func _update_touch_damage(delta: float) -> void:
	touch_update_deltas.append(delta)


func _can_sleep_layered_area_family_event_phase() -> bool:
	# This fixture deliberately observes every synthetic tick while overriding the
	# real combat-sense clock. Production fire-ranged enemies retain deadline sleep.
	return false


func _get_navigation_move_direction(_delta: float) -> Vector2:
	return forced_move_direction.normalized()


func _move_after_confirmed_no_contact(delta: float = -1.0) -> void:
	if velocity == Vector2.ZERO:
		return
	movement_submission_count += 1
	var motion_delta := delta if delta >= 0.0 else get_physics_process_delta_time()
	global_position += velocity * motion_delta


func _clear_navigation_path() -> void:
	navigation_clear_count += 1


func _try_fire_ranged_projectile() -> bool:
	projectile_fire_attempt_count += 1
	return true


func _broadcast_enemy_action(
	_action_name: StringName,
	_direction: Vector2
) -> void:
	action_broadcast_count += 1
