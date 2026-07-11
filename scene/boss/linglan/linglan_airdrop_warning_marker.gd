extends Node2D
class_name LinglanAirdropWarningMarker

@export_range(4.0, 96.0, 1.0, "or_greater") var base_radius: float = 26.0
@export_range(0.05, 5.0, 0.05, "or_greater") var duration: float = 1.2

var elapsed: float = 0.0


func _ready() -> void:
	set_process(false)
	queue_redraw()


func start(seconds: float) -> void:
	duration = maxf(seconds, 0.05)
	elapsed = 0.0
	set_process(true)
	queue_redraw()


func _process(delta: float) -> void:
	elapsed += maxf(delta, 0.0)
	if elapsed >= duration:
		queue_free()
		return
	queue_redraw()


func _draw() -> void:
	var progress := clampf(elapsed / maxf(duration, 0.05), 0.0, 1.0)
	var pulse := 0.5 + 0.5 * sin(progress * TAU * 3.0)
	var radius := lerpf(base_radius * 1.35, base_radius * 0.82, progress)
	var alpha := lerpf(0.34, 0.88, progress) * lerpf(0.8, 1.0, pulse)
	var fill_color := Color(1.0, 0.14, 0.08, 0.12 * alpha)
	var ring_color := Color(1.0, 0.18, 0.08, alpha)
	var core_color := Color(1.0, 0.92, 0.74, 0.86 * alpha)

	draw_circle(Vector2.ZERO, radius, fill_color)
	draw_arc(Vector2.ZERO, radius, 0.0, TAU, 48, ring_color, 2.0, true)
	draw_arc(Vector2.ZERO, radius * 0.58, 0.0, TAU, 36, ring_color, 1.5, true)
	draw_line(Vector2(-radius, 0.0), Vector2(radius, 0.0), ring_color, 2.0, true)
	draw_line(Vector2(0.0, -radius), Vector2(0.0, radius), ring_color, 2.0, true)
	draw_line(Vector2(-5.0, 0.0), Vector2(5.0, 0.0), core_color, 1.5, true)
	draw_line(Vector2(0.0, -5.0), Vector2(0.0, 5.0), core_color, 1.5, true)
