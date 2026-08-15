extends SceneTree

const TOWER_SCENE := preload(
	"res://scene/game_modes/tower_defense/tower_defense_game.tscn"
)
const FORMAL_PROGRESSION: TowerDefenseProgressionConfig = preload(
	"res://resources/config/campaigns/tower_defense/formal_progression.tres"
)
const MAX_COMBAT_FIXTURE_SEED := 2048
const MAX_COMBAT_WAIT_FRAMES := 600

var failures: Array[String] = []


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
	_expect(
		game.music_player.has_stream_playback()
		and tower_music_playback != null
		and not game.music_player.stream_paused,
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
	coordinator.call("_freeze_tower_runtime")
	coordinator.call("_freeze_tower_runtime")
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
		and game.music_player.stream_paused,
		"冻结边界必须暂停同一个 Tower 音乐 playback，不能 stop 或重建。"
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
		and not game.music_player.stream_paused,
		"恢复边界必须解除同一个 Tower 音乐 playback 的暂停。"
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
	await _verify_snapshot_ordering_and_idempotence()
	if failures.is_empty():
		print("TOWER_DEFENSE_ROGUE_EXPLORATION_SMOKE_TEST_OK")
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	quit(1)


func _verify_zero_action_points_skip() -> void:
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


func _verify_snapshot_ordering_and_idempotence() -> void:
	var run_state := root.get_node("RunState") as RunStateStore
	run_state.begin_new_run(PlayerCharacterRegistry.DEFAULT_CHARACTER_ID, false)
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
		inactive_snapshot
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
	current_scene = null
	game.queue_free()
	for _cleanup_frame in range(8):
		await process_frame
		await physics_frame


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
			route.restore_embedded_players_to_full_health()
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
