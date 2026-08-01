@tool
extends Control
class_name PlayerAttackIntervalBar

@export var slot_color: Color = Color(0.035, 0.055, 0.045, 0.92)
@export var cooldown_color: Color = Color(0.38, 0.82, 0.42, 0.96)
@export var ready_color: Color = Color(0.98, 0.82, 0.28, 1.0)
@export var empowered_color_a: Color = Color(1.0, 0.78, 0.08, 1.0)
@export var empowered_color_b: Color = Color(1.0, 1.0, 0.92, 1.0)

@onready var empowered_animation_player: AnimationPlayer = $EmpoweredAnimationPlayer

var cooldown_progress: float = 1.0
var is_ready: bool = true
var empowered_active := false
var empowered_flash_phase := 0.0:
	set(value):
		empowered_flash_phase = clampf(value, 0.0, 1.0)
		queue_redraw()


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	queue_redraw()


func set_cooldown_progress(progress: float, ready_state: bool) -> void:
	var next_progress := clampf(progress, 0.0, 1.0)
	if is_equal_approx(cooldown_progress, next_progress) and is_ready == ready_state:
		return
	cooldown_progress = next_progress
	is_ready = ready_state
	# Electric Surge owns the complete fill and flash colour. Keep the ordinary
	# value current for the frame where the buff ends, but let the authored flash
	# animation remain the only redraw source while the empowered visual is active.
	if not empowered_active:
		queue_redraw()


func set_empowered_active(active: bool) -> void:
	if empowered_active == active:
		return
	empowered_active = active
	if active:
		empowered_animation_player.play(&"empowered_flash")
	else:
		empowered_animation_player.stop()
		empowered_flash_phase = 0.0
	queue_redraw()


func _draw() -> void:
	if size.x <= 0.0 or size.y <= 0.0:
		return
	var slot_rect := Rect2(Vector2.ZERO, Vector2(size.x, minf(size.y, 2.0)))
	draw_rect(slot_rect, slot_color)
	var fill_rect := slot_rect
	var visual_progress := 1.0 if empowered_active else cooldown_progress
	fill_rect.size.x = roundf(slot_rect.size.x * visual_progress)
	if fill_rect.size.x <= 0.0:
		return
	var fill_color := ready_color if is_ready else cooldown_color
	if empowered_active:
		fill_color = empowered_color_a.lerp(
			empowered_color_b,
			empowered_flash_phase
		)
	draw_rect(fill_rect, fill_color)
