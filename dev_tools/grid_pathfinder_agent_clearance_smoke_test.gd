extends SceneTree

const GAME_SCENE := preload("res://scene/game.tscn")
const TEST_AGENT_HALF_EXTENTS := Vector2(9.0, 9.0)

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
	_expect(
		pathfinder.agent_grid_cache.size() > 0,
		"Game startup must prewarm enemy agent clearance grids."
	)

	var adjacent_cell := _find_walkable_cell_adjacent_to_blocked(pathfinder)
	_expect(adjacent_cell != Vector2i.MAX, "Map must contain a walkable cell adjacent to a blocked tile.")
	if adjacent_cell != Vector2i.MAX:
		_expect(
			bool(pathfinder.call("_is_cell_walkable", adjacent_cell)),
			"Point pathfinding must treat the adjacent cell as walkable."
		)
		var agent_grid := pathfinder.call("_get_or_create_agent_grid", TEST_AGENT_HALF_EXTENTS) as AStarGrid2D
		_expect(agent_grid != null, "GridPathfinder must create an agent clearance grid.")
		if agent_grid != null:
			_expect(
				agent_grid.is_point_solid(adjacent_cell),
				"Agent clearance grid must block cells where the enemy body would overlap an obstacle."
			)
			var cached_agent_grid := pathfinder.call("_get_or_create_agent_grid", TEST_AGENT_HALF_EXTENTS) as AStarGrid2D
			_expect(cached_agent_grid == agent_grid, "Agent clearance grids must be cached by body size.")
			var nearest_agent_cell := pathfinder.call("_get_closest_walkable_cell", adjacent_cell, agent_grid) as Vector2i
			_expect(
				nearest_agent_cell != Vector2i.MAX and nearest_agent_cell != adjacent_cell,
				"Agent pathfinding must find a recovery cell when the current point cell is too close to an obstacle."
			)
			if nearest_agent_cell != Vector2i.MAX:
				var from_global := pathfinder.call("_map_to_global", adjacent_cell) as Vector2
				var nearest_global := pathfinder.call("_map_to_global", nearest_agent_cell) as Vector2
				var recovery_path := pathfinder.get_global_path(from_global, nearest_global, TEST_AGENT_HALF_EXTENTS)
				_expect(not recovery_path.is_empty(), "Agent pathfinding must include the nearest recovery cell when starting from a blocked-for-agent cell.")
				if not recovery_path.is_empty():
					_expect(
						recovery_path[0].is_equal_approx(nearest_global),
						"Agent pathfinding must not skip the recovery start cell when the original start cell is blocked for the enemy body."
					)

	_finish(game)


func _find_walkable_cell_adjacent_to_blocked(pathfinder: GridPathfinder) -> Vector2i:
	var region := pathfinder.astar_grid.region
	var directions := [
		Vector2i.RIGHT,
		Vector2i.LEFT,
		Vector2i.DOWN,
		Vector2i.UP,
	]
	for y in range(region.position.y, region.end.y):
		for x in range(region.position.x, region.end.x):
			var cell := Vector2i(x, y)
			if not bool(pathfinder.call("_is_cell_walkable", cell)):
				continue
			for direction in directions:
				var neighbor: Vector2i = cell + (direction as Vector2i)
				if not pathfinder.astar_grid.is_in_boundsv(neighbor):
					continue
				if not bool(pathfinder.call("_is_cell_walkable", neighbor)):
					return cell
	return Vector2i.MAX


func _finish(game: Node) -> void:
	game.queue_free()
	await process_frame
	await physics_frame

	if failures.is_empty():
		print("GRID_PATHFINDER_AGENT_CLEARANCE_SMOKE_TEST_OK")
		quit()
		return

	for failure in failures:
		push_error(failure)
	quit(1)


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
