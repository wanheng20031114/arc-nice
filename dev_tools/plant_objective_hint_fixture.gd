extends Node

var result: Dictionary = {}
var _failures: Array[String] = []
var _assertions := 0
var _runtime: TowerDefenseGame
var _plants: Array[PlantDefense] = []

func _ready() -> void:
	_run.call_deferred()

func _run() -> void:
	(get_tree().root.get_node("RunState") as RunStateStore).begin_new_run(&"weishidaier", false)
	_runtime = load("res://scene/game_modes/tower_defense/tower_defense_game.tscn").instantiate() as TowerDefenseGame
	_runtime.auto_start_waves = false
	_runtime.day_phase_announcements_enabled = false
	_runtime.defer_runtime_activation()
	get_tree().root.add_child(_runtime)
	get_tree().current_scene = _runtime
	while _runtime.get_runtime_preparation_snapshot().state == RuntimePreparationProvider.PreparationState.PREPARING:
		await get_tree().process_frame
	_check(_runtime.get_runtime_preparation_snapshot().state == RuntimePreparationProvider.PreparationState.READY, "Real TD runtime prepared")
	_runtime.activate_runtime()
	_runtime.plant_terrain_decay_timer.stop()
	var system := _runtime.plant_system
	for i in 400:
		var plant_id := &"water_collector" if i % 4 == 0 else &"corn_machine_gun"
		var config := system.get_config(plant_id)
		var plant := system._instantiate_registered_plant(config, Vector2i(1 + (i % 20) * 2, 3 + (i / 20) * 2), _runtime.player, i + 1, false, -1, 0, -1, false)
		_check(plant != null, "Real building registered")
		_plants.append(plant)
	_runtime.process_mode = Node.PROCESS_MODE_DISABLED
	var random := RandomNumberGenerator.new()
	random.seed = 20260908
	for i in 120:
		var center := _plants[random.randi_range(0, 399)].global_position + Vector2(random.randf_range(-60, 60), random.randf_range(-60, 60))
		var radius := [0.0, 1.0, 3.0, 12.0, 100.0][i % 5] as float
		var include_water := i % 2 == 0
		var previous := system.find_nearest_enemy_objective(center, radius, include_water)
		_compare(center, radius, include_water, {}, previous)
		_compare(center, radius, include_water, {}, _plants[random.randi_range(0, 399)])
		if previous != null:
			_compare(center, radius, include_water, {previous.get_instance_id(): true}, previous)
	# Same world targets under rotated/non-uniformly scaled/skewed map coordinates
	# must still use logical distances; no world-distance shortcut is permitted.
	var original_transform := system.ground_tile_map.global_transform
	for transform in [Transform2D(0.4, Vector2(1.7, 0.8), 0.2, Vector2(25, -11)), Transform2D(-0.8, Vector2(0.6, 2.0), -0.1, Vector2(-50, 17))]:
		system.ground_tile_map.global_transform = transform
		for i in 30:
			var center := _plants[i * 7].global_position + Vector2(12, -7)
			var previous := system.find_nearest_enemy_objective(center, 12, true)
			_compare(center, 12, true, {}, previous)
			_compare(center, 12, false, {}, previous)
	system.ground_tile_map.global_transform = original_transform
	# A previous target never overrides eligibility, retirement, water filtering,
	# registration ownership, maximum radius, or a newly closer building.
	var center := _plants[101].global_position + Vector2(0, 16)
	var previous := system.find_nearest_enemy_objective(center, 12, true)
	_compare(center, 12, false, {}, _plants[100])
	previous.is_dead = true
	_compare(center, 12, true, {}, previous)
	previous.is_dead = false
	previous.is_removing = true
	_compare(center, 12, true, {}, previous)
	previous.is_removing = false
	var fence_config := system.get_config(&"simple_fence")
	var fence := system._instantiate_registered_plant(fence_config, Vector2i(70, 70), _runtime.player, 1001, false, -1, 0, -1, false)
	_check(not system._enemy_target_plants.has(fence), "Contact-only fence is outside proactive index")
	_compare(fence.global_position, 100, true, {}, fence)
	var foreign := fence_config.plant_scene.instantiate() as PlantDefense
	add_child(foreign)
	foreign.global_position = center
	_compare(center, 12, true, {}, foreign)
	var closer_config := system.get_config(&"corn_machine_gun")
	var closer := system._instantiate_registered_plant(closer_config, Vector2i(80, 80), _runtime.player, 1002, false, -1, 0, -1, false)
	closer.global_position = center
	system._enemy_target_spatial_index.update(closer, center)
	_check(system.find_nearest_enemy_objective(center, 12, true, {}, previous) == closer, "New closer target replaces valid old objective")
	_compare(center, 12, true, {}, previous)
	closer.queue_free()
	_compare(center, 12, true, {}, closer)
	for invalid_center in [Vector2(INF, 0), Vector2(NAN, 0)]:
		_compare(invalid_center, 12, true, {}, previous)
	for radius in [-1.0, INF, NAN]:
		_compare(center, radius, true, {}, previous)
	var benchmark_center := _plants[210].global_position + Vector2(5, 5)
	var benchmark_hint := system.find_nearest_enemy_objective(benchmark_center, 12, true)
	var measurements: Array[Dictionary] = []
	for mode in [false, true, true, false, false, true, true, false]:
		var start := Time.get_ticks_usec()
		var correct := true
		for i in 500:
			var selected := system.find_nearest_enemy_objective(benchmark_center, 12, true, {}, benchmark_hint if mode else null)
			correct = correct and selected == benchmark_hint
		measurements.append({"hint": mode, "usec": Time.get_ticks_usec() - start})
		_check(correct, "Benchmark preserves selected target")
	print("PLANT_OBJECTIVE_HINT_REGRESSION ", JSON.stringify({"assertions": _assertions, "failures": _failures, "abBA_500_queries": measurements}))
	_runtime.prepare_for_scene_teardown()
	get_tree().current_scene = null
	_runtime.queue_free()
	_runtime = null
	result["exit_code"] = 0 if _failures.is_empty() else 1
	queue_free()

func _compare(center: Vector2, radius: float, include_water: bool, excluded: Dictionary, previous: PlantDefense) -> void:
	var system := _runtime.plant_system
	var without_hint := system.find_nearest_enemy_objective(center, radius, include_water, excluded)
	var with_hint := system.find_nearest_enemy_objective(center, radius, include_water, excluded, previous)
	_check(with_hint == without_hint, "Bounded candidates preserve full-radius nearest and footprint tie order")

func _check(condition: bool, message: String) -> void:
	_assertions += 1
	if not condition:
		_failures.append(message)
		push_error(message)
