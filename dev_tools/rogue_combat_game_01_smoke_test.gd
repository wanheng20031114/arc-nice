extends SceneTree

const ROGUE_COMBAT_SCENE_01 := preload(
	"res://scene/rogue_combat/rogue_combat_game_01.tscn"
)
const COMBAT_ROBOT_CONFIG := preload(
	"res://resources/config/enemies/combat_robot.tres"
)
const ROGUE_COMBAT_MUSIC := preload(
	"res://resources/audio/1-28 Journey of the Prairie King (The Outlaw).mp3"
)
const ROGUE_COMBAT_SCRIPT_PATH := "res://scene/rogue_combat/rogue_combat_game.gd"
const ROGUE_COMBAT_SCENE_PATH := "res://scene/rogue_combat/rogue_combat_game_01.tscn"
const EXPECTED_STANDARD_NIGHT_COLOR := Color(
	87.0 / 255.0,
	123.0 / 255.0,
	158.0 / 255.0,
	1.0
)

const EXPECTED_SPAWN_POSITIONS: Dictionary[StringName, Vector2] = {
	&"Spawn1": Vector2(255.0, 32.0),
	&"Spawn2": Vector2(255.0, 129.0),
	&"Spawn3": Vector2(255.0, 223.0),
}
const EXPECTED_PLAYER_SPAWN_POSITION := Vector2(79.0, 128.0)

var failures: Array[String] = []
var game: RogueCombatGame = null
var wave: WaveConfig = null
var outcome_events: Array[Dictionary] = []
var flow_events: Array[Dictionary] = []


func _initialize() -> void:
	call_deferred(&"_run")


func _run() -> void:
	wave = _create_test_wave()
	game = ROGUE_COMBAT_SCENE_01.instantiate() as RogueCombatGame
	_expect(game != null, "Rouge 作战场景 1 必须能实例化为 RogueCombatGame。")
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

	_test_independent_scene_contract()
	_test_fixed_underground_night_contract()
	_test_deadline_start_policies()
	_test_authoritative_deadline_and_outcomes()
	_test_client_active_flow_updates()
	_test_remote_timeout_reason_contract()
	_test_permanent_death_presentation()

	await _cleanup()
	_finish()


func _test_independent_scene_contract() -> void:
	var scene_state := ROGUE_COMBAT_SCENE_01.get_state()
	_expect(
		scene_state != null and scene_state.get_base_scene_state() == null,
		"Rouge 作战必须是可独立编辑的场景，不能继续继承 game.tscn。"
	)
	_expect(game is Game, "Rouge 作战脚本必须继续复用普通模式 Game 行为。")
	var script_source := FileAccess.get_file_as_string(
		ROGUE_COMBAT_SCRIPT_PATH
	)
	var scene_source := FileAccess.get_file_as_string(
		ROGUE_COMBAT_SCENE_PATH
	)
	_expect(
		not script_source.is_empty()
		and script_source.contains(
			"const UNDERGROUND_NIGHT_COLOR := "
			+ "DayNightController.REFERENCE_NIGHT_COLOR"
		),
		"Rouge 黑夜常量源码必须直接引用塔防标准夜色，不能复制色值。"
	)
	_expect(
		not scene_source.is_empty()
		and not scene_source.contains("night_color ="),
		"场景 01 不得重新声明 night_color 覆盖，必须继承控制器标准夜色。"
	)
	_expect(
		game.get_node_or_null("GroundTileMapLayer") is TileMapLayer
		and game.get_node_or_null("OverlayTileMapLayer") is TileMapLayer
		and game.get_node_or_null("PlayerSpawn") is Marker2D,
		"独立场景必须保留地面、覆盖层与玩家出生点。"
	)
	var ground := game.get_node_or_null("GroundTileMapLayer") as TileMapLayer
	var overlay := game.get_node_or_null("OverlayTileMapLayer") as TileMapLayer
	var player_spawn := game.get_node_or_null("PlayerSpawn") as Marker2D
	_expect(
		ground != null
		and not ground.get_used_cells().is_empty()
		and overlay != null
		and overlay.get_used_cells().size() == 12,
		"独立场景必须保留已绘制的地图与三扇 2×2 红门覆盖图块。"
	)
	_expect(
		player_spawn != null
		and player_spawn.position.is_equal_approx(
			EXPECTED_PLAYER_SPAWN_POSITION
		),
		"Rouge 作战场景必须保留调整后的队伍出生锚点。"
	)

	var spawn_root := game.get_node_or_null("EnemySpawnPoints") as Node2D
	_expect(spawn_root != null, "独立场景必须保留 EnemySpawnPoints。")
	if spawn_root != null:
		_expect(
			spawn_root.get_child_count() == EXPECTED_SPAWN_POSITIONS.size(),
			"Rouge 作战场景必须且只能包含三个红门出生点。"
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
				"红门出生点 %s 必须使用场景 01 的专属位置。" % String(spawn_name)
			)
			if marker != null and player_spawn != null:
				var path: PackedVector2Array = game.grid_pathfinder.call(
					"get_global_path",
					marker.global_position,
					player_spawn.global_position
				)
				_expect(
					not path.is_empty()
					and path[-1].is_equal_approx(player_spawn.global_position),
					"红门出生点 %s 必须能通过当前瓦片地形到达玩家区域。"
					% String(spawn_name)
				)

	if player_spawn != null:
		var authored_team_positions: Dictionary[Vector2, bool] = {}
		for player_index in 4:
			var spawn_offset: Vector2 = game.call(
				"_get_multiplayer_spawn_offset",
				player_index
			)
			var team_position: Vector2 = player_spawn.position + spawn_offset
			authored_team_positions[team_position] = true
		_expect(
			authored_team_positions.size() == 4,
			"四人队伍必须从新 PlayerSpawn 锚点得到四个互不重叠的位置。"
		)

	_expect(
		not game.standard_merchants_enabled
		and game.merchant == null
		and game.luoxi_merchant == null
		and game.get_node_or_null("ZhuangfangyiMerchant") == null
		and game.get_node_or_null("LuoxiMerchant") == null
		and game.get_node_or_null("WorldBounds") == null,
		"场景 01 必须在静态结构中排除标准商人、默认拾取物与旧 WorldBounds。"
	)
	var scene_contract_errors := game.validate_encounter_scene_contract(
		RogueCombatEncounterConfig.REQUIRED_SCENE_SPAWN_POINT_MASK
	)
	_expect(
		scene_contract_errors.is_empty(),
		"场景 01 必须满足三门专属结构契约：%s" % [scene_contract_errors]
	)

	_expect(
		is_equal_approx(game.pre_wave_duration, 3.0)
		and is_equal_approx(game.combat_time_limit_seconds, 90.0)
		and not game.auto_start_waves,
		"Rouge 作战场景必须静态配置 3 秒准备、90 秒上限，并等待路由显式启动。"
	)
	_expect(
		game.get_node_or_null("RogueCombatHUD") is RogueCombatHUD
		and game.get_node_or_null("WaveHUD") == null
		and game.wave_hud == null
		and game.get_node_or_null("CombatDeadlineTimer") is Timer
		and game.get_node_or_null("TowerDefenseStatusHUD") is TowerDefenseStatusHUD,
		"场景必须只保留专用作战 HUD，并静态提供权威计时 Timer 与死亡 HUD。"
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


func _test_fixed_underground_night_contract() -> void:
	var controller := game.day_night_controller
	var reference_color := DayNightController.REFERENCE_NIGHT_COLOR
	var underground_color := RogueCombatGame.UNDERGROUND_NIGHT_COLOR
	_expect(
		game.world_lighting_policy
		== GameRuntimeBase.WorldLightingPolicy.FIXED_NIGHT,
		"场景 01 必须使用 FIXED_NIGHT 世界光照策略。"
	)
	_expect(
		controller != null
		and reference_color == EXPECTED_STANDARD_NIGHT_COLOR
		and underground_color == EXPECTED_STANDARD_NIGHT_COLOR
		and underground_color == reference_color
		and controller.night_color == EXPECTED_STANDARD_NIGHT_COLOR
		and controller.color == EXPECTED_STANDARD_NIGHT_COLOR,
		"塔防、Rouge 常量与场景最终夜色必须严格等于 #577B9E。"
	)
	_expect_fixed_underground_night("场景初始化")

	for spawn_name in EXPECTED_SPAWN_POSITIONS:
		var gate_light := game.get_node_or_null(
			"EnemySpawnPoints/%s/NightLight" % String(spawn_name)
		) as NightPointLight2D
		_expect(
			gate_light != null
			and gate_light.enabled
			and is_equal_approx(gate_light.night_energy, 0.3)
			and is_equal_approx(gate_light.energy, 0.3),
			"固定黑夜下红门 %s 的 night_energy 与实时能量必须保持 0.3。"
			% String(spawn_name)
		)

	var flash_pool := game.get_node_or_null(
		"NightVfxFlashPool"
	) as NightVfxFlashPool
	_expect(
		_flash_pool_matches_authored_contract(flash_pool),
		"场景 01 必须复用容量为 8 且包络参数不变的夜间战斗闪光池。"
	)

	game.transition_world_to_day(5.0)
	_expect_fixed_underground_night("显式白昼请求")
	game.transition_world_to_night(5.0)
	_expect_fixed_underground_night("显式黑夜请求")


func _test_deadline_start_policies() -> void:
	game.deadline_start = RogueCombatGame.DeadlineStart.PREPARATION_START
	game.call("_enter_pre_flow_step", wave)
	_expect_fixed_underground_night("PRE_WAVE（准备期计时）")
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
		and game.rogue_combat_hud.enemy_value_label.text == "0 / 10",
		"准备阶段 HUD 必须显示事件倒计时与本波 0/10 已消灭进度。"
	)
	game.state_timer.stop()
	game.call("_stop_combat_deadline")

	game.deadline_start = RogueCombatGame.DeadlineStart.WAVE_START
	game.call("_enter_pre_flow_step", wave)
	_expect_fixed_underground_night("PRE_WAVE（开战时计时）")
	_expect(
		not bool(game.get("_combat_deadline_started"))
		and game.combat_deadline_timer.is_stopped()
		and game.combat_seconds_remaining == 90,
		"选择 WAVE_START 时，准备阶段只能重置 90 秒状态，不能提前启动。"
	)
	_expect(
		not game.music_player.playing and game.music_player.stream == null,
		"三秒准备倒计时期间不得提前绑定或播放作战音乐。"
	)
	game.state_timer.stop()
	game.navigation_prewarmed = true
	game.call("_begin_wave_config", wave)
	game.enemy_spawn_timer.stop()
	_expect_fixed_underground_night("WAVE_ACTIVE")
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
		and game.rogue_combat_hud.enemy_value_label.text == "0 / 10",
		"正式作战 HUD 必须从 01:30 和 0/10 已消灭进度开始。"
	)
	_expect(
		game.music_player.playing
		and game.music_player.stream == ROGUE_COMBAT_MUSIC
		and game.music_player.bus == &"Music"
		and is_equal_approx(
			game.music_player.volume_db,
			Game.MUSIC_FADE_IN_START_VOLUME_DB
		)
		and game.music_fade_tween != null
		and is_equal_approx(Game.DEFAULT_MUSIC_VOLUME_DB, -6.0)
		and is_equal_approx(Game.MUSIC_FADE_IN_SECONDS, 3.0)
		and (ROGUE_COMBAT_MUSIC as AudioStreamMP3).loop,
		"WAVE_ACTIVE 必须在 Music 总线以 -6 dB 目标和三秒淡入启动循环 1-28。"
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
	_expect_fixed_underground_night("DEFEAT")
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
	_expect_fixed_underground_night("VICTORY")
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
	game.current_wave_total = 0
	game.wave_start_audio.stop()
	game.apply_remote_flow_state(
		wave.step_id,
		GameRuntimeBase.WaveState.WAVE_ACTIVE,
		73
	)
	_expect_fixed_underground_night("客户端 WAVE_ACTIVE 首包")
	_expect(
		game.wave_state == GameRuntimeBase.WaveState.WAVE_ACTIVE
		and game.combat_seconds_remaining == 73
		and game.current_wave_total == 10
		and game.rogue_combat_hud.time_value_label.text == "01:13",
		"Client 首次进入 WAVE_ACTIVE 时必须建立作战状态、敌人总数与剩余秒。"
	)
	game.apply_remote_enemy_count(7)
	_expect(
		game.wave_hud == null
		and game.current_wave_defeated == 3
		and game.rogue_combat_hud.enemy_value_label.text == "3 / 10",
		"Client 敌人数同步必须只更新专用作战 HUD，不能依赖已删除的通用 HUD。"
	)

	game.wave_start_audio.stop()
	game.apply_remote_flow_state(
		wave.step_id,
		GameRuntimeBase.WaveState.WAVE_ACTIVE,
		42
	)
	_expect_fixed_underground_night("客户端 WAVE_ACTIVE 更新")
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
	_expect_fixed_underground_night("客户端 DEFEAT")
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
	result.spawn_point_mask = (
		RogueCombatEncounterConfig.REQUIRED_SCENE_SPAWN_POINT_MASK
	)
	result.spawn_interval = 60.0
	result.spawn_count_per_tick = 1
	result.max_alive_enemies = 1
	result.music = ROGUE_COMBAT_MUSIC
	return result


func _create_test_campaign(test_wave: WaveConfig) -> WaveCampaignConfig:
	var graph := FlowGraphConfig.new()
	graph.graph_name = "Rouge Combat Smoke Test"
	graph.steps = [test_wave]
	graph.start_step = test_wave

	var campaign := WaveCampaignConfig.new()
	campaign.campaign_id = &"rogue_combat_game_01_smoke_test"
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


func _expect_fixed_underground_night(context: String) -> void:
	var controller := game.day_night_controller
	_expect(
		controller != null
		and DayNightController.REFERENCE_NIGHT_COLOR
		== EXPECTED_STANDARD_NIGHT_COLOR
		and RogueCombatGame.UNDERGROUND_NIGHT_COLOR
		== EXPECTED_STANDARD_NIGHT_COLOR
		and controller.night_color == EXPECTED_STANDARD_NIGHT_COLOR
		and controller.color == EXPECTED_STANDARD_NIGHT_COLOR
		and is_equal_approx(controller.night_factor, 1.0)
		and controller.is_night()
		and not controller.is_transitioning()
		and controller.get("_transition_tween") == null,
		"%s 后必须保持地下固定黑夜，且不能遗留昼夜 Tween。" % context
	)


func _flash_pool_matches_authored_contract(
	pool: NightVfxFlashPool
) -> bool:
	if pool == null or pool.get_capacity() != 8 or pool.get_child_count() != 8:
		return false
	for child in pool.get_children():
		var flash := child as NightVfxFlash2D
		if (
			flash == null
			or flash.auto_play
			or flash.shadow_enabled
			or flash.is_flash_active()
			or flash.is_processing()
			or not is_equal_approx(flash.texture_scale, 0.4)
			or not is_equal_approx(flash.attack_seconds, 0.04)
			or not is_equal_approx(flash.hold_seconds, 0.06)
			or not is_equal_approx(flash.decay_seconds, 0.30)
			or not is_equal_approx(flash.initial_strength, 0.58)
			or not is_equal_approx(flash.hold_end_strength, 0.78)
			or not is_equal_approx(flash.decay_exponent, 1.8)
			or not is_equal_approx(flash.start_scale_multiplier, 0.74)
			or not is_equal_approx(flash.end_scale_multiplier, 0.84)
		):
			return false
	return true


func _expect(condition: bool, message: String) -> void:
	if condition:
		return
	failures.append(message)
	push_error(message)


func _finish() -> void:
	if failures.is_empty():
		print("ROGUE_COMBAT_GAME_01_SMOKE_TEST_OK")
		quit(0)
		return
	print("ROGUE_COMBAT_GAME_01_SMOKE_TEST_FAILED count=%d" % failures.size())
	for failure in failures:
		print(" - %s" % failure)
	quit(1)
