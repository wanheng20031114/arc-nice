extends SceneTree

const SOURCE_WAVE_PATTERN := "res://resources/config/waves/wave_%02d.tres"
const CAMPAIGN_ROOT := "res://resources/config/campaigns"
const STANDARD_BOSS_CONFIG := preload("res://resources/config/bosses/boss_01_linglan.tres")
const WAVE_CAMPAIGN_CONFIG_SCRIPT := preload(
	"res://resources/config/waves/wave_campaign_config.gd"
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
const TOWER_DEFENSE_STRESS_TOTAL_ENEMIES := 1200
const TOWER_DEFENSE_STRESS_MAX_ALIVE := 300
const TOWER_DEFENSE_STRESS_SPAWN_INTERVAL := 0.1
const TOWER_DEFENSE_STRESS_SPAWN_COUNT_PER_TICK := 4
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
		"tower_defense_stress_test": false,
	},
	{
		"mode": "standard",
		"players": "multiplayer",
		"campaign_id": &"standard_multiplayer",
		"display_name": "普通模式 / 多人",
		"spawn_point_mask": WaveConfig.STANDARD_SPAWN_POINT_MASK,
		"boss_config": STANDARD_BOSS_CONFIG,
		"tower_defense_stress_test": false,
	},
	{
		"mode": "tower_defense",
		"players": "singleplayer",
		"campaign_id": &"tower_defense_singleplayer",
		"display_name": "塔防模式 / 单人",
		"spawn_point_mask": WaveConfig.ALL_SPAWN_POINT_MASK,
		"boss_config": null,
		"tower_defense_stress_test": true,
	},
	{
		"mode": "tower_defense",
		"players": "multiplayer",
		"campaign_id": &"tower_defense_multiplayer",
		"display_name": "塔防模式 / 多人",
		"spawn_point_mask": WaveConfig.ALL_SPAWN_POINT_MASK,
		"boss_config": null,
		"tower_defense_stress_test": true,
	},
]


func _init() -> void:
	if not OS.get_cmdline_user_args().has(FORCE_ARGUMENT):
		push_error(
			"该工具会覆写四套 Campaign 快照。确认后请使用 -- --force 显式运行。"
		)
		quit(2)
		return

	var failures := PackedStringArray()
	for definition in CAMPAIGNS:
		_generate_campaign(definition, failures)
	if failures.is_empty():
		print("GENERATE_WAVE_CAMPAIGN_RESOURCES_OK")
		quit()
		return
	for failure in failures:
		push_error(failure)
	quit(1)


func _generate_campaign(definition: Dictionary, failures: PackedStringArray) -> void:
	var directory := "%s/%s/%s" % [
		CAMPAIGN_ROOT,
		String(definition["mode"]),
		String(definition["players"]),
	]
	var absolute_directory := ProjectSettings.globalize_path(directory)
	var directory_error := DirAccess.make_dir_recursive_absolute(absolute_directory)
	if directory_error != OK:
		failures.append("无法创建 Campaign 目录 %s：%s" % [directory, error_string(directory_error)])
		return

	var campaign_waves: Array[WaveConfig] = []
	for wave_number in range(1, 13):
		var source_wave := load(SOURCE_WAVE_PATTERN % wave_number) as WaveConfig
		if source_wave == null:
			failures.append("无法加载源波次 %02d。" % wave_number)
			return
		var campaign_wave := source_wave.duplicate(true) as WaveConfig
		campaign_wave.spawn_point_mask = int(definition["spawn_point_mask"])
		if bool(definition["tower_defense_stress_test"]):
			_configure_tower_defense_stress_wave(campaign_wave, wave_number)
		var wave_path := "%s/wave_%02d.tres" % [directory, wave_number]
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


func _configure_tower_defense_stress_wave(
	wave_config: WaveConfig,
	wave_number: int
) -> void:
	wave_config.spawn_interval = TOWER_DEFENSE_STRESS_SPAWN_INTERVAL
	wave_config.spawn_count_per_tick = TOWER_DEFENSE_STRESS_SPAWN_COUNT_PER_TICK
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
