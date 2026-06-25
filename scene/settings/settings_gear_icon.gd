extends Control


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	queue_redraw()


func _draw() -> void:
	var side := minf(size.x, size.y)
	if side <= 0.0:
		return
	var draw_scale := side / 64.0
	var center := size * 0.5
	var gold := Color(0.84, 0.71, 0.36, 1.0)
	var dark := Color(0.27, 0.23, 0.15, 1.0)
	var highlight := Color(1.0, 0.94, 0.66, 0.45)
	var tooth_size := Vector2(8.0, 14.0) * draw_scale
	var tooth_offsets := [
		Vector2(0.0, -24.0),
		Vector2(0.0, 24.0),
		Vector2(-24.0, 0.0),
		Vector2(24.0, 0.0),
		Vector2(-17.0, -17.0),
		Vector2(17.0, -17.0),
		Vector2(-17.0, 17.0),
		Vector2(17.0, 17.0),
	]
	for offset in tooth_offsets:
		var rect_size := tooth_size
		if absf(offset.x) > absf(offset.y):
			rect_size = Vector2(tooth_size.y, tooth_size.x)
		if absf(offset.x) == absf(offset.y):
			rect_size = Vector2(10.0, 10.0) * draw_scale
		draw_rect(Rect2(center + offset * draw_scale - rect_size * 0.5, rect_size), gold)
	draw_circle(center, 21.0 * draw_scale, gold)
	draw_arc(center, 21.0 * draw_scale, 0.0, TAU, 64, dark, 3.0 * draw_scale)
	draw_circle(center, 11.0 * draw_scale, dark)
	draw_arc(center, 6.0 * draw_scale, 0.0, TAU, 32, Color(0.96, 0.84, 0.48, 1.0), 3.0 * draw_scale)
	draw_rect(Rect2(center + Vector2(-3.0, -23.0) * draw_scale, Vector2(6.0, 8.0) * draw_scale), highlight)
	draw_rect(Rect2(center + Vector2(-15.0, -17.0) * draw_scale, Vector2(7.0, 5.0) * draw_scale), highlight)
