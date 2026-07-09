@tool
extends Control
class_name PlayerAmmoBar

@export var frame_color: Color = Color(0.18, 0.2, 0.19, 0.96)
@export var slot_color: Color = Color(0.04, 0.045, 0.04, 0.9)
@export var ammo_color: Color = Color(0.46, 0.9, 0.35, 0.96)
@export var separator_color: Color = Color(0.02, 0.025, 0.02, 0.72)
@export var reload_color: Color = Color(0.98, 0.78, 0.18, 0.98)

var current_ammo: int = 0
var max_ammo: int = 1
var is_reloading: bool = false
var reload_progress: float = 0.0


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	if Engine.is_editor_hint():
		set_ammo_state(21, 30, false, 0.0)


func set_ammo_state(
	new_current_ammo: int,
	new_max_ammo: int,
	new_is_reloading: bool,
	new_reload_progress: float
) -> void:
	max_ammo = maxi(new_max_ammo, 1)
	current_ammo = clampi(new_current_ammo, 0, max_ammo)
	is_reloading = new_is_reloading
	reload_progress = clampf(new_reload_progress, 0.0, 1.0)
	queue_redraw()


func _draw() -> void:
	var frame_rect := Rect2(Vector2.ZERO, size)
	var slot_rect := frame_rect.grow(-1.0)
	if frame_rect.size.x <= 0.0 or frame_rect.size.y <= 0.0:
		return

	draw_rect(frame_rect, frame_color)
	draw_rect(slot_rect, slot_color)
	if slot_rect.size.x <= 0.0 or slot_rect.size.y <= 0.0:
		return

	if is_reloading:
		var reload_rect := slot_rect
		reload_rect.size.x = maxf(slot_rect.size.x * reload_progress, 0.0)
		if reload_rect.size.x > 0.0:
			draw_rect(reload_rect, reload_color)
		return

	var cell_width := slot_rect.size.x / float(max_ammo)
	for ammo_index in range(max_ammo):
		var cell_rect := Rect2(
			Vector2(slot_rect.position.x + float(ammo_index) * cell_width, slot_rect.position.y),
			Vector2(cell_width, slot_rect.size.y)
		)
		if ammo_index < current_ammo:
			draw_rect(cell_rect, ammo_color)
		if ammo_index > 0 and cell_width >= 0.6:
			var line_x := slot_rect.position.x + float(ammo_index) * cell_width
			draw_line(
				Vector2(line_x, slot_rect.position.y),
				Vector2(line_x, slot_rect.position.y + slot_rect.size.y),
				separator_color,
				1.0,
				false
			)
