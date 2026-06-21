extends SceneTree

const PLAYER_SCENE := preload("res://scene/player.tscn")
const BASIC_CONFIG := preload("res://resources/config/enemies/yuanshi_insect_basic.tres")
const GUARDIAN_CONFIG := preload("res://resources/config/enemies/yuanshi_insect_guardian.tres")
const GREEN_SHELL_CONFIG := preload(
	"res://resources/config/enemies/yuanshi_insect_green_shell.tres"
)
const AURA_SCRIPT := preload("res://scene/enemy/yuanshi_insect_aura.gd")

var failures: Array[String] = []
var test_root: Node2D


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	test_root = Node2D.new()
	test_root.name = "YuanshiInsectGuardianSmokeTest"
	root.add_child(test_root)
	current_scene = test_root

	_test_resource_contract()
	await _test_damage_defense_formulas()
	await _test_guardian_aura_visual_configuration()
	await _test_guardian_chase_and_collision_contract()
	await _test_guardian_aura_defense_lifecycle()

	test_root.queue_free()
	await process_frame
	await physics_frame
	for _cleanup_frame in range(4):
		await process_frame

	if failures.is_empty():
		print("YUANSHI_INSECT_GUARDIAN_SMOKE_TEST_OK")
		quit()
		return

	for failure in failures:
		push_error(failure)
	quit(1)


func _test_resource_contract() -> void:
	_expect(
		GUARDIAN_CONFIG is YuanshiInsectGuardianConfig,
		"Guardian config must use YuanshiInsectGuardianConfig."
	)
	_expect(
		GUARDIAN_CONFIG.variant == YuanshiInsectConfig.Variant.GUARDIAN,
		"Guardian enum variant mismatch."
	)
	_expect(BASIC_CONFIG.enemy_scene != null, "Basic Yuanshi insect must use its own scene.")
	_expect(GUARDIAN_CONFIG.enemy_scene != null, "Guardian must use its own scene.")
	_expect(GUARDIAN_CONFIG.max_health >= 16, "Guardian health is not high enough.")
	_expect(GUARDIAN_CONFIG.attack_damage == 1, "Guardian attack damage must be 1.")
	_expect(
		is_equal_approx(GUARDIAN_CONFIG.move_speed, BASIC_CONFIG.move_speed),
		"Guardian must keep normal Yuanshi insect movement speed."
	)
	var basic_scene_enemy := BASIC_CONFIG.enemy_scene.instantiate() as YuanshiInsect
	var guardian_scene_enemy := GUARDIAN_CONFIG.enemy_scene.instantiate() as YuanshiInsect
	_expect(guardian_scene_enemy != null, "Guardian scene must instantiate YuanshiInsect.")
	if guardian_scene_enemy == null:
		basic_scene_enemy.free()
		return
	_expect(guardian_scene_enemy.get_script() == AURA_SCRIPT, "Guardian scene must use the aura script.")
	var basic_body_node := basic_scene_enemy.get_node("CollisionShape2D") as CollisionShape2D
	var guardian_body_node := guardian_scene_enemy.get_node("CollisionShape2D") as CollisionShape2D
	_expect(
		basic_body_node != null and basic_body_node.shape != null,
		"Basic Yuanshi insect body collision shape must be configured."
	)
	_expect(
		guardian_body_node != null and guardian_body_node.shape != null,
		"Guardian body collision shape must be configured."
	)
	if basic_body_node != null and basic_body_node.shape != null:
		_expect(_get_shape_extent_radius(basic_body_node) > 0.0, "Basic Yuanshi insect body collision extent must be positive.")
	if guardian_body_node != null and guardian_body_node.shape != null:
		_expect(_get_shape_extent_radius(guardian_body_node) > 0.0, "Guardian body collision extent must be positive.")
	basic_scene_enemy.free()
	guardian_scene_enemy.free()
	_expect(
		GUARDIAN_CONFIG.aura_radius > GREEN_SHELL_CONFIG.aura_radius,
		"Guardian aura must be larger than green shell aura."
	)
	_expect(
		GUARDIAN_CONFIG.aura_physical_defense_bonus == 3,
		"Guardian aura must provide exactly +3 physical defense."
	)
	var texture := load("res://resources/texture/yuanshi_insect_guardian.png") as Texture2D
	var image := texture.get_image() if texture != null else null
	_expect(image != null and image.get_size() == Vector2i(96, 64), "Guardian sprite sheet size is incorrect.")


func _test_damage_defense_formulas() -> void:
	var player := PLAYER_SCENE.instantiate() as Player
	test_root.add_child(player)
	await physics_frame
	player.invincibility_duration = 0.0
	player.current_health = 20
	player.physical_defense = 2
	player.magic_defense = 25
	player.apply_damage(5)
	_expect(player.current_health == 17, "Player physical defense formula is incorrect.")
	player.apply_damage(7, EnemyConfig.DamageType.MAGIC)
	_expect(player.current_health == 12, "Player magic defense formula is incorrect.")

	var enemy_config := BASIC_CONFIG.duplicate(true) as YuanshiInsectConfig
	enemy_config.physical_defense = 2
	enemy_config.magic_defense = 25
	var enemy := _spawn_enemy(Vector2.ZERO, enemy_config, player)
	enemy.current_health = 20
	enemy.apply_damage(5)
	_expect(enemy.current_health == 17, "Enemy physical defense formula is incorrect.")
	enemy.apply_damage(7, Vector2.ZERO, EnemyConfig.DamageType.MAGIC)
	_expect(enemy.current_health == 12, "Enemy magic defense formula is incorrect.")

	player.queue_free()
	enemy.queue_free()
	await physics_frame


func _test_guardian_aura_visual_configuration() -> void:
	var player := _spawn_player(Vector2(160.0, 0.0))
	var guardian: Variant = _spawn_enemy(Vector2.ZERO, GUARDIAN_CONFIG, player)
	_expect(guardian != null, "Guardian scene must instantiate YuanshiInsect.")
	if guardian == null:
		player.queue_free()
		return
	_expect(guardian.get_script() == AURA_SCRIPT, "Guardian scene must use the aura script.")
	await _wait_physics_frames(3)

	var aura_shape := guardian.aura_area_shape.shape as CircleShape2D

	_expect(guardian.aura_active, "Guardian aura did not start.")
	_expect(not GUARDIAN_CONFIG.aura_particles_enabled, "Guardian aura particles should be disabled.")
	_expect(not guardian.aura_particles.emitting, "Guardian should not emit aura particles.")
	_expect(guardian.aura_area.collision_mask == 4, "Guardian aura must monitor enemy bodies.")
	_expect(aura_shape != null, "Guardian aura shape is not circular.")
	if aura_shape != null:
		_expect(is_equal_approx(aura_shape.radius, GUARDIAN_CONFIG.aura_radius), "Guardian aura radius ignored config.")
	_expect(guardian.aura_range_fill.visible, "Guardian aura fill is hidden.")
	_expect(guardian.aura_range_outline.visible, "Guardian aura outline is hidden.")
	_expect(
		guardian.get_effective_physical_defense() == GUARDIAN_CONFIG.physical_defense,
		"Guardian must not receive its own aura defense."
	)

	guardian.queue_free()
	player.queue_free()
	await physics_frame


func _test_guardian_chase_and_collision_contract() -> void:
	var player := _spawn_player(Vector2(96.0, 0.0))
	var guardian: Variant = _spawn_enemy(Vector2.ZERO, GUARDIAN_CONFIG, player)
	_expect(guardian != null, "Guardian scene must instantiate YuanshiInsect.")
	if guardian == null:
		player.queue_free()
		return
	_expect(guardian.get_script() == AURA_SCRIPT, "Guardian scene must use the aura script.")
	await _wait_physics_frames(2)

	var body_shape := guardian.collision_shape.shape as Shape2D
	var touch_shape := guardian.touch_damage_shape.shape as Shape2D
	_expect(body_shape != null, "Guardian body collision shape must be configured.")
	_expect(touch_shape != null, "Guardian touch damage shape must be configured.")
	if body_shape != null:
		_expect(_get_shape_extent_radius(guardian.collision_shape) > 0.0, "Guardian body collision extent must be positive.")
	if touch_shape != null:
		_expect(_get_shape_extent_radius(guardian.touch_damage_shape) > 0.0, "Guardian touch damage extent must be positive.")
	_expect(guardian.collision_shape.shape != guardian.touch_damage_shape.shape, "Guardian body and touch shapes must be independently editable.")

	var start_distance: float = guardian.global_position.distance_to(player.global_position)
	await _wait_physics_frames(12)
	var end_distance: float = guardian.global_position.distance_to(player.global_position)
	_expect(end_distance < start_distance - 1.0, "Guardian did not move toward the player.")

	guardian.queue_free()
	player.queue_free()
	await physics_frame


func _test_guardian_aura_defense_lifecycle() -> void:
	var player := _spawn_player(Vector2(160.0, 0.0))
	var guardian: Variant = _spawn_enemy(Vector2.ZERO, GUARDIAN_CONFIG, player)
	_expect(guardian != null, "Guardian scene must instantiate YuanshiInsect.")
	if guardian == null:
		player.queue_free()
		return
	_expect(guardian.get_script() == AURA_SCRIPT, "Guardian scene must use the aura script.")
	var second_guardian: Variant = _spawn_enemy(Vector2(120.0, 0.0), GUARDIAN_CONFIG, player)
	var ally := _spawn_enemy(Vector2(20.0, 0.0), BASIC_CONFIG, player)
	ally.current_health = 20
	await _wait_physics_frames(2)

	guardian.call("_on_aura_area_body_entered", guardian)
	_expect(
		guardian.get_effective_physical_defense() == GUARDIAN_CONFIG.physical_defense,
		"Guardian aura must ignore its owner."
	)

	guardian.call("_on_aura_area_body_entered", ally)
	_expect(ally.get_effective_physical_defense() == 3, "Guardian aura did not add +3 physical defense.")
	second_guardian.call("_on_aura_area_body_entered", ally)
	_expect(ally.get_effective_physical_defense() == 6, "Guardian aura bonuses from multiple guardians must stack.")
	second_guardian.call("_on_aura_area_body_exited", ally)
	_expect(ally.get_effective_physical_defense() == 3, "Guardian aura stack did not remove one source on exit.")
	ally.apply_damage(4)
	_expect(ally.current_health == 19, "Guardian aura did not reduce physical damage by 3.")

	guardian.call("_on_aura_area_body_exited", ally)
	_expect(ally.get_effective_physical_defense() == 0, "Guardian aura defense did not clear on exit.")
	ally.apply_damage(4)
	_expect(ally.current_health == 15, "Enemy kept guardian defense after leaving aura.")

	guardian.call("_on_aura_area_body_entered", ally)
	_expect(ally.get_effective_physical_defense() == 3, "Guardian aura did not reapply physical defense.")
	guardian.apply_damage(
		GUARDIAN_CONFIG.max_health
		+ GUARDIAN_CONFIG.physical_defense
	)
	await _wait_physics_frames(45)
	_expect(ally.get_effective_physical_defense() == 0, "Guardian aura defense did not clear on death.")

	if is_instance_valid(guardian):
		guardian.queue_free()
	if is_instance_valid(second_guardian):
		second_guardian.queue_free()
	ally.queue_free()
	player.queue_free()
	await physics_frame


func _spawn_player(position: Vector2) -> Player:
	var player := PLAYER_SCENE.instantiate() as Player
	test_root.add_child(player)
	player.global_position = position
	return player


func _spawn_enemy(
	position: Vector2,
	enemy_config: YuanshiInsectConfig,
	player: Player
) -> YuanshiInsect:
	var enemy := enemy_config.enemy_scene.instantiate() as YuanshiInsect
	test_root.add_child(enemy)
	enemy.global_position = position
	enemy.setup(enemy_config, player)
	return enemy


func _wait_physics_frames(frame_count: int) -> void:
	for _frame_index in range(frame_count):
		await physics_frame


func _get_shape_extent_radius(shape_node: CollisionShape2D) -> float:
	if shape_node == null or shape_node.shape == null:
		return 0.0
	var shape_rect := shape_node.shape.get_rect()
	var corners := [
		shape_rect.position,
		shape_rect.position + Vector2(shape_rect.size.x, 0.0),
		shape_rect.position + Vector2(0.0, shape_rect.size.y),
		shape_rect.position + shape_rect.size,
	]
	var max_radius := 0.0
	for corner in corners:
		max_radius = maxf(max_radius, (shape_node.transform * corner).length())
	return max_radius


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
