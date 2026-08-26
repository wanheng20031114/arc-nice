extends SceneTree

## Deterministic four-policy transcript for the shared normal/elite Lightning
## runner. The authored fixture keeps the real warning service, chain query,
## DamageRequest admission and network presentation code; only target, LOS and
## navigation answers are scripted.

const POLICY := preload(
	"res://scene/combat/simulation/enemy_simulation_policy.gd"
)
const RUNTIME_SCENE := preload(
	"res://dev_tools/fixtures/lightning_sorcerer_layered_semantic_runtime.tscn"
)
const LIGHTNING_CONFIG := preload(
	"res://resources/config/enemies/lightning_sorcerer.tres"
)
const LIGHTNING_ELITE_CONFIG := preload(
	"res://resources/config/enemies/lightning_sorcerer_elite.tres"
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
const SOURCE_NET_ID := 78_001
const SOURCE_OWNER_PEER_ID := 95
const TARGET_A_NET_ID := 78_002
const TARGET_B_NET_ID := 78_003
const TARGET_C_NET_ID := 78_004
const TARGET_D_NET_ID := 78_005
const TARGET_HEALTH := 1000
const ROLLBACK_TICK := 40
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
	"windup_left",
	"cast_direction_x",
	"cast_direction_y",
	"cast_target",
	"snapshot_faction",
	"snapshot_credit_peer",
	"snapshot_instigator",
	"snapshot_event",
	"snapshot_type",
	"cached_target",
	"objective",
	"held",
	"warning_active",
	"warning_radius",
	"warning_progress",
	"warning_positions",
	"warning_retry_deadlines",
	"cast_pivot_rotation",
	"animation",
	"source_faction",
	"target_a_faction",
	"target_b_faction",
	"target_c_faction",
	"target_d_faction",
	"target_a_dead",
	"action_sequence",
	"action_log",
	"presentation_log",
	"damage_log",
	"chain_path_log",
	"target_a_health",
	"target_b_health",
	"target_c_health",
	"target_d_health",
	"movement_submissions",
	"cooldown_updates",
	"last_cooldown_delta",
	"los_queries",
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
		"Every Lightning policy coroutine must reach its completion sentinel."
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
	print("LIGHTNING_SORCERER_LAYERED_SEMANTICS_JSON %s" % JSON.stringify(result))
	if failures.is_empty():
		print("LIGHTNING_SORCERER_LAYERED_SEMANTICS_REGRESSION_OK")
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	quit(1)


func _verify_two_config_closure_and_capabilities() -> void:
	for config in [LIGHTNING_CONFIG, LIGHTNING_ELITE_CONFIG]:
		var lightning := config.enemy_scene.instantiate() as LightningSorcerer
		_expect(
			lightning != null,
			"%s must instantiate the shared LightningSorcerer runner."
			% config.resource_path
		)
		if lightning == null:
			continue
		var script := lightning.get_script() as Script
		_expect(
			script.get_base_script() == LAYERED_RANGED_SCRIPT,
			"%s must directly inherit LayeredRangedEnemy."
			% config.resource_path
		)
		_expect(
			lightning.supports_centralized_authoritative_simulation()
			and lightning.supports_layered_area_authoritative_simulation()
			and lightning.supports_layered_contact_authoritative_simulation()
			and lightning.supports_dynamic_enemy_targeting()
			and lightning.supports_indexed_touch_authority()
			and not bool(lightning.call(&"_uses_inherited_touch_damage")),
			"%s must explicitly publish centralized/layered/contact/dynamic/indexed capability without inherited touch damage."
			% config.resource_path
		)
		var authored_areas: Array[Node] = lightning.find_children(
			"*",
			"Area2D",
			true,
			false
		)
		_expect(
			authored_areas.size() == 1
			and authored_areas[0] == lightning.get_node("TouchDamageArea"),
			"%s must have no attack Area hidden behind indexed TouchDamageArea."
			% config.resource_path
		)
		lightning.free()
	_expect(
		LIGHTNING_CONFIG.enemy_scene.resource_path
		== "res://scene/enemy/sorcerer/lightning_sorcerer.tscn"
		and LIGHTNING_ELITE_CONFIG.enemy_scene.resource_path
		== "res://scene/enemy/sorcerer/lightning_sorcerer_elite.tscn"
		and LIGHTNING_CONFIG.attack_damage == 50
		and LIGHTNING_ELITE_CONFIG.attack_damage == 80
		and LIGHTNING_CONFIG.chain_range == 48.0
		and LIGHTNING_ELITE_CONFIG.chain_range == 64.0
		and LIGHTNING_CONFIG.attack_interval == 3.0
		and LIGHTNING_ELITE_CONFIG.attack_interval == 2.0
		and LIGHTNING_CONFIG.max_health == 200
		and LIGHTNING_ELITE_CONFIG.max_health == 300,
		"The two-config closure must preserve normal/elite damage, chain, cooldown and health distinctions."
	)


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

	var source: Variant = runtime.get_node("EnemyContainer/LightningSource")
	var target_a := runtime.get_node("EnemyContainer/TargetA") as Enemy
	var target_b := runtime.get_node("EnemyContainer/TargetB") as Enemy
	var target_c := runtime.get_node("EnemyContainer/TargetC") as Enemy
	var target_d := runtime.get_node("EnemyContainer/TargetD") as Enemy
	var targets: Array[Enemy] = [target_a, target_b, target_c, target_d]
	var source_config := LIGHTNING_CONFIG.duplicate(true) as LightningSorcererConfig
	source_config.attack_range = 160.0
	source_config.chain_range = 64.0
	source_config.max_chain_bounces = 1
	source_config.windup_duration = PHYSICS_DELTA * 2.5
	source_config.attack_interval = PHYSICS_DELTA * 18.5
	source_config.initial_attack_stagger_window = 0.0
	source_config.drop_table = null
	source_config.xirang_kill_reward = 0

	source.set_meta(&"net_id", SOURCE_NET_ID)
	source.set_meta(&"owner_peer_id", SOURCE_OWNER_PEER_ID)
	for target_index in range(targets.size()):
		var target := targets[target_index]
		var target_config := TARGET_CONFIG.duplicate(true) as EnemyConfig
		_configure_target_config(target_config)
		target.set_meta(&"net_id", TARGET_A_NET_ID + target_index)
		target.setup(target_config, null, null, runtime)
		runtime.register_network_enemy(TARGET_A_NET_ID + target_index, target)
		target.set_authoritative_simulation_enabled(false)
	source.setup(source_config, null, null, runtime)
	runtime.register_network_enemy(SOURCE_NET_ID, source)
	source.set_combat_faction_id(CombatRelationService.HOSTILE_WAVE, 1, true)
	target_a.set_combat_faction_id(CombatRelationService.PLAYER_ALLIED, 1, true)
	target_b.set_combat_faction_id(CombatRelationService.PLAYER_ALLIED, 1, true)
	target_c.set_combat_faction_id(CombatRelationService.HOSTILE_WAVE, 1, true)
	target_d.set_combat_faction_id(CombatRelationService.HOSTILE_WAVE, 1, true)
	source.forced_target = null
	source.set_objective_target(null)

	await physics_frame
	await physics_frame
	_disable_automatic_callbacks(coordinator, source, targets)
	await _advance_one_tick(coordinator, source, targets)
	_reset_source_after_bootstrap(source, source_config, targets)

	_expect(
		source.supports_layered_area_authoritative_simulation()
		and source.supports_layered_contact_authoritative_simulation()
		and source.supports_indexed_touch_authority(),
		"%s Lightning must retain explicit layered/contact/indexed opt-in."
		% mode_name
	)
	if simulation_mode == POLICY.Mode.LEGACY:
		_expect(
			not source.is_centrally_simulated(),
			"LEGACY must keep Lightning on the individual runner."
		)
	else:
		_expect(
			source.is_centrally_simulated()
			and coordinator.owns_enemy(source, source.enemy_simulation_token),
			"%s must own Lightning through the coordinator." % mode_name
		)
	if simulation_mode == POLICY.Mode.LAYERED_CONTACT:
		_expect(
			source.is_indexed_touch_authority_enabled()
			and not source.touch_damage_area.monitoring
			and not source.touch_damage_area.monitorable
			and _all_touch_shapes_disabled(source),
			"LAYERED_CONTACT must replace only Lightning TouchDamageArea."
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
			"CONTACT must preserve data warning and chain authority without an attack Area."
		)
	else:
		_expect(
			not source.is_indexed_touch_authority_enabled(),
			"%s must retain authored Area contact authority." % mode_name
		)

	var context := {
		"coordinator": coordinator,
		"source": source,
		"targets": targets,
		"simulation_mode": simulation_mode,
		"rollback_restored": simulation_mode == POLICY.Mode.LEGACY,
		"rollback_released_indexed": simulation_mode == POLICY.Mode.LEGACY,
		"rollback_preserved_state": simulation_mode == POLICY.Mode.LEGACY,
	}
	var snapshots: Array[Dictionary] = []
	for tick_index in range(1, TEST_TICKS + 1):
		_apply_pre_tick_script(tick_index, context)
		await _advance_one_tick(coordinator, source, targets)
		snapshots.append(_capture_snapshot(tick_index, source, targets))

	_validate_mode_invariants(mode_name, simulation_mode, snapshots, context)
	context["proxy_contract"] = _verify_proxy_action_contract(
		source,
		source_config,
		target_c
	)
	_expect(
		bool(context["proxy_contract"]),
		"%s multiplayer proxy must preserve target/plant warning repair and terminal ordering without mutating host action_sequence."
		% mode_name
	)
	var run_result := {
		"mode": mode_name,
		"snapshots": snapshots,
		"trace_lines": _canonical_trace_lines(snapshots),
	}
	runtime.prepare_for_scene_teardown()
	runtime.queue_free()
	await process_frame
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
	source_config: LightningSorcererConfig,
	targets: Array[Enemy]
) -> void:
	var target_a := targets[0]
	var target_b := targets[1]
	var target_c := targets[2]
	var target_d := targets[3]
	source.global_position = Vector2.ZERO
	source.velocity = Vector2.ZERO
	target_a.global_position = Vector2(100.0, 0.0)
	target_b.global_position = Vector2(130.0, 0.0)
	target_c.global_position = Vector2(100.0, 0.0)
	target_d.global_position = Vector2(130.0, 0.0)
	for target in targets:
		target.current_health = TARGET_HEALTH
		target.is_dead = false
	source.combat_state = LightningSorcerer.CombatState.CHASE
	source.attack_cooldown_left = 0.0
	source.initial_attack_stagger_left = 0.0
	source.windup_time_left = 0.0
	source.cast_direction = Vector2.RIGHT
	source.cast_target = null
	source.cast_damage_source_snapshot = null
	source.cached_runtime_attack_target = null
	source.attack_target_refresh_left = 0.0
	source.warning_retry_time_left = 0.0
	source.warning_retry_sent = false
	source.layered_lightning_event_consumes_tick = false
	source.layered_lightning_windup_ready_to_resolve = false
	source.forced_target = target_a
	source.forced_los_clear = true
	source.forced_move_direction = Vector2.RIGHT
	source.call(&"_clear_target_warning")
	source.call(&"_clear_proxy_target_warning")
	source.call(&"_reset_ranged_attack_position_state")
	source.call(&"_play_config_animation", source_config.move_animation_name)
	source.reset_semantic_trace()
	# setup/_ready/bootstrap legitimately consume initialization RNG; align the
	# authored transcript only after those lifecycle calls have finished.
	source.random_generator.seed = FIXED_SEED
	source.material_drop_random_generator.seed = FIXED_SEED + 1
	source.set_objective_target(target_a)
	source.request_layered_area_urgent_decision()


func _apply_pre_tick_script(tick_index: int, context: Dictionary) -> void:
	var coordinator: EnemySimulationCoordinator = context["coordinator"]
	var source: Variant = context["source"]
	var targets: Array[Enemy] = context["targets"]
	var target_a := targets[0]
	var target_b := targets[1]
	var target_c := targets[2]
	var target_d := targets[3]
	if tick_index == 2:
		target_a.global_position = Vector2(0.0, 100.0)
		target_b.global_position = Vector2(30.0, 100.0)
	elif tick_index == 24:
		target_a.global_position = Vector2(220.0, 0.0)
		target_b.global_position = Vector2(250.0, 0.0)
		source.request_layered_area_urgent_decision()
	elif tick_index == 26:
		target_a.global_position = Vector2(100.0, 0.0)
		target_b.global_position = Vector2(130.0, 0.0)
		source.request_layered_area_urgent_decision()
	elif tick_index == 27:
		target_a.global_position = Vector2(-100.0, 0.0)
		target_b.global_position = Vector2(-130.0, 0.0)
	elif tick_index == 29:
		source.forced_los_clear = false
		source.request_layered_area_urgent_decision()
	elif tick_index == 30:
		source.forced_los_clear = true
		source.request_layered_area_urgent_decision()
	elif tick_index == 31:
		target_a.set_combat_faction_id(CombatRelationService.HOSTILE_WAVE, 2, true)
		source.request_layered_area_urgent_decision()
	elif tick_index == 32:
		target_a.set_combat_faction_id(CombatRelationService.PLAYER_ALLIED, 3, true)
		target_a.is_dead = false
		source.request_layered_area_urgent_decision()
	elif tick_index == 33:
		target_a.is_dead = true
		source.request_layered_area_urgent_decision()
	elif tick_index == 34:
		source.set_combat_faction_id(CombatRelationService.PLAYER_ALLIED, 2, true)
		target_c.set_combat_faction_id(CombatRelationService.HOSTILE_WAVE, 2, true)
		target_d.set_combat_faction_id(CombatRelationService.HOSTILE_WAVE, 2, true)
		source.forced_target = target_c
		source.set_objective_target(target_c)
		source.request_layered_area_urgent_decision()
	elif tick_index == 35:
		# The committed DamageSourceSnapshot remains PLAYER_ALLIED while the live
		# caster flips back. Both target validation and the chain must use it.
		source.set_combat_faction_id(CombatRelationService.HOSTILE_WAVE, 3, true)
		target_c.global_position = Vector2(-100.0, 0.0)
		target_d.global_position = Vector2(-130.0, 0.0)
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
	for node_variant in other_nodes:
		if node_variant == null or not is_instance_valid(node_variant):
			continue
		var node := node_variant as Node
		node.set_process(false)
		node.set_physics_process(false)


func _capture_snapshot(
	tick_index: int,
	source: Variant,
	targets: Array[Enemy]
) -> Dictionary:
	var target_a := targets[0]
	var target_b := targets[1]
	var target_c := targets[2]
	var target_d := targets[3]
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
		"windup_left": _quantize(source.windup_time_left),
		"cast_direction_x": _quantize(source.cast_direction.x),
		"cast_direction_y": _quantize(source.cast_direction.y),
		"cast_target": _target_label(source.cast_target, targets),
		"snapshot_faction": _snapshot_field_int(
			source.cast_damage_source_snapshot,
			&"source_faction_id",
			-1
		),
		"snapshot_credit_peer": _snapshot_field_int(
			source.cast_damage_source_snapshot,
			&"credit_peer_id",
			0
		),
		"snapshot_instigator": _snapshot_field_int(
			source.cast_damage_source_snapshot,
			&"instigator_entity_id",
			0
		),
		"snapshot_event": _snapshot_field_int(
			source.cast_damage_source_snapshot,
			&"event_source_id",
			0
		),
		"snapshot_type": _snapshot_field_string(
			source.cast_damage_source_snapshot,
			&"source_type"
		),
		"cached_target": _target_label(source.cached_runtime_attack_target, targets),
		"objective": _target_label(source.objective_target, targets),
		"held": 1 if bool(source.get("_ranged_attack_position_held")) else 0,
		"warning_active": 1 if source.target_warning_handle > 0 else 0,
		"warning_radius": _quantize(source.target_warning_chain_radius),
		"warning_progress": _packed_ints_to_string(source.warning_progress_log),
		"warning_positions": "|".join(source.warning_position_log),
		"warning_retry_deadlines": "|".join(
			source.warning_retry_deadline_log
		),
		"cast_pivot_rotation": _quantize(source.cast_pivot.rotation),
		"animation": String(source.animated_sprite.animation),
		"source_faction": source.get_combat_faction_id(),
		"target_a_faction": target_a.get_combat_faction_id(),
		"target_b_faction": target_b.get_combat_faction_id(),
		"target_c_faction": target_c.get_combat_faction_id(),
		"target_d_faction": target_d.get_combat_faction_id(),
		"target_a_dead": 1 if target_a.is_dead else 0,
		"action_sequence": source.action_sequence,
		"action_log": "|".join(source.action_log),
		"presentation_log": "|".join(source.presentation_log),
		"damage_log": "|".join(source.damage_log),
		"chain_path_log": "|".join(source.chain_path_log),
		"target_a_health": target_a.current_health,
		"target_b_health": target_b.current_health,
		"target_c_health": target_c.current_health,
		"target_d_health": target_d.current_health,
		"movement_submissions": source.movement_submission_count,
		"cooldown_updates": source.cooldown_update_deltas.size(),
		"last_cooldown_delta": (
			_quantize(source.cooldown_update_deltas[-1])
			if not source.cooldown_update_deltas.is_empty()
			else 0
		),
		"los_queries": source.los_query_count,
		"behavior_rng": source.random_generator.state,
		"drop_rng": source.material_drop_random_generator.state,
		"central_owned": 1 if source.is_centrally_simulated() else 0,
		"indexed_touch": 1 if source.is_indexed_touch_authority_enabled() else 0,
		"touch_area_monitoring": 1 if source.touch_damage_area.monitoring else 0,
	}


func _capture_rollback_state(source: Variant) -> Dictionary:
	return {
		"state": source.combat_state,
		"cooldown": source.attack_cooldown_left,
		"initial_stagger": source.initial_attack_stagger_left,
		"target_refresh": source.attack_target_refresh_left,
		"windup_left": source.windup_time_left,
		"cast_direction": source.cast_direction,
		"cast_target": source.cast_target,
		"cast_snapshot": source.cast_damage_source_snapshot,
		"warning_handle": source.target_warning_handle,
		"warning_radius": source.target_warning_chain_radius,
		"action_sequence": source.action_sequence,
		"rng": source.random_generator.state,
		"damage_count": source.damage_log.size(),
		"chain_count": source.chain_path_log.size(),
	}


func _verify_proxy_action_contract(
	source: Variant,
	source_config: LightningSorcererConfig,
	target: Enemy
) -> bool:
	var action_sequence_before := int(source.action_sequence)
	source.play_multiplayer_enemy_target_action_with_context(
		&"lightning_windup",
		target,
		source.global_position,
		100,
		PHYSICS_DELTA
	)
	var warning_started: bool = (
		source.latest_proxy_action_id == 100
		and source.proxy_warning_target == target
		and source.target_warning_handle > 0
		and source.proxy_warning_duration > 0.0
		and source.animated_sprite.animation == source_config.windup_animation_name
	)
	var warning_position_count: int = source.warning_position_log.size()
	target.global_position += Vector2(0.0, 8.0)
	source.call(&"_update_proxy_target_warning", PHYSICS_DELTA)
	var moving_target_followed: bool = (
		source.warning_position_log.size() == warning_position_count + 1
		and source.proxy_warning_target == target
	)
	source.play_multiplayer_enemy_target_action_with_context(
		&"lightning_windup_retry",
		target,
		source.global_position,
		99,
		0.0
	)
	var stale_retry_rejected: bool = (
		source.latest_proxy_action_id == 100
		and source.proxy_warning_target == target
	)
	source.play_multiplayer_enemy_action(&"fire", Vector2.LEFT, 101)
	var fire_terminal_applied: bool = (
		source.latest_proxy_action_id == 101
		and source.latest_proxy_terminal_action_id == 101
		and source.target_warning_handle == 0
		and source.proxy_warning_duration == 0.0
		and source.animated_sprite.animation == source_config.attack_animation_name
	)
	source.apply_multiplayer_target_presentation_state(
		Enemy.TargetPresentationPhase.LIGHTNING_WINDUP,
		target,
		source.global_position,
		101,
		0.0,
		source_config.windup_duration
	)
	var reliable_repair_did_not_reopen: bool = (
		source.latest_proxy_presentation_revision == 101
		and source.target_warning_handle == 0
		and source.proxy_warning_duration == 0.0
	)
	source.play_multiplayer_enemy_action_with_context(
		&"lightning_plant_windup",
		Vector2(16.0, 0.0),
		Vector2(10.0, 5.0),
		102,
		0.0
	)
	var plant_warning_started: bool = (
		source.latest_proxy_action_id == 102
		and source.proxy_warning_target == null
		and source.proxy_warning_plant_position == Vector2(26.0, 5.0)
		and source.target_warning_handle > 0
	)
	source.play_multiplayer_enemy_action(&"cancel", Vector2.RIGHT, 103)
	var plant_warning_cancelled: bool = (
		source.latest_proxy_action_id == 103
		and source.latest_proxy_terminal_action_id == 103
		and source.target_warning_handle == 0
		and source.proxy_warning_duration == 0.0
		and source.animated_sprite.animation == source_config.move_animation_name
		and int(source.action_sequence) == action_sequence_before
	)
	return (
		warning_started
		and moving_target_followed
		and stale_retry_rejected
		and fire_terminal_applied
		and reliable_repair_did_not_reopen
		and plant_warning_started
		and plant_warning_cancelled
	)


func _validate_mode_invariants(
	mode_name: String,
	simulation_mode: int,
	snapshots: Array[Dictionary],
	context: Dictionary
) -> void:
	if snapshots.size() != TEST_TICKS:
		failures.append("%s must capture every Lightning tick." % mode_name)
		return
	_expect_state(snapshots, 1, LightningSorcerer.CombatState.WINDUP, mode_name)
	_expect(
		int(snapshots[0]["warning_active"]) == 1
		and int(snapshots[0]["warning_radius"])
		== _quantize(64.0)
		and int(snapshots[0]["snapshot_faction"])
		== CombatRelationService.HOSTILE_WAVE
		and int(snapshots[0]["snapshot_credit_peer"])
		== SOURCE_OWNER_PEER_ID
		and int(snapshots[0]["snapshot_instigator"]) == SOURCE_NET_ID
		and int(snapshots[0]["snapshot_event"])
		== SOURCE_NET_ID * 1_000_000 + 1
		and String(snapshots[0]["snapshot_type"])
		== "lightning_sorcerer_chain",
		"%s first lock must publish warning geometry and freeze the hostile source snapshot."
		% mode_name
	)
	_expect(
		String(snapshots[3]["warning_progress"]).begins_with("0,400,800,1000")
		and String(snapshots[1]["warning_positions"]).ends_with("0,100000000"),
		"%s warning progress must remain exact while following the moving target."
		% mode_name
	)
	_expect_state(snapshots, 4, LightningSorcerer.CombatState.CHASE, mode_name)
	_expect(
		int(snapshots[3]["warning_active"]) == 0
		and int(snapshots[3]["action_sequence"]) == 2
		and int(snapshots[3]["target_a_health"])
		== TARGET_HEALTH - LIGHTNING_CONFIG.attack_damage
		and int(snapshots[3]["target_b_health"])
		== TARGET_HEALTH - LIGHTNING_CONFIG.attack_damage
		and int(snapshots[3]["target_c_health"]) == TARGET_HEALTH
		and int(snapshots[3]["target_d_health"]) == TARGET_HEALTH,
		"%s first strike must damage only the two hostile-to-source Enemy targets in chain range."
		% mode_name
	)
	var held_position_x := int(snapshots[3]["position_x"])
	for tick_number in range(5, 23):
		var held_snapshot: Dictionary = snapshots[tick_number - 1]
		_expect(
			int(held_snapshot["held"]) == 1
			and int(held_snapshot["position_x"]) == held_position_x,
			"%s cooldown ranged hold must suppress motion on tick %d."
			% [mode_name, tick_number]
		)
	_expect_state(snapshots, 23, LightningSorcerer.CombatState.WINDUP, mode_name)
	_expect_state(snapshots, 24, LightningSorcerer.CombatState.CHASE, mode_name)
	_expect(
		int(snapshots[23]["movement_submissions"])
		== int(snapshots[22]["movement_submissions"])
		and int(snapshots[24]["movement_submissions"])
		> int(snapshots[23]["movement_submissions"]),
		"%s range cancellation must consume tick 24 and resume chase on tick 25."
		% mode_name
	)
	_expect_state(snapshots, 26, LightningSorcerer.CombatState.WINDUP, mode_name)
	_expect_state(snapshots, 29, LightningSorcerer.CombatState.CHASE, mode_name)
	_expect(
		int(snapshots[28]["target_a_health"])
		== TARGET_HEALTH - LIGHTNING_CONFIG.attack_damage
		and int(snapshots[28]["action_sequence"]) == 6,
		"%s blocked LOS at expiry must cancel without a second chain."
		% mode_name
	)
	_expect_state(snapshots, 30, LightningSorcerer.CombatState.WINDUP, mode_name)
	_expect_state(snapshots, 31, LightningSorcerer.CombatState.CHASE, mode_name)
	_expect_state(snapshots, 32, LightningSorcerer.CombatState.WINDUP, mode_name)
	_expect_state(snapshots, 33, LightningSorcerer.CombatState.CHASE, mode_name)
	_expect(
		int(snapshots[30]["target_a_faction"])
		== CombatRelationService.HOSTILE_WAVE
		and int(snapshots[32]["target_a_dead"]) == 1
		and int(snapshots[32]["action_sequence"]) == 10,
		"%s committed target faction change and death must each cancel the lock."
		% mode_name
	)
	_expect_state(snapshots, 34, LightningSorcerer.CombatState.WINDUP, mode_name)
	_expect(
		int(snapshots[34]["source_faction"])
		== CombatRelationService.HOSTILE_WAVE
		and int(snapshots[34]["snapshot_faction"])
		== CombatRelationService.PLAYER_ALLIED,
		"%s live source faction changes must not rewrite the committed snapshot."
		% mode_name
	)
	_expect_state(snapshots, 37, LightningSorcerer.CombatState.CHASE, mode_name)
	var expected_first_damage := (
		"%d:%d:%d:%d:%d:%d:lightning_sorcerer_chain:1"
		% [
			TARGET_A_NET_ID,
			LIGHTNING_CONFIG.attack_damage,
			CombatRelationService.HOSTILE_WAVE,
			SOURCE_OWNER_PEER_ID,
			SOURCE_NET_ID,
			SOURCE_NET_ID * 1_000_000 + 1,
		]
	)
	var expected_second_damage := (
		"%d:%d:%d:%d:%d:%d:lightning_sorcerer_chain:1"
		% [
			TARGET_C_NET_ID,
			LIGHTNING_CONFIG.attack_damage,
			CombatRelationService.PLAYER_ALLIED,
			SOURCE_OWNER_PEER_ID,
			SOURCE_NET_ID,
			SOURCE_NET_ID * 1_000_000 + 11,
		]
	)
	_expect(
		int(snapshots[36]["action_sequence"]) == 12
		and int(snapshots[36]["target_c_health"])
		== TARGET_HEALTH - LIGHTNING_CONFIG.attack_damage
		and int(snapshots[36]["target_d_health"])
		== TARGET_HEALTH - LIGHTNING_CONFIG.attack_damage
		and String(snapshots[36]["damage_log"]).contains(expected_first_damage)
		and String(snapshots[36]["damage_log"]).contains(expected_second_damage),
		"%s second chain must retain allied-source faction, peer credit, instigator, event id and source type."
		% mode_name
	)
	var source: Variant = context["source"]
	_expect(
		source.damage_log.size() == 4
		and source.chain_path_log.size() == 2
		and source.presentation_log.size() == 12,
		"%s must emit two two-target chains and one ordered presentation edge for each lock terminal."
		% mode_name
	)
	_expect(
		String(snapshots[36]["warning_retry_deadlines"])
		== "1:1:1|5:1:1|11:1:1",
		"%s retry deadlines must fire and broadcast at actions 1/5/11 under the same frozen-snapshot relation that owns committed strike authority."
		% mode_name
	)
	_expect(
		String(snapshots[36]["action_log"])
		== (
			"1:target:lightning_windup:78002|1:retry:78002|"
			+ "2:action:fire:0,1000000|"
			+ "3:target:lightning_windup:78002|4:action:cancel:0,1000000|"
			+ "5:target:lightning_windup:78002|5:retry:78002|"
			+ "6:action:cancel:-1000000,0|"
			+ "7:target:lightning_windup:78002|8:action:cancel:-1000000,0|"
			+ "9:target:lightning_windup:78002|10:action:cancel:-1000000,0|"
			+ "11:target:lightning_windup:78004|11:retry:78004|"
			+ "12:action:fire:-1000000,0"
		),
		"%s lock/retry/fire/cancel actions must retain exact sequence, moving-target direction and frozen-relation retry authority."
		% mode_name
	)
	_expect(
		int(snapshots[55]["action_sequence"]) == 12
		and int(snapshots[55]["target_c_health"])
		== TARGET_HEALTH - LIGHTNING_CONFIG.attack_damage,
		"%s live same-faction objective must prevent a third lock after cooldown."
		% mode_name
	)
	_expect(
		bool(context["rollback_restored"])
		and bool(context["rollback_released_indexed"])
		and bool(context["rollback_preserved_state"]),
		"%s rollback must restore individual physics without changing Lightning state, warning, action or damage rows."
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
	_expect(
		source.windup_start_phases.size() == 6
		and source.strike_resolve_phases.size() == 2
		and source.cancel_phases.size() == 4
		and _all_phases_equal(source.windup_start_phases, attack_phase)
		and _all_phases_equal(source.strike_resolve_phases, attack_phase)
		and _phases_equal_exact(source.cancel_phases, expected_cancel_phases),
		"%s Lightning commits/strikes must stay in %s and cancel phases must preserve range/LOS/faction/death ordering."
		% [mode_name, attack_phase]
	)
	var expected_warning_update_phases: Array[StringName] = []
	var expected_warning_clear_phases: Array[StringName] = []
	if simulation_mode in [POLICY.Mode.LAYERED_AREA, POLICY.Mode.LAYERED_CONTACT]:
		expected_warning_update_phases = [
			&"decision", &"event", &"event", &"event",
			&"decision",
			&"decision", &"event", &"event", &"event",
			&"decision",
			&"decision",
			&"decision", &"event", &"event", &"event",
		]
		expected_warning_clear_phases = [
			&"decision", &"event", &"decision", &"event", &"event", &"decision",
		]
	else:
		for _warning_index in range(15):
			expected_warning_update_phases.append(&"legacy")
		for _clear_index in range(6):
			expected_warning_clear_phases.append(&"legacy")
	_expect(
		_phases_equal_exact(source.warning_update_phases, expected_warning_update_phases)
		and _phases_equal_exact(source.warning_clear_phases, expected_warning_clear_phases),
		"%s warning start/progress/clear mutations must stay in their authored event/decision lanes."
		% mode_name
	)
	_expect(
		source.cooldown_update_deltas.size() == TEST_TICKS
		and _all_deltas_equal(source.cooldown_update_deltas, PHYSICS_DELTA),
		"%s cooldown/stagger/target-refresh/windup clocks must remain exact 60 Hz."
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


func _target_label(target: Node2D, targets: Array[Enemy]) -> String:
	if target == targets[0]:
		return "target_a"
	if target == targets[1]:
		return "target_b"
	if target == targets[2]:
		return "target_c"
	if target == targets[3]:
		return "target_d"
	return "none"


func _snapshot_field_int(
	snapshot: DamageSourceSnapshot,
	field_name: StringName,
	default_value: int
) -> int:
	if snapshot == null:
		return default_value
	return int(snapshot.get(field_name))


func _snapshot_field_string(
	snapshot: DamageSourceSnapshot,
	field_name: StringName
) -> String:
	if snapshot == null:
		return ""
	return String(snapshot.get(field_name))


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
	var values := values_variant as PackedInt32Array
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
		for tick_number in [1, 4, 23, 24, 25, 26, 29, 31, 33, 34, 35, 37, 40, 56]:
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
