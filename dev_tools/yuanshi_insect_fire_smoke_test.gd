extends SceneTree

const PLAYER_SCENE := preload("res://scene/player/weishidaier/player_weishidaier.tscn")
const FIRE_CONFIG := preload("res://resources/config/enemies/yuanshi_insect_fire_ranged.tres")
const BOMBER_CONFIG := preload("res://resources/config/enemies/yuanshi_insect_bomber.tres")
const PURPLE_BOMBER_CONFIG := preload("res://resources/config/enemies/yuanshi_insect_purple_bomber.tres")
const FIRE_PROJECTILE_SCENE := preload("res://scene/enemy/yuanshi_insect_fire_projectile.tscn")
const EXPLODER_SCRIPT := preload("res://scene/enemy/yuanshi_insect_exploder.gd")
const FIRE_CONFIG_SCRIPT := preload("res://resources/config/enemies/yuanshi_insect_fire_ranged_config.gd")
const FIRE_WAVE := preload("res://resources/config/waves/wave_04.tres")
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
	await _test_bomber_explosion_query_contract()
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
		FIRE_CONFIG.enemy_scene != null,
		"Fire Yuanshi insect must use its dedicated scene."
	)
	_expect(is_equal_approx(FIRE_CONFIG.attack_range, 172.8), "Attack range must be 172.8.")
	_expect(
		is_equal_approx(FIRE_CONFIG.projectile_speed, 142.5),
		"Projectile speed must be 142.5."
	)
	_expect(FIRE_CONFIG.attack_damage == 10, "Fire projectile damage mismatch.")
	_expect(is_equal_approx(FIRE_CONFIG.attack_interval, 1.35), "Attack interval must be 1.35.")
	_expect(FIRE_CONFIG.attack_fire_frame == 2, "Attack must fire on frame 2.")

	var fire_enemy_count := 0
	for entry in FIRE_WAVE.enemy_entries:
		if entry != null and entry.enemy_config == FIRE_CONFIG:
			fire_enemy_count += entry.count
	_expect(
		fire_enemy_count == 10,
		"Wave 4 must contain 10 fire Yuanshi insects."
	)

	var projectile := FIRE_PROJECTILE_SCENE.instantiate() as YuanshiInsectFireProjectile
	_expect(projectile != null, "Projectile scene did not instantiate YuanshiInsectFireProjectile.")
	if projectile != null:
		_expect(projectile.collision_layer == 128, "Projectile must use EnemyProjectile layer 8.")
		_expect(
			projectile.collision_mask == YuanshiInsectFireProjectile.DAMAGEABLE_COLLISION_MASK,
			"Projectile Area must scan Player and PlantDefense; its cached sweep owns World collision."
		)
		projectile.free()


func _test_bomber_explosion_query_contract() -> void:
	await _assert_bomber_explosion_query_contract(BOMBER_CONFIG, "Bomber")
	await _assert_bomber_explosion_query_contract(PURPLE_BOMBER_CONFIG, "Purple bomber")


func _assert_bomber_explosion_query_contract(
	enemy_config: YuanshiInsectConfig,
	contract_name: String
) -> void:
	var inside_player := _spawn_player(Vector2(enemy_config.explosion_radius - 10.0, 0.0))
	var outside_player := _spawn_player(Vector2(enemy_config.explosion_radius + 10.0, 0.0))
	var bomber := enemy_config.enemy_scene.instantiate() as YuanshiInsectExploder
	_expect(bomber != null, "%s scene must instantiate YuanshiInsectExploder." % contract_name)
	if bomber == null:
		inside_player.queue_free()
		outside_player.queue_free()
		await process_frame
		return

	test_root.add_child(bomber)
	bomber.global_position = Vector2.ZERO
	bomber.setup(enemy_config, inside_player)
	bomber.set_physics_process(false)
	await physics_frame
	await physics_frame

	var explosion_area := bomber.get_node("ExplosionArea") as Area2D
	var explosion_shape := bomber.get_node("ExplosionArea/CollisionShape2D") as CollisionShape2D
	var explosion_circle := explosion_shape.shape as CircleShape2D
	_expect(explosion_area.collision_layer == 0, "%s explosion area must not occupy a physics layer." % contract_name)
	_expect(explosion_area.collision_mask == 6, "%s explosion query mask changed." % contract_name)
	_expect(not explosion_area.monitoring, "%s explosion area must not monitor continuously." % contract_name)
	_expect(not explosion_area.monitorable, "%s explosion area must not be monitorable." % contract_name)
	_expect(explosion_shape.disabled, "%s explosion collision shape must stay disabled." % contract_name)
	_expect(
		explosion_circle != null
		and is_equal_approx(explosion_circle.radius, enemy_config.explosion_radius),
		"%s explosion radius changed." % contract_name
	)

	inside_player.invincibility_time_left = 0.0
	var inside_health := inside_player.current_health
	var outside_health := outside_player.current_health
	bomber.call("_try_apply_explosion_damage")
	_expect(
		inside_player.current_health == inside_health - enemy_config.explosion_damage,
		"%s explicit explosion query damage mismatch: expected %d, got %d."
		% [
			contract_name,
			inside_health - enemy_config.explosion_damage,
			inside_player.current_health,
		]
	)
	_expect(
		outside_player.current_health == outside_health,
		"%s explicit explosion query damaged a player beyond its configured radius." % contract_name
	)

	bomber.queue_free()
	inside_player.queue_free()
	outside_player.queue_free()
	await process_frame
	await physics_frame


func _test_legacy_bomber_unchanged() -> void:
	_expect(
		BOMBER_CONFIG.variant == YuanshiInsectConfig.Variant.BOMBER,
		"Bomber Yuanshi insect variant changed."
	)
	_expect(BOMBER_CONFIG.enemy_scene != null, "Bomber must use its own scene.")
	_expect(BOMBER_CONFIG.explode_on_death, "Bomber lost its self-destruct behavior.")

	var player := _spawn_player(Vector2(100, 0))
	var visual_bomber := BOMBER_CONFIG.enemy_scene.instantiate() as YuanshiInsect
	_expect(visual_bomber != null, "Bomber visual contract scene must instantiate YuanshiInsect.")
	if visual_bomber != null:
		test_root.add_child(visual_bomber)
		visual_bomber.global_position = Vector2.ZERO
		visual_bomber.setup(BOMBER_CONFIG, player)
		await process_frame
		visual_bomber.call("_start_explosion_sequence")
		_expect(
			visual_bomber.animated_sprite.z_index >= 8,
			"Bomber explosion animation must render above enemy body sprites."
		)
		visual_bomber.queue_free()
		await process_frame

	var bomber := BOMBER_CONFIG.enemy_scene.instantiate() as YuanshiInsect
	_expect(bomber != null, "Bomber scene must instantiate YuanshiInsect.")
	if bomber == null:
		player.queue_free()
		return
	_expect(bomber.get_script() == EXPLODER_SCRIPT, "Bomber scene must use the exploder script.")
	test_root.add_child(bomber)
	bomber.global_position = Vector2.ZERO
	bomber.setup(BOMBER_CONFIG, player)
	await _wait_physics_frames(20)

	_expect(bomber.get_node_or_null("AttackAudio") == null, "Base bomber unexpectedly contains attack audio.")
	_expect(bomber.get_node_or_null("AuraArea") == null, "Base bomber unexpectedly contains aura nodes.")
	_expect(bomber.get_node_or_null("ExplosionArea") != null, "Bomber must own its explosion area.")
	_expect(bomber.animated_sprite.animation == BOMBER_CONFIG.move_animation_name, "Bomber left move animation.")
	_expect(
		bomber.animated_sprite.sprite_frames != null
		and bomber.animated_sprite.sprite_frames.resource_path == "res://resources/animation/yuanshi_insect_bomber.tres",
		"Bomber scene animation resource changed."
	)
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

	_expect(player.current_health == initial_health - FIRE_CONFIG.attack_damage, "Projectile did not damage the player exactly once.")
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
	var enemy := FIRE_CONFIG.enemy_scene.instantiate() as YuanshiInsect
	test_root.add_child(enemy)
	enemy.global_position = position
	enemy.setup(FIRE_CONFIG, player)
	return enemy


func _spawn_projectile(position: Vector2, direction: Vector2) -> YuanshiInsectFireProjectile:
	var projectile := FIRE_PROJECTILE_SCENE.instantiate() as YuanshiInsectFireProjectile
	projectile.setup(direction, FIRE_CONFIG.attack_damage, FIRE_CONFIG.projectile_speed, 2.0)
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
