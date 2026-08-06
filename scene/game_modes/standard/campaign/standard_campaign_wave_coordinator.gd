extends Node
class_name StandardCampaignWaveCoordinator

signal wave_music_requested(wave_config: WaveConfig)
signal post_wave_music_requested(cleared_step: FlowStepConfig)
signal boss_step_requested(boss_config: BossConfig)
signal remote_boss_state_requested(
	state: CombatFlowState.State,
	boss_config: BossConfig
)

var flow_graph: FlowGraphConfig = null
var bosses: Array[Resource] = []
var wave_hud: StandardWaveHUD = null
var countdown_audio: AudioStreamPlayer = null
var wave_start_audio: AudioStreamPlayer = null


func bind_presentation(
	hud: StandardWaveHUD,
	countdown_player: AudioStreamPlayer,
	wave_start_player: AudioStreamPlayer
) -> void:
	wave_hud = hud
	countdown_audio = countdown_player
	wave_start_audio = wave_start_player


func initialize_campaign(campaign: WaveCampaignConfig) -> bool:
	flow_graph = null
	bosses.clear()
	if campaign == null:
		return false
	flow_graph = campaign.flow_graph
	for configured_boss in campaign.get_bosses():
		bosses.append(configured_boss)
	return flow_graph != null


func replace_bosses(configured_bosses: Array[Resource]) -> void:
	bosses.assign(configured_bosses)


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


func present_flow_countdown(seconds: int) -> void:
	if wave_hud != null:
		wave_hud.show_countdown(seconds)


func present_wave_started(
	wave_config: WaveConfig,
	is_remote: bool,
	wave_number: int,
	defeated_count: int,
	total_count: int
) -> void:
	if wave_config != null:
		wave_music_requested.emit(wave_config)
	if wave_hud != null:
		if is_remote:
			wave_hud.show_enemy_count(maxi(wave_number, 1), 0)
		else:
			wave_hud.show_wave_progress(
				maxi(wave_number, 1),
				defeated_count,
				total_count
			)
	if wave_start_audio != null:
		wave_start_audio.play()


func present_wave_progress(
	wave_number: int,
	defeated_count: int,
	total_count: int
) -> void:
	if wave_hud != null:
		wave_hud.show_wave_progress(
			maxi(wave_number, 1),
			defeated_count,
			total_count
		)


func present_remote_enemy_count(wave_number: int, alive_count: int) -> void:
	if wave_hud != null:
		wave_hud.show_enemy_count(maxi(wave_number, 1), alive_count)


func hide_wave_presentation() -> void:
	if wave_hud != null:
		wave_hud.hide_all()


func present_countdown_tick() -> void:
	if countdown_audio == null:
		return
	countdown_audio.pitch_scale = 1.0
	countdown_audio.play()


func present_intermission_started(cleared_step: FlowStepConfig) -> void:
	post_wave_music_requested.emit(cleared_step)


func begin_mode_flow_step(flow_step: FlowStepConfig) -> bool:
	var boss_config := flow_step as BossConfig
	if boss_config == null:
		return false
	boss_step_requested.emit(boss_config)
	return true


func apply_remote_mode_flow_state(
	state: CombatFlowState.State,
	flow_step: FlowStepConfig
) -> bool:
	var boss_config := flow_step as BossConfig
	if boss_config == null:
		return false
	if state not in [
		CombatFlowState.State.BOSS_INTRO,
		CombatFlowState.State.BOSS_ACTIVE,
	]:
		return false
	remote_boss_state_requested.emit(state, boss_config)
	return true
