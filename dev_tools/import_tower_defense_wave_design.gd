extends SceneTree

## Imports the canonical tower-defense wave JSON contract.
##
## Validation is the default and never changes project resources. Production
## files are only replaced when --apply is supplied explicitly.

const SCHEMA_VERSION := 3
const CAMPAIGN_ID := "tower_defense_formal"
const WAVE_COUNT := 12
const DAY_COUNT := 4
const WAVES_PER_DAY := 4
const BOSS_DAY := 4
const BOSS_PERIOD := "day"
const ROGUE_EXPLORATION_DAY_COUNT := 3
const MAX_ENTRIES_PER_WAVE := 18
const MIN_ENEMY_COUNT := 1
const MAX_ENEMY_COUNT := 9999
const MIN_SPAWN_INTERVAL := 0.025
const MAX_SPAWN_INTERVAL := 60.0
const MIN_SPAWN_COUNT_PER_TICK := 1
const MAX_SPAWN_COUNT_PER_TICK := 4
const MIN_MAX_ALIVE_ENEMIES := 1
const MAX_MAX_ALIVE_ENEMIES := 999
const MIN_XIRANG_REWARD_OVERRIDE := -1
const MAX_XIRANG_REWARD_OVERRIDE := 999

const INPUT_ARGUMENT_PREFIX := "--input="
const APPLY_ARGUMENT := "--apply"
const TEST_FAIL_AFTER_WAVE_COMMIT_ARGUMENT := "--test-fail-after-wave-commit"

const FORMAL_WAVE_PATH_PATTERN := (
	"res://resources/config/campaigns/tower_defense/formal/wave_%02d.tres"
)
const SINGLEPLAYER_FLOW_PATH := (
	"res://resources/config/campaigns/tower_defense/singleplayer/flow.tres"
)
const MULTIPLAYER_FLOW_PATH := (
	"res://resources/config/campaigns/tower_defense/multiplayer/flow.tres"
)
const PROGRESSION_CONFIG_PATH := (
	"res://resources/config/campaigns/tower_defense/formal_progression.tres"
)
const BOSS_CONFIG: BossConfig = preload(
	"res://resources/config/bosses/boss_01_linglan.tres"
)
const WAVE_CONFIG_SCRIPT := preload("res://resources/config/waves/wave_config.gd")
const WAVE_ENEMY_ENTRY_SCRIPT := preload(
	"res://resources/config/waves/wave_enemy_entry.gd"
)
const FLOW_EXIT_CONFIG_SCRIPT := preload(
	"res://resources/config/flow/flow_exit_config.gd"
)

const ALLOWED_COMBAT_MUSIC_PATHS := {
	"res://resources/audio/shenmu_forest_combat.ogg": true,
	"res://resources/audio/shenmu_swamp_combat.ogg": true,
	"res://resources/audio/shenmu_town_combat.ogg": true,
}
const ALLOWED_POST_WAVE_MUSIC_PATHS := {
	"res://resources/audio/shenmu_forest_intermission.ogg": true,
	"res://resources/audio/shenmu_swamp_intermission.ogg": true,
	"res://resources/audio/shenmu_town_intermission.ogg": true,
}


func _init() -> void:
	var arguments := _parse_arguments()
	if not bool(arguments.get("valid", false)):
		quit(2)
		return

	var input_path := String(arguments["input_path"])
	var document: Variant = _load_json_document(input_path)
	if document == null:
		quit(2)
		return

	var errors := PackedStringArray()
	var plan := _validate_document(document, errors)
	if not errors.is_empty():
		_print_validation_errors(input_path, errors)
		quit(2)
		return

	var waves := _build_wave_resources(plan)
	if waves.size() != WAVE_COUNT:
		push_error("导入计划无法构建完整的 12 个 WaveConfig；未写入任何正式资源。")
		quit(1)
		return
	var graph_errors := _validate_built_graph(waves)
	if not graph_errors.is_empty():
		_print_validation_errors(input_path, graph_errors)
		quit(1)
		return

	_print_audit_summary(input_path, plan, false)
	if not bool(arguments["apply"]):
		print("当前为只校验模式；未写入任何正式塔防资源。需要应用时显式追加 --apply。")
		print("TOWER_DEFENSE_WAVE_IMPORT_MODE validate_only writes=0")
		print("TOWER_DEFENSE_WAVE_IMPORT_VALIDATE_OK")
		quit()
		return

	var apply_error := _apply_plan(
		plan,
		waves,
		bool(arguments["test_fail_after_wave_commit"])
	)
	if not apply_error.is_empty():
		push_error(apply_error)
		quit(1)
		return
	_print_audit_summary(input_path, plan, true)
	print("TOWER_DEFENSE_WAVE_IMPORT_APPLY_OK")
	quit()


func _parse_arguments() -> Dictionary:
	var input_path := ""
	var apply := false
	var test_fail_after_wave_commit := false
	for argument in OS.get_cmdline_user_args():
		if argument.begins_with(INPUT_ARGUMENT_PREFIX):
			if not input_path.is_empty():
				push_error("--input 只能提供一次。")
				return {"valid": false}
			input_path = argument.trim_prefix(INPUT_ARGUMENT_PREFIX).strip_edges()
		elif argument == APPLY_ARGUMENT:
			if apply:
				push_error("--apply 只能提供一次。")
				return {"valid": false}
			apply = true
		elif argument == TEST_FAIL_AFTER_WAVE_COMMIT_ARGUMENT:
			if test_fail_after_wave_commit:
				push_error("--test-fail-after-wave-commit 只能提供一次。")
				return {"valid": false}
			test_fail_after_wave_commit = true
		else:
			push_error("未知参数：%s" % argument)
			return {"valid": false}
	if input_path.is_empty():
		push_error(
			"缺少 --input=<JSON路径>。输入路径必须是绝对路径或 res:// 路径。"
		)
		return {"valid": false}
	if not input_path.begins_with("res://") and not input_path.is_absolute_path():
		push_error("--input 必须是绝对路径或 res:// 路径：%s" % input_path)
		return {"valid": false}
	if test_fail_after_wave_commit and not apply:
		push_error("--test-fail-after-wave-commit 只能与 --apply 一起使用。")
		return {"valid": false}
	return {
		"valid": true,
		"input_path": input_path,
		"apply": apply,
		"test_fail_after_wave_commit": test_fail_after_wave_commit,
	}


func _load_json_document(input_path: String) -> Variant:
	var absolute_path := (
		ProjectSettings.globalize_path(input_path)
		if input_path.begins_with("res://")
		else input_path
	)
	var input_file := FileAccess.open(absolute_path, FileAccess.READ)
	if input_file == null:
		push_error(
			"无法读取 %s：%s"
			% [absolute_path, error_string(FileAccess.get_open_error())]
		)
		return null
	var json_text := input_file.get_as_text()
	input_file.close()
	var parser := JSON.new()
	var parse_error := parser.parse(json_text)
	if parse_error != OK:
		push_error(
			"JSON 解析失败（第 %d 行）：%s"
			% [parser.get_error_line(), parser.get_error_message()]
		)
		return null
	return parser.data


func _validate_document(document: Variant, errors: PackedStringArray) -> Dictionary:
	if typeof(document) != TYPE_DICTIONARY:
		errors.append("根节点必须是 JSON 对象。")
		return {}
	var root := document as Dictionary
	var daily_rogue_action_points := _validate_root_identity(root, errors)
	var enemy_configs_by_id := _build_enemy_config_map(errors)
	var waves_value: Variant = root.get("waves")
	if typeof(waves_value) != TYPE_ARRAY:
		errors.append("waves 必须是数组。")
		return {}
	var source_waves := waves_value as Array
	if source_waves.size() != WAVE_COUNT:
		errors.append("waves 必须恰好包含 12 波，当前为 %d 波。" % source_waves.size())

	var normalized_waves: Array[Dictionary] = []
	var unique_enemy_ids := {}
	var total_enemy_count := 0
	var override_entry_count := 0
	for wave_index in range(source_waves.size()):
		if wave_index >= WAVE_COUNT:
			break
		var wave_number := wave_index + 1
		var normalized_wave := _validate_wave(
			source_waves[wave_index],
			wave_number,
			enemy_configs_by_id,
			errors
		)
		if normalized_wave.is_empty():
			continue
		normalized_waves.append(normalized_wave)
		for entry in normalized_wave["entries"] as Array[Dictionary]:
			unique_enemy_ids[String(entry["enemy_id"])] = true
			total_enemy_count += int(entry["count"])
			if int(entry["xirang_kill_reward_override"]) >= 0:
				override_entry_count += 1

	if normalized_waves.size() != WAVE_COUNT and errors.is_empty():
		errors.append("无法得到完整的 12 波规范化结果。")
	if not errors.is_empty():
		return {}
	return {
		"waves": normalized_waves,
		"daily_rogue_action_points": daily_rogue_action_points,
		"unique_enemy_count": unique_enemy_ids.size(),
		"total_enemy_count": total_enemy_count,
		"override_entry_count": override_entry_count,
	}


func _validate_root_identity(
	root: Dictionary,
	errors: PackedStringArray
) -> Array[int]:
	var daily_rogue_action_points: Array[int] = []
	var schema_version := _read_integer(
		root,
		"schema_version",
		SCHEMA_VERSION,
		SCHEMA_VERSION,
		"根节点",
		errors
	)
	if schema_version != SCHEMA_VERSION:
		return daily_rogue_action_points
	var campaign_value: Variant = root.get("campaign_id")
	if typeof(campaign_value) != TYPE_STRING:
		errors.append("根节点.campaign_id 必须是字符串。")
	elif String(campaign_value) != CAMPAIGN_ID:
		errors.append(
			"根节点.campaign_id 必须为 %s，当前为 %s。"
			% [CAMPAIGN_ID, String(campaign_value)]
		)
	_validate_required_exact_integer(root, "target_wave_count", WAVE_COUNT, errors)
	_validate_required_exact_integer(root, "day_count", DAY_COUNT, errors)
	_validate_required_exact_integer(root, "waves_per_day", WAVES_PER_DAY, errors)
	_validate_required_exact_integer(root, "boss_after_wave", WAVE_COUNT, errors)
	_validate_required_exact_integer(root, "boss_day", BOSS_DAY, errors)
	var boss_period_value: Variant = root.get("boss_period")
	if typeof(boss_period_value) != TYPE_STRING or String(boss_period_value) != BOSS_PERIOD:
		errors.append("根节点.boss_period 必须为字符串 %s。" % BOSS_PERIOD)
	var action_points_value: Variant = root.get("daily_rogue_action_points")
	if typeof(action_points_value) != TYPE_ARRAY:
		errors.append("根节点.daily_rogue_action_points 必须是长度为3的非负整数数组。")
		return daily_rogue_action_points
	var source_action_points := action_points_value as Array
	if source_action_points.size() != ROGUE_EXPLORATION_DAY_COUNT:
		errors.append(
			"根节点.daily_rogue_action_points 必须恰好包含第1至第3日共3项。"
		)
	for day_index in source_action_points.size():
		var value: Variant = source_action_points[day_index]
		if not _is_integer_number(value) or int(value) < 0:
			errors.append(
				"根节点.daily_rogue_action_points[%d] 必须是非负整数。"
				% day_index
			)
			continue
		daily_rogue_action_points.append(int(value))
	return daily_rogue_action_points


func _validate_required_exact_integer(
	dictionary: Dictionary,
	key: String,
	expected: int,
	errors: PackedStringArray
) -> void:
	if not dictionary.has(key):
		errors.append("根节点.%s 为 schema v3 必填字段。" % key)
		return
	var value: Variant = dictionary[key]
	if not _is_integer_number(value) or int(value) != expected:
		errors.append("根节点.%s 必须为整数 %d。" % [key, expected])


func _build_enemy_config_map(errors: PackedStringArray) -> Dictionary:
	var result := {}
	if not EnemyCodexRegistry.validate_contract():
		errors.append("EnemyCodexRegistry 自身契约无效，无法安全解析稳定 ID。")
		return result
	for codex_entry in EnemyCodexRegistry.get_all_entries():
		if codex_entry == null or codex_entry.enemy_config == null:
			errors.append("敌人图鉴包含缺少 EnemyConfig 的条目。")
			continue
		if codex_entry.rank == EnemyCodexEntryConfig.Rank.BOSS:
			continue
		result[String(codex_entry.entry_id)] = codex_entry.enemy_config
	return result


func _validate_wave(
	wave_value: Variant,
	wave_number: int,
	enemy_configs_by_id: Dictionary,
	errors: PackedStringArray
) -> Dictionary:
	var context := "waves[%d]" % (wave_number - 1)
	if typeof(wave_value) != TYPE_DICTIONARY:
		errors.append("%s 必须是对象。" % context)
		return {}
	var wave := wave_value as Dictionary
	var expected_wave_id := "wave_%02d" % wave_number
	var wave_id := _read_nonempty_string(wave, "wave_id", context, 32, errors)
	if not wave_id.is_empty() and wave_id != expected_wave_id:
		errors.append(
			"%s.wave_id 必须为 %s，当前为 %s。"
			% [context, expected_wave_id, wave_id]
		)
	if wave.has("wave_number"):
		var declared_wave_number := _read_integer(
			wave, "wave_number", wave_number, wave_number, context, errors
		)
		if declared_wave_number != wave_number:
			pass
	if wave.has("is_placeholder"):
		var placeholder_value: Variant = wave["is_placeholder"]
		if typeof(placeholder_value) != TYPE_BOOL:
			errors.append("%s.is_placeholder 必须是布尔值。" % context)
		elif bool(placeholder_value):
			errors.append("%s 仍标记为待设计，不能导入正式战役。" % expected_wave_id)

	var display_name := _read_nonempty_string(
		wave, "display_name", context, 80, errors
	)
	if display_name.contains("\n") or display_name.contains("\r"):
		errors.append("%s.display_name 不能包含换行。" % context)
	var spawn_point_mask := _read_integer(
		wave, "spawn_point_mask", 1, WaveConfig.ALL_SPAWN_POINT_MASK, context, errors
	)
	var spawn_interval := _read_float(
		wave,
		"spawn_interval",
		MIN_SPAWN_INTERVAL,
		MAX_SPAWN_INTERVAL,
		context,
		errors
	)
	var spawn_count_per_tick := _read_integer(
		wave,
		"spawn_count_per_tick",
		MIN_SPAWN_COUNT_PER_TICK,
		MAX_SPAWN_COUNT_PER_TICK,
		context,
		errors
	)
	var max_alive_enemies := _read_integer(
		wave,
		"max_alive_enemies",
		MIN_MAX_ALIVE_ENEMIES,
		MAX_MAX_ALIVE_ENEMIES,
		context,
		errors
	)
	var music_path := _read_music_path(wave, "music_path", context, errors)
	var post_wave_music_path := _read_music_path(
		wave, "post_wave_music_path", context, errors
	)

	var entries_value: Variant = wave.get("entries")
	if typeof(entries_value) != TYPE_ARRAY:
		errors.append("%s.entries 必须是数组。" % context)
		return {}
	var source_entries := entries_value as Array
	if source_entries.is_empty():
		errors.append("%s 必须至少配置 1 个敌人条目。" % expected_wave_id)
	elif source_entries.size() > MAX_ENTRIES_PER_WAVE:
		errors.append(
			"%s 最多允许 %d 个敌人条目，当前为 %d 个。"
			% [expected_wave_id, MAX_ENTRIES_PER_WAVE, source_entries.size()]
		)

	var normalized_entries: Array[Dictionary] = []
	var seen_enemy_ids := {}
	for entry_index in range(source_entries.size()):
		var entry_context := "%s.entries[%d]" % [context, entry_index]
		var entry_value: Variant = source_entries[entry_index]
		if typeof(entry_value) != TYPE_DICTIONARY:
			errors.append("%s 必须是对象。" % entry_context)
			continue
		var entry := entry_value as Dictionary
		var enemy_id := _read_nonempty_string(entry, "enemy_id", entry_context, 80, errors)
		if enemy_id == "linglan_boss":
			errors.append("%s 不能使用 Boss 敌人 linglan_boss。" % entry_context)
		elif not enemy_id.is_empty() and not enemy_configs_by_id.has(enemy_id):
			errors.append("%s.enemy_id 未在 EnemyCodexRegistry 中找到：%s" % [entry_context, enemy_id])
		if seen_enemy_ids.has(enemy_id) and not enemy_id.is_empty():
			errors.append("%s 内 enemy_id 重复：%s" % [expected_wave_id, enemy_id])
		elif not enemy_id.is_empty():
			seen_enemy_ids[enemy_id] = true
		var count := _read_integer(
			entry,
			"count",
			MIN_ENEMY_COUNT,
			MAX_ENEMY_COUNT,
			entry_context,
			errors
		)
		var reward_override := _read_xirang_reward_override(
			entry, entry_context, errors
		)
		if enemy_configs_by_id.has(enemy_id):
			normalized_entries.append({
				"enemy_id": enemy_id,
				"enemy_config": enemy_configs_by_id[enemy_id],
				"count": count,
				"xirang_kill_reward_override": reward_override,
			})

	return {
		"wave_id": expected_wave_id,
		"display_name": display_name,
		"spawn_point_mask": spawn_point_mask,
		"spawn_interval": spawn_interval,
		"spawn_count_per_tick": spawn_count_per_tick,
		"max_alive_enemies": max_alive_enemies,
		"music_path": music_path,
		"post_wave_music_path": post_wave_music_path,
		"entries": normalized_entries,
	}


func _read_nonempty_string(
	dictionary: Dictionary,
	key: String,
	context: String,
	max_length: int,
	errors: PackedStringArray
) -> String:
	var value: Variant = dictionary.get(key)
	if typeof(value) != TYPE_STRING:
		errors.append("%s.%s 必须是字符串。" % [context, key])
		return ""
	var text := String(value).strip_edges()
	if text.is_empty():
		errors.append("%s.%s 不能为空。" % [context, key])
	elif text.length() > max_length:
		errors.append("%s.%s 最长为 %d 个字符。" % [context, key, max_length])
	return text


func _read_integer(
	dictionary: Dictionary,
	key: String,
	minimum: int,
	maximum: int,
	context: String,
	errors: PackedStringArray
) -> int:
	var value: Variant = dictionary.get(key)
	if not _is_integer_number(value):
		errors.append("%s.%s 必须是整数。" % [context, key])
		return minimum
	var number := int(value)
	if number < minimum or number > maximum:
		errors.append(
			"%s.%s 必须在 %d..%d 范围内，当前为 %d。"
			% [context, key, minimum, maximum, number]
		)
	return number


func _read_float(
	dictionary: Dictionary,
	key: String,
	minimum: float,
	maximum: float,
	context: String,
	errors: PackedStringArray
) -> float:
	var value: Variant = dictionary.get(key)
	if typeof(value) != TYPE_INT and typeof(value) != TYPE_FLOAT:
		errors.append("%s.%s 必须是数值。" % [context, key])
		return minimum
	var number := float(value)
	if is_nan(number) or is_inf(number):
		errors.append("%s.%s 必须是有限数值。" % [context, key])
		return minimum
	if number < minimum or number > maximum:
		errors.append(
			"%s.%s 必须在 %.3f..%.3f 范围内，当前为 %s。"
			% [context, key, minimum, maximum, number]
		)
	return number


func _read_xirang_reward_override(
	entry: Dictionary,
	context: String,
	errors: PackedStringArray
) -> int:
	var value: Variant = entry.get("xirang_kill_reward_override")
	if not _is_integer_number(value):
		errors.append("%s.xirang_kill_reward_override 必须是整数。" % context)
		return MIN_XIRANG_REWARD_OVERRIDE
	var reward := int(value)
	if reward != -1 and (reward < 0 or reward > MAX_XIRANG_REWARD_OVERRIDE):
		errors.append(
			"%s.xirang_kill_reward_override 只能是 -1 或 0..999，当前为 %d。"
			% [context, reward]
		)
	return reward


func _read_music_path(
	wave: Dictionary,
	key: String,
	context: String,
	errors: PackedStringArray
) -> String:
	var value: Variant = wave.get(key)
	if typeof(value) != TYPE_STRING:
		errors.append("%s.%s 必须是字符串。" % [context, key])
		return ""
	var path := String(value)
	var allowed_paths := (
		ALLOWED_COMBAT_MUSIC_PATHS
		if key == "music_path"
		else ALLOWED_POST_WAVE_MUSIC_PATHS
	)
	if not allowed_paths.has(path):
		errors.append(
			"%s.%s 只能使用现有正式塔防%s曲目，当前为 %s。"
			% [context, key, "战斗" if key == "music_path" else "间歇", path]
		)
		return path
	var resource := load(path)
	if not resource is AudioStream:
		errors.append("%s.%s 不是可加载的 AudioStream：%s" % [context, key, path])
	return path


func _is_integer_number(value: Variant) -> bool:
	if typeof(value) == TYPE_INT:
		return true
	if typeof(value) != TYPE_FLOAT:
		return false
	var number := float(value)
	return not is_nan(number) and not is_inf(number) and number == floor(number)


func _build_wave_resources(plan: Dictionary) -> Array[WaveConfig]:
	var result: Array[WaveConfig] = []
	var normalized_waves := plan["waves"] as Array[Dictionary]
	for wave_index in range(normalized_waves.size()):
		var source := normalized_waves[wave_index]
		var wave := WAVE_CONFIG_SCRIPT.new() as WaveConfig
		wave.step_id = StringName(source["wave_id"])
		wave.wave_name = String(source["display_name"])
		wave.display_name = wave.wave_name
		wave.spawn_point_mask = int(source["spawn_point_mask"])
		wave.spawn_interval = float(source["spawn_interval"])
		wave.spawn_count_per_tick = int(source["spawn_count_per_tick"])
		wave.max_alive_enemies = int(source["max_alive_enemies"])
		wave.music = load(String(source["music_path"])) as AudioStream
		wave.post_wave_music = load(String(source["post_wave_music_path"])) as AudioStream
		wave.editor_position = Vector2(
			120.0 + float(wave_index % 4) * 360.0,
			-120.0 + float(wave_index / 4) * 220.0
		)
		var wave_entries: Array[WaveEnemyEntry] = []
		for source_entry in source["entries"] as Array[Dictionary]:
			var wave_entry := WAVE_ENEMY_ENTRY_SCRIPT.new() as WaveEnemyEntry
			wave_entry.enemy_config = source_entry["enemy_config"] as EnemyConfig
			wave_entry.count = int(source_entry["count"])
			wave_entry.xirang_kill_reward_override = int(
				source_entry["xirang_kill_reward_override"]
			)
			wave_entries.append(wave_entry)
		wave.enemy_entries = wave_entries
		var flow_exit := FLOW_EXIT_CONFIG_SCRIPT.new() as FlowExitConfig
		flow_exit.target_step_id = StringName(
			"wave_%02d" % (wave_index + 2)
			if wave_index + 1 < WAVE_COUNT
			else "boss_01_linglan"
		)
		var exits: Array[FlowExitConfig] = [flow_exit]
		wave.exits = exits
		result.append(wave)
	return result


func _validate_built_graph(waves: Array[WaveConfig]) -> PackedStringArray:
	var graph := _create_flow_graph(waves, "塔防模式 / 正式导入预检")
	return graph.validate_graph()


func _create_flow_graph(waves: Array[WaveConfig], graph_name: String) -> FlowGraphConfig:
	var graph := FlowGraphConfig.new()
	graph.graph_name = graph_name
	graph.start_step = waves[0] if not waves.is_empty() else null
	var steps: Array[FlowStepConfig] = []
	steps.assign(waves)
	steps.append(BOSS_CONFIG)
	graph.steps = steps
	return graph


func _apply_plan(
	plan: Dictionary,
	waves: Array[WaveConfig],
	test_fail_after_wave_commit: bool
) -> String:
	var run_id := "%d_%d" % [int(Time.get_unix_time_from_system()), OS.get_process_id()]
	var staging_root := "user://tower_defense_wave_import/staging_%s" % run_id
	var backup_root := "user://tower_defense_wave_import/backup_%s" % run_id
	var directory_error := DirAccess.make_dir_recursive_absolute(
		ProjectSettings.globalize_path(staging_root)
	)
	if directory_error != OK:
		return "无法创建导入暂存目录：%s" % error_string(directory_error)

	var staged_wave_paths := PackedStringArray()
	for wave_index in range(waves.size()):
		var stage_path := "%s/wave_%02d.tres" % [staging_root, wave_index + 1]
		var save_error := ResourceSaver.save(waves[wave_index], stage_path)
		if save_error != OK:
			_cleanup_staging(staging_root)
			return "预写入第 %d 波失败：%s" % [wave_index + 1, error_string(save_error)]
		staged_wave_paths.append(stage_path)

	var staged_waves: Array[WaveConfig] = []
	for wave_index in range(staged_wave_paths.size()):
		var staged_wave := ResourceLoader.load(
			staged_wave_paths[wave_index], "", ResourceLoader.CACHE_MODE_IGNORE
		) as WaveConfig
		if staged_wave == null:
			_cleanup_staging(staging_root)
			return "无法重新加载预写入的第 %d 波。" % (wave_index + 1)
		var verify_error := _verify_wave_resource(
			staged_wave, plan["waves"][wave_index] as Dictionary, wave_index + 1
		)
		if not verify_error.is_empty():
			_cleanup_staging(staging_root)
			return "预写入验证失败：%s" % verify_error
		staged_waves.append(staged_wave)

	var progression_stage_error := _stage_progression_config(plan, staging_root)
	if not progression_stage_error.is_empty():
		_cleanup_staging(staging_root)
		return progression_stage_error

	var preflight_flow_error := _preflight_flow_serialization(staging_root, staged_waves)
	if not preflight_flow_error.is_empty():
		_cleanup_staging(staging_root)
		return preflight_flow_error

	var backup_error := _create_backups(backup_root)
	if not backup_error.is_empty():
		_cleanup_staging(staging_root)
		return backup_error

	var commit_error := _commit_staged_resources(
		plan,
		staging_root,
		backup_root,
		test_fail_after_wave_commit
	)
	_cleanup_staging(staging_root)
	if not commit_error.is_empty():
		return commit_error
	print("可恢复备份：%s" % ProjectSettings.globalize_path(backup_root))
	return ""


func _stage_progression_config(plan: Dictionary, staging_root: String) -> String:
	var source_config := ResourceLoader.load(
		PROGRESSION_CONFIG_PATH,
		"",
		ResourceLoader.CACHE_MODE_IGNORE
	) as TowerDefenseProgressionConfig
	if source_config == null:
		return "无法加载正式塔防成长配置。"
	var staged_config := source_config.duplicate(true) as TowerDefenseProgressionConfig
	if staged_config == null:
		return "无法复制正式塔防成长配置。"
	var action_points: Array[int] = []
	action_points.assign(plan["daily_rogue_action_points"])
	staged_config.daily_rogue_action_points = action_points
	var config_errors := staged_config.validate_config()
	if not config_errors.is_empty():
		return "地下探索行动力无法形成有效成长配置：%s" % "；".join(config_errors)
	var stage_path := "%s/formal_progression.tres" % staging_root
	var save_error := ResourceSaver.save(staged_config, stage_path)
	if save_error != OK:
		return "成长配置预写入失败：%s" % error_string(save_error)
	var reloaded_config := ResourceLoader.load(
		stage_path,
		"",
		ResourceLoader.CACHE_MODE_IGNORE
	) as TowerDefenseProgressionConfig
	return _verify_progression_config(reloaded_config, action_points)


func _verify_progression_config(
	config: TowerDefenseProgressionConfig,
	expected_action_points: Array[int]
) -> String:
	if config == null:
		return "成长配置为空或无法重新加载。"
	var config_errors := config.validate_config()
	if not config_errors.is_empty():
		return "成长配置无效：%s" % "；".join(config_errors)
	if config.daily_rogue_action_points != expected_action_points:
		return "成长配置的每日地下探索行动力与导入计划不一致。"
	return ""


func _preflight_flow_serialization(
	staging_root: String,
	staged_waves: Array[WaveConfig]
) -> String:
	var graph := _create_flow_graph(staged_waves, "塔防模式 / 正式导入序列化预检")
	var flow_path := "%s/flow_preflight.tres" % staging_root
	var save_error := ResourceSaver.save(graph, flow_path)
	if save_error != OK:
		return "流程资源预写入失败：%s" % error_string(save_error)
	var loaded_graph := ResourceLoader.load(
		flow_path, "", ResourceLoader.CACHE_MODE_IGNORE
	) as FlowGraphConfig
	if loaded_graph == null:
		return "流程资源预写入后无法重新加载。"
	var errors := loaded_graph.validate_graph()
	if not errors.is_empty():
		return "流程资源预写入校验失败：%s" % "；".join(errors)
	return ""


func _create_backups(backup_root: String) -> String:
	var directory_error := DirAccess.make_dir_recursive_absolute(
		ProjectSettings.globalize_path(backup_root)
	)
	if directory_error != OK:
		return "无法创建导入备份目录：%s" % error_string(directory_error)
	for target in _get_target_file_definitions():
		var target_path := String(target["path"])
		var marker_path := "%s/%s.absent" % [backup_root, String(target["backup_name"])]
		if not FileAccess.file_exists(target_path):
			var marker := FileAccess.open(marker_path, FileAccess.WRITE)
			if marker == null:
				return "无法记录原先不存在的目标：%s" % target_path
			marker.store_string("absent")
			marker.close()
			continue
		var backup_path := "%s/%s" % [backup_root, String(target["backup_name"])]
		var copy_error := _copy_file_bytes(target_path, backup_path)
		if copy_error != OK:
			return "备份 %s 失败：%s" % [target_path, error_string(copy_error)]
	return ""


func _commit_staged_resources(
	plan: Dictionary,
	staging_root: String,
	backup_root: String,
	test_fail_after_wave_commit: bool
) -> String:
	for wave_number in range(1, WAVE_COUNT + 1):
		var source := "%s/wave_%02d.tres" % [staging_root, wave_number]
		var target := FORMAL_WAVE_PATH_PATTERN % wave_number
		var replace_error := _replace_file(source, target)
		if replace_error != OK:
			_rollback_from_backups(backup_root)
			return "替换 %s 失败，已尝试回滚：%s" % [target, error_string(replace_error)]

	var committed_waves: Array[WaveConfig] = []
	for wave_number in range(1, WAVE_COUNT + 1):
		var path := FORMAL_WAVE_PATH_PATTERN % wave_number
		var wave := ResourceLoader.load(
			path, "", ResourceLoader.CACHE_MODE_IGNORE
		) as WaveConfig
		if wave == null:
			_rollback_from_backups(backup_root)
			return "正式路径重新加载第 %d 波失败，已尝试回滚。" % wave_number
		var verify_error := _verify_wave_resource(
			wave, plan["waves"][wave_number - 1] as Dictionary, wave_number
		)
		if not verify_error.is_empty():
			_rollback_from_backups(backup_root)
			return "%s；已尝试回滚。" % verify_error
		committed_waves.append(wave)
	if test_fail_after_wave_commit:
		_rollback_from_backups(backup_root)
		return "测试注入：波次提交后故意失败；已尝试回滚。"

	var single_graph := _create_flow_graph(
		committed_waves, "塔防模式 / 正式单人战斗流程"
	)
	var multiplayer_graph := _create_flow_graph(
		committed_waves, "塔防模式 / 正式多人战斗流程"
	)
	var staged_flow_definitions := [
		{
			"graph": single_graph,
			"stage_path": "%s/singleplayer_flow.tres" % staging_root,
			"target_path": SINGLEPLAYER_FLOW_PATH,
		},
		{
			"graph": multiplayer_graph,
			"stage_path": "%s/multiplayer_flow.tres" % staging_root,
			"target_path": MULTIPLAYER_FLOW_PATH,
		},
	]
	for definition in staged_flow_definitions:
		var save_error := ResourceSaver.save(
			definition["graph"] as FlowGraphConfig,
			String(definition["stage_path"])
		)
		if save_error != OK:
			_rollback_from_backups(backup_root)
			return "写入流程暂存文件失败，已尝试回滚：%s" % error_string(save_error)
		var staged_graph := ResourceLoader.load(
			String(definition["stage_path"]), "", ResourceLoader.CACHE_MODE_IGNORE
		) as FlowGraphConfig
		var flow_error := _verify_flow_graph(staged_graph)
		if not flow_error.is_empty():
			_rollback_from_backups(backup_root)
			return "%s；已尝试回滚。" % flow_error

	for definition in staged_flow_definitions:
		var replace_error := _replace_file(
			String(definition["stage_path"]),
			String(definition["target_path"])
		)
		if replace_error != OK:
			_rollback_from_backups(backup_root)
			return "替换正式流程失败，已尝试回滚：%s" % error_string(replace_error)

	for flow_path in [SINGLEPLAYER_FLOW_PATH, MULTIPLAYER_FLOW_PATH]:
		var committed_graph := ResourceLoader.load(
			flow_path, "", ResourceLoader.CACHE_MODE_IGNORE
		) as FlowGraphConfig
		var flow_error := _verify_flow_graph(committed_graph)
		if not flow_error.is_empty():
			_rollback_from_backups(backup_root)
			return "%s；已尝试回滚。" % flow_error

	var progression_source := "%s/formal_progression.tres" % staging_root
	var progression_replace_error := _replace_file(
		progression_source,
		PROGRESSION_CONFIG_PATH
	)
	if progression_replace_error != OK:
		_rollback_from_backups(backup_root)
		return (
			"替换正式成长配置失败，已尝试回滚：%s"
			% error_string(progression_replace_error)
		)
	var committed_progression := ResourceLoader.load(
		PROGRESSION_CONFIG_PATH,
		"",
		ResourceLoader.CACHE_MODE_IGNORE
	) as TowerDefenseProgressionConfig
	var expected_action_points: Array[int] = []
	expected_action_points.assign(plan["daily_rogue_action_points"])
	var progression_error := _verify_progression_config(
		committed_progression,
		expected_action_points
	)
	if not progression_error.is_empty():
		_rollback_from_backups(backup_root)
		return "%s；已尝试回滚。" % progression_error
	return ""


func _verify_wave_resource(
	wave: WaveConfig,
	expected: Dictionary,
	wave_number: int
) -> String:
	if wave == null:
		return "第 %d 波资源为空。" % wave_number
	if wave.step_id != StringName(expected["wave_id"]):
		return "第 %d 波 step_id 不匹配。" % wave_number
	if wave.wave_name != String(expected["display_name"]):
		return "第 %d 波 display_name 不匹配。" % wave_number
	if wave.spawn_point_mask != int(expected["spawn_point_mask"]):
		return "第 %d 波 spawn_point_mask 不匹配。" % wave_number
	if not is_equal_approx(wave.spawn_interval, float(expected["spawn_interval"])):
		return "第 %d 波 spawn_interval 不匹配。" % wave_number
	if wave.spawn_count_per_tick != int(expected["spawn_count_per_tick"]):
		return "第 %d 波 spawn_count_per_tick 不匹配。" % wave_number
	if wave.max_alive_enemies != int(expected["max_alive_enemies"]):
		return "第 %d 波 max_alive_enemies 不匹配。" % wave_number
	if wave.music == null or wave.music.resource_path != String(expected["music_path"]):
		return "第 %d 波 music_path 不匹配。" % wave_number
	if (
		wave.post_wave_music == null
		or wave.post_wave_music.resource_path != String(expected["post_wave_music_path"])
	):
		return "第 %d 波 post_wave_music_path 不匹配。" % wave_number
	var expected_entries := expected["entries"] as Array[Dictionary]
	if wave.enemy_entries.size() != expected_entries.size():
		return "第 %d 波敌人条目数量不匹配。" % wave_number
	for entry_index in range(expected_entries.size()):
		var actual_entry := wave.enemy_entries[entry_index]
		var expected_entry := expected_entries[entry_index]
		if actual_entry == null or actual_entry.enemy_config == null:
			return "第 %d 波第 %d 个敌人条目为空。" % [wave_number, entry_index + 1]
		if (
			actual_entry.enemy_config.resource_path
			!= (expected_entry["enemy_config"] as EnemyConfig).resource_path
		):
			return "第 %d 波第 %d 个 enemy_id 解析结果不匹配。" % [wave_number, entry_index + 1]
		if actual_entry.count != int(expected_entry["count"]):
			return "第 %d 波第 %d 个 count 不匹配。" % [wave_number, entry_index + 1]
		if (
			actual_entry.xirang_kill_reward_override
			!= int(expected_entry["xirang_kill_reward_override"])
		):
			return "第 %d 波第 %d 个息壤奖励覆盖不匹配。" % [wave_number, entry_index + 1]
	var expected_target := (
		StringName("wave_%02d" % (wave_number + 1))
		if wave_number < WAVE_COUNT
		else &"boss_01_linglan"
	)
	var default_exit := wave.get_default_exit()
	if default_exit == null or default_exit.get_target_step_id() != expected_target:
		return "第 %d 波默认出口不匹配。" % wave_number
	return ""


func _verify_flow_graph(graph: FlowGraphConfig) -> String:
	if graph == null:
		return "正式流程资源无法加载。"
	var graph_errors := graph.validate_graph()
	if not graph_errors.is_empty():
		return "正式流程图无效：%s" % "；".join(graph_errors)
	if graph.steps.size() != WAVE_COUNT + 1:
		return "正式流程必须包含 12 波与 1 个 Boss。"
	if graph.start_step == null or graph.start_step.step_id != &"wave_01":
		return "正式流程起点必须是 wave_01。"
	for wave_index in range(WAVE_COUNT):
		if graph.steps[wave_index].step_id != StringName("wave_%02d" % (wave_index + 1)):
			return "正式流程的第 %d 个节点顺序错误。" % (wave_index + 1)
	if graph.steps[WAVE_COUNT].step_id != &"boss_01_linglan":
		return "正式流程的末节点必须是 boss_01_linglan。"
	return ""


func _get_target_file_definitions() -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	for wave_number in range(1, WAVE_COUNT + 1):
		result.append({
			"path": FORMAL_WAVE_PATH_PATTERN % wave_number,
			"backup_name": "wave_%02d.tres" % wave_number,
		})
	result.append({
		"path": SINGLEPLAYER_FLOW_PATH,
		"backup_name": "singleplayer_flow.tres",
	})
	result.append({
		"path": MULTIPLAYER_FLOW_PATH,
		"backup_name": "multiplayer_flow.tres",
	})
	result.append({
		"path": PROGRESSION_CONFIG_PATH,
		"backup_name": "formal_progression.tres",
	})
	return result


func _rollback_from_backups(backup_root: String) -> void:
	var rollback_errors := PackedStringArray()
	for target in _get_target_file_definitions():
		var target_path := String(target["path"])
		var backup_name := String(target["backup_name"])
		var backup_path := "%s/%s" % [backup_root, backup_name]
		var marker_path := "%s/%s.absent" % [backup_root, backup_name]
		if FileAccess.file_exists(backup_path):
			var replace_error := _replace_file(backup_path, target_path)
			if replace_error != OK:
				rollback_errors.append("恢复 %s 失败：%s" % [target_path, error_string(replace_error)])
		elif FileAccess.file_exists(marker_path) and FileAccess.file_exists(target_path):
			var remove_error := DirAccess.remove_absolute(
				ProjectSettings.globalize_path(target_path)
			)
			if remove_error != OK:
				rollback_errors.append("移除新文件 %s 失败：%s" % [target_path, error_string(remove_error)])
	if rollback_errors.is_empty():
		print("ROLLBACK_OK %s" % ProjectSettings.globalize_path(backup_root))
	else:
		for rollback_error in rollback_errors:
			push_error(rollback_error)


func _copy_file_bytes(source_path: String, destination_path: String) -> Error:
	var source_absolute := ProjectSettings.globalize_path(source_path)
	var destination_absolute := ProjectSettings.globalize_path(destination_path)
	var source := FileAccess.open(source_absolute, FileAccess.READ)
	if source == null:
		return FileAccess.get_open_error()
	var destination := FileAccess.open(destination_absolute, FileAccess.WRITE)
	if destination == null:
		source.close()
		return FileAccess.get_open_error()
	destination.store_buffer(source.get_buffer(source.get_length()))
	source.close()
	destination.close()
	return OK


func _replace_file(source_path: String, target_path: String) -> Error:
	var target_absolute := ProjectSettings.globalize_path(target_path)
	var temporary_absolute := "%s.wave_import_tmp" % target_absolute
	var copy_error := _copy_file_bytes(source_path, temporary_absolute)
	if copy_error != OK:
		return copy_error
	if FileAccess.file_exists(target_absolute):
		var remove_error := DirAccess.remove_absolute(target_absolute)
		if remove_error != OK:
			DirAccess.remove_absolute(temporary_absolute)
			return remove_error
	var rename_error := DirAccess.rename_absolute(temporary_absolute, target_absolute)
	if rename_error != OK:
		DirAccess.remove_absolute(temporary_absolute)
	return rename_error


func _cleanup_staging(staging_root: String) -> void:
	var absolute_root := ProjectSettings.globalize_path(staging_root)
	var directory := DirAccess.open(absolute_root)
	if directory == null:
		return
	directory.list_dir_begin()
	var file_name := directory.get_next()
	while not file_name.is_empty():
		if not directory.current_is_dir():
			DirAccess.remove_absolute(absolute_root.path_join(file_name))
		file_name = directory.get_next()
	directory.list_dir_end()
	DirAccess.remove_absolute(absolute_root)


func _print_validation_errors(input_path: String, errors: PackedStringArray) -> void:
	push_error("塔防波次 JSON 校验失败：%s" % input_path)
	print("塔防波次 JSON 校验失败：%s" % input_path)
	for error in errors:
		push_error("- %s" % error)
		print("- %s" % error)
	print("TOWER_DEFENSE_WAVE_IMPORT_INVALID error_count=%d" % errors.size())


func _print_audit_summary(input_path: String, plan: Dictionary, applied: bool) -> void:
	print("=== 塔防正式战役导入审计 ===")
	print("输入：%s" % input_path)
	print("模式：%s" % ("应用" if applied else "只校验"))
	print("schema_version=%d campaign_id=%s" % [SCHEMA_VERSION, CAMPAIGN_ID])
	print(
		"波次=%d 敌人种类=%d 基础敌人总数=%d 息壤覆盖条目=%d"
		% [
			WAVE_COUNT,
			int(plan["unique_enemy_count"]),
			int(plan["total_enemy_count"]),
			int(plan["override_entry_count"]),
		]
	)
	for wave in plan["waves"] as Array[Dictionary]:
		var wave_total := 0
		var override_count := 0
		for entry in wave["entries"] as Array[Dictionary]:
			wave_total += int(entry["count"])
			if int(entry["xirang_kill_reward_override"]) >= 0:
				override_count += 1
		print(
			"%s | %s | 条目=%d 敌人=%d 覆盖=%d 出生点掩码=%d 间隔=%.3f 每批=%d 存活上限=%d"
			% [
				String(wave["wave_id"]),
				String(wave["display_name"]),
				(wave["entries"] as Array).size(),
				wave_total,
				override_count,
				int(wave["spawn_point_mask"]),
				float(wave["spawn_interval"]),
				int(wave["spawn_count_per_tick"]),
				int(wave["max_alive_enemies"]),
			]
		)
