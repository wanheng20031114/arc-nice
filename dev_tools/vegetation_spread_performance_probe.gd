extends SceneTree

const SPREAD_SCENE := preload(
	"res://scene/game_modes/tower_defense/plant/vegetation/vegetation_spread_system.tscn"
)
const COMPLETED_SOURCE_COUNT := 32
const ADVANCE_CALL_COUNT := 500
const ADVANCE_STEP_SECONDS := 0.01

var failures: Array[String] = []


class FakeTerrain:
	extends DualGridTilemap

	var raw_cells: Dictionary = {}

	func _ready() -> void:
		pass

	func get_terrain_type(cell_pos: Vector2i) -> int:
		return int(raw_cells.get(cell_pos, DualGridTilemap.TerrainType.EMPTY))

	func set_tile(coords: Vector2i, terrain_type: int) -> void:
		if terrain_type == DualGridTilemap.TerrainType.EMPTY:
			raw_cells.erase(coords)
		else:
			raw_cells[coords] = terrain_type


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	var fixture := Node2D.new()
	root.add_child(fixture)
	var terrain := FakeTerrain.new()
	var world_layer := TileMapLayer.new()
	var tile_set := TileSet.new()
	tile_set.tile_size = Vector2i(16, 16)
	world_layer.tile_set = tile_set
	terrain.add_child(world_layer)
	terrain.world_map_layer = world_layer
	fixture.add_child(terrain)
	var spread := SPREAD_SCENE.instantiate() as VegetationSpreadSystem
	fixture.add_child(spread)
	await process_frame
	_expect(
		spread.setup(terrain, Rect2i(-100, -100, 201, 201), false),
		"Performance probe fixture must configure the vegetation system."
	)

	for source_index in range(COMPLETED_SOURCE_COUNT):
		var origin := Vector2i(
			-72 + (source_index % 8) * 18,
			-72 + (source_index / 8) * 18
		)
		spread.register_source(
			source_index + 1,
			origin,
			VegetationSpreadSystem.TOTAL_SPREAD_SECONDS
		)
	spread.register_source(1000, Vector2i(80, 80), 0.0)
	_expect(
		spread.get_source_count() == COMPLETED_SOURCE_COUNT + 1
		and spread.get_active_source_count() == 1,
		"Completed sources must stay available for ownership while leaving the 10 Hz active set."
	)

	spread.reset_overlay_update_stats()
	var advance_started_usec := Time.get_ticks_usec()
	for _advance_index in range(ADVANCE_CALL_COUNT):
		spread.advance_time(ADVANCE_STEP_SECONDS)
	var advance_elapsed_ms := float(Time.get_ticks_usec() - advance_started_usec) / 1000.0
	_expect(
		spread.get_last_advance_source_count() == 1,
		"Each advancement must visit only the one incomplete source."
	)
	_expect(
		int((spread.get_overlay_update_stats())["flush_count"]) == 0,
		"Repeated same-frame updates must remain coalesced before the render-frame flush."
	)

	var flush_started_usec := Time.get_ticks_usec()
	spread.call("_process", 0.0)
	var first_flush_elapsed_ms := float(Time.get_ticks_usec() - flush_started_usec) / 1000.0
	var first_stats := spread.get_overlay_update_stats()
	var first_transform_writes := int(first_stats["transform_write_count"])
	_expect(
		int(first_stats["flush_count"]) == 1
		and int(first_stats["layout_rebuild_count"]) == 1
		and first_transform_writes == spread.get_overlay_cell_count(),
		"The first coalesced flush must author each unique cell transform exactly once."
	)

	spread.advance_time(1.0)
	var progress_flush_started_usec := Time.get_ticks_usec()
	spread.call("_process", 0.0)
	var progress_flush_elapsed_ms := (
		float(Time.get_ticks_usec() - progress_flush_started_usec) / 1000.0
	)
	var progress_stats := spread.get_overlay_update_stats()
	_expect(
		int(progress_stats["layout_rebuild_count"]) == 1
		and int(progress_stats["transform_write_count"]) == first_transform_writes,
		"Progress-only flushes must preserve the stable transform layout."
	)

	print(
		(
			"VEGETATION_SPREAD_PERFORMANCE_PROBE sources=%d active=%d "
			+ "advance_calls=%d advance_ms=%.3f first_flush_ms=%.3f "
			+ "progress_flush_ms=%.3f overlay_cells=%d stats=%s"
		)
		% [
			spread.get_source_count(),
			spread.get_active_source_count(),
			ADVANCE_CALL_COUNT,
			advance_elapsed_ms,
			first_flush_elapsed_ms,
			progress_flush_elapsed_ms,
			spread.get_overlay_cell_count(),
			str(progress_stats),
		]
	)

	fixture.queue_free()
	await process_frame
	if failures.is_empty():
		print("VEGETATION_SPREAD_PERFORMANCE_PROBE_OK")
		quit()
		return
	for failure in failures:
		push_error(failure)
	quit(1)


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
