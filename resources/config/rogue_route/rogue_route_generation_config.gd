@tool
extends Resource
class_name RogueRouteGenerationConfig

@export_group("地图尺寸")
@export_range(3, 31, 2) var width := 11
@export_range(3, 31, 2) var height := 9

@export_group("内容分布")
@export_range(0.0, 1.0, 0.01) var empty_ratio := 0.50
## 控制不同 seed 之间空节点总量的变化区间。
@export_range(0.0, 0.49, 0.01) var empty_ratio_jitter := 0.06
## 0 为独立均匀散布，1 为完全服从低频空间场，数值越高越容易成片。
@export_range(0.0, 1.0, 0.01) var empty_cluster_strength := 0.30
@export var node_type_catalog: Array[RogueRouteNodeTypeConfig] = []

@export_group("路线连接")
## 生成树之外补充的可用相邻边比例；0 是树，1 是完整四邻接网格。
@export_range(0.0, 1.0, 0.01) var extra_edge_ratio := 0.20

@export_group("行动力")
@export_range(0, 9999, 1, "or_greater") var initial_action_points := 12
@export_range(1, 999, 1, "or_greater") var move_action_cost := 1

@export_group("视觉数据")
## 视觉层可直接使用生成快照中的整数像素偏移；中心起点始终为零偏移。
@export var visual_jitter_pixels := Vector2i(7, 5)


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
		if type_config == null:
			continue
		if type_config.generation_weight > 0.0:
			if type_config.maximum_count == 0:
				return get_node_count() - 1
			result += type_config.maximum_count
		else:
			result += type_config.minimum_count
	return mini(result, get_node_count() - 1)


func get_type_config(node_type: int) -> RogueRouteNodeTypeConfig:
	for type_config in node_type_catalog:
		if type_config != null and type_config.node_type == node_type:
			return type_config
	return null


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
		"schema=1",
		"size=%d,%d" % [width, height],
		"move_cost=%d" % move_action_cost,
		"visual_jitter=%d,%d" % [
			visual_jitter_pixels.x,
			visual_jitter_pixels.y,
		],
		"world_metrics=%s" % world_metrics.compute_contract_hash(),
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
	if width < 3 or height < 3:
		errors.append("路线图宽高必须至少为 3。")
	if width % 2 == 0 or height % 2 == 0:
		errors.append("路线图宽高必须为奇数，才能提供唯一中心格。")
	if width > 31 or height > 31:
		errors.append("路线图宽高不能超过 31。")
	if not is_finite(empty_ratio) or empty_ratio < 0.0 or empty_ratio > 1.0:
		errors.append("empty_ratio 必须位于 0 到 1。")
	if (
		not is_finite(empty_ratio_jitter)
		or empty_ratio_jitter < 0.0
		or empty_ratio_jitter >= 0.5
	):
		errors.append("empty_ratio_jitter 必须位于 0（含）到 0.5（不含）。")
	if (
		not is_finite(empty_cluster_strength)
		or empty_cluster_strength < 0.0
		or empty_cluster_strength > 1.0
	):
		errors.append("empty_cluster_strength 必须位于 0 到 1。")
	if (
		not is_finite(extra_edge_ratio)
		or extra_edge_ratio < 0.0
		or extra_edge_ratio > 1.0
	):
		errors.append("extra_edge_ratio 必须位于 0 到 1。")
	if initial_action_points < 0:
		errors.append("initial_action_points 不能为负数。")
	if move_action_cost <= 0:
		errors.append("move_action_cost 必须大于零。")
	if visual_jitter_pixels.x < 0 or visual_jitter_pixels.y < 0:
		errors.append("visual_jitter_pixels 不能为负数。")

	var seen_ids: Dictionary = {}
	var seen_node_types: Dictionary = {}
	var positive_weight_sum := 0.0
	for type_config in node_type_catalog:
		if type_config == null:
			errors.append("node_type_catalog 中包含空资源。")
			continue
		errors.append_array(type_config.validate_config())
		if type_config.type_id != &"":
			if seen_ids.has(type_config.type_id):
				errors.append("路线节点包含重复 type_id：%s。" % String(type_config.type_id))
			else:
				seen_ids[type_config.type_id] = true
		if seen_node_types.has(type_config.node_type):
			errors.append("路线节点类型 %d 被重复注册。" % type_config.node_type)
		else:
			seen_node_types[type_config.node_type] = true
		positive_weight_sum += maxf(type_config.generation_weight, 0.0)

	for expected_type in range(
		RogueRouteGraph.NodeType.MAGICAL_ENCOUNTER,
		RogueRouteGraph.NodeType.PREPARE_AHEAD + 1
	):
		if not seen_node_types.has(expected_type):
			errors.append("路线图缺少非空节点类型 %d。" % expected_type)
	if positive_weight_sum <= 0.0:
		errors.append("路线图至少需要一个正数生成权重。")

	var node_count := get_node_count()
	var minimum_non_empty_count := get_minimum_non_empty_count()
	var maximum_non_empty_count := get_maximum_non_empty_count()
	if minimum_non_empty_count > node_count - 1:
		errors.append("六类节点的 minimum_count 无法装入保留中心空格后的地图。")
	if maximum_non_empty_count < minimum_non_empty_count:
		errors.append("六类节点的 maximum_count 无法容纳各类型 minimum_count。")
	var requested_max_empty := roundi(
		float(node_count) * minf(empty_ratio + empty_ratio_jitter, 1.0)
	)
	if requested_max_empty > node_count - minimum_non_empty_count:
		errors.append("空节点比例上限无法为各类型保留 minimum_count。")
	var requested_min_empty := roundi(
		float(node_count) * maxf(empty_ratio - empty_ratio_jitter, 0.0)
	)
	if requested_min_empty < node_count - maximum_non_empty_count:
		errors.append("空节点比例下限会超出节点类型的 maximum_count 总容量。")
	return errors
