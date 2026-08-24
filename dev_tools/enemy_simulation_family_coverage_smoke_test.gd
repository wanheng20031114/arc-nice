extends SceneTree

const RUNTIME_SCENE := preload(
	"res://dev_tools/fixtures/enemy_gameplay_gateway_test_runtime.tscn"
)
const BASIC_CONFIG := preload(
	"res://resources/config/enemies/yuanshi_insect_basic.tres"
)
const LINGLAN_CONFIG := preload(
	"res://resources/config/enemies/linglan_boss.tres"
)
const COORDINATOR_SCENE := preload(
	"res://scene/combat/simulation/enemy_simulation_coordinator.tscn"
)

const ENEMY_CONFIG_DIRECTORY := "res://resources/config/enemies"
const ENEMY_BASE_SCRIPT_PATH := "res://scene/enemy/enemy.gd"
const EXPECTED_CONFIG_COUNT := 64
const EXPECTED_CENTRALIZED_CONFIG_COUNT := 64
const TEST_DELTA := 1.0 / 60.0

var failures: Array[String] = []


func _init() -> void:
	call_deferred(&"_run")


func _run() -> void:
	var config_paths := _discover_enemy_config_paths()
	_expect(
		config_paths.size() == EXPECTED_CONFIG_COUNT,
		"EnemyConfig closure must contain exactly %d resources, found %d."
		% [EXPECTED_CONFIG_COUNT, config_paths.size()]
	)
	var inherited_scripts: Dictionary[String, bool] = {}
	var resource_audit := _audit_resource_closure(
		config_paths,
		inherited_scripts
	)
	var centralized_count := int(resource_audit.get("centralized_count", -1))
	var layered_area_paths: Array[String] = []
	layered_area_paths.assign(resource_audit.get("layered_area_paths", []))
	layered_area_paths.sort()
	var expected_layered_area_paths: Array[String] = []
	expected_layered_area_paths.assign(config_paths)
	expected_layered_area_paths.sort()
	_expect(
		centralized_count == EXPECTED_CENTRALIZED_CONFIG_COUNT,
		"COMPAT_60 must cover exactly all %d configs; found %d."
		% [EXPECTED_CENTRALIZED_CONFIG_COUNT, centralized_count]
	)
	_expect(
		expected_layered_area_paths.size() == EXPECTED_CONFIG_COUNT
		and expected_layered_area_paths.has(LINGLAN_CONFIG.resource_path),
		"The final LAYERED_AREA closure must contain all 64 configs, including Linglan."
	)
	_expect(
		layered_area_paths == expected_layered_area_paths,
		(
			"The certified LAYERED_AREA config set changed. Missing=%s Unexpected=%s"
			% [
				_path_set_difference(expected_layered_area_paths, layered_area_paths),
				_path_set_difference(layered_area_paths, expected_layered_area_paths),
			]
		)
	)
	_audit_authoritative_entrypoints(inherited_scripts)
	_audit_authored_default()
	await _audit_all_family_handoffs(config_paths)
	await _audit_container_claim_and_rollback()
	await _audit_linglan_suspend_resume()

	var result := {
		"status": "ok" if failures.is_empty() else "failed",
		"config_count": config_paths.size(),
		"centralized_count": centralized_count,
		"layered_area_count": layered_area_paths.size(),
		"layered_area_paths": layered_area_paths,
		"inherited_script_count": inherited_scripts.size(),
		"failures": failures.duplicate(),
	}
	print("ENEMY_SIMULATION_FAMILY_COVERAGE_JSON %s" % JSON.stringify(result))
	if failures.is_empty():
		print("ENEMY_SIMULATION_FAMILY_COVERAGE_SMOKE_TEST_OK")
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	quit(1)


func _discover_enemy_config_paths() -> Array[String]:
	var result: Array[String] = []
	var directory := DirAccess.open(ENEMY_CONFIG_DIRECTORY)
	_expect(directory != null, "Enemy config directory must be readable.")
	if directory == null:
		return result
	for file_name in directory.get_files():
		if not file_name.ends_with(".tres"):
			continue
		var path := "%s/%s" % [ENEMY_CONFIG_DIRECTORY, file_name]
		var resource := ResourceLoader.load(path)
		if resource is EnemyConfig:
			result.append(path)
	result.sort()
	return result


func _audit_resource_closure(
	config_paths: Array[String],
	inherited_scripts: Dictionary[String, bool]
) -> Dictionary:
	var centralized_count := 0
	var layered_area_paths: Array[String] = []
	for config_path in config_paths:
		var config := ResourceLoader.load(config_path) as EnemyConfig
		_expect(config != null, "%s must load as EnemyConfig." % config_path)
		if config == null:
			continue
		_expect(
			config.enemy_scene != null and config.enemy_scene.can_instantiate(),
			"%s must provide an instantiable enemy_scene." % config_path
		)
		if config.enemy_scene == null or not config.enemy_scene.can_instantiate():
			continue
		var enemy := config.enemy_scene.instantiate() as Enemy
		_expect(enemy != null, "%s enemy_scene root must inherit Enemy." % config_path)
		if enemy == null:
			continue
		var supports_centralized := (
			enemy.supports_centralized_authoritative_simulation()
		)
		_expect(
			supports_centralized,
			"%s must opt into centralized COMPAT ownership." % config_path
		)
		_expect(
			not enemy.uses_anchored_compat_simulation(),
			"%s must use the ordinary coordinator traversal; no anchored exception remains."
			% config_path
		)
		if supports_centralized:
			centralized_count += 1
			_collect_script_inheritance(enemy.get_script() as Script, inherited_scripts)
		if enemy.supports_layered_area_authoritative_simulation():
			layered_area_paths.append(config_path)
		enemy.free()
	return {
		"centralized_count": centralized_count,
		"layered_area_paths": layered_area_paths,
	}


func _path_set_difference(
	left_paths: Array[String],
	right_paths: Array[String]
) -> Array[String]:
	var difference: Array[String] = []
	for path in left_paths:
		if not right_paths.has(path):
			difference.append(path)
	return difference


func _collect_script_inheritance(
	script_resource: Script,
	result: Dictionary[String, bool]
) -> void:
	var current := script_resource
	while current != null:
		if current.resource_path != "":
			result[current.resource_path] = true
		current = current.get_base_script()


func _audit_authoritative_entrypoints(
	inherited_scripts: Dictionary[String, bool]
) -> void:
	for script_path in inherited_scripts.keys():
		var path := String(script_path)
		if path == ENEMY_BASE_SCRIPT_PATH:
			continue
		var file := FileAccess.open(path, FileAccess.READ)
		_expect(file != null, "%s must be readable for entrypoint audit." % path)
		if file == null:
			continue
		var source := file.get_as_text()
		_expect(
			not source.begins_with("func _physics_process(")
			and not source.contains("\nfunc _physics_process("),
			"%s must inherit Enemy's guarded _physics_process entrypoint." % path
		)
		_expect(
			not source.contains("super._physics_process("),
			"%s must call super._run_authoritative_physics_step, never the callback."
			% path
		)


func _audit_authored_default() -> void:
	var coordinator := COORDINATOR_SCENE.instantiate() as EnemySimulationCoordinator
	_expect(coordinator != null, "The authored coordinator scene must instantiate.")
	if coordinator == null:
		return
	_expect(
		coordinator.mode == EnemySimulationPolicy.Mode.LAYERED_CONTACT,
		"The authored stable default must use the accepted layered-contact mode."
	)
	coordinator.free()
	_expect(
		EnemySimulationPolicy.resolve_mode_from_arguments(
			PackedStringArray(["--enemy-simulation-mode=legacy"]),
			EnemySimulationPolicy.Mode.COMPAT_60
		) == EnemySimulationPolicy.Mode.LEGACY,
		"The command-line LEGACY override must remain an immediate rollback path."
	)


func _audit_all_family_handoffs(config_paths: Array[String]) -> void:
	var runtime := RUNTIME_SCENE.instantiate() as EnemyGameplayGatewayTestRuntime
	_expect(runtime != null, "The authored family coverage runtime must instantiate.")
	if runtime == null:
		return
	root.add_child(runtime)
	await process_frame
	var coordinator := runtime.get_enemy_simulation_coordinator()
	var enemy_container := runtime.get_node_or_null("EnemyContainer")
	var boss_container := runtime.get_node_or_null("BossContainer")
	_expect(
		coordinator != null and enemy_container != null and boss_container != null,
		"The coverage runtime must author coordinator, EnemyContainer, and BossContainer."
	)
	if coordinator == null or enemy_container == null or boss_container == null:
		runtime.queue_free()
		await process_frame
		return
	var expected_start_mode := EnemySimulationPolicy.resolve_mode_from_arguments(
		OS.get_cmdline_user_args(),
		EnemySimulationPolicy.Mode.LAYERED_CONTACT
	)
	_expect(
		coordinator.mode == expected_start_mode,
		(
			"Runtime startup mode must honor the authored LAYERED_CONTACT default "
			+ "or an explicit CLI rollback override."
		)
	)
	coordinator.set_mode(EnemySimulationPolicy.Mode.COMPAT_60)
	coordinator.set_physics_process(false)

	for config_path in config_paths:
		var config := ResourceLoader.load(config_path) as EnemyConfig
		if config == null or config.enemy_scene == null:
			continue
		var enemy := config.enemy_scene.instantiate() as Enemy
		if enemy == null:
			continue
		var container := boss_container if config.is_boss else enemy_container
		container.add_child(enemy)
		enemy.setup(config, null, runtime.grid_pathfinder, runtime)
		coordinator.set_physics_process(false)
		if config_path == LINGLAN_CONFIG.resource_path:
			var layered_boss := enemy as LinglanBoss
			_expect(
				layered_boss != null
				and enemy.get_node_or_null("EnemySimulationPhaseAnchor") == null
				and layered_boss.is_centrally_simulated()
				and layered_boss.authoritative_simulation_driver
					== Enemy.AuthoritativeSimulationDriver.SCHEDULED_SUSPENDED
				and layered_boss.enemy_simulation_token > 0
				and layered_boss.simulation_id > 0
				and layered_boss.supports_layered_area_authoritative_simulation()
				and not layered_boss.uses_anchored_compat_simulation()
				and not layered_boss.is_physics_processing(),
				"Inactive Linglan must retain suspended ordinary coordinator ownership."
			)
			if layered_boss != null:
				layered_boss.set_active(true)
				_expect(
					layered_boss.authoritative_simulation_driver
						== Enemy.AuthoritativeSimulationDriver.SCHEDULED_ACTIVE
					and not layered_boss.is_physics_processing(),
					"Active Linglan must resume scheduled ownership without its root callback."
				)
		var token := enemy.enemy_simulation_token
		_expect(
			enemy.is_centrally_simulated()
			and token > 0
			and enemy.simulation_id > 0
			and coordinator.owns_enemy(enemy, token)
			and not enemy.is_physics_processing(),
			"%s must atomically hand off to one scheduled driver." % config_path
		)
		var scheduled_before := enemy.scheduled_authoritative_step_count
		var suppressed_before := enemy.suppressed_direct_authoritative_step_count
		enemy.call(&"_physics_process", TEST_DELTA)
		_expect(
			enemy.scheduled_authoritative_step_count == scheduled_before
			and enemy.suppressed_direct_authoritative_step_count
				== suppressed_before + 1,
			"%s direct callback must be suppressed without a state step." % config_path
		)
		enemy.set_authoritative_simulation_enabled(true)
		coordinator.set_physics_process(false)
		await physics_frame
		var one_step_before := enemy.scheduled_authoritative_step_count
		coordinator.call(&"_physics_process", TEST_DELTA)
		coordinator.set_physics_process(false)
		_expect(
			enemy.scheduled_authoritative_step_count == one_step_before + 1,
			"%s must execute exactly one shared runner step per coordinator tick."
			% config_path
		)
		enemy.queue_free()
		await process_frame
		await physics_frame
		coordinator.set_physics_process(false)
		_expect(
			int(coordinator.get_metrics()["registered_count"]) == 0,
			"%s teardown must unregister its scheduled slot." % config_path
		)

	coordinator.set_mode(EnemySimulationPolicy.Mode.LEGACY)
	runtime.queue_free()
	await process_frame
	await physics_frame


func _audit_container_claim_and_rollback() -> void:
	var runtime := RUNTIME_SCENE.instantiate() as EnemyGameplayGatewayTestRuntime
	if runtime == null:
		return
	root.add_child(runtime)
	await process_frame
	var coordinator := runtime.get_enemy_simulation_coordinator()
	var enemy_container := runtime.get_node_or_null("EnemyContainer")
	var boss_container := runtime.get_node_or_null("BossContainer")
	if coordinator == null or enemy_container == null or boss_container == null:
		runtime.queue_free()
		await process_frame
		return
	coordinator.set_mode(EnemySimulationPolicy.Mode.LEGACY)
	var regular := BASIC_CONFIG.enemy_scene.instantiate() as Enemy
	var boss_container_enemy := BASIC_CONFIG.enemy_scene.instantiate() as Enemy
	enemy_container.add_child(regular)
	boss_container.add_child(boss_container_enemy)
	regular.setup(BASIC_CONFIG, null, runtime.grid_pathfinder, runtime)
	boss_container_enemy.setup(BASIC_CONFIG, null, runtime.grid_pathfinder, runtime)
	_expect(
		regular.is_physics_processing()
		and boss_container_enemy.is_physics_processing()
		and not regular.is_centrally_simulated()
		and not boss_container_enemy.is_centrally_simulated(),
		"LEGACY fixtures must begin under individual callbacks."
	)
	coordinator.set_mode(EnemySimulationPolicy.Mode.COMPAT_60)
	_expect(
		regular.is_centrally_simulated()
		and boss_container_enemy.is_centrally_simulated()
		and not regular.is_physics_processing()
		and not boss_container_enemy.is_physics_processing(),
		"A live forward switch must claim both authored combat containers."
	)
	coordinator.set_mode(EnemySimulationPolicy.Mode.LEGACY)
	_expect(
		not regular.is_centrally_simulated()
		and not boss_container_enemy.is_centrally_simulated()
		and regular.is_physics_processing()
		and boss_container_enemy.is_physics_processing(),
		"LEGACY rollback must restore both active individual callbacks."
	)
	regular.queue_free()
	boss_container_enemy.queue_free()
	runtime.queue_free()
	await process_frame
	await physics_frame


func _audit_linglan_suspend_resume() -> void:
	var runtime := RUNTIME_SCENE.instantiate() as EnemyGameplayGatewayTestRuntime
	if runtime == null:
		return
	root.add_child(runtime)
	await process_frame
	var coordinator := runtime.get_enemy_simulation_coordinator()
	var contact_service := runtime.get_enemy_contact_service()
	var boss_container := runtime.get_node_or_null("BossContainer")
	if coordinator == null or contact_service == null or boss_container == null:
		runtime.queue_free()
		await process_frame
		return
	coordinator.set_mode(EnemySimulationPolicy.Mode.COMPAT_60)
	var boss := LINGLAN_CONFIG.enemy_scene.instantiate() as LinglanBoss
	_expect(boss != null, "Linglan config must instantiate LinglanBoss.")
	if boss == null:
		runtime.queue_free()
		await process_frame
		return
	boss_container.add_child(boss)
	boss.setup(LINGLAN_CONFIG, null, runtime.grid_pathfinder, runtime)
	_expect(
		boss.get_node_or_null("EnemySimulationPhaseAnchor") == null
		and not boss.uses_anchored_compat_simulation()
		and boss.supports_layered_area_authoritative_simulation(),
		"Linglan must use the ordinary layered scheduler without a phase anchor."
	)
	var owned_token := boss.enemy_simulation_token
	_expect(
		boss.is_centrally_simulated()
		and owned_token > 0
		and coordinator.owns_enemy(boss, owned_token)
		and boss.authoritative_simulation_driver
			== Enemy.AuthoritativeSimulationDriver.SCHEDULED_SUSPENDED
		and not boss.is_physics_processing(),
		"Inactive Linglan must keep a suspended ordinary registration."
	)
	boss.set_active(true)
	_expect(
		boss.authoritative_simulation_driver
			== Enemy.AuthoritativeSimulationDriver.SCHEDULED_ACTIVE
		and not boss.is_physics_processing(),
		"Activating Linglan must resume coordinator-owned simulation."
	)
	await physics_frame
	var scheduled_before := boss.scheduled_authoritative_step_count
	coordinator.call(&"_physics_process", TEST_DELTA)
	coordinator.set_physics_process(false)
	_expect(
		boss.scheduled_authoritative_step_count == scheduled_before + 1,
		"COMPAT_60 must execute Linglan exactly once through ordinary traversal."
	)

	coordinator.set_mode(EnemySimulationPolicy.Mode.LAYERED_CONTACT)
	_expect(
		boss.is_centrally_simulated()
		and coordinator.owns_enemy(boss, owned_token)
		and boss.supports_layered_area_authoritative_simulation()
		and not boss.supports_layered_contact_authoritative_simulation(),
		"Layered mode must use Linglan's event/motion phases while retaining its Area."
	)
	await physics_frame
	var layered_before := boss.scheduled_authoritative_step_count
	coordinator.call(&"_physics_process", TEST_DELTA)
	coordinator.set_physics_process(false)
	var contact_metrics: Dictionary = contact_service.get_metrics()
	_expect(
		boss.scheduled_authoritative_step_count == layered_before + 1
		and not boss.is_indexed_touch_authority_enabled()
		and boss.touch_damage_area.monitoring
		and not contact_service.owns_enemy(boss, boss.simulation_id)
		and int(contact_metrics["registered_count"]) == 0,
		"Layered Linglan must preserve its unverified Boss Area and avoid a contact proxy."
	)
	boss.set_active(false)
	_expect(
		boss.authoritative_simulation_driver
			== Enemy.AuthoritativeSimulationDriver.SCHEDULED_SUSPENDED
		and not boss.is_physics_processing(),
		"Deactivating Linglan must suspend, not discard, layered ownership."
	)
	coordinator.set_mode(EnemySimulationPolicy.Mode.LEGACY)
	var rollback_scheduled_steps := boss.scheduled_authoritative_step_count
	_expect(
		not boss.is_centrally_simulated()
		and boss.authoritative_simulation_driver
			== Enemy.AuthoritativeSimulationDriver.INDIVIDUAL
		and not boss.is_physics_processing()
		and boss.scheduled_authoritative_step_count == rollback_scheduled_steps
		and not coordinator.advance_anchored_compat_enemy(boss, TEST_DELTA),
		"LEGACY rollback must restore inactive individual ownership with no anchor path."
	)
	boss.set_active(true)
	_expect(
		boss.is_physics_processing(),
		"Active Linglan must resume its root callback after LEGACY rollback."
	)
	boss.queue_free()
	runtime.queue_free()
	await process_frame
	await physics_frame


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
