extends CanvasLayer
class_name ProductionBuildingPanel

signal opened
signal closed

const DESIGN_SIZE := Vector2(728.0, 544.0)
const WOOD := preload("res://resources/config/materials/material_wood.tres")
const SAPLING := preload("res://resources/config/materials/material_sapling.tres")

@onready var overlay: Control = $Overlay
@onready var panel_root: Control = $Overlay/PanelRoot
@onready var building_title: Label = $Overlay/PanelRoot/BuildingTitle
@onready var toggle_button: Button = $Overlay/PanelRoot/ToggleButton
@onready var input_slot: InventorySlot = $Overlay/PanelRoot/InputSlot
@onready var output_slots: Array[InventorySlot] = [
	$Overlay/PanelRoot/OutputSlot1,
	$Overlay/PanelRoot/OutputSlot2,
	$Overlay/PanelRoot/OutputSlot3,
]
@onready var progress_bar: ProgressBar = $Overlay/PanelRoot/ProgressBar
@onready var progress_label: Label = $Overlay/PanelRoot/ProgressLabel
@onready var material_list: PanelContainer = $Overlay/PanelRoot/MaterialList
@onready var wood_button: Button = $Overlay/PanelRoot/MaterialList/ListMargin/Rows/WoodButton
@onready var sapling_button: Button = $Overlay/PanelRoot/MaterialList/ListMargin/Rows/SaplingButton
@onready var recipe_rows: Array[Button] = [
	$Overlay/PanelRoot/RecipeScroll/RecipeRows/RecipeRow1,
	$Overlay/PanelRoot/RecipeScroll/RecipeRows/RecipeRow2,
	$Overlay/PanelRoot/RecipeScroll/RecipeRows/RecipeRow3,
	$Overlay/PanelRoot/RecipeScroll/RecipeRows/RecipeRow4,
	$Overlay/PanelRoot/RecipeScroll/RecipeRows/RecipeRow5,
	$Overlay/PanelRoot/RecipeScroll/RecipeRows/RecipeRow6,
]
@onready var status_label: Label = $Overlay/PanelRoot/StatusLabel
@onready var close_button: Button = $Overlay/PanelRoot/CloseButton
@onready var transient_status_timer: Timer = $TransientStatusTimer

var building: ProductionBuilding = null
var tracked_player: Player = null
var bound_coordinator: ProductionCoordinator = null
var transient_status := ""
var _last_visual_remaining_seconds := -1


func _ready() -> void:
	overlay.hide()
	material_list.hide()
	set_process_input(false)
	set_process(false)
	input_slot.pressed.connect(_on_input_slot_pressed)
	toggle_button.pressed.connect(_on_toggle_pressed)
	close_button.pressed.connect(close)
	wood_button.pressed.connect(_on_wood_pressed)
	sapling_button.pressed.connect(_on_sapling_pressed)
	for row_index in recipe_rows.size():
		recipe_rows[row_index].pressed.connect(_on_recipe_row_pressed.bind(row_index))
	transient_status_timer.timeout.connect(_on_transient_status_timeout)
	get_viewport().size_changed.connect(_update_panel_transform)
	_update_panel_transform()
	_clear_slots()


func open_for(new_building: ProductionBuilding, player: Player) -> void:
	bind_building(new_building, player)
	open()


func bind_building(new_building: ProductionBuilding, player: Player) -> void:
	if building == new_building and tracked_player == player:
		_refresh_all()
		return
	_unbind_building()
	building = new_building
	tracked_player = player
	if building != null:
		building.production_state_changed.connect(_refresh_all)
		bound_coordinator = building.production_coordinator
		if bound_coordinator != null:
			bound_coordinator.storage_totals_changed.connect(_refresh_all)
	if tracked_player != null:
		tracked_player.died.connect(_on_tracked_player_died)
	_refresh_all()


func open() -> void:
	if building == null or tracked_player == null or tracked_player.is_dead:
		_unbind_building()
		return
	if overlay.visible:
		return
	show()
	overlay.show()
	set_process_input(true)
	set_process(true)
	tracked_player.set_controls_locked(true)
	material_list.hide()
	_refresh_all()
	building.on_shared_production_panel_opened(self)
	opened.emit()


func close() -> void:
	if not overlay.visible and building == null:
		return
	var closing_building := building
	var closing_player := tracked_player
	var was_open := overlay.visible
	overlay.hide()
	material_list.hide()
	hide()
	set_process_input(false)
	set_process(false)
	transient_status_timer.stop()
	transient_status = ""
	_unbind_building()
	_clear_slots()
	if (
		was_open
		and closing_player != null
		and is_instance_valid(closing_player)
		and not closing_player.is_dead
	):
		closing_player.set_controls_locked(false)
	if not was_open:
		return
	if closing_building != null and is_instance_valid(closing_building):
		closing_building.on_shared_production_panel_closed(self)
	closed.emit()


func is_open() -> bool:
	return overlay.visible


func is_bound_to_building(candidate: ProductionBuilding) -> bool:
	return building == candidate and candidate != null


func _input(event: InputEvent) -> void:
	if not overlay.visible:
		return
	if PlantDefense.is_building_modal_close_event(event):
		get_viewport().set_input_as_handled()
		close()


func _process(_delta: float) -> void:
	if (
		not overlay.visible
		or building == null
		or not is_instance_valid(building)
	):
		set_process(false)
		return
	_refresh_visual_progress()


func _refresh_all() -> void:
	if building == null or not is_instance_valid(building):
		return
	building_title.text = building.config.display_name if building.config != null else "生产建筑"
	toggle_button.text = "Ⅱ" if building.production_enabled else "▶"
	toggle_button.tooltip_text = "暂停生产并清空本轮进度" if building.production_enabled else "启动生产"
	toggle_button.button_pressed = building.production_enabled

	var display_recipe := building.get_display_recipe()
	var coordinator := building.production_coordinator
	if display_recipe != null:
		var input_count := (
			coordinator.get_total_item_count(display_recipe.input_item)
			if coordinator != null
			else 0
		)
		input_slot.set_item(display_recipe.input_item, input_count)
	else:
		input_slot.set_item(null, 0)

	for output_slot in output_slots:
		output_slot.set_item(null, 0)
	if display_recipe != null:
		for output_index in mini(display_recipe.output_items.size(), output_slots.size()):
			output_slots[output_index].set_item(
				display_recipe.output_items[output_index],
				display_recipe.output_amounts[output_index]
			)

	_last_visual_remaining_seconds = -1
	_refresh_visual_progress()
	_refresh_recipe_rows()
	_refresh_material_rows()
	_refresh_status()


func _refresh_progress_text() -> void:
	var recipe := building.get_active_recipe()
	if recipe == null:
		progress_label.text = "请选择右侧配方"
		return
	if not building.production_enabled:
		progress_label.text = "已暂停 · 本轮进度已清空"
		return
	var remaining := ceili(building.get_visual_remaining_seconds())
	if remaining <= 0:
		progress_label.text = "剩余 0 秒 · 等待仓库结算"
	else:
		progress_label.text = "剩余 %d 秒" % remaining


func _refresh_visual_progress() -> void:
	if building == null or not is_instance_valid(building):
		return
	progress_bar.value = building.get_visual_progress_ratio() * 100.0
	var remaining := ceili(building.get_visual_remaining_seconds())
	if remaining == _last_visual_remaining_seconds:
		return
	_last_visual_remaining_seconds = remaining
	_refresh_progress_text()


func _refresh_recipe_rows() -> void:
	for row_index in recipe_rows.size():
		var row := recipe_rows[row_index]
		if row_index >= building.recipes.size():
			row.hide()
			continue
		var recipe := building.recipes[row_index]
		if recipe == null or not recipe.is_valid():
			row.hide()
			continue
		row.show()
		row.set_meta(&"recipe_id", recipe.recipe_id)
		row.icon = recipe.input_item.icon_texture
		row.text = "%s ×%d  →  %s\n约 %.1f 秒" % [
			recipe.input_item.display_name,
			recipe.input_amount,
			recipe.get_output_summary(),
			recipe.duration_seconds,
		]
		row.button_pressed = building.active_recipe_id == recipe.recipe_id


func _refresh_material_rows() -> void:
	var coordinator := building.production_coordinator
	var wood_count := coordinator.get_total_item_count(WOOD) if coordinator != null else 0
	var sapling_count := coordinator.get_total_item_count(SAPLING) if coordinator != null else 0
	wood_button.icon = WOOD.icon_texture
	wood_button.text = "木头    仓库共 %d" % wood_count
	sapling_button.icon = SAPLING.icon_texture
	sapling_button.text = "树苗    仓库共 %d" % sapling_count


func _refresh_status() -> void:
	if not transient_status.is_empty():
		status_label.text = transient_status
		return
	if building.get_active_recipe() == null:
		status_label.text = "点击右侧配方后开始生产；高亮项为当前方案。"
		return
	if not building.production_enabled:
		status_label.text = "生产建筑已关闭。重新启动后从 0 秒开始。"
		return
	match building.completion_wait_reason:
		ProductionCoordinator.RESULT_MISSING_INPUT:
			status_label.text = "进度已到 0 秒，等待任意仓库出现所需原料。"
		ProductionCoordinator.RESULT_STORAGE_FULL:
			status_label.text = "进度已到 0 秒，等待任意仓库腾出产物空间。"
		ProductionCoordinator.RESULT_UNAVAILABLE:
			status_label.text = "仓库网络刚刚发生变化，将在下个同步周期重试。"
		_:
			status_label.text = "原料和产物只在一轮完成瞬间于全场仓库中结算。"


func _on_toggle_pressed() -> void:
	if building == null:
		return
	building.set_production_enabled(not building.production_enabled)


func _on_input_slot_pressed() -> void:
	material_list.visible = not material_list.visible
	if material_list.visible:
		wood_button.grab_focus()


func _on_wood_pressed() -> void:
	material_list.hide()
	_show_transient_status("木头可用于当前加工站；实际用量会在完成瞬间从全场仓库扣除。")


func _on_sapling_pressed() -> void:
	_show_transient_status("树苗与当前配方不匹配，未放入、未消耗任何物品。")


func _on_recipe_row_pressed(row_index: int) -> void:
	if building == null or row_index < 0 or row_index >= recipe_rows.size():
		return
	var recipe_id := StringName(recipe_rows[row_index].get_meta(&"recipe_id", ""))
	if building.select_recipe(recipe_id):
		material_list.hide()
		_refresh_recipe_rows()
		_show_transient_status("已选择配方；当前方案保持高亮。")


func _show_transient_status(message: String) -> void:
	transient_status = message
	transient_status_timer.start()
	_refresh_status()


func _on_transient_status_timeout() -> void:
	transient_status = ""
	_refresh_status()


func _on_tracked_player_died() -> void:
	close()


func _unbind_building() -> void:
	if building != null and is_instance_valid(building):
		if building.production_state_changed.is_connected(_refresh_all):
			building.production_state_changed.disconnect(_refresh_all)
	if (
		bound_coordinator != null
		and is_instance_valid(bound_coordinator)
		and bound_coordinator.storage_totals_changed.is_connected(_refresh_all)
	):
		bound_coordinator.storage_totals_changed.disconnect(_refresh_all)
	if tracked_player != null and is_instance_valid(tracked_player):
		if tracked_player.died.is_connected(_on_tracked_player_died):
			tracked_player.died.disconnect(_on_tracked_player_died)
	building = null
	tracked_player = null
	bound_coordinator = null


func _clear_slots() -> void:
	if input_slot != null:
		input_slot.set_item(null, 0)
	for output_slot in output_slots:
		output_slot.set_item(null, 0)


func _update_panel_transform() -> void:
	var viewport_size := Vector2(get_viewport().get_visible_rect().size)
	var scale_factor := minf(
		viewport_size.x / DESIGN_SIZE.x,
		viewport_size.y / DESIGN_SIZE.y
	) * 0.94
	scale_factor = minf(scale_factor, 1.0)
	panel_root.scale = Vector2.ONE * scale_factor
	panel_root.position = (viewport_size - DESIGN_SIZE * scale_factor) * 0.5
