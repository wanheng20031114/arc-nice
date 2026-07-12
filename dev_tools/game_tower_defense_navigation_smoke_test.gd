extends SceneTree

const TOWER_SCENE := preload("res://scene/game_tower_defense.tscn")

var failures: Array[String] = []


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	var game := TOWER_SCENE.instantiate() as GameTowerDefense
	game.auto_start_waves = false
	root.add_child(game)
	current_scene = game
	await process_frame
	await physics_frame

	var pathfinder := game.get_node_or_null("GridPathfinder") as GridPathfinder
	_expect(pathfinder != null and pathfinder.is_built, "Tower defense must provide a built GridPathfinder.")
	_expect(not game.linglan_boss_enabled, "Tower-defense Linglan must remain disabled.")
	_expect(game.bosses.is_empty(), "Tower-defense Campaign must not expose a BossConfig.")
	var spawn_points: Array[Marker2D] = game.enemy_spawn_points
	var targets: Array[Node2D] = []
	if game.player != null:
		targets.append(game.player)
	targets.append_array(game.get_home_objective_targets())
	var enemy_configs := _collect_actual_enemy_configs(game)

	_expect(spawn_points.size() == 6, "Tower defense navigation must validate all six spawn points.")
	_expect(targets.size() == 5, "Tower defense navigation must validate the player and four Home cells.")
	_expect(not enemy_configs.is_empty(), "Tower defense campaign must expose actual EnemyConfig resources.")

	if pathfinder != null and pathfinder.is_built and not enemy_configs.is_empty():
		for enemy_config in enemy_configs:
			_verify_config_navigation_matrix(
				game,
				pathfinder,
				enemy_config,
				spawn_points,
				targets
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
		await _verify_spawn_recovery_motion(game, pathfinder, enemy_configs)

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

func _collect_actual_enemy_configs(game: GameTowerDefense) -> Array[EnemyConfig]:
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
	game: GameTowerDefense,
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
				_expect(
					_manhattan_distance(from_cell, resolved_from_cell) == 1,
					"%s recovery must be exactly one cardinal cell, got %s->%s."
					% [route_label, from_cell, resolved_from_cell]
				)

			var next_cell: Vector2i = step.get("next_cell", Vector2i.MAX)
			if status == GridPathfinder.NavigationStepStatus.READY and next_cell != Vector2i.MAX:
				_expect(
					_manhattan_distance(resolved_from_cell, next_cell) <= 1,
					"%s next cell must be current or one cardinal neighbor." % route_label
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
	game: GameTowerDefense,
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


func _verify_deferred_does_not_direct_fallback(
	game: GameTowerDefense,
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
	pathfinder.flow_field_budget_frame = Engine.get_physics_frames()
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
	game: GameTowerDefense,
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
	pathfinder.flow_field_budget_frame = Engine.get_physics_frames()
	pathfinder.flow_field_builds_used_this_frame = maxi(
		pathfinder.max_flow_field_builds_per_physics_frame,
		1
	)
	var move_direction := enemy.call("_get_navigation_move_direction", 1.0 / 60.0) as Vector2
	_expect(
		move_direction != Vector2.ZERO and enemy.cached_navigation_uses_direct_objective_approach,
		"A distant static Home target must use the cheap direct-approach tier before flow lookup."
	)
	if move_direction != Vector2.ZERO:
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
			bool(enemy.call("_can_use_far_static_objective_linear_movement")),
			"The lightweight movement tier must remain exclusive to a verified far static objective."
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
	game: GameTowerDefense,
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


func _status_name(status: int) -> String:
	var names := GridPathfinder.NavigationStepStatus.keys()
	return str(names[status]) if status >= 0 and status < names.size() else "UNKNOWN(%d)" % status


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
