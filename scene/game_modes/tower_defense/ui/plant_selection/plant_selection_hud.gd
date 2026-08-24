extends CanvasLayer
class_name PlantSelectionHUD

signal selection_confirmed(config: PlantDefenseConfig)
signal cancel_requested

const PLANT_CARD_SCENE := preload("res://scene/game_modes/tower_defense/ui/plant_selection/plant_selection_card.tscn")
const TRANSITION_SECONDS := 0.12
const CATEGORY_ORDER: Array[int] = [
	PlantDefenseConfig.BuildingCategory.DEFENSE_TOWER,
	PlantDefenseConfig.BuildingCategory.SUPPORT_TOWER,
	PlantDefenseConfig.BuildingCategory.PRODUCTION_BUILDING,
	PlantDefenseConfig.BuildingCategory.TECHNOLOGY_BUILDING,
	PlantDefenseConfig.BuildingCategory.FENCE,
	PlantDefenseConfig.BuildingCategory.TERRAIN_BUILDING,
	PlantDefenseConfig.BuildingCategory.STORAGE_BUILDING,
]

@onready var root_control: Control = $Root
@onready var dim: ColorRect = $Root/Dim
@onready var catalog_panel: PanelContainer = $Root/ScreenMargin/Content
@onready var outer_scroll: ScrollContainer = (
	$Root/ScreenMargin/Content/Margin/Layout/CatalogScroll
)
@onready var confirm_button: Button = (
	$Root/ScreenMargin/Content/Margin/Layout/Footer/ConfirmButton
)
@onready var cancel_button: Button = (
	$Root/ScreenMargin/Content/Margin/Layout/Footer/CancelButton
)
@onready var hint_label: Label = $Root/ScreenMargin/Content/Margin/Layout/Hint

var cards: Array[PlantSelectionCard] = []
var available_configs: Array[PlantDefenseConfig] = []
var selected_config: PlantDefenseConfig = null
var free_placement_mode := false
var item_counts_by_plant_id: Dictionary = {}
var category_card_rows: Dictionary = {}
var category_headers: Dictionary = {}
var category_cards: Dictionary = {}
var category_last_selected_ids: Dictionary = {}
var saved_outer_scroll := 0
var last_selected_plant_id: StringName = &""
var selected_category_index := 0
var _open := false
var _transition_generation := 0
var _transition_tween: Tween = null


func _ready() -> void:
	_configure_category_nodes()
	hide()
	root_control.hide()
	confirm_button.pressed.connect(_confirm_selection)
	cancel_button.pressed.connect(_request_cancel)
	dim.gui_input.connect(_on_dim_gui_input)
	var settings := get_node_or_null("/root/UserSettings")
	if settings != null:
		var binding_callback := Callable(self, "_on_action_bindings_changed")
		if not settings.is_connected(&"action_bindings_changed", binding_callback):
			settings.connect(&"action_bindings_changed", binding_callback)
	_refresh_hotkey_hint()
	set_process_unhandled_input(false)


func _on_action_bindings_changed(action: StringName) -> void:
	if action in [&"interact", &"plant", &"quit"]:
		_refresh_hotkey_hint()


func _refresh_hotkey_hint() -> void:
	var settings := get_node_or_null("/root/UserSettings")
	if settings == null:
		return
	var interact_key := str(
		settings.call("get_primary_binding_text", "interact", "未绑定", true)
	)
	var plant_key := str(
		settings.call("get_primary_binding_text", "plant", "未绑定", true)
	)
	var quit_key := str(
		settings.call("get_primary_binding_text", "quit", "未绑定", true)
	)
	hint_label.text = (
		"左右切换建筑  ·  上下切换分类  ·  Enter / %s 部署  ·  "
		+ "%s / 右键 / %s 关闭"
	) % [interact_key, quit_key, plant_key]


func open(
	configs: Array[PlantDefenseConfig],
	item_counts: Dictionary = {},
	allow_free_placement: bool = false
) -> bool:
	if configs.is_empty():
		return false
	available_configs.assign(configs)
	available_configs.sort_custom(_config_precedes)
	item_counts_by_plant_id = item_counts.duplicate()
	free_placement_mode = allow_free_placement
	_build_cards()
	_restore_selected_config()
	_refresh_selection(false)
	_open = true
	_transition_generation += 1
	_kill_transition_tween()
	show()
	root_control.show()
	root_control.mouse_filter = Control.MOUSE_FILTER_PASS
	dim.modulate.a = 0.0
	catalog_panel.modulate.a = 0.0
	set_process_unhandled_input(true)
	_transition_tween = create_tween().set_parallel(true)
	_transition_tween.tween_property(
		dim,
		"modulate:a",
		1.0,
		TRANSITION_SECONDS
	)
	_transition_tween.tween_property(
		catalog_panel,
		"modulate:a",
		1.0,
		TRANSITION_SECONDS
	)
	call_deferred("_restore_scroll_and_focus")
	return true


func close() -> void:
	if not _open and not visible:
		return
	_capture_scroll_positions()
	_open = false
	_transition_generation += 1
	var close_generation := _transition_generation
	set_process_unhandled_input(false)
	root_control.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_kill_transition_tween()
	_transition_tween = create_tween().set_parallel(true)
	_transition_tween.tween_property(
		dim,
		"modulate:a",
		0.0,
		TRANSITION_SECONDS
	)
	_transition_tween.tween_property(
		catalog_panel,
		"modulate:a",
		0.0,
		TRANSITION_SECONDS
	)
	_transition_tween.finished.connect(
		func() -> void:
			if close_generation != _transition_generation or _open:
				return
			root_control.hide()
			hide()
			dim.modulate.a = 1.0
			catalog_panel.modulate.a = 1.0
	)


func is_open() -> bool:
	return _open


func refresh_item_counts(item_counts: Dictionary) -> void:
	item_counts_by_plant_id = item_counts.duplicate()
	for card in cards:
		card.update_availability(
			_get_owned_count(card.plant_config),
			free_placement_mode
		)
	_refresh_category_headers()
	_refresh_selection(false)


func get_category_card_count(category: int) -> int:
	var typed_cards := category_cards.get(category, []) as Array
	return typed_cards.size()


func get_category_flow(category: int) -> HFlowContainer:
	return category_card_rows.get(category) as HFlowContainer


func get_category_row_count(category: int) -> int:
	var card_count := get_category_card_count(category)
	if card_count == 0:
		return 0
	var flow := get_category_flow(category)
	if flow == null:
		return 0
	return flow.get_line_count()


func _unhandled_input(event: InputEvent) -> void:
	if not _open:
		return
	if event.is_action_pressed(&"ui_left") or event.is_action_pressed(&"move_left"):
		_select_item_relative(-1)
		get_viewport().set_input_as_handled()
		return
	if event.is_action_pressed(&"ui_right") or event.is_action_pressed(&"move_right"):
		_select_item_relative(1)
		get_viewport().set_input_as_handled()
		return
	if event.is_action_pressed(&"ui_up") or event.is_action_pressed(&"move_up"):
		_select_category_relative(-1)
		get_viewport().set_input_as_handled()
		return
	if event.is_action_pressed(&"ui_down") or event.is_action_pressed(&"move_down"):
		_select_category_relative(1)
		get_viewport().set_input_as_handled()
		return
	if event.is_action_pressed(&"ui_accept") or event.is_action_pressed(&"interact"):
		_confirm_selection()
		get_viewport().set_input_as_handled()
		return
	if event.is_action_pressed(&"quit"):
		_request_cancel()
		get_viewport().set_input_as_handled()


func _configure_category_nodes() -> void:
	_register_category_nodes(
		PlantDefenseConfig.BuildingCategory.DEFENSE_TOWER,
		$Root/ScreenMargin/Content/Margin/Layout/CatalogScroll/Rows/DefenseRow
	)
	_register_category_nodes(
		PlantDefenseConfig.BuildingCategory.SUPPORT_TOWER,
		$Root/ScreenMargin/Content/Margin/Layout/CatalogScroll/Rows/SupportRow
	)
	_register_category_nodes(
		PlantDefenseConfig.BuildingCategory.PRODUCTION_BUILDING,
		$Root/ScreenMargin/Content/Margin/Layout/CatalogScroll/Rows/ProductionRow
	)
	_register_category_nodes(
		PlantDefenseConfig.BuildingCategory.TECHNOLOGY_BUILDING,
		$Root/ScreenMargin/Content/Margin/Layout/CatalogScroll/Rows/TechnologyRow
	)
	_register_category_nodes(
		PlantDefenseConfig.BuildingCategory.FENCE,
		$Root/ScreenMargin/Content/Margin/Layout/CatalogScroll/Rows/FenceRow
	)
	_register_category_nodes(
		PlantDefenseConfig.BuildingCategory.TERRAIN_BUILDING,
		$Root/ScreenMargin/Content/Margin/Layout/CatalogScroll/Rows/TerrainRow
	)
	_register_category_nodes(
		PlantDefenseConfig.BuildingCategory.STORAGE_BUILDING,
		$Root/ScreenMargin/Content/Margin/Layout/CatalogScroll/Rows/StorageRow
	)


func _register_category_nodes(category: int, row: VBoxContainer) -> void:
	category_headers[category] = row.get_node("Header") as Label
	category_card_rows[category] = row.get_node("Cards") as HFlowContainer
	category_cards[category] = []


func _build_cards() -> void:
	for category in CATEGORY_ORDER:
		var card_row := category_card_rows[category] as HFlowContainer
		for child in card_row.get_children():
			child.free()
		category_cards[category] = []
	cards.clear()
	for config in available_configs:
		if not category_card_rows.has(config.building_category):
			continue
		var card := PLANT_CARD_SCENE.instantiate() as PlantSelectionCard
		var card_row := category_card_rows[config.building_category] as HFlowContainer
		card_row.add_child(card)
		card.setup(
			config,
			_get_owned_count(config),
			free_placement_mode,
			false
		)
		card.plant_selected.connect(_select_config)
		card.plant_confirmed.connect(_on_card_confirmed)
		cards.append(card)
		var typed_cards := category_cards[config.building_category] as Array
		typed_cards.append(card)
		category_cards[config.building_category] = typed_cards
	_refresh_category_headers()


func _refresh_category_headers() -> void:
	for category in CATEGORY_ORDER:
		var typed_cards := category_cards.get(category, []) as Array
		var deployable_count := 0
		for card_variant in typed_cards:
			var card := card_variant as PlantSelectionCard
			if card != null and card.can_confirm():
				deployable_count += 1
		var header := category_headers[category] as Label
		header.text = "%s  ·  可部署 %d/%d" % [
			PlantDefenseConfig.get_building_category_label(category),
			deployable_count,
			typed_cards.size(),
		]


func _restore_selected_config() -> void:
	var previous_selection := _find_config(last_selected_plant_id)
	selected_config = previous_selection if _can_deploy_config(previous_selection) else null
	var remembered_fallback: PlantDefenseConfig = null
	if selected_config == null:
		for category in CATEGORY_ORDER:
			var category_id := category_last_selected_ids.get(category, &"") as StringName
			var remembered_config := _find_config(category_id)
			if remembered_fallback == null and remembered_config != null:
				remembered_fallback = remembered_config
			if _can_deploy_config(remembered_config):
				selected_config = remembered_config
				break
	if selected_config == null:
		for config in available_configs:
			if _can_deploy_config(config):
				selected_config = config
				break
	if selected_config == null:
		selected_config = previous_selection
	if selected_config == null:
		selected_config = remembered_fallback
	if selected_config == null and not available_configs.is_empty():
		selected_config = available_configs[0]
	if selected_config != null:
		selected_category_index = maxi(
			CATEGORY_ORDER.find(selected_config.building_category),
			0
		)


func _select_config(config: PlantDefenseConfig) -> void:
	if config == null or not available_configs.has(config):
		return
	selected_config = config
	last_selected_plant_id = config.plant_id
	category_last_selected_ids[config.building_category] = config.plant_id
	selected_category_index = maxi(
		CATEGORY_ORDER.find(config.building_category),
		0
	)
	_refresh_selection(true)


func _on_card_confirmed(config: PlantDefenseConfig) -> void:
	_select_config(config)
	_confirm_selection()


func _select_item_relative(offset: int) -> void:
	if selected_config == null:
		return
	var typed_cards := category_cards.get(
		selected_config.building_category,
		[]
	) as Array
	if typed_cards.is_empty():
		return
	var selected_index := 0
	for card_index in typed_cards.size():
		var card := typed_cards[card_index] as PlantSelectionCard
		if card.plant_config == selected_config:
			selected_index = card_index
			break
	selected_index = wrapi(selected_index + offset, 0, typed_cards.size())
	_select_config((typed_cards[selected_index] as PlantSelectionCard).plant_config)


func _select_category_relative(offset: int) -> void:
	if CATEGORY_ORDER.is_empty():
		return
	selected_category_index = wrapi(
		selected_category_index + offset,
		0,
		CATEGORY_ORDER.size()
	)
	var category := CATEGORY_ORDER[selected_category_index]
	var typed_cards := category_cards.get(category, []) as Array
	if typed_cards.is_empty():
		_select_category_relative(offset)
		return
	var remembered_id := category_last_selected_ids.get(category, &"") as StringName
	var remembered_config := _find_config(remembered_id)
	if _can_deploy_config(remembered_config):
		_select_config(remembered_config)
		return
	for card_variant in typed_cards:
		var card := card_variant as PlantSelectionCard
		if card != null and card.can_confirm():
			_select_config(card.plant_config)
			return
	_select_config(
		remembered_config
		if remembered_config != null
		else (typed_cards[0] as PlantSelectionCard).plant_config
	)


func _refresh_selection(ensure_visible: bool) -> void:
	for card in cards:
		card.set_selected(card.plant_config == selected_config)
	var can_confirm := _can_confirm_selected()
	confirm_button.disabled = not can_confirm
	if selected_config == null:
		confirm_button.text = "部署建筑"
		return
	var owned_count := _get_owned_count(selected_config)
	confirm_button.text = (
		"免费部署 %s" % selected_config.display_name
		if free_placement_mode
		else "部署 %s（可用 %d）" % [selected_config.display_name, owned_count]
	)
	if ensure_visible:
		_focus_selected_card(true)


func _can_confirm_selected() -> bool:
	return _can_deploy_config(selected_config)


func _can_deploy_config(config: PlantDefenseConfig) -> bool:
	return config != null and (free_placement_mode or _get_owned_count(config) > 0)


func _get_owned_count(config: PlantDefenseConfig) -> int:
	if config == null:
		return 0
	return maxi(int(item_counts_by_plant_id.get(config.plant_id, 0)), 0)


func _find_config(plant_id: StringName) -> PlantDefenseConfig:
	if plant_id == &"":
		return null
	for config in available_configs:
		if config.plant_id == plant_id:
			return config
	return null


func _focus_selected_card(ensure_visible: bool) -> void:
	if not _open or selected_config == null:
		return
	for card in cards:
		if card.plant_config != selected_config:
			continue
		card.grab_focus()
		if ensure_visible:
			outer_scroll.ensure_control_visible(card)
		return


func _restore_scroll_and_focus() -> void:
	await get_tree().process_frame
	if not _open:
		return
	_focus_selected_card(false)
	await get_tree().process_frame
	if not _open:
		return
	outer_scroll.scroll_vertical = saved_outer_scroll


func _capture_scroll_positions() -> void:
	if outer_scroll == null:
		return
	saved_outer_scroll = outer_scroll.scroll_vertical


func _confirm_selection() -> void:
	if _can_confirm_selected():
		selection_confirmed.emit(selected_config)


func _request_cancel() -> void:
	if _open:
		cancel_requested.emit()


func _on_dim_gui_input(event: InputEvent) -> void:
	var mouse_event := event as InputEventMouseButton
	if (
		mouse_event != null
		and mouse_event.button_index == MOUSE_BUTTON_RIGHT
		and mouse_event.pressed
	):
		dim.accept_event()
		_request_cancel()


func _kill_transition_tween() -> void:
	if _transition_tween != null and _transition_tween.is_valid():
		_transition_tween.kill()
	_transition_tween = null


func _config_precedes(
	left: PlantDefenseConfig,
	right: PlantDefenseConfig
) -> bool:
	if left.building_category != right.building_category:
		return left.building_category < right.building_category
	if left.menu_order != right.menu_order:
		return left.menu_order < right.menu_order
	return String(left.plant_id) < String(right.plant_id)


func _exit_tree() -> void:
	_kill_transition_tween()
