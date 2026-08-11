extends SceneTree

const MpProjectileCoordinator := preload(
	"res://scene/multiplayer/projectile/mp_projectile_coordinator.gd"
)
const BULLET_SCENE := preload(
	"res://scene/enemy/mechanical_life/combat_robot_gunner_bullet.tscn"
)
const ELITE_BULLET_SCENE := preload(
	"res://scene/enemy/mechanical_life/combat_robot_gunner_elite_bullet.tscn"
)
const MP_GAME_SCRIPT := preload("res://scene/multiplayer/mp_game.gd")
const DAMAGEABLE_LAYER := 2
const WORLD_LAYER := 1
const WATER_TERRAIN_LAYER := 1 << 11
const TEST_SPEED := 240.0
const TEST_COMPENSATION_AGE := 0.25

class ClientViewGateway:
	extends MultiplayerGameplayGateway

	func is_client_view() -> bool:
		return true


var failures: Array[String] = []


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	await _test_scene_and_animation_contract()
	_test_runtime_registration_contract()
	await _test_multiplayer_projectile_branch_preserves_host_direction()
	await _test_compensated_sweep_hits_damageable()
	await _test_water_terrain_does_not_block_compensated_sweep()
	await _test_world_blocks_compensated_sweep_before_target()
	await _test_invalid_plants_are_ignored_for_full_compensation()
	await _test_live_plant_behind_dead_plant_is_still_hit()
	await _test_client_view_plant_hit_consumes_visual_without_damage()
	_finish()


func _test_scene_and_animation_contract() -> void:
	var fixture := _create_fixture("GunnerBulletResourceFixture")
	var bullet := BULLET_SCENE.instantiate() as CombatRobotGunnerBullet
	fixture.add_child(bullet)
	bullet.set_physics_process(false)
	_expect(bullet is CapooAK47Bullet, "Gunner bullet must inherit the AK projectile contract.")
	var bullet_source := FileAccess.get_file_as_string(
		"res://scene/enemy/mechanical_life/combat_robot_gunner_bullet.gd"
	)
	_expect(
		not bullet_source.contains("func _advance_projectile"),
		"Normal flight must keep the inherited AK/Area2D path; only compensation may sweep."
	)
	_expect(
		bullet.source_type == &"combat_robot_gunner_bullet",
		"Gunner bullet must own a dedicated multiplayer source type."
	)
	_expect(
		bullet.collision_layer == 128
		and bullet.collision_mask == CapooAK47Bullet.DAMAGEABLE_COLLISION_MASK,
		"Gunner bullet must retain the AK Player/PlantDefense collision profile."
	)
	_expect(
		bullet.animated_sprite.texture_filter == CanvasItem.TEXTURE_FILTER_NEAREST,
		"Gunner bullet must pin nearest-neighbor filtering in its scene."
	)
	var rectangle := bullet.sweep_collision_shape.shape as RectangleShape2D
	_expect(
		rectangle != null and rectangle.size == Vector2(9.0, 3.0),
		"Gunner bullet collision shape must match its visible 9x3 footprint."
	)
	var frames := bullet.animated_sprite.sprite_frames
	_expect(
		frames != null and frames.has_animation(&"fly")
		and frames.get_frame_count(&"fly") == 3
		and is_equal_approx(frames.get_animation_speed(&"fly"), 25.0)
		and frames.get_animation_loop(&"fly"),
		"Gunner bullet fly animation must be three looping frames at 25 FPS."
	)
	if frames != null and frames.has_animation(&"fly"):
		for frame_index in range(3):
			var atlas_texture := frames.get_frame_texture(&"fly", frame_index) as AtlasTexture
			_expect(
				atlas_texture != null
				and atlas_texture.region
					== Rect2(frame_index * 12.0, 0.0, 12.0, 8.0),
				"Fly frame %d must use its exact 12x8 atlas cell." % frame_index
			)
	var texture := load(
		"res://resources/texture/enemy/mechanical_life/combat_robot_gunner_bullet.png"
	) as Texture2D
	_expect(
		texture != null and texture.get_size() == Vector2(36.0, 8.0),
		"Gunner bullet atlas must be exactly 36x8."
	)
	if texture != null:
		var image := texture.get_image()
		var reference_alpha := PackedByteArray()
		for frame_index in range(3):
			var frame_image := image.get_region(Rect2i(frame_index * 12, 0, 12, 8))
			_expect(
				frame_image.get_used_rect() == Rect2i(2, 3, 9, 3),
				"Fly frame %d must expose the exact local 9x3 silhouette." % frame_index
			)
			var alpha := _get_alpha_mask(frame_image)
			if frame_index == 0:
				reference_alpha = alpha
			else:
				_expect(
					alpha == reference_alpha,
					"All fly frames must preserve the same alpha outline."
				)
	await _dispose_fixture(fixture)


func _test_multiplayer_projectile_branch_preserves_host_direction() -> void:
	var fixture := _create_fixture("GunnerBulletMultiplayerFixture")
	var runtime := StandardGame.new()
	var gameplay_gateway := MultiplayerGameplayGateway.new()
	gameplay_gateway.name = "MultiplayerGameplayGateway"
	runtime.add_child(gameplay_gateway)
	gameplay_gateway.bind_runtime(runtime)
	var coordinator := MpProjectileCoordinator.new()
	coordinator.bind_runtime(runtime)
	var host_direction := Vector2(0.6, 0.8)
	var projectile := coordinator.instantiate_projectile(
		&"combat_robot_gunner_bullet",
		1,
		host_direction,
		35,
		TEST_SPEED,
		1.4,
		false,
		0,
		0
	) as CombatRobotGunnerBullet
	_expect(projectile != null, "MpGame must instantiate the dedicated gunner projectile type.")
	if projectile != null:
		projectile.set_physics_process(false)
		_expect(
			projectile.direction.is_equal_approx(host_direction),
			"MpGame must preserve the Host-authored spread direction exactly."
		)
		_expect(
			is_equal_approx(projectile.rotation, host_direction.angle()),
			"Gunner projectile rotation must follow the accepted Host direction."
		)
	var elite_projectile := coordinator.instantiate_projectile(
		&"combat_robot_gunner_elite_bullet",
		1,
		host_direction,
		50,
		80.0,
		1.5,
		false,
		0,
		0
	) as CombatRobotGunnerBullet
	_expect(
		elite_projectile != null,
		"MpGame must instantiate the elite projectile type."
	)
	if elite_projectile != null:
		elite_projectile.set_physics_process(false)
		_expect(
			elite_projectile.authored_source_type
			== &"combat_robot_gunner_elite_bullet",
			"Elite projectile must retain its authored stable source before tree entry."
		)
	coordinator.unbind_runtime(runtime)
	coordinator.free()
	runtime.free()
	await _dispose_fixture(fixture)


func _test_runtime_registration_contract() -> void:
	for source_path in [
		"res://scene/combat/runtime/wave_combat_runtime_base.gd",
		"res://scene/game_modes/tower_defense/prewarm/tower_defense_prewarmer_coordinator.gd",
	]:
		var source := FileAccess.get_file_as_string(source_path)
		_expect(
			source.contains(
				"CombatRuntimeBase.register_combat_robot_gunner_bullet_pool("
			),
			"%s must use the shared gunner projectile pool contract." % source_path
		)
		_expect(
			source.contains(
				"CombatRuntimeBase.register_combat_robot_gunner_elite_bullet_pool("
			),
			"%s must use the shared elite gunner projectile pool contract." % source_path
		)
	var pool := SessionObjectPool.new()
	root.add_child(pool)
	CombatRuntimeBase.register_combat_robot_gunner_bullet_pool(pool)
	CombatRuntimeBase.register_combat_robot_gunner_elite_bullet_pool(pool)
	var pool_metrics := pool.get_metrics(BULLET_SCENE.resource_path)
	_expect(
		int(pool_metrics.get("created", -1))
			== CombatRuntimeBase.COMBAT_ROBOT_GUNNER_BULLET_PREWARM_COUNT
		and int(pool_metrics.get("inactive", -1))
			== CombatRuntimeBase.COMBAT_ROBOT_GUNNER_BULLET_PREWARM_COUNT
		and int(pool_metrics.get("retained_capacity", -1))
			== CombatRuntimeBase.COMBAT_ROBOT_GUNNER_BULLET_RETAINED_CAPACITY,
		"Shared gunner pool must stay lazy (0 prewarm) and retain 96 in both runtimes."
	)
	var elite_pool_metrics := pool.get_metrics(ELITE_BULLET_SCENE.resource_path)
	_expect(
		int(elite_pool_metrics.get("created", -1))
			== CombatRuntimeBase.COMBAT_ROBOT_GUNNER_ELITE_BULLET_PREWARM_COUNT
		and int(elite_pool_metrics.get("retained_capacity", -1))
			== CombatRuntimeBase.COMBAT_ROBOT_GUNNER_ELITE_BULLET_RETAINED_CAPACITY,
		"Shared elite gunner pool must stay lazy (0 prewarm) and retain 96."
	)
	pool.free()
	var catalog_source := FileAccess.get_file_as_string(
		"res://scene/game_modes/game_mode_catalog.gd"
	)
	_expect(
		catalog_source.contains(
			"res://scene/enemy/mechanical_life/combat_robot_gunner_bullet.tscn"
		)
		and catalog_source.contains(
			"res://scene/enemy/mechanical_life/combat_robot_gunner_elite_bullet.tscn"
		),
		"GameModeCatalog must stage-load both gunner projectile scenes."
	)
	var telemetry_source := FileAccess.get_file_as_string(
		"res://scene/combat/diagnostics/runtime_performance_telemetry.gd"
	)
	_expect(
		telemetry_source.contains(
			"res://scene/enemy/mechanical_life/combat_robot_gunner_bullet.gd"
		),
		"Runtime telemetry must classify the dedicated gunner projectile script."
	)


func _test_compensated_sweep_hits_damageable() -> void:
	var fixture := _create_fixture("GunnerBulletDamageableSweepFixture")
	_add_static_body(fixture, DAMAGEABLE_LAYER, Vector2(40.0, 0.0))
	var bullet := await _spawn_stationary_test_bullet(fixture)
	bullet.simulate_compensated_motion(TEST_COMPENSATION_AGE)
	_expect(bullet.has_hit, "Compensated motion must sweep a thin damageable body.")
	_expect(
		bullet.global_position.x > 30.0 and bullet.global_position.x < 45.0,
		"Damageable sweep must stop at the target instead of teleporting past it."
	)
	await _dispose_fixture(fixture)


func _test_water_terrain_does_not_block_compensated_sweep() -> void:
	var fixture := _create_fixture("GunnerBulletWaterSweepFixture")
	_add_static_body(fixture, WATER_TERRAIN_LAYER, Vector2(20.0, 0.0))
	_add_static_body(fixture, DAMAGEABLE_LAYER, Vector2(40.0, 0.0))
	var bullet := await _spawn_stationary_test_bullet(fixture)
	bullet.simulate_compensated_motion(TEST_COMPENSATION_AGE)
	_expect(bullet.has_hit, "WaterTerrain must not prevent the later damageable hit.")
	_expect(
		bullet.global_position.x > 30.0,
		"WaterTerrain layer 12 must not stop the gunner bullet."
	)
	await _dispose_fixture(fixture)


func _test_world_blocks_compensated_sweep_before_target() -> void:
	var fixture := _create_fixture("GunnerBulletWorldSweepFixture")
	_add_static_body(fixture, WORLD_LAYER, Vector2(20.0, 0.0))
	_add_static_body(fixture, DAMAGEABLE_LAYER, Vector2(40.0, 0.0))
	var bullet := await _spawn_stationary_test_bullet(fixture)
	bullet.simulate_compensated_motion(TEST_COMPENSATION_AGE)
	_expect(bullet.has_hit, "World impact must consume compensated gunner motion.")
	_expect(
		bullet.global_position.x < 25.0,
		"Compensation must stop at World before a damageable body behind it."
	)
	await _dispose_fixture(fixture)


func _test_invalid_plants_are_ignored_for_full_compensation() -> void:
	var fixture := _create_fixture("GunnerBulletInvalidPlantFixture")
	var dead_plant := _add_plant(fixture, Vector2(20.0, 0.0))
	dead_plant.is_dead = true
	var removing_plant := _add_plant(fixture, Vector2(40.0, 0.0))
	removing_plant.is_removing = true
	var bullet := await _spawn_stationary_test_bullet(fixture)
	bullet.simulate_compensated_motion(TEST_COMPENSATION_AGE)
	_expect(
		not bullet.has_hit and bullet.pool_active,
		"Dead/removing plants must neither consume nor retain the visual bullet."
	)
	_expect(
		is_equal_approx(bullet.global_position.x, TEST_SPEED * TEST_COMPENSATION_AGE),
		"Ignoring invalid plants must preserve the complete compensation distance."
	)
	_expect(
		bullet.sweep_exclude.is_empty(),
		"Temporary invalid-plant sweep exclusions must be cleared after compensation."
	)
	await _dispose_fixture(fixture)


func _test_client_view_plant_hit_consumes_visual_without_damage() -> void:
	var fixture := _create_client_view_fixture("GunnerBulletClientPlantFixture")
	var plant := _add_plant(fixture, Vector2(40.0, 0.0))
	var initial_health := plant.current_health
	var bullet := await _spawn_stationary_test_bullet(fixture)
	var gameplay_gateway := (
		fixture.get_node("MultiplayerGameplayGateway")
		as MultiplayerGameplayGateway
	)
	bullet.bind_gameplay_context(null, gameplay_gateway)
	bullet.simulate_compensated_motion(TEST_COMPENSATION_AGE)
	_expect(bullet.has_hit, "Client-view plant contact must consume the visual projectile.")
	_expect(
		plant.current_health == initial_health,
		"Client-view plant contact must not call the authoritative receive_damage path."
	)
	await _dispose_fixture(fixture)


func _test_live_plant_behind_dead_plant_is_still_hit() -> void:
	var fixture := _create_authoritative_fixture(
		"GunnerBulletDeadThenLivePlantFixture"
	)
	var dead_plant := _add_plant(fixture, Vector2(20.0, 0.0))
	dead_plant.is_dead = true
	var live_plant := _add_plant(fixture, Vector2(40.0, 0.0))
	var initial_health := live_plant.current_health
	var bullet := await _spawn_stationary_test_bullet(fixture)
	bullet.bind_gameplay_context(
		fixture,
		fixture.get_multiplayer_gameplay_gateway()
	)
	bullet.simulate_compensated_motion(TEST_COMPENSATION_AGE)
	_expect(
		bullet.has_hit and bullet.global_position.x > 30.0,
		"Sweep exclusion must continue from a dead plant to the first live target behind it."
	)
	_expect(
		live_plant.current_health == initial_health - 35,
		"Single-player/Host compensation must damage the live plant behind a dead one."
	)
	_expect(
		bullet.sweep_exclude.is_empty()
		and bullet.damageable_sweep.query.exclude.is_empty(),
		"Completed compensation must clear local and query exclusion state."
	)
	await _dispose_fixture(fixture)


func _spawn_stationary_test_bullet(fixture: Node2D) -> CombatRobotGunnerBullet:
	var bullet := BULLET_SCENE.instantiate() as CombatRobotGunnerBullet
	fixture.add_child(bullet)
	bullet.global_position = Vector2.ZERO
	bullet.setup(Vector2.RIGHT, 35, TEST_SPEED, 1.4)
	bullet.set_physics_process(false)
	await physics_frame
	return bullet


func _add_static_body(parent: Node2D, layer: int, body_position: Vector2) -> void:
	var body := StaticBody2D.new()
	body.collision_layer = layer
	body.collision_mask = 0
	body.position = body_position
	var collision_shape := CollisionShape2D.new()
	var rectangle := RectangleShape2D.new()
	rectangle.size = Vector2(2.0, 12.0)
	collision_shape.shape = rectangle
	body.add_child(collision_shape)
	parent.add_child(body)


func _add_plant(parent: Node2D, body_position: Vector2) -> PlantDefense:
	var plant := PlantDefense.new()
	plant.collision_layer = 512
	plant.collision_mask = 0
	plant.position = body_position
	plant.max_health = 100
	plant.current_health = 100
	var collision_shape := CollisionShape2D.new()
	var rectangle := RectangleShape2D.new()
	rectangle.size = Vector2(2.0, 12.0)
	collision_shape.shape = rectangle
	plant.add_child(collision_shape)
	parent.add_child(plant)
	return plant


func _get_alpha_mask(image: Image) -> PackedByteArray:
	var result := PackedByteArray()
	result.resize(image.get_width() * image.get_height())
	var write_index := 0
	for y in range(image.get_height()):
		for x in range(image.get_width()):
			result[write_index] = 255 if image.get_pixel(x, y).a > 0.0 else 0
			write_index += 1
	return result


func _create_fixture(fixture_name: String) -> Node2D:
	var fixture := Node2D.new()
	fixture.name = fixture_name
	root.add_child(fixture)
	current_scene = fixture
	return fixture


func _create_client_view_fixture(fixture_name: String) -> Node2D:
	var fixture := Node2D.new()
	fixture.name = fixture_name
	var gameplay_gateway := ClientViewGateway.new()
	gameplay_gateway.name = "MultiplayerGameplayGateway"
	fixture.add_child(gameplay_gateway)
	root.add_child(fixture)
	current_scene = fixture
	return fixture


func _create_authoritative_fixture(
	fixture_name: String
) -> PlayerTestCombatRuntime:
	var fixture := PlayerTestCombatRuntime.new()
	fixture.name = fixture_name
	root.add_child(fixture)
	current_scene = fixture
	return fixture


func _dispose_fixture(fixture: Node) -> void:
	if fixture != null and is_instance_valid(fixture):
		fixture.queue_free()
	await process_frame
	await physics_frame


func _finish() -> void:
	if failures.is_empty():
		print("COMBAT_ROBOT_GUNNER_BULLET_SMOKE_TEST_OK")
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	quit(1)


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
