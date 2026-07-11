extends SceneTree

const WEISHIDAIER_SCENE := preload("res://scene/player/weishidaier/player_weishidaier.tscn")
const HOE_CAT_SCENE := preload("res://scene/player/hoe_cat/player_hoe_cat.tscn")
const DASH_READY_SHADER_PATH := "res://scene/player/effects/dash_ready_glow.gdshader"
const MOTION_STATUS_SHADER_PATH := "res://scene/entity_motion_status.gdshader"
const MULTIPLAYER_GAME_SCRIPT_PATH := "res://scene/multiplayer/mp_game.gd"
const READY_STRENGTH_PARAMETER := &"ready_strength"
const DASH_STRENGTH_PARAMETER := &"dash_effect_strength"


class DashOverridePlayer:
	extends Player

	func _get_character_dash_distance() -> float:
		return 48.0

	func _get_character_dash_cooldown() -> float:
		return 1.75


var failures: Array[String] = []
var test_root: Node2D


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	test_root = Node2D.new()
	test_root.name = "PlayerDashSmokeTest"
	root.add_child(test_root)
	current_scene = test_root

	_expect(InputMap.has_action(&"dash"), "Project input map must define the dash action.")
	_test_shader_contracts()
	_test_character_dash_override_contract()
	await _test_player_scene(WEISHIDAIER_SCENE, "Weishidaier")
	await _test_player_scene(HOE_CAT_SCENE, "Hoe Cat")
	await _test_dash_wall_collision()
	await _test_dash_preserves_existing_invincibility()
	await _test_multiplayer_dash_protection()

	test_root.queue_free()
	for _cleanup_frame in range(4):
		await process_frame
		await physics_frame

	if failures.is_empty():
		print("PLAYER_DASH_SMOKE_TEST_OK")
		quit()
		return

	for failure in failures:
		push_error(failure)
	quit(1)


func _test_shader_contracts() -> void:
	var motion_shader_file := FileAccess.open(MOTION_STATUS_SHADER_PATH, FileAccess.READ)
	_expect(motion_shader_file != null, "Dash body shader must be readable.")
	if motion_shader_file != null:
		var motion_shader_source := motion_shader_file.get_as_text()
		_expect(
			motion_shader_source.find("uniform float dash_effect_strength") >= 0,
			"Motion status shader must expose dash strength."
		)
		_expect(
			motion_shader_source.find("uniform vec2 dash_direction") >= 0,
			"Motion status shader must expose dash direction."
		)
		_expect(
			motion_shader_source.find("TEXTURE_PIXEL_SIZE * dash_trail_pixels") >= 0,
			"Dash body shader must use pixel-sized directional samples."
		)
		_expect(
			motion_shader_source.find("UV + trail_offset") >= 0
			and motion_shader_source.find("UV - trail_offset") < 0,
			"Dash body shader must place its sampled trail behind the movement direction."
		)

	var ready_shader_file := FileAccess.open(DASH_READY_SHADER_PATH, FileAccess.READ)
	_expect(ready_shader_file != null, "Dash ready glow shader must be readable.")
	if ready_shader_file != null:
		var ready_shader_source := ready_shader_file.get_as_text()
		_expect(
			ready_shader_source.find("render_mode unshaded, blend_add") >= 0,
			"Dash ready glow must use an additive unshaded CanvasItem shader."
		)
		_expect(
			ready_shader_source.find("uniform float ready_strength") >= 0,
			"Dash ready glow must expose ready strength."
		)

	var multiplayer_script_file := FileAccess.open(MULTIPLAYER_GAME_SCRIPT_PATH, FileAccess.READ)
	_expect(multiplayer_script_file != null, "Multiplayer game script must be readable.")
	if multiplayer_script_file != null:
		var multiplayer_source := multiplayer_script_file.get_as_text()
		_expect(
			multiplayer_source.find("const INPUT_BUTTON_DASH := 4") >= 0,
			"Multiplayer input packets must reserve a dash button bit."
		)
		_expect(
			multiplayer_source.find("DASH_INPUT_REDUNDANCY_PACKETS") >= 0
			and multiplayer_source.find("dash_request_sequence") >= 0,
			"Multiplayer dash requests must use a repeated, deduplicated sequence."
		)
		_expect(
			multiplayer_source.find("_try_accept_client_dash_request") >= 0,
			"Host must validate dash movement evidence before granting protection."
		)
		_expect(
			multiplayer_source.find("_last_dash_accepted_times") >= 0
			and multiplayer_source.find("minimum_dash_interval") >= 0
			and multiplayer_source.find("player_node.get_dash_cooldown()") >= 0,
			"Host must enforce dash cooldown independently of client request sequence."
		)


func _test_character_dash_override_contract() -> void:
	var player := DashOverridePlayer.new()
	_expect(
		is_equal_approx(player.get_dash_distance(), 48.0),
		"Player subclasses must be able to override dash distance through the character hook."
	)
	_expect(
		is_equal_approx(player.get_dash_cooldown(), 1.75),
		"Player subclasses must be able to override dash cooldown through the character hook."
	)
	player.free()


func _test_player_scene(player_scene: PackedScene, label: String) -> void:
	var player := player_scene.instantiate() as Player
	_expect(player != null, "%s scene must instantiate as Player." % label)
	if player == null:
		return
	test_root.add_child(player)
	var cooldown_timer := player.get_node_or_null("DashCooldownTimer") as Timer
	var ready_indicator := player.get_node_or_null("DashReadyIndicator") as Control
	var body_sprite := player.get_node_or_null("BodySprite") as AnimatedSprite2D
	var body_material: ShaderMaterial = null
	if body_sprite != null:
		body_material = body_sprite.material as ShaderMaterial
	var ready_material: ShaderMaterial = null
	if ready_indicator != null:
		ready_material = ready_indicator.material as ShaderMaterial

	_expect(
		is_equal_approx(player.get_dash_distance(), 35.0),
		"%s default dash distance must be 35 pixels." % label
	)
	_expect(
		is_equal_approx(player.get_dash_cooldown(), 5.0),
		"%s default dash cooldown must be 5 seconds." % label
	)
	_expect(cooldown_timer != null, "%s must author a DashCooldownTimer node." % label)
	_expect(
		cooldown_timer != null
		and cooldown_timer.one_shot
		and cooldown_timer.process_callback == Timer.TIMER_PROCESS_PHYSICS
		and is_equal_approx(cooldown_timer.wait_time, 5.0),
		"%s dash cooldown must be a five-second one-shot physics Timer." % label
	)
	_expect(ready_indicator != null, "%s must author a DashReadyIndicator node." % label)
	_expect(ready_indicator != null and ready_indicator.visible, "%s local ready glow must start visible." % label)
	_expect(
		ready_material != null and ready_material.shader.resource_path == DASH_READY_SHADER_PATH,
		"%s ready indicator must use the dash ready glow shader." % label
	)
	_expect(
		ready_material != null
		and is_zero_approx(float(ready_material.get_shader_parameter(READY_STRENGTH_PARAMETER))),
		"%s ready glow must begin its reveal at zero strength." % label
	)
	_expect(
		body_material != null and body_material.shader.resource_path == MOTION_STATUS_SHADER_PATH,
		"%s body must keep the shared motion status shader." % label
	)
	await create_timer(0.1, true, true).timeout
	var initial_mid_strength := float(
		ready_material.get_shader_parameter(READY_STRENGTH_PARAMETER)
	) if ready_material != null else -1.0
	_expect(
		initial_mid_strength > 0.0 and initial_mid_strength < 0.5,
		"%s ready glow must use a slow-start nonlinear reveal (halfway %.3f)."
		% [label, initial_mid_strength]
	)
	await create_timer(0.12, true, true).timeout
	_expect(
		ready_material != null
		and float(ready_material.get_shader_parameter(READY_STRENGTH_PARAMETER)) >= 0.99,
		"%s ready glow reveal must finish in 0.2 seconds." % label
	)

	player.dash_duration = 0.12
	player.dash_cooldown = 0.22

	var stood_still_dash := bool(player.call("_try_start_dash", Vector2.ZERO))
	_expect(not stood_still_dash, "%s must reject dash while standing still." % label)
	_expect(cooldown_timer != null and cooldown_timer.is_stopped(), "%s rejected dash must not consume cooldown." % label)

	var start_position := player.global_position
	var expected_dash_distance := player.get_dash_distance()
	var started := bool(player.call("_try_start_dash", Vector2.ONE))
	_expect(started, "%s must dash while movement input is non-zero." % label)
	_expect(player.is_dashing(), "%s must enter dash state immediately." % label)
	_expect(
		body_material != null and float(body_material.get_shader_parameter(DASH_STRENGTH_PARAMETER)) > 0.0,
		"%s dash must activate the body shader effect." % label
	)
	_expect(
		ready_material != null and is_zero_approx(float(ready_material.get_shader_parameter(READY_STRENGTH_PARAMETER))),
		"%s ready glow must switch off when dash starts." % label
	)
	var health_before_dash_hit := player.current_health
	_expect(
		not player.apply_damage(5),
		"%s must reject damage during dash." % label
	)
	_expect(player.current_health == health_before_dash_hit, "%s dash immunity must preserve health." % label)

	for _dash_frame in range(20):
		await physics_frame
		await process_frame
		if not player.is_dashing():
			break
	_expect(not player.is_dashing(), "%s dash must finish in a short bounded duration." % label)
	var displacement := player.global_position - start_position
	_expect(
		absf(displacement.length() - expected_dash_distance) <= 0.75,
		"%s unobstructed dash must travel about %.1f px (actual %.3f)."
		% [label, expected_dash_distance, displacement.length()]
	)
	_expect(
		absf(absf(displacement.x) - absf(displacement.y)) <= 0.5,
		"%s diagonal dash must normalize direction instead of gaining distance." % label
	)
	_expect(not player.is_dash_ready(), "%s dash must remain unavailable during cooldown." % label)
	_expect(
		not bool(player.call("_try_start_dash", Vector2.RIGHT)),
		"%s must reject a second dash during cooldown." % label
	)

	for _cooldown_frame in range(30):
		await physics_frame
		await process_frame
		if player.is_dash_ready():
			break
	_expect(player.is_dash_ready(), "%s dash must become ready after cooldown." % label)
	var cooldown_start_strength := float(
		ready_material.get_shader_parameter(READY_STRENGTH_PARAMETER)
	) if ready_material != null else -1.0
	_expect(
		cooldown_start_strength >= 0.0 and cooldown_start_strength < 0.05,
		"%s cooldown completion must start the ready reveal near zero (actual %.3f)."
		% [label, cooldown_start_strength]
	)
	await create_timer(0.1, true, true).timeout
	var cooldown_mid_strength := float(
		ready_material.get_shader_parameter(READY_STRENGTH_PARAMETER)
	) if ready_material != null else -1.0
	_expect(
		cooldown_mid_strength > 0.0 and cooldown_mid_strength < 0.5,
		"%s cooldown reveal must accelerate from a slow start (halfway %.3f)."
		% [label, cooldown_mid_strength]
	)
	await create_timer(0.12, true, true).timeout
	_expect(
		ready_material != null
		and float(ready_material.get_shader_parameter(READY_STRENGTH_PARAMETER)) >= 0.99,
		"%s ready glow must fully return after its 0.2-second reveal." % label
	)
	_expect(player.apply_damage(1), "%s must take damage again after dash ends." % label)

	player.queue_free()
	await process_frame


func _test_multiplayer_dash_protection() -> void:
	var player := WEISHIDAIER_SCENE.instantiate() as Player
	test_root.add_child(player)
	await process_frame
	player.dash_cooldown = 0.2
	player.configure_multiplayer_control(2, false, "Remote")
	var ready_indicator := player.get_node("DashReadyIndicator") as Control
	_expect(not ready_indicator.visible, "Remote players must not show a misleading local cooldown glow.")
	_expect(
		player.start_multiplayer_dash_protection(Vector2.RIGHT),
		"Host proxy must accept a valid remote dash protection request."
	)
	_expect(not player.is_dashing(), "Host proxy protection must not simulate a second movement dash.")
	var health_before_hit := player.current_health
	_expect(not player.apply_damage(4), "Host proxy must reject damage during confirmed remote dash.")
	_expect(player.current_health == health_before_hit, "Remote dash protection must preserve authoritative health.")
	player.update_multiplayer_authority_passive_state(player.dash_duration + 0.01)
	_expect(player.apply_damage(1), "Host proxy must accept damage after remote dash protection expires.")
	player.queue_free()
	await process_frame


func _test_dash_wall_collision() -> void:
	var wall := StaticBody2D.new()
	wall.position = Vector2(16.0, 0.0)
	wall.collision_layer = 1
	wall.collision_mask = 0
	var wall_shape := CollisionShape2D.new()
	var wall_rectangle := RectangleShape2D.new()
	wall_rectangle.size = Vector2(2.0, 64.0)
	wall_shape.shape = wall_rectangle
	wall.add_child(wall_shape)
	test_root.add_child(wall)

	var player := WEISHIDAIER_SCENE.instantiate() as Player
	player.position = Vector2.ZERO
	player.dash_cooldown = 0.2
	test_root.add_child(player)
	await physics_frame
	await process_frame
	_expect(bool(player.call("_try_start_dash", Vector2.RIGHT)), "Wall test dash must start.")
	for _dash_frame in range(20):
		await physics_frame
		await process_frame
		if not player.is_dashing():
			break
	_expect(
		player.global_position.x <= 8.0,
		"Dash must stop at world collision instead of passing through the wall (x=%.3f)." % player.global_position.x
	)
	_expect(
		player.global_position.distance_to(Vector2.ZERO) < player.dash_distance,
		"A wall-blocked dash must travel less than the configured distance."
	)
	player.queue_free()
	wall.queue_free()
	await process_frame


func _test_dash_preserves_existing_invincibility() -> void:
	var player := WEISHIDAIER_SCENE.instantiate() as Player
	player.dash_cooldown = 0.2
	test_root.add_child(player)
	await process_frame
	player.start_multiplayer_invincibility(1.0)
	_expect(bool(player.call("_try_start_dash", Vector2.RIGHT)), "Invincibility overlap dash must start.")
	for _dash_frame in range(20):
		await physics_frame
		await process_frame
		if not player.is_dashing():
			break
	_expect(
		player.invincibility_time_left > 0.7,
		"Dash must not shorten or replace an existing hurt/revive invincibility timer."
	)
	player.queue_free()
	await process_frame


func _expect(condition: bool, message: String) -> void:
	if condition:
		return
	failures.append(message)
