extends SceneTree

const POLICY := preload(
	"res://scene/combat/simulation/enemy_simulation_policy.gd"
)
const RUNTIME_SCENE := preload(
	"res://dev_tools/fixtures/capoo_sniper_layered_semantic_runtime.tscn"
)
const SNIPER_CONFIG := preload(
	"res://resources/config/enemies/capoo_sniper.tres"
)
const STONE_SNIPER_CONFIG := preload(
	"res://resources/config/enemies/stone_eroded_capoo_sniper.tres"
)
const TARGET_CONFIG := preload(
	"res://resources/config/enemies/yuanshi_insect_basic.tres"
)
const LAYERED_RANGED_SCRIPT := preload(
	"res://scene/enemy/layered_ranged_enemy.gd"
)

const PHYSICS_DELTA := 1.0 / 60.0
const TEST_TICKS := 52
const FIXED_SEED := 20_260_824
const SOURCE_NET_ID := 78_001
const TARGET_A_NET_ID := 78_002
const TARGET_B_NET_ID := 78_003
const ROLLBACK_TICK := 43
const TEST_MODES: Array[int] = [
	POLICY.Mode.LEGACY,
	POLICY.Mode.COMPAT_60,
	POLICY.Mode.LAYERED_AREA,
	POLICY.Mode.LAYERED_CONTACT,
]
const GAMEPLAY_FIELDS: PackedStringArray = [
	"tick",
	"state",
	"position_x",
	"position_y",
	"velocity_x",
	"velocity_y",
	"cooldown",
	"lock_left",
	"locked_target",
	"objective",
	"locked_non_player",
	"locked_offset_x",
	"locked_offset_y",
	"held",
	"warning_line_live",
	"warning_reticle_live",
	"warning_position_x",
	"warning_position_y",
	"warning_progress",
	"warning_updates",
	"warning_clears",
	"animation",
	"source_faction",
	"lock_source_faction",
	"lock_instigator",
	"lock_event_source",
	"lock_source_type",
	"action_sequence",
	"action_log",
	"presentation_log",
	"damage_count",
	"last_damage",
	"last_damage_type",
	"last_damage_target",
	"last_damage_direction_x",
	"last_damage_direction_y",
	"last_damage_source_faction",
	"last_damage_instigator",
	"last_damage_event_source",
	"last_damage_source_type",
	"target_a_health",
	"target_b_health",
	"movement_submissions",
	"touch_updates",
	"cooldown_updates",
	"last_touch_delta",
	"last_cooldown_delta",
	"event_order",
	"los_queries",
	"behavior_rng",
	"drop_rng",
]

var failures: Array[String] = []
var completed_mode_count := 0


func _init() -> void:
	call_deferred(&"_run")


func _run() -> void:
	_verify_two_config_closure_and_capabilities()
	var runs: Dictionary = {}
	for simulation_mode in TEST_MODES:
		runs[simulation_mode] = await _run_mode(simulation_mode)
	_expect(
		completed_mode_count == TEST_MODES.size(),
		"Every Sniper policy coroutine must reach its completion sentinel."
	)
	_compare_mode_traces(runs)

	var result := {
		"status": "ok" if failures.is_empty() else "failed",
		"fixed_seed": FIXED_SEED,
		"ticks": TEST_TICKS,
		"modes": _mode_names(),
		"trace_digests": _trace_digests(runs),
		"checkpoints": _checkpoint_diagnostics(runs),
		"failures": failures.duplicate(),
	}
	print("CAPOO_SNIPER_LAYERED_SEMANTICS_JSON %s" % JSON.stringify(result))
	if failures.is_empty():
		print("CAPOO_SNIPER_LAYERED_SEMANTICS_REGRESSION_OK")
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	quit(1)


func _verify_two_config_closure_and_capabilities() -> void:
	for config in [SNIPER_CONFIG, STONE_SNIPER_CONFIG]:
		var sniper := config.enemy_scene.instantiate() as CapooSniper
		_expect(
			sniper != null,
			"%s must instantiate the shared CapooSniper runner."
			% config.resource_path
		)
		if sniper == null:
			continue
		var implementation := sniper.get_script() as Script
		_expect(
			implementation != null
			and implementation.get_base_script() == LAYERED_RANGED_SCRIPT,
			"%s must directly inherit LayeredRangedEnemy."
			% config.resource_path
		)
		_expect(
			sniper.supports_centralized_authoritative_simulation()
			and sniper.supports_layered_area_authoritative_simulation()
			and sniper.supports_layered_contact_authoritative_simulation()
			and sniper.supports_dynamic_enemy_targeting()
			and sniper.supports_indexed_touch_authority()
			and sniper.uses_layered_area_physics_phase_decisions()
			and sniper.uses_trusted_layered_phase_entrypoints()
			and not bool(sniper.call(&"_uses_inherited_touch_damage")),
			"%s must publish every explicit ranged capability without inherited touch damage."
			% config.resource_path
		)
		sniper.free()


func _run_mode(simulation_mode: int) -> Dictionary:
	var mode_name := POLICY.mode_to_name(simulation_mode)
	var runtime := RUNTIME_SCENE.instantiate() as EnemyGameplayGatewayTestRuntime
	runtime.runtime_mode = CombatRuntimeBase.RuntimeMode.SINGLEPLAYER
	var coordinator := runtime.get_node(
		"EnemySimulationCoordinator"
	) as EnemySimulationCoordinator
	coordinator.set_mode(simulation_mode)
	root.add_child(runtime)
	await process_frame

	var source: Variant = runtime.get_node("EnemyContainer/SniperSource")
	var target_a := runtime.get_node("EnemyContainer/TargetA") as Enemy
	var target_b := runtime.get_node("EnemyContainer/TargetB") as Enemy
	var source_config := SNIPER_CONFIG.duplicate(true) as CapooSniperConfig
	source_config.attack_range = 200.0
	source_config.lock_duration = PHYSICS_DELTA * 2.5
	source_config.attack_interval = PHYSICS_DELTA * 5.5
	source_config.drop_table = null
	source_config.xirang_kill_reward = 0
	var target_a_config := TARGET_CONFIG.duplicate(true) as EnemyConfig
	target_a_config.max_health = 2_000
	target_a_config.physical_defense = 0
	target_a_config.drop_table = null
	target_a_config.xirang_kill_reward = 0
	var target_b_config := TARGET_CONFIG.duplicate(true) as EnemyConfig
	target_b_config.max_health = 2_000
	target_b_config.physical_defense = 0
	target_b_config.drop_table = null
	target_b_config.xirang_kill_reward = 0

	source.set_meta(&"net_id", SOURCE_NET_ID)
	target_a.set_meta(&"net_id", TARGET_A_NET_ID)
	target_b.set_meta(&"net_id", TARGET_B_NET_ID)
	source.setup(source_config, null, null, runtime)
	target_a.setup(target_a_config, null, null, runtime)
	target_b.setup(target_b_config, null, null, runtime)
	runtime.register_network_enemy(SOURCE_NET_ID, source)
	runtime.register_network_enemy(TARGET_A_NET_ID, target_a)
	runtime.register_network_enemy(TARGET_B_NET_ID, target_b)
	source.set_combat_faction_id(
		CombatRelationService.HOSTILE_WAVE,
		1,
		true
	)
	target_a.set_combat_faction_id(
		CombatRelationService.PLAYER_ALLIED,
		1,
		true
	)
	target_b.set_combat_faction_id(
		CombatRelationService.HOSTILE_WAVE,
		1,
		true
	)
	target_a.set_authoritative_simulation_enabled(false)
	target_b.set_authoritative_simulation_enabled(false)
	source.forced_target = null
	source.set_objective_target(null)

	await physics_frame
	await physics_frame
	_disable_automatic_callbacks(coordinator, source, [target_a, target_b])
	await _advance_one_tick(coordinator, source, [target_a, target_b])
	_reset_source_after_bootstrap(source, source_config, target_a, target_b)

	_expect(
		source.supports_layered_area_authoritative_simulation()
		and source.supports_layered_contact_authoritative_simulation()
		and source.supports_indexed_touch_authority(),
		"%s Sniper harness must explicitly enter every layered gate."
		% mode_name
	)
	if simulation_mode == POLICY.Mode.LEGACY:
		_expect(
			not source.is_centrally_simulated(),
			"LEGACY must keep Sniper on the individual runner."
		)
	else:
		_expect(
			source.is_centrally_simulated()
			and coordinator.owns_enemy(source, source.enemy_simulation_token),
			"%s must own Sniper through the coordinator." % mode_name
		)
	if simulation_mode == POLICY.Mode.LAYERED_CONTACT:
		_expect(
			source.is_indexed_touch_authority_enabled()
			and not source.touch_damage_area.monitoring
			and not source.touch_damage_area.monitorable
			and _all_touch_shapes_disabled(source),
			"LAYERED_CONTACT must atomically replace Sniper TouchDamageArea."
		)
		var authored_areas: Array[Node] = source.find_children(
			"*",
			"Area2D",
			true,
			false
		)
		_expect(
			authored_areas.size() == 1
			and authored_areas[0] == source.touch_damage_area,
			"Sniper CONTACT admission must not hide a weapon Area."
		)
	else:
		_expect(
			not source.is_indexed_touch_authority_enabled(),
			"%s must retain authored Area contact authority." % mode_name
		)

	var context := {
		"coordinator": coordinator,
		"source": source,
		"target_a": target_a,
		"target_b": target_b,
		"simulation_mode": simulation_mode,
		"rollback_restored": simulation_mode == POLICY.Mode.LEGACY,
		"rollback_released_indexed": simulation_mode == POLICY.Mode.LEGACY,
		"rollback_preserved_state": simulation_mode == POLICY.Mode.LEGACY,
	}
	var snapshots: Array[Dictionary] = []
	for tick_index in range(1, TEST_TICKS + 1):
		_apply_pre_tick_script(tick_index, context)
		await _advance_one_tick(coordinator, source, [target_a, target_b])
		snapshots.append(
			_capture_snapshot(tick_index, source, target_a, target_b)
		)

	_validate_mode_invariants(mode_name, simulation_mode, snapshots, context)
	var run_result := {
		"mode": mode_name,
		"snapshots": snapshots,
		"trace_lines": _canonical_trace_lines(snapshots),
		"rollback_restored": context["rollback_restored"],
		"rollback_released_indexed": context["rollback_released_indexed"],
		"rollback_preserved_state": context["rollback_preserved_state"],
	}
	runtime.queue_free()
	await process_frame
	completed_mode_count += 1
	return run_result


func _reset_source_after_bootstrap(
	source: Variant,
	source_config: CapooSniperConfig,
	target_a: Enemy,
	target_b: Enemy
) -> void:
	source.global_position = Vector2.ZERO
	source.velocity = Vector2.ZERO
	target_a.global_position = Vector2(120.0, 0.0)
	target_b.global_position = Vector2(120.0, 0.0)
	target_a.is_dead = false
	target_b.is_dead = false
	target_a.current_health = 2_000
	target_b.current_health = 2_000
	source.combat_state = CapooSniper.CombatState.CHASE
	source.attack_cooldown_left = 0.0
	source.lock_time_left = 0.0
	source.locked_target = null
	source.locked_player = null
	source.locked_non_player_target = false
	source.locked_non_player_target_offset = Vector2.ZERO
	source.lock_damage_source_snapshot = null
	source.layered_sniper_event_consumes_tick = false
	source.layered_sniper_lock_ready_to_fire = false
	source.layered_sniper_pending_fire_direction = Vector2.ZERO
	source.forced_target = target_a
	source.forced_target_valid = true
	source.forced_los_clear = true
	source.forced_move_direction = Vector2.RIGHT
	source.call(&"_clear_lock_warning")
	source.call(&"_reset_ranged_attack_position_state")
	source.call(&"_play_config_animation", source_config.move_animation_name)
	source.reset_semantic_trace()
	source.random_generator.seed = FIXED_SEED
	source.material_drop_random_generator.seed = FIXED_SEED + 1
	source.set_objective_target(target_a)
	source.request_layered_area_urgent_decision()


func _apply_pre_tick_script(tick_index: int, context: Dictionary) -> void:
	var coordinator: EnemySimulationCoordinator = context["coordinator"]
	var source: Variant = context["source"]
	var target_a: Enemy = context["target_a"]
	var target_b: Enemy = context["target_b"]
	if tick_index == 2:
		target_a.global_position = Vector2(0.0, 120.0)
	elif tick_index == 11:
		target_a.global_position = Vector2(360.0, 0.0)
		source.request_layered_area_urgent_decision()
	elif tick_index == 12:
		target_a.global_position = Vector2(120.0, 0.0)
		source.request_layered_area_urgent_decision()
	elif tick_index == 14:
		source.forced_los_clear = false
	elif tick_index == 16:
		source.forced_los_clear = true
		source.request_layered_area_urgent_decision()
	elif tick_index == 17:
		target_a.set_combat_faction_id(
			CombatRelationService.HOSTILE_WAVE,
			2,
			true
		)
	elif tick_index == 18:
		target_a.set_combat_faction_id(
			CombatRelationService.PLAYER_ALLIED,
			3,
			true
		)
		source.request_layered_area_urgent_decision()
	elif tick_index == 19:
		target_a.is_dead = true
	elif tick_index == 20:
		target_a.is_dead = false
		source.set_combat_faction_id(
			CombatRelationService.HOSTILE_WAVE,
			4,
			true
		)
		source.request_layered_area_urgent_decision()
	elif tick_index == 21:
		# The committed lock retains HOSTILE_WAVE even though live relation flips.
		source.set_combat_faction_id(
			CombatRelationService.PLAYER_ALLIED,
			5,
			true
		)
	elif tick_index == 22:
		target_a.global_position = Vector2(-120.0, 0.0)
	elif tick_index == 24:
		source.forced_target = target_b
		source.set_objective_target(target_b)
		source.request_layered_area_urgent_decision()
	elif tick_index == 30:
		# The second committed snapshot is PLAYER_ALLIED; live HOSTILE must not
		# suppress its geometric LOS or direct damage at expiry.
		source.set_combat_faction_id(
			CombatRelationService.HOSTILE_WAVE,
			6,
			true
		)
	elif tick_index == 31:
		target_b.global_position = Vector2(0.0, -120.0)
	elif tick_index == 38:
		source.set_combat_faction_id(
			CombatRelationService.PLAYER_ALLIED,
			7,
			true
		)
		source.request_layered_area_urgent_decision()
	elif tick_index == 39:
		target_b.set_combat_faction_id(
			CombatRelationService.PLAYER_ALLIED,
			8,
			true
		)
	elif tick_index == 40:
		target_b.set_combat_faction_id(
			CombatRelationService.HOSTILE_WAVE,
			9,
			true
		)
		source.request_layered_area_urgent_decision()
	elif tick_index == 41:
		target_b.is_dead = true
	elif tick_index == 42:
		target_b.is_dead = false
		source.request_layered_area_urgent_decision()
	elif tick_index == ROLLBACK_TICK:
		var before_rollback := _capture_rollback_state(source)
		if int(context["simulation_mode"]) != POLICY.Mode.LEGACY:
			coordinator.set_mode(POLICY.Mode.LEGACY)
			context["rollback_restored"] = source.is_physics_processing()
			context["rollback_released_indexed"] = (
				not source.is_indexed_touch_authority_enabled()
			)
		else:
			context["rollback_restored"] = not source.is_centrally_simulated()
			context["rollback_released_indexed"] = (
				not source.is_indexed_touch_authority_enabled()
			)
		context["rollback_preserved_state"] = (
			_capture_rollback_state(source) == before_rollback
		)
		source.set_physics_process(false)
		coordinator.set_physics_process(false)


func _advance_one_tick(
	coordinator: EnemySimulationCoordinator,
	source: Variant,
	other_nodes: Array
) -> void:
	await physics_frame
	_disable_automatic_callbacks(coordinator, source, other_nodes)
	if source == null or not is_instance_valid(source) or source.is_dead:
		return
	if source.is_centrally_simulated():
		coordinator.call(&"_physics_process", PHYSICS_DELTA)
		coordinator.set_physics_process(false)
		return
	source.call(&"_run_authoritative_physics_step", PHYSICS_DELTA)
	source.set_physics_process(false)


func _disable_automatic_callbacks(
	coordinator: EnemySimulationCoordinator,
	source: Variant,
	other_nodes: Array
) -> void:
	coordinator.set_physics_process(false)
	if source != null and is_instance_valid(source):
		source.set_process(false)
		source.set_physics_process(false)
	for node_variant in other_nodes:
		if node_variant == null or not is_instance_valid(node_variant):
			continue
		var node := node_variant as Node
		node.set_process(false)
		node.set_physics_process(false)


func _capture_snapshot(
	tick_index: int,
	source: Variant,
	target_a: Enemy,
	target_b: Enemy
) -> Dictionary:
	var lock_snapshot := source.lock_damage_source_snapshot as DamageSourceSnapshot
	var last_damage: Dictionary = (
		source.damage_records[-1]
		if not source.damage_records.is_empty()
		else {}
	)
	return {
		"tick": tick_index,
		"state": source.combat_state,
		"position_x": _quantize(source.global_position.x),
		"position_y": _quantize(source.global_position.y),
		"velocity_x": _quantize(source.velocity.x),
		"velocity_y": _quantize(source.velocity.y),
		"cooldown": _quantize(source.attack_cooldown_left),
		"lock_left": _quantize(source.lock_time_left),
		"locked_target": _target_label(source.locked_target, target_a, target_b),
		"objective": _target_label(source.objective_target, target_a, target_b),
		"locked_non_player": 1 if source.locked_non_player_target else 0,
		"locked_offset_x": _quantize(source.locked_non_player_target_offset.x),
		"locked_offset_y": _quantize(source.locked_non_player_target_offset.y),
		"held": 1 if bool(source.get("_ranged_attack_position_held")) else 0,
		"warning_line_live": 1 if source.sniper_line_warning_handle > 0 else 0,
		"warning_reticle_live": 1 if source.sniper_reticle_warning_handle > 0 else 0,
		"warning_position_x": _quantize(source.last_warning_position.x),
		"warning_position_y": _quantize(source.last_warning_position.y),
		"warning_progress": _quantize(source.last_warning_progress),
		"warning_updates": source.warning_update_count,
		"warning_clears": source.warning_clear_count,
		"animation": String(source.animated_sprite.animation),
		"source_faction": source.get_combat_faction_id(),
		"lock_source_faction": (
			lock_snapshot.source_faction_id if lock_snapshot != null else -1
		),
		"lock_instigator": (
			lock_snapshot.instigator_entity_id if lock_snapshot != null else 0
		),
		"lock_event_source": (
			lock_snapshot.event_source_id if lock_snapshot != null else 0
		),
		"lock_source_type": (
			String(lock_snapshot.source_type) if lock_snapshot != null else ""
		),
		"action_sequence": source.action_sequence,
		"action_log": "|".join(source.action_log),
		"presentation_log": "|".join(source.presentation_log),
		"damage_count": source.damage_records.size(),
		"last_damage": int(last_damage.get("damage", 0)),
		"last_damage_type": int(last_damage.get("damage_type", -1)),
		"last_damage_target": int(last_damage.get("target_id", 0)),
		"last_damage_direction_x": int(last_damage.get("direction_x", 0)),
		"last_damage_direction_y": int(last_damage.get("direction_y", 0)),
		"last_damage_source_faction": int(last_damage.get("source_faction", -1)),
		"last_damage_instigator": int(last_damage.get("instigator_id", 0)),
		"last_damage_event_source": int(last_damage.get("event_source_id", 0)),
		"last_damage_source_type": String(last_damage.get("source_type", "")),
		"target_a_health": target_a.current_health,
		"target_b_health": target_b.current_health,
		"movement_submissions": source.movement_submission_count,
		"touch_updates": source.touch_update_deltas.size(),
		"cooldown_updates": source.cooldown_update_deltas.size(),
		"last_touch_delta": (
			_quantize(source.touch_update_deltas[-1])
			if not source.touch_update_deltas.is_empty()
			else 0
		),
		"last_cooldown_delta": (
			_quantize(source.cooldown_update_deltas[-1])
			if not source.cooldown_update_deltas.is_empty()
			else 0
		),
		"event_order": "|".join(source.event_order_log),
		"los_queries": source.los_query_count,
		"behavior_rng": source.random_generator.state,
		"drop_rng": source.material_drop_random_generator.state,
		"central_owned": 1 if source.is_centrally_simulated() else 0,
		"indexed_touch": 1 if source.is_indexed_touch_authority_enabled() else 0,
		"touch_area_monitoring": 1 if source.touch_damage_area.monitoring else 0,
	}


func _capture_rollback_state(source: Variant) -> Dictionary:
	var snapshot := source.lock_damage_source_snapshot as DamageSourceSnapshot
	return {
		"state": source.combat_state,
		"cooldown": source.attack_cooldown_left,
		"lock_left": source.lock_time_left,
		"target": source.locked_target,
		"offset": source.locked_non_player_target_offset,
		"source_faction": (
			snapshot.source_faction_id if snapshot != null else -1
		),
		"instigator": (
			snapshot.instigator_entity_id if snapshot != null else 0
		),
		"event_source": (
			snapshot.event_source_id if snapshot != null else 0
		),
		"source_type": (
			String(snapshot.source_type) if snapshot != null else ""
		),
		"action_sequence": source.action_sequence,
		"rng": source.random_generator.state,
		"warning_position": source.last_warning_position,
		"warning_progress": source.last_warning_progress,
		"pending_direction": source.layered_sniper_pending_fire_direction,
	}


func _validate_mode_invariants(
	mode_name: String,
	simulation_mode: int,
	snapshots: Array[Dictionary],
	context: Dictionary
) -> void:
	if snapshots.size() != TEST_TICKS:
		failures.append("%s must capture every Sniper tick." % mode_name)
		return
	_expect_state(snapshots, 1, CapooSniper.CombatState.LOCK, mode_name)
	_expect(
		int(snapshots[0]["warning_line_live"]) == 1
		and int(snapshots[0]["warning_reticle_live"]) == 1
		and int(snapshots[1]["warning_position_y"]) > 0
		and int(snapshots[1]["locked_offset_y"]) > 0,
		"%s LOCK warning and non-player offset must follow target movement."
		% mode_name
	)
	_expect_state(snapshots, 4, CapooSniper.CombatState.CHASE, mode_name)
	_expect(
		int(snapshots[3]["damage_count"]) == 1
		and int(snapshots[3]["action_sequence"]) == 2
		and int(snapshots[3]["warning_line_live"]) == 0
		and int(snapshots[3]["warning_reticle_live"]) == 0,
		"%s first lock must fire once after three exact countdown ticks."
		% mode_name
	)
	var held_position_x := int(snapshots[3]["position_x"])
	for tick_number in range(5, 10):
		var held_snapshot: Dictionary = snapshots[tick_number - 1]
		_expect(
			int(held_snapshot["held"]) == 1
			and int(held_snapshot["position_x"]) == held_position_x,
			"%s cooldown hold must suppress motion on tick %d."
			% [mode_name, tick_number]
		)
	_expect_state(snapshots, 10, CapooSniper.CombatState.LOCK, mode_name)
	_expect_state(snapshots, 11, CapooSniper.CombatState.CHASE, mode_name)
	_expect(
		int(snapshots[10]["movement_submissions"])
		== int(snapshots[9]["movement_submissions"]),
		"%s out-of-range cancellation must consume the complete lock tick."
		% mode_name
	)
	_expect_state(snapshots, 15, CapooSniper.CombatState.CHASE, mode_name)
	_expect(
		int(snapshots[14]["damage_count"]) == 1,
		"%s blocked expiry LOS must cancel without direct damage."
		% mode_name
	)
	_expect_state(snapshots, 17, CapooSniper.CombatState.CHASE, mode_name)
	_expect_state(snapshots, 19, CapooSniper.CombatState.CHASE, mode_name)
	_expect(
		int(snapshots[18]["damage_count"]) == 1,
		"%s friendly and dead Enemy targets must cancel committed locks."
		% mode_name
	)
	_expect_state(snapshots, 23, CapooSniper.CombatState.CHASE, mode_name)
	_expect(
		int(snapshots[22]["damage_count"]) == 2
		and int(snapshots[22]["last_damage_source_faction"])
		== CombatRelationService.HOSTILE_WAVE
		and int(snapshots[22]["source_faction"])
		== CombatRelationService.PLAYER_ALLIED,
		"%s first faction flip must retain the committed HOSTILE snapshot."
		% mode_name
	)
	_expect_state(snapshots, 32, CapooSniper.CombatState.CHASE, mode_name)
	_expect(
		int(snapshots[31]["damage_count"]) == 3
		and int(snapshots[31]["last_damage_source_faction"])
		== CombatRelationService.PLAYER_ALLIED
		and int(snapshots[31]["source_faction"])
		== CombatRelationService.HOSTILE_WAVE,
		"%s second faction flip must retain the committed PLAYER_ALLIED snapshot."
		% mode_name
	)
	_expect_state(snapshots, 39, CapooSniper.CombatState.CHASE, mode_name)
	_expect_state(snapshots, 41, CapooSniper.CombatState.CHASE, mode_name)
	_expect_state(snapshots, 42, CapooSniper.CombatState.LOCK, mode_name)
	_expect_state(snapshots, 45, CapooSniper.CombatState.CHASE, mode_name)
	_expect_state(snapshots, 51, CapooSniper.CombatState.LOCK, mode_name)
	var final_snapshot: Dictionary = snapshots[TEST_TICKS - 1]
	_expect(
		int(final_snapshot["warning_line_live"]) == 1
		and int(final_snapshot["warning_reticle_live"]) == 1
		and int(final_snapshot["damage_count"]) == 4
		and int(final_snapshot["target_a_health"])
		== 2_000 - SNIPER_CONFIG.attack_damage * 2
		and int(final_snapshot["target_b_health"])
		== 2_000 - SNIPER_CONFIG.attack_damage * 2,
		"%s dynamic Enemy shots must apply exactly four authored damage requests."
		% mode_name
	)
	_expect(
		int(snapshots[3]["last_damage_direction_x"]) == 0
		and int(snapshots[3]["last_damage_direction_y"]) == 1_000_000
		and int(snapshots[22]["last_damage_direction_x"]) == -1_000_000
		and int(snapshots[22]["last_damage_direction_y"]) == 0
		and int(snapshots[31]["last_damage_direction_x"]) == 0
		and int(snapshots[31]["last_damage_direction_y"]) == -1_000_000,
		"%s moving-target directions must freeze at the event/decision boundary."
		% mode_name
	)
	_expect(
		int(final_snapshot["last_damage"])
		== SNIPER_CONFIG.attack_damage
		and int(final_snapshot["last_damage_type"])
		== EnemyConfig.DamageType.PHYSICAL
		and int(final_snapshot["last_damage_target"]) == TARGET_B_NET_ID
		and int(final_snapshot["last_damage_source_faction"])
		== CombatRelationService.PLAYER_ALLIED
		and int(final_snapshot["last_damage_instigator"]) == SOURCE_NET_ID
		and int(final_snapshot["last_damage_event_source"])
		== SOURCE_NET_ID * 1_000_000 + 19
		and String(final_snapshot["last_damage_source_type"])
		== "capoo_sniper_lock",
		"%s direct shot must retain explicit frozen faction/type/instigator/event identity."
		% mode_name
	)
	var expected_actions := (
		"1:sniper_lock_start:78002|2:sniper_lock_fire:78002|"
		+ "3:sniper_lock_start:78002|4:sniper_lock_cancel:78002|"
		+ "5:sniper_lock_start:78002|6:sniper_lock_cancel:78002|"
		+ "7:sniper_lock_start:78002|8:sniper_lock_cancel:78002|"
		+ "9:sniper_lock_start:78002|10:sniper_lock_cancel:78002|"
		+ "11:sniper_lock_start:78002|12:sniper_lock_fire:78002|"
		+ "13:sniper_lock_start:78003|14:sniper_lock_fire:78003|"
		+ "15:sniper_lock_start:78003|16:sniper_lock_cancel:78003|"
		+ "17:sniper_lock_start:78003|18:sniper_lock_cancel:78003|"
		+ "19:sniper_lock_start:78003|20:sniper_lock_fire:78003|"
		+ "21:sniper_lock_start:78003"
	)
	_expect(
		int(final_snapshot["action_sequence"]) == 21
		and String(final_snapshot["action_log"]) == expected_actions
		and source_presentation_pair_count(final_snapshot) == 21,
		"%s lock/cancel/fire multiplayer actions must retain exact target sequence."
		% mode_name
	)
	_expect(
		bool(context["rollback_restored"])
		and bool(context["rollback_released_indexed"])
		and bool(context["rollback_preserved_state"]),
		"%s active-lock rollback must preserve Sniper state/snapshot/action/warning."
		% mode_name
	)
	_expect(
		int(snapshots[ROLLBACK_TICK - 2]["central_owned"])
		== (0 if simulation_mode == POLICY.Mode.LEGACY else 1)
		and int(snapshots[ROLLBACK_TICK - 1]["central_owned"]) == 0,
		"%s rollback must transfer ownership exactly at tick %d."
		% [mode_name, ROLLBACK_TICK]
	)
	if simulation_mode == POLICY.Mode.LAYERED_CONTACT:
		_expect(
			int(snapshots[ROLLBACK_TICK - 2]["indexed_touch"]) == 1
			and int(snapshots[ROLLBACK_TICK - 1]["indexed_touch"]) == 0
			and int(snapshots[ROLLBACK_TICK - 1]["touch_area_monitoring"]) == 1,
			"CONTACT rollback must restore authored TouchDamageArea atomically."
		)
	var source: Variant = context["source"]
	if simulation_mode in [POLICY.Mode.LAYERED_AREA, POLICY.Mode.LAYERED_CONTACT]:
		_expect(
			source.lock_start_phases.size() == 11
			and _phase_prefix_matches(source.lock_start_phases, 10, &"decision")
			and StringName(source.lock_start_phases[-1]) == &"legacy"
			and source.fire_commit_phases.size() == 4
			and _phase_prefix_matches(source.fire_commit_phases, 3, &"decision")
			and StringName(source.fire_commit_phases[-1]) == &"legacy",
			"%s commits must use decision before rollback and legacy afterward."
			% mode_name
		)
	else:
		_expect(
			_all_phases_equal(source.lock_start_phases, &"legacy")
			and _all_phases_equal(source.fire_commit_phases, &"legacy"),
			"%s commits must remain in the authored runner." % mode_name
		)
	_expect(
		source.touch_update_deltas.size() == TEST_TICKS
		and source.cooldown_update_deltas.size() == TEST_TICKS
		and _all_deltas_equal(source.touch_update_deltas, PHYSICS_DELTA)
		and _all_deltas_equal(source.cooldown_update_deltas, PHYSICS_DELTA)
		and _event_order_is_touch_then_cooldown(source.event_order_log),
		"%s event clocks must retain exact touch -> cooldown -> optional LOCK order."
		% mode_name
	)


func source_presentation_pair_count(snapshot: Dictionary) -> int:
	var encoded := String(snapshot.get("presentation_log", ""))
	return 0 if encoded.is_empty() else encoded.split("|").size()


func _compare_mode_traces(runs: Dictionary) -> void:
	var legacy_run: Dictionary = runs.get(POLICY.Mode.LEGACY, {})
	var legacy_snapshots: Array = legacy_run.get("snapshots", [])
	for comparison_mode in [
		POLICY.Mode.COMPAT_60,
		POLICY.Mode.LAYERED_AREA,
		POLICY.Mode.LAYERED_CONTACT,
	]:
		var mode_name := POLICY.mode_to_name(comparison_mode)
		var comparison_run: Dictionary = runs.get(comparison_mode, {})
		var comparison_snapshots: Array = comparison_run.get("snapshots", [])
		if comparison_snapshots.size() != legacy_snapshots.size():
			failures.append("%s trace length differs from LEGACY." % mode_name)
			continue
		var mismatch_count := 0
		for tick_index in range(legacy_snapshots.size()):
			var legacy_snapshot: Dictionary = legacy_snapshots[tick_index]
			var comparison_snapshot: Dictionary = comparison_snapshots[tick_index]
			for field_name in GAMEPLAY_FIELDS:
				if legacy_snapshot.get(field_name) == comparison_snapshot.get(field_name):
					continue
				failures.append(
					"%s diverged from LEGACY at tick %d field %s: legacy=%s comparison=%s"
					% [
						mode_name,
						tick_index + 1,
						field_name,
						str(legacy_snapshot.get(field_name)),
						str(comparison_snapshot.get(field_name)),
					]
				)
				mismatch_count += 1
				if mismatch_count >= 10:
					break
			if mismatch_count >= 10:
				break


func _expect_state(
	snapshots: Array[Dictionary],
	tick_number: int,
	expected_state: int,
	mode_name: String
) -> void:
	_expect(
		int(snapshots[tick_number - 1]["state"]) == expected_state,
		"%s tick %d must be state %d (got %s)."
		% [
			mode_name,
			tick_number,
			expected_state,
			str(snapshots[tick_number - 1]["state"]),
		]
	)


func _target_label(target: Node2D, target_a: Enemy, target_b: Enemy) -> String:
	if target == target_a:
		return "target_a"
	if target == target_b:
		return "target_b"
	return "none"


func _all_touch_shapes_disabled(source: Variant) -> bool:
	for shape_variant in source.touch_damage_shapes:
		var shape := shape_variant as CollisionShape2D
		if shape != null and not shape.disabled:
			return false
	return true


func _all_phases_equal(phases: Array, expected_phase: StringName) -> bool:
	for phase_variant in phases:
		if StringName(phase_variant) != expected_phase:
			return false
	return true


func _phase_prefix_matches(
	phases: Array,
	prefix_size: int,
	expected_phase: StringName
) -> bool:
	if phases.size() < prefix_size:
		return false
	for phase_index in range(prefix_size):
		if StringName(phases[phase_index]) != expected_phase:
			return false
	return true


func _all_deltas_equal(deltas: Array, expected_delta: float) -> bool:
	for delta_variant in deltas:
		if not is_equal_approx(float(delta_variant), expected_delta):
			return false
	return true


func _event_order_is_touch_then_cooldown(order: PackedStringArray) -> bool:
	var index := 0
	while index < order.size():
		if order[index] != "touch":
			return false
		index += 1
		if index >= order.size() or order[index] != "cooldown":
			return false
		index += 1
		if index < order.size() and order[index] == "lock":
			index += 1
	return true


func _canonical_trace_lines(snapshots: Array[Dictionary]) -> PackedStringArray:
	var result := PackedStringArray()
	for snapshot in snapshots:
		var gameplay_snapshot := {}
		for field_name in GAMEPLAY_FIELDS:
			gameplay_snapshot[field_name] = snapshot.get(field_name)
		result.append(JSON.stringify(gameplay_snapshot))
	return result


func _trace_digests(runs: Dictionary) -> Dictionary:
	var result := {}
	for simulation_mode in TEST_MODES:
		var run: Dictionary = runs.get(simulation_mode, {})
		var lines: PackedStringArray = run.get("trace_lines", PackedStringArray())
		result[POLICY.mode_to_name(simulation_mode)] = "\n".join(lines).sha256_text()
	return result


func _checkpoint_diagnostics(runs: Dictionary) -> Dictionary:
	var result := {}
	for simulation_mode in TEST_MODES:
		var run: Dictionary = runs.get(simulation_mode, {})
		var snapshots: Array = run.get("snapshots", [])
		var checkpoints := {}
		for tick_number in [1, 4, 10, 11, 15, 17, 19, 23, 32, 39, 41, 42, 43, 45, 51]:
			checkpoints[str(tick_number)] = (
				snapshots[tick_number - 1].duplicate(true)
				if snapshots.size() >= tick_number
				else {}
			)
		result[POLICY.mode_to_name(simulation_mode)] = checkpoints
	return result


func _mode_names() -> PackedStringArray:
	var result := PackedStringArray()
	for simulation_mode in TEST_MODES:
		result.append(POLICY.mode_to_name(simulation_mode))
	return result


func _quantize(value: float) -> int:
	return roundi(value * 1_000_000.0)


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
