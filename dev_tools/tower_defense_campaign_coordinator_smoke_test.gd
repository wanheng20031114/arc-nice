extends SceneTree

const TOWER_SCENE := preload(
	"res://scene/game_modes/tower_defense/tower_defense_game.tscn"
)

var failures: Array[String] = []


func _init() -> void:
	call_deferred(&"_run")


func _run() -> void:
	var game := TOWER_SCENE.instantiate() as TowerDefenseGame
	game.auto_start_waves = false
	root.add_child(game)
	current_scene = game
	await process_frame

	var campaign := game.campaign_coordinator
	_expect(campaign != null, "塔防场景缺少静态 CampaignCoordinator。")
	_expect(
		game.get_node_or_null("CampaignRuntimePort")
		is TowerDefenseCampaignRuntimePort,
		"塔防场景缺少静态 CampaignRuntimePort。"
	)
	_expect(campaign.is_runtime_bound(), "Campaign 强类型运行时依赖未完整绑定。")
	_expect(campaign.active_campaign != null, "Campaign 唯一 owner 未加载活动战役。")
	_expect(campaign.flow_graph != null, "Campaign 唯一 owner 未加载流程图。")
	_expect(campaign.get_start_flow_step() != null, "Campaign 流程缺少起点。")
	_expect(
		game.state_timer.timeout.is_connected(
			Callable(campaign, "on_state_timer_timeout")
		),
		"StateTimer 未静态连接 Campaign。"
	)
	_expect(
		game.enemy_coordinator.wave_completed.is_connected(
			Callable(campaign, "complete_current_step")
		),
		"Enemy 完成信号未直接连接 Campaign。"
	)
	for property_info in game.get_property_list():
		_expect(
			StringName(property_info.get("name", &"")) not in [
				&"active_campaign",
				&"flow_graph",
				&"waves",
				&"bosses",
			],
			"TowerDefenseGame 不得保留 Campaign 配置镜像。"
		)

	game.runtime_mode = CombatRuntimeBase.RuntimeMode.SINGLEPLAYER
	var start_step := campaign.get_start_flow_step()
	campaign.wave_state = CombatFlowState.State.PRE_WAVE
	campaign.current_flow_step = start_step
	campaign.next_flow_step_after_rest = start_step
	campaign.countdown_seconds = 9
	_expect(campaign.request_wave_start(), "单人准备阶段应允许收束倒计时。")
	_expect(
		campaign.countdown_seconds
		== TowerDefensePresentationCoordinator.COUNTDOWN_FINAL_SECONDS,
		"提前开波必须保持既有最终倒计时秒数。"
	)
	game.state_timer.stop()
	var snapshot := campaign.get_flow_state_snapshot()
	_expect(
		StringName(snapshot.get("step_id", &""))
		== campaign.get_flow_step_id(start_step),
		"流程快照 step_id 与 Campaign 状态不一致。"
	)
	_expect(
		int(snapshot.get("state", -1)) == int(CombatFlowState.State.PRE_WAVE),
		"流程快照状态与 Campaign 状态不一致。"
	)

	var entered_results: Array[CombatFlowState.State] = []
	campaign.result_entered.connect(
		func(state: CombatFlowState.State) -> void: entered_results.append(state)
	)
	var terminal_wave := WaveConfig.new()
	terminal_wave.step_id = &"campaign_smoke_terminal"
	campaign.current_flow_step = terminal_wave
	campaign.wave_state = CombatFlowState.State.WAVE_ACTIVE
	campaign.terminal_wave_enters_fate_interlude = false
	campaign.complete_current_step()
	_expect(
		campaign.wave_state == CombatFlowState.State.VICTORY,
		"无后继流程节点必须由 Campaign 进入胜利。"
	)
	_expect(
		entered_results == [CombatFlowState.State.VICTORY],
		"Campaign 胜利结果信号必须且只能发出一次。"
	)

	current_scene = null
	game.queue_free()
	for _cleanup_frame in range(4):
		await process_frame
		await physics_frame
	if failures.is_empty():
		print("TOWER_DEFENSE_CAMPAIGN_COORDINATOR_SMOKE_TEST_OK")
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	quit(1)


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
