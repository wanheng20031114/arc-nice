extends SceneTree

## Four-policy semantic golden for the exact CapooSMG family. The authored
## harness replaces only world motion and bullet backends; cooldown, short-range
## aim, spread RNG, action sequencing, faction snapshots and proxy-independent
## weapon state all execute through production code.

const POLICY := preload(
	"res://scene/combat/simulation/enemy_simulation_policy.gd"
)
const RUNTIME_SCENE := preload(
	"res://dev_tools/fixtures/capoo_smg_layered_semantic_runtime.tscn"
)
const SMG_CONFIG := preload(
	"res://resources/config/enemies/capoo_smg.tres"
)
const STONE_SMG_CONFIG := preload(
	"res://resources/config/enemies/stone_eroded_capoo_smg.tres"
)
const TARGET_CONFIG := preload(
	"res://resources/config/enemies/yuanshi_insect_basic.tres"
)
const LAYERED_RANGED_SCRIPT := preload(
	"res://scene/enemy/layered_ranged_enemy.gd"
)

const PHYSICS_DELTA := 1.0 / 60.0
const TEST_TICKS := 30
const FIXED_SEED := 20_260_824
const SOURCE_NET_ID := 75_001
const SOURCE_OWNER_PEER_ID := 117
const TARGET_A_NET_ID := 75_002
const TARGET_B_NET_ID := 75_003
const ROLLBACK_TICK := 25
const EXPECTED_SHOT_TICKS: PackedInt32Array = [
	1, 4, 7, 11, 14, 17, 20, 24, 27, 30,
]
const TEST_MODES: Array[int] = [
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
	"fire_left",
	"last_move_x",
	"last_move_y",
	"muzzle_left",
	"muzzle_visible",
	"muzzle_progress_log",
	"animation",
	"source_faction",
	"objective",
	"forced_target",
	"action_sequence",
	"action_log",
	"fire_opportunities",
	"fire_opportunity_log",
	"bullet_attempts",
	"shot_count",
	"shot_log",
	"hitscan_count",
	"last_shot_x",
	"last_shot_y",
	"movement_submissions",
	"touch_updates",
	"last_touch_delta",
	"target_refreshes",
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
		"Every SMG policy coroutine must reach its completion sentinel."
	)
	_compare_mode_traces(runs)

	var result := {
		"status": "ok" if failures.is_empty() else "failed",
		"fixed_seed": FIXED_SEED,
		"ticks": TEST_TICKS,
		"modes": _mode_names(),
		"trace_digests": _trace_digests(runs),
		"rollback": _rollback_diagnostics(runs),
		"failures": failures.duplicate(),
	}
	print("CAPOO_SMG_LAYERED_SEMANTICS_JSON %s" % JSON.stringify(result))
	if failures.is_empty():
		print("CAPOO_SMG_LAYERED_SEMANTICS_REGRESSION_OK")
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	quit(1)


func _verify_two_config_closure_and_capabilities() -> void:
	for config in [SMG_CONFIG, STONE_SMG_CONFIG]:
		var smg := config.enemy_scene.instantiate() as CapooSMG
		_expect(
			smg != null,
			"%s must instantiate the shared CapooSMG runner."
			% config.resource_path
		)
		if smg == null:
			continue
		var implementation := smg.get_script() as Script
		_expect(
			implementation != null
			and implementation.get_base_script() == LAYERED_RANGED_SCRIPT,
			"%s must directly inherit LayeredRangedEnemy."
			% config.resource_path
		)
		_expect(
			smg.supports_centralized_authoritative_simulation()
			and smg.supports_layered_area_authoritative_simulation()
			and smg.supports_layered_contact_authoritative_simulation()
			and smg.supports_dynamic_enemy_targeting()
			and smg.supports_indexed_touch_authority()
			and not bool(smg.call(&"_uses_inherited_touch_damage")),
			"%s must publish explicit centralized/layered/contact/indexed SMG capability without inherited damage."
			% config.resource_path
		)
		smg.free()


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

	var source: Variant = runtime.get_node("EnemyContainer/SMGSource")
	var target_a := runtime.get_node("EnemyContainer/TargetA") as Enemy
	var target_b := runtime.get_node("EnemyContainer/TargetB") as Enemy
	var source_config := SMG_CONFIG.duplicate(true) as CapooSMGConfig
	source_config.fire_interval = PHYSICS_DELTA * 2.5
	source_config.attack_range = 48.0
	source_config.spread_angle_degrees = 12.5
	source_config.attack_damage = 37
	source_config.move_speed = 60.0
	source_config.attack_audio_stream = null
	source_config.drop_table = null
	source_config.xirang_kill_reward = 0
	var target_a_config := TARGET_CONFIG.duplicate(true) as EnemyConfig
	target_a_config.drop_table = null
	target_a_config.xirang_kill_reward = 0
	var target_b_config := TARGET_CONFIG.duplicate(true) as EnemyConfig
	target_b_config.drop_table = null
	target_b_config.xirang_kill_reward = 0

	source.set_meta(&"net_id", SOURCE_NET_ID)
	source.set_meta(&"owner_peer_id", SOURCE_OWNER_PEER_ID)
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
	await _advance_one_tick(coordinator, source, [target_a, target_b], 0)
	_reset_source_after_bootstrap(source, source_config, target_a, target_b)

	_expect(
		source.supports_layered_area_authoritative_simulation()
		and source.supports_layered_contact_authoritative_simulation()
		and source.supports_indexed_touch_authority(),
		"%s SMG must retain explicit layered/contact/indexed opt-in."
		% mode_name
	)
	if simulation_mode == POLICY.Mode.LEGACY:
		_expect(
			not source.is_centrally_simulated(),
			"LEGACY must keep SMG on the individual runner."
		)
	else:
		_expect(
			source.is_centrally_simulated()
			and coordinator.owns_enemy(source, source.enemy_simulation_token),
			"%s must own SMG through the coordinator." % mode_name
		)
	if simulation_mode == POLICY.Mode.LAYERED_CONTACT:
		_expect(
			source.is_indexed_touch_authority_enabled()
			and not source.touch_damage_area.monitoring
			and not source.touch_damage_area.monitorable
			and _all_touch_shapes_disabled(source),
			"LAYERED_CONTACT must atomically replace the single SMG TouchDamageArea."
		)
	else:
		_expect(
			not source.is_indexed_touch_authority_enabled(),
			"%s must retain authored Player/Plant Area authority."
			% mode_name
		)

	var context := {
		"coordinator": coordinator,
		"source": source,
		"target_a": target_a,
		"target_b": target_b,
		"simulation_mode": simulation_mode,
		"rollback_restored": simulation_mode == POLICY.Mode.LEGACY,
		"rollback_released_indexed": simulation_mode == POLICY.Mode.LEGACY,
		"rollback_restored_area": simulation_mode == POLICY.Mode.LEGACY,
		"rollback_area_immediate": simulation_mode == POLICY.Mode.LEGACY,
		"rollback_preserved_state": simulation_mode == POLICY.Mode.LEGACY,
		"rollback_state_diff": PackedStringArray(),
	}
	var snapshots: Array[Dictionary] = []
	for tick_index in range(1, TEST_TICKS + 1):
		_apply_pre_tick_script(tick_index, context)
		await _advance_one_tick(
			coordinator,
			source,
			[target_a, target_b],
			tick_index,
			context
		)
		snapshots.append(_capture_snapshot(
			tick_index,
			source,
			target_a,
			target_b
		))

	_validate_mode_invariants(mode_name, simulation_mode, snapshots, context)
	var run_result := {
		"mode": mode_name,
		"snapshots": snapshots,
		"trace_lines": _canonical_gameplay_trace_lines(snapshots),
		"rollback": {
			"individual_restored": context["rollback_restored"],
			"indexed_released": context["rollback_released_indexed"],
			"area_immediate": context["rollback_area_immediate"],
			"area_at_boundary": context["rollback_restored_area"],
			"state_preserved": context["rollback_preserved_state"],
			"state_diff": context["rollback_state_diff"],
		},
	}
	runtime.prepare_for_scene_teardown()
	runtime.queue_free()
	await process_frame
	await physics_frame
	completed_mode_count += 1
	return run_result


func _reset_source_after_bootstrap(
	source: Variant,
	source_config: CapooSMGConfig,
	target_a: Enemy,
	target_b: Enemy
) -> void:
	source.global_position = Vector2.ZERO
	source.velocity = Vector2.ZERO
	source.fire_time_left = 0.0
	source.last_move_direction = Vector2.RIGHT
	source.muzzle_flash_time_left = 0.0
	source.layered_smg_post_motion_fire_pending = false
	source.layered_smg_pending_target = null
	source.layered_smg_pending_base_direction = Vector2.ZERO
	source.forced_target = target_a
	source.forced_target_valid = true
	source.forced_player_contact = false
	source.forced_move_direction = Vector2.RIGHT
	source.forced_fire_success = true
	target_a.global_position = Vector2(40.0, 0.0)
	target_b.global_position = Vector2(80.0, 0.0)
	target_a.is_dead = false
	target_b.is_dead = false
	source.set_combat_faction_id(
		CombatRelationService.HOSTILE_WAVE,
		1,
		true
	)
	target_a.set_combat_faction_id(
		CombatRelationService.PLAYER_ALLIED,
		2,
		true
	)
	target_b.set_combat_faction_id(
		CombatRelationService.PLAYER_ALLIED,
		2,
		true
	)
	source.call(&"_play_config_animation", source_config.move_animation_name)
	source.call(&"_set_muzzle_flash", 0.0, Vector2.RIGHT)
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
		target_a.global_position = Vector2(0.0, 40.0)
		source.forced_move_direction = Vector2.DOWN
	elif tick_index == 3:
		source.forced_player_contact = true
	elif tick_index == 5:
		source.forced_player_contact = false
		source.forced_move_direction = Vector2.ZERO
	elif tick_index == 8:
		target_a.global_position = Vector2(160.0, 0.0)
		source.forced_move_direction = Vector2.RIGHT
	elif tick_index == 11:
		target_a.global_position = source.global_position + Vector2(40.0, 0.0)
	elif tick_index == 12:
		source.forced_fire_success = false
		source.forced_target_valid = false
		source.set_objective_target(null)
		source.request_layered_area_urgent_decision()
	elif tick_index == 13:
		source.forced_target_valid = true
		source.set_objective_target(target_a)
		source.request_layered_area_urgent_decision()
	elif tick_index == 15:
		target_a.set_combat_faction_id(
			CombatRelationService.HOSTILE_WAVE,
			3,
			true
		)
		source.set_objective_target(null)
		source.request_layered_area_urgent_decision()
	elif tick_index == 17:
		source.forced_fire_success = true
		source.set_combat_faction_id(
			CombatRelationService.PLAYER_ALLIED,
			2,
			true
		)
		target_a.global_position = source.global_position + Vector2(40.0, 0.0)
		source.set_objective_target(target_a)
		source.request_layered_area_urgent_decision()
	elif tick_index == 18:
		target_a.is_dead = true
		source.set_objective_target(null)
		source.request_layered_area_urgent_decision()
	elif tick_index == 19:
		target_b.set_combat_faction_id(
			CombatRelationService.HOSTILE_WAVE,
			3,
			true
		)
		target_b.global_position = source.global_position + Vector2(-40.0, 0.0)
		source.forced_target = target_b
		source.forced_move_direction = Vector2.LEFT
		source.set_objective_target(target_b)
		source.request_layered_area_urgent_decision()
	elif tick_index == 23:
		source.forced_fire_success = false
	elif tick_index == 24:
		source.forced_fire_success = true
	elif tick_index == ROLLBACK_TICK:
		var before_rollback := _capture_rollback_state(source)
		if int(context["simulation_mode"]) != POLICY.Mode.LEGACY:
			coordinator.set_mode(POLICY.Mode.LEGACY)
			context["rollback_restored"] = source.is_physics_processing()
			context["rollback_released_indexed"] = (
				not source.is_indexed_touch_authority_enabled()
			)
			context["rollback_area_immediate"] = (
				source.touch_damage_area.monitoring
				and source.touch_damage_area.monitorable
				and not _all_touch_shapes_disabled(source)
			)
		else:
			context["rollback_restored"] = not source.is_centrally_simulated()
			context["rollback_released_indexed"] = (
				not source.is_indexed_touch_authority_enabled()
			)
			context["rollback_area_immediate"] = (
				source.touch_damage_area.monitoring
				and source.touch_damage_area.monitorable
				and not _all_touch_shapes_disabled(source)
			)
		var after_rollback := _capture_rollback_state(source)
		context["rollback_state_diff"] = _dictionary_diff(
			before_rollback,
			after_rollback
		)
		var rollback_state_diff: PackedStringArray = (
			context["rollback_state_diff"]
		)
		context["rollback_preserved_state"] = (
			rollback_state_diff.is_empty()
		)
		source.set_physics_process(false)
		coordinator.set_physics_process(false)
	elif tick_index == 26:
		source.forced_player_contact = true
	elif tick_index == 28:
		source.forced_player_contact = false
		source.forced_move_direction = Vector2.UP


func _advance_one_tick(
	coordinator: EnemySimulationCoordinator,
	source: Variant,
	other_nodes: Array,
	semantic_tick: int,
	context: Dictionary = {}
) -> void:
	await physics_frame
	_disable_automatic_callbacks(coordinator, source, other_nodes)
	if source == null or not is_instance_valid(source) or source.is_dead:
		return
	if semantic_tick == ROLLBACK_TICK and not context.is_empty():
		# Enemy restores Physics2D monitoring/shape state with call_deferred so a
		# mode switch cannot mutate an Area during an active physics flush. Verify
		# that restoration has committed at the next physics boundary, before this
		# test invokes the first post-rollback authored gameplay step.
		context["rollback_restored_area"] = (
			source.touch_damage_area.monitoring
			and source.touch_damage_area.monitorable
			and not _all_touch_shapes_disabled(source)
		)
	source.semantic_tick = semantic_tick
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
	return {
		"tick": tick_index,
		"position_x": _quantize(source.global_position.x),
		"position_y": _quantize(source.global_position.y),
		"velocity_x": _quantize(source.velocity.x),
		"velocity_y": _quantize(source.velocity.y),
		"fire_left": _quantize(source.fire_time_left),
		"last_move_x": _quantize(source.last_move_direction.x),
		"last_move_y": _quantize(source.last_move_direction.y),
		"muzzle_left": _quantize(source.muzzle_flash_time_left),
		"muzzle_visible": 1 if source.muzzle_flash.visible else 0,
		"muzzle_progress_log": _integer_log(source.muzzle_progress_records),
		"animation": String(source.animated_sprite.animation),
		"source_faction": source.get_combat_faction_id(),
		"objective": _target_label(source.objective_target, target_a, target_b),
		"forced_target": _target_label(source.forced_target, target_a, target_b),
		"action_sequence": source.action_sequence,
		"action_log": _action_log(source.action_records),
		"fire_opportunities": source.fire_opportunity_count,
		"fire_opportunity_log": _fire_opportunity_log(
			source.fire_opportunity_records
		),
		"bullet_attempts": source.shot_attempt_count,
		"shot_count": source.shot_records.size(),
		"shot_log": _shot_gameplay_log(source.shot_records),
		"hitscan_count": source.hitscan_shots_fired,
		"last_shot_x": _quantize(source.last_shot_direction.x),
		"last_shot_y": _quantize(source.last_shot_direction.y),
		"movement_submissions": source.movement_submission_count,
		"touch_updates": source.touch_update_deltas.size(),
		"last_touch_delta": (
			_quantize(source.touch_update_deltas[-1])
			if not source.touch_update_deltas.is_empty()
			else 0
		),
		"target_refreshes": source.combat_target_refresh_count,
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
		"position": source.global_position,
		"velocity": source.velocity,
		"fire_left": source.fire_time_left,
		"last_move": source.last_move_direction,
		"muzzle_left": source.muzzle_flash_time_left,
		"muzzle_visible": source.muzzle_flash.visible,
		"last_shot": source.last_shot_direction,
		"action_sequence": source.action_sequence,
		"rng": source.random_generator.state,
		"pending": source.layered_smg_post_motion_fire_pending,
		"pending_target": source.layered_smg_pending_target,
		"pending_direction": source.layered_smg_pending_base_direction,
	}


func _validate_mode_invariants(
	mode_name: String,
	simulation_mode: int,
	snapshots: Array[Dictionary],
	context: Dictionary
) -> void:
	if snapshots.size() != TEST_TICKS:
		failures.append("%s must capture every SMG tick." % mode_name)
		return
	var source: Variant = context["source"]
	var actual_shot_ticks := PackedInt32Array()
	for record_variant in source.shot_records:
		var record := record_variant as Dictionary
		actual_shot_ticks.append(int(record.get("tick", -1)))
	_expect(
		actual_shot_ticks == EXPECTED_SHOT_TICKS,
		"%s SMG fire cadence must remain %s (got %s)."
		% [mode_name, str(EXPECTED_SHOT_TICKS), str(actual_shot_ticks)]
	)
	_expect(
		source.shot_attempt_count == EXPECTED_SHOT_TICKS.size() + 1
		and source.action_sequence == EXPECTED_SHOT_TICKS.size()
		and source.action_records.size() == EXPECTED_SHOT_TICKS.size(),
		"%s failed backend attempt must consume spread RNG but not cooldown/action sequence."
		% mode_name
	)
	_expect(
		int(snapshots[0]["position_x"]) == 1_000_000
		and int(source.shot_records[0]["origin_x"]) == 1_000_000,
		"%s first short-range shot must commit after the authored movement submission."
		% mode_name
	)
	_expect(
		int(snapshots[3]["movement_submissions"])
		== int(snapshots[1]["movement_submissions"])
		and int(source.shot_records[1]["tick"]) == 4,
		"%s contact ticks must stop motion and fire on the exact cooldown edge."
		% mode_name
	)
	_expect(
		int(snapshots[6]["movement_submissions"])
		== int(snapshots[3]["movement_submissions"])
		and int(source.shot_records[2]["tick"]) == 7,
		"%s zero-direction chase must commit a ready shot without inventing motion."
		% mode_name
	)
	_expect(
		not _shot_records_have_tick(source.shot_records, 10)
		and int(snapshots[9]["fire_left"]) == 0,
		"%s short-range envelope must reject the ready out-of-range attempt without consuming cooldown."
		% mode_name
	)
	_expect(
		int(snapshots[11]["fire_opportunities"])
		== int(snapshots[10]["fire_opportunities"]),
		"%s LOS/target-adapter rejection must suppress the tick-12 fire commit."
		% mode_name
	)
	_expect(
		int(snapshots[14]["fire_opportunities"])
		== int(snapshots[13]["fire_opportunities"])
		and int(snapshots[17]["fire_opportunities"])
		== int(snapshots[16]["fire_opportunities"]),
		"%s friendly and dead targets must be rejected before the SMG backend."
		% mode_name
	)
	_validate_backend_and_attribution(mode_name, source)
	_validate_phase_order(mode_name, simulation_mode, source)
	_expect(
		bool(context["rollback_restored"])
		and bool(context["rollback_released_indexed"])
		and bool(context["rollback_restored_area"])
		and bool(context["rollback_preserved_state"]),
		"%s rollback must preserve weapon/RNG state, immediately release logical indexed authority, and restore the authored Area before post-rollback gameplay; diagnostics=%s"
		% [mode_name, str({
			"individual": context["rollback_restored"],
			"indexed": context["rollback_released_indexed"],
			"area_immediate": context["rollback_area_immediate"],
			"area_at_boundary": context["rollback_restored_area"],
			"state_diff": context["rollback_state_diff"],
		})]
	)
	_expect(
		(
			int(context["simulation_mode"]) != POLICY.Mode.LAYERED_CONTACT
			and bool(context["rollback_area_immediate"])
		)
		or (
			int(context["simulation_mode"]) == POLICY.Mode.LAYERED_CONTACT
			and not bool(context["rollback_area_immediate"])
			and bool(context["rollback_restored_area"])
		),
		"%s rollback must retain authored Area immediately unless CONTACT is leaving its deliberate deferred Physics2D commit, which must finish at the next boundary."
		% mode_name
	)
	_expect(
		int(snapshots[ROLLBACK_TICK - 1]["central_owned"]) == 0
		and int(snapshots[ROLLBACK_TICK - 1]["indexed_touch"]) == 0
		and int(snapshots[ROLLBACK_TICK - 1]["touch_area_monitoring"]) == 1,
		"%s tick %d must continue on restored LEGACY ownership after rollback."
		% [mode_name, ROLLBACK_TICK]
	)
	_expect(
		source.touch_update_deltas.size() == TEST_TICKS
		and _all_deltas_equal(source.touch_update_deltas, PHYSICS_DELTA),
		"%s must advance authored touch-before-timer semantics exactly once per tick."
		% mode_name
	)


func _validate_backend_and_attribution(
	mode_name: String,
	source: Variant
) -> void:
	var projectile_records := 0
	for index in range(source.shot_records.size()):
		var shot := source.shot_records[index] as Dictionary
		var action := source.action_records[index] as Dictionary
		_expect(
			int(action.get("id", 0)) == index + 1
			and String(action.get("name", "")) == "fire"
			and int(action.get("direction_x", 0))
			== int(shot.get("direction_x", 1))
			and int(action.get("direction_y", 0))
			== int(shot.get("direction_y", 1)),
			"%s shot %d must broadcast the same frozen direction with monotonic action ID."
			% [mode_name, index + 1]
		)
		_expect(
			int(shot.get("damage", 0)) == 37
			and int(shot.get("credit_peer_id", 0)) == SOURCE_OWNER_PEER_ID
			and int(shot.get("instigator_id", 0)) == SOURCE_NET_ID,
			"%s shot %d must preserve damage and ownership attribution."
			% [mode_name, index + 1]
		)
		if String(shot.get("mode", "")) == "projectile":
			projectile_records += 1
			_expect(
				int(shot.get("tick", 0)) == 14
				and int(shot.get("event_source_id", -1)) == 0
				and String(shot.get("source_type", ""))
				== "capoo_smg_bullet",
				"%s projectile mode must freeze the tick-14 bullet snapshot."
				% mode_name
			)
		else:
			_expect(
				String(shot.get("mode", "")) == "hitscan"
				and int(shot.get("event_source_id", 0))
				== SOURCE_NET_ID * 1_000_000 + index + 1
				and String(shot.get("source_type", ""))
				== "capoo_smg_hitscan",
				"%s hitscan shot %d must use action-correlated source identity."
				% [mode_name, index + 1]
			)
	var allied_shot := source.shot_records[5] as Dictionary
	_expect(
		projectile_records == 1
		and source.hitscan_shots_fired == EXPECTED_SHOT_TICKS.size() - 1
		and int((source.shot_records[0] as Dictionary)["source_faction"])
		== CombatRelationService.HOSTILE_WAVE
		and int(allied_shot["tick"]) == 17
		and int(allied_shot["source_faction"])
		== CombatRelationService.PLAYER_ALLIED,
		"%s must preserve backend selection and freeze the launch-time source faction."
		% mode_name
	)


func _validate_phase_order(
	mode_name: String,
	simulation_mode: int,
	source: Variant
) -> void:
	var expected_default_phase := (
		&"compat"
		if simulation_mode == POLICY.Mode.LEGACY
		or simulation_mode == POLICY.Mode.COMPAT_60
		else &"motion"
	)
	for record_variant in source.shot_records:
		var record := record_variant as Dictionary
		var tick := int(record.get("tick", 0))
		var expected_phase := (
			&"compat"
			if tick >= ROLLBACK_TICK
			else (
				&"decision"
				if simulation_mode >= POLICY.Mode.LAYERED_AREA
				and tick in [4, 7]
				else expected_default_phase
			)
		)
		_expect(
			StringName(record.get("phase", &"")) == expected_phase,
			"%s tick %d shot must commit in %s (got %s)."
			% [
				mode_name,
				tick,
				String(expected_phase),
				String(record.get("phase", "")),
			]
		)


func _compare_mode_traces(runs: Dictionary) -> void:
	var legacy_run: Dictionary = runs.get(POLICY.Mode.LEGACY, {})
	var legacy_snapshots: Array = legacy_run.get("snapshots", [])
	for simulation_mode in TEST_MODES:
		if simulation_mode == POLICY.Mode.LEGACY:
			continue
		var mode_name := POLICY.mode_to_name(simulation_mode)
		var comparison_run: Dictionary = runs.get(simulation_mode, {})
		var comparison_snapshots: Array = comparison_run.get("snapshots", [])
		if comparison_snapshots.size() != legacy_snapshots.size():
			failures.append("%s SMG trace length differs from LEGACY." % mode_name)
			continue
		var mismatch_count := 0
		for tick_index in range(legacy_snapshots.size()):
			var legacy_snapshot := legacy_snapshots[tick_index] as Dictionary
			var comparison_snapshot := comparison_snapshots[tick_index] as Dictionary
			for field_name in GAMEPLAY_FIELDS:
				if legacy_snapshot.get(field_name) == comparison_snapshot.get(field_name):
					continue
				failures.append(
					"%s SMG diverged from LEGACY at tick %d field %s: legacy=%s comparison=%s"
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


func _target_label(target: Node2D, target_a: Enemy, target_b: Enemy) -> String:
	if target == target_a:
		return "target_a"
	if target == target_b:
		return "target_b"
	return "none"


func _shot_gameplay_log(records: Array[Dictionary]) -> String:
	var lines := PackedStringArray()
	for record in records:
		lines.append(JSON.stringify({
			"tick": record.get("tick", 0),
			"mode": record.get("mode", ""),
			"origin_x": record.get("origin_x", 0),
			"origin_y": record.get("origin_y", 0),
			"direction_x": record.get("direction_x", 0),
			"direction_y": record.get("direction_y", 0),
			"damage": record.get("damage", 0),
			"source_faction": record.get("source_faction", -1),
			"credit_peer_id": record.get("credit_peer_id", 0),
			"instigator_id": record.get("instigator_id", 0),
			"event_source_id": record.get("event_source_id", 0),
			"source_type": record.get("source_type", ""),
		}))
	return "|".join(lines)


func _action_log(records: Array[Dictionary]) -> String:
	var lines := PackedStringArray()
	for record in records:
		lines.append("%d:%s:%d:%d" % [
			int(record.get("id", 0)),
			String(record.get("name", "")),
			int(record.get("direction_x", 0)),
			int(record.get("direction_y", 0)),
		])
	return "|".join(lines)


func _fire_opportunity_log(records: Array[Dictionary]) -> String:
	var lines := PackedStringArray()
	for record in records:
		lines.append("%d:%d:%d:%d" % [
			int(record.get("tick", 0)),
			int(record.get("target_id", 0)),
			int(record.get("base_direction_x", 0)),
			int(record.get("base_direction_y", 0)),
		])
	return "|".join(lines)


func _integer_log(values: Array[int]) -> String:
	var parts := PackedStringArray()
	for value in values:
		parts.append(str(value))
	return ",".join(parts)


func _shot_records_have_tick(records: Array[Dictionary], tick: int) -> bool:
	for record in records:
		if int(record.get("tick", -1)) == tick:
			return true
	return false


func _dictionary_diff(before: Dictionary, after: Dictionary) -> PackedStringArray:
	var differences := PackedStringArray()
	for field_name in before:
		if before.get(field_name) == after.get(field_name):
			continue
		differences.append(
			"%s:%s->%s"
			% [
				String(field_name),
				str(before.get(field_name)),
				str(after.get(field_name)),
			]
		)
	return differences


func _all_touch_shapes_disabled(source: Variant) -> bool:
	for shape_variant in source.touch_damage_shapes:
		var shape := shape_variant as CollisionShape2D
		if shape != null and not shape.disabled:
			return false
	return true


func _all_deltas_equal(deltas: Array[float], expected_delta: float) -> bool:
	for delta in deltas:
		if not is_equal_approx(delta, expected_delta):
			return false
	return true


func _canonical_gameplay_trace_lines(
	snapshots: Array[Dictionary]
) -> PackedStringArray:
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
		result[POLICY.mode_to_name(simulation_mode)] = (
			"\n".join(lines).sha256_text()
		)
	return result


func _rollback_diagnostics(runs: Dictionary) -> Dictionary:
	var result := {}
	for simulation_mode in TEST_MODES:
		var run: Dictionary = runs.get(simulation_mode, {})
		result[POLICY.mode_to_name(simulation_mode)] = run.get("rollback", {})
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
