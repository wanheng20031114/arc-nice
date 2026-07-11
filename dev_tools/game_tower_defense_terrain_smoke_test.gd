extends SceneTree

const TOWER_SCENE := preload("res://scene/game_tower_defense.tscn")
const EXPECTED_BASE_DIRT_RECT := Rect2i(-120, -88, 256, 192)
const EXPECTED_BASE_DIRT_CELL_COUNT := 256 * 192
const FULL_DIRT_ATLAS_COORDS := Vector2i(2, 1)

var failures: Array[String] = []


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	var start_msec := Time.get_ticks_msec()
	var game := TOWER_SCENE.instantiate() as GameTowerDefense
	_expect(game != null, "Tower-defense scene must instantiate for terrain verification.")
	if game == null:
		_finish()
		return

	game.auto_start_waves = false
	game.linglan_boss_enabled = false
	root.add_child(game)
	current_scene = game
	await process_frame
	await process_frame

	_verify_dual_grid_wiring(game)
	_verify_visual_grid_alignment(game)
	_verify_base_dirt_coverage(game)
	_verify_runtime_placement_visibility(game)
	var refresh_start_msec := Time.get_ticks_msec()
	game.dual_grid_terrain.refresh_all_tiles()
	print("Cached dual-grid refresh completed in %d ms." % (Time.get_ticks_msec() - refresh_start_msec))

	print("Tower-defense terrain initialized in %d ms." % (Time.get_ticks_msec() - start_msec))
	game.queue_free()
	await process_frame
	await process_frame
	_finish()


func _verify_dual_grid_wiring(game: GameTowerDefense) -> void:
	var terrain := game.dual_grid_terrain
	_expect(terrain != null, "Tower-defense scene must expose DualGridTerrain.")
	if terrain == null:
		return

	var layers: Array[TileMapLayer] = [
		terrain.world_map_layer,
		terrain.base_dirt_map_layer,
		terrain.grass_display_map_layer,
		terrain.dirt_display_map_layer,
		terrain.water_display_map_layer,
		terrain.metal_display_map_layer,
		terrain.terrain_detail_map_layer,
	]
	for layer in layers:
		_expect(layer != null, "Every dual-grid TileMapLayer reference must be assigned.")
		if layer == null:
			continue
		_expect(layer.tile_set != null, "%s must have a TileSet." % layer.name)
		_expect(
			layer.tile_set != null and layer.tile_set.tile_size == Vector2i(16, 16),
			"%s must use the authored 16x16 dual-grid TileSet." % layer.name
		)
		_expect(not layer.collision_enabled, "%s must stay visual-only without collision." % layer.name)
		_expect(not layer.navigation_enabled, "%s must stay outside TileMap navigation." % layer.name)
		_expect(not layer.occlusion_enabled, "%s must not create light occluders." % layer.name)

	_expect(
		game.ground_tile_map_layer.tile_set.tile_size == terrain.world_map_layer.tile_set.tile_size,
		"Dual-grid logical cells must match the existing gameplay grid size."
	)
	_expect(
		terrain.base_dirt_map_layer.rendering_quadrant_size == 32,
		"The large dirt backdrop must batch rendering in 32x32 quadrants."
	)


func _verify_visual_grid_alignment(game: GameTowerDefense) -> void:
	var terrain := game.dual_grid_terrain
	if terrain == null:
		return
	var gameplay_layer := game.ground_tile_map_layer
	_expect(
		terrain.global_position.is_equal_approx(gameplay_layer.global_position),
		"Dual-grid terrain root must share GroundTileMapLayer's logical origin."
	)
	_expect(
		terrain.world_map_layer.global_position.is_equal_approx(gameplay_layer.global_position),
		"WorldLayer must stay on the gameplay grid without a root half-cell offset."
	)
	var logical_cell_center := terrain.world_map_layer.to_global(
		terrain.world_map_layer.map_to_local(Vector2i(7, 5))
	)
	var gameplay_cell_center := gameplay_layer.to_global(
		gameplay_layer.map_to_local(Vector2i(7, 5))
	)
	_expect(
		logical_cell_center.is_equal_approx(gameplay_cell_center),
		"WorldLayer logical cell centers must match GroundTileMapLayer."
	)
	var display_layers: Array[TileMapLayer] = [
		terrain.base_dirt_map_layer,
		terrain.grass_display_map_layer,
		terrain.dirt_display_map_layer,
		terrain.water_display_map_layer,
		terrain.metal_display_map_layer,
		terrain.terrain_detail_map_layer,
	]
	for layer in display_layers:
		if layer == null:
			continue
		_expect(
			layer.global_position.is_equal_approx(
				gameplay_layer.global_position + Vector2(-8.0, -8.0)
			),
			"%s must retain the original dual-grid half-cell display offset." % layer.name
		)
		var display_cell_center := layer.to_global(layer.map_to_local(Vector2i(7, 5)))
		_expect(
			display_cell_center.is_equal_approx(
				gameplay_cell_center + Vector2(-8.0, -8.0)
			),
			"%s rendered cells must retain the original dual-grid offset." % layer.name
		)
	_expect(
		terrain.base_dirt_map_layer.z_index == -3,
		"Base dirt must stay at Z=-3 as the lowest terrain layer."
	)
	_expect(terrain.world_map_layer.z_index == -2, "WorldLayer must stay at Z=-2.")
	for layer in [
		terrain.grass_display_map_layer,
		terrain.dirt_display_map_layer,
		terrain.water_display_map_layer,
		terrain.metal_display_map_layer,
		terrain.terrain_detail_map_layer,
	]:
		_expect(
			layer.z_index == -1,
			"%s must stay at Z=-1 above WorldLayer and below GroundTileMapLayer." % layer.name
		)
	_expect(
		gameplay_layer.z_index == 0,
		"GroundTileMapLayer must stay at Z=0 above dual-grid terrain."
	)
	_expect(
		game.overlay_tile_map_layer.z_index == 1,
		"OverlayTileMapLayer must stay at Z=1 above GroundTileMapLayer."
	)

	terrain.set_tile(Vector2i.ZERO, DualGridTilemap.TerrainType.GRASS)
	_expect(
		terrain.grass_display_map_layer.get_used_cells().size() == 4,
		"One dual-grid logical grass cell must render four aligned visual cells."
	)
	terrain.set_tile(Vector2i.ZERO, DualGridTilemap.TerrainType.EMPTY)


func _verify_base_dirt_coverage(game: GameTowerDefense) -> void:
	var terrain := game.dual_grid_terrain
	if terrain == null or terrain.base_dirt_map_layer == null:
		return
	var dirt_layer := terrain.base_dirt_map_layer
	_expect(
		terrain.base_dirt_fill_origin == EXPECTED_BASE_DIRT_RECT.position,
		"Base dirt fill origin must keep the backdrop centered on the arena."
	)
	_expect(
		terrain.base_dirt_fill_cells == EXPECTED_BASE_DIRT_RECT.size,
		"Base dirt fill size must remain 256x192 cells."
	)
	_expect(
		dirt_layer.get_used_rect() == EXPECTED_BASE_DIRT_RECT,
		"Base dirt layer must cover the complete 4096x3072 world backdrop."
	)
	_expect(
		dirt_layer.get_used_cells().size() == EXPECTED_BASE_DIRT_CELL_COUNT,
		"Base dirt layer must contain every cell in its configured rectangle."
	)
	for coords in [EXPECTED_BASE_DIRT_RECT.position, EXPECTED_BASE_DIRT_RECT.end - Vector2i.ONE]:
		_expect(
			dirt_layer.get_cell_source_id(coords) == DualGridTilemap.TerrainType.DIRT,
			"Base dirt corner %s must use the dirt atlas source." % coords
		)
		_expect(
			dirt_layer.get_cell_atlas_coords(coords) == FULL_DIRT_ATLAS_COORDS,
			"Base dirt corner %s must use the full dirt tile." % coords
		)
	_expect(
		dirt_layer.z_index < game.ground_tile_map_layer.z_index,
		"Base dirt must render below the existing gameplay ground."
	)
	_expect(
		game.ground_tile_map_layer.get_used_rect().size == Vector2i(54, 31),
		"The visual dirt backdrop must not expand the 54x31 gameplay/pathfinding grid."
	)
	_expect(
		game.plant_system.ground_tile_map == game.ground_tile_map_layer,
		"Plant placement must continue using the gameplay ground, not the visual backdrop."
	)
	_expect(
		game.grid_pathfinder.get("obstacle_tile_layer_path") == NodePath("../GroundTileMapLayer"),
		"GridPathfinder must remain isolated from the large visual dirt backdrop."
	)


func _verify_runtime_placement_visibility(game: GameTowerDefense) -> void:
	var controller := game.plant_placement_controller
	_expect(controller != null, "PlantPlacementController must exist for visibility verification.")
	if controller == null:
		return
	var instructions := controller.get_node("PlacementInstructions") as CanvasLayer
	_expect(not controller.preview.visible, "Placement preview must start hidden.")
	_expect(not controller.selection_hud.visible, "Plant selection CanvasLayer must start hidden.")
	_expect(instructions != null and not instructions.visible, "Placement instructions must start hidden.")

	_expect(controller.open_selection(), "Plant selection must open at runtime.")
	_expect(controller.selection_hud.visible, "Plant selection CanvasLayer must show at runtime.")
	_expect(controller.selection_hud.is_open(), "Plant selection Root must show at runtime.")
	var configs := game.plant_system.get_available_configs()
	if not configs.is_empty():
		controller.selection_hud.selection_confirmed.emit(configs[0])
		_expect(instructions != null and instructions.visible, "Placement instructions must show after selection.")
		_expect(controller.placement_hint_root.visible, "Placement instruction content must show after selection.")
	controller.cancel_placement()
	_expect(not controller.selection_hud.visible, "Plant selection CanvasLayer must hide after cancellation.")
	_expect(instructions != null and not instructions.visible, "Placement instructions must hide after cancellation.")


func _finish() -> void:
	if failures.is_empty():
		print("GAME_TOWER_DEFENSE_TERRAIN_SMOKE_TEST_OK")
		quit()
		return
	for failure in failures:
		push_error(failure)
	quit(1)


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
