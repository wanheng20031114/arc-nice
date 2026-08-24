extends CanvasLayer
class_name RogueCombatResultOverlay

signal dismissed

const VICTORY_TITLE := "通过作战"
const FAILURE_TITLE := "作战失败"
const COMMON_RARITY_TEXT := "普通品质"
const VICTORY_TITLE_COLOR := Color(0.58, 0.94, 0.62, 1.0)
const FAILURE_TITLE_COLOR := Color(1.0, 0.43, 0.36, 1.0)
const VICTORY_RULE_COLOR := Color(0.46, 0.86, 0.51, 0.58)
const FAILURE_RULE_COLOR := Color(0.92, 0.3, 0.25, 0.58)
const LOOT_RECEIVED_COLOR := Color(0.58, 0.9, 0.61, 1.0)
const LOOT_LOST_COLOR := Color(1.0, 0.46, 0.38, 1.0)
const LOOT_EMPTY_COLOR := Color(0.68, 0.69, 0.67, 1.0)
const OPEN_DURATION_SECONDS := 0.22

@onready var root_control: Control = %Root
@onready var result_panel: PanelContainer = %ResultPanel
@onready var panel_margin: MarginContainer = %PanelMargin
@onready var result_content: VBoxContainer = %ResultContent
@onready var left_state_rule: ColorRect = %LeftStateRule
@onready var result_title_label: Label = %ResultTitle
@onready var right_state_rule: ColorRect = %RightStateRule
@onready var result_subtitle_label: Label = %ResultSubtitle
@onready var extra_xirang_value_label: Label = %ExtraXirangValue
@onready var loot_card: PanelContainer = %LootCard
@onready var loot_card_margin: MarginContainer = %LootCardMargin
@onready var loot_icon_frame: PanelContainer = %LootIconFrame
@onready var loot_icon_rect: TextureRect = %LootIcon
@onready var rarity_badge: PanelContainer = %RarityBadge
@onready var rarity_label: Label = %RarityLabel
@onready var loot_name_label: Label = %LootName
@onready var loot_status_label: Label = %LootStatus
@onready var loot_card_2: PanelContainer = %LootCard2
@onready var loot_card_margin_2: MarginContainer = %LootCardMargin2
@onready var loot_icon_frame_2: PanelContainer = %LootIconFrame2
@onready var loot_icon_rect_2: TextureRect = %LootIcon2
@onready var rarity_badge_2: PanelContainer = %RarityBadge2
@onready var rarity_label_2: Label = %RarityLabel2
@onready var loot_name_label_2: Label = %LootName2
@onready var loot_status_label_2: Label = %LootStatus2
@onready var loot_card_3: PanelContainer = %LootCard3
@onready var loot_card_margin_3: MarginContainer = %LootCardMargin3
@onready var loot_icon_frame_3: PanelContainer = %LootIconFrame3
@onready var loot_icon_rect_3: TextureRect = %LootIcon3
@onready var rarity_badge_3: PanelContainer = %RarityBadge3
@onready var rarity_label_3: Label = %RarityLabel3
@onready var loot_name_label_3: Label = %LootName3
@onready var loot_status_label_3: Label = %LootStatus3
@onready var close_button: Button = %CloseButton

var _open_tween: Tween = null


func _ready() -> void:
	close_button.pressed.connect(_on_close_button_pressed)
	var viewport := get_viewport()
	if viewport != null and not viewport.size_changed.is_connected(
		_update_responsive_layout
	):
		viewport.size_changed.connect(_update_responsive_layout)
	set_process_unhandled_input(false)
	_update_responsive_layout()


func show_victory(
	extra_xirang: int,
	loot_name: String,
	loot_icon: Texture2D,
	inventory_full: bool = false
) -> void:
	present_result(
		true,
		extra_xirang,
		loot_name,
		loot_icon,
		inventory_full
	)


func show_failure(reason: String = "队伍已全数阵亡") -> void:
	present_result(false, 0, "", null, false, reason)


func present_reward_result(result: Dictionary) -> void:
	var victory := bool(result.get("victory", false))
	if not victory:
		present_result(
			false,
			0,
			"",
			null,
			false,
			str(result.get("failure_reason", ""))
		)
		return
	var raw_rewards := result.get("item_rewards", []) as Array
	if raw_rewards.is_empty():
		return
	var first_reward := raw_rewards[0] as Dictionary
	var first_item := _load_reward_item(first_reward)
	present_result(
		true,
		int(result.get("extra_xirang", 0)),
		str(first_reward.get("name", "")),
		first_item.icon_texture if first_item != null else null,
		int(first_reward.get("granted_count", 0))
		< int(first_reward.get("rolled_count", 1))
	)
	var shared_light_stone_reward := maxi(
		int(result.get("shared_light_stone_reward", 0)),
		0
	)
	if shared_light_stone_reward > 0:
		result_subtitle_label.text += "  全队共享光石 +%d。" % (
			shared_light_stone_reward
		)
	var cards: Array[PanelContainer] = [loot_card, loot_card_2, loot_card_3]
	var icons: Array[TextureRect] = [loot_icon_rect, loot_icon_rect_2, loot_icon_rect_3]
	var badges: Array[PanelContainer] = [rarity_badge, rarity_badge_2, rarity_badge_3]
	var rarity_labels: Array[Label] = [rarity_label, rarity_label_2, rarity_label_3]
	var name_labels: Array[Label] = [loot_name_label, loot_name_label_2, loot_name_label_3]
	var status_labels: Array[Label] = [
		loot_status_label,
		loot_status_label_2,
		loot_status_label_3,
	]
	for row_index in range(cards.size()):
		if row_index >= raw_rewards.size():
			cards[row_index].hide()
			continue
		cards[row_index].show()
		_bind_reward_row(
			raw_rewards[row_index] as Dictionary,
			icons[row_index],
			badges[row_index],
			rarity_labels[row_index],
			name_labels[row_index],
			status_labels[row_index]
		)


func present_result(
	victory: bool,
	extra_xirang: int = 0,
	loot_name: String = "",
	loot_icon: Texture2D = null,
	inventory_full: bool = false,
	failure_reason: String = ""
) -> void:
	var normalized_loot_name := loot_name.strip_edges()
	var has_loot := victory and not normalized_loot_name.is_empty()
	result_title_label.text = VICTORY_TITLE if victory else FAILURE_TITLE
	result_title_label.self_modulate = (
		VICTORY_TITLE_COLOR if victory else FAILURE_TITLE_COLOR
	)
	var state_rule_color := VICTORY_RULE_COLOR if victory else FAILURE_RULE_COLOR
	left_state_rule.color = state_rule_color
	right_state_rule.color = state_rule_color
	result_subtitle_label.text = (
		"所有敌人已被击败，作战区域已经安全。"
		if victory
		else _normalize_failure_reason(failure_reason)
	)
	extra_xirang_value_label.text = "+%d" % maxi(extra_xirang, 0)
	loot_name_label.text = normalized_loot_name if has_loot else "无"
	loot_card.show()
	loot_card_2.hide()
	loot_card_3.hide()
	loot_icon_rect.texture = loot_icon if has_loot else null
	rarity_badge.visible = has_loot
	rarity_label.text = COMMON_RARITY_TEXT
	if has_loot and inventory_full:
		loot_status_label.text = "未获得（背包已满）"
		loot_status_label.self_modulate = LOOT_LOST_COLOR
		loot_icon_rect.modulate = Color(0.72, 0.72, 0.72, 0.45)
	elif has_loot:
		loot_status_label.text = "已放入背包"
		loot_status_label.self_modulate = LOOT_RECEIVED_COLOR
		loot_icon_rect.modulate = Color.WHITE
	else:
		loot_status_label.text = "本次没有获得战利品"
		loot_status_label.self_modulate = LOOT_EMPTY_COLOR
		loot_icon_rect.modulate = Color.WHITE
	show()
	set_process_unhandled_input(true)
	_play_open_animation()
	call_deferred("_focus_close_button")


func _bind_reward_row(
	reward: Dictionary,
	icon_rect: TextureRect,
	badge: PanelContainer,
	badge_label: Label,
	name_label: Label,
	status_label: Label
) -> void:
	var item := _load_reward_item(reward)
	var rolled_count := maxi(int(reward.get("rolled_count", 1)), 1)
	var granted_count := clampi(
		int(reward.get("granted_count", 0)),
		0,
		rolled_count
	)
	var display_name := str(reward.get("name", "未知战利品")).strip_edges()
	name_label.text = (
		"%s ×%d" % [display_name, rolled_count]
		if rolled_count > 1
		else display_name
	)
	icon_rect.texture = item.icon_texture if item != null else null
	var rarity_text := str(reward.get("rarity_name", "")).strip_edges()
	badge.visible = not rarity_text.is_empty()
	badge_label.text = rarity_text
	if granted_count == rolled_count:
		status_label.text = "已放入背包"
		status_label.self_modulate = LOOT_RECEIVED_COLOR
		icon_rect.modulate = Color.WHITE
	elif granted_count > 0:
		status_label.text = "获得%d，另有%d因背包空间不足而丢失" % [
			granted_count,
			rolled_count - granted_count,
		]
		status_label.self_modulate = LOOT_LOST_COLOR
		icon_rect.modulate = Color(0.9, 0.9, 0.9, 0.72)
	else:
		status_label.text = "未获得（背包已满）"
		status_label.self_modulate = LOOT_LOST_COLOR
		icon_rect.modulate = Color(0.72, 0.72, 0.72, 0.45)


func _load_reward_item(reward: Dictionary) -> PickupConfig:
	var config_path := str(reward.get("config_path", ""))
	if config_path.is_empty() or not ResourceLoader.exists(config_path):
		return null
	return load(config_path) as PickupConfig


func hide_immediately() -> void:
	_stop_open_tween()
	set_process_unhandled_input(false)
	root_control.modulate = Color.WHITE
	result_panel.scale = Vector2.ONE
	close_button.release_focus()
	hide()


func _normalize_failure_reason(reason: String) -> String:
	var normalized_reason := reason.strip_edges()
	return "队伍已全数阵亡" if normalized_reason.is_empty() else normalized_reason


func _play_open_animation() -> void:
	_stop_open_tween()
	_refresh_panel_pivot()
	root_control.modulate = Color(1.0, 1.0, 1.0, 0.0)
	result_panel.scale = Vector2(0.96, 0.96)
	_open_tween = create_tween()
	_open_tween.set_parallel(true)
	_open_tween.tween_property(
		root_control,
		"modulate:a",
		1.0,
		OPEN_DURATION_SECONDS
	).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	_open_tween.tween_property(
		result_panel,
		"scale",
		Vector2.ONE,
		OPEN_DURATION_SECONDS
	).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	_open_tween.finished.connect(_on_open_tween_finished)


func _stop_open_tween() -> void:
	if _open_tween != null:
		_open_tween.kill()
		_open_tween = null


func _refresh_panel_pivot() -> void:
	result_panel.pivot_offset = result_panel.size * 0.5


func _focus_close_button() -> void:
	if visible and is_instance_valid(close_button):
		_refresh_panel_pivot()
		close_button.grab_focus()


func _on_open_tween_finished() -> void:
	_open_tween = null
	root_control.modulate = Color.WHITE
	result_panel.scale = Vector2.ONE


func _on_close_button_pressed() -> void:
	if not visible:
		return
	hide_immediately()
	dismissed.emit()


func _unhandled_input(event: InputEvent) -> void:
	if not visible or not event.is_action_pressed(&"quit"):
		return
	get_viewport().set_input_as_handled()
	_on_close_button_pressed()


func _update_responsive_layout() -> void:
	if not is_node_ready():
		return
	var viewport_size := get_viewport().get_visible_rect().size
	if viewport_size.x <= 0.0 or viewport_size.y <= 0.0:
		return
	var compact := viewport_size.x < 600.0 or viewport_size.y < 520.0
	result_panel.custom_minimum_size.x = minf(
		540.0,
		maxf(viewport_size.x - 32.0, 300.0)
	)
	panel_margin.add_theme_constant_override("margin_left", 18 if compact else 30)
	panel_margin.add_theme_constant_override("margin_right", 18 if compact else 30)
	panel_margin.add_theme_constant_override("margin_top", 18 if compact else 26)
	panel_margin.add_theme_constant_override("margin_bottom", 18 if compact else 26)
	result_content.add_theme_constant_override("separation", 8 if compact else 12)
	loot_card_margin.add_theme_constant_override("margin_left", 10 if compact else 14)
	loot_card_margin.add_theme_constant_override("margin_right", 10 if compact else 14)
	loot_card_margin.add_theme_constant_override("margin_top", 9 if compact else 12)
	loot_card_margin.add_theme_constant_override("margin_bottom", 9 if compact else 12)
	for margin in [loot_card_margin, loot_card_margin_2, loot_card_margin_3]:
		margin.add_theme_constant_override("margin_left", 10 if compact else 14)
		margin.add_theme_constant_override("margin_right", 10 if compact else 14)
		margin.add_theme_constant_override("margin_top", 7 if compact else 12)
		margin.add_theme_constant_override("margin_bottom", 7 if compact else 12)
	for icon_frame in [loot_icon_frame, loot_icon_frame_2, loot_icon_frame_3]:
		icon_frame.custom_minimum_size = (
			Vector2(54.0, 54.0) if compact else Vector2(72.0, 72.0)
		)
	_set_label_font_size(result_title_label, 30 if compact else 38)
	_set_label_font_size(result_subtitle_label, 13 if compact else 15)
	_set_label_font_size(loot_name_label, 18 if compact else 21)
	_set_label_font_size(loot_name_label_2, 18 if compact else 21)
	_set_label_font_size(loot_name_label_3, 18 if compact else 21)
	_refresh_panel_pivot()


func _set_label_font_size(label: Label, font_size: int) -> void:
	if label.label_settings != null:
		label.label_settings.font_size = font_size
	else:
		label.add_theme_font_size_override("font_size", font_size)
