extends FireSorcerer
class_name FireSorcererLayeredSemanticHarness

## Keeps the authored three-preview Fire scene and DATA volley service intact.
## Only world-dependent target/range/LOS/navigation answers are scripted so all
## four simulation policies replay one deterministic combat transcript.

const FIXED_PHYSICS_DELTA := 1.0 / 60.0

var forced_target: Node2D = null
var forced_target_valid := true
var forced_target_in_range := true
var forced_los_clear := true
var forced_move_direction := Vector2.RIGHT

var phase_context: StringName = &""
var cooldown_update_deltas: Array[float] = []
var summon_start_phases: Array[StringName] = []
var fire_resolve_phases: Array[StringName] = []
var cancel_phases: Array[StringName] = []
var movement_submission_count := 0
var action_log := PackedStringArray()
var volley_attempt_count := 0
var volley_records: Array[Dictionary] = []
var volley_handles := PackedInt64Array()
var los_query_count := 0


func reset_semantic_trace() -> void:
	phase_context = &""
	cooldown_update_deltas.clear()
	summon_start_phases.clear()
	fire_resolve_phases.clear()
	cancel_phases.clear()
	movement_submission_count = 0
	action_log.clear()
	action_sequence = 0
	volley_attempt_count = 0
	volley_records.clear()
	volley_handles.clear()
	los_query_count = 0


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


func _try_start_summon(
	attack_target: Node2D,
	fire_config: FireSorcererConfig
) -> bool:
	var started := super._try_start_summon(attack_target, fire_config)
	if started:
		summon_start_phases.append(phase_context)
	return started


func _finish_summon_and_fire(fire_config: FireSorcererConfig) -> void:
	fire_resolve_phases.append(phase_context)
	super._finish_summon_and_fire(fire_config)


func _cancel_summon(restore_move_animation := true) -> void:
	if combat_state == CombatState.SUMMON:
		cancel_phases.append(phase_context)
	super._cancel_summon(restore_move_animation)


func _select_nearest_attack_target(
	fallback_target: Node2D,
	_fire_config: FireSorcererConfig,
	allow_runtime_refresh: bool
) -> Node2D:
	if not _is_ranged_combat_target_valid(cached_runtime_attack_target):
		cached_runtime_attack_target = null
		attack_target_refresh_left = 0.0
	if allow_runtime_refresh and attack_target_refresh_left <= 0.0:
		attack_target_refresh_left = ATTACK_TARGET_REFRESH_INTERVAL
		cached_runtime_attack_target = (
			forced_target
			if _is_ranged_combat_target_valid(forced_target)
			else null
		)
	if cached_runtime_attack_target != null:
		return cached_runtime_attack_target
	return (
		fallback_target
		if _is_ranged_combat_target_valid(fallback_target)
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


func _is_ranged_combat_target_in_range(
	target: Node2D,
	_attack_range: float
) -> bool:
	return forced_target_in_range and _is_ranged_combat_target_valid(target)


func _has_ranged_combat_line(
	target: Node2D,
	_collision_mask_value: int = 1,
	_force_refresh: bool = false
) -> bool:
	los_query_count += 1
	return forced_los_clear and _is_ranged_combat_target_valid(target)


func refresh_dynamic_combat_target_decision(_simulation_tick: int) -> void:
	# The golden authors each target/faction edge. Production Fire keeps Enemy's
	# dynamic-target refresh implementation unchanged.
	pass


func _get_navigation_move_direction(_delta: float) -> Vector2:
	return forced_move_direction.normalized()


func _move_after_confirmed_no_contact(delta: float = -1.0) -> void:
	if velocity == Vector2.ZERO:
		return
	movement_submission_count += 1
	var motion_delta := delta if delta >= 0.0 else FIXED_PHYSICS_DELTA
	global_position += velocity * motion_delta


func _broadcast_enemy_action(
	action_name: StringName,
	direction: Vector2
) -> void:
	super._broadcast_enemy_action(action_name, direction)
	action_log.append("%d:%s" % [action_sequence, String(action_name)])


func _spawn_fireball_volley(fire_config: FireSorcererConfig) -> bool:
	volley_attempt_count += 1
	var target_at_launch := summon_target
	var service := _get_fire_sorcerer_volley_simulation_service()
	var record_count_before := (
		service.get_dense_record_count() if service != null else 0
	)
	var spawned := super._spawn_fireball_volley(fire_config)
	if not spawned or service == null:
		return spawned
	service.set_physics_process(false)
	var handle := FireSorcererVolleySimulationService.INVALID_HANDLE
	for stable_index in range(
		record_count_before,
		service.get_dense_record_count()
	):
		var candidate := service.get_handle_at_stable_index(stable_index)
		if candidate > FireSorcererVolleySimulationService.INVALID_HANDLE:
			handle = candidate
	if handle <= FireSorcererVolleySimulationService.INVALID_HANDLE:
		return spawned
	volley_handles.append(handle)
	var dense_slot := int(service.call(&"_resolve_dense_slot", handle))
	var damages: PackedInt32Array = service.get("_damages")
	var speeds: PackedFloat64Array = service.get("_speeds")
	var target_ids: PackedInt64Array = service.get("_target_instance_ids")
	var burn_durations: PackedFloat64Array = service.get("_burn_durations")
	var burn_levels: PackedInt32Array = service.get("_burn_levels")
	var source_factions: PackedInt32Array = service.get("_source_faction_ids")
	var credit_peers: PackedInt64Array = service.get("_source_credit_peer_ids")
	var instigator_ids: PackedInt64Array = service.get(
		"_source_instigator_entity_ids"
	)
	var event_ids: PackedInt64Array = service.get("_source_event_ids")
	var positions := PackedInt64Array()
	var directions := PackedInt64Array()
	for ball_index in range(FireSorcererVolleySimulationService.BALL_COUNT):
		var ball_position := service.get_ball_position(handle, ball_index)
		var ball_direction := service.get_ball_direction(handle, ball_index)
		positions.append(_quantize(ball_position.x))
		positions.append(_quantize(ball_position.y))
		directions.append(_quantize(ball_direction.x))
		directions.append(_quantize(ball_direction.y))
	volley_records.append({
		"handle": handle,
		"mode": service.get_slot_mode(handle),
		"profile": service.get_slot_profile(handle),
		"state": service.get_slot_state(handle),
		"mask": service.get_active_ball_mask(handle),
		"positions": positions,
		"directions": directions,
		"damage": int(damages[dense_slot]),
		"speed": _quantize(float(speeds[dense_slot])),
		"lifetime": _quantize(service.get_remaining_lifetime(handle)),
		"target_instance": int(target_ids[dense_slot]),
		"target_net_id": (
			int(target_at_launch.get_meta(&"net_id", 0))
			if target_at_launch != null and is_instance_valid(target_at_launch)
			else 0
		),
		"burn_duration": _quantize(float(burn_durations[dense_slot])),
		"burn_level": int(burn_levels[dense_slot]),
		"source_faction": int(source_factions[dense_slot]),
		"credit_peer": int(credit_peers[dense_slot]),
		"instigator": int(instigator_ids[dense_slot]),
		"event_id": int(event_ids[dense_slot]),
		"family_source_type": String(
			service.get_profile_family_source_type(
				service.get_slot_profile(handle)
			)
		),
		"ball0_source_type": String(
			service.get_profile_ball_source_type(
				service.get_slot_profile(handle),
				0
			)
		),
	})
	return spawned


func apply_recorded_ball_contact(
	volley_index: int,
	ball_index: int,
	target: Node2D
) -> bool:
	if (
		volley_index < 0
		or volley_index >= volley_handles.size()
		or target == null
		or not is_instance_valid(target)
	):
		return false
	var service := _get_fire_sorcerer_volley_simulation_service()
	if service == null:
		return false
	var dense_slot := int(service.call(
		&"_resolve_dense_slot",
		int(volley_handles[volley_index])
	))
	if dense_slot < 0:
		return false
	service.set("_endpoint_target", target)
	var accepted := bool(service.call(
		&"_apply_authoritative_damage",
		dense_slot,
		ball_index,
		true
	))
	service.set("_endpoint_target", null)
	return accepted


func _quantize(value: float) -> int:
	return roundi(value * 1_000_000.0)
