extends SceneTree

const TOWER_SCENE := preload(
	"res://scene/game_modes/tower_defense/tower_defense_game.tscn"
)
const ENEMY_CONFIG := preload("res://resources/config/enemies/slime.tres")
const EXPECTED_NORMAL_WAVE_ENEMY_COUNT := 63
const EXPECTED_ROBOT_IDS := [
	"combat_robot",
	"combat_robot_elite",
	"combat_robot_gunner",
	"combat_robot_gunner_elite",
	"combat_robot_drone_operator",
	"combat_robot_drone_operator_elite",
	"combat_robot_shield_bearer",
	"combat_robot_shield_bearer_elite",
	"combat_robot_ninja",
	"combat_robot_ninja_elite",
	"combat_robot_main_battle_elite",
]

var failures: Array[String] = []


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	var game := TOWER_SCENE.instantiate() as TowerDefenseGame
	game.auto_start_waves = false

	root.add_child(game)
	current_scene = game
	_expect(game.enemy_coordinator.is_bound(), "EnemyCoordinator 强类型运行时依赖未完整绑定。")
	await process_frame

	game.enemy_coordinator.pending_enemy_config_index = 11
	game.enemy_coordinator.next_multiplayer_enemy_net_id = 47
	game.enemy_coordinator.enemy_retarget_cursor = 9
	_expect(game.enemy_coordinator.pending_enemy_config_index == 11, "queue cursor 未由 EnemyCoordinator 持有。")
	_expect(game.enemy_coordinator.next_multiplayer_enemy_net_id == 47, "net id 未由 EnemyCoordinator 持有。")
	_expect(game.enemy_coordinator.enemy_retarget_cursor == 9, "retarget cursor 未由 EnemyCoordinator 持有。")

	await _exercise_full_catalog_tower_spawn(game)
	game.enemy_coordinator.next_multiplayer_enemy_net_id = 47
	await _exercise_spawn_terminal_chain(game)

	current_scene = null
	game.queue_free()
	for _cleanup_frame in range(6):
		await process_frame
		await physics_frame
	if failures.is_empty():
		print("TOWER_DEFENSE_ENEMY_COORDINATOR_FACADE_SMOKE_TEST_OK")
		quit()
		return
	for failure in failures:
		push_error(failure)
	quit(1)


func _exercise_full_catalog_tower_spawn(game: TowerDefenseGame) -> void:
	game.runtime_mode = CombatRuntimeBase.RuntimeMode.HOST_AUTHORITY
	game.campaign_coordinator.replace_flow_state_for_fixture(
		CombatFlowState.State.INTERMISSION
	)
	game.enemy_coordinator.clear_queue()
	game.enemy_coordinator.clear_active_enemies()
	game.enemy_coordinator.clear_hud_enemies()
	game.enemy_coordinator.active_wave_spawn_points.clear()
	game.enemy_coordinator.active_wave_spawn_points.append_array(
		game.enemy_coordinator.enemy_spawn_points
	)
	game.campaign_coordinator.reset_wave_progress(
		EXPECTED_NORMAL_WAVE_ENEMY_COUNT
	)
	_expect(game.tower_grid_pathfinder.is_built, "塔防正式 GridPathfinder 尚未建立。")
	_expect(
		not game.enemy_coordinator.active_wave_spawn_points.is_empty(),
		"塔防正式场景没有可用的敌人出生点。"
	)
	var home_targets := game.get_home_objective_targets()
	_expect(not home_targets.is_empty(), "塔防正式场景没有可用的 Home 目标。")
	if (
		not game.tower_grid_pathfinder.is_built
		or game.enemy_coordinator.active_wave_spawn_points.is_empty()
		or home_targets.is_empty()
	):
		return

	var normal_wave_enemy_count := 0
	var robot_ids_seen := {}
	var validated_navigation_profiles := {}
	for entry in EnemyCodexRegistry.get_all_entries():
		if entry.rank == EnemyCodexEntryConfig.Rank.BOSS:
			continue
		normal_wave_enemy_count += 1
		var entry_id := String(entry.entry_id)
		if entry_id in EXPECTED_ROBOT_IDS:
			robot_ids_seen[entry_id] = true
		var enemy_config := entry.enemy_config
		_expect(enemy_config != null, "图鉴敌人缺少 EnemyConfig：%s" % entry_id)
		if enemy_config == null or enemy_config.enemy_scene == null:
			continue

		var probe := enemy_config.enemy_scene.instantiate() as Enemy
		_expect(probe != null, "敌人场景无法实例化为 Enemy：%s" % entry_id)
		if probe == null:
			continue
		var body_half_extents := probe.get_configured_body_collision_half_extents()
		probe.free()
		_expect(body_half_extents.x > 0.0 and body_half_extents.y > 0.0, "敌人体型无效：%s" % entry_id)
		var profile_key := "%d:%d:%d" % [
			ceili(body_half_extents.x),
			ceili(body_half_extents.y),
			enemy_config.terrain_traversal_types,
		]
		if not validated_navigation_profiles.has(profile_key):
			validated_navigation_profiles[profile_key] = true
			for spawn_point in game.enemy_coordinator.enemy_spawn_points:
				var has_home_path := false
				for home_target in home_targets:
					var path := game.tower_grid_pathfinder.get_global_path(
						spawn_point.global_position,
						home_target.global_position,
						body_half_extents,
						enemy_config.terrain_traversal_types
					)
					if not path.is_empty():
						has_home_path = true
						break
				_expect(
					has_home_path,
					"敌人体型无法从出生点 %s 到达任一 Home：%s" % [
						spawn_point.name,
						entry_id,
					]
				)

		var expected_net_id := game.enemy_coordinator.next_multiplayer_enemy_net_id
		var spawned := game.enemy_coordinator.try_spawn_enemy(enemy_config)
		_expect(spawned, "塔防 EnemyCoordinator 无法生成敌人：%s" % entry_id)
		var spawned_enemy := game.enemy_coordinator.get_enemy(expected_net_id)
		_expect(spawned_enemy != null, "塔防敌人未进入多人稳定索引：%s" % entry_id)
		if spawned_enemy != null:
			spawned_enemy.process_mode = Node.PROCESS_MODE_DISABLED
			_expect(spawned_enemy.config == enemy_config, "生成敌人配置发生漂移：%s" % entry_id)
			game.campaign_coordinator.try_resolve_wave_enemy(
				spawned_enemy.get_instance_id(),
				CombatTypes.EnemyTerminalReason.REMOVED
			)
			spawned_enemy.queue_free()
			await process_frame
			await physics_frame
			_expect(
				game.enemy_coordinator.get_enemy(expected_net_id) == null,
				"敌人退出后多人索引残留：%s" % entry_id
			)

	_expect(
		normal_wave_enemy_count == EXPECTED_NORMAL_WAVE_ENEMY_COUNT,
		"塔防可配置敌人必须完整覆盖63个非Boss图鉴条目。"
	)
	for robot_id in EXPECTED_ROBOT_IDS:
		_expect(robot_ids_seen.has(robot_id), "塔防可配置敌人缺少机器人：%s" % robot_id)
	game.enemy_coordinator.clear_active_enemies()
	game.enemy_coordinator.clear_hud_enemies()
	game.enemy_coordinator.active_wave_spawn_points.clear()


func _exercise_spawn_terminal_chain(game: TowerDefenseGame) -> void:
	var default_completion := Callable(
		game.campaign_coordinator,
		"complete_current_step"
	)
	if game.enemy_coordinator.wave_completed.is_connected(default_completion):
		game.enemy_coordinator.wave_completed.disconnect(default_completion)
	var completed_count := [0]
	game.enemy_coordinator.wave_completed.connect(
		func() -> void: completed_count[0] += 1
	)
	var spawned_ids: Array[int] = []
	var defeated_ids: Array[int] = []
	var removed_ids: Array[int] = []
	game.multiplayer_gateway.enemy_spawned.connect(
		func(net_id: int, _config: EnemyConfig, _position: Vector2) -> void:
			spawned_ids.append(net_id)
	)
	game.multiplayer_gateway.enemy_defeated.connect(
		func(net_id: int, _position: Vector2) -> void:
			defeated_ids.append(net_id)
	)
	game.multiplayer_gateway.enemy_removed.connect(
		func(net_id: int) -> void: removed_ids.append(net_id)
	)

	game.runtime_mode = CombatRuntimeBase.RuntimeMode.HOST_AUTHORITY
	game.campaign_coordinator.replace_flow_state_for_fixture(
		CombatFlowState.State.WAVE_ACTIVE
	)
	game.campaign_coordinator.current_wave_index = 2
	game.campaign_coordinator.reset_wave_progress(1, 1)
	game.enemy_coordinator.clear_queue()
	game.enemy_coordinator.clear_active_enemies()
	game.enemy_coordinator.clear_hud_enemies()
	game.enemy_coordinator.active_wave_spawn_points.clear()
	if game.enemy_coordinator.enemy_spawn_points.is_empty():
		_expect(false, "正式场景没有可用的敌人出生点。")
		return
	game.enemy_coordinator.active_wave_spawn_points.append(
		game.enemy_coordinator.enemy_spawn_points[0]
	)

	var spawned := game.enemy_coordinator.try_spawn_enemy(ENEMY_CONFIG, 9)
	_expect(spawned, "EnemyCoordinator 未能完成普通波次敌人实例化。")
	_expect(spawned_ids == [47], "出生广播或稳定 net id 顺序发生变化。")
	var enemy := game.get_network_enemy(47)
	_expect(enemy != null, "实例化敌人未注册到多人索引。")
	if enemy == null:
		return
	_expect(game.enemy_coordinator.has_active_enemy(enemy.get_instance_id()), "实例化敌人未进入 active 集合。")
	_expect(game.enemy_coordinator.hud_enemy_count() == 1, "实例化敌人未进入 HUD 存活集合。")

	enemy.defeated.emit(enemy)
	enemy.defeated.emit(enemy)
	_expect(defeated_ids == [47], "击败广播未严格复用出生 net id。")
	_expect(
		game.campaign_coordinator.current_wave_defeated == 1,
		"击败计数未写入 Campaign 唯一状态。"
	)
	_expect(
		game.campaign_coordinator.current_wave_resolved == 1,
		"重复 defeated 信号不得重复写入 Campaign 已结算计数。"
	)
	var enemy_instance_id := enemy.get_instance_id()
	enemy.queue_free()
	await process_frame
	await physics_frame
	_expect(removed_ids == [47], "tree exit 未产生唯一 enemy_removed 终止事件。")
	_expect(not game.has_network_enemy(47), "tree exit 后 net→enemy 索引残留。")
	_expect(game.get_network_enemy_net_id_by_instance_id(enemy_instance_id) == 0, "tree exit 后 instance→net 索引残留。")
	_expect(game.enemy_coordinator.hud_enemy_count() == 0, "tree exit 后 HUD 存活集合残留。")
	_expect(completed_count[0] == 1, "波次完成判定应且只应触发一次。")


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
