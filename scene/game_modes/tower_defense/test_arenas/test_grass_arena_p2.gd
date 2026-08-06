extends TestGrassArena
class_name TestGrassArenaP2


@onready var test_controls_layer: CanvasLayer = $TestControlsHint


## P2 把唯一的终点波视为完整一天。正式流程会在终点波直接结算胜利，
## 因此这里显式进入同一套小葱命运间奏，并以空后继节点表示间奏后胜利。
func _complete_current_step() -> void:
	var completed_wave := current_flow_step as WaveConfig
	var campaign_waves := active_campaign.get_waves()
	var is_only_terminal_wave := (
		completed_wave != null
		and campaign_waves.size() == 1
		and campaign_waves[0] == completed_wave
		and _get_default_next_flow_step(current_flow_step) == null
	)
	if not is_only_terminal_wave:
		super._complete_current_step()
		return
	var completed_wave_number := _get_wave_number_for_step(completed_wave)
	_record_progression_day(_get_day_number_for_wave(completed_wave_number))
	_set_test_controls_hint_visible(false)
	_enter_xiaocong_fate_interlude(null)


func _enter_victory(emit_multiplayer: bool = true) -> void:
	_set_test_controls_hint_visible(false)
	super._enter_victory(emit_multiplayer)


func apply_remote_flow_state(step_id: StringName, state: int, seconds: int) -> void:
	super.apply_remote_flow_state(step_id, state, seconds)
	var typed_state := state as CombatFlowState.State
	if typed_state in [
		CombatFlowState.State.FATE_INTERLUDE,
		CombatFlowState.State.VICTORY,
		CombatFlowState.State.DEFEAT,
	]:
		_set_test_controls_hint_visible(false)


func _update_test_controls_hint() -> void:
	var controls_text := (
		"T：自由放置植物　L：切换昼夜　Del：摧毁周围3格植物"
		if runtime_mode == RuntimeMode.SINGLEPLAYER
		else (
			"T：自由放置植物　L/Del：仅房主可用"
			if runtime_mode == RuntimeMode.CLIENT_VIEW
			else "T：自由放置植物　L：切换昼夜（房主）　Del：摧毁周围3格植物（房主）"
		)
	)
	test_controls_hint.text = (
		"草地测试场景 P2｜击败普通史莱姆即完成一天\n"
		+ controls_text
	)


func _set_test_controls_hint_visible(should_show: bool) -> void:
	if test_controls_layer != null:
		test_controls_layer.visible = should_show
