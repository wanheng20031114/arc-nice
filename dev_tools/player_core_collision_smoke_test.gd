extends SceneTree

const PLAYER_SCENE := preload("res://scene/player.tscn")
const ENEMY_SCENE := preload("res://scene/enemy/enemy.tscn")
const ENEMY_CONFIG := preload("res://resources/config/enemies/yuanshi_insect_basic.tres")
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
	preload("res://resources/config/enemies/linglan_boss.tres"),
]
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

	await _test_player_core_wall_contract()
	await _test_enemy_base_wall_mask()
	await _test_enemy_body_blocked_by_inner_wall()
	await _test_enemy_chases_center_until_inner_wall()
	await _test_all_enemy_scenes_inherit_player_core_wall_mask()

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


func _test_player_core_wall_contract() -> void:
	var player := PLAYER_SCENE.instantiate() as Player
	_expect(player != null, "Player scene must instantiate.")
	if player == null:
		return
	test_root.add_child(player)
	await process_frame
	await physics_frame

	var body_shape := player.get_node_or_null("CollisionShape2D") as CollisionShape2D
	var body_circle := body_shape.shape as CircleShape2D if body_shape != null else null
	var core_body := player.get_node_or_null("NoEnteyCore") as CollisionObject2D
	_expect(core_body != null, "Player must include NoEnteyCore as a wall body.")
	if core_body != null:
		_expect((core_body.collision_layer & PLAYER_CORE_LAYER) != 0, "NoEnteyCore wall must live on PlayerCore layer.")
		_expect(core_body.collision_mask == 0, "NoEnteyCore wall must not scan other layers.")
		var animatable := core_body as AnimatableBody2D
		if animatable != null:
			_expect(not animatable.sync_to_physics, "NoEnteyCore wall must follow the player transform directly.")
		var core_shape := core_body.get_node_or_null("CollisionShape2D") as CollisionShape2D
		var core_circle := core_shape.shape as CircleShape2D if core_shape != null else null
		_expect(core_circle != null, "NoEnteyCore wall must own a CircleShape2D.")
		if core_circle != null and body_circle != null:
			_expect(core_circle.radius > 0.0, "NoEnteyCore radius must be positive.")
			_expect(core_circle.radius < body_circle.radius, "NoEnteyCore should stay inside the player body.")
	player.queue_free()
	await physics_frame


func _test_enemy_base_wall_mask() -> void:
	var enemy := ENEMY_SCENE.instantiate() as Enemy
	_expect(enemy != null, "Base enemy scene must instantiate.")
	if enemy == null:
		return
	test_root.add_child(enemy)
	await process_frame
	await physics_frame

	_expect((enemy.collision_mask & WORLD_LAYER) != 0, "Enemy body must keep colliding with World.")
	_expect((enemy.collision_mask & PLAYER_CORE_LAYER) != 0, "Enemy body must collide with PlayerCore wall.")
	_expect((enemy.collision_mask & PLAYER_LAYER) == 0, "Enemy body must not collide with the regular Player body.")
	var touch_area := enemy.get_node_or_null("TouchDamageArea") as Area2D
	_expect(touch_area != null, "Enemy touch damage area must exist.")
	if touch_area != null:
		_expect((touch_area.collision_mask & PLAYER_LAYER) != 0, "Touch damage area must still listen to Player.")
	enemy.queue_free()
	await physics_frame


func _test_enemy_body_blocked_by_inner_wall() -> void:
	var player := PLAYER_SCENE.instantiate() as Player
	var enemy := ENEMY_SCENE.instantiate() as Enemy
	_expect(player != null and enemy != null, "Player and enemy scenes must instantiate for wall collision.")
	if player == null or enemy == null:
		if player != null:
			player.free()
		if enemy != null:
			enemy.free()
		return
	test_root.add_child(player)
	player.global_position = Vector2.ZERO
	test_root.add_child(enemy)
	enemy.setup(ENEMY_CONFIG, player)
	await process_frame
	await physics_frame

	var core_shape := player.get_node_or_null("NoEnteyCore/CollisionShape2D") as CollisionShape2D
	var player_shape := player.get_node_or_null("CollisionShape2D") as CollisionShape2D
	var enemy_shape := enemy.get_node_or_null("CollisionShape2D") as CollisionShape2D
	var core_radius := _get_circle_radius(core_shape)
	var player_radius := _get_circle_radius(player_shape)
	var enemy_radius := _get_shape_extent_radius(enemy_shape)
	_expect(core_radius > 0.0 and enemy_radius > 0.0, "Wall test needs valid core and enemy radii.")

	var start_distance := core_radius + enemy_radius + 1.0
	enemy.global_position = (core_shape.global_position if core_shape != null else Vector2.ZERO) + Vector2.LEFT * start_distance
	await physics_frame

	_expect(start_distance < player_radius + enemy_radius, "Enemy test position must place body inside the player's outer body ring.")
	_expect(enemy.test_move(enemy.global_transform, Vector2.RIGHT * 2.0), "Enemy body must be blocked by the NoEnteyCore wall.")
	_expect(not enemy.test_move(enemy.global_transform, Vector2.LEFT * 2.0), "Enemy body must remain free to move away from NoEnteyCore.")

	enemy.queue_free()
	player.queue_free()
	await physics_frame


func _test_enemy_chases_center_until_inner_wall() -> void:
	var player := PLAYER_SCENE.instantiate() as Player
	var enemy := ENEMY_CONFIG.enemy_scene.instantiate() as Enemy
	_expect(player != null and enemy != null, "Player and moving enemy scene must instantiate for chase test.")
	if player == null or enemy == null:
		if player != null:
			player.free()
		if enemy != null:
			enemy.free()
		return
	test_root.add_child(player)
	player.global_position = Vector2.ZERO
	test_root.add_child(enemy)
	enemy.setup(ENEMY_CONFIG, player)
	await process_frame
	await physics_frame

	var core_shape := player.get_node_or_null("NoEnteyCore/CollisionShape2D") as CollisionShape2D
	var player_shape := player.get_node_or_null("CollisionShape2D") as CollisionShape2D
	var enemy_shape := enemy.get_node_or_null("CollisionShape2D") as CollisionShape2D
	var core_radius := _get_circle_radius(core_shape)
	var player_radius := _get_circle_radius(player_shape)
	var enemy_radius := _get_shape_extent_radius(enemy_shape)
	_expect(core_radius > 0.0 and enemy_radius > 0.0, "Chase test needs valid core and enemy radii.")
	if core_shape == null:
		enemy.queue_free()
		player.queue_free()
		await physics_frame
		return

	var initial_distance := core_radius + enemy_radius + 12.0
	enemy.global_position = core_shape.global_position + Vector2.LEFT * initial_distance
	await physics_frame

	for _frame_index in range(120):
		await physics_frame

	var final_distance := enemy_shape.global_position.distance_to(core_shape.global_position)
	var outer_body_distance := player_radius + enemy_radius
	_expect(
		not _body_shape_overlaps_player_core(enemy_shape),
		"Moving enemy entered the NoEnteyCore inner wall."
	)
	_expect(
		enemy.test_move(enemy.global_transform, Vector2.RIGHT),
		"Moving enemy was not blocked by the NoEnteyCore wall when continuing toward the player center."
	)
	_expect(
		final_distance < outer_body_distance,
		"Moving enemy was blocked before its body entered the player's outer ring."
	)
	_expect(
		final_distance < initial_distance - 4.0,
		"Moving enemy did not continue chasing the player's center."
	)

	enemy.queue_free()
	player.queue_free()
	await physics_frame


func _test_all_enemy_scenes_inherit_player_core_wall_mask() -> void:
	for enemy_config in ENEMY_CONFIGS_TO_CHECK:
		var config := enemy_config as EnemyConfig
		_expect(config != null, "Enemy config must load for PlayerCore mask coverage.")
		if config == null or config.enemy_scene == null:
			continue
		var enemy := config.enemy_scene.instantiate() as Enemy
		_expect(enemy != null, "%s scene must instantiate as Enemy." % config.display_name)
		if enemy == null:
			continue
		test_root.add_child(enemy)
		await process_frame
		await physics_frame
		_expect(
			(enemy.collision_mask & PLAYER_CORE_LAYER) != 0,
			"%s body must inherit PlayerCore wall collision from the base enemy scene." % config.display_name
		)
		enemy.queue_free()
		await physics_frame


func _get_circle_radius(shape_node: CollisionShape2D) -> float:
	if shape_node == null:
		return 0.0
	var circle := shape_node.shape as CircleShape2D
	if circle == null:
		return 0.0
	return circle.radius


func _get_shape_extent_radius(shape_node: CollisionShape2D) -> float:
	if shape_node == null or shape_node.shape == null:
		return 0.0
	var circle := shape_node.shape as CircleShape2D
	if circle != null:
		var scale := shape_node.transform.get_scale()
		return circle.radius * maxf(absf(scale.x), absf(scale.y))
	var shape_rect := shape_node.shape.get_rect()
	var corners := [
		shape_rect.position,
		shape_rect.position + Vector2(shape_rect.size.x, 0.0),
		shape_rect.position + Vector2(0.0, shape_rect.size.y),
		shape_rect.position + shape_rect.size,
	]
	var max_radius := 0.0
	for corner in corners:
		max_radius = maxf(max_radius, (shape_node.transform * (corner as Vector2)).length())
	return max_radius


func _body_shape_overlaps_player_core(shape_node: CollisionShape2D) -> bool:
	if shape_node == null or shape_node.shape == null or test_root == null:
		return false
	var params := PhysicsShapeQueryParameters2D.new()
	params.shape = shape_node.shape
	params.transform = shape_node.global_transform
	params.collision_mask = PLAYER_CORE_LAYER
	params.collide_with_bodies = true
	params.collide_with_areas = false
	return not test_root.get_world_2d().direct_space_state.intersect_shape(params, 8).is_empty()


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
