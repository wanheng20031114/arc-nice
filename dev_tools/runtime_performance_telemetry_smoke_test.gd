extends SceneTree

const TOWER_SCENE := preload("res://scene/game_modes/tower_defense/tower_defense_game.tscn")
const PERFORMANCE_CAMPAIGN := preload(
	"res://resources/config/campaigns/tower_defense/performance/campaign.tres"
)
const BULLET_SCENE := preload("res://scene/bullet.tscn")
const TANGO_LASER_BULLET_SCENE := preload(
	"res://scene/player/tango/tango_laser_bullet.tscn"
)
const FIRE_SORCERER_FIREBALL_VOLLEY_SCENE := preload(
	"res://scene/enemy/sorcerer/fire_sorcerer_fireball_volley.tscn"
)
const FIRE_SORCERER_ELITE_FIREBALL_VOLLEY_SCENE := preload(
	"res://scene/enemy/sorcerer/fire_sorcerer_elite_fireball_volley.tscn"
)
const FROST_SORCERER_ICE_SPIKE_SCENE := preload(
	"res://scene/enemy/sorcerer/frost_sorcerer_ice_spike.tscn"
)
const TELEMETRY_SCRIPT := preload("res://scene/runtime_performance_telemetry.gd")
const EXPECTED_WAVE_TOTAL := 1200
const EXPECTED_MAX_ALIVE := 300

var failures: Array[String] = []
var telemetry: Node = null
var game: TowerDefenseGame = null


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	telemetry = TELEMETRY_SCRIPT.new()
	root.add_child(telemetry)
	_verify_percentiles()
	_verify_player_bullet_lifetime()

	game = TOWER_SCENE.instantiate() as TowerDefenseGame
	_expect(game != null, "Telemetry pressure fixture must instantiate tower defense.")
	if game == null:
		await _finish()
		return

	game.auto_start_waves = false
	game.singleplayer_campaign = PERFORMANCE_CAMPAIGN
	root.add_child(game)
	await process_frame
	await physics_frame
	await _verify_runtime_classification()
	var preparation_started_msec := Time.get_ticks_msec()
	var preparation_last_tick_usec := Time.get_ticks_usec()
	var preparation_max_frame_ms := 0.0
	game.call("_schedule_enemy_navigation_prewarm")
	var preparation_frames := 0
	while not game.is_runtime_preparation_complete() and preparation_frames < 600:
		await process_frame
		var preparation_now_usec := Time.get_ticks_usec()
		preparation_max_frame_ms = maxf(
			preparation_max_frame_ms,
			float(preparation_now_usec - preparation_last_tick_usec) / 1000.0
		)
		preparation_last_tick_usec = preparation_now_usec
		preparation_frames += 1
	_expect(
		game.navigation_prewarmed and game.is_runtime_preparation_complete(),
		"Pressure telemetry must finish all staged runtime preparation before wave activation."
	)
	var preparation_elapsed_ms := Time.get_ticks_msec() - preparation_started_msec
	_expect(
		preparation_max_frame_ms < 75.0 and preparation_frames < 400,
		"Staged preparation must stay responsive and finish in a bounded frame count."
	)

	telemetry.reset()
	telemetry.count_sample_interval_seconds = 0.05
	telemetry.start(game)

	_expect(game.waves.size() == 12, "Telemetry pressure fixture requires twelve waves.")
	if game.waves.is_empty():
		await _finish()
		return
	var first_wave := game.waves[0]
	_expect(
		first_wave.get_total_enemy_count() == EXPECTED_WAVE_TOTAL,
		"Telemetry pressure fixture requires the 1200-enemy first wave."
	)
	_expect(
		first_wave.max_alive_enemies == EXPECTED_MAX_ALIVE,
		"Telemetry pressure fixture requires the 300-enemy active cap."
	)

	game.call("_begin_flow_step", first_wave)
	game.enemy_spawn_timer.stop()
	telemetry.sample_runtime_counts(game)
	var pressure_spawn_frames := 0
	while (
		game.current_wave_spawned < EXPECTED_MAX_ALIVE
		and pressure_spawn_frames < 600
	):
		var batch_started_usec: int = telemetry.begin_enemy_spawn_batch()
		game.call("_spawn_wave_batch")
		telemetry.end_enemy_spawn_batch(batch_started_usec)
		await process_frame
		pressure_spawn_frames += 1
	_expect(
		game.current_wave_spawned == EXPECTED_MAX_ALIVE,
		(
			"Pressure fixture must reach the 300-enemy cap within 600 frames; "
			+ "spawned %d."
		) % game.current_wave_spawned
	)

	var counts: Dictionary = telemetry.sample_runtime_counts(game)
	var summary: Dictionary = telemetry.get_summary()
	var frame_summary := summary["frame_time"] as Dictionary
	var spawn_summary := summary["enemy_spawn_batch"] as Dictionary
	var peak_summary := summary["peak"] as Dictionary
	_expect(
		int(counts["active_enemies"]) == EXPECTED_MAX_ALIVE,
		"Telemetry must report exactly 300 active pressure enemies."
	)
	_expect(
		int(counts["active_projectiles"]) == 0,
		"Spawn-only pressure telemetry must not invent projectiles."
	)
	_expect(
		int(peak_summary["active_enemies"]) == EXPECTED_MAX_ALIVE,
		"Telemetry peak enemy count must stop at the configured cap."
	)
	_expect(
		int(frame_summary["sample_count"]) >= 50,
		"Pressure telemetry must collect a useful frame-time distribution."
	)
	_expect(
		int(spawn_summary["sample_count"]) >= 250,
		"Pressure telemetry must collect the measured single-enemy spawn ticks."
	)
	_expect_percentile_order(frame_summary, "frame")
	_expect_percentile_order(spawn_summary, "spawn")
	_expect(
		float(frame_summary["p95_ms"]) < 50.0,
		"Prepared 300-enemy pressure p95 frame time must stay below 50ms."
	)
	_expect(
		float(frame_summary["p99_ms"]) < 250.0,
		"Prepared 300-enemy pressure p99 must not contain the former synchronous prewarm spike."
	)
	print(
		"TOWER_DEFENSE_PREPARATION elapsed_ms=%d staged_frames=%d max_frame_ms=%.3f"
		% [preparation_elapsed_ms, preparation_frames, preparation_max_frame_ms]
	)
	print(telemetry.format_summary("TOWER_DEFENSE_PRESSURE_TELEMETRY"))
	await _finish()


func _verify_percentiles() -> void:
	for sample in [1.0, 2.0, 3.0, 4.0, 100.0]:
		telemetry.record_frame_time_ms(sample)
		telemetry.record_enemy_spawn_batch_time_ms(sample * 2.0)
	var summary: Dictionary = telemetry.get_summary()
	var frame_summary := summary["frame_time"] as Dictionary
	var spawn_summary := summary["enemy_spawn_batch"] as Dictionary
	_expect(
		is_equal_approx(float(frame_summary["p50_ms"]), 3.0)
		and is_equal_approx(float(frame_summary["p95_ms"]), 100.0)
		and is_equal_approx(float(frame_summary["p99_ms"]), 100.0),
		"Telemetry must use deterministic nearest-rank frame percentiles."
	)
	_expect(
		is_equal_approx(float(spawn_summary["p50_ms"]), 6.0)
		and is_equal_approx(float(spawn_summary["p95_ms"]), 200.0)
		and is_equal_approx(float(spawn_summary["p99_ms"]), 200.0),
		"Telemetry must use deterministic nearest-rank spawn percentiles."
	)
	telemetry.reset()


func _verify_player_bullet_lifetime() -> void:
	var bullet := BULLET_SCENE.instantiate() as Bullet
	_expect(bullet != null, "Player projectile lifetime fixture must instantiate Bullet.")
	if bullet == null:
		return
	bullet.set_physics_process(false)
	root.add_child(bullet)
	_expect(
		is_equal_approx(bullet.max_lifetime, 1.083)
		and is_equal_approx(bullet.speed, 320.0)
		and is_equal_approx(bullet.max_lifetime * bullet.speed, 346.56),
		"Player bullets must keep a 1.083s / 346.56-world-pixel view-bounded envelope."
	)
	bullet._physics_process(bullet.max_lifetime)
	_expect(
		bullet.is_queued_for_deletion(),
		"Player bullets must deterministically release when their lifetime reaches zero."
	)


func _verify_runtime_classification() -> void:
	var bullet := BULLET_SCENE.instantiate() as Bullet
	_expect(bullet != null, "Telemetry classifier requires a projectile fixture.")
	if bullet == null:
		return

	bullet.set_physics_process(false)
	game.add_child(bullet)
	var tango_laser_bullet := TANGO_LASER_BULLET_SCENE.instantiate()
	_expect(
		tango_laser_bullet != null,
		"Telemetry classifier requires a Tango laser-bullet fixture."
	)
	if tango_laser_bullet != null:
		tango_laser_bullet.set_physics_process(false)
		game.add_child(tango_laser_bullet)
	var fire_sorcerer_volley := FIRE_SORCERER_FIREBALL_VOLLEY_SCENE.instantiate()
	_expect(
		fire_sorcerer_volley != null,
		"Telemetry classifier requires a Fire Sorcerer volley fixture."
	)
	if fire_sorcerer_volley != null:
		fire_sorcerer_volley.set_process(false)
		fire_sorcerer_volley.set_physics_process(false)
		game.add_child(fire_sorcerer_volley)
	var elite_fire_sorcerer_volley := (
		FIRE_SORCERER_ELITE_FIREBALL_VOLLEY_SCENE.instantiate()
	)
	_expect(
		elite_fire_sorcerer_volley != null,
		"Telemetry classifier requires an elite Fire Sorcerer volley fixture."
	)
	if elite_fire_sorcerer_volley != null:
		elite_fire_sorcerer_volley.set_process(false)
		elite_fire_sorcerer_volley.set_physics_process(false)
		game.add_child(elite_fire_sorcerer_volley)
	var frost_sorcerer_ice_spike := FROST_SORCERER_ICE_SPIKE_SCENE.instantiate()
	_expect(
		frost_sorcerer_ice_spike != null,
		"Telemetry classifier requires a Frost Sorcerer ice-spike fixture."
	)
	if frost_sorcerer_ice_spike != null:
		frost_sorcerer_ice_spike.set_process(false)
		frost_sorcerer_ice_spike.set_physics_process(false)
		game.add_child(frost_sorcerer_ice_spike)
		# Exercise the script-path fallback instead of passing only because the
		# authored scene is also tagged with the runtime-projectiles group.
		frost_sorcerer_ice_spike.remove_from_group(&"runtime_projectiles")
	var counts: Dictionary = telemetry.sample_runtime_counts(game)
	_expect(
		int(counts["active_projectiles"]) == 5,
		(
			"Telemetry must recognize player and Tango bullets, normal and elite "
			+ "Fire Sorcerer projectiles, plus the Frost Sorcerer ice spike."
		)
	)
	bullet.queue_free()
	if tango_laser_bullet != null:
		tango_laser_bullet.queue_free()
	if fire_sorcerer_volley != null:
		fire_sorcerer_volley.queue_free()
	if elite_fire_sorcerer_volley != null:
		elite_fire_sorcerer_volley.queue_free()
	if frost_sorcerer_ice_spike != null:
		frost_sorcerer_ice_spike.queue_free()
	await process_frame
	await physics_frame


func _expect_percentile_order(summary: Dictionary, label: String) -> void:
	var p50 := float(summary["p50_ms"])
	var p95 := float(summary["p95_ms"])
	var p99 := float(summary["p99_ms"])
	var maximum := float(summary["max_ms"])
	_expect(
		p50 <= p95 and p95 <= p99 and p99 <= maximum,
		"%s telemetry percentiles must be monotonic." % label
	)


func _finish() -> void:
	if telemetry != null:
		telemetry.stop()
	if game != null:
		game.queue_free()
	if telemetry != null:
		telemetry.queue_free()
	for _cleanup_frame in range(6):
		await process_frame
		await physics_frame
	if failures.is_empty():
		print("RUNTIME_PERFORMANCE_TELEMETRY_SMOKE_TEST_OK")
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	quit(1)


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
