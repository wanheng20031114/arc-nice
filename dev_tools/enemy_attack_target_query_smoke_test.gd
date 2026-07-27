extends SceneTree

const TILE_SIZE := 16.0
const CHAIN_RADIUS_CELLS := 3.0
const ATTACK_RADIUS_CELLS := 7.0
const FAR_PLANT_COUNT := 256
const PROACTIVE_CONFIG := preload(
	"res://resources/config/plant_defense/agave_cannon.tres"
)

var failures: Array[String] = []
var fixture: Node2D = null
var tile_map: TileMapLayer = null
var plant_container: Node2D = null
var plant_system: QueryProbePlantSystem = null


class QueryProbePlantSystem:
	extends PlantSystem

	func register_probe_plant(
		plant: PlantDefense,
		cell: Vector2i
	) -> void:
		_register_plant_footprint(plant, [cell], PROACTIVE_CONFIG)

	func get_world_aabb_candidate_count(
		center_world: Vector2,
		radius_world: float
	) -> int:
		return _query_plant_targets_in_world_aabb(
			center_world,
			Vector2.ONE * radius_world
		).size()


func _init() -> void:
	call_deferred(&"_run")


func _run() -> void:
	_build_fixture()
	var center_cell := Vector2i.ZERO
	var center_world := _cell_world(center_cell)
	var nearest_plant := _add_plant(&"NearestPlant", Vector2i(1, 0))
	var second_plant := _add_plant(&"SecondPlant", Vector2i(2, 0))
	var boundary_plant := _add_plant(&"BoundaryPlant", Vector2i(7, 0))

	_test_local_radii_and_exclusions(
		center_cell,
		center_world,
		nearest_plant,
		second_plant,
		boundary_plant
	)
	_test_distant_population_does_not_expand_local_candidates(
		center_cell,
		center_world,
		nearest_plant
	)
	_test_stable_equidistant_selection()
	_test_pending_lifecycle_invalid_nearest()
	_test_runtime_player_plant_merge(
		center_world,
		nearest_plant,
		second_plant
	)

	if fixture != null and is_instance_valid(fixture):
		fixture.queue_free()
	for _cleanup_frame in range(3):
		await process_frame
	if failures.is_empty():
		print("ENEMY_ATTACK_TARGET_QUERY_SMOKE_TEST_OK")
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	quit(1)


func _build_fixture() -> void:
	fixture = Node2D.new()
	fixture.name = "EnemyAttackTargetQuerySmokeTest"
	root.add_child(fixture)
	tile_map = TileMapLayer.new()
	tile_map.name = "GroundTileMapLayer"
	var tile_set := TileSet.new()
	tile_set.tile_size = Vector2i(int(TILE_SIZE), int(TILE_SIZE))
	tile_map.tile_set = tile_set
	fixture.add_child(tile_map)
	plant_container = Node2D.new()
	plant_container.name = "PlantContainer"
	fixture.add_child(plant_container)
	plant_system = QueryProbePlantSystem.new()
	plant_system.name = "PlantSystem"
	fixture.add_child(plant_system)
	plant_system.setup(
		tile_map,
		null,
		plant_container,
		Rect2i(-2048, -2048, 4096, 4096)
	)
	plant_system.set_enemy_target_query_metrics_enabled(true)


func _test_local_radii_and_exclusions(
	_center_cell: Vector2i,
	center_world: Vector2,
	nearest_plant: PlantDefense,
	second_plant: PlantDefense,
	boundary_plant: PlantDefense
) -> void:
	var excluded: Dictionary = {
		nearest_plant.get_instance_id(): true,
	}
	_expect(
		plant_system.find_nearest_enemy_objective(
			center_world,
			CHAIN_RADIUS_CELLS
		) == nearest_plant,
		"3格查询必须返回最近植物。"
	)
	_expect(
		plant_system.find_nearest_enemy_objective(
			center_world,
			CHAIN_RADIUS_CELLS,
			true,
			excluded
		) == second_plant,
		"3格查询必须排除已命中的实例并选择下一个植物。"
	)
	excluded[second_plant.get_instance_id()] = true
	_expect(
		plant_system.find_nearest_enemy_objective(
			center_world,
			ATTACK_RADIUS_CELLS,
			true,
			excluded
		) == boundary_plant,
		"7格查询必须精确包含半径边界并排除全部已命中目标。"
	)
	_expect(
		plant_system.find_nearest_enemy_attack_target_world(
			center_world,
			CHAIN_RADIUS_CELLS * TILE_SIZE,
			{nearest_plant.get_instance_id(): true}
		) == second_plant,
		"世界半径查询必须复用同一排除语义。"
	)
	_expect(
		plant_system.get_world_aabb_candidate_count(
			center_world,
			CHAIN_RADIUS_CELLS * TILE_SIZE
		) == 2
		and plant_system.get_world_aabb_candidate_count(
			center_world,
			ATTACK_RADIUS_CELLS * TILE_SIZE
		) == 3
		and int(plant_system.get_plant_target_spatial_index_metrics().get(
			"membership_count",
			-1
		)) == 3,
		"3格与7格查询必须共享单成员空间索引，并只返回各自AABB候选。"
	)


func _test_distant_population_does_not_expand_local_candidates(
	_center_cell: Vector2i,
	center_world: Vector2,
	nearest_plant: PlantDefense
) -> void:
	var candidate_count_before := plant_system.get_world_aabb_candidate_count(
		center_world,
		CHAIN_RADIUS_CELLS * TILE_SIZE
	)
	for plant_index in range(FAR_PLANT_COUNT):
		var far_cell := Vector2i(
			32 + (plant_index % 32) * 2,
			32 + (plant_index / 32) * 2
		)
		_add_plant(StringName("FarPlant%d" % plant_index), far_cell)
	var candidate_count_after := plant_system.get_world_aabb_candidate_count(
		center_world,
		CHAIN_RADIUS_CELLS * TILE_SIZE
	)
	var selected := plant_system.find_nearest_enemy_attack_target_world(
		center_world,
		CHAIN_RADIUS_CELLS * TILE_SIZE
	)
	var query_metrics := plant_system.get_last_enemy_target_query_metrics()
	_expect(
		selected == nearest_plant
		and candidate_count_before == 2
		and candidate_count_after == candidate_count_before
		and int(query_metrics.get("candidates_visited", -1)) == candidate_count_before
		and int(query_metrics.get("results_written", -1)) == 1
		and query_metrics.get("query_mode") == &"buckets",
		"远处256株植物不得增加3格查询的候选遍历量或触发全植物收集。"
	)


func _test_stable_equidistant_selection() -> void:
	var tie_center := Vector2i(0, 20)
	var left_plant := _add_plant(&"TieLeftPlant", tie_center + Vector2i.LEFT)
	_add_plant(&"TieRightPlant", tie_center + Vector2i.RIGHT)
	var tie_world := _cell_world(tie_center)
	for _repeat_index in range(8):
		_expect(
			plant_system.find_nearest_enemy_objective(
				tie_world,
				CHAIN_RADIUS_CELLS
			) == left_plant,
			"等距植物必须在连续局部查询中保持稳定顺序。"
		)
		_expect(
			plant_system.find_nearest_enemy_attack_target_world(
				tie_world,
				CHAIN_RADIUS_CELLS * TILE_SIZE
			) == left_plant,
			"等距植物必须在连续世界查询中保持稳定实例顺序。"
		)


func _test_pending_lifecycle_invalid_nearest() -> void:
	var center_cell := Vector2i(0, 40)
	var dead_nearest := _add_plant(&"PendingDeadPlant", center_cell)
	var living_second := _add_plant(
		&"LivingAfterPendingDeadPlant",
		center_cell + Vector2i.RIGHT
	)
	dead_nearest.is_dead = true
	_expect(
		plant_system.find_nearest_enemy_attack_target_world(
			_cell_world(center_cell),
			CHAIN_RADIUS_CELLS * TILE_SIZE
		) == living_second,
		"死亡标记与 removal_started 注销之间的重入查询必须继续选择下一个活植物。"
	)


func _test_runtime_player_plant_merge(
	center_world: Vector2,
	nearest_plant: PlantDefense,
	second_plant: PlantDefense
) -> void:
	var runtime := GameTowerDefense.new()
	runtime.plant_system = plant_system
	var local_player := Player.new()
	local_player.position = center_world + Vector2(TILE_SIZE * 0.5, 0.0)
	var peer_player := Player.new()
	peer_player.position = center_world + Vector2(TILE_SIZE * 1.5, 0.0)
	runtime.player = local_player
	runtime.peer_players[2] = peer_player
	var maximum_distance := ATTACK_RADIUS_CELLS * TILE_SIZE
	_expect(
		runtime.find_nearest_enemy_attack_target_world(
			center_world,
			maximum_distance
		) == local_player,
		"混合查询必须在玩家与植物之间选择真实最近目标。"
	)
	var excluded: Dictionary = {local_player.get_instance_id(): true}
	_expect(
		runtime.find_nearest_enemy_attack_target_world(
			center_world,
			maximum_distance,
			excluded
		) == nearest_plant,
		"排除最近玩家后，混合查询必须选择最近植物。"
	)
	excluded[nearest_plant.get_instance_id()] = true
	_expect(
		runtime.find_nearest_enemy_attack_target_world(
			center_world,
			maximum_distance,
			excluded
		) == peer_player,
		"排除已命中玩家与植物后，混合查询必须继续选择下一个玩家。"
	)
	excluded[peer_player.get_instance_id()] = true
	_expect(
		runtime.find_nearest_enemy_attack_target_world(
			center_world,
			maximum_distance,
			excluded
		) == second_plant,
		"玩家与植物必须共享同一实例排除集合。"
	)
	runtime.free()
	local_player.free()
	peer_player.free()


func _add_plant(plant_name: StringName, cell: Vector2i) -> PlantDefense:
	var plant := PlantDefense.new()
	plant.name = plant_name
	plant_container.add_child(plant)
	plant.global_position = _cell_world(cell)
	plant_system.register_probe_plant(plant, cell)
	return plant


func _cell_world(cell: Vector2i) -> Vector2:
	return tile_map.to_global(tile_map.map_to_local(cell))


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
