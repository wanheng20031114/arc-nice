extends SceneTree

const POLICY := preload(
	"res://scene/combat/simulation/enemy_simulation_policy.gd"
)
const RUNTIME_SCENE := preload(
	"res://dev_tools/fixtures/linglan_boss_layered_semantic_runtime.tscn"
)
const LINGLAN_CONFIG := preload(
	"res://resources/config/enemies/linglan_boss.tres"
)

const PHYSICS_DELTA := 1.0 / 60.0
const TEST_TICKS := 23
const ROLLBACK_TICK := 18
const FIXED_SEED := 20_260_824
const BOSS_NET_ID := 79_001
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
	"active",
	"phase",
	"position_x",
	"position_y",
	"velocity_x",
	"velocity_y",
	"skill1_elapsed",
	"skill1_fire_left",
	"skill1_finished",
	"skill2_elapsed",
	"skill2_spawn_ticks",
	"skill2_shots",
	"action_sequence",
	"action_log",
	"ring_log",
	"movement_submissions",
	"touch_updates",
	"warning_updates",
	"warning_clears",
	"skill2_spawn_requests",
	"skill2_warning_spawns",
	"skill2_warning_updates",
	"skill2_fires",
	"event_order",
	"animation",
	"skill3_rng",
	"skill4_rng",
	"skill_order_rng",
]

var failures: Array[String] = []
var completed_mode_count := 0


func _init() -> void:
	call_deferred(&"_run")


func _run() -> void:
	var runs: Dictionary = {}
	for simulation_mode in ALL_RUN_MODES:
		runs[simulation_mode] = await _run_mode(simulation_mode)
	_expect(
		completed_mode_count == ALL_RUN_MODES.size(),
		"迁移前 oracle 与四种灵岚策略必须全部抵达完成哨兵。"
	)
	_compare_mode_traces(runs)

	var result := {
		"status": "ok" if failures.is_empty() else "failed",
		"fixed_seed": FIXED_SEED,
		"ticks": TEST_TICKS,
		"modes": _mode_names(),
		"trace_digests": _trace_digests(runs),
		"failures": failures.duplicate(),
	}
	print("LINGLAN_BOSS_LAYERED_SEMANTICS_JSON %s" % JSON.stringify(result))
	if failures.is_empty():
		print("LINGLAN_BOSS_LAYERED_SEMANTICS_REGRESSION_OK")
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	quit(1)


func _run_mode(simulation_mode: int) -> Dictionary:
	var is_oracle := simulation_mode == PRE_REFACTOR_ORACLE_MODE
	var mode_name := _mode_name(simulation_mode)
	var runtime := RUNTIME_SCENE.instantiate() as EnemyGameplayGatewayTestRuntime
	runtime.runtime_mode = CombatRuntimeBase.RuntimeMode.SINGLEPLAYER
	var coordinator := runtime.get_node(
		"EnemySimulationCoordinator"
	) as EnemySimulationCoordinator
	coordinator.set_mode(
		POLICY.Mode.LEGACY if is_oracle else simulation_mode
	)
	root.add_child(runtime)
	await process_frame

	var source := runtime.get_node(
		"BossContainer/LinglanBoss"
	) as LinglanBossLayeredSemanticHarness
	var source_config := LINGLAN_CONFIG.duplicate(true) as EnemyConfig
	source.set_meta(&"net_id", BOSS_NET_ID)
	source.setup(source_config, null, null, runtime, null)
	runtime.register_network_enemy(BOSS_NET_ID, source)
	_configure_skill_resources(source)
	source.skill3_random.seed = FIXED_SEED
	source.skill4_random.seed = FIXED_SEED + 1
	source.skill_order_random.seed = FIXED_SEED + 2
	source.set_pre_refactor_oracle_active(is_oracle)
	source.set_active(false)

	await physics_frame
	await physics_frame
	_disable_automatic_callbacks(coordinator, source)
	source.reset_semantic_trace()
	_reset_stationary_skill1(source)

	_expect(
		source.supports_layered_area_authoritative_simulation()
		and not source.supports_layered_contact_authoritative_simulation()
		and not source.supports_indexed_touch_authority(),
		"%s Linglan harness must enter layered phases without shared contact."
		% mode_name
	)
	if simulation_mode in [PRE_REFACTOR_ORACLE_MODE, POLICY.Mode.LEGACY]:
		_expect(
			not source.is_centrally_simulated()
			and not source.is_physics_processing(),
			"LEGACY inactive Linglan must remain on its suspended individual runner."
		)
	else:
		_expect(
			source.is_centrally_simulated()
			and coordinator.owns_enemy(source, source.enemy_simulation_token)
			and source.authoritative_simulation_driver
			== Enemy.AuthoritativeSimulationDriver.SCHEDULED_SUSPENDED,
			"%s inactive Linglan must remain coordinator-owned and suspended."
			% mode_name
		)

	var context := {
		"coordinator": coordinator,
		"source": source,
		"simulation_mode": simulation_mode,
		"is_oracle": is_oracle,
		"rollback_applicable": not is_oracle,
		"rollback_restored": simulation_mode == POLICY.Mode.LEGACY,
		"rollback_preserved_state": simulation_mode == POLICY.Mode.LEGACY,
		"rollback_retained_area": simulation_mode == POLICY.Mode.LEGACY,
	}
	var snapshots: Array[Dictionary] = []
	for tick_index in range(1, TEST_TICKS + 1):
		_apply_pre_tick_script(tick_index, context)
		await _advance_one_tick(coordinator, source, is_oracle)
		snapshots.append(_capture_snapshot(tick_index, source))

	_validate_mode_invariants(mode_name, simulation_mode, snapshots, context)
	var run_result := {
		"mode": mode_name,
		"snapshots": snapshots,
		"trace_lines": _canonical_trace_lines(snapshots),
		"rollback_applicable": context["rollback_applicable"],
		"rollback_restored": context["rollback_restored"],
		"rollback_preserved_state": context["rollback_preserved_state"],
		"rollback_retained_area": context["rollback_retained_area"],
	}
	runtime.queue_free()
	await process_frame
	completed_mode_count += 1
	return run_result


func _configure_skill_resources(
	source: LinglanBossLayeredSemanticHarness
) -> void:
	var skill1 := source.skill1_config.duplicate(true) as LinglanSkillConfig
	skill1.start_delay = PHYSICS_DELTA * 2.5
	skill1.attack_speed = 3_000.0
	skill1.fixed_fire_duration = 1.0
	skill1.rotating_fire_duration = 0.0
	source.skill1_config = skill1

	var skill2 := source.skill2_config.duplicate(true) as LinglanSkill2Config
	skill2.move_speed = 120.0
	skill2.arrival_distance = 0.1
	skill2.attack_count = 2
	skill2.attack_interval = 0.1
	skill2.warning_lead_time = 0.04
	source.skill2_config = skill2


func _reset_stationary_skill1(
	source: LinglanBossLayeredSemanticHarness
) -> void:
	source.boss_skill_phase = LinglanBoss.BossSkillPhase.SKILL1
	source.velocity = Vector2.ZERO
	source.skill1_elapsed = 0.0
	source.skill1_fire_time_left = 0.0
	source.skill1_finished = false
	source.skill1_attack_broadcast_sent = false
	source.skill1_warning_broadcast_sent = false


func _configure_skill2_move(
	source: LinglanBossLayeredSemanticHarness,
	target_position: Vector2
) -> void:
	source.call(&"_reset_skill2_state")
	source.skill2_target_global_position = target_position
	source.boss_skill_phase = LinglanBoss.BossSkillPhase.MOVE_TO_SKILL2
	source.velocity = Vector2.ZERO


func _apply_pre_tick_script(
	tick_index: int,
	context: Dictionary
) -> void:
	var coordinator: EnemySimulationCoordinator = context["coordinator"]
	var source: LinglanBossLayeredSemanticHarness = context["source"]
	if tick_index == 3:
		source.set_active(true)
		# Manual stepping owns this regression's exact tick boundary.
		source.set_physics_process(false)
		_reset_stationary_skill1(source)
	elif tick_index == 8:
		_configure_skill2_move(source, Vector2(10.0, 0.0))
	elif tick_index == 14:
		source.set_active(false)
	elif tick_index == 16:
		source.set_active(true)
		source.set_physics_process(false)
		_configure_skill2_move(
			source,
			source.global_position + Vector2(4.0, 0.0)
		)
	elif (
		tick_index == ROLLBACK_TICK
		and not bool(context.get("is_oracle", false))
	):
		var before_rollback := _capture_rollback_state(source)
		if int(context["simulation_mode"]) != POLICY.Mode.LEGACY:
			coordinator.set_mode(POLICY.Mode.LEGACY)
			context["rollback_restored"] = (
				not source.is_centrally_simulated()
				and source.is_physics_processing()
			)
		else:
			context["rollback_restored"] = (
				not source.is_centrally_simulated()
			)
		context["rollback_preserved_state"] = (
			_capture_rollback_state(source) == before_rollback
		)
		context["rollback_retained_area"] = (
			not source.is_indexed_touch_authority_enabled()
			and source.touch_damage_area.monitoring
			and source.touch_damage_area.monitorable
			and not _all_touch_shapes_disabled(source)
		)
		source.set_physics_process(false)
		coordinator.set_physics_process(false)
	elif tick_index == 20:
		_configure_skill2_move(
			source,
			source.global_position + Vector2(2.0, 0.0)
		)


func _advance_one_tick(
	coordinator: EnemySimulationCoordinator,
	source: LinglanBossLayeredSemanticHarness,
	is_oracle: bool
) -> void:
	await physics_frame
	_disable_automatic_callbacks(coordinator, source)
	if is_oracle:
		if source.is_active:
			source.simulate_pre_refactor_authoritative_step(PHYSICS_DELTA)
		source.set_physics_process(false)
		return
	if source.is_centrally_simulated():
		coordinator.call(&"_physics_process", PHYSICS_DELTA)
		coordinator.set_physics_process(false)
		return
	if source.is_active:
		source.call(&"_run_authoritative_physics_step", PHYSICS_DELTA)
	source.set_physics_process(false)


func _disable_automatic_callbacks(
	coordinator: EnemySimulationCoordinator,
	source: LinglanBossLayeredSemanticHarness
) -> void:
	coordinator.set_physics_process(false)
	source.set_process(false)
	source.set_physics_process(false)


func _capture_snapshot(
	tick_index: int,
	source: LinglanBossLayeredSemanticHarness
) -> Dictionary:
	return {
		"tick": tick_index,
		"active": 1 if source.is_active else 0,
		"phase": source.boss_skill_phase,
		"position_x": _quantize(source.global_position.x),
		"position_y": _quantize(source.global_position.y),
		"velocity_x": _quantize(source.velocity.x),
		"velocity_y": _quantize(source.velocity.y),
		"skill1_elapsed": _quantize(source.skill1_elapsed),
		"skill1_fire_left": _quantize(source.skill1_fire_time_left),
		"skill1_finished": 1 if source.skill1_finished else 0,
		"skill2_elapsed": _quantize(source.skill2_elapsed),
		"skill2_spawn_ticks": source.skill2_spawn_ticks_completed,
		"skill2_shots": source.skill2_shots_fired,
		"action_sequence": source.action_sequence,
		"action_log": "|".join(source.action_log),
		"action_phase_log": "|".join(source.action_phase_log),
		"ring_log": "|".join(source.ring_log),
		"movement_log": "|".join(source.movement_log),
		"movement_submissions": source.movement_log.size(),
		"touch_updates": source.touch_update_deltas.size(),
		"warning_updates": source.warning_update_count,
		"warning_clears": source.warning_clear_count,
		"skill2_spawn_requests": source.skill2_spawn_request_count,
		"skill2_warning_spawns": source.skill2_warning_spawn_count,
		"skill2_warning_updates": source.skill2_warning_update_count,
		"skill2_fires": source.skill2_fire_count,
		"event_order": "|".join(source.event_order_log),
		"animation": String(source.animated_sprite.animation),
		"skill3_rng": source.skill3_random.state,
		"skill4_rng": source.skill4_random.state,
		"skill_order_rng": source.skill_order_random.state,
		"central_owned": 1 if source.is_centrally_simulated() else 0,
		"driver": source.authoritative_simulation_driver,
		"indexed_touch": (
			1 if source.is_indexed_touch_authority_enabled() else 0
		),
		"touch_area_monitoring": (
			1 if source.touch_damage_area.monitoring else 0
		),
		"touch_area_monitorable": (
			1 if source.touch_damage_area.monitorable else 0
		),
		"touch_shapes_disabled": (
			1 if _all_touch_shapes_disabled(source) else 0
		),
	}


func _capture_rollback_state(
	source: LinglanBossLayeredSemanticHarness
) -> Dictionary:
	return {
		"active": source.is_active,
		"phase": source.boss_skill_phase,
		"position": source.global_position,
		"velocity": source.velocity,
		"skill1_elapsed": source.skill1_elapsed,
		"skill2_elapsed": source.skill2_elapsed,
		"skill2_spawn_ticks": source.skill2_spawn_ticks_completed,
		"skill2_shots": source.skill2_shots_fired,
		"action_sequence": source.action_sequence,
		"action_log": source.action_log.duplicate(),
		"ring_log": source.ring_log.duplicate(),
		"skill3_rng": source.skill3_random.state,
		"skill4_rng": source.skill4_random.state,
		"skill_order_rng": source.skill_order_random.state,
	}


func _validate_mode_invariants(
	mode_name: String,
	simulation_mode: int,
	snapshots: Array[Dictionary],
	context: Dictionary
) -> void:
	_expect(
		snapshots.size() == TEST_TICKS,
		"%s must capture every Linglan tick." % mode_name
	)
	if snapshots.size() != TEST_TICKS:
		return
	for tick_number in [1, 2, 14, 15]:
		var inactive_snapshot: Dictionary = snapshots[tick_number - 1]
		_expect(
			int(inactive_snapshot["active"]) == 0
			and int(inactive_snapshot["touch_area_monitoring"]) == 0
			and int(inactive_snapshot["touch_area_monitorable"]) == 0
			and int(inactive_snapshot["touch_shapes_disabled"]) == 1,
			"%s inactive tick %d must suspend simulation and authored contact."
			% [mode_name, tick_number]
		)
	for tick_number in [3, 8, 12, 13, 16, 17]:
		var active_snapshot: Dictionary = snapshots[tick_number - 1]
		_expect(
			int(active_snapshot["active"]) == 1
			and int(active_snapshot["indexed_touch"]) == 0
			and int(active_snapshot["touch_area_monitoring"]) == 1
			and int(active_snapshot["touch_area_monitorable"]) == 1
			and int(active_snapshot["touch_shapes_disabled"]) == 0,
			"%s active tick %d must retain the Boss TouchDamageArea."
			% [mode_name, tick_number]
		)
	_expect(
		int(snapshots[1]["touch_updates"]) == 0
		and int(snapshots[2]["touch_updates"]) == 1
		and int(snapshots[12]["touch_updates"]) == 11
		and int(snapshots[14]["touch_updates"]) == 11
		and int(snapshots[-1]["touch_updates"]) == 19,
		"%s inactive/resumed Linglan must advance event clocks on exactly 19 ticks."
		% mode_name
	)
	_expect(
		int(snapshots[2]["phase"]) == LinglanBoss.BossSkillPhase.SKILL1
		and int(snapshots[4]["action_sequence"]) == 1
		and String(snapshots[6]["ring_log"]).begins_with("ring:0|")
		and String(snapshots[6]["ring_log"]).split("|").size() == 2,
		"%s stationary Skill1 must preserve warning, attack and ring boundaries."
		% mode_name
	)
	var expected_move_positions := [2, 4, 6, 8, 10]
	for index in range(expected_move_positions.size()):
		var move_snapshot: Dictionary = snapshots[7 + index]
		_expect(
			int(move_snapshot["position_x"])
			== expected_move_positions[index] * 1_000_000,
			"%s Skill2 movement position mismatch at tick %d."
			% [mode_name, 8 + index]
		)
	_expect(
		int(snapshots[11]["phase"]) == LinglanBoss.BossSkillPhase.SKILL2
		and int(snapshots[11]["velocity_x"]) == 0
		and int(snapshots[11]["action_sequence"]) == 2,
		"%s movement arrival must commit Skill2 in the same motion tick."
		% mode_name
	)
	_expect(
		int(snapshots[13]["active"]) == 0
		and int(snapshots[13]["phase"]) == LinglanBoss.BossSkillPhase.SKILL1
		and int(snapshots[13]["action_sequence"]) == 0
		and int(snapshots[13]["skill1_elapsed"]) == 0,
		"%s deactivation must suspend and reset the authored Boss skill state."
		% mode_name
	)
	_expect(
		int(snapshots[15]["position_x"]) == 12_000_000
		and int(snapshots[16]["position_x"]) == 14_000_000
		and int(snapshots[16]["phase"])
		== LinglanBoss.BossSkillPhase.SKILL2,
		"%s activation must resume ownership and preserve 60 Hz movement."
		% mode_name
	)
	var expected_actions := (
		"1:linglan_skill1_attack:0:0|"
		+ "2:linglan_skill2_attack:0:0|"
		+ "1:linglan_skill2_attack:0:0|"
		+ "2:linglan_skill2_attack:0:0"
	)
	var final_snapshot: Dictionary = snapshots[-1]
	_expect(
		String(final_snapshot["action_log"]) == expected_actions
		and int(final_snapshot["position_x"]) == 16_000_000
		and int(final_snapshot["movement_submissions"]) == 5
		and int(final_snapshot["skill2_spawn_requests"]) == 3
		and int(final_snapshot["skill2_warning_spawns"]) == 3
		and int(final_snapshot["skill2_warning_updates"]) == 6
		and int(final_snapshot["skill2_fires"]) == 1,
		"%s action/timer/movement order must match the authored deterministic script."
		% mode_name
	)
	if not bool(context.get("is_oracle", false)):
		_expect(
			bool(context["rollback_restored"])
			and bool(context["rollback_preserved_state"])
			and bool(context["rollback_retained_area"]),
			"%s rollback must preserve live Boss state and authored Area authority."
			% mode_name
		)
		_expect(
			int(snapshots[ROLLBACK_TICK - 2]["central_owned"])
			== (0 if simulation_mode == POLICY.Mode.LEGACY else 1)
			and int(snapshots[ROLLBACK_TICK - 1]["central_owned"]) == 0,
			"%s rollback must transfer ownership exactly at tick %d."
			% [mode_name, ROLLBACK_TICK]
		)
	var source: LinglanBossLayeredSemanticHarness = context["source"]
	if simulation_mode == PRE_REFACTOR_ORACLE_MODE:
		_expect(
			_all_action_phases_equal(source, &"oracle")
			and _all_ring_phases_equal(source, &"oracle"),
			"PRE_REFACTOR_ORACLE 必须仅执行冻结的旧 physics 状态机。"
		)
	elif simulation_mode in [
		POLICY.Mode.LAYERED_AREA,
		POLICY.Mode.LAYERED_CONTACT,
	]:
		_expect(
			"linglan_skill1_attack:event" in source.action_phase_log
			and (
				"linglan_skill2_attack:motion" in source.action_phase_log
			)
			and String(source.action_phase_log[-1])
			== "linglan_skill2_attack:legacy"
			and _all_ring_phases_equal(source, &"event"),
			"%s must commit stationary events, motion arrivals and post-rollback actions in their exact phases."
			% mode_name
		)
	else:
		_expect(
			_all_action_phases_equal(source, &"legacy")
			and _all_ring_phases_equal(source, &"legacy"),
			"%s must retain the complete authored runner before layering."
			% mode_name
		)
	if simulation_mode == POLICY.Mode.LAYERED_CONTACT:
		for tick_number in range(3, ROLLBACK_TICK):
			if tick_number in [14, 15]:
				continue
			var contact_snapshot: Dictionary = snapshots[tick_number - 1]
			_expect(
				int(contact_snapshot["indexed_touch"]) == 0
				and int(contact_snapshot["touch_area_monitoring"]) == 1
				and int(contact_snapshot["touch_shapes_disabled"]) == 0,
				"LAYERED_CONTACT must retain Boss Area authority at tick %d."
				% tick_number
			)


func _all_action_phases_equal(
	source: LinglanBossLayeredSemanticHarness,
	expected_phase: StringName
) -> bool:
	for record in source.action_phase_log:
		if String(record).begins_with("ring:"):
			continue
		var parts := String(record).split(":")
		if parts.size() != 2 or StringName(parts[1]) != expected_phase:
			return false
	return true


func _all_ring_phases_equal(
	source: LinglanBossLayeredSemanticHarness,
	expected_phase: StringName
) -> bool:
	var ring_count := 0
	for record in source.action_phase_log:
		if not String(record).begins_with("ring:"):
			continue
		ring_count += 1
		var parts := String(record).split(":")
		if parts.size() != 2 or StringName(parts[1]) != expected_phase:
			return false
	return ring_count == 2


func _compare_mode_traces(runs: Dictionary) -> void:
	var oracle_run: Dictionary = runs.get(PRE_REFACTOR_ORACLE_MODE, {})
	var oracle_snapshots: Array = oracle_run.get("snapshots", [])
	for comparison_mode in TEST_MODES:
		var mode_name := POLICY.mode_to_name(comparison_mode)
		var comparison_run: Dictionary = runs.get(comparison_mode, {})
		var comparison_snapshots: Array = comparison_run.get("snapshots", [])
		if comparison_snapshots.size() != oracle_snapshots.size():
			failures.append(
				"%s trace 长度与迁移前 oracle 不同。" % mode_name
			)
			continue
		for tick_index in range(oracle_snapshots.size()):
			var oracle_snapshot: Dictionary = oracle_snapshots[tick_index]
			var comparison_snapshot: Dictionary = comparison_snapshots[tick_index]
			for field_name in GAMEPLAY_FIELDS:
				if oracle_snapshot.get(field_name) == comparison_snapshot.get(field_name):
					continue
				failures.append(
					"%s 在 tick %d 字段 %s 偏离：oracle=%s actual=%s"
					% [
						mode_name,
						tick_index + 1,
						field_name,
						str(oracle_snapshot.get(field_name)),
						str(comparison_snapshot.get(field_name)),
					]
				)


func _canonical_trace_lines(snapshots: Array[Dictionary]) -> PackedStringArray:
	var lines := PackedStringArray()
	for snapshot in snapshots:
		var values := PackedStringArray()
		for field_name in GAMEPLAY_FIELDS:
			values.append("%s=%s" % [field_name, str(snapshot.get(field_name))])
		lines.append(";".join(values))
	return lines


func _trace_digests(runs: Dictionary) -> Dictionary:
	var digests := {}
	for simulation_mode in ALL_RUN_MODES:
		var run_result: Dictionary = runs.get(simulation_mode, {})
		var lines: PackedStringArray = run_result.get(
			"trace_lines",
			PackedStringArray()
		)
		digests[_mode_name(simulation_mode)] = _sha256_lines(lines)
	return digests


func _sha256_lines(lines: PackedStringArray) -> String:
	var hashing := HashingContext.new()
	hashing.start(HashingContext.HASH_SHA256)
	hashing.update("\n".join(lines).to_utf8_buffer())
	return hashing.finish().hex_encode()


func _mode_names() -> PackedStringArray:
	var names := PackedStringArray()
	for simulation_mode in ALL_RUN_MODES:
		names.append(_mode_name(simulation_mode))
	return names


func _mode_name(simulation_mode: int) -> String:
	return (
		"PRE_REFACTOR_ORACLE"
		if simulation_mode == PRE_REFACTOR_ORACLE_MODE
		else POLICY.mode_to_name(simulation_mode)
	)


func _all_touch_shapes_disabled(
	source: LinglanBossLayeredSemanticHarness
) -> bool:
	if source.touch_damage_shapes.is_empty():
		return false
	for shape in source.touch_damage_shapes:
		if shape != null and is_instance_valid(shape) and not shape.disabled:
			return false
	return true


func _quantize(value: float) -> int:
	return roundi(value * 1_000_000.0)


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
