@tool
extends Resource
class_name WaveCampaignConfig

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
	var errors := PackedStringArray()
	if campaign_id == &"":
		errors.append("Campaign 缺少 campaign_id。")
	if flow_graph == null:
		errors.append("Campaign %s 缺少 FlowGraphConfig。" % String(campaign_id))
		return errors

	errors.append_array(flow_graph.validate_graph())
	var waves := get_waves()
	if waves.is_empty():
		errors.append("Campaign %s 不包含任何 WaveConfig。" % String(campaign_id))
	for wave_config in waves:
		if wave_config.spawn_point_mask == 0:
			errors.append(
				"Campaign %s 的波次 %s 没有启用出生点。"
				% [String(campaign_id), wave_config.get_flow_display_name()]
			)
		elif wave_config.spawn_point_mask & ~WaveConfig.ALL_SPAWN_POINT_MASK:
			errors.append(
				"Campaign %s 的波次 %s 包含未知出生点位。"
				% [String(campaign_id), wave_config.get_flow_display_name()]
			)
	return errors
