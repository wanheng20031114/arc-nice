extends SceneTree

class FlowBoundaryProbe:
	extends GameTowerDefense

	var probe_wave_number := 1
	var probe_next_step: FlowStepConfig = null
	var entered_fate := false
	var entered_intermission := false
	var entered_victory := false
	var captured_next_step: FlowStepConfig = null

	func _get_default_next_flow_step(_flow_step: FlowStepConfig) -> FlowStepConfig:
		return probe_next_step

	func _get_wave_number_for_step(_wave_config: WaveConfig) -> int:
		return probe_wave_number

	func _enter_xiaocong_fate_interlude(next_step: FlowStepConfig) -> void:
		entered_fate = true
		captured_next_step = next_step

	func _enter_intermission(next_step: FlowStepConfig = null) -> void:
		entered_intermission = true
		captured_next_step = next_step

	func _enter_victory(_emit_multiplayer: bool = true) -> void:
		entered_victory = true


class LightingProbe:
	extends GameTowerDefense

	var lighting_events: Array[StringName] = []

	func transition_world_to_night(_duration_seconds: float = -1.0) -> void:
		lighting_events.append(&"night")

	func transition_world_to_day(_duration_seconds: float = -1.0) -> void:
		lighting_events.append(&"day")


var failures: Array[String] = []


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	_test_day_and_lighting_boundaries()
	_test_wave_completion_boundaries()
	_test_elite_bias_day_window()
	_test_double_xirang_day_combat_states()
	_test_boss_runtime_health_cap()
	_test_xiaocong_collectible_offer_count()
	if failures.is_empty():
		print("TOWER_DEFENSE_FATE_INTEGRATION_SMOKE_TEST_OK")
		quit()
		return
	for failure in failures:
		push_error(failure)
	quit(1)


func _test_day_and_lighting_boundaries() -> void:
	var probe := LightingProbe.new()
	var expected_days := [1, 1, 1, 1, 2, 2, 2, 2, 3]
	for wave_index in range(expected_days.size()):
		var wave_number := wave_index + 1
		_expect(
			probe._get_day_number_for_wave(wave_number) == expected_days[wave_index],
			"Wave %d must map to day %d." % [wave_number, expected_days[wave_index]]
		)

	var expected_wave_lighting: Array[StringName] = [
		&"day", &"day", &"night", &"night",
		&"day", &"day", &"night", &"night",
	]
	for wave_index in range(expected_wave_lighting.size()):
		probe.lighting_events.clear()
		probe._apply_wave_start_lighting(wave_index + 1)
		_expect(
			probe.lighting_events == [expected_wave_lighting[wave_index]],
			"Wave %d lighting must be %s." % [
				wave_index + 1,
				String(expected_wave_lighting[wave_index]),
			]
		)

	var expected_rest_lighting: Array[StringName] = [
		&"day", &"day", &"night", &"day",
	]
	for completed_wave_index in range(expected_rest_lighting.size()):
		probe.lighting_events.clear()
		probe._apply_intermission_lighting(completed_wave_index + 1)
		_expect(
			probe.lighting_events == [expected_rest_lighting[completed_wave_index]],
			"Rest after wave %d must keep the expected phase lighting." % (
				completed_wave_index + 1
			)
		)
	probe.free()


func _test_wave_completion_boundaries() -> void:
	var next_wave := WaveConfig.new()
	for wave_number in [1, 3, 5]:
		var probe := FlowBoundaryProbe.new()
		probe.current_flow_step = WaveConfig.new()
		probe.probe_wave_number = wave_number
		probe.probe_next_step = next_wave
		probe._complete_current_step()
		_expect(
			probe.entered_intermission and not probe.entered_fate,
			"Non-day-ending wave %d must enter intermission." % wave_number
		)
		probe.free()

	var day_end_probe := FlowBoundaryProbe.new()
	day_end_probe.current_flow_step = WaveConfig.new()
	day_end_probe.probe_wave_number = 4
	day_end_probe.probe_next_step = next_wave
	day_end_probe._complete_current_step()
	_expect(day_end_probe.entered_fate, "Wave 4 must enter the fate interlude.")
	_expect(
		day_end_probe.captured_next_step == next_wave,
		"The fate interlude must retain the next campaign step."
	)
	day_end_probe.free()

	var terminal_day_end_probe := FlowBoundaryProbe.new()
	terminal_day_end_probe.current_flow_step = WaveConfig.new()
	terminal_day_end_probe.probe_wave_number = 8
	terminal_day_end_probe.probe_next_step = null
	terminal_day_end_probe._complete_current_step()
	_expect(
		terminal_day_end_probe.entered_fate and not terminal_day_end_probe.entered_victory,
		"A terminal day-ending wave must resolve fate before victory."
	)
	terminal_day_end_probe.free()


func _test_elite_bias_day_window() -> void:
	var probe := GameTowerDefense.new()
	var base_config := load(
		"res://resources/config/enemies/capoo_knight.tres"
	) as EnemyConfig
	var elite_config := load(
		"res://resources/config/enemies/capoo_knight_elite.tres"
	) as EnemyConfig
	_expect(base_config != null and elite_config != null, "Elite fixture configs must load.")
	if base_config == null or elite_config == null:
		probe.free()
		return

	probe.fate_elite_bias_day = 2
	probe.random_generator.seed = 246813579
	probe.current_wave_index = 0
	for sample_index in range(32):
		_expect(
			probe._resolve_fate_enemy_config(base_config) == base_config,
			"Elite bias must not leak into the day before its target window."
		)

	probe.current_wave_index = 4
	var saw_elite := false
	for sample_index in range(128):
		if probe._resolve_fate_enemy_config(base_config) == elite_config:
			saw_elite = true
			break
	_expect(saw_elite, "The configured next day must be able to replace base enemies.")

	probe.current_wave_index = 8
	for sample_index in range(32):
		_expect(
			probe._resolve_fate_enemy_config(base_config) == base_config,
			"Elite bias must expire after exactly one day."
		)
	probe.free()


func _test_double_xirang_day_combat_states() -> void:
	var probe := GameTowerDefense.new()
	probe.fate_double_xirang_day = 2
	probe.current_wave_index = 4
	probe.wave_state = GameRuntimeBase.WaveState.WAVE_ACTIVE
	_expect(
		probe._is_fate_double_xirang_reward_active(),
		"The target day's ordinary waves must double Xirang kill rewards."
	)
	probe.wave_state = GameRuntimeBase.WaveState.BOSS_ACTIVE
	_expect(
		probe._is_fate_double_xirang_reward_active(),
		"A target-day boss fight must retain the next-day double-Xirang reward."
	)
	probe.wave_state = GameRuntimeBase.WaveState.INTERMISSION
	_expect(
		not probe._is_fate_double_xirang_reward_active(),
		"The double-Xirang fate must remain combat-only."
	)
	probe.current_wave_index = 8
	probe.wave_state = GameRuntimeBase.WaveState.WAVE_ACTIVE
	_expect(
		not probe._is_fate_double_xirang_reward_active(),
		"The double-Xirang fate must expire after its single target day."
	)
	probe.free()


func _test_boss_runtime_health_cap() -> void:
	var boss_config := load(
		"res://resources/config/enemies/linglan_boss.tres"
	) as EnemyConfig
	_expect(boss_config != null, "Linglan boss config must load for fate health validation.")
	if boss_config == null or boss_config.enemy_scene == null:
		return
	var boss := boss_config.enemy_scene.instantiate() as LinglanBoss
	_expect(boss != null, "Linglan boss scene must instantiate for fate health validation.")
	if boss == null:
		return
	boss.config = boss_config
	boss.current_health = boss_config.max_health
	boss.set_runtime_max_health_multiplier(0.9)
	_expect(
		boss.get_max_health() == boss.get_runtime_max_health()
		and boss.current_health == boss.get_runtime_max_health(),
		"All-enemy max-health fate must also drive Linglan's authoritative HUD cap."
	)
	boss.free()


func _test_xiaocong_collectible_offer_count() -> void:
	var game := GameTowerDefense.new()
	var manager := TowerDefenseFateManager.new()
	var merchant := LuoxiMerchant.new()
	var target_player := preload(
		"res://scene/player/weishidaier/player_weishidaier.tscn"
	).instantiate() as Player
	game.runtime_mode = GameRuntimeBase.RuntimeMode.HOST_AUTHORITY
	game.fate_manager = manager
	game.luoxi_merchant = merchant
	game.peer_players = {1: target_player}
	manager.active = true
	manager.stage = TowerDefenseFateManager.STAGE_RESOLVING
	manager.eligible_peer_ids = [1]
	LuoxiMerchant.set_runtime_choice_count(LuoxiMerchant.MAX_CHOICE_COUNT)
	game._begin_fate_collectible_reward()
	var offer: Array = manager.collectible_offers.get(1, []) as Array
	_expect(
		manager.stage == TowerDefenseFateManager.STAGE_COLLECTIBLE_REWARD
		and offer.size() == LuoxiMerchant.DEFAULT_CHOICE_COUNT,
		"Xiaocong option 3 must stay at three cards when permanent buff 8 gives Luoxi four."
	)
	LuoxiMerchant.reset_runtime_choice_count()
	game.peer_players.clear()
	target_player.free()
	merchant.free()
	manager.free()
	game.free()


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
