extends CanvasLayer
class_name RogueRouteNodeBriefing

signal confirmed
signal canceled

const BRIEFING_MODEL_SCRIPT := preload(
	"res://scene/game_modes/rogue/route/rogue_route_node_briefing_model.gd"
)
const PANEL_OPEN_SECONDS := 0.20
const HERO_REVEAL_SECONDS := 0.25
const INFO_FADE_SECONDS := 0.16
const INFO_STAGGER_SECONDS := 0.035
const MAP_SHADE_COLOR := Color(0.012, 0.018, 0.02, 0.78)
const PANEL_OPEN_OFFSET := Vector2(0.0, 18.0)
const DANGER_PANEL_OPEN_SECONDS := 0.18
const DANGER_HERO_REVEAL_SECONDS := 0.22
const DANGER_INFO_FADE_SECONDS := 0.15
const DANGER_INFO_STAGGER_SECONDS := 0.03
const DANGER_MAP_SHADE_COLOR := Color(0.012, 0.018, 0.02, 0.82)
const DANGER_PANEL_OPEN_OFFSET := Vector2(-8.0, 0.0)
const DANGER_FRAME_MODULATE := Color(0.92, 0.9, 0.86, 1.0)
const DANGER_TAG_TEXT := "▲  威胁等级：高"
const HOST_STATUS_TEXT := "确认前不会扣除行动力"
const CLIENT_STATUS_TEXT := "等待房主决定"
const REQUIRED_COMBAT_STATUS_TEXT := "该特殊作战不可取消"
const CONFIRMING_STATUS_TEXT := "正在进入作战…"
const CANCELING_STATUS_TEXT := "正在返回路线…"

@export_group("危险简报样式")
@export var danger_hero_style: StyleBox
@export var danger_info_style: StyleBox
@export var danger_enemy_style: StyleBox
@export var danger_primary_style: StyleBox
@export var danger_primary_hover_style: StyleBox
@export var danger_primary_pressed_style: StyleBox

@onready var map_shade: ColorRect = %MapShade
@onready var panel_stage: Control = %PanelStage
@onready var frame: NinePatchRect = $Root/PanelStage/Frame
@onready var hero_visual: TextureRect = %HeroVisual
@onready var hero_reveal_mask: ColorRect = %HeroRevealMask
@onready var node_icon: TextureRect = %NodeIcon
@onready var title_label: Label = %TitleLabel
@onready var summary_label: Label = %SummaryLabel
@onready var briefing_tag: Label = (
	$Root/PanelStage/Frame/ContentMargin/Content/Header/BriefingTag
)
@onready var header_line: ColorRect = (
	$Root/PanelStage/Frame/ContentMargin/Content/HeaderLine
)
@onready var hero_frame: PanelContainer = (
	$Root/PanelStage/Frame/ContentMargin/Content/HeroFrame
)
@onready var hero_tint: ColorRect = (
	$Root/PanelStage/Frame/ContentMargin/Content/HeroFrame/HeroTint
)
@onready var objective_card: PanelContainer = %ObjectiveCard
@onready var time_card: PanelContainer = %TimeCard
@onready var enemy_card: PanelContainer = %EnemyCard
@onready var reward_card: PanelContainer = %RewardCard
@onready var action_point_card: PanelContainer = %ActionPointCard
@onready var objective_label: Label = %ObjectiveLabel
@onready var time_limit_label: Label = %TimeLimitLabel
@onready var enemy_count_label: Label = %EnemyCountLabel
@onready var reward_label: Label = %RewardLabel
@onready var action_point_label: Label = %ActionPointLabel
@onready var action_point_icon: TextureRect = (
	$Root/PanelStage/Frame/ContentMargin/Content/InfoStack/InfoBottom/ActionPointCard/Margin/Row/Icon
)
@onready var decision_status_label: Label = %DecisionStatusLabel
@onready var close_button: Button = %CloseButton
@onready var cancel_button: Button = %CancelButton
@onready var confirm_button: Button = %ConfirmButton

var _open_tween: Tween
var _panel_rest_position := Vector2.ZERO
var _can_decide := false
var _can_cancel := true
var _decision_locked := false
var _info_cards: Array[Control] = []
var _info_captions: Array[Label] = []
var _value_labels: Array[Label] = []
var _presentation_variant := BRIEFING_MODEL_SCRIPT.PRESENTATION_VARIANT_DEFAULT
var _default_panel_styles: Dictionary = {}
var _default_button_styles: Dictionary = {}
var _default_label_colors: Dictionary = {}
var _default_map_shade_color := Color.WHITE
var _default_header_line_color := Color.WHITE
var _default_hero_tint_color := Color.WHITE
var _default_hero_reveal_color := Color.WHITE
var _default_frame_modulate := Color.WHITE
var _default_node_icon_modulate := Color.WHITE
var _default_action_point_icon_modulate := Color.WHITE
var _default_decision_status_modulate := Color.WHITE
var _default_briefing_tag_text := ""


func _ready() -> void:
	map_shade.gui_input.connect(_on_map_shade_gui_input)
	close_button.pressed.connect(_cancel)
	cancel_button.pressed.connect(_cancel)
	confirm_button.pressed.connect(_confirm)
	_panel_rest_position = panel_stage.position
	_info_cards.assign([
		%ObjectiveCard,
		%TimeCard,
		%EnemyCard,
		%RewardCard,
		%ActionPointCard,
	])
	_info_captions.assign([
		$Root/PanelStage/Frame/ContentMargin/Content/InfoStack/InfoTop/ObjectiveCard/Margin/Block/Caption,
		$Root/PanelStage/Frame/ContentMargin/Content/InfoStack/InfoTop/TimeCard/Margin/Block/Caption,
		$Root/PanelStage/Frame/ContentMargin/Content/InfoStack/InfoTop/EnemyCard/Margin/Block/Caption,
		$Root/PanelStage/Frame/ContentMargin/Content/InfoStack/InfoBottom/RewardCard/Margin/Block/Caption,
		$Root/PanelStage/Frame/ContentMargin/Content/InfoStack/InfoBottom/ActionPointCard/Margin/Row/Block/Caption,
	])
	_value_labels.assign([
		objective_label,
		time_limit_label,
		enemy_count_label,
		reward_label,
		action_point_label,
	])
	_capture_default_presentation()
	dismiss()


func present(model: BRIEFING_MODEL_SCRIPT, can_decide: bool) -> void:
	if model == null or not model.is_valid():
		push_error("无法显示无效的作战简报模型。")
		dismiss()
		return

	_apply_model(model)
	_presentation_variant = model.presentation_variant
	_apply_presentation_variant()
	_can_decide = can_decide
	_can_cancel = model.can_cancel
	_decision_locked = false
	visible = true
	set_process_input(true)
	_configure_decision_controls()
	_play_open_animation()
	if _can_decide:
		call_deferred(&"_grab_primary_focus")


func dismiss() -> void:
	_stop_open_animation()
	visible = false
	set_process_input(false)
	_can_decide = false
	_can_cancel = true
	_decision_locked = false
	_presentation_variant = BRIEFING_MODEL_SCRIPT.PRESENTATION_VARIANT_DEFAULT
	_apply_presentation_variant()
	panel_stage.position = _panel_rest_position
	hero_reveal_mask.scale.x = 0.0
	for card in _info_cards:
		card.modulate = Color.WHITE
	_release_modal_focus()


func can_decide() -> bool:
	return _can_decide


func is_decision_locked() -> bool:
	return _decision_locked


func can_cancel() -> bool:
	return _can_cancel


func get_presentation_variant() -> StringName:
	return _presentation_variant


func _input(event: InputEvent) -> void:
	if not visible or not event.is_action_pressed(&"quit"):
		return
	get_viewport().set_input_as_handled()
	if _can_decide and _can_cancel:
		_cancel()


func _apply_model(model: BRIEFING_MODEL_SCRIPT) -> void:
	node_icon.texture = model.icon
	title_label.text = model.title
	summary_label.text = model.summary
	hero_visual.texture = model.hero_visual
	objective_label.text = model.objective
	time_limit_label.text = "%d 秒" % model.time_limit_seconds
	enemy_count_label.text = "%d" % model.enemy_count
	reward_label.text = model.reward_summary
	action_point_label.text = (
		"0" if model.action_point_delta == 0 else "%+d" % model.action_point_delta
	)
	confirm_button.text = model.primary_action_text


func _configure_decision_controls() -> void:
	close_button.visible = _can_decide and _can_cancel
	close_button.disabled = not _can_decide or not _can_cancel
	cancel_button.visible = _can_cancel
	cancel_button.disabled = not _can_decide or not _can_cancel
	confirm_button.disabled = not _can_decide
	cancel_button.focus_mode = (
		Control.FOCUS_ALL
		if _can_decide and _can_cancel
		else Control.FOCUS_NONE
	)
	confirm_button.focus_mode = (
		Control.FOCUS_ALL if _can_decide else Control.FOCUS_NONE
	)
	decision_status_label.text = CLIENT_STATUS_TEXT
	if _can_decide:
		decision_status_label.text = (
			HOST_STATUS_TEXT if _can_cancel else REQUIRED_COMBAT_STATUS_TEXT
		)
	if _can_decide:
		decision_status_label.modulate = Color(0.39, 0.25, 0.14, 0.76)
	else:
		decision_status_label.modulate = Color(0.54, 0.19, 0.12, 1.0)
	if not _can_decide:
		_release_modal_focus()


func _play_open_animation() -> void:
	_stop_open_animation()
	var danger := _is_danger_presentation()
	var shade_color := DANGER_MAP_SHADE_COLOR if danger else MAP_SHADE_COLOR
	var panel_duration := DANGER_PANEL_OPEN_SECONDS if danger else PANEL_OPEN_SECONDS
	var hero_duration := (
		DANGER_HERO_REVEAL_SECONDS if danger else HERO_REVEAL_SECONDS
	)
	var info_duration := DANGER_INFO_FADE_SECONDS if danger else INFO_FADE_SECONDS
	var info_stagger := (
		DANGER_INFO_STAGGER_SECONDS if danger else INFO_STAGGER_SECONDS
	)
	var open_offset := DANGER_PANEL_OPEN_OFFSET if danger else PANEL_OPEN_OFFSET
	map_shade.color = Color(shade_color, 0.0)
	panel_stage.position = _panel_rest_position + open_offset
	panel_stage.modulate = Color(1.0, 1.0, 1.0, 0.0)
	hero_reveal_mask.pivot_offset = Vector2(
		hero_reveal_mask.size.x,
		0.0
	)
	hero_reveal_mask.scale.x = 1.0
	for card in _info_cards:
		card.modulate = Color(1.0, 1.0, 1.0, 0.0)

	_open_tween = create_tween().set_parallel(true)
	_open_tween.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	_open_tween.tween_property(
		map_shade,
		^"color",
		shade_color,
		panel_duration
	)
	_open_tween.tween_property(
		panel_stage,
		^"position",
		_panel_rest_position,
		panel_duration
	)
	_open_tween.tween_property(
		panel_stage,
		^"modulate",
		Color.WHITE,
		panel_duration
	)
	_open_tween.tween_property(
		hero_reveal_mask,
		^"scale:x",
		0.0,
		hero_duration
	)
	for index in range(_info_cards.size()):
		var base_delay := 0.04 if danger else 0.06
		_open_tween.tween_property(
			_info_cards[index],
			^"modulate",
			Color.WHITE,
			info_duration
		).set_delay(base_delay + info_stagger * index)


func _stop_open_animation() -> void:
	if _open_tween != null and _open_tween.is_valid():
		_open_tween.kill()
	_open_tween = null


func _on_map_shade_gui_input(event: InputEvent) -> void:
	var mouse_event := event as InputEventMouseButton
	if mouse_event == null:
		return
	if mouse_event.button_index != MOUSE_BUTTON_LEFT or not mouse_event.pressed:
		return
	map_shade.accept_event()
	if _can_decide and _can_cancel:
		_cancel()


func _confirm() -> void:
	if not visible or not _can_decide or _decision_locked:
		return
	_lock_decision(CONFIRMING_STATUS_TEXT)
	confirmed.emit()


func _cancel() -> void:
	if not visible or not _can_decide or not _can_cancel or _decision_locked:
		return
	_lock_decision(CANCELING_STATUS_TEXT)
	canceled.emit()


func _lock_decision(status_text: String) -> void:
	_decision_locked = true
	close_button.disabled = true
	cancel_button.disabled = true
	confirm_button.disabled = true
	decision_status_label.text = status_text
	decision_status_label.modulate = Color(0.54, 0.19, 0.12, 1.0)
	_release_modal_focus()


func _is_danger_presentation() -> bool:
	return (
		_presentation_variant
		== BRIEFING_MODEL_SCRIPT.PRESENTATION_VARIANT_DANGER
	)


func _capture_default_presentation() -> void:
	_default_panel_styles = {
		hero_frame: hero_frame.get_theme_stylebox(&"panel"),
		objective_card: objective_card.get_theme_stylebox(&"panel"),
		time_card: time_card.get_theme_stylebox(&"panel"),
		enemy_card: enemy_card.get_theme_stylebox(&"panel"),
		reward_card: reward_card.get_theme_stylebox(&"panel"),
		action_point_card: action_point_card.get_theme_stylebox(&"panel"),
	}
	for button in [close_button, cancel_button, confirm_button]:
		_default_button_styles[button] = {
			&"normal": button.get_theme_stylebox(&"normal"),
			&"hover": button.get_theme_stylebox(&"hover"),
			&"pressed": button.get_theme_stylebox(&"pressed"),
			&"disabled": button.get_theme_stylebox(&"disabled"),
			&"focus": button.get_theme_stylebox(&"focus"),
			&"font_color": button.get_theme_color(&"font_color"),
			&"font_hover_color": button.get_theme_color(&"font_hover_color"),
			&"font_pressed_color": button.get_theme_color(&"font_pressed_color"),
			&"font_disabled_color": button.get_theme_color(&"font_disabled_color"),
		}
	for label in (
		[title_label, summary_label, briefing_tag, decision_status_label]
		+ _info_captions
		+ _value_labels
	):
		_default_label_colors[label] = label.get_theme_color(&"font_color")
	_default_map_shade_color = map_shade.color
	_default_header_line_color = header_line.color
	_default_hero_tint_color = hero_tint.color
	_default_hero_reveal_color = hero_reveal_mask.color
	_default_frame_modulate = frame.self_modulate
	_default_node_icon_modulate = node_icon.modulate
	_default_action_point_icon_modulate = action_point_icon.modulate
	_default_decision_status_modulate = decision_status_label.modulate
	_default_briefing_tag_text = briefing_tag.text


func _apply_presentation_variant() -> void:
	if _is_danger_presentation():
		_apply_danger_presentation()
		return
	_restore_default_presentation()


func _apply_danger_presentation() -> void:
	frame.self_modulate = DANGER_FRAME_MODULATE
	map_shade.color = DANGER_MAP_SHADE_COLOR
	header_line.color = Color(0.66, 0.16, 0.045, 0.68)
	hero_tint.color = Color(0.3, 0.055, 0.015, 0.13)
	hero_reveal_mask.color = Color(0.075, 0.09, 0.09, 1.0)
	briefing_tag.text = DANGER_TAG_TEXT
	title_label.add_theme_color_override(&"font_color", Color(0.32, 0.09, 0.03, 1.0))
	summary_label.add_theme_color_override(&"font_color", Color(0.5, 0.2, 0.07, 0.9))
	briefing_tag.add_theme_color_override(&"font_color", Color(0.62, 0.18, 0.055, 0.96))
	enemy_count_label.add_theme_color_override(&"font_color", Color(0.56, 0.13, 0.045, 1.0))
	hero_frame.add_theme_stylebox_override(&"panel", danger_hero_style)
	for info_card in [objective_card, time_card, reward_card]:
		info_card.add_theme_stylebox_override(&"panel", danger_info_style)
	enemy_card.add_theme_stylebox_override(&"panel", danger_enemy_style)
	_apply_button_style_set(
		confirm_button,
		danger_primary_style,
		danger_primary_hover_style,
		danger_primary_pressed_style
	)
	confirm_button.add_theme_color_override(&"font_color", Color(1.0, 0.92, 0.76, 1.0))
	confirm_button.add_theme_color_override(&"font_hover_color", Color(1.0, 0.97, 0.86, 1.0))
	confirm_button.add_theme_color_override(&"font_pressed_color", Color(1.0, 0.88, 0.68, 1.0))


func _apply_button_style_set(
	button: Button,
	normal_style: StyleBox,
	hover_style: StyleBox,
	pressed_style: StyleBox
) -> void:
	button.add_theme_stylebox_override(&"normal", normal_style)
	button.add_theme_stylebox_override(&"hover", hover_style)
	button.add_theme_stylebox_override(&"pressed", pressed_style)


func _restore_default_presentation() -> void:
	for control_variant in _default_panel_styles:
		var control := control_variant as Control
		var style := _default_panel_styles[control_variant] as StyleBox
		control.add_theme_stylebox_override(&"panel", style)
	for button_variant in _default_button_styles:
		var button := button_variant as Button
		var styles := _default_button_styles[button_variant] as Dictionary
		for style_name in [&"normal", &"hover", &"pressed", &"disabled", &"focus"]:
			button.add_theme_stylebox_override(
				style_name,
				styles[style_name] as StyleBox
			)
		for color_name in [
			&"font_color",
			&"font_hover_color",
			&"font_pressed_color",
			&"font_disabled_color",
		]:
			button.add_theme_color_override(color_name, styles[color_name] as Color)
	for label_variant in _default_label_colors:
		var label := label_variant as Label
		label.add_theme_color_override(
			&"font_color",
			_default_label_colors[label_variant] as Color
		)
	map_shade.color = _default_map_shade_color
	header_line.color = _default_header_line_color
	hero_tint.color = _default_hero_tint_color
	hero_reveal_mask.color = _default_hero_reveal_color
	frame.self_modulate = _default_frame_modulate
	node_icon.modulate = _default_node_icon_modulate
	action_point_icon.modulate = _default_action_point_icon_modulate
	decision_status_label.modulate = _default_decision_status_modulate
	briefing_tag.text = _default_briefing_tag_text


func _release_modal_focus() -> void:
	if get_viewport() == null:
		return
	var focus_owner := get_viewport().gui_get_focus_owner()
	if focus_owner in [close_button, cancel_button, confirm_button]:
		get_viewport().gui_release_focus()


func _grab_primary_focus() -> void:
	if visible and _can_decide and not _decision_locked:
		confirm_button.grab_focus()
