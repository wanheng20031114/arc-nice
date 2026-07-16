extends SceneTree

const TOWER_SCENE := preload("res://scene/game_tower_defense.tscn")
const CONTEXT_COUNT := 300
const TEST_AGENT_HALF_EXTENTS := Vector2(8.0, 4.0)
const TEST_EXPANSIONS_PER_FRAME := 64
const MAX_MANUAL_BUILD_FRAMES := 10000
const FLOW_PRIORITY_SELECTOR_AB_ITERATIONS := 10000

var failures: Array[String] = []


class SyntheticGridPathfinder:
	extends GridPathfinder

	func _ready() -> void:
		set_process(false)

	func _global_to_map(global_position: Vector2) -> Vector2i:
		return Vector2i(
			floori(global_position.x / astar_grid.cell_size.x),
			floori(global_position.y / astar_grid.cell_size.y)
		)

	func _map_to_global(cell: Vector2i) -> Vector2:
		return (Vector2(cell) + Vector2(0.5, 0.5)) * astar_grid.cell_size

	func _is_raw_navigation_segment_walkable(
		_from_global_position: Vector2,
		_to_global_position: Vector2,
		_traversal_types: int
	) -> bool:
		return true


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
		test_cells.size() == 5,
		"The tower map must provide a connected source and a walkable seven-cell target lane."
	)
	if path_grid == null or test_cells.size() != 5:
		_finish(game, 0)
		return

	var source_cell: Vector2i = test_cells["source"]
	var anchor_cell: Vector2i = test_cells["anchor"]
	var adjacent_cell: Vector2i = test_cells["adjacent"]
	var repath_cell: Vector2i = test_cells["repath"]
	var far_retarget_cell: Vector2i = test_cells["far_retarget"]
	var source_position := pathfinder.call("_map_to_global", source_cell) as Vector2

	_reset_dynamic_runtime_state(pathfinder)
	pathfinder.runtime_navigation_max_expansions_per_frame = TEST_EXPANSIONS_PER_FRAME
	pathfinder.runtime_navigation_time_budget_usec = 8000
	# The algorithm-equivalence cases below intentionally compare against a full
	# synchronous field. Production uses a bounded 20-cell moving-target region;
	# that separate contract is covered by the wall pursuit integration test.
	pathfinder.coalesce_dynamic_target_profiles_by_grid_topology = false
	pathfinder.dynamic_target_flow_radius_cells = 128
	pathfinder.dynamic_target_repath_distance_cells = 2
	pathfinder.dynamic_target_max_anchor_age_seconds = 2.0
	# This suite retains a dedicated bounded-retarget contract. Production uses
	# zero cancellations so queued topology groups cannot lose completed work.
	pathfinder.dynamic_target_max_pending_retargets_before_publish = 1

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
		far_retarget_cell,
		results,
		contexts
	)
	_test_two_targets_share_one_profile_anchor_job(
		pathfinder,
		game,
		source_position,
		anchor_cell
	)
	_test_target_release_cancels_pending_job(pathfinder, target)
	var static_build_frames := _test_static_try_stages_and_publishes_fixed_cache(
		pathfinder,
		source_position,
		repath_cell
	)
	_test_cold_target_retarget_is_bounded(
		pathfinder,
		game,
		source_position,
		anchor_cell,
		far_retarget_cell
	)
	_test_rebuild_cancels_flow_and_agent_grid_jobs(
		pathfinder,
		game,
		source_position,
		anchor_cell,
		adjacent_cell
	)
	_test_public_api_auto_extends_long_wall_coverage(game)
	_test_late_required_source_resumes_packed_coverage_search(game)
	_test_rebuild_cancels_partial_packed_materialization(game)
	_test_player_flow_priority_and_round_robin(game)
	_test_flow_priority_selector_performance_ab(game)
	_test_integral_forward_obstacle_lookahead(game)
	_test_dynamic_prefetch_cohort_deduplication(game)
	_test_prefetch_preserves_unique_coverage_sources(game)
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
			and int(pathfinder.call(
				"_get_runtime_flow_job_discovered_cell_count",
				initial_job
			)) == 1,
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
	far_retarget_cell: Vector2i,
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
	var stale_while_repathing := 0
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
		if results[context_index].dynamic_anchor_is_stale:
			stale_while_repathing += 1
	_expect(
		pathfinder.runtime_flow_build_jobs.size() == 1
		and pathfinder.runtime_flow_build_order.size() == 1,
		"A target move of at least two cells must enqueue exactly one successor job."
	)
	_expect(
		ready_while_repathing == CONTEXT_COUNT
		and stale_while_repathing == 0
		and (slot.get("published_anchor_cell") as Vector2i) == anchor_cell
		and int(slot.get("published_revision")) == published_revision,
		"A bounded two-cell lag must remain usable while its successor is pending."
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
		and results[0].resolved_target_cell == anchor_cell
		and not results[0].dynamic_anchor_is_stale,
		"A caller must continue receiving the old READY field during successor construction."
	)

	var obsolete_job_key := String(pathfinder.runtime_flow_build_order[0])
	var cancellations_before := pathfinder.runtime_flow_builds_cancelled
	target.global_position = pathfinder.call(
		"_map_to_global",
		far_retarget_cell
	) as Vector2
	pathfinder.try_write_dynamic_target_navigation_step(
		results[0],
		contexts[0],
		source_position,
		target,
		TEST_AGENT_HALF_EXTENTS,
		GridPathfinder.DEFAULT_TRAVERSAL_TYPES
	)
	var replacement_job: Variant = _only_value(pathfinder.runtime_flow_build_jobs)
	_expect(
		pathfinder.runtime_flow_build_jobs.size() == 1
		and not pathfinder.runtime_flow_build_jobs.has(obsolete_job_key)
		and replacement_job != null
		and (replacement_job.get("target_cell") as Vector2i) == far_retarget_cell,
		"A pending dynamic job that falls four cells behind must be cancelled and retargeted."
	)
	_expect(
		pathfinder.runtime_flow_builds_cancelled == cancellations_before + 1,
		"Retargeting the last waiter must record one obsolete-job cancellation."
	)
	_expect(
		results[0].dynamic_anchor_is_stale
		and results[0].resolved_target_cell == anchor_cell,
		"The old complete field may remain readable but must be marked stale while the current replacement builds."
	)

	# Keep moving the target on every scheduler slice. A bounded retarget policy
	# must still publish a complete, newer revision instead of cancelling or
	# discarding forever.
	var lane_direction := (far_retarget_cell - anchor_cell).sign()
	var moving_neighbor := far_retarget_cell - lane_direction
	var liveness_frames := 0
	while (
		int(slot.get("published_revision")) == published_revision
		and liveness_frames < MAX_MANUAL_BUILD_FRAMES
	):
		var moving_target_cell := (
			far_retarget_cell if liveness_frames % 2 == 0 else moving_neighbor
		)
		target.global_position = pathfinder.call(
			"_map_to_global",
			moving_target_cell
		) as Vector2
		pathfinder.try_write_dynamic_target_navigation_step(
			results[0],
			contexts[0],
			source_position,
			target,
			TEST_AGENT_HALF_EXTENTS,
			GridPathfinder.DEFAULT_TRAVERSAL_TYPES
		)
		pathfinder.set_process(false)
		pathfinder.call("_advance_runtime_navigation_jobs")
		pathfinder.set_process(false)
		liveness_frames += 1
	_expect(
		int(slot.get("published_revision")) > published_revision,
		"A continuously moving target must publish a newer revision within a bounded build."
	)
	_expect(
		_chebyshev_distance(
			slot.get("published_anchor_cell") as Vector2i,
			far_retarget_cell
		) <= 1,
		"The bounded intermediate publication must remain close to the moving target lane."
	)

	# Leave one replacement pending so the following target-deduplication test can
	# prove that a second target instance shares this profile/anchor job.
	target.global_position = pathfinder.call("_map_to_global", anchor_cell) as Vector2
	pathfinder.try_write_dynamic_target_navigation_step(
		results[0],
		contexts[0],
		source_position,
		target,
		TEST_AGENT_HALF_EXTENTS,
		GridPathfinder.DEFAULT_TRAVERSAL_TYPES
	)
	var pending_return_job: Variant = _only_value(pathfinder.runtime_flow_build_jobs)
	_expect(
		pending_return_job != null
		and (pending_return_job.get("target_cell") as Vector2i) == anchor_cell,
		"The refreshed slot must immediately enqueue its newest distant target."
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


func _test_cold_target_retarget_is_bounded(
	pathfinder: GridPathfinder,
	game: GameTowerDefense,
	source_position: Vector2,
	anchor_cell: Vector2i,
	far_retarget_cell: Vector2i
) -> void:
	var target := Node2D.new()
	target.name = "ColdMovingTargetProbe"
	game.add_child(target)
	target.global_position = pathfinder.call("_map_to_global", anchor_cell) as Vector2
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
	var first_job: Variant = _only_value(pathfinder.runtime_flow_build_jobs)
	_expect(
		result.status == GridPathfinder.NavigationStepStatus.DEFERRED
		and first_job != null
		and (first_job.get("target_cell") as Vector2i) == anchor_cell,
		"A cold dynamic target must begin with one unpublished anchor job."
	)

	var cancellations_before := pathfinder.runtime_flow_builds_cancelled
	target.global_position = pathfinder.call(
		"_map_to_global",
		far_retarget_cell
	) as Vector2
	pathfinder.try_write_dynamic_target_navigation_step(
		result,
		context,
		source_position,
		target,
		TEST_AGENT_HALF_EXTENTS,
		GridPathfinder.DEFAULT_TRAVERSAL_TYPES
	)
	var retargeted_job: Variant = _only_value(pathfinder.runtime_flow_build_jobs)
	_expect(
		retargeted_job != null
		and (retargeted_job.get("target_cell") as Vector2i) == far_retarget_cell
		and pathfinder.runtime_flow_builds_cancelled == cancellations_before + 1,
		"A cold job may retarget once before its first guaranteed publication."
	)

	var slot: Variant = _only_value(pathfinder.dynamic_flow_target_slots)
	var lane_direction := (far_retarget_cell - anchor_cell).sign()
	var moving_neighbor := far_retarget_cell - lane_direction
	var build_frames := 0
	while (
		slot != null
		and int(slot.get("published_revision")) == 0
		and build_frames < MAX_MANUAL_BUILD_FRAMES
	):
		var moving_target_cell := (
			far_retarget_cell if build_frames % 2 == 0 else moving_neighbor
		)
		target.global_position = pathfinder.call(
			"_map_to_global",
			moving_target_cell
		) as Vector2
		pathfinder.try_write_dynamic_target_navigation_step(
			result,
			context,
			source_position,
			target,
			TEST_AGENT_HALF_EXTENTS,
			GridPathfinder.DEFAULT_TRAVERSAL_TYPES
		)
		pathfinder.set_process(false)
		pathfinder.call("_advance_runtime_navigation_jobs")
		pathfinder.set_process(false)
		build_frames += 1
	_expect(
		slot != null
		and int(slot.get("published_revision")) > 0
		and int(slot.get("pending_retargets_since_publish")) == 0,
		"A cold continuously moving target must publish after a bounded retarget count."
	)
	if slot != null and int(slot.get("published_revision")) > 0:
		_expect(
			_chebyshev_distance(
				slot.get("published_anchor_cell") as Vector2i,
				far_retarget_cell
			) <= 1,
			"The first cold publication must use the bounded recent target lane."
		)
	target.free()
	pathfinder.call("_prune_dynamic_flow_slots", false)


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
		pathfinder.call(
			"_get_runtime_flow_job_discovered_cell_count",
			flow_job_before
		)
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
		and int(pathfinder.call(
			"_get_runtime_flow_job_discovered_cell_count",
			flow_job_after
		)) > flow_entries_before
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


func _test_public_api_auto_extends_long_wall_coverage(
	game: GameTowerDefense
) -> void:
	var synthetic_grid := AStarGrid2D.new()
	synthetic_grid.region = Rect2i(0, 0, 64, 64)
	synthetic_grid.cell_size = Vector2(16.0, 16.0)
	synthetic_grid.diagonal_mode = AStarGrid2D.DIAGONAL_MODE_ONLY_IF_NO_OBSTACLES
	synthetic_grid.default_compute_heuristic = AStarGrid2D.HEURISTIC_OCTILE
	synthetic_grid.default_estimate_heuristic = AStarGrid2D.HEURISTIC_OCTILE
	synthetic_grid.update()
	for wall_y in range(35):
		synthetic_grid.set_point_solid(Vector2i(21, wall_y), true)

	var synthetic_pathfinder := SyntheticGridPathfinder.new()
	synthetic_pathfinder.name = "PublicCoverageSyntheticPathfinder"
	game.add_child(synthetic_pathfinder)
	synthetic_pathfinder.navigation_generation = 1
	synthetic_pathfinder.astar_grid = synthetic_grid
	synthetic_pathfinder.is_built = true
	synthetic_pathfinder.dynamic_target_flow_radius_cells = 20
	synthetic_pathfinder.coalesce_dynamic_target_profiles_by_grid_topology = false
	var default_cache_key := synthetic_pathfinder.call(
		"_get_agent_grid_cache_key",
		Vector2.ZERO,
		GridPathfinder.DEFAULT_TRAVERSAL_TYPES
	) as String
	var default_snapshot: Variant = synthetic_pathfinder.call(
		"_build_agent_solid_integral_snapshot",
		synthetic_grid
	)
	synthetic_pathfinder.call(
		"_store_agent_open_plain_integral_snapshot",
		default_cache_key,
		default_snapshot
	)

	var target_cell := Vector2i(20, 10)
	var source_cell := Vector2i(22, 10)
	var target := Node2D.new()
	target.name = "PublicCoverageTarget"
	synthetic_pathfinder.add_child(target)
	target.global_position = synthetic_pathfinder.call(
		"_map_to_global",
		target_cell
	) as Vector2
	var source_position := synthetic_pathfinder.call(
		"_map_to_global",
		source_cell
	) as Vector2
	var result := GridPathfinder.NavigationStepResult.new()
	var context := GridPathfinder.FlowQueryContext.new()
	synthetic_pathfinder.try_write_dynamic_target_navigation_step(
		result,
		context,
		source_position,
		target,
		Vector2.ZERO,
		GridPathfinder.DEFAULT_TRAVERSAL_TYPES,
		0.0
	)
	_expect(
		result.status == GridPathfinder.NavigationStepStatus.DEFERRED
		and synthetic_pathfinder.runtime_flow_build_jobs.size() == 1,
		"The public API must stage one bounded field on a cold long-wall query."
	)
	_drain_runtime_flow_jobs(synthetic_pathfinder, 5000)

	result = GridPathfinder.NavigationStepResult.new()
	context = GridPathfinder.FlowQueryContext.new()
	synthetic_pathfinder.try_write_dynamic_target_navigation_step(
		result,
		context,
		source_position,
		target,
		Vector2.ZERO,
		GridPathfinder.DEFAULT_TRAVERSAL_TYPES,
		0.0
	)
	_expect(
		result.status == GridPathfinder.NavigationStepStatus.DEFERRED,
		"A public bounded-field coverage miss must be DEFERRED, never UNREACHABLE."
	)
	for source_y in range(1, 11):
		for source_x in range(22, 32):
			synthetic_pathfinder.try_write_dynamic_target_navigation_step(
				GridPathfinder.NavigationStepResult.new(),
				GridPathfinder.FlowQueryContext.new(),
				synthetic_pathfinder.call(
					"_map_to_global",
					Vector2i(source_x, source_y)
				) as Vector2,
				target,
				Vector2.ZERO,
				GridPathfinder.DEFAULT_TRAVERSAL_TYPES,
				0.0
			)
	var coverage_job: Variant = _only_value(
		synthetic_pathfinder.runtime_flow_build_jobs
	)
	_expect(
		coverage_job != null
		and bool(coverage_job.get("complete_when_required_sources_reached"))
		and (coverage_job.get("required_source_cells") as Dictionary).size() == 100
		and not bool(coverage_job.get("urgent")),
		"Public misses from 100 source cells must merge into one low-priority continuation."
	)
	_drain_runtime_flow_jobs(synthetic_pathfinder, 10000)

	result = GridPathfinder.NavigationStepResult.new()
	context = GridPathfinder.FlowQueryContext.new()
	synthetic_pathfinder.try_write_dynamic_target_navigation_step(
		result,
		context,
		source_position,
		target,
		Vector2.ZERO,
		GridPathfinder.DEFAULT_TRAVERSAL_TYPES,
		0.0
	)
	var public_slot: Variant = _only_value(
		synthetic_pathfinder.dynamic_flow_target_slots
	)
	_expect(
		result.status == GridPathfinder.NavigationStepStatus.READY
		and result.is_complete_route
		and public_slot != null
		and int(public_slot.get("published_revision")) == 2,
		"The public API must atomically publish coverage and become READY on revision two."
	)

	# Close the only opening and start a new immutable generation. The coverage
	# continuation must exhaust the target component once, publish an exhaustive
	# verdict, and never enqueue the same impossible route on later queries.
	for wall_y in range(35, 64):
		synthetic_grid.set_point_solid(Vector2i(21, wall_y), true)
	synthetic_pathfinder.call("_cancel_all_runtime_navigation_jobs")
	synthetic_pathfinder.dynamic_flow_target_slots.clear()
	synthetic_pathfinder.flow_field_cache.clear()
	synthetic_pathfinder.flow_field_cache_order.clear()
	synthetic_pathfinder.agent_open_plain_integral_cache.clear()
	synthetic_pathfinder.navigation_generation += 1
	default_snapshot = synthetic_pathfinder.call(
		"_build_agent_solid_integral_snapshot",
		synthetic_grid
	)
	synthetic_pathfinder.call(
		"_store_agent_open_plain_integral_snapshot",
		default_cache_key,
		default_snapshot
	)
	result = GridPathfinder.NavigationStepResult.new()
	context = GridPathfinder.FlowQueryContext.new()
	synthetic_pathfinder.try_write_dynamic_target_navigation_step(
		result,
		context,
		source_position,
		target,
		Vector2.ZERO,
		GridPathfinder.DEFAULT_TRAVERSAL_TYPES,
		0.0
	)
	_drain_runtime_flow_jobs(synthetic_pathfinder, 5000)
	synthetic_pathfinder.try_write_dynamic_target_navigation_step(
		result,
		context,
		source_position,
		target,
		Vector2.ZERO,
		GridPathfinder.DEFAULT_TRAVERSAL_TYPES,
		0.0
	)
	_expect(
		result.status == GridPathfinder.NavigationStepStatus.DEFERRED,
		"A non-exhaustive local miss must still request one full connectivity verdict."
	)
	_drain_runtime_flow_jobs(synthetic_pathfinder, 10000)
	result = GridPathfinder.NavigationStepResult.new()
	context = GridPathfinder.FlowQueryContext.new()
	synthetic_pathfinder.try_write_dynamic_target_navigation_step(
		result,
		context,
		source_position,
		target,
		Vector2.ZERO,
		GridPathfinder.DEFAULT_TRAVERSAL_TYPES,
		0.0
	)
	public_slot = _only_value(synthetic_pathfinder.dynamic_flow_target_slots)
	_expect(
		result.status == GridPathfinder.NavigationStepStatus.UNREACHABLE
		and public_slot != null
		and bool((public_slot.get("published_field") as Dictionary).get(
			"coverage_is_exhaustive",
			false
		))
		and synthetic_pathfinder.runtime_flow_build_jobs.is_empty(),
		"A disconnected source must become stable UNREACHABLE after one exhaustive continuation."
	)
	synthetic_pathfinder.try_write_dynamic_target_navigation_step(
		result,
		context,
		source_position,
		target,
		Vector2.ZERO,
		GridPathfinder.DEFAULT_TRAVERSAL_TYPES,
		0.0
	)
	_expect(
		synthetic_pathfinder.runtime_flow_build_jobs.is_empty(),
		"Repeated queries against an exhaustive field must not rebuild impossible coverage."
	)

	synthetic_pathfinder.set_process(false)
	synthetic_pathfinder.queue_free()


func _test_late_required_source_resumes_packed_coverage_search(
	game: GameTowerDefense
) -> void:
	var fixture := _stage_packed_coverage_materialization(
		game,
		"LateRequiredSourceMaterializationPathfinder"
	)
	var pathfinder := fixture.get("pathfinder") as SyntheticGridPathfinder
	var target := fixture.get("target") as Node2D
	var job: Variant = fixture.get("job")
	if pathfinder == null or target == null or job == null:
		if pathfinder != null:
			pathfinder.queue_free()
		return

	var late_source_cell := Vector2i(20, 20)
	var late_result := GridPathfinder.NavigationStepResult.new()
	var late_context := GridPathfinder.FlowQueryContext.new()
	pathfinder.try_write_dynamic_target_navigation_step(
		late_result,
		late_context,
		pathfinder.call("_map_to_global", late_source_cell) as Vector2,
		target,
		Vector2.ZERO,
		GridPathfinder.DEFAULT_TRAVERSAL_TYPES,
		0.0
	)
	_expect(
		late_result.status == GridPathfinder.NavigationStepStatus.DEFERRED,
		"A source joining during packed materialization must remain DEFERRED until the resumed search publishes."
	)
	_expect(
		(job.get("required_source_cells") as Dictionary).has(late_source_cell)
		and (job.get("remaining_required_source_cells") as Dictionary).has(
			late_source_cell
		)
		and not bool(job.get("search_completed")),
		"A not-yet-finalized required source must reopen a packed coverage search."
	)
	_expect(
		int(job.get("next_materialize_cell_index")) == 0
		and (job.get("next_cells") as Dictionary).is_empty()
		and (job.get("distances") as Dictionary).is_empty(),
		"Reopening search must discard the obsolete partial materialization before continuing."
	)

	_drain_runtime_flow_jobs(pathfinder, 10000)
	var slot: Variant = _only_value(pathfinder.dynamic_flow_target_slots)
	var published_field := (
		slot.get("published_field") as Dictionary if slot != null else {}
	)
	var published_next_cells := published_field.get("next_cells", {}) as Dictionary
	var published_distances := published_field.get("distances", {}) as Dictionary
	_expect(
		slot != null
		and int(slot.get("published_revision")) == 2
		and published_next_cells.has(late_source_cell)
		and published_distances.has(late_source_cell),
		"The resumed packed coverage job must publish a complete route for the late required source."
	)
	late_result = GridPathfinder.NavigationStepResult.new()
	late_context = GridPathfinder.FlowQueryContext.new()
	pathfinder.try_write_dynamic_target_navigation_step(
		late_result,
		late_context,
		pathfinder.call("_map_to_global", late_source_cell) as Vector2,
		target,
		Vector2.ZERO,
		GridPathfinder.DEFAULT_TRAVERSAL_TYPES,
		0.0
	)
	_expect(
		late_result.status == GridPathfinder.NavigationStepStatus.READY
		and late_result.is_complete_route,
		"The public query must become READY after the late-source coverage publication."
	)

	pathfinder.set_process(false)
	pathfinder.queue_free()


func _test_rebuild_cancels_partial_packed_materialization(
	game: GameTowerDefense
) -> void:
	var fixture := _stage_packed_coverage_materialization(
		game,
		"RebuildDuringMaterializationPathfinder"
	)
	var pathfinder := fixture.get("pathfinder") as SyntheticGridPathfinder
	var job: Variant = fixture.get("job")
	var slot: Variant = fixture.get("slot")
	if pathfinder == null or job == null or slot == null:
		if pathfinder != null:
			pathfinder.queue_free()
		return

	var generation_before := pathfinder.navigation_generation
	var cancellations_before := pathfinder.runtime_flow_builds_cancelled
	var completions_before := pathfinder.runtime_flow_builds_completed
	var published_revision_before := int(slot.get("published_revision"))
	var published_field_before := slot.get("published_field") as Dictionary
	var partial_distances := job.get("distances") as Dictionary
	_expect(
		not partial_distances.is_empty()
		and int(job.get("next_materialize_cell_index")) > 0,
		"The rebuild race must begin after a non-empty partial Dictionary batch exists."
	)

	pathfinder.rebuild()
	_expect(
		pathfinder.navigation_generation == generation_before + 1
		and pathfinder.is_built,
		"A rebuild during materialization must atomically start and publish a new navigation generation."
	)
	_expect(
		pathfinder.runtime_flow_build_jobs.is_empty()
		and pathfinder.runtime_flow_build_order.is_empty()
		and pathfinder.dynamic_flow_target_slots.is_empty()
		and pathfinder.runtime_flow_builds_cancelled == cancellations_before + 1,
		"A rebuild must cancel and detach the packed job that was still materializing."
	)
	_expect(
		pathfinder.runtime_flow_builds_completed == completions_before
		and int(slot.get("published_revision")) == published_revision_before
		and (slot.get("published_field") as Dictionary) == published_field_before,
		"A partial materialization from the old generation must never publish a new slot revision."
	)

	pathfinder.set_process(false)
	pathfinder.queue_free()


func _test_player_flow_priority_and_round_robin(game: GameTowerDefense) -> void:
	for packed_storage in [false, true]:
		var suffix := "Packed" if packed_storage else "Legacy"
		var pathfinder := _create_open_synthetic_pathfinder(
			game,
			"PriorityRoundRobin%s" % suffix,
			Vector2i(48, 48),
			8
		)
		pathfinder.runtime_flow_use_packed_build_storage = packed_storage
		var grid := pathfinder.astar_grid
		var static_key := "priority-static-%s" % suffix
		var background_key := "priority-background-%s" % suffix
		var dynamic_a_key := "priority-dynamic-a-%s" % suffix
		var dynamic_b_key := "priority-dynamic-b-%s" % suffix
		var static_targets: Array[Vector2i] = [Vector2i(40, 40)]
		var background_targets: Array[Vector2i] = [Vector2i(8, 40)]
		var dynamic_a_targets: Array[Vector2i] = [Vector2i(8, 8)]
		var dynamic_b_targets: Array[Vector2i] = [Vector2i(32, 8)]
		var static_job: Variant = pathfinder.call(
			"_get_or_create_runtime_flow_build_job",
			Vector2i(40, 40),
			Vector2.ZERO,
			GridPathfinder.DEFAULT_TRAVERSAL_TYPES,
			grid,
			GridPathfinder.RuntimeFlowJobPriority.STATIC_OBJECTIVE,
			static_targets,
			grid.region,
			Vector2i.MAX,
			static_key
		)
		var dynamic_a: Variant = pathfinder.call(
			"_get_or_create_runtime_flow_build_job",
			Vector2i(8, 8),
			Vector2.ZERO,
			GridPathfinder.DEFAULT_TRAVERSAL_TYPES,
			grid,
			GridPathfinder.RuntimeFlowJobPriority.DYNAMIC_TARGET,
			dynamic_a_targets,
			grid.region,
			Vector2i(8, 8),
			dynamic_a_key
		)
		var dynamic_b: Variant = pathfinder.call(
			"_get_or_create_runtime_flow_build_job",
			Vector2i(32, 8),
			Vector2.ZERO,
			GridPathfinder.DEFAULT_TRAVERSAL_TYPES,
			grid,
			GridPathfinder.RuntimeFlowJobPriority.DYNAMIC_TARGET,
			dynamic_b_targets,
			grid.region,
			Vector2i(32, 8),
			dynamic_b_key
		)
		var background_job: Variant = pathfinder.call(
			"_get_or_create_runtime_flow_build_job",
			Vector2i(8, 40),
			Vector2.ZERO,
			GridPathfinder.DEFAULT_TRAVERSAL_TYPES,
			grid,
			GridPathfinder.RuntimeFlowJobPriority.BACKGROUND,
			background_targets,
			grid.region,
			Vector2i.MAX,
			background_key
		)
		_expect(
			pathfinder.runtime_flow_build_order == [
				dynamic_a_key,
				dynamic_b_key,
				static_key,
				background_key,
			],
			"Player flow jobs must sort ahead of static-objective flow work (%s)."
			% suffix
		)
		for _step in range(GridPathfinder.RUNTIME_FLOW_JOB_QUANTUM_STEPS * 2):
			pathfinder.call("_advance_scheduled_runtime_flow_job")
		_expect(
			int(pathfinder.call(
				"_get_runtime_flow_job_discovered_cell_count",
				dynamic_a
			)) > 1
			and int(pathfinder.call(
				"_get_runtime_flow_job_discovered_cell_count",
				dynamic_b
			)) > 1,
			"Equal-priority player jobs must both advance within two scheduler quanta (%s)."
			% suffix
		)
		_expect(
			int(pathfinder.call(
				"_get_runtime_flow_job_discovered_cell_count",
				static_job
			)) > 1
			and int(pathfinder.call(
				"_get_runtime_flow_job_discovered_cell_count",
				background_job
			)) > 1,
			(
				"Sustained player-flow work must still service static and background "
				+ "bands within two scheduler cycles (%s)."
			) % suffix
		)
		var dynamic_discovered := (
			int(pathfinder.call(
				"_get_runtime_flow_job_discovered_cell_count",
				dynamic_a
			))
			+ int(pathfinder.call(
				"_get_runtime_flow_job_discovered_cell_count",
				dynamic_b
			))
		)
		var lower_priority_discovered := (
			int(pathfinder.call(
				"_get_runtime_flow_job_discovered_cell_count",
				static_job
			))
			+ int(pathfinder.call(
				"_get_runtime_flow_job_discovered_cell_count",
				background_job
			))
		)
		_expect(
			dynamic_discovered > lower_priority_discovered,
			"Weighted service must retain a measurable player-flow preference (%s)."
			% suffix
		)
		_expect(
			pathfinder.runtime_flow_priority_counts == [1, 1, 2]
			and pathfinder.runtime_flow_build_order.size() == 4,
			"Quantum rotation must preserve exact priority-band counts (%s)." % suffix
		)
		pathfinder.call(
			"_get_or_create_runtime_flow_build_job",
			Vector2i(8, 40),
			Vector2.ZERO,
			GridPathfinder.DEFAULT_TRAVERSAL_TYPES,
			grid,
			GridPathfinder.RuntimeFlowJobPriority.STATIC_OBJECTIVE,
			background_targets,
			grid.region,
			Vector2i.MAX,
			background_key
		)
		_expect(
			pathfinder.runtime_flow_priority_counts == [0, 2, 2]
			and int(background_job.get("priority"))
				== GridPathfinder.RuntimeFlowJobPriority.STATIC_OBJECTIVE,
			"Priority promotion must atomically move one counted band entry (%s)."
			% suffix
		)
		pathfinder.call("_remove_runtime_flow_build_job", dynamic_a_key)
		_expect(
			pathfinder.runtime_flow_priority_counts == [0, 2, 1]
			and pathfinder.runtime_flow_build_order.size() == 3,
			"Completion/removal must decrement the owning priority band once (%s)."
			% suffix
		)
		pathfinder.call("_cancel_all_runtime_navigation_jobs")
		_expect(
			pathfinder.runtime_flow_priority_counts == [0, 0, 0]
			and pathfinder.runtime_flow_build_order.is_empty(),
			"Bulk cancellation must reset every priority-band invariant (%s)." % suffix
		)
		pathfinder.queue_free()


func _test_flow_priority_selector_performance_ab(
	game: GameTowerDefense
) -> void:
	var pathfinder := _create_open_synthetic_pathfinder(
		game,
		"FlowPrioritySelectorPerformanceAB",
		Vector2i(8, 8),
		4
	)
	for job_index in range(64):
		var priority := GridPathfinder.RuntimeFlowJobPriority.BACKGROUND
		if job_index < 48:
			priority = GridPathfinder.RuntimeFlowJobPriority.DYNAMIC_TARGET
		elif job_index < 56:
			priority = GridPathfinder.RuntimeFlowJobPriority.STATIC_OBJECTIVE
		var cache_key := "selector-ab-%d" % job_index
		var job := GridPathfinder.RuntimeFlowBuildJob.new()
		job.generation = pathfinder.navigation_generation
		job.cache_key = cache_key
		job.priority = priority
		pathfinder.runtime_flow_build_jobs[cache_key] = job
		pathfinder.call("_insert_runtime_flow_job_key", cache_key, priority)
	_expect(
		pathfinder.runtime_flow_priority_counts == [8, 8, 48]
		and pathfinder.runtime_flow_build_order.size() == 64,
		"The O(1) selector fixture must retain exact contiguous priority-band counts."
	)
	var optimized_samples: Array[int] = []
	var legacy_samples: Array[int] = []
	var optimized_checksum := -1
	var legacy_checksum := -2
	for sample_index in range(7):
		var first_optimized := sample_index % 2 == 0
		var first := _measure_flow_priority_selector(
			pathfinder,
			first_optimized
		)
		var second := _measure_flow_priority_selector(
			pathfinder,
			not first_optimized
		)
		for measurement in [first, second]:
			if bool(measurement["optimized"]):
				optimized_samples.append(int(measurement["usec"]))
				optimized_checksum = int(measurement["checksum"])
			else:
				legacy_samples.append(int(measurement["usec"]))
				legacy_checksum = int(measurement["checksum"])
	optimized_samples.sort()
	legacy_samples.sort()
	var optimized_median := optimized_samples[optimized_samples.size() / 2]
	var legacy_median := legacy_samples[legacy_samples.size() / 2]
	print(
		"FLOW_PRIORITY_SELECTOR_AB jobs=64 iterations=%d optimized_usec=%d legacy_scan_usec=%d ratio=%.3f"
		% [
			FLOW_PRIORITY_SELECTOR_AB_ITERATIONS,
			optimized_median,
			legacy_median,
			float(optimized_median) / maxf(float(legacy_median), 1.0),
		]
	)
	_expect(
		optimized_checksum == legacy_checksum,
		"The O(1) priority-band selector must match the retired full-scan result."
	)
	_expect(
		optimized_median <= 50000
		and optimized_median * 2 < legacy_median,
		"64-job selector A/B must stay below 5us/call and beat full scans by >2x."
	)
	pathfinder.queue_free()


func _measure_flow_priority_selector(
	pathfinder: SyntheticGridPathfinder,
	optimized: bool
) -> Dictionary:
	var checksum := 0
	var started_usec := Time.get_ticks_usec()
	for iteration in range(FLOW_PRIORITY_SELECTOR_AB_ITERATIONS):
		var priority := GridPathfinder.RUNTIME_FLOW_PRIORITY_SERVICE_CYCLE[
			iteration % GridPathfinder.RUNTIME_FLOW_PRIORITY_SERVICE_CYCLE.size()
		]
		var order_index := (
			pathfinder._get_runtime_flow_service_order_index(priority)
			if optimized
			else _legacy_flow_priority_service_order_index(pathfinder, priority)
		)
		checksum += order_index
	return {
		"optimized": optimized,
		"usec": Time.get_ticks_usec() - started_usec,
		"checksum": checksum,
	}


func _legacy_flow_priority_service_order_index(
	pathfinder: SyntheticGridPathfinder,
	requested_priority: int
) -> int:
	var selected_index := -1
	for order_index in range(pathfinder.runtime_flow_build_order.size()):
		var queued_job := pathfinder.runtime_flow_build_jobs.get(
			pathfinder.runtime_flow_build_order[order_index]
		) as GridPathfinder.RuntimeFlowBuildJob
		if queued_job == null or queued_job.generation != pathfinder.navigation_generation:
			return order_index
		if selected_index < 0 and queued_job.priority == requested_priority:
			selected_index = order_index
	return selected_index if selected_index >= 0 else 0


func _test_integral_forward_obstacle_lookahead(game: GameTowerDefense) -> void:
	var pathfinder := _create_open_synthetic_pathfinder(
		game,
		"IntegralForwardObstacleLookahead",
		Vector2i(24, 24),
		8
	)
	var grid := pathfinder.astar_grid
	grid.set_point_solid(Vector2i(8, 10), true)
	var cache_key := pathfinder.call(
		"_get_agent_grid_cache_key",
		Vector2.ZERO,
		GridPathfinder.DEFAULT_TRAVERSAL_TYPES
	) as String
	var snapshot: Variant = pathfinder.call(
		"_build_agent_solid_integral_snapshot",
		grid
	)
	pathfinder.call(
		"_store_agent_open_plain_integral_snapshot",
		cache_key,
		snapshot
	)
	var profile := GridPathfinder.AgentNavigationProfile.new()
	profile.generation = pathfinder.navigation_generation
	profile.cache_key = cache_key
	profile.normalized_extents = Vector2.ZERO
	profile.traversal_types = GridPathfinder.DEFAULT_TRAVERSAL_TYPES
	profile.path_grid = grid
	profile.solid_integral_snapshot = snapshot
	var source := pathfinder.call("_map_to_global", Vector2i(5, 10)) as Vector2
	var blocked_target := pathfinder.call("_map_to_global", Vector2i(12, 10)) as Vector2
	var open_target := pathfinder.call("_map_to_global", Vector2i(5, 16)) as Vector2
	_expect(
		pathfinder.try_has_navigation_obstacle_ahead_with_profile(
			source,
			blocked_target,
			2.0,
			3.0,
			profile
		) == true,
		"The O(1) forward lookahead must see a wall beyond the current short probe."
	)
	_expect(
		pathfinder.try_has_navigation_obstacle_ahead_with_profile(
			source,
			open_target,
			2.0,
			3.0,
			profile
		) == false
		and pathfinder.runtime_flow_build_jobs.is_empty(),
		"An open lookahead must stay allocation-free and enqueue no flow work."
	)
	pathfinder.queue_free()


func _test_dynamic_prefetch_cohort_deduplication(
	game: GameTowerDefense
) -> void:
	var pathfinder := _create_open_synthetic_pathfinder(
		game,
		"DynamicPrefetchCohortDeduplication",
		Vector2i(48, 48),
		16
	)
	var target := Node2D.new()
	target.name = "SharedPrefetchTarget"
	pathfinder.add_child(target)
	target.global_position = pathfinder.call(
		"_map_to_global",
		Vector2i(24, 24)
	) as Vector2
	var cache_key := pathfinder.call(
		"_get_agent_grid_cache_key",
		Vector2.ZERO,
		GridPathfinder.DEFAULT_TRAVERSAL_TYPES
	) as String
	var profile := GridPathfinder.AgentNavigationProfile.new()
	profile.generation = pathfinder.navigation_generation
	profile.cache_key = cache_key
	profile.normalized_extents = Vector2.ZERO
	profile.traversal_types = GridPathfinder.DEFAULT_TRAVERSAL_TYPES
	profile.path_grid = pathfinder.astar_grid
	profile.solid_integral_snapshot = pathfinder.call(
		"_get_agent_open_plain_integral_snapshot",
		cache_key
	)
	_expect(profile != null, "The shared-prefetch fixture must resolve one agent profile.")
	var issued_count := 0
	var request_count_before := pathfinder.dynamic_flow_prefetch_requests_total
	var full_count_before := pathfinder.dynamic_flow_prefetch_full_requests_total
	var dedupe_count_before := pathfinder.dynamic_flow_prefetch_deduplicated_total
	for enemy_index in range(160):
		var source_cell := Vector2i(
			4 + enemy_index % 16,
			4 + floori(float(enemy_index) / 16.0) % 10
		)
		if pathfinder.try_prefetch_dynamic_target_flow_with_profile(
			pathfinder.call("_map_to_global", source_cell) as Vector2,
			target,
			0.0,
			profile
		):
			issued_count += 1
	_expect(
		issued_count == 1
		and pathfinder.dynamic_flow_prefetch_requests_total
			- request_count_before == 160
		and pathfinder.dynamic_flow_prefetch_full_requests_total
			- full_count_before == 1
		and pathfinder.dynamic_flow_prefetch_deduplicated_total
			- dedupe_count_before == 159,
		"A 160-enemy cohort must issue one full prefetch and merge the other 159."
	)
	_expect(
		pathfinder.dynamic_flow_target_slots.size() == 1
		and pathfinder.runtime_flow_build_jobs.size() == 1,
		"Same-frame cohort prefetch must allocate exactly one slot and one flow job."
	)
	pathfinder.queue_free()


func _test_prefetch_preserves_unique_coverage_sources(
	game: GameTowerDefense
) -> void:
	var pathfinder := _create_open_synthetic_pathfinder(
		game,
		"DynamicPrefetchCoverageSources",
		Vector2i(24, 24),
		3
	)
	var target_cell := Vector2i(4, 4)
	var target := Node2D.new()
	pathfinder.add_child(target)
	target.global_position = pathfinder.call("_map_to_global", target_cell) as Vector2
	var initial_result := GridPathfinder.NavigationStepResult.new()
	pathfinder.try_write_dynamic_target_navigation_step(
		initial_result,
		GridPathfinder.FlowQueryContext.new(),
		pathfinder.call("_map_to_global", Vector2i(5, 4)) as Vector2,
		target,
		Vector2.ZERO,
		GridPathfinder.DEFAULT_TRAVERSAL_TYPES,
		0.0
	)
	_drain_runtime_flow_jobs(pathfinder, 5000)
	var cache_key := pathfinder.call(
		"_get_agent_grid_cache_key",
		Vector2.ZERO,
		GridPathfinder.DEFAULT_TRAVERSAL_TYPES
	) as String
	var profile := GridPathfinder.AgentNavigationProfile.new()
	profile.generation = pathfinder.navigation_generation
	profile.cache_key = cache_key
	profile.normalized_extents = Vector2.ZERO
	profile.traversal_types = GridPathfinder.DEFAULT_TRAVERSAL_TYPES
	profile.path_grid = pathfinder.astar_grid
	profile.solid_integral_snapshot = pathfinder.call(
		"_get_agent_open_plain_integral_snapshot",
		cache_key
	)
	var source_a := Vector2i(10, 4)
	var source_b := Vector2i(10, 6)
	var full_before := pathfinder.dynamic_flow_prefetch_full_requests_total
	var dedupe_before := pathfinder.dynamic_flow_prefetch_deduplicated_total
	for source_cell in [source_a, source_b, source_b]:
		pathfinder.try_prefetch_dynamic_target_flow_with_profile(
			pathfinder.call("_map_to_global", source_cell) as Vector2,
			target,
			0.0,
			profile
		)
	var job: Variant = _only_value(pathfinder.runtime_flow_build_jobs)
	_expect(
		job != null
		and bool(job.get("complete_when_required_sources_reached"))
		and (job.get("required_source_cells") as Dictionary).has(source_a)
		and (job.get("required_source_cells") as Dictionary).has(source_b),
		"Same-frame prefetch must retain every unique out-of-region coverage source."
	)
	_expect(
		pathfinder.dynamic_flow_prefetch_full_requests_total - full_before == 2
		and pathfinder.dynamic_flow_prefetch_deduplicated_total - dedupe_before == 1
		and pathfinder.runtime_flow_build_jobs.size() == 1,
		"Coverage prefetch must merge duplicate cells while sharing one continuation job."
	)
	_drain_runtime_flow_jobs(pathfinder, 10000)
	var slot: Variant = _only_value(pathfinder.dynamic_flow_target_slots)
	var published_next_cells := (
		(slot.get("published_field") as Dictionary).get("next_cells", {}) as Dictionary
		if slot != null
		else {}
	)
	_expect(
		published_next_cells.has(source_a) and published_next_cells.has(source_b),
		"The shared coverage publication must contain both prefetched sources."
	)
	for source_cell in [source_a, source_b]:
		var result := GridPathfinder.NavigationStepResult.new()
		pathfinder.try_write_dynamic_target_navigation_step(
			result,
			GridPathfinder.FlowQueryContext.new(),
			pathfinder.call("_map_to_global", source_cell) as Vector2,
			target,
			Vector2.ZERO,
			GridPathfinder.DEFAULT_TRAVERSAL_TYPES,
			0.0
		)
		_expect(
			result.status == GridPathfinder.NavigationStepStatus.READY,
			"Every prefetched coverage source must be READY after publication."
		)
	var invalid_full_before := pathfinder.dynamic_flow_prefetch_full_requests_total
	var invalid_dedupe_before := pathfinder.dynamic_flow_prefetch_deduplicated_total
	var invalid_jobs_before := pathfinder.runtime_flow_build_jobs.size()
	for invalid_source in [Vector2i(-1, -1), Vector2i(-2, -2)]:
		pathfinder.try_prefetch_dynamic_target_flow_with_profile(
			pathfinder.call("_map_to_global", invalid_source) as Vector2,
			target,
			0.0,
			profile
		)
	var invalid_full_delta := (
		pathfinder.dynamic_flow_prefetch_full_requests_total - invalid_full_before
	)
	var invalid_dedupe_delta := (
		pathfinder.dynamic_flow_prefetch_deduplicated_total - invalid_dedupe_before
	)
	var invalid_job: Variant = _only_value(pathfinder.runtime_flow_build_jobs)
	var invalid_job_summary := (
		{
			"key": invalid_job.get("cache_key"),
			"coverage": invalid_job.get("complete_when_required_sources_reached"),
			"required": invalid_job.get("required_source_cells"),
		}
		if invalid_job != null
		else {}
	)
	_expect(
		invalid_full_delta == 1
		and invalid_dedupe_delta == 1
		and pathfinder.runtime_flow_build_jobs.size() == invalid_jobs_before,
		(
			"Distinct unwalkable/out-of-region sources must share the slot-level "
			+ "dedupe key and never create useless coverage work: full=%d dedupe=%d jobs=%d->%d %s."
		) % [
			invalid_full_delta,
			invalid_dedupe_delta,
			invalid_jobs_before,
			pathfinder.runtime_flow_build_jobs.size(),
			str(invalid_job_summary),
		]
	)
	pathfinder.queue_free()


func _stage_packed_coverage_materialization(
	game: GameTowerDefense,
	pathfinder_name: String
) -> Dictionary:
	var pathfinder := _create_open_synthetic_pathfinder(
		game,
		pathfinder_name,
		Vector2i(24, 24),
		3
	)
	var target_cell := Vector2i(4, 4)
	var initial_source_cell := Vector2i(5, 4)
	var first_coverage_source_cell := Vector2i(10, 4)
	var target := Node2D.new()
	target.name = "%sTarget" % pathfinder_name
	pathfinder.add_child(target)
	target.global_position = pathfinder.call("_map_to_global", target_cell) as Vector2

	var result := GridPathfinder.NavigationStepResult.new()
	var context := GridPathfinder.FlowQueryContext.new()
	pathfinder.try_write_dynamic_target_navigation_step(
		result,
		context,
		pathfinder.call("_map_to_global", initial_source_cell) as Vector2,
		target,
		Vector2.ZERO,
		GridPathfinder.DEFAULT_TRAVERSAL_TYPES,
		0.0
	)
	_expect(
		result.status == GridPathfinder.NavigationStepStatus.DEFERRED
		and pathfinder.runtime_flow_build_jobs.size() == 1,
		"The packed materialization fixture must begin with one bounded cold job."
	)
	_drain_runtime_flow_jobs(pathfinder, 5000)

	var slot: Variant = _only_value(pathfinder.dynamic_flow_target_slots)
	_expect(
		slot != null and int(slot.get("published_revision")) == 1,
		"The packed materialization fixture must first publish its bounded revision."
	)
	result = GridPathfinder.NavigationStepResult.new()
	context = GridPathfinder.FlowQueryContext.new()
	pathfinder.try_write_dynamic_target_navigation_step(
		result,
		context,
		pathfinder.call(
			"_map_to_global",
			first_coverage_source_cell
		) as Vector2,
		target,
		Vector2.ZERO,
		GridPathfinder.DEFAULT_TRAVERSAL_TYPES,
		0.0
	)
	var job: Variant = _only_value(pathfinder.runtime_flow_build_jobs)
	_expect(
		result.status == GridPathfinder.NavigationStepStatus.DEFERRED
		and job != null
		and bool(job.get("uses_packed_storage"))
		and bool(job.get("complete_when_required_sources_reached")),
		"A source outside the bounded field must stage one packed coverage job."
	)
	if job == null:
		return {
			"pathfinder": pathfinder,
			"target": target,
			"slot": slot,
			"job": null,
		}

	var search_steps := 0
	while (
		not bool(job.get("search_completed"))
		and search_steps < 5000
	):
		pathfinder.call("_advance_first_runtime_flow_job")
		search_steps += 1
	_expect(
		bool(job.get("search_completed"))
		and int(job.get("pending_entry_count")) > 0,
		"Coverage search must stop at its first required source while a resumable frontier remains."
	)
	pathfinder.call("_advance_first_runtime_flow_job")
	_expect(
		bool(job.get("search_completed"))
		and int(job.get("next_materialize_cell_index")) > 0
		and int(job.get("next_materialize_cell_index"))
			< (job.get("packed_distances") as PackedInt32Array).size()
		and not (job.get("distances") as Dictionary).is_empty()
		and pathfinder.runtime_flow_build_jobs.size() == 1
		and int(slot.get("published_revision")) == 1,
		"One bounded materialization batch must remain partial and unpublished."
	)
	return {
		"pathfinder": pathfinder,
		"target": target,
		"slot": slot,
		"job": job,
	}


func _create_open_synthetic_pathfinder(
	game: GameTowerDefense,
	pathfinder_name: String,
	region_size: Vector2i,
	flow_radius_cells: int
) -> SyntheticGridPathfinder:
	var synthetic_grid := AStarGrid2D.new()
	synthetic_grid.region = Rect2i(Vector2i.ZERO, region_size)
	synthetic_grid.cell_size = Vector2(16.0, 16.0)
	synthetic_grid.diagonal_mode = AStarGrid2D.DIAGONAL_MODE_ONLY_IF_NO_OBSTACLES
	synthetic_grid.default_compute_heuristic = AStarGrid2D.HEURISTIC_OCTILE
	synthetic_grid.default_estimate_heuristic = AStarGrid2D.HEURISTIC_OCTILE
	synthetic_grid.update()

	var pathfinder := SyntheticGridPathfinder.new()
	pathfinder.name = pathfinder_name
	game.add_child(pathfinder)
	pathfinder.navigation_generation = 1
	pathfinder.astar_grid = synthetic_grid
	pathfinder.is_built = true
	pathfinder.dynamic_target_flow_radius_cells = flow_radius_cells
	pathfinder.coalesce_dynamic_target_profiles_by_grid_topology = false
	pathfinder.runtime_flow_use_packed_build_storage = true
	var default_cache_key := pathfinder.call(
		"_get_agent_grid_cache_key",
		Vector2.ZERO,
		GridPathfinder.DEFAULT_TRAVERSAL_TYPES
	) as String
	var default_snapshot: Variant = pathfinder.call(
		"_build_agent_solid_integral_snapshot",
		synthetic_grid
	)
	pathfinder.call(
		"_store_agent_open_plain_integral_snapshot",
		default_cache_key,
		default_snapshot
	)
	return pathfinder


func _drain_runtime_flow_jobs(pathfinder: GridPathfinder, maximum_steps: int) -> void:
	var steps := 0
	while not pathfinder.runtime_flow_build_jobs.is_empty() and steps < maximum_steps:
		pathfinder.call("_advance_first_runtime_flow_job")
		steps += 1
	_expect(
		pathfinder.runtime_flow_build_jobs.is_empty(),
		"A synthetic runtime flow job must complete within its expansion guard."
	)


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
				var far_retarget := anchor + direction * 6
				var lane_is_walkable := true
				for lane_offset in range(1, 7):
					if not bool(pathfinder.call(
						"_is_cell_walkable",
						anchor + direction * lane_offset,
						path_grid
					)):
						lane_is_walkable = false
						break
				if not lane_is_walkable:
					continue
				var source := _find_connected_source(pathfinder, path_grid, anchor)
				if source == Vector2i.MAX:
					continue
				return {
					"source": source,
					"anchor": anchor,
					"adjacent": adjacent,
					"repath": repath,
					"far_retarget": far_retarget,
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
