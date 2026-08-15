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
	nonlethal.tree_exited.connect(
		game.enemy_coordinator.handle_wave_enemy_tree_exited.bind(
			nonlethal.get_instance_id()
		)
	)
	game.home_defense_coordinator.set_authoritative_base_health(
		BASIC_CONFIG.home_damage + 1,
		BASIC_CONFIG.home_damage + 1
	)
	game.home_defense_coordinator.clear_resolved_enemy_ids()
	game.home_defense_coordinator.on_enemy_reached_home(nonlethal, Vector2i.ZERO)
	# ESCAPED 在实体 tree_exited 时进入 DETACHED，波次完成不得早于离树。
	await process_frame
	await physics_frame
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
	lethal.tree_exited.connect(
		game.enemy_coordinator.handle_wave_enemy_tree_exited.bind(
			lethal.get_instance_id()
		)
	)
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
	await process_frame
	await physics_frame

	# Boss auxiliary 不推进 Boss 目标，但仍必须拥有唯一 ESCAPED 终结；
	# 该链覆盖 HomeDefense → wire → tree_exited，而不是手工预写账本。
	var auxiliary := BASIC_CONFIG.enemy_scene.instantiate() as Enemy
	game.enemy_container.add_child(auxiliary)
	auxiliary.setup(BASIC_CONFIG, game.player, game.grid_pathfinder)
	game.runtime_mode = CombatRuntimeBase.RuntimeMode.HOST_AUTHORITY
	game.campaign_coordinator.replace_flow_state_for_fixture(
		CombatFlowState.State.BOSS_ACTIVE,
		game.campaign_coordinator.bosses[0]
	)
	game.campaign_coordinator.reset_wave_progress(1, 1)
	game.enemy_coordinator.clear_queue()
	game.enemy_coordinator.clear_active_enemies()
	var auxiliary_id := auxiliary.get_instance_id()
	game.enemy_coordinator.register_external_enemy(
		auxiliary, WaveEnemyTerminalLedger.EnemyRole.AUXILIARY
	)
	auxiliary.tree_exited.connect(
		game.enemy_coordinator.handle_wave_enemy_tree_exited.bind(auxiliary_id)
	)
	var escaped_net_ids: Array[int] = []
	var removed_net_ids: Array[int] = []
	game.multiplayer_gateway.enemy_escaped.connect(
		func(net_id: int) -> void: escaped_net_ids.append(net_id)
	)
	game.multiplayer_gateway.enemy_removed.connect(
		func(net_id: int) -> void: removed_net_ids.append(net_id)
	)
	game.register_network_enemy(77, auxiliary)
	game.home_defense_coordinator.set_authoritative_base_health(
		BASIC_CONFIG.home_damage + 1,
		BASIC_CONFIG.home_damage + 1
	)
	game.home_defense_coordinator.clear_resolved_enemy_ids()
	game.home_defense_coordinator.on_enemy_reached_home(
		auxiliary, Vector2i.ZERO
	)
	await process_frame
	await physics_frame
	var terminal_ledger := game.campaign_coordinator.wave_enemy_terminal_ledger
	var auxiliary_terminal_reason := terminal_ledger.get_terminal_reason(
		auxiliary_id
	)
	_expect(
		escaped_net_ids == [77]
		and removed_net_ids.is_empty()
		and auxiliary_terminal_reason
		== CombatTypes.EnemyTerminalReason.ESCAPED,
		"Boss auxiliary 到家必须只广播一次 ESCAPED，离树不得再补 REMOVED。"
	)
	_expect(
		game.campaign_coordinator.current_wave_escaped == 0
		and game.campaign_coordinator.wave_state
		== CombatFlowState.State.BOSS_ACTIVE,
		"Boss auxiliary 的终结原因不得污染 objective 聚合或完成 Boss 步骤。"
	)

	current_scene = null
	game.queue_free()
	for _cleanup in range(6):
		await process_frame
