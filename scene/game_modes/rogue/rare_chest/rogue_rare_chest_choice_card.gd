extends PanelContainer
class_name RogueRareChestChoiceCard

signal selected(option_id: StringName)

const DISABLED_MODULATE := Color(0.82, 0.8, 0.74, 1.0)
const LOSER_MODULATE := Color(0.62, 0.61, 0.57, 1.0)

@export var background_texture: Texture2D

@onready var background: TextureRect = $Background
@onready var button: Button = $Button
@onready var selection_border: Panel = $SelectionBorder
@onready var number_label: Label = $Content/Margin/Rows/Header/Number
@onready var effect_label: Label = $Content/Margin/Rows/Header/Effect
@onready var detail_label: Label = $Content/Margin/Rows/Detail
@onready var state_label: Label = $Content/Margin/Rows/State

var option_id: StringName = &""
var display_index := 0
var entrance_tween: Tween = null
var resolution_tween: Tween = null
var interaction_enabled := false
var resolution_active := false
var resolved_selected := false


func _ready() -> void:
	button.pressed.connect(_on_button_pressed)
	resized.connect(_sync_pivot_offset)
	background.texture = background_texture
	selection_border.visible = false
	_sync_pivot_offset()


func configure(
	option: Dictionary,
	new_display_index: int,
	local_can_select: bool,
	disabled_reason: String = ""
) -> void:
	option_id = StringName(option.get("option_id", ""))
	display_index = maxi(new_display_index, 0)
	number_label.text = "%02d" % (display_index + 1)
	effect_label.text = str(option.get("effect_text", "未知增益"))
	detail_label.text = str(option.get("detail_text", ""))
	detail_label.visible = not detail_label.text.is_empty()
	state_label.text = disabled_reason
	state_label.visible = not disabled_reason.is_empty()
	button.disabled = (
		not local_can_select
		or not disabled_reason.is_empty()
		or option_id.is_empty()
	)
	interaction_enabled = local_can_select
	_refresh_interaction()
	_refresh_visual_state()


func set_interaction_enabled(enabled: bool) -> void:
	interaction_enabled = enabled
	_refresh_interaction()


func set_resolution_state(
	is_selected: bool,
	is_resolution_active: bool
) -> void:
	if resolution_tween != null:
		resolution_tween.kill()
		resolution_tween = null
	var became_selected := (
		is_resolution_active
		and is_selected
		and not (resolution_active and resolved_selected)
	)
	resolution_active = is_resolution_active
	resolved_selected = is_resolution_active and is_selected
	selection_border.visible = resolved_selected
	_refresh_visual_state()
	if not became_selected:
		return
	resolution_tween = create_tween()
	resolution_tween.tween_property(
		self,
		"scale",
		Vector2(1.025, 1.025),
		0.14
	).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	resolution_tween.tween_property(
		self,
		"scale",
		Vector2.ONE,
		0.22
	).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)


func play_entrance(delay_seconds: float) -> void:
	await get_tree().process_frame
	if not is_inside_tree() or not is_visible_in_tree():
		return
	if entrance_tween != null:
		entrance_tween.kill()
	modulate = Color(1, 1, 1, 0)
	var target_position := position
	position = target_position + Vector2(44, 0)
	entrance_tween = create_tween().set_parallel(true)
	entrance_tween.tween_property(
		self,
		"position",
		target_position,
		0.34
	).set_delay(delay_seconds).set_trans(Tween.TRANS_BACK).set_ease(
		Tween.EASE_OUT
	)
	entrance_tween.tween_property(
		self,
		"modulate",
		Color.WHITE,
		0.22
	).set_delay(delay_seconds)
	entrance_tween.finished.connect(func() -> void: entrance_tween = null)


func _refresh_interaction() -> void:
	var accepts_input := interaction_enabled and not button.disabled
	button.mouse_filter = (
		Control.MOUSE_FILTER_STOP
		if accepts_input
		else Control.MOUSE_FILTER_IGNORE
	)
	button.focus_mode = (
		Control.FOCUS_ALL if accepts_input else Control.FOCUS_NONE
	)
	if not accepts_input and button.has_focus():
		button.release_focus()


func _refresh_visual_state() -> void:
	scale = Vector2.ONE
	if resolution_active:
		self_modulate = Color.WHITE if resolved_selected else LOSER_MODULATE
		return
	self_modulate = DISABLED_MODULATE if button.disabled else Color.WHITE


func _on_button_pressed() -> void:
	if not option_id.is_empty() and not button.disabled:
		selected.emit(option_id)


func _sync_pivot_offset() -> void:
	pivot_offset = size * 0.5
