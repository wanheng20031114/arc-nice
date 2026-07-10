extends SceneTree

const KNIGHT_SCENE := preload("res://scene/enemy/capoo_knight.tscn")
const ELITE_KNIGHT_SCENE := preload("res://scene/enemy/capoo_knight_elite.tscn")
const SWORDSMAN_SCENE := preload("res://scene/enemy/capoo_swordsman.tscn")
const PLAYER_SCENE := preload("res://scene/player.tscn")
const KNIGHT_CONFIG := preload("res://resources/config/enemies/capoo_knight.tres")
const ELITE_KNIGHT_CONFIG := preload("res://resources/config/enemies/capoo_knight_elite.tres")
const SWORDSMAN_CONFIG := preload("res://resources/config/enemies/capoo_swordsman.tres")
const WAVES := [
	preload("res://resources/config/waves/wave_06.tres"),
	preload("res://resources/config/waves/wave_07.tres"),
	preload("res://resources/config/waves/wave_08.tres"),
	preload("res://resources/config/waves/wave_09.tres"),
	preload("res://resources/config/waves/wave_10.tres"),
	preload("res://resources/config/waves/wave_11.tres"),
]
const EXPECTED_KNIGHT_COUNTS := [60, 50, 0, 20, 20, 10]
const EXPECTED_ELITE_KNIGHT_COUNTS := [0, 0, 0, 20, 20, 60]
const EXPECTED_WAVE_TOTALS := [470, 440, 420, 400, 465, 480]
var failures: Array[String] = []
var test_root: Node2D


class FakePathfinder:
	extends Node

	var is_built := true
	var requested_path := false
	var budget_available := true
	var path := PackedVector2Array()

	func get_global_path(
		_from_global_position: Vector2,
		_to_global_position: Vector2,
		_agent_half_extents: Vector2 = Vector2.ZERO
	) -> PackedVector2Array:
		requested_path = true
		return path

	func try_get_global_path(
		_from_global_position: Vector2,
		_to_global_position: Vector2,
		_agent_half_extents: Vector2 = Vector2.ZERO
	) -> Variant:
		requested_path = true
		if not budget_available:
			return null
		return path


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	test_root = Node2D.new()
	test_root.name = "CapooKnightSmokeTest"
	root.add_child(test_root)
	current_scene = test_root

	_test_resource_contract()
	_test_elite_resource_contract()
	await _test_knight_runtime_facing()
	await _test_elite_runtime_facing()
	await _test_slash_geometry()
	await _test_windup_delays_damage()
	await _test_death_interrupts_attack()
	await _test_proxy_action_visuals()
	await _test_swordsman_uses_path_when_corner_blocks_direct_chase()
	await _test_path_waypoint_motion_does_not_cut_corners()
	await _test_navigation_budget_retry_keeps_existing_path()

	test_root.queue_free()
	await process_frame
	await physics_frame
	for _cleanup_frame in range(4):
		await process_frame

	if failures.is_empty():
		print("CAPOO_KNIGHT_SMOKE_TEST_OK")
		quit()
		return

	for failure in failures:
		push_error(failure)
	quit(1)


func _test_resource_contract() -> void:
	_expect(KNIGHT_CONFIG is CapooKnightConfig, "Knight config must use CapooKnightConfig.")
	_expect(KNIGHT_CONFIG.display_name == "骑士猫猫虫", "Display name mismatch.")
	_expect(KNIGHT_CONFIG.enemy_scene == KNIGHT_SCENE, "Knight must use its own scene.")
	_expect(KNIGHT_CONFIG.max_health == 200, "Knight health mismatch.")
	_expect(KNIGHT_CONFIG.attack_damage == 28, "Knight slash damage mismatch.")
	_expect(KNIGHT_CONFIG.physical_defense == 10, "Knight physical defense mismatch.")
	_expect(KNIGHT_CONFIG.magic_defense == 0, "Knight magic defense mismatch.")
	_expect(is_equal_approx(KNIGHT_CONFIG.move_speed, 34.0), "Knight move speed mismatch.")
	_expect(is_equal_approx(KNIGHT_CONFIG.attack_interval, 4.0), "Knight attack interval mismatch.")
	_expect(is_equal_approx(KNIGHT_CONFIG.attack_windup, 0.35), "Knight windup mismatch.")
	_expect(is_equal_approx(KNIGHT_CONFIG.slash_outer_radius, 48.0), "Knight slash outer radius mismatch.")
	_expect(is_equal_approx(KNIGHT_CONFIG.slash_inner_radius, 6.5), "Knight slash inner radius mismatch.")
	_expect(is_equal_approx(KNIGHT_CONFIG.slash_angle_degrees, 60.0), "Knight slash angle mismatch.")
	_expect(KNIGHT_CONFIG.slash_effect_scene != null, "Knight slash effect scene is missing.")
	_expect(_resource_path(KNIGHT_CONFIG.attack_audio_stream).ends_with("capoo_sword_slash_heavy.wav"), "Knight slash audio mismatch.")

	var texture := load("res://resources/texture/capoo_knight.png") as Texture2D
	var slash_texture := load("res://resources/texture/capoo_knight_slash.png") as Texture2D
	_expect(texture != null and texture.get_size() == Vector2(384, 384), "Knight sprite sheet size is incorrect.")
	_expect(slash_texture != null and slash_texture.get_size() == Vector2(384, 96), "Knight slash sheet size is incorrect.")
	var knight_instance := KNIGHT_SCENE.instantiate() as CapooKnight
	var animated_sprite := knight_instance.get_node("AnimatedSprite2D") as AnimatedSprite2D
	var body_shapes := _collect_direct_collision_shapes(knight_instance)
	var touch_shapes := _collect_direct_collision_shapes(knight_instance.get_node("TouchDamageArea"))
	_expect(animated_sprite.sprite_frames != null and animated_sprite.sprite_frames.has_animation(&"move"), "Knight scene must own its move animation.")
	_expect(knight_instance.sprite_faces_left_by_default, "Knight sprite sheet faces left by default and must declare that.")
	_expect(animated_sprite.flip_h, "Knight editor preview must face right by flipping its left-facing sheet.")
	_expect(body_shapes.size() == 2, "Knight body collision should use both configured CollisionShape2D nodes.")
	_expect(touch_shapes.size() == 2, "Knight touch damage should use both configured CollisionShape2D nodes.")
	for body_shape in body_shapes:
		_expect(body_shape.shape is RectangleShape2D, "Knight body collision must use scene-owned rectangles.")
	for touch_shape in touch_shapes:
		_expect(touch_shape.shape is RectangleShape2D, "Knight touch collision must use scene-owned rectangles.")
	_expect(_are_shapes_independent(body_shapes, touch_shapes), "Knight body and touch shapes must be independently editable.")
	knight_instance.free()

	for index in range(WAVES.size()):
		_expect(_count_wave_entries(WAVES[index]) == EXPECTED_KNIGHT_COUNTS[index], "Knight wave count mismatch.")
		_expect(
			_count_wave_entries_for_config(WAVES[index], ELITE_KNIGHT_CONFIG) == EXPECTED_ELITE_KNIGHT_COUNTS[index],
			"Elite knight wave count mismatch."
		)
		_expect(_count_total_wave_entries(WAVES[index]) == EXPECTED_WAVE_TOTALS[index], "Wave total changed unexpectedly.")


func _test_elite_resource_contract() -> void:
	_expect(ELITE_KNIGHT_CONFIG is CapooKnightConfig, "Elite knight config must use CapooKnightConfig.")
	_expect(ELITE_KNIGHT_CONFIG.display_name == "精英骑士猫猫虫", "Elite knight display name mismatch.")
	_expect(ELITE_KNIGHT_CONFIG.enemy_scene == ELITE_KNIGHT_SCENE, "Elite knight must use its own scene.")
	_expect(ELITE_KNIGHT_CONFIG.max_health == 350, "Elite knight health mismatch.")
	_expect(ELITE_KNIGHT_CONFIG.attack_damage == KNIGHT_CONFIG.attack_damage, "Elite knight slash damage must match knight.")
	_expect(ELITE_KNIGHT_CONFIG.physical_defense == 15, "Elite knight physical defense mismatch.")
	_expect(ELITE_KNIGHT_CONFIG.magic_defense == 0, "Elite knight magic defense mismatch.")
	_expect(is_equal_approx(ELITE_KNIGHT_CONFIG.move_speed, KNIGHT_CONFIG.move_speed), "Elite knight move speed must match knight.")
	_expect(is_equal_approx(ELITE_KNIGHT_CONFIG.attack_interval, 2.0), "Elite knight attack interval mismatch.")
	_expect(is_equal_approx(ELITE_KNIGHT_CONFIG.attack_range, KNIGHT_CONFIG.attack_range), "Elite knight attack range must match knight.")
	_expect(is_equal_approx(ELITE_KNIGHT_CONFIG.attack_windup, KNIGHT_CONFIG.attack_windup), "Elite knight windup must match knight.")
	_expect(is_equal_approx(ELITE_KNIGHT_CONFIG.slash_outer_radius, KNIGHT_CONFIG.slash_outer_radius), "Elite knight slash outer radius must match knight.")
	_expect(is_equal_approx(ELITE_KNIGHT_CONFIG.slash_inner_radius, KNIGHT_CONFIG.slash_inner_radius), "Elite knight slash inner radius must match knight.")
	_expect(is_equal_approx(ELITE_KNIGHT_CONFIG.slash_angle_degrees, KNIGHT_CONFIG.slash_angle_degrees), "Elite knight slash angle must match knight.")
	_expect(ELITE_KNIGHT_CONFIG.slash_effect_scene == KNIGHT_CONFIG.slash_effect_scene, "Elite knight must reuse knight slash effect.")
	_expect(_resource_path(ELITE_KNIGHT_CONFIG.attack_audio_stream).ends_with("capoo_sword_slash_heavy.wav"), "Elite knight slash audio mismatch.")

	var texture := load("res://resources/texture/capoo_knight_elite.png") as Texture2D
	_expect(texture != null and texture.get_size() == Vector2(384, 384), "Elite knight sprite sheet size is incorrect.")

	var knight_instance := KNIGHT_SCENE.instantiate() as CapooKnight
	var elite_instance := ELITE_KNIGHT_SCENE.instantiate() as CapooKnight
	_expect(elite_instance != null, "Elite knight scene must instantiate CapooKnight.")
	if knight_instance == null or elite_instance == null:
		if knight_instance != null:
			knight_instance.free()
		if elite_instance != null:
			elite_instance.free()
		return

	var animated_sprite := elite_instance.get_node("AnimatedSprite2D") as AnimatedSprite2D
	_expect(animated_sprite.sprite_frames != null, "Elite knight scene must own SpriteFrames.")
	if animated_sprite.sprite_frames != null:
		for animation_name in [&"move", &"windup", &"attack", &"death"]:
			_expect(
				animated_sprite.sprite_frames.has_animation(animation_name),
				"Elite knight sprite frames must include %s." % animation_name
			)
			_expect(
				animated_sprite.sprite_frames.get_frame_count(animation_name) == 4,
				"Elite knight %s animation must have 4 frames." % animation_name
			)
	_expect(animated_sprite.animation == &"move", "Elite knight editor animation must be move.")
	_expect(animated_sprite.frame == 0, "Elite knight editor frame must be 0.")
	_expect(elite_instance.sprite_faces_left_by_default, "Elite knight sprite sheet faces left by default and must declare that.")
	_expect(animated_sprite.flip_h, "Elite knight editor preview must face right by flipping its left-facing sheet.")

	_expect(
		_collision_shape_nodes_match(_collect_direct_collision_shapes(elite_instance), _collect_direct_collision_shapes(knight_instance)),
		"Elite knight body collision must match knight collision."
	)
	_expect(
		_collision_shape_nodes_match(
			_collect_direct_collision_shapes(elite_instance.get_node("TouchDamageArea")),
			_collect_direct_collision_shapes(knight_instance.get_node("TouchDamageArea"))
		),
		"Elite knight touch collision must match knight collision."
	)

	elite_instance.free()
	knight_instance.free()


func _test_knight_runtime_facing() -> void:
	var knight_instance := KNIGHT_SCENE.instantiate() as CapooKnight
	_expect(knight_instance != null, "Knight runtime facing test must instantiate CapooKnight.")
	if knight_instance == null:
		return

	test_root.add_child(knight_instance)
	await process_frame
	var animated_sprite := knight_instance.get_node("AnimatedSprite2D") as AnimatedSprite2D
	var body_shapes := _collect_direct_collision_shapes(knight_instance)
	_expect(knight_instance.sprite_faces_left_by_default, "Knight sprite sheet faces left by default and must declare that.")
	knight_instance.call("_set_facing_left", false)
	_expect(animated_sprite.flip_h, "Knight must face right when moving right.")
	var right_body_shape_x := body_shapes[1].position.x if body_shapes.size() > 1 else 0.0
	knight_instance.call("_set_facing_left", true)
	_expect(not animated_sprite.flip_h, "Knight must face left when moving left.")
	if body_shapes.size() > 1:
		_expect(is_equal_approx(body_shapes[1].position.x, -right_body_shape_x), "Knight off-center collision shape must mirror with facing.")
	knight_instance.queue_free()
	await process_frame


func _test_elite_runtime_facing() -> void:
	var elite_instance := ELITE_KNIGHT_SCENE.instantiate() as CapooKnight
	_expect(elite_instance != null, "Elite knight runtime facing test must instantiate CapooKnight.")
	if elite_instance == null:
		return

	test_root.add_child(elite_instance)
	await process_frame
	var animated_sprite := elite_instance.get_node("AnimatedSprite2D") as AnimatedSprite2D
	_expect(elite_instance.sprite_faces_left_by_default, "Elite knight sprite sheet faces left by default and must declare that.")
	elite_instance.call("_set_facing_left", false)
	_expect(animated_sprite.flip_h, "Elite knight must face right when moving right.")
	elite_instance.call("_set_facing_left", true)
	_expect(not animated_sprite.flip_h, "Elite knight must face left when moving left.")
	elite_instance.queue_free()
	await process_frame


func _test_slash_geometry() -> void:
	await _expect_slash_result(Vector2(42.0, 0.0), true, "Knight slash did not hit a target in front.")
	await _expect_slash_result(Vector2(5.0, 0.0), false, "Knight slash hit inside its inner dead zone.")
	await _expect_slash_result(Vector2(52.0, 0.0), false, "Knight slash hit outside its outer radius.")
	await _expect_slash_result(Vector2(36.0, 36.0), false, "Knight slash hit outside its 60-degree arc.")
	await _expect_slash_result(Vector2(-32.0, 0.0), false, "Knight slash hit behind itself.")


func _test_windup_delays_damage() -> void:
	var player := _spawn_player(Vector2(42.0, 0.0))
	var enemy := _spawn_knight(Vector2.ZERO, player)
	await _wait_physics_frames(3)
	_expect(enemy.combat_state == CapooKnight.CombatState.WINDUP, "Knight did not enter windup at melee range.")
	await _wait_physics_frames(10)
	_expect(player.current_health == 100, "Knight dealt damage during early windup.")
	var guard_frames := 0
	while enemy.combat_state == CapooKnight.CombatState.WINDUP:
		await physics_frame
		guard_frames += 1
		if guard_frames > 90:
			_expect(false, "Knight windup did not finish in time.")
			break
	guard_frames = 0
	while enemy.combat_state == CapooKnight.CombatState.SLASH and player.current_health == 100:
		await physics_frame
		guard_frames += 1
		if guard_frames > 90:
			_expect(false, "Knight slash damage did not resolve in time.")
			break
	_expect(player.current_health == 72, "Knight did not deal delayed slash damage.")
	enemy.queue_free()
	player.queue_free()
	await physics_frame


func _test_death_interrupts_attack() -> void:
	var player := _spawn_player(Vector2(42.0, 0.0))
	var enemy := _spawn_knight(Vector2.ZERO, player)
	await _wait_physics_frames(3)
	_expect(enemy.combat_state == CapooKnight.CombatState.WINDUP, "Death test knight did not enter windup.")
	enemy.apply_damage(KNIGHT_CONFIG.max_health + KNIGHT_CONFIG.physical_defense)
	await _wait_physics_frames(45)
	_expect(player.current_health == 100, "Dead knight dealt slash damage after attack interruption.")
	if is_instance_valid(enemy):
		enemy.queue_free()
	player.queue_free()
	await physics_frame


func _test_proxy_action_visuals() -> void:
	var player := _spawn_player(Vector2(120.0, 0.0))
	var enemy := _spawn_knight(Vector2.ZERO, player)
	enemy.configure_multiplayer_proxy()
	enemy.play_multiplayer_enemy_action(&"windup", Vector2.RIGHT, 1)
	await process_frame
	_expect(enemy.windup_warning.visible, "Proxy windup warning did not appear.")
	enemy.play_multiplayer_enemy_action(&"slash", Vector2.RIGHT, 2)
	await process_frame
	var slash_effect_count := _count_slash_effects()
	_expect(slash_effect_count > 0, "Proxy slash effect did not spawn.")
	await process_frame
	_expect(not enemy.windup_warning.visible, "Stale proxy windup tween must not re-show warning after slash.")
	enemy.queue_free()

	var death_enemy := _spawn_knight(Vector2.ZERO, player)
	death_enemy.configure_multiplayer_proxy()
	death_enemy.play_multiplayer_enemy_action(&"windup", Vector2.RIGHT, 1)
	await process_frame
	_expect(death_enemy.windup_warning.visible, "Proxy death test windup warning did not appear.")
	death_enemy.play_multiplayer_death_sequence()
	await process_frame
	_expect(not death_enemy.windup_warning.visible, "Proxy knight death must clear windup warning.")
	death_enemy.play_multiplayer_enemy_action(&"slash", Vector2.RIGHT, 2)
	await process_frame
	_expect(_count_slash_effects() == slash_effect_count, "Dead proxy knight must not spawn slash effects.")
	death_enemy.queue_free()
	player.queue_free()
	await physics_frame


func _test_swordsman_uses_path_when_corner_blocks_direct_chase() -> void:
	var player := _spawn_player(Vector2(18.0, 0.0))
	var wall := _spawn_wall(Vector2(9.0, 0.0), Vector2(8.0, 64.0))
	await physics_frame
	var pathfinder := FakePathfinder.new()
	pathfinder.path = PackedVector2Array([
		Vector2(0.0, -32.0),
		Vector2(18.0, -32.0),
		player.global_position,
	])
	test_root.add_child(pathfinder)
	var enemy := SWORDSMAN_SCENE.instantiate() as CapooKnight
	_expect(enemy != null, "Swordsman scene must instantiate CapooKnight.")
	if enemy == null:
		player.queue_free()
		wall.queue_free()
		pathfinder.queue_free()
		await physics_frame
		return
	test_root.add_child(enemy)
	enemy.global_position = Vector2.ZERO
	enemy.setup(SWORDSMAN_CONFIG, player, pathfinder)
	enemy.attack_cooldown_left = 10.0
	await _wait_physics_frames(8)

	_expect(pathfinder.requested_path, "Swordsman must use pathfinding when a wall blocks close direct chase.")
	_expect(enemy.global_position.y < -0.5, "Swordsman did not follow the path away from the blocked corner.")

	enemy.queue_free()
	wall.queue_free()
	pathfinder.queue_free()
	player.queue_free()
	await physics_frame


func _test_path_waypoint_motion_does_not_cut_corners() -> void:
	var player := _spawn_player(Vector2(128.0, 128.0))
	var wall := _spawn_wall(Vector2(16.0, 0.0), Vector2(8.0, 64.0))
	await physics_frame
	var pathfinder := FakePathfinder.new()
	test_root.add_child(pathfinder)
	var enemy := _spawn_knight(Vector2.ZERO, player)
	enemy.pathfinder = pathfinder
	enemy.current_path = PackedVector2Array([Vector2(32.0, 32.0)])
	enemy.current_path_index = 0
	enemy.path_refresh_time_left = 10.0

	var move_direction := enemy.call("_get_navigation_move_direction", 0.016) as Vector2
	_expect(is_zero_approx(move_direction.x) or is_zero_approx(move_direction.y), "Knight path following must not move diagonally into obstacle corners.")
	_expect(move_direction != Vector2.ZERO, "Knight path following must keep moving toward a diagonal waypoint.")
	_expect(is_zero_approx(move_direction.x) and move_direction.y > 0.0, "Knight path following must try the open axis when the primary axis is blocked.")

	enemy.queue_free()
	wall.queue_free()
	pathfinder.queue_free()
	player.queue_free()
	await physics_frame


func _test_navigation_budget_retry_keeps_existing_path() -> void:
	var player := _spawn_player(Vector2(96.0, 0.0))
	var pathfinder := FakePathfinder.new()
	pathfinder.path = PackedVector2Array([Vector2(16.0, 0.0), Vector2(32.0, 0.0)])
	test_root.add_child(pathfinder)
	var enemy := _spawn_knight(Vector2.ZERO, player)
	enemy.pathfinder = pathfinder
	enemy.current_path = PackedVector2Array([Vector2(8.0, 0.0)])
	enemy.current_path_index = 0

	pathfinder.budget_available = false
	enemy.call("_refresh_navigation_path")
	_expect(enemy.current_path.size() == 1 and enemy.current_path[0] == Vector2(8.0, 0.0), "Knight must keep its current path when path budget is exhausted.")
	_expect(enemy.path_refresh_time_left >= 0.03 and enemy.path_refresh_time_left <= 0.08, "Knight retry delay must be short when path budget is exhausted.")

	pathfinder.budget_available = true
	enemy.call("_refresh_navigation_path")
	_expect(enemy.current_path.size() == 2 and enemy.current_path[0] == Vector2(16.0, 0.0), "Knight must update its path when path budget is available.")
	_expect(enemy.path_refresh_time_left >= 0.1875 and enemy.path_refresh_time_left <= 0.3125, "Knight successful refresh delay must be jittered around the configured interval.")

	enemy.queue_free()
	pathfinder.queue_free()
	player.queue_free()
	await physics_frame


func _expect_slash_result(player_position: Vector2, should_hit: bool, message: String) -> void:
	var player := _spawn_player(player_position)
	var enemy := _spawn_knight(Vector2.ZERO, player)
	enemy.touch_damage_area.monitoring = false
	enemy.touch_damage_area.monitorable = false
	await _wait_physics_frames(2)
	enemy.slash_direction = Vector2.RIGHT
	enemy.action_sequence = 1
	enemy.call("_apply_slash_damage")
	await physics_frame
	var was_hit := player.current_health == 72
	_expect(was_hit == should_hit, message)
	enemy.queue_free()
	player.queue_free()
	await physics_frame


func _spawn_player(position: Vector2) -> Player:
	var player := PLAYER_SCENE.instantiate() as Player
	player.global_position = position
	test_root.add_child(player)
	player.invincibility_duration = 0.0
	player.invincibility_time_left = 0.0
	player.set("_base_max_health", 100)
	player.max_health = 100
	player.current_health = 100
	player.health_bar.setup(player.max_health, player.current_health)
	return player


func _spawn_knight(position: Vector2, player: Player) -> CapooKnight:
	var enemy := KNIGHT_SCENE.instantiate() as CapooKnight
	test_root.add_child(enemy)
	enemy.global_position = position
	enemy.setup(KNIGHT_CONFIG, player)
	return enemy


func _spawn_wall(position: Vector2, size: Vector2) -> StaticBody2D:
	var wall := StaticBody2D.new()
	wall.collision_layer = 1
	wall.collision_mask = 0
	var shape_node := CollisionShape2D.new()
	var rectangle := RectangleShape2D.new()
	rectangle.size = size
	shape_node.shape = rectangle
	wall.add_child(shape_node)
	test_root.add_child(wall)
	wall.global_position = position
	return wall


func _count_wave_entries(wave_config: WaveConfig) -> int:
	return _count_wave_entries_for_config(wave_config, KNIGHT_CONFIG)


func _count_wave_entries_for_config(wave_config: WaveConfig, enemy_config: EnemyConfig) -> int:
	var total := 0
	for entry in wave_config.enemy_entries:
		if entry != null and entry.enemy_config == enemy_config:
			total += entry.count
	return total


func _count_total_wave_entries(wave_config: WaveConfig) -> int:
	var total := 0
	for entry in wave_config.enemy_entries:
		if entry != null:
			total += entry.count
	return total


func _count_slash_effects() -> int:
	var total := 0
	for child in test_root.get_children():
		if child is CapooKnightSlashEffect:
			total += 1
	return total


func _wait_physics_frames(frame_count: int) -> void:
	for _frame_index in range(frame_count):
		await physics_frame


func _collect_direct_collision_shapes(parent_node: Node) -> Array[CollisionShape2D]:
	var shapes: Array[CollisionShape2D] = []
	for child in parent_node.get_children():
		var shape_node := child as CollisionShape2D
		if shape_node != null:
			shapes.append(shape_node)
	return shapes


func _are_shapes_independent(
	body_shapes: Array[CollisionShape2D],
	touch_shapes: Array[CollisionShape2D]
) -> bool:
	for body_shape in body_shapes:
		for touch_shape in touch_shapes:
			if body_shape.shape == touch_shape.shape:
				return false
	return true


func _collision_shape_nodes_match(actual_shapes: Array[CollisionShape2D], expected_shapes: Array[CollisionShape2D]) -> bool:
	if actual_shapes.size() != expected_shapes.size():
		return false
	for index in range(expected_shapes.size()):
		if not _collision_shape_node_matches(actual_shapes[index], expected_shapes[index]):
			return false
	return true


func _collision_shape_node_matches(actual_shape_node: CollisionShape2D, expected_shape_node: CollisionShape2D) -> bool:
	if actual_shape_node == null or expected_shape_node == null:
		return false
	if not actual_shape_node.position.is_equal_approx(expected_shape_node.position):
		return false
	if not actual_shape_node.scale.is_equal_approx(expected_shape_node.scale):
		return false
	if not is_equal_approx(actual_shape_node.rotation, expected_shape_node.rotation):
		return false
	var actual_shape := actual_shape_node.shape
	var expected_shape := expected_shape_node.shape
	if actual_shape == null or expected_shape == null:
		return actual_shape == expected_shape
	if actual_shape.get_class() != expected_shape.get_class():
		return false
	if actual_shape is RectangleShape2D and expected_shape is RectangleShape2D:
		return (actual_shape as RectangleShape2D).size.is_equal_approx((expected_shape as RectangleShape2D).size)
	return actual_shape.get_rect().is_equal_approx(expected_shape.get_rect())


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)


func _resource_path(resource: Resource) -> String:
	return resource.resource_path if resource != null else ""
