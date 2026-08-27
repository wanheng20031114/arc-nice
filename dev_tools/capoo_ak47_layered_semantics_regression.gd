extends SceneTree

## Four-policy per-tick semantic golden for the normal/stone shared AK runner.
## The authored fixture replaces world queries and projectile registration only;
## production windup, burst, cancel, RNG, action and source-snapshot semantics run
## unchanged through LEGACY, COMPAT, AREA and CONTACT.

const POLICY := preload(
	"res://scene/combat/simulation/enemy_simulation_policy.gd"
)
const RUNTIME_SCENE := preload(
	"res://dev_tools/fixtures/capoo_ak47_layered_semantic_runtime.tscn"
)
const AK_CONFIG := preload(
	"res://resources/config/enemies/capoo_ak47.tres"
)
const STONE_AK_CONFIG := preload(
	"res://resources/config/enemies/stone_eroded_capoo_ak47.tres"
)
const TARGET_CONFIG := preload(
	"res://resources/config/enemies/yuanshi_insect_basic.tres"
)
const LAYERED_RANGED_SCRIPT := preload(
	"res://scene/enemy/layered_ranged_enemy.gd"
)

const PHYSICS_DELTA := 1.0 / 60.0
const TEST_TICKS := 40
const FIXED_SEED := 20_260_824
const SOURCE_NET_ID := 76_001
const SOURCE_OWNER_PEER_ID := 127
const TARGET_A_NET_ID := 76_002
const TARGET_B_NET_ID := 76_003
const ROLLBACK_TICK := 34
const EXPECTED_WINDUP_TICKS: PackedInt32Array = [1, 11, 14, 17, 21, 31]
const EXPECTED_SHOT_TICKS: PackedInt32Array = [4, 6, 8, 20, 24, 26, 28, 34, 36, 38]
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
	"combat_state",
	"cooldown_left",
	"windup_left",
	"burst_shots",
	"burst_fire_left",
	"burst_direction_x",
	"burst_direction_y",
	"burst_audio_step",
	"attack_target",
	"objective",
	"forced_target",
	"source_faction",
	"action_sequence",
	"action_log",
	"windup_count",
	"windup_log",
	"shot_attempts",
	"shot_count",
	"shot_log",
	"movement_submissions",
	"touch_updates",
	"cooldown_updates",
	"event_gameplay_log",
	"los_queries",
	"local_projectile_sequence",
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
	for simulation_mode in ALL_RUN_MODES:
		runs[simulation_mode] = await _run_mode(simulation_mode)
	_expect(
		completed_mode_count == ALL_RUN_MODES.size(),
		"The pre-refactor oracle and every AK policy must reach completion."
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
	print("CAPOO_AK47_LAYERED_SEMANTICS_JSON %s" % JSON.stringify(result))
	if failures.is_empty():
		print("CAPOO_AK47_LAYERED_SEMANTICS_REGRESSION_OK")
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	quit(1)


func _verify_two_config_closure_and_capabilities() -> void:
	for config in [AK_CONFIG, STONE_AK_CONFIG]:
		var ak := config.enemy_scene.instantiate() as CapooAK47
		_expect(
			ak != null,
			"%s must instantiate the shared CapooAK47 runner."
			% config.resource_path
		)
		if ak == null:
			continue
		var implementation := ak.get_script() as Script
		_expect(
			implementation != null
			and implementation.get_base_script() == LAYERED_RANGED_SCRIPT,
			"%s must directly inherit LayeredRangedEnemy."
			% config.resource_path
		)
		_expect(
			ak.supports_centralized_authoritative_simulation()
			and ak.supports_layered_area_authoritative_simulation()
			and ak.supports_layered_contact_authoritative_simulation()
			and ak.supports_dynamic_enemy_targeting()
			and ak.supports_indexed_touch_authority()
			and not bool(ak.call(&"_uses_inherited_touch_damage")),
			"%s must publish explicit centralized/layered/contact/indexed AK capability."
			% config.resource_path
		)
		ak.free()


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

	var source: Variant = runtime.get_node("EnemyContainer/AK47Source")
	var target_a := runtime.get_node("EnemyContainer/TargetA") as Enemy
	var target_b := runtime.get_node("EnemyContainer/TargetB") as Enemy
	var source_config := AK_CONFIG.duplicate(true) as CapooAK47Config
	source_config.attack_windup = PHYSICS_DELTA * 2.0
	source_config.burst_count = 3
	source_config.burst_fire_interval = PHYSICS_DELTA * 2.0
	source_config.attack_interval = PHYSICS_DELTA * 8.0
	source_config.attack_range = 96.0
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
		"%s AK harness must exercise the production layered/contact/indexed hooks."
		% mode_name
	)
	if is_oracle or simulation_mode == POLICY.Mode.LEGACY:
		_expect(
			not source.is_centrally_simulated(),
			"LEGACY must keep AK on the individual runner."
		)
	else:
		_expect(
			source.is_centrally_simulated()
			and coordinator.owns_enemy(source, source.enemy_simulation_token),
			"%s must own AK through the coordinator." % mode_name
		)
	if simulation_mode == POLICY.Mode.LAYERED_CONTACT:
		_expect(
			source.is_indexed_touch_authority_enabled()
			and not source.touch_damage_area.monitoring
			and not source.touch_damage_area.monitorable
			and _all_touch_shapes_disabled(source),
			"LAYERED_CONTACT must atomically replace the single AK TouchDamageArea."
		)
	else:
		_expect(
			not source.is_indexed_touch_authority_enabled(),
			"%s must retain authored Player/Plant Area authority." % mode_name
		)

	var context := {
		"coordinator": coordinator,
		"source": source,
		"target_a": target_a,
		"target_b": target_b,
		"simulation_mode": simulation_mode,
		"is_oracle": is_oracle,
		"rollback_applicable": not is_oracle,
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
			"applicable": context["rollback_applicable"],
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
	source_config: CapooAK47Config,
	target_a: Enemy,
	target_b: Enemy
) -> void:
	source.call(&"_release_unused_network_burst_ids")
	source.global_position = Vector2.ZERO
	source.velocity = Vector2.ZERO
	source.combat_state = CapooAK47.CombatState.CHASE
	source.attack_cooldown_left = 0.0
	source.windup_time_left = 0.0
	source.burst_shot_direction = Vector2.RIGHT
	source.burst_shots_fired = 0
	source.burst_fire_time_left = 0.0
	source.burst_audio_step = 0
	source.attack_target = null
	source.navigation_update_frame_offset = 0
	source.committed_attack_phase_offset_seconds = 0.0
	source.committed_windup_duration_seconds = 0.0
	source.layered_ak47_event_consumes_tick = false
	source.forced_target = target_a
	source.forced_target_valid = true
	source.forced_in_range = true
	source.forced_los_clear = true
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
	source.call(&"_reset_ranged_attack_position_state")
	source.call(&"_play_config_animation", source_config.move_animation_name)
	source.call(&"_set_muzzle_heat", 0.0, Vector2.RIGHT)
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
	elif tick_index == 5:
		# The locked burst remains hostile, but every later projectile must freeze
		# the caster's new launch-time faction independently.
		source.set_combat_faction_id(
			CombatRelationService.PLAYER_ALLIED,
			2,
			true
		)
		target_a.set_combat_faction_id(
			CombatRelationService.HOSTILE_WAVE,
			3,
			true
		)
	elif tick_index == 11:
		# Pin the authored cooldown edge; the test is about state ordering, not a
		# platform-dependent residual after repeated floating-point subtraction.
		source.attack_cooldown_left = 0.0
	elif tick_index == 12:
		source.forced_in_range = false
	elif tick_index == 14:
		source.forced_in_range = true
	elif tick_index == 15:
		source.forced_los_clear = false
	elif tick_index == 17:
		source.forced_los_clear = true
	elif tick_index == 18:
		target_a.global_position = source.global_position + Vector2(-40.0, 0.0)
	elif tick_index == 21:
		# Invalidate a committed burst, then prove the pre-state-match cancel may
		# select a new hostile dynamic enemy in this same physics tick.
		source.attack_cooldown_left = 0.0
		target_a.is_dead = true
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
	elif tick_index == 29:
		source.forced_in_range = false
		source.forced_player_contact = true
	elif tick_index == 31:
		source.forced_player_contact = false
		source.forced_in_range = true
		source.attack_cooldown_left = 0.0
		target_b.global_position = source.global_position + Vector2(0.0, -40.0)
		source.forced_move_direction = Vector2.UP
	elif (
		tick_index == ROLLBACK_TICK
		and not bool(context.get("is_oracle", false))
	):
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
		var rollback_state_diff: PackedStringArray = context["rollback_state_diff"]
		context["rollback_preserved_state"] = rollback_state_diff.is_empty()
		source.set_physics_process(false)
		coordinator.set_physics_process(false)


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
	if (
		semantic_tick == ROLLBACK_TICK
		and not context.is_empty()
		and not bool(context.get("is_oracle", false))
	):
		context["rollback_restored_area"] = (
			source.touch_damage_area.monitoring
			and source.touch_damage_area.monitorable
			and not _all_touch_shapes_disabled(source)
		)
	source.semantic_tick = semantic_tick
	if bool(context.get("is_oracle", false)):
		source.call(&"simulate_pre_refactor_authoritative_step", PHYSICS_DELTA)
		source.set_physics_process(false)
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
	return {
		"tick": tick_index,
		"position_x": _quantize(source.global_position.x),
		"position_y": _quantize(source.global_position.y),
		"velocity_x": _quantize(source.velocity.x),
		"velocity_y": _quantize(source.velocity.y),
		"combat_state": source.combat_state,
		"cooldown_left": _quantize(source.attack_cooldown_left),
		"windup_left": _quantize(source.windup_time_left),
		"burst_shots": source.burst_shots_fired,
		"burst_fire_left": _quantize(source.burst_fire_time_left),
		"burst_direction_x": _quantize(source.burst_shot_direction.x),
		"burst_direction_y": _quantize(source.burst_shot_direction.y),
		"burst_audio_step": source.burst_audio_step,
		"attack_target": _target_label(source.attack_target, target_a, target_b),
		"objective": _target_label(source.objective_target, target_a, target_b),
		"forced_target": _target_label(source.forced_target, target_a, target_b),
		"source_faction": source.get_combat_faction_id(),
		"action_sequence": source.action_sequence,
		"action_log": _action_gameplay_log(source.action_records),
		"windup_count": source.windup_records.size(),
		"windup_log": _windup_gameplay_log(source.windup_records),
		"shot_attempts": source.shot_attempt_count,
		"shot_count": source.shot_records.size(),
		"shot_log": _shot_gameplay_log(source.shot_records),
		"movement_submissions": source.movement_submission_count,
		"touch_updates": source.touch_update_deltas.size(),
		"cooldown_updates": source.cooldown_update_deltas.size(),
		"event_gameplay_log": _event_gameplay_log(source.event_records),
		"los_queries": source.los_query_count,
		"local_projectile_sequence": source.local_data_projectile_sequence,
		"behavior_rng": source.random_generator.state,
		"drop_rng": source.material_drop_random_generator.state,
		"central_owned": 1 if source.is_centrally_simulated() else 0,
		"indexed_touch": 1 if source.is_indexed_touch_authority_enabled() else 0,
		"touch_area_monitoring": 1 if source.touch_damage_area.monitoring else 0,
	}


func _capture_rollback_state(source: Variant) -> Dictionary:
	return {
		"position": source.global_position,
		"velocity": source.velocity,
		"combat_state": source.combat_state,
		"cooldown": source.attack_cooldown_left,
		"windup": source.windup_time_left,
		"burst_direction": source.burst_shot_direction,
		"burst_shots": source.burst_shots_fired,
		"burst_fire": source.burst_fire_time_left,
		"burst_audio": source.burst_audio_step,
		"attack_target": source.attack_target,
		"phase_offset": source.committed_attack_phase_offset_seconds,
		"windup_duration": source.committed_windup_duration_seconds,
		"local_sequence": source.local_data_projectile_sequence,
		"action_sequence": source.action_sequence,
		"rng": source.random_generator.state,
		"network_ids": source.network_burst_projectile_ids.duplicate(),
		"network_states": source.network_burst_attached_states.duplicate(),
		"network_descriptor": source.network_burst_descriptor.duplicate(),
		"network_sent": source.network_burst_descriptor_sent,
		"ranged_hold": source._ranged_attack_position_held,
		"muzzle_visible": source.muzzle_heat.visible,
		"muzzle_position": source.muzzle_heat.position,
		"muzzle_rotation": source.muzzle_heat.rotation,
		"muzzle_scale": source.muzzle_heat.scale,
		"muzzle_color": source.muzzle_heat.color,
		"animation": source.animated_sprite.animation,
	}


func _validate_mode_invariants(
	mode_name: String,
	simulation_mode: int,
	snapshots: Array[Dictionary],
	context: Dictionary
) -> void:
	if snapshots.size() != TEST_TICKS:
		failures.append("%s must capture every AK tick." % mode_name)
		return
	var source: Variant = context["source"]
	var actual_windup_ticks := PackedInt32Array()
	for record_variant in source.windup_records:
		var record := record_variant as Dictionary
		actual_windup_ticks.append(int(record.get("tick", -1)))
	var actual_shot_ticks := PackedInt32Array()
	for record_variant in source.shot_records:
		var record := record_variant as Dictionary
		actual_shot_ticks.append(int(record.get("tick", -1)))
	_expect(
		actual_windup_ticks == EXPECTED_WINDUP_TICKS,
		"%s AK windup commits must remain %s (got %s)."
		% [mode_name, str(EXPECTED_WINDUP_TICKS), str(actual_windup_ticks)]
	)
	_expect(
		actual_shot_ticks == EXPECTED_SHOT_TICKS
		and source.shot_attempt_count == EXPECTED_SHOT_TICKS.size(),
		"%s AK burst cadence must remain %s (got %s)."
		% [mode_name, str(EXPECTED_SHOT_TICKS), str(actual_shot_ticks)]
	)
	_expect(
		int(snapshots[2]["combat_state"]) == CapooAK47.CombatState.BURST
		and int(snapshots[2]["shot_count"]) == 0
		and int(snapshots[3]["shot_count"]) == 1,
		"%s windup expiry must enter BURST without firing until the following tick."
		% mode_name
	)
	_expect(
		int(snapshots[11]["combat_state"]) == CapooAK47.CombatState.CHASE
		and int(snapshots[11]["movement_submissions"])
		== int(snapshots[10]["movement_submissions"])
		and int(snapshots[12]["movement_submissions"])
		== int(snapshots[11]["movement_submissions"]) + 1,
		"%s range cancellation must consume its tick and resume chase motion one tick later."
		% mode_name
	)
	_expect(
		int(snapshots[15]["combat_state"]) == CapooAK47.CombatState.CHASE
		and int(snapshots[15]["movement_submissions"])
		== int(snapshots[14]["movement_submissions"]),
		"%s exact-LOS cancellation must consume the windup expiry tick."
		% mode_name
	)
	_expect(
		String(snapshots[20]["attack_target"]) == "target_b"
		and int(snapshots[20]["combat_state"]) == CapooAK47.CombatState.WINDUP,
		"%s invalid committed target must cancel and retarget the hostile enemy in the same tick."
		% mode_name
	)
	_expect(
		int(snapshots[29]["movement_submissions"])
		== int(snapshots[28]["movement_submissions"]),
		"%s player contact must block out-of-range chase motion."
		% mode_name
	)
	_expect(
		_action_tick_name_log(source.action_records)
		== "1:windup|3:burst|11:windup|14:windup|17:windup|19:burst|21:windup|23:burst|31:windup|33:burst",
		"%s multiplayer action commits must retain the authored windup/burst tick order."
		% mode_name
	)
	_validate_snapshot_attribution(mode_name, source)
	_validate_phase_order(mode_name, simulation_mode, source)
	_validate_event_order(mode_name, source)
	if not bool(context.get("is_oracle", false)):
		_expect(
			bool(context["rollback_restored"])
			and bool(context["rollback_released_indexed"])
			and bool(context["rollback_restored_area"])
			and bool(context["rollback_preserved_state"]),
			"%s rollback must preserve AK burst/RNG/network state, release indexed authority, and restore the authored Area; diagnostics=%s"
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
			"%s rollback must defer Area restoration only when leaving CONTACT."
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
		and source.cooldown_update_deltas.size() == TEST_TICKS
		and _all_deltas_equal(source.touch_update_deltas, PHYSICS_DELTA)
		and _all_deltas_equal(source.cooldown_update_deltas, PHYSICS_DELTA),
		"%s must advance touch then cooldown exactly once per physics tick."
		% mode_name
	)


func _validate_snapshot_attribution(mode_name: String, source: Variant) -> void:
	for index in range(source.shot_records.size()):
		var shot := source.shot_records[index] as Dictionary
		_expect(
			int(shot.get("damage", 0)) == 37
			and int(shot.get("credit_peer_id", 0)) == SOURCE_OWNER_PEER_ID
			and int(shot.get("instigator_id", 0)) == SOURCE_NET_ID
			and int(shot.get("event_source_id", -1)) == 0
			and String(shot.get("source_type", "")) == "capoo_ak47_bullet",
			"%s shot %d must preserve AK damage and launch attribution."
			% [mode_name, index + 1]
		)
	var first_shot := source.shot_records[0] as Dictionary
	var second_shot := source.shot_records[1] as Dictionary
	var final_shot := source.shot_records[-1] as Dictionary
	_expect(
		int(first_shot["source_faction"]) == CombatRelationService.HOSTILE_WAVE
		and int(second_shot["source_faction"])
		== CombatRelationService.PLAYER_ALLIED
		and int(final_shot["source_faction"])
		== CombatRelationService.PLAYER_ALLIED,
		"%s each AK projectile must freeze its own launch-time source faction."
		% mode_name
	)


func _validate_phase_order(
	mode_name: String,
	simulation_mode: int,
	source: Variant
) -> void:
	for record_variant in source.windup_records:
		var record := record_variant as Dictionary
		var tick := int(record.get("tick", 0))
		var expected_phase := (
			&"oracle"
			if simulation_mode == PRE_REFACTOR_ORACLE_MODE
			else (
				&"compat"
				if simulation_mode <= POLICY.Mode.COMPAT_60
				or tick >= ROLLBACK_TICK
				else &"decision"
			)
		)
		_expect(
			StringName(record.get("phase", &"")) == expected_phase,
			"%s tick %d windup must commit in %s."
			% [mode_name, tick, String(expected_phase)]
		)
	for record_variant in source.shot_records:
		var record := record_variant as Dictionary
		var tick := int(record.get("tick", 0))
		var expected_phase := (
			&"oracle"
			if simulation_mode == PRE_REFACTOR_ORACLE_MODE
			else (
				&"compat"
				if simulation_mode <= POLICY.Mode.COMPAT_60
				or tick >= ROLLBACK_TICK
				else &"event"
			)
		)
		_expect(
			StringName(record.get("phase", &"")) == expected_phase,
			"%s tick %d bullet must commit in %s (got %s)."
			% [
				mode_name,
				tick,
				String(expected_phase),
				String(record.get("phase", "")),
			]
		)


func _validate_event_order(mode_name: String, source: Variant) -> void:
	for tick_index in range(1, TEST_TICKS + 1):
		var names := PackedStringArray()
		for record_variant in source.event_records:
			var record := record_variant as Dictionary
			if int(record.get("tick", 0)) == tick_index:
				names.append(String(record.get("event", "")))
		_expect(
			names.size() >= 2
			and names[0] == "touch"
			and names[1] == "cooldown",
			"%s tick %d must preserve touch-before-cooldown event order (got %s)."
			% [mode_name, tick_index, str(names)]
		)


func _compare_mode_traces(runs: Dictionary) -> void:
	var oracle_run: Dictionary = runs.get(PRE_REFACTOR_ORACLE_MODE, {})
	var oracle_snapshots: Array = oracle_run.get("snapshots", [])
	for simulation_mode in TEST_MODES:
		var mode_name := _mode_name(simulation_mode)
		var comparison_run: Dictionary = runs.get(simulation_mode, {})
		var comparison_snapshots: Array = comparison_run.get("snapshots", [])
		if comparison_snapshots.size() != oracle_snapshots.size():
			failures.append("%s AK trace length differs from pre-refactor oracle." % mode_name)
			continue
		var mismatch_count := 0
		for tick_index in range(oracle_snapshots.size()):
			var legacy_snapshot := oracle_snapshots[tick_index] as Dictionary
			var comparison_snapshot := comparison_snapshots[tick_index] as Dictionary
			for field_name in GAMEPLAY_FIELDS:
				if legacy_snapshot.get(field_name) == comparison_snapshot.get(field_name):
					continue
				failures.append(
					"%s AK diverged from pre-refactor oracle at tick %d field %s: oracle=%s comparison=%s"
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


func _action_gameplay_log(records: Array[Dictionary]) -> String:
	var lines := PackedStringArray()
	for record in records:
		lines.append("%d:%d:%s:%d:%d" % [
			int(record.get("tick", 0)),
			int(record.get("id", 0)),
			String(record.get("name", "")),
			int(record.get("direction_x", 0)),
			int(record.get("direction_y", 0)),
		])
	return "|".join(lines)


func _action_tick_name_log(records: Array[Dictionary]) -> String:
	var lines := PackedStringArray()
	for record in records:
		lines.append("%d:%s" % [
			int(record.get("tick", 0)),
			String(record.get("name", "")),
		])
	return "|".join(lines)


func _windup_gameplay_log(records: Array[Dictionary]) -> String:
	var lines := PackedStringArray()
	for record in records:
		lines.append("%d:%d:%d" % [
			int(record.get("tick", 0)),
			int(record.get("target_id", 0)),
			int(record.get("duration", 0)),
		])
	return "|".join(lines)


func _shot_gameplay_log(records: Array[Dictionary]) -> String:
	var lines := PackedStringArray()
	for record in records:
		lines.append(JSON.stringify({
			"tick": record.get("tick", 0),
			"shot_index": record.get("shot_index", 0),
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


func _event_gameplay_log(records: Array[Dictionary]) -> String:
	var lines := PackedStringArray()
	for record in records:
		lines.append("%d:%s" % [
			int(record.get("tick", 0)),
			String(record.get("event", "")),
		])
	return "|".join(lines)


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
	for simulation_mode in ALL_RUN_MODES:
		var run: Dictionary = runs.get(simulation_mode, {})
		var lines: PackedStringArray = run.get("trace_lines", PackedStringArray())
		result[_mode_name(simulation_mode)] = "\n".join(lines).sha256_text()
	return result


func _rollback_diagnostics(runs: Dictionary) -> Dictionary:
	var result := {}
	for simulation_mode in ALL_RUN_MODES:
		var run: Dictionary = runs.get(simulation_mode, {})
		result[_mode_name(simulation_mode)] = run.get("rollback", {})
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
