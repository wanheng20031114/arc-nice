extends SceneTree

const LINGLAN_SCENE := preload("res://scene/linglan_boss.tscn")
const LINGLAN_CONFIG := preload("res://resources/config/enemies/linglan_boss.tres")
const SKILL1_CONFIG := preload("res://resources/config/bosses/linglan_skill1.tres")

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
	_expect(SKILL1_CONFIG.ring_direction_count == 24, "Skill1 direction count mismatch.")
	_expect(is_equal_approx(SKILL1_CONFIG.attack_speed, 800.0), "Skill1 attack speed mismatch.")
	_expect(is_equal_approx(SKILL1_CONFIG.get_fire_interval(), 0.125), "Skill1 fire interval mismatch.")
	_expect(is_equal_approx(SKILL1_CONFIG.projectile_speed, 300.0), "Skill1 projectile speed mismatch.")
	_expect(SKILL1_CONFIG.projectile_damage == 50, "Skill1 projectile damage mismatch.")
	_expect(SKILL1_CONFIG.projectile_scene != null, "Skill1 projectile scene missing.")


func _test_skill1_fire_schedule() -> void:
	var boss := LINGLAN_SCENE.instantiate() as LinglanBoss
	_expect(boss != null, "Linglan scene did not instantiate as LinglanBoss.")
	if boss == null:
		return
	test_root.add_child(boss)
	await process_frame
	boss.config = LINGLAN_CONFIG
	boss.activate_boss(null, null)

	boss.call("_physics_process", 4.99)
	_expect(_get_sakura_bullets().is_empty(), "Skill1 fired before the 5 second delay.")

	boss.call("_physics_process", 0.01)
	var first_ring := _get_sakura_bullets()
	_expect(first_ring.size() == 24, "Skill1 first ring must spawn 24 projectiles.")
	if first_ring.size() == 24:
		var first_bullet := first_ring[0]
		_expect(is_equal_approx(first_bullet.speed, 300.0), "Sakura bullet speed mismatch.")
		_expect(first_bullet.damage == 50, "Sakura bullet damage mismatch.")
		_expect(is_equal_approx(first_bullet.max_lifetime, 2.0), "Sakura bullet lifetime mismatch.")
		_expect(first_bullet.direction.dot(Vector2.RIGHT) > 0.99, "First ring must start from the unrotated right direction.")
	_clear_sakura_bullets()

	boss.call("_physics_process", 2.25)
	var rotated_bullets := _get_sakura_bullets()
	_expect(rotated_bullets.size() > 24, "Skill1 must keep firing during the rotating phase.")
	if rotated_bullets.size() >= 24:
		var last_ring_first_bullet := rotated_bullets[rotated_bullets.size() - 24]
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


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
