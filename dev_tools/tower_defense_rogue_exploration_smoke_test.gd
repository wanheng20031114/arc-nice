extends SceneTree

const TOWER_SCENE := preload(
	"res://scene/game_modes/tower_defense/tower_defense_game.tscn"
)
const FORMAL_PROGRESSION: TowerDefenseProgressionConfig = preload(
	"res://resources/config/campaigns/tower_defense/formal_progression.tres"
)
const SPATIAL_AUDIO_VOICE_LIMITER := preload(
	"res://scene/combat/audio/spatial_audio_voice_limiter.gd"
)
const LOOPING_AUDIO_STREAM := preload(
	"res://resources/audio/1-27 Journey of the Prairie King (Overworld).mp3"
)
const TRANSIENT_AUDIO_STREAM := preload(
	"res://resources/audio/cowboy_explosion.wav"
)
const AUDIO_FREEZE_TEST_GROUP := &"tower_rogue_audio_freeze_test"
const MAX_COMBAT_FIXTURE_SEED := 2048
const MAX_COMBAT_WAIT_FRAMES := 600

var failures: Array[String] = []
var zero_action_points_case_completed := false
var snapshot_ordering_case_completed := false


func _init() -> void:
	call_deferred(&"_run")


func _run() -> void:
	var run_state := root.get_node("RunState") as RunStateStore
	run_state.begin_new_run(PlayerCharacterRegistry.DEFAULT_CHARACTER_ID, false)
	run_state.set_max_health_penalty_for_peer(0, 17)
	var game := TOWER_SCENE.instantiate() as TowerDefenseGame
	game.auto_start_waves = false
	var fate := game.get_node_or_null("FateCoordinator") as FateCoordinator
	if fate != null:
		fate.elite_enemy_config_loads_requested = true
	root.add_child(game)
	current_scene = game
	await process_frame

	var coordinator := game.get_rogue_exploration_coordinator()
	var route := coordinator.get_route()
	_expect(
		coordinator != null
		and route != null
		and route.get_parent() == coordinator
		and coordinator.get_node_or_null("RogueCombatCoordinator")
			is RogueCombatMultiplayerCoordinator,
		"塔防场景必须静态挂载 RogueRoute 与多人作战协调器。"
	)
	_expect(
		not route.visible
		and route.process_mode == Node.PROCESS_MODE_DISABLED
		and not route.map_camera.enabled
		and _all_route_canvas_layers_hidden(route),
		"非探索期路线世界、相机与全部 CanvasLayer 必须从首帧起隐藏。"
	)

	game.home_defense_coordinator.set_authoritative_base_health(135, 63)
	run_state.set_party_core_health(63, 135)
	game.production_coordinator.set_authoritative_processing_enabled(true)
	game.research_coordinator.set_authoritative_processing_enabled(true)
	game.plant_terrain_decay_timer.start(17.0)
	game.plant_placement_controller.set_placement_input_enabled(true)
	game.plant_placement_controller.set_process_unhandled_input(true)
	game.music_player.stream = AudioStreamGenerator.new()
	game.music_player.stream_paused = false
	game.music_player.play(1.0)
	var tower_music_playback := game.music_player.get_stream_playback()
	var looping_sfx := _add_audio_player_2d(
		game,
		LOOPING_AUDIO_STREAM,
		&"SFX"
	)
	var originally_paused_music := _add_audio_player(
		game,
		AudioStreamGenerator.new(),
		&"Music"
	)
	var replaced_music := _add_audio_player(
		game,
		AudioStreamGenerator.new(),
		&"Music"
	)
	var restarted_music := _add_audio_player(
		game,
		AudioStreamGenerator.new(),
		&"Music"
	)
	var reparented_music := _add_audio_player(
		game,
		AudioStreamGenerator.new(),
		&"Music"
	)
	var freed_music := _add_audio_player(
		game,
		AudioStreamGenerator.new(),
		&"Music"
	)
	var transient_2d := AudioStreamPlayer2D.new()
	transient_2d.stream = TRANSIENT_AUDIO_STREAM
	transient_2d.bus = &"SFX"
	game.add_child(transient_2d)
	var transient_music := _add_audio_player(
		game,
		TRANSIENT_AUDIO_STREAM,
		&"Music"
	)
	var transient_claim_result := SPATIAL_AUDIO_VOICE_LIMITER.claim_voice(
		transient_2d,
		game,
		AUDIO_FREEZE_TEST_GROUP,
		1
	)
	var transient_preemptions := [0]
	transient_2d.set_meta(
		SPATIAL_AUDIO_VOICE_LIMITER.VOICE_PREEMPTED_CALLBACK_META,
		func() -> void: transient_preemptions[0] += 1
	)
	transient_2d.play()
	var transient_3d := AudioStreamPlayer3D.new()
	transient_3d.stream = TRANSIENT_AUDIO_STREAM
	transient_3d.bus = &"SFX"
	game.add_child(transient_3d)
	transient_3d.play()
	var nested_rogue_voice := AudioStreamPlayer2D.new()
	nested_rogue_voice.stream = TRANSIENT_AUDIO_STREAM
	nested_rogue_voice.bus = &"SFX"
	route.add_child(nested_rogue_voice)
	var nested_claim_result := SPATIAL_AUDIO_VOICE_LIMITER.claim_voice(
		nested_rogue_voice,
		route,
		AUDIO_FREEZE_TEST_GROUP,
		1
	)
	nested_rogue_voice.play()
	await process_frame
	originally_paused_music.stream_paused = true
	await process_frame
	var looping_sfx_playback := looping_sfx.get_stream_playback()
	var paused_music_playback := originally_paused_music.get_stream_playback()
	var replaced_music_playback := replaced_music.get_stream_playback()
	var restarted_music_playback := restarted_music.get_stream_playback()
	_expect(
		game.music_player.has_stream_playback()
		and tower_music_playback != null
		and not game.music_player.stream_paused
		and looping_sfx_playback != null
		and paused_music_playback != null
		and replaced_music_playback != null
		and restarted_music_playback != null
		and originally_paused_music.stream_paused
		and transient_claim_result == 0
		and transient_2d.playing
		and transient_music.playing
		and transient_3d.playing
		and nested_claim_result == 0
		and nested_rogue_voice.playing
		and SPATIAL_AUDIO_VOICE_LIMITER.get_active_voice_count(
			game,
			AUDIO_FREEZE_TEST_GROUP
		) == 1
		and SPATIAL_AUDIO_VOICE_LIMITER.get_active_voice_count(
			route,
			AUDIO_FREEZE_TEST_GROUP
		) == 1,
		"音乐冻结回归需要先建立一个有效且未暂停的 Tower playback。"
	)
	game.settings_panel.open()
	game.player_profile_panel.open()
	game.debug_collectible_window.open()
	game.oak_warehouse_panel.show()
	game.oak_warehouse_panel.overlay.show()
	game.production_building_panel.show()
	game.production_building_panel.overlay.show()
	var research_modal_fixture := ResearchCenter.new()
	game.research_center_panel.building = research_modal_fixture
	game.research_center_panel.tracked_player = game.player
	game.research_center_panel.show()
	game.luoxi_merchant.choice_visible = true
	game.luoxi_merchant.choice_overlay.show_choices([])
	game.luoxi_merchant.special_game_overlay.show_game(1)
	game.luoxi_special_game_coordinator.sessions_by_peer[0] = (
		LuoxiSpecialGameSession.new()
	)
	_expect(
		game.settings_panel.is_open()
		and game.player_profile_panel.is_open()
		and game.debug_collectible_window.is_open()
		and game.oak_warehouse_panel.is_open()
		and game.production_building_panel.is_open()
		and game.research_center_panel.is_open()
		and game.luoxi_merchant.choice_overlay.is_open()
		and game.luoxi_merchant.special_game_overlay.is_open(),
		"Rogue 转场测试前必须先打开所有 Tower 高层 modal。"
	)
	var decay_time_before_freeze := game.plant_terrain_decay_timer.time_left
	var tower_music_position_before_freeze := (
		game.music_player.get_playback_position()
	)
	coordinator.call("_freeze_tower_runtime")
	coordinator.call("_freeze_tower_runtime")
	var tower_music_frozen_position := game.music_player.get_playback_position()
	_expect(
		not game.settings_panel.is_open()
		and not game.player_profile_panel.is_open()
		and not game.debug_collectible_window.is_open()
		and not game.oak_warehouse_panel.is_open()
		and not game.production_building_panel.is_open()
		and not game.research_center_panel.is_open()
		and not game.luoxi_merchant.choice_overlay.is_open()
		and not game.luoxi_merchant.special_game_overlay.is_open()
		and game.luoxi_special_game_coordinator.sessions_by_peer.is_empty(),
		"Rogue 冻结捕获基线前必须关闭旧 modal 并取消洛希 session。"
	)
	research_modal_fixture.free()
	_expect(
		game.plant_terrain_decay_timer.is_stopped()
		and not game.production_coordinator.authoritative_processing_enabled
		and not game.research_coordinator.authoritative_processing_enabled
		and not game.plant_placement_controller.placement_input_enabled
		and not game.plant_placement_controller.is_processing_unhandled_input(),
		"冻结边界必须暂停原本运行中的生产、研究、衰减和建造输入。"
	)
	_expect(
		game.music_player.get_stream_playback() == tower_music_playback
		and game.music_player.stream_paused
		and looping_sfx.get_stream_playback() == looping_sfx_playback
		and looping_sfx.stream_paused
		and originally_paused_music.get_stream_playback() == paused_music_playback
		and originally_paused_music.stream_paused
		and not transient_2d.playing
		and int(transient_preemptions[0]) == 1
		and not transient_music.playing
		and not transient_3d.playing
		and nested_rogue_voice.playing
		and not nested_rogue_voice.stream_paused
		and SPATIAL_AUDIO_VOICE_LIMITER.get_active_voice_count(
			game,
			AUDIO_FREEZE_TEST_GROUP
		) == 0
		and SPATIAL_AUDIO_VOICE_LIMITER.get_active_voice_count(
			route,
			AUDIO_FREEZE_TEST_GROUP
		) == 1
		and absf(
			tower_music_frozen_position - tower_music_position_before_freeze
		) < 0.1,
		"冻结必须保留循环 playback 位置、终止 Tower SFX，并隔离嵌套 Rogue 声部。"
	)
	var replacement_stream := AudioStreamGenerator.new()
	replaced_music.stream = replacement_stream
	replaced_music.play()
	var replacement_playback := replaced_music.get_stream_playback()
	replaced_music.stream_paused = true
	restarted_music.stop()
	restarted_music.play()
	var restarted_music_generation := restarted_music.get_stream_playback()
	restarted_music.stream_paused = true
	reparented_music.reparent(route)
	freed_music.free()
	_expect(
		replacement_playback != null
		and replacement_playback != replaced_music_playback
		and restarted_music_generation != null
		and restarted_music_generation != restarted_music_playback
		and reparented_music.stream_paused,
		"冻结期替换 stream、重启 playback 与迁移节点必须产生失效租约。"
	)
	coordinator.call("_restore_tower_runtime")
	_expect(
		not game.plant_terrain_decay_timer.is_stopped()
		and absf(
			game.plant_terrain_decay_timer.time_left - decay_time_before_freeze
		) < 0.25
		and game.production_coordinator.authoritative_processing_enabled
		and game.research_coordinator.authoritative_processing_enabled
		and game.plant_placement_controller.placement_input_enabled
		and game.plant_placement_controller.is_processing_unhandled_input(),
		"恢复边界必须精确续接原本运行中的计时与系统开关。"
	)
	_expect(
		game.music_player.get_stream_playback() == tower_music_playback
		and not game.music_player.stream_paused
		and absf(
			game.music_player.get_playback_position()
			- tower_music_frozen_position
		) < 0.1
		and looping_sfx.get_stream_playback() == looping_sfx_playback
		and not looping_sfx.stream_paused
		and originally_paused_music.stream_paused,
		"恢复必须续接同一循环 playback 的位置，并保留进入前已有暂停。"
	)
	_expect(
		replaced_music.stream == replacement_stream
		and replaced_music.get_stream_playback() == replacement_playback
		and replaced_music.stream_paused
		and restarted_music.get_stream_playback() == restarted_music_generation
		and restarted_music.stream_paused
		and reparented_music.get_parent() == route
		and reparented_music.stream_paused,
		"替换 stream、重启 playback 或迁移节点后，旧暂停租约必须失效。"
	)
	_expect(
		not transient_2d.playing
		and int(transient_preemptions[0]) == 1
		and not transient_music.playing
		and not transient_3d.playing
		and nested_rogue_voice.playing,
		"恢复不得复活 Music/SFX 总线上的瞬态音频，也不得干预嵌套 Rogue 音频。"
	)
	var restored_tower_environment := (
		game.get_node("WorldEnvironment") as WorldEnvironment
	).environment
	coordinator.call("_restore_tower_runtime")
	_expect(
		game.map_camera.enabled
		and (game.get_node("WorldEnvironment") as WorldEnvironment).environment
			== restored_tower_environment
		and game.music_player.get_stream_playback() == tower_music_playback
		and not game.music_player.stream_paused,
		"重复恢复不得再次改写相机、环境或音乐，冻结租约必须严格幂等。"
	)
	SPATIAL_AUDIO_VOICE_LIMITER.release_all_voice_claims(nested_rogue_voice)
	for audio_fixture in [
		looping_sfx,
		originally_paused_music,
		replaced_music,
		restarted_music,
		reparented_music,
		transient_2d,
		transient_music,
		transient_3d,
		nested_rogue_voice,
	]:
		if is_instance_valid(audio_fixture):
			audio_fixture.stop()
			audio_fixture.free()
	game.production_coordinator.set_authoritative_processing_enabled(false)
	game.research_coordinator.set_authoritative_processing_enabled(false)
	game.plant_terrain_decay_timer.stop()
	game.plant_placement_controller.set_placement_input_enabled(false)
	game.plant_placement_controller.set_process_unhandled_input(false)
	coordinator.call("_freeze_tower_runtime")
	coordinator.call("_restore_tower_runtime")
	_expect(
		game.plant_terrain_decay_timer.is_stopped()
		and not game.production_coordinator.authoritative_processing_enabled
		and not game.research_coordinator.authoritative_processing_enabled
		and not game.plant_placement_controller.placement_input_enabled
		and not game.plant_placement_controller.is_processing_unhandled_input(),
		"恢复边界不得把进入前已停止的系统错误启动。"
	)
	game.player.apply_multiplayer_death_state()
	game.player_roster_coordinator.restore_all_players_to_full_health(false)
	game.player.set_multiplayer_health_state(1, false)

	var wave_five := game.campaign_coordinator.get_flow_step_by_id(&"wave_05")
	_expect(
		coordinator.enter_exploration(1, wave_five),
		"第4波后必须能进入首日地下探索。"
	)
	await process_frame
	var first_epoch := int(
		coordinator.export_multiplayer_snapshot_for_peer().get(
			"map_generation_epoch",
			-1
		)
	)
	_expect(
		coordinator.is_exploration_active()
		and route.visible
		and route.map_camera.enabled
		and route.route_hud.visible
		and route.get_action_points() == 5
		and first_epoch == 1
		and not str(
			route.export_layout_snapshot().get("layout_hash", "")
		).is_empty(),
		"首日探索必须以0点创建地图后幂等发放5点，并接管路线相机/HUD。"
	)
	_expect(
		coordinator.enter_exploration(1, wave_five)
		and route.get_action_points() == 5,
		"同一探索日重复进入必须幂等，不能重复发放行动力。"
	)
	var mismatched_repeat_step := (
		game.campaign_coordinator.get_flow_step_by_id(&"wave_09")
	)
	_expect(
		not coordinator.enter_exploration(1, mismatched_repeat_step),
		"active 探索日的幂等重入必须同时匹配续接 step，不能静默换目标。"
	)
	_expect(
		not game.map_camera.enabled,
		"探索期间必须释放塔防相机所有权。"
	)
	_expect(
		game.get_node("WorldEnvironment").environment == null,
		"探索期间必须释放塔防 WorldEnvironment 所有权。"
	)
	_expect(
		not game.production_coordinator.authoritative_processing_enabled
		and not game.research_coordinator.authoritative_processing_enabled,
		"探索期间必须冻结塔防生产和研究。"
	)
	_expect(
		game.plant_terrain_decay_timer.is_stopped(),
		"探索期间必须冻结地形衰减计时器。"
	)
	_expect(
		not game.plant_placement_controller.placement_input_enabled
		and not game.plant_placement_controller.is_processing_unhandled_input(),
		"探索期间必须冻结建造输入。"
	)
	_expect(
		not game.player.is_dead
		and game.player.current_health == game.player.max_health,
		"进入探索时塔防角色必须复活并恢复到当前生命上限。"
	)
	var route_player := route.player
	var penalized_route_max_health := route_player.max_health
	_expect(
		route_player.current_health == penalized_route_max_health
		and route_player.get_run_max_health_penalty() == 17,
		"路线角色必须先应用永久最大生命惩罚，再恢复满血。"
	)
	var combat_fixture := _configure_adjacent_normal_combat_route(route)
	_expect(
		not combat_fixture.is_empty(),
		"嵌入式路线必须能找到出生点相邻的普通作战夹具。"
	)
	var first_layout_hash := str(
		route.export_layout_snapshot().get("layout_hash", "")
	)
	var inventory_revision_before_combat := run_state.inventory_revision
	var route_xirang_before_combat := route_player.current_xirang
	if not combat_fixture.is_empty():
		var runtime_state := route.get("_runtime_state") as RogueRouteRuntimeState
		var singleplayer_combat := (
			coordinator.get_combat_coordinator()
			as RogueCombatSingleplayerCoordinator
		)
		_expect(
			singleplayer_combat != null
			and runtime_state.try_move(
				int(combat_fixture["combat_node_id"]),
				route.generation_config.move_action_cost,
				runtime_state.state_revision
			),
			"塔防静态路线必须复用正式单人作战协调器进入普通作战。"
		)
		var battle: RogueCombatGame = null
		if singleplayer_combat != null:
			battle = await _wait_for_active_battle(singleplayer_combat)
		_expect(battle != null, "嵌入式普通作战必须实例化真实战场。")
		if battle != null:
			_set_route_action_points_for_boundary_test(route, 0)
			await process_frame
			_expect(
				coordinator.is_exploration_active()
				and singleplayer_combat.is_runtime_busy()
				and not coordinator.is_settled_for_auto_return(),
				"行动力归零时，活动作战必须阻止地下探索提前进入命运间奏。"
			)
			battle.call("_enter_victory")
			_expect(
				await _wait_for_combat_result(route),
				"嵌入式普通作战胜利必须进入正式奖励结算。"
			)
			var combat_result := singleplayer_combat.get_last_result()
			var loot := combat_result.get("loot", {}) as Dictionary
			_expect(
				bool(combat_result.get("victory", false))
				and bool(loot.get("granted", false))
				and run_state.inventory_revision
					> inventory_revision_before_combat
				and route_player.current_xirang
					>= route_xirang_before_combat,
				"普通作战胜利奖励必须写入共享经济账本，且息壤不能回退。"
			)
			route.combat_result_overlay.close_button.pressed.emit()
			_expect(
				await _wait_for_combat_settlement(singleplayer_combat),
				"关闭作战结算后必须释放战场并解除路线 busy。"
			)

	var expected_xirang_after_rogue := run_state.get_party_xirang_balance(0)
	_expect(
		expected_xirang_after_rogue == route_player.current_xirang,
		"Rogue 路线实体与跨场景息壤账本必须在退出探索前一致。"
	)
	route_player.apply_multiplayer_death_state()
	_set_route_action_points_for_boundary_test(route, 0)
	var entered_fate := await _wait_for_fate_interlude_entry(game, coordinator)
	_expect(
		entered_fate,
		"行动力归零且所有路线子流程稳定后必须自动进入小葱命运间奏。"
	)
	_expect(
		not coordinator.is_exploration_active()
		and not route.visible
		and _all_route_canvas_layers_hidden(route)
		and game.campaign_coordinator.wave_state
			== CombatFlowState.State.FATE_INTERLUDE
		and game.fate_manager.active
		and game.xiaocong_fate_interlude.is_active
		and run_state.get_party_core_health() == 63
		and run_state.get_party_core_maximum_health() == 135
		and game.home_defense_coordinator.current_base_health == 63
		and game.home_defense_coordinator.maximum_base_health == 135,
		"探索转入命运间奏时必须隐藏路线表现，并原子恢复塔防核心状态。"
	)
	_expect(
		not game.production_coordinator.authoritative_processing_enabled
		and not game.research_coordinator.authoritative_processing_enabled
		and game.plant_terrain_decay_timer.is_stopped(),
		"返回必须精确恢复进入前已停止的生产、研究与衰减状态。"
	)
	_expect(
		run_state.inventory_revision > inventory_revision_before_combat,
		"地下探索转入命运间奏不得回滚已经提交的作战奖励。"
	)
	_expect(
		await _force_finish_fate_and_wait_for_tower(game),
		"命运选择完成后必须返回塔防流程。"
	)
	game.state_timer.stop()
	_expect(
		game.campaign_coordinator.wave_state == CombatFlowState.State.INTERMISSION
		and not game.xiaocong_fate_interlude.is_active
		and not game.production_coordinator.authoritative_processing_enabled
		and not game.research_coordinator.authoritative_processing_enabled
		and game.plant_terrain_decay_timer.is_stopped()
		and game.player.current_xirang == expected_xirang_after_rogue
		and run_state.get_party_xirang_balance(0) == expected_xirang_after_rogue
		and game.player.global_position
			== game.player_roster_coordinator.get_world_spawn_position(0),
		(
			"小葱命运结束后必须返回塔防出生点、保留 Rogue 息壤结算、"
			+ "续接休整，并保持进入 Rogue 前已经停用的生产、研究与衰减状态。"
		)
	)
	_expect(
		coordinator.enter_exploration(1, wave_five),
		"已结算探索日的可靠重发必须作为幂等成功处理。"
	)
	for _duplicate_frame in range(4):
		await process_frame
	_expect(
		not coordinator.is_exploration_active()
		and not coordinator.has_pending_presentation_exit()
		and game.campaign_coordinator.wave_state
			== CombatFlowState.State.INTERMISSION
		and not game.fate_manager.active,
		"已结算探索日不得因重复进入请求而重开 Rogue 或再次进入 Fate。"
	)

	var wave_nine := game.campaign_coordinator.get_flow_step_by_id(&"wave_09")
	_expect(
		coordinator.enter_exploration(2, wave_nine),
		"第二日结束后必须能复用地下探索。"
	)
	await process_frame
	var second_snapshot := coordinator.export_multiplayer_snapshot_for_peer()
	_expect(
		str(route.export_layout_snapshot().get("layout_hash", ""))
			== first_layout_hash
		and int(second_snapshot.get("map_generation_epoch", -1)) == first_epoch
		and route.get_action_points() == 5,
		"命运间奏返回后的第二日必须复用同一地图，并只追加当日5点行动力。"
	)
	_expect(
		not route_player.is_dead
		and route_player.current_health == route_player.max_health
		and route_player.max_health == penalized_route_max_health
		and route_player.get_run_max_health_penalty() == 17,
		"同图跨日重新进入时路线角色也必须保留惩罚后的上限并恢复满血。"
	)
	var repeated_active_snapshot := (
		coordinator.export_multiplayer_snapshot_for_peer(0)
	)
	_expect(
		int(repeated_active_snapshot.get("tower_core_current", -1)) == 63
		and int(repeated_active_snapshot.get("tower_core_maximum", -1)) == 135,
		"active探索快照必须携带进入前Host保存的塔防核心状态。"
	)
	# 模拟晚加入客户端冻结时仍持有默认100/100；同一active快照必须以
	# Host边界覆盖恢复账本，后续退出才不会把真实基地血量回滚为默认值。
	coordinator.set("_saved_tower_core_current", 100)
	coordinator.set("_saved_tower_core_maximum", 100)
	route_player.set_multiplayer_health_state(7, false)
	route.set_authority_enabled(false)
	var invalid_core_snapshot := repeated_active_snapshot.duplicate(true)
	invalid_core_snapshot["tower_core_current"] = 136
	_expect(
		not coordinator.apply_multiplayer_snapshot(invalid_core_snapshot)
		and int(coordinator.get("_saved_tower_core_current")) == 100
		and route_player.current_health == 7,
		"非法塔防核心边界必须在写入任何探索或恢复状态前被原子拒绝。"
	)
	var repeated_snapshot_applied := coordinator.apply_multiplayer_snapshot(
		repeated_active_snapshot
	)
	route.set_authority_enabled(true)
	_expect(
		repeated_snapshot_applied
		and route_player.current_health == 7
		and int(coordinator.get("_saved_tower_core_current")) == 63
		and int(coordinator.get("_saved_tower_core_maximum")) == 135,
		(
			"同日同epoch的重复active快照不得给路线角色回血，并必须修正晚加入"
			+ "客户端的塔防核心恢复边界。"
		)
	)

	route.call("_show_run_defeat")
	_expect(
		coordinator.host_handle_exploration_failure(),
		"嵌入式败局必须由外层权威协调器直接消费。"
	)
	_expect(
		coordinator.has_pending_presentation_exit()
		and bool(game.call(&"_is_tower_runtime_suspended_for_rogue"))
		and route.visible
		and route.process_mode == Node.PROCESS_MODE_DISABLED
		and not game.map_camera.enabled
		and game.get_node("WorldEnvironment").environment == null
		and game.xiaocong_fate_interlude.scene_transition_layer.visible,
		(
			"Rogue 逻辑结束后必须保留不可操作的最后一帧并继续冻结塔防，"
			+ "直到小葱遮罩完全覆盖后再退出路线表现。"
		)
	)
	var pending_boss := game.campaign_coordinator.get_flow_step_by_id(
		&"boss_01_linglan"
	)
	_expect(
		coordinator.enter_exploration(2, wave_nine)
		and not coordinator.enter_exploration(3, pending_boss)
		and coordinator.has_pending_presentation_exit(),
		"pending 退出必须幂等确认同一天重发，并拒绝下一天提前替换当前退出。"
	)
	var failure_entered_fate := await _wait_for_fate_interlude_entry(
		game,
		coordinator
	)
	_expect(
		failure_entered_fate
		and run_state.get_party_core_health() == 63
		and run_state.get_party_core_maximum_health() == 135
		and game.home_defense_coordinator.current_base_health == 63
		and game.home_defense_coordinator.maximum_base_health == 135,
		"探索失败也必须精确恢复塔防核心并进入命运间奏。"
	)
	_expect(
		await _force_finish_fate_and_wait_for_tower(game),
		"探索失败后的命运间奏也必须能正常续接塔防。"
	)
	game.state_timer.stop()

	var boss := pending_boss
	_expect(
		coordinator.enter_exploration(3, boss),
		"第三日结束后必须能生成失败后的新地图。"
	)
	await process_frame
	_expect(
		int(
			coordinator.export_multiplayer_snapshot_for_peer().get(
				"map_generation_epoch",
				-1
			)
		) == first_epoch + 1,
		"上一日探索失败后，下一次探索必须推进地图生成 epoch。"
	)
	_set_route_action_points_for_boundary_test(route, 0)
	coordinator.call("_finish_exploration", false)
	_expect(
		await _wait_for_fate_interlude_entry(game, coordinator),
		"第三次探索结束后也必须先进入小葱命运间奏。"
	)
	_expect(
		await _force_finish_fate_and_wait_for_tower(game),
		"第三次命运间奏完成后必须返回塔防。"
	)
	game.state_timer.stop()
	_expect(
		game.campaign_coordinator.wave_state == CombatFlowState.State.INTERMISSION
		and game.campaign_coordinator.countdown_seconds == 60
		and game.wave_hud.day_label.text == "第 4 日"
		and game.wave_hud.phase_label.text == "白昼"
		and game.wave_hud.wave_title_label.text == "首领战准备"
		and not game.wave_hud.global_wave_notice.visible,
		"第三次命运间奏后必须进入60秒第4日白昼首领准备，不显示普通波号。"
	)

	current_scene = null
	game.queue_free()
	for _cleanup_frame in range(8):
		await process_frame
		await physics_frame
	await _verify_zero_action_points_skip()
	_expect(
		zero_action_points_case_completed,
		"零行动点异步夹具不得因 SCRIPT ERROR 提前中止后假绿。"
	)
	await _verify_snapshot_ordering_and_idempotence()
	_expect(
		snapshot_ordering_case_completed,
		"快照顺序异步夹具不得因 SCRIPT ERROR 提前中止后假绿。"
	)
	if failures.is_empty():
		print("TOWER_DEFENSE_ROGUE_EXPLORATION_SMOKE_TEST_OK")
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	quit(1)


func _verify_zero_action_points_skip() -> void:
	zero_action_points_case_completed = false
	var game := TOWER_SCENE.instantiate() as TowerDefenseGame
	game.auto_start_waves = false
	game.progression_config = (
		FORMAL_PROGRESSION.duplicate(true) as TowerDefenseProgressionConfig
	)
	game.progression_config.daily_rogue_action_points = [0, 5, 5]
	var fate := game.get_node_or_null("FateCoordinator") as FateCoordinator
	if fate != null:
		fate.elite_enemy_config_loads_requested = true
	root.add_child(game)
	current_scene = game
	await process_frame
	var coordinator := game.get_rogue_exploration_coordinator()
	var wave_five := game.campaign_coordinator.get_flow_step_by_id(&"wave_05")
	_expect(
		coordinator.enter_exploration(1, wave_five),
		"行动力配置为0的探索日必须成功执行跳过语义。"
	)
	var entered_fate := await _wait_for_fate_interlude_entry(game, coordinator)
	var snapshot := coordinator.export_multiplayer_snapshot_for_peer()
	var grant_ledger := snapshot.get("daily_grant_ledger", {}) as Dictionary
	_expect(
		entered_fate
		and not coordinator.is_exploration_active()
		and not coordinator.get_route().is_route_ready()
		and int(grant_ledger.get("1", -1)) == 0
		and game.campaign_coordinator.wave_state
			== CombatFlowState.State.FATE_INTERLUDE,
		"0行动力日不得生成路线地图，并必须记录幂等0点发放后进入命运间奏。"
	)
	_expect(
		await _force_finish_fate_and_wait_for_tower(game),
		"0行动力日的命运间奏完成后必须返回塔防。"
	)
	_expect(
		game.campaign_coordinator.wave_state == CombatFlowState.State.INTERMISSION,
		"0行动力日的命运选择完成后必须续接新一日休整。"
	)
	_expect(
		coordinator.enter_exploration(1, wave_five),
		"0行动力日重复请求必须幂等成功。"
	)
	for _duplicate_frame in range(4):
		await process_frame
	_expect(
		game.campaign_coordinator.wave_state == CombatFlowState.State.INTERMISSION
		and not coordinator.is_exploration_active()
		and not coordinator.has_pending_presentation_exit()
		and not game.fate_manager.active
		and not coordinator.get_route().is_route_ready(),
		"0行动力日重复请求不得生成地图或重开 Fate。"
	)
	game.state_timer.stop()
	current_scene = null
	game.queue_free()
	for _cleanup_frame in range(8):
		await process_frame
		await physics_frame
	zero_action_points_case_completed = true


func _verify_snapshot_ordering_and_idempotence() -> void:
	snapshot_ordering_case_completed = false
	var run_state := root.get_node("RunState") as RunStateStore
	run_state.begin_new_run(PlayerCharacterRegistry.DEFAULT_CHARACTER_ID, false)
	var xirang_condition := load(
		"res://resources/config/collectibles/collectible_copper_gear.tres"
	) as PickupConfig
	var original_xirang_condition := {
		"attack_speed_xirang_step": xirang_condition.attack_speed_xirang_step,
		"attack_speed_bonus_per_xirang_step": (
			xirang_condition.attack_speed_bonus_per_xirang_step
		),
		"conditional_effect_id": xirang_condition.conditional_effect_id,
		"conditional_xirang_threshold": (
			xirang_condition.conditional_xirang_threshold
		),
		"conditional_attack_bonus": xirang_condition.conditional_attack_bonus,
		"conditional_move_speed_bonus": (
			xirang_condition.conditional_move_speed_bonus
		),
	}
	xirang_condition.attack_speed_xirang_step = 1_000
	xirang_condition.attack_speed_bonus_per_xirang_step = 1.0
	xirang_condition.conditional_effect_id = PickupConfig.CONDITION_XIRANG_AT_LEAST
	xirang_condition.conditional_xirang_threshold = 2_000
	xirang_condition.conditional_attack_bonus = 13
	xirang_condition.conditional_move_speed_bonus = 5.0
	_expect(
		run_state.try_add_item(xirang_condition),
		"Tower outer signal 屏障夹具必须建立息壤条件收藏品。"
	)
	var game := TOWER_SCENE.instantiate() as TowerDefenseGame
	game.auto_start_waves = false
	var fate := game.get_node_or_null("FateCoordinator") as FateCoordinator
	if fate != null:
		fate.elite_enemy_config_loads_requested = true
	root.add_child(game)
	current_scene = game
	await process_frame
	var coordinator := game.get_rogue_exploration_coordinator()
	var route := coordinator.get_route()
	var wave_five := game.campaign_coordinator.get_flow_step_by_id(&"wave_05")
	var wave_nine := game.campaign_coordinator.get_flow_step_by_id(&"wave_09")
	game.home_defense_coordinator.set_authoritative_base_health(135, 63)
	run_state.set_party_core_health(63, 135)
	_expect(
		coordinator.enter_exploration(1, wave_five),
		"乱序快照回归夹具必须能进入首日 Rogue。"
	)
	await process_frame
	run_state.set_party_core_health(28, 100)
	var active_snapshot := coordinator.export_multiplayer_snapshot_for_peer(0)
	var route_player := route.get_players_for_persistent_projection().get(0) as Player
	var baseline_attack := route_player.attack_damage
	var baseline_move_speed := route_player.move_speed
	var baseline_attack_speed := route_player.get_attack_speed()
	var old_xirang_values := run_state.party_xirang_balances.duplicate(true)
	var old_xirang_revision := run_state.party_xirang_ledger_revision
	var next_xirang_balance := run_state.get_party_xirang_balance(0) + 1_500
	_expect(
		run_state.set_party_xirang_balance(0, next_xirang_balance, false),
		"Tower outer signal 屏障夹具必须先构造 Host 的下一份息壤高水位。"
	)
	var next_xirang_snapshot := coordinator.export_multiplayer_snapshot_for_peer(0)
	# 同一进程模拟客户端仍停在旧高水位；Player 未收到 signal，因此余额与
	# 条件派生面板也保持旧值，直到 outer 组合事务一次性提交。
	run_state.party_xirang_balances = old_xirang_values
	run_state.party_xirang_ledger_revision = old_xirang_revision
	var player_signal_counts := {
		"xirang": 0,
		"attack_speed": 0,
		"profile": 0,
	}
	route_player.xirang_changed.connect(func(_total: int, _delta: int) -> void:
		player_signal_counts["xirang"] += 1
	)
	route_player.attack_speed_changed.connect(func(_value: float) -> void:
		player_signal_counts["attack_speed"] += 1
	)
	route_player.profile_display_changed.connect(func() -> void:
		player_signal_counts["profile"] += 1
	)
	var first_owner_observation := {
		"count": 0,
		"complete": false,
		"player_signals_already_emitted": false,
		"reentry_rejected": false,
		"route_direct_reentry_rejected": false,
	}
	var first_owner_callback := func(_ledger: Dictionary) -> void:
		first_owner_observation["count"] += 1
		first_owner_observation["reentry_rejected"] = not (
			coordinator.apply_multiplayer_snapshot(next_xirang_snapshot)
		)
		first_owner_observation["route_direct_reentry_rejected"] = not (
			route.apply_full_snapshot(
				next_xirang_snapshot["route_layout"] as Dictionary,
				next_xirang_snapshot["route_state"] as Dictionary,
				next_xirang_snapshot["encounter"] as Dictionary,
				next_xirang_snapshot["economy"] as Dictionary,
				next_xirang_snapshot["shop"] as Dictionary
			)
		)
		first_owner_observation["player_signals_already_emitted"] = (
			int(player_signal_counts["xirang"]) != 0
			or int(player_signal_counts["attack_speed"]) != 0
			or int(player_signal_counts["profile"]) != 0
		)
		first_owner_observation["complete"] = (
			coordinator.is_exploration_active()
			and run_state.get_party_xirang_balance(0) == next_xirang_balance
			and route.export_state_snapshot()
			== next_xirang_snapshot["route_state"]
			and route_player.current_xirang == next_xirang_balance
			and route_player.attack_damage == baseline_attack + 13
			and is_equal_approx(
				route_player.move_speed,
				baseline_move_speed + 5.0
			)
			and route_player.get_attack_speed() > baseline_attack_speed
			and route.get_players_for_persistent_projection().get(0)
			== route_player
		)
	run_state.party_xirang_ledger_changed.connect(first_owner_callback)
	route.set_authority_enabled(false)
	var next_xirang_applied := coordinator.apply_multiplayer_snapshot(
		next_xirang_snapshot
	)
	route.set_authority_enabled(true)
	run_state.party_xirang_ledger_changed.disconnect(first_owner_callback)
	_expect(
		next_xirang_applied
		and int(first_owner_observation["count"]) == 1
		and bool(first_owner_observation["complete"])
		and bool(first_owner_observation["reentry_rejected"])
		and bool(
			first_owner_observation["route_direct_reentry_rejected"]
		)
		and not bool(
			first_owner_observation["player_signals_already_emitted"]
		)
		and int(player_signal_counts["xirang"]) == 1
		and int(player_signal_counts["attack_speed"]) == 1
		and int(player_signal_counts["profile"]) == 1,
		(
			"Tower active outer 的首个 owner 回调必须同时看见 outer/RunState/"
			+ "Route/全部 Player 与息壤条件面板的新状态；Player 契约 signal "
			+ "只能随后各发布一次。"
		)
	)
	active_snapshot = coordinator.export_multiplayer_snapshot_for_peer(0)
	# CH6 Research / CH5 Fate 可能先于旧 CH0 active 到达。owner 高水位
	# 已推进时，旧 outer 必须全域拒绝，不能拿 stale token 回写 Route Player；
	# 下一份同代自包含 outer 才统一投影新永久层。
	var stale_persistent_owner_active_snapshot := active_snapshot.duplicate(true)
	var newer_research_state := game.research_coordinator.export_runtime_state()
	newer_research_state["revision"] = int(newer_research_state["revision"]) + 1
	var newer_research_levels := newer_research_state["player_levels"] as Dictionary
	newer_research_levels[0] = mini(
		int(newer_research_levels[0]) + 1,
		Player.RESEARCH_TECHNOLOGY_MAX_LEVEL
	)
	var prepared_newer_research := (
		game.research_coordinator.prepare_multiplayer_runtime_state(
			newer_research_state,
			false
		)
	)
	var newer_fate_state := fate.export_persistent_player_modifier_snapshot()
	newer_fate_state["revision"] = int(newer_fate_state["revision"]) + 1
	newer_fate_state["player_max_health_multiplier"] = 1.08
	newer_fate_state["player_move_speed_multiplier"] = 1.06
	newer_fate_state["player_dash_cooldown_reduction"] = 0.20
	var prepared_newer_fate := fate.prepare_persistent_player_modifier_snapshot(
		newer_fate_state,
		false
	)
	_expect(
		game.research_coordinator.commit_prepared_multiplayer_runtime_state(
			prepared_newer_research
		)
		and fate.commit_prepared_persistent_player_modifier_snapshot(
			prepared_newer_fate
		),
		"跨信道乱序夹具必须先推进 Research/Fate 权威高水位。"
	)
	# Host Fate manager 与永久投影 revision 同代；测试直接模拟已验 CH5
	# commit 后的权威 manager 高水位，供随后 outer 导出自包含快照。
	fate.manager.state_revision = int(newer_fate_state["revision"])
	var stale_owner_player_baseline := {
		"research": route_player.get_research_technology_level(),
		"fate_max": route_player.tower_defense_fate_max_health_multiplier,
		"fate_move": route_player.tower_defense_fate_move_speed_multiplier,
		"attack": route_player.attack_damage,
		"max_health": route_player.max_health,
	}
	var newer_research_committed := game.research_coordinator.export_runtime_state()
	var newer_fate_committed := fate.export_persistent_player_modifier_snapshot()
	route.set_authority_enabled(false)
	var stale_owner_outer_applied := coordinator.apply_multiplayer_snapshot(
		stale_persistent_owner_active_snapshot
	)
	route.set_authority_enabled(true)
	_expect(
		not stale_owner_outer_applied
		and game.research_coordinator.export_runtime_state()
		== newer_research_committed
		and fate.export_persistent_player_modifier_snapshot()
		== newer_fate_committed
		and route_player.get_research_technology_level()
		== int(stale_owner_player_baseline["research"])
		and is_equal_approx(
			route_player.tower_defense_fate_max_health_multiplier,
			float(stale_owner_player_baseline["fate_max"])
		)
		and is_equal_approx(
			route_player.tower_defense_fate_move_speed_multiplier,
			float(stale_owner_player_baseline["fate_move"])
		)
		and route_player.attack_damage == int(
			stale_owner_player_baseline["attack"]
		)
		and route_player.max_health == int(
			stale_owner_player_baseline["max_health"]
		),
		"较新 Research/Fate 后到达的旧 active outer 必须零 owner/Player 回滚。"
	)
	var refreshed_persistent_outer := (
		coordinator.export_multiplayer_snapshot_for_peer(0)
	)
	route.set_authority_enabled(false)
	var refreshed_persistent_applied := coordinator.apply_multiplayer_snapshot(
		refreshed_persistent_outer
	)
	route.set_authority_enabled(true)
	_expect(
		refreshed_persistent_applied
		and route_player.get_research_technology_level()
		== int(newer_research_levels[0])
		and is_equal_approx(
			route_player.tower_defense_fate_max_health_multiplier,
			1.08
		)
		and is_equal_approx(
			route_player.tower_defense_fate_move_speed_multiplier,
			1.06
		),
		"同代新 outer 必须在 reveal 前把 Research/Fate 高水位绝对投影到 Route Player。"
	)
	active_snapshot = coordinator.export_multiplayer_snapshot_for_peer(0)
	# 模拟 CH6/runtime repair 已把三类 Party 高水位推进，随后才到达旧 CH0
	# active outer。路线表现可重建，但持久经济绝不能随 layout rewind 回退。
	var stale_party_active_snapshot := active_snapshot.duplicate(true)
	var stale_route_state_baseline := route.export_state_snapshot()
	var stale_route_layout_baseline := route.export_layout_snapshot()
	_expect(
		run_state.set_party_xirang_balance(
			0,
			run_state.get_party_xirang_balance(0) + 37
		)
		and run_state.set_max_health_penalty_for_peer(
			0,
			run_state.get_max_health_penalty_for_peer(0) + 3
		)
		and run_state.try_add_item(RunStateStore.STARTING_WOOD),
		"旧 CH0 回归夹具必须先推进息壤、状态与背包三类 Party 高水位。"
	)
	var newer_party_economy := run_state.export_party_economy_snapshot()
	var player_panel_baseline := {
		"current_health": route_player.current_health,
		"max_health": route_player.max_health,
		"move_speed": route_player.move_speed,
		"attack_damage": route_player.attack_damage,
	}
	route.set_authority_enabled(false)
	var stale_party_snapshot_applied := coordinator.apply_multiplayer_snapshot(
		stale_party_active_snapshot
	)
	route.set_authority_enabled(true)
	_expect(
		not stale_party_snapshot_applied
		and run_state.export_party_economy_snapshot() == newer_party_economy
		and route.export_state_snapshot() == stale_route_state_baseline
		and route.export_layout_snapshot() == stale_route_layout_baseline
		and route_player.current_health == int(
			player_panel_baseline["current_health"]
		)
		and route_player.max_health == int(player_panel_baseline["max_health"])
		and route_player.move_speed == float(player_panel_baseline["move_speed"])
		and route_player.attack_damage == int(
			player_panel_baseline["attack_damage"]
		),
		(
			"较新 CH6 后到达的旧 active CH0 必须全域拒绝：息壤、状态、背包、"
			+ "路线与玩家面板均不得被旧快照回滚。"
		)
	)
	# Host 下一份同代 outer 携带新高水位后应可继续正常同步。
	active_snapshot = coordinator.export_multiplayer_snapshot_for_peer(0)
	var jumped_active_snapshot := active_snapshot.duplicate(true)
	jumped_active_snapshot["day"] = 2
	jumped_active_snapshot["next_step_id"] = String(wave_nine.step_id)
	var jumped_ledger := (
		jumped_active_snapshot["daily_grant_ledger"] as Dictionary
	)
	jumped_ledger["2"] = 5
	_expect(
		not coordinator.apply_multiplayer_snapshot(jumped_active_snapshot)
		and int(
			coordinator.export_multiplayer_snapshot_for_peer().get("day", -1)
		) == 1,
		"active 会话不得被另一探索日的 active 快照原地替换。"
	)
	var wrong_epoch_inactive_snapshot := active_snapshot.duplicate(true)
	wrong_epoch_inactive_snapshot["active"] = false
	wrong_epoch_inactive_snapshot["day"] = 0
	wrong_epoch_inactive_snapshot["next_step_id"] = ""
	wrong_epoch_inactive_snapshot["map_generation_epoch"] = (
		int(active_snapshot["map_generation_epoch"]) + 1
	)
	_expect(
		not coordinator.apply_multiplayer_snapshot(
			wrong_epoch_inactive_snapshot
		)
		and coordinator.is_exploration_active(),
		"inactive 快照必须精确终结当前 map epoch，不能跨会话关闭 Rogue。"
	)

	var inactive_snapshot := active_snapshot.duplicate(true)
	inactive_snapshot["active"] = false
	inactive_snapshot["day"] = 0
	inactive_snapshot["next_step_id"] = ""
	# 模拟 channel 5 的 Tower 基地恢复先于 channel 0 inactive 快照到达；
	# false 不发 party-status 信号，因此不能污染 active 期间锁存的 Rogue 核心。
	run_state.set_party_core_health(63, 135, false)
	_expect(
		coordinator.apply_multiplayer_snapshot(inactive_snapshot)
		and coordinator.has_pending_presentation_exit()
		and int(coordinator.get("_rogue_core_current")) == 28
		and int(coordinator.get("_rogue_core_maximum")) == 100,
		"Tower 核心先到时，inactive 边界仍必须保留最后的 Rogue 核心缓存。"
	)
	var stale_active_snapshot := active_snapshot.duplicate(true)
	stale_active_snapshot["economy"] = (
		route.export_encounter_economy_snapshot(0)
	)
	_expect(
		not coordinator.apply_multiplayer_snapshot(stale_active_snapshot)
		and coordinator.has_pending_presentation_exit()
		and not coordinator.is_exploration_active(),
		"inactive 后乱序重发的旧 active 快照不得取消 pending 或重开路线。"
	)
	var restore_signal_observation := {
		"emitted": false,
		"suspended": false,
		"route_visible": false,
	}
	var restore_signal_callback := func(
		_current_health: int,
		_maximum_health: int,
		_revision: int
	) -> void:
		restore_signal_observation["emitted"] = true
		restore_signal_observation["suspended"] = (
			coordinator.is_tower_runtime_suspended()
		)
		restore_signal_observation["route_visible"] = route.visible
	game.home_defense_coordinator.base_health_changed.connect(
		restore_signal_callback
	)
	var presentation_exit_completed := (
		coordinator.complete_pending_presentation_exit()
	)
	game.home_defense_coordinator.base_health_changed.disconnect(
		restore_signal_callback
	)
	_expect(
		presentation_exit_completed
		and not coordinator.complete_pending_presentation_exit()
		and not coordinator.has_pending_presentation_exit()
		and not coordinator.apply_multiplayer_snapshot(stale_active_snapshot)
		and run_state.get_party_core_health() == 63
		and run_state.get_party_core_maximum_health() == 135
		and int(coordinator.get("_rogue_core_current")) == 28
		and int(coordinator.get("_rogue_core_maximum")) == 100,
		"pending 视觉退出必须只消费一次，且完成后仍拒绝已结算日旧 active 快照。"
	)
	_expect(
		bool(restore_signal_observation["emitted"])
		and bool(restore_signal_observation["suspended"])
		and bool(restore_signal_observation["route_visible"]),
		"核心恢复同步发信号时 pending 必须仍持有 suspension 与 Rogue 最后一帧。"
	)
	# 模拟玩家在 Rogue 终局结算期间断线：客户端只持有旧 Tower Player，
	# 重连时收到 inactive outer，必须一次修齐成长、完整 Party Economy、
	# Research 与 Fate，而不能等待下一次 active 探索才纠正面板。
	var inactive_repair := coordinator.export_multiplayer_snapshot_for_peer(0)
	var repaired_progression := (
		inactive_repair["player_upgrade_ledger"] as Dictionary
	)
	repaired_progression["revision"] = int(repaired_progression["revision"]) + 1
	var repaired_progression_values := (
		repaired_progression["values"] as Dictionary
	)
	var repaired_progression_owner := (
		repaired_progression_values["0"] as Dictionary
	)
	var repaired_upgrade_levels := (
		repaired_progression_owner["upgrade_levels"] as Dictionary
	)
	var repaired_attack_key := str(int(RunStateStore.StatType.ATTACK))
	repaired_upgrade_levels[repaired_attack_key] = mini(
		int(repaired_upgrade_levels[repaired_attack_key]) + 1,
		int(RunStateStore.MAX_UPGRADE_LEVELS[RunStateStore.StatType.ATTACK])
	)
	var repaired_party := inactive_repair["party_economy"] as Dictionary
	var repaired_xirang := repaired_party["xirang_ledger"] as Dictionary
	repaired_xirang["revision"] = int(repaired_xirang["revision"]) + 1
	var repaired_xirang_values := repaired_xirang["values"] as Dictionary
	var repaired_balance := int(repaired_xirang_values["0"]) + 321
	repaired_xirang_values["0"] = repaired_balance
	var repaired_status := repaired_party["party_status_ledger"] as Dictionary
	repaired_status["revision"] = int(repaired_status["revision"]) + 1
	var repaired_bonuses := repaired_status["player_stat_bonuses"] as Dictionary
	var repaired_owner_bonuses := repaired_bonuses["0"] as Dictionary
	repaired_owner_bonuses["attack_damage"] = (
		int(repaired_owner_bonuses["attack_damage"]) + 4
	)
	inactive_repair["party_xirang_ledger"] = repaired_xirang.duplicate(true)
	inactive_repair["party_status_ledger"] = repaired_status.duplicate(true)
	var repaired_research := inactive_repair["research_runtime_state"] as Dictionary
	repaired_research["revision"] = int(repaired_research["revision"]) + 1
	var repaired_research_levels := repaired_research["player_levels"] as Dictionary
	var repaired_research_level := mini(
		int(repaired_research_levels[0]) + 1,
		Player.RESEARCH_TECHNOLOGY_MAX_LEVEL
	)
	repaired_research_levels[0] = repaired_research_level
	var repaired_fate := (
		inactive_repair["fate_persistent_player_modifiers"] as Dictionary
	)
	repaired_fate["revision"] = int(repaired_fate["revision"]) + 1
	repaired_fate["player_max_health_multiplier"] = 1.15
	repaired_fate["player_move_speed_multiplier"] = 1.10
	repaired_fate["player_dash_cooldown_reduction"] = 0.25
	var tower_player_before_repair := {
		"attack": game.player.attack_damage,
		"effective_move_ratio": (
			game.player.get_authoritative_effective_move_speed_ratio()
		),
	}
	var inactive_repair_applied := coordinator.apply_multiplayer_snapshot(
		inactive_repair
	)
	_expect(
		inactive_repair_applied
		and run_state.export_player_upgrade_ledger() == repaired_progression
		and run_state.export_party_economy_snapshot() == repaired_party
		and game.research_coordinator.export_runtime_state() == repaired_research
		and run_state.get_party_xirang_balance(0) == repaired_balance
		and game.player.current_xirang == repaired_balance
		and game.player.get_research_technology_level()
		== repaired_research_level
		and is_equal_approx(
			game.player.tower_defense_fate_max_health_multiplier,
			1.15
		)
		and is_equal_approx(
			game.player.tower_defense_fate_move_speed_multiplier,
			1.10
		)
		and game.player.attack_damage > int(tower_player_before_repair["attack"])
		and game.player.get_authoritative_effective_move_speed_ratio() > float(
			tower_player_before_repair["effective_move_ratio"]
		),
		(
			"错过 Rogue settlement 后的 inactive reconnect 必须自包含修复成长、"
			+ "Xirang/status/inventory、Research/Fate，并立即重投 Tower Player。"
		)
	)
	# 模拟一个从未见过 Rogue 的新客户端：CH5 Fate 已先到，随后 CH0
	# 才按自身可靠顺序补送旧 active→inactive。旧 active 必须被流程状态
	# 淘汰，inactive 只收敛账本，不能新建无人消费的 pending。
	coordinator.set("_daily_grant_ledger", {})
	coordinator.set("_map_generation_epoch", 0)
	game.campaign_coordinator.replace_flow_state_for_fixture(
		CombatFlowState.State.WAVE_ACTIVE
	)
	game.campaign_coordinator.current_wave_index = 4
	_expect(
		not coordinator.apply_multiplayer_snapshot(active_snapshot),
		"Campaign 已进入更后日时必须按日序淘汰旧 Rogue active 快照。"
	)
	game.campaign_coordinator.current_wave_index = 0
	game.campaign_coordinator.replace_flow_state_for_fixture(
		CombatFlowState.State.FATE_INTERLUDE
	)
	var superseded_active_applied := coordinator.apply_multiplayer_snapshot(
		active_snapshot
	)
	var terminal_inactive_applied := coordinator.apply_multiplayer_snapshot(
		inactive_repair
	)
	_expect(
		not superseded_active_applied
		and terminal_inactive_applied
		and not coordinator.is_exploration_active()
		and not coordinator.has_pending_presentation_exit()
		and int(
			(
				coordinator.export_multiplayer_snapshot_for_peer().get(
					"daily_grant_ledger",
					{}
				) as Dictionary
			).get("1", -1)
		) == 5,
		"CH5 Fate 先到时，晚到的 CH0 active→inactive 只能收敛为无 pending 的终态。"
	)
	game.state_timer.stop()
	xirang_condition.attack_speed_xirang_step = int(
		original_xirang_condition["attack_speed_xirang_step"]
	)
	xirang_condition.attack_speed_bonus_per_xirang_step = float(
		original_xirang_condition["attack_speed_bonus_per_xirang_step"]
	)
	xirang_condition.conditional_effect_id = StringName(
		original_xirang_condition["conditional_effect_id"]
	)
	xirang_condition.conditional_xirang_threshold = int(
		original_xirang_condition["conditional_xirang_threshold"]
	)
	xirang_condition.conditional_attack_bonus = int(
		original_xirang_condition["conditional_attack_bonus"]
	)
	xirang_condition.conditional_move_speed_bonus = float(
		original_xirang_condition["conditional_move_speed_bonus"]
	)
	current_scene = null
	game.queue_free()
	for _cleanup_frame in range(8):
		await process_frame
		await physics_frame
	snapshot_ordering_case_completed = true


func _add_audio_player(
	parent: Node,
	stream: AudioStream,
	bus: StringName
) -> AudioStreamPlayer:
	var audio_player := AudioStreamPlayer.new()
	audio_player.stream = stream
	audio_player.bus = bus
	parent.add_child(audio_player)
	audio_player.play()
	return audio_player


func _add_audio_player_2d(
	parent: Node,
	stream: AudioStream,
	bus: StringName
) -> AudioStreamPlayer2D:
	var audio_player := AudioStreamPlayer2D.new()
	audio_player.stream = stream
	audio_player.bus = bus
	parent.add_child(audio_player)
	audio_player.play()
	return audio_player


func _set_route_action_points_for_boundary_test(
	route: RogueRouteGame,
	action_points: int
) -> void:
	var runtime_state := route.get("_runtime_state") as RogueRouteRuntimeState
	runtime_state.action_points = action_points
	runtime_state.state_changed.emit(runtime_state.export_state())


func _configure_adjacent_normal_combat_route(
	route: RogueRouteGame
) -> Dictionary:
	for seed in range(1, MAX_COMBAT_FIXTURE_SEED + 1):
		var graph := RogueRouteGenerator.generate(route.generation_config, seed)
		if graph == null:
			continue
		for neighbor_id in graph.get_neighbors(graph.start_node_id):
			if (
				graph.get_node_type(neighbor_id)
				!= RogueRouteGraph.NodeType.NORMAL_COMBAT
			):
				continue
			if not route.start_authoritative_session(seed, false, 5):
				return {}
			route.restore_players_for_route_scene_entry()
			route.route_board.complete_entry_reveal()
			return {
				"seed": seed,
				"combat_node_id": int(neighbor_id),
			}
	return {}


func _wait_for_active_battle(
	coordinator: RogueCombatSingleplayerCoordinator
) -> RogueCombatGame:
	for _frame_index in MAX_COMBAT_WAIT_FRAMES:
		var battle := coordinator.get_active_battle()
		if battle != null and is_instance_valid(battle):
			return battle
		await process_frame
	return null


func _wait_for_combat_result(route: RogueRouteGame) -> bool:
	for _frame_index in MAX_COMBAT_WAIT_FRAMES:
		if route.combat_result_overlay.visible:
			return true
		await process_frame
	return false


func _wait_for_combat_settlement(
	coordinator: RogueCombatSingleplayerCoordinator
) -> bool:
	for _frame_index in MAX_COMBAT_WAIT_FRAMES:
		if (
			coordinator.get_active_battle() == null
			and not coordinator.is_runtime_busy()
		):
			return true
		await process_frame
	return false


func _wait_for_fate_interlude_entry(
	game: TowerDefenseGame,
	coordinator: TowerDefenseRogueExplorationCoordinator
) -> bool:
	for _frame_index in range(240):
		if (
			not coordinator.is_exploration_active()
			and game.campaign_coordinator.wave_state
			== CombatFlowState.State.FATE_INTERLUDE
			and game.fate_manager.active
			and game.xiaocong_fate_interlude.is_active
		):
			return true
		await process_frame
	return false


func _force_finish_fate_and_wait_for_tower(game: TowerDefenseGame) -> bool:
	if not game.fate_manager.active:
		return false
	game.fate_manager.force_finish()
	for _frame_index in range(480):
		if (
			not game.fate_manager.active
			and not game.xiaocong_fate_interlude.is_active
			and game.campaign_coordinator.wave_state
			!= CombatFlowState.State.FATE_INTERLUDE
			and game.xiaocong_fate_interlude.scene_transition_progress
			<= 0.001
			and not game.xiaocong_fate_interlude.scene_transition_layer.visible
		):
			return true
		await process_frame
	return false


func _all_route_canvas_layers_hidden(route: RogueRouteGame) -> bool:
	for child in route.find_children("*", "CanvasLayer", true, false):
		var canvas_layer := child as CanvasLayer
		if canvas_layer != null and canvas_layer.visible:
			return false
	return true


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
