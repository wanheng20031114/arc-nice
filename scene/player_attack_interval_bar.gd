@tool
extends Control
class_name PlayerAttackIntervalBar

@export var slot_color: Color = Color(0.035, 0.055, 0.045, 0.92)
@export var cooldown_color: Color = Color(0.38, 0.82, 0.42, 0.96)
@export var ready_color: Color = Color(0.98, 0.82, 0.28, 1.0)

var cooldown_progress: float = 1.0
var is_ready: bool = true


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	queue_redraw()


func set_cooldown_progress(progress: float, ready: bool) -> void:
	cooldown_progress = clampf(progress, 0.0, 1.0)
	is_ready = ready
	queue_redraw()


func _draw() -> void:
	if size.x <= 0.0 or size.y <= 0.0:
		return
	var slot_rect := Rect2(Vector2.ZERO, Vector2(size.x, minf(size.y, 2.0)))
	draw_rect(slot_rect, slot_color)
	var fill_rect := slot_rect
	fill_rect.size.x = roundf(slot_rect.size.x * cooldown_progress)
	if fill_rect.size.x <= 0.0:
		return
	draw_rect(fill_rect, ready_color if is_ready else cooldown_color)
