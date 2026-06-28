extends SceneTree

const PLAYER_SCENE := preload("res://scene/player.tscn")
const BASIC_CONFIG := preload("res://resources/config/enemies/yuanshi_insect_basic.tres")
const APPLE := preload("res://resources/config/collectibles/collectible_apple.tres")
const RUBY := preload("res://resources/config/collectibles/collectible_ruby.tres")
const POWER_RING := preload("res://resources/config/collectibles/collectible_power_ring.tres")
const LIFE_RING := preload("res://resources/config/collectibles/collectible_life_ring.tres")
const SPEED_RING := preload("res://resources/config/collectibles/collectible_speed_ring.tres")
const PHYSICAL_RING := preload("res://resources/config/collectibles/collectible_physical_ring.tres")
const MAGIC_RING := preload("res://resources/config/collectibles/collectible_magic_ring.tres")
const GOLD_WINE_CUP := preload("res://resources/config/collectibles/collectible_gold_wine_cup.tres")
const TIANSHI_STAKE := preload("res://resources/config/collectibles/collectible_tianshi_stake.tres")
const THUNDER_CRYSTAL := preload("res://resources/config/collectibles/collectible_thunder_crystal.tres")
const FROST_CRYSTAL := preload("res://resources/config/collectibles/collectible_frost_crystal.tres")
const LIFE_CRYSTAL := preload("res://resources/config/collectibles/collectible_life_crystal.tres")
const MOON_AMULET := preload("res://resources/config/collectibles/collectible_moon_amulet.tres")
const SWIFT_CRYSTAL := preload("res://resources/config/collectibles/collectible_swift_crystal.tres")
const ADMIN_DOLL := preload("res://resources/config/collectibles/collectible_admin_doll.tres")
const ARCHER := preload("res://resources/config/collectibles/collectible_archer.tres")
const NINE_ELEVEN := preload("res://resources/config/collectibles/collectible_nine_eleven.tres")
const CHARGED_JADE_PENDANT := preload("res://resources/config/collectibles/collectible_charged_jade_pendant.tres")
const LUCKY_GEM := preload("res://resources/config/collectibles/collectible_lucky_gem.tres")
const MEDIEVAL_SHIELD := preload("res://resources/config/collectibles/collectible_medieval_shield.tres")
const COLLECTIBLE_ARROW_PROJECTILE_SCRIPT := preload("res://scene/collectible_arrow_projectile.gd")

var failures: Array[String] = []
var test_root: Node2D


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	test_root = Node2D.new()
	test_root.name = "CollectibleEffectsSmokeTest"
	root.add_child(test_root)
	current_scene = test_root

	await _test_collectible_resources()
	await _test_collectible_stat_rules()
	await _test_xirang_dynamic_rules()
	await _test_new_collectible_rules()
	await _test_admin_doll_free_upgrade()
	await _test_combat_effects()

	test_root.queue_free()
	for _cleanup_frame in range(8):
		await process_frame
		await physics_frame

	if failures.is_empty():
		print("COLLECTIBLE_EFFECTS_SMOKE_TEST_OK")
		quit()
		return

	for failure in failures:
		push_error(failure)
	quit(1)


func _test_collectible_resources() -> void:
	var pool := LuoxiMerchant.get_collectible_pool()
	_expect(pool.size() == 24, "Luoxi collectible pool must include apple plus 23 collectibles.")
	var seen_paths: Dictionary = {}
	for item in pool:
		var config := item as PickupConfig
		_expect(config != null, "Collectible pool entry must load.")
		if config == null:
			continue
		_expect(not config.resource_path.is_empty(), "Collectible resource must have a resource path.")
		_expect(not seen_paths.has(config.resource_path), "Collectible pool must not contain duplicate resource paths.")
		seen_paths[config.resource_path] = true
		_expect(config.can_store_in_inventory, "%s must be storable in inventory." % config.display_name)
		_expect(config.pickup_type == PickupConfig.PickupType.COLLECTIBLE, "%s must use collectible pickup type." % config.display_name)
		_expect(not config.description.is_empty(), "%s must have a visible description." % config.display_name)
		_expect(config.icon_texture != null, "%s must have an icon texture." % config.display_name)
		if config.icon_texture != null:
			_expect(config.icon_texture.get_width() <= 32, "%s icon width must be <= 32." % config.display_name)
			_expect(config.icon_texture.get_height() <= 32, "%s icon height must be <= 32." % config.display_name)
	_expect(APPLE.icon_texture.get_width() == 32 and APPLE.icon_texture.get_height() == 32, "Apple icon must remain 32x32.")


func _test_new_collectible_rules() -> void:
	var run_state := root.get_node("RunState") as RunStateStore
	run_state.begin_new_run()
	var player := _spawn_player()
	_expect(run_state.try_add_item(CHARGED_JADE_PENDANT), "First charged jade pendant must fit in inventory.")
	_expect(run_state.try_add_item(CHARGED_JADE_PENDANT), "Second charged jade pendant must fit in inventory.")
	await process_frame
	_expect(
		is_equal_approx(float(player.get("collectible_skill_charge_bonus_per_second")), 1.0),
		"Charged jade pendants must stack their +0.5 skill charge per second bonus."
	)
	player.queue_free()
	await process_frame

	run_state.begin_new_run()
	player = _spawn_player()
	_expect(run_state.try_add_item(NINE_ELEVEN), "911 must fit in inventory.")
	await process_frame
	player.call("_set_multiplayer_facing_id", 0)
	player.current_health = player.max_health
	_expect(player.apply_damage(10, EnemyConfig.DamageType.PHYSICAL, {"is_ranged": true, "source_direction": Vector2.RIGHT}), "911 front hit must apply damage.")
	_expect(player.current_health == player.max_health - 13, "911 must increase front ranged damage by 30%.")
	player.invincibility_time_left = 0.0
	_expect(player.apply_damage(10, EnemyConfig.DamageType.PHYSICAL, {"is_ranged": true, "source_direction": Vector2.LEFT}), "911 back hit must apply damage.")
	_expect(player.current_health == player.max_health - 18, "911 must reduce back ranged damage by 50%.")
	player.queue_free()
	await process_frame

	run_state.begin_new_run()
	player = _spawn_player()
	_expect(run_state.try_add_item(LUCKY_GEM), "Lucky gem must fit in inventory.")
	_expect(run_state.try_add_item(MEDIEVAL_SHIELD), "Medieval shield must fit in inventory.")
	await process_frame
	_expect(
		is_equal_approx(float(player.get("collectible_base_upgrade_free_chance")), 0.2),
		"Lucky gem must expose a 20% free base upgrade chance."
	)
	_expect(
		is_equal_approx(float(player.get("collectible_ranged_dodge_chance")), 0.2),
		"Medieval shield must expose a 20% independent ranged dodge chance."
	)
	_expect(player.get_node_or_null("LuckyUpgradeAudio") != null, "Player scene must contain LuckyUpgradeAudio.")
	player.queue_free()
	await process_frame

	run_state.begin_new_run()
	player = _spawn_player()
	var enemies: Array[Enemy] = []
	for enemy_index in range(4):
		enemies.append(_spawn_enemy(Vector2(48.0 + enemy_index * 24.0, 0.0), player))
	await process_frame
	player.call("_trigger_archer", ARCHER)
	var arrow_count := 0
	for child in test_root.get_children():
		if child.get_script() == COLLECTIBLE_ARROW_PROJECTILE_SCRIPT:
			arrow_count += 1
			_expect(int(child.get("damage")) == player.attack_damage * 2, "Archer arrows must deal 200% of the player's attack damage.")
	_expect(arrow_count == 3, "Archer must fire at the nearest three enemies.")
	for child in test_root.get_children():
		if child.get_script() == COLLECTIBLE_ARROW_PROJECTILE_SCRIPT:
			child.queue_free()
	for enemy in enemies:
		if is_instance_valid(enemy):
			enemy.queue_free()
	player.queue_free()
	await process_frame


func _test_collectible_stat_rules() -> void:
	var run_state := root.get_node("RunState") as RunStateStore
	run_state.begin_new_run()
	var player := _spawn_player()
	_expect(run_state.try_add_item(RUBY), "First ruby must fit in inventory.")
	_expect(run_state.try_add_item(RUBY), "Second ruby must fit in inventory.")
	_expect(run_state.try_add_item(POWER_RING), "First power ring must fit in inventory.")
	_expect(run_state.try_add_item(POWER_RING), "Second power ring must fit in inventory.")
	await process_frame
	_expect(player.attack_damage == 26, "Two rubies and two power rings must all stack.")
	_expect(
		player.get_outgoing_damage(player.attack_damage, EnemyConfig.DamageType.PHYSICAL) == 26,
		"Power ring must not add physical damage; it is a direct attack bonus only."
	)
	_expect(run_state.discard_item(0), "Discarding one ruby must succeed.")
	await process_frame
	_expect(player.attack_damage == 23, "Discarding one ruby must remove exactly one ruby bonus while both power rings remain active.")
	player.queue_free()
	await process_frame

	run_state.begin_new_run()
	player = _spawn_player()
	var base_max_health := player.max_health
	var base_move_speed := player.move_speed
	var base_physical_defense := player.physical_defense
	var base_magic_defense := player.magic_defense
	_expect(run_state.try_add_item(LIFE_RING), "First life ring must fit in inventory.")
	_expect(run_state.try_add_item(LIFE_RING), "Second life ring must fit in inventory.")
	_expect(run_state.try_add_item(SPEED_RING), "First speed ring must fit in inventory.")
	_expect(run_state.try_add_item(SPEED_RING), "Second speed ring must fit in inventory.")
	_expect(run_state.try_add_item(PHYSICAL_RING), "First physical ring must fit in inventory.")
	_expect(run_state.try_add_item(PHYSICAL_RING), "Second physical ring must fit in inventory.")
	_expect(run_state.try_add_item(MAGIC_RING), "First magic ring must fit in inventory.")
	_expect(run_state.try_add_item(MAGIC_RING), "Second magic ring must fit in inventory.")
	await process_frame
	_expect(player.max_health == base_max_health + 40, "Two life rings must stack max health.")
	_expect(is_equal_approx(player.move_speed, base_move_speed + 30.0), "Two speed rings must stack move speed.")
	_expect(player.physical_defense == base_physical_defense + 2, "Two physical rings must stack physical defense.")
	_expect(player.magic_defense == base_magic_defense + 2, "Two magic rings must stack magic defense.")
	_expect(
		player.get_outgoing_damage(10, EnemyConfig.DamageType.PHYSICAL) == 12,
		"Two physical rings must stack physical damage bonus."
	)
	_expect(
		player.get_outgoing_damage(10, EnemyConfig.DamageType.MAGIC) == 12,
		"Two magic rings must stack magic damage bonus."
	)
	player.queue_free()
	await process_frame

	run_state.begin_new_run()
	player = _spawn_player()
	_expect(run_state.try_add_item(APPLE), "First apple must fit in inventory.")
	_expect(run_state.try_add_item(APPLE), "Second apple must fit in inventory.")
	await process_frame
	_expect(
		is_equal_approx(player.call("_get_inventory_bullet_pierce_chance"), 0.5),
		"Multiple apples must still only expose a 50% max pierce chance."
	)
	player.queue_free()
	await process_frame


func _test_xirang_dynamic_rules() -> void:
	var run_state := root.get_node("RunState") as RunStateStore
	run_state.begin_new_run()
	var player := _spawn_player()
	_expect(run_state.try_add_item(GOLD_WINE_CUP), "Gold wine cup must fit in inventory.")
	player.grant_cheat_xirang(250)
	await process_frame
	_expect(
		is_equal_approx(player.get_attack_speed(), (100.0 / 0.18) + 12.0),
		"Gold wine cup must add 6 attack speed points per 100 xirang."
	)
	_expect(
		is_equal_approx(player.get_attacks_per_second(), ((100.0 / 0.18) + 12.0) / 100.0),
		"100 attack speed must equal 1 attack per second."
	)
	player.queue_free()
	await process_frame

	run_state.begin_new_run()
	player = _spawn_player()
	_expect(run_state.try_add_item(TIANSHI_STAKE), "Tianshi stake must fit in inventory.")
	player.grant_cheat_xirang(2100)
	await process_frame
	_expect(player.physical_defense == 2, "Tianshi stake must add physical defense per 1000 xirang.")
	_expect(player.magic_defense == 2, "Tianshi stake must add magic defense per 1000 xirang.")
	player.queue_free()
	await process_frame


func _test_admin_doll_free_upgrade() -> void:
	var run_state := root.get_node("RunState") as RunStateStore
	run_state.begin_new_run()
	var player := _spawn_player()
	_expect(run_state.try_add_item(ADMIN_DOLL), "Admin doll must fit in inventory.")
	player.grant_cheat_xirang(ZhuangfangyiMerchant.PURCHASE_COST)
	_expect(player.try_purchase_skill1(ZhuangfangyiMerchant.PURCHASE_COST), "Admin doll must not make the first skill purchase free.")
	_expect(player.current_xirang == 0, "First skill purchase must still spend 200 xirang.")
	_expect(player.try_upgrade_skill1(player.has_collectible_effect(PickupConfig.COLLECTIBLE_EFFECT_ADMIN_DOLL)), "Admin doll must make later skill upgrades free.")
	_expect(player.current_xirang == 0, "Admin doll upgrade must not spend xirang.")
	_expect(run_state.get_item(0) == ADMIN_DOLL, "Admin doll must not be consumed by a free upgrade.")
	player.queue_free()
	await process_frame


func _test_combat_effects() -> void:
	var run_state := root.get_node("RunState") as RunStateStore
	run_state.begin_new_run()
	var player := _spawn_player()
	var enemy := _spawn_enemy(Vector2(40.0, 0.0), player)
	var nearby_enemy := _spawn_enemy(Vector2(64.0, 0.0), player)
	_expect(run_state.try_add_item(MAGIC_RING), "Magic ring must fit in inventory.")
	_expect(run_state.try_add_item(THUNDER_CRYSTAL), "Thunder crystal must fit in inventory.")
	await process_frame
	enemy.current_health = 100
	nearby_enemy.current_health = 100
	player.call("_trigger_thunder_crystal", THUNDER_CRYSTAL)
	_expect(enemy.last_damage_taken == 51, "Thunder crystal must use magic damage bonus.")
	_expect(nearby_enemy.last_damage_taken == 51, "Thunder crystal must damage nearby enemies around the strike point.")

	run_state.begin_new_run()
	player.refresh_collectible_stats()
	_expect(run_state.try_add_item(FROST_CRYSTAL), "Frost crystal must fit in inventory.")
	await process_frame
	enemy.current_health = 100
	player.call("_trigger_frost_crystal", FROST_CRYSTAL)
	_expect(enemy.last_damage_taken == 10, "Frost crystal must damage enemies in its radius.")
	_expect(enemy.move_speed_modifiers.size() > 0, "Frost crystal must slow enemies in its radius.")
	enemy.queue_free()
	await process_frame
	await create_timer(FROST_CRYSTAL.periodic_slow_duration + 0.1).timeout

	var ally := _spawn_player(Vector2(24.0, 0.0))
	run_state.begin_new_run()
	player.refresh_collectible_stats()
	_expect(run_state.try_add_item(LIFE_CRYSTAL), "Life crystal must fit in inventory.")
	await process_frame
	ally.current_health = 5
	player.call("_trigger_life_crystal", LIFE_CRYSTAL)
	_expect(ally.current_health == 15, "Life crystal must heal nearby friendly players for 10 health.")

	run_state.begin_new_run()
	player.refresh_collectible_stats()
	_expect(run_state.try_add_item(MOON_AMULET), "Moon amulet must fit in inventory.")
	_expect(run_state.try_add_item(SWIFT_CRYSTAL), "Swift crystal must fit in inventory.")
	await process_frame
	player.current_health = player.max_health
	var base_speed := float(player.call("_get_effective_move_speed"))
	player.call("_activate_collectible_skill_effects")
	await process_frame
	_expect(
		float(player.call("_get_effective_move_speed")) > base_speed,
		"Swift crystal must boost movement after skill activation."
	)
	player.invincibility_time_left = 0.0
	var health_before := player.current_health
	player.apply_damage(10)
	_expect(player.current_health == health_before - 5, "Moon amulet shield must halve incoming damage.")

	for node in [player, ally, enemy, nearby_enemy]:
		if is_instance_valid(node):
			node.queue_free()
	await process_frame


func _spawn_player(position: Vector2 = Vector2.ZERO) -> Player:
	var player := PLAYER_SCENE.instantiate() as Player
	test_root.add_child(player)
	player.global_position = position
	return player


func _spawn_enemy(position: Vector2, player: Player) -> Enemy:
	var enemy := BASIC_CONFIG.enemy_scene.instantiate() as Enemy
	test_root.add_child(enemy)
	enemy.global_position = position
	enemy.setup(BASIC_CONFIG, player, null)
	return enemy


func _expect(condition: bool, message: String) -> void:
	if condition:
		return
	failures.append(message)
