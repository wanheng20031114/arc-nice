extends Node2D
class_name CollectibleLightningEffect

var lifetime: float = 0.26
var age: float = 0.0
var height: float = 96.0
var strike_color: Color = Color(1.0, 0.88, 0.28, 1.0)


func setup(duration: float = 0.26, strike_height: float = 96.0) -> void:
	lifetime = maxf(duration, 0.05)
	height = maxf(strike_height, 16.0)
	age = 0.0
	queue_redraw()


func _process(delta: float) -> void:
	age += delta
	if age >= lifetime:
		queue_free()
		return
	queue_redraw()


func _draw() -> void:
	var alpha := 1.0 - clampf(age / lifetime, 0.0, 1.0)
	var points := PackedVector2Array([
		Vector2(-5.0, -height * 0.5),
		Vector2(4.0, -height * 0.22),
		Vector2(-3.0, -height * 0.04),
		Vector2(6.0, height * 0.18),
		Vector2(0.0, height * 0.5),
	])
	var glow := strike_color
	glow.a = 0.18 * alpha
	draw_polyline(points, glow, 8.0, true)
	var core := strike_color
	core.a = alpha
	draw_polyline(points, core, 3.0, true)
