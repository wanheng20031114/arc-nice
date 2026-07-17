extends RefCounted
class_name PlantDefenseRegistry

const AGAVE_CANNON_ID: StringName = &"agave_cannon"
const CORN_MACHINE_GUN_ID: StringName = &"corn_machine_gun"
const OAK_WAREHOUSE_ID: StringName = &"oak_warehouse"
const VEGETATION_STAKE_ID: StringName = &"vegetation_stake"
const WOOD_PROCESSING_STATION_ID: StringName = &"wood_processing_station"
const WATER_COLLECTOR_ID: StringName = &"water_collector"

const AGAVE_CANNON_CONFIG: PlantDefenseConfig = preload(
	"res://resources/config/plant_defense/agave_cannon.tres"
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
const WATER_COLLECTOR_CONFIG: PlantDefenseConfig = preload(
	"res://resources/config/plant_defense/water_collector.tres"
)

const PLANT_CONFIGS := {
	AGAVE_CANNON_ID: AGAVE_CANNON_CONFIG,
	CORN_MACHINE_GUN_ID: CORN_MACHINE_GUN_CONFIG,
	OAK_WAREHOUSE_ID: OAK_WAREHOUSE_CONFIG,
	VEGETATION_STAKE_ID: VEGETATION_STAKE_CONFIG,
	WOOD_PROCESSING_STATION_ID: WOOD_PROCESSING_STATION_CONFIG,
	WATER_COLLECTOR_ID: WATER_COLLECTOR_CONFIG,
}


static func get_config(plant_id: StringName) -> PlantDefenseConfig:
	return PLANT_CONFIGS.get(plant_id) as PlantDefenseConfig


static func get_all_configs() -> Array[PlantDefenseConfig]:
	return [
		AGAVE_CANNON_CONFIG,
		CORN_MACHINE_GUN_CONFIG,
		OAK_WAREHOUSE_CONFIG,
		VEGETATION_STAKE_CONFIG,
		WOOD_PROCESSING_STATION_CONFIG,
		WATER_COLLECTOR_CONFIG,
	]


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
