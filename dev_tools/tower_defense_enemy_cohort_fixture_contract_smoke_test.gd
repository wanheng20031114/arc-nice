extends SceneTree

const TOWER_SCENE := preload(
	"res://scene/game_modes/tower_defense/tower_defense_game.tscn"
)
const FORMAL_WAVE := preload(
	"res://resources/config/campaigns/tower_defense/formal/wave_01.tres"
)
const FIXTURE_ENEMY_COUNT := 12

var failures: Array[String] = []


func _init() -> void:
	call_deferred(&"_run")


func _run() -> void:
	var game := TOWER_SCENE.instantiate() as TowerDefenseGame
	game.auto_start_waves = false
	root.add_child(game)
	current_scene = game
	await process_frame
	await physics_frame

	game.runtime_mode = CombatRuntimeBase.RuntimeMode.HOST_AUTHORITY
	game.enemy_spawn_timer.stop()
	game.state_timer.stop()
	game.campaign_coordinator.current_flow_step = FORMAL_WAVE
	game.campaign_coordinator.wave_state = CombatFlowState.State.WAVE_ACTIVE
	game.enemy_coordinator.clear_queue()
	game.enemy_coordinator.clear_active_enemies()
	game.enemy_coordinator.clear_hud_alive_enemies()
	game.clear_network_enemy_registry()
	game.enemy_coordinator.next_multiplayer_enemy_net_id = 1
	game.campaign_coordinator.reset_wave_progress(FIXTURE_ENEMY_COUNT)

	var spawned_enemies: Array[Enemy] = []
	for enemy_index in range(FIXTURE_ENEMY_COUNT):
		var wave_entry := FORMAL_WAVE.enemy_entries[
			enemy_index % FORMAL_WAVE.enemy_entries.size()
		] as Resource
		var enemy_config := (
			wave_entry.get("enemy_config") as EnemyConfig
			if wave_entry != null
			else null
		)
		var enemy := (
			enemy_config.enemy_scene.instantiate() as Enemy
			if enemy_config != null and enemy_config.enemy_scene != null
			else null
		)
		_expect(enemy != null, "Formal fixture enemy scene must instantiate.")
		if enemy == null:
			continue
		game.enemy_container.add_child(enemy)
		enemy.global_position = Vector2(400.0 + enemy_index * 3.0, 320.0)
		enemy.setup(enemy_config, game.player, game.grid_pathfinder, game)
		game.enemy_coordinator.assign_enemy_targets(enemy, enemy.global_position)
		var enemy_id := enemy.get_instance_id()
		_expect(
			game.enemy_coordinator.register_external_enemy(enemy),
			"Formal fixture enemy must enter the real wave ledger."
		)
		enemy.defeated.connect(Callable(
			game.enemy_coordinator,
			&"_on_wave_enemy_defeated"
		))
		enemy.tree_exited.connect(
			game.enemy_coordinator.handle_wave_enemy_tree_exited.bind(enemy_id)
		)
		var net_id := game.enemy_coordinator.finalize_authoritative_enemy_spawn(
			enemy,
			enemy_config,
			enemy.global_position,
			false
		)
		_expect(
			net_id == enemy_index + 1,
			"Formal fixture must assign stable continuous production net ids."
		)
		enemy.set_authoritative_simulation_enabled(false)
		spawned_enemies.append(enemy)

	await process_frame
	await physics_frame
	_verify_registration_state(game, FIXTURE_ENEMY_COUNT, FIXTURE_ENEMY_COUNT, 0)

	if not spawned_enemies.is_empty():
		var terminal_enemy := spawned_enemies[0]
		terminal_enemy.defeated.emit(terminal_enemy)
		terminal_enemy.queue_free()
		await process_frame
		await physics_frame
		await process_frame
		_verify_registration_state(
			game,
			FIXTURE_ENEMY_COUNT - 1,
			FIXTURE_ENEMY_COUNT - 1,
			1
		)

	game.prepare_for_scene_teardown()
	current_scene = null
	game.queue_free()
	for _cleanup_frame in range(5):
		await process_frame
		await physics_frame

	if failures.is_empty():
		print("TOWER_DEFENSE_ENEMY_COHORT_FIXTURE_CONTRACT_SMOKE_TEST_OK")
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	quit(1)


func _verify_registration_state(
	game: TowerDefenseGame,
	expected_attached: int,
	expected_active: int,
	expected_defeated: int
) -> void:
	var ledger := game.campaign_coordinator.wave_enemy_terminal_ledger
	var snapshot := ledger.get_snapshot()
	var plant_metrics := game.enemy_coordinator.get_plant_objective_index_metrics()
	var network_ids := game.get_network_enemy_ids()
	network_ids.sort()
	var cross_store_count := 0
	for net_id in network_ids:
		var enemy := game.get_network_enemy(net_id)
		if (
			enemy != null
			and game.combat_target_index.enemies_by_net_id.get(net_id) == enemy
			and ledger.has_enemy(enemy.get_instance_id())
		):
			cross_store_count += 1
	_expect(
		game.runtime_mode == CombatRuntimeBase.RuntimeMode.HOST_AUTHORITY
		and game.campaign_coordinator.current_flow_step == FORMAL_WAVE,
		"Formal fixture must retain Host authority and the authored current flow step."
	)
	_expect(
		int(snapshot.get("total", -1)) == FIXTURE_ENEMY_COUNT
		and int(snapshot.get("spawned", -1)) == FIXTURE_ENEMY_COUNT
		and int(snapshot.get("defeated", -1)) == expected_defeated
		and ledger.get_active_enemy_count() == expected_active
		and ledger.get_attached_enemy_count() == expected_attached,
		"Formal fixture ledger counts must follow production terminal events."
	)
	_expect(
		game.get_network_enemy_count() == expected_attached
		and game.combat_target_index.enemies_by_net_id.size() == expected_attached
		and int(plant_metrics.get("tracked_enemies", -1)) == expected_attached
		and cross_store_count == expected_attached,
		"Network, CombatTargetIndex and PlantObjectiveEnemyIndex must remain aligned."
	)


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
