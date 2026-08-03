extends SceneTree

const ROGUE_COMBAT_SCENE := preload(
	"res://scene/rogue_combat/rogue_combat_game.tscn"
)
const COMBAT_ROBOT_CONFIG := preload(
	"res://resources/config/enemies/combat_robot.tres"
)

const EXPECTED_SPAWN_POSITIONS: Dictionary[StringName, Vector2] = {
	&"Spawn1": Vector2(112.0, -18.0),
	&"Spawn2": Vector2(306.0, 144.0),
	&"Spawn3": Vector2(306.0, 224.0),
	&"Spawn4": Vector2(128.0, 276.0),
	&"Spawn5": Vector2(-50.0, 144.0),
}

var failures: Array[String] = []
var game: RogueCombatGame = null
var wave: WaveConfig = null
var outcome_events: Array[Dictionary] = []
var flow_events: Array[Dictionary] = []


func _initialize() -> void:
	call_deferred(&"_run")


func _run() -> void:
	wave = _create_test_wave()
	game = ROGUE_COMBAT_SCENE.instantiate() as RogueCombatGame
	_expect(game != null, "Rouge 作战场景必须能实例化为 RogueCombatGame。")
	if game == null:
		_finish()
		return

	var campaign := _create_test_campaign(wave)
	game.singleplayer_campaign = campaign
	game.multiplayer_campaign = campaign
	game.auto_start_waves = false
	(game.get_node("MusicPlayer") as AudioStreamPlayer).autoplay = false
	root.add_child(game)
	await process_frame

	game.combat_outcome_started.connect(
		func(victory: bool, failure_reason: String) -> void:
			outcome_events.append({
				"victory": victory,
				"failure_reason": failure_reason,
			})
	)
	game.multiplayer_flow_state_changed.connect(
		func(step_id: StringName, state: int, seconds: int) -> void:
			flow_events.append({
				"step_id": step_id,
				"state": state,
				"seconds": seconds,
			})
	)

	_test_inherited_scene_contract()
	_test_deadline_start_policies()
	_test_authoritative_deadline_and_outcomes()
	_test_client_active_flow_updates()
	_test_remote_timeout_reason_contract()
	_test_permanent_death_presentation()

	await _cleanup()
	_finish()


func _test_inherited_scene_contract() -> void:
	_expect(game is Game, "Rouge 作战运行时必须继续继承普通模式 Game。")
	_expect(
		game.get_node_or_null("GroundTileMapLayer") is TileMapLayer
		and game.get_node_or_null("OverlayTileMapLayer") is TileMapLayer
		and game.get_node_or_null("PlayerSpawn") is Marker2D,
		"继承场景必须保留普通模式的地面、覆盖层与玩家出生点。"
	)
	var ground := game.get_node_or_null("GroundTileMapLayer") as TileMapLayer
	var overlay := game.get_node_or_null("OverlayTileMapLayer") as TileMapLayer
	_expect(
		ground != null
		and not ground.get_used_cells().is_empty()
		and overlay != null
		and overlay.get_used_cells().size() == 10,
		"继承场景必须保留普通模式已绘制的地图与五扇红门覆盖图块。"
	)

	var spawn_root := game.get_node_or_null("EnemySpawnPoints") as Node2D
	_expect(spawn_root != null, "继承场景必须保留 EnemySpawnPoints。")
	if spawn_root != null:
		_expect(
			spawn_root.get_child_count() == EXPECTED_SPAWN_POSITIONS.size(),
			"Rouge 作战场景必须原样保留五个红门出生点。"
		)
		for spawn_name in EXPECTED_SPAWN_POSITIONS:
			var marker := spawn_root.get_node_or_null(
				NodePath(String(spawn_name))
			) as Marker2D
			_expect(
				marker != null
				and marker.position.is_equal_approx(
					EXPECTED_SPAWN_POSITIONS[spawn_name]
				),
				"红门出生点 %s 必须保留普通模式位置。" % String(spawn_name)
			)

	_expect(
		is_equal_approx(game.pre_wave_duration, 3.0)
		and is_equal_approx(game.combat_time_limit_seconds, 90.0)
		and not game.auto_start_waves,
		"Rouge 作战场景必须静态配置 3 秒准备、90 秒上限，并等待路由显式启动。"
	)
	_expect(
		game.get_node_or_null("RogueCombatHUD") is RogueCombatHUD
		and game.get_node_or_null("CombatDeadlineTimer") is Timer
		and game.get_node_or_null("TowerDefenseStatusHUD") is TowerDefenseStatusHUD,
		"作战 HUD、权威计时 Timer 与死亡 HUD 必须作为静态场景节点存在。"
	)
	_expect(
		is_equal_approx(game.combat_deadline_timer.wait_time, 1.0)
		and not game.combat_deadline_timer.one_shot,
		"CombatDeadlineTimer 必须按每秒重复触发。"
	)
	_expect(
		not game.allows_player_respawn(0)
		and not game.allows_player_respawn(2)
		and not game.allows_enemy_pickup_drops(),
		"Rouge 作战必须禁止复活，并默认关闭敌人的随机拾取物掉落。"
	)
	_expect(
		wave.get_total_enemy_count() == 10
		and wave.enemy_entries.size() == 1
		and wave.enemy_entries[0].enemy_config == COMBAT_ROBOT_CONFIG,
		"测试 Campaign 必须以一波 10 个基础作战机器人驱动契约。"
	)


func _test_deadline_start_policies() -> void:
	game.deadline_start = RogueCombatGame.DeadlineStart.PREPARATION_START
	game.call("_enter_pre_flow_step", wave)
	_expect(
		game.wave_state == GameRuntimeBase.WaveState.PRE_WAVE
		and game.countdown_seconds == 3,
		"PREPARATION_START 必须先进入三秒 PRE_WAVE。"
	)
	_expect(
		bool(game.get("_combat_deadline_started"))
		and not game.combat_deadline_timer.is_stopped()
		and game.combat_seconds_remaining == 90,
		"选择 PREPARATION_START 时，90 秒权威计时必须在准备阶段立即启动。"
	)
	_expect(
		game.rogue_combat_hud.visible
		and game.rogue_combat_hud.preparation_seconds_label.text == "3"
		and game.rogue_combat_hud.enemy_value_label.text == "10 / 10",
		"准备阶段 HUD 必须显示事件倒计时与本波十名敌人。"
	)
	game.state_timer.stop()
	game.call("_stop_combat_deadline")

	game.deadline_start = RogueCombatGame.DeadlineStart.WAVE_START
	game.call("_enter_pre_flow_step", wave)
	_expect(
		not bool(game.get("_combat_deadline_started"))
		and game.combat_deadline_timer.is_stopped()
		and game.combat_seconds_remaining == 90,
		"选择 WAVE_START 时，准备阶段只能重置 90 秒状态，不能提前启动。"
	)
	game.state_timer.stop()
	game.navigation_prewarmed = true
	game.call("_begin_wave_config", wave)
	game.enemy_spawn_timer.stop()
	_expect(
		game.wave_state == GameRuntimeBase.WaveState.WAVE_ACTIVE
		and game.current_wave_total == 10,
		"正式开战必须进入 WAVE_ACTIVE，并保留十名敌人的权威总数。"
	)
	_expect(
		bool(game.get("_combat_deadline_started"))
		and not game.combat_deadline_timer.is_stopped()
		and game.combat_seconds_remaining == 90,
		"选择 WAVE_START 时，90 秒权威计时必须随正式波次启动。"
	)
	_expect(
		game.rogue_combat_hud.time_value_label.text == "01:30"
		and game.rogue_combat_hud.enemy_value_label.text == "10 / 10",
		"正式作战 HUD 必须从 01:30 和 10/10 开始。"
	)
	game.call("_stop_combat_deadline")


func _test_authoritative_deadline_and_outcomes() -> void:
	game.runtime_mode = GameRuntimeBase.RuntimeMode.HOST_AUTHORITY
	game.wave_state = GameRuntimeBase.WaveState.WAVE_ACTIVE
	game.combat_seconds_remaining = 90
	game.combat_deadline_timer.stop()
	game.set("_combat_deadline_started", true)
	flow_events.clear()
	game.call("_on_combat_deadline_timer_timeout")
	_expect(
		game.combat_seconds_remaining == 89
		and game.rogue_combat_hud.time_value_label.text == "01:29",
		"Host 权威计时每次触发必须只递减一秒并同步本地 HUD。"
	)
	_expect(
		flow_events.size() == 1
		and flow_events[0].step_id == wave.step_id
		and int(flow_events[0].state) == GameRuntimeBase.WaveState.WAVE_ACTIVE
		and int(flow_events[0].seconds) == 89,
		"Host 的每秒作战状态必须广播当前 step、WAVE_ACTIVE 与剩余秒数。"
	)
	var host_snapshot := game.get_flow_state_snapshot()
	_expect(
		int(host_snapshot.get("countdown_seconds", -1)) == 89,
		"WAVE_ACTIVE 快照必须携带权威作战剩余秒，而不是准备倒计时。"
	)
	game.call("_stop_combat_deadline")

	game.runtime_mode = GameRuntimeBase.RuntimeMode.SINGLEPLAYER
	game.call("_reset_combat_outcome")
	game.call("_reset_combat_deadline")
	game.wave_state = GameRuntimeBase.WaveState.WAVE_ACTIVE
	game.call("_start_combat_deadline")
	game.combat_seconds_remaining = 1
	var outcome_count_before_timeout := outcome_events.size()
	game.call("_on_combat_deadline_timer_timeout")
	game.call("_on_combat_deadline_timer_timeout")
	_expect(
		game.wave_state == GameRuntimeBase.WaveState.DEFEAT
		and game.combat_deadline_timer.is_stopped()
		and not bool(game.get("_combat_deadline_started")),
		"90 秒耗尽必须进入 DEFEAT 并停止截止计时。"
	)
	_expect(
		outcome_events.size() == outcome_count_before_timeout + 1
		and not bool(outcome_events[-1].victory)
		and String(outcome_events[-1].failure_reason)
		== RogueCombatGame.TIMEOUT_FAILURE_REASON,
		"超时必须仅发出一次失败结果，并使用明确的超时原因。"
	)

	game.call("_reset_combat_outcome")
	game.call("_reset_combat_deadline")
	game.wave_state = GameRuntimeBase.WaveState.WAVE_ACTIVE
	game.call("_start_combat_deadline")
	var outcome_count_before_victory := outcome_events.size()
	game.call("_enter_victory")
	game.call("_enter_victory")
	_expect(
		game.wave_state == GameRuntimeBase.WaveState.VICTORY
		and game.combat_deadline_timer.is_stopped()
		and not bool(game.get("_combat_deadline_started")),
		"胜利必须停止截止计时，并保持幂等的 VICTORY 状态。"
	)
	_expect(
		outcome_events.size() == outcome_count_before_victory + 1
		and bool(outcome_events[-1].victory)
		and String(outcome_events[-1].failure_reason).is_empty(),
		"胜利必须仅发出一次成功结果。"
	)


func _test_client_active_flow_updates() -> void:
	game.runtime_mode = GameRuntimeBase.RuntimeMode.CLIENT_VIEW
	game.wave_state = GameRuntimeBase.WaveState.PRE_WAVE
	game.current_flow_step = wave
	game.current_wave_total = 10
	game.wave_start_audio.stop()
	game.apply_remote_flow_state(
		wave.step_id,
		GameRuntimeBase.WaveState.WAVE_ACTIVE,
		73
	)
	_expect(
		game.wave_state == GameRuntimeBase.WaveState.WAVE_ACTIVE
		and game.combat_seconds_remaining == 73
		and game.rogue_combat_hud.time_value_label.text == "01:13",
		"Client 首次进入 WAVE_ACTIVE 时必须建立作战状态与剩余秒。"
	)

	game.wave_start_audio.stop()
	game.apply_remote_flow_state(
		wave.step_id,
		GameRuntimeBase.WaveState.WAVE_ACTIVE,
		42
	)
	_expect(
		game.combat_seconds_remaining == 42
		and game.rogue_combat_hud.time_value_label.text == "00:42",
		"Client 重复收到同一 WAVE_ACTIVE 时必须原位同步剩余秒。"
	)
	_expect(
		not game.wave_start_audio.playing,
		"Client 的 WAVE_ACTIVE 每秒更新不得重播波次开始音效。"
	)
	var client_snapshot := game.get_flow_state_snapshot()
	_expect(
		int(client_snapshot.get("countdown_seconds", -1)) == 42,
		"Client WAVE_ACTIVE 快照必须反映最近一次权威剩余秒。"
	)


func _test_remote_timeout_reason_contract() -> void:
	game.runtime_mode = GameRuntimeBase.RuntimeMode.CLIENT_VIEW
	game.call("_reset_combat_outcome")
	game.wave_state = GameRuntimeBase.WaveState.WAVE_ACTIVE
	var outcome_count_before := outcome_events.size()
	game.apply_remote_defeat_with_reason(
		RogueCombatGame.TIMEOUT_FAILURE_REASON
	)
	_expect(
		game.wave_state == GameRuntimeBase.WaveState.DEFEAT
		and game.get_multiplayer_defeat_reason()
		== RogueCombatGame.TIMEOUT_FAILURE_REASON,
		"Client 必须保存 Host 发送的权威超时失败原因。"
	)
	_expect(
		outcome_events.size() == outcome_count_before + 1
		and not bool(outcome_events[-1].victory)
		and String(outcome_events[-1].failure_reason)
		== RogueCombatGame.TIMEOUT_FAILURE_REASON,
		"Client 的 combat_outcome_started 必须报告权威超时原因，不能误报全灭。"
	)


func _test_permanent_death_presentation() -> void:
	game.runtime_mode = GameRuntimeBase.RuntimeMode.SINGLEPLAYER
	game.player.is_dead = true
	game.call("_present_permanent_death", 0)
	var status_hud := game.tower_defense_status_hud
	_expect(
		game.player.tower_defense_death_presentation_active,
		"Rouge 永久死亡必须复用塔防玩家死亡遮罩呈现。"
	)
	_expect(
		status_hud.local_permanent_death_active
		and status_hud.local_countdown_label.text
		== TowerDefenseStatusHUD.PERMANENT_DEATH_FULL_TEXT
		and status_hud.local_compact_countdown_label.text
		== TowerDefenseStatusHUD.PERMANENT_DEATH_COMPACT_TEXT,
		"本地永久死亡 UI 必须显示“无法复活/观战中”，不能显示复活秒数。"
	)
	_expect(
		status_hud.death_screen_effect.visible
		and status_hud.local_death_center.visible,
		"永久死亡必须显示全屏死亡遮罩与本地观战卡。"
	)
	_expect(
		not bool(status_hud.get("_dead_player_list_enabled"))
		and status_hud.respawn_entries.is_empty()
		and not status_hud.dead_players_panel.visible
		and status_hud.dead_players_label.text.is_empty(),
		"Rouge 永久死亡不得填充或显示右侧复活列表。"
	)


func _create_test_wave() -> WaveConfig:
	var entry := WaveEnemyEntry.new()
	entry.enemy_config = COMBAT_ROBOT_CONFIG
	entry.count = 10

	var result := WaveConfig.new()
	result.step_id = &"rogue_combat_smoke_wave"
	result.wave_name = "狭路相逢"
	result.enemy_entries = [entry]
	result.spawn_point_mask = WaveConfig.STANDARD_SPAWN_POINT_MASK
	result.spawn_interval = 60.0
	result.spawn_count_per_tick = 1
	result.max_alive_enemies = 1
	return result


func _create_test_campaign(test_wave: WaveConfig) -> WaveCampaignConfig:
	var graph := FlowGraphConfig.new()
	graph.graph_name = "Rouge Combat Smoke Test"
	graph.steps = [test_wave]
	graph.start_step = test_wave

	var campaign := WaveCampaignConfig.new()
	campaign.campaign_id = &"rogue_combat_game_smoke_test"
	campaign.flow_graph = graph
	return campaign


func _cleanup() -> void:
	if game != null and is_instance_valid(game):
		game.combat_deadline_timer.stop()
		game.enemy_spawn_timer.stop()
		game.state_timer.stop()
		game.queue_free()
		await process_frame
	game = null


func _expect(condition: bool, message: String) -> void:
	if condition:
		return
	failures.append(message)
	push_error(message)


func _finish() -> void:
	if failures.is_empty():
		print("ROGUE_COMBAT_GAME_SMOKE_TEST_OK")
		quit(0)
		return
	print("ROGUE_COMBAT_GAME_SMOKE_TEST_FAILED count=%d" % failures.size())
	for failure in failures:
		print(" - %s" % failure)
	quit(1)
