extends Control
class_name DebugCollectibleWindow

signal collectible_requested(config_path: String)
signal closed

@onready var close_button: Button = $Center/Panel/Margin/Layout/Header/CloseButton
@onready var collectible_list: ItemList = $Center/Panel/Margin/Layout/CollectibleList
@onready var status_label: Label = $Center/Panel/Margin/Layout/StatusLabel


func _ready() -> void:
	visible = false
	set_process_unhandled_input(false)
	close_button.pressed.connect(close)
	collectible_list.item_clicked.connect(_on_collectible_clicked)
	collectible_list.item_activated.connect(_on_collectible_activated)


func open() -> void:
	_populate_collectibles()
	visible = true
	set_process_unhandled_input(true)
	status_label.text = "点击一个收藏品后直接加入背包"
	move_to_front()
	collectible_list.deselect_all()
	collectible_list.grab_focus()


func close() -> void:
	if not visible:
		return
	# Hiding a focused modal does not guarantee that every close route releases
	# its focused child immediately. Do it explicitly for both the list/F10 path
	# and the focused close-button path so the next gameplay modal owns focus.
	var focus_owner := get_viewport().gui_get_focus_owner()
	if focus_owner != null and (focus_owner == self or is_ancestor_of(focus_owner)):
		focus_owner.release_focus()
	visible = false
	set_process_unhandled_input(false)
	closed.emit()


func toggle() -> void:
	if visible:
		close()
	else:
		open()


func is_open() -> bool:
	return visible


func show_grant_result(config_path: String, success: bool) -> void:
	var item := LuoxiMerchant.get_collectible_for_path(config_path)
	var item_name := item.display_name if item != null else "收藏品"
	status_label.text = "已获得：%s" % item_name if success else "无法获得：%s（背包可能已满）" % item_name


func _unhandled_input(event: InputEvent) -> void:
	if not visible:
		return
	if event.is_action_pressed("cheat_collectibles") or event.is_action_pressed("quit") or event.is_action_pressed("ui_cancel"):
		close()
		get_viewport().set_input_as_handled()


func _populate_collectibles() -> void:
	collectible_list.clear()
	# The debug catalog intentionally includes event-only special collectibles;
	# production reward rolls use CollectibleRegistry.get_standard_random_pool().
	for item_variant in CollectibleRegistry.get_all():
		var item := item_variant as PickupConfig
		if item == null:
			continue
		var item_index := collectible_list.add_item(item.display_name, item.icon_texture, true)
		collectible_list.set_item_metadata(item_index, item.resource_path)
		if not item.description.is_empty():
			collectible_list.set_item_tooltip(item_index, item.description)


func _on_collectible_clicked(index: int, _at_position: Vector2, mouse_button_index: int) -> void:
	if mouse_button_index != MOUSE_BUTTON_LEFT:
		return
	_request_collectible(index)


func _on_collectible_activated(index: int) -> void:
	_request_collectible(index)


func _request_collectible(index: int) -> void:
	if index < 0 or index >= collectible_list.get_item_count():
		return
	var config_path := str(collectible_list.get_item_metadata(index))
	if config_path.is_empty():
		return
	collectible_requested.emit(config_path)
