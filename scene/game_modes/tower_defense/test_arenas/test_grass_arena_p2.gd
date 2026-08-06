extends TestGrassArena
class_name TestGrassArenaP2


@onready var test_controls_layer: CanvasLayer = $TestControlsHint


func _ready() -> void:
	# P2 把唯一终点波视为完整一天，并显式请求终点命运间奏。
	campaign_coordinator.terminal_wave_enters_fate_interlude = true
	campaign_coordinator.terminal_wave_fate_interlude_started.connect(
		_on_terminal_wave_fate_interlude_started
	)
	campaign_coordinator.result_entered.connect(_on_campaign_result_entered)
	campaign_coordinator.remote_flow_state_applied.connect(
		_on_campaign_remote_flow_state_applied
	)
	super._ready()


func _on_terminal_wave_fate_interlude_started() -> void:
	_set_test_controls_hint_visible(false)


func _on_campaign_result_entered(_state: CombatFlowState.State) -> void:
	_set_test_controls_hint_visible(false)


func _on_campaign_remote_flow_state_applied(
	_step_id: StringName,
	state: CombatFlowState.State,
	_seconds: int
) -> void:
	if state in [
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
