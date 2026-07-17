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
const FLOW_DISTANCE_INFINITY := 2147483647
const FLOW_NO_CELL_INDEX := -1
const RUNTIME_FLOW_MATERIALIZE_BATCH_CELLS := 16
const RUNTIME_FLOW_JOB_QUANTUM_STEPS := 8
const FORWARD_OBSTACLE_LOOKAHEAD_SEGMENTS := 2
const MAX_FLOW_RECOVERY_CACHE_ENTRIES := 512
const DEFAULT_TRAVERSAL_TYPES := DualGridTilemap.TraversalType.LAND
const NAVIGATION_CELL_OBSTACLE_FLAG := 1 << 7
const NAVIGATION_CELL_TRAVERSAL_MASK := NAVIGATION_CELL_OBSTACLE_FLAG - 1

enum NavigationStepStatus {
	READY,
	ARRIVED,
	DEFERRED,
	UNREACHABLE,
}

enum RuntimeFlowJobPriority {
	BACKGROUND,
	STATIC_OBJECTIVE,
	DYNAMIC_TARGET,
}

# Preserve the latency advantage of moving-player fields without allowing a
# continuously retargeting cohort to starve fixed objectives or optional
# coverage forever. Missing bands fall back to the highest queued priority, so
# a dynamic-only queue still receives every scheduler slice.
const RUNTIME_FLOW_PRIORITY_SERVICE_CYCLE: Array[int] = [
	RuntimeFlowJobPriority.DYNAMIC_TARGET,
	RuntimeFlowJobPriority.DYNAMIC_TARGET,
	RuntimeFlowJobPriority.DYNAMIC_TARGET,
	RuntimeFlowJobPriority.STATIC_OBJECTIVE,
	RuntimeFlowJobPriority.DYNAMIC_TARGET,
	RuntimeFlowJobPriority.DYNAMIC_TARGET,
	RuntimeFlowJobPriority.DYNAMIC_TARGET,
	RuntimeFlowJobPriority.BACKGROUND,
]


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
	# Dynamic fields are immutable while a replacement is built. Consumers use
	# this bit as freshness telemetry and to prefer a certified live correction;
	# it must never invalidate an otherwise complete, collision-safe old route.
	var dynamic_anchor_is_stale: bool = false

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
		dynamic_anchor_is_stale = false


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
	var target_contact_radius_world: float = 0.0
	var path_grid: AStarGrid2D = null
	var desired_original_cell: Vector2i = Vector2i.MAX
	var desired_resolved_cell: Vector2i = Vector2i.MAX
	var desired_target_position: Vector2 = Vector2.ZERO
	var desired_goal_cells: Array[Vector2i] = []
	var desired_goal_signature: String = ""
	var desired_goal_evaluation_valid: bool = false
	var desired_build_region: Rect2i = Rect2i()
	var published_anchor_cell: Vector2i = Vector2i.MAX
	var published_goal_cells: Array[Vector2i] = []
	var published_goal_lookup: Dictionary = {}
	var published_goal_signature: String = ""
	var published_build_region: Rect2i = Rect2i()
	var published_field: Dictionary = {}
	var previous_published_anchor_cell: Vector2i = Vector2i.MAX
	var previous_published_goal_cells: Array[Vector2i] = []
	var previous_published_build_region: Rect2i = Rect2i()
	var previous_published_field: Dictionary = {}
	var previous_retained_physics_frame: int = -1
	var previous_published_revision: int = -1
	var published_revision: int = 0
	var published_physics_frame: int = -1
	var pending_job_key: String = ""
	var last_request_physics_frame: int = -1
	var pending_retargets_since_publish: int = 0


class RuntimeFlowBuildJob:
	var generation: int = -1
	var cache_key: String = ""
	var target_cell: Vector2i = Vector2i.MAX
	var target_cells: Array[Vector2i] = []
	var dynamic_target_original_cell: Vector2i = Vector2i.MAX
	var expansion_region: Rect2i = Rect2i()
	var normalized_extents: Vector2 = Vector2.ZERO
	var traversal_types: int = 0
	var path_grid: AStarGrid2D = null
	var next_cells: Dictionary = {}
	var distances: Dictionary = {}
	# Runtime Dijkstra builds use region-local packed indices while they are hot.
	# The published compatibility field is materialized in bounded batches after
	# search, avoiding Vector2i hash lookups without creating a completion spike.
	var uses_packed_storage: bool = false
	var packed_region_width: int = 0
	var packed_distances: PackedInt32Array = PackedInt32Array()
	var packed_next_indices: PackedInt32Array = PackedInt32Array()
	var discovered_cell_count: int = 0
	var solid_snapshot: AgentSolidIntegralSnapshot = null
	var search_completed: bool = false
	var next_materialize_cell_index: int = 0
	var pending_buckets: Array = []
	var pending_entry_count: int = 0
	var current_distance: int = 0
	var waiting_dynamic_slots: Dictionary = {}
	var publish_to_fixed_cache: bool = false
	var urgent: bool = false
	var priority: int = RuntimeFlowJobPriority.BACKGROUND
	var scheduler_steps_since_yield: int = 0
	var complete_when_required_sources_reached: bool = false
	var required_source_cells: Dictionary = {}
	var remaining_required_source_cells: Dictionary = {}
	var completed_by_required_coverage: bool = false


class AgentSolidIntegralSnapshot:
	var generation: int = -1
	var region: Rect2i = Rect2i()
	var stride: int = 0
	var values: PackedInt32Array = PackedInt32Array()
	# Runtime flow jobs need the same per-agent solidity data without repeated
	# AStarGrid2D method calls. It is built atomically beside the prefix sums.
	var solid_cells: PackedByteArray = PackedByteArray()
	var transition_masks: PackedByteArray = PackedByteArray()


class AgentNavigationProfile:
	var generation: int = -1
	var cache_key: String = ""
	var normalized_extents: Vector2 = Vector2.ZERO
	var traversal_types: int = 0
	var path_grid: AStarGrid2D = null
	var solid_integral_snapshot: AgentSolidIntegralSnapshot = null


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
	var next_transition_cell_index: int = 0

@export var obstacle_tile_layer_path: NodePath = ^"../GroundTileMapLayer"
@export var terrain_map_path: NodePath
# 用于检测阻挡的碰撞层索引
@export var tile_physics_layer_index: int = 0
# Only an isolated fixture whose World layer contains no non-TileMap bodies may
# enable this. Production scenes also contain merchant/boundary StaticBody2D
# nodes, so projectile collision must retain its exact Physics2D fallback.
@export var world_collision_layer_exclusive_to_authored_tiles := false
# Legacy full-path callers are complete-only by default. Partial routes remain
# opt-in for diagnostics and are never accepted by the safe-step API.
@export var allow_partial_path: bool = false
# 搜索最近可行走格子的最大半径
@export var max_nearest_cell_search_radius: int = 6
# Kept under the original exported name for scene compatibility. The counter is
# now reset by rendered/process frame, so physics catch-up ticks share one cap.
@export_range(1, 128, 1, "or_greater") var max_path_queries_per_physics_frame: int = 12
# 敌人体积寻路按实际碰撞外接尺寸计算；需要覆盖 CharacterBody2D.safe_margin，
# 否则刚好贴边的格子会被寻路视为可走，但 move_and_slide() 会在碰撞恢复中卡住。
@export var agent_clearance_padding: float = 0.1
# Likewise, registrations are capped per rendered/process frame rather than per
# physics tick. Actual construction remains governed by the microsecond budget.
@export_range(1, 128, 1, "or_greater") var max_flow_field_builds_per_physics_frame: int = 4
# Direction refreshes are normally spread over six physics phases (about 50
# refreshes per render frame for 300 enemies). A visible frame that catches up
# several physics ticks must not merge all six phases into one 300-agent spike.
# Deferred agents retain their last verified direction and retry next render
# frame, while movement itself continues at the authored physics rate.
@export_range(1, 512, 1, "or_greater") var max_agent_navigation_refreshes_per_process_frame: int = 64
# flow field 按“敌人体型 + 目标格”缓存，限制上限避免长局无限增长。
@export_range(1, 256, 1, "or_greater") var max_flow_field_cache_entries: int = 48
# 动态目标的运行期建图必须切成有上限的小片，绝不允许在敌人物理帧中
# 同步遍历整张地图。格数与时间任一先到即让出主线程。
@export_range(16, 4096, 1, "or_greater") var runtime_navigation_max_expansions_per_frame: int = 192
@export_range(100, 8000, 50, "or_greater") var runtime_navigation_time_budget_usec: int = 1000
# Keep an explicit A/B switch until the real-map probes have compared identical
# cohorts. Only in-progress job storage changes; published flow fields retain
# their established Dictionary contract.
@export var runtime_flow_use_packed_build_storage: bool = true
# Integral-certified segments are O(1). Only exact fallbacks near an obstacle
# consume this per-render-frame budget; when exhausted, runtime callers receive
# null and fall back to their shared flow field.
@export_range(1, 256, 1, "or_greater") var max_exact_segment_fallbacks_per_render_frame: int = 32
@export_range(100, 8000, 50, "or_greater") var exact_segment_fallback_time_budget_usec: int = 750
# 玩家目标至少偏离已发布锚点两个格子才立即请求新场；若停在相邻格，
# 最迟也会在短暂稳定后刷新。这样不会在每个 16px 格边界制造全图工作。
@export_range(1, 8, 1, "or_greater") var dynamic_target_repath_distance_cells: int = 2
@export_range(0.05, 2.0, 0.05, "or_greater") var dynamic_target_max_anchor_age_seconds: float = 0.25
# A two-cell mismatch requests a refresh. This wider threshold marks when a
# consumer should prefer a separately certified live correction and exposes
# diagnostics; the old complete field remains a valid obstacle route meanwhile.
@export_range(2, 32, 1, "or_greater") var dynamic_target_max_usable_anchor_lag_cells: int = 6
# Tower-defense enemies now select a moving player inside a 10-cell radius. The
# 16-cell field keeps six cells for wall detours and the budgeted retarget
# handoff. Real-map A/B found 14 cells caused an extra coverage publication,
# while 16 cut field work by roughly one third without that churn.
@export_range(8, 64, 1, "or_greater") var dynamic_target_flow_radius_cells: int = 16
# Cell-center clearance grids depend on how many neighboring rows/columns an
# AABB reaches, not on every individual sprite size. Canonicalizing only the
# moving-target profile makes equivalent enemy bodies share one field while
# static Home/objective navigation retains its exact authored extents.
@export var coalesce_dynamic_target_profiles_by_grid_topology: bool = true
@export_range(0.1, 3.0, 0.1, "or_greater") var dynamic_previous_field_retention_seconds: float = 1.0
# A replacement already this far behind the newest requested cell is detached
# and restarted, but only a bounded number of times before one complete
# intermediate field is guaranteed to publish. This prevents a continuously
# moving player from starving every reverse-field build.
@export_range(2, 16, 1, "or_greater") var dynamic_target_pending_retarget_distance_cells: int = 4
@export_range(0, 4, 1, "or_greater") var dynamic_target_max_pending_retargets_before_publish: int = 0
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
var agent_navigation_refresh_budget_process_frame: int = -1
var agent_navigation_refreshes_used_this_frame: int = 0
var agent_navigation_refreshes_admitted_total: int = 0
var agent_navigation_refreshes_deferred_total: int = 0
var agent_navigation_refresh_budget_saturated_frames_total: int = 0
var agent_navigation_refresh_last_saturated_process_frame: int = -1
var agent_navigation_refresh_deferred_queue: Array[int] = []
var agent_navigation_refresh_deferred_queue_head: int = 0
var agent_navigation_refresh_deferred_ids: Dictionary[int, bool] = {}
var agent_navigation_refresh_deferred_since_frame: Dictionary[int, int] = {}
var agent_navigation_refresh_last_request_frame: Dictionary[int, int] = {}
var agent_navigation_refresh_reserved_order: Array[int] = []
var agent_navigation_refresh_reserved_ids: Dictionary[int, bool] = {}
var agent_navigation_refresh_max_wait_process_frames: int = 0
var exact_segment_budget_process_frame: int = -1
var exact_segment_fallbacks_used_this_frame: int = 0
var exact_segment_fallback_usec_used_this_frame: int = 0
var segment_queries_total: int = 0
var segment_integral_hits_total: int = 0
var segment_exact_fallbacks_total: int = 0
var segment_budget_deferrals_total: int = 0
var agent_grid_cache: Dictionary = {}
# Each shared agent profile owns one immutable summed-area table of its solid
# cells. The table is published atomically with the profile grid, so a runtime
# caller can cheaply certify a completely open rectangle without ever observing
# a partially built snapshot.
var agent_open_plain_integral_cache: Dictionary = {}
# Lightweight generation-bound handles let consumers cache one resolved agent
# profile instead of rebuilding a String key and traversing two dictionaries on
# every movement probe.
var agent_navigation_profile_cache: Dictionary = {}
var flow_field_cache: Dictionary = {}
var flow_field_cache_order: Array[String] = []
var flow_recovery_route_cache: Dictionary = {}
var flow_recovery_cache_order: Array[String] = []
var dynamic_flow_target_slots: Dictionary = {}
var dynamic_flow_prefetch_dedupe_frame: int = -1
var dynamic_flow_prefetch_dedupe_generation: int = -1
var dynamic_flow_prefetch_keys_this_frame: Dictionary = {}
var dynamic_flow_prefetch_requests_total: int = 0
var dynamic_flow_prefetch_full_requests_total: int = 0
var dynamic_flow_prefetch_deduplicated_total: int = 0
var dynamic_flow_prefetch_result_scratch := NavigationStepResult.new()
var runtime_flow_build_jobs: Dictionary = {}
var runtime_flow_build_order: Array[String] = []
# Counts for the three contiguous priority bands make every scheduler selection
# O(1). Array movement happens only at an eight-step same-band quantum boundary,
# never once per flow expansion.
var runtime_flow_priority_counts: Array[int] = [0, 0, 0]
var runtime_agent_grid_build_jobs: Dictionary = {}
var runtime_agent_grid_build_order: Array[String] = []
var region_local_rect: Rect2 = Rect2()
var terrain_rebuild_queued: bool = false
var navigation_generation: int = 0
# One byte per base navigation cell. The high bit represents authored collision
# and the low bits store DualGridTilemap.TraversalType flags. TileMap resources
# are sampled only while rebuilding; every steady-state clearance query reads
# this immutable array instead of crossing into TileMapLayer repeatedly.
var raw_navigation_snapshot_generation: int = -1
var raw_navigation_snapshot_region: Rect2i = Rect2i()
var raw_navigation_cell_snapshot: PackedByteArray = PackedByteArray()
# Prefix sums of only the authored TileMap collision bit. Short projectiles can
# use this immutable snapshot to prove an open world segment in O(1), while any
# obstacle, boundary or stale generation retains the exact Physics2D ray.
var raw_obstacle_integral_snapshot: PackedInt32Array = PackedInt32Array()
var raw_obstacle_integral_stride: int = 0
var legacy_navigation_step_scratch := NavigationStepResult.new()
var runtime_navigation_expansions_last_frame: int = 0
var runtime_navigation_build_usec_last_frame: int = 0
var runtime_navigation_build_usec_peak: int = 0
var runtime_flow_builds_completed: int = 0
var runtime_flow_builds_cancelled: int = 0
var runtime_navigation_prefers_urgent_flow: bool = true
var runtime_flow_priority_service_cursor: int = 0


# 在节点进入场景树时调用，初始化寻路网格
func _ready() -> void:
	rebuild()
	set_process(false)


func _process(_delta: float) -> void:
	_advance_runtime_navigation_jobs()


# 重新构建寻路网格数据。所有公开调用都会开启新 generation；只有 terrain
# signal 已同步失效旧数据后，私有 deferred 路径才可复用当前 generation。
func rebuild() -> void:
	_rebuild_navigation_snapshot(true)
	if is_built:
		# An explicit rebuild already sampled every live terrain cell. Cancel any
		# older deferred callback; it will observe false and become a no-op.
		terrain_rebuild_queued = false


func _rebuild_navigation_snapshot(invalidate_generation: bool) -> void:
	if invalidate_generation:
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

	var rebuilt_grid := AStarGrid2D.new()
	agent_grid_cache.clear()
	agent_open_plain_integral_cache.clear()
	agent_navigation_profile_cache.clear()
	flow_field_cache.clear()
	flow_field_cache_order.clear()
	flow_recovery_route_cache.clear()
	flow_recovery_cache_order.clear()
	rebuilt_grid.region = used_rect
	rebuilt_grid.cell_size = Vector2(obstacle_tile_layer.tile_set.tile_size)
	rebuilt_grid.diagonal_mode = AStarGrid2D.DIAGONAL_MODE_ONLY_IF_NO_OBSTACLES
	rebuilt_grid.default_compute_heuristic = AStarGrid2D.HEURISTIC_OCTILE
	rebuilt_grid.default_estimate_heuristic = AStarGrid2D.HEURISTIC_OCTILE
	rebuilt_grid.update()
	var rebuilt_cell_snapshot := _build_raw_navigation_cell_snapshot(used_rect)
	if rebuilt_cell_snapshot.size() != used_rect.size.x * used_rect.size.y:
		push_warning("GridPathfinder 无法构建基础导航快照。")
		return
	var rebuilt_obstacle_integral := _build_raw_obstacle_integral_snapshot(
		used_rect,
		rebuilt_cell_snapshot
	)
	var rebuilt_obstacle_integral_stride := used_rect.size.x + 1
	if (
		rebuilt_obstacle_integral.size()
		!= rebuilt_obstacle_integral_stride * (used_rect.size.y + 1)
	):
		push_warning("GridPathfinder 无法构建世界碰撞积分快照。")
		return

	# Publish the base grid and its byte snapshot as one generation. is_built
	# remains false until all dependent default-profile data is ready, so runtime
	# readers can observe either the complete old generation or the complete new
	# generation, never a half-built mix.
	astar_grid = rebuilt_grid
	raw_navigation_snapshot_generation = navigation_generation
	raw_navigation_snapshot_region = used_rect
	raw_navigation_cell_snapshot = rebuilt_cell_snapshot
	raw_obstacle_integral_snapshot = rebuilt_obstacle_integral
	raw_obstacle_integral_stride = rebuilt_obstacle_integral_stride
	_update_region_local_rect()

	for y in range(used_rect.position.y, used_rect.end.y):
		for x in range(used_rect.position.x, used_rect.end.x):
			var cell := Vector2i(x, y)
			rebuilt_grid.set_point_solid(cell, _is_cell_blocked(cell))

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
	# Invalidate certificates immediately. The expensive rebuild remains deferred
	# so multiple edits coalesce, but no caller can keep using a LAND/WATER result
	# produced before the first traversal-affecting edit.
	navigation_generation += 1
	is_built = false
	_cancel_all_runtime_navigation_jobs()
	dynamic_flow_target_slots.clear()
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
	if not terrain_rebuild_queued:
		return
	terrain_rebuild_queued = false
	_rebuild_navigation_snapshot(false)


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


func get_navigation_cell_half_diagonal() -> float:
	return astar_grid.cell_size.abs().length() * 0.5


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
	traversal_types: int = DEFAULT_TRAVERSAL_TYPES,
	target_contact_radius_world: float = 0.0
) -> void:
	_write_dynamic_target_navigation_step(
		result,
		context,
		from_global_position,
		target_node,
		agent_half_extents,
		traversal_types,
		target_contact_radius_world
	)


# Lightweight cohort prefetch used while a short direct probe is still clear.
# The first enemy for one target/profile performs the normal slot update; every
# equivalent enemy in the same physics frame stops at the dedupe key instead of
# repeating goal-cell resolution and slot/job Dictionary work.
func try_prefetch_dynamic_target_flow_with_profile(
	from_global_position: Vector2,
	target_node: Node2D,
	target_contact_radius_world: float,
	profile: AgentNavigationProfile
) -> bool:
	dynamic_flow_prefetch_requests_total += 1
	if (
		not is_built
		or target_node == null
		or not is_instance_valid(target_node)
		or not _is_agent_navigation_profile_valid(profile)
	):
		return false
	var dynamic_profile_extents := _get_dynamic_target_profile_extents(
		profile.normalized_extents
	)
	var current_physics_frame := Engine.get_physics_frames()
	if (
		dynamic_flow_prefetch_dedupe_frame != current_physics_frame
		or dynamic_flow_prefetch_dedupe_generation != navigation_generation
	):
		dynamic_flow_prefetch_dedupe_frame = current_physics_frame
		dynamic_flow_prefetch_dedupe_generation = navigation_generation
		dynamic_flow_prefetch_keys_this_frame.clear()
	var normalized_contact_radius := maxf(target_contact_radius_world, 0.0)
	var slot_key := _get_dynamic_flow_slot_key(
		target_node.get_instance_id(),
		dynamic_profile_extents,
		profile.traversal_types,
		normalized_contact_radius
	)
	var target_position := target_node.global_position
	# Match the two-pixel desired-state threshold used by the slot updater. A
	# same-frame teleport or meaningful target correction must not inherit an
	# earlier prefetch key merely because the Node instance stayed the same.
	var dedupe_key := "%s:t%d,%d" % [
		slot_key,
		floori(target_position.x * 0.5),
		floori(target_position.y * 0.5),
	]
	var existing_slot := dynamic_flow_target_slots.get(
		slot_key
	) as DynamicFlowTargetSlot
	if (
		existing_slot != null
		and existing_slot.generation == navigation_generation
		and not existing_slot.published_field.is_empty()
	):
		var source_cell := _global_to_map(from_global_position)
		var published_next_cells := existing_slot.published_field.get(
			"next_cells",
			{}
		) as Dictionary
		if (
			not published_next_cells.has(source_cell)
			and not bool(existing_slot.published_field.get(
				"coverage_is_exhaustive",
				true
			))
			and _is_cell_walkable(source_cell, existing_slot.path_grid)
		):
			# A bounded published field can need several distinct out-of-region
			# sources. Merge identical enemies in one cell, but let every unique
			# source join the shared coverage continuation before actual handoff.
			dedupe_key += ":s%d,%d" % [source_cell.x, source_cell.y]
	if dynamic_flow_prefetch_keys_this_frame.has(dedupe_key):
		dynamic_flow_prefetch_deduplicated_total += 1
		return false
	dynamic_flow_prefetch_keys_this_frame[dedupe_key] = true
	dynamic_flow_prefetch_full_requests_total += 1
	_write_dynamic_target_navigation_step(
		dynamic_flow_prefetch_result_scratch,
		null,
		from_global_position,
		target_node,
		profile.normalized_extents,
		profile.traversal_types,
		normalized_contact_radius
	)
	return true


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


func is_world_collision_segment_certified_clear(
	from_global_position: Vector2,
	to_global_position: Vector2
) -> bool:
	# This certificate covers only the authored TileMap collision layer represented
	# by NAVIGATION_CELL_OBSTACLE_FLAG. Dynamic damageable bodies remain handled by
	# each projectile's Area2D. A one-cell guard band makes the proof conservative
	# for segments touching cell boundaries and for polygons authored up to a tile
	# edge; uncertainty always falls back to the original Physics2D ray.
	if (
		not world_collision_layer_exclusive_to_authored_tiles
		or not is_built
		or obstacle_tile_layer == null
		or raw_navigation_snapshot_generation != navigation_generation
		or raw_obstacle_integral_snapshot.is_empty()
		or raw_obstacle_integral_stride != raw_navigation_snapshot_region.size.x + 1
	):
		return false
	var from_cell := _global_to_map(from_global_position)
	var to_cell := _global_to_map(to_global_position)
	var minimum_cell := Vector2i(
		mini(from_cell.x, to_cell.x) - 1,
		mini(from_cell.y, to_cell.y) - 1
	)
	var maximum_cell := Vector2i(
		maxi(from_cell.x, to_cell.x) + 1,
		maxi(from_cell.y, to_cell.y) + 1
	)
	if (
		not raw_navigation_snapshot_region.has_point(minimum_cell)
		or not raw_navigation_snapshot_region.has_point(maximum_cell)
	):
		return false
	return _get_raw_obstacle_count_in_cell_rect(
		minimum_cell,
		maximum_cell
	) == 0


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
	var cache_key := _get_agent_grid_cache_key(
		normalized_extents,
		traversal_types
	)
	return _try_is_navigation_segment_walkable_runtime(
		from_global_position,
		to_global_position,
		normalized_extents,
		traversal_types,
		path_grid,
		_get_agent_open_plain_integral_snapshot(cache_key)
	)


func try_get_agent_navigation_profile(
	agent_half_extents: Vector2 = Vector2.ZERO,
	traversal_types: int = DEFAULT_TRAVERSAL_TYPES
) -> AgentNavigationProfile:
	if not is_built or obstacle_tile_layer == null:
		return null
	var normalized_extents := _normalize_agent_half_extents(agent_half_extents)
	var cache_key := _get_agent_grid_cache_key(
		normalized_extents,
		traversal_types
	)
	var cached_profile := agent_navigation_profile_cache.get(
		cache_key
	) as AgentNavigationProfile
	if _is_agent_navigation_profile_valid(cached_profile):
		return cached_profile
	var path_grid := _get_runtime_agent_grid_or_enqueue(
		normalized_extents,
		traversal_types
	)
	if path_grid == null:
		return null
	var snapshot := _get_agent_open_plain_integral_snapshot(cache_key)
	if snapshot == null:
		return null
	var profile := AgentNavigationProfile.new()
	profile.generation = navigation_generation
	profile.cache_key = cache_key
	profile.normalized_extents = normalized_extents
	profile.traversal_types = traversal_types
	profile.path_grid = path_grid
	profile.solid_integral_snapshot = snapshot
	agent_navigation_profile_cache[cache_key] = profile
	return profile


func is_agent_navigation_profile_valid(profile: AgentNavigationProfile) -> bool:
	return _is_agent_navigation_profile_valid(profile)


func try_is_navigation_segment_walkable_with_profile(
	from_global_position: Vector2,
	to_global_position: Vector2,
	profile: AgentNavigationProfile
) -> Variant:
	if not _is_agent_navigation_profile_valid(profile):
		return null
	return _try_is_navigation_segment_walkable_runtime(
		from_global_position,
		to_global_position,
		profile.normalized_extents,
		profile.traversal_types,
		profile.path_grid,
		profile.solid_integral_snapshot
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


func try_is_navigation_open_plain_with_profile(
	from_global_position: Vector2,
	to_global_position: Vector2,
	profile: AgentNavigationProfile
) -> Variant:
	if not _is_agent_navigation_profile_valid(profile):
		return null
	var snapshot := profile.solid_integral_snapshot
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


# Fixed-cost static-obstacle lookahead for direct-moving agents. The shared
# profile grid is already inflated for the caller's body, so two summed-area
# rectangle reads are enough to conservatively notice a wall several cells
# before the normal short movement probe reaches it. A fully open corridor
# always returns false and therefore never creates runtime flow work.
func try_has_navigation_obstacle_ahead_with_profile(
	from_global_position: Vector2,
	toward_global_position: Vector2,
	known_clear_distance_world: float,
	lookahead_distance_cells: float,
	profile: AgentNavigationProfile
) -> Variant:
	if not _is_agent_navigation_profile_valid(profile):
		return null
	var offset := toward_global_position - from_global_position
	var total_distance := offset.length()
	var clear_distance := maxf(known_clear_distance_world, 0.0)
	if total_distance <= clear_distance + 0.0001:
		return false
	var minimum_cell_size := maxf(
		minf(absf(astar_grid.cell_size.x), absf(astar_grid.cell_size.y)),
		1.0
	)
	var lookahead_world := maxf(lookahead_distance_cells, 0.0) * minimum_cell_size
	if lookahead_world <= 0.0001:
		return false
	var corridor_end_distance := minf(
		total_distance,
		clear_distance + lookahead_world
	)
	if corridor_end_distance <= clear_distance + 0.0001:
		return false

	var direction := offset / total_distance
	var snapshot := profile.solid_integral_snapshot
	for segment_index in range(FORWARD_OBSTACLE_LOOKAHEAD_SEGMENTS):
		var start_weight := (
			float(segment_index) / float(FORWARD_OBSTACLE_LOOKAHEAD_SEGMENTS)
		)
		var end_weight := (
			float(segment_index + 1) / float(FORWARD_OBSTACLE_LOOKAHEAD_SEGMENTS)
		)
		var segment_start_distance := lerpf(
			clear_distance,
			corridor_end_distance,
			start_weight
		)
		var segment_end_distance := lerpf(
			clear_distance,
			corridor_end_distance,
			end_weight
		)
		var start_cell := _global_to_map(
			from_global_position + direction * segment_start_distance
		)
		var end_cell := _global_to_map(
			from_global_position + direction * segment_end_distance
		)
		var minimum_cell := Vector2i(
			mini(start_cell.x, end_cell.x),
			mini(start_cell.y, end_cell.y)
		)
		var maximum_cell := Vector2i(
			maxi(start_cell.x, end_cell.x),
			maxi(start_cell.y, end_cell.y)
		)
		if (
			not snapshot.region.has_point(minimum_cell)
			or not snapshot.region.has_point(maximum_cell)
		):
			return true
		if _get_agent_solid_count_in_cell_rect(
			snapshot,
			minimum_cell,
			maximum_cell
		) > 0:
			return true
	return false


func _is_navigation_segment_walkable_with_grid(
	from_global_position: Vector2,
	to_global_position: Vector2,
	normalized_extents: Vector2,
	traversal_types: int,
	path_grid: AStarGrid2D,
	solid_integral_snapshot: AgentSolidIntegralSnapshot = null
) -> bool:
	# Most movement probes cover only a fraction of a tile. Certify their swept
	# cell rectangle from the immutable agent-solid integral first; the expanded
	# one-cell guard band makes this conservative for sub-cell endpoints. Only a
	# segment near a wall, water edge, or region boundary pays for exact samples.
	if _can_certify_navigation_segment_from_integral(
		from_global_position,
		to_global_position,
		normalized_extents,
		traversal_types,
		solid_integral_snapshot
	):
		return true
	return _is_navigation_segment_walkable_exact_with_grid(
		from_global_position,
		to_global_position,
		normalized_extents,
		traversal_types,
		path_grid
	)


func _try_is_navigation_segment_walkable_runtime(
	from_global_position: Vector2,
	to_global_position: Vector2,
	normalized_extents: Vector2,
	traversal_types: int,
	path_grid: AStarGrid2D,
	solid_integral_snapshot: AgentSolidIntegralSnapshot
) -> Variant:
	segment_queries_total += 1
	if _can_certify_navigation_segment_from_integral(
		from_global_position,
		to_global_position,
		normalized_extents,
		traversal_types,
		solid_integral_snapshot
	):
		segment_integral_hits_total += 1
		return true
	_refresh_exact_segment_budget_frame()
	if (
		exact_segment_fallbacks_used_this_frame
			>= maxi(max_exact_segment_fallbacks_per_render_frame, 1)
		or exact_segment_fallback_usec_used_this_frame
			>= maxi(exact_segment_fallback_time_budget_usec, 100)
	):
		segment_budget_deferrals_total += 1
		return null

	exact_segment_fallbacks_used_this_frame += 1
	segment_exact_fallbacks_total += 1
	var started_usec := Time.get_ticks_usec()
	var is_walkable := _is_navigation_segment_walkable_exact_with_grid(
		from_global_position,
		to_global_position,
		normalized_extents,
		traversal_types,
		path_grid
	)
	exact_segment_fallback_usec_used_this_frame += maxi(
		Time.get_ticks_usec() - started_usec,
		0
	)
	return is_walkable


func _is_navigation_segment_walkable_exact_with_grid(
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


func _can_certify_navigation_segment_from_integral(
	from_global_position: Vector2,
	to_global_position: Vector2,
	normalized_extents: Vector2,
	traversal_types: int,
	solid_integral_snapshot: AgentSolidIntegralSnapshot = null
) -> bool:
	var snapshot := solid_integral_snapshot
	if snapshot == null:
		var cache_key := _get_agent_grid_cache_key(
			normalized_extents,
			traversal_types
		)
		snapshot = _get_agent_open_plain_integral_snapshot(cache_key)
	if snapshot == null:
		return false
	var from_cell := _global_to_map(from_global_position)
	var to_cell := _global_to_map(to_global_position)
	var minimum_cell := Vector2i(
		mini(from_cell.x, to_cell.x) - 1,
		mini(from_cell.y, to_cell.y) - 1
	)
	var maximum_cell := Vector2i(
		maxi(from_cell.x, to_cell.x) + 1,
		maxi(from_cell.y, to_cell.y) + 1
	)
	if (
		not snapshot.region.has_point(minimum_cell)
		or not snapshot.region.has_point(maximum_cell)
	):
		return false
	return _get_agent_solid_count_in_cell_rect(
		snapshot,
		minimum_cell,
		maximum_cell
	) == 0


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
	var path_grid := _get_or_create_agent_grid(normalized_extents, traversal_types)
	_store_dynamic_target_profile_grid_alias(
		normalized_extents,
		traversal_types,
		path_grid,
		_get_agent_open_plain_integral_snapshot(
			_get_agent_grid_cache_key(normalized_extents, traversal_types)
		)
	)


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
		_store_dynamic_target_profile_grid_alias(
			normalized_extents,
			traversal_types,
			agent_grid_cache.get(cache_key) as AStarGrid2D,
			_get_agent_open_plain_integral_snapshot(cache_key)
		)
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
	completed_rows = 0
	for local_y in range(agent_grid.region.size.y):
		for local_x in range(agent_grid.region.size.x):
			_write_agent_transition_mask_cell(
				solid_integral_snapshot,
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
	_store_dynamic_target_profile_grid_alias(
		normalized_extents,
		traversal_types,
		agent_grid,
		solid_integral_snapshot
	)


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
	var cached_field := _get_cached_flow_field(
		target_cell,
		normalized_extents,
		traversal_types
	)
	if not cached_field.is_empty():
		_store_dynamic_target_flow_alias(
			target_cell,
			normalized_extents,
			traversal_types,
			cached_field
		)
		return

	var field := _build_flow_field(target_cell, path_grid)
	_store_flow_field(
		target_cell,
		normalized_extents,
		traversal_types,
		field
	)
	_store_dynamic_target_flow_alias(
		target_cell,
		normalized_extents,
		traversal_types,
		field
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
	var cached_field := _get_cached_flow_field(
		target_cell,
		normalized_extents,
		traversal_types
	)
	if not cached_field.is_empty():
		_store_dynamic_target_flow_alias(
			target_cell,
			normalized_extents,
			traversal_types,
			cached_field
		)
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
	_store_dynamic_target_flow_alias(
		target_cell,
		normalized_extents,
		traversal_types,
		field
	)


func _refresh_path_query_budget_frame() -> void:
	var current_frame := Engine.get_process_frames()
	if current_frame == path_query_budget_frame:
		return
	path_query_budget_frame = current_frame
	path_queries_used_this_frame = 0


func _refresh_flow_field_budget_frame() -> void:
	var current_frame := Engine.get_process_frames()
	if current_frame == flow_field_budget_frame:
		return
	flow_field_budget_frame = current_frame
	flow_field_builds_used_this_frame = 0


func try_acquire_agent_navigation_refresh(agent_instance_id: int) -> bool:
	var current_frame := Engine.get_process_frames()
	if current_frame != agent_navigation_refresh_budget_process_frame:
		_begin_agent_navigation_refresh_process_frame(current_frame)
	if not agent_navigation_refresh_reserved_ids.is_empty():
		if not agent_navigation_refresh_reserved_ids.has(agent_instance_id):
			var unreserved_capacity := (
				maxi(max_agent_navigation_refreshes_per_process_frame, 1)
				- agent_navigation_refresh_reserved_ids.size()
			)
			if agent_navigation_refreshes_used_this_frame < unreserved_capacity:
				agent_navigation_refreshes_used_this_frame += 1
				agent_navigation_refreshes_admitted_total += 1
				return true
			_defer_agent_navigation_refresh(agent_instance_id, current_frame)
			return false
		agent_navigation_refresh_reserved_ids.erase(agent_instance_id)
		_admit_deferred_agent_navigation_refresh(agent_instance_id, current_frame)
		agent_navigation_refreshes_used_this_frame += 1
		agent_navigation_refreshes_admitted_total += 1
		return true
	if (
		agent_navigation_refreshes_used_this_frame
		>= maxi(max_agent_navigation_refreshes_per_process_frame, 1)
	):
		_defer_agent_navigation_refresh(agent_instance_id, current_frame)
		return false
	agent_navigation_refreshes_used_this_frame += 1
	agent_navigation_refreshes_admitted_total += 1
	return true


func _begin_agent_navigation_refresh_process_frame(current_frame: int) -> void:
	agent_navigation_refresh_budget_process_frame = current_frame
	agent_navigation_refreshes_used_this_frame = 0

	# Reservations that were not consumed (normally only an enemy removed or
	# paused before its physics callback) keep their age and return to the front.
	var rebuilt_queue: Array[int] = []
	for agent_id in agent_navigation_refresh_reserved_order:
		if (
			agent_navigation_refresh_reserved_ids.has(agent_id)
			and agent_navigation_refresh_deferred_ids.has(agent_id)
		):
			rebuilt_queue.append(agent_id)
	for queue_index in range(
		agent_navigation_refresh_deferred_queue_head,
		agent_navigation_refresh_deferred_queue.size()
	):
		var queued_id := agent_navigation_refresh_deferred_queue[queue_index]
		if agent_navigation_refresh_deferred_ids.has(queued_id):
			rebuilt_queue.append(queued_id)
	agent_navigation_refresh_deferred_queue = rebuilt_queue
	agent_navigation_refresh_deferred_queue_head = 0
	agent_navigation_refresh_reserved_order.clear()
	agent_navigation_refresh_reserved_ids.clear()

	var reservation_cap := maxi(
		max_agent_navigation_refreshes_per_process_frame,
		1
	)
	while (
		agent_navigation_refresh_reserved_order.size() < reservation_cap
		and (
			agent_navigation_refresh_deferred_queue_head
			< agent_navigation_refresh_deferred_queue.size()
		)
	):
		var agent_id := agent_navigation_refresh_deferred_queue[
			agent_navigation_refresh_deferred_queue_head
		]
		agent_navigation_refresh_deferred_queue_head += 1
		if not agent_navigation_refresh_deferred_ids.has(agent_id):
			continue
		var last_request_frame := int(
			agent_navigation_refresh_last_request_frame.get(agent_id, -1)
		)
		if last_request_frame < current_frame - 1:
			# An enemy that entered contact/attack/death no longer asks for a
			# navigation direction. Do not let its stale reservation consume a
			# slot forever; it can enqueue again if movement later resumes.
			_forget_deferred_agent_navigation_refresh(agent_id)
			continue
		var agent_object := instance_from_id(agent_id)
		if not is_instance_valid(agent_object):
			_forget_deferred_agent_navigation_refresh(agent_id)
			continue
		var enemy := agent_object as Enemy
		if enemy != null and enemy.is_dead:
			_forget_deferred_agent_navigation_refresh(agent_id)
			continue
		agent_navigation_refresh_reserved_order.append(agent_id)
		agent_navigation_refresh_reserved_ids[agent_id] = true


func _defer_agent_navigation_refresh(
	agent_instance_id: int,
	current_frame: int
) -> void:
	agent_navigation_refreshes_deferred_total += 1
	if current_frame != agent_navigation_refresh_last_saturated_process_frame:
		agent_navigation_refresh_last_saturated_process_frame = current_frame
		agent_navigation_refresh_budget_saturated_frames_total += 1
	if agent_instance_id <= 0:
		return
	agent_navigation_refresh_last_request_frame[agent_instance_id] = current_frame
	if agent_navigation_refresh_deferred_ids.has(agent_instance_id):
		return
	agent_navigation_refresh_deferred_ids[agent_instance_id] = true
	agent_navigation_refresh_deferred_since_frame[agent_instance_id] = current_frame
	agent_navigation_refresh_deferred_queue.append(agent_instance_id)


func _admit_deferred_agent_navigation_refresh(
	agent_instance_id: int,
	current_frame: int
) -> void:
	var deferred_since := int(
		agent_navigation_refresh_deferred_since_frame.get(
			agent_instance_id,
			current_frame
		)
	)
	agent_navigation_refresh_max_wait_process_frames = maxi(
		agent_navigation_refresh_max_wait_process_frames,
		maxi(current_frame - deferred_since, 0)
	)
	_forget_deferred_agent_navigation_refresh(agent_instance_id)


func _forget_deferred_agent_navigation_refresh(agent_instance_id: int) -> void:
	agent_navigation_refresh_deferred_ids.erase(agent_instance_id)
	agent_navigation_refresh_deferred_since_frame.erase(agent_instance_id)
	agent_navigation_refresh_last_request_frame.erase(agent_instance_id)
	agent_navigation_refresh_reserved_ids.erase(agent_instance_id)


func _refresh_exact_segment_budget_frame() -> void:
	var current_frame := Engine.get_process_frames()
	if current_frame == exact_segment_budget_process_frame:
		return
	exact_segment_budget_process_frame = current_frame
	exact_segment_fallbacks_used_this_frame = 0
	exact_segment_fallback_usec_used_this_frame = 0


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
	target_cell: Vector2i,
	target_cells: Array[Vector2i],
	original_target_cell: Vector2i
) -> void:
	if (
		slot == null
		or slot.generation != navigation_generation
		or target_cell == Vector2i.MAX
		or target_cells.is_empty()
	):
		return
	# A fixed single-goal field is safe to adopt only when its endpoint is the
	# live target cell itself. Wall-adjacent moving targets use a multi-source
	# contact region and therefore need their own bounded runtime field.
	if target_cells.size() == 1 and target_cell == original_target_cell:
		var cached_field := _get_cached_flow_field(
			target_cell,
			slot.normalized_extents,
			slot.traversal_types
		)
		if not cached_field.is_empty():
			_publish_dynamic_flow_slot(
				slot,
				original_target_cell,
				target_cells,
				cached_field
			)
			return

	var flow_radius := maxi(dynamic_target_flow_radius_cells, 1)
	var requested_region := Rect2i(
		original_target_cell - Vector2i(flow_radius, flow_radius),
		Vector2i(flow_radius * 2 + 1, flow_radius * 2 + 1)
	).intersection(slot.path_grid.region)
	var job_key := _get_dynamic_flow_job_cache_key(
		slot,
		original_target_cell,
		target_cells
	)
	var job := _get_or_create_runtime_flow_build_job(
		target_cell,
		slot.normalized_extents,
		slot.traversal_types,
		slot.path_grid,
		RuntimeFlowJobPriority.DYNAMIC_TARGET,
		target_cells,
		requested_region,
		original_target_cell,
		job_key
	)
	job.waiting_dynamic_slots[slot.slot_key] = true
	slot.pending_job_key = job.cache_key
	set_process(true)


func _request_runtime_dynamic_flow_coverage_build(
	slot: DynamicFlowTargetSlot,
	original_source_cell: Vector2i
) -> void:
	if (
		slot == null
		or slot.generation != navigation_generation
		or slot.path_grid == null
		or not _is_cell_walkable(original_source_cell, slot.path_grid)
		or slot.desired_resolved_cell == Vector2i.MAX
		or slot.desired_goal_cells.is_empty()
	):
		return
	if slot.pending_job_key != "":
		var pending_job := runtime_flow_build_jobs.get(
			slot.pending_job_key
		) as RuntimeFlowBuildJob
		if pending_job == null:
			slot.pending_job_key = ""
		elif pending_job.complete_when_required_sources_reached:
			_add_required_source_to_runtime_flow_job(
				pending_job,
				original_source_cell
			)
			pending_job.waiting_dynamic_slots[slot.slot_key] = true
			set_process(true)
			return
		else:
			return

	var job_key := "%s:coverage" % _get_dynamic_flow_job_cache_key(
		slot,
		slot.desired_original_cell,
		slot.desired_goal_cells
	)
	var job := _get_or_create_runtime_flow_build_job(
		slot.desired_resolved_cell,
		slot.normalized_extents,
		slot.traversal_types,
		slot.path_grid,
		RuntimeFlowJobPriority.BACKGROUND,
		slot.desired_goal_cells,
		slot.path_grid.region,
		slot.desired_original_cell,
		job_key
	)
	job.complete_when_required_sources_reached = true
	_add_required_source_to_runtime_flow_job(job, original_source_cell)
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
		RuntimeFlowJobPriority.STATIC_OBJECTIVE
	)
	job.publish_to_fixed_cache = true
	set_process(true)


func _get_or_create_runtime_flow_build_job(
	target_cell: Vector2i,
	normalized_extents: Vector2,
	traversal_types: int,
	path_grid: AStarGrid2D,
	priority: int,
	target_cells: Array[Vector2i] = [],
	expansion_region: Rect2i = Rect2i(),
	dynamic_target_original_cell: Vector2i = Vector2i.MAX,
	cache_key_override: String = ""
) -> RuntimeFlowBuildJob:
	var cache_key := cache_key_override
	if cache_key.is_empty():
		cache_key = _get_flow_field_cache_key(
			target_cell,
			normalized_extents,
			traversal_types
		)
	var job := runtime_flow_build_jobs.get(cache_key) as RuntimeFlowBuildJob
	if job != null:
		if priority > job.priority:
			_remove_runtime_flow_job_key_from_order(cache_key, job.priority)
			job.priority = priority
			job.urgent = priority > RuntimeFlowJobPriority.BACKGROUND
			job.scheduler_steps_since_yield = 0
			_insert_runtime_flow_job_key(cache_key, priority)
		return job

	job = RuntimeFlowBuildJob.new()
	job.generation = navigation_generation
	job.cache_key = cache_key
	job.target_cell = target_cell
	job.target_cells = target_cells.duplicate()
	if job.target_cells.is_empty():
		job.target_cells.append(target_cell)
	job.dynamic_target_original_cell = dynamic_target_original_cell
	job.expansion_region = expansion_region
	if job.expansion_region.size.x <= 0 or job.expansion_region.size.y <= 0:
		job.expansion_region = path_grid.region
	job.normalized_extents = normalized_extents
	job.traversal_types = traversal_types
	job.path_grid = path_grid
	job.priority = priority
	job.urgent = priority > RuntimeFlowJobPriority.BACKGROUND
	job.uses_packed_storage = runtime_flow_use_packed_build_storage
	if job.uses_packed_storage:
		job.solid_snapshot = _get_agent_open_plain_integral_snapshot(
			_get_agent_grid_cache_key(normalized_extents, traversal_types)
		)
		job.packed_region_width = job.expansion_region.size.x
		var packed_cell_count := (
			job.expansion_region.size.x * job.expansion_region.size.y
		)
		job.packed_distances.resize(packed_cell_count)
		job.packed_distances.fill(FLOW_DISTANCE_INFINITY)
		job.packed_next_indices.resize(packed_cell_count)
		job.packed_next_indices.fill(FLOW_NO_CELL_INDEX)
	for _bucket_index in range(FLOW_BUCKET_COUNT):
		job.pending_buckets.append([])
	var first_bucket := job.pending_buckets[0] as Array
	for seed_cell in job.target_cells:
		if not job.expansion_region.has_point(seed_cell):
			continue
		if not _is_cell_walkable(seed_cell, path_grid):
			continue
		if job.uses_packed_storage:
			var seed_index := _get_runtime_flow_job_cell_index(job, seed_cell)
			if (
				seed_index == FLOW_NO_CELL_INDEX
				or job.packed_distances[seed_index] != FLOW_DISTANCE_INFINITY
			):
				continue
			job.packed_distances[seed_index] = 0
			job.packed_next_indices[seed_index] = seed_index
			job.discovered_cell_count += 1
			first_bucket.append(seed_index)
		else:
			if job.next_cells.has(seed_cell):
				continue
			job.next_cells[seed_cell] = seed_cell
			job.distances[seed_cell] = 0
			job.discovered_cell_count += 1
			first_bucket.append(seed_cell)
		job.pending_entry_count += 1
	runtime_flow_build_jobs[cache_key] = job
	_insert_runtime_flow_job_key(cache_key, priority)
	return job


func _insert_runtime_flow_job_key(cache_key: String, priority: int) -> void:
	# Counts preserve a stable tail insertion for each sorted priority band
	# without scanning every queued job.
	var normalized_priority := clampi(
		priority,
		RuntimeFlowJobPriority.BACKGROUND,
		RuntimeFlowJobPriority.DYNAMIC_TARGET
	)
	var insertion_index := _get_runtime_flow_priority_band_start(
		normalized_priority
	) + runtime_flow_priority_counts[normalized_priority]
	insertion_index = clampi(insertion_index, 0, runtime_flow_build_order.size())
	runtime_flow_build_order.insert(insertion_index, cache_key)
	runtime_flow_priority_counts[normalized_priority] += 1


func _get_runtime_flow_priority_band_start(priority: int) -> int:
	match priority:
		RuntimeFlowJobPriority.DYNAMIC_TARGET:
			return 0
		RuntimeFlowJobPriority.STATIC_OBJECTIVE:
			return runtime_flow_priority_counts[
				RuntimeFlowJobPriority.DYNAMIC_TARGET
			]
		_:
			return (
				runtime_flow_priority_counts[
					RuntimeFlowJobPriority.DYNAMIC_TARGET
				]
				+ runtime_flow_priority_counts[
					RuntimeFlowJobPriority.STATIC_OBJECTIVE
				]
			)


func _get_runtime_flow_service_order_index(priority: int) -> int:
	if runtime_flow_build_order.is_empty():
		return -1
	var normalized_priority := clampi(
		priority,
		RuntimeFlowJobPriority.BACKGROUND,
		RuntimeFlowJobPriority.DYNAMIC_TARGET
	)
	if runtime_flow_priority_counts[normalized_priority] <= 0:
		return 0
	return _get_runtime_flow_priority_band_start(normalized_priority)


func _remove_runtime_flow_job_key_from_order(
	cache_key: String,
	priority: int
) -> void:
	var order_index := runtime_flow_build_order.find(cache_key)
	if order_index < 0:
		return
	runtime_flow_build_order.remove_at(order_index)
	var normalized_priority := clampi(
		priority,
		RuntimeFlowJobPriority.BACKGROUND,
		RuntimeFlowJobPriority.DYNAMIC_TARGET
	)
	runtime_flow_priority_counts[normalized_priority] = maxi(
		runtime_flow_priority_counts[normalized_priority] - 1,
		0
	)


func _rebuild_runtime_flow_priority_counts() -> void:
	runtime_flow_priority_counts.fill(0)
	for cache_key in runtime_flow_build_order:
		var queued_job := runtime_flow_build_jobs.get(
			cache_key
		) as RuntimeFlowBuildJob
		if queued_job == null:
			continue
		var normalized_priority := clampi(
			queued_job.priority,
			RuntimeFlowJobPriority.BACKGROUND,
			RuntimeFlowJobPriority.DYNAMIC_TARGET
		)
		runtime_flow_priority_counts[normalized_priority] += 1


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
				advanced = _advance_scheduled_runtime_flow_job()
			else:
				advanced = _advance_first_runtime_agent_grid_job()
			runtime_navigation_prefers_urgent_flow = (
				not runtime_navigation_prefers_urgent_flow
			)
		elif urgent_flow_waiting:
			advanced = _advance_scheduled_runtime_flow_job()
		elif not runtime_agent_grid_build_order.is_empty():
			advanced = _advance_first_runtime_agent_grid_job()
		elif not runtime_flow_build_order.is_empty():
			advanced = _advance_scheduled_runtime_flow_job()
		else:
			break
		if advanced:
			expansions += 1
		attempts_since_time_check += 1
		# Search reads the clock every four expansions. Packed materialization does
		# Dictionary writes in 16-cell batches and returns false by design, so read
		# immediately after each such batch to cap its deadline overshoot at one
		# batch without polluting path-expansion telemetry.
		if not advanced or attempts_since_time_check >= 4:
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

	if job.next_transition_cell_index < total_cells:
		_write_agent_transition_mask_cell(
			job.solid_integral_snapshot,
			job.next_transition_cell_index
		)
		job.next_transition_cell_index += 1
		if job.next_transition_cell_index < total_cells:
			return true

	_store_agent_open_plain_integral_snapshot(
		cache_key,
		job.solid_integral_snapshot
	)
	if job.publish_path_grid_to_cache:
		agent_grid_cache[cache_key] = job.path_grid
	_remove_runtime_agent_grid_job(cache_key)
	return true


func _get_runtime_flow_job_cell_index(
	job: RuntimeFlowBuildJob,
	cell: Vector2i
) -> int:
	if job == null or not job.expansion_region.has_point(cell):
		return FLOW_NO_CELL_INDEX
	var local_cell := cell - job.expansion_region.position
	return local_cell.y * job.packed_region_width + local_cell.x


func _get_runtime_flow_job_cell_from_index(
	job: RuntimeFlowBuildJob,
	cell_index: int
) -> Vector2i:
	if (
		job == null
		or job.packed_region_width <= 0
		or cell_index < 0
		or cell_index >= job.packed_distances.size()
	):
		return Vector2i.MAX
	return job.expansion_region.position + Vector2i(
		cell_index % job.packed_region_width,
		cell_index / job.packed_region_width
	)


func _get_runtime_flow_job_discovered_cell_count(job: RuntimeFlowBuildJob) -> int:
	if job == null:
		return 0
	return job.discovered_cell_count if job.uses_packed_storage else job.next_cells.size()


func _get_runtime_flow_job_distance(
	job: RuntimeFlowBuildJob,
	cell: Vector2i
) -> int:
	if job == null:
		return -1
	if not job.uses_packed_storage:
		return int(job.distances.get(cell, -1))
	var cell_index := _get_runtime_flow_job_cell_index(job, cell)
	if cell_index == FLOW_NO_CELL_INDEX:
		return -1
	var distance := job.packed_distances[cell_index]
	return -1 if distance == FLOW_DISTANCE_INFINITY else distance


func _advance_runtime_flow_job_materialization(job: RuntimeFlowBuildJob) -> bool:
	if job == null or not job.uses_packed_storage:
		return true
	if job.next_materialize_cell_index == 0:
		job.next_cells.clear()
		job.distances.clear()
	var scanned_cells := 0
	while (
		job.next_materialize_cell_index < job.packed_distances.size()
		and scanned_cells < RUNTIME_FLOW_MATERIALIZE_BATCH_CELLS
	):
		var cell_index := job.next_materialize_cell_index
		job.next_materialize_cell_index += 1
		scanned_cells += 1
		var distance := job.packed_distances[cell_index]
		if distance == FLOW_DISTANCE_INFINITY:
			continue
		var cell := _get_runtime_flow_job_cell_from_index(job, cell_index)
		var next_index := job.packed_next_indices[cell_index]
		var next_cell := _get_runtime_flow_job_cell_from_index(job, next_index)
		if cell == Vector2i.MAX or next_cell == Vector2i.MAX:
			continue
		job.distances[cell] = distance
		job.next_cells[cell] = next_cell
	return job.next_materialize_cell_index >= job.packed_distances.size()


func _finish_runtime_flow_job_search(job: RuntimeFlowBuildJob) -> void:
	if job == null:
		return
	if job.uses_packed_storage:
		job.search_completed = true
		return
	_complete_runtime_flow_build_job(job)


func _advance_first_runtime_flow_job() -> bool:
	if runtime_flow_build_order.is_empty():
		return false
	return _advance_runtime_flow_job_at_order_index(0)


func _advance_scheduled_runtime_flow_job() -> bool:
	if runtime_flow_build_order.is_empty():
		return false
	var requested_priority := RUNTIME_FLOW_PRIORITY_SERVICE_CYCLE[
		runtime_flow_priority_service_cursor
	]
	runtime_flow_priority_service_cursor = (
		(runtime_flow_priority_service_cursor + 1)
		% RUNTIME_FLOW_PRIORITY_SERVICE_CYCLE.size()
	)
	var selected_index := _get_runtime_flow_service_order_index(
		requested_priority
	)
	return _advance_runtime_flow_job_at_order_index(selected_index)


func _advance_runtime_flow_job_at_order_index(order_index: int) -> bool:
	if order_index < 0 or order_index >= runtime_flow_build_order.size():
		return false
	var cache_key := runtime_flow_build_order[order_index]
	var job := runtime_flow_build_jobs.get(cache_key) as RuntimeFlowBuildJob
	if job == null or job.generation != navigation_generation:
		_cancel_runtime_flow_build_job(cache_key)
		return false
	var advanced := _advance_runtime_flow_job(job)
	_yield_runtime_flow_job_after_quantum(cache_key, job)
	return advanced


func _advance_runtime_flow_job(job: RuntimeFlowBuildJob) -> bool:
	if job.search_completed:
		if _advance_runtime_flow_job_materialization(job):
			_complete_runtime_flow_build_job(job)
		# Dictionary materialization is bounded by the same wall-clock deadline but
		# is not a path expansion, so keep the existing expansion telemetry exact.
		return false
	if _runtime_flow_job_reached_all_required_sources(job):
		job.completed_by_required_coverage = true
		_finish_runtime_flow_job_search(job)
		return false
	while job.pending_entry_count > 0:
		var bucket_index := job.current_distance % FLOW_BUCKET_COUNT
		var bucket := job.pending_buckets[bucket_index] as Array
		if bucket.is_empty():
			job.current_distance += 1
			continue
		var current_entry: Variant = bucket.pop_back()
		job.pending_entry_count -= 1
		var current_cell := Vector2i.ZERO
		var current_index := FLOW_NO_CELL_INDEX
		var stored_current_distance := -1
		if job.uses_packed_storage:
			current_index = int(current_entry)
			current_cell = _get_runtime_flow_job_cell_from_index(job, current_index)
			if current_index != FLOW_NO_CELL_INDEX:
				stored_current_distance = job.packed_distances[current_index]
		else:
			current_cell = current_entry as Vector2i
			stored_current_distance = int(job.distances.get(current_cell, -1))
		if stored_current_distance != job.current_distance:
			# A cell whose tentative distance improved leaves one stale bucket
			# entry behind. Consume only one entry per scheduler step so a large
			# stale tail can never escape the global time/expansion budget.
			if job.pending_entry_count <= 0:
				_finish_runtime_flow_job_search(job)
			return true
		if job.remaining_required_source_cells.has(current_cell):
			job.remaining_required_source_cells.erase(current_cell)
		var uses_packed_transitions := (
			job.uses_packed_storage
			and job.solid_snapshot != null
			and job.solid_snapshot.generation == navigation_generation
			and not job.solid_snapshot.transition_masks.is_empty()
		)
		var packed_transition_mask := 0
		if uses_packed_transitions:
			var snapshot_local := (
				current_cell - job.solid_snapshot.region.position
			)
			var snapshot_index := (
				snapshot_local.y * job.solid_snapshot.region.size.x
				+ snapshot_local.x
			)
			packed_transition_mask = (
				job.solid_snapshot.transition_masks[snapshot_index]
			)
		for direction_index in range(FLOW_DIRECTIONS.size()):
			var direction := FLOW_DIRECTIONS[direction_index]
			var neighbor := current_cell + direction
			if not job.expansion_region.has_point(neighbor):
				continue
			if uses_packed_transitions:
				if (packed_transition_mask & (1 << direction_index)) == 0:
					continue
			elif not _is_safe_flow_transition(current_cell, direction, job.path_grid):
				continue
			var candidate_distance := (
				job.current_distance
				+ (
					FLOW_ORTHOGONAL_COST
					if direction_index < FLOW_CARDINAL_DIRECTIONS.size()
					else FLOW_DIAGONAL_COST
				)
			)
			var target_bucket := (
				job.pending_buckets[candidate_distance % FLOW_BUCKET_COUNT] as Array
			)
			if job.uses_packed_storage:
				var neighbor_local := neighbor - job.expansion_region.position
				var neighbor_index := (
					neighbor_local.y * job.packed_region_width + neighbor_local.x
				)
				var previous_distance := job.packed_distances[neighbor_index]
				if candidate_distance >= previous_distance:
					continue
				if previous_distance == FLOW_DISTANCE_INFINITY:
					job.discovered_cell_count += 1
				job.packed_distances[neighbor_index] = candidate_distance
				job.packed_next_indices[neighbor_index] = current_index
				target_bucket.append(neighbor_index)
			else:
				if candidate_distance >= int(
					job.distances.get(neighbor, FLOW_DISTANCE_INFINITY)
				):
					continue
				if not job.distances.has(neighbor):
					job.discovered_cell_count += 1
				job.distances[neighbor] = candidate_distance
				job.next_cells[neighbor] = current_cell
				target_bucket.append(neighbor)
			job.pending_entry_count += 1
		if _runtime_flow_job_reached_all_required_sources(job):
			job.completed_by_required_coverage = true
			_finish_runtime_flow_job_search(job)
			return true
		if job.pending_entry_count <= 0:
			_finish_runtime_flow_job_search(job)
		return true

	_finish_runtime_flow_job_search(job)
	return false


func _yield_runtime_flow_job_after_quantum(
	cache_key: String,
	job: RuntimeFlowBuildJob
) -> void:
	if (
		job == null
		or not runtime_flow_build_jobs.has(cache_key)
		or runtime_flow_build_order.is_empty()
	):
		return
	job.scheduler_steps_since_yield += 1
	if job.scheduler_steps_since_yield < RUNTIME_FLOW_JOB_QUANTUM_STEPS:
		return
	job.scheduler_steps_since_yield = 0
	# Move to the tail of the same priority band. Lower-priority work remains
	# behind it, while another player/profile job cannot monopolize every slice.
	_remove_runtime_flow_job_key_from_order(cache_key, job.priority)
	_insert_runtime_flow_job_key(cache_key, job.priority)


func _runtime_flow_job_reached_all_required_sources(
	job: RuntimeFlowBuildJob
) -> bool:
	return (
		job != null
		and job.complete_when_required_sources_reached
		and not job.required_source_cells.is_empty()
		and job.remaining_required_source_cells.is_empty()
	)


func _add_required_source_to_runtime_flow_job(
	job: RuntimeFlowBuildJob,
	source_cell: Vector2i
) -> void:
	if job == null or job.required_source_cells.has(source_cell):
		return
	job.required_source_cells[source_cell] = true
	var known_distance := _get_runtime_flow_job_distance(job, source_cell)
	# Positive transition costs make any discovered distance final once the
	# Dijkstra cursor reaches it. This keeps source completion O(1) per expansion.
	if known_distance < 0 or known_distance > job.current_distance:
		job.remaining_required_source_cells[source_cell] = true
	# Packed publication is staged for a few render frames. A new consumer can
	# join that narrow window after the previous required set finished. If the
	# frontier still has work, resume Dijkstra instead of publishing a field that
	# never reached the newly registered source.
	if (
		job.search_completed
		and not job.remaining_required_source_cells.is_empty()
		and job.pending_entry_count > 0
	):
		job.search_completed = false
		job.completed_by_required_coverage = false
		job.next_materialize_cell_index = 0
		job.next_cells.clear()
		job.distances.clear()


func _complete_runtime_flow_build_job(job: RuntimeFlowBuildJob) -> void:
	if job == null:
		return
	var field := {
		"target_cell": job.target_cell,
		"target_cells": job.target_cells,
		"goal_cells": job.target_cells,
		"build_region": job.expansion_region,
		"next_cells": job.next_cells,
		"distances": job.distances,
		"coverage_is_exhaustive": (
			job.expansion_region == job.path_grid.region
			and not job.completed_by_required_coverage
			and job.pending_entry_count <= 0
		),
	}
	if job.publish_to_fixed_cache:
		_store_flow_field(
			job.target_cell,
			job.normalized_extents,
			job.traversal_types,
			field
		)
	var affected_slots: Array[DynamicFlowTargetSlot] = []
	for slot_key_variant in job.waiting_dynamic_slots:
		var slot_key := String(slot_key_variant)
		var slot := dynamic_flow_target_slots.get(slot_key) as DynamicFlowTargetSlot
		if (
			slot == null
			or slot.generation != navigation_generation
			or slot.pending_job_key != job.cache_key
		):
			continue
		# Publish every complete intermediate field that is at least as close to the
		# live target as the currently visible one. Together with the bounded
		# retarget count, this guarantees monotonically fresher revisions even while
		# the player moves continuously; the latest desired target is requested below.
		var published_target_cell := (
			job.dynamic_target_original_cell
			if job.dynamic_target_original_cell != Vector2i.MAX
			else job.target_cell
		)
		var target_lag := _get_goal_cell_set_distance(
			job.target_cells,
			slot.desired_goal_cells
		)
		var published_lag := 2147483647
		if not slot.published_field.is_empty():
			published_lag = _get_goal_cell_set_distance(
				slot.published_goal_cells,
				slot.desired_goal_cells
			)
		if (
			slot.published_field.is_empty()
			or target_lag <= published_lag
		):
			_publish_dynamic_flow_slot(
				slot,
				published_target_cell,
				job.target_cells,
				field
			)
		else:
			slot.pending_job_key = ""
		affected_slots.append(slot)
	runtime_flow_builds_completed += 1
	_remove_runtime_flow_build_job(job.cache_key)
	# Coalesce every target update that arrived during the build into at most one
	# successor request. Obsolete completions are discarded rather than resetting
	# the apparent age of a seconds-old anchor.
	for slot in affected_slots:
		_update_dynamic_flow_slot_request(
			slot,
			slot.desired_original_cell,
			slot.desired_resolved_cell,
			slot.desired_goal_cells,
			slot.desired_target_position,
			false
		)


func _remove_runtime_agent_grid_job(cache_key: String) -> void:
	runtime_agent_grid_build_jobs.erase(cache_key)
	runtime_agent_grid_build_order.erase(cache_key)


func _remove_runtime_flow_build_job(cache_key: String) -> void:
	var job := runtime_flow_build_jobs.get(cache_key) as RuntimeFlowBuildJob
	if job != null:
		_remove_runtime_flow_job_key_from_order(cache_key, job.priority)
	else:
		# Defensive repair for an externally corrupted queue. Production mutation
		# always owns both structures and therefore takes the counted branch above.
		runtime_flow_build_order.erase(cache_key)
		_rebuild_runtime_flow_priority_counts()
	runtime_flow_build_jobs.erase(cache_key)


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
	runtime_flow_priority_counts.fill(0)
	runtime_agent_grid_build_jobs.clear()
	runtime_agent_grid_build_order.clear()
	runtime_navigation_prefers_urgent_flow = true
	runtime_flow_priority_service_cursor = 0
	dynamic_flow_prefetch_dedupe_frame = -1
	dynamic_flow_prefetch_dedupe_generation = -1
	dynamic_flow_prefetch_keys_this_frame.clear()
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
	distances: Dictionary,
	use_flow_seed_as_endpoint: bool = false,
	recovery_cache_discriminator: String = ""
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
			traversal_types,
			recovery_cache_discriminator
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
	result.resolved_target_cell = (
		from_cell
		if flow_next_cell == from_cell
		else target_cell
	)
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
	if use_flow_seed_as_endpoint and route_distance == 0:
		result.waypoint = _map_to_global(from_cell)
		if from_global_position.distance_squared_to(result.waypoint) <= 0.25:
			result.status = NavigationStepStatus.ARRIVED
		return

	var endpoint_cell := from_cell if flow_next_cell == from_cell else target_cell
	var resolved_target_position := _map_to_global(endpoint_cell)
	if (
		endpoint_cell == target_cell
		and _is_global_position_walkable_for_agent(
		field_target_position,
		normalized_extents,
		traversal_types
		)
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
	traversal_types: int,
	target_contact_radius_world: float
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

	var normalized_extents := _get_dynamic_target_profile_extents(
		agent_half_extents
	)
	var original_from_cell := _global_to_map(from_global_position)
	var target_position := target_node.global_position
	var original_target_cell := _global_to_map(target_position)
	var normalized_contact_radius := maxf(target_contact_radius_world, 0.0)
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
		path_grid,
		normalized_contact_radius
	)
	if slot == null:
		result.reset(
			NavigationStepStatus.DEFERRED,
			original_from_cell,
			original_target_cell
		)
		return
	_expire_previous_dynamic_field_if_needed(slot)
	var desired_target_cell := slot.desired_resolved_cell
	var desired_goal_cells := slot.desired_goal_cells
	var desired_state_changed := (
		slot.desired_original_cell != original_target_cell
		or not slot.desired_goal_evaluation_valid
		or slot.desired_target_position.distance_squared_to(target_position) >= 4.0
	)
	if desired_state_changed:
		desired_goal_cells = _get_dynamic_target_goal_cells(
			original_target_cell,
			target_position,
			path_grid,
			traversal_types,
			normalized_contact_radius
		)
		desired_target_cell = _select_dynamic_goal_anchor(
			desired_goal_cells,
			target_position,
			slot
		)
	if desired_target_cell == Vector2i.MAX or desired_goal_cells.is_empty():
		if desired_state_changed:
			slot.desired_original_cell = original_target_cell
			slot.desired_resolved_cell = Vector2i.MAX
			slot.desired_target_position = target_position
			slot.desired_goal_cells = []
			slot.desired_goal_signature = ""
			slot.desired_build_region = _get_dynamic_flow_expansion_region(
				original_target_cell,
				slot.path_grid
			)
			slot.desired_goal_evaluation_valid = true
			slot.last_request_physics_frame = Engine.get_physics_frames()
			_detach_dynamic_flow_slot_from_pending_job(slot)
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
		desired_target_cell,
		desired_goal_cells,
		target_position,
		desired_state_changed
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

	var selected_field := slot.published_field
	var selected_anchor_cell := slot.published_anchor_cell
	var selected_revision := slot.published_revision
	var selected_next_cells := selected_field.get("next_cells", {}) as Dictionary
	var current_field_missing_walkable_source := (
		_is_cell_walkable(original_from_cell, path_grid)
		and not selected_next_cells.has(original_from_cell)
	)
	if (
		current_field_missing_walkable_source
		and not bool(selected_field.get("coverage_is_exhaustive", true))
	):
		_request_runtime_dynamic_flow_coverage_build(slot, original_from_cell)
	if (
		current_field_missing_walkable_source
		and _can_use_previous_dynamic_field(slot)
	):
		var previous_next_cells := slot.previous_published_field.get(
			"next_cells",
			{}
		) as Dictionary
		if previous_next_cells.has(original_from_cell):
			selected_field = slot.previous_published_field
			selected_anchor_cell = slot.previous_published_anchor_cell
			selected_revision = slot.previous_published_revision
			selected_next_cells = previous_next_cells

	var published_target_cell := selected_field.get(
		"target_cell",
		selected_anchor_cell
	) as Vector2i
	var next_cells := selected_next_cells
	var distances := selected_field.get("distances", {}) as Dictionary
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
		original_target_cell,
		selected_anchor_cell,
		selected_revision
	)
	# A published dynamic field always terminates at its immutable anchor. The
	# current player position is deliberately not substituted here: only the
	# Enemy's full-body line-of-sight sweep may approve a direct final segment.
	_write_navigation_step_from_flow_field(
		result,
		from_global_position,
		_map_to_global(published_target_cell),
		original_from_cell,
		original_target_cell,
		published_target_cell,
		normalized_extents,
		traversal_types,
		path_grid,
		next_cells,
		distances,
		true,
		"%s:%d" % [slot.slot_key, selected_revision]
	)
	if (
		result.status == NavigationStepStatus.UNREACHABLE
		and not bool(selected_field.get("coverage_is_exhaustive", true))
	):
		_request_runtime_dynamic_flow_coverage_build(slot, original_from_cell)
		result.reset(
			NavigationStepStatus.DEFERRED,
			original_from_cell,
			original_target_cell
		)
	# Expose the immutable field's live-target anchor separately from whichever
	# contact-region seed this particular consumer currently flows toward.
	result.resolved_target_cell = selected_anchor_cell
	result.dynamic_anchor_is_stale = (
		_chebyshev_cell_distance(
			selected_anchor_cell,
			original_target_cell
		)
		>= maxi(
			dynamic_target_max_usable_anchor_lag_cells,
			dynamic_target_repath_distance_cells
		)
	)


func _get_or_create_dynamic_flow_slot(
	target_node: Node2D,
	normalized_extents: Vector2,
	traversal_types: int,
	path_grid: AStarGrid2D,
	target_contact_radius_world: float
) -> DynamicFlowTargetSlot:
	var slot_key := _get_dynamic_flow_slot_key(
		target_node.get_instance_id(),
		normalized_extents,
		traversal_types,
		target_contact_radius_world
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
	slot.target_contact_radius_world = target_contact_radius_world
	slot.path_grid = path_grid
	dynamic_flow_target_slots[slot_key] = slot
	return slot


func _update_dynamic_flow_slot_request(
	slot: DynamicFlowTargetSlot,
	original_target_cell: Vector2i,
	desired_target_cell: Vector2i,
	desired_goal_cells: Array[Vector2i],
	target_position: Vector2,
	desired_state_changed: bool = true
) -> void:
	var current_physics_frame := Engine.get_physics_frames()
	slot.last_request_physics_frame = current_physics_frame
	if desired_state_changed:
		slot.desired_original_cell = original_target_cell
		slot.desired_resolved_cell = desired_target_cell
		slot.desired_target_position = target_position
		slot.desired_goal_cells = desired_goal_cells.duplicate()
		slot.desired_goal_signature = _get_goal_cells_signature(
			desired_goal_cells
		)
		slot.desired_goal_evaluation_valid = true
		slot.desired_build_region = _get_dynamic_flow_expansion_region(
			original_target_cell,
			slot.path_grid
		)

	var adopted_prewarmed_field := false
	if slot.published_field.is_empty():
		# Loading prewarm stores the initial player field in the fixed cache. Adopt
		# one complete immutable field immediately, then replace it with the bounded
		# multi-source contact field in the scheduler. This avoids a cold 0.3 s stop
		# on the first wall pursuit without putting moving footsteps in the fixed LRU.
		var prewarm_goal_candidates: Array[Vector2i] = desired_goal_cells.duplicate()
		prewarm_goal_candidates.erase(desired_target_cell)
		prewarm_goal_candidates.push_front(desired_target_cell)
		for prewarm_goal_cell: Vector2i in prewarm_goal_candidates:
			var prewarmed_field := _get_cached_flow_field(
				prewarm_goal_cell,
				slot.normalized_extents,
				slot.traversal_types
			)
			if prewarmed_field.is_empty():
				continue
			var adopted_goal_cells: Array[Vector2i] = [prewarm_goal_cell]
			_publish_dynamic_flow_slot(
				slot,
				original_target_cell,
				adopted_goal_cells,
				prewarmed_field
			)
			adopted_prewarmed_field = true
			break

	if slot.pending_job_key != "":
		var pending_job := runtime_flow_build_jobs.get(
			slot.pending_job_key
		) as RuntimeFlowBuildJob
		if pending_job == null:
			slot.pending_job_key = ""
		elif (
			pending_job.complete_when_required_sources_reached
			and _chebyshev_cell_distance(
				pending_job.dynamic_target_original_cell,
				original_target_cell
			) >= maxi(dynamic_target_repath_distance_cells, 1)
		):
			# Fresh bounded target work always preempts optional long-detour coverage.
			_detach_dynamic_flow_slot_from_pending_job(slot)
		elif (
			_chebyshev_cell_distance(
				pending_job.dynamic_target_original_cell,
				original_target_cell
			) >= maxi(dynamic_target_pending_retarget_distance_cells, 2)
			and slot.pending_retargets_since_publish
				< maxi(dynamic_target_max_pending_retargets_before_publish, 0)
		):
			_detach_dynamic_flow_slot_from_pending_job(slot)
			slot.pending_retargets_since_publish += 1
		else:
			return
	if adopted_prewarmed_field:
		_request_runtime_dynamic_flow_build(
			slot,
			desired_target_cell,
			desired_goal_cells,
			original_target_cell
		)
		return
	if slot.published_field.is_empty():
		_request_runtime_dynamic_flow_build(
			slot,
			desired_target_cell,
			desired_goal_cells,
			original_target_cell
		)
		return
	var anchor_distance := _chebyshev_cell_distance(
		slot.published_anchor_cell,
		original_target_cell
	)
	var goal_signature_changed := (
		slot.desired_goal_signature
		!= slot.published_goal_signature
	)
	if anchor_distance == 0 and not goal_signature_changed:
		return
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
		or (
			anchor_age >= maximum_age_frames
			and (anchor_distance > 0 or goal_signature_changed)
		)
	):
		_request_runtime_dynamic_flow_build(
			slot,
			desired_target_cell,
			desired_goal_cells,
			original_target_cell
		)


func _detach_dynamic_flow_slot_from_pending_job(
	slot: DynamicFlowTargetSlot
) -> void:
	if slot == null or slot.pending_job_key == "":
		return
	var job_key := slot.pending_job_key
	var job := runtime_flow_build_jobs.get(job_key) as RuntimeFlowBuildJob
	slot.pending_job_key = ""
	if job == null:
		return
	job.waiting_dynamic_slots.erase(slot.slot_key)
	if job.waiting_dynamic_slots.is_empty() and not job.publish_to_fixed_cache:
		_cancel_runtime_flow_build_job(job_key)


func _publish_dynamic_flow_slot(
	slot: DynamicFlowTargetSlot,
	anchor_cell: Vector2i,
	goal_cells: Array[Vector2i],
	field: Dictionary
) -> void:
	if slot == null or field.is_empty():
		return
	if not slot.published_field.is_empty():
		slot.previous_published_anchor_cell = slot.published_anchor_cell
		slot.previous_published_goal_cells = slot.published_goal_cells.duplicate()
		slot.previous_published_build_region = slot.published_build_region
		slot.previous_published_field = slot.published_field
		slot.previous_retained_physics_frame = Engine.get_physics_frames()
		slot.previous_published_revision = slot.published_revision
	slot.published_anchor_cell = anchor_cell
	slot.published_goal_cells = goal_cells.duplicate()
	slot.published_goal_signature = _get_goal_cells_signature(goal_cells)
	slot.published_goal_lookup.clear()
	for goal_cell in slot.published_goal_cells:
		slot.published_goal_lookup[goal_cell] = true
	slot.published_build_region = field.get("build_region", Rect2i()) as Rect2i
	slot.published_field = field
	slot.published_revision += 1
	slot.published_physics_frame = Engine.get_physics_frames()
	slot.pending_job_key = ""
	slot.pending_retargets_since_publish = 0


func _can_use_previous_dynamic_field(slot: DynamicFlowTargetSlot) -> bool:
	_expire_previous_dynamic_field_if_needed(slot)
	return slot != null and not slot.previous_published_field.is_empty()


func _expire_previous_dynamic_field_if_needed(
	slot: DynamicFlowTargetSlot
) -> void:
	if (
		slot == null
		or slot.previous_published_field.is_empty()
		or slot.previous_retained_physics_frame < 0
	):
		return
	var maximum_retention_frames := maxi(
		ceili(
			dynamic_previous_field_retention_seconds
			* float(maxi(Engine.physics_ticks_per_second, 1))
		),
		1
	)
	if (
		Engine.get_physics_frames() - slot.previous_retained_physics_frame
		<= maximum_retention_frames
	):
		return
	# A source-driven continuation may contain most of the authored map. Release
	# it as soon as its brief handoff window expires instead of retaining two large
	# Dictionary graphs for the lifetime of an otherwise active target slot.
	slot.previous_published_anchor_cell = Vector2i.MAX
	slot.previous_published_goal_cells = []
	slot.previous_published_build_region = Rect2i()
	slot.previous_published_field = {}
	slot.previous_retained_physics_frame = -1
	slot.previous_published_revision = -1


func _bind_dynamic_flow_query_context(
	context: FlowQueryContext,
	slot: DynamicFlowTargetSlot,
	requested_target_position: Vector2,
	original_target_cell: Vector2i,
	resolved_anchor_cell: Vector2i = Vector2i.MAX,
	selected_revision: int = -1
) -> void:
	if context == null or slot == null:
		return
	context.generation = navigation_generation
	context.target_is_static = false
	context.requested_target_position = requested_target_position
	context.original_target_cell = original_target_cell
	context.resolved_target_cell = (
		resolved_anchor_cell
		if resolved_anchor_cell != Vector2i.MAX
		else slot.published_anchor_cell
	)
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
	context.dynamic_slot_revision = (
		selected_revision if selected_revision >= 0 else slot.published_revision
	)


func _get_dynamic_flow_slot_key(
	target_instance_id: int,
	normalized_extents: Vector2,
	traversal_types: int,
	target_contact_radius_world: float
) -> String:
	return "%d:%s:%d" % [
		target_instance_id,
		_get_agent_grid_cache_key(normalized_extents, traversal_types),
		roundi(maxf(target_contact_radius_world, 0.0) * 10.0),
	]


func _get_dynamic_flow_job_cache_key(
	slot: DynamicFlowTargetSlot,
	original_target_cell: Vector2i,
	goal_cells: Array[Vector2i]
) -> String:
	var goal_parts := PackedStringArray()
	for goal_cell in goal_cells:
		goal_parts.append("%d,%d" % [goal_cell.x, goal_cell.y])
	return "dynamic:%s:%d,%d:%s" % [
		_get_agent_grid_cache_key(slot.normalized_extents, slot.traversal_types),
		original_target_cell.x,
		original_target_cell.y,
		";".join(goal_parts),
	]


func _get_dynamic_target_goal_cells(
	original_target_cell: Vector2i,
	target_global_position: Vector2,
	path_grid: AStarGrid2D,
	traversal_types: int,
	target_contact_radius_world: float
) -> Array[Vector2i]:
	var result: Array[Vector2i] = []
	if path_grid == null:
		return result
	# The goal is a geographic contact envelope, not the player's exact cell.
	# Every seed must be standable by this body profile, close enough for the two
	# collision envelopes to meet, and have raw-terrain line of sight to the live
	# player. A wall therefore removes seeds on its opposite side instead of an
	# arbitrary nearest-cell scan choosing one side for the entire horde.
	var contact_radius := maxf(target_contact_radius_world, 0.5)
	var minimum_cell_size := maxf(
		minf(absf(astar_grid.cell_size.x), absf(astar_grid.cell_size.y)),
		1.0
	)
	var search_radius := mini(
		maxi(ceili(contact_radius / minimum_cell_size) + 1, 1),
		maxi(max_nearest_cell_search_radius, 1)
	)
	var maximum_distance_squared := contact_radius * contact_radius + 0.01
	for y in range(
		original_target_cell.y - search_radius,
		original_target_cell.y + search_radius + 1
	):
		for x in range(
			original_target_cell.x - search_radius,
			original_target_cell.x + search_radius + 1
		):
			var candidate := Vector2i(x, y)
			if not _is_cell_walkable(candidate, path_grid):
				continue
			var candidate_position := _map_to_global(candidate)
			if (
				candidate_position.distance_squared_to(target_global_position)
				> maximum_distance_squared
			):
				continue
			if not _is_raw_navigation_segment_walkable(
				candidate_position,
				target_global_position,
				traversal_types
			):
				continue
			result.append(candidate)
	if not result.is_empty():
		return result

	# Never fall back to an arbitrary nearest walkable cell. Around a thin wall
	# that cell may be in the opposite connected component, which would publish
	# one wrong anchor to the complete pursuing cohort. No certified same-side
	# contact seed is an explicit unreachable result until the target moves.
	return result


func _select_dynamic_goal_anchor(
	goal_cells: Array[Vector2i],
	target_global_position: Vector2,
	slot: DynamicFlowTargetSlot
) -> Vector2i:
	if goal_cells.is_empty():
		return Vector2i.MAX
	if slot != null and not slot.published_goal_lookup.is_empty():
		for goal_cell in goal_cells:
			if slot.published_goal_lookup.has(goal_cell):
				return goal_cell
	var best_cell := goal_cells[0]
	var best_distance := _map_to_global(best_cell).distance_squared_to(
		target_global_position
	)
	for index in range(1, goal_cells.size()):
		var candidate := goal_cells[index]
		var candidate_distance := _map_to_global(candidate).distance_squared_to(
			target_global_position
		)
		if candidate_distance < best_distance:
			best_cell = candidate
			best_distance = candidate_distance
	return best_cell


func _get_dynamic_flow_expansion_region(
	original_target_cell: Vector2i,
	path_grid: AStarGrid2D
) -> Rect2i:
	if path_grid == null:
		return Rect2i()
	var radius := maxi(dynamic_target_flow_radius_cells, 1)
	return Rect2i(
		original_target_cell - Vector2i(radius, radius),
		Vector2i(radius * 2 + 1, radius * 2 + 1)
	).intersection(path_grid.region)


func _get_goal_cells_signature(goal_cells: Array[Vector2i]) -> String:
	var parts := PackedStringArray()
	for goal_cell in goal_cells:
		parts.append("%d,%d" % [goal_cell.x, goal_cell.y])
	return ";".join(parts)


func _get_goal_cell_set_distance(
	from_cells: Array[Vector2i],
	to_cells: Array[Vector2i]
) -> int:
	if from_cells.is_empty() or to_cells.is_empty():
		return 2147483647
	var best_distance := 2147483647
	for from_cell in from_cells:
		for to_cell in to_cells:
			best_distance = mini(
				best_distance,
				_chebyshev_cell_distance(from_cell, to_cell)
			)
			if best_distance == 0:
				return 0
	return best_distance


func _is_raw_navigation_segment_walkable(
	from_global_position: Vector2,
	to_global_position: Vector2,
	traversal_types: int
) -> bool:
	var from_local := obstacle_tile_layer.to_local(from_global_position)
	var to_local := obstacle_tile_layer.to_local(to_global_position)
	var current_cell := obstacle_tile_layer.local_to_map(from_local)
	var target_cell := obstacle_tile_layer.local_to_map(to_local)
	if _is_cell_blocked(current_cell, traversal_types):
		return false
	if current_cell == target_cell:
		return true

	# Grid DDA visits every cell touched by the real sub-cell segment. At an exact
	# corner crossing both orthogonal neighbors are checked before the diagonal
	# cell, preventing a goal seed from seeing through two touching wall corners.
	var delta := to_local - from_local
	var step_x := signi(roundi(signf(delta.x)))
	var step_y := signi(roundi(signf(delta.y)))
	var cell_size := astar_grid.cell_size.abs()
	var t_delta_x := INF if step_x == 0 else cell_size.x / absf(delta.x)
	var t_delta_y := INF if step_y == 0 else cell_size.y / absf(delta.y)
	var current_center := obstacle_tile_layer.map_to_local(current_cell)
	var next_boundary_x := current_center.x + float(step_x) * cell_size.x * 0.5
	var next_boundary_y := current_center.y + float(step_y) * cell_size.y * 0.5
	var t_max_x := INF if step_x == 0 else (next_boundary_x - from_local.x) / delta.x
	var t_max_y := INF if step_y == 0 else (next_boundary_y - from_local.y) / delta.y
	var maximum_steps := (
		absi(target_cell.x - current_cell.x)
		+ absi(target_cell.y - current_cell.y)
		+ 2
	)
	for _step_index in range(maximum_steps):
		if is_equal_approx(t_max_x, t_max_y):
			var horizontal_cell := current_cell + Vector2i(step_x, 0)
			var vertical_cell := current_cell + Vector2i(0, step_y)
			if (
				_is_cell_blocked(horizontal_cell, traversal_types)
				or _is_cell_blocked(vertical_cell, traversal_types)
			):
				return false
			current_cell += Vector2i(step_x, step_y)
			t_max_x += t_delta_x
			t_max_y += t_delta_y
		elif t_max_x < t_max_y:
			current_cell.x += step_x
			t_max_x += t_delta_x
		else:
			current_cell.y += step_y
			t_max_y += t_delta_y
		if _is_cell_blocked(current_cell, traversal_types):
			return false
		if current_cell == target_cell:
			return true
	return false


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
		"dynamic_anchor_is_stale": result.dynamic_anchor_is_stale,
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
	traversal_types: int,
	flow_revision_discriminator: String = ""
) -> Dictionary:
	# Hundreds of enemies often enter the same conservative blocked band at the
	# same cell. The recovery corridor depends only on the current navigation
	# generation, flow profile, origin and configured search radius, so share it
	# just like the flow field instead of rerunning bounded Dijkstra per enemy.
	var cache_key := "%d:%s:%d:%d:%d:%s" % [
		navigation_generation,
		_get_flow_field_cache_key(target_cell, agent_half_extents, traversal_types),
		origin_cell.x,
		origin_cell.y,
		maxi(max_nearest_cell_search_radius, 0),
		flow_revision_discriminator,
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
	for cell_index in range(total_cells):
		_write_agent_transition_mask_cell(snapshot, cell_index)
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
	snapshot.solid_cells.resize(
		path_grid.region.size.x * path_grid.region.size.y
	)
	snapshot.solid_cells.fill(0)
	snapshot.transition_masks.resize(
		path_grid.region.size.x * path_grid.region.size.y
	)
	snapshot.transition_masks.fill(0)
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
	snapshot.solid_cells[cell_index] = solid_value
	snapshot.values[destination_index] = (
		solid_value
		+ snapshot.values[(prefix_y - 1) * snapshot.stride + prefix_x]
		+ snapshot.values[prefix_y * snapshot.stride + prefix_x - 1]
		- snapshot.values[(prefix_y - 1) * snapshot.stride + prefix_x - 1]
	)


func _write_agent_transition_mask_cell(
	snapshot: AgentSolidIntegralSnapshot,
	cell_index: int
) -> void:
	if snapshot == null:
		return
	var width := snapshot.region.size.x
	var height := snapshot.region.size.y
	var total_cells := width * height
	if cell_index < 0 or cell_index >= total_cells:
		return
	if snapshot.solid_cells[cell_index] != 0:
		snapshot.transition_masks[cell_index] = 0
		return
	var local_x := cell_index % width
	var local_y := floori(float(cell_index) / float(width))
	var transition_mask := 0
	for direction_index in range(FLOW_DIRECTIONS.size()):
		var direction := FLOW_DIRECTIONS[direction_index]
		var target_x := local_x + direction.x
		var target_y := local_y + direction.y
		if (
			target_x < 0
			or target_y < 0
			or target_x >= width
			or target_y >= height
		):
			continue
		var target_index := target_y * width + target_x
		if snapshot.solid_cells[target_index] != 0:
			continue
		if direction.x != 0 and direction.y != 0:
			var horizontal_index := local_y * width + target_x
			var vertical_index := target_y * width + local_x
			if (
				snapshot.solid_cells[horizontal_index] != 0
				or snapshot.solid_cells[vertical_index] != 0
			):
				continue
		transition_mask |= 1 << direction_index
	snapshot.transition_masks[cell_index] = transition_mask


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
		or snapshot.solid_cells.size()
			!= snapshot.region.size.x * snapshot.region.size.y
		or snapshot.transition_masks.size()
			!= snapshot.region.size.x * snapshot.region.size.y
	):
		return null
	return snapshot


func _is_agent_navigation_profile_valid(
	profile: AgentNavigationProfile
) -> bool:
	if (
		profile == null
		or not is_built
		or profile.generation != navigation_generation
		or profile.path_grid == null
		or profile.solid_integral_snapshot == null
		or profile.path_grid.region != astar_grid.region
	):
		return false
	var snapshot := profile.solid_integral_snapshot
	return (
		snapshot.generation == navigation_generation
		and snapshot.region == astar_grid.region
		and snapshot.stride == snapshot.region.size.x + 1
		and snapshot.values.size()
			== (snapshot.region.size.x + 1) * (snapshot.region.size.y + 1)
	)


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


func _get_dynamic_target_profile_extents(
	agent_half_extents: Vector2
) -> Vector2:
	var normalized_extents := _normalize_agent_half_extents(agent_half_extents)
	if (
		not coalesce_dynamic_target_profiles_by_grid_topology
		or astar_grid == null
	):
		return normalized_extents
	return Vector2(
		_get_grid_topology_axis_extent(
			normalized_extents.x,
			absf(astar_grid.cell_size.x)
		),
		_get_grid_topology_axis_extent(
			normalized_extents.y,
			absf(astar_grid.cell_size.y)
		)
	)


func _store_dynamic_target_profile_grid_alias(
	normalized_extents: Vector2,
	traversal_types: int,
	path_grid: AStarGrid2D,
	snapshot: AgentSolidIntegralSnapshot
) -> void:
	if path_grid == null or snapshot == null:
		return
	var dynamic_extents := _get_dynamic_target_profile_extents(
		normalized_extents
	)
	if dynamic_extents == normalized_extents:
		return
	# The zero-clearance topology is the already-published base grid. For other
	# topology-equivalent profiles, alias the immutable grid/snapshot rather than
	# rebuilding the same cells under another extents key.
	if dynamic_extents == Vector2.ZERO:
		return
	var dynamic_cache_key := _get_agent_grid_cache_key(
		dynamic_extents,
		traversal_types
	)
	if agent_grid_cache.has(dynamic_cache_key):
		return
	agent_grid_cache[dynamic_cache_key] = path_grid
	agent_open_plain_integral_cache[dynamic_cache_key] = snapshot


func _store_dynamic_target_flow_alias(
	target_cell: Vector2i,
	normalized_extents: Vector2,
	traversal_types: int,
	field: Dictionary
) -> void:
	if field.is_empty():
		return
	var dynamic_extents := _get_dynamic_target_profile_extents(
		normalized_extents
	)
	if dynamic_extents == normalized_extents:
		return
	if not _get_cached_flow_field(
		target_cell,
		dynamic_extents,
		traversal_types
	).is_empty():
		return
	_store_flow_field(
		target_cell,
		dynamic_extents,
		traversal_types,
		field
	)


func _get_grid_topology_axis_extent(extent: float, cell_size: float) -> float:
	var safe_cell_size := maxf(cell_size, 0.001)
	var collision_reach := (
		maxf(extent, 0.0)
		+ maxf(agent_clearance_padding, 0.0)
		+ safe_cell_size * 0.5
	)
	# `_is_local_position_walkable_for_agent()` rejects a neighboring obstacle
	# only while its center distance is strictly below collision_reach. Collapse
	# all extents that reach the same number of grid rows/columns to the smallest
	# integer extent with exactly that topology.
	var reached_neighbor_count := maxi(
		ceili((collision_reach - 0.001) / safe_cell_size) - 1,
		0
	)
	if reached_neighbor_count <= 0:
		return 0.0
	return float(ceili(maxf(
		float(reached_neighbor_count) * safe_cell_size
			- safe_cell_size * 0.5
			- maxf(agent_clearance_padding, 0.0)
			+ 0.001,
		0.0
	)))


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
			var blocked_center := obstacle_tile_layer.map_to_local(blocked_cell)
			var delta := (local_position - blocked_center).abs()
			if delta.x >= collision_reach.x or delta.y >= collision_reach.y:
				continue
			if _is_cell_blocked(blocked_cell, traversal_types):
				return false
	return true


# 检查指定的网格单元是否被障碍物或当前移动能力不可通过的地形阻挡。
func _is_cell_blocked(
	cell: Vector2i,
	traversal_types: int = DEFAULT_TRAVERSAL_TYPES
) -> bool:
	var flags := _get_raw_navigation_cell_flags(cell)
	if flags < 0:
		return true
	if (flags & NAVIGATION_CELL_OBSTACLE_FLAG) != 0:
		return true
	if terrain_map == null:
		return false
	return (flags & traversal_types & NAVIGATION_CELL_TRAVERSAL_MASK) == 0


func _is_obstacle_cell_blocked(cell: Vector2i) -> bool:
	var flags := _get_raw_navigation_cell_flags(cell)
	return flags < 0 or (flags & NAVIGATION_CELL_OBSTACLE_FLAG) != 0


func _get_raw_navigation_cell_flags(cell: Vector2i) -> int:
	if (
		raw_navigation_snapshot_generation != navigation_generation
		or raw_navigation_snapshot_region != astar_grid.region
		or not raw_navigation_snapshot_region.has_point(cell)
	):
		return -1
	var local_cell := cell - raw_navigation_snapshot_region.position
	var cell_index := (
		local_cell.y * raw_navigation_snapshot_region.size.x + local_cell.x
	)
	if cell_index < 0 or cell_index >= raw_navigation_cell_snapshot.size():
		return -1
	return int(raw_navigation_cell_snapshot[cell_index])


func _build_raw_navigation_cell_snapshot(region: Rect2i) -> PackedByteArray:
	var snapshot := PackedByteArray()
	var total_cells := region.size.x * region.size.y
	if total_cells <= 0:
		return snapshot
	snapshot.resize(total_cells)
	for local_y in range(region.size.y):
		for local_x in range(region.size.x):
			var cell := region.position + Vector2i(local_x, local_y)
			var flags := _get_live_terrain_traversal_flags(cell)
			if _is_obstacle_cell_blocked_live(cell):
				flags |= NAVIGATION_CELL_OBSTACLE_FLAG
			snapshot[local_y * region.size.x + local_x] = flags
	return snapshot


func _build_raw_obstacle_integral_snapshot(
	region: Rect2i,
	cell_snapshot: PackedByteArray
) -> PackedInt32Array:
	var integral := PackedInt32Array()
	var width := region.size.x
	var height := region.size.y
	if (
		width <= 0
		or height <= 0
		or cell_snapshot.size() != width * height
	):
		return integral
	var stride := width + 1
	integral.resize(stride * (height + 1))
	for local_y in range(height):
		var row_obstacle_count := 0
		for local_x in range(width):
			var cell_flags := int(cell_snapshot[local_y * width + local_x])
			if (cell_flags & NAVIGATION_CELL_OBSTACLE_FLAG) != 0:
				row_obstacle_count += 1
			var integral_index := (local_y + 1) * stride + local_x + 1
			integral[integral_index] = (
				integral[local_y * stride + local_x + 1]
				+ row_obstacle_count
			)
	return integral


func _get_raw_obstacle_count_in_cell_rect(
	minimum_cell: Vector2i,
	maximum_cell: Vector2i
) -> int:
	var local_minimum := minimum_cell - raw_navigation_snapshot_region.position
	var local_maximum_exclusive := (
		maximum_cell - raw_navigation_snapshot_region.position + Vector2i.ONE
	)
	var stride := raw_obstacle_integral_stride
	var top_left := local_minimum.y * stride + local_minimum.x
	var top_right := (
		local_minimum.y * stride + local_maximum_exclusive.x
	)
	var bottom_left := (
		local_maximum_exclusive.y * stride + local_minimum.x
	)
	var bottom_right := (
		local_maximum_exclusive.y * stride + local_maximum_exclusive.x
	)
	return (
		int(raw_obstacle_integral_snapshot[bottom_right])
		- int(raw_obstacle_integral_snapshot[top_right])
		- int(raw_obstacle_integral_snapshot[bottom_left])
		+ int(raw_obstacle_integral_snapshot[top_left])
	)


func _get_live_terrain_traversal_flags(cell: Vector2i) -> int:
	if terrain_map == null:
		return NAVIGATION_CELL_TRAVERSAL_MASK
	var terrain_cell := terrain_map.world_to_map(_map_to_global(cell))
	return (
		terrain_map.get_terrain_traversal_type(terrain_cell)
		& NAVIGATION_CELL_TRAVERSAL_MASK
	)


func _is_obstacle_cell_blocked_live(cell: Vector2i) -> bool:
	var tile_data := obstacle_tile_layer.get_cell_tile_data(cell)
	if tile_data == null:
		# In dual-grid scenes the obstacle layer is sparse: open dirt/grass lives
		# in the semantic terrain map and only authored structures occupy this
		# layer. A missing obstacle tile therefore means "no obstacle", while
		# legacy scenes without a terrain map retain their closed-grid behavior.
		return terrain_map == null

	return tile_data.get_collision_polygons_count(tile_physics_layer_index) > 0
