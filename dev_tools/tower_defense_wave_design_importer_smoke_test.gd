extends SceneTree

const IMPORTER_SCRIPT := "res://dev_tools/import_tower_defense_wave_design.gd"
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
const COMBAT_MUSIC := "res://resources/audio/shenmu_forest_combat.ogg"
const REST_MUSIC := "res://resources/audio/shenmu_forest_intermission.ogg"

var failures := PackedStringArray()
var temporary_files := PackedStringArray()


func _init() -> void:
	var production_snapshot := _snapshot_production_files()
	var test_directory := "user://tower_defense_wave_importer_smoke_%d" % OS.get_process_id()
	var make_directory_error := DirAccess.make_dir_recursive_absolute(
		ProjectSettings.globalize_path(test_directory)
	)
	_expect(make_directory_error == OK, "应能创建测试 JSON 目录。")
	if make_directory_error != OK:
		_finish()
		return

	var valid_document := _build_valid_document()
	var valid_path := "%s/valid.json" % test_directory
	_expect(_write_json(valid_path, valid_document), "应能写出合法测试 JSON。")
	var valid_result := _run_importer(valid_path)
	_expect(int(valid_result["exit_code"]) == 0, "合法 12 波四日战役应通过默认只校验模式。")
	_expect(
		String(valid_result["output"]).contains("TOWER_DEFENSE_WAVE_IMPORT_VALIDATE_OK"),
		"合法校验应输出成功标记。"
	)
	_expect(
		String(valid_result["output"]).contains(
			"TOWER_DEFENSE_WAVE_IMPORT_MODE validate_only writes=0"
		),
		"默认模式应明确声明未写入正式资源。"
	)
	_expect(
		_production_snapshot_matches(production_snapshot),
		"默认只校验模式不得创建、删除或修改任何正式波次/流程文件。"
	)

	var short_document := valid_document.duplicate(true) as Dictionary
	(short_document["waves"] as Array).pop_back()
	var short_path := "%s/short.json" % test_directory
	_expect(_write_json(short_path, short_document), "应能写出缺波测试 JSON。")
	var short_result := _run_importer(short_path)
	_expect(int(short_result["exit_code"]) != 0, "不足 12 波的设计必须被拒绝。")
	_expect(
		String(short_result["output"]).contains("TOWER_DEFENSE_WAVE_IMPORT_INVALID"),
		"缺波设计应输出失败标记。"
	)

	var invalid_document := valid_document.duplicate(true) as Dictionary
	var first_wave := (invalid_document["waves"] as Array)[0] as Dictionary
	first_wave["max_alive_enemies"] = 1000
	first_wave["music_path"] = "res://resources/audio/battle.ogg"
	var first_entries := first_wave["entries"] as Array
	var first_entry := first_entries[0] as Dictionary
	first_entry["count"] = 10000
	first_entry["xirang_kill_reward_override"] = 1000
	first_entries.append({
		"enemy_id": "yuanshi_insect_basic",
		"count": 1,
		"xirang_kill_reward_override": -1,
	})
	first_entries.append({
		"enemy_id": "linglan_boss",
		"count": 1,
		"xirang_kill_reward_override": -1,
	})
	var invalid_path := "%s/invalid.json" % test_directory
	_expect(_write_json(invalid_path, invalid_document), "应能写出非法测试 JSON。")
	var invalid_result := _run_importer(invalid_path)
	_expect(int(invalid_result["exit_code"]) != 0, "越界、重复及 Boss 条目必须被拒绝。")
	_expect(
		String(invalid_result["output"]).contains("error_count=6"),
		"非法样本应同时报告重复、Boss、四类边界/路径错误。"
	)
	_expect(
		_production_snapshot_matches(production_snapshot),
		"任何校验失败也不得修改正式波次/流程文件。"
	)

	var sixteen_wave_document := valid_document.duplicate(true) as Dictionary
	for wave_number in range(13, 17):
		var extra_wave := ((valid_document["waves"] as Array)[0] as Dictionary).duplicate(true)
		extra_wave["wave_id"] = "wave_%02d" % wave_number
		extra_wave["wave_number"] = wave_number
		(sixteen_wave_document["waves"] as Array).append(extra_wave)
	var sixteen_wave_path := "%s/sixteen_waves.json" % test_directory
	_expect(_write_json(sixteen_wave_path, sixteen_wave_document), "应能写出旧16波测试 JSON。")
	var sixteen_wave_result := _run_importer(sixteen_wave_path)
	_expect(int(sixteen_wave_result["exit_code"]) != 0, "旧16波设计必须被 schema v3 拒绝。")

	var short_ap_document := valid_document.duplicate(true) as Dictionary
	short_ap_document["daily_rogue_action_points"] = [5, 5]
	var short_ap_path := "%s/short_ap.json" % test_directory
	_expect(_write_json(short_ap_path, short_ap_document), "应能写出行动力长度错误样本。")
	_expect(int(_run_importer(short_ap_path)["exit_code"]) != 0, "行动力数组长度不是3时必须拒绝。")

	var negative_ap_document := valid_document.duplicate(true) as Dictionary
	negative_ap_document["daily_rogue_action_points"] = [5, -1, 5]
	var negative_ap_path := "%s/negative_ap.json" % test_directory
	_expect(_write_json(negative_ap_path, negative_ap_document), "应能写出负行动力样本。")
	_expect(int(_run_importer(negative_ap_path)["exit_code"]) != 0, "负行动力必须拒绝。")

	var wrong_boss_day_document := valid_document.duplicate(true) as Dictionary
	wrong_boss_day_document["boss_day"] = 3
	var wrong_boss_day_path := "%s/wrong_boss_day.json" % test_directory
	_expect(_write_json(wrong_boss_day_path, wrong_boss_day_document), "应能写出错误Boss日期样本。")
	_expect(int(_run_importer(wrong_boss_day_path)["exit_code"]) != 0, "Boss日期不是第4日时必须拒绝。")

	var rollback_result := _run_importer(
		valid_path,
		PackedStringArray(["--apply", "--test-fail-after-wave-commit"])
	)
	_expect(int(rollback_result["exit_code"]) != 0, "测试注入的提交失败必须返回失败。")
	_expect(
		String(rollback_result["output"]).contains("ROLLBACK_OK"),
		"提交失败应执行完整回滚。"
	)
	_expect(
		_production_snapshot_matches(production_snapshot),
		"提交失败后12波、单双人流程与成长配置必须逐字节恢复。"
	)

	_cleanup_test_files(test_directory)
	_finish()


func _build_valid_document() -> Dictionary:
	var waves: Array[Dictionary] = []
	for wave_number in range(1, 13):
		var use_maximum_bounds := wave_number == 12
		waves.append({
			"wave_id": "wave_%02d" % wave_number,
			"wave_number": wave_number,
			"display_name": "第%d波 导入器测试" % wave_number,
			"spawn_point_mask": 63 if use_maximum_bounds else 1,
			"spawn_interval": 60.0 if use_maximum_bounds else 0.025,
			"spawn_count_per_tick": 4 if use_maximum_bounds else 1,
			"max_alive_enemies": 999 if use_maximum_bounds else 1,
			"music_path": COMBAT_MUSIC,
			"post_wave_music_path": REST_MUSIC,
			"is_placeholder": false,
			"entries": [
				{
					"enemy_id": "yuanshi_insect_basic",
					"count": 9999 if use_maximum_bounds else 1,
					"xirang_kill_reward_override": 999 if use_maximum_bounds else -1,
				},
			],
		})
	return {
		"schema_version": 3,
		"campaign_id": "tower_defense_formal",
		"target_wave_count": 12,
		"day_count": 4,
		"waves_per_day": 4,
		"boss_after_wave": 12,
		"boss_day": 4,
		"boss_period": "day",
		"daily_rogue_action_points": [5, 5, 5],
		"waves": waves,
	}


func _run_importer(
	input_path: String,
	extra_arguments: PackedStringArray = PackedStringArray()
) -> Dictionary:
	var output: Array = []
	var arguments := PackedStringArray([
		"--headless",
		"--path",
		ProjectSettings.globalize_path("res://"),
		"--script",
		IMPORTER_SCRIPT,
		"--",
		"--input=%s" % ProjectSettings.globalize_path(input_path),
	])
	arguments.append_array(extra_arguments)
	var exit_code := OS.execute(OS.get_executable_path(), arguments, output, true)
	return {
		"exit_code": exit_code,
		"output": "\n".join(output),
	}


func _write_json(path: String, document: Dictionary) -> bool:
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		return false
	file.store_string(JSON.stringify(document, "\t", false))
	file.close()
	temporary_files.append(path)
	return true


func _snapshot_production_files() -> Dictionary:
	var result := {}
	for wave_number in range(1, 13):
		var path := FORMAL_WAVE_PATH_PATTERN % wave_number
		result[path] = _read_file_state(path)
	result[SINGLEPLAYER_FLOW_PATH] = _read_file_state(SINGLEPLAYER_FLOW_PATH)
	result[MULTIPLAYER_FLOW_PATH] = _read_file_state(MULTIPLAYER_FLOW_PATH)
	result[PROGRESSION_CONFIG_PATH] = _read_file_state(PROGRESSION_CONFIG_PATH)
	return result


func _production_snapshot_matches(snapshot: Dictionary) -> bool:
	for path_value in snapshot:
		var path := String(path_value)
		var before := snapshot[path] as Dictionary
		var after := _read_file_state(path)
		if bool(before["exists"]) != bool(after["exists"]):
			return false
		if bool(before["exists"]) and before["bytes"] != after["bytes"]:
			return false
	return true


func _read_file_state(path: String) -> Dictionary:
	if not FileAccess.file_exists(path):
		return {"exists": false, "bytes": PackedByteArray()}
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return {"exists": true, "bytes": PackedByteArray()}
	var bytes := file.get_buffer(file.get_length())
	file.close()
	return {"exists": true, "bytes": bytes}


func _cleanup_test_files(test_directory: String) -> void:
	for path in temporary_files:
		if FileAccess.file_exists(path):
			DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
	DirAccess.remove_absolute(ProjectSettings.globalize_path(test_directory))


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)


func _finish() -> void:
	if failures.is_empty():
		print("TOWER_DEFENSE_WAVE_DESIGN_IMPORTER_SMOKE_TEST_OK")
		quit()
		return
	for failure in failures:
		push_error(failure)
	quit(1)
