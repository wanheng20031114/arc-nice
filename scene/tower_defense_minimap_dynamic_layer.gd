extends Control
class_name TowerDefenseMinimapDynamicLayer

const LOCAL_PLAYER_COLOR := Color(0.18, 1.0, 0.38, 1.0)
const REMOTE_PLAYER_COLOR := Color(0.96, 0.98, 1.0, 1.0)
const ENEMY_COLOR := Color(1.0, 0.18, 0.14, 1.0)
const PLANT_COLOR := Color(0.52, 0.91, 0.54, 0.96)
const MARKER_OUTLINE_COLOR := Color(0.015, 0.025, 0.02, 0.96)
const LOCAL_PLAYER_COLOR_CENTER := Color(0.72, 1.0, 0.78, 1.0)
const LOCAL_PLAYER_RADIUS := 1.65
const LOCAL_PLAYER_CENTER_RADIUS := 0.5
const REMOTE_PLAYER_RADIUS := 1.2
const PLAYER_MARKER_OUTLINE_WIDTH := 0.35
const ENEMY_BUCKET_SIZE_PX := 4.0
const ENEMY_SINGLE_RADIUS := 1.0
const ENEMY_MEDIUM_RADIUS := 1.4
const ENEMY_HIGH_RADIUS := 1.8
const ENEMY_MEDIUM_DENSITY := 2
const ENEMY_HIGH_DENSITY := 5

var tile_world_size := Vector2(16.0, 16.0)
var world_center := Vector2.ZERO
var overview_world_size := Vector2.ONE
var local_player_world_position := Vector2.ZERO
var remote_player_world_positions := PackedVector2Array()
var enemy_world_positions := PackedVector2Array()
var plant_world_positions := PackedVector2Array()


func set_tile_world_size(new_tile_world_size: Vector2) -> void:
	tile_world_size = new_tile_world_size


func set_projection(new_world_center: Vector2, new_overview_world_size: Vector2) -> void:
	world_center = new_world_center
	overview_world_size = new_overview_world_size
	queue_redraw()


func set_local_player_position(world_position: Vector2) -> void:
	local_player_world_position = world_position
	queue_redraw()


func set_world_entities(
	new_remote_player_world_positions: PackedVector2Array,
	new_enemy_world_positions: PackedVector2Array,
	new_plant_world_positions: PackedVector2Array
) -> void:
	remote_player_world_positions = new_remote_player_world_positions
	enemy_world_positions = new_enemy_world_positions
	plant_world_positions = new_plant_world_positions
	queue_redraw()


func _draw() -> void:
	var overview_rect := Rect2(world_center - overview_world_size * 0.5, overview_world_size)
	var plant_size := _projected_tile_size()
	for world_position in plant_world_positions:
		if not overview_rect.has_point(world_position):
			continue
		var center := _world_to_canvas(world_position)
		draw_rect(Rect2(center - plant_size * 0.5, plant_size), PLANT_COLOR)

	_draw_enemy_buckets(overview_rect)
	for world_position in remote_player_world_positions:
		_draw_player_dot_if_visible(
			world_position,
			REMOTE_PLAYER_RADIUS,
			REMOTE_PLAYER_COLOR,
			overview_rect
		)
	_draw_player_dot_if_visible(
		local_player_world_position,
		LOCAL_PLAYER_RADIUS,
		LOCAL_PLAYER_COLOR,
		overview_rect
	)
	if overview_rect.has_point(local_player_world_position):
		draw_circle(
			_world_to_canvas(local_player_world_position),
			LOCAL_PLAYER_CENTER_RADIUS,
			LOCAL_PLAYER_COLOR_CENTER
		)


func _draw_player_dot_if_visible(
	world_position: Vector2,
	radius: float,
	color: Color,
	overview_rect: Rect2
) -> void:
	if not overview_rect.has_point(world_position):
		return
	var canvas_position := _world_to_canvas(world_position)
	draw_circle(canvas_position, radius + PLAYER_MARKER_OUTLINE_WIDTH, MARKER_OUTLINE_COLOR)
	draw_circle(canvas_position, radius, color)


func _draw_enemy_buckets(overview_rect: Rect2) -> void:
	for bucket in _build_enemy_canvas_buckets(overview_rect):
		var enemy_count: int = bucket["count"]
		var canvas_position: Vector2 = bucket["canvas_position"]
		draw_circle(canvas_position, get_enemy_marker_radius(enemy_count), ENEMY_COLOR)


func _build_enemy_canvas_buckets(overview_rect: Rect2) -> Array[Dictionary]:
	var bucket_data := {}
	for world_position in enemy_world_positions:
		if not overview_rect.has_point(world_position):
			continue
		var canvas_position := _world_to_canvas(world_position)
		var bucket_coordinate := Vector2i(
			floori(canvas_position.x / ENEMY_BUCKET_SIZE_PX),
			floori(canvas_position.y / ENEMY_BUCKET_SIZE_PX)
		)
		bucket_data[bucket_coordinate] = int(bucket_data.get(bucket_coordinate, 0)) + 1

	var buckets: Array[Dictionary] = []
	for bucket_coordinate in bucket_data:
		var enemy_count: int = bucket_data[bucket_coordinate]
		buckets.append(
			{
				"bucket_coordinate": bucket_coordinate,
				"canvas_position": (
					Vector2(bucket_coordinate) + Vector2.ONE * 0.5
				) * ENEMY_BUCKET_SIZE_PX,
				"count": enemy_count,
			}
		)
	return buckets


func get_enemy_marker_radius(enemy_count: int) -> float:
	if enemy_count >= ENEMY_HIGH_DENSITY:
		return ENEMY_HIGH_RADIUS
	if enemy_count >= ENEMY_MEDIUM_DENSITY:
		return ENEMY_MEDIUM_RADIUS
	return ENEMY_SINGLE_RADIUS


func _projected_tile_size() -> Vector2:
	var projection_scale := _get_projection_scale()
	return Vector2(
		maxf(tile_world_size.x * projection_scale, 2.0),
		maxf(tile_world_size.y * projection_scale, 2.0)
	)


func _world_to_canvas(world_position: Vector2) -> Vector2:
	var safe_world_size := Vector2(
		maxf(overview_world_size.x, 0.001),
		maxf(overview_world_size.y, 0.001)
	)
	var projection_scale := _get_projection_scale()
	var projected_world_size := safe_world_size * projection_scale
	var projection_origin := (size - projected_world_size) * 0.5
	var world_top_left := world_center - safe_world_size * 0.5
	return projection_origin + (world_position - world_top_left) * projection_scale


func _get_projection_scale() -> float:
	return minf(
		size.x / maxf(overview_world_size.x, 0.001),
		size.y / maxf(overview_world_size.y, 0.001)
	)
