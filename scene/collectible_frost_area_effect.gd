extends Node2D
class_name CollectibleFrostAreaEffect

const SHARD_ANGLES: Array[float] = [
	0.0,
	0.42,
	0.86,
	1.18,
	1.62,
	2.06,
	2.44,
	2.82,
	3.26,
	3.68,
	4.04,
	4.48,
	4.9,
	5.28,
	5.7,
	6.04,
]
const SHARD_LENGTHS: Array[float] = [
	0.22,
	0.13,
	0.18,
	0.1,
	0.2,
	0.14,
	0.23,
	0.12,
	0.19,
	0.15,
	0.21,
	0.11,
	0.24,
	0.13,
	0.18,
	0.16,
]

var effect_radius: float = 72.0
var lifetime: float = 0.72
var age: float = 0.0


func setup(radius: float, duration: float = 0.72) -> void:
	effect_radius = maxf(radius, 1.0)
	lifetime = maxf(duration, 0.08)
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
	var alpha := smoothstep(1.0, 0.0, progress)
	var wave_radius := lerpf(effect_radius * 0.28, effect_radius, progress)
	var mist_radius := lerpf(effect_radius * 0.52, effect_radius * 0.96, progress)

	draw_circle(Vector2.ZERO, mist_radius, Color(0.42, 0.86, 1.0, 0.18 * alpha))
	draw_circle(Vector2.ZERO, effect_radius * 0.38, Color(0.72, 0.96, 1.0, 0.08 * alpha))

	_draw_arc_band(wave_radius, alpha)
	_draw_ice_shards(progress, alpha)
	_draw_inner_snow(progress, alpha)


func _draw_arc_band(wave_radius: float, alpha: float) -> void:
	var outer := Color(0.72, 0.96, 1.0, 0.92 * alpha)
	var inner := Color(0.18, 0.56, 0.95, 0.42 * alpha)
	draw_arc(Vector2.ZERO, wave_radius, 0.0, TAU, 128, outer, 3.0, true)
	draw_arc(Vector2.ZERO, wave_radius * 0.74, 0.0, TAU, 128, inner, 1.5, true)
	for index in range(8):
		var start_angle := float(index) * TAU / 8.0 + 0.12
		draw_arc(
			Vector2.ZERO,
			wave_radius * 0.88,
			start_angle,
			start_angle + 0.26,
			10,
			Color(0.88, 1.0, 1.0, 0.7 * alpha),
			2.0,
			true
		)


func _draw_ice_shards(progress: float, alpha: float) -> void:
	var base_radius := lerpf(effect_radius * 0.18, effect_radius * 0.66, progress)
	var grow := effect_radius * lerpf(0.18, 0.42, progress)
	for index in range(SHARD_ANGLES.size()):
		var direction := Vector2.from_angle(SHARD_ANGLES[index])
		var length := grow * SHARD_LENGTHS[index]
		var start := direction * base_radius
		var end := direction * minf(base_radius + length, effect_radius * 0.96)
		var shard_alpha := alpha * (0.62 + 0.38 * sin(float(index) * 1.7))
		draw_line(start, end, Color(0.62, 0.9, 1.0, 0.7 * shard_alpha), 2.0, true)
		draw_line(
			start.lerp(end, 0.52),
			start.lerp(end, 0.88) + direction.orthogonal() * 3.0,
			Color(0.9, 1.0, 1.0, 0.45 * shard_alpha),
			1.0,
			true
		)


func _draw_inner_snow(progress: float, alpha: float) -> void:
	for index in range(10):
		var angle := float(index) * TAU / 10.0 + progress * 0.8
		var radius := effect_radius * (0.16 + 0.04 * float(index % 4)) + progress * effect_radius * 0.18
		var center := Vector2.from_angle(angle) * radius
		var size := 1.6 + float(index % 3) * 0.45
		var color := Color(0.9, 1.0, 1.0, 0.58 * alpha)
		draw_line(center + Vector2(-size, 0.0), center + Vector2(size, 0.0), color, 1.0, true)
		draw_line(center + Vector2(0.0, -size), center + Vector2(0.0, size), color, 1.0, true)
