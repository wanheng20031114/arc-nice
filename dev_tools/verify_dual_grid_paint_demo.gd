extends SceneTree

const DEMO_SCENE_PATH := "res://scene/game_modes/tower_defense/test_arenas/terrain/dual_grid_paint_demo.tscn"
const TILESET_PATH := "res://resources/terrain/dual_grid/terrain_dual_grid_tileset_16.tres"
const TILESET_32_PATH := "res://resources/terrain/dual_grid/terrain_dual_grid_tileset_32.tres"
const GRASS_TILES_PATH := "res://resources/terrain/dual_grid/meadow_grass_dual_grid_atlas_16.png"
const GRASS_TILES_32_PATH := "res://resources/terrain/dual_grid/meadow_grass_dual_grid_atlas_32.png"
const DIRT_TILES_PATH := "res://resources/terrain/dual_grid/tilled_soil_dual_grid_atlas_16.png"
const DIRT_TILES_32_PATH := "res://resources/terrain/dual_grid/tilled_soil_dual_grid_atlas_32.png"
const WATER_TILES_PATH := "res://resources/terrain/dual_grid/sky_blue_water_dual_grid_animation_16.png"
const WATER_TILES_32_PATH := "res://resources/terrain/dual_grid/sky_blue_water_dual_grid_animation_32.png"
const METAL_TILES_PATH := "res://resources/terrain/dual_grid/gray_metal_floor_dual_grid_atlas_16.png"
const METAL_TILES_32_PATH := "res://resources/terrain/dual_grid/gray_metal_floor_dual_grid_atlas_32.png"
const METAL_REFERENCE_PATH := "res://resources/terrain/dual_grid/gray_metal_floor_reference_tile_32.png"
const FLOWER_DETAILS_PATH := "res://resources/terrain/dual_grid/grass_flower_details_16.png"
const FLOWER_DETAILS_32_PATH := "res://resources/terrain/dual_grid/grass_flower_details_32.png"
const CLAY_DETAILS_PATH := "res://resources/terrain/dual_grid/dirt_clay_details_16.png"
const CLAY_DETAILS_32_PATH := "res://resources/terrain/dual_grid/dirt_clay_details_32.png"
const PLACEHOLDER_PATH := "res://resources/terrain/dual_grid/terrain_dual_grid_placeholders_16.png"
const PLACEHOLDER_32_PATH := "res://resources/terrain/dual_grid/terrain_dual_grid_placeholders_32.png"
const MAP_COLUMNS := 40
const MAP_ROWS := 24
const DIRT_SOURCE_ID := 2
const WATER_SOURCE_ID := 3
const METAL_SOURCE_ID := 4
const FLOWER_SOURCE_ID := 5
const CLAY_SOURCE_ID := 6
const DETAIL_VARIANT_COUNT := 6
const DETAIL_TEST_GRID_SIZE := 64
const FULL_DIRT_ATLAS_COORDS := Vector2i(2, 1)
const WATER_ANIMATION_FRAMES := 16
const WATER_ANIMATION_FRAMES_32 := 8
const WATER_ANIMATION_SPEED := 4.0
const WATER_MASK_ROWS := 15
const COMMON_MASK_ATLAS_COORDS := [
	Vector2i(0, 0),
	Vector2i(1, 0),
	Vector2i(2, 0),
	Vector2i(3, 0),
	Vector2i(0, 1),
	Vector2i(1, 1),
	Vector2i(2, 1),
	Vector2i(3, 1),
	Vector2i(0, 2),
	Vector2i(1, 2),
	Vector2i(2, 2),
	Vector2i(3, 2),
	Vector2i(1, 3),
	Vector2i(2, 3),
	Vector2i(3, 3),
]

var errors: Array[String] = []


func _init() -> void:
	print("Starting dual-grid paint demo verification.")
	call_deferred("_run")


func _run() -> void:
	_verify_image_size(GRASS_TILES_PATH, Vector2i(64, 64))
	_verify_image_size(GRASS_TILES_32_PATH, Vector2i(128, 128))
	_verify_image_size(DIRT_TILES_PATH, Vector2i(64, 64))
	_verify_image_size(DIRT_TILES_32_PATH, Vector2i(128, 128))
	_verify_image_size(WATER_TILES_PATH, Vector2i(256, 240))
	_verify_image_size(WATER_TILES_32_PATH, Vector2i(512, 480))
	_verify_image_size(METAL_TILES_PATH, Vector2i(64, 64))
	_verify_image_size(METAL_TILES_32_PATH, Vector2i(128, 128))
	_verify_image_size(METAL_REFERENCE_PATH, Vector2i(32, 32))
	_verify_image_size(FLOWER_DETAILS_PATH, Vector2i(96, 16))
	_verify_image_size(FLOWER_DETAILS_32_PATH, Vector2i(192, 32))
	_verify_image_size(CLAY_DETAILS_PATH, Vector2i(96, 16))
	_verify_image_size(CLAY_DETAILS_32_PATH, Vector2i(192, 32))
	_verify_image_size(PLACEHOLDER_PATH, Vector2i(64, 16))
	_verify_image_size(PLACEHOLDER_32_PATH, Vector2i(128, 32))
	_verify_metal_reference_has_no_outer_seam()
	_verify_placeholder_metal_color(PLACEHOLDER_PATH, 16)
	_verify_placeholder_metal_color(PLACEHOLDER_32_PATH, 32)
	_verify_tileset_placeholders(TILESET_PATH)
	_verify_tileset_placeholders(TILESET_32_PATH)
	_verify_tileset_water_animation(TILESET_PATH, WATER_ANIMATION_FRAMES)
	_verify_tileset_water_animation(TILESET_32_PATH, WATER_ANIMATION_FRAMES_32)
	_verify_tileset_metal(TILESET_PATH)
	_verify_tileset_metal(TILESET_32_PATH)
	_verify_detail_image(FLOWER_DETAILS_PATH, 16)
	_verify_detail_image(FLOWER_DETAILS_32_PATH, 32)
	_verify_detail_image(CLAY_DETAILS_PATH, 16)
	_verify_detail_image(CLAY_DETAILS_32_PATH, 32)
	_verify_tileset_details(TILESET_PATH)
	_verify_tileset_details(TILESET_32_PATH)

	var scene := load(DEMO_SCENE_PATH) as PackedScene
	if scene == null:
		_fail("Dual-grid paint demo scene could not be loaded.")
		return

	var demo := scene.instantiate()
	root.add_child(demo)
	await process_frame
	await process_frame
	_verify_demo_camera(demo)

	var tilemap := demo.get_node("%TileMapLayers")
	if tilemap == null:
		errors.append("TileMapLayers unique node is missing.")
	else:
		_verify_demo_uses_16_pixel_tiles(tilemap)
		_verify_coordinate_conversion(tilemap)
		if not tilemap.world_map_layer.visible:
			errors.append("WorldLayer must stay visible so Godot's TileMap editor can edit it.")
		_verify_starting_details(tilemap)
		_verify_starting_metal_region(tilemap)
		_verify_base_dirt_layer(tilemap)
		_verify_single_cell_rules(tilemap)
		_verify_terrain_switch(tilemap)
		_verify_water_switch(tilemap)
		_verify_metal_switch(tilemap)
		_verify_erase(tilemap)
		_verify_detail_distribution(tilemap)

	demo.queue_free()
	await process_frame

	if errors.is_empty():
		print("Verified dual-grid paint demo.")
		quit(0)
	else:
		for error in errors:
			push_error(error)
		quit(1)


func _verify_demo_uses_16_pixel_tiles(tilemap) -> void:
	if tilemap.world_map_layer.tile_set.tile_size != Vector2i(16, 16):
		errors.append("Paint demo must use the 16x16 TileSet by default.")
	for layer: TileMapLayer in [
		tilemap.base_dirt_map_layer,
		tilemap.grass_display_map_layer,
		tilemap.dirt_display_map_layer,
		tilemap.water_display_map_layer,
		tilemap.metal_display_map_layer,
		tilemap.terrain_detail_map_layer,
	]:
		if layer.position != Vector2(-8, -8):
			errors.append("16x16 dual-grid display layers must use a (-8, -8) offset.")


func _verify_demo_camera(demo: Node) -> void:
	var camera := demo.get_node("%Camera2D") as Camera2D
	if camera.global_position != Vector2(320, 192):
		errors.append("16x16 paint demo camera must center on the 40x24 map.")
	if not camera.zoom.is_equal_approx(Vector2(2.1, 2.1)):
		errors.append("16x16 paint demo camera must preserve the reference visual scale.")


func _verify_coordinate_conversion(tilemap) -> void:
	var expected_cell := Vector2i(5, 7)
	var world_position: Vector2 = tilemap.world_map_layer.to_global(
		tilemap.world_map_layer.map_to_local(expected_cell)
	)
	if tilemap.world_to_map(world_position) != expected_cell:
		errors.append("16x16 world-to-map coordinate conversion is incorrect.")


func _verify_tileset_placeholders(path: String) -> void:
	var tile_set := load(path) as TileSet
	if tile_set == null:
		errors.append("Terrain TileSet could not be loaded: %s" % path)
		return

	var placeholder_source := tile_set.get_source(0) as TileSetAtlasSource
	if placeholder_source == null:
		errors.append("Terrain TileSet source 0 should be the placeholder atlas source.")
		return

	for coords in [Vector2i(0, 0), Vector2i(1, 0), Vector2i(2, 0), Vector2i(3, 0)]:
		if not placeholder_source.has_tile(coords):
			errors.append("Placeholder atlas source should contain editor base tile %s: %s" % [str(coords), path])


func _verify_tileset_water_animation(path: String, expected_frames: int) -> void:
	var tile_set := load(path) as TileSet
	if tile_set == null:
		errors.append("Terrain TileSet could not be loaded: %s" % path)
		return

	var water_source := tile_set.get_source(WATER_SOURCE_ID) as TileSetAtlasSource
	if water_source == null:
		errors.append("Terrain TileSet source 3 should be the animated water atlas: %s" % path)
		return

	for row in range(WATER_MASK_ROWS):
		var coords := Vector2i(0, row)
		if not water_source.has_tile(coords):
			errors.append("Animated water atlas is missing tile %s: %s" % [str(coords), path])
			continue
		if water_source.get_tile_animation_frames_count(coords) != expected_frames:
			errors.append("Animated water tile %s should have %s frames: %s" % [str(coords), expected_frames, path])
		if not is_equal_approx(water_source.get_tile_animation_speed(coords), WATER_ANIMATION_SPEED):
			errors.append("Animated water tile %s should play at %s fps: %s" % [str(coords), WATER_ANIMATION_SPEED, path])


func _verify_tileset_metal(path: String) -> void:
	var tile_set := load(path) as TileSet
	if tile_set == null:
		errors.append("Terrain TileSet could not be loaded: %s" % path)
		return

	var metal_source := tile_set.get_source(METAL_SOURCE_ID) as TileSetAtlasSource
	if metal_source == null:
		errors.append("Terrain TileSet source 4 should be the metal atlas: %s" % path)
		return

	for coords in COMMON_MASK_ATLAS_COORDS:
		if not metal_source.has_tile(coords):
			errors.append("Metal atlas is missing tile %s: %s" % [str(coords), path])


func _verify_tileset_details(path: String) -> void:
	var tile_set := load(path) as TileSet
	if tile_set == null:
		return
	for source_id in [FLOWER_SOURCE_ID, CLAY_SOURCE_ID]:
		var detail_source := tile_set.get_source(source_id) as TileSetAtlasSource
		if detail_source == null:
			errors.append("Terrain detail source %s is missing: %s" % [source_id, path])
			continue
		for variant in range(DETAIL_VARIANT_COUNT):
			var coords := Vector2i(variant, 0)
			if not detail_source.has_tile(coords):
				errors.append("Terrain detail source %s is missing variant %s: %s" % [source_id, variant, path])


func _verify_image_size(path: String, expected_size: Vector2i) -> void:
	var image := Image.load_from_file(ProjectSettings.globalize_path(path))
	if image == null or image.is_empty():
		errors.append("Image is missing or empty: %s" % path)
		return
	if image.get_size() != expected_size:
		errors.append("%s should be %s, got %s." % [path, str(expected_size), str(image.get_size())])


func _verify_detail_image(path: String, tile_size: int) -> void:
	var image := Image.load_from_file(ProjectSettings.globalize_path(path))
	if image == null or image.is_empty():
		return
	for variant in range(DETAIL_VARIANT_COUNT):
		var occupied_pixels := 0
		for y in range(tile_size):
			for x in range(variant * tile_size, (variant + 1) * tile_size):
				var alpha := image.get_pixel(x, y).a8
				if alpha != 0 and alpha != 255:
					errors.append("Terrain detail alpha must be binary: %s" % path)
					return
				if alpha == 255:
					occupied_pixels += 1
		if occupied_pixels == 0:
			errors.append("Terrain detail variant %s should not be empty: %s" % [variant, path])


func _verify_metal_reference_has_no_outer_seam() -> void:
	var image := Image.load_from_file(ProjectSettings.globalize_path(METAL_REFERENCE_PATH))
	if image == null or image.is_empty():
		return

	var edge_colors := {}
	for index in range(image.get_width()):
		edge_colors[image.get_pixel(index, 0).to_rgba32()] = true
		edge_colors[image.get_pixel(index, image.get_height() - 1).to_rgba32()] = true
		edge_colors[image.get_pixel(0, index).to_rgba32()] = true
		edge_colors[image.get_pixel(image.get_width() - 1, index).to_rgba32()] = true
	if edge_colors.size() < 2:
		errors.append("Metal reference outer pixels should continue the surface texture instead of forming a solid seam.")


func _verify_placeholder_metal_color(path: String, tile_size: int) -> void:
	var image := Image.load_from_file(ProjectSettings.globalize_path(path))
	if image == null or image.is_empty():
		return

	var half_size := floori(tile_size * 0.5)
	var sample := image.get_pixel(tile_size * 3 + half_size, half_size)
	var expected := Color(120.0 / 255.0, 120.0 / 255.0, 120.0 / 255.0, 1.0)
	if sample != expected:
		errors.append("The fourth placeholder tile should use the metal surface gray: %s" % path)


func _verify_base_dirt_layer(tilemap) -> void:
	if tilemap.base_dirt_map_layer == null:
		errors.append("BaseDirtLayer should be assigned as the bottom dirt fallback layer.")
		return

	if tilemap.world_map_layer.z_index >= tilemap.base_dirt_map_layer.z_index:
		errors.append("WorldLayer should render below BaseDirtLayer so editor placeholders do not cover the dirt fallback.")
	if tilemap.base_dirt_map_layer.z_index >= tilemap.grass_display_map_layer.z_index:
		errors.append("BaseDirtLayer should render below terrain display layers.")
	if tilemap.base_dirt_map_layer.position != tilemap.grass_display_map_layer.position:
		errors.append("BaseDirtLayer should use the same half-tile offset as display layers.")

	var expected_cells := (MAP_COLUMNS + 1) * (MAP_ROWS + 1)
	if tilemap.base_dirt_map_layer.get_used_cells().size() != expected_cells:
		errors.append("BaseDirtLayer should fill %s full dirt cells." % expected_cells)

	for coords in [Vector2i(0, 0), Vector2i(MAP_COLUMNS, MAP_ROWS)]:
		if tilemap.base_dirt_map_layer.get_cell_source_id(coords) != DIRT_SOURCE_ID:
			errors.append("BaseDirtLayer cell %s should use dirt source id %s." % [str(coords), DIRT_SOURCE_ID])
		if tilemap.base_dirt_map_layer.get_cell_atlas_coords(coords) != FULL_DIRT_ATLAS_COORDS:
			errors.append("BaseDirtLayer cell %s should use full dirt atlas %s." % [str(coords), str(FULL_DIRT_ATLAS_COORDS)])


func _verify_starting_metal_region(tilemap) -> void:
	if tilemap.metal_display_map_layer == null:
		errors.append("MetalDisplayLayer should be assigned.")
		return
	if tilemap.metal_display_map_layer.z_index <= tilemap.water_display_map_layer.z_index:
		errors.append("MetalDisplayLayer should render above the other terrain display layers.")
	if tilemap.metal_display_map_layer.position != tilemap.grass_display_map_layer.position:
		errors.append("MetalDisplayLayer should use the same half-tile offset as other display layers.")
	if tilemap.metal_display_map_layer.get_used_cells().is_empty():
		errors.append("The starting demo map should contain a visible metal region.")
	for coords in [Vector2i(4, 16), Vector2i(9, 20)]:
		if tilemap.world_map_layer.get_cell_atlas_coords(coords) != Vector2i(3, 0):
			errors.append("Starting metal cell %s should use placeholder atlas (3, 0)." % str(coords))


func _verify_starting_details(tilemap) -> void:
	if tilemap.terrain_detail_map_layer == null:
		errors.append("TerrainDetailLayer should be assigned.")
		return
	if tilemap.terrain_detail_map_layer.z_index <= tilemap.metal_display_map_layer.z_index:
		errors.append("TerrainDetailLayer should render above the terrain display layers.")
	if tilemap.terrain_detail_map_layer.position != tilemap.grass_display_map_layer.position:
		errors.append("TerrainDetailLayer should use the same half-tile offset as terrain layers.")
	if tilemap.terrain_detail_map_layer.get_used_cells().is_empty():
		errors.append("The starting demo map should contain terrain details.")
	for cell in tilemap.terrain_detail_map_layer.get_used_cells():
		var source_id: int = tilemap.terrain_detail_map_layer.get_cell_source_id(cell)
		var terrain_type := 1 if source_id == FLOWER_SOURCE_ID else 2
		if source_id != FLOWER_SOURCE_ID and source_id != CLAY_SOURCE_ID:
			errors.append("Unexpected terrain detail source %s at %s." % [source_id, str(cell)])
			continue
		if tilemap.call("_calculate_terrain_mask", cell, terrain_type) != 15:
			errors.append("Terrain detail at %s should only appear on a full terrain tile." % str(cell))


func _verify_single_cell_rules(tilemap) -> void:
	tilemap.call("clear_tiles")
	tilemap.call("set_tile", Vector2i(0, 0), 1)

	var expected := {
		Vector2i(0, 0): Vector2i(1, 3),
		Vector2i(1, 0): Vector2i(0, 0),
		Vector2i(0, 1): Vector2i(0, 2),
		Vector2i(1, 1): Vector2i(3, 3),
	}
	for cell in expected.keys():
		var atlas_coords: Vector2i = tilemap.grass_display_map_layer.get_cell_atlas_coords(cell)
		if atlas_coords != expected[cell]:
			errors.append("Grass display cell %s should use atlas %s, got %s." % [str(cell), str(expected[cell]), str(atlas_coords)])
	if not tilemap.terrain_detail_map_layer.get_used_cells().is_empty():
		errors.append("A single grass cell should not create a detail on partial dual-grid masks.")


func _verify_terrain_switch(tilemap) -> void:
	tilemap.call("set_tile", Vector2i(0, 0), 2)
	if tilemap.grass_display_map_layer.get_used_cells().size() != 0:
		errors.append("Grass display layer should clear after switching the only cell to dirt.")
	if tilemap.dirt_display_map_layer.get_used_cells().size() != 4:
		errors.append("One dirt cell should draw exactly four dirt display cells.")
	if tilemap.world_map_layer.get_cell_atlas_coords(Vector2i(0, 0)) != Vector2i(1, 0):
		errors.append("World placeholder should switch to the dirt atlas coordinate.")


func _verify_water_switch(tilemap) -> void:
	tilemap.call("set_tile", Vector2i(0, 0), 3)
	if tilemap.dirt_display_map_layer.get_used_cells().size() != 0:
		errors.append("Dirt display layer should clear after switching the only cell to water.")
	if tilemap.water_display_map_layer.get_used_cells().size() != 4:
		errors.append("One water cell should draw exactly four water display cells.")
	if tilemap.world_map_layer.get_cell_atlas_coords(Vector2i(0, 0)) != Vector2i(2, 0):
		errors.append("World placeholder should switch to the water atlas coordinate.")

	var expected := {
		Vector2i(0, 0): Vector2i(0, 1),
		Vector2i(1, 0): Vector2i(0, 2),
		Vector2i(0, 1): Vector2i(0, 3),
		Vector2i(1, 1): Vector2i(0, 4),
	}
	for cell in expected.keys():
		var atlas_coords: Vector2i = tilemap.water_display_map_layer.get_cell_atlas_coords(cell)
		if atlas_coords != expected[cell]:
			errors.append("Water display cell %s should use animated atlas %s, got %s." % [str(cell), str(expected[cell]), str(atlas_coords)])


func _verify_metal_switch(tilemap) -> void:
	tilemap.call("set_tile", Vector2i(0, 0), METAL_SOURCE_ID)
	if tilemap.water_display_map_layer.get_used_cells().size() != 0:
		errors.append("Water display layer should clear after switching the only cell to metal.")
	if tilemap.metal_display_map_layer.get_used_cells().size() != 4:
		errors.append("One metal cell should draw exactly four metal display cells.")
	if tilemap.world_map_layer.get_cell_atlas_coords(Vector2i(0, 0)) != Vector2i(3, 0):
		errors.append("World placeholder should switch to the metal atlas coordinate.")

	var expected := {
		Vector2i(0, 0): Vector2i(1, 3),
		Vector2i(1, 0): Vector2i(0, 0),
		Vector2i(0, 1): Vector2i(0, 2),
		Vector2i(1, 1): Vector2i(3, 3),
	}
	for cell in expected.keys():
		var atlas_coords: Vector2i = tilemap.metal_display_map_layer.get_cell_atlas_coords(cell)
		if atlas_coords != expected[cell]:
			errors.append("Metal display cell %s should use atlas %s, got %s." % [str(cell), str(expected[cell]), str(atlas_coords)])


func _verify_erase(tilemap) -> void:
	tilemap.call("set_tile", Vector2i(0, 0), -1)
	if tilemap.world_map_layer.get_cell_source_id(Vector2i(0, 0)) != -1:
		errors.append("World layer should erase the cell.")
	if tilemap.metal_display_map_layer.get_used_cells().size() != 0:
		errors.append("Metal display layer should clear after erasing the only cell.")
	if tilemap.terrain_detail_map_layer.get_used_cells().size() != 0:
		errors.append("Terrain detail layer should clear after erasing the only cell.")


func _verify_detail_distribution(tilemap) -> void:
	_verify_uniform_detail_distribution(tilemap, 1, FLOWER_SOURCE_ID, 0.08, 0.12)
	_verify_uniform_detail_distribution(tilemap, 2, CLAY_SOURCE_ID, 0.05, 0.09)


func _verify_uniform_detail_distribution(
	tilemap,
	terrain_type: int,
	expected_source_id: int,
	minimum_density: float,
	maximum_density: float
) -> void:
	tilemap.call("clear_tiles")
	var placeholder_coords: Vector2i = tilemap.call("_get_placeholder_atlas_coords", terrain_type)
	for y in range(DETAIL_TEST_GRID_SIZE):
		for x in range(DETAIL_TEST_GRID_SIZE):
			tilemap.world_map_layer.set_cell(Vector2i(x, y), 0, placeholder_coords)
	tilemap.call("refresh_all_tiles")

	var full_tile_count := (DETAIL_TEST_GRID_SIZE - 1) * (DETAIL_TEST_GRID_SIZE - 1)
	var detail_cells: Array[Vector2i] = tilemap.terrain_detail_map_layer.get_used_cells()
	var density := float(detail_cells.size()) / full_tile_count
	if density < minimum_density or density > maximum_density:
		errors.append("Terrain %s detail density should be between %.2f and %.2f, got %.3f." % [terrain_type, minimum_density, maximum_density, density])

	var variants := {}
	var snapshot := {}
	for cell in detail_cells:
		var source_id: int = tilemap.terrain_detail_map_layer.get_cell_source_id(cell)
		if source_id != expected_source_id:
			errors.append("Terrain %s detail cell %s used source %s." % [terrain_type, str(cell), source_id])
		if tilemap.call("_calculate_terrain_mask", cell, terrain_type) != 15:
			errors.append("Terrain %s detail cell %s is not on a full mask." % [terrain_type, str(cell)])
		var atlas_coords: Vector2i = tilemap.terrain_detail_map_layer.get_cell_atlas_coords(cell)
		variants[atlas_coords.x] = true
		snapshot[cell] = atlas_coords
		var has_adjacent_detail := false
		for y in range(-1, 2):
			for x in range(-1, 2):
				if x == 0 and y == 0:
					continue
				if tilemap.terrain_detail_map_layer.get_cell_source_id(cell + Vector2i(x, y)) != -1:
					has_adjacent_detail = true
		if has_adjacent_detail:
			errors.append("Terrain details should not occupy adjacent tiles: %s" % str(cell))
	if variants.size() != DETAIL_VARIANT_COUNT:
		errors.append("Terrain %s should use all %s detail variants, got %s." % [terrain_type, DETAIL_VARIANT_COUNT, variants.size()])

	tilemap.call("refresh_all_tiles")
	if tilemap.terrain_detail_map_layer.get_used_cells().size() != snapshot.size():
		errors.append("Terrain %s detail count changed after a deterministic refresh." % terrain_type)
	for cell in snapshot:
		if tilemap.terrain_detail_map_layer.get_cell_atlas_coords(cell) != snapshot[cell]:
			errors.append("Terrain %s detail variant changed after refresh at %s." % [terrain_type, str(cell)])


func _fail(message: String) -> void:
	push_error(message)
	quit(1)
