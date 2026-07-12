extends Node
class_name GridPathfinder

const FLOW_CARDINAL_DIRECTIONS: Array[Vector2i] = [
	Vector2i.RIGHT,
	Vector2i.LEFT,
	Vector2i.DOWN,
	Vector2i.UP,
]
const FLOW_DIAGONAL_DIRECTIONS: Array[Vector2i] = [
	Vector2i(1, 1),
	Vector2i(1, -1),
	Vector2i(-1, 1),
	Vector2i(-1, -1),
]
const FLOW_DIRECTIONS: Array[Vector2i] = [
	Vector2i.RIGHT,
	Vector2i.LEFT,
	Vector2i.DOWN,
	Vector2i.UP,
	Vector2i(1, 1),
	Vector2i(1, -1),
	Vector2i(-1, 1),
	Vector2i(-1, -1),
]
const FLOW_ORTHOGONAL_COST := 10
const FLOW_DIAGONAL_COST := 14
const MAX_FLOW_RECOVERY_CACHE_ENTRIES := 512
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
var flow_recovery_route_cache: Dictionary = {}
var flow_recovery_cache_order: Array[String] = []
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
	flow_recovery_route_cache.clear()
	flow_recovery_cache_order.clear()
	astar_grid.region = used_rect
	astar_grid.cell_size = Vector2(obstacle_tile_layer.tile_set.tile_size)
	astar_grid.diagonal_mode = AStarGrid2D.DIAGONAL_MODE_ONLY_IF_NO_OBSTACLES
	astar_grid.default_compute_heuristic = AStarGrid2D.HEURISTIC_OCTILE
	astar_grid.default_estimate_heuristic = AStarGrid2D.HEURISTIC_OCTILE
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


func is_navigation_segment_walkable(
	from_global_position: Vector2,
	to_global_position: Vector2,
	agent_half_extents: Vector2 = Vector2.ZERO,
	traversal_types: int = DEFAULT_TRAVERSAL_TYPES
) -> bool:
	if not is_built or obstacle_tile_layer == null:
		return false
	var normalized_extents := _normalize_agent_half_extents(agent_half_extents)
	var path_grid := _get_or_create_agent_grid(normalized_extents, traversal_types)
	var from_local := obstacle_tile_layer.to_local(from_global_position)
	var to_local := obstacle_tile_layer.to_local(to_global_position)
	var local_distance := from_local.distance_to(to_local)
	var minimum_cell_size := minf(
		absf(astar_grid.cell_size.x),
		absf(astar_grid.cell_size.y)
	)
	var sample_spacing := maxf(minimum_cell_size * 0.5, 1.0)
	var sample_count := maxi(ceili(local_distance / sample_spacing), 1)
	for sample_index in range(sample_count + 1):
		var weight := float(sample_index) / float(sample_count)
		var sample_local := from_local.lerp(to_local, weight)
		var sample_cell := obstacle_tile_layer.local_to_map(sample_local)
		if not _is_cell_walkable(sample_cell, path_grid):
			return false
		if (
			normalized_extents != Vector2.ZERO
			and not _is_local_position_walkable_for_agent(
				sample_local,
				normalized_extents,
				traversal_types
			)
		):
			return false
	return true


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
	var build_generation := navigation_generation

	var agent_grid := AStarGrid2D.new()
	agent_grid.region = astar_grid.region
	agent_grid.cell_size = astar_grid.cell_size
	agent_grid.diagonal_mode = AStarGrid2D.DIAGONAL_MODE_ONLY_IF_NO_OBSTACLES
	agent_grid.default_compute_heuristic = AStarGrid2D.HEURISTIC_OCTILE
	agent_grid.default_estimate_heuristic = AStarGrid2D.HEURISTIC_OCTILE
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
			if (
				not is_inside_tree()
				or not is_built
				or navigation_generation != build_generation
			):
				return
	if navigation_generation != build_generation:
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
	var build_generation := navigation_generation
	var field: Dictionary = await _build_flow_field_staged(
		target_cell,
		path_grid,
		cells_per_frame
	)
	if (
		field.is_empty()
		or not is_inside_tree()
		or not is_built
		or navigation_generation != build_generation
	):
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
	agent_grid.diagonal_mode = AStarGrid2D.DIAGONAL_MODE_ONLY_IF_NO_OBSTACLES
	agent_grid.default_compute_heuristic = AStarGrid2D.HEURISTIC_OCTILE
	agent_grid.default_estimate_heuristic = AStarGrid2D.HEURISTIC_OCTILE
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
	var recovery_waypoint_cell := Vector2i.MAX
	var recovery_cost := 0
	if not _is_cell_walkable(from_cell, path_grid):
		var recovery_route := _get_cached_safe_flow_recovery_route(
			original_from_cell,
			target_cell,
			normalized_extents,
			next_cells,
			distances,
			path_grid,
			traversal_types
		)
		from_cell = recovery_route.get("resolved_cell", Vector2i.MAX) as Vector2i
		recovery_waypoint_cell = recovery_route.get(
			"first_step_cell",
			Vector2i.MAX
		) as Vector2i
		recovery_cost = int(recovery_route.get("recovery_cost", 0))
		used_start_recovery = (
			from_cell != Vector2i.MAX
			and recovery_waypoint_cell != Vector2i.MAX
		)
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
	# next_cell always describes the immediate waypoint returned for this
	# decision. During recovery it is the first raw-terrain-safe step toward the
	# resolved flow cell, never the farther resolved cell itself.
	result.next_cell = recovery_waypoint_cell if used_start_recovery else flow_next_cell
	result.used_start_recovery = used_start_recovery
	result.is_complete_route = true
	# Internally the eight-way Dijkstra uses 10/14 Octile weights. Keep the
	# existing result field in tile-distance units instead of leaking that
	# implementation scale to callers.
	result.remaining_cell_distance = ceili(
		float(route_distance + recovery_cost) / float(FLOW_ORTHOGONAL_COST)
	)

	if used_start_recovery:
		# The body moves toward this center normally; it is never teleported. The
		# raw-cell corridor and CharacterBody shape sweep together let a large body
		# leave the conservative inflated band without crossing authored terrain.
		result.waypoint = _map_to_global(recovery_waypoint_cell)
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


func _get_safe_flow_recovery_route(
	origin_cell: Vector2i,
	next_cells: Dictionary,
	distances: Dictionary,
	path_grid: AStarGrid2D,
	traversal_types: int
) -> Dictionary:
	var search_radius := maxi(max_nearest_cell_search_radius, 0)
	if search_radius <= 0 or _is_cell_blocked(origin_cell, traversal_types):
		return {}

	var recovery_costs: Dictionary = {origin_cell: 0}
	var recovery_parents: Dictionary = {origin_cell: Vector2i.MAX}
	var pending_cells: Array[Vector2i] = []
	var pending_costs: Array[int] = []
	var best_cell := Vector2i.MAX
	var best_recovery_cost := 2147483647
	var best_flow_distance := 2147483647
	_push_flow_heap_entry(pending_cells, pending_costs, origin_cell, 0)

	while not pending_cells.is_empty():
		var pending_entry := _pop_flow_heap_entry(pending_cells, pending_costs)
		var current_cell := Vector2i(pending_entry.x, pending_entry.y)
		var current_cost := pending_entry.z
		if current_cost != int(recovery_costs.get(current_cell, -1)):
			continue
		if current_cost > best_recovery_cost:
			break
		if (
			current_cell != origin_cell
			and next_cells.has(current_cell)
			and _is_cell_walkable(current_cell, path_grid)
		):
			var flow_distance := int(distances.get(current_cell, 2147483647))
			if (
				current_cost < best_recovery_cost
				or (
					current_cost == best_recovery_cost
					and flow_distance < best_flow_distance
				)
			):
				best_cell = current_cell
				best_recovery_cost = current_cost
				best_flow_distance = flow_distance
			continue

		for direction in FLOW_DIRECTIONS:
			var neighbor := current_cell + direction
			if _chebyshev_cell_distance(origin_cell, neighbor) > search_radius:
				continue
			if not path_grid.is_in_boundsv(neighbor):
				continue
			if not _is_raw_recovery_transition_safe(
				current_cell,
				direction,
				traversal_types
			):
				continue
			var candidate_cost := current_cost + _get_flow_transition_cost(direction)
			if candidate_cost >= int(recovery_costs.get(neighbor, 2147483647)):
				continue
			recovery_costs[neighbor] = candidate_cost
			recovery_parents[neighbor] = current_cell
			_push_flow_heap_entry(
				pending_cells,
				pending_costs,
				neighbor,
				candidate_cost
			)

	if best_cell == Vector2i.MAX:
		return {}
	var first_step_cell := best_cell
	var parent_cell: Vector2i = recovery_parents.get(
		first_step_cell,
		Vector2i.MAX
	)
	while parent_cell != origin_cell and parent_cell != Vector2i.MAX:
		first_step_cell = parent_cell
		parent_cell = recovery_parents.get(
			first_step_cell,
			Vector2i.MAX
		)
	if parent_cell != origin_cell:
		return {}
	return {
		"resolved_cell": best_cell,
		"first_step_cell": first_step_cell,
		"recovery_cost": best_recovery_cost,
	}


func _get_cached_safe_flow_recovery_route(
	origin_cell: Vector2i,
	target_cell: Vector2i,
	agent_half_extents: Vector2,
	next_cells: Dictionary,
	distances: Dictionary,
	path_grid: AStarGrid2D,
	traversal_types: int
) -> Dictionary:
	# Hundreds of enemies often enter the same conservative blocked band at the
	# same cell. The recovery corridor depends only on the current navigation
	# generation, flow profile, origin and configured search radius, so share it
	# just like the flow field instead of rerunning bounded Dijkstra per enemy.
	var cache_key := "%d:%s:%d:%d:%d" % [
		navigation_generation,
		_get_flow_field_cache_key(target_cell, agent_half_extents, traversal_types),
		origin_cell.x,
		origin_cell.y,
		maxi(max_nearest_cell_search_radius, 0),
	]
	if flow_recovery_route_cache.has(cache_key):
		return flow_recovery_route_cache[cache_key] as Dictionary

	var recovery_route := _get_safe_flow_recovery_route(
		origin_cell,
		next_cells,
		distances,
		path_grid,
		traversal_types
	)
	flow_recovery_route_cache[cache_key] = recovery_route
	flow_recovery_cache_order.append(cache_key)
	while flow_recovery_cache_order.size() > MAX_FLOW_RECOVERY_CACHE_ENTRIES:
		var oldest_key := flow_recovery_cache_order.pop_front() as String
		flow_recovery_route_cache.erase(oldest_key)
	return recovery_route


func _is_raw_recovery_transition_safe(
	from_cell: Vector2i,
	direction: Vector2i,
	traversal_types: int
) -> bool:
	var target_cell := from_cell + direction
	if not astar_grid.is_in_boundsv(target_cell):
		return false
	if _is_cell_blocked(target_cell, traversal_types):
		return false
	if direction.x == 0 or direction.y == 0:
		return true
	var horizontal_side := from_cell + Vector2i(direction.x, 0)
	var vertical_side := from_cell + Vector2i(0, direction.y)
	if (
		not astar_grid.is_in_boundsv(horizontal_side)
		or not astar_grid.is_in_boundsv(vertical_side)
	):
		return false
	return (
		not _is_cell_blocked(horizontal_side, traversal_types)
		and not _is_cell_blocked(vertical_side, traversal_types)
	)


func _chebyshev_cell_distance(from_cell: Vector2i, to_cell: Vector2i) -> int:
	var delta := (to_cell - from_cell).abs()
	return maxi(delta.x, delta.y)


func _get_flow_navigation_waypoint(
	from_global_position: Vector2,
	to_global_position: Vector2,
	agent_half_extents: Vector2,
	traversal_types: int,
	uses_build_budget: bool
) -> Variant:
	# Compatibility wrapper: legacy flow callers inherit the complete-route and
	# bounded, step-by-step recovery guarantees of the safe-step API.
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
	var pending_costs: Array[int] = []
	next_cells[target_cell] = target_cell
	distances[target_cell] = 0
	_push_flow_heap_entry(pending_cells, pending_costs, target_cell, 0)

	while not pending_cells.is_empty():
		var pending_entry := _pop_flow_heap_entry(pending_cells, pending_costs)
		var current_cell := Vector2i(pending_entry.x, pending_entry.y)
		var current_distance := pending_entry.z
		if current_distance != int(distances.get(current_cell, -1)):
			continue
		for direction in FLOW_DIRECTIONS:
			var neighbor: Vector2i = current_cell + direction
			if not _is_safe_flow_transition(current_cell, direction, path_grid):
				continue
			var candidate_distance := current_distance + _get_flow_transition_cost(direction)
			if candidate_distance >= int(distances.get(neighbor, 2147483647)):
				continue
			distances[neighbor] = candidate_distance
			next_cells[neighbor] = current_cell
			_push_flow_heap_entry(
				pending_cells,
				pending_costs,
				neighbor,
				candidate_distance
			)

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
	var pending_costs: Array[int] = []
	var processed_this_frame := 0
	var build_generation := navigation_generation
	next_cells[target_cell] = target_cell
	distances[target_cell] = 0
	_push_flow_heap_entry(pending_cells, pending_costs, target_cell, 0)
	while not pending_cells.is_empty():
		var pending_entry := _pop_flow_heap_entry(pending_cells, pending_costs)
		var current_cell := Vector2i(pending_entry.x, pending_entry.y)
		var current_distance := pending_entry.z
		if current_distance != int(distances.get(current_cell, -1)):
			continue
		for direction in FLOW_DIRECTIONS:
			var neighbor: Vector2i = current_cell + direction
			if not _is_safe_flow_transition(current_cell, direction, path_grid):
				continue
			var candidate_distance := current_distance + _get_flow_transition_cost(direction)
			if candidate_distance >= int(distances.get(neighbor, 2147483647)):
				continue
			distances[neighbor] = candidate_distance
			next_cells[neighbor] = current_cell
			_push_flow_heap_entry(
				pending_cells,
				pending_costs,
				neighbor,
				candidate_distance
			)
		processed_this_frame += 1
		if processed_this_frame >= maxi(cells_per_frame, 1):
			processed_this_frame = 0
			await get_tree().process_frame
			if (
				not is_inside_tree()
				or not is_built
				or navigation_generation != build_generation
			):
				return {}
	return {
		"target_cell": target_cell,
		"next_cells": next_cells,
		"distances": distances,
	}


func _is_safe_flow_transition(
	from_cell: Vector2i,
	direction: Vector2i,
	path_grid: AStarGrid2D
) -> bool:
	if not _is_cell_walkable(from_cell, path_grid):
		return false
	var target_cell := from_cell + direction
	if not _is_cell_walkable(target_cell, path_grid):
		return false
	if direction.x == 0 or direction.y == 0:
		return true
	# A diagonal is valid only when both orthogonal side cells are valid for the
	# same inflated agent grid. This is the grid equivalent of Godot's
	# DIAGONAL_MODE_ONLY_IF_NO_OBSTACLES and prevents cutting across wall/water
	# corners with large collision shapes.
	return (
		_is_cell_walkable(from_cell + Vector2i(direction.x, 0), path_grid)
		and _is_cell_walkable(from_cell + Vector2i(0, direction.y), path_grid)
	)


func _get_flow_transition_cost(direction: Vector2i) -> int:
	return (
		FLOW_DIAGONAL_COST
		if direction.x != 0 and direction.y != 0
		else FLOW_ORTHOGONAL_COST
	)


func _push_flow_heap_entry(
	heap_cells: Array[Vector2i],
	heap_costs: Array[int],
	cell: Vector2i,
	cost: int
) -> void:
	heap_cells.append(cell)
	heap_costs.append(cost)
	var index := heap_cells.size() - 1
	while index > 0:
		var parent_index := (index - 1) >> 1
		if heap_costs[parent_index] <= cost:
			break
		heap_cells[index] = heap_cells[parent_index]
		heap_costs[index] = heap_costs[parent_index]
		index = parent_index
	heap_cells[index] = cell
	heap_costs[index] = cost


func _pop_flow_heap_entry(
	heap_cells: Array[Vector2i],
	heap_costs: Array[int]
) -> Vector3i:
	var root_cell := heap_cells[0]
	var root_cost := heap_costs[0]
	var last_cell: Vector2i = heap_cells.pop_back()
	var last_cost: int = heap_costs.pop_back()
	if not heap_cells.is_empty():
		var index := 0
		while true:
			var left_child := index * 2 + 1
			if left_child >= heap_cells.size():
				break
			var right_child := left_child + 1
			var smaller_child := left_child
			if (
				right_child < heap_cells.size()
				and heap_costs[right_child] < heap_costs[left_child]
			):
				smaller_child = right_child
			if heap_costs[smaller_child] >= last_cost:
				break
			heap_cells[index] = heap_cells[smaller_child]
			heap_costs[index] = heap_costs[smaller_child]
			index = smaller_child
		heap_cells[index] = last_cell
		heap_costs[index] = last_cost
	return Vector3i(root_cell.x, root_cell.y, root_cost)


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
