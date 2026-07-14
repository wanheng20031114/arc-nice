extends SceneTree

const SPREAD_SCENE := preload(
	"res://scene/plant_defense/vegetation_spread_system.tscn"
)

var failures: Array[String] = []
var fixture_root: Node2D = null
var terrain: FakeTerrain = null
var spread: VegetationSpreadSystem = null


class FakeTerrain:
	extends DualGridTilemap

	var raw_cells: Dictionary = {}
	var set_call_count := 0

	func _ready() -> void:
		pass

	func set_raw(cell: Vector2i, terrain_type: int) -> void:
		if terrain_type == DualGridTilemap.TerrainType.EMPTY:
			raw_cells.erase(cell)
		else:
			raw_cells[cell] = terrain_type

	func get_terrain_type(cell_pos: Vector2i) -> int:
		return int(raw_cells.get(cell_pos, DualGridTilemap.TerrainType.EMPTY))

	func set_tile(coords: Vector2i, terrain_type: int) -> void:
		var previous := get_terrain_type(coords)
		set_raw(coords, terrain_type)
		set_call_count += 1
		if previous != terrain_type:
			terrain_changed.emit(coords, previous, terrain_type)


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	_test_ring_geometry_and_pixel_hash()
	await _test_all_ring_deadlines_and_full_teardown()
	await _test_in_progress_teardown()
	await _test_obstacles_do_not_block_later_rings()
	await _test_reversible_terrain_and_skips()
	await _test_frozen_boundary()
	await _test_independent_overlap_progress()
	await _test_completed_overlap_owners()
	await _test_non_authoritative_client()
	await _test_runtime_state_is_monotonic()
	_cleanup_fixture()
	await process_frame

	if failures.is_empty():
		print("VEGETATION_SPREAD_SYSTEM_SMOKE_TEST_OK")
		quit()
		return
	for failure in failures:
		push_error(failure)
	quit(1)


func _test_ring_geometry_and_pixel_hash() -> void:
	var expected_counts := [0, 4, 8, 16, 20, 40]
	var all_offsets: Dictionary = {}
	for ring in range(1, VegetationSpreadSystem.SPREAD_RADIUS + 1):
		var offsets := VegetationSpreadSystem.get_ring_offsets(ring)
		_expect(offsets.size() == expected_counts[ring], "第%d圈必须有%d格。" % [ring, expected_counts[ring]])
		for offset in offsets:
			_expect(offset != Vector2i.ZERO, "传播圈必须排除中心格。")
			_expect(not all_offsets.has(offset), "五个传播圈之间不能有重复格。")
			all_offsets[offset] = true
	_expect(all_offsets.size() == 88, "平滑外沿后的五个传播圈必须合计88格。")
	var outer_ring := VegetationSpreadSystem.get_ring_offsets(5)
	for smoothed_cap_cell in [
		Vector2i(5, 1),
		Vector2i(5, -1),
		Vector2i(-5, 1),
		Vector2i(-5, -1),
		Vector2i(1, 5),
		Vector2i(-1, 5),
		Vector2i(1, -5),
		Vector2i(-1, -5),
	]:
		_expect(outer_ring.has(smoothed_cap_cell), "第五圈必须补齐轴向尖帽相邻格：%s" % smoothed_cap_cell)
	for outside_cell in [
		Vector2i(5, 2),
		Vector2i(2, 5),
		Vector2i(-5, -2),
		Vector2i(-2, -5),
	]:
		_expect(not outer_ring.has(outside_cell), "第五圈不能超出最小平滑扩展：%s" % outside_cell)

	var cell := Vector2i(17, -9)
	var quarter := VegetationSpreadSystem.get_revealed_pixel_indices(cell, 0.25)
	var half := VegetationSpreadSystem.get_revealed_pixel_indices(cell, 0.5)
	var full := VegetationSpreadSystem.get_revealed_pixel_indices(cell, 1.0)
	_expect(quarter.size() == 12, "25%进度必须稳定揭示12个像素。")
	_expect(half.size() == 24, "50%进度必须稳定揭示24个像素。")
	_expect(full.size() == 48, "完整临时绿化最多且恰好揭示48个像素。")
	for pixel_index in quarter:
		_expect(half.has(pixel_index), "已经出现的绿化像素不能在进度增加时消失。")
	_expect(
		full == VegetationSpreadSystem.get_revealed_pixel_indices(cell, 1.0),
		"相同世界格的绿化像素哈希必须稳定。"
	)


func _test_all_ring_deadlines_and_full_teardown() -> void:
	await _build_fixture(Rect2i(-6, -6, 13, 13), true)
	_expect(not spread.is_processing(), "没有传播来源时不应保留每帧处理。")
	_expect(spread.register_source(70, Vector2i.ZERO), "五圈边界测试必须能注册权威来源。")
	_expect(spread.is_processing(), "注册未完成来源后必须启用计时处理。")
	var completed_cell_counts := [0, 4, 12, 28, 48, 88]
	var ring_cell_counts := [0, 4, 8, 16, 20, 40]
	var elapsed := 0.0
	for ring in range(1, VegetationSpreadSystem.SPREAD_RADIUS + 1):
		var just_before_deadline := float(ring) * VegetationSpreadSystem.SECONDS_PER_RING - 0.1
		spread.advance_time(just_before_deadline - elapsed)
		elapsed = just_before_deadline
		_expect(
			_count_terrain_type(DualGridTilemap.TerrainType.GRASS)
			== completed_cell_counts[ring - 1],
			"%.1f秒不能提前完成第%d圈。" % [elapsed, ring]
		)
		_expect(
			spread.get_overlay_cell_count() == ring_cell_counts[ring],
			"%.1f秒必须只显示第%d圈的%d个进行中格。" % [elapsed, ring, ring_cell_counts[ring]]
		)

		spread.advance_time(0.1)
		elapsed += 0.1
		_expect(
			_count_terrain_type(DualGridTilemap.TerrainType.GRASS)
			== completed_cell_counts[ring],
			"第%d圈必须在%.0f秒边界完成，累计%d格。" % [ring, elapsed, completed_cell_counts[ring]]
		)

	_expect(spread.get_overlay_cell_count() == 0, "50秒全部五圈完成后不能残留临时绿化覆盖。")
	_expect(not spread.is_processing(), "全部来源完成后必须停用每帧处理。")
	for ring in range(1, VegetationSpreadSystem.SPREAD_RADIUS + 1):
		for offset in VegetationSpreadSystem.get_ring_offsets(ring):
			_expect(
				terrain.get_terrain_type(offset) == DualGridTilemap.TerrainType.GRASS,
				"50秒时五圈内所有有效泥地都必须完成绿化：%s" % offset
			)

	_expect(spread.cancel_source(70), "全部五圈完成后来源仍必须可销毁。")
	_expect(not spread.has_source(70), "销毁后必须删除已完成来源。")
	_expect(terrain.raw_cells.is_empty(), "完整传播来源销毁后，其80格EMPTY草地必须全部恢复。")
	_expect(spread.get_overlay_cell_count() == 0, "完整传播来源销毁后不能残留覆盖实例。")


func _test_in_progress_teardown() -> void:
	await _build_fixture(Rect2i(-6, -6, 13, 13), true)
	_expect(spread.register_source(71, Vector2i.ZERO), "进行中销毁测试必须能注册来源。")
	spread.advance_time(15.0)
	_expect(
		_count_terrain_type(DualGridTilemap.TerrainType.GRASS) == 4,
		"15秒时只能完成第一圈4格。"
	)
	_expect(spread.get_overlay_cell_count() == 8, "15秒时第二圈8格必须处于50%绿化过程。")
	_expect(spread.cancel_source(71), "传播进行中的来源必须可立即销毁。")
	_expect(not spread.is_processing(), "销毁最后一个进行中来源后必须停用每帧处理。")
	_expect(terrain.raw_cells.is_empty(), "进行中销毁必须恢复已完成第一圈并清除未完成第二圈。")
	_expect(spread.get_overlay_cell_count() == 0, "进行中销毁必须立即清除所有临时绿化像素。")


func _test_obstacles_do_not_block_later_rings() -> void:
	await _build_fixture(Rect2i(-6, -6, 13, 13), true, {
		Vector2i(1, 0): DualGridTilemap.TerrainType.WATER,
		Vector2i(0, 1): DualGridTilemap.TerrainType.METAL,
	})
	_expect(spread.register_source(72, Vector2i.ZERO), "障碍穿透测试必须能注册来源。")
	spread.advance_time(50.0)
	_expect(
		terrain.get_terrain_type(Vector2i(1, 0)) == DualGridTilemap.TerrainType.WATER,
		"第一圈水格必须保持不变。"
	)
	_expect(
		terrain.get_terrain_type(Vector2i(0, 1)) == DualGridTilemap.TerrainType.METAL,
		"第一圈金属格必须保持不变。"
	)
	for cell in [
		Vector2i(2, 0),
		Vector2i(3, 0),
		Vector2i(4, 0),
		Vector2i(5, 0),
		Vector2i(0, 2),
		Vector2i(0, 3),
		Vector2i(0, 4),
		Vector2i(0, 5),
	]:
		_expect(
			terrain.get_terrain_type(cell) == DualGridTilemap.TerrainType.GRASS,
			"障碍不能阻断同方向更外圈泥地的传播：%s" % cell
		)
	spread.cancel_source(72)
	_expect(
		terrain.get_terrain_type(Vector2i(1, 0)) == DualGridTilemap.TerrainType.WATER,
		"来源销毁后原有水格必须保持水。"
	)
	_expect(
		terrain.get_terrain_type(Vector2i(0, 1)) == DualGridTilemap.TerrainType.METAL,
		"来源销毁后原有金属格必须保持金属。"
	)
	_expect(terrain.get_terrain_type(Vector2i(5, 0)) == DualGridTilemap.TerrainType.EMPTY, "障碍后方生成草必须随来源恢复。")


func _test_reversible_terrain_and_skips() -> void:
	await _build_fixture(Rect2i(-6, -6, 13, 13), true, {
		Vector2i(2, 0): DualGridTilemap.TerrainType.DIRT,
		Vector2i(0, 2): DualGridTilemap.TerrainType.GRASS,
		Vector2i(-2, 0): DualGridTilemap.TerrainType.WATER,
		Vector2i(0, -2): DualGridTilemap.TerrainType.METAL,
	})
	_expect(spread.register_source(1, Vector2i.ZERO), "权威端必须能注册植被桩来源。")
	spread.advance_time(9.9)
	_expect(terrain.set_call_count == 0, "9.9秒时第一圈不能提前转换。")
	_expect(spread.get_overlay_cell_count() == 4, "第一圈转换前必须只有4个唯一覆盖实例。")
	spread.advance_time(0.1)
	for offset in VegetationSpreadSystem.get_ring_offsets(1):
		_expect(
			terrain.get_terrain_type(offset) == DualGridTilemap.TerrainType.GRASS,
			"10秒时第一圈必须转为草地：%s" % offset
		)
	_expect(terrain.get_terrain_type(Vector2i.ZERO) == DualGridTilemap.TerrainType.EMPTY, "中心格不能由传播修改。")

	spread.advance_time(10.0)
	_expect(terrain.get_terrain_type(Vector2i(2, 0)) == DualGridTilemap.TerrainType.GRASS, "显式DIRT必须可转草。")
	_expect(terrain.get_terrain_type(Vector2i(0, 2)) == DualGridTilemap.TerrainType.GRASS, "原有草地必须保持草地。")
	_expect(terrain.get_terrain_type(Vector2i(-2, 0)) == DualGridTilemap.TerrainType.WATER, "水格必须跳过。")
	_expect(terrain.get_terrain_type(Vector2i(0, -2)) == DualGridTilemap.TerrainType.METAL, "金属格必须跳过。")
	_expect(
		terrain.set_call_count == 9,
		"前两圈只能写入4个第一圈EMPTY与5个第二圈泥地，原有草不能登记或重复写入。"
	)

	_expect(spread.cancel_source(1), "来源必须可销毁。")
	for offset in VegetationSpreadSystem.get_ring_offsets(1):
		_expect(terrain.get_terrain_type(offset) == DualGridTilemap.TerrainType.EMPTY, "EMPTY生成草必须精确恢复EMPTY。")
	_expect(terrain.get_terrain_type(Vector2i(2, 0)) == DualGridTilemap.TerrainType.DIRT, "显式DIRT必须精确恢复DIRT。")
	_expect(terrain.get_terrain_type(Vector2i(0, 2)) == DualGridTilemap.TerrainType.GRASS, "原有草不能随来源销毁。")
	_expect(terrain.set_call_count == 18, "销毁时只能恢复来源实际生成的9格，不能改写原有草。")
	_expect(spread.get_overlay_cell_count() == 0, "销毁来源必须立刻清除未完成覆盖。")


func _test_frozen_boundary() -> void:
	await _build_fixture(Rect2i(0, 0, 6, 6), true)
	spread.register_source(2, Vector2i.ZERO)
	spread.advance_time(5.0)
	_expect(spread.get_overlay_cell_count() == 2, "地图角落的第一圈只能包含冻结边界内的右、下两格。")
	spread.advance_time(45.0)
	for cell in terrain.raw_cells:
		_expect(Rect2i(0, 0, 6, 6).has_point(cell), "传播不能越过初始化时冻结的地图边界。")


func _test_independent_overlap_progress() -> void:
	await _build_fixture(Rect2i(-6, -6, 15, 13), true)
	spread.register_source(10, Vector2i.ZERO)
	spread.advance_time(10.0)
	var shared_cell := Vector2i(1, 0)
	_expect(terrain.get_terrain_type(shared_cell) == DualGridTilemap.TerrainType.GRASS, "来源A必须完成重合格。")

	spread.register_source(20, Vector2i(2, 0))
	spread.advance_time(5.0)
	spread.cancel_source(10)
	_expect(
		terrain.get_terrain_type(shared_cell) == DualGridTilemap.TerrainType.EMPTY,
		"另一来源仅进行5秒时不能维持已完成来源的草地。"
	)
	_expect(
		is_equal_approx(spread.get_overlay_progress(shared_cell), 0.5),
		"领先来源销毁后只能显示另一来源自己的独立进度。"
	)
	spread.advance_time(5.0)
	_expect(terrain.get_terrain_type(shared_cell) == DualGridTilemap.TerrainType.GRASS, "来源B必须在自己的第10秒才完成。")
	spread.cancel_source(20)
	_expect(terrain.get_terrain_type(shared_cell) == DualGridTilemap.TerrainType.EMPTY, "最后维持者销毁后必须恢复原地形。")


func _test_completed_overlap_owners() -> void:
	await _build_fixture(Rect2i(-6, -6, 15, 13), true)
	spread.register_source(30, Vector2i.ZERO)
	spread.register_source(40, Vector2i(2, 0))
	spread.advance_time(10.0)
	var shared_cell := Vector2i(1, 0)
	_expect(terrain.set_call_count == 7, "重叠来源完成同格时只能转换一次，不能叠加或重复提交。")
	spread.cancel_source(30)
	_expect(terrain.get_terrain_type(shared_cell) == DualGridTilemap.TerrainType.GRASS, "两个来源均完成时销毁一个必须保留草地。")
	spread.cancel_source(40)
	_expect(terrain.get_terrain_type(shared_cell) == DualGridTilemap.TerrainType.EMPTY, "最后一个完成来源销毁时必须恢复草地。")


func _test_non_authoritative_client() -> void:
	await _build_fixture(Rect2i(-6, -6, 13, 13), false)
	spread.register_source(50, Vector2i.ZERO)
	spread.advance_time(50.0)
	_expect(terrain.set_call_count == 0, "非权威客户端不能根据本地计时修改地形。")
	_expect(spread.get_overlay_cell_count() == 80, "非权威客户端仍须显示五圈的预测绿化覆盖。")
	spread.cancel_source(50)
	_expect(terrain.set_call_count == 0, "非权威客户端销毁来源也不能自行恢复地形。")


func _test_runtime_state_is_monotonic() -> void:
	await _build_fixture(Rect2i(-6, -6, 13, 13), false)
	_expect(
		spread.apply_source_runtime_state(
			60,
			Vector2i.ZERO,
			{"schema": 1, "spread_elapsed_seconds": 25.0}
		),
		"客户端必须能从多人运行时状态注册来源。"
	)
	spread.apply_source_runtime_state(
		60,
		Vector2i.ZERO,
		{"schema": 1, "spread_elapsed_seconds": 5.0}
	)
	var exported := spread.export_source_runtime_state(60)
	_expect(is_equal_approx(float(exported.get("spread_elapsed_seconds", 0.0)), 25.0), "重复的较旧状态不能让传播时间倒退。")


func _build_fixture(
	bounds: Rect2i,
	authority: bool,
	initial_cells: Dictionary = {}
) -> void:
	_cleanup_fixture()
	fixture_root = Node2D.new()
	fixture_root.name = "VegetationSpreadFixture"
	root.add_child(fixture_root)

	terrain = FakeTerrain.new()
	terrain.name = "FakeTerrain"
	var world_layer := TileMapLayer.new()
	world_layer.name = "WorldLayer"
	var tile_set := TileSet.new()
	tile_set.tile_size = Vector2i(16, 16)
	world_layer.tile_set = tile_set
	terrain.add_child(world_layer)
	terrain.world_map_layer = world_layer
	for cell in initial_cells:
		terrain.set_raw(cell, int(initial_cells[cell]))
	fixture_root.add_child(terrain)

	spread = SPREAD_SCENE.instantiate() as VegetationSpreadSystem
	fixture_root.add_child(spread)
	await process_frame
	_expect(spread != null, "传播场景必须实例化为VegetationSpreadSystem。")
	_expect(spread.get_node_or_null("GrowthOverlay") is MultiMeshInstance2D, "传播场景必须预置MultiMeshInstance2D。")
	if spread != null:
		var overlay := spread.get_node("GrowthOverlay") as MultiMeshInstance2D
		_expect(overlay.multimesh != null and overlay.multimesh.use_custom_data, "覆盖MultiMesh必须启用INSTANCE_CUSTOM。")
		_expect(overlay.multimesh.mesh is QuadMesh, "覆盖表现必须使用预置16×16 QuadMesh。")
		if overlay.multimesh.mesh is QuadMesh:
			_expect((overlay.multimesh.mesh as QuadMesh).size == Vector2(16, 16), "覆盖QuadMesh必须严格对齐16×16地块。")
		_expect(spread.setup(terrain, bounds, authority), "传播系统必须接受冻结边界和权威模式配置。")


func _cleanup_fixture() -> void:
	if fixture_root != null and is_instance_valid(fixture_root):
		fixture_root.free()
	fixture_root = null
	terrain = null
	spread = null


func _count_terrain_type(terrain_type: int) -> int:
	var count := 0
	for cell_variant in terrain.raw_cells:
		if int(terrain.raw_cells[cell_variant]) == terrain_type:
			count += 1
	return count


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
