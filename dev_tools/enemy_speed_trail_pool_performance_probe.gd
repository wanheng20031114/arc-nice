extends SceneTree

const BASIC_CONFIG := preload("res://resources/config/enemies/yuanshi_insect_basic.tres")
const SPEED_TRAIL_SCENE := preload("res://scene/combat/feedback/move_speed_trail_effect.tscn")
const ENEMY_COUNT := 300
const ACTIVE_TRAIL_COUNT := 40
const RETAINED_CAPACITY := 32
const LEGACY_PARTICLES_PER_ENEMY := 4

var failures: Array[String] = []
var fixture_root: Node2D
var pool: SessionObjectPool
var enemies: Array[Enemy] = []


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	fixture_root = Node2D.new()
	fixture_root.name = "EnemySpeedTrailPoolPerformanceProbe"
	root.add_child(fixture_root)
	current_scene = fixture_root

	pool = SessionObjectPool.new()
	pool.name = "SessionObjectPool"
	fixture_root.add_child(pool)
	pool.register_scene(SPEED_TRAIL_SCENE, 0, RETAINED_CAPACITY)

	var started_usec := Time.get_ticks_usec()
	for enemy_index in range(ENEMY_COUNT):
		var enemy := BASIC_CONFIG.enemy_scene.instantiate() as Enemy
		fixture_root.add_child(enemy)
		enemy.setup(BASIC_CONFIG, null, null)
		enemy.set_physics_process(false)
		enemies.append(enemy)
	var spawn_usec := Time.get_ticks_usec() - started_usec
	await process_frame

	var idle_particle_count := _count_enemy_resident_gpu_particles()
	var idle_metrics := pool.get_metrics(SPEED_TRAIL_SCENE.resource_path)
	_expect(
		idle_particle_count == 0,
		"Three hundred idle enemies must carry zero resident GPUParticles2D nodes."
	)
	_expect(
		int(idle_metrics.get("created", -1)) == 0,
		"The speed-trail pool must not prewarm emitters that normal enemies never use."
	)

	for enemy_index in range(ACTIVE_TRAIL_COUNT):
		var enemy := enemies[enemy_index]
		enemy.velocity = Vector2.RIGHT * 80.0
		enemy.add_move_speed_modifier(700000 + enemy_index, 1.25)
	var active_metrics := pool.get_metrics(SPEED_TRAIL_SCENE.resource_path)
	_expect(
		int(active_metrics.get("in_use", -1)) == ACTIVE_TRAIL_COUNT,
		"Every moving hasted enemy must receive one elastic trail lease."
	)
	_expect(
		int(active_metrics.get("created", -1)) == ACTIVE_TRAIL_COUNT,
		"Only active haste effects may create speed-trail nodes."
	)
	_expect(
		int(active_metrics.get("overflow", -1)) == ACTIVE_TRAIL_COUNT - RETAINED_CAPACITY,
		"The pool must account for short-lived leases beyond its retained budget."
	)

	for enemy_index in range(ACTIVE_TRAIL_COUNT):
		enemies[enemy_index].remove_move_speed_modifier(700000 + enemy_index)
	_expect(
		int(pool.get_metrics(SPEED_TRAIL_SCENE.resource_path).get("in_use", -1)) == 0,
		"Stopping haste must return every trail lease in the same frame."
	)
	for _release_frame in range(2):
		await physics_frame
	var released_metrics := pool.get_metrics(SPEED_TRAIL_SCENE.resource_path)
	_expect(
		int(released_metrics.get("created", -1)) == RETAINED_CAPACITY,
		"Overflow trail nodes must be discarded after the release quarantine."
	)
	_expect(
		int(released_metrics.get("inactive", -1)) == RETAINED_CAPACITY,
		"Only the configured retained trail capacity may remain inactive."
	)
	_expect(
		int(released_metrics.get("pending_release", -1)) == 0,
		"All released trail leases must leave quarantine."
	)

	print(
		(
			"ENEMY_SPEED_TRAIL_POOL_METRICS enemies=%d idle_particles=%d legacy_particles_removed=%d "
			+ "spawn_usec=%d peak_leases=%d retained=%d overflow=%d"
		)
		% [
			ENEMY_COUNT,
			idle_particle_count,
			ENEMY_COUNT * LEGACY_PARTICLES_PER_ENEMY,
			spawn_usec,
			int(released_metrics.get("peak_in_use", 0)),
			int(released_metrics.get("created", 0)),
			int(released_metrics.get("overflow", 0)),
		]
	)

	fixture_root.queue_free()
	for _cleanup_frame in range(4):
		await process_frame
		await physics_frame
	if failures.is_empty():
		print("ENEMY_SPEED_TRAIL_POOL_PERFORMANCE_PROBE_OK")
		quit()
		return
	for failure in failures:
		push_error(failure)
	quit(1)


func _count_enemy_resident_gpu_particles() -> int:
	var count := 0
	for enemy in enemies:
		for descendant in enemy.find_children("", "GPUParticles2D", true, false):
			if descendant is GPUParticles2D:
				count += 1
	return count


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
