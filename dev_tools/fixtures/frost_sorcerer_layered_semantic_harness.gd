extends FrostSorcerer
class_name FrostSorcererLayeredSemanticHarness

## The authored Frost scene, preview and real ice-spike remain intact. This
## fixture replaces only world-dependent target/range/LOS/navigation answers so
## every simulation policy replays the same deterministic script.

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
var spike_attempt_count := 0
var spike_records: Array[Dictionary] = []
var spawned_spikes: Array[FrostSorcererIceSpike] = []
var known_spike_ids: Dictionary[int, bool] = {}
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
	spike_attempt_count = 0
	spike_records.clear()
	spawned_spikes.clear()
	known_spike_ids.clear()
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
	frost_config: FrostSorcererConfig
) -> bool:
	var started := super._try_start_summon(attack_target, frost_config)
	if started:
		summon_start_phases.append(phase_context)
	return started


func _finish_summon_and_fire(frost_config: FrostSorcererConfig) -> void:
	fire_resolve_phases.append(phase_context)
	super._finish_summon_and_fire(frost_config)


func _cancel_summon(restore_move_animation := true) -> void:
	if combat_state == CombatState.SUMMON:
		cancel_phases.append(phase_context)
	super._cancel_summon(restore_move_animation)


func _select_nearest_attack_target(
	fallback_target: Node2D,
	_frost_config: FrostSorcererConfig,
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
	# The regression authors every target/faction edge explicitly. Production
	# Frost still inherits Enemy's dynamic-target refresh unchanged.
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


func _spawn_ice_spike(frost_config: FrostSorcererConfig) -> bool:
	spike_attempt_count += 1
	var target_at_launch := summon_target
	var spawned := super._spawn_ice_spike(frost_config)
	if not spawned or combat_runtime == null or not is_instance_valid(combat_runtime):
		return spawned
	for child in combat_runtime.get_children():
		var spike := child as FrostSorcererIceSpike
		if spike == null:
			continue
		var spike_id := spike.get_instance_id()
		if known_spike_ids.has(spike_id):
			continue
		known_spike_ids[spike_id] = true
		spawned_spikes.append(spike)
		spike.set_physics_process(false)
		var snapshot := spike.damage_source_snapshot
		spike_records.append({
			"position_x": _quantize(spike.global_position.x),
			"position_y": _quantize(spike.global_position.y),
			"direction_x": _quantize(spike.direction.x),
			"direction_y": _quantize(spike.direction.y),
			"damage": spike.damage,
			"speed": _quantize(spike.speed),
			"lifetime": _quantize(spike.remaining_lifetime),
			"target_id": (
				int(target_at_launch.get_meta(&"net_id", 0))
				if target_at_launch != null
				and is_instance_valid(target_at_launch)
				else 0
			),
			"source_faction": (
				snapshot.source_faction_id if snapshot != null else -1
			),
			"credit_peer_id": (
				snapshot.credit_peer_id if snapshot != null else 0
			),
			"instigator_id": (
				snapshot.instigator_entity_id if snapshot != null else 0
			),
			"event_source_id": (
				snapshot.event_source_id if snapshot != null else 0
			),
			"source_type": (
				String(snapshot.source_type) if snapshot != null else ""
			),
		})
	return spawned


func _quantize(value: float) -> int:
	return roundi(value * 1_000_000.0)
