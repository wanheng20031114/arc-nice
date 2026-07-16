extends SceneTree

const PLAYER_SCENE := preload("res://scene/player/weishidaier/player_weishidaier.tscn")
const FAST_CONFIG := preload("res://resources/config/enemies/yuanshi_insect_fast.tres")

var failures: Array[String] = []
var test_root: Node2D


class FakePathfinder:
	extends Node

	var is_built := true
	var requested_safe_step := false
	var safe_step: Dictionary = {
		"status": GridPathfinder.NavigationStepStatus.UNREACHABLE,
	}

	func try_get_safe_navigation_step(
		_from_global_position: Vector2,
		_to_global_position: Vector2,
		_agent_half_extents: Vector2 = Vector2.ZERO,
		_traversal_types: int = DualGridTilemap.TraversalType.LAND
	) -> Dictionary:
		requested_safe_step = true
		return safe_step.duplicate()


class FakeDynamicPathfinder:
	extends GridPathfinder

	var requested_dynamic_step := false
	var open_plain_is_clear := true
	var segment_is_clear := true
	var dynamic_status := GridPathfinder.NavigationStepStatus.READY
	var dynamic_waypoint := Vector2.ZERO
	var dynamic_live_target_cell := Vector2i(20, 0)
	var dynamic_anchor_cell := Vector2i(10, 0)
	var dynamic_from_cell := Vector2i.ZERO
	var dynamic_next_cell := Vector2i(1, 0)
	var requested_contact_radius_world := 0.0
	var open_plain_query_count := 0
	var segment_query_deltas: Array[Vector2] = []

	func _ready() -> void:
		is_built = true
		astar_grid.cell_size = Vector2(16.0, 16.0)
		set_process(false)

	func try_write_dynamic_target_navigation_step(
		result: GridPathfinder.NavigationStepResult,
		context: GridPathfinder.FlowQueryContext,
		_from_global_position: Vector2,
		_target_node: Node2D,
		_agent_half_extents: Vector2 = Vector2.ZERO,
		_traversal_types: int = GridPathfinder.DEFAULT_TRAVERSAL_TYPES,
		_target_contact_radius_world: float = 0.0
	) -> void:
		requested_dynamic_step = true
		requested_contact_radius_world = _target_contact_radius_world
		result.reset(dynamic_status, dynamic_from_cell, dynamic_live_target_cell)
		result.waypoint = dynamic_waypoint
		result.resolved_from_cell = dynamic_from_cell
		result.resolved_target_cell = dynamic_anchor_cell
		result.next_cell = dynamic_next_cell
		result.is_complete_route = true
		result.dynamic_anchor_is_stale = (
			maxi(
				abs(dynamic_live_target_cell.x - dynamic_anchor_cell.x),
				abs(dynamic_live_target_cell.y - dynamic_anchor_cell.y)
			) >= 6
		)
		context.generation = navigation_generation
		context.dynamic_slot_key = "fake-live-player-slot"
		context.original_target_cell = dynamic_live_target_cell
		context.resolved_target_cell = dynamic_anchor_cell

	func try_is_navigation_open_plain(
		_from_global_position: Vector2,
		_to_global_position: Vector2,
		_agent_half_extents: Vector2 = Vector2.ZERO,
		_traversal_types: int = DualGridTilemap.TraversalType.LAND
	) -> Variant:
		open_plain_query_count += 1
		return open_plain_is_clear

	func try_is_navigation_segment_walkable(
		from_global_position: Vector2,
		to_global_position: Vector2,
		_agent_half_extents: Vector2 = Vector2.ZERO,
		_traversal_types: int = DualGridTilemap.TraversalType.LAND
	) -> Variant:
		segment_query_deltas.append(to_global_position - from_global_position)
		return segment_is_clear


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	test_root = Node2D.new()
	test_root.name = "YuanshiInsectNavigationSmokeTest"
	root.add_child(test_root)
	current_scene = test_root

	await _test_near_clear_player_uses_certified_short_probe()
	await _test_near_blocked_player_falls_back_to_flow()
	await _test_unreachable_never_direct_fallbacks()
	await _test_ready_step_moves_toward_waypoint()
	await _test_blocked_primary_axis_uses_safe_secondary_axis()
	await _test_blocked_only_axis_stops()
	await _test_deferred_without_cache_stops()
	await _test_deferred_reuses_only_shape_safe_cached_direction()
	await _test_outdated_dynamic_flow_prefers_live_player_on_open_plain()
	await _test_outdated_dynamic_flow_keeps_obstacle_route_when_not_certified()
	await _test_outdated_dynamic_flow_endpoint_never_waits_when_live_player_is_clear()
	await _test_far_stale_endpoint_does_not_issue_full_physics_sweep()
	await _test_contact_region_endpoint_finishes_sub_cell_player_approach()
	await _test_flow_direction_gains_bounded_direct_movement_certificate()
	await _test_uncertified_flow_direction_keeps_move_and_slide_fallback()

	test_root.queue_free()
	await process_frame
	await physics_frame

	if failures.is_empty():
		print("YUANSHI_INSECT_NAVIGATION_SMOKE_TEST_OK")
		quit()
		return
	for failure in failures:
		push_error(failure)
	quit(1)


func _test_near_clear_player_uses_certified_short_probe() -> void:
	var player := _spawn_player(Vector2(64.0, 32.0))
	var pathfinder := _spawn_dynamic_pathfinder()
	var enemy := _spawn_fast_insect(Vector2.ZERO, player, pathfinder)
	enemy.navigation_update_interval_frames = 1
	await physics_frame
	var move_direction := enemy.call("_get_navigation_move_direction", 0.016) as Vector2
	_expect(
		not pathfinder.requested_dynamic_step,
		"A nearby player with a clear bounded short-step certificate must bypass flow navigation."
	)
	_expect(
		pathfinder.open_plain_query_count == 0,
		"Ordinary nearby pursuit must use only its bounded short-step certificate."
	)
	_expect(
		move_direction.is_equal_approx(Vector2(64.0, 32.0).normalized()),
		"The moving-target fast path must preserve a true normalized diagonal."
	)
	await _free_fixture([enemy, pathfinder, player])


func _test_near_blocked_player_falls_back_to_flow() -> void:
	var player := _spawn_player(Vector2(64.0, 0.0))
	var wall := _spawn_wall(Vector2(14.0, 0.0), Vector2(16.0, 64.0))
	var pathfinder := _spawn_pathfinder()
	pathfinder.safe_step = _ready_step(Vector2(0.0, 32.0))
	var enemy := _spawn_fast_insect(Vector2.ZERO, player, pathfinder)
	enemy.navigation_update_interval_frames = 1
	await physics_frame
	var move_direction := enemy.call("_get_navigation_move_direction", 0.016) as Vector2
	_expect(
		pathfinder.requested_safe_step,
		"A wall-blocked nearby player must fall back to complete flow navigation."
	)
	_expect(move_direction == Vector2.DOWN, "The blocked direct tier must consume the safe flow step.")
	await _free_fixture([enemy, wall, pathfinder, player])


func _test_unreachable_never_direct_fallbacks() -> void:
	var player := _spawn_player(Vector2(248.0, 0.0))
	var pathfinder := _spawn_pathfinder()
	var enemy := _spawn_fast_insect(Vector2.ZERO, player, pathfinder)
	enemy.navigation_update_interval_frames = 1
	await physics_frame
	var move_direction := enemy.call("_get_navigation_move_direction", 0.016) as Vector2
	_expect(pathfinder.requested_safe_step, "Fast insect must request the unified safe-step API.")
	_expect(
		move_direction == Vector2.ZERO,
		"UNREACHABLE must stop when a distant target requires flow navigation."
	)
	await _free_fixture([enemy, pathfinder, player])


func _test_ready_step_moves_toward_waypoint() -> void:
	var player := _spawn_player(Vector2(264.0, 0.0))
	var pathfinder := _spawn_pathfinder()
	pathfinder.safe_step = _ready_step(Vector2(32.0, 0.0))
	var enemy := _spawn_fast_insect(Vector2.ZERO, player, pathfinder)
	enemy.navigation_update_interval_frames = 1
	await physics_frame
	var move_direction := enemy.call("_get_navigation_move_direction", 0.016) as Vector2
	_expect(move_direction == Vector2.RIGHT, "READY must move toward its safe waypoint.")
	await _free_fixture([enemy, pathfinder, player])


func _test_blocked_primary_axis_uses_safe_secondary_axis() -> void:
	var player := _spawn_player(Vector2(264.0, 32.0))
	var wall := _spawn_wall(Vector2(14.0, 0.0), Vector2(16.0, 64.0))
	var pathfinder := _spawn_pathfinder()
	pathfinder.safe_step = _ready_step(Vector2(32.0, 32.0))
	var enemy := _spawn_fast_insect(Vector2.ZERO, player, pathfinder)
	enemy.navigation_update_interval_frames = 1
	await physics_frame
	var move_direction := enemy.call("_get_navigation_move_direction", 0.016) as Vector2
	_expect(
		move_direction == Vector2.DOWN,
		"Safe-step consumer must use the unblocked secondary axis instead of entering a wall."
	)
	await _free_fixture([enemy, wall, pathfinder, player])


func _test_blocked_only_axis_stops() -> void:
	var player := _spawn_player(Vector2(264.0, 0.0))
	var wall := _spawn_wall(Vector2(14.0, 0.0), Vector2(16.0, 64.0))
	var pathfinder := _spawn_pathfinder()
	pathfinder.safe_step = _ready_step(Vector2(32.0, 0.0))
	var enemy := _spawn_fast_insect(Vector2.ZERO, player, pathfinder)
	enemy.navigation_update_interval_frames = 1
	await physics_frame
	var move_direction := enemy.call("_get_navigation_move_direction", 0.016) as Vector2
	_expect(move_direction == Vector2.ZERO, "Consumer must stop when the only step axis is physically blocked.")
	await _free_fixture([enemy, wall, pathfinder, player])


func _test_deferred_without_cache_stops() -> void:
	var player := _spawn_player(Vector2(264.0, 0.0))
	var pathfinder := _spawn_pathfinder()
	pathfinder.safe_step = {"status": GridPathfinder.NavigationStepStatus.DEFERRED}
	var enemy := _spawn_fast_insect(Vector2.ZERO, player, pathfinder)
	enemy.navigation_update_interval_frames = 1
	await physics_frame
	var move_direction := enemy.call("_get_navigation_move_direction", 0.016) as Vector2
	_expect(move_direction == Vector2.ZERO, "DEFERRED without a verified cached step must stop.")
	await _free_fixture([enemy, pathfinder, player])


func _test_deferred_reuses_only_shape_safe_cached_direction() -> void:
	var player := _spawn_player(Vector2(264.0, 264.0))
	var pathfinder := _spawn_pathfinder()
	pathfinder.safe_step = {"status": GridPathfinder.NavigationStepStatus.DEFERRED}
	var enemy := _spawn_fast_insect(Vector2.ZERO, player, pathfinder)
	enemy.navigation_update_interval_frames = 1
	enemy.cached_navigation_move_direction = Vector2.DOWN
	var move_direction := enemy.call("_get_navigation_move_direction", 0.016) as Vector2
	_expect(move_direction == Vector2.DOWN, "DEFERRED may reuse the last shape-safe verified direction.")
	var wall := _spawn_wall(Vector2(0.0, 7.5), Vector2(64.0, 8.0))
	await physics_frame
	enemy.cached_navigation_move_direction = Vector2.DOWN
	move_direction = enemy.call("_get_navigation_move_direction", 0.016) as Vector2
	_expect(move_direction == Vector2.ZERO, "DEFERRED must discard a cached direction once physics blocks it.")
	await _free_fixture([enemy, wall, pathfinder, player])


func _test_outdated_dynamic_flow_prefers_live_player_on_open_plain() -> void:
	var player := _spawn_player(Vector2(320.0, 64.0))
	var pathfinder := _spawn_dynamic_pathfinder()
	pathfinder.dynamic_waypoint = Vector2(-32.0, 0.0)
	var enemy := _spawn_fast_insect(Vector2.ZERO, player, pathfinder)
	enemy.navigation_update_interval_frames = 1
	await physics_frame
	var move_direction := enemy.call("_get_navigation_move_direction", 0.016) as Vector2
	_expect(pathfinder.requested_dynamic_step, "A far live player must use the shared dynamic slot API.")
	_expect(
		pathfinder.open_plain_query_count == 1,
		"Bypassing a stale dynamic field must request one complete-corridor certificate."
	)
	_expect(
		move_direction.is_equal_approx(player.global_position.normalized()),
		"An outdated open-terrain flow must immediately correct toward the live player."
	)
	_expect(
		enemy.cached_navigation_uses_direct_objective_approach,
		"The live-player correction must retain a bounded collision certificate between staggered updates."
	)
	await _free_fixture([enemy, pathfinder, player])


func _test_outdated_dynamic_flow_keeps_obstacle_route_when_not_certified() -> void:
	var player := _spawn_player(Vector2(320.0, 64.0))
	var pathfinder := _spawn_dynamic_pathfinder()
	pathfinder.open_plain_is_clear = false
	pathfinder.dynamic_waypoint = Vector2(0.0, 32.0)
	var enemy := _spawn_fast_insect(Vector2.ZERO, player, pathfinder)
	enemy.navigation_update_interval_frames = 1
	await physics_frame
	var move_direction := enemy.call("_get_navigation_move_direction", 0.016) as Vector2
	_expect(
		move_direction.is_equal_approx(Vector2.DOWN),
		(
			"A materially stale dynamic anchor must keep following its complete, "
			+ "collision-safe flow waypoint while the replacement builds; field "
			+ "freshness must never freeze the pursuing cohort."
		)
	)
	_expect(
		pathfinder.open_plain_query_count == 1,
		"A stale live-target correction must consult the complete-corridor certificate."
	)
	var queried_live_target_short_step := false
	for query_delta in pathfinder.segment_query_deltas:
		if absf(query_delta.x) > absf(query_delta.y):
			queried_live_target_short_step = true
			break
	_expect(
		not queried_live_target_short_step,
		(
			"A rejected complete corridor must not be replaced by a locally clear "
			+ "short probe toward the live player."
		)
	)
	_expect(
		enemy.cached_navigation_uses_direct_objective_approach
		and enemy.cached_navigation_verified_direct_motion_clearance > 0.0,
		(
			"The stale live corridor must not be used, but the independently certified "
			+ "old flow waypoint may retain bounded direct translation."
		)
	)
	_expect(
		pathfinder.requested_contact_radius_world > 0.0,
		"Player pursuit must pass a derived collision contact radius into the shared dynamic slot."
	)
	await _free_fixture([enemy, pathfinder, player])


func _test_outdated_dynamic_flow_endpoint_never_waits_when_live_player_is_clear() -> void:
	var player := _spawn_player(Vector2(320.0, 0.0))
	var pathfinder := _spawn_dynamic_pathfinder()
	pathfinder.dynamic_waypoint = Vector2.ZERO
	pathfinder.dynamic_next_cell = pathfinder.dynamic_from_cell
	var enemy := _spawn_fast_insect(Vector2.ZERO, player, pathfinder)
	enemy.navigation_update_interval_frames = 1
	await physics_frame
	var move_direction := enemy.call("_get_navigation_move_direction", 0.016) as Vector2
	_expect(
		move_direction == Vector2.RIGHT,
		"Reaching an old flow anchor must not make an enemy wait there while the live player is directly reachable."
	)
	await _free_fixture([enemy, pathfinder, player])


func _test_far_stale_endpoint_does_not_issue_full_physics_sweep() -> void:
	var player := _spawn_player(Vector2(320.0, 0.0))
	var pathfinder := _spawn_dynamic_pathfinder()
	pathfinder.open_plain_is_clear = false
	pathfinder.dynamic_waypoint = Vector2.ZERO
	pathfinder.dynamic_next_cell = pathfinder.dynamic_from_cell
	var enemy := _spawn_fast_insect(Vector2.ZERO, player, pathfinder)
	enemy.navigation_update_interval_frames = 1
	await physics_frame
	Enemy.set_performance_metrics_enabled(true)
	var move_direction := enemy.call(
		"_get_flow_navigation_move_direction",
		player,
		pathfinder,
		1.0
	) as Vector2
	var metrics := Enemy.get_performance_metrics()
	Enemy.set_performance_metrics_enabled(false)
	_expect(
		move_direction == Vector2.ZERO,
		"A blocked far stale endpoint must wait for the staged replacement."
	)
	_expect(
		int(metrics.get("test_move_calls", -1)) == 0,
		(
			"A blocked far stale endpoint must not sweep the full distance to "
			+ "the live player for every enemy."
		)
	)
	await _free_fixture([enemy, pathfinder, player])


func _test_contact_region_endpoint_finishes_sub_cell_player_approach() -> void:
	var player := _spawn_player(Vector2(16.0, 0.0))
	var pathfinder := _spawn_dynamic_pathfinder()
	pathfinder.dynamic_live_target_cell = Vector2i.ZERO
	pathfinder.dynamic_anchor_cell = Vector2i.ZERO
	pathfinder.dynamic_waypoint = Vector2.ZERO
	pathfinder.dynamic_next_cell = pathfinder.dynamic_from_cell
	var enemy := _spawn_fast_insect(Vector2.ZERO, player, pathfinder)
	enemy.navigation_update_interval_frames = 1
	await physics_frame
	await physics_frame
	var move_direction := enemy.call(
		"_get_flow_navigation_move_direction",
		player,
		pathfinder,
		1.0
	) as Vector2
	_expect(
		move_direction == Vector2.RIGHT,
		(
			"A multi-source contact-region endpoint must finish the short "
			+ "collision-safe approach instead of stopping beside the player."
		)
	)
	_expect(
		enemy.cached_navigation_tracks_live_target_direction,
		"The final sub-cell approach must invalidate itself if the player crosses it."
	)
	await _free_fixture([enemy, pathfinder, player])


func _test_flow_direction_gains_bounded_direct_movement_certificate() -> void:
	var player := _spawn_player(Vector2(320.0, 0.0))
	var pathfinder := _spawn_dynamic_pathfinder()
	pathfinder.dynamic_live_target_cell = Vector2i(20, 0)
	pathfinder.dynamic_anchor_cell = Vector2i(20, 0)
	pathfinder.dynamic_waypoint = Vector2(32.0, 0.0)
	var enemy := _spawn_fast_insect(Vector2.ZERO, player, pathfinder)
	enemy.navigation_update_interval_frames = 3
	await physics_frame
	var move_direction := enemy.call("_get_navigation_move_direction", 0.016) as Vector2
	_expect(move_direction == Vector2.RIGHT, "A ready flow must retain its authored direction.")
	_expect(
		enemy.cached_navigation_uses_direct_objective_approach
		and enemy.cached_navigation_verified_direct_motion_clearance > 0.0,
		"An O(1)-certified flow segment must gain bounded direct movement clearance."
	)
	await _free_fixture([enemy, pathfinder, player])


func _test_uncertified_flow_direction_keeps_move_and_slide_fallback() -> void:
	var player := _spawn_player(Vector2(320.0, 0.0))
	var pathfinder := _spawn_dynamic_pathfinder()
	pathfinder.dynamic_live_target_cell = Vector2i(20, 0)
	pathfinder.dynamic_anchor_cell = Vector2i(20, 0)
	pathfinder.dynamic_waypoint = Vector2(32.0, 0.0)
	pathfinder.segment_is_clear = false
	var enemy := _spawn_fast_insect(Vector2.ZERO, player, pathfinder)
	enemy.navigation_update_interval_frames = 3
	await physics_frame
	var move_direction := enemy.call("_get_navigation_move_direction", 0.016) as Vector2
	_expect(move_direction == Vector2.RIGHT, "An uncertified flow must still provide movement.")
	_expect(
		not enemy.cached_navigation_uses_direct_objective_approach,
		"An uncertified flow must retain the move_and_slide fallback."
	)
	await _free_fixture([enemy, pathfinder, player])


func _ready_step(waypoint: Vector2) -> Dictionary:
	return {
		"status": GridPathfinder.NavigationStepStatus.READY,
		"waypoint": waypoint,
		"is_complete_route": true,
	}


func _spawn_pathfinder() -> FakePathfinder:
	var pathfinder := FakePathfinder.new()
	test_root.add_child(pathfinder)
	return pathfinder


func _spawn_dynamic_pathfinder() -> FakeDynamicPathfinder:
	var pathfinder := FakeDynamicPathfinder.new()
	test_root.add_child(pathfinder)
	return pathfinder


func _spawn_player(position: Vector2) -> Player:
	var player := PLAYER_SCENE.instantiate() as Player
	test_root.add_child(player)
	player.global_position = position
	return player


func _spawn_fast_insect(position: Vector2, player: Player, pathfinder: Node) -> YuanshiInsect:
	var enemy := FAST_CONFIG.enemy_scene.instantiate() as YuanshiInsect
	test_root.add_child(enemy)
	enemy.global_position = position
	enemy.setup(FAST_CONFIG, player, pathfinder)
	enemy.set_physics_process(false)
	return enemy


func _spawn_wall(position: Vector2, size: Vector2) -> StaticBody2D:
	var wall := StaticBody2D.new()
	wall.collision_layer = 1
	wall.collision_mask = 0
	var shape_node := CollisionShape2D.new()
	var rectangle := RectangleShape2D.new()
	rectangle.size = size
	shape_node.shape = rectangle
	wall.add_child(shape_node)
	test_root.add_child(wall)
	wall.global_position = position
	return wall


func _free_fixture(nodes: Array) -> void:
	for node in nodes:
		if node != null and is_instance_valid(node):
			node.queue_free()
	await physics_frame


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
