extends SceneTree

const SIMPLE_FENCE_CONFIG := preload(
	"res://resources/config/plant_defense/simple_fence.tres"
)
const ENEMY_SCENE := preload("res://scene/enemy/enemy.tscn")
const PROACTIVE_COUNT := 32
const CONTACT_ONLY_COUNT := 10_000
const ENEMY_COUNT := 300
const WARMUP_FRAMES := 120
const SAMPLE_FRAMES := 240
const PAIR_COUNT := 3
const QUERY_RADIUS := 512.0
const MAX_P95_RATIO := 1.10
const MAX_P95_FIXED_MARGIN_MS := 0.5

var failures: Array[String] = []


class IndexProbePlantSystem:
	extends PlantSystem

	func register_probe(
		plant: PlantDefense,
		cell: Vector2i,
		config: PlantDefenseConfig
	) -> void:
		_register_plant_footprint(plant, [cell], config)

	func unregister_probe(plant: PlantDefense) -> void:
		_release_plant_footprint(plant)


func _init() -> void:
	call_deferred(&"_run")


func _run() -> void:
	var baseline := _build_fixture("FenceIndexBaseline")
	var with_fences := _build_fixture("FenceIndexWithTenThousand")
	var baseline_system := baseline["system"] as IndexProbePlantSystem
	var fence_system := with_fences["system"] as IndexProbePlantSystem
	var baseline_proactive := _add_proactive_plants(baseline)
	var fence_proactive := _add_proactive_plants(with_fences)

	baseline_system.set_enemy_target_query_metrics_enabled(true)
	fence_system.set_enemy_target_query_metrics_enabled(true)
	var query_center := Vector2.ZERO
	var baseline_target := baseline_system.find_nearest_enemy_attack_target_world(
		query_center,
		QUERY_RADIUS
	)
	var baseline_query_metrics := (
		baseline_system.get_last_enemy_target_query_metrics()
	)
	var baseline_structure := (
		baseline_system.get_enemy_target_spatial_index_metrics()
	)
	var object_count_before := int(Performance.get_monitor(
		Performance.OBJECT_NODE_COUNT
	))
	_add_contact_only_plants(with_fences)
	await process_frame
	var object_count_after := int(Performance.get_monitor(
		Performance.OBJECT_NODE_COUNT
	))
	var fence_target := fence_system.find_nearest_enemy_attack_target_world(
		query_center,
		QUERY_RADIUS
	)
	var fence_query_metrics := fence_system.get_last_enemy_target_query_metrics()
	var fence_structure := fence_system.get_enemy_target_spatial_index_metrics()
	var all_structure := fence_system.get_plant_target_spatial_index_metrics()

	_expect(
		baseline_target != null
		and fence_target != null
		and baseline_target.name == fence_target.name
		and int(baseline_structure.get("membership_count", -1))
		== PROACTIVE_COUNT
		and int(fence_structure.get("membership_count", -1))
		== PROACTIVE_COUNT
		and int(baseline_structure.get("registered_count", -1))
		== int(fence_structure.get("registered_count", -2))
		and int(baseline_query_metrics.get("candidates_visited", -1))
		== int(fence_query_metrics.get("candidates_visited", -2))
		and int(baseline_query_metrics.get("results_written", -1))
		== int(fence_query_metrics.get("results_written", -2)),
		"热点内增加10000个CONTACT_ONLY围栏后，敌人候选索引成员数、候选访问量与结果签名必须和零围栏基线完全一致。baseline=%s fence=%s"
		% [baseline_query_metrics, fence_query_metrics]
	)
	_expect(
		int(all_structure.get("membership_count", -1))
		== PROACTIVE_COUNT + CONTACT_ONLY_COUNT
		and bool(all_structure.get("structure_counts_consistent", false))
		and bool(fence_structure.get("structure_counts_consistent", false)),
		"完整建筑索引必须保留10000围栏供治疗/交互使用，而敌人主动索引仍只含32个普通建筑。"
	)
	print(
		"SIMPLE_FENCE_STATIC_COST nodes_delta=%d all_index_members=%d enemy_index_members=%d"
		% [
			object_count_after - object_count_before,
			int(all_structure.get("membership_count", -1)),
			int(fence_structure.get("membership_count", -1)),
		]
	)

	var enemies := _add_query_enemies(with_fences)
	baseline_system.set_enemy_target_query_metrics_enabled(false)
	fence_system.set_enemy_target_query_metrics_enabled(false)
	var baseline_p95s: Array[float] = []
	var fence_p95s: Array[float] = []
	for pair_index in range(PAIR_COUNT):
		var paired_p95 := await _measure_paired_query_p95(
			baseline_system,
			fence_system,
			enemies,
			pair_index
		)
		baseline_p95s.append(paired_p95.x)
		fence_p95s.append(paired_p95.y)
		var baseline_p95: float = baseline_p95s.back()
		var fence_p95: float = fence_p95s.back()
		_expect(
			fence_p95
			<= baseline_p95 * MAX_P95_RATIO + MAX_P95_FIXED_MARGIN_MS,
			"第%d组300敌人A/B中，10000围栏查询p95不得超过基线1.10×+0.5ms：baseline=%.3fms fence=%.3fms。"
			% [pair_index + 1, baseline_p95, fence_p95]
		)
	print(
		"SIMPLE_FENCE_QUERY_AB baseline_p95_ms=%s fence_p95_ms=%s"
		% [baseline_p95s, fence_p95s]
	)
	fence_system.set_enemy_target_query_metrics_enabled(true)
	for proactive in fence_proactive:
		fence_system.unregister_probe(proactive)
	var fence_only_target := fence_system.find_nearest_enemy_attack_target_world(
		query_center,
		QUERY_RADIUS
	)
	var fence_only_metrics := fence_system.get_last_enemy_target_query_metrics()
	var fence_only_structure := fence_system.get_enemy_target_spatial_index_metrics()
	_expect(
		fence_only_target == null
		and int(fence_only_structure.get("membership_count", -1)) == 0
		and int(fence_only_structure.get("registered_count", -1)) == 0
		and int(fence_only_metrics.get("candidates_visited", -1)) == 0
		and int(fence_only_metrics.get("results_written", -1)) == 0,
		"只有围栏时敌人主动索引必须为空，查询不得访问任何候选。metrics=%s"
		% fence_only_metrics
	)

	# Keep both fixtures alive until all comparisons finish; then release the large
	# static population and let Physics2D process deferred removals before exit.
	for proactive in baseline_proactive:
		baseline_system.unregister_probe(proactive)
	(baseline["root"] as Node).queue_free()
	(with_fences["root"] as Node).queue_free()
	for _cleanup_frame in range(8):
		await process_frame

	if failures.is_empty():
		print("SIMPLE_FENCE_ENEMY_INDEX_PERFORMANCE_PROBE_OK")
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	quit(1)


func _build_fixture(fixture_name: String) -> Dictionary:
	var fixture_root := Node2D.new()
	fixture_root.name = fixture_name
	root.add_child(fixture_root)
	var tile_map := TileMapLayer.new()
	var tile_set := TileSet.new()
	tile_set.tile_size = Vector2i(16, 16)
	tile_map.tile_set = tile_set
	fixture_root.add_child(tile_map)
	var plant_container := Node2D.new()
	plant_container.name = "PlantContainer"
	fixture_root.add_child(plant_container)
	var enemy_container := Node2D.new()
	enemy_container.name = "EnemyContainer"
	fixture_root.add_child(enemy_container)
	var system := IndexProbePlantSystem.new()
	fixture_root.add_child(system)
	system.setup(
		tile_map,
		null,
		plant_container,
		Rect2i(-20_000, -20_000, 40_000, 40_000)
	)
	return {
		"root": fixture_root,
		"tile_map": tile_map,
		"plant_container": plant_container,
		"enemy_container": enemy_container,
		"system": system,
	}


func _add_proactive_plants(built: Dictionary) -> Array[PlantDefense]:
	var config := SIMPLE_FENCE_CONFIG.duplicate(true) as PlantDefenseConfig
	config.cardinal_connection_group = &""
	config.enemy_engagement_mode = (
		PlantDefenseConfig.EnemyEngagementMode.PROACTIVE
	)
	var system := built["system"] as IndexProbePlantSystem
	var container := built["plant_container"] as Node2D
	var plants: Array[PlantDefense] = []
	for index in range(PROACTIVE_COUNT):
		var plant := PlantDefense.new()
		plant.name = "Proactive%02d" % index
		container.add_child(plant)
		var cell := Vector2i(index, 0)
		plant.global_position = Vector2(
			float(index % 8) * 12.0 - 42.0,
			float(index / 8) * 12.0 - 18.0
		)
		plant.setup(config, null, [cell], false, 500, 0, 500, false)
		system.register_probe(plant, cell, config)
		plants.append(plant)
	return plants


func _add_contact_only_plants(built: Dictionary) -> void:
	var config := SIMPLE_FENCE_CONFIG.duplicate(true) as PlantDefenseConfig
	config.cardinal_connection_group = &""
	_expect(
		config.enemy_engagement_mode
		== PlantDefenseConfig.EnemyEngagementMode.CONTACT_ONLY,
		"性能夹具必须保留真实围栏的CONTACT_ONLY资格。"
	)
	var system := built["system"] as IndexProbePlantSystem
	var container := built["plant_container"] as Node2D
	for index in range(CONTACT_ONLY_COUNT):
		var plant := PlantDefense.new()
		plant.name = "ContactOnlyFence%d" % index
		container.add_child(plant)
		var cell := Vector2i(1000 + index, 10)
		# Deliberately keep every contact-only anchor in the enemy query hotspot.
		plant.global_position = Vector2(
			float(index % 64) - 32.0,
			float((index / 64) % 64) - 32.0
		)
		plant.setup(config, null, [cell], false, 500, 0, 500, false)
		system.register_probe(
			plant,
			cell,
			config
		)


func _add_query_enemies(built: Dictionary) -> Array[Enemy]:
	var container := built["enemy_container"] as Node2D
	var enemies: Array[Enemy] = []
	for index in range(ENEMY_COUNT):
		var enemy := ENEMY_SCENE.instantiate() as Enemy
		enemy.name = "QueryEnemy%d" % index
		container.add_child(enemy)
		enemy.set_physics_process(false)
		enemy.set_process(false)
		enemy.global_position = Vector2(
			float((index * 17) % 121) - 60.0,
			float((index * 31) % 121) - 60.0
		)
		enemies.append(enemy)
	return enemies


func _measure_paired_query_p95(
	baseline_system: PlantSystem,
	fence_system: PlantSystem,
	enemies: Array[Enemy],
	pair_index: int
) -> Vector2:
	for warmup_frame in range(WARMUP_FRAMES):
		if (warmup_frame + pair_index) % 2 == 0:
			_run_enemy_queries(baseline_system, enemies)
			_run_enemy_queries(fence_system, enemies)
		else:
			_run_enemy_queries(fence_system, enemies)
			_run_enemy_queries(baseline_system, enemies)
		await process_frame
	var baseline_samples: Array[float] = []
	var fence_samples: Array[float] = []
	baseline_samples.resize(SAMPLE_FRAMES)
	fence_samples.resize(SAMPLE_FRAMES)
	for sample_index in range(SAMPLE_FRAMES):
		var baseline_signature := 0
		var fence_signature := 0
		if (sample_index + pair_index) % 2 == 0:
			var baseline_started_usec := Time.get_ticks_usec()
			baseline_signature = _run_enemy_queries(baseline_system, enemies)
			baseline_samples[sample_index] = (
				float(Time.get_ticks_usec() - baseline_started_usec) / 1000.0
			)
			var fence_started_usec := Time.get_ticks_usec()
			fence_signature = _run_enemy_queries(fence_system, enemies)
			fence_samples[sample_index] = (
				float(Time.get_ticks_usec() - fence_started_usec) / 1000.0
			)
		else:
			var fence_started_usec := Time.get_ticks_usec()
			fence_signature = _run_enemy_queries(fence_system, enemies)
			fence_samples[sample_index] = (
				float(Time.get_ticks_usec() - fence_started_usec) / 1000.0
			)
			var baseline_started_usec := Time.get_ticks_usec()
			baseline_signature = _run_enemy_queries(baseline_system, enemies)
			baseline_samples[sample_index] = (
				float(Time.get_ticks_usec() - baseline_started_usec) / 1000.0
			)
		if baseline_signature != fence_signature:
			failures.append(
				"300敌人配对查询的结果签名必须逐帧一致：pair=%d frame=%d baseline=%d fence=%d。"
				% [pair_index + 1, sample_index, baseline_signature, fence_signature]
			)
			break
		await process_frame
	baseline_samples.sort()
	fence_samples.sort()
	var p95_index := ceili(float(SAMPLE_FRAMES) * 0.95) - 1
	return Vector2(baseline_samples[p95_index], fence_samples[p95_index])


func _run_enemy_queries(
	system: PlantSystem,
	enemies: Array[Enemy]
) -> int:
	var signature := 0
	for enemy in enemies:
		var target := system.find_nearest_enemy_attack_target_world(
			enemy.global_position,
			QUERY_RADIUS
		)
		if target != null:
			signature = int((signature * 33 + target.name.hash()) & 0x7fffffff)
	return signature


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
