extends CapooSwordsman

## Swordsman uses Knight's production state machine. Only nondeterministic world
## queries and motion submission are replaced so all timers, transitions, RNG,
## action IDs and DamageSourceSnapshot construction stay in production code.

const PROBE_DELTA := 1.0 / 60.0

var forced_preferred_target: Node2D = null
var forced_combat_sense_due := true
var use_forced_combat_sense_due := true
var forced_start_range := true
var forced_world_line_clear := true
var forced_move_direction := Vector2.RIGHT
var forced_decision_interval_frames := 1
var use_forced_decision_interval := true
var contract_tick := 0
var phase_context: StringName = &""

var attack_start_ticks: Array[int] = []
var attack_start_phases: Array[StringName] = []
var attack_target_ids: Array[int] = []
var slash_start_ticks: Array[int] = []
var slash_start_phases: Array[StringName] = []
var slash_damage_ticks: Array[int] = []
var slash_damage_phases: Array[StringName] = []
var slash_damage_snapshots: Array[Dictionary] = []
var action_names: Array[StringName] = []
var action_ticks: Array[int] = []
var action_phases: Array[StringName] = []
var action_directions: Array[Vector2] = []
var cooldown_update_deltas: Array[float] = []
var movement_submission_count := 0
var navigation_clear_count := 0
var slash_effect_count := 0
var touch_update_count := 0
var family_decision_ticks: Array[int] = []
var family_decision_physics_frames: Array[int] = []


func _run_authoritative_physics_step(delta: float) -> void:
	phase_context = &"whole"
	super._run_authoritative_physics_step(delta)
	phase_context = &""


func _advance_layered_area_family_event_phase(delta: float) -> void:
	phase_context = &"event"
	super._advance_layered_area_family_event_phase(delta)
	phase_context = &""


func _try_consume_layered_area_family_decision_phase(delta: float) -> bool:
	phase_context = &"decision"
	family_decision_ticks.append(contract_tick)
	family_decision_physics_frames.append(Engine.get_physics_frames())
	var consumed := super._try_consume_layered_area_family_decision_phase(delta)
	phase_context = &""
	return consumed


func _try_start_windup(candidate_target: Node2D = null) -> bool:
	var started := super._try_start_windup(candidate_target)
	if started:
		attack_start_ticks.append(contract_tick)
		attack_start_phases.append(phase_context)
		attack_target_ids.append(
			committed_attack_target.get_instance_id()
			if committed_attack_target != null
			else 0
		)
	return started


func _start_slash(direction: Vector2) -> void:
	super._start_slash(direction)
	if combat_state == CombatState.SLASH:
		slash_start_ticks.append(contract_tick)
		slash_start_phases.append(phase_context)


func _apply_slash_damage() -> void:
	slash_damage_ticks.append(contract_tick)
	slash_damage_phases.append(phase_context)
	var snapshot := slash_damage_source_snapshot
	slash_damage_snapshots.append({
		"source_faction_id": (
			snapshot.source_faction_id if snapshot != null else -1
		),
		"instigator_entity_id": (
			snapshot.instigator_entity_id if snapshot != null else -1
		),
		"event_source_id": (
			snapshot.event_source_id if snapshot != null else -1
		),
		"source_type": String(snapshot.source_type) if snapshot != null else "",
	})


func _broadcast_enemy_action(action_name: StringName, direction: Vector2) -> void:
	action_names.append(action_name)
	action_ticks.append(contract_tick)
	action_phases.append(phase_context)
	action_directions.append(direction)
	super._broadcast_enemy_action(action_name, direction)


func _update_attack_cooldown(delta: float) -> void:
	cooldown_update_deltas.append(delta)
	super._update_attack_cooldown(delta)


func _get_preferred_ranged_combat_target() -> Node2D:
	return forced_preferred_target


func get_layered_area_decision_interval_frames() -> int:
	if use_forced_decision_interval:
		return maxi(forced_decision_interval_frames, 1)
	return super.get_layered_area_decision_interval_frames()


func _is_combat_sense_refresh_due() -> bool:
	if use_forced_combat_sense_due:
		return forced_combat_sense_due
	return super._is_combat_sense_refresh_due()


func _is_slash_target_in_start_range(
	target: Node2D,
	attack_range: float
) -> bool:
	return (
		forced_start_range
		and super._is_slash_target_in_start_range(target, attack_range)
	)


func _has_clear_world_line_to_target(attack_target: Node2D) -> bool:
	return (
		forced_world_line_clear
		and _is_ranged_combat_target_valid(attack_target)
	)


func _get_navigation_move_direction(_delta: float) -> Vector2:
	return forced_move_direction.normalized()


func _has_player_contact() -> bool:
	return false


func _update_touch_damage(delta: float) -> void:
	touch_update_count += 1
	super._update_touch_damage(delta)


func _clear_navigation_path() -> void:
	navigation_clear_count += 1
	super._clear_navigation_path()


func _move_until_player_contact(delta: float = -1.0) -> void:
	_submit_probe_motion(delta)


func _move_after_confirmed_no_contact(delta: float = -1.0) -> void:
	_submit_probe_motion(delta)


func _submit_probe_motion(delta: float) -> void:
	if velocity.is_zero_approx():
		return
	movement_submission_count += 1
	var motion_delta := delta if delta >= 0.0 else PROBE_DELTA
	global_position += velocity * motion_delta


func _play_slash_effect(_direction: Vector2) -> void:
	slash_effect_count += 1
