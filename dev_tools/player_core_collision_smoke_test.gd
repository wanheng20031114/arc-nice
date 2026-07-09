extends SceneTree

const PLAYER_SCENE := preload("res://scene/player.tscn")
const ENEMY_SCENE := preload("res://scene/enemy/enemy.tscn")
const ENEMY_CONFIG := preload("res://resources/config/enemies/yuanshi_insect_basic.tres")
const KNIGHT_CONFIG := preload("res://resources/config/enemies/capoo_knight.tres")
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

	await _test_player_core_marker_contract()
	await _test_enemy_base_collision_mask()
	await _test_enemy_velocity_limited_by_inner_core()
	await _test_enemy_chases_center_until_inner_limit()
	await _test_wide_enemy_inner_limit_still_allows_touch_overlap()
	await _test_player_motion_can_overlap_enemy_core()
	await _test_all_enemy_scenes_ignore_player_core_wall_mask()

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


func _test_player_core_marker_contract() -> void:
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
	_expect(core_body != null, "Player must include NoEnteyCore as the inner-radius marker.")
	if core_body != null:
		_expect(core_body.collision_layer == 0, "NoEnteyCore marker must not create a physics wall.")
		_expect(core_body.collision_mask == 0, "NoEnteyCore marker must not scan other layers.")
		var core_shape := core_body.get_node_or_null("CollisionShape2D") as CollisionShape2D
		var core_circle := core_shape.shape as CircleShape2D if core_shape != null else null
		_expect(core_circle != null, "NoEnteyCore marker must keep a CircleShape2D radius.")
		if core_circle != null and body_circle != null:
			_expect(core_circle.radius > 0.0, "NoEnteyCore radius must be positive.")
			_expect(core_circle.radius < body_circle.radius, "NoEnteyCore should stay inside the player body.")
	player.queue_free()
	await physics_frame


func _test_enemy_base_collision_mask() -> void:
	var enemy := ENEMY_SCENE.instantiate() as Enemy
	_expect(enemy != null, "Base enemy scene must instantiate.")
	if enemy == null:
		return
	test_root.add_child(enemy)
	await process_frame
	await physics_frame

	_expect((enemy.collision_mask & WORLD_LAYER) != 0, "Enemy body must keep colliding with World.")
	_expect((enemy.collision_mask & PLAYER_CORE_LAYER) == 0, "Enemy body must not collide with PlayerCore as a physics wall.")
	_expect((enemy.collision_mask & PLAYER_LAYER) == 0, "Enemy body must not collide with the regular Player body.")
	var touch_area := enemy.get_node_or_null("TouchDamageArea") as Area2D
	_expect(touch_area != null, "Enemy touch damage area must exist.")
	if touch_area != null:
		_expect((touch_area.collision_mask & PLAYER_LAYER) != 0, "Touch damage area must still listen to Player.")
	enemy.queue_free()
	await physics_frame


func _test_enemy_velocity_limited_by_inner_core() -> void:
	var player := PLAYER_SCENE.instantiate() as Player
	var enemy := ENEMY_CONFIG.enemy_scene.instantiate() as Enemy
	_expect(player != null and enemy != null, "Player and enemy scenes must instantiate for velocity limit.")
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

	var core_shape := _get_core_shape(player)
	var core_radius := _get_circle_radius(core_shape)
	var enemy_radius := _get_touch_damage_inner_radius(enemy)
	var minimum_distance := core_radius + enemy_radius
	_expect(core_radius > 0.0 and enemy_radius > 0.0, "Velocity limit test needs valid core and touch radii.")

	enemy.global_position = core_shape.global_position + Vector2.LEFT * (minimum_distance + 3.0)
	await physics_frame
	enemy.velocity = Vector2.RIGHT * 60.0
	enemy.call("_limit_velocity_against_target_player_core", 1.0)
	var projected_distance := (enemy.touch_damage_area.global_position + enemy.velocity).distance_to(core_shape.global_position)
	_expect(
		projected_distance >= minimum_distance - 0.01,
		"Enemy inward velocity must be clipped before its touch area enters the player inner core."
	)

	enemy.velocity = Vector2.LEFT * 60.0
	enemy.call("_limit_velocity_against_target_player_core", 1.0)
	_expect(
		enemy.velocity.distance_to(Vector2.LEFT * 60.0) < 0.001,
		"Enemy outward velocity must not be clipped by the player inner core."
	)

	enemy.queue_free()
	player.queue_free()
	await physics_frame


func _test_enemy_chases_center_until_inner_limit() -> void:
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
	player.invincibility_duration = 0.0
	player.invincibility_time_left = 0.0
	test_root.add_child(enemy)
	enemy.setup(ENEMY_CONFIG, player)
	await process_frame
	await physics_frame

	var core_shape := _get_core_shape(player)
	var player_shape := player.get_node_or_null("CollisionShape2D") as CollisionShape2D
	var core_radius := _get_circle_radius(core_shape)
	var player_radius := _get_circle_radius(player_shape)
	var enemy_radius := _get_touch_damage_inner_radius(enemy)
	var enemy_touch_extent_radius := _get_touch_damage_extent_radius(enemy)
	var minimum_distance := core_radius + enemy_radius
	var touch_damage_distance := player_radius + enemy_touch_extent_radius
	_expect(core_radius > 0.0 and enemy_radius > 0.0, "Chase test needs valid core and touch radii.")
	if core_shape == null:
		enemy.queue_free()
		player.queue_free()
		await physics_frame
		return

	var initial_distance := minimum_distance + 12.0
	enemy.global_position = core_shape.global_position + Vector2.LEFT * initial_distance
	await physics_frame
	var player_health_before := player.current_health

	for _frame_index in range(120):
		await physics_frame

	var final_distance := enemy.touch_damage_area.global_position.distance_to(core_shape.global_position)
	_expect(
		final_distance >= minimum_distance - 0.75,
		"Moving enemy entered the player inner core under its own movement."
	)
	_expect(
		final_distance < touch_damage_distance,
		"Moving enemy was blocked before its touch damage area reached the player body."
	)
	_expect(
		player.current_health < player_health_before,
		"Moving enemy reached the limit but did not damage the player."
	)
	_expect(
		final_distance < initial_distance - 4.0,
		"Moving enemy did not continue chasing toward the player's center."
	)

	enemy.queue_free()
	player.queue_free()
	await physics_frame


func _test_wide_enemy_inner_limit_still_allows_touch_overlap() -> void:
	var player := PLAYER_SCENE.instantiate() as Player
	var enemy := KNIGHT_CONFIG.enemy_scene.instantiate() as Enemy
	_expect(player != null and enemy != null, "Player and wide enemy scenes must instantiate for overlap test.")
	if player == null or enemy == null:
		if player != null:
			player.free()
		if enemy != null:
			enemy.free()
		return
	test_root.add_child(player)
	player.global_position = Vector2.ZERO
	test_root.add_child(enemy)
	enemy.setup(KNIGHT_CONFIG, player)
	enemy.set_physics_process(false)
	await process_frame
	await physics_frame

	var core_shape := _get_core_shape(player)
	var core_radius := _get_circle_radius(core_shape)
	var blocking_radius := float(enemy.call("_get_player_core_blocking_radius"))
	_expect(core_radius > 0.0 and blocking_radius > 0.0, "Wide enemy overlap test needs valid core and blocking radii.")
	if core_shape == null:
		enemy.queue_free()
		player.queue_free()
		await physics_frame
		return

	enemy.global_position = core_shape.global_position + Vector2.LEFT * (core_radius + blocking_radius + 4.0)
	await physics_frame
	enemy.velocity = Vector2.RIGHT * 80.0
	enemy.call("_limit_velocity_against_target_player_core", 1.0)
	enemy.global_position += enemy.velocity
	await physics_frame

	_expect(
		_area_overlaps_body(enemy.touch_damage_area, player),
		"Wide enemies must still overlap the player with TouchDamageArea at the inner-core limit."
	)

	enemy.queue_free()
	player.queue_free()
	await physics_frame


func _test_player_motion_can_overlap_enemy_core() -> void:
	var player := PLAYER_SCENE.instantiate() as Player
	var enemy := ENEMY_SCENE.instantiate() as Enemy
	_expect(player != null and enemy != null, "Player and enemy scenes must instantiate for player overlap test.")
	if player == null or enemy == null:
		if player != null:
			player.free()
		if enemy != null:
			enemy.free()
		return
	test_root.add_child(player)
	test_root.add_child(enemy)
	await process_frame
	await physics_frame

	var core_shape := _get_core_shape(player)
	var enemy_shape := enemy.get_node_or_null("CollisionShape2D") as CollisionShape2D
	_expect(core_shape != null and enemy_shape != null, "Player overlap test needs core and enemy shapes.")
	if core_shape == null or enemy_shape == null:
		enemy.queue_free()
		player.queue_free()
		await physics_frame
		return

	enemy.global_position = Vector2.ZERO
	var enemy_position_before := enemy.global_position
	player.global_position = enemy_shape.global_position - core_shape.position
	await physics_frame

	_expect(
		enemy.global_position.distance_to(enemy_position_before) < 0.001,
		"Moving the player inner core onto an enemy must not push the enemy away."
	)
	_expect(
		_body_shape_overlaps_player_core_geometry(enemy_shape, core_shape),
		"Player movement should be able to place the enemy inside the player body/core."
	)

	enemy.queue_free()
	player.queue_free()
	await physics_frame


func _test_all_enemy_scenes_ignore_player_core_wall_mask() -> void:
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
			(enemy.collision_mask & PLAYER_CORE_LAYER) == 0,
			"%s body must ignore PlayerCore as a physics wall." % config.display_name
		)
		enemy.queue_free()
		await physics_frame


func _get_core_shape(player: Player) -> CollisionShape2D:
	if player == null:
		return null
	return player.get_node_or_null("NoEnteyCore/CollisionShape2D") as CollisionShape2D


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


func _get_touch_damage_extent_radius(enemy: Enemy) -> float:
	if enemy == null:
		return 0.0
	var max_radius := 0.0
	var touch_area := enemy.get_node_or_null("TouchDamageArea")
	if touch_area == null:
		return 0.0
	for child in touch_area.get_children():
		var shape_node := child as CollisionShape2D
		if shape_node == null:
			continue
		max_radius = maxf(max_radius, _get_shape_extent_radius(shape_node))
	return max_radius


func _get_touch_damage_inner_radius(enemy: Enemy) -> float:
	if enemy == null:
		return 0.0
	var max_radius := 0.0
	var touch_area := enemy.get_node_or_null("TouchDamageArea")
	if touch_area == null:
		return 0.0
	for child in touch_area.get_children():
		var shape_node := child as CollisionShape2D
		if shape_node == null:
			continue
		var half_extents := _get_shape_half_extents(shape_node)
		max_radius = maxf(max_radius, minf(half_extents.x, half_extents.y))
	return max_radius


func _get_shape_half_extents(shape_node: CollisionShape2D) -> Vector2:
	if shape_node == null or shape_node.shape == null:
		return Vector2.ZERO
	var shape_rect := shape_node.shape.get_rect()
	var corners := [
		shape_rect.position,
		shape_rect.position + Vector2(shape_rect.size.x, 0.0),
		shape_rect.position + Vector2(0.0, shape_rect.size.y),
		shape_rect.position + shape_rect.size,
	]
	var min_position := Vector2(INF, INF)
	var max_position := Vector2(-INF, -INF)
	for corner in corners:
		var transformed_corner: Vector2 = shape_node.transform * (corner as Vector2)
		min_position.x = minf(min_position.x, transformed_corner.x)
		min_position.y = minf(min_position.y, transformed_corner.y)
		max_position.x = maxf(max_position.x, transformed_corner.x)
		max_position.y = maxf(max_position.y, transformed_corner.y)
	return Vector2(
		maxf(absf(min_position.x), absf(max_position.x)),
		maxf(absf(min_position.y), absf(max_position.y))
	)


func _area_overlaps_body(area: Area2D, body: Node2D) -> bool:
	if area == null or body == null:
		return false
	for overlapping_body in area.get_overlapping_bodies():
		if overlapping_body == body:
			return true
	return false


func _body_shape_overlaps_player_core_geometry(
	body_shape: CollisionShape2D,
	core_shape: CollisionShape2D
) -> bool:
	if body_shape == null or core_shape == null:
		return false
	var body_radius := _get_shape_extent_radius(body_shape)
	var core_radius := _get_circle_radius(core_shape)
	if body_radius <= 0.0 or core_radius <= 0.0:
		return false
	return body_shape.global_position.distance_to(core_shape.global_position) < body_radius + core_radius


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
