extends SceneTree

## Stage-seven terminal edge regression. Two real hostile enemies launch authored
## projectiles before either dies; both authored body_entered signal handlers then
## resolve on the same LAYERED_CONTACT physics tick. This exercises frozen
## projectile faction, production damage admission, terminal ledger and reward
## attribution together without depending on new-Area PhysicsServer registration
## ordering, which is allowed to span frames.

const TOWER_SCENE := preload(
	"res://scene/game_modes/tower_defense/tower_defense_game.tscn"
)
const BASIC_CONFIG := preload(
	"res://resources/config/enemies/yuanshi_insect_basic.tres"
)
const DROP_CONFIG := preload(
	"res://resources/config/materials/material_sapling.tres"
)
const FIRE_PROJECTILE_SCENE := preload(
	"res://scene/enemy/yuanshi_insect/yuanshi_insect_fire_projectile.tscn"
)

const LEFT_FACTION := 3
const RIGHT_FACTION := 4
const LEFT_TERMINAL_ID := 41_001
const RIGHT_TERMINAL_ID := 41_002
const REWARD_TERMINAL_ID := 41_003
const REWARD_AMOUNT := 23

var failures: Array[String] = []
var game: TowerDefenseGame


func _init() -> void:
	call_deferred(&"_run")


func _run() -> void:
	game = TOWER_SCENE.instantiate() as TowerDefenseGame
	game.auto_start_waves = false
	root.add_child(game)
	current_scene = game
	await process_frame
	await physics_frame
	var simulation_coordinator := game.get_enemy_simulation_coordinator()
	if simulation_coordinator == null:
		failures.append("Tower fixture must author EnemySimulationCoordinator.")
	else:
		simulation_coordinator.set_mode(
			EnemySimulationPolicy.Mode.LAYERED_CONTACT
		)
		_expect(
			simulation_coordinator.mode
			== EnemySimulationPolicy.Mode.LAYERED_CONTACT,
			"Terminal fixture must exercise the production LAYERED_CONTACT mode."
		)

	await _test_same_tick_mutual_terminal_order_and_no_reward()
	await _test_player_allied_reward_and_drop_are_single_shot()

	current_scene = null
	game.queue_free()
	for _cleanup_frame in range(6):
		await process_frame
		await physics_frame

	if failures.is_empty():
		print("ENEMY_DYNAMIC_TERMINAL_EDGE_SMOKE_TEST_OK")
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	quit(1)


func _test_same_tick_mutual_terminal_order_and_no_reward() -> void:
	_prepare_wave_fixture(2)
	var relation_service := game.get_combat_relation_service()
	_expect(
		relation_service.set_hostile(LEFT_FACTION, RIGHT_FACTION)
		and relation_service.set_hostile(RIGHT_FACTION, LEFT_FACTION),
		"The fixture factions must be mutually hostile without using PLAYER_ALLIED."
	)

	var left_config := _make_enemy_config(7, 17, true)
	var right_config := _make_enemy_config(7, 19, true)
	var left := _spawn_registered_enemy(
		left_config,
		LEFT_FACTION,
		LEFT_TERMINAL_ID,
		Vector2(-12.0, 0.0)
	)
	var right := _spawn_registered_enemy(
		right_config,
		RIGHT_FACTION,
		RIGHT_TERMINAL_ID,
		Vector2(12.0, 0.0)
	)
	if left == null or right == null:
		return

	var terminal_order: Array[int] = []
	var terminal_counts: Dictionary[int, int] = {}
	_connect_terminal_capture(left, terminal_order, terminal_counts)
	_connect_terminal_capture(right, terminal_order, terminal_counts)
	var terminal_physics_frames: Array[int] = []
	left.defeated.connect(func(_enemy: Enemy) -> void:
		terminal_physics_frames.append(Engine.get_physics_frames())
	)
	right.defeated.connect(func(_enemy: Enemy) -> void:
		terminal_physics_frames.append(Engine.get_physics_frames())
	)
	var pickups_before := _count_pickups(game.enemy_container)
	var left_drop_rng_before := left.material_drop_random_generator.state
	var right_drop_rng_before := right.material_drop_random_generator.state

	# Both source snapshots are frozen while both attackers are alive. A projectile
	# remains authoritative after its source dies, so reciprocal in-flight hits do
	# not become order-dependent when PhysicsServer dispatches one callback first.
	var left_snapshot := left.create_damage_source_snapshot(
		51_001,
		&"same_tick_left_projectile"
	)
	var right_snapshot := right.create_damage_source_snapshot(
		51_002,
		&"same_tick_right_projectile"
	)
	_expect(
		left_snapshot.instigator_entity_id == LEFT_TERMINAL_ID
		and right_snapshot.instigator_entity_id == RIGHT_TERMINAL_ID
		and left_snapshot.source_faction_id == LEFT_FACTION
		and right_snapshot.source_faction_id == RIGHT_FACTION
		and not left.is_dead
		and not right.is_dead,
		"Both attacks must freeze stable source identity while both enemies are alive."
	)
	var left_projectile := _spawn_terminal_projectile(
		right.global_position,
		right.current_health,
		left_snapshot
	)
	var right_projectile := _spawn_terminal_projectile(
		left.global_position,
		left.current_health,
		right_snapshot
	)
	_expect(
		left_projectile != null and right_projectile != null,
		"Both authored reciprocal projectiles must instantiate."
	)
	if left_projectile != null and right_projectile != null:
		# These are the real typed Area2D signals connected by each projectile's
		# production _ready(). Emitting both synchronously isolates the intended
		# simultaneous-combat contract from PhysicsServer RID registration order.
		left_projectile.body_entered.emit(right)
		right_projectile.body_entered.emit(left)
	_expect(
		left.is_dead
		and right.is_dead,
		"Two real enemies with reciprocal in-flight projectiles must both die."
	)
	var sorted_terminal_ids := terminal_order.duplicate()
	sorted_terminal_ids.sort()
	_expect(
		sorted_terminal_ids == [LEFT_TERMINAL_ID, RIGHT_TERMINAL_ID]
		and int(terminal_counts.get(LEFT_TERMINAL_ID, 0)) == 1
		and int(terminal_counts.get(RIGHT_TERMINAL_ID, 0)) == 1
		and terminal_physics_frames.size() == 2
		and terminal_physics_frames[0] == terminal_physics_frames[1],
		"Production projectile callbacks must publish each terminal exactly once "
		+ "on the same authoritative tick; ids=%s counts=%s frames=%s."
		% [sorted_terminal_ids, terminal_counts, terminal_physics_frames]
	)

	var ledger := game.campaign_coordinator.wave_enemy_terminal_ledger
	_expect(
		ledger.get_terminal_reason(left.get_instance_id())
		== CombatTypes.EnemyTerminalReason.DEFEATED
		and ledger.get_terminal_reason(right.get_instance_id())
		== CombatTypes.EnemyTerminalReason.DEFEATED
		and ledger.get_defeated() == 2
		and ledger.get_resolved() == 2
		and ledger.get_active_enemy_count() == 0,
		"The wave ledger must retain two distinct DEFEATED terminals from the same tick."
	)
	_expect(
		left.defeat_context != null
		and right.defeat_context != null
		and not left.defeat_context.is_player_reward_eligible()
		and not right.defeat_context.is_player_reward_eligible()
		and left.material_drop_random_generator.state == left_drop_rng_before
		and right.material_drop_random_generator.state == right_drop_rng_before
		and game._pending_xirang_kill_reward == 0,
		"A non-player duel must neither roll drops nor enqueue player economy credit."
	)

	# Repeat equivalent frozen events. Enemy and ledger idempotency must reject
	# them without adding a terminal, reward, drop roll or wave resolution.
	var repeated_right := right.apply_combat_damage(
		_make_snapshot_request(right.current_health, left_snapshot)
	)
	var repeated_left := left.apply_combat_damage(
		_make_snapshot_request(left.current_health, right_snapshot)
	)
	_expect(
		repeated_right.is_rejected_for(
			CombatTypes.DamageRejectionReason.TARGET_DEAD
		)
		and repeated_left.is_rejected_for(
			CombatTypes.DamageRejectionReason.TARGET_DEAD
		)
		and terminal_order.size() == 2
		and ledger.get_defeated() == 2
		and ledger.get_resolved() == 2,
		"Repeated same-tick events must not duplicate terminals or wave accounting."
	)

	await process_frame
	await process_frame
	_expect(
		_count_pickups(game.enemy_container) == pickups_before
		and game._pending_xirang_kill_reward == 0,
		"Pure non-player combat must not roll drops or grant deferred Xirang."
	)
	game.unregister_network_enemy(LEFT_TERMINAL_ID, left)
	game.unregister_network_enemy(RIGHT_TERMINAL_ID, right)
	_queue_free_if_valid(left)
	_queue_free_if_valid(right)
	await process_frame


func _test_player_allied_reward_and_drop_are_single_shot() -> void:
	_prepare_wave_fixture(1)
	var reward_config := _make_enemy_config(5, REWARD_AMOUNT, true)
	var victim := _spawn_registered_enemy(
		reward_config,
		CombatRelationService.HOSTILE_WAVE,
		REWARD_TERMINAL_ID,
		Vector2.ZERO
	)
	if victim == null:
		return

	var terminal_order: Array[int] = []
	var terminal_counts: Dictionary[int, int] = {}
	_connect_terminal_capture(victim, terminal_order, terminal_counts)
	var pickups_before := _count_pickups(game.enemy_container)
	var player_xirang_before := game.player.get_xirang()
	var request := _make_snapshot_request(
		victim.current_health,
		DamageSourceSnapshot.create(
			CombatRelationService.PLAYER_ALLIED,
			1,
			61_001,
			61_002,
			&"single_reward_lethal"
		)
	)
	var authoritative_physics_tick := Engine.get_physics_frames()
	var lethal_result := victim.apply_combat_damage(request)
	var duplicate_result := victim.apply_combat_damage(request)
	_expect(
		Engine.get_physics_frames() == authoritative_physics_tick
		and lethal_result.lethal
		and duplicate_result.is_rejected_for(
			CombatTypes.DamageRejectionReason.TARGET_DEAD
		),
		"One player-allied lethal and its duplicate must resolve inside one tick."
	)
	_expect(
		terminal_order == [REWARD_TERMINAL_ID]
		and int(terminal_counts.get(REWARD_TERMINAL_ID, 0)) == 1
		and victim.defeat_context != null
		and victim.defeat_context.is_player_reward_eligible()
		and game.campaign_coordinator.wave_enemy_terminal_ledger.get_defeated() == 1
		and game.campaign_coordinator.wave_enemy_terminal_ledger.get_resolved() == 1
		and game._pending_xirang_kill_reward == REWARD_AMOUNT,
		"A player-allied lethal must commit one terminal and enqueue one reward only."
	)

	await process_frame
	await process_frame
	_expect(
		game.player.get_xirang() == player_xirang_before + REWARD_AMOUNT
		and _count_pickups(game.enemy_container) == pickups_before + 1
		and game._pending_xirang_kill_reward == 0
		and terminal_order == [REWARD_TERMINAL_ID],
		"Deferred settlement must grant exactly one reward and one guaranteed pickup."
	)
	game.unregister_network_enemy(REWARD_TERMINAL_ID, victim)
	_queue_free_if_valid(victim)
	await process_frame


func _prepare_wave_fixture(total: int) -> void:
	game.campaign_coordinator.replace_flow_state_for_fixture(
		CombatFlowState.State.WAVE_ACTIVE,
		game.campaign_coordinator.waves[0]
	)
	game.campaign_coordinator.reset_wave_progress(total, total)
	game.enemy_coordinator.clear_queue()
	game.enemy_coordinator.clear_active_enemies()
	game._pending_xirang_kill_reward = 0


func _spawn_registered_enemy(
	enemy_config: EnemyConfig,
	faction_id: int,
	terminal_fixture_id: int,
	position: Vector2
) -> Enemy:
	var enemy := enemy_config.enemy_scene.instantiate() as Enemy
	if enemy == null:
		failures.append("The real Yuanshi scene could not be instantiated.")
		return null
	game.enemy_container.add_child(enemy)
	enemy.global_position = position
	enemy.setup(enemy_config, null, game.grid_pathfinder, game)
	enemy.set_process(false)
	enemy.set_authoritative_simulation_enabled(false)
	enemy.set_meta(&"terminal_fixture_id", terminal_fixture_id)
	if not enemy.set_combat_faction_id(faction_id, -1, true):
		failures.append("Fixture faction %d could not be assigned." % faction_id)
	if not game.enemy_coordinator.register_external_enemy(enemy):
		failures.append("Wave terminal fixture %d could not register." % terminal_fixture_id)
		return enemy
	if not game.register_network_enemy(terminal_fixture_id, enemy):
		failures.append(
			"Terminal fixture %d could not freeze a stable network identity."
			% terminal_fixture_id
		)
	# The production spawn path connects this synchronously before Enemy checks
	# whether ledger-backed rewards may settle. Reproduce that exact ordering.
	enemy.defeated.connect(Callable(
		game.enemy_coordinator,
		&"_on_wave_enemy_defeated"
	))
	return enemy


func _connect_terminal_capture(
	enemy: Enemy,
	terminal_order: Array[int],
	terminal_counts: Dictionary[int, int]
) -> void:
	enemy.defeated.connect(func(defeated_enemy: Enemy) -> void:
		var terminal_id := int(defeated_enemy.get_meta(
			&"terminal_fixture_id",
			0
		))
		terminal_order.append(terminal_id)
		terminal_counts[terminal_id] = int(
			terminal_counts.get(terminal_id, 0)
		) + 1
	)


func _spawn_terminal_projectile(
	position: Vector2,
	damage: int,
	source_snapshot: DamageSourceSnapshot
) -> YuanshiInsectFireProjectile:
	var projectile := (
		FIRE_PROJECTILE_SCENE.instantiate()
		as YuanshiInsectFireProjectile
	)
	if projectile == null:
		return null
	game.enemy_container.add_child(projectile)
	projectile.bind_gameplay_context(
		game,
		game.get_multiplayer_gameplay_gateway()
	)
	# Keep the real Area2D stationary inside the victim body until PhysicsServer
	# publishes body_entered. Restricting the authored mask to layer 4 isolates the
	# intended enemy target without bypassing collision/contact dispatch.
	projectile.collision_mask = 4
	projectile.global_position = position
	projectile.setup(
		Vector2.RIGHT,
		damage,
		0.0,
		1.0,
		source_snapshot
	)
	return projectile


func _make_snapshot_request(
	amount: int,
	source_snapshot: DamageSourceSnapshot
) -> DamageRequest:
	var request := DamageRequest.new(
		amount,
		CombatTypes.DamageType.PHYSICAL
	)
	request.with_source_snapshot(source_snapshot)
	request.with_flag(CombatTypes.DamageFlag.SUPPRESS_HIT_PARTICLES)
	request.with_flag(CombatTypes.DamageFlag.SUPPRESS_HIT_FLASH)
	return request


func _make_enemy_config(
	max_health: int,
	xirang_reward: int,
	guaranteed_drop: bool
) -> EnemyConfig:
	var enemy_config := BASIC_CONFIG.duplicate(true) as EnemyConfig
	enemy_config.max_health = maxi(max_health, 1)
	enemy_config.physical_defense = 0
	enemy_config.magic_defense = 0
	enemy_config.xirang_kill_reward = maxi(xirang_reward, 0)
	enemy_config.drop_table = (
		_make_guaranteed_drop_table() if guaranteed_drop else null
	)
	return enemy_config


func _make_guaranteed_drop_table() -> EnemyDropTable:
	var rule := EnemyDropRule.new()
	rule.pickup_config = DROP_CONFIG
	rule.chance = 1.0
	var table := EnemyDropTable.new()
	table.rules = [rule]
	return table


func _count_pickups(parent: Node) -> int:
	var count := 0
	for child in parent.get_children():
		if child is Pickup:
			count += 1
	return count


func _queue_free_if_valid(node: Node) -> void:
	if node != null and is_instance_valid(node) and not node.is_queued_for_deletion():
		node.queue_free()


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
