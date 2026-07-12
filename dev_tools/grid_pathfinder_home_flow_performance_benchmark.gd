extends SceneTree

const TOWER_SCENE := preload("res://scene/game_tower_defense.tscn")
const QUERY_COUNT := 300
const WARMUP_TICKS := 30
const MEASURE_TICKS := 240
const AGENT_HALF_EXTENTS := Vector2(8.0, 8.0)
const TRAVERSAL_TYPES := DualGridTilemap.TraversalType.LAND

var failures: Array[String] = []


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	var game := TOWER_SCENE.instantiate() as GameTowerDefense
	_expect(game != null, "Home flow benchmark must instantiate tower defense.")
	if game == null:
		_finish()
		return
	game.auto_start_waves = false
	root.add_child(game)
	await process_frame
	await physics_frame
	_stop_audio_players(game)

	var pathfinder := game.grid_pathfinder as GridPathfinder
	var home_targets := game.get_home_objective_targets()
	_expect(pathfinder != null and pathfinder.is_built, "Home flow benchmark requires a built grid.")
	_expect(not home_targets.is_empty(), "Home flow benchmark requires a Home target.")
	if pathfinder == null or not pathfinder.is_built or home_targets.is_empty():
		game.queue_free()
		await process_frame
		_finish()
		return

	game.process_mode = Node.PROCESS_MODE_DISABLED
	var home_target := home_targets[0] as Node2D
	var target_position := home_target.global_position
	pathfinder.prewarm_agent_grid(AGENT_HALF_EXTENTS, TRAVERSAL_TYPES)
	pathfinder.prewarm_flow_navigation_target(
		target_position,
		AGENT_HALF_EXTENTS,
		TRAVERSAL_TYPES
	)
	var query_positions := _collect_near_home_query_positions(
		pathfinder,
		target_position
	)
	_expect(
		query_positions.size() >= 16,
		"Home flow benchmark requires enough nearby complete-route cells."
	)
	if query_positions.size() < 16:
		game.queue_free()
		await process_frame
		_finish()
		return
	_verify_fast_path_equivalence(pathfinder, query_positions, target_position)

	var results: Array[GridPathfinder.NavigationStepResult] = []
	var contexts: Array[GridPathfinder.FlowQueryContext] = []
	for _query_index in range(QUERY_COUNT):
		results.append(GridPathfinder.NavigationStepResult.new())
		contexts.append(GridPathfinder.FlowQueryContext.new())

	var measured_usec := 0
	var ready_count := 0
	var deferred_count := 0
	var unreachable_count := 0
	var checksum := Vector2.ZERO
	var total_ticks := WARMUP_TICKS + MEASURE_TICKS
	for tick in range(total_ticks):
		var started_usec := Time.get_ticks_usec()
		for query_index in range(QUERY_COUNT):
			var from_position := query_positions[
				(query_index + tick) % query_positions.size()
			]
			var step := results[query_index]
			pathfinder.try_write_safe_navigation_step(
				step,
				contexts[query_index],
				from_position,
				target_position,
				AGENT_HALF_EXTENTS,
				TRAVERSAL_TYPES,
				true
			)
			var status := step.status
			if status == GridPathfinder.NavigationStepStatus.READY:
				ready_count += 1
				checksum += step.waypoint
				_expect(
					step.is_complete_route,
					"READY Home flow queries must retain the complete-route guarantee."
				)
			elif status == GridPathfinder.NavigationStepStatus.ARRIVED:
				ready_count += 1
			elif status == GridPathfinder.NavigationStepStatus.DEFERRED:
				deferred_count += 1
			else:
				unreachable_count += 1
		var elapsed_usec := Time.get_ticks_usec() - started_usec
		if tick >= WARMUP_TICKS:
			measured_usec += elapsed_usec

	var usec_per_tick := float(measured_usec) / float(MEASURE_TICKS)
	print(
		(
			"GRID_PATHFINDER_HOME_FLOW_BENCHMARK "
		+ "queries_per_tick=%d positions=%d usec_per_tick=%.1f usec_per_query=%.3f "
		+ "ready=%d deferred=%d unreachable=%d checksum=(%.1f,%.1f)"
		)
		% [
			QUERY_COUNT,
			query_positions.size(),
			usec_per_tick,
			usec_per_tick / float(QUERY_COUNT),
			ready_count,
			deferred_count,
			unreachable_count,
			checksum.x,
			checksum.y,
		]
	)
	_expect(deferred_count == 0, "A prewarmed shared Home field must never become DEFERRED.")
	_expect(unreachable_count == 0, "Nearby fixture cells must keep complete routes to Home.")
	_expect(checksum != Vector2.ZERO, "Home flow benchmark must consume navigation waypoints.")
	game.queue_free()
	await process_frame
	await physics_frame
	_finish()


func _verify_fast_path_equivalence(
	pathfinder: GridPathfinder,
	query_positions: Array[Vector2],
	target_position: Vector2
) -> void:
	var result := GridPathfinder.NavigationStepResult.new()
	var context := GridPathfinder.FlowQueryContext.new()
	for from_position in query_positions:
		var legacy := pathfinder.get_safe_navigation_step(
			from_position,
			target_position,
			AGENT_HALF_EXTENTS,
			TRAVERSAL_TYPES
		)
		pathfinder.write_safe_navigation_step(
			result,
			context,
			from_position,
			target_position,
			AGENT_HALF_EXTENTS,
			TRAVERSAL_TYPES,
			true
		)
		_expect(
			int(legacy.get("status", -1)) == result.status
			and (legacy.get("waypoint", Vector2.ZERO) as Vector2).is_equal_approx(result.waypoint)
			and (legacy.get("from_cell", Vector2i.MAX) as Vector2i) == result.from_cell
			and (legacy.get("resolved_from_cell", Vector2i.MAX) as Vector2i)
				== result.resolved_from_cell
			and (legacy.get("target_cell", Vector2i.MAX) as Vector2i) == result.target_cell
			and (legacy.get("resolved_target_cell", Vector2i.MAX) as Vector2i)
				== result.resolved_target_cell
			and (legacy.get("next_cell", Vector2i.MAX) as Vector2i) == result.next_cell
			and bool(legacy.get("used_start_recovery", false)) == result.used_start_recovery
			and bool(legacy.get("is_complete_route", false)) == result.is_complete_route
			and int(legacy.get("remaining_cell_distance", -1))
				== result.remaining_cell_distance,
			"Reusable Home flow results must exactly match every legacy result field."
		)
	context.generation = -1
	pathfinder.write_safe_navigation_step(
		result,
		context,
		query_positions[0],
		target_position,
		AGENT_HALF_EXTENTS,
		TRAVERSAL_TYPES,
		true
	)
	_expect(
		context.generation == pathfinder.navigation_generation
		and result.is_complete_route,
		"A stale reusable context must rebind to the current navigation generation."
	)


func _collect_near_home_query_positions(
	pathfinder: GridPathfinder,
	target_position: Vector2
) -> Array[Vector2]:
	var positions: Array[Vector2] = []
	var target_cell := pathfinder.call("_global_to_map", target_position) as Vector2i
	for radius in range(1, 13):
		for cell_y in range(target_cell.y - radius, target_cell.y + radius + 1):
			for cell_x in range(target_cell.x - radius, target_cell.x + radius + 1):
				if (
					cell_x != target_cell.x - radius
					and cell_x != target_cell.x + radius
					and cell_y != target_cell.y - radius
					and cell_y != target_cell.y + radius
				):
					continue
				var position := pathfinder.call("_map_to_global", Vector2i(cell_x, cell_y)) as Vector2
				var step := pathfinder.get_safe_navigation_step(
					position,
					target_position,
					AGENT_HALF_EXTENTS,
					TRAVERSAL_TYPES
				)
				var status := int(step.get("status", GridPathfinder.NavigationStepStatus.UNREACHABLE))
				if (
					(status == GridPathfinder.NavigationStepStatus.READY
					or status == GridPathfinder.NavigationStepStatus.ARRIVED)
					and bool(step.get("is_complete_route", false))
				):
					positions.append(position)
					if positions.size() >= 96:
						return positions
	return positions


func _stop_audio_players(node: Node) -> void:
	if node is AudioStreamPlayer or node is AudioStreamPlayer2D:
		node.stop()
	for child in node.get_children():
		_stop_audio_players(child)


func _finish() -> void:
	if failures.is_empty():
		print("GRID_PATHFINDER_HOME_FLOW_BENCHMARK_OK")
		quit()
		return
	for failure in failures:
		push_error(failure)
	quit(1)


func _expect(condition: bool, message: String) -> void:
	if not condition and not failures.has(message):
		failures.append(message)
