@tool
extends Resource
class_name RogueRouteNodeTypeConfig

@export var type_id: StringName = &""
@export_enum(
	"神奇遭遇:1",
	"紧急作战:2",
	"普通作战:3",
	"遗址物资:4",
	"地下商店:5",
	"未雨绸缪:6"
) var node_type: int = RogueRouteGraph.NodeType.MAGICAL_ENCOUNTER
@export var display_name: String = ""
@export var icon: Texture2D = null
@export_range(0.0, 1000.0, 0.01, "or_greater") var generation_weight := 1.0
@export_range(0, 99, 1, "or_greater") var minimum_count := 1
## 0 表示不设上限；正数上限同时约束保底数量与后续权重抽取。
@export_range(0, 99, 1, "or_greater") var maximum_count := 0
## 由路线内容注册表解析为具体遭遇、战斗地图或商店内容。
@export var content_pool_id: StringName = &""


func validate_config() -> PackedStringArray:
	var errors := PackedStringArray()
	if type_id == &"":
		errors.append("路线节点类型缺少 type_id。")
	if (
		node_type < RogueRouteGraph.NodeType.MAGICAL_ENCOUNTER
		or node_type > RogueRouteGraph.NodeType.PREPARE_AHEAD
	):
		errors.append("路线节点 %s 使用了未知 node_type。" % String(type_id))
	if display_name.strip_edges().is_empty():
		errors.append("路线节点 %s 缺少 display_name。" % String(type_id))
	if icon == null:
		errors.append("路线节点 %s 缺少 icon。" % String(type_id))
	if not is_finite(generation_weight) or generation_weight < 0.0:
		errors.append("路线节点 %s 的生成权重无效。" % String(type_id))
	if minimum_count < 0:
		errors.append("路线节点 %s 的 minimum_count 不能为负数。" % String(type_id))
	if maximum_count < 0:
		errors.append("路线节点 %s 的 maximum_count 不能为负数。" % String(type_id))
	elif maximum_count > 0 and maximum_count < minimum_count:
		errors.append(
			"路线节点 %s 的 maximum_count 不能小于 minimum_count。"
			% String(type_id)
		)
	return errors
