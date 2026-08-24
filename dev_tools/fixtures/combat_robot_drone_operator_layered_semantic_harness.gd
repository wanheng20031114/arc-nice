extends CombatRobotDroneOperator
class_name CombatRobotDroneOperatorLayeredSemanticHarness

## Authored replay double for the production DroneOperator state machine. Only
## navigation, LOS and the final drone lease boundary are recorded; selection,
## event clocks, target/faction validation, actions and motion gates remain real.

const FIXED_PHYSICS_DELTA := 1.0 / 60.0

var forced_visibility := true
var forced_move_direction := Vector2.RIGHT
var force_straight_contact_plan_certified := true
var use_real_drone_spawn := false
var pre_refactor_oracle_active := false
var suppress_semantic_facing_contact_dirty := false
var semantic_tick := 0
var phase_context: StringName = &""

var movement_submission_count := 0
var touch_update_count := 0
var spawn_attempt_count := 0
var selection_attempt_ticks: Array[int] = []
var selection_attempt_phases: Array[String] = []
var drone_records: Array[Dictionary] = []
var drone_record_phases: Array[String] = []
var action_log: Array[String] = []


func supports_layered_area_authoritative_simulation() -> bool:
	# Production deliberately rejects derived scripts. This authored harness opts
	# into the same production phase bodies for deterministic policy replay.
	return true


func supports_layered_contact_authoritative_simulation() -> bool:
	return true


func supports_indexed_touch_authority() -> bool:
	return false


func is_layered_area_contact_plan_certified(
	_delta: float,
	_counterpart: Node2D
) -> bool:
	return force_straight_contact_plan_certified


func reset_semantic_trace() -> void:
	phase_context = &""
	movement_submission_count = 0
	touch_update_count = 0
	spawn_attempt_count = 0
	selection_attempt_ticks.clear()
	selection_attempt_phases.clear()
	drone_records.clear()
	drone_record_phases.clear()
	action_log.clear()
	action_sequence = 0


func set_pre_refactor_oracle_active(active: bool) -> void:
	pre_refactor_oracle_active = active
	if not active:
		return
	# HEAD used only the three authored physics Timer nodes. The oracle must never
	# inherit a captured layered deadline from the implementation under test.
	layered_operator_clock_authority = false
	deploy_timer.paused = false
	cooldown_timer.paused = false
	blocked_retry_timer.paused = false


func emit_pre_refactor_attack_sense_entered(body: Node2D) -> void:
	attack_sense_area.emit_signal(&"body_entered", body)


func emit_pre_refactor_attack_sense_exited(body: Node2D) -> void:
	attack_sense_area.emit_signal(&"body_exited", body)


func _run_authoritative_physics_step(delta: float) -> void:
	phase_context = &"compat"
	super._run_authoritative_physics_step(delta)
	phase_context = &""


func simulate_pre_refactor_authoritative_step(delta: float) -> void:
	# Frozen from HEAD `CombatRobotDroneOperator._physics_process`. The oracle
	# bypasses every new phase helper and lets native child Timers signal normally.
	var previous_phase := phase_context
	phase_context = &"oracle"
	if is_dead:
		velocity = Vector2.ZERO
		phase_context = previous_phase
		return

	_update_touch_damage(maxf(delta, 0.0))
	if combat_state == CombatState.DEPLOY:
		velocity = Vector2.ZERO
		_update_facing(locked_deploy_direction)
		phase_context = previous_phase
		return

	var tracking_target: Node2D = null
	if combat_state == CombatState.TRACKING_COOLDOWN:
		tracking_target = _get_live_last_attack_target()
	_update_tracking_movement(tracking_target)
	phase_context = previous_phase


func _on_attack_sense_area_body_entered(body: Node2D) -> void:
	if not pre_refactor_oracle_active:
		super._on_attack_sense_area_body_entered(body)
		return
	if is_dead or is_multiplayer_proxy:
		return
	if not _is_ranged_combat_target_valid(body):
		return
	sensed_targets[body.get_instance_id()] = body
	if combat_state == CombatState.TRACKING_READY:
		_try_select_and_begin_deploy()


func _on_attack_sense_area_body_exited(body: Node2D) -> void:
	if not pre_refactor_oracle_active:
		super._on_attack_sense_area_body_exited(body)
		return
	if body != null:
		sensed_targets.erase(body.get_instance_id())
	if combat_state == CombatState.TRACKING_READY and sensed_targets.is_empty():
		if not _has_in_range_attackable_objective():
			blocked_retry_timer.stop()


func _on_objective_target_changed(
	_enemy: Enemy,
	_current_target: Node2D
) -> void:
	if not pre_refactor_oracle_active:
		super._on_objective_target_changed(_enemy, _current_target)
		return
	if (
		is_dead
		or is_multiplayer_proxy
		or combat_state != CombatState.TRACKING_READY
	):
		return
	_try_select_and_begin_deploy()


func _on_deploy_timer_timeout() -> void:
	if not pre_refactor_oracle_active:
		super._on_deploy_timer_timeout()
		return
	if is_dead or is_multiplayer_proxy or combat_state != CombatState.DEPLOY:
		return
	combat_state = CombatState.TRACKING_COOLDOWN
	velocity = Vector2.ZERO
	_reset_ranged_attack_position_state()
	_clear_cached_navigation_move_direction()
	if config != null:
		_play_scene_animation(config.move_animation_name)
	var cooldown := (
		maxf(operator_config_cache.attack_cooldown, 0.0)
		if operator_config_cache != null
		else 0.0
	)
	if cooldown <= 0.0:
		_on_cooldown_timer_timeout()
		return
	cooldown_timer.start(cooldown)


func _on_cooldown_timer_timeout() -> void:
	if not pre_refactor_oracle_active:
		super._on_cooldown_timer_timeout()
		return
	if (
		is_dead
		or is_multiplayer_proxy
		or combat_state != CombatState.TRACKING_COOLDOWN
	):
		return
	combat_state = CombatState.TRACKING_READY
	last_attack_target = null
	_reset_ranged_attack_position_state()
	_clear_cached_navigation_move_direction()
	_try_select_and_begin_deploy()


func _on_blocked_retry_timer_timeout() -> void:
	if not pre_refactor_oracle_active:
		super._on_blocked_retry_timer_timeout()
		return
	if is_dead or is_multiplayer_proxy or combat_state != CombatState.TRACKING_READY:
		return
	_try_select_and_begin_deploy()


func _advance_layered_area_family_event_phase(delta: float) -> void:
	phase_context = &"event"
	super._advance_layered_area_family_event_phase(delta)
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
	# The authored regression scripts target/faction mutations explicitly. Avoid
	# an unrelated target-index cadence obscuring the family state machine.
	pass


func _is_world_segment_clear(
	_target_position: Vector2,
	_collision_mask_value: int = 1
) -> bool:
	return forced_visibility


func _get_operator_navigation_move_direction(_target: Node2D) -> Vector2:
	return (
		forced_move_direction.normalized()
		if forced_move_direction != Vector2.ZERO
		else Vector2.ZERO
	)


func _update_facing(direction: Vector2) -> void:
	# This replay has no nearby contact counterpart. Preserve authored facing in
	# every policy, but do not let a visual mirror change inject CONTACT's safety
	# preflight pause into a pure state-machine comparison. All non-facing geometry
	# changes still reach the production dirty/recapture path.
	suppress_semantic_facing_contact_dirty = true
	super._update_facing(direction)
	suppress_semantic_facing_contact_dirty = false


func mark_contact_shape_geometry_changed() -> void:
	if suppress_semantic_facing_contact_dirty:
		return
	super.mark_contact_shape_geometry_changed()


func _move_after_confirmed_no_contact(delta: float = -1.0) -> void:
	if velocity == Vector2.ZERO:
		return
	movement_submission_count += 1
	var motion_delta := delta if delta >= 0.0 else FIXED_PHYSICS_DELTA
	global_position += velocity * motion_delta


func _update_touch_damage(delta: float) -> void:
	touch_update_count += 1
	super._update_touch_damage(delta)


func _collect_nearest_attack_candidates() -> void:
	if not pre_refactor_oracle_active:
		super._collect_nearest_attack_candidates()
		return
	# Frozen from HEAD. Do not let the oracle share the refactored projection-aware
	# selection pipeline with the implementation under test.
	nearest_target_buffer.clear()
	nearest_distance_buffer.clear()
	nearest_kind_buffer.clear()
	nearest_id_buffer.clear()
	stale_target_id_buffer.clear()
	if operator_config_cache == null:
		return

	var attack_range := maxf(operator_config_cache.attack_range, 0.0)
	var attack_range_squared := attack_range * attack_range
	var check_limit := maxi(operator_config_cache.visible_target_check_limit, 1)
	var proactive_target := get_attackable_objective()
	if proactive_target != null:
		_insert_attack_candidate_if_in_range(
			proactive_target,
			attack_range_squared,
			check_limit
		)
	for target_id_variant in sensed_targets:
		var target_id := int(target_id_variant)
		var target := sensed_targets.get(target_id) as Node2D
		if not _is_ranged_combat_target_valid(target):
			stale_target_id_buffer.append(target_id)
			continue
		_insert_attack_candidate_if_in_range(
			target,
			attack_range_squared,
			check_limit
		)

	for stale_target_id in stale_target_id_buffer:
		sensed_targets.erase(stale_target_id)


func _try_select_and_begin_deploy() -> bool:
	selection_attempt_ticks.append(semantic_tick)
	selection_attempt_phases.append(String(phase_context))
	if not pre_refactor_oracle_active:
		return super._try_select_and_begin_deploy()
	# Frozen from HEAD. Every Timer operation stays on the three authored native
	# Timer nodes; no layered armed/deadline projection is read or written.
	if (
		is_dead
		or is_multiplayer_proxy
		or combat_state != CombatState.TRACKING_READY
		or operator_config_cache == null
	):
		return false
	var designated_target := _get_active_designated_attack_target()
	if designated_target != null:
		if not _is_target_within_attack_range(designated_target):
			blocked_retry_timer.stop()
			return false
		if _is_world_segment_clear(
			designated_target.global_position,
			WORLD_COLLISION_MASK
		) and _begin_deploy(designated_target):
			blocked_retry_timer.stop()
			return true
		_arm_blocked_retry_if_needed(true)
		return false

	_collect_nearest_attack_candidates()
	for candidate_target in nearest_target_buffer:
		if not _is_world_segment_clear(
			candidate_target.global_position,
			WORLD_COLLISION_MASK
		):
			continue
		if _begin_deploy(candidate_target):
			blocked_retry_timer.stop()
			return true

	_arm_blocked_retry_if_needed()
	return false


func _begin_deploy(target: Node2D) -> bool:
	if not pre_refactor_oracle_active:
		return super._begin_deploy(target)
	# Frozen from HEAD; in particular, start DeployTimer directly rather than
	# routing through the layered clock helper.
	if not _is_ranged_combat_target_valid(target):
		return false
	var target_position := target.global_position
	var deploy_direction := global_position.direction_to(target_position)
	if deploy_direction == Vector2.ZERO:
		deploy_direction = Vector2.LEFT if facing_left else Vector2.RIGHT
	else:
		deploy_direction = deploy_direction.normalized()
	var outgoing_damage := get_effective_attack_damage(
		operator_config_cache.attack_damage
	)
	if not _spawn_committed_drone(
		target_position,
		deploy_direction,
		outgoing_damage
	):
		return false

	last_attack_target = target
	locked_target_position = target_position
	locked_deploy_direction = deploy_direction
	combat_state = CombatState.DEPLOY
	velocity = Vector2.ZERO
	blocked_retry_timer.stop()
	_clear_navigation_path()
	_set_ranged_attack_position_held(true)
	_update_facing(locked_deploy_direction)
	_play_scene_animation(operator_config_cache.deploy_animation_name)
	deploy_timer.start(maxf(operator_config_cache.deploy_delay, 0.001))
	_broadcast_enemy_action(ACTION_DEPLOY, locked_deploy_direction)
	return true


func _arm_blocked_retry_if_needed(force_retry: bool = false) -> void:
	if not pre_refactor_oracle_active:
		super._arm_blocked_retry_if_needed(force_retry)
		return
	# Frozen from HEAD; this must not arm the layered retry projection.
	if (
		operator_config_cache == null
		or combat_state != CombatState.TRACKING_READY
		or (
			not force_retry
			and sensed_targets.is_empty()
			and not _has_in_range_attackable_objective()
		)
	):
		blocked_retry_timer.stop()
		return
	blocked_retry_timer.start(
		maxf(operator_config_cache.blocked_retry_interval, 0.01)
	)


func _update_tracking_movement(
	tracking_target: Node2D,
	apply_motion: bool = true
) -> void:
	if not pre_refactor_oracle_active:
		super._update_tracking_movement(tracking_target, apply_motion)
		return
	# Frozen from HEAD. The deterministic fixture direction replaces only the old
	# navigation query; no layered navigation/contact projection is populated.
	var live_tracking_target := (
		tracking_target
		if _is_ranged_combat_target_valid(tracking_target)
		else null
	)
	var stop_distance := (
		maxf(operator_config_cache.stop_distance, 0.0)
		if operator_config_cache != null
		else 0.0
	)
	var within_stop_distance := (
		live_tracking_target != null
		and global_position.distance_squared_to(
			live_tracking_target.global_position
		) <= stop_distance * stop_distance
	)
	if _has_player_contact() or within_stop_distance:
		velocity = Vector2.ZERO
		_set_ranged_attack_position_held(true)
		if live_tracking_target != null:
			_update_facing(
				global_position.direction_to(live_tracking_target.global_position)
			)
		return

	_reset_ranged_attack_position_state()
	var navigation_target := (
		live_tracking_target
		if live_tracking_target != null
		else objective_target
	)
	if not is_instance_valid(navigation_target):
		velocity = Vector2.ZERO
		return
	var move_direction := _get_pre_refactor_navigation_move_direction(
		navigation_target
	)
	velocity = move_direction * get_effective_move_speed()
	_update_facing(move_direction)
	if apply_motion:
		_move_until_player_contact()


func _get_pre_refactor_navigation_move_direction(_target: Node2D) -> Vector2:
	return (
		forced_move_direction.normalized()
		if forced_move_direction != Vector2.ZERO
		else Vector2.ZERO
	)


func _cancel_operator_state(
	restore_move_animation: bool,
	disable_attack_sense: bool
) -> void:
	if not pre_refactor_oracle_active:
		super._cancel_operator_state(
			restore_move_animation,
			disable_attack_sense
		)
		return
	# Frozen from HEAD so oracle death/teardown cannot clear or otherwise mutate
	# the implementation-under-test layered projections.
	_stop_operator_timers()
	combat_state = CombatState.TRACKING_READY
	last_attack_target = null
	locked_target_position = Vector2.ZERO
	locked_deploy_direction = Vector2.RIGHT
	velocity = Vector2.ZERO
	sensed_targets.clear()
	nearest_target_buffer.clear()
	nearest_distance_buffer.clear()
	nearest_kind_buffer.clear()
	nearest_id_buffer.clear()
	stale_target_id_buffer.clear()
	_reset_ranged_attack_position_state()
	_clear_cached_navigation_move_direction()
	if disable_attack_sense and attack_sense_area != null:
		attack_sense_area.set_deferred("monitoring", false)
	if restore_move_animation and config != null and not is_dead:
		_play_scene_animation(config.move_animation_name)


func _spawn_committed_drone(
	target_position: Vector2,
	deploy_direction: Vector2,
	outgoing_damage: int
) -> bool:
	spawn_attempt_count += 1
	var spawned := true
	if use_real_drone_spawn:
		spawned = super._spawn_committed_drone(
			target_position,
			deploy_direction,
			outgoing_damage
		)
	if not spawned:
		return false
	var source_type := operator_config_cache.projectile_type
	var snapshot := create_damage_source_snapshot(0, source_type)
	var spawn_position := drone_spawn.global_position
	var flight_direction := spawn_position.direction_to(target_position)
	if flight_direction == Vector2.ZERO:
		flight_direction = deploy_direction
	else:
		flight_direction = flight_direction.normalized()
	var drone_speed := maxf(operator_config_cache.drone_speed, 0.0)
	drone_records.append({
		"tick": semantic_tick,
		"target_x": _quantize(target_position.x),
		"target_y": _quantize(target_position.y),
		"direction_x": _quantize(deploy_direction.x),
		"direction_y": _quantize(deploy_direction.y),
		"flight_direction_x": _quantize(flight_direction.x),
		"flight_direction_y": _quantize(flight_direction.y),
		"damage": outgoing_damage,
		"speed": _quantize(drone_speed),
		"duration": _quantize(
			spawn_position.distance_to(target_position) / maxf(drone_speed, 0.001)
		),
		"source_faction": snapshot.source_faction_id,
		"credit_peer": snapshot.credit_peer_id,
		"instigator": snapshot.instigator_entity_id,
		"source_type": String(snapshot.source_type),
	})
	drone_record_phases.append(String(phase_context))
	return true


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


func semantic_deploy_time_left() -> float:
	return (
		layered_deploy_time_left
		if layered_operator_clock_authority
		else deploy_timer.time_left
	)


func semantic_cooldown_time_left() -> float:
	return (
		layered_cooldown_time_left
		if layered_operator_clock_authority
		else cooldown_timer.time_left
	)


func semantic_blocked_retry_time_left() -> float:
	return (
		layered_blocked_retry_time_left
		if layered_operator_clock_authority
		else blocked_retry_timer.time_left
	)


func _quantize(value: float) -> int:
	return roundi(value * 1_000_000.0)
