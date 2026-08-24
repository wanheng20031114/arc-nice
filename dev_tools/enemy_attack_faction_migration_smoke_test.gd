extends SceneTree

## Stage-five vertical smoke: concrete enemy weapons must retain launch-time
## faction attribution, rebind network event IDs, clear pooled attribution and
## resolve dynamic Enemy targets through the same authoritative sinks.

const RUNTIME_SCENE := preload(
	"res://dev_tools/fixtures/enemy_gameplay_gateway_test_runtime.tscn"
)
const PLAYER_SCENE := preload(
	"res://scene/player/weishidaier/player_weishidaier.tscn"
)
const TARGET_CONFIG := preload(
	"res://resources/config/enemies/yuanshi_insect_basic.tres"
)
const RANGED_SOURCE_CONFIG := preload(
	"res://resources/config/enemies/capoo_smg.tres"
)
const BOMBER_CONFIG := preload(
	"res://resources/config/enemies/yuanshi_insect_bomber.tres"
)
const MELEE_ROBOT_SPECS := [
	{
		"label": "战斗机器人",
		"config": preload(
			"res://resources/config/enemies/combat_robot.tres"
		),
		"dash": true,
	},
	{
		"label": "忍者战斗机器人",
		"config": preload(
			"res://resources/config/enemies/combat_robot_ninja.tres"
		),
		"dash": false,
	},
	{
		"label": "举盾战斗机器人",
		"config": preload(
			"res://resources/config/enemies/combat_robot_shield_bearer.tres"
		),
		"dash": false,
	},
]

const PROJECTILE_SPECS := [
	{
		"name": &"ak",
		"type": &"capoo_ak47_bullet",
		"scene": preload("res://scene/enemy/capoo/capoo_ak47_bullet.tscn"),
	},
	{
		"name": &"gunner",
		"type": &"combat_robot_gunner_bullet",
		"scene": preload(
			"res://scene/enemy/mechanical_life/combat_robot_gunner_bullet.tscn"
		),
	},
	{
		"name": &"smg",
		"type": &"capoo_smg_bullet",
		"scene": preload("res://scene/enemy/capoo/capoo_smg_bullet.tscn"),
	},
	{
		"name": &"rpg",
		"type": &"capoo_rpg_rocket",
		"scene": preload("res://scene/enemy/capoo/capoo_rpg_rocket.tscn"),
	},
	{
		"name": &"mage",
		"type": &"capoo_mage_fireball",
		"scene": preload("res://scene/enemy/capoo/capoo_mage_fireball.tscn"),
	},
	{
		"name": &"fire",
		"type": &"fire_sorcerer_fireball_volley",
		"scene": preload(
			"res://scene/enemy/sorcerer/fire_sorcerer_fireball_volley.tscn"
		),
	},
	{
		"name": &"frost",
		"type": &"frost_sorcerer_ice_spike",
		"scene": preload(
			"res://scene/enemy/sorcerer/frost_sorcerer_ice_spike.tscn"
		),
	},
	{
		"name": &"drone",
		"type": &"combat_robot_suicide_drone",
		"scene": preload(
			"res://scene/enemy/mechanical_life/combat_robot_suicide_drone.tscn"
		),
	},
	{
		"name": &"yuanshi",
		"type": &"yuanshi_fire_projectile",
		"scene": preload(
			"res://scene/enemy/yuanshi_insect/yuanshi_insect_fire_projectile.tscn"
		),
	},
]

const SOURCE_CONTRACTS := {
	"res://scene/enemy/capoo/capoo_ak47.gd": [
		"launch_source_snapshot := create_damage_source_snapshot(",
		"RapidFireSimulationService.AK_SOURCE_TYPE",
	],
	"res://scene/enemy/mechanical_life/combat_robot_gunner.gd": [
		"create_damage_source_snapshot(",
	],
	"res://scene/enemy/capoo/capoo_smg.gd": [
		"&\"capoo_smg_hitscan\"",
		"source_snapshot",
	],
	"res://scene/enemy/capoo/capoo_sniper.gd": [
		"lock_damage_source_snapshot = create_damage_source_snapshot(",
	],
	"res://scene/enemy/capoo/capoo_knight.gd": [
		"slash_damage_source_snapshot = create_damage_source_snapshot(",
	],
	"res://scene/enemy/sorcerer/lightning_sorcerer.gd": [
		"cast_damage_source_snapshot = create_damage_source_snapshot(",
	],
	"res://scene/enemy/mechanical_life/combat_robot_main_battle_elite.gd": [
		"action_damage_source_snapshot = create_damage_source_snapshot(",
	],
	"res://scene/enemy/capoo/capoo_rpg.gd": [
		"create_damage_source_snapshot(",
		"&\"capoo_rpg_rocket\"",
	],
	"res://scene/enemy/capoo/capoo_mage.gd": [
		"create_damage_source_snapshot(",
		"&\"capoo_mage_fireball\"",
	],
	"res://scene/enemy/sorcerer/fire_sorcerer.gd": [
		"create_damage_source_snapshot(",
	],
	"res://scene/enemy/sorcerer/frost_sorcerer.gd": [
		"create_damage_source_snapshot(",
	],
	"res://scene/enemy/mechanical_life/combat_robot_drone_operator.gd": [
		"create_damage_source_snapshot(",
	],
	"res://scene/enemy/slime/slime.gd": [
		"_on_touch_damage_applied(",
		"source_snapshot: DamageSourceSnapshot",
	],
	"res://scene/enemy/yuanshi_insect/yuanshi_insect_fire_ranged.gd": [
		"create_damage_source_snapshot(",
		"&\"yuanshi_fire_projectile\"",
	],
	"res://scene/enemy/yuanshi_insect/yuanshi_insect_exploder.gd": [
		"outgoing_explosion_source_snapshot",
		"hit_enemy.apply_combat_damage(enemy_request)",
	],
}

var failures: Array[String] = []
var runtime: EnemyGameplayGatewayTestRuntime
var projectile_coordinator: MpProjectileCoordinator
var player: Player
var next_network_enemy_id := 1000


func _init() -> void:
	call_deferred(&"_run")


func _run() -> void:
	runtime = RUNTIME_SCENE.instantiate() as EnemyGameplayGatewayTestRuntime
	root.add_child(runtime)
	current_scene = runtime
	await process_frame

	projectile_coordinator = MpProjectileCoordinator.new()
	projectile_coordinator.bind_runtime(runtime)
	player = PLAYER_SCENE.instantiate() as Player
	runtime.add_child(player)
	await process_frame
	player.bind_combat_runtime(runtime)
	_prepare_player(player)

	await _test_projectile_registration_and_pool_reuse()
	_test_direct_attack_enemy_targets()
	await _test_ranged_automatic_targeting()
	await _test_melee_robot_dynamic_enemy_targets()
	await _test_yuanshi_explosion_enemy_targets()
	_test_source_contracts()

	current_scene = null
	runtime.queue_free()
	projectile_coordinator.free()
	for _cleanup_frame in range(4):
		await process_frame
		await physics_frame

	if failures.is_empty():
		print("ENEMY_ATTACK_FACTION_MIGRATION_SMOKE_OK")
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	quit(1)


func _test_projectile_registration_and_pool_reuse() -> void:
	for spec_variant in PROJECTILE_SPECS:
		var spec := spec_variant as Dictionary
		var projectile := (spec["scene"] as PackedScene).instantiate()
		runtime.enemy_container.add_child(projectile)
		await process_frame
		projectile.call(
			&"bind_gameplay_context",
			runtime,
			runtime.get_multiplayer_gameplay_gateway()
		)
		var source_type := spec["type"] as StringName
		var launch_snapshot := DamageSourceSnapshot.create(
			CombatRelationService.HOSTILE_WAVE,
			7,
			99,
			0,
			source_type
		)
		_configure_projectile(spec["name"] as StringName, projectile, launch_snapshot)
		var projectile_id := projectile_coordinator.register_local_projectile(
			projectile,
			source_type,
			0,
			5,
			1.0,
			false,
			true,
			1.0
		)
		var retained_snapshot := projectile.get("damage_source_snapshot") as DamageSourceSnapshot
		var meta_snapshot := projectile.get_meta(
			&"damage_source_snapshot",
			null
		) as DamageSourceSnapshot
		var record_snapshot := (
			projectile_coordinator.get_projectile_damage_source_snapshot(
				projectile_id
			)
		)
		_expect(
			projectile_id > 0
			and retained_snapshot != null
			and meta_snapshot != null
			and record_snapshot != null
			and retained_snapshot.event_source_id == projectile_id
			and meta_snapshot.event_source_id == projectile_id
			and record_snapshot.event_source_id == projectile_id
			and retained_snapshot.source_faction_id
				== CombatRelationService.HOSTILE_WAVE
			and retained_snapshot.credit_peer_id == 7
			and retained_snapshot.instigator_entity_id == 99
			and retained_snapshot.source_type == source_type,
			"%s Host registration must rebind field/meta/record to projectile_id."
				% String(spec["name"])
		)
		if spec["name"] == &"ak":
			_test_registered_projectile_player_sink(projectile, projectile_id)
		if spec["name"] == &"fire":
			_test_fire_ball_subtype_snapshot(projectile, projectile_id)

		projectile.call(&"on_pool_released", 1)
		_expect(
			projectile.get("damage_source_snapshot") == null
			and not projectile.has_meta(&"damage_source_snapshot"),
			"%s pool release must clear the previous source snapshot."
				% String(spec["name"])
		)
		projectile.call(&"on_pool_acquired", 2)
		var reused_snapshot := DamageSourceSnapshot.create(
			CombatRelationService.PLAYER_ALLIED,
			17,
			199,
			0,
			source_type
		)
		_configure_projectile(spec["name"] as StringName, projectile, reused_snapshot)
		var reused_projectile_id := projectile_id + 500000
		projectile.call(
			&"setup_multiplayer",
			reused_projectile_id,
			0,
			source_type
		)
		var reused_retained := projectile.get(
			"damage_source_snapshot"
		) as DamageSourceSnapshot
		var reused_meta := projectile.get_meta(
			&"damage_source_snapshot",
			null
		) as DamageSourceSnapshot
		_expect(
			reused_retained != null
			and reused_meta != null
			and reused_retained.event_source_id == reused_projectile_id
			and reused_meta.event_source_id == reused_projectile_id
			and reused_retained.source_faction_id
				== CombatRelationService.PLAYER_ALLIED
			and reused_retained.credit_peer_id == 17
			and reused_retained.instigator_entity_id == 199,
			"%s pool reuse must retain only the new launch attribution."
				% String(spec["name"])
		)
		projectile.call(&"on_pool_released", 2)
		projectile.queue_free()


func _configure_projectile(
	projectile_name: StringName,
	projectile: Node,
	source_snapshot: DamageSourceSnapshot
) -> void:
	match projectile_name:
		&"ak", &"gunner", &"smg":
			projectile.call(
				&"setup",
				Vector2.RIGHT,
				5,
				100.0,
				1.0,
				null,
				null,
				source_snapshot
			)
		&"rpg":
			projectile.call(
				&"setup",
				Vector2.RIGHT,
				5,
				100.0,
				1.0,
				24.0,
				source_snapshot
			)
		&"mage":
			projectile.call(
				&"setup",
				Vector2.RIGHT,
				5,
				100.0,
				1.0,
				12.0,
				null,
				0.65,
				source_snapshot
			)
		&"fire":
			projectile.call(
				&"setup",
				Vector2.RIGHT,
				5,
				100.0,
				1.0,
				null,
				6.0,
				runtime,
				-1.0,
				-1,
				source_snapshot
			)
		&"frost", &"yuanshi":
			projectile.call(
				&"setup",
				Vector2.RIGHT,
				5,
				100.0,
				1.0,
				source_snapshot
			)
		&"drone":
			projectile.call(
				&"setup",
				Vector2.RIGHT,
				5,
				100.0,
				1.0,
				24.0,
				null,
				source_snapshot
			)


func _test_registered_projectile_player_sink(
	projectile: Node,
	projectile_id: int
) -> void:
	_prepare_player(player)
	var health_before := player.current_health
	var request := projectile.call(
		&"_make_damage_request",
		Vector2.RIGHT,
		Vector2.LEFT
	) as DamageRequest
	var result := player.apply_combat_damage(request)
	_expect(
		result.accepted
		and player.current_health < health_before
		and request.get_or_create_source_snapshot().event_source_id
			== projectile_id,
		"Registered enemy projectile must carry a nonzero event ID into Player sink."
	)


func _test_fire_ball_subtype_snapshot(
	projectile: Node,
	projectile_id: int
) -> void:
	var request := projectile.call(
		&"_make_ball_damage_request",
		player,
		1
	) as DamageRequest
	var snapshot := request.get_or_create_source_snapshot()
	_expect(
		snapshot.event_source_id == projectile_id
		and snapshot.source_type
			== projectile.call(&"_get_ball_source_type", 1),
		"FireVolley A/B/C requests must keep projectile event ID and per-ball subtype."
	)


func _test_direct_attack_enemy_targets() -> void:
	var target := _spawn_enemy(TARGET_CONFIG, Vector2(24.0, 0.0))
	var knight := CapooKnight.new()
	knight.combat_runtime = runtime
	knight.combat_relation_service = runtime.get_combat_relation_service()
	knight.set_combat_faction_id(
		CombatRelationService.PLAYER_ALLIED,
		-1,
		true
	)
	knight.slash_damage_source_snapshot = knight.create_damage_source_snapshot(
		101,
		&"capoo_knight_slash"
	)
	knight.set_combat_faction_id(
		CombatRelationService.HOSTILE_WAVE,
		-1,
		true
	)
	var health_before := target.current_health
	var knight_applied := bool(knight.call(
		&"_dispatch_slash_damage",
		target,
		5,
		Vector2.RIGHT
	))
	_expect(
		knight_applied
		and target.current_health < health_before
		and target.last_damage_result.request.get_or_create_source_snapshot(
		).source_faction_id == CombatRelationService.PLAYER_ALLIED,
		"Knight slash must damage Enemy using faction frozen before source mutation."
	)
	var friendly_health := target.current_health
	knight.slash_damage_source_snapshot = DamageSourceSnapshot.create(
		CombatRelationService.HOSTILE_WAVE,
		0,
		1,
		102,
		&"capoo_knight_slash"
	)
	_expect(
		not bool(knight.call(
			&"_dispatch_slash_damage",
			target,
			5,
			Vector2.RIGHT
		))
		and target.current_health == friendly_health,
		"Knight slash must reject same-faction Enemy without damage."
	)

	var swordsman := CapooSwordsman.new()
	swordsman.slash_damage_source_snapshot = DamageSourceSnapshot.create(
		CombatRelationService.PLAYER_ALLIED,
		0,
		2,
		103,
		&"capoo_swordsman_slash"
	)
	var swordsman_request := swordsman.call(
		&"_make_slash_damage_request",
		5,
		Vector2.RIGHT
	) as DamageRequest
	_expect(
		swordsman_request.get_or_create_source_snapshot().source_type
			== &"capoo_swordsman_slash",
		"Swordsman inheritance must retain the slash source snapshot."
	)

	var lightning := LightningSorcerer.new()
	lightning.combat_runtime = runtime
	lightning.combat_relation_service = runtime.get_combat_relation_service()
	lightning.cast_damage_source_snapshot = DamageSourceSnapshot.create(
		CombatRelationService.PLAYER_ALLIED,
		0,
		3,
		104,
		&"lightning_sorcerer"
	)
	health_before = target.current_health
	_expect(
		bool(lightning.call(
			&"_apply_chain_damage",
			target,
			5,
			104,
			Vector2.ZERO
		))
		and target.current_health < health_before,
		"Lightning initial/chain resolver must damage a hostile Enemy."
	)

	var main_battle := CombatRobotMainBattleElite.new()
	main_battle.combat_runtime = runtime
	main_battle.combat_relation_service = runtime.get_combat_relation_service()
	main_battle.action_damage_source_snapshot = DamageSourceSnapshot.create(
		CombatRelationService.PLAYER_ALLIED,
		0,
		4,
		105,
		&"combat_robot_main_battle_attack"
	)
	health_before = target.current_health
	_expect(
		bool(main_battle.call(
			&"_dispatch_target_damage",
			target,
			5,
			&"combat_robot_main_battle_attack",
			Vector2.RIGHT,
			false,
			false
		))
		and target.current_health < health_before,
		"MainBattle fan/circle resolver must damage a hostile Enemy."
	)

	var sniper := CapooSniper.new()
	sniper.lock_damage_source_snapshot = DamageSourceSnapshot.create(
		CombatRelationService.PLAYER_ALLIED,
		0,
		6,
		107,
		&"capoo_sniper_lock"
	)
	var sniper_request := sniper.call(
		&"_make_lock_damage_request",
		5,
		Vector2.RIGHT
	) as DamageRequest
	health_before = target.current_health
	_expect(
		target.apply_combat_damage(sniper_request).accepted
		and target.current_health < health_before,
		"Sniper direct request must damage a hostile Enemy."
	)

	knight.free()
	swordsman.free()
	lightning.free()
	main_battle.free()
	sniper.free()
	target.queue_free()


func _test_ranged_automatic_targeting() -> void:
	var source := _spawn_enemy(
		RANGED_SOURCE_CONFIG,
		Vector2.ZERO
	) as CapooSMG
	var retained := _spawn_enemy(TARGET_CONFIG, Vector2(100.0, 0.0))
	var challenger := _spawn_enemy(TARGET_CONFIG, Vector2(80.0, 0.0))
	source.set_combat_faction_id(
		CombatRelationService.PLAYER_ALLIED,
		-1,
		true
	)
	var coordinator := TowerDefenseEnemyCoordinator.new()
	coordinator._runtime = runtime
	coordinator.assign_enemy_targets(source, source.global_position)
	_expect(
		source.supports_dynamic_enemy_targeting()
		and source.get_automatic_combat_target() == challenger,
		"Ranged family must opt in and automatically acquire the nearest hostile Enemy."
	)

	# Establish the farther target, then prove a merely 20% closer challenger is
	# retained by the authored 25% hysteresis while a 30% closer one replaces it.
	source.clear_automatic_combat_target()
	source.consider_automatic_combat_target(retained, 1)
	coordinator.assign_enemy_targets(source, source.global_position)
	_expect(
		source.get_automatic_combat_target() == retained,
		"A 20% closer ranged Enemy candidate must not defeat 25% hysteresis."
	)
	challenger.global_position = Vector2(70.0, 0.0)
	coordinator.assign_enemy_targets(source, source.global_position)
	_expect(
		source.get_automatic_combat_target() == challenger,
		"A ranged Enemy candidate over 25% closer must replace the retained target."
	)

	var lethal_request := DamageRequest.new(
		challenger.current_health,
		CombatTypes.DamageType.PHYSICAL
	).with_source_snapshot(DamageSourceSnapshot.create(
		CombatRelationService.PLAYER_ALLIED,
		0,
		0,
		108,
		&"ranged_target_death_probe"
	))
	var lethal_result := challenger.apply_combat_damage(lethal_request)
	coordinator.assign_enemy_targets(source, source.global_position)
	_expect(
		lethal_result.lethal
		and source.get_automatic_combat_target() == retained,
		"Ranged target death must immediately fall back to the next hostile Enemy."
	)
	coordinator.free()
	source.queue_free()
	retained.queue_free()
	challenger.queue_free()
	await process_frame


func _test_melee_robot_dynamic_enemy_targets() -> void:
	var coordinator := TowerDefenseEnemyCoordinator.new()
	coordinator._runtime = runtime
	for spec_index in range(MELEE_ROBOT_SPECS.size()):
		var spec := MELEE_ROBOT_SPECS[spec_index] as Dictionary
		var label := String(spec["label"])
		var source_position := Vector2(4000.0 + spec_index * 1000.0, 0.0)
		var source := _spawn_enemy(
			spec["config"] as EnemyConfig,
			source_position
		)
		var target := _spawn_enemy(
			TARGET_CONFIG,
			source_position + Vector2(80.0, 0.0)
		)
		var previous_faction_revision := source.get_faction_revision()
		var switched_faction := source.set_combat_faction_id(
			CombatRelationService.PLAYER_ALLIED,
			-1,
			true
		)
		coordinator.assign_enemy_targets(source, source.global_position)
		_expect(
			switched_faction
			and source.get_faction_revision() > previous_faction_revision
			and source.supports_dynamic_enemy_targeting()
			and source.get_automatic_combat_target() == target
			and source.objective_target == target
			and source.get_attackable_objective() == target,
			"%s切换玩家阵营后必须由正式目标协调器选择最近的敌对Enemy。"
				% label
		)

		if bool(spec["dash"]):
			var robot := source as CombatRobot
			var expected_dash_direction := source.global_position.direction_to(
				target.global_position
			)
			var preferred_target := robot.call(
				&"_get_preferred_ranged_combat_target"
			) as Node2D
			var started_windup := bool(robot.call(&"_try_start_windup"))
			_expect(
				preferred_target == target
				and started_windup
				and robot.combat_state == CombatRobot.CombatState.WINDUP
				and robot.dash_direction.dot(expected_dash_direction) > 0.999,
				"战斗机器人冲刺必须从通用动态目标解析敌对Enemy及其方向。"
			)
			robot.call(&"_reset_dash_state", false)

		var contact_radius := (
			maxf(
				source.touch_damage_extent_radius,
				source.body_collision_extent_radius
			)
			+ target.body_collision_extent_radius
		)
		target.global_position = source.global_position + Vector2(
			maxf(contact_radius - 0.25, 0.0),
			0.0
		)
		var health_before := target.current_health
		source.touch_damage_cooldown_left = 0.0
		source._update_touch_damage(1.0 / 60.0)
		var applied_snapshot := (
			target.last_damage_result.request.get_or_create_source_snapshot()
			if target.last_damage_result != null
				and target.last_damage_result.request != null
			else null
		) as DamageSourceSnapshot
		_expect(
			contact_radius > 0.0
			and target.current_health < health_before
			and applied_snapshot != null
			and applied_snapshot.source_faction_id
				== CombatRelationService.PLAYER_ALLIED,
			"%s必须沿正式接触伤害链攻击敌对Enemy，并冻结玩家阵营来源。"
				% label
		)

		_unregister_and_queue_enemy(source)
		_unregister_and_queue_enemy(target)
		await process_frame
	coordinator.free()


func _test_yuanshi_explosion_enemy_targets() -> void:
	var exploder := _spawn_enemy(
		BOMBER_CONFIG,
		Vector2(2000.0, 2000.0)
	) as YuanshiInsectExploder
	var hostile_target := _spawn_enemy(
		TARGET_CONFIG,
		exploder.global_position
	)
	var friendly_target := _spawn_enemy(
		TARGET_CONFIG,
		exploder.global_position + Vector2(1.0, 0.0)
	)
	exploder.set_combat_faction_id(
		CombatRelationService.PLAYER_ALLIED,
		-1,
		true
	)
	friendly_target.set_combat_faction_id(
		CombatRelationService.PLAYER_ALLIED,
		-1,
		true
	)
	exploder.outgoing_explosion_damage_snapshot = 5
	exploder.outgoing_explosion_source_snapshot = (
		exploder.create_damage_source_snapshot(109, &"yuanshi_explosion")
	)
	exploder.set_combat_faction_id(
		CombatRelationService.HOSTILE_WAVE,
		-1,
		true
	)
	var hostile_health := hostile_target.current_health
	var friendly_health := friendly_target.current_health
	var hostile_applied := bool(exploder.call(
		&"_try_apply_explosion_damage_to_enemy",
		hostile_target
	))
	var friendly_applied := bool(exploder.call(
		&"_try_apply_explosion_damage_to_enemy",
		friendly_target
	))
	_expect(
		hostile_applied
		and not friendly_applied
		and hostile_target.current_health < hostile_health
		and friendly_target.current_health == friendly_health,
		(
			"Yuanshi explosion must use frozen faction against Enemy and ignore allies "
			+ "(hostile %d/%d, friendly %d/%d)."
			% [
				hostile_target.current_health,
				hostile_health,
				friendly_target.current_health,
				friendly_health,
			]
		)
	)
	exploder.queue_free()
	hostile_target.queue_free()
	friendly_target.queue_free()


func _test_source_contracts() -> void:
	for path_variant in SOURCE_CONTRACTS:
		var path := String(path_variant)
		var source := FileAccess.get_file_as_string(path)
		var required_tokens := SOURCE_CONTRACTS[path_variant] as Array
		for token_variant in required_tokens:
			var token := String(token_variant)
			_expect(
				source.contains(token),
				"Concrete source contract missing in %s: %s" % [path, token]
			)
	var exploder_source := FileAccess.get_file_as_string(
		"res://scene/enemy/yuanshi_insect/yuanshi_insect_exploder.gd"
	)
	_expect(
		not exploder_source.contains("hit_enemy.apply_damage("),
		"Yuanshi explosion must not retain the legacy Enemy.apply_damage path."
	)


func _spawn_enemy(config_resource: EnemyConfig, position: Vector2) -> Enemy:
	var config := config_resource.duplicate(true) as EnemyConfig
	config.max_health = maxi(config.max_health, 50)
	config.physical_defense = 0
	config.magic_defense = 0
	config.xirang_kill_reward = 0
	config.drop_table = null
	var enemy := config.enemy_scene.instantiate() as Enemy
	runtime.enemy_container.add_child(enemy)
	enemy.global_position = position
	enemy.setup(config, null, null, runtime)
	enemy.set_process(false)
	enemy.set_physics_process(false)
	next_network_enemy_id += 1
	_expect(
		runtime.register_network_enemy(next_network_enemy_id, enemy),
		"Enemy attack smoke network registration failed."
	)
	return enemy


func _unregister_and_queue_enemy(enemy: Enemy) -> void:
	if enemy == null or not is_instance_valid(enemy):
		return
	var net_id := int(enemy.get_meta(&"net_id", 0))
	if net_id > 0:
		runtime.unregister_network_enemy(net_id, enemy)
	enemy.queue_free()


func _prepare_player(target_player: Player) -> void:
	target_player.max_health = 100
	target_player.current_health = 100
	target_player.physical_defense = 0
	target_player.magic_defense = 0
	target_player.is_dead = false
	target_player.invincibility_time_left = 0.0
	target_player.dash_time_left = 0.0
	target_player.multiplayer_dash_protection_time_left = 0.0
	target_player.dodge_chance = 0.0
	target_player.collectible_ranged_dodge_chance = 0.0
	target_player.damage_reduction_modifiers.clear()
	target_player.health_bar.set_health(
		target_player.current_health,
		target_player.max_health
	)
	target_player.global_position = Vector2(10000.0, 10000.0)
	target_player.set_process(false)
	target_player.set_physics_process(false)


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
