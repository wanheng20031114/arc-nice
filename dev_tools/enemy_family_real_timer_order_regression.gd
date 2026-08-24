extends SceneTree

## This regression intentionally relies on real SceneTree physics dispatch.
## Awaiting a frame is only the observation boundary: it never disables a runner
## and never invokes `_physics_process`, `_run_authoritative_physics_step`, or a
## coordinator phase manually. The harnesses record the actual parent/Timer and
## coordinator event/decision/motion order produced by Godot.

const POLICY := preload(
	"res://scene/combat/simulation/enemy_simulation_policy.gd"
)
const RUNTIME_SCENE := preload(
	"res://dev_tools/fixtures/enemy_gameplay_gateway_test_runtime.tscn"
)
const NINJA_SCENE := preload(
	"res://dev_tools/fixtures/combat_robot_ninja_timer_order_harness.tscn"
)
const OPERATOR_SCENE := preload(
	"res://dev_tools/fixtures/combat_robot_drone_operator_timer_order_harness.tscn"
)
const NINJA_CONFIG := preload(
	"res://resources/config/enemies/combat_robot_ninja.tres"
)
const OPERATOR_CONFIG := preload(
	"res://resources/config/enemies/combat_robot_drone_operator.tres"
)
const TARGET_CONFIG := preload(
	"res://resources/config/enemies/yuanshi_insect_basic.tres"
)

const PHYSICS_DELTA := 1.0 / 60.0
const SHORT_TIMER_TICKS := 2
const NINJA_COOLDOWN_TICKS := 4
const ROLLBACK_TIMER_TICKS := 5
const ROLLBACK_AFTER_TICKS := 2
const SOURCE_NET_ID := 98_100
const TARGET_NET_ID := 98_101
const TEST_MODES: Array[int] = [
	POLICY.Mode.LEGACY,
	POLICY.Mode.COMPAT_60,
	POLICY.Mode.LAYERED_AREA,
	POLICY.Mode.LAYERED_CONTACT,
]
const LAYERED_MODES: Array[int] = [
	POLICY.Mode.LAYERED_AREA,
	POLICY.Mode.LAYERED_CONTACT,
]
const OPERATOR_TIMER_KINDS: Array[StringName] = [
	&"deploy",
	&"cooldown",
	&"retry",
]
const NINJA_NO_MOTION_SCENARIOS: Array[StringName] = [
	&"stationary",
	&"existing_contact",
	&"no_target",
]

var failures: Array[String] = []
var completed_runs := 0


func _init() -> void:
	call_deferred(&"_run")


func _run() -> void:
	var debug_case := _resolve_debug_case()
	if debug_case != &"":
		await _run_debug_case(debug_case)
		return
	var ninja_runs := {}
	for simulation_mode in TEST_MODES:
		ninja_runs[simulation_mode] = await _run_ninja_timer_cycle(
			simulation_mode,
			SHORT_TIMER_TICKS,
			NINJA_COOLDOWN_TICKS,
			-1
		)
	_validate_ninja_mode_parity(ninja_runs, "steady")

	var ninja_rollback_runs := {}
	ninja_rollback_runs[POLICY.Mode.LEGACY] = await _run_ninja_timer_cycle(
		POLICY.Mode.LEGACY,
		ROLLBACK_TIMER_TICKS,
		ROLLBACK_TIMER_TICKS + 2,
		-1
	)
	for simulation_mode in LAYERED_MODES:
		ninja_rollback_runs[simulation_mode] = await _run_ninja_timer_cycle(
			simulation_mode,
			ROLLBACK_TIMER_TICKS,
			ROLLBACK_TIMER_TICKS + 2,
			ROLLBACK_AFTER_TICKS
		)
	_validate_ninja_mode_parity(ninja_rollback_runs, "rollback")
	_validate_ninja_rollbacks(ninja_rollback_runs)
	var ninja_zero_boundary_rollback_runs := {}
	ninja_zero_boundary_rollback_runs[POLICY.Mode.LEGACY] = (
		await _run_ninja_timer_cycle(
			POLICY.Mode.LEGACY,
			SHORT_TIMER_TICKS,
			SHORT_TIMER_TICKS,
			-1
		)
	)
	for simulation_mode in LAYERED_MODES:
		ninja_zero_boundary_rollback_runs[simulation_mode] = (
			await _run_ninja_timer_cycle(
				simulation_mode,
				SHORT_TIMER_TICKS,
				SHORT_TIMER_TICKS,
				SHORT_TIMER_TICKS
			)
		)
	_validate_ninja_mode_parity(
		ninja_zero_boundary_rollback_runs,
		"zero_boundary_rollback"
	)
	_validate_ninja_rollbacks(ninja_zero_boundary_rollback_runs)
	var ninja_no_motion_runs := {}
	for scenario in NINJA_NO_MOTION_SCENARIOS:
		var scenario_runs := {}
		for simulation_mode in TEST_MODES:
			scenario_runs[simulation_mode] = await _run_ninja_timer_cycle(
				simulation_mode,
				SHORT_TIMER_TICKS,
				NINJA_COOLDOWN_TICKS,
				-1,
				scenario
			)
		_validate_ninja_no_motion_finalization(scenario, scenario_runs)
		ninja_no_motion_runs[String(scenario)] = scenario_runs

	var operator_runs := {}
	for timer_kind in OPERATOR_TIMER_KINDS:
		var kind_runs := {}
		for simulation_mode in TEST_MODES:
			kind_runs[simulation_mode] = await _run_operator_timer_cycle(
				simulation_mode,
				timer_kind,
				SHORT_TIMER_TICKS,
				-1
			)
		_validate_operator_mode_parity(timer_kind, kind_runs, "steady")
		operator_runs[String(timer_kind)] = kind_runs

	var operator_rollback_runs := {}
	for timer_kind in OPERATOR_TIMER_KINDS:
		var kind_runs := {}
		kind_runs[POLICY.Mode.LEGACY] = await _run_operator_timer_cycle(
			POLICY.Mode.LEGACY,
			timer_kind,
			ROLLBACK_TIMER_TICKS,
			-1
		)
		for simulation_mode in LAYERED_MODES:
			kind_runs[simulation_mode] = await _run_operator_timer_cycle(
				simulation_mode,
				timer_kind,
				ROLLBACK_TIMER_TICKS,
				ROLLBACK_AFTER_TICKS
			)
		_validate_operator_mode_parity(timer_kind, kind_runs, "rollback")
		_validate_operator_rollbacks(timer_kind, kind_runs)
		operator_rollback_runs[String(timer_kind)] = kind_runs

	var operator_zero_boundary_rollback_runs := {}
	for timer_kind in OPERATOR_TIMER_KINDS:
		var kind_runs := {}
		kind_runs[POLICY.Mode.LEGACY] = await _run_operator_timer_cycle(
			POLICY.Mode.LEGACY,
			timer_kind,
			SHORT_TIMER_TICKS,
			-1
		)
		for simulation_mode in LAYERED_MODES:
			kind_runs[simulation_mode] = await _run_operator_timer_cycle(
				simulation_mode,
				timer_kind,
				SHORT_TIMER_TICKS,
				SHORT_TIMER_TICKS
			)
		_validate_operator_mode_parity(
			timer_kind,
			kind_runs,
			"zero_boundary_rollback"
		)
		_validate_operator_rollbacks(timer_kind, kind_runs)
		operator_zero_boundary_rollback_runs[String(timer_kind)] = kind_runs

	var operator_sleep_retry_runs := {}
	for simulation_mode in LAYERED_MODES:
		operator_sleep_retry_runs[simulation_mode] = (
			await _run_operator_sleep_retry_cycle(simulation_mode)
		)
	_validate_operator_sleep_retry_wake(operator_sleep_retry_runs)

	var expected_runs := (
		TEST_MODES.size()
		+ 1
		+ LAYERED_MODES.size()
		+ 1
		+ LAYERED_MODES.size()
		+ NINJA_NO_MOTION_SCENARIOS.size() * TEST_MODES.size()
		+ OPERATOR_TIMER_KINDS.size() * TEST_MODES.size()
		+ OPERATOR_TIMER_KINDS.size() * (1 + LAYERED_MODES.size())
		+ OPERATOR_TIMER_KINDS.size() * (1 + LAYERED_MODES.size())
		+ LAYERED_MODES.size()
	)
	_expect(
		completed_runs == expected_runs,
		"Every real SceneTree Timer run must complete (%d/%d)."
		% [completed_runs, expected_runs]
	)

	var result := {
		"status": "ok" if failures.is_empty() else "failed",
		"completed_runs": completed_runs,
		"expected_runs": expected_runs,
		"ninja_digests": _mode_trace_digests(ninja_runs),
		"ninja_rollback_digests": _mode_trace_digests(ninja_rollback_runs),
		"ninja_zero_boundary_rollback_digests": _mode_trace_digests(
			ninja_zero_boundary_rollback_runs
		),
		"ninja_no_motion_digests": _nested_trace_digests(
			ninja_no_motion_runs
		),
		"operator_digests": _nested_trace_digests(operator_runs),
		"operator_rollback_digests": _nested_trace_digests(
			operator_rollback_runs
		),
		"operator_zero_boundary_rollback_digests": _nested_trace_digests(
			operator_zero_boundary_rollback_runs
		),
		"operator_sleep_retry_digests": _mode_trace_digests(
			operator_sleep_retry_runs
		),
		"failures": failures.duplicate(),
	}
	print("ENEMY_FAMILY_REAL_TIMER_ORDER_JSON %s" % JSON.stringify(result))
	if failures.is_empty():
		print("ENEMY_FAMILY_REAL_TIMER_ORDER_REGRESSION_OK")
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	quit(1)


func _resolve_debug_case() -> StringName:
	for argument in OS.get_cmdline_user_args():
		if argument.begins_with("--timer-order-debug="):
			return StringName(argument.trim_prefix("--timer-order-debug="))
	return &""


func _run_debug_case(timer_kind: StringName) -> void:
	var result := {}
	for simulation_mode in TEST_MODES:
		var run := await _run_operator_timer_cycle(
			simulation_mode,
			timer_kind,
			SHORT_TIMER_TICKS,
			-1
		)
		result[_mode_name(simulation_mode)] = _trace_summary(run.get("trace", []))
	print("ENEMY_FAMILY_REAL_TIMER_ORDER_DEBUG %s" % JSON.stringify(result))
	quit(0)


func _run_ninja_timer_cycle(
	simulation_mode: int,
	boost_ticks: int,
	cooldown_ticks: int,
	rollback_after_ticks: int,
	no_motion_scenario: StringName = &""
) -> Dictionary:
	var context := _create_runtime_context(NINJA_SCENE, simulation_mode)
	var runtime: EnemyGameplayGatewayTestRuntime = context["runtime"]
	var coordinator: EnemySimulationCoordinator = context["coordinator"]
	var source: CombatRobotNinjaTimerOrderHarness = context["source"]
	var target: Enemy = context["target"]
	var source_config := NINJA_CONFIG.duplicate(true) as CombatRobotNinjaConfig
	source_config.boost_duration = PHYSICS_DELTA * float(boost_ticks)
	source_config.boost_cooldown = PHYSICS_DELTA * float(cooldown_ticks)
	source_config.move_speed = 60.0
	source_config.drop_table = null
	source_config.xirang_kill_reward = 0
	_setup_enemy_pair(source, source_config, target, runtime)
	_configure_ninja_no_motion_scenario(source, no_motion_scenario)
	source.begin_timer_order_trace()
	var started: bool = bool(source.call(&"_try_start_damage_boost"))
	_expect(started, "%s Ninja boost must start." % _mode_name(simulation_mode))

	var rollback_restored := rollback_after_ticks < 0
	var total_steps := maxi(boost_ticks, cooldown_ticks) + 4
	for step_index in range(1, total_steps + 1):
		await _await_one_complete_physics_step()
		if step_index == rollback_after_ticks:
			source.mark_timer_order_trace(&"rollback")
			coordinator.set_mode(POLICY.Mode.LEGACY)
			rollback_restored = (
				not source.is_centrally_simulated()
				and not source.layered_ninja_timer_authority_active
				and not source.boost_timer.paused
				and not source.cooldown_timer.paused
				and not source.boost_timer.is_stopped()
				and not source.cooldown_timer.is_stopped()
			)

	var run := {
		"trace": source.timer_order_trace.duplicate(true),
		"rollback_restored": rollback_restored,
		"central": source.is_centrally_simulated(),
		"boost_active": source.boost_active,
		"cooldown_active": source.boost_cooldown_active,
		"boost_timer_stopped": source.boost_timer.is_stopped(),
		"cooldown_timer_stopped": source.cooldown_timer.is_stopped(),
		"boost_timer_paused": source.boost_timer.paused,
		"cooldown_timer_paused": source.cooldown_timer.paused,
		"objective_target_valid": is_instance_valid(source.objective_target),
	}
	await _destroy_runtime(runtime)
	completed_runs += 1
	return run


func _configure_ninja_no_motion_scenario(
	source: CombatRobotNinjaTimerOrderHarness,
	scenario: StringName
) -> void:
	match scenario:
		&"stationary":
			source.forced_move_direction = Vector2.ZERO
		&"existing_contact":
			source.forced_existing_contact = true
		&"no_target":
			source.suppress_dynamic_target_refresh = true
			source.objective_target = null


func _run_operator_timer_cycle(
	simulation_mode: int,
	timer_kind: StringName,
	timer_ticks: int,
	rollback_after_ticks: int
) -> Dictionary:
	var context := _create_runtime_context(OPERATOR_SCENE, simulation_mode)
	var runtime: EnemyGameplayGatewayTestRuntime = context["runtime"]
	var coordinator: EnemySimulationCoordinator = context["coordinator"]
	var source: CombatRobotDroneOperatorTimerOrderHarness = context["source"]
	var target: Enemy = context["target"]
	var source_config := (
		OPERATOR_CONFIG.duplicate(true) as CombatRobotDroneOperatorConfig
	)
	source_config.attack_range = 400.0
	source_config.stop_distance = 0.0
	# Deploy is isolated from Cooldown here; Cooldown has its own real-Timer run.
	source_config.attack_cooldown = 0.0
	source_config.move_speed = 60.0
	source_config.drop_table = null
	source_config.xirang_kill_reward = 0
	_setup_enemy_pair(source, source_config, target, runtime)
	source.last_attack_target = target
	source.locked_deploy_direction = Vector2.RIGHT
	source.sensed_targets.clear()
	source.layered_operator_selection_requested = false
	source.begin_timer_order_trace()
	_start_operator_timer(source, timer_kind, timer_ticks)
	source.layered_operator_selection_requested = false

	var rollback_restored := rollback_after_ticks < 0
	var total_steps := timer_ticks + 4
	for step_index in range(1, total_steps + 1):
		await _await_one_complete_physics_step()
		if step_index == rollback_after_ticks:
			source.mark_timer_order_trace(&"rollback")
			coordinator.set_mode(POLICY.Mode.LEGACY)
			rollback_restored = (
				not source.is_centrally_simulated()
				and not source.layered_operator_clock_authority
				and _operator_timer_is_running(source, timer_kind)
			)

	var run := {
		"trace": source.timer_order_trace.duplicate(true),
		"rollback_restored": rollback_restored,
		"central": source.is_centrally_simulated(),
		"state": int(source.combat_state),
		"retry_armed": source.layered_blocked_retry_armed,
		"deploy_timer_stopped": source.deploy_timer.is_stopped(),
		"cooldown_timer_stopped": source.cooldown_timer.is_stopped(),
		"retry_timer_stopped": source.blocked_retry_timer.is_stopped(),
	}
	await _destroy_runtime(runtime)
	completed_runs += 1
	return run


func _run_operator_sleep_retry_cycle(simulation_mode: int) -> Dictionary:
	var context := _create_runtime_context(OPERATOR_SCENE, simulation_mode)
	var runtime: EnemyGameplayGatewayTestRuntime = context["runtime"]
	var source: CombatRobotDroneOperatorTimerOrderHarness = context["source"]
	var target: Enemy = context["target"]
	var source_config := (
		OPERATOR_CONFIG.duplicate(true) as CombatRobotDroneOperatorConfig
	)
	source_config.attack_range = 400.0
	source_config.stop_distance = 0.0
	source_config.blocked_retry_interval = PHYSICS_DELTA * float(
		SHORT_TIMER_TICKS
	)
	source_config.move_speed = 60.0
	source_config.drop_table = null
	source_config.xirang_kill_reward = 0
	source.force_infinite_event_sleep_certificate = true
	source.force_world_segment_blocked = true
	_setup_enemy_pair(source, source_config, target, runtime)
	source.sensed_targets[target.get_instance_id()] = target
	source.layered_operator_selection_requested = false
	source.begin_timer_order_trace()

	var sleep_established := false
	for _sleep_probe in range(3):
		await _await_one_complete_physics_step()
		if source.layered_area_event_phase_sleeping:
			sleep_established = true
			break
	source.mark_timer_order_trace(&"sleep_established")

	# Deliberately do not call the urgent-request API here. A regular 60 Hz
	# decision is allowed while the trusted event registration holds an infinite
	# sleep certificate; its failed production selection must wake the new Timer.
	source.production_selection_attempts_remaining = 1
	source.layered_operator_selection_requested = true
	await _await_one_complete_physics_step()
	var retry_armed_after_failure := source.layered_blocked_retry_armed
	var event_woken_after_failure := (
		not source.layered_area_event_phase_sleeping
	)

	for _retry_step in range(SHORT_TIMER_TICKS + 6):
		await _await_one_complete_physics_step()
		if (
			_count_tag(source.timer_order_trace, "retry_commit") == 1
			and _count_tag(source.timer_order_trace, "selection_attempt") >= 2
		):
			break

	var run := {
		"trace": source.timer_order_trace.duplicate(true),
		"sleep_established": sleep_established,
		"retry_armed_after_failure": retry_armed_after_failure,
		"event_woken_after_failure": event_woken_after_failure,
		"retry_armed": source.layered_blocked_retry_armed,
		"event_sleeping": source.layered_area_event_phase_sleeping,
	}
	await _destroy_runtime(runtime)
	completed_runs += 1
	return run


func _create_runtime_context(source_scene: PackedScene, simulation_mode: int) -> Dictionary:
	var runtime := RUNTIME_SCENE.instantiate() as EnemyGameplayGatewayTestRuntime
	runtime.runtime_mode = CombatRuntimeBase.RuntimeMode.SINGLEPLAYER
	var coordinator := runtime.get_node(
		"EnemySimulationCoordinator"
	) as EnemySimulationCoordinator
	coordinator.set_mode(simulation_mode)
	root.add_child(runtime)

	var enemy_container := runtime.get_node("EnemyContainer") as Node2D
	var target := TARGET_CONFIG.enemy_scene.instantiate() as Enemy
	target.name = "TimerOrderTarget"
	enemy_container.add_child(target)
	var source := source_scene.instantiate() as Enemy
	source.name = "TimerOrderSource"
	enemy_container.add_child(source)
	return {
		"runtime": runtime,
		"coordinator": coordinator,
		"source": source,
		"target": target,
	}


func _setup_enemy_pair(
	source: Enemy,
	source_config: EnemyConfig,
	target: Enemy,
	runtime: EnemyGameplayGatewayTestRuntime
) -> void:
	var target_config := TARGET_CONFIG.duplicate(true) as EnemyConfig
	target_config.drop_table = null
	target_config.xirang_kill_reward = 0
	target.set_meta(&"net_id", TARGET_NET_ID)
	target.setup(target_config, null, null, runtime)
	runtime.register_network_enemy(TARGET_NET_ID, target)
	target.set_combat_faction_id(
		CombatRelationService.PLAYER_ALLIED,
		1,
		true
	)
	target.set_authoritative_simulation_enabled(false)
	target.global_position = Vector2(240.0, 0.0)

	source.set_meta(&"net_id", SOURCE_NET_ID)
	source.setup(source_config, null, null, runtime)
	runtime.register_network_enemy(SOURCE_NET_ID, source)
	source.set_combat_faction_id(
		CombatRelationService.HOSTILE_WAVE,
		1,
		true
	)
	source.global_position = Vector2.ZERO
	source.velocity = Vector2.ZERO
	# Direct assignment avoids inventing an Area/objective signal before the
	# controlled Timer starts; the production movement validity checks remain real.
	source.objective_target = target
	source.request_layered_area_urgent_decision()


func _start_operator_timer(
	source: CombatRobotDroneOperatorTimerOrderHarness,
	timer_kind: StringName,
	timer_ticks: int
) -> void:
	var duration := PHYSICS_DELTA * float(timer_ticks)
	match timer_kind:
		&"deploy":
			source.combat_state = CombatRobotDroneOperator.CombatState.DEPLOY
			source.call(&"_start_deploy_delay", duration)
		&"cooldown":
			source.combat_state = (
				CombatRobotDroneOperator.CombatState.TRACKING_COOLDOWN
			)
			source.call(&"_start_cooldown", duration)
		&"retry":
			source.combat_state = (
				CombatRobotDroneOperator.CombatState.TRACKING_READY
			)
			source.call(&"_start_blocked_retry", duration)


func _operator_timer_is_running(
	source: CombatRobotDroneOperatorTimerOrderHarness,
	timer_kind: StringName
) -> bool:
	match timer_kind:
		&"deploy":
			return not source.deploy_timer.is_stopped()
		&"cooldown":
			return not source.cooldown_timer.is_stopped()
		&"retry":
			return not source.blocked_retry_timer.is_stopped()
	return false


func _await_one_complete_physics_step() -> void:
	await physics_frame
	# `physics_frame` is emitted immediately before node physics callbacks. The
	# following idle boundary observes their completed order without dispatching
	# any callback from test code.
	await process_frame


func _destroy_runtime(runtime: EnemyGameplayGatewayTestRuntime) -> void:
	if runtime != null and is_instance_valid(runtime):
		runtime.prepare_for_scene_teardown()
		runtime.queue_free()
	await process_frame


func _validate_ninja_mode_parity(runs: Dictionary, scenario: String) -> void:
	var baseline: Dictionary = runs.get(POLICY.Mode.LEGACY, {})
	var baseline_trace: Array = baseline.get("trace", [])
	var expected_boost_motion := _count_tag_before(
		baseline_trace,
		"motion_boost",
		"boost_timeout"
	)
	var expected_cooldown_motion := _count_motion_before(
		baseline_trace,
		"cooldown_timeout"
	)
	for simulation_mode_variant in runs:
		var simulation_mode := int(simulation_mode_variant)
		var run: Dictionary = runs[simulation_mode_variant]
		var trace: Array = run.get("trace", [])
		var label := "Ninja/%s/%s" % [_mode_name(simulation_mode), scenario]
		_expect(_count_tag(trace, "boost_timeout") == 1,
			"%s must commit exactly one boost timeout." % label)
		_expect(_count_tag(trace, "cooldown_timeout") == 1,
			"%s must commit exactly one cooldown timeout." % label)
		_expect(
			_count_tag_before(trace, "motion_boost", "boost_timeout")
			== expected_boost_motion,
			"%s must preserve every final boosted motion before timeout." % label
		)
		_expect(
			_count_motion_before(trace, "cooldown_timeout")
			== expected_cooldown_motion,
			"%s must preserve native cooldown deadline motion count." % label
		)
		_expect(
			_has_tag_after(trace, "motion_base", "boost_timeout"),
			"%s must move in base state only after boost timeout." % label
		)
		if scenario == "steady":
			_validate_ninja_raw_order(label, simulation_mode, trace)


func _validate_ninja_raw_order(
	label: String,
	simulation_mode: int,
	trace: Array
) -> void:
	var boost_timeout := _first_record(trace, "boost_timeout")
	var cooldown_timeout := _first_record(trace, "cooldown_timeout")
	if boost_timeout.is_empty() or cooldown_timeout.is_empty():
		return
	if simulation_mode in LAYERED_MODES:
		_expect(
			bool(boost_timeout.get("layered_clock", false))
			and _has_same_frame_before(trace, boost_timeout, "motion_lane_begin")
			and _has_same_frame_before(trace, boost_timeout, "motion_boost")
			and _has_same_frame_after(trace, boost_timeout, "motion_lane_end"),
			"%s layered boost timeout must follow real motion in its post-motion lane."
			% label
		)
		_expect(
			bool(cooldown_timeout.get("layered_clock", false))
			and _has_same_frame_before(trace, cooldown_timeout, "motion_lane_begin")
			and (
				_has_same_frame_before(trace, cooldown_timeout, "motion_boost")
				or _has_same_frame_before(trace, cooldown_timeout, "motion_base")
			)
			and _has_same_frame_after(trace, cooldown_timeout, "motion_lane_end"),
			"%s layered cooldown timeout must follow real motion in its post-motion lane."
			% label
		)
		_expect(
			_count_tag(trace, "parent_begin") == 0
			and _count_tag(trace, "runner_begin") == 0,
			"%s layered ownership must suppress both individual and whole runners."
			% label
		)
	else:
		_expect(
			not bool(boost_timeout.get("layered_clock", true))
			and _has_same_frame_before(trace, boost_timeout, "runner_end"),
			"%s native BoostTimer must fire after the real parent runner." % label
		)
		_expect(
			not bool(cooldown_timeout.get("layered_clock", true))
			and _has_same_frame_before(trace, cooldown_timeout, "runner_end"),
			"%s native CooldownTimer must fire after the real parent runner." % label
		)
		_expect(
			_count_tag(trace, "parent_begin") > 0
			if simulation_mode == POLICY.Mode.LEGACY
			else _count_tag(trace, "parent_begin") == 0,
			"%s must expose only its policy-owned parent callback." % label
		)


func _validate_ninja_no_motion_finalization(
	scenario: StringName,
	runs: Dictionary
) -> void:
	for simulation_mode_variant in runs:
		var simulation_mode := int(simulation_mode_variant)
		var run: Dictionary = runs[simulation_mode_variant]
		var trace: Array = run.get("trace", [])
		var label := "Ninja/%s/%s" % [
			_mode_name(simulation_mode),
			String(scenario),
		]
		_expect(_count_tag(trace, "boost_timeout") == 1,
			"%s must commit exactly one boost timeout." % label)
		_expect(_count_tag(trace, "cooldown_timeout") == 1,
			"%s must commit exactly one cooldown timeout." % label)
		_expect(
			_count_tag(trace, "motion_boost") == 0
			and _count_tag(trace, "motion_base") == 0,
			"%s must not manufacture a Transform for Timer finalization." % label
		)
		if scenario == &"no_target":
			_expect(
				not bool(run.get("objective_target_valid", true)),
				"%s must remain targetless throughout the real Timer cycle." % label
			)
		var boost_timeout := _first_record(trace, "boost_timeout")
		var cooldown_timeout := _first_record(trace, "cooldown_timeout")
		if boost_timeout.is_empty() or cooldown_timeout.is_empty():
			continue
		if simulation_mode in LAYERED_MODES:
			_expect(
				bool(boost_timeout.get("layered_clock", false))
				and _has_same_frame_before(
					trace,
					boost_timeout,
					"motion_lane_begin"
				)
				and _has_same_frame_after(
					trace,
					boost_timeout,
					"motion_lane_end"
				),
				"%s boost must finalize in a real post-motion slot even without movement."
				% label
			)
			_expect(
				bool(cooldown_timeout.get("layered_clock", false))
				and _has_same_frame_before(
					trace,
					cooldown_timeout,
					"motion_lane_begin"
				)
				and _has_same_frame_after(
					trace,
					cooldown_timeout,
					"motion_lane_end"
				),
				"%s cooldown must finalize in a real post-motion slot without movement."
				% label
			)
			_expect(
				_count_tag(trace, "parent_begin") == 0
				and _count_tag(trace, "runner_begin") == 0,
				"%s layered finalization must not revive an individual runner." % label
			)
		else:
			_expect(
				not bool(boost_timeout.get("layered_clock", true))
				and _has_same_frame_before(trace, boost_timeout, "runner_end"),
				"%s native boost timeout must remain after its stationary parent." % label
			)
			_expect(
				not bool(cooldown_timeout.get("layered_clock", true))
				and _has_same_frame_before(trace, cooldown_timeout, "runner_end"),
				"%s native cooldown timeout must remain after its stationary parent."
				% label
			)


func _validate_ninja_rollbacks(runs: Dictionary) -> void:
	for simulation_mode in LAYERED_MODES:
		var run: Dictionary = runs.get(simulation_mode, {})
		var trace: Array = run.get("trace", [])
		var label := "Ninja/%s/rollback" % _mode_name(simulation_mode)
		_expect(bool(run.get("rollback_restored", false)),
			"%s must restore both native Timer nodes at rollback." % label)
		_expect(_count_tag_after(trace, "event_begin", "rollback") == 0,
			"%s must stop the event lane after rollback." % label)
		_expect(_count_tag_after(trace, "parent_begin", "rollback") > 0,
			"%s must resume the individual parent on the next real tick." % label)
		_expect(
			_all_tag_records_after_use_native_clock(
				trace,
				["boost_timeout", "cooldown_timeout"],
				"rollback"
			),
			"%s restored timers must own the only post-rollback timeouts." % label
		)


func _validate_operator_mode_parity(
	timer_kind: StringName,
	runs: Dictionary,
	scenario: String
) -> void:
	var transition_tag := _operator_transition_tag(timer_kind)
	var behavior_tag := _operator_behavior_tag(timer_kind)
	var baseline: Dictionary = runs.get(POLICY.Mode.LEGACY, {})
	var baseline_trace: Array = baseline.get("trace", [])
	var expected_behavior_count := _count_tag_before(
		baseline_trace,
		behavior_tag,
		transition_tag
	)
	for simulation_mode_variant in runs:
		var simulation_mode := int(simulation_mode_variant)
		var run: Dictionary = runs[simulation_mode_variant]
		var trace: Array = run.get("trace", [])
		var label := "DroneOperator/%s/%s/%s" % [
			String(timer_kind),
			_mode_name(simulation_mode),
			scenario,
		]
		_expect(
			_count_tag(trace, transition_tag) == 1,
			"%s must commit exactly one Timer transition." % label
		)
		_expect(
			_count_tag_before(trace, behavior_tag, transition_tag)
			== expected_behavior_count,
			"%s must preserve the final old-state parent behavior before timeout."
			% label
		)
		if scenario == "steady":
			_validate_operator_raw_order(
				label,
				simulation_mode,
				timer_kind,
				trace
			)


func _validate_operator_raw_order(
	label: String,
	simulation_mode: int,
	timer_kind: StringName,
	trace: Array
) -> void:
	var transition_tag := _operator_transition_tag(timer_kind)
	var behavior_tag := _operator_behavior_tag(timer_kind)
	var transition := _first_record(trace, transition_tag)
	if transition.is_empty():
		return
	if simulation_mode in LAYERED_MODES:
		_expect(
			bool(transition.get("layered_clock", false))
			and _has_same_frame_before(trace, transition, "event_begin")
			and _has_same_frame_before(trace, transition, "event_end")
			and _has_same_frame_before(trace, transition, behavior_tag)
			and _has_same_frame_before(trace, transition, "motion_lane_begin")
			and _has_same_frame_after(trace, transition, "motion_lane_end")
			and String(transition.get("phase", "")) == "motion",
			(
				"%s event must expose the deadline, then the old-state behavior "
				+ "must finish before the single post-behavior motion-lane commit."
			) % label
		)
		if timer_kind == &"retry":
			var selection := _first_record(trace, "selection_attempt")
			_expect(
				not selection.is_empty()
				and _has_same_frame_before(trace, selection, "retry_commit")
				and _has_same_frame_before(trace, selection, "motion_lane_begin")
				and _has_same_frame_after(trace, selection, "motion_lane_end"),
				"%s retry selection must follow its post-behavior commit exactly once."
				% label
			)
		_expect(
			_count_tag(trace, "parent_begin") == 0
			and _count_tag(trace, "runner_begin") == 0,
			"%s layered ownership must not run a second parent step." % label
		)
	else:
		_expect(
			_has_same_frame_before(trace, transition, "runner_end"),
			"%s native Timer transition must follow the real parent runner." % label
		)
		if timer_kind == &"retry":
			_expect(
				_has_same_frame_before(trace, transition, "retry_timeout"),
				"%s native BlockedRetryTimer signal must precede its transition."
				% label
			)
			var selection := _first_record(trace, "selection_attempt")
			_expect(
				not selection.is_empty()
				and _has_same_frame_before(trace, selection, "retry_commit"),
				"%s native retry transition must precede selection." % label
			)


func _validate_operator_rollbacks(
	timer_kind: StringName,
	runs: Dictionary
) -> void:
	for simulation_mode in LAYERED_MODES:
		var run: Dictionary = runs.get(simulation_mode, {})
		var trace: Array = run.get("trace", [])
		var label := "DroneOperator/%s/%s/rollback" % [
			String(timer_kind),
			_mode_name(simulation_mode),
		]
		_expect(bool(run.get("rollback_restored", false)),
			"%s must restore its exact native Timer node." % label)
		_expect(_count_tag_after(trace, "event_begin", "rollback") == 0,
			"%s must stop the event lane after rollback." % label)
		_expect(_count_tag_after(trace, "parent_begin", "rollback") > 0,
			"%s must resume the parent runner without a dead tick." % label)
		_expect(
			_count_tag(trace, _operator_transition_tag(timer_kind)) == 1,
			"%s rollback must neither duplicate nor lose its timeout transition."
			% label
		)
		_expect(
			_all_tag_records_after_use_native_clock(
				trace,
				[_operator_transition_tag(timer_kind)],
				"rollback"
			),
			"%s restored Timer must own the only post-rollback transition." % label
		)


func _validate_operator_sleep_retry_wake(runs: Dictionary) -> void:
	for simulation_mode_variant in runs:
		var simulation_mode := int(simulation_mode_variant)
		var run: Dictionary = runs[simulation_mode_variant]
		var trace: Array = run.get("trace", [])
		var label := "DroneOperator/retry_sleep_wake/%s" % (
			_mode_name(simulation_mode)
		)
		_expect(bool(run.get("sleep_established", false)),
			"%s must first publish a real infinite event-sleep certificate." % label)
		_expect(bool(run.get("retry_armed_after_failure", false)),
			"%s failed decision selection must arm the layered retry clock." % label)
		_expect(bool(run.get("event_woken_after_failure", false)),
			"%s retry arming must invalidate the old infinite sleep certificate."
			% label)
		_expect(_count_tag(trace, "retry_commit") == 1,
			"%s must commit exactly one retry timeout." % label)
		_expect(_count_tag(trace, "retry_timeout") == 0,
			"%s layered retry must not leak a native Timer signal." % label)
		_expect(not bool(run.get("retry_armed", true)),
			"%s must disarm retry after its single timeout." % label)
		_expect(_count_tag_after(
			trace,
			"selection_attempt",
			"sleep_established"
		) == 2,
			"%s must select once to arm retry and once after its timeout." % label)
		var first_selection := _first_record_after(
			trace,
			"selection_attempt",
			"sleep_established"
		)
		var retry_commit := _first_record(trace, "retry_commit")
		var second_selection := _first_record_after_sequence(
			trace,
			"selection_attempt",
			int(first_selection.get("sequence", -1))
		)
		_expect(
			not first_selection.is_empty()
			and not retry_commit.is_empty()
			and not second_selection.is_empty()
			and int(first_selection.get("sequence", -1))
				< int(retry_commit.get("sequence", -1))
			and int(retry_commit.get("sequence", -1))
				< int(second_selection.get("sequence", -1)),
			"%s must preserve sleep -> failed selection -> timeout -> selection order."
			% label
		)
		_expect(
			bool(retry_commit.get("layered_clock", false))
			and _has_same_frame_before(trace, retry_commit, "event_begin")
			and _has_same_frame_before(trace, retry_commit, "event_end")
			and _has_same_frame_before(trace, retry_commit, "behavior_ready")
			and _has_same_frame_before(trace, retry_commit, "motion_lane_begin")
			and _has_same_frame_after(trace, retry_commit, "motion_lane_end")
			and String(retry_commit.get("phase", "")) == "motion",
			(
				"%s resumed event lane must expose the retry deadline, while the "
				+ "single timeout commit remains in the post-behavior motion lane."
			) % label
		)
		_expect(
			_count_tag(trace, "parent_begin") == 0
			and _count_tag(trace, "runner_begin") == 0,
			"%s wake must not revive either legacy runner." % label
		)


func _operator_transition_tag(timer_kind: StringName) -> String:
	match timer_kind:
		&"deploy":
			return "deploy_commit"
		&"cooldown":
			return "cooldown_commit"
		&"retry":
			return "retry_commit"
	return ""


func _operator_behavior_tag(timer_kind: StringName) -> String:
	match timer_kind:
		&"deploy":
			return "behavior_deploy"
		&"cooldown":
			return "behavior_cooldown"
		&"retry":
			return "behavior_ready"
	return ""


func _count_tag(trace: Array, tag: String) -> int:
	var count := 0
	for record_variant in trace:
		var record := record_variant as Dictionary
		if String(record.get("tag", "")) == tag:
			count += 1
	return count


func _count_tag_before(trace: Array, tag: String, stop_tag: String) -> int:
	var count := 0
	for record_variant in trace:
		var record := record_variant as Dictionary
		var record_tag := String(record.get("tag", ""))
		if record_tag == stop_tag:
			break
		if record_tag == tag:
			count += 1
	return count


func _count_motion_before(trace: Array, stop_tag: String) -> int:
	var count := 0
	for record_variant in trace:
		var record := record_variant as Dictionary
		var record_tag := String(record.get("tag", ""))
		if record_tag == stop_tag:
			break
		if record_tag in ["motion_boost", "motion_base"]:
			count += 1
	return count


func _count_tag_after(trace: Array, tag: String, start_tag: String) -> int:
	var count := 0
	var started := false
	for record_variant in trace:
		var record := record_variant as Dictionary
		var record_tag := String(record.get("tag", ""))
		if record_tag == start_tag:
			started = true
			continue
		if started and record_tag == tag:
			count += 1
	return count


func _has_tag_after(trace: Array, tag: String, start_tag: String) -> bool:
	return _count_tag_after(trace, tag, start_tag) > 0


func _first_record(trace: Array, tag: String) -> Dictionary:
	for record_variant in trace:
		var record := record_variant as Dictionary
		if String(record.get("tag", "")) == tag:
			return record
	return {}


func _first_record_after(
	trace: Array,
	tag: String,
	start_tag: String
) -> Dictionary:
	var started := false
	for record_variant in trace:
		var record := record_variant as Dictionary
		var record_tag := String(record.get("tag", ""))
		if record_tag == start_tag:
			started = true
			continue
		if started and record_tag == tag:
			return record
	return {}


func _first_record_after_sequence(
	trace: Array,
	tag: String,
	start_sequence: int
) -> Dictionary:
	for record_variant in trace:
		var record := record_variant as Dictionary
		if (
			int(record.get("sequence", -1)) > start_sequence
			and String(record.get("tag", "")) == tag
		):
			return record
	return {}


func _has_same_frame_before(
	trace: Array,
	anchor: Dictionary,
	tag: String
) -> bool:
	var anchor_frame := int(anchor.get("frame", -1))
	var anchor_sequence := int(anchor.get("sequence", -1))
	for record_variant in trace:
		var record := record_variant as Dictionary
		if int(record.get("sequence", -1)) >= anchor_sequence:
			break
		if (
			int(record.get("frame", -2)) == anchor_frame
			and String(record.get("tag", "")) == tag
		):
			return true
	return false


func _has_same_frame_after(
	trace: Array,
	anchor: Dictionary,
	tag: String
) -> bool:
	var anchor_frame := int(anchor.get("frame", -1))
	var anchor_sequence := int(anchor.get("sequence", -1))
	for record_variant in trace:
		var record := record_variant as Dictionary
		if (
			int(record.get("sequence", -1)) > anchor_sequence
			and int(record.get("frame", -2)) == anchor_frame
			and String(record.get("tag", "")) == tag
		):
			return true
	return false


func _all_tag_records_after_use_native_clock(
	trace: Array,
	tags: Array[String],
	start_tag: String
) -> bool:
	var started := false
	var observed := 0
	for record_variant in trace:
		var record := record_variant as Dictionary
		var record_tag := String(record.get("tag", ""))
		if record_tag == start_tag:
			started = true
			continue
		if not started or record_tag not in tags:
			continue
		observed += 1
		if bool(record.get("layered_clock", true)):
			return false
	return observed == tags.size()


func _mode_trace_digests(runs: Dictionary) -> Dictionary:
	var result := {}
	for simulation_mode_variant in runs:
		var run: Dictionary = runs[simulation_mode_variant]
		result[_mode_name(int(simulation_mode_variant))] = JSON.stringify(
			run.get("trace", [])
		).sha256_text()
	return result


func _nested_trace_digests(nested_runs: Dictionary) -> Dictionary:
	var result := {}
	for label_variant in nested_runs:
		result[String(label_variant)] = _mode_trace_digests(
			nested_runs[label_variant]
		)
	return result


func _trace_summary(trace: Array) -> PackedStringArray:
	var result := PackedStringArray()
	if trace.is_empty():
		return result
	var first_frame := int((trace.front() as Dictionary).get("frame", 0))
	for record_variant in trace:
		var record := record_variant as Dictionary
		result.append("%d:%s:%s:c%d:s%d" % [
			int(record.get("frame", first_frame)) - first_frame,
			String(record.get("tag", "")),
			String(record.get("phase", "")),
			1 if bool(record.get("layered_clock", false)) else 0,
			int(record.get("state", -1)),
		])
	return result


func _mode_name(simulation_mode: int) -> String:
	return POLICY.mode_to_name(simulation_mode)


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
