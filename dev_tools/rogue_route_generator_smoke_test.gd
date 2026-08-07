extends SceneTree

const DEFAULT_CONFIG: RogueRouteGenerationConfig = preload(
	"res://resources/config/rogue_route/p3_generation_config.tres"
)
const WORLD_METRICS: RogueRouteWorldMetrics = preload(
	"res://resources/config/rogue_route/p3_world_metrics.tres"
)
const EXPECTED_ICON_PATHS := {
	RogueRouteGraph.NodeType.MAGICAL_ENCOUNTER:
		"res://resources/texture/rogue_route/magical_encounter.png",
	RogueRouteGraph.NodeType.EMERGENCY_COMBAT:
		"res://resources/texture/rogue_route/emergency_combat.png",
	RogueRouteGraph.NodeType.NORMAL_COMBAT:
		"res://resources/texture/rogue_route/normal_combat.png",
	RogueRouteGraph.NodeType.WILDERNESS_RESOURCE:
		"res://resources/texture/rogue_route/wilderness_resource.png",
	RogueRouteGraph.NodeType.MYSTERY_BLACK_MARKET:
		"res://resources/texture/rogue_route/mystery_black_market.png",
	RogueRouteGraph.NodeType.PREPARE_AHEAD:
		"res://resources/texture/rogue_route/prepare_ahead.png",
}
const SEED_SWEEP_COUNT := 256
const STATISTICAL_SEED_COUNT := 64

var failures: Array[String] = []


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	_test_default_config_contract()
	_test_runtime_contract_hash()
	_test_determinism_and_layout_round_trip()
	_test_random_stream_isolation()
	_test_seed_sweep_invariants()
	_test_variance_controls()
	_finish()


func _test_default_config_contract() -> void:
	_expect(DEFAULT_CONFIG != null, "P3 路线图默认配置必须能够加载。")
	if DEFAULT_CONFIG == null:
		return
	_expect(
		DEFAULT_CONFIG.validate_config().is_empty(),
		"P3 路线图默认配置必须通过 validate_config：%s"
		% [DEFAULT_CONFIG.validate_config()]
	)
	_expect(
		DEFAULT_CONFIG.width == 11 and DEFAULT_CONFIG.height == 9,
		"P3 路线图必须使用 11×9 奇数网格。"
	)
	_expect(
		DEFAULT_CONFIG.get_center_coord() == Vector2i(5, 4)
		and DEFAULT_CONFIG.get_center_node_id() == 49,
		"P3 路线图中心必须精确为 (5,4)，row-major id 必须为 49。"
	)
	_expect(
		is_equal_approx(DEFAULT_CONFIG.empty_ratio, 0.5),
		"P3 路线图基准空节点比例必须为 50%。"
	)
	_expect(
		DEFAULT_CONFIG.node_type_catalog.size() == 6,
		"P3 路线图必须注册六种非空节点。"
	)
	var black_market_config := DEFAULT_CONFIG.get_type_config(
		RogueRouteGraph.NodeType.MYSTERY_BLACK_MARKET
	)
	var ruins_resource_config := DEFAULT_CONFIG.get_type_config(
		RogueRouteGraph.NodeType.WILDERNESS_RESOURCE
	)
	_expect(
		black_market_config != null
		and black_market_config.minimum_count == 4
		and black_market_config.maximum_count == 7
		and is_equal_approx(black_market_config.generation_weight, 0.2),
		"神秘黑市必须使用 4–7 个硬数量约束与 0.2 生成权重。"
	)
	_expect(
		ruins_resource_config != null
		and ruins_resource_config.display_name == "遗址物资",
		"数值类型 4 必须对玩家显示为遗址物资。"
	)
	for node_type in EXPECTED_ICON_PATHS:
		var type_config := DEFAULT_CONFIG.get_type_config(int(node_type))
		_expect(
			type_config != null
			and type_config.icon != null
			and type_config.icon.resource_path == EXPECTED_ICON_PATHS[node_type],
			"节点类型 %d 必须绑定约定图标。" % int(node_type)
		)

	var invalid_even_config := DEFAULT_CONFIG.duplicate(true) as RogueRouteGenerationConfig
	invalid_even_config.width = 10
	_expect(
		_has_error_containing(invalid_even_config.validate_config(), "奇数"),
		"偶数宽度必须被配置校验拒绝。"
	)
	var duplicate_type_config := DEFAULT_CONFIG.duplicate(true) as RogueRouteGenerationConfig
	duplicate_type_config.node_type_catalog.append(
		duplicate_type_config.node_type_catalog[0]
	)
	_expect(
		_has_error_containing(duplicate_type_config.validate_config(), "重复"),
		"重复路线节点注册必须被配置校验拒绝。"
	)
	var invalid_maximum_config := (
		DEFAULT_CONFIG.duplicate(true) as RogueRouteGenerationConfig
	)
	var invalid_black_market := invalid_maximum_config.get_type_config(
		RogueRouteGraph.NodeType.MYSTERY_BLACK_MARKET
	)
	invalid_black_market.maximum_count = invalid_black_market.minimum_count - 1
	_expect(
		_has_error_containing(
			invalid_maximum_config.validate_config(),
			"maximum_count"
		),
		"正数 maximum_count 小于 minimum_count 时必须被配置校验拒绝。"
	)


func _test_runtime_contract_hash() -> void:
	_expect(WORLD_METRICS != null, "P3 必须加载统一路线世界度量资源。")
	if WORLD_METRICS == null:
		return
	_expect(
		WORLD_METRICS.validate_metrics().is_empty()
		and WORLD_METRICS.cell_spacing.is_equal_approx(Vector2(112.0, 80.0))
		and WORLD_METRICS.board_margin.is_equal_approx(Vector2(128.0, 112.0))
		and WORLD_METRICS.get_layout_size(Vector2i(11, 9)).is_equal_approx(
			Vector2(1376.0, 864.0)
		),
		"P3 世界度量必须稳定定义 112×80 正交间距、128×112 边距和 1376×864 布局。"
	)
	var baseline_hash := DEFAULT_CONFIG.compute_runtime_contract_hash(
		WORLD_METRICS
	)
	var repeated_hash := DEFAULT_CONFIG.compute_runtime_contract_hash(
		WORLD_METRICS
	)
	_expect(
		baseline_hash.length() == 64 and baseline_hash == repeated_hash,
		"运行契约哈希必须是稳定的 64 位十六进制 SHA-256。"
	)
	var changed_metrics := WORLD_METRICS.duplicate(true) as RogueRouteWorldMetrics
	changed_metrics.cell_spacing.x += 1.0
	var changed_config := DEFAULT_CONFIG.duplicate(true) as RogueRouteGenerationConfig
	changed_config.move_action_cost += 1
	var changed_cap_config := (
		DEFAULT_CONFIG.duplicate(true) as RogueRouteGenerationConfig
	)
	changed_cap_config.get_type_config(
		RogueRouteGraph.NodeType.MYSTERY_BLACK_MARKET
	).maximum_count += 1
	_expect(
		DEFAULT_CONFIG.compute_runtime_contract_hash(changed_metrics) != baseline_hash
		and changed_config.compute_runtime_contract_hash(WORLD_METRICS) != baseline_hash
		and changed_cap_config.compute_runtime_contract_hash(WORLD_METRICS)
		!= baseline_hash,
		"世界几何、移动消耗或节点 maximum_count 变化必须改变运行契约哈希。"
	)


func _test_determinism_and_layout_round_trip() -> void:
	var first := RogueRouteGenerator.generate(DEFAULT_CONFIG, 0x51A7E)
	var second := RogueRouteGenerator.generate(DEFAULT_CONFIG, 0x51A7E)
	_expect(first != null and second != null, "固定 seed 必须成功生成两张路线图。")
	if first == null or second == null:
		return
	_expect(
		first.compute_layout_hash() == second.compute_layout_hash()
		and first.export_layout() == second.export_layout(),
		"相同 seed 与配置必须逐字段生成完全相同的布局。"
	)
	var exported := first.export_layout()
	var imported := RogueRouteGraph.import_layout(exported)
	_expect(
		imported != null
		and imported.compute_layout_hash() == first.compute_layout_hash()
		and imported.export_layout() == exported,
		"路线图 export/import 必须无损往返并保留哈希。"
	)

	var tampered := exported.duplicate(true)
	var tampered_types := (tampered["node_types"] as PackedByteArray).duplicate()
	tampered_types[0] = (
		RogueRouteGraph.NodeType.NORMAL_COMBAT
		if tampered_types[0] == RogueRouteGraph.NodeType.EMPTY
		else RogueRouteGraph.NodeType.EMPTY
	)
	tampered["node_types"] = tampered_types
	_expect(
		RogueRouteGraph.import_layout(tampered) == null,
		"布局字段被篡改后必须因哈希不匹配而拒绝导入。"
	)


func _test_random_stream_isolation() -> void:
	var seed_value := 0x2468ACE
	var baseline := RogueRouteGenerator.generate(DEFAULT_CONFIG, seed_value)
	if baseline == null:
		_expect(false, "随机流隔离基线必须成功生成。")
		return

	var jittered_config := DEFAULT_CONFIG.duplicate(true) as RogueRouteGenerationConfig
	jittered_config.visual_jitter_pixels = Vector2i(5, 2)
	var jittered := RogueRouteGenerator.generate(jittered_config, seed_value)
	_expect(
		jittered != null
		and jittered.compute_topology_hash() == baseline.compute_topology_hash()
		and jittered.compute_content_hash() == baseline.compute_content_hash()
		and jittered.compute_layout_hash() != baseline.compute_layout_hash(),
		"临时启用视觉抖动只能改变 visual 流，不能改变拓扑或内容。"
	)

	var dense_config := DEFAULT_CONFIG.duplicate(true) as RogueRouteGenerationConfig
	dense_config.extra_edge_ratio = 0.65
	var dense := RogueRouteGenerator.generate(dense_config, seed_value)
	_expect(
		dense != null
		and dense.compute_topology_hash() != baseline.compute_topology_hash()
		and dense.compute_content_hash() == baseline.compute_content_hash(),
		"改变补边比例只能改变 topology 流结果，不能串扰内容。"
	)

	var content_config := DEFAULT_CONFIG.duplicate(true) as RogueRouteGenerationConfig
	content_config.empty_ratio = 0.36
	content_config.empty_ratio_jitter = 0.0
	var changed_content := RogueRouteGenerator.generate(content_config, seed_value)
	_expect(
		changed_content != null
		and changed_content.compute_topology_hash() == baseline.compute_topology_hash()
		and changed_content.compute_content_hash() != baseline.compute_content_hash(),
		"改变内容比例只能改变 content 流结果，不能串扰拓扑。"
	)


func _test_seed_sweep_invariants() -> void:
	var unique_layout_hashes: Dictionary = {}
	for seed_offset in range(SEED_SWEEP_COUNT):
		var generation_seed := 0x730000 + seed_offset
		var graph := RogueRouteGenerator.generate(DEFAULT_CONFIG, generation_seed)
		_expect(graph != null, "seed=%d 必须成功生成路线图。" % generation_seed)
		if graph == null:
			continue
		_validate_graph_invariants(graph, DEFAULT_CONFIG, generation_seed)
		unique_layout_hashes[graph.compute_layout_hash()] = true
	_expect(
		unique_layout_hashes.size() >= SEED_SWEEP_COUNT - 2,
		"256 个连续 seed 应生成至少 254 个不同布局，实际为 %d。"
		% unique_layout_hashes.size()
	)


func _validate_graph_invariants(
	graph: RogueRouteGraph,
	config: RogueRouteGenerationConfig,
	generation_seed: int
) -> void:
	var label := "seed=%d" % generation_seed
	var node_count := config.get_node_count()
	_expect(
		graph.validate_layout().is_empty(),
		"%s：生成布局必须通过自身校验：%s"
		% [label, graph.validate_layout()]
	)
	_expect(
		graph.width == config.width
		and graph.height == config.height
		and graph.get_node_count() == node_count,
		"%s：节点数量必须精确等于 11×9。" % label
	)
	_expect(
		graph.start_node_id == config.get_center_node_id()
		and graph.get_start_coord() == config.get_center_coord()
		and graph.get_node_type(graph.start_node_id) == RogueRouteGraph.NodeType.EMPTY
		and graph.get_visual_offset(graph.start_node_id) == Vector2.ZERO,
		"%s：玩家起点必须是正中心 EMPTY 格，且不得发生视觉偏移。" % label
	)

	var empty_count := graph.get_node_ids_by_type(RogueRouteGraph.NodeType.EMPTY).size()
	var empty_ratio := float(empty_count) / float(node_count)
	var quantization_error := 0.5 / float(node_count) + 0.000001
	_expect(
		empty_ratio
		>= maxf(config.empty_ratio - config.empty_ratio_jitter, 0.0)
		- quantization_error
		and empty_ratio
		<= minf(config.empty_ratio + config.empty_ratio_jitter, 1.0)
		+ quantization_error,
		"%s：空节点比例 %.4f 超出配置范围。" % [label, empty_ratio]
	)
	for type_config in config.node_type_catalog:
		var generated_count := graph.get_node_ids_by_type(
			type_config.node_type
		).size()
		_expect(
			generated_count >= type_config.minimum_count
			and (
				type_config.maximum_count == 0
				or generated_count <= type_config.maximum_count
			),
			"%s：%s 数量必须位于 minimum_count/maximum_count 约束内。"
			% [label, type_config.display_name]
		)
	var black_market_count := graph.get_node_ids_by_type(
		RogueRouteGraph.NodeType.MYSTERY_BLACK_MARKET
	).size()
	_expect(
		black_market_count >= 4 and black_market_count <= 7,
		"%s：神秘黑市总数必须始终位于 4–7，实际为 %d。"
		% [label, black_market_count]
	)

	var maximum_edge_count := graph.get_max_cardinal_edge_count()
	var spanning_tree_edge_count := node_count - 1
	var expected_extra_edge_count := roundi(
		config.extra_edge_ratio
		* float(maximum_edge_count - spanning_tree_edge_count)
	)
	_expect(
		graph.get_edge_count()
		== spanning_tree_edge_count + expected_extra_edge_count
		and graph.get_edge_count() >= node_count
		and graph.get_edge_count() < maximum_edge_count,
		"%s：路线图必须使用覆盖树加精确补边，且不能成为完整邻接网格。" % label
	)

	var previous_edge := Vector2i(-1, -1)
	var seen_edges: Dictionary = {}
	for edge_offset in range(0, graph.edges.size(), 2):
		var first_node_id := int(graph.edges[edge_offset])
		var second_node_id := int(graph.edges[edge_offset + 1])
		var edge := Vector2i(first_node_id, second_node_id)
		var first_coord := graph.id_to_coord(first_node_id)
		var second_coord := graph.id_to_coord(second_node_id)
		var edge_key := "%d:%d" % [first_node_id, second_node_id]
		_expect(
			first_node_id < second_node_id
			and (
				absi(first_coord.x - second_coord.x)
				+ absi(first_coord.y - second_coord.y)
			) == 1
			and not seen_edges.has(edge_key),
			"%s：每条边必须规范化、唯一并仅连接四邻格。" % label
		)
		_expect(
			previous_edge.x < edge.x
			or (previous_edge.x == edge.x and previous_edge.y < edge.y),
			"%s：序列化边必须按端点稳定排序。" % label
		)
		seen_edges[edge_key] = true
		previous_edge = edge

	var visited: Dictionary = {graph.start_node_id: true}
	var queue: Array[int] = [graph.start_node_id]
	var cursor := 0
	while cursor < queue.size():
		var node_id := queue[cursor]
		cursor += 1
		var neighbors := graph.get_neighbors(node_id)
		_expect(
			neighbors.size() >= 1 and neighbors.size() <= 4,
			"%s：每个节点度数必须位于 1 到 4。" % label
		)
		for neighbor_id in neighbors:
			_expect(
				graph.has_edge(int(neighbor_id), node_id),
				"%s：无向邻接必须双向对称。" % label
			)
			if not visited.has(int(neighbor_id)):
				visited[int(neighbor_id)] = true
				queue.append(int(neighbor_id))
	_expect(
		visited.size() == node_count,
		"%s：从中心 BFS 必须访问全部 %d 个格子。" % [label, node_count]
	)

	for node_id in range(node_count):
		var offset := graph.get_visual_offset(node_id)
		_expect(
			absf(offset.x) <= float(config.visual_jitter_pixels.x)
			and absf(offset.y) <= float(config.visual_jitter_pixels.y),
			"%s：节点 %d 的视觉抖动超出配置。" % [label, node_id]
		)


func _test_variance_controls() -> void:
	var fixed_ratio_config := DEFAULT_CONFIG.duplicate(true) as RogueRouteGenerationConfig
	fixed_ratio_config.empty_ratio_jitter = 0.0
	var variable_ratio_config := DEFAULT_CONFIG.duplicate(true) as RogueRouteGenerationConfig
	variable_ratio_config.empty_ratio_jitter = 0.18
	var dispersed_config := DEFAULT_CONFIG.duplicate(true) as RogueRouteGenerationConfig
	dispersed_config.empty_ratio_jitter = 0.0
	dispersed_config.empty_cluster_strength = 0.0
	var clustered_config := DEFAULT_CONFIG.duplicate(true) as RogueRouteGenerationConfig
	clustered_config.empty_ratio_jitter = 0.0
	clustered_config.empty_cluster_strength = 1.0

	var fixed_ratios: Array[float] = []
	var variable_ratios: Array[float] = []
	var dispersed_adjacency_sum := 0.0
	var clustered_adjacency_sum := 0.0
	for seed_offset in range(STATISTICAL_SEED_COUNT):
		var generation_seed := 0x910000 + seed_offset
		var fixed_graph := RogueRouteGenerator.generate(fixed_ratio_config, generation_seed)
		var variable_graph := RogueRouteGenerator.generate(variable_ratio_config, generation_seed)
		var dispersed_graph := RogueRouteGenerator.generate(dispersed_config, generation_seed)
		var clustered_graph := RogueRouteGenerator.generate(clustered_config, generation_seed)
		if (
			fixed_graph == null
			or variable_graph == null
			or dispersed_graph == null
			or clustered_graph == null
		):
			_expect(false, "方差控制 seed=%d 必须成功生成四张路线图。" % generation_seed)
			continue
		fixed_ratios.append(_get_empty_ratio(fixed_graph))
		variable_ratios.append(_get_empty_ratio(variable_graph))
		dispersed_adjacency_sum += _get_empty_adjacency_ratio(dispersed_graph)
		clustered_adjacency_sum += _get_empty_adjacency_ratio(clustered_graph)

	_expect(
		_get_variance(variable_ratios) > _get_variance(fixed_ratios) + 0.001,
		"提高 empty_ratio_jitter 必须可测量地提高跨 seed 空节点比例方差。"
	)
	_expect(
		clustered_adjacency_sum
		> dispersed_adjacency_sum + float(STATISTICAL_SEED_COUNT) * 0.04,
		"提高 empty_cluster_strength 必须显著增加相邻空格的聚团程度。"
	)


func _get_empty_ratio(graph: RogueRouteGraph) -> float:
	return (
		float(graph.get_node_ids_by_type(RogueRouteGraph.NodeType.EMPTY).size())
		/ float(graph.get_node_count())
	)


func _get_empty_adjacency_ratio(graph: RogueRouteGraph) -> float:
	var adjacent_empty_pairs := 0
	var maximum_pair_count := graph.get_max_cardinal_edge_count()
	for row in range(graph.height):
		for column in range(graph.width):
			var node_id := row * graph.width + column
			if column + 1 < graph.width:
				if (
					graph.get_node_type(node_id) == RogueRouteGraph.NodeType.EMPTY
					and graph.get_node_type(node_id + 1) == RogueRouteGraph.NodeType.EMPTY
				):
					adjacent_empty_pairs += 1
			if row + 1 < graph.height:
				if (
					graph.get_node_type(node_id) == RogueRouteGraph.NodeType.EMPTY
					and graph.get_node_type(node_id + graph.width)
					== RogueRouteGraph.NodeType.EMPTY
				):
					adjacent_empty_pairs += 1
	return float(adjacent_empty_pairs) / float(maximum_pair_count)


func _get_variance(values: Array[float]) -> float:
	if values.is_empty():
		return 0.0
	var mean := 0.0
	for value in values:
		mean += value
	mean /= float(values.size())
	var variance := 0.0
	for value in values:
		var difference := value - mean
		variance += difference * difference
	return variance / float(values.size())


func _has_error_containing(errors: PackedStringArray, needle: String) -> bool:
	for error in errors:
		if error.contains(needle):
			return true
	return false


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
