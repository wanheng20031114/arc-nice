extends SceneTree

const TOWER_SCENE := preload("res://scene/game_tower_defense.tscn")
const SYNC_PROFILE_EXTENTS := Vector2(15.0, 2.0)
const STAGED_PROFILE_EXTENTS := Vector2(3.0, 15.0)
const RUNTIME_PROFILE_EXTENTS := Vector2(14.0, 11.0)
const LAND_TRAVERSAL := DualGridTilemap.TraversalType.LAND
const MANUAL_EXPANSIONS_PER_FRAME := 16
const MAX_MANUAL_BUILD_FRAMES := 2000

var failures: Array[String] = []


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	var game := TOWER_SCENE.instantiate() as GameTowerDefense
	if game == null:
		_expect(false, "Tower-defense scene must instantiate GameTowerDefense.")
		_finish(null)
		return
	game.auto_start_waves = false
	root.add_child(game)
	current_scene = game
	await process_frame
	await physics_frame

	var pathfinder := game.get_node_or_null("GridPathfinder") as GridPathfinder
	_expect(
		pathfinder != null and pathfinder.is_built,
		"Tower defense must provide a built GridPathfinder."
	)
	if pathfinder == null or not pathfinder.is_built:
		_finish(game)
		return

	_test_default_open_and_blocked_rectangles(pathfinder)
	await _test_synchronous_and_loading_profile_snapshots(pathfinder)
	_test_rebuild_invalidates_profile_snapshots(pathfinder)
	_test_runtime_profile_build_is_staged_and_atomic(pathfinder)

	_finish(game)


func _test_default_open_and_blocked_rectangles(pathfinder: GridPathfinder) -> void:
	var default_key := pathfinder.call(
		"_get_agent_grid_cache_key",
		Vector2.ZERO,
		LAND_TRAVERSAL
	) as String
	_expect(
		pathfinder.agent_open_plain_integral_cache.has(default_key),
		"The default navigation grid must publish an open-plain snapshot during rebuild."
	)

	var open_pair := _find_open_rectangle(pathfinder, pathfinder.astar_grid)
	_expect(
		open_pair.size() == 2,
		"The tower map must provide a multi-cell open rectangle."
	)
	if open_pair.size() == 2:
		var open_result: Variant = pathfinder.try_is_navigation_open_plain(
			pathfinder.call("_map_to_global", open_pair[0]) as Vector2,
			pathfinder.call("_map_to_global", open_pair[1]) as Vector2
		)
		_expect(open_result == true, "A rectangle containing no solid cells must be certified open.")

	var blocked_pair := _find_walkable_pair_with_solid_between(
		pathfinder,
		pathfinder.astar_grid
	)
	_expect(
		blocked_pair.size() == 2,
		"The tower map must provide two walkable endpoints with a solid cell between them."
	)
	if blocked_pair.size() == 2:
		var blocked_result: Variant = pathfinder.try_is_navigation_open_plain(
			pathfinder.call("_map_to_global", blocked_pair[0]) as Vector2,
			pathfinder.call("_map_to_global", blocked_pair[1]) as Vector2
		)
		_expect(blocked_result == false, "A rectangle crossing a solid cell must not be certified open.")

	var outside_position := pathfinder.call(
		"_map_to_global",
		pathfinder.astar_grid.region.position - Vector2i.ONE
	) as Vector2
	var inside_position := pathfinder.call(
		"_map_to_global",
		pathfinder.astar_grid.region.position
	) as Vector2
	_expect(
		pathfinder.try_is_navigation_open_plain(outside_position, inside_position) == false,
		"An endpoint outside the navigation region must return false."
	)


func _test_synchronous_and_loading_profile_snapshots(pathfinder: GridPathfinder) -> void:
	var sync_key := pathfinder.call(
		"_get_agent_grid_cache_key",
		SYNC_PROFILE_EXTENTS,
		LAND_TRAVERSAL
	) as String
	pathfinder.agent_grid_cache.erase(sync_key)
	pathfinder.agent_open_plain_integral_cache.erase(sync_key)
	var first_grid := pathfinder.call(
		"_get_or_create_agent_grid",
		SYNC_PROFILE_EXTENTS,
		LAND_TRAVERSAL
	) as AStarGrid2D
	var first_snapshot: Variant = pathfinder.agent_open_plain_integral_cache.get(sync_key)
	_expect(first_grid != null, "Synchronous profile prewarm must create an agent grid.")
	_expect(first_snapshot != null, "Synchronous profile prewarm must create its integral snapshot.")
	var second_grid := pathfinder.call(
		"_get_or_create_agent_grid",
		SYNC_PROFILE_EXTENTS,
		LAND_TRAVERSAL
	) as AStarGrid2D
	var second_snapshot: Variant = pathfinder.agent_open_plain_integral_cache.get(sync_key)
	_expect(second_grid == first_grid, "Identical agent profiles must share one cached grid.")
	_expect(second_snapshot == first_snapshot, "Identical agent profiles must share one integral snapshot.")

	var staged_key := pathfinder.call(
		"_get_agent_grid_cache_key",
		STAGED_PROFILE_EXTENTS,
		LAND_TRAVERSAL
	) as String
	pathfinder.agent_grid_cache.erase(staged_key)
	pathfinder.agent_open_plain_integral_cache.erase(staged_key)
	await pathfinder.prewarm_agent_grid_staged(
		STAGED_PROFILE_EXTENTS,
		LAND_TRAVERSAL,
		8
	)
	_expect(
		pathfinder.agent_grid_cache.has(staged_key),
		"Loading prewarm must publish the staged agent grid."
	)
	_expect(
		pathfinder.agent_open_plain_integral_cache.has(staged_key),
		"Loading prewarm must publish the matching integral snapshot."
	)


func _test_rebuild_invalidates_profile_snapshots(pathfinder: GridPathfinder) -> void:
	var default_key := pathfinder.call(
		"_get_agent_grid_cache_key",
		Vector2.ZERO,
		LAND_TRAVERSAL
	) as String
	var sync_key := pathfinder.call(
		"_get_agent_grid_cache_key",
		SYNC_PROFILE_EXTENTS,
		LAND_TRAVERSAL
	) as String
	var previous_generation := pathfinder.navigation_generation
	var previous_default_snapshot: Variant = (
		pathfinder.agent_open_plain_integral_cache.get(default_key)
	)
	pathfinder.rebuild()
	_expect(
		pathfinder.navigation_generation == previous_generation + 1,
		"Rebuild must advance the navigation generation."
	)
	_expect(
		not pathfinder.agent_open_plain_integral_cache.has(sync_key),
		"Rebuild must invalidate non-default profile snapshots."
	)
	var rebuilt_default_snapshot: Variant = (
		pathfinder.agent_open_plain_integral_cache.get(default_key)
	)
	_expect(
		rebuilt_default_snapshot != null,
		"Rebuild must synchronously publish a new default snapshot."
	)
	_expect(
		rebuilt_default_snapshot != previous_default_snapshot,
		"Rebuild must not reuse a snapshot from the previous generation."
	)


func _test_runtime_profile_build_is_staged_and_atomic(pathfinder: GridPathfinder) -> void:
	var runtime_key := pathfinder.call(
		"_get_agent_grid_cache_key",
		RUNTIME_PROFILE_EXTENTS,
		LAND_TRAVERSAL
	) as String
	pathfinder.agent_grid_cache.erase(runtime_key)
	pathfinder.agent_open_plain_integral_cache.erase(runtime_key)
	pathfinder.runtime_agent_grid_build_jobs.erase(runtime_key)
	pathfinder.runtime_agent_grid_build_order.erase(runtime_key)
	pathfinder.runtime_navigation_max_expansions_per_frame = MANUAL_EXPANSIONS_PER_FRAME
	pathfinder.runtime_navigation_time_budget_usec = 1000
	pathfinder.set_process(false)

	var sample_cell := _find_any_walkable_cell(pathfinder.astar_grid)
	_expect(sample_cell != Vector2i.MAX, "The default map must provide a walkable sample cell.")
	if sample_cell == Vector2i.MAX:
		return
	var sample_position := pathfinder.call("_map_to_global", sample_cell) as Vector2
	var cold_result: Variant = pathfinder.try_is_navigation_open_plain(
		sample_position,
		sample_position,
		RUNTIME_PROFILE_EXTENTS,
		LAND_TRAVERSAL
	)
	_expect(cold_result == null, "A cold runtime profile must return null instead of building synchronously.")
	_expect(
		pathfinder.runtime_agent_grid_build_jobs.size() == 1,
		"A cold runtime profile must enqueue exactly one shared build job."
	)
	_expect(
		not pathfinder.agent_grid_cache.has(runtime_key)
		and not pathfinder.agent_open_plain_integral_cache.has(runtime_key),
		"A cold runtime profile must not publish either half before staged work runs."
	)

	pathfinder.call("_advance_runtime_navigation_jobs")
	var job := pathfinder.runtime_agent_grid_build_jobs.get(runtime_key) as Object
	_expect(job != null, "One budget slice must not synchronously finish the cold profile.")
	_expect(
		not pathfinder.agent_grid_cache.has(runtime_key)
		and not pathfinder.agent_open_plain_integral_cache.has(runtime_key),
		"The runtime grid and snapshot must remain hidden during the first budget slice."
	)
	_expect(
		pathfinder.try_is_navigation_open_plain(
			sample_position,
			sample_position,
			RUNTIME_PROFILE_EXTENTS,
			LAND_TRAVERSAL
		) == null,
		"Repeated cold queries must share the pending job and remain deferred."
	)
	_expect(
		pathfinder.runtime_agent_grid_build_jobs.size() == 1,
		"Repeated cold queries must not duplicate the profile build."
	)

	var saw_integral_stage := false
	var manual_frames := 0
	while pathfinder.runtime_agent_grid_build_jobs.has(runtime_key):
		job = pathfinder.runtime_agent_grid_build_jobs.get(runtime_key) as Object
		if job != null and bool(job.get("grid_cells_completed")):
			saw_integral_stage = true
			_expect(
				not pathfinder.agent_grid_cache.has(runtime_key)
				and not pathfinder.agent_open_plain_integral_cache.has(runtime_key),
				"Completing grid cells must not publish before the integral snapshot is complete."
			)
		pathfinder.call("_advance_runtime_navigation_jobs")
		manual_frames += 1
		if manual_frames >= MAX_MANUAL_BUILD_FRAMES:
			break
	_expect(saw_integral_stage, "The runtime job must expose a separately budgeted integral stage.")
	_expect(
		manual_frames < MAX_MANUAL_BUILD_FRAMES,
		"The staged runtime profile must complete within the manual deadline."
	)
	_expect(
		pathfinder.agent_grid_cache.has(runtime_key)
		and pathfinder.agent_open_plain_integral_cache.has(runtime_key),
		"The complete runtime grid and snapshot must publish together."
	)

	var runtime_grid := pathfinder.agent_grid_cache.get(runtime_key) as AStarGrid2D
	var runtime_walkable_cell := _find_any_walkable_cell(runtime_grid)
	_expect(runtime_walkable_cell != Vector2i.MAX, "The runtime profile must retain walkable cells.")
	if runtime_walkable_cell != Vector2i.MAX:
		var runtime_position := pathfinder.call(
			"_map_to_global",
			runtime_walkable_cell
		) as Vector2
		_expect(
			pathfinder.try_is_navigation_open_plain(
				runtime_position,
				runtime_position,
				RUNTIME_PROFILE_EXTENTS,
				LAND_TRAVERSAL
			) == true,
			"A published runtime profile must answer open-plain queries without rebuilding."
		)


func _find_open_rectangle(
	_pathfinder: GridPathfinder,
	path_grid: AStarGrid2D
) -> Array[Vector2i]:
	var region := path_grid.region
	for y in range(region.position.y, region.end.y - 2):
		for x in range(region.position.x, region.end.x - 2):
			var minimum_cell := Vector2i(x, y)
			var maximum_cell := Vector2i(x + 2, y + 2)
			if _rect_is_walkable(path_grid, minimum_cell, maximum_cell):
				return [minimum_cell, maximum_cell]
	return []


func _find_walkable_pair_with_solid_between(
	_pathfinder: GridPathfinder,
	path_grid: AStarGrid2D
) -> Array[Vector2i]:
	var region := path_grid.region
	for y in range(region.position.y, region.end.y):
		for start_x in range(region.position.x, region.end.x - 2):
			var start_cell := Vector2i(start_x, y)
			if path_grid.is_point_solid(start_cell):
				continue
			var saw_solid := false
			for end_x in range(start_x + 1, mini(start_x + 13, region.end.x)):
				var candidate := Vector2i(end_x, y)
				if path_grid.is_point_solid(candidate):
					saw_solid = true
					continue
				if saw_solid:
					return [start_cell, candidate]
	for x in range(region.position.x, region.end.x):
		for start_y in range(region.position.y, region.end.y - 2):
			var start_cell := Vector2i(x, start_y)
			if path_grid.is_point_solid(start_cell):
				continue
			var saw_solid := false
			for end_y in range(start_y + 1, mini(start_y + 13, region.end.y)):
				var candidate := Vector2i(x, end_y)
				if path_grid.is_point_solid(candidate):
					saw_solid = true
					continue
				if saw_solid:
					return [start_cell, candidate]
	return []


func _rect_is_walkable(
	path_grid: AStarGrid2D,
	minimum_cell: Vector2i,
	maximum_cell: Vector2i
) -> bool:
	for y in range(minimum_cell.y, maximum_cell.y + 1):
		for x in range(minimum_cell.x, maximum_cell.x + 1):
			if path_grid.is_point_solid(Vector2i(x, y)):
				return false
	return true


func _find_any_walkable_cell(path_grid: AStarGrid2D) -> Vector2i:
	if path_grid == null:
		return Vector2i.MAX
	var region := path_grid.region
	for y in range(region.position.y, region.end.y):
		for x in range(region.position.x, region.end.x):
			var cell := Vector2i(x, y)
			if not path_grid.is_point_solid(cell):
				return cell
	return Vector2i.MAX


func _finish(game: Node) -> void:
	if game != null:
		game.queue_free()
	await process_frame
	await physics_frame
	if failures.is_empty():
		print("GRID_PATHFINDER_OPEN_PLAIN_SMOKE_TEST_OK")
		quit()
		return
	for failure in failures:
		push_error(failure)
	quit(1)


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
