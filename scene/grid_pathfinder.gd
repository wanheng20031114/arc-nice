extends Node
class_name GridPathfinder

const FLOW_CARDINAL_DIRECTIONS: Array[Vector2i] = [
	Vector2i.RIGHT,
	Vector2i.LEFT,
	Vector2i.DOWN,
	Vector2i.UP,
]
const DEFAULT_TRAVERSAL_TYPES := DualGridTilemap.TraversalType.LAND

enum NavigationStepStatus {
	READY,
	ARRIVED,
	DEFERRED,
	UNREACHABLE,
}


class NavigationStepResult:
	var status: int = NavigationStepStatus.DEFERRED
	var waypoint: Vector2 = Vector2.ZERO
	var from_cell: Vector2i = Vector2i.MAX
	var resolved_from_cell: Vector2i = Vector2i.MAX
	var target_cell: Vector2i = Vector2i.MAX
	var resolved_target_cell: Vector2i = Vector2i.MAX
	var next_cell: Vector2i = Vector2i.MAX
	var used_start_recovery: bool = false
	var is_complete_route: bool = false
	var remaining_cell_distance: int = -1

	func reset(
		new_status: int,
		new_from_cell: Vector2i = Vector2i.MAX,
		new_target_cell: Vector2i = Vector2i.MAX
	) -> void:
		status = new_status
		waypoint = Vector2.ZERO
		from_cell = new_from_cell
		resolved_from_cell = Vector2i.MAX
		target_cell = new_target_cell
		resolved_target_cell = Vector2i.MAX
		next_cell = Vector2i.MAX
		used_start_recovery = false
		is_complete_route = false
		remaining_cell_distance = -1


class FlowQueryContext:
	var generation: int = -1
	var target_is_static: bool = false
	var requested_target_position: Vector2 = Vector2.ZERO
	var original_target_cell: Vector2i = Vector2i.MAX
	var resolved_target_cell: Vector2i = Vector2i.MAX
	var normalized_extents: Vector2 = Vector2.ZERO
	var traversal_types: int = 0
	var path_grid: AStarGrid2D = null
	var next_cells: Dictionary = {}
	var distances: Dictionary = {}

	func invalidate() -> void:
		generation = -1
		path_grid = null
		next_cells = {}
		distances = {}

@export var obstacle_tile_layer_path: NodePath = ^"../GroundTileMapLayer"
@export var terrain_map_path: NodePath
# 用于检测阻挡的碰撞层索引
@export var tile_physics_layer_index: int = 0
# Legacy full-path callers are complete-only by default. Partial routes remain
# opt-in for diagnostics and are never accepted by the safe-step API.
@export var allow_partial_path: bool = false
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
var agent_grid_cache: Dictionary = {}
var flow_field_cache: Dictionary = {}
var flow_field_cache_order: Array[String] = []
var region_local_rect: Rect2 = Rect2()
var terrain_rebuild_queued: bool = false
var navigation_generation: int = 0
var legacy_navigation_step_scratch := NavigationStepResult.new()


# 在节点进入场景树时调用，初始化寻路网格
func _ready() -> void:
	rebuild()


# 重新构建寻路网格数据
func rebuild() -> void:
	navigation_generation += 1
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
			astar_grid.set_point_solid(cell, _is_cell_blocked(cell))

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


# Returns one grid-safe navigation decision with an explicit status. Unlike the
# legacy path API, READY is only returned when the resolved start belongs to a
# flow field that reaches the resolved target. Partial A* paths are never
# surfaced as successful navigation.
func try_get_safe_navigation_step(
	from_global_position: Vector2,
	to_global_position: Vector2,
	agent_half_extents: Vector2 = Vector2.ZERO,
	traversal_types: int = DEFAULT_TRAVERSAL_TYPES
) -> Dictionary:
	var result := legacy_navigation_step_scratch
	_write_safe_navigation_step(
		result,
		null,
		from_global_position,
		to_global_position,
		agent_half_extents,
		traversal_types,
		true,
		false
	)
	return _navigation_step_result_to_dictionary(result)


# Allocation-free form for hot consumers. `result` and `context` are owned and
# reused by the caller; static targets reuse the already-resolved shared field.
func try_write_safe_navigation_step(
	result: NavigationStepResult,
	context: FlowQueryContext,
	from_global_position: Vector2,
	to_global_position: Vector2,
	agent_half_extents: Vector2 = Vector2.ZERO,
	traversal_types: int = DEFAULT_TRAVERSAL_TYPES,
	target_is_static: bool = false
) -> void:
	_write_safe_navigation_step(
		result,
		context,
		from_global_position,
		to_global_position,
		agent_half_extents,
		traversal_types,
		true,
		target_is_static
	)


# Unbudgeted form for prewarming, validation and deterministic tests.
func get_safe_navigation_step(
	from_global_position: Vector2,
	to_global_position: Vector2,
	agent_half_extents: Vector2 = Vector2.ZERO,
	traversal_types: int = DEFAULT_TRAVERSAL_TYPES
) -> Dictionary:
	var result := legacy_navigation_step_scratch
	_write_safe_navigation_step(
		result,
		null,
		from_global_position,
		to_global_position,
		agent_half_extents,
		traversal_types,
		false,
		false
	)
	return _navigation_step_result_to_dictionary(result)


func write_safe_navigation_step(
	result: NavigationStepResult,
	context: FlowQueryContext,
	from_global_position: Vector2,
	to_global_position: Vector2,
	agent_half_extents: Vector2 = Vector2.ZERO,
	traversal_types: int = DEFAULT_TRAVERSAL_TYPES,
	target_is_static: bool = false
) -> void:
	_write_safe_navigation_step(
		result,
		context,
		from_global_position,
		to_global_position,
		agent_half_extents,
		traversal_types,
		false,
		target_is_static
	)


# Complete-only A* path used by diagnostics and callers that need the full
# route. This deliberately ignores allow_partial_path.
func get_complete_global_path(
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
	var target_cell := _get_closest_walkable_cell(_global_to_map(to_global_position), path_grid)
	if from_cell == Vector2i.MAX or target_cell == Vector2i.MAX:
		return PackedVector2Array()

	var cell_path := path_grid.get_id_path(from_cell, target_cell, false)
	if cell_path.is_empty() or cell_path[cell_path.size() - 1] != target_cell:
		return PackedVector2Array()
	if cell_path.size() == 1:
		if _is_global_position_walkable_for_agent(
			to_global_position,
			normalized_extents,
			traversal_types
		):
			return PackedVector2Array([to_global_position])
		return PackedVector2Array([_map_to_global(target_cell)])

	var global_path := PackedVector2Array()
	var first_path_index := 1 if from_cell == original_from_cell else 0
	for cell_index in range(first_path_index, cell_path.size()):
		global_path.append(_map_to_global(cell_path[cell_index]))

	if not global_path.is_empty() and _is_global_position_walkable_for_agent(
		to_global_position,
		normalized_extents,
		traversal_types
	):
		global_path[global_path.size() - 1] = to_global_position
	return global_path


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


func prewarm_agent_grid_staged(
	agent_half_extents: Vector2,
	traversal_types: int = DEFAULT_TRAVERSAL_TYPES,
	rows_per_frame: int = 8
) -> void:
	if not is_built:
		return
	var normalized_extents := _normalize_agent_half_extents(agent_half_extents)
	if normalized_extents == Vector2.ZERO:
		return
	var cache_key := _get_agent_grid_cache_key(normalized_extents, traversal_types)
	if agent_grid_cache.has(cache_key):
		return

	var agent_grid := AStarGrid2D.new()
	agent_grid.region = astar_grid.region
	agent_grid.cell_size = astar_grid.cell_size
	agent_grid.diagonal_mode = AStarGrid2D.DIAGONAL_MODE_NEVER
	agent_grid.default_compute_heuristic = AStarGrid2D.HEURISTIC_MANHATTAN
	agent_grid.default_estimate_heuristic = AStarGrid2D.HEURISTIC_MANHATTAN
	agent_grid.update()
	var completed_rows := 0
	for y in range(agent_grid.region.position.y, agent_grid.region.end.y):
		for x in range(agent_grid.region.position.x, agent_grid.region.end.x):
			var cell := Vector2i(x, y)
			agent_grid.set_point_solid(
				cell,
				_is_cell_blocked_for_agent(cell, normalized_extents, traversal_types)
			)
		completed_rows += 1
		if completed_rows >= maxi(rows_per_frame, 1):
			completed_rows = 0
			await get_tree().process_frame
			if not is_inside_tree() or not is_built:
				return
	agent_grid_cache[cache_key] = agent_grid


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


func prewarm_flow_navigation_target_staged(
	to_global_position: Vector2,
	agent_half_extents: Vector2 = Vector2.ZERO,
	traversal_types: int = DEFAULT_TRAVERSAL_TYPES,
	cells_per_frame: int = 1024
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
	var field: Dictionary = await _build_flow_field_staged(
		target_cell,
		path_grid,
		cells_per_frame
	)
	if field.is_empty() or not is_inside_tree() or not is_built:
		return
	_store_flow_field(target_cell, normalized_extents, traversal_types, field)


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


func _write_safe_navigation_step(
	result: NavigationStepResult,
	context: FlowQueryContext,
	from_global_position: Vector2,
	to_global_position: Vector2,
	agent_half_extents: Vector2,
	traversal_types: int,
	uses_build_budget: bool,
	target_is_static: bool
) -> void:
	if result == null:
		return
	if not is_built:
		result.reset(NavigationStepStatus.DEFERRED)
		return

	var normalized_extents := _normalize_agent_half_extents(agent_half_extents)
	var original_from_cell := _global_to_map(from_global_position)
	var original_target_cell := Vector2i.MAX
	var target_cell := Vector2i.MAX
	var path_grid: AStarGrid2D = null
	var next_cells_variant: Variant = null
	var distances_variant: Variant = null
	if _can_reuse_flow_query_context(
		context,
		to_global_position,
		normalized_extents,
		traversal_types,
		target_is_static
	):
		original_target_cell = context.original_target_cell
		target_cell = context.resolved_target_cell
		path_grid = context.path_grid
		next_cells_variant = context.next_cells
		distances_variant = context.distances
	else:
		original_target_cell = _global_to_map(to_global_position)
		path_grid = _get_or_create_agent_grid(normalized_extents, traversal_types)
		target_cell = _get_closest_walkable_cell(original_target_cell, path_grid)
		if target_cell == Vector2i.MAX:
			result.reset(
				NavigationStepStatus.UNREACHABLE,
				original_from_cell,
				original_target_cell
			)
			if context != null:
				context.invalidate()
			return

		var field := _get_cached_flow_field(target_cell, normalized_extents, traversal_types)
		if field.is_empty():
			if uses_build_budget:
				_refresh_flow_field_budget_frame()
				if flow_field_builds_used_this_frame >= maxi(max_flow_field_builds_per_physics_frame, 1):
					result.reset(
						NavigationStepStatus.DEFERRED,
						original_from_cell,
						original_target_cell
					)
					result.resolved_target_cell = target_cell
					if context != null:
						context.invalidate()
					return
				flow_field_builds_used_this_frame += 1
			field = _build_flow_field(target_cell, path_grid)
			_store_flow_field(target_cell, normalized_extents, traversal_types, field)

		if field.is_empty():
			result.reset(
				NavigationStepStatus.UNREACHABLE,
				original_from_cell,
				original_target_cell
			)
			result.resolved_target_cell = target_cell
			if context != null:
				context.invalidate()
			return
		next_cells_variant = field["next_cells"]
		distances_variant = field["distances"]
		var field_next_cells := next_cells_variant as Dictionary
		var field_distances := distances_variant as Dictionary
		if field_next_cells.is_empty():
			result.reset(
				NavigationStepStatus.UNREACHABLE,
				original_from_cell,
				original_target_cell
			)
			result.resolved_target_cell = target_cell
			if context != null:
				context.invalidate()
			return
		if context != null:
			_bind_flow_query_context(
				context,
				to_global_position,
				original_target_cell,
				target_cell,
				normalized_extents,
				traversal_types,
				path_grid,
				field_next_cells,
				field_distances,
				target_is_static
			)
	var next_cells := next_cells_variant as Dictionary
	var distances := distances_variant as Dictionary

	var from_cell := original_from_cell
	var used_start_recovery := false
	if not _is_cell_walkable(from_cell, path_grid):
		from_cell = _get_safe_adjacent_flow_recovery_cell(
			original_from_cell,
			next_cells,
			distances,
			path_grid
		)
		used_start_recovery = from_cell != Vector2i.MAX
	elif not next_cells.has(from_cell):
		# A walkable cell absent from the target's field is in another connected
		# component. Do not turn a partial route into apparent forward progress.
		from_cell = Vector2i.MAX

	if from_cell == Vector2i.MAX or not next_cells.has(from_cell):
		result.reset(
			NavigationStepStatus.UNREACHABLE,
			original_from_cell,
			original_target_cell
		)
		result.resolved_target_cell = target_cell
		return

	var route_distance := int(distances.get(from_cell, -1))
	var flow_next_cell: Vector2i = next_cells.get(from_cell, Vector2i.MAX)
	if flow_next_cell == Vector2i.MAX:
		result.reset(
			NavigationStepStatus.UNREACHABLE,
			original_from_cell,
			original_target_cell
		)
		return

	result.reset(
		NavigationStepStatus.READY,
		original_from_cell,
		original_target_cell
	)
	result.resolved_from_cell = from_cell
	result.resolved_target_cell = target_cell
	# next_cell always describes the waypoint returned for this decision. During
	# recovery that is the one adjacent reachable cell; the following flow step
	# is deliberately deferred until the body has safely entered it.
	result.next_cell = from_cell if used_start_recovery else flow_next_cell
	result.used_start_recovery = used_start_recovery
	result.is_complete_route = true
	result.remaining_cell_distance = route_distance + (1 if used_start_recovery else 0)

	if used_start_recovery:
		# Recovery is deliberately limited to one cardinal cell. Returning a
		# farther cell would ask CharacterBody2D to cross unknown collision space.
		result.waypoint = _map_to_global(from_cell)
		return

	if flow_next_cell != from_cell:
		result.waypoint = _map_to_global(flow_next_cell)
		return

	var resolved_target_position := _map_to_global(target_cell)
	if _is_global_position_walkable_for_agent(
		to_global_position,
		normalized_extents,
		traversal_types
	):
		result.waypoint = to_global_position
		if from_global_position.distance_squared_to(to_global_position) <= 0.25:
			result.status = NavigationStepStatus.ARRIVED
		return

	result.waypoint = resolved_target_position
	if from_global_position.distance_squared_to(resolved_target_position) <= 0.25:
		result.status = NavigationStepStatus.ARRIVED


func _can_reuse_flow_query_context(
	context: FlowQueryContext,
	to_global_position: Vector2,
	normalized_extents: Vector2,
	traversal_types: int,
	target_is_static: bool
) -> bool:
	if context == null or context.generation != navigation_generation:
		return false
	if context.path_grid == null or context.next_cells.is_empty():
		return false
	if (
		context.normalized_extents != normalized_extents
		or context.traversal_types != traversal_types
		or context.target_is_static != target_is_static
	):
		return false
	if target_is_static:
		return context.requested_target_position == to_global_position
	return context.original_target_cell == _global_to_map(to_global_position)


func _bind_flow_query_context(
	context: FlowQueryContext,
	to_global_position: Vector2,
	original_target_cell: Vector2i,
	resolved_target_cell: Vector2i,
	normalized_extents: Vector2,
	traversal_types: int,
	path_grid: AStarGrid2D,
	next_cells: Dictionary,
	distances: Dictionary,
	target_is_static: bool
) -> void:
	context.generation = navigation_generation
	context.target_is_static = target_is_static
	context.requested_target_position = to_global_position
	context.original_target_cell = original_target_cell
	context.resolved_target_cell = resolved_target_cell
	context.normalized_extents = normalized_extents
	context.traversal_types = traversal_types
	context.path_grid = path_grid
	context.next_cells = next_cells
	context.distances = distances


func _navigation_step_result_to_dictionary(result: NavigationStepResult) -> Dictionary:
	return {
		"status": result.status,
		"waypoint": result.waypoint,
		"from_cell": result.from_cell,
		"resolved_from_cell": result.resolved_from_cell,
		"target_cell": result.target_cell,
		"resolved_target_cell": result.resolved_target_cell,
		"next_cell": result.next_cell,
		"used_start_recovery": result.used_start_recovery,
		"is_complete_route": result.is_complete_route,
		"remaining_cell_distance": result.remaining_cell_distance,
	}


func _get_safe_adjacent_flow_recovery_cell(
	origin_cell: Vector2i,
	next_cells: Dictionary,
	distances: Dictionary,
	path_grid: AStarGrid2D
) -> Vector2i:
	var best_cell := Vector2i.MAX
	var best_flow_distance := INF
	for direction in FLOW_CARDINAL_DIRECTIONS:
		var candidate := origin_cell + direction
		if not next_cells.has(candidate):
			continue
		if not _is_cell_walkable(candidate, path_grid):
			continue
		var flow_distance := float(distances.get(candidate, INF))
		if flow_distance < best_flow_distance:
			best_flow_distance = flow_distance
			best_cell = candidate
	return best_cell


func _get_flow_navigation_waypoint(
	from_global_position: Vector2,
	to_global_position: Vector2,
	agent_half_extents: Vector2,
	traversal_types: int,
	uses_build_budget: bool
) -> Variant:
	# Compatibility wrapper: legacy flow callers inherit the complete-route and
	# one-cardinal-cell recovery guarantees of the safe-step API.
	var step := legacy_navigation_step_scratch
	_write_safe_navigation_step(
		step,
		null,
		from_global_position,
		to_global_position,
		agent_half_extents,
		traversal_types,
		uses_build_budget,
		false
	)
	var status := step.status
	if status != NavigationStepStatus.READY and status != NavigationStepStatus.ARRIVED:
		return null
	return step.waypoint


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


func _build_flow_field_staged(
	target_cell: Vector2i,
	path_grid: AStarGrid2D,
	cells_per_frame: int
) -> Dictionary:
	var next_cells: Dictionary = {}
	var distances: Dictionary = {}
	var pending_cells: Array[Vector2i] = []
	var pending_cell_index := 0
	var processed_this_frame := 0
	next_cells[target_cell] = target_cell
	distances[target_cell] = 0
	pending_cells.append(target_cell)
	while pending_cell_index < pending_cells.size():
		var current_cell := pending_cells[pending_cell_index]
		pending_cell_index += 1
		var current_distance := int(distances[current_cell])
		for direction in FLOW_CARDINAL_DIRECTIONS:
			var neighbor: Vector2i = current_cell + direction
			if distances.has(neighbor) or not _is_cell_walkable(neighbor, path_grid):
				continue
			distances[neighbor] = current_distance + 1
			next_cells[neighbor] = current_cell
			pending_cells.append(neighbor)
		processed_this_frame += 1
		if processed_this_frame >= maxi(cells_per_frame, 1):
			processed_this_frame = 0
			await get_tree().process_frame
			if not is_inside_tree() or not is_built:
				return {}
	return {
		"target_cell": target_cell,
		"next_cells": next_cells,
		"distances": distances,
	}


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
	var field_variant: Variant = flow_field_cache.get(cache_key)
	if field_variant == null:
		return {}
	var field := field_variant as Dictionary
	if field == null or field.is_empty():
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

	var cell_size := astar_grid.cell_size.abs()
	var half_cell := cell_size * 0.5
	var collision_reach := padded_extents + half_cell
	var center_cell := obstacle_tile_layer.local_to_map(local_position)
	var candidate_radius := Vector2i(
		ceili(collision_reach.x / maxf(cell_size.x, 0.001)),
		ceili(collision_reach.y / maxf(cell_size.y, 0.001))
	)
	var region := astar_grid.region
	var min_cell := Vector2i(
		maxi(center_cell.x - candidate_radius.x, region.position.x),
		maxi(center_cell.y - candidate_radius.y, region.position.y)
	)
	var max_cell := Vector2i(
		mini(center_cell.x + candidate_radius.x, region.end.x - 1),
		mini(center_cell.y + candidate_radius.y, region.end.y - 1)
	)
	for cell_y in range(min_cell.y, max_cell.y + 1):
		for cell_x in range(min_cell.x, max_cell.x + 1):
			var blocked_cell := Vector2i(cell_x, cell_y)
			if not _is_cell_blocked(blocked_cell, traversal_types):
				continue
			var blocked_center := obstacle_tile_layer.map_to_local(blocked_cell)
			var delta := (local_position - blocked_center).abs()
			if delta.x < collision_reach.x and delta.y < collision_reach.y:
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
		# In dual-grid scenes the obstacle layer is sparse: open dirt/grass lives
		# in the semantic terrain map and only authored structures occupy this
		# layer. A missing obstacle tile therefore means "no obstacle", while
		# legacy scenes without a terrain map retain their closed-grid behavior.
		return terrain_map == null

	return tile_data.get_collision_polygons_count(tile_physics_layer_index) > 0
