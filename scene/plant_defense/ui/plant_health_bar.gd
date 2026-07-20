@tool
extends Control
class_name PlantHealthBar

@export_group("动画")
@export_range(0.0, 1.0, 0.01) var fade_duration: float = 0.12
@export_range(0.0, 1.0, 0.01) var fill_duration: float = 0.10
@export_range(0.0, 1.0, 0.01) var damage_trail_delay: float = 0.10
@export_range(0.0, 1.0, 0.01) var damage_trail_duration: float = 0.24

@export_group("受伤后弱化")
@export_range(1.0, 60.0, 0.5, "or_greater") var idle_fade_delay: float = 15.0
@export_range(0.0, 2.0, 0.05) var idle_fade_duration: float = 0.8
@export_range(0.65, 1.0, 0.01) var idle_color_brightness: float = 0.90
@export_range(0.65, 1.0, 0.01) var idle_slot_alpha: float = 0.82

@export_group("配色")
@export var frame_color: Color = Color(0.16, 0.09, 0.045, 1.0):
	set(value):
		frame_color = value
		queue_redraw()
@export var slot_color: Color = Color(0.035, 0.047, 0.031, 0.96):
	set(value):
		slot_color = value
		queue_redraw()
@export var damage_trail_color: Color = Color(0.92, 0.53, 0.18, 1.0):
	set(value):
		damage_trail_color = value
		queue_redraw()
@export var health_fill_color: Color = Color(0.31, 0.68, 0.23, 1.0):
	set(value):
		health_fill_color = value
		queue_redraw()

@export_group("编辑器预览")
@export_range(0.0, 1.0, 0.01) var editor_preview_ratio: float = 0.72:
	set(value):
		editor_preview_ratio = clampf(value, 0.0, 1.0)
		if Engine.is_editor_hint():
			_apply_editor_preview()

var max_health_value: int = 1
var displayed_health: float = 1.0
var delayed_health: float = 1.0

var _target_health: int = 1
var _is_initialized := false
var _fill_tween: Tween = null
var _trail_tween: Tween = null
var _visibility_tween: Tween = null
var _idle_style_tween: Tween = null
var _idle_style_amount := 0.0

@onready var _idle_fade_timer: Timer = $IdleFadeTimer


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	if Engine.is_editor_hint():
		_apply_editor_preview()
		return

	visible = false
	modulate.a = 0.0
	queue_redraw()


func _notification(what: int) -> void:
	if what == NOTIFICATION_RESIZED:
		queue_redraw()


func setup(max_health: int, current_health: int) -> void:
	_stop_value_tweens()
	_stop_visibility_tween()
	_stop_idle_style_tween()
	_stop_idle_fade_timer()
	_set_idle_style_amount(0.0)

	max_health_value = maxi(max_health, 1)
	_target_health = clampi(current_health, 0, max_health_value)
	displayed_health = float(_target_health)
	delayed_health = float(_target_health)
	_is_initialized = true
	_set_visible_immediate(_target_health < max_health_value)
	if _target_health < max_health_value:
		_restart_idle_fade_timer()
	queue_redraw()


func set_health(current_health: int, max_health: int) -> void:
	if not _is_initialized:
		setup(max_health, current_health)
		return

	var previous_target := _target_health
	var previous_maximum := max_health_value
	max_health_value = maxi(max_health, 1)
	_target_health = clampi(current_health, 0, max_health_value)

	if Engine.is_editor_hint() or not is_inside_tree():
		displayed_health = float(_target_health)
		delayed_health = float(_target_health)
		_set_visible_immediate(_target_health < max_health_value)
		queue_redraw()
		return

	if _target_health >= max_health_value and not visible:
		_stop_idle_fade_timer()
		_stop_value_tweens()
		displayed_health = float(_target_health)
		delayed_health = float(_target_health)
		queue_redraw()
		return

	var took_damage := _target_health < previous_target
	var became_damaged := (
		previous_target >= previous_maximum
		and _target_health < max_health_value
	)
	_animate_current_fill(_target_health)
	_animate_damage_trail(_target_health, took_damage)
	if _target_health >= max_health_value:
		_stop_idle_fade_timer()
		_fade_out_after(maxf(fill_duration, damage_trail_duration))
	elif took_damage or became_damaged:
		_fade_in()
		_restart_idle_fade_timer()


func _draw() -> void:
	var bar_width := maxi(floori(size.x), 3)
	var bar_height := maxi(floori(size.y), 3)
	var frame_rect := Rect2(Vector2.ZERO, Vector2(bar_width, bar_height))
	var slot_rect := Rect2(Vector2.ONE, Vector2(bar_width - 2, bar_height - 2))
	var frame_draw_color := _resolve_idle_color(
		frame_color,
		idle_color_brightness,
		1.0,
		0.96
	)
	var slot_draw_color := _resolve_idle_color(
		slot_color,
		idle_color_brightness,
		idle_slot_alpha,
		1.0
	)
	var trail_draw_color := _resolve_idle_color(
		damage_trail_color,
		idle_color_brightness,
		1.0,
		1.04
	)
	var fill_draw_color := _resolve_idle_color(
		health_fill_color,
		idle_color_brightness,
		1.0,
		1.08
	)

	_draw_frame(frame_rect, frame_draw_color)
	draw_rect(slot_rect, slot_draw_color, true)
	_draw_fill(slot_rect, delayed_health, trail_draw_color)
	_draw_fill(slot_rect, displayed_health, fill_draw_color)


func _draw_frame(frame_rect: Rect2, color: Color) -> void:
	draw_rect(
		frame_rect.grow(-0.5),
		color,
		false,
		1.0,
		false
	)


func _resolve_idle_color(
	source: Color,
	brightness_scale: float,
	alpha_scale: float,
	saturation_scale: float
) -> Color:
	var target := Color.from_hsv(
		source.h,
		clampf(source.s * saturation_scale, 0.0, 1.0),
		clampf(source.v * brightness_scale, 0.0, 1.0),
		clampf(source.a * alpha_scale, 0.0, 1.0)
	)
	return source.lerp(target, clampf(_idle_style_amount, 0.0, 1.0))


func _draw_fill(slot_rect: Rect2, health_value: float, color: Color) -> void:
	if health_value <= 0.0:
		return
	var ratio := clampf(health_value / float(maxi(max_health_value, 1)), 0.0, 1.0)
	var fill_width := clampi(roundi(slot_rect.size.x * ratio), 1, roundi(slot_rect.size.x))
	draw_rect(Rect2(slot_rect.position, Vector2(fill_width, slot_rect.size.y)), color, true)


func _animate_current_fill(target_health: int) -> void:
	if _fill_tween != null and _fill_tween.is_valid():
		_fill_tween.kill()
	_fill_tween = null

	if fill_duration <= 0.0:
		_set_displayed_health(float(target_health))
		return

	_fill_tween = create_tween()
	_fill_tween.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	_fill_tween.tween_method(
		_set_displayed_health,
		displayed_health,
		float(target_health),
		fill_duration
	)


func _animate_damage_trail(target_health: int, use_delay: bool) -> void:
	if _trail_tween != null and _trail_tween.is_valid():
		_trail_tween.kill()
	_trail_tween = null

	if damage_trail_duration <= 0.0:
		_set_delayed_health(float(target_health))
		return

	_trail_tween = create_tween()
	if use_delay and damage_trail_delay > 0.0:
		_trail_tween.tween_interval(damage_trail_delay)
	_trail_tween.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_OUT)
	_trail_tween.tween_method(
		_set_delayed_health,
		delayed_health,
		float(target_health),
		damage_trail_duration
	)


func _set_displayed_health(value: float) -> void:
	displayed_health = clampf(value, 0.0, float(max_health_value))
	queue_redraw()


func _set_delayed_health(value: float) -> void:
	delayed_health = clampf(value, 0.0, float(max_health_value))
	queue_redraw()


func _fade_in() -> void:
	_stop_visibility_tween()
	_restore_active_style()
	visible = true
	if fade_duration <= 0.0 or is_equal_approx(modulate.a, 1.0):
		modulate.a = 1.0
		return

	_visibility_tween = create_tween()
	_visibility_tween.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	_visibility_tween.tween_property(self, "modulate:a", 1.0, fade_duration)


func _fade_out_after(delay: float) -> void:
	_stop_visibility_tween()
	_stop_idle_style_tween()
	_stop_idle_fade_timer()
	if not visible:
		_set_visible_immediate(false)
		return
	if fade_duration <= 0.0:
		_set_visible_immediate(false)
		return

	_visibility_tween = create_tween()
	if delay > 0.0:
		_visibility_tween.tween_interval(delay)
	_visibility_tween.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)
	_visibility_tween.tween_property(self, "modulate:a", 0.0, fade_duration)
	_visibility_tween.tween_callback(_finish_fade_out)


func _finish_fade_out() -> void:
	_visibility_tween = null
	_set_visible_immediate(false)


func _on_idle_fade_timer_timeout() -> void:
	if not visible or _target_health >= max_health_value:
		return
	_stop_idle_style_tween()
	if (
		idle_fade_duration <= 0.0
		or is_equal_approx(_idle_style_amount, 1.0)
	):
		_set_idle_style_amount(1.0)
		return
	_idle_style_tween = create_tween()
	_idle_style_tween.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_OUT)
	_idle_style_tween.tween_method(
		_set_idle_style_amount,
		_idle_style_amount,
		1.0,
		idle_fade_duration
	)


func _restart_idle_fade_timer() -> void:
	if (
		Engine.is_editor_hint()
		or not is_inside_tree()
		or _idle_fade_timer == null
	):
		return
	if idle_fade_delay <= 0.0:
		_on_idle_fade_timer_timeout()
		return
	_idle_fade_timer.start(idle_fade_delay)


func _stop_idle_fade_timer() -> void:
	if _idle_fade_timer != null:
		_idle_fade_timer.stop()


func _set_visible_immediate(should_show: bool) -> void:
	visible = should_show
	modulate.a = 1.0 if should_show else 0.0
	if not should_show:
		_stop_idle_fade_timer()
		_stop_idle_style_tween()
		_set_idle_style_amount(0.0)


func _restore_active_style() -> void:
	_stop_idle_style_tween()
	_set_idle_style_amount(0.0)


func _set_idle_style_amount(value: float) -> void:
	_idle_style_amount = clampf(value, 0.0, 1.0)
	queue_redraw()


func _stop_value_tweens() -> void:
	if _fill_tween != null and _fill_tween.is_valid():
		_fill_tween.kill()
	if _trail_tween != null and _trail_tween.is_valid():
		_trail_tween.kill()
	_fill_tween = null
	_trail_tween = null


func _stop_visibility_tween() -> void:
	if _visibility_tween != null and _visibility_tween.is_valid():
		_visibility_tween.kill()
	_visibility_tween = null


func _stop_idle_style_tween() -> void:
	if _idle_style_tween != null and _idle_style_tween.is_valid():
		_idle_style_tween.kill()
	_idle_style_tween = null


func _apply_editor_preview() -> void:
	max_health_value = 100
	_target_health = roundi(float(max_health_value) * editor_preview_ratio)
	displayed_health = float(_target_health)
	delayed_health = minf(float(max_health_value), displayed_health + 14.0)
	visible = true
	modulate.a = 1.0
	_idle_style_amount = 0.0
	queue_redraw()
