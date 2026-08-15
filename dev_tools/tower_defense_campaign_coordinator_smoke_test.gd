extends SceneTree

const TOWER_SCENE := preload(
	"res://scene/game_modes/tower_defense/tower_defense_game.tscn"
)
const PERFORMANCE_CAMPAIGN: WaveCampaignConfig = preload(
	"res://resources/config/campaigns/tower_defense/performance/campaign.tres"
)
const FLOW_STATE_CLIENT_SOURCE_PATHS: Array[String] = [
	"res://scene/game_modes/tower_defense/fate/tower_defense_fate_flow_coordinator.gd",
	"res://scene/game_modes/tower_defense/rogue/tower_defense_rogue_exploration_coordinator.gd",
	"res://scene/game_modes/tower_defense/boss/tower_defense_boss_coordinator.gd",
	"res://scene/game_modes/tower_defense/multiplayer/tower_defense_multiplayer_mode_adapter.gd",
]

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
	_test_flow_state_write_ownership()
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
		campaign.is_formal_four_day_campaign()
		and campaign.should_enter_daily_rogue_exploration(4)
		and campaign.should_enter_daily_rogue_exploration(8)
		and campaign.should_enter_daily_rogue_exploration(12),
		"正式12波战役必须只在第4、8、12波后进入地下探索。"
	)
	var formal_campaign := campaign.active_campaign
	var formal_waves := campaign.waves.duplicate()
	campaign.active_campaign = PERFORMANCE_CAMPAIGN
	campaign.waves.assign(PERFORMANCE_CAMPAIGN.get_waves())
	_expect(
		campaign.waves.size() == 12
		and not campaign.is_formal_four_day_campaign()
		and not campaign.should_enter_daily_rogue_exploration(4),
		"12波性能战役不得被误判为正式四日战役或插入地下探索。"
	)
	campaign.active_campaign = formal_campaign
	campaign.waves.assign(formal_waves)
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

	campaign.reset_wave_progress(2)
	_expect(
		not campaign.try_resolve_wave_enemy_defeat()
		and not campaign.try_resolve_wave_enemy_escape(),
		"Campaign 不得结算尚未生成的敌人。"
	)
	_expect(
		campaign.record_wave_spawns(1) == 1
		and campaign.try_resolve_wave_enemy_defeat()
		and not campaign.try_resolve_wave_enemy_escape(),
		"Campaign 必须维持 resolved <= spawned，且同一生成额度只能结算一次。"
	)
	campaign.reset_wave_progress(0)
	_expect(
		campaign.apply_remote_wave_progress(1, 1, 0, 1, 2)
		and campaign.current_wave_resolved == 1
		and campaign.current_wave_spawned == 1,
		"远端波次进度必须维持 resolved <= spawned。"
	)
	_expect(
		campaign.apply_remote_wave_progress(2, 1, 1, 2, 3)
		and campaign.current_wave_index == 1
		and campaign.current_wave_spawned == 2
		and not campaign.apply_remote_wave_progress(1, 1, 0, 1, 2)
		and not campaign.apply_remote_wave_progress(2, 1, 0, 1, 3)
		and campaign.current_wave_resolved == 2,
		"远端波次 epoch 必须拒绝旧波和同波倒退包。"
	)
	campaign.reset_wave_progress(0)
	campaign.current_wave_index = 0

	game.runtime_mode = CombatRuntimeBase.RuntimeMode.SINGLEPLAYER
	var start_step := campaign.get_start_flow_step()
	campaign.replace_flow_state_for_fixture(
		CombatFlowState.State.PRE_WAVE,
		start_step,
		start_step,
		9
	)
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

	var boss_step := campaign.get_flow_step_by_id(&"boss_01_linglan")
	_expect(boss_step is BossConfig, "正式流程必须存在铃兰 Boss 步骤。")
	var typed_boss_step := boss_step as BossConfig
	var wave_five := campaign.get_flow_step_by_id(&"wave_05")
	game.state_timer.start(1.0)
	game.enemy_spawn_timer.start(1.0)
	campaign.transition_to_fate_interlude(boss_step)
	_expect(
		campaign.wave_state == CombatFlowState.State.FATE_INTERLUDE
		and campaign.next_flow_step_after_rest == boss_step
		and campaign.countdown_seconds == 0
		and game.state_timer.is_stopped()
		and game.enemy_spawn_timer.is_stopped(),
		"Fate typed transition 必须原子提交 next/state/countdown 并停止流程 timer。"
	)
	game.state_timer.start(1.0)
	game.enemy_spawn_timer.start(1.0)
	_expect(
		campaign.transition_to_rogue_exploration(wave_five)
		and campaign.wave_state == CombatFlowState.State.ROGUE_EXPLORATION
		and campaign.next_flow_step_after_rest == wave_five
		and campaign.countdown_seconds == 0
		and game.state_timer.is_stopped()
		and game.enemy_spawn_timer.is_stopped(),
		"Rogue typed transition 必须原子提交 next/state/countdown 并停止流程 timer。"
	)
	game.state_timer.start(1.0)
	game.enemy_spawn_timer.start(1.0)
	_expect(
		campaign.apply_remote_wave_progress(12, 12, 0, 12, 12),
		"Boss 前置夹具必须先建立末波已完成的远端进度 epoch。"
	)
	_expect(
		not campaign.apply_remote_wave_progress(12, 0, 0, 0, 1),
		"Boss keyframe 与末波复用 wave number 时不得倒退覆盖末波 epoch。"
	)
	_expect(
		campaign.transition_to_boss_intro(typed_boss_step)
		and campaign.wave_state == CombatFlowState.State.BOSS_INTRO
		and campaign.current_flow_step == boss_step
		and campaign.next_flow_step_after_rest == null
		and campaign.current_wave_total == 1
		and campaign.current_wave_spawned == 1
		and campaign.current_wave_resolved == 0
		and campaign.countdown_seconds == 0
		and game.state_timer.is_stopped()
		and game.enemy_spawn_timer.is_stopped(),
		(
			"Boss intro typed transition 必须提交 active step、重置 Boss 进度，"
			+ "并清空 rest/countdown。"
		)
	)
	_expect(
		not campaign.apply_remote_wave_progress(12, 0, 0, 0, 1)
		and not campaign.apply_remote_wave_progress(12, 12, 0, 12, 12)
		and campaign.current_wave_total == 1
		and campaign.current_wave_spawned == 1
		and campaign.current_wave_resolved == 0
		and campaign.get_replicated_wave_progress_snapshot().is_empty(),
		(
			"Boss flow 必须隔离通用 wave_progress：Boss 包与迟到末波包"
			+ "都不得污染 Boss 自己的进度状态。"
		)
	)
	_expect(
		campaign.transition_to_boss_active(typed_boss_step)
		and campaign.wave_state == CombatFlowState.State.BOSS_ACTIVE
		and campaign.current_flow_step == boss_step,
		"Boss active typed transition 必须保持同一个 Boss active step。"
	)
	campaign.start_client_flow_countdown(
		CombatFlowState.State.INTERMISSION,
		&"boss_01_linglan",
		60
	)
	campaign.update_client_flow_countdown()
	campaign.update_client_flow_countdown()
	_expect(
		game.wave_hud.day_label.text == "第 4 日"
		and game.wave_hud.phase_label.text == "白昼"
		and game.wave_hud.wave_title_label.text == "首领战准备"
		and not game.wave_hud.global_wave_notice.visible,
		"客户端连续倒计时必须保持第4日白昼首领准备语义，不能回写第12波。"
	)
	game.state_timer.stop()
	campaign.resume_flow_after_fate_interlude(&"boss_01_linglan")
	_expect(
		campaign.wave_state == CombatFlowState.State.INTERMISSION
		and campaign.current_flow_step == boss_step
		and campaign.next_flow_step_after_rest == boss_step
		and campaign.countdown_seconds == 60
		and not game.state_timer.is_stopped()
		and game.wave_hud.wave_title_label.text == "首领战准备",
		(
			"第三次 Fate 完成后必须进入 60 秒第4日首领准备，"
			+ "不能回落到普通波间休整。"
		)
	)
	game.state_timer.stop()

	var entered_results: Array[CombatFlowState.State] = []
	campaign.result_entered.connect(
		func(state: CombatFlowState.State) -> void: entered_results.append(state)
	)
	var terminal_wave := WaveConfig.new()
	terminal_wave.step_id = &"campaign_smoke_terminal"
	campaign.replace_flow_state_for_fixture(
		CombatFlowState.State.WAVE_ACTIVE,
		terminal_wave
	)
	campaign.terminal_wave_enters_fate_interlude = false
	campaign.complete_current_step()
	campaign.enter_victory()
	_expect(
		campaign.wave_state == CombatFlowState.State.VICTORY,
		"无后继流程节点必须由 Campaign 进入胜利。"
	)
	_expect(
		entered_results == [CombatFlowState.State.VICTORY],
		"Campaign 胜利入口必须幂等，结果信号只能发出一次。"
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


func _test_flow_state_write_ownership() -> void:
	var direct_write_pattern := RegEx.new()
	var compiled := direct_write_pattern.compile(
		"(?:campaign_coordinator|_campaign|_campaign_coordinator)"
		+ "\\.(?:wave_state|current_flow_step|next_flow_step_after_rest|countdown_seconds)"
		+ "\\s*=(?!=)"
	)
	_expect(compiled == OK, "Campaign 外部写入静态规则无法编译。")
	if compiled != OK:
		return
	for source_path in FLOW_STATE_CLIENT_SOURCE_PATHS:
		var source := _read_text(source_path)
		_expect(
			direct_write_pattern.search(source) == null,
			"Campaign flow 状态仍被外部直接写入：%s" % source_path
		)
	_expect(
		_read_text(FLOW_STATE_CLIENT_SOURCE_PATHS[0]).contains(
			"campaign_coordinator.transition_to_fate_interlude("
		)
		and _read_text(FLOW_STATE_CLIENT_SOURCE_PATHS[1]).contains(
			"_campaign.transition_to_rogue_exploration("
		)
		and _read_text(FLOW_STATE_CLIENT_SOURCE_PATHS[2]).contains(
			"campaign_coordinator.transition_to_boss_intro("
		)
		and _read_text(FLOW_STATE_CLIENT_SOURCE_PATHS[2]).contains(
			"campaign_coordinator.transition_to_boss_active("
		),
		"Fate/Rogue/Boss 必须通过 Campaign typed transition API 写流程状态。"
	)


func _read_text(path: String) -> String:
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		failures.append("无法读取验证源码：%s" % path)
		return ""
	return file.get_as_text()


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
