extends SceneTree

const ENEMY_CONFIGS: Array[EnemyConfig] = [
	preload("res://resources/config/enemies/yuanshi_insect_basic.tres"),
	preload("res://resources/config/enemies/yuanshi_insect_fast.tres"),
	preload("res://resources/config/enemies/yuanshi_insect_bomber.tres"),
	preload("res://resources/config/enemies/yuanshi_insect_shell.tres"),
	preload("res://resources/config/enemies/yuanshi_insect_purple_bomber.tres"),
	preload("res://resources/config/enemies/yuanshi_insect_green_shell.tres"),
	preload("res://resources/config/enemies/yuanshi_insect_guardian.tres"),
	preload("res://resources/config/enemies/yuanshi_insect_fire_ranged.tres"),
	preload("res://resources/config/enemies/capoo_ak47.tres"),
	preload("res://resources/config/enemies/capoo_knight.tres"),
	preload("res://resources/config/enemies/capoo_knight_elite.tres"),
	preload("res://resources/config/enemies/capoo_swordsman.tres"),
	preload("res://resources/config/enemies/capoo_rpg.tres"),
	preload("res://resources/config/enemies/capoo_mage.tres"),
	preload("res://resources/config/enemies/capoo_sniper.tres"),
	preload("res://resources/config/enemies/capoo_smg.tres"),
]
const ENEMY_VISUAL_SHADER_PATH := "res://scene/entity_motion_status.gdshader"

var failures: Array[String] = []
var test_root: Node2D


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	test_root = Node2D.new()
	test_root.name = "EnemySceneContractSmokeTest"
	root.add_child(test_root)
	current_scene = test_root

	for enemy_config in ENEMY_CONFIGS:
		await _test_enemy_scene_contract(enemy_config)

	current_scene = null
	test_root.queue_free()
	await process_frame
	await physics_frame
	for _cleanup_frame in range(4):
		await process_frame

	if failures.is_empty():
		print("ENEMY_SCENE_CONTRACT_SMOKE_TEST_OK")
		quit()
		return

	for failure in failures:
		push_error(failure)
	quit(1)


func _test_enemy_scene_contract(enemy_config: EnemyConfig) -> void:
	_expect(enemy_config != null, "Enemy config must not be null.")
	if enemy_config == null:
		return
	_expect(enemy_config.enemy_scene != null, "%s must provide enemy_scene." % enemy_config.resource_path)
	if enemy_config.enemy_scene == null:
		return

	var enemy := enemy_config.enemy_scene.instantiate() as Enemy
	_expect(enemy != null, "%s scene must instantiate Enemy." % enemy_config.resource_path)
	if enemy == null:
		return

	var animated_sprite := enemy.get_node_or_null("AnimatedSprite2D") as AnimatedSprite2D
	var touch_damage_area := enemy.get_node_or_null("TouchDamageArea") as Area2D
	var legacy_hit_particles := enemy.get_node_or_null("HitParticles") as GPUParticles2D
	var body_shape_nodes := _collect_direct_collision_shapes(enemy)
	var touch_shape_nodes := _collect_direct_collision_shapes(touch_damage_area)
	_expect(animated_sprite != null, "%s scene must include AnimatedSprite2D." % enemy_config.resource_path)
	_expect(touch_damage_area != null, "%s scene must include TouchDamageArea." % enemy_config.resource_path)
	_expect(
		legacy_hit_particles == null,
		"%s must use the shared hit-effect pool instead of a resident emitter."
		% enemy_config.resource_path
	)
	_expect(not body_shape_nodes.is_empty(), "%s scene must include body CollisionShape2D nodes." % enemy_config.resource_path)
	_expect(not touch_shape_nodes.is_empty(), "%s scene must include touch CollisionShape2D nodes." % enemy_config.resource_path)
	if animated_sprite == null or touch_damage_area == null or body_shape_nodes.is_empty() or touch_shape_nodes.is_empty():
		enemy.free()
		return

	var scene_frames := animated_sprite.sprite_frames
	var sprite_material := animated_sprite.material as ShaderMaterial
	var body_shapes := _get_shape_resources(body_shape_nodes)
	var touch_shapes := _get_shape_resources(touch_shape_nodes)
	_expect(enemy.material == null, "%s root node must not hold the enemy visual material." % enemy_config.resource_path)
	_expect(not animated_sprite.use_parent_material, "%s sprite must not inherit a root material." % enemy_config.resource_path)
	_expect(sprite_material != null, "%s sprite must own a ShaderMaterial." % enemy_config.resource_path)
	_expect(
		sprite_material != null and sprite_material.shader.resource_path == ENEMY_VISUAL_SHADER_PATH,
		"%s sprite must use the enemy visual shader." % enemy_config.resource_path
	)
	_expect(
		sprite_material != null and not sprite_material.resource_local_to_scene,
		"%s enemy visual material must be shared for 2D batching." % enemy_config.resource_path
	)
	_expect(scene_frames != null, "%s scene must own SpriteFrames." % enemy_config.resource_path)
	if scene_frames != null:
		_expect(scene_frames.has_animation(enemy_config.move_animation_name), "%s scene must include move animation." % enemy_config.resource_path)
	_expect(animated_sprite.animation == enemy_config.move_animation_name, "%s editor animation must be move." % enemy_config.resource_path)
	_expect(animated_sprite.frame == 0, "%s editor frame must be 0." % enemy_config.resource_path)
	_expect(body_shapes.size() == body_shape_nodes.size(), "%s all body shapes must be configured in scene." % enemy_config.resource_path)
	_expect(touch_shapes.size() == touch_shape_nodes.size(), "%s all touch shapes must be configured in scene." % enemy_config.resource_path)
	_expect(
		_are_body_and_touch_shapes_independent(body_shapes, touch_shapes),
		"%s body and touch shapes must be independently editable." % enemy_config.resource_path
	)

	test_root.add_child(enemy)
	enemy.setup(enemy_config, null, null)
	await process_frame
	var effects_before := _collect_active_hit_effects().size()
	enemy.call("_play_hit_particles", Vector2.RIGHT)
	var active_effects := _collect_active_hit_effects()
	_expect(
		active_effects.size() == effects_before + 1
		and active_effects.back().emitting,
		"%s hit feedback must use a transient shared effect."
		% enemy_config.resource_path
	)
	if not active_effects.is_empty():
		active_effects.back().call("_on_finished")
	await process_frame

	_expect(animated_sprite.sprite_frames == scene_frames, "%s setup must not replace scene SpriteFrames." % enemy_config.resource_path)
	_expect(enemy.body_collision_shapes.size() == body_shape_nodes.size(), "%s runtime must cache all body collision shapes." % enemy_config.resource_path)
	_expect(enemy.touch_damage_shapes.size() == touch_shape_nodes.size(), "%s runtime must cache all touch collision shapes." % enemy_config.resource_path)
	_expect(_shape_nodes_match_resources(body_shape_nodes, body_shapes), "%s setup must not replace body shapes." % enemy_config.resource_path)
	_expect(_shape_nodes_match_resources(touch_shape_nodes, touch_shapes), "%s setup must not replace touch shapes." % enemy_config.resource_path)
	_test_collision_shapes_mirror_with_facing(enemy_config, enemy, animated_sprite, body_shape_nodes, touch_shape_nodes)

	enemy.queue_free()
	await process_frame


func _collect_active_hit_effects() -> Array[BulletHitEffect]:
	var effects: Array[BulletHitEffect] = []
	for child in test_root.get_children():
		var effect := child as BulletHitEffect
		if effect != null and effect.pool_active:
			effects.append(effect)
	return effects


func _collect_direct_collision_shapes(parent_node: Node) -> Array[CollisionShape2D]:
	var shapes: Array[CollisionShape2D] = []
	if parent_node == null:
		return shapes
	for child in parent_node.get_children():
		var shape_node := child as CollisionShape2D
		if shape_node != null:
			shapes.append(shape_node)
	return shapes


func _get_shape_resources(shape_nodes: Array[CollisionShape2D]) -> Array[Shape2D]:
	var shapes: Array[Shape2D] = []
	for shape_node in shape_nodes:
		if shape_node.shape != null:
			shapes.append(shape_node.shape)
	return shapes


func _are_body_and_touch_shapes_independent(
	body_shapes: Array[Shape2D],
	touch_shapes: Array[Shape2D]
) -> bool:
	for body_shape in body_shapes:
		for touch_shape in touch_shapes:
			if body_shape == touch_shape:
				return false
	return true


func _shape_nodes_match_resources(
	shape_nodes: Array[CollisionShape2D],
	expected_shapes: Array[Shape2D]
) -> bool:
	if shape_nodes.size() != expected_shapes.size():
		return false
	for index in range(shape_nodes.size()):
		if shape_nodes[index].shape != expected_shapes[index]:
			return false
	return true


func _test_collision_shapes_mirror_with_facing(
	enemy_config: EnemyConfig,
	enemy: Enemy,
	animated_sprite: AnimatedSprite2D,
	body_shape_nodes: Array[CollisionShape2D],
	touch_shape_nodes: Array[CollisionShape2D]
) -> void:
	var all_shape_nodes: Array[CollisionShape2D] = []
	all_shape_nodes.append_array(body_shape_nodes)
	all_shape_nodes.append_array(touch_shape_nodes)
	var right_bounds: Array[Rect2] = []
	for shape_node in all_shape_nodes:
		right_bounds.append(_get_collision_shape_local_bounds(shape_node))

	enemy.call("_set_facing_left", true)
	_expect(
		animated_sprite.flip_h == (not enemy.sprite_faces_left_by_default),
		"%s facing left must use the configured sprite default direction." % enemy_config.resource_path
	)
	for index in range(all_shape_nodes.size()):
		var left_bound := _get_collision_shape_local_bounds(all_shape_nodes[index])
		_expect(
			_are_bounds_mirrored_on_x(right_bounds[index], left_bound),
			"%s collision shape %d must mirror when facing left." % [enemy_config.resource_path, index]
		)

	enemy.call("_set_facing_left", false)
	_expect(
		animated_sprite.flip_h == enemy.sprite_faces_left_by_default,
		"%s facing right must use the configured sprite default direction." % enemy_config.resource_path
	)
	for index in range(all_shape_nodes.size()):
		var restored_bound := _get_collision_shape_local_bounds(all_shape_nodes[index])
		_expect(
			_are_bounds_equal(right_bounds[index], restored_bound),
			"%s collision shape %d must restore when facing right." % [enemy_config.resource_path, index]
		)


func _get_collision_shape_local_bounds(shape_node: CollisionShape2D) -> Rect2:
	if shape_node == null or shape_node.shape == null:
		return Rect2()

	var shape_rect: Rect2 = shape_node.shape.get_rect()
	var corners: Array[Vector2] = [
		shape_rect.position,
		shape_rect.position + Vector2(shape_rect.size.x, 0.0),
		shape_rect.position + Vector2(0.0, shape_rect.size.y),
		shape_rect.position + shape_rect.size,
	]
	var minimum: Vector2 = Vector2(INF, INF)
	var maximum: Vector2 = Vector2(-INF, -INF)
	for corner in corners:
		var transformed_corner: Vector2 = shape_node.transform * corner
		minimum.x = minf(minimum.x, transformed_corner.x)
		minimum.y = minf(minimum.y, transformed_corner.y)
		maximum.x = maxf(maximum.x, transformed_corner.x)
		maximum.y = maxf(maximum.y, transformed_corner.y)
	return Rect2(minimum, maximum - minimum)


func _are_bounds_mirrored_on_x(right_bound: Rect2, left_bound: Rect2) -> bool:
	var right_min_x := right_bound.position.x
	var right_max_x := right_bound.position.x + right_bound.size.x
	var left_min_x := left_bound.position.x
	var left_max_x := left_bound.position.x + left_bound.size.x
	return (
		is_equal_approx(left_min_x, -right_max_x)
		and is_equal_approx(left_max_x, -right_min_x)
		and is_equal_approx(left_bound.position.y, right_bound.position.y)
		and is_equal_approx(left_bound.size.y, right_bound.size.y)
	)


func _are_bounds_equal(expected_bound: Rect2, actual_bound: Rect2) -> bool:
	return (
		is_equal_approx(actual_bound.position.x, expected_bound.position.x)
		and is_equal_approx(actual_bound.position.y, expected_bound.position.y)
		and is_equal_approx(actual_bound.size.x, expected_bound.size.x)
		and is_equal_approx(actual_bound.size.y, expected_bound.size.y)
	)


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
