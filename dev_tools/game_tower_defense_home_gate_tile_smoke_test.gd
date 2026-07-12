extends SceneTree

const TOWER_SCENE := preload("res://scene/game_tower_defense.tscn")
const ATLAS_PATH := "res://resources/texture/动态瓦片.png"
const RED_GATE_COORDS := Vector2i(0, 0)
const HOME_GATE_COORDS := Vector2i(0, 3)
const FRAME_SIZE := Vector2i(16, 32)
const FRAME_COUNT := 4
const BASE_ALPHA_SEQUENCE := [108, 170, 227, 170]
const CORNER_ALPHA_SEQUENCE := [170, 227, 252, 227]
const BLUE_GATE_RGB := Vector3i(1, 135, 254)

var failures: Array[String] = []


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	var game := TOWER_SCENE.instantiate() as GameTowerDefense
	_expect(game != null, "Tower-defense scene must instantiate for home-gate verification.")
	if game == null:
		_finish()
		return
	game.auto_start_waves = false
	_expect(not game.linglan_boss_enabled, "Tower-defense Linglan must be disabled by default.")
	root.add_child(game)
	current_scene = game
	await process_frame
	await process_frame

	_verify_atlas_pixels()
	_verify_overlay_tileset(game.overlay_tile_map_layer)

	game.queue_free()
	await process_frame
	await process_frame
	_finish()


func _verify_atlas_pixels() -> void:
	var image := Image.load_from_file(ProjectSettings.globalize_path(ATLAS_PATH))
	_expect(image != null and not image.is_empty(), "Dynamic tile atlas must load.")
	if image == null or image.is_empty():
		return
	_expect(image.get_size() == Vector2i(64, 128), "Dynamic tile atlas must be 64x128 after appending the home gate.")

	for frame_index in range(FRAME_COUNT):
		var expected_visible_pixels := _get_expected_door_frame_pixels()
		var visible_pixels := {}
		var frame_origin := Vector2i(frame_index * FRAME_SIZE.x, 96)
		for y in range(FRAME_SIZE.y):
			for x in range(FRAME_SIZE.x):
				var color := image.get_pixelv(frame_origin + Vector2i(x, y))
				if color.a <= 0.0:
					continue
				visible_pixels[Vector2i(x, y)] = true
				var color_8 := Vector3i(
					roundi(color.r * 255.0),
					roundi(color.g * 255.0),
					roundi(color.b * 255.0)
				)
				_expect(color_8 == BLUE_GATE_RGB, "Home-gate visible pixels must use the authored electric-blue palette.")

		_expect(visible_pixels.size() == 86, "Each home-gate frame must contain its frame and center exclamation pixels.")
		_expect(visible_pixels == expected_visible_pixels, "Home gate must preserve the frame and blue exclamation while removing the outer warning decoration.")
		for pixel in visible_pixels:
			var alpha_8 := roundi(image.get_pixelv(frame_origin + pixel).a * 255.0)
			var expected_alpha: int = int(BASE_ALPHA_SEQUENCE[frame_index])
			if pixel == Vector2i(0, 22) or pixel == Vector2i(15, 22):
				expected_alpha = CORNER_ALPHA_SEQUENCE[frame_index]
			_expect(alpha_8 == expected_alpha, "Home gate must retain the red gate's four-frame alpha pulse.")


func _verify_overlay_tileset(overlay_layer: TileMapLayer) -> void:
	_expect(overlay_layer != null and overlay_layer.tile_set != null, "OverlayTileMapLayer must expose its TileSet.")
	if overlay_layer == null or overlay_layer.tile_set == null:
		return
	var tile_set := overlay_layer.tile_set
	_expect(tile_set.get_custom_data_layer_by_name("overlay_role") >= 0, "Overlay TileSet must define overlay_role custom data.")
	_expect(tile_set.get_physics_layers_count() == 0, "Home gate must remain a visual/semantic tile without collision.")
	var source := tile_set.get_source(0) as TileSetAtlasSource
	_expect(source != null, "Overlay TileSet must retain atlas source 0.")
	if source == null:
		return
	for coords in [RED_GATE_COORDS, HOME_GATE_COORDS]:
		_expect(source.has_tile(coords), "Overlay atlas must contain gate tile %s." % coords)
		_expect(source.get_tile_animation_frames_count(coords) == FRAME_COUNT, "Gate tile %s must have four frames." % coords)
		_expect(is_equal_approx(source.get_tile_animation_speed(coords), 4.0), "Gate tile %s must animate at the red gate's speed." % coords)
		for frame_index in range(FRAME_COUNT):
			_expect(
				is_equal_approx(source.get_tile_animation_frame_duration(coords, frame_index), 1.0),
				"Gate tile %s frame %d must retain unit duration." % [coords, frame_index]
			)
	var home_tile_data := source.get_tile_data(HOME_GATE_COORDS, 0)
	_expect(home_tile_data != null, "Home-gate TileData must exist.")
	if home_tile_data != null:
		_expect(
			home_tile_data.get_custom_data("overlay_role") == &"home_gate",
			"Blue gate must be semantically tagged as home_gate."
		)
	for frame_index in range(FRAME_COUNT):
		_expect(
			source.get_tile_texture_region(HOME_GATE_COORDS, frame_index)
			== Rect2i(frame_index * FRAME_SIZE.x, 96, FRAME_SIZE.x, FRAME_SIZE.y),
			"Home-gate animation frame %d must read the appended atlas strip." % frame_index
		)


func _get_expected_door_frame_pixels() -> Dictionary:
	var pixels := {}
	for x in range(FRAME_SIZE.x):
		pixels[Vector2i(x, 9)] = true
		pixels[Vector2i(x, 22)] = true
	for y in range(10, FRAME_SIZE.y):
		pixels[Vector2i(0, y)] = true
		pixels[Vector2i(15, y)] = true
	for y in [12, 13, 14, 15, 17, 18]:
		pixels[Vector2i(7, y)] = true
		pixels[Vector2i(8, y)] = true
	return pixels


func _finish() -> void:
	if failures.is_empty():
		print("GAME_TOWER_DEFENSE_HOME_GATE_TILE_SMOKE_TEST_OK")
		quit()
		return
	for failure in failures:
		push_error(failure)
	quit(1)


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
