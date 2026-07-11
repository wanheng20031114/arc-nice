extends Node2D
class_name PlantPlacementController

signal state_changed(previous_state: PlacementState, current_state: PlacementState)
signal placement_mode_changed(active: bool)
signal player_lock_requested(locked: bool)
signal plant_placed(plant: PlantDefense, config: PlantDefenseConfig)
signal placement_cancelled
signal selection_unavailable

enum PlacementState {
	IDLE,
	SELECTING,
	PLACING,
}

const PLACEMENT_MARKER_SCENE := preload(
	"res://scene/plant_defense/plant_placement_marker.tscn"
)

@export_range(1.0, 16.0, 0.5) var click_tolerance_world := 6.0
@export_range(0.05, 1.0, 0.05) var marker_refresh_interval := 0.2

@onready var marker_container: Node2D = $MarkerContainer
@onready var preview: PlantPlacementPreview = $PlantPlacementPreview
@onready var selection_hud: PlantSelectionHUD = $PlantSelectionHUD
@onready var placement_hint_root: Control = $PlacementInstructions/Root
@onready var placement_hint_label: Label = $PlacementInstructions/Root/Bottom/Panel/Margin/HintLabel

var plant_system: PlantSystem
var owner_player: Player
var placement_state := PlacementState.IDLE
var selected_config: PlantDefenseConfig
var valid_anchors: Array[Vector2i] = []
var markers_by_anchor: Dictionary = {}
var hovered_anchor := Vector2i.ZERO
var has_hovered_anchor := false
var marker_refresh_time_left := 0.0


func _ready() -> void:
	selection_hud.selection_confirmed.connect(_begin_placing)
	selection_hud.cancel_requested.connect(cancel_placement)
	placement_hint_root.hide()
	preview.hide_preview()
	set_process(false)


func setup(new_plant_system: PlantSystem, new_owner_player: Player = null) -> void:
	configure(new_plant_system, new_owner_player)


func configure(new_plant_system: PlantSystem, new_owner_player: Player = null) -> void:
	if placement_state != PlacementState.IDLE:
		cancel_placement()
	_disconnect_owner_player()
	plant_system = new_plant_system
	owner_player = new_owner_player
	if owner_player != null:
		owner_player.died.connect(_on_owner_player_unavailable)
		owner_player.tree_exiting.connect(_on_owner_player_unavailable)


func is_active() -> bool:
	return placement_state != PlacementState.IDLE


func is_selecting() -> bool:
	return placement_state == PlacementState.SELECTING


func is_placing() -> bool:
	return placement_state == PlacementState.PLACING


func open_selection() -> bool:
	if placement_state != PlacementState.IDLE or plant_system == null:
		return false
	if owner_player != null and owner_player.is_dead:
		return false
	var configs := plant_system.get_available_configs()
	if configs.is_empty():
		selection_unavailable.emit()
		return false
	_set_placement_state(PlacementState.SELECTING)
	placement_mode_changed.emit(true)
	player_lock_requested.emit(true)
	if selection_hud.open(configs):
		return true
	cancel_placement()
	selection_unavailable.emit()
	return false


func cancel_placement() -> void:
	if placement_state == PlacementState.IDLE:
		return
	selection_hud.close()
	_clear_world_preview()
	selected_config = null
	_set_placement_state(PlacementState.IDLE)
	placement_mode_changed.emit(false)
	player_lock_requested.emit(false)
	placement_cancelled.emit()


func refresh_valid_positions() -> void:
	if placement_state != PlacementState.PLACING:
		return
	_refresh_valid_markers()
	_update_hover_from_mouse()


func _process(delta: float) -> void:
	if placement_state != PlacementState.PLACING:
		return
	marker_refresh_time_left -= delta
	if marker_refresh_time_left <= 0.0:
		marker_refresh_time_left = marker_refresh_interval
		_refresh_valid_markers()
	_update_hover_from_mouse()


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed(&"plant"):
		if placement_state == PlacementState.IDLE:
			open_selection()
		else:
			cancel_placement()
		get_viewport().set_input_as_handled()
		return

	if placement_state == PlacementState.IDLE:
		return
	if event.is_action_pressed(&"ui_cancel"):
		cancel_placement()
		get_viewport().set_input_as_handled()
		return

	var mouse_event := event as InputEventMouseButton
	if mouse_event == null or not mouse_event.pressed:
		return
	if mouse_event.button_index == MOUSE_BUTTON_RIGHT:
		cancel_placement()
		get_viewport().set_input_as_handled()
		return
	if (
		placement_state == PlacementState.PLACING
		and mouse_event.button_index == MOUSE_BUTTON_LEFT
	):
		_try_place_hovered()
		get_viewport().set_input_as_handled()


func _begin_placing(config: PlantDefenseConfig) -> void:
	if placement_state != PlacementState.SELECTING or config == null:
		return
	selected_config = config
	selection_hud.close()
	_set_placement_state(PlacementState.PLACING)
	preview.configure(selected_config)
	placement_hint_root.show()
	marker_refresh_time_left = 0.0
	set_process(true)
	_refresh_valid_markers()
	_update_hover_from_mouse()


func _refresh_valid_markers() -> void:
	if plant_system == null or selected_config == null:
		_clear_markers()
		return
	valid_anchors = plant_system.get_valid_anchors(selected_config)
	var current_anchor_lookup := {}
	for anchor in valid_anchors:
		current_anchor_lookup[anchor] = true
		var marker := markers_by_anchor.get(anchor) as PlantPlacementMarker
		if marker == null:
			marker = PLACEMENT_MARKER_SCENE.instantiate() as PlantPlacementMarker
			marker_container.add_child(marker)
			markers_by_anchor[anchor] = marker
		marker.setup(
			anchor,
			plant_system.get_anchor_world_position(anchor, selected_config)
		)

	for anchor_variant in markers_by_anchor.keys():
		var anchor: Vector2i = anchor_variant
		if current_anchor_lookup.has(anchor):
			continue
		var stale_marker := markers_by_anchor[anchor] as PlantPlacementMarker
		if stale_marker != null:
			stale_marker.queue_free()
		markers_by_anchor.erase(anchor)
	_update_hint_text()


func _update_hover_from_mouse() -> void:
	var mouse_world_position := get_global_mouse_position()
	var closest_distance_squared := click_tolerance_world * click_tolerance_world
	var next_anchor := Vector2i.ZERO
	var found_anchor := false
	for anchor in valid_anchors:
		var marker := markers_by_anchor.get(anchor) as PlantPlacementMarker
		if marker == null or not is_instance_valid(marker):
			continue
		var distance_squared := mouse_world_position.distance_squared_to(marker.global_position)
		if distance_squared > closest_distance_squared:
			continue
		closest_distance_squared = distance_squared
		next_anchor = anchor
		found_anchor = true
	_set_hovered_anchor(next_anchor, found_anchor)


func _set_hovered_anchor(anchor: Vector2i, has_anchor: bool) -> void:
	if has_hovered_anchor:
		var previous_marker := markers_by_anchor.get(hovered_anchor) as PlantPlacementMarker
		if previous_marker != null and is_instance_valid(previous_marker):
			previous_marker.set_highlighted(false)
	hovered_anchor = anchor
	has_hovered_anchor = has_anchor
	if not has_hovered_anchor:
		preview.hide_preview()
		return
	var marker := markers_by_anchor.get(hovered_anchor) as PlantPlacementMarker
	if marker == null or not is_instance_valid(marker):
		has_hovered_anchor = false
		preview.hide_preview()
		return
	marker.set_highlighted(true)
	preview.show_at(marker.global_position)


func _try_place_hovered() -> void:
	if not has_hovered_anchor or plant_system == null or selected_config == null:
		return
	var placed_plant := plant_system.try_place(selected_config, hovered_anchor)
	if placed_plant == null:
		refresh_valid_positions()
		return
	var placed_config := selected_config
	selection_hud.close()
	_clear_world_preview()
	selected_config = null
	_set_placement_state(PlacementState.IDLE)
	placement_mode_changed.emit(false)
	player_lock_requested.emit(false)
	plant_placed.emit(placed_plant, placed_config)


func _clear_world_preview() -> void:
	set_process(false)
	placement_hint_root.hide()
	preview.hide_preview()
	_clear_markers()


func _clear_markers() -> void:
	for marker_variant in markers_by_anchor.values():
		var marker := marker_variant as PlantPlacementMarker
		if marker != null and is_instance_valid(marker):
			marker.queue_free()
	markers_by_anchor.clear()
	valid_anchors.clear()
	has_hovered_anchor = false


func _update_hint_text() -> void:
	if selected_config == null:
		return
	placement_hint_label.text = "%s  ·  %d 个可放置交点  ·  左键放置  ·  右键 / Esc / 植物键取消" % [
		selected_config.display_name,
		valid_anchors.size(),
	]


func _set_placement_state(next_state: PlacementState) -> void:
	if placement_state == next_state:
		return
	var previous_state := placement_state
	placement_state = next_state
	state_changed.emit(previous_state, placement_state)


func _disconnect_owner_player() -> void:
	if owner_player == null or not is_instance_valid(owner_player):
		return
	if owner_player.died.is_connected(_on_owner_player_unavailable):
		owner_player.died.disconnect(_on_owner_player_unavailable)
	if owner_player.tree_exiting.is_connected(_on_owner_player_unavailable):
		owner_player.tree_exiting.disconnect(_on_owner_player_unavailable)


func _on_owner_player_unavailable() -> void:
	cancel_placement()


func _exit_tree() -> void:
	_disconnect_owner_player()
	if placement_state != PlacementState.IDLE:
		player_lock_requested.emit(false)
