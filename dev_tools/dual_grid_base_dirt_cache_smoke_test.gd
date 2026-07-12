extends SceneTree

const DUAL_GRID_TILESET := preload(
	"res://resources/terrain/dual_grid/terrain_dual_grid_tileset_16.tres"
)
const BAKED_FILL_RECT := Rect2i(-3, -2, 8, 6)

var failures: Array[String] = []


class RebuildCountingDualGridTilemap:
	extends DualGridTilemap

	var rebuild_count := 0

	func _rebuild_base_dirt_layer(fill_rect: Rect2i) -> void:
		rebuild_count += 1
		super._rebuild_base_dirt_layer(fill_rect)


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	var terrain := RebuildCountingDualGridTilemap.new()
	var dirt_layer := TileMapLayer.new()
	dirt_layer.tile_set = DUAL_GRID_TILESET
	terrain.base_dirt_map_layer = dirt_layer
	terrain.base_dirt_fill_origin = BAKED_FILL_RECT.position
	terrain.base_dirt_fill_cells = BAKED_FILL_RECT.size
	terrain.base_dirt_source_id = DualGridTilemap.TerrainType.DIRT
	terrain.base_dirt_atlas_coords = Vector2i(2, 1)
	terrain.add_child(dirt_layer)
	root.add_child(terrain)

	for y in range(BAKED_FILL_RECT.position.y, BAKED_FILL_RECT.end.y):
		for x in range(BAKED_FILL_RECT.position.x, BAKED_FILL_RECT.end.x):
			dirt_layer.set_cell(
				Vector2i(x, y),
				terrain.base_dirt_source_id,
				terrain.base_dirt_atlas_coords
			)
	await process_frame

	terrain.set("_base_dirt_generation_key", [])
	terrain.call("_refresh_base_dirt_layer")

	var expected_generation_key := [
		dirt_layer.get_instance_id(),
		BAKED_FILL_RECT.position,
		BAKED_FILL_RECT.size,
		terrain.base_dirt_source_id,
		terrain.base_dirt_atlas_coords,
	]
	_expect(
		terrain.get("_base_dirt_generation_key") == expected_generation_key,
		"匹配配置的烘焙泥土层必须在首次刷新时直接建立generation key。"
	)
	_expect(
		terrain.rebuild_count == 0,
		"匹配配置的烘焙泥土层不得在启动时被清空并逐格重铺。"
	)

	var moved_fill_rect := Rect2i(BAKED_FILL_RECT.position + Vector2i(20, 0), BAKED_FILL_RECT.size)
	terrain.base_dirt_fill_origin = moved_fill_rect.position
	terrain.call("_refresh_base_dirt_layer")
	_expect(
		dirt_layer.get_used_rect() == moved_fill_rect,
		"烘焙泥土层与配置不匹配时仍必须按新fill_rect重建。"
	)
	_expect(
		terrain.rebuild_count == 1,
		"泥土fill_rect改变时必须实际更新TileMapLayer。"
	)

	terrain.queue_free()
	await process_frame
	_finish()


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)


func _finish() -> void:
	if failures.is_empty():
		print("DUAL_GRID_BASE_DIRT_CACHE_SMOKE_TEST_OK")
		quit()
		return
	for failure in failures:
		push_error(failure)
	quit(1)
