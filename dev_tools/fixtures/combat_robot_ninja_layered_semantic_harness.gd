extends CombatRobotNinja
class_name CombatRobotNinjaLayeredSemanticHarness

## Preserve the authored boost/contact/timer state machine while replacing only
## navigation movement and audible playback with deterministic evidence.

const FIXED_PHYSICS_DELTA := 1.0 / 60.0

var forced_move_direction := Vector2.RIGHT
var forced_decision_interval_frames := 1
var pre_refactor_oracle_active := false
var suppress_semantic_facing_contact_dirty := false
var semantic_tick := 0
var phase_context: StringName = &""

var movement_submission_count := 0
var touch_update_count := 0
var family_event_count := 0
var family_decision_count := 0
var motion_phase_count := 0
var action_ticks: Array[int] = []
var action_names: Array[StringName] = []
var action_phases: Array[StringName] = []
var movement_phases: Array[StringName] = []
var boost_audio_pitch_samples: Array[int] = []


func _is_exact_layered_ninja_family() -> bool:
	# Production deliberately rejects derived scripts. This authored harness opts
	# in only to exercise the exact production phase implementation.
	return true


func get_layered_area_decision_interval_frames() -> int:
	return maxi(forced_decision_interval_frames, 1)


func reset_semantic_trace() -> void:
	semantic_tick = 0
	phase_context = &""
	movement_submission_count = 0
	touch_update_count = 0
	family_event_count = 0
	family_decision_count = 0
	motion_phase_count = 0
	action_ticks.clear()
	action_names.clear()
	action_phases.clear()
	movement_phases.clear()
	boost_audio_pitch_samples.clear()
	action_sequence = 0


func set_pre_refactor_oracle_active(active: bool) -> void:
	pre_refactor_oracle_active = active
	if not active:
		return
	# The frozen oracle is driven only by the authored native physics Timers.
	# Never let a layered clock or paused Timer leak in from fixture admission.
	layered_ninja_timer_authority_active = false
	boost_timer.paused = false
	cooldown_timer.paused = false


func _run_authoritative_physics_step(delta: float) -> void:
	phase_context = &"compat"
	super._run_authoritative_physics_step(delta)
	phase_context = &""


func simulate_pre_refactor_authoritative_step(delta: float) -> void:
	# Frozen from HEAD `CombatRobotNinja._physics_process`. It intentionally does
	# not call SimpleChaseLayeredEnemy or any layered clock helper.
	var previous_phase := phase_context
	phase_context = &"oracle"
	if is_dead:
		velocity = Vector2.ZERO
		phase_context = previous_phase
		return

	_update_touch_damage(maxf(delta, 0.0))
	if not is_instance_valid(objective_target):
		velocity = Vector2.ZERO
		_move_until_player_contact()
		phase_context = previous_phase
		return
	if _has_player_contact():
		velocity = Vector2.ZERO
		phase_context = previous_phase
		return

	var move_direction := _get_safe_navigation_move_direction(
		objective_target,
		pathfinder,
		waypoint_arrival_distance
	)
	_update_facing(move_direction)
	velocity = move_direction * get_effective_move_speed()
	var position_before_move := global_position
	_move_until_player_contact()
	if boost_active:
		var actual_displacement := global_position - position_before_move
		if actual_displacement != Vector2.ZERO:
			_update_afterimage_direction(actual_displacement)
	phase_context = previous_phase


func _try_start_damage_boost() -> bool:
	if not pre_refactor_oracle_active:
		return super._try_start_damage_boost()
	# Frozen from HEAD. Native BoostTimer/CooldownTimer are the only clocks here.
	if (
		is_dead
		or is_multiplayer_proxy
		or boost_active
		or boost_cooldown_active
		or ninja_config_cache == null
	):
		return false
	var boost_duration := maxf(ninja_config_cache.boost_duration, 0.0)
	if boost_duration <= 0.0:
		return false
	boost_active = true
	boost_cooldown_active = true
	boost_timer.start(boost_duration)
	var cooldown_duration := maxf(ninja_config_cache.boost_cooldown, 0.0)
	if cooldown_duration > 0.0:
		cooldown_timer.start(cooldown_duration)
	else:
		boost_cooldown_active = false
	_switch_locomotion_animation_preserving_phase(
		ninja_config_cache.boost_animation_name,
		true
	)
	_sync_blade_contact_shapes()
	_clear_cached_navigation_move_direction()
	var boost_direction := (
		velocity.normalized()
		if velocity != Vector2.ZERO
		else _get_facing_direction()
	)
	_update_afterimage_direction(boost_direction, true)
	_set_afterimage_strength(1.0)
	_play_boost_audio()
	_broadcast_enemy_action(boost_direction)
	return true


func _on_boost_timer_timeout() -> void:
	if not pre_refactor_oracle_active:
		super._on_boost_timer_timeout()
		return
	if is_dead or not boost_active:
		return
	_finish_damage_boost(true)


func _on_cooldown_timer_timeout() -> void:
	if not pre_refactor_oracle_active:
		super._on_cooldown_timer_timeout()
		return
	if is_multiplayer_proxy:
		return
	boost_cooldown_active = false


func _finish_damage_boost(restore_move_animation: bool) -> void:
	if not pre_refactor_oracle_active:
		super._finish_damage_boost(restore_move_animation)
		return
	# Frozen from HEAD. In particular, do not mutate layered deadline flags and do
	# not route the blade swap through the contact-geometry dirty marker.
	if not boost_active:
		return
	boost_active = false
	proxy_boost_started_from_action = false
	boost_timer.stop()
	_set_afterimage_strength(0.0)
	if slash_audio != null:
		slash_audio.stop()
	_sync_blade_contact_shapes()
	_clear_cached_navigation_move_direction()
	if restore_move_animation and not is_dead and config != null:
		_switch_locomotion_animation_preserving_phase(
			config.move_animation_name
		)
	if is_multiplayer_proxy:
		proxy_action_animation_name_in_use = &""
		proxy_action_restore_token += 1


func _cancel_damage_boost(
	restore_move_animation: bool,
	disable_contacts: bool
) -> void:
	if not pre_refactor_oracle_active:
		super._cancel_damage_boost(restore_move_animation, disable_contacts)
		return
	# Frozen from HEAD for oracle death/cancel boundaries.
	boost_active = false
	boost_cooldown_active = false
	proxy_boost_started_from_action = false
	_stop_boost_timers()
	_set_afterimage_strength(0.0)
	if slash_audio != null:
		slash_audio.stop()
	if disable_contacts:
		_set_all_blade_contact_shapes_disabled()
	else:
		_sync_blade_contact_shapes()
	if restore_move_animation and not is_dead and config != null:
		_switch_locomotion_animation_preserving_phase(
			config.move_animation_name
		)
	proxy_action_animation_name_in_use = &""
	proxy_action_restore_token += 1
	_clear_cached_navigation_move_direction()


func _sync_blade_contact_shapes() -> void:
	if not pre_refactor_oracle_active:
		super._sync_blade_contact_shapes()
		return
	# Exact HEAD shape toggle: no authored-state bookkeeping, no shared-contact
	# geometry revision, and no unconditional deferred rewrite.
	if is_multiplayer_proxy or is_dead:
		_set_all_blade_contact_shapes_disabled()
		return
	_set_pre_refactor_collision_shape_disabled_deferred(
		move_rear_blade_shape,
		boost_active
	)
	_set_pre_refactor_collision_shape_disabled_deferred(
		move_front_blade_shape,
		boost_active
	)
	_set_pre_refactor_collision_shape_disabled_deferred(
		boost_upper_blade_shape,
		not boost_active
	)
	_set_pre_refactor_collision_shape_disabled_deferred(
		boost_lower_blade_shape,
		not boost_active
	)


func _set_all_blade_contact_shapes_disabled() -> void:
	if not pre_refactor_oracle_active:
		super._set_all_blade_contact_shapes_disabled()
		return
	for shape_node in _get_blade_contact_shapes():
		_set_pre_refactor_collision_shape_disabled_deferred(shape_node, true)


func _set_pre_refactor_collision_shape_disabled_deferred(
	shape_node: CollisionShape2D,
	disabled: bool
) -> void:
	if shape_node == null or shape_node.disabled == disabled:
		return
	shape_node.set_deferred("disabled", disabled)


func is_touch_damage_shape_authored_enabled(
	shape_node: CollisionShape2D
) -> bool:
	if not pre_refactor_oracle_active:
		return super.is_touch_damage_shape_authored_enabled(shape_node)
	# HEAD had no authored-shape projection. Oracle diagnostics must observe the
	# real deferred CollisionShape2D result instead of stale migration metadata.
	return (
		shape_node != null
		and is_instance_valid(shape_node)
		and not shape_node.disabled
	)


func _stop_boost_timers() -> void:
	if not pre_refactor_oracle_active:
		super._stop_boost_timers()
		return
	if boost_timer != null:
		boost_timer.stop()
	if cooldown_timer != null:
		cooldown_timer.stop()


func _advance_layered_area_family_event_phase(delta: float) -> void:
	phase_context = &"event"
	family_event_count += 1
	super._advance_layered_area_family_event_phase(delta)
	phase_context = &""


func _try_consume_layered_area_family_decision_phase(delta: float) -> bool:
	phase_context = &"decision"
	family_decision_count += 1
	var consumed := super._try_consume_layered_area_family_decision_phase(delta)
	phase_context = &""
	return consumed


func _simulate_layered_area_motion_body(delta: float) -> bool:
	phase_context = &"motion"
	motion_phase_count += 1
	var completed := super._simulate_layered_area_motion_body(delta)
	phase_context = &""
	return completed


func _get_safe_navigation_move_direction(
	_target_node: Node2D,
	_shared_pathfinder: Node,
	_waypoint_arrival_distance: float
) -> Vector2:
	# One deterministic world seam for both frozen HEAD (`_physics_process` calls
	# this method directly) and every migrated policy (the family navigation hook
	# delegates here). Keeping it below both runners prevents a false oracle split.
	return (
		forced_move_direction.normalized()
		if forced_move_direction != Vector2.ZERO
		else Vector2.ZERO
	)


func _update_facing(move_direction: Vector2) -> void:
	# This semantic replay has no near contact counterpart. Preserve the authored
	# facing/mirror result in every runner, while keeping that visual direction
	# change from injecting CONTACT's deliberate one-tick geometry-preflight pause
	# into an otherwise pure state-machine comparison. Boost blade-union changes
	# still flow through the real dirty/recapture path below.
	suppress_semantic_facing_contact_dirty = true
	super._update_facing(move_direction)
	suppress_semantic_facing_contact_dirty = false


func mark_contact_shape_geometry_changed() -> void:
	if suppress_semantic_facing_contact_dirty:
		return
	super.mark_contact_shape_geometry_changed()


func _move_until_player_contact(delta: float = -1.0) -> void:
	_submit_probe_motion(delta)


func _move_after_confirmed_no_contact(delta: float = -1.0) -> void:
	_submit_probe_motion(delta)


func _submit_probe_motion(delta: float) -> void:
	if velocity.is_zero_approx():
		return
	movement_submission_count += 1
	movement_phases.append(phase_context)
	var motion_delta := delta if delta >= 0.0 else FIXED_PHYSICS_DELTA
	global_position += velocity * motion_delta
	if boost_active:
		_update_afterimage_direction(velocity)


func _update_touch_damage(delta: float) -> void:
	touch_update_count += 1
	super._update_touch_damage(delta)


func _broadcast_enemy_action(direction: Vector2) -> void:
	super._broadcast_enemy_action(direction)
	action_ticks.append(semantic_tick)
	action_names.append(ACTION_BOOST)
	action_phases.append(phase_context)


func _play_boost_audio(_start_offset: float = 0.0) -> void:
	# Production samples pitch before consulting the global limiter. Preserve the
	# RNG consumption without introducing an audible/headless side effect.
	boost_audio_pitch_samples.append(
		roundi(random_generator.randf_range(0.96, 1.04) * 1_000_000.0)
	)
