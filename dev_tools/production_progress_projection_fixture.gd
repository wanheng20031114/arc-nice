extends Node

## Freed before the native SceneTree exits, so its typed gameplay dependencies
## do not outlive GDScriptLanguage during Godot 4.6.2 shutdown.
var result: Dictionary = {}

var _failures: Array[String] = []


func _ready() -> void:
	_run.call_deferred()


func _run() -> void:
	var coordinator := load("res://scene/game_modes/tower_defense/economy/production/production_coordinator.tscn").instantiate() as ProductionCoordinator
	get_tree().root.add_child(coordinator)
	coordinator.production_tick_timer.stop()
	var pause_controller := GameplayPauseController.get_autoload_instance()
	pause_controller.register_context(coordinator, _unused_exit_handler)
	var config := load("res://resources/config/plant_defense/wood_processing_station.tres") as PlantDefenseConfig
	var building := config.plant_scene.instantiate() as ProductionProgressBorderBuilding
	get_tree().root.add_child(building)
	building.setup(config, null, [Vector2i.ZERO])
	coordinator.register_plant(building)
	var recipe := ProductionRecipe.new()
	recipe.recipe_id = &"projection_regression"
	recipe.duration_seconds = 10.0
	var water := load("res://resources/config/materials/material_water_bottle.tres") as PickupConfig
	recipe.input_items = [water]
	recipe.input_amounts = [0]
	recipe.output_items = [water]
	recipe.output_amounts = [1]
	building.recipes.assign([recipe])
	building.recipe_unlock_checker = Callable()
	_check(building.select_recipe(recipe.recipe_id), "Source recipe selection")
	building.progress_elapsed_seconds = 2.0
	building._sync_visual_progress_clock()
	building.production_state_changed.emit(false)
	_check_projection(building, 0.2, 0.3, "ordinary next tick")
	# The existing aura changes a one-second tick into two seconds of work.
	building.add_production_duration_multiplier_modifier(1, 0.5)
	_check_projection(building, 0.2, 0.4, "two-times production aura")
	var state := building.export_multiplayer_runtime_state()
	building.configure_multiplayer_proxy(building.current_health, building.max_health, building.health_revision)
	state["revision"] = int(state["revision"]) + 1
	state["projection_duration_seconds"] = 1.0
	building.apply_multiplayer_runtime_state_with_host_sample(
		state, GameplayPauseController.get_global_gameplay_time_seconds() - 0.5, 100.0
	)
	_check(absf(building.get_visual_progress_ratio() - 0.3) < 0.004, "Delayed snapshot catches up by its age")
	_check_projection(building, 0.2, 0.4, "delayed snapshot border")
	var before_pause := building.get_visual_progress_ratio()
	pause_controller.request_pause(true)
	await get_tree().create_timer(0.15, true).timeout
	_check(absf(building.get_visual_progress_ratio() - before_pause) < 0.001, "Gameplay pause freezes the projection clock")
	pause_controller.request_pause(false)
	await get_tree().create_timer(0.7, true).timeout
	_check(is_equal_approx(building.get_visual_progress_ratio(), 0.4), "Projection stops at the next authoritative tick")
	_check(building.progress_elapsed_seconds == 2.0, "Display projection cannot grant production")
	building.completion_wait_reason = ProductionCoordinator.RESULT_MISSING_INPUT
	building._sync_visual_progress_clock()
	building.production_state_changed.emit(false)
	_check_projection(building, 0.2, 0.2, "missing input remains frozen")
	building.completion_wait_reason = &""
	building.progress_elapsed_seconds = 9.5
	building._sync_visual_progress_clock()
	building.production_state_changed.emit(false)
	_check_projection(building, 0.95, 1.0, "completion clamps to one")
	building.production_enabled = false
	building.production_state_changed.emit(false)
	_check(not bool(building.production_border.get_instance_shader_parameter(&"working_active")), "Stopped building disables active border")
	coordinator.unregister_plant(building)
	_check(not coordinator.is_processing(), "Last producer releases shared visual clock processing")
	pause_controller.unregister_context(coordinator)
	building.queue_free()
	coordinator.queue_free()
	for frame in 3:
		await get_tree().process_frame
	print("PRODUCTION_PROJECTION_REGRESSION ", JSON.stringify({"failures": _failures}))
	result["exit_code"] = 0 if _failures.is_empty() else 1
	queue_free()


func _check_projection(building: ProductionProgressBorderBuilding, start: float, target: float, label: String) -> void:
	var projection := building.get_visual_progress_projection()
	_check(is_equal_approx(projection.x, start) and is_equal_approx(projection.y, target), label)
	var shader_start := float(building.production_border.get_instance_shader_parameter(&"progress_value"))
	var shader_projection: Vector3 = building.production_border.get_instance_shader_parameter(&"progress_projection")
	_check(is_equal_approx(shader_start, start) and is_equal_approx(shader_projection.x, target), label + " shader ratios")
	_check(is_equal_approx(shader_projection.y, projection.z) and is_equal_approx(shader_projection.z, projection.w), label + " shared epoch")


func _unused_exit_handler() -> void:
	pass


func _check(condition: bool, message: String) -> void:
	if not condition:
		_failures.append(message)
		push_error(message)
