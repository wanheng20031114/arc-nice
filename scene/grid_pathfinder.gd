extends Node
class_name GridPathfinder

@export var obstacle_tile_layer_path: NodePath = ^"../GroundTileMapLayer"
# 用于检测阻挡的碰撞层索引
@export var tile_physics_layer_index: int = 0
# 如果无法到达目标，是否允许返回部分路径（尽可能靠近目标）
@export var allow_partial_path: bool = true
# 搜索最近可行走格子的最大半径
@export var max_nearest_cell_search_radius: int = 6
# 每个物理帧允许的 A* 路径查询数量，用于避免大量敌人同帧刷新造成尖峰。
@export_range(1, 128, 1, "or_greater") var max_path_queries_per_physics_frame: int = 12
# 敌人体积寻路按实际碰撞外接尺寸计算；Godot 物理允许刚好接触但不重叠。
@export var agent_clearance_padding: float = 0.0

# 内部使用的 AStarGrid2D 对象，用于 A* 寻路计算
var astar_grid: AStarGrid2D = AStarGrid2D.new()
# 引用的障碍物 TileMapLayer
var obstacle_tile_layer: TileMapLayer = null
# 寻路网格是否已经构建完成的标志
var is_built: bool = false
var path_queries_used_this_frame: int = 0
var path_query_budget_frame: int = -1
var blocked_cells: Array[Vector2i] = []
var agent_grid_cache: Dictionary = {}
var region_local_rect: Rect2 = Rect2()


# 在节点进入场景树时调用，初始化寻路网格
func _ready() -> void:
	rebuild()


# 重新构建寻路网格数据
func rebuild() -> void:
	is_built = false
	obstacle_tile_layer = get_node_or_null(obstacle_tile_layer_path) as TileMapLayer
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
	blocked_cells.clear()
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

	is_built = true


# 获取两点之间的全局坐标路径数组
func get_global_path(
	from_global_position: Vector2,
	to_global_position: Vector2,
	agent_half_extents: Vector2 = Vector2.ZERO
) -> PackedVector2Array:
	if not is_built:
		return PackedVector2Array()

	var normalized_extents := _normalize_agent_half_extents(agent_half_extents)
	var path_grid := _get_or_create_agent_grid(normalized_extents)
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

	if not global_path.is_empty() and _is_global_position_walkable_for_agent(to_global_position, normalized_extents):
		global_path[global_path.size() - 1] = to_global_position

	return global_path


func try_get_global_path(
	from_global_position: Vector2,
	to_global_position: Vector2,
	agent_half_extents: Vector2 = Vector2.ZERO
) -> Variant:
	if not is_built:
		return PackedVector2Array()

	_refresh_path_query_budget_frame()
	if path_queries_used_this_frame >= maxi(max_path_queries_per_physics_frame, 1):
		return null

	path_queries_used_this_frame += 1
	return get_global_path(from_global_position, to_global_position, agent_half_extents)


func prewarm_agent_grid(agent_half_extents: Vector2) -> void:
	if not is_built:
		return
	var normalized_extents := _normalize_agent_half_extents(agent_half_extents)
	if normalized_extents == Vector2.ZERO:
		return
	_get_or_create_agent_grid(normalized_extents)


func _refresh_path_query_budget_frame() -> void:
	var current_frame := Engine.get_physics_frames()
	if current_frame == path_query_budget_frame:
		return
	path_query_budget_frame = current_frame
	path_queries_used_this_frame = 0


func _get_or_create_agent_grid(agent_half_extents: Vector2) -> AStarGrid2D:
	if agent_half_extents == Vector2.ZERO:
		return astar_grid

	var cache_key := "%d:%d" % [ceili(agent_half_extents.x), ceili(agent_half_extents.y)]
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
			agent_grid.set_point_solid(cell, _is_cell_blocked_for_agent(cell, agent_half_extents))

	agent_grid_cache[cache_key] = agent_grid
	return agent_grid


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


func _is_cell_blocked_for_agent(cell: Vector2i, agent_half_extents: Vector2) -> bool:
	if not astar_grid.is_in_boundsv(cell):
		return true
	if astar_grid.is_point_solid(cell):
		return true
	return not _is_local_position_walkable_for_agent(
		obstacle_tile_layer.map_to_local(cell),
		agent_half_extents
	)


func _is_global_position_walkable_for_agent(global_position: Vector2, agent_half_extents: Vector2) -> bool:
	var cell := _global_to_map(global_position)
	if not _is_cell_walkable(cell, _get_or_create_agent_grid(agent_half_extents)):
		return false
	if agent_half_extents == Vector2.ZERO:
		return true
	return _is_local_position_walkable_for_agent(obstacle_tile_layer.to_local(global_position), agent_half_extents)


func _is_local_position_walkable_for_agent(local_position: Vector2, agent_half_extents: Vector2) -> bool:
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
	for blocked_cell in blocked_cells:
		var blocked_center := obstacle_tile_layer.map_to_local(blocked_cell)
		var delta := (local_position - blocked_center).abs()
		if delta.x < padded_extents.x + half_cell.x and delta.y < padded_extents.y + half_cell.y:
			return false
	return true


# 检查指定的网格单元是否被障碍物阻挡
func _is_cell_blocked(cell: Vector2i) -> bool:
	var tile_data := obstacle_tile_layer.get_cell_tile_data(cell)
	if tile_data == null:
		return true

	return tile_data.get_collision_polygons_count(tile_physics_layer_index) > 0
