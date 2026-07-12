extends SceneTree

const PLAYER_SCENE := preload("res://scene/player/weishidaier/player_weishidaier.tscn")
const ENEMY_SCENE := preload("res://scene/enemy/enemy.tscn")
const BASIC_CONFIG := preload("res://resources/config/enemies/yuanshi_insect_basic.tres")
const BOSS_CONFIG := preload("res://resources/config/enemies/linglan_boss.tres")
const ENEMY_CONFIGS_TO_CHECK := [
	preload("res://resources/config/enemies/yuanshi_insect_basic.tres"),
	preload("res://resources/config/enemies/yuanshi_insect_fast.tres"),
	preload("res://resources/config/enemies/yuanshi_insect_shell.tres"),
	preload("res://resources/config/enemies/yuanshi_insect_bomber.tres"),
	preload("res://resources/config/enemies/yuanshi_insect_purple_bomber.tres"),
	preload("res://resources/config/enemies/yuanshi_insect_fire_ranged.tres"),
	preload("res://resources/config/enemies/yuanshi_insect_green_shell.tres"),
	preload("res://resources/config/enemies/yuanshi_insect_guardian.tres"),
	preload("res://resources/config/enemies/capoo_ak47.tres"),
	preload("res://resources/config/enemies/capoo_smg.tres"),
	preload("res://resources/config/enemies/capoo_rpg.tres"),
	preload("res://resources/config/enemies/capoo_knight.tres"),
	preload("res://resources/config/enemies/capoo_knight_elite.tres"),
	preload("res://resources/config/enemies/capoo_swordsman.tres"),
	preload("res://resources/config/enemies/capoo_mage.tres"),
	preload("res://resources/config/enemies/capoo_sniper.tres"),
]
const CARDINAL_DIRECTIONS: Array[Vector2] = [
	Vector2.RIGHT,
	Vector2.LEFT,
	Vector2.DOWN,
	Vector2.UP,
]
const WORLD_LAYER := 1 << 0
const WATER_TERRAIN_LAYER := 1 << 11
const PLAYER_LAYER := 1 << 1


class CountingPathfinder:
	extends Node

	var is_built: bool = true
	var flow_queries: int = 0
	var path_queries: int = 0


	func try_get_flow_navigation_waypoint(
		from_global_position: Vector2,
		to_global_position: Vector2,
		_agent_half_extents: Vector2 = Vector2.ZERO,
		_traversal_types: int = DualGridTilemap.TraversalType.LAND
	) -> Variant:
		flow_queries += 1
		var direction := from_global_position.direction_to(to_global_position)
		return from_global_position + direction * 16.0


	func try_get_global_path(
		_from_global_position: Vector2,
		to_global_position: Vector2,
		_agent_half_extents: Vector2 = Vector2.ZERO,
		_traversal_types: int = DualGridTilemap.TraversalType.LAND
	) -> Variant:
		path_queries += 1
		return PackedVector2Array([to_global_position])


var failures: Array[String] = []
var test_root: Node2D


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	test_root = Node2D.new()
	test_root.name = "PlayerContactStopSmokeTest"
	root.add_child(test_root)
	current_scene = test_root

	var requested_stage := "all"
	var user_args := OS.get_cmdline_user_args()
	if not user_args.is_empty():
		requested_stage = user_args[0]
	if requested_stage == "all" or requested_stage == "inner_core_removed":
		print("CONTACT_TEST stage=inner_core_removed")
		await _test_inner_core_removed()
	if requested_stage == "all" or requested_stage == "collision_contract":
		print("CONTACT_TEST stage=collision_contract")
		await _test_enemy_collision_contract()
	if requested_stage == "all" or requested_stage == "directional_contact":
		print("CONTACT_TEST stage=directional_contact")
		await _test_basic_enemy_stops_in_partial_contact_from_all_sides()
	if requested_stage == "all" or requested_stage == "all_enemy_shapes":
		print("CONTACT_TEST stage=all_enemy_shapes")
		await _test_all_regular_enemy_touch_shapes_hold_motion()
	if requested_stage == "all" or requested_stage == "multiple_players":
		print("CONTACT_TEST stage=multiple_players")
		await _test_multiple_touching_players_are_tracked()
	if requested_stage == "all" or requested_stage == "navigation_skip":
		print("CONTACT_TEST stage=navigation_skip")
		await _test_contact_skips_navigation_work()
	if requested_stage == "all" or requested_stage == "boss_contact":
		print("CONTACT_TEST stage=boss_contact")
		await _test_boss_move_phases_respect_player_contact()

	test_root.queue_free()
	await process_frame
	await physics_frame
	for _cleanup_frame in range(4):
		await process_frame

	if failures.is_empty():
		print("PLAYER_CORE_COLLISION_SMOKE_TEST_OK")
		quit(0)
		return

	for failure in failures:
		push_error(failure)
	quit(1)


func _test_inner_core_removed() -> void:
	var player := _spawn_player(Vector2.ZERO)
	_expect(player.get_node_or_null("NoEnteyCore") == null, "Player must not keep a hidden inner-core physics marker.")
	var body_shape := player.get_node_or_null("CollisionShape2D") as CollisionShape2D
	_expect(body_shape != null and body_shape.shape != null, "Player must keep its regular body collision shape.")
	player.queue_free()
	await physics_frame


func _test_enemy_collision_contract() -> void:
	var enemy := ENEMY_SCENE.instantiate() as Enemy
	_expect(enemy != null, "Base enemy scene must instantiate.")
	if enemy == null:
		return
	test_root.add_child(enemy)
	await process_frame
	await physics_frame

	_expect(
		enemy.collision_mask == (WORLD_LAYER | WATER_TERRAIN_LAYER),
		"Land enemies must scan World and WaterTerrain; player contact belongs to TouchDamageArea."
	)
	_expect(not enemy.has_method("_limit_velocity_against_target_player_core"), "Legacy per-frame player-core geometry limiter must be removed.")
	_expect(not enemy.has_method("_get_player_core_blocking_radius"), "Legacy player-core radius calculation must be removed.")
	_expect(enemy.has_method("_move_until_player_contact"), "Enemy base must expose contact-aware movement.")
	_expect((enemy.touch_damage_area.collision_mask & PLAYER_LAYER) != 0, "TouchDamageArea must continue scanning Player bodies.")
	enemy.queue_free()
	await physics_frame


func _test_basic_enemy_stops_in_partial_contact_from_all_sides() -> void:
	for direction in CARDINAL_DIRECTIONS:
		var player := _spawn_player(Vector2.ZERO)
		var enemy := BASIC_CONFIG.enemy_scene.instantiate() as Enemy
		_expect(enemy != null, "Basic enemy must instantiate for directional contact testing.")
		if enemy == null:
			player.queue_free()
			await physics_frame
			continue
		test_root.add_child(enemy)
		enemy.global_position = direction * 24.0
		enemy.setup(BASIC_CONFIG, player)
		var health_before := player.current_health

		var contacted := false
		for _frame_index in range(90):
			await physics_frame
			if enemy._has_player_contact():
				contacted = true
				break
		_expect(contacted, "Basic enemy must reach player contact from direction %s." % direction)
		if contacted:
			var contact_position := enemy.global_position
			var player_shape := player.get_node_or_null("CollisionShape2D") as CollisionShape2D
			await _wait_physics_frames(12)
			_expect(enemy.global_position.distance_to(contact_position) < 0.05, "Contacted enemy must stop advancing from direction %s." % direction)
			_expect(enemy.velocity == Vector2.ZERO, "Contacted enemy velocity must be zero from direction %s." % direction)
			_expect(_area_overlaps_body(enemy.touch_damage_area, player), "Stopped enemy must remain in an attacking overlap pose.")
			if player_shape != null:
				_expect(
					enemy.touch_damage_area.global_position.distance_to(player_shape.global_position) > 4.0,
					"Enemy must stop in partial contact instead of centering over the player."
				)
			_expect(player.current_health < health_before, "First contact must still deal touch damage.")

			player.global_position = -direction * 120.0
			await _wait_until_contact_count(enemy, 0, 12)
			var resume_position := enemy.global_position
			await _wait_physics_frames(8)
			_expect(enemy.global_position.distance_to(resume_position) > 0.2, "Enemy must resume chasing after the player leaves contact.")

		enemy.queue_free()
		player.queue_free()
		await physics_frame


func _test_all_regular_enemy_touch_shapes_hold_motion() -> void:
	for enemy_config_variant in ENEMY_CONFIGS_TO_CHECK:
		var enemy_config := enemy_config_variant as EnemyConfig
		var player := _spawn_player(Vector2.ZERO)
		var enemy := enemy_config.enemy_scene.instantiate() as Enemy
		_expect(enemy != null, "%s must instantiate as Enemy." % enemy_config.display_name)
		if enemy == null:
			player.queue_free()
			await physics_frame
			continue
		enemy.set_physics_process(false)
		test_root.add_child(enemy)
		enemy.global_position = Vector2.ZERO
		enemy.setup(enemy_config, player)
		var health_before := player.current_health
		await _wait_physics_frames(2)

		_expect(enemy.touching_players.size() == 1, "%s must register one Player body despite multiple touch shapes." % enemy_config.display_name)
		_expect(player.current_health < health_before, "%s contact must still deal damage." % enemy_config.display_name)
		var held_position := enemy.global_position
		enemy.velocity = Vector2.RIGHT * 80.0
		enemy._move_until_player_contact()
		_expect(enemy.velocity == Vector2.ZERO, "%s must cancel self-movement while touching a player." % enemy_config.display_name)
		_expect(enemy.global_position.distance_to(held_position) < 0.001, "%s must not advance deeper after contact." % enemy_config.display_name)

		player.global_position = Vector2(2048.0, 2048.0)
		await _wait_until_contact_count(enemy, 0, 6)
		_expect(enemy.touching_players.is_empty(), "%s must unregister a player that left its touch area." % enemy_config.display_name)

		enemy.queue_free()
		player.queue_free()
		await physics_frame


func _test_multiple_touching_players_are_tracked() -> void:
	var player_one := _spawn_player(Vector2.ZERO)
	var enemy := BASIC_CONFIG.enemy_scene.instantiate() as Enemy
	enemy.set_physics_process(false)
	test_root.add_child(enemy)
	enemy.global_position = Vector2.ZERO
	enemy.setup(BASIC_CONFIG, player_one)
	await _wait_until_contact_count(enemy, 1, 4)

	var player_two := _spawn_player(Vector2.ZERO)
	await _wait_until_contact_count(enemy, 2, 4)
	_expect(enemy.touching_players.size() == 2, "Enemy must track both overlapping players.")

	player_two.global_position = Vector2(2048.0, 0.0)
	await _wait_until_contact_count(enemy, 1, 6)
	_expect(enemy.touching_players.size() == 1, "Leaving one player must keep the remaining contact registered.")
	_expect(enemy.touched_player == player_one, "Damage target must fall back to the player that remains in contact.")
	player_one.invincibility_time_left = 0.0
	var health_before := player_one.current_health
	enemy.touch_damage_cooldown_left = 0.0
	enemy._update_touch_damage(0.0)
	_expect(player_one.current_health < health_before, "Periodic touch damage must continue after the latest player exits.")

	var held_position := enemy.global_position
	enemy.velocity = Vector2.RIGHT * 60.0
	enemy._move_until_player_contact()
	_expect(enemy.velocity == Vector2.ZERO and enemy.global_position == held_position, "Any remaining player contact must keep movement stopped.")

	player_one.global_position = Vector2(-2048.0, 0.0)
	await _wait_until_contact_count(enemy, 0, 6)
	enemy.set_physics_process(true)
	await _wait_physics_frames(8)
	_expect(enemy.global_position.distance_to(held_position) > 0.2, "Enemy may resume only after every player leaves contact.")

	enemy.queue_free()
	player_one.queue_free()
	player_two.queue_free()
	await physics_frame


func _test_contact_skips_navigation_work() -> void:
	var pathfinder := CountingPathfinder.new()
	test_root.add_child(pathfinder)
	var player := _spawn_player(Vector2.ZERO)
	var enemy := BASIC_CONFIG.enemy_scene.instantiate() as Enemy
	enemy.set_physics_process(false)
	test_root.add_child(enemy)
	enemy.global_position = Vector2.ZERO
	enemy.setup(BASIC_CONFIG, player, pathfinder)
	await _wait_until_contact_count(enemy, 1, 4)

	enemy.set_physics_process(false)
	pathfinder.flow_queries = 0
	pathfinder.path_queries = 0
	enemy._clear_cached_navigation_move_direction()
	enemy.set_physics_process(true)
	await _wait_physics_frames(6)
	_expect(pathfinder.flow_queries == 0 and pathfinder.path_queries == 0, "Contacted enemies must skip navigation before doing any path query.")

	player.global_position = Vector2(300.0, 0.0)
	await _wait_until_contact_count(enemy, 0, 6)
	enemy._clear_cached_navigation_move_direction()
	await _wait_physics_frames(6)
	_expect(pathfinder.flow_queries > 0, "Navigation queries must resume after contact ends.")

	enemy.queue_free()
	player.queue_free()
	pathfinder.queue_free()
	await physics_frame


func _test_boss_move_phases_respect_player_contact() -> void:
	var player := _spawn_player(Vector2.ZERO)
	var boss := BOSS_CONFIG.enemy_scene.instantiate() as LinglanBoss
	_expect(boss != null, "Linglan boss must instantiate for contact movement testing.")
	if boss == null:
		player.queue_free()
		await physics_frame
		return
	test_root.add_child(boss)
	boss.global_position = Vector2.ZERO
	boss.setup(BOSS_CONFIG, player)
	boss.set_active(true)
	boss.set_physics_process(false)
	boss.set_process(false)
	await _wait_until_contact_count(boss, 1, 6)
	_expect(boss._has_player_contact(), "Active boss must register player touch contact.")

	var held_position := boss.global_position
	boss.skill2_target_global_position = Vector2(100.0, 0.0)
	boss.skill3_target_global_position = Vector2(100.0, 0.0)
	boss.skill4_target_global_position = Vector2(100.0, 0.0)
	boss._update_skill2_move(1.0 / 60.0)
	_expect(boss.global_position == held_position and boss.velocity == Vector2.ZERO, "Boss skill-2 movement must stop before its snap branch while touching a player.")
	boss._update_skill3_move(1.0 / 60.0)
	_expect(boss.global_position == held_position and boss.velocity == Vector2.ZERO, "Boss skill-3 movement must stop while touching a player.")
	boss._update_skill4_move(1.0 / 60.0)
	_expect(boss.global_position == held_position and boss.velocity == Vector2.ZERO, "Boss skill-4 movement must stop while touching a player.")

	player.global_position = Vector2(-2048.0, 0.0)
	await _wait_until_contact_count(boss, 0, 6)
	boss._update_skill2_move(1.0 / 60.0)
	_expect(boss.global_position.distance_to(held_position) > 0.1, "Boss scripted movement must resume after player contact ends.")

	player.global_position = boss.global_position
	await _wait_until_contact_count(boss, 1, 6)
	boss.set_active(false)
	_expect(boss.touching_players.is_empty(), "Disabling the boss must clear retained player contacts.")

	boss.queue_free()
	player.queue_free()
	await physics_frame


func _spawn_player(spawn_position: Vector2) -> Player:
	var player := PLAYER_SCENE.instantiate() as Player
	player.global_position = spawn_position
	test_root.add_child(player)
	player.invincibility_duration = 0.0
	player.invincibility_time_left = 0.0
	player.set("_base_max_health", 100000)
	player.max_health = 100000
	player.current_health = 100000
	player.health_bar.setup(player.max_health, player.current_health)
	player.set_physics_process(false)
	player.set_process(false)
	return player


func _wait_until_contact_count(enemy: Enemy, expected_count: int, maximum_frames: int) -> void:
	for _frame_index in range(maximum_frames):
		if enemy.touching_players.size() == expected_count:
			return
		await physics_frame


func _wait_physics_frames(frame_count: int) -> void:
	for _frame_index in range(frame_count):
		await physics_frame


func _area_overlaps_body(area: Area2D, body: Node2D) -> bool:
	if area == null or body == null:
		return false
	return area.get_overlapping_bodies().has(body)


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
