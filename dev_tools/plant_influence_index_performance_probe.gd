extends SceneTree

# Headless A/B for the enemy -> plant objective broad phase. The legacy side
# reproduces one cold query-cache miss per distinct enemy cell: a 19 x 19
# occupied_cells scan followed by exact world-distance selection. Production
# reads the event-driven inverse index and performs the same exact selection.
const QUERY_COUNT := 300
const QUERY_COLUMNS := 30
const QUERY_CELL_SPACING := Vector2i(2, 2)
const QUERY_RADIUS_CELLS := 8.0
const BROAD_SEARCH_RADIUS_CELLS := 9
const SAMPLE_COUNT := 30
const WARMUP_COUNT := 4
const PLANT_COUNTS: Array[int] = [0, 10, 50]

var failures: Array[String] = []
var query_cells: Array[Vector2i] = []
var query_world_positions := PackedVector2Array()


class ProbePlantSystem:
	extends PlantSystem

	var legacy_cell_checks := 0
	var legacy_candidate_checks := 0

	func register_probe_plant(plant: PlantDefense, cells: Array[Vector2i]) -> void:
		_register_plant_footprint(plant, cells)

	func get_index_candidate_count(center_cell: Vector2i, search_radius: int) -> int:
		return _get_plant_influence_candidates(center_cell, search_radius).size()

	func get_index_cell_count(search_radius: int) -> int:
		return _ensure_plant_influence_index(search_radius).size()

	func get_index_membership_count(search_radius: int) -> int:
		var influence_index := _ensure_plant_influence_index(search_radius)
		var membership_count := 0
		for center_cell_variant in influence_index:
			var candidates := influence_index[center_cell_variant] as Dictionary
			membership_count += candidates.size()
		return membership_count

	func reset_legacy_counts() -> void:
		legacy_cell_checks = 0
		legacy_candidate_checks = 0

	func legacy_find_nearest_living_plant(
		from_global_position: Vector2,
		max_radius_cells: float
	) -> PlantDefense:
		if (
			ground_tile_map == null
			or ground_tile_map.tile_set == null
			or occupied_cells.is_empty()
			or max_radius_cells < 0.0
		):
			return null

		var tile_size := Vector2(ground_tile_map.tile_set.tile_size).abs()
		if tile_size.x <= 0.0 or tile_size.y <= 0.0:
			return null
		var from_local := ground_tile_map.to_local(from_global_position)
		var center_cell := ground_tile_map.local_to_map(from_local)
		var search_radius := ceili(max_radius_cells) + 1
		var candidates: Array[PlantDefense] = []
		var seen_instance_ids: Dictionary[int, bool] = {}
		for cell_y in range(
			center_cell.y - search_radius,
			center_cell.y + search_radius + 1
		):
			for cell_x in range(
				center_cell.x - search_radius,
				center_cell.x + search_radius + 1
			):
				legacy_cell_checks += 1
				var plant := occupied_cells.get(Vector2i(cell_x, cell_y)) as PlantDefense
				if (
					plant == null
					or not is_instance_valid(plant)
					or plant.is_dead
					or plant.is_removing
					or plant.is_queued_for_deletion()
				):
					continue
				var instance_id := plant.get_instance_id()
				if seen_instance_ids.has(instance_id):
					continue
				seen_instance_ids[instance_id] = true
				candidates.append(plant)

		var maximum_distance_squared := max_radius_cells * max_radius_cells
		var nearest_plant: PlantDefense = null
		var nearest_distance_squared := INF
		for plant in candidates:
			legacy_candidate_checks += 1
			var plant_local := ground_tile_map.to_local(plant.global_position)
			var offset_in_cells := Vector2(
				(plant_local.x - from_local.x) / tile_size.x,
				(plant_local.y - from_local.y) / tile_size.y
			)
			var distance_squared := offset_in_cells.length_squared()
			if (
				distance_squared <= maximum_distance_squared
				and distance_squared < nearest_distance_squared
			):
				nearest_distance_squared = distance_squared
				nearest_plant = plant
		return nearest_plant


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	_build_query_cells()
	for plant_count in PLANT_COUNTS:
		await _run_case(plant_count)
	if failures.is_empty():
		print("PLANT_INFLUENCE_INDEX_PERFORMANCE_PROBE_OK")
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	quit(1)


func _build_query_cells() -> void:
	query_cells.clear()
	for query_index in range(QUERY_COUNT):
		query_cells.append(
			Vector2i(
				(query_index % QUERY_COLUMNS) * QUERY_CELL_SPACING.x - 29,
				(query_index / QUERY_COLUMNS) * QUERY_CELL_SPACING.y - 9
			)
		)


func _run_case(plant_count: int) -> void:
	var fixture := Node2D.new()
	fixture.name = "PlantInfluenceProbe%d" % plant_count
	root.add_child(fixture)
	var tile_map := TileMapLayer.new()
	var tile_set := TileSet.new()
	tile_set.tile_size = Vector2i(16, 16)
	tile_map.tile_set = tile_set
	fixture.add_child(tile_map)
	var plant_container := Node2D.new()
	fixture.add_child(plant_container)
	var plant_system := ProbePlantSystem.new()
	fixture.add_child(plant_system)
	plant_system.setup(
		tile_map,
		null,
		plant_container,
		Rect2i(-128, -128, 256, 256)
	)

	query_world_positions.clear()
	for query_cell in query_cells:
		query_world_positions.append(tile_map.to_global(tile_map.map_to_local(query_cell)))

	var index_update_started_usec := Time.get_ticks_usec()
	for plant_index in range(plant_count):
		var plant := PlantDefense.new()
		plant.name = "ProbePlant%d" % plant_index
		plant_container.add_child(plant)
		var plant_cell := Vector2i(
			(plant_index % 10) * 6 - 27,
			(plant_index / 10) * 4 - 8
		)
		plant.global_position = tile_map.to_global(tile_map.map_to_local(plant_cell))
		plant_system.register_probe_plant(plant, [plant_cell])
	var index_update_ms := (
		float(Time.get_ticks_usec() - index_update_started_usec) / 1000.0
	)

	_verify_semantic_parity(plant_system, plant_count)
	for _warmup_index in range(WARMUP_COUNT):
		_run_indexed_sweep(plant_system)
		_run_legacy_cold_sweep(plant_system)

	var indexed_samples: Array[float] = []
	var legacy_samples: Array[float] = []
	for sample_index in range(SAMPLE_COUNT):
		if sample_index % 2 == 0:
			indexed_samples.append(_measure_indexed_sweep(plant_system))
			legacy_samples.append(_measure_legacy_cold_sweep(plant_system))
		else:
			legacy_samples.append(_measure_legacy_cold_sweep(plant_system))
			indexed_samples.append(_measure_indexed_sweep(plant_system))

	plant_system.reset_legacy_counts()
	_run_legacy_cold_sweep(plant_system)
	var legacy_cell_checks := plant_system.legacy_cell_checks
	var legacy_candidate_checks := plant_system.legacy_candidate_checks
	var indexed_candidate_checks := _count_indexed_candidates(plant_system)
	var indexed_summary := _summarize(indexed_samples)
	var legacy_summary := _summarize(legacy_samples)
	print(
		(
			"PLANT_INFLUENCE_INDEX_AB plant_count=%d queries=%d samples=%d "
			+ "index_update_ms=%.3f indexed_ms=%s legacy_cold_ms=%s speedup_p50=%.2f "
			+ "indexed_candidate_checks=%d legacy_candidate_checks=%d "
			+ "legacy_cell_checks=%d index_cells=%d index_memberships=%d"
		)
		% [
			plant_count,
			QUERY_COUNT,
			SAMPLE_COUNT,
			index_update_ms,
			_format_summary(indexed_summary),
			_format_summary(legacy_summary),
			float(legacy_summary["p50"]) / maxf(float(indexed_summary["p50"]), 0.001),
			indexed_candidate_checks,
			legacy_candidate_checks,
			legacy_cell_checks,
			plant_system.get_index_cell_count(BROAD_SEARCH_RADIUS_CELLS),
			plant_system.get_index_membership_count(BROAD_SEARCH_RADIUS_CELLS),
		]
	)

	fixture.queue_free()
	await process_frame


func _verify_semantic_parity(plant_system: ProbePlantSystem, plant_count: int) -> void:
	for query_index in range(query_world_positions.size()):
		var query_position := query_world_positions[query_index]
		var indexed_target := plant_system.find_nearest_living_plant(
			query_position,
			QUERY_RADIUS_CELLS
		)
		var legacy_target := plant_system.legacy_find_nearest_living_plant(
			query_position,
			QUERY_RADIUS_CELLS
		)
		_expect(
			indexed_target == legacy_target,
			"Plant count %d query %d must preserve the legacy nearest target."
			% [plant_count, query_index]
		)


func _measure_indexed_sweep(plant_system: ProbePlantSystem) -> float:
	var started_usec := Time.get_ticks_usec()
	_run_indexed_sweep(plant_system)
	return float(Time.get_ticks_usec() - started_usec) / 1000.0


func _measure_legacy_cold_sweep(plant_system: ProbePlantSystem) -> float:
	var started_usec := Time.get_ticks_usec()
	_run_legacy_cold_sweep(plant_system)
	return float(Time.get_ticks_usec() - started_usec) / 1000.0


func _run_indexed_sweep(plant_system: ProbePlantSystem) -> void:
	for query_position in query_world_positions:
		plant_system.find_nearest_living_plant(query_position, QUERY_RADIUS_CELLS)


func _run_legacy_cold_sweep(plant_system: ProbePlantSystem) -> void:
	for query_position in query_world_positions:
		plant_system.legacy_find_nearest_living_plant(
			query_position,
			QUERY_RADIUS_CELLS
		)


func _count_indexed_candidates(plant_system: ProbePlantSystem) -> int:
	var candidate_count := 0
	for query_cell in query_cells:
		candidate_count += plant_system.get_index_candidate_count(
			query_cell,
			BROAD_SEARCH_RADIUS_CELLS
		)
	return candidate_count


func _summarize(samples: Array[float]) -> Dictionary:
	if samples.is_empty():
		return {"p50": 0.0, "p95": 0.0, "p99": 0.0, "max": 0.0}
	var sorted := samples.duplicate()
	sorted.sort()
	return {
		"p50": _nearest_rank(sorted, 0.50),
		"p95": _nearest_rank(sorted, 0.95),
		"p99": _nearest_rank(sorted, 0.99),
		"max": sorted.back(),
	}


func _nearest_rank(sorted: Array[float], percentile: float) -> float:
	var rank := ceili(clampf(percentile, 0.0, 1.0) * sorted.size())
	return sorted[clampi(rank - 1, 0, sorted.size() - 1)]


func _format_summary(summary: Dictionary) -> String:
	return "%.3f/%.3f/%.3f/%.3f" % [
		summary["p50"],
		summary["p95"],
		summary["p99"],
		summary["max"],
	]


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
