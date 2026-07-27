extends SceneTree

const SIMPLE_FENCE_CONFIG := preload(
	"res://resources/config/plant_defense/simple_fence.tres"
)
const LOCAL_PLANT_COUNT := 32
const DISTANT_PLANT_COUNT := 10_000
const OVERVIEW_AABB := Rect2(Vector2(-80.0, -64.0), Vector2(160.0, 128.0))

var failures: Array[String] = []


class MinimapQueryPlantSystem:
	extends PlantSystem

	func register_probe(
		plant: PlantDefense,
		cell: Vector2i,
		config: PlantDefenseConfig
	) -> void:
		_register_plant_footprint(plant, [cell], config)


func _init() -> void:
	call_deferred(&"_run")


func _run() -> void:
	var baseline := _build_fixture(&"MinimapAabbBaseline")
	var loaded := _build_fixture(&"MinimapAabbWithDistantPlants")
	var baseline_system := baseline["system"] as MinimapQueryPlantSystem
	var loaded_system := loaded["system"] as MinimapQueryPlantSystem
	var local_config := SIMPLE_FENCE_CONFIG.duplicate(true) as PlantDefenseConfig
	local_config.cardinal_connection_group = &""
	_add_local_plants(baseline, local_config)
	_add_local_plants(loaded, local_config)
	_add_distant_plants(loaded, local_config)

	baseline_system.set_plant_target_query_metrics_enabled(true)
	loaded_system.set_plant_target_query_metrics_enabled(true)
	var baseline_result: Array[PlantDefense] = []
	var loaded_result: Array[PlantDefense] = []
	baseline_system.query_living_plants_in_world_aabb_into(
		OVERVIEW_AABB,
		baseline_result
	)
	var baseline_metrics := baseline_system.get_last_plant_target_query_metrics()
	loaded_system.query_living_plants_in_world_aabb_into(
		OVERVIEW_AABB,
		loaded_result
	)
	var loaded_metrics := loaded_system.get_last_plant_target_query_metrics()

	var baseline_signature := _plant_name_signature(baseline_result)
	var loaded_signature := _plant_name_signature(loaded_result)
	_expect(
		baseline_result.size() == LOCAL_PLANT_COUNT
		and loaded_result.size() == LOCAL_PLANT_COUNT
		and loaded_signature == baseline_signature,
		"精确overview AABB查询在增加10000个远处建筑后必须返回相同的32个局部建筑。"
	)
	_expect(
		int(baseline_metrics.get("candidates_visited", -1))
		== int(loaded_metrics.get("candidates_visited", -2))
		and int(baseline_metrics.get("results_written", -1))
		== int(loaded_metrics.get("results_written", -2))
		and int(loaded_metrics.get("candidates_visited", -1)) == LOCAL_PLANT_COUNT,
		"10000个远处建筑不得增加小地图局部AABB查询的候选访问量。baseline=%s loaded=%s"
		% [baseline_metrics, loaded_metrics]
	)
	var loaded_structure := loaded_system.get_plant_target_spatial_index_metrics()
	_expect(
		int(loaded_structure.get("registered_count", -1))
		== LOCAL_PLANT_COUNT + DISTANT_PLANT_COUNT
		and bool(loaded_structure.get("structure_counts_consistent", false)),
		"完整建筑索引必须保留全部10032个建筑，同时局部查询只访问32个候选。"
	)

	# Reuse the exact same caller-owned array. This guards the minimap's steady
	# sampling contract without accepting a hidden per-query result allocation.
	loaded_system.query_living_plants_in_world_aabb_into(
		OVERVIEW_AABB,
		loaded_result
	)
	_expect(
		loaded_result.size() == LOCAL_PLANT_COUNT
		and _plant_name_signature(loaded_result) == loaded_signature,
		"重复局部查询必须清空并复用caller-owned结果数组，且保持结果等价。"
	)

	print(
		"TOWER_DEFENSE_MINIMAP_PLANT_QUERY visible=%d candidates=%d distant=%d signature=%d"
		% [
			loaded_result.size(),
			int(loaded_metrics.get("candidates_visited", -1)),
			DISTANT_PLANT_COUNT,
			loaded_signature,
		]
	)
	(baseline["root"] as Node).queue_free()
	(loaded["root"] as Node).queue_free()
	for _cleanup_frame in range(6):
		await process_frame
	if failures.is_empty():
		print("TOWER_DEFENSE_MINIMAP_PLANT_QUERY_SMOKE_TEST_OK")
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	quit(1)


func _build_fixture(fixture_name: StringName) -> Dictionary:
	var fixture_root := Node2D.new()
	fixture_root.name = fixture_name
	root.add_child(fixture_root)
	var ground_tile_map := TileMapLayer.new()
	var tile_set := TileSet.new()
	tile_set.tile_size = Vector2i(16, 16)
	ground_tile_map.tile_set = tile_set
	fixture_root.add_child(ground_tile_map)
	var plant_container := Node2D.new()
	fixture_root.add_child(plant_container)
	var system := MinimapQueryPlantSystem.new()
	fixture_root.add_child(system)
	system.setup(
		ground_tile_map,
		null,
		plant_container,
		Rect2i(-20_000, -20_000, 40_000, 40_000)
	)
	return {
		"root": fixture_root,
		"container": plant_container,
		"system": system,
	}


func _add_local_plants(built: Dictionary, config: PlantDefenseConfig) -> void:
	var container := built["container"] as Node2D
	var system := built["system"] as MinimapQueryPlantSystem
	for index in range(LOCAL_PLANT_COUNT):
		var plant := PlantDefense.new()
		plant.name = "LocalPlant%02d" % index
		container.add_child(plant)
		plant.global_position = Vector2(
			float(index % 8) * 12.0 - 42.0,
			float(index / 8) * 12.0 - 18.0
		)
		plant.setup(config, null, [Vector2i(index, 0)], false, 500, 0, 500, false)
		system.register_probe(plant, Vector2i(index, 0), config)


func _add_distant_plants(built: Dictionary, config: PlantDefenseConfig) -> void:
	var container := built["container"] as Node2D
	var system := built["system"] as MinimapQueryPlantSystem
	for index in range(DISTANT_PLANT_COUNT):
		var plant := PlantDefense.new()
		plant.name = "DistantPlant%d" % index
		container.add_child(plant)
		plant.global_position = Vector2(
			100_000.0 + float(index % 100) * 8.0,
			100_000.0 + float(index / 100) * 8.0
		)
		var cell := Vector2i(1000 + index, 10)
		plant.setup(config, null, [cell], false, 500, 0, 500, false)
		system.register_probe(plant, cell, config)


func _plant_name_signature(plants: Array[PlantDefense]) -> int:
	var names := PackedStringArray()
	for plant in plants:
		names.append(plant.name)
	names.sort()
	return hash(names)


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
