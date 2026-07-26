extends SceneTree

const INTERACTION_BUILDING_CONFIG := preload(
	"res://resources/config/plant_defense/wood_processing_station.tres"
)

const MP_GAME_PATH := "res://scene/multiplayer/mp_game.gd"
const INTERACTION_DISTANCE := 48.0
const FAR_BUILDING_COUNT := 512
const PERFORMANCE_ITERATIONS := 2_000


class QueryProbePlantSystem:
	extends PlantSystem

	func register_probe_plant(plant: PlantDefense) -> void:
		_register_plant_footprint(
			plant,
			[Vector2i.ZERO],
			INTERACTION_BUILDING_CONFIG
		)

	func move_probe_plant(plant: PlantDefense, world_position: Vector2) -> void:
		plant.global_position = world_position
		_plant_target_spatial_index.update(plant, world_position)


class TestMpGame:
	extends "res://scene/multiplayer/mp_game.gd"

	func accepts_warehouse(player: Player, building: OakWarehouse) -> bool:
		return _is_authoritative_nearest_warehouse(player, building)

	func accepts_production(player: Player, building: ProductionBuilding) -> bool:
		return _is_authoritative_nearest_production_building(player, building)

	func accepts_research(player: Player, building: ResearchCenter) -> bool:
		return _is_authoritative_nearest_research_center(player, building)


var failures: Array[String] = []
var plant_system := QueryProbePlantSystem.new()
var runtime := GameTowerDefense.new()
var mp_game := TestMpGame.new()
var player := Player.new()
var all_buildings: Array[PlantDefense] = []


func _init() -> void:
	call_deferred(&"_run")


func _run() -> void:
	runtime.plant_system = plant_system
	mp_game.game = runtime
	player.global_position = Vector2.ZERO

	var warehouse := OakWarehouse.new()
	var production := ProductionBuilding.new()
	var research := ResearchCenter.new()
	_register_building(warehouse, Vector2(24.0, 0.0), 10)
	_register_building(production, Vector2(16.0, 0.0), 20)
	_register_building(research, Vector2(8.0, 0.0), 30)

	_test_cross_type_authority(warehouse, production, research)
	_test_lifecycle_and_tie_breaks(warehouse, production, research)
	_test_spatial_population_independence(warehouse)
	_test_authority_source_delegation()
	_cleanup()

	if failures.is_empty():
		print("MULTIPLAYER_BUILDING_INTERACTION_SPATIAL_SMOKE_TEST_OK")
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	quit(1)


func _test_cross_type_authority(
	warehouse: OakWarehouse,
	production: ProductionBuilding,
	research: ResearchCenter
) -> void:
	_expect(
		mp_game.accepts_research(player, research),
		"最近的研究中心必须通过 Host 授权。"
	)
	_expect(
		not mp_game.accepts_production(player, production)
		and not mp_game.accepts_warehouse(player, warehouse),
		"更近的另一类型交互建筑存在时，Host 必须拒绝较远的生产/仓库请求。"
	)

	var non_interactive := PlantDefense.new()
	non_interactive.is_operational = true
	non_interactive.global_position = Vector2.ZERO
	plant_system.register_probe_plant(non_interactive)
	all_buildings.append(non_interactive)
	_expect(
		mp_game.accepts_research(player, research),
		"更近的普通防御植物不得阻塞建筑交互选择。"
	)


func _test_lifecycle_and_tie_breaks(
	warehouse: OakWarehouse,
	production: ProductionBuilding,
	research: ResearchCenter
) -> void:
	research.is_operational = false
	_expect(
		mp_game.accepts_production(player, production),
		"未投入运行的最近建筑必须被过滤并选择下一座生产建筑。"
	)
	production.is_removing = true
	_expect(
		mp_game.accepts_warehouse(player, warehouse),
		"正在拆除的最近建筑必须被过滤并选择下一座仓库。"
	)

	research.is_operational = true
	production.is_removing = false
	plant_system.move_probe_plant(warehouse, Vector2(-16.0, 0.0))
	plant_system.move_probe_plant(research, Vector2(16.0, 0.0))
	plant_system.move_probe_plant(production, Vector2(40.0, 0.0))
	warehouse.set_meta(&"net_id", 10)
	research.set_meta(&"net_id", 30)
	_expect(
		mp_game.accepts_warehouse(player, warehouse)
		and not mp_game.accepts_research(player, research),
		"等距跨类型建筑必须按较小网络 ID 选择，保持客户端与 Host 一致。"
	)
	warehouse.set_meta(&"net_id", 40)
	research.set_meta(&"net_id", 5)
	_expect(
		mp_game.accepts_research(player, research)
		and not mp_game.accepts_warehouse(player, warehouse),
		"网络 ID 变化后，等距选择必须稳定切换到较小 ID。"
	)

	plant_system.move_probe_plant(research, Vector2(INTERACTION_DISTANCE, 0.0))
	warehouse.is_dead = true
	production.is_dead = true
	_expect(
		mp_game.accepts_research(player, research),
		"Host 交互圆必须精确包含 48 像素边界。"
	)
	plant_system.move_probe_plant(
		research,
		Vector2(INTERACTION_DISTANCE + 0.01, 0.0)
	)
	_expect(
		not mp_game.accepts_research(player, research),
		"Host 交互圆必须拒绝刚刚越过 48 像素边界的建筑。"
	)
	warehouse.is_dead = false
	production.is_dead = false
	plant_system.move_probe_plant(warehouse, Vector2(-16.0, 0.0))
	plant_system.move_probe_plant(research, Vector2(16.0, 0.0))


func _test_spatial_population_independence(expected_nearest: PlantDefense) -> void:
	# Restore the lower authoritative ID before comparing the indexed and legacy
	# selectors. Every distant building remains operational and eligible, so the
	# baseline really does inspect the complete population.
	expected_nearest.set_meta(&"net_id", 1)
	for index in range(FAR_BUILDING_COUNT):
		var far_building := PlantDefense.new()
		_register_building(
			far_building,
			Vector2(
				512.0 + float(index % 32) * 64.0,
				512.0 + float(index / 32) * 64.0
			),
			1000 + index
		)

	plant_system.set_plant_target_query_metrics_enabled(true)
	var indexed_nearest := (
		plant_system.find_nearest_operational_interaction_building_world(
			player.global_position,
			INTERACTION_DISTANCE
		)
	)
	var metrics := plant_system.get_last_plant_target_query_metrics()
	var candidates_visited := int(metrics.get("candidates_visited", -1))
	_expect(
		indexed_nearest == expected_nearest
		and metrics.get("query_mode") == &"buckets"
		and candidates_visited >= 0
		and candidates_visited <= 4
		and candidates_visited < all_buildings.size(),
		"远处 512 座建筑不得扩张 48 像素局部查询；空间哈希只能访问邻近桶候选。"
	)

	plant_system.set_plant_target_query_metrics_enabled(false)
	for _warmup in range(32):
		plant_system.find_nearest_operational_interaction_building_world(
			player.global_position,
			INTERACTION_DISTANCE
		)
		_legacy_full_scan_nearest()
	var indexed_started := Time.get_ticks_usec()
	for _iteration in range(PERFORMANCE_ITERATIONS):
		plant_system.find_nearest_operational_interaction_building_world(
			player.global_position,
			INTERACTION_DISTANCE
		)
	var indexed_elapsed := Time.get_ticks_usec() - indexed_started
	var legacy_started := Time.get_ticks_usec()
	for _iteration in range(PERFORMANCE_ITERATIONS):
		_legacy_full_scan_nearest()
	var legacy_elapsed := Time.get_ticks_usec() - legacy_started
	print(
		(
			"BUILDING_INTERACTION_SPATIAL_AB indexed_us=%d "
			+ "legacy_full_scan_us=%d speedup=%.2fx candidates=%d population=%d"
		) % [
			indexed_elapsed,
			legacy_elapsed,
			float(legacy_elapsed) / float(maxi(indexed_elapsed, 1)),
			candidates_visited,
			all_buildings.size(),
		]
	)
	_expect(
		indexed_elapsed < legacy_elapsed,
		"局部空间哈希 A/B 必须快于完整建筑集合扫描。"
	)


func _legacy_full_scan_nearest() -> PlantDefense:
	var nearest: PlantDefense = null
	var nearest_distance_squared := INF
	var maximum_distance_squared := INTERACTION_DISTANCE * INTERACTION_DISTANCE
	for building in all_buildings:
		if not PlantDefense.is_operational_interaction_candidate(building):
			continue
		var distance_squared := player.global_position.distance_squared_to(
			building.global_position
		)
		if distance_squared > maximum_distance_squared:
			continue
		if PlantDefense.is_interaction_candidate_preferred(
			building,
			distance_squared,
			nearest,
			nearest_distance_squared
		):
			nearest = building
			nearest_distance_squared = distance_squared
	return nearest


func _test_authority_source_delegation() -> void:
	var source := FileAccess.get_file_as_string(MP_GAME_PATH)
	for function_name in [
		"_is_authoritative_nearest_warehouse",
		"_is_authoritative_nearest_production_building",
		"_is_authoritative_nearest_research_center",
	]:
		var function_source := _extract_function_source(source, function_name)
		_expect(
			function_source.contains(
				"_find_authoritative_nearest_interaction_building"
			)
			and not function_source.contains("get_multiplayer_plant_snapshots"),
			"%s 必须委托统一空间查询，禁止恢复完整植物快照扫描。" % function_name
		)


func _extract_function_source(source: String, function_name: String) -> String:
	var start := source.find("func %s(" % function_name)
	if start < 0:
		return ""
	var next_function := source.find("\nfunc ", start + 1)
	if next_function < 0:
		return source.substr(start)
	return source.substr(start, next_function - start)


func _register_building(
	building: PlantDefense,
	world_position: Vector2,
	net_id: int
) -> void:
	building.global_position = world_position
	building.is_operational = true
	building.add_to_group(PlantDefense.BUILDING_INTERACTION_GROUP)
	building.set_meta(&"net_id", net_id)
	plant_system.register_probe_plant(building)
	all_buildings.append(building)


func _cleanup() -> void:
	for building in all_buildings:
		if building != null and is_instance_valid(building):
			building.free()
	all_buildings.clear()
	if mp_game != null and is_instance_valid(mp_game):
		mp_game.free()
	if runtime != null and is_instance_valid(runtime):
		runtime.free()
	if plant_system != null and is_instance_valid(plant_system):
		plant_system.free()
	if player != null and is_instance_valid(player):
		player.free()


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
