extends Control
class_name EncyclopediaScreen

signal grid_build_completed(generation: int)

const ENTRY_CARD_SCENE := preload("res://scene/encyclopedia/entry_card.tscn")
const MAIN_MENU_SCENE_PATH := "res://scene/main_menu.tscn"
const CARD_WIDTH := 112.0
const CARD_GAP := 12.0
const GRID_WIDTH_RESERVE := 20.0
const GRID_BASE_BOTTOM_MARGIN := 8
const DETAIL_WIDTH := 344.0
const DETAIL_GAP := 12.0
const PAGE_ENTRANCE_DURATION := 0.18
const SECTION_TRANSITION_DURATION := 0.12
const DETAIL_TRANSITION_DURATION := 0.22
const GRID_REFLOW_FADE_DURATION := 0.07
const INITIAL_GRID_ROWS := 2
const GRID_BUILD_BATCH_SIZE := 10
const CARD_BATCH_FADE_DURATION := 0.08
const STACKABLE_FILTER_KEY := &"stackable"
const RARITY_COLORS := {
	&"common": Color("f0e3c2"),
	&"rare": Color("68d8ff"),
	&"epic": Color("c987ff"),
	&"legendary": Color("ffae32"),
}

@onready var page: Control = $Page
@onready var enemy_button: Button = $Page/PageMargin/ArchiveSurface/SurfaceMargin/PageRow/Sidebar/SectionNav/Buttons/Enemy
@onready var collectible_button: Button = $Page/PageMargin/ArchiveSurface/SurfaceMargin/PageRow/Sidebar/SectionNav/Buttons/Collectible
@onready var building_button: Button = $Page/PageMargin/ArchiveSurface/SurfaceMargin/PageRow/Sidebar/SectionNav/Buttons/Building
@onready var section_nav: Control = $Page/PageMargin/ArchiveSurface/SurfaceMargin/PageRow/Sidebar/SectionNav
@onready var selection_indicator: ColorRect = $Page/PageMargin/ArchiveSurface/SurfaceMargin/PageRow/Sidebar/SectionNav/SelectionIndicator
@onready var back_button: Button = $Page/PageMargin/ArchiveSurface/SurfaceMargin/PageRow/Sidebar/BackButton
@onready var workspace: Control = $Page/PageMargin/ArchiveSurface/SurfaceMargin/PageRow/Workspace
@onready var grid_pane: VBoxContainer = $Page/PageMargin/ArchiveSurface/SurfaceMargin/PageRow/Workspace/GridPane
@onready var section_kicker: Label = $Page/PageMargin/ArchiveSurface/SurfaceMargin/PageRow/Workspace/GridPane/Header/SectionKicker
@onready var section_title: Label = $Page/PageMargin/ArchiveSurface/SurfaceMargin/PageRow/Workspace/GridPane/Header/TitleRow/SectionTitle
@onready var archive_index: Label = $Page/PageMargin/ArchiveSurface/SurfaceMargin/PageRow/Workspace/GridPane/Header/TitleRow/ArchiveIndex
@onready var section_description: Label = $Page/PageMargin/ArchiveSurface/SurfaceMargin/PageRow/Workspace/GridPane/Header/SectionDescription
@onready var search_edit: LineEdit = $Page/PageMargin/ArchiveSurface/SurfaceMargin/PageRow/Workspace/GridPane/Toolbar/Search
@onready var filter_button: OptionButton = $Page/PageMargin/ArchiveSurface/SurfaceMargin/PageRow/Workspace/GridPane/Toolbar/Filter
@onready var result_count: Label = $Page/PageMargin/ArchiveSurface/SurfaceMargin/PageRow/Workspace/GridPane/Toolbar/ResultCount
@onready var grid_area: Control = $Page/PageMargin/ArchiveSurface/SurfaceMargin/PageRow/Workspace/GridPane/GridArea
@onready var grid_scroll: ScrollContainer = $Page/PageMargin/ArchiveSurface/SurfaceMargin/PageRow/Workspace/GridPane/GridArea/GridScroll
@onready var grid_margin: MarginContainer = $Page/PageMargin/ArchiveSurface/SurfaceMargin/PageRow/Workspace/GridPane/GridArea/GridScroll/GridMargin
@onready var entry_grid: GridContainer = $Page/PageMargin/ArchiveSurface/SurfaceMargin/PageRow/Workspace/GridPane/GridArea/GridScroll/GridMargin/EntryGrid
@onready var empty_state: CenterContainer = $Page/PageMargin/ArchiveSurface/SurfaceMargin/PageRow/Workspace/GridPane/GridArea/EmptyState
@onready var detail_panel: EncyclopediaDetailPanel = $Page/PageMargin/ArchiveSurface/SurfaceMargin/PageRow/Workspace/DetailPanel

var _catalog: CodexCatalog
var _current_section: int = CodexSection.ENEMY
var _section_states: Dictionary = {}
var _section_buttons: Array[Button] = []
var _cards: Array[EncyclopediaEntryCard] = []
var _card_pool: Array[EncyclopediaEntryCard] = []
var _pending_grid_entries: Array[CodexEntryViewData] = []
var _pending_grid_index := 0
var _pending_scroll_value := 0
var _pending_scroll_restore := false
var _card_batch_tweens: Array[Tween] = []
var _grid_columns := 1
var _grid_generation := 0
var _completed_grid_generation := -1
var _suppress_toolbar_signals := false
var _section_initialized := false
var _detail_open := false
var _page_tween: Tween
var _section_tween: Tween
var _indicator_tween: Tween
var _detail_tween: Tween
var _grid_reflow_tween: Tween
var _layout_transition_active := false
var _layout_transition_serial := 0
var _transition_anchor_id := &""
var _transition_anchor_screen_y := 0.0
var _grid_anchor_extra_bottom := 0
var _filter_icons: Array[Texture2D] = []


func _ready() -> void:
	_catalog = CodexCatalog.new()
	_section_buttons = [enemy_button, collectible_button, building_button]
	_initialize_section_states()
	_connect_controls()
	_update_sidebar_counts()
	detail_panel.visible = false
	_apply_section(CodexSection.ENEMY)
	_prepare_focus_navigation()
	_prepare_page_entrance()
	call_deferred("_play_page_entrance")
	call_deferred("_sync_selection_indicator", false)


func _unhandled_input(event: InputEvent) -> void:
	if not event.is_action_pressed(&"ui_cancel"):
		return
	if _detail_open:
		_close_detail(true)
	else:
		_return_to_main_menu()
	get_viewport().set_input_as_handled()


func _initialize_section_states() -> void:
	for section in CodexSection.ALL:
		_section_states[section] = {
			"query": "",
			"filter": &"",
			"scroll": 0,
			"selected_id": &"",
		}


func _connect_controls() -> void:
	enemy_button.pressed.connect(_request_section.bind(CodexSection.ENEMY))
	collectible_button.pressed.connect(
		_request_section.bind(CodexSection.COLLECTIBLE)
	)
	building_button.pressed.connect(_request_section.bind(CodexSection.BUILDING))
	back_button.pressed.connect(_return_to_main_menu)
	search_edit.text_changed.connect(_on_search_changed)
	filter_button.item_selected.connect(_on_filter_selected)
	detail_panel.close_requested.connect(_on_detail_close_requested)
	grid_pane.resized.connect(_on_grid_pane_resized)
	grid_scroll.get_v_scroll_bar().value_changed.connect(
		_on_grid_scroll_value_changed
	)


func _update_sidebar_counts() -> void:
	enemy_button.text = "敌人  %d" % _catalog.get_total_count(CodexSection.ENEMY)
	collectible_button.text = (
		"收藏品  %d" % _catalog.get_total_count(CodexSection.COLLECTIBLE)
	)
	building_button.text = (
		"建筑物  %d" % _catalog.get_total_count(CodexSection.BUILDING)
	)


func _request_section(section: int) -> void:
	if not CodexSection.is_valid(section):
		return
	if _section_initialized and section == _current_section:
		return
	_save_current_section_state()
	if (
		_detail_open
		or detail_panel.visible
		or _detail_tween != null
		or _grid_reflow_tween != null
		or _layout_transition_active
	):
		_cancel_detail_transition_for_section_change()
	_set_navigation_visuals(section)
	_move_selection_indicator(_button_for_section(section), true)
	if _section_tween != null:
		_section_tween.kill()
	grid_area.modulate = Color.WHITE
	_section_tween = create_tween()
	_section_tween.tween_property(
		grid_area,
		"modulate:a",
		0.0,
		SECTION_TRANSITION_DURATION * 0.5
	).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN)
	_section_tween.tween_callback(_apply_section.bind(section))
	_section_tween.tween_property(
		grid_area,
		"modulate:a",
		1.0,
		SECTION_TRANSITION_DURATION * 0.5
	).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_OUT)
	_section_tween.finished.connect(func() -> void: _section_tween = null)


func _apply_section(section: int) -> void:
	_current_section = section
	_section_initialized = true
	var state: Dictionary = _section_states[section]
	_suppress_toolbar_signals = true
	search_edit.text = String(state["query"])
	_populate_filter_options(section, StringName(state["filter"]))
	_suppress_toolbar_signals = false
	section_kicker.text = _section_kicker_text(section)
	section_title.text = "%s档案" % CodexSection.get_label(section)
	section_description.text = _section_description_text(section)
	archive_index.text = "%03d 条记录" % _catalog.get_total_count(section)
	_set_navigation_visuals(section)
	_refresh_grid(false)
	_prepare_focus_navigation()


func _populate_filter_options(section: int, selected_key: StringName) -> void:
	_filter_icons.clear()
	filter_button.clear()
	filter_button.add_item("全部分类")
	filter_button.set_item_metadata(0, &"")
	var selected_index := 0
	for option in _catalog.get_filter_options(section):
		var option_key := StringName(option["key"])
		filter_button.add_item("%s  %d" % [option["label"], option["count"]])
		var item_index := filter_button.item_count - 1
		filter_button.set_item_metadata(item_index, option_key)
		if option_key == selected_key:
			selected_index = item_index
	if section == CodexSection.COLLECTIBLE:
		var stackable_count := _count_stackable_collectibles()
		filter_button.add_item("可叠加  %d" % stackable_count)
		var stackable_index := filter_button.item_count - 1
		filter_button.set_item_metadata(stackable_index, STACKABLE_FILTER_KEY)
		if selected_key == STACKABLE_FILTER_KEY:
			selected_index = stackable_index
	_apply_filter_option_visuals(section)
	filter_button.select(selected_index)
	if selected_index == 0:
		var state: Dictionary = _section_states[section]
		state["filter"] = &""


func _on_search_changed(query: String) -> void:
	if _suppress_toolbar_signals:
		return
	var state: Dictionary = _section_states[_current_section]
	state["query"] = query
	state["scroll"] = 0
	_refresh_grid(true)


func _on_filter_selected(index: int) -> void:
	if _suppress_toolbar_signals:
		return
	var state: Dictionary = _section_states[_current_section]
	state["filter"] = StringName(filter_button.get_item_metadata(index))
	state["scroll"] = 0
	_refresh_grid(true)


func _refresh_grid(reset_scroll: bool) -> void:
	_grid_generation += 1
	_set_grid_anchor_extra_bottom(0)
	var generation := _grid_generation
	_cancel_card_batch_tweens()
	_recycle_active_cards()
	_pending_grid_entries.clear()
	_pending_grid_index = 0

	var state: Dictionary = _section_states[_current_section]
	var query := String(state["query"]).strip_edges().to_lower()
	var filter_key := StringName(state["filter"])
	for entry in _catalog.get_entries(_current_section):
		if entry.visibility_state == CodexVisibilityState.HIDDEN:
			continue
		if filter_key == STACKABLE_FILTER_KEY:
			if entry.secondary_badge != "可叠加":
				continue
		elif filter_key != &"" and entry.filter_key != filter_key:
			continue
		if not query.is_empty():
			if entry.visibility_state == CodexVisibilityState.UNKNOWN:
				continue
			if not entry.display_name.to_lower().contains(query):
				continue
		_pending_grid_entries.append(entry)

	var total_count := _catalog.get_entries(_current_section).size()
	result_count.text = "显示 %d / %d" % [_pending_grid_entries.size(), total_count]
	empty_state.visible = _pending_grid_entries.is_empty()
	grid_scroll.visible = not _pending_grid_entries.is_empty()
	_pending_scroll_value = 0 if reset_scroll else int(state["scroll"])
	_pending_scroll_restore = not reset_scroll and _pending_scroll_value > 0
	grid_scroll.scroll_vertical = 0
	call_deferred("_begin_grid_build", generation)


func _begin_grid_build(generation: int) -> void:
	if generation != _grid_generation:
		return
	_update_grid_columns()
	if _pending_grid_entries.is_empty():
		_pending_scroll_restore = false
		_prepare_focus_navigation()
		_mark_grid_build_complete(generation)
		return
	var initial_row_count := maxi(
		INITIAL_GRID_ROWS,
		int(ceil(float(GRID_BUILD_BATCH_SIZE) / float(_grid_columns)))
	)
	var initial_card_count := mini(
		_pending_grid_entries.size(),
		_grid_columns * initial_row_count
	)
	_append_grid_batch(generation, initial_card_count)
	_build_remaining_grid_entries(generation)


func _build_remaining_grid_entries(generation: int) -> void:
	while (
		generation == _grid_generation
		and _pending_grid_index < _pending_grid_entries.size()
	):
		await get_tree().process_frame
		if generation != _grid_generation:
			return
		_append_grid_batch(generation, GRID_BUILD_BATCH_SIZE)
	if generation != _grid_generation:
		return
	await get_tree().process_frame
	if generation == _grid_generation and _pending_scroll_restore:
		_pending_scroll_restore = false
		grid_scroll.scroll_vertical = mini(
			_pending_scroll_value,
			_maximum_grid_scroll()
		)
	if generation == _grid_generation:
		_mark_grid_build_complete(generation)


func _append_grid_batch(generation: int, batch_size: int) -> void:
	if generation != _grid_generation or batch_size <= 0:
		return
	var batch: Array[EncyclopediaEntryCard] = []
	var batch_end := mini(
		_pending_grid_index + batch_size,
		_pending_grid_entries.size()
	)
	while _pending_grid_index < batch_end:
		var entry := _pending_grid_entries[_pending_grid_index]
		var card := _obtain_card()
		entry_grid.move_child(card, _cards.size())
		card.setup(entry)
		card.modulate.a = 0.0
		card.visible = true
		_cards.append(card)
		batch.append(card)
		_pending_grid_index += 1
	_rebuild_card_focus_neighbours()
	_fade_in_card_batch(batch)


func _obtain_card() -> EncyclopediaEntryCard:
	if not _card_pool.is_empty():
		var reused_card := _card_pool.pop_back() as EncyclopediaEntryCard
		reused_card.reset_interaction_state()
		return reused_card
	var card := ENTRY_CARD_SCENE.instantiate() as EncyclopediaEntryCard
	entry_grid.add_child(card)
	card.entry_pressed.connect(_on_card_pressed)
	card.entry_focused.connect(_on_card_focused)
	return card


func _recycle_active_cards() -> void:
	var focused_control := get_viewport().gui_get_focus_owner()
	for card in _cards:
		if focused_control == card.get_focus_control():
			card.get_focus_control().release_focus()
		card.visible = false
		card.modulate.a = 1.0
		_card_pool.append(card)
	_cards.clear()


func _fade_in_card_batch(batch: Array[EncyclopediaEntryCard]) -> void:
	if batch.is_empty():
		return
	var fade_tween := create_tween().set_parallel(true)
	for card in batch:
		fade_tween.tween_property(
			card,
			"modulate:a",
			1.0,
			CARD_BATCH_FADE_DURATION
		).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_OUT)
	_card_batch_tweens.append(fade_tween)


func _cancel_card_batch_tweens() -> void:
	for tween in _card_batch_tweens:
		if tween != null and tween.is_valid():
			tween.kill()
	_card_batch_tweens.clear()


func is_grid_build_complete() -> bool:
	return _completed_grid_generation == _grid_generation


func _mark_grid_build_complete(generation: int) -> void:
	if generation != _grid_generation:
		return
	_completed_grid_generation = generation
	grid_build_completed.emit(generation)


func _on_card_focused(entry: CodexEntryViewData) -> void:
	_cancel_pending_scroll_restore()
	var state: Dictionary = _section_states[_current_section]
	state["selected_id"] = entry.entry_id


func _on_card_pressed(entry: CodexEntryViewData) -> void:
	if entry.visibility_state != CodexVisibilityState.REVEALED:
		return
	_cancel_pending_scroll_restore()
	var state: Dictionary = _section_states[_current_section]
	state["selected_id"] = entry.entry_id
	_open_detail(entry)


func _on_grid_scroll_value_changed(value: float) -> void:
	if _pending_scroll_restore and not is_zero_approx(value):
		_cancel_pending_scroll_restore()


func _cancel_pending_scroll_restore() -> void:
	_pending_scroll_restore = false


func _open_detail(entry: CodexEntryViewData) -> void:
	detail_panel.show_entry(entry)
	if _detail_open:
		return
	_detail_open = true
	if _detail_tween != null:
		_detail_tween.kill()
	_begin_layout_transition()
	detail_panel.visible = true
	detail_panel.offset_left = 0.0
	detail_panel.offset_right = DETAIL_WIDTH
	detail_panel.modulate = Color(1.0, 1.0, 1.0, 0.0)
	_detail_tween = create_tween().set_parallel(true)
	_detail_tween.tween_property(
		grid_pane,
		"offset_right",
		-(DETAIL_WIDTH + DETAIL_GAP),
		DETAIL_TRANSITION_DURATION
	).set_trans(Tween.TRANS_QUART).set_ease(Tween.EASE_OUT)
	_detail_tween.tween_property(
		detail_panel,
		"offset_left",
		-DETAIL_WIDTH,
		DETAIL_TRANSITION_DURATION
	).set_trans(Tween.TRANS_QUART).set_ease(Tween.EASE_OUT)
	_detail_tween.tween_property(
		detail_panel,
		"offset_right",
		0.0,
		DETAIL_TRANSITION_DURATION
	).set_trans(Tween.TRANS_QUART).set_ease(Tween.EASE_OUT)
	_detail_tween.tween_property(
		detail_panel,
		"modulate",
		Color.WHITE,
		DETAIL_TRANSITION_DURATION * 0.75
	).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_OUT)
	_detail_tween.finished.connect(_on_detail_open_finished)
	_start_grid_reflow(
		workspace.size.x - DETAIL_WIDTH - DETAIL_GAP,
		Tween.EASE_OUT
	)


func _on_detail_open_finished() -> void:
	_detail_tween = null
	grid_pane.offset_right = -(DETAIL_WIDTH + DETAIL_GAP)
	_finish_layout_transition()
	_rebuild_card_focus_neighbours()
	_configure_detail_focus_neighbours()


func _on_detail_close_requested() -> void:
	_close_detail(true)


func _close_detail(animate: bool, restore_focus: bool = true) -> void:
	if not _detail_open:
		return
	_detail_open = false
	if _detail_tween != null:
		_detail_tween.kill()
		_detail_tween = null
	if _grid_reflow_tween != null:
		_grid_reflow_tween.kill()
		_grid_reflow_tween = null
	if not animate:
		_finish_detail_close(restore_focus)
		return
	_begin_layout_transition()
	_detail_tween = create_tween().set_parallel(true)
	_detail_tween.tween_property(
		grid_pane,
		"offset_right",
		0.0,
		DETAIL_TRANSITION_DURATION
	).set_trans(Tween.TRANS_QUART).set_ease(Tween.EASE_OUT)
	_detail_tween.tween_property(
		detail_panel,
		"offset_left",
		0.0,
		DETAIL_TRANSITION_DURATION
	).set_trans(Tween.TRANS_QUART).set_ease(Tween.EASE_OUT)
	_detail_tween.tween_property(
		detail_panel,
		"offset_right",
		DETAIL_WIDTH,
		DETAIL_TRANSITION_DURATION
	).set_trans(Tween.TRANS_QUART).set_ease(Tween.EASE_OUT)
	_detail_tween.tween_property(
		detail_panel,
		"modulate:a",
		0.0,
		DETAIL_TRANSITION_DURATION * 0.75
	).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN)
	_detail_tween.finished.connect(_finish_detail_close.bind(restore_focus))
	_start_grid_reflow(
		workspace.size.x,
		Tween.EASE_OUT,
		DETAIL_TRANSITION_DURATION - GRID_REFLOW_FADE_DURATION * 2.0
	)


func _finish_detail_close(restore_focus: bool = true) -> void:
	_detail_tween = null
	detail_panel.visible = false
	detail_panel.offset_left = 0.0
	detail_panel.offset_right = DETAIL_WIDTH
	detail_panel.modulate = Color.WHITE
	detail_panel.clear_entry()
	grid_pane.offset_right = 0.0
	_finish_layout_transition()
	_rebuild_card_focus_neighbours()
	call_deferred(
		"_finalize_closed_grid_padding",
		_layout_transition_serial
	)
	if restore_focus:
		call_deferred("_restore_selected_card_focus")


func _cancel_detail_transition_for_section_change() -> void:
	if _detail_tween != null:
		_detail_tween.kill()
		_detail_tween = null
	if _grid_reflow_tween != null:
		_grid_reflow_tween.kill()
		_grid_reflow_tween = null
	_detail_open = false
	_layout_transition_serial += 1
	_transition_anchor_id = &""
	_transition_anchor_screen_y = NAN
	_set_grid_anchor_extra_bottom(0)
	_finish_detail_close(false)
	grid_area.modulate = Color.WHITE


func _save_current_section_state() -> void:
	if not _section_initialized:
		return
	var state: Dictionary = _section_states[_current_section]
	state["query"] = search_edit.text
	state["filter"] = _selected_filter_key()
	state["scroll"] = grid_scroll.scroll_vertical


func _selected_filter_key() -> StringName:
	if filter_button.item_count == 0 or filter_button.selected < 0:
		return &""
	return StringName(filter_button.get_item_metadata(filter_button.selected))


func _count_stackable_collectibles() -> int:
	var count := 0
	for entry in _catalog.get_entries(CodexSection.COLLECTIBLE):
		if (
			entry.visibility_state != CodexVisibilityState.HIDDEN
			and entry.secondary_badge == "可叠加"
		):
			count += 1
	return count


func _apply_filter_option_visuals(section: int) -> void:
	if section != CodexSection.COLLECTIBLE:
		return
	var popup := filter_button.get_popup()
	popup.add_theme_constant_override(&"icon_max_width", 14)
	popup.add_theme_constant_override(&"item_start_padding", 10)
	popup.add_theme_constant_override(&"item_end_padding", 10)
	for index in filter_button.item_count:
		var key := StringName(filter_button.get_item_metadata(index))
		var color := Color(0.52, 0.56, 0.54)
		if RARITY_COLORS.has(key):
			color = RARITY_COLORS[key]
		elif key == STACKABLE_FILTER_KEY:
			color = Color("62d7a4")
		var icon := _make_filter_swatch(color)
		_filter_icons.append(icon)
		filter_button.set_item_icon(index, icon)
		popup.set_item_icon_max_width(index, 12)
		if RARITY_COLORS.has(key):
			popup.set_item_tooltip(index, "%s稀有度" % filter_button.get_item_text(index))
		elif key == STACKABLE_FILTER_KEY:
			popup.set_item_tooltip(index, "仅显示每份都能参与效果计算的收藏品")


func _make_filter_swatch(color: Color) -> Texture2D:
	var gradient := Gradient.new()
	gradient.colors = PackedColorArray([color, color])
	var texture := GradientTexture2D.new()
	texture.width = 12
	texture.height = 12
	texture.fill_from = Vector2(0.0, 0.0)
	texture.fill_to = Vector2(1.0, 1.0)
	texture.gradient = gradient
	return texture


func _return_to_main_menu() -> void:
	_save_current_section_state()
	MainMenu.request_focus_after_return(&"encyclopedia")
	get_tree().change_scene_to_file(MAIN_MENU_SCENE_PATH)


func _on_grid_pane_resized() -> void:
	if _layout_transition_active:
		call_deferred("_update_grid_spacing")
	else:
		call_deferred("_update_grid_columns")


func _begin_layout_transition() -> void:
	_layout_transition_active = true
	_layout_transition_serial += 1
	var state: Dictionary = _section_states[_current_section]
	_transition_anchor_id = StringName(state["selected_id"])
	var anchor_card := _card_for_entry_id(_transition_anchor_id)
	_transition_anchor_screen_y = (
		anchor_card.global_position.y if anchor_card != null else NAN
	)


func _start_grid_reflow(
	target_pane_width: float,
	ease: Tween.EaseType,
	delay: float = 0.0
) -> void:
	if _grid_reflow_tween != null:
		_grid_reflow_tween.kill()
	var target_columns := _columns_for_width(target_pane_width)
	_grid_reflow_tween = create_tween()
	if delay > 0.0:
		_grid_reflow_tween.tween_interval(delay)
	_grid_reflow_tween.tween_property(
		grid_area,
		"modulate:a",
		0.0,
		GRID_REFLOW_FADE_DURATION
	).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN)
	_grid_reflow_tween.tween_callback(_apply_grid_reflow.bind(target_columns))
	_grid_reflow_tween.tween_property(
		grid_area,
		"modulate:a",
		1.0,
		GRID_REFLOW_FADE_DURATION
	).set_trans(Tween.TRANS_SINE).set_ease(ease)
	_grid_reflow_tween.finished.connect(func() -> void: _grid_reflow_tween = null)


func _apply_grid_reflow(columns: int) -> void:
	_grid_columns = columns
	entry_grid.columns = columns
	_update_grid_spacing()
	call_deferred("_restore_transition_anchor", _layout_transition_serial)


func _finish_layout_transition() -> void:
	_layout_transition_active = false
	if _grid_reflow_tween != null:
		_grid_reflow_tween.kill()
		_grid_reflow_tween = null
	grid_area.modulate.a = 1.0
	var columns := _columns_for_width(grid_pane.size.x)
	if columns != _grid_columns or entry_grid.columns != columns:
		_apply_grid_reflow(columns)
	else:
		_update_grid_spacing()
	call_deferred("_restore_transition_anchor", _layout_transition_serial)


func _restore_transition_anchor(transition_serial: int) -> void:
	if transition_serial != _layout_transition_serial:
		return
	if is_nan(_transition_anchor_screen_y):
		return
	var anchor_card := _card_for_entry_id(_transition_anchor_id)
	if anchor_card == null or not anchor_card.is_visible_in_tree():
		return
	var screen_delta := anchor_card.global_position.y - _transition_anchor_screen_y
	var target_scroll := grid_scroll.scroll_vertical + int(round(screen_delta))
	var maximum_scroll := _maximum_grid_scroll()
	if target_scroll > maximum_scroll:
		_set_grid_anchor_extra_bottom(
			_grid_anchor_extra_bottom + target_scroll - maximum_scroll
		)
		await get_tree().process_frame
		if transition_serial != _layout_transition_serial:
			return
		anchor_card = _card_for_entry_id(_transition_anchor_id)
		if anchor_card == null or not anchor_card.is_visible_in_tree():
			return
		screen_delta = anchor_card.global_position.y - _transition_anchor_screen_y
		target_scroll = grid_scroll.scroll_vertical + int(round(screen_delta))
	grid_scroll.scroll_vertical = target_scroll


func _maximum_grid_scroll() -> int:
	var vertical_scrollbar := grid_scroll.get_v_scroll_bar()
	return maxi(
		0,
		int(ceil(vertical_scrollbar.max_value - vertical_scrollbar.page))
	)


func _set_grid_anchor_extra_bottom(extra_bottom: int) -> void:
	_grid_anchor_extra_bottom = maxi(extra_bottom, 0)
	grid_margin.add_theme_constant_override(
		&"margin_bottom",
		GRID_BASE_BOTTOM_MARGIN + _grid_anchor_extra_bottom
	)


func _finalize_closed_grid_padding(transition_serial: int) -> void:
	await get_tree().process_frame
	if transition_serial != _layout_transition_serial or _detail_open:
		return
	_set_grid_anchor_extra_bottom(0)
	await get_tree().process_frame
	if transition_serial == _layout_transition_serial and not _detail_open:
		_restore_transition_anchor(transition_serial)


func _card_for_entry_id(entry_id: StringName) -> EncyclopediaEntryCard:
	for card in _cards:
		if card.entry_data != null and card.entry_data.entry_id == entry_id:
			return card
	return null


func _columns_for_width(pane_width: float) -> int:
	var available_width := pane_width - GRID_WIDTH_RESERVE
	if available_width <= CARD_WIDTH:
		return 1
	return maxi(
		1,
		int(floor((available_width + CARD_GAP) / (CARD_WIDTH + CARD_GAP)))
	)


func _update_grid_columns() -> void:
	var next_columns := _columns_for_width(grid_pane.size.x)
	_grid_columns = next_columns
	entry_grid.columns = next_columns
	_update_grid_spacing()
	call_deferred("_rebuild_card_focus_neighbours")


func _update_grid_spacing() -> void:
	if entry_grid.columns <= 1:
		entry_grid.add_theme_constant_override(&"h_separation", int(CARD_GAP))
		return
	var available_width := maxf(grid_pane.size.x - GRID_WIDTH_RESERVE, CARD_WIDTH)
	var used_by_cards := float(entry_grid.columns) * CARD_WIDTH
	var even_gap := (available_width - used_by_cards) / float(entry_grid.columns - 1)
	entry_grid.add_theme_constant_override(
		&"h_separation",
		maxi(int(floor(even_gap)), int(CARD_GAP))
	)


func _rebuild_card_focus_neighbours() -> void:
	if _cards.is_empty():
		return
	var nav_button := _button_for_section(_current_section)
	var detail_close := detail_panel.get_close_button() if _detail_open else null
	for index in _cards.size():
		var column := index % _grid_columns
		var left: Control = (
			_cards[index - 1].get_focus_control()
			if column > 0
			else nav_button
		)
		var has_right_card := (
			column < _grid_columns - 1 and index + 1 < _cards.size()
		)
		var right: Control = (
			_cards[index + 1].get_focus_control()
			if has_right_card
			else detail_close
		)
		var up_index := index - _grid_columns
		var up: Control = (
			_cards[up_index].get_focus_control()
			if up_index >= 0
			else _top_bar_control_for_column(column)
		)
		var down_index := index + _grid_columns
		var down: Control = (
			_cards[down_index].get_focus_control()
			if down_index < _cards.size()
			else null
		)
		_cards[index].set_focus_neighbours(left, right, up, down)
	_prepare_focus_navigation()


func _prepare_focus_navigation() -> void:
	var selected_nav := _button_for_section(_current_section)
	for button in _section_buttons:
		button.focus_neighbor_right = button.get_path_to(search_edit)
	back_button.focus_neighbor_right = back_button.get_path_to(search_edit)
	search_edit.focus_neighbor_left = search_edit.get_path_to(selected_nav)
	search_edit.focus_neighbor_right = search_edit.get_path_to(filter_button)
	filter_button.focus_neighbor_left = filter_button.get_path_to(search_edit)
	if not _cards.is_empty():
		search_edit.focus_neighbor_bottom = search_edit.get_path_to(
			_cards[0].get_focus_control()
		)
		var top_right_index := mini(_grid_columns - 1, _cards.size() - 1)
		filter_button.focus_neighbor_bottom = filter_button.get_path_to(
			_cards[top_right_index].get_focus_control()
		)
	else:
		search_edit.focus_neighbor_bottom = NodePath("")
		filter_button.focus_neighbor_bottom = NodePath("")


func _configure_detail_focus_neighbours() -> void:
	var source := _selected_card_focus_control()
	var close := detail_panel.get_close_button()
	var scroll := detail_panel.get_scroll_control()
	if source != null:
		close.focus_neighbor_left = close.get_path_to(source)
		scroll.focus_neighbor_left = scroll.get_path_to(source)
	close.focus_neighbor_bottom = close.get_path_to(scroll)
	scroll.focus_neighbor_top = scroll.get_path_to(close)


func _top_bar_control_for_column(column: int) -> Control:
	if column >= maxi(_grid_columns - 2, 1):
		return filter_button
	return search_edit


func _selected_card_focus_control() -> Control:
	var state: Dictionary = _section_states[_current_section]
	var selected_id := StringName(state["selected_id"])
	for card in _cards:
		if card.entry_data != null and card.entry_data.entry_id == selected_id:
			return card.get_focus_control()
	return _cards[0].get_focus_control() if not _cards.is_empty() else null


func _restore_selected_card_focus() -> void:
	var control := _selected_card_focus_control()
	if control != null and control.is_visible_in_tree():
		control.grab_focus()


func _set_navigation_visuals(section: int) -> void:
	for index in _section_buttons.size():
		var button := _section_buttons[index]
		var button_section := CodexSection.ALL[index]
		var is_selected := button_section == section
		button.add_theme_color_override(
			&"font_color",
			Color(0.97, 0.84, 0.5) if is_selected else Color(0.72, 0.73, 0.69)
		)
		button.add_theme_stylebox_override(
			&"normal",
			_make_navigation_style(is_selected)
		)


func _make_navigation_style(selected: bool) -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.content_margin_left = 12.0
	style.bg_color = (
		Color(0.22, 0.2, 0.13, 0.72)
		if selected
		else Color(0.045, 0.052, 0.052, 0.18)
	)
	style.corner_radius_top_left = 3
	style.corner_radius_top_right = 3
	style.corner_radius_bottom_left = 3
	style.corner_radius_bottom_right = 3
	return style


func _move_selection_indicator(button: Button, animate: bool) -> void:
	if button == null:
		return
	if _indicator_tween != null:
		_indicator_tween.kill()
	var target_y: float = button.global_position.y - section_nav.global_position.y
	selection_indicator.size.y = button.size.y
	if not animate:
		selection_indicator.position.y = target_y
		return
	_indicator_tween = create_tween()
	_indicator_tween.tween_property(
		selection_indicator,
		"position:y",
		target_y,
		SECTION_TRANSITION_DURATION
	).set_trans(Tween.TRANS_QUART).set_ease(Tween.EASE_OUT)
	_indicator_tween.finished.connect(func() -> void: _indicator_tween = null)


func _sync_selection_indicator(animate: bool) -> void:
	_move_selection_indicator(_button_for_section(_current_section), animate)


func _button_for_section(section: int) -> Button:
	match section:
		CodexSection.COLLECTIBLE:
			return collectible_button
		CodexSection.BUILDING:
			return building_button
		_:
			return enemy_button


func _prepare_page_entrance() -> void:
	page.modulate = Color(1.0, 1.0, 1.0, 0.0)
	page.position += Vector2(0.0, 8.0)


func _play_page_entrance() -> void:
	if _page_tween != null:
		_page_tween.kill()
	var target_position := page.position - Vector2(0.0, 8.0)
	_page_tween = create_tween().set_parallel(true)
	_page_tween.tween_property(
		page,
		"position",
		target_position,
		PAGE_ENTRANCE_DURATION
	).set_trans(Tween.TRANS_QUART).set_ease(Tween.EASE_OUT)
	_page_tween.tween_property(
		page,
		"modulate",
		Color.WHITE,
		PAGE_ENTRANCE_DURATION
	).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_OUT)
	_page_tween.finished.connect(_on_page_entrance_finished)


func _on_page_entrance_finished() -> void:
	_page_tween = null
	if get_viewport().gui_get_focus_owner() == null:
		enemy_button.grab_focus()


func _section_kicker_text(section: int) -> String:
	match section:
		CodexSection.COLLECTIBLE:
			return "RELIC ARCHIVE  ·  收藏记录"
		CodexSection.BUILDING:
			return "STRUCTURE ARCHIVE  ·  建造资料"
		_:
			return "THREAT ARCHIVE  ·  目标情报"


func _section_description_text(section: int) -> String:
	match section:
		CodexSection.COLLECTIBLE:
			return "查阅收藏品效果、稀有度与叠加规则。"
		CodexSection.BUILDING:
			return "查阅建筑属性、放置条件与主要制造方式。"
		_:
			return "查阅已归档敌人的数值、特性与行动方式。"
