extends Node2D
class_name DualGridPaintDemo

const MAP_COLUMNS := 40
const MAP_ROWS := 24
const REFERENCE_TILE_SIZE := 32.0
const REFERENCE_CAMERA_SPEED := 680.0
const REFERENCE_MIN_ZOOM := 0.7
const REFERENCE_MAX_ZOOM := 2.6
const REFERENCE_INITIAL_ZOOM := 1.05
const PLACEHOLDER_SOURCE_ID := 0
const TERRAIN_GRASS := 1
const TERRAIN_DIRT := 2
const TERRAIN_WATER := 3
const TERRAIN_METAL := 4
const TERRAIN_EMPTY := -1

var is_painting := false
var paint_terrain := TERRAIN_GRASS
var active_tile_size := 16.0
var camera_speed := REFERENCE_CAMERA_SPEED * 0.5
var min_zoom := REFERENCE_MIN_ZOOM * 2.0
var max_zoom := REFERENCE_MAX_ZOOM * 2.0

@onready var dual_grid_tilemap: DualGridTilemap = %TileMapLayers
@onready var camera: Camera2D = %Camera2D
@onready var mode_label: Label = %ModeLabel


func _ready() -> void:
	texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	active_tile_size = float(dual_grid_tilemap.world_map_layer.tile_set.tile_size.x)
	var zoom_scale := REFERENCE_TILE_SIZE / active_tile_size
	camera_speed = REFERENCE_CAMERA_SPEED / zoom_scale
	min_zoom = REFERENCE_MIN_ZOOM * zoom_scale
	max_zoom = REFERENCE_MAX_ZOOM * zoom_scale
	camera.zoom = Vector2.ONE * REFERENCE_INITIAL_ZOOM * zoom_scale
	_build_starting_map()
	camera.global_position = Vector2(MAP_COLUMNS, MAP_ROWS) * active_tile_size * 0.5
	_update_label()


func _process(delta: float) -> void:
	_update_camera(delta)
	if is_painting:
		_paint_at_mouse()


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		_handle_mouse_button(event)
	elif event is InputEventMouseMotion and is_painting:
		_paint_at_mouse()
		get_viewport().set_input_as_handled()
	elif event is InputEventKey and event.pressed and not event.echo:
		_handle_key(event)


func _handle_mouse_button(event: InputEventMouseButton) -> void:
	if event.button_index == MOUSE_BUTTON_WHEEL_UP and event.pressed:
		_zoom_camera(1.12)
		get_viewport().set_input_as_handled()
		return
	if event.button_index == MOUSE_BUTTON_WHEEL_DOWN and event.pressed:
		_zoom_camera(1.0 / 1.12)
		get_viewport().set_input_as_handled()
		return

	match event.button_index:
		MOUSE_BUTTON_LEFT:
			pass
		MOUSE_BUTTON_RIGHT:
			paint_terrain = TERRAIN_DIRT
		MOUSE_BUTTON_MIDDLE:
			paint_terrain = TERRAIN_EMPTY
		_:
			return

	is_painting = event.pressed
	if event.pressed:
		_paint_at_mouse()
	get_viewport().set_input_as_handled()


func _handle_key(event: InputEventKey) -> void:
	match event.physical_keycode:
		KEY_1:
			paint_terrain = TERRAIN_GRASS
		KEY_2:
			paint_terrain = TERRAIN_DIRT
		KEY_3:
			paint_terrain = TERRAIN_WATER
		KEY_4:
			paint_terrain = TERRAIN_EMPTY
		KEY_5:
			paint_terrain = TERRAIN_METAL
		KEY_C:
			_build_starting_map()
		_:
			return
	_update_label()
	get_viewport().set_input_as_handled()


func _build_starting_map() -> void:
	dual_grid_tilemap.clear_tiles()
	for y in range(MAP_ROWS):
		for x in range(MAP_COLUMNS):
			var terrain := TERRAIN_GRASS
			var path_cross: bool = abs(y - 12) <= 2 or abs(x - 20) <= 2
			var lower_field: bool = x > 23 and y > 14
			var left_patch: bool = (x - 11) * (x - 11) + (y - 9) * (y - 9) < 42
			var corner_patch: bool = (x - 35) * (x - 35) + (y - 5) * (y - 5) < 28
			var pond: bool = (x - 31) * (x - 31) + (y - 7) * (y - 7) < 24
			var stream: bool = x > 26 and x < 35 and abs(y - 17) <= 1
			var metal_deck: bool = x >= 4 and x <= 9 and y >= 16 and y <= 20
			if pond or stream:
				terrain = TERRAIN_WATER
			elif metal_deck:
				terrain = TERRAIN_METAL
			elif path_cross or lower_field or left_patch or corner_patch:
				terrain = TERRAIN_DIRT
			dual_grid_tilemap.world_map_layer.set_cell(
				Vector2i(x, y),
				PLACEHOLDER_SOURCE_ID,
				_get_placeholder_atlas_coords(terrain)
			)
	dual_grid_tilemap.refresh_all_tiles()
	_update_label()


func _paint_at_mouse() -> void:
	var cell := dual_grid_tilemap.world_to_map(get_global_mouse_position())
	if cell.x < 0 or cell.y < 0 or cell.x >= MAP_COLUMNS or cell.y >= MAP_ROWS:
		return
	dual_grid_tilemap.set_tile(cell, paint_terrain)
	_update_label()


func _update_camera(delta: float) -> void:
	var direction := Vector2.ZERO
	if Input.is_physical_key_pressed(KEY_A) or Input.is_physical_key_pressed(KEY_LEFT):
		direction.x -= 1.0
	if Input.is_physical_key_pressed(KEY_D) or Input.is_physical_key_pressed(KEY_RIGHT):
		direction.x += 1.0
	if Input.is_physical_key_pressed(KEY_W) or Input.is_physical_key_pressed(KEY_UP):
		direction.y -= 1.0
	if Input.is_physical_key_pressed(KEY_S) or Input.is_physical_key_pressed(KEY_DOWN):
		direction.y += 1.0
	if direction != Vector2.ZERO:
		camera.global_position += direction.normalized() * camera_speed * delta / maxf(camera.zoom.x, 0.1)
	_clamp_camera()


func _zoom_camera(factor: float) -> void:
	var next_zoom := clampf(camera.zoom.x * factor, min_zoom, max_zoom)
	camera.zoom = Vector2.ONE * next_zoom
	_clamp_camera()


func _clamp_camera() -> void:
	var map_size := Vector2(MAP_COLUMNS, MAP_ROWS) * active_tile_size
	var viewport_half := get_viewport_rect().size * 0.5 / camera.zoom.x
	camera.global_position.x = clampf(camera.global_position.x, viewport_half.x, maxf(viewport_half.x, map_size.x - viewport_half.x))
	camera.global_position.y = clampf(camera.global_position.y, viewport_half.y, maxf(viewport_half.y, map_size.y - viewport_half.y))


func _update_label() -> void:
	if mode_label == null:
		return

	var cell := dual_grid_tilemap.world_to_map(get_global_mouse_position())
	var brush := "empty"
	if paint_terrain == TERRAIN_GRASS:
		brush = "grass"
	elif paint_terrain == TERRAIN_DIRT:
		brush = "dirt"
	elif paint_terrain == TERRAIN_WATER:
		brush = "water"
	elif paint_terrain == TERRAIN_METAL:
		brush = "metal"
	mode_label.text = "Dual grid paint test | LMB paint | RMB dirt | MMB erase | 1 grass | 2 dirt | 3 water | 4 erase | 5 metal | C reset | Brush: %s | Cell: %s" % [brush, str(cell)]


func _get_placeholder_atlas_coords(terrain: int) -> Vector2i:
	match terrain:
		TERRAIN_GRASS:
			return dual_grid_tilemap.grass_placeholder_atlas_coords
		TERRAIN_DIRT:
			return dual_grid_tilemap.dirt_placeholder_atlas_coords
		TERRAIN_WATER:
			return dual_grid_tilemap.water_placeholder_atlas_coords
		TERRAIN_METAL:
			return dual_grid_tilemap.metal_placeholder_atlas_coords
		_:
			return Vector2i(-1, -1)
