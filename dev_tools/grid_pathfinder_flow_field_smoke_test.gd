extends SceneTree

const GAME_SCENE := preload("res://scene/game.tscn")
const TEST_AGENT_HALF_EXTENTS := Vector2(8.0, 8.0)
const BLOCKED_AGENT_HALF_EXTENTS := Vector2(9.0, 9.0)

var failures: Array[String] = []


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	var game := GAME_SCENE.instantiate()
	root.add_child(game)
	current_scene = game
	await process_frame
	await physics_frame

	var pathfinder := game.get_node("GridPathfinder") as GridPathfinder
	_expect(pathfinder != null, "Game must provide GridPathfinder.")
	_expect(pathfinder != null and pathfinder.is_built, "GridPathfinder must be built.")
	if pathfinder == null or not pathfinder.is_built:
		_finish(game)
		return

	_test_flow_field_reuses_target_cache(pathfinder)
	_test_flow_field_recovers_from_blocked_for_agent_start(pathfinder)

	_finish(game)


func _test_flow_field_reuses_target_cache(pathfinder: GridPathfinder) -> void:
	var cell_pair := _find_reachable_cell_pair(pathfinder, TEST_AGENT_HALF_EXTENTS)
	_expect(cell_pair.size() == 2, "Map must provide two reachable cells for flow-field navigation.")
	if cell_pair.size() != 2:
		return

	var start_global := pathfinder.call("_map_to_global", cell_pair[0]) as Vector2
	var target_global := pathfinder.call("_map_to_global", cell_pair[1]) as Vector2
	var cache_size_before := pathfinder.flow_field_cache.size()
	var waypoint_result: Variant = pathfinder.get_flow_navigation_waypoint(
		start_global,
		target_global,
		TEST_AGENT_HALF_EXTENTS
	)
	_expect(waypoint_result != null, "Flow field must return a waypoint for a reachable agent.")
	if waypoint_result != null:
		var waypoint: Vector2 = waypoint_result
		_expect(not waypoint.is_equal_approx(start_global), "Flow field waypoint must advance away from the start position.")

	var cache_size_after_first := pathfinder.flow_field_cache.size()
	pathfinder.get_flow_navigation_waypoint(start_global, target_global, TEST_AGENT_HALF_EXTENTS)
	var cache_size_after_second := pathfinder.flow_field_cache.size()
	_expect(cache_size_after_first == cache_size_before + 1, "Flow field must build one shared cache entry for a new target and body size.")
	_expect(cache_size_after_second == cache_size_after_first, "Flow field must reuse the cached field for repeated queries.")


func _test_flow_field_recovers_from_blocked_for_agent_start(pathfinder: GridPathfinder) -> void:
	var point_walkable_cell := _find_point_walkable_but_agent_blocked_cell(pathfinder, BLOCKED_AGENT_HALF_EXTENTS)
	_expect(point_walkable_cell != Vector2i.MAX, "Map must contain a point-walkable cell that is blocked for a larger enemy body.")
	if point_walkable_cell == Vector2i.MAX:
		return

	var agent_grid := pathfinder.call("_get_or_create_agent_grid", BLOCKED_AGENT_HALF_EXTENTS) as AStarGrid2D
	var recovery_cell := pathfinder.call("_get_closest_walkable_cell", point_walkable_cell, agent_grid) as Vector2i
	_expect(recovery_cell != Vector2i.MAX and recovery_cell != point_walkable_cell, "Flow field test must find a distinct recovery cell.")
	if recovery_cell == Vector2i.MAX:
		return

	var blocked_start_global := pathfinder.call("_map_to_global", point_walkable_cell) as Vector2
	var recovery_global := pathfinder.call("_map_to_global", recovery_cell) as Vector2
	var waypoint_result: Variant = pathfinder.get_flow_navigation_waypoint(
		blocked_start_global,
		recovery_global,
		BLOCKED_AGENT_HALF_EXTENTS
	)
	_expect(waypoint_result != null, "Flow field must return a recovery waypoint when the start cell is too close to an obstacle.")
	if waypoint_result != null:
		var waypoint: Vector2 = waypoint_result
		_expect(waypoint.is_equal_approx(recovery_global), "Flow field must steer first toward the nearest reachable recovery cell.")


func _find_reachable_cell_pair(pathfinder: GridPathfinder, agent_half_extents: Vector2) -> Array[Vector2i]:
	var path_grid := pathfinder.call("_get_or_create_agent_grid", agent_half_extents) as AStarGrid2D
	var region := pathfinder.astar_grid.region
	for y in range(region.position.y, region.end.y):
		for x in range(region.position.x, region.end.x):
			var start_cell := Vector2i(x, y)
			if not bool(pathfinder.call("_is_cell_walkable", start_cell, path_grid)):
				continue
			for target_y in range(region.end.y - 1, region.position.y - 1, -1):
				for target_x in range(region.end.x - 1, region.position.x - 1, -1):
					var target_cell := Vector2i(target_x, target_y)
					if start_cell.distance_squared_to(target_cell) < 25:
						continue
					if not bool(pathfinder.call("_is_cell_walkable", target_cell, path_grid)):
						continue
					var start_global := pathfinder.call("_map_to_global", start_cell) as Vector2
					var target_global := pathfinder.call("_map_to_global", target_cell) as Vector2
					if not pathfinder.get_global_path(start_global, target_global, agent_half_extents).is_empty():
						return [start_cell, target_cell]
	return []


func _find_point_walkable_but_agent_blocked_cell(pathfinder: GridPathfinder, agent_half_extents: Vector2) -> Vector2i:
	var agent_grid := pathfinder.call("_get_or_create_agent_grid", agent_half_extents) as AStarGrid2D
	var region := pathfinder.astar_grid.region
	for y in range(region.position.y, region.end.y):
		for x in range(region.position.x, region.end.x):
			var cell := Vector2i(x, y)
			if not bool(pathfinder.call("_is_cell_walkable", cell)):
				continue
			if agent_grid != null and agent_grid.is_point_solid(cell):
				return cell
	return Vector2i.MAX


func _finish(game: Node) -> void:
	game.queue_free()
	await process_frame
	await physics_frame

	if failures.is_empty():
		print("GRID_PATHFINDER_FLOW_FIELD_SMOKE_TEST_OK")
		quit()
		return

	for failure in failures:
		push_error(failure)
	quit(1)


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
