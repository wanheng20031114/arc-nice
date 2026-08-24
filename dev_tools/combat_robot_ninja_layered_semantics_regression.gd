extends SceneTree

const POLICY := preload(
	"res://scene/combat/simulation/enemy_simulation_policy.gd"
)
const RUNTIME_SCENE := preload(
	"res://dev_tools/fixtures/combat_robot_ninja_layered_semantic_runtime.tscn"
)
const NINJA_CONFIG := preload(
	"res://resources/config/enemies/combat_robot_ninja.tres"
)
const NINJA_ELITE_CONFIG := preload(
	"res://resources/config/enemies/combat_robot_ninja_elite.tres"
)
const TARGET_CONFIG := preload(
	"res://resources/config/enemies/yuanshi_insect_basic.tres"
)

const PHYSICS_DELTA := 1.0 / 60.0
const TEST_TICKS := 13
const ROLLBACK_TICK := 11
const FIXED_SEED := 20_260_824
const SOURCE_NET_ID := 95_001
const TARGET_A_NET_ID := 95_002
const TARGET_B_NET_ID := 95_003
const PRE_REFACTOR_ORACLE_MODE := -1
const TEST_MODES: Array[int] = [
	POLICY.Mode.LEGACY,
	POLICY.Mode.COMPAT_60,
	POLICY.Mode.LAYERED_AREA,
	POLICY.Mode.LAYERED_CONTACT,
]
const ALL_RUN_MODES: Array[int] = [
	PRE_REFACTOR_ORACLE_MODE,
	POLICY.Mode.LEGACY,
	POLICY.Mode.COMPAT_60,
	POLICY.Mode.LAYERED_AREA,
	POLICY.Mode.LAYERED_CONTACT,
]
const GAMEPLAY_FIELDS: PackedStringArray = [
	"tick",
	"position_x",
	"position_y",
	"velocity_x",
	"velocity_y",
	"health",
	"boost_active",
	"cooldown_active",
	"boost_left",
	"cooldown_left",
	"objective",
	"facing_left",
	"animation",
	"action_sequence",
	"action_ticks",
	"action_names",
	"audio_pitches",
	"movement_submissions",
	"touch_updates",
	"authored_blades",
	"afterimage_direction_x",
	"afterimage_direction_y",
	"behavior_rng",
	"drop_rng",
]

var failures: Array[String] = []
var completed_run_count := 0


func _init() -> void:
	call_deferred(&"_run")


func _run() -> void:
	_verify_two_config_closure()
	var all_runs := {}
	for config in [NINJA_CONFIG, NINJA_ELITE_CONFIG]:
		var config_runs := {}
		for simulation_mode in ALL_RUN_MODES:
			config_runs[simulation_mode] = await _run_mode(
				config,
				simulation_mode
			)
		_compare_mode_traces(config.resource_path, config_runs)
		all_runs[config.resource_path] = config_runs
	_expect(
		completed_run_count == ALL_RUN_MODES.size() * 2,
		"The pre-refactor oracle and every normal/elite Ninja policy must complete."
	)

	var result := {
		"status": "ok" if failures.is_empty() else "failed",
		"fixed_seed": FIXED_SEED,
		"ticks": TEST_TICKS,
		"config_count": 2,
		"modes": _mode_names(),
		"trace_digests": _trace_digests(all_runs),
		"failures": failures.duplicate(),
	}
	print("COMBAT_ROBOT_NINJA_LAYERED_SEMANTICS_JSON %s" % JSON.stringify(result))
	if failures.is_empty():
		print("COMBAT_ROBOT_NINJA_LAYERED_SEMANTICS_REGRESSION_OK")
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	quit(1)


func _verify_two_config_closure() -> void:
	for config in [NINJA_CONFIG, NINJA_ELITE_CONFIG]:
		var ninja := config.enemy_scene.instantiate() as CombatRobotNinja
		_expect(
			ninja != null
			and ninja.supports_centralized_authoritative_simulation()
			and ninja.supports_layered_area_authoritative_simulation()
			and ninja.supports_layered_contact_authoritative_simulation()
			and not ninja.supports_indexed_touch_authority(),
			"%s must close the migrated Ninja family." % config.resource_path
		)
		if ninja != null:
			ninja.free()


func _run_mode(config: EnemyConfig, simulation_mode: int) -> Dictionary:
	var is_oracle := simulation_mode == PRE_REFACTOR_ORACLE_MODE
	var mode_name := _mode_name(simulation_mode)
	var config_label := config.resource_path.get_file().get_basename()
	var runtime := RUNTIME_SCENE.instantiate() as EnemyGameplayGatewayTestRuntime
	runtime.runtime_mode = CombatRuntimeBase.RuntimeMode.SINGLEPLAYER
	var coordinator := runtime.get_node(
		"EnemySimulationCoordinator"
	) as EnemySimulationCoordinator
	coordinator.set_mode(
		POLICY.Mode.LEGACY if is_oracle else simulation_mode
	)
	root.add_child(runtime)
	coordinator.set_physics_process(false)

	var source: Variant = runtime.get_node("EnemyContainer/NinjaSource")
	var target_a := runtime.get_node("EnemyContainer/TargetA") as Enemy
	var target_b := runtime.get_node("EnemyContainer/TargetB") as Enemy
	var source_config := config.duplicate(true) as CombatRobotNinjaConfig
	source_config.boost_duration = PHYSICS_DELTA * 12.0
	source_config.boost_cooldown = PHYSICS_DELTA * 20.0
	source_config.drop_table = null
	source_config.xirang_kill_reward = 0
	_setup_enemy(source, source_config, runtime, SOURCE_NET_ID)
	_setup_target(target_a, runtime, TARGET_A_NET_ID)
	_setup_target(target_b, runtime, TARGET_B_NET_ID)
	target_a.set_authoritative_simulation_enabled(false)
	target_b.set_authoritative_simulation_enabled(false)
	_disable_automatic_callbacks(coordinator, source, [target_a, target_b])
	_reset_source(source, target_a, target_b)
	source.call(&"set_pre_refactor_oracle_active", is_oracle)

	var context := {
		"coordinator": coordinator,
		"source": source,
		"target_a": target_a,
		"target_b": target_b,
		"is_oracle": is_oracle,
		"rollback_applicable": not is_oracle,
		"rollback_preserved": simulation_mode == POLICY.Mode.LEGACY,
		"rollback_restored": simulation_mode == POLICY.Mode.LEGACY,
		"contact_registered": simulation_mode != POLICY.Mode.LAYERED_CONTACT,
		"boost_union_registered": simulation_mode != POLICY.Mode.LAYERED_CONTACT,
	}
	var snapshots: Array[Dictionary] = []
	for tick_index in range(1, TEST_TICKS + 1):
		_apply_pre_tick_script(tick_index, context)
		await _advance_one_tick(
			coordinator,
			source,
			[target_a, target_b],
			is_oracle
		)
		if simulation_mode == POLICY.Mode.LAYERED_CONTACT:
			var contact_service := runtime.get_enemy_contact_service()
			if tick_index == 1:
				context["contact_registered"] = (
					contact_service.owns_enemy(source)
					and not source.is_indexed_touch_authority_enabled()
					and source.touch_damage_area.monitoring
				)
			elif tick_index == 2:
				context["boost_union_registered"] = (
					contact_service.owns_enemy(source)
					and _authored_blade_label(source) == "boost"
				)
		if (
			tick_index == ROLLBACK_TICK
			and not is_oracle
			and simulation_mode != POLICY.Mode.LEGACY
		):
			var before_rollback := _capture_rollback_state(source)
			coordinator.set_mode(POLICY.Mode.LEGACY)
			context["rollback_preserved"] = (
				_capture_rollback_state(source) == before_rollback
			)
			context["rollback_restored"] = (
				not source.is_centrally_simulated()
				and source.is_physics_processing()
				and not source.boost_timer.paused
				and not source.cooldown_timer.paused
				and not source.boost_timer.is_stopped()
				and source.touch_damage_area.monitoring
				and _count_enabled_touch_shapes(source) == 3
			)
			source.set_physics_process(false)
			coordinator.set_physics_process(false)
		snapshots.append(_capture_snapshot(
			tick_index,
			source,
			target_a,
			target_b
		))

	_validate_mode_invariants(
		"%s/%s" % [config_label, mode_name],
		simulation_mode,
		snapshots,
		context
	)
	var result := {
		"mode": mode_name,
		"snapshots": snapshots,
		"trace_lines": _canonical_trace_lines(snapshots),
		"rollback_applicable": context["rollback_applicable"],
	}
	runtime.queue_free()
	await process_frame
	completed_run_count += 1
	return result


func _reset_source(source: Variant, target_a: Enemy, target_b: Enemy) -> void:
	source.global_position = Vector2.ZERO
	source.velocity = Vector2.ZERO
	source.boost_active = false
	source.boost_cooldown_active = false
	source.layered_ninja_timer_authority_active = false
	source.layered_boost_time_left = 0.0
	source.layered_cooldown_time_left = 0.0
	source.boost_timer.stop()
	source.cooldown_timer.stop()
	source.boost_timer.paused = false
	source.cooldown_timer.paused = false
	source.forced_move_direction = Vector2.RIGHT
	source.forced_decision_interval_frames = 1
	source.reset_semantic_trace()
	source.random_generator.seed = FIXED_SEED
	source.material_drop_random_generator.seed = FIXED_SEED + 1
	target_a.global_position = Vector2(160.0, 0.0)
	target_b.global_position = Vector2(-160.0, 0.0)
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
	source.call(&"_sync_blade_contact_shapes")
	source.request_layered_area_urgent_decision()


func _apply_pre_tick_script(tick_index: int, context: Dictionary) -> void:
	var source: Variant = context["source"]
	var target_a: Enemy = context["target_a"]
	var target_b: Enemy = context["target_b"]
	source.semantic_tick = tick_index
	match tick_index:
		2:
			source.apply_damage(
				25,
				Vector2.LEFT,
				EnemyConfig.DamageType.PHYSICAL,
				false
			)
		4:
			target_a.set_combat_faction_id(
				CombatRelationService.HOSTILE_WAVE,
				2,
				true
			)
			source.forced_move_direction = Vector2.LEFT
			source.set_objective_target(target_b)
			source.request_layered_area_urgent_decision()
		5:
			target_a.is_dead = true
		6:
			source.call(&"_cancel_damage_boost", true, false)
		7:
			source.apply_damage(
				25,
				Vector2.RIGHT,
				EnemyConfig.DamageType.PHYSICAL,
				false
			)
		8:
			target_b.is_dead = true
			target_a.is_dead = false
			target_a.set_combat_faction_id(
				CombatRelationService.PLAYER_ALLIED,
				3,
				true
			)
			source.forced_move_direction = Vector2.RIGHT
			source.set_objective_target(target_a)
			source.request_layered_area_urgent_decision()
		9:
			target_a.set_combat_faction_id(
				CombatRelationService.HOSTILE_WAVE,
				4,
				true
			)
			source.set_objective_target(null)
			source.request_layered_area_urgent_decision()
		10:
			target_a.set_combat_faction_id(
				CombatRelationService.PLAYER_ALLIED,
				5,
				true
			)
			source.set_objective_target(target_a)
			source.request_layered_area_urgent_decision()
		12:
			target_a.is_dead = true
			target_b.is_dead = false
			target_b.set_combat_faction_id(
				CombatRelationService.PLAYER_ALLIED,
				3,
				true
			)
			source.forced_move_direction = Vector2.LEFT
			source.set_objective_target(target_b)
		13:
			target_b.set_combat_faction_id(
				CombatRelationService.HOSTILE_WAVE,
				4,
				true
			)
			target_a.is_dead = false
			target_a.set_combat_faction_id(
				CombatRelationService.PLAYER_ALLIED,
				7,
				true
			)
			source.forced_move_direction = Vector2.RIGHT
			source.set_objective_target(target_a)


func _advance_one_tick(
	coordinator: EnemySimulationCoordinator,
	source: Variant,
	other_nodes: Array,
	is_oracle: bool
) -> void:
	if source == null or not is_instance_valid(source) or source.is_dead:
		await physics_frame
		_disable_automatic_callbacks(coordinator, source, other_nodes)
		return
	if is_oracle:
		# HEAD ran the parent physics body before its Boost/Cooldown Timer children.
		# Step the frozen body first, then let the real physics Timers deliver their
		# native timeout signals on this same authored boundary.
		source.call(&"simulate_pre_refactor_authoritative_step", PHYSICS_DELTA)
		await physics_frame
		_disable_automatic_callbacks(coordinator, source, other_nodes)
		source.set_physics_process(false)
		return
	await physics_frame
	_disable_automatic_callbacks(coordinator, source, other_nodes)
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
	var afterimage: Vector2 = source.afterimage_world_direction
	return {
		"tick": tick_index,
		"position_x": _quantize(source.global_position.x),
		"position_y": _quantize(source.global_position.y),
		"velocity_x": _quantize(source.velocity.x),
		"velocity_y": _quantize(source.velocity.y),
		"health": source.current_health,
		"boost_active": 1 if source.boost_active else 0,
		"cooldown_active": 1 if source.boost_cooldown_active else 0,
		"boost_left": _quantize(source.get_authoritative_boost_time_left()),
		"cooldown_left": _quantize(
			source.get_authoritative_boost_cooldown_time_left()
		),
		"objective": _target_label(source.objective_target, target_a, target_b),
		"facing_left": 1 if source.facing_left else 0,
		"animation": String(source.animated_sprite.animation),
		"action_sequence": source.action_sequence,
		"action_ticks": source.action_ticks.duplicate(),
		"action_names": _string_name_array(source.action_names),
		"action_phases": _string_name_array(source.action_phases),
		"audio_pitches": source.boost_audio_pitch_samples.duplicate(),
		"movement_submissions": source.movement_submission_count,
		"movement_phases": _string_name_array(source.movement_phases),
		"touch_updates": source.touch_update_count,
		"family_events": source.family_event_count,
		"family_decisions": source.family_decision_count,
		"motion_phases": source.motion_phase_count,
		"authored_blades": _authored_blade_label(source),
		"afterimage_direction_x": _quantize(afterimage.x),
		"afterimage_direction_y": _quantize(afterimage.y),
		"behavior_rng": source.random_generator.state,
		"drop_rng": source.material_drop_random_generator.state,
		"central_owned": 1 if source.is_centrally_simulated() else 0,
		"touch_monitoring": 1 if source.touch_damage_area.monitoring else 0,
		"enabled_touch_shapes": _count_enabled_touch_shapes(source),
	}


func _capture_rollback_state(source: Variant) -> Dictionary:
	return {
		"position": source.global_position,
		"velocity": source.velocity,
		"boost_active": source.boost_active,
		"cooldown_active": source.boost_cooldown_active,
		"boost_left": _quantize(source.get_authoritative_boost_time_left()),
		"cooldown_left": _quantize(
			source.get_authoritative_boost_cooldown_time_left()
		),
		"action_sequence": source.action_sequence,
		"rng": source.random_generator.state,
		"animation": source.animated_sprite.animation,
		"authored_blades": _authored_blade_label(source),
	}


func _validate_mode_invariants(
	label: String,
	simulation_mode: int,
	snapshots: Array[Dictionary],
	context: Dictionary
) -> void:
	_expect(snapshots.size() == TEST_TICKS, "%s must capture every tick." % label)
	if snapshots.size() != TEST_TICKS:
		return
	var last: Dictionary = snapshots.back()
	_expect(
		last["action_ticks"] == [2, 7]
		and last["action_names"]
		== PackedStringArray([
			"combat_robot_ninja_boost",
			"combat_robot_ninja_boost",
		])
		and int(last["action_sequence"]) == 2
		and (last["audio_pitches"] as Array).size() == 2,
		"%s must preserve both damage-triggered boost commits and RNG samples."
		% label
	)
	_expect(
		int(snapshots[5]["boost_active"]) == 0
		and String(snapshots[5]["authored_blades"]) == "move"
		and int(snapshots[6]["boost_active"]) == 1
		and String(snapshots[6]["authored_blades"]) == "boost",
		"%s interruption must restore move blades before the second boost union."
		% label
	)
	_expect(
		String(snapshots[3]["objective"]) == "target_b"
		and String(snapshots[7]["objective"]) == "target_a"
		and String(snapshots[8]["objective"]) == "none"
		and String(snapshots[11]["objective"]) == "target_b"
		and String(snapshots[12]["objective"]) == "target_a",
		"%s must preserve friend/death/empty/recovery dynamic target edges."
		% label
	)
	if not bool(context.get("is_oracle", false)):
		_expect(
			bool(context["rollback_preserved"])
			and bool(context["rollback_restored"]),
			"%s rollback must preserve boost/RNG/timer state and restore native Timer authority."
			% label
		)
	_expect(
		bool(context["contact_registered"])
		and bool(context["boost_union_registered"]),
		"%s CONTACT must retain the compound proxy across the runtime blade swap."
		% label
	)
	_expect(
		int(last["touch_monitoring"]) == 1
		and int(last["enabled_touch_shapes"]) == 3,
		"%s must retain authored Player/Plant Area authority with body plus one blade pair."
		% label
	)
	var layered_mode := simulation_mode in [
		POLICY.Mode.LAYERED_AREA,
		POLICY.Mode.LAYERED_CONTACT,
	]
	if layered_mode:
		_expect(
			int(snapshots[ROLLBACK_TICK - 1]["family_events"])
			== ROLLBACK_TICK
			and int(snapshots[ROLLBACK_TICK - 1]["family_decisions"])
			== ROLLBACK_TICK,
			"%s layered runner must split all pre-rollback events and decisions."
			% label
		)
	else:
		_expect(
			int(last["family_events"]) == 0
			and int(last["family_decisions"]) == 0,
			"%s LEGACY/COMPAT must retain the whole authored runner."
			% label
		)


func _compare_mode_traces(config_path: String, runs: Dictionary) -> void:
	var baseline: Dictionary = runs.get(PRE_REFACTOR_ORACLE_MODE, {})
	var baseline_snapshots: Array = baseline.get("snapshots", [])
	_validate_pre_refactor_oracle_motion_touch(config_path, baseline_snapshots)
	print(
		"NINJA_PRE_REFACTOR_ORACLE_MOTION_TOUCH_TRACE config=%s trace=%s"
		% [
			config_path,
			_compact_oracle_motion_touch_trace(baseline_snapshots),
		]
	)
	for simulation_mode in TEST_MODES:
		var mode_name := _mode_name(simulation_mode)
		var run: Dictionary = runs.get(simulation_mode, {})
		var snapshots: Array = run.get("snapshots", [])
		if snapshots.size() != baseline_snapshots.size():
			failures.append(
				"%s/%s trace length differs from pre-refactor oracle."
				% [config_path, mode_name]
			)
			continue
		var mismatch_count := 0
		for tick_index in range(snapshots.size()):
			for field_name in GAMEPLAY_FIELDS:
				var actual: Dictionary = snapshots[tick_index]
				var expected: Dictionary = baseline_snapshots[tick_index]
				if actual.get(field_name) == expected.get(field_name):
					continue
				failures.append(
					"%s/%s diverged at tick %d field %s: oracle=%s actual=%s"
					% [
						config_path,
						mode_name,
						tick_index + 1,
						field_name,
						str(expected.get(field_name)),
						str(actual.get(field_name)),
					]
				)
				mismatch_count += 1
				if mismatch_count >= 10:
					break
			if mismatch_count >= 10:
				break


func _validate_pre_refactor_oracle_motion_touch(
	config_path: String,
	snapshots: Array
) -> void:
	_expect(
		snapshots.size() == TEST_TICKS,
		"%s pre-refactor oracle must expose every motion/touch tick."
		% config_path
	)
	if snapshots.size() != TEST_TICKS:
		return

	var expected_movement_submissions := 0
	var targetless_ticks := PackedInt32Array()
	for tick_index in range(snapshots.size()):
		var snapshot: Dictionary = snapshots[tick_index]
		var has_objective := String(snapshot.get("objective", "none")) != "none"
		if has_objective:
			expected_movement_submissions += 1
		else:
			targetless_ticks.append(tick_index + 1)
		_expect(
			int(snapshot.get("movement_submissions", -1))
			== expected_movement_submissions,
			(
				"%s pre-refactor oracle tick %d must submit motion exactly once "
				+ "for a live objective and never for a targetless tick."
			)
			% [config_path, tick_index + 1]
		)
		_expect(
			int(snapshot.get("touch_updates", -1)) == tick_index + 1,
			"%s pre-refactor oracle tick %d must retain its 60 Hz touch update."
			% [config_path, tick_index + 1]
		)
		if has_objective:
			continue
		_expect(
			int(snapshot.get("velocity_x", 1)) == 0
			and int(snapshot.get("velocity_y", 1)) == 0,
			"%s pre-refactor oracle tick %d must stop while targetless."
			% [config_path, tick_index + 1]
		)
		if tick_index <= 0:
			continue
		var previous: Dictionary = snapshots[tick_index - 1]
		_expect(
			int(snapshot.get("position_x", 1))
			== int(previous.get("position_x", 0))
			and int(snapshot.get("position_y", 1))
			== int(previous.get("position_y", 0)),
			"%s pre-refactor oracle tick %d must skip targetless motion."
			% [config_path, tick_index + 1]
		)
	_expect(
		targetless_ticks == PackedInt32Array([9]),
		"%s pre-refactor oracle must expose the scripted targetless edge only at tick 9."
		% config_path
	)


func _compact_oracle_motion_touch_trace(snapshots: Array) -> String:
	var parts := PackedStringArray()
	for snapshot_value in snapshots:
		var snapshot: Dictionary = snapshot_value
		parts.append(
			"%d:%s:m%d:t%d"
			% [
				int(snapshot.get("tick", 0)),
				String(snapshot.get("objective", "none")),
				int(snapshot.get("movement_submissions", -1)),
				int(snapshot.get("touch_updates", -1)),
			]
		)
	return "|".join(parts)


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
	primary_source: Variant,
	other_nodes: Array
) -> void:
	coordinator.set_physics_process(false)
	if primary_source != null and is_instance_valid(primary_source):
		primary_source.set_process(false)
		primary_source.set_physics_process(false)
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


func _authored_blade_label(source: Variant) -> String:
	var move_count := 0
	var boost_count := 0
	for shape_variant in source.call(&"_get_blade_contact_shapes"):
		var shape := shape_variant as CollisionShape2D
		if (
			shape == null
			or not source.is_touch_damage_shape_authored_enabled(shape)
		):
			continue
		var shape_name := String(shape.name)
		if shape_name.begins_with("Move"):
			move_count += 1
		elif shape_name.begins_with("Boost"):
			boost_count += 1
	if move_count == 2 and boost_count == 0:
		return "move"
	if boost_count == 2 and move_count == 0:
		return "boost"
	return "invalid:%d:%d" % [move_count, boost_count]


func _target_label(target: Node2D, target_a: Enemy, target_b: Enemy) -> String:
	if target == target_a:
		return "target_a"
	if target == target_b:
		return "target_b"
	return "none"


func _string_name_array(values: Array) -> PackedStringArray:
	var result := PackedStringArray()
	for value in values:
		result.append(String(value))
	return result


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


func _trace_digests(all_runs: Dictionary) -> Dictionary:
	var result := {}
	for config_path: String in all_runs:
		var config_result := {}
		var runs: Dictionary = all_runs[config_path]
		for simulation_mode in ALL_RUN_MODES:
			var run: Dictionary = runs.get(simulation_mode, {})
			var lines: PackedStringArray = run.get(
				"trace_lines",
				PackedStringArray()
			)
			config_result[_mode_name(simulation_mode)] = (
				"\n".join(lines).sha256_text()
			)
		result[config_path] = config_result
	return result


func _mode_names() -> PackedStringArray:
	var result := PackedStringArray()
	for simulation_mode in ALL_RUN_MODES:
		result.append(_mode_name(simulation_mode))
	return result


func _mode_name(simulation_mode: int) -> String:
	return (
		"PRE_REFACTOR_ORACLE"
		if simulation_mode == PRE_REFACTOR_ORACLE_MODE
		else POLICY.mode_to_name(simulation_mode)
	)


func _quantize(value: float) -> int:
	return roundi(value * 1_000_000.0)


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
