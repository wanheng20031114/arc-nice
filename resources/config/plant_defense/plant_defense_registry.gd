extends RefCounted
class_name PlantDefenseRegistry

const AGAVE_CANNON_ID: StringName = &"agave_cannon"
const BAMBOO_MORTAR_ID: StringName = &"bamboo_mortar"
const CORN_MACHINE_GUN_ID: StringName = &"corn_machine_gun"
const OAK_WAREHOUSE_ID: StringName = &"oak_warehouse"
const VEGETATION_STAKE_ID: StringName = &"vegetation_stake"
const WOOD_PROCESSING_STATION_ID: StringName = &"wood_processing_station"
const STONE_MILL_ID: StringName = &"stone_mill"
const SIMPLE_FENCE_ID: StringName = &"simple_fence"
const WATER_COLLECTOR_ID: StringName = &"water_collector"
const RESEARCH_CENTER_ID: StringName = &"research_center"
const PLANT_CULTIVATION_CENTER_ID: StringName = &"plant_cultivation_center"
const PLANTING_BASE_ID: StringName = &"planting_base"
const HYDRANGEA_RAIN_TOWER_ID: StringName = &"hydrangea_rain_tower"
const GRAPE_ARC_TOWER_ID: StringName = &"grape_arc_tower"
const EXCAVATOR_ID: StringName = &"excavator"

const AGAVE_CANNON_CONFIG: PlantDefenseConfig = preload(
	"res://resources/config/plant_defense/agave_cannon.tres"
)
const BAMBOO_MORTAR_CONFIG: PlantDefenseConfig = preload(
	"res://resources/config/plant_defense/bamboo_mortar.tres"
)
const CORN_MACHINE_GUN_CONFIG: PlantDefenseConfig = preload(
	"res://resources/config/plant_defense/corn_machine_gun.tres"
)
const OAK_WAREHOUSE_CONFIG: PlantDefenseConfig = preload(
	"res://resources/config/plant_defense/oak_warehouse.tres"
)
const VEGETATION_STAKE_CONFIG: PlantDefenseConfig = preload(
	"res://resources/config/plant_defense/vegetation_stake.tres"
)
const WOOD_PROCESSING_STATION_CONFIG: PlantDefenseConfig = preload(
	"res://resources/config/plant_defense/wood_processing_station.tres"
)
const STONE_MILL_CONFIG: PlantDefenseConfig = preload(
	"res://resources/config/plant_defense/stone_mill.tres"
)
const SIMPLE_FENCE_CONFIG: PlantDefenseConfig = preload(
	"res://resources/config/plant_defense/simple_fence.tres"
)
const WATER_COLLECTOR_CONFIG: PlantDefenseConfig = preload(
	"res://resources/config/plant_defense/water_collector.tres"
)
const RESEARCH_CENTER_CONFIG: PlantDefenseConfig = preload(
	"res://resources/config/plant_defense/research_center.tres"
)
const PLANT_CULTIVATION_CENTER_CONFIG: PlantDefenseConfig = preload(
	"res://resources/config/plant_defense/plant_cultivation_center.tres"
)
const PLANTING_BASE_CONFIG: PlantDefenseConfig = preload(
	"res://resources/config/plant_defense/planting_base.tres"
)
const HYDRANGEA_RAIN_TOWER_CONFIG: PlantDefenseConfig = preload(
	"res://resources/config/plant_defense/hydrangea_rain_tower.tres"
)
const GRAPE_ARC_TOWER_CONFIG: PlantDefenseConfig = preload(
	"res://resources/config/plant_defense/grape_arc_tower.tres"
)
const EXCAVATOR_CONFIG: PlantDefenseConfig = preload(
	"res://resources/config/plant_defense/excavator.tres"
)

const PLANT_CONFIGS := {
	AGAVE_CANNON_ID: AGAVE_CANNON_CONFIG,
	CORN_MACHINE_GUN_ID: CORN_MACHINE_GUN_CONFIG,
	OAK_WAREHOUSE_ID: OAK_WAREHOUSE_CONFIG,
	VEGETATION_STAKE_ID: VEGETATION_STAKE_CONFIG,
	WOOD_PROCESSING_STATION_ID: WOOD_PROCESSING_STATION_CONFIG,
	STONE_MILL_ID: STONE_MILL_CONFIG,
	SIMPLE_FENCE_ID: SIMPLE_FENCE_CONFIG,
	WATER_COLLECTOR_ID: WATER_COLLECTOR_CONFIG,
	RESEARCH_CENTER_ID: RESEARCH_CENTER_CONFIG,
	PLANT_CULTIVATION_CENTER_ID: PLANT_CULTIVATION_CENTER_CONFIG,
	BAMBOO_MORTAR_ID: BAMBOO_MORTAR_CONFIG,
	HYDRANGEA_RAIN_TOWER_ID: HYDRANGEA_RAIN_TOWER_CONFIG,
	GRAPE_ARC_TOWER_ID: GRAPE_ARC_TOWER_CONFIG,
	EXCAVATOR_ID: EXCAVATOR_CONFIG,
	PLANTING_BASE_ID: PLANTING_BASE_CONFIG,
}


static func get_config(plant_id: StringName) -> PlantDefenseConfig:
	return PLANT_CONFIGS.get(plant_id) as PlantDefenseConfig


static func get_all_configs() -> Array[PlantDefenseConfig]:
	var configs: Array[PlantDefenseConfig] = []
	for config_variant in PLANT_CONFIGS.values():
		var config := config_variant as PlantDefenseConfig
		if config != null:
			configs.append(config)
	configs.sort_custom(_config_precedes)
	return configs


static func _config_precedes(
	left: PlantDefenseConfig,
	right: PlantDefenseConfig
) -> bool:
	if left.building_category != right.building_category:
		return left.building_category < right.building_category
	if left.menu_order != right.menu_order:
		return left.menu_order < right.menu_order
	return String(left.plant_id) < String(right.plant_id)


static func is_valid_plant_id(plant_id: StringName) -> bool:
	var config := get_config(plant_id)
	return config != null and config.is_valid()


static func instantiate_plant(plant_id: StringName) -> PlantDefense:
	var config := get_config(plant_id)
	if config == null:
		push_error("Unknown plant defense id: %s" % plant_id)
		return null
	if not config.is_valid():
		push_error("Plant defense config is invalid: %s" % plant_id)
		return null

	var instance := config.plant_scene.instantiate()
	var plant := instance as PlantDefense
	if plant == null:
		push_error("Plant defense scene root must inherit PlantDefense: %s" % plant_id)
		instance.free()
	return plant
