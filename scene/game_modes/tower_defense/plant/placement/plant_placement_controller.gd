extends Node2D
class_name PlantPlacementController

signal state_changed(previous_state: PlacementState, current_state: PlacementState)
signal placement_mode_changed(active: bool)
signal player_lock_requested(locked: bool)
signal plant_placed(plant: PlantDefense, config: PlantDefenseConfig)
signal multiplayer_placement_requested(request_id: int, plant_id: StringName, anchor: Vector2i)
signal inventory_placement_requested(
	request_id: int,
	plant_id: StringName,
	anchor: Vector2i,
	slot_index: int,
	expected_inventory_revision: int,
	item_config_path: String
)
signal placement_cancelled
signal selection_unavailable

enum PlacementState {
	IDLE,
	SELECTING,
	PLACING,
}

enum PlacementSource {
	SANDBOX_FREE,
	INVENTORY_ITEM,
	CATALOG_ITEM,
}

const PLACEMENT_MARKER_SCENE := preload(
	"res://scene/game_modes/tower_defense/plant/placement/plant_placement_marker.tscn"
)

@export_range(1.0, 16.0, 0.5) var click_tolerance_world := 6.0
@export_range(0.05, 1.0, 0.05) var marker_refresh_interval := 0.2
@export var free_placement_enabled := false

@onready var marker_container: Node2D = $MarkerContainer
@onready var preview: PlantPlacementPreview = $PlantPlacementPreview
@onready var selection_hud: PlantSelectionHUD = $PlantSelectionHUD
@onready var placement_hint_layer: CanvasLayer = $PlacementInstructions
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
var multiplayer_request_mode := false
var next_multiplayer_request_id := 1
var placement_source := PlacementSource.SANDBOX_FREE
var inventory_slot_index := -1
var inventory_expected_revision := -1
var inventory_item_config_path := ""
var run_state: RunStateStore = null
var production_coordinator: ProductionCoordinator = null
var inventory_peer_id := 0
var placement_input_enabled := true


func _ready() -> void:
	selection_hud.selection_confirmed.connect(_begin_placing)
	selection_hud.cancel_requested.connect(cancel_placement)
	placement_hint_layer.hide()
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


func set_multiplayer_request_mode(enabled: bool) -> void:
	multiplayer_request_mode = enabled


func configure_inventory_catalog(
	new_run_state: RunStateStore,
	new_production_coordinator: ProductionCoordinator,
	new_inventory_peer_id: int,
	allow_free_placement: bool
) -> void:
	_disconnect_catalog_state()
	run_state = new_run_state
	production_coordinator = new_production_coordinator
	inventory_peer_id = maxi(new_inventory_peer_id, 0)
	free_placement_enabled = allow_free_placement
	if (
		run_state != null
		and not run_state.inventory_changed.is_connected(_on_inventory_changed)
	):
		run_state.inventory_changed.connect(_on_inventory_changed)
	if (
		production_coordinator != null
		and not production_coordinator.storage_totals_changed.is_connected(
			_on_shared_storage_totals_changed
		)
	):
		production_coordinator.storage_totals_changed.connect(
			_on_shared_storage_totals_changed
		)


func set_free_placement_enabled(enabled: bool) -> void:
	free_placement_enabled = enabled
	if selection_hud.is_open():
		cancel_placement()


func set_placement_input_enabled(enabled: bool) -> void:
	placement_input_enabled = enabled
	if not enabled:
		cancel_placement()


func notify_multiplayer_placement_rejected(_request_id: int) -> void:
	selection_unavailable.emit()


func is_active() -> bool:
	return placement_state != PlacementState.IDLE


func is_selecting() -> bool:
	return placement_state == PlacementState.SELECTING


func is_placing() -> bool:
	return placement_state == PlacementState.PLACING


func open_selection() -> bool:
	if (
		not placement_input_enabled
		or placement_state != PlacementState.IDLE
		or plant_system == null
	):
		return false
	if owner_player != null and owner_player.is_dead:
		return false
	var configs := _get_available_configs_for_current_mode()
	if configs.is_empty():
		selection_unavailable.emit()
		return false
	_clear_placement_source()
	_set_placement_state(PlacementState.SELECTING)
	placement_mode_changed.emit(true)
	player_lock_requested.emit(true)
	if selection_hud.open(
		configs,
		_get_catalog_item_counts(configs),
		free_placement_enabled
	):
		return true
	cancel_placement()
	selection_unavailable.emit()
	return false


func begin_inventory_placement(
	config: PlantDefenseConfig,
	slot_index: int,
	expected_inventory_revision: int,
	item_config_path: String
) -> bool:
	var continuing_catalog_selection := (
		placement_state == PlacementState.SELECTING
	)
	if (
		not placement_input_enabled
		or placement_state not in [PlacementState.IDLE, PlacementState.SELECTING]
		or plant_system == null
		or config == null
		or not config.is_valid()
		or slot_index < 0
		or expected_inventory_revision < 0
		or item_config_path.is_empty()
	):
		return false
	if owner_player != null and owner_player.is_dead:
		return false
	if multiplayer_request_mode and not config.supports_multiplayer:
		return false
	placement_source = PlacementSource.INVENTORY_ITEM
	inventory_slot_index = slot_index
	inventory_expected_revision = expected_inventory_revision
	inventory_item_config_path = item_config_path
	if continuing_catalog_selection:
		selection_hud.close()
	_set_placement_state(PlacementState.PLACING)
	if not continuing_catalog_selection:
		placement_mode_changed.emit(true)
		player_lock_requested.emit(true)
	_start_placing(config)
	return true


func _get_available_configs_for_current_mode() -> Array[PlantDefenseConfig]:
	var configs := plant_system.get_available_configs()
	if not multiplayer_request_mode:
		return configs

	var multiplayer_configs: Array[PlantDefenseConfig] = []
	for config in configs:
		if config != null and config.supports_multiplayer:
			multiplayer_configs.append(config)
	return multiplayer_configs


func cancel_placement() -> void:
	if placement_state == PlacementState.IDLE:
		return
	selection_hud.close()
	_clear_world_preview()
	selected_config = null
	_clear_placement_source()
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
	if not placement_input_enabled:
		return
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
	if not free_placement_enabled:
		_begin_catalog_item_placement(config)
		return
	selection_hud.close()
	_set_placement_state(PlacementState.PLACING)
	placement_source = PlacementSource.SANDBOX_FREE
	_start_placing(config)


func _begin_catalog_item_placement(config: PlantDefenseConfig) -> void:
	if _get_catalog_item_count(config) <= 0:
		_refresh_open_catalog_counts()
		selection_unavailable.emit()
		return
	selection_hud.close()
	_set_placement_state(PlacementState.PLACING)
	placement_source = PlacementSource.CATALOG_ITEM
	_start_placing(config)


func _start_placing(config: PlantDefenseConfig) -> void:
	selected_config = config
	preview.configure(selected_config, _get_placement_tile_size())
	placement_hint_layer.show()
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
	if placement_source == PlacementSource.INVENTORY_ITEM:
		var item_request_id := next_multiplayer_request_id
		next_multiplayer_request_id += 1
		var requested_item_config := selected_config
		var requested_item_anchor := hovered_anchor
		var requested_slot_index := inventory_slot_index
		var requested_revision := inventory_expected_revision
		var requested_item_path := inventory_item_config_path
		_finish_placement_interaction()
		inventory_placement_requested.emit(
			item_request_id,
			requested_item_config.plant_id,
			requested_item_anchor,
			requested_slot_index,
			requested_revision,
			requested_item_path
		)
		return
	if (
		placement_source == PlacementSource.CATALOG_ITEM
		or multiplayer_request_mode
	):
		var request_id := next_multiplayer_request_id
		next_multiplayer_request_id += 1
		var requested_config := selected_config
		var requested_anchor := hovered_anchor
		_finish_placement_interaction()
		multiplayer_placement_requested.emit(
			request_id,
			requested_config.plant_id,
			requested_anchor
		)
		return
	var placed_plant := plant_system.try_place(selected_config, hovered_anchor)
	if placed_plant == null:
		refresh_valid_positions()
		return
	var placed_config := selected_config
	_finish_placement_interaction()
	plant_placed.emit(placed_plant, placed_config)


func _finish_placement_interaction() -> void:
	selection_hud.close()
	_clear_world_preview()
	selected_config = null
	_clear_placement_source()
	_set_placement_state(PlacementState.IDLE)
	placement_mode_changed.emit(false)
	player_lock_requested.emit(false)


func _clear_world_preview() -> void:
	set_process(false)
	placement_hint_root.hide()
	placement_hint_layer.hide()
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
	var cost_hint := ""
	if placement_source == PlacementSource.INVENTORY_ITEM:
		cost_hint = "  ·  落地消耗背包 1 个建筑物品"
	elif placement_source == PlacementSource.CATALOG_ITEM:
		cost_hint = "  ·  落地消耗背包或共享仓库 1 个建筑物品"
	placement_hint_label.text = "%s  ·  %d 个可放置位置%s  ·  左键放置  ·  右键 / Esc / 植物键取消" % [
		selected_config.display_name,
		valid_anchors.size(),
		cost_hint,
	]


func _get_placement_tile_size() -> Vector2:
	if (
		plant_system == null
		or plant_system.ground_tile_map == null
		or plant_system.ground_tile_map.tile_set == null
	):
		return PlantPlacementPreview.DEFAULT_TILE_SIZE
	return Vector2(plant_system.ground_tile_map.tile_set.tile_size).abs()


func _set_placement_state(next_state: PlacementState) -> void:
	if placement_state == next_state:
		return
	var previous_state := placement_state
	placement_state = next_state
	state_changed.emit(previous_state, placement_state)


func _clear_placement_source() -> void:
	placement_source = PlacementSource.SANDBOX_FREE
	inventory_slot_index = -1
	inventory_expected_revision = -1
	inventory_item_config_path = ""


func _get_catalog_item_counts(
	configs: Array[PlantDefenseConfig]
) -> Dictionary:
	var counts := {}
	for config in configs:
		var item := BuildingItemRegistry.get_item(config.plant_id)
		counts[config.plant_id] = (
			_get_inventory_item_total(item)
			+ _get_shared_warehouse_item_total(item)
		)
	return counts


func _get_catalog_item_count(config: PlantDefenseConfig) -> int:
	if config == null:
		return 0
	var item := BuildingItemRegistry.get_item(config.plant_id)
	return _get_inventory_item_total(item) + _get_shared_warehouse_item_total(item)


func _get_inventory_item_total(item: PickupConfig) -> int:
	if run_state == null or item == null:
		return 0
	return (
		run_state.get_inventory_item_total_for_peer(inventory_peer_id, item)
		if inventory_peer_id > 0
		else run_state.get_inventory_item_total(item)
	)


func _get_shared_warehouse_item_total(item: PickupConfig) -> int:
	if production_coordinator == null or item == null:
		return 0
	return production_coordinator.get_total_item_count(item)


func _refresh_open_catalog_counts() -> void:
	if not selection_hud.is_open():
		return
	selection_hud.refresh_item_counts(
		_get_catalog_item_counts(_get_available_configs_for_current_mode())
	)


func _on_inventory_changed() -> void:
	_refresh_open_catalog_counts()


func _on_shared_storage_totals_changed() -> void:
	_refresh_open_catalog_counts()


func _disconnect_owner_player() -> void:
	if owner_player == null or not is_instance_valid(owner_player):
		return
	if owner_player.died.is_connected(_on_owner_player_unavailable):
		owner_player.died.disconnect(_on_owner_player_unavailable)
	if owner_player.tree_exiting.is_connected(_on_owner_player_unavailable):
		owner_player.tree_exiting.disconnect(_on_owner_player_unavailable)


func _disconnect_catalog_state() -> void:
	if (
		run_state != null
		and is_instance_valid(run_state)
		and run_state.inventory_changed.is_connected(_on_inventory_changed)
	):
		run_state.inventory_changed.disconnect(_on_inventory_changed)
	if (
		production_coordinator != null
		and is_instance_valid(production_coordinator)
		and production_coordinator.storage_totals_changed.is_connected(
			_on_shared_storage_totals_changed
		)
	):
		production_coordinator.storage_totals_changed.disconnect(
			_on_shared_storage_totals_changed
		)


func _on_owner_player_unavailable() -> void:
	cancel_placement()


func _exit_tree() -> void:
	_disconnect_owner_player()
	_disconnect_catalog_state()
	if placement_state != PlacementState.IDLE:
		player_lock_requested.emit(false)
