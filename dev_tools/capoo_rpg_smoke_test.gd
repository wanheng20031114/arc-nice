extends SceneTree

const CAPOO_SCENE := preload("res://scene/enemy/capoo_rpg.tscn")
const ROCKET_SCENE := preload("res://scene/enemy/capoo_rpg_rocket.tscn")
const EXPLOSION_SCENE := preload("res://scene/enemy/capoo_rpg_explosion.tscn")
const PLAYER_SCENE := preload("res://scene/player.tscn")
const CAPOO_CONFIG := preload("res://resources/config/enemies/capoo_rpg.tres")
const MP_GAME_SCRIPT := preload("res://scene/multiplayer/mp_game.gd")

var failures: Array[String] = []
var test_root: Node2D
var spawned_rockets: Array[CapooRPGRocket] = []
var spawned_explosions: Array[CapooRPGExplosion] = []


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	test_root = Node2D.new()
	test_root.name = "CapooRPGSmokeTest"
	root.add_child(test_root)
	current_scene = test_root
	test_root.child_entered_tree.connect(_on_child_entered_tree)

	_test_resource_contract()
	await _test_windup_fire_and_cooldown()
	await _test_world_obstruction_blocks_attack()
	await _test_rocket_explosion_paths()
	await _test_explosion_damage_contract()
	await _test_death_interrupts_attack()
	await _test_proxy_action_visuals()
	_test_multiplayer_projectile_registry()

	test_root.queue_free()
	await process_frame
	await physics_frame
	for _cleanup_frame in range(4):
		await process_frame

	if failures.is_empty():
		print("CAPOO_RPG_SMOKE_TEST_OK")
		quit()
		return

	for failure in failures:
		push_error(failure)
	quit(1)


func _test_resource_contract() -> void:
	_expect(CAPOO_CONFIG is CapooRPGConfig, "RPG config must use CapooRPGConfig.")
	_expect(CAPOO_CONFIG.display_name == "RPG猫猫虫", "Display name mismatch.")
	_expect(CAPOO_CONFIG.enemy_scene == CAPOO_SCENE, "RPG Capoo must use its own scene.")
	_expect(CAPOO_CONFIG.projectile_scene == ROCKET_SCENE, "RPG Capoo must use its rocket scene.")
	_expect(CAPOO_CONFIG.attack_audio_stream != null, "RPG fire audio is missing.")
	_expect(CAPOO_CONFIG.max_health == 200, "RPG health mismatch.")
	_expect(CAPOO_CONFIG.attack_damage == 20, "RPG damage mismatch.")
	_expect(CAPOO_CONFIG.physical_defense == 0, "RPG physical defense mismatch.")
	_expect(CAPOO_CONFIG.magic_defense == 0, "RPG magic defense mismatch.")
	_expect(is_equal_approx(CAPOO_CONFIG.move_speed, 16.0), "RPG move speed mismatch.")
	_expect(is_equal_approx(CAPOO_CONFIG.attack_range, 320.0), "RPG attack range mismatch.")
	_expect(is_equal_approx(CAPOO_CONFIG.attack_windup, 0.5), "RPG windup mismatch.")
	_expect(is_equal_approx(CAPOO_CONFIG.attack_interval, 6.0), "RPG cooldown mismatch.")
	_expect(is_equal_approx(CAPOO_CONFIG.projectile_speed, 210.0), "RPG rocket speed mismatch.")
	_expect(is_equal_approx(CAPOO_CONFIG.projectile_lifetime, 3.0), "RPG rocket lifetime mismatch.")
	_expect(is_equal_approx(CAPOO_CONFIG.explosion_radius, 44.0), "RPG explosion radius mismatch.")

	var rocket_frames := load("res://resources/animation/capoo_rpg_rocket.tres") as SpriteFrames
	var explosion_frames := load("res://resources/animation/capoo_rpg_explosion.tres") as SpriteFrames
	_expect(rocket_frames != null and rocket_frames.get_frame_count(&"fly") == 4, "RPG rocket frame count mismatch.")
	_expect(
		explosion_frames != null and explosion_frames.get_frame_count(&"explode") == 8,
		"RPG explosion frame count mismatch."
	)

	var texture := load("res://resources/texture/capoo_rpg.png") as Texture2D
	var rocket_texture := load("res://resources/texture/capoo_rpg_rocket.png") as Texture2D
	var explosion_texture := load("res://resources/texture/capoo_rpg_explosion.png") as Texture2D
	_expect(texture != null and texture.get_size() == Vector2(384, 384), "RPG sprite sheet size is incorrect.")
	_expect(rocket_texture != null and rocket_texture.get_size() == Vector2(128, 32), "RPG rocket sheet size is incorrect.")
	_expect(
		explosion_texture != null and explosion_texture.get_size() == Vector2(768, 96),
		"RPG explosion sheet size is incorrect."
	)

	var capoo_instance := CAPOO_SCENE.instantiate() as CapooRPG
	var rocket_instance := ROCKET_SCENE.instantiate() as CapooRPGRocket
	var explosion_instance := EXPLOSION_SCENE.instantiate() as CapooRPGExplosion
	_expect(capoo_instance != null, "RPG Capoo scene did not instantiate CapooRPG.")
	_expect(rocket_instance != null, "RPG rocket scene did not instantiate CapooRPGRocket.")
	_expect(explosion_instance != null, "RPG explosion scene did not instantiate CapooRPGExplosion.")
	if capoo_instance != null:
		_expect(capoo_instance.get_node_or_null("MuzzleHeat") is Polygon2D, "RPG scene is missing MuzzleHeat.")
		_expect(capoo_instance.get_node_or_null("AttackAudio") is AudioStreamPlayer2D, "RPG scene is missing AttackAudio.")
		var animated_sprite := capoo_instance.get_node("AnimatedSprite2D") as AnimatedSprite2D
		var scene_frames := animated_sprite.sprite_frames
		_expect(scene_frames != null, "RPG scene SpriteFrames are missing.")
		if scene_frames != null:
			_expect(scene_frames.get_frame_count(&"move") == 3, "RPG move frame count mismatch.")
			_expect(scene_frames.get_frame_count(&"windup") == 4, "RPG windup frame count mismatch.")
			_expect(scene_frames.get_frame_count(&"attack") == 4, "RPG attack frame count mismatch.")
			_expect(scene_frames.get_frame_count(&"death") == 3, "RPG death frame count mismatch.")
		var body_shape := capoo_instance.get_node("CollisionShape2D") as CollisionShape2D
		var touch_shape := capoo_instance.get_node("TouchDamageArea/CollisionShape2D") as CollisionShape2D
		_expect(body_shape.shape is RectangleShape2D, "RPG body collision must be scene-owned rectangle.")
		_expect(touch_shape.shape is RectangleShape2D, "RPG touch collision must be scene-owned rectangle.")
		_expect(body_shape.shape != touch_shape.shape, "RPG body and touch shapes must be independently editable.")
		capoo_instance.free()
	if rocket_instance != null:
		var explosion_shape := rocket_instance.get_node("ExplosionShape") as CollisionShape2D
		var explosion_circle := explosion_shape.shape as CircleShape2D
		_expect(
			explosion_circle != null and is_equal_approx(explosion_circle.radius, 44.0),
			"RPG rocket explosion shape radius mismatch."
		)
		rocket_instance.free()
	if explosion_instance != null:
		var explosion_audio := explosion_instance.get_node("ExplosionAudio") as AudioStreamPlayer2D
		_expect(explosion_audio.stream != null, "RPG explosion audio is missing.")
		explosion_instance.free()


func _test_windup_fire_and_cooldown() -> void:
	spawned_rockets.clear()
	var player := _spawn_player(Vector2(240.0, 0.0), 200)
	var enemy := _spawn_capoo(Vector2.ZERO, player)
	await _wait_physics_frames(3)

	_expect(enemy.combat_state == CapooRPG.CombatState.WINDUP, "RPG Capoo did not enter windup in range.")
	_expect(spawned_rockets.is_empty(), "RPG Capoo fired during early windup.")
	await _wait_physics_frames(20)
	_expect(spawned_rockets.is_empty(), "RPG Capoo fired before windup completed.")

	var guard_frames := 0
	while enemy.combat_state == CapooRPG.CombatState.WINDUP and guard_frames < 90:
		await physics_frame
		guard_frames += 1
	_expect(guard_frames < 90, "RPG windup did not finish in time.")
	await _wait_physics_frames(2)
	_expect(spawned_rockets.size() == 1, "RPG Capoo did not fire exactly one rocket.")

	await _wait_physics_frames(180)
	_expect(spawned_rockets.size() == 1, "RPG Capoo fired again during cooldown.")
	_expect(enemy.combat_state != CapooRPG.CombatState.WINDUP, "RPG Capoo re-entered windup during cooldown.")

	enemy.queue_free()
	player.queue_free()
	await physics_frame


func _test_world_obstruction_blocks_attack() -> void:
	spawned_rockets.clear()
	var player := _spawn_player(Vector2(240.0, 0.0), 100)
	var wall := _spawn_wall(Vector2(120.0, 0.0), 16.0)
	await physics_frame
	var enemy := _spawn_capoo(Vector2.ZERO, player)
	await _wait_physics_frames(24)

	_expect(enemy.combat_state == CapooRPG.CombatState.CHASE, "RPG Capoo attacked through a World-layer wall.")
	_expect(spawned_rockets.is_empty(), "RPG Capoo fired through a World-layer wall.")

	enemy.queue_free()
	wall.queue_free()
	player.queue_free()
	await physics_frame


func _test_rocket_explosion_paths() -> void:
	spawned_explosions.clear()
	var wall := _spawn_wall(Vector2(18.0, 0.0), 5.0)
	var wall_rocket := _spawn_rocket(Vector2.ZERO, Vector2.RIGHT, 20, 210.0, 3.0)
	await _wait_physics_frames(12)
	_expect(not is_instance_valid(wall_rocket), "RPG rocket did not explode on World collision.")
	_expect(spawned_explosions.size() >= 1, "RPG rocket did not spawn an explosion on World collision.")
	wall.queue_free()

	spawned_explosions.clear()
	var lifetime_rocket := _spawn_rocket(Vector2.ZERO, Vector2.RIGHT, 20, 0.0, 0.03)
	await _wait_physics_frames(5)
	_expect(not is_instance_valid(lifetime_rocket), "RPG rocket did not explode when its lifetime expired.")
	_expect(spawned_explosions.size() >= 1, "RPG rocket did not spawn an explosion on lifetime expiry.")

	spawned_explosions.clear()
	var player := _spawn_player(Vector2.ZERO, 100)
	await physics_frame
	var direct_rocket := _spawn_rocket(Vector2.ZERO, Vector2.RIGHT, 20, 0.0, 3.0)
	direct_rocket.call("_on_body_entered", player)
	await physics_frame
	_expect(player.current_health == 80, "Direct rocket hit did not deal exactly one explosion damage packet.")
	_expect(not is_instance_valid(direct_rocket), "RPG rocket remained after direct player hit.")
	_expect(spawned_explosions.size() >= 1, "RPG rocket did not spawn an explosion on player hit.")
	player.queue_free()
	await physics_frame


func _test_explosion_damage_contract() -> void:
	var near_player := _spawn_player(Vector2(38.0, 0.0), 100)
	var far_player := _spawn_player(Vector2(64.0, 0.0), 100)
	var enemy := CAPOO_SCENE.instantiate() as CapooRPG
	test_root.add_child(enemy)
	enemy.global_position = Vector2(20.0, 0.0)
	enemy.current_health = 37
	await physics_frame

	var rocket := _spawn_rocket(Vector2.ZERO, Vector2.RIGHT, 20, 0.0, 3.0)
	rocket.call("_explode")
	await physics_frame

	_expect(near_player.current_health == 80, "RPG explosion did not damage the player inside radius.")
	_expect(far_player.current_health == 100, "RPG explosion damaged a player outside radius.")
	_expect(enemy.current_health == 37, "RPG explosion damaged an enemy.")

	near_player.queue_free()
	far_player.queue_free()
	enemy.queue_free()
	await physics_frame


func _test_death_interrupts_attack() -> void:
	spawned_rockets.clear()
	var player := _spawn_player(Vector2(240.0, 0.0), 100)
	var enemy := _spawn_capoo(Vector2.ZERO, player)
	await _wait_physics_frames(3)

	_expect(enemy.combat_state == CapooRPG.CombatState.WINDUP, "Death test RPG did not enter windup.")
	enemy.apply_damage(CAPOO_CONFIG.max_health)
	await _wait_physics_frames(45)
	_expect(spawned_rockets.is_empty(), "Dead RPG Capoo fired after attack interruption.")

	if is_instance_valid(enemy):
		enemy.queue_free()
	player.queue_free()
	await physics_frame


func _test_proxy_action_visuals() -> void:
	var player := _spawn_player(Vector2(240.0, 0.0), 100)
	var enemy := _spawn_capoo(Vector2.ZERO, player)
	enemy.configure_multiplayer_proxy()
	enemy.play_multiplayer_enemy_action(&"windup", Vector2.RIGHT, 1)
	await process_frame
	_expect(enemy.muzzle_heat.visible, "Proxy RPG windup muzzle heat did not appear.")
	_expect(enemy.animated_sprite.animation == CAPOO_CONFIG.windup_animation_name, "Proxy RPG did not play windup animation.")
	enemy.play_multiplayer_enemy_action(&"fire", Vector2.RIGHT, 2)
	await process_frame
	_expect(enemy.muzzle_heat.visible, "Proxy RPG fire muzzle heat did not appear.")
	_expect(enemy.animated_sprite.animation == CAPOO_CONFIG.attack_animation_name, "Proxy RPG did not play fire animation.")
	enemy.queue_free()
	player.queue_free()
	await physics_frame


func _test_multiplayer_projectile_registry() -> void:
	var mp_game := MP_GAME_SCRIPT.new()
	var projectile := mp_game.call(
		"_instantiate_projectile",
		&"capoo_rpg_rocket",
		0,
		Vector2.RIGHT,
		20,
		210.0,
		3.0
	) as CapooRPGRocket
	_expect(projectile != null, "Multiplayer registry did not instantiate capoo_rpg_rocket.")
	if projectile != null:
		_expect(projectile.damage == 20, "Registry rocket damage mismatch.")
		_expect(is_equal_approx(projectile.speed, 210.0), "Registry rocket speed mismatch.")
		projectile.free()
	mp_game.free()


func _spawn_player(position: Vector2, health: int) -> Player:
	var player := PLAYER_SCENE.instantiate() as Player
	test_root.add_child(player)
	player.global_position = position
	player.collision_layer = 2
	player.invincibility_duration = 0.0
	player.invincibility_time_left = 0.0
	player.max_health = health
	player.current_health = health
	return player


func _spawn_capoo(position: Vector2, player: Player) -> CapooRPG:
	var enemy := CAPOO_SCENE.instantiate() as CapooRPG
	test_root.add_child(enemy)
	enemy.global_position = position
	enemy.setup(CAPOO_CONFIG, player)
	return enemy


func _spawn_rocket(
	position: Vector2,
	direction: Vector2,
	damage: int,
	speed: float,
	lifetime: float
) -> CapooRPGRocket:
	var rocket := ROCKET_SCENE.instantiate() as CapooRPGRocket
	test_root.add_child(rocket)
	rocket.global_position = position
	rocket.setup(direction, damage, speed, lifetime, CAPOO_CONFIG.explosion_radius)
	return rocket


func _spawn_wall(position: Vector2, radius: float) -> StaticBody2D:
	var wall := StaticBody2D.new()
	wall.collision_layer = 1
	wall.collision_mask = 0
	var wall_shape := CollisionShape2D.new()
	var circle := CircleShape2D.new()
	circle.radius = radius
	wall_shape.shape = circle
	wall.add_child(wall_shape)
	test_root.add_child(wall)
	wall.global_position = position
	return wall


func _on_child_entered_tree(child: Node) -> void:
	var rocket := child as CapooRPGRocket
	if rocket != null:
		spawned_rockets.append(rocket)
	var explosion := child as CapooRPGExplosion
	if explosion != null:
		spawned_explosions.append(explosion)


func _wait_physics_frames(frame_count: int) -> void:
	for _frame_index in range(frame_count):
		await physics_frame


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
