extends Node
class_name GridPathfinder

@export var obstacle_tile_layer_path: NodePath = ^"../GroundTileMapLayer"
# 用于检测阻挡的碰撞层索引
@export var tile_physics_layer_index: int = 0
# 如果无法到达目标，是否允许返回部分路径（尽可能靠近目标）
@export var allow_partial_path: bool = true
# 搜索最近可行走格子的最大半径
@export var max_nearest_cell_search_radius: int = 6

# 内部使用的 AStarGrid2D 对象，用于 A* 寻路计算
var astar_grid: AStarGrid2D = AStarGrid2D.new()
# 引用的障碍物 TileMapLayer
var obstacle_tile_layer: TileMapLayer = null
# 寻路网格是否已经构建完成的标志
var is_built: bool = false


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
	astar_grid.region = used_rect
	astar_grid.cell_size = Vector2(obstacle_tile_layer.tile_set.tile_size)
	astar_grid.diagonal_mode = AStarGrid2D.DIAGONAL_MODE_NEVER
	astar_grid.default_compute_heuristic = AStarGrid2D.HEURISTIC_MANHATTAN
	astar_grid.default_estimate_heuristic = AStarGrid2D.HEURISTIC_MANHATTAN
	astar_grid.update()

	for y in range(used_rect.position.y, used_rect.end.y):
		for x in range(used_rect.position.x, used_rect.end.x):
			var cell := Vector2i(x, y)
			astar_grid.set_point_solid(cell, _is_cell_blocked(cell))

	is_built = true


# 获取两点之间的全局坐标路径数组
func get_global_path(from_global_position: Vector2, to_global_position: Vector2) -> PackedVector2Array:
	if not is_built:
		return PackedVector2Array()

	var from_cell := _get_closest_walkable_cell(_global_to_map(from_global_position))
	var to_cell := _get_closest_walkable_cell(_global_to_map(to_global_position))
	if from_cell == Vector2i.MAX or to_cell == Vector2i.MAX:
		return PackedVector2Array()

	var cell_path := astar_grid.get_id_path(from_cell, to_cell, allow_partial_path)
	var global_path := PackedVector2Array()
	for cell_index in range(1, cell_path.size()):
		var cell := cell_path[cell_index]
		global_path.append(_map_to_global(cell))

	if not global_path.is_empty():
		global_path[global_path.size() - 1] = to_global_position

	return global_path


# 将全局坐标转换为 TileMap 的网格坐标
func _global_to_map(global_position: Vector2) -> Vector2i:
	return obstacle_tile_layer.local_to_map(obstacle_tile_layer.to_local(global_position))


# 将 TileMap 的网格坐标转换为全局坐标
func _map_to_global(cell: Vector2i) -> Vector2:
	return obstacle_tile_layer.to_global(obstacle_tile_layer.map_to_local(cell))


# 以给定的网格坐标为中心，查找并返回最近的一个可行走网格坐标
func _get_closest_walkable_cell(origin_cell: Vector2i) -> Vector2i:
	if _is_cell_walkable(origin_cell):
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
				if not _is_cell_walkable(candidate):
					continue

				var distance := origin_cell.distance_squared_to(candidate)
				if distance < best_distance:
					best_distance = distance
					best_cell = candidate

		if best_cell != Vector2i.MAX:
			return best_cell

	return Vector2i.MAX


# 检查指定的网格单元是否在边界内并且未被阻挡（可行走）
func _is_cell_walkable(cell: Vector2i) -> bool:
	return astar_grid.is_in_boundsv(cell) and not astar_grid.is_point_solid(cell)


# 检查指定的网格单元是否被障碍物阻挡
func _is_cell_blocked(cell: Vector2i) -> bool:
	var tile_data := obstacle_tile_layer.get_cell_tile_data(cell)
	if tile_data == null:
		return true

	return tile_data.get_collision_polygons_count(tile_physics_layer_index) > 0
