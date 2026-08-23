extends SceneTree

const COORDINATOR_SCENE_PATH := (
	"res://scene/combat/simulation/enemy_simulation_coordinator.tscn"
)
const COORDINATOR_SCENE := preload(
	"res://scene/combat/simulation/enemy_simulation_coordinator.tscn"
)
const COORDINATOR_SCRIPT := preload(
	"res://scene/combat/simulation/enemy_simulation_coordinator.gd"
)
const RapidFireSimulationServiceScript := preload(
	"res://scene/combat/simulation/rapid_fire_simulation_service.gd"
)
const EnemyDamageableSpatialIndexScript := preload(
	"res://scene/combat/targeting/enemy_damageable_spatial_index.gd"
)
const FIXTURE_SCENE := preload(
	"res://dev_tools/fixtures/enemy_gameplay_gateway_test_runtime.tscn"
)
const AUTHORED_RUNTIME_SCENE_PATHS := [
	"res://scene/game_modes/tower_defense/tower_defense_game.tscn",
	"res://scene/game_modes/standard/standard_game.tscn",
	"res://scene/game_modes/rogue/combat/rogue_combat_game_01.tscn",
	"res://scene/game_modes/rogue/combat/rogue_combat_game_02.tscn",
	"res://scene/game_modes/rogue/combat/rogue_combat_game_03.tscn",
	"res://scene/game_modes/rogue/combat/rogue_combat_game_04.tscn",
	"res://dev_tools/fixtures/enemy_gameplay_gateway_test_runtime.tscn",
]

var failures: Array[String] = []


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	_test_all_runtime_scenes_mount_the_shared_coordinator()
	_test_authored_coordinator_service_tree_defaults_to_idle()
	_test_direct_coordinator_without_authored_child_is_safe()
	await _test_fixture_binding_and_idempotent_teardown()
	_finish()


func _test_all_runtime_scenes_mount_the_shared_coordinator() -> void:
	for scene_path in AUTHORED_RUNTIME_SCENE_PATHS:
		_expect(
			FileAccess.file_exists(scene_path),
			"Unable to find authored runtime: %s" % scene_path
		)
		if not FileAccess.file_exists(scene_path):
			continue
		var scene_source := FileAccess.get_file_as_string(scene_path)
		var coordinator_count := scene_source.count(
			'[node name="EnemySimulationCoordinator"'
		)
		_expect(
			coordinator_count == 1,
			"Runtime must author exactly one EnemySimulationCoordinator: %s"
			% scene_path
		)
		_expect(
			scene_source.contains(COORDINATOR_SCENE_PATH),
			"Runtime must instance the shared coordinator PackedScene: %s"
			% scene_path
		)


func _test_authored_coordinator_service_tree_defaults_to_idle() -> void:
	var coordinator := COORDINATOR_SCENE.instantiate() as EnemySimulationCoordinator
	_expect(coordinator != null, "The authored coordinator scene must instantiate.")
	if coordinator == null:
		return
	var combat_services := coordinator.get_combat_services()
	_expect(
		combat_services != null,
		"The authored coordinator must contain EnemyCombatServices."
	)
	if combat_services != null:
		var rapid_fire_service := (
			combat_services.get_rapid_fire_simulation_service()
		)
		var damageable_spatial_index: EnemyDamageableSpatialIndexScript = (
			combat_services.get_enemy_damageable_spatial_index()
		)
		_expect(
			rapid_fire_service != null,
			"EnemyCombatServices must author RapidFireSimulationService."
		)
		if rapid_fire_service != null:
			var metrics := rapid_fire_service.get_metrics()
			_expect(
				StringName(metrics["profile"])
				== RapidFireSimulationServiceScript.PROFILE_AK,
				"The first rapid-fire profile must be AK."
			)
			_expect(
				int(metrics["mode"])
				== RapidFireSimulationServiceScript.Mode.DISABLED,
				"The authored rapid-fire service must default to DISABLED."
			)
			_expect(
				int(metrics["active_slots"]) == 0,
				"The authored rapid-fire service must start with zero slots."
			)
			_expect(
				not rapid_fire_service.is_physics_processing(),
				"The authored rapid-fire service must start physics-disabled."
			)
		_expect(
			damageable_spatial_index != null,
			"EnemyCombatServices must author EnemyDamageableSpatialIndex."
		)
		if damageable_spatial_index != null:
			var index_metrics := damageable_spatial_index.get_metrics()
			_expect(
				int(index_metrics["registered_count"]) == 0
				and int(index_metrics["membership_count"]) == 0,
				"The authored damageable index must start empty."
			)
	coordinator.free()


func _test_direct_coordinator_without_authored_child_is_safe() -> void:
	var coordinator := COORDINATOR_SCRIPT.new() as EnemySimulationCoordinator
	_expect(coordinator != null, "A direct coordinator instance must be valid.")
	if coordinator == null:
		return
	coordinator._ready()
	_expect(
		coordinator.get_combat_services() == null,
		"A direct coordinator instance must tolerate the optional child being absent."
	)
	coordinator.prepare_combat_services_for_runtime_teardown()
	coordinator.prepare_combat_services_for_runtime_teardown()
	_expect(
		not coordinator.is_physics_processing(),
		"A childless direct coordinator must remain physics-idle."
	)
	coordinator.free()


func _test_fixture_binding_and_idempotent_teardown() -> void:
	var runtime := FIXTURE_SCENE.instantiate() as EnemyGameplayGatewayTestRuntime
	_expect(runtime != null, "The gateway fixture must instantiate.")
	if runtime == null:
		return
	root.add_child(runtime)
	await process_frame

	var coordinator := runtime.get_enemy_simulation_coordinator()
	var combat_services := runtime.get_enemy_combat_services()
	_expect(coordinator != null, "The gateway fixture must expose its coordinator.")
	_expect(
		combat_services != null,
		"The gateway fixture must expose bound enemy combat services."
	)
	if coordinator != null and combat_services != null:
		var rapid_fire_service := (
			combat_services.get_rapid_fire_simulation_service()
		)
		var damageable_spatial_index: EnemyDamageableSpatialIndexScript = (
			combat_services.get_enemy_damageable_spatial_index()
		)
		_expect(
			combat_services.is_bound_to(runtime, coordinator),
			"EnemyCombatServices must bind to its authored runtime and coordinator."
		)
		_expect(
			rapid_fire_service != null
			and rapid_fire_service.is_bound_to(runtime, coordinator),
			"RapidFireSimulationService must inherit the same bound context."
		)
		_expect(
			damageable_spatial_index != null
			and damageable_spatial_index.is_bound_to(runtime, coordinator),
			"EnemyDamageableSpatialIndex must inherit the same bound context."
		)
		if damageable_spatial_index != null:
			var initial_index_metrics := damageable_spatial_index.get_metrics()
			_expect(
				int(initial_index_metrics["registered_count"]) == 0,
				"A non-tower runtime must keep the damageable index empty."
			)
		runtime.prepare_for_scene_teardown()
		runtime.prepare_for_scene_teardown()
		var service_metrics := combat_services.get_metrics()
		var rapid_fire_metrics: Dictionary = service_metrics["rapid_fire"]
		var damageable_index_metrics: Dictionary = (
			service_metrics["enemy_damageable_spatial_index"]
		)
		_expect(
			int(service_metrics["teardown_count"]) == 1,
			"EnemyCombatServices teardown must be idempotent."
		)
		_expect(
			int(rapid_fire_metrics["teardown_count"]) == 1,
			"RapidFireSimulationService teardown must be idempotent."
		)
		_expect(
			int(damageable_index_metrics["teardown_count"]) == 1,
			"EnemyDamageableSpatialIndex teardown must be idempotent."
		)
		_expect(
			not bool(service_metrics["bound"])
			and not bool(rapid_fire_metrics["bound"])
			and not bool(damageable_index_metrics["bound"]),
			"Teardown must release all runtime and coordinator references."
		)
		_expect(
			int(damageable_index_metrics["registered_count"]) == 0
			and int(damageable_index_metrics["membership_count"]) == 0,
			"Teardown must leave the damageable index structurally empty."
		)
		_expect(
			int(rapid_fire_metrics["active_slots"]) == 0
			and not bool(rapid_fire_metrics["physics_processing"]),
			"Teardown must leave zero rapid-fire slots and physics disabled."
		)
		_expect(
			runtime.get_enemy_combat_services() == null,
			"Runtime getter must not rebind or expose services after teardown."
		)
		_expect(
			not combat_services.bind_context(runtime, coordinator),
			"EnemyCombatServices must reject explicit rebind after teardown."
		)
		if rapid_fire_service != null:
			_expect(
				not rapid_fire_service.bind_context(runtime, coordinator),
				"RapidFireSimulationService must reject rebind after teardown."
			)
		if damageable_spatial_index != null:
			_expect(
				not damageable_spatial_index.bind_context(runtime, coordinator),
				"EnemyDamageableSpatialIndex must reject rebind after teardown."
			)

	runtime.queue_free()
	await process_frame
	await physics_frame


func _finish() -> void:
	var result := {
		"status": "ok" if failures.is_empty() else "failed",
		"failures": failures.duplicate(),
	}
	print("ENEMY_COMBAT_SERVICES_MOUNT_JSON %s" % JSON.stringify(result))
	if failures.is_empty():
		print("ENEMY_COMBAT_SERVICES_MOUNT_SMOKE_TEST_OK")
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	quit(1)


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
