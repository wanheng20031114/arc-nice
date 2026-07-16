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
var _projection_scale := 1.0
var _projection_origin := Vector2.ZERO
var _world_top_left := Vector2.ZERO
var _cached_overview_rect := Rect2(Vector2.ZERO, Vector2.ONE)
var _enemy_bucket_column_count := 1
var _enemy_bucket_row_count := 1
var _enemy_canvas_bucket_counts := PackedInt32Array([0])
var _touched_enemy_bucket_indices := PackedInt32Array()


func _ready() -> void:
	_refresh_projection_cache()


func _notification(what: int) -> void:
	if what != NOTIFICATION_RESIZED:
		return
	_refresh_projection_cache()
	queue_redraw()


func set_tile_world_size(new_tile_world_size: Vector2) -> void:
	tile_world_size = new_tile_world_size


func set_projection(new_world_center: Vector2, new_overview_world_size: Vector2) -> void:
	world_center = new_world_center
	overview_world_size = new_overview_world_size
	_refresh_projection_cache()
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
	var plant_size := _projected_tile_size()
	for world_position in plant_world_positions:
		if not _cached_overview_rect.has_point(world_position):
			continue
		var center := _world_to_canvas(world_position)
		draw_rect(Rect2(center - plant_size * 0.5, plant_size), PLANT_COLOR)

	_draw_enemy_buckets(_cached_overview_rect)
	for world_position in remote_player_world_positions:
		_draw_player_dot_if_visible(
			world_position,
			REMOTE_PLAYER_RADIUS,
			REMOTE_PLAYER_COLOR,
			_cached_overview_rect
		)
	_draw_player_dot_if_visible(
		local_player_world_position,
		LOCAL_PLAYER_RADIUS,
		LOCAL_PLAYER_COLOR,
		_cached_overview_rect
	)
	if _cached_overview_rect.has_point(local_player_world_position):
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
	_rebuild_enemy_canvas_bucket_counts(overview_rect)
	for bucket_index in _touched_enemy_bucket_indices:
		var enemy_count := _enemy_canvas_bucket_counts[bucket_index]
		var bucket_coordinate := _get_enemy_bucket_coordinate(bucket_index)
		var canvas_position := _get_enemy_bucket_canvas_position(bucket_coordinate)
		draw_circle(
			canvas_position,
			get_enemy_marker_radius(enemy_count),
			ENEMY_COLOR
		)


func _build_enemy_canvas_buckets(overview_rect: Rect2) -> Array[Dictionary]:
	# Diagnostic representation used by focused tests. Runtime drawing consumes
	# the reusable count table directly and does not allocate one Dictionary per
	# visible density marker.
	_rebuild_enemy_canvas_bucket_counts(overview_rect)
	var buckets: Array[Dictionary] = []
	for bucket_index in _touched_enemy_bucket_indices:
		var bucket_coordinate := _get_enemy_bucket_coordinate(bucket_index)
		buckets.append(
			{
				"bucket_coordinate": bucket_coordinate,
				"canvas_position": _get_enemy_bucket_canvas_position(
					bucket_coordinate
				),
				"count": _enemy_canvas_bucket_counts[bucket_index],
			}
		)
	return buckets


func _rebuild_enemy_canvas_bucket_counts(overview_rect: Rect2) -> void:
	_clear_touched_enemy_bucket_counts()
	for world_position in enemy_world_positions:
		if not overview_rect.has_point(world_position):
			continue
		var canvas_position := _world_to_canvas(world_position)
		var bucket_x := floori(canvas_position.x / ENEMY_BUCKET_SIZE_PX)
		var bucket_y := floori(canvas_position.y / ENEMY_BUCKET_SIZE_PX)
		if (
			bucket_x < 0
			or bucket_x >= _enemy_bucket_column_count
			or bucket_y < 0
			or bucket_y >= _enemy_bucket_row_count
		):
			continue
		var bucket_index := bucket_y * _enemy_bucket_column_count + bucket_x
		if _enemy_canvas_bucket_counts[bucket_index] == 0:
			_touched_enemy_bucket_indices.append(bucket_index)
		_enemy_canvas_bucket_counts[bucket_index] += 1


func _clear_touched_enemy_bucket_counts() -> void:
	for bucket_index in _touched_enemy_bucket_indices:
		_enemy_canvas_bucket_counts[bucket_index] = 0
	_touched_enemy_bucket_indices.clear()


func _get_enemy_bucket_coordinate(bucket_index: int) -> Vector2i:
	return Vector2i(
		bucket_index % _enemy_bucket_column_count,
		floori(float(bucket_index) / float(_enemy_bucket_column_count))
	)


func _get_enemy_bucket_canvas_position(bucket_coordinate: Vector2i) -> Vector2:
	return (
		Vector2(bucket_coordinate) + Vector2.ONE * 0.5
	) * ENEMY_BUCKET_SIZE_PX


func get_enemy_marker_radius(enemy_count: int) -> float:
	if enemy_count >= ENEMY_HIGH_DENSITY:
		return ENEMY_HIGH_RADIUS
	if enemy_count >= ENEMY_MEDIUM_DENSITY:
		return ENEMY_MEDIUM_RADIUS
	return ENEMY_SINGLE_RADIUS


func _projected_tile_size() -> Vector2:
	return Vector2(
		maxf(tile_world_size.x * _projection_scale, 2.0),
		maxf(tile_world_size.y * _projection_scale, 2.0)
	)


func _world_to_canvas(world_position: Vector2) -> Vector2:
	return _projection_origin + (world_position - _world_top_left) * _projection_scale


func _get_projection_scale() -> float:
	return _projection_scale


func _refresh_projection_cache() -> void:
	var safe_world_size := Vector2(
		maxf(overview_world_size.x, 0.001),
		maxf(overview_world_size.y, 0.001)
	)
	_projection_scale = minf(
		size.x / maxf(overview_world_size.x, 0.001),
		size.y / maxf(overview_world_size.y, 0.001)
	)
	var projected_world_size := safe_world_size * _projection_scale
	_projection_origin = (size - projected_world_size) * 0.5
	_world_top_left = world_center - safe_world_size * 0.5
	_cached_overview_rect = Rect2(_world_top_left, safe_world_size)
	_resize_enemy_bucket_storage_if_needed()


func _resize_enemy_bucket_storage_if_needed() -> void:
	var required_column_count := maxi(
		ceili(maxf(size.x, 1.0) / ENEMY_BUCKET_SIZE_PX),
		1
	)
	var required_row_count := maxi(
		ceili(maxf(size.y, 1.0) / ENEMY_BUCKET_SIZE_PX),
		1
	)
	if (
		required_column_count == _enemy_bucket_column_count
		and required_row_count == _enemy_bucket_row_count
	):
		return
	_enemy_bucket_column_count = required_column_count
	_enemy_bucket_row_count = required_row_count
	_touched_enemy_bucket_indices.clear()
	_enemy_canvas_bucket_counts.resize(
		_enemy_bucket_column_count * _enemy_bucket_row_count
	)
	_enemy_canvas_bucket_counts.fill(0)
