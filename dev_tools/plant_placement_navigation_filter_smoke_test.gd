extends SceneTree

const AGAVE_CONFIG := preload("res://resources/config/plant_defense/agave_cannon.tres")
const VEGETATION_STAKE_CONFIG := preload(
	"res://resources/config/plant_defense/vegetation_stake.tres"
)
const SIMPLE_FENCE_CONFIG := preload(
	"res://resources/config/plant_defense/simple_fence.tres"
)
const PLACEMENT_PREVIEW_SCENE := preload(
	"res://scene/plant_defense/plant_placement_preview.tscn"
)
const PLACEMENT_CONTROLLER_SCENE := preload(
	"res://scene/plant_defense/plant_placement_controller.tscn"
)
const MINIMAP_SCENE := preload("res://scene/tower_defense_minimap.tscn")

var failures: Array[String] = []


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	_test_footprint_validation()
	await _test_footprint_preview_and_hint()
	_test_terrain_change_filters()
	_finish()


func _test_footprint_validation() -> void:
	var config := AGAVE_CONFIG.duplicate(true) as PlantDefenseConfig
	config.footprint_size = Vector2i.ONE
	_expect(config.is_valid(), "A valid plant config must accept a 1x1 footprint.")
	config.footprint_size = Vector2i(2, 2)
	_expect(config.is_valid(), "Existing 2x2 plant footprints must remain valid.")
	config.footprint_size = Vector2i(0, 1)
	_expect(not config.is_valid(), "A footprint with zero width must be invalid.")
	config.footprint_size = Vector2i(1, 0)
	_expect(not config.is_valid(), "A footprint with zero height must be invalid.")
	config.footprint_size = Vector2i(-1, 1)
	_expect(not config.is_valid(), "A footprint with negative width must be invalid.")
	config.footprint_size = Vector2i(2, 2)
	config.placement_preview_display_size = Vector2.ZERO
	_expect(not config.is_valid(), "A zero-sized placement preview must be invalid.")
	config.placement_preview_display_size = Vector2(32.0, 32.0)
	config.placement_preview_offset = Vector2(INF, 0.0)
	_expect(not config.is_valid(), "A non-finite placement preview offset must be invalid.")


func _test_footprint_preview_and_hint() -> void:
	var preview := PLACEMENT_PREVIEW_SCENE.instantiate() as PlantPlacementPreview
	root.add_child(preview)
	await process_frame

	preview.configure(VEGETATION_STAKE_CONFIG, Vector2(16.0, 16.0))
	_expect(
		preview.footprint_size == Vector2(16.0, 16.0)
		and preview.ghost_sprite.texture.get_size()
		* preview.ghost_sprite.scale == Vector2(32.0, 32.0),
		"The 1x1 vegetation stake must retain its intentional 32x32 visual overhang."
	)
	preview.configure(SIMPLE_FENCE_CONFIG, Vector2(16.0, 16.0))
	_expect(
		preview.footprint_size == Vector2(16.0, 16.0)
		and preview.ghost_sprite.texture.get_size()
		* preview.ghost_sprite.scale == Vector2(16.0, 16.0)
		and preview.ghost_sprite.position == Vector2.ZERO,
		"The 1x1 fence ghost must match its placed 16x16 world canvas without offset."
	)
	preview.configure(AGAVE_CONFIG, Vector2(16.0, 16.0))
	_expect(
		preview.footprint_size == Vector2(32.0, 32.0),
		"An existing 2x2 preview must keep its 32x32 footprint."
	)
	preview.queue_free()

	var controller := PLACEMENT_CONTROLLER_SCENE.instantiate() as PlantPlacementController
	root.add_child(controller)
	await process_frame
	controller.selected_config = VEGETATION_STAKE_CONFIG
	controller.valid_anchors = [Vector2i.ZERO, Vector2i.RIGHT]
	controller._update_hint_text()
	_expect(
		controller.placement_hint_label.text.contains("2 个可放置位置")
		and not controller.placement_hint_label.text.contains("交点"),
		"Placement instructions must describe generic positions instead of intersections."
	)
	controller.queue_free()
	await process_frame


func _test_terrain_change_filters() -> void:
	var pathfinder := GridPathfinder.new()
	_expect(
		not pathfinder._does_terrain_change_affect_navigation(
			DualGridTilemap.TerrainType.DIRT,
			DualGridTilemap.TerrainType.GRASS
		),
		"Dirt-to-grass changes must not invalidate LAND navigation."
	)
	_expect(
		not pathfinder._does_terrain_change_affect_navigation(
			DualGridTilemap.TerrainType.EMPTY,
			DualGridTilemap.TerrainType.GRASS
		),
		"Implicit dirt-to-grass changes must not invalidate LAND navigation."
	)
	pathfinder._on_terrain_changed(
		Vector2i.ZERO,
		DualGridTilemap.TerrainType.DIRT,
		DualGridTilemap.TerrainType.GRASS
	)
	_expect(
		not pathfinder.terrain_rebuild_queued,
		"The terrain signal handler must not queue a rebuild for dirt-to-grass changes."
	)
	_expect(
		pathfinder._does_terrain_change_affect_navigation(
			DualGridTilemap.TerrainType.DIRT,
			DualGridTilemap.TerrainType.WATER
		),
		"Entering water must still invalidate navigation."
	)
	pathfinder.free()

	var minimap := MINIMAP_SCENE.instantiate() as TowerDefenseMinimap
	root.add_child(minimap)
	var minimap_canvas := minimap.minimap_canvas
	_expect(
		not minimap_canvas._does_terrain_change_affect_static_topology(
			DualGridTilemap.TerrainType.DIRT,
			DualGridTilemap.TerrainType.GRASS
		),
		"Dirt-to-grass changes must not rebuild minimap topology."
	)
	minimap_canvas._on_terrain_topology_changed(
		Vector2i.ZERO,
		DualGridTilemap.TerrainType.DIRT,
		DualGridTilemap.TerrainType.GRASS
	)
	_expect(
		not minimap_canvas._static_rebuild_pending,
		"The minimap terrain handler must ignore dirt-to-grass changes."
	)
	_expect(
		minimap_canvas._does_terrain_change_affect_static_topology(
			DualGridTilemap.TerrainType.GRASS,
			DualGridTilemap.TerrainType.WATER
		),
		"Entering water must still rebuild minimap topology."
	)
	_expect(
		minimap_canvas._does_terrain_change_affect_static_topology(
			DualGridTilemap.TerrainType.WATER,
			DualGridTilemap.TerrainType.EMPTY
		),
		"Leaving water must still rebuild minimap topology."
	)
	minimap.free()


func _finish() -> void:
	if failures.is_empty():
		print("PLANT_PLACEMENT_NAVIGATION_FILTER_SMOKE_TEST_OK")
		quit()
		return
	for failure in failures:
		push_error(failure)
	quit(1)


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
