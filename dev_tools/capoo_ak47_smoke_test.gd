extends SceneTree

const CAPOO_SCENE := preload("res://scene/enemy/capoo_ak47.tscn")
const BULLET_SCENE := preload("res://scene/enemy/capoo_ak47_bullet.tscn")
const PLAYER_SCENE := preload("res://scene/player/weishidaier/player_weishidaier.tscn")
const AGAVE_SCENE := preload("res://scene/plant_defense/agave_cannon.tscn")
const CAPOO_CONFIG := preload("res://resources/config/enemies/capoo_ak47.tres")
const AGAVE_CONFIG := preload("res://resources/config/plant_defense/agave_cannon.tres")
const WAVE_06 := preload("res://resources/config/waves/wave_06.tres")
const WAVE_07 := preload("res://resources/config/waves/wave_07.tres")

var failures: Array[String] = []
var test_root: Node2D
var spawned_projectiles: Array[CapooAK47Bullet] = []


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	test_root = Node2D.new()
	test_root.name = "CapooAK47SmokeTest"
	root.add_child(test_root)
	current_scene = test_root
	test_root.child_entered_tree.connect(_on_child_entered_tree)

	_test_resource_contract()
	await _test_windup_and_locked_burst()
	await _test_plant_targeting_and_contact_depth()
	await _test_projectile_damage_and_world_collision()
	await _test_death_interrupts_attack()
	await _test_proxy_action_visuals()

	test_root.queue_free()
	await process_frame
	await physics_frame
	for _cleanup_frame in range(4):
		await process_frame

	if failures.is_empty():
		print("CAPOO_AK47_SMOKE_TEST_OK")
		quit()
		return

	for failure in failures:
		push_error(failure)
	quit(1)


func _test_resource_contract() -> void:
	_expect(CAPOO_CONFIG is CapooAK47Config, "AK Capoo config must use CapooAK47Config.")
	_expect(CAPOO_CONFIG.display_name == "AK猫猫虫", "Display name mismatch.")
	_expect(CAPOO_CONFIG.max_health == 150, "AK Capoo health mismatch.")
	_expect(CAPOO_CONFIG.attack_damage == 20, "AK Capoo projectile damage mismatch.")
	_expect(CAPOO_CONFIG.burst_count == 10, "AK Capoo burst count must be 10.")
	_expect(is_equal_approx(CAPOO_CONFIG.attack_windup, 1.5), "AK Capoo windup must be 1.5 seconds.")
	_expect(is_equal_approx(CAPOO_CONFIG.projectile_speed, 142.5), "AK projectile speed mismatch.")
	_expect(CAPOO_CONFIG.enemy_scene == CAPOO_SCENE, "AK Capoo must use its own enemy scene.")
	_expect(CAPOO_CONFIG.projectile_scene == BULLET_SCENE, "AK Capoo must use AK bullet scene.")
	_expect(CAPOO_CONFIG.attack_audio_stream != null, "AK fire audio is missing.")
	var capoo_scene_instance := CAPOO_SCENE.instantiate()
	var attack_audio := capoo_scene_instance.get_node("AttackAudio") as AudioStreamPlayer2D
	var animated_sprite := capoo_scene_instance.get_node("AnimatedSprite2D") as AnimatedSprite2D
	var body_shape := capoo_scene_instance.get_node("CollisionShape2D") as CollisionShape2D
	var touch_shape := capoo_scene_instance.get_node("TouchDamageArea/CollisionShape2D") as CollisionShape2D
	_expect(attack_audio.volume_db <= -16.0, "AK fire audio must stay quiet enough for bursts.")
	_expect(attack_audio.max_polyphony <= 3, "AK fire audio polyphony must avoid noisy overlap.")
	_expect(animated_sprite.scale.x < 0.5 and animated_sprite.scale.y < 0.5, "AK Capoo high resolution sprite must be scene-scaled down.")
	_expect(animated_sprite.sprite_frames != null and animated_sprite.sprite_frames.has_animation(&"move"), "AK scene must own its move animation.")
	_expect(body_shape.shape is RectangleShape2D, "AK body collision must be scene-owned rectangle.")
	_expect(touch_shape.shape is RectangleShape2D, "AK touch collision must be scene-owned rectangle.")
	_expect(body_shape.shape != touch_shape.shape, "AK body and touch shapes must be independently editable.")
	capoo_scene_instance.free()
	_expect(_count_wave_entries(WAVE_06) == 0, "Wave 6 must not spawn AK Capoos.")
	_expect(_count_wave_entries(WAVE_07) == 80, "Wave 7 must contain 80 AK Capoos.")

	var texture := load("res://resources/texture/capoo_ak47.png") as Texture2D
	var bullet_texture := load("res://resources/texture/capoo_ak47_bullet.png") as Texture2D
	_expect(texture != null and texture.get_size() == Vector2(384, 384), "AK Capoo sprite sheet size is incorrect.")
	_expect(
		bullet_texture != null and bullet_texture.get_size() == Vector2(24, 8),
		"AK bullet sprite sheet size is incorrect."
	)
	var bullet_instance := BULLET_SCENE.instantiate() as CapooAK47Bullet
	_expect(bullet_instance != null, "AK bullet scene did not instantiate CapooAK47Bullet.")
	if bullet_instance != null:
		var bullet_shape := bullet_instance.get_node_or_null("CollisionShape2D") as CollisionShape2D
		_expect(
			bullet_instance.collision_mask == CapooAK47Bullet.DAMAGEABLE_COLLISION_MASK,
			"AK bullet Area must scan Player and PlantDefense; its cached sweep owns World collision."
		)
		_expect(bullet_shape != null, "AK bullet collision shape must be a direct child of the Area2D.")
		_expect(bullet_shape != null and bullet_shape.shape is RectangleShape2D, "AK bullet collision should use the configured rectangle shape.")
		bullet_instance.free()


func _test_windup_and_locked_burst() -> void:
	spawned_projectiles.clear()
	var player := _spawn_player(Vector2(120.0, 0.0))
	var enemy := _spawn_capoo(Vector2.ZERO, player)
	await _wait_physics_frames(3)

	_expect(enemy.combat_state == CapooAK47.CombatState.WINDUP, "AK Capoo did not enter windup at medium range.")
	_expect(spawned_projectiles.is_empty(), "AK Capoo fired during early windup.")
	await _wait_physics_frames(45)
	_expect(spawned_projectiles.is_empty(), "AK Capoo fired before windup completed.")

	while enemy.combat_state == CapooAK47.CombatState.WINDUP:
		await physics_frame
	player.global_position = Vector2(120.0, 80.0)
	await _wait_physics_frames(70)

	_expect(spawned_projectiles.size() == CAPOO_CONFIG.burst_count, "AK Capoo did not fire exactly 10 bullets.")
	if not spawned_projectiles.is_empty() and is_instance_valid(spawned_projectiles[0]):
		_expect(
			spawned_projectiles[0].direction.dot(Vector2.RIGHT) > 0.99,
			"AK Capoo burst did not lock the windup-finished direction."
		)

	enemy.queue_free()
	player.queue_free()
	await physics_frame


func _test_projectile_damage_and_world_collision() -> void:
	var player := _spawn_player(Vector2(20.0, 0.0))
	player.invincibility_duration = 0.0
	player.current_health = 5
	var projectile := _spawn_projectile(Vector2.ZERO, Vector2.RIGHT)
	projectile.call("_on_body_entered", player)
	await physics_frame
	_expect(player.current_health == 4, "AK bullet did not deal 1 damage to the player.")
	_expect(not is_instance_valid(projectile), "AK bullet remained after hitting player.")

	var plant := _spawn_agave(Vector2(20.0, 40.0))
	var plant_health_before := plant.current_health
	var plant_projectile := _spawn_projectile(Vector2.ZERO, Vector2.RIGHT)
	plant_projectile.damage = 20
	plant_projectile.call("_on_body_entered", plant)
	await physics_frame
	_expect(
		plant.current_health == plant_health_before - 10,
		"AK bullet must damage a plant through its authored physical defense."
	)
	_expect(not is_instance_valid(plant_projectile), "AK bullet remained after hitting a plant.")

	var wall := StaticBody2D.new()
	wall.collision_layer = 1
	var wall_shape := CollisionShape2D.new()
	var circle := CircleShape2D.new()
	circle.radius = 5.0
	wall_shape.shape = circle
	wall.add_child(wall_shape)
	test_root.add_child(wall)
	wall.global_position = Vector2(12.0, 0.0)

	var wall_projectile := _spawn_projectile(Vector2.ZERO, Vector2.RIGHT)
	await _wait_physics_frames(8)
	_expect(not is_instance_valid(wall_projectile), "AK bullet did not disappear on World collision.")

	wall.queue_free()
	plant.queue_free()
	player.queue_free()
	await physics_frame


func _test_plant_targeting_and_contact_depth() -> void:
	var player := _spawn_player(Vector2(400.0, 0.0))
	var plant := _spawn_agave(Vector2(100.0, 0.0))
	var enemy := _spawn_capoo(Vector2.ZERO, player)
	enemy.set_physics_process(false)
	enemy.set_objective_target(plant)
	_expect(enemy.has_attackable_objective(), "A living plant must be an attackable enemy objective.")
	_expect(
		bool(enemy.call("_try_start_windup")),
		"AK Capoo must begin its ranged windup when a targeted plant is in range."
	)

	var gate := Node2D.new()
	test_root.add_child(gate)
	enemy.set_objective_target(gate)
	_expect(not enemy.has_attackable_objective(), "A Home/navigation node must not become a ranged attack target.")
	enemy.call("_cancel_attack")

	enemy.set_objective_target(plant)
	enemy.global_position = plant.global_position + Vector2(23.0, 0.0)
	enemy.call("_on_touch_damage_area_body_entered", plant)
	_expect(
		not bool(enemy.call("_has_player_contact")),
		"Initial plant overlap must not stop the enemy at the outer visual edge."
	)
	_expect(
		is_equal_approx(plant.get_enemy_approach_depth(), 6.0),
		"Agave must author a deeper six-pixel enemy approach inset."
	)
	enemy.global_position = plant.global_position + Vector2(18.0, 0.0)
	_expect(
		not bool(enemy.call("_has_player_contact")),
		"Agave contact must preserve the full six-pixel approach depth."
	)
	enemy.global_position = plant.global_position + Vector2(17.0, 0.0)
	_expect(
		bool(enemy.call("_has_player_contact")),
		"Enemy must stop after pressing six pixels into the Agave contact boundary."
	)

	enemy.queue_free()
	plant.queue_free()
	player.queue_free()
	gate.queue_free()
	await physics_frame


func _test_death_interrupts_attack() -> void:
	spawned_projectiles.clear()
	var player := _spawn_player(Vector2(120.0, 0.0))
	var enemy := _spawn_capoo(Vector2.ZERO, player)
	await _wait_physics_frames(3)

	_expect(enemy.combat_state == CapooAK47.CombatState.WINDUP, "Death test enemy did not enter windup.")
	enemy.apply_damage(CAPOO_CONFIG.max_health + 10)
	await _wait_physics_frames(120)
	_expect(spawned_projectiles.is_empty(), "Dead AK Capoo fired after attack interruption.")

	if is_instance_valid(enemy):
		enemy.queue_free()
	player.queue_free()
	await physics_frame


func _test_proxy_action_visuals() -> void:
	var player := _spawn_player(Vector2(120.0, 0.0))
	var enemy := _spawn_capoo(Vector2.ZERO, player)
	enemy.configure_multiplayer_proxy()
	enemy.play_multiplayer_enemy_action(&"windup", Vector2.RIGHT, 1)
	await process_frame
	_expect(enemy.muzzle_heat.visible, "Proxy AK windup muzzle heat did not appear.")
	enemy.play_multiplayer_enemy_action(&"burst", Vector2.LEFT, 2)
	await process_frame
	_expect(enemy.muzzle_heat.visible, "Proxy AK burst muzzle heat did not appear.")
	_expect(
		Vector2.RIGHT.rotated(enemy.muzzle_heat.rotation).dot(Vector2.LEFT) > 0.99,
		"Stale proxy AK windup tween must not override newer burst direction."
	)
	enemy.play_multiplayer_death_sequence()
	await process_frame
	_expect(not enemy.muzzle_heat.visible, "Proxy AK death must clear muzzle heat.")
	enemy.queue_free()
	player.queue_free()
	await physics_frame


func _spawn_player(position: Vector2) -> Player:
	var player := PLAYER_SCENE.instantiate() as Player
	test_root.add_child(player)
	player.global_position = position
	return player


func _spawn_capoo(position: Vector2, player: Player) -> CapooAK47:
	var enemy := CAPOO_SCENE.instantiate() as CapooAK47
	test_root.add_child(enemy)
	enemy.global_position = position
	enemy.setup(CAPOO_CONFIG, player)
	return enemy


func _spawn_agave(position: Vector2) -> AgaveCannon:
	var plant := AGAVE_SCENE.instantiate() as AgaveCannon
	test_root.add_child(plant)
	plant.global_position = position
	plant.setup(AGAVE_CONFIG, null, [Vector2i.ZERO])
	return plant


func _spawn_projectile(position: Vector2, direction: Vector2) -> CapooAK47Bullet:
	var projectile := BULLET_SCENE.instantiate() as CapooAK47Bullet
	test_root.add_child(projectile)
	projectile.global_position = position
	projectile.setup(direction, 1, CAPOO_CONFIG.projectile_speed, CAPOO_CONFIG.projectile_lifetime)
	return projectile


func _count_wave_entries(wave_config: WaveConfig) -> int:
	var total := 0
	for entry in wave_config.enemy_entries:
		if entry != null and entry.enemy_config == CAPOO_CONFIG:
			total += entry.count
	return total


func _on_child_entered_tree(child: Node) -> void:
	var projectile := child as CapooAK47Bullet
	if projectile != null:
		spawned_projectiles.append(projectile)


func _wait_physics_frames(frame_count: int) -> void:
	for _frame_index in range(frame_count):
		await physics_frame


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
