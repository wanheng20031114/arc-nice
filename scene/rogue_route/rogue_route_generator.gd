extends RefCounted
class_name RogueRouteGenerator

## 三条随机流互不共享状态。修改连线密度、内容权重或视觉抖动时，不会串扰
## 其他维度的确定性结果。
const TOPOLOGY_STREAM_SALT := 0x13579BDF2468ACE
const CONTENT_STREAM_SALT := 0x2468ACE13579BDF
const VISUAL_STREAM_SALT := 0x51A7E2D439C06BF
const CONTENT_NOISE_FREQUENCY := 0.16


static func generate(
	config: RogueRouteGenerationConfig,
	generation_seed: int
) -> RogueRouteGraph:
	if config == null:
		push_error("RogueRouteGenerator 缺少生成配置。")
		return null
	var config_errors := config.validate_config()
	if not config_errors.is_empty():
		push_error(
			"RogueRouteGenerator 配置无效：%s"
			% "；".join(config_errors)
		)
		return null

	var topology_rng := _make_stream(generation_seed, TOPOLOGY_STREAM_SALT)
	var content_rng := _make_stream(generation_seed, CONTENT_STREAM_SALT)
	var visual_rng := _make_stream(generation_seed, VISUAL_STREAM_SALT)
	var generated_edges := _generate_edges(config, topology_rng)
	var content_data := _generate_content(config, content_rng)
	if content_data.is_empty():
		return null
	var generated_visual_offsets := _generate_visual_offsets(config, visual_rng)

	var graph := RogueRouteGraph.new()
	var layout_errors := graph.initialize_layout(
		generation_seed,
		config.width,
		config.height,
		config.get_center_node_id(),
		content_data["node_types"] as PackedByteArray,
		content_data["node_content_seeds"] as PackedInt64Array,
		generated_visual_offsets,
		generated_edges
	)
	if not layout_errors.is_empty():
		push_error(
			"RogueRouteGenerator 生成了无效路线图：%s"
			% "；".join(layout_errors)
		)
		return null
	return graph


static func _make_stream(base_seed: int, stream_salt: int) -> RandomNumberGenerator:
	var random := RandomNumberGenerator.new()
	random.seed = base_seed ^ stream_salt
	return random


static func _generate_edges(
	config: RogueRouteGenerationConfig,
	random: RandomNumberGenerator
) -> PackedInt32Array:
	var candidate_edges: Array[Vector2i] = []
	for row in range(config.height):
		for column in range(config.width):
			var node_id := row * config.width + column
			if column + 1 < config.width:
				candidate_edges.append(Vector2i(node_id, node_id + 1))
			if row + 1 < config.height:
				candidate_edges.append(
					Vector2i(node_id, node_id + config.width)
				)
	_shuffle_edges(candidate_edges, random)

	var node_count := config.get_node_count()
	var parents: Array[int] = []
	var tree_sizes: Array[int] = []
	parents.resize(node_count)
	tree_sizes.resize(node_count)
	for node_id in range(node_count):
		parents[node_id] = node_id
		tree_sizes[node_id] = 1

	var selected_edges: Array[Vector2i] = []
	var spare_edges: Array[Vector2i] = []
	for edge in candidate_edges:
		if _union_sets(parents, tree_sizes, edge.x, edge.y):
			selected_edges.append(edge)
		else:
			spare_edges.append(edge)

	var requested_extra_edge_count := roundi(
		config.extra_edge_ratio * float(spare_edges.size())
	)
	for extra_edge_index in range(
		clampi(requested_extra_edge_count, 0, spare_edges.size())
	):
		selected_edges.append(spare_edges[extra_edge_index])
	selected_edges.sort_custom(func(first: Vector2i, second: Vector2i) -> bool:
		if first.x != second.x:
			return first.x < second.x
		return first.y < second.y
	)

	var packed_edges := PackedInt32Array()
	packed_edges.resize(selected_edges.size() * 2)
	for edge_index in range(selected_edges.size()):
		packed_edges[edge_index * 2] = selected_edges[edge_index].x
		packed_edges[edge_index * 2 + 1] = selected_edges[edge_index].y
	return packed_edges


static func _generate_content(
	config: RogueRouteGenerationConfig,
	random: RandomNumberGenerator
) -> Dictionary:
	var node_count := config.get_node_count()
	var node_content_seeds := PackedInt64Array()
	node_content_seeds.resize(node_count)
	for node_id in range(node_count):
		node_content_seeds[node_id] = int(random.randi())

	var target_empty_ratio := clampf(
		config.empty_ratio
		+ random.randf_range(
			-config.empty_ratio_jitter,
			config.empty_ratio_jitter
		),
		0.0,
		1.0
	)
	var minimum_empty_count := maxi(
		1,
		node_count - config.get_maximum_non_empty_count()
	)
	var maximum_empty_count := node_count - config.get_minimum_non_empty_count()
	var empty_count := clampi(
		roundi(float(node_count) * target_empty_ratio),
		minimum_empty_count,
		maximum_empty_count
	)
	var start_node_id := config.get_center_node_id()

	var noise := FastNoiseLite.new()
	noise.seed = int(random.randi() & 0x7FFFFFFF)
	noise.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	noise.frequency = CONTENT_NOISE_FREQUENCY
	var scored_candidates: Array[Dictionary] = []
	for node_id in range(node_count):
		if node_id == start_node_id:
			continue
		var coord := Vector2i(node_id % config.width, node_id / config.width)
		var uniform_score := random.randf()
		var spatial_score := clampf(
			(noise.get_noise_2d(float(coord.x), float(coord.y)) + 1.0) * 0.5,
			0.0,
			1.0
		)
		scored_candidates.append({
			"node_id": node_id,
			"score": lerpf(
				uniform_score,
				spatial_score,
				config.empty_cluster_strength
			),
		})
	scored_candidates.sort_custom(func(first: Dictionary, second: Dictionary) -> bool:
		var first_score := float(first["score"])
		var second_score := float(second["score"])
		if not is_equal_approx(first_score, second_score):
			return first_score > second_score
		return int(first["node_id"]) < int(second["node_id"])
	)

	var node_types := PackedByteArray()
	node_types.resize(node_count)
	node_types.fill(RogueRouteGraph.NodeType.EMPTY)
	var empty_node_ids: Dictionary = {start_node_id: true}
	for empty_index in range(empty_count - 1):
		empty_node_ids[int(scored_candidates[empty_index]["node_id"])] = true

	var non_empty_node_ids: Array[int] = []
	for node_id in range(node_count):
		if not empty_node_ids.has(node_id):
			non_empty_node_ids.append(node_id)
	_shuffle_ints(non_empty_node_ids, random)

	var type_configs: Array[RogueRouteNodeTypeConfig] = []
	type_configs.assign(config.node_type_catalog)
	type_configs.sort_custom(
		func(
			first: RogueRouteNodeTypeConfig,
			second: RogueRouteNodeTypeConfig
		) -> bool:
			return first.node_type < second.node_type
	)
	var generated_types: Array[int] = []
	var generated_counts: Dictionary[int, int] = {}
	for type_config in type_configs:
		generated_counts[type_config.node_type] = 0
		for _minimum_index in range(type_config.minimum_count):
			generated_types.append(type_config.node_type)
			generated_counts[type_config.node_type] += 1
	while generated_types.size() < non_empty_node_ids.size():
		var next_type := _roll_weighted_type(
			type_configs,
			generated_counts,
			random
		)
		if next_type == RogueRouteGraph.NodeType.EMPTY:
			push_error("路线节点类型容量不足，无法填满非空节点。")
			return {}
		generated_types.append(next_type)
		generated_counts[next_type] = generated_counts.get(next_type, 0) + 1
	_shuffle_ints(generated_types, random)
	for assignment_index in range(non_empty_node_ids.size()):
		node_types[non_empty_node_ids[assignment_index]] = generated_types[assignment_index]

	return {
		"node_types": node_types,
		"node_content_seeds": node_content_seeds,
	}


static func _generate_visual_offsets(
	config: RogueRouteGenerationConfig,
	random: RandomNumberGenerator
) -> PackedVector2Array:
	var result := PackedVector2Array()
	result.resize(config.get_node_count())
	var start_node_id := config.get_center_node_id()
	for node_id in range(result.size()):
		if node_id == start_node_id:
			result[node_id] = Vector2.ZERO
			continue
		result[node_id] = Vector2(
			random.randi_range(
				-config.visual_jitter_pixels.x,
				config.visual_jitter_pixels.x
			),
			random.randi_range(
				-config.visual_jitter_pixels.y,
				config.visual_jitter_pixels.y
			)
		)
	return result


static func _roll_weighted_type(
	type_configs: Array[RogueRouteNodeTypeConfig],
	generated_counts: Dictionary[int, int],
	random: RandomNumberGenerator
) -> int:
	var total_weight := 0.0
	var fallback_type := RogueRouteGraph.NodeType.EMPTY
	for type_config in type_configs:
		if not _has_remaining_capacity(type_config, generated_counts):
			continue
		total_weight += maxf(type_config.generation_weight, 0.0)
		if type_config.generation_weight > 0.0:
			fallback_type = type_config.node_type
	if total_weight <= 0.0:
		return RogueRouteGraph.NodeType.EMPTY
	var roll := random.randf() * total_weight
	for type_config in type_configs:
		if not _has_remaining_capacity(type_config, generated_counts):
			continue
		roll -= maxf(type_config.generation_weight, 0.0)
		if roll <= 0.0:
			return type_config.node_type
	return fallback_type


static func _has_remaining_capacity(
	type_config: RogueRouteNodeTypeConfig,
	generated_counts: Dictionary[int, int]
) -> bool:
	return (
		type_config.maximum_count == 0
		or generated_counts.get(type_config.node_type, 0) < type_config.maximum_count
	)


static func _find_root(parents: Array[int], node_id: int) -> int:
	var root := node_id
	while parents[root] != root:
		root = parents[root]
	while parents[node_id] != node_id:
		var next_node_id := parents[node_id]
		parents[node_id] = root
		node_id = next_node_id
	return root


static func _union_sets(
	parents: Array[int],
	tree_sizes: Array[int],
	first_node_id: int,
	second_node_id: int
) -> bool:
	var first_root := _find_root(parents, first_node_id)
	var second_root := _find_root(parents, second_node_id)
	if first_root == second_root:
		return false
	if tree_sizes[first_root] < tree_sizes[second_root]:
		var temporary_root := first_root
		first_root = second_root
		second_root = temporary_root
	parents[second_root] = first_root
	tree_sizes[first_root] += tree_sizes[second_root]
	return true


static func _shuffle_edges(
	values: Array[Vector2i],
	random: RandomNumberGenerator
) -> void:
	for source_index in range(values.size() - 1, 0, -1):
		var target_index := random.randi_range(0, source_index)
		var temporary := values[source_index]
		values[source_index] = values[target_index]
		values[target_index] = temporary


static func _shuffle_ints(
	values: Array[int],
	random: RandomNumberGenerator
) -> void:
	for source_index in range(values.size() - 1, 0, -1):
		var target_index := random.randi_range(0, source_index)
		var temporary := values[source_index]
		values[source_index] = values[target_index]
		values[target_index] = temporary
