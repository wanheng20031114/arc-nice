extends SceneTree

const SUPPORTED_PLANT_COUNT := 10_000
const TILE_SIZE := Vector2i(16, 16)

var failures: Array[String] = []


class TerrainProbe:
	extends DualGridTilemap

	var default_terrain := DualGridTilemap.TerrainType.GRASS
	var terrain_by_cell: Dictionary[Vector2i, int] = {}

	func set_probe_terrain(cell: Vector2i, terrain_type: int) -> void:
		var previous := get_terrain_type(cell)
		if terrain_type == default_terrain:
			terrain_by_cell.erase(cell)
		else:
			terrain_by_cell[cell] = terrain_type
		if previous != terrain_type:
			terrain_changed.emit(cell, previous, terrain_type)

	func get_terrain_type(cell_pos: Vector2i) -> int:
		return terrain_by_cell.get(cell_pos, default_terrain)

	func is_cell_plantable(cell_pos: Vector2i) -> bool:
		return get_terrain_type(cell_pos) == DualGridTilemap.TerrainType.GRASS


class LocalityProbePlantSystem:
	extends PlantSystem

	func register_probe(
		plant: PlantDefense,
		cells: Array[Vector2i],
		config: PlantDefenseConfig,
		track_support: bool = true
	) -> void:
		_register_plant_footprint(plant, cells, config)
		if track_support:
			_register_plant_terrain_support(plant)

	func connect_probe_lifecycle(plant: PlantDefense) -> void:
		plant.removal_started.connect(
			_on_plant_removal_started.bind(plant),
			CONNECT_ONE_SHOT
		)
		plant.tree_exiting.connect(
			_on_plant_tree_exiting.bind(plant),
			CONNECT_ONE_SHOT
		)

	func clear_probe_registries() -> void:
		occupied_cells.clear()
		plant_footprints.clear()
		plants_by_net_id.clear()
		_registered_plant_configs.clear()
		_unsupported_terrain_plants.clear()
		_terrain_support_plants_by_cell.clear()
		_terrain_support_cells_by_plant.clear()


func _init() -> void:
	call_deferred(&"_run")


func _run() -> void:
	await _test_transform_locality_and_lifecycle()
	await _test_shared_terrain_cell_fanout()
	await _test_ten_thousand_supported_plants_visit_zero()

	if failures.is_empty():
		print("PLANT_TERRAIN_SUPPORT_LOCALITY_SMOKE_TEST_OK")
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	quit(1)


func _test_transform_locality_and_lifecycle() -> void:
	var fixture := _build_fixture(
		"TransformLocalityFixture",
		Vector2(7.0, 13.0),
		Vector2(-11.0, 5.0),
		Vector2(50.0, -8.0)
	)
	var system := fixture["system"] as LocalityProbePlantSystem
	var ground := fixture["ground"] as TileMapLayer
	var terrain_a := fixture["terrain"] as TerrainProbe
	var container := fixture["container"] as Node2D
	var config := _make_grass_config()
	var terrain_cell := Vector2i(3, 4)
	var first_ground_cell := _terrain_cell_to_ground_cell(
		terrain_a,
		ground,
		terrain_cell
	)
	var expected_ground_cell := terrain_cell + Vector2i(2, -1)
	_expect(
		first_ground_cell == expected_ground_cell
		and first_ground_cell != terrain_cell,
		"不同transform下terrain cell必须经世界空间映射到正确且不同的占地格。"
	)
	var second_ground_cell := first_ground_cell + Vector2i.RIGHT
	var second_terrain_cell := _ground_cell_to_terrain_cell(
		ground,
		terrain_a,
		second_ground_cell
	)
	_expect(
		second_terrain_cell == terrain_cell + Vector2i.RIGHT,
		"多格footprint的相邻占地格必须独立映射回对应terrain cell。"
	)

	var plant := PlantDefense.new()
	plant.name = "TransformProbePlant"
	plant.config = config
	plant.footprint_cells.assign([first_ground_cell, second_ground_cell])
	plant.max_health = 1000
	plant.current_health = 1000
	plant.is_operational = true
	container.add_child(plant)
	system.register_probe(plant, plant.footprint_cells, config)
	system.connect_probe_lifecycle(plant)
	_expect(
		int(system.get_unsupported_terrain_metrics()["unsupported_plant_count"]) == 0,
		"合法放置的多格植物初始不能进入失地集合。"
	)

	terrain_a.set_probe_terrain(terrain_cell, DualGridTilemap.TerrainType.DIRT)
	var metrics := system.get_unsupported_terrain_metrics()
	_expect(
		int(metrics["unsupported_plant_count"]) == 1
		and int(metrics["last_change_affected_candidates"]) == 1
		and int(metrics["last_change_plants_recomputed"]) == 1,
		"单个terrain变化只能访问一个占地格，并重算命中的完整footprint。"
	)
	_expect(
		system.apply_unsupported_terrain_damage_tick() == 1
		and plant.current_health == 900,
		"首次失地tick必须对集合中的权威植物结算一次当前生命10%。"
	)
	metrics = system.get_unsupported_terrain_metrics()
	_expect(
		int(metrics["last_tick_plants_visited"]) == 1
		and int(metrics["last_tick_plants_damaged"]) == 1,
		"失地tick指标必须精确记录集合快照访问数与伤害数。"
	)
	_expect(
		system.apply_unsupported_terrain_damage_tick() == 1
		and plant.current_health == 810,
		"重复tick必须保持事件集合成员并按新的当前生命继续结算。"
	)

	terrain_a.set_probe_terrain(terrain_cell, DualGridTilemap.TerrainType.GRASS)
	_expect(
		int(system.get_unsupported_terrain_metrics()["unsupported_plant_count"]) == 0
		and system.apply_unsupported_terrain_damage_tick() == 0
		and int(
			system.get_unsupported_terrain_metrics()["last_tick_plants_visited"]
		) == 0,
		"失地格恢复后植物必须立即离开集合，后续tick访问0个植物。"
	)
	terrain_a.set_probe_terrain(
		second_terrain_cell,
		DualGridTilemap.TerrainType.DIRT
	)
	_expect(
		int(system.get_unsupported_terrain_metrics()["unsupported_plant_count"]) == 1,
		"多格footprint任意一个非首格失地都必须进入集合。"
	)
	terrain_a.set_probe_terrain(
		second_terrain_cell,
		DualGridTilemap.TerrainType.GRASS
	)
	_expect(
		int(system.get_unsupported_terrain_metrics()["unsupported_plant_count"]) == 0,
		"完整footprint恢复后必须退出失地集合。"
	)

	terrain_a.set_probe_terrain(
		terrain_cell + Vector2i(30, 30),
		DualGridTilemap.TerrainType.DIRT
	)
	metrics = system.get_unsupported_terrain_metrics()
	_expect(
		int(metrics["last_change_affected_candidates"]) == 0
		and int(metrics["last_change_plants_recomputed"]) == 0,
		"远处terrain变化必须命中空局部桶且不重算任何植物。"
	)

	var terrain_b := _make_terrain_probe(
		"TerrainB",
		Vector2(-11.0, 5.0),
		Vector2(50.0, -8.0)
	)
	root.add_child(terrain_b)
	system.setup(
		ground,
		null,
		container,
		Rect2i(-100, -100, 200, 200),
		terrain_b
	)
	var terrain_callback := Callable(system, "_on_terrain_changed")
	_expect(
		not terrain_a.terrain_changed.is_connected(terrain_callback)
		and terrain_b.terrain_changed.is_connected(terrain_callback)
		and int(
			system.get_unsupported_terrain_metrics()["last_rebuild_plants_visited"]
		) == 1,
		"setup切换terrain_map必须成对解绑旧信号、绑定新信号并一次性重建集合。"
	)
	terrain_b.set_probe_terrain(
		terrain_cell + Vector2i(40, 40),
		DualGridTilemap.TerrainType.DIRT
	)
	var before_old_signal := system.get_unsupported_terrain_metrics()
	terrain_a.set_probe_terrain(terrain_cell, DualGridTilemap.TerrainType.DIRT)
	_expect(
		system.get_unsupported_terrain_metrics() == before_old_signal
		and int(before_old_signal["unsupported_plant_count"]) == 0,
		"解绑后的旧terrain_map不得再改变集合或局部化指标。"
	)
	terrain_b.set_probe_terrain(terrain_cell, DualGridTilemap.TerrainType.DIRT)
	_expect(
		int(system.get_unsupported_terrain_metrics()["unsupported_plant_count"]) == 1,
		"新terrain_map的变化必须立即驱动失地集合。"
	)
	system.setup(
		ground,
		null,
		container,
		Rect2i(-100, -100, 200, 200),
		terrain_a
	)
	_expect(
		int(system.get_unsupported_terrain_metrics()["unsupported_plant_count"]) == 1,
		"切回已有失地状态的terrain_map时，一次性重建必须恢复正确集合。"
	)

	plant.current_health = 50
	_expect(
		system.apply_unsupported_terrain_damage_tick() == 1
		and plant.is_dead
		and not system.plant_footprints.has(plant)
		and int(
			system.get_unsupported_terrain_metrics()["unsupported_plant_count"]
		) == 0,
		"致死失地tick必须沿正常removal信号同步清理占地与失地集合。"
	)
	_expect(
		system.apply_unsupported_terrain_damage_tick() == 0
		and int(
			system.get_unsupported_terrain_metrics()["last_tick_plants_visited"]
		) == 0,
		"死亡清理后的重复tick不得保留悬空候选。"
	)
	plant.begin_removal(PlantDefense.RemovalMode.SILENT)
	fixture["root"].queue_free()
	terrain_b.queue_free()
	await process_frame


func _test_shared_terrain_cell_fanout() -> void:
	var fixture := _build_fixture(
		"SharedTerrainCellFixture",
		Vector2.ZERO,
		Vector2.ZERO,
		Vector2.ZERO,
		true,
		Vector2i(32, 32)
	)
	var system := fixture["system"] as LocalityProbePlantSystem
	var terrain := fixture["terrain"] as TerrainProbe
	var container := fixture["container"] as Node2D
	var config := _make_grass_config()
	var plants: Array[PlantDefense] = []
	for ground_cell in [Vector2i(0, 0), Vector2i(1, 0)]:
		var plant := PlantDefense.new()
		plant.config = config
		plant.footprint_cells.assign([ground_cell])
		plant.max_health = 500
		plant.current_health = 500
		plant.is_operational = true
		container.add_child(plant)
		system.register_probe(plant, plant.footprint_cells, config)
		system.connect_probe_lifecycle(plant)
		plants.append(plant)
	_expect(
		_ground_cell_to_terrain_cell(
			fixture["ground"] as TileMapLayer,
			terrain,
			Vector2i(0, 0)
		) == Vector2i.ZERO
		and _ground_cell_to_terrain_cell(
			fixture["ground"] as TileMapLayer,
			terrain,
			Vector2i(1, 0)
		) == Vector2i.ZERO,
		"32px terrain格必须能同时支撑两个独立16px占地格。"
	)
	terrain.set_probe_terrain(Vector2i.ZERO, DualGridTilemap.TerrainType.DIRT)
	var metrics := system.get_unsupported_terrain_metrics()
	_expect(
		int(metrics["last_change_affected_candidates"]) == 2
		and int(metrics["last_change_plants_recomputed"]) == 2
		and int(metrics["unsupported_plant_count"]) == 2,
		"共享terrain cell变化必须通过反向索引局部重算全部两个受影响植物。"
	)
	_expect(
		system.apply_unsupported_terrain_damage_tick() == 2
		and plants[0].current_health == 450
		and plants[1].current_health == 450
		and int(
			system.get_unsupported_terrain_metrics()["last_tick_plants_visited"]
		) == 2,
		"共享terrain cell下两个权威植物必须各结算一次且tick仅访问两个集合成员。"
	)
	terrain.set_probe_terrain(Vector2i.ZERO, DualGridTilemap.TerrainType.GRASS)
	_expect(
		int(system.get_unsupported_terrain_metrics()["unsupported_plant_count"]) == 0
		and system.apply_unsupported_terrain_damage_tick() == 0,
		"共享terrain cell恢复后两个植物都必须立即退出集合。"
	)
	for plant in plants:
		plant.begin_removal(PlantDefense.RemovalMode.SILENT)
	fixture["root"].queue_free()
	await process_frame


func _test_ten_thousand_supported_plants_visit_zero() -> void:
	var fixture := _build_fixture(
		"TenThousandSupportedFixture",
		Vector2.ZERO,
		Vector2.ZERO,
		Vector2.ZERO,
		false
	)
	var system := fixture["system"] as LocalityProbePlantSystem
	var ground := fixture["ground"] as TileMapLayer
	var terrain := fixture["terrain"] as TerrainProbe
	var container := fixture["container"] as Node2D
	var config := _make_grass_config()
	var plants: Array[PlantDefense] = []
	plants.resize(SUPPORTED_PLANT_COUNT)
	for index in range(SUPPORTED_PLANT_COUNT):
		var plant := PlantDefense.new()
		plant.config = config
		plant.max_health = 500
		plant.current_health = 500
		var cell := Vector2i(index % 100, index / 100)
		plant.footprint_cells.assign([cell])
		system.register_probe(plant, plant.footprint_cells, config, false)
		plants[index] = plant
	system.setup(
		ground,
		null,
		container,
		Rect2i(0, 0, 100, 100),
		terrain
	)
	var metrics := system.get_unsupported_terrain_metrics()
	_expect(
		int(metrics["last_rebuild_plants_visited"]) == SUPPORTED_PLANT_COUNT
		and int(metrics["tracked_plant_count"]) == SUPPORTED_PLANT_COUNT
		and int(metrics["unsupported_plant_count"]) == 0,
		"setup一次性重建必须检查全部10000个受支持植物，但集合保持为空。"
	)
	_expect(
		system.apply_unsupported_terrain_damage_tick() == 0,
		"10000个受支持植物的周期tick不得产生伤害。"
	)
	metrics = system.get_unsupported_terrain_metrics()
	_expect(
		int(metrics["last_tick_plants_visited"]) == 0
		and int(metrics["last_tick_plants_damaged"]) == 0,
		"10000个受支持植物存在时，周期tick访问数必须严格为0。"
	)

	system.clear_probe_registries()
	system.setup(
		ground,
		null,
		container,
		Rect2i(0, 0, 100, 100),
		terrain
	)
	for plant in plants:
		plant.free()
	fixture["root"].queue_free()
	await process_frame


func _build_fixture(
	fixture_name: String,
	ground_position: Vector2,
	terrain_position: Vector2,
	terrain_layer_position: Vector2,
	setup_immediately: bool = true,
	terrain_tile_size: Vector2i = TILE_SIZE
) -> Dictionary:
	var fixture_root := Node2D.new()
	fixture_root.name = fixture_name
	root.add_child(fixture_root)
	var ground := TileMapLayer.new()
	ground.name = "Ground"
	ground.tile_set = _make_tile_set()
	ground.position = ground_position
	fixture_root.add_child(ground)
	var terrain := _make_terrain_probe(
		"TerrainA",
		terrain_position,
		terrain_layer_position,
		terrain_tile_size
	)
	fixture_root.add_child(terrain)
	var container := Node2D.new()
	container.name = "Plants"
	fixture_root.add_child(container)
	var system := LocalityProbePlantSystem.new()
	system.name = "PlantSystem"
	fixture_root.add_child(system)
	if setup_immediately:
		system.setup(
			ground,
			null,
			container,
			Rect2i(-100, -100, 200, 200),
			terrain
		)
	return {
		"root": fixture_root,
		"ground": ground,
		"terrain": terrain,
		"container": container,
		"system": system,
	}


func _make_terrain_probe(
	node_name: String,
	terrain_position: Vector2,
	layer_position: Vector2,
	tile_size: Vector2i = TILE_SIZE
) -> TerrainProbe:
	var terrain := TerrainProbe.new()
	terrain.name = node_name
	terrain.position = terrain_position
	var world_layer := TileMapLayer.new()
	world_layer.name = "WorldMapLayer"
	world_layer.tile_set = _make_tile_set(tile_size)
	world_layer.position = layer_position
	terrain.add_child(world_layer)
	terrain.world_map_layer = world_layer
	return terrain


func _make_tile_set(tile_size: Vector2i = TILE_SIZE) -> TileSet:
	var tile_set := TileSet.new()
	tile_set.tile_size = tile_size
	return tile_set


func _make_grass_config() -> PlantDefenseConfig:
	var config := PlantDefenseConfig.new()
	config.plant_id = &"terrain_support_probe"
	config.footprint_size = Vector2i.ONE
	config.requires_grass = true
	config.requires_water_source = false
	return config


func _terrain_cell_to_ground_cell(
	terrain: DualGridTilemap,
	ground: TileMapLayer,
	terrain_cell: Vector2i
) -> Vector2i:
	var world_position := terrain.world_map_layer.to_global(
		terrain.world_map_layer.map_to_local(terrain_cell)
	)
	return ground.local_to_map(ground.to_local(world_position))


func _ground_cell_to_terrain_cell(
	ground: TileMapLayer,
	terrain: DualGridTilemap,
	ground_cell: Vector2i
) -> Vector2i:
	var world_position := ground.to_global(ground.map_to_local(ground_cell))
	return terrain.world_to_map(world_position)


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
