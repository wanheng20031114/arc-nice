extends SceneTree

## Production-cadence proof for the main-battle split. Unlike the four-mode
## golden, this fixture runs a real four-frame decision bucket and verifies that
## motion remains 60 Hz, urgent target work is not swallowed, moving skill
## states survive decision gaps, and certified stationary ticks submit nothing.

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
const SOURCE_NET_ID := 97_101
const TARGET_NET_ID := 97_102
const SCHEDULED_BUCKET_TICKS: Array[int] = [1, 5, 9, 13, 17]
const OFF_PHASE_URGENT_TICKS: Array[int] = [2, 16, 18, 19]
const EXPECTED_REFRESH_TICKS: Array[int] = [1, 2, 5, 16, 17, 18, 19]

var failures: Array[String] = []


func _init() -> void:
	call_deferred(&"_run")


func _run() -> void:
	var runtime := RUNTIME_SCENE.instantiate() as EnemyGameplayGatewayTestRuntime
	runtime.runtime_mode = CombatRuntimeBase.RuntimeMode.SINGLEPLAYER
	var coordinator := runtime.get_node(
		"EnemySimulationCoordinator"
	) as EnemySimulationCoordinator
	coordinator.set_mode(POLICY.Mode.COMPAT_60)
	root.add_child(runtime)
	coordinator.set_physics_process(false)

	var source: Variant = runtime.get_node("EnemyContainer/MainBattleSource")
	var target := runtime.get_node("EnemyContainer/Target") as Enemy
	var source_config := MAIN_CONFIG.duplicate(true) as CombatRobotMainBattleEliteConfig
	_configure_source_config(source_config)
	_setup_enemy(source, source_config, runtime, SOURCE_NET_ID)
	_setup_target(target, runtime, TARGET_NET_ID)
	target.set_authoritative_simulation_enabled(false)
	_disable_automatic_callbacks(coordinator, source, target)

	# Registration captures cadence on layered admission. Align the first manual
	# tick to a due bucket, then switch atomically from COMPAT into AREA.
	source.force_every_tick_combat_sense = false
	source.combat_sense_update_interval_frames = 4
	var first_manual_physics_frame := Engine.get_physics_frames() + 1
	source.navigation_update_frame_offset = posmod(
		-first_manual_physics_frame,
		4
	)
	coordinator.set_mode(POLICY.Mode.LAYERED_AREA)
	coordinator.set_physics_process(false)
	_reset_source(source, target)

	var snapshots: Array[Dictionary] = []
	for tick_index in range(1, 20):
		_apply_pre_tick_script(tick_index, source, target)
		await _advance_one_tick(coordinator, source, target)
		snapshots.append(_capture_snapshot(tick_index, source))

	var decision_ticks: Array = source.decision_phase_ticks
	var refresh_ticks: Array = source.dynamic_refresh_ticks
	_expect(
		_ticks_occur_exactly_once(decision_ticks, SCHEDULED_BUCKET_TICKS)
		and _ticks_occur_exactly_once(decision_ticks, OFF_PHASE_URGENT_TICKS)
		and decision_ticks.size()
		== SCHEDULED_BUCKET_TICKS.size() + OFF_PHASE_URGENT_TICKS.size(),
		(
			"decision 必须严格分成四帧 bucket 与有明确原因的 off-phase urgent："
			+ "actual=%s"
		) % str(decision_ticks)
	)
	_expect(
		refresh_ticks == EXPECTED_REFRESH_TICKS
		and _ticks_occur_exactly_once(refresh_ticks, [16, 18, 19]),
		(
			"目标移除/恢复与阵营改变必须各刷新一次，且不得制造重复刷新："
			+ "actual=%s"
		) % str(refresh_ticks)
	)
	_expect(
		_ticks_in_range(decision_ticks, 8, 10) == [9]
		and _ticks_in_range(decision_ticks, 12, 14) == [13]
		and _ticks_in_range(refresh_ticks, 8, 10).is_empty()
		and _ticks_in_range(refresh_ticks, 12, 14).is_empty(),
		"S1/S2 移动状态只能命中四帧 bucket，不能退化为 60Hz 完整决策/刷新。"
	)
	for tick_number in range(1, 5):
		_expect(
			int(snapshots[tick_number - 1]["position_x"])
			== tick_number * 1_000_000,
			"稀疏 decision 间隔内 CHASE Transform 必须保持 60Hz：tick=%d"
			% tick_number
		)
	_expect(
		source.action_phase_log.size() >= 1
		and String(source.action_phase_log[0]).begins_with(
			"5:main_battle_attack_windup:decision"
		),
		"off-cadence 就绪攻击只能在 tick 5 的正式 decision bucket 开始。"
	)
	_expect(
		int(snapshots[7]["skill1_motion_count"]) == 1
		and int(snapshots[8]["skill1_motion_count"]) == 2
		and int(snapshots[9]["skill1_motion_count"]) == 3,
		"SKILL1_DASH 必须跨过 tick 9 decision bucket 仍逐 tick 运动。"
	)
	_expect(
		int(snapshots[11]["skill2_motion_count"]) == 1
		and int(snapshots[12]["skill2_motion_count"]) == 2
		and int(snapshots[13]["skill2_motion_count"]) == 3,
		"SKILL2_TRACK 必须跨过 tick 13 decision bucket 仍逐 tick 运动。"
	)
	_expect(
		int(snapshots[15]["position_x"])
		== int(snapshots[14]["position_x"])
		and int(snapshots[15]["velocity_x"]) == 0
		and int(snapshots[15]["chase_motion_count"])
		== int(snapshots[14]["chase_motion_count"]),
		"无目标的 off-cadence CHASE 必须清零速度并跳过 Transform。"
	)
	_expect(
		int(snapshots[17]["position_x"])
		== int(snapshots[16]["position_x"])
		and int(snapshots[17]["velocity_x"]) == 0
		and int(snapshots[17]["chase_motion_count"])
		== int(snapshots[16]["chase_motion_count"]),
		"已接触的 off-cadence CHASE 必须清零速度并跳过 Transform。"
	)
	_expect(
		source.touch_damage_area.monitoring
		and not runtime.get_enemy_contact_service().owns_enemy(source),
		"主战机甲的稀疏 AREA 纵切不得越权关闭 authored TouchDamageArea。"
	)

	var result := {
		"status": "ok" if failures.is_empty() else "failed",
		"decision_ticks": source.decision_phase_ticks,
		"refresh_ticks": source.dynamic_refresh_ticks,
		"action_phases": source.action_phase_log,
		"failures": failures.duplicate(),
	}
	print("COMBAT_ROBOT_MAIN_BATTLE_SPARSE_CADENCE_JSON %s" % JSON.stringify(result))
	runtime.queue_free()
	await process_frame
	if failures.is_empty():
		print("COMBAT_ROBOT_MAIN_BATTLE_SPARSE_CADENCE_SMOKE_TEST_OK")
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	quit(1)


func _configure_source_config(config: CombatRobotMainBattleEliteConfig) -> void:
	config.move_speed = 60.0
	config.attack_range = 64.0
	config.attack_windup = PHYSICS_DELTA * 8.0
	config.attack_damage_delay = PHYSICS_DELTA * 4.0
	config.attack_slash_duration = PHYSICS_DELTA * 10.0
	config.attack_cooldown = PHYSICS_DELTA * 60.0
	config.skill1_initial_delay = PHYSICS_DELTA * 60.0
	config.skill1_dash_speed = 60.0
	config.skill1_dash_duration = PHYSICS_DELTA * 3.0
	config.skill1_recovery = PHYSICS_DELTA * 2.0
	config.skill2_initial_delay = PHYSICS_DELTA * 60.0
	config.skill2_tracking_duration = PHYSICS_DELTA * 3.0
	config.skill2_cross_speed = 120.0
	config.skill2_drop_duration = PHYSICS_DELTA
	config.skill2_recovery = PHYSICS_DELTA * 2.0
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
	source.layered_event_start_state = source.combat_state
	source.layered_motion_state = source.combat_state
	source.layered_motion_due = false
	source.layered_area_motion_phase_due = false
	source.layered_chase_gate_cached = false
	source.forced_target = target
	source.forced_target_valid = true
	source.forced_target_in_range = true
	source.forced_move_direction = Vector2.RIGHT
	source.forced_contact = false
	source.semantic_tick = 0
	source.reset_semantic_trace()
	source.set_objective_target(target)
	source.request_layered_area_urgent_decision()


func _apply_pre_tick_script(
	tick_index: int,
	source: Variant,
	target: Enemy
) -> void:
	source.semantic_tick = tick_index
	match tick_index:
		2:
			source.request_layered_area_urgent_decision()
		3:
			source.attack_cooldown_left = 0.0
		8:
			source.combat_state = CombatRobotMainBattleElite.CombatState.SKILL1_DASH
			source.state_time_left = PHYSICS_DELTA * 3.0
			source.skill1_locked_position = source.global_position + Vector2(8.0, 0.0)
			source.locked_direction = Vector2.RIGHT
			source.velocity = Vector2.RIGHT * 60.0
		12:
			target.global_position = source.global_position + Vector2(8.0, 0.0)
			source.combat_state = CombatRobotMainBattleElite.CombatState.SKILL2_TRACK
			source.state_time_left = PHYSICS_DELTA * 3.0
			source.committed_target = target
			source.skill2_last_target_position = target.global_position
			source.skill2_last_tracking_direction = Vector2.RIGHT
		16:
			source.combat_state = CombatRobotMainBattleElite.CombatState.CHASE
			source.state_time_left = 0.0
			source.committed_target = null
			source.forced_target = null
			source.forced_target_valid = false
			source.set_objective_target(null)
			source.velocity = Vector2(99.0, 0.0)
		18:
			# Tick 5 的攻击被测试脚本切入 S1，未走到 authored cooldown。
			# 在恢复目标前显式保持三类动作未就绪，隔离“目标变化 urgent”
			# 本身，避免同 tick 开启新攻击后掩盖 tick 19 的阵营变化刷新。
			source.attack_cooldown_left = PHYSICS_DELTA * 60.0
			source.skill1_cooldown_left = PHYSICS_DELTA * 60.0
			source.skill2_cooldown_left = PHYSICS_DELTA * 60.0
			source.forced_target = target
			source.forced_target_valid = true
			source.set_objective_target(target)
			source.forced_contact = true
			source.velocity = Vector2(99.0, 0.0)
		19:
			source.forced_contact = false
			target.set_combat_faction_id(
				CombatRelationService.HOSTILE_WAVE,
				2,
				true
			)
			source.request_layered_area_urgent_decision()


func _advance_one_tick(
	coordinator: EnemySimulationCoordinator,
	source: Variant,
	target: Enemy
) -> void:
	await physics_frame
	_disable_automatic_callbacks(coordinator, source, target)
	coordinator.call(&"_physics_process", PHYSICS_DELTA)
	coordinator.set_physics_process(false)


func _capture_snapshot(tick_index: int, source: Variant) -> Dictionary:
	return {
		"tick": tick_index,
		"position_x": roundi(source.global_position.x * 1_000_000.0),
		"velocity_x": roundi(source.velocity.x * 1_000_000.0),
		"state": source.combat_state,
		"chase_motion_count": source.chase_motion_count,
		"skill1_motion_count": source.skill1_motion_count,
		"skill2_motion_count": source.skill2_motion_count,
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
	target: Enemy
) -> void:
	coordinator.set_physics_process(false)
	source.set_process(false)
	source.set_physics_process(false)
	target.set_process(false)
	target.set_physics_process(false)


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)


func _ticks_occur_exactly_once(ticks: Array, expected_ticks: Array) -> bool:
	for tick_variant in expected_ticks:
		if ticks.count(int(tick_variant)) != 1:
			return false
	return true


func _ticks_in_range(ticks: Array, first_tick: int, last_tick: int) -> Array[int]:
	var result: Array[int] = []
	for tick_variant in ticks:
		var tick := int(tick_variant)
		if tick >= first_tick and tick <= last_tick:
			result.append(tick)
	return result
