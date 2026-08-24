extends SceneTree

const POLICY := preload(
	"res://scene/combat/simulation/enemy_simulation_policy.gd"
)
const RUNTIME_SCENE := preload(
	"res://dev_tools/fixtures/combat_robot_gunner_layered_semantic_runtime.tscn"
)
const GUNNER_CONFIG := preload(
	"res://resources/config/enemies/combat_robot_gunner.tres"
)
const GUNNER_ELITE_CONFIG := preload(
	"res://resources/config/enemies/combat_robot_gunner_elite.tres"
)
const TARGET_CONFIG := preload(
	"res://resources/config/enemies/yuanshi_insect_basic.tres"
)
const LAYERED_RANGED_SCRIPT := preload(
	"res://scene/enemy/layered_ranged_enemy.gd"
)

const PHYSICS_DELTA := 1.0 / 60.0
const TEST_TICKS := 29
const ROLLBACK_TICK := 14
const FIXED_SEED := 20_260_824
const SOURCE_NET_ID := 93_101
const SOURCE_OWNER_PEER_ID := 71
const TARGET_A_NET_ID := 93_102
const TARGET_B_NET_ID := 93_103
const EXPECTED_SHOT_TICKS: Array[int] = [
	1, 3, 6, 7,
	11, 13, 15, 17,
	21, 23, 25, 27,
]
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
	"burst_shots",
	"burst_fire_left",
	"locked_direction_x",
	"locked_direction_y",
	"burst_target",
	"objective",
	"facing_left",
	"muzzle_x",
	"muzzle_y",
	"fire_upper_phase",
	"fire_leg_phase",
	"fire_visual_left",
	"animation",
	"animation_frame",
	"source_faction",
	"action_sequence",
	"action_log",
	"shot_attempts",
	"shot_records",
	"burst_start_ticks",
	"burst_finish_ticks",
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
	var runs: Dictionary = {}
	for simulation_mode in TEST_MODES:
		runs[simulation_mode] = await _run_mode(simulation_mode)
	_expect(
		completed_mode_count == TEST_MODES.size(),
		"Every CombatRobotGunner policy coroutine must complete."
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
	print(
		"COMBAT_ROBOT_GUNNER_LAYERED_SEMANTICS_JSON %s"
		% JSON.stringify(result)
	)
	if failures.is_empty():
		print("COMBAT_ROBOT_GUNNER_LAYERED_SEMANTICS_REGRESSION_OK")
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	quit(1)


func _verify_two_config_closure_and_capabilities() -> void:
	for config in [GUNNER_CONFIG, GUNNER_ELITE_CONFIG]:
		var gunner := config.enemy_scene.instantiate() as CombatRobotGunner
		_expect(
			gunner != null,
			"%s must instantiate CombatRobotGunner." % config.resource_path
		)
		if gunner == null:
			continue
		var implementation := gunner.get_script() as Script
		_expect(
			implementation != null
			and implementation.get_base_script() == LAYERED_RANGED_SCRIPT,
			"%s must directly inherit LayeredRangedEnemy."
			% config.resource_path
		)
		_expect(
			gunner.supports_centralized_authoritative_simulation()
			and gunner.supports_layered_area_authoritative_simulation()
			and gunner.supports_layered_contact_authoritative_simulation()
			and not gunner.supports_indexed_touch_authority()
			and gunner.supports_dynamic_enemy_targeting()
			and bool(gunner.call(&"_uses_inherited_touch_damage")),
			"%s must opt into shared Enemy contact while indexed Player/Plant stays closed."
			% config.resource_path
		)
		_expect(
			gunner.get_layered_area_decision_interval_frames() == 1,
			"%s must retain authored per-tick tracking decisions."
			% config.resource_path
		)
		gunner.free()


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

	var source: Variant = runtime.get_node("EnemyContainer/GunnerSource")
	var target_a := runtime.get_node("EnemyContainer/TargetA") as Enemy
	var target_b := runtime.get_node("EnemyContainer/TargetB") as Enemy
	var source_config := GUNNER_CONFIG.duplicate(true) as CombatRobotGunnerConfig
	source_config.attack_range = 200.0
	source_config.stop_distance = 0.0
	source_config.burst_count = 4
	source_config.burst_fire_interval = PHYSICS_DELTA * 2.0
	source_config.spread_angle_degrees = 7.0
	source_config.burst_move_speed_multiplier = 0.5
	source_config.attack_cooldown = PHYSICS_DELTA * 3.5
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
		"%s harness must preserve Gunner's production capability boundary."
		% mode_name
	)
	if simulation_mode == POLICY.Mode.LEGACY:
		_expect(
			not source.is_centrally_simulated(),
			"LEGACY must retain Gunner's individual runner."
		)
	else:
		_expect(
			source.is_centrally_simulated()
			and coordinator.owns_enemy(source, source.enemy_simulation_token),
			"%s must centrally own Gunner." % mode_name
		)

	var context := {
		"coordinator": coordinator,
		"source": source,
		"target_a": target_a,
		"target_b": target_b,
		"rollback_preserved": simulation_mode == POLICY.Mode.LEGACY,
		"rollback_restored": simulation_mode == POLICY.Mode.LEGACY,
		"contact_admitted_without_indexed": (
			simulation_mode != POLICY.Mode.LAYERED_CONTACT
		),
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
			context["contact_admitted_without_indexed"] = (
				contact_service.owns_enemy(source)
				and not source.is_indexed_touch_authority_enabled()
				and source.touch_damage_area.monitoring
				and _count_enabled_touch_shapes(source) == 1
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
				and _count_enabled_touch_shapes(source) == 1
				and not runtime.get_enemy_contact_service().owns_enemy(source)
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
	source.combat_state = CombatRobotGunner.CombatState.TRACKING_READY
	source.attack_cooldown_left = 0.0
	source.burst_target = null
	source.burst_shots_fired = 0
	source.burst_fire_time_left = 0.0
	source.locked_fire_direction = Vector2.RIGHT
	source.fire_upper_phase = 0.0
	source.fire_leg_phase = 0.0
	source.fire_visual_time_left = 0.0
	source.layered_gunner_burst_finalize_pending = false
	source.layered_gunner_motion_pending = false
	source.layered_gunner_legs_stopped = false
	source.forced_target = target_a
	source.forced_target_valid = true
	source.forced_target_in_range = true
	source.forced_move_direction = Vector2.RIGHT
	source.semantic_tick = 0
	source.reset_semantic_trace()
	source.random_generator.seed = FIXED_SEED
	source.material_drop_random_generator.seed = FIXED_SEED + 1
	source.animated_sprite.play(source.config.move_animation_name)
	source.animated_sprite.pause()
	source.animated_sprite.frame = 2
	source.animated_sprite.frame_progress = 0.25
	source.facing_left = false
	source.call(&"_sync_muzzle_facing")
	target_a.global_position = Vector2(80.0, 0.0)
	target_b.global_position = Vector2(-80.0, 0.0)
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
	if tick_index == 8:
		# Cooldown tracking changes immediately, but the finished first burst kept
		# its original target and direction for every projectile.
		source.forced_target = target_b
		source.forced_move_direction = Vector2.LEFT
		source.set_objective_target(target_b)
		source.request_layered_area_urgent_decision()
	elif tick_index == 12:
		# A committed burst follows movement policy without retargeting its firing
		# direction when the dynamic target crosses navigation space.
		target_b.global_position = Vector2(0.0, 100.0)
	elif tick_index == 14:
		# Every projectile snapshots the source faction at launch. The committed
		# burst itself survives the target becoming friendly to the new faction.
		source.set_combat_faction_id(
			CombatRelationService.PLAYER_ALLIED,
			2,
			true
		)
	elif tick_index == 19:
		target_b.global_position = Vector2(100.0, 100.0)
		target_b.set_combat_faction_id(
			CombatRelationService.HOSTILE_WAVE,
			2,
			true
		)
	elif tick_index == 22:
		target_b.global_position = Vector2(-100.0, -100.0)
	elif tick_index == 23:
		# Losing the committed target must not truncate the already accepted burst.
		target_b.is_dead = true


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
		"cooldown": _quantize(source.attack_cooldown_left),
		"burst_shots": source.burst_shots_fired,
		"burst_fire_left": _quantize(source.burst_fire_time_left),
		"locked_direction_x": _quantize(source.locked_fire_direction.x),
		"locked_direction_y": _quantize(source.locked_fire_direction.y),
		"burst_target": _target_label(source.burst_target, target_a, target_b),
		"objective": _target_label(source.objective_target, target_a, target_b),
		"facing_left": 1 if source.facing_left else 0,
		"muzzle_x": _quantize(source.muzzle.position.x),
		"muzzle_y": _quantize(source.muzzle.position.y),
		"fire_upper_phase": _quantize(source.fire_upper_phase),
		"fire_leg_phase": _quantize(source.fire_leg_phase),
		"fire_visual_left": _quantize(source.fire_visual_time_left),
		"animation": String(source.animated_sprite.animation),
		"animation_frame": source.animated_sprite.frame,
		"source_faction": source.get_combat_faction_id(),
		"action_sequence": source.action_sequence,
		"action_log": source.action_log.duplicate(),
		"shot_attempts": source.shot_attempt_count,
		"shot_records": source.shot_records.duplicate(true),
		"shot_phases": source.shot_phases.duplicate(),
		"burst_start_ticks": source.burst_start_ticks.duplicate(),
		"burst_start_phases": source.burst_start_phases.duplicate(),
		"burst_finish_ticks": source.burst_finish_ticks.duplicate(),
		"movement_submissions": source.movement_submission_count,
		"touch_updates": source.touch_update_count,
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
		"cooldown": source.attack_cooldown_left,
		"target": source.burst_target,
		"shots": source.burst_shots_fired,
		"fire_left": source.burst_fire_time_left,
		"direction": source.locked_fire_direction,
		"upper_phase": source.fire_upper_phase,
		"leg_phase": source.fire_leg_phase,
		"visual_left": source.fire_visual_time_left,
		"action_sequence": source.action_sequence,
		"shot_attempts": source.shot_attempt_count,
		"shot_records": source.shot_records.duplicate(true),
		"behavior_rng": source.random_generator.state,
	}


func _validate_mode_invariants(
	mode_name: String,
	simulation_mode: int,
	snapshots: Array[Dictionary],
	context: Dictionary
) -> void:
	_expect(
		snapshots.size() == TEST_TICKS,
		"%s must capture every Gunner tick." % mode_name
	)
	if snapshots.size() != TEST_TICKS:
		return
	var last: Dictionary = snapshots.back()
	var shot_records: Array = last["shot_records"]
	var shot_ticks: Array[int] = []
	for record_variant in shot_records:
		var record := record_variant as Dictionary
		shot_ticks.append(int(record.get("tick", -1)))
	_expect(
		last["burst_start_ticks"] == [1, 11, 21]
		and last["burst_finish_ticks"] == [7, 17, 27]
		and shot_ticks == EXPECTED_SHOT_TICKS,
		"%s must preserve burst/cooldown timing and the failed-shot retry edge."
		% mode_name
	)
	_expect(
		int(last["shot_attempts"]) == 13
		and shot_records.size() == 12
		and int(last["action_sequence"]) == 12
		and (last["action_log"] as Array).size() == 12,
		"%s must count only successful DATA launches and actions." % mode_name
	)
	_expect(
		int(last["movement_submissions"]) == TEST_TICKS
		and int(last["touch_updates"]) == TEST_TICKS,
		"%s must preserve 60 Hz movement and touch event submission."
		% mode_name
	)
	_expect(
		bool(context["rollback_preserved"])
		and bool(context["rollback_restored"]),
		"%s rollback must preserve a committed burst and restore individual authority."
		% mode_name
	)
	_expect(
		bool(context["contact_admitted_without_indexed"]),
		"%s CONTACT must own Gunner's shared proxy while retaining the authored Area."
		% mode_name
	)
	_expect(
		int(last["indexed_touch"]) == 0
		and int(last["touch_monitoring"]) == 1
		and int(last["enabled_touch_shapes"]) == 1,
		"%s must never disable Gunner's authored physical touch rectangle."
		% mode_name
	)
	_expect(
		int(snapshots[13]["state"]) == CombatRobotGunner.CombatState.BURST
		and String(snapshots[13]["burst_target"]) == "none"
		and int(snapshots[13]["burst_shots"]) == 2,
		"%s faction change must detach the live target without cancelling the burst."
		% mode_name
	)
	_expect(
		int(snapshots[22]["state"]) == CombatRobotGunner.CombatState.BURST
		and String(snapshots[22]["burst_target"]) == "none",
		"%s target death must not truncate an accepted burst." % mode_name
	)
	_validate_projectile_snapshots(mode_name, shot_records)

	var start_phases: Array = last["burst_start_phases"]
	var shot_phases: Array = last["shot_phases"]
	if simulation_mode in [
		POLICY.Mode.LAYERED_AREA,
		POLICY.Mode.LAYERED_CONTACT,
	]:
		_expect(
			start_phases == ["decision", "decision", "compat"],
			"%s must commit pre-rollback bursts in decision and the final one in COMPAT."
			% mode_name
		)
		_expect(
			shot_phases.size() == 12
			and _all_phase_range_equals(shot_phases, 0, 6, "motion")
			and _all_phase_range_equals(shot_phases, 6, 12, "compat"),
			"%s must launch after layered motion, then use COMPAT after rollback."
			% mode_name
		)
	else:
		_expect(
			start_phases == ["compat", "compat", "compat"]
			and _all_phase_range_equals(
				shot_phases,
				0,
				shot_phases.size(),
				"compat"
			),
			"%s must retain the complete authored COMPAT runner." % mode_name
		)
	_expect(
		int(snapshots[ROLLBACK_TICK - 2]["central_owned"])
		== (0 if simulation_mode == POLICY.Mode.LEGACY else 1)
		and int(snapshots[ROLLBACK_TICK - 1]["central_owned"]) == 0,
		"%s must transfer ownership exactly at rollback tick %d."
		% [mode_name, ROLLBACK_TICK]
	)


func _validate_projectile_snapshots(mode_name: String, records: Array) -> void:
	if records.size() != 12:
		return
	for record_index in range(records.size()):
		var record := records[record_index] as Dictionary
		var expected_faction := (
			CombatRelationService.HOSTILE_WAVE
			if record_index < 6
			else CombatRelationService.PLAYER_ALLIED
		)
		_expect(
			int(record.get("source_faction", -1)) == expected_faction
			and int(record.get("credit_peer", 0)) == SOURCE_OWNER_PEER_ID
			and int(record.get("instigator", 0)) == SOURCE_NET_ID
			and String(record.get("source_type", ""))
			== "combat_robot_gunner_bullet",
			"%s shot %d must freeze launch faction, credit and source identity."
			% [mode_name, record_index + 1]
		)
	for record_index in range(0, 4):
		_expect(
			int((records[record_index] as Dictionary)["direction_x"]) > 0,
			"%s first burst shot %d must retain the locked right direction."
			% [mode_name, record_index + 1]
		)
	for record_index in range(4, 8):
		_expect(
			int((records[record_index] as Dictionary)["direction_x"]) < 0,
			"%s second burst shot %d must ignore the moved target and stay left."
			% [mode_name, record_index - 3]
		)
	for record_index in range(8, 12):
		var direction_record := records[record_index] as Dictionary
		_expect(
			int(direction_record["direction_x"]) > 0
			and int(direction_record["direction_y"]) > 0,
			"%s third burst shot %d must retain its accepted northeast direction."
			% [mode_name, record_index - 7]
		)
	_expect(
		int((records[0] as Dictionary)["position_x"]) > 14_000_000,
		"%s immediate first projectile must use the post-motion muzzle position."
		% mode_name
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
			failures.append(
				"%s Gunner trace length differs from COMPAT_60." % mode_name
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
				if mismatch_count >= 10:
					break
			if mismatch_count >= 10:
				break


func _setup_enemy(
	enemy: Variant,
	config: EnemyConfig,
	runtime: EnemyGameplayGatewayTestRuntime,
	net_id: int
) -> void:
	enemy.set_meta(&"net_id", net_id)
	enemy.set_meta(&"owner_peer_id", SOURCE_OWNER_PEER_ID)
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


func _all_phase_range_equals(
	phases: Array,
	from_index: int,
	to_index: int,
	expected: String
) -> bool:
	if from_index < 0 or to_index > phases.size() or from_index > to_index:
		return false
	for phase_index in range(from_index, to_index):
		if String(phases[phase_index]) != expected:
			return false
	return true


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
		for tick_index in [1, 7, 11, 14, 17, 21, 23, 27]:
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
