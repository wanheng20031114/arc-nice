extends SceneTree

const GAME_SCENE := preload("res://scene/game.tscn")
const BASIC_CONFIG := preload("res://resources/config/enemies/yuanshi_insect_basic.tres")
const TEST_QUEUE_SIZE := 1000

var failures: Array[String] = []


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	var game := GAME_SCENE.instantiate() as Game
	game.auto_start_waves = false
	root.add_child(game)
	current_scene = game
	await process_frame
	await physics_frame

	var wave := WaveConfig.new()
	var entry := WaveEnemyEntry.new()
	entry.enemy_config = BASIC_CONFIG
	entry.count = TEST_QUEUE_SIZE
	var entries: Array[WaveEnemyEntry] = [entry]
	wave.enemy_entries = entries

	game.call("_build_wave_spawn_queue", wave)
	_expect(game.pending_enemy_configs.size() == TEST_QUEUE_SIZE, "Wave spawn queue must keep the full shuffled array.")
	_expect(game.pending_enemy_config_index == 0, "Wave spawn queue cursor must start at zero.")
	_expect(bool(game.call("_has_pending_enemy_configs")), "Wave spawn queue must report pending items at the start.")

	game.pending_enemy_config_index = TEST_QUEUE_SIZE - 1
	_expect(bool(game.call("_has_pending_enemy_configs")), "Wave spawn queue must still have the final pending item.")
	_expect(game.pending_enemy_configs[game.pending_enemy_config_index] == BASIC_CONFIG, "Wave spawn queue cursor must read the current item without shifting the array.")

	game.pending_enemy_config_index = TEST_QUEUE_SIZE
	_expect(not bool(game.call("_has_pending_enemy_configs")), "Wave spawn queue must be empty when the cursor reaches the array size.")
	game.call("_clear_pending_enemy_spawn_queue")
	_expect(game.pending_enemy_configs.is_empty(), "Wave spawn queue clear must release the backing array.")
	_expect(game.pending_enemy_config_index == 0, "Wave spawn queue clear must reset the cursor.")

	game.queue_free()
	await process_frame
	await physics_frame

	if failures.is_empty():
		print("WAVE_SPAWN_QUEUE_CURSOR_SMOKE_TEST_OK")
		quit()
		return

	for failure in failures:
		push_error(failure)
	quit(1)


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
