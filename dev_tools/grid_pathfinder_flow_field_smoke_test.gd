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
	_test_complete_path_same_cell(pathfinder)

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
	var recovery_pair := _find_adjacent_agent_recovery_pair(pathfinder, BLOCKED_AGENT_HALF_EXTENTS)
	_expect(recovery_pair.size() == 2, "Map must contain an agent-blocked cell with one safe cardinal recovery cell.")
	if recovery_pair.size() != 2:
		return
	var point_walkable_cell := recovery_pair[0]
	var recovery_cell := recovery_pair[1]

	var blocked_start_global := pathfinder.call("_map_to_global", point_walkable_cell) as Vector2
	var recovery_global := pathfinder.call("_map_to_global", recovery_cell) as Vector2
	var waypoint_result: Variant = pathfinder.get_flow_navigation_waypoint(
		blocked_start_global,
		recovery_global,
		BLOCKED_AGENT_HALF_EXTENTS
	)
	_expect(waypoint_result != null, "Flow field must return a waypoint for one-cardinal-cell recovery.")
	if waypoint_result != null:
		var waypoint: Vector2 = waypoint_result
		_expect(waypoint.is_equal_approx(recovery_global), "Flow field recovery must never skip beyond its adjacent safe cell.")

	var distant_pair := _find_distant_agent_recovery_pair(pathfinder, BLOCKED_AGENT_HALF_EXTENTS)
	if distant_pair.size() == 2:
		var distant_start_global := pathfinder.call("_map_to_global", distant_pair[0]) as Vector2
		var distant_target_global := pathfinder.call("_map_to_global", distant_pair[1]) as Vector2
		var distant_result: Variant = pathfinder.get_flow_navigation_waypoint(
			distant_start_global,
			distant_target_global,
			BLOCKED_AGENT_HALF_EXTENTS
		)
		var distant_step := pathfinder.get_safe_navigation_step(
			distant_start_global,
			distant_target_global,
			BLOCKED_AGENT_HALF_EXTENTS
		)
		var first_step: Vector2i = distant_step.get("next_cell", Vector2i.MAX)
		var first_delta := first_step - distant_pair[0]
		_expect(
			distant_result != null
			and int(distant_step.get("status", GridPathfinder.NavigationStepStatus.UNREACHABLE))
				== GridPathfinder.NavigationStepStatus.READY
			and bool(distant_step.get("used_start_recovery", false)),
			"A physically open multi-cell clearance band must expose bounded recovery."
		)
		_expect(
			distant_result != null
			and first_step != Vector2i.MAX
			and maxi(absi(first_delta.x), absi(first_delta.y)) == 1
			and bool(pathfinder.call(
				"_is_raw_recovery_transition_safe",
				distant_pair[0],
				first_delta,
				GridPathfinder.DEFAULT_TRAVERSAL_TYPES
			))
			and (distant_result as Vector2).is_equal_approx(
				pathfinder.call("_map_to_global", first_step) as Vector2
			),
			"Multi-cell recovery must return only one adjacent no-corner-cutting waypoint."
		)


func _test_complete_path_same_cell(pathfinder: GridPathfinder) -> void:
	var path_grid := pathfinder.call("_get_or_create_agent_grid", TEST_AGENT_HALF_EXTENTS) as AStarGrid2D
	var region := pathfinder.astar_grid.region
	for cell_y in range(region.position.y, region.end.y):
		for cell_x in range(region.position.x, region.end.x):
			var cell := Vector2i(cell_x, cell_y)
			if not bool(pathfinder.call("_is_cell_walkable", cell, path_grid)):
				continue
			var global_position := pathfinder.call("_map_to_global", cell) as Vector2
			var complete_path := pathfinder.get_complete_global_path(
				global_position,
				global_position,
				TEST_AGENT_HALF_EXTENTS
			)
			_expect(
				complete_path.size() == 1,
				"A complete same-cell path must contain exactly its reachable endpoint."
			)
			if complete_path.size() == 1:
				_expect(
					complete_path[0].is_equal_approx(global_position),
					"A complete same-cell path must preserve the exact reachable target."
				)
			return
	_expect(false, "Map must provide a walkable cell for same-cell complete-path testing.")


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


func _find_adjacent_agent_recovery_pair(
	pathfinder: GridPathfinder,
	agent_half_extents: Vector2
) -> Array[Vector2i]:
	var agent_grid := pathfinder.call("_get_or_create_agent_grid", agent_half_extents) as AStarGrid2D
	var region := pathfinder.astar_grid.region
	for y in range(region.position.y, region.end.y):
		for x in range(region.position.x, region.end.x):
			var cell := Vector2i(x, y)
			if not bool(pathfinder.call("_is_cell_walkable", cell)):
				continue
			if agent_grid == null or not agent_grid.is_point_solid(cell):
				continue
			for direction in GridPathfinder.FLOW_CARDINAL_DIRECTIONS:
				var recovery_cell := cell + direction
				if bool(pathfinder.call("_is_cell_walkable", recovery_cell, agent_grid)):
					return [cell, recovery_cell]
	return []


func _find_distant_agent_recovery_pair(
	pathfinder: GridPathfinder,
	agent_half_extents: Vector2
) -> Array[Vector2i]:
	var agent_grid := pathfinder.call("_get_or_create_agent_grid", agent_half_extents) as AStarGrid2D
	var region := pathfinder.astar_grid.region
	for y in range(region.position.y, region.end.y):
		for x in range(region.position.x, region.end.x):
			var cell := Vector2i(x, y)
			if not bool(pathfinder.call("_is_cell_walkable", cell)):
				continue
			if agent_grid == null or not agent_grid.is_point_solid(cell):
				continue
			var recovery_cell := pathfinder.call("_get_closest_walkable_cell", cell, agent_grid) as Vector2i
			if recovery_cell == Vector2i.MAX:
				continue
			var manhattan_distance := absi(cell.x - recovery_cell.x) + absi(cell.y - recovery_cell.y)
			if manhattan_distance > 1:
				return [cell, recovery_cell]
	return []


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
