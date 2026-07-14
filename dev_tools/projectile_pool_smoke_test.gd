extends SceneTree

const BULLET_SCENE := preload("res://scene/bullet.tscn")
const AK_BULLET_SCENE := preload("res://scene/enemy/capoo_ak47_bullet.tscn")
const SMG_BULLET_SCENE := preload("res://scene/enemy/capoo_smg_bullet.tscn")
const RPG_ROCKET_SCENE := preload("res://scene/enemy/capoo_rpg_rocket.tscn")
const MAGE_FIREBALL_SCENE := preload("res://scene/enemy/capoo_mage_fireball.tscn")
const YUANSHI_FIRE_PROJECTILE_SCENE := preload("res://scene/enemy/yuanshi_insect_fire_projectile.tscn")
const AGAVE_CANNONBALL_SCENE := preload("res://scene/plant_defense/agave_cannonball.tscn")
const COLLECTIBLE_ARROW_SCENE := preload("res://scene/collectible_arrow_projectile.tscn")
const COLLECTIBLE_SAKURA_ROCKET_SCENE := preload(
	"res://scene/collectible_sakura_rocket.tscn"
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
	pool.register_scene(YUANSHI_FIRE_PROJECTILE_SCENE, 1, 2)
	pool.register_scene(AGAVE_CANNONBALL_SCENE, 1, 2)
	pool.register_scene(COLLECTIBLE_ARROW_SCENE, 1, 2)
	pool.register_scene(COLLECTIBLE_SAKURA_ROCKET_SCENE, 1, 2)
	pool.register_scene(BULLET_HIT_EFFECT_SCENE, 2, 2)
	pool.register_scene(ENEMY_HIT_EFFECT_SCENE, 2, 2)

	await _verify_player_bullet_reuse()
	await _verify_real_collision_callback_release()
	await _verify_capoo_bullet_reuse()
	await _verify_extended_projectile_reuse()
	await _verify_strict_hit_effect_budget()
	await _finish()


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
	_expect(reused.speed == 320.0 and reused.max_lifetime == 2.0, "Player bullet authored timing must reset.")
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


func _verify_extended_projectile_reuse() -> void:
	var scenes: Array[PackedScene] = [
		RPG_ROCKET_SCENE,
		MAGE_FIREBALL_SCENE,
		YUANSHI_FIRE_PROJECTILE_SCENE,
		AGAVE_CANNONBALL_SCENE,
		COLLECTIBLE_ARROW_SCENE,
		COLLECTIBLE_SAKURA_ROCKET_SCENE,
	]
	for projectile_scene in scenes:
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
