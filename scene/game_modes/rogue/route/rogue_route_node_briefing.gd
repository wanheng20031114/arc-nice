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
const HOST_STATUS_TEXT := "确认前不会扣除行动力"
const CLIENT_STATUS_TEXT := "等待房主决定"
const REQUIRED_COMBAT_STATUS_TEXT := "该特殊作战不可取消"
const CONFIRMING_STATUS_TEXT := "正在进入作战…"
const CANCELING_STATUS_TEXT := "正在返回路线…"

@onready var map_shade: ColorRect = %MapShade
@onready var panel_stage: Control = %PanelStage
@onready var hero_visual: TextureRect = %HeroVisual
@onready var hero_reveal_mask: ColorRect = %HeroRevealMask
@onready var node_icon: TextureRect = %NodeIcon
@onready var title_label: Label = %TitleLabel
@onready var summary_label: Label = %SummaryLabel
@onready var objective_label: Label = %ObjectiveLabel
@onready var time_limit_label: Label = %TimeLimitLabel
@onready var enemy_count_label: Label = %EnemyCountLabel
@onready var reward_label: Label = %RewardLabel
@onready var action_point_label: Label = %ActionPointLabel
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
	dismiss()


func present(model: BRIEFING_MODEL_SCRIPT, can_decide: bool) -> void:
	if model == null or not model.is_valid():
		push_error("无法显示无效的作战简报模型。")
		dismiss()
		return

	_apply_model(model)
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


func _input(event: InputEvent) -> void:
	if not visible or not event.is_action_pressed(&"ui_cancel"):
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
	decision_status_label.modulate = (
		Color(0.39, 0.25, 0.14, 0.76)
		if _can_decide
		else Color(0.54, 0.19, 0.12, 1.0)
	)
	if not _can_decide:
		_release_modal_focus()


func _play_open_animation() -> void:
	_stop_open_animation()
	map_shade.color = Color(MAP_SHADE_COLOR, 0.0)
	panel_stage.position = _panel_rest_position + PANEL_OPEN_OFFSET
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
		MAP_SHADE_COLOR,
		PANEL_OPEN_SECONDS
	)
	_open_tween.tween_property(
		panel_stage,
		^"position",
		_panel_rest_position,
		PANEL_OPEN_SECONDS
	)
	_open_tween.tween_property(
		panel_stage,
		^"modulate",
		Color.WHITE,
		PANEL_OPEN_SECONDS
	)
	_open_tween.tween_property(
		hero_reveal_mask,
		^"scale:x",
		0.0,
		HERO_REVEAL_SECONDS
	)
	for index in range(_info_cards.size()):
		_open_tween.tween_property(
			_info_cards[index],
			^"modulate",
			Color.WHITE,
			INFO_FADE_SECONDS
		).set_delay(0.06 + INFO_STAGGER_SECONDS * index)


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


func _release_modal_focus() -> void:
	if get_viewport() == null:
		return
	var focus_owner := get_viewport().gui_get_focus_owner()
	if focus_owner in [close_button, cancel_button, confirm_button]:
		get_viewport().gui_release_focus()


func _grab_primary_focus() -> void:
	if visible and _can_decide and not _decision_locked:
		confirm_button.grab_focus()
