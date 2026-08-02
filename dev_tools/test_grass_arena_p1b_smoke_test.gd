extends SceneTree

const ARENA_SCENE := preload("res://scene/test_arena/test_grass_arena_p1b.tscn")
const TEST_CAMPAIGN := preload(
	"res://resources/config/campaigns/test_arena/p1b/singleplayer/campaign.tres"
)
const MULTIPLAYER_TEST_CAMPAIGN := preload(
	"res://resources/config/campaigns/test_arena/p1b/multiplayer/campaign.tres"
)
const COMBAT_ROBOT_CONFIG := preload(
	"res://resources/config/enemies/combat_robot.tres"
)
const COMBAT_ROBOT_GUNNER_CONFIG := preload(
	"res://resources/config/enemies/combat_robot_gunner.tres"
)
const COMBAT_ROBOT_DRONE_OPERATOR_CONFIG := preload(
	"res://resources/config/enemies/combat_robot_drone_operator.tres"
)
const COMBAT_ROBOT_DRONE_OPERATOR_CONFIG_PATH := (
	"res://resources/config/enemies/combat_robot_drone_operator.tres"
)
const FORMAL_WAVE_DIRECTORIES := [
	"res://resources/config/campaigns/standard/singleplayer",
	"res://resources/config/campaigns/standard/multiplayer",
	"res://resources/config/campaigns/tower_defense/formal",
]
const EXPECTED_TOTAL_ENEMIES := 1000
const EXPECTED_COMBAT_ROBOT_COUNT := 334
const EXPECTED_COMBAT_ROBOT_GUNNER_COUNT := 333
const EXPECTED_DRONE_OPERATOR_COUNT := 333

var failures: Array[String] = []
var arena: TestGrassArena


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	arena = ARENA_SCENE.instantiate() as TestGrassArena
	_expect(arena != null, "P1B 必须复用 TestGrassArena 运行时。")
	if arena == null:
		_finish()
		return
	arena.auto_start_waves = false
	root.add_child(arena)
	current_scene = arena
	await process_frame
	await process_frame

	_test_scene_contract()
	_test_campaign_contracts()
	_test_operator_stays_out_of_formal_waves()
	_test_strict_three_type_rotation_queue()
	_test_unequal_round_robin_queue()

	current_scene = null
	arena.queue_free()
	await process_frame
	await process_frame
	_finish()


func _test_scene_contract() -> void:
	_expect(arena.singleplayer_campaign == TEST_CAMPAIGN, "P1B 必须绑定独立单人 Campaign。")
	_expect(
		arena.multiplayer_campaign == MULTIPLAYER_TEST_CAMPAIGN,
		"P1B 必须绑定独立多人 Campaign。"
	)
	_expect(
		arena.test_scene_label == "P1B"
		and arena.test_entry_announcement_text == "测试场景 P1B",
		"P1B 必须显示独立的场景标签与入场报幕。"
	)
	_expect(not arena.day_phase_announcements_enabled, "P1B 必须继承测试场景的报幕设置。")
	_expect(arena.sandbox_free_building_enabled, "P1B 必须继承自由放置植物能力。")


func _test_campaign_contracts() -> void:
	_expect(
		TEST_CAMPAIGN.campaign_id == &"test_grass_arena_p1b_singleplayer",
		"P1B 单人 Campaign ID 必须保持独立。"
	)
	_expect(
		MULTIPLAYER_TEST_CAMPAIGN.campaign_id == &"test_grass_arena_p1b_multiplayer",
		"P1B 多人 Campaign ID 必须保持独立。"
	)
	_expect(TEST_CAMPAIGN.validate_campaign().is_empty(), "P1B 单人 Campaign 必须通过校验。")
	_expect(
		MULTIPLAYER_TEST_CAMPAIGN.validate_campaign().is_empty(),
		"P1B 多人 Campaign 必须通过校验。"
	)
	_validate_campaign_wave(TEST_CAMPAIGN, "单人")
	_validate_campaign_wave(MULTIPLAYER_TEST_CAMPAIGN, "多人")
	_expect(
		is_zero_approx(arena.progression_config.enemy_count_per_extra_player_ratio)
		and arena.progression_config.get_scaled_enemy_count(EXPECTED_TOTAL_ENEMIES, 8)
		== EXPECTED_TOTAL_ENEMIES,
		"P1B 的1000台机器人不得随多人房间人数缩放。"
	)


func _validate_campaign_wave(campaign: WaveCampaignConfig, mode_label: String) -> void:
	var waves := campaign.get_waves()
	_expect(waves.size() == 1, "P1B %s Campaign 必须只有一个波次。" % mode_label)
	if waves.size() != 1:
		return
	var wave := waves[0]
	_expect(
		wave.get_total_enemy_count() == EXPECTED_TOTAL_ENEMIES,
		"P1B %s波次必须正好包含1000台机器人。" % mode_label
	)
	_expect(wave.enemy_entries.size() == 3, "P1B %s波次必须只有三种机器人。" % mode_label)
	if wave.enemy_entries.size() == 3:
		_expect(
			wave.enemy_entries[0].enemy_config == COMBAT_ROBOT_CONFIG
			and wave.enemy_entries[0].count == EXPECTED_COMBAT_ROBOT_COUNT,
			"P1B %s波次必须先登记334台持剑战斗机器人。" % mode_label
		)
		_expect(
			wave.enemy_entries[1].enemy_config == COMBAT_ROBOT_GUNNER_CONFIG
			and wave.enemy_entries[1].count == EXPECTED_COMBAT_ROBOT_GUNNER_COUNT,
			"P1B %s波次必须第二个登记333台持枪战斗机器人。" % mode_label
		)
		_expect(
			wave.enemy_entries[2].enemy_config == COMBAT_ROBOT_DRONE_OPERATOR_CONFIG
			and wave.enemy_entries[2].count == EXPECTED_DRONE_OPERATOR_COUNT,
			"P1B %s波次必须第三个登记333台爆炸无人机操作员。" % mode_label
		)
	_expect(
		wave.spawn_order == WaveConfig.SpawnOrder.ENTRY_ROUND_ROBIN,
		"P1B %s波次必须启用条目轮询生成顺序。" % mode_label
	)
	_expect(is_equal_approx(wave.spawn_interval, 3.0), "P1B 生成间隔必须为3秒。")
	_expect(wave.spawn_count_per_tick == 1, "P1B 每次生成必须只有1台机器人。")
	_expect(wave.max_alive_enemies == EXPECTED_TOTAL_ENEMIES, "P1B 场上上限必须为1000。")
	_expect(wave.spawn_point_mask == 3, "P1B 只能使用右侧两个红门出生点。")
	_expect(
		wave.get_enabled_spawn_point_names() == [&"Spawn1", &"Spawn2"],
		"P1B 出生点必须精确解析为 Spawn1 和 Spawn2。"
	)


func _test_operator_stays_out_of_formal_waves() -> void:
	var operator_reference_count := 0
	for directory_path in FORMAL_WAVE_DIRECTORIES:
		var directory := DirAccess.open(directory_path)
		_expect(
			directory != null,
			"P1B 正式波次隔离测试必须能读取目录 %s。" % directory_path
		)
		if directory == null:
			continue
		for file_name in directory.get_files():
			if not file_name.begins_with("wave_") or not file_name.ends_with(".tres"):
				continue
			var wave_text := FileAccess.get_file_as_string(
				"%s/%s" % [directory_path, file_name]
			)
			operator_reference_count += wave_text.count(
				COMBAT_ROBOT_DRONE_OPERATOR_CONFIG_PATH
			)
	_expect(
		operator_reference_count == 0,
		"爆炸无人机操作员只能进入 P1B，所有正式波次引用次数必须为0。"
	)


func _test_strict_three_type_rotation_queue() -> void:
	var singleplayer_wave := TEST_CAMPAIGN.get_waves()[0]
	var multiplayer_wave := MULTIPLAYER_TEST_CAMPAIGN.get_waves()[0]
	var expected_configs: Array[EnemyConfig] = [
		COMBAT_ROBOT_CONFIG,
		COMBAT_ROBOT_GUNNER_CONFIG,
		COMBAT_ROBOT_DRONE_OPERATOR_CONFIG,
	]
	for wave in [singleplayer_wave, multiplayer_wave]:
		for seed_value in [0x51B0, 0x71B0]:
			arena.random_generator.seed = seed_value
			arena.call("_build_wave_spawn_queue", wave)
			_expect(
				arena.pending_enemy_configs.size() == EXPECTED_TOTAL_ENEMIES
				and arena.pending_enemy_xirang_kill_rewards.size() == EXPECTED_TOTAL_ENEMIES,
				"P1B 运行时必须构建1000项且配置/奖励严格等长的队列。"
			)
			var actual_counts: Array[int] = [0, 0, 0]
			for queue_index in range(arena.pending_enemy_configs.size()):
				var expected_config := expected_configs[queue_index % 3]
				var queued_config := arena.pending_enemy_configs[queue_index]
				_expect(
					queued_config == expected_config,
					"P1B 必须从持剑开始，按持剑、持枪、操作员在全部1000项中严格轮转。"
				)
				var actual_index := expected_configs.find(queued_config)
				if actual_index >= 0:
					actual_counts[actual_index] += 1
				_expect(
					arena.pending_enemy_xirang_kill_rewards[queue_index]
					== expected_config.xirang_kill_reward,
					"P1B 轮询队列中的息壤奖励必须始终与机器人配置配对。"
				)
			_expect(
				actual_counts[0] == EXPECTED_COMBAT_ROBOT_COUNT
				and actual_counts[1] == EXPECTED_COMBAT_ROBOT_GUNNER_COUNT
				and actual_counts[2] == EXPECTED_DRONE_OPERATOR_COUNT,
				"P1B 三型轮转必须最终生成334/333/333台。"
			)
			_expect(
				arena.pending_enemy_configs.back() == COMBAT_ROBOT_CONFIG,
				"P1B 的第1000项必须是额外一台持剑战斗机器人。"
			)
			arena.call("_clear_pending_enemy_spawn_queue")


func _test_unequal_round_robin_queue() -> void:
	var short_config := EnemyConfig.new()
	short_config.xirang_kill_reward = 11
	var long_config := EnemyConfig.new()
	long_config.xirang_kill_reward = 17
	var ignored_config := EnemyConfig.new()

	var short_entry := WaveEnemyEntry.new()
	short_entry.enemy_config = short_config
	short_entry.count = 2
	var invalid_entry := WaveEnemyEntry.new()
	var long_entry := WaveEnemyEntry.new()
	long_entry.enemy_config = long_config
	long_entry.count = 4
	var empty_entry := WaveEnemyEntry.new()
	empty_entry.enemy_config = ignored_config
	empty_entry.count = 0

	var entries: Array[WaveEnemyEntry] = [
		short_entry,
		null,
		invalid_entry,
		long_entry,
		empty_entry,
	]
	var wave := WaveConfig.new()
	wave.spawn_order = WaveConfig.SpawnOrder.ENTRY_ROUND_ROBIN
	wave.enemy_entries = entries
	arena.call("_build_wave_spawn_queue", wave)

	var expected_configs: Array[EnemyConfig] = [
		short_config,
		long_config,
		short_config,
		long_config,
		long_config,
		long_config,
	]
	_expect(
		arena.pending_enemy_configs == expected_configs,
		"条目轮询必须跳过空/无配置/零数量条目，并在短条目耗尽后继续长条目。"
	)
	_expect(
		arena.pending_enemy_xirang_kill_rewards == [11, 17, 11, 17, 17, 17],
		"不等数量轮询仍必须维持配置与奖励的一一配对。"
	)
	arena.call("_clear_pending_enemy_spawn_queue")


func _finish() -> void:
	if failures.is_empty():
		print("TEST_GRASS_ARENA_P1B_SMOKE_TEST_OK")
		quit()
		return
	for failure in failures:
		push_error(failure)
	quit(1)


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
