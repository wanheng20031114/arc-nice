extends "res://dev_tools/capoo_knight_layered_semantics_regression.gd"

## Independent Swordsman vertical slice. Shared assertions intentionally reuse
## the proven Knight-family golden runner, while this script owns its authored
## scene/config closure, compound CONTACT and multiplayer proxy contract.

const SWORDSMAN_RUNTIME_SCENE := preload(
	"res://dev_tools/fixtures/capoo_swordsman_layered_semantic_runtime.tscn"
)
const SWORD_CONFIG := preload(
	"res://resources/config/enemies/capoo_swordsman.tres"
)
const STONE_SWORD_CONFIG := preload(
	"res://resources/config/enemies/stone_eroded_capoo_swordsman.tres"
)


func _run() -> void:
	_verify_swordsman_config_closure()
	await _verify_multiplayer_proxy_actions()

	var runs: Dictionary = {}
	for simulation_mode in TEST_MODES:
		runs[simulation_mode] = await _run_swordsman_mode(simulation_mode)
	_expect(
		completed_mode_count == TEST_MODES.size(),
		"Every Swordsman policy coroutine must reach its completion sentinel."
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
	print("CAPOO_SWORDSMAN_LAYERED_SEMANTICS_JSON %s" % JSON.stringify(result))
	if failures.is_empty():
		print("CAPOO_SWORDSMAN_LAYERED_SEMANTICS_REGRESSION_OK")
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	quit(1)


func _verify_swordsman_config_closure() -> void:
	for config_variant in [SWORD_CONFIG, STONE_SWORD_CONFIG]:
		var config := config_variant as EnemyConfig
		var enemy := _instantiate_config_enemy(config) as CapooSwordsman
		if enemy == null:
			failures.append(
				"%s must instantiate CapooSwordsman." % config.resource_path
			)
			continue
		var shape_kinds := _get_authored_touch_shape_kinds(enemy)
		_expect(
			enemy.supports_centralized_authoritative_simulation()
			and enemy.supports_layered_area_authoritative_simulation()
			and enemy.supports_dynamic_enemy_targeting()
			and enemy.supports_layered_contact_authoritative_simulation()
			and not enemy.supports_indexed_touch_authority(),
			"%s must opt into compound shared contact while retaining authored Player/Plant Area authority."
			% config.resource_path
		)
		_expect(
			shape_kinds == PackedStringArray([
				"RectangleShape2D",
				"SegmentShape2D",
			]),
			"%s must retain its authored rectangle plus long SegmentShape2D touch compound."
			% config.resource_path
		)
		_expect(
			StringName(enemy.call(&"_get_slash_damage_source_type"))
				== &"capoo_knight_slash",
			"%s must preserve the existing Swordsman slash source identity."
			% config.resource_path
		)
		enemy.free()

	var source := _instantiate_config_enemy(SWORD_CONFIG) as CapooSwordsman
	var designated := _instantiate_config_enemy(TARGET_CONFIG)
	var automatic := _instantiate_config_enemy(TARGET_CONFIG)
	if source == null or designated == null or automatic == null:
		failures.append("Swordsman production target-priority probe must instantiate authored enemies.")
		if source != null:
			source.free()
		if designated != null:
			designated.free()
		if automatic != null:
			automatic.free()
		return
	source.set_combat_faction_id(CombatRelationService.HOSTILE_WAVE, 1, true)
	designated.set_combat_faction_id(CombatRelationService.PLAYER_ALLIED, 1, true)
	automatic.set_combat_faction_id(CombatRelationService.PLAYER_ALLIED, 1, true)
	source.set_objective_target(designated)
	_expect(
		source.call(&"_get_preferred_ranged_combat_target") == designated
		and source.get_resolved_combat_target(automatic) == designated,
		"Production Swordsman must retain designated-target priority."
	)
	var previous_throttling := Enemy.combat_sense_throttling_enabled
	Enemy.combat_sense_throttling_enabled = true
	var expected_interval := mini(
		source.layered_area_decision_interval_frames,
		source.combat_sense_update_interval_frames
	)
	_expect(
		source.get_layered_area_decision_interval_frames()
			== maxi(expected_interval, 1),
		"Production Swordsman must inherit Knight's combat-sense-bounded layered cadence."
	)
	Enemy.combat_sense_throttling_enabled = false
	_expect(
		source.get_layered_area_decision_interval_frames() == 1,
		"Disabling combat-sense throttling must restore exact 60 Hz Swordsman decisions."
	)
	Enemy.combat_sense_throttling_enabled = previous_throttling
	source.set_objective_target(null)
	_expect(
		source.get_resolved_combat_target(automatic) == automatic,
		"Production Swordsman must fall back to an automatic hostile enemy."
	)
	automatic.set_combat_faction_id(CombatRelationService.HOSTILE_WAVE, 2, true)
	_expect(
		source.get_resolved_combat_target(automatic) == null,
		"Production Swordsman must reject an automatic target after it turns friendly."
	)
	source.free()
	designated.free()
	automatic.free()


func _verify_multiplayer_proxy_actions() -> void:
	var runtime := _instantiate_swordsman_runtime(POLICY.Mode.LEGACY)
	var coordinator := runtime.get_enemy_simulation_coordinator()
	var source: Variant = runtime.get_node("EnemyContainer/SwordsmanSource")
	var preferred := runtime.get_node("EnemyContainer/PreferredTarget") as Enemy
	var decoy := runtime.get_node("EnemyContainer/ObjectiveDecoy") as Enemy
	_setup_enemy(
		source,
		SWORD_CONFIG.duplicate(true) as EnemyConfig,
		runtime,
		95_001
	)
	_setup_target(preferred, runtime, 95_002)
	_setup_target(decoy, runtime, 95_003)
	_disable_automatic_callbacks(coordinator, source, [preferred, decoy])
	source.configure_multiplayer_proxy()
	source.slash_effect_count = 0
	source.play_multiplayer_enemy_action(&"windup", Vector2.LEFT, 10)
	var windup_committed: bool = (
		source.latest_proxy_action_id == 10
		and source.windup_warning.visible
	)
	source.play_multiplayer_enemy_action(&"slash", Vector2.RIGHT, 9)
	var stale_rejected: bool = (
		source.latest_proxy_action_id == 10
		and source.slash_effect_count == 0
	)
	source.play_multiplayer_enemy_action(&"slash", Vector2.RIGHT, 11)
	var slash_committed: bool = (
		source.latest_proxy_action_id == 11
		and source.slash_effect_count == 1
		and not source.windup_warning.visible
	)
	source.play_multiplayer_death_sequence()
	_expect(
		windup_committed
		and stale_rejected
		and slash_committed
		and source.latest_proxy_action_id == 12
		and not source.windup_warning.visible,
		"Swordsman proxy actions must apply ordered windup/slash IDs, reject stale actions and clear on death."
	)
	runtime.queue_free()
	await process_frame


func _run_swordsman_mode(simulation_mode: int) -> Dictionary:
	var mode_name := POLICY.mode_to_name(simulation_mode)
	var runtime := _instantiate_swordsman_runtime(simulation_mode)
	var coordinator := runtime.get_enemy_simulation_coordinator()
	var contact_service := runtime.get_enemy_contact_service()
	var source: Variant = runtime.get_node("EnemyContainer/SwordsmanSource")
	var preferred := runtime.get_node("EnemyContainer/PreferredTarget") as Enemy
	var decoy := runtime.get_node("EnemyContainer/ObjectiveDecoy") as Enemy

	var source_config := (
		SWORD_CONFIG.duplicate(true) as CapooSwordsmanConfig
	)
	source_config.attack_range = 64.0
	source_config.attack_windup = PHYSICS_DELTA * 2.5
	source_config.attack_interval = PHYSICS_DELTA * 10.5
	source_config.slash_damage_delay = PHYSICS_DELTA * 1.5
	source_config.slash_duration = PHYSICS_DELTA * 3.5
	source_config.drop_table = null
	source_config.xirang_kill_reward = 0
	_setup_enemy(source, source_config, runtime, SOURCE_NET_ID)
	_setup_target(preferred, runtime, PREFERRED_TARGET_NET_ID)
	_setup_target(decoy, runtime, OBJECTIVE_DECOY_NET_ID)
	preferred.set_authoritative_simulation_enabled(false)
	decoy.set_authoritative_simulation_enabled(false)
	_disable_automatic_callbacks(coordinator, source, [preferred, decoy])
	_reset_trace_source(source, preferred, decoy)
	var authored_touch_state := _capture_touch_area_state(source)

	_expect(
		source is CapooSwordsman
		and source.supports_layered_area_authoritative_simulation()
		and source.supports_layered_contact_authoritative_simulation()
		and not source.supports_indexed_touch_authority(),
		"%s Swordsman must expose compound shared contact but retain authored Player/Plant Area authority."
		% mode_name
	)
	if simulation_mode == POLICY.Mode.LEGACY:
		_expect(
			not source.is_centrally_simulated(),
			"LEGACY must keep Swordsman on its individual runner."
		)
	else:
		_expect(
			source.is_centrally_simulated()
			and coordinator.owns_enemy(source, source.enemy_simulation_token),
			"%s must keep Swordsman centrally scheduled." % mode_name
		)

	var context := {
		"coordinator": coordinator,
		"source": source,
		"preferred": preferred,
		"decoy": decoy,
		"rollback_preserved": simulation_mode == POLICY.Mode.LEGACY,
		"rollback_restored": simulation_mode == POLICY.Mode.LEGACY,
		"contact_proxy_only": simulation_mode != POLICY.Mode.LAYERED_CONTACT,
	}
	var snapshots: Array[Dictionary] = []
	for tick_index in range(1, TEST_TICKS + 1):
		_apply_pre_tick_script(tick_index, context)
		await _advance_one_tick(coordinator, source, [preferred, decoy])
		if (
			tick_index == 1
			and simulation_mode == POLICY.Mode.LAYERED_CONTACT
		):
			context["contact_proxy_only"] = (
				contact_service.owns_enemy(source)
				and not source.is_indexed_touch_authority_enabled()
				and _capture_touch_area_state(source) == authored_touch_state
			)
		if tick_index == ROLLBACK_TICK and simulation_mode != POLICY.Mode.LEGACY:
			var before_rollback := _capture_rollback_state(source, preferred, decoy)
			coordinator.set_mode(POLICY.Mode.LEGACY)
			context["rollback_preserved"] = (
				_capture_rollback_state(source, preferred, decoy)
				== before_rollback
			)
			context["rollback_restored"] = (
				not source.is_centrally_simulated()
				and source.is_physics_processing()
				and not source.is_indexed_touch_authority_enabled()
			)
			source.set_physics_process(false)
			coordinator.set_physics_process(false)
		snapshots.append(
			_capture_snapshot(tick_index, source, preferred, decoy)
		)

	_validate_mode_invariants(mode_name, simulation_mode, snapshots, context)
	var run_result := {
		"mode": mode_name,
		"snapshots": snapshots,
		"trace_lines": _canonical_trace_lines(snapshots),
	}
	runtime.queue_free()
	await process_frame
	completed_mode_count += 1
	return run_result


func _instantiate_swordsman_runtime(
	simulation_mode: int
) -> EnemyGameplayGatewayTestRuntime:
	var runtime := (
		SWORDSMAN_RUNTIME_SCENE.instantiate()
		as EnemyGameplayGatewayTestRuntime
	)
	runtime.runtime_mode = CombatRuntimeBase.RuntimeMode.SINGLEPLAYER
	var coordinator := runtime.get_node(
		"EnemySimulationCoordinator"
	) as EnemySimulationCoordinator
	coordinator.set_mode(simulation_mode)
	root.add_child(runtime)
	coordinator.set_physics_process(false)
	return runtime


func _get_authored_touch_shape_kinds(enemy: Enemy) -> PackedStringArray:
	var result := PackedStringArray()
	var area := enemy.get_node_or_null("TouchDamageArea") as Area2D
	if area == null:
		return result
	for child in area.find_children("*", "CollisionShape2D", true, false):
		var shape_node := child as CollisionShape2D
		if shape_node == null or shape_node.shape == null or shape_node.disabled:
			continue
		result.append(shape_node.shape.get_class())
	result.sort()
	return result
