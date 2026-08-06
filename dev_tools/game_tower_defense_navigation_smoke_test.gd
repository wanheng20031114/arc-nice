extends SceneTree

const TOWER_SCENE := preload("res://scene/game_modes/tower_defense/tower_defense_game.tscn")
const AGAVE_CONFIG := preload("res://resources/config/plant_defense/agave_cannon.tres")

var failures: Array[String] = []


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	var original_navigation_refresh_budget := (
		Enemy.navigation_process_frame_budget_enabled
	)
	# The route matrix deliberately evaluates every authored spawn/config pair in
	# one synthetic process frame. Keep that exhaustive contract independent from
	# the production frame cap; the dedicated fixture below turns the cap back on.
	Enemy.navigation_process_frame_budget_enabled = false
	var game := TOWER_SCENE.instantiate() as TowerDefenseGame
	game.auto_start_waves = false
	root.add_child(game)
	current_scene = game
	await process_frame
	await physics_frame

	var pathfinder := game.get_node_or_null("GridPathfinder") as GridPathfinder
	_expect(pathfinder != null and pathfinder.is_built, "Tower defense must provide a built GridPathfinder.")
	_expect(game.linglan_boss_enabled, "Tower-defense Linglan must be enabled.")
	_expect(game.bosses.size() == 1, "Tower-defense Campaign must expose the Linglan BossConfig.")
	var spawn_points: Array[Marker2D] = game.enemy_spawn_points
	var targets: Array[Node2D] = []
	if game.player != null:
		targets.append(game.player)
	targets.append_array(game.get_home_objective_targets())
	var enemy_configs := _collect_actual_enemy_configs(game)

	_expect(spawn_points.size() == 6, "Tower defense navigation must validate all six spawn points.")
	_expect(targets.size() == 2, "Tower defense navigation must validate the player and logical Home entrance.")
	_expect(not enemy_configs.is_empty(), "Tower defense campaign must expose actual EnemyConfig resources.")

	if pathfinder != null and pathfinder.is_built and not enemy_configs.is_empty():
		_verify_navigation_phase_distribution(game, enemy_configs[0])
		_verify_navigation_next_refresh_cache(game, pathfinder, enemy_configs[0])
		_verify_same_render_navigation_dedupe(game, pathfinder, enemy_configs[0])
		for enemy_config in enemy_configs:
			_verify_config_navigation_matrix(
				game,
				pathfinder,
				enemy_config,
				spawn_points,
				targets
			)
		_verify_diagonal_flow_and_corner_guards(
			game,
			pathfinder,
			enemy_configs[0]
		)
		_verify_partial_path_is_rejected(pathfinder, enemy_configs[0], spawn_points[0])
		_verify_deferred_does_not_direct_fallback(
			game,
			pathfinder,
			enemy_configs[0],
			spawn_points[0],
			targets[0]
		)
		_verify_far_home_uses_safe_direct_approach(
			game,
			pathfinder,
			enemy_configs[0],
			spawn_points[0],
			targets[1]
		)
		await _verify_near_static_verified_motion_contract(
			game,
			pathfinder,
			enemy_configs[0]
		)
		_verify_near_moving_verified_motion_contract(
			game,
			pathfinder,
			enemy_configs[0]
		)
		await _verify_spawn_recovery_motion(game, pathfinder, enemy_configs)

	Enemy.navigation_process_frame_budget_enabled = original_navigation_refresh_budget
	game.queue_free()
	await process_frame
	await physics_frame

	if failures.is_empty():
		print(
			"GAME_TOWER_DEFENSE_NAVIGATION_SMOKE_TEST_OK configs=%d routes=%d"
			% [enemy_configs.size(), enemy_configs.size() * spawn_points.size() * targets.size()]
		)
		quit()
		return

	for failure in failures:
		push_error(failure)
	quit(1)


func _verify_navigation_phase_distribution(
	game: TowerDefenseGame,
	enemy_config: EnemyConfig
) -> void:
	const SAMPLE_COUNT := 24
	var normal_groups: Array[int] = [0, 0, 0, 0, 0, 0]
	var far_groups: Array[int] = [0, 0, 0, 0, 0, 0, 0, 0]
	var retry_frame_counts: Dictionary[int, int] = {}
	var current_frame := Engine.get_physics_frames()
	var fixtures: Array[Enemy] = []
	for _index in range(SAMPLE_COUNT):
		var enemy := enemy_config.enemy_scene.instantiate() as Enemy
		_expect(enemy != null, "Navigation phase fixture must instantiate every enemy.")
		if enemy == null:
			continue
		game.enemy_container.add_child(enemy)
		enemy.set_physics_process(false)
		fixtures.append(enemy)
		var offset := enemy.navigation_update_frame_offset
		normal_groups[offset % Enemy.DEFAULT_NAVIGATION_UPDATE_INTERVAL_FRAMES] += 1
		far_groups[offset % Enemy.FAR_STATIC_OBJECTIVE_UPDATE_INTERVAL_FRAMES] += 1
		var retry_frame := enemy.navigation_zero_direction_retry_frame
		var next_refresh_frame := enemy.navigation_next_refresh_physics_frame
		retry_frame_counts[retry_frame] = int(
			retry_frame_counts.get(retry_frame, 0)
		) + 1
		_expect(
			retry_frame > current_frame
			and next_refresh_frame == retry_frame
			and retry_frame <= current_frame + Enemy.DEFAULT_NAVIGATION_UPDATE_INTERVAL_FRAMES
			and (
				retry_frame + offset
			) % Enemy.DEFAULT_NAVIGATION_UPDATE_INTERVAL_FRAMES == 0,
			"Initial zero-direction retries must land on the enemy's deterministic navigation phase."
		)

	_expect(
		normal_groups == [4, 4, 4, 4, 4, 4],
		"Twenty-four enemies must split evenly across six 10 Hz navigation groups."
	)
	_expect(
		far_groups == [3, 3, 3, 3, 3, 3, 3, 3],
		"Twenty-four enemies must split evenly across the eight-frame far-objective tier."
	)
	var retries_are_balanced := retry_frame_counts.size() == 6
	for count_variant in retry_frame_counts.values():
		retries_are_balanced = retries_are_balanced and int(count_variant) == 4
	_expect(
		retries_are_balanced,
		"Initial zero-direction retries must be spread evenly over six physics frames."
	)
	for enemy in fixtures:
		enemy.free()


func _verify_navigation_next_refresh_cache(
	game: TowerDefenseGame,
	pathfinder: GridPathfinder,
	enemy_config: EnemyConfig
) -> void:
	var enemy := enemy_config.enemy_scene.instantiate() as Enemy
	_expect(enemy != null, "Next-refresh cache fixture must instantiate an enemy.")
	if enemy == null:
		return
	game.enemy_container.add_child(enemy)
	enemy.set_physics_process(false)
	enemy.setup(enemy_config, game.player, pathfinder)
	enemy.cached_navigation_move_direction = Vector2.RIGHT
	enemy.navigation_zero_direction_retry_frame = 0
	enemy.navigation_next_refresh_physics_frame = Engine.get_physics_frames() + 6
	enemy.navigation_scheduled_refresh_interval_frames = (
		enemy.navigation_update_interval_frames
	)

	var saved_metrics_enabled := Enemy.performance_metrics_enabled
	Enemy.set_performance_metrics_enabled(true)
	var cached_direction := enemy.call(
		"_get_safe_navigation_move_direction",
		game.player,
		pathfinder,
		1.0
	) as Vector2
	var cached_metrics := Enemy.get_performance_metrics()
	_expect(
		cached_direction == Vector2.RIGHT
		and int(cached_metrics.get("navigation_calls", -1)) == 0
		and int(cached_metrics.get("navigation_refresh_calls", -1)) == 0,
		"A future next-refresh frame must return the cached direction before profiling or path work."
	)

	enemy.navigation_refresh_deferred = true
	enemy.last_navigation_update_render_frame = -1
	var deferred_direction := enemy.call(
		"_get_safe_navigation_move_direction",
		null,
		null,
		1.0
	) as Vector2
	var deferred_metrics := Enemy.get_performance_metrics()
	_expect(
		deferred_direction == Vector2.ZERO
		and not enemy.navigation_refresh_deferred
		and int(deferred_metrics.get("navigation_calls", 0)) == 1
		and int(deferred_metrics.get("navigation_refresh_calls", 0)) == 1
		and enemy.navigation_next_refresh_physics_frame > Engine.get_physics_frames()
		and enemy.navigation_zero_direction_retry_frame
			== enemy.navigation_next_refresh_physics_frame,
		"Deferred work must bypass the future cache once, then zero results must schedule a phased retry."
	)

	enemy.set_objective_target(null)
	_expect(
		enemy.navigation_next_refresh_physics_frame == 0
		and enemy.navigation_scheduled_refresh_interval_frames == 0
		and enemy.navigation_zero_direction_retry_frame == 0,
		"Changing the objective must invalidate the next-refresh cache immediately."
	)
	enemy.set_objective_target(game.player)
	enemy.call("_cache_navigation_move_direction", Vector2.RIGHT)
	_expect(
		enemy.navigation_next_refresh_physics_frame > Engine.get_physics_frames(),
		"A non-zero navigation result must schedule its next phased refresh."
	)
	var navigation_calls_before_interval_change := int(
		Enemy.get_performance_metrics().get("navigation_calls", 0)
	)
	enemy.navigation_update_interval_frames = 1
	enemy.last_navigation_update_render_frame = -1
	var saved_refresh_budget := Enemy.navigation_process_frame_budget_enabled
	Enemy.navigation_process_frame_budget_enabled = false
	enemy.call(
		"_get_safe_navigation_move_direction",
		game.player,
		pathfinder,
		1.0
	)
	Enemy.navigation_process_frame_budget_enabled = saved_refresh_budget
	var interval_change_metrics := Enemy.get_performance_metrics()
	_expect(
		int(interval_change_metrics.get("navigation_calls", 0))
			== navigation_calls_before_interval_change + 1
		and enemy.navigation_scheduled_refresh_interval_frames == 1,
		(
			"Changing the runtime navigation interval must invalidate a future deadline "
			+ "and refresh immediately (calls_before=%d calls_after=%d scheduled=%d "
			+ "next=%d physics=%d)."
		) % [
			navigation_calls_before_interval_change,
			int(interval_change_metrics.get("navigation_calls", 0)),
			enemy.navigation_scheduled_refresh_interval_frames,
			enemy.navigation_next_refresh_physics_frame,
			Engine.get_physics_frames(),
		]
	)
	enemy.set_pathfinder(null)
	_expect(
		enemy.navigation_next_refresh_physics_frame == 0,
		"Changing the pathfinder must invalidate the next-refresh cache immediately."
	)
	Enemy.set_performance_metrics_enabled(saved_metrics_enabled)
	enemy.free()


func _verify_same_render_navigation_dedupe(
	game: TowerDefenseGame,
	pathfinder: GridPathfinder,
	enemy_config: EnemyConfig
) -> void:
	var saved_budget_switch := Enemy.navigation_process_frame_budget_enabled
	Enemy.navigation_process_frame_budget_enabled = true
	var enemy := enemy_config.enemy_scene.instantiate() as Enemy
	game.enemy_container.add_child(enemy)
	enemy.set_physics_process(false)
	enemy.setup(enemy_config, game.player, pathfinder)
	enemy.navigation_update_interval_frames = 1
	enemy.cached_navigation_move_direction = Vector2.RIGHT
	enemy.last_navigation_update_render_frame = -1
	pathfinder.agent_navigation_refresh_budget_process_frame = -1
	pathfinder.agent_navigation_refreshes_used_this_frame = 0
	var first_refresh := bool(enemy.call(
		"_should_update_navigation_direction",
		game.player
	))
	var duplicate_refresh := bool(enemy.call(
		"_should_update_navigation_direction",
		game.player
	))
	_expect(
		first_refresh and not duplicate_refresh,
		(
			"One enemy must not perform two expensive navigation refreshes in one "
			+ "render frame (first=%s duplicate=%s render=%d last=%d cached=%s)."
		)
		% [
			first_refresh,
			duplicate_refresh,
			Engine.get_process_frames(),
			enemy.last_navigation_update_render_frame,
			enemy.cached_navigation_move_direction,
		]
	)
	enemy.free()

	var saved_refresh_cap := pathfinder.max_agent_navigation_refreshes_per_process_frame
	pathfinder.max_agent_navigation_refreshes_per_process_frame = 2
	pathfinder.agent_navigation_refresh_budget_process_frame = -1
	pathfinder.agent_navigation_refreshes_used_this_frame = 0
	pathfinder.agent_navigation_refresh_deferred_queue.clear()
	pathfinder.agent_navigation_refresh_deferred_queue_head = 0
	pathfinder.agent_navigation_refresh_deferred_ids.clear()
	pathfinder.agent_navigation_refresh_deferred_since_frame.clear()
	pathfinder.agent_navigation_refresh_last_request_frame.clear()
	pathfinder.agent_navigation_refresh_reserved_order.clear()
	pathfinder.agent_navigation_refresh_reserved_ids.clear()
	pathfinder.agent_navigation_refresh_max_wait_process_frames = 0
	var budget_fixtures: Array[Enemy] = []
	var first_frame_admissions: Array[bool] = []
	for _index in range(4):
		var fixture := enemy_config.enemy_scene.instantiate() as Enemy
		game.enemy_container.add_child(fixture)
		fixture.set_physics_process(false)
		fixture.setup(enemy_config, game.player, pathfinder)
		fixture.navigation_update_interval_frames = 1
		fixture.cached_navigation_move_direction = Vector2.RIGHT
		fixture.last_navigation_update_render_frame = -1
		budget_fixtures.append(fixture)
		first_frame_admissions.append(bool(fixture.call(
			"_should_update_navigation_direction",
			game.player
		)))
	_expect(
		first_frame_admissions == [true, true, false, false]
		and budget_fixtures[2].navigation_refresh_deferred
		and budget_fixtures[3].navigation_refresh_deferred,
		(
			"A process-frame navigation budget must admit only its cap and mark "
			+ "overflow work for next-render retry: %s."
		) % [first_frame_admissions]
	)
	# Emulate entry into the next rendered frame without introducing an unrelated
	# full scene tick into this deterministic contract test. Calling all fixtures
	# in the same stable tree order proves deferred FIFO reservations cannot be
	# stolen by the two agents that were admitted first.
	pathfinder.agent_navigation_refresh_budget_process_frame = -1
	pathfinder.agent_navigation_refreshes_used_this_frame = 0
	var second_frame_admissions: Array[bool] = []
	for fixture in budget_fixtures:
		fixture.last_navigation_update_render_frame = -1
		second_frame_admissions.append(bool(fixture.call(
			"_should_update_navigation_direction",
			game.player
		)))
	_expect(
		second_frame_admissions == [false, false, true, true]
		and not budget_fixtures[2].navigation_refresh_deferred
		and not budget_fixtures[3].navigation_refresh_deferred,
		(
			"Deferred FIFO reservations must rotate the grant to later tree-order "
			+ "agents on the next render frame: %s."
		) % [second_frame_admissions]
	)
	pathfinder.agent_navigation_refresh_budget_process_frame = -1
	pathfinder.agent_navigation_refreshes_used_this_frame = 0
	var third_frame_admissions: Array[bool] = []
	for fixture in budget_fixtures:
		fixture.last_navigation_update_render_frame = -1
		third_frame_admissions.append(bool(fixture.call(
			"_should_update_navigation_direction",
			game.player
		)))
	_expect(
		third_frame_admissions == [true, true, false, false]
		and pathfinder.agent_navigation_refresh_max_wait_process_frames <= 1,
		(
			"FIFO navigation grants must remain fair in a sustained overload "
			+ "(third=%s max_wait=%d)."
		) % [
			third_frame_admissions,
			pathfinder.agent_navigation_refresh_max_wait_process_frames,
		]
	)
	for fixture in budget_fixtures:
		fixture.free()
	pathfinder.max_agent_navigation_refreshes_per_process_frame = saved_refresh_cap
	pathfinder.agent_navigation_refresh_budget_process_frame = -1
	pathfinder.agent_navigation_refreshes_used_this_frame = 0
	pathfinder.agent_navigation_refresh_deferred_queue.clear()
	pathfinder.agent_navigation_refresh_deferred_queue_head = 0
	pathfinder.agent_navigation_refresh_deferred_ids.clear()
	pathfinder.agent_navigation_refresh_deferred_since_frame.clear()
	pathfinder.agent_navigation_refresh_last_request_frame.clear()
	pathfinder.agent_navigation_refresh_reserved_order.clear()
	pathfinder.agent_navigation_refresh_reserved_ids.clear()
	Enemy.navigation_process_frame_budget_enabled = saved_budget_switch


func _collect_actual_enemy_configs(game: TowerDefenseGame) -> Array[EnemyConfig]:
	var configs: Array[EnemyConfig] = []
	var seen_paths: Dictionary = {}
	for wave_config in game.waves:
		if wave_config == null:
			continue
		for entry in wave_config.enemy_entries:
			if entry == null or entry.enemy_config == null:
				continue
			_append_unique_enemy_config(configs, seen_paths, entry.enemy_config)
	return configs


func _append_unique_enemy_config(
	configs: Array[EnemyConfig],
	seen_paths: Dictionary,
	enemy_config: EnemyConfig
) -> void:
	var config_key := enemy_config.resource_path
	if config_key.is_empty():
		config_key = "instance:%d" % enemy_config.get_instance_id()
	if seen_paths.has(config_key):
		return
	seen_paths[config_key] = true
	configs.append(enemy_config)


func _verify_config_navigation_matrix(
	game: TowerDefenseGame,
	pathfinder: GridPathfinder,
	enemy_config: EnemyConfig,
	spawn_points: Array[Marker2D],
	targets: Array[Node2D]
) -> void:
	var probe_enemy := enemy_config.enemy_scene.instantiate() as Enemy
	_expect(probe_enemy != null, "%s must instantiate Enemy." % enemy_config.display_name)
	if probe_enemy == null:
		return
	var half_extents := probe_enemy.get_configured_body_collision_half_extents()
	var uses_shared_chase_consumer := probe_enemy.has_method("_get_navigation_move_direction")
	probe_enemy.free()
	var agent_grid := pathfinder.call(
		"_get_or_create_agent_grid",
		half_extents,
		enemy_config.terrain_traversal_types
	) as AStarGrid2D

	for spawn_point in spawn_points:
		for target in targets:
			var route_label := "%s %s->%s" % [
				enemy_config.display_name,
				spawn_point.name,
				target.name,
			]
			var step := pathfinder.get_safe_navigation_step(
				spawn_point.global_position,
				target.global_position,
				half_extents,
				enemy_config.terrain_traversal_types
			)
			var fast_result := GridPathfinder.NavigationStepResult.new()
			var fast_context := GridPathfinder.FlowQueryContext.new()
			pathfinder.write_safe_navigation_step(
				fast_result,
				fast_context,
				spawn_point.global_position,
				target.global_position,
				half_extents,
				enemy_config.terrain_traversal_types,
				target != game.player
			)
			_expect_navigation_step_equivalent(step, fast_result, route_label)
			var status := int(step.get("status", GridPathfinder.NavigationStepStatus.UNREACHABLE))
			var safe_step_ready := (
				status == GridPathfinder.NavigationStepStatus.READY
				or status == GridPathfinder.NavigationStepStatus.ARRIVED
			)
			if uses_shared_chase_consumer:
				_expect(
					safe_step_ready,
					"%s shared chase must return READY/ARRIVED, got %s."
					% [route_label, _status_name(status)]
				)
			else:
				_expect(
					safe_step_ready or status == GridPathfinder.NavigationStepStatus.UNREACHABLE,
					"%s special-movement enemy must return an explicit terminal status." % route_label
				)
			if safe_step_ready:
				_expect(bool(step.get("is_complete_route", false)), "%s safe step must have a complete route." % route_label)

			var from_cell: Vector2i = step.get("from_cell", Vector2i.MAX)
			var resolved_from_cell: Vector2i = step.get("resolved_from_cell", Vector2i.MAX)
			var resolved_target_cell: Vector2i = step.get("resolved_target_cell", Vector2i.MAX)
			if safe_step_ready:
				_expect(resolved_from_cell != Vector2i.MAX, "%s must resolve its start cell." % route_label)
			_expect(resolved_target_cell != Vector2i.MAX, "%s must resolve its target cell." % route_label)
			if bool(step.get("used_start_recovery", false)):
				var recovery_first_step: Vector2i = step.get("next_cell", Vector2i.MAX)
				var recovery_delta := recovery_first_step - from_cell
				_expect(
					resolved_from_cell != from_cell
					and _chebyshev_distance(from_cell, resolved_from_cell)
						<= pathfinder.max_nearest_cell_search_radius
					and _chebyshev_distance(from_cell, recovery_first_step) == 1
					and bool(pathfinder.call(
						"_is_raw_recovery_transition_safe",
						from_cell,
						recovery_delta,
						enemy_config.terrain_traversal_types
					)),
					"%s recovery must use one bounded raw-terrain-safe step, got %s->%s (resolved %s)."
					% [route_label, from_cell, recovery_first_step, resolved_from_cell]
				)

			var next_cell: Vector2i = step.get("next_cell", Vector2i.MAX)
			if (
				status == GridPathfinder.NavigationStepStatus.READY
				and next_cell != Vector2i.MAX
				and not bool(step.get("used_start_recovery", false))
			):
				var next_delta := next_cell - resolved_from_cell
				_expect(
					_chebyshev_distance(resolved_from_cell, next_cell) <= 1,
					"%s next cell must be current or one eight-way neighbor." % route_label
				)
				if next_delta.x != 0 and next_delta.y != 0:
					_expect(
						bool(pathfinder.call(
							"_is_safe_flow_transition",
							resolved_from_cell,
							next_delta,
							agent_grid
						)),
						"%s diagonal step must not cut an obstacle corner." % route_label
					)

			var complete_path := pathfinder.get_complete_global_path(
				spawn_point.global_position,
				target.global_position,
				half_extents,
				enemy_config.terrain_traversal_types
			)
			_expect(not complete_path.is_empty(), "%s must expose a non-empty complete path." % route_label)
			if not complete_path.is_empty():
				var endpoint_cell := pathfinder.call("_global_to_map", complete_path[-1]) as Vector2i
				_expect(
					endpoint_cell == resolved_target_cell,
					"%s complete path must end at resolved target %s, got %s."
					% [route_label, resolved_target_cell, endpoint_cell]
				)

	_verify_enemy_consumer_for_config(game, pathfinder, enemy_config, spawn_points, targets[1])


func _verify_enemy_consumer_for_config(
	game: TowerDefenseGame,
	pathfinder: GridPathfinder,
	enemy_config: EnemyConfig,
	spawn_points: Array[Marker2D],
	objective: Node2D
) -> void:
	for spawn_point in spawn_points:
		var enemy := enemy_config.enemy_scene.instantiate() as Enemy
		if enemy == null:
			continue
		game.enemy_container.add_child(enemy)
		enemy.global_position = spawn_point.global_position
		enemy.setup(enemy_config, game.player, pathfinder)
		enemy.set_objective_target(objective)
		enemy.navigation_update_interval_frames = 1
		enemy.set_physics_process(false)
		if not enemy.has_method("_get_navigation_move_direction"):
			enemy.free()
			continue
		var move_direction := enemy.call("_get_navigation_move_direction", 1.0 / 60.0) as Vector2
		_expect(
			move_direction != Vector2.ZERO,
			"%s consumer must produce movement from %s." % [enemy_config.display_name, spawn_point.name]
		)
		if move_direction != Vector2.ZERO:
			_expect(
				not enemy.test_move(enemy.global_transform, move_direction),
				"%s consumer must not return a direction that immediately crosses collision at %s."
				% [enemy_config.display_name, spawn_point.name]
			)
		enemy.free()


func _verify_diagonal_flow_and_corner_guards(
	game: TowerDefenseGame,
	pathfinder: GridPathfinder,
	enemy_config: EnemyConfig
) -> void:
	var probe_enemy := enemy_config.enemy_scene.instantiate() as Enemy
	if probe_enemy == null:
		return
	var half_extents := probe_enemy.get_configured_body_collision_half_extents()
	probe_enemy.free()
	var agent_grid := pathfinder.call(
		"_get_or_create_agent_grid",
		half_extents,
		enemy_config.terrain_traversal_types
	) as AStarGrid2D
	var source_cell := Vector2i.MAX
	var target_cell := Vector2i.MAX
	var diagonal_direction := Vector2i(1, 1)
	for y in range(agent_grid.region.position.y + 1, agent_grid.region.end.y - 1):
		for x in range(agent_grid.region.position.x + 1, agent_grid.region.end.x - 1):
			var candidate_source := Vector2i(x, y)
			if bool(pathfinder.call(
				"_is_safe_flow_transition",
				candidate_source,
				diagonal_direction,
				agent_grid
			)):
				source_cell = candidate_source
				target_cell = candidate_source + diagonal_direction
				break
		if source_cell != Vector2i.MAX:
			break
	_expect(source_cell != Vector2i.MAX, "Diagonal flow test must find an open 2x2 agent-grid area.")
	if source_cell == Vector2i.MAX:
		return
	_expect(
		bool(pathfinder.call(
			"_is_safe_flow_transition",
			target_cell,
			-diagonal_direction,
			agent_grid
		)),
		"The reverse flow-field expansion must accept the same unobstructed diagonal."
	)

	var open_field := pathfinder.call(
		"_build_flow_field",
		target_cell,
		agent_grid
	) as Dictionary
	var open_next_cells := open_field.get("next_cells", {}) as Dictionary
	var open_distances := open_field.get("distances", {}) as Dictionary
	_expect(
		open_next_cells.get(source_cell, Vector2i.MAX) == target_cell,
		"An unobstructed diagonal must be the next shared-flow step, got %s->%s (target %s, field=%d, target_next=%s)."
		% [
			source_cell,
			open_next_cells.get(source_cell, Vector2i.MAX),
			target_cell,
			open_next_cells.size(),
			open_next_cells.get(target_cell, Vector2i.MAX),
		]
	)
	_expect(
		int(open_distances.get(source_cell, -1)) == GridPathfinder.FLOW_DIAGONAL_COST,
		"One diagonal flow step must use the authored Octile cost, got %s."
		% open_distances.get(source_cell, -1)
	)

	var blocked_side_cell := source_cell + Vector2i.RIGHT
	var blocked_side_was_solid := agent_grid.is_point_solid(blocked_side_cell)
	agent_grid.set_point_solid(blocked_side_cell, true)
	var guarded_field := pathfinder.call(
		"_build_flow_field",
		target_cell,
		agent_grid
	) as Dictionary
	var guarded_next_cells := guarded_field.get("next_cells", {}) as Dictionary
	_expect(
		guarded_next_cells.get(source_cell, Vector2i.MAX) != target_cell,
		"A diagonal must be rejected when either orthogonal side cell is blocked."
	)
	agent_grid.set_point_solid(blocked_side_cell, blocked_side_was_solid)
	pathfinder.flow_field_cache.clear()
	pathfinder.flow_field_cache_order.clear()

	var objective := Node2D.new()
	game.add_child(objective)
	objective.global_position = pathfinder.call("_map_to_global", target_cell) as Vector2
	var moving_enemy := enemy_config.enemy_scene.instantiate() as Enemy
	if moving_enemy != null and moving_enemy.has_method("_get_navigation_move_direction"):
		game.enemy_container.add_child(moving_enemy)
		moving_enemy.global_position = pathfinder.call("_map_to_global", source_cell) as Vector2
		moving_enemy.setup(enemy_config, game.player, pathfinder)
		moving_enemy.set_objective_target(objective)
		moving_enemy.navigation_update_interval_frames = 1
		moving_enemy.set_physics_process(false)
		# This assertion validates diagonal consumption, not runtime cold-build
		# scheduling. Runtime try_* misses are intentionally staged now.
		pathfinder.prewarm_flow_navigation_target(
			objective.global_position,
			moving_enemy.get_configured_body_collision_half_extents(),
			enemy_config.terrain_traversal_types
		)
		var move_direction := moving_enemy.call(
			"_get_flow_navigation_move_direction",
			objective,
			pathfinder,
			0.0
		) as Vector2
		_expect(
			not is_zero_approx(move_direction.x)
			and not is_zero_approx(move_direction.y)
			and is_equal_approx(move_direction.length(), 1.0),
			"The enemy flow consumer must preserve a normalized diagonal waypoint."
		)
		moving_enemy.free()
	objective.free()


func _verify_deferred_does_not_direct_fallback(
	game: TowerDefenseGame,
	pathfinder: GridPathfinder,
	enemy_config: EnemyConfig,
	spawn_point: Marker2D,
	objective: Node2D
) -> void:
	var enemy := enemy_config.enemy_scene.instantiate() as Enemy
	if enemy == null or not enemy.has_method("_get_navigation_move_direction"):
		if enemy != null:
			enemy.free()
		return
	game.enemy_container.add_child(enemy)
	if enemy == null:
		return
	enemy.global_position = spawn_point.global_position
	enemy.setup(enemy_config, game.player, pathfinder)
	enemy.set_objective_target(objective)
	enemy.navigation_update_interval_frames = 1
	enemy.set_physics_process(false)
	enemy.call("_clear_navigation_path")

	pathfinder.flow_field_cache.clear()
	pathfinder.flow_field_cache_order.clear()
	pathfinder.flow_field_budget_frame = Engine.get_process_frames()
	pathfinder.flow_field_builds_used_this_frame = maxi(
		pathfinder.max_flow_field_builds_per_physics_frame,
		1
	)
	var deferred_step := pathfinder.try_get_safe_navigation_step(
		enemy.global_position,
		objective.global_position,
		enemy.get_configured_body_collision_half_extents(),
		enemy_config.terrain_traversal_types
	)
	var fast_deferred_result := GridPathfinder.NavigationStepResult.new()
	var fast_deferred_context := GridPathfinder.FlowQueryContext.new()
	pathfinder.try_write_safe_navigation_step(
		fast_deferred_result,
		fast_deferred_context,
		enemy.global_position,
		objective.global_position,
		enemy.get_configured_body_collision_half_extents(),
		enemy_config.terrain_traversal_types,
		true
	)
	_expect(
		int(deferred_step.get("status", -1)) == GridPathfinder.NavigationStepStatus.DEFERRED,
		"Exhausted flow build budget must produce explicit DEFERRED status."
	)
	_expect_navigation_step_equivalent(
		deferred_step,
		fast_deferred_result,
		"Exhausted flow build budget"
	)
	var move_direction := enemy.call("_get_navigation_move_direction", 1.0 / 60.0) as Vector2
	_expect(
		move_direction == Vector2.ZERO,
		"DEFERRED with no previously verified step must stop instead of direct-fallback chasing."
	)
	_expect(
		not bool(enemy.call("_should_update_navigation_direction", objective)),
		"A zero/deferred navigation result must wait for its next query interval instead of retrying every frame."
	)
	pathfinder.flow_field_budget_frame = -1
	pathfinder.flow_field_builds_used_this_frame = 0
	pathfinder.flow_field_cache.clear()
	pathfinder.flow_field_cache_order.clear()
	enemy.free()


func _verify_far_home_uses_safe_direct_approach(
	game: TowerDefenseGame,
	pathfinder: GridPathfinder,
	enemy_config: EnemyConfig,
	spawn_point: Marker2D,
	objective: Node2D
) -> void:
	var enemy := enemy_config.enemy_scene.instantiate() as Enemy
	if enemy == null or not enemy.has_method("_get_navigation_move_direction"):
		if enemy != null:
			enemy.free()
		return
	game.enemy_container.add_child(enemy)
	enemy.global_position = spawn_point.global_position
	enemy.setup(enemy_config, game.player, pathfinder)
	enemy.set_objective_target(objective)
	enemy.set_physics_process(false)
	enemy.call("_clear_navigation_path")

	_expect(
		enemy.global_position.distance_to(objective.global_position)
		>= Enemy.FAR_STATIC_OBJECTIVE_DISTANCE,
		"Far-Home navigation probe must begin beyond the direct-approach threshold."
	)
	pathfinder.flow_field_cache.clear()
	pathfinder.flow_field_cache_order.clear()
	pathfinder.flow_field_budget_frame = Engine.get_process_frames()
	pathfinder.flow_field_builds_used_this_frame = maxi(
		pathfinder.max_flow_field_builds_per_physics_frame,
		1
	)
	# Earlier contract checks intentionally consume many short-segment fallbacks
	# in one synthetic render frame. This fixture verifies the far-direct tier,
	# so give it a fresh production-sized exact budget.
	pathfinder.exact_segment_budget_process_frame = Engine.get_process_frames()
	pathfinder.exact_segment_fallbacks_used_this_frame = 0
	pathfinder.exact_segment_fallback_usec_used_this_frame = 0
	var segment_queries_before := pathfinder.segment_queries_total
	var move_direction := enemy.call("_get_navigation_move_direction", 1.0 / 60.0) as Vector2
	_expect(
		move_direction != Vector2.ZERO and enemy.cached_navigation_uses_direct_objective_approach,
		"A distant static Home target must use the cheap direct-approach tier before flow lookup."
	)
	_expect(
		pathfinder.segment_queries_total == segment_queries_before + 1,
		"Far direct approach must certify only its current short probe segment."
	)
	if move_direction != Vector2.ZERO:
		_expect(
			move_direction.is_equal_approx(
				enemy.global_position.direction_to(objective.global_position)
			),
			"The far direct-approach tier must preserve the true normalized objective direction."
		)
		var probe_distance := float(enemy.call("_get_far_direct_objective_probe_distance"))
		var minimum_interval_distance := (
			enemy.get_effective_move_speed()
			* float(Enemy.FAR_STATIC_OBJECTIVE_UPDATE_INTERVAL_FRAMES)
			/ float(maxi(Engine.physics_ticks_per_second, 1))
		)
		_expect(
			probe_distance > minimum_interval_distance,
			"Far direct movement must sweep beyond its complete low-frequency travel interval."
		)
		_expect(
			not enemy.test_move(
				enemy.global_transform,
				move_direction * probe_distance
			),
			"The far direct-approach tier must collision-test its complete travel interval."
		)
		var position_before_linear_step := enemy.global_position
		enemy.velocity = move_direction * enemy.get_effective_move_speed()
		enemy.call("_move_until_player_contact")
		_expect(
			enemy.global_position.distance_to(position_before_linear_step) > 0.0,
			"A verified far-Home route must use lightweight linear movement."
		)
		_expect(
			bool(enemy.call(
				"_can_use_verified_static_objective_linear_movement",
				enemy.velocity * enemy.get_physics_process_delta_time()
			)),
			"The lightweight movement tier must retain enough collision-tested clearance for the next static-objective step."
		)
	_expect(
		int(enemy.call("_get_navigation_update_interval_frames", objective))
		>= Enemy.FAR_STATIC_OBJECTIVE_UPDATE_INTERVAL_FRAMES,
		"Distant static Home targets must use the lower-frequency navigation tier."
	)

	pathfinder.flow_field_budget_frame = -1
	pathfinder.flow_field_builds_used_this_frame = 0
	pathfinder.flow_field_cache.clear()
	pathfinder.flow_field_cache_order.clear()
	enemy.free()


func _verify_near_static_verified_motion_contract(
	game: TowerDefenseGame,
	pathfinder: GridPathfinder,
	enemy_config: EnemyConfig
) -> void:
	game.set_physics_process(false)
	var enemy := enemy_config.enemy_scene.instantiate() as Enemy
	_expect(enemy != null, "Near-static verified-motion fixture must instantiate an enemy.")
	if enemy == null:
		return
	game.enemy_container.add_child(enemy)
	enemy.setup(enemy_config, game.player, pathfinder)
	enemy.set_physics_process(false)
	var fixture := _find_open_near_static_fixture(
		pathfinder,
		enemy.get_configured_body_collision_half_extents(),
		enemy_config.terrain_traversal_types,
		game.player.global_position
	)
	_expect(
		fixture.size() == 2,
		"Near-static verified-motion test must find a collision-free open corridor."
	)
	if fixture.size() != 2:
		enemy.free()
		return

	var objective := Node2D.new()
	game.add_child(objective)
	objective.global_position = fixture[1]
	enemy.global_position = fixture[0]
	enemy.set_objective_target(objective)
	enemy.call("_clear_navigation_path")
	var direct_direction := enemy.call(
		"_get_navigation_move_direction",
		1.0 / float(maxi(Engine.physics_ticks_per_second, 1))
	) as Vector2
	_expect(
		direct_direction != Vector2.ZERO
		and enemy.cached_navigation_uses_direct_objective_approach,
		"A shape-swept near static corridor must opt into verified lightweight movement."
	)
	var clearance_before := enemy.cached_navigation_verified_direct_motion_clearance
	enemy.velocity = direct_direction * enemy.get_effective_move_speed()
	var verified_motion := enemy.velocity * enemy.get_physics_process_delta_time()
	_expect(
		bool(enemy.call(
			"_can_use_verified_static_objective_linear_movement",
			verified_motion
		)),
		"A normal physics step inside the exact swept clearance must be eligible for direct movement."
	)
	var position_before := enemy.global_position
	enemy.call("_move_until_player_contact")
	_expect(
		enemy.global_position.is_equal_approx(position_before + verified_motion),
		"Verified near-static movement must preserve the authored velocity and physics delta."
	)
	_expect(
		is_equal_approx(
			enemy.cached_navigation_verified_direct_motion_clearance,
			clearance_before - verified_motion.length()
		),
		"Each lightweight step must consume exactly its collision-tested clearance."
	)
	_expect(
		not bool(enemy.call(
			"_can_use_verified_static_objective_linear_movement",
			direct_direction * (clearance_before + 1.0)
		)),
		"A lag-sized step beyond the verified clearance must fall back to CharacterBody movement."
	)
	var physics_delta := maxf(enemy.get_physics_process_delta_time(), 0.0001)
	var fallback_motion := direct_direction * (
		enemy.cached_navigation_verified_direct_motion_clearance + 1.0
	)
	enemy.velocity = fallback_motion / physics_delta
	var fallback_position_before := enemy.global_position
	enemy.call("_move_until_player_contact")
	_expect(
		enemy.global_position.distance_to(fallback_position_before) > 0.0,
		"An oversized open-corridor frame must exercise CharacterBody fallback movement."
	)
	_expect(
		not enemy.cached_navigation_uses_direct_objective_approach
		and is_zero_approx(
			enemy.cached_navigation_verified_direct_motion_clearance
		),
		"CharacterBody fallback must invalidate the origin-bound direct-motion certificate."
	)
	enemy.velocity = direct_direction * enemy.get_effective_move_speed()
	var next_frame_motion := enemy.velocity * physics_delta
	_expect(
		not bool(enemy.call(
			"_can_use_verified_static_objective_linear_movement",
			next_frame_motion
		)),
		"The frame after fallback must not reuse clearance certified from the old origin."
	)
	enemy.call("_move_until_player_contact")
	_expect(
		not enemy.cached_navigation_uses_direct_objective_approach
		and is_zero_approx(
			enemy.cached_navigation_verified_direct_motion_clearance
		),
		"Fallback movement must remain in CharacterBody mode until navigation revalidates."
	)
	# Even a stale direct certificate must never bypass CharacterBody movement for
	# the moving player target; that path retains its existing contact semantics.
	enemy.cached_navigation_uses_direct_objective_approach = true
	enemy.cached_navigation_verified_direct_motion_clearance = (
		next_frame_motion.length() + 1.0
	)
	enemy.objective_target = game.player
	_expect(
		not bool(enemy.call(
			"_can_use_verified_static_objective_linear_movement",
			verified_motion
		)),
		"Verified lightweight movement must remain unavailable for the player objective."
	)
	enemy.set_objective_target(objective)

	var wall := _spawn_navigation_blocker(
		game,
		fixture[0],
		fixture[1],
		1
	)
	await physics_frame
	await _verify_blocker_rejects_lightweight_motion(
		enemy,
		objective,
		fixture[0],
		"World wall"
	)
	wall.queue_free()
	await physics_frame

	if (enemy.collision_mask & Enemy.WATER_TERRAIN_COLLISION_LAYER) != 0:
		var water := _spawn_navigation_blocker(
			game,
			fixture[0],
			fixture[1],
			Enemy.WATER_TERRAIN_COLLISION_LAYER
		)
		await physics_frame
		await _verify_blocker_rejects_lightweight_motion(
			enemy,
			objective,
			fixture[0],
			"Water terrain"
		)
		water.queue_free()
		await physics_frame

	enemy.free()
	objective.free()
	await _verify_near_static_plant_contact_still_stops(
		game,
		pathfinder,
		enemy_config,
		fixture
	)


func _verify_near_moving_verified_motion_contract(
	game: TowerDefenseGame,
	pathfinder: GridPathfinder,
	enemy_config: EnemyConfig
) -> void:
	var player := game.player
	_expect(player != null, "Near-moving verified-motion fixture requires the player.")
	if player == null:
		return

	var enemy := enemy_config.enemy_scene.instantiate() as Enemy
	_expect(enemy != null, "Near-moving verified-motion fixture must instantiate an enemy.")
	if enemy == null:
		return
	game.enemy_container.add_child(enemy)
	enemy.setup(enemy_config, player, pathfinder)
	enemy.set_physics_process(false)
	var fixture := _find_open_near_static_fixture(
		pathfinder,
		enemy.get_configured_body_collision_half_extents(),
		enemy_config.terrain_traversal_types,
		player.global_position
	)
	_expect(
		fixture.size() == 2,
		"Near-moving verified-motion test must find a collision-free open corridor."
	)
	if fixture.size() != 2:
		enemy.free()
		return

	var saved_player_position := player.global_position
	var saved_player_physics := player.is_physics_processing()
	player.set_physics_process(false)
	player.global_position = fixture[1]
	enemy.global_position = fixture[0]
	enemy.set_near_moving_target_direct_distance(
		fixture[0].distance_to(fixture[1]) + 16.0
	)
	enemy.set_objective_target(player)
	enemy.call("_clear_navigation_path")
	var direct_direction := enemy.call(
		"_get_navigation_move_direction",
		1.0 / float(maxi(Engine.physics_ticks_per_second, 1))
	) as Vector2
	_expect(
		direct_direction != Vector2.ZERO
		and enemy.cached_navigation_uses_direct_objective_approach,
		"An open swept corridor to the moving player must create a direct-motion certificate."
	)
	_expect(
		enemy.navigation_update_interval_frames
			== Enemy.DEFAULT_NAVIGATION_UPDATE_INTERVAL_FRAMES,
		"Normal enemies must stagger navigation direction updates across six 10 Hz groups."
	)

	enemy.velocity = direct_direction * enemy.get_effective_move_speed()
	var verified_motion := enemy.velocity * enemy.get_physics_process_delta_time()
	_expect(
		bool(enemy.call(
			"_can_use_verified_direct_objective_linear_movement",
			verified_motion
		)),
		"A moving-player step inside its exact swept clearance must use lightweight movement."
	)
	_expect(
		not bool(enemy.call(
			"_can_use_verified_static_objective_linear_movement",
			verified_motion
		)),
		"The compatibility predicate must remain restricted to static objectives."
	)
	_expect(
		not bool(enemy.call(
			"_can_use_verified_direct_objective_linear_movement",
			direct_direction.rotated(PI * 0.5) * verified_motion.length()
		)),
		"A direct-motion certificate must reject movement outside its swept direction."
	)
	var position_before := enemy.global_position
	var clearance_before := enemy.cached_navigation_verified_direct_motion_clearance
	enemy.call("_move_until_player_contact")
	_expect(
		enemy.global_position.is_equal_approx(position_before + verified_motion),
		"Verified moving-player movement must preserve the authored velocity and physics delta."
	)
	_expect(
		is_equal_approx(
			enemy.cached_navigation_verified_direct_motion_clearance,
			clearance_before - verified_motion.length()
		),
		"Moving-player lightweight movement must consume its swept clearance exactly once."
	)

	var valid_generation := enemy.cached_navigation_generation
	enemy.cached_navigation_generation = valid_generation - 1
	_expect(
		not bool(enemy.call(
			"_can_use_verified_direct_objective_linear_movement",
			verified_motion
		)),
		"A navigation rebuild must invalidate moving-player direct-motion certificates."
	)
	enemy.cached_navigation_generation = valid_generation
	player.global_position = enemy.global_position - direct_direction * 32.0
	_expect(
		not bool(enemy.call(
			"_can_use_verified_direct_objective_linear_movement",
			verified_motion
		)),
		"A player crossing behind the cached direction must force navigation revalidation."
	)
	var crossed_position_before := enemy.global_position
	enemy.velocity = direct_direction * enemy.get_effective_move_speed()
	enemy.call("_move_until_player_contact")
	_expect(
		enemy.global_position.is_equal_approx(crossed_position_before)
		and enemy.velocity == Vector2.ZERO
		and enemy.cached_navigation_move_direction == Vector2.ZERO
		and bool(enemy.call("_should_update_navigation_direction", player)),
		"A live target crossing behind must stop this tick and force the next navigation update."
	)

	player.global_position = saved_player_position
	player.set_physics_process(saved_player_physics)
	enemy.free()


func _find_open_near_static_fixture(
	pathfinder: GridPathfinder,
	half_extents: Vector2,
	traversal_types: int,
	avoid_position: Vector2
) -> PackedVector2Array:
	var agent_grid := pathfinder.call(
		"_get_or_create_agent_grid",
		half_extents,
		traversal_types
	) as AStarGrid2D
	var candidate_offsets: Array[Vector2i] = [
		Vector2i(4, 0),
		Vector2i(-4, 0),
		Vector2i(0, 4),
		Vector2i(0, -4),
	]
	for y in range(agent_grid.region.position.y + 2, agent_grid.region.end.y - 2):
		for x in range(agent_grid.region.position.x + 2, agent_grid.region.end.x - 2):
			var from_cell := Vector2i(x, y)
			if agent_grid.is_point_solid(from_cell):
				continue
			var from_global := pathfinder.call("_map_to_global", from_cell) as Vector2
			if from_global.distance_to(avoid_position) < 192.0:
				continue
			for offset in candidate_offsets:
				var to_cell := from_cell + offset
				if not agent_grid.is_in_boundsv(to_cell) or agent_grid.is_point_solid(to_cell):
					continue
				var to_global := pathfinder.call("_map_to_global", to_cell) as Vector2
				if pathfinder.try_is_navigation_open_plain(
					from_global,
					to_global,
					half_extents,
					traversal_types
				) == true:
					return PackedVector2Array([from_global, to_global])
	return PackedVector2Array()


func _spawn_navigation_blocker(
	game: TowerDefenseGame,
	from_position: Vector2,
	to_position: Vector2,
	collision_layer: int
) -> StaticBody2D:
	var body := StaticBody2D.new()
	body.collision_layer = collision_layer
	body.collision_mask = 0
	var shape_node := CollisionShape2D.new()
	var shape := RectangleShape2D.new()
	var direction := from_position.direction_to(to_position)
	shape.size = (
		Vector2(8.0, 256.0)
		if absf(direction.x) >= absf(direction.y)
		else Vector2(256.0, 8.0)
	)
	shape_node.shape = shape
	body.add_child(shape_node)
	game.add_child(body)
	body.global_position = from_position.lerp(to_position, 0.5)
	return body


func _verify_blocker_rejects_lightweight_motion(
	enemy: Enemy,
	objective: Node2D,
	start_position: Vector2,
	label: String
) -> void:
	enemy.global_position = start_position
	enemy.velocity = Vector2.ZERO
	enemy.set_objective_target(objective)
	enemy.call("_clear_navigation_path")
	var saw_physics_fallback := false
	var path_direction := start_position.direction_to(objective.global_position)
	var blocker_progress := start_position.distance_to(objective.global_position) * 0.5
	var maximum_progress := 0.0
	for _frame in range(180):
		await physics_frame
		var move_direction := enemy.call(
			"_get_navigation_move_direction",
			1.0 / float(maxi(Engine.physics_ticks_per_second, 1))
		) as Vector2
		enemy.velocity = move_direction * enemy.get_effective_move_speed()
		saw_physics_fallback = (
			saw_physics_fallback
			or not enemy.cached_navigation_uses_direct_objective_approach
		)
		enemy.call("_move_until_player_contact")
		maximum_progress = maxf(
			maximum_progress,
			(enemy.global_position - start_position).dot(path_direction)
		)
	_expect(
		saw_physics_fallback,
		"%s must invalidate lightweight motion before a body reaches it." % label
	)
	_expect(
		maximum_progress < blocker_progress,
		"%s must remain physically uncrossable during verified/static fallback movement." % label
	)


func _verify_near_static_plant_contact_still_stops(
	game: TowerDefenseGame,
	pathfinder: GridPathfinder,
	enemy_config: EnemyConfig,
	fixture: PackedVector2Array
) -> void:
	game.set_physics_process(false)
	var plant := AGAVE_CONFIG.plant_scene.instantiate() as PlantDefense
	var enemy := enemy_config.enemy_scene.instantiate() as Enemy
	_expect(
		plant != null and enemy != null,
		"Near-static contact fixture must instantiate its real plant and enemy."
	)
	if plant == null or enemy == null:
		if plant != null:
			plant.free()
		if enemy != null:
			enemy.free()
		return
	game.plant_container.add_child(plant)
	plant.global_position = fixture[1]
	plant.setup(AGAVE_CONFIG, game.player, [])
	var attack_timer := plant.get_node_or_null("AttackTimer") as Timer
	if attack_timer != null:
		attack_timer.stop()
	game.enemy_container.add_child(enemy)
	enemy.global_position = fixture[0]
	enemy.setup(enemy_config, game.player, pathfinder)
	enemy.current_health = 1_000_000
	enemy.set_objective_target(plant)
	enemy.call("_clear_navigation_path")
	var initial_health := plant.current_health
	var saw_verified_motion := false
	var reached_stable_contact := false
	for _frame in range(240):
		await physics_frame
		saw_verified_motion = (
			saw_verified_motion
			or enemy.cached_navigation_uses_direct_objective_approach
		)
		if plant.current_health < initial_health and enemy.call("_has_player_contact"):
			reached_stable_contact = true
			break
	_expect(
		saw_verified_motion,
		"The real near plant approach must exercise verified lightweight movement."
	)
	_expect(
		plant.current_health < initial_health,
		"Direct transform movement must preserve TouchDamageArea entry and plant damage."
	)
	_expect(
		reached_stable_contact,
		"The enemy must still stop at the authored plant approach depth."
	)
	if reached_stable_contact:
		var stopped_position := enemy.global_position
		for _frame in range(12):
			await physics_frame
		_expect(
			enemy.global_position.distance_to(stopped_position) < 0.05
			and enemy.velocity == Vector2.ZERO,
			"A touching enemy must remain stopped after lightweight approach."
		)
	enemy.queue_free()
	plant.queue_free()
	await physics_frame


func _verify_partial_path_is_rejected(
	pathfinder: GridPathfinder,
	enemy_config: EnemyConfig,
	spawn_point: Marker2D
) -> void:
	var probe_enemy := enemy_config.enemy_scene.instantiate() as Enemy
	if probe_enemy == null:
		return
	var half_extents := probe_enemy.get_configured_body_collision_half_extents()
	probe_enemy.free()
	var agent_grid := pathfinder.call(
		"_get_or_create_agent_grid",
		half_extents,
		enemy_config.terrain_traversal_types
	) as AStarGrid2D
	var start_cell := pathfinder.call(
		"_get_closest_walkable_cell",
		pathfinder.call("_global_to_map", spawn_point.global_position),
		agent_grid
	) as Vector2i
	var isolated_target := _find_isolatable_target(agent_grid, start_cell)
	_expect(isolated_target != Vector2i.MAX, "Navigation test must find an isolatable target cell.")
	if isolated_target == Vector2i.MAX:
		return

	var neighbor_states: Dictionary = {}
	for direction in GridPathfinder.FLOW_CARDINAL_DIRECTIONS:
		var neighbor := isolated_target + direction
		neighbor_states[neighbor] = agent_grid.is_point_solid(neighbor)
		agent_grid.set_point_solid(neighbor, true)
	pathfinder.flow_field_cache.clear()
	pathfinder.flow_field_cache_order.clear()

	var partial_cells := agent_grid.get_id_path(start_cell, isolated_target, true)
	_expect(
		not partial_cells.is_empty() and partial_cells[-1] != isolated_target,
		"Fixture must produce a non-empty partial A* path that misses its target."
	)
	var start_global := pathfinder.call("_map_to_global", start_cell) as Vector2
	var target_global := pathfinder.call("_map_to_global", isolated_target) as Vector2
	var step := pathfinder.get_safe_navigation_step(
		start_global,
		target_global,
		half_extents,
		enemy_config.terrain_traversal_types
	)
	_expect(
		int(step.get("status", -1)) == GridPathfinder.NavigationStepStatus.UNREACHABLE,
		"Safe navigation must reject a route for which A* can only return a partial path."
	)
	_expect(
		pathfinder.get_complete_global_path(
			start_global,
			target_global,
			half_extents,
			enemy_config.terrain_traversal_types
		).is_empty(),
		"Complete-only path API must reject the isolated target."
	)
	_expect(
		not pathfinder.allow_partial_path
		and pathfinder.get_global_path(
			start_global,
			target_global,
			half_extents,
			enemy_config.terrain_traversal_types
		).is_empty(),
		"Legacy full-path API must also be complete-only by default."
	)

	for neighbor in neighbor_states:
		agent_grid.set_point_solid(neighbor, bool(neighbor_states[neighbor]))
	pathfinder.flow_field_cache.clear()
	pathfinder.flow_field_cache_order.clear()


func _find_isolatable_target(agent_grid: AStarGrid2D, start_cell: Vector2i) -> Vector2i:
	var region := agent_grid.region
	for y in range(region.position.y + 2, region.end.y - 2):
		for x in range(region.position.x + 2, region.end.x - 2):
			var cell := Vector2i(x, y)
			if cell.distance_squared_to(start_cell) < 100:
				continue
			if agent_grid.is_point_solid(cell):
				continue
			var all_neighbors_open := true
			for direction in GridPathfinder.FLOW_CARDINAL_DIRECTIONS:
				if agent_grid.is_point_solid(cell + direction):
					all_neighbors_open = false
					break
			if all_neighbors_open:
				return cell
	return Vector2i.MAX


func _verify_spawn_recovery_motion(
	game: TowerDefenseGame,
	pathfinder: GridPathfinder,
	enemy_configs: Array[EnemyConfig]
) -> void:
	if game.enemy_spawn_points.size() < 6:
		return
	game.set_physics_process(false)
	var objective_targets := game.get_home_objective_targets()
	if objective_targets.is_empty():
		return
	var objective := objective_targets[0]
	var moving_enemies: Array[Enemy] = []
	var initial_positions: Dictionary = {}
	var initial_distances: Dictionary = {}
	var route_labels: Dictionary = {}
	for enemy_config in enemy_configs:
		var probe_enemy := enemy_config.enemy_scene.instantiate() as Enemy
		if probe_enemy == null:
			continue
		var uses_shared_chase_consumer := probe_enemy.has_method("_get_navigation_move_direction")
		if uses_shared_chase_consumer:
			pathfinder.prewarm_agent_grid(
				probe_enemy.get_configured_body_collision_half_extents(),
				enemy_config.terrain_traversal_types
			)
			pathfinder.prewarm_flow_navigation_target(
				objective.global_position,
				probe_enemy.get_configured_body_collision_half_extents(),
				enemy_config.terrain_traversal_types
			)
		probe_enemy.free()
		if not uses_shared_chase_consumer:
			continue
		for spawn_index in [4, 5]:
			var enemy := enemy_config.enemy_scene.instantiate() as Enemy
			if enemy == null:
				continue
			game.enemy_container.add_child(enemy)
			enemy.global_position = game.enemy_spawn_points[spawn_index].global_position
			enemy.setup(enemy_config, game.player, pathfinder)
			enemy.set_objective_target(objective)
			enemy.navigation_update_interval_frames = 1
			moving_enemies.append(enemy)
			var enemy_id := enemy.get_instance_id()
			initial_positions[enemy_id] = enemy.global_position
			initial_distances[enemy_id] = enemy.global_position.distance_to(objective.global_position)
			route_labels[enemy_id] = "%s %s" % [
				enemy_config.display_name,
				game.enemy_spawn_points[spawn_index].name,
			]

	_expect(not moving_enemies.is_empty(), "Spawn5/6 recovery must exercise shared-chase enemies.")
	for _frame in range(120):
		await physics_frame

	for enemy in moving_enemies:
		if not is_instance_valid(enemy):
			_expect(false, "A Spawn5/6 recovery enemy disappeared before motion verification.")
			continue
		var enemy_id := enemy.get_instance_id()
		var route_label := String(route_labels[enemy_id])
		var start_position: Vector2 = initial_positions[enemy_id]
		var moved_distance := start_position.distance_to(enemy.global_position)
		_expect(
			moved_distance >= 16.0,
			"%s must physically leave its Spawn5/6 recovery area." % route_label
		)
		_expect(
			enemy.global_position.distance_to(objective.global_position)
			< float(initial_distances[enemy_id]),
			"%s must make physical progress toward Home after recovery." % route_label
		)
		enemy.queue_free()
	await physics_frame


func _expect_navigation_step_equivalent(
	legacy: Dictionary,
	fast: GridPathfinder.NavigationStepResult,
	label: String
) -> void:
	_expect(
		int(legacy.get("status", -1)) == fast.status
		and (legacy.get("waypoint", Vector2.ZERO) as Vector2).is_equal_approx(fast.waypoint)
		and (legacy.get("from_cell", Vector2i.MAX) as Vector2i) == fast.from_cell
		and (legacy.get("resolved_from_cell", Vector2i.MAX) as Vector2i)
			== fast.resolved_from_cell
		and (legacy.get("target_cell", Vector2i.MAX) as Vector2i) == fast.target_cell
		and (legacy.get("resolved_target_cell", Vector2i.MAX) as Vector2i)
			== fast.resolved_target_cell
		and (legacy.get("next_cell", Vector2i.MAX) as Vector2i) == fast.next_cell
		and bool(legacy.get("used_start_recovery", false)) == fast.used_start_recovery
		and bool(legacy.get("is_complete_route", false)) == fast.is_complete_route
		and int(legacy.get("remaining_cell_distance", -1)) == fast.remaining_cell_distance,
		"%s reusable safe-step result must exactly match the legacy Dictionary." % label
	)


func _manhattan_distance(a: Vector2i, b: Vector2i) -> int:
	return absi(a.x - b.x) + absi(a.y - b.y)


func _chebyshev_distance(a: Vector2i, b: Vector2i) -> int:
	var delta := (b - a).abs()
	return maxi(delta.x, delta.y)


func _status_name(status: int) -> String:
	var names := GridPathfinder.NavigationStepStatus.keys()
	return str(names[status]) if status >= 0 and status < names.size() else "UNKNOWN(%d)" % status


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
