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
	preload("res://resources/config/enemies/capoo_swordsman.tres"),
	preload("res://resources/config/enemies/capoo_rpg.tres"),
]

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
	var body_shape_node := enemy.get_node_or_null("CollisionShape2D") as CollisionShape2D
	var touch_shape_node := enemy.get_node_or_null("TouchDamageArea/CollisionShape2D") as CollisionShape2D
	_expect(animated_sprite != null, "%s scene must include AnimatedSprite2D." % enemy_config.resource_path)
	_expect(body_shape_node != null, "%s scene must include body CollisionShape2D." % enemy_config.resource_path)
	_expect(touch_shape_node != null, "%s scene must include touch CollisionShape2D." % enemy_config.resource_path)
	if animated_sprite == null or body_shape_node == null or touch_shape_node == null:
		enemy.free()
		return

	var scene_frames := animated_sprite.sprite_frames
	var body_shape := body_shape_node.shape
	var touch_shape := touch_shape_node.shape
	_expect(scene_frames != null, "%s scene must own SpriteFrames." % enemy_config.resource_path)
	if scene_frames != null:
		_expect(scene_frames.has_animation(enemy_config.move_animation_name), "%s scene must include move animation." % enemy_config.resource_path)
	_expect(animated_sprite.animation == enemy_config.move_animation_name, "%s editor animation must be move." % enemy_config.resource_path)
	_expect(animated_sprite.frame == 0, "%s editor frame must be 0." % enemy_config.resource_path)
	_expect(body_shape != null, "%s body shape must be configured in scene." % enemy_config.resource_path)
	_expect(touch_shape != null, "%s touch shape must be configured in scene." % enemy_config.resource_path)
	_expect(body_shape != touch_shape, "%s body and touch shapes must be independently editable." % enemy_config.resource_path)

	test_root.add_child(enemy)
	enemy.setup(enemy_config, null, null)
	await process_frame

	_expect(animated_sprite.sprite_frames == scene_frames, "%s setup must not replace scene SpriteFrames." % enemy_config.resource_path)
	_expect(body_shape_node.shape == body_shape, "%s setup must not replace body shape." % enemy_config.resource_path)
	_expect(touch_shape_node.shape == touch_shape, "%s setup must not replace touch shape." % enemy_config.resource_path)

	enemy.queue_free()
	await process_frame


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
