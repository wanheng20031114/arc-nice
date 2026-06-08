extends Node
class_name GridPathfinder

@export var obstacle_tile_layer_path: NodePath = ^"../GroundTileMapLayer"
@export var tile_physics_layer_index: int = 0
@export var allow_partial_path: bool = true
@export var max_nearest_cell_search_radius: int = 6

var astar_grid: AStarGrid2D = AStarGrid2D.new()
var obstacle_tile_layer: TileMapLayer = null
var is_built: bool = false


func _ready() -> void:
	rebuild()


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


func _global_to_map(global_position: Vector2) -> Vector2i:
	return obstacle_tile_layer.local_to_map(obstacle_tile_layer.to_local(global_position))


func _map_to_global(cell: Vector2i) -> Vector2:
	return obstacle_tile_layer.to_global(obstacle_tile_layer.map_to_local(cell))


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


func _is_cell_walkable(cell: Vector2i) -> bool:
	return astar_grid.is_in_boundsv(cell) and not astar_grid.is_point_solid(cell)


func _is_cell_blocked(cell: Vector2i) -> bool:
	var tile_data := obstacle_tile_layer.get_cell_tile_data(cell)
	if tile_data == null:
		return true

	return tile_data.get_collision_polygons_count(tile_physics_layer_index) > 0
