extends SceneTree

const BULLET_SCENE := preload("res://scene/bullet.tscn")
const AK_BULLET_SCENE := preload("res://scene/enemy/capoo/capoo_ak47_bullet.tscn")
const SMG_BULLET_SCENE := preload("res://scene/enemy/capoo/capoo_smg_bullet.tscn")
const RPG_ROCKET_SCENE := preload("res://scene/enemy/capoo/capoo_rpg_rocket.tscn")
const MAGE_FIREBALL_SCENE := preload("res://scene/enemy/capoo/capoo_mage_fireball.tscn")
const FIRE_SORCERER_FIREBALL_VOLLEY_SCENE := preload(
	"res://scene/enemy/sorcerer/fire_sorcerer_fireball_volley.tscn"
)
const FIRE_SORCERER_ELITE_FIREBALL_VOLLEY_SCENE := preload(
	"res://scene/enemy/sorcerer/fire_sorcerer_elite_fireball_volley.tscn"
)
const FROST_SORCERER_ICE_SPIKE_SCENE := preload(
	"res://scene/enemy/sorcerer/frost_sorcerer_ice_spike.tscn"
)
const YUANSHI_FIRE_PROJECTILE_SCENE := preload("res://scene/enemy/yuanshi_insect/yuanshi_insect_fire_projectile.tscn")
const AGAVE_CANNONBALL_SCENE := preload("res://scene/plant_defense/agave_cannonball.tscn")
const COLLECTIBLE_ARROW_SCENE := preload("res://scene/collectible_arrow_projectile.tscn")
const LINGLAN_SKILL1_BULLET_SCENE := preload(
	"res://scene/boss/linglan/linglan_skill1_sakura_bullet.tscn"
)
const LINGLAN_SAKURA_HIT_EFFECT_SCENE := preload(
	"res://scene/boss/linglan/linglan_sakura_hit_effect.tscn"
)
const COLLECTIBLE_SAKURA_ROCKET_SCENE := preload(
	"res://scene/collectible_sakura_rocket.tscn"
)
const COLLECTIBLE_SAKURA_EXPLOSION_SCENE := preload(
	"res://scene/collectible_sakura_explosion.tscn"
)
const BULLET_HIT_EFFECT_SCENE := preload("res://scene/bullet_hit_effect.tscn")
const ENEMY_HIT_EFFECT_SCENE := preload("res://scene/enemy/enemy_hit_effect.tscn")

var failures: Array[String] = []
var fixture: Node2D = null
var pool: SessionObjectPool = null


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	fixture = Node2D.new()
	fixture.name = "ProjectilePoolSmokeFixture"
	root.add_child(fixture)
	current_scene = fixture
	pool = SessionObjectPool.new()
	pool.name = "SessionObjectPool"
	fixture.add_child(pool)

	pool.register_scene(BULLET_SCENE, 1, 2)
	pool.register_scene(AK_BULLET_SCENE, 1, 2)
	pool.register_scene(SMG_BULLET_SCENE, 1, 2)
	pool.register_scene(RPG_ROCKET_SCENE, 1, 2)
	pool.register_scene(MAGE_FIREBALL_SCENE, 1, 2)
	pool.register_scene(FIRE_SORCERER_FIREBALL_VOLLEY_SCENE, 1, 2)
	pool.register_scene(
		FIRE_SORCERER_ELITE_FIREBALL_VOLLEY_SCENE,
		1,
		2
	)
	pool.register_scene(FROST_SORCERER_ICE_SPIKE_SCENE, 1, 2)
	pool.register_scene(YUANSHI_FIRE_PROJECTILE_SCENE, 1, 2)
	pool.register_scene(AGAVE_CANNONBALL_SCENE, 1, 2)
	pool.register_scene(COLLECTIBLE_ARROW_SCENE, 1, 2)
	pool.register_scene(LINGLAN_SKILL1_BULLET_SCENE, 1, 2)
	pool.register_scene(COLLECTIBLE_SAKURA_ROCKET_SCENE, 1, 2)
	pool.register_scene(LINGLAN_SAKURA_HIT_EFFECT_SCENE, 1, 2)
	pool.register_scene(BULLET_HIT_EFFECT_SCENE, 2, 2)
	pool.register_scene(ENEMY_HIT_EFFECT_SCENE, 2, 2)

	_verify_world_collision_query_reuse()
	await _verify_real_reused_query_semantics()
	await _verify_player_bullet_reuse()
	await _verify_real_collision_callback_release()
	await _verify_capoo_bullet_reuse()
	await _verify_linglan_skill1_reuse()
	await _verify_extended_projectile_reuse()
	await _verify_strict_hit_effect_budget()
	await _finish()


func _verify_world_collision_query_reuse() -> void:
	var projectile_scenes: Array[PackedScene] = [RPG_ROCKET_SCENE, MAGE_FIREBALL_SCENE]
	for projectile_scene in projectile_scenes:
		var projectile: Node = projectile_scene.instantiate()
		fixture.add_child(projectile)
		var query := projectile.get("world_collision_query") as PhysicsRayQueryParameters2D
		var exclude: Array = projectile.get("world_collision_exclude") as Array
		_expect(query != null, "%s must retain one world ray query." % projectile_scene.resource_path)
		_expect(
			exclude.size() == 1 and exclude[0] == projectile.get_rid(),
			"%s must retain one reusable self-exclusion RID." % projectile_scene.resource_path
		)
		if query != null:
			var from_position := Vector2(3.0, 5.0)
			var to_position := Vector2(13.0, 17.0)
			projectile.call("_get_world_hit", from_position, to_position)
			_expect(
				query.from == from_position and query.to == to_position,
				"%s world cast must update the retained query." % projectile_scene.resource_path
			)
			_expect(
				is_same(query, projectile.get("world_collision_query"))
				and is_same(exclude, projectile.get("world_collision_exclude")),
				"%s world casts must not replace their query or exclusion array."
				% projectile_scene.resource_path
			)
		projectile.free()

	var simple_ray_scenes: Array[PackedScene] = [
		COLLECTIBLE_ARROW_SCENE,
		LINGLAN_SKILL1_BULLET_SCENE,
	]
	for projectile_scene in simple_ray_scenes:
		var projectile := projectile_scene.instantiate() as Area2D
		fixture.add_child(projectile)
		var query := projectile.get("world_collision_query") as PhysicsRayQueryParameters2D
		var exclude := projectile.get("world_collision_exclude") as Array
		var from_position := Vector2(2.0, 4.0)
		var to_position := Vector2(12.0, 14.0)
		projectile.call("_will_hit_world", from_position, to_position)
		_expect(
			query != null
			and query.from == from_position
			and query.to == to_position
			and exclude.size() == 1
			and exclude[0] == projectile.get_rid(),
			"%s must update one retained self-excluding world ray query."
			% projectile_scene.resource_path
		)
		projectile.free()

	var skill2_rocket := COLLECTIBLE_SAKURA_ROCKET_SCENE.instantiate() as LinglanSkill2SakuraRocket
	fixture.add_child(skill2_rocket)
	var skill2_query := skill2_rocket.hit_collision_query
	var skill2_exclude := skill2_rocket.hit_collision_exclude
	skill2_rocket.call("_get_hit", Vector2(7.0, 9.0), Vector2(17.0, 19.0))
	_expect(
		skill2_query.from == Vector2(7.0, 9.0)
		and skill2_query.to == Vector2(17.0, 19.0)
		and skill2_exclude.size() == 1
		and skill2_exclude[0] == skill2_rocket.get_rid(),
		"Linglan Skill2 rockets must update one retained self-excluding hit query."
	)
	skill2_rocket.free()


func _verify_real_reused_query_semantics() -> void:
	var wall := StaticBody2D.new()
	wall.collision_layer = LinglanSakuraBullet.WORLD_COLLISION_MASK
	wall.collision_mask = 0
	var wall_collision := CollisionShape2D.new()
	var wall_shape := RectangleShape2D.new()
	wall_shape.size = Vector2(18.0, 18.0)
	wall_collision.shape = wall_shape
	wall.add_child(wall_collision)
	fixture.add_child(wall)

	var first_wall_position := Vector2(640.0, 160.0)
	var second_wall_position := Vector2(640.0, 256.0)
	wall.global_position = first_wall_position
	await physics_frame

	var ray_bullet := pool.acquire(LINGLAN_SKILL1_BULLET_SCENE) as LinglanSakuraBullet
	_expect(ray_bullet != null, "Real ray-query fixture must acquire a pooled Sakura bullet.")
	if ray_bullet != null:
		var ray_instance_id := ray_bullet.get_instance_id()
		var retained_ray_query := ray_bullet.world_collision_query
		var first_from := first_wall_position - Vector2(48.0, 0.0)
		var first_to := first_wall_position + Vector2(48.0, 0.0)
		_expect(
			ray_bullet.call("_will_hit_world", first_from, first_to),
			"A pooled ray query must hit a world body at its first lease position."
		)
		_expect(
			retained_ray_query.from == first_from
			and retained_ray_query.to == first_to
			and retained_ray_query.collision_mask == LinglanSakuraBullet.WORLD_COLLISION_MASK,
			"The first ray lease must apply the current segment and world-only collision mask."
		)
		_expect(pool.release(ray_bullet), "The first real ray-query lease must release.")
		await _wait_for_quarantine()

		wall.global_position = second_wall_position
		await physics_frame
		var reused_ray_bullet := pool.acquire(
			LINGLAN_SKILL1_BULLET_SCENE
		) as LinglanSakuraBullet
		_expect(
			reused_ray_bullet != null
			and reused_ray_bullet.get_instance_id() == ray_instance_id
			and is_same(reused_ray_bullet.world_collision_query, retained_ray_query),
			"The second ray lease must reuse the same bullet and query object."
		)
		if reused_ray_bullet != null:
			_expect(
				not reused_ray_bullet.call("_will_hit_world", first_from, first_to),
				"A reused ray query must not retain a hit at the first lease position."
			)
			var second_from := second_wall_position - Vector2(48.0, 0.0)
			var second_to := second_wall_position + Vector2(48.0, 0.0)
			_expect(
				reused_ray_bullet.call("_will_hit_world", second_from, second_to),
				"A reused ray query must hit the world body at its second lease position."
			)
			_expect(
				retained_ray_query.from == second_from
				and retained_ray_query.to == second_to
				and retained_ray_query.exclude.size() == 1
				and retained_ray_query.exclude[0] == reused_ray_bullet.get_rid(),
				"The reused ray query must overwrite its segment while retaining only self-exclusion."
			)
			_expect(pool.release(reused_ray_bullet), "The second real ray-query lease must release.")
			await _wait_for_quarantine()

	var target := PlantDefense.new()
	target.name = "ExplosionDamageProbePlant"
	target.collision_layer = CapooRPGRocket.DAMAGEABLE_COLLISION_MASK & 512
	target.collision_mask = 0
	target.max_health = 200
	target.current_health = target.max_health
	target.physical_defense = 0
	target.magic_defense = 0
	var target_collision := CollisionShape2D.new()
	var target_shape := RectangleShape2D.new()
	target_shape.size = Vector2(16.0, 16.0)
	target_collision.shape = target_shape
	target.add_child(target_collision)
	fixture.add_child(target)

	var first_explosion_position := Vector2(800.0, 160.0)
	var second_explosion_position := Vector2(800.0, 256.0)
	target.global_position = first_explosion_position
	await physics_frame

	var rocket := pool.acquire(RPG_ROCKET_SCENE) as CapooRPGRocket
	_expect(rocket != null, "Real explosion-query fixture must acquire a pooled RPG rocket.")
	if rocket != null:
		var rocket_instance_id := rocket.get_instance_id()
		var retained_explosion_query := rocket.explosion_query
		rocket.global_position = first_explosion_position
		rocket.setup(Vector2.RIGHT, 17, 0.0, 1.0, 32.0)
		var health_before_first_hit := target.current_health
		rocket.call("_apply_explosion_damage", target)
		_expect(
			target.current_health == health_before_first_hit - 17,
			"Direct-hit plus overlap results must damage a target exactly once per explosion."
		)
		_expect(
			rocket.explosion_damaged_bodies.size() == 1
			and rocket.explosion_damaged_bodies.has(target.get_instance_id()),
			"The first explosion lease must de-duplicate its direct and overlap hit."
		)
		_expect(
			retained_explosion_query.transform.origin == first_explosion_position
			and retained_explosion_query.collision_mask == CapooRPGRocket.DAMAGEABLE_COLLISION_MASK,
			"The first explosion lease must apply its current transform and damageable mask."
		)
		_expect(pool.release(rocket), "The first real explosion-query lease must release.")
		await _wait_for_quarantine()

		target.global_position = second_explosion_position
		await physics_frame
		var reused_rocket := pool.acquire(RPG_ROCKET_SCENE) as CapooRPGRocket
		_expect(
			reused_rocket != null
			and reused_rocket.get_instance_id() == rocket_instance_id
			and is_same(reused_rocket.explosion_query, retained_explosion_query),
			"The second explosion lease must reuse the same rocket and shape query."
		)
		if reused_rocket != null:
			_expect(
				reused_rocket.explosion_damaged_bodies.is_empty(),
				"The second explosion lease must begin without stale hit de-dup entries."
			)
			reused_rocket.global_position = second_explosion_position
			reused_rocket.setup(Vector2.RIGHT, 17, 0.0, 1.0, 32.0)
			var health_before_second_hit := target.current_health
			reused_rocket.call("_apply_explosion_damage")
			_expect(
				target.current_health == health_before_second_hit - 17,
				"A reused explosion query must find and damage the target at its new position once."
			)
			_expect(
				retained_explosion_query.transform.origin == second_explosion_position
				and retained_explosion_query.collision_mask == CapooRPGRocket.DAMAGEABLE_COLLISION_MASK
				and reused_rocket.explosion_damaged_bodies.size() == 1
				and reused_rocket.explosion_damaged_bodies.has(target.get_instance_id()),
				"The reused explosion query must overwrite its transform, keep its mask, and rebuild de-dup state."
			)
			_expect(pool.release(reused_rocket), "The second real explosion-query lease must release.")
			await _wait_for_quarantine()

	wall.queue_free()
	target.queue_free()
	await physics_frame


func _verify_player_bullet_reuse() -> void:
	var bullet := pool.acquire(BULLET_SCENE) as Bullet
	_expect(bullet != null, "Player bullet pool must acquire its prewarmed instance.")
	if bullet == null:
		return
	var first_id := bullet.get_instance_id()
	var finished_ids: Array[int] = []
	bullet.projectile_finished.connect(
		func(projectile_id: int, projectile: Node) -> void:
			if projectile == bullet:
				finished_ids.append(projectile_id)
	)
	bullet.speed = 999.0
	bullet.max_lifetime = 9.0
	bullet.remaining_lifetime = 7.0
	bullet.setup(Vector2.DOWN, 77, true)
	bullet.setup_multiplayer(41, 8, &"contaminated")
	bullet.hit_enemy_instance_ids[123] = true
	var fake_owner := Player.new()
	bullet.collectible_owner = fake_owner
	bullet.is_homing = true
	bullet.modulate = Color.RED
	bullet.collision_layer = 0
	bullet.collision_mask = 0
	bullet.retire()
	fake_owner.free()
	_expect(finished_ids == [41], "Retiring a pooled bullet must emit its current network id once.")
	await _wait_for_quarantine()
	_expect(not bullet.monitoring and not bullet.monitorable, "Inactive bullets must leave Area2D monitoring.")

	var reused := pool.acquire(BULLET_SCENE) as Bullet
	_expect(reused != null and reused.get_instance_id() == first_id, "Player bullet must reuse the retained instance.")
	if reused == null:
		return
	_expect(reused.pool_active, "Reacquired player bullet must be active.")
	_expect(
		reused.speed == 320.0 and reused.max_lifetime == 1.083,
		"Player bullet authored view-bounded timing must reset."
	)
	_expect(reused.remaining_lifetime == reused.max_lifetime, "Player bullet lifetime must reset.")
	_expect(reused.direction == Vector2.RIGHT and reused.damage == 1, "Player bullet direction and damage must reset.")
	_expect(not reused.pierces_enemies and not reused.is_homing, "Player bullet modifiers must reset.")
	_expect(reused.hit_enemy_instance_ids.is_empty(), "Player bullet hit de-dup state must reset.")
	_expect(reused.collectible_owner == null and reused.homing_target == null, "Player bullet references must reset.")
	_expect(reused.projectile_id == 0 and reused.owner_peer_id == 0, "Player bullet network identity must reset.")
	_expect(reused.modulate == Color.WHITE and reused.rotation == 0.0, "Player bullet visual state must reset.")
	_expect(reused.collision_layer == 16 and reused.collision_mask == 4, "Player bullet collision profile must reset.")
	_expect(reused.monitoring and reused.monitorable, "Reacquired player bullet must restore Area2D monitoring.")
	reused.setup_multiplayer(42, 9, &"player_bullet")
	reused.retire()
	_expect(finished_ids == [41, 42], "A reused bullet must not accumulate duplicate lifecycle callbacks.")
	await _wait_for_quarantine()


func _verify_real_collision_callback_release() -> void:
	var collision_pool := SessionObjectPool.new()
	collision_pool.name = "PhysicsCallbackPool"
	fixture.add_child(collision_pool)
	collision_pool.register_scene(BULLET_SCENE, 1, 1)
	var bullet := collision_pool.acquire(BULLET_SCENE) as Bullet
	_expect(bullet != null, "Physics callback fixture must acquire a pooled Area2D bullet.")
	if bullet == null:
		collision_pool.queue_free()
		await process_frame
		return

	var target_body := StaticBody2D.new()
	target_body.collision_layer = 4
	target_body.collision_mask = 0
	var target_shape := CollisionShape2D.new()
	var target_rectangle := RectangleShape2D.new()
	target_rectangle.size = Vector2(16.0, 16.0)
	target_shape.shape = target_rectangle
	target_body.add_child(target_shape)
	fixture.add_child(target_body)
	var overlap_position := Vector2(320.0, 240.0)
	target_body.global_position = overlap_position
	bullet.global_position = overlap_position
	bullet.speed = 0.0
	bullet.remaining_lifetime = 10.0
	bullet.setup_multiplayer(901, 1, &"physics_callback_probe")
	var finished_ids: Array[int] = []
	bullet.projectile_finished.connect(
		func(projectile_id: int, projectile: Node) -> void:
			if projectile == bullet:
				finished_ids.append(projectile_id)
	)
	for _physics_frame in range(3):
		await physics_frame
		if not bool(bullet.get_meta(SessionObjectPool.POOL_ACTIVE_META, false)):
			break
	_expect(finished_ids == [901], "A real body_entered callback must consume its lease exactly once.")
	_expect(
		not bool(bullet.get_meta(SessionObjectPool.POOL_ACTIVE_META, true)),
		"The collision callback must synchronously invalidate the pool lease."
	)
	await process_frame
	_expect(
		bullet.process_mode == Node.PROCESS_MODE_DISABLED,
		"The collision callback's deferred process-mode shutdown must commit safely."
	)
	await _wait_for_quarantine()
	var reused := collision_pool.acquire(BULLET_SCENE) as Bullet
	_expect(
		reused == bullet and reused.monitoring and reused.monitorable,
		"A collision-released bullet must remain reusable with monitoring restored."
	)
	if reused != null:
		collision_pool.release(reused)
	target_body.queue_free()
	collision_pool.queue_free()
	await process_frame


func _verify_capoo_bullet_reuse() -> void:
	var ak := pool.acquire(AK_BULLET_SCENE) as CapooAK47Bullet
	var smg := pool.acquire(SMG_BULLET_SCENE) as CapooAK47Bullet
	_expect(ak != null and smg != null and ak != smg, "AK and SMG must use separate scene buckets.")
	if ak == null or smg == null:
		return
	var ak_id := ak.get_instance_id()
	ak.setup(Vector2.LEFT, 33, 555.0, 8.0)
	ak.setup_multiplayer(71, 3, &"capoo_ak47_bullet")
	ak.has_hit = true
	ak.rotation = 2.0
	ak.collision_layer = 0
	ak.collision_mask = 0
	ak.animated_sprite.frame = 1
	pool.release(ak)
	smg.retire(false)
	await _wait_for_quarantine()
	var reused_ak := pool.acquire(AK_BULLET_SCENE) as CapooAK47Bullet
	_expect(reused_ak != null and reused_ak.get_instance_id() == ak_id, "AK bullet must reuse its retained instance.")
	if reused_ak == null:
		return
	_expect(reused_ak.pool_active and not reused_ak.has_hit, "Reused AK bullet must clear consumed state.")
	_expect(reused_ak.speed == 142.5 and reused_ak.max_lifetime == 2.0, "AK authored timing must reset.")
	_expect(reused_ak.direction == Vector2.RIGHT and reused_ak.damage == 1, "AK direction and damage must reset.")
	_expect(reused_ak.projectile_id == 0 and reused_ak.owner_peer_id == 0, "AK network identity must reset.")
	_expect(reused_ak.rotation == 0.0, "AK rotation must reset.")
	_expect(
		reused_ak.collision_layer == 128
		and reused_ak.collision_mask == CapooAK47Bullet.DAMAGEABLE_COLLISION_MASK,
		"AK collision profile must reset for Player and PlantDefense targets."
	)
	_expect(
		reused_ak.animated_sprite.frame == 0
		and reused_ak.animated_sprite.frame_progress == 0.0,
		"AK animation must restart from its first frame."
	)
	reused_ak.remaining_lifetime = 0.0
	reused_ak.call("_physics_process", 0.016)
	_expect(not reused_ak.pool_active, "Natural AK expiry must return to the pool.")
	_expect(_count_active_hit_effects() == 0, "Natural projectile expiry must not spawn a hit effect.")
	await _wait_for_quarantine()


func _verify_linglan_skill1_reuse() -> void:
	var bullet := pool.acquire(LINGLAN_SKILL1_BULLET_SCENE) as LinglanSakuraBullet
	_expect(bullet != null, "Linglan Skill1 bullet pool must provide its prewarmed lease.")
	if bullet == null:
		return
	var first_instance_id := bullet.get_instance_id()
	var retained_query := bullet.world_collision_query
	var retained_exclude := bullet.world_collision_exclude
	var finished_ids: Array[int] = []
	bullet.projectile_finished.connect(
		func(projectile_id: int, projectile: Node) -> void:
			if projectile == bullet:
				finished_ids.append(projectile_id)
	)
	bullet.setup(Vector2.DOWN, 91, 777.0, 8.0)
	bullet.setup_multiplayer(1701, 17, &"contaminated")
	bullet.modulate = Color.RED
	bullet.self_modulate = Color.BLUE
	bullet.collision_layer = 0
	bullet.collision_mask = 0
	bullet.animated_sprite.hide()
	bullet.animated_sprite.frame = 1
	bullet.retire()
	_expect(
		finished_ids == [1701],
		"Linglan Skill1 retirement must publish its current network identity once."
	)
	await _wait_for_quarantine()

	var reused := pool.acquire(LINGLAN_SKILL1_BULLET_SCENE) as LinglanSakuraBullet
	_expect(
		reused != null and reused.get_instance_id() == first_instance_id,
		"Linglan Skill1 bullets must reuse the retained Area2D instance."
	)
	if reused == null:
		return
	_expect(reused.pool_active and not reused.has_hit, "Reused Sakura bullets must clear consumed state.")
	_expect(
		reused.direction == Vector2.RIGHT
		and reused.damage == 50
		and is_equal_approx(reused.speed, 300.0)
		and is_equal_approx(reused.max_lifetime, 2.0)
		and is_equal_approx(reused.remaining_lifetime, 2.0),
		"Reused Sakura bullets must restore authored direction, damage, speed, and lifetime."
	)
	_expect(
		reused.projectile_id == 0
		and reused.owner_peer_id == 0
		and reused.source_type == &"linglan_skill1",
		"Reused Sakura bullets must clear multiplayer lease identity."
	)
	_expect(
		reused.position == Vector2.ZERO
		and is_zero_approx(reused.rotation)
		and reused.modulate == Color.WHITE
		and reused.self_modulate == Color.WHITE,
		"Reused Sakura bullets must reset transform and tint state."
	)
	_expect(
		reused.collision_layer == 128
		and reused.collision_mask == 3
		and reused.monitoring
		and reused.monitorable,
		"Reused Sakura bullets must restore their complete collision profile."
	)
	_expect(
		is_same(retained_query, reused.world_collision_query)
		and is_same(retained_exclude, reused.world_collision_exclude)
		and retained_exclude.size() == 1
		and retained_exclude[0] == reused.get_rid(),
		"Sakura bullet reuse must retain one self-excluding world query."
	)
	_expect(
		reused.animated_sprite.visible
		and reused.animated_sprite.frame == 0
		and reused.animated_sprite.is_playing(),
		"Sakura bullet reuse must restart its visible flight animation from frame zero."
	)
	reused.setup_multiplayer(1702, 18, &"linglan_skill1")
	reused.retire()
	_expect(
		finished_ids == [1701, 1702],
		"A reused Sakura bullet must not accumulate duplicate lifecycle callbacks."
	)
	await _wait_for_quarantine()

	var effect := pool.acquire(LINGLAN_SAKURA_HIT_EFFECT_SCENE) as LinglanSakuraHitEffect
	_expect(effect != null and effect.pool_active, "Linglan hit particles must use an elastic pooled lease.")
	if effect == null:
		return
	var effect_id := effect.get_instance_id()
	effect.setup(Vector2.UP)
	_expect(effect.emitting, "Pooled Linglan hit particles must emit after setup.")
	effect.call("_on_finished")
	await _wait_for_quarantine()
	var reused_effect := pool.acquire(
		LINGLAN_SAKURA_HIT_EFFECT_SCENE
	) as LinglanSakuraHitEffect
	_expect(
		reused_effect != null
		and reused_effect.get_instance_id() == effect_id
		and reused_effect.pool_active
		and not reused_effect.emitting
		and is_zero_approx(reused_effect.rotation),
		"Linglan hit particles must reset emission and orientation between leases."
	)
	if reused_effect != null:
		reused_effect.call("_on_finished")
	await _wait_for_quarantine()


func _verify_extended_projectile_reuse() -> void:
	var scenes: Array[PackedScene] = [
		RPG_ROCKET_SCENE,
		MAGE_FIREBALL_SCENE,
		FIRE_SORCERER_FIREBALL_VOLLEY_SCENE,
		FIRE_SORCERER_ELITE_FIREBALL_VOLLEY_SCENE,
		FROST_SORCERER_ICE_SPIKE_SCENE,
		YUANSHI_FIRE_PROJECTILE_SCENE,
		AGAVE_CANNONBALL_SCENE,
		COLLECTIBLE_ARROW_SCENE,
		LINGLAN_SKILL1_BULLET_SCENE,
		COLLECTIBLE_SAKURA_ROCKET_SCENE,
	]
	for projectile_scene in scenes:
		var retained_explosion_query: PhysicsShapeQueryParameters2D = null
		var retained_explosion_targets: Dictionary = {}
		var retained_motion_sweep: RefCounted = null
		var retained_motion_query: PhysicsShapeQueryParameters2D = null
		var projectile := pool.acquire(projectile_scene)
		_expect(projectile != null, "%s must be acquirable from the elastic pool." % projectile_scene.resource_path)
		if projectile == null:
			continue
		var first_instance_id := projectile.get_instance_id()
		if projectile.has_method("setup_multiplayer"):
			projectile.call("setup_multiplayer", 701, 9, &"contaminated")
		projectile.set("direction", Vector2.DOWN)
		projectile.set("damage", 99)
		projectile.set("remaining_lifetime", 0.125)
		if projectile_scene in [RPG_ROCKET_SCENE, MAGE_FIREBALL_SCENE, AGAVE_CANNONBALL_SCENE, COLLECTIBLE_SAKURA_ROCKET_SCENE]:
			retained_explosion_query = projectile.get("explosion_query") as PhysicsShapeQueryParameters2D
			var target_property := (
				"explosion_targets"
				if projectile_scene == AGAVE_CANNONBALL_SCENE
				else "explosion_damaged_ids"
				if projectile_scene == COLLECTIBLE_SAKURA_ROCKET_SCENE
				else "explosion_damaged_bodies"
			)
			retained_explosion_targets = projectile.get(target_property) as Dictionary
			retained_explosion_targets[999] = null
		if projectile_scene == AGAVE_CANNONBALL_SCENE:
			projectile.set("authoritative_damage", false)
		if projectile_scene == COLLECTIBLE_SAKURA_ROCKET_SCENE:
			projectile.set("speed", 13.0)
			projectile.set("max_lifetime", 0.25)
			projectile.set("explosion_radius", 9.0)
			projectile.set("homing_turn_rate", 0.2)
		if projectile_scene in [
			FIRE_SORCERER_FIREBALL_VOLLEY_SCENE,
			FIRE_SORCERER_ELITE_FIREBALL_VOLLEY_SCENE,
		]:
			var dirty_volley := projectile as FireSorcererFireballVolley
			retained_motion_sweep = dirty_volley.motion_sweep
			retained_motion_query = dirty_volley.motion_sweep.query
			retained_motion_query.motion = Vector2(90.0, 90.0)
			dirty_volley.speed = 13.0
			dirty_volley.burn_duration = 0.25
			dirty_volley.burn_level = 99
			dirty_volley.active_ball_mask = 0
			dirty_volley.visible_effect_mask = (
				FireSorcererFireballVolley.ALL_BALLS_ACTIVE_MASK
			)
			dirty_volley.target_runtime = fixture
			dirty_volley.target_refresh_left = 9.0
			for ball_index in range(
				FireSorcererFireballVolley.BALL_COUNT
			):
				dirty_volley.ball_directions[ball_index] = Vector2.DOWN
				dirty_volley.ball_effect_times[ball_index] = 9.0
				dirty_volley.ball_areas[ball_index].position = Vector2(
					90.0 + ball_index,
					90.0
				)
				dirty_volley.ball_areas[ball_index].collision_layer = 0
				dirty_volley.ball_areas[ball_index].collision_mask = 0
				dirty_volley.ball_sprites[ball_index].hide()
		if projectile_scene == FROST_SORCERER_ICE_SPIKE_SCENE:
			var dirty_spike := projectile as FrostSorcererIceSpike
			retained_motion_sweep = dirty_spike.motion_sweep
			retained_motion_query = dirty_spike.motion_sweep.query
			retained_motion_query.motion = Vector2(91.0, 17.0)
			dirty_spike.setup(Vector2.UP, 17, 225.0, 0.75)
			dirty_spike.setup_multiplayer(
				702,
				10,
				&"contaminated_frost_spike"
			)
			_expect(
				dirty_spike.direction == Vector2.UP
				and dirty_spike.damage == 17
				and is_equal_approx(dirty_spike.speed, 225.0)
				and is_equal_approx(dirty_spike.max_lifetime, 0.75)
				and is_equal_approx(dirty_spike.remaining_lifetime, 0.75)
				and dirty_spike.projectile_id == 702
				and dirty_spike.owner_peer_id == 10,
				"Frost Sorcerer ice-spike setup must apply one straight-flight lease."
			)
			dirty_spike.has_hit = true
			dirty_spike.effect_time_left = 9.0
			dirty_spike.multiplayer_contact_consumed = true
			dirty_spike.motion_sweep_query_count = 99
		if projectile is Area2D:
			(projectile as Area2D).collision_layer = 0
			(projectile as Area2D).collision_mask = 0
		_expect(pool.release(projectile), "%s active lease must release." % projectile_scene.resource_path)
		await _wait_for_quarantine()

		var reused := pool.acquire(projectile_scene)
		_expect(
			reused != null and reused.get_instance_id() == first_instance_id,
			"%s must reuse its retained instance." % projectile_scene.resource_path
		)
		if reused == null:
			continue
		_expect(bool(reused.get("pool_active")), "%s must reactivate its gameplay lease." % projectile_scene.resource_path)
		_expect(
			int(reused.get("projectile_id")) == 0 and int(reused.get("owner_peer_id")) == 0,
			"%s must clear network identity." % projectile_scene.resource_path
		)
		_expect(
			reused.get("direction") == Vector2.RIGHT and int(reused.get("damage")) > 0,
			"%s must restore direction and authored damage defaults." % projectile_scene.resource_path
		)
		_expect(
			float(reused.get("remaining_lifetime")) > 0.0,
			"%s must restore a positive lifetime." % projectile_scene.resource_path
		)
		if retained_explosion_query != null:
			var target_property := (
				"explosion_targets"
				if projectile_scene == AGAVE_CANNONBALL_SCENE
				else "explosion_damaged_ids"
				if projectile_scene == COLLECTIBLE_SAKURA_ROCKET_SCENE
				else "explosion_damaged_bodies"
			)
			_expect(
				is_same(retained_explosion_query, reused.get("explosion_query"))
				and is_same(retained_explosion_targets, reused.get(target_property))
				and retained_explosion_targets.is_empty(),
				"%s must retain explosion query containers while clearing lease de-dup state."
				% projectile_scene.resource_path
			)
		if projectile_scene == AGAVE_CANNONBALL_SCENE:
			_expect(
				bool(reused.get("authoritative_damage")),
				"Pooled Agave cannonballs must restore authoritative damage state."
			)
		if projectile_scene == COLLECTIBLE_SAKURA_ROCKET_SCENE:
			var sakura_rocket := reused as LinglanSkill2SakuraRocket
			_expect(
				sakura_rocket != null
				and sakura_rocket.explosion_scene == COLLECTIBLE_SAKURA_EXPLOSION_SCENE
				and is_equal_approx(sakura_rocket.speed, 210.0)
				and is_equal_approx(sakura_rocket.max_lifetime, 5.0)
				and is_equal_approx(sakura_rocket.explosion_radius, 47.0)
				and is_equal_approx(sakura_rocket.homing_turn_rate, 1.2),
				"Pooled collectible Sakura rockets must retain their isolated effect and authored movement defaults."
			)
		if projectile_scene in [
			FIRE_SORCERER_FIREBALL_VOLLEY_SCENE,
			FIRE_SORCERER_ELITE_FIREBALL_VOLLEY_SCENE,
		]:
			var reused_volley := reused as FireSorcererFireballVolley
			reused_volley.set_physics_process(false)
			await physics_frame
			var expected_speed := (
				115.0
				if projectile_scene
					== FIRE_SORCERER_ELITE_FIREBALL_VOLLEY_SCENE
				else 100.0
			)
			var expected_source_type := (
				&"fire_sorcerer_elite_fireball_volley"
				if projectile_scene
					== FIRE_SORCERER_ELITE_FIREBALL_VOLLEY_SCENE
				else &"fire_sorcerer_fireball_volley"
			)
			var expected_burn_level := (
				10
				if projectile_scene
					== FIRE_SORCERER_ELITE_FIREBALL_VOLLEY_SCENE
				else 5
			)
			_expect(
				reused_volley.active_ball_mask
					== FireSorcererFireballVolley.ALL_BALLS_ACTIVE_MASK
				and reused_volley.visible_effect_mask == 0
				and reused_volley.target_runtime == null
				and is_zero_approx(reused_volley.target_refresh_left)
				and is_equal_approx(reused_volley.speed, expected_speed)
				and is_equal_approx(reused_volley.burn_duration, 5.0)
				and reused_volley.burn_level == expected_burn_level
				and reused_volley.source_type == expected_source_type,
				(
					"%s must restore all three live balls, its authored speed "
					+ "burn profile and independent source type while clearing stale "
					+ "visual and target-query state."
				) % projectile_scene.resource_path
			)
			_expect(
				is_same(retained_motion_sweep, reused_volley.motion_sweep)
				and is_same(
					retained_motion_query,
					reused_volley.motion_sweep.query
				)
				and retained_motion_query.motion == Vector2.ZERO,
				"Reused Fire Sorcerer volleys must retain one clean shape query."
			)
			var unique_ball_positions := {}
			for ball_index in range(
				FireSorcererFireballVolley.BALL_COUNT
			):
				var ball := reused_volley.ball_areas[ball_index]
				var shape := reused_volley.ball_collision_shapes[ball_index]
				var sprite := reused_volley.ball_sprites[ball_index]
				unique_ball_positions[ball.position] = true
				_expect(
					ball.collision_layer
						== FireSorcererFireballVolley.AUTHORED_COLLISION_LAYER
					and ball.collision_mask
						== FireSorcererFireballVolley.AUTHORED_COLLISION_MASK
					and ball.monitoring
					and ball.monitorable
					and not shape.disabled
					and retained_motion_query.shape == shape.shape
					and sprite.visible
					and sprite.animation == &"fly"
					and reused_volley.ball_directions[ball_index]
						== Vector2.RIGHT
					and is_zero_approx(
						reused_volley.ball_effect_times[ball_index]
					),
					(
						"Reused Fire Sorcerer ball %d must restore collision, "
						+ "visual, direction, and timing state."
					) % ball_index
				)
			_expect(
				unique_ball_positions.size()
					== FireSorcererFireballVolley.BALL_COUNT,
				"Reused Fire Sorcerer volleys must restore three distinct "
				+ "authored offsets."
			)
		if projectile_scene == FROST_SORCERER_ICE_SPIKE_SCENE:
			var reused_spike := reused as FrostSorcererIceSpike
			_expect(
				not reused_spike.has_hit
				and is_zero_approx(reused_spike.effect_time_left)
				and is_equal_approx(reused_spike.speed, 100.0)
				and is_equal_approx(reused_spike.max_lifetime, 7.0)
				and is_equal_approx(reused_spike.remaining_lifetime, 7.0)
				and reused_spike.source_type == &"frost_sorcerer_ice_spike"
				and not reused_spike.multiplayer_contact_consumed
				and reused_spike.motion_sweep_query_count == 0,
				(
					"Reused Frost Sorcerer ice spikes must restore their single-hit "
					+ "100px/s, 7s straight-flight profile and source type."
				)
			)
			_expect(
				is_same(
					retained_motion_sweep,
					reused_spike.motion_sweep
				)
				and is_same(
					retained_motion_query,
					reused_spike.motion_sweep.query
				)
				and retained_motion_query.motion == Vector2.ZERO
				and retained_motion_query.shape
					== reused_spike.collision_shape.shape,
				"Reused ice spikes must retain one clean authored motion shape query."
			)
			_expect(
				reused_spike.collision_layer
					== FrostSorcererIceSpike.AUTHORED_COLLISION_LAYER
				and reused_spike.collision_mask
					== FrostSorcererIceSpike.AUTHORED_COLLISION_MASK
				and not reused_spike.collision_shape.disabled
				and reused_spike.animated_sprite.visible
				and reused_spike.animated_sprite.animation == &"fly",
				"Reused ice spikes must restore collision and the flight visual."
			)
		if reused is Area2D:
			_expect(
				(reused as Area2D).monitoring and (reused as Area2D).monitorable,
				"%s must restore Area2D monitoring." % projectile_scene.resource_path
			)
		_expect(pool.release(reused), "%s reused lease must release." % projectile_scene.resource_path)
		await _wait_for_quarantine()

func _verify_strict_hit_effect_budget() -> void:
	var first := pool.try_acquire(BULLET_HIT_EFFECT_SCENE) as BulletHitEffect
	var second := pool.try_acquire(BULLET_HIT_EFFECT_SCENE) as BulletHitEffect
	var dropped := pool.try_acquire(BULLET_HIT_EFFECT_SCENE) as BulletHitEffect
	_expect(first != null and second != null, "Strict hit-effect pool must serve retained capacity.")
	_expect(dropped == null, "Strict hit-effect pool must drop visuals beyond capacity.")
	var metrics := pool.get_metrics(BULLET_HIT_EFFECT_SCENE.resource_path)
	_expect(int(metrics.get("dropped", 0)) == 1, "Strict hit-effect drops must be observable.")
	if first != null:
		first.setup(Vector2.RIGHT)
		first.call("_on_finished")
	if second != null:
		second.setup(Vector2.UP)
		second.call("_on_finished")
	await _wait_for_quarantine()
	var reused := pool.try_acquire(BULLET_HIT_EFFECT_SCENE) as BulletHitEffect
	_expect(reused != null and reused.pool_active, "Finished hit effects must become reusable.")
	if reused != null:
		reused.call("_on_finished")
	await _wait_for_quarantine()


func _count_active_hit_effects() -> int:
	var active := 0
	for child in pool.get_children():
		var effect := child as BulletHitEffect
		if effect != null and effect.pool_active:
			active += 1
	return active


func _wait_for_quarantine() -> void:
	await physics_frame
	await process_frame
	await physics_frame
	await process_frame


func _finish() -> void:
	current_scene = null
	if fixture != null:
		fixture.queue_free()
	for _cleanup_frame in range(4):
		await process_frame
		await physics_frame
	if failures.is_empty():
		print("PROJECTILE_POOL_SMOKE_TEST_OK")
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	quit(1)


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
