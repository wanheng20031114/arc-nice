extends SceneTree

## Scene-level regression for the unified damage sink. Unlike the pure resolver
## A/B test, this test instantiates production Enemy, Player, PlantDefense and
## boss scenes so acceptance rules, health mutations, revisions, signals and
## death lifecycles are covered together with the numeric result.

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
const LINGLAN_SCENE := preload(
	"res://scene/boss/linglan/linglan_boss.tscn"
)
const LINGLAN_CONFIG := preload(
	"res://resources/config/enemies/linglan_boss.tres"
)
const GOAT_HORN := preload(
	"res://resources/config/collectibles/collectible_goat_horn.tres"
)
const EXECUTE_COLLECTIBLES := [
	GOAT_HORN,
	preload("res://resources/config/collectibles/collectible_obsidian_key.tres"),
	preload("res://resources/config/collectibles/collectible_kingslayer_blade.tres"),
	preload("res://resources/config/collectibles/collectible_void_crown.tres"),
]
const TEST_RUNTIME_SCENE := preload(
	"res://dev_tools/fixtures/enemy_gameplay_gateway_test_runtime.tscn"
)

var failures: Array[String] = []
var test_root: EnemyGameplayGatewayTestRuntime


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	test_root = (
		TEST_RUNTIME_SCENE.instantiate()
		as EnemyGameplayGatewayTestRuntime
	)
	test_root.name = "DamagePipelineSmokeTest"
	test_root.runtime_mode = CombatRuntimeBase.RuntimeMode.SINGLEPLAYER
	root.add_child(test_root)
	current_scene = test_root

	await _test_legacy_wrapper_equivalence()
	await _test_enemy_numeric_contract()
	await _test_player_numeric_and_periodic_contract()
	await _test_plant_authority_revision_and_bypass_contract()
	await _test_overkill_and_single_lethal_contract()
	await _test_collectible_execute_contract()
	await _test_linglan_health_signal_contract()

	test_root.queue_free()
	for _cleanup_frame in range(6):
		await process_frame
		await physics_frame

	if failures.is_empty():
		print("DAMAGE_PIPELINE_SMOKE_TEST_OK")
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	quit(1)


func _test_legacy_wrapper_equivalence() -> void:
	var enemy_config := _make_enemy_config(100, 7, 25)
	var legacy_enemy := _spawn_enemy(enemy_config)
	var request_enemy := _spawn_enemy(enemy_config)
	var legacy_enemy_accepted := legacy_enemy.apply_damage(
		31,
		Vector2.LEFT,
		EnemyConfig.DamageType.MAGIC,
		false
	)
	var enemy_request := DamageRequest.new(
		31,
		CombatTypes.DamageType.MAGIC
	)
	enemy_request.with_directions(Vector2.LEFT)
	enemy_request.with_flag(CombatTypes.DamageFlag.SUPPRESS_HIT_PARTICLES)
	var enemy_result := request_enemy.apply_combat_damage(enemy_request)
	_expect(
		legacy_enemy_accepted == enemy_result.accepted
		and legacy_enemy.current_health == request_enemy.current_health
		and legacy_enemy.last_damage_result.applied_damage == enemy_result.applied_damage
		and legacy_enemy.last_damage_taken == enemy_result.applied_damage,
		"Enemy legacy apply_damage must be a behavior-preserving wrapper around apply_combat_damage."
	)

	var legacy_player := await _spawn_player()
	var request_player := await _spawn_player()
	for player in [legacy_player, request_player]:
		_prepare_player(player, 100, 4, 0)
		player.collectible_ranged_front_damage_multiplier = 0.6
	var legacy_player_accepted := legacy_player.apply_damage(
		13,
		EnemyConfig.DamageType.PHYSICAL,
		{
			"is_ranged": true,
			"source_direction": Vector2.RIGHT,
		}
	)
	var player_request := DamageRequest.new(
		13,
		CombatTypes.DamageType.PHYSICAL
	)
	_with_hostile_source(player_request)
	player_request.with_flag(CombatTypes.DamageFlag.RANGED)
	player_request.with_directions(Vector2.LEFT, Vector2.RIGHT)
	var player_result := request_player.apply_combat_damage(player_request)
	_expect(
		legacy_player_accepted == player_result.accepted
		and legacy_player.current_health == request_player.current_health
		and legacy_player.last_damage_result.applied_damage == player_result.applied_damage
		and legacy_player.last_damage_taken == player_result.applied_damage,
		"Player legacy apply_damage must preserve the unified ranged-direction result."
	)

	var legacy_plant := _spawn_agave()
	var request_plant := _spawn_agave()
	var hostile_plant_source := _spawn_enemy(_make_enemy_config(10, 0, 0))
	var legacy_plant_accepted := legacy_plant.receive_damage(
		19,
		hostile_plant_source,
		Vector2.DOWN,
		EnemyConfig.DamageType.MAGIC
	)
	var plant_request := DamageRequest.new(
		19,
		CombatTypes.DamageType.MAGIC
	)
	_with_hostile_source(plant_request)
	plant_request.with_directions(Vector2.DOWN)
	var plant_result := request_plant.apply_combat_damage(plant_request)
	_expect(
		legacy_plant_accepted == plant_result.accepted
		and legacy_plant.current_health == request_plant.current_health
		and legacy_plant.last_damage_result.applied_damage == plant_result.applied_damage,
		"Plant legacy receive_damage must be a behavior-preserving wrapper around apply_combat_damage."
	)

	_free_fixtures([
		legacy_enemy,
		request_enemy,
		legacy_player,
		request_player,
		legacy_plant,
		request_plant,
		hostile_plant_source,
	])
	await process_frame


func _test_enemy_numeric_contract() -> void:
	var enemy := _spawn_enemy(_make_enemy_config(100, 999, 100))
	var physical_minimum := enemy.apply_combat_damage(DamageRequest.new(
		7,
		CombatTypes.DamageType.PHYSICAL
	))
	var magic_minimum := enemy.apply_combat_damage(DamageRequest.new(
		400,
		CombatTypes.DamageType.MAGIC
	))
	_expect(
		physical_minimum.accepted
		and physical_minimum.applied_damage == 1
		and magic_minimum.accepted
		and magic_minimum.applied_damage == 1,
		"Enemy physical and magic mitigation must retain the one-damage minimum."
	)

	var nearest_enemy := _spawn_enemy(_make_enemy_config(100, 3, 0))
	nearest_enemy.add_damage_taken_multiplier_modifier(91001, 1.25)
	var nearest_result := nearest_enemy.apply_combat_damage(DamageRequest.new(
		9,
		CombatTypes.DamageType.PHYSICAL
	))
	_expect(
		nearest_result.adjusted_amount == 9
		and nearest_result.mitigated_damage == 6
		and nearest_result.resolved_damage == 8
		and nearest_result.applied_damage == 8,
		"Enemy taken-damage multipliers must run after defense and use nearest rounding; actual=%s."
		% _result_summary(nearest_result)
	)

	_free_fixtures([enemy, nearest_enemy])
	await process_frame


func _test_player_numeric_and_periodic_contract() -> void:
	var player := await _spawn_player()
	_prepare_player(player, 100, 2, 100)

	var physical_minimum := player.apply_combat_damage(_with_hostile_source(DamageRequest.new(
		2,
		CombatTypes.DamageType.PHYSICAL
	)))
	_prepare_player(player, 100, 0, 100)
	var magic_minimum := player.apply_combat_damage(_with_hostile_source(DamageRequest.new(
		100,
		CombatTypes.DamageType.MAGIC
	)))
	_expect(
		physical_minimum.applied_damage == 1
		and magic_minimum.applied_damage == 1,
		"Player physical and magic mitigation must retain the one-damage minimum; physical=%s magic=%s."
		% [_result_summary(physical_minimum), _result_summary(magic_minimum)]
	)

	_prepare_player(player, 100, 0, 0)
	player.add_damage_reduction_modifier(92001, 0.25)
	var reduction_result := player.apply_combat_damage(_with_hostile_source(DamageRequest.new(
		7,
		CombatTypes.DamageType.PHYSICAL
	)))
	_expect(
		reduction_result.mitigated_damage == 7
		and reduction_result.resolved_damage == 5
		and reduction_result.applied_damage == 5,
		"Player damage reduction must use the strongest post-mitigation source and floor rounding; actual=%s."
		% _result_summary(reduction_result)
	)

	_prepare_player(player, 100, 2, 0)
	player.facing_suffix = &"right"
	player.collectible_ranged_front_damage_multiplier = 0.5
	var ranged_request := DamageRequest.new(14, CombatTypes.DamageType.PHYSICAL)
	_with_hostile_source(ranged_request)
	ranged_request.with_flag(CombatTypes.DamageFlag.RANGED)
	ranged_request.with_directions(Vector2.LEFT, Vector2.RIGHT)
	var ranged_result := player.apply_combat_damage(ranged_request)
	_expect(
		ranged_result.adjusted_amount == 7
		and ranged_result.mitigated_damage == 5
		and ranged_result.applied_damage == 5,
		"Player directional ranged scaling must run before mitigation and use nearest rounding; actual=%s."
		% _result_summary(ranged_result)
	)

	_prepare_player(player, 50, 0, 0)
	player.invincibility_time_left = 3.25
	player.dodge_chance = 1.0
	player.collectible_ranged_dodge_chance = 1.0
	var periodic_request := DamageRequest.new(
		10,
		CombatTypes.DamageType.PHYSICAL
	)
	_with_hostile_source(periodic_request)
	periodic_request.flags = (
		CombatTypes.DamageFlag.PERIODIC
		| CombatTypes.DamageFlag.BYPASS_INVULNERABILITY
		| CombatTypes.DamageFlag.BYPASS_DODGE
		| CombatTypes.DamageFlag.NO_HIT_INVINCIBILITY
	)
	var periodic_result := player.apply_combat_damage(periodic_request)
	_expect(
		periodic_result.accepted
		and periodic_result.applied_damage == 10
		and player.current_health == 40
		and is_equal_approx(player.invincibility_time_left, 3.25),
		"Periodic flags must bypass invulnerability and dodge without refreshing hit invincibility; actual=%s health=%d invincibility=%.3f."
		% [_result_summary(periodic_result), player.current_health, player.invincibility_time_left]
	)

	player.invincibility_time_left = 0.0
	var periodic_legacy_accepted := player.apply_periodic_damage(
		4,
		EnemyConfig.DamageType.PHYSICAL
	)
	_expect(
		periodic_legacy_accepted
		and player.last_damage_result.applied_damage == 4
		and is_zero_approx(player.invincibility_time_left),
		"Legacy periodic damage must preserve bypass flags and must not grant new hit invincibility; actual=%s invincibility=%.3f."
		% [_result_summary(player.last_damage_result), player.invincibility_time_left]
	)

	var health_before_invulnerable_probe := player.current_health
	player.invincibility_time_left = 1.0
	var invulnerable_result := player.apply_combat_damage(
		_with_hostile_source(DamageRequest.new(5))
	)
	_expect(
		invulnerable_result.is_rejected_for(
			CombatTypes.DamageRejectionReason.INVULNERABLE
		)
		and player.current_health == health_before_invulnerable_probe,
		"Ordinary Player damage must expose INVULNERABLE without mutating health; actual=%s."
		% _result_summary(invulnerable_result)
	)

	player.queue_free()
	await process_frame


func _test_plant_authority_revision_and_bypass_contract() -> void:
	var plant := _spawn_agave()
	plant.physical_defense = 10
	plant.magic_defense = 20
	var initial_revision := plant.health_revision
	var physical_result := plant.apply_combat_damage(_with_hostile_source(DamageRequest.new(
		15,
		CombatTypes.DamageType.PHYSICAL
	)))
	var revision_after_physical := plant.health_revision
	var magic_result := plant.apply_combat_damage(_with_hostile_source(DamageRequest.new(
		10,
		CombatTypes.DamageType.MAGIC
	)))
	var revision_after_magic := plant.health_revision
	var bypass_request := DamageRequest.new(
		100,
		CombatTypes.DamageType.PHYSICAL
	)
	_with_hostile_source(bypass_request)
	bypass_request.with_flag(CombatTypes.DamageFlag.BYPASS_MITIGATION)
	var bypass_result := plant.apply_combat_damage(bypass_request)
	_expect(
		physical_result.applied_damage == 5
		and magic_result.applied_damage == 8
		and bypass_result.applied_damage == 100,
		"Plant damage must distinguish physical/magic mitigation and honor BYPASS_MITIGATION."
	)
	_expect(
		revision_after_physical == initial_revision + 1
		and revision_after_magic == revision_after_physical + 1
		and plant.health_revision == revision_after_magic + 1,
		"Each accepted Plant damage result must advance authoritative health revision exactly once."
	)

	var proxy := _spawn_agave()
	proxy.is_multiplayer_proxy = true
	var proxy_health := proxy.current_health
	var proxy_revision := proxy.health_revision
	var proxy_result := proxy.apply_combat_damage(DamageRequest.new(50))
	_expect(
		proxy_result.is_rejected_for(
			CombatTypes.DamageRejectionReason.NOT_AUTHORITY
		)
		and proxy.current_health == proxy_health
		and proxy.health_revision == proxy_revision,
		"Plant multiplayer proxies must explicitly reject damage as NOT_AUTHORITY without a revision."
	)
	var enemy_proxy := _spawn_enemy(_make_enemy_config(100, 0, 0))
	enemy_proxy.is_multiplayer_proxy = true
	var enemy_proxy_health := enemy_proxy.current_health
	var enemy_proxy_result := enemy_proxy.apply_combat_damage(
		DamageRequest.new(50)
	)
	_expect(
		enemy_proxy_result.is_rejected_for(
			CombatTypes.DamageRejectionReason.NOT_AUTHORITY
		)
		and enemy_proxy.current_health == enemy_proxy_health,
		"Enemy multiplayer proxies must share the canonical NOT_AUTHORITY sink contract."
	)

	_free_fixtures([plant, proxy, enemy_proxy])
	await process_frame


func _test_overkill_and_single_lethal_contract() -> void:
	var enemy := _spawn_enemy(_make_enemy_config(3, 0, 0))
	var enemy_deaths: Array[Enemy] = []
	enemy.defeated.connect(func(defeated_enemy: Enemy) -> void:
		enemy_deaths.append(defeated_enemy)
	)
	var enemy_lethal := enemy.apply_combat_damage(DamageRequest.new(99))
	var enemy_repeat := enemy.apply_combat_damage(DamageRequest.new(99))
	_expect(
		enemy_lethal.applied_damage == 3
		and enemy_lethal.health_after == 0
		and enemy_lethal.lethal
		and enemy_repeat.is_rejected_for(
			CombatTypes.DamageRejectionReason.TARGET_DEAD
		)
		and enemy_deaths.size() == 1,
		"Enemy overkill must cap applied damage and emit one death across repeated requests."
	)

	var player := await _spawn_player()
	_prepare_player(player, 4, 0, 0)
	var player_deaths: Array[bool] = []
	player.died.connect(func() -> void:
		player_deaths.append(true)
	)
	var player_lethal := player.apply_combat_damage(
		_with_hostile_source(DamageRequest.new(99))
	)
	var player_repeat := player.apply_combat_damage(
		_with_hostile_source(DamageRequest.new(99))
	)
	_expect(
		player_lethal.applied_damage == 4
		and player_lethal.lethal
		and player_repeat.is_rejected_for(
			CombatTypes.DamageRejectionReason.TARGET_DEAD
		)
		and player_deaths.size() == 1,
		"Player overkill must cap applied damage and emit one death across repeated requests."
	)

	var plant := _spawn_agave()
	plant.current_health = 5
	plant.physical_defense = 0
	var plant_revision := plant.health_revision
	var plant_deaths: Array[bool] = []
	plant.died.connect(func() -> void:
		plant_deaths.append(true)
	)
	var plant_lethal := plant.apply_combat_damage(
		_with_hostile_source(DamageRequest.new(99))
	)
	var plant_repeat := plant.apply_combat_damage(
		_with_hostile_source(DamageRequest.new(99))
	)
	_expect(
		plant_lethal.applied_damage == 5
		and plant_lethal.lethal
		and plant_repeat.is_rejected_for(
			CombatTypes.DamageRejectionReason.TARGET_DEAD
		)
		and plant.health_revision == plant_revision + 1
		and plant_deaths.size() == 1,
		"Plant overkill must cap damage, advance one revision and emit one death."
	)

	_free_fixtures([enemy, player, plant])
	await process_frame


func _test_linglan_health_signal_contract() -> void:
	var linglan := LINGLAN_SCENE.instantiate() as LinglanBoss
	_expect(linglan != null, "Linglan production scene must instantiate for damage pipeline coverage.")
	if linglan == null:
		return
	test_root.add_child(linglan)
	linglan.config = LINGLAN_CONFIG
	linglan.activate_boss(null, null)
	linglan.set_physics_process(false)
	var observations: Array[Vector2i] = []
	linglan.health_changed.connect(func(current: int, maximum: int) -> void:
		observations.append(Vector2i(current, maximum))
	)
	var result := linglan.apply_combat_damage(_with_player_allied_source(DamageRequest.new(
		125,
		CombatTypes.DamageType.PHYSICAL
	)))
	_expect(
		result.accepted
		and result.applied_damage == 95
		and observations.size() == 1
		and observations[0] == Vector2i(
			LINGLAN_CONFIG.max_health - 95,
			LINGLAN_CONFIG.max_health
		),
		"Linglan _on_combat_damage_applied must preserve one accurate boss health signal."
	)
	linglan.queue_free()
	await process_frame


func _test_collectible_execute_contract() -> void:
	_expect(
		GOAT_HORN.collectible_rarity == PickupConfig.CollectibleRarity.COMMON
		and is_equal_approx(GOAT_HORN.on_hit_chance, 0.14)
		and is_equal_approx(GOAT_HORN.on_hit_execute_health_ratio, 0.03),
		"Goat Horn must remain common with a 14% proc chance and an exact 3% execute threshold."
	)

	var player := await _spawn_player()
	var normal_enemy := _spawn_enemy(_make_enemy_config(100, 0, 0))
	_expect(not normal_enemy.is_boss_enemy(), "A regular enemy must not be classified as a Boss.")
	var goat_probe := GOAT_HORN.duplicate() as PickupConfig
	goat_probe.on_hit_chance = 1.0
	var goat_cooldown_key := str(player.call(
		"_get_collectible_aux_key",
		goat_probe,
		"hit:%s" % goat_probe.on_hit_effect_id
	))
	normal_enemy.current_health = 4
	player.collectible_trigger_deadlines.erase(goat_cooldown_key)
	player.call("_apply_collectible_on_hit_effect", goat_probe, normal_enemy, 1)
	_expect(
		normal_enemy.current_health == 4 and not normal_enemy.is_dead,
		"Goat Horn must not execute a regular enemy above the 3% health threshold."
	)
	normal_enemy.current_health = 3
	player.collectible_trigger_deadlines.erase(goat_cooldown_key)
	player.call("_apply_collectible_on_hit_effect", goat_probe, normal_enemy, 1)
	_expect(
		normal_enemy.is_dead,
		"Goat Horn must still execute a regular enemy at the exact 3% health threshold."
	)

	var linglan := LINGLAN_SCENE.instantiate() as LinglanBoss
	_expect(linglan != null, "Linglan must instantiate for execute-immunity coverage.")
	if linglan != null:
		test_root.add_child(linglan)
		linglan.config = LINGLAN_CONFIG
		linglan.activate_boss(null, null)
		linglan.set_process(false)
		linglan.set_physics_process(false)
		_expect(linglan.is_boss_enemy(), "Linglan must expose the authoritative Boss identity.")
		for source_variant in EXECUTE_COLLECTIBLES:
			var source := source_variant as PickupConfig
			var execute_probe := source.duplicate() as PickupConfig
			execute_probe.on_hit_chance = 1.0
			var cooldown_key := str(player.call(
				"_get_collectible_aux_key",
				execute_probe,
				"hit:%s" % execute_probe.on_hit_effect_id
			))
			player.collectible_trigger_deadlines.erase(cooldown_key)
			linglan.current_health = 1
			linglan.last_damage_taken = 0
			var revision_before := linglan.health_revision
			player.call("_apply_collectible_on_hit_effect", execute_probe, linglan, 1)
			_expect(
				linglan.current_health == 1
				and not linglan.is_dead
				and linglan.last_damage_taken == 0
				and linglan.health_revision == revision_before,
				"%s must not execute or damage a Boss." % source.display_name
			)
			_expect(
				not player.collectible_trigger_deadlines.has(cooldown_key),
				"%s must not roll or consume its execute cooldown on a Boss." % source.display_name
			)
		linglan.queue_free()

	player.queue_free()
	normal_enemy.queue_free()
	await process_frame


func _make_enemy_config(
	max_health: int,
	physical_defense: int,
	magic_defense: int
) -> EnemyConfig:
	var config := ENEMY_CONFIG.duplicate(true) as EnemyConfig
	config.max_health = max_health
	config.physical_defense = physical_defense
	config.magic_defense = magic_defense
	config.xirang_kill_reward = 0
	config.drop_table = null
	return config


func _spawn_enemy(config: EnemyConfig) -> Enemy:
	var enemy := config.enemy_scene.instantiate() as Enemy
	test_root.add_child(enemy)
	enemy.setup(config, null)
	enemy.set_process(false)
	enemy.set_physics_process(false)
	return enemy


func _spawn_player() -> Player:
	var player := PLAYER_SCENE.instantiate() as Player
	test_root.add_child(player)
	test_root.bind_player_runtime_context(player)
	await process_frame
	player.set_process(false)
	player.set_physics_process(false)
	return player


func _prepare_player(
	player: Player,
	health: int,
	physical_defense: int,
	magic_defense: int
) -> void:
	player.max_health = maxi(health, 1)
	player.current_health = maxi(health, 1)
	player.physical_defense = physical_defense
	player.magic_defense = magic_defense
	player.is_dead = false
	player.invincibility_time_left = 0.0
	player.dash_time_left = 0.0
	player.multiplayer_dash_protection_time_left = 0.0
	player.dodge_chance = 0.0
	player.collectible_ranged_dodge_chance = 0.0
	player.damage_reduction_modifiers.clear()
	player.health_bar.set_health(player.current_health, player.max_health)


func _spawn_agave() -> AgaveCannon:
	var plant := AGAVE_SCENE.instantiate() as AgaveCannon
	test_root.add_child(plant)
	var config := AGAVE_CONFIG.duplicate(true) as PlantDefenseConfig
	plant.setup(config, null, [Vector2i.ZERO])
	plant.attack_timer.stop()
	plant.set_process(false)
	plant.set_physics_process(false)
	return plant


func _free_fixtures(fixtures: Array) -> void:
	for fixture in fixtures:
		if fixture != null and is_instance_valid(fixture):
			(fixture as Node).queue_free()


func _with_player_allied_source(request: DamageRequest) -> DamageRequest:
	request.with_source_snapshot(DamageSourceSnapshot.create(
		CombatRelationService.PLAYER_ALLIED,
		1,
		1,
		1,
		&"damage_pipeline_player_probe"
	))
	return request


func _with_hostile_source(request: DamageRequest) -> DamageRequest:
	request.with_source_snapshot(DamageSourceSnapshot.create(
		CombatRelationService.HOSTILE_WAVE,
		0,
		2,
		2,
		&"damage_pipeline_enemy_probe"
	))
	return request


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)


func _result_summary(result: DamageResult) -> String:
	if result == null:
		return "<null>"
	return (
		"accepted=%s rejection=%d requested=%d adjusted=%d mitigated=%d resolved=%d applied=%d health=%d->%d lethal=%s"
		% [
			result.accepted,
			result.rejection_reason,
			result.requested_amount,
			result.adjusted_amount,
			result.mitigated_damage,
			result.resolved_damage,
			result.applied_damage,
			result.health_before,
			result.health_after,
			result.lethal,
		]
	)
