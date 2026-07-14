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
const FLOW_BUCKET_COUNT := FLOW_DIAGONAL_COST + 1
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
	var dynamic_slot_key: String = ""
	var dynamic_slot_revision: int = -1

	func invalidate() -> void:
		generation = -1
		path_grid = null
		next_cells = {}
		distances = {}
		dynamic_slot_key = ""
		dynamic_slot_revision = -1


class DynamicFlowTargetSlot:
	var generation: int = -1
	var slot_key: String = ""
	var target_instance_id: int = 0
	var target_reference: WeakRef = null
	var normalized_extents: Vector2 = Vector2.ZERO
	var traversal_types: int = 0
	var path_grid: AStarGrid2D = null
	var desired_original_cell: Vector2i = Vector2i.MAX
	var desired_resolved_cell: Vector2i = Vector2i.MAX
	var published_anchor_cell: Vector2i = Vector2i.MAX
	var published_field: Dictionary = {}
	var published_revision: int = 0
	var published_physics_frame: int = -1
	var pending_job_key: String = ""
	var last_request_physics_frame: int = -1


class RuntimeFlowBuildJob:
	var generation: int = -1
	var cache_key: String = ""
	var target_cell: Vector2i = Vector2i.MAX
	var normalized_extents: Vector2 = Vector2.ZERO
	var traversal_types: int = 0
	var path_grid: AStarGrid2D = null
	var next_cells: Dictionary = {}
	var distances: Dictionary = {}
	var pending_buckets: Array = []
	var pending_entry_count: int = 0
	var current_distance: int = 0
	var waiting_dynamic_slots: Dictionary = {}
	var publish_to_fixed_cache: bool = false
	var urgent: bool = false


class AgentSolidIntegralSnapshot:
	var generation: int = -1
	var region: Rect2i = Rect2i()
	var stride: int = 0
	var values: PackedInt32Array = PackedInt32Array()


class RuntimeAgentGridBuildJob:
	var generation: int = -1
	var cache_key: String = ""
	var normalized_extents: Vector2 = Vector2.ZERO
	var traversal_types: int = 0
	var path_grid: AStarGrid2D = null
	var publish_path_grid_to_cache: bool = true
	var next_cell_index: int = 0
	var grid_cells_completed: bool = false
	var solid_integral_snapshot: AgentSolidIntegralSnapshot = null
	var next_integral_cell_index: int = 0

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
# 每个物理帧最多登记多少张新 flow job；实际建图由独立的格数/时间预算分片。
@export_range(1, 128, 1, "or_greater") var max_flow_field_builds_per_physics_frame: int = 4
# flow field 按“敌人体型 + 目标格”缓存，限制上限避免长局无限增长。
@export_range(1, 256, 1, "or_greater") var max_flow_field_cache_entries: int = 48
# 动态目标的运行期建图必须切成有上限的小片，绝不允许在敌人物理帧中
# 同步遍历整张地图。格数与时间任一先到即让出主线程。
@export_range(16, 4096, 1, "or_greater") var runtime_navigation_max_expansions_per_frame: int = 192
@export_range(100, 8000, 50, "or_greater") var runtime_navigation_time_budget_usec: int = 1000
# 玩家目标至少偏离已发布锚点两个格子才立即请求新场；若停在相邻格，
# 最迟也会在短暂稳定后刷新。这样不会在每个 16px 格边界制造全图工作。
@export_range(1, 8, 1, "or_greater") var dynamic_target_repath_distance_cells: int = 2
@export_range(0.05, 2.0, 0.05, "or_greater") var dynamic_target_max_anchor_age_seconds: float = 0.25
@export_range(1.0, 120.0, 1.0, "or_greater") var dynamic_target_slot_ttl_seconds: float = 15.0
@export_range(1, 256, 1, "or_greater") var max_dynamic_target_slots: int = 64

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
# Each shared agent profile owns one immutable summed-area table of its solid
# cells. The table is published atomically with the profile grid, so a runtime
# caller can cheaply certify a completely open rectangle without ever observing
# a partially built snapshot.
var agent_open_plain_integral_cache: Dictionary = {}
var flow_field_cache: Dictionary = {}
var flow_field_cache_order: Array[String] = []
var flow_recovery_route_cache: Dictionary = {}
var flow_recovery_cache_order: Array[String] = []
var dynamic_flow_target_slots: Dictionary = {}
var runtime_flow_build_jobs: Dictionary = {}
var runtime_flow_build_order: Array[String] = []
var runtime_agent_grid_build_jobs: Dictionary = {}
var runtime_agent_grid_build_order: Array[String] = []
var region_local_rect: Rect2 = Rect2()
var terrain_rebuild_queued: bool = false
var navigation_generation: int = 0
var legacy_navigation_step_scratch := NavigationStepResult.new()
var runtime_navigation_expansions_last_frame: int = 0
var runtime_navigation_build_usec_last_frame: int = 0
var runtime_navigation_build_usec_peak: int = 0
var runtime_flow_builds_completed: int = 0
var runtime_flow_builds_cancelled: int = 0
var runtime_navigation_prefers_urgent_flow: bool = true


# 在节点进入场景树时调用，初始化寻路网格
func _ready() -> void:
	rebuild()
	set_process(false)


func _process(_delta: float) -> void:
	_advance_runtime_navigation_jobs()


# 重新构建寻路网格数据
func rebuild() -> void:
	navigation_generation += 1
	is_built = false
	_cancel_all_runtime_navigation_jobs()
	dynamic_flow_target_slots.clear()
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
	agent_open_plain_integral_cache.clear()
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

	_store_agent_open_plain_integral_snapshot(
		_get_agent_grid_cache_key(Vector2.ZERO, DEFAULT_TRAVERSAL_TYPES),
		_build_agent_solid_integral_snapshot(astar_grid)
	)
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


func _on_terrain_changed(_cell: Vector2i, previous_terrain: int, current_terrain: int) -> void:
	if not _does_terrain_change_affect_navigation(previous_terrain, current_terrain):
		return
	if terrain_rebuild_queued:
		return
	terrain_rebuild_queued = true
	call_deferred("_rebuild_after_terrain_change")


func _does_terrain_change_affect_navigation(
	previous_terrain: int,
	current_terrain: int
) -> bool:
	return (
		_get_traversal_type_for_terrain(previous_terrain)
		!= _get_traversal_type_for_terrain(current_terrain)
	)


func _get_traversal_type_for_terrain(terrain_type: int) -> int:
	if terrain_type == DualGridTilemap.TerrainType.WATER:
		return DualGridTilemap.TraversalType.WATER
	return DualGridTilemap.TraversalType.LAND


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


# Runtime-only path for moving objectives such as players. It never performs a
# full flow-field or agent-grid build inside the caller's physics tick. All
# enemies that chase the same Node2D with the same body profile share one slot,
# one published immutable field and at most one staged replacement job.
func try_write_dynamic_target_navigation_step(
	result: NavigationStepResult,
	context: FlowQueryContext,
	from_global_position: Vector2,
	target_node: Node2D,
	agent_half_extents: Vector2 = Vector2.ZERO,
	traversal_types: int = DEFAULT_TRAVERSAL_TYPES
) -> void:
	_write_dynamic_target_navigation_step(
		result,
		context,
		from_global_position,
		target_node,
		agent_half_extents,
		traversal_types
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
	return _is_navigation_segment_walkable_with_grid(
		from_global_position,
		to_global_position,
		normalized_extents,
		traversal_types,
		path_grid
	)


# Budget-aware runtime variant. A null result means the agent grid is being
# built in stages; callers should fall back to DEFERRED flow navigation rather
# than synchronously constructing it from a movement tick.
func try_is_navigation_segment_walkable(
	from_global_position: Vector2,
	to_global_position: Vector2,
	agent_half_extents: Vector2 = Vector2.ZERO,
	traversal_types: int = DEFAULT_TRAVERSAL_TYPES
) -> Variant:
	if not is_built or obstacle_tile_layer == null:
		return false
	var normalized_extents := _normalize_agent_half_extents(agent_half_extents)
	var path_grid := _get_runtime_agent_grid_or_enqueue(
		normalized_extents,
		traversal_types
	)
	if path_grid == null:
		return null
	return _is_navigation_segment_walkable_with_grid(
		from_global_position,
		to_global_position,
		normalized_extents,
		traversal_types,
		path_grid
	)


# Budget-aware, conservative certificate for static open terrain. This does not
# perform a physics sweep and does not claim that a body can move: it only
# proves that every cell in the endpoint bounding rectangle is walkable for the
# shared agent profile. Callers must retain their normal physics validation for
# dynamic bodies and exact collision geometry.
#
# A null result means that the profile grid and its immutable integral snapshot
# are still being built by the runtime navigation scheduler.
func try_is_navigation_open_plain(
	from_global_position: Vector2,
	to_global_position: Vector2,
	agent_half_extents: Vector2 = Vector2.ZERO,
	traversal_types: int = DEFAULT_TRAVERSAL_TYPES
) -> Variant:
	if not is_built or obstacle_tile_layer == null:
		return null
	var normalized_extents := _normalize_agent_half_extents(agent_half_extents)
	var path_grid := _get_runtime_agent_grid_or_enqueue(
		normalized_extents,
		traversal_types
	)
	if path_grid == null:
		return null
	var cache_key := _get_agent_grid_cache_key(
		normalized_extents,
		traversal_types
	)
	var snapshot := _get_agent_open_plain_integral_snapshot(cache_key)
	if snapshot == null:
		return null

	var from_cell := _global_to_map(from_global_position)
	var to_cell := _global_to_map(to_global_position)
	if (
		not snapshot.region.has_point(from_cell)
		or not snapshot.region.has_point(to_cell)
	):
		return false
	var minimum_cell := Vector2i(
		mini(from_cell.x, to_cell.x),
		mini(from_cell.y, to_cell.y)
	)
	var maximum_cell := Vector2i(
		maxi(from_cell.x, to_cell.x),
		maxi(from_cell.y, to_cell.y)
	)
	return _get_agent_solid_count_in_cell_rect(
		snapshot,
		minimum_cell,
		maximum_cell
	) == 0


func _is_navigation_segment_walkable_with_grid(
	from_global_position: Vector2,
	to_global_position: Vector2,
	normalized_extents: Vector2,
	traversal_types: int,
	path_grid: AStarGrid2D
) -> bool:
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
	if (
		agent_grid_cache.has(cache_key)
		and _get_agent_open_plain_integral_snapshot(cache_key) != null
	):
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
	var solid_integral_snapshot := _create_empty_agent_solid_integral_snapshot(
		agent_grid
	)
	completed_rows = 0
	for local_y in range(agent_grid.region.size.y):
		for local_x in range(agent_grid.region.size.x):
			_write_agent_solid_integral_cell(
				solid_integral_snapshot,
				agent_grid,
				local_y * agent_grid.region.size.x + local_x
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
	_store_agent_open_plain_integral_snapshot(
		cache_key,
		solid_integral_snapshot
	)
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


func _get_runtime_agent_grid_or_enqueue(
	normalized_extents: Vector2,
	traversal_types: int
) -> AStarGrid2D:
	var cache_key := _get_agent_grid_cache_key(normalized_extents, traversal_types)
	var uses_default_grid := (
		normalized_extents == Vector2.ZERO
		and traversal_types == DEFAULT_TRAVERSAL_TYPES
	)
	var cached_grid := (
		astar_grid
		if uses_default_grid
		else agent_grid_cache.get(cache_key) as AStarGrid2D
	)
	if (
		cached_grid != null
		and _get_agent_open_plain_integral_snapshot(cache_key) != null
	):
		return cached_grid
	_enqueue_runtime_agent_grid_build(
		cache_key,
		normalized_extents,
		traversal_types,
		cached_grid,
		not uses_default_grid
	)
	return null


func _enqueue_runtime_agent_grid_build(
	cache_key: String,
	normalized_extents: Vector2,
	traversal_types: int,
	existing_path_grid: AStarGrid2D = null,
	publish_path_grid_to_cache: bool = true
) -> void:
	if runtime_agent_grid_build_jobs.has(cache_key):
		return
	var job := RuntimeAgentGridBuildJob.new()
	job.generation = navigation_generation
	job.cache_key = cache_key
	job.normalized_extents = normalized_extents
	job.traversal_types = traversal_types
	job.publish_path_grid_to_cache = publish_path_grid_to_cache
	job.path_grid = existing_path_grid
	if job.path_grid != null:
		job.next_cell_index = job.path_grid.region.size.x * job.path_grid.region.size.y
		job.grid_cells_completed = true
	else:
		job.path_grid = AStarGrid2D.new()
		job.path_grid.region = astar_grid.region
		job.path_grid.cell_size = astar_grid.cell_size
		job.path_grid.diagonal_mode = AStarGrid2D.DIAGONAL_MODE_ONLY_IF_NO_OBSTACLES
		job.path_grid.default_compute_heuristic = AStarGrid2D.HEURISTIC_OCTILE
		job.path_grid.default_estimate_heuristic = AStarGrid2D.HEURISTIC_OCTILE
		job.path_grid.update()
	runtime_agent_grid_build_jobs[cache_key] = job
	runtime_agent_grid_build_order.append(cache_key)
	set_process(true)


func _request_runtime_dynamic_flow_build(
	slot: DynamicFlowTargetSlot,
	target_cell: Vector2i
) -> void:
	if (
		slot == null
		or slot.generation != navigation_generation
		or target_cell == Vector2i.MAX
	):
		return
	var cached_field := _get_cached_flow_field(
		target_cell,
		slot.normalized_extents,
		slot.traversal_types
	)
	if not cached_field.is_empty():
		_publish_dynamic_flow_slot(slot, target_cell, cached_field)
		return

	var needs_first_field := slot.published_field.is_empty()
	var job := _get_or_create_runtime_flow_build_job(
		target_cell,
		slot.normalized_extents,
		slot.traversal_types,
		slot.path_grid,
		needs_first_field
	)
	job.waiting_dynamic_slots[slot.slot_key] = true
	slot.pending_job_key = job.cache_key
	set_process(true)


func _request_runtime_fixed_flow_build(
	target_cell: Vector2i,
	normalized_extents: Vector2,
	traversal_types: int,
	path_grid: AStarGrid2D
) -> void:
	var job := _get_or_create_runtime_flow_build_job(
		target_cell,
		normalized_extents,
		traversal_types,
		path_grid,
		true
	)
	job.publish_to_fixed_cache = true
	set_process(true)


func _get_or_create_runtime_flow_build_job(
	target_cell: Vector2i,
	normalized_extents: Vector2,
	traversal_types: int,
	path_grid: AStarGrid2D,
	urgent: bool
) -> RuntimeFlowBuildJob:
	var cache_key := _get_flow_field_cache_key(
		target_cell,
		normalized_extents,
		traversal_types
	)
	var job := runtime_flow_build_jobs.get(cache_key) as RuntimeFlowBuildJob
	if job != null:
		if urgent and not job.urgent:
			job.urgent = true
			runtime_flow_build_order.erase(cache_key)
			_insert_runtime_flow_job_key(cache_key, true)
		return job

	job = RuntimeFlowBuildJob.new()
	job.generation = navigation_generation
	job.cache_key = cache_key
	job.target_cell = target_cell
	job.normalized_extents = normalized_extents
	job.traversal_types = traversal_types
	job.path_grid = path_grid
	job.urgent = urgent
	for _bucket_index in range(FLOW_BUCKET_COUNT):
		job.pending_buckets.append([])
	job.next_cells[target_cell] = target_cell
	job.distances[target_cell] = 0
	var first_bucket := job.pending_buckets[0] as Array
	first_bucket.append(target_cell)
	job.pending_entry_count = 1
	runtime_flow_build_jobs[cache_key] = job
	_insert_runtime_flow_job_key(cache_key, urgent)
	return job


func _insert_runtime_flow_job_key(cache_key: String, urgent: bool) -> void:
	if not urgent:
		runtime_flow_build_order.append(cache_key)
		return
	# Urgent jobs remain FIFO among themselves and are inserted immediately
	# before refresh jobs. A stream of newly joined profiles therefore cannot
	# perpetually restart or starve the first cold target.
	var insertion_index := 0
	while insertion_index < runtime_flow_build_order.size():
		var queued_job := runtime_flow_build_jobs.get(
			runtime_flow_build_order[insertion_index]
		) as RuntimeFlowBuildJob
		if queued_job == null or not queued_job.urgent:
			break
		insertion_index += 1
	runtime_flow_build_order.insert(insertion_index, cache_key)


func _advance_runtime_navigation_jobs() -> void:
	var started_usec := Time.get_ticks_usec()
	var deadline_usec := started_usec + maxi(runtime_navigation_time_budget_usec, 100)
	var maximum_expansions := maxi(runtime_navigation_max_expansions_per_frame, 1)
	var expansions := 0
	var attempts_since_time_check := 0

	while expansions < maximum_expansions:
		var advanced := false
		var urgent_flow_waiting := false
		if not runtime_flow_build_order.is_empty():
			var first_flow_job := runtime_flow_build_jobs.get(
				runtime_flow_build_order[0]
			) as RuntimeFlowBuildJob
			urgent_flow_waiting = first_flow_job != null and first_flow_job.urgent
		if urgent_flow_waiting and not runtime_agent_grid_build_order.is_empty():
			# A ready-grid cold flow and a newly joined body profile are equally
			# urgent. Alternate individual scheduler steps so neither can starve
			# the other while both still share the same global time deadline.
			if runtime_navigation_prefers_urgent_flow:
				advanced = _advance_first_runtime_flow_job()
			else:
				advanced = _advance_first_runtime_agent_grid_job()
			runtime_navigation_prefers_urgent_flow = (
				not runtime_navigation_prefers_urgent_flow
			)
		elif urgent_flow_waiting:
			advanced = _advance_first_runtime_flow_job()
		elif not runtime_agent_grid_build_order.is_empty():
			advanced = _advance_first_runtime_agent_grid_job()
		elif not runtime_flow_build_order.is_empty():
			advanced = _advance_first_runtime_flow_job()
		else:
			break
		if advanced:
			expansions += 1
		attempts_since_time_check += 1
		# Checking every four expansions keeps overshoot close to the authored
		# deadline even on Dictionary-heavy corner cells. These jobs are rare and
		# staged, so the tiny clock-read cost is preferable to a hidden 2 ms spike.
		if attempts_since_time_check >= 4:
			attempts_since_time_check = 0
			if Time.get_ticks_usec() >= deadline_usec:
				break

	runtime_navigation_expansions_last_frame = expansions
	runtime_navigation_build_usec_last_frame = int(Time.get_ticks_usec() - started_usec)
	runtime_navigation_build_usec_peak = maxi(
		runtime_navigation_build_usec_peak,
		runtime_navigation_build_usec_last_frame
	)
	_prune_dynamic_flow_slots(false)
	if (
		runtime_agent_grid_build_order.is_empty()
		and runtime_flow_build_order.is_empty()
	):
		set_process(false)


func _advance_first_runtime_agent_grid_job() -> bool:
	if runtime_agent_grid_build_order.is_empty():
		return false
	var cache_key := runtime_agent_grid_build_order[0]
	var job := runtime_agent_grid_build_jobs.get(cache_key) as RuntimeAgentGridBuildJob
	if job == null or job.generation != navigation_generation:
		_remove_runtime_agent_grid_job(cache_key)
		return false
	var region := job.path_grid.region
	var total_cells := region.size.x * region.size.y
	if not job.grid_cells_completed:
		if job.next_cell_index < total_cells:
			var cell := Vector2i(
				region.position.x + job.next_cell_index % region.size.x,
				region.position.y + floori(
					float(job.next_cell_index) / float(region.size.x)
				)
			)
			job.path_grid.set_point_solid(
				cell,
				_is_cell_blocked_for_agent(
					cell,
					job.normalized_extents,
					job.traversal_types
				)
			)
			job.next_cell_index += 1
			if job.next_cell_index < total_cells:
				return true
		job.grid_cells_completed = true

	if job.solid_integral_snapshot == null:
		job.solid_integral_snapshot = _create_empty_agent_solid_integral_snapshot(
			job.path_grid
		)
		return true

	if job.next_integral_cell_index < total_cells:
		_write_agent_solid_integral_cell(
			job.solid_integral_snapshot,
			job.path_grid,
			job.next_integral_cell_index
		)
		job.next_integral_cell_index += 1
		if job.next_integral_cell_index < total_cells:
			return true

	_store_agent_open_plain_integral_snapshot(
		cache_key,
		job.solid_integral_snapshot
	)
	if job.publish_path_grid_to_cache:
		agent_grid_cache[cache_key] = job.path_grid
	_remove_runtime_agent_grid_job(cache_key)
	return true


func _advance_first_runtime_flow_job() -> bool:
	if runtime_flow_build_order.is_empty():
		return false
	var cache_key := runtime_flow_build_order[0]
	var job := runtime_flow_build_jobs.get(cache_key) as RuntimeFlowBuildJob
	if job == null or job.generation != navigation_generation:
		_cancel_runtime_flow_build_job(cache_key)
		return false

	while job.pending_entry_count > 0:
		var bucket_index := job.current_distance % FLOW_BUCKET_COUNT
		var bucket := job.pending_buckets[bucket_index] as Array
		if bucket.is_empty():
			job.current_distance += 1
			continue
		var current_cell := bucket.pop_back() as Vector2i
		job.pending_entry_count -= 1
		if int(job.distances.get(current_cell, -1)) != job.current_distance:
			# A cell whose tentative distance improved leaves one stale bucket
			# entry behind. Consume only one entry per scheduler step so a large
			# stale tail can never escape the global time/expansion budget.
			if job.pending_entry_count <= 0:
				_complete_runtime_flow_build_job(job)
			return true
		for direction in FLOW_DIRECTIONS:
			var neighbor := current_cell + direction
			if not _is_safe_flow_transition(current_cell, direction, job.path_grid):
				continue
			var candidate_distance := (
				job.current_distance + _get_flow_transition_cost(direction)
			)
			if candidate_distance >= int(job.distances.get(neighbor, 2147483647)):
				continue
			job.distances[neighbor] = candidate_distance
			job.next_cells[neighbor] = current_cell
			var target_bucket := (
				job.pending_buckets[candidate_distance % FLOW_BUCKET_COUNT] as Array
			)
			target_bucket.append(neighbor)
			job.pending_entry_count += 1
		if job.pending_entry_count <= 0:
			_complete_runtime_flow_build_job(job)
		return true

	_complete_runtime_flow_build_job(job)
	return false


func _complete_runtime_flow_build_job(job: RuntimeFlowBuildJob) -> void:
	if job == null:
		return
	var field := {
		"target_cell": job.target_cell,
		"next_cells": job.next_cells,
		"distances": job.distances,
	}
	if job.publish_to_fixed_cache:
		_store_flow_field(
			job.target_cell,
			job.normalized_extents,
			job.traversal_types,
			field
		)
	var published_slots: Array[DynamicFlowTargetSlot] = []
	for slot_key_variant in job.waiting_dynamic_slots:
		var slot_key := String(slot_key_variant)
		var slot := dynamic_flow_target_slots.get(slot_key) as DynamicFlowTargetSlot
		if (
			slot == null
			or slot.generation != navigation_generation
			or slot.pending_job_key != job.cache_key
		):
			continue
		_publish_dynamic_flow_slot(slot, job.target_cell, field)
		published_slots.append(slot)
	runtime_flow_builds_completed += 1
	_remove_runtime_flow_build_job(job.cache_key)
	# Coalesce every target update that arrived during the build into at most one
	# successor request. The just-published complete field remains active while
	# that successor is built; no half-field is ever visible to an enemy.
	for slot in published_slots:
		_update_dynamic_flow_slot_request(
			slot,
			slot.desired_original_cell,
			slot.desired_resolved_cell
		)


func _remove_runtime_agent_grid_job(cache_key: String) -> void:
	runtime_agent_grid_build_jobs.erase(cache_key)
	runtime_agent_grid_build_order.erase(cache_key)


func _remove_runtime_flow_build_job(cache_key: String) -> void:
	runtime_flow_build_jobs.erase(cache_key)
	runtime_flow_build_order.erase(cache_key)


func _cancel_runtime_flow_build_job(cache_key: String) -> void:
	var job := runtime_flow_build_jobs.get(cache_key) as RuntimeFlowBuildJob
	if job != null:
		for slot_key_variant in job.waiting_dynamic_slots:
			var slot := dynamic_flow_target_slots.get(
				String(slot_key_variant)
			) as DynamicFlowTargetSlot
			if slot != null and slot.pending_job_key == cache_key:
				slot.pending_job_key = ""
		runtime_flow_builds_cancelled += 1
	_remove_runtime_flow_build_job(cache_key)


func _cancel_all_runtime_navigation_jobs() -> void:
	runtime_flow_builds_cancelled += runtime_flow_build_jobs.size()
	runtime_flow_build_jobs.clear()
	runtime_flow_build_order.clear()
	runtime_agent_grid_build_jobs.clear()
	runtime_agent_grid_build_order.clear()
	runtime_navigation_prefers_urgent_flow = true
	set_process(false)


func _remove_dynamic_flow_slot(slot_key: String) -> void:
	var slot := dynamic_flow_target_slots.get(slot_key) as DynamicFlowTargetSlot
	if slot == null:
		return
	if slot.pending_job_key != "":
		var job := runtime_flow_build_jobs.get(
			slot.pending_job_key
		) as RuntimeFlowBuildJob
		if job != null:
			job.waiting_dynamic_slots.erase(slot_key)
			if (
				job.waiting_dynamic_slots.is_empty()
				and not job.publish_to_fixed_cache
			):
				_cancel_runtime_flow_build_job(job.cache_key)
	dynamic_flow_target_slots.erase(slot_key)


func _prune_dynamic_flow_slots(force_capacity: bool) -> void:
	if dynamic_flow_target_slots.is_empty():
		return
	var current_frame := Engine.get_physics_frames()
	var ttl_frames := maxi(
		ceili(
			dynamic_target_slot_ttl_seconds
			* float(maxi(Engine.physics_ticks_per_second, 1))
		),
		1
	)
	var removable_keys: Array[String] = []
	var oldest_key := ""
	var oldest_frame := 2147483647
	for slot_key_variant in dynamic_flow_target_slots:
		var slot_key := String(slot_key_variant)
		var slot := dynamic_flow_target_slots.get(slot_key) as DynamicFlowTargetSlot
		if slot == null:
			removable_keys.append(slot_key)
			continue
		var target: Object = (
			slot.target_reference.get_ref()
			if slot.target_reference != null
			else null
		)
		if (
			target == null
			or not is_instance_valid(target)
			or current_frame - slot.last_request_physics_frame >= ttl_frames
		):
			removable_keys.append(slot_key)
			continue
		if slot.last_request_physics_frame < oldest_frame:
			oldest_frame = slot.last_request_physics_frame
			oldest_key = slot_key
	for slot_key in removable_keys:
		_remove_dynamic_flow_slot(slot_key)
	if (
		force_capacity
		and dynamic_flow_target_slots.size() >= maxi(max_dynamic_target_slots, 1)
		and oldest_key != ""
		and current_frame - oldest_frame > 2
	):
		_remove_dynamic_flow_slot(oldest_key)


func _get_or_create_agent_grid(
	agent_half_extents: Vector2,
	traversal_types: int = DEFAULT_TRAVERSAL_TYPES
) -> AStarGrid2D:
	if agent_half_extents == Vector2.ZERO and traversal_types == DEFAULT_TRAVERSAL_TYPES:
		var default_cache_key := _get_agent_grid_cache_key(
			Vector2.ZERO,
			DEFAULT_TRAVERSAL_TYPES
		)
		if _get_agent_open_plain_integral_snapshot(default_cache_key) == null:
			_store_agent_open_plain_integral_snapshot(
				default_cache_key,
				_build_agent_solid_integral_snapshot(astar_grid)
			)
		return astar_grid

	var cache_key := _get_agent_grid_cache_key(agent_half_extents, traversal_types)
	var cached_grid := agent_grid_cache.get(cache_key) as AStarGrid2D
	if cached_grid != null:
		if _get_agent_open_plain_integral_snapshot(cache_key) == null:
			_store_agent_open_plain_integral_snapshot(
				cache_key,
				_build_agent_solid_integral_snapshot(cached_grid)
			)
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

	_store_agent_open_plain_integral_snapshot(
		cache_key,
		_build_agent_solid_integral_snapshot(agent_grid)
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
		path_grid = (
			_get_runtime_agent_grid_or_enqueue(normalized_extents, traversal_types)
			if uses_build_budget
			else _get_or_create_agent_grid(normalized_extents, traversal_types)
		)
		if path_grid == null:
			result.reset(
				NavigationStepStatus.DEFERRED,
				original_from_cell,
				original_target_cell
			)
			return
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
				var job_key := _get_flow_field_cache_key(
					target_cell,
					normalized_extents,
					traversal_types
				)
				if not runtime_flow_build_jobs.has(job_key):
					_refresh_flow_field_budget_frame()
					if flow_field_builds_used_this_frame >= maxi(
						max_flow_field_builds_per_physics_frame,
						1
					):
						result.reset(
							NavigationStepStatus.DEFERRED,
							original_from_cell,
							original_target_cell
						)
						result.resolved_target_cell = target_cell
						return
					flow_field_builds_used_this_frame += 1
				_request_runtime_fixed_flow_build(
					target_cell,
					normalized_extents,
					traversal_types,
					path_grid
				)
				result.reset(
					NavigationStepStatus.DEFERRED,
					original_from_cell,
					original_target_cell
				)
				result.resolved_target_cell = target_cell
				return
			else:
				field = _build_flow_field(target_cell, path_grid)
				_store_flow_field(
					target_cell,
					normalized_extents,
					traversal_types,
					field
				)

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
	_write_navigation_step_from_flow_field(
		result,
		from_global_position,
		to_global_position,
		original_from_cell,
		original_target_cell,
		target_cell,
		normalized_extents,
		traversal_types,
		path_grid,
		next_cells,
		distances
	)


func _write_navigation_step_from_flow_field(
	result: NavigationStepResult,
	from_global_position: Vector2,
	field_target_position: Vector2,
	original_from_cell: Vector2i,
	original_target_cell: Vector2i,
	target_cell: Vector2i,
	normalized_extents: Vector2,
	traversal_types: int,
	path_grid: AStarGrid2D,
	next_cells: Dictionary,
	distances: Dictionary
) -> void:
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
	result.remaining_cell_distance = ceili(
		float(route_distance + recovery_cost) / float(FLOW_ORTHOGONAL_COST)
	)

	if used_start_recovery:
		result.waypoint = _map_to_global(recovery_waypoint_cell)
		return

	if flow_next_cell != from_cell:
		result.waypoint = _map_to_global(flow_next_cell)
		return

	var resolved_target_position := _map_to_global(target_cell)
	if _is_global_position_walkable_for_agent(
		field_target_position,
		normalized_extents,
		traversal_types
	):
		result.waypoint = field_target_position
		if from_global_position.distance_squared_to(field_target_position) <= 0.25:
			result.status = NavigationStepStatus.ARRIVED
		return

	result.waypoint = resolved_target_position
	if from_global_position.distance_squared_to(resolved_target_position) <= 0.25:
		result.status = NavigationStepStatus.ARRIVED


func _write_dynamic_target_navigation_step(
	result: NavigationStepResult,
	context: FlowQueryContext,
	from_global_position: Vector2,
	target_node: Node2D,
	agent_half_extents: Vector2,
	traversal_types: int
) -> void:
	if result == null:
		return
	if not is_built:
		result.reset(NavigationStepStatus.DEFERRED)
		return
	if target_node == null or not is_instance_valid(target_node):
		result.reset(NavigationStepStatus.UNREACHABLE)
		if context != null:
			context.invalidate()
		return

	var normalized_extents := _normalize_agent_half_extents(agent_half_extents)
	var original_from_cell := _global_to_map(from_global_position)
	var target_position := target_node.global_position
	var original_target_cell := _global_to_map(target_position)
	var path_grid := _get_runtime_agent_grid_or_enqueue(
		normalized_extents,
		traversal_types
	)
	if path_grid == null:
		result.reset(
			NavigationStepStatus.DEFERRED,
			original_from_cell,
			original_target_cell
		)
		return

	var slot := _get_or_create_dynamic_flow_slot(
		target_node,
		normalized_extents,
		traversal_types,
		path_grid
	)
	if slot == null:
		result.reset(
			NavigationStepStatus.DEFERRED,
			original_from_cell,
			original_target_cell
		)
		return
	var desired_target_cell := slot.desired_resolved_cell
	if (
		slot.desired_original_cell != original_target_cell
		or desired_target_cell == Vector2i.MAX
	):
		desired_target_cell = _get_closest_walkable_cell(
			original_target_cell,
			path_grid
		)
	if desired_target_cell == Vector2i.MAX:
		_remove_dynamic_flow_slot(slot.slot_key)
		result.reset(
			NavigationStepStatus.UNREACHABLE,
			original_from_cell,
			original_target_cell
		)
		if context != null:
			context.invalidate()
		return
	_update_dynamic_flow_slot_request(
		slot,
		original_target_cell,
		desired_target_cell
	)

	if slot.published_field.is_empty():
		result.reset(
			NavigationStepStatus.DEFERRED,
			original_from_cell,
			original_target_cell
		)
		result.resolved_target_cell = desired_target_cell
		_bind_dynamic_flow_query_context(
			context,
			slot,
			target_position,
			original_target_cell
		)
		return

	var next_cells := slot.published_field.get("next_cells", {}) as Dictionary
	var distances := slot.published_field.get("distances", {}) as Dictionary
	if next_cells.is_empty() or distances.is_empty():
		result.reset(
			NavigationStepStatus.DEFERRED,
			original_from_cell,
			original_target_cell
		)
		return

	_bind_dynamic_flow_query_context(
		context,
		slot,
		target_position,
		original_target_cell
	)
	# A published dynamic field always terminates at its immutable anchor. The
	# current player position is deliberately not substituted here: only the
	# Enemy's full-body line-of-sight sweep may approve a direct final segment.
	_write_navigation_step_from_flow_field(
		result,
		from_global_position,
		_map_to_global(slot.published_anchor_cell),
		original_from_cell,
		original_target_cell,
		slot.published_anchor_cell,
		normalized_extents,
		traversal_types,
		path_grid,
		next_cells,
		distances
	)


func _get_or_create_dynamic_flow_slot(
	target_node: Node2D,
	normalized_extents: Vector2,
	traversal_types: int,
	path_grid: AStarGrid2D
) -> DynamicFlowTargetSlot:
	var slot_key := _get_dynamic_flow_slot_key(
		target_node.get_instance_id(),
		normalized_extents,
		traversal_types
	)
	var slot := dynamic_flow_target_slots.get(slot_key) as DynamicFlowTargetSlot
	if slot != null:
		var referenced_target: Object = (
			slot.target_reference.get_ref()
			if slot.target_reference != null
			else null
		)
		if (
			slot.generation == navigation_generation
			and referenced_target == target_node
			and slot.path_grid == path_grid
		):
			return slot
		_remove_dynamic_flow_slot(slot_key)

	_prune_dynamic_flow_slots(true)
	if dynamic_flow_target_slots.size() >= maxi(max_dynamic_target_slots, 1):
		return null
	slot = DynamicFlowTargetSlot.new()
	slot.generation = navigation_generation
	slot.slot_key = slot_key
	slot.target_instance_id = target_node.get_instance_id()
	slot.target_reference = weakref(target_node)
	slot.normalized_extents = normalized_extents
	slot.traversal_types = traversal_types
	slot.path_grid = path_grid
	dynamic_flow_target_slots[slot_key] = slot
	return slot


func _update_dynamic_flow_slot_request(
	slot: DynamicFlowTargetSlot,
	original_target_cell: Vector2i,
	desired_target_cell: Vector2i
) -> void:
	var current_physics_frame := Engine.get_physics_frames()
	slot.last_request_physics_frame = current_physics_frame
	slot.desired_original_cell = original_target_cell
	slot.desired_resolved_cell = desired_target_cell

	if slot.published_field.is_empty():
		# Loading prewarm stores the initial player field in the fixed cache. Adopt
		# that immutable dictionary once, then keep later moving fields out of the
		# fixed-objective LRU so player footsteps cannot evict Home fields.
		var prewarmed_field := _get_cached_flow_field(
			desired_target_cell,
			slot.normalized_extents,
			slot.traversal_types
		)
		if not prewarmed_field.is_empty():
			_publish_dynamic_flow_slot(
				slot,
				desired_target_cell,
				prewarmed_field
			)

	if slot.pending_job_key != "":
		return
	if slot.published_field.is_empty():
		_request_runtime_dynamic_flow_build(slot, desired_target_cell)
		return
	if desired_target_cell == slot.published_anchor_cell:
		return

	var anchor_distance := _chebyshev_cell_distance(
		slot.published_anchor_cell,
		desired_target_cell
	)
	var maximum_age_frames := maxi(
		ceili(
			dynamic_target_max_anchor_age_seconds
			* float(maxi(Engine.physics_ticks_per_second, 1))
		),
		1
	)
	var anchor_age := current_physics_frame - slot.published_physics_frame
	if (
		anchor_distance >= maxi(dynamic_target_repath_distance_cells, 1)
		or anchor_age >= maximum_age_frames
	):
		_request_runtime_dynamic_flow_build(slot, desired_target_cell)


func _publish_dynamic_flow_slot(
	slot: DynamicFlowTargetSlot,
	anchor_cell: Vector2i,
	field: Dictionary
) -> void:
	if slot == null or field.is_empty():
		return
	slot.published_anchor_cell = anchor_cell
	slot.published_field = field
	slot.published_revision += 1
	slot.published_physics_frame = Engine.get_physics_frames()
	slot.pending_job_key = ""


func _bind_dynamic_flow_query_context(
	context: FlowQueryContext,
	slot: DynamicFlowTargetSlot,
	requested_target_position: Vector2,
	original_target_cell: Vector2i
) -> void:
	if context == null or slot == null:
		return
	context.generation = navigation_generation
	context.target_is_static = false
	context.requested_target_position = requested_target_position
	context.original_target_cell = original_target_cell
	context.resolved_target_cell = slot.published_anchor_cell
	context.normalized_extents = slot.normalized_extents
	context.traversal_types = slot.traversal_types
	# Dynamic contexts store only the shared slot revision, not the large field
	# dictionaries. Replacing a slot therefore releases the old field once and
	# cannot be kept alive by hundreds of dormant enemies.
	if (
		context.path_grid != null
		or not context.next_cells.is_empty()
		or not context.distances.is_empty()
	):
		context.path_grid = null
		context.next_cells = {}
		context.distances = {}
	context.dynamic_slot_key = slot.slot_key
	context.dynamic_slot_revision = slot.published_revision


func _get_dynamic_flow_slot_key(
	target_instance_id: int,
	normalized_extents: Vector2,
	traversal_types: int
) -> String:
	return "%d:%s" % [
		target_instance_id,
		_get_agent_grid_cache_key(normalized_extents, traversal_types),
	]


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


func _build_agent_solid_integral_snapshot(
	path_grid: AStarGrid2D
) -> AgentSolidIntegralSnapshot:
	var snapshot := _create_empty_agent_solid_integral_snapshot(path_grid)
	if snapshot == null:
		return null
	var total_cells := path_grid.region.size.x * path_grid.region.size.y
	for cell_index in range(total_cells):
		_write_agent_solid_integral_cell(snapshot, path_grid, cell_index)
	return snapshot


func _create_empty_agent_solid_integral_snapshot(
	path_grid: AStarGrid2D
) -> AgentSolidIntegralSnapshot:
	if path_grid == null:
		return null
	var snapshot := AgentSolidIntegralSnapshot.new()
	snapshot.generation = navigation_generation
	snapshot.region = path_grid.region
	snapshot.stride = path_grid.region.size.x + 1
	snapshot.values.resize(
		(path_grid.region.size.x + 1) * (path_grid.region.size.y + 1)
	)
	snapshot.values.fill(0)
	return snapshot


func _write_agent_solid_integral_cell(
	snapshot: AgentSolidIntegralSnapshot,
	path_grid: AStarGrid2D,
	cell_index: int
) -> void:
	if snapshot == null or path_grid == null:
		return
	var width := snapshot.region.size.x
	var total_cells := width * snapshot.region.size.y
	if cell_index < 0 or cell_index >= total_cells:
		return
	var local_x := cell_index % width
	var local_y := floori(float(cell_index) / float(width))
	var cell := snapshot.region.position + Vector2i(local_x, local_y)
	var prefix_x := local_x + 1
	var prefix_y := local_y + 1
	var destination_index := prefix_y * snapshot.stride + prefix_x
	var solid_value := 1 if path_grid.is_point_solid(cell) else 0
	snapshot.values[destination_index] = (
		solid_value
		+ snapshot.values[(prefix_y - 1) * snapshot.stride + prefix_x]
		+ snapshot.values[prefix_y * snapshot.stride + prefix_x - 1]
		- snapshot.values[(prefix_y - 1) * snapshot.stride + prefix_x - 1]
	)


func _store_agent_open_plain_integral_snapshot(
	cache_key: String,
	snapshot: AgentSolidIntegralSnapshot
) -> void:
	if (
		cache_key.is_empty()
		or snapshot == null
		or snapshot.generation != navigation_generation
	):
		return
	agent_open_plain_integral_cache[cache_key] = snapshot


func _get_agent_open_plain_integral_snapshot(
	cache_key: String
) -> AgentSolidIntegralSnapshot:
	var snapshot := agent_open_plain_integral_cache.get(
		cache_key
	) as AgentSolidIntegralSnapshot
	if (
		snapshot == null
		or snapshot.generation != navigation_generation
		or snapshot.region != astar_grid.region
		or snapshot.stride != snapshot.region.size.x + 1
		or snapshot.values.size()
			!= (snapshot.region.size.x + 1) * (snapshot.region.size.y + 1)
	):
		return null
	return snapshot


func _get_agent_solid_count_in_cell_rect(
	snapshot: AgentSolidIntegralSnapshot,
	minimum_cell: Vector2i,
	maximum_cell: Vector2i
) -> int:
	if snapshot == null:
		return 0
	var local_minimum := minimum_cell - snapshot.region.position
	var local_maximum := maximum_cell - snapshot.region.position
	var prefix_left := local_minimum.x
	var prefix_top := local_minimum.y
	var prefix_right := local_maximum.x + 1
	var prefix_bottom := local_maximum.y + 1
	return (
		snapshot.values[prefix_bottom * snapshot.stride + prefix_right]
		- snapshot.values[prefix_top * snapshot.stride + prefix_right]
		- snapshot.values[prefix_bottom * snapshot.stride + prefix_left]
		+ snapshot.values[prefix_top * snapshot.stride + prefix_left]
	)


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
