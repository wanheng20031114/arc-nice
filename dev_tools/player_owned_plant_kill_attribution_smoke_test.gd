extends SceneTree

## Stage-five economic acceptance: a real player-owned Agave is registered by
## PlantSystem and enters the same authoritative plant-damage adapter used by
## tower projectiles. The resulting lethal snapshot, wave-ledger commit, peer
## credit, reward and drop are checked as one transaction. A real hostile Enemy
## then kills a player-allied Enemy through its touch attack to prove that the
## wave lifecycle still advances without player-economy settlement.

const TOWER_SCENE := preload(
	"res://scene/game_modes/tower_defense/tower_defense_game.tscn"
)
const AGAVE_CONFIG := preload(
	"res://resources/config/plant_defense/agave_cannon.tres"
)
const ENEMY_CONFIG := preload(
	"res://resources/config/enemies/yuanshi_insect_basic.tres"
)
const DROP_CONFIG := preload(
	"res://resources/config/materials/material_sapling.tres"
)

const OWNER_PEER_ID := 42
const PLANT_NET_ID := 7701
const HOSTILE_ATTACKER_NET_ID := 8801
const PLAYER_KILL_REWARD := 13
const HOSTILE_KILL_REWARD := 17

var failures: Array[String] = []
var game: TowerDefenseGame = null


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	game = TOWER_SCENE.instantiate() as TowerDefenseGame
	if game == null:
		_fail("Tower-defense scene did not instantiate.")
		_finish()
		return
	game.auto_start_waves = false
	root.add_child(game)
	current_scene = game
	await process_frame
	await physics_frame
	await process_frame

	if game.runtime_mode != CombatRuntimeBase.RuntimeMode.SINGLEPLAYER:
		_fail("Plant attribution fixture must use authoritative single-player mode.")
	else:
		await _test_player_owned_plant_kill_transaction()
		await _test_hostile_enemy_kill_has_no_economy_credit()

	current_scene = null
	game.queue_free()
	for _cleanup_frame in range(6):
		await process_frame
		await physics_frame
	_finish()


func _test_player_owned_plant_kill_transaction() -> void:
	var owner := game.player
	if owner == null or not is_instance_valid(owner):
		_fail("Tower-defense runtime did not create its real player owner.")
		return
	owner.peer_id = OWNER_PEER_ID
	owner.set_controls_locked(true)
	owner.set_process(false)
	owner.set_physics_process(false)

	var anchors: Array[Vector2i] = game.plant_system.get_valid_anchors_for_player(
		AGAVE_CONFIG,
		owner
	)
	if anchors.is_empty():
		_fail("Real tower-defense map exposed no valid Agave placement anchor.")
		return
	var plant := game.plant_system.try_place_for_player(
		AGAVE_CONFIG,
		anchors[0],
		owner,
		PLANT_NET_ID
	) as AgaveCannon
	if plant == null:
		_fail("PlantSystem failed to register the player-owned Agave fixture.")
		return
	await create_timer(PlantDefense.CONSTRUCTION_DURATION_SECONDS + 0.08).timeout
	plant.attack_timer.stop()
	plant.idle_aim_timer.stop()
	plant.set_process(false)
	plant.set_physics_process(false)
	if (
		plant.owner_player != owner
		or int(plant.get_meta(&"net_id", 0)) != PLANT_NET_ID
		or game.plant_system.get_plant_by_net_id(PLANT_NET_ID) != plant
		or not plant.is_operational
	):
		_fail("Agave owner/net-id/operational registration did not converge.")
		return

	var adapter := (
		game.get_multiplayer_mode_adapter()
		as TowerDefenseMultiplayerModeAdapter
	)
	if adapter == null:
		_fail("Tower-defense runtime did not expose its production plant adapter.")
		return
	_prepare_wave_fixture()
	var reward_config := _make_enemy_config(1, PLAYER_KILL_REWARD, true)
	var target := _spawn_registered_wave_enemy(reward_config)
	if target == null:
		return
	var terminal_callback := Callable(
		game.enemy_coordinator,
		"_on_wave_enemy_defeated"
	)
	if not target.defeated.is_connected(terminal_callback):
		target.defeated.connect(terminal_callback)

	var expected_reward := PLAYER_KILL_REWARD
	if game.fate_coordinator.is_double_xirang_reward_active():
		expected_reward *= 2
	var player_xirang_before := owner.current_xirang
	var pickups_before := _count_pickups()
	var day_number := game.campaign_coordinator.get_day_number_for_wave(
		game.campaign_coordinator.current_wave_index + 1
	)
	var daily_before := int(
		game.campaign_coordinator.daily_xirang_rewards.get(day_number, 0)
	)
	var target_id := target.get_instance_id()
	var accepted := adapter.apply_authoritative_plant_enemy_damage(
		PLANT_NET_ID,
		target,
		1,
		Vector2.RIGHT,
		EnemyConfig.DamageType.PHYSICAL
	)
	var context := target.defeat_context
	var source := (
		context.source_snapshot
		if context != null
		else null
	) as DamageSourceSnapshot
	_expect(
		accepted
		and target.is_dead
		and context != null
		and source != null
		and source.source_faction_id == CombatRelationService.PLAYER_ALLIED
		and source.credit_peer_id == OWNER_PEER_ID
		and source.instigator_entity_id == PLANT_NET_ID
		and source.event_source_id == PLANT_NET_ID
		and source.source_type == &"plant_attack"
		and context.is_player_reward_eligible(),
		"Real Agave lethal must preserve owner peer and plant identity end to end."
	)
	_expect(
		game.campaign_coordinator.wave_enemy_terminal_ledger.get_terminal_reason(
			target_id
		) == CombatTypes.EnemyTerminalReason.DEFEATED
		and game._pending_xirang_kill_reward == expected_reward
		and int(game.campaign_coordinator.daily_xirang_rewards.get(
			day_number,
			0
		)) == daily_before + expected_reward,
		"Player-owned tower lethal must commit DEFEATED before one reward transaction."
	)

	# A second hit through the same production adapter must be rejected before it
	# can duplicate the reward accumulator, progression accounting or drop task.
	var duplicate_accepted := adapter.apply_authoritative_plant_enemy_damage(
		PLANT_NET_ID,
		target,
		1,
		Vector2.RIGHT,
		EnemyConfig.DamageType.PHYSICAL
	)
	_expect(
		not duplicate_accepted
		and game._pending_xirang_kill_reward == expected_reward
		and int(game.campaign_coordinator.daily_xirang_rewards.get(
			day_number,
			0
		)) == daily_before + expected_reward,
		"Repeated lethal admission must not enqueue reward accounting twice."
	)

	for _settlement_frame in range(4):
		await process_frame
	_expect(
		owner.current_xirang == player_xirang_before + expected_reward
		and game._pending_xirang_kill_reward == 0
		and _count_pickups() == pickups_before + 1,
		"Player-owned tower lethal must settle exactly one reward and one pickup."
	)
	var settled_xirang := owner.current_xirang
	var settled_pickups := _count_pickups()
	for _dedupe_frame in range(3):
		await process_frame
	_expect(
		owner.current_xirang == settled_xirang
		and _count_pickups() == settled_pickups,
		"Deferred settlement must remain single-shot after later frames."
	)


func _test_hostile_enemy_kill_has_no_economy_credit() -> void:
	_prepare_wave_fixture()
	var target_config := _make_enemy_config(1, HOSTILE_KILL_REWARD, true)
	var target := _spawn_registered_wave_enemy(target_config)
	if target == null:
		return
	if not target.set_combat_faction_id(
		CombatRelationService.PLAYER_ALLIED,
		1,
		true
	):
		_fail("Hostile-duel target could not enter the player-allied faction.")
		return
	var terminal_callback := Callable(
		game.enemy_coordinator,
		"_on_wave_enemy_defeated"
	)
	if not target.defeated.is_connected(terminal_callback):
		target.defeated.connect(terminal_callback)

	var attacker_config := _make_enemy_config(10, 0, false)
	attacker_config.attack_damage = 5
	var attacker := attacker_config.enemy_scene.instantiate() as Enemy
	if attacker == null:
		_fail("Hostile attacker scene did not instantiate.")
		return
	game.enemy_container.add_child(attacker)
	attacker.set_meta(&"net_id", HOSTILE_ATTACKER_NET_ID)
	attacker.setup(attacker_config, null, game.grid_pathfinder, game)
	attacker.set_authoritative_simulation_enabled(false)

	var owner := game.player
	var player_xirang_before := owner.current_xirang
	var pickups_before := _count_pickups()
	var day_number := game.campaign_coordinator.get_day_number_for_wave(
		game.campaign_coordinator.current_wave_index + 1
	)
	var daily_before := int(
		game.campaign_coordinator.daily_xirang_rewards.get(day_number, 0)
	)
	var target_id := target.get_instance_id()
	var hostile_request := DamageRequest.new(
		attacker_config.attack_damage,
		int(EnemyConfig.DamageType.PHYSICAL)
	)
	hostile_request.with_source_snapshot(attacker.create_damage_source_snapshot(
		HOSTILE_ATTACKER_NET_ID,
		&"enemy_attack"
	))
	var hostile_result := target.apply_combat_damage(hostile_request)
	var context := target.defeat_context
	var source := (
		context.source_snapshot
		if context != null
		else null
	) as DamageSourceSnapshot
	_expect(
		hostile_result.accepted
		and hostile_result.lethal
		and target.is_dead
		and context != null
		and source != null
		and source.source_faction_id == CombatRelationService.HOSTILE_WAVE
		and source.credit_peer_id == 0
		and source.instigator_entity_id == HOSTILE_ATTACKER_NET_ID
		and not context.is_player_reward_eligible()
		and game.campaign_coordinator.wave_enemy_terminal_ledger.get_terminal_reason(
			target_id
		) == CombatTypes.EnemyTerminalReason.DEFEATED,
		"Enemy-vs-enemy lethal must retain hostile attribution and advance the ledger."
	)
	_expect(
		game._pending_xirang_kill_reward == 0
		and int(game.campaign_coordinator.daily_xirang_rewards.get(
			day_number,
			0
		)) == daily_before,
		"Hostile enemy lethal must not enqueue player reward accounting."
	)
	for _settlement_frame in range(4):
		await process_frame
	_expect(
		owner.current_xirang == player_xirang_before
		and _count_pickups() == pickups_before,
		"Hostile enemy lethal must not grant Xirang or spawn a pickup."
	)
	attacker.queue_free()


func _prepare_wave_fixture() -> void:
	game.campaign_coordinator.replace_flow_state_for_fixture(
		CombatFlowState.State.WAVE_ACTIVE,
		game.campaign_coordinator.waves[0]
	)
	game.campaign_coordinator.reset_wave_progress(1, 1)
	game.enemy_coordinator.clear_queue()
	game.enemy_coordinator.clear_active_enemies()
	game._pending_xirang_kill_reward = 0


func _spawn_registered_wave_enemy(config: EnemyConfig) -> Enemy:
	var enemy := config.enemy_scene.instantiate() as Enemy
	if enemy == null:
		_fail("Wave enemy scene did not instantiate.")
		return null
	game.enemy_container.add_child(enemy)
	enemy.setup(config, game.player, game.grid_pathfinder, game)
	enemy.set_authoritative_simulation_enabled(false)
	if not game.enemy_coordinator.register_external_enemy(enemy):
		_fail("Wave enemy did not register in the authoritative terminal ledger.")
		enemy.queue_free()
		return null
	return enemy


func _make_enemy_config(
	maximum_health: int,
	reward: int,
	with_drop: bool
) -> EnemyConfig:
	var config := ENEMY_CONFIG.duplicate(true) as EnemyConfig
	config.max_health = maxi(maximum_health, 1)
	config.physical_defense = 0
	config.magic_defense = 0
	config.xirang_kill_reward = maxi(reward, 0)
	config.drop_table = _make_guaranteed_drop_table() if with_drop else null
	return config


func _make_guaranteed_drop_table() -> EnemyDropTable:
	var rule := EnemyDropRule.new()
	rule.pickup_config = DROP_CONFIG
	rule.chance = 1.0
	var table := EnemyDropTable.new()
	table.rules = [rule]
	return table


func _count_pickups() -> int:
	var count := 0
	for child in game.enemy_container.get_children():
		if child is Pickup:
			count += 1
	return count


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)


func _fail(message: String) -> void:
	failures.append(message)


func _finish() -> void:
	if failures.is_empty():
		print("PLAYER_OWNED_PLANT_KILL_ATTRIBUTION_SMOKE_TEST_OK")
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	quit(1)
