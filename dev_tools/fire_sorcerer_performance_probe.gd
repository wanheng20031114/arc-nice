extends SceneTree

# Focused CPU/lifecycle pressure probe. It drives the real SessionObjectPool
# acquisition/release path while manually timing gameplay callbacks. Pool lease
# metrics include roots that have no live balls but still own expiry visuals.
const FIRE_SORCERER_SCENE := preload(
	"res://scene/enemy/sorcerer/fire_sorcerer.tscn"
)
const FIREBALL_VOLLEY_SCENE := preload(
	"res://scene/enemy/sorcerer/fire_sorcerer_fireball_volley.tscn"
)
const FIRE_SORCERER_CONFIG := preload(
	"res://resources/config/enemies/fire_sorcerer.tres"
)
const PLAYER_SCENE := preload(
	"res://scene/player/weishidaier/player_weishidaier.tscn"
)

const ENEMY_COUNT := 300
const STEADY_VOLLEY_COUNT := ENEMY_COUNT * 2
const BALLS_PER_VOLLEY := 3
const POOL_PREWARM_COUNT := 48
# The third volley starts 7.2 s after the first (0.6 windup + 3.0 cooldown).
# A 7 s flight plus expiry visuals therefore creates a short three-generation
# lease overlap; 0.9 s staggering and one-frame quarantine stay below 704.
const POOL_RETAINED_CAPACITY := 704
const COHORT_SAMPLE_FRAMES := 540
const VOLLEY_SAMPLE_FRAMES := 240
const WARMUP_FRAMES := 12
const REAL_FRAME_BASELINE_SAMPLES := 60
const REAL_FRAME_ACTIVE_SAMPLES := 120
const TEST_DELTA := 1.0 / 60.0
const FRAME_BUDGET_60_FPS_MS := 1000.0 / 60.0

var failures: Array[String] = []
var fixture: PoolRuntimeFixture = null
var object_pool: SessionObjectPool = null
var player: Player = null
var tracked_volleys: Array[FireSorcererFireballVolley] = []


class PoolRuntimeFixture:
	extends Node2D

	var session_object_pool: SessionObjectPool = null

	func install_pool() -> SessionObjectPool:
		session_object_pool = SessionObjectPool.new()
		session_object_pool.name = "SessionObjectPool"
		add_child(session_object_pool)
		return session_object_pool

	func has_session_object_pool_scene(scene: PackedScene) -> bool:
		return (
			session_object_pool != null
			and session_object_pool.is_registered(scene)
		)

	func acquire_session_object(
		scene: PackedScene,
		strict: bool = false
	) -> Node:
		if not has_session_object_pool_scene(scene):
			return null
		return (
			session_object_pool.try_acquire(scene)
			if strict
			else session_object_pool.acquire(scene)
		)


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	# This retained probe loads the retired Area2D fixture directly as an isolated
	# baseline. DATA acceptance lives in fire_sorcerer_data_performance_probe.gd.
	fixture = PoolRuntimeFixture.new()
	fixture.name = "FireSorcererPerformanceProbe"
	root.add_child(fixture)
	current_scene = fixture
	object_pool = fixture.install_pool()
	object_pool.child_entered_tree.connect(_on_pool_child_entered_tree)
	object_pool.register_scene(
		FIREBALL_VOLLEY_SCENE,
		POOL_PREWARM_COUNT,
		POOL_RETAINED_CAPACITY
	)
	var startup_pool_metrics := object_pool.get_metrics(
		FIREBALL_VOLLEY_SCENE.resource_path
	)
	_expect(
		int(startup_pool_metrics.get("created", -1)) == POOL_PREWARM_COUNT
		and int(startup_pool_metrics.get("inactive", -1))
			== POOL_PREWARM_COUNT
		and int(startup_pool_metrics.get("retained_capacity", -1))
			== POOL_RETAINED_CAPACITY,
		"Focused probe must use the production 48/704 volley pool contract."
	)
	player = _spawn_collisionless_target(Vector2(620.0, 0.0))
	await physics_frame

	var baseline_real_samples := await _sample_real_physics_frames(
		REAL_FRAME_BASELINE_SAMPLES
	)
	var cohort_result: Dictionary = (
		await _measure_synchronized_300_enemy_cohort()
	)
	await process_frame
	var volley_result: Dictionary = await _measure_600_concurrent_volleys()
	var active_real_samples := await _sample_real_physics_frames(
		REAL_FRAME_ACTIVE_SAMPLES
	)

	var baseline_p95_ms := _percentile(baseline_real_samples, 0.95)
	var active_real_p95_ms := _percentile(active_real_samples, 0.95)
	var active_real_increment_ms := maxf(
		active_real_p95_ms - baseline_p95_ms,
		0.0
	)
	print(
		(
			"FIRE_SORCERER_PERFORMANCE enemies=%d steady_volleys=%d "
			+ "steady_balls=%d cohort_p50_ms=%.3f cohort_p95_ms=%.3f "
			+ "cohort_p99_ms=%.3f cohort_max_ms=%.3f "
			+ "cohort_spawn_spikes_over_budget=%d "
			+ "cohort_peak_active_roots=%d cohort_peak_lease_roots=%d "
			+ "cohort_peak_visual_only_roots=%d cohort_pool_created=%d "
			+ "cohort_pool_headroom=%d cohort_pool_pending_peak=%d "
			+ "cohort_pool_overflow=%d "
			+ "cohort_min_actions=%d cohort_max_actions=%d "
			+ "volley_p50_ms=%.3f volley_p95_ms=%.3f volley_p99_ms=%.3f "
			+ "volley_max_ms=%.3f volley_avg_callback_usec=%.3f "
			+ "reuse_created_before=%d reuse_created_after=%d "
			+ "reuse_overflow_delta=%d "
			+ "baseline_real_p95_ms=%.3f active_real_p95_ms=%.3f "
			+ "active_real_increment_ms=%.3f nodes=%d"
		)
		% [
			ENEMY_COUNT,
			STEADY_VOLLEY_COUNT,
			STEADY_VOLLEY_COUNT * BALLS_PER_VOLLEY,
			float(cohort_result["p50_ms"]),
			float(cohort_result["p95_ms"]),
			float(cohort_result["p99_ms"]),
			float(cohort_result["max_ms"]),
			int(cohort_result["over_budget_frames"]),
			int(cohort_result["peak_active_roots"]),
			int(cohort_result["peak_lease_roots"]),
			int(cohort_result["peak_visual_only_roots"]),
			int(cohort_result["pool_created"]),
			POOL_RETAINED_CAPACITY - int(cohort_result["pool_created"]),
			int(cohort_result["pool_pending_peak"]),
			int(cohort_result["pool_overflow"]),
			int(cohort_result["min_actions"]),
			int(cohort_result["max_actions"]),
			float(volley_result["p50_ms"]),
			float(volley_result["p95_ms"]),
			float(volley_result["p99_ms"]),
			float(volley_result["max_ms"]),
			float(volley_result["average_callback_usec"]),
			int(volley_result["pool_created_before"]),
			int(volley_result["pool_created_after"]),
			int(volley_result["pool_overflow_delta"]),
			baseline_p95_ms,
			active_real_p95_ms,
			active_real_increment_ms,
			_count_nodes_recursive(fixture),
		]
	)

	_expect(
		float(cohort_result["p95_ms"]) < FRAME_BUDGET_60_FPS_MS,
		"300 synchronized Fire Sorcerers must keep isolated p95 below 16.67 ms."
	)
	_expect(
		int(cohort_result["peak_active_roots"]) >= STEADY_VOLLEY_COUNT,
		"300-enemy lifecycle must reach at least 600 roots with live balls."
	)
	_expect(
		int(cohort_result["peak_visual_only_roots"]) > 0
		and int(cohort_result["peak_lease_roots"])
			> int(cohort_result["peak_active_roots"]),
		"Lease peak must include roots retained solely for expiry visuals."
	)
	_expect(
		int(cohort_result["peak_lease_roots"]) <= POOL_RETAINED_CAPACITY
		and int(cohort_result["pool_created"]) <= POOL_RETAINED_CAPACITY
		and int(cohort_result["pool_overflow"]) == 0,
		"Repeated 300-enemy rounds must stay inside the 704 retained leases."
	)
	_expect(
		int(cohort_result["min_actions"]) == 6
		and int(cohort_result["max_actions"]) == 6,
		"Every Fire Sorcerer must complete all three measured attack rounds."
	)
	_expect(
		float(volley_result["p95_ms"]) < FRAME_BUDGET_60_FPS_MS,
		"600 homing volleys / 1800 balls must keep isolated p95 below 16.67 ms."
	)
	_expect(
		active_real_increment_ms < FRAME_BUDGET_60_FPS_MS,
		"PhysicsServer plus live Area2D overhead must add less than one 60 FPS frame."
	)
	_expect(
		int(volley_result["pool_created_after"])
			== int(volley_result["pool_created_before"])
		and int(volley_result["pool_overflow_delta"]) == 0,
		"A later 600-root round must reuse retained leases without recurring growth."
	)

	FireSorcererFireballVolley.set_performance_metrics_enabled(false)
	current_scene = null
	fixture.queue_free()
	await process_frame
	await physics_frame
	for _cleanup_frame in range(6):
		await process_frame
	if failures.is_empty():
		print("FIRE_SORCERER_LEGACY_PERFORMANCE_BASELINE_OK")
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	quit(1)


func _measure_synchronized_300_enemy_cohort() -> Dictionary:
	var enemies: Array[FireSorcerer] = []
	for enemy_index in range(ENEMY_COUNT):
		var enemy := (
			FIRE_SORCERER_SCENE.instantiate()
			as FireSorcerer
		)
		fixture.add_child(enemy)
		var row := enemy_index / 30
		var column := enemy_index % 30
		enemy.global_position = Vector2(
			float(column - 15) * 2.0,
			float(row - 5) * 2.0
		)
		enemy.setup(FIRE_SORCERER_CONFIG, player, null)
		enemy.set_physics_process(false)
		enemies.append(enemy)

	var first_attack_buckets := {}
	for enemy in enemies:
		first_attack_buckets[
			roundi(
				enemy.initial_attack_stagger_left
				* float(Engine.physics_ticks_per_second)
			)
		] = true
		_expect(
			is_zero_approx(enemy.attack_cooldown_left),
			"First-attack staggering must not masquerade as post-volley cooldown."
		)
	_expect(
		first_attack_buckets.size() == ceili(
			FIRE_SORCERER_CONFIG.initial_attack_stagger_window
				* float(Engine.physics_ticks_per_second)
		),
		"300 Fire Sorcerers must cover every deterministic first-attack bucket."
	)

	for _warmup_index in range(WARMUP_FRAMES):
		# Advance the real physics frame so the production six-frame staggered
		# ranged-LOS cache services every phase of the 300-enemy cohort.
		await physics_frame
		for enemy in enemies:
			enemy.call("_physics_process", TEST_DELTA)
		_step_tracked_volleys(TEST_DELTA)

	var samples_ms: Array[float] = []
	var peak_active_roots := 0
	var peak_visual_only_roots := 0
	var peak_lease_roots := 0
	var pool_pending_peak := 0
	var over_budget_frames := 0
	var lease_metric_mismatch := false
	for _frame_index in range(COHORT_SAMPLE_FRAMES):
		await physics_frame
		var started_usec := Time.get_ticks_usec()
		for enemy in enemies:
			enemy.call("_physics_process", TEST_DELTA)
		_step_tracked_volleys(TEST_DELTA)
		var elapsed_ms := float(
			Time.get_ticks_usec() - started_usec
		) / 1000.0
		samples_ms.append(elapsed_ms)
		if elapsed_ms >= FRAME_BUDGET_60_FPS_MS:
			over_budget_frames += 1
		var current_active_roots := _count_live_tracked_volleys()
		var current_visual_only_roots := (
			_count_visual_only_tracked_volleys()
		)
		var current_lease_roots := _count_leased_tracked_volleys()
		var current_pool_metrics := object_pool.get_metrics(
			FIREBALL_VOLLEY_SCENE.resource_path
		)
		peak_active_roots = maxi(
			peak_active_roots,
			current_active_roots
		)
		peak_visual_only_roots = maxi(
			peak_visual_only_roots,
			current_visual_only_roots
		)
		peak_lease_roots = maxi(
			peak_lease_roots,
			int(current_pool_metrics.get("peak_in_use", 0))
		)
		pool_pending_peak = maxi(
			pool_pending_peak,
			int(current_pool_metrics.get("pending_release", 0))
		)
		if int(current_pool_metrics.get("in_use", -1)) != current_lease_roots:
			lease_metric_mismatch = true

	samples_ms.sort()
	var final_pool_metrics := object_pool.get_metrics(
		FIREBALL_VOLLEY_SCENE.resource_path
	)
	var minimum_actions := 1_000_000
	var maximum_actions := 0
	for enemy in enemies:
		minimum_actions = mini(minimum_actions, enemy.action_sequence)
		maximum_actions = maxi(maximum_actions, enemy.action_sequence)
	for enemy in enemies:
		enemy.queue_free()
	_expect(
		not lease_metric_mismatch,
		"SessionObjectPool in_use metrics must match live pool_active roots."
	)
	_expect(
		int(final_pool_metrics.get("dropped", -1)) == 0,
		"Elastic Fire Sorcerer projectile leases must never be dropped."
	)
	for volley in tracked_volleys:
		if volley == null or not is_instance_valid(volley):
			continue
		_expect(
			volley.get_parent() == object_pool
			and int(volley.get_meta(
				SessionObjectPool.POOL_OWNER_META,
				0
			)) == object_pool.get_instance_id(),
			"Every measured volley must be a real SessionObjectPool-owned lease."
		)
	return {
		"p50_ms": _percentile(samples_ms, 0.50),
		"p95_ms": _percentile(samples_ms, 0.95),
		"p99_ms": _percentile(samples_ms, 0.99),
		"max_ms": samples_ms.back() if not samples_ms.is_empty() else 0.0,
		"over_budget_frames": over_budget_frames,
		"peak_active_roots": peak_active_roots,
		"peak_lease_roots": peak_lease_roots,
		"peak_visual_only_roots": peak_visual_only_roots,
		"pool_created": int(final_pool_metrics.get("created", -1)),
		"pool_pending_peak": pool_pending_peak,
		"pool_overflow": int(final_pool_metrics.get("overflow", -1)),
		"min_actions": minimum_actions,
		"max_actions": maximum_actions,
	}


func _measure_600_concurrent_volleys() -> Dictionary:
	await _release_all_volley_leases()
	var pool_metrics_before := object_pool.get_metrics(
		FIREBALL_VOLLEY_SCENE.resource_path
	)
	_expect(
		int(pool_metrics_before.get("in_use", -1)) == 0
		and int(pool_metrics_before.get("pending_release", -1)) == 0,
		"Prior attack rounds must fully return their volley leases."
	)
	var leased_volleys: Array[FireSorcererFireballVolley] = []
	for volley_index in range(STEADY_VOLLEY_COUNT):
		var volley := (
			fixture.acquire_session_object(
				FIREBALL_VOLLEY_SCENE,
				false
			)
			as FireSorcererFireballVolley
		)
		_expect(
			volley != null,
			"Real pool must acquire all 600 high-concurrency volley leases."
		)
		if volley == null:
			continue
		volley.top_level = true
		var row := volley_index / 30
		var column := volley_index % 30
		volley.global_position = Vector2(
			float(column - 15) * 2.0,
			float(row - 10) * 2.0
		)
		volley.setup(
			Vector2.RIGHT,
			FIRE_SORCERER_CONFIG.attack_damage,
			FIRE_SORCERER_CONFIG.projectile_speed,
			FIRE_SORCERER_CONFIG.projectile_lifetime,
			player,
			FIRE_SORCERER_CONFIG.homing_turn_rate
		)
		volley.set_physics_process(false)
		leased_volleys.append(volley)

	var pool_metrics_after_acquire := object_pool.get_metrics(
		FIREBALL_VOLLEY_SCENE.resource_path
	)
	_expect(
		leased_volleys.size() == STEADY_VOLLEY_COUNT
		and int(pool_metrics_after_acquire.get("in_use", -1))
			== STEADY_VOLLEY_COUNT,
		"High-concurrency fixture must hold exactly 600 real pool leases."
	)
	FireSorcererFireballVolley.set_performance_metrics_enabled(true)
	var samples_ms: Array[float] = []
	for _frame_index in range(VOLLEY_SAMPLE_FRAMES):
		var started_usec := Time.get_ticks_usec()
		for volley in leased_volleys:
			volley.call("_physics_process", TEST_DELTA)
		samples_ms.append(
			float(Time.get_ticks_usec() - started_usec) / 1000.0
		)
	samples_ms.sort()
	var metrics := FireSorcererFireballVolley.get_performance_metrics()
	var expected_callbacks := STEADY_VOLLEY_COUNT * VOLLEY_SAMPLE_FRAMES
	var expected_ball_steps := expected_callbacks * BALLS_PER_VOLLEY
	_expect(
		int(metrics["physics_calls"]) == expected_callbacks,
		"Volley telemetry must count one callback per root per simulated frame."
	)
	_expect(
		int(metrics["active_ball_steps"]) == expected_ball_steps
		and int(metrics["homing_updates"]) == expected_ball_steps,
		"600 volleys must update exactly 1800 live homing balls per frame."
	)
	var average_callback_usec := (
		float(metrics["physics_usec"])
		/ float(maxi(int(metrics["physics_calls"]), 1))
	)

	# Keep the same live nodes for real PhysicsServer frame sampling.
	for volley in leased_volleys:
		volley.set_physics_process(true)
	var pool_metrics_after := object_pool.get_metrics(
		FIREBALL_VOLLEY_SCENE.resource_path
	)
	return {
		"p50_ms": _percentile(samples_ms, 0.50),
		"p95_ms": _percentile(samples_ms, 0.95),
		"p99_ms": _percentile(samples_ms, 0.99),
		"max_ms": samples_ms.back() if not samples_ms.is_empty() else 0.0,
		"average_callback_usec": average_callback_usec,
		"pool_created_before": int(pool_metrics_before.get("created", -1)),
		"pool_created_after": int(pool_metrics_after.get("created", -1)),
		"pool_overflow_delta": (
			int(pool_metrics_after.get("overflow", -1))
			- int(pool_metrics_before.get("overflow", -1))
		),
	}


func _step_tracked_volleys(delta: float) -> void:
	for volley in tracked_volleys:
		if (
			volley != null
			and is_instance_valid(volley)
			and volley.pool_active
		):
			# Volley setup happens before add_child(). Godot finalizes the
			# process flag while entering the tree, after child_entered_tree may
			# already have tried to disable it. Enforce one manual driver here.
			if volley.is_physics_processing():
				volley.set_physics_process(false)
			volley.call("_physics_process", delta)


func _count_live_tracked_volleys() -> int:
	var count := 0
	for volley in tracked_volleys:
		if (
			volley != null
			and is_instance_valid(volley)
			and volley.pool_active
			and volley.active_ball_mask != 0
		):
			count += 1
	return count


func _count_visual_only_tracked_volleys() -> int:
	var count := 0
	for volley in tracked_volleys:
		if (
			volley != null
			and is_instance_valid(volley)
			and volley.pool_active
			and volley.active_ball_mask == 0
			and volley.visible_effect_mask != 0
		):
			count += 1
	return count


func _count_leased_tracked_volleys() -> int:
	var count := 0
	for volley in tracked_volleys:
		if (
			volley != null
			and is_instance_valid(volley)
			and bool(volley.get_meta(
				SessionObjectPool.POOL_ACTIVE_META,
				false
			))
		):
			count += 1
	return count


func _release_all_volley_leases() -> void:
	for volley in tracked_volleys:
		if (
			volley == null
			or not is_instance_valid(volley)
			or not bool(volley.get_meta(
				SessionObjectPool.POOL_ACTIVE_META,
				false
			))
		):
			continue
		_expect(
			object_pool.release(volley),
			"Every active volley lease must return through SessionObjectPool."
		)
	for _quarantine_frame in range(3):
		await physics_frame
		await process_frame


func _on_pool_child_entered_tree(child: Node) -> void:
	var volley := child as FireSorcererFireballVolley
	if volley == null:
		return
	volley.set_physics_process(false)
	tracked_volleys.append(volley)


func _spawn_collisionless_target(position: Vector2) -> Player:
	var target := PLAYER_SCENE.instantiate() as Player
	fixture.add_child(target)
	target.global_position = position
	target.collision_layer = 0
	target.collision_mask = 0
	target.invincibility_duration = 0.0
	target.set_physics_process(false)
	target.set_process(false)
	return target


func _sample_real_physics_frames(sample_count: int) -> Array[float]:
	var samples_ms: Array[float] = []
	var previous_usec := Time.get_ticks_usec()
	for _sample_index in range(sample_count):
		await physics_frame
		var current_usec := Time.get_ticks_usec()
		samples_ms.append(float(current_usec - previous_usec) / 1000.0)
		previous_usec = current_usec
	samples_ms.sort()
	return samples_ms


func _percentile(sorted_values: Array[float], ratio: float) -> float:
	if sorted_values.is_empty():
		return 0.0
	var rank := ceili(
		clampf(ratio, 0.0, 1.0) * float(sorted_values.size())
	)
	return sorted_values[clampi(rank - 1, 0, sorted_values.size() - 1)]


func _count_nodes_recursive(node: Node) -> int:
	var count := 1
	for child in node.get_children():
		count += _count_nodes_recursive(child)
	return count


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
