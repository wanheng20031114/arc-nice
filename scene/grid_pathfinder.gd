extends Node
class_name GridPathfinder

const FLOW_CARDINAL_DIRECTIONS: Array[Vector2i] = [
	Vector2i.RIGHT,
	Vector2i.LEFT,
	Vector2i.DOWN,
	Vector2i.UP,
]
const DEFAULT_TRAVERSAL_TYPES := DualGridTilemap.TraversalType.LAND

@export var obstacle_tile_layer_path: NodePath = ^"../GroundTileMapLayer"
@export var terrain_map_path: NodePath
# 用于检测阻挡的碰撞层索引
@export var tile_physics_layer_index: int = 0
# 如果无法到达目标，是否允许返回部分路径（尽可能靠近目标）
@export var allow_partial_path: bool = true
# 搜索最近可行走格子的最大半径
@export var max_nearest_cell_search_radius: int = 6
# 每个物理帧允许的 A* 路径查询数量，用于避免大量敌人同帧刷新造成尖峰。
@export_range(1, 128, 1, "or_greater") var max_path_queries_per_physics_frame: int = 12
# 敌人体积寻路按实际碰撞外接尺寸计算；需要覆盖 CharacterBody2D.safe_margin，
# 否则刚好贴边的格子会被寻路视为可走，但 move_and_slide() 会在碰撞恢复中卡住。
@export var agent_clearance_padding: float = 0.1
# 每个物理帧最多新建多少张 flow field；已缓存的场会被所有敌人共享，不计入预算。
@export_range(1, 128, 1, "or_greater") var max_flow_field_builds_per_physics_frame: int = 4
# flow field 按“敌人体型 + 目标格”缓存，限制上限避免长局无限增长。
@export_range(1, 256, 1, "or_greater") var max_flow_field_cache_entries: int = 48

# 内部使用的 AStarGrid2D 对象，用于 A* 寻路计算
var astar_grid: AStarGrid2D = AStarGrid2D.new()
# 引用的障碍物 TileMapLayer
var obstacle_tile_layer: TileMapLayer = null
var terrain_map: DualGridTilemap = null
# 寻路网格是否已经构建完成的标志
var is_built: bool = false
var path_queries_used_this_frame: int = 0
var path_query_budget_frame: int = -1
var flow_field_builds_used_this_frame: int = 0
var flow_field_budget_frame: int = -1
var blocked_cells: Array[Vector2i] = []
var blocked_cells_by_traversal: Dictionary = {}
var agent_grid_cache: Dictionary = {}
var flow_field_cache: Dictionary = {}
var flow_field_cache_order: Array[String] = []
var region_local_rect: Rect2 = Rect2()
var terrain_rebuild_queued: bool = false


# 在节点进入场景树时调用，初始化寻路网格
func _ready() -> void:
	rebuild()


# 重新构建寻路网格数据
func rebuild() -> void:
	is_built = false
	obstacle_tile_layer = get_node_or_null(obstacle_tile_layer_path) as TileMapLayer
	_resolve_terrain_map()
	if obstacle_tile_layer == null:
		push_warning("GridPathfinder 缺少可用的 TileMapLayer。")
		return
	if obstacle_tile_layer.tile_set == null:
		push_warning("GridPathfinder 的 TileMapLayer 缺少 TileSet。")
		return

	var used_rect := obstacle_tile_layer.get_used_rect()
	if used_rect.size.x <= 0 or used_rect.size.y <= 0:
		push_warning("GridPathfinder 的 TileMapLayer 没有可用瓦片。")
		return

	astar_grid.clear()
	agent_grid_cache.clear()
	flow_field_cache.clear()
	flow_field_cache_order.clear()
	blocked_cells.clear()
	blocked_cells_by_traversal.clear()
	astar_grid.region = used_rect
	astar_grid.cell_size = Vector2(obstacle_tile_layer.tile_set.tile_size)
	astar_grid.diagonal_mode = AStarGrid2D.DIAGONAL_MODE_NEVER
	astar_grid.default_compute_heuristic = AStarGrid2D.HEURISTIC_MANHATTAN
	astar_grid.default_estimate_heuristic = AStarGrid2D.HEURISTIC_MANHATTAN
	astar_grid.update()
	_update_region_local_rect()

	for y in range(used_rect.position.y, used_rect.end.y):
		for x in range(used_rect.position.x, used_rect.end.x):
			var cell := Vector2i(x, y)
			var is_blocked := _is_cell_blocked(cell)
			astar_grid.set_point_solid(cell, is_blocked)
			if is_blocked:
				blocked_cells.append(cell)
	blocked_cells_by_traversal[DEFAULT_TRAVERSAL_TYPES] = blocked_cells.duplicate()

	is_built = true


func _resolve_terrain_map() -> void:
	var resolved_terrain_map: DualGridTilemap = null
	if not terrain_map_path.is_empty():
		resolved_terrain_map = get_node_or_null(terrain_map_path) as DualGridTilemap
	if terrain_map == resolved_terrain_map:
		return
	if terrain_map != null and terrain_map.terrain_changed.is_connected(_on_terrain_changed):
		terrain_map.terrain_changed.disconnect(_on_terrain_changed)
	terrain_map = resolved_terrain_map
	if terrain_map != null and not terrain_map.terrain_changed.is_connected(_on_terrain_changed):
		terrain_map.terrain_changed.connect(_on_terrain_changed)


func _on_terrain_changed(_cell: Vector2i, _previous_terrain: int, _current_terrain: int) -> void:
	if terrain_rebuild_queued:
		return
	terrain_rebuild_queued = true
	call_deferred("_rebuild_after_terrain_change")


func _rebuild_after_terrain_change() -> void:
	terrain_rebuild_queued = false
	rebuild()


# 获取两点之间的全局坐标路径数组
func get_global_path(
	from_global_position: Vector2,
	to_global_position: Vector2,
	agent_half_extents: Vector2 = Vector2.ZERO,
	traversal_types: int = DEFAULT_TRAVERSAL_TYPES
) -> PackedVector2Array:
	if not is_built:
		return PackedVector2Array()

	var normalized_extents := _normalize_agent_half_extents(agent_half_extents)
	var path_grid := _get_or_create_agent_grid(normalized_extents, traversal_types)
	var original_from_cell := _global_to_map(from_global_position)
	var from_cell := _get_closest_walkable_cell(original_from_cell, path_grid)
	var to_cell := _get_closest_walkable_cell(_global_to_map(to_global_position), path_grid)
	if from_cell == Vector2i.MAX or to_cell == Vector2i.MAX:
		return PackedVector2Array()

	var cell_path := path_grid.get_id_path(from_cell, to_cell, allow_partial_path)
	var global_path := PackedVector2Array()
	var first_path_index := 1 if from_cell == original_from_cell else 0
	for cell_index in range(first_path_index, cell_path.size()):
		var cell := cell_path[cell_index]
		global_path.append(_map_to_global(cell))

	if not global_path.is_empty() and _is_global_position_walkable_for_agent(
		to_global_position,
		normalized_extents,
		traversal_types
	):
		global_path[global_path.size() - 1] = to_global_position

	return global_path


func try_get_global_path(
	from_global_position: Vector2,
	to_global_position: Vector2,
	agent_half_extents: Vector2 = Vector2.ZERO,
	traversal_types: int = DEFAULT_TRAVERSAL_TYPES
) -> Variant:
	if not is_built:
		return PackedVector2Array()

	_refresh_path_query_budget_frame()
	if path_queries_used_this_frame >= maxi(max_path_queries_per_physics_frame, 1):
		return null

	path_queries_used_this_frame += 1
	return get_global_path(
		from_global_position,
		to_global_position,
		agent_half_extents,
		traversal_types
	)


func try_get_flow_navigation_waypoint(
	from_global_position: Vector2,
	to_global_position: Vector2,
	agent_half_extents: Vector2 = Vector2.ZERO,
	traversal_types: int = DEFAULT_TRAVERSAL_TYPES
) -> Variant:
	return _get_flow_navigation_waypoint(
		from_global_position,
		to_global_position,
		agent_half_extents,
		traversal_types,
		true
	)


func get_flow_navigation_waypoint(
	from_global_position: Vector2,
	to_global_position: Vector2,
	agent_half_extents: Vector2 = Vector2.ZERO,
	traversal_types: int = DEFAULT_TRAVERSAL_TYPES
) -> Variant:
	return _get_flow_navigation_waypoint(
		from_global_position,
		to_global_position,
		agent_half_extents,
		traversal_types,
		false
	)


func prewarm_agent_grid(
	agent_half_extents: Vector2,
	traversal_types: int = DEFAULT_TRAVERSAL_TYPES
) -> void:
	if not is_built:
		return
	var normalized_extents := _normalize_agent_half_extents(agent_half_extents)
	if normalized_extents == Vector2.ZERO:
		return
	_get_or_create_agent_grid(normalized_extents, traversal_types)


func prewarm_flow_navigation_target(
	to_global_position: Vector2,
	agent_half_extents: Vector2 = Vector2.ZERO,
	traversal_types: int = DEFAULT_TRAVERSAL_TYPES
) -> void:
	if not is_built:
		return

	var normalized_extents := _normalize_agent_half_extents(agent_half_extents)
	var path_grid := _get_or_create_agent_grid(normalized_extents, traversal_types)
	var target_cell := _get_closest_walkable_cell(_global_to_map(to_global_position), path_grid)
	if target_cell == Vector2i.MAX:
		return
	if not _get_cached_flow_field(target_cell, normalized_extents, traversal_types).is_empty():
		return

	_store_flow_field(
		target_cell,
		normalized_extents,
		traversal_types,
		_build_flow_field(target_cell, path_grid)
	)


func _refresh_path_query_budget_frame() -> void:
	var current_frame := Engine.get_physics_frames()
	if current_frame == path_query_budget_frame:
		return
	path_query_budget_frame = current_frame
	path_queries_used_this_frame = 0


func _refresh_flow_field_budget_frame() -> void:
	var current_frame := Engine.get_physics_frames()
	if current_frame == flow_field_budget_frame:
		return
	flow_field_budget_frame = current_frame
	flow_field_builds_used_this_frame = 0


func _get_or_create_agent_grid(
	agent_half_extents: Vector2,
	traversal_types: int = DEFAULT_TRAVERSAL_TYPES
) -> AStarGrid2D:
	if agent_half_extents == Vector2.ZERO and traversal_types == DEFAULT_TRAVERSAL_TYPES:
		return astar_grid

	var cache_key := _get_agent_grid_cache_key(agent_half_extents, traversal_types)
	var cached_grid := agent_grid_cache.get(cache_key) as AStarGrid2D
	if cached_grid != null:
		return cached_grid

	var agent_grid := AStarGrid2D.new()
	agent_grid.region = astar_grid.region
	agent_grid.cell_size = astar_grid.cell_size
	agent_grid.diagonal_mode = AStarGrid2D.DIAGONAL_MODE_NEVER
	agent_grid.default_compute_heuristic = AStarGrid2D.HEURISTIC_MANHATTAN
	agent_grid.default_estimate_heuristic = AStarGrid2D.HEURISTIC_MANHATTAN
	agent_grid.update()

	for y in range(agent_grid.region.position.y, agent_grid.region.end.y):
		for x in range(agent_grid.region.position.x, agent_grid.region.end.x):
			var cell := Vector2i(x, y)
			agent_grid.set_point_solid(
				cell,
				_is_cell_blocked_for_agent(cell, agent_half_extents, traversal_types)
			)

	agent_grid_cache[cache_key] = agent_grid
	return agent_grid


func _get_flow_navigation_waypoint(
	from_global_position: Vector2,
	to_global_position: Vector2,
	agent_half_extents: Vector2,
	traversal_types: int,
	uses_build_budget: bool
) -> Variant:
	if not is_built:
		return null

	var normalized_extents := _normalize_agent_half_extents(agent_half_extents)
	var path_grid := _get_or_create_agent_grid(normalized_extents, traversal_types)
	var target_cell := _get_closest_walkable_cell(_global_to_map(to_global_position), path_grid)
	if target_cell == Vector2i.MAX:
		return null

	var field := _get_cached_flow_field(target_cell, normalized_extents, traversal_types)
	if field.is_empty():
		if uses_build_budget:
			_refresh_flow_field_budget_frame()
			if flow_field_builds_used_this_frame >= maxi(max_flow_field_builds_per_physics_frame, 1):
				return null
			flow_field_builds_used_this_frame += 1
		field = _build_flow_field(target_cell, path_grid)
		_store_flow_field(target_cell, normalized_extents, traversal_types, field)

	var next_cells := field.get("next_cells", {}) as Dictionary
	if next_cells.is_empty():
		return null
	var distances := field.get("distances", {}) as Dictionary

	var from_cell := _global_to_map(from_global_position)
	if not _is_cell_walkable(from_cell, path_grid):
		var recovery_cell := _get_closest_flow_reachable_cell(from_cell, next_cells, distances, path_grid)
		if recovery_cell == Vector2i.MAX:
			return null
		return _map_to_global(recovery_cell)

	if not next_cells.has(from_cell):
		var reachable_cell := _get_closest_flow_reachable_cell(from_cell, next_cells, distances, path_grid)
		if reachable_cell == Vector2i.MAX:
			return null
		return _map_to_global(reachable_cell)

	var next_cell: Vector2i = next_cells.get(from_cell, Vector2i.MAX)
	if next_cell == Vector2i.MAX:
		return null
	if next_cell == from_cell:
		if _is_global_position_walkable_for_agent(
			to_global_position,
			normalized_extents,
			traversal_types
		):
			return to_global_position
		return _map_to_global(next_cell)

	return _map_to_global(next_cell)


func _build_flow_field(target_cell: Vector2i, path_grid: AStarGrid2D) -> Dictionary:
	var next_cells: Dictionary = {}
	var distances: Dictionary = {}
	var pending_cells: Array[Vector2i] = []
	var pending_cell_index := 0
	next_cells[target_cell] = target_cell
	distances[target_cell] = 0
	pending_cells.append(target_cell)

	while pending_cell_index < pending_cells.size():
		var current_cell := pending_cells[pending_cell_index]
		pending_cell_index += 1
		var current_distance := int(distances[current_cell])
		for direction in FLOW_CARDINAL_DIRECTIONS:
			var neighbor: Vector2i = current_cell + direction
			if distances.has(neighbor):
				continue
			if not _is_cell_walkable(neighbor, path_grid):
				continue
			distances[neighbor] = current_distance + 1
			next_cells[neighbor] = current_cell
			pending_cells.append(neighbor)

	return {
		"target_cell": target_cell,
		"next_cells": next_cells,
		"distances": distances,
	}


func _get_closest_flow_reachable_cell(
	origin_cell: Vector2i,
	next_cells: Dictionary,
	distances: Dictionary,
	path_grid: AStarGrid2D
) -> Vector2i:
	if next_cells.has(origin_cell):
		return origin_cell

	var search_radius := maxi(max_nearest_cell_search_radius, 0)
	var best_cell := Vector2i.MAX
	var best_flow_distance := INF
	var best_origin_distance := INF
	for radius in range(1, search_radius + 1):
		for y in range(origin_cell.y - radius, origin_cell.y + radius + 1):
			for x in range(origin_cell.x - radius, origin_cell.x + radius + 1):
				if x != origin_cell.x - radius and x != origin_cell.x + radius and y != origin_cell.y - radius and y != origin_cell.y + radius:
					continue

				var candidate := Vector2i(x, y)
				if not next_cells.has(candidate):
					continue
				if not _is_cell_walkable(candidate, path_grid):
					continue

				var flow_distance := float(distances.get(candidate, INF))
				var origin_distance := float(origin_cell.distance_squared_to(candidate))
				if (
					flow_distance < best_flow_distance
					or (
						is_equal_approx(flow_distance, best_flow_distance)
						and origin_distance < best_origin_distance
					)
				):
					best_flow_distance = flow_distance
					best_origin_distance = origin_distance
					best_cell = candidate

	return best_cell


func _get_cached_flow_field(
	target_cell: Vector2i,
	agent_half_extents: Vector2,
	traversal_types: int
) -> Dictionary:
	var cache_key := _get_flow_field_cache_key(
		target_cell,
		agent_half_extents,
		traversal_types
	)
	var field := flow_field_cache.get(cache_key, {}) as Dictionary
	if field.is_empty():
		return {}
	flow_field_cache_order.erase(cache_key)
	flow_field_cache_order.append(cache_key)
	return field


func _store_flow_field(
	target_cell: Vector2i,
	agent_half_extents: Vector2,
	traversal_types: int,
	field: Dictionary
) -> void:
	var cache_key := _get_flow_field_cache_key(
		target_cell,
		agent_half_extents,
		traversal_types
	)
	flow_field_cache[cache_key] = field
	flow_field_cache_order.erase(cache_key)
	flow_field_cache_order.append(cache_key)
	while flow_field_cache_order.size() > maxi(max_flow_field_cache_entries, 1):
		var oldest_key := flow_field_cache_order.pop_front() as String
		flow_field_cache.erase(oldest_key)


func _get_flow_field_cache_key(
	target_cell: Vector2i,
	agent_half_extents: Vector2,
	traversal_types: int
) -> String:
	return "%s:%d:%d" % [
		_get_agent_grid_cache_key(agent_half_extents, traversal_types),
		target_cell.x,
		target_cell.y,
	]


func _get_agent_grid_cache_key(agent_half_extents: Vector2, traversal_types: int) -> String:
	return "%s:%d" % [_get_agent_extents_cache_key(agent_half_extents), traversal_types]


func _get_agent_extents_cache_key(agent_half_extents: Vector2) -> String:
	return "%d:%d" % [ceili(agent_half_extents.x), ceili(agent_half_extents.y)]


func _normalize_agent_half_extents(agent_half_extents: Vector2) -> Vector2:
	if agent_half_extents.x <= 0.0 and agent_half_extents.y <= 0.0:
		return Vector2.ZERO
	return Vector2(maxf(ceili(agent_half_extents.x), 0.0), maxf(ceili(agent_half_extents.y), 0.0))


func _update_region_local_rect() -> void:
	var region := astar_grid.region
	var first_center := obstacle_tile_layer.map_to_local(region.position)
	var last_center := obstacle_tile_layer.map_to_local(region.end - Vector2i.ONE)
	var half_cell := astar_grid.cell_size * 0.5
	var min_position := Vector2(
		minf(first_center.x, last_center.x) - half_cell.x,
		minf(first_center.y, last_center.y) - half_cell.y
	)
	var max_position := Vector2(
		maxf(first_center.x, last_center.x) + half_cell.x,
		maxf(first_center.y, last_center.y) + half_cell.y
	)
	region_local_rect = Rect2(min_position, max_position - min_position)


# 将全局坐标转换为 TileMap 的网格坐标
func _global_to_map(global_position: Vector2) -> Vector2i:
	return obstacle_tile_layer.local_to_map(obstacle_tile_layer.to_local(global_position))


# 将 TileMap 的网格坐标转换为全局坐标
func _map_to_global(cell: Vector2i) -> Vector2:
	return obstacle_tile_layer.to_global(obstacle_tile_layer.map_to_local(cell))


# 以给定的网格坐标为中心，查找并返回最近的一个可行走网格坐标
func _get_closest_walkable_cell(origin_cell: Vector2i, path_grid: AStarGrid2D = null) -> Vector2i:
	if _is_cell_walkable(origin_cell, path_grid):
		return origin_cell

	var search_radius := maxi(max_nearest_cell_search_radius, 0)
	for radius in range(1, search_radius + 1):
		var best_cell := Vector2i.MAX
		var best_distance := INF
		for y in range(origin_cell.y - radius, origin_cell.y + radius + 1):
			for x in range(origin_cell.x - radius, origin_cell.x + radius + 1):
				if x != origin_cell.x - radius and x != origin_cell.x + radius and y != origin_cell.y - radius and y != origin_cell.y + radius:
					continue

				var candidate := Vector2i(x, y)
				if not _is_cell_walkable(candidate, path_grid):
					continue

				var distance := origin_cell.distance_squared_to(candidate)
				if distance < best_distance:
					best_distance = distance
					best_cell = candidate

		if best_cell != Vector2i.MAX:
			return best_cell

	return Vector2i.MAX


# 检查指定的网格单元是否在边界内并且未被阻挡（可行走）
func _is_cell_walkable(cell: Vector2i, path_grid: AStarGrid2D = null) -> bool:
	var grid := path_grid if path_grid != null else astar_grid
	return grid.is_in_boundsv(cell) and not grid.is_point_solid(cell)


func _is_cell_blocked_for_agent(
	cell: Vector2i,
	agent_half_extents: Vector2,
	traversal_types: int
) -> bool:
	if not astar_grid.is_in_boundsv(cell):
		return true
	if _is_cell_blocked(cell, traversal_types):
		return true
	return not _is_local_position_walkable_for_agent(
		obstacle_tile_layer.map_to_local(cell),
		agent_half_extents,
		traversal_types
	)


func _is_global_position_walkable_for_agent(
	global_position: Vector2,
	agent_half_extents: Vector2,
	traversal_types: int = DEFAULT_TRAVERSAL_TYPES
) -> bool:
	var cell := _global_to_map(global_position)
	if not _is_cell_walkable(
		cell,
		_get_or_create_agent_grid(agent_half_extents, traversal_types)
	):
		return false
	if agent_half_extents == Vector2.ZERO:
		return true
	return _is_local_position_walkable_for_agent(
		obstacle_tile_layer.to_local(global_position),
		agent_half_extents,
		traversal_types
	)


func _is_local_position_walkable_for_agent(
	local_position: Vector2,
	agent_half_extents: Vector2,
	traversal_types: int = DEFAULT_TRAVERSAL_TYPES
) -> bool:
	var padded_extents := agent_half_extents + Vector2.ONE * maxf(agent_clearance_padding, 0.0)
	if local_position.x - padded_extents.x < region_local_rect.position.x:
		return false
	if local_position.y - padded_extents.y < region_local_rect.position.y:
		return false
	if local_position.x + padded_extents.x > region_local_rect.end.x:
		return false
	if local_position.y + padded_extents.y > region_local_rect.end.y:
		return false

	var half_cell := astar_grid.cell_size * 0.5
	for blocked_cell in _get_blocked_cells_for_traversal(traversal_types):
		var blocked_center := obstacle_tile_layer.map_to_local(blocked_cell)
		var delta := (local_position - blocked_center).abs()
		if delta.x < padded_extents.x + half_cell.x and delta.y < padded_extents.y + half_cell.y:
			return false
	return true


# 检查指定的网格单元是否被障碍物或当前移动能力不可通过的地形阻挡。
func _is_cell_blocked(
	cell: Vector2i,
	traversal_types: int = DEFAULT_TRAVERSAL_TYPES
) -> bool:
	if _is_obstacle_cell_blocked(cell):
		return true
	if terrain_map == null:
		return false
	return not terrain_map.is_world_position_traversable(
		_map_to_global(cell),
		traversal_types
	)


func _is_obstacle_cell_blocked(cell: Vector2i) -> bool:
	var tile_data := obstacle_tile_layer.get_cell_tile_data(cell)
	if tile_data == null:
		return true

	return tile_data.get_collision_polygons_count(tile_physics_layer_index) > 0


func _get_blocked_cells_for_traversal(traversal_types: int) -> Array[Vector2i]:
	if blocked_cells_by_traversal.has(traversal_types):
		var cached_cells: Array[Vector2i] = blocked_cells_by_traversal[traversal_types]
		return cached_cells

	var traversal_blocked_cells: Array[Vector2i] = []
	for y in range(astar_grid.region.position.y, astar_grid.region.end.y):
		for x in range(astar_grid.region.position.x, astar_grid.region.end.x):
			var cell := Vector2i(x, y)
			if _is_cell_blocked(cell, traversal_types):
				traversal_blocked_cells.append(cell)
	blocked_cells_by_traversal[traversal_types] = traversal_blocked_cells
	return traversal_blocked_cells
