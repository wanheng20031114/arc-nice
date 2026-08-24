extends SceneTree

## Four-policy per-tick semantic replay for the main-battle robot. The trace
## covers chase motion, normal attack, skill-1 dash/circle, skill-2 tracking/drop,
## faction-invalid cancellation and a mid-action rollback to LEGACY.

const POLICY := preload(
	"res://scene/combat/simulation/enemy_simulation_policy.gd"
)
const RUNTIME_SCENE := preload(
	"res://dev_tools/fixtures/combat_robot_main_battle_layered_semantic_runtime.tscn"
)
const MAIN_CONFIG := preload(
	"res://resources/config/enemies/combat_robot_main_battle_elite.tres"
)
const TARGET_CONFIG := preload(
	"res://resources/config/enemies/yuanshi_insect_basic.tres"
)

const PHYSICS_DELTA := 1.0 / 60.0
const TEST_TICKS := 36
const ROLLBACK_TICK := 30
const FIXED_SEED := 20_260_824
const SOURCE_NET_ID := 97_001
const TARGET_NET_ID := 97_002
const PRE_REFACTOR_ORACLE_MODE := -1
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
	"state_time",
	"attack_cooldown",
	"skill1_cooldown",
	"skill2_cooldown",
	"locked_x",
	"locked_y",
	"skill1_locked_x",
	"skill1_locked_y",
	"skill2_target_x",
	"skill2_target_y",
	"committed_target",
	"airborne",
	"action_damage_done",
	"action_sequence",
	"action_log",
	"shape_damage_count",
	"touch_updates",
	"contact_queries",
	"chase_motion_count",
	"skill1_motion_count",
	"skill2_motion_count",
	"touch_monitoring",
	"touch_monitorable",
	"enabled_touch_shapes",
	"behavior_rng",
	"drop_rng",
]

var failures: Array[String] = []
var completed_mode_count := 0


func _init() -> void:
	call_deferred(&"_run")


func _run() -> void:
	var runs: Dictionary = {}
	runs[PRE_REFACTOR_ORACLE_MODE] = await _run_mode(
		PRE_REFACTOR_ORACLE_MODE
	)
	_validate_frozen_oracle_semantics(
		runs[PRE_REFACTOR_ORACLE_MODE]
	)
	for simulation_mode in TEST_MODES:
		runs[simulation_mode] = await _run_mode(simulation_mode)
	_expect(
		completed_mode_count == TEST_MODES.size() + 1,
		"迁移前 oracle 与四种主战机甲策略必须全部抵达完成哨兵。"
	)
	_compare_mode_traces(runs)

	var result := {
		"status": "ok" if failures.is_empty() else "failed",
		"fixed_seed": FIXED_SEED,
		"ticks": TEST_TICKS,
		"modes": _mode_names(),
		"trace_digests": _trace_digests(runs),
		"oracle_evidence": _oracle_evidence(
			runs.get(PRE_REFACTOR_ORACLE_MODE, {})
		),
		"failures": failures.duplicate(),
	}
	print("COMBAT_ROBOT_MAIN_BATTLE_LAYERED_SEMANTICS_JSON %s" % JSON.stringify(result))
	if failures.is_empty():
		print("COMBAT_ROBOT_MAIN_BATTLE_LAYERED_SEMANTICS_REGRESSION_OK")
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
	coordinator.set_physics_process(false)

	var source: Variant = runtime.get_node("EnemyContainer/MainBattleSource")
	var target := runtime.get_node("EnemyContainer/Target") as Enemy
	var source_config := MAIN_CONFIG.duplicate(true) as CombatRobotMainBattleEliteConfig
	_configure_source_config(source_config)
	_setup_enemy(source, source_config, runtime, SOURCE_NET_ID)
	_setup_target(target, runtime, TARGET_NET_ID)
	target.set_authoritative_simulation_enabled(false)
	_disable_automatic_callbacks(coordinator, source, [target])
	_reset_source(source, target)

	_expect(
		source.supports_layered_area_authoritative_simulation()
		and not source.supports_layered_contact_authoritative_simulation(),
		"%s 必须使用生产主战机甲的 AREA-only 能力边界。" % mode_name
	)
	if is_oracle or simulation_mode == POLICY.Mode.LEGACY:
		_expect(
			not source.is_centrally_simulated(),
			"LEGACY 必须保留主战机甲个体 runner。"
		)
	else:
		_expect(
			source.is_centrally_simulated()
			and coordinator.owns_enemy(source, source.enemy_simulation_token),
			"%s 必须由统一协调器持有主战机甲。" % mode_name
		)

	var contact_service := runtime.get_enemy_contact_service()
	var context := {
		"source": source,
		"target": target,
		"coordinator": coordinator,
		"contact_service": contact_service,
		"rollback_preserved": simulation_mode == POLICY.Mode.LEGACY,
		"rollback_restored": simulation_mode == POLICY.Mode.LEGACY,
		"area_retained": true,
	}
	var snapshots: Array[Dictionary] = []
	for tick_index in range(1, TEST_TICKS + 1):
		_apply_pre_tick_script(tick_index, context)
		await _advance_one_tick(coordinator, source, [target], is_oracle)
		context["area_retained"] = bool(context["area_retained"]) and (
			not contact_service.owns_enemy(source)
			and not source.is_indexed_touch_authority_enabled()
		)
		snapshots.append(_capture_snapshot(tick_index, source, target))
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
				and not contact_service.owns_enemy(source)
				and source.touch_damage_area.monitoring
				and _count_enabled_touch_shapes(source) == 1
			)
			source.set_physics_process(false)
			coordinator.set_physics_process(false)

	_validate_mode_invariants(
		mode_name,
		simulation_mode,
		is_oracle,
		snapshots,
		context
	)
	var result := {
		"mode": mode_name,
		"snapshots": snapshots,
		"trace_lines": _canonical_trace_lines(snapshots),
		"rollback_preserved": context["rollback_preserved"],
		"rollback_restored": context["rollback_restored"],
		"area_retained": context["area_retained"],
	}
	runtime.queue_free()
	await process_frame
	completed_mode_count += 1
	return result


func _configure_source_config(config: CombatRobotMainBattleEliteConfig) -> void:
	config.move_speed = 60.0
	config.attack_range = 64.0
	config.attack_windup = PHYSICS_DELTA * 2.0
	config.attack_damage_delay = PHYSICS_DELTA
	config.attack_slash_duration = PHYSICS_DELTA * 3.0
	config.attack_cooldown = PHYSICS_DELTA * 20.0
	config.skill1_initial_delay = PHYSICS_DELTA * 60.0
	config.skill1_trigger_range = 64.0
	config.skill1_windup = PHYSICS_DELTA * 2.0
	config.skill1_dash_speed = 60.0
	config.skill1_dash_duration = PHYSICS_DELTA * 3.0
	config.skill1_recovery = PHYSICS_DELTA * 2.0
	config.skill1_cooldown = PHYSICS_DELTA * 30.0
	config.skill2_initial_delay = PHYSICS_DELTA * 60.0
	config.skill2_trigger_range = 64.0
	config.skill2_takeoff_duration = PHYSICS_DELTA * 2.0
	config.skill2_tracking_duration = PHYSICS_DELTA * 3.0
	config.skill2_cross_speed = 120.0
	config.skill2_drop_duration = PHYSICS_DELTA
	config.skill2_recovery = PHYSICS_DELTA * 2.0
	config.skill2_cooldown = PHYSICS_DELTA * 30.0
	config.drop_table = null
	config.xirang_kill_reward = 0
	config.move_stomp_audio_stream_a = null
	config.move_stomp_audio_stream_b = null
	config.hit_audio_stream_a = null
	config.hit_audio_stream_b = null
	config.attack_windup_audio_stream = null
	config.attack_slash_audio_stream = null
	config.skill1_charge_audio_stream = null
	config.skill1_dash_audio_stream = null
	config.skill1_circle_slash_audio_stream = null
	config.skill2_takeoff_audio_stream = null
	config.skill2_drop_audio_stream = null
	config.death_audio_stream = null


func _reset_source(source: Variant, target: Enemy) -> void:
	source.global_position = Vector2.ZERO
	source.velocity = Vector2.ZERO
	source.combat_state = CombatRobotMainBattleElite.CombatState.CHASE
	source.state_time_left = 0.0
	source.attack_cooldown_left = PHYSICS_DELTA * 60.0
	source.skill1_cooldown_left = PHYSICS_DELTA * 60.0
	source.skill2_cooldown_left = PHYSICS_DELTA * 60.0
	source.committed_target = null
	source.action_damage_source_snapshot = null
	source.action_damage_done = false
	source.airborne = false
	source.locked_direction = Vector2.RIGHT
	source.skill1_locked_position = Vector2.ZERO
	source.skill2_last_target_position = target.global_position
	source.skill2_last_tracking_direction = Vector2.RIGHT
	source.layered_event_start_state = source.combat_state
	source.layered_motion_state = source.combat_state
	source.layered_motion_due = false
	source.layered_area_motion_phase_due = false
	source.forced_target = target
	source.forced_target_valid = true
	source.forced_target_in_range = true
	source.forced_move_direction = Vector2.RIGHT
	source.forced_contact = false
	source.semantic_tick = 0
	source.reset_semantic_trace()
	source.random_generator.seed = FIXED_SEED
	source.material_drop_random_generator.seed = FIXED_SEED + 1
	source.set_objective_target(target)
	source.request_layered_area_urgent_decision()


func _apply_pre_tick_script(tick_index: int, context: Dictionary) -> void:
	var source: Variant = context["source"]
	var target: Enemy = context["target"]
	source.semantic_tick = tick_index
	match tick_index:
		2:
			source.attack_cooldown_left = 0.0
			source.skill1_cooldown_left = PHYSICS_DELTA * 60.0
			source.skill2_cooldown_left = PHYSICS_DELTA * 60.0
			source.request_layered_area_urgent_decision()
		8:
			target.global_position = Vector2(7.0, 0.0)
			source.attack_cooldown_left = PHYSICS_DELTA * 60.0
			source.skill1_cooldown_left = 0.0
			source.skill2_cooldown_left = PHYSICS_DELTA * 60.0
			source.request_layered_area_urgent_decision()
		16:
			target.global_position = Vector2(14.0, 0.0)
			source.attack_cooldown_left = PHYSICS_DELTA * 60.0
			source.skill1_cooldown_left = PHYSICS_DELTA * 60.0
			source.skill2_cooldown_left = 0.0
			source.request_layered_area_urgent_decision()
		26:
			source.forced_contact = true
			source.attack_cooldown_left = 0.0
			source.skill1_cooldown_left = PHYSICS_DELTA * 60.0
			source.skill2_cooldown_left = PHYSICS_DELTA * 60.0
			source.request_layered_area_urgent_decision()
		27:
			source.forced_contact = false
			target.set_combat_faction_id(
				CombatRelationService.HOSTILE_WAVE,
				2,
				true
			)
		28:
			target.set_combat_faction_id(
				CombatRelationService.PLAYER_ALLIED,
				3,
				true
			)
			source.request_layered_area_urgent_decision()


func _advance_one_tick(
	coordinator: EnemySimulationCoordinator,
	source: Variant,
	other_nodes: Array,
	is_oracle: bool
) -> void:
	await physics_frame
	_disable_automatic_callbacks(coordinator, source, other_nodes)
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
	target: Enemy
) -> Dictionary:
	return {
		"tick": tick_index,
		"state": source.combat_state,
		"position_x": _quantize(source.global_position.x),
		"position_y": _quantize(source.global_position.y),
		"velocity_x": _quantize(source.velocity.x),
		"velocity_y": _quantize(source.velocity.y),
		"state_time": _quantize(source.state_time_left),
		"attack_cooldown": _quantize(source.attack_cooldown_left),
		"skill1_cooldown": _quantize(source.skill1_cooldown_left),
		"skill2_cooldown": _quantize(source.skill2_cooldown_left),
		"locked_x": _quantize(source.locked_direction.x),
		"locked_y": _quantize(source.locked_direction.y),
		"skill1_locked_x": _quantize(source.skill1_locked_position.x),
		"skill1_locked_y": _quantize(source.skill1_locked_position.y),
		"skill2_target_x": _quantize(source.skill2_last_target_position.x),
		"skill2_target_y": _quantize(source.skill2_last_target_position.y),
		"committed_target": 1 if source.committed_target == target else 0,
		"airborne": 1 if source.airborne else 0,
		"action_damage_done": 1 if source.action_damage_done else 0,
		"action_sequence": source.action_sequence,
		"action_log": source.action_log.duplicate(),
		"action_phase_log": source.action_phase_log.duplicate(),
		"shape_damage_count": source.shape_damage_count,
		"touch_updates": source.touch_update_count,
		"contact_queries": source.contact_query_count,
		"chase_motion_count": source.chase_motion_count,
		"skill1_motion_count": source.skill1_motion_count,
		"skill2_motion_count": source.skill2_motion_count,
		"touch_monitoring": 1 if source.touch_damage_area.monitoring else 0,
		"touch_monitorable": 1 if source.touch_damage_area.monitorable else 0,
		"enabled_touch_shapes": _count_enabled_touch_shapes(source),
		"behavior_rng": source.random_generator.state,
		"drop_rng": source.material_drop_random_generator.state,
	}


func _capture_rollback_state(source: Variant) -> Dictionary:
	return {
		"state": source.combat_state,
		"position": source.global_position,
		"velocity": source.velocity,
		"state_time": source.state_time_left,
		"attack_cooldown": source.attack_cooldown_left,
		"skill1_cooldown": source.skill1_cooldown_left,
		"skill2_cooldown": source.skill2_cooldown_left,
		"committed_target": source.committed_target,
		"damage_snapshot": source.action_damage_source_snapshot,
		"action_sequence": source.action_sequence,
		"action_log": source.action_log.duplicate(),
		"shape_damage_count": source.shape_damage_count,
		"airborne": source.airborne,
	}


func _validate_mode_invariants(
	mode_name: String,
	simulation_mode: int,
	is_oracle: bool,
	snapshots: Array[Dictionary],
	context: Dictionary
) -> void:
	_expect(
		snapshots.size() == TEST_TICKS,
		"%s 必须采集全部 %d tick。" % [mode_name, TEST_TICKS]
	)
	if snapshots.size() != TEST_TICKS:
		return
	var last: Dictionary = snapshots.back()
	if not is_oracle:
		_expect(
			bool(context["rollback_preserved"])
			and bool(context["rollback_restored"]),
			"%s 必须在动作中途无损回退至 LEGACY 个体 runner。" % mode_name
		)
	_expect(
		bool(context["area_retained"]),
		"%s 不得让共享接触服务接管 Boss 的 authored Area。" % mode_name
	)
	var expected_start_phase := (
		"oracle"
		if is_oracle
		else (
			"decision"
			if simulation_mode in [
				POLICY.Mode.LAYERED_AREA,
				POLICY.Mode.LAYERED_CONTACT,
			]
			else "compat"
		)
	)
	var phase_log: Array = last["action_phase_log"]
	_expect(
		phase_log.size() == 9
		and String(phase_log[0]).ends_with(":" + expected_start_phase)
		and String(phase_log[2]).ends_with(":" + expected_start_phase)
		and String(phase_log[5]).ends_with(":" + expected_start_phase)
		and String(phase_log[7]).ends_with(":" + expected_start_phase),
		"%s 新动作只能由兼容 runner 或分层 decision 相位提交。" % mode_name
	)


func _validate_frozen_oracle_semantics(run: Dictionary) -> void:
	var snapshots: Array = run.get("snapshots", [])
	_expect(
		snapshots.size() == TEST_TICKS,
		"冻结 oracle 必须采集完整主战机甲场景。"
	)
	if snapshots.size() != TEST_TICKS:
		return
	var last: Dictionary = snapshots.back()
	var action_log: Array = last["action_log"]
	_expect(
		action_log.size() == 9
		and String(action_log[0]).contains("main_battle_attack_windup")
		and String(action_log[1]).contains("main_battle_attack_slash")
		and String(action_log[2]).contains("main_battle_skill1_windup")
		and String(action_log[3]).contains("main_battle_skill1_dash")
		and String(action_log[4]).contains("main_battle_skill1_circle")
		and String(action_log[5]).contains("main_battle_skill2_takeoff")
		and String(action_log[6]).contains("main_battle_skill2_drop")
		and String(action_log[7]).contains("main_battle_attack_windup")
		and String(action_log[8]).contains("main_battle_attack_slash"),
		"冻结 oracle 必须自证普通攻击、两技能与阵营恢复后重试的动作顺序。"
	)
	_expect(
		int(last["shape_damage_count"]) == 4
		and int(last["chase_motion_count"]) == 3
		and int(last["skill1_motion_count"]) == 4
		and int(last["skill2_motion_count"]) == 4,
		"冻结 oracle 必须自证三类命中与 CHASE/S1/S2 的 60Hz 运动提交。"
	)
	_expect(
		int(snapshots[10]["state"])
		== CombatRobotMainBattleElite.CombatState.SKILL1_DASH
		and int(snapshots[10]["skill1_motion_count"])
		== int(snapshots[9]["skill1_motion_count"])
		and int(snapshots[19]["state"])
		== CombatRobotMainBattleElite.CombatState.SKILL2_TRACK
		and int(snapshots[19]["skill2_motion_count"])
		== int(snapshots[18]["skill2_motion_count"]),
		"冻结 oracle 必须自证状态转换 tick 不提前执行新状态运动。"
	)
	_expect(
		int(snapshots[25]["contact_queries"])
		== int(snapshots[24]["contact_queries"]),
		"冻结 oracle 的动作成功 tick 必须先早退，不提前执行接触选择器。"
	)
	_expect(
		int(snapshots[26]["state"])
		== CombatRobotMainBattleElite.CombatState.CHASE
		and int(snapshots[26]["chase_motion_count"])
		== int(snapshots[25]["chase_motion_count"]),
		"冻结 oracle 的阵营失效取消 tick 必须完整消耗。"
	)
	var saw_airborne_area_disabled := false
	var saw_grounded_area_restored := false
	for snapshot_variant in snapshots:
		var snapshot: Dictionary = snapshot_variant
		if (
			int(snapshot["airborne"]) == 1
			and int(snapshot["touch_monitoring"]) == 0
			and int(snapshot["touch_monitorable"]) == 0
			and int(snapshot["enabled_touch_shapes"]) == 0
		):
			saw_airborne_area_disabled = true
		elif (
			saw_airborne_area_disabled
			and int(snapshot["airborne"]) == 0
			and int(snapshot["touch_monitoring"]) == 1
			and int(snapshot["touch_monitorable"]) == 1
			and int(snapshot["enabled_touch_shapes"]) == 1
		):
			saw_grounded_area_restored = true
	_expect(
		bool(run.get("area_retained", false))
		and saw_airborne_area_disabled
		and saw_grounded_area_restored,
		(
			"冻结 oracle 必须自证 authored TouchDamageArea 在腾空时关闭、"
			+ "落地后恢复，且从未被共享接触服务接管。"
		)
	)


func _compare_mode_traces(runs: Dictionary) -> void:
	var baseline: Dictionary = runs.get(PRE_REFACTOR_ORACLE_MODE, {})
	var baseline_snapshots: Array = baseline.get("snapshots", [])
	for simulation_mode in TEST_MODES:
		var run: Dictionary = runs.get(simulation_mode, {})
		var snapshots: Array = run.get("snapshots", [])
		var mode_name := POLICY.mode_to_name(simulation_mode)
		if snapshots.size() != baseline_snapshots.size():
			failures.append("%s trace 长度与迁移前 oracle 不同。" % mode_name)
			continue
		var mismatch_count := 0
		for tick_index in range(snapshots.size()):
			var actual: Dictionary = snapshots[tick_index]
			var expected: Dictionary = baseline_snapshots[tick_index]
			for field_name in GAMEPLAY_FIELDS:
				if actual.get(field_name) == expected.get(field_name):
					continue
				failures.append(
					"%s 在 tick %d 字段 %s 偏离：oracle=%s actual=%s"
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


func _oracle_evidence(run: Dictionary) -> Dictionary:
	var snapshots: Array = run.get("snapshots", [])
	if snapshots.is_empty():
		return {}
	var transitions: Array[String] = []
	var previous_state := -1
	for snapshot_variant in snapshots:
		var snapshot: Dictionary = snapshot_variant
		var current_state := int(snapshot.get("state", -1))
		if current_state == previous_state:
			continue
		transitions.append(
			"%d:%d" % [int(snapshot.get("tick", 0)), current_state]
		)
		previous_state = current_state
	var last: Dictionary = snapshots.back()
	return {
		"transitions": transitions,
		"action_log": last.get("action_log", []),
		"action_phase_log": last.get("action_phase_log", []),
		"shape_damage_count": last.get("shape_damage_count", 0),
		"touch_updates": last.get("touch_updates", 0),
		"contact_queries": last.get("contact_queries", 0),
		"chase_motion_count": last.get("chase_motion_count", 0),
		"skill1_motion_count": last.get("skill1_motion_count", 0),
		"skill2_motion_count": last.get("skill2_motion_count", 0),
		"rollback_preserved": run.get("rollback_preserved", false),
		"rollback_restored": run.get("rollback_restored", false),
		"area_retained": run.get("area_retained", false),
	}


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
	var modes_with_oracle: Array[int] = [PRE_REFACTOR_ORACLE_MODE]
	modes_with_oracle.append_array(TEST_MODES)
	for simulation_mode in modes_with_oracle:
		var run: Dictionary = runs.get(simulation_mode, {})
		var lines: PackedStringArray = run.get(
			"trace_lines",
			PackedStringArray()
		)
		result[_mode_name(simulation_mode)] = (
			"\n".join(lines).sha256_text()
		)
	return result


func _mode_names() -> PackedStringArray:
	var result := PackedStringArray()
	result.append(_mode_name(PRE_REFACTOR_ORACLE_MODE))
	for simulation_mode in TEST_MODES:
		result.append(POLICY.mode_to_name(simulation_mode))
	return result


func _mode_name(simulation_mode: int) -> String:
	if simulation_mode == PRE_REFACTOR_ORACLE_MODE:
		return "PRE_REFACTOR_ORACLE"
	return POLICY.mode_to_name(simulation_mode)


func _quantize(value: float) -> int:
	return roundi(value * 1_000_000.0)


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
