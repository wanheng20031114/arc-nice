@tool
extends Resource
class_name RogueRouteGenerationConfig

## 无布局时的编辑器/场景回退画布；正式路线尺寸来自抽中的模板。
@export_group("回退画布")
@export_range(1, 31, 1, "or_greater") var width := 11
@export_range(1, 31, 1, "or_greater") var height := 9

@export_group("地图模板")
@export var templates: Array[RogueRouteTemplateConfig] = []

@export_group("出生规则")
@export_range(1, 8, 1, "or_greater") var start_max_manhattan_distance := 2
@export_range(1, 99, 1, "or_greater") var start_minimum_non_empty_count := 6

@export_group("内容分布")
@export var node_type_catalog: Array[RogueRouteNodeTypeConfig] = []

## 以下字段保留为旧资源/工具的只读兼容数据。模板化生成不再读取它们。
@export_group("旧生成参数（不再使用）")
@export_range(0.0, 1.0, 0.01) var empty_ratio := 0.50
@export_range(0.0, 0.49, 0.01) var empty_ratio_jitter := 0.06
@export_range(0.0, 1.0, 0.01) var empty_cluster_strength := 0.30
@export_range(0.0, 1.0, 0.01) var extra_edge_ratio := 0.20

@export_group("行动力")
@export_range(0, 9999, 1, "or_greater") var initial_action_points := 12
@export_range(1, 999, 1, "or_greater") var move_action_cost := 1

@export_group("视觉数据")
@export var visual_jitter_pixels := Vector2i(7, 5)


## 兼容旧场景在图快照到达前查询默认画布节点数。
func get_node_count() -> int:
	return width * height


func get_center_coord() -> Vector2i:
	return Vector2i(width / 2, height / 2)


func get_center_node_id() -> int:
	var center := get_center_coord()
	return center.y * width + center.x


func get_minimum_non_empty_count() -> int:
	var result := 0
	for type_config in node_type_catalog:
		if type_config != null:
			result += maxi(type_config.minimum_count, 0)
	return result


func get_maximum_non_empty_count() -> int:
	var result := 0
	for type_config in node_type_catalog:
		if type_config != null:
			result += maxi(type_config.maximum_count, 0)
	return result


func get_type_config(node_type: int) -> RogueRouteNodeTypeConfig:
	for type_config in node_type_catalog:
		if type_config != null and type_config.node_type == node_type:
			return type_config
	return null


func get_template(template_id: StringName) -> RogueRouteTemplateConfig:
	if template_id == &"":
		return null
	for template in templates:
		if template != null and template.template_id == template_id:
			return template
	return null


func get_sorted_templates() -> Array[RogueRouteTemplateConfig]:
	var result: Array[RogueRouteTemplateConfig] = []
	for template in templates:
		if template != null:
			result.append(template)
	result.sort_custom(func(
		first: RogueRouteTemplateConfig,
		second: RogueRouteTemplateConfig
	) -> bool:
		return String(first.template_id) < String(second.template_id)
	)
	return result


## 对收到的网络图执行本地配置绑定校验，不能只信任可被一并重算的 layout_hash。
func validate_graph_template(graph: RogueRouteGraph) -> PackedStringArray:
	if graph == null:
		return PackedStringArray(["路线图为空。"])
	var template := get_template(graph.template_id)
	var errors := graph.validate_template_binding(template)
	if template == null:
		return errors
	var valid_start_node_ids := template.get_valid_start_node_ids(
		start_max_manhattan_distance,
		start_minimum_non_empty_count
	)
	if not valid_start_node_ids.has(graph.start_node_id):
		errors.append("路线图出生点不满足本地模板的非边缘/邻近节点规则。")
	elif graph.get_node_type(graph.start_node_id) != RogueRouteGraph.NodeType.EMPTY:
		errors.append("路线图出生点必须保持 EMPTY。")
	else:
		var start_coord := graph.get_start_coord()
		var nearby_non_empty_count := 0
		for node_id in range(graph.get_node_count()):
			if node_id == graph.start_node_id:
				continue
			var coord := graph.id_to_coord(node_id)
			var distance := (
				absi(coord.x - start_coord.x) + absi(coord.y - start_coord.y)
			)
			if (
				distance <= start_max_manhattan_distance
				and graph.get_node_type(node_id) != RogueRouteGraph.NodeType.EMPTY
			):
				nearby_non_empty_count += 1
		if nearby_non_empty_count < start_minimum_non_empty_count:
			errors.append(
				"路线图出生点附近非空节点少于配置保底：%d < %d。"
				% [nearby_non_empty_count, start_minimum_non_empty_count]
			)
	for type_config in node_type_catalog:
		if type_config == null:
			continue
		var actual_count := graph.get_node_ids_by_type(type_config.node_type).size()
		if (
			actual_count < type_config.minimum_count
			or actual_count > type_config.maximum_count
		):
			errors.append(
				"路线图节点 %s 数量越界：%d 不在 %d–%d。"
				% [
					String(type_config.type_id),
					actual_count,
					type_config.minimum_count,
					type_config.maximum_count,
				]
			)
	return errors


func compute_runtime_contract_hash(
	world_metrics: RogueRouteWorldMetrics
) -> String:
	if world_metrics == null:
		return ""
	var type_configs := node_type_catalog.duplicate()
	type_configs.sort_custom(func(
		first: RogueRouteNodeTypeConfig,
		second: RogueRouteNodeTypeConfig
	) -> bool:
		if first == null:
			return false
		if second == null:
			return true
		return first.node_type < second.node_type
	)
	var parts := PackedStringArray([
		"schema=2",
		"fallback_size=%d,%d" % [width, height],
		"start_rule=%d,%d" % [
			start_max_manhattan_distance,
			start_minimum_non_empty_count,
		],
		"move_cost=%d" % move_action_cost,
		"visual_jitter=%d,%d" % [
			visual_jitter_pixels.x,
			visual_jitter_pixels.y,
		],
		"world_metrics=%s" % world_metrics.compute_contract_hash(),
	])
	for template in get_sorted_templates():
		parts.append("template=%s:%.6f:%s" % [
			String(template.template_id),
			template.selection_weight,
			template.compute_topology_hash(),
		])
	for type_config in type_configs:
		if type_config == null:
			parts.append("type=null")
			continue
		parts.append("type=%d:%s:%s:%.6f:%d:%d" % [
			type_config.node_type,
			String(type_config.type_id),
			String(type_config.content_pool_id),
			type_config.generation_weight,
			type_config.minimum_count,
			type_config.maximum_count,
		])
	return "\n".join(parts).sha256_text()


func validate_config() -> PackedStringArray:
	var errors := PackedStringArray()
	if width <= 0 or height <= 0 or width > 31 or height > 31:
		errors.append("路线回退画布宽高必须位于 1 到 31。")
	if start_max_manhattan_distance <= 0:
		errors.append("出生点曼哈顿距离必须大于零。")
	if start_minimum_non_empty_count <= 0:
		errors.append("出生点附近非空节点保底必须大于零。")
	if initial_action_points < 0:
		errors.append("initial_action_points 不能为负数。")
	if move_action_cost <= 0:
		errors.append("move_action_cost 必须大于零。")
	if visual_jitter_pixels.x < 0 or visual_jitter_pixels.y < 0:
		errors.append("visual_jitter_pixels 不能为负数。")

	var seen_template_ids: Dictionary = {}
	var minimum_template_node_count := 2147483647
	var positive_template_weight_sum := 0.0
	if templates.is_empty():
		errors.append("路线生成配置至少需要一个地图模板。")
	for template in templates:
		if template == null:
			errors.append("templates 中包含空资源。")
			continue
		errors.append_array(template.validate_config())
		if template.template_id != &"":
			if seen_template_ids.has(template.template_id):
				errors.append(
					"路线生成配置包含重复 template_id：%s。"
					% String(template.template_id)
				)
			else:
				seen_template_ids[template.template_id] = true
		positive_template_weight_sum += maxf(template.selection_weight, 0.0)
		minimum_template_node_count = mini(
			minimum_template_node_count,
			template.get_node_count()
		)
		if template.get_valid_start_node_ids(
			start_max_manhattan_distance,
			start_minimum_non_empty_count
		).is_empty():
			errors.append(
				"路线模板 %s 不满足配置的出生点规则。"
				% String(template.template_id)
			)
	if not templates.is_empty() and positive_template_weight_sum <= 0.0:
		errors.append("路线模板总选择权重必须大于零。")

	var seen_ids: Dictionary = {}
	var seen_node_types: Dictionary = {}
	for type_config in node_type_catalog:
		if type_config == null:
			errors.append("node_type_catalog 中包含空资源。")
			continue
		errors.append_array(type_config.validate_config())
		if type_config.type_id != &"":
			if seen_ids.has(type_config.type_id):
				errors.append(
					"路线节点包含重复 type_id：%s。"
					% String(type_config.type_id)
				)
			else:
				seen_ids[type_config.type_id] = true
		if seen_node_types.has(type_config.node_type):
			errors.append("路线节点类型 %d 被重复注册。" % type_config.node_type)
		else:
			seen_node_types[type_config.node_type] = true
		if type_config.maximum_count <= 0:
			errors.append(
				"路线节点 %s 必须设置有限 maximum_count。"
				% String(type_config.type_id)
			)

	for expected_type in range(
		RogueRouteGraph.NodeType.MAGICAL_ENCOUNTER,
		RogueRouteGraph.NodeType.PREPARE_AHEAD + 1
	):
		if not seen_node_types.has(expected_type):
			errors.append("路线图缺少非空节点类型 %d。" % expected_type)

	var minimum_non_empty_count := get_minimum_non_empty_count()
	var maximum_non_empty_count := get_maximum_non_empty_count()
	if minimum_non_empty_count < start_minimum_non_empty_count:
		errors.append("非空节点最小总数无法满足出生点附近保底。")
	if minimum_template_node_count != 2147483647:
		if minimum_non_empty_count > minimum_template_node_count - 1:
			errors.append("最小非空节点总数无法装入最小模板并保留出生点。")
		if maximum_non_empty_count > minimum_template_node_count - 1:
			errors.append("最大非空节点总数无法装入最小模板并保留出生点。")
	return errors
