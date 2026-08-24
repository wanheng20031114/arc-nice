extends LinglanBoss
class_name LinglanBossLayeredSemanticHarness

## Keeps the authored Linglan state machine intact while replacing only world
## effects and body integration with deterministic trace records. Production
## remains exact-script fail-closed; this fixture explicitly opts into the same
## phase implementation so all four policies can replay one authored script.

const FIXED_PHYSICS_DELTA := 1.0 / 60.0

var phase_context: StringName = &""
var event_order_log := PackedStringArray()
var action_log := PackedStringArray()
var action_phase_log := PackedStringArray()
var ring_log := PackedStringArray()
var movement_log := PackedStringArray()
var touch_update_deltas: Array[float] = []
var warning_update_count := 0
var warning_clear_count := 0
var skill2_spawn_request_count := 0
var skill2_warning_spawn_count := 0
var skill2_warning_update_count := 0
var skill2_fire_count := 0
var pre_refactor_oracle_active := false


func _is_exact_layered_linglan_family() -> bool:
	return true


func set_pre_refactor_oracle_active(active: bool) -> void:
	pre_refactor_oracle_active = active


func set_active(active: bool) -> void:
	if not pre_refactor_oracle_active:
		super.set_active(active)
		return
	# Frozen copy of the pre-migration activation boundary. In particular, the
	# oracle must drive the authored physics flag directly instead of entering
	# the new coordinator-aware authoritative-driver transition.
	is_active = active
	visible = active
	set_process(active)
	set_physics_process(active)
	if touch_damage_area != null:
		touch_damage_area.set_deferred("monitoring", active)
		touch_damage_area.set_deferred("monitorable", active)
	_set_collision_shapes_disabled(body_collision_shapes, not active)
	_set_collision_shapes_disabled(touch_damage_shapes, not active)
	if not active:
		_clear_touching_players()
		_reset_skill_state()


func reset_semantic_trace() -> void:
	phase_context = &""
	event_order_log.clear()
	action_log.clear()
	action_phase_log.clear()
	ring_log.clear()
	movement_log.clear()
	touch_update_deltas.clear()
	warning_update_count = 0
	warning_clear_count = 0
	skill2_spawn_request_count = 0
	skill2_warning_spawn_count = 0
	skill2_warning_update_count = 0
	skill2_fire_count = 0
	action_sequence = 0


func _run_authoritative_physics_step(delta: float) -> void:
	phase_context = &"legacy"
	super._run_authoritative_physics_step(delta)
	phase_context = &""


func simulate_pre_refactor_authoritative_step(delta: float) -> void:
	# Frozen copy of the pre-migration `_physics_process` phase machine. It does
	# not call the refactored event/motion runner shared by current policies.
	var previous_context := phase_context
	phase_context = &"oracle"
	if not is_active or is_dead:
		velocity = Vector2.ZERO
		phase_context = previous_context
		return
	_update_touch_damage(delta)
	_update_enrage_sniper_airdrops(delta)
	_update_tower_slime_summoning(delta)
	match boss_skill_phase:
		BossSkillPhase.SKILL1:
			_update_skill1(delta)
			velocity = Vector2.ZERO
			if skill1_finished:
				_finish_skill(1)
		BossSkillPhase.MOVE_TO_SKILL2:
			_update_skill2_move(delta)
		BossSkillPhase.SKILL2:
			_update_skill2(delta)
		BossSkillPhase.MOVE_TO_SKILL3:
			_update_skill3_move(delta)
		BossSkillPhase.SKILL3:
			_update_skill3(delta)
		BossSkillPhase.MOVE_TO_SKILL4:
			_update_skill4_move(delta)
		BossSkillPhase.SKILL4:
			_update_skill4(delta)
		BossSkillPhase.POST_SKILL_IDLE:
			_update_post_skill_idle(delta)
		BossSkillPhase.ADVANCE_TO_HOME:
			_update_tower_advance(delta)
		_:
			velocity = Vector2.ZERO
			_play_idle_animation()
	phase_context = previous_context


func _advance_layered_event_body(delta: float) -> void:
	var previous_context := phase_context
	if _is_layered_scheduler_dispatch():
		phase_context = &"event"
	super._advance_layered_event_body(delta)
	phase_context = previous_context


func _advance_layered_motion_body(delta: float) -> void:
	var previous_context := phase_context
	if _is_layered_scheduler_dispatch():
		phase_context = &"motion"
	super._advance_layered_motion_body(delta)
	phase_context = previous_context


func _is_layered_scheduler_dispatch() -> bool:
	if (
		enemy_simulation_coordinator == null
		or not is_instance_valid(enemy_simulation_coordinator)
	):
		return false
	return enemy_simulation_coordinator.mode in [
		EnemySimulationPolicy.Mode.LAYERED_AREA,
		EnemySimulationPolicy.Mode.LAYERED_CONTACT,
	]


func _update_touch_damage(delta: float) -> void:
	event_order_log.append(&"touch")
	touch_update_deltas.append(delta)
	super._update_touch_damage(delta)


func _update_enrage_sniper_airdrops(delta: float) -> void:
	event_order_log.append(&"enrage")
	super._update_enrage_sniper_airdrops(delta)


func _update_tower_slime_summoning(delta: float) -> void:
	event_order_log.append(&"slime")
	super._update_tower_slime_summoning(delta)


func _update_skill1(delta: float) -> void:
	event_order_log.append(&"skill1")
	super._update_skill1(delta)


func _update_skill2_move(delta: float) -> void:
	event_order_log.append(&"move2")
	super._update_skill2_move(delta)


func _update_skill2(delta: float) -> void:
	event_order_log.append(&"skill2")
	super._update_skill2(delta)


func _fire_skill1_ring(skill_elapsed: float) -> void:
	ring_log.append("ring:%d" % _quantize(skill_elapsed))
	action_phase_log.append("ring:%s" % String(phase_context))


func _update_skill1_warning_rays() -> void:
	warning_update_count += 1


func _clear_skill1_warning_rays() -> void:
	warning_clear_count += 1
	skill1_warning_rays.clear()


func _request_skill2_spawn_adds() -> void:
	skill2_spawn_request_count += 1


func _spawn_skill2_warning_arrow(shot_index: int) -> void:
	skill2_warning_spawn_count += 1
	skill2_warning_shot_index = shot_index


func _update_skill2_warning_arrow() -> void:
	skill2_warning_update_count += 1


func _fire_skill2_rocket() -> void:
	skill2_fire_count += 1


func _clear_skill2_warning_arrow() -> void:
	skill2_warning_shot_index = -1
	skill2_warning_arrow = null


func _broadcast_enemy_action(
	action_name: StringName,
	direction: Vector2
) -> void:
	super._broadcast_enemy_action(action_name, direction)
	action_log.append(
		"%d:%s:%d:%d"
		% [
			action_sequence,
			String(action_name),
			_quantize(direction.x),
			_quantize(direction.y),
		]
	)
	action_phase_log.append(
		"%s:%s" % [String(action_name), String(phase_context)]
	)


func _has_player_contact() -> bool:
	return false


func _move_after_confirmed_no_contact(delta: float = -1.0) -> void:
	if velocity == Vector2.ZERO:
		return
	var motion_delta := delta if delta >= 0.0 else FIXED_PHYSICS_DELTA
	movement_log.append(
		"%s:%d:%d"
		% [
			String(phase_context),
			_quantize(velocity.x),
			_quantize(velocity.y),
		]
	)
	global_position += velocity * motion_delta


func _quantize(value: float) -> int:
	return roundi(value * 1_000_000.0)
