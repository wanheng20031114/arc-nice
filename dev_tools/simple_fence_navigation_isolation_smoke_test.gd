extends SceneTree

const TOWER_SCENE := preload("res://scene/game_modes/tower_defense/tower_defense_game.tscn")
const REAL_FENCE_COUNT := 1000
const NAVIGATION_QUERY_COUNT := 300

var failures: Array[String] = []


func _init() -> void:
	call_deferred(&"_run")


func _run() -> void:
	var game := TOWER_SCENE.instantiate() as TowerDefenseGame
	game.auto_start_waves = false
	root.add_child(game)
	current_scene = game
	await process_frame
	await physics_frame
	game.set_physics_process(false)

	var pathfinder := game.grid_pathfinder as GridPathfinder
	var plant_system := game.plant_system as PlantSystem
	_expect(
		pathfinder != null and pathfinder.is_built and plant_system != null,
		"导航隔离测试必须启动生产塔防场景、已发布GridPathfinder与PlantSystem。"
	)
	if pathfinder == null or not pathfinder.is_built or plant_system == null:
		await _finish(game)
		return

	var route_pairs := _build_route_pairs(game, pathfinder)
	_expect(
		route_pairs.size() == NAVIGATION_QUERY_COUNT,
		"导航隔离测试必须构造恰好300组真实开放格路径查询。"
	)
	_prewarm_navigation_caches(pathfinder, route_pairs)
	_expect(
		pathfinder.flow_field_cache.size() > 0
		and pathfinder.agent_grid_cache.size() > 0
		and pathfinder.agent_navigation_profile_cache.size() > 0,
		"导航隔离基线必须实际预热flow、agent grid与agent profile缓存，禁止以空缓存比较伪通过。"
	)
	var baseline_routes := _navigation_signatures(pathfinder, route_pairs)
	_expect(
		_count_ready_navigation_steps(pathfinder, route_pairs) > 0,
		"300条导航结果中必须实际存在READY路线，禁止仅比较未执行的查询。"
	)
	var baseline_state := _navigation_state_signature(pathfinder)
	var baseline_retarget := _retarget_signature(game)

	plant_system.placement_area = Rect2i(-20_000, -20_000, 40_000, 40_000)
	var fences: Array[CardinalConnectedPlant] = []
	for index in range(REAL_FENCE_COUNT):
		var cell := Vector2i(1000 + (index % 50), 1000 + (index / 50))
		var fence := plant_system.spawn_multiplayer_replica(
			&"simple_fence",
			cell,
			null,
			50_000 + index,
			500,
			500,
			0,
			false
		) as CardinalConnectedPlant
		if fence != null:
			fences.append(fence)
		var refresh_metrics := (
			plant_system.get_last_cardinal_connection_refresh_metrics()
		)
		_expect(
			int(refresh_metrics.get("cells_visited", -1)) <= 5,
			"第%d个真实围栏放置只能访问局部五格，metrics=%s。"
			% [index, refresh_metrics]
		)
	_expect(
		fences.size() == REAL_FENCE_COUNT,
		"导航隔离测试必须成功生成1000个带真实静态碰撞体的围栏。"
	)
	var placed_routes := _navigation_signatures(pathfinder, route_pairs)
	var placed_state := _navigation_state_signature(pathfinder)
	var placed_retarget := _retarget_signature(game)
	_expect(
		placed_state == baseline_state
		and placed_routes == baseline_routes,
		"放置1000个真实围栏后，navigation generation、原始阻挡快照、agent/flow cache与300条导航结果必须逐项不变。"
	)
	_expect(
		placed_retarget == baseline_retarget,
		"CONTACT_ONLY围栏放置不得触发全敌人重索敌预算。baseline=%s placed=%s"
		% [baseline_retarget, placed_retarget]
	)

	for index in range(REAL_FENCE_COUNT):
		_expect(
			plant_system.remove_plant_by_net_id(
				50_000 + index,
				PlantDefense.RemovalMode.SILENT
			),
			"第%d个权威围栏必须能按net id静默移除。" % index
		)
		var refresh_metrics := (
			plant_system.get_last_cardinal_connection_refresh_metrics()
		)
		_expect(
			int(refresh_metrics.get("cells_visited", -1)) <= 5,
			"第%d个真实围栏移除只能访问局部五格，metrics=%s。"
			% [index, refresh_metrics]
		)
	var removed_routes := _navigation_signatures(pathfinder, route_pairs)
	var removed_state := _navigation_state_signature(pathfinder)
	var removed_retarget := _retarget_signature(game)
	_expect(
		removed_state == baseline_state
		and removed_routes == baseline_routes,
		"移除1000个真实围栏后，导航代数、快照、缓存及300条结果仍必须与零围栏基线完全相同。"
	)
	_expect(
		removed_retarget == baseline_retarget,
		"CONTACT_ONLY围栏移除不得执行全敌人引用扫描或请求重索敌。baseline=%s removed=%s"
		% [baseline_retarget, removed_retarget]
	)
	_expect(
		pathfinder.raw_navigation_snapshot_generation
		== pathfinder.navigation_generation,
		"围栏批量放置/移除后，原始导航快照仍必须属于当前有效generation。"
	)
	print(
		"SIMPLE_FENCE_NAVIGATION_ISOLATION fences=%d queries=%d generation=%d flow_cache=%d"
		% [
			REAL_FENCE_COUNT,
			NAVIGATION_QUERY_COUNT,
			pathfinder.navigation_generation,
			pathfinder.flow_field_cache.size(),
		]
	)
	await _finish(game)


func _build_route_pairs(
	game: TowerDefenseGame,
	pathfinder: GridPathfinder
) -> Array[Dictionary]:
	var open_cells: Array[Vector2i] = []
	var region := pathfinder.astar_grid.region
	for y in range(region.position.y, region.end.y):
		for x in range(region.position.x, region.end.x):
			var cell := Vector2i(x, y)
			if not pathfinder.astar_grid.is_point_solid(cell):
				open_cells.append(cell)
	var pairs: Array[Dictionary] = []
	if open_cells.size() < 2:
		return pairs
	var tile_map := game.ground_tile_map_layer as TileMapLayer
	for index in range(NAVIGATION_QUERY_COUNT):
		var from_cell := open_cells[(index * 17) % open_cells.size()]
		var to_cell := open_cells[
			(index * 43 + open_cells.size() / 2) % open_cells.size()
		]
		pairs.append({
			"from": tile_map.to_global(tile_map.map_to_local(from_cell)),
			"to": tile_map.to_global(tile_map.map_to_local(to_cell)),
		})
	return pairs


func _navigation_signatures(
	pathfinder: GridPathfinder,
	pairs: Array[Dictionary]
) -> PackedInt64Array:
	var signatures := PackedInt64Array()
	for pair in pairs:
		var from_position: Vector2 = pair["from"]
		var to_position: Vector2 = pair["to"]
		var step := pathfinder.try_get_safe_navigation_step(
			from_position,
			to_position,
			Vector2(8.0, 4.0),
			DualGridTilemap.TraversalType.LAND
		)
		signatures.append(hash([
			step.get("status"),
			step.get("waypoint"),
			step.get("from_cell"),
			step.get("resolved_from_cell"),
			step.get("target_cell"),
			step.get("resolved_target_cell"),
			step.get("next_cell"),
			step.get("used_start_recovery"),
			step.get("is_complete_route"),
			step.get("remaining_cell_distance"),
		]))
	return signatures


func _prewarm_navigation_caches(
	pathfinder: GridPathfinder,
	pairs: Array[Dictionary]
) -> void:
	for index in range(mini(8, pairs.size())):
		pathfinder.prewarm_flow_navigation_target(
			pairs[index]["to"],
			Vector2(8.0, 4.0),
			DualGridTilemap.TraversalType.LAND
		)
		pathfinder.try_get_agent_navigation_profile(
			Vector2(8.0, 4.0),
			DualGridTilemap.TraversalType.LAND
		)


func _count_ready_navigation_steps(
	pathfinder: GridPathfinder,
	pairs: Array[Dictionary]
) -> int:
	var ready_count := 0
	for pair in pairs:
		var step := pathfinder.try_get_safe_navigation_step(
			pair["from"],
			pair["to"],
			Vector2(8.0, 4.0),
			DualGridTilemap.TraversalType.LAND
		)
		if int(step.get("status", -1)) == GridPathfinder.NavigationStepStatus.READY:
			ready_count += 1
	return ready_count


func _navigation_state_signature(pathfinder: GridPathfinder) -> Dictionary:
	return {
		"generation": pathfinder.navigation_generation,
		"raw_generation": pathfinder.raw_navigation_snapshot_generation,
		"raw_region": pathfinder.raw_navigation_snapshot_region,
		"raw_cells": pathfinder.raw_navigation_cell_snapshot.duplicate(),
		"raw_obstacles": pathfinder.raw_obstacle_integral_snapshot.duplicate(),
		"raw_obstacle_stride": pathfinder.raw_obstacle_integral_stride,
		"agent_grid_keys": _sorted_dictionary_keys(pathfinder.agent_grid_cache),
		"agent_integral_keys": _sorted_dictionary_keys(
			pathfinder.agent_open_plain_integral_cache
		),
		"agent_profile_keys": _sorted_dictionary_keys(
			pathfinder.agent_navigation_profile_cache
		),
		"flow_keys": _sorted_dictionary_keys(pathfinder.flow_field_cache),
		"flow_value_hashes": _sorted_dictionary_value_hashes(
			pathfinder.flow_field_cache
		),
		"flow_order": pathfinder.flow_field_cache_order.duplicate(),
		"recovery_keys": _sorted_dictionary_keys(
			pathfinder.flow_recovery_route_cache
		),
		"recovery_order": pathfinder.flow_recovery_cache_order.duplicate(),
		"runtime_flow_builds_completed": pathfinder.runtime_flow_builds_completed,
		"runtime_flow_builds_cancelled": pathfinder.runtime_flow_builds_cancelled,
	}


func _retarget_signature(game: TowerDefenseGame) -> Dictionary:
	return {
		"time_left": game.enemy_retarget_time_left,
		"sweep_remaining": game.enemy_retarget_sweep_remaining,
		"cursor": game.enemy_retarget_cursor,
	}


func _sorted_dictionary_keys(dictionary: Dictionary) -> PackedStringArray:
	var keys := PackedStringArray()
	for key in dictionary:
		keys.append(str(key))
	keys.sort()
	return keys


func _sorted_dictionary_value_hashes(dictionary: Dictionary) -> PackedInt64Array:
	var keys := _sorted_dictionary_keys(dictionary)
	var values := PackedInt64Array()
	for key in keys:
		values.append(hash(dictionary.get(key)))
	return values


func _finish(game: TowerDefenseGame) -> void:
	game.queue_free()
	for _cleanup_frame in range(8):
		await process_frame
	if failures.is_empty():
		print("SIMPLE_FENCE_NAVIGATION_ISOLATION_SMOKE_TEST_OK")
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	quit(1)


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
