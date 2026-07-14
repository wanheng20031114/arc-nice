extends SceneTree

const COMPLETE_SHAPE_QUERY_2D := preload("res://scene/complete_shape_query_2d.gd")
const BOSS_ROCKET_SCENE := preload(
	"res://scene/boss/linglan/linglan_skill2_sakura_rocket.tscn"
)
const COLLECTIBLE_ROCKET_SCENE := preload("res://scene/collectible_sakura_rocket.tscn")
const RPG_ROCKET_SCENE := preload("res://scene/enemy/capoo_rpg_rocket.tscn")
const MAGE_FIREBALL_SCENE := preload("res://scene/enemy/capoo_mage_fireball.tscn")
const AGAVE_CANNONBALL_SCENE := preload("res://scene/plant_defense/agave_cannonball.tscn")
const PLAYER_SCENE := preload("res://scene/player/weishidaier/player_weishidaier.tscn")
const ENEMY_CONFIG := preload("res://resources/config/enemies/yuanshi_insect_basic.tres")

const DENSE_COLLIDER_COUNT := 145
const TEST_HEALTH := 1000

var failures: Array[String] = []
var test_root: Node2D


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	test_root = Node2D.new()
	test_root.name = "ExplosionQueryRegressionSmokeTest"
	root.add_child(test_root)
	current_scene = test_root

	_test_sakura_rocket_resource_isolation()
	_test_enemy_projectile_resource_isolation()
	await _test_complete_shape_query_pagination()
	await _test_direct_collision_target_inclusion()

	test_root.queue_free()
	await process_frame
	await physics_frame
	for _cleanup_frame in range(3):
		await process_frame

	if failures.is_empty():
		print("EXPLOSION_QUERY_REGRESSION_SMOKE_TEST_OK")
		quit()
		return
	for failure in failures:
		push_error(failure)
	quit(1)


func _test_sakura_rocket_resource_isolation() -> void:
	_expect(
		BOSS_ROCKET_SCENE.resource_path != COLLECTIBLE_ROCKET_SCENE.resource_path,
		"Boss and collectible Sakura rockets must use different PackedScenes."
	)
	var boss_rocket_a := BOSS_ROCKET_SCENE.instantiate() as LinglanSkill2SakuraRocket
	var boss_rocket_b := BOSS_ROCKET_SCENE.instantiate() as LinglanSkill2SakuraRocket
	var collectible_rocket := COLLECTIBLE_ROCKET_SCENE.instantiate() as LinglanSkill2SakuraRocket
	_expect(boss_rocket_a != null and boss_rocket_b != null, "Boss Sakura rocket scene failed to instantiate.")
	_expect(collectible_rocket != null, "Collectible Sakura rocket scene failed to instantiate.")
	if boss_rocket_a == null or boss_rocket_b == null or collectible_rocket == null:
		_free_if_valid(boss_rocket_a)
		_free_if_valid(boss_rocket_b)
		_free_if_valid(collectible_rocket)
		return

	var boss_shape_a := boss_rocket_a.get_node("ExplosionShape") as CollisionShape2D
	var boss_shape_b := boss_rocket_b.get_node("ExplosionShape") as CollisionShape2D
	var collectible_shape := collectible_rocket.get_node("ExplosionShape") as CollisionShape2D
	var boss_body_shape_a := boss_rocket_a.get_node("CollisionShape2D") as CollisionShape2D
	var boss_body_shape_b := boss_rocket_b.get_node("CollisionShape2D") as CollisionShape2D
	var collectible_body_shape := (
		collectible_rocket.get_node("CollisionShape2D") as CollisionShape2D
	)
	_expect(
		boss_shape_a.shape.resource_local_to_scene
		and boss_shape_b.shape.resource_local_to_scene
		and collectible_shape.shape.resource_local_to_scene,
		"Every mutable Sakura explosion Shape must be local to its scene instance."
	)
	_expect(
		boss_shape_a.shape != boss_shape_b.shape
		and boss_shape_a.shape != collectible_shape.shape,
		"Boss/collectible Sakura rocket instances must not share mutable Shape resources."
	)
	_expect(
		not boss_body_shape_a.shape.resource_local_to_scene
		and not boss_body_shape_b.shape.resource_local_to_scene
		and not collectible_body_shape.shape.resource_local_to_scene,
		"Immutable Sakura rocket body Shapes must remain shared resources."
	)
	_expect(
		boss_body_shape_a.shape == boss_body_shape_b.shape,
		"Boss Sakura rocket instances must reuse their immutable capsule Shape."
	)
	var boss_circle_a := boss_shape_a.shape as CircleShape2D
	var boss_circle_b := boss_shape_b.shape as CircleShape2D
	var collectible_circle := collectible_shape.shape as CircleShape2D
	_expect(
		is_equal_approx(boss_circle_a.radius, 78.0)
		and is_equal_approx(boss_circle_b.radius, 78.0)
		and is_equal_approx(collectible_circle.radius, 47.0),
		"Sakura rocket scenes must keep independent authored explosion radii."
	)
	boss_circle_a.radius = 13.0
	_expect(
		is_equal_approx(boss_circle_b.radius, 78.0)
		and is_equal_approx(collectible_circle.radius, 47.0),
		"Mutating one Boss rocket radius must not leak to another Boss or collectible rocket."
	)
	boss_rocket_a.free()
	boss_rocket_b.free()
	collectible_rocket.free()


func _test_enemy_projectile_resource_isolation() -> void:
	var rpg_a := RPG_ROCKET_SCENE.instantiate() as CapooRPGRocket
	var rpg_b := RPG_ROCKET_SCENE.instantiate() as CapooRPGRocket
	var mage_a := MAGE_FIREBALL_SCENE.instantiate() as CapooMageFireball
	var mage_b := MAGE_FIREBALL_SCENE.instantiate() as CapooMageFireball
	_expect(
		rpg_a != null and rpg_b != null and mage_a != null and mage_b != null,
		"Enemy explosive projectile scenes failed to instantiate."
	)
	if rpg_a == null or rpg_b == null or mage_a == null or mage_b == null:
		_free_if_valid(rpg_a)
		_free_if_valid(rpg_b)
		_free_if_valid(mage_a)
		_free_if_valid(mage_b)
		return

	var rpg_circle_a := (rpg_a.get_node("ExplosionShape") as CollisionShape2D).shape as CircleShape2D
	var rpg_circle_b := (rpg_b.get_node("ExplosionShape") as CollisionShape2D).shape as CircleShape2D
	var mage_body_a := (mage_a.get_node("CollisionShape2D") as CollisionShape2D).shape as CircleShape2D
	var mage_body_b := (mage_b.get_node("CollisionShape2D") as CollisionShape2D).shape as CircleShape2D
	var mage_explosion_a := (mage_a.get_node("ExplosionShape") as CollisionShape2D).shape as CircleShape2D
	var mage_explosion_b := (mage_b.get_node("ExplosionShape") as CollisionShape2D).shape as CircleShape2D
	_expect(
		rpg_circle_a.resource_local_to_scene
		and mage_body_a.resource_local_to_scene
		and mage_explosion_a.resource_local_to_scene,
		"Every runtime-mutated enemy projectile Shape must be local to its scene instance."
	)
	_expect(
		rpg_circle_a != rpg_circle_b
		and mage_body_a != mage_body_b
		and mage_explosion_a != mage_explosion_b,
		"Enemy explosive projectile instances must not share runtime-mutated Shapes."
	)
	rpg_circle_a.radius = 17.0
	mage_body_a.radius = 7.0
	mage_explosion_a.radius = 23.0
	_expect(
		is_equal_approx(rpg_circle_b.radius, 44.0)
		and is_equal_approx(mage_body_b.radius, 4.0)
		and is_equal_approx(mage_explosion_b.radius, 10.5),
		"Mutating one enemy projectile radius must not leak to another instance."
	)
	rpg_a.free()
	rpg_b.free()
	mage_a.free()
	mage_b.free()


func _test_complete_shape_query_pagination() -> void:
	var bodies: Array[StaticBody2D] = []
	for body_index in range(DENSE_COLLIDER_COUNT):
		var body := StaticBody2D.new()
		body.collision_layer = 1
		body.collision_mask = 0
		var shape_node := CollisionShape2D.new()
		var circle := CircleShape2D.new()
		circle.radius = 1.0
		shape_node.shape = circle
		body.add_child(shape_node)
		test_root.add_child(body)
		body.global_position = Vector2(
			float(body_index % 17) * 5.0 - 40.0,
			float(body_index / 17) * 5.0 - 20.0
		)
		bodies.append(body)
	await physics_frame
	await physics_frame

	var query := PhysicsShapeQueryParameters2D.new()
	var query_circle := CircleShape2D.new()
	query_circle.radius = 128.0
	query.shape = query_circle
	query.transform = Transform2D.IDENTITY
	query.collision_mask = 1
	query.collide_with_bodies = true
	query.collide_with_areas = false
	query.exclude = [bodies[0].get_rid()]
	var query_metrics: Dictionary = {}
	var results := COMPLETE_SHAPE_QUERY_2D.intersect_shape_all(
		test_root.get_world_2d().direct_space_state,
		query,
		16,
		query_metrics
	)
	var unique_collider_ids: Dictionary = {}
	for result in results:
		var collider := result.get("collider") as CollisionObject2D
		if collider != null:
			unique_collider_ids[collider.get_instance_id()] = true
	_expect(
		unique_collider_ids.size() == DENSE_COLLIDER_COUNT - 1,
		"Paged Shape query must return all dense colliders: expected %d, got %d."
		% [DENSE_COLLIDER_COUNT - 1, unique_collider_ids.size()]
	)
	_expect(
		query.exclude.size() == 1 and query.exclude[0] == bodies[0].get_rid(),
		"Complete Shape query must restore the caller's original exclusions."
	)
	_expect(
		int(query_metrics.get("full_batch_count", 0)) == 9
		and int(query_metrics.get("physics_query_count", 0)) >= 9
		and int(query_metrics.get("physics_query_count", 0)) <= 10
		and int(query_metrics.get("newly_excluded_count", 0)) == DENSE_COLLIDER_COUNT - 1
		and int(query_metrics.get("result_count", 0)) == DENSE_COLLIDER_COUNT - 1,
		"Dense query metrics must expose all nine full pages and at most one terminal query: %s."
		% [query_metrics]
	)
	_expect(
		query_metrics.has("elapsed_usec")
		and int(query_metrics.get("elapsed_usec", -1)) >= 0,
		"Dense query diagnostics must report a non-negative elapsed time."
	)
	for body in bodies:
		body.queue_free()
	await physics_frame


func _test_direct_collision_target_inclusion() -> void:
	var player := _spawn_player(Vector2(500.0, 0.0))
	await physics_frame

	var rpg := RPG_ROCKET_SCENE.instantiate() as CapooRPGRocket
	test_root.add_child(rpg)
	rpg.global_position = Vector2.ZERO
	rpg.setup(Vector2.RIGHT, 20, 0.0, 1.0, 44.0)
	var health_before := player.current_health
	rpg.call("_apply_explosion_damage", player)
	_expect(
		player.current_health < health_before,
		"RPG direct collision target must be damaged even outside the follow-up Shape query."
	)
	rpg.queue_free()

	player.invincibility_time_left = 0.0
	var fireball := MAGE_FIREBALL_SCENE.instantiate() as CapooMageFireball
	test_root.add_child(fireball)
	fireball.global_position = Vector2.ZERO
	fireball.setup(Vector2.RIGHT, 20, 0.0, 1.0, 10.5)
	health_before = player.current_health
	fireball.call("_apply_explosion_damage", player)
	_expect(
		player.current_health < health_before,
		"Mage fireball direct collision target must be damaged outside its Shape query."
	)
	fireball.queue_free()

	player.invincibility_time_left = 0.0
	var boss_rocket := BOSS_ROCKET_SCENE.instantiate() as LinglanSkill2SakuraRocket
	test_root.add_child(boss_rocket)
	boss_rocket.global_position = Vector2.ZERO
	boss_rocket.setup(Vector2.RIGHT, 20, 0.0, 1.0, 78.0)
	health_before = player.current_health
	boss_rocket.call("_apply_explosion_damage", player)
	_expect(
		player.current_health < health_before,
		"Boss Sakura rocket direct collision target must be damaged outside its Shape query."
	)
	boss_rocket.queue_free()

	var enemy := ENEMY_CONFIG.enemy_scene.instantiate() as Enemy
	test_root.add_child(enemy)
	enemy.global_position = Vector2(500.0, 100.0)
	enemy.setup(ENEMY_CONFIG, player)
	enemy.current_health = TEST_HEALTH
	enemy.set_physics_process(false)
	enemy.hit_audio.stream = null
	await physics_frame

	var collectible_rocket := COLLECTIBLE_ROCKET_SCENE.instantiate() as LinglanSkill2SakuraRocket
	test_root.add_child(collectible_rocket)
	collectible_rocket.global_position = Vector2.ZERO
	collectible_rocket.setup(
		Vector2.RIGHT,
		20,
		0.0,
		1.0,
		47.0,
		null,
		1.2,
		enemy,
		true,
		EnemyConfig.DamageType.MAGIC
	)
	var enemy_health_before := enemy.current_health
	collectible_rocket.call("_apply_explosion_damage", enemy)
	_expect(
		enemy.current_health < enemy_health_before,
		"Collectible Sakura rocket direct enemy must be included outside its Shape query."
	)
	collectible_rocket.queue_free()

	var cannonball := AGAVE_CANNONBALL_SCENE.instantiate() as AgaveCannonball
	test_root.add_child(cannonball)
	cannonball.global_position = Vector2.ZERO
	cannonball.setup(Vector2.RIGHT, 20, 0.0, 18.0, 1.0)
	enemy_health_before = enemy.current_health
	cannonball.call("_apply_explosion_damage", enemy)
	_expect(
		enemy.current_health < enemy_health_before,
		"Agave direct enemy must be included outside its explosion Shape query."
	)
	cannonball.queue_free()
	enemy.queue_free()
	player.queue_free()
	await physics_frame


func _spawn_player(position: Vector2) -> Player:
	var player := PLAYER_SCENE.instantiate() as Player
	test_root.add_child(player)
	player.global_position = position
	player.collision_layer = 2
	player.invincibility_duration = 0.0
	player.invincibility_time_left = 0.0
	player.set("_base_max_health", TEST_HEALTH)
	player.max_health = TEST_HEALTH
	player.current_health = TEST_HEALTH
	player.health_bar.setup(TEST_HEALTH, TEST_HEALTH)
	player.set_physics_process(false)
	return player


func _free_if_valid(node: Node) -> void:
	if node != null and is_instance_valid(node):
		node.free()


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
