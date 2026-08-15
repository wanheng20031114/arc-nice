extends SceneTree

const TOWER_SCENE := preload("res://scene/game_modes/tower_defense/tower_defense_game.tscn")
const PERFORMANCE_CAMPAIGN := preload(
	"res://resources/config/campaigns/tower_defense/performance/campaign.tres"
)
const EXPECTED_WAVE_TOTAL := 1200
const EXPECTED_MAX_ALIVE := 300
const EXPECTED_EARLY_WAVE_INTERVAL := 0.1
const EXPECTED_SEQUENTIAL_WAVE_INTERVAL := 0.025
const EXPECTED_SEQUENTIAL_SPAWNS_PER_SECOND := 40
const SPAWN_RATE_TOLERANCE := 2

var failures: Array[String] = []


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	var game := TOWER_SCENE.instantiate() as TowerDefenseGame
	_expect(game != null, "Tower-defense pressure scene must instantiate.")
	if game == null:
		_finish(0)
		return

	game.auto_start_waves = false
	game.singleplayer_campaign = PERFORMANCE_CAMPAIGN
	root.add_child(game)
	await process_frame
	await physics_frame
	var campaign := game.campaign_coordinator

	_expect(game.linglan_boss_enabled, "Tower-defense runtime must enable Linglan.")
	_expect(campaign.bosses.is_empty(), "Performance Campaign must remain free of Boss steps.")
	_expect(campaign.waves.size() == 12, "Pressure Campaign must contain twelve waves.")
	if campaign.waves.is_empty():
		game.queue_free()
		await process_frame
		_finish(0)
		return

	for early_wave_index in range(2):
		var early_wave: WaveConfig = campaign.waves[early_wave_index]
		_expect(
			is_equal_approx(early_wave.spawn_interval, EXPECTED_EARLY_WAVE_INTERVAL)
			and early_wave.spawn_count_per_tick == 1,
			"Tower-defense waves 1-2 must spawn one enemy every 0.1 seconds."
		)

	var sequential_wave: WaveConfig = campaign.waves[2]
	_expect(
		sequential_wave.get_total_enemy_count() == EXPECTED_WAVE_TOTAL,
		"Pressure wave must queue exactly 1200 enemies."
	)
	_expect(
		sequential_wave.max_alive_enemies == EXPECTED_MAX_ALIVE,
		"Pressure wave simultaneous-enemy cap must be 300."
	)
	_expect(
		is_equal_approx(
			sequential_wave.spawn_interval,
			EXPECTED_SEQUENTIAL_WAVE_INTERVAL
		)
		and sequential_wave.spawn_count_per_tick == 1,
		"Tower-defense waves 3-12 must spawn enemies one at a time at 40 per second."
	)

	var started_at_msec := Time.get_ticks_msec()
	campaign.begin_flow_step(sequential_wave)
	_expect(
		is_equal_approx(
			game.enemy_spawn_timer.wait_time,
			EXPECTED_SEQUENTIAL_WAVE_INTERVAL
		),
		"Tower-defense runtime must preserve the configured 0.025-second interval."
	)
	var timed_spawn_start: int = campaign.current_wave_spawned
	await create_timer(1.0).timeout
	game.enemy_spawn_timer.stop()
	var timed_spawn_count: int = campaign.current_wave_spawned - timed_spawn_start
	_expect(
		absi(timed_spawn_count - EXPECTED_SEQUENTIAL_SPAWNS_PER_SECOND)
		<= SPAWN_RATE_TOLERANCE,
		"Sequential spawning must preserve the original total rate of 40 enemies per second."
	)
	for _spawn_index in range(EXPECTED_MAX_ALIVE):
		game.enemy_coordinator.spawn_wave_batch(
			TowerDefenseCampaignCoordinator.MAX_WAVE_SPAWN_COUNT_PER_TICK
		)
	var fill_elapsed_msec := Time.get_ticks_msec() - started_at_msec

	_expect(campaign.current_wave_total == EXPECTED_WAVE_TOTAL, "Runtime queue total must stay at 1200.")
	_expect(campaign.current_wave_spawned == EXPECTED_MAX_ALIVE, "Runtime must fill exactly 300 slots.")
	_expect(
		game.enemy_coordinator.active_wave_enemy_ids.size() == EXPECTED_MAX_ALIVE,
		"Active enemy registry must stop exactly at 300."
	)
	_expect(
		game.enemy_container.get_child_count() == EXPECTED_MAX_ALIVE,
		"EnemyContainer must contain exactly 300 live enemies at the cap."
	)
	_expect(
		game.enemy_coordinator.pending_enemy_config_index == EXPECTED_MAX_ALIVE,
		"Spawn queue must retain the remaining 900 enemies after reaching the cap."
	)

	for _blocked_batch_index in range(20):
		game.enemy_coordinator.spawn_wave_batch(
			TowerDefenseCampaignCoordinator.MAX_WAVE_SPAWN_COUNT_PER_TICK
		)
	_expect(
		campaign.current_wave_spawned == EXPECTED_MAX_ALIVE
		and game.enemy_coordinator.active_wave_enemy_ids.size() == EXPECTED_MAX_ALIVE,
		"Additional spawn ticks must never exceed the 300-enemy hard cap."
	)

	# 压测主动销毁场景不属于敌人异常消失；先提交明确的 REMOVED 终结原因，
	# 让三百个实体沿正式账本路径注销，避免 teardown 污染异常诊断。
	for child in game.enemy_container.get_children():
		var enemy := child as Enemy
		if enemy == null:
			continue
		campaign.try_resolve_wave_enemy(
			enemy.get_instance_id(), CombatTypes.EnemyTerminalReason.REMOVED
		)
		enemy.queue_free()
	await process_frame
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
