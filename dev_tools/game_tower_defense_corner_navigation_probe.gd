extends SceneTree

const TOWER_SCENE := preload("res://scene/game_tower_defense.tscn")
const BASIC_CONFIG := preload("res://resources/config/enemies/yuanshi_insect_basic.tres")
const OFFSETS: Array[float] = [-6.0, -3.0, 0.0, 3.0, 6.0]
const MAX_STATIC_REPORTS := 32
const STUCK_FRAME_THRESHOLD := 90

var static_zero_count := 0
var static_sample_count := 0
var static_reports: Array[String] = []
var legacy_cardinal_zero_count := 0
var legacy_cardinal_sample_count := 0
var legacy_cardinal_reports: Array[String] = []
var inflated_band_sample_count := 0
var inflated_band_unreachable_count := 0
var inflated_band_ready_but_zero_count := 0
var inflated_band_reports: Array[String] = []
var invalid_recovery_first_step_count := 0
var dynamic_stuck_count := 0
var dynamic_unresolved_count := 0
var dynamic_route_count := 0
var direct_diagonal_success_count := 0
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
	if pathfinder == null or not pathfinder.is_built:
		push_error("CORNER_NAV_PROBE: GridPathfinder is unavailable.")
		quit(1)
		return
	var objectives := game.get_home_objective_targets()
	if objectives.is_empty():
		push_error("CORNER_NAV_PROBE: Home objectives are unavailable.")
		quit(1)
		return
	_print_home_target_diagnostics(game, pathfinder, objectives)

	var probe_enemy := BASIC_CONFIG.enemy_scene.instantiate() as Enemy
	game.enemy_container.add_child(probe_enemy)
	probe_enemy.setup(BASIC_CONFIG, game.player, pathfinder)
	probe_enemy.navigation_update_interval_frames = 1
	probe_enemy.set_physics_process(false)
	await physics_frame

	_scan_static_corner_positions(pathfinder, probe_enemy, objectives)
	_scan_legacy_cardinal_corner_positions(pathfinder, probe_enemy, objectives)
	_scan_inflated_grid_transition_band(pathfinder, probe_enemy, objectives)
	_scan_all_agent_profile_transition_bands(game, pathfinder, objectives)
	if game.player != null:
		var player_objectives: Array[Node2D] = [game.player]
		_scan_static_corner_positions(pathfinder, probe_enemy, player_objectives)
		_scan_legacy_cardinal_corner_positions(pathfinder, probe_enemy, player_objectives)
	_print_cardinal_design_evidence(probe_enemy, objectives[0])
	probe_enemy.queue_free()
	await physics_frame

	game.set_physics_process(false)
	await _run_spawn_route_probes(game, pathfinder, objectives)
	_assert_results(game)

	var summary := (
		"static_samples=%d ready_but_zero=%d legacy_samples=%d legacy_ready_but_zero=%d band_samples=%d band_unreachable=%d band_ready_but_zero=%d invalid_first_steps=%d dynamic_routes=%d dynamic_stuck=%d dynamic_unresolved=%d diagonal_direct=%d reports=%d"
		% [
			static_sample_count,
			static_zero_count,
			legacy_cardinal_sample_count,
			legacy_cardinal_zero_count,
			inflated_band_sample_count,
			inflated_band_unreachable_count,
			inflated_band_ready_but_zero_count,
			invalid_recovery_first_step_count,
			dynamic_route_count,
			dynamic_stuck_count,
			dynamic_unresolved_count,
			direct_diagonal_success_count,
			static_reports.size() + legacy_cardinal_reports.size() + inflated_band_reports.size(),
		]
	)
	for report in static_reports:
		print(report)
	for report in legacy_cardinal_reports:
		print(report)
	for report in inflated_band_reports:
		print(report)

	game.queue_free()
	await process_frame
	await physics_frame
	if failures.is_empty():
		print("CORNER_NAV_PROBE_OK %s" % summary)
		quit()
		return
	for failure in failures:
		push_error("CORNER_NAV_PROBE_FAILED: %s" % failure)
	print("CORNER_NAV_PROBE_FAILED %s failures=%d" % [summary, failures.size()])
	quit(1)


func _scan_static_corner_positions(
	pathfinder: GridPathfinder,
	enemy: Enemy,
	objectives: Array[Node2D]
) -> void:
	var extents := enemy.get_configured_body_collision_half_extents()
	var traversal_types := BASIC_CONFIG.terrain_traversal_types
	var agent_grid := pathfinder.call(
		"_get_or_create_agent_grid",
		extents,
		traversal_types
	) as AStarGrid2D
	var region := agent_grid.region
	for y in range(region.position.y + 1, region.end.y - 1):
		for x in range(region.position.x + 1, region.end.x - 1):
			var cell := Vector2i(x, y)
			if agent_grid.is_point_solid(cell) or not _is_near_blocked_cell(agent_grid, cell):
				continue
			var cell_center := pathfinder.call("_map_to_global", cell) as Vector2
			for offset_y in OFFSETS:
				for offset_x in OFFSETS:
					var sample_position := cell_center + Vector2(offset_x, offset_y)
					var objective := _nearest_objective(sample_position, objectives)
					if objective == null:
						continue
					enemy.global_position = sample_position
					enemy.force_update_transform()
					enemy.set_objective_target(objective)
					enemy.call("_clear_navigation_path")
					var step := pathfinder.get_safe_navigation_step(
						sample_position,
						objective.global_position,
						extents,
						traversal_types
					)
					var status := int(step.get("status", GridPathfinder.NavigationStepStatus.UNREACHABLE))
					if status != GridPathfinder.NavigationStepStatus.READY:
						continue
					static_sample_count += 1
					var direction := enemy.call(
						"_get_safe_navigation_move_direction",
						objective,
						pathfinder,
						2.0
					) as Vector2
					if direction != Vector2.ZERO:
						continue
					static_zero_count += 1
					if static_reports.size() >= MAX_STATIC_REPORTS:
						continue
					static_reports.append(_format_failure_diagnostics(
						pathfinder,
						enemy,
						objective,
						step,
						"STATIC_READY_ZERO"
					))


func _scan_legacy_cardinal_corner_positions(
	pathfinder: GridPathfinder,
	enemy: Enemy,
	objectives: Array[Node2D]
) -> void:
	var extents := enemy.get_configured_body_collision_half_extents()
	var traversal_types := BASIC_CONFIG.terrain_traversal_types
	var agent_grid := pathfinder.call(
		"_get_or_create_agent_grid",
		extents,
		traversal_types
	) as AStarGrid2D
	var fields: Dictionary = {}
	for objective in objectives:
		var target_cell := pathfinder.call(
			"_get_closest_walkable_cell",
			pathfinder.call("_global_to_map", objective.global_position),
			agent_grid
		) as Vector2i
		fields[objective.get_instance_id()] = _build_legacy_cardinal_field(
			target_cell,
			agent_grid
		)

	var region := agent_grid.region
	for y in range(region.position.y + 1, region.end.y - 1):
		for x in range(region.position.x + 1, region.end.x - 1):
			var cell := Vector2i(x, y)
			if agent_grid.is_point_solid(cell) or not _is_near_blocked_cell(agent_grid, cell):
				continue
			var cell_center := pathfinder.call("_map_to_global", cell) as Vector2
			for offset_y in OFFSETS:
				for offset_x in OFFSETS:
					var sample_position := cell_center + Vector2(offset_x, offset_y)
					var objective := _nearest_objective(sample_position, objectives)
					if objective == null:
						continue
					var next_cells: Dictionary = fields[objective.get_instance_id()]
					if not next_cells.has(cell):
						continue
					var next_cell: Vector2i = next_cells[cell]
					var waypoint := pathfinder.call("_map_to_global", next_cell) as Vector2
					# Exact target-center occupancy is ARRIVED, not a zero-direction
					# navigation failure. The legacy emulation has no status enum of its
					# own, so exclude that terminal case explicitly.
					if sample_position.distance_squared_to(waypoint) <= 0.25:
						continue
					enemy.global_position = sample_position
					enemy.force_update_transform()
					legacy_cardinal_sample_count += 1
					var direction := _legacy_axis_aligned_waypoint_direction(
						enemy,
						waypoint,
						2.0
					)
					if direction != Vector2.ZERO:
						continue
					legacy_cardinal_zero_count += 1
					if legacy_cardinal_reports.size() >= MAX_STATIC_REPORTS:
						continue
					var step := {
						"status": GridPathfinder.NavigationStepStatus.READY,
						"from_cell": cell,
						"resolved_from_cell": cell,
						"next_cell": next_cell,
						"waypoint": waypoint,
					}
					legacy_cardinal_reports.append(_format_failure_diagnostics(
						pathfinder,
						enemy,
						objective,
						step,
						"LEGACY_CARDINAL_READY_ZERO"
					))


func _build_legacy_cardinal_field(
	target_cell: Vector2i,
	grid: AStarGrid2D
) -> Dictionary:
	var next_cells: Dictionary = {target_cell: target_cell}
	var pending: Array[Vector2i] = [target_cell]
	var index := 0
	while index < pending.size():
		var current := pending[index]
		index += 1
		for direction in GridPathfinder.FLOW_CARDINAL_DIRECTIONS:
			var neighbor: Vector2i = current + direction
			if next_cells.has(neighbor):
				continue
			if not grid.is_in_boundsv(neighbor) or grid.is_point_solid(neighbor):
				continue
			next_cells[neighbor] = current
			pending.append(neighbor)
	return next_cells


func _scan_inflated_grid_transition_band(
	pathfinder: GridPathfinder,
	enemy: Enemy,
	objectives: Array[Node2D]
) -> void:
	var extents := enemy.get_configured_body_collision_half_extents()
	var traversal_types := enemy.terrain_traversal_types
	var agent_grid := pathfinder.call(
		"_get_or_create_agent_grid",
		extents,
		traversal_types
	) as AStarGrid2D
	var region := agent_grid.region
	for y in range(region.position.y + 1, region.end.y - 1):
		for x in range(region.position.x + 1, region.end.x - 1):
			var cell := Vector2i(x, y)
			# Only inspect clearance-band cells: the point grid itself is open, but
			# the collision-shape-inflated agent grid rejects the center.
			if not agent_grid.is_point_solid(cell) or pathfinder.astar_grid.is_point_solid(cell):
				continue
			var cell_center := pathfinder.call("_map_to_global", cell) as Vector2
			for offset_y in OFFSETS:
				for offset_x in OFFSETS:
					var sample_position := cell_center + Vector2(offset_x, offset_y)
					var objective := _nearest_objective(sample_position, objectives)
					if objective == null:
						continue
					enemy.global_position = sample_position
					enemy.force_update_transform()
					# A zero-length test is not a reliable overlap predicate for
					# CharacterBody2D. A position is useful to recovery diagnostics
					# only when the body can physically move at least one cardinal pixel.
					if not _has_physical_cardinal_exit(enemy):
						continue
					inflated_band_sample_count += 1
					var step := pathfinder.get_safe_navigation_step(
						sample_position,
						objective.global_position,
						extents,
						traversal_types
					)
					var status := int(step.get("status", GridPathfinder.NavigationStepStatus.UNREACHABLE))
					if (
						status == GridPathfinder.NavigationStepStatus.READY
						and bool(step.get("used_start_recovery", false))
					):
						var first_step: Vector2i = step.get("next_cell", Vector2i.MAX)
						if not _is_valid_recovery_first_step(
							pathfinder,
							cell,
							first_step,
							traversal_types
						):
							invalid_recovery_first_step_count += 1
					if status == GridPathfinder.NavigationStepStatus.READY:
						enemy.set_objective_target(objective)
						enemy.call("_clear_navigation_path")
						var move_direction := enemy.call(
							"_get_safe_navigation_move_direction",
							objective,
							pathfinder,
							2.0
						) as Vector2
						if move_direction == Vector2.ZERO:
							inflated_band_ready_but_zero_count += 1
							if inflated_band_reports.size() < MAX_STATIC_REPORTS:
								inflated_band_reports.append(
									_format_failure_diagnostics(
										pathfinder,
										enemy,
										objective,
										step,
										"INFLATED_BAND_READY_ZERO"
									)
								)
					if status != GridPathfinder.NavigationStepStatus.UNREACHABLE:
						continue
					inflated_band_unreachable_count += 1
					if inflated_band_reports.size() >= MAX_STATIC_REPORTS:
						continue
					var closest_walkable := pathfinder.call(
						"_get_closest_walkable_cell",
						cell,
						agent_grid
					) as Vector2i
					var direct_direction := enemy.call(
						"_get_collision_safe_direct_objective_direction",
						objective.global_position,
						2.0
					) as Vector2
					inflated_band_reports.append(
						_format_failure_diagnostics(
							pathfinder,
							enemy,
							objective,
							step,
							"INFLATED_BAND_UNREACHABLE enemy=%s extents=%s closest=%s manhattan=%d physical_direct=%s distance=%.2f"
							% [
								enemy.config.display_name if enemy.config != null else enemy.name,
								extents,
								closest_walkable,
								_manhattan_distance(cell, closest_walkable),
								direct_direction,
								sample_position.distance_to(objective.global_position),
							]
						)
					)


func _scan_all_agent_profile_transition_bands(
	game: GameTowerDefense,
	pathfinder: GridPathfinder,
	objectives: Array[Node2D]
) -> void:
	var seen_profiles: Dictionary = {}
	for wave_config in game.waves:
		if wave_config == null:
			continue
		for entry in wave_config.enemy_entries:
			if entry == null or entry.enemy_config == null or entry.enemy_config.enemy_scene == null:
				continue
			var candidate := entry.enemy_config.enemy_scene.instantiate() as Enemy
			if candidate == null:
				continue
			game.enemy_container.add_child(candidate)
			candidate.setup(entry.enemy_config, game.player, pathfinder)
			candidate.set_physics_process(false)
			var extents := candidate.get_configured_body_collision_half_extents()
			var profile_key := "%d:%d:%d" % [
				ceili(extents.x),
				ceili(extents.y),
				candidate.terrain_traversal_types,
			]
			if seen_profiles.has(profile_key):
				candidate.queue_free()
				continue
			seen_profiles[profile_key] = true
			print(
				"AGENT_PROFILE_SCAN enemy=%s profile=%s extents=%s"
				% [entry.enemy_config.display_name, profile_key, extents]
			)
			var samples_before := inflated_band_sample_count
			var unreachable_before := inflated_band_unreachable_count
			_scan_inflated_grid_transition_band(
				pathfinder,
				candidate,
				objectives
			)
			print(
				"AGENT_PROFILE_RESULT enemy=%s samples=%d unreachable=%d"
				% [
					entry.enemy_config.display_name,
					inflated_band_sample_count - samples_before,
					inflated_band_unreachable_count - unreachable_before,
				]
			)
			candidate.queue_free()


func _run_spawn_route_probes(
	game: GameTowerDefense,
	pathfinder: GridPathfinder,
	objectives: Array[Node2D]
) -> void:
	# The route probe diagnoses terrain navigation, not the intentional contact-
	# damage stop. Keep the player away from the Home approach corridor.
	if game.player != null:
		game.player.global_position = Vector2(-5000.0, -5000.0)
	# The matrix intentionally resolves many high-damage profiles at once. Keep
	# the base alive so later routes are still accepted by the real Home handler.
	game.maximum_base_health = 1_000_000
	game.current_base_health = game.maximum_base_health
	var probes: Array[Enemy] = []
	var last_positions: Dictionary = {}
	var stagnant_frames: Dictionary = {}
	var route_labels: Dictionary = {}
	for enemy_config in _collect_unique_agent_profile_configs(game):
		for spawn in game.enemy_spawn_points:
			var enemy := enemy_config.enemy_scene.instantiate() as Enemy
			game.enemy_container.add_child(enemy)
			enemy.global_position = spawn.global_position
			enemy.setup(enemy_config, game.player, pathfinder)
			enemy.navigation_update_interval_frames = 1
			enemy.add_move_speed_modifier(900001, 8.0)
			enemy.set_objective_target(_nearest_objective(enemy.global_position, objectives))
			probes.append(enemy)
			dynamic_route_count += 1
			last_positions[enemy.get_instance_id()] = enemy.global_position
			stagnant_frames[enemy.get_instance_id()] = 0
			route_labels[enemy.get_instance_id()] = "%s/%s" % [
				enemy_config.display_name,
				spawn.name,
			]

	var reported: Dictionary = {}
	for frame_index in range(900):
		await physics_frame
		for enemy in probes:
			if not is_instance_valid(enemy) or enemy.is_dead:
				continue
			var enemy_id := enemy.get_instance_id()
			var previous: Vector2 = last_positions[enemy_id]
			if enemy.global_position.distance_squared_to(previous) <= 0.0001:
				stagnant_frames[enemy_id] = int(stagnant_frames[enemy_id]) + 1
			else:
				stagnant_frames[enemy_id] = 0
				last_positions[enemy_id] = enemy.global_position
			if (
				int(stagnant_frames[enemy_id]) >= STUCK_FRAME_THRESHOLD
				and not reported.has(enemy_id)
			):
				reported[enemy_id] = true
				dynamic_stuck_count += 1
				var objective := enemy.objective_target
				var step := pathfinder.get_safe_navigation_step(
					enemy.global_position,
					objective.global_position,
					enemy.get_configured_body_collision_half_extents(),
					enemy.terrain_traversal_types
				)
				print(_format_failure_diagnostics(
					pathfinder,
					enemy,
					objective,
					step,
					"DYNAMIC_STUCK route=%s frame=%d" % [route_labels[enemy_id], frame_index]
				))

	for enemy in probes:
		if is_instance_valid(enemy):
			dynamic_unresolved_count += 1
			print(
				"ROUTE_END route=%s id=%d pos=%s cell=%s target=%s distance=%.2f velocity=%s cached=%s direct=%s"
				% [
					route_labels[enemy.get_instance_id()],
					enemy.get_instance_id(),
					enemy.global_position,
					pathfinder.call("_global_to_map", enemy.global_position),
					enemy.objective_target.global_position if is_instance_valid(enemy.objective_target) else Vector2.ZERO,
					enemy.global_position.distance_to(enemy.objective_target.global_position) if is_instance_valid(enemy.objective_target) else -1.0,
					enemy.velocity,
					enemy.cached_navigation_move_direction,
					enemy.cached_navigation_uses_direct_objective_approach,
				]
			)
			enemy.queue_free()
	await physics_frame


func _collect_unique_agent_profile_configs(game: GameTowerDefense) -> Array[EnemyConfig]:
	var configs: Array[EnemyConfig] = []
	var seen_profiles: Dictionary = {}
	for wave_config in game.waves:
		if wave_config == null:
			continue
		for entry in wave_config.enemy_entries:
			if entry == null or entry.enemy_config == null or entry.enemy_config.enemy_scene == null:
				continue
			var probe := entry.enemy_config.enemy_scene.instantiate() as Enemy
			if probe == null:
				continue
			var extents := probe.get_configured_body_collision_half_extents()
			var traversal_types := entry.enemy_config.terrain_traversal_types
			var profile_key := "%d:%d:%d" % [
				ceili(extents.x),
				ceili(extents.y),
				traversal_types,
			]
			probe.free()
			if seen_profiles.has(profile_key):
				continue
			seen_profiles[profile_key] = true
			configs.append(entry.enemy_config)
	return configs


func _print_cardinal_design_evidence(enemy: Enemy, objective: Node2D) -> void:
	var samples := [
		objective.global_position + Vector2(420.0, 170.0),
		objective.global_position + Vector2(-510.0, 230.0),
		objective.global_position + Vector2(460.0, -190.0),
	]
	for sample in samples:
		enemy.global_position = sample
		enemy.force_update_transform()
		var offset: Vector2 = objective.global_position - (sample as Vector2)
		var direction := enemy.call(
			"_get_collision_safe_direct_objective_direction",
			objective.global_position,
			2.0
		) as Vector2
		if direction != Vector2.ZERO and not is_zero_approx(direction.x * direction.y):
			direct_diagonal_success_count += 1
		print(
			"DIRECT_DESIGN sample=%s offset=%s normalized=%s selected=%s axis_only=%s"
			% [sample, offset, offset.normalized(), direction, is_zero_approx(direction.x * direction.y)]
		)


func _assert_results(game: GameTowerDefense) -> void:
	_expect(static_sample_count > 0, "Static corner matrix did not collect samples.")
	_expect(
		static_zero_count == 0,
		"%d complete READY corner steps returned zero direction." % static_zero_count
	)
	_expect(inflated_band_sample_count > 0, "Inflated transition-band matrix collected no samples.")
	_expect(
		inflated_band_unreachable_count == 0,
		"%d physically recoverable inflated-band samples remained UNREACHABLE."
		% inflated_band_unreachable_count
	)
	_expect(
		inflated_band_ready_but_zero_count == 0,
		"%d inflated-band READY decisions could not produce a CharacterBody direction."
		% inflated_band_ready_but_zero_count
	)
	_expect(
		invalid_recovery_first_step_count == 0,
		"%d recovery decisions skipped an adjacent/no-corner-cutting first step."
		% invalid_recovery_first_step_count
	)
	_expect(game.enemy_spawn_points.size() == 6, "Dynamic matrix requires all six spawn points.")
	_expect(dynamic_route_count >= 6, "Dynamic route matrix did not instantiate every spawn.")
	_expect(
		dynamic_stuck_count == 0,
		"%d Spawn-to-Home routes remained stationary for %d frames."
		% [dynamic_stuck_count, STUCK_FRAME_THRESHOLD]
	)
	_expect(
		dynamic_unresolved_count == 0,
		"%d Spawn-to-Home routes failed to enter a Home Area within the probe window."
		% dynamic_unresolved_count
	)
	_expect(
		direct_diagonal_success_count >= 2,
		"Open far-objective probes did not demonstrate normalized diagonal direct movement."
	)


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)


func _is_near_blocked_cell(grid: AStarGrid2D, cell: Vector2i) -> bool:
	for direction in GridPathfinder.FLOW_CARDINAL_DIRECTIONS:
		if grid.is_point_solid(cell + direction):
			return true
	return false


func _has_physical_cardinal_exit(enemy: Enemy) -> bool:
	for direction in GridPathfinder.FLOW_CARDINAL_DIRECTIONS:
		if not enemy.test_move(enemy.global_transform, Vector2(direction)):
			return true
	return false


func _legacy_axis_aligned_waypoint_direction(
	enemy: Enemy,
	waypoint: Vector2,
	arrival_distance: float
) -> Vector2:
	var offset := waypoint - enemy.global_position
	if offset == Vector2.ZERO:
		return Vector2.ZERO
	var deadzone := maxf(arrival_distance, 0.0)
	var abs_x := absf(offset.x)
	var abs_y := absf(offset.y)
	if abs_x <= deadzone and abs_y > deadzone:
		return _legacy_choose_unblocked_axis(enemy, Vector2(0.0, signf(offset.y)))
	if abs_y <= deadzone and abs_x > deadzone:
		return _legacy_choose_unblocked_axis(enemy, Vector2(signf(offset.x), 0.0))
	if abs_x >= abs_y:
		return _legacy_choose_unblocked_axis(
			enemy,
			Vector2(signf(offset.x), 0.0),
			Vector2(0.0, signf(offset.y))
		)
	return _legacy_choose_unblocked_axis(
		enemy,
		Vector2(0.0, signf(offset.y)),
		Vector2(signf(offset.x), 0.0)
	)


func _legacy_choose_unblocked_axis(
	enemy: Enemy,
	primary: Vector2,
	secondary: Vector2 = Vector2.ZERO
) -> Vector2:
	if primary != Vector2.ZERO and bool(enemy.call(
		"_is_navigation_motion_shape_safe",
		primary,
		Enemy.PATH_DIRECTION_PROBE_DISTANCE
	)):
		return primary
	if secondary != Vector2.ZERO and bool(enemy.call(
		"_is_navigation_motion_shape_safe",
		secondary,
		Enemy.PATH_DIRECTION_PROBE_DISTANCE
	)):
		return secondary
	return Vector2.ZERO


func _nearest_objective(position: Vector2, objectives: Array[Node2D]) -> Node2D:
	var best: Node2D = null
	var best_distance := INF
	for objective in objectives:
		if objective == null or not is_instance_valid(objective):
			continue
		var distance := position.distance_squared_to(objective.global_position)
		if distance < best_distance:
			best_distance = distance
			best = objective
	return best


func _manhattan_distance(a: Vector2i, b: Vector2i) -> int:
	if b == Vector2i.MAX:
		return -1
	return absi(a.x - b.x) + absi(a.y - b.y)


func _is_valid_recovery_first_step(
	pathfinder: GridPathfinder,
	from_cell: Vector2i,
	first_step: Vector2i,
	traversal_types: int
) -> bool:
	if first_step == Vector2i.MAX:
		return false
	var delta := first_step - from_cell
	if delta == Vector2i.ZERO or maxi(absi(delta.x), absi(delta.y)) != 1:
		return false
	# Reuse the production contract so cardinal targets, diagonal targets, both
	# diagonal side cells and navigation bounds are all checked identically.
	return bool(pathfinder.call(
		"_is_raw_recovery_transition_safe",
		from_cell,
		delta,
		traversal_types
	))


func _print_home_target_diagnostics(
	game: GameTowerDefense,
	pathfinder: GridPathfinder,
	objectives: Array[Node2D]
) -> void:
	for objective in objectives:
		var cell := pathfinder.call("_global_to_map", objective.global_position) as Vector2i
		var tile_data := game.ground_tile_map_layer.get_cell_tile_data(cell)
		var collision_polygons := (
			tile_data.get_collision_polygons_count(pathfinder.tile_physics_layer_index)
			if tile_data != null
			else 0
		)
		print(
			"HOME_TARGET_DIAG name=%s pos=%s cell=%s base_solid=%s ground_atlas=%s collision_polygons=%d"
			% [
				objective.name,
				objective.global_position,
				cell,
				pathfinder.astar_grid.is_point_solid(cell),
				game.ground_tile_map_layer.get_cell_atlas_coords(cell),
				collision_polygons,
			]
		)


func _format_failure_diagnostics(
	pathfinder: GridPathfinder,
	enemy: Enemy,
	objective: Node2D,
	step: Dictionary,
	label: String
) -> String:
	var directions := {
		"right": Vector2.RIGHT,
		"left": Vector2.LEFT,
		"down": Vector2.DOWN,
		"up": Vector2.UP,
	}
	var collisions: Array[String] = []
	for direction_name in directions:
		var direction: Vector2 = directions[direction_name]
		var collision := KinematicCollision2D.new()
		var blocked := enemy.test_move(enemy.global_transform, direction, collision)
		collisions.append(
			"%s=%s normal=%s travel=%s remainder=%s"
			% [
				direction_name,
				blocked,
				collision.get_normal() if blocked else Vector2.ZERO,
				collision.get_travel() if blocked else Vector2.ZERO,
				collision.get_remainder() if blocked else Vector2.ZERO,
			]
		)
	return (
		"%s id=%d pos=%s cell=%s target=%s target_cell=%s status=%d from=%s resolved_from=%s next=%s waypoint=%s velocity=%s cached=%s direct=%s collisions=[%s]"
		% [
			label,
			enemy.get_instance_id(),
			enemy.global_position,
			pathfinder.call("_global_to_map", enemy.global_position),
			objective.global_position,
			pathfinder.call("_global_to_map", objective.global_position),
			int(step.get("status", -1)),
			step.get("from_cell", Vector2i.MAX),
			step.get("resolved_from_cell", Vector2i.MAX),
			step.get("next_cell", Vector2i.MAX),
			step.get("waypoint", Vector2.ZERO),
			enemy.velocity,
			enemy.cached_navigation_move_direction,
			enemy.cached_navigation_uses_direct_objective_approach,
			"; ".join(collisions),
		]
	)
