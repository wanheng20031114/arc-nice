extends SceneTree

const TARGET_WAVE_COUNT := 16
const CURRENT_FORMAL_WAVE_COUNT := 12
const WAVES_PER_DAY := 4
const FORMAL_WAVE_PATH := (
	"res://resources/config/campaigns/tower_defense/formal/wave_%02d.tres"
)
const PROGRESSION_CONFIG := preload(
	"res://resources/config/campaigns/tower_defense/formal_progression.tres"
)
const DAY_CYCLE_CONFIG := preload(
	"res://resources/config/day_cycle/tower_defense_day_cycle.tres"
)
const BOSS_CONFIG := preload("res://resources/config/bosses/boss_01_linglan.tres")

const OUTPUT_ARGUMENT_PREFIX := "--output="


func _init() -> void:
	var output_path := _get_output_path()
	if output_path.is_empty():
		push_error("缺少 --output=<JSON路径>。")
		quit(2)
		return
	var snapshot := _build_snapshot()
	if snapshot.is_empty():
		quit(1)
		return
	var absolute_output_path := _globalize_output_path(output_path)
	var output_directory := absolute_output_path.get_base_dir()
	var directory_error := DirAccess.make_dir_recursive_absolute(output_directory)
	if directory_error != OK:
		push_error(
			"无法创建导出目录 %s：%s"
			% [output_directory, error_string(directory_error)]
		)
		quit(1)
		return
	var output_file := FileAccess.open(absolute_output_path, FileAccess.WRITE)
	if output_file == null:
		push_error(
			"无法写入 %s：%s"
			% [absolute_output_path, error_string(FileAccess.get_open_error())]
		)
		quit(1)
		return
	output_file.store_string(JSON.stringify(snapshot, "\t", false))
	output_file.close()
	print("TOWER_DEFENSE_WAVE_DESIGNER_SNAPSHOT_OK %s" % absolute_output_path)
	quit()


func _get_output_path() -> String:
	for argument in OS.get_cmdline_user_args():
		if argument.begins_with(OUTPUT_ARGUMENT_PREFIX):
			return argument.trim_prefix(OUTPUT_ARGUMENT_PREFIX).strip_edges()
	return ""


func _globalize_output_path(path: String) -> String:
	if path.begins_with("res://") or path.begins_with("user://"):
		return ProjectSettings.globalize_path(path)
	return path


func _build_snapshot() -> Dictionary:
	var formal_waves: Array[WaveConfig] = []
	var used_enemy_config_paths := {}
	for wave_number in range(1, CURRENT_FORMAL_WAVE_COUNT + 1):
		var wave := load(FORMAL_WAVE_PATH % wave_number) as WaveConfig
		if wave == null:
			push_error("无法加载正式塔防第 %d 波。" % wave_number)
			return {}
		formal_waves.append(wave)
		for entry in wave.enemy_entries:
			if entry != null and entry.enemy_config != null:
				used_enemy_config_paths[entry.enemy_config.resource_path] = true

	var enemy_id_by_config_path := {}
	var enemies: Array[Dictionary] = []
	var boss: Dictionary = {}
	for codex_entry in EnemyCodexRegistry.get_all_entries():
		var enemy_config := codex_entry.enemy_config
		if enemy_config == null:
			push_error("敌人图鉴条目 %s 缺少 EnemyConfig。" % codex_entry.entry_id)
			return {}
		enemy_id_by_config_path[enemy_config.resource_path] = String(codex_entry.entry_id)
		var enemy_data := _serialize_enemy(
			codex_entry,
			used_enemy_config_paths.has(enemy_config.resource_path)
		)
		if codex_entry.rank == EnemyCodexEntryConfig.Rank.BOSS:
			boss = enemy_data
			boss["boss_config_path"] = codex_entry.boss_config.resource_path
			continue
		enemies.append(enemy_data)

	var waves: Array[Dictionary] = []
	for wave_number in range(1, TARGET_WAVE_COUNT + 1):
		if wave_number <= formal_waves.size():
			waves.append(
				_serialize_wave(
					formal_waves[wave_number - 1],
					wave_number,
					enemy_id_by_config_path,
					false
				)
			)
			continue
		waves.append(
			_create_placeholder_wave(
				formal_waves.back(),
				wave_number
			)
		)

	return {
		"schema_version": 1,
		"workbook_id": "tower_defense_wave_designer_v1",
		"campaign_id": "tower_defense_formal",
		"source_wave_count": CURRENT_FORMAL_WAVE_COUNT,
		"target_wave_count": TARGET_WAVE_COUNT,
		"day_count": TARGET_WAVE_COUNT / WAVES_PER_DAY,
		"waves_per_day": DAY_CYCLE_CONFIG.waves_per_day,
		"night_start_wave_in_day": DAY_CYCLE_CONFIG.night_start_wave_in_day,
		"boss_after_wave": TARGET_WAVE_COUNT,
		"progression": {
			"enemy_count_per_extra_player_ratio": (
				PROGRESSION_CONFIG.enemy_count_per_extra_player_ratio
			),
			"initial_preparation_seconds": (
				PROGRESSION_CONFIG.initial_preparation_seconds
			),
			"wave_intermission_seconds": (
				PROGRESSION_CONFIG.wave_intermission_seconds
			),
			"new_day_preparation_seconds": (
				PROGRESSION_CONFIG.new_day_preparation_seconds
			),
		},
		"enemies": enemies,
		"boss": boss,
		"waves": waves,
	}


func _serialize_enemy(
	codex_entry: EnemyCodexEntryConfig,
	formal_used: bool
) -> Dictionary:
	var config := codex_entry.enemy_config
	var drops: Array[Dictionary] = []
	var total_expected_drops := 0.0
	for rule in config.drop_table.get_eligible_rules(config.category_tags):
		if rule == null or rule.pickup_config == null:
			continue
		drops.append({
			"pickup_name": rule.pickup_config.display_name,
			"pickup_path": rule.pickup_config.resource_path,
			"chance": rule.chance,
			"required_tags": Array(rule.required_tags),
		})
		total_expected_drops += rule.chance
	return {
		"enemy_id": String(codex_entry.entry_id),
		"selection_label": "%s｜%s" % [codex_entry.entry_id, config.display_name],
		"display_name": config.display_name,
		"family_id": String(codex_entry.family_id),
		"family_label": codex_entry.family_label,
		"rank": EnemyCodexRegistry.get_rank_label(codex_entry.rank),
		"formal_used": formal_used,
		"can_spawn_in_normal_wave": (
			codex_entry.rank != EnemyCodexEntryConfig.Rank.BOSS
		),
		"config_path": config.resource_path,
		"scene_path": config.enemy_scene.resource_path,
		"category_tags": Array(config.category_tags),
		"max_health": config.max_health,
		"attack_damage": config.attack_damage,
		"physical_defense": config.physical_defense,
		"magic_defense": config.magic_defense,
		"move_speed": config.move_speed,
		"home_damage": config.home_damage,
		"base_xirang_reward": config.xirang_kill_reward,
		"expected_drop_count_per_kill": total_expected_drops,
		"drop_rules": drops,
	}


func _serialize_wave(
	wave: WaveConfig,
	wave_number: int,
	enemy_id_by_config_path: Dictionary,
	is_placeholder: bool
) -> Dictionary:
	var entries: Array[Dictionary] = []
	for entry in wave.enemy_entries:
		if entry == null or entry.enemy_config == null:
			continue
		var config_path := entry.enemy_config.resource_path
		if not enemy_id_by_config_path.has(config_path):
			push_error("第 %d 波使用了敌人目录之外的配置：%s" % [wave_number, config_path])
			return {}
		entries.append({
			"enemy_id": String(enemy_id_by_config_path[config_path]),
			"count": entry.count,
			"xirang_kill_reward_override": entry.xirang_kill_reward_override,
		})
	return {
		"wave_id": "wave_%02d" % wave_number,
		"wave_number": wave_number,
		"day": DAY_CYCLE_CONFIG.get_day_number(wave_number),
		"wave_in_day": DAY_CYCLE_CONFIG.get_wave_in_day(wave_number),
		"period": "夜晚" if DAY_CYCLE_CONFIG.is_night_wave(wave_number) else "白昼",
		"display_name": wave.wave_name,
		"spawn_point_mask": wave.spawn_point_mask,
		"spawn_interval": wave.spawn_interval,
		"spawn_count_per_tick": wave.spawn_count_per_tick,
		"max_alive_enemies": wave.max_alive_enemies,
		"music_path": wave.music.resource_path if wave.music != null else "",
		"post_wave_music_path": (
			wave.post_wave_music.resource_path if wave.post_wave_music != null else ""
		),
		"is_placeholder": is_placeholder,
		"entries": entries,
	}


func _create_placeholder_wave(template: WaveConfig, wave_number: int) -> Dictionary:
	# 占位波只继承全波节奏与音乐，绝不虚构敌人组成。
	return {
		"wave_id": "wave_%02d" % wave_number,
		"wave_number": wave_number,
		"day": DAY_CYCLE_CONFIG.get_day_number(wave_number),
		"wave_in_day": DAY_CYCLE_CONFIG.get_wave_in_day(wave_number),
		"period": "夜晚" if DAY_CYCLE_CONFIG.is_night_wave(wave_number) else "白昼",
		"display_name": "第%d波（待设计）" % wave_number,
		"spawn_point_mask": template.spawn_point_mask,
		"spawn_interval": template.spawn_interval,
		"spawn_count_per_tick": template.spawn_count_per_tick,
		"max_alive_enemies": template.max_alive_enemies,
		"music_path": template.music.resource_path if template.music != null else "",
		"post_wave_music_path": (
			template.post_wave_music.resource_path if template.post_wave_music != null else ""
		),
		"is_placeholder": true,
		"entries": [],
	}
