extends SceneTree

const LINGLAN_SCENE := preload("res://scene/linglan_boss.tscn")
const LINGLAN_CONFIG := preload("res://resources/config/enemies/linglan_boss.tres")
const SKILL1_CONFIG := preload("res://resources/config/bosses/linglan_skill1.tres")
const SAKURA_BULLET_TEXTURE := preload("res://resources/texture/boss_linglan/skill1_sakura_bullet.png")
const SAKURA_BULLET_SCENE := preload("res://scene/linglan_skill1_sakura_bullet.tscn")
const WARNING_RAY_SCENE := preload("res://scene/linglan_skill1_warning_ray.tscn")
const PLAYER_SCENE := preload("res://scene/player.tscn")
const ENEMY_SCENE := preload("res://scene/enemy/enemy.tscn")

var failures: Array[String] = []
var test_root: Node2D


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	test_root = Node2D.new()
	test_root.name = "LinglanSkill1SmokeTest"
	root.add_child(test_root)
	current_scene = test_root

	_test_skill1_config()
	await _test_sakura_bullet_scene_contract()
	await _test_skill1_fire_schedule()

	test_root.queue_free()
	await process_frame

	if failures.is_empty():
		print("LINGLAN_SKILL1_SMOKE_TEST_OK")
		quit()
		return

	for failure in failures:
		push_error(failure)
	quit(1)


func _test_skill1_config() -> void:
	_expect(SKILL1_CONFIG.skill_name == &"linglan_skill1", "Skill1 name mismatch.")
	_expect(is_equal_approx(SKILL1_CONFIG.start_delay, 5.0), "Skill1 start delay mismatch.")
	_expect(SKILL1_CONFIG.ring_direction_count == 20, "Skill1 direction count mismatch.")
	_expect(is_equal_approx(SKILL1_CONFIG.attack_speed, 1800.0), "Skill1 attack speed mismatch.")
	_expect(is_equal_approx(SKILL1_CONFIG.get_fire_interval(), 1.0 / 18.0), "Skill1 fire interval mismatch.")
	_expect(is_equal_approx(SKILL1_CONFIG.projectile_speed, 300.0), "Skill1 projectile speed mismatch.")
	_expect(is_equal_approx(SKILL1_CONFIG.get_projectile_travel_distance(), 600.0), "Skill1 projectile travel distance mismatch.")
	_expect(SKILL1_CONFIG.projectile_damage == 50, "Skill1 projectile damage mismatch.")
	_expect(SKILL1_CONFIG.projectile_scene != null, "Skill1 projectile scene missing.")
	_expect(SKILL1_CONFIG.warning_ray_scene == WARNING_RAY_SCENE, "Skill1 warning ray scene mismatch.")
	_expect(is_equal_approx(SKILL1_CONFIG.warning_lead_time, 1.0), "Skill1 warning lead time mismatch.")
	_expect(is_equal_approx(SKILL1_CONFIG.warning_ray_width_scale, 0.6), "Skill1 warning ray width scale mismatch.")
	_expect(SAKURA_BULLET_TEXTURE.get_size().x > 0 and SAKURA_BULLET_TEXTURE.get_size().y > 0, "Sakura bullet texture missing.")


func _test_sakura_bullet_scene_contract() -> void:
	var bullet := SAKURA_BULLET_SCENE.instantiate() as LinglanSakuraBullet
	_expect(bullet != null, "Sakura bullet scene did not instantiate as LinglanSakuraBullet.")
	if bullet == null:
		return
	test_root.add_child(bullet)
	await process_frame

	var shape_node := bullet.get_node_or_null("CollisionShape2D") as CollisionShape2D
	_expect(shape_node != null, "Sakura bullet must expose a direct CollisionShape2D for editor tuning.")
	if shape_node != null:
		var circle := shape_node.shape as CircleShape2D
		_expect(circle != null, "Sakura bullet collision shape must be circular.")
		if circle != null:
			_expect(circle.radius > 0.0, "Sakura bullet collision radius must stay editor-tunable and positive.")
	_expect(bullet.collision_mask & 4 == 0, "Sakura bullet collision mask must not include EnemyBody.")
	_expect(bullet.collision_mask & 256 == 0, "Sakura bullet collision mask must not include BossBody.")

	var player := PLAYER_SCENE.instantiate() as Player
	player.max_health = 100
	player.invincibility_duration = 0.0
	test_root.add_child(player)
	await process_frame
	bullet.setup(Vector2.RIGHT, 50, 300.0, 2.0)
	bullet.call("_on_body_entered", player)
	_expect(player.current_health == 50, "Sakura bullet must deal 50 damage on hit.")
	_expect(_count_sakura_hit_effects() == 1, "Sakura bullet must spawn one lightweight pink hit effect on a valid player hit.")

	if is_instance_valid(bullet):
		bullet.queue_free()
	player.queue_free()
	_clear_sakura_hit_effects()

	var enemy := ENEMY_SCENE.instantiate() as Enemy
	enemy.current_health = 100
	test_root.add_child(enemy)
	var enemy_safe_bullet := SAKURA_BULLET_SCENE.instantiate() as LinglanSakuraBullet
	test_root.add_child(enemy_safe_bullet)
	await process_frame
	enemy_safe_bullet.call("_on_body_entered", enemy)
	_expect(enemy.current_health == 100, "Sakura bullet must ignore Enemy bodies.")
	_expect(is_instance_valid(enemy_safe_bullet) and not enemy_safe_bullet.has_hit, "Sakura bullet must not be consumed by Enemy bodies.")
	_expect(_count_sakura_hit_effects() == 0, "Sakura bullet must not spawn hit effects on Enemy bodies.")
	if is_instance_valid(enemy_safe_bullet):
		enemy_safe_bullet.queue_free()
	enemy.queue_free()


func _test_skill1_fire_schedule() -> void:
	var boss := LINGLAN_SCENE.instantiate() as LinglanBoss
	_expect(boss != null, "Linglan scene did not instantiate as LinglanBoss.")
	if boss == null:
		return
	test_root.add_child(boss)
	await process_frame
	boss.config = LINGLAN_CONFIG
	boss.activate_boss(null, null)

	boss.call("_physics_process", SKILL1_CONFIG.start_delay - SKILL1_CONFIG.warning_lead_time - 0.01)
	_expect(_get_sakura_bullets().is_empty(), "Skill1 fired before the 5 second delay.")
	_expect(_get_warning_rays().is_empty(), "Skill1 warning rays appeared before the warning lead time.")

	boss.call("_physics_process", 0.02)
	var warning_rays := _get_warning_rays()
	_expect(warning_rays.size() == 20, "Skill1 warning must show 20 rays before firing, got %d." % warning_rays.size())
	if warning_rays.size() == 20:
		var first_ray := warning_rays[0]
		var first_ray_core := first_ray.get_node_or_null("Core") as Line2D
		_expect(first_ray.global_position.distance_to(boss.global_position) <= 0.01, "Skill1 warning rays must rotate around Linglan.")
		_expect(first_ray.global_rotation == Vector2.RIGHT.angle(), "Skill1 first warning ray must point right.")
		_expect(first_ray_core != null, "Skill1 warning ray must expose a Core Line2D.")
		if first_ray_core != null:
			_expect(first_ray_core.points.size() == 2, "Skill1 warning ray must be a single segment.")
			if first_ray_core.points.size() == 2:
				_expect(is_equal_approx(first_ray_core.points[0].x, SKILL1_CONFIG.projectile_spawn_distance), "Skill1 warning ray must start at the projectile spawn distance.")
				_expect(
					is_equal_approx(
						first_ray_core.points[1].x,
						SKILL1_CONFIG.projectile_spawn_distance + SKILL1_CONFIG.get_projectile_travel_distance()
					),
					"Skill1 warning ray must preview the full projectile path."
				)

	boss.call("_physics_process", SKILL1_CONFIG.warning_lead_time)
	await process_frame
	var first_ring := _get_sakura_bullets()
	_expect(first_ring.size() == 20, "Skill1 first ring must spawn 20 projectiles.")
	_expect(_get_warning_rays().is_empty(), "Skill1 warning rays must clear when firing starts.")
	if first_ring.size() == 20:
		var first_bullet := first_ring[0]
		_expect(is_equal_approx(first_bullet.speed, 300.0), "Sakura bullet speed mismatch.")
		_expect(first_bullet.damage == 50, "Sakura bullet damage mismatch.")
		_expect(is_equal_approx(first_bullet.max_lifetime, 2.0), "Sakura bullet lifetime mismatch.")
		_expect(first_bullet.direction.dot(Vector2.RIGHT) > 0.99, "First ring must start from the unrotated right direction.")
	_clear_sakura_bullets()

	boss.call("_physics_process", 2.25)
	var rotated_bullets := _get_sakura_bullets()
	_expect(rotated_bullets.size() > 20, "Skill1 must keep firing during the rotating phase.")
	if rotated_bullets.size() >= 20:
		var last_ring_first_bullet := rotated_bullets[rotated_bullets.size() - 20]
		_expect(
			last_ring_first_bullet.direction.angle() > 0.001,
			"Skill1 ring direction must rotate after the first 2 seconds."
		)
	_clear_sakura_bullets()

	boss.skill1_elapsed = SKILL1_CONFIG.start_delay + SKILL1_CONFIG.get_total_duration() + 0.1
	boss.skill1_fire_time_left = 0.0
	boss.skill1_finished = false
	boss.call("_physics_process", 0.1)
	_expect(_get_sakura_bullets().is_empty(), "Skill1 must not spawn projectiles after its duration.")
	_expect(boss.skill1_finished, "Skill1 must mark itself finished after its duration.")

	boss.queue_free()


func _get_sakura_bullets() -> Array[LinglanSakuraBullet]:
	var bullets: Array[LinglanSakuraBullet] = []
	for child in test_root.get_children():
		var bullet := child as LinglanSakuraBullet
		if bullet != null:
			bullets.append(bullet)
	return bullets


func _clear_sakura_bullets() -> void:
	for bullet in _get_sakura_bullets():
		bullet.free()


func _get_warning_rays() -> Array[Node2D]:
	var rays: Array[Node2D] = []
	for child in test_root.get_children():
		if child.name.begins_with("LinglanSkill1WarningRay"):
			var ray := child as Node2D
			if ray != null:
				rays.append(ray)
	return rays


func _count_sakura_hit_effects() -> int:
	var count := 0
	for child in test_root.get_children():
		if child is LinglanSakuraHitEffect:
			count += 1
	return count


func _clear_sakura_hit_effects() -> void:
	for child in test_root.get_children():
		if child is LinglanSakuraHitEffect:
			child.free()


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
