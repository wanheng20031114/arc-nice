extends SceneTree

const STANDARD_GAME_SCENE := preload(
	"res://scene/game_modes/standard/standard_game.tscn"
)
const STANDARD_GAME_SOURCE_PATH := (
	"res://scene/game_modes/standard/standard_game.gd"
)
const WAVE_RUNTIME_SOURCE_PATH := (
	"res://scene/combat/runtime/wave_combat_runtime_base.gd"
)
const TOWER_PREWARMER_SOURCE_PATH := (
	"res://scene/game_modes/tower_defense/prewarm/tower_defense_prewarmer_coordinator.gd"
)
const AGAVE_CANNONBALL_SCENE_PATH := (
	"res://scene/plant_defense/agave_cannonball.tscn"
)

var failures: Array[String] = []


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	_test_source_boundaries()
	await _test_standard_runtime_has_no_dead_pool()
	if failures.is_empty():
		print("STANDARD_AGAVE_CANNONBALL_BOUNDARY_SMOKE_TEST_OK")
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	quit(1)


func _test_source_boundaries() -> void:
	var standard_source := (
		FileAccess.get_file_as_string(STANDARD_GAME_SOURCE_PATH)
		+ "\n"
		+ FileAccess.get_file_as_string(WAVE_RUNTIME_SOURCE_PATH)
	)
	var tower_source := FileAccess.get_file_as_string(TOWER_PREWARMER_SOURCE_PATH)
	_expect(
		not standard_source.contains(AGAVE_CANNONBALL_SCENE_PATH),
		"StandardGame must not preload the tower-only Agave cannonball."
	)
	_expect(
		not standard_source.contains("AGAVE_CANNONBALL_POOL_SCENE"),
		"StandardGame must not register an unused Agave cannonball pool."
	)
	_expect(
		tower_source.count(AGAVE_CANNONBALL_SCENE_PATH) == 1
		and tower_source.contains(
			"register_scene(AGAVE_CANNONBALL_POOL_SCENE, 48, 384)"
		),
		"TowerDefensePrewarmerCoordinator must retain the live Agave cannonball pool contract."
	)


func _test_standard_runtime_has_no_dead_pool() -> void:
	var game := STANDARD_GAME_SCENE.instantiate() as StandardGame
	_expect(game != null, "StandardGame must instantiate for pool boundary test.")
	if game == null:
		return
	game.auto_start_waves = false
	root.add_child(game)
	await process_frame
	_expect(
		game.session_object_pool.get_metrics(AGAVE_CANNONBALL_SCENE_PATH).is_empty(),
		"StandardGame must not create a metrics bucket for the tower-only projectile."
	)
	var pooled_nodes := 0
	for candidate in game.session_object_pool.find_children("*", "", true, false):
		if str(candidate.get_meta(SessionObjectPool.POOL_KEY_META, "")) == AGAVE_CANNONBALL_SCENE_PATH:
			pooled_nodes += 1
	_expect(
		pooled_nodes == 0,
		"StandardGame must instantiate zero Agave cannonball pool nodes."
	)
	game.queue_free()
	await process_frame
	await process_frame


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
