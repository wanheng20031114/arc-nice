extends SceneTree

const PLAYER_SCENE := preload("res://scene/player.tscn")
const ENEMY_SCENE := preload("res://scene/enemy/enemy.tscn")
const ENEMY_CONFIG := preload("res://resources/config/enemies/yuanshi_insect_basic.tres")
const WORLD_LAYER := 1 << 0
const PLAYER_LAYER := 1 << 1
const PLAYER_CORE_LAYER := 1 << 9

var failures: Array[String] = []
var test_root: Node2D


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	test_root = Node2D.new()
	test_root.name = "PlayerCoreCollisionSmokeTest"
	root.add_child(test_root)
	current_scene = test_root

	await _test_player_core_contract()
	await _test_enemy_body_collides_with_player_core_only()

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


func _test_player_core_contract() -> void:
	var player := PLAYER_SCENE.instantiate() as Player
	_expect(player != null, "Player scene must instantiate.")
	if player == null:
		return
	test_root.add_child(player)
	await process_frame
	await physics_frame

	var body_shape := player.get_node_or_null("CollisionShape2D") as CollisionShape2D
	var body_circle: CircleShape2D = null
	if body_shape != null:
		body_circle = body_shape.shape as CircleShape2D
	var core := player.get_node_or_null("NoEnteyCore") as AnimatableBody2D
	_expect(core != null, "Player must include NoEnteyCore.")
	if core != null:
		_expect((core.collision_layer & PLAYER_CORE_LAYER) != 0, "NoEnteyCore must live on PlayerCore physics layer.")
		_expect(core.collision_mask == 0, "NoEnteyCore must not actively scan other layers.")
		var core_shape := core.get_node_or_null("CollisionShape2D") as CollisionShape2D
		var core_circle: CircleShape2D = null
		if core_shape != null:
			core_circle = core_shape.shape as CircleShape2D
		_expect(core_circle != null, "NoEnteyCore must use a CircleShape2D.")
		if core_circle != null and body_circle != null:
			_expect(core_circle.radius > body_circle.radius, "NoEnteyCore must be larger than the damage/player body shape.")

	player.queue_free()
	await physics_frame


func _test_enemy_body_collides_with_player_core_only() -> void:
	var player := PLAYER_SCENE.instantiate() as Player
	var enemy := ENEMY_SCENE.instantiate() as Enemy
	_expect(player != null and enemy != null, "Player and enemy scenes must instantiate.")
	if player == null or enemy == null:
		if player != null:
			player.free()
		if enemy != null:
			enemy.free()
		return
	test_root.add_child(player)
	player.global_position = Vector2.ZERO
	test_root.add_child(enemy)
	enemy.global_position = Vector2(-24.0, 0.0)
	enemy.setup(ENEMY_CONFIG, player)
	await process_frame
	await physics_frame

	_expect((enemy.collision_mask & WORLD_LAYER) != 0, "Enemy body must keep colliding with the world layer.")
	_expect((enemy.collision_mask & PLAYER_CORE_LAYER) != 0, "Enemy body must collide with PlayerCore.")
	_expect((enemy.collision_mask & PLAYER_LAYER) == 0, "Enemy body must not collide with the regular Player layer.")
	var touch_area := enemy.get_node_or_null("TouchDamageArea") as Area2D
	_expect(touch_area != null, "Enemy touch damage area must exist.")
	if touch_area != null:
		_expect((touch_area.collision_mask & PLAYER_LAYER) != 0, "Touch damage area must still listen to regular Player bodies.")

	enemy.global_position = Vector2(-24.0, 0.0)
	await physics_frame
	_expect(enemy.test_move(enemy.global_transform, Vector2.RIGHT * 8.0), "Enemy body must be blocked before overlapping the player core.")
	_expect(not enemy.test_move(enemy.global_transform, Vector2.LEFT * 8.0), "Enemy body should remain free to move away from the player core.")

	enemy.queue_free()
	player.queue_free()
	await physics_frame


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
