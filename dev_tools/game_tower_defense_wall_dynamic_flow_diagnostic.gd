extends SceneTree

# Integration regression for the synchronized enemy stop observed when the
# moving player target reaches a wall. It drives the same contact-region slot
# contract as production enemies and validates both build bounds and liveness.
const TOWER_SCENE := preload("res://scene/game_tower_defense.tscn")
const BASIC_ENEMY_CONFIG := preload(
	"res://resources/config/enemies/yuanshi_insect_basic.tres"
)
const MAX_ENEMIES := 160
const MIN_SOURCE_DISTANCE_CELLS := 12
const MAX_BUILD_FRAMES := 600
const MAX_COLD_HANDOFF_FRAMES := 360
const OPEN_GROUND_AB_ITERATIONS := 1000
const OPEN_GROUND_AB_SAMPLE_COUNT := 7
const OPEN_GROUND_AB_WARMUP_ITERATIONS := 128
const MAX_OPEN_GROUND_LOOKAHEAD_RATIO := 4.0
const MAX_OPEN_GROUND_LOOKAHEAD_USEC_PER_CALL := 40.0
const FLOW_RADIUS_ENV := "ARC_NAV_DYNAMIC_FLOW_RADIUS"
const SOURCE_RADIUS_ENV := "ARC_NAV_SOURCE_RADIUS"
const PACKED_BUILD_ENV := "ARC_NAV_PACKED_FLOW_BUILD"

var game: GameTowerDefense
var pathfinder: GridPathfinder
var enemies: Array[Enemy] = []
var failures: Array[String] = []
var source_collection_radius_cells: int = 0


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	game = TOWER_SCENE.instantiate() as GameTowerDefense
	if game == null:
		push_error("WALL_DYNAMIC_FLOW_DIAGNOSTIC could not instantiate tower defense.")
		quit(1)
		return
	game.auto_start_waves = false
	root.add_child(game)
	current_scene = game
	await process_frame
	await physics_frame
	_stop_background_gameplay()

	pathfinder = game.grid_pathfinder as GridPathfinder
	if pathfinder == null or not pathfinder.is_built or game.player == null:
		push_error("WALL_DYNAMIC_FLOW_DIAGNOSTIC requires a built pathfinder and player.")
		await _finish(1)
		return
	_apply_ab_overrides()

	var probe_enemy := BASIC_ENEMY_CONFIG.enemy_scene.instantiate() as Enemy
	game.enemy_container.add_child(probe_enemy)
	probe_enemy.setup(BASIC_ENEMY_CONFIG, game.player, pathfinder)
	probe_enemy.set_physics_process(false)
	var half_extents := probe_enemy.get_configured_body_collision_half_extents()
	var traversal_types := BASIC_ENEMY_CONFIG.terrain_traversal_types
	pathfinder.prewarm_agent_grid(half_extents, traversal_types)
	var profile := pathfinder.try_get_agent_navigation_profile(
		half_extents,
		traversal_types
	)
	if profile == null:
		push_error("WALL_DYNAMIC_FLOW_DIAGNOSTIC could not build the basic enemy profile.")
		await _finish(1)
		return

	var fixture := _find_wall_fixture(profile)
	if fixture.is_empty():
		push_error("WALL_DYNAMIC_FLOW_DIAGNOSTIC found no reachable wall fixture.")
		await _finish(1)
		return
	var initial_cell := fixture["initial_cell"] as Vector2i
	var wall_cell := fixture["wall_cell"] as Vector2i
	var wall_direction := fixture["wall_direction"] as Vector2i
	var initial_position := pathfinder.call("_map_to_global", initial_cell) as Vector2
	var wall_position := pathfinder.call("_map_to_global", wall_cell) as Vector2
	game.player.global_position = initial_position
	game.player.velocity = Vector2.ZERO
	game.player.set_physics_process(false)

	var source_cells := _collect_sources(
		profile,
		wall_cell,
		wall_position,
		initial_cell
	)
	if source_cells.is_empty():
		push_error("WALL_DYNAMIC_FLOW_DIAGNOSTIC found no wall-occluded enemy sources.")
		await _finish(1)
		return
	var source_cohort_signature := _get_source_cohort_signature(source_cells)
	probe_enemy.set_near_moving_target_direct_distance(
		GameTowerDefense.PLAYER_NEAR_MOVING_DIRECT_DISTANCE
	)
	probe_enemy.navigation_update_interval_frames = 1
	var cold_fixture := _find_cold_handoff_fixture(
		probe_enemy,
		profile
	)
	var cold_source_cell: Vector2i = cold_fixture.get(
		"source_cell",
		Vector2i.MAX
	) as Vector2i
	var cold_target_position: Vector2 = cold_fixture.get(
		"target_position",
		wall_position
	) as Vector2
	var open_ground_metrics := _measure_open_ground_lookahead_ab(
		probe_enemy,
		profile
	)
	var prefetch_throttle_metrics := await _measure_enemy_prefetch_throttle(
		probe_enemy,
		cold_source_cell,
		cold_target_position
	)
	var cold_handoff_metrics := await _run_cold_short_probe_handoff(
		probe_enemy,
		cold_source_cell,
		cold_target_position
	)
	probe_enemy.queue_free()
	await process_frame
	_reset_cold_runtime_state()
	game.player.global_position = initial_position
	_spawn_enemies(source_cells)

	var initial_build := await _wait_for_dynamic_ready(enemies[0])
	var initial_build_frames := int(initial_build["frames"])
	if initial_build_frames < 0:
		push_error("WALL_DYNAMIC_FLOW_DIAGNOSTIC initial dynamic field did not publish.")
		await _finish(1)
		return
	var slot := _get_only_dynamic_slot()
	var initial_revision := slot.published_revision if slot != null else -1
	var initial_field_cells := (
		(
			slot.published_field.get("next_cells", {}) as Dictionary
		).size()
		if slot != null
		else 0
	)
	var initial_field_signature := (
		_get_flow_field_signature(slot.published_field) if slot != null else ""
	)
	var initial_region_cells := (
		slot.published_build_region.size.x * slot.published_build_region.size.y
		if slot != null
		else 0
	)
	_expect(
		pathfinder.dynamic_flow_target_slots.size() == 1 and slot != null,
		"The initial pursuing cohort must share exactly one dynamic target slot."
	)
	if slot != null:
		_expect(
			slot.published_build_region.size.x
				<= pathfinder.dynamic_target_flow_radius_cells * 2 + 1
			and slot.published_build_region.size.y
				<= pathfinder.dynamic_target_flow_radius_cells * 2 + 1,
			"The normal moving-target field must stay inside its bounded local window."
		)

	game.player.global_position = wall_position
	var frozen_snapshot := _sample_enemy_flow_directions()
	var production_snapshot := _sample_enemy_safe_directions()
	var pending_slot := _get_only_dynamic_slot()
	var frozen_published_anchor := (
		pending_slot.published_anchor_cell if pending_slot != null else Vector2i.MAX
	)
	var frozen_desired_original := (
		pending_slot.desired_original_cell if pending_slot != null else Vector2i.MAX
	)
	var frozen_desired_resolved := (
		pending_slot.desired_resolved_cell if pending_slot != null else Vector2i.MAX
	)
	var pending_job_target := Vector2i.MAX
	if pending_slot != null and pending_slot.pending_job_key != "":
		var pending_job := pathfinder.runtime_flow_build_jobs.get(
			pending_slot.pending_job_key
		) as GridPathfinder.RuntimeFlowBuildJob
		if pending_job != null:
			pending_job_target = pending_job.target_cell

	var replacement_frames := 0
	var replacement_expansion_sum := 0
	var replacement_expansion_peak := 0
	var replacement_usec_sum := 0
	var replacement_usec_peak := 0
	var replacement_expansion_capped_frames := 0
	var replacement_deadline_capped_frames := 0
	while replacement_frames < MAX_BUILD_FRAMES:
		var live_slot := _get_only_dynamic_slot()
		if live_slot != null and live_slot.published_revision > initial_revision:
			break
		await process_frame
		replacement_frames += 1
		replacement_expansion_sum += pathfinder.runtime_navigation_expansions_last_frame
		replacement_expansion_peak = maxi(
			replacement_expansion_peak,
			pathfinder.runtime_navigation_expansions_last_frame
		)
		replacement_usec_sum += pathfinder.runtime_navigation_build_usec_last_frame
		replacement_usec_peak = maxi(
			replacement_usec_peak,
			pathfinder.runtime_navigation_build_usec_last_frame
		)
		if (
			pathfinder.runtime_navigation_expansions_last_frame
			>= pathfinder.runtime_navigation_max_expansions_per_frame
		):
			replacement_expansion_capped_frames += 1
		if (
			pathfinder.runtime_navigation_build_usec_last_frame
			>= pathfinder.runtime_navigation_time_budget_usec
		):
			replacement_deadline_capped_frames += 1
	var replacement_slot := _get_only_dynamic_slot()
	_expect(
		replacement_frames < MAX_BUILD_FRAMES
		and replacement_slot != null
		and replacement_slot.published_revision > initial_revision,
		"The wall-adjacent replacement field must publish within the render-frame guard."
	)
	if replacement_slot != null:
		_expect(
			replacement_slot.published_build_region.size.x
				<= pathfinder.dynamic_target_flow_radius_cells * 2 + 1
			and replacement_slot.published_build_region.size.y
				<= pathfinder.dynamic_target_flow_radius_cells * 2 + 1,
			"A fresh local replacement must remain bounded even beside a wall."
		)

	var recovered_snapshot := _sample_enemy_flow_directions()
	var recovery_wait_frames := 0
	while recovery_wait_frames < MAX_BUILD_FRAMES:
		var recovery_slot := _get_only_dynamic_slot()
		if (
			int(recovered_snapshot.get("nonzero", 0)) == enemies.size()
			and recovery_slot != null
			and recovery_slot.pending_job_key == ""
		):
			break
		await process_frame
		recovery_wait_frames += 1
		recovered_snapshot = _sample_enemy_flow_directions()
	var final_slot := _get_only_dynamic_slot()
	var replacement_field_cells := (
		(
			final_slot.published_field.get("next_cells", {}) as Dictionary
		).size()
		if final_slot != null
		else 0
	)
	var replacement_field_signature := (
		_get_flow_field_signature(final_slot.published_field)
		if final_slot != null
		else ""
	)
	var replacement_region_cells := (
		final_slot.published_build_region.size.x
			* final_slot.published_build_region.size.y
		if final_slot != null
		else 0
	)
	var local_goal_region := _collect_local_goal_region(profile, wall_cell)
	var profile_resolution_summary := _get_profile_resolution_summary(wall_cell)
	print(
		(
			"WALL_DYNAMIC_FLOW_COLD_HANDOFF source=%s direct_frames=%d flow_frames=%d "
			+ "max_zero_streak=%d request_frame=%d publish_frame=%d first_flow_frame=%d publish_latency=%d "
			+ "travel=%.2f usec_peak=%d expansion_peak=%d zero_details=%s"
		)
		% [
			str(cold_source_cell),
			int(cold_handoff_metrics.get("direct_frames", 0)),
			int(cold_handoff_metrics.get("flow_frames", 0)),
			int(cold_handoff_metrics.get("max_zero_streak", 0)),
			int(cold_handoff_metrics.get("request_frame", -1)),
			int(cold_handoff_metrics.get("publish_frame", -1)),
			int(cold_handoff_metrics.get("first_flow_frame", -1)),
			int(cold_handoff_metrics.get("publish_latency", -1)),
			float(cold_handoff_metrics.get("travel_distance", 0.0)),
			int(cold_handoff_metrics.get("usec_peak", 0)),
			int(cold_handoff_metrics.get("expansion_peak", 0)),
			str(cold_handoff_metrics.get("zero_details", [])),
		]
	)
	print(
		(
			"WALL_DYNAMIC_FLOW_OPEN_AB iterations=%d legacy_usec=%d lookahead_usec=%d "
			+ "ratio=%.3f open_nonzero=%d queued_jobs=%d"
		)
		% [
			OPEN_GROUND_AB_ITERATIONS,
			int(open_ground_metrics.get("legacy_usec", 0)),
			int(open_ground_metrics.get("lookahead_usec", 0)),
			float(open_ground_metrics.get("ratio", 0.0)),
			int(open_ground_metrics.get("nonzero", 0)),
			int(open_ground_metrics.get("queued_jobs", -1)),
		]
	)
	print(
		(
			"WALL_DYNAMIC_FLOW_PREFETCH_THROTTLE first=%d immediate=%d "
			+ "before_deadline=%d after_deadline=%d failed_profile_deadline=%d "
			+ "issued=%d deduplicated=%d"
		)
		% [
			int(prefetch_throttle_metrics.get("first_calls", -1)),
			int(prefetch_throttle_metrics.get("immediate_calls", -1)),
			int(prefetch_throttle_metrics.get("before_deadline_calls", -1)),
			int(prefetch_throttle_metrics.get("after_deadline_calls", -1)),
			int(prefetch_throttle_metrics.get("failed_profile_deadline", -1)),
			int(prefetch_throttle_metrics.get("issued", -1)),
			int(prefetch_throttle_metrics.get("deduplicated", -1)),
		]
	)

	print(
		(
			"WALL_DYNAMIC_FLOW_DIAGNOSTIC radius=%d source_radius=%d packed=%s cohort=%s "
			+ "enemies=%d initial_cell=%s wall_cell=%s "
			+ "initial_build_frames=%d stale=%d zero=%d ready=%d deferred=%d "
			+ "old_flow_nonzero=%d old_flow_shape_safe=%d far_from_old_anchor=%d "
			+ "outside_old_anchor_influence=%d remaining_range=%d..%d anchor_lag=%d "
			+ "uncertified_live_corridor=%d pending_job_target=%s "
			+ "replacement_frames=%d recovered_nonzero=%d final_revision=%d "
			+ "final_anchor=%s desired=%s "
			+ "initial_field_cells=%d initial_field_signature=%s initial_region_cells=%d "
			+ "initial_expansions_total=%d initial_expansions_avg=%.1f initial_expansions_peak=%d "
			+ "initial_usec_total=%d initial_usec_avg=%.1f initial_usec_peak=%d initial_caps=%d/%d "
			+ "replacement_field_cells=%d replacement_field_signature=%s replacement_region_cells=%d "
			+ "replacement_expansions_total=%d replacement_expansions_avg=%.1f replacement_expansions_peak=%d "
			+ "replacement_usec_total=%d replacement_usec_avg=%.1f replacement_usec_peak=%d replacement_caps=%d/%d"
			+ " wall_direction=%s frozen_published=%s frozen_desired_original=%s "
			+ "frozen_desired_resolved=%s local_goal_region=%s profile_resolutions=%s"
			+ " production_zero=%d production_nonzero=%d production_direct=%d production_stale=%d"
		)
		% [
			pathfinder.dynamic_target_flow_radius_cells,
			source_collection_radius_cells,
			str(pathfinder.runtime_flow_use_packed_build_storage).to_lower(),
			source_cohort_signature,
			enemies.size(),
			str(initial_cell),
			str(wall_cell),
			initial_build_frames,
			int(frozen_snapshot["stale"]),
			int(frozen_snapshot["zero"]),
			int(frozen_snapshot["ready"]),
			int(frozen_snapshot["deferred"]),
			int(frozen_snapshot["old_flow_nonzero"]),
			int(frozen_snapshot["old_flow_shape_safe"]),
			int(frozen_snapshot["far_from_old_anchor"]),
			int(frozen_snapshot["outside_old_anchor_influence"]),
			int(frozen_snapshot["minimum_remaining"]),
			int(frozen_snapshot["maximum_remaining"]),
			int(frozen_snapshot["maximum_anchor_lag"]),
			int(frozen_snapshot["uncertified"]),
			str(pending_job_target),
			replacement_frames,
			int(recovered_snapshot["nonzero"]),
			final_slot.published_revision if final_slot != null else -1,
			str(final_slot.published_anchor_cell if final_slot != null else Vector2i.MAX),
			str(final_slot.desired_resolved_cell if final_slot != null else Vector2i.MAX),
			initial_field_cells,
			initial_field_signature,
			initial_region_cells,
			int(initial_build["expansion_sum"]),
			float(initial_build["expansion_sum"]) / maxf(initial_build_frames, 1),
			int(initial_build["expansion_peak"]),
			int(initial_build["usec_sum"]),
			float(initial_build["usec_sum"]) / maxf(initial_build_frames, 1),
			int(initial_build["usec_peak"]),
			int(initial_build["expansion_capped_frames"]),
			int(initial_build["deadline_capped_frames"]),
			replacement_field_cells,
			replacement_field_signature,
			replacement_region_cells,
			replacement_expansion_sum,
			float(replacement_expansion_sum) / maxf(replacement_frames, 1),
			replacement_expansion_peak,
			replacement_usec_sum,
			float(replacement_usec_sum) / maxf(replacement_frames, 1),
			replacement_usec_peak,
			replacement_expansion_capped_frames,
			replacement_deadline_capped_frames,
			str(wall_direction),
			str(frozen_published_anchor),
			str(frozen_desired_original),
			str(frozen_desired_resolved),
			str(local_goal_region),
			str(profile_resolution_summary),
			int(production_snapshot["zero"]),
			int(production_snapshot["nonzero"]),
			int(production_snapshot["direct"]),
			int(production_snapshot["stale"]),
		]
	)

	_expect(not enemies.is_empty(), "The wall fixture must retain a non-empty enemy cohort.")
	_expect(
		cold_source_cell != Vector2i.MAX,
		"The real map must provide a cold short-probe-to-flow handoff fixture."
	)
	_expect(
		int(cold_handoff_metrics.get("request_frame", -1)) >= 0
		and int(cold_handoff_metrics.get("publish_frame", -1)) >= 0
		and int(cold_handoff_metrics.get("flow_frames", 0)) > 0
		and int(cold_handoff_metrics.get("publish_frame", 999))
			< int(cold_handoff_metrics.get("first_flow_frame", -1)),
		"A cold wall approach must prefetch and publish before actual movement hands off to flow."
	)
	_expect(
		int(cold_handoff_metrics.get("max_zero_streak", 999)) <= 1,
		"The cold wall handoff must not stop for more than one consecutive movement frame."
	)
	_expect(
		float(cold_handoff_metrics.get("travel_distance", 0.0)) > 1.0,
		"The cold handoff fixture must exercise real CharacterBody movement."
	)
	_expect(
		int(cold_handoff_metrics.get("usec_peak", 999999))
			<= ceili(float(pathfinder.runtime_navigation_time_budget_usec) * 1.25),
		"Cold flow prefetch must keep scheduler peak overshoot within 25% of its microsecond budget."
	)
	_expect(
		int(open_ground_metrics.get("nonzero", 0)) == OPEN_GROUND_AB_ITERATIONS
		and int(open_ground_metrics.get("queued_jobs", -1)) == 0,
		"Open ground lookahead must preserve direct motion without enqueuing flow work."
	)
	_expect(
		float(open_ground_metrics.get("ratio", INF))
			<= MAX_OPEN_GROUND_LOOKAHEAD_RATIO
		and (
			float(open_ground_metrics.get("lookahead_usec", INF))
			/ float(OPEN_GROUND_AB_ITERATIONS)
		) <= MAX_OPEN_GROUND_LOOKAHEAD_USEC_PER_CALL,
		(
			"Open-ground lookahead must stay within its executable A/B CPU guard "
			+ "(ratio <= %.1f, <= %.1f usec/call)."
		) % [
			MAX_OPEN_GROUND_LOOKAHEAD_RATIO,
			MAX_OPEN_GROUND_LOOKAHEAD_USEC_PER_CALL,
		]
	)
	_expect(
		int(prefetch_throttle_metrics.get("first_calls", -1)) == 1
		and int(prefetch_throttle_metrics.get("immediate_calls", -1)) == 1
		and int(prefetch_throttle_metrics.get("before_deadline_calls", -1)) == 1
		and int(prefetch_throttle_metrics.get("after_deadline_calls", -1)) == 2
		and int(prefetch_throttle_metrics.get("failed_profile_deadline", -1)) == 0
		and int(prefetch_throttle_metrics.get("issued", 0)) >= 2,
		(
			"Enemy lookahead must retry immediately after an unavailable profile, "
			+ "then stay idle for five frames and resume on frame six."
		)
	)
	_expect(
		int(frozen_snapshot["old_flow_nonzero"]) == enemies.size()
		and int(frozen_snapshot["old_flow_shape_safe"])
			== int(frozen_snapshot["old_flow_nonzero"]),
		"Every old-field step must remain non-zero and shape-safe while replacement builds."
	)
	_expect(
		int(production_snapshot["zero"]) == 0
		and int(production_snapshot["nonzero"]) == enemies.size(),
		"Moving the player beside a wall must never freeze any member of the pursuing cohort."
	)
	_expect(
		recovery_wait_frames < MAX_BUILD_FRAMES
		and int(recovered_snapshot["nonzero"]) == enemies.size(),
		"All pursuers must regain a complete non-zero route after optional coverage continuation."
	)
	_expect(
		pathfinder.dynamic_flow_target_slots.size() == 1
		and final_slot != null
		and final_slot.published_anchor_cell == wall_cell
		and final_slot.desired_original_cell == wall_cell
		and final_slot.pending_job_key == "",
		"The final shared slot must target the live wall cell and leave no pending job."
	)
	_expect(
		final_slot != null and not final_slot.published_goal_cells.is_empty(),
		"The wall-adjacent player must retain at least one certified contact-region goal."
	)

	if failures.is_empty():
		await _finish(0)
		return
	for failure in failures:
		push_error(failure)
	await _finish(1)


func _apply_ab_overrides() -> void:
	var radius_text := OS.get_environment(FLOW_RADIUS_ENV).strip_edges()
	if radius_text.is_valid_int():
		pathfinder.dynamic_target_flow_radius_cells = maxi(int(radius_text), 1)
	source_collection_radius_cells = pathfinder.dynamic_target_flow_radius_cells
	var source_radius_text := OS.get_environment(SOURCE_RADIUS_ENV).strip_edges()
	if source_radius_text.is_valid_int():
		source_collection_radius_cells = maxi(int(source_radius_text), 1)
	var packed_build_text := OS.get_environment(PACKED_BUILD_ENV).strip_edges().to_lower()
	match packed_build_text:
		"1", "true", "yes", "on":
			pathfinder.runtime_flow_use_packed_build_storage = true
		"0", "false", "no", "off":
			pathfinder.runtime_flow_use_packed_build_storage = false
		"":
			pass
		_:
			push_warning(
				"Ignoring invalid %s=%s; expected true/false or 1/0."
				% [PACKED_BUILD_ENV, packed_build_text]
			)


func _find_cold_handoff_fixture(
	enemy: Enemy,
	profile: GridPathfinder.AgentNavigationProfile
) -> Dictionary:
	if enemy == null or profile == null:
		return {}
	var grid := profile.path_grid
	for y in range(grid.region.position.y, grid.region.end.y):
		for x in range(grid.region.position.x, grid.region.end.x):
			var wall_cell := Vector2i(x, y)
			if not grid.is_point_solid(wall_cell):
				continue
			for direction in GridPathfinder.FLOW_CARDINAL_DIRECTIONS:
				for side_distance in range(3, 6):
					var source_cell := wall_cell - direction * side_distance
					var target_cell := wall_cell + direction * side_distance
					if (
						not grid.is_in_boundsv(source_cell)
						or not grid.is_in_boundsv(target_cell)
						or grid.is_point_solid(source_cell)
						or grid.is_point_solid(target_cell)
					):
						continue
					var route := grid.get_id_path(source_cell, target_cell, false)
					if route.is_empty() or route[route.size() - 1] != target_cell:
						continue
					var source_position := pathfinder.call(
						"_map_to_global",
						source_cell
					) as Vector2
					var target_position := pathfinder.call(
						"_map_to_global",
						target_cell
					) as Vector2
					game.player.global_position = target_position
					enemy.global_position = source_position
					enemy.call("_clear_cached_navigation_move_direction")
					var direct_direction := enemy.call(
						"_get_collision_safe_short_navigation_step_direction",
						target_position
					) as Vector2
					if direct_direction == Vector2.ZERO:
						continue
					var probe_distance := float(enemy.call(
						"_get_far_direct_objective_probe_distance"
					))
					if pathfinder.try_has_navigation_obstacle_ahead_with_profile(
						source_position,
						target_position,
						probe_distance,
						Enemy.DYNAMIC_FLOW_PREFETCH_LOOKAHEAD_CELLS,
						profile
					) == true:
						return {
							"source_cell": source_cell,
							"target_cell": target_cell,
							"target_position": target_position,
						}
	return {}


func _run_cold_short_probe_handoff(
	enemy: Enemy,
	source_cell: Vector2i,
	target_position: Vector2
) -> Dictionary:
	var metrics := {
		"direct_frames": 0,
		"flow_frames": 0,
		"first_flow_frame": -1,
		"max_zero_streak": 0,
		"request_frame": -1,
		"publish_frame": -1,
		"publish_latency": -1,
		"travel_distance": 0.0,
		"usec_peak": 0,
		"expansion_peak": 0,
		"zero_details": [],
	}
	if enemy == null or source_cell == Vector2i.MAX:
		return metrics
	_reset_cold_runtime_state()
	game.player.global_position = target_position
	enemy.global_position = pathfinder.call("_map_to_global", source_cell) as Vector2
	enemy.velocity = Vector2.ZERO
	enemy.set_physics_process(false)
	enemy.call("_clear_cached_navigation_move_direction")
	# Teleporting the fixture updates CanvasItem immediately but its PhysicsServer2D
	# body transform is synchronized on the next physics step. Exclude that setup
	# artifact from the measured short-probe handoff.
	await physics_frame
	await physics_frame
	for _settle_frame in range(8):
		if enemy.call(
			"_get_collision_safe_short_navigation_step_direction",
			target_position
		) != Vector2.ZERO:
			break
		await process_frame
	enemy.call("_clear_cached_navigation_move_direction")
	var initial_position := enemy.global_position
	var consecutive_zero_frames := 0
	for frame_index in range(MAX_COLD_HANDOFF_FRAMES):
		var direction := enemy.call(
			"_get_safe_navigation_move_direction",
			game.player,
			pathfinder,
			1.0
		) as Vector2
		if direction == Vector2.ZERO:
			consecutive_zero_frames += 1
			metrics["max_zero_streak"] = maxi(
				int(metrics["max_zero_streak"]),
				consecutive_zero_frames
			)
			(metrics["zero_details"] as Array).append(
				{
					"frame": frame_index,
					"position": enemy.global_position,
					"status": (
						enemy.navigation_step_result.status
						if enemy.navigation_step_result != null
						else -1
					),
					"next": (
						enemy.navigation_step_result.next_cell
						if enemy.navigation_step_result != null
						else Vector2i.MAX
					),
				}
			)
		else:
			consecutive_zero_frames = 0
			if enemy.cached_navigation_uses_direct_objective_approach:
				metrics["direct_frames"] = int(metrics["direct_frames"]) + 1
			elif (
				enemy.navigation_step_result != null
				and enemy.navigation_step_result.status
					== GridPathfinder.NavigationStepStatus.READY
			):
				metrics["flow_frames"] = int(metrics["flow_frames"]) + 1
				if int(metrics["first_flow_frame"]) < 0:
					metrics["first_flow_frame"] = frame_index
		enemy.velocity = direction * enemy.get_effective_move_speed()
		# Exercise the real CharacterBody collision response without allowing the
		# player's contact Area2D to terminate the navigation fixture through a wall.
		# Production's direction selection is unchanged; this isolates the exact
		# short-probe -> flow transition that the diagnostic is intended to cover.
		enemy.move_and_slide()
		if (
			int(metrics["request_frame"]) < 0
			and not pathfinder.dynamic_flow_target_slots.is_empty()
		):
			metrics["request_frame"] = frame_index

		await process_frame
		metrics["usec_peak"] = maxi(
			int(metrics["usec_peak"]),
			pathfinder.runtime_navigation_build_usec_last_frame
		)
		metrics["expansion_peak"] = maxi(
			int(metrics["expansion_peak"]),
			pathfinder.runtime_navigation_expansions_last_frame
		)
		var slot := _get_only_dynamic_slot()
		if (
			int(metrics["publish_frame"]) < 0
			and slot != null
			and slot.published_revision > 0
		):
			metrics["publish_frame"] = frame_index
		if int(metrics["flow_frames"]) > 0:
			break
	metrics["travel_distance"] = initial_position.distance_to(enemy.global_position)
	if int(metrics["request_frame"]) >= 0 and int(metrics["publish_frame"]) >= 0:
		metrics["publish_latency"] = (
			int(metrics["publish_frame"]) - int(metrics["request_frame"])
		)
	return metrics


func _measure_enemy_prefetch_throttle(
	enemy: Enemy,
	source_cell: Vector2i,
	target_position: Vector2
) -> Dictionary:
	var empty_result := {
		"first_calls": -1,
		"immediate_calls": -1,
		"before_deadline_calls": -1,
		"after_deadline_calls": -1,
		"failed_profile_deadline": -1,
		"issued": -1,
		"deduplicated": -1,
	}
	if enemy == null or source_cell == Vector2i.MAX:
		return empty_result
	_reset_cold_runtime_state()
	game.player.global_position = target_position
	enemy.global_position = pathfinder.call("_map_to_global", source_cell) as Vector2
	enemy.navigation_flow_prefetch_next_physics_frame = 0
	var saved_pathfinder := enemy.pathfinder
	enemy.pathfinder = null
	enemy.call("_prefetch_dynamic_player_flow_if_obstacle_ahead", game.player)
	var failed_profile_deadline := enemy.navigation_flow_prefetch_next_physics_frame
	enemy.pathfinder = saved_pathfinder
	var previous_metrics_enabled := Enemy.performance_metrics_enabled
	Enemy.set_performance_metrics_enabled(true)
	enemy.call("_prefetch_dynamic_player_flow_if_obstacle_ahead", game.player)
	var first_calls := int(
		Enemy.get_performance_metrics().get("navigation_lookahead_calls", -1)
	)
	enemy.call("_prefetch_dynamic_player_flow_if_obstacle_ahead", game.player)
	var immediate_calls := int(
		Enemy.get_performance_metrics().get("navigation_lookahead_calls", -1)
	)
	for _early_frame in range(
		1,
		Enemy.DYNAMIC_FLOW_PREFETCH_INTERVAL_PHYSICS_FRAMES
	):
		await physics_frame
		enemy.call("_prefetch_dynamic_player_flow_if_obstacle_ahead", game.player)
	var before_deadline_calls := int(
		Enemy.get_performance_metrics().get("navigation_lookahead_calls", -1)
	)
	await physics_frame
	enemy.call("_prefetch_dynamic_player_flow_if_obstacle_ahead", game.player)
	var metrics := Enemy.get_performance_metrics()
	var result := {
		"first_calls": first_calls,
		"immediate_calls": immediate_calls,
		"before_deadline_calls": before_deadline_calls,
		"after_deadline_calls": int(metrics.get("navigation_lookahead_calls", -1)),
		"failed_profile_deadline": failed_profile_deadline,
		"issued": int(metrics.get("navigation_flow_prefetches", -1)),
		"deduplicated": int(metrics.get(
			"navigation_flow_prefetch_deduplicated",
			-1
		)),
	}
	Enemy.set_performance_metrics_enabled(previous_metrics_enabled)
	_reset_cold_runtime_state()
	enemy.navigation_flow_prefetch_next_physics_frame = 0
	return result


func _measure_open_ground_lookahead_ab(
	enemy: Enemy,
	profile: GridPathfinder.AgentNavigationProfile
) -> Dictionary:
	var fixture := _find_open_ground_fixture(enemy, profile)
	if enemy == null or fixture.is_empty():
		return {
			"legacy_usec": 0,
			"lookahead_usec": 0,
			"ratio": 0.0,
			"nonzero": 0,
			"queued_jobs": -1,
		}
	var source_position := fixture["source_position"] as Vector2
	var target_position := fixture["target_position"] as Vector2
	game.player.global_position = target_position
	enemy.global_position = source_position
	enemy.velocity = Vector2.ZERO
	enemy.call("_clear_cached_navigation_move_direction")
	_reset_cold_runtime_state()
	var direction := (target_position - source_position).normalized()
	var probe_distance := float(enemy.call(
		"_get_far_direct_objective_probe_distance"
	))
	var probe_end := source_position + direction * probe_distance

	_measure_open_ground_probe_batch(
		profile,
		source_position,
		target_position,
		probe_end,
		probe_distance,
		false,
		OPEN_GROUND_AB_WARMUP_ITERATIONS
	)
	_measure_open_ground_probe_batch(
		profile,
		source_position,
		target_position,
		probe_end,
		probe_distance,
		true,
		OPEN_GROUND_AB_WARMUP_ITERATIONS
	)
	var legacy_samples: Array[int] = []
	var lookahead_samples: Array[int] = []
	var nonzero := OPEN_GROUND_AB_ITERATIONS
	for sample_index in range(OPEN_GROUND_AB_SAMPLE_COUNT):
		var first_uses_lookahead := sample_index % 2 != 0
		var first := _measure_open_ground_probe_batch(
			profile,
			source_position,
			target_position,
			probe_end,
			probe_distance,
			first_uses_lookahead,
			OPEN_GROUND_AB_ITERATIONS
		)
		var second := _measure_open_ground_probe_batch(
			profile,
			source_position,
			target_position,
			probe_end,
			probe_distance,
			not first_uses_lookahead,
			OPEN_GROUND_AB_ITERATIONS
		)
		for measurement in [first, second]:
			if bool(measurement["lookahead"]):
				lookahead_samples.append(int(measurement["usec"]))
				nonzero = mini(nonzero, int(measurement["nonzero"]))
			else:
				legacy_samples.append(int(measurement["usec"]))
	legacy_samples.sort()
	lookahead_samples.sort()
	var legacy_usec := legacy_samples[legacy_samples.size() / 2]
	var lookahead_usec := lookahead_samples[lookahead_samples.size() / 2]
	var queued_jobs := (
		pathfinder.runtime_flow_build_jobs.size()
		+ pathfinder.dynamic_flow_target_slots.size()
	)
	return {
		"legacy_usec": legacy_usec,
		"lookahead_usec": lookahead_usec,
		"ratio": float(lookahead_usec) / maxf(float(legacy_usec), 1.0),
		"nonzero": nonzero,
		"queued_jobs": queued_jobs,
	}


func _measure_open_ground_probe_batch(
	profile: GridPathfinder.AgentNavigationProfile,
	source_position: Vector2,
	target_position: Vector2,
	probe_end: Vector2,
	probe_distance: float,
	include_lookahead: bool,
	iteration_count: int
) -> Dictionary:
	var nonzero := 0
	var started_usec := Time.get_ticks_usec()
	for _iteration in range(iteration_count):
		var short_clear: Variant = (
			pathfinder.try_is_navigation_segment_walkable_with_profile(
				source_position,
				probe_end,
				profile
			)
		)
		if not include_lookahead:
			continue
		var obstacle_ahead: Variant = (
			pathfinder.try_has_navigation_obstacle_ahead_with_profile(
				source_position,
				target_position,
				probe_distance,
				Enemy.DYNAMIC_FLOW_PREFETCH_LOOKAHEAD_CELLS,
				profile
			)
		)
		if short_clear == true and obstacle_ahead == false:
			nonzero += 1
	return {
		"lookahead": include_lookahead,
		"usec": maxi(Time.get_ticks_usec() - started_usec, 0),
		"nonzero": nonzero,
	}


func _find_open_ground_fixture(
	enemy: Enemy,
	profile: GridPathfinder.AgentNavigationProfile
) -> Dictionary:
	if enemy == null or profile == null:
		return {}
	var grid := profile.path_grid
	for y in range(grid.region.position.y, grid.region.end.y):
		for x in range(grid.region.position.x, grid.region.end.x):
			var source_cell := Vector2i(x, y)
			if grid.is_point_solid(source_cell):
				continue
			for direction in GridPathfinder.FLOW_CARDINAL_DIRECTIONS:
				var target_cell := source_cell + direction * 6
				if (
					not grid.is_in_boundsv(target_cell)
					or grid.is_point_solid(target_cell)
				):
					continue
				var source_position := pathfinder.call(
					"_map_to_global",
					source_cell
				) as Vector2
				var target_position := pathfinder.call(
					"_map_to_global",
					target_cell
				) as Vector2
				if pathfinder.try_is_navigation_open_plain_with_profile(
					source_position,
					target_position,
					profile
				) != true:
					continue
				game.player.global_position = target_position
				enemy.global_position = source_position
				enemy.call("_clear_cached_navigation_move_direction")
				if enemy.call(
					"_get_collision_safe_short_navigation_step_direction",
					target_position
				) == Vector2.ZERO:
					continue
				var probe_distance := float(enemy.call(
					"_get_far_direct_objective_probe_distance"
				))
				var probe_direction := (
					target_position - source_position
				).normalized()
				if not pathfinder.call(
					"_can_certify_navigation_segment_from_integral",
					source_position,
					source_position + probe_direction * probe_distance,
					profile.normalized_extents,
					profile.traversal_types,
					profile.solid_integral_snapshot
				):
					continue
				if pathfinder.try_has_navigation_obstacle_ahead_with_profile(
					source_position,
					target_position,
					probe_distance,
					Enemy.DYNAMIC_FLOW_PREFETCH_LOOKAHEAD_CELLS,
					profile
				) == false:
					return {
						"source_position": source_position,
						"target_position": target_position,
					}
	return {}


func _reset_cold_runtime_state() -> void:
	if pathfinder == null:
		return
	pathfinder.call("_cancel_all_runtime_navigation_jobs")
	pathfinder.dynamic_flow_target_slots.clear()
	pathfinder.flow_field_cache.clear()
	pathfinder.flow_field_cache_order.clear()
	pathfinder.runtime_navigation_expansions_last_frame = 0
	pathfinder.runtime_navigation_build_usec_last_frame = 0
	pathfinder.runtime_navigation_build_usec_peak = 0
	pathfinder.set_process(false)


func _get_source_cohort_signature(source_cells: Array[Vector2i]) -> String:
	var encoded_cells := PackedStringArray()
	for cell in source_cells:
		encoded_cells.append("%d,%d" % [cell.x, cell.y])
	return ";".join(encoded_cells).sha256_text().left(16)


func _get_flow_field_signature(field: Dictionary) -> String:
	var next_cells := field.get("next_cells", {}) as Dictionary
	var distances := field.get("distances", {}) as Dictionary
	var encoded_cells := PackedStringArray()
	for cell_variant in next_cells:
		var cell := cell_variant as Vector2i
		var next_cell := next_cells.get(cell, Vector2i.MAX) as Vector2i
		encoded_cells.append(
			"%d,%d>%d,%d:%d" % [
				cell.x,
				cell.y,
				next_cell.x,
				next_cell.y,
				int(distances.get(cell, -1)),
			]
		)
	encoded_cells.sort()
	return ";".join(encoded_cells).sha256_text().left(16)


func _stop_background_gameplay() -> void:
	game.set_process(false)
	game.set_physics_process(false)
	game.enemy_spawn_timer.stop()
	game.state_timer.stop()
	game.player.max_health = 1_000_000
	game.player.current_health = 1_000_000
	game.player.is_dead = false


func _find_wall_fixture(
	profile: GridPathfinder.AgentNavigationProfile
) -> Dictionary:
	var grid := profile.path_grid
	for y in range(grid.region.position.y, grid.region.end.y):
		for x in range(grid.region.position.x, grid.region.end.x):
			var wall_cell := Vector2i(x, y)
			if grid.is_point_solid(wall_cell):
				continue
			for wall_direction in GridPathfinder.FLOW_CARDINAL_DIRECTIONS:
				if not grid.is_in_boundsv(wall_cell + wall_direction):
					continue
				if not grid.is_point_solid(wall_cell + wall_direction):
					continue
				var away := -wall_direction
				for distance in range(8, 17):
					var initial_cell := wall_cell + away * distance
					if not grid.is_in_boundsv(initial_cell):
						continue
					if grid.is_point_solid(initial_cell):
						continue
					var route := grid.get_id_path(initial_cell, wall_cell, false)
					if route.is_empty() or route[route.size() - 1] != wall_cell:
						continue
					return {
						"wall_cell": wall_cell,
						"initial_cell": initial_cell,
						"wall_direction": wall_direction,
					}
	return {}


func _collect_sources(
	profile: GridPathfinder.AgentNavigationProfile,
	wall_cell: Vector2i,
	wall_position: Vector2,
	initial_target_cell: Vector2i
) -> Array[Vector2i]:
	var cells: Array[Vector2i] = []
	var grid := profile.path_grid
	for y in range(grid.region.position.y, grid.region.end.y):
		for x in range(grid.region.position.x, grid.region.end.x):
			var cell := Vector2i(x, y)
			if grid.is_point_solid(cell):
				continue
			var delta := (cell - wall_cell).abs()
			if maxi(delta.x, delta.y) < MIN_SOURCE_DISTANCE_CELLS:
				continue
			var initial_delta := (cell - initial_target_cell).abs()
			if (
				maxi(initial_delta.x, initial_delta.y)
				>= source_collection_radius_cells
			):
				continue
			if Vector2(cell - wall_cell).length_squared() > 16.0 * 16.0:
				continue
			var world_position := pathfinder.call("_map_to_global", cell) as Vector2
			if pathfinder.try_is_navigation_open_plain_with_profile(
				world_position,
				wall_position,
				profile
			) == true:
				continue
			var route := grid.get_id_path(cell, wall_cell, false)
			if route.is_empty() or route[route.size() - 1] != wall_cell:
				continue
			cells.append(cell)
			if cells.size() >= MAX_ENEMIES:
				return cells
	return cells


func _collect_local_goal_region(
	profile: GridPathfinder.AgentNavigationProfile,
	target_cell: Vector2i
) -> Array[Vector2i]:
	var target_position := pathfinder.call("_map_to_global", target_cell) as Vector2
	var goal_cells: Array[Vector2i] = []
	for y in range(target_cell.y - 1, target_cell.y + 2):
		for x in range(target_cell.x - 1, target_cell.x + 2):
			var candidate := Vector2i(x, y)
			if (
				not profile.path_grid.is_in_boundsv(candidate)
				or profile.path_grid.is_point_solid(candidate)
			):
				continue
			var candidate_position := pathfinder.call(
				"_map_to_global",
				candidate
			) as Vector2
			if pathfinder.call(
				"_is_navigation_segment_walkable_with_grid",
				candidate_position,
				target_position,
				profile.normalized_extents,
				profile.traversal_types,
				profile.path_grid,
				profile.solid_integral_snapshot
			):
				goal_cells.append(candidate)
	return goal_cells


func _get_profile_resolution_summary(target_cell: Vector2i) -> Array[String]:
	var summaries: Array[String] = []
	var seen_configs: Dictionary = {}
	for wave_config in game.waves:
		if wave_config == null:
			continue
		for entry in wave_config.enemy_entries:
			if entry == null or entry.enemy_config == null:
				continue
			var enemy_config := entry.enemy_config as EnemyConfig
			if seen_configs.has(enemy_config.resource_path):
				continue
			seen_configs[enemy_config.resource_path] = true
			var probe := enemy_config.enemy_scene.instantiate() as Enemy
			if probe == null:
				continue
			var half_extents := probe.get_configured_body_collision_half_extents()
			probe.free()
			pathfinder.prewarm_agent_grid(
				half_extents,
				enemy_config.terrain_traversal_types
			)
			var other_profile := pathfinder.try_get_agent_navigation_profile(
				half_extents,
				enemy_config.terrain_traversal_types
			)
			if other_profile == null:
				continue
			var resolved := pathfinder.call(
				"_get_closest_walkable_cell",
				target_cell,
				other_profile.path_grid
			) as Vector2i
			summaries.append(
				"%s extents=%s target_solid=%s resolved=%s"
				% [
					enemy_config.resource_path.get_file(),
					str(half_extents.ceil()),
					str(other_profile.path_grid.is_point_solid(target_cell)),
					str(resolved),
				]
			)
	return summaries


func _spawn_enemies(source_cells: Array[Vector2i]) -> void:
	for cell in source_cells:
		var enemy := BASIC_ENEMY_CONFIG.enemy_scene.instantiate() as Enemy
		game.enemy_container.add_child(enemy)
		enemy.setup(BASIC_ENEMY_CONFIG, game.player, pathfinder)
		enemy.set_near_moving_target_direct_distance(
			GameTowerDefense.PLAYER_NEAR_MOVING_DIRECT_DISTANCE
		)
		enemy.global_position = pathfinder.call("_map_to_global", cell) as Vector2
		enemy.navigation_update_interval_frames = 1
		enemy.set_physics_process(false)
		enemies.append(enemy)


func _wait_for_dynamic_ready(enemy: Enemy) -> Dictionary:
	var expansion_sum := 0
	var expansion_peak := 0
	var usec_sum := 0
	var usec_peak := 0
	var expansion_capped_frames := 0
	var deadline_capped_frames := 0
	for frame_index in range(MAX_BUILD_FRAMES):
		var result := GridPathfinder.NavigationStepResult.new()
		var context := GridPathfinder.FlowQueryContext.new()
		pathfinder.try_write_dynamic_target_navigation_step(
			result,
			context,
			enemy.global_position,
			game.player,
			enemy.get_configured_body_collision_half_extents(),
			enemy.terrain_traversal_types,
			enemy.get_dynamic_target_contact_goal_radius(game.player)
		)
		if result.status == GridPathfinder.NavigationStepStatus.READY:
			return {
				"frames": frame_index,
				"expansion_sum": expansion_sum,
				"expansion_peak": expansion_peak,
				"usec_sum": usec_sum,
				"usec_peak": usec_peak,
				"expansion_capped_frames": expansion_capped_frames,
				"deadline_capped_frames": deadline_capped_frames,
			}
		await process_frame
		expansion_sum += pathfinder.runtime_navigation_expansions_last_frame
		expansion_peak = maxi(
			expansion_peak,
			pathfinder.runtime_navigation_expansions_last_frame
		)
		usec_sum += pathfinder.runtime_navigation_build_usec_last_frame
		usec_peak = maxi(usec_peak, pathfinder.runtime_navigation_build_usec_last_frame)
		if (
			pathfinder.runtime_navigation_expansions_last_frame
			>= pathfinder.runtime_navigation_max_expansions_per_frame
		):
			expansion_capped_frames += 1
		if (
			pathfinder.runtime_navigation_build_usec_last_frame
			>= pathfinder.runtime_navigation_time_budget_usec
		):
			deadline_capped_frames += 1
	return {
		"frames": -1,
		"expansion_sum": expansion_sum,
		"expansion_peak": expansion_peak,
		"usec_sum": usec_sum,
		"usec_peak": usec_peak,
		"expansion_capped_frames": expansion_capped_frames,
		"deadline_capped_frames": deadline_capped_frames,
	}


func _sample_enemy_flow_directions() -> Dictionary:
	var stale := 0
	var zero := 0
	var nonzero := 0
	var ready := 0
	var deferred := 0
	var uncertified := 0
	var old_flow_nonzero := 0
	var old_flow_shape_safe := 0
	var far_from_old_anchor := 0
	var outside_old_anchor_influence := 0
	var minimum_remaining := 2147483647
	var maximum_remaining := -1
	var maximum_anchor_lag := 0
	for enemy in enemies:
		enemy.call("_clear_cached_navigation_move_direction")
		var direction := enemy.call(
			"_get_flow_navigation_move_direction",
			game.player,
			pathfinder,
			1.0
		) as Vector2
		if enemy.navigation_step_result != null:
			var anchor_delta := (
				enemy.navigation_step_result.target_cell
				- enemy.navigation_step_result.resolved_target_cell
			).abs()
			var anchor_lag := maxi(anchor_delta.x, anchor_delta.y)
			maximum_anchor_lag = maxi(maximum_anchor_lag, anchor_lag)
			if enemy.navigation_step_result.dynamic_anchor_is_stale:
				stale += 1
			var old_flow_direction := enemy.call(
				"_get_waypoint_move_direction",
				enemy.navigation_step_result.waypoint,
				1.0
			) as Vector2
			if old_flow_direction != Vector2.ZERO:
				old_flow_nonzero += 1
				if enemy.call(
					"_is_navigation_motion_shape_safe",
					old_flow_direction,
					1.0
				):
					old_flow_shape_safe += 1
			if enemy.navigation_step_result.remaining_cell_distance >= 6:
				far_from_old_anchor += 1
			if enemy.navigation_step_result.remaining_cell_distance >= 0:
				minimum_remaining = mini(
					minimum_remaining,
					enemy.navigation_step_result.remaining_cell_distance
				)
				maximum_remaining = maxi(
					maximum_remaining,
					enemy.navigation_step_result.remaining_cell_distance
				)
				if (
					enemy.navigation_step_result.remaining_cell_distance
					> anchor_lag + 2
				):
					outside_old_anchor_influence += 1
			match enemy.navigation_step_result.status:
				GridPathfinder.NavigationStepStatus.READY:
					ready += 1
				GridPathfinder.NavigationStepStatus.DEFERRED:
					deferred += 1
		if enemy.call(
			"_try_get_navigation_open_plain",
			game.player.global_position
		) != true:
			uncertified += 1
		if direction == Vector2.ZERO:
			zero += 1
		else:
			nonzero += 1
	return {
		"stale": stale,
		"zero": zero,
		"nonzero": nonzero,
		"ready": ready,
		"deferred": deferred,
		"uncertified": uncertified,
		"old_flow_nonzero": old_flow_nonzero,
		"old_flow_shape_safe": old_flow_shape_safe,
		"far_from_old_anchor": far_from_old_anchor,
		"outside_old_anchor_influence": outside_old_anchor_influence,
		"minimum_remaining": (
			minimum_remaining if minimum_remaining != 2147483647 else -1
		),
		"maximum_remaining": maximum_remaining,
		"maximum_anchor_lag": maximum_anchor_lag,
	}


func _sample_enemy_safe_directions() -> Dictionary:
	var zero := 0
	var nonzero := 0
	var direct := 0
	var stale := 0
	for enemy in enemies:
		enemy.call("_clear_cached_navigation_move_direction")
		var direction := enemy.call(
			"_get_safe_navigation_move_direction",
			game.player,
			pathfinder,
			1.0
		) as Vector2
		if direction == Vector2.ZERO:
			zero += 1
		else:
			nonzero += 1
		if enemy.cached_navigation_uses_direct_objective_approach:
			direct += 1
		if (
			enemy.navigation_step_result != null
			and enemy.navigation_step_result.dynamic_anchor_is_stale
		):
			stale += 1
	return {
		"zero": zero,
		"nonzero": nonzero,
		"direct": direct,
		"stale": stale,
	}


func _get_only_dynamic_slot() -> GridPathfinder.DynamicFlowTargetSlot:
	if pathfinder.dynamic_flow_target_slots.size() != 1:
		return null
	for value in pathfinder.dynamic_flow_target_slots.values():
		return value as GridPathfinder.DynamicFlowTargetSlot
	return null


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)


func _finish(exit_code: int) -> void:
	if game != null and is_instance_valid(game):
		game.queue_free()
	await process_frame
	await physics_frame
	quit(exit_code)
