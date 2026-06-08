@tool
extends Control

@export var fade_duration: float = 0.16
@export var value_duration: float = 0.18
@export var frame_color: Color = Color(0.18, 0.2, 0.21, 0.96)
@export var slot_color: Color = Color(0.045, 0.05, 0.055, 0.92)
@export_range(0.0, 1.0, 0.05) var editor_preview_ratio: float = 0.7:
	set(value):
		editor_preview_ratio = value
		if Engine.is_editor_hint():
			_apply_editor_preview()

var value_tween: Tween = null
var visibility_tween: Tween = null
var color_tween: Tween = null
var displayed_health: float = 0.0
var displayed_color: Color = Color(0.27, 0.68, 0.28)
var max_health_value: int = 1


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	if Engine.is_editor_hint():
		_apply_editor_preview()
		return

	visible = false
	modulate.a = 0.0


func setup(max_health: int, current_health: int) -> void:
	max_health_value = maxi(max_health, 1)
	displayed_health = clampi(current_health, 0, max_health_value)
	displayed_color = _get_health_color(_get_health_ratio(displayed_health, max_health_value))
	_set_visible_immediate(current_health < max_health_value)
	queue_redraw()


func set_health(current_health: int, max_health: int) -> void:
	max_health_value = maxi(max_health, 1)
	var safe_current_health := clampi(current_health, 0, max_health_value)
	var health_ratio := _get_health_ratio(safe_current_health, max_health_value)

	_animate_value(safe_current_health)
	_update_fill_color(health_ratio, false)

	if safe_current_health >= max_health_value:
		_fade_out()
	else:
		_fade_in()


func _draw() -> void:
	if Engine.is_editor_hint():
		_apply_editor_preview_values()

	var frame_rect := Rect2(Vector2.ZERO, size)
	var slot_rect := frame_rect.grow(-1.0)
	var health_ratio := _get_health_ratio(displayed_health, max_health_value)
	var fill_rect := slot_rect
	fill_rect.size.x = maxf(round(slot_rect.size.x * health_ratio), 0.0)

	_draw_rounded_rect(frame_rect, frame_color, 2)
	_draw_rounded_rect(slot_rect, slot_color, 1)
	if fill_rect.size.x > 0.0:
		_draw_rounded_rect(fill_rect, displayed_color, 1)


func _animate_value(target_value: int) -> void:
	if value_tween != null:
		value_tween.kill()

	value_tween = create_tween()
	value_tween.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_OUT)
	value_tween.tween_method(_set_displayed_health, displayed_health, float(target_value), value_duration)


func _update_fill_color(health_ratio: float, immediate: bool) -> void:
	var target_color := _get_health_color(health_ratio)
	if color_tween != null:
		color_tween.kill()

	if immediate:
		displayed_color = target_color
		queue_redraw()
		return

	color_tween = create_tween()
	color_tween.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_OUT)
	color_tween.tween_method(_set_displayed_color, displayed_color, target_color, value_duration)


func _set_displayed_health(value: float) -> void:
	displayed_health = value
	queue_redraw()


func _set_displayed_color(value: Color) -> void:
	displayed_color = value
	queue_redraw()


func _draw_rounded_rect(rect: Rect2, color: Color, corner_radius: int) -> void:
	var style_box := StyleBoxFlat.new()
	style_box.bg_color = color
	style_box.corner_radius_top_left = corner_radius
	style_box.corner_radius_top_right = corner_radius
	style_box.corner_radius_bottom_right = corner_radius
	style_box.corner_radius_bottom_left = corner_radius
	draw_style_box(style_box, rect)


func _fade_in() -> void:
	if visibility_tween != null:
		visibility_tween.kill()

	visible = true
	visibility_tween = create_tween()
	visibility_tween.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_OUT)
	visibility_tween.tween_property(self, "modulate:a", 1.0, fade_duration)


func _fade_out() -> void:
	if visibility_tween != null:
		visibility_tween.kill()

	visibility_tween = create_tween()
	visibility_tween.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN)
	visibility_tween.tween_property(self, "modulate:a", 0.0, fade_duration)
	visibility_tween.finished.connect(func() -> void: visible = false)


func _set_visible_immediate(should_show: bool) -> void:
	visible = should_show
	modulate.a = 1.0 if should_show else 0.0


func _apply_editor_preview() -> void:
	_apply_editor_preview_values()
	visible = true
	modulate.a = 1.0
	queue_redraw()


func _apply_editor_preview_values() -> void:
	max_health_value = 100
	displayed_health = roundf(editor_preview_ratio * max_health_value)
	displayed_color = _get_health_color(editor_preview_ratio)


func _get_health_ratio(current_health: float, safe_max_health: int) -> float:
	return clampf(current_health / float(safe_max_health), 0.0, 1.0)


func _get_health_color(health_ratio: float) -> Color:
	var green := Color(0.27, 0.68, 0.28)
	var yellow := Color(0.82, 0.7, 0.18)
	var orange := Color(0.86, 0.4, 0.12)
	var red := Color(0.82, 0.16, 0.12)

	if health_ratio >= 0.6:
		return yellow.lerp(green, inverse_lerp(0.6, 1.0, health_ratio))
	if health_ratio >= 0.3:
		return orange.lerp(yellow, inverse_lerp(0.3, 0.6, health_ratio))

	return red.lerp(orange, inverse_lerp(0.0, 0.3, health_ratio))
