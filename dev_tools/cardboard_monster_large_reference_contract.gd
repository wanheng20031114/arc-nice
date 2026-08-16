extends RefCounted

const LARGE_CONFIG_PATH := (
	"res://resources/config/enemies/cardboard_monster_large.tres"
)
const FORMAL_CAMPAIGN_ROOT := (
	"res://resources/config/campaigns/tower_defense/formal"
)
const FORMAL_WAVE_12_PATH := FORMAL_CAMPAIGN_ROOT + "/wave_12.tres"


# 两个入口测试共用这一份精确合同，避免一个只放行路径、另一个忘记校验
# 作者资源内容。返回全部错误，让调用方沿用自己的失败汇总方式。
static func validate_formal_wave_12_contract() -> Array[String]:
	var errors: Array[String] = []
	var references := _find_text_references(
		FORMAL_CAMPAIGN_ROOT,
		LARGE_CONFIG_PATH,
		errors
	)
	references.sort()
	var expected_references: Array[String] = [FORMAL_WAVE_12_PATH]
	if references != expected_references:
		errors.append(
			"正式塔防大纸箱怪直引必须精确限定在第 12 波：%s。"
			% [references]
		)

	var formal_wave := load(FORMAL_WAVE_12_PATH) as WaveConfig
	if formal_wave == null:
		errors.append("正式塔防第 12 波必须可强类型加载为 WaveConfig。")
		return errors
	var matching_entry_count := 0
	var authored_enemy_count := 0
	for entry in formal_wave.enemy_entries:
		if (
			entry != null
			and entry.enemy_config != null
			and entry.enemy_config.resource_path == LARGE_CONFIG_PATH
		):
			matching_entry_count += 1
			authored_enemy_count += entry.count
	if matching_entry_count != 1 or authored_enemy_count != 400:
		errors.append(
			"正式塔防第 12 波必须只含一个大纸箱怪条目，作者数量必须为 400。"
		)
	return errors


static func _find_text_references(
	directory_path: String,
	needle: String,
	errors: Array[String]
) -> Array[String]:
	var matches: Array[String] = []
	var directory := DirAccess.open(directory_path)
	if directory == null:
		errors.append("无法打开正式塔防直引审计目录：%s。" % directory_path)
		return matches
	directory.list_dir_begin()
	var entry_name := directory.get_next()
	while not entry_name.is_empty():
		if entry_name != "." and entry_name != "..":
			var child_path := directory_path.path_join(entry_name)
			if directory.current_is_dir():
				matches.append_array(
					_find_text_references(child_path, needle, errors)
				)
			elif entry_name.get_extension() in ["tres", "tscn", "gd"]:
				var source := FileAccess.get_file_as_string(child_path)
				if needle in source:
					matches.append(child_path)
		entry_name = directory.get_next()
	directory.list_dir_end()
	return matches
