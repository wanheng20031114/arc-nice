extends SceneTree

const SKILL1_CONFIG := preload("res://resources/config/bosses/linglan_skill1.tres")
const SAKURA_BULLET_SCENE := preload(
	"res://scene/boss/linglan/linglan_skill1_sakura_bullet.tscn"
)
const RETAINED_CAPACITY := 768
const PREWARM_COUNT := 64

var failures: Array[String] = []
var fixture: Node2D = null
var pool: SessionObjectPool = null


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	fixture = Node2D.new()
	fixture.name = "LinglanSkill1PoolPerformanceProbe"
	root.add_child(fixture)
	current_scene = fixture

	var fire_interval := SKILL1_CONFIG.get_fire_interval()
	var ring_count := roundi(SKILL1_CONFIG.get_total_duration() / fire_interval)
	var total_projectile_leases := ring_count * SKILL1_CONFIG.ring_direction_count
	var peak_live_projectiles := (
		ceili(SKILL1_CONFIG.projectile_lifetime / fire_interval)
		* SKILL1_CONFIG.ring_direction_count
	)
	_expect(total_projectile_leases == 6120, "Probe must cover the full authored 6,120-shot Skill1.")
	_expect(peak_live_projectiles == 720, "Probe peak must match the authored two-second flight window.")

	var baseline_cpu_usec := _measure_unpooled_lifecycle(total_projectile_leases)
	pool = SessionObjectPool.new()
	pool.name = "SessionObjectPool"
	fixture.add_child(pool)
	var prewarm_started_usec := Time.get_ticks_usec()
	pool.register_scene(SAKURA_BULLET_SCENE, PREWARM_COUNT, RETAINED_CAPACITY)
	var prewarm_cpu_usec := Time.get_ticks_usec() - prewarm_started_usec
	var pooled_cpu_usec := await _measure_pooled_lifecycle(
		total_projectile_leases,
		peak_live_projectiles
	)
	var warm_replay_cpu_usec := await _measure_pooled_lifecycle(
		total_projectile_leases,
		peak_live_projectiles
	)
	var quarantine_headroom := roundi(
		float(SKILL1_CONFIG.ring_direction_count) / (60.0 * fire_interval)
	)
	await _exercise_same_frame_release_and_spawn(
		peak_live_projectiles,
		quarantine_headroom
	)

	var metrics := pool.get_metrics(SAKURA_BULLET_SCENE.resource_path)
	var stable_subtree_nodes := _count_subtree_nodes(pool)
	var speedup := (
		float(baseline_cpu_usec)
		/ maxf(float(pooled_cpu_usec + prewarm_cpu_usec), 1.0)
	)
	var warm_speedup := (
		float(baseline_cpu_usec) / maxf(float(warm_replay_cpu_usec), 1.0)
	)
	print(
		"LINGLAN_SKILL1_POOL_PROBE ",
		"leases=", total_projectile_leases,
		" peak_live=", peak_live_projectiles,
		" baseline_cpu_usec=", baseline_cpu_usec,
		" prewarm_cpu_usec=", prewarm_cpu_usec,
		" pooled_cpu_usec=", pooled_cpu_usec,
		" first_attack_speedup=", snappedf(speedup, 0.01),
		" warm_replay_cpu_usec=", warm_replay_cpu_usec,
		" warm_replay_speedup=", snappedf(warm_speedup, 0.01),
		" quarantine_headroom=", quarantine_headroom,
		" created=", int(metrics.get("created", -1)),
		" peak_in_use=", int(metrics.get("peak_in_use", -1)),
		" inactive=", int(metrics.get("inactive", -1)),
		" overflow=", int(metrics.get("overflow", -1)),
		" dropped=", int(metrics.get("dropped", -1)),
		" stable_subtree_nodes=", stable_subtree_nodes
	)

	_expect(
		int(metrics.get("created", 0)) == peak_live_projectiles + quarantine_headroom,
		"A realistic same-frame release/spawn overlap must add only one frame of quarantine headroom."
	)
	_expect(
		int(metrics.get("peak_in_use", 0)) == peak_live_projectiles,
		"Pool metrics must observe the complete 720-projectile simultaneous window."
	)
	_expect(
		int(metrics.get("in_use", -1)) == 0
		and int(metrics.get("pending_release", -1)) == 0
		and int(metrics.get("inactive", -1)) == peak_live_projectiles + quarantine_headroom,
		"Every high-density lease must return to the retained pool after quarantine."
	)
	_expect(
		int(metrics.get("overflow", -1)) == 0
		and int(metrics.get("dropped", -1)) == 0,
		"The authored peak must neither overflow nor drop gameplay projectiles."
	)
	_expect(
		stable_subtree_nodes == 1 + (peak_live_projectiles + quarantine_headroom) * 3,
		"The steady pool subtree must contain one pool plus exactly three nodes per bullet."
	)

	current_scene = null
	fixture.queue_free()
	for _cleanup_frame in range(4):
		await process_frame
		await physics_frame
	if failures.is_empty():
		print("LINGLAN_SKILL1_POOL_PERFORMANCE_PROBE_OK")
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	quit(1)


func _measure_unpooled_lifecycle(total_projectiles: int) -> int:
	var started_usec := Time.get_ticks_usec()
	for projectile_index in range(total_projectiles):
		var bullet := SAKURA_BULLET_SCENE.instantiate() as LinglanSakuraBullet
		if bullet == null:
			failures.append("Unpooled baseline failed to instantiate a Sakura bullet.")
			break
		fixture.add_child(bullet)
		var angle := TAU * float(projectile_index % 20) / 20.0
		bullet.setup(
			Vector2.RIGHT.rotated(angle),
			SKILL1_CONFIG.projectile_damage,
			SKILL1_CONFIG.projectile_speed,
			SKILL1_CONFIG.projectile_lifetime
		)
		bullet.free()
	return Time.get_ticks_usec() - started_usec


func _measure_pooled_lifecycle(total_projectiles: int, batch_capacity: int) -> int:
	var remaining := total_projectiles
	var pooled_cpu_usec := 0
	var expected_subtree_nodes := -1
	var unique_instance_ids: Dictionary[int, bool] = {}
	var lease_index := 0
	while remaining > 0:
		var batch_size := mini(remaining, batch_capacity)
		var active: Array[LinglanSakuraBullet] = []
		active.resize(batch_size)
		var started_usec := Time.get_ticks_usec()
		for batch_index in range(batch_size):
			var bullet := pool.acquire(SAKURA_BULLET_SCENE) as LinglanSakuraBullet
			if bullet == null:
				failures.append("Elastic Skill1 pool unexpectedly dropped a gameplay lease.")
				active.resize(batch_index)
				break
			var angle := TAU * float(lease_index % 20) / 20.0
			bullet.setup(
				Vector2.RIGHT.rotated(angle),
				SKILL1_CONFIG.projectile_damage,
				SKILL1_CONFIG.projectile_speed,
				SKILL1_CONFIG.projectile_lifetime
			)
			active[batch_index] = bullet
			unique_instance_ids[bullet.get_instance_id()] = true
			lease_index += 1
		for bullet in active:
			if bullet != null:
				pool.release(bullet)
		pooled_cpu_usec += Time.get_ticks_usec() - started_usec
		await _wait_for_quarantine()
		var subtree_nodes := _count_subtree_nodes(pool)
		if expected_subtree_nodes < 0:
			expected_subtree_nodes = subtree_nodes
		else:
			_expect(
				subtree_nodes == expected_subtree_nodes,
				"Pool subtree node count must remain fixed after reaching the live working set."
			)
		remaining -= batch_size
	_expect(
		unique_instance_ids.size() == batch_capacity,
		"All 6,120 leases must cycle through only the 720-instance working set."
	)
	return pooled_cpu_usec


func _exercise_same_frame_release_and_spawn(
	peak_live_projectiles: int,
	projectiles_per_frame: int
) -> void:
	var active: Array[LinglanSakuraBullet] = []
	for _projectile_index in range(peak_live_projectiles):
		var bullet := pool.acquire(SAKURA_BULLET_SCENE) as LinglanSakuraBullet
		if bullet != null:
			active.append(bullet)
	_expect(
		active.size() == peak_live_projectiles,
		"Rolling quarantine fixture must acquire the complete live projectile window."
	)
	var replace_count := mini(projectiles_per_frame, active.size())
	for projectile_index in range(replace_count):
		pool.release(active[projectile_index])
	var replacements: Array[LinglanSakuraBullet] = []
	for _projectile_index in range(replace_count):
		var replacement := pool.acquire(SAKURA_BULLET_SCENE) as LinglanSakuraBullet
		if replacement != null:
			replacements.append(replacement)
	_expect(
		replacements.size() == replace_count,
		"Same-frame replacement must preserve every projectile while old leases are quarantined."
	)
	for projectile_index in range(replace_count, active.size()):
		pool.release(active[projectile_index])
	for replacement in replacements:
		pool.release(replacement)
	await _wait_for_quarantine()


func _count_subtree_nodes(node: Node) -> int:
	var total := 1
	for child in node.get_children():
		total += _count_subtree_nodes(child)
	return total


func _wait_for_quarantine() -> void:
	await physics_frame
	await process_frame
	await physics_frame
	await process_frame


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
