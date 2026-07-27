extends CanvasLayer
class_name PlantSelectionHUD

signal selection_confirmed(config: PlantDefenseConfig)
signal cancel_requested

const PLANT_CARD_SCENE := preload("res://scene/plant_defense/plant_selection_card.tscn")
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
@onready var selected_summary: Label = (
	$Root/ScreenMargin/Content/Margin/Layout/Header/SelectedSummary
)
@onready var confirm_button: Button = (
	$Root/ScreenMargin/Content/Margin/Layout/Footer/ConfirmButton
)
@onready var cancel_button: Button = (
	$Root/ScreenMargin/Content/Margin/Layout/Footer/CancelButton
)

var cards: Array[PlantSelectionCard] = []
var available_configs: Array[PlantDefenseConfig] = []
var selected_config: PlantDefenseConfig = null
var free_placement_mode := false
var item_counts_by_plant_id: Dictionary = {}
var category_scrolls: Dictionary = {}
var category_card_rows: Dictionary = {}
var category_headers: Dictionary = {}
var category_cards: Dictionary = {}
var category_last_selected_ids: Dictionary = {}
var saved_horizontal_scrolls: Dictionary = {}
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
	set_process_unhandled_input(false)


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
	_refresh_selection(false)


func get_category_card_count(category: int) -> int:
	var typed_cards := category_cards.get(category, []) as Array
	return typed_cards.size()


func get_category_scroll(category: int) -> ScrollContainer:
	return category_scrolls.get(category) as ScrollContainer


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
	if event.is_action_pressed(&"ui_cancel"):
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
	category_scrolls[category] = row.get_node("Scroll") as ScrollContainer
	category_card_rows[category] = row.get_node("Scroll/Cards") as HBoxContainer
	category_cards[category] = []


func _build_cards() -> void:
	for category in CATEGORY_ORDER:
		var card_row := category_card_rows[category] as HBoxContainer
		for child in card_row.get_children():
			child.free()
		category_cards[category] = []
	cards.clear()
	for config in available_configs:
		if not category_card_rows.has(config.building_category):
			continue
		var card := PLANT_CARD_SCENE.instantiate() as PlantSelectionCard
		var card_row := category_card_rows[config.building_category] as HBoxContainer
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
	for category in CATEGORY_ORDER:
		var header := category_headers[category] as Label
		header.text = "%s  ·  %d" % [
			PlantDefenseConfig.get_building_category_label(category),
			get_category_card_count(category),
		]


func _restore_selected_config() -> void:
	selected_config = _find_config(last_selected_plant_id)
	if selected_config == null:
		for category in CATEGORY_ORDER:
			var category_id := category_last_selected_ids.get(category, &"") as StringName
			selected_config = _find_config(category_id)
			if selected_config != null:
				break
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
		confirm_button.text = "选择建筑"
		selected_summary.text = "请选择建筑"
		return
	var owned_count := _get_owned_count(selected_config)
	confirm_button.text = (
		"免费放置 %s" % selected_config.display_name
		if free_placement_mode
		else "放置 %s（持有 %d）" % [selected_config.display_name, owned_count]
	)
	selected_summary.text = "%s  ·  %s  ·  %s" % [
		selected_config.display_name,
		"沙盒免费" if free_placement_mode else "持有 %d" % owned_count,
		PlantDefenseConfig.get_placement_surface_label(
			selected_config.placement_surface
		),
	]
	if ensure_visible:
		_focus_selected_card(true)


func _can_confirm_selected() -> bool:
	return (
		selected_config != null
		and (free_placement_mode or _get_owned_count(selected_config) > 0)
	)


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
			var category_scroll := category_scrolls.get(
				selected_config.building_category
			) as ScrollContainer
			if category_scroll != null:
				category_scroll.ensure_control_visible(card)
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
	for category in CATEGORY_ORDER:
		var scroll := category_scrolls[category] as ScrollContainer
		scroll.scroll_horizontal = int(saved_horizontal_scrolls.get(category, 0))


func _capture_scroll_positions() -> void:
	if outer_scroll == null:
		return
	saved_outer_scroll = outer_scroll.scroll_vertical
	for category in CATEGORY_ORDER:
		var scroll := category_scrolls.get(category) as ScrollContainer
		if scroll != null:
			saved_horizontal_scrolls[category] = scroll.scroll_horizontal


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
