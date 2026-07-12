extends SceneTree

const PLAYER_SCENE := preload("res://scene/player/weishidaier/player_weishidaier.tscn")
const FAST_CONFIG := preload("res://resources/config/enemies/yuanshi_insect_fast.tres")

var failures: Array[String] = []
var test_root: Node2D


class FakePathfinder:
	extends Node

	var is_built := true
	var requested_safe_step := false
	var safe_step: Dictionary = {
		"status": GridPathfinder.NavigationStepStatus.UNREACHABLE,
	}

	func try_get_safe_navigation_step(
		_from_global_position: Vector2,
		_to_global_position: Vector2,
		_agent_half_extents: Vector2 = Vector2.ZERO,
		_traversal_types: int = DualGridTilemap.TraversalType.LAND
	) -> Dictionary:
		requested_safe_step = true
		return safe_step.duplicate()


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	test_root = Node2D.new()
	test_root.name = "YuanshiInsectNavigationSmokeTest"
	root.add_child(test_root)
	current_scene = test_root

	await _test_near_clear_player_uses_direct_sweep()
	await _test_near_blocked_player_falls_back_to_flow()
	await _test_unreachable_never_direct_fallbacks()
	await _test_ready_step_moves_toward_waypoint()
	await _test_blocked_primary_axis_uses_safe_secondary_axis()
	await _test_blocked_only_axis_stops()
	await _test_deferred_without_cache_stops()
	await _test_deferred_reuses_only_shape_safe_cached_direction()

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


func _test_near_clear_player_uses_direct_sweep() -> void:
	var player := _spawn_player(Vector2(64.0, 32.0))
	var pathfinder := _spawn_pathfinder()
	var enemy := _spawn_fast_insect(Vector2.ZERO, player, pathfinder)
	enemy.navigation_update_interval_frames = 1
	await physics_frame
	var move_direction := enemy.call("_get_navigation_move_direction", 0.016) as Vector2
	_expect(
		not pathfinder.requested_safe_step,
		"A nearby player with a clear full-body segment must bypass flow navigation."
	)
	_expect(
		move_direction.is_equal_approx(Vector2(64.0, 32.0).normalized()),
		"The moving-target fast path must preserve a true normalized diagonal."
	)
	await _free_fixture([enemy, pathfinder, player])


func _test_near_blocked_player_falls_back_to_flow() -> void:
	var player := _spawn_player(Vector2(64.0, 0.0))
	var wall := _spawn_wall(Vector2(14.0, 0.0), Vector2(16.0, 64.0))
	var pathfinder := _spawn_pathfinder()
	pathfinder.safe_step = _ready_step(Vector2(0.0, 32.0))
	var enemy := _spawn_fast_insect(Vector2.ZERO, player, pathfinder)
	enemy.navigation_update_interval_frames = 1
	await physics_frame
	var move_direction := enemy.call("_get_navigation_move_direction", 0.016) as Vector2
	_expect(
		pathfinder.requested_safe_step,
		"A wall-blocked nearby player must fall back to complete flow navigation."
	)
	_expect(move_direction == Vector2.DOWN, "The blocked direct tier must consume the safe flow step.")
	await _free_fixture([enemy, wall, pathfinder, player])


func _test_unreachable_never_direct_fallbacks() -> void:
	var player := _spawn_player(Vector2(248.0, 0.0))
	var pathfinder := _spawn_pathfinder()
	var enemy := _spawn_fast_insect(Vector2.ZERO, player, pathfinder)
	enemy.navigation_update_interval_frames = 1
	await physics_frame
	var move_direction := enemy.call("_get_navigation_move_direction", 0.016) as Vector2
	_expect(pathfinder.requested_safe_step, "Fast insect must request the unified safe-step API.")
	_expect(
		move_direction == Vector2.ZERO,
		"UNREACHABLE must stop when a distant target requires flow navigation."
	)
	await _free_fixture([enemy, pathfinder, player])


func _test_ready_step_moves_toward_waypoint() -> void:
	var player := _spawn_player(Vector2(264.0, 0.0))
	var pathfinder := _spawn_pathfinder()
	pathfinder.safe_step = _ready_step(Vector2(32.0, 0.0))
	var enemy := _spawn_fast_insect(Vector2.ZERO, player, pathfinder)
	enemy.navigation_update_interval_frames = 1
	var move_direction := enemy.call("_get_navigation_move_direction", 0.016) as Vector2
	_expect(move_direction == Vector2.RIGHT, "READY must move toward its safe waypoint.")
	await _free_fixture([enemy, pathfinder, player])


func _test_blocked_primary_axis_uses_safe_secondary_axis() -> void:
	var player := _spawn_player(Vector2(264.0, 32.0))
	var wall := _spawn_wall(Vector2(14.0, 0.0), Vector2(16.0, 64.0))
	var pathfinder := _spawn_pathfinder()
	pathfinder.safe_step = _ready_step(Vector2(32.0, 32.0))
	var enemy := _spawn_fast_insect(Vector2.ZERO, player, pathfinder)
	enemy.navigation_update_interval_frames = 1
	await physics_frame
	var move_direction := enemy.call("_get_navigation_move_direction", 0.016) as Vector2
	_expect(
		move_direction == Vector2.DOWN,
		"Safe-step consumer must use the unblocked secondary axis instead of entering a wall."
	)
	await _free_fixture([enemy, wall, pathfinder, player])


func _test_blocked_only_axis_stops() -> void:
	var player := _spawn_player(Vector2(264.0, 0.0))
	var wall := _spawn_wall(Vector2(14.0, 0.0), Vector2(16.0, 64.0))
	var pathfinder := _spawn_pathfinder()
	pathfinder.safe_step = _ready_step(Vector2(32.0, 0.0))
	var enemy := _spawn_fast_insect(Vector2.ZERO, player, pathfinder)
	enemy.navigation_update_interval_frames = 1
	await physics_frame
	var move_direction := enemy.call("_get_navigation_move_direction", 0.016) as Vector2
	_expect(move_direction == Vector2.ZERO, "Consumer must stop when the only step axis is physically blocked.")
	await _free_fixture([enemy, wall, pathfinder, player])


func _test_deferred_without_cache_stops() -> void:
	var player := _spawn_player(Vector2(264.0, 0.0))
	var pathfinder := _spawn_pathfinder()
	pathfinder.safe_step = {"status": GridPathfinder.NavigationStepStatus.DEFERRED}
	var enemy := _spawn_fast_insect(Vector2.ZERO, player, pathfinder)
	enemy.navigation_update_interval_frames = 1
	var move_direction := enemy.call("_get_navigation_move_direction", 0.016) as Vector2
	_expect(move_direction == Vector2.ZERO, "DEFERRED without a verified cached step must stop.")
	await _free_fixture([enemy, pathfinder, player])


func _test_deferred_reuses_only_shape_safe_cached_direction() -> void:
	var player := _spawn_player(Vector2(264.0, 264.0))
	var pathfinder := _spawn_pathfinder()
	pathfinder.safe_step = {"status": GridPathfinder.NavigationStepStatus.DEFERRED}
	var enemy := _spawn_fast_insect(Vector2.ZERO, player, pathfinder)
	enemy.navigation_update_interval_frames = 1
	enemy.cached_navigation_move_direction = Vector2.DOWN
	var move_direction := enemy.call("_get_navigation_move_direction", 0.016) as Vector2
	_expect(move_direction == Vector2.DOWN, "DEFERRED may reuse the last shape-safe verified direction.")
	var wall := _spawn_wall(Vector2(0.0, 7.5), Vector2(64.0, 8.0))
	await physics_frame
	enemy.cached_navigation_move_direction = Vector2.DOWN
	move_direction = enemy.call("_get_navigation_move_direction", 0.016) as Vector2
	_expect(move_direction == Vector2.ZERO, "DEFERRED must discard a cached direction once physics blocks it.")
	await _free_fixture([enemy, wall, pathfinder, player])


func _ready_step(waypoint: Vector2) -> Dictionary:
	return {
		"status": GridPathfinder.NavigationStepStatus.READY,
		"waypoint": waypoint,
		"is_complete_route": true,
	}


func _spawn_pathfinder() -> FakePathfinder:
	var pathfinder := FakePathfinder.new()
	test_root.add_child(pathfinder)
	return pathfinder


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
	enemy.set_physics_process(false)
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


func _free_fixture(nodes: Array) -> void:
	for node in nodes:
		if node != null and is_instance_valid(node):
			node.queue_free()
	await physics_frame


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
