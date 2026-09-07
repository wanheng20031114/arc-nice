extends SceneTree

## Production-scene capacity probe. Fixture overrides health to hold the cohort
## constant; combat, targeting, production, visuals and physics remain enabled.
## --headless --path . --script res://dev_tools/tower_density_probe.gd --
## --buildings=400 --enemies=300 --frames=600 --output=res://dev_tools/output/density.json
var runtime: TowerDefenseGame
var building_count := 400
var enemy_count := 300
var sample_frames := 600
var output_path := "res://dev_tools/output/density.json"
var disable_production := false
var disable_visuals := false
var _deadline_msec := 0
var _samples: Array[float] = []
var _physics_samples: Array[float] = []
var _production_samples: Array[float] = []
var _native_physics_samples: Array[float] = []
var _native_process_samples: Array[float] = []
var _enemy_instances: Array[Enemy] = []
var _building_instances: Array[PlantDefense] = []
var _started_sampling := false
var _last_frame_usec := 0
var _last_physics_usec := 0


func _initialize() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--buildings="):
			building_count = int(arg.trim_prefix("--buildings="))
		elif arg.begins_with("--enemies="):
			enemy_count = int(arg.trim_prefix("--enemies="))
		elif arg.begins_with("--frames="):
			sample_frames = int(arg.trim_prefix("--frames="))
		elif arg.begins_with("--output="):
			output_path = arg.trim_prefix("--output=")
		elif arg == "--disable-production":
			disable_production = true
		elif arg == "--disable-visuals":
			disable_visuals = true
	_deadline_msec = Time.get_ticks_msec() + 120000
	_run.call_deferred()


func _process(_delta: float) -> bool:
	if Time.get_ticks_msec() > _deadline_msec:
		push_error("Density probe exceeded 120 seconds")
		quit(2)
	if _started_sampling:
		var now := Time.get_ticks_usec()
		if _last_frame_usec > 0:
			_samples.append(float(now - _last_frame_usec) / 1000.0)
		_last_frame_usec = now
		_native_physics_samples.append(Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS) * 1000.0)
		_native_process_samples.append(Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0)
	return false


func _physics_process(_delta: float) -> bool:
	if _started_sampling:
		var now := Time.get_ticks_usec()
		if _last_physics_usec > 0:
			_physics_samples.append(float(now - _last_physics_usec) / 1000.0)
		_last_physics_usec = now
	return false


func _run() -> void:
	seed(20260908)
	Engine.max_fps = 60
	(root.get_node("RunState") as RunStateStore).begin_new_run(&"weishidaier", false)
	runtime = load("res://scene/game_modes/tower_defense/tower_defense_game.tscn").instantiate()
	runtime.auto_start_waves = false
	runtime.day_phase_announcements_enabled = false
	root.add_child(runtime)
	current_scene = runtime
	runtime.activate_runtime()
	runtime.random_generator.seed = 20260908
	runtime.plant_terrain_decay_timer.stop()
	runtime.player.current_health = 10000000
	runtime.player.max_health = 10000000
	runtime.player.global_position = Vector2(640, 380)
	await process_frame
	print("DENSITY_READY ", runtime.plant_system.placement_area)
	var plant_ids := [&"corn_machine_gun", &"agave_cannon", &"wood_processing_station", &"oak_warehouse"]
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
			quit(3)
			return
		_building_instances.append(building)
		if building is ProductionBuilding:
			var producer := building as ProductionBuilding
			producer.recipe_unlock_checker = Callable()
			if not producer.recipes.is_empty():
				producer.select_recipe(producer.recipes[0].recipe_id)
				producer.set_production_loop_enabled(true)
		if index % 16 == 15:
			await process_frame
	for index in enemy_count:
		var config_path := "res://resources/config/enemies/yuanshi_insect_basic.tres"
		if index % 5 == 0:
			config_path = "res://resources/config/enemies/yuanshi_insect_shell.tres"
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
			await process_frame
	if disable_production:
		runtime.production_coordinator.set_authoritative_processing_enabled(false)
	if disable_visuals:
		runtime.hide()
	for frame in 120:
		await physics_frame
	Enemy.set_performance_metrics_enabled(true)
	var simulation := runtime.get_enemy_simulation_coordinator()
	simulation.get_metrics(true)
	_started_sampling = true
	for frame in sample_frames:
		await physics_frame
	_started_sampling = false
	var result := {
		"buildings_requested": building_count,
		"enemies_requested": enemy_count,
		"buildings_alive": _building_instances.filter(func(b): return is_instance_valid(b) and not b.is_dead).size(),
		"enemies_alive": _enemy_instances.filter(func(e): return is_instance_valid(e) and not e.is_dead).size(),
		"frames": sample_frames,
		"renderer": RenderingServer.get_current_rendering_method(),
		"headless": DisplayServer.get_name() == "headless",
		"frame_ms": _summarize(_samples),
		"physics_interval_ms": _summarize(_physics_samples),
		"native_physics_ms": _summarize(_native_physics_samples),
		"native_process_ms": _summarize(_native_process_samples),
		"enemy": Enemy.get_performance_metrics(true),
		"simulation": simulation.get_metrics(true),
		"nodes": Performance.get_monitor(Performance.OBJECT_NODE_COUNT),
		"objects": Performance.get_monitor(Performance.OBJECT_COUNT),
		"static_memory_bytes": Performance.get_monitor(Performance.MEMORY_STATIC),
		"collision_pairs": Performance.get_monitor(Performance.PHYSICS_2D_COLLISION_PAIRS),
		"draw_calls": Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME),
		"production_disabled": disable_production,
		"visuals_disabled": disable_visuals,
	}
	var output := FileAccess.open(output_path, FileAccess.WRITE)
	output.store_string(JSON.stringify(result, "\t"))
	output.close()
	print("DENSITY_RESULT ", JSON.stringify(result))
	Enemy.set_performance_metrics_enabled(false)
	runtime.prepare_for_scene_teardown()
	current_scene = null
	runtime.queue_free()
	_building_instances.clear()
	_enemy_instances.clear()
	for frame in 6:
		await process_frame
	quit(0)


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
