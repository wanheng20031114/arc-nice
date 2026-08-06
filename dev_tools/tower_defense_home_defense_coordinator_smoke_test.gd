extends SceneTree

const TOWER_SCENE := preload("res://scene/game_modes/tower_defense/tower_defense_game.tscn")
const BASIC_CONFIG := preload("res://resources/config/enemies/slime.tres")

var failures: Array[String] = []
var flow_state := CombatFlowState.State.WAVE_ACTIVE
var active_enemy_ids: Dictionary = {}
var active_boss: Enemy = null
var events: Array[StringName] = []


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	var coordinator := TowerDefenseHomeDefenseCoordinator.new()
	root.add_child(coordinator)
	coordinator._runtime_mode = CombatRuntimeBase.RuntimeMode.SINGLEPLAYER
	coordinator._flow_state_query = func() -> int: return flow_state
	coordinator._active_enemy_query = func(enemy_id: int) -> bool:
		return active_enemy_ids.has(enemy_id)
	coordinator._active_boss_query = func() -> Enemy: return active_boss
	coordinator.enemy_escaped.connect(
		func(_enemy: Enemy, _wave: bool, _boss: bool) -> void: events.append(&"enemy_escaped")
	)
	coordinator.base_health_changed.connect(
		func(_current: int, _maximum: int, _revision: int) -> void:
			events.append(&"base_health_changed")
	)
	coordinator.base_defeated.connect(func() -> void:
		events.append(&"base_defeated")
		flow_state = CombatFlowState.State.DEFEAT
	)
	coordinator.wave_escape_finished.connect(
		func() -> void: events.append(&"wave_escape_finished")
	)
	coordinator.boss_escaped.connect(func() -> void: events.append(&"boss_escaped"))

	var config := EnemyConfig.new()
	config.home_damage = 1
	var nonlethal := Enemy.new()
	nonlethal.config = config
	active_enemy_ids[nonlethal.get_instance_id()] = true
	coordinator.current_base_health = 2
	coordinator.maximum_base_health = 2
	coordinator.on_enemy_reached_home(nonlethal, Vector2i.ZERO)
	_expect(
		events == [&"enemy_escaped", &"base_health_changed", &"wave_escape_finished"],
		"非致死逃逸必须按清理、扣血、波次收尾排序。"
	)
	coordinator.on_enemy_reached_home(nonlethal, Vector2i.ONE)
	_expect(events.size() == 3, "重复 gate 事件不得再次产生任何信号。")
	nonlethal.free()

	events.clear()
	coordinator.clear_resolved_enemy_ids()
	flow_state = CombatFlowState.State.WAVE_ACTIVE
	var lethal := Enemy.new()
	lethal.config = config
	active_enemy_ids[lethal.get_instance_id()] = true
	coordinator.current_base_health = 1
	coordinator.maximum_base_health = 1
	coordinator.on_enemy_reached_home(lethal, Vector2i.ZERO)
	_expect(
		events == [
			&"enemy_escaped",
			&"base_health_changed",
			&"base_defeated",
			&"wave_escape_finished",
		],
		"致死逃逸必须先进入失败，再允许波次完成检查。"
	)
	lethal.free()

	events.clear()
	coordinator.clear_resolved_enemy_ids()
	flow_state = CombatFlowState.State.BOSS_ACTIVE
	var boss := Enemy.new()
	boss.config = config
	active_boss = boss
	active_enemy_ids[boss.get_instance_id()] = true
	coordinator.current_base_health = 250
	coordinator.maximum_base_health = 250
	coordinator.on_enemy_reached_home(boss, Vector2i.ZERO)
	_expect(events.has(&"base_defeated"), "Boss 逃逸必须摧毁完整基地。")
	_expect(not events.has(&"boss_escaped"), "基地已失败时不得再完成 Boss 步骤。")
	boss.free()

	coordinator.queue_free()
	await process_frame
	await _verify_real_runtime_escape_ordering()
	if failures.is_empty():
		print("TOWER_DEFENSE_HOME_DEFENSE_COORDINATOR_SMOKE_TEST_OK")
		quit()
		return
	for failure in failures:
		push_error(failure)
	quit(1)


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)


func _verify_real_runtime_escape_ordering() -> void:
	var game := TOWER_SCENE.instantiate() as TowerDefenseGame
	game.auto_start_waves = false
	root.add_child(game)
	current_scene = game
	await process_frame
	await physics_frame
	game.home_defense_coordinator._run_state = null

	var nonlethal := BASIC_CONFIG.enemy_scene.instantiate() as Enemy
	game.enemy_container.add_child(nonlethal)
	nonlethal.setup(BASIC_CONFIG, game.player, game.grid_pathfinder)
	game.wave_state = CombatFlowState.State.WAVE_ACTIVE
	game.current_flow_step = game.waves[0]
	game.current_wave_total = 1
	game.current_wave_spawned = 1
	game.current_wave_defeated = 0
	game.current_wave_escaped = 0
	game.current_wave_resolved = 0
	game.call("_clear_pending_enemy_spawn_queue")
	game.active_wave_enemy_ids.clear()
	game.active_wave_enemy_ids[nonlethal.get_instance_id()] = true
	game.current_base_health = BASIC_CONFIG.home_damage + 1
	game.maximum_base_health = BASIC_CONFIG.home_damage + 1
	game.home_defense_coordinator.clear_resolved_enemy_ids()
	game.call("_on_enemy_reached_home", nonlethal, Vector2i.ZERO)
	_expect(
		game.wave_state != CombatFlowState.State.WAVE_ACTIVE
		and game.wave_state != CombatFlowState.State.DEFEAT,
		"非致死最后敌人逃逸必须完成波次且不得失败。"
	)

	var lethal_order: Array[StringName] = []
	game.home_defense_coordinator.base_defeated.connect(
		func() -> void: lethal_order.append(&"defeat")
	)
	game.home_defense_coordinator.wave_escape_finished.connect(
		func() -> void: lethal_order.append(&"wave_finish")
	)
	var lethal := BASIC_CONFIG.enemy_scene.instantiate() as Enemy
	game.enemy_container.add_child(lethal)
	lethal.setup(BASIC_CONFIG, game.player, game.grid_pathfinder)
	game.wave_state = CombatFlowState.State.WAVE_ACTIVE
	game.current_flow_step = game.waves[0]
	game.current_wave_total = 1
	game.current_wave_spawned = 1
	game.current_wave_defeated = 0
	game.current_wave_escaped = 0
	game.current_wave_resolved = 0
	game.call("_clear_pending_enemy_spawn_queue")
	game.active_wave_enemy_ids.clear()
	game.active_wave_enemy_ids[lethal.get_instance_id()] = true
	game.current_base_health = BASIC_CONFIG.home_damage
	game.maximum_base_health = BASIC_CONFIG.home_damage
	game.home_defense_coordinator.clear_resolved_enemy_ids()
	game.call("_on_enemy_reached_home", lethal, Vector2i.ZERO)
	_expect(game.wave_state == CombatFlowState.State.DEFEAT, "致死最后逃逸必须直接进入失败。")
	_expect(
		lethal_order == [&"defeat", &"wave_finish"],
		"致死最后逃逸必须先发出失败，再运行不会转胜的波次完成检查。"
	)

	current_scene = null
	game.queue_free()
	for _cleanup in range(6):
		await process_frame
