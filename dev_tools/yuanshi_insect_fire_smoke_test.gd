extends SceneTree

const YUANSHI_INSECT_SCENE := preload("res://scene/yuanshi_insect.tscn")
const PLAYER_SCENE := preload("res://scene/player.tscn")
const FIRE_CONFIG := preload("res://resources/config/enemies/yuanshi_insect_fire_ranged.tres")
const BOMBER_CONFIG := preload("res://resources/config/enemies/yuanshi_insect_bomber.tres")
const FIRE_PROJECTILE_SCENE := preload("res://scene/yuanshi_insect_fire_projectile.tscn")
const FIRE_CONFIG_SCRIPT := preload("res://resources/config/enemies/yuanshi_insect_fire_ranged_config.gd")
const COMBAT_STATE_CHASE := 0
const COMBAT_STATE_ATTACK := 1

var failures: Array[String] = []
var test_root: Node2D


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	test_root = Node2D.new()
	test_root.name = "YuanshiInsectFireSmokeTest"
	root.add_child(test_root)
	current_scene = test_root

	_test_resource_contract()
	await _test_legacy_bomber_unchanged()
	await _test_attack_and_live_aim()
	await _test_wall_blocks_attack()
	await _test_projectile_damage_and_world_collision()
	await _test_death_interrupts_attack()
	test_root.queue_free()
	await process_frame
	await physics_frame
	for _cleanup_frame in range(4):
		await process_frame

	if failures.is_empty():
		print("YUANSHI_INSECT_FIRE_SMOKE_TEST_OK")
		await process_frame
		quit()
		return

	for failure in failures:
		push_error(failure)
	quit(1)


func _test_resource_contract() -> void:
	_expect(
		FIRE_CONFIG.variant == YuanshiInsectConfig.Variant.FIRE_RANGED,
		"Fire Yuanshi insect enum mismatch."
	)
	_expect(
		FIRE_CONFIG.get_script() == FIRE_CONFIG_SCRIPT,
		"Fire Yuanshi insect must use its dedicated config type."
	)
	_expect(
		FIRE_CONFIG.enemy_scene_override != null,
		"Fire Yuanshi insect must use its dedicated scene."
	)
	_expect(is_equal_approx(FIRE_CONFIG.attack_range, 172.8), "Attack range must be 172.8.")
	_expect(
		is_equal_approx(FIRE_CONFIG.projectile_speed, 142.5),
		"Projectile speed must be 142.5."
	)
	_expect(is_equal_approx(FIRE_CONFIG.attack_interval, 1.35), "Attack interval must be 1.35.")
	_expect(FIRE_CONFIG.attack_fire_frame == 2, "Attack must fire on frame 2.")

	var game_script_source := FileAccess.get_file_as_string("res://scene/game.gd")
	_expect(
		game_script_source.contains("res://resources/config/enemies/yuanshi_insect_fire_ranged.tres"),
		"Game random spawn list does not contain the fire enemy config."
	)

	var projectile := FIRE_PROJECTILE_SCENE.instantiate() as YuanshiInsectFireProjectile
	_expect(projectile != null, "Projectile scene did not instantiate YuanshiInsectFireProjectile.")
	if projectile != null:
		_expect(projectile.collision_layer == 128, "Projectile must use EnemyProjectile layer 8.")
		_expect(projectile.collision_mask == 3, "Projectile must only scan World and Player.")
		projectile.free()


func _test_legacy_bomber_unchanged() -> void:
	_expect(
		BOMBER_CONFIG.variant == YuanshiInsectConfig.Variant.BOMBER,
		"Bomber Yuanshi insect variant changed."
	)
	_expect(BOMBER_CONFIG.enemy_scene_override == null, "Bomber must keep using the base enemy scene.")
	_expect(BOMBER_CONFIG.explode_on_death, "Bomber lost its self-destruct behavior.")
	_expect(
		BOMBER_CONFIG.enemy_frames.resource_path == "res://resources/animation/yuanshi_insect_bomber.tres",
		"Bomber animation resource changed."
	)

	var player := _spawn_player(Vector2(100, 0))
	var bomber := YUANSHI_INSECT_SCENE.instantiate() as YuanshiInsect
	test_root.add_child(bomber)
	bomber.global_position = Vector2.ZERO
	bomber.setup(BOMBER_CONFIG, player)
	await _wait_physics_frames(20)

	_expect(bomber.get_node_or_null("AttackAudio") == null, "Base bomber unexpectedly contains attack audio.")
	_expect(bomber.animated_sprite.animation == BOMBER_CONFIG.move_animation_name, "Bomber left move animation.")
	_expect(_get_projectile_ids().is_empty(), "Base bomber generated a fire projectile.")

	bomber.apply_damage(BOMBER_CONFIG.max_health)
	await _wait_physics_frames(60)
	_expect(not is_instance_valid(bomber), "Bomber did not finish its death and explosion sequence.")
	_expect(_get_projectile_ids().is_empty(), "Dying bomber generated a fire projectile.")

	if is_instance_valid(bomber):
		bomber.queue_free()
	player.queue_free()
	await physics_frame


func _test_attack_and_live_aim() -> void:
	var player := _spawn_player(Vector2(100, 0))
	var enemy := _spawn_enemy(Vector2.ZERO, player)
	await physics_frame
	await physics_frame

	_expect(enemy.get("combat_state") == COMBAT_STATE_ATTACK, "Enemy did not enter attack in clear range.")
	player.global_position = Vector2(100, 60)

	var projectile := await _wait_for_projectile(40)
	_expect(projectile != null, "Enemy did not fire on its attack frame.")
	if projectile != null:
		var expected_direction := enemy.global_position.direction_to(player.global_position)
		_expect(
			projectile.direction.dot(expected_direction) > 0.995,
			"Projectile did not aim at the player's firing-frame position."
		)

	await _wait_physics_frames(40)
	_expect(enemy.animated_sprite.animation == FIRE_CONFIG.move_animation_name, "Enemy did not resume move animation.")
	enemy.queue_free()
	player.queue_free()
	await physics_frame


func _test_wall_blocks_attack() -> void:
	var player := _spawn_player(Vector2(100, 0))
	var wall := _spawn_wall(Vector2(50, 0), Vector2(4, 48))
	await physics_frame
	var enemy := _spawn_enemy(Vector2.ZERO, player)
	await _wait_physics_frames(4)

	_expect(enemy.get("combat_state") == COMBAT_STATE_CHASE, "Enemy attacked through a World-layer wall.")
	_expect(
		not enemy.call("_has_clear_world_line_to_target"),
		"World-layer wall did not block line of sight."
	)
	enemy.queue_free()
	player.queue_free()
	wall.queue_free()
	await physics_frame


func _test_projectile_damage_and_world_collision() -> void:
	var player := _spawn_player(Vector2(48, 0))
	await physics_frame
	var initial_health := player.current_health
	var projectile := _spawn_projectile(Vector2.ZERO, Vector2.RIGHT)
	await _wait_physics_frames(30)

	_expect(player.current_health == initial_health - 1, "Projectile did not damage the player exactly once.")
	_expect(not is_instance_valid(projectile), "Projectile remained after hitting the player.")
	player.queue_free()
	await physics_frame

	var wall := _spawn_wall(Vector2(24, 0), Vector2(4, 48))
	var wall_projectile := _spawn_projectile(Vector2.ZERO, Vector2.RIGHT)
	await _wait_physics_frames(20)
	_expect(not is_instance_valid(wall_projectile), "Projectile did not disappear on World collision.")
	wall.queue_free()
	await physics_frame


func _test_death_interrupts_attack() -> void:
	var existing_projectile_ids := _get_projectile_ids()
	var player := _spawn_player(Vector2(100, 0))
	var enemy := _spawn_enemy(Vector2.ZERO, player)
	await _wait_physics_frames(3)
	_expect(enemy.get("combat_state") == COMBAT_STATE_ATTACK, "Death test enemy did not begin attacking.")

	enemy.apply_damage(FIRE_CONFIG.max_health)
	await _wait_physics_frames(20)
	var new_projectile_ids := _get_projectile_ids()
	for projectile_id in new_projectile_ids:
		_expect(existing_projectile_ids.has(projectile_id), "Dead enemy fired a projectile after attack interruption.")

	player.queue_free()
	await physics_frame


func _spawn_player(position: Vector2) -> Player:
	var player := PLAYER_SCENE.instantiate() as Player
	test_root.add_child(player)
	player.global_position = position
	return player


func _spawn_enemy(position: Vector2, player: Player) -> YuanshiInsect:
	var enemy := FIRE_CONFIG.enemy_scene_override.instantiate() as YuanshiInsect
	test_root.add_child(enemy)
	enemy.global_position = position
	enemy.setup(FIRE_CONFIG, player)
	return enemy


func _spawn_projectile(position: Vector2, direction: Vector2) -> YuanshiInsectFireProjectile:
	var projectile := FIRE_PROJECTILE_SCENE.instantiate() as YuanshiInsectFireProjectile
	projectile.setup(direction, 1, FIRE_CONFIG.projectile_speed, 2.0)
	test_root.add_child(projectile)
	projectile.global_position = position
	return projectile


func _spawn_wall(position: Vector2, size: Vector2) -> StaticBody2D:
	var wall := StaticBody2D.new()
	wall.collision_layer = 1
	wall.collision_mask = 0
	var shape_node := CollisionShape2D.new()
	var shape := RectangleShape2D.new()
	shape.size = size
	shape_node.shape = shape
	wall.add_child(shape_node)
	test_root.add_child(wall)
	wall.global_position = position
	return wall


func _wait_for_projectile(max_frames: int) -> YuanshiInsectFireProjectile:
	for _frame_index in range(max_frames):
		await physics_frame
		for child in test_root.get_children():
			var projectile := child as YuanshiInsectFireProjectile
			if projectile != null:
				return projectile
	return null


func _wait_physics_frames(frame_count: int) -> void:
	for _frame_index in range(frame_count):
		await physics_frame


func _get_projectile_ids() -> Array[int]:
	var projectile_ids: Array[int] = []
	for child in test_root.get_children():
		if child is YuanshiInsectFireProjectile:
			projectile_ids.append(child.get_instance_id())
	return projectile_ids


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
