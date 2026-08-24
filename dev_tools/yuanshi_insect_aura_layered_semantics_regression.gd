extends SceneTree

const POLICY := preload(
	"res://scene/combat/simulation/enemy_simulation_policy.gd"
)
const RUNTIME_SCENE := preload(
	"res://dev_tools/fixtures/yuanshi_insect_aura_layered_semantic_runtime.tscn"
)
const AURA_HARNESS_SCENE := preload(
	"res://dev_tools/fixtures/yuanshi_insect_aura_layered_semantic_harness.tscn"
)
const PLAYER_SCENE := preload(
	"res://scene/player/weishidaier/player_weishidaier.tscn"
)
const GREEN_SHELL_CONFIG := preload(
	"res://resources/config/enemies/yuanshi_insect_green_shell.tres"
)
const GUARDIAN_CONFIG := preload(
	"res://resources/config/enemies/yuanshi_insect_guardian.tres"
)
const STONE_GREEN_SHELL_CONFIG := preload(
	"res://resources/config/enemies/stone_eroded_yuanshi_insect_green_shell.tres"
)
const STONE_GUARDIAN_CONFIG := preload(
	"res://resources/config/enemies/stone_eroded_yuanshi_insect_guardian.tres"
)
const BASIC_CONFIG := preload(
	"res://resources/config/enemies/yuanshi_insect_basic.tres"
)

const PHYSICS_DELTA := 1.0 / 60.0
const PLAYER_TRACE_TICKS := 65
const PLAYER_EXIT_TICK := 64
const SOURCE_NET_ID := 73_001
const DYNAMIC_SOURCE_NET_ID := 73_101
const DYNAMIC_TARGET_NET_ID := 73_102
const AURA_TARGET_POSITION := Vector2(26.0, 0.0)
const OUTSIDE_AURA_POSITION := Vector2(192.0, 0.0)
const TEST_MODES: Array[int] = [
	POLICY.Mode.LEGACY,
	POLICY.Mode.LAYERED_AREA,
	POLICY.Mode.LAYERED_CONTACT,
]
const TRACE_FIELDS: PackedStringArray = [
	"tick",
	"player_health",
	"cooldown",
	"event_count",
	"damage_count",
	"event_sequence",
	"target_is_player",
	"candidate_count",
	"last_event_delta",
	"aura_monitoring",
	"aura_monitorable",
	"aura_shape_disabled",
	"source_faction",
	"last_source_faction",
	"last_source_type",
]

var failures: Array[String] = []
var completed_player_mode_count := 0
var dynamic_enemy_semantics_completed := false
var freed_target_cleanup_completed := false
var guardian_relation_filter_completed := false


func _init() -> void:
	call_deferred(&"_run")


func _run() -> void:
	_verify_four_config_capabilities()
	var player_runs: Dictionary = {}
	for simulation_mode in TEST_MODES:
		player_runs[simulation_mode] = await _run_player_semantics(
			simulation_mode
		)
	_expect(
		completed_player_mode_count == TEST_MODES.size(),
		"Every Player Aura mode coroutine must reach its explicit completion sentinel."
	)
	_compare_player_runs(player_runs)
	await _verify_dynamic_enemy_semantics()
	_expect(
		dynamic_enemy_semantics_completed,
		"Dynamic Enemy Aura semantics must reach its completion sentinel."
	)
	await _verify_freed_target_cleanup()
	_expect(
		freed_target_cleanup_completed,
		"Freed-target cleanup must reach its completion sentinel."
	)
	await _verify_guardian_relation_filter()
	_expect(
		guardian_relation_filter_completed,
		"Guardian relation filtering must reach its completion sentinel."
	)

	var result := {
		"status": "ok" if failures.is_empty() else "failed",
		"modes": _mode_names(),
		"player_hit_ticks": _player_hit_ticks_by_mode(player_runs),
		"player_trace_digests": _player_trace_digests(player_runs),
		"failures": failures.duplicate(),
	}
	print(
		"YUANSHI_AURA_LAYERED_SEMANTICS_JSON %s"
		% JSON.stringify(result)
	)
	if failures.is_empty():
		print("YUANSHI_AURA_LAYERED_SEMANTICS_REGRESSION_OK")
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	quit(1)


func _verify_four_config_capabilities() -> void:
	for config in [
		GREEN_SHELL_CONFIG,
		GUARDIAN_CONFIG,
		STONE_GREEN_SHELL_CONFIG,
		STONE_GUARDIAN_CONFIG,
	]:
		var enemy := config.enemy_scene.instantiate() as YuanshiInsectAura
		_expect(
			enemy != null,
			"%s must instantiate the shared Aura runner." % config.resource_path
		)
		if enemy == null:
			continue
		_expect(
			enemy.supports_centralized_authoritative_simulation()
			and enemy.supports_layered_area_authoritative_simulation()
			and enemy.supports_dynamic_enemy_targeting()
			and enemy.supports_indexed_touch_authority(),
			"%s must publish centralized/layered/dynamic/indexed capability."
			% config.resource_path
		)
		enemy.free()


func _run_player_semantics(simulation_mode: int) -> Dictionary:
	var mode_name := POLICY.mode_to_name(simulation_mode)
	var runtime := _new_runtime()
	root.add_child(runtime)
	await process_frame
	var coordinator := runtime.get_enemy_simulation_coordinator()
	coordinator.set_mode(simulation_mode)
	var guardian_system := runtime.get_node_or_null(
		"GuardianAuraSystem"
	) as GuardianAuraSystem
	if guardian_system != null:
		guardian_system.set_physics_process(false)

	var player := await _spawn_player(runtime, 1, "AuraSemanticPlayer")
	runtime.player = player
	runtime.peer_players[1] = player
	player.global_position = OUTSIDE_AURA_POSITION
	var source: Variant = AURA_HARNESS_SCENE.instantiate()
	var source_config := GREEN_SHELL_CONFIG.duplicate(true) as EnemyConfig
	source_config.drop_table = null
	source_config.xirang_kill_reward = 0
	source.name = "AuraSemanticSource"
	source.set_meta(&"net_id", SOURCE_NET_ID)
	runtime.enemy_container.add_child(source)
	source.setup(source_config, player, null, runtime)
	source.global_position = Vector2.ZERO
	_expect(
		runtime.register_network_enemy(SOURCE_NET_ID, source),
		"%s Aura source must enter the runtime target index." % mode_name
	)

	await physics_frame
	await physics_frame
	_disable_automatic_callbacks(coordinator, source, [player], guardian_system)
	await _advance_one_tick(simulation_mode, coordinator, source, [player])
	source.reset_aura_semantic_trace()
	source.aura_damage_cooldown_left = 0.0
	source.aura_damage_event_sequence = 0
	source.set_objective_target(player)
	player.current_health = player.max_health
	player.health_bar.set_health(player.current_health, player.max_health)

	_expect(
		source.aura_active
		and source.aura_area.collision_mask
		== YuanshiInsectAura.AURA_DAMAGE_COLLISION_MASK,
		"%s must keep the authored local AuraArea active for Player and Enemy targets."
		% mode_name
	)
	if simulation_mode == POLICY.Mode.LAYERED_CONTACT:
		_expect(
			source.is_indexed_touch_authority_enabled(),
			"LAYERED_CONTACT must admit Aura indexed touch authority."
		)

	var snapshots: Array[Dictionary] = []
	var hit_ticks: Array[int] = []
	var previous_health := player.current_health
	for tick_index in range(1, PLAYER_TRACE_TICKS + 1):
		var before_event := Callable()
		if tick_index == 1:
			player.global_position = AURA_TARGET_POSITION
			before_event = func() -> void:
				source.layered_area_decision_urgent = false
				source.call(&"_on_aura_area_body_entered", player)
				_expect(
					source.layered_area_decision_urgent,
					"%s AuraArea enter must wake the sparse decision lane."
					% mode_name
				)
				_expect(
					player.current_health == player.max_health,
					"%s AuraArea signal must commit damage in the event hook, not the signal callback."
					% mode_name
				)
		elif tick_index == PLAYER_EXIT_TICK:
			player.global_position = OUTSIDE_AURA_POSITION
			before_event = func() -> void:
				source.layered_area_decision_urgent = false
				source.call(&"_on_aura_area_body_exited", player)
				_expect(
					source.layered_area_decision_urgent,
					"%s AuraArea exit must wake the sparse decision lane."
					% mode_name
				)
		await _advance_one_tick(
			simulation_mode,
			coordinator,
			source,
			[player],
			before_event
		)
		if player.current_health < previous_health:
			hit_ticks.append(tick_index)
		previous_health = player.current_health
		snapshots.append(_capture_player_snapshot(tick_index, source, player))

	_validate_player_mode(mode_name, simulation_mode, source, player, snapshots, hit_ticks)
	var cooldown_before_rollback: float = source.aura_damage_cooldown_left
	var rollback_restored := true
	var rollback_released_indexed := true
	if simulation_mode != POLICY.Mode.LEGACY:
		coordinator.set_mode(POLICY.Mode.LEGACY)
		rollback_restored = source.is_physics_processing()
		rollback_released_indexed = not source.is_indexed_touch_authority_enabled()
		_expect(
			rollback_restored
			and rollback_released_indexed
			and is_equal_approx(
				source.aura_damage_cooldown_left,
				cooldown_before_rollback
			),
			"%s rollback must restore individual ownership, release indexed touch, and preserve Aura cooldown."
			% mode_name
		)
		source.set_physics_process(false)
		coordinator.set_physics_process(false)
	_expect_aura_area_contract(source, mode_name, false)

	var run_result := {
		"mode": mode_name,
		"snapshots": snapshots,
		"hit_ticks": hit_ticks,
		"rollback_restored": rollback_restored,
		"rollback_released_indexed": rollback_released_indexed,
	}
	runtime.queue_free()
	await process_frame
	completed_player_mode_count += 1
	return run_result


func _validate_player_mode(
	mode_name: String,
	simulation_mode: int,
	source: Variant,
	player: Player,
	snapshots: Array[Dictionary],
	hit_ticks: Array[int]
) -> void:
	_expect(
		snapshots.size() == PLAYER_TRACE_TICKS,
		"%s must capture every Player Aura tick." % mode_name
	)
	_expect(
		hit_ticks == [1, 61],
		"%s must preserve the authored 1.0s Player Aura ticks [1, 61] (got %s)."
		% [mode_name, hit_ticks]
	)
	_expect(
		player.current_health
		== player.max_health - GREEN_SHELL_CONFIG.attack_damage * 2,
		"%s Player must receive exactly two default Aura hits." % mode_name
	)
	_expect(
		source.aura_event_deltas.size() == PLAYER_TRACE_TICKS,
		"%s local active Aura must not event-sleep or freeze its public cooldown."
		% mode_name
	)
	for event_delta in source.aura_event_deltas:
		_expect(
			is_equal_approx(event_delta, PHYSICS_DELTA),
			"%s every local Aura event must retain the authored 60 Hz delta."
			% mode_name
		)
	if simulation_mode == POLICY.Mode.LAYERED_CONTACT:
		_expect_aura_area_contract(source, mode_name, true)
	else:
		_expect_aura_area_contract(source, mode_name, false)
	var first_snapshot: Dictionary = snapshots[0] if not snapshots.is_empty() else {}
	_expect(
		int(first_snapshot.get("last_source_faction", -1))
		== CombatRelationService.HOSTILE_WAVE
		and String(first_snapshot.get("last_source_type", ""))
		== String(YuanshiInsectAura.AURA_DAMAGE_SOURCE_TYPE),
		"%s Player damage must retain explicit hostile yuanshi_aura attribution."
		% mode_name
	)


func _expect_aura_area_contract(
	source: Variant,
	mode_name: String,
	expect_indexed_touch: bool
) -> void:
	_expect(
		source.aura_area.monitoring
		and source.aura_area.monitorable
		and not source.aura_area_shape.disabled
		and source.aura_area.collision_mask
		== YuanshiInsectAura.AURA_DAMAGE_COLLISION_MASK,
		"%s must keep AuraArea enabled independently of indexed touch authority."
		% mode_name
	)
	if expect_indexed_touch:
		_expect(
			source.is_indexed_touch_authority_enabled()
			and not source.touch_damage_area.monitoring
			and not source.touch_damage_area.monitorable
			and _all_touch_damage_shapes_disabled(source),
			"%s CONTACT must close only TouchDamageArea while AuraArea stays live."
			% mode_name
		)


func _capture_player_snapshot(
	tick_index: int,
	source: Variant,
	player: Player
) -> Dictionary:
	var source_snapshot: DamageSourceSnapshot = null
	if (
		player.last_damage_result != null
		and player.last_damage_result.request != null
	):
		source_snapshot = player.last_damage_result.request.source_snapshot
	return {
		"tick": tick_index,
		"player_health": player.current_health,
		"cooldown": _quantize(source.aura_damage_cooldown_left),
		"event_count": source.aura_event_deltas.size(),
		"damage_count": source.aura_damage_apply_count,
		"event_sequence": source.aura_damage_event_sequence,
		"target_is_player": 1 if source.aura_damage_target == player else 0,
		"candidate_count": source.aura_damage_targets.size(),
		"last_event_delta": (
			_quantize(source.aura_event_deltas[-1])
			if not source.aura_event_deltas.is_empty()
			else 0
		),
		"aura_monitoring": 1 if source.aura_area.monitoring else 0,
		"aura_monitorable": 1 if source.aura_area.monitorable else 0,
		"aura_shape_disabled": 1 if source.aura_area_shape.disabled else 0,
		"source_faction": source.get_combat_faction_id(),
		"last_source_faction": (
			source_snapshot.source_faction_id
			if source_snapshot != null
			else -1
		),
		"last_source_type": (
			String(source_snapshot.source_type)
			if source_snapshot != null
			else ""
		),
	}


func _compare_player_runs(player_runs: Dictionary) -> void:
	var legacy_run: Dictionary = player_runs.get(POLICY.Mode.LEGACY, {})
	var legacy_snapshots: Array = legacy_run.get("snapshots", [])
	var legacy_hit_ticks: Array = legacy_run.get("hit_ticks", [])
	for layered_mode in [POLICY.Mode.LAYERED_AREA, POLICY.Mode.LAYERED_CONTACT]:
		var mode_name := POLICY.mode_to_name(layered_mode)
		var layered_run: Dictionary = player_runs.get(layered_mode, {})
		var layered_snapshots: Array = layered_run.get("snapshots", [])
		_expect(
			layered_run.get("hit_ticks", []) == legacy_hit_ticks,
			"%s Player hit ticks must equal LEGACY." % mode_name
		)
		if layered_snapshots.size() != legacy_snapshots.size():
			failures.append(
				"%s Player trace length differs from LEGACY." % mode_name
			)
			continue
		var mismatch_count := 0
		for tick_index in range(legacy_snapshots.size()):
			var legacy_snapshot: Dictionary = legacy_snapshots[tick_index]
			var layered_snapshot: Dictionary = layered_snapshots[tick_index]
			for field_name in TRACE_FIELDS:
				if legacy_snapshot.get(field_name) == layered_snapshot.get(field_name):
					continue
				failures.append(
					"%s diverged from LEGACY at tick %d field %s: legacy=%s layered=%s"
					% [
						mode_name,
						tick_index + 1,
						field_name,
						str(legacy_snapshot.get(field_name)),
						str(layered_snapshot.get(field_name)),
					]
				)
				mismatch_count += 1
				if mismatch_count >= 8:
					break
			if mismatch_count >= 8:
				break


func _verify_dynamic_enemy_semantics() -> void:
	var runtime := _new_runtime()
	root.add_child(runtime)
	await process_frame
	var coordinator := runtime.get_enemy_simulation_coordinator()
	coordinator.set_mode(POLICY.Mode.LAYERED_CONTACT)
	var guardian_system := runtime.get_node("GuardianAuraSystem") as GuardianAuraSystem
	guardian_system.set_physics_process(false)

	var source: Variant = AURA_HARNESS_SCENE.instantiate()
	var source_config := GREEN_SHELL_CONFIG.duplicate(true) as EnemyConfig
	source_config.drop_table = null
	source_config.xirang_kill_reward = 0
	source.name = "DynamicAuraSource"
	source.set_meta(&"net_id", DYNAMIC_SOURCE_NET_ID)
	runtime.enemy_container.add_child(source)
	source.setup(source_config, null, null, runtime)
	source.global_position = Vector2.ZERO
	runtime.register_network_enemy(DYNAMIC_SOURCE_NET_ID, source)

	var target_config := BASIC_CONFIG.duplicate(true) as EnemyConfig
	target_config.max_health = 50
	target_config.physical_defense = 0
	target_config.magic_defense = 0
	target_config.drop_table = null
	target_config.xirang_kill_reward = 2
	var target := _spawn_enemy(
		runtime,
		target_config,
		"DynamicAuraTarget",
		DYNAMIC_TARGET_NET_ID
	)
	target.global_position = AURA_TARGET_POSITION
	source.set_objective_target(target)

	await physics_frame
	await physics_frame
	_disable_automatic_callbacks(coordinator, source, [target], guardian_system)
	await _advance_one_tick(
		POLICY.Mode.LAYERED_CONTACT,
		coordinator,
		source,
		[target]
	)
	source.reset_aura_semantic_trace()
	source.aura_damage_cooldown_left = 0.0
	target.current_health = target_config.max_health
	_expect(
		target.set_combat_faction_id(
			CombatRelationService.PLAYER_ALLIED,
			1,
			true
		),
		"Dynamic Aura target must enter the opposing faction."
	)
	source.layered_area_decision_urgent = false
	source.call(&"_on_aura_area_body_entered", target)
	_expect(
		source.layered_area_decision_urgent,
		"Enemy AuraArea enter must wake the sparse lane."
	)
	await _advance_one_tick(
		POLICY.Mode.LAYERED_CONTACT,
		coordinator,
		source,
		[target]
	)
	_expect(
		target.current_health == 30,
		"Hostile Enemy inside Aura radius must receive one physical Aura hit."
	)
	var first_result := target.last_damage_result
	var first_request: DamageRequest = (
		first_result.request if first_result != null else null
	)
	var first_snapshot: DamageSourceSnapshot = (
		first_request.source_snapshot if first_request != null else null
	)
	_expect(
		first_result != null
		and first_result.accepted
		and first_request != null
		and first_request.damage_type == CombatTypes.DamageType.PHYSICAL
		and first_request.has_flag(CombatTypes.DamageFlag.PERIODIC)
		and first_request.source_snapshot_is_explicit
		and first_snapshot != null
		and first_snapshot.source_faction_id
		== CombatRelationService.HOSTILE_WAVE
		and first_snapshot.instigator_entity_id == DYNAMIC_SOURCE_NET_ID
		and first_snapshot.event_source_id > 0
		and first_snapshot.source_type == YuanshiInsectAura.AURA_DAMAGE_SOURCE_TYPE,
		"Enemy Aura hit must carry an explicit hostile/physical/periodic yuanshi_aura snapshot."
	)

	source.layered_area_decision_urgent = false
	_expect(
		target.set_combat_faction_id(
			CombatRelationService.HOSTILE_WAVE,
			2,
			true
		),
		"Dynamic target must enter the source faction."
	)
	_expect(
		source.layered_area_decision_urgent,
		"Tracked Enemy faction change must wake Aura target validation."
	)
	source.aura_damage_cooldown_left = 0.0
	await _advance_one_tick(
		POLICY.Mode.LAYERED_CONTACT,
		coordinator,
		source,
		[target]
	)
	_expect(
		target.current_health == 30 and source.aura_damage_target == null,
		"Same-faction Enemy must never receive Aura friendly fire."
	)

	source.layered_area_decision_urgent = false
	target.set_combat_faction_id(CombatRelationService.PLAYER_ALLIED, 3, true)
	_expect(
		source.layered_area_decision_urgent,
		"Returning a tracked Enemy to a hostile faction must wake Aura."
	)
	source.aura_damage_cooldown_left = 0.0
	await _advance_one_tick(
		POLICY.Mode.LAYERED_CONTACT,
		coordinator,
		source,
		[target]
	)
	_expect(
		target.current_health == 10,
		"Aura must resume damage after a hostile faction transition."
	)

	source.set_combat_faction_id(CombatRelationService.PLAYER_ALLIED, 1, true)
	target.set_combat_faction_id(CombatRelationService.HOSTILE_WAVE, 4, true)
	source.set_objective_target(target)
	source.layered_area_decision_urgent = false
	source.aura_damage_cooldown_left = 0.0
	await _advance_one_tick(
		POLICY.Mode.LAYERED_CONTACT,
		coordinator,
		source,
		[target]
	)
	_expect(
		target.is_dead
		and target.defeat_context != null
		and target.defeat_context.source_snapshot != null
		and target.defeat_context.source_snapshot.source_faction_id
		== CombatRelationService.PLAYER_ALLIED
		and target.defeat_context.is_player_reward_eligible(),
		"Player-allied Aura lethality must retain the existing reward-eligible defeat context."
	)
	_expect(
		not source.aura_damage_targets.has(target.get_instance_id())
		and source.aura_damage_target == null,
		"Enemy defeat must synchronously remove the Aura candidate and selected target."
	)
	_expect(
		source.enemy_defeat_wake_count == 1,
		"Enemy defeat must wake planning inside the event callback before the same-tick decision consumes urgency."
	)

	runtime.queue_free()
	await process_frame
	dynamic_enemy_semantics_completed = true


func _verify_freed_target_cleanup() -> void:
	var runtime := _new_runtime()
	root.add_child(runtime)
	await process_frame
	var coordinator := runtime.get_enemy_simulation_coordinator()
	coordinator.set_mode(POLICY.Mode.LEGACY)
	var guardian_system := runtime.get_node("GuardianAuraSystem") as GuardianAuraSystem
	guardian_system.set_physics_process(false)
	var source: Variant = AURA_HARNESS_SCENE.instantiate()
	var source_config := GREEN_SHELL_CONFIG.duplicate(true) as EnemyConfig
	source_config.drop_table = null
	source.name = "FreedTargetAuraSource"
	runtime.enemy_container.add_child(source)
	source.setup(source_config, null, null, runtime)
	source.global_position = Vector2.ZERO
	source.set_physics_process(false)

	var player := await _spawn_player(runtime, 7, "FreedAuraPlayer")
	player.global_position = OUTSIDE_AURA_POSITION
	source.call(&"_track_aura_damage_target", player)
	var player_id := player.get_instance_id()
	_expect(
		source.aura_damage_targets.has(player_id)
		and source.aura_player_death_callbacks.has(player_id),
		"Freed-Player fixture must begin with a tracked non-overlap candidate."
	)
	player.queue_free()
	await process_frame
	_expect(not is_instance_valid(player), "Player queue_free fixture must be freed.")
	source.call(&"_update_aura_damage", PHYSICS_DELTA)
	_expect(
		not source.aura_damage_targets.has(player_id)
		and not source.aura_player_death_callbacks.has(player_id)
		and source.aura_damage_target == null
		and source.aura_touched_player == null,
		"Freed Player must be pruned Variant-first without a died/Area exit callback."
	)

	var enemy_config := BASIC_CONFIG.duplicate(true) as EnemyConfig
	enemy_config.drop_table = null
	var enemy := _spawn_enemy(
		runtime,
		enemy_config,
		"FreedAuraEnemy",
		73_207
	)
	enemy.global_position = OUTSIDE_AURA_POSITION
	source.call(&"_track_aura_damage_target", enemy)
	var enemy_id := enemy.get_instance_id()
	_expect(
		source.aura_damage_targets.has(enemy_id) and not enemy.is_dead,
		"Freed-Enemy fixture must begin tracked and alive."
	)
	enemy.queue_free()
	await process_frame
	_expect(not is_instance_valid(enemy), "Enemy queue_free fixture must be freed.")
	source.call(&"_update_aura_damage", PHYSICS_DELTA)
	_expect(
		not source.aura_damage_targets.has(enemy_id)
		and source.aura_damage_target == null,
		"Freed Enemy must be pruned by target ID without a defeated callback or freed-object cast."
	)

	runtime.queue_free()
	await process_frame
	freed_target_cleanup_completed = true


func _verify_guardian_relation_filter() -> void:
	var runtime := _new_runtime()
	root.add_child(runtime)
	await process_frame
	var coordinator := runtime.get_enemy_simulation_coordinator()
	coordinator.set_mode(POLICY.Mode.LEGACY)
	coordinator.set_physics_process(false)
	var guardian_system := runtime.get_node("GuardianAuraSystem") as GuardianAuraSystem
	guardian_system.set_physics_process(false)

	var guardian := _spawn_enemy(
		runtime,
		GUARDIAN_CONFIG.duplicate(true) as EnemyConfig,
		"RelationGuardian",
		73_301
	)
	var same_faction := _spawn_enemy(
		runtime,
		BASIC_CONFIG.duplicate(true) as EnemyConfig,
		"RelationSameFaction",
		73_302
	)
	var opposing := _spawn_enemy(
		runtime,
		BASIC_CONFIG.duplicate(true) as EnemyConfig,
		"RelationOpposing",
		73_303
	)
	var unrelated := _spawn_enemy(
		runtime,
		BASIC_CONFIG.duplicate(true) as EnemyConfig,
		"RelationUnrelated",
		73_304
	)
	guardian.global_position = Vector2.ZERO
	same_faction.global_position = Vector2(12.0, 0.0)
	opposing.global_position = Vector2(18.0, 0.0)
	unrelated.global_position = Vector2(24.0, 0.0)
	opposing.set_combat_faction_id(CombatRelationService.PLAYER_ALLIED, 1, true)
	unrelated.set_combat_faction_id(3, 1, true)
	await physics_frame
	guardian_system.set_physics_process(false)
	guardian_system.force_refresh_all()
	var source_id := guardian.get_instance_id()
	_expect(
		guardian_system.has_guardian_source(same_faction, guardian)
		and same_faction.physical_defense_modifiers.has(source_id),
		"Guardian must buff a same-faction ally inside its authored radius."
	)
	_expect(
		not guardian_system.has_guardian_source(opposing, guardian)
		and not guardian_system.has_guardian_source(unrelated, guardian)
		and not opposing.physical_defense_modifiers.has(source_id)
		and not unrelated.physical_defense_modifiers.has(source_id),
		"Guardian must not buff an opposing or merely non-hostile different faction."
	)

	same_faction.set_combat_faction_id(CombatRelationService.PLAYER_ALLIED, 1, true)
	opposing.set_combat_faction_id(CombatRelationService.HOSTILE_WAVE, 2, true)
	guardian_system.force_refresh_all()
	_expect(
		not guardian_system.has_guardian_source(same_faction, guardian)
		and guardian_system.has_guardian_source(opposing, guardian)
		and not same_faction.physical_defense_modifiers.has(source_id)
		and opposing.physical_defense_modifiers.has(source_id),
		"Guardian relation refresh must remove a former ally and add a new same-faction ally."
	)

	guardian.set_combat_faction_id(CombatRelationService.PLAYER_ALLIED, 1, true)
	guardian_system.force_refresh_all()
	_expect(
		guardian_system.has_guardian_source(same_faction, guardian)
		and not guardian_system.has_guardian_source(opposing, guardian)
		and not guardian_system.has_guardian_source(unrelated, guardian),
		"Guardian source faction changes must never leave a buff on newly opposing factions."
	)

	runtime.queue_free()
	await process_frame
	guardian_relation_filter_completed = true


func _new_runtime() -> EnemyGameplayGatewayTestRuntime:
	var runtime := RUNTIME_SCENE.instantiate() as EnemyGameplayGatewayTestRuntime
	runtime.runtime_mode = CombatRuntimeBase.RuntimeMode.SINGLEPLAYER
	return runtime


func _spawn_player(
	runtime: EnemyGameplayGatewayTestRuntime,
	peer_id: int,
	node_name: String
) -> Player:
	var player := PLAYER_SCENE.instantiate() as Player
	player.name = node_name
	runtime.add_child(player)
	await process_frame
	player.peer_id = peer_id
	player.bind_combat_runtime(runtime)
	player.current_health = maxi(player.max_health, 1)
	player.physical_defense = 0
	player.magic_defense = 0
	player.is_dead = false
	player.invincibility_duration = 0.0
	player.invincibility_time_left = 0.0
	player.dash_time_left = 0.0
	player.multiplayer_dash_protection_time_left = 0.0
	player.dodge_chance = 0.0
	player.collectible_ranged_dodge_chance = 0.0
	player.damage_reduction_modifiers.clear()
	player.health_bar.set_health(player.current_health, player.max_health)
	player.set_process(false)
	player.set_physics_process(false)
	return player


func _spawn_enemy(
	runtime: EnemyGameplayGatewayTestRuntime,
	enemy_config: EnemyConfig,
	node_name: String,
	net_id: int
) -> Enemy:
	var enemy := enemy_config.enemy_scene.instantiate() as Enemy
	enemy.name = node_name
	enemy.set_meta(&"net_id", net_id)
	runtime.enemy_container.add_child(enemy)
	enemy.setup(enemy_config, null, null, runtime)
	_expect(
		runtime.register_network_enemy(net_id, enemy),
		"%s must enter the runtime combat index." % node_name
	)
	enemy.set_process(false)
	enemy.set_physics_process(false)
	return enemy


func _advance_one_tick(
	simulation_mode: int,
	coordinator: EnemySimulationCoordinator,
	source: Variant,
	other_nodes: Array,
	before_event: Callable = Callable()
) -> void:
	await physics_frame
	_disable_automatic_callbacks(coordinator, source, other_nodes)
	if before_event.is_valid():
		before_event.call()
	if source == null or not is_instance_valid(source) or source.is_dead:
		return
	if simulation_mode == POLICY.Mode.LEGACY:
		source.call(&"_run_authoritative_physics_step", PHYSICS_DELTA)
		return
	coordinator.call(&"_physics_process", PHYSICS_DELTA)
	coordinator.set_physics_process(false)


func _disable_automatic_callbacks(
	coordinator: EnemySimulationCoordinator,
	source: Variant,
	other_nodes: Array,
	guardian_system: GuardianAuraSystem = null
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
	if guardian_system != null and is_instance_valid(guardian_system):
		guardian_system.set_physics_process(false)


func _all_touch_damage_shapes_disabled(source: Variant) -> bool:
	for shape_variant in source.touch_damage_shapes:
		var shape := shape_variant as CollisionShape2D
		if shape != null and not shape.disabled:
			return false
	return true


func _player_hit_ticks_by_mode(player_runs: Dictionary) -> Dictionary:
	var result := {}
	for simulation_mode in TEST_MODES:
		var run: Dictionary = player_runs.get(simulation_mode, {})
		result[POLICY.mode_to_name(simulation_mode)] = run.get("hit_ticks", [])
	return result


func _player_trace_digests(player_runs: Dictionary) -> Dictionary:
	var result := {}
	for simulation_mode in TEST_MODES:
		var run: Dictionary = player_runs.get(simulation_mode, {})
		var lines := PackedStringArray()
		for snapshot in run.get("snapshots", []):
			lines.append(JSON.stringify(snapshot))
		result[POLICY.mode_to_name(simulation_mode)] = "\n".join(lines).sha256_text()
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
