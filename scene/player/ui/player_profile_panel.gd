extends CanvasLayer
class_name PlayerProfilePanel

signal opened
signal closed

const DESIGN_SIZE := Vector2(724.0, 543.0)
const PORTRAIT_DEFAULT_POSITION := Vector2(150.0, 178.0)
const PORTRAIT_WITH_SKILL_POSITION := Vector2(150.0, 147.0)
const ITEM_DETAIL_SIZE := Vector2(254.0, 166.0)
const ITEM_DETAIL_MARGIN := 14.0
const ITEM_CATEGORY_COLLECTIBLE_TEXTURE := preload("res://resources/texture/item_category_badge_collectible.png")
const ITEM_CATEGORY_ITEM_TEXTURE := preload("res://resources/texture/item_category_badge_item.png")

@onready var overlay: Control = $Overlay
@onready var panel_root: Control = $Overlay/PanelRoot
@onready var close_button: Button = $Overlay/PanelRoot/CloseButton
@onready var portrait: Sprite2D = $Overlay/PanelRoot/Portrait
@onready var attack_value: Label = $Overlay/PanelRoot/AttackValue
@onready var health_value: Label = $Overlay/PanelRoot/HealthValue
@onready var attack_speed_value: Label = $Overlay/PanelRoot/AttackSpeedValue
@onready var move_speed_value: Label = $Overlay/PanelRoot/MoveSpeedValue
@onready var dodge_value: Label = $Overlay/PanelRoot/DodgeValue
@onready var physical_defense_value: Label = $Overlay/PanelRoot/PhysicalDefenseValue
@onready var magic_defense_value: Label = $Overlay/PanelRoot/MagicDefenseValue
@onready var skill_info: Control = $Overlay/PanelRoot/SkillInfo
@onready var skill_icon: TextureRect = $Overlay/PanelRoot/SkillInfo/SkillIcon
@onready var skill_name_label: Label = $Overlay/PanelRoot/SkillInfo/SkillName
@onready var skill_description_label: Label = $Overlay/PanelRoot/SkillInfo/SkillDescription
@onready var skill_cost_label: Label = $Overlay/PanelRoot/SkillInfo/SkillCost
@onready var inventory_grid: Control = $Overlay/PanelRoot/InventoryGrid
@onready var item_detail_panel: PanelContainer = $Overlay/PanelRoot/ItemDetailPanel
@onready var item_detail_title: Label = $Overlay/PanelRoot/ItemDetailPanel/Margin/Content/HeaderRow/ItemTitle
@onready var item_detail_category_backing: TextureRect = $Overlay/PanelRoot/ItemDetailPanel/Margin/Content/HeaderRow/ItemCategory
@onready var item_detail_category_label: Label = $Overlay/PanelRoot/ItemDetailPanel/Margin/Content/HeaderRow/ItemCategory/CategoryLabel
@onready var item_detail_description: RichTextLabel = $Overlay/PanelRoot/ItemDetailPanel/Margin/Content/ItemDescription
@onready var item_detail_hint: Label = $Overlay/PanelRoot/ItemDetailPanel/Margin/Content/ItemHint
@onready var item_detail_use_button: Button = $Overlay/PanelRoot/ItemDetailPanel/Margin/Content/ButtonRow/UseButton
@onready var item_detail_discard_button: Button = $Overlay/PanelRoot/ItemDetailPanel/Margin/Content/ButtonRow/DiscardButton
@onready var upgrade_surface: NinePatchRect = $Overlay/PanelRoot/UpgradeSurface
@onready var upgrade_panel: VBoxContainer = $Overlay/PanelRoot/UpgradePanel
@onready var craft_surface: NinePatchRect = $Overlay/PanelRoot/CraftSurface
@onready var simple_crafting_panel: SimpleCraftingPanel = $Overlay/PanelRoot/SimpleCraftingPanel
@onready var tab_bar: TabBar = $Overlay/PanelRoot/TabBar
@onready var attack_row: UpgradeRow = $Overlay/PanelRoot/UpgradePanel/AttackRow
@onready var health_row: UpgradeRow = $Overlay/PanelRoot/UpgradePanel/HealthRow
@onready var speed_row: UpgradeRow = $Overlay/PanelRoot/UpgradePanel/SpeedRow
@onready var dodge_row: UpgradeRow = $Overlay/PanelRoot/UpgradePanel/DodgeRow
@onready var run_state: RunStateStore = get_node("/root/RunState") as RunStateStore
@onready var net_manager: Node = get_node("/root/NetManager")

var tracked_player: Player = null
var slots: Array[InventorySlot] = []
var selected_slot_index := -1
var current_tab := 0  # 0 = 背包, 1 = 升级, 2 = 简易制造


func _ready() -> void:
	overlay.visible = false
	set_process(false)
	close_button.pressed.connect(close)
	item_detail_use_button.pressed.connect(_on_detail_use_pressed)
	item_detail_discard_button.pressed.connect(_on_detail_discard_pressed)
	panel_root.gui_input.connect(_on_panel_root_gui_input)
	inventory_grid.gui_input.connect(_on_inventory_grid_gui_input)
	get_viewport().size_changed.connect(_update_panel_transform)
	_collect_slots()
	_update_panel_transform()
	run_state.ensure_run_started()
	run_state.inventory_changed.connect(_refresh_inventory)
	run_state.upgrade_changed.connect(_refresh_upgrades)

	tab_bar.tab_changed.connect(_on_tab_changed)
	simple_crafting_panel.craft_requested.connect(_on_simple_crafting_requested)

	# 升级行信号
	attack_row.upgrade_requested.connect(_on_upgrade_requested)
	health_row.upgrade_requested.connect(_on_upgrade_requested)
	speed_row.upgrade_requested.connect(_on_upgrade_requested)
	dodge_row.upgrade_requested.connect(_on_upgrade_requested)

	# 为升级行设置息壤图标
	var xirang_icon := preload("res://resources/texture/xirang_icon.png")
	attack_row.cost_icon.texture = xirang_icon
	health_row.cost_icon.texture = xirang_icon
	speed_row.cost_icon.texture = xirang_icon
	dodge_row.cost_icon.texture = xirang_icon

	_apply_tab_state()


func bind_player(player: Player) -> void:
	if tracked_player != null:
		if overlay.visible:
			close()
		if tracked_player.health_changed.is_connected(_on_health_changed):
			tracked_player.health_changed.disconnect(_on_health_changed)
		if tracked_player.attack_speed_changed.is_connected(_on_attack_speed_changed):
			tracked_player.attack_speed_changed.disconnect(_on_attack_speed_changed)
		if tracked_player.xirang_changed.is_connected(_on_xirang_changed):
			tracked_player.xirang_changed.disconnect(_on_xirang_changed)
		if tracked_player.dodge_changed.is_connected(_on_dodge_changed):
			tracked_player.dodge_changed.disconnect(_on_dodge_changed)
		if tracked_player.died.is_connected(_on_player_died):
			tracked_player.died.disconnect(_on_player_died)

	tracked_player = player
	if tracked_player == null:
		portrait.position = PORTRAIT_DEFAULT_POSITION
		close()
		return

	tracked_player.health_changed.connect(_on_health_changed)
	tracked_player.attack_speed_changed.connect(_on_attack_speed_changed)
	tracked_player.xirang_changed.connect(_on_xirang_changed)
	tracked_player.dodge_changed.connect(_on_dodge_changed)
	tracked_player.died.connect(_on_player_died)
	_refresh_skill_presentation()
	_update_skill_tooltip()
	_refresh_character_portrait()
	portrait.position = PORTRAIT_DEFAULT_POSITION
	attack_value.text = str(tracked_player.attack_damage)
	_on_attack_speed_changed(tracked_player.get_attack_speed())
	_on_dodge_changed(tracked_player.dodge_chance)
	_on_health_changed(tracked_player.current_health, tracked_player.max_health)
	_refresh_inventory()
	_refresh_upgrades()


func _refresh_character_portrait() -> void:
	portrait.texture = null
	if tracked_player == null:
		return
	var config := tracked_player.get_character_config()
	if config == null or config.portrait_texture.is_empty():
		return
	portrait.texture = load(config.portrait_texture) as Texture2D


func open() -> void:
	if tracked_player == null or tracked_player.is_dead:
		return
	if overlay.visible:
		return

	overlay.visible = true
	set_process(true)
	tracked_player.set_controls_locked(true)
	opened.emit()
	selected_slot_index = -1
	_refresh_inventory()
	_refresh_upgrades()
	_refresh_stat_display()


func close() -> void:
	if not overlay.visible:
		return

	overlay.visible = false
	set_process(false)
	_clear_inventory_selection()
	if tracked_player != null and not tracked_player.is_dead:
		tracked_player.set_controls_locked(false)
	closed.emit()


func toggle() -> void:
	if overlay.visible:
		close()
	else:
		open()


func is_open() -> bool:
	return overlay.visible


func _process(_delta: float) -> void:
	if overlay.visible:
		_refresh_stat_display()


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("bag"):
		toggle()
		get_viewport().set_input_as_handled()
		return

	if not overlay.visible:
		return

	if event.is_action_pressed("quit") or event.is_action_pressed("ui_cancel"):
		close()
		get_viewport().set_input_as_handled()
	elif event.is_action_pressed("ui_accept") and selected_slot_index >= 0 and current_tab == 0:
		_try_use_slot(selected_slot_index)
		get_viewport().set_input_as_handled()


func _collect_slots() -> void:
	slots.clear()
	for child in inventory_grid.get_children():
		var slot := child as InventorySlot
		if slot == null:
			continue
		slot.slot_selected.connect(_on_slot_selected)
		slot.item_activated.connect(_try_use_slot)
		slots.append(slot)


func _refresh_inventory() -> void:
	for slot_index in range(slots.size()):
		slots[slot_index].set_item(
			run_state.get_item(slot_index),
			run_state.get_item_count(slot_index)
		)
		slots[slot_index].set_selected(slot_index == selected_slot_index)
	_refresh_item_detail()
	if current_tab == 2:
		simple_crafting_panel.refresh()


func _refresh_upgrades() -> void:
	_refresh_upgrade_row(attack_row, RunStateStore.StatType.ATTACK)
	_refresh_upgrade_row(health_row, RunStateStore.StatType.HEALTH)
	_refresh_upgrade_row(speed_row, RunStateStore.StatType.ATTACK_SPEED)
	_refresh_upgrade_row(dodge_row, RunStateStore.StatType.DODGE)


func _refresh_upgrade_row(row: UpgradeRow, stat_type: int) -> void:
	var current_level: int = run_state.get_upgrade_level(stat_type)
	var current_cost: int = run_state.get_upgrade_cost(stat_type)
	var can_afford := (
		tracked_player != null
		and current_cost >= 0
		and tracked_player.current_xirang >= current_cost
	)
	row.set_upgrade_state(current_level, current_cost, can_afford)


func _refresh_stat_display() -> void:
	if tracked_player == null:
		return
	attack_value.text = str(tracked_player.attack_damage)
	_on_health_changed(tracked_player.current_health, tracked_player.max_health)
	_on_attack_speed_changed(tracked_player.get_attack_speed())
	_on_dodge_changed(tracked_player.dodge_chance)
	move_speed_value.text = str(roundi(tracked_player.move_speed))
	physical_defense_value.text = str(tracked_player.physical_defense)
	magic_defense_value.text = str(tracked_player.magic_defense)
	_refresh_skill_display()


func _on_slot_selected(slot_index: int) -> void:
	if slot_index < 0 or slot_index >= slots.size() or run_state.get_item(slot_index) == null:
		_clear_inventory_selection()
		return
	selected_slot_index = slot_index
	for slot in slots:
		slot.set_selected(slot.slot_index == selected_slot_index)
	_refresh_item_detail()


func _try_use_slot(slot_index: int) -> void:
	if slot_index < 0 or slot_index >= slots.size() or run_state.get_item(slot_index) == null:
		_clear_inventory_selection()
		return
	selected_slot_index = slot_index
	var item := run_state.get_item(slot_index)
	if item.pickup_type == PickupConfig.PickupType.BUILDING:
		_try_begin_building_placement(slot_index)
		return
	if _request_multiplayer_inventory_item_use(slot_index):
		return
	if run_state.try_use_item(slot_index, tracked_player):
		_refresh_inventory()
		_refresh_stat_display()
	else:
		_refresh_item_detail()


func _on_inventory_grid_gui_input(event: InputEvent) -> void:
	if not overlay.visible or current_tab != 0:
		return

	var mouse_event := event as InputEventMouseButton
	if mouse_event == null:
		return
	if mouse_event.button_index != MOUSE_BUTTON_LEFT or not mouse_event.pressed:
		return

	_clear_inventory_selection()
	inventory_grid.accept_event()


func _on_panel_root_gui_input(event: InputEvent) -> void:
	if not overlay.visible or current_tab != 0 or selected_slot_index < 0:
		return

	var mouse_event := event as InputEventMouseButton
	if mouse_event == null:
		return
	if mouse_event.button_index != MOUSE_BUTTON_LEFT or not mouse_event.pressed:
		return

	_clear_inventory_selection()
	panel_root.accept_event()


func _clear_inventory_selection() -> void:
	selected_slot_index = -1
	for slot in slots:
		slot.set_selected(false)
	_hide_item_detail()
	get_viewport().gui_release_focus()


func _on_health_changed(current: int, maximum: int) -> void:
	health_value.text = "%d / %d" % [current, maximum]


func _on_attack_speed_changed(attack_speed: float) -> void:
	var rounded_speed := roundf(attack_speed)
	attack_speed_value.text = (
		str(roundi(rounded_speed))
		if is_equal_approx(attack_speed, rounded_speed)
		else "%.2f" % attack_speed
	)


func _on_dodge_changed(chance: float) -> void:
	dodge_value.text = "%.0f%%" % (clampf(chance, 0.0, 1.0) * 100.0)


func _refresh_skill_display() -> void:
	if tracked_player == null:
		skill_info.visible = false
		portrait.position = PORTRAIT_DEFAULT_POSITION
		return
	var has_skill := tracked_player.has_skill1()
	skill_info.visible = has_skill
	portrait.position = PORTRAIT_WITH_SKILL_POSITION if has_skill else PORTRAIT_DEFAULT_POSITION
	_refresh_skill_presentation()
	if not has_skill:
		return
	var required_charge := maxf(tracked_player.skill1_charge_duration, 0.01)
	skill_cost_label.text = "技力需求%d" % roundi(required_charge)
	_update_skill_tooltip()


func _update_skill_tooltip() -> void:
	if tracked_player == null:
		return
	var tooltip := "%s\n%s" % [
		tracked_player.get_skill1_display_name(),
		tracked_player.get_skill1_description(),
	]
	skill_info.tooltip_text = tooltip
	skill_icon.tooltip_text = tooltip


func _refresh_skill_presentation() -> void:
	if tracked_player == null:
		return
	skill_name_label.text = tracked_player.get_skill1_display_name()
	skill_description_label.text = tracked_player.get_skill1_description()
	skill_icon.texture = tracked_player.get_skill1_icon()


func _on_xirang_changed(_total: int, _added_amount: int) -> void:
	_refresh_upgrades()


func _on_player_died() -> void:
	close()


func _on_upgrade_requested(stat_type: int) -> void:
	if tracked_player == null:
		return
	if net_manager != null and net_manager.is_client():
		var current_scene := get_tree().current_scene
		if current_scene != null and current_scene.has_method("request_multiplayer_upgrade"):
			current_scene.call("request_multiplayer_upgrade", stat_type)
		return

	if run_state.try_upgrade(stat_type, tracked_player):
		_refresh_upgrades()
		_refresh_stat_display()
		# 播放升级成功音效
		if tracked_player.powerup_audio != null:
			tracked_player.powerup_audio.play()


# ──── 标签页切换 ────

func _on_tab_changed(tab_index: int) -> void:
	if tab_index == current_tab:
		return
	current_tab = tab_index
	_apply_tab_state()
	match current_tab:
		0:
			_clear_inventory_selection()
		1:
			_refresh_upgrades()
		2:
			simple_crafting_panel.refresh()


func _apply_tab_state() -> void:
	inventory_grid.visible = current_tab == 0
	upgrade_surface.visible = current_tab == 1
	upgrade_panel.visible = current_tab == 1
	craft_surface.visible = current_tab == 2
	simple_crafting_panel.set_panel_active(current_tab == 2)
	tab_bar.current_tab = current_tab
	if current_tab == 0:
		_refresh_item_detail()
	else:
		_hide_item_detail()


func _on_simple_crafting_requested(recipe_id: StringName) -> void:
	var recipe := SimpleCraftingRegistry.get_recipe(recipe_id)
	if recipe == null:
		simple_crafting_panel.show_result(
			recipe_id,
			RunStateStore.CRAFT_RESULT_INVALID_RECIPE
		)
		return
	var current_scene := get_tree().current_scene
	if (
		current_scene != null
		and current_scene.has_method("request_multiplayer_simple_crafting")
	):
		current_scene.call("request_multiplayer_simple_crafting", recipe_id)
		return
	var expected_revision := (
		run_state.get_inventory_revision_for_peer(
			run_state.active_multiplayer_peer_id
		)
		if run_state.active_multiplayer_peer_id > 0
		else run_state.get_inventory_revision()
	)
	var result := run_state.try_craft_inventory_recipe_if_revision(
		recipe,
		expected_revision
	)
	simple_crafting_panel.show_result(recipe_id, result)


func show_simple_crafting_result(
	recipe_id: StringName,
	result: StringName
) -> void:
	simple_crafting_panel.show_result(recipe_id, result)


func _refresh_item_detail() -> void:
	if current_tab != 0 or selected_slot_index < 0 or selected_slot_index >= slots.size():
		_hide_item_detail()
		return

	var item := run_state.get_item(selected_slot_index)
	if item == null:
		_clear_inventory_selection()
		return

	var is_consumable := _is_consumable_item(item)
	var is_material := item.pickup_type == PickupConfig.PickupType.MATERIAL
	var is_building := item.pickup_type == PickupConfig.PickupType.BUILDING
	var stack_count := run_state.get_item_count(selected_slot_index)
	item_detail_title.text = (
		"%s ×%d" % [item.display_name, stack_count]
		if stack_count > 1
		else item.display_name
	)
	item_detail_category_label.text = _get_item_type_label(item)
	item_detail_category_backing.texture = (
		ITEM_CATEGORY_ITEM_TEXTURE
		if is_consumable or is_material
		else ITEM_CATEGORY_COLLECTIBLE_TEXTURE
	)
	item_detail_description.text = item.description if not item.description.is_empty() else "暂无描述"
	item_detail_hint.visible = is_consumable
	item_detail_hint.text = (
		"也可以双击槽位进入建造模式"
		if is_building
		else "也可以双击槽位使用"
	)
	item_detail_use_button.visible = is_consumable
	item_detail_use_button.text = "建造" if is_building else "使用"
	item_detail_discard_button.visible = true
	item_detail_discard_button.text = (
		"销毁"
		if is_building
		else ("删除" if is_material else "丢弃")
	)
	item_detail_panel.visible = true
	item_detail_panel.move_to_front()
	_update_item_detail_position(slots[selected_slot_index])


func _hide_item_detail() -> void:
	item_detail_panel.visible = false


func _update_item_detail_position(slot: InventorySlot) -> void:
	if slot == null:
		return
	var slot_size := slot.size
	if slot_size.x <= 0.0 or slot_size.y <= 0.0:
		slot_size = slot.custom_minimum_size
	var slot_position := inventory_grid.position + slot.position
	var target_x := slot_position.x + slot_size.x + ITEM_DETAIL_MARGIN
	if target_x + ITEM_DETAIL_SIZE.x > DESIGN_SIZE.x - ITEM_DETAIL_MARGIN:
		target_x = slot_position.x - ITEM_DETAIL_MARGIN - ITEM_DETAIL_SIZE.x
	target_x = clampf(target_x, ITEM_DETAIL_MARGIN, DESIGN_SIZE.x - ITEM_DETAIL_SIZE.x - ITEM_DETAIL_MARGIN)

	var target_y := clampf(
		slot_position.y,
		ITEM_DETAIL_MARGIN,
		DESIGN_SIZE.y - ITEM_DETAIL_SIZE.y - ITEM_DETAIL_MARGIN
	)
	item_detail_panel.position = Vector2(roundf(target_x), roundf(target_y))
	item_detail_panel.size = ITEM_DETAIL_SIZE


func _on_detail_use_pressed() -> void:
	if selected_slot_index < 0:
		return
	_try_use_slot(selected_slot_index)


func _on_detail_discard_pressed() -> void:
	if selected_slot_index < 0:
		return
	if _request_multiplayer_inventory_item_discard(selected_slot_index):
		return
	if run_state.discard_item(selected_slot_index):
		_refresh_inventory()
		_refresh_stat_display()


func _is_consumable_item(item: PickupConfig) -> bool:
	return (
		item != null
		and item.pickup_type != PickupConfig.PickupType.COLLECTIBLE
		and item.pickup_type != PickupConfig.PickupType.MATERIAL
	)


func _get_item_type_label(item: PickupConfig) -> String:
	if item != null and item.pickup_type == PickupConfig.PickupType.COLLECTIBLE:
		return "收藏品"
	if item != null and item.pickup_type == PickupConfig.PickupType.MATERIAL:
		return "物资"
	if item != null and item.pickup_type == PickupConfig.PickupType.BUILDING:
		return "建筑"
	return "道具"


func _try_begin_building_placement(slot_index: int) -> void:
	var current_scene := get_tree().current_scene
	if (
		current_scene == null
		or not current_scene.has_method("begin_inventory_building_placement")
	):
		_refresh_item_detail()
		return
	var expected_revision := (
		run_state.get_inventory_revision_for_peer(
			run_state.active_multiplayer_peer_id
		)
		if run_state.active_multiplayer_peer_id > 0
		else run_state.get_inventory_revision()
	)
	close()
	var started := bool(current_scene.call(
		"begin_inventory_building_placement",
		slot_index,
		expected_revision
	))
	if not started:
		open()


func _request_multiplayer_inventory_item_use(slot_index: int) -> bool:
	var current_scene := get_tree().current_scene
	if current_scene == null or not current_scene.has_method("request_multiplayer_inventory_item_use"):
		return false
	current_scene.call("request_multiplayer_inventory_item_use", slot_index)
	return true


func _request_multiplayer_inventory_item_discard(slot_index: int) -> bool:
	var current_scene := get_tree().current_scene
	if current_scene == null or not current_scene.has_method("request_multiplayer_inventory_item_discard"):
		return false
	current_scene.call("request_multiplayer_inventory_item_discard", slot_index)
	return true


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
