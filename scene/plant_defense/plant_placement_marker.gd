extends Node2D
class_name PlantPlacementMarker

const FILL_COLOR := Color(0.22, 1.0, 0.42, 0.22)
const RING_COLOR := Color(0.38, 1.0, 0.5, 0.9)
const HOVER_FILL_COLOR := Color(0.54, 1.0, 0.62, 0.4)
const HOVER_RING_COLOR := Color(0.82, 1.0, 0.84, 1.0)

var top_left_cell := Vector2i.ZERO
var highlighted := false


func setup(cell: Vector2i, world_position: Vector2) -> void:
	top_left_cell = cell
	global_position = world_position


func set_highlighted(value: bool) -> void:
	if highlighted == value:
		return
	highlighted = value
	queue_redraw()


func _draw() -> void:
	var fill_color := HOVER_FILL_COLOR if highlighted else FILL_COLOR
	var ring_color := HOVER_RING_COLOR if highlighted else RING_COLOR
	var radius := 5.0 if highlighted else 4.0
	draw_circle(Vector2.ZERO, radius, fill_color, true, -1.0, false)
	draw_arc(Vector2.ZERO, radius, 0.0, TAU, 20, ring_color, 1.5, false)
	draw_line(Vector2(-2.0, 0.0), Vector2(2.0, 0.0), ring_color, 1.0, false)
	draw_line(Vector2(0.0, -2.0), Vector2(0.0, 2.0), ring_color, 1.0, false)
