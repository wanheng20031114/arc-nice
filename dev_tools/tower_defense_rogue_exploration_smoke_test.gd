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
	var decay_time_before_freeze := game.plant_terrain_decay_timer.time_left
	coordinator.call("_freeze_tower_runtime")
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
				"行动力归零时，活动作战必须阻止地下探索自动返回。"
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

	route_player.apply_multiplayer_death_state()
	_set_route_action_points_for_boundary_test(route, 0)
	var auto_returned := await _wait_for_automatic_return(coordinator)
	_expect(
		auto_returned,
		"行动力归零且所有路线子流程稳定后必须自动返回塔防。"
	)
	game.state_timer.stop()
	_expect(
		not coordinator.is_exploration_active()
		and not route.visible
		and _all_route_canvas_layers_hidden(route)
		and game.map_camera.enabled
		and run_state.get_party_core_health() == 63
		and run_state.get_party_core_maximum_health() == 135
		and game.home_defense_coordinator.current_base_health == 63
		and game.home_defense_coordinator.maximum_base_health == 135,
		"探索返回必须隐藏路线表现，并原子恢复冻结前的塔防核心状态。"
	)
	_expect(
		not game.production_coordinator.authoritative_processing_enabled
		and not game.research_coordinator.authoritative_processing_enabled
		and game.plant_terrain_decay_timer.is_stopped(),
		"返回必须精确恢复进入前已停止的生产、研究与衰减状态。"
	)
	_expect(
		run_state.inventory_revision > inventory_revision_before_combat,
		"地下探索自动返回不得回滚已经提交的作战奖励。"
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
		"正常返回后的第二日必须复用同一地图，并只追加当日5点行动力。"
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
	game.state_timer.stop()
	await process_frame
	_expect(
		run_state.get_party_core_health() == 63
		and run_state.get_party_core_maximum_health() == 135
		and game.home_defense_coordinator.current_base_health == 63
		and game.home_defense_coordinator.maximum_base_health == 135,
		"探索失败也必须精确恢复塔防核心，不能导致返回后立即塔防失败。"
	)

	var boss := game.campaign_coordinator.get_flow_step_by_id(&"boss_01_linglan")
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
	game.state_timer.stop()
	await process_frame
	_expect(
		game.campaign_coordinator.wave_state == CombatFlowState.State.INTERMISSION
		and game.campaign_coordinator.countdown_seconds == 60
		and game.wave_hud.day_label.text == "第 4 日"
		and game.wave_hud.phase_label.text == "白昼"
		and game.wave_hud.wave_title_label.text == "首领战准备"
		and not game.wave_hud.global_wave_notice.visible,
		"第三次探索返回后必须进入60秒第4日白昼首领准备，不显示普通波号。"
	)

	current_scene = null
	game.queue_free()
	for _cleanup_frame in range(8):
		await process_frame
		await physics_frame
	await _verify_zero_action_points_skip()
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
	var snapshot := coordinator.export_multiplayer_snapshot_for_peer()
	var grant_ledger := snapshot.get("daily_grant_ledger", {}) as Dictionary
	_expect(
		not coordinator.is_exploration_active()
		and not coordinator.get_route().is_route_ready()
		and int(grant_ledger.get("1", -1)) == 0
		and game.campaign_coordinator.wave_state
			== CombatFlowState.State.INTERMISSION,
		"0行动力日不得生成地图或冻结塔防，并必须记录幂等0点发放后继续流程。"
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


func _wait_for_automatic_return(
	coordinator: TowerDefenseRogueExplorationCoordinator
) -> bool:
	for _frame_index in range(240):
		if not coordinator.is_exploration_active():
			return true
		await process_frame
	return not coordinator.is_exploration_active()


func _all_route_canvas_layers_hidden(route: RogueRouteGame) -> bool:
	for child in route.find_children("*", "CanvasLayer", true, false):
		var canvas_layer := child as CanvasLayer
		if canvas_layer != null and canvas_layer.visible:
			return false
	return true


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
