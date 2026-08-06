extends SceneTree

const LINGLAN_SCENE := preload("res://scene/boss/linglan/linglan_boss.tscn")
const LINGLAN_CONFIG := preload("res://resources/config/enemies/linglan_boss.tres")
const SKILL1_CONFIG := preload("res://resources/config/bosses/linglan_skill1.tres")
const SAKURA_BULLET_TEXTURE := preload("res://resources/texture/boss_linglan/skill1_sakura_bullet.png")
const SAKURA_BULLET_SCENE := preload("res://scene/boss/linglan/linglan_skill1_sakura_bullet.tscn")
const WARNING_RAY_SCENE := preload("res://scene/boss/linglan/linglan_skill1_warning_ray.tscn")
const PLAYER_SCENE := preload("res://scene/player/weishidaier/player_weishidaier.tscn")
const ENEMY_SCENE := preload("res://scene/enemy/enemy.tscn")
const TEST_RUNTIME_SCRIPT := preload(
	"res://dev_tools/fixtures/linglan_combat_test_runtime.gd"
)

var failures: Array[String] = []
var test_root: CombatRuntimeBase


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	test_root = TEST_RUNTIME_SCRIPT.new()
	test_root.name = "LinglanSkill1SmokeTest"
	root.add_child(test_root)

	_test_skill1_config()
	await _test_sakura_bullet_scene_contract()
	await _test_skill1_fire_schedule()
	await _test_multiplayer_proxy_warning_action()

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
	_expect(is_equal_approx(SKILL1_CONFIG.projectile_lifetime, 1.2), "Skill1 active projectile lifetime mismatch.")
	_expect(is_equal_approx(SKILL1_CONFIG.get_projectile_travel_distance(), 360.0), "Skill1 projectile travel distance mismatch.")
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
	(test_root as LinglanCombatTestRuntime).bind_linglan_node(bullet)
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
	player.invincibility_duration = 0.0
	test_root.add_child(player)
	await process_frame
	player._base_max_health = 100
	player.max_health = 100
	player.current_health = 100
	player.health_bar.setup(player.max_health, player.current_health)
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
	(test_root as LinglanCombatTestRuntime).bind_linglan_node(enemy_safe_bullet)
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
	(test_root as LinglanCombatTestRuntime).bind_linglan_node(boss)
	await process_frame
	boss.config = LINGLAN_CONFIG
	boss.activate_boss(
		null,
		null,
		test_root,
		(test_root as LinglanCombatTestRuntime).linglan_boss_runtime_port
	)

	boss.call("_physics_process", SKILL1_CONFIG.start_delay - SKILL1_CONFIG.warning_lead_time - 0.01)
	_expect(_get_sakura_bullets().is_empty(), "Skill1 fired before the 5 second delay.")
	_expect(_get_warning_rays().is_empty(), "Skill1 warning rays appeared before the warning lead time.")

	boss.call("_physics_process", 0.02)
	var warning_rays := _get_warning_rays()
	var direction_count := SKILL1_CONFIG.ring_direction_count
	_expect(
		warning_rays.size() == direction_count,
		"Skill1 warning must show %d rays before firing, got %d." % [direction_count, warning_rays.size()]
	)
	if warning_rays.size() == direction_count:
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
	_expect(
		first_ring.size() == direction_count,
		"Skill1 first ring must spawn %d projectiles." % direction_count
	)
	_expect(_get_warning_rays().is_empty(), "Skill1 warning rays must clear when firing starts.")
	var sprite := boss.get_node_or_null("AnimatedSprite2D") as AnimatedSprite2D
	_expect(sprite != null and sprite.animation == &"attack", "Skill1 firing phase must play Linglan attack animation.")
	if first_ring.size() == direction_count:
		var first_bullet := first_ring[0]
		_expect(is_equal_approx(first_bullet.speed, 300.0), "Sakura bullet speed mismatch.")
		_expect(first_bullet.damage == 50, "Sakura bullet damage mismatch.")
		_expect(is_equal_approx(first_bullet.max_lifetime, 1.2), "Sakura bullet active lifetime mismatch.")
		_expect(first_bullet.direction.dot(Vector2.RIGHT) > 0.99, "First ring must start from the unrotated right direction.")
	_clear_sakura_bullets()

	boss.call("_physics_process", 2.25)
	var rotated_bullets := _get_sakura_bullets()
	_expect(rotated_bullets.size() > direction_count, "Skill1 must keep firing during the rotating phase.")
	if rotated_bullets.size() >= direction_count:
		var last_ring_first_bullet := rotated_bullets[rotated_bullets.size() - direction_count]
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


func _test_multiplayer_proxy_warning_action() -> void:
	var boss := LINGLAN_SCENE.instantiate() as LinglanBoss
	_expect(boss != null, "Linglan scene did not instantiate for proxy warning action.")
	if boss == null:
		return
	test_root.add_child(boss)
	(test_root as LinglanCombatTestRuntime).bind_linglan_node(boss)
	await process_frame
	boss.global_position = Vector2(32.0, -12.0)
	boss.configure_multiplayer_proxy()

	boss.play_multiplayer_enemy_action(&"linglan_skill1_warning", Vector2.ZERO, 1)
	await process_frame
	var warning_rays := _get_warning_rays()
	_expect(
		warning_rays.size() == SKILL1_CONFIG.ring_direction_count,
		"Proxy Skill1 warning action must spawn all warning rays, got %d." % warning_rays.size()
	)
	if not warning_rays.is_empty():
		_expect(
			warning_rays[0].global_position.distance_to(boss.global_position) <= 0.01,
			"Proxy Skill1 warning rays must be positioned at remote Linglan."
		)

	boss.apply_multiplayer_proxy_motion(
		Vector2(48.0, -20.0),
		Vector2.ZERO,
		Enemy.LocomotionState.IDLE
	)
	warning_rays = _get_warning_rays()
	if not warning_rays.is_empty():
		_expect(
			warning_rays[0].global_position.distance_to(boss.global_position) <= 0.01,
			"Proxy Skill1 warning rays must follow snapshot motion."
		)

	boss.play_multiplayer_enemy_action(&"linglan_skill1_attack", Vector2.ZERO, 2)
	await process_frame
	_expect(_get_warning_rays().is_empty(), "Proxy Skill1 warning rays must clear when attack starts.")

	boss.queue_free()
	await process_frame

	var death_boss := LINGLAN_SCENE.instantiate() as LinglanBoss
	_expect(death_boss != null, "Linglan scene did not instantiate for proxy warning death cleanup.")
	if death_boss == null:
		return
	test_root.add_child(death_boss)
	(test_root as LinglanCombatTestRuntime).bind_linglan_node(death_boss)
	await process_frame
	death_boss.global_position = Vector2(-32.0, 18.0)
	death_boss.configure_multiplayer_proxy()

	death_boss.play_multiplayer_enemy_action(&"linglan_skill1_warning", Vector2.ZERO, 1)
	await process_frame
	_expect(
		_get_warning_rays().size() == SKILL1_CONFIG.ring_direction_count,
		"Proxy Skill1 death cleanup test must spawn warning rays first."
	)
	death_boss.play_multiplayer_death_sequence()
	await process_frame
	_expect(_get_warning_rays().is_empty(), "Proxy Skill1 death must clear warning rays.")

	if is_instance_valid(death_boss):
		death_boss.queue_free()
	await process_frame


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
