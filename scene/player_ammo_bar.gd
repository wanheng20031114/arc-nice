@tool
extends Control
class_name PlayerAmmoBar

@export var slot_color: Color = Color(0.04, 0.045, 0.04, 0.9)
@export var ammo_color: Color = Color(1.0, 0.56, 0.08, 0.98)
@export var separator_color: Color = Color(0.16, 0.07, 0.015, 0.82)
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
	if size.x <= 0.0 or size.y <= 0.0:
		return
	var slot_rect := Rect2(Vector2.ZERO, Vector2(size.x, minf(size.y, 2.0)))

	draw_rect(slot_rect, slot_color)

	if is_reloading:
		var reload_rect := slot_rect
		reload_rect.size.x = maxf(slot_rect.size.x * reload_progress, 0.0)
		if reload_rect.size.x > 0.0:
			draw_rect(reload_rect, reload_color)
		return

	var cell_width := slot_rect.size.x / float(max_ammo)
	var ammo_width := slot_rect.size.x * (float(current_ammo) / float(max_ammo))
	if ammo_width <= 0.0:
		return
	if cell_width < 2.0:
		draw_rect(
			Rect2(slot_rect.position, Vector2(ammo_width, slot_rect.size.y)),
			ammo_color
		)
		return

	for ammo_index in range(current_ammo):
		var cell_x := floorf(slot_rect.position.x + float(ammo_index) * cell_width)
		var next_cell_x := floorf(slot_rect.position.x + float(ammo_index + 1) * cell_width)
		var cell_pixel_width := maxf(next_cell_x - cell_x, 1.0)
		var fill_width := maxf(cell_pixel_width - 1.0, 1.0)
		draw_rect(
			Rect2(
				Vector2(cell_x, slot_rect.position.y),
				Vector2(fill_width, slot_rect.size.y)
			),
			ammo_color
		)
