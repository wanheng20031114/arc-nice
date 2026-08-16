extends SceneTree

const SOURCE_WAVE_PATTERN := "res://resources/config/waves/wave_%02d.tres"
const CAMPAIGN_ROOT := "res://resources/config/campaigns"
const STANDARD_BOSS_CONFIG := preload("res://resources/config/bosses/boss_01_linglan.tres")
const WAVE_CAMPAIGN_CONFIG_SCRIPT := preload(
	"res://resources/config/waves/wave_campaign_config.gd"
)
const WAVE_CONTENT_CONTRACT := preload(
	"res://dev_tools/wave_campaign_content_contract.gd"
)
const WAVE_ENEMY_ENTRY_SCRIPT := preload(
	"res://resources/config/waves/wave_enemy_entry.gd"
)
const TOWER_DEFENSE_STRESS_BASIC := preload(
	"res://resources/config/enemies/yuanshi_insect_basic.tres"
)
const TOWER_DEFENSE_STRESS_SHELL := preload(
	"res://resources/config/enemies/yuanshi_insect_shell.tres"
)
const TOWER_DEFENSE_STRESS_AK47 := preload(
	"res://resources/config/enemies/capoo_ak47.tres"
)
const FORCE_ARGUMENT := "--force"
const CHECK_ARGUMENT := "--check"
const STANDARD_SHARED_POLICY := &"standard_shared"
const TOWER_DEFENSE_STRESS_POLICY := &"tower_defense_stress"
const TOWER_DEFENSE_STRESS_TOTAL_ENEMIES := 1200
const TOWER_DEFENSE_STRESS_MAX_ALIVE := 300
const TOWER_DEFENSE_EARLY_WAVE_COUNT := 2
const TOWER_DEFENSE_EARLY_WAVE_SPAWN_INTERVAL := 0.1
const TOWER_DEFENSE_ORIGINAL_BATCH_INTERVAL := 0.1
const TOWER_DEFENSE_ORIGINAL_BATCH_SIZE := 4.0
const TOWER_DEFENSE_SEQUENTIAL_SPAWN_INTERVAL := (
	TOWER_DEFENSE_ORIGINAL_BATCH_INTERVAL / TOWER_DEFENSE_ORIGINAL_BATCH_SIZE
)
const TOWER_DEFENSE_SEQUENTIAL_SPAWN_COUNT_PER_TICK := 1
const TOWER_DEFENSE_FIRST_WAVE_BASIC_COUNT := 850
const TOWER_DEFENSE_FIRST_WAVE_SHELL_COUNT := 320
const TOWER_DEFENSE_FIRST_WAVE_AK47_COUNT := 30

const CAMPAIGNS := [
	{
		"mode": "standard",
		"players": "singleplayer",
		"campaign_id": &"standard_singleplayer",
		"display_name": "普通模式 / 单人",
		"spawn_point_mask": WaveConfig.STANDARD_SPAWN_POINT_MASK,
		"boss_config": STANDARD_BOSS_CONFIG,
		"wave_policy": STANDARD_SHARED_POLICY,
	},
	{
		"mode": "standard",
		"players": "multiplayer",
		"campaign_id": &"standard_multiplayer",
		"display_name": "普通模式 / 多人",
		"spawn_point_mask": WaveConfig.STANDARD_SPAWN_POINT_MASK,
		"boss_config": STANDARD_BOSS_CONFIG,
		"wave_policy": STANDARD_SHARED_POLICY,
	},
	{
		"mode": "tower_defense",
		"players": "performance",
		"campaign_id": &"tower_defense_performance",
		"display_name": "塔防模式 / 1200 敌人性能测试",
		"spawn_point_mask": WaveConfig.ALL_SPAWN_POINT_MASK,
		"boss_config": null,
		"wave_policy": TOWER_DEFENSE_STRESS_POLICY,
		"wave_subdirectory": "waves",
	},
]


func _init() -> void:
	var arguments := OS.get_cmdline_user_args()
	var should_generate := arguments.has(FORCE_ARGUMENT)
	var should_check := arguments.has(CHECK_ARGUMENT)
	if should_generate == should_check:
		push_error(
			"请使用 -- --check 校验快照，或使用 -- --force 显式重新生成。"
		)
		quit(2)
		return

	var failures := PackedStringArray()
	if should_check:
		for definition in CAMPAIGNS:
			# 性能战役保留独立调参历史；本检查只为正式 Standard 快照闭包负责。
			if definition["wave_policy"] == STANDARD_SHARED_POLICY:
				_check_campaign(definition, failures)
	else:
		for definition in CAMPAIGNS:
			_generate_campaign(definition, failures)
	if failures.is_empty():
		print(
			"CHECK_STANDARD_WAVE_CAMPAIGN_RESOURCES_OK"
			if should_check
			else "GENERATE_WAVE_CAMPAIGN_RESOURCES_OK"
		)
		quit()
		return
	for failure in failures:
		push_error(failure)
	quit(1)


func _generate_campaign(definition: Dictionary, failures: PackedStringArray) -> void:
	var directory := _get_campaign_directory(definition)
	var absolute_directory := ProjectSettings.globalize_path(directory)
	var directory_error := DirAccess.make_dir_recursive_absolute(absolute_directory)
	if directory_error != OK:
		failures.append("无法创建 Campaign 目录 %s：%s" % [directory, error_string(directory_error)])
		return
	var wave_directory := directory
	var wave_subdirectory := String(definition.get("wave_subdirectory", ""))
	if not wave_subdirectory.is_empty():
		wave_directory = "%s/%s" % [directory, wave_subdirectory]
		var wave_directory_error := DirAccess.make_dir_recursive_absolute(
			ProjectSettings.globalize_path(wave_directory)
		)
		if wave_directory_error != OK:
			failures.append(
				"无法创建波次目录 %s：%s"
				% [wave_directory, error_string(wave_directory_error)]
			)
			return

	var campaign_waves: Array[WaveConfig] = []
	for wave_number in range(1, 13):
		var campaign_wave := _build_campaign_wave(definition, wave_number, failures)
		if campaign_wave == null:
			return
		var wave_path := "%s/wave_%02d.tres" % [wave_directory, wave_number]
		var wave_error := ResourceSaver.save(campaign_wave, wave_path)
		if wave_error != OK:
			failures.append("无法保存 %s：%s" % [wave_path, error_string(wave_error)])
			return
		campaign_waves.append(load(wave_path) as WaveConfig)

	var flow_graph := FlowGraphConfig.new()
	flow_graph.graph_name = "%s战斗流程" % String(definition["display_name"])
	flow_graph.start_step = campaign_waves[0]
	var flow_steps: Array[FlowStepConfig] = []
	flow_steps.assign(campaign_waves)
	var boss_config := definition["boss_config"] as BossConfig
	if boss_config != null:
		flow_steps.append(boss_config)
	flow_graph.steps = flow_steps
	var flow_path := "%s/flow.tres" % directory
	var flow_error := ResourceSaver.save(flow_graph, flow_path)
	if flow_error != OK:
		failures.append("无法保存 %s：%s" % [flow_path, error_string(flow_error)])
		return

	var campaign := WAVE_CAMPAIGN_CONFIG_SCRIPT.new()
	campaign.campaign_id = definition["campaign_id"] as StringName
	campaign.flow_graph = load(flow_path) as FlowGraphConfig
	var campaign_path := "%s/campaign.tres" % directory
	var campaign_error := ResourceSaver.save(campaign, campaign_path)
	if campaign_error != OK:
		failures.append("无法保存 %s：%s" % [campaign_path, error_string(campaign_error)])


func _check_campaign(definition: Dictionary, failures: PackedStringArray) -> void:
	var directory := _get_campaign_directory(definition)
	var campaign_path := "%s/campaign.tres" % directory
	var campaign := load(campaign_path) as WaveCampaignConfig
	if campaign == null:
		failures.append("无法加载 Campaign 快照：%s" % campaign_path)
		return
	if campaign.campaign_id != definition["campaign_id"]:
		failures.append("Campaign id 与生成定义不一致：%s" % campaign_path)
	var validation_errors := campaign.validate_campaign()
	for validation_error in validation_errors:
		failures.append("%s：%s" % [campaign_path, validation_error])
	if campaign.flow_graph == null:
		return
	var expected_flow_path := "%s/flow.tres" % directory
	if campaign.flow_graph.resource_path != expected_flow_path:
		failures.append("Campaign 引用了错误的流程图快照：%s" % campaign_path)
	if campaign.flow_graph.graph_name != "%s战斗流程" % String(definition["display_name"]):
		failures.append("流程图名称与生成定义不一致：%s" % campaign.flow_graph.resource_path)

	var actual_waves := campaign.get_waves()
	if actual_waves.size() != 12:
		failures.append("Campaign 快照必须包含 12 个波次：%s" % campaign_path)
		return
	if campaign.flow_graph.start_step != actual_waves[0]:
		failures.append("流程图必须从第 1 波开始：%s" % campaign.flow_graph.resource_path)

	var wave_directory := directory
	var wave_subdirectory := String(definition.get("wave_subdirectory", ""))
	if not wave_subdirectory.is_empty():
		wave_directory = "%s/%s" % [directory, wave_subdirectory]
	for wave_number in range(1, 13):
		var expected_wave := _build_campaign_wave(definition, wave_number, failures)
		if expected_wave == null:
			return
		var expected_path := "%s/wave_%02d.tres" % [wave_directory, wave_number]
		var actual_wave := actual_waves[wave_number - 1]
		if actual_wave.resource_path != expected_path:
			failures.append("流程图引用了错误的波次快照：%s" % expected_path)
			continue
		if (
			WAVE_CONTENT_CONTRACT.get_wave_signature(expected_wave)
			!= WAVE_CONTENT_CONTRACT.get_wave_signature(actual_wave)
		):
			failures.append("波次快照已偏离源资源或显式策略：%s" % expected_path)
		if definition["wave_policy"] == STANDARD_SHARED_POLICY:
			_assert_formal_label(expected_wave, SOURCE_WAVE_PATTERN % wave_number, failures)
			_assert_formal_label(actual_wave, expected_path, failures)

	var expected_boss := definition["boss_config"] as BossConfig
	var actual_bosses := campaign.get_bosses()
	var expected_step_count := 12 + (1 if expected_boss != null else 0)
	if campaign.flow_graph.steps.size() != expected_step_count:
		failures.append("流程图包含生成定义之外的节点：%s" % campaign.flow_graph.resource_path)
	if expected_boss == null:
		if not actual_bosses.is_empty():
			failures.append("无首领策略的 Campaign 不应包含首领：%s" % campaign_path)
	elif (
		actual_bosses.size() != 1
		or actual_bosses[0].resource_path != expected_boss.resource_path
	):
		failures.append("Campaign 首领快照与生成定义不一致：%s" % campaign_path)


func _get_campaign_directory(definition: Dictionary) -> String:
	return "%s/%s/%s" % [
		CAMPAIGN_ROOT,
		String(definition["mode"]),
		String(definition["players"]),
	]


func _build_campaign_wave(
	definition: Dictionary,
	wave_number: int,
	failures: PackedStringArray
) -> WaveConfig:
	var source_path := SOURCE_WAVE_PATTERN % wave_number
	var source_wave := load(source_path) as WaveConfig
	if source_wave == null:
		failures.append("无法加载源波次：%s" % source_path)
		return null
	var campaign_wave := source_wave.duplicate(true) as WaveConfig
	campaign_wave.spawn_point_mask = int(definition["spawn_point_mask"])

	# 单人与多人共享正式源；任何玩法差异都必须在定义中选择显式策略。
	match StringName(definition["wave_policy"]):
		STANDARD_SHARED_POLICY:
			pass
		TOWER_DEFENSE_STRESS_POLICY:
			_configure_tower_defense_stress_wave(campaign_wave, wave_number)
		_:
			failures.append(
				"Campaign %s 使用了未知波次策略。" % String(definition["campaign_id"])
			)
			return null
	return campaign_wave


func _assert_formal_label(
	wave_config: WaveConfig,
	resource_path: String,
	failures: PackedStringArray
) -> void:
	if WAVE_CONTENT_CONTRACT.has_test_label(wave_config):
		failures.append("正式 Standard 波次禁止测试标签：%s" % resource_path)


func _configure_tower_defense_stress_wave(
	wave_config: WaveConfig,
	wave_number: int
) -> void:
	wave_config.spawn_interval = (
		TOWER_DEFENSE_EARLY_WAVE_SPAWN_INTERVAL
		if wave_number <= TOWER_DEFENSE_EARLY_WAVE_COUNT
		else TOWER_DEFENSE_SEQUENTIAL_SPAWN_INTERVAL
	)
	wave_config.spawn_count_per_tick = TOWER_DEFENSE_SEQUENTIAL_SPAWN_COUNT_PER_TICK
	wave_config.max_alive_enemies = TOWER_DEFENSE_STRESS_MAX_ALIVE

	if wave_number == 1:
		wave_config.wave_name = "第1波 虫潮压力测试"
		wave_config.display_name = wave_config.wave_name
		wave_config.enemy_entries = [
			_create_wave_entry(
				TOWER_DEFENSE_STRESS_BASIC,
				TOWER_DEFENSE_FIRST_WAVE_BASIC_COUNT
			),
			_create_wave_entry(
				TOWER_DEFENSE_STRESS_SHELL,
				TOWER_DEFENSE_FIRST_WAVE_SHELL_COUNT
			),
			_create_wave_entry(
				TOWER_DEFENSE_STRESS_AK47,
				TOWER_DEFENSE_FIRST_WAVE_AK47_COUNT
			),
		]
	else:
		_merge_duplicate_wave_entries(wave_config.enemy_entries)
		_scale_wave_entries_to_total(
			wave_config.enemy_entries,
			TOWER_DEFENSE_STRESS_TOTAL_ENEMIES
		)

	if wave_number == 12:
		# 塔防铃兰需要独立的大量设计；压力战役目前在第12波后直接结束。
		wave_config.exits.clear()
		wave_config.post_clear_rest_duration = 0.0


func _create_wave_entry(enemy_config: EnemyConfig, count: int) -> WaveEnemyEntry:
	var entry := WAVE_ENEMY_ENTRY_SCRIPT.new() as WaveEnemyEntry
	entry.enemy_config = enemy_config
	entry.count = count
	return entry


func _merge_duplicate_wave_entries(entries: Array[WaveEnemyEntry]) -> void:
	var merged_entries: Array[WaveEnemyEntry] = []
	var entries_by_config_path: Dictionary = {}
	for entry in entries:
		if entry == null or entry.enemy_config == null:
			continue
		var config_path := entry.enemy_config.resource_path
		if entries_by_config_path.has(config_path):
			var existing := entries_by_config_path[config_path] as WaveEnemyEntry
			existing.count += entry.count
			continue
		entries_by_config_path[config_path] = entry
		merged_entries.append(entry)
	entries.assign(merged_entries)


func _scale_wave_entries_to_total(
	entries: Array[WaveEnemyEntry],
	target_total: int
) -> void:
	var source_total := 0
	for entry in entries:
		if entry != null and entry.enemy_config != null:
			source_total += maxi(entry.count, 0)
	if source_total <= 0 or target_total <= 0:
		return

	var allocated_total := 0
	var remainders: Array[Dictionary] = []
	for entry_index in range(entries.size()):
		var entry := entries[entry_index]
		if entry == null or entry.enemy_config == null:
			continue
		var exact_count := float(entry.count) * float(target_total) / float(source_total)
		entry.count = maxi(int(floor(exact_count)), 1)
		allocated_total += entry.count
		remainders.append({
			"entry_index": entry_index,
			"remainder": exact_count - floor(exact_count),
		})

	remainders.sort_custom(
		func(a: Dictionary, b: Dictionary) -> bool:
			var difference := float(a["remainder"]) - float(b["remainder"])
			if not is_zero_approx(difference):
				return difference > 0.0
			return int(a["entry_index"]) < int(b["entry_index"])
	)
	var remaining := target_total - allocated_total
	for remainder_index in range(remaining):
		var target_entry_index := int(
			remainders[remainder_index % remainders.size()]["entry_index"]
		)
		entries[target_entry_index].count += 1
