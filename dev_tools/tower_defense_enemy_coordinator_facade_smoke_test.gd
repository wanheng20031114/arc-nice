extends SceneTree

const TOWER_SCENE := preload(
	"res://scene/game_modes/tower_defense/tower_defense_game.tscn"
)
const ENEMY_CONFIG := preload("res://resources/config/enemies/slime.tres")

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
	game.campaign_coordinator.wave_state = CombatFlowState.State.WAVE_ACTIVE
	game.campaign_coordinator.current_wave_index = 2
	game.campaign_coordinator.current_wave_total = 1
	game.campaign_coordinator.current_wave_spawned = 1
	game.campaign_coordinator.current_wave_defeated = 0
	game.campaign_coordinator.current_wave_escaped = 0
	game.campaign_coordinator.current_wave_resolved = 0
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
	var enemy := game.multiplayer_enemies_by_net_id.get(47) as Enemy
	_expect(enemy != null, "实例化敌人未注册到多人索引。")
	if enemy == null:
		return
	_expect(game.enemy_coordinator.has_active_enemy(enemy.get_instance_id()), "实例化敌人未进入 active 集合。")
	_expect(game.enemy_coordinator.hud_enemy_count() == 1, "实例化敌人未进入 HUD 存活集合。")

	enemy.defeated.emit(enemy)
	_expect(defeated_ids == [47], "击败广播未严格复用出生 net id。")
	_expect(
		game.campaign_coordinator.current_wave_defeated == 1,
		"击败计数未写入 Campaign 唯一状态。"
	)
	_expect(
		game.campaign_coordinator.current_wave_resolved == 1,
		"已结算计数未写入 Campaign 唯一状态。"
	)
	var enemy_instance_id := enemy.get_instance_id()
	enemy.queue_free()
	await process_frame
	await physics_frame
	_expect(removed_ids == [47], "tree exit 未产生唯一 enemy_removed 终止事件。")
	_expect(not game.multiplayer_enemies_by_net_id.has(47), "tree exit 后 net→enemy 索引残留。")
	_expect(not game.multiplayer_enemy_ids_by_instance.has(enemy_instance_id), "tree exit 后 instance→net 索引残留。")
	_expect(game.enemy_coordinator.hud_enemy_count() == 0, "tree exit 后 HUD 存活集合残留。")
	_expect(completed_count[0] == 1, "波次完成判定应且只应触发一次。")


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
