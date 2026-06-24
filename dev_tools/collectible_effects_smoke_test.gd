extends SceneTree

const PLAYER_SCENE := preload("res://scene/player.tscn")
const BASIC_CONFIG := preload("res://resources/config/enemies/yuanshi_insect_basic.tres")
const APPLE := preload("res://resources/config/collectibles/collectible_apple.tres")
const RUBY := preload("res://resources/config/collectibles/collectible_ruby.tres")
const POWER_RING := preload("res://resources/config/collectibles/collectible_power_ring.tres")
const MAGIC_RING := preload("res://resources/config/collectibles/collectible_magic_ring.tres")
const GOLD_WINE_CUP := preload("res://resources/config/collectibles/collectible_gold_wine_cup.tres")
const TIANSHI_STAKE := preload("res://resources/config/collectibles/collectible_tianshi_stake.tres")
const THUNDER_CRYSTAL := preload("res://resources/config/collectibles/collectible_thunder_crystal.tres")
const FROST_CRYSTAL := preload("res://resources/config/collectibles/collectible_frost_crystal.tres")
const LIFE_CRYSTAL := preload("res://resources/config/collectibles/collectible_life_crystal.tres")
const MOON_AMULET := preload("res://resources/config/collectibles/collectible_moon_amulet.tres")
const SWIFT_CRYSTAL := preload("res://resources/config/collectibles/collectible_swift_crystal.tres")
const ADMIN_DOLL := preload("res://resources/config/collectibles/collectible_admin_doll.tres")

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
	_expect(pool.size() == 19, "Luoxi collectible pool must include apple plus 18 new collectibles.")
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


func _test_collectible_stat_rules() -> void:
	var run_state := root.get_node("RunState") as RunStateStore
	run_state.begin_new_run()
	var player := _spawn_player()
	_expect(run_state.try_add_item(RUBY), "First ruby must fit in inventory.")
	_expect(run_state.try_add_item(RUBY), "Second ruby must fit in inventory.")
	_expect(run_state.try_add_item(POWER_RING), "First power ring must fit in inventory.")
	_expect(run_state.try_add_item(POWER_RING), "Second power ring must fit in inventory.")
	await process_frame
	_expect(player.attack_damage == 21, "Two rubies must stack but duplicate power rings must only apply once.")
	_expect(
		player.get_outgoing_damage(player.attack_damage, EnemyConfig.DamageType.PHYSICAL) == 21,
		"Power ring must not add physical damage; it is a direct attack bonus only."
	)
	_expect(run_state.discard_item(0), "Discarding one ruby must succeed.")
	await process_frame
	_expect(player.attack_damage == 18, "Discarding one ruby must remove exactly one ruby bonus.")
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
		is_equal_approx(player.get_attack_speed(), (100.0 / 0.18) + 2.0),
		"Gold wine cup must add floor(xirang / 100) attack speed points."
	)
	_expect(
		is_equal_approx(player.get_attacks_per_second(), ((100.0 / 0.18) + 2.0) / 100.0),
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
