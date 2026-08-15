extends SceneTree

const TOWER_SCENE := preload("res://scene/game_modes/tower_defense/tower_defense_game.tscn")
const BASIC_CONFIG := preload("res://resources/config/enemies/slime.tres")

var failures: Array[String] = []


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
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
	game.campaign_coordinator.replace_flow_state_for_fixture(
		CombatFlowState.State.WAVE_ACTIVE,
		game.campaign_coordinator.waves[0]
	)
	game.campaign_coordinator.reset_wave_progress(1, 1)
	game.enemy_coordinator.clear_queue()
	game.enemy_coordinator.clear_active_enemies()
	game.enemy_coordinator.register_external_enemy(nonlethal)
	game.home_defense_coordinator.set_authoritative_base_health(
		BASIC_CONFIG.home_damage + 1,
		BASIC_CONFIG.home_damage + 1
	)
	game.home_defense_coordinator.clear_resolved_enemy_ids()
	game.home_defense_coordinator.on_enemy_reached_home(nonlethal, Vector2i.ZERO)
	_expect(
		game.campaign_coordinator.wave_state != CombatFlowState.State.WAVE_ACTIVE
		and game.campaign_coordinator.wave_state != CombatFlowState.State.DEFEAT,
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
	game.campaign_coordinator.replace_flow_state_for_fixture(
		CombatFlowState.State.WAVE_ACTIVE,
		game.campaign_coordinator.waves[0]
	)
	game.campaign_coordinator.reset_wave_progress(1, 1)
	game.enemy_coordinator.clear_queue()
	game.enemy_coordinator.clear_active_enemies()
	game.enemy_coordinator.register_external_enemy(lethal)
	game.home_defense_coordinator.set_authoritative_base_health(
		BASIC_CONFIG.home_damage,
		BASIC_CONFIG.home_damage
	)
	game.home_defense_coordinator.clear_resolved_enemy_ids()
	game.home_defense_coordinator.on_enemy_reached_home(lethal, Vector2i.ZERO)
	_expect(
		game.campaign_coordinator.wave_state == CombatFlowState.State.DEFEAT,
		"致死最后逃逸必须直接进入失败。"
	)
	_expect(
		lethal_order == [&"defeat", &"wave_finish"],
		"致死最后逃逸必须先发出失败，再运行不会转胜的波次完成检查。"
	)

	current_scene = null
	game.queue_free()
	for _cleanup in range(6):
		await process_frame
