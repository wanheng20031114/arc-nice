extends SceneTree

const GAME_SCENE := preload("res://scene/game_modes/standard/standard_game.tscn")
const TEST_QUEUE_SIZE := 1000

var failures: Array[String] = []


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	var game := GAME_SCENE.instantiate() as StandardGame
	game.auto_start_waves = false
	root.add_child(game)
	current_scene = game
	await process_frame
	await physics_frame

	var inherited_config := EnemyConfig.new()
	inherited_config.xirang_kill_reward = 7
	var zero_override_config := EnemyConfig.new()
	zero_override_config.xirang_kill_reward = 13
	var positive_override_config := EnemyConfig.new()
	positive_override_config.xirang_kill_reward = 19

	var inherited_entry := WaveEnemyEntry.new()
	inherited_entry.enemy_config = inherited_config
	inherited_entry.count = TEST_QUEUE_SIZE - 2
	var zero_override_entry := WaveEnemyEntry.new()
	zero_override_entry.enemy_config = zero_override_config
	zero_override_entry.xirang_kill_reward_override = 0
	var positive_override_entry := WaveEnemyEntry.new()
	positive_override_entry.enemy_config = positive_override_config
	positive_override_entry.xirang_kill_reward_override = 31
	var entries: Array[WaveEnemyEntry] = [
		inherited_entry,
		zero_override_entry,
		positive_override_entry,
	]
	var wave := WaveConfig.new()
	wave.enemy_entries = entries
	_expect(
		wave.spawn_order == WaveConfig.SpawnOrder.SHUFFLED,
		"Wave spawn queues must keep shuffled ordering as their default."
	)

	_expect(
		inherited_entry.resolve_xirang_kill_reward() == 7,
		"A negative wave override must inherit the resolved enemy config reward."
	)
	_expect(
		zero_override_entry.resolve_xirang_kill_reward() == 0,
		"A zero wave override must remain an explicit zero reward."
	)
	_expect(
		positive_override_entry.resolve_xirang_kill_reward() == 31,
		"A positive wave override must replace the enemy config reward."
	)
	var fate_replacement_config := EnemyConfig.new()
	fate_replacement_config.xirang_kill_reward = 23
	_expect(
		inherited_entry.resolve_xirang_kill_reward(fate_replacement_config) == 23,
		"Inherited rewards must follow the resolved fate replacement config."
	)

	var reward_probe := Enemy.new()
	reward_probe.config = inherited_config
	_expect(
		reward_probe.get_effective_xirang_kill_reward() == 7,
		"Enemy instances must inherit their config reward by default."
	)
	reward_probe.set_xirang_kill_reward_override(0)
	_expect(
		reward_probe.get_xirang_kill_reward_override() == 0
		and reward_probe.get_effective_xirang_kill_reward() == 0,
		"Enemy instances must preserve an explicit zero reward override."
	)
	reward_probe.set_xirang_kill_reward_override(31)
	_expect(
		reward_probe.get_effective_xirang_kill_reward() == 31,
		"Enemy instances must expose their positive effective reward override."
	)
	reward_probe.free()

	game.random_generator.seed = 0x71A4
	game.call("_build_wave_spawn_queue", wave)
	_expect(game.pending_enemy_configs.size() == TEST_QUEUE_SIZE, "Wave spawn queue must keep the full shuffled array.")
	_expect(
		game.pending_enemy_xirang_kill_rewards.size() == TEST_QUEUE_SIZE,
		"Wave reward queue must stay the same size as the config queue."
	)
	for queue_index in range(TEST_QUEUE_SIZE):
		var queued_config := game.pending_enemy_configs[queue_index]
		var queued_reward := game.pending_enemy_xirang_kill_rewards[queue_index]
		if queued_config == inherited_config:
			_expect(queued_reward == 7, "Inherited rewards must stay paired during shuffle.")
		elif queued_config == zero_override_config:
			_expect(queued_reward == 0, "Zero overrides must stay paired during shuffle.")
		elif queued_config == positive_override_config:
			_expect(queued_reward == 31, "Positive overrides must stay paired during shuffle.")
		else:
			_expect(false, "Wave queue must not introduce an unknown enemy config.")
	_expect(game.pending_enemy_config_index == 0, "Wave spawn queue cursor must start at zero.")
	_expect(bool(game.call("_has_pending_enemy_configs")), "Wave spawn queue must report pending items at the start.")

	game.pending_enemy_config_index = TEST_QUEUE_SIZE - 1
	_expect(bool(game.call("_has_pending_enemy_configs")), "Wave spawn queue must still have the final pending item.")
	var final_config := game.pending_enemy_configs[game.pending_enemy_config_index]
	var final_reward := game.pending_enemy_xirang_kill_rewards[game.pending_enemy_config_index]
	_expect(
		(final_config == inherited_config and final_reward == 7)
		or (final_config == zero_override_config and final_reward == 0)
		or (final_config == positive_override_config and final_reward == 31),
		"Wave queue cursor must read the final paired config and reward without shifting."
	)

	game.pending_enemy_config_index = TEST_QUEUE_SIZE
	_expect(not bool(game.call("_has_pending_enemy_configs")), "Wave spawn queue must be empty when the cursor reaches the array size.")
	game.call("_clear_pending_enemy_spawn_queue")
	_expect(game.pending_enemy_configs.is_empty(), "Wave spawn queue clear must release the backing array.")
	_expect(
		game.pending_enemy_xirang_kill_rewards.is_empty(),
		"Wave spawn queue clear must release the paired reward array."
	)
	_expect(game.pending_enemy_config_index == 0, "Wave spawn queue clear must reset the cursor.")

	var short_entry := WaveEnemyEntry.new()
	short_entry.enemy_config = inherited_config
	short_entry.count = 2
	short_entry.xirang_kill_reward_override = 41
	var invalid_entry := WaveEnemyEntry.new()
	var long_entry := WaveEnemyEntry.new()
	long_entry.enemy_config = positive_override_config
	long_entry.count = 4
	var empty_entry := WaveEnemyEntry.new()
	empty_entry.enemy_config = zero_override_config
	empty_entry.count = 0
	var round_robin_entries: Array[WaveEnemyEntry] = [
		short_entry,
		null,
		invalid_entry,
		long_entry,
		empty_entry,
	]
	var round_robin_wave := WaveConfig.new()
	round_robin_wave.spawn_order = WaveConfig.SpawnOrder.ENTRY_ROUND_ROBIN
	round_robin_wave.enemy_entries = round_robin_entries
	var expected_round_robin_configs: Array[EnemyConfig] = [
		inherited_config,
		positive_override_config,
		inherited_config,
		positive_override_config,
		positive_override_config,
		positive_override_config,
	]
	for seed_value in [0x1251, 0x9374]:
		game.random_generator.seed = seed_value
		game.call("_build_wave_spawn_queue", round_robin_wave)
		_expect(
			game.pending_enemy_configs == expected_round_robin_configs,
			"Round-robin queues must skip invalid entries and exhaust unequal counts in entry order."
		)
		_expect(
			game.pending_enemy_xirang_kill_rewards == [41, 19, 41, 19, 19, 19],
			"Round-robin queues must keep every reward paired with its config."
		)
		game.call("_clear_pending_enemy_spawn_queue")

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
