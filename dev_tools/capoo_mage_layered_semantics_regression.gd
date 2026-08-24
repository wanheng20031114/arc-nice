extends SceneTree

const POLICY := preload(
	"res://scene/combat/simulation/enemy_simulation_policy.gd"
)
const RUNTIME_SCENE := preload(
	"res://dev_tools/fixtures/capoo_mage_layered_semantic_runtime.tscn"
)
const MAGE_CONFIG := preload(
	"res://resources/config/enemies/capoo_mage.tres"
)
const STONE_MAGE_CONFIG := preload(
	"res://resources/config/enemies/stone_eroded_capoo_mage.tres"
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
const SOURCE_NET_ID := 74_001
const TARGET_A_NET_ID := 74_002
const TARGET_B_NET_ID := 74_003
const ROLLBACK_TICK := 40
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
	"windup_left",
	"fire_left",
	"fire_direction_x",
	"fire_direction_y",
	"attack_target",
	"objective",
	"held",
	"glow_progress",
	"glow_visible",
	"glow_position_x",
	"glow_position_y",
	"glow_rotation",
	"glow_scale",
	"glow_alpha",
	"animation",
	"source_faction",
	"action_sequence",
	"action_log",
	"fireball_attempts",
	"fireball_count",
	"last_fireball_direction_x",
	"last_fireball_direction_y",
	"last_fireball_damage",
	"last_fireball_target",
	"last_fireball_source_faction",
	"last_fireball_instigator",
	"last_fireball_source_type",
	"movement_submissions",
	"cooldown_updates",
	"last_cooldown_delta",
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
		"Every Mage policy coroutine must reach its completion sentinel."
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
	print("CAPOO_MAGE_LAYERED_SEMANTICS_JSON %s" % JSON.stringify(result))
	if failures.is_empty():
		print("CAPOO_MAGE_LAYERED_SEMANTICS_REGRESSION_OK")
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	quit(1)


func _verify_two_config_closure_and_capabilities() -> void:
	for config in [MAGE_CONFIG, STONE_MAGE_CONFIG]:
		var mage := config.enemy_scene.instantiate() as CapooMage
		_expect(
			mage != null,
			"%s must instantiate the shared CapooMage runner."
			% config.resource_path
		)
		if mage == null:
			continue
		var script := mage.get_script() as Script
		_expect(
			script.get_base_script() == LAYERED_RANGED_SCRIPT,
			"%s must directly inherit LayeredRangedEnemy."
			% config.resource_path
		)
		_expect(
			mage.supports_centralized_authoritative_simulation()
			and mage.supports_layered_area_authoritative_simulation()
			and mage.supports_layered_contact_authoritative_simulation()
			and mage.supports_dynamic_enemy_targeting()
			and mage.supports_indexed_touch_authority()
			and not bool(mage.call(&"_uses_inherited_touch_damage")),
			"%s must publish centralized/layered/dynamic/indexed ranged capability without inherited touch damage."
			% config.resource_path
		)
		mage.free()


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

	var source: Variant = runtime.get_node("EnemyContainer/MageSource")
	var target_a := runtime.get_node("EnemyContainer/TargetA") as Enemy
	var target_b := runtime.get_node("EnemyContainer/TargetB") as Enemy
	var source_config := MAGE_CONFIG.duplicate(true) as CapooMageConfig
	source_config.attack_windup = PHYSICS_DELTA * 2.5
	source_config.attack_interval = PHYSICS_DELTA * 18.5
	source_config.drop_table = null
	source_config.xirang_kill_reward = 0
	var target_a_config := TARGET_CONFIG.duplicate(true) as EnemyConfig
	target_a_config.drop_table = null
	target_a_config.xirang_kill_reward = 0
	var target_b_config := TARGET_CONFIG.duplicate(true) as EnemyConfig
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
	target_a.set_combat_faction_id(
		CombatRelationService.PLAYER_ALLIED,
		1,
		true
	)
	target_b.set_combat_faction_id(
		CombatRelationService.PLAYER_ALLIED,
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
	_reset_source_after_bootstrap(source, source_config, target_a)

	_expect(
		source.supports_layered_area_authoritative_simulation()
		and source.supports_layered_contact_authoritative_simulation()
		and source.supports_indexed_touch_authority(),
		"%s Mage must retain explicit layered/indexed opt-in." % mode_name
	)
	if simulation_mode == POLICY.Mode.LEGACY:
		_expect(
			not source.is_centrally_simulated(),
			"LEGACY must keep Mage on the individual runner."
		)
	else:
		_expect(
			source.is_centrally_simulated()
			and coordinator.owns_enemy(source, source.enemy_simulation_token),
			"%s must own Mage through the coordinator." % mode_name
		)
	if simulation_mode == POLICY.Mode.LAYERED_CONTACT:
		_expect(
			source.is_indexed_touch_authority_enabled()
			and not source.touch_damage_area.monitoring
			and not source.touch_damage_area.monitorable
			and _all_touch_shapes_disabled(source),
			"LAYERED_CONTACT must replace Mage TouchDamageArea with indexed contact."
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
			"Mage must not lose a separate attack Area when CONTACT closes TouchDamageArea."
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
	source_config: CapooMageConfig,
	target_a: Enemy
) -> void:
	source.global_position = Vector2.ZERO
	source.velocity = Vector2.ZERO
	source.combat_state = CapooMage.CombatState.CHASE
	source.attack_cooldown_left = 0.0
	source.windup_time_left = 0.0
	source.fire_time_left = 0.0
	source.fire_direction = Vector2.RIGHT
	source.attack_target = null
	source.layered_mage_event_consumes_tick = false
	source.layered_mage_windup_ready_to_fire = false
	source.forced_target = target_a
	source.forced_target_valid = true
	source.forced_target_in_range = true
	source.forced_los_clear = true
	source.forced_move_direction = Vector2.RIGHT
	source.call(&"_reset_ranged_attack_position_state")
	source.call(&"_play_config_animation", source_config.move_animation_name)
	source.call(&"_set_spell_glow", 0.0, Vector2.RIGHT)
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
	elif tick_index == 24:
		source.forced_target_in_range = false
		source.request_layered_area_urgent_decision()
	elif tick_index == 26:
		source.forced_target_in_range = true
		source.request_layered_area_urgent_decision()
	elif tick_index == 29:
		source.forced_los_clear = false
		source.request_layered_area_urgent_decision()
	elif tick_index == 31:
		source.forced_los_clear = true
		source.request_layered_area_urgent_decision()
	elif tick_index == 32:
		target_a.set_combat_faction_id(
			CombatRelationService.HOSTILE_WAVE,
			2,
			true
		)
		source.request_layered_area_urgent_decision()
	elif tick_index == 34:
		target_a.set_combat_faction_id(
			CombatRelationService.PLAYER_ALLIED,
			3,
			true
		)
		source.request_layered_area_urgent_decision()
	elif tick_index == 35:
		target_a.is_dead = true
		source.request_layered_area_urgent_decision()
	elif tick_index == 36:
		source.set_combat_faction_id(
			CombatRelationService.PLAYER_ALLIED,
			1,
			true
		)
		target_b.set_combat_faction_id(
			CombatRelationService.HOSTILE_WAVE,
			2,
			true
		)
		source.forced_target = target_b
		source.set_objective_target(target_b)
		source.request_layered_area_urgent_decision()
	elif tick_index == 37:
		target_b.global_position = Vector2(-120.0, 0.0)
	elif tick_index == ROLLBACK_TICK:
		var before_rollback := _capture_rollback_state(source)
		if int(context["simulation_mode"]) != POLICY.Mode.LEGACY:
			coordinator.set_mode(POLICY.Mode.LEGACY)
			context["rollback_restored"] = source.is_physics_processing()
			context["rollback_released_indexed"] = (
				not source.is_indexed_touch_authority_enabled()
			)
		else:
			# LEGACY is the semantic baseline, not a coordinator handoff. Its
			# individual callback is deliberately disabled by this manual clock.
			context["rollback_restored"] = not source.is_centrally_simulated()
			context["rollback_released_indexed"] = (
				not source.is_indexed_touch_authority_enabled()
			)
		context["rollback_preserved_state"] = (
			_capture_rollback_state(source) == before_rollback
		)
		source.set_physics_process(false)
		coordinator.set_physics_process(false)
	elif tick_index == 51:
		target_b.set_combat_faction_id(
			CombatRelationService.PLAYER_ALLIED,
			3,
			true
		)
		source.request_layered_area_urgent_decision()


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
	var last_fireball: Dictionary = (
		source.fireball_records[-1]
		if not source.fireball_records.is_empty()
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
		"windup_left": _quantize(source.windup_time_left),
		"fire_left": _quantize(source.fire_time_left),
		"fire_direction_x": _quantize(source.fire_direction.x),
		"fire_direction_y": _quantize(source.fire_direction.y),
		"attack_target": _target_label(source.attack_target, target_a, target_b),
		"objective": _target_label(source.objective_target, target_a, target_b),
		"held": 1 if bool(source.get("_ranged_attack_position_held")) else 0,
		"glow_progress": _quantize(source.last_glow_progress),
		"glow_visible": 1 if source.spell_glow.visible else 0,
		"glow_position_x": _quantize(source.spell_glow.position.x),
		"glow_position_y": _quantize(source.spell_glow.position.y),
		"glow_rotation": _quantize(source.spell_glow.rotation),
		"glow_scale": _quantize(source.spell_glow.scale.x),
		"glow_alpha": _quantize(source.spell_glow.color.a),
		"animation": String(source.animated_sprite.animation),
		"source_faction": source.get_combat_faction_id(),
		"action_sequence": source.action_sequence,
		"action_log": "|".join(source.action_log),
		"fireball_attempts": source.fireball_attempt_count,
		"fireball_count": source.fireball_records.size(),
		"last_fireball_direction_x": int(last_fireball.get("direction_x", 0)),
		"last_fireball_direction_y": int(last_fireball.get("direction_y", 0)),
		"last_fireball_damage": int(last_fireball.get("damage", 0)),
		"last_fireball_target": int(last_fireball.get("target_id", 0)),
		"last_fireball_source_faction": int(
			last_fireball.get("source_faction", -1)
		),
		"last_fireball_instigator": int(
			last_fireball.get("instigator_id", 0)
		),
		"last_fireball_source_type": String(
			last_fireball.get("source_type", "")
		),
		"movement_submissions": source.movement_submission_count,
		"cooldown_updates": source.cooldown_update_deltas.size(),
		"last_cooldown_delta": (
			_quantize(source.cooldown_update_deltas[-1])
			if not source.cooldown_update_deltas.is_empty()
			else 0
		),
		"los_queries": source.los_query_count,
		"behavior_rng": source.random_generator.state,
		"drop_rng": source.material_drop_random_generator.state,
		"central_owned": 1 if source.is_centrally_simulated() else 0,
		"indexed_touch": (
			1 if source.is_indexed_touch_authority_enabled() else 0
		),
		"touch_area_monitoring": (
			1 if source.touch_damage_area.monitoring else 0
		),
	}


func _capture_rollback_state(source: Variant) -> Dictionary:
	return {
		"state": source.combat_state,
		"cooldown": source.attack_cooldown_left,
		"windup": source.windup_time_left,
		"fire": source.fire_time_left,
		"direction": source.fire_direction,
		"target": source.attack_target,
		"action_sequence": source.action_sequence,
		"rng": source.random_generator.state,
		"glow": source.last_glow_progress,
	}


func _validate_mode_invariants(
	mode_name: String,
	simulation_mode: int,
	snapshots: Array[Dictionary],
	context: Dictionary
) -> void:
	if snapshots.size() != TEST_TICKS:
		failures.append("%s must capture every Mage tick." % mode_name)
		return
	_expect_state(snapshots, 1, CapooMage.CombatState.WINDUP, mode_name)
	_expect(
		int(snapshots[1]["fire_direction_y"]) > 0,
		"%s WINDUP must track the target movement on tick 2." % mode_name
	)
	_expect_state(snapshots, 4, CapooMage.CombatState.FIRE, mode_name)
	_expect(
		int(snapshots[3]["action_sequence"]) == 2
		and int(snapshots[3]["fireball_count"]) == 1,
		"%s first WINDUP/FIRE must preserve action order and one projectile."
		% mode_name
	)
	_expect_state(snapshots, 15, CapooMage.CombatState.CHASE, mode_name)
	var held_position_x := int(snapshots[14]["position_x"])
	for tick_number in range(16, 23):
		var held_snapshot: Dictionary = snapshots[tick_number - 1]
		_expect(
			int(held_snapshot["held"]) == 1
			and int(held_snapshot["position_x"]) == held_position_x,
			"%s cooldown hold must suppress motion on tick %d."
			% [mode_name, tick_number]
		)
	_expect_state(snapshots, 23, CapooMage.CombatState.WINDUP, mode_name)
	_expect_state(snapshots, 24, CapooMage.CombatState.CHASE, mode_name)
	_expect(
		int(snapshots[23]["movement_submissions"])
		== int(snapshots[22]["movement_submissions"])
		and int(snapshots[24]["movement_submissions"])
		> int(snapshots[23]["movement_submissions"]),
		"%s range cancellation must consume tick 24 and resume motion on tick 25."
		% mode_name
	)
	_expect_state(snapshots, 29, CapooMage.CombatState.CHASE, mode_name)
	_expect(
		int(snapshots[28]["fireball_count"]) == 1,
		"%s blocked LOS at windup expiry must cancel without firing."
		% mode_name
	)
	_expect_state(snapshots, 32, CapooMage.CombatState.CHASE, mode_name)
	_expect_state(snapshots, 35, CapooMage.CombatState.CHASE, mode_name)
	_expect(
		int(snapshots[31]["fireball_count"]) == 1
		and int(snapshots[34]["fireball_count"]) == 1,
		"%s friendly-faction and dead targets must cancel committed windup."
		% mode_name
	)
	_expect_state(snapshots, 39, CapooMage.CombatState.FIRE, mode_name)
	_expect(
		int(snapshots[38]["action_sequence"]) == 8
		and int(snapshots[38]["fireball_count"]) == 2
		and String(snapshots[38]["action_log"])
		== (
			"1:windup|2:fire|3:windup|4:windup|"
			+ "5:windup|6:windup|7:windup|8:fire"
		),
		"%s cancellations must not disturb deterministic action_sequence ordering."
		% mode_name
	)
	_expect(
		int(snapshots[3]["last_fireball_direction_x"]) == 0
		and int(snapshots[3]["last_fireball_direction_y"]) == 1_000_000
		and int(snapshots[38]["last_fireball_direction_x"]) == -1_000_000
		and int(snapshots[38]["last_fireball_direction_y"]) == 0,
		"%s fireballs must freeze the latest moving-target direction."
		% mode_name
	)
	_expect(
		int(snapshots[3]["last_fireball_source_faction"])
		== CombatRelationService.HOSTILE_WAVE
		and int(snapshots[3]["last_fireball_target"]) == TARGET_A_NET_ID
		and int(snapshots[38]["last_fireball_damage"])
		== MAGE_CONFIG.attack_damage
		and int(snapshots[38]["last_fireball_target"]) == TARGET_B_NET_ID
		and int(snapshots[38]["last_fireball_source_faction"])
		== CombatRelationService.PLAYER_ALLIED
		and int(snapshots[38]["last_fireball_instigator"])
		== SOURCE_NET_ID
		and String(snapshots[38]["last_fireball_source_type"])
		== "capoo_mage_fireball",
		"%s fireballs must freeze both default-hostile and runtime-allied launch factions with explicit type/instigator."
		% mode_name
	)
	_expect(
		bool(context["rollback_restored"])
		and bool(context["rollback_released_indexed"])
		and bool(context["rollback_preserved_state"]),
		"%s rollback must restore individual physics without changing Mage state/RNG."
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
			"CONTACT rollback must release indexed authority and restore TouchDamageArea."
		)
	var expected_phase := (
		&"decision"
		if simulation_mode in [POLICY.Mode.LAYERED_AREA, POLICY.Mode.LAYERED_CONTACT]
		else &"legacy"
	)
	var source: Variant = context["source"]
	_expect(
		source.windup_start_phases.size() == 6
		and source.fire_start_phases.size() == 2
		and _all_phases_equal(source.windup_start_phases, expected_phase)
		and _all_phases_equal(source.fire_start_phases, expected_phase),
		"%s attack commits must occur only in the expected %s phase."
		% [mode_name, expected_phase]
	)
	_expect(
		source.cooldown_update_deltas.size() == TEST_TICKS
		and _all_deltas_equal(source.cooldown_update_deltas, PHYSICS_DELTA),
		"%s cooldown/WINDUP/FIRE event clocks must remain exact 60 Hz."
		% mode_name
	)


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
			failures.append(
				"%s trace length differs from LEGACY." % mode_name
			)
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


func _all_deltas_equal(deltas: Array, expected_delta: float) -> bool:
	for delta_variant in deltas:
		if not is_equal_approx(float(delta_variant), expected_delta):
			return false
	return true


func _canonical_trace_lines(snapshots: Array[Dictionary]) -> PackedStringArray:
	var result := PackedStringArray()
	for snapshot in snapshots:
		result.append(JSON.stringify(snapshot))
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
		for tick_number in [1, 4, 15, 23, 24, 29, 32, 35, 39, 40, 51]:
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
