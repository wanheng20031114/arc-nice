extends SceneTree

const POLICY := preload(
	"res://scene/combat/simulation/enemy_simulation_policy.gd"
)
const RUNTIME_SCENE := preload(
	"res://dev_tools/fixtures/combat_robot_layered_semantic_runtime.tscn"
)
const ROBOT_CONFIG := preload(
	"res://resources/config/enemies/combat_robot.tres"
)
const ROBOT_ELITE_CONFIG := preload(
	"res://resources/config/enemies/combat_robot_elite.tres"
)
const TARGET_CONFIG := preload(
	"res://resources/config/enemies/yuanshi_insect_basic.tres"
)

const PHYSICS_DELTA := 1.0 / 60.0
const TEST_TICKS := 24
const ROLLBACK_TICK := 17
const FIXED_SEED := 20_260_824
const SOURCE_NET_ID := 92_001
const TARGET_A_NET_ID := 92_002
const TARGET_B_NET_ID := 92_003
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
	"dash_left",
	"dash_direction_x",
	"dash_direction_y",
	"objective",
	"warning_visible",
	"warning_alpha",
	"warning_rotation",
	"animation",
	"action_sequence",
	"action_log",
	"windup_start_ticks",
	"dash_start_ticks",
	"dash_finish_ticks",
	"movement_submissions",
	"dash_submissions",
	"touch_updates",
	"cooldown_updates",
	"behavior_rng",
	"drop_rng",
]

var failures: Array[String] = []
var completed_mode_count := 0


func _init() -> void:
	call_deferred(&"_run")


func _run() -> void:
	_verify_two_config_closure_and_cadence()
	var runs: Dictionary = {}
	for simulation_mode in TEST_MODES:
		runs[simulation_mode] = await _run_mode(simulation_mode)
	_expect(
		completed_mode_count == TEST_MODES.size(),
		"Every CombatRobot policy coroutine must complete."
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
	print("COMBAT_ROBOT_LAYERED_SEMANTICS_JSON %s" % JSON.stringify(result))
	if failures.is_empty():
		print("COMBAT_ROBOT_LAYERED_SEMANTICS_REGRESSION_OK")
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	quit(1)


func _verify_two_config_closure_and_cadence() -> void:
	for config in [ROBOT_CONFIG, ROBOT_ELITE_CONFIG]:
		var robot := config.enemy_scene.instantiate() as CombatRobot
		_expect(
			robot != null,
			"%s must instantiate CombatRobot." % config.resource_path
		)
		if robot == null:
			continue
		_expect(
			robot.supports_centralized_authoritative_simulation()
			and robot.supports_layered_area_authoritative_simulation()
			and robot.supports_layered_contact_authoritative_simulation()
			and not robot.supports_indexed_touch_authority(),
			"%s must opt into compound enemy contact while indexed Player/Plant authority stays closed."
			% config.resource_path
		)
		_expect(
			robot.get_layered_area_decision_interval_frames()
			== robot.combat_sense_update_interval_frames
			and robot.get_layered_area_decision_interval_frames() > 1,
			"%s production perception must retain the authored throttled cadence."
			% config.resource_path
		)
		robot.free()


func _run_mode(simulation_mode: int) -> Dictionary:
	var mode_name := POLICY.mode_to_name(simulation_mode)
	var runtime := RUNTIME_SCENE.instantiate() as EnemyGameplayGatewayTestRuntime
	runtime.runtime_mode = CombatRuntimeBase.RuntimeMode.SINGLEPLAYER
	var coordinator := runtime.get_node(
		"EnemySimulationCoordinator"
	) as EnemySimulationCoordinator
	coordinator.set_mode(simulation_mode)
	root.add_child(runtime)
	coordinator.set_physics_process(false)

	var source: Variant = runtime.get_node("EnemyContainer/RobotSource")
	var target_a := runtime.get_node("EnemyContainer/TargetA") as Enemy
	var target_b := runtime.get_node("EnemyContainer/TargetB") as Enemy
	var source_config := ROBOT_CONFIG.duplicate(true) as CombatRobotConfig
	source_config.dash_trigger_range = 200.0
	source_config.dash_windup = PHYSICS_DELTA * 2.5
	source_config.dash_speed = 60.0
	source_config.dash_duration = PHYSICS_DELTA * 4.5
	source_config.dash_cooldown = PHYSICS_DELTA * 3.5
	source_config.drop_table = null
	source_config.xirang_kill_reward = 0
	_setup_enemy(source, source_config, runtime, SOURCE_NET_ID)
	_setup_target(target_a, runtime, TARGET_A_NET_ID)
	_setup_target(target_b, runtime, TARGET_B_NET_ID)
	target_a.set_authoritative_simulation_enabled(false)
	target_b.set_authoritative_simulation_enabled(false)
	_disable_automatic_callbacks(coordinator, source, [target_a, target_b])
	_reset_source(source, target_a, target_b)

	_expect(
		source.supports_layered_area_authoritative_simulation()
		and source.supports_layered_contact_authoritative_simulation()
		and not source.supports_indexed_touch_authority(),
		"%s test family must preserve the production capability boundary."
		% mode_name
	)
	if simulation_mode == POLICY.Mode.LEGACY:
		_expect(
			not source.is_centrally_simulated(),
			"LEGACY must retain CombatRobot's individual runner."
		)
	else:
		_expect(
			source.is_centrally_simulated()
			and coordinator.owns_enemy(source, source.enemy_simulation_token),
			"%s must centrally own CombatRobot." % mode_name
		)

	var context := {
		"coordinator": coordinator,
		"source": source,
		"target_a": target_a,
		"target_b": target_b,
		"rollback_preserved": simulation_mode == POLICY.Mode.LEGACY,
		"rollback_restored": simulation_mode == POLICY.Mode.LEGACY,
		"contact_proxy_only": simulation_mode != POLICY.Mode.LAYERED_CONTACT,
	}
	var snapshots: Array[Dictionary] = []
	for tick_index in range(1, TEST_TICKS + 1):
		_apply_pre_tick_script(tick_index, context)
		await _advance_one_tick(
			coordinator,
			source,
			[target_a, target_b]
		)
		if tick_index == 1 and simulation_mode == POLICY.Mode.LAYERED_CONTACT:
			var contact_service := runtime.get_enemy_contact_service()
			context["contact_proxy_only"] = (
				contact_service.owns_enemy(source)
				and not source.is_indexed_touch_authority_enabled()
				and source.touch_damage_area.monitoring
				and _count_enabled_touch_shapes(source) == 2
			)
		if tick_index == ROLLBACK_TICK and simulation_mode != POLICY.Mode.LEGACY:
			var before_rollback := _capture_rollback_state(source)
			coordinator.set_mode(POLICY.Mode.LEGACY)
			context["rollback_preserved"] = (
				_capture_rollback_state(source) == before_rollback
			)
			context["rollback_restored"] = (
				not source.is_centrally_simulated()
				and source.is_physics_processing()
				and not source.is_indexed_touch_authority_enabled()
				and source.touch_damage_area.monitoring
				and _count_enabled_touch_shapes(source) == 2
			)
			source.set_physics_process(false)
			coordinator.set_physics_process(false)
		snapshots.append(
			_capture_snapshot(tick_index, source, target_a, target_b)
		)

	_validate_mode_invariants(mode_name, simulation_mode, snapshots, context)
	var result := {
		"mode": mode_name,
		"snapshots": snapshots,
		"trace_lines": _canonical_trace_lines(snapshots),
	}
	runtime.queue_free()
	await process_frame
	completed_mode_count += 1
	return result


func _reset_source(source: Variant, target_a: Enemy, target_b: Enemy) -> void:
	source.global_position = Vector2.ZERO
	source.velocity = Vector2.ZERO
	source.combat_state = CombatRobot.CombatState.CHASE
	source.dash_cooldown_left = 0.0
	source.windup_time_left = 0.0
	source.dash_time_left = 0.0
	source.dash_direction = Vector2.RIGHT
	source.layered_dash_step_time = 0.0
	source.layered_dash_speed = 0.0
	source.layered_dash_step_prepared = false
	source.forced_target = target_a
	source.forced_target_valid = true
	source.forced_target_in_range = true
	source.forced_move_direction = Vector2.RIGHT
	source.forced_decision_interval_frames = 1
	source.semantic_tick = 0
	source.collision_on_dash_submission = 7
	source.reset_semantic_trace()
	source.random_generator.seed = FIXED_SEED
	source.material_drop_random_generator.seed = FIXED_SEED + 1
	target_a.global_position = Vector2(120.0, 0.0)
	target_b.global_position = Vector2(-120.0, 0.0)
	for target in [target_a, target_b]:
		target.is_dead = false
		target.set_combat_faction_id(
			CombatRelationService.PLAYER_ALLIED,
			1,
			true
		)
	source.set_combat_faction_id(
		CombatRelationService.HOSTILE_WAVE,
		1,
		true
	)
	source.set_objective_target(target_a)
	source.request_layered_area_urgent_decision()


func _apply_pre_tick_script(tick_index: int, context: Dictionary) -> void:
	var source: Variant = context["source"]
	var target_b: Enemy = context["target_b"]
	source.semantic_tick = tick_index
	if tick_index == 11:
		source.forced_target = target_b
		source.forced_move_direction = Vector2.LEFT
		source.set_objective_target(target_b)
		source.request_layered_area_urgent_decision()
	elif tick_index == 14:
		# A committed windup must survive its target becoming friendly to the
		# source faction; only the next automatic acquisition is filtered.
		target_b.set_combat_faction_id(
			CombatRelationService.HOSTILE_WAVE,
			2,
			true
		)
	elif tick_index == 15:
		target_b.global_position = Vector2(-40.0, 100.0)
	elif tick_index == 16:
		target_b.set_combat_faction_id(
			CombatRelationService.PLAYER_ALLIED,
			3,
			true
		)


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


func _capture_snapshot(
	tick_index: int,
	source: Variant,
	target_a: Enemy,
	target_b: Enemy
) -> Dictionary:
	return {
		"tick": tick_index,
		"state": source.combat_state,
		"position_x": _quantize(source.global_position.x),
		"position_y": _quantize(source.global_position.y),
		"velocity_x": _quantize(source.velocity.x),
		"velocity_y": _quantize(source.velocity.y),
		"cooldown": _quantize(source.dash_cooldown_left),
		"windup_left": _quantize(source.windup_time_left),
		"dash_left": _quantize(source.dash_time_left),
		"dash_direction_x": _quantize(source.dash_direction.x),
		"dash_direction_y": _quantize(source.dash_direction.y),
		"objective": _target_label(source.objective_target, target_a, target_b),
		"warning_visible": 1 if source.windup_warning.visible else 0,
		"warning_alpha": _quantize(source.windup_warning.color.a),
		"warning_rotation": _quantize(source.windup_warning.rotation),
		"animation": String(source.animated_sprite.animation),
		"action_sequence": source.action_sequence,
		"action_log": source.action_log.duplicate(),
		"windup_start_ticks": source.windup_start_ticks.duplicate(),
		"dash_start_ticks": source.dash_start_ticks.duplicate(),
		"dash_finish_ticks": source.dash_finish_ticks.duplicate(),
		"windup_start_phases": source.windup_start_phases.duplicate(),
		"movement_submissions": source.movement_submission_count,
		"dash_submissions": source.dash_submission_count,
		"touch_updates": source.touch_update_count,
		"cooldown_updates": source.cooldown_update_count,
		"behavior_rng": source.random_generator.state,
		"drop_rng": source.material_drop_random_generator.state,
		"central_owned": 1 if source.is_centrally_simulated() else 0,
		"indexed_touch": 1 if source.is_indexed_touch_authority_enabled() else 0,
		"touch_monitoring": 1 if source.touch_damage_area.monitoring else 0,
		"enabled_touch_shapes": _count_enabled_touch_shapes(source),
	}


func _capture_rollback_state(source: Variant) -> Dictionary:
	return {
		"state": source.combat_state,
		"position": source.global_position,
		"velocity": source.velocity,
		"cooldown": source.dash_cooldown_left,
		"windup": source.windup_time_left,
		"dash": source.dash_time_left,
		"direction": source.dash_direction,
		"action_sequence": source.action_sequence,
		"warning_visible": source.windup_warning.visible,
		"warning_rotation": source.windup_warning.rotation,
		"warning_color": source.windup_warning.color,
		"animation": source.animated_sprite.animation,
		"dash_submissions": source.dash_submission_count,
	}


func _validate_mode_invariants(
	mode_name: String,
	simulation_mode: int,
	snapshots: Array[Dictionary],
	context: Dictionary
) -> void:
	_expect(
		snapshots.size() == TEST_TICKS,
		"%s must capture every scripted tick." % mode_name
	)
	if snapshots.size() != TEST_TICKS:
		return
	var last: Dictionary = snapshots.back()
	_expect(
		last["windup_start_ticks"] == [1, 13, 22]
		and last["dash_start_ticks"] == [4, 16]
		and last["dash_finish_ticks"] == [9, 18],
		"%s must preserve windup, duration finish and scripted collision edges."
		% mode_name
	)
	_expect(
		int(snapshots[3]["dash_submissions"]) == 0
		and int(snapshots[4]["dash_submissions"]) == 1
		and int(snapshots[8]["dash_submissions"]) == 5,
		"%s must not move on the WINDUP-to-DASH transition tick and must clamp the final half tick."
		% mode_name
	)
	_expect(
		int(snapshots[17]["dash_submissions"]) == 7
		and int(snapshots[17]["state"]) == CombatRobot.CombatState.CHASE,
		"%s second dash must stop on the deterministic collision submission."
		% mode_name
	)
	_expect(
		bool(context["rollback_preserved"])
		and bool(context["rollback_restored"]),
		"%s rollback must preserve the mid-dash state and restore individual authority."
		% mode_name
	)
	_expect(
		bool(context["contact_proxy_only"]),
		"%s CONTACT must register the compound enemy proxy while retaining both authored Player/Plant shapes."
		% mode_name
	)
	_expect(
		int(last["touch_updates"]) == TEST_TICKS
		and int(last["cooldown_updates"]) == TEST_TICKS,
		"%s must advance touch then dash-family event exactly once per tick."
		% mode_name
	)
	var expected_phase := (
		"decision"
		if simulation_mode in [
			POLICY.Mode.LAYERED_AREA,
			POLICY.Mode.LAYERED_CONTACT,
		]
		else "compat"
	)
	var phases: Array = last["windup_start_phases"]
	# The third windup occurs after the scripted rollback and therefore uses the
	# individual runner in every non-LEGACY mode.
	_expect(
		phases.size() == 3
		and String(phases[0]) == expected_phase
		and String(phases[1]) == expected_phase
		and String(phases[2]) == "compat",
		"%s must commit layered windups only in decision and post-rollback windup in COMPAT."
		% mode_name
	)
	_expect(
		int(last["indexed_touch"]) == 0
		and int(last["touch_monitoring"]) == 1
		and int(last["enabled_touch_shapes"]) == 2,
		"%s must never disable composite authored touch authority." % mode_name
	)


func _compare_mode_traces(runs: Dictionary) -> void:
	var baseline: Dictionary = runs.get(POLICY.Mode.COMPAT_60, {})
	var baseline_snapshots: Array = baseline.get("snapshots", [])
	for simulation_mode in TEST_MODES:
		if simulation_mode == POLICY.Mode.COMPAT_60:
			continue
		var run: Dictionary = runs.get(simulation_mode, {})
		var snapshots: Array = run.get("snapshots", [])
		var mode_name := POLICY.mode_to_name(simulation_mode)
		if snapshots.size() != baseline_snapshots.size():
			failures.append("%s trace length differs from COMPAT_60." % mode_name)
			continue
		var mismatch_count := 0
		for tick_index in range(snapshots.size()):
			var actual: Dictionary = snapshots[tick_index]
			var expected: Dictionary = baseline_snapshots[tick_index]
			for field_name in GAMEPLAY_FIELDS:
				if actual.get(field_name) == expected.get(field_name):
					continue
				failures.append(
					"%s diverged at tick %d field %s: compat=%s actual=%s"
					% [
						mode_name,
						tick_index + 1,
						field_name,
						str(expected.get(field_name)),
						str(actual.get(field_name)),
					]
				)
				mismatch_count += 1
				if mismatch_count >= 8:
					break
			if mismatch_count >= 8:
				break


func _setup_enemy(
	enemy: Variant,
	config: EnemyConfig,
	runtime: EnemyGameplayGatewayTestRuntime,
	net_id: int
) -> void:
	enemy.set_meta(&"net_id", net_id)
	enemy.setup(config, null, null, runtime)
	runtime.register_network_enemy(net_id, enemy)
	enemy.set_combat_faction_id(
		CombatRelationService.HOSTILE_WAVE,
		1,
		true
	)


func _setup_target(
	target: Enemy,
	runtime: EnemyGameplayGatewayTestRuntime,
	net_id: int
) -> void:
	var target_config := TARGET_CONFIG.duplicate(true) as EnemyConfig
	target_config.drop_table = null
	target_config.xirang_kill_reward = 0
	target.set_meta(&"net_id", net_id)
	target.setup(target_config, null, null, runtime)
	runtime.register_network_enemy(net_id, target)
	target.set_combat_faction_id(
		CombatRelationService.PLAYER_ALLIED,
		1,
		true
	)


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


func _count_enabled_touch_shapes(enemy: Enemy) -> int:
	var count := 0
	if enemy == null or enemy.touch_damage_area == null:
		return count
	for child in enemy.touch_damage_area.get_children():
		var shape := child as CollisionShape2D
		if shape != null and shape.shape != null and not shape.disabled:
			count += 1
	return count


func _target_label(target: Node2D, target_a: Enemy, target_b: Enemy) -> String:
	if target == target_a:
		return "target_a"
	if target == target_b:
		return "target_b"
	return "none"


func _canonical_trace_lines(
	snapshots: Array[Dictionary]
) -> PackedStringArray:
	var result := PackedStringArray()
	for snapshot in snapshots:
		var canonical := {}
		for field_name in GAMEPLAY_FIELDS:
			canonical[field_name] = snapshot.get(field_name)
		result.append(JSON.stringify(canonical))
	return result


func _trace_digests(runs: Dictionary) -> Dictionary:
	var result := {}
	for simulation_mode in TEST_MODES:
		var run: Dictionary = runs.get(simulation_mode, {})
		var lines: PackedStringArray = run.get(
			"trace_lines",
			PackedStringArray()
		)
		result[POLICY.mode_to_name(simulation_mode)] = (
			"\n".join(lines).sha256_text()
		)
	return result


func _checkpoint_diagnostics(runs: Dictionary) -> Dictionary:
	var result := {}
	for simulation_mode in TEST_MODES:
		var run: Dictionary = runs.get(simulation_mode, {})
		var snapshots: Array = run.get("snapshots", [])
		var checkpoints := {}
		for tick_index in [4, 9, 17, 18, 22]:
			checkpoints[str(tick_index)] = (
				snapshots[tick_index - 1]
				if snapshots.size() >= tick_index
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
