extends PlantDefense
class_name ProductionBuilding

signal production_state_changed

const RUNTIME_STATE_SCHEMA := 1
const INTERACTION_GROUP := PlantDefense.BUILDING_INTERACTION_GROUP
const INTERACTION_SELECTION_REFRESH_SECONDS := 0.08

@export_group("生产配置")
@export var recipes: Array[ProductionRecipe] = []

@onready var interaction_area: Area2D = $InteractionArea
@onready var interaction_prompt: Control = $InteractionPrompt
@onready var prompt_keycap: Control = $InteractionPrompt/PromptMargin/PromptRow/Keycap
@onready var health_bar: PlantHealthBar = $HealthBar

var production_coordinator: ProductionCoordinator = null
var production_panel: ProductionBuildingPanel = null
var nearby_player: Player = null
var is_interaction_target := false
var production_enabled := true
var active_recipe_id: StringName = &""
var progress_elapsed_seconds := 0.0
var completion_wait_reason: StringName = &""
var production_revision := 0
var interaction_selection_refresh_left := 0.0
var prompt_rest_position := Vector2.ZERO
var prompt_tween: Tween = null


func _ready() -> void:
	super._ready()
	add_to_group(INTERACTION_GROUP)
	prompt_rest_position = interaction_prompt.position
	_hide_interaction_prompt()
	set_process(false)
	set_process_unhandled_input(false)
	interaction_area.body_entered.connect(_on_interaction_area_body_entered)
	interaction_area.body_exited.connect(_on_interaction_area_body_exited)


func _process(delta: float) -> void:
	if nearby_player == null or not is_instance_valid(nearby_player):
		nearby_player = null
		_set_interaction_target(false)
		set_process(false)
		return
	interaction_selection_refresh_left -= delta
	if interaction_selection_refresh_left > 0.0:
		return
	interaction_selection_refresh_left = INTERACTION_SELECTION_REFRESH_SECONDS
	_refresh_interaction_selection(nearby_player)


func _unhandled_input(event: InputEvent) -> void:
	if (
		not is_interaction_target
		or nearby_player == null
		or production_panel == null
		or production_panel.is_open()
		or not event.is_action_pressed(&"interact")
		or nearby_player.controls_locked
		or nearby_player.is_dead
	):
		return
	get_viewport().set_input_as_handled()
	production_panel.open_for(self, nearby_player)


func _on_setup_completed() -> void:
	progress_elapsed_seconds = 0.0
	completion_wait_reason = &""
	production_enabled = true
	active_recipe_id = &""
	production_revision = 0
	health_bar.setup(max_health, current_health)
	if not health_changed.is_connected(_on_health_changed):
		health_changed.connect(_on_health_changed)


func _on_operational_started() -> void:
	interaction_area.set_deferred("monitoring", true)


func _on_removal_started(_mode: RemovalMode) -> void:
	var interaction_player := nearby_player
	nearby_player = null
	health_bar.hide()
	set_process(false)
	interaction_area.set_deferred("monitoring", false)
	_set_interaction_target(false)
	close_production_panel()
	_refresh_interaction_selection(interaction_player)


func set_production_coordinator(coordinator: ProductionCoordinator) -> void:
	production_coordinator = coordinator


func set_shared_production_panel(shared_panel: ProductionBuildingPanel) -> void:
	if production_panel == shared_panel:
		return
	close_production_panel()
	production_panel = shared_panel


func close_production_panel() -> void:
	if _has_bound_production_panel():
		production_panel.close()


func is_modal_ui_open() -> bool:
	return _has_bound_production_panel() and production_panel.is_open()


func get_interaction_player() -> Player:
	return nearby_player


func set_interaction_target_selected(selected: bool) -> void:
	_set_interaction_target(selected)


func get_recipe(recipe_id: StringName) -> ProductionRecipe:
	for recipe in recipes:
		if recipe != null and recipe.recipe_id == recipe_id:
			return recipe
	return null


func get_active_recipe() -> ProductionRecipe:
	return get_recipe(active_recipe_id)


func get_display_recipe() -> ProductionRecipe:
	var active_recipe := get_active_recipe()
	if active_recipe != null:
		return active_recipe
	for recipe in recipes:
		if recipe != null and recipe.is_valid():
			return recipe
	return null


func select_recipe(recipe_id: StringName) -> bool:
	var recipe := get_recipe(recipe_id)
	if recipe == null or not recipe.is_valid():
		return false
	if active_recipe_id == recipe_id:
		return true
	active_recipe_id = recipe_id
	progress_elapsed_seconds = 0.0
	completion_wait_reason = &""
	_bump_production_state()
	return true


func set_production_enabled(enabled: bool) -> void:
	if production_enabled == enabled:
		return
	production_enabled = enabled
	# Pausing always discards the partial cycle, including a ready-but-blocked
	# cycle at zero remaining time.
	progress_elapsed_seconds = 0.0
	completion_wait_reason = &""
	_bump_production_state()


func advance_shared_production_tick(delta_seconds: float) -> void:
	if (
		is_multiplayer_proxy
		or not is_operational
		or is_dead
		or is_removing
		or not production_enabled
		or delta_seconds <= 0.0
	):
		return
	var recipe := get_active_recipe()
	if recipe == null or not recipe.is_valid():
		return
	var previous_elapsed := progress_elapsed_seconds
	progress_elapsed_seconds = minf(
		progress_elapsed_seconds + delta_seconds,
		recipe.duration_seconds
	)
	if progress_elapsed_seconds + 0.0001 >= recipe.duration_seconds:
		if try_complete_ready_production():
			return
	if not is_equal_approx(previous_elapsed, progress_elapsed_seconds):
		_bump_production_state()


func try_complete_ready_production() -> bool:
	if (
		is_multiplayer_proxy
		or not is_operational
		or is_dead
		or is_removing
		or not production_enabled
		or production_coordinator == null
	):
		return false
	var recipe := get_active_recipe()
	if (
		recipe == null
		or not recipe.is_valid()
		or progress_elapsed_seconds + 0.0001 < recipe.duration_seconds
	):
		return false
	var result := production_coordinator.try_commit_recipe(recipe)
	if result == ProductionCoordinator.RESULT_SUCCESS:
		progress_elapsed_seconds = 0.0
		completion_wait_reason = &""
		_bump_production_state()
		return true
	if completion_wait_reason != result:
		completion_wait_reason = result
		_bump_production_state()
	return false


func get_progress_ratio() -> float:
	var recipe := get_active_recipe()
	if recipe == null or recipe.duration_seconds <= 0.0:
		return 0.0
	return clampf(progress_elapsed_seconds / recipe.duration_seconds, 0.0, 1.0)


func get_remaining_seconds() -> float:
	var recipe := get_active_recipe()
	if recipe == null:
		return 0.0
	return maxf(recipe.duration_seconds - progress_elapsed_seconds, 0.0)


func export_multiplayer_runtime_state() -> Dictionary:
	return {
		"schema": RUNTIME_STATE_SCHEMA,
		"enabled": production_enabled,
		"active_recipe_id": String(active_recipe_id),
		"progress_elapsed_seconds": progress_elapsed_seconds,
		"wait_reason": String(completion_wait_reason),
		"revision": production_revision,
	}


func apply_multiplayer_runtime_state(state: Dictionary, _mapped_sample_time: float) -> void:
	if int(state.get("schema", 0)) != RUNTIME_STATE_SCHEMA:
		return
	var received_revision := int(state.get("revision", 0))
	if received_revision < production_revision:
		return
	var received_recipe_id := StringName(state.get("active_recipe_id", ""))
	if received_recipe_id != &"" and get_recipe(received_recipe_id) == null:
		return
	production_revision = received_revision
	production_enabled = bool(state.get("enabled", true))
	active_recipe_id = received_recipe_id
	var recipe := get_active_recipe()
	progress_elapsed_seconds = clampf(
		float(state.get("progress_elapsed_seconds", 0.0)),
		0.0,
		recipe.duration_seconds if recipe != null else 0.0
	)
	completion_wait_reason = StringName(state.get("wait_reason", ""))
	production_state_changed.emit()


func on_shared_production_panel_opened(panel: ProductionBuildingPanel) -> void:
	if panel != production_panel or not _has_bound_production_panel():
		return
	_set_interaction_target(false)
	_refresh_interaction_selection(nearby_player)
	modal_ui_visibility_changed.emit(true)


func on_shared_production_panel_closed(panel: ProductionBuildingPanel) -> void:
	if panel != production_panel:
		return
	if nearby_player != null:
		_refresh_interaction_selection(nearby_player)
	else:
		_set_interaction_target(false)
	modal_ui_visibility_changed.emit(false)


func _has_bound_production_panel() -> bool:
	return (
		production_panel != null
		and is_instance_valid(production_panel)
		and production_panel.is_bound_to_building(self)
	)


func _bump_production_state() -> void:
	production_revision += 1
	production_state_changed.emit()


func _on_interaction_area_body_entered(body: Node2D) -> void:
	var player := body as Player
	if player == null or not player.uses_local_input or player.is_dead:
		return
	nearby_player = player
	interaction_selection_refresh_left = 0.0
	set_process(true)
	_refresh_interaction_selection(player)


func _on_interaction_area_body_exited(body: Node2D) -> void:
	if body != nearby_player:
		return
	var exiting_player := nearby_player
	nearby_player = null
	set_process(false)
	_set_interaction_target(false)
	close_production_panel()
	_refresh_interaction_selection(exiting_player)


func _refresh_interaction_selection(player: Player) -> void:
	if player == null or not is_instance_valid(player) or get_tree() == null:
		return
	var nearby_buildings: Array[PlantDefense] = []
	var nearest_building: PlantDefense = null
	var nearest_distance_squared := INF
	var building_panel_is_open := false
	for node in get_tree().get_nodes_in_group(INTERACTION_GROUP):
		var building := node as PlantDefense
		if (
			building == null
			or not is_instance_valid(building)
			or building.is_queued_for_deletion()
			or building.get_interaction_player() != player
		):
			continue
		nearby_buildings.append(building)
		if building.is_modal_ui_open():
			building_panel_is_open = true
		if building.is_dead or building.is_removing or building.is_modal_ui_open():
			continue
		var distance_squared := player.global_position.distance_squared_to(
			building.global_position
		)
		var wins_distance_tie := (
			is_equal_approx(distance_squared, nearest_distance_squared)
			and (
				nearest_building == null
				or building.global_position.y < nearest_building.global_position.y
				or (
					is_equal_approx(
						building.global_position.y,
						nearest_building.global_position.y
					)
					and (
						building.global_position.x < nearest_building.global_position.x
						or (
							is_equal_approx(
								building.global_position.x,
								nearest_building.global_position.x
							)
							and building.get_instance_id() < nearest_building.get_instance_id()
						)
					)
				)
			)
		)
		if distance_squared < nearest_distance_squared or wins_distance_tie:
			nearest_building = building
			nearest_distance_squared = distance_squared
	var can_select := (
		not building_panel_is_open
		and not player.is_dead
		and not player.controls_locked
	)
	for building in nearby_buildings:
		building.set_interaction_target_selected(
			can_select and building == nearest_building
		)


func _set_interaction_target(should_be_target: bool) -> void:
	if is_interaction_target == should_be_target:
		set_process_unhandled_input(should_be_target)
		if not should_be_target and interaction_prompt.visible:
			_hide_interaction_prompt()
		return
	is_interaction_target = should_be_target
	set_process_unhandled_input(should_be_target)
	if should_be_target:
		_show_interaction_prompt()
	else:
		_hide_interaction_prompt()


func _show_interaction_prompt() -> void:
	_stop_prompt_tween()
	interaction_prompt.position = prompt_rest_position + Vector2(0, 1)
	interaction_prompt.modulate = Color(1, 1, 1, 0)
	prompt_keycap.modulate = Color(1, 1, 0.72, 1)
	interaction_prompt.show()
	prompt_tween = create_tween().set_parallel(true)
	prompt_tween.tween_property(interaction_prompt, "modulate:a", 1.0, 0.08)
	prompt_tween.tween_method(_set_prompt_reveal_offset, 1.0, 0.0, 0.08)
	prompt_tween.tween_property(prompt_keycap, "modulate", Color.WHITE, 0.14)


func _hide_interaction_prompt() -> void:
	_stop_prompt_tween()
	interaction_prompt.hide()
	interaction_prompt.position = prompt_rest_position
	interaction_prompt.modulate = Color.WHITE
	prompt_keycap.modulate = Color.WHITE


func _stop_prompt_tween() -> void:
	if prompt_tween != null and prompt_tween.is_valid():
		prompt_tween.kill()
	prompt_tween = null


func _set_prompt_reveal_offset(offset: float) -> void:
	interaction_prompt.position = prompt_rest_position + Vector2(0, roundf(offset))


func _on_health_changed(new_health: int, new_max_health: int) -> void:
	health_bar.set_health(new_health, new_max_health)
