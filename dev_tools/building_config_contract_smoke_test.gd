extends SceneTree

const EXPECTED_SORTED_IDS: Array[StringName] = [
	&"agave_cannon",
	&"corn_machine_gun",
	&"bamboo_mortar",
	&"grape_arc_tower",
	&"hydrangea_rain_tower",
	&"orange_charging_tower",
	&"wood_processing_station",
	&"water_collector",
	&"planting_base",
	&"plant_cultivation_center",
	&"excavator",
	&"stone_mill",
	&"research_center",
	&"simple_fence",
	&"vegetation_stake",
	&"oak_warehouse",
]
const EXPECTED_CATEGORY_BY_ID := {
	&"agave_cannon": PlantDefenseConfig.BuildingCategory.DEFENSE_TOWER,
	&"corn_machine_gun": PlantDefenseConfig.BuildingCategory.DEFENSE_TOWER,
	&"bamboo_mortar": PlantDefenseConfig.BuildingCategory.DEFENSE_TOWER,
	&"grape_arc_tower": PlantDefenseConfig.BuildingCategory.DEFENSE_TOWER,
	&"hydrangea_rain_tower": PlantDefenseConfig.BuildingCategory.SUPPORT_TOWER,
	&"orange_charging_tower": PlantDefenseConfig.BuildingCategory.SUPPORT_TOWER,
	&"wood_processing_station": PlantDefenseConfig.BuildingCategory.PRODUCTION_BUILDING,
	&"water_collector": PlantDefenseConfig.BuildingCategory.PRODUCTION_BUILDING,
	&"planting_base": PlantDefenseConfig.BuildingCategory.PRODUCTION_BUILDING,
	&"plant_cultivation_center": PlantDefenseConfig.BuildingCategory.PRODUCTION_BUILDING,
	&"excavator": PlantDefenseConfig.BuildingCategory.PRODUCTION_BUILDING,
	&"stone_mill": PlantDefenseConfig.BuildingCategory.PRODUCTION_BUILDING,
	&"research_center": PlantDefenseConfig.BuildingCategory.TECHNOLOGY_BUILDING,
	&"simple_fence": PlantDefenseConfig.BuildingCategory.FENCE,
	&"vegetation_stake": PlantDefenseConfig.BuildingCategory.TERRAIN_BUILDING,
	&"oak_warehouse": PlantDefenseConfig.BuildingCategory.STORAGE_BUILDING,
}
const EXPECTED_SURFACE_BY_ID := {
	&"agave_cannon": PlantDefenseConfig.PlacementSurface.GRASS_ONLY,
	&"corn_machine_gun": PlantDefenseConfig.PlacementSurface.GRASS_ONLY,
	&"bamboo_mortar": PlantDefenseConfig.PlacementSurface.GRASS_ONLY,
	&"grape_arc_tower": PlantDefenseConfig.PlacementSurface.GRASS_ONLY,
	&"hydrangea_rain_tower": PlantDefenseConfig.PlacementSurface.GRASS_ONLY,
	&"orange_charging_tower": PlantDefenseConfig.PlacementSurface.GRASS_ONLY,
	&"wood_processing_station": PlantDefenseConfig.PlacementSurface.ANY_LAND,
	&"water_collector": PlantDefenseConfig.PlacementSurface.WATER_ONLY,
	&"planting_base": PlantDefenseConfig.PlacementSurface.GRASS_ONLY,
	&"plant_cultivation_center": PlantDefenseConfig.PlacementSurface.GRASS_ONLY,
	&"excavator": PlantDefenseConfig.PlacementSurface.ANY_LAND,
	&"stone_mill": PlantDefenseConfig.PlacementSurface.ANY_LAND,
	&"research_center": PlantDefenseConfig.PlacementSurface.GRASS_ONLY,
	&"simple_fence": PlantDefenseConfig.PlacementSurface.ANY_LAND,
	&"vegetation_stake": PlantDefenseConfig.PlacementSurface.GRASS_ONLY,
	&"oak_warehouse": PlantDefenseConfig.PlacementSurface.ANY_LAND,
}
const EXPECTED_MENU_ORDER_BY_ID := {
	&"agave_cannon": 10,
	&"corn_machine_gun": 20,
	&"bamboo_mortar": 30,
	&"grape_arc_tower": 40,
	&"hydrangea_rain_tower": 10,
	&"orange_charging_tower": 20,
	&"wood_processing_station": 10,
	&"water_collector": 20,
	&"planting_base": 30,
	&"plant_cultivation_center": 40,
	&"excavator": 50,
	&"stone_mill": 60,
	&"research_center": 10,
	&"simple_fence": 10,
	&"vegetation_stake": 10,
	&"oak_warehouse": 10,
}
const EXPECTED_TOWER_PHYSICAL_DEFENSE_BY_ID := {
	&"agave_cannon": 10,
	&"corn_machine_gun": 10,
	&"bamboo_mortar": 20,
	&"grape_arc_tower": 10,
	&"hydrangea_rain_tower": 10,
	&"orange_charging_tower": 10,
}
const EXPECTED_CATEGORY_COUNTS := {
	PlantDefenseConfig.BuildingCategory.DEFENSE_TOWER: 4,
	PlantDefenseConfig.BuildingCategory.SUPPORT_TOWER: 2,
	PlantDefenseConfig.BuildingCategory.PRODUCTION_BUILDING: 6,
	PlantDefenseConfig.BuildingCategory.TECHNOLOGY_BUILDING: 1,
	PlantDefenseConfig.BuildingCategory.FENCE: 1,
	PlantDefenseConfig.BuildingCategory.TERRAIN_BUILDING: 1,
	PlantDefenseConfig.BuildingCategory.STORAGE_BUILDING: 1,
}
const ANY_LAND_IDS: Array[StringName] = [
	&"simple_fence",
	&"oak_warehouse",
	&"wood_processing_station",
	&"stone_mill",
	&"excavator",
]
const DIRT_BLOCK: PickupConfig = preload(
	"res://resources/config/materials/material_dirt_block.tres"
)
const WHITE_CRYSTAL_POWDER: PickupConfig = preload(
	"res://resources/config/materials/material_white_crystal_powder.tres"
)
const WOODEN_CORE: PickupConfig = preload(
	"res://resources/config/materials/material_wooden_core.tres"
)
const WATER_BOTTLE: PickupConfig = preload(
	"res://resources/config/materials/material_water_bottle.tres"
)
const SORCERER_VIOLET_POWDER: PickupConfig = preload(
	"res://resources/config/materials/material_sorcerer_violet_powder.tres"
)

var failures: Array[String] = []


class TerrainProbe:
	extends DualGridTilemap

	var terrain_by_cell: Dictionary[Vector2i, int] = {}

	func get_terrain_type(cell_pos: Vector2i) -> int:
		return terrain_by_cell.get(cell_pos, DualGridTilemap.TerrainType.EMPTY)

	func is_cell_plantable(cell_pos: Vector2i) -> bool:
		return get_terrain_type(cell_pos) == DualGridTilemap.TerrainType.GRASS


class PlacementProbe:
	extends PlantSystem

	func supports(cell: Vector2i, config: PlantDefenseConfig) -> bool:
		return _is_terrain_supported_for_config(cell, config)


func _init() -> void:
	call_deferred(&"_run")


func _run() -> void:
	_test_registry_semantics()
	_test_surface_semantics()
	_test_building_item_and_acquisition_closure()
	if failures.is_empty():
		print("BUILDING_CONFIG_CONTRACT_SMOKE_TEST_OK")
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	quit(1)


func _test_registry_semantics() -> void:
	var configs := PlantDefenseRegistry.get_all_configs()
	var actual_ids: Array[StringName] = []
	var category_counts := {}
	var seen_ids := {}
	for config in configs:
		actual_ids.append(config.plant_id)
		category_counts[config.building_category] = (
			int(category_counts.get(config.building_category, 0)) + 1
		)
		_expect(not seen_ids.has(config.plant_id), "建筑ID不得重复：%s。" % config.plant_id)
		seen_ids[config.plant_id] = true
		_expect(config.is_valid(), "正式建筑配置必须完整有效：%s。" % config.plant_id)
		_expect(
			config.building_category == EXPECTED_CATEGORY_BY_ID.get(config.plant_id),
			"建筑分类不符合语义契约：%s。" % config.plant_id
		)
		_expect(
			config.placement_surface == EXPECTED_SURFACE_BY_ID.get(config.plant_id),
			"放置地形不符合语义契约：%s。" % config.plant_id
		)
		_expect(
			config.menu_order == int(EXPECTED_MENU_ORDER_BY_ID.get(config.plant_id, 0)),
			"类内菜单顺序不符合10步长契约：%s。" % config.plant_id
		)
		if EXPECTED_TOWER_PHYSICAL_DEFENSE_BY_ID.has(config.plant_id):
			_expect(
				config.physical_defense
				== int(EXPECTED_TOWER_PHYSICAL_DEFENSE_BY_ID[config.plant_id]),
				"炮台基础物防不符合数值契约：%s。" % config.plant_id
			)
	_expect(configs.size() == 16, "正式建筑注册表必须恰好包含16项。")
	_expect(
		actual_ids == EXPECTED_SORTED_IDS,
		"注册表必须按类别、类内顺序、ID确定性排序。actual=%s" % [actual_ids]
	)
	_expect(
		category_counts == EXPECTED_CATEGORY_COUNTS,
		"七类建筑数量必须固定为4/2/6/1/1/1/1。actual=%s" % [category_counts]
	)


func _test_surface_semantics() -> void:
	var terrain := TerrainProbe.new()
	var system := PlacementProbe.new()
	system.terrain_map = terrain
	var cell := Vector2i(3, 5)
	for plant_id in ANY_LAND_IDS:
		var config := PlantDefenseRegistry.get_config(plant_id)
		for land_type in [
			DualGridTilemap.TerrainType.GRASS,
			DualGridTilemap.TerrainType.DIRT,
			DualGridTilemap.TerrainType.METAL,
		]:
			terrain.terrain_by_cell[cell] = land_type
			_expect(
				system.supports(cell, config),
				"任意陆地建筑%s必须接受地形%d。" % [plant_id, land_type]
			)
		terrain.terrain_by_cell[cell] = DualGridTilemap.TerrainType.WATER
		_expect(
			not system.supports(cell, config),
			"任意陆地建筑%s必须拒绝水面。" % plant_id
		)
	var grass_config := PlantDefenseRegistry.get_config(&"agave_cannon")
	for rejected_type in [
		DualGridTilemap.TerrainType.DIRT,
		DualGridTilemap.TerrainType.METAL,
		DualGridTilemap.TerrainType.WATER,
	]:
		terrain.terrain_by_cell[cell] = rejected_type
		_expect(
			not system.supports(cell, grass_config),
			"仅草地建筑必须拒绝非草地%d。" % rejected_type
		)
	terrain.terrain_by_cell[cell] = DualGridTilemap.TerrainType.GRASS
	_expect(system.supports(cell, grass_config), "仅草地建筑必须接受草地。")

	var water_config := PlantDefenseRegistry.get_config(&"water_collector")
	var water_cells := [
		Vector2i.ZERO,
		Vector2i.RIGHT,
		Vector2i.DOWN,
		Vector2i.ONE,
	]
	for water_cell in water_cells:
		terrain.terrain_by_cell[water_cell] = DualGridTilemap.TerrainType.WATER
	_expect(
		_footprint_is_supported(system, water_config, water_cells),
		"水源采集器必须接受完整2×2水面。"
	)
	terrain.terrain_by_cell[Vector2i.ONE] = DualGridTilemap.TerrainType.DIRT
	_expect(
		not _footprint_is_supported(system, water_config, water_cells),
		"水源采集器的2×2占格只要一格不是水面就必须拒绝。"
	)
	system.free()
	terrain.free()


func _test_building_item_and_acquisition_closure() -> void:
	_expect(
		BuildingItemRegistry.validate_contract(),
		"建筑物品必须与16个plant_id形成一一对应，且每项至少有一条获取路线。"
	)
	_expect(
		BuildingItemRegistry.get_all_items().size() == 16,
		"建筑物品Registry必须恰好公开16项。"
	)
	var reachable_recipe_paths := {}
	for recipe in SimpleCraftingRegistry.get_all_recipes():
		reachable_recipe_paths[recipe.resource_path] = true
	for producer_id in [&"wood_processing_station", &"plant_cultivation_center"]:
		var producer_config := PlantDefenseRegistry.get_config(producer_id)
		var producer := producer_config.plant_scene.instantiate() as ProductionBuilding
		_expect(producer != null, "获取路线生产建筑必须继承ProductionBuilding：%s。" % producer_id)
		if producer == null:
			continue
		for recipe in producer.recipes:
			reachable_recipe_paths[recipe.resource_path] = true
		producer.free()
	for config in PlantDefenseRegistry.get_all_configs():
		var item := BuildingItemRegistry.get_item(config.plant_id)
		var recipe := BuildingItemRegistry.get_primary_acquisition_recipe(config.plant_id)
		_expect(item != null, "正式建筑缺少唯一建筑物品：%s。" % config.plant_id)
		_expect(recipe != null, "正式建筑缺少有效获取配方：%s。" % config.plant_id)
		if recipe != null:
			_expect(
				reachable_recipe_paths.has(recipe.resource_path),
				"登记的建筑获取配方未接入实际生产入口：%s。" % config.plant_id
			)
	var grape_recipe := BuildingItemRegistry.get_primary_acquisition_recipe(
		&"grape_arc_tower"
	)
	_expect(
		grape_recipe != null
		and grape_recipe.input_items.has(DIRT_BLOCK)
		and grape_recipe.input_items.has(WHITE_CRYSTAL_POWDER),
		"葡萄培育路线必须为土块和白晶粉提供真实消费端。"
	)
	var hydrangea_recipe := BuildingItemRegistry.get_primary_acquisition_recipe(
		&"hydrangea_rain_tower"
	)
	_expect(
		hydrangea_recipe != null
		and hydrangea_recipe.input_items == [WOODEN_CORE, WATER_BOTTLE]
		and hydrangea_recipe.input_amounts == [2, 2]
		and hydrangea_recipe.output_items
		== [BuildingItemRegistry.HYDRANGEA_RAIN_TOWER_ITEM]
		and hydrangea_recipe.output_amounts == [1]
		and is_equal_approx(hydrangea_recipe.duration_seconds, 30.0)
		and hydrangea_recipe.outputs_to_player_inventory(),
		"紫阳花雨幕塔必须在植物培育中心消耗2个木制核心和2个水瓶，并培育30秒。"
	)
	var orange_recipe := BuildingItemRegistry.get_primary_acquisition_recipe(
		&"orange_charging_tower"
	)
	_expect(
		orange_recipe != null
		and orange_recipe.input_items == [WOODEN_CORE, SORCERER_VIOLET_POWDER]
		and orange_recipe.input_amounts == [1, 1]
		and orange_recipe.output_items
		== [BuildingItemRegistry.ORANGE_CHARGING_TOWER_ITEM]
		and orange_recipe.output_amounts == [1]
		and is_equal_approx(orange_recipe.duration_seconds, 30.0)
		and orange_recipe.outputs_to_player_inventory(),
		"橘充能塔必须在植物培育中心消耗1个木制核心和1份术士紫晶粉，并培育30秒。"
	)


func _footprint_is_supported(
	system: PlacementProbe,
	config: PlantDefenseConfig,
	cells: Array
) -> bool:
	for cell_variant in cells:
		if not system.supports(cell_variant as Vector2i, config):
			return false
	return true


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
