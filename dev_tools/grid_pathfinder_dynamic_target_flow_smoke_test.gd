extends SceneTree

const TOWER_SCENE := preload("res://scene/game_tower_defense.tscn")
const CONTEXT_COUNT := 300
const TEST_AGENT_HALF_EXTENTS := Vector2(8.0, 4.0)
const TEST_EXPANSIONS_PER_FRAME := 64
const MAX_MANUAL_BUILD_FRAMES := 10000

var failures: Array[String] = []


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	var game := TOWER_SCENE.instantiate() as GameTowerDefense
	if game == null:
		_expect(false, "Tower-defense scene must instantiate GameTowerDefense.")
		_finish(null, 0)
		return
	game.auto_start_waves = false
	root.add_child(game)
	current_scene = game
	await process_frame
	await physics_frame

	var pathfinder := game.get_node_or_null("GridPathfinder") as GridPathfinder
	_expect(
		pathfinder != null and pathfinder.is_built,
		"Tower defense must provide a built GridPathfinder."
	)
	if pathfinder == null or not pathfinder.is_built:
		_finish(game, 0)
		return

	# Build the body-profile grid outside the measured API call. The assertions
	# below then isolate a cold dynamic flow-field miss from agent-grid staging.
	var path_grid := pathfinder.call(
		"_get_or_create_agent_grid",
		TEST_AGENT_HALF_EXTENTS,
		GridPathfinder.DEFAULT_TRAVERSAL_TYPES
	) as AStarGrid2D
	_expect(path_grid != null, "The dynamic-flow test profile must have an agent grid.")
	var test_cells := _find_test_cells(pathfinder, path_grid)
	_expect(
		test_cells.size() == 4,
		"The tower map must provide a connected source and a walkable three-cell target lane."
	)
	if path_grid == null or test_cells.size() != 4:
		_finish(game, 0)
		return

	var source_cell: Vector2i = test_cells["source"]
	var anchor_cell: Vector2i = test_cells["anchor"]
	var adjacent_cell: Vector2i = test_cells["adjacent"]
	var repath_cell: Vector2i = test_cells["repath"]
	var source_position := pathfinder.call("_map_to_global", source_cell) as Vector2

	_reset_dynamic_runtime_state(pathfinder)
	pathfinder.runtime_navigation_max_expansions_per_frame = TEST_EXPANSIONS_PER_FRAME
	pathfinder.runtime_navigation_time_budget_usec = 8000
	pathfinder.dynamic_target_repath_distance_cells = 2
	pathfinder.dynamic_target_max_anchor_age_seconds = 2.0

	var target := Node2D.new()
	target.name = "DynamicFlowTargetProbe"
	game.add_child(target)
	target.global_position = pathfinder.call("_map_to_global", anchor_cell) as Vector2

	var results: Array[GridPathfinder.NavigationStepResult] = []
	var contexts: Array[GridPathfinder.FlowQueryContext] = []
	for _index in range(CONTEXT_COUNT):
		results.append(GridPathfinder.NavigationStepResult.new())
		contexts.append(GridPathfinder.FlowQueryContext.new())

	_test_cold_miss_and_deduplication(
		pathfinder,
		target,
		source_position,
		results,
		contexts
	)
	var build_frames := _complete_initial_build_atomically(
		pathfinder,
		target,
		source_position,
		anchor_cell,
		results,
		contexts
	)
	_test_anchor_hysteresis_and_successor_deduplication(
		pathfinder,
		target,
		source_position,
		anchor_cell,
		adjacent_cell,
		repath_cell,
		results,
		contexts
	)
	_test_two_targets_share_one_profile_anchor_job(
		pathfinder,
		game,
		source_position,
		repath_cell
	)
	_test_target_release_cancels_pending_job(pathfinder, target)
	var static_build_frames := _test_static_try_stages_and_publishes_fixed_cache(
		pathfinder,
		source_position,
		repath_cell
	)
	_test_rebuild_cancels_flow_and_agent_grid_jobs(
		pathfinder,
		game,
		source_position,
		anchor_cell,
		adjacent_cell
	)

	_finish(game, build_frames + static_build_frames)


func _test_cold_miss_and_deduplication(
	pathfinder: GridPathfinder,
	target: Node2D,
	source_position: Vector2,
	results: Array[GridPathfinder.NavigationStepResult],
	contexts: Array[GridPathfinder.FlowQueryContext]
) -> void:
	var fixed_cache_size_before := pathfinder.flow_field_cache.size()
	var synchronous_build_count_before := pathfinder.flow_field_builds_used_this_frame
	var completed_build_count_before := pathfinder.runtime_flow_builds_completed
	pathfinder.try_write_dynamic_target_navigation_step(
		results[0],
		contexts[0],
		source_position,
		target,
		TEST_AGENT_HALF_EXTENTS,
		GridPathfinder.DEFAULT_TRAVERSAL_TYPES
	)

	_expect(
		results[0].status == GridPathfinder.NavigationStepStatus.DEFERRED,
		"A cold dynamic target miss must return DEFERRED instead of building synchronously."
	)
	_expect(
		pathfinder.flow_field_cache.size() == fixed_cache_size_before,
		"A cold dynamic target miss must not populate the synchronous fixed flow cache."
	)
	_expect(
		pathfinder.flow_field_builds_used_this_frame == synchronous_build_count_before,
		"A cold dynamic target miss must not consume the synchronous flow-build budget."
	)
	_expect(
		pathfinder.runtime_flow_builds_completed == completed_build_count_before,
		"A cold dynamic target miss must only enqueue work, not complete it in the caller."
	)
	_expect(
		pathfinder.runtime_agent_grid_build_jobs.is_empty(),
		"The prebuilt body profile must not enqueue an unrelated agent-grid job."
	)
	_expect(
		pathfinder.dynamic_flow_target_slots.size() == 1
		and pathfinder.runtime_flow_build_jobs.size() == 1,
		"The first cold query must create exactly one dynamic slot and one staged flow job."
	)

	var initial_job: Variant = _only_value(pathfinder.runtime_flow_build_jobs)
	if initial_job != null:
		_expect(
			int(initial_job.get("pending_entry_count")) == 1
			and (initial_job.get("next_cells") as Dictionary).size() == 1
			and (initial_job.get("distances") as Dictionary).size() == 1,
			"The caller must observe only the staged job seed, never a synchronously expanded field."
		)

	for context_index in range(1, CONTEXT_COUNT):
		pathfinder.try_write_dynamic_target_navigation_step(
			results[context_index],
			contexts[context_index],
			source_position,
			target,
			TEST_AGENT_HALF_EXTENTS,
			GridPathfinder.DEFAULT_TRAVERSAL_TYPES
		)

	var all_deferred := true
	var shared_slot_key := contexts[0].dynamic_slot_key
	for context_index in range(CONTEXT_COUNT):
		if (
			results[context_index].status != GridPathfinder.NavigationStepStatus.DEFERRED
			or contexts[context_index].dynamic_slot_key != shared_slot_key
		):
			all_deferred = false
			break
	_expect(
		all_deferred and not shared_slot_key.is_empty(),
		"All 300 cold contexts must defer against the same dynamic target slot."
	)
	_expect(
		pathfinder.dynamic_flow_target_slots.size() == 1
		and pathfinder.runtime_flow_build_jobs.size() == 1
		and pathfinder.runtime_flow_build_order.size() == 1,
		"Three hundred equal target/profile queries must deduplicate to one slot and one job."
	)


func _complete_initial_build_atomically(
	pathfinder: GridPathfinder,
	target: Node2D,
	source_position: Vector2,
	anchor_cell: Vector2i,
	results: Array[GridPathfinder.NavigationStepResult],
	contexts: Array[GridPathfinder.FlowQueryContext]
) -> int:
	var build_frames := 0
	while (
		not pathfinder.runtime_flow_build_jobs.is_empty()
		and build_frames < MAX_MANUAL_BUILD_FRAMES
	):
		var slot_before: Variant = _only_value(pathfinder.dynamic_flow_target_slots)
		if slot_before != null:
			_expect(
				int(slot_before.get("published_revision")) == 0
				and (slot_before.get("published_field") as Dictionary).is_empty(),
				"A pending initial build must not expose a partial flow field."
			)

		pathfinder.set_process(false)
		pathfinder.call("_advance_runtime_navigation_jobs")
		pathfinder.set_process(false)
		build_frames += 1
		_expect(
			pathfinder.runtime_navigation_expansions_last_frame
			<= pathfinder.runtime_navigation_max_expansions_per_frame,
			"A runtime-navigation slice must never exceed its configured expansion cap."
		)

		if not pathfinder.runtime_flow_build_jobs.is_empty():
			pathfinder.try_write_dynamic_target_navigation_step(
				results[0],
				contexts[0],
				source_position,
				target,
				TEST_AGENT_HALF_EXTENTS,
				GridPathfinder.DEFAULT_TRAVERSAL_TYPES
			)
			_expect(
				results[0].status == GridPathfinder.NavigationStepStatus.DEFERRED,
				"The initial field must remain DEFERRED until its complete atomic publication."
			)

	_expect(
		build_frames < MAX_MANUAL_BUILD_FRAMES,
		"The staged dynamic flow build must complete within the smoke-test frame guard."
	)
	_expect(
		pathfinder.runtime_flow_build_jobs.is_empty(),
		"The completed initial dynamic flow build must leave no pending flow job."
	)
	var published_slot: Variant = _only_value(pathfinder.dynamic_flow_target_slots)
	if published_slot == null:
		_expect(false, "The completed dynamic flow build must retain its shared slot.")
		return build_frames
	_expect(
		int(published_slot.get("published_revision")) == 1
		and (published_slot.get("published_anchor_cell") as Vector2i) == anchor_cell
		and not (published_slot.get("published_field") as Dictionary).is_empty(),
		"Completion must atomically publish one complete field at the requested anchor."
	)
	_verify_runtime_field_matches_reference(
		pathfinder,
		published_slot.get("published_field") as Dictionary,
		anchor_cell
	)

	var ready_count := 0
	for context_index in range(CONTEXT_COUNT):
		pathfinder.try_write_dynamic_target_navigation_step(
			results[context_index],
			contexts[context_index],
			source_position,
			target,
			TEST_AGENT_HALF_EXTENTS,
			GridPathfinder.DEFAULT_TRAVERSAL_TYPES
		)
		if (
			results[context_index].status == GridPathfinder.NavigationStepStatus.READY
			and results[context_index].is_complete_route
			and contexts[context_index].dynamic_slot_revision == 1
		):
			ready_count += 1
	_expect(
		ready_count == CONTEXT_COUNT,
		"After publication, all 300 contexts must observe the same complete READY field."
	)
	return build_frames


func _verify_runtime_field_matches_reference(
	pathfinder: GridPathfinder,
	runtime_field: Dictionary,
	target_cell: Vector2i
) -> void:
	var path_grid := pathfinder.call(
		"_get_or_create_agent_grid",
		TEST_AGENT_HALF_EXTENTS,
		GridPathfinder.DEFAULT_TRAVERSAL_TYPES
	) as AStarGrid2D
	var reference_field := pathfinder.call(
		"_build_flow_field",
		target_cell,
		path_grid
	) as Dictionary
	var runtime_distances := runtime_field.get("distances", {}) as Dictionary
	var reference_distances := reference_field.get("distances", {}) as Dictionary
	_expect(
		runtime_distances.size() == reference_distances.size(),
		"The staged Dial field must cover exactly the synchronous reference component."
	)
	for cell_variant in reference_distances:
		var cell := cell_variant as Vector2i
		if (
			not runtime_distances.has(cell)
			or int(runtime_distances[cell]) != int(reference_distances[cell])
		):
			_expect(
				false,
				"The staged Dial field must preserve the exact Octile distance at %s."
				% cell
			)
			return


func _test_anchor_hysteresis_and_successor_deduplication(
	pathfinder: GridPathfinder,
	target: Node2D,
	source_position: Vector2,
	anchor_cell: Vector2i,
	adjacent_cell: Vector2i,
	repath_cell: Vector2i,
	results: Array[GridPathfinder.NavigationStepResult],
	contexts: Array[GridPathfinder.FlowQueryContext]
) -> void:
	var slot: Variant = _only_value(pathfinder.dynamic_flow_target_slots)
	if slot == null:
		_expect(false, "Anchor hysteresis requires the published dynamic slot.")
		return
	var published_revision := int(slot.get("published_revision"))

	target.global_position = pathfinder.call("_map_to_global", adjacent_cell) as Vector2
	pathfinder.try_write_dynamic_target_navigation_step(
		results[0],
		contexts[0],
		source_position,
		target,
		TEST_AGENT_HALF_EXTENTS,
		GridPathfinder.DEFAULT_TRAVERSAL_TYPES
	)
	_expect(
		pathfinder.runtime_flow_build_jobs.is_empty()
		and (slot.get("published_anchor_cell") as Vector2i) == anchor_cell
		and int(slot.get("published_revision")) == published_revision,
		"A one-cell target move must keep the published anchor and enqueue no replacement."
	)
	_expect(
		results[0].status == GridPathfinder.NavigationStepStatus.READY
		and results[0].resolved_target_cell == anchor_cell
		and contexts[0].resolved_target_cell == anchor_cell,
		"A one-cell target move must keep serving READY steps from the old anchor."
	)

	target.global_position = pathfinder.call("_map_to_global", repath_cell) as Vector2
	var ready_while_repathing := 0
	for context_index in range(CONTEXT_COUNT):
		pathfinder.try_write_dynamic_target_navigation_step(
			results[context_index],
			contexts[context_index],
			source_position,
			target,
			TEST_AGENT_HALF_EXTENTS,
			GridPathfinder.DEFAULT_TRAVERSAL_TYPES
		)
		if (
			results[context_index].status == GridPathfinder.NavigationStepStatus.READY
			and results[context_index].resolved_target_cell == anchor_cell
		):
			ready_while_repathing += 1
	_expect(
		pathfinder.runtime_flow_build_jobs.size() == 1
		and pathfinder.runtime_flow_build_order.size() == 1,
		"A target move of at least two cells must enqueue exactly one successor job."
	)
	_expect(
		ready_while_repathing == CONTEXT_COUNT
		and (slot.get("published_anchor_cell") as Vector2i) == anchor_cell
		and int(slot.get("published_revision")) == published_revision,
		"All contexts must keep using the old complete anchor while its successor is pending."
	)

	pathfinder.set_process(false)
	pathfinder.call("_advance_runtime_navigation_jobs")
	pathfinder.set_process(false)
	_expect(
		pathfinder.runtime_navigation_expansions_last_frame
		<= pathfinder.runtime_navigation_max_expansions_per_frame,
		"A successor build slice must obey the same per-frame expansion cap."
	)
	_expect(
		pathfinder.runtime_flow_build_jobs.size() == 1
		and (slot.get("published_anchor_cell") as Vector2i) == anchor_cell
		and int(slot.get("published_revision")) == published_revision,
		"A partial successor build must not replace the old published anchor."
	)
	pathfinder.try_write_dynamic_target_navigation_step(
		results[0],
		contexts[0],
		source_position,
		target,
		TEST_AGENT_HALF_EXTENTS,
		GridPathfinder.DEFAULT_TRAVERSAL_TYPES
	)
	_expect(
		results[0].status == GridPathfinder.NavigationStepStatus.READY
		and results[0].resolved_target_cell == anchor_cell,
		"A caller must continue receiving the old READY field during successor construction."
	)


func _test_target_release_cancels_pending_job(
	pathfinder: GridPathfinder,
	target: Node2D
) -> void:
	var cancellations_before := pathfinder.runtime_flow_builds_cancelled
	target.free()
	pathfinder.call("_prune_dynamic_flow_slots", false)
	_expect(
		pathfinder.dynamic_flow_target_slots.is_empty(),
		"Releasing a dynamic target must remove its shared slot."
	)
	_expect(
		pathfinder.runtime_flow_build_jobs.is_empty()
		and pathfinder.runtime_flow_build_order.is_empty(),
		"Releasing the last waiter must cancel and remove its pending flow job."
	)
	_expect(
		pathfinder.runtime_flow_builds_cancelled == cancellations_before + 1,
		"Target release must be recorded as exactly one cancelled flow job."
	)


func _test_two_targets_share_one_profile_anchor_job(
	pathfinder: GridPathfinder,
	game: GameTowerDefense,
	source_position: Vector2,
	target_cell: Vector2i
) -> void:
	var second_target := Node2D.new()
	second_target.name = "SecondDynamicFlowTargetProbe"
	game.add_child(second_target)
	second_target.global_position = pathfinder.call("_map_to_global", target_cell) as Vector2
	var result := GridPathfinder.NavigationStepResult.new()
	var context := GridPathfinder.FlowQueryContext.new()
	pathfinder.try_write_dynamic_target_navigation_step(
		result,
		context,
		source_position,
		second_target,
		TEST_AGENT_HALF_EXTENTS,
		GridPathfinder.DEFAULT_TRAVERSAL_TYPES
	)
	_expect(
		pathfinder.dynamic_flow_target_slots.size() == 2
		and pathfinder.runtime_flow_build_jobs.size() == 1,
		"Two target instances at one anchor/profile must own distinct slots but share one job."
	)
	_expect(
		result.status == GridPathfinder.NavigationStepStatus.DEFERRED,
		"A newly joined target without a published field must wait for the shared job."
	)
	second_target.free()
	pathfinder.call("_prune_dynamic_flow_slots", false)
	_expect(
		pathfinder.dynamic_flow_target_slots.size() == 1
		and pathfinder.runtime_flow_build_jobs.size() == 1,
		"Removing one of two job waiters must preserve the other target and shared job."
	)


func _test_static_try_stages_and_publishes_fixed_cache(
	pathfinder: GridPathfinder,
	source_position: Vector2,
	target_cell: Vector2i
) -> int:
	pathfinder.flow_field_cache.clear()
	pathfinder.flow_field_cache_order.clear()
	var target_position := pathfinder.call("_map_to_global", target_cell) as Vector2
	var result := GridPathfinder.NavigationStepResult.new()
	var context := GridPathfinder.FlowQueryContext.new()
	var fixed_cache_size_before := pathfinder.flow_field_cache.size()
	pathfinder.try_write_safe_navigation_step(
		result,
		context,
		source_position,
		target_position,
		TEST_AGENT_HALF_EXTENTS,
		GridPathfinder.DEFAULT_TRAVERSAL_TYPES,
		true
	)
	_expect(
		result.status == GridPathfinder.NavigationStepStatus.DEFERRED,
		"A static try-write cold miss must return DEFERRED on its caller frame."
	)
	_expect(
		pathfinder.flow_field_cache.size() == fixed_cache_size_before,
		"A static try-write cold miss must not synchronously populate the fixed flow cache."
	)
	_expect(
		pathfinder.runtime_flow_build_jobs.size() == 1,
		"A static try-write cold miss must enqueue exactly one staged flow job."
	)
	var fixed_job: Variant = _only_value(pathfinder.runtime_flow_build_jobs)
	if fixed_job != null:
		_expect(
			bool(fixed_job.get("publish_to_fixed_cache"))
			and int(fixed_job.get("pending_entry_count")) == 1,
			"The static miss job must remain at its seed and publish only when complete."
		)

	var build_frames := 0
	while (
		not pathfinder.runtime_flow_build_jobs.is_empty()
		and build_frames < MAX_MANUAL_BUILD_FRAMES
	):
		pathfinder.set_process(false)
		pathfinder.call("_advance_runtime_navigation_jobs")
		pathfinder.set_process(false)
		build_frames += 1
		_expect(
			pathfinder.runtime_navigation_expansions_last_frame
			<= pathfinder.runtime_navigation_max_expansions_per_frame,
			"A staged static-flow slice must obey the configured expansion cap."
		)
		if not pathfinder.runtime_flow_build_jobs.is_empty():
			pathfinder.try_write_safe_navigation_step(
				result,
				context,
				source_position,
				target_position,
				TEST_AGENT_HALF_EXTENTS,
				GridPathfinder.DEFAULT_TRAVERSAL_TYPES,
				true
			)
			_expect(
				result.status == GridPathfinder.NavigationStepStatus.DEFERRED
				and pathfinder.flow_field_cache.is_empty()
				and pathfinder.runtime_flow_build_jobs.size() == 1,
				"Repeated static queries must deduplicate and stay DEFERRED until publication."
			)

	_expect(
		build_frames < MAX_MANUAL_BUILD_FRAMES,
		"The staged static flow build must complete within the smoke-test frame guard."
	)
	_expect(
		pathfinder.runtime_flow_build_jobs.is_empty()
		and pathfinder.flow_field_cache.size() == 1,
		"A complete staged static flow must atomically publish one fixed cache entry."
	)
	pathfinder.try_write_safe_navigation_step(
		result,
		context,
		source_position,
		target_position,
		TEST_AGENT_HALF_EXTENTS,
		GridPathfinder.DEFAULT_TRAVERSAL_TYPES,
		true
	)
	_expect(
		result.status == GridPathfinder.NavigationStepStatus.READY
		and result.is_complete_route,
		"The static try-write query must become READY from the completed fixed cache."
	)
	return build_frames


func _test_rebuild_cancels_flow_and_agent_grid_jobs(
	pathfinder: GridPathfinder,
	game: GameTowerDefense,
	source_position: Vector2,
	dynamic_target_cell: Vector2i,
	agent_grid_target_cell: Vector2i
) -> void:
	var target := Node2D.new()
	target.name = "TerrainRebuildTargetProbe"
	game.add_child(target)
	target.global_position = pathfinder.call("_map_to_global", dynamic_target_cell) as Vector2
	var result := GridPathfinder.NavigationStepResult.new()
	var context := GridPathfinder.FlowQueryContext.new()
	pathfinder.try_write_dynamic_target_navigation_step(
		result,
		context,
		source_position,
		target,
		TEST_AGENT_HALF_EXTENTS,
		GridPathfinder.DEFAULT_TRAVERSAL_TYPES
	)
	_expect(
		result.status == GridPathfinder.NavigationStepStatus.DEFERRED
		and pathfinder.dynamic_flow_target_slots.size() == 1
		and pathfinder.runtime_flow_build_jobs.size() == 1,
		"The terrain-rebuild case must begin with one pending dynamic slot/job."
	)
	var uncached_extents := Vector2(13.0, 7.0)
	var uncached_grid_key := pathfinder.call(
		"_get_agent_grid_cache_key",
		uncached_extents,
		GridPathfinder.DEFAULT_TRAVERSAL_TYPES
	) as String
	pathfinder.agent_grid_cache.erase(uncached_grid_key)
	var agent_grid_result := GridPathfinder.NavigationStepResult.new()
	var agent_grid_context := GridPathfinder.FlowQueryContext.new()
	pathfinder.try_write_safe_navigation_step(
		agent_grid_result,
		agent_grid_context,
		source_position,
		pathfinder.call("_map_to_global", agent_grid_target_cell) as Vector2,
		uncached_extents,
		GridPathfinder.DEFAULT_TRAVERSAL_TYPES,
		true
	)
	_expect(
		agent_grid_result.status == GridPathfinder.NavigationStepStatus.DEFERRED
		and pathfinder.runtime_agent_grid_build_jobs.size() == 1
		and pathfinder.runtime_flow_build_jobs.size() == 1,
		"The rebuild case must hold one flow job and one independently staged agent-grid job."
	)
	var flow_job_before: Variant = _only_value(pathfinder.runtime_flow_build_jobs)
	var grid_job_before: Variant = _only_value(pathfinder.runtime_agent_grid_build_jobs)
	var flow_entries_before := int(
		(flow_job_before.get("next_cells") as Dictionary).size()
	)
	var grid_index_before := int(grid_job_before.get("next_cell_index"))
	pathfinder.set_process(false)
	pathfinder.call("_advance_runtime_navigation_jobs")
	pathfinder.set_process(false)
	var flow_job_after: Variant = _only_value(pathfinder.runtime_flow_build_jobs)
	var grid_job_after: Variant = _only_value(pathfinder.runtime_agent_grid_build_jobs)
	_expect(
		flow_job_after != null
		and grid_job_after != null
		and int((flow_job_after.get("next_cells") as Dictionary).size())
			> flow_entries_before
		and int(grid_job_after.get("next_cell_index")) > grid_index_before,
		"One bounded slice must make fair progress on an urgent flow and a cold profile grid."
	)

	var generation_before := pathfinder.navigation_generation
	var cancellations_before := pathfinder.runtime_flow_builds_cancelled
	pathfinder.rebuild()
	_expect(
		pathfinder.navigation_generation == generation_before + 1 and pathfinder.is_built,
		"A terrain navigation rebuild must advance the generation and restore a built grid."
	)
	_expect(
		pathfinder.dynamic_flow_target_slots.is_empty()
		and pathfinder.runtime_flow_build_jobs.is_empty()
		and pathfinder.runtime_flow_build_order.is_empty()
		and pathfinder.runtime_agent_grid_build_jobs.is_empty()
		and pathfinder.runtime_agent_grid_build_order.is_empty(),
		"A terrain navigation rebuild must clear both flow and agent-grid jobs."
	)
	_expect(
		pathfinder.runtime_flow_builds_cancelled == cancellations_before + 1,
		"A terrain rebuild must record its pending flow job as cancelled."
	)
	target.free()


func _find_test_cells(
	pathfinder: GridPathfinder,
	path_grid: AStarGrid2D
) -> Dictionary:
	if path_grid == null:
		return {}
	var region := path_grid.region
	for y in range(region.position.y, region.end.y):
		for x in range(region.position.x, region.end.x):
			var anchor := Vector2i(x, y)
			if not bool(pathfinder.call("_is_cell_walkable", anchor, path_grid)):
				continue
			for direction in GridPathfinder.FLOW_CARDINAL_DIRECTIONS:
				var adjacent := anchor + direction
				var repath := anchor + direction * 2
				if (
					not bool(pathfinder.call("_is_cell_walkable", adjacent, path_grid))
					or not bool(pathfinder.call("_is_cell_walkable", repath, path_grid))
				):
					continue
				var source := _find_connected_source(pathfinder, path_grid, anchor)
				if source == Vector2i.MAX:
					continue
				return {
					"source": source,
					"anchor": anchor,
					"adjacent": adjacent,
					"repath": repath,
				}
	return {}


func _find_connected_source(
	pathfinder: GridPathfinder,
	path_grid: AStarGrid2D,
	target_cell: Vector2i
) -> Vector2i:
	var region := path_grid.region
	for y in range(region.end.y - 1, region.position.y - 1, -1):
		for x in range(region.end.x - 1, region.position.x - 1, -1):
			var source := Vector2i(x, y)
			if _chebyshev_distance(source, target_cell) < 8:
				continue
			if not bool(pathfinder.call("_is_cell_walkable", source, path_grid)):
				continue
			if not path_grid.get_id_path(source, target_cell, false).is_empty():
				return source
	return Vector2i.MAX


func _reset_dynamic_runtime_state(pathfinder: GridPathfinder) -> void:
	pathfinder.call("_cancel_all_runtime_navigation_jobs")
	pathfinder.dynamic_flow_target_slots.clear()
	pathfinder.flow_field_cache.clear()
	pathfinder.flow_field_cache_order.clear()
	pathfinder.flow_recovery_route_cache.clear()
	pathfinder.flow_recovery_cache_order.clear()
	pathfinder.flow_field_budget_frame = -1
	pathfinder.flow_field_builds_used_this_frame = 0
	pathfinder.runtime_navigation_expansions_last_frame = 0
	pathfinder.runtime_navigation_build_usec_last_frame = 0
	pathfinder.runtime_navigation_build_usec_peak = 0
	pathfinder.runtime_flow_builds_completed = 0
	pathfinder.runtime_flow_builds_cancelled = 0
	pathfinder.set_process(false)


func _only_value(dictionary: Dictionary) -> Variant:
	if dictionary.size() != 1:
		return null
	return dictionary.values()[0]


func _chebyshev_distance(a: Vector2i, b: Vector2i) -> int:
	var delta := (b - a).abs()
	return maxi(delta.x, delta.y)


func _finish(game: Node, build_frames: int) -> void:
	if game != null:
		game.queue_free()
		await process_frame
		await physics_frame

	if failures.is_empty():
		print(
			"GRID_PATHFINDER_DYNAMIC_TARGET_FLOW_SMOKE_TEST_OK contexts=%d build_frames=%d"
			% [CONTEXT_COUNT, build_frames]
		)
		quit()
		return

	for failure in failures:
		push_error(failure)
	quit(1)


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
