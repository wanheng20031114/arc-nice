extends SceneTree

const TOWER_SCENE := preload(
	"res://scene/game_modes/tower_defense/tower_defense_game.tscn"
)
const ROOT_SOURCE_PATH := (
	"res://scene/game_modes/tower_defense/tower_defense_game.gd"
)
const FATE_SOURCE_PATH := (
	"res://scene/game_modes/tower_defense/fate/fate_coordinator.gd"
)
const HOME_SOURCE_PATH := (
	"res://scene/game_modes/tower_defense/home/"
	+ "tower_defense_home_defense_coordinator.gd"
)
const FLOW_SOURCE_PATH := (
	"res://scene/game_modes/tower_defense/fate/"
	+ "tower_defense_fate_flow_coordinator.gd"
)
const LUOXI_SOURCE_PATH := (
	"res://scene/game_modes/tower_defense/merchants/luoxi/"
	+ "luoxi_special_game_coordinator.gd"
)
const RESEARCH_SOURCE_PATH := (
	"res://scene/game_modes/tower_defense/economy/research/research_coordinator.gd"
)

var failures: Array[String] = []


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	_test_static_boundaries()
	await _test_runtime_binding_and_behavior()
	if failures.is_empty():
		print("TOWER_DEFENSE_FATE_FLOW_COORDINATOR_BOUNDARY_SMOKE_TEST_OK")
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	quit(1)


func _test_static_boundaries() -> void:
	var root_source := _read_text(ROOT_SOURCE_PATH)
	var fate_source := _read_text(FATE_SOURCE_PATH)
	var home_source := _read_text(HOME_SOURCE_PATH)
	var flow_source := _read_text(FLOW_SOURCE_PATH)
	var luoxi_source := _read_text(LUOXI_SOURCE_PATH)
	var research_source := _read_text(RESEARCH_SOURCE_PATH)
	for source_pair in [
		["FateCoordinator", fate_source],
		["FateFlowCoordinator", flow_source],
		["LuoxiSpecialGameCoordinator", luoxi_source],
		["ResearchCoordinator", research_source],
	]:
		var label := str(source_pair[0])
		var source := str(source_pair[1])
		for forbidden in [
			"TowerDefenseGame",
			"get_tree().current_scene",
			"has_method(",
			".call(",
			"Callable",
		]:
			_expect(
				not source.contains(forbidden),
				"%s 仍存在动态/root 反向依赖：%s" % [label, forbidden]
			)
	_expect(
		fate_source.contains(
			"home_defense_coordinator.set_authoritative_base_health("
		)
		and fate_source.contains(
			"player_roster_coordinator.get_player_for_runtime_peer("
		)
		and fate_source.contains("multiplayer_adapter.publish_inventory_changed("),
		"FateCoordinator 未直连 Home/Roster/Adapter。"
	)
	_expect(
		flow_source.contains("campaign_coordinator.apply_remote_flow_state(")
		and flow_source.contains("presentation_coordinator.transition_world_to_day()")
		and flow_source.contains("multiplayer_gateway.player_teleport_requested.emit("),
		"FateFlowCoordinator 未直连 Campaign/Presentation/Gateway。"
	)
	_expect(
		luoxi_source.contains("home_defense_coordinator.apply_base_damage(")
		and luoxi_source.contains("player_roster_coordinator.get_all_players()")
		and luoxi_source.contains("multiplayer_adapter.apply_luoxi_player_health_loss("),
		"LuoxiSpecialGameCoordinator 未直连 Home/Roster/Adapter。"
	)
	_expect(
		research_source.contains(
			"player_roster_coordinator: TowerDefensePlayerRosterCoordinator"
		)
		and not research_source.contains("var game:"),
		"ResearchCoordinator 仍依赖 TowerDefenseGame。"
	)
	for removed_facade in [
		"func request_xiaocong_interaction(",
		"func apply_remote_xiaocong_fate_state(",
		"func _teleport_fate_player_authoritatively(",
		"func request_luoxi_special_game_start(",
		"func apply_luoxi_core_health_loss(",
		"func try_claim_luoxi_collectible_for_peer(",
	]:
		_expect(
			not root_source.contains(removed_facade),
			"TowerDefenseGame 仍保留无生产调用 façade：%s" % removed_facade
		)
	_expect(
		root_source.contains("func grant_xirang_kill_reward(amount: int) -> bool:")
		and root_source.contains("fate_coordinator.is_double_xirang_reward_active()")
		and root_source.contains("campaign_coordinator.record_xirang_reward("),
		"TowerDefenseGame 必须只保留直连 Fate+Campaign 的息壤击杀覆写。"
	)
	_expect(
		home_source.contains("_present_base_health(false, false)")
		and home_source.contains("if play_damage_pulse:")
		and home_source.contains("_presentation_coordinator.play_gate_damage_warning()"),
		"基地警报必须由 HomeDefenseCoordinator 只响应真实伤害。"
	)


func _test_runtime_binding_and_behavior() -> void:
	var game := TOWER_SCENE.instantiate() as TowerDefenseGame
	_expect(game != null, "塔防主场景无法实例化。")
	if game == null:
		return
	game.auto_start_waves = false
	var runtime_fate := game.get_node_or_null("FateCoordinator") as FateCoordinator
	if runtime_fate != null:
		runtime_fate.elite_enemy_config_loads_requested = true
	var runtime_boss := game.get_node_or_null(
		"BossCoordinator"
	) as TowerDefenseBossCoordinator
	if runtime_boss != null:
		runtime_boss.runtime_scene_loads_requested = true
	root.add_child(game)
	current_scene = game
	await process_frame
	var flow := game.fate_flow_coordinator
	var fate := game.fate_coordinator
	var roster := game.player_roster_coordinator
	_expect(flow != null and flow.is_bound(), "FateFlowCoordinator 依赖绑定不完整。")
	_expect(
		flow.campaign_coordinator == game.campaign_coordinator
		and flow.player_roster_coordinator == roster
		and flow.plant_placement_coordinator == game.plant_placement_coordinator
		and flow.presentation_coordinator == game.presentation_coordinator
		and flow.multiplayer_adapter == game.tower_multiplayer_mode_adapter
		and flow.multiplayer_gateway == game.multiplayer_gateway,
		"FateFlowCoordinator 未绑定静态强类型依赖。"
	)
	_expect(
		fate.home_defense_coordinator == game.home_defense_coordinator
		and fate.player_roster_coordinator == roster
		and fate.run_state == game.run_state
		and fate.luoxi_merchant == game.luoxi_merchant,
		"FateCoordinator 未绑定静态强类型依赖。"
	)
	_expect(
		game.research_coordinator.player_roster_coordinator == roster
		and game.luoxi_special_game_coordinator.player_roster_coordinator == roster,
		"Research/Luoxi 未绑定 PlayerRoster。"
	)

	var previous_revision := game.home_defense_coordinator.base_health_revision
	var ledger_revision_before := game.run_state.get_party_status_ledger_revision()
	var ledger_health_before := game.run_state.get_party_core_health()
	var ledger_maximum_before := game.run_state.get_party_core_maximum_health()
	var warning_msec_before := game.tower_defense_status_hud.last_gate_warning_msec
	fate._set_base_health(37, 1)
	_expect(
		game.home_defense_coordinator.maximum_base_health == 37
		and game.home_defense_coordinator.current_base_health == 1
		and game.home_defense_coordinator.base_health_revision
		== previous_revision + 1,
		"Fate 基地生命修改必须经 HomeDefenseCoordinator。"
	)
	_expect(
		game.tower_defense_status_hud.last_gate_warning_msec
		== warning_msec_before,
		"Fate 基地生命修改不得触发受击警报。"
	)
	_expect(
		game.run_state.get_party_status_ledger_revision() == ledger_revision_before
		and game.run_state.get_party_core_health() == ledger_health_before
		and game.run_state.get_party_core_maximum_health() == ledger_maximum_before,
		"Fate 基地生命修改不得额外写入 RunState 状态账本。"
	)

	roster.set_runtime_identity(CombatRuntimeBase.RuntimeMode.HOST_AUTHORITY, 2)
	roster.spawn_slot_indices.erase(99)
	_expect(
		roster.get_world_spawn_position(99, 2)
		== game.player_spawn.global_position
			+ TowerDefenseGame.MULTIPLAYER_SPAWN_OFFSETS[2],
		"缺失 spawn slot 时必须沿用玩家遍历槽位，而不是回落到槽位 0。"
	)

	roster.set_runtime_identity(CombatRuntimeBase.RuntimeMode.SINGLEPLAYER, 0)
	game.plant_terrain_decay_timer.start(8.0)
	await process_frame
	flow.set_interlude_systems_frozen(true)
	var captured_time_left := flow.frozen_terrain_decay_time_left
	flow.set_interlude_systems_frozen(true)
	_expect(
		game.plant_terrain_decay_timer.is_stopped()
		and captured_time_left > 0.0
		and is_equal_approx(flow.frozen_terrain_decay_time_left, captured_time_left)
		and not game.production_coordinator.authoritative_processing_enabled
		and not game.research_coordinator.authoritative_processing_enabled,
		"Fate freeze 必须幂等暂停 timer、生产与科研。"
	)
	flow.set_interlude_systems_frozen(false)
	_expect(
		not game.plant_terrain_decay_timer.is_stopped()
		and game.production_coordinator.authoritative_processing_enabled
		and game.research_coordinator.authoritative_processing_enabled,
		"Fate unfreeze 必须恢复权威系统。"
	)

	flow.set_player_combat_locked(true)
	_expect(
		game.player.combat_actions_locked and not game.player.controls_locked,
		"Fate 幕间必须只锁战斗动作。"
	)
	flow.set_player_combat_locked(false)
	flow.teleport_authoritative_players_to_room()
	_expect(
		game.player.global_position
		== game.xiaocong_fate_interlude.get_player_spawn_position(0),
		"单人进入 Fate 房间必须由 Flow 直接传送。"
	)
	flow.restore_authoritative_players_from_room()
	_expect(
		game.player.global_position == roster.get_world_spawn_position(0),
		"单人离开 Fate 房间必须恢复 Roster 出生位置。"
	)

	_stop_audio_recursive(game)
	current_scene = null
	game.queue_free()
	for _cleanup_frame in range(4):
		await process_frame
		await physics_frame


func _read_text(path: String) -> String:
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		failures.append("无法读取验证源码：%s" % path)
		return ""
	return file.get_as_text()


func _stop_audio_recursive(node: Node) -> void:
	var player_2d := node as AudioStreamPlayer2D
	if player_2d != null:
		player_2d.stop()
		player_2d.stream = null
	var player := node as AudioStreamPlayer
	if player != null:
		player.stop()
		player.stream = null
	for child in node.get_children():
		_stop_audio_recursive(child)


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
