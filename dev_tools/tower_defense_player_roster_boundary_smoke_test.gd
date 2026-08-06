extends SceneTree

const TOWER_SCENE := preload(
	"res://scene/game_modes/tower_defense/tower_defense_game.tscn"
)

var failures: Array[String] = []


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	await _test_host_roster_and_snapshot_parity()
	await _test_singleplayer_death_and_tango_paths()
	_test_tree_less_fixture_facade()
	_test_source_boundary()
	await process_frame
	await process_frame
	if failures.is_empty():
		print("TOWER_DEFENSE_PLAYER_ROSTER_BOUNDARY_SMOKE_TEST_OK")
		call_deferred("_finish", 0)
		return
	print("TOWER_DEFENSE_PLAYER_ROSTER_BOUNDARY_SMOKE_TEST_FAILED count=%d" % failures.size())
	for failure in failures:
		print(" - %s" % failure)
	call_deferred("_finish", 1)


func _finish(exit_code: int) -> void:
	quit(exit_code)


func _test_host_roster_and_snapshot_parity() -> void:
	var game := TOWER_SCENE.instantiate() as TowerDefenseGame
	_expect(game != null, "塔防场景必须实例化为 TowerDefenseGame。")
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
	) as TowerDefensePlayerRosterCoordinator
	_expect(roster != null, "塔防场景必须静态挂载玩家编排节点。")
	_expect(roster != null and roster.is_bound(), "塔防玩家编排依赖必须完整绑定。")
	_expect(
		roster != null and roster.starting_package_granted,
		"多人房主的原子起步包必须由玩家编排完成。"
	)
	_expect(_peer_ids(game.peer_players) == [1, 2, 3], "塔防玩家必须按 peer ID 排序出生。")
	_expect(game.player == game.get_player_for_peer(2), "塔防必须选择本地 peer 玩家。")
	var expected_names := game.multiplayer_player_names.duplicate()
	var expected_character_ids := game.multiplayer_player_character_ids.duplicate()
	roster.configure_roster(
		game.multiplayer_player_names,
		game.multiplayer_player_character_ids
	)
	_expect(
		game.multiplayer_player_names == expected_names
		and game.multiplayer_player_character_ids == expected_character_ids,
		"名单配置必须支持共享字典作为 self-alias 输入。"
	)
	var legacy_states := _legacy_collect(game.peer_players)
	var coordinator_states := game.collect_player_snapshot_states()
	_expect(
		_state_hash(legacy_states) == _state_hash(coordinator_states),
		"提取协调器前后的玩家快照轨迹哈希必须严格一致。"
	)
	_expect(
		_peer_state_ids(coordinator_states) == [1, 2, 3],
		"玩家快照必须保留既有 Dictionary 插入顺序。"
	)

	roster.reset_wave_death_counts()
	var delays: Array[int] = []
	for _index in range(5):
		delays.append(roundi(
			game.tower_multiplayer_mode_adapter.consume_next_player_respawn_delay(0)
		))
	_expect(delays == [5, 10, 15, 20, 20], "塔防复活延迟序列必须保持不变。")
	game.singleplayer_respawn_time_left = 7.0
	_expect(
		is_equal_approx(roster.singleplayer_respawn_time_left, 7.0),
		"根脚本复活时间 property 必须写穿到协调器真源。"
	)
	roster.singleplayer_respawn_time_left = 3.0
	_expect(
		is_equal_approx(game.singleplayer_respawn_time_left, 3.0),
		"根脚本复活时间 property 必须读取协调器真源。"
	)

	game.remove_multiplayer_player(3)
	_expect(
		not game.peer_players.has(3)
		and not game.multiplayer_spawn_slot_indices.has(3)
		and not game.multiplayer_player_names.has(3),
		"移除玩家必须同步清理实体、出生槽与名单。"
	)
	var restored := game.restore_multiplayer_player(
		3, 4, "Restored", &"tango", null, 2, {"wave_death_count": 2}
	)
	_expect(restored != null, "塔防必须能恢复断线玩家。")
	_expect(
		game.multiplayer_spawn_slot_indices.get(4) == 2
		and game.player_wave_death_counts.get(4) == 2,
		"恢复玩家必须保留出生槽和波次死亡次数。"
	)
	legacy_states.clear()
	coordinator_states.clear()
	game.queue_free()
	await process_frame


func _test_singleplayer_death_and_tango_paths() -> void:
	var game := TOWER_SCENE.instantiate() as TowerDefenseGame
	game.auto_start_waves = false
	root.add_child(game)
	await process_frame
	await process_frame
	var roster := game.get_node("PlayerRosterCoordinator") as TowerDefensePlayerRosterCoordinator
	_expect(
		roster.starting_package_granted,
		"单人原子起步包必须由玩家编排完成。"
	)
	roster.reset_wave_death_counts()
	game.player.died.emit()
	_expect(
		game.player_wave_death_counts.get(0) == 1
		and is_equal_approx(game.singleplayer_respawn_time_left, 5.0),
		"一次单人死亡信号必须只消费一次五秒复活档位。"
	)

	var tango := PlayerCharacterRegistry.instantiate_character(&"tango") as PlayerTango
	_expect(tango != null, "Tango 角色必须可由注册表实例化。")
	if tango != null:
		game.add_child(tango)
		game.bind_player_runtime_context(tango)
		game.player = tango
		game.runtime_mode = CombatRuntimeBase.RuntimeMode.SINGLEPLAYER
		roster.local_player = tango
		roster.set_runtime_identity(game.runtime_mode, game.multiplayer_local_peer_id)
		_expect(
			roster.request_tango_charge_started(Vector2.RIGHT)
			and roster.request_tango_charge_released(Vector2.RIGHT),
			"Tango 的 started/released 必须走强类型权威路径。"
		)
		_expect(
			roster.request_tango_charge_started(Vector2.UP),
			"Tango 必须能再次开始权威蓄力。"
		)
		game.runtime_mode = CombatRuntimeBase.RuntimeMode.CLIENT_VIEW
		roster.set_runtime_identity(game.runtime_mode, game.multiplayer_local_peer_id)
		_expect(
			not roster.request_tango_charge_released(Vector2.UP)
			and not roster.request_tango_charge_cancelled(),
			"蓄力期间切换为客户端观察模式后 release/cancel 必须被拒绝。"
		)
		game.runtime_mode = CombatRuntimeBase.RuntimeMode.SINGLEPLAYER
		roster.set_runtime_identity(game.runtime_mode, game.multiplayer_local_peer_id)
		_expect(
			roster.request_tango_charge_cancelled(),
			"Tango 的 started/cancelled 必须走强类型权威路径。"
		)
	game.queue_free()
	await process_frame


func _test_tree_less_fixture_facade() -> void:
	var game := TowerDefenseGame.new()
	var player_instance := PlayerCharacterRegistry.instantiate_character(
		&"weishidaier"
	) as Player
	game.peer_players = {7: player_instance}
	_expect(
		game.get_player_for_peer(7) == player_instance,
		"裸 TowerDefenseGame fixture 必须继续支持权威传送玩家查找。"
	)
	var states := game.collect_player_snapshot_states()
	_expect(
		states.size() == 1 and states[0].peer_id == 7,
		"裸 TowerDefenseGame fixture 必须继续支持快照收集。"
	)
	states.clear()
	player_instance.free()
	game.free()


func _test_source_boundary() -> void:
	var source := FileAccess.get_file_as_string(
		"res://scene/game_modes/tower_defense/player/tower_defense_player_roster_coordinator.gd"
	)
	var scene_source := FileAccess.get_file_as_string(
		"res://scene/game_modes/tower_defense/tower_defense_game.tscn"
	)
	_expect(not source.contains("current_scene"), "玩家编排不得猜测 current_scene。")
	_expect(not source.contains("has_method("), "玩家编排不得动态探测网络或玩法能力。")
	_expect(not source.contains(".call("), "玩家编排不得动态调用运行时能力。")
	_expect(not source.contains("get_parent("), "玩家编排不得从父节点反查依赖。")
	_expect(not source.contains("get_node("), "玩家编排不得自行解析兄弟节点。")
	_expect(not source.contains("get_node_or_null("), "玩家编排不得容错猜测兄弟节点。")
	_expect(not source.contains("NodePath(\"../"), "玩家编排不得持有上行 NodePath。")
	_expect(not source.contains("StandardGame"), "塔防玩家编排不得反向依赖普通模式。")
	_expect(not source.contains("RogueCombatGame"), "塔防玩家编排不得反向依赖肉鸽模式。")
	var root_source := FileAccess.get_file_as_string(
		"res://scene/game_modes/tower_defense/tower_defense_game.gd"
	)
	_expect(
		source.contains("func grant_starting_package(")
		and source.contains("func get_selected_singleplayer_character_id()")
		and not root_source.contains("can_add_item_counts_for_peer(")
		and not root_source.contains("func request_tango_charge_started(")
		and not root_source.contains("func consume_next_player_respawn_delay("),
		"角色、蓄力与复活事务必须由玩家编排或多人适配器直接拥有。"
	)
	_expect(
		scene_source.contains("[node name=\"PlayerRosterCoordinator\" parent=\".\" instance="),
		"玩家编排必须由塔防 .tscn 静态实例化。"
	)


func _legacy_collect(peer_players: Dictionary) -> Array[SnapshotManager.PlayerState]:
	var states: Array[SnapshotManager.PlayerState] = []
	for peer_id_variant in peer_players:
		var peer_id := int(peer_id_variant)
		var player_instance := peer_players[peer_id] as Player
		if player_instance == null or not is_instance_valid(player_instance):
			continue
		var state := SnapshotManager.PlayerState.new()
		state.peer_id = peer_id
		state.character_id = player_instance.get_character_id()
		state.position = player_instance.global_position
		state.velocity = player_instance.velocity
		state.facing = player_instance.get_multiplayer_facing_id()
		state.anim_state = player_instance.get_multiplayer_anim_state()
		state.current_health = player_instance.current_health
		state.max_health = player_instance.max_health
		state.current_xirang = player_instance.current_xirang
		state.is_dead = player_instance.is_dead
		state.invincibility_time_left = player_instance.invincibility_time_left
		state.skill1_unlocked = player_instance.skill1_unlocked
		state.skill1_charge = player_instance.skill1_charge
		state.skill1_charge_duration = player_instance.skill1_charge_duration
		state.skill1_upgrade_level = player_instance.skill1_upgrade_level
		state.form_mode = player_instance.get_multiplayer_form_mode()
		state.shot_pattern = player_instance.get_multiplayer_shot_pattern()
		state.ammo_capacity = player_instance.get_multiplayer_ammo_capacity()
		state.current_ammo = player_instance.get_multiplayer_current_ammo()
		state.is_reloading = player_instance.get_multiplayer_is_reloading()
		state.reload_progress = player_instance.get_multiplayer_reload_progress()
		state.primary_cooldown_ratio = clampf(
			player_instance.get_primary_cooldown_ratio(), 0.0, 1.0
		)
		state.effective_move_speed_multiplier = (
			player_instance.get_authoritative_move_speed_multiplier()
		)
		states.append(state)
	return states


func _state_hash(states: Array[SnapshotManager.PlayerState]) -> int:
	var values: Array = []
	for state in states:
		values.append([
			state.peer_id, state.character_id, state.position, state.velocity,
			state.facing, state.anim_state, state.current_health, state.max_health,
			state.current_xirang, state.is_dead, state.invincibility_time_left,
			state.skill1_unlocked, state.skill1_charge, state.skill1_charge_duration,
			state.skill1_upgrade_level, state.form_mode, state.shot_pattern,
			state.ammo_capacity, state.current_ammo, state.is_reloading,
			state.reload_progress, state.primary_cooldown_ratio,
			state.effective_move_speed_multiplier,
		])
	return hash(values)


func _peer_ids(players: Dictionary) -> Array[int]:
	var result: Array[int] = []
	for peer_id_variant in players:
		result.append(int(peer_id_variant))
	return result


func _peer_state_ids(states: Array[SnapshotManager.PlayerState]) -> Array[int]:
	var result: Array[int] = []
	for state in states:
		result.append(state.peer_id)
	return result
func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
