extends Control
class_name TowerDefenseMinimapStaticLayer

const BACKGROUND_COLOR := Color(0.018, 0.035, 0.03, 0.94)
const WATER_COLOR := Color(0.38, 0.76, 0.91, 0.82)
const WALL_COLOR := Color(0.53, 0.55, 0.58, 0.96)
const HOME_GATE_COLOR := Color(0.08, 0.52, 1.0, 1.0)
const ENEMY_GATE_COLOR := Color(1.0, 0.22, 0.18, 1.0)
const VIEW_FRAME_COLOR := Color(0.22, 1.0, 0.42, 0.96)
const VIEW_FRAME_WIDTH := 1.25

var tile_world_size := Vector2(16.0, 16.0)
var wall_world_positions := PackedVector2Array()
var water_world_positions := PackedVector2Array()
var home_gate_world_positions := PackedVector2Array()
var enemy_gate_world_positions := PackedVector2Array()

var world_center := Vector2.ZERO
var overview_world_size := Vector2(1.0, 1.0)
var visible_world_size := Vector2.ONE
var _projection_scale := 1.0
var _projection_origin := Vector2.ZERO
var _world_top_left := Vector2.ZERO
var _cached_overview_rect := Rect2(Vector2.ZERO, Vector2.ONE)
var _projected_tile_size := Vector2(16.0, 16.0)
var _projected_half_tile := Vector2(8.0, 8.0)


func _ready() -> void:
	_refresh_projection_cache()


func _notification(what: int) -> void:
	if what != NOTIFICATION_RESIZED:
		return
	_refresh_projection_cache()
	queue_redraw()


func set_topology(
	new_tile_world_size: Vector2,
	new_wall_world_positions: PackedVector2Array,
	new_water_world_positions: PackedVector2Array,
	new_home_gate_world_positions: PackedVector2Array,
	new_enemy_gate_world_positions: PackedVector2Array
) -> void:
	tile_world_size = new_tile_world_size
	wall_world_positions = new_wall_world_positions
	water_world_positions = new_water_world_positions
	home_gate_world_positions = new_home_gate_world_positions
	enemy_gate_world_positions = new_enemy_gate_world_positions
	_refresh_projected_tile_cache()
	queue_redraw()


func set_projection(
	new_world_center: Vector2,
	new_overview_world_size: Vector2,
	new_visible_world_size: Vector2
) -> void:
	world_center = new_world_center
	overview_world_size = new_overview_world_size
	visible_world_size = new_visible_world_size
	_refresh_projection_cache()
	queue_redraw()


func get_projected_view_rect() -> Rect2:
	return _world_rect_to_canvas(
		Rect2(world_center - visible_world_size * 0.5, visible_world_size)
	)


func _draw() -> void:
	draw_rect(Rect2(Vector2.ZERO, size), BACKGROUND_COLOR)
	_draw_world_squares(water_world_positions, WATER_COLOR)
	_draw_world_squares(wall_world_positions, WALL_COLOR)
	_draw_world_squares(enemy_gate_world_positions, ENEMY_GATE_COLOR)
	_draw_world_squares(home_gate_world_positions, HOME_GATE_COLOR)

	var view_rect := get_projected_view_rect()
	draw_rect(view_rect, VIEW_FRAME_COLOR, false, VIEW_FRAME_WIDTH, true)


func _draw_world_squares(positions: PackedVector2Array, color: Color) -> void:
	var half_tile := tile_world_size * 0.5
	for world_position in positions:
		var tile_rect := Rect2(world_position - half_tile, tile_world_size)
		if not _cached_overview_rect.intersects(tile_rect):
			continue
		var canvas_center := (
			_projection_origin
			+ (world_position - _world_top_left) * _projection_scale
		)
		draw_rect(
			Rect2(canvas_center - _projected_half_tile, _projected_tile_size),
			color
		)


func _world_rect_to_canvas(world_rect: Rect2) -> Rect2:
	return Rect2(
		_world_to_canvas(world_rect.position),
		world_rect.size * _projection_scale
	)


func _world_to_canvas(world_position: Vector2) -> Vector2:
	return _projection_origin + (world_position - _world_top_left) * _projection_scale


func _refresh_projection_cache() -> void:
	var safe_world_size := Vector2(
		maxf(overview_world_size.x, 0.001),
		maxf(overview_world_size.y, 0.001)
	)
	_projection_scale = minf(size.x / safe_world_size.x, size.y / safe_world_size.y)
	var projected_world_size := safe_world_size * _projection_scale
	_projection_origin = (size - projected_world_size) * 0.5
	_world_top_left = world_center - safe_world_size * 0.5
	_cached_overview_rect = Rect2(_world_top_left, safe_world_size)
	_refresh_projected_tile_cache()


func _refresh_projected_tile_cache() -> void:
	_projected_tile_size = tile_world_size * _projection_scale
	_projected_half_tile = _projected_tile_size * 0.5
