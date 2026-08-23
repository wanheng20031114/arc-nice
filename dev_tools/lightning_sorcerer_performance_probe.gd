extends SceneTree

const PROACTIVE_PLANT_CONFIG := preload(
	"res://resources/config/plant_defense/agave_cannon.tres"
)

# Headless CPU/capacity probe for Lightning Sorcerer. It intentionally splits
# authoritative chain resolution from optional rendering work: the first case
# drives 300 real enemy instances through one five-target cast, while the second
# exercises the production 64/96 strict VFX pool and fixed eight-light budget.
const LIGHTNING_SCENE := preload(
	"res://scene/enemy/sorcerer/lightning_sorcerer.tscn"
)
const LIGHTNING_CONFIG := preload(
	"res://resources/config/enemies/lightning_sorcerer.tres"
)
const LIGHTNING_VFX_SCENE := preload(
	"res://scene/enemy/sorcerer/lightning_sorcerer_lightning_vfx.tscn"
)
const NIGHT_FLASH_POOL_SCENE := preload(
	"res://scene/lighting/night_vfx_flash_pool.tscn"
)
const PERFORMANCE_RUNTIME_SCENE := preload(
	"res://dev_tools/fixtures/lightning_sorcerer_performance_runtime.tscn"
)

const TILE_SIZE := 16.0
const ENEMY_COUNT := 300
const LOCAL_TARGET_COUNT := 5
const FAR_PLANT_COUNT := 1024
const CHAIN_WARMUP_SWEEPS := 6
const CHAIN_SAMPLE_SWEEPS := 40
const DENSE_GRID_HALF_EXTENT := 9
const MEDIUM_DENSE_MIN_CELL := -4
const MEDIUM_DENSE_MAX_CELL_EXCLUSIVE := 4
const DENSITY_QUERY_COUNT := ENEMY_COUNT * 4
const DENSITY_WARMUP_SWEEPS := 4
const DENSITY_SAMPLE_SWEEPS := 20
const VFX_REQUEST_COUNT := 300
const VFX_PREWARM_COUNT := 64
const VFX_RETAINED_CAPACITY := 96
const VFX_EXPECTED_DROPS_PER_BURST := (
	VFX_REQUEST_COUNT - VFX_RETAINED_CAPACITY
)
const VFX_MANUAL_FRAME_COUNT := 11
const WARNING_MANUAL_FRAME_COUNT := 18
const TEST_DELTA := 1.0 / 60.0
const POOL_IDLE_GUARD_FRAMES := 30
const PROBE_PLANT_HEALTH := 1_000_000_000

# Headless CPU gates intentionally leave CI variance headroom while still
# rejecting a return to unbounded per-caster scans or per-frame node growth.
const CHAIN_P95_LIMIT_MS := 33.333
const DENSE_QUERY_P95_LIMIT_MS := 18.0
const VFX_BURST_LIMIT_MS := 18.0
const VFX_UPDATE_P95_LIMIT_MS := 2.0
const VFX_OFFSCREEN_LIMIT_MS := 6.0
const WARNING_START_LIMIT_MS := 18.0
const WARNING_UPDATE_P95_LIMIT_MS := 2.0


class ProbePlantSystem:
	extends PlantSystem

	var spatial_query_count := 0
	var spatial_candidate_visits := 0
	var registry_query_count := 0

	func register_probe_plant(
		plant: PlantDefense,
		cell: Vector2i
	) -> void:
		_register_plant_footprint(plant, [cell], PROACTIVE_PLANT_CONFIG)

	func reset_query_metrics() -> void:
		spatial_query_count = 0
		spatial_candidate_visits = 0
		registry_query_count = 0

	func get_candidate_count(center_cell: Vector2i, search_radius: int) -> int:
		var tile_size := Vector2(ground_tile_map.tile_set.tile_size).abs()
		var center_world := ground_tile_map.to_global(
			ground_tile_map.map_to_local(center_cell)
		)
		return _query_plant_targets_for_logical_radius(
			center_world,
			tile_size,
			float(search_radius)
		).size()

	func find_nearest_enemy_attack_target_world(
		from_global_position: Vector2,
		max_world_distance: float,
		excluded_instance_ids: Dictionary = {}
	) -> PlantDefense:
		var nearest := super.find_nearest_enemy_attack_target_world(
			from_global_position,
			max_world_distance,
			excluded_instance_ids
		)
		var metrics := get_last_enemy_target_query_metrics()
		spatial_query_count += 1
		spatial_candidate_visits += int(metrics.get("candidates_visited", 0))
		if metrics.get("query_mode") == &"registry":
			registry_query_count += 1
		return nearest


var failures: Array[String] = []
var budget_violations: Array[String] = []
var runtime: LightningSorcererPerformanceRuntime = null
var tile_map: TileMapLayer = null
var plant_container: Node2D = null
var plant_system: ProbePlantSystem = null
var pathfinder: Node = null
var object_pool: SessionObjectPool = null
var flash_pool: NightVfxFlashPool = null
var enemies: Array[LightningSorcerer] = []
var local_targets: Array[PlantDefense] = []
var pool_registration_ms := 0.0


func _init() -> void:
	call_deferred(&"_run")


func _run() -> void:
	_build_fixture()
	await process_frame
	await physics_frame
	_spawn_local_targets()
	_spawn_enemies()
	await process_frame
	await physics_frame

	var local_candidate_count_before := plant_system.get_candidate_count(
		Vector2i.ZERO,
		8
	)
	var local_result := await _measure_chain_case()

	_spawn_far_targets()
	await process_frame
	await physics_frame
	var local_candidate_count_after := plant_system.get_candidate_count(
		Vector2i.ZERO,
		8
	)
	var distant_result := await _measure_chain_case()
	var density_result := await _measure_local_density()
	var warning_result := _measure_warning_pressure()
	var vfx_result := await _measure_vfx_pressure()

	_validate_results(
		local_result,
		distant_result,
		density_result,
		warning_result,
		vfx_result,
		local_candidate_count_before,
		local_candidate_count_after
	)
	_print_results(
		local_result,
		distant_result,
		density_result,
		warning_result,
		vfx_result,
		local_candidate_count_before,
		local_candidate_count_after
	)
	await _finish()


func _build_fixture() -> void:
	runtime = PERFORMANCE_RUNTIME_SCENE.instantiate() as LightningSorcererPerformanceRuntime
	if runtime == null:
		_expect(false, "Lightning performance runtime fixture must instantiate.")
		return
	runtime.name = "LightningSorcererPerformanceProbe"
	root.add_child(runtime)
	current_scene = runtime
	var simulation_coordinator := runtime.get_node_or_null(
		"EnemySimulationCoordinator"
	)
	if simulation_coordinator != null:
		simulation_coordinator.process_mode = Node.PROCESS_MODE_DISABLED

	var camera := Camera2D.new()
	camera.name = "Camera2D"
	camera.enabled = true
	runtime.add_child(camera)
	camera.global_position = Vector2(152.0, 0.0)

	flash_pool = NIGHT_FLASH_POOL_SCENE.instantiate() as NightVfxFlashPool
	flash_pool.name = "NightVfxFlashPool"
	runtime.add_child(flash_pool)

	object_pool = SessionObjectPool.new()
	object_pool.name = "SessionObjectPool"
	runtime.add_child(object_pool)
	var pool_started_usec := Time.get_ticks_usec()
	object_pool.register_scene(
		LIGHTNING_VFX_SCENE,
		VFX_PREWARM_COUNT,
		VFX_RETAINED_CAPACITY
	)
	pool_registration_ms = float(
		Time.get_ticks_usec() - pool_started_usec
	) / 1000.0

	tile_map = TileMapLayer.new()
	tile_map.name = "GroundTileMapLayer"
	var tile_set := TileSet.new()
	tile_set.tile_size = Vector2i(int(TILE_SIZE), int(TILE_SIZE))
	tile_map.tile_set = tile_set
	runtime.add_child(tile_map)

	plant_container = Node2D.new()
	plant_container.name = "PlantContainer"
	runtime.add_child(plant_container)
	plant_system = ProbePlantSystem.new()
	plant_system.name = "PlantSystem"
	runtime.add_child(plant_system)
	plant_system.setup(
		tile_map,
		null,
		plant_container,
		Rect2i(-4096, -4096, 8192, 8192)
	)
	plant_system.set_enemy_target_query_metrics_enabled(true)
	runtime.plant_system = plant_system

	pathfinder = runtime.get_node_or_null("GridPathfinder")


func _spawn_local_targets() -> void:
	for target_index in range(LOCAL_TARGET_COUNT):
		local_targets.append(_spawn_plant(
			"LocalTarget%02d" % target_index,
			Vector2i(2 + target_index * 2, 0)
		))


func _spawn_far_targets() -> void:
	for plant_index in range(FAR_PLANT_COUNT):
		_spawn_plant(
			"FarTarget%04d" % plant_index,
			Vector2i(
				256 + (plant_index % 32) * 2,
				256 + (plant_index / 32) * 2
			)
		)


func _spawn_medium_dense_local_targets() -> void:
	for cell_y in range(
		MEDIUM_DENSE_MIN_CELL,
		MEDIUM_DENSE_MAX_CELL_EXCLUSIVE
	):
		for cell_x in range(
			MEDIUM_DENSE_MIN_CELL,
			MEDIUM_DENSE_MAX_CELL_EXCLUSIVE
		):
			_spawn_plant(
				"MediumDenseTarget_%+03d_%+03d" % [cell_x, cell_y],
				Vector2i(cell_x, cell_y)
			)


func _spawn_remaining_dense_local_targets() -> void:
	for cell_y in range(-DENSE_GRID_HALF_EXTENT, DENSE_GRID_HALF_EXTENT + 1):
		for cell_x in range(-DENSE_GRID_HALF_EXTENT, DENSE_GRID_HALF_EXTENT + 1):
			if (
				cell_x >= MEDIUM_DENSE_MIN_CELL
				and cell_x < MEDIUM_DENSE_MAX_CELL_EXCLUSIVE
				and cell_y >= MEDIUM_DENSE_MIN_CELL
				and cell_y < MEDIUM_DENSE_MAX_CELL_EXCLUSIVE
			):
				continue
			_spawn_plant(
				"DenseTarget_%+03d_%+03d" % [cell_x, cell_y],
				Vector2i(cell_x, cell_y)
			)


func _spawn_plant(plant_name: String, cell: Vector2i) -> PlantDefense:
	var plant := PlantDefense.new()
	plant.name = plant_name
	plant.max_health = PROBE_PLANT_HEALTH
	plant.current_health = PROBE_PLANT_HEALTH
	plant.magic_defense = 0
	plant.physical_defense = 0
	plant.collision_layer = 0
	plant.collision_mask = 0
	plant_container.add_child(plant)
	plant.global_position = _cell_world(cell)
	plant_system.register_probe_plant(plant, cell)
	return plant


func _spawn_enemies() -> void:
	for enemy_index in range(ENEMY_COUNT):
		var enemy := LIGHTNING_SCENE.instantiate() as LightningSorcerer
		if enemy == null:
			continue
		runtime.add_child(enemy)
		enemy.name = "LightningSorcerer%03d" % enemy_index
		enemy.global_position = Vector2.ZERO
		enemy.setup(LIGHTNING_CONFIG, null, pathfinder, runtime)
		enemy.collision_layer = 0
		enemy.collision_mask = 0
		enemy.set_process(false)
		enemy.set_physics_process(false)
		enemies.append(enemy)


func _measure_chain_case() -> Dictionary:
	for _warmup_index in range(CHAIN_WARMUP_SWEEPS):
		_run_chain_sweep()
		await process_frame

	var samples_ms: Array[float] = []
	var minimum_queries := 1_000_000
	var maximum_queries := 0
	var minimum_candidate_visits := 1_000_000
	var maximum_candidate_visits := 0
	var minimum_hits := 1_000_000
	var maximum_hits := 0
	var registry_query_total := 0
	for _sample_index in range(CHAIN_SAMPLE_SWEEPS):
		var sample := _run_chain_sweep()
		samples_ms.append(float(sample["elapsed_ms"]))
		minimum_queries = mini(minimum_queries, int(sample["queries"]))
		maximum_queries = maxi(maximum_queries, int(sample["queries"]))
		minimum_candidate_visits = mini(
			minimum_candidate_visits,
			int(sample["candidate_visits"])
		)
		maximum_candidate_visits = maxi(
			maximum_candidate_visits,
			int(sample["candidate_visits"])
		)
		minimum_hits = mini(minimum_hits, int(sample["hits"]))
		maximum_hits = maxi(maximum_hits, int(sample["hits"]))
		registry_query_total += int(sample["registry_queries"])
		# Damage numbers aggregate into five deferred callbacks. Drain them outside
		# the synchronous chain timing so every sweep starts from the same state.
		await process_frame

	return {
		"timing": _summarize(samples_ms),
		"minimum_queries": minimum_queries,
		"maximum_queries": maximum_queries,
		"minimum_candidate_visits": minimum_candidate_visits,
		"maximum_candidate_visits": maximum_candidate_visits,
		"minimum_hits": minimum_hits,
		"maximum_hits": maximum_hits,
		"registry_query_total": registry_query_total,
	}


func _run_chain_sweep() -> Dictionary:
	runtime.attack_target_query_count = 0
	plant_system.reset_query_metrics()
	var total_hits := 0
	var started_usec := Time.get_ticks_usec()
	for enemy in enemies:
		var first_target := runtime.find_nearest_enemy_attack_target_world(
			enemy.global_position,
			LIGHTNING_CONFIG.attack_range
		)
		if first_target == null:
			continue
		var world_path := enemy.call(
			"_resolve_chain_hits",
			first_target,
			LIGHTNING_CONFIG,
			enemy.get_instance_id()
		) as PackedVector2Array
		total_hits += maxi(world_path.size() - 1, 0)
	var elapsed_ms := float(Time.get_ticks_usec() - started_usec) / 1000.0
	return {
		"elapsed_ms": elapsed_ms,
		"queries": runtime.attack_target_query_count,
		"candidate_visits": plant_system.spatial_candidate_visits,
		"registry_queries": plant_system.registry_query_count,
		"hits": total_hits,
	}


func _measure_local_density() -> Dictionary:
	var center_cell := Vector2i.ZERO
	var center_world := _cell_world(center_cell)
	var sparse_candidate_count := plant_system.get_candidate_count(
		center_cell,
		4
	)
	var sparse_result := await _measure_query_only_case(center_world)
	_spawn_medium_dense_local_targets()
	await process_frame
	await physics_frame
	var medium_candidate_count := plant_system.get_candidate_count(center_cell, 4)
	var medium_result := await _measure_query_only_case(center_world)
	_spawn_remaining_dense_local_targets()
	await process_frame
	await physics_frame
	var dense_candidate_count := plant_system.get_candidate_count(center_cell, 4)
	var dense_result := await _measure_query_only_case(center_world)
	return {
		"sparse_candidate_count": sparse_candidate_count,
		"medium_candidate_count": medium_candidate_count,
		"dense_candidate_count": dense_candidate_count,
		"sparse_result": sparse_result,
		"medium_result": medium_result,
		"dense_result": dense_result,
	}


func _measure_query_only_case(center_world: Vector2) -> Dictionary:
	for _warmup_index in range(DENSITY_WARMUP_SWEEPS):
		_run_query_only_sweep(center_world)
	var samples_ms: Array[float] = []
	var minimum_candidate_visits := 1_000_000_000
	var maximum_candidate_visits := 0
	var registry_query_total := 0
	for _sample_index in range(DENSITY_SAMPLE_SWEEPS):
		var sample := _run_query_only_sweep(center_world)
		samples_ms.append(float(sample["elapsed_ms"]))
		minimum_candidate_visits = mini(
			minimum_candidate_visits,
			int(sample["candidate_visits"])
		)
		maximum_candidate_visits = maxi(
			maximum_candidate_visits,
			int(sample["candidate_visits"])
		)
		registry_query_total += int(sample["registry_queries"])
	return {
		"timing": _summarize(samples_ms),
		"minimum_candidate_visits": minimum_candidate_visits,
		"maximum_candidate_visits": maximum_candidate_visits,
		"registry_query_total": registry_query_total,
	}


func _run_query_only_sweep(center_world: Vector2) -> Dictionary:
	plant_system.reset_query_metrics()
	var started_usec := Time.get_ticks_usec()
	for _query_index in range(DENSITY_QUERY_COUNT):
		plant_system.find_nearest_enemy_attack_target_world(
			center_world,
			LIGHTNING_CONFIG.chain_range
		)
	return {
		"elapsed_ms": float(Time.get_ticks_usec() - started_usec) / 1000.0,
		"candidate_visits": plant_system.spatial_candidate_visits,
		"registry_queries": plant_system.registry_query_count,
	}


func _measure_warning_pressure() -> Dictionary:
	var started_usec := Time.get_ticks_usec()
	var started_count := 0
	for enemy in enemies:
		if bool(enemy.call("_try_start_windup", local_targets[0], LIGHTNING_CONFIG)):
			started_count += 1
	var start_ms := float(Time.get_ticks_usec() - started_usec) / 1000.0

	var active_count := 0
	var visible_count := 0
	var processing_count := 0
	for enemy in enemies:
		if enemy.target_warning.is_warning_active():
			active_count += 1
		if enemy.target_warning.visible:
			visible_count += 1
		if enemy.target_warning.is_processing():
			processing_count += 1

	var samples_ms: Array[float] = []
	for _frame_index in range(WARNING_MANUAL_FRAME_COUNT):
		started_usec = Time.get_ticks_usec()
		for enemy in enemies:
			enemy.call("_update_windup", TEST_DELTA)
		samples_ms.append(
			float(Time.get_ticks_usec() - started_usec) / 1000.0
		)

	var windup_count := 0
	var progressed_count := 0
	for enemy in enemies:
		if enemy.combat_state == LightningSorcerer.CombatState.WINDUP:
			windup_count += 1
		if enemy.target_warning.get_warning_progress() > 0.0:
			progressed_count += 1
		enemy.call("_cancel_windup", false)
	return {
		"start_ms": start_ms,
		"started_count": started_count,
		"active_count": active_count,
		"visible_count": visible_count,
		"processing_count": processing_count,
		"windup_count": windup_count,
		"progressed_count": progressed_count,
		"timing": _summarize(samples_ms),
	}


func _measure_vfx_pressure() -> Dictionary:
	var startup_metrics := _vfx_metrics()
	var maximum_gameplay_path := PackedVector2Array([
		Vector2.ZERO,
		Vector2(112.0, 0.0),
		Vector2(160.0, 0.0),
		Vector2(208.0, 0.0),
		Vector2(256.0, 0.0),
		Vector2(304.0, 0.0),
	])

	var first_burst := _spawn_vfx_burst(maximum_gameplay_path)
	var first_metrics := _vfx_metrics()
	var active_lights_after_first_burst := flash_pool.get_active_flash_count()
	var update_result := _measure_active_vfx_updates()
	await _wait_for_vfx_pool_idle()
	var idle_metrics := _vfx_metrics()

	var second_burst := _spawn_vfx_burst(maximum_gameplay_path)
	var second_metrics := _vfx_metrics()
	_release_all_active_vfx()
	await _wait_for_vfx_pool_idle()
	var reuse_idle_metrics := _vfx_metrics()

	var offscreen_path := PackedVector2Array([
		Vector2(100000.0, 100000.0),
		Vector2(100112.0, 100000.0),
	])
	var offscreen_before := _vfx_metrics()
	var offscreen_started_usec := Time.get_ticks_usec()
	var offscreen_accepted := 0
	for _request_index in range(VFX_REQUEST_COUNT):
		if LightningSorcererLightningVfx.try_spawn(
			runtime,
			offscreen_path
		):
			offscreen_accepted += 1
	var offscreen_ms := float(
		Time.get_ticks_usec() - offscreen_started_usec
	) / 1000.0
	var offscreen_after := _vfx_metrics()

	return {
		"startup_metrics": startup_metrics,
		"first_burst": first_burst,
		"first_metrics": first_metrics,
		"active_lights_after_first_burst": active_lights_after_first_burst,
		"update_result": update_result,
		"idle_metrics": idle_metrics,
		"second_burst": second_burst,
		"second_metrics": second_metrics,
		"reuse_idle_metrics": reuse_idle_metrics,
		"offscreen_accepted": offscreen_accepted,
		"offscreen_ms": offscreen_ms,
		"offscreen_before": offscreen_before,
		"offscreen_after": offscreen_after,
	}


func _spawn_vfx_burst(world_path: PackedVector2Array) -> Dictionary:
	var accepted := 0
	var started_usec := Time.get_ticks_usec()
	for _request_index in range(VFX_REQUEST_COUNT):
		if LightningSorcererLightningVfx.try_spawn(runtime, world_path):
			accepted += 1
	return {
		"accepted": accepted,
		"elapsed_ms": float(Time.get_ticks_usec() - started_usec) / 1000.0,
	}


func _measure_active_vfx_updates() -> Dictionary:
	var active_effects := _get_active_vfx()
	for effect in active_effects:
		effect.set_process(false)
	var samples_ms: Array[float] = []
	var maximum_segment_vector_count := 0
	for _frame_index in range(VFX_MANUAL_FRAME_COUNT):
		var segment_vector_count := 0
		var started_usec := Time.get_ticks_usec()
		for effect in active_effects:
			if not effect.pool_active:
				continue
			effect.call("_process", TEST_DELTA)
			if not effect.pool_active:
				continue
			var revealed := effect.call(
				"_build_revealed_multiline_segments"
			) as PackedVector2Array
			segment_vector_count += revealed.size()
		samples_ms.append(float(Time.get_ticks_usec() - started_usec) / 1000.0)
		maximum_segment_vector_count = maxi(
			maximum_segment_vector_count,
			segment_vector_count
		)
	return {
		"active_effect_count": active_effects.size(),
		"timing": _summarize(samples_ms),
		"maximum_segment_vector_count": maximum_segment_vector_count,
	}


func _release_all_active_vfx() -> void:
	for effect in _get_active_vfx():
		SessionObjectPool.release_to_owner(effect)


func _get_active_vfx() -> Array[LightningSorcererLightningVfx]:
	var result: Array[LightningSorcererLightningVfx] = []
	for child in runtime.get_children():
		var effect := child as LightningSorcererLightningVfx
		if effect == null or not effect.pool_active:
			continue
		result.append(effect)
	return result


func _wait_for_vfx_pool_idle() -> void:
	for _guard_index in range(POOL_IDLE_GUARD_FRAMES):
		var metrics := _vfx_metrics()
		if (
			int(metrics.get("in_use", 0)) == 0
			and int(metrics.get("pending_release", 0)) == 0
		):
			return
		await process_frame
		await physics_frame
	_expect(false, "Lightning VFX pool did not become idle within the guard.")


func _vfx_metrics() -> Dictionary:
	return object_pool.get_metrics(LIGHTNING_VFX_SCENE.resource_path)


func _print_results(
	local_result: Dictionary,
	distant_result: Dictionary,
	density_result: Dictionary,
	warning_result: Dictionary,
	vfx_result: Dictionary,
	local_candidate_count_before: int,
	local_candidate_count_after: int
) -> void:
	var local_timing := local_result["timing"] as Dictionary
	var distant_timing := distant_result["timing"] as Dictionary
	var sparse_density_result := density_result["sparse_result"] as Dictionary
	var medium_density_result := density_result["medium_result"] as Dictionary
	var dense_density_result := density_result["dense_result"] as Dictionary
	var sparse_density_timing := sparse_density_result["timing"] as Dictionary
	var medium_density_timing := medium_density_result["timing"] as Dictionary
	var dense_density_timing := dense_density_result["timing"] as Dictionary
	var first_burst := vfx_result["first_burst"] as Dictionary
	var second_burst := vfx_result["second_burst"] as Dictionary
	var first_metrics := vfx_result["first_metrics"] as Dictionary
	var update_result := vfx_result["update_result"] as Dictionary
	var update_timing := update_result["timing"] as Dictionary
	var offscreen_before := vfx_result["offscreen_before"] as Dictionary
	var offscreen_after := vfx_result["offscreen_after"] as Dictionary
	var warning_timing := warning_result["timing"] as Dictionary
	print(
		(
			"LIGHTNING_SORCERER_WARNING_PERFORMANCE enemies=%d started=%d "
			+ "active=%d visible=%d node_process=%d start_ms=%.3f "
			+ "frames=%d update_ms=%s progressed=%d"
		)
		% [
			ENEMY_COUNT,
			int(warning_result["started_count"]),
			int(warning_result["active_count"]),
			int(warning_result["visible_count"]),
			int(warning_result["processing_count"]),
			float(warning_result["start_ms"]),
			WARNING_MANUAL_FRAME_COUNT,
			_format_summary(warning_timing),
			int(warning_result["progressed_count"]),
		]
	)
	print(
		(
			"LIGHTNING_SORCERER_CHAIN_PERFORMANCE enemies=%d hits_per_sweep=%d "
			+ "queries_per_sweep=%d initial_queries=%d bounce_queries=%d "
			+ "samples=%d local_plants=%d far_plants=%d "
			+ "local_candidates=%d/%d local_ms=%s distant_ms=%s "
			+ "distant_p50_ratio=%.3f candidate_visits=%d/%d registry_queries=%d/%d"
		)
		% [
			ENEMY_COUNT,
			int(local_result["minimum_hits"]),
			int(local_result["minimum_queries"]),
			ENEMY_COUNT,
			ENEMY_COUNT * (LOCAL_TARGET_COUNT - 1),
			CHAIN_SAMPLE_SWEEPS,
			LOCAL_TARGET_COUNT,
			FAR_PLANT_COUNT,
			local_candidate_count_before,
			local_candidate_count_after,
			_format_summary(local_timing),
			_format_summary(distant_timing),
			float(distant_timing["p50"])
				/ maxf(float(local_timing["p50"]), 0.001),
			int(local_result["minimum_candidate_visits"]),
			int(distant_result["minimum_candidate_visits"]),
			int(local_result["registry_query_total"]),
			int(distant_result["registry_query_total"]),
		]
	)
	print(
		(
			"LIGHTNING_SORCERER_LOCAL_DENSITY_PERFORMANCE queries=%d samples=%d "
			+ "candidates=%d/%d/%d sparse_ms=%s medium_ms=%s dense_ms=%s "
			+ "p50_slowdown=%.2f/%.2f candidate_visits=%d/%d/%d "
			+ "registry_queries=%d/%d/%d"
		)
		% [
			DENSITY_QUERY_COUNT,
			DENSITY_SAMPLE_SWEEPS,
			int(density_result["sparse_candidate_count"]),
			int(density_result["medium_candidate_count"]),
			int(density_result["dense_candidate_count"]),
			_format_summary(sparse_density_timing),
			_format_summary(medium_density_timing),
			_format_summary(dense_density_timing),
			float(medium_density_timing["p50"])
				/ maxf(float(sparse_density_timing["p50"]), 0.001),
			float(dense_density_timing["p50"])
				/ maxf(float(sparse_density_timing["p50"]), 0.001),
			int(sparse_density_result["minimum_candidate_visits"]),
			int(medium_density_result["minimum_candidate_visits"]),
			int(dense_density_result["minimum_candidate_visits"]),
			int(sparse_density_result["registry_query_total"]),
			int(medium_density_result["registry_query_total"]),
			int(dense_density_result["registry_query_total"]),
		]
	)
	print(
		(
			"LIGHTNING_SORCERER_VFX_PERFORMANCE requests=%d prewarm=%d capacity=%d "
			+ "registration_ms=%.3f first_accepted=%d first_ms=%.3f "
			+ "reuse_accepted=%d reuse_ms=%.3f created=%d peak=%d dropped=%d "
			+ "overflow=%d lights=%d update_ms=%s update_vectors_max=%d "
			+ "multiline_submit_bound=%d offscreen_ms=%.3f offscreen_dropped_delta=%d"
		)
		% [
			VFX_REQUEST_COUNT,
			VFX_PREWARM_COUNT,
			VFX_RETAINED_CAPACITY,
			pool_registration_ms,
			int(first_burst["accepted"]),
			float(first_burst["elapsed_ms"]),
			int(second_burst["accepted"]),
			float(second_burst["elapsed_ms"]),
			int(first_metrics.get("created", -1)),
			int(first_metrics.get("peak_in_use", -1)),
			int(first_metrics.get("dropped", -1)),
			int(first_metrics.get("overflow", -1)),
			int(vfx_result["active_lights_after_first_burst"]),
			_format_summary(update_timing),
			int(update_result["maximum_segment_vector_count"]),
			VFX_RETAINED_CAPACITY * 2,
			float(vfx_result["offscreen_ms"]),
			int(offscreen_after.get("dropped", 0))
				- int(offscreen_before.get("dropped", 0)),
		]
	)
	print(
		"LIGHTNING_SORCERER_HEADLESS_NOTE GPU timing, actual draw calls, HDR glow, "
		+ "overdraw, and PointLight2D pixel cost require a non-headless run."
	)
	var result := {
		"schema_version": 1,
		"valid": failures.is_empty(),
		"verdict": (
			"passed"
			if failures.is_empty() and budget_violations.is_empty()
			else "failed"
		),
		"enemy_count": ENEMY_COUNT,
		"thresholds_ms": {
			"chain_p95": CHAIN_P95_LIMIT_MS,
			"dense_query_p95": DENSE_QUERY_P95_LIMIT_MS,
			"warning_start": WARNING_START_LIMIT_MS,
			"warning_update_p95": WARNING_UPDATE_P95_LIMIT_MS,
			"vfx_burst": VFX_BURST_LIMIT_MS,
			"vfx_update_p95": VFX_UPDATE_P95_LIMIT_MS,
			"vfx_offscreen": VFX_OFFSCREEN_LIMIT_MS,
		},
		"chain": {
			"local": local_result,
			"distant": distant_result,
		},
		"density": density_result,
		"warning": warning_result,
		"vfx": vfx_result,
		"workload_violations": failures,
		"budget_violations": budget_violations,
		"violations": failures + budget_violations,
	}
	print(
		"LIGHTNING_SORCERER_PERFORMANCE_RESULT ",
		JSON.stringify(result)
	)


func _validate_results(
	local_result: Dictionary,
	distant_result: Dictionary,
	density_result: Dictionary,
	warning_result: Dictionary,
	vfx_result: Dictionary,
	local_candidate_count_before: int,
	local_candidate_count_after: int
) -> void:
	var expected_queries := ENEMY_COUNT * LOCAL_TARGET_COUNT
	var expected_hits := ENEMY_COUNT * LOCAL_TARGET_COUNT
	for result in [local_result, distant_result]:
		_expect(
			int(result["minimum_queries"]) == expected_queries
			and int(result["maximum_queries"]) == expected_queries,
			"Every 300-enemy sweep must perform one initial plus four chain queries per caster."
		)
		_expect(
			int(result["minimum_hits"]) == expected_hits
			and int(result["maximum_hits"]) == expected_hits,
			"Every 300-enemy sweep must resolve exactly 1500 direct hits."
		)
	_expect(
		int(local_result["registry_query_total"]) > 0
		and int(distant_result["registry_query_total"]) == 0,
		"A tiny registry may scan at most its bounded size, while 1024 distant plants must switch to local buckets."
	)
	_expect(
		local_candidate_count_before == local_candidate_count_after,
		"Adding 1024 distant plants must not enlarge the local attack bucket."
	)
	_expect(
		int(local_result["minimum_candidate_visits"])
			>= int(distant_result["minimum_candidate_visits"])
		and int(local_result["maximum_candidate_visits"])
			>= int(distant_result["maximum_candidate_visits"]),
		"Distant plants must not add local candidate work; bucket/ring pruning may reduce it."
	)
	var sparse_density_result := density_result["sparse_result"] as Dictionary
	var medium_density_result := density_result["medium_result"] as Dictionary
	var dense_density_result := density_result["dense_result"] as Dictionary
	var sparse_candidate_count := int(density_result["sparse_candidate_count"])
	var medium_candidate_count := int(density_result["medium_candidate_count"])
	var dense_candidate_count := int(density_result["dense_candidate_count"])
	_expect(
		medium_candidate_count > sparse_candidate_count
		and dense_candidate_count > medium_candidate_count,
		"The density diagnostics must progressively enlarge the local AABB candidate set."
	)
	_expect(
		int(sparse_density_result["minimum_candidate_visits"])
			> 0
		and int(sparse_density_result["maximum_candidate_visits"])
			<= sparse_candidate_count * DENSITY_QUERY_COUNT
		and int(medium_density_result["minimum_candidate_visits"])
			> 0
		and int(medium_density_result["maximum_candidate_visits"])
			<= medium_candidate_count * DENSITY_QUERY_COUNT
		and int(dense_density_result["minimum_candidate_visits"])
			> 0
		and int(dense_density_result["maximum_candidate_visits"])
			<= dense_candidate_count * DENSITY_QUERY_COUNT,
		"Direct-nearest ring pruning must visit a positive subset bounded by the local AABB candidates."
	)
	_expect(
		int(sparse_density_result["registry_query_total"]) == 0
		and int(medium_density_result["registry_query_total"]) == 0
		and int(dense_density_result["registry_query_total"]) == 0,
		"With the retained distant population, every density case must stay on bounded local buckets."
	)
	_expect_budget(
		float((local_result["timing"] as Dictionary)["p95"])
			<= CHAIN_P95_LIMIT_MS
		and float((distant_result["timing"] as Dictionary)["p95"])
			<= CHAIN_P95_LIMIT_MS,
		"A real 300 x 5 chain sweep exceeded the headless CPU p95 gate."
	)
	_expect_budget(
		float((dense_density_result["timing"] as Dictionary)["p95"])
			<= DENSE_QUERY_P95_LIMIT_MS,
		"The 1200-query dense local-target sweep exceeded the CPU p95 gate."
	)
	_expect(
		int(warning_result["started_count"]) == ENEMY_COUNT
		and int(warning_result["active_count"]) == ENEMY_COUNT
		and int(warning_result["visible_count"]) == ENEMY_COUNT
		and int(warning_result["processing_count"]) == 0
		and int(warning_result["windup_count"]) == ENEMY_COUNT
		and int(warning_result["progressed_count"]) == ENEMY_COUNT,
		"The pressure case must drive 300 authored warnings through real WINDUP without per-node processing."
	)
	_expect_budget(
		float(warning_result["start_ms"]) <= WARNING_START_LIMIT_MS
		and float((warning_result["timing"] as Dictionary)["p95"])
			<= WARNING_UPDATE_P95_LIMIT_MS,
		"The 300-warning WINDUP batch exceeded its headless CPU gate."
	)

	var startup := vfx_result["startup_metrics"] as Dictionary
	var first_burst := vfx_result["first_burst"] as Dictionary
	var first_metrics := vfx_result["first_metrics"] as Dictionary
	var idle := vfx_result["idle_metrics"] as Dictionary
	var second_burst := vfx_result["second_burst"] as Dictionary
	var second_metrics := vfx_result["second_metrics"] as Dictionary
	var reuse_idle := vfx_result["reuse_idle_metrics"] as Dictionary
	var update_result := vfx_result["update_result"] as Dictionary
	var offscreen_before := vfx_result["offscreen_before"] as Dictionary
	var offscreen_after := vfx_result["offscreen_after"] as Dictionary
	_expect(
		int(startup.get("created", -1)) == VFX_PREWARM_COUNT
		and int(startup.get("inactive", -1)) == VFX_PREWARM_COUNT
		and int(startup.get("retained_capacity", -1))
			== VFX_RETAINED_CAPACITY,
		"Lightning VFX startup must preserve the production 64/96 pool contract."
	)
	_expect(
		int(first_burst["accepted"]) == VFX_RETAINED_CAPACITY
		and int(first_metrics.get("created", -1)) == VFX_RETAINED_CAPACITY
		and int(first_metrics.get("peak_in_use", -1)) == VFX_RETAINED_CAPACITY
		and int(first_metrics.get("dropped", -1))
			== VFX_EXPECTED_DROPS_PER_BURST
		and int(first_metrics.get("overflow", -1)) == 0,
		"A 300-cast visual burst must cap at 96 leases and drop only optional VFX."
	)
	_expect(
		int(vfx_result["active_lights_after_first_burst"]) == 8,
		"A saturated lightning burst must still use only eight real night lights."
	)
	_expect(
		int(update_result["active_effect_count"]) == VFX_RETAINED_CAPACITY,
		"The active-update sample must drive all 96 retained VFX nodes."
	)
	_expect(
		int(idle.get("in_use", -1)) == 0
		and int(idle.get("pending_release", -1)) == 0
		and int(idle.get("inactive", -1)) == VFX_RETAINED_CAPACITY,
		"All completed lightning VFX must return after the one-frame quarantine."
	)
	_expect(
		int(second_burst["accepted"]) == VFX_RETAINED_CAPACITY
		and int(second_metrics.get("created", -1)) == VFX_RETAINED_CAPACITY
		and int(second_metrics.get("dropped", -1))
			== VFX_EXPECTED_DROPS_PER_BURST * 2
		and int(reuse_idle.get("created", -1)) == VFX_RETAINED_CAPACITY
		and int(reuse_idle.get("in_use", -1)) == 0,
		"A hot 300-cast burst must reuse the 96 retained VFX without node growth."
	)
	_expect(
		int(vfx_result["offscreen_accepted"]) == 0
		and int(offscreen_after.get("created", -1))
			== int(offscreen_before.get("created", -1))
		and int(offscreen_after.get("dropped", -1))
			== int(offscreen_before.get("dropped", -1)),
		"Offscreen lightning must be omitted before taking or dropping a pool lease."
	)
	_expect_budget(
		float(first_burst["elapsed_ms"]) <= VFX_BURST_LIMIT_MS
		and float(second_burst["elapsed_ms"]) <= VFX_BURST_LIMIT_MS,
		"A 300-request Lightning VFX burst exceeded the synchronous CPU gate."
	)
	_expect_budget(
		float((update_result["timing"] as Dictionary)["p95"])
			<= VFX_UPDATE_P95_LIMIT_MS,
		"Updating all 96 retained Lightning VFX exceeded the CPU p95 gate."
	)
	_expect_budget(
		float(vfx_result["offscreen_ms"]) <= VFX_OFFSCREEN_LIMIT_MS,
		"The 300-request offscreen Lightning VFX rejection exceeded its CPU gate."
	)


func _summarize(samples: Array[float]) -> Dictionary:
	if samples.is_empty():
		return {"p50": 0.0, "p95": 0.0, "p99": 0.0, "max": 0.0}
	var sorted := samples.duplicate()
	sorted.sort()
	return {
		"p50": _percentile(sorted, 0.50),
		"p95": _percentile(sorted, 0.95),
		"p99": _percentile(sorted, 0.99),
		"max": sorted.back(),
	}


func _percentile(sorted: Array[float], ratio: float) -> float:
	if sorted.is_empty():
		return 0.0
	var rank := ceili(clampf(ratio, 0.0, 1.0) * float(sorted.size()))
	return sorted[clampi(rank - 1, 0, sorted.size() - 1)]


func _format_summary(summary: Dictionary) -> String:
	return "%.3f/%.3f/%.3f/%.3f" % [
		float(summary["p50"]),
		float(summary["p95"]),
		float(summary["p99"]),
		float(summary["max"]),
	]


func _cell_world(cell: Vector2i) -> Vector2:
	return tile_map.to_global(tile_map.map_to_local(cell))


func _finish() -> void:
	current_scene = null
	if runtime != null and is_instance_valid(runtime):
		runtime.queue_free()
	for _cleanup_frame in range(6):
		await process_frame
		await physics_frame
	if failures.is_empty() and budget_violations.is_empty():
		print("LIGHTNING_SORCERER_PERFORMANCE_PROBE_OK")
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	for violation in budget_violations:
		push_error(violation)
	quit(1)


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)


func _expect_budget(condition: bool, message: String) -> void:
	if not condition:
		budget_violations.append(message)
