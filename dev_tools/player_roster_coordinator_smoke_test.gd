extends SceneTree

const STANDARD_SCENE := preload(
	"res://scene/game_modes/standard/standard_game.tscn"
)
const ROGUE_SCENE := preload(
	"res://scene/game_modes/rogue/combat/rogue_combat_game_01.tscn"
)

var failures: Array[String] = []


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	await _test_standard_roster()
	await _test_rogue_roster()
	_test_mode_source_boundaries()
	if failures.is_empty():
		print("PLAYER_ROSTER_COORDINATOR_SMOKE_TEST_OK")
		quit(0)
		return
	print("PLAYER_ROSTER_COORDINATOR_SMOKE_TEST_FAILED count=%d" % failures.size())
	for failure in failures:
		print(" - %s" % failure)
	quit(1)


func _test_standard_roster() -> void:
	var game := STANDARD_SCENE.instantiate() as StandardGame
	_expect(game != null, "普通模式场景必须实例化为 StandardGame。")
	if game == null:
		return
	game.auto_start_waves = false
	game.configure_multiplayer(
		CombatRuntimeBase.RuntimeMode.HOST_AUTHORITY,
		2,
		{3: "Third", 1: "Host", 2: "Local"},
		{3: &"tango", 1: &"weishidaier", 2: &"tango"}
	)
	root.add_child(game)
	await process_frame
	await process_frame
	var roster := game.get_node_or_null(
		"PlayerRosterCoordinator"
	) as StandardPlayerRosterCoordinator
	_expect(roster != null, "普通模式必须静态挂载独立玩家编排节点。")
	_expect(roster != null and roster.is_bound(), "普通模式玩家编排依赖必须完整绑定。")
	_expect(_peer_ids(game.peer_players) == [1, 2, 3], "普通模式玩家必须按 peer ID 排序出生。")
	_expect(game.player == game.get_player_for_peer(2), "普通模式必须选择本地 peer 玩家。")
	_expect(
		game.get_player_for_peer(3).get_character_id() == &"tango",
		"普通模式必须使用 peer 的权威角色 ID。"
	)

	var first_output := game.collect_player_snapshot_states()
	var first_state := first_output[0]
	first_state.sequence = 91
	first_state.health_revision = 37
	var second_output := game.collect_player_snapshot_states()
	_expect(is_same(first_output, second_output), "玩家快照输出数组必须按模式实例复用。")
	_expect(is_same(first_state, second_output[0]), "同一 peer 的玩家快照对象必须复用。")
	_expect(
		second_output[0].sequence == 0 and second_output[0].health_revision == 0,
		"复用快照必须重置广播层写入的序列与生命修订号。"
	)

	var removed_state := second_output[2]
	game.remove_multiplayer_player(3)
	var restored := game.restore_multiplayer_player(
		3,
		4,
		"Restored",
		&"tango",
		null,
		2
	)
	_expect(restored != null, "普通模式必须能恢复断线玩家。")
	_expect(
		restored != null
		and restored.position.is_equal_approx(
			(game.get_node("PlayerSpawn") as Marker2D).position
			+ roster.get_spawn_offset(2)
		),
		"恢复玩家必须保持原出生槽位偏移语义。"
	)
	_expect(
		game.multiplayer_player_names.get(4) == "Restored"
		and game.multiplayer_player_character_ids.get(4) == &"tango",
		"恢复玩家必须迁移名字与角色索引。"
	)
	var restored_output := game.collect_player_snapshot_states()
	var restored_state: SnapshotManager.PlayerState = null
	for state in restored_output:
		if state.peer_id == 4:
			restored_state = state
			break
	_expect(
		restored_state != null and not is_same(removed_state, restored_state),
		"断线 peer 的缓存对象不得污染重连后的新 peer。"
	)

	for peer_id in game.peer_players:
		var player_instance := game.peer_players[peer_id] as Player
		player_instance.is_dead = true
	roster.handle_multiplayer_player_died(1)
	game.wave_state = CombatFlowState.State.VICTORY
	await create_timer(0.3).timeout
	_expect(
		game.wave_state == CombatFlowState.State.VICTORY,
		"死亡宽限期内转为胜利后不得被迟到检查覆盖为失败。"
	)
	_expect(not roster.defeat_check_pending, "死亡宽限检查完成后必须清理 pending 状态。")
	game.queue_free()
	await process_frame


func _test_rogue_roster() -> void:
	var game := ROGUE_SCENE.instantiate() as RogueCombatGame
	_expect(game != null, "肉鸽作战场景必须实例化为 RogueCombatGame。")
	if game == null:
		return
	game.auto_start_waves = false
	game.configure_multiplayer(
		CombatRuntimeBase.RuntimeMode.CLIENT_VIEW,
		2,
		{3: "Third", 1: "Host", 2: "Local"},
		{3: &"weishidaier", 1: &"tango", 2: &"weishidaier"}
	)
	root.add_child(game)
	await process_frame
	await process_frame
	var roster := game.get_node_or_null(
		"PlayerRosterCoordinator"
	) as RoguePlayerRosterCoordinator
	_expect(roster != null, "肉鸽模式必须静态挂载独立玩家编排节点。")
	_expect(roster != null and roster.is_bound(), "肉鸽玩家编排依赖必须完整绑定。")
	_expect(_peer_ids(game.peer_players) == [1, 2, 3], "肉鸽玩家必须按 peer ID 排序出生。")
	_expect(game.player == game.get_player_for_peer(2), "肉鸽必须选择本地 peer 玩家。")
	_expect(
		game.get_player_for_peer(1).get_character_id() == &"tango",
		"肉鸽必须使用自身玩家编排的角色索引。"
	)
	var first_output := game.collect_player_snapshot_states()
	var first_state := first_output[0]
	var second_output := game.collect_player_snapshot_states()
	_expect(
		is_same(first_output, second_output) and is_same(first_state, second_output[0]),
		"肉鸽必须持有自身实例级玩家快照缓存。"
	)
	game.queue_free()
	await process_frame


func _test_mode_source_boundaries() -> void:
	var shared_source := FileAccess.get_file_as_string(
		"res://scene/combat/player/combat_player_roster_coordinator_base.gd"
	)
	var standard_source := FileAccess.get_file_as_string(
		"res://scene/game_modes/standard/player/standard_player_roster_coordinator.gd"
	)
	var rogue_source := FileAccess.get_file_as_string(
		"res://scene/game_modes/rogue/combat/player/rogue_player_roster_coordinator.gd"
	)
	var wave_source := FileAccess.get_file_as_string(
		"res://scene/combat/runtime/wave_combat_runtime_base.gd"
	)
	var rogue_flow_test_source := FileAccess.get_file_as_string(
		"res://dev_tools/rogue_combat_singleplayer_flow_smoke_test.gd"
	)
	_expect(
		standard_source.contains("extends CombatPlayerRosterCoordinatorBase")
		and rogue_source.contains("extends CombatPlayerRosterCoordinatorBase"),
		"普通与肉鸽玩家编排必须共用中性基类，只在子类保留模式差异。"
	)
	_expect(
		shared_source.contains("func configure_multiplayer_players()")
		and not standard_source.contains("func configure_multiplayer_players()")
		and not rogue_source.contains("func configure_multiplayer_players()"),
		"玩家出生、快照与生命周期编排不得在普通/肉鸽模式重复实现。"
	)
	_expect(not standard_source.contains("RoguePlayerRosterCoordinator"), "普通玩家编排不得引用肉鸽实现。")
	_expect(not rogue_source.contains("StandardPlayerRosterCoordinator"), "肉鸽玩家编排不得引用普通实现。")
	_expect(not wave_source.contains("PlayerCharacterRegistry"), "中性 Wave 运行时不得拥有角色实例化规则。")
	_expect(not wave_source.contains("multiplayer_player_names"), "中性 Wave 运行时不得拥有玩家名单。")
	_expect(not wave_source.contains("INITIAL_PLAYER_XIRANG"), "中性 Wave 运行时不得拥有模式初始资源。")
	_expect(
		not rogue_flow_test_source.contains("StandardGame.INITIAL_PLAYER_XIRANG"),
		"肉鸽玩家资源回归测试不得反向依赖普通模式常量。"
	)


func _peer_ids(peer_players: Dictionary) -> Array[int]:
	var result: Array[int] = []
	for peer_id_variant in peer_players:
		result.append(int(peer_id_variant))
	return result


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
