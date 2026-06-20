extends SceneTree

const PLAYER_SCENE := preload("res://scene/player.tscn")
const GREEN_SHELL_CONFIG := preload(
	"res://resources/config/enemies/yuanshi_insect_green_shell.tres"
)
const BASIC_CONFIG := preload("res://resources/config/enemies/yuanshi_insect_basic.tres")
const AURA_SCRIPT := preload("res://scene/enemy/yuanshi_insect_aura.gd")

var failures: Array[String] = []
var test_root: Node2D


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	test_root = Node2D.new()
	test_root.name = "YuanshiInsectGreenShellSmokeTest"
	root.add_child(test_root)
	current_scene = test_root

	_test_resource_contract()
	await _test_aura_visual_configuration()
	await _test_shared_attack_damage()
	await _test_aura_damage_and_shutdown()
	await _test_normal_enemy_has_no_aura()

	test_root.queue_free()
	await process_frame
	await physics_frame
	for _cleanup_frame in range(4):
		await process_frame

	if failures.is_empty():
		print("YUANSHI_INSECT_GREEN_SHELL_SMOKE_TEST_OK")
		quit()
		return

	for failure in failures:
		push_error(failure)
	quit(1)


func _test_resource_contract() -> void:
	_expect(
		GREEN_SHELL_CONFIG is YuanshiInsectGreenShellConfig,
		"Green shell config must use its dedicated resource type."
	)
	_expect(GREEN_SHELL_CONFIG.enemy_scene != null, "Green shell must use its own scene.")
	_expect(GREEN_SHELL_CONFIG.aura_enabled, "Green shell aura must be enabled.")
	_expect(GREEN_SHELL_CONFIG.attack_damage > 0, "Green shell attack damage must be positive.")
	var scene_enemy := GREEN_SHELL_CONFIG.enemy_scene.instantiate() as YuanshiInsect
	_expect(scene_enemy != null, "Green shell scene must instantiate YuanshiInsect.")
	if scene_enemy == null:
		return
	_expect(scene_enemy.get_script() == AURA_SCRIPT, "Green shell scene must use the aura script.")
	var body_shape_node := scene_enemy.get_node("CollisionShape2D") as CollisionShape2D
	var body_shape := body_shape_node.shape as CircleShape2D
	_expect(body_shape != null, "Green shell body collision shape must be circular.")
	if body_shape != null:
		_expect(GREEN_SHELL_CONFIG.aura_radius > body_shape.radius, "Aura must exceed body radius.")
	scene_enemy.free()
	_expect(GREEN_SHELL_CONFIG.aura_particle_amount >= 60, "Aura particles are not dense enough.")
	_expect(GREEN_SHELL_CONFIG.aura_particle_texture != null, "Aura particle texture is missing.")
	_expect(GREEN_SHELL_CONFIG.aura_particle_color_ramp != null, "Aura color ramp is missing.")
	_expect(
		GREEN_SHELL_CONFIG.aura_particle_emission_radius
		+ GREEN_SHELL_CONFIG.aura_particle_speed_max
		* GREEN_SHELL_CONFIG.aura_particle_lifetime
		<= GREEN_SHELL_CONFIG.aura_radius,
		"Aura particles can travel beyond the damage radius."
	)


func _test_aura_visual_configuration() -> void:
	var player := _spawn_player(Vector2(200.0, 0.0))
	var enemy: Variant = _spawn_enemy(Vector2.ZERO, GREEN_SHELL_CONFIG, player)
	var second_enemy: Variant = _spawn_enemy(Vector2(100.0, 100.0), GREEN_SHELL_CONFIG, player)
	_expect(enemy != null and second_enemy != null, "Green shell scenes must instantiate YuanshiInsect.")
	if enemy == null or second_enemy == null:
		player.queue_free()
		return
	_expect(enemy.get_script() == AURA_SCRIPT, "Green shell scene must use the aura script.")
	_expect(second_enemy.get_script() == AURA_SCRIPT, "Second green shell scene must use the aura script.")
	await _wait_physics_frames(3)

	var aura_shape := enemy.aura_area_shape.shape as CircleShape2D
	var aura_material := enemy.aura_particles.process_material as ParticleProcessMaterial
	var second_material := second_enemy.aura_particles.process_material as ParticleProcessMaterial

	_expect(enemy.aura_active, "Green shell aura did not start.")
	_expect(enemy.aura_particles.emitting, "Green shell particles are not emitting continuously.")
	_expect(enemy.aura_particles.local_coords, "Aura particles must stay attached to the moving enemy.")
	_expect(enemy.aura_particles.amount == GREEN_SHELL_CONFIG.aura_particle_amount, "Particle amount ignored config.")
	_expect(enemy.aura_particles.texture == GREEN_SHELL_CONFIG.aura_particle_texture, "Particle texture ignored config.")
	_expect(
		is_equal_approx(enemy.aura_particles.lifetime, GREEN_SHELL_CONFIG.aura_particle_lifetime),
		"Particle lifetime ignored config."
	)
	_expect(aura_shape != null, "Aura damage shape is not circular.")
	if aura_shape != null:
		_expect(is_equal_approx(aura_shape.radius, GREEN_SHELL_CONFIG.aura_radius), "Aura radius ignored config.")
	_expect(aura_material != null, "Aura particle material is missing.")
	if aura_material != null:
		_expect(
			aura_material.emission_shape == ParticleProcessMaterial.EMISSION_SHAPE_RING,
			"Aura particles are not emitted from a ring."
		)
		_expect(
			is_equal_approx(
				aura_material.emission_ring_radius,
				GREEN_SHELL_CONFIG.aura_particle_emission_radius
			),
			"Particle emission ring radius ignored config."
		)
		_expect(
			is_equal_approx(
				aura_material.emission_ring_inner_radius,
				GREEN_SHELL_CONFIG.aura_particle_emission_radius
				- GREEN_SHELL_CONFIG.aura_particle_emission_thickness
			),
			"Particle emission ring thickness ignored config."
		)
		_expect(
			is_equal_approx(aura_material.radial_velocity_min, GREEN_SHELL_CONFIG.aura_particle_speed_min),
			"Particle minimum speed ignored config."
		)
		_expect(
			is_equal_approx(aura_material.radial_velocity_max, GREEN_SHELL_CONFIG.aura_particle_speed_max),
			"Particle maximum speed ignored config."
		)
		_expect(
			aura_material.color_initial_ramp == GREEN_SHELL_CONFIG.aura_particle_color_ramp,
			"Particle color variation ignored config."
		)
	_expect(aura_material != second_material, "Aura material is shared between enemy instances.")
	_expect(enemy.aura_range_fill.visible, "Aura range fill is hidden.")
	_expect(enemy.aura_range_outline.visible, "Aura range outline is hidden.")
	_expect(enemy.aura_range_fill.color == GREEN_SHELL_CONFIG.aura_fill_color, "Aura fill color ignored config.")
	_expect(
		enemy.aura_range_outline.default_color == GREEN_SHELL_CONFIG.aura_outline_color,
		"Aura outline color ignored config."
	)
	_expect(enemy.aura_range_outline.points.size() >= 32, "Aura outline is too coarse.")
	for point in enemy.aura_range_outline.points:
		_expect(
			is_equal_approx(point.length(), GREEN_SHELL_CONFIG.aura_radius),
			"Aura outline does not match the damage radius."
		)
		if not failures.is_empty():
			break

	enemy.queue_free()
	second_enemy.queue_free()
	player.queue_free()
	await physics_frame


func _test_shared_attack_damage() -> void:
	var test_config := GREEN_SHELL_CONFIG.duplicate(true) as YuanshiInsectGreenShellConfig
	test_config.move_speed = 0.0
	test_config.aura_damage_interval = 10.0

	var player := _spawn_player(Vector2(200.0, 0.0))
	player.invincibility_duration = 0.0
	var enemy: Variant = _spawn_enemy(Vector2.ZERO, test_config, player)
	_expect(enemy != null, "Green shell scene must instantiate YuanshiInsect.")
	if enemy == null:
		player.queue_free()
		return
	_expect(enemy.get_script() == AURA_SCRIPT, "Green shell scene must use the aura script.")
	await _wait_physics_frames(2)

	var initial_health := player.current_health
	enemy.aura_touched_player = player
	enemy.call("_try_deal_aura_damage")

	_expect(
		player.current_health == initial_health - test_config.attack_damage,
		(
			"Aura damage did not use base attack damage "
			+ "(health %d -> %d, config %d, runtime %d)."
			% [
				initial_health,
				player.current_health,
				test_config.attack_damage,
				enemy.config.attack_damage,
			]
		)
	)

	enemy.aura_touched_player = null
	var health_after_aura := player.current_health
	enemy.touched_player = player
	enemy.call("_try_deal_touch_damage")
	_expect(
		player.current_health == health_after_aura - test_config.attack_damage,
		(
			"Body contact damage did not use base attack damage "
			+ "(health %d -> %d, config %d, runtime %d)."
			% [
				health_after_aura,
				player.current_health,
				test_config.attack_damage,
				enemy.config.attack_damage,
			]
		)
	)

	enemy.queue_free()
	player.queue_free()
	await physics_frame


func _test_aura_damage_and_shutdown() -> void:
	var test_config := GREEN_SHELL_CONFIG.duplicate(true) as YuanshiInsectGreenShellConfig
	test_config.move_speed = 0.0
	test_config.aura_damage_interval = 0.1

	var player := _spawn_player(Vector2(24.0, 0.0))
	player.invincibility_duration = 0.0
	var enemy: Variant = _spawn_enemy(Vector2.ZERO, test_config, player)
	_expect(enemy != null, "Green shell scene must instantiate YuanshiInsect.")
	if enemy == null:
		player.queue_free()
		return
	_expect(enemy.get_script() == AURA_SCRIPT, "Green shell scene must use the aura script.")
	var initial_health := player.current_health
	await _wait_physics_frames(5)

	_expect(player.current_health < initial_health, "Aura did not damage a player inside its radius.")
	player.global_position = Vector2(100.0, 0.0)
	await _wait_physics_frames(3)
	var health_after_exit := player.current_health
	await _wait_physics_frames(12)
	_expect(player.current_health == health_after_exit, "Aura kept damaging the player after exit.")

	enemy.apply_damage(test_config.max_health + test_config.physical_defense)
	await physics_frame
	_expect(not enemy.aura_active, "Aura remained active after enemy death.")
	_expect(not enemy.aura_particles.emitting, "Aura particles remained active after enemy death.")
	_expect(not enemy.aura_range_outline.visible, "Aura range remained visible after enemy death.")

	enemy.queue_free()
	player.queue_free()
	await physics_frame


func _test_normal_enemy_has_no_aura() -> void:
	var player := _spawn_player(Vector2(100.0, 0.0))
	var enemy := _spawn_enemy(Vector2.ZERO, BASIC_CONFIG, player)
	await _wait_physics_frames(2)

	_expect(enemy.get_script() != AURA_SCRIPT, "Normal Yuanshi insect unexpectedly uses the aura script.")
	_expect(enemy.get_node_or_null("AuraArea") == null, "Normal Yuanshi insect unexpectedly owns AuraArea.")
	_expect(enemy.get_node_or_null("AuraParticles") == null, "Normal Yuanshi insect unexpectedly owns AuraParticles.")
	_expect(enemy.get_node_or_null("AuraRangeOutline") == null, "Normal Yuanshi insect unexpectedly owns an aura range.")

	enemy.queue_free()
	player.queue_free()
	await physics_frame


func _spawn_player(position: Vector2) -> Player:
	var player := PLAYER_SCENE.instantiate() as Player
	player.global_position = position
	test_root.add_child(player)
	player.max_health = 100
	player.current_health = player.max_health
	player.health_bar.setup(player.max_health, player.current_health)
	return player


func _spawn_enemy(
	position: Vector2,
	enemy_config: YuanshiInsectConfig,
	player: Player
) -> YuanshiInsect:
	var enemy := enemy_config.enemy_scene.instantiate() as YuanshiInsect
	enemy.global_position = position
	test_root.add_child(enemy)
	enemy.setup(enemy_config, player)
	return enemy


func _wait_physics_frames(frame_count: int) -> void:
	for _frame_index in range(frame_count):
		await physics_frame


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
