extends SceneTree

const BULLET_SCENE := preload("res://scene/combat/projectiles/bullet.tscn")
const ARROW_SCENE := preload("res://scene/combat/collectibles/collectible_arrow_projectile.tscn")
const TANGO_SCENE := preload("res://scene/player/tango/tango_laser_bullet.tscn")
const TIYI_SCENE := preload("res://scene/player/tiyi/tiyi_sniper_bullet.tscn")
const WEISHIDAIER_BOMB_SCENE := preload(
	"res://scene/player/weishidaier/weishidaier_skill1_bomb.tscn"
)
const AGAVE_CANNONBALL_SCENE := preload(
	"res://scene/plant_defense/agave_cannonball.tscn"
)
const SAKURA_ROCKET_SCENE := preload(
	"res://scene/combat/collectibles/collectible_sakura_rocket.tscn"
)
const SHIELD_BEARER_SCENE := preload(
	"res://scene/enemy/mechanical_life/combat_robot_shield_bearer.tscn"
)
const SHIELD_BEARER_CONFIG := preload(
	"res://resources/config/enemies/combat_robot_shield_bearer.tres"
)
const PLAYER_TEST_RUNTIME := preload(
	"res://dev_tools/player_test_combat_runtime.gd"
)

const PROJECTILE_SHIELD_LAYER := 1 << 12

var failures: Array[String] = []


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	await _test_strong_type_and_atomic_durability()
	await _test_signal_safe_monitorable_transition()
	await _test_proxy_visual_consumption_is_read_only()
	await _test_real_ray_front_and_back_contract()
	await _test_real_projectile_interception_matrix()
	await _test_scene_query_configuration()
	_test_source_matrix_contract()
	_finish()


func _test_strong_type_and_atomic_durability() -> void:
	var fixture := _create_fixture("ShieldAtomicFixture")
	var owner_enemy := Enemy.new()
	var shield := await _add_shield(fixture, owner_enemy, Vector2.ZERO)
	var event_counts := {"durability": 0, "break": 0}
	shield.durability_changed.connect(func(_remaining: int, _maximum: int) -> void:
		event_counts["durability"] = int(event_counts["durability"]) + 1
	)
	shield.shield_broken.connect(func() -> void:
		event_counts["break"] = int(event_counts["break"]) + 1
	)

	_expect(shield.get_owner_enemy() == owner_enemy, "Shield must retain its typed Enemy owner.")
	_expect(shield.is_active(), "A freshly configured shield must be active.")
	_expect(
		shield.collision_layer == PROJECTILE_SHIELD_LAYER
		and shield.collision_mask == 0
		and not shield.monitoring
		and shield.monitorable,
		"Shield must be a passive layer-13 query target."
	)
	_expect(
		not shield.try_intercept(Vector2.RIGHT),
		"A right-facing shield must not intercept travel from its back."
	)
	_expect(
		shield.get_remaining_durability() == 20,
		"Back contact must not consume durability."
	)
	for hit_index in range(19):
		_expect(
			shield.try_intercept(Vector2.LEFT),
			"Front hit %d must be intercepted." % (hit_index + 1)
		)
	_expect(
		shield.get_remaining_durability() == 1 and shield.is_active(),
		"The nineteenth hit must leave exactly one active durability."
	)
	_expect(shield.try_intercept(Vector2.LEFT), "The twentieth hit must still be blocked.")
	_expect(
		shield.get_remaining_durability() == 0
		and not shield.is_active()
		and shield.collision_layer == 0,
		"The twentieth hit must synchronously disable the collision candidate."
	)
	_expect(
		not shield.try_intercept(Vector2.LEFT),
		"The twenty-first hit must see a transparent broken shield."
	)
	await process_frame
	_expect(
		not shield.monitorable,
		"The broken shield must settle its deferred monitorable state safely."
	)
	_expect(int(event_counts["durability"]) == 20, "Each authoritative block must emit one durability event.")
	_expect(int(event_counts["break"]) == 1, "Only the twentieth hit may emit shield_broken.")

	shield.setup(owner_enemy, 20)
	shield.set_facing_direction(Vector2.LEFT)
	_expect(
		shield.try_intercept(Vector2.RIGHT),
		"A left-facing shield must intercept rightward world travel."
	)
	shield.set_shield_active(false)
	_expect(
		not shield.try_intercept(Vector2.RIGHT) and shield.collision_layer == 0,
		"Lifecycle disable must stop interception without polling."
	)
	shield.set_shield_active(true)
	_expect(
		shield.is_active() and shield.collision_layer == PROJECTILE_SHIELD_LAYER,
		"An unbroken lifecycle-disabled shield may restore its passive layer."
	)
	owner_enemy.free()
	await _dispose_fixture(fixture)


func _test_signal_safe_monitorable_transition() -> void:
	var fixture := _create_fixture("ShieldSignalSafetyFixture")
	var owner_enemy := Enemy.new()
	var shield := await _add_shield(fixture, owner_enemy, Vector2.ZERO)
	var overlap_detector := Area2D.new()
	overlap_detector.collision_layer = 0
	overlap_detector.collision_mask = PROJECTILE_SHIELD_LAYER
	overlap_detector.monitoring = true
	overlap_detector.monitorable = false
	var detector_shape := CollisionShape2D.new()
	var detector_circle := CircleShape2D.new()
	detector_circle.radius = 12.0
	detector_shape.shape = detector_circle
	overlap_detector.add_child(detector_shape)
	var callback_count := [0]
	var disable_on_enter := func(area: Area2D) -> void:
		if area != shield:
			return
		callback_count[0] = int(callback_count[0]) + 1
		shield.set_shield_active(false)
	overlap_detector.area_entered.connect(disable_on_enter)
	fixture.add_child(overlap_detector)
	await physics_frame
	await process_frame
	await physics_frame
	_expect(
		int(callback_count[0]) == 1,
		"A real Area2D overlap must exercise shield disable inside an in/out signal."
	)
	_expect(
		not shield.is_active()
		and shield.collision_layer == 0
		and not shield.monitorable,
		(
			"Signal-triggered shield disable must leave no passive collision or "
			+ "monitorable state after the deferred physics boundary."
		)
	)
	overlap_detector.area_entered.disconnect(disable_on_enter)
	shield.set_shield_active(true)
	shield.set_shield_active(false)
	shield.set_shield_active(true)
	_expect(
		shield.is_active() and shield.collision_layer == PROJECTILE_SHIELD_LAYER,
		"Rapid lifecycle changes must expose only the final collision candidate."
	)
	await process_frame
	await physics_frame
	_expect(
		shield.monitorable,
		"The final deferred monitorable request must win after rapid state changes."
	)
	owner_enemy.free()
	await _dispose_fixture(fixture)


func _test_proxy_visual_consumption_is_read_only() -> void:
	var fixture := _create_fixture("ShieldProxyFixture")
	var owner_enemy := Enemy.new()
	var shield := await _add_shield(fixture, owner_enemy, Vector2.ZERO)
	shield.set_visual_proxy_mode(true)
	_expect(
		shield.try_intercept(Vector2.LEFT),
		"A proxy must consume an active front-side projectile visual."
	)
	_expect(
		shield.get_remaining_durability() == 20,
		"A proxy projectile contact must not author durability."
	)
	shield.apply_proxy_durability_snapshot(13)
	shield.apply_proxy_durability_snapshot(20)
	_expect(
		shield.get_remaining_durability() == 13,
		"An older proxy snapshot must not repair a damaged shield."
	)
	shield.apply_proxy_durability_snapshot(0)
	_expect(
		not shield.is_active() and not shield.try_intercept(Vector2.LEFT),
		"A replicated broken stage must make proxy collisions transparent."
	)
	owner_enemy.free()
	await _dispose_fixture(fixture)


func _test_real_ray_front_and_back_contract() -> void:
	var fixture := _create_fixture("ShieldRayFixture")
	var owner_enemy := Enemy.new()
	var shield := await _add_shield(fixture, owner_enemy, Vector2(20.0, 0.0))
	shield.set_facing_direction(Vector2.LEFT)
	var bullet := BULLET_SCENE.instantiate() as Bullet
	fixture.add_child(bullet)
	bullet.set_physics_process(false)
	bullet.direction = Vector2.RIGHT
	await physics_frame
	_expect(
		bool(bullet.call("_will_hit_world", Vector2.ZERO, Vector2(40.0, 0.0))),
		"The ordinary bullet's existing segment ray must intercept the shield area."
	)
	_expect(
		shield.get_remaining_durability() == 19,
		"The real ordinary-bullet ray must consume exactly one durability."
	)
	shield.set_facing_direction(Vector2.RIGHT)
	_expect(
		not bool(bullet.call("_will_hit_world", Vector2.ZERO, Vector2(40.0, 0.0))),
		"A back-side result must exclude the shield RID and become transparent."
	)
	_expect(
		shield.get_remaining_durability() == 19,
		"The transparent re-sweep must not consume durability."
	)
	shield.setup(owner_enemy, 20)
	shield.set_facing_direction(Vector2.LEFT)
	for _hit_index in range(19):
		shield.try_intercept(Vector2.RIGHT)
	_expect(
		bool(bullet.call("_will_hit_world", Vector2.ZERO, Vector2(40.0, 0.0)))
		and shield.get_remaining_durability() == 0,
		"The real twentieth ray hit must still be fully consumed."
	)
	_expect(
		not bool(bullet.call("_will_hit_world", Vector2.ZERO, Vector2(40.0, 0.0))),
		"A same-frame twenty-first ray must exclude the stale broken shield RID."
	)
	owner_enemy.free()
	await _dispose_fixture(fixture)


func _test_real_projectile_interception_matrix() -> void:
	await _test_arrow_real_ray()
	await _test_tango_real_sweep()
	await _test_tiyi_real_sweep()
	await _test_weishidaier_real_sweep_and_explosion()
	await _test_agave_real_sweep_and_explosion()
	await _test_sakura_friendly_only_ray()


func _test_arrow_real_ray() -> void:
	var fixture := _create_fixture("ShieldArrowFixture")
	var owner_enemy := Enemy.new()
	var shield := await _add_shield(fixture, owner_enemy, Vector2(20.0, 0.0))
	shield.set_facing_direction(Vector2.LEFT)
	var arrow := ARROW_SCENE.instantiate() as CollectibleArrowProjectile
	fixture.add_child(arrow)
	arrow.set_physics_process(false)
	arrow.direction = Vector2.RIGHT
	await physics_frame
	_expect(
		bool(arrow.call("_will_hit_world", Vector2.ZERO, Vector2(40.0, 0.0)))
		and shield.get_remaining_durability() == 19,
		"Collectible arrow must intercept through its real segment ray."
	)
	owner_enemy.free()
	await _dispose_fixture(fixture)


func _test_tango_real_sweep() -> void:
	var fixture := _create_fixture("ShieldTangoFixture")
	var owner_enemy := Enemy.new()
	var shield := await _add_shield(fixture, owner_enemy, Vector2(20.0, 0.0))
	shield.set_facing_direction(Vector2.LEFT)
	var tango := TANGO_SCENE.instantiate() as TangoLaserBullet
	fixture.add_child(tango)
	tango.global_position = Vector2.ZERO
	tango.direction = Vector2.RIGHT
	tango.set_physics_process(false)
	await physics_frame
	tango.call("_sweep_segment", 0.1)
	_expect(
		shield.get_remaining_durability() == 19 and not tango.pool_active,
		"Tango laser must consume itself through its real ShapeCast path."
	)
	owner_enemy.free()
	await _dispose_fixture(fixture)


func _test_tiyi_real_sweep() -> void:
	var fixture := _create_fixture("ShieldTiyiFixture")
	var owner_enemy := Enemy.new()
	var shield := await _add_shield(fixture, owner_enemy, Vector2(20.0, 0.0))
	shield.set_facing_direction(Vector2.LEFT)
	var tiyi := TIYI_SCENE.instantiate() as TiyiSniperBullet
	fixture.add_child(tiyi)
	tiyi.global_position = Vector2.ZERO
	tiyi.direction = Vector2.RIGHT
	tiyi.set_physics_process(false)
	await physics_frame
	tiyi.call("_sweep_segment", 0.05)
	_expect(
		shield.get_remaining_durability() == 19 and tiyi.is_queued_for_deletion(),
		"Tiyi sniper projectile must stop on the real shield ShapeCast hit."
	)
	owner_enemy.free()
	await _dispose_fixture(fixture)


func _test_weishidaier_real_sweep_and_explosion() -> void:
	var fixture := _create_fixture("ShieldWeishidaierFixture")
	var bearer := await _add_real_shield_bearer(
		fixture,
		Vector2(24.0, 0.0),
		true
	)
	_expect(bearer != null, "Weishidaier fixture must instantiate the real shield bearer scene.")
	if bearer == null:
		await _dispose_fixture(fixture)
		return
	var health_before := bearer.current_health
	var bomb := WEISHIDAIER_BOMB_SCENE.instantiate() as WeishidaierSkill1Bomb
	fixture.add_child(bomb)
	bomb.bind_gameplay_context(
		fixture,
		fixture.get_multiplayer_gameplay_gateway()
	)
	bomb.global_position = Vector2.ZERO
	bomb.setup(null, Vector2.RIGHT, 40)
	bomb.set_physics_process(false)
	await physics_frame
	var intercepted := bool(bomb.call("_sweep_projectile_shield", 40.0))
	_expect(
		intercepted and bomb.has_exploded
		and bearer.get_shield_remaining_durability() == 19
		and health_before - bearer.current_health == 15
		and bomb.global_position.x < bearer.global_position.x,
		(
			"Weishidaier bomb must spend exactly one block on the real shield, "
			+ "then preserve its original explosion and deal 15 post-defense damage to the bearer."
		)
	)
	await _dispose_fixture(fixture)


func _test_agave_real_sweep_and_explosion() -> void:
	var fixture := _create_fixture("ShieldAgaveFixture")
	var bearer := await _add_real_shield_bearer(
		fixture,
		Vector2(24.0, 0.0),
		true
	)
	_expect(bearer != null, "Agave fixture must instantiate the real shield bearer scene.")
	if bearer == null:
		await _dispose_fixture(fixture)
		return
	var health_before := bearer.current_health
	var cannonball := AGAVE_CANNONBALL_SCENE.instantiate() as AgaveCannonball
	fixture.add_child(cannonball)
	cannonball.global_position = Vector2.ZERO
	cannonball.setup(Vector2.RIGHT, 40, 180.0, 18.0, 1.25, true, 0)
	cannonball.set_physics_process(false)
	await physics_frame
	cannonball.call("_physics_process", 0.25)
	_expect(
		bearer.get_shield_remaining_durability() == 19
		and cannonball.has_exploded
		and health_before - bearer.current_health == 15
		and cannonball.global_position.x < bearer.global_position.x,
		(
			"Agave cannonball must spend exactly one block on the real shield, "
			+ "then preserve its original explosion and deal 15 post-defense damage to the bearer."
		)
	)
	await _dispose_fixture(fixture)


func _test_sakura_friendly_only_ray() -> void:
	var fixture := _create_fixture("ShieldSakuraFixture")
	var owner_enemy := Enemy.new()
	var shield := await _add_shield(fixture, owner_enemy, Vector2(20.0, 0.0))
	shield.set_facing_direction(Vector2.LEFT)
	var rocket := SAKURA_ROCKET_SCENE.instantiate() as LinglanSkill2SakuraRocket
	fixture.add_child(rocket)
	rocket.global_position = Vector2.ZERO
	rocket.set_physics_process(false)
	rocket.setup(
		Vector2.RIGHT, 40, 210.0, 1.0, 47.0,
		null, 0.0, null, false, EnemyConfig.DamageType.PHYSICAL
	)
	await physics_frame
	rocket.call("_physics_process", 0.2)
	_expect(
		not rocket.has_exploded
		and rocket.global_position.x > 40.0
		and shield.get_remaining_durability() == 20,
		"A non-enemies_only Sakura rocket must bypass the friendly shield layer."
	)
	rocket.global_position = Vector2.ZERO
	rocket.setup(
		Vector2.RIGHT, 40, 210.0, 1.0, 47.0,
		null, 0.0, null, true, EnemyConfig.DamageType.PHYSICAL
	)
	rocket.call("_physics_process", 0.2)
	_expect(
		rocket.has_exploded
		and rocket.global_position.x < 20.0
		and shield.get_remaining_durability() == 19,
		"Only enemies_only Sakura rockets may hit the shield and explode there."
	)
	owner_enemy.free()
	await _dispose_fixture(fixture)


func _test_scene_query_configuration() -> void:
	var fixture := _create_fixture("ShieldSceneContractFixture")
	var bullet := BULLET_SCENE.instantiate() as Bullet
	var arrow := ARROW_SCENE.instantiate() as CollectibleArrowProjectile
	var tango := TANGO_SCENE.instantiate() as TangoLaserBullet
	var tiyi := TIYI_SCENE.instantiate() as TiyiSniperBullet
	var bomb := WEISHIDAIER_BOMB_SCENE.instantiate() as WeishidaierSkill1Bomb
	var cannonball := AGAVE_CANNONBALL_SCENE.instantiate() as AgaveCannonball
	for projectile in [bullet, arrow, tango, tiyi, bomb, cannonball]:
		fixture.add_child(projectile)
		projectile.set_physics_process(false)

	_expect(
		bullet.world_collision_query.collision_mask
			== (Bullet.WORLD_COLLISION_MASK | PROJECTILE_SHIELD_LAYER)
		and bullet.world_collision_query.collide_with_areas,
		"Ordinary Bullet must reuse one World|ProjectileShield area-aware ray."
	)
	_expect(
		arrow.world_collision_query.collision_mask
			== (CollectibleArrowProjectile.WORLD_COLLISION_MASK | PROJECTILE_SHIELD_LAYER)
		and arrow.world_collision_query.collide_with_areas,
		"Collectible arrow must reuse one World|ProjectileShield area-aware ray."
	)
	for cast in [tango.sweep_cast, tiyi.sweep_cast, cannonball.flight_cast]:
		_expect(
			(cast.collision_mask & PROJECTILE_SHIELD_LAYER) != 0
			and cast.collide_with_areas,
			"Existing high-speed ShapeCast must include passive shield areas."
		)
	_expect(
		bomb.shield_sweep != null
		and bomb.shield_sweep.collision_mask == PROJECTILE_SHIELD_LAYER
		and bomb.shield_sweep.collide_with_areas
		and not bomb.shield_sweep.collide_with_bodies,
		"Weishidaier bomb must own one preauthored shield-only sweep."
	)
	await _dispose_fixture(fixture)


func _test_source_matrix_contract() -> void:
	_expect(
		ProjectSettings.get_setting("layer_names/2d_physics/layer_13", "")
			== "ProjectileShield",
		"Physics layer 13 must be named ProjectileShield."
	)
	var shield_source := FileAccess.get_file_as_string(
		"res://scene/enemy/projectile_shield_area.gd"
	)
	_expect(
		not shield_source.contains("func _process(")
		and not shield_source.contains("func _physics_process("),
		"The passive shield must not add frame callbacks."
	)
	_expect(
		not shield_source.contains("multiplayer.is_server()"),
		(
			"Shield authority must not use Godot server identity because a Relay "
			+ "game Host is also an ENet client."
		)
	)
	_expect(
		shield_source.contains("set_deferred(&\"monitorable\", enabled)")
		and not shield_source.contains("\n\tmonitorable = enabled"),
		(
			"Shield monitorability must be deferred because lifecycle changes can "
			+ "run inside Area2D in/out signals."
		)
	)
	var rocket_source := FileAccess.get_file_as_string(
		"res://scene/boss/linglan/linglan_skill2_sakura_rocket.gd"
	)
	_expect(
		rocket_source.contains("ENEMY_ONLY_HIT_COLLISION_MASK")
		and rocket_source.contains("| PROJECTILE_SHIELD_COLLISION_MASK")
		and rocket_source.contains("if not enemies_only or hit_result.is_empty()"),
		"Only enemies_only Sakura rockets may enter the shield interception path."
	)
	var bomb_scene_source := FileAccess.get_file_as_string(
		"res://scene/player/weishidaier/weishidaier_skill1_bomb.tscn"
	)
	_expect(
		bomb_scene_source.contains("[node name=\"ShieldSweep\" type=\"ShapeCast2D\"")
		and bomb_scene_source.contains("collision_mask = 4096"),
		"The bomb's anti-tunneling shield sweep must be authored in its scene."
	)


func _add_shield(
	parent: Node2D,
	owner_enemy: Enemy,
	position: Vector2
) -> ProjectileShieldArea:
	var shield := ProjectileShieldArea.new()
	shield.position = position
	var collision_shape := CollisionShape2D.new()
	var rectangle := RectangleShape2D.new()
	rectangle.size = Vector2(2.0, 18.0)
	collision_shape.shape = rectangle
	shield.add_child(collision_shape)
	parent.add_child(shield)
	shield.setup(owner_enemy, 20)
	await physics_frame
	return shield


func _add_real_shield_bearer(
	parent: Node2D,
	position: Vector2,
	facing_left: bool
) -> CombatRobotShieldBearer:
	var bearer := SHIELD_BEARER_SCENE.instantiate() as CombatRobotShieldBearer
	if bearer == null:
		return null
	parent.add_child(bearer)
	bearer.global_position = position
	bearer.setup(SHIELD_BEARER_CONFIG, null, null)
	bearer.set_process(false)
	bearer.set_physics_process(false)
	bearer.call("_set_facing_left", facing_left)
	await physics_frame
	await physics_frame
	return bearer


func _create_fixture(fixture_name: String) -> PlayerTestCombatRuntime:
	var fixture := PLAYER_TEST_RUNTIME.new() as PlayerTestCombatRuntime
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
		print("PROJECTILE_SHIELD_MATRIX_SMOKE_TEST_OK")
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	quit(1)


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
