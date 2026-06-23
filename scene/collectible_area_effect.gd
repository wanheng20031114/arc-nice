extends Node2D
class_name CollectibleAreaEffect

var effect_radius: float = 48.0
var lifetime: float = 0.45
var age: float = 0.0
var effect_color: Color = Color(0.45, 0.9, 1.0, 0.34)


func setup(radius: float, color: Color, duration: float = 0.45) -> void:
	effect_radius = maxf(radius, 1.0)
	effect_color = color
	lifetime = maxf(duration, 0.05)
	age = 0.0
	queue_redraw()


func _process(delta: float) -> void:
	age += delta
	if age >= lifetime:
		queue_free()
		return
	queue_redraw()


func _draw() -> void:
	var progress := clampf(age / lifetime, 0.0, 1.0)
	var alpha := 1.0 - progress
	var radius := lerpf(effect_radius * 0.72, effect_radius, progress)
	var fill := effect_color
	fill.a *= 0.38 * alpha
	var edge := effect_color
	edge.a *= alpha
	draw_circle(Vector2.ZERO, radius, fill)
	draw_arc(Vector2.ZERO, radius, 0.0, TAU, 96, edge, 2.0, true)
