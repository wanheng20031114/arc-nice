extends Control
class_name RogueRouteCell

signal node_pressed(node_id: int)

const INVALID_NODE_ID := -1
const ENTRY_REVEAL_START_SCALE := 0.78
const ENTRY_REVEAL_OVERSHOOT_SCALE := 1.04
const ENTRY_REVEAL_OVERSHOOT_POINT := 0.78
const NODE_CENTER := Vector2(32.0, 32.0)
const VISITED_NODE_MODULATE := Color(0.48, 0.52, 0.54, 0.74)

@onready var current_glow: ColorRect = $CurrentGlow
@onready var node_button: Button = $NodeButton
@onready var node_art: TextureRect = $NodeButton/NodeArt
@onready var empty_ring: TextureRect = $NodeButton/EmptyRing
@onready var active_ring: TextureRect = $ActiveRing

var node_id: int = INVALID_NODE_ID
var display_name := ""
var is_empty := false
var _icon: Texture2D

var _authority_enabled := true
var _click_enabled := true
var _is_near := false
var _is_hovered := false
var _is_focused := false
var _is_selected := false
var _is_current := false
var _is_visited := false
var _entry_reveal_progress := 1.0
var _entry_reveal_base_self_modulate := Color.WHITE


func _ready() -> void:
	_apply_content()
	_update_interaction_state()
	_update_visual_state()


func setup(
	initial_node_id: int,
	node_display_name: String,
	icon: Texture2D,
	node_is_empty: bool
) -> void:
	node_id = initial_node_id
	display_name = node_display_name
	is_empty = node_is_empty
	_icon = icon
	if not is_node_ready():
		return
	_apply_content()
	_update_visual_state()


func set_authority_enabled(enabled: bool) -> void:
	if _authority_enabled == enabled:
		return
	_authority_enabled = enabled
	if is_node_ready():
		_update_interaction_state()


func set_click_enabled(enabled: bool) -> void:
	if _click_enabled == enabled:
		return
	_click_enabled = enabled
	if is_node_ready():
		_update_interaction_state()


func set_near(enabled: bool) -> void:
	if _is_near == enabled:
		return
	_is_near = enabled
	if is_node_ready():
		_update_visual_state()


func set_selected(enabled: bool) -> void:
	if _is_selected == enabled:
		return
	_is_selected = enabled
	if is_node_ready():
		_update_visual_state()


func set_current(enabled: bool) -> void:
	if _is_current == enabled:
		return
	_is_current = enabled
	if is_node_ready():
		_update_visual_state()


func set_visited(enabled: bool) -> void:
	if _is_visited == enabled:
		return
	_is_visited = enabled
	if is_node_ready():
		_update_visual_state()


func is_interaction_enabled() -> bool:
	return _authority_enabled and _click_enabled


func get_focus_control() -> Button:
	return node_button


func get_connection_anchor() -> Vector2:
	if not is_node_ready():
		return NODE_CENTER
	return node_button.position + node_button.size * 0.5


func prepare_entry_reveal() -> void:
	if is_equal_approx(_entry_reveal_progress, 1.0):
		_entry_reveal_base_self_modulate = self_modulate
	pivot_offset = get_connection_anchor()
	set_entry_reveal_progress(0.0)


func set_entry_reveal_progress(progress: float) -> void:
	_entry_reveal_progress = clampf(progress, 0.0, 1.0)
	var alpha_progress := smoothstep(0.0, 0.72, _entry_reveal_progress)
	self_modulate = Color(
		_entry_reveal_base_self_modulate.r,
		_entry_reveal_base_self_modulate.g,
		_entry_reveal_base_self_modulate.b,
		_entry_reveal_base_self_modulate.a * alpha_progress
	)
	var reveal_scale := 1.0
	if _entry_reveal_progress < ENTRY_REVEAL_OVERSHOOT_POINT:
		var rise_progress := smoothstep(
			0.0,
			ENTRY_REVEAL_OVERSHOOT_POINT,
			_entry_reveal_progress
		)
		reveal_scale = lerpf(
			ENTRY_REVEAL_START_SCALE,
			ENTRY_REVEAL_OVERSHOOT_SCALE,
			rise_progress
		)
	else:
		var settle_progress := smoothstep(
			ENTRY_REVEAL_OVERSHOOT_POINT,
			1.0,
			_entry_reveal_progress
		)
		reveal_scale = lerpf(
			ENTRY_REVEAL_OVERSHOOT_SCALE,
			1.0,
			settle_progress
		)
	scale = Vector2.ONE * reveal_scale


func complete_entry_reveal() -> void:
	_entry_reveal_progress = 1.0
	self_modulate = _entry_reveal_base_self_modulate
	scale = Vector2.ONE


func get_entry_reveal_progress() -> float:
	return _entry_reveal_progress


func _on_node_button_pressed() -> void:
	if node_id == INVALID_NODE_ID or not is_interaction_enabled():
		return
	node_pressed.emit(node_id)


func _on_node_button_mouse_entered() -> void:
	_is_hovered = true
	_update_visual_state()


func _on_node_button_mouse_exited() -> void:
	_is_hovered = false
	_update_visual_state()


func _on_node_button_focus_entered() -> void:
	_is_focused = true
	_update_visual_state()


func _on_node_button_focus_exited() -> void:
	_is_focused = false
	_update_visual_state()


func _update_interaction_state() -> void:
	var enabled := is_interaction_enabled()
	node_button.disabled = not enabled
	node_button.focus_mode = Control.FOCUS_ALL if enabled else Control.FOCUS_NONE
	node_button.mouse_default_cursor_shape = (
		Control.CURSOR_POINTING_HAND if enabled else Control.CURSOR_ARROW
	)
	_update_visual_state()


func _apply_content() -> void:
	node_button.tooltip_text = "" if is_empty else display_name
	node_art.texture = _icon


func _update_visual_state() -> void:
	var content_modulate := Color.WHITE
	# 探索进度与“当前是否可点击”是不同概念：远处未探索节点依然
	# 保持完整亮度，只有已经走过的节点才退到背景中。
	if _is_visited and not _is_current:
		content_modulate = VISITED_NODE_MODULATE
	if _is_hovered or _is_focused or _is_selected or _is_current:
		content_modulate = content_modulate.lightened(0.10)

	current_glow.visible = _is_current
	node_art.visible = not is_empty and node_art.texture != null
	node_art.modulate = content_modulate
	empty_ring.visible = is_empty
	empty_ring.modulate = content_modulate
	# 选中和当前节点共用同一张金属圆环；不再额外画发光圆或标签。
	active_ring.visible = _is_current or _is_selected
	active_ring.modulate = Color.WHITE
