extends CapooAK47
class_name CapooAK47LayeredSemanticHarness

## Authored AK scene and production state machine with deterministic world
## answers. Only targeting, LOS, body submission and projectile registration are
## replaced; attack clocks, RNG draws, actions and DamageSourceSnapshot creation
## continue through the real family runner in all four policies.

const FIXED_PHYSICS_DELTA := 1.0 / 60.0

var forced_target: Node2D = null
var forced_target_valid := true
var forced_in_range := true
var forced_los_clear := true
var forced_player_contact := false
var forced_move_direction := Vector2.RIGHT
var forced_fire_success := true

var semantic_tick := 0
var phase_context: StringName = &""
var movement_submission_count := 0
var touch_update_deltas: Array[float] = []
var cooldown_update_deltas: Array[float] = []
var event_records: Array[Dictionary] = []
var windup_records: Array[Dictionary] = []
var shot_attempt_count := 0
var shot_records: Array[Dictionary] = []
var action_records: Array[Dictionary] = []
var los_query_count := 0


func _is_exact_layered_ak47_family() -> bool:
	# Production remains exact-script fail-closed. This authored fixture opts in
	# only so the production AK hooks can be replayed under every policy.
	return true


func reset_semantic_trace() -> void:
	semantic_tick = 0
	phase_context = &""
	movement_submission_count = 0
	touch_update_deltas.clear()
	cooldown_update_deltas.clear()
	event_records.clear()
	windup_records.clear()
	shot_attempt_count = 0
	shot_records.clear()
	action_records.clear()
	los_query_count = 0
	action_sequence = 0
	local_data_projectile_sequence = 0


func _run_authoritative_physics_step(delta: float) -> void:
	phase_context = &"compat"
	super._run_authoritative_physics_step(delta)
	phase_context = &""


func simulate_pre_refactor_authoritative_step(delta: float) -> void:
	# Frozen from HEAD `CapooAK47._physics_process`. Keep this independent from
	# the new event/decision/motion helpers so a shared split regression cannot
	# make every scheduler policy agree on the same incorrect burst trace.
	var previous_phase := phase_context
	phase_context = &"oracle"
	if is_dead:
		velocity = Vector2.ZERO
		phase_context = previous_phase
		return

	_update_touch_damage(delta)
	_update_attack_cooldown(delta)
	if (
		combat_state != CombatState.CHASE
		and not _is_ranged_combat_target_valid(attack_target)
	):
		_cancel_attack()

	match combat_state:
		CombatState.WINDUP:
			_update_windup(delta)
			phase_context = previous_phase
			return
		CombatState.BURST:
			_update_burst(delta)
			phase_context = previous_phase
			return

	var capoo_config := config as CapooConfig
	if _is_combat_sense_refresh_due():
		var preferred_target := _get_preferred_ranged_combat_target()
		if (
			capoo_config != null
			and _try_hold_ranged_attack_position(
				preferred_target,
				capoo_config.attack_range,
				WORLD_COLLISION_MASK
			)
		):
			if _try_start_windup(preferred_target):
				phase_context = previous_phase
				return
			if _try_hold_ranged_attack_position(
				preferred_target,
				capoo_config.attack_range,
				WORLD_COLLISION_MASK
			):
				_update_facing(
					global_position.direction_to(preferred_target.global_position)
				)
				phase_context = previous_phase
				return
		else:
			_reset_ranged_attack_position_state()
	elif _ranged_attack_position_held:
		velocity = Vector2.ZERO
		phase_context = previous_phase
		return

	if not is_instance_valid(objective_target):
		velocity = Vector2.ZERO
		_move_until_player_contact()
		phase_context = previous_phase
		return

	var move_direction := _get_navigation_move_direction(delta)
	_update_facing(move_direction)
	velocity = move_direction * _get_move_speed()
	_move_until_player_contact()
	phase_context = previous_phase


func _advance_layered_ranged_event_phase(delta: float) -> void:
	phase_context = &"event"
	super._advance_layered_ranged_event_phase(delta)
	phase_context = &""


func _try_consume_layered_ranged_decision_phase(delta: float) -> bool:
	phase_context = &"decision"
	var consumed := super._try_consume_layered_ranged_decision_phase(delta)
	phase_context = &""
	return consumed


func _simulate_layered_area_motion_body(delta: float) -> bool:
	phase_context = &"motion"
	var completed := super._simulate_layered_area_motion_body(delta)
	phase_context = &""
	return completed


func refresh_dynamic_combat_target_decision(_simulation_tick: int) -> void:
	# The regression explicitly authors target death and faction transitions.
	pass


func _get_preferred_ranged_combat_target() -> Node2D:
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
	attack_range: float
) -> bool:
	if not forced_in_range or not _is_ranged_combat_target_valid(target):
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
	return (
		forced_los_clear
		and target != null
		and is_instance_valid(target)
		and can_attack_combat_target(target)
	)


func _is_combat_sense_refresh_due() -> bool:
	return true


func _has_player_contact() -> bool:
	return forced_player_contact


func _get_navigation_move_direction(_delta: float) -> Vector2:
	return forced_move_direction.normalized()


func _move_until_player_contact(delta: float = -1.0) -> void:
	if forced_player_contact:
		velocity = Vector2.ZERO
		return
	_submit_probe_motion(delta)


func _move_after_confirmed_no_contact(delta: float = -1.0) -> void:
	_submit_probe_motion(delta)


func _submit_probe_motion(delta: float) -> void:
	if velocity.is_zero_approx():
		return
	movement_submission_count += 1
	var motion_delta := delta if delta >= 0.0 else FIXED_PHYSICS_DELTA
	global_position += velocity * motion_delta


func _update_touch_damage(delta: float) -> void:
	touch_update_deltas.append(delta)
	event_records.append(_event_record(&"touch"))
	super._update_touch_damage(delta)


func _update_attack_cooldown(delta: float) -> void:
	cooldown_update_deltas.append(delta)
	event_records.append(_event_record(&"cooldown"))
	super._update_attack_cooldown(delta)


func _update_windup(delta: float) -> void:
	event_records.append(_event_record(&"windup"))
	super._update_windup(delta)


func _update_burst(delta: float) -> void:
	event_records.append(_event_record(&"burst"))
	super._update_burst(delta)


func _try_start_windup(candidate_target: Node2D = null) -> bool:
	var started := super._try_start_windup(candidate_target)
	if started:
		windup_records.append({
			"tick": semantic_tick,
			"phase": String(phase_context),
			"target_id": int(attack_target.get_meta(&"net_id", 0)),
			"duration": _quantize(committed_windup_duration_seconds),
		})
	return started


func _cancel_attack() -> void:
	if combat_state != CombatState.CHASE:
		event_records.append(_event_record(&"cancel"))
	super._cancel_attack()


func _finish_burst() -> void:
	event_records.append(_event_record(&"finish"))
	super._finish_burst()


func _fire_data_projectile(capoo_config: CapooAK47Config) -> bool:
	shot_attempt_count += 1
	if not forced_fire_success:
		return false
	var snapshot := create_damage_source_snapshot(
		0,
		RapidFireSimulationService.AK_SOURCE_TYPE
	)
	var phase_identity := _next_local_data_phase_identity()
	shot_records.append({
		"tick": semantic_tick,
		"phase": String(phase_context),
		"shot_index": burst_shots_fired,
		"direction_x": _quantize(burst_shot_direction.x),
		"direction_y": _quantize(burst_shot_direction.y),
		"damage": get_effective_attack_damage(capoo_config.attack_damage),
		"phase_identity": phase_identity,
		"source_faction": snapshot.source_faction_id,
		"credit_peer_id": snapshot.credit_peer_id,
		"instigator_id": snapshot.instigator_entity_id,
		"event_source_id": snapshot.event_source_id,
		"source_type": String(snapshot.source_type),
	})
	return true


func _broadcast_enemy_action(
	action_name: StringName,
	direction: Vector2
) -> void:
	super._broadcast_enemy_action(action_name, direction)
	action_records.append({
		"tick": semantic_tick,
		"id": action_sequence,
		"name": String(action_name),
		"direction_x": _quantize(direction.x),
		"direction_y": _quantize(direction.y),
	})


func _event_record(event_name: StringName) -> Dictionary:
	return {
		"tick": semantic_tick,
		"phase": String(phase_context),
		"event": String(event_name),
	}


func _quantize(value: float) -> int:
	return roundi(value * 1_000_000.0)
