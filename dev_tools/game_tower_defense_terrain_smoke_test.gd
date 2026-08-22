extends SceneTree

const TOWER_SCENE := preload("res://scene/game_modes/tower_defense/tower_defense_game.tscn")
const BASE_DIRT_TILE_TEXTURE := preload(
	"res://resources/terrain/dual_grid/tilled_soil_full_tile_16.png"
)
const DIRT_ATLAS_TEXTURE := preload(
	"res://resources/terrain/dual_grid/tilled_soil_dual_grid_atlas_16.png"
)
const EXPECTED_BASE_DIRT_RECT := Rect2i(-120, -88, 256, 192)
const EXPECTED_BASE_DIRT_WORLD_POSITION := Vector2(-1928.0, -1416.0)
const EXPECTED_BASE_DIRT_WORLD_SIZE := Vector2(4096.0, 3072.0)
const WATER_TERRAIN_COLLISION_LAYER := 1 << 11

var failures: Array[String] = []


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	var start_msec := Time.get_ticks_msec()
	var game := TOWER_SCENE.instantiate() as TowerDefenseGame
	_expect(game != null, "Tower-defense scene must instantiate for terrain verification.")
	if game == null:
		_finish()
		return

	game.auto_start_waves = false
	_expect(game.linglan_boss_enabled, "Tower-defense Linglan must be enabled by the authored scene.")
	root.add_child(game)
	current_scene = game
	await process_frame
	await process_frame

	_verify_dual_grid_wiring(game)
	_verify_large_map_topology(game)
	_verify_visual_grid_alignment(game)
	_verify_base_dirt_coverage(game)
	_verify_base_dirt_texture_matches_atlas()
	_verify_terrain_semantics(game)
	_verify_reachable_grass_placement(game)
	await _verify_runtime_placement_visibility(game)
	var refresh_start_msec := Time.get_ticks_msec()
	game.dual_grid_terrain.refresh_all_tiles()
	print("Cached dual-grid refresh completed in %d ms." % (Time.get_ticks_msec() - refresh_start_msec))

	print("Tower-defense terrain initialized in %d ms." % (Time.get_ticks_msec() - start_msec))
	game.queue_free()
	await process_frame
	await process_frame
	_finish()


func _verify_dual_grid_wiring(game: TowerDefenseGame) -> void:
	var terrain := game.dual_grid_terrain
	_expect(terrain != null, "Tower-defense scene must expose DualGridTerrain.")
	if terrain == null:
		return

	var layers: Array[TileMapLayer] = [
		terrain.world_map_layer,
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

	var water_collision_layer := terrain.water_collision_map_layer
	_expect(water_collision_layer != null, "Dual-grid terrain must expose WaterCollisionLayer.")
	if water_collision_layer != null:
		_expect(water_collision_layer.collision_enabled, "WaterCollisionLayer must enable collision.")
		_expect(not water_collision_layer.navigation_enabled, "Water collision must not create TileMap navigation.")
		_expect(is_zero_approx(water_collision_layer.self_modulate.a), "Water collision tiles must remain visually transparent.")
		_expect(water_collision_layer.tile_set != null, "WaterCollisionLayer must have a TileSet.")
		if water_collision_layer.tile_set != null:
			_expect(
				water_collision_layer.tile_set.get_physics_layers_count() == 1,
				"WaterCollisionLayer must provide exactly one physics layer."
			)
			_expect(
				water_collision_layer.tile_set.get_physics_layer_collision_layer(0) == WATER_TERRAIN_COLLISION_LAYER,
				"Water collision must use the dedicated WaterTerrain physics layer."
			)

	var base_dirt_backdrop := terrain.base_dirt_backdrop
	_expect(base_dirt_backdrop != null, "Dual-grid terrain must expose the repeated base-dirt backdrop.")
	_expect(
		terrain.base_dirt_map_layer == null,
		"Tower defense must not instantiate the legacy 49,152-cell base-dirt TileMapLayer."
	)
	if base_dirt_backdrop != null:
		_expect(base_dirt_backdrop.texture != null, "Base dirt backdrop must provide its authored full-tile texture.")
		_expect(
			base_dirt_backdrop.stretch_mode == TextureRect.STRETCH_TILE,
			"Base dirt backdrop must use TextureRect's native tiled stretch mode."
		)
		_expect(
			base_dirt_backdrop.texture_repeat == CanvasItem.TEXTURE_REPEAT_ENABLED,
			"Base dirt backdrop must explicitly enable texture repeat."
		)

	_expect(
		game.ground_tile_map_layer.tile_set.tile_size == terrain.world_map_layer.tile_set.tile_size,
		"Dual-grid logical cells must match the existing gameplay grid size."
	)


func _verify_large_map_topology(game: TowerDefenseGame) -> void:
	var gameplay_layer := game.ground_tile_map_layer
	var gameplay_rect := gameplay_layer.get_used_rect()
	_expect(
		gameplay_rect == Rect2i(0, 0, 74, 46),
		"Tower-defense gameplay bounds must cover the complete authored large map."
	)
	var boundary_cells: Array[Vector2i] = []
	for x in range(gameplay_rect.position.x, gameplay_rect.end.x):
		boundary_cells.append(Vector2i(x, gameplay_rect.position.y))
		boundary_cells.append(Vector2i(x, gameplay_rect.end.y - 1))
	for y in range(gameplay_rect.position.y + 1, gameplay_rect.end.y - 1):
		boundary_cells.append(Vector2i(gameplay_rect.position.x, y))
		boundary_cells.append(Vector2i(gameplay_rect.end.x - 1, y))
	for cell in boundary_cells:
		var tile_data := gameplay_layer.get_cell_tile_data(cell)
		_expect(
			tile_data != null and tile_data.get_collision_polygons_count(0) > 0,
			"Every outer large-map boundary cell must block escape: %s" % cell
		)

	var spawn_root := game.get_node("EnemySpawnPoints") as Node2D
	_expect(spawn_root.get_child_count() == 6, "Tower-defense map must expose all six spawn markers.")
	for child in spawn_root.get_children():
		var marker := child as Marker2D
		if marker == null:
			continue
		var marker_cell := gameplay_layer.local_to_map(
			gameplay_layer.to_local(marker.global_position)
		)
		_expect(
			gameplay_rect.grow(-1).has_point(marker_cell),
			"Enemy spawn marker must stay inside the closed map boundary: %s" % marker.name
		)

	for spawn_offset in TowerDefenseGame.MULTIPLAYER_SPAWN_OFFSETS:
		var spawn_position := game.player_spawn.global_position + spawn_offset
		var spawn_cell := gameplay_layer.local_to_map(gameplay_layer.to_local(spawn_position))
		var ground_data := gameplay_layer.get_cell_tile_data(spawn_cell)
		_expect(
			game.dual_grid_terrain.get_terrain_type(spawn_cell)
			== DualGridTilemap.TerrainType.GRASS,
			"Every initial/respawn slot must remain on grass: %s" % spawn_cell
		)
		_expect(
			ground_data == null or ground_data.get_collision_polygons_count(0) == 0,
			"Every initial/respawn slot must be free of Ground collision: %s" % spawn_cell
		)


func _verify_visual_grid_alignment(game: TowerDefenseGame) -> void:
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
	var base_dirt_backdrop := terrain.base_dirt_backdrop
	_expect(base_dirt_backdrop != null, "Base dirt backdrop must be wired for alignment checks.")
	_expect(
		base_dirt_backdrop != null and base_dirt_backdrop.z_index == -5,
		"Base dirt must stay at Z=-5."
	)
	_expect(
		base_dirt_backdrop != null
		and base_dirt_backdrop.z_index < terrain.world_map_layer.z_index,
		"BaseDirt must render below the semantic WorldLayer."
	)
	_expect(not terrain.world_map_layer.visible, "Semantic WorldLayer must be hidden at runtime.")
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

	var isolated_test_cell := Vector2i(80, 60)
	_expect(
		terrain.get_terrain_type(isolated_test_cell) == DualGridTilemap.TerrainType.EMPTY,
		"Terrain refresh test requires an unused logical cell."
	)
	terrain.set_tile(isolated_test_cell, DualGridTilemap.TerrainType.GRASS)
	for offset in DualGridTilemap.NEIGHBOURS:
		_expect(
			terrain.grass_display_map_layer.get_cell_source_id(isolated_test_cell + offset)
			== DualGridTilemap.TerrainType.GRASS,
			"One logical grass cell must refresh each of its four display cells."
		)
	terrain.set_tile(isolated_test_cell, DualGridTilemap.TerrainType.WATER)
	_expect(
		terrain.water_collision_map_layer.get_cell_source_id(isolated_test_cell) == 0,
		"Changing a logical cell to water must immediately synchronize its physical tile."
	)
	terrain.set_tile(isolated_test_cell, DualGridTilemap.TerrainType.EMPTY)
	_expect(
		terrain.water_collision_map_layer.get_cell_source_id(isolated_test_cell) == -1,
		"Removing water must immediately erase its physical tile."
	)


func _verify_base_dirt_coverage(game: TowerDefenseGame) -> void:
	var terrain := game.dual_grid_terrain
	if terrain == null or terrain.base_dirt_backdrop == null:
		return
	var dirt_backdrop := terrain.base_dirt_backdrop
	_expect(
		terrain.base_dirt_fill_origin == EXPECTED_BASE_DIRT_RECT.position,
		"Base dirt fill origin must keep the backdrop centered on the arena."
	)
	_expect(
		terrain.base_dirt_fill_cells == EXPECTED_BASE_DIRT_RECT.size,
		"Base dirt fill size must remain 256x192 cells."
	)
	_expect(
		dirt_backdrop.position.is_equal_approx(EXPECTED_BASE_DIRT_WORLD_POSITION),
		"Repeated base dirt must begin at the same half-cell-aligned world position as the legacy backdrop."
	)
	_expect(
		dirt_backdrop.size.is_equal_approx(EXPECTED_BASE_DIRT_WORLD_SIZE),
		"Repeated base dirt must cover the complete 4096x3072 world backdrop."
	)
	_expect(
		dirt_backdrop.texture != null
		and dirt_backdrop.texture.get_size() == Vector2(16.0, 16.0),
		"Repeated base dirt must use the exact standalone 16x16 full-dirt tile."
	)
	_expect(
		dirt_backdrop.z_index < game.ground_tile_map_layer.z_index,
		"Base dirt must render below the existing gameplay ground."
	)
	var gameplay_rect := game.ground_tile_map_layer.get_used_rect()
	_expect(
		gameplay_rect.size.x > 0
		and gameplay_rect.size.y > 0
		and gameplay_rect.size.x < EXPECTED_BASE_DIRT_RECT.size.x
		and gameplay_rect.size.y < EXPECTED_BASE_DIRT_RECT.size.y,
		"The large visual dirt backdrop must remain isolated from the smaller gameplay/pathfinding grid."
	)
	_expect(
		game.plant_system.ground_tile_map == game.ground_tile_map_layer,
		"Plant placement must continue using the gameplay ground, not the visual backdrop."
	)
	_expect(
		game.plant_system.terrain_map == terrain,
		"Plant placement must use DualGridTerrain as its terrain semantics provider."
	)
	_expect(
		game.grid_pathfinder.get("obstacle_tile_layer_path") == NodePath("../GroundTileMapLayer"),
		"GridPathfinder must remain isolated from the large visual dirt backdrop."
	)
	_expect(
		game.grid_pathfinder.get("terrain_map_path") == NodePath("../DualGridTerrain"),
		"Tower-defense pathfinding must read semantic terrain from DualGridTerrain."
	)


func _verify_base_dirt_texture_matches_atlas() -> void:
	var standalone_image := BASE_DIRT_TILE_TEXTURE.get_image()
	var atlas_image := DIRT_ATLAS_TEXTURE.get_image()
	_expect(
		standalone_image != null and standalone_image.get_size() == Vector2i(16, 16),
		"Standalone base-dirt texture must decode as one 16x16 tile."
	)
	_expect(atlas_image != null, "Authored dirt atlas must remain readable for pixel comparison.")
	if standalone_image == null or atlas_image == null:
		return
	for y in range(16):
		for x in range(16):
			_expect(
				standalone_image.get_pixel(x, y) == atlas_image.get_pixel(x + 32, y + 16),
				"Standalone base-dirt pixel (%d,%d) must exactly match atlas tile (2,1)." % [x, y]
			)


func _verify_terrain_semantics(game: TowerDefenseGame) -> void:
	var terrain := game.dual_grid_terrain
	if terrain == null:
		return
	var water_cells: Array[Vector2i] = []
	var grass_cells: Array[Vector2i] = []
	for cell in terrain.world_map_layer.get_used_cells():
		match terrain.get_terrain_type(cell):
			DualGridTilemap.TerrainType.WATER:
				water_cells.append(cell)
			DualGridTilemap.TerrainType.GRASS:
				grass_cells.append(cell)
	_expect(not water_cells.is_empty(), "Tower-defense terrain must contain semantic water cells.")
	_expect(not grass_cells.is_empty(), "Tower-defense terrain must contain semantic grass cells.")
	_expect(
		(game.player.collision_mask & WATER_TERRAIN_COLLISION_LAYER) != 0,
		"Default land players must collide with WaterTerrain."
	)
	_expect(
		terrain.water_collision_map_layer.get_used_cells().size() == water_cells.size(),
		"Every semantic water cell must have one aligned physical blocker."
	)
	if not water_cells.is_empty():
		var water_cell := water_cells[0]
		_expect(not terrain.is_cell_plantable(water_cell), "Water must reject plant placement.")
		_expect(
			not terrain.is_cell_traversable(water_cell, DualGridTilemap.TraversalType.LAND),
			"Land traversal must reject water."
		)
		_expect(
			terrain.is_cell_traversable(
				water_cell,
				DualGridTilemap.TraversalType.LAND | DualGridTilemap.TraversalType.WATER
			),
			"An amphibious traversal profile must accept water."
		)
		var water_tile_data := terrain.water_collision_map_layer.get_cell_tile_data(water_cell)
		_expect(
			water_tile_data != null and water_tile_data.get_collision_polygons_count(0) == 1,
			"Each water blocker must use one full-cell collision polygon."
		)
		_expect(
			_has_water_physics_at_cell(game, water_cell),
			"WaterTerrain physics must be queryable at the semantic water cell."
		)
	if not grass_cells.is_empty():
		_expect(terrain.is_cell_plantable(grass_cells[0]), "Only semantic grass must be plantable.")
		_expect(
			not _has_water_physics_at_cell(game, grass_cells[0]),
			"Grass must not receive a WaterTerrain physical blocker."
		)
	_verify_open_ground_terrain_rules(game, terrain)
	var default_dirt_cell := Vector2i(70, 50)
	_expect(
		terrain.get_effective_terrain_type(default_dirt_cell) == DualGridTilemap.TerrainType.DIRT,
		"Unpainted cells over the dirt fallback must behave as default dirt."
	)
	_expect(not terrain.is_cell_plantable(default_dirt_cell), "Default dirt must reject plants.")
	_expect(
		terrain.is_cell_traversable(default_dirt_cell, DualGridTilemap.TraversalType.LAND),
		"Default dirt must remain land-traversable."
	)


func _verify_open_ground_terrain_rules(
	game: TowerDefenseGame,
	terrain: DualGridTilemap
) -> void:
	var ground_cell := Vector2i.MAX
	for candidate in game.ground_tile_map_layer.get_used_cells():
		var tile_data := game.ground_tile_map_layer.get_cell_tile_data(candidate)
		if tile_data != null and tile_data.get_collision_polygons_count(0) == 0:
			ground_cell = candidate
			break
	_expect(ground_cell != Vector2i.MAX, "Gameplay grid must contain an open cell for terrain-rule tests.")
	if ground_cell == Vector2i.MAX:
		return

	var world_position := game.ground_tile_map_layer.to_global(
		game.ground_tile_map_layer.map_to_local(ground_cell)
	)
	var terrain_cell := terrain.world_to_map(world_position)
	var original_terrain_type := terrain.get_terrain_type(terrain_cell)
	var pathfinder := game.grid_pathfinder as GridPathfinder
	var amphibious_types := (
		DualGridTilemap.TraversalType.LAND | DualGridTilemap.TraversalType.WATER
	)

	terrain.set_tile(terrain_cell, DualGridTilemap.TerrainType.EMPTY)
	_expect(
		bool(game.plant_system.call(
			"_is_floor_cell_available",
			ground_cell,
			PlantDefenseRegistry.get_config(&"excavator")
		)),
		"Excavator must accept unpainted ground as effective dirt."
	)
	_expect(
		bool(game.plant_system.call(
			"_is_floor_cell_available",
			ground_cell,
			PlantDefenseRegistry.get_config(&"simple_fence")
		)),
		"Simple fence must accept unpainted ground as effective dirt."
	)
	_expect(
		not bool(game.plant_system.call(
			"_is_floor_cell_available",
			ground_cell,
			PlantDefenseRegistry.get_config(&"agave_cannon")
		)),
		"Grass-only buildings must reject unpainted effective dirt."
	)

	terrain.set_tile(terrain_cell, DualGridTilemap.TerrainType.WATER)
	pathfinder.rebuild()
	_expect(
		not bool(game.plant_system.call(
			"_is_floor_cell_available",
			ground_cell,
			PlantDefenseRegistry.get_config(&"agave_cannon")
		)),
		"PlantSystem must reject water even when the gameplay ground cell is open."
	)
	_expect(
		bool(pathfinder.call(
			"_is_cell_blocked",
			ground_cell,
			DualGridTilemap.TraversalType.LAND
		)),
		"Default land pathfinding must mark water solid."
	)
	_expect(
		not bool(pathfinder.call("_is_cell_blocked", ground_cell, amphibious_types)),
		"Amphibious pathfinding must allow water when gameplay ground is open."
	)
	var amphibious_grid := pathfinder.call(
		"_get_or_create_agent_grid",
		Vector2.ZERO,
		amphibious_types
	) as AStarGrid2D
	_expect(
		amphibious_grid != pathfinder.astar_grid,
		"Traversal profiles must use distinct cached AStar grids."
	)
	_expect(
		not amphibious_grid.is_point_solid(ground_cell),
		"The amphibious AStar grid must keep an open water cell walkable."
	)

	terrain.set_tile(terrain_cell, DualGridTilemap.TerrainType.GRASS)
	_expect(
		bool(game.plant_system.call(
			"_is_floor_cell_available",
			ground_cell,
			PlantDefenseRegistry.get_config(&"agave_cannon")
		)),
		"PlantSystem must accept an open semantic grass cell."
	)
	terrain.set_tile(terrain_cell, original_terrain_type)
	pathfinder.rebuild()


func _has_water_physics_at_cell(game: TowerDefenseGame, cell: Vector2i) -> bool:
	var collision_layer := game.dual_grid_terrain.water_collision_map_layer
	var query_shape := RectangleShape2D.new()
	query_shape.size = Vector2(8.0, 8.0)
	var query := PhysicsShapeQueryParameters2D.new()
	query.shape = query_shape
	query.transform = Transform2D(
		0.0,
		collision_layer.to_global(collision_layer.map_to_local(cell))
	)
	query.collision_mask = WATER_TERRAIN_COLLISION_LAYER
	query.collide_with_areas = false
	query.collide_with_bodies = true
	return not game.get_world_2d().direct_space_state.intersect_shape(query, 1).is_empty()


func _verify_runtime_placement_visibility(game: TowerDefenseGame) -> void:
	var controller := game.plant_placement_controller
	_expect(controller != null, "PlantPlacementController must exist for visibility verification.")
	if controller == null:
		return
	var instructions := controller.get_node("PlacementInstructions") as CanvasLayer
	_expect(not controller.preview.visible, "Placement preview must start hidden.")
	_expect(not controller.selection_hud.visible, "Plant selection CanvasLayer must start hidden.")
	_expect(instructions != null and not instructions.visible, "Placement instructions must start hidden.")

	# 该用例只验证界面生命周期，不应依赖本局背包是否恰好持有建筑箱。
	controller.set_free_placement_enabled(true)
	_expect(controller.open_selection(), "Plant selection must open at runtime.")
	_expect(controller.selection_hud.visible, "Plant selection CanvasLayer must show at runtime.")
	_expect(controller.selection_hud.is_open(), "Plant selection Root must show at runtime.")
	var configs := game.plant_system.get_available_configs()
	if not configs.is_empty():
		controller.selection_hud.selection_confirmed.emit(configs[0])
		_expect(instructions != null and instructions.visible, "Placement instructions must show after selection.")
		_expect(controller.placement_hint_root.visible, "Placement instruction content must show after selection.")
	controller.cancel_placement()
	_expect(
		not controller.selection_hud.is_open(),
		"Plant selection must stop accepting input immediately after cancellation."
	)
	# The heavy terrain scene can finish a frame just after the wall-clock timer;
	# leave one generous scheduling margin while the authored tween stays 120 ms.
	await create_timer(PlantSelectionHUD.TRANSITION_SECONDS + 0.10).timeout
	_expect(
		not controller.selection_hud.visible,
		"Plant selection CanvasLayer must hide after its authored close fade."
	)
	_expect(instructions != null and not instructions.visible, "Placement instructions must hide after cancellation.")


func _verify_reachable_grass_placement(game: TowerDefenseGame) -> void:
	var configs := game.plant_system.get_available_configs()
	_expect(not configs.is_empty(), "Tower-defense scene must expose at least one plant config.")
	if configs.is_empty():
		return
	var config := configs[0]
	var valid_anchors := game.plant_system.get_valid_anchors_for_player(config, game.player)
	var player_cell := game.ground_tile_map_layer.local_to_map(
		game.ground_tile_map_layer.to_local(game.player.global_position)
	)
	var nearest_semantic_distance := 1 << 30
	var nearest_any_grass_distance := 1 << 30
	var nearest_grounded_grass_distance := 1 << 30
	var grass_cell_count := 0
	for candidate in game.dual_grid_terrain.world_map_layer.get_used_cells():
		if game.dual_grid_terrain.get_terrain_type(candidate) != DualGridTilemap.TerrainType.GRASS:
			continue
		grass_cell_count += 1
		var terrain_square := [
			candidate,
			candidate + Vector2i.RIGHT,
			candidate + Vector2i.DOWN,
			candidate + Vector2i.ONE,
		]
		var all_semantic_grass := true
		var all_grounded_grass := true
		var square_distance := 1 << 30
		for cell in terrain_square:
			if game.dual_grid_terrain.get_terrain_type(cell) != DualGridTilemap.TerrainType.GRASS:
				all_semantic_grass = false
				all_grounded_grass = false
				break
			var ground_data := game.ground_tile_map_layer.get_cell_tile_data(cell)
			if ground_data == null or ground_data.get_collision_polygons_count(0) > 0:
				all_grounded_grass = false
			square_distance = mini(
				square_distance,
				absi(cell.x - player_cell.x) + absi(cell.y - player_cell.y)
			)
		if all_semantic_grass:
			nearest_any_grass_distance = mini(nearest_any_grass_distance, square_distance)
		if all_grounded_grass:
			nearest_grounded_grass_distance = mini(
				nearest_grounded_grass_distance,
				square_distance
			)
	var placement_area: Rect2i = game.plant_system.placement_area
	_expect(
		placement_area == game.dual_grid_terrain.world_map_layer.get_used_rect(),
		"Plant placement bounds must follow the authored terrain, not the legacy boss arena."
	)
	_expect(
		game.plant_system.max_placement_manhattan_distance == 6,
		"Tower-defense plant placement must use the intended local six-cell radius."
	)
	var last_anchor_exclusive := placement_area.end - config.footprint_size + Vector2i.ONE
	for y in range(placement_area.position.y, last_anchor_exclusive.y):
		for x in range(placement_area.position.x, last_anchor_exclusive.x):
			var anchor := Vector2i(x, y)
			var cells := game.plant_system.get_footprint_cells(anchor, config)
			var all_grass := true
			var closest_cell_distance := 1 << 30
			for cell in cells:
				if not bool(game.plant_system.call(
					"_is_floor_cell_available",
					cell,
					config
				)):
					all_grass = false
					break
				closest_cell_distance = mini(
					closest_cell_distance,
					absi(cell.x - player_cell.x) + absi(cell.y - player_cell.y)
				)
			if all_grass:
				nearest_semantic_distance = mini(
					nearest_semantic_distance,
					closest_cell_distance
				)
	print(
		(
			"Tower-defense nearest area-grounded grass=%d any-grass=%d "
			+ "grounded-grass=%d valid_anchors=%d player_cell=%s area=%s grass_cells=%d"
		)
		% [
			nearest_semantic_distance,
			nearest_any_grass_distance,
			nearest_grounded_grass_distance,
			valid_anchors.size(),
			player_cell,
			placement_area,
			grass_cell_count,
		]
	)
	_expect(
		not valid_anchors.is_empty(),
		(
			(
				"PlayerSpawn must have a reachable 2x2 grass plant anchor "
				+ "(area=%s, nearest area-grounded=%d, any-grass=%d, grounded-grass=%d, "
				+ "player_cell=%s, grass_cells=%d)."
			)
			% [
				placement_area,
				nearest_semantic_distance,
				nearest_any_grass_distance,
				nearest_grounded_grass_distance,
				player_cell,
				grass_cell_count,
			]
		)
	)


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
