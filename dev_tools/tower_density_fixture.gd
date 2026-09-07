extends Node

var result: Dictionary = {}
var _finishing := false

## Production-scene capacity probe. Fixture overrides health to hold the cohort
## constant; combat, targeting, production, visuals and physics remain enabled.
## --headless --path . --script res://dev_tools/tower_density_probe.gd --
## --buildings=400 --enemies=300 --frames=600 --output=res://dev_tools/output/density.json
var runtime: TowerDefenseGame
var building_count := 400
var enemy_count := 300
var sample_frames := 600
var warmup_frames := 300
var output_path := "res://dev_tools/output/density.json"
var disable_production := false
var disable_visuals := false
var active_production := false
var detailed_metrics := false
var enemy_wave_path := ""
var screenshot_path := ""
var _deadline_msec := 0
var _samples: Array[float] = []
var _physics_samples: Array[float] = []
var _native_physics_samples: Array[float] = []
var _native_process_samples: Array[float] = []
var _enemy_instances: Array[Enemy] = []
var _building_instances: Array[PlantDefense] = []
var _started_sampling := false
var _last_frame_usec := 0
var _last_physics_usec := 0
var _gpu_samples: Array[float] = []
var _render_cpu_samples: Array[float] = []


func _ready() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--buildings="):
			building_count = int(arg.trim_prefix("--buildings="))
		elif arg.begins_with("--enemies="):
			enemy_count = int(arg.trim_prefix("--enemies="))
		elif arg.begins_with("--frames="):
			sample_frames = int(arg.trim_prefix("--frames="))
		elif arg.begins_with("--warmup="):
			warmup_frames = int(arg.trim_prefix("--warmup="))
		elif arg.begins_with("--output="):
			output_path = arg.trim_prefix("--output=")
		elif arg == "--disable-production":
			disable_production = true
		elif arg == "--disable-visuals":
			disable_visuals = true
		elif arg == "--active-production":
			active_production = true
		elif arg == "--detailed-metrics":
			detailed_metrics = true
		elif arg.begins_with("--enemy-wave="):
			enemy_wave_path = arg.trim_prefix("--enemy-wave=")
		elif arg.begins_with("--screenshot="):
			screenshot_path = arg.trim_prefix("--screenshot=")
	_deadline_msec = Time.get_ticks_msec() + 120000
	_run.call_deferred()


func _process(_delta: float) -> void:
	if Time.get_ticks_msec() > _deadline_msec:
		push_error("Density probe exceeded 120 seconds")
		_finish(2)
		return
	if _started_sampling:
		var now := Time.get_ticks_usec()
		if _last_frame_usec > 0:
			_samples.append(float(now - _last_frame_usec) / 1000.0)
		_last_frame_usec = now
		_native_physics_samples.append(Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS) * 1000.0)
		_native_process_samples.append(Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0)
		if DisplayServer.get_name() != "headless":
			_gpu_samples.append(RenderingServer.viewport_get_measured_render_time_gpu(get_tree().root.get_viewport_rid()))
			_render_cpu_samples.append(RenderingServer.viewport_get_measured_render_time_cpu(get_tree().root.get_viewport_rid()))


func _physics_process(_delta: float) -> void:
	if _started_sampling:
		var now := Time.get_ticks_usec()
		if _last_physics_usec > 0:
			_physics_samples.append(float(now - _last_physics_usec) / 1000.0)
		_last_physics_usec = now


func _run() -> void:
	seed(20260908)
	Engine.max_fps = 60
	if DisplayServer.get_name() != "headless":
		RenderingServer.viewport_set_measure_render_time(get_tree().root.get_viewport_rid(), true)
	(get_tree().root.get_node("RunState") as RunStateStore).begin_new_run(&"weishidaier", false)
	runtime = load("res://scene/game_modes/tower_defense/tower_defense_game.tscn").instantiate()
	runtime.auto_start_waves = false
	runtime.day_phase_announcements_enabled = false
	runtime.defer_runtime_activation()
	get_tree().root.add_child(runtime)
	get_tree().current_scene = runtime
	if not await _wait_for_runtime_preparation():
		_finish(4)
		return
	runtime.activate_runtime()
	runtime.random_generator.seed = 20260908
	runtime.plant_terrain_decay_timer.stop()
	runtime.player.current_health = 10000000
	runtime.player.max_health = 10000000
	runtime.player.global_position = Vector2(640, 380)
	await get_tree().process_frame
	print("DENSITY_READY ", runtime.plant_system.placement_area)
	var plant_ids := [&"corn_machine_gun", &"agave_cannon", &"wood_processing_station", &"oak_warehouse"]
	var source_recipe := ProductionRecipe.new()
	var water: PickupConfig = load("res://resources/config/materials/material_water_bottle.tres")
	if active_production:
		source_recipe.recipe_id = &"density_water_source"
		source_recipe.duration_seconds = 5.0
		source_recipe.input_items = [water]
		source_recipe.input_amounts = [0]
		source_recipe.output_items = [water]
		source_recipe.output_amounts = [1]
	for index in building_count:
		var plant_id: StringName = plant_ids[index % plant_ids.size()]
		var config := runtime.plant_system.get_config(plant_id).duplicate() as PlantDefenseConfig
		config.max_health = 10000000
		var cell := Vector2i(1 + (index % 20) * 2, 3 + (index / 20) * 2)
		var building := runtime.plant_system._instantiate_registered_plant(
			config, cell, runtime.player, index + 1, false, -1, 0, -1, false
		)
		if building == null:
			push_error("Building fixture failed: " + str(index))
			_finish(3)
			return
		_building_instances.append(building)
		if building is ProductionBuilding:
			var producer := building as ProductionBuilding
			producer.recipe_unlock_checker = Callable()
			if active_production:
				producer.recipes.assign([source_recipe])
			if not producer.recipes.is_empty():
				producer.select_recipe(producer.recipes[0].recipe_id)
				producer.set_production_loop_enabled(true)
		if index % 16 == 15:
			await get_tree().process_frame
	var cohort := load("res://dev_tools/tower_density_enemy_cohort.gd")
	var enemy_paths: PackedStringArray = cohort.build_paths(enemy_count, enemy_wave_path)
	for index in enemy_paths.size():
		var config_path := enemy_paths[index]
		var config := load(config_path).duplicate() as EnemyConfig
		config.max_health = 10000000
		var enemy := config.enemy_scene.instantiate() as Enemy
		runtime.enemy_container.add_child(enemy)
		enemy.global_position = Vector2(560 + index % 25 * 12, 130 + index / 25 * 18)
		enemy.setup(config, runtime.player, null, runtime)
		runtime.enemy_coordinator.assign_enemy_targets(enemy, enemy.global_position)
		runtime.enemy_coordinator.finalize_authoritative_enemy_spawn(enemy, config, enemy.global_position, false)
		_enemy_instances.append(enemy)
		if index % 16 == 15:
			await get_tree().process_frame
	if disable_production:
		runtime.production_coordinator.set_authoritative_processing_enabled(false)
	if disable_visuals:
		runtime.hide()
	for frame in warmup_frames:
		await get_tree().physics_frame
	Enemy.set_performance_metrics_enabled(detailed_metrics)
	var simulation := runtime.get_enemy_simulation_coordinator()
	simulation.get_metrics(true)
	var alive_at_sample_start := _enemy_instances.filter(func(e): return is_instance_valid(e) and not e.is_dead).size()
	_started_sampling = true
	for frame in sample_frames:
		await get_tree().physics_frame
	_started_sampling = false
	var measurements := {
		"buildings_requested": building_count,
		"enemies_requested": enemy_count,
		"enemies_alive_at_sample_start": alive_at_sample_start,
		"enemy_wave": enemy_wave_path,
		"enemy_cohort": cohort.summarize(enemy_paths),
		"detailed_metrics": detailed_metrics,
		"buildings_alive": _building_instances.filter(func(b): return is_instance_valid(b) and not b.is_dead).size(),
		"enemies_alive": _enemy_instances.filter(func(e): return is_instance_valid(e) and not e.is_dead).size(),
		"frames": sample_frames,
		"warmup_frames": warmup_frames,
		"renderer": RenderingServer.get_current_rendering_method(),
		"headless": DisplayServer.get_name() == "headless",
		"frame_ms": _summarize(_samples),
		"physics_interval_ms": _summarize(_physics_samples),
		"native_physics_ms": _summarize(_native_physics_samples),
		"native_process_ms": _summarize(_native_process_samples),
		"render_gpu_ms": _summarize(_gpu_samples),
		"render_cpu_ms": _summarize(_render_cpu_samples),
		"enemy": Enemy.get_performance_metrics(true),
		"simulation": simulation.get_metrics(true),
		"nodes": Performance.get_monitor(Performance.OBJECT_NODE_COUNT),
		"objects": Performance.get_monitor(Performance.OBJECT_COUNT),
		"static_memory_bytes": Performance.get_monitor(Performance.MEMORY_STATIC),
		"collision_pairs": Performance.get_monitor(Performance.PHYSICS_2D_COLLISION_PAIRS),
		"draw_calls": Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME),
		"production_disabled": disable_production,
		"visuals_disabled": disable_visuals,
		"active_production": active_production,
		"water_produced_total": runtime.production_coordinator.get_total_item_count(water),
		"production_storage_metrics": runtime.production_coordinator.get_storage_totals_metrics(),
		"processed_tweens": get_tree().get_processed_tweens().size(),
	}
	Enemy.set_performance_metrics_enabled(false)
	if not screenshot_path.is_empty() and DisplayServer.get_name() != "headless":
		await RenderingServer.frame_post_draw
		get_tree().root.get_texture().get_image().save_png(screenshot_path)
	var output := FileAccess.open(output_path, FileAccess.WRITE)
	output.store_string(JSON.stringify(measurements, "\t"))
	output.close()
	print("DENSITY_RESULT ", JSON.stringify(measurements))
	var production_valid := not active_production or sample_frames < 300 or int(measurements["water_produced_total"]) > 0
	if not production_valid:
		push_error("Active production completed no water during the density sample")
	_finish(0 if production_valid else 5)


func _wait_for_runtime_preparation() -> bool:
	while is_instance_valid(runtime):
		var preparation := runtime.get_runtime_preparation_snapshot()
		match preparation.state:
			RuntimePreparationProvider.PreparationState.READY:
				return true
			RuntimePreparationProvider.PreparationState.FAILED:
				push_error(preparation.failure_reason)
				return false
		await get_tree().process_frame
	return false


func _finish(exit_code: int) -> void:
	if _finishing:
		return
	_finishing = true
	_started_sampling = false
	set_process(false)
	set_physics_process(false)
	Enemy.set_performance_metrics_enabled(false)
	if is_instance_valid(runtime):
		runtime.prepare_for_scene_teardown()
		get_tree().current_scene = null
		runtime.queue_free()
	_building_instances.clear()
	_enemy_instances.clear()
	result["exit_code"] = exit_code
	queue_free()



func _summarize(values: Array[float]) -> Dictionary:
	if values.is_empty():
		return {}
	values.sort()
	return {
		"count": values.size(),
		"mean": values.reduce(func(total, value): return total + value, 0.0) / values.size(),
		"p50": values[int((values.size() - 1) * 0.5)],
		"p95": values[int((values.size() - 1) * 0.95)],
		"p99": values[int((values.size() - 1) * 0.99)],
		"max": values[-1],
	}
