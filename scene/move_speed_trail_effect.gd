extends Node2D

const MIN_DIRECTION_LENGTH_SQUARED := 0.001
const TRAIL_STEP_DISTANCE := 7.0

@export var base_length: float = 28.0
@export var drift_speed: float = 3.6

@onready var trail_lines: Array[Line2D] = [
	$TrailLong,
	$TrailMid,
	$TrailShort,
	$TrailFar,
]

var motion_direction := Vector2.RIGHT
var _phase := 0.0


func _ready() -> void:
	visible = false
	set_process(false)
	_redraw_lines()


func set_effect_active(enabled: bool) -> void:
	if visible == enabled:
		return
	visible = enabled
	set_process(enabled)
	if enabled:
		_redraw_lines()
	else:
		_clear_lines()


func set_motion_direction(direction: Vector2) -> void:
	if direction.length_squared() >= MIN_DIRECTION_LENGTH_SQUARED:
		motion_direction = direction.normalized()
	if visible:
		_redraw_lines()


func _process(delta: float) -> void:
	_phase = fmod(_phase + delta * drift_speed, 1.0)
	_redraw_lines()


func _redraw_lines() -> void:
	var back_direction := -motion_direction
	var side_direction := Vector2(-motion_direction.y, motion_direction.x)
	var moving_offset := _phase * TRAIL_STEP_DISTANCE
	var side_offsets: Array[float] = [-7.0, -2.5, 4.0, 8.0]
	var start_offsets: Array[float] = [4.0, 9.0, 6.0, 14.0]
	var lengths: Array[float] = [base_length, base_length * 0.74, base_length * 0.56, base_length * 0.4]

	for index in range(trail_lines.size()):
		var line := trail_lines[index]
		var start: Vector2 = (
			back_direction * (start_offsets[index] + moving_offset)
			+ side_direction * side_offsets[index]
		)
		var end_point: Vector2 = start + back_direction * lengths[index]
		line.points = PackedVector2Array([start, end_point])


func _clear_lines() -> void:
	for line in trail_lines:
		line.points = PackedVector2Array()
