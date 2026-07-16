extends SceneTree

const TOWER_SCENE := preload("res://scene/game_tower_defense.tscn")
const LAND := DualGridTilemap.TraversalType.LAND
const WATER := DualGridTilemap.TraversalType.WATER
const AGENT_EXTENTS := Vector2(8.0, 4.0)

var failures: Array[String] = []


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	var game := TOWER_SCENE.instantiate() as GameTowerDefense
	game.auto_start_waves = false
	root.add_child(game)
	current_scene = game
	await process_frame
	await physics_frame

	var pathfinder := game.get_node_or_null("GridPathfinder") as GridPathfinder
	_expect(pathfinder != null and pathfinder.is_built, "GridPathfinder must build.")
	if pathfinder == null or not pathfinder.is_built:
		_finish(game)
		return

	_verify_raw_snapshot_matches_live_map(pathfinder)
	_verify_generation_bound_agent_profile(pathfinder)
	_verify_integral_segment_certificate_is_conservative(pathfinder)
	await _verify_terrain_change_invalidates_immediately(pathfinder)
	_finish(game)


func _verify_raw_snapshot_matches_live_map(pathfinder: GridPathfinder) -> void:
	var region := pathfinder.astar_grid.region
	_expect(
		pathfinder.raw_navigation_snapshot_generation
			== pathfinder.navigation_generation,
		"Published raw snapshot must belong to the active generation."
	)
	_expect(
		pathfinder.raw_navigation_snapshot_region == region,
		"Published raw snapshot must cover the base grid."
	)
	_expect(
		pathfinder.raw_navigation_cell_snapshot.size()
			== region.size.x * region.size.y,
		"Raw snapshot must store exactly one byte per base cell."
	)

	var traversal_masks: Array[int] = [LAND, WATER, LAND | WATER]
	for y in range(region.position.y, region.end.y):
		for x in range(region.position.x, region.end.x):
			var cell := Vector2i(x, y)
			var obstacle_blocked := bool(pathfinder.call(
				"_is_obstacle_cell_blocked_live",
				cell
			))
			var live_traversal := int(pathfinder.call(
				"_get_live_terrain_traversal_flags",
				cell
			))
			for traversal_mask in traversal_masks:
				var expected := (
					obstacle_blocked
					or (
						pathfinder.terrain_map != null
						and (live_traversal & traversal_mask) == 0
					)
				)
				var actual := bool(pathfinder.call(
					"_is_cell_blocked",
					cell,
					traversal_mask
				))
				if actual == expected:
					continue
				_expect(
					false,
					"Raw snapshot mismatch at %s for traversal mask %d."
					% [cell, traversal_mask]
				)
				return


func _verify_integral_segment_certificate_is_conservative(
	pathfinder: GridPathfinder
) -> void:
	var normalized_extents := pathfinder.call(
		"_normalize_agent_half_extents",
		AGENT_EXTENTS
	) as Vector2
	var path_grid := pathfinder.call(
		"_get_or_create_agent_grid",
		normalized_extents,
		LAND
	) as AStarGrid2D
	_expect(path_grid != null, "Agent grid must build for certificate verification.")
	if path_grid == null:
		return

	var region := path_grid.region
	var step := Vector2i(
		maxi(region.size.x / 18, 1),
		maxi(region.size.y / 18, 1)
	)
	var motions: Array[Vector2] = [
		Vector2(4.0, 0.0),
		Vector2(-4.0, 0.0),
		Vector2(0.0, 4.0),
		Vector2(0.0, -4.0),
		Vector2(5.0, 5.0),
		Vector2(-5.0, 5.0),
	]
	var certified_count := 0
	for y in range(region.position.y, region.end.y, step.y):
		for x in range(region.position.x, region.end.x, step.x):
			var from_global := pathfinder.call(
				"_map_to_global",
				Vector2i(x, y)
			) as Vector2
			for motion in motions:
				var to_global := from_global + motion
				var certified := bool(pathfinder.call(
					"_can_certify_navigation_segment_from_integral",
					from_global,
					to_global,
					normalized_extents,
					LAND
				))
				if not certified:
					continue
				certified_count += 1
				if _legacy_segment_walkable(
					pathfinder,
					from_global,
					to_global,
					normalized_extents,
					LAND,
					path_grid
				):
					continue
				_expect(false, "Integral certificate produced an unsafe segment.")
				return
	_expect(certified_count > 0, "Open terrain must produce integral certificates.")


func _verify_generation_bound_agent_profile(pathfinder: GridPathfinder) -> void:
	pathfinder.call("_get_or_create_agent_grid", AGENT_EXTENTS, LAND)
	var first_profile := pathfinder.try_get_agent_navigation_profile(
		AGENT_EXTENTS,
		LAND
	)
	var second_profile := pathfinder.try_get_agent_navigation_profile(
		AGENT_EXTENTS,
		LAND
	)
	_expect(first_profile != null, "A warmed agent profile must resolve.")
	_expect(
		first_profile == second_profile,
		"Identical profile requests must share one generation-bound handle."
	)
	_expect(
		pathfinder.is_agent_navigation_profile_valid(first_profile),
		"A resolved profile must be valid for the active generation."
	)
	if first_profile == null:
		return
	var open_cell := _find_profile_open_cell(first_profile.path_grid)
	_expect(open_cell != Vector2i.MAX, "Agent profile must retain an open cell.")
	if open_cell == Vector2i.MAX:
		return
	var open_position := pathfinder.call("_map_to_global", open_cell) as Vector2
	_expect(
		pathfinder.try_is_navigation_open_plain_with_profile(
			open_position,
			open_position,
			first_profile
		) == true,
		"Profile open-plain API must use its bound integral snapshot."
	)
	_expect(
		pathfinder.try_is_navigation_segment_walkable_with_profile(
			open_position,
			open_position,
			first_profile
		) == true,
		"Profile segment API must use its bound grid and integral snapshot."
	)


func _find_profile_open_cell(path_grid: AStarGrid2D) -> Vector2i:
	if path_grid == null:
		return Vector2i.MAX
	var region := path_grid.region
	for y in range(region.position.y + 1, region.end.y - 1):
		for x in range(region.position.x + 1, region.end.x - 1):
			var cell := Vector2i(x, y)
			if not path_grid.is_point_solid(cell):
				return cell
	return Vector2i.MAX


func _legacy_segment_walkable(
	pathfinder: GridPathfinder,
	from_global: Vector2,
	to_global: Vector2,
	normalized_extents: Vector2,
	traversal_types: int,
	path_grid: AStarGrid2D
) -> bool:
	var from_local := pathfinder.obstacle_tile_layer.to_local(from_global)
	var to_local := pathfinder.obstacle_tile_layer.to_local(to_global)
	var minimum_cell_size := minf(
		absf(pathfinder.astar_grid.cell_size.x),
		absf(pathfinder.astar_grid.cell_size.y)
	)
	var sample_count := maxi(
		ceili(from_local.distance_to(to_local) / maxf(minimum_cell_size * 0.5, 1.0)),
		1
	)
	for sample_index in range(sample_count + 1):
		var weight := float(sample_index) / float(sample_count)
		var sample_local := from_local.lerp(to_local, weight)
		var sample_cell := pathfinder.obstacle_tile_layer.local_to_map(sample_local)
		if not bool(pathfinder.call("_is_cell_walkable", sample_cell, path_grid)):
			return false
		if (
			normalized_extents != Vector2.ZERO
			and not bool(pathfinder.call(
				"_is_local_position_walkable_for_agent",
				sample_local,
				normalized_extents,
				traversal_types
			))
		):
			return false
	return true


func _verify_terrain_change_invalidates_immediately(
	pathfinder: GridPathfinder
) -> void:
	var stable_generation := pathfinder.navigation_generation
	pathfinder.call(
		"_on_terrain_changed",
		Vector2i.ZERO,
		DualGridTilemap.TerrainType.GRASS,
		DualGridTilemap.TerrainType.DIRT
	)
	_expect(
		pathfinder.navigation_generation == stable_generation
		and pathfinder.is_built,
		"LAND-to-LAND edits must not invalidate navigation."
	)

	pathfinder.call(
		"_on_terrain_changed",
		Vector2i.ZERO,
		DualGridTilemap.TerrainType.DIRT,
		DualGridTilemap.TerrainType.WATER
	)
	_expect(
		pathfinder.navigation_generation == stable_generation + 1,
		"The first LAND/WATER edit must invalidate generation synchronously."
	)
	_expect(
		not pathfinder.is_built and pathfinder.terrain_rebuild_queued,
		"Queries must remain deferred until the coalesced rebuild publishes."
	)
	_expect(
		pathfinder.raw_navigation_snapshot_generation
			!= pathfinder.navigation_generation,
		"A dirty generation must reject the old raw snapshot."
	)
	var stale_profile: GridPathfinder.AgentNavigationProfile = null
	if not pathfinder.agent_navigation_profile_cache.is_empty():
		stale_profile = (
			pathfinder.agent_navigation_profile_cache.values()[0]
			as GridPathfinder.AgentNavigationProfile
		)
	_expect(
		stale_profile == null
		or not pathfinder.is_agent_navigation_profile_valid(stale_profile),
		"Terrain invalidation must reject previously resolved profile handles."
	)

	var deadline := Time.get_ticks_msec() + 5000
	while not pathfinder.is_built and Time.get_ticks_msec() < deadline:
		await process_frame
	_expect(pathfinder.is_built, "Deferred terrain rebuild must complete.")
	_expect(
		pathfinder.navigation_generation == stable_generation + 1,
		"Deferred publication must not increment the already-invalidated generation twice."
	)
	_expect(
		pathfinder.raw_navigation_snapshot_generation
			== pathfinder.navigation_generation,
		"Deferred rebuild must atomically publish the new snapshot generation."
	)

	# An explicit rebuild can legally happen while a terrain callback is queued
	# (editor tooling and tests both do this). It must consume the old request;
	# a newer terrain edit in the same frame must still invalidate the just-built
	# snapshot, and either queued callback may publish it exactly once.
	var explicit_race_generation := pathfinder.navigation_generation
	pathfinder.call(
		"_on_terrain_changed",
		Vector2i.ZERO,
		DualGridTilemap.TerrainType.DIRT,
		DualGridTilemap.TerrainType.WATER
	)
	_expect(
		pathfinder.navigation_generation == explicit_race_generation + 1
		and pathfinder.terrain_rebuild_queued,
		"A terrain edit before an explicit rebuild must invalidate immediately."
	)
	pathfinder.rebuild()
	_expect(
		pathfinder.navigation_generation == explicit_race_generation + 2
		and pathfinder.is_built
		and not pathfinder.terrain_rebuild_queued,
		"An explicit rebuild must consume the older deferred terrain request."
	)
	pathfinder.call(
		"_on_terrain_changed",
		Vector2i.ZERO,
		DualGridTilemap.TerrainType.WATER,
		DualGridTilemap.TerrainType.DIRT
	)
	var newest_invalidated_generation := pathfinder.navigation_generation
	_expect(
		newest_invalidated_generation == explicit_race_generation + 3
		and not pathfinder.is_built
		and pathfinder.terrain_rebuild_queued,
		"A newer terrain edit must invalidate an explicit publication in the same frame."
	)
	deadline = Time.get_ticks_msec() + 5000
	while not pathfinder.is_built and Time.get_ticks_msec() < deadline:
		await process_frame
	_expect(
		pathfinder.is_built
		and pathfinder.navigation_generation == newest_invalidated_generation
		and pathfinder.raw_navigation_snapshot_generation
			== newest_invalidated_generation,
		"Queued callbacks must publish only the newest invalidated generation."
	)


func _finish(game: Node) -> void:
	if game != null:
		game.queue_free()
	await process_frame
	await physics_frame
	if failures.is_empty():
		print("GRID_PATHFINDER_RAW_SNAPSHOT_SMOKE_TEST_OK")
		quit()
		return
	for failure in failures:
		push_error(failure)
	quit(1)


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
