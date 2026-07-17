extends PlantDefense
class_name ResearchCenter

signal research_command_requested(command: Dictionary)
signal multiplayer_research_result(success: bool, reason: StringName)

const INTERACTION_GROUP := PlantDefense.BUILDING_INTERACTION_GROUP
const INTERACTION_SELECTION_REFRESH_SECONDS := 0.08
const MULTIPLAYER_RESEARCH_REQUEST_TIMEOUT_SECONDS := 4.0

@onready var interaction_area: Area2D = $InteractionArea
@onready var interaction_prompt: Control = $InteractionPrompt
@onready var prompt_keycap: Control = $InteractionPrompt/PromptMargin/PromptRow/Keycap
@onready var health_bar: PlantHealthBar = $HealthBar
@onready var multiplayer_research_request_timer: Timer = $MultiplayerResearchRequestTimer

var research_coordinator: ResearchCoordinator = null
var research_panel: ResearchCenterPanel = null
var nearby_player: Player = null
var is_interaction_target := false
var interaction_selection_refresh_left := 0.0
var prompt_rest_position := Vector2.ZERO
var prompt_tween: Tween = null
var building_net_id := 0
var multiplayer_research_peer_id := 0
var multiplayer_research_enabled := false
var multiplayer_research_request_pending := false
var multiplayer_research_pending_request_id := 0
var next_multiplayer_research_request_id := 1


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
		or research_panel == null
		or research_panel.is_open()
		or not event.is_action_pressed(&"interact")
		or nearby_player.controls_locked
		or nearby_player.is_dead
	):
		return
	get_viewport().set_input_as_handled()
	research_panel.open_for(self, nearby_player)


func _on_setup_completed() -> void:
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
	close_research_panel()
	_refresh_interaction_selection(interaction_player)


func set_research_coordinator(coordinator: ResearchCoordinator) -> void:
	research_coordinator = coordinator


func set_shared_research_panel(panel: ResearchCenterPanel) -> void:
	if research_panel == panel:
		return
	close_research_panel()
	research_panel = panel


func set_research_services(
	coordinator: ResearchCoordinator,
	panel: ResearchCenterPanel
) -> void:
	set_research_coordinator(coordinator)
	set_shared_research_panel(panel)


func close_research_panel() -> void:
	if _has_bound_research_panel():
		research_panel.close()


func is_modal_ui_open() -> bool:
	return _has_bound_research_panel() and research_panel.is_open()


func get_interaction_player() -> Player:
	return nearby_player


func set_interaction_target_selected(selected: bool) -> void:
	_set_interaction_target(selected)


func try_start_global_research() -> StringName:
	if is_multiplayer_proxy:
		return _request_multiplayer_research(&"global")
	if research_coordinator == null:
		return ResearchCoordinator.RESULT_UNAVAILABLE
	return research_coordinator.try_start_global_research()


func try_purchase_player_technology(player: Player) -> StringName:
	if is_multiplayer_proxy:
		return _request_multiplayer_research(&"player")
	if research_coordinator == null:
		return ResearchCoordinator.RESULT_UNAVAILABLE
	return research_coordinator.try_purchase_player_technology(player)


func configure_multiplayer_research(new_building_net_id: int, peer_id: int) -> void:
	var normalized_building_net_id := maxi(new_building_net_id, 0)
	var normalized_peer_id := maxi(peer_id, 0)
	var will_be_enabled := normalized_building_net_id > 0 and normalized_peer_id > 0
	var identity_changed := (
		building_net_id != normalized_building_net_id
		or multiplayer_research_peer_id != normalized_peer_id
	)
	if not identity_changed and multiplayer_research_enabled == will_be_enabled:
		return
	building_net_id = normalized_building_net_id
	multiplayer_research_peer_id = normalized_peer_id
	multiplayer_research_enabled = will_be_enabled
	multiplayer_research_request_pending = false
	multiplayer_research_pending_request_id = 0
	multiplayer_research_request_timer.stop()


func complete_multiplayer_research_request(
	request_id: int,
	success: bool,
	reason: StringName
) -> void:
	if (
		not multiplayer_research_request_pending
		or request_id != multiplayer_research_pending_request_id
	):
		return
	multiplayer_research_request_pending = false
	multiplayer_research_pending_request_id = 0
	multiplayer_research_request_timer.stop()
	multiplayer_research_result.emit(success, reason)


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


func _request_multiplayer_research(operation: StringName) -> StringName:
	if (
		not multiplayer_research_enabled
		or multiplayer_research_request_pending
		or building_net_id <= 0
		or multiplayer_research_peer_id <= 0
	):
		return ResearchCoordinator.RESULT_UNAVAILABLE
	var request_id := next_multiplayer_research_request_id
	next_multiplayer_research_request_id += 1
	multiplayer_research_request_pending = true
	multiplayer_research_pending_request_id = request_id
	multiplayer_research_request_timer.start(
		MULTIPLAYER_RESEARCH_REQUEST_TIMEOUT_SECONDS
	)
	research_command_requested.emit({
		"schema": 1,
		"request_id": request_id,
		"building_net_id": building_net_id,
		"peer_id": multiplayer_research_peer_id,
		"operation": String(operation),
	})
	return ResearchCoordinator.RESULT_REQUEST_SENT


func _on_multiplayer_research_request_timeout() -> void:
	if not multiplayer_research_request_pending:
		return
	multiplayer_research_request_pending = false
	multiplayer_research_pending_request_id = 0
	multiplayer_research_result.emit(false, ResearchCoordinator.RESULT_UNAVAILABLE)


func export_multiplayer_runtime_state() -> Dictionary:
	if research_coordinator == null:
		return {}
	return {
		"schema": 1,
		"research": research_coordinator.export_runtime_state(),
	}


func apply_multiplayer_runtime_state(
	state: Dictionary,
	_mapped_sample_time: float
) -> void:
	if (
		not is_multiplayer_proxy
		or research_coordinator == null
		or int(state.get("schema", 0)) != 1
	):
		return
	var research_state := state.get("research", {}) as Dictionary
	research_coordinator.apply_multiplayer_runtime_state(research_state)


func on_shared_research_panel_opened(panel: ResearchCenterPanel) -> void:
	if panel != research_panel or not _has_bound_research_panel():
		return
	_set_interaction_target(false)
	_refresh_interaction_selection(nearby_player)
	modal_ui_visibility_changed.emit(true)


func on_shared_research_panel_closed(panel: ResearchCenterPanel) -> void:
	if panel != research_panel:
		return
	if nearby_player != null:
		_refresh_interaction_selection(nearby_player)
	else:
		_set_interaction_target(false)
	modal_ui_visibility_changed.emit(false)


func _has_bound_research_panel() -> bool:
	return (
		research_panel != null
		and is_instance_valid(research_panel)
		and research_panel.is_bound_to_building(self)
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
	close_research_panel()
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
		if distance_squared < nearest_distance_squared:
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
	prompt_keycap.modulate = Color(0.65, 0.92, 1.0, 1)
	interaction_prompt.show()
	prompt_tween = create_tween().set_parallel(true)
	prompt_tween.tween_property(interaction_prompt, "modulate:a", 1.0, 0.08)
	prompt_tween.tween_property(interaction_prompt, "position", prompt_rest_position, 0.08)
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


func _on_health_changed(new_health: int, new_max_health: int) -> void:
	health_bar.set_health(new_health, new_max_health)
