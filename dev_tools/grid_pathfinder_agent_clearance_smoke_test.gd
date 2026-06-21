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
