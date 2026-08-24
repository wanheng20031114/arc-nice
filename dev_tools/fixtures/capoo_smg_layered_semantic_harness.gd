extends CapooSMG
class_name CapooSMGLayeredSemanticHarness

## Keeps the authored SMG timer/aim/RNG/action runner intact. Only world queries,
## body submission and projectile backends are replaced with deterministic probes.

const FIXED_PHYSICS_DELTA := 1.0 / 60.0

var forced_target: Node2D = null
var forced_target_valid := true
var forced_player_contact := false
var forced_move_direction := Vector2.RIGHT
var forced_fire_success := true

var semantic_tick := 0
var phase_context: StringName = &""
var movement_submission_count := 0
var touch_update_deltas: Array[float] = []
var fire_opportunity_count := 0
var fire_opportunity_records: Array[Dictionary] = []
var shot_attempt_count := 0
var shot_records: Array[Dictionary] = []
var action_records: Array[Dictionary] = []
var muzzle_progress_records: Array[int] = []


func _is_exact_layered_smg_family() -> bool:
	# Production rejects derived scripts. This authored test double opts in only
	# to exercise the exact production phase implementation under four policies.
	return true


func reset_semantic_trace() -> void:
	semantic_tick = 0
	phase_context = &""
	movement_submission_count = 0
	touch_update_deltas.clear()
	fire_opportunity_count = 0
	fire_opportunity_records.clear()
	shot_attempt_count = 0
	shot_records.clear()
	action_records.clear()
	muzzle_progress_records.clear()
	action_sequence = 0
	hitscan_shots_fired = 0
	last_shot_direction = Vector2.RIGHT
	combat_target_refresh_count = 0
	_invalidate_combat_target_cache()


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
	# The regression authors target death/faction/selection edges explicitly.
	pass


func _get_preferred_ranged_combat_target() -> Node2D:
	return (
		forced_target
		if _is_ranged_combat_target_valid(forced_target)
		else null
	)


func _is_ranged_combat_target_valid(target: Node2D) -> bool:
	return (
		forced_target_valid
		and target != null
		and target == forced_target
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
	super._update_touch_damage(delta)


func _try_fire_scatter(
	base_direction: Vector2,
	attack_target: Node2D = null
) -> bool:
	fire_opportunity_count += 1
	fire_opportunity_records.append({
		"tick": semantic_tick,
		"phase": String(phase_context),
		"target_id": (
			int(attack_target.get_meta(&"net_id", 0))
			if attack_target != null
			else 0
		),
		"base_direction_x": _quantize(base_direction.x),
		"base_direction_y": _quantize(base_direction.y),
	})
	return super._try_fire_scatter(base_direction, attack_target)


func _fire_bullet(shoot_direction: Vector2) -> bool:
	shot_attempt_count += 1
	if not forced_fire_success or smg_config_cache == null:
		return false
	var source_type := &"capoo_smg_hitscan"
	var source_id := _get_multiplayer_damage_source_id(action_sequence + 1)
	var snapshot := create_damage_source_snapshot(source_id, source_type)
	shot_records.append({
		"tick": semantic_tick,
		"phase": String(phase_context),
		"mode": "hitscan",
		"origin_x": _quantize(global_position.x),
		"origin_y": _quantize(global_position.y),
		"direction_x": _quantize(shoot_direction.x),
		"direction_y": _quantize(shoot_direction.y),
		"damage": get_effective_attack_damage(smg_config_cache.attack_damage),
		"source_faction": snapshot.source_faction_id,
		"credit_peer_id": snapshot.credit_peer_id,
		"instigator_id": snapshot.instigator_entity_id,
		"event_source_id": snapshot.event_source_id,
		"source_type": String(snapshot.source_type),
	})
	hitscan_shots_fired += 1
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


func _set_muzzle_flash(progress: float, direction: Vector2) -> void:
	muzzle_progress_records.append(_quantize(clampf(progress, 0.0, 1.0)))
	super._set_muzzle_flash(progress, direction)


func _quantize(value: float) -> int:
	return roundi(value * 1_000_000.0)
