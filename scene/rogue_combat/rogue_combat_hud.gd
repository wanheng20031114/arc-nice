extends CanvasLayer
class_name RogueCombatHUD

const DEFAULT_EVENT_TITLE := "狭路相逢"
const PREPARATION_CAPTION := "准备倒计时"
const COMBAT_CAPTION := "剩余时间"
const NORMAL_TIME_COLOR := Color(1.0, 0.86, 0.48, 1.0)
const URGENT_TIME_COLOR := Color(1.0, 0.36, 0.3, 1.0)
const CLEARED_ENEMY_COLOR := Color(0.52, 0.9, 0.58, 1.0)
const ACTIVE_ENEMY_COLOR := Color(1.0, 0.48, 0.39, 1.0)

@onready var info_panel: PanelContainer = %InfoPanel
@onready var info_margin: MarginContainer = %InfoMargin
@onready var event_block: VBoxContainer = %EventBlock
@onready var event_title_label: Label = %EventTitle
@onready var time_block: VBoxContainer = %TimeBlock
@onready var time_caption_label: Label = %TimeCaption
@onready var time_value_label: Label = %TimeValue
@onready var enemy_block: VBoxContainer = %EnemyBlock
@onready var enemy_value_label: Label = %EnemyValue
@onready var preparation_center: CenterContainer = %PreparationCenter
@onready var preparation_panel: PanelContainer = %PreparationPanel
@onready var preparation_margin: MarginContainer = %PreparationMargin
@onready var preparation_content: VBoxContainer = %PreparationContent
@onready var preparation_event_title: Label = %PreparationEventTitle
@onready var preparation_caption_label: Label = %PreparationCaption
@onready var preparation_seconds_label: Label = %PreparationSeconds
@onready var preparation_hint_label: Label = %PreparationHint


func _ready() -> void:
	var viewport := get_viewport()
	if viewport != null and not viewport.size_changed.is_connected(
		_update_responsive_layout
	):
		viewport.size_changed.connect(_update_responsive_layout)
	_update_responsive_layout()


func show_preparation(
	event_title: String = DEFAULT_EVENT_TITLE,
	seconds_left: float = 3.0,
	total_enemy_count: int = 10
) -> void:
	show()
	preparation_center.show()
	set_event_title(event_title)
	time_caption_label.text = PREPARATION_CAPTION
	set_preparation_time(seconds_left)
	set_defeated_enemy_count(0, total_enemy_count)


func set_preparation_time(seconds_left: float) -> void:
	var seconds := maxi(ceili(maxf(seconds_left, 0.0)), 0)
	var display_text := "开始！" if seconds <= 0 else str(seconds)
	preparation_seconds_label.text = display_text
	time_value_label.text = display_text
	time_value_label.self_modulate = NORMAL_TIME_COLOR


func show_combat(
	event_title: String = DEFAULT_EVENT_TITLE,
	remaining_seconds: float = 90.0,
	defeated_enemies: int = 0,
	total_enemies: int = 10
) -> void:
	show()
	preparation_center.hide()
	set_event_title(event_title)
	time_caption_label.text = COMBAT_CAPTION
	set_combat_remaining_time(remaining_seconds)
	set_defeated_enemy_count(defeated_enemies, total_enemies)


func set_combat_remaining_time(remaining_seconds: float) -> void:
	var seconds := maxi(ceili(maxf(remaining_seconds, 0.0)), 0)
	time_caption_label.text = COMBAT_CAPTION
	time_value_label.text = format_seconds(seconds)
	time_value_label.self_modulate = (
		URGENT_TIME_COLOR if seconds <= 10 else NORMAL_TIME_COLOR
	)


func set_defeated_enemy_count(defeated_enemies: int, total_enemies: int) -> void:
	var safe_total := maxi(total_enemies, 0)
	var safe_defeated := (
		clampi(defeated_enemies, 0, safe_total) if safe_total > 0 else 0
	)
	enemy_value_label.text = "%d / %d" % [safe_defeated, safe_total]
	enemy_value_label.self_modulate = (
		CLEARED_ENEMY_COLOR if safe_defeated >= safe_total else ACTIVE_ENEMY_COLOR
	)


func set_event_title(event_title: String) -> void:
	var normalized_title := event_title.strip_edges()
	if normalized_title.is_empty():
		normalized_title = DEFAULT_EVENT_TITLE
	event_title_label.text = normalized_title
	preparation_event_title.text = normalized_title


func hide_hud() -> void:
	preparation_center.hide()
	hide()


static func format_seconds(total_seconds: int) -> String:
	var safe_seconds := maxi(total_seconds, 0)
	return "%02d:%02d" % [floori(safe_seconds / 60.0), safe_seconds % 60]


func _update_responsive_layout() -> void:
	if not is_node_ready():
		return
	var viewport_size := get_viewport().get_visible_rect().size
	if viewport_size.x <= 0.0 or viewport_size.y <= 0.0:
		return
	var compact := viewport_size.x < 600.0 or viewport_size.y < 430.0
	info_panel.custom_minimum_size = Vector2(
		minf(620.0, maxf(viewport_size.x - 24.0, 340.0)),
		56.0 if compact else 64.0
	)
	preparation_panel.custom_minimum_size.x = minf(
		430.0,
		maxf(viewport_size.x - 40.0, 280.0)
	)
	info_margin.add_theme_constant_override("margin_left", 9 if compact else 14)
	info_margin.add_theme_constant_override("margin_right", 9 if compact else 14)
	info_margin.add_theme_constant_override("margin_top", 5 if compact else 7)
	info_margin.add_theme_constant_override("margin_bottom", 5 if compact else 7)
	preparation_margin.add_theme_constant_override(
		"margin_left", 22 if compact else 34
	)
	preparation_margin.add_theme_constant_override(
		"margin_right", 22 if compact else 34
	)
	preparation_margin.add_theme_constant_override(
		"margin_top", 18 if compact else 26
	)
	preparation_margin.add_theme_constant_override(
		"margin_bottom", 18 if compact else 26
	)
	preparation_content.add_theme_constant_override(
		"separation", 6 if compact else 9
	)
	event_block.custom_minimum_size.x = 120.0 if compact else 168.0
	time_block.custom_minimum_size.x = 76.0 if compact else 112.0
	enemy_block.custom_minimum_size.x = 88.0 if compact else 112.0
	_set_label_font_size(event_title_label, 15 if compact else 18)
	_set_label_font_size(time_value_label, 18 if compact else 22)
	_set_label_font_size(enemy_value_label, 18 if compact else 22)
	_set_label_font_size(preparation_event_title, 30 if compact else 38)
	_set_label_font_size(preparation_caption_label, 13 if compact else 15)
	_set_label_font_size(preparation_seconds_label, 48 if compact else 62)
	_set_label_font_size(preparation_hint_label, 12 if compact else 14)


func _set_label_font_size(label: Label, font_size: int) -> void:
	if label.label_settings != null:
		label.label_settings.font_size = font_size
	else:
		label.add_theme_font_size_override("font_size", font_size)
