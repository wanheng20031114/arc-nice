extends SceneTree

const RUNTIME_SCENE := preload(
	"res://dev_tools/fixtures/enemy_gameplay_gateway_test_runtime.tscn"
)
const FAST_CONFIG := preload(
	"res://resources/config/enemies/yuanshi_insect_fast.tres"
)
const LINGLAN_SCENE := preload(
	"res://scene/boss/linglan/linglan_boss.tscn"
)
const TEST_DELTA := 1.0 / 60.0
const ENEMY_CONFIG_DIRECTORY := "res://resources/config/enemies"
const EXPECTED_CONFIG_COUNT := 64
const SIGNATURE_STATE_EXCLUSIONS: PackedStringArray = [
	"authoritative_simulation_driver",
	"enemy_simulation_token",
	"simulation_id",
	"scheduled_authoritative_step_count",
	"scheduled_authoritative_admission_tick",
	"scheduled_authoritative_admission_token",
	"suppressed_direct_authoritative_step_count",
	"individual_simulation_activation_physics_frame",
	"layered_area_last_event_tick",
]

var failures: Array[String] = []


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	_test_linglan_layered_contract()
	var runtime := RUNTIME_SCENE.instantiate() as EnemyGameplayGatewayTestRuntime
	root.add_child(runtime)
	current_scene = runtime
	await process_frame

	var coordinator := runtime.get_enemy_simulation_coordinator()
	_expect(coordinator != null, "The authored runtime must expose its coordinator.")
	if coordinator != null:
		await _test_real_enemy_handoff(runtime, coordinator)
		await _test_suspended_enemy_rollback(runtime, coordinator)
		await _test_live_forward_handoff(runtime, coordinator)
		await _test_compat_tick_matches_legacy(runtime, coordinator)
		await _test_all_family_tick_signatures(runtime, coordinator)

	runtime.queue_free()
	await process_frame
	await physics_frame

	var result := {
		"status": "ok" if failures.is_empty() else "failed",
		"failures": failures.duplicate(),
	}
	print("ENEMY_SIMULATION_COMPAT_INTEGRATION_JSON %s" % JSON.stringify(result))
	if failures.is_empty():
		print("ENEMY_SIMULATION_COMPAT_INTEGRATION_SMOKE_TEST_OK")
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	quit(1)


func _test_linglan_layered_contract() -> void:
	var boss := LINGLAN_SCENE.instantiate() as LinglanBoss
	_expect(boss != null, "The authored Linglan scene must instantiate.")
	if boss == null:
		return
	_expect(
		boss.get_node_or_null("EnemySimulationPhaseAnchor") == null,
		"Migrated Linglan must not retain the obsolete priority-0 phase anchor."
	)
	_expect(
		boss.supports_centralized_authoritative_simulation()
		and not boss.uses_anchored_compat_simulation()
		and boss.supports_layered_area_authoritative_simulation(),
		"Linglan must use ordinary COMPAT traversal and authored layered phases."
	)
	boss.free()


func _test_real_enemy_handoff(
	runtime: EnemyGameplayGatewayTestRuntime,
	coordinator: EnemySimulationCoordinator
) -> void:
	coordinator.set_mode(EnemySimulationPolicy.Mode.COMPAT_60)
	var enemy := _spawn_enemy(runtime)
	var token := enemy.enemy_simulation_token
	_expect(enemy.is_centrally_simulated(), "A supported authoritative Yuanshi must hand off atomically.")
	_expect(token > 0, "The handoff must assign a positive ownership token.")
	_expect(enemy.simulation_id > 0, "The handoff must assign a stable simulation ID.")
	_expect(
		coordinator.owns_enemy(enemy, token),
		"The enemy and coordinator must agree on exact ownership."
	)
	_expect(
		not enemy.is_physics_processing(),
		"A centrally owned enemy must disable its individual physics callback."
	)

	var scheduled_before := enemy.scheduled_authoritative_step_count
	await physics_frame
	await physics_frame
	_expect(
		enemy.scheduled_authoritative_step_count > scheduled_before,
		"The real Yuanshi authoritative step must advance through COMPAT_60."
	)
	var scheduled_after := enemy.scheduled_authoritative_step_count
	var suppressed_before := enemy.suppressed_direct_authoritative_step_count
	enemy._physics_process(TEST_DELTA)
	_expect(
		enemy.scheduled_authoritative_step_count == scheduled_after,
		"A direct callback must never duplicate a centrally scheduled step."
	)
	_expect(
		enemy.suppressed_direct_authoritative_step_count == suppressed_before + 1,
		"Suppressed direct entry must remain observable for A/B evidence."
	)

	coordinator.set_mode(EnemySimulationPolicy.Mode.LEGACY)
	_expect(
		not enemy.is_centrally_simulated(),
		"LEGACY rollback must release coordinator ownership."
	)
	_expect(
		enemy.is_physics_processing(),
		"An active enemy must resume its individual callback after rollback."
	)
	_expect(
		not coordinator.owns_enemy(enemy, token),
		"A released token must be invalid immediately after rollback."
	)
	enemy.touch_damage_cooldown_left = 1.0
	await physics_frame
	await physics_frame
	_expect(
		enemy.touch_damage_cooldown_left < 1.0,
		"The restored LEGACY callback must keep authoritative timers advancing."
	)
	_expect(
		enemy.scheduled_authoritative_step_count == scheduled_after,
		"No scheduled callback may run after a LEGACY rollback."
	)
	enemy.queue_free()
	await physics_frame


func _test_suspended_enemy_rollback(
	runtime: EnemyGameplayGatewayTestRuntime,
	coordinator: EnemySimulationCoordinator
) -> void:
	coordinator.set_mode(EnemySimulationPolicy.Mode.COMPAT_60)
	var enemy := _spawn_enemy(runtime)
	_expect(enemy.is_centrally_simulated(), "The suspended fixture must first be centrally owned.")
	enemy.set_authoritative_simulation_enabled(false)
	_expect(
		enemy.authoritative_simulation_driver
		== Enemy.AuthoritativeSimulationDriver.SCHEDULED_SUSPENDED,
		"Central suspension must preserve ownership without simulation."
	)
	coordinator.set_mode(EnemySimulationPolicy.Mode.LEGACY)
	_expect(
		enemy.authoritative_simulation_driver
		== Enemy.AuthoritativeSimulationDriver.INDIVIDUAL,
		"Rollback must restore the individual driver even for a suspended enemy."
	)
	_expect(
		not enemy.is_physics_processing(),
		"A suspended enemy must remain paused when ownership returns to LEGACY."
	)
	enemy.queue_free()
	await physics_frame


func _test_compat_tick_matches_legacy(
	runtime: EnemyGameplayGatewayTestRuntime,
	coordinator: EnemySimulationCoordinator
) -> void:
	coordinator.set_mode(EnemySimulationPolicy.Mode.LEGACY)
	var legacy_enemy := FAST_CONFIG.enemy_scene.instantiate() as YuanshiInsect
	runtime.enemy_container.add_child(legacy_enemy)
	legacy_enemy.setup(FAST_CONFIG, null, runtime.grid_pathfinder, null)
	legacy_enemy.set_physics_process(false)

	coordinator.set_mode(EnemySimulationPolicy.Mode.COMPAT_60)
	var compat_enemy := _spawn_enemy(runtime)
	coordinator.set_physics_process(false)
	await physics_frame

	legacy_enemy.global_position = Vector2(-128.0, -128.0)
	compat_enemy.global_position = Vector2(128.0, 128.0)
	legacy_enemy.touch_damage_cooldown_left = 1.0
	compat_enemy.touch_damage_cooldown_left = 1.0
	legacy_enemy.velocity = Vector2(4.0, -2.0)
	compat_enemy.velocity = Vector2(4.0, -2.0)
	legacy_enemy._physics_process(TEST_DELTA)
	coordinator._physics_process(TEST_DELTA)

	var legacy_signature := _capture_tick_signature(legacy_enemy)
	var compat_signature := _capture_tick_signature(compat_enemy)
	_expect(
		legacy_signature == compat_signature,
		"COMPAT_60 must preserve the real Yuanshi per-tick state transition."
	)
	_expect(
		compat_enemy.scheduled_authoritative_step_count == 1,
		"The paired compatibility sample must consume exactly one scheduled step."
	)

	coordinator.set_mode(EnemySimulationPolicy.Mode.LEGACY)
	legacy_enemy.queue_free()
	compat_enemy.queue_free()
	await physics_frame


func _test_live_forward_handoff(
	runtime: EnemyGameplayGatewayTestRuntime,
	coordinator: EnemySimulationCoordinator
) -> void:
	coordinator.set_mode(EnemySimulationPolicy.Mode.LEGACY)
	var enemy := _spawn_enemy(runtime)
	_expect(
		not enemy.is_centrally_simulated() and enemy.is_physics_processing(),
		"A LEGACY enemy must begin with its individual callback."
	)
	coordinator.set_mode(EnemySimulationPolicy.Mode.COMPAT_60)
	_expect(
		enemy.is_centrally_simulated(),
		"A live forward A/B switch must claim existing supported enemies."
	)
	_expect(
		not enemy.is_physics_processing(),
		"A live forward handoff must atomically disable individual processing."
	)
	coordinator.set_mode(EnemySimulationPolicy.Mode.LEGACY)
	_expect(
		not enemy.is_centrally_simulated(),
		"The live forward sample must remain safely reversible."
	)
	enemy.queue_free()
	await physics_frame


func _test_all_family_tick_signatures(
	runtime: EnemyGameplayGatewayTestRuntime,
	coordinator: EnemySimulationCoordinator
) -> void:
	var config_paths := _discover_enemy_config_paths()
	_expect(
		config_paths.size() == EXPECTED_CONFIG_COUNT,
		"COMPAT signature matrix must discover exactly %d EnemyConfigs."
		% EXPECTED_CONFIG_COUNT
	)
	var boss_container := runtime.get_node_or_null("BossContainer")
	_expect(boss_container != null, "The signature fixture must author BossContainer.")
	if boss_container == null:
		return

	for config_index in range(config_paths.size()):
		var config_path := config_paths[config_index]
		var config := ResourceLoader.load(config_path) as EnemyConfig
		if config == null or config.enemy_scene == null:
			continue
		coordinator.set_mode(EnemySimulationPolicy.Mode.LEGACY)
		var legacy_enemy := config.enemy_scene.instantiate() as Enemy
		var compat_enemy := config.enemy_scene.instantiate() as Enemy
		_expect(
			legacy_enemy != null and compat_enemy != null,
			"%s must instantiate a paired Enemy fixture." % config_path
		)
		if legacy_enemy == null or compat_enemy == null:
			if legacy_enemy != null:
				legacy_enemy.free()
			if compat_enemy != null:
				compat_enemy.free()
			continue
		legacy_enemy.name = "LegacyPair%d" % config_index
		compat_enemy.name = "CompatPair%d" % config_index
		# The legacy peer is intentionally outside both combat containers. It binds
		# the same runtime services, but a live mode switch only claims the authored
		# BossContainer / EnemyContainer fixture under test.
		runtime.add_child(legacy_enemy)
		var compat_container := (
			boss_container if config.is_boss else runtime.enemy_container
		)
		compat_container.add_child(compat_enemy)
		legacy_enemy.setup(config, null, runtime.grid_pathfinder, runtime)
		compat_enemy.setup(config, null, runtime.grid_pathfinder, runtime)
		legacy_enemy.global_position = Vector2(256.0, 192.0)
		compat_enemy.global_position = legacy_enemy.global_position
		legacy_enemy.velocity = Vector2(3.0, -2.0)
		compat_enemy.velocity = legacy_enemy.velocity
		legacy_enemy.random_generator.seed = 91_000 + config_index
		compat_enemy.random_generator.state = legacy_enemy.random_generator.state
		legacy_enemy.material_drop_random_generator.seed = 191_000 + config_index
		compat_enemy.material_drop_random_generator.state = (
			legacy_enemy.material_drop_random_generator.state
		)
		_copy_comparable_script_state(legacy_enemy, compat_enemy)

		coordinator.set_mode(EnemySimulationPolicy.Mode.COMPAT_60)
		_expect(
			compat_enemy.is_centrally_simulated()
			and not legacy_enemy.is_centrally_simulated(),
			"%s paired fixture must claim only its COMPAT member." % config_path
		)
		if legacy_enemy is LinglanBoss:
			(legacy_enemy as LinglanBoss).set_active(true)
			(compat_enemy as LinglanBoss).set_active(true)
		else:
			legacy_enemy.set_authoritative_simulation_enabled(true)
			compat_enemy.set_authoritative_simulation_enabled(true)
		legacy_enemy.set_physics_process(false)
		coordinator.set_physics_process(false)
		await physics_frame
		# Timer/animation callbacks may have advanced while crossing the activation
		# fence. Re-copy primitive script state immediately before the paired tick.
		_copy_comparable_script_state(legacy_enemy, compat_enemy)
		compat_enemy.global_position = legacy_enemy.global_position
		compat_enemy.velocity = legacy_enemy.velocity
		compat_enemy.random_generator.state = legacy_enemy.random_generator.state
		compat_enemy.material_drop_random_generator.state = (
			legacy_enemy.material_drop_random_generator.state
		)
		var scheduled_before := compat_enemy.scheduled_authoritative_step_count
		legacy_enemy.call(&"_physics_process", TEST_DELTA)
		coordinator.call(&"_physics_process", TEST_DELTA)
		coordinator.set_physics_process(false)

		var legacy_signature := _capture_family_tick_signature(legacy_enemy)
		var compat_signature := _capture_family_tick_signature(compat_enemy)
		_expect(
			legacy_signature == compat_signature,
			"%s COMPAT_60 tick diverged from the shared legacy runner. legacy=%s compat=%s"
			% [
				config_path,
				JSON.stringify(legacy_signature),
				JSON.stringify(compat_signature),
			]
		)
		_expect(
			compat_enemy.scheduled_authoritative_step_count
				== scheduled_before + 1,
			"%s must consume exactly one scheduled step." % config_path
		)

		coordinator.set_mode(EnemySimulationPolicy.Mode.LEGACY)
		legacy_enemy.queue_free()
		compat_enemy.queue_free()
		await process_frame
		await physics_frame
		coordinator.set_physics_process(false)


func _discover_enemy_config_paths() -> Array[String]:
	var result: Array[String] = []
	var directory := DirAccess.open(ENEMY_CONFIG_DIRECTORY)
	if directory == null:
		return result
	for file_name in directory.get_files():
		if not file_name.ends_with(".tres"):
			continue
		var path := "%s/%s" % [ENEMY_CONFIG_DIRECTORY, file_name]
		if ResourceLoader.load(path) is EnemyConfig:
			result.append(path)
	result.sort()
	return result


func _copy_comparable_script_state(source: Enemy, target: Enemy) -> void:
	for property_info in source.get_property_list():
		var usage := int(property_info.get("usage", 0))
		if usage & PROPERTY_USAGE_SCRIPT_VARIABLE == 0:
			continue
		if usage & PROPERTY_USAGE_READ_ONLY != 0:
			continue
		var property_name := StringName(property_info.get("name", &""))
		if property_name == &"" or String(property_name) in SIGNATURE_STATE_EXCLUSIONS:
			continue
		var value: Variant = source.get(property_name)
		if _is_comparable_state_type(typeof(value)):
			target.set(property_name, value)


func _capture_family_tick_signature(enemy: Enemy) -> Dictionary:
	var state := {}
	for property_info in enemy.get_property_list():
		var usage := int(property_info.get("usage", 0))
		if usage & PROPERTY_USAGE_SCRIPT_VARIABLE == 0:
			continue
		var property_name := StringName(property_info.get("name", &""))
		if property_name == &"" or String(property_name) in SIGNATURE_STATE_EXCLUSIONS:
			continue
		var value: Variant = enemy.get(property_name)
		if _is_comparable_state_type(typeof(value)):
			state[String(property_name)] = _normalize_signature_value(value)
	state["global_position"] = _normalize_signature_value(enemy.global_position)
	state["velocity"] = _normalize_signature_value(enemy.velocity)
	state["behavior_rng_state"] = enemy.random_generator.state
	state["drop_rng_state"] = enemy.material_drop_random_generator.state
	if enemy.animated_sprite != null:
		state["animation"] = String(enemy.animated_sprite.animation)
		state["animation_frame"] = enemy.animated_sprite.frame
	return state


func _is_comparable_state_type(type: int) -> bool:
	return type in [
		TYPE_BOOL,
		TYPE_INT,
		TYPE_FLOAT,
		TYPE_STRING,
		TYPE_STRING_NAME,
		TYPE_VECTOR2,
	]


func _normalize_signature_value(value: Variant) -> Variant:
	match typeof(value):
		TYPE_FLOAT:
			return snappedf(float(value), 0.000001)
		TYPE_VECTOR2:
			var vector := value as Vector2
			return Vector2(
				snappedf(vector.x, 0.000001),
				snappedf(vector.y, 0.000001)
			)
		TYPE_STRING_NAME:
			return String(value)
		_:
			return value


func _capture_tick_signature(enemy: YuanshiInsect) -> Dictionary:
	return {
		"cooldown": snappedf(enemy.touch_damage_cooldown_left, 0.000001),
		"velocity": enemy.velocity,
		"position_delta": enemy.global_position.abs(),
		"is_dead": enemy.is_dead,
		"has_contact": enemy.call("_has_player_contact"),
	}


func _spawn_enemy(runtime: EnemyGameplayGatewayTestRuntime) -> YuanshiInsect:
	var enemy := FAST_CONFIG.enemy_scene.instantiate() as YuanshiInsect
	runtime.enemy_container.add_child(enemy)
	enemy.setup(FAST_CONFIG, null, runtime.grid_pathfinder, runtime)
	return enemy


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
