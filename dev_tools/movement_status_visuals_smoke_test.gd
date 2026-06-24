extends SceneTree

const PLAYER_SCENE := preload("res://scene/player.tscn")
const BASIC_CONFIG := preload("res://resources/config/enemies/yuanshi_insect_basic.tres")
const SPEED_PICKUP := preload("res://resources/config/pickups/pickup_speed.tres")
const TENPURA_PICKUP := preload("res://resources/config/pickups/pickup_tenpura.tres")
const MOTION_STATUS_SHADER_PATH := "res://scene/entity_motion_status.gdshader"
const SLOW_OVERLAY_PARAMETER := &"slow_overlay_strength"
const BLINK_PARAMETER := &"blink_enabled"

var failures: Array[String] = []
var test_root: Node2D


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	test_root = Node2D.new()
	test_root.name = "MovementStatusVisualsSmokeTest"
	root.add_child(test_root)
	current_scene = test_root

	await _test_player_movement_status_visuals()
	await _test_enemy_movement_status_visuals()

	test_root.queue_free()
	for _cleanup_frame in range(4):
		await process_frame
		await physics_frame

	if failures.is_empty():
		print("MOVEMENT_STATUS_VISUALS_SMOKE_TEST_OK")
		quit()
		return

	for failure in failures:
		push_error(failure)
	quit(1)


func _test_player_movement_status_visuals() -> void:
	var player := PLAYER_SCENE.instantiate() as Player
	test_root.add_child(player)
	await process_frame

	var sprite := player.get_node("BodySprite") as AnimatedSprite2D
	var sprite_material := sprite.material as ShaderMaterial
	var speed_trail := player.get_node("MoveSpeedTrailEffect") as Node2D
	_expect(sprite_material != null, "Player body sprite must use a ShaderMaterial.")
	_expect(
		sprite_material != null and sprite_material.shader.resource_path == MOTION_STATUS_SHADER_PATH,
		"Player body sprite must use the motion status shader."
	)
	_expect(speed_trail != null, "Player must include a speed trail effect node.")

	player.apply_pickup(SPEED_PICKUP)
	player.velocity = Vector2.RIGHT * 120.0
	player.call("_update_movement_status_visuals", Vector2.RIGHT)
	_expect(speed_trail.visible, "Player temporary speed boost must show speed trail lines.")
	_expect(
		is_equal_approx(float(sprite_material.get_shader_parameter(SLOW_OVERLAY_PARAMETER)), 0.0),
		"Player speed boost must not apply the slow overlay."
	)

	player.apply_pickup(TENPURA_PICKUP)
	player.velocity = Vector2.RIGHT * 24.0
	player.call("_update_movement_status_visuals", Vector2.RIGHT)
	_expect(not speed_trail.visible, "Player speed down must hide speed trail lines.")
	_expect(
		float(sprite_material.get_shader_parameter(SLOW_OVERLAY_PARAMETER)) > 0.0,
		"Player speed down must apply the slow overlay."
	)

	player.queue_free()
	await process_frame


func _test_enemy_movement_status_visuals() -> void:
	var player := PLAYER_SCENE.instantiate() as Player
	test_root.add_child(player)
	var enemy := BASIC_CONFIG.enemy_scene.instantiate() as Enemy
	test_root.add_child(enemy)
	enemy.setup(BASIC_CONFIG, player, null)
	await process_frame

	var sprite := enemy.get_node("AnimatedSprite2D") as AnimatedSprite2D
	var visual_material := sprite.material as ShaderMaterial
	var speed_trail := enemy.get_node("MoveSpeedTrailEffect") as Node2D
	_expect(enemy.material == null, "Enemy root must not hold the visual material.")
	_expect(not sprite.use_parent_material, "Enemy sprite must not inherit a root material.")
	_expect(visual_material != null, "Enemy sprite must use a ShaderMaterial.")
	_expect(
		visual_material != null and visual_material.shader.resource_path == MOTION_STATUS_SHADER_PATH,
		"Enemy sprite must use the motion status shader."
	)
	_expect(speed_trail != null, "Enemy must include a speed trail effect node.")

	enemy.velocity = Vector2.LEFT * 60.0
	enemy.add_move_speed_modifier(101, 0.5)
	enemy.call("_update_movement_status_visuals")
	_expect(
		float(visual_material.get_shader_parameter(SLOW_OVERLAY_PARAMETER)) > 0.0,
		"Enemy speed down modifier must apply the slow overlay."
	)
	_expect(not speed_trail.visible, "Enemy speed down modifier must not show speed trail lines.")

	enemy.remove_move_speed_modifier(101)
	enemy.add_move_speed_modifier(102, 1.35)
	enemy.call("_update_movement_status_visuals")
	_expect(
		is_equal_approx(float(visual_material.get_shader_parameter(SLOW_OVERLAY_PARAMETER)), 0.0),
		"Enemy speed boost modifier must clear the slow overlay."
	)
	_expect(speed_trail.visible, "Enemy speed boost modifier must show speed trail lines while moving.")
	var health_before_hit := enemy.current_health
	enemy.apply_damage(1, Vector2.RIGHT)
	_expect(enemy.current_health == health_before_hit - 1, "Enemy hit sanity check must apply damage.")
	_expect(
		not bool(visual_material.get_shader_parameter(BLINK_PARAMETER)),
		"Enemy hit feedback must not enable hurt blink."
	)

	enemy.queue_free()
	player.queue_free()
	await process_frame


func _expect(condition: bool, message: String) -> void:
	if condition:
		return
	failures.append(message)
