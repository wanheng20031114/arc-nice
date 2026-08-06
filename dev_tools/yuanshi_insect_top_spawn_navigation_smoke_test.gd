extends SceneTree

const GAME_SCENE := preload("res://scene/game_modes/standard/standard_game.tscn")
const BASIC_CONFIG := preload("res://resources/config/enemies/yuanshi_insect_basic.tres")
const FAST_CONFIG := preload("res://resources/config/enemies/yuanshi_insect_fast.tres")
const SHELL_CONFIG := preload("res://resources/config/enemies/yuanshi_insect_shell.tres")
const BOMBER_CONFIG := preload("res://resources/config/enemies/yuanshi_insect_bomber.tres")
const PURPLE_BOMBER_CONFIG := preload("res://resources/config/enemies/yuanshi_insect_purple_bomber.tres")
const GREEN_SHELL_CONFIG := preload("res://resources/config/enemies/yuanshi_insect_green_shell.tres")
const GUARDIAN_CONFIG := preload("res://resources/config/enemies/yuanshi_insect_guardian.tres")
const FIRE_RANGED_CONFIG := preload("res://resources/config/enemies/yuanshi_insect_fire_ranged.tres")

const SIMULATION_SECONDS := 3.0
const PHYSICS_DELTA := 1.0 / 60.0

var failures: Array[String] = []


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	var game := GAME_SCENE.instantiate() as StandardGame
	game.auto_start_waves = false
	root.add_child(game)
	current_scene = game
	await process_frame
	await physics_frame

	var spawn_point := game.get_node_or_null("EnemySpawnPoints/Spawn1") as Marker2D
	var pathfinder := game.get_node_or_null("GridPathfinder") as GridPathfinder
	_expect(spawn_point != null, "StandardGame must provide the top enemy spawn point.")
	_expect(pathfinder != null and pathfinder.is_built, "StandardGame must provide a built GridPathfinder.")
	if spawn_point == null or pathfinder == null or not pathfinder.is_built:
		_finish(game)
		return

	game.player.global_position = Vector2(39.0, 180.0)

	for enemy_config in [
		BASIC_CONFIG,
		FAST_CONFIG,
		SHELL_CONFIG,
		BOMBER_CONFIG,
		PURPLE_BOMBER_CONFIG,
		GREEN_SHELL_CONFIG,
		GUARDIAN_CONFIG,
		FIRE_RANGED_CONFIG,
	]:
		await _test_top_spawn_navigation_for_config(game, spawn_point, pathfinder, enemy_config)

	_finish(game)


func _test_top_spawn_navigation_for_config(
	game: StandardGame,
	spawn_point: Marker2D,
	pathfinder: GridPathfinder,
	enemy_config: EnemyConfig
) -> void:
	var enemy := _spawn_insect(game, spawn_point.global_position, enemy_config)
	await physics_frame

	var display_name := enemy_config.display_name
	var waypoint_result: Variant = pathfinder.get_flow_navigation_waypoint(
		enemy.global_position,
		game.player.global_position,
		enemy.call("_get_body_collision_half_extents") as Vector2
	)
	_expect(waypoint_result != null, "%s from top spawn must receive a flow-field waypoint." % display_name)
	if waypoint_result != null:
		var waypoint: Vector2 = waypoint_result
		_expect(waypoint.y > enemy.global_position.y, "%s first top-spawn waypoint must lead into the map." % display_name)

	var start_position := enemy.global_position
	var max_y := start_position.y
	var moved_distance := 0.0
	var closest_distance_to_player := start_position.distance_to(game.player.global_position)
	var previous_position := enemy.global_position
	var simulation_frames := int(ceili(SIMULATION_SECONDS / PHYSICS_DELTA))
	for _frame_index in range(simulation_frames):
		await physics_frame
		max_y = maxf(max_y, enemy.global_position.y)
		moved_distance += enemy.global_position.distance_to(previous_position)
		closest_distance_to_player = minf(closest_distance_to_player, enemy.global_position.distance_to(game.player.global_position))
		previous_position = enemy.global_position

	_expect(max_y >= 8.0, "%s must enter the playable map from the top spawn." % display_name)
	_expect(moved_distance >= 16.0, "%s must keep moving after top spawn and not get stuck at the boundary." % display_name)
	_expect(
		closest_distance_to_player <= start_position.distance_to(game.player.global_position) - 16.0,
		"%s must make meaningful progress toward the player from top spawn." % display_name
	)
	enemy.queue_free()
	await physics_frame


func _spawn_insect(game: StandardGame, position: Vector2, enemy_config: EnemyConfig) -> YuanshiInsect:
	var enemy := enemy_config.enemy_scene.instantiate() as YuanshiInsect
	game.enemy_container.add_child(enemy)
	enemy.global_position = position
	enemy.setup(enemy_config, game.player, game.grid_pathfinder)
	return enemy


func _finish(game: Node) -> void:
	game.queue_free()
	await process_frame
	await physics_frame

	if failures.is_empty():
		print("YUANSHI_INSECT_TOP_SPAWN_NAVIGATION_SMOKE_TEST_OK")
		quit()
		return

	for failure in failures:
		push_error(failure)
	quit(1)


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
