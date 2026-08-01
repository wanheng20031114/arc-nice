extends SceneTree

const TANGO_LASER_SCENE := preload(
	"res://scene/player/tango/tango_laser_bullet.tscn"
)

# Four default Electric Surge barrages: 29 volleys x three cannons, with every
# 0.722-second projectile receiving 44 physics sweeps at 60 Hz.
const TANGO_COUNT := 4
const VOLLEYS_PER_SURGE := 29
const PROJECTILES_PER_VOLLEY := 3
const SWEEPS_PER_PROJECTILE := 44
const PEAK_LIVE_PROJECTILES_PER_TANGO := 9
const PEAK_LIVE_PROJECTILES := TANGO_COUNT * PEAK_LIVE_PROJECTILES_PER_TANGO
const TOTAL_SWEEPS := (
	TANGO_COUNT
	* VOLLEYS_PER_SURGE
	* PROJECTILES_PER_VOLLEY
	* SWEEPS_PER_PROJECTILE
)
const WARMUP_SWEEPS := 512
const FIXED_DELTA := 1.0 / 60.0
const SAMPLE_ORDER := [false, true, true, false, false, true]

var failures: Array[String] = []
var fixture: Node2D = null
var bullets: Array[TangoLaserBullet] = []


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	fixture = Node2D.new()
	fixture.name = "TangoLaserSweepPerformanceAB"
	root.add_child(fixture)
	current_scene = fixture
	_spawn_peak_live_fixture()
	await process_frame
	await physics_frame

	_expect(
		bullets.size() == PEAK_LIVE_PROJECTILES,
		"A/B fixture must contain the four-Tango peak of 36 live projectiles."
	)
	if bullets.size() != PEAK_LIVE_PROJECTILES:
		await _finish()
		return

	TangoLaserBullet.set_sweep_performance_metrics_enabled(false)
	_run_sweeps(WARMUP_SWEEPS, false)
	_run_sweeps(WARMUP_SWEEPS, true)

	var baseline_times_usec: Array[int] = []
	var optimized_times_usec: Array[int] = []
	var baseline_positions := PackedVector2Array()
	var optimized_positions := PackedVector2Array()
	var baseline_metrics: Dictionary = {}
	var optimized_metrics: Dictionary = {}
	for fast_path_enabled in SAMPLE_ORDER:
		var sample := _measure_variant(bool(fast_path_enabled))
		if bool(fast_path_enabled):
			optimized_times_usec.append(int(sample.get("elapsed_usec", 0)))
			optimized_positions = sample.get(
				"positions",
				PackedVector2Array()
			) as PackedVector2Array
			optimized_metrics = sample.get("metrics", {}) as Dictionary
		else:
			baseline_times_usec.append(int(sample.get("elapsed_usec", 0)))
			baseline_positions = sample.get(
				"positions",
				PackedVector2Array()
			) as PackedVector2Array
			baseline_metrics = sample.get("metrics", {}) as Dictionary

	_assert_variant_metrics(baseline_metrics, false)
	_assert_variant_metrics(optimized_metrics, true)
	_expect(
		baseline_positions == optimized_positions
		and _position_checksum_is_expected(optimized_positions),
		(
			"Both algorithms must preserve every empty-path projectile position "
			+ "after the same number of production sweeps."
		)
	)

	var baseline_median_usec := _median_usec(baseline_times_usec)
	var optimized_median_usec := _median_usec(optimized_times_usec)
	var timing_ratio := (
		float(optimized_median_usec)
		/ maxf(float(baseline_median_usec), 1.0)
	)
	_expect(
		baseline_median_usec > 0 and optimized_median_usec > 0,
		"Both A/B variants must produce a finite timing sample."
	)
	print(
		"TANGO_LASER_SWEEP_PERFORMANCE_AB ",
		"tangos=", TANGO_COUNT,
		" volleys_per_tango=", VOLLEYS_PER_SURGE,
		" peak_live=", PEAK_LIVE_PROJECTILES,
		" sweeps=", TOTAL_SWEEPS,
		" baseline_samples_usec=", baseline_times_usec,
		" optimized_samples_usec=", optimized_times_usec,
		" baseline_median_usec=", baseline_median_usec,
		" optimized_median_usec=", optimized_median_usec,
		" optimized_to_baseline=", snappedf(timing_ratio, 0.001),
		" eliminated_hit_collections=",
		int(baseline_metrics.get("hit_collection_calls", 0))
		- int(optimized_metrics.get("hit_collection_calls", 0))
	)

	await _finish()


func _spawn_peak_live_fixture() -> void:
	for projectile_index in range(PEAK_LIVE_PROJECTILES):
		var bullet := TANGO_LASER_SCENE.instantiate() as TangoLaserBullet
		_expect(bullet != null, "Every A/B projectile must instantiate.")
		if bullet == null:
			continue
		bullet.setup(Vector2.RIGHT, 15, false)
		fixture.add_child(bullet)
		bullet.set_physics_process(false)
		bullets.append(bullet)


func _measure_variant(fast_path_enabled: bool) -> Dictionary:
	TangoLaserBullet.set_empty_sweep_fast_path_enabled(fast_path_enabled)
	TangoLaserBullet.reset_sweep_performance_metrics()
	TangoLaserBullet.set_sweep_performance_metrics_enabled(true)
	_reset_bullet_positions()
	var started_usec := Time.get_ticks_usec()
	_run_sweeps(TOTAL_SWEEPS, fast_path_enabled)
	var elapsed_usec := Time.get_ticks_usec() - started_usec
	return {
		"elapsed_usec": elapsed_usec,
		"metrics": TangoLaserBullet.get_sweep_performance_metrics(),
		"positions": _capture_bullet_positions(),
	}


func _run_sweeps(sweep_count: int, fast_path_enabled: bool) -> void:
	TangoLaserBullet.set_empty_sweep_fast_path_enabled(fast_path_enabled)
	for sweep_index in range(sweep_count):
		bullets[sweep_index % bullets.size()].call(
			"_sweep_segment",
			FIXED_DELTA
		)


func _reset_bullet_positions() -> void:
	for projectile_index in bullets.size():
		var bullet := bullets[projectile_index]
		bullet.global_position = Vector2(0.0, float(projectile_index) * 4.0)
		bullet.direction = Vector2.RIGHT
		bullet.rotation = 0.0


func _capture_bullet_positions() -> PackedVector2Array:
	var positions := PackedVector2Array()
	for bullet in bullets:
		positions.append(bullet.global_position)
	return positions


func _position_checksum_is_expected(positions: PackedVector2Array) -> bool:
	if positions.size() != PEAK_LIVE_PROJECTILES:
		return false
	var total_x := 0.0
	for position in positions:
		total_x += position.x
	var expected_total_x := (
		float(TOTAL_SWEEPS)
		* 480.0
		* FIXED_DELTA
	)
	return is_equal_approx(total_x, expected_total_x)


func _assert_variant_metrics(metrics: Dictionary, optimized: bool) -> void:
	_expect(
		int(metrics.get("sweep_calls", 0)) == TOTAL_SWEEPS
		and int(metrics.get("empty_collision_calls", 0)) == TOTAL_SWEEPS
		and int(metrics.get("collected_hit_count", -1)) == 0,
		"Both variants must execute the same number of genuinely empty ShapeCast sweeps."
	)
	if optimized:
		_expect(
			int(metrics.get("fast_path_calls", 0)) == TOTAL_SWEEPS
			and int(metrics.get("hit_collection_calls", -1)) == 0,
			"Optimized sweeps must bypass every temporary hit collection."
		)
		return
	_expect(
		int(metrics.get("fast_path_calls", -1)) == 0
		and int(metrics.get("hit_collection_calls", 0)) == TOTAL_SWEEPS,
		"Legacy sweeps must reconstruct the previous per-sweep hit-collection path."
	)


func _median_usec(samples: Array[int]) -> int:
	if samples.is_empty():
		return 0
	var sorted_samples := samples.duplicate()
	sorted_samples.sort()
	return sorted_samples[sorted_samples.size() / 2]


func _finish() -> void:
	TangoLaserBullet.set_sweep_performance_metrics_enabled(false)
	TangoLaserBullet.reset_sweep_performance_metrics()
	TangoLaserBullet.set_empty_sweep_fast_path_enabled(true)
	current_scene = null
	if fixture != null and is_instance_valid(fixture):
		fixture.queue_free()
	for _cleanup_frame in range(3):
		await process_frame
		await physics_frame
	if failures.is_empty():
		print("TANGO_LASER_SWEEP_PERFORMANCE_AB_OK")
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	quit(1)


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
