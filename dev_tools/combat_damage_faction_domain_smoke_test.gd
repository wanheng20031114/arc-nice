extends SceneTree

## Stage-five combat-domain regression: frozen source attribution, strict
## faction admission, delayed status ownership, enemy-vs-enemy melee, reward
## eligibility and the Home ESCAPED gate are exercised through production
## sinks rather than duplicating resolver arithmetic in the probe.

const RUNTIME_SCENE := preload(
	"res://dev_tools/fixtures/enemy_gameplay_gateway_test_runtime.tscn"
)
const PLAYER_SCENE := preload(
	"res://scene/player/weishidaier/player_weishidaier.tscn"
)
const ENEMY_CONFIG := preload(
	"res://resources/config/enemies/yuanshi_insect_basic.tres"
)
const AGAVE_SCENE := preload(
	"res://scene/plant_defense/agave_cannon.tscn"
)
const AGAVE_CONFIG := preload(
	"res://resources/config/plant_defense/agave_cannon.tres"
)
const DROP_CONFIG := preload(
	"res://resources/config/materials/material_sapling.tres"
)
const TOWER_SCENE := preload(
	"res://scene/game_modes/tower_defense/tower_defense_game.tscn"
)
const HOME_ENEMY_CONFIG := preload(
	"res://resources/config/enemies/slime.tres"
)


class HomeProbe extends TowerDefenseHomeDefenseCoordinator:
	func _present_base_health(
		_play_damage_pulse: bool,
		_was_remote: bool
	) -> void:
		pass


class FactionProbe extends Node2D:
	var faction_id := CombatRelationService.NEUTRAL

	func get_combat_faction_id() -> int:
		return faction_id


var failures: Array[String] = []
var runtime: EnemyGameplayGatewayTestRuntime
var fixture_parent: Node2D


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	runtime = RUNTIME_SCENE.instantiate() as EnemyGameplayGatewayTestRuntime
	root.add_child(runtime)
	current_scene = runtime
	fixture_parent = runtime.enemy_container
	await process_frame

	_test_snapshot_value_contract()
	await _test_four_authoritative_sinks()
	await _test_periodic_snapshot_contract()
	_test_enemy_enemy_melee_contract()
	await _test_defeat_reward_and_drop_contract()
	_test_facade_faction_delegation()

	current_scene = null
	runtime.queue_free()
	for _cleanup_frame in range(4):
		await process_frame
		await physics_frame

	await _test_home_friendly_escape_gate()
	root.get_node("BurnStatusScheduler").call("clear_all")
	root.get_node("BleedStatusScheduler").call("clear_all")
	await process_frame

	if failures.is_empty():
		print("COMBAT_DAMAGE_FACTION_DOMAIN_SMOKE_TEST_OK")
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	quit(1)


func _test_snapshot_value_contract() -> void:
	var original := DamageSourceSnapshot.create(
		CombatRelationService.PLAYER_ALLIED,
		17,
		23,
		31,
		&"snapshot_probe"
	)
	var scalar := DamageRequest.new(3).with_source_snapshot(original)
	var batch := DamageBatchRequest.new(
		PackedInt64Array([2, 5]),
		PackedInt32Array([3, 1])
	).with_source_snapshot(original)
	original.source_faction_id = CombatRelationService.HOSTILE_WAVE
	original.credit_peer_id = 999
	var scalar_snapshot := scalar.get_source_snapshot_copy()
	var batch_snapshot := batch.get_source_snapshot_copy()
	_expect(
		scalar_snapshot.source_faction_id
			== CombatRelationService.PLAYER_ALLIED
		and scalar_snapshot.credit_peer_id == 17
		and batch_snapshot.source_faction_id
			== CombatRelationService.PLAYER_ALLIED
		and batch_snapshot.credit_peer_id == 17,
		"Scalar and batch requests must deep-copy source snapshots."
	)
	scalar_snapshot.source_faction_id = CombatRelationService.HOSTILE_WAVE
	_expect(
		scalar.get_or_create_source_snapshot().source_faction_id
			== CombatRelationService.PLAYER_ALLIED,
		"A returned source snapshot copy must not mutate the retained request value."
	)
	var legacy := DamageRequest.new(1).get_or_create_source_snapshot()
	_expect(
		legacy.source_faction_id == CombatRelationService.PLAYER_ALLIED
		and legacy.source_type == DamageSourceSnapshot.LEGACY_SOURCE_TYPE,
		"Raw unattributed DamageRequest must retain legacy player-owned semantics."
	)

	var source_enemy := _spawn_enemy(_make_enemy_config(20), null)
	source_enemy.set_combat_faction_id(
		CombatRelationService.PLAYER_ALLIED,
		-1,
		true
	)
	var captured_request := DamageRequest.new(1).with_source(
		source_enemy,
		91,
		&"faction_freeze_probe"
	)
	source_enemy.set_combat_faction_id(
		CombatRelationService.HOSTILE_WAVE,
		-1,
		true
	)
	_expect(
		captured_request.get_or_create_source_snapshot().source_faction_id
			== CombatRelationService.PLAYER_ALLIED,
		"DamageRequest.with_source must freeze faction before the source changes."
	)
	source_enemy.queue_free()


func _test_four_authoritative_sinks() -> void:
	var enemy := _spawn_enemy(_make_enemy_config(80), runtime)
	var enemy_health := enemy.current_health
	var enemy_hostile_result := enemy.apply_combat_damage(
		_make_request(3, CombatRelationService.PLAYER_ALLIED)
	)
	var enemy_after_hostile := enemy.current_health
	var enemy_nonhostile_result := enemy.apply_combat_damage(
		_make_request(3, CombatRelationService.HOSTILE_WAVE)
	)
	var enemy_bypass_result := enemy.apply_combat_damage(
		_make_request(
			3,
			CombatRelationService.HOSTILE_WAVE,
			true
		)
	)
	_expect(
		enemy_hostile_result.accepted
		and enemy_after_hostile < enemy_health
		and enemy_nonhostile_result.is_rejected_for(
			CombatTypes.DamageRejectionReason.NON_HOSTILE
		)
		and enemy_bypass_result.accepted,
		"Enemy sink must accept hostile, reject non-hostile and honor explicit bypass."
	)

	var player := await _spawn_player()
	_prepare_player(player, 80)
	var player_hostile_result := player.apply_combat_damage(
		_make_player_request(3, CombatRelationService.HOSTILE_WAVE)
	)
	var player_nonhostile_result := player.apply_combat_damage(
		_make_player_request(3, CombatRelationService.PLAYER_ALLIED)
	)
	var player_bypass_result := player.apply_combat_damage(
		_make_player_request(
			3,
			CombatRelationService.PLAYER_ALLIED,
			true
		)
	)
	var player_health_before_malformed := player.current_health
	var malformed_context_accepted := player.apply_damage(
		3,
		EnemyConfig.DamageType.PHYSICAL,
		{"source_snapshot": "not-a-snapshot"}
	)
	_expect(
		player_hostile_result.accepted
		and player_nonhostile_result.is_rejected_for(
			CombatTypes.DamageRejectionReason.NON_HOSTILE
		)
		and player_bypass_result.accepted
		and not malformed_context_accepted
		and player.last_damage_result.is_rejected_for(
			CombatTypes.DamageRejectionReason.INVALID_REQUEST
		)
		and player.current_health == player_health_before_malformed,
		"Player sink must accept hostile, reject non-hostile and honor explicit bypass."
	)

	var plant := _spawn_plant(player)
	var plant_hostile_result := plant.apply_combat_damage(
		_make_request(3, CombatRelationService.HOSTILE_WAVE)
	)
	var plant_nonhostile_result := plant.apply_combat_damage(
		_make_request(3, CombatRelationService.PLAYER_ALLIED)
	)
	var plant_bypass_result := plant.apply_combat_damage(
		_make_request(
			3,
			CombatRelationService.PLAYER_ALLIED,
			true
		)
	)
	_expect(
		plant_hostile_result.accepted
		and plant_nonhostile_result.is_rejected_for(
			CombatTypes.DamageRejectionReason.NON_HOSTILE
		)
		and plant_bypass_result.accepted,
		"Plant sink must accept hostile, reject non-hostile and honor explicit bypass."
	)

	var home := HomeProbe.new()
	runtime.add_child(home)
	home._runtime = runtime
	home._run_state = null
	home.maximum_base_health = 80
	home.current_base_health = 80
	var home_hostile_result := home.apply_base_combat_damage(
		_make_request(3, CombatRelationService.HOSTILE_WAVE)
	)
	var home_nonhostile_result := home.apply_base_combat_damage(
		_make_request(3, CombatRelationService.PLAYER_ALLIED)
	)
	var home_bypass_result := home.apply_base_combat_damage(
		_make_request(
			3,
			CombatRelationService.PLAYER_ALLIED,
			true
		)
	)
	_expect(
		home_hostile_result.accepted
		and home_nonhostile_result.is_rejected_for(
			CombatTypes.DamageRejectionReason.NON_HOSTILE
		)
		and home_bypass_result.accepted,
		"Home sink must accept hostile, reject non-hostile and honor explicit bypass."
	)

	enemy.queue_free()
	player.queue_free()
	plant.queue_free()
	home.queue_free()
	await process_frame


func _test_periodic_snapshot_contract() -> void:
	var burn_scheduler := root.get_node("BurnStatusScheduler")
	burn_scheduler.call("clear_all")
	burn_scheduler.set_physics_process(false)

	var player := await _spawn_player()
	_prepare_player(player, 60)
	var source_enemy := _spawn_enemy(_make_enemy_config(20), runtime)
	var frozen_hostile := source_enemy.create_damage_source_snapshot(
		701,
		&"frozen_burn"
	)
	_expect(
		player.apply_burn_status(&"frozen_burn", 2.0, 7, frozen_hostile),
		"Player must accept a valid frozen burn application."
	)
	# Mutating both the caller value and live source must not change the retained
	# SourceState attribution.
	frozen_hostile.source_faction_id = CombatRelationService.PLAYER_ALLIED
	source_enemy.set_combat_faction_id(
		CombatRelationService.PLAYER_ALLIED,
		-1,
		true
	)
	source_enemy.queue_free()
	var health_before_tick := player.current_health
	burn_scheduler.call("_advance_active_burns", 1.0)
	_expect(
		player.current_health < health_before_tick
		and player.last_damage_result.accepted
		and player.last_damage_result.request.get_or_create_source_snapshot(
		).source_faction_id == CombatRelationService.HOSTILE_WAVE,
		"Player burn tick must retain the application-time faction after source mutation/removal."
	)

	# Same-family refresh intentionally transfers future attribution to the last
	# accepted application. A player-owned refresh is therefore rejected by the
	# player sink rather than inheriting the older enemy owner.
	burn_scheduler.call("clear_all")
	_prepare_player(player, 60)
	player.apply_burn_status(
		&"refresh_owner",
		2.0,
		5,
		DamageSourceSnapshot.create(CombatRelationService.HOSTILE_WAVE)
	)
	player.apply_burn_status(
		&"refresh_owner",
		2.0,
		9,
		DamageSourceSnapshot.create(CombatRelationService.PLAYER_ALLIED)
	)
	var refresh_health := player.current_health
	burn_scheduler.call("_advance_active_burns", 1.0)
	_expect(
		player.current_health == refresh_health
		and player.last_damage_result.is_rejected_for(
			CombatTypes.DamageRejectionReason.NON_HOSTILE
		),
		"Same-family refresh must replace frozen attribution with the latest application."
	)

	burn_scheduler.call("clear_all")
	_prepare_player(player, 60)
	player.apply_burn_status(
		&"clear_probe",
		2.0,
		6,
		DamageSourceSnapshot.create(CombatRelationService.HOSTILE_WAVE)
	)
	player.clear_burn_status()
	var cleared_health := player.current_health
	burn_scheduler.call("_advance_active_burns", 2.0)
	_expect(
		player.current_health == cleared_health,
		"Clearing a periodic status must release its source and prevent later ticks."
	)

	var plant := _spawn_plant(player)
	burn_scheduler.call("clear_all")
	var plant_health := plant.current_health
	plant.apply_burn_status(
		&"plant_burn",
		2.0,
		4,
		DamageSourceSnapshot.create(CombatRelationService.HOSTILE_WAVE)
	)
	burn_scheduler.call("_advance_active_burns", 1.0)
	_expect(
		plant.current_health < plant_health
		and plant.last_damage_result.accepted
		and plant.last_damage_result.request.get_or_create_source_snapshot(
		).source_faction_id == CombatRelationService.HOSTILE_WAVE,
		"Plant periodic tick must carry the frozen hostile snapshot into its sink."
	)

	var enemy := _spawn_enemy(_make_enemy_config(3), runtime)
	enemy.apply_burn_status(
		&"player_burn",
		2.0,
		3,
		DamageSourceSnapshot.create(
			CombatRelationService.PLAYER_ALLIED,
			42,
			51,
			61,
			&"player_burn"
		)
	)
	enemy.call(
		"_advance_collectible_status_effects_to",
		enemy.collectible_status_clock + 1.0
	)
	_expect(
		enemy.is_dead
		and enemy.defeat_context != null
		and enemy.defeat_context.source_snapshot.credit_peer_id == 42,
		"Enemy periodic lethal must freeze the player credit in EnemyDefeatContext."
	)

	burn_scheduler.call("clear_all")
	player.queue_free()
	plant.queue_free()
	await process_frame


func _test_enemy_enemy_melee_contract() -> void:
	var attacker := _spawn_enemy(_make_enemy_config(30), null)
	var target := _spawn_enemy(_make_enemy_config(30), null)
	attacker.set_combat_faction_id(
		CombatRelationService.PLAYER_ALLIED,
		-1,
		true
	)
	attacker.global_position = Vector2(20.0, 20.0)
	target.global_position = attacker.global_position
	attacker.set_objective_target(target)
	attacker.touch_damage_cooldown_left = 0.0
	var target_health := target.current_health
	attacker.call("_try_deal_touch_damage")
	_expect(
		target.current_health < target_health
		and target.last_damage_result != null
		and target.last_damage_result.request.get_or_create_source_snapshot(
		).source_faction_id == CombatRelationService.PLAYER_ALLIED,
		"Enemy melee must damage a contacted hostile Enemy with an explicit snapshot."
	)
	attacker.queue_free()
	target.queue_free()


func _test_defeat_reward_and_drop_contract() -> void:
	var reward_config := _make_enemy_config(1)
	reward_config.xirang_kill_reward = 13
	reward_config.drop_table = _make_guaranteed_drop_table()
	var initial_pickups := _count_pickups(fixture_parent)
	var rewarded_enemy := _spawn_enemy(reward_config, runtime)
	var rewarded_result := rewarded_enemy.apply_combat_damage(
		_make_request(1, CombatRelationService.PLAYER_ALLIED)
	)
	_expect(
		rewarded_result.lethal
		and rewarded_enemy.defeat_context != null
		and rewarded_enemy.defeat_context.is_player_reward_eligible()
		and runtime._pending_xirang_kill_reward == 13,
		"Player-allied lethal must enqueue Xirang after accepted defeat settlement."
	)
	await process_frame
	await process_frame
	var rewarded_pickups := _count_pickups(fixture_parent)
	_expect(
		rewarded_pickups == initial_pickups + 1,
		"Player-allied lethal must spawn the configured guaranteed pickup."
	)

	var hostile_config := _make_enemy_config(1)
	hostile_config.xirang_kill_reward = 17
	hostile_config.drop_table = _make_guaranteed_drop_table()
	var hostile_killed_enemy := _spawn_enemy(hostile_config, runtime)
	hostile_killed_enemy.set_combat_faction_id(
		CombatRelationService.PLAYER_ALLIED,
		-1,
		true
	)
	var pickups_before_hostile_kill := _count_pickups(fixture_parent)
	var hostile_result := hostile_killed_enemy.apply_combat_damage(
		_make_request(1, CombatRelationService.HOSTILE_WAVE)
	)
	_expect(
		hostile_result.lethal
		and hostile_killed_enemy.defeat_context != null
		and not hostile_killed_enemy.defeat_context.is_player_reward_eligible()
		and runtime._pending_xirang_kill_reward == 0,
		"Pure hostile-faction lethal must resolve death without granting Xirang."
	)
	await process_frame
	await process_frame
	_expect(
		_count_pickups(fixture_parent) == pickups_before_hostile_kill,
		"Pure hostile-faction lethal must not create pickup drops."
	)


func _test_facade_faction_delegation() -> void:
	var target := FactionProbe.new()
	target.faction_id = 7
	runtime.add_child(target)
	_expect(
		runtime.get_combat_query_facade().get_target_faction_id(target) == 7,
		"CombatQueryFacade must delegate faction reads to the target contract."
	)
	target.queue_free()


func _test_home_friendly_escape_gate() -> void:
	var game := TOWER_SCENE.instantiate() as TowerDefenseGame
	game.auto_start_waves = false
	root.add_child(game)
	current_scene = game
	await process_frame
	await physics_frame
	game.home_defense_coordinator._run_state = null
	await _test_tower_reward_ledger_gate(game)

	var enemy := HOME_ENEMY_CONFIG.enemy_scene.instantiate() as Enemy
	game.enemy_container.add_child(enemy)
	enemy.setup(HOME_ENEMY_CONFIG, game.player, game.grid_pathfinder, game)
	enemy.set_combat_faction_id(
		CombatRelationService.PLAYER_ALLIED,
		-1,
		true
	)
	game.campaign_coordinator.replace_flow_state_for_fixture(
		CombatFlowState.State.WAVE_ACTIVE,
		game.campaign_coordinator.waves[0]
	)
	game.campaign_coordinator.reset_wave_progress(1, 1)
	game.enemy_coordinator.clear_queue()
	game.enemy_coordinator.clear_active_enemies()
	_expect(
		game.enemy_coordinator.register_external_enemy(enemy),
		"Friendly Home probe enemy must register in the wave ledger."
	)
	var enemy_id := enemy.get_instance_id()
	var base_health_before := game.home_defense_coordinator.current_base_health
	game.home_defense_coordinator.clear_resolved_enemy_ids()
	game.home_defense_coordinator.on_enemy_reached_home(enemy, Vector2i.ZERO)
	_expect(
		game.enemy_coordinator.has_active_enemy(enemy_id)
		and game.campaign_coordinator.wave_enemy_terminal_ledger.get_terminal_reason(
			enemy_id
		) == -1
		and not game.home_defense_coordinator.resolved_home_enemy_ids.has(enemy_id)
		and game.home_defense_coordinator.current_base_health == base_health_before
		and not enemy.is_dead
		and not enemy.is_queued_for_deletion(),
		"Friendly Enemy reaching Home must not record ESCAPED, dedupe, remove or damage the base."
	)

	current_scene = null
	game.queue_free()
	for _cleanup_frame in range(6):
		await process_frame
		await physics_frame


func _test_tower_reward_ledger_gate(game: TowerDefenseGame) -> void:
	var reward_config := _make_enemy_config(1)
	reward_config.xirang_kill_reward = 19
	reward_config.drop_table = _make_guaranteed_drop_table()

	# Synchronous defeated handler commits DEFEATED before Enemy asks the
	# runtime whether reward/drop settlement is allowed.
	_prepare_tower_wave_fixture(game)
	var committed := _spawn_tower_enemy(game, reward_config)
	committed.defeated.connect(Callable(
		game.enemy_coordinator,
		"_on_wave_enemy_defeated"
	))
	var committed_id := committed.get_instance_id()
	var committed_pickups_before := _count_pickups(game.enemy_container)
	var committed_result := committed.apply_combat_damage(
		_make_request(1, CombatRelationService.PLAYER_ALLIED)
	)
	_expect(
		committed_result.lethal
		and game.campaign_coordinator.wave_enemy_terminal_ledger.get_terminal_reason(
			committed_id
		) == CombatTypes.EnemyTerminalReason.DEFEATED
		and game._pending_xirang_kill_reward == 19,
		"Registered player-allied lethal must commit DEFEATED before enqueuing reward."
	)
	await process_frame
	await process_frame
	_expect(
		_count_pickups(game.enemy_container) == committed_pickups_before + 1,
		"Registered committed DEFEATED must admit its configured pickup drop."
	)

	# A registered entity whose defeated event is deliberately not connected to
	# the ledger models a rejected/missing terminal transaction. Death visuals may
	# continue, but economic side effects are forbidden.
	_prepare_tower_wave_fixture(game)
	var rejected := _spawn_tower_enemy(game, reward_config)
	var rejected_id := rejected.get_instance_id()
	var rejected_pickups_before := _count_pickups(game.enemy_container)
	var rejected_result := rejected.apply_combat_damage(
		_make_request(1, CombatRelationService.PLAYER_ALLIED)
	)
	_expect(
		rejected_result.lethal
		and game.campaign_coordinator.wave_enemy_terminal_ledger.get_terminal_reason(
			rejected_id
		) == -1
		and game._pending_xirang_kill_reward == 0,
		"Ledger rejection/missing commit must suppress Xirang settlement."
	)
	await process_frame
	await process_frame
	_expect(
		_count_pickups(game.enemy_container) == rejected_pickups_before,
		"Ledger rejection/missing commit must suppress pickup settlement."
	)

	# Bypass only changes admission. A hostile-owned lethal still advances the
	# original wave ledger but cannot become player economy credit.
	_prepare_tower_wave_fixture(game)
	var hostile_owned := _spawn_tower_enemy(game, reward_config)
	hostile_owned.defeated.connect(Callable(
		game.enemy_coordinator,
		"_on_wave_enemy_defeated"
	))
	var hostile_owned_id := hostile_owned.get_instance_id()
	var hostile_pickups_before := _count_pickups(game.enemy_container)
	var hostile_result := hostile_owned.apply_combat_damage(
		_make_request(1, CombatRelationService.HOSTILE_WAVE, true)
	)
	_expect(
		hostile_result.lethal
		and game.campaign_coordinator.wave_enemy_terminal_ledger.get_terminal_reason(
			hostile_owned_id
		) == CombatTypes.EnemyTerminalReason.DEFEATED
		and game._pending_xirang_kill_reward == 0,
		"Hostile-owned lethal must advance DEFEATED without granting Xirang."
	)
	await process_frame
	await process_frame
	_expect(
		_count_pickups(game.enemy_container) == hostile_pickups_before,
		"Hostile-owned lethal must not spawn pickup drops."
	)


func _prepare_tower_wave_fixture(game: TowerDefenseGame) -> void:
	game.campaign_coordinator.replace_flow_state_for_fixture(
		CombatFlowState.State.WAVE_ACTIVE,
		game.campaign_coordinator.waves[0]
	)
	game.campaign_coordinator.reset_wave_progress(1, 1)
	game.enemy_coordinator.clear_queue()
	game.enemy_coordinator.clear_active_enemies()
	game._pending_xirang_kill_reward = 0


func _spawn_tower_enemy(
	game: TowerDefenseGame,
	config: EnemyConfig
) -> Enemy:
	var enemy := config.enemy_scene.instantiate() as Enemy
	game.enemy_container.add_child(enemy)
	enemy.setup(config, game.player, game.grid_pathfinder, game)
	_expect(
		game.enemy_coordinator.register_external_enemy(enemy),
		"Tower reward probe enemy must register in the wave ledger."
	)
	return enemy


func _make_request(
	amount: int,
	source_faction_id: int,
	bypass_faction_filter: bool = false
) -> DamageRequest:
	var request := DamageRequest.new(amount, CombatTypes.DamageType.PHYSICAL)
	request.with_source_snapshot(DamageSourceSnapshot.create(
		source_faction_id,
		0,
		0,
		101,
		&"faction_domain_smoke"
	))
	request.with_flag(
		CombatTypes.DamageFlag.BYPASS_FACTION_FILTER,
		bypass_faction_filter
	)
	request.with_flag(CombatTypes.DamageFlag.SUPPRESS_HIT_PARTICLES)
	request.with_flag(CombatTypes.DamageFlag.SUPPRESS_HIT_FLASH)
	return request


func _make_player_request(
	amount: int,
	source_faction_id: int,
	bypass_faction_filter: bool = false
) -> DamageRequest:
	var request := _make_request(
		amount,
		source_faction_id,
		bypass_faction_filter
	)
	request.with_flag(CombatTypes.DamageFlag.BYPASS_INVULNERABILITY)
	request.with_flag(CombatTypes.DamageFlag.BYPASS_DODGE)
	request.with_flag(CombatTypes.DamageFlag.NO_HIT_INVINCIBILITY)
	return request


func _make_enemy_config(max_health: int) -> EnemyConfig:
	var config := ENEMY_CONFIG.duplicate(true) as EnemyConfig
	config.max_health = maxi(max_health, 1)
	config.physical_defense = 0
	config.magic_defense = 0
	config.attack_damage = 5
	config.xirang_kill_reward = 0
	config.drop_table = null
	return config


func _make_guaranteed_drop_table() -> EnemyDropTable:
	var rule := EnemyDropRule.new()
	rule.pickup_config = DROP_CONFIG
	rule.chance = 1.0
	var table := EnemyDropTable.new()
	table.rules = [rule]
	return table


func _spawn_enemy(
	config: EnemyConfig,
	runtime_context: CombatRuntimeBase
) -> Enemy:
	var enemy := config.enemy_scene.instantiate() as Enemy
	fixture_parent.add_child(enemy)
	enemy.setup(config, null, null, runtime_context)
	enemy.set_process(false)
	enemy.set_physics_process(false)
	return enemy


func _spawn_player() -> Player:
	var player := PLAYER_SCENE.instantiate() as Player
	runtime.add_child(player)
	await process_frame
	player.bind_combat_runtime(runtime)
	player.set_process(false)
	player.set_physics_process(false)
	return player


func _prepare_player(player: Player, health: int) -> void:
	player.max_health = maxi(health, 1)
	player.current_health = maxi(health, 1)
	player.physical_defense = 0
	player.magic_defense = 0
	player.is_dead = false
	player.invincibility_time_left = 0.0
	player.dash_time_left = 0.0
	player.multiplayer_dash_protection_time_left = 0.0
	player.dodge_chance = 0.0
	player.collectible_ranged_dodge_chance = 0.0
	player.damage_reduction_modifiers.clear()
	player.health_bar.set_health(player.current_health, player.max_health)


func _spawn_plant(owner: Player) -> AgaveCannon:
	var plant := AGAVE_SCENE.instantiate() as AgaveCannon
	runtime.add_child(plant)
	var config := AGAVE_CONFIG.duplicate(true) as PlantDefenseConfig
	plant.setup(config, owner, [Vector2i.ZERO])
	plant.bind_gameplay_context(runtime, null)
	plant.attack_timer.stop()
	plant.set_process(false)
	plant.set_physics_process(false)
	return plant


func _count_pickups(parent: Node) -> int:
	var count := 0
	for child in parent.get_children():
		if child is Pickup:
			count += 1
	return count


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
