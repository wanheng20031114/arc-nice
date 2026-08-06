extends SceneTree

const TOWER_SCENE := preload("res://scene/game_modes/tower_defense/tower_defense_game.tscn")
const EXPECTED_WAVE_TOTAL := 1200
const EXPECTED_MAX_ALIVE := 300

var failures: Array[String] = []
var xirang_reward_signal_count := 0


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	var game := TOWER_SCENE.instantiate() as TowerDefenseGame
	_expect(game != null, "Long-wave fixture must instantiate tower defense.")
	if game == null:
		_finish(0, 0)
		return
	game.auto_start_waves = false
	root.add_child(game)
	current_scene = game
	await process_frame
	await physics_frame
	game.call("_schedule_enemy_navigation_prewarm")
	var preparation_deadline := Time.get_ticks_msec() + 30000
	while not game.is_runtime_preparation_complete() and Time.get_ticks_msec() < preparation_deadline:
		await process_frame
	_expect(
		game.navigation_prewarmed and game.is_runtime_preparation_complete(),
		"Long-wave fixture must finish all staged runtime preparation."
	)
	if game.waves.is_empty():
		current_scene = null
		game.queue_free()
		_finish(0, 0)
		return

	# Build the pressure cohort explicitly. Formal campaign content is allowed to
	# change independently; relying on its first wave previously left this test in
	# an infinite `spawned < 1200` loop after that wave was reduced to 24 enemies.
	var authored_wave := game.waves[0]
	var fixture_enemy_config: EnemyConfig = null
	for authored_entry in authored_wave.enemy_entries:
		if authored_entry != null and authored_entry.enemy_config != null:
			fixture_enemy_config = authored_entry.enemy_config
			break
	_expect(fixture_enemy_config != null, "Long-wave fixture needs one authored enemy config.")
	if fixture_enemy_config == null:
		current_scene = null
		game.queue_free()
		_finish(0, 0)
		return
	var fixture_entry := WaveEnemyEntry.new()
	fixture_entry.enemy_config = fixture_enemy_config
	fixture_entry.count = EXPECTED_WAVE_TOTAL
	var first_wave := WaveConfig.new()
	first_wave.wave_name = "固定长波压力夹具"
	first_wave.enemy_entries = [fixture_entry]
	first_wave.spawn_point_mask = authored_wave.spawn_point_mask
	first_wave.spawn_order = WaveConfig.SpawnOrder.ENTRY_ROUND_ROBIN
	first_wave.spawn_interval = 0.025
	first_wave.spawn_count_per_tick = 4
	first_wave.max_alive_enemies = EXPECTED_MAX_ALIVE
	var expected_xirang_value := 0
	for entry in first_wave.enemy_entries:
		if entry != null and entry.enemy_config != null:
			expected_xirang_value += entry.count * entry.enemy_config.xirang_kill_reward
	_expect(first_wave.get_total_enemy_count() == EXPECTED_WAVE_TOTAL, "Long-wave total must be 1200.")
	_expect(first_wave.max_alive_enemies == EXPECTED_MAX_ALIVE, "Long-wave cap must be 300.")
	_expect(
		game.get_node_or_null("XirangDropManager") == null,
		"Tower-defense runtime must not retain the removed Xirang orb manager."
	)

	var started_msec := Time.get_ticks_msec()
	var initial_xirang := game.player.current_xirang
	game.player.xirang_changed.connect(_on_xirang_changed)
	game.call("_begin_flow_step", first_wave)
	game.enemy_spawn_timer.stop()
	var observed_peak_enemies := 0
	var cycle_guard := 0
	var death_loop_samples_ms: Array[float] = []
	var post_death_frame_samples_ms: Array[float] = []
	var worst_post_death_frame: Dictionary = {}
	while game.current_wave_spawned < EXPECTED_WAVE_TOTAL and cycle_guard < 8:
		while (
			game.current_wave_spawned < EXPECTED_WAVE_TOTAL
			and game.active_wave_enemy_ids.size() < EXPECTED_MAX_ALIVE
		):
			game.call("_spawn_wave_batch")
			observed_peak_enemies = maxi(
				observed_peak_enemies,
				game.active_wave_enemy_ids.size()
			)
			await process_frame
		_expect(
			game.active_wave_enemy_ids.size() <= EXPECTED_MAX_ALIVE,
			"Long-wave spawning must never exceed the live cap."
		)

		var enemies_to_defeat: Array[Enemy] = []
		for child in game.enemy_container.get_children():
			var enemy := child as Enemy
			if enemy != null and not enemy.is_dead:
				enemies_to_defeat.append(enemy)
		var death_loop_started_usec := Time.get_ticks_usec()
		for enemy in enemies_to_defeat:
			enemy.call("_die")
		death_loop_samples_ms.append(
			float(Time.get_ticks_usec() - death_loop_started_usec) / 1000.0
		)
		var clear_deadline := Time.get_ticks_msec() + 10000
		var previous_frame_tick_usec := Time.get_ticks_usec()
		var post_frame_index := 0
		while not game.active_wave_enemy_ids.is_empty() and Time.get_ticks_msec() < clear_deadline:
			var active_before := game.active_wave_enemy_ids.size()
			var children_before := game.enemy_container.get_child_count()
			await process_frame
			var current_frame_tick_usec := Time.get_ticks_usec()
			var frame_elapsed_ms := float(
				current_frame_tick_usec - previous_frame_tick_usec
			) / 1000.0
			post_death_frame_samples_ms.append(frame_elapsed_ms)
			if frame_elapsed_ms > float(worst_post_death_frame.get("elapsed_ms", -1.0)):
				worst_post_death_frame = {
					"tranche": cycle_guard + 1,
					"frame": post_frame_index,
					"elapsed_ms": frame_elapsed_ms,
					"active_before": active_before,
					"active_after": game.active_wave_enemy_ids.size(),
					"children_before": children_before,
					"children_after": game.enemy_container.get_child_count(),
					"player_xirang": game.player.current_xirang,
				}
			previous_frame_tick_usec = current_frame_tick_usec
			post_frame_index += 1
		_expect(
			game.active_wave_enemy_ids.is_empty(),
			"Every defeated 300-enemy tranche must leave the active registry."
		)
		cycle_guard += 1

	# Kill rewards are intentionally coalesced and settled once at frame end.
	await process_frame
	var elapsed_msec := Time.get_ticks_msec() - started_msec
	death_loop_samples_ms.sort()
	post_death_frame_samples_ms.sort()
	var death_loop_p95_ms: float = _percentile(death_loop_samples_ms, 0.95)
	var death_loop_max_ms: float = (
		death_loop_samples_ms.back() if not death_loop_samples_ms.is_empty() else 0.0
	)
	var post_death_p95_ms: float = _percentile(post_death_frame_samples_ms, 0.95)
	var post_death_max_ms: float = (
		post_death_frame_samples_ms.back()
		if not post_death_frame_samples_ms.is_empty()
		else 0.0
	)
	print(
		"LONG_WAVE_XIRANG_DIAGNOSTIC expected=%d granted=%d final=%d"
		% [
			expected_xirang_value,
			game.player.current_xirang - initial_xirang,
			game.player.current_xirang,
		]
	)
	print("LONG_WAVE_DEATH_WORST_FRAME %s" % str(worst_post_death_frame))
	print(
		(
			"LONG_WAVE_DEATH_PERFORMANCE tranches=%d death_loop_p95_ms=%.3f "
			+ "death_loop_max_ms=%.3f post_frames=%d post_death_p95_ms=%.3f "
			+ "post_death_max_ms=%.3f"
		)
		% [
			death_loop_samples_ms.size(),
			death_loop_p95_ms,
			death_loop_max_ms,
			post_death_frame_samples_ms.size(),
			post_death_p95_ms,
			post_death_max_ms,
		]
	)
	_expect(game.current_wave_spawned == EXPECTED_WAVE_TOTAL, "All 1200 enemies must spawn.")
	_expect(game.current_wave_defeated == EXPECTED_WAVE_TOTAL, "All 1200 enemies must resolve as defeated.")
	_expect(observed_peak_enemies == EXPECTED_MAX_ALIVE, "Long-wave peak enemy count must reach 300.")
	_expect(
		game.player.current_xirang == initial_xirang + expected_xirang_value,
		(
			"Long-wave deaths must grant the configured Xirang value directly: "
			+ "expected=%d granted=%d initial=%d final=%d"
			% [
				expected_xirang_value,
				game.player.current_xirang - initial_xirang,
				initial_xirang,
				game.player.current_xirang,
			]
		)
	)
	_expect(
		death_loop_samples_ms.size() == 4 and not post_death_frame_samples_ms.is_empty(),
		"Long-wave death benchmark must observe four 300-enemy tranches and deferred frames."
	)
	_expect(
		xirang_reward_signal_count == death_loop_samples_ms.size(),
		"Each 300-enemy tranche must settle through one aggregated Xirang change signal."
	)
	var granted_xirang := game.player.current_xirang - initial_xirang
	current_scene = null
	game.queue_free()
	for _cleanup_frame in range(6):
		await process_frame
	_finish(elapsed_msec, granted_xirang)


func _on_xirang_changed(_total: int, added_amount: int) -> void:
	if added_amount > 0:
		xirang_reward_signal_count += 1


func _finish(elapsed_msec: int, granted_xirang: int) -> void:
	if failures.is_empty():
		print(
			"GAME_TOWER_DEFENSE_LONG_WAVE_SMOKE_TEST_OK enemies=1200 granted_xirang=%d elapsed_ms=%d"
			% [granted_xirang, elapsed_msec]
		)
		quit()
		return
	for failure in failures:
		push_error(failure)
	quit(1)


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)


func _percentile(sorted_samples: Array[float], ratio: float) -> float:
	if sorted_samples.is_empty():
		return 0.0
	var rank := ceili(clampf(ratio, 0.0, 1.0) * sorted_samples.size())
	return sorted_samples[clampi(rank - 1, 0, sorted_samples.size() - 1)]
