extends PlantDefense
class_name ProductionBuilding

signal production_state_changed
signal production_command_requested(command: Dictionary)
signal production_snapshot_requested(building_net_id: int)
signal multiplayer_production_result(success: bool, reason: StringName)

const RUNTIME_STATE_SCHEMA := 3
const INTERACTION_GROUP := PlantDefense.BUILDING_INTERACTION_GROUP
const INTERACTION_SELECTION_REFRESH_SECONDS := 0.08
const VISUAL_PROJECTION_WINDOW_SECONDS := 1.0
const MULTIPLAYER_PRODUCTION_REQUEST_TIMEOUT_SECONDS := 4.0

enum PanelTheme {
	DEFAULT,
	PLANT,
}

@export_group("生产配置")
@export var recipes: Array[ProductionRecipe] = []
@export var auto_select_first_recipe := false
@export var production_panel_background_override: Texture2D = null
@export var production_panel_theme: PanelTheme = PanelTheme.DEFAULT

@onready var interaction_area: Area2D = $InteractionArea
@onready var interaction_prompt: Control = $InteractionPrompt
@onready var prompt_keycap: Control = $InteractionPrompt/PromptMargin/PromptRow/Keycap
@onready var health_bar: PlantHealthBar = $HealthBar
@onready var multiplayer_production_request_timer: Timer = $MultiplayerProductionRequestTimer

var production_coordinator: ProductionCoordinator = null
var production_panel: ProductionBuildingPanel = null
var nearby_player: Player = null
var is_interaction_target := false
var production_enabled := true
var active_recipe_id: StringName = &""
var progress_elapsed_seconds := 0.0
var completion_wait_reason: StringName = &""
var personal_output_peer_id := 0
var production_revision := 0
var building_net_id := 0
var multiplayer_production_peer_id := 0
var multiplayer_production_enabled := false
var multiplayer_production_snapshot_ready := true
var multiplayer_production_request_pending := false
var multiplayer_production_pending_request_id := 0
var next_multiplayer_production_request_id := 1
var interaction_selection_refresh_left := 0.0
var prompt_rest_position := Vector2.ZERO
var prompt_tween: Tween = null
var _visual_progress_elapsed_at_sync := 0.0
var _visual_progress_sync_msec: int = 0
var _visual_projection_duration_seconds := VISUAL_PROJECTION_WINDOW_SECONDS


func _ready() -> void:
	super._ready()
	add_to_group(INTERACTION_GROUP)
	prompt_rest_position = interaction_prompt.position
	_hide_interaction_prompt()
	set_process(false)
	set_process_unhandled_input(false)
	interaction_area.body_entered.connect(_on_interaction_area_body_entered)
	interaction_area.body_exited.connect(_on_interaction_area_body_exited)
	multiplayer_production_request_timer.timeout.connect(
		_on_multiplayer_production_request_timeout
	)


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
	personal_output_peer_id = 0
	if auto_select_first_recipe:
		for recipe in recipes:
			if recipe != null and recipe.is_valid():
				active_recipe_id = recipe.recipe_id
				break
	production_revision = 0
	_sync_visual_progress_clock()
	health_bar.setup(max_health, current_health)
	if not health_changed.is_connected(_on_health_changed):
		health_changed.connect(_on_health_changed)


func _on_operational_started() -> void:
	_sync_visual_progress_clock()
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


func uses_environment_source() -> bool:
	var recipe := get_display_recipe()
	return recipe != null and recipe.uses_environment_source()


func is_player_within_multiplayer_interaction_distance(
	player: Player,
	maximum_distance: float
) -> bool:
	return (
		player != null
		and is_instance_valid(player)
		and maximum_distance >= 0.0
		and player.global_position.distance_squared_to(global_position)
		<= maximum_distance * maximum_distance
	)


func configure_multiplayer_production(
	new_building_net_id: int,
	peer_id: int,
	snapshot_ready: bool = false
) -> void:
	var normalized_building_net_id := maxi(new_building_net_id, 0)
	var normalized_peer_id := maxi(peer_id, 0)
	var will_be_enabled := normalized_building_net_id > 0 and normalized_peer_id > 0
	var identity_changed := (
		building_net_id != normalized_building_net_id
		or multiplayer_production_peer_id != normalized_peer_id
	)
	if not identity_changed and multiplayer_production_enabled == will_be_enabled:
		if snapshot_ready and not multiplayer_production_snapshot_ready:
			set_multiplayer_production_snapshot_ready(true)
		return
	building_net_id = normalized_building_net_id
	multiplayer_production_peer_id = normalized_peer_id
	multiplayer_production_enabled = will_be_enabled
	multiplayer_production_snapshot_ready = snapshot_ready or not will_be_enabled
	multiplayer_production_request_pending = false
	multiplayer_production_pending_request_id = 0
	multiplayer_production_request_timer.stop()
	production_state_changed.emit()


func set_multiplayer_production_snapshot_ready(is_ready: bool) -> void:
	multiplayer_production_snapshot_ready = is_ready or not multiplayer_production_enabled
	if multiplayer_production_snapshot_ready and not multiplayer_production_request_pending:
		multiplayer_production_request_timer.stop()
	production_state_changed.emit()


func is_multiplayer_production_ready() -> bool:
	return (
		is_operational
		and not is_dead
		and not is_removing
		and multiplayer_production_enabled
		and multiplayer_production_snapshot_ready
		and not multiplayer_production_request_pending
	)


func request_multiplayer_recipe_selection(recipe_id: StringName) -> bool:
	var recipe := get_recipe(recipe_id)
	if not is_multiplayer_production_ready() or recipe == null or not recipe.is_valid():
		return false
	var command := ProductionBuildingProtocol.make_select_recipe_command(
		next_multiplayer_production_request_id,
		building_net_id,
		multiplayer_production_peer_id,
		production_revision,
		recipe_id
	)
	return _submit_multiplayer_production_command(command)


func request_multiplayer_enabled_change(enabled: bool) -> bool:
	if not is_multiplayer_production_ready():
		return false
	var command := ProductionBuildingProtocol.make_set_enabled_command(
		next_multiplayer_production_request_id,
		building_net_id,
		multiplayer_production_peer_id,
		production_revision,
		enabled
	)
	return _submit_multiplayer_production_command(command)


func request_multiplayer_production_snapshot() -> bool:
	if not multiplayer_production_enabled or building_net_id <= 0:
		return false
	set_multiplayer_production_snapshot_ready(false)
	multiplayer_production_request_timer.start(
		MULTIPLAYER_PRODUCTION_REQUEST_TIMEOUT_SECONDS
	)
	production_snapshot_requested.emit(building_net_id)
	return true


func complete_multiplayer_production_request(result: Dictionary) -> bool:
	if not is_current_multiplayer_production_result(result):
		return false
	multiplayer_production_request_pending = false
	multiplayer_production_pending_request_id = 0
	multiplayer_production_snapshot_ready = true
	multiplayer_production_request_timer.stop()
	multiplayer_production_result.emit(
		bool(result.get("success", false)),
		StringName(result.get(
			"reason",
			ProductionBuildingProtocol.RESULT_INVALID_COMMAND
		))
	)
	production_state_changed.emit()
	return true


func is_current_multiplayer_production_result(result: Dictionary) -> bool:
	return (
		multiplayer_production_enabled
		and multiplayer_production_request_pending
		and ProductionBuildingProtocol.get_int_field(result, "request_id", 0)
		== multiplayer_production_pending_request_id
		and ProductionBuildingProtocol.get_int_field(result, "building_net_id", 0)
		== building_net_id
		and ProductionBuildingProtocol.get_int_field(result, "peer_id", 0)
		== multiplayer_production_peer_id
	)


func select_recipe(
	recipe_id: StringName,
	output_peer_id: int = 0
) -> bool:
	if is_multiplayer_proxy:
		return false
	var recipe := get_recipe(recipe_id)
	if recipe == null or not recipe.is_valid():
		return false
	var next_output_peer_id := (
		maxi(output_peer_id, 0)
		if recipe.outputs_to_player_inventory()
		else 0
	)
	if (
		active_recipe_id == recipe_id
		and personal_output_peer_id == next_output_peer_id
	):
		return true
	active_recipe_id = recipe_id
	personal_output_peer_id = next_output_peer_id
	progress_elapsed_seconds = 0.0
	completion_wait_reason = &""
	_bump_production_state()
	return true


func set_production_enabled(enabled: bool) -> bool:
	if is_multiplayer_proxy:
		return false
	if production_enabled == enabled:
		return true
	production_enabled = enabled
	# Pausing always discards the partial cycle, including a ready-but-blocked
	# cycle at zero remaining time.
	progress_elapsed_seconds = 0.0
	completion_wait_reason = &""
	_bump_production_state()
	return true


func apply_authoritative_multiplayer_production_command(
	command: Dictionary
) -> StringName:
	if not ProductionBuildingProtocol.is_valid_command(command):
		return ProductionBuildingProtocol.RESULT_INVALID_COMMAND
	if is_multiplayer_proxy or is_dead or is_removing or not is_operational:
		return ProductionBuildingProtocol.RESULT_UNAVAILABLE
	if int(command["expected_production_revision"]) != production_revision:
		return ProductionBuildingProtocol.RESULT_STALE_STATE
	match ProductionBuildingProtocol.get_operation(command):
		ProductionBuildingProtocol.OPERATION_SELECT_RECIPE:
			var recipe_id := StringName(command["recipe_id"])
			var recipe := get_recipe(recipe_id)
			if recipe == null or not recipe.is_valid():
				return ProductionBuildingProtocol.RESULT_INVALID_RECIPE
			return (
				ProductionBuildingProtocol.RESULT_SUCCESS
				if select_recipe(
					recipe_id,
					ProductionBuildingProtocol.get_int_field(
						command,
						"peer_id",
						0
					)
				)
				else ProductionBuildingProtocol.RESULT_UNAVAILABLE
			)
		ProductionBuildingProtocol.OPERATION_SET_ENABLED:
			return (
				ProductionBuildingProtocol.RESULT_SUCCESS
				if set_production_enabled(bool(command["enabled"]))
				else ProductionBuildingProtocol.RESULT_UNAVAILABLE
			)
		_:
			return ProductionBuildingProtocol.RESULT_INVALID_COMMAND


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
	var result := production_coordinator.try_commit_recipe(
		recipe,
		personal_output_peer_id
	)
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


## Smooth display state projected only until the next shared one-second logic
## tick. It cannot advance authoritative production, consume items or emit
## network state, so a stalled tick never grants progress.
func get_visual_progress_elapsed_seconds() -> float:
	var recipe := get_active_recipe()
	if recipe == null or not recipe.is_valid():
		return 0.0
	var visual_elapsed := clampf(
		_visual_progress_elapsed_at_sync,
		0.0,
		recipe.duration_seconds
	)
	if _should_project_visual_progress(recipe):
		var elapsed_since_sync := maxf(
			float(Time.get_ticks_msec() - _visual_progress_sync_msec) / 1000.0,
			0.0
		)
		var projection_fraction := clampf(
			elapsed_since_sync / maxf(_visual_projection_duration_seconds, 0.001),
			0.0,
			1.0
		)
		visual_elapsed += minf(
			VISUAL_PROJECTION_WINDOW_SECONDS,
			maxf(
				recipe.duration_seconds - visual_elapsed,
				0.0
			)
		) * projection_fraction
	return clampf(visual_elapsed, 0.0, recipe.duration_seconds)


func get_visual_progress_ratio() -> float:
	var recipe := get_active_recipe()
	if recipe == null or not recipe.is_valid():
		return 0.0
	return clampf(
		get_visual_progress_elapsed_seconds() / recipe.duration_seconds,
		0.0,
		1.0
	)


func get_visual_remaining_seconds() -> float:
	var recipe := get_active_recipe()
	if recipe == null:
		return 0.0
	return maxf(
		recipe.duration_seconds - get_visual_progress_elapsed_seconds(),
		0.0
	)


func get_visual_projection_duration_seconds() -> float:
	return _visual_projection_duration_seconds


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
		"personal_output_peer_id": personal_output_peer_id,
		"revision": production_revision,
		"projection_duration_seconds": get_visual_projection_duration_seconds(),
	}


func apply_multiplayer_runtime_state(state: Dictionary, mapped_sample_time: float) -> void:
	if not is_multiplayer_proxy:
		return
	if (
		typeof(state.get("schema")) != TYPE_INT
		or int(state["schema"]) != RUNTIME_STATE_SCHEMA
		or typeof(state.get("revision")) != TYPE_INT
		or typeof(state.get("enabled")) != TYPE_BOOL
		or typeof(state.get("active_recipe_id")) not in [TYPE_STRING, TYPE_STRING_NAME]
		or typeof(state.get("progress_elapsed_seconds")) not in [TYPE_INT, TYPE_FLOAT]
		or typeof(state.get("wait_reason")) not in [TYPE_STRING, TYPE_STRING_NAME]
		or typeof(state.get("personal_output_peer_id")) != TYPE_INT
		or typeof(state.get("projection_duration_seconds")) not in [TYPE_INT, TYPE_FLOAT]
	):
		return
	var received_progress := float(state["progress_elapsed_seconds"])
	var received_projection := float(state["projection_duration_seconds"])
	if not is_finite(received_progress) or not is_finite(received_projection):
		return
	var received_revision := int(state["revision"])
	var received_output_peer_id := int(state["personal_output_peer_id"])
	if received_revision < 0 or received_output_peer_id < 0:
		return
	if received_revision < production_revision:
		return
	var received_recipe_id := StringName(state["active_recipe_id"])
	if received_recipe_id != &"" and get_recipe(received_recipe_id) == null:
		return
	production_revision = received_revision
	production_enabled = bool(state["enabled"])
	active_recipe_id = received_recipe_id
	personal_output_peer_id = received_output_peer_id
	var recipe := get_active_recipe()
	progress_elapsed_seconds = clampf(
		received_progress,
		0.0,
		recipe.duration_seconds if recipe != null else 0.0
	)
	completion_wait_reason = StringName(state["wait_reason"])
	_sync_visual_progress_clock()
	_visual_projection_duration_seconds = clampf(
		received_projection,
		0.001,
		VISUAL_PROJECTION_WINDOW_SECONDS
	)
	var sample_age_seconds := maxf(
		float(Time.get_ticks_msec()) / 1000.0 - mapped_sample_time,
		0.0
	)
	_visual_progress_sync_msec -= int(
		minf(sample_age_seconds, _visual_projection_duration_seconds) * 1000.0
	)
	if multiplayer_production_enabled:
		multiplayer_production_snapshot_ready = true
		if not multiplayer_production_request_pending:
			multiplayer_production_request_timer.stop()
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
	_sync_visual_progress_clock()
	production_state_changed.emit()


func _submit_multiplayer_production_command(command: Dictionary) -> bool:
	if not ProductionBuildingProtocol.is_valid_command(command):
		return false
	var request_id := ProductionBuildingProtocol.get_int_field(
		command,
		"request_id",
		0
	)
	multiplayer_production_request_pending = true
	multiplayer_production_pending_request_id = request_id
	next_multiplayer_production_request_id = maxi(
		next_multiplayer_production_request_id,
		request_id + 1
	)
	multiplayer_production_request_timer.start(
		MULTIPLAYER_PRODUCTION_REQUEST_TIMEOUT_SECONDS
	)
	production_state_changed.emit()
	production_command_requested.emit(command)
	return true


func _on_multiplayer_production_request_timeout() -> void:
	if not multiplayer_production_enabled:
		return
	if (
		not multiplayer_production_request_pending
		and multiplayer_production_snapshot_ready
	):
		return
	multiplayer_production_request_pending = false
	multiplayer_production_pending_request_id = 0
	multiplayer_production_snapshot_ready = false
	production_state_changed.emit()
	multiplayer_production_request_timer.start(
		MULTIPLAYER_PRODUCTION_REQUEST_TIMEOUT_SECONDS
	)
	production_snapshot_requested.emit(building_net_id)


func _sync_visual_progress_clock() -> void:
	var recipe := get_active_recipe()
	var maximum_elapsed := recipe.duration_seconds if recipe != null else 0.0
	_visual_progress_elapsed_at_sync = clampf(
		progress_elapsed_seconds,
		0.0,
		maximum_elapsed
	)
	_visual_progress_sync_msec = Time.get_ticks_msec()
	_visual_projection_duration_seconds = (
		production_coordinator.get_seconds_until_next_tick()
		if production_coordinator != null
		else VISUAL_PROJECTION_WINDOW_SECONDS
	)


func _should_project_visual_progress(recipe: ProductionRecipe) -> bool:
	return (
		recipe != null
		and is_operational
		and not is_dead
		and not is_removing
		and production_enabled
		and completion_wait_reason == &""
		and _visual_progress_elapsed_at_sync + 0.0001 < recipe.duration_seconds
	)


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
		if PlantDefense.is_interaction_candidate_preferred(
			building,
			distance_squared,
			nearest_building,
			nearest_distance_squared
		):
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
