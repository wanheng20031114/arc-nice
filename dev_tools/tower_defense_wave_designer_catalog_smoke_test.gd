extends SceneTree

const WORKBOOK_PATH := "res://reports/塔防模式_4日战役智能设计器.xlsx"
const EXPECTED_NORMAL_WAVE_ENEMY_COUNT := 63
const EXPECTED_ROBOT_IDS := [
	"combat_robot",
	"combat_robot_elite",
	"combat_robot_gunner",
	"combat_robot_gunner_elite",
	"combat_robot_drone_operator",
	"combat_robot_drone_operator_elite",
	"combat_robot_shield_bearer",
	"combat_robot_shield_bearer_elite",
	"combat_robot_ninja",
	"combat_robot_ninja_elite",
	"combat_robot_main_battle_elite",
]
const DROP_COLUMN_BY_PATH := {
	"res://resources/config/materials/material_wood.tres": "O",
	"res://resources/config/materials/material_white_crystal.tres": "P",
	"res://resources/config/materials/material_sapling.tres": "Q",
	"res://resources/config/materials/material_capoo_blue_crystal.tres": "R",
	"res://resources/config/materials/material_sorcerer_violet_powder.tres": "S",
	"res://resources/config/materials/material_gel.tres": "T",
	"res://resources/config/materials/material_small_stone.tres": "U",
	"res://resources/config/pickup_triggered_items/speed_boots.tres": "V",
	"res://resources/config/pickup_triggered_items/rapid_magazine.tres": "W",
	"res://resources/config/pickup_triggered_items/tenpura.tres": "X",
	"res://resources/config/pickup_triggered_items/health_potion.tres": "Y",
	"res://resources/config/pickup_triggered_items/snow_wolf_pojun.tres": "Z",
}

var failures: Array[String] = []


func _init() -> void:
	var archive := ZIPReader.new()
	var open_error := archive.open(ProjectSettings.globalize_path(WORKBOOK_PATH))
	_expect(open_error == OK, "应能打开四日战役智能设计器。")
	if open_error != OK:
		_finish()
		return

	var worksheet_xml := ""
	var catalog_xml := ""
	var machine_xml := ""
	for file_path in archive.get_files():
		if not file_path.begins_with("xl/worksheets/sheet") or not file_path.ends_with(".xml"):
			continue
		var xml := archive.read_file(file_path).get_string_from_utf8()
		worksheet_xml += xml
		if xml.contains("敌人目录｜"):
			catalog_xml = xml
		elif xml.contains("敌人导入数据｜schema v3"):
			machine_xml = xml
	archive.close()

	_expect(not catalog_xml.is_empty(), "工作簿缺少敌人目录工作表。")
	_expect(not machine_xml.is_empty(), "工作簿缺少敌人导入机器区。")
	var expected_ids := PackedStringArray()
	for entry in EnemyCodexRegistry.get_all_entries():
		if entry.rank != EnemyCodexEntryConfig.Rank.BOSS:
			expected_ids.append(String(entry.entry_id))
	_expect(
		expected_ids.size() == EXPECTED_NORMAL_WAVE_ENEMY_COUNT,
		"运行时非Boss敌人目录应为63项。"
	)

	var actual_ids := _read_column_values(catalog_xml, "B", 6, 68)
	_expect(
		actual_ids == expected_ids,
		"Excel敌人目录必须按顺序完整匹配 EnemyCodexRegistry 的全部非Boss条目。"
	)
	_expect(
		_read_column_values(machine_xml, "B", 5, 67) == expected_ids,
		"Excel敌人导入机器区必须按顺序完整匹配 EnemyCodexRegistry。"
	)
	_expect(
		int((_read_row_values(machine_xml, 2)).get("F", -1))
		== EXPECTED_NORMAL_WAVE_ENEMY_COUNT,
		"Excel敌人导入机器区的enemy_count必须为63。"
	)
	for robot_id in EXPECTED_ROBOT_IDS:
		_expect(actual_ids.has(robot_id), "Excel敌人目录缺少机器人：%s" % robot_id)
	_validate_catalog_runtime_values(catalog_xml)
	_validate_machine_runtime_values(machine_xml)

	_expect(
		_count_regex(worksheet_xml, "\\$A\\$6:\\$A\\$68") == 12,
		"前三日日页的12个敌人下拉必须全部覆盖目录A6:A68。"
	)
	_expect(
		_count_regex(worksheet_xml, "\\$A\\$6:\\$M\\$68") == 216,
		"216个波次奖励查找必须全部覆盖目录A6:M68。"
	)
	_expect(
		_count_regex(worksheet_xml, "\\$A\\$6:\\$B\\$68") == 216,
		"216个稳定ID查找必须全部覆盖目录A6:B68。"
	)
	_expect(
		_count_regex(worksheet_xml, "\\$A\\$6:\\$[A-Z]+\\$54") == 0,
		"工作簿不得残留旧49项目录上界。"
	)
	_expect(
		catalog_xml.contains("sqref=\"G6:M68\"")
		and catalog_xml.contains("sqref=\"O6:Z68\""),
		"新增敌人的战斗数值与掉率必须继续受目录数据验证约束。"
	)
	_expect(
		_count_regex(catalog_xml, "<x:row r=\"(5[5-9]|6[0-8])\" ht=\"23\"") == 14,
		"新增14行必须延续敌人目录的23点行高。"
	)
	_finish()


func _read_column_values(
	xml: String,
	column: String,
	minimum_row: int,
	maximum_row: int
) -> PackedStringArray:
	var regex := RegEx.new()
	var compile_error := regex.compile(
		"<x:c r=\"%s([0-9]+)\"[^>]*>.*?<x:v>([^<]*)</x:v></x:c>" % column
	)
	_expect(compile_error == OK, "工作簿单元格正则应可编译：%s。" % column)
	var values := PackedStringArray()
	if compile_error != OK:
		return values
	for match_result in regex.search_all(xml):
		var row_number := int(match_result.get_string(1))
		if row_number >= minimum_row and row_number <= maximum_row:
			values.append(match_result.get_string(2))
	return values


func _validate_catalog_runtime_values(xml: String) -> void:
	var row_number := 6
	for entry in EnemyCodexRegistry.get_all_entries():
		if entry.rank == EnemyCodexEntryConfig.Rank.BOSS:
			continue
		var config := entry.enemy_config
		var cells := _read_row_values(xml, row_number)
		var expected_stats := {
			"G": float(config.max_health),
			"H": float(config.attack_damage),
			"I": float(config.physical_defense),
			"J": float(config.magic_defense),
			"K": float(config.move_speed),
			"L": float(config.home_damage),
			"M": float(config.xirang_kill_reward),
		}
		for column in expected_stats:
			_expect(cells.has(column), "敌人目录缺少数值单元格 %s%d。" % [column, row_number])
			if cells.has(column):
				_expect(
					is_equal_approx(float(cells[column]), float(expected_stats[column])),
					"敌人目录数值未同步 EnemyConfig：%s %s%d" % [
						entry.entry_id,
						column,
						row_number,
					]
				)
		_expect(
			cells.get("AC", "") == config.resource_path,
			"敌人目录配置路径未同步 EnemyConfig：%s" % entry.entry_id
		)
		_expect(
			cells.get("AD", "") == config.enemy_scene.resource_path,
			"敌人目录场景路径未同步 EnemyConfig：%s" % entry.entry_id
		)

		var expected_drops := {
			"O": 0.0, "P": 0.0, "Q": 0.0, "R": 0.0, "S": 0.0, "T": 0.0,
			"U": 0.0, "V": 0.0, "W": 0.0, "X": 0.0, "Y": 0.0, "Z": 0.0,
		}
		if config.drop_table != null:
			for rule in config.drop_table.get_eligible_rules(config.category_tags):
				if rule.pickup_config == null:
					continue
				var pickup_path := rule.pickup_config.resource_path
				_expect(
					DROP_COLUMN_BY_PATH.has(pickup_path),
					"敌人掉落没有设计器列映射：%s" % pickup_path
				)
				if DROP_COLUMN_BY_PATH.has(pickup_path):
					expected_drops[String(DROP_COLUMN_BY_PATH[pickup_path])] = rule.chance
		for column in expected_drops:
			_expect(cells.has(column), "敌人目录缺少掉率单元格 %s%d。" % [column, row_number])
			if cells.has(column):
				_expect(
					is_equal_approx(float(cells[column]), float(expected_drops[column])),
					"敌人目录掉率未同步 EnemyConfig：%s %s%d" % [
						entry.entry_id,
						column,
						row_number,
					]
				)
		row_number += 1


func _validate_machine_runtime_values(xml: String) -> void:
	var row_number := 5
	for entry in EnemyCodexRegistry.get_all_entries():
		if entry.rank == EnemyCodexEntryConfig.Rank.BOSS:
			continue
		var cells := _read_row_values(xml, row_number)
		_expect(
			cells.get("X", "") == entry.enemy_config.resource_path,
			"敌人导入机器区配置路径未同步 EnemyConfig：%s" % entry.entry_id
		)
		row_number += 1


func _read_row_values(xml: String, row_number: int) -> Dictionary:
	var regex := RegEx.new()
	var compile_error := regex.compile(
		"<x:c r=\"([A-Z]+)%d\"[^>]*>.*?<x:v>([^<]*)</x:v></x:c>" % row_number
	)
	_expect(compile_error == OK, "敌人目录行正则应可编译：%d" % row_number)
	var values := {}
	if compile_error != OK:
		return values
	for match_result in regex.search_all(xml):
		values[match_result.get_string(1)] = match_result.get_string(2)
	return values


func _count_regex(subject: String, pattern: String) -> int:
	var regex := RegEx.new()
	var compile_error := regex.compile(pattern)
	_expect(compile_error == OK, "工作簿契约正则应可编译：%s" % pattern)
	if compile_error != OK:
		return 0
	return regex.search_all(subject).size()


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)


func _finish() -> void:
	if failures.is_empty():
		print("TOWER_DEFENSE_WAVE_DESIGNER_CATALOG_SMOKE_TEST_OK")
		quit()
		return
	for failure in failures:
		push_error(failure)
	quit(1)
