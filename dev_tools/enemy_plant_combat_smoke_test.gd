extends SceneTree

const PLAYER_SCENE := preload("res://scene/player/weishidaier/player_weishidaier.tscn")
const AGAVE_SCENE := preload("res://scene/plant_defense/agave_cannon.tscn")
const OAK_WAREHOUSE_SCENE := preload("res://scene/plant_defense/oak_warehouse.tscn")
const AGAVE_CONFIG := preload("res://resources/config/plant_defense/agave_cannon.tres")
const AK_CONFIG := preload("res://resources/config/enemies/capoo_ak47.tres")
const RPG_CONFIG := preload("res://resources/config/enemies/capoo_rpg.tres")
const MAGE_CONFIG := preload("res://resources/config/enemies/capoo_mage.tres")
const SNIPER_CONFIG := preload("res://resources/config/enemies/capoo_sniper.tres")
const SMG_CONFIG := preload("res://resources/config/enemies/capoo_smg.tres")
const KNIGHT_CONFIG := preload("res://resources/config/enemies/capoo_knight.tres")
const ELITE_KNIGHT_CONFIG := preload(
	"res://resources/config/enemies/capoo_knight_elite.tres"
)
const SWORDSMAN_CONFIG := preload(
	"res://resources/config/enemies/capoo_swordsman.tres"
)
const FIRE_INSECT_CONFIG := preload(
	"res://resources/config/enemies/yuanshi_insect_fire_ranged.tres"
)
const AK_BULLET_SCENE := preload("res://scene/enemy/capoo_ak47_bullet.tscn")
const SMG_BULLET_SCENE := preload("res://scene/enemy/capoo_smg_bullet.tscn")
const RPG_ROCKET_SCENE := preload("res://scene/enemy/capoo_rpg_rocket.tscn")
const MAGE_FIREBALL_SCENE := preload("res://scene/enemy/capoo_mage_fireball.tscn")
const FIRE_PROJECTILE_SCENE := preload(
	"res://scene/enemy/yuanshi_insect_fire_projectile.tscn"
)

var failures: Array[String] = []
var test_root: Node2D


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	test_root = Node2D.new()
	test_root.name = "EnemyPlantCombatSmokeTest"
	root.add_child(test_root)
	current_scene = test_root

	await _verify_ranged_enemy_target_contract()
	await _verify_melee_enemy_plant_attack_contract()
	await _verify_projectile_plant_damage_contract()
	await _verify_sniper_plant_damage_contract()

	test_root.queue_free()
	await process_frame
	await physics_frame
	for _cleanup_frame in range(3):
		await process_frame

	if failures.is_empty():
		print("ENEMY_PLANT_COMBAT_SMOKE_TEST_OK")
		quit()
		return
	for failure in failures:
		push_error(failure)
	quit(1)


func _verify_ranged_enemy_target_contract() -> void:
	var warehouse := OAK_WAREHOUSE_SCENE.instantiate() as OakWarehouse
	_expect(
		warehouse != null and is_equal_approx(warehouse.get_enemy_approach_depth(), 3.0),
		"Oak Warehouse must retain a shallower three-pixel approach inset."
	)
	if warehouse != null:
		warehouse.free()
	var player := _spawn_player(Vector2(600.0, 0.0))
	var plant := _spawn_agave(Vector2(40.0, 0.0))
	var gate := Node2D.new()
	test_root.add_child(gate)
	gate.global_position = Vector2(80.0, 0.0)

	var ak := _spawn_enemy(AK_CONFIG, player) as CapooAK47
	ak.set_objective_target(plant)
	_expect(bool(ak.call("_try_start_windup")), "AK Capoo must wind up against a plant.")
	ak.call("_cancel_attack")
	ak.set_objective_target(gate)
	_expect(not bool(ak.call("_try_start_windup")), "AK Capoo must not shoot a Home gate.")

	var rpg := _spawn_enemy(RPG_CONFIG, player) as CapooRPG
	rpg.set_objective_target(plant)
	_expect(bool(rpg.call("_try_start_windup")), "RPG Capoo must wind up against a plant.")

	var mage := _spawn_enemy(MAGE_CONFIG, player) as CapooMage
	mage.set_objective_target(plant)
	_expect(bool(mage.call("_try_start_windup")), "Mage Capoo must cast against a plant.")

	var fire_insect := _spawn_enemy(FIRE_INSECT_CONFIG, player) as YuanshiInsectFireRanged
	fire_insect.set_objective_target(plant)
	_expect(
		bool(fire_insect.call("_try_start_ranged_attack")),
		"Fire-ranged insect must begin its attack against a plant."
	)

	var smg_test_config := SMG_CONFIG.duplicate(true) as CapooSMGConfig
	smg_test_config.spread_angle_degrees = 0.0
	var smg := _spawn_enemy(smg_test_config, player) as CapooSMG
	_expect(
		ak.can_target_water_plant_objectives()
		and rpg.can_target_water_plant_objectives()
		and mage.can_target_water_plant_objectives()
		and fire_insect.can_target_water_plant_objectives()
		and smg.can_target_water_plant_objectives(),
		"Every independent and shared ranged enemy family must retain water-building objectives."
	)
	smg.set_objective_target(plant)
	await physics_frame
	var plant_health_before_smg := plant.current_health
	_expect(
		bool(smg.call("_try_fire_scatter", Vector2.ZERO)),
		"SMG Capoo must aim and fire at a nearby plant without a movement direction."
	)
	_expect(
		plant.current_health < plant_health_before_smg
		and smg.hitscan_shots_fired == 1,
		"SMG close-range hitscan must damage its determined plant target without spawning a bullet."
	)
	smg.fire_time_left = 0.0
	plant.global_position = Vector2(100.0, 0.0)
	_expect(
		not bool(smg.call("_try_fire_scatter", Vector2.RIGHT)),
		"SMG Capoo must not fire when its plant target leaves close range."
	)
	plant.begin_removal(PlantDefense.RemovalMode.ANIMATED)
	_expect(
		not plant.is_dead
		and ak.get_attackable_objective() == null
		and rpg.get_attackable_objective() == null
		and mage.get_attackable_objective() == null
		and fire_insect.get_attackable_objective() == null
		and smg.get_attackable_objective() == null,
		"A non-death removal must invalidate every enemy plant objective immediately."
	)

	for enemy in [ak, rpg, mage, fire_insect, smg]:
		if enemy != null and is_instance_valid(enemy):
			enemy.queue_free()
	plant.begin_removal(PlantDefense.RemovalMode.SILENT)
	player.queue_free()
	gate.queue_free()
	await physics_frame


func _verify_melee_enemy_plant_attack_contract() -> void:
	var player := _spawn_player(Vector2(600.0, 0.0))
	var gate := Node2D.new()
	test_root.add_child(gate)
	gate.global_position = Vector2(42.0, 0.0)
	var melee_configs: Array[CapooKnightConfig] = [
		KNIGHT_CONFIG,
		ELITE_KNIGHT_CONFIG,
		SWORDSMAN_CONFIG,
	]
	for melee_config in melee_configs:
		var plant := _spawn_agave(Vector2(42.0, 0.0))
		var enemy := _spawn_enemy(melee_config, player) as CapooKnight
		await physics_frame
		_expect(
			not enemy.can_target_water_plant_objectives(),
			"%s must remain a land-only melee objective selector."
			% melee_config.display_name
		)
		var health_before := plant.current_health
		enemy.set_objective_target(plant)
		enemy.call("_on_touch_damage_area_body_entered", plant)
		_expect(
			plant.current_health == health_before,
			"%s must not deal an invisible contact hit before its slash."
			% melee_config.display_name
		)
		_expect(
			bool(enemy.call("_try_start_windup"))
			and enemy.combat_state == CapooKnight.CombatState.WINDUP
			and enemy.animated_sprite.animation == melee_config.windup_animation_name,
			"%s must enter its windup animation against a plant."
			% melee_config.display_name
		)
		enemy.call("_update_windup", melee_config.attack_windup)
		_expect(
			enemy.combat_state == CapooKnight.CombatState.SLASH
			and enemy.animated_sprite.animation == melee_config.attack_animation_name,
			"%s must use its slash animation against a plant."
			% melee_config.display_name
		)
		var early_slash_delta := melee_config.slash_damage_delay * 0.5
		enemy.call("_update_slash", early_slash_delta)
		_expect(
			plant.current_health == health_before,
			"%s must not damage the plant before its authored slash frame."
			% melee_config.display_name
		)
		enemy.call(
			"_update_slash",
			melee_config.slash_damage_delay - early_slash_delta
		)
		var health_after_slash := plant.current_health
		enemy.call("_update_slash", 0.0)
		_expect(
			health_after_slash
			== health_before
				- maxi(melee_config.attack_damage - plant.physical_defense, 1),
			"%s slash must apply exactly one mitigated hit to the plant."
			% melee_config.display_name
		)
		_expect(
			plant.current_health == health_after_slash,
			"%s must not apply its committed slash to the same plant twice."
			% melee_config.display_name
		)
		enemy.call("_cancel_attack")
		enemy.set_objective_target(gate)
		_expect(
			not bool(enemy.call("_try_start_windup")),
			"%s must not slash a navigation-only Home gate."
			% melee_config.display_name
		)
		var removing_plant := _spawn_agave(Vector2(42.0, 0.0))
		enemy.set_objective_target(removing_plant)
		_expect(
			bool(enemy.call("_try_start_windup")),
			"%s removal fixture must begin a plant windup."
			% melee_config.display_name
		)
		var removing_health_before := removing_plant.current_health
		removing_plant.begin_removal(PlantDefense.RemovalMode.ANIMATED)
		enemy.call("_physics_process", 0.0)
		_expect(
			enemy.combat_state == CapooKnight.CombatState.CHASE
			and not enemy.windup_warning.visible
			and enemy.animated_sprite.animation == melee_config.move_animation_name
			and removing_plant.current_health == removing_health_before,
			"%s must cancel a plant windup without damage when the building disappears."
			% melee_config.display_name
		)
		enemy.queue_free()
		plant.begin_removal(PlantDefense.RemovalMode.SILENT)
		removing_plant.begin_removal(PlantDefense.RemovalMode.SILENT)
		await physics_frame
	gate.queue_free()
	player.queue_free()
	await physics_frame


func _verify_projectile_plant_damage_contract() -> void:
	var direct_projectile_scenes: Array[PackedScene] = [
		AK_BULLET_SCENE,
		SMG_BULLET_SCENE,
		FIRE_PROJECTILE_SCENE,
	]
	for projectile_index in range(direct_projectile_scenes.size()):
		var projectile_scene := direct_projectile_scenes[projectile_index]
		var plant := _spawn_agave(Vector2(1000.0 + float(projectile_index) * 100.0, 0.0))
		var health_before := plant.current_health
		var projectile := projectile_scene.instantiate() as Area2D
		test_root.add_child(projectile)
		projectile.call("setup", Vector2.RIGHT, 50, 100.0, 1.0)
		_expect(
			(projectile.collision_mask & 512) != 0,
			"Enemy projectile must monitor the PlantDefense collision layer: %s" % projectile_scene.resource_path
		)
		projectile.call("_on_body_entered", plant)
		await physics_frame
		_expect(
			plant.current_health == health_before - 40,
			"Direct enemy projectile damage mismatch for %s (before=%d, after=%d)." % [
				projectile_scene.resource_path,
				health_before,
				plant.current_health,
			]
		)
		plant.begin_removal(PlantDefense.RemovalMode.SILENT)
		await physics_frame

	var removing_plant := _spawn_agave(Vector2(1600.0, 0.0))
	var removing_health := removing_plant.current_health
	var ghost_bullet := AK_BULLET_SCENE.instantiate() as CapooAK47Bullet
	test_root.add_child(ghost_bullet)
	ghost_bullet.setup(Vector2.RIGHT, 50, 100.0, 1.0)
	removing_plant.begin_removal(PlantDefense.RemovalMode.ANIMATED)
	ghost_bullet.call("_on_body_entered", removing_plant)
	_expect(
		removing_plant.current_health == removing_health and not ghost_bullet.has_hit,
		"A projectile callback in the deferred collision shutdown frame must ignore the removal remnant."
	)
	ghost_bullet.queue_free()
	removing_plant.begin_removal(PlantDefense.RemovalMode.SILENT)
	await physics_frame

	var rocket_plant := _spawn_agave(Vector2(2000.0, 0.0))
	var rocket_health_before := rocket_plant.current_health
	var rocket := RPG_ROCKET_SCENE.instantiate() as CapooRPGRocket
	test_root.add_child(rocket)
	rocket.monitoring = false
	rocket.global_position = rocket_plant.global_position
	rocket.setup(Vector2.RIGHT, 50, 0.0, 1.0, 44.0)
	await physics_frame
	rocket.call("_apply_explosion_damage")
	_expect(
		rocket_plant.current_health == rocket_health_before - 40,
		"RPG explosion must include PlantDefense bodies (before=%d, after=%d)." % [
			rocket_health_before,
			rocket_plant.current_health,
		]
	)
	rocket.queue_free()
	rocket_plant.begin_removal(PlantDefense.RemovalMode.SILENT)
	await physics_frame

	var fireball_plant := _spawn_agave(Vector2(3000.0, 0.0))
	fireball_plant.physical_defense = 49
	fireball_plant.magic_defense = 20
	var fireball_health_before := fireball_plant.current_health
	var fireball := MAGE_FIREBALL_SCENE.instantiate() as CapooMageFireball
	test_root.add_child(fireball)
	fireball.monitoring = false
	fireball.global_position = fireball_plant.global_position
	fireball.setup(Vector2.RIGHT, 50, 0.0, 1.0, 16.0, fireball_plant, 0.65)
	await physics_frame
	_expect(fireball.target_player == fireball_plant, "Mage fireball must retain a plant homing target.")
	fireball.call("_apply_explosion_damage")
	_expect(
		fireball_plant.current_health == fireball_health_before - 40,
		"Mage fireball must use 20 magic defense (40 damage), not 49 physical defense (before=%d, after=%d)." % [
			fireball_health_before,
			fireball_plant.current_health,
		]
	)
	fireball.queue_free()
	fireball_plant.begin_removal(PlantDefense.RemovalMode.SILENT)
	await physics_frame

	var removing_fireball_plant := _spawn_agave(Vector2(3200.0, 0.0))
	var removing_fireball_health := removing_fireball_plant.current_health
	var removing_fireball := MAGE_FIREBALL_SCENE.instantiate() as CapooMageFireball
	test_root.add_child(removing_fireball)
	removing_fireball.monitoring = false
	removing_fireball.global_position = removing_fireball_plant.global_position
	removing_fireball.setup(
		Vector2.RIGHT,
		50,
		0.0,
		1.0,
		16.0,
		removing_fireball_plant,
		0.65
	)
	removing_fireball_plant.begin_removal(PlantDefense.RemovalMode.ANIMATED)
	_expect(
		not bool(removing_fireball.call("_is_homing_target_alive")),
		"Mage fireball homing must release a plant as soon as removal starts."
	)
	removing_fireball.call("_apply_explosion_damage")
	_expect(
		removing_fireball_plant.current_health == removing_fireball_health,
		"Explosion queries must ignore a plant during its deferred collision shutdown frame."
	)
	removing_fireball.queue_free()
	removing_fireball_plant.begin_removal(PlantDefense.RemovalMode.SILENT)
	await physics_frame


func _verify_sniper_plant_damage_contract() -> void:
	var player := _spawn_player(Vector2(600.0, 0.0))
	var plant := _spawn_agave(Vector2(100.0, 0.0))
	var health_before := plant.current_health
	var sniper := _spawn_enemy(SNIPER_CONFIG, player) as CapooSniper
	sniper.set_objective_target(plant)
	_expect(bool(sniper.call("_try_start_lock")), "Sniper Capoo must lock a plant objective.")
	_expect(sniper.locked_target == plant, "Sniper lock must retain the authoritative plant target.")
	sniper.lock_time_left = 0.0
	sniper.call("_update_lock", 0.0)
	_expect(
		plant.current_health == health_before - maxi(SNIPER_CONFIG.attack_damage - plant.physical_defense, 1),
		"Sniper direct shot must damage the locked plant."
	)
	sniper.queue_free()

	var proxy_sniper := SNIPER_CONFIG.enemy_scene.instantiate() as CapooSniper
	test_root.add_child(proxy_sniper)
	proxy_sniper.setup(SNIPER_CONFIG, player)
	proxy_sniper.configure_multiplayer_proxy()
	proxy_sniper.play_multiplayer_enemy_action(
		&"sniper_plant_lock_start",
		Vector2(100.0, 0.0),
		1
	)
	await process_frame
	_expect(
		proxy_sniper.proxy_plant_lock_active and proxy_sniper.aim_glow.visible,
		"Client-view sniper proxy must render a plant lock through generic enemy actions."
	)
	proxy_sniper.play_multiplayer_enemy_action(
		&"sniper_plant_lock_fire",
		Vector2(100.0, 0.0),
		2
	)
	_expect(
		not proxy_sniper.proxy_plant_lock_active,
		"Client-view sniper proxy must clear plant-lock VFX after fire."
	)
	proxy_sniper.queue_free()
	plant.begin_removal(PlantDefense.RemovalMode.SILENT)
	player.queue_free()
	await physics_frame


func _spawn_enemy(enemy_config: EnemyConfig, player: Player) -> Enemy:
	var enemy := enemy_config.enemy_scene.instantiate() as Enemy
	test_root.add_child(enemy)
	enemy.global_position = Vector2.ZERO
	enemy.setup(enemy_config, player)
	enemy.set_physics_process(false)
	return enemy


func _spawn_player(position: Vector2) -> Player:
	var player := PLAYER_SCENE.instantiate() as Player
	test_root.add_child(player)
	player.global_position = position
	return player


func _spawn_agave(position: Vector2) -> AgaveCannon:
	var plant := AGAVE_SCENE.instantiate() as AgaveCannon
	test_root.add_child(plant)
	plant.global_position = position
	plant.setup(AGAVE_CONFIG, null, [Vector2i.ZERO])
	plant.attack_timer.stop()
	return plant


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
