extends Node
class_name TowerDefenseCampaignCoordinator

var active_campaign: WaveCampaignConfig = null
var singleplayer_campaign: WaveCampaignConfig = null
var multiplayer_campaign: WaveCampaignConfig = null
var flow_graph: FlowGraphConfig = null
var waves: Array[WaveConfig] = []
var bosses: Array[Resource] = []
var day_cycle_config: DayCycleConfig = null
var configuration_errors: PackedStringArray = []


func configure(
	runtime_mode: int,
	definition: GameModeDefinition,
	singleplayer_campaign: WaveCampaignConfig,
	multiplayer_campaign: WaveCampaignConfig,
	configured_day_cycle: DayCycleConfig
) -> bool:
	clear()
	day_cycle_config = configured_day_cycle
	var resolved_singleplayer := singleplayer_campaign
	var resolved_multiplayer := multiplayer_campaign
	if (
		definition != null
		and resolved_singleplayer == null
		and not definition.singleplayer_campaign_path.is_empty()
	):
		resolved_singleplayer = load(
			definition.singleplayer_campaign_path
		) as WaveCampaignConfig
	if (
		definition != null
		and resolved_multiplayer == null
		and not definition.multiplayer_campaign_path.is_empty()
	):
		resolved_multiplayer = load(
			definition.multiplayer_campaign_path
		) as WaveCampaignConfig
	self.singleplayer_campaign = resolved_singleplayer
	self.multiplayer_campaign = resolved_multiplayer
	active_campaign = (
		resolved_singleplayer
		if runtime_mode == CombatRuntimeBase.RuntimeMode.SINGLEPLAYER
		else resolved_multiplayer
	)
	if active_campaign == null:
		configuration_errors.append(
			"TowerDefense Campaign 缺少当前运行模式的 WaveCampaignConfig。"
		)
		return false
	configuration_errors.append_array(active_campaign.validate_campaign())
	if not configuration_errors.is_empty():
		return false
	flow_graph = active_campaign.flow_graph
	waves.assign(active_campaign.get_waves())
	for boss_config in active_campaign.get_bosses():
		bosses.append(boss_config)
	return true


func clear() -> void:
	active_campaign = null
	singleplayer_campaign = null
	multiplayer_campaign = null
	flow_graph = null
	waves.clear()
	bosses.clear()
	configuration_errors.clear()


func replace_runtime_state_for_fixture(
	fixture_flow_graph: FlowGraphConfig,
	fixture_waves: Array[WaveConfig],
	fixture_bosses: Array[Resource]
) -> void:
	flow_graph = fixture_flow_graph
	waves.assign(fixture_waves)
	bosses.assign(fixture_bosses)


func validate_flow_graph() -> PackedStringArray:
	if flow_graph == null:
		return PackedStringArray([
			"TowerDefense Campaign 没有配置 FlowGraphConfig。",
		])
	return flow_graph.validate_graph()


func get_start_flow_step() -> FlowStepConfig:
	return flow_graph.start_step if flow_graph != null else null


func get_flow_step_by_id(step_id: StringName) -> FlowStepConfig:
	if step_id == &"" or flow_graph == null:
		return null
	return flow_graph.get_step_by_id(step_id)


func get_flow_step_id(flow_step: FlowStepConfig) -> StringName:
	return flow_step.step_id if flow_step != null else &""


func get_default_next_flow_step(flow_step: FlowStepConfig) -> FlowStepConfig:
	if (
		flow_step == null
		or flow_graph == null
		or flow_graph.get_step_index(flow_step) < 0
	):
		return null
	return flow_graph.get_default_next_step(flow_step)


func get_wave_number_for_step(
	wave_config: WaveConfig,
	fallback_wave_index: int
) -> int:
	if wave_config == null:
		return fallback_wave_index + 1
	var wave_index := waves.find(wave_config)
	if wave_index >= 0:
		return wave_index + 1
	if flow_graph != null:
		var wave_number := 0
		for step in flow_graph.steps:
			if step is WaveConfig:
				wave_number += 1
			if step == wave_config:
				return maxi(wave_number, 1)
	return fallback_wave_index + 1


func get_configured_bosses() -> Array[BossConfig]:
	var result: Array[BossConfig] = []
	if flow_graph != null:
		for step in flow_graph.steps:
			var boss_step := step as BossConfig
			if boss_step != null:
				result.append(boss_step)
	if result.is_empty():
		for boss_resource in bosses:
			var boss_config := boss_resource as BossConfig
			if boss_config != null:
				result.append(boss_config)
	return result


func is_night_wave(wave_number: int) -> bool:
	return day_cycle_config != null and day_cycle_config.is_night_wave(wave_number)


func is_night_intermission_after_wave(completed_wave_number: int) -> bool:
	return (
		day_cycle_config != null
		and day_cycle_config.is_night_intermission_after_wave(completed_wave_number)
	)


func get_day_number_for_wave(wave_number: int) -> int:
	return day_cycle_config.get_day_number(wave_number) if day_cycle_config != null else 1


func get_wave_in_day(wave_number: int) -> int:
	return day_cycle_config.get_wave_in_day(wave_number) if day_cycle_config != null else 1


func is_day_end_wave(wave_number: int) -> bool:
	return day_cycle_config != null and day_cycle_config.is_day_end_wave(wave_number)


func should_record_day(
	runtime_mode: int,
	day_number: int,
	existing_records: Array[Dictionary]
) -> bool:
	if runtime_mode == CombatRuntimeBase.RuntimeMode.CLIENT_VIEW or day_number <= 0:
		return false
	for record in existing_records:
		if int(record.get("day", 0)) == day_number:
			return false
	return true
