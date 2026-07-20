extends PlantDefense
class_name ResearchCenter

signal research_command_requested(command: Dictionary)
signal multiplayer_research_result(
	success: bool,
	reason: StringName,
	operation: StringName,
	research_id: StringName
)

const INTERACTION_GROUP := PlantDefense.BUILDING_INTERACTION_GROUP
const INTERACTION_SELECTION_REFRESH_SECONDS := 0.08
const MULTIPLAYER_RESEARCH_REQUEST_TIMEOUT_SECONDS := 4.0
const MULTIPLAYER_RESEARCH_COMMAND_SCHEMA := 2
const BORDER_REVEAL_SECONDS := 0.15
const BORDER_WORKING_ACTIVE_PARAMETER := &"working_active"
const BORDER_PROGRESS_VALUE_PARAMETER := &"progress_value"
const BORDER_NOISE_SEED_PARAMETER := &"noise_seed"

@onready var interaction_area: Area2D = $InteractionArea
@onready var interaction_prompt: Control = $InteractionPrompt
@onready var prompt_keycap: Control = $InteractionPrompt/PromptMargin/PromptRow/Keycap
@onready var health_bar: PlantHealthBar = $HealthBar
@onready var research_border: MeshInstance2D = $ResearchBorder
@onready var hotspot_glow: NightPointLight2D = $HotspotGlow
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
var multiplayer_research_pending_operation: StringName = &""
var multiplayer_research_pending_research_id: StringName = &""
var next_multiplayer_research_request_id := 1
var _border_reveal_tween: Tween = null
var _border_working_active := false


func _ready() -> void:
	super._ready()
	add_to_group(INTERACTION_GROUP)
	prompt_rest_position = interaction_prompt.position
	_hide_interaction_prompt()
	set_process(false)
	set_process_unhandled_input(false)
	interaction_area.body_entered.connect(_on_interaction_area_body_entered)
	interaction_area.body_exited.connect(_on_interaction_area_body_exited)
	var seed_source := int(get_instance_id())
	research_border.set_instance_shader_parameter(
		BORDER_NOISE_SEED_PARAMETER,
		float(posmod(seed_source * 43 + 17, 997)) / 997.0
	)
	research_border.set_instance_shader_parameter(
		BORDER_WORKING_ACTIVE_PARAMETER,
		false
	)
	_sync_research_border()


func _exit_tree() -> void:
	_disconnect_research_coordinator()
	_stop_border_reveal_tween()


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
	_sync_research_border()


func _on_construction_started() -> void:
	_stop_border_reveal_tween()
	research_border.hide()
	hotspot_glow.set_emission_allowed(false)


func _on_construction_finished(was_animated: bool) -> void:
	_sync_research_border()
	hotspot_glow.set_emission_allowed(true)
	if not was_animated:
		research_border.modulate.a = 1.0
		research_border.show()
		return
	research_border.modulate.a = 0.0
	research_border.show()
	_border_reveal_tween = create_tween()
	_border_reveal_tween.set_trans(Tween.TRANS_SINE).set_ease(
		Tween.EASE_OUT
	)
	_border_reveal_tween.tween_property(
		research_border,
		"modulate:a",
		1.0,
		BORDER_REVEAL_SECONDS
	)


func _on_operational_started() -> void:
	interaction_area.set_deferred("monitoring", true)
	_sync_research_border()


func _on_removal_started(_mode: RemovalMode) -> void:
	var interaction_player := nearby_player
	nearby_player = null
	_stop_border_reveal_tween()
	research_border.hide()
	hotspot_glow.set_emission_allowed(false)
	health_bar.hide()
	set_process(false)
	interaction_area.set_deferred("monitoring", false)
	_set_interaction_target(false)
	close_research_panel()
	_refresh_interaction_selection(interaction_player)


func set_research_coordinator(coordinator: ResearchCoordinator) -> void:
	if research_coordinator == coordinator:
		_sync_research_border()
		return
	_disconnect_research_coordinator()
	research_coordinator = coordinator
	if (
		research_coordinator != null
		and not research_coordinator.research_state_changed.is_connected(
			_sync_research_border
		)
	):
		research_coordinator.research_state_changed.connect(
			_sync_research_border
		)
	_sync_research_border()


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


func _sync_research_border() -> void:
	if not is_node_ready():
		return
	var active_research_id := (
		research_coordinator.get_active_global_research_id()
		if research_coordinator != null
		else &""
	)
	var working := (
		research_coordinator != null
		and not active_research_id.is_empty()
		and is_operational
		and not is_dead
		and not is_removing
		and (
			research_coordinator.get_global_research_state(
				active_research_id
			)
			== ResearchCoordinator.GlobalResearchState.RESEARCHING
		)
	)
	var progress_start := (
		research_coordinator.get_global_progress_ratio(
			active_research_id
		)
		if working
		else 0.0
	)
	if _border_working_active != working:
		_border_working_active = working
		research_border.set_instance_shader_parameter(
			BORDER_WORKING_ACTIVE_PARAMETER,
			working
		)
	research_border.set_instance_shader_parameter(
		BORDER_PROGRESS_VALUE_PARAMETER,
		progress_start
	)


func _disconnect_research_coordinator() -> void:
	if (
		research_coordinator != null
		and is_instance_valid(research_coordinator)
		and research_coordinator.research_state_changed.is_connected(
			_sync_research_border
		)
	):
		research_coordinator.research_state_changed.disconnect(
			_sync_research_border
		)


func _stop_border_reveal_tween() -> void:
	if (
		_border_reveal_tween != null
		and _border_reveal_tween.is_valid()
	):
		_border_reveal_tween.kill()
	_border_reveal_tween = null


func close_research_panel() -> void:
	if _has_bound_research_panel():
		research_panel.close()


func is_modal_ui_open() -> bool:
	return _has_bound_research_panel() and research_panel.is_open()


func get_interaction_player() -> Player:
	return nearby_player


func set_interaction_target_selected(selected: bool) -> void:
	_set_interaction_target(selected)


func try_start_global_research(
	research_id: StringName = ResearchCoordinator.BUILDING_DEFENSE_RESEARCH_ID
) -> StringName:
	if GlobalResearchRegistry.get_config(research_id) == null:
		return ResearchCoordinator.RESULT_UNAVAILABLE
	if is_multiplayer_proxy:
		return _request_multiplayer_research(&"global", research_id)
	if research_coordinator == null:
		return ResearchCoordinator.RESULT_UNAVAILABLE
	return research_coordinator.try_start_global_research(research_id)


func try_purchase_player_technology(player: Player) -> StringName:
	if is_multiplayer_proxy:
		return _request_multiplayer_research(&"player", &"")
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
	multiplayer_research_pending_operation = &""
	multiplayer_research_pending_research_id = &""
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
	var completed_operation := multiplayer_research_pending_operation
	var completed_research_id := multiplayer_research_pending_research_id
	multiplayer_research_request_pending = false
	multiplayer_research_pending_request_id = 0
	multiplayer_research_pending_operation = &""
	multiplayer_research_pending_research_id = &""
	multiplayer_research_request_timer.stop()
	multiplayer_research_result.emit(
		success,
		reason,
		completed_operation,
		completed_research_id
	)


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


func _request_multiplayer_research(
	operation: StringName,
	research_id: StringName
) -> StringName:
	if (
		not multiplayer_research_enabled
		or multiplayer_research_request_pending
		or building_net_id <= 0
		or multiplayer_research_peer_id <= 0
		or (
			operation == &"global"
			and GlobalResearchRegistry.get_config(research_id) == null
		)
		or (operation == &"player" and not research_id.is_empty())
		or (operation != &"global" and operation != &"player")
	):
		return ResearchCoordinator.RESULT_UNAVAILABLE
	var request_id := next_multiplayer_research_request_id
	next_multiplayer_research_request_id += 1
	multiplayer_research_request_pending = true
	multiplayer_research_pending_request_id = request_id
	multiplayer_research_pending_operation = operation
	multiplayer_research_pending_research_id = research_id
	multiplayer_research_request_timer.start(
		MULTIPLAYER_RESEARCH_REQUEST_TIMEOUT_SECONDS
	)
	research_command_requested.emit({
		"schema": MULTIPLAYER_RESEARCH_COMMAND_SCHEMA,
		"request_id": request_id,
		"building_net_id": building_net_id,
		"peer_id": multiplayer_research_peer_id,
		"operation": String(operation),
		"research_id": String(research_id),
	})
	return ResearchCoordinator.RESULT_REQUEST_SENT


func _on_multiplayer_research_request_timeout() -> void:
	if not multiplayer_research_request_pending:
		return
	var timed_out_operation := multiplayer_research_pending_operation
	var timed_out_research_id := multiplayer_research_pending_research_id
	multiplayer_research_request_pending = false
	multiplayer_research_pending_request_id = 0
	multiplayer_research_pending_operation = &""
	multiplayer_research_pending_research_id = &""
	multiplayer_research_result.emit(
		false,
		ResearchCoordinator.RESULT_UNAVAILABLE,
		timed_out_operation,
		timed_out_research_id
	)


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
