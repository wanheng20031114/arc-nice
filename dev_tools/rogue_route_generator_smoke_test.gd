extends SceneTree

const DEFAULT_CONFIG: RogueRouteGenerationConfig = preload(
	"res://resources/config/rogue_route/p3_generation_config.tres"
)
const WORLD_METRICS: RogueRouteWorldMetrics = preload(
	"res://resources/config/rogue_route/p3_world_metrics.tres"
)
const EXPECTED_TEMPLATE_IDS := [
	"4a", "4b", "4c", "4d", "4e", "4f", "4g", "4h", "4i", "4j",
	"5a", "5b", "5c", "5d", "5e", "5f", "5g", "5h", "5i", "5j",
]
const SEED_SWEEP_COUNT := 1024

var failures: Array[String] = []


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	_test_default_config_contract()
	_test_runtime_contract_hash()
	_test_determinism_and_layout_round_trip()
	_test_random_stream_isolation()
	_test_seed_sweep_invariants()
	_finish()


func _test_default_config_contract() -> void:
	_expect(DEFAULT_CONFIG != null, "P3 路线图默认配置必须能够加载。")
	if DEFAULT_CONFIG == null:
		return
	_expect(
		DEFAULT_CONFIG.validate_config().is_empty(),
		"P3 路线生成配置必须有效：%s" % [DEFAULT_CONFIG.validate_config()]
	)
	_expect(
		DEFAULT_CONFIG.templates.size() == EXPECTED_TEMPLATE_IDS.size(),
		"P3 必须配置 4a–4j、5a–5j 共 20 个模板。"
	)
	var actual_ids: Array[String] = []
	for template in DEFAULT_CONFIG.get_sorted_templates():
		actual_ids.append(String(template.template_id))
		_expect(
			is_equal_approx(template.selection_weight, 1.0),
			"模板 %s 的选择权重必须为 1。" % template.template_id
		)
	_expect(actual_ids == EXPECTED_TEMPLATE_IDS, "20 个模板 ID 必须完整且稳定排序。")
	_expect(
		DEFAULT_CONFIG.start_max_manhattan_distance == 2
		and DEFAULT_CONFIG.start_minimum_non_empty_count == 6,
		"出生规则必须固定为曼哈顿距离 2 内至少 6 个非空节点。"
	)
	_expect_type_range(RogueRouteGraph.NodeType.NORMAL_COMBAT, 4, 4)
	_expect_type_range(RogueRouteGraph.NodeType.EMERGENCY_COMBAT, 3, 3)
	_expect_type_range(RogueRouteGraph.NodeType.MAGICAL_ENCOUNTER, 4, 4)
	_expect_type_range(RogueRouteGraph.NodeType.UNDERGROUND_SHOP, 2, 3)
	_expect_type_range(RogueRouteGraph.NodeType.PREPARE_AHEAD, 2, 3)
	_expect_type_range(RogueRouteGraph.NodeType.WILDERNESS_RESOURCE, 2, 3)


func _expect_type_range(node_type: int, minimum_count: int, maximum_count: int) -> void:
	var type_config := DEFAULT_CONFIG.get_type_config(node_type)
	_expect(
		type_config != null
		and type_config.minimum_count == minimum_count
		and type_config.maximum_count == maximum_count,
		"节点类型 %d 的数量范围必须为 %d–%d。"
		% [node_type, minimum_count, maximum_count]
	)


func _test_runtime_contract_hash() -> void:
	var baseline_hash := DEFAULT_CONFIG.compute_runtime_contract_hash(WORLD_METRICS)
	_expect(
		baseline_hash.length() == 64
		and baseline_hash == DEFAULT_CONFIG.compute_runtime_contract_hash(WORLD_METRICS),
		"模板化生成运行契约必须是稳定 SHA-256。"
	)
	var changed_config := DEFAULT_CONFIG.duplicate_deep(
		Resource.DEEP_DUPLICATE_ALL
	) as RogueRouteGenerationConfig
	changed_config.templates[0].selection_weight = 2.0
	var changed_count_config := (
		DEFAULT_CONFIG.duplicate_deep(Resource.DEEP_DUPLICATE_ALL)
		as RogueRouteGenerationConfig
	)
	changed_count_config.get_type_config(
		RogueRouteGraph.NodeType.MAGICAL_ENCOUNTER
	).minimum_count = 3
	_expect(
		changed_config.compute_runtime_contract_hash(WORLD_METRICS) != baseline_hash
		and changed_count_config.compute_runtime_contract_hash(WORLD_METRICS)
		!= baseline_hash,
		"模板权重、拓扑或精确数量范围变化必须改变运行契约。"
	)


func _test_determinism_and_layout_round_trip() -> void:
	var first := RogueRouteGenerator.generate(DEFAULT_CONFIG, 0x51A7E)
	var second := RogueRouteGenerator.generate(DEFAULT_CONFIG, 0x51A7E)
	_expect(first != null and second != null, "固定 seed 必须成功生成路线图。")
	if first == null or second == null:
		return
	_expect(
		first.export_layout() == second.export_layout(),
		"相同 seed 与配置必须逐字段生成完全相同的布局。"
	)
	var exported := first.export_layout()
	var imported := RogueRouteGraph.import_layout(exported, DEFAULT_CONFIG)
	_expect(
		int(exported.get("schema_version", 0)) == RogueRouteGraph.SCHEMA_VERSION
		and exported.has("template_id")
		and exported.has("node_coords")
		and imported != null
		and imported.export_layout() == exported,
		"schema=2 快照必须显式携带模板与坐标并支持配置绑定的无损往返。"
	)
	var old_schema := exported.duplicate(true)
	old_schema["schema_version"] = 1
	_expect(
		RogueRouteGraph.import_layout(old_schema, DEFAULT_CONFIG) == null,
		"旧版路线快照必须被直接拒绝。"
	)

	var forged_id := RogueRouteGraph.new()
	var other_template_id := &"4a" if first.template_id != &"4a" else &"4b"
	var forged_id_errors := forged_id.initialize_layout(
		first.generation_seed,
		first.width,
		first.height,
		first.start_node_id,
		first.node_types,
		first.node_content_seeds,
		first.visual_offsets,
		first.edges,
		other_template_id,
		first.node_coords
	)
	_expect(forged_id_errors.is_empty(), "伪造模板 ID 后仍应满足一般图结构约束。")
	if forged_id_errors.is_empty():
		_expect(
			RogueRouteGraph.import_layout(
				forged_id.export_layout(),
				DEFAULT_CONFIG
			) == null,
			"即使重算 layout_hash，本地模板绑定仍必须拒绝 template_id 篡改。"
		)

	var shifted_coords := first.node_coords.duplicate()
	for node_id in range(shifted_coords.size()):
		shifted_coords[node_id] += Vector2.RIGHT
	var forged_coords := RogueRouteGraph.new()
	var forged_errors := forged_coords.initialize_layout(
		first.generation_seed,
		first.width + 1,
		first.height,
		first.start_node_id,
		first.node_types,
		first.node_content_seeds,
		first.visual_offsets,
		first.edges,
		first.template_id,
		shifted_coords
	)
	_expect(forged_errors.is_empty(), "平移坐标后仍应满足一般图结构约束。")
	if forged_errors.is_empty():
		var forged_snapshot := forged_coords.export_layout()
		_expect(
			RogueRouteGraph.import_layout(forged_snapshot) != null
			and RogueRouteGraph.import_layout(forged_snapshot, DEFAULT_CONFIG) == null,
			"即使攻击方重算 layout_hash，本地模板绑定仍必须拒绝坐标篡改。"
		)

	var template := DEFAULT_CONFIG.get_template(first.template_id)
	var valid_starts := template.get_valid_start_node_ids(
		DEFAULT_CONFIG.start_max_manhattan_distance,
		DEFAULT_CONFIG.start_minimum_non_empty_count
	)
	var invalid_start_node_id := -1
	for node_id in range(first.get_node_count()):
		if not valid_starts.has(node_id):
			invalid_start_node_id = node_id
			break
	_expect(invalid_start_node_id >= 0, "正式模板必须存在非法出生位置供防篡改测试。")
	if invalid_start_node_id >= 0:
		var invalid_start_types := first.node_types.duplicate()
		var displaced_type: int = int(invalid_start_types[invalid_start_node_id])
		invalid_start_types[invalid_start_node_id] = RogueRouteGraph.NodeType.EMPTY
		invalid_start_types[first.start_node_id] = displaced_type
		var invalid_start := RogueRouteGraph.new()
		var invalid_start_errors := invalid_start.initialize_layout(
			first.generation_seed,
			first.width,
			first.height,
			invalid_start_node_id,
			invalid_start_types,
			first.node_content_seeds,
			first.visual_offsets,
			first.edges,
			first.template_id,
			first.node_coords
		)
		_expect(
			invalid_start_errors.is_empty()
			and RogueRouteGraph.import_layout(
				invalid_start.export_layout(),
				DEFAULT_CONFIG
			) == null,
			"即使重算 layout_hash，非法边缘出生点也必须被本地规则拒绝。"
		)

	var forged_content_seeds := first.node_content_seeds.duplicate()
	forged_content_seeds[0] = int(forged_content_seeds[0]) ^ 1
	var forged_seed_binding := RogueRouteGraph.new()
	var forged_seed_errors := forged_seed_binding.initialize_layout(
		first.generation_seed,
		first.width,
		first.height,
		first.start_node_id,
		first.node_types,
		forged_content_seeds,
		first.visual_offsets,
		first.edges,
		first.template_id,
		first.node_coords
	)
	_expect(
		forged_seed_errors.is_empty()
		and RogueRouteGraph.import_layout(forged_seed_binding.export_layout()) != null
		and RogueRouteGraph.import_layout(
			forged_seed_binding.export_layout(),
			DEFAULT_CONFIG
		) == null,
		"即使重算 layout_hash，快照也必须与本地按 generation_seed 生成的完整布局一致。"
	)


func _test_random_stream_isolation() -> void:
	var seed_value := 0x2468ACE
	var baseline := RogueRouteGenerator.generate(DEFAULT_CONFIG, seed_value)
	var jittered_config := DEFAULT_CONFIG.duplicate_deep(
		Resource.DEEP_DUPLICATE_ALL
	) as RogueRouteGenerationConfig
	jittered_config.visual_jitter_pixels = Vector2i(5, 2)
	var jittered := RogueRouteGenerator.generate(jittered_config, seed_value)
	_expect(
		baseline != null
		and jittered != null
		and jittered.compute_topology_hash() == baseline.compute_topology_hash()
		and jittered.compute_content_hash() == baseline.compute_content_hash()
		and jittered.compute_layout_hash() != baseline.compute_layout_hash(),
		"视觉随机流只能改变偏移，不得串扰模板、出生或内容。"
	)


func _test_seed_sweep_invariants() -> void:
	var seen_templates: Dictionary = {}
	var seen_magical_counts: Dictionary = {}
	var seen_shop_counts: Dictionary = {}
	var seen_chest_counts: Dictionary = {}
	var seen_resource_counts: Dictionary = {}
	for seed_offset in range(SEED_SWEEP_COUNT):
		var generation_seed := 0x730000 + seed_offset
		var graph := RogueRouteGenerator.generate(DEFAULT_CONFIG, generation_seed)
		_expect(graph != null, "seed=%d 必须成功生成路线图。" % generation_seed)
		if graph == null:
			continue
		_validate_graph_invariants(graph, generation_seed)
		seen_templates[String(graph.template_id)] = true
		seen_magical_counts[
			graph.get_node_ids_by_type(RogueRouteGraph.NodeType.MAGICAL_ENCOUNTER).size()
		] = true
		seen_shop_counts[
			graph.get_node_ids_by_type(RogueRouteGraph.NodeType.UNDERGROUND_SHOP).size()
		] = true
		seen_chest_counts[
			graph.get_node_ids_by_type(RogueRouteGraph.NodeType.PREPARE_AHEAD).size()
		] = true
		seen_resource_counts[
			graph.get_node_ids_by_type(RogueRouteGraph.NodeType.WILDERNESS_RESOURCE).size()
		] = true
	_expect(seen_templates.size() == 20, "连续 1024 个 seed 必须覆盖全部 20 个等权模板。")
	_expect(
		seen_magical_counts.size() == 1 and seen_magical_counts.has(4)
		and seen_shop_counts.has(2) and seen_shop_counts.has(3)
		and seen_chest_counts.has(2) and seen_chest_counts.has(3)
		and seen_resource_counts.has(2) and seen_resource_counts.has(3),
		"神奇遭遇必须固定4个，其余2–3独立均匀数量必须覆盖两端：遭遇%s 商店%s 宝箱%s 物资%s。"
		% [
			seen_magical_counts.keys(),
			seen_shop_counts.keys(),
			seen_chest_counts.keys(),
			seen_resource_counts.keys(),
		]
	)


func _validate_graph_invariants(graph: RogueRouteGraph, generation_seed: int) -> void:
	var label := "seed=%d" % generation_seed
	var template := DEFAULT_CONFIG.get_template(graph.template_id)
	_expect(
		graph.validate_layout().is_empty()
		and DEFAULT_CONFIG.validate_graph_template(graph).is_empty()
		and template != null,
		"%s：图必须通过结构与本地模板绑定校验。" % label
	)
	if template == null:
		return
	_expect(
		graph.get_node_count() == template.get_node_count()
		and graph.node_coords == template.node_coords
		and graph.edges == template.edges,
		"%s：紧凑节点、坐标和边必须精确来自所选模板。" % label
	)
	_expect(
		graph.get_node_type(graph.start_node_id) == RogueRouteGraph.NodeType.EMPTY
		and graph.get_visual_offset(graph.start_node_id) == Vector2.ZERO,
		"%s：出生点必须保持 EMPTY 且无视觉抖动。" % label
	)

	var start_coord := graph.get_start_coord()
	var minimum_coord := graph.id_to_coord(0)
	var maximum_coord := minimum_coord
	var nearby_non_empty_count := 0
	for node_id in range(graph.get_node_count()):
		var coord := graph.id_to_coord(node_id)
		minimum_coord.x = mini(minimum_coord.x, coord.x)
		minimum_coord.y = mini(minimum_coord.y, coord.y)
		maximum_coord.x = maxi(maximum_coord.x, coord.x)
		maximum_coord.y = maxi(maximum_coord.y, coord.y)
		_expect(
			graph.coord_to_id(coord) == node_id,
			"%s：显式坐标必须与紧凑节点 ID 无损互查。" % label
		)
		var distance := absi(coord.x - start_coord.x) + absi(coord.y - start_coord.y)
		if (
			node_id != graph.start_node_id
			and distance <= 2
			and graph.get_node_type(node_id) != RogueRouteGraph.NodeType.EMPTY
		):
			nearby_non_empty_count += 1
	_expect(
		start_coord.x != minimum_coord.x
		and start_coord.x != maximum_coord.x
		and start_coord.y != minimum_coord.y
		and start_coord.y != maximum_coord.y
		and nearby_non_empty_count >= 6,
		"%s：出生点不得在包围盒边缘，且两格内必须至少有 6 个非空节点。" % label
	)

	_expect(
		graph.get_node_ids_by_type(RogueRouteGraph.NodeType.NORMAL_COMBAT).size() == 4
		and graph.get_node_ids_by_type(RogueRouteGraph.NodeType.EMERGENCY_COMBAT).size() == 3,
		"%s：普通作战必须为 4 个、紧急作战必须为 3 个。" % label
	)
	for node_type in [
		RogueRouteGraph.NodeType.MAGICAL_ENCOUNTER,
		RogueRouteGraph.NodeType.UNDERGROUND_SHOP,
		RogueRouteGraph.NodeType.PREPARE_AHEAD,
		RogueRouteGraph.NodeType.WILDERNESS_RESOURCE,
	]:
		var count := graph.get_node_ids_by_type(node_type).size()
		var type_config := DEFAULT_CONFIG.get_type_config(node_type)
		_expect(
			count >= type_config.minimum_count and count <= type_config.maximum_count,
			"%s：节点类型 %d 数量越界。" % [label, node_type]
		)

	var encounter_node_ids := graph.get_node_ids_by_type(
		RogueRouteGraph.NodeType.MAGICAL_ENCOUNTER
	)
	var encounter_ids: Dictionary = {}
	for node_id in encounter_node_ids:
		var encounter_id := RogueEncounterRegistry.select_encounter_for_map(
			RogueEncounterRegistry.MAGICAL_ENCOUNTER_POOL,
			graph.generation_seed,
			encounter_node_ids,
			int(node_id)
		)
		_expect(
			encounter_id != RogueEncounterRegistry.CHICKEN_BRO
			and encounter_id != RogueEncounterRegistry.GHOST_SHADOW,
			"%s：地图分配不得返回预留的鸡哥或鬼影事件。" % label
		)
		encounter_ids[encounter_id] = true
	_expect(
		encounter_ids.size() == encounter_node_ids.size(),
		"%s：本地图所有神奇遭遇节点必须一一映射到互不重复事件。" % label
	)


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)


func _finish() -> void:
	if failures.is_empty():
		print("ROGUE_ROUTE_GENERATOR_SMOKE_TEST_OK")
		quit()
		return
	for failure in failures:
		push_error(failure)
	quit(1)
