extends CapooMage
class_name CapooMageLayeredSemanticHarness

## Authored Mage scene/state/visual/projectile behavior remains intact. The
## fixture replaces only world-dependent target, LOS, navigation and body motion
## answers so every simulation policy replays one deterministic script.

const FIXED_PHYSICS_DELTA := 1.0 / 60.0

var forced_target: Node2D = null
var forced_target_valid := true
var forced_target_in_range := true
var forced_los_clear := true
var forced_move_direction := Vector2.RIGHT

var phase_context: StringName = &""
var cooldown_update_deltas: Array[float] = []
var windup_start_phases: Array[StringName] = []
var fire_start_phases: Array[StringName] = []
var movement_submission_count := 0
var action_log := PackedStringArray()
var fireball_attempt_count := 0
var fireball_records: Array[Dictionary] = []
var known_fireball_ids: Dictionary[int, bool] = {}
var last_glow_progress := 0.0
var los_query_count := 0


func reset_semantic_trace() -> void:
	phase_context = &""
	cooldown_update_deltas.clear()
	windup_start_phases.clear()
	fire_start_phases.clear()
	movement_submission_count = 0
	action_log.clear()
	action_sequence = 0
	fireball_attempt_count = 0
	fireball_records.clear()
	known_fireball_ids.clear()
	last_glow_progress = 0.0
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


func _try_start_windup(candidate_target: Node2D = null) -> bool:
	var started := super._try_start_windup(candidate_target)
	if started:
		windup_start_phases.append(phase_context)
	return started


func _start_fire(direction: Vector2) -> void:
	super._start_fire(direction)
	if combat_state == CombatState.FIRE:
		fire_start_phases.append(phase_context)


func _get_preferred_ranged_combat_target() -> Node2D:
	return forced_target


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
	# The test script authors every target/faction edge explicitly. Production
	# Mage still inherits Enemy's dynamic-target refresh unchanged.
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


func _fire_fireball() -> bool:
	fireball_attempt_count += 1
	var fired := super._fire_fireball()
	if not fired or combat_runtime == null or not is_instance_valid(combat_runtime):
		return fired
	for child in combat_runtime.get_children():
		var fireball := child as CapooMageFireball
		if fireball == null:
			continue
		var fireball_id := fireball.get_instance_id()
		if known_fireball_ids.has(fireball_id):
			continue
		known_fireball_ids[fireball_id] = true
		fireball.set_physics_process(false)
		var snapshot := fireball.damage_source_snapshot
		fireball_records.append({
			"direction_x": _quantize(fireball.direction.x),
			"direction_y": _quantize(fireball.direction.y),
			"damage": fireball.damage,
			"target_id": (
				int(fireball.target_player.get_meta(&"net_id", 0))
				if fireball.target_player != null
				and is_instance_valid(fireball.target_player)
				else 0
			),
			"source_faction": (
				snapshot.source_faction_id if snapshot != null else -1
			),
			"instigator_id": (
				snapshot.instigator_entity_id if snapshot != null else 0
			),
			"source_type": (
				String(snapshot.source_type) if snapshot != null else ""
			),
		})
	return fired


func _set_spell_glow(progress: float, direction: Vector2) -> void:
	last_glow_progress = clampf(progress, 0.0, 1.0)
	super._set_spell_glow(progress, direction)


func _quantize(value: float) -> int:
	return roundi(value * 1_000_000.0)
