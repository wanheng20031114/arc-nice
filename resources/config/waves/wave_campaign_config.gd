@tool
extends Resource
class_name WaveCampaignConfig

const ContentValidationContextResource := preload(
	"res://resources/config/content_validation_context.gd"
)

@export var campaign_id: StringName = &""
@export var flow_graph: FlowGraphConfig


func get_waves() -> Array[WaveConfig]:
	var result: Array[WaveConfig] = []
	if flow_graph == null:
		return result
	for step in flow_graph.steps:
		var wave_config := step as WaveConfig
		if wave_config != null:
			result.append(wave_config)
	return result


func get_bosses() -> Array[BossConfig]:
	var result: Array[BossConfig] = []
	if flow_graph == null:
		return result
	for step in flow_graph.steps:
		var boss_config := step as BossConfig
		if boss_config != null:
			result.append(boss_config)
	return result


func validate_campaign() -> PackedStringArray:
	var context := ContentValidationContextResource.new()
	var campaign_label := (
		"Campaign[%s]" % String(campaign_id)
		if campaign_id != &""
		else "Campaign"
	)
	var campaign_path := ContentValidationContextResource.describe_resource(
		self,
		campaign_label
	)
	if campaign_id == &"":
		context.add_error(campaign_path, "缺少 campaign_id。")
	if flow_graph == null:
		context.add_error(campaign_path, "缺少 FlowGraphConfig。")
		return context.errors

	var graph_path := ContentValidationContextResource.child_path(campaign_path, "flow_graph")
	for graph_error in flow_graph.validate_graph():
		context.add_error(graph_path, graph_error)
	var waves := get_waves()
	if waves.is_empty():
		context.add_error(campaign_path, "不包含任何 WaveConfig。")

	# 内容闭包按 steps 的序列化顺序递归，保证错误顺序可重现。
	for step_index in range(flow_graph.steps.size()):
		var step := flow_graph.steps[step_index]
		var step_path := ContentValidationContextResource.child_path(
			graph_path,
			"steps[%d]" % step_index
		)
		var wave_config := step as WaveConfig
		if wave_config != null:
			wave_config.append_validation_errors(context, step_path)
			continue
		var boss_config := step as BossConfig
		if boss_config != null:
			boss_config.append_validation_errors(context, step_path)
	return context.errors
