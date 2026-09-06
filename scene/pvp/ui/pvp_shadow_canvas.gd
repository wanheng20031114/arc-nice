extends Node2D
## All opaque white shadows are drawn into one transparent SubViewport, so
## overlapping shadows never become darker and thin gaps remain deterministic.

var _polygons: Array[PackedVector2Array] = []
var _source_inside_wall := false
var _screen_size := Vector2.ZERO


func update_shadows(obstacles: Array[Rect2], origin: Vector2, canvas_transform: Transform2D, reach: float, screen_size: Vector2) -> void:
	_polygons.clear()
	_source_inside_wall = false
	_screen_size = screen_size
	for obstacle: Rect2 in obstacles:
		if obstacle.has_point(origin):
			_source_inside_wall = true
			break
		var polygon := PvpVisibility.build_shadow_polygon(obstacle, origin, reach)
		_polygons.append(canvas_transform * polygon)
	queue_redraw()


func _draw() -> void:
	if _source_inside_wall:
		draw_rect(Rect2(Vector2.ZERO, _screen_size), Color.WHITE)
		return
	for polygon: PackedVector2Array in _polygons:
		draw_colored_polygon(polygon, Color.WHITE)
