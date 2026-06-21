extends SceneTree

const PLAYER_SCENE := preload("res://scene/player.tscn")
const FAST_CONFIG := preload("res://resources/config/enemies/yuanshi_insect_fast.tres")

var failures: Array[String] = []
var test_root: Node2D


class FakePathfinder:
	extends Node

	var is_built := true
	var requested_path := false
	var path := PackedVector2Array()

	func get_global_path(
		_from_global_position: Vector2,
		_to_global_position: Vector2,
		_agent_half_extents: Vector2 = Vector2.ZERO
	) -> PackedVector2Array:
		requested_path = true
		return path

	func try_get_global_path(
		_from_global_position: Vector2,
		_to_global_position: Vector2,
		_agent_half_extents: Vector2 = Vector2.ZERO
	) -> Variant:
		requested_path = true
		return path


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	test_root = Node2D.new()
	test_root.name = "YuanshiInsectNavigationSmokeTest"
	root.add_child(test_root)
	current_scene = test_root

	await _test_fast_insect_does_not_push_into_wall_when_path_is_empty()
	await _test_fast_insect_can_fallback_chase_with_clear_line()

	test_root.queue_free()
	await process_frame
	await physics_frame

	if failures.is_empty():
		print("YUANSHI_INSECT_NAVIGATION_SMOKE_TEST_OK")
		quit()
		return

	for failure in failures:
		push_error(failure)
	quit(1)


func _test_fast_insect_does_not_push_into_wall_when_path_is_empty() -> void:
	var player := _spawn_player(Vector2(48.0, 0.0))
	var wall := _spawn_wall(Vector2(24.0, 0.0), Vector2(8.0, 64.0))
	var pathfinder := FakePathfinder.new()
	test_root.add_child(pathfinder)
	await physics_frame

	var enemy := _spawn_fast_insect(Vector2.ZERO, player, pathfinder)
	enemy.path_refresh_time_left = 10.0
	var move_direction := enemy.call("_get_navigation_move_direction", 0.016) as Vector2
	_expect(pathfinder.requested_path, "Fast insect must request a path when its path is empty.")
	_expect(move_direction == Vector2.ZERO, "Fast insect must not directly push into a wall when no path is available.")
	_expect(enemy.path_refresh_time_left <= 0.08, "Fast insect must retry pathfinding soon when blocked.")

	enemy.queue_free()
	wall.queue_free()
	pathfinder.queue_free()
	player.queue_free()
	await physics_frame


func _test_fast_insect_can_fallback_chase_with_clear_line() -> void:
	var player := _spawn_player(Vector2(48.0, 0.0))
	var pathfinder := FakePathfinder.new()
	test_root.add_child(pathfinder)
	await physics_frame

	var enemy := _spawn_fast_insect(Vector2.ZERO, player, pathfinder)
	enemy.path_refresh_time_left = 10.0
	var move_direction := enemy.call("_get_navigation_move_direction", 0.016) as Vector2
	_expect(pathfinder.requested_path, "Fast insect must request a path when its path is empty.")
	_expect(move_direction.x > 0.0 and is_zero_approx(move_direction.y), "Fast insect must still chase directly when line of sight is clear.")

	enemy.queue_free()
	pathfinder.queue_free()
	player.queue_free()
	await physics_frame


func _spawn_player(position: Vector2) -> Player:
	var player := PLAYER_SCENE.instantiate() as Player
	test_root.add_child(player)
	player.global_position = position
	return player


func _spawn_fast_insect(position: Vector2, player: Player, pathfinder: Node) -> YuanshiInsect:
	var enemy := FAST_CONFIG.enemy_scene.instantiate() as YuanshiInsect
	test_root.add_child(enemy)
	enemy.global_position = position
	enemy.setup(FAST_CONFIG, player, pathfinder)
	return enemy


func _spawn_wall(position: Vector2, size: Vector2) -> StaticBody2D:
	var wall := StaticBody2D.new()
	wall.collision_layer = 1
	wall.collision_mask = 0
	var shape_node := CollisionShape2D.new()
	var rectangle := RectangleShape2D.new()
	rectangle.size = size
	shape_node.shape = rectangle
	wall.add_child(shape_node)
	test_root.add_child(wall)
	wall.global_position = position
	return wall


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
