extends SceneTree

const LINGLAN_FRAMES := preload("res://resources/animation/linglan.tres")
const LINGLAN_SCENE := preload("res://scene/linglan_boss.tscn")

var failures: Array[String] = []
var test_root: Node2D


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	test_root = Node2D.new()
	test_root.name = "LinglanBossSmokeTest"
	root.add_child(test_root)
	current_scene = test_root

	_test_animation_resource()
	await _test_scene_structure()

	test_root.queue_free()
	for _cleanup_frame in range(4):
		await process_frame
		await physics_frame

	if failures.is_empty():
		print("LINGLAN_BOSS_SMOKE_TEST_OK")
		quit()
		return

	for failure in failures:
		push_error(failure)
	quit(1)


func _test_animation_resource() -> void:
	var expected_counts := {
		&"idle": 4,
		&"idle_up": 1,
		&"idle_down": 1,
		&"idle_left": 1,
		&"idle_right": 1,
		&"move_up": 4,
		&"move_down": 4,
		&"move_left": 4,
		&"move_right": 4,
		&"die": 4,
	}
	for animation_name in expected_counts.keys():
		_expect(
			LINGLAN_FRAMES.has_animation(animation_name),
			"Linglan animation %s must exist." % animation_name
		)
		if not LINGLAN_FRAMES.has_animation(animation_name):
			continue
		_expect(
			LINGLAN_FRAMES.get_frame_count(animation_name) == expected_counts[animation_name],
			"Linglan animation %s has an unexpected frame count." % animation_name
		)
		var first_texture := LINGLAN_FRAMES.get_frame_texture(animation_name, 0)
		_expect(first_texture != null, "Linglan animation %s must have a texture." % animation_name)
		if first_texture != null:
			var frame_size := first_texture.get_size()
			_expect(frame_size.x >= 250.0 and frame_size.y >= 180.0, "Linglan boss frames must keep high-resolution pixel art detail.")
	_expect(not LINGLAN_FRAMES.get_animation_loop(&"die"), "Linglan die animation must not loop.")


func _test_scene_structure() -> void:
	var linglan := LINGLAN_SCENE.instantiate() as LinglanBoss
	_expect(linglan != null, "Linglan scene must instantiate as LinglanBoss.")
	if linglan == null:
		return
	test_root.add_child(linglan)
	await process_frame
	await physics_frame

	var sprite := linglan.get_node_or_null("AnimatedSprite2D") as AnimatedSprite2D
	_expect(sprite != null, "Linglan scene must include AnimatedSprite2D.")
	if sprite != null:
		_expect(sprite.sprite_frames == LINGLAN_FRAMES, "Linglan sprite must use linglan.tres.")
		_expect(sprite.animation == &"idle", "Linglan scene must default to idle.")

	var body_shape := linglan.get_node_or_null("StaticBody2D/CollisionShape2D") as CollisionShape2D
	var interaction_shape := linglan.get_node_or_null("InteractionArea/CollisionShape2D") as CollisionShape2D
	_expect(body_shape != null and body_shape.shape is CapsuleShape2D, "Linglan must have a capsule body collision.")
	_expect(
		interaction_shape != null and interaction_shape.shape is CircleShape2D,
		"Linglan must have a circular interaction area."
	)
	if body_shape != null and body_shape.shape is CapsuleShape2D:
		_expect((body_shape.shape as CapsuleShape2D).radius >= 24.0, "Linglan boss body collision must not keep the small NPC radius.")
	if interaction_shape != null and interaction_shape.shape is CircleShape2D:
		_expect((interaction_shape.shape as CircleShape2D).radius >= 80.0, "Linglan boss interaction area must match the larger boss sprite.")

	linglan.queue_free()
	await process_frame


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
