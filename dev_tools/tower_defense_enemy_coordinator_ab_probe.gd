extends SceneTree

const TOWER_SCENE := preload(
	"res://scene/game_modes/tower_defense/tower_defense_game.tscn"
)
const PROGRESSION := preload(
	"res://resources/config/campaigns/tower_defense/formal_progression.tres"
)
const ENEMY_CONFIGS: Array[EnemyConfig] = [
	preload("res://resources/config/enemies/slime.tres"),
	preload("res://resources/config/enemies/slime_green.tres"),
	preload("res://resources/config/enemies/slime_frost.tres"),
]
const FIXED_SEEDS: Array[int] = [0x13579BDF, 0x2468ACE0, 0x5EEDC0DE]
const PLAYER_COUNT := 3

var failures: Array[String] = []


func _init() -> void:
	call_deferred(&"_run")


func _run() -> void:
	var game := TOWER_SCENE.instantiate() as TowerDefenseGame
	game.auto_start_waves = false
	root.add_child(game)
	current_scene = game
	await process_frame
	game.runtime_mode = CombatRuntimeBase.RuntimeMode.HOST_AUTHORITY

	var default_completion := Callable(
		game.campaign_coordinator,
		"complete_current_step"
	)
	if game.enemy_coordinator.wave_completed.is_connected(default_completion):
		game.enemy_coordinator.wave_completed.disconnect(default_completion)
	var actual_trace: Array = []
	game.multiplayer_gateway.enemy_spawned.connect(
		func(net_id: int, config: EnemyConfig, position: Vector2) -> void:
			actual_trace.append([&"S", net_id, config.resource_path, position])
	)
	game.multiplayer_gateway.enemy_defeated.connect(
		func(net_id: int, _position: Vector2) -> void:
			actual_trace.append([&"D", net_id])
	)
	game.multiplayer_gateway.enemy_removed.connect(
		func(net_id: int) -> void:
			actual_trace.append([&"R", net_id])
	)
	game.enemy_coordinator.wave_progress_changed.connect(
		func(
			wave_number: int,
			defeated: int,
			escaped: int,
			resolved: int,
			total: int
		) -> void:
			actual_trace.append([
				&"P", wave_number, defeated, escaped, resolved, total,
			])
	)
	game.enemy_coordinator.wave_completed.connect(
		func() -> void: actual_trace.append([&"C"])
	)

	var combined_trace: Array = []
	for round_index in range(FIXED_SEEDS.size()):
		actual_trace.clear()
		var wave := _create_wave()
		var spawn_points: Array[Marker2D] = []
		for point_index in range(mini(game.enemy_coordinator.enemy_spawn_points.size(), 3)):
			spawn_points.append(game.enemy_coordinator.enemy_spawn_points[point_index])
		_expect(not spawn_points.is_empty(), "A/B 场景没有可用出生点。")
		if spawn_points.is_empty():
			break

		var seed := FIXED_SEEDS[round_index]
		var first_net_id := 1000 + round_index * 100
		var expected := _build_legacy_trace(
			wave,
			seed,
			spawn_points,
			first_net_id,
			round_index + 1
		)

		game.random_generator.seed = seed
		# A/B 基线需要复现抽取前的原始状态布置；普通 fixture 不得绕过
		# Campaign replace_flow_state_for_fixture/typed transition API。
		game.campaign_coordinator.current_flow_step = wave
		game.campaign_coordinator.wave_state = CombatFlowState.State.WAVE_ACTIVE
		game.campaign_coordinator.current_wave_index = round_index
		game.enemy_coordinator.clear_active_enemies()
		game.enemy_coordinator.clear_hud_enemies()
		game.enemy_coordinator.clear_queue()
		game.enemy_coordinator.active_wave_spawn_points.assign(spawn_points)
		game.clear_network_enemy_registry()
		game.enemy_coordinator.next_multiplayer_enemy_net_id = first_net_id
		var wave_total := game.enemy_coordinator.begin_wave(
			wave,
			PROGRESSION,
			PLAYER_COUNT
		)
		game.campaign_coordinator.reset_wave_progress(wave_total)
		game.enemy_coordinator.spawn_wave_batch(64)

		var spawned_enemies: Array[Enemy] = []
		for enemy_offset in range(game.campaign_coordinator.current_wave_total):
			var net_id := first_net_id + enemy_offset
			var enemy := game.get_network_enemy(net_id)
			_expect(enemy != null, "A/B 普通波次未按连续 net id 注册敌人 %d。" % net_id)
			if enemy != null:
				spawned_enemies.append(enemy)
		for enemy in spawned_enemies:
			enemy.defeated.emit(enemy)
		for enemy in spawned_enemies:
			enemy.queue_free()
		await process_frame
		await physics_frame

		_expect(
			actual_trace == expected,
			"第 %d 轮固定 seed 的队列/RNG/net id/终止轨迹不一致。" % (round_index + 1)
		)
		combined_trace.append(actual_trace.duplicate(true))

	current_scene = null
	game.queue_free()
	for _cleanup_frame in range(4):
		await process_frame
		await physics_frame
	if failures.is_empty():
		print(
			"TOWER_DEFENSE_ENEMY_COORDINATOR_AB_PROBE_OK "
			+ "rounds=%d trajectory_hash=%d"
			% [FIXED_SEEDS.size(), hash(combined_trace)]
		)
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	quit(1)


func _create_wave() -> WaveConfig:
	var wave := WaveConfig.new()
	wave.wave_name = "EnemyCoordinator A/B"
	wave.spawn_order = WaveConfig.SpawnOrder.SHUFFLED
	wave.spawn_count_per_tick = 64
	wave.max_alive_enemies = 64
	var counts: Array[int] = [2, 1, 2]
	var rewards: Array[int] = [7, 11, 13]
	for entry_index in range(ENEMY_CONFIGS.size()):
		var entry := WaveEnemyEntry.new()
		entry.enemy_config = ENEMY_CONFIGS[entry_index]
		entry.count = counts[entry_index]
		entry.xirang_kill_reward_override = rewards[entry_index]
		wave.enemy_entries.append(entry)
	return wave


func _build_legacy_trace(
	wave: WaveConfig,
	seed: int,
	spawn_points: Array[Marker2D],
	first_net_id: int,
	wave_number: int
) -> Array:
	var random_generator := RandomNumberGenerator.new()
	random_generator.seed = seed
	var queued_configs: Array[EnemyConfig] = []
	var queued_rewards: Array[int] = []
	for entry in wave.enemy_entries:
		var scaled_count := PROGRESSION.get_scaled_enemy_count(
			maxi(entry.count, 0),
			PLAYER_COUNT
		)
		for _enemy_index in range(scaled_count):
			queued_configs.append(entry.enemy_config)
			queued_rewards.append(entry.resolve_xirang_kill_reward(entry.enemy_config))
	for source_index in range(queued_configs.size() - 1, 0, -1):
		var target_index := random_generator.randi_range(0, source_index)
		var config := queued_configs[source_index]
		queued_configs[source_index] = queued_configs[target_index]
		queued_configs[target_index] = config
		var reward := queued_rewards[source_index]
		queued_rewards[source_index] = queued_rewards[target_index]
		queued_rewards[target_index] = reward

	var trace: Array = []
	for enemy_index in range(queued_configs.size()):
		var spawn_point := spawn_points[
			random_generator.randi_range(0, spawn_points.size() - 1)
		]
		trace.append([
			&"S",
			first_net_id + enemy_index,
			queued_configs[enemy_index].resource_path,
			spawn_point.global_position,
		])
	for enemy_index in range(queued_configs.size()):
		trace.append([&"D", first_net_id + enemy_index])
		trace.append([
			&"P",
			wave_number,
			enemy_index + 1,
			0,
			enemy_index + 1,
			queued_configs.size(),
		])
	for enemy_index in range(queued_configs.size()):
		trace.append([&"R", first_net_id + enemy_index])
	trace.append([&"C"])
	return trace


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
