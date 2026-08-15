extends CanvasLayer
class_name TowerDefensePlayerProfilePanel

signal opened
signal closed
signal multiplayer_upgrade_requested(stat_type: int)
signal multiplayer_inventory_item_use_requested(slot_index: int)
signal multiplayer_inventory_item_discard_requested(slot_index: int)
signal multiplayer_simple_crafting_requested(
	recipe_id: StringName,
	request_token: int
)
signal multiplayer_simple_crafting_cancel_requested(request_token: int)
signal building_placement_requested(
	slot_index: int,
	expected_inventory_revision: int
)

const DESIGN_SIZE := Vector2(724.0, 543.0)
const CONTROL_LOCK_OWNER := &"tower_player_profile"

@onready var overlay: Control = $Overlay
@onready var panel_root: Control = $Overlay/PanelRoot
@onready var close_button: Button = $Overlay/PanelRoot/CloseButton
@onready var stats_view: PlayerStatsView = $Overlay/PanelRoot/PlayerStatsView
@onready var inventory_view: PlayerInventoryView = (
	$Overlay/PanelRoot/PlayerInventoryView
)
@onready var upgrade_surface: NinePatchRect = $Overlay/PanelRoot/UpgradeSurface
@onready var upgrade_panel: VBoxContainer = $Overlay/PanelRoot/UpgradePanel
@onready var craft_surface: NinePatchRect = $Overlay/PanelRoot/CraftSurface
@onready var simple_crafting_panel: SimpleCraftingPanel = (
	$Overlay/PanelRoot/SimpleCraftingPanel
)
@onready var tab_bar: TabBar = $Overlay/PanelRoot/TabBar
@onready var attack_row: UpgradeRow = $Overlay/PanelRoot/UpgradePanel/AttackRow
@onready var health_row: UpgradeRow = $Overlay/PanelRoot/UpgradePanel/HealthRow
@onready var speed_row: UpgradeRow = $Overlay/PanelRoot/UpgradePanel/SpeedRow
@onready var dodge_row: UpgradeRow = $Overlay/PanelRoot/UpgradePanel/DodgeRow
@onready var run_state: RunStateStore = get_node("/root/RunState") as RunStateStore

# Public presentation aliases kept for focused UI tests and editor tooling.
@onready var portrait: Sprite2D = stats_view.portrait
@onready var attack_value: Label = stats_view.attack_value
@onready var health_value: Label = stats_view.health_value
@onready var attack_speed_value: Label = stats_view.attack_speed_value
@onready var move_speed_value: Label = stats_view.move_speed_value
@onready var dodge_value: Label = stats_view.dodge_value
@onready var physical_defense_value: Label = stats_view.physical_defense_value
@onready var magic_defense_value: Label = stats_view.magic_defense_value
@onready var skill_info: Control = stats_view.skill_info
@onready var skill_icon: TextureRect = stats_view.skill_icon
@onready var skill_name_label: Label = stats_view.skill_name_label
@onready var skill_description_label: Label = stats_view.skill_description_label
@onready var skill_cost_label: Label = stats_view.skill_cost_label
@onready var inventory_grid: Control = inventory_view.inventory_grid
@onready var item_detail_panel: PanelContainer = inventory_view.item_detail_panel
@onready var item_detail_title: Label = inventory_view.item_detail_title
@onready var item_detail_category_backing: TextureRect = (
	inventory_view.item_detail_category_backing
)
@onready var item_detail_category_label: Label = (
	inventory_view.item_detail_category_label
)
@onready var item_detail_description: RichTextLabel = (
	inventory_view.item_detail_description
)
@onready var item_detail_hint: Label = inventory_view.item_detail_hint
@onready var item_detail_use_button: Button = inventory_view.item_detail_use_button
@onready var item_detail_discard_button: Button = (
	inventory_view.item_detail_discard_button
)

var tracked_player: Player = null
var research_coordinator: ResearchCoordinator = null
var slots: Array[InventorySlot] = []
var current_tab := 0
var multiplayer_requests_enabled := false
var selected_slot_index: int:
	get:
		return inventory_view.selected_slot_index if inventory_view != null else -1


func _ready() -> void:
	overlay.visible = false
	close_button.pressed.connect(close)
	panel_root.gui_input.connect(_on_panel_root_gui_input)
	get_viewport().size_changed.connect(_update_panel_transform)
	_update_panel_transform()
	run_state.ensure_run_started()
	run_state.upgrade_changed.connect(_refresh_upgrades)
	run_state.inventory_changed.connect(_on_inventory_changed)
	inventory_view.bind_run_state(run_state)
	inventory_view.item_use_requested.connect(_on_inventory_item_use_requested)
	inventory_view.item_discard_requested.connect(
		_on_inventory_item_discard_requested
	)
	inventory_view.item_quick_use_toggle_requested.connect(
		_on_inventory_item_quick_use_toggle_requested
	)
	slots = inventory_view.slots
	stats_view.player_died.connect(_on_player_died)
	stats_view.xirang_changed.connect(_refresh_upgrades)
	tab_bar.tab_changed.connect(_on_tab_changed)
	simple_crafting_panel.craft_requested.connect(_on_simple_crafting_requested)
	simple_crafting_panel.craft_request_cancelled.connect(
		_on_simple_crafting_request_cancelled
	)
	simple_crafting_panel.set_research_state_provider(research_coordinator)
	attack_row.upgrade_requested.connect(_on_upgrade_requested)
	health_row.upgrade_requested.connect(_on_upgrade_requested)
	speed_row.upgrade_requested.connect(_on_upgrade_requested)
	dodge_row.upgrade_requested.connect(_on_upgrade_requested)
	_apply_upgrade_cost_icons()
	_apply_tab_state()


func configure_multiplayer_requests(enabled: bool) -> void:
	multiplayer_requests_enabled = enabled


func bind_player(player: Player) -> void:
	if tracked_player != null and overlay.visible:
		close()
	tracked_player = player
	stats_view.bind_player(player)
	if tracked_player == null:
		close()
		return
	inventory_view.refresh()
	_refresh_upgrades()


func set_research_coordinator(
	new_research_coordinator: ResearchCoordinator
) -> void:
	research_coordinator = new_research_coordinator
	if is_node_ready():
		simple_crafting_panel.set_research_state_provider(research_coordinator)


func open() -> void:
	if tracked_player == null or tracked_player.is_dead or overlay.visible:
		return
	overlay.visible = true
	tracked_player.set_control_lock(CONTROL_LOCK_OWNER, true)
	opened.emit()
	inventory_view.clear_selection()
	inventory_view.refresh()
	_refresh_upgrades()
	stats_view.refresh()


func close() -> void:
	if not overlay.visible:
		return
	simple_crafting_panel.cancel_pending_request()
	overlay.visible = false
	inventory_view.clear_selection()
	if tracked_player != null and is_instance_valid(tracked_player):
		tracked_player.set_control_lock(CONTROL_LOCK_OWNER, false)
	closed.emit()


func toggle() -> void:
	if overlay.visible:
		close()
	else:
		open()


func is_open() -> bool:
	return overlay.visible


func refresh_inventory() -> void:
	inventory_view.refresh()
	if current_tab == 2:
		simple_crafting_panel.refresh()


func show_simple_crafting_result(
	recipe_id: StringName,
	result: StringName,
	request_token: int
) -> void:
	simple_crafting_panel.show_result(recipe_id, result, request_token)


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("use_item") and not event.is_echo():
		if _request_quick_use_item():
			get_viewport().set_input_as_handled()
		return
	if event.is_action_pressed("bag"):
		toggle()
		get_viewport().set_input_as_handled()
		return
	if not overlay.visible:
		return
	if event.is_action_pressed("quit") or event.is_action_pressed("ui_cancel"):
		close()
		get_viewport().set_input_as_handled()
	elif event.is_action_pressed("ui_accept") and current_tab == 0:
		if inventory_view.handle_accept():
			get_viewport().set_input_as_handled()


func _request_quick_use_item() -> bool:
	if (
		tracked_player == null
		or not is_instance_valid(tracked_player)
		or not tracked_player.uses_local_input
		or tracked_player.is_dead
		or tracked_player.world_movement_mode
		or tracked_player.are_combat_actions_locked()
		or overlay.visible
	):
		return false
	var owner_peer_id := tracked_player.peer_id if tracked_player.peer_id > 0 else 0
	if run_state.get_active_multiplayer_peer_id() != owner_peer_id:
		return false
	var slot_index := run_state.get_quick_use_slot_index(owner_peer_id)
	if slot_index < 0:
		return false
	_on_inventory_item_use_requested(slot_index)
	return true


func _on_inventory_changed() -> void:
	refresh_inventory()


func _refresh_upgrades() -> void:
	_refresh_upgrade_row(attack_row, RunStateStore.StatType.ATTACK)
	_refresh_upgrade_row(health_row, RunStateStore.StatType.HEALTH)
	_refresh_upgrade_row(speed_row, RunStateStore.StatType.ATTACK_SPEED)
	_refresh_upgrade_row(dodge_row, RunStateStore.StatType.DODGE)


func _refresh_upgrade_row(row: UpgradeRow, stat_type: int) -> void:
	var current_level := run_state.get_upgrade_level(stat_type)
	var current_cost := run_state.get_upgrade_cost(stat_type)
	var can_afford := (
		tracked_player != null
		and current_cost >= 0
		and tracked_player.current_xirang >= current_cost
	)
	row.set_upgrade_state(current_level, current_cost, can_afford)


func _on_upgrade_requested(stat_type: int) -> void:
	if tracked_player == null:
		return
	if multiplayer_requests_enabled:
		multiplayer_upgrade_requested.emit(stat_type)
		return
	if run_state.try_upgrade(stat_type, tracked_player):
		_refresh_upgrades()
		stats_view.refresh()
		if tracked_player.powerup_audio != null:
			tracked_player.powerup_audio.play()


func _on_inventory_item_use_requested(slot_index: int) -> void:
	var item := inventory_view.get_item(slot_index)
	if item == null:
		inventory_view.refresh()
		return
	if item.pickup_type == PickupConfig.PickupType.BUILDING:
		_begin_building_placement(slot_index)
		return
	if multiplayer_requests_enabled:
		multiplayer_inventory_item_use_requested.emit(slot_index)
		return
	if run_state.try_use_item(slot_index, tracked_player):
		inventory_view.refresh()
		stats_view.refresh()
	else:
		inventory_view.refresh()


func _on_inventory_item_discard_requested(slot_index: int) -> void:
	if multiplayer_requests_enabled:
		multiplayer_inventory_item_discard_requested.emit(slot_index)
		return
	if run_state.discard_item(slot_index):
		inventory_view.refresh()
		stats_view.refresh()
	else:
		inventory_view.refresh()


func _on_inventory_item_quick_use_toggle_requested(slot_index: int) -> void:
	if tracked_player == null or not is_instance_valid(tracked_player):
		return
	var owner_peer_id := tracked_player.peer_id if tracked_player.peer_id > 0 else 0
	if run_state.get_active_multiplayer_peer_id() != owner_peer_id:
		return
	run_state.toggle_quick_use_binding(slot_index, owner_peer_id)


func _begin_building_placement(slot_index: int) -> void:
	var expected_revision := (
		run_state.get_inventory_revision_for_peer(
			run_state.get_active_multiplayer_peer_id()
		)
		if run_state.get_active_multiplayer_peer_id() > 0
		else run_state.get_inventory_revision()
	)
	close()
	building_placement_requested.emit(slot_index, expected_revision)


func restore_after_failed_building_placement() -> void:
	open()


func _on_tab_changed(tab_index: int) -> void:
	if tab_index == current_tab:
		return
	current_tab = tab_index
	_apply_tab_state()
	match current_tab:
		0:
			inventory_view.clear_selection()
		1:
			_refresh_upgrades()
		2:
			simple_crafting_panel.refresh()


func _apply_tab_state() -> void:
	inventory_view.set_panel_active(current_tab == 0)
	upgrade_surface.visible = current_tab == 1
	upgrade_panel.visible = current_tab == 1
	craft_surface.visible = current_tab == 2
	simple_crafting_panel.set_panel_active(current_tab == 2)
	tab_bar.current_tab = current_tab


func _on_simple_crafting_requested(
	recipe_id: StringName,
	request_token: int
) -> void:
	var recipe := SimpleCraftingRegistry.get_recipe(recipe_id)
	if recipe == null:
		simple_crafting_panel.show_result(
			recipe_id,
			RunStateStore.CRAFT_RESULT_INVALID_RECIPE,
			request_token
		)
		return
	var completed_research_ids := _get_completed_global_research_ids()
	if not SimpleCraftingRegistry.is_recipe_unlocked(
		recipe,
		completed_research_ids
	):
		simple_crafting_panel.show_result(
			recipe_id,
			RunStateStore.CRAFT_RESULT_RESEARCH_LOCKED,
			request_token
		)
		return
	if multiplayer_requests_enabled:
		multiplayer_simple_crafting_requested.emit(recipe_id, request_token)
		return
	var expected_revision := run_state.get_inventory_revision()
	var result := run_state.try_craft_inventory_recipe_if_revision(
		recipe,
		expected_revision,
		true,
		completed_research_ids
	)
	simple_crafting_panel.show_result(recipe_id, result, request_token)


func _get_completed_global_research_ids() -> Array[StringName]:
	if research_coordinator != null and is_instance_valid(research_coordinator):
		return research_coordinator.get_completed_global_research_ids()
	var completed_ids: Array[StringName] = []
	return completed_ids


func _on_simple_crafting_request_cancelled(request_token: int) -> void:
	if multiplayer_requests_enabled:
		multiplayer_simple_crafting_cancel_requested.emit(request_token)


func _on_player_died() -> void:
	close()


func _on_slot_selected(slot_index: int) -> void:
	inventory_view.select_slot(slot_index)


func _on_inventory_grid_gui_input(event: InputEvent) -> void:
	inventory_view.handle_blank_grid_input(event)


func _on_panel_root_gui_input(event: InputEvent) -> void:
	if not overlay.visible or current_tab != 0 or selected_slot_index < 0:
		return
	var mouse_event := event as InputEventMouseButton
	if mouse_event == null:
		return
	if mouse_event.button_index != MOUSE_BUTTON_LEFT or not mouse_event.pressed:
		return
	inventory_view.clear_selection()
	panel_root.accept_event()


func _apply_upgrade_cost_icons() -> void:
	var xirang_icon := preload("res://resources/texture/xirang_icon.png")
	attack_row.cost_icon.texture = xirang_icon
	health_row.cost_icon.texture = xirang_icon
	speed_row.cost_icon.texture = xirang_icon
	dodge_row.cost_icon.texture = xirang_icon


func _update_panel_transform() -> void:
	var viewport_size := Vector2(get_viewport().get_visible_rect().size)
	var scale_factor := 1.0
	if viewport_size.x < DESIGN_SIZE.x or viewport_size.y < DESIGN_SIZE.y:
		scale_factor = minf(
			viewport_size.x / DESIGN_SIZE.x,
			viewport_size.y / DESIGN_SIZE.y
		) * 0.94
		scale_factor = minf(scale_factor, 1.0)
	panel_root.scale = Vector2.ONE * scale_factor
	panel_root.position = ((viewport_size - DESIGN_SIZE * scale_factor) * 0.5).round()
