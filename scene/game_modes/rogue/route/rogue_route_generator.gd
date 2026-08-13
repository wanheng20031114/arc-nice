extends RefCounted
class_name RogueRouteGenerator

## 模板/出生、内容与视觉使用互不共享状态的随机流。修改任一维度时，不会
## 串扰其他维度的确定性结果。
const TOPOLOGY_STREAM_SALT := 0x13579BDF2468ACE
const CONTENT_STREAM_SALT := 0x2468ACE13579BDF
const VISUAL_STREAM_SALT := 0x51A7E2D439C06BF


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
	var template := _select_template(config, topology_rng)
	if template == null:
		push_error("RogueRouteGenerator 未能选出地图模板。")
		return null
	var start_node_id := _select_start_node(config, template, topology_rng)
	if start_node_id < 0:
		push_error("RogueRouteGenerator 未能选出满足规则的出生点。")
		return null
	var content_data := _generate_content(
		config,
		template,
		start_node_id,
		content_rng
	)
	if content_data.is_empty():
		return null
	var generated_visual_offsets := _generate_visual_offsets(
		template.get_node_count(),
		start_node_id,
		config.visual_jitter_pixels,
		visual_rng
	)

	var graph := RogueRouteGraph.new()
	var layout_errors := graph.initialize_layout(
		generation_seed,
		template.width,
		template.height,
		start_node_id,
		content_data["node_types"] as PackedByteArray,
		content_data["node_content_seeds"] as PackedInt64Array,
		generated_visual_offsets,
		template.edges,
		template.template_id,
		template.node_coords
	)
	if layout_errors.is_empty():
		layout_errors.append_array(config.validate_graph_template(graph))
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


static func _select_template(
	config: RogueRouteGenerationConfig,
	random: RandomNumberGenerator
) -> RogueRouteTemplateConfig:
	var sorted_templates := config.get_sorted_templates()
	var total_weight := 0.0
	for template in sorted_templates:
		total_weight += maxf(template.selection_weight, 0.0)
	if total_weight <= 0.0:
		return null
	var roll := random.randf() * total_weight
	for template in sorted_templates:
		roll -= maxf(template.selection_weight, 0.0)
		if roll <= 0.0:
			return template
	return sorted_templates.back() if not sorted_templates.is_empty() else null


static func _select_start_node(
	config: RogueRouteGenerationConfig,
	template: RogueRouteTemplateConfig,
	random: RandomNumberGenerator
) -> int:
	var candidates := template.get_valid_start_node_ids(
		config.start_max_manhattan_distance,
		config.start_minimum_non_empty_count
	)
	if candidates.is_empty():
		return -1
	return int(candidates[random.randi_range(0, candidates.size() - 1)])


static func _generate_content(
	config: RogueRouteGenerationConfig,
	template: RogueRouteTemplateConfig,
	start_node_id: int,
	random: RandomNumberGenerator
) -> Dictionary:
	var node_count := template.get_node_count()
	var node_content_seeds := PackedInt64Array()
	node_content_seeds.resize(node_count)
	for node_id in range(node_count):
		node_content_seeds[node_id] = int(random.randi())

	var type_configs: Array[RogueRouteNodeTypeConfig] = []
	type_configs.assign(config.node_type_catalog)
	type_configs.sort_custom(func(
		first: RogueRouteNodeTypeConfig,
		second: RogueRouteNodeTypeConfig
	) -> bool:
		return first.node_type < second.node_type
	)
	var generated_types: Array[int] = []
	for type_config in type_configs:
		var target_count := random.randi_range(
			type_config.minimum_count,
			type_config.maximum_count
		)
		for _count_index in range(target_count):
			generated_types.append(type_config.node_type)

	if generated_types.size() > node_count - 1:
		push_error("路线模板无法容纳本次抽取的全部非空节点。")
		return {}

	var start_coord := template.get_node_coord(start_node_id)
	var nearby_node_ids: Array[int] = []
	var remaining_node_ids: Array[int] = []
	for node_id in range(node_count):
		if node_id == start_node_id:
			continue
		var coord := template.get_node_coord(node_id)
		var distance := (
			absi(coord.x - start_coord.x) + absi(coord.y - start_coord.y)
		)
		if distance >= 1 and distance <= config.start_max_manhattan_distance:
			nearby_node_ids.append(node_id)
		else:
			remaining_node_ids.append(node_id)
	_shuffle_ints(nearby_node_ids, random)
	if nearby_node_ids.size() < config.start_minimum_non_empty_count:
		push_error("出生点附近实际节点不足，无法满足非空节点保底。")
		return {}

	var selected_node_ids: Array[int] = []
	for nearby_index in range(config.start_minimum_non_empty_count):
		selected_node_ids.append(nearby_node_ids[nearby_index])
	for nearby_index in range(
		config.start_minimum_non_empty_count,
		nearby_node_ids.size()
	):
		remaining_node_ids.append(nearby_node_ids[nearby_index])
	_shuffle_ints(remaining_node_ids, random)
	var remaining_selection_count := (
		generated_types.size() - selected_node_ids.size()
	)
	if remaining_selection_count < 0:
		push_error("非空节点总数小于出生点附近保底。")
		return {}
	for selection_index in range(remaining_selection_count):
		selected_node_ids.append(remaining_node_ids[selection_index])

	_shuffle_ints(selected_node_ids, random)
	_shuffle_ints(generated_types, random)
	var node_types := PackedByteArray()
	node_types.resize(node_count)
	node_types.fill(RogueRouteGraph.NodeType.EMPTY)
	for assignment_index in range(generated_types.size()):
		node_types[selected_node_ids[assignment_index]] = (
			generated_types[assignment_index]
		)

	return {
		"node_types": node_types,
		"node_content_seeds": node_content_seeds,
	}


static func _generate_visual_offsets(
	node_count: int,
	start_node_id: int,
	maximum_jitter: Vector2i,
	random: RandomNumberGenerator
) -> PackedVector2Array:
	var result := PackedVector2Array()
	result.resize(node_count)
	for node_id in range(node_count):
		if node_id == start_node_id:
			result[node_id] = Vector2.ZERO
			continue
		result[node_id] = Vector2(
			random.randi_range(-maximum_jitter.x, maximum_jitter.x),
			random.randi_range(-maximum_jitter.y, maximum_jitter.y)
		)
	return result


static func _shuffle_ints(
	values: Array[int],
	random: RandomNumberGenerator
) -> void:
	for source_index in range(values.size() - 1, 0, -1):
		var target_index := random.randi_range(0, source_index)
		var temporary := values[source_index]
		values[source_index] = values[target_index]
		values[target_index] = temporary
