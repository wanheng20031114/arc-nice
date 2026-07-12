extends SceneTree

const TOWER_SCENE := preload("res://scene/game_tower_defense.tscn")
const EXPECTED_WAVE_TOTAL := 1200
const EXPECTED_MAX_ALIVE := 300

var failures: Array[String] = []


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	var game := TOWER_SCENE.instantiate() as GameTowerDefense
	_expect(game != null, "Tower-defense pressure scene must instantiate.")
	if game == null:
		_finish(0)
		return

	game.auto_start_waves = false
	root.add_child(game)
	await process_frame
	await physics_frame

	_expect(not game.linglan_boss_enabled, "Pressure Campaign must keep Linglan disabled.")
	_expect(game.bosses.is_empty(), "Pressure Campaign must not contain a Boss step.")
	_expect(game.waves.size() == 12, "Pressure Campaign must contain twelve waves.")
	if game.waves.is_empty():
		game.queue_free()
		await process_frame
		_finish(0)
		return

	var first_wave := game.waves[0]
	_expect(
		first_wave.get_total_enemy_count() == EXPECTED_WAVE_TOTAL,
		"Pressure wave must queue exactly 1200 enemies."
	)
	_expect(
		first_wave.max_alive_enemies == EXPECTED_MAX_ALIVE,
		"Pressure wave simultaneous-enemy cap must be 300."
	)

	var started_at_msec := Time.get_ticks_msec()
	game.call("_begin_flow_step", first_wave)
	game.enemy_spawn_timer.stop()
	for _batch_index in range(100):
		game.call("_spawn_wave_batch")
	var fill_elapsed_msec := Time.get_ticks_msec() - started_at_msec

	_expect(game.current_wave_total == EXPECTED_WAVE_TOTAL, "Runtime queue total must stay at 1200.")
	_expect(game.current_wave_spawned == EXPECTED_MAX_ALIVE, "Runtime must fill exactly 300 slots.")
	_expect(
		game.active_wave_enemy_ids.size() == EXPECTED_MAX_ALIVE,
		"Active enemy registry must stop exactly at 300."
	)
	_expect(
		game.enemy_container.get_child_count() == EXPECTED_MAX_ALIVE,
		"EnemyContainer must contain exactly 300 live enemies at the cap."
	)
	_expect(
		game.pending_enemy_config_index == EXPECTED_MAX_ALIVE,
		"Spawn queue must retain the remaining 900 enemies after reaching the cap."
	)

	for _blocked_batch_index in range(20):
		game.call("_spawn_wave_batch")
	_expect(
		game.current_wave_spawned == EXPECTED_MAX_ALIVE
		and game.active_wave_enemy_ids.size() == EXPECTED_MAX_ALIVE,
		"Additional spawn ticks must never exceed the 300-enemy hard cap."
	)

	game.queue_free()
	for _cleanup_frame in range(4):
		await process_frame
	_finish(fill_elapsed_msec)


func _finish(fill_elapsed_msec: int) -> void:
	if failures.is_empty():
		print(
			"GAME_TOWER_DEFENSE_PRESSURE_SMOKE_TEST_OK enemies=300 fill_ms=%d"
			% fill_elapsed_msec
		)
		quit()
		return
	for failure in failures:
		push_error(failure)
	quit(1)


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
