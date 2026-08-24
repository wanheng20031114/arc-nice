extends SceneTree

const POLICY := preload(
	"res://scene/combat/simulation/enemy_simulation_policy.gd"
)
const RUNTIME_SCENE := preload(
	"res://dev_tools/fixtures/combat_robot_drone_operator_layered_semantic_runtime.tscn"
)
const NORMAL_CONFIG := preload(
	"res://resources/config/enemies/combat_robot_drone_operator.tres"
)
const ELITE_CONFIG := preload(
	"res://resources/config/enemies/combat_robot_drone_operator_elite.tres"
)
const TARGET_CONFIG := preload(
	"res://resources/config/enemies/yuanshi_insect_basic.tres"
)
const SIMPLE_CHASE_SCRIPT := preload(
	"res://scene/enemy/simple_chase_layered_enemy.gd"
)

const PHYSICS_DELTA := 1.0 / 60.0
const TEST_TICKS := 16
const ROLLBACK_TICK := 9
const FIXED_SEED := 20_260_824
const SOURCE_NET_ID := 94_201
const SOURCE_OWNER_PEER_ID := 73
const TARGET_A_NET_ID := 94_202
const TARGET_B_NET_ID := 94_203
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
	"dead",
	"state",
	"position_x",
	"position_y",
	"velocity_x",
	"velocity_y",
	"deploy_left",
	"cooldown_left",
	"retry_left",
	"last_target",
	"objective",
	"locked_target_x",
	"locked_target_y",
	"locked_direction_x",
	"locked_direction_y",
	"facing_left",
	"animation",
	"source_faction",
	"action_sequence",
	"action_log",
	"spawn_attempts",
	"drone_records",
	"movement_submissions",
	"touch_updates",
	"behavior_rng",
	"drop_rng",
]

var failures: Array[String] = []
var completed_mode_count := 0


func _init() -> void:
	call_deferred(&"_run")


func _run() -> void:
	_verify_two_config_closure_and_capabilities()
	var all_profile_runs := {}
	for profile_config in [NORMAL_CONFIG, ELITE_CONFIG]:
		var profile_name := _profile_name(profile_config)
		var profile_runs := {}
		for simulation_mode in ALL_RUN_MODES:
			profile_runs[simulation_mode] = await _run_mode(
				simulation_mode,
				profile_config
			)
		_compare_mode_traces(profile_name, profile_runs)
		all_profile_runs[profile_name] = profile_runs

	await _verify_real_committed_drone_lifecycle(NORMAL_CONFIG)
	await _verify_real_committed_drone_lifecycle(ELITE_CONFIG)
	_expect(
		completed_mode_count == ALL_RUN_MODES.size() * 2,
		"The pre-refactor oracle and every DroneOperator policy replay must complete."
	)

	var result := {
		"status": "ok" if failures.is_empty() else "failed",
		"fixed_seed": FIXED_SEED,
		"ticks": TEST_TICKS,
		"rollback_tick": ROLLBACK_TICK,
		"modes": _mode_names(),
		"trace_digests": _all_trace_digests(all_profile_runs),
		"checkpoints": _all_checkpoint_diagnostics(all_profile_runs),
		"failures": failures.duplicate(),
	}
	print(
		"COMBAT_ROBOT_DRONE_OPERATOR_LAYERED_SEMANTICS_JSON %s"
		% JSON.stringify(result)
	)
	if failures.is_empty():
		print("COMBAT_ROBOT_DRONE_OPERATOR_LAYERED_SEMANTICS_REGRESSION_OK")
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	quit(1)


func _verify_two_config_closure_and_capabilities() -> void:
	for config in [NORMAL_CONFIG, ELITE_CONFIG]:
		var operator := config.enemy_scene.instantiate() as CombatRobotDroneOperator
		_expect(
			operator != null,
			"%s must instantiate CombatRobotDroneOperator." % config.resource_path
		)
		if operator == null:
			continue
		var implementation := operator.get_script() as Script
		_expect(
			implementation != null
			and implementation.get_base_script() == SIMPLE_CHASE_SCRIPT,
			"%s must directly inherit SimpleChaseLayeredEnemy."
			% config.resource_path
		)
		_expect(
			operator.supports_centralized_authoritative_simulation()
			and operator.supports_layered_area_authoritative_simulation()
			and operator.supports_layered_contact_authoritative_simulation()
			and not operator.supports_indexed_touch_authority()
			and operator.supports_dynamic_enemy_targeting()
			and bool(operator.call(&"_uses_inherited_touch_damage"))
			and operator.get_layered_area_decision_interval_frames() == 1,
			"%s must opt into AREA/CONTACT while retaining authored touch authority."
			% config.resource_path
		)
		operator.free()


func _run_mode(
	simulation_mode: int,
	profile_config: EnemyConfig
) -> Dictionary:
	var is_oracle := simulation_mode == PRE_REFACTOR_ORACLE_MODE
	var mode_name := _mode_name(simulation_mode)
	var profile_name := _profile_name(profile_config)
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

	var source: Variant = runtime.get_node("EnemyContainer/OperatorSource")
	var target_a := runtime.get_node("EnemyContainer/TargetA") as Enemy
	var target_b := runtime.get_node("EnemyContainer/TargetB") as Enemy
	var source_config := profile_config.duplicate(true) as CombatRobotDroneOperatorConfig
	source_config.attack_range = 200.0
	source_config.stop_distance = 0.0
	# Native physics Timers expose one zero boundary before timeout. These waits
	# preserve the intended tick-3/tick-8/tick-13 deployment script under that real
	# parent-before-child order instead of assuming timeout on the subtraction tick.
	source_config.deploy_delay = PHYSICS_DELTA
	source_config.attack_cooldown = PHYSICS_DELTA * 2.0
	source_config.blocked_retry_interval = PHYSICS_DELTA * 2.0
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
	# Give every newly-instantiated coordinator one neutral Engine physics boundary
	# before tick 1. No authored Timer is armed here. This makes the first manual
	# coordinator call eligible under its once-per-physics-frame guard without
	# reverting to the old child-Timer-before-parent replay order.
	await physics_frame
	_disable_automatic_callbacks(coordinator, source, [target_a, target_b])

	_expect(
		source.supports_layered_area_authoritative_simulation()
		and source.supports_layered_contact_authoritative_simulation()
		and not source.supports_indexed_touch_authority(),
		"%s/%s harness must retain the production capability boundary."
		% [profile_name, mode_name]
	)
	if is_oracle or simulation_mode == POLICY.Mode.LEGACY:
		_expect(
			not source.is_centrally_simulated(),
			"%s/%s must retain the individual runner."
			% [profile_name, mode_name]
		)
	else:
		_expect(
			source.is_centrally_simulated()
			and coordinator.owns_enemy(source, source.enemy_simulation_token),
			"%s/%s must be centrally owned."
			% [profile_name, mode_name]
		)

	var context := {
		"coordinator": coordinator,
		"source": source,
		"target_a": target_a,
		"target_b": target_b,
		"is_oracle": is_oracle,
		"rollback_applicable": not is_oracle,
		"rollback_preserved": simulation_mode == POLICY.Mode.LEGACY,
		"rollback_restored": simulation_mode == POLICY.Mode.LEGACY,
		"rollback_restore_checks": {},
		"contact_admitted_without_indexed": (
			simulation_mode != POLICY.Mode.LAYERED_CONTACT
		),
	}
	var snapshots: Array[Dictionary] = []
	for tick_index in range(1, TEST_TICKS + 1):
		source.semantic_tick = tick_index
		_apply_pre_tick_script(tick_index, context)
		# HEAD ran the operator body before its three physics Timer children.
		# Drive every policy at that same boundary: authored/coordinator body first,
		# native child Timer delivery second, then capture the completed tick. The
		# former non-oracle path awaited first and therefore compared a child-before-
		# parent fixture artifact against the frozen parent-before-child oracle.
		_advance_authority_one_tick(coordinator, source, is_oracle)
		await physics_frame
		_disable_automatic_callbacks(
			coordinator,
			source,
			[target_a, target_b]
		)
		if tick_index == 1 and simulation_mode == POLICY.Mode.LAYERED_CONTACT:
			var contact_service := runtime.get_enemy_contact_service()
			context["contact_admitted_without_indexed"] = (
				contact_service.owns_enemy(source)
				and not source.is_indexed_touch_authority_enabled()
				and source.touch_damage_area.monitoring
				and source.attack_sense_area.monitoring
				and _count_enabled_touch_shapes(source) == 1
			)
		if (
			tick_index == ROLLBACK_TICK
			and not is_oracle
			and simulation_mode != POLICY.Mode.LEGACY
		):
			var before_rollback := _capture_rollback_state(source)
			var rollback_used_layered_clock := bool(
				source.layered_operator_clock_authority
			)
			var deploy_timer_was_stopped: bool = bool(
				source.deploy_timer.is_stopped()
			)
			coordinator.set_mode(POLICY.Mode.LEGACY)
			context["rollback_preserved"] = (
				_capture_rollback_state(source) == before_rollback
			)
			context["rollback_restore_checks"] = {
				"individual": not source.is_centrally_simulated(),
				"physics": source.is_physics_processing(),
				"authored_touch": not source.is_indexed_touch_authority_enabled(),
				"touch_monitoring": source.touch_damage_area.monitoring,
				"sense_monitoring": source.attack_sense_area.monitoring,
				"contact_released": (
					not runtime.get_enemy_contact_service().owns_enemy(source)
				),
				# Layered rollback must materialize its zero-boundary deadline as
				# a native Timer for the next authored child slot. COMPAT already
				# owns that native Timer; at this exact boundary Godot has stopped
				# it while its timeout delivery remains queued, so rollback must
				# preserve (rather than manufacture) the native stopped state.
				"deploy_timer": (
					not source.deploy_timer.is_stopped()
					if rollback_used_layered_clock
					else (
						source.deploy_timer.is_stopped()
						== deploy_timer_was_stopped
					)
				),
			}
			context["rollback_restored"] = (
				false not in context["rollback_restore_checks"].values()
			)
			source.set_physics_process(false)
			coordinator.set_physics_process(false)
		snapshots.append(
			_capture_snapshot(tick_index, source, target_a, target_b)
		)

	_validate_mode_invariants(
		profile_name,
		mode_name,
		simulation_mode,
		snapshots,
		context,
		source_config
	)
	var result := {
		"mode": mode_name,
		"snapshots": snapshots,
		"trace_lines": _canonical_trace_lines(snapshots),
		"rollback_applicable": context["rollback_applicable"],
		"rollback_preserved": context["rollback_preserved"],
		"rollback_restored": context["rollback_restored"],
	}
	runtime.prepare_for_scene_teardown()
	runtime.queue_free()
	await process_frame
	completed_mode_count += 1
	return result


func _reset_source(source: Variant, target_a: Enemy, target_b: Enemy) -> void:
	# Establish the world relation before the semantic trace begins. A source
	# faction mutation can emit objective_target_changed; final cancellation below
	# erases that setup-only attempt and its Timer, leaving tick 1 AttackSense as
	# the replay's single explicit event source.
	target_a.global_position = Vector2(60.0, 0.0)
	target_b.global_position = Vector2(-50.0, 0.0)
	for target in [target_a, target_b]:
		target.is_dead = false
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
	source.set_combat_faction_id(
		CombatRelationService.HOSTILE_WAVE,
		1,
		true
	)
	# Direct assignment avoids inventing an objective-change event before tick 1.
	source.objective_target = target_a
	source.call(&"_cancel_operator_state", false, false)
	source.global_position = Vector2.ZERO
	source.velocity = Vector2.ZERO
	source.combat_state = CombatRobotDroneOperator.CombatState.TRACKING_READY
	source.last_attack_target = null
	source.locked_target_position = Vector2.ZERO
	source.locked_deploy_direction = Vector2.RIGHT
	source.layered_deploy_time_left = 0.0
	source.layered_cooldown_time_left = 0.0
	source.layered_blocked_retry_time_left = 0.0
	source.layered_operator_selection_requested = false
	source.forced_visibility = false
	source.forced_move_direction = Vector2.RIGHT
	source.use_real_drone_spawn = false
	source.semantic_tick = 0
	source.reset_semantic_trace()
	source.random_generator.seed = FIXED_SEED
	source.material_drop_random_generator.seed = FIXED_SEED + 1
	source.animated_sprite.play(source.config.move_animation_name)
	source.animated_sprite.pause()
	source.facing_left = false
	source.request_layered_area_urgent_decision()


func _apply_pre_tick_script(tick_index: int, context: Dictionary) -> void:
	var source: Variant = context["source"]
	var target_a: Enemy = context["target_a"]
	var target_b: Enemy = context["target_b"]
	if tick_index == 1:
		if bool(context.get("is_oracle", false)):
			source.call(&"emit_pre_refactor_attack_sense_entered", target_a)
		else:
			source.call(&"_on_attack_sense_area_body_entered", target_a)
	elif tick_index == 2:
		# The first blocked attempt must wait for its authored retry deadline.
		source.forced_visibility = true
	elif tick_index == 4:
		# A committed drone retains tick-3 position/direction when its target moves.
		target_a.global_position = Vector2(120.0, 0.0)
	elif tick_index == 6:
		# Source faction flips: A becomes friendly, B becomes hostile and becomes the
		# cooldown tracking/objective target without changing the committed drone.
		source.set_combat_faction_id(
			CombatRelationService.PLAYER_ALLIED,
			2,
			true
		)
		source.forced_move_direction = Vector2.LEFT
		source.set_objective_target(target_b)
		if bool(context.get("is_oracle", false)):
			source.call(&"emit_pre_refactor_attack_sense_entered", target_b)
		else:
			source.call(&"_on_attack_sense_area_body_entered", target_b)
	elif tick_index == 7:
		target_b.global_position = Vector2(-40.0, 40.0)
	elif tick_index == 9:
		# The second drone already froze (-40, 40); this move must not retarget it.
		target_b.global_position = Vector2(100.0, 100.0)
	elif tick_index == 11:
		# Direct target death (without an exit signal) must clear cooldown tracking.
		target_b.is_dead = true
		source.set_combat_faction_id(
			CombatRelationService.HOSTILE_WAVE,
			3,
			true
		)
		source.forced_move_direction = Vector2.RIGHT
		source.set_objective_target(target_a)
	elif tick_index == 14:
		# Death cancels only the operator timers/state. Every committed lease is
		# intentionally independent and is verified with real nodes below.
		source.call(&"_die")


func _advance_authority_one_tick(
	coordinator: EnemySimulationCoordinator,
	source: Variant,
	is_oracle: bool
) -> void:
	if source == null or not is_instance_valid(source) or source.is_dead:
		return
	if is_oracle:
		source.call(&"simulate_pre_refactor_authoritative_step", PHYSICS_DELTA)
		source.set_physics_process(false)
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
		"dead": 1 if source.is_dead else 0,
		"state": source.combat_state,
		"position_x": _quantize(source.global_position.x),
		"position_y": _quantize(source.global_position.y),
		"velocity_x": _quantize(source.velocity.x),
		"velocity_y": _quantize(source.velocity.y),
		"deploy_left": _quantize_milliseconds(source.semantic_deploy_time_left()),
		"cooldown_left": _quantize_milliseconds(source.semantic_cooldown_time_left()),
		"retry_left": _quantize_milliseconds(
			source.semantic_blocked_retry_time_left()
		),
		"last_target": _target_label(source.last_attack_target, target_a, target_b),
		"objective": _target_label(source.objective_target, target_a, target_b),
		"locked_target_x": _quantize(source.locked_target_position.x),
		"locked_target_y": _quantize(source.locked_target_position.y),
		"locked_direction_x": _quantize(source.locked_deploy_direction.x),
		"locked_direction_y": _quantize(source.locked_deploy_direction.y),
		"facing_left": 1 if source.facing_left else 0,
		"animation": String(source.animated_sprite.animation),
		"source_faction": source.get_combat_faction_id(),
		"action_sequence": source.action_sequence,
		"action_log": source.action_log.duplicate(),
		"spawn_attempts": source.spawn_attempt_count,
		"drone_records": source.drone_records.duplicate(true),
		"drone_record_phases": source.drone_record_phases.duplicate(),
		"selection_attempt_ticks": source.selection_attempt_ticks.duplicate(),
		"selection_attempt_phases": source.selection_attempt_phases.duplicate(),
		"movement_submissions": source.movement_submission_count,
		"touch_updates": source.touch_update_count,
		"behavior_rng": source.random_generator.state,
		"drop_rng": source.material_drop_random_generator.state,
		"central_owned": 1 if source.is_centrally_simulated() else 0,
		"clock_authority": 1 if source.layered_operator_clock_authority else 0,
		"indexed_touch": 1 if source.is_indexed_touch_authority_enabled() else 0,
		"touch_monitoring": 1 if source.touch_damage_area.monitoring else 0,
		"sense_monitoring": 1 if source.attack_sense_area.monitoring else 0,
		"enabled_touch_shapes": _count_enabled_touch_shapes(source),
	}


func _capture_rollback_state(source: Variant) -> Dictionary:
	return {
		"state": source.combat_state,
		"position": source.global_position,
		"velocity": source.velocity,
		"deploy_left_ms": _quantize_milliseconds(
			source.semantic_deploy_time_left()
		),
		"cooldown_left_ms": _quantize_milliseconds(
			source.semantic_cooldown_time_left()
		),
		"retry_left_ms": _quantize_milliseconds(
			source.semantic_blocked_retry_time_left()
		),
		"last_target": source.last_attack_target,
		"locked_position": source.locked_target_position,
		"locked_direction": source.locked_deploy_direction,
		"action_sequence": source.action_sequence,
		"action_log": source.action_log.duplicate(),
		"drone_records": source.drone_records.duplicate(true),
		"behavior_rng": source.random_generator.state,
	}


func _validate_mode_invariants(
	profile_name: String,
	mode_name: String,
	simulation_mode: int,
	snapshots: Array[Dictionary],
	context: Dictionary,
	profile_config: CombatRobotDroneOperatorConfig
) -> void:
	var label := "%s/%s" % [profile_name, mode_name]
	_expect(
		snapshots.size() == TEST_TICKS,
		"%s must capture every authored tick." % label
	)
	if snapshots.size() != TEST_TICKS:
		return
	var last: Dictionary = snapshots.back()
	var records: Array = last["drone_records"]
	_expect(
		int(last["spawn_attempts"]) == 3
		and records.size() == 3
		and int(last["action_sequence"]) == 3
		and (last["action_log"] as Array).size() == 3,
		"%s must commit exactly three drones/actions in sequence." % label
	)
	_expect(
		last["selection_attempt_ticks"] == [1, 3, 8, 13],
		"%s must preserve enter/retry/cooldown selection deadlines." % label
	)
	_expect(
		int(last["movement_submissions"]) == 9
		and int(last["touch_updates"]) == 13,
		"%s must retain 60 Hz tracking motion and touch-event cadence." % label
	)
	if not bool(context.get("is_oracle", false)):
		_expect(
			bool(context["rollback_preserved"])
			and bool(context["rollback_restored"]),
			(
				"%s rollback must preserve DEPLOY and restore its authored Timer/Areas "
				+ "(preserved=%s restored=%s)."
			)
			% [
				label,
				str(context["rollback_preserved"]),
				str(context["rollback_restored"])
					+ " checks="
					+ str(context["rollback_restore_checks"]),
			]
		)
	_expect(
		bool(context["contact_admitted_without_indexed"]),
		"%s CONTACT must own shared Enemy contact without indexed touch."
		% label
	)
	_expect(
		int(snapshots[12]["indexed_touch"]) == 0
		and int(snapshots[12]["touch_monitoring"]) == 1
		and int(snapshots[12]["sense_monitoring"]) == 1
		and int(snapshots[12]["enabled_touch_shapes"]) == 1,
		"%s must never disable TouchDamageArea or AttackSenseArea." % label
	)
	_expect(
		int(snapshots[8]["state"])
		== CombatRobotDroneOperator.CombatState.DEPLOY
		and int(snapshots[ROLLBACK_TICK - 2]["central_owned"])
		== (
			0
			if simulation_mode in [
				PRE_REFACTOR_ORACLE_MODE,
				POLICY.Mode.LEGACY,
			]
			else 1
		)
		and int(snapshots[ROLLBACK_TICK - 1]["central_owned"]) == 0,
		"%s must roll back a committed deployment exactly after tick 9."
		% label
	)
	_expect(
		int(last["dead"]) == 1
		and int(last["state"])
		== CombatRobotDroneOperator.CombatState.TRACKING_READY
		and int(last["deploy_left"]) == 0
		and int(last["cooldown_left"]) == 0
		and int(last["retry_left"]) == 0
		and records.size() == 3,
		"%s operator death must cancel local state without retracting commits."
		% label
	)
	_validate_drone_snapshots(label, records, profile_config)

	var record_phases: Array = last["drone_record_phases"]
	if simulation_mode in [
		POLICY.Mode.LAYERED_AREA,
		POLICY.Mode.LAYERED_CONTACT,
	]:
		_expect(
			record_phases == ["motion", "motion", ""],
			"%s must commit pre-rollback Timer callbacks after authored motion, then use restored Timer authority."
			% label
		)
	else:
		_expect(
			record_phases == ["", "", ""],
			"%s must retain authored signal/Timer deployment callbacks."
			% label
		)


func _validate_drone_snapshots(
	label: String,
	records: Array,
	profile_config: CombatRobotDroneOperatorConfig
) -> void:
	if records.size() != 3:
		return
	var expected_targets := [
		Vector2(60.0, 0.0),
		Vector2(-40.0, 40.0),
		Vector2(120.0, 0.0),
	]
	var expected_factions := [
		CombatRelationService.HOSTILE_WAVE,
		CombatRelationService.PLAYER_ALLIED,
		CombatRelationService.HOSTILE_WAVE,
	]
	for record_index in range(records.size()):
		var record := records[record_index] as Dictionary
		var target_position: Vector2 = expected_targets[record_index]
		_expect(
			int(record.get("tick", -1)) == [3, 8, 13][record_index]
			and int(record.get("target_x", 0)) == _quantize(target_position.x)
			and int(record.get("target_y", 0)) == _quantize(target_position.y),
			"%s drone %d must freeze its exact commit-time target."
			% [label, record_index + 1]
		)
		_expect(
			int(record.get("damage", -1)) == profile_config.attack_damage
			and int(record.get("speed", -1))
			== _quantize(profile_config.drone_speed)
			and String(record.get("source_type", ""))
			== String(profile_config.projectile_type),
			"%s drone %d must retain profile damage/speed/source type."
			% [label, record_index + 1]
		)
		_expect(
			int(record.get("source_faction", -1))
			== int(expected_factions[record_index])
			and int(record.get("credit_peer", 0)) == SOURCE_OWNER_PEER_ID
			and int(record.get("instigator", 0)) == SOURCE_NET_ID,
			"%s drone %d must freeze faction, credit and instigator identity."
			% [label, record_index + 1]
		)
	_expect(
		int((records[0] as Dictionary)["direction_x"]) > 0
		and int((records[1] as Dictionary)["direction_x"]) < 0
		and int((records[1] as Dictionary)["direction_y"]) > 0
		and int((records[2] as Dictionary)["direction_x"]) > 0,
		"%s formation directions must remain tied to frozen target positions."
		% label
	)


func _compare_mode_traces(profile_name: String, runs: Dictionary) -> void:
	var baseline: Dictionary = runs.get(PRE_REFACTOR_ORACLE_MODE, {})
	var baseline_snapshots: Array = baseline.get("snapshots", [])
	for simulation_mode in TEST_MODES:
		var run: Dictionary = runs.get(simulation_mode, {})
		var snapshots: Array = run.get("snapshots", [])
		var mode_name := _mode_name(simulation_mode)
		if snapshots.size() != baseline_snapshots.size():
			failures.append(
				"%s/%s trace length differs from pre-refactor oracle."
				% [profile_name, mode_name]
			)
			continue
		var mismatch_count := 0
		for tick_index in range(snapshots.size()):
			var actual: Dictionary = snapshots[tick_index]
			var expected: Dictionary = baseline_snapshots[tick_index]
			for field_name in GAMEPLAY_FIELDS:
				if actual.get(field_name) == expected.get(field_name):
					continue
				failures.append(
					"%s/%s diverged at tick %d field %s: oracle=%s actual=%s"
					% [
						profile_name,
						mode_name,
						tick_index + 1,
						field_name,
						str(expected.get(field_name)),
						str(actual.get(field_name)),
					]
				)
				mismatch_count += 1
				if mismatch_count >= 12:
					break
			if mismatch_count >= 12:
				break


func _verify_real_committed_drone_lifecycle(profile_config: EnemyConfig) -> void:
	var profile_name := _profile_name(profile_config)
	var runtime := RUNTIME_SCENE.instantiate() as EnemyGameplayGatewayTestRuntime
	runtime.runtime_mode = CombatRuntimeBase.RuntimeMode.SINGLEPLAYER
	var coordinator := runtime.get_node(
		"EnemySimulationCoordinator"
	) as EnemySimulationCoordinator
	coordinator.set_mode(POLICY.Mode.LEGACY)
	root.add_child(runtime)
	coordinator.set_physics_process(false)
	var source: Variant = runtime.get_node("EnemyContainer/OperatorSource")
	var target := runtime.get_node("EnemyContainer/TargetA") as Enemy
	var source_config := profile_config.duplicate(true) as CombatRobotDroneOperatorConfig
	source_config.drop_table = null
	source_config.xirang_kill_reward = 0
	_setup_enemy(source, source_config, runtime, SOURCE_NET_ID + 100)
	_setup_target(target, runtime, TARGET_A_NET_ID + 100)
	target.set_authoritative_simulation_enabled(false)
	_disable_automatic_callbacks(coordinator, source, [target])
	source.global_position = Vector2.ZERO
	target.global_position = Vector2(60.0, 0.0)
	source.set_combat_faction_id(
		CombatRelationService.HOSTILE_WAVE,
		1,
		true
	)
	target.set_combat_faction_id(
		CombatRelationService.PLAYER_ALLIED,
		1,
		true
	)
	source.use_real_drone_spawn = true
	source.semantic_tick = 1
	source.reset_semantic_trace()
	var committed: bool = bool(source.call(&"_begin_deploy", target))
	var motion_system := runtime.get_node(
		"CombatRobotDroneMotionSystem"
	) as CombatRobotDroneMotionSystem
	var drone: CombatRobotSuicideDrone = null
	if motion_system != null and not motion_system.drones.is_empty():
		drone = motion_system.drones.back()
	_expect(
		committed
		and drone != null
		and motion_system.has_drone(drone)
		and drone.deployment_started
		and drone.damage_source_snapshot != null,
		"%s real committed drone must join the authored motion system."
		% profile_name
	)
	if drone != null:
		var frozen_target := drone.target_position
		var frozen_snapshot := drone.damage_source_snapshot.duplicate_snapshot()
		source.call(&"_die")
		_expect(
			motion_system.has_drone(drone)
			and drone.pool_active
			and drone.deployment_started
			and drone.target_position.is_equal_approx(frozen_target)
			and drone.damage_source_snapshot.source_faction_id
			== frozen_snapshot.source_faction_id
			and drone.damage_source_snapshot.instigator_entity_id
			== frozen_snapshot.instigator_entity_id,
			"%s operator death must not retract or rewrite a committed drone."
			% profile_name
		)
		drone.retire()
		_expect(
			not motion_system.has_drone(drone),
			"%s explicit drone retirement must clean its formation/motion lease."
			% profile_name
		)
	runtime.prepare_for_scene_teardown()
	runtime.queue_free()
	await process_frame


func _setup_enemy(
	enemy: Variant,
	config: EnemyConfig,
	runtime: EnemyGameplayGatewayTestRuntime,
	net_id: int
) -> void:
	enemy.set_meta(&"net_id", net_id)
	enemy.set_meta(&"owner_peer_id", SOURCE_OWNER_PEER_ID)
	var pathfinder := runtime.get_node("GridPathfinder")
	enemy.setup(config, null, pathfinder, runtime)
	runtime.register_network_enemy(net_id, enemy)


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
	# AttackSenseArea remains live and asserted in every policy, but this semantic
	# replay owns enter/exit through its explicit authored event script. Removing
	# the target body from physics layers prevents a second, order-dependent Area
	# callback from restarting the native retry Timer during `await physics_frame`.
	target.collision_layer = 0
	runtime.register_network_enemy(net_id, target)


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


func _all_trace_digests(all_profile_runs: Dictionary) -> Dictionary:
	var result := {}
	for profile_name_variant in all_profile_runs:
		var profile_name := String(profile_name_variant)
		var profile_runs: Dictionary = all_profile_runs[profile_name_variant]
		var profile_digests := {}
		for simulation_mode in ALL_RUN_MODES:
			var run: Dictionary = profile_runs.get(simulation_mode, {})
			var lines: PackedStringArray = run.get(
				"trace_lines",
				PackedStringArray()
			)
			profile_digests[_mode_name(simulation_mode)] = (
				"\n".join(lines).sha256_text()
			)
		result[profile_name] = profile_digests
	return result


func _all_checkpoint_diagnostics(all_profile_runs: Dictionary) -> Dictionary:
	var result := {}
	for profile_name_variant in all_profile_runs:
		var profile_name := String(profile_name_variant)
		var profile_runs: Dictionary = all_profile_runs[profile_name_variant]
		var profile_checkpoints := {}
		for simulation_mode in ALL_RUN_MODES:
			var run: Dictionary = profile_runs.get(simulation_mode, {})
			var snapshots: Array = run.get("snapshots", [])
			var checkpoints := {}
			for tick_index in [1, 3, 5, 8, 9, 10, 11, 13, 14]:
				checkpoints[str(tick_index)] = (
					snapshots[tick_index - 1]
					if snapshots.size() >= tick_index
					else {}
				)
			profile_checkpoints[_mode_name(simulation_mode)] = checkpoints
		result[profile_name] = profile_checkpoints
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


func _profile_name(config: EnemyConfig) -> String:
	return "elite" if config == ELITE_CONFIG else "normal"


func _quantize(value: float) -> int:
	return roundi(value * 1_000_000.0)


func _quantize_milliseconds(value: float) -> int:
	return roundi(value * 1_000.0)


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
