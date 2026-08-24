extends CapooRPG
class_name CapooRPGLayeredSemanticHarness

## Preserve the authored RPG state machine and data-rocket service. Only the
## world-dependent target, LOS, navigation and body-motion answers are scripted
## so every simulation policy receives the same deterministic inputs.

const FIXED_PHYSICS_DELTA := 1.0 / 60.0
const ROCKET_SERVICE := preload(
	"res://scene/combat/simulation/capoo_rpg_rocket_simulation_service.gd"
)

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
var rocket_attempt_count := 0
var rocket_records: Array[Dictionary] = []
var last_muzzle_heat_progress := 0.0
var los_query_count := 0


func reset_semantic_trace() -> void:
	phase_context = &""
	cooldown_update_deltas.clear()
	windup_start_phases.clear()
	fire_start_phases.clear()
	movement_submission_count = 0
	action_log.clear()
	action_sequence = 0
	rocket_attempt_count = 0
	rocket_records.clear()
	last_muzzle_heat_progress = 0.0
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


func _has_clear_world_line_to_rpg_target(target: Node2D) -> bool:
	los_query_count += 1
	return forced_los_clear and _is_ranged_combat_target_valid(target)


func refresh_dynamic_combat_target_decision(_simulation_tick: int) -> void:
	# The regression scripts every target/faction edge. Production RPG retains
	# Enemy's descriptor-based dynamic target refresh without this fixture hook.
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


func _fire_rocket() -> bool:
	rocket_attempt_count += 1
	var rocket_service := _get_capoo_rpg_rocket_simulation_service()
	var record_count_before := (
		rocket_service.get_dense_record_count()
		if rocket_service != null
		else 0
	)
	var committed_target_id := (
		int(committed_attack_target.get_meta(&"net_id", 0))
		if committed_attack_target != null
		and is_instance_valid(committed_attack_target)
		else 0
	)
	var fired := super._fire_rocket()
	if not fired or rocket_service == null:
		return fired
	for stable_index in range(
		record_count_before,
		rocket_service.get_dense_record_count()
	):
		var handle := rocket_service.get_handle_at_stable_index(stable_index)
		if handle <= ROCKET_SERVICE.INVALID_HANDLE:
			continue
		var snapshot := rocket_service.get_damage_source_snapshot(handle)
		var spawn_position := rocket_service.get_position(handle)
		var direction := rocket_service.get_direction_at_stable_index(stable_index)
		rocket_records.append({
			"spawn_x": _quantize(spawn_position.x),
			"spawn_y": _quantize(spawn_position.y),
			"direction_x": _quantize(direction.x),
			"direction_y": _quantize(direction.y),
			"remaining_lifetime": _quantize(
				rocket_service.get_remaining_lifetime(handle)
			),
			"target_id": committed_target_id,
			"source_faction": (
				snapshot.source_faction_id if snapshot != null else -1
			),
			"credit_peer_id": (
				snapshot.credit_peer_id if snapshot != null else 0
			),
			"instigator_id": (
				snapshot.instigator_entity_id if snapshot != null else 0
			),
			"source_type": (
				String(snapshot.source_type) if snapshot != null else ""
			),
		})
	return fired


func _set_muzzle_heat(progress: float, direction: Vector2) -> void:
	last_muzzle_heat_progress = clampf(progress, 0.0, 1.0)
	super._set_muzzle_heat(progress, direction)


func _quantize(value: float) -> int:
	return roundi(value * 1_000_000.0)
