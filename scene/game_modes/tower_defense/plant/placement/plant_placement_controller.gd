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
const MAX_IGNORED_REQUEST_IDS := 16

@export_range(1.0, 16.0, 0.5) var click_tolerance_world := 6.0
@export_range(0.05, 1.0, 0.05) var marker_refresh_interval := 0.2
@export var free_placement_enabled := false

@onready var marker_container: Node2D = $MarkerContainer
@onready var preview: PlantPlacementPreview = $PlantPlacementPreview
@onready var selection_hud: PlantSelectionHUD = $PlantSelectionHUD
@onready var placement_hint_layer: CanvasLayer = $PlacementInstructions
@onready var placement_hint_root: Control = $PlacementInstructions/Root
@onready var placement_hint_label: Label = $PlacementInstructions/Root/Bottom/Panel/Margin/HintLabel
@onready var pending_placement_timeout: Timer = $PendingPlacementTimeout

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
var pending_request_id := 0
var pending_config: PlantDefenseConfig = null
var pending_anchor := Vector2i.ZERO
var pending_source := PlacementSource.SANDBOX_FREE
var pending_inventory_slot_index := -1
var pending_inventory_revision := -1
var pending_inventory_item_config_path := ""
var pending_inventory_item_count := -1
var pending_catalog_item_count := -1
var pending_success_received := false
var ignored_request_ids: Array[int] = []


func _ready() -> void:
	selection_hud.selection_confirmed.connect(_begin_placing)
	selection_hud.cancel_requested.connect(cancel_placement)
	pending_placement_timeout.timeout.connect(_on_pending_placement_timeout)
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


func notify_multiplayer_placement_rejected(request_id: int) -> void:
	if _is_ignored_request_id(request_id):
		return
	if pending_request_id > 0:
		if request_id != pending_request_id:
			return
		_finish_placement_interaction()
	selection_unavailable.emit()


func notify_placement_succeeded(request_id: int) -> void:
	if _is_ignored_request_id(request_id):
		return
	if request_id <= 0 or request_id != pending_request_id:
		return
	pending_success_received = true
	_try_complete_pending_continuous_placement()


func has_pending_placement_request() -> bool:
	return pending_request_id > 0


func get_pending_placement_request_id() -> int:
	return pending_request_id


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
	_clear_pending_request(true)
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
	if event.is_action_pressed(&"plant") and not _is_shift_modifier_event(event):
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
		_try_place_hovered(mouse_event.shift_pressed)
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


func _try_place_hovered(continuous_requested: bool = false) -> void:
	if (
		pending_request_id > 0
		or not has_hovered_anchor
		or plant_system == null
		or selected_config == null
	):
		return
	if placement_source == PlacementSource.INVENTORY_ITEM:
		var item_request_id := next_multiplayer_request_id
		next_multiplayer_request_id += 1
		var requested_item_config := selected_config
		var requested_item_anchor := hovered_anchor
		var requested_slot_index := inventory_slot_index
		var requested_revision := inventory_expected_revision
		var requested_item_path := inventory_item_config_path
		if continuous_requested:
			_begin_pending_continuous_request(
				item_request_id,
				requested_item_config,
				requested_item_anchor
			)
		else:
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
		if continuous_requested:
			_begin_pending_continuous_request(
				request_id,
				requested_config,
				requested_anchor
			)
		else:
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
	if not continuous_requested:
		_finish_placement_interaction()
		plant_placed.emit(placed_plant, placed_config)
		return
	plant_placed.emit(placed_plant, placed_config)
	if (
		placement_state == PlacementState.PLACING
		and selected_config == placed_config
	):
		refresh_valid_positions()


func _begin_pending_continuous_request(
	request_id: int,
	config: PlantDefenseConfig,
	anchor: Vector2i
) -> void:
	pending_request_id = request_id
	pending_config = config
	pending_anchor = anchor
	pending_source = placement_source
	pending_inventory_slot_index = inventory_slot_index
	pending_inventory_revision = inventory_expected_revision
	pending_inventory_item_config_path = inventory_item_config_path
	pending_inventory_item_count = (
		_get_inventory_item_count_at_slot(inventory_slot_index)
		if placement_source == PlacementSource.INVENTORY_ITEM
		else -1
	)
	pending_catalog_item_count = (
		_get_catalog_item_count(config)
		if placement_source == PlacementSource.CATALOG_ITEM
		else -1
	)
	pending_success_received = false
	pending_placement_timeout.start()
	_update_hint_text()


func _try_complete_pending_continuous_placement() -> void:
	if pending_request_id <= 0 or not pending_success_received:
		return
	match pending_source:
		PlacementSource.SANDBOX_FREE:
			_resume_after_pending_placement()
		PlacementSource.CATALOG_ITEM:
			var remaining_count := _get_catalog_item_count(pending_config)
			if remaining_count >= pending_catalog_item_count:
				_update_hint_text()
				return
			if remaining_count <= 0:
				_finish_placement_interaction()
				return
			_resume_after_pending_placement()
		PlacementSource.INVENTORY_ITEM:
			var current_revision := _get_current_inventory_revision()
			if current_revision <= pending_inventory_revision:
				_update_hint_text()
				return
			var current_item := _get_inventory_item_at_slot(
				pending_inventory_slot_index
			)
			var current_item_count := _get_inventory_item_count_at_slot(
				pending_inventory_slot_index
			)
			if (
				current_item == null
				or current_item.resource_path != pending_inventory_item_config_path
				or current_item_count <= 0
			):
				_finish_placement_interaction()
				return
			if current_item_count >= pending_inventory_item_count:
				_update_hint_text()
				return
			inventory_expected_revision = current_revision
			_resume_after_pending_placement()


func _resume_after_pending_placement() -> void:
	var completed_config := pending_config
	var completed_source := pending_source
	_clear_pending_request(true)
	if (
		placement_state != PlacementState.PLACING
		or selected_config != completed_config
		or placement_source != completed_source
	):
		return
	refresh_valid_positions()


func _clear_pending_request(remember_as_ignored: bool = false) -> void:
	var cleared_request_id := pending_request_id
	if pending_placement_timeout != null:
		pending_placement_timeout.stop()
	pending_request_id = 0
	pending_config = null
	pending_anchor = Vector2i.ZERO
	pending_source = PlacementSource.SANDBOX_FREE
	pending_inventory_slot_index = -1
	pending_inventory_revision = -1
	pending_inventory_item_config_path = ""
	pending_inventory_item_count = -1
	pending_catalog_item_count = -1
	pending_success_received = false
	if remember_as_ignored and cleared_request_id > 0:
		_remember_ignored_request_id(cleared_request_id)


func _remember_ignored_request_id(request_id: int) -> void:
	if request_id <= 0 or ignored_request_ids.has(request_id):
		return
	ignored_request_ids.append(request_id)
	if ignored_request_ids.size() > MAX_IGNORED_REQUEST_IDS:
		ignored_request_ids.pop_front()


func _is_ignored_request_id(request_id: int) -> bool:
	return ignored_request_ids.has(request_id)


func _on_pending_placement_timeout() -> void:
	if pending_request_id <= 0:
		return
	_clear_pending_request(true)
	_finish_placement_interaction()
	selection_unavailable.emit()


func _finish_placement_interaction() -> void:
	_clear_pending_request(true)
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
	var action_hint := (
		"建筑已放置，等待物品同步  ·  右键 / Esc / 植物键取消"
		if pending_request_id > 0 and pending_success_received
		else (
			"等待放置确认  ·  右键 / Esc / 植物键取消"
			if pending_request_id > 0
			else "左键放置  ·  按住 Shift 连续放置  ·  右键 / Esc / 植物键取消"
		)
	)
	placement_hint_label.text = "%s  ·  %d 个可放置位置%s  ·  %s" % [
		selected_config.display_name,
		valid_anchors.size(),
		cost_hint,
		action_hint,
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


func _get_current_inventory_revision() -> int:
	if run_state == null:
		return -1
	return (
		run_state.get_inventory_revision_for_peer(inventory_peer_id)
		if inventory_peer_id > 0
		else run_state.get_inventory_revision()
	)


func _get_inventory_item_at_slot(slot_index: int) -> PickupConfig:
	if run_state == null or slot_index < 0:
		return null
	return (
		run_state.get_item_for_peer(inventory_peer_id, slot_index)
		if inventory_peer_id > 0
		else run_state.get_item(slot_index)
	)


func _get_inventory_item_count_at_slot(slot_index: int) -> int:
	if run_state == null or slot_index < 0:
		return 0
	return (
		run_state.get_item_count_for_peer(inventory_peer_id, slot_index)
		if inventory_peer_id > 0
		else run_state.get_item_count(slot_index)
	)


func _refresh_open_catalog_counts() -> void:
	if not selection_hud.is_open():
		return
	selection_hud.refresh_item_counts(
		_get_catalog_item_counts(_get_available_configs_for_current_mode())
	)


func _on_inventory_changed() -> void:
	_refresh_open_catalog_counts()
	_try_complete_pending_continuous_placement()


func _on_shared_storage_totals_changed() -> void:
	_refresh_open_catalog_counts()
	_try_complete_pending_continuous_placement()


static func _is_shift_modifier_event(event: InputEvent) -> bool:
	var key_event := event as InputEventKey
	return (
		key_event != null
		and (
			key_event.keycode == KEY_SHIFT
			or key_event.physical_keycode == KEY_SHIFT
		)
	)


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
