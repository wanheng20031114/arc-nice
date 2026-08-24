extends SceneTree

const POLICY := preload(
	"res://scene/combat/simulation/enemy_simulation_policy.gd"
)
const RUNTIME_SCENE := preload(
	"res://dev_tools/fixtures/fire_sorcerer_layered_semantic_runtime.tscn"
)
const FIRE_CONFIG := preload(
	"res://resources/config/enemies/fire_sorcerer.tres"
)
const FIRE_ELITE_CONFIG := preload(
	"res://resources/config/enemies/fire_sorcerer_elite.tres"
)
const TARGET_CONFIG := preload(
	"res://resources/config/enemies/yuanshi_insect_basic.tres"
)
const LAYERED_RANGED_SCRIPT := preload(
	"res://scene/enemy/layered_ranged_enemy.gd"
)

const PHYSICS_DELTA := 1.0 / 60.0
const TEST_TICKS := 56
const FIXED_SEED := 20_260_824
const SOURCE_NET_ID := 77_001
const SOURCE_OWNER_PEER_ID := 94
const TARGET_A_NET_ID := 77_002
const TARGET_B_NET_ID := 77_003
const TARGET_HEALTH := 1000
const ROLLBACK_TICK := 40
const LEGACY_SMOKE_PATHS := [
	"res://dev_tools/fire_sorcerer_smoke_test.gd",
	"res://dev_tools/fire_sorcerer_elite_smoke_test.gd",
	"res://dev_tools/fire_sorcerer_data_backend_smoke_test.gd",
	"res://dev_tools/fire_sorcerer_network_contact_smoke_test.gd",
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
	"initial_stagger",
	"target_refresh",
	"summon_left",
	"summon_direction_x",
	"summon_direction_y",
	"summon_target",
	"cached_target",
	"objective",
	"held",
	"preview_mask",
	"preview_pivot_rotation",
	"animation",
	"source_faction",
	"target_a_faction",
	"target_b_faction",
	"target_a_dead",
	"action_sequence",
	"action_log",
	"volley_attempts",
	"volley_count",
	"last_volley_mode",
	"last_volley_profile",
	"last_volley_state",
	"last_volley_mask",
	"last_volley_positions",
	"last_volley_directions",
	"last_volley_damage",
	"last_volley_speed",
	"last_volley_lifetime",
	"last_volley_target",
	"last_volley_burn_duration",
	"last_volley_burn_level",
	"last_volley_source_faction",
	"last_volley_credit_peer",
	"last_volley_instigator",
	"last_volley_event",
	"last_volley_family_type",
	"last_volley_ball0_type",
	"same_faction_a_accepted",
	"hostile_a_accepted",
	"same_faction_b_accepted",
	"hostile_b_accepted",
	"target_a_health",
	"target_b_health",
	"target_a_burning",
	"target_b_burning",
	"legacy_volley_nodes",
	"movement_submissions",
	"cooldown_updates",
	"last_cooldown_delta",
	"los_queries",
	"attack_audio_pitch",
	"behavior_rng",
	"drop_rng",
]

var failures: Array[String] = []
var completed_mode_count := 0
var burn_scheduler: Node = null


func _init() -> void:
	call_deferred(&"_run")


func _run() -> void:
	burn_scheduler = root.get_node_or_null("BurnStatusScheduler")
	if burn_scheduler != null:
		burn_scheduler.call(&"clear_all")
		burn_scheduler.set_physics_process(false)

	_verify_two_config_closure_and_capabilities()
	_verify_legacy_smoke_closure()
	var runs: Dictionary = {}
	for simulation_mode in TEST_MODES:
		runs[simulation_mode] = await _run_mode(simulation_mode)
	_expect(
		completed_mode_count == TEST_MODES.size(),
		"Every Fire policy coroutine must reach its completion sentinel."
	)
	_compare_mode_traces(runs)

	if burn_scheduler != null:
		burn_scheduler.call(&"clear_all")
		burn_scheduler.set_physics_process(false)
	var result := {
		"status": "ok" if failures.is_empty() else "failed",
		"fixed_seed": FIXED_SEED,
		"ticks": TEST_TICKS,
		"modes": _mode_names(),
		"trace_digests": _trace_digests(runs),
		"checkpoints": _checkpoint_diagnostics(runs),
		"legacy_smokes": LEGACY_SMOKE_PATHS,
		"failures": failures.duplicate(),
	}
	print("FIRE_SORCERER_LAYERED_SEMANTICS_JSON %s" % JSON.stringify(result))
	if failures.is_empty():
		print("FIRE_SORCERER_LAYERED_SEMANTICS_REGRESSION_OK")
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	quit(1)


func _verify_two_config_closure_and_capabilities() -> void:
	for config in [FIRE_CONFIG, FIRE_ELITE_CONFIG]:
		var fire := config.enemy_scene.instantiate() as FireSorcerer
		_expect(
			fire != null,
			"%s must instantiate the shared FireSorcerer runner."
			% config.resource_path
		)
		if fire == null:
			continue
		var script := fire.get_script() as Script
		_expect(
			script.get_base_script() == LAYERED_RANGED_SCRIPT,
			"%s must directly inherit LayeredRangedEnemy."
			% config.resource_path
		)
		_expect(
			fire.supports_centralized_authoritative_simulation()
			and fire.supports_layered_area_authoritative_simulation()
			and fire.supports_layered_contact_authoritative_simulation()
			and fire.supports_dynamic_enemy_targeting()
			and fire.supports_indexed_touch_authority()
			and not bool(fire.call(&"_uses_inherited_touch_damage")),
			"%s must explicitly publish centralized/layered/contact/dynamic/indexed capability without inherited touch damage."
			% config.resource_path
		)
		var authored_areas: Array[Node] = fire.find_children(
			"*",
			"Area2D",
			true,
			false
		)
		_expect(
			authored_areas.size() == 1
			and authored_areas[0] == fire.get_node("TouchDamageArea"),
			"%s must have no enemy-body attack Area hidden behind indexed TouchDamageArea."
			% config.resource_path
		)
		fire.free()
	_expect(
		FIRE_CONFIG.enemy_scene.resource_path
		== "res://scene/enemy/sorcerer/fire_sorcerer.tscn"
		and FIRE_ELITE_CONFIG.enemy_scene.resource_path
		== "res://scene/enemy/sorcerer/fire_sorcerer_elite.tscn"
		and FIRE_CONFIG.attack_damage == 40
		and FIRE_ELITE_CONFIG.attack_damage == 70
		and FIRE_CONFIG.projectile_speed == 100.0
		and FIRE_ELITE_CONFIG.projectile_speed == 115.0
		and FIRE_CONFIG.burn_level == 5
		and FIRE_ELITE_CONFIG.burn_level == 10,
		"The two-config closure must preserve normal/elite damage, speed and burn distinctions."
	)
	var normal := FIRE_CONFIG.enemy_scene.instantiate() as FireSorcerer
	var elite := FIRE_ELITE_CONFIG.enemy_scene.instantiate() as FireSorcerer
	_expect(
		normal != null
		and elite != null
		and normal.projectile_source_type
		== FireSorcerer.NORMAL_PROJECTILE_SOURCE_TYPE
		and elite.projectile_source_type
		== FireSorcerer.ELITE_PROJECTILE_SOURCE_TYPE
		and normal.call(&"_get_fire_sorcerer_volley_profile")
		== FireSorcererVolleySimulationService.Profile.NORMAL
		and elite.call(&"_get_fire_sorcerer_volley_profile")
		== FireSorcererVolleySimulationService.Profile.ELITE,
		"Normal and elite scenes must retain distinct volley profile/source identity."
	)
	if normal != null:
		normal.free()
	if elite != null:
		elite.free()


func _verify_legacy_smoke_closure() -> void:
	for smoke_path in LEGACY_SMOKE_PATHS:
		_expect(
			ResourceLoader.exists(smoke_path, "Script"),
			"Existing Fire coverage must remain available: %s" % smoke_path
		)


func _run_mode(simulation_mode: int) -> Dictionary:
	if burn_scheduler != null:
		burn_scheduler.call(&"clear_all")
		burn_scheduler.set_physics_process(false)
	var mode_name := POLICY.mode_to_name(simulation_mode)
	var runtime := RUNTIME_SCENE.instantiate() as EnemyGameplayGatewayTestRuntime
	runtime.runtime_mode = CombatRuntimeBase.RuntimeMode.SINGLEPLAYER
	var coordinator := runtime.get_node(
		"EnemySimulationCoordinator"
	) as EnemySimulationCoordinator
	coordinator.set_mode(simulation_mode)
	root.add_child(runtime)
	await process_frame

	var source: Variant = runtime.get_node("EnemyContainer/FireSource")
	var target_a := runtime.get_node("EnemyContainer/TargetA") as Enemy
	var target_b := runtime.get_node("EnemyContainer/TargetB") as Enemy
	var source_config := FIRE_CONFIG.duplicate(true) as FireSorcererConfig
	source_config.summon_duration = PHYSICS_DELTA * 2.5
	source_config.attack_interval = PHYSICS_DELTA * 18.5
	source_config.initial_attack_stagger_window = 0.0
	source_config.drop_table = null
	source_config.xirang_kill_reward = 0
	var target_a_config := TARGET_CONFIG.duplicate(true) as EnemyConfig
	_configure_target_config(target_a_config)
	var target_b_config := TARGET_CONFIG.duplicate(true) as EnemyConfig
	_configure_target_config(target_b_config)

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
	source.set_combat_faction_id(CombatRelationService.HOSTILE_WAVE, 1, true)
	target_a.set_combat_faction_id(CombatRelationService.PLAYER_ALLIED, 1, true)
	target_b.set_combat_faction_id(CombatRelationService.PLAYER_ALLIED, 1, true)
	target_a.set_authoritative_simulation_enabled(false)
	target_b.set_authoritative_simulation_enabled(false)
	source.forced_target = null
	source.set_objective_target(null)

	await physics_frame
	await physics_frame
	_disable_automatic_callbacks(coordinator, source, [target_a, target_b])
	await _advance_one_tick(coordinator, source, [target_a, target_b])
	var volley_service := source.call(
		&"_get_fire_sorcerer_volley_simulation_service"
	) as FireSorcererVolleySimulationService
	_expect(volley_service != null, "%s must mount the Fire volley service." % mode_name)
	if volley_service != null:
		volley_service.set_physics_process(false)
	_reset_source_after_bootstrap(source, source_config, target_a, target_b)

	_expect(
		source.supports_layered_area_authoritative_simulation()
		and source.supports_layered_contact_authoritative_simulation()
		and source.supports_indexed_touch_authority(),
		"%s Fire must retain explicit layered/contact/indexed opt-in." % mode_name
	)
	if simulation_mode == POLICY.Mode.LEGACY:
		_expect(
			not source.is_centrally_simulated(),
			"LEGACY must keep Fire on the individual runner."
		)
	else:
		_expect(
			source.is_centrally_simulated()
			and coordinator.owns_enemy(source, source.enemy_simulation_token),
			"%s must own Fire through the coordinator." % mode_name
		)
	if simulation_mode == POLICY.Mode.LAYERED_CONTACT:
		_expect(
			source.is_indexed_touch_authority_enabled()
			and not source.touch_damage_area.monitoring
			and not source.touch_damage_area.monitorable
			and _all_touch_shapes_disabled(source),
			"LAYERED_CONTACT must replace only Fire TouchDamageArea."
		)
		var authored_areas: Array[Node] = source.find_children(
			"*",
			"Area2D",
			true,
			false
		)
		_expect(
			authored_areas.size() == 1
			and authored_areas[0] == source.touch_damage_area,
			"CONTACT must not disable any Fire warning or projectile authority Area."
		)
	else:
		_expect(
			not source.is_indexed_touch_authority_enabled(),
			"%s must retain authored Area contact authority." % mode_name
		)

	var context := {
		"coordinator": coordinator,
		"source": source,
		"target_a": target_a,
		"target_b": target_b,
		"simulation_mode": simulation_mode,
		"same_faction_a_accepted": false,
		"hostile_a_accepted": false,
		"same_faction_b_accepted": false,
		"hostile_b_accepted": false,
		"rollback_restored": simulation_mode == POLICY.Mode.LEGACY,
		"rollback_released_indexed": simulation_mode == POLICY.Mode.LEGACY,
		"rollback_preserved_state": simulation_mode == POLICY.Mode.LEGACY,
	}
	var snapshots: Array[Dictionary] = []
	for tick_index in range(1, TEST_TICKS + 1):
		_apply_pre_tick_script(tick_index, context)
		await _advance_one_tick(coordinator, source, [target_a, target_b])
		snapshots.append(
			_capture_snapshot(tick_index, source, target_a, target_b, context)
		)

	context["proxy_contract"] = _verify_proxy_action_contract(source, source_config)
	_validate_mode_invariants(mode_name, simulation_mode, snapshots, context)
	var run_result := {
		"mode": mode_name,
		"snapshots": snapshots,
		"trace_lines": _canonical_trace_lines(snapshots),
	}
	runtime.prepare_for_scene_teardown()
	runtime.queue_free()
	await process_frame
	if burn_scheduler != null:
		burn_scheduler.call(&"clear_all")
		burn_scheduler.set_physics_process(false)
	completed_mode_count += 1
	return run_result


func _configure_target_config(target_config: EnemyConfig) -> void:
	target_config.max_health = TARGET_HEALTH
	target_config.physical_defense = 0
	target_config.magic_defense = 0
	target_config.drop_table = null
	target_config.xirang_kill_reward = 0


func _reset_source_after_bootstrap(
	source: Variant,
	source_config: FireSorcererConfig,
	target_a: Enemy,
	target_b: Enemy
) -> void:
	source.global_position = Vector2.ZERO
	source.velocity = Vector2.ZERO
	target_a.global_position = Vector2(120.0, 0.0)
	target_b.global_position = Vector2(120.0, 0.0)
	source.combat_state = FireSorcerer.CombatState.CHASE
	source.attack_cooldown_left = 0.0
	source.initial_attack_stagger_left = 0.0
	source.summon_time_left = 0.0
	source.summon_direction = Vector2.RIGHT
	source.summon_target = null
	source.cached_runtime_attack_target = null
	source.attack_target_refresh_left = 0.0
	source.layered_fire_event_consumes_tick = false
	source.layered_fire_summon_ready_to_resolve = false
	source.forced_target = target_a
	source.forced_target_valid = true
	source.forced_target_in_range = true
	source.forced_los_clear = true
	source.forced_move_direction = Vector2.RIGHT
	source.call(&"_reset_ranged_attack_position_state")
	source.call(&"_play_config_animation", source_config.move_animation_name)
	source.call(&"_hide_summon_previews")
	source.reset_semantic_trace()
	# Seed after setup/_ready/bootstrap; setup legitimately consumes deterministic
	# initialization RNG and must not offset one policy relative to another.
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
		target_a.global_position = Vector2(0.0, 120.0)
	elif tick_index == 5:
		target_a.set_combat_faction_id(CombatRelationService.HOSTILE_WAVE, 2, true)
		context["same_faction_a_accepted"] = source.apply_recorded_ball_contact(
			0,
			0,
			target_a
		)
		source.request_layered_area_urgent_decision()
	elif tick_index == 6:
		target_a.set_combat_faction_id(CombatRelationService.PLAYER_ALLIED, 3, true)
		context["hostile_a_accepted"] = source.apply_recorded_ball_contact(
			0,
			0,
			target_a
		)
		_disable_burn_scheduler()
		source.request_layered_area_urgent_decision()
	elif tick_index == 24:
		source.forced_target_in_range = false
		source.request_layered_area_urgent_decision()
	elif tick_index == 26:
		source.forced_target_in_range = true
		source.request_layered_area_urgent_decision()
	elif tick_index == 27:
		target_a.global_position = Vector2(-120.0, 0.0)
	elif tick_index == 29:
		source.forced_los_clear = false
		source.request_layered_area_urgent_decision()
	elif tick_index == 30:
		source.forced_los_clear = true
		source.request_layered_area_urgent_decision()
	elif tick_index == 31:
		target_a.set_combat_faction_id(CombatRelationService.HOSTILE_WAVE, 4, true)
		source.request_layered_area_urgent_decision()
	elif tick_index == 32:
		target_a.set_combat_faction_id(CombatRelationService.PLAYER_ALLIED, 5, true)
		target_a.is_dead = false
		source.request_layered_area_urgent_decision()
	elif tick_index == 33:
		target_a.is_dead = true
		source.request_layered_area_urgent_decision()
	elif tick_index == 34:
		source.set_combat_faction_id(CombatRelationService.PLAYER_ALLIED, 2, true)
		target_b.set_combat_faction_id(CombatRelationService.HOSTILE_WAVE, 2, true)
		source.forced_target = target_b
		source.set_objective_target(target_b)
		source.request_layered_area_urgent_decision()
	elif tick_index == 35:
		target_b.global_position = Vector2(-120.0, 0.0)
	elif tick_index == 38:
		target_b.set_combat_faction_id(CombatRelationService.PLAYER_ALLIED, 3, true)
		context["same_faction_b_accepted"] = source.apply_recorded_ball_contact(
			1,
			0,
			target_b
		)
		source.request_layered_area_urgent_decision()
	elif tick_index == 39:
		target_b.set_combat_faction_id(CombatRelationService.HOSTILE_WAVE, 4, true)
		context["hostile_b_accepted"] = source.apply_recorded_ball_contact(
			1,
			0,
			target_b
		)
		_disable_burn_scheduler()
		source.request_layered_area_urgent_decision()
	elif tick_index == ROLLBACK_TICK:
		var before_rollback := _capture_rollback_state(source)
		if int(context["simulation_mode"]) != POLICY.Mode.LEGACY:
			coordinator.set_mode(POLICY.Mode.LEGACY)
			context["rollback_restored"] = source.is_physics_processing()
			context["rollback_released_indexed"] = (
				not source.is_indexed_touch_authority_enabled()
			)
		else:
			context["rollback_restored"] = not source.is_centrally_simulated()
			context["rollback_released_indexed"] = (
				not source.is_indexed_touch_authority_enabled()
			)
		context["rollback_preserved_state"] = (
			_capture_rollback_state(source) == before_rollback
		)
		source.set_physics_process(false)
		coordinator.set_physics_process(false)
	elif tick_index == 55:
		target_b.set_combat_faction_id(CombatRelationService.PLAYER_ALLIED, 5, true)
		source.request_layered_area_urgent_decision()


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


func _disable_automatic_callbacks(
	coordinator: EnemySimulationCoordinator,
	source: Variant,
	other_nodes: Array
) -> void:
	coordinator.set_physics_process(false)
	if source != null and is_instance_valid(source):
		source.set_process(false)
		source.set_physics_process(false)
		var service := source.call(
			&"_get_fire_sorcerer_volley_simulation_service"
		) as FireSorcererVolleySimulationService
		if service != null:
			service.set_physics_process(false)
	for node_variant in other_nodes:
		if node_variant == null or not is_instance_valid(node_variant):
			continue
		var node := node_variant as Node
		node.set_process(false)
		node.set_physics_process(false)
	_disable_burn_scheduler()


func _disable_burn_scheduler() -> void:
	if burn_scheduler != null:
		burn_scheduler.set_physics_process(false)


func _capture_snapshot(
	tick_index: int,
	source: Variant,
	target_a: Enemy,
	target_b: Enemy,
	context: Dictionary
) -> Dictionary:
	var last_volley: Dictionary = (
		source.volley_records[-1]
		if not source.volley_records.is_empty()
		else {}
	)
	return {
		"tick": tick_index,
		"state": source.combat_state,
		"position_x": _quantize(source.global_position.x),
		"position_y": _quantize(source.global_position.y),
		"velocity_x": _quantize(source.velocity.x),
		"velocity_y": _quantize(source.velocity.y),
		"cooldown": _quantize(source.attack_cooldown_left),
		"initial_stagger": _quantize(source.initial_attack_stagger_left),
		"target_refresh": _quantize(source.attack_target_refresh_left),
		"summon_left": _quantize(source.summon_time_left),
		"summon_direction_x": _quantize(source.summon_direction.x),
		"summon_direction_y": _quantize(source.summon_direction.y),
		"summon_target": _target_label(source.summon_target, target_a, target_b),
		"cached_target": _target_label(
			source.cached_runtime_attack_target,
			target_a,
			target_b
		),
		"objective": _target_label(source.objective_target, target_a, target_b),
		"held": 1 if bool(source.get("_ranged_attack_position_held")) else 0,
		"preview_mask": _preview_visible_mask(source),
		"preview_pivot_rotation": _quantize(source.summon_pivot.rotation),
		"preview_scale_milli": _preview_scale_milli(source),
		"animation": String(source.animated_sprite.animation),
		"source_faction": source.get_combat_faction_id(),
		"target_a_faction": target_a.get_combat_faction_id(),
		"target_b_faction": target_b.get_combat_faction_id(),
		"target_a_dead": 1 if target_a.is_dead else 0,
		"action_sequence": source.action_sequence,
		"action_log": "|".join(source.action_log),
		"volley_attempts": source.volley_attempt_count,
		"volley_count": source.volley_records.size(),
		"last_volley_mode": int(last_volley.get("mode", 0)),
		"last_volley_profile": int(last_volley.get("profile", 0)),
		"last_volley_state": int(last_volley.get("state", 0)),
		"last_volley_mask": int(last_volley.get("mask", 0)),
		"last_volley_positions": _packed_ints_to_string(
			last_volley.get("positions", PackedInt64Array())
		),
		"last_volley_directions": _packed_ints_to_string(
			last_volley.get("directions", PackedInt64Array())
		),
		"last_volley_damage": int(last_volley.get("damage", 0)),
		"last_volley_speed": int(last_volley.get("speed", 0)),
		"last_volley_lifetime": int(last_volley.get("lifetime", 0)),
		"last_volley_target": int(last_volley.get("target_net_id", 0)),
		"last_volley_burn_duration": int(last_volley.get("burn_duration", 0)),
		"last_volley_burn_level": int(last_volley.get("burn_level", 0)),
		"last_volley_source_faction": int(last_volley.get("source_faction", -1)),
		"last_volley_credit_peer": int(last_volley.get("credit_peer", 0)),
		"last_volley_instigator": int(last_volley.get("instigator", 0)),
		"last_volley_event": int(last_volley.get("event_id", 0)),
		"last_volley_family_type": String(last_volley.get("family_source_type", "")),
		"last_volley_ball0_type": String(last_volley.get("ball0_source_type", "")),
		"same_faction_a_accepted": 1 if bool(context["same_faction_a_accepted"]) else 0,
		"hostile_a_accepted": 1 if bool(context["hostile_a_accepted"]) else 0,
		"same_faction_b_accepted": 1 if bool(context["same_faction_b_accepted"]) else 0,
		"hostile_b_accepted": 1 if bool(context["hostile_b_accepted"]) else 0,
		"target_a_health": target_a.current_health,
		"target_b_health": target_b.current_health,
		"target_a_burning": _burn_state(target_a),
		"target_b_burning": _burn_state(target_b),
		"legacy_volley_nodes": _count_legacy_volley_nodes(source.combat_runtime),
		"movement_submissions": source.movement_submission_count,
		"cooldown_updates": source.cooldown_update_deltas.size(),
		"last_cooldown_delta": (
			_quantize(source.cooldown_update_deltas[-1])
			if not source.cooldown_update_deltas.is_empty()
			else 0
		),
		"los_queries": source.los_query_count,
		"attack_audio_pitch": _quantize(source.attack_audio.pitch_scale),
		"behavior_rng": source.random_generator.state,
		"drop_rng": source.material_drop_random_generator.state,
		"central_owned": 1 if source.is_centrally_simulated() else 0,
		"indexed_touch": 1 if source.is_indexed_touch_authority_enabled() else 0,
		"touch_area_monitoring": 1 if source.touch_damage_area.monitoring else 0,
	}


func _capture_rollback_state(source: Variant) -> Dictionary:
	var service := source.call(
		&"_get_fire_sorcerer_volley_simulation_service"
	) as FireSorcererVolleySimulationService
	return {
		"state": source.combat_state,
		"cooldown": source.attack_cooldown_left,
		"initial_stagger": source.initial_attack_stagger_left,
		"target_refresh": source.attack_target_refresh_left,
		"summon_left": source.summon_time_left,
		"direction": source.summon_direction,
		"target": source.summon_target,
		"action_sequence": source.action_sequence,
		"rng": source.random_generator.state,
		"attack_audio_pitch": source.attack_audio.pitch_scale,
		"preview_mask": _preview_visible_mask(source),
		"volley_records": source.volley_records.size(),
		"service_dense": service.get_dense_record_count() if service != null else -1,
		"service_active": service.get_active_slot_count() if service != null else -1,
	}


func _verify_proxy_action_contract(
	source: Variant,
	source_config: FireSorcererConfig
) -> bool:
	var action_sequence_before := int(source.action_sequence)
	source.play_multiplayer_enemy_action(&"summon", Vector2.UP, 100)
	var summon_visible: bool = (
		source.latest_proxy_action_id == 100
		and _preview_visible_mask(source) == 7
		and is_equal_approx(source.summon_pivot.rotation, Vector2.UP.angle())
		and source.animated_sprite.animation == source_config.windup_animation_name
	)
	source.play_multiplayer_enemy_action(&"cancel", Vector2.LEFT, 99)
	var stale_rejected: bool = (
		source.latest_proxy_action_id == 100
		and _preview_visible_mask(source) == 7
	)
	source.play_multiplayer_enemy_action(&"fire", Vector2.LEFT, 101)
	var fire_applied: bool = (
		source.latest_proxy_action_id == 101
		and _preview_visible_mask(source) == 0
		and source.animated_sprite.animation == source_config.attack_animation_name
	)
	source.play_multiplayer_enemy_action(&"summon", Vector2.RIGHT, 102)
	source.play_multiplayer_enemy_action(&"cancel", Vector2.RIGHT, 103)
	var cancel_applied: bool = (
		source.latest_proxy_action_id == 103
		and _preview_visible_mask(source) == 0
		and source.animated_sprite.animation == source_config.move_animation_name
		and int(source.action_sequence) == action_sequence_before
	)
	return summon_visible and stale_rejected and fire_applied and cancel_applied


func _validate_mode_invariants(
	mode_name: String,
	simulation_mode: int,
	snapshots: Array[Dictionary],
	context: Dictionary
) -> void:
	if snapshots.size() != TEST_TICKS:
		failures.append("%s must capture every Fire tick." % mode_name)
		return
	_expect_state(snapshots, 1, FireSorcerer.CombatState.SUMMON, mode_name)
	_expect(
		int(snapshots[0]["preview_mask"]) == 7
		and int(snapshots[1]["summon_direction_y"]) > 0,
		"%s summon warning must show all previews and track target movement."
		% mode_name
	)
	_expect_state(snapshots, 4, FireSorcerer.CombatState.CHASE, mode_name)
	_expect(
		int(snapshots[3]["preview_mask"]) == 0
		and int(snapshots[3]["action_sequence"]) == 2
		and int(snapshots[3]["volley_count"]) == 1
		and int(snapshots[3]["legacy_volley_nodes"]) == 0
		and int(snapshots[3]["attack_audio_pitch"]) >= 950_000
		and int(snapshots[3]["attack_audio_pitch"]) <= 1_050_000
		and snapshots[3]["behavior_rng"] != snapshots[2]["behavior_rng"],
		"%s first warning/fire must hide previews, order actions and register DATA only."
		% mode_name
	)
	_expect(
		int(snapshots[4]["same_faction_a_accepted"]) == 0
		and int(snapshots[4]["target_a_health"]) == TARGET_HEALTH
		and int(snapshots[4]["target_a_burning"]) == 0,
		"%s same-faction volley contact must reject damage and burn." % mode_name
	)
	_expect(
		int(snapshots[5]["hostile_a_accepted"]) == 1
		and int(snapshots[5]["target_a_health"])
		== TARGET_HEALTH - FIRE_CONFIG.attack_damage
		and int(snapshots[5]["target_a_burning"]) == 1,
		"%s hostile Enemy contact must apply configured magic damage and burn."
		% mode_name
	)
	var held_position_x := int(snapshots[5]["position_x"])
	for tick_number in range(7, 23):
		var held_snapshot: Dictionary = snapshots[tick_number - 1]
		_expect(
			int(held_snapshot["held"]) == 1
			and int(held_snapshot["position_x"]) == held_position_x,
			"%s cooldown ranged hold must suppress motion on tick %d."
			% [mode_name, tick_number]
		)
	_expect_state(snapshots, 23, FireSorcerer.CombatState.SUMMON, mode_name)
	_expect_state(snapshots, 24, FireSorcerer.CombatState.CHASE, mode_name)
	_expect(
		int(snapshots[23]["movement_submissions"])
		== int(snapshots[22]["movement_submissions"])
		and int(snapshots[24]["movement_submissions"])
		> int(snapshots[23]["movement_submissions"]),
		"%s range cancellation must consume tick 24 and resume chase on tick 25."
		% mode_name
	)
	_expect_state(snapshots, 26, FireSorcerer.CombatState.SUMMON, mode_name)
	_expect_state(snapshots, 29, FireSorcerer.CombatState.CHASE, mode_name)
	_expect(
		int(snapshots[28]["volley_count"]) == 1,
		"%s blocked LOS at expiry must cancel without firing." % mode_name
	)
	_expect_state(snapshots, 30, FireSorcerer.CombatState.SUMMON, mode_name)
	_expect_state(snapshots, 31, FireSorcerer.CombatState.CHASE, mode_name)
	_expect_state(snapshots, 32, FireSorcerer.CombatState.SUMMON, mode_name)
	_expect_state(snapshots, 33, FireSorcerer.CombatState.CHASE, mode_name)
	_expect(
		int(snapshots[30]["volley_count"]) == 1
		and int(snapshots[32]["volley_count"]) == 1,
		"%s friendly-faction and dead committed targets must cancel summon."
		% mode_name
	)
	_expect_state(snapshots, 34, FireSorcerer.CombatState.SUMMON, mode_name)
	_expect_state(snapshots, 37, FireSorcerer.CombatState.CHASE, mode_name)
	_expect(
		int(snapshots[36]["action_sequence"]) == 12
		and int(snapshots[36]["volley_count"]) == 2
		and snapshots[36]["behavior_rng"] != snapshots[35]["behavior_rng"]
		and String(snapshots[36]["action_log"])
		== (
			"1:summon|2:fire|3:summon|4:cancel|5:summon|6:cancel|"
			+ "7:summon|8:cancel|9:summon|10:cancel|11:summon|12:fire"
		),
		"%s summon/fire/cancel multiplayer actions must retain exact sequence."
		% mode_name
	)
	_expect(
		int(snapshots[37]["same_faction_b_accepted"]) == 0
		and int(snapshots[37]["target_b_health"]) == TARGET_HEALTH
		and int(snapshots[37]["target_b_burning"]) == 0,
		"%s runtime-allied source must not damage or burn its temporary ally."
		% mode_name
	)
	_expect(
		int(snapshots[38]["hostile_b_accepted"]) == 1
		and int(snapshots[38]["target_b_health"])
		== TARGET_HEALTH - FIRE_CONFIG.attack_damage
		and int(snapshots[38]["target_b_burning"]) == 1,
		"%s runtime-allied source must damage and burn a hostile Enemy."
		% mode_name
	)
	_expect(
		String(snapshots[3]["last_volley_directions"])
		== "0,1000000,0,1000000,0,1000000"
		and String(snapshots[36]["last_volley_directions"])
		== "-1000000,0,-1000000,0,-1000000,0",
		"%s all three balls must freeze the latest moving-target direction."
		% mode_name
	)
	_expect(
		int(snapshots[3]["last_volley_mode"])
		== FireSorcererVolleySimulationService.Mode.DATA
		and int(snapshots[3]["last_volley_profile"])
		== FireSorcererVolleySimulationService.Profile.NORMAL
		and int(snapshots[3]["last_volley_state"])
		== FireSorcererVolleySimulationService.SlotState.PENDING_ACTIVATION
		and int(snapshots[3]["last_volley_mask"])
		== FireSorcererVolleySimulationService.ALL_BALLS_MASK
		and int(snapshots[36]["last_volley_damage"])
		== FIRE_CONFIG.attack_damage
		and int(snapshots[36]["last_volley_speed"])
		== _quantize(FIRE_CONFIG.projectile_speed)
		and int(snapshots[36]["last_volley_lifetime"])
		== _quantize(FIRE_CONFIG.projectile_lifetime)
		and int(snapshots[36]["last_volley_burn_duration"])
		== _quantize(FIRE_CONFIG.burn_duration)
		and int(snapshots[36]["last_volley_burn_level"])
		== FIRE_CONFIG.burn_level,
		"%s DATA volley must preserve profile, three-ball mask and authored payload."
		% mode_name
	)
	_expect(
		int(snapshots[3]["last_volley_target"]) == TARGET_A_NET_ID
		and int(snapshots[3]["last_volley_source_faction"])
		== CombatRelationService.HOSTILE_WAVE
		and int(snapshots[36]["last_volley_target"]) == TARGET_B_NET_ID
		and int(snapshots[36]["last_volley_source_faction"])
		== CombatRelationService.PLAYER_ALLIED
		and int(snapshots[36]["last_volley_credit_peer"])
		== SOURCE_OWNER_PEER_ID
		and int(snapshots[36]["last_volley_instigator"])
		== SOURCE_NET_ID
		and String(snapshots[36]["last_volley_family_type"])
		== "fire_sorcerer_fireball_volley"
		and String(snapshots[36]["last_volley_ball0_type"])
		== "fire_sorcerer_fireball_a",
		"%s volley must freeze target, faction, credit, instigator and source types."
		% mode_name
	)
	_expect(
		int(snapshots[55]["volley_count"]) == 2
		and int(snapshots[55]["action_sequence"]) == 12,
		"%s friendly target at cooldown expiry must prevent a third summon."
		% mode_name
	)
	_expect(
		bool(context["rollback_restored"])
		and bool(context["rollback_released_indexed"])
		and bool(context["rollback_preserved_state"]),
		"%s rollback must restore individual physics without changing Fire state/RNG/volley rows."
		% mode_name
	)
	_expect(
		int(snapshots[ROLLBACK_TICK - 2]["central_owned"])
		== (0 if simulation_mode == POLICY.Mode.LEGACY else 1)
		and int(snapshots[ROLLBACK_TICK - 1]["central_owned"]) == 0,
		"%s rollback must transfer ownership exactly at tick %d."
		% [mode_name, ROLLBACK_TICK]
	)
	if simulation_mode == POLICY.Mode.LAYERED_CONTACT:
		_expect(
			int(snapshots[ROLLBACK_TICK - 2]["indexed_touch"]) == 1
			and int(snapshots[ROLLBACK_TICK - 1]["indexed_touch"]) == 0
			and int(snapshots[ROLLBACK_TICK - 1]["touch_area_monitoring"]) == 1,
			"CONTACT rollback must release indexed authority and restore TouchDamageArea."
		)
	var attack_phase := (
		&"decision"
		if simulation_mode in [POLICY.Mode.LAYERED_AREA, POLICY.Mode.LAYERED_CONTACT]
		else &"legacy"
	)
	var expected_cancel_phases: Array[StringName] = []
	if simulation_mode in [POLICY.Mode.LAYERED_AREA, POLICY.Mode.LAYERED_CONTACT]:
		expected_cancel_phases = [&"event", &"decision", &"event", &"event"]
	else:
		expected_cancel_phases = [&"legacy", &"legacy", &"legacy", &"legacy"]
	var source: Variant = context["source"]
	_expect(
		source.summon_start_phases.size() == 6
		and source.fire_resolve_phases.size() == 2
		and source.cancel_phases.size() == 4
		and _all_phases_equal(source.summon_start_phases, attack_phase)
		and _all_phases_equal(source.fire_resolve_phases, attack_phase)
		and _phases_equal_exact(source.cancel_phases, expected_cancel_phases),
		"%s Fire commits/fires must stay in %s and cancel phases must preserve range/LOS/faction/death ordering."
		% [mode_name, attack_phase]
	)
	_expect(
		source.cooldown_update_deltas.size() == TEST_TICKS
		and _all_deltas_equal(source.cooldown_update_deltas, PHYSICS_DELTA),
		"%s cooldown/stagger/refresh/SUMMON clocks must remain exact 60 Hz."
		% mode_name
	)
	_expect(
		bool(context.get("proxy_contract", false)),
		"%s multiplayer proxy must reject stale actions and replay summon/fire/cancel warning visuals without mutating Host action_sequence."
		% mode_name
	)


func _compare_mode_traces(runs: Dictionary) -> void:
	var legacy_run: Dictionary = runs.get(POLICY.Mode.LEGACY, {})
	var legacy_snapshots: Array = legacy_run.get("snapshots", [])
	for comparison_mode in [
		POLICY.Mode.COMPAT_60,
		POLICY.Mode.LAYERED_AREA,
		POLICY.Mode.LAYERED_CONTACT,
	]:
		var mode_name := POLICY.mode_to_name(comparison_mode)
		var comparison_run: Dictionary = runs.get(comparison_mode, {})
		var comparison_snapshots: Array = comparison_run.get("snapshots", [])
		if comparison_snapshots.size() != legacy_snapshots.size():
			failures.append("%s trace length differs from LEGACY." % mode_name)
			continue
		var mismatch_count := 0
		for tick_index in range(legacy_snapshots.size()):
			var legacy_snapshot: Dictionary = legacy_snapshots[tick_index]
			var comparison_snapshot: Dictionary = comparison_snapshots[tick_index]
			for field_name in GAMEPLAY_FIELDS:
				if legacy_snapshot.get(field_name) == comparison_snapshot.get(field_name):
					continue
				failures.append(
					"%s diverged from LEGACY at tick %d field %s: legacy=%s comparison=%s"
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


func _expect_state(
	snapshots: Array[Dictionary],
	tick_number: int,
	expected_state: int,
	mode_name: String
) -> void:
	_expect(
		int(snapshots[tick_number - 1]["state"]) == expected_state,
		"%s tick %d must be state %d (got %s)."
		% [
			mode_name,
			tick_number,
			expected_state,
			str(snapshots[tick_number - 1]["state"]),
		]
	)


func _target_label(target: Node2D, target_a: Enemy, target_b: Enemy) -> String:
	if target == target_a:
		return "target_a"
	if target == target_b:
		return "target_b"
	return "none"


func _preview_visible_mask(source: Variant) -> int:
	var mask := 0
	for preview_index in range(source.summon_previews.size()):
		if source.summon_previews[preview_index].visible:
			mask |= 1 << preview_index
	return mask


func _preview_scale_milli(source: Variant) -> PackedInt32Array:
	var result := PackedInt32Array()
	for preview in source.summon_previews:
		result.append(roundi(preview.scale.x * 1_000.0))
	return result


func _count_legacy_volley_nodes(runtime: Node) -> int:
	var count := 0
	for node in runtime.find_children("*", "Node", true, false):
		if node is FireSorcererFireballVolley:
			count += 1
	return count


func _burn_state(target: Object) -> int:
	var enemy := target as Enemy
	if enemy == null:
		return 0
	return 1 if enemy.has_damage_over_time_status(
		&"burn",
		FireSorcererVolleySimulationService.NORMAL_FAMILY_SOURCE_TYPE
	) else 0


func _all_touch_shapes_disabled(source: Variant) -> bool:
	for shape_variant in source.touch_damage_shapes:
		var shape := shape_variant as CollisionShape2D
		if shape != null and not shape.disabled:
			return false
	return true


func _all_phases_equal(phases: Array, expected_phase: StringName) -> bool:
	for phase_variant in phases:
		if StringName(phase_variant) != expected_phase:
			return false
	return true


func _phases_equal_exact(actual: Array, expected: Array[StringName]) -> bool:
	if actual.size() != expected.size():
		return false
	for phase_index in range(expected.size()):
		if StringName(actual[phase_index]) != expected[phase_index]:
			return false
	return true


func _all_deltas_equal(deltas: Array, expected_delta: float) -> bool:
	for delta_variant in deltas:
		if not is_equal_approx(float(delta_variant), expected_delta):
			return false
	return true


func _packed_ints_to_string(values_variant: Variant) -> String:
	var values := values_variant as PackedInt64Array
	var parts := PackedStringArray()
	for value in values:
		parts.append(str(value))
	return ",".join(parts)


func _canonical_trace_lines(snapshots: Array[Dictionary]) -> PackedStringArray:
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
		result[POLICY.mode_to_name(simulation_mode)] = "\n".join(lines).sha256_text()
	return result


func _checkpoint_diagnostics(runs: Dictionary) -> Dictionary:
	var result := {}
	for simulation_mode in TEST_MODES:
		var run: Dictionary = runs.get(simulation_mode, {})
		var snapshots: Array = run.get("snapshots", [])
		var checkpoints := {}
		for tick_number in [1, 4, 5, 6, 23, 24, 29, 31, 33, 37, 38, 39, 40, 56]:
			checkpoints[str(tick_number)] = (
				snapshots[tick_number - 1].duplicate(true)
				if snapshots.size() >= tick_number
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
