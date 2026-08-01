extends SceneTree

const EXPORT_PRESETS_PATH := "res://export_presets.cfg"
const REQUIRED_PRODUCTION_INCLUDE_FILTERS := [
	"resources/font/*.txt",
]
const REQUIRED_PRODUCTION_FILTERS := [
	"dev_tools/*",
	"tmp/*",
	"addons/flow_graph_editor/*",
	"relay_servers/*",
	"reports/*",
	"agent_skills/*",
	"resources/texture/boss_linglan/attack backup.png",
	"resources/texture/player/tiyi/24x24_backup.png",
	"resources/config/campaigns/tower_defense/performance/*",
	"resources/texture/luoxi_idle_hd.png",
	"resources/animation/luoxi_hd.tres",
	"resources/texture/zhuangfangyi_idle_hd.png",
	"resources/animation/zhuangfangyi_hd.tres",
	"resources/texture/zhuangfangyi_idle_hd_v2.png",
	"resources/animation/zhuangfangyi_hd_v2.tres",
	"resources/terrain/dual_grid/gray_metal_floor_reference_tile_32.png",
]

var failures: Array[String] = []


func _init() -> void:
	var config := ConfigFile.new()
	var load_error := config.load(EXPORT_PRESETS_PATH)
	_expect(load_error == OK, "export_presets.cfg must be readable.")
	if load_error == OK:
		_validate_export_presets(config)

	if failures.is_empty():
		print("EXPORT_PRESET_PRODUCTION_FILTER_SMOKE_TEST_OK")
		quit()
		return
	for failure in failures:
		push_error(failure)
	quit(1)


func _validate_export_presets(config: ConfigFile) -> void:
	var preset_sections := PackedStringArray()
	for section_variant in config.get_sections():
		var section := String(section_variant)
		if section.begins_with("preset.") and not section.contains(".options"):
			preset_sections.append(section)
	_expect(not preset_sections.is_empty(), "At least one export preset must exist.")
	for section in preset_sections:
		var preset_name := String(config.get_value(section, "name", section))
		var export_filter := String(config.get_value(section, "export_filter", ""))
		var include_filter := String(config.get_value(section, "include_filter", ""))
		var exclude_filter := String(config.get_value(section, "exclude_filter", ""))
		if export_filter != "all_resources":
			continue
		for required_filter in REQUIRED_PRODUCTION_INCLUDE_FILTERS:
			_expect(
				_has_filter(include_filter, required_filter),
				"All-resource export preset '%s' must include '%s' in production packages."
				% [preset_name, required_filter]
			)
		for required_filter in REQUIRED_PRODUCTION_FILTERS:
			_expect(
				_has_filter(exclude_filter, required_filter),
				"All-resource export preset '%s' must exclude '%s' from production packages."
				% [preset_name, required_filter]
			)


func _has_filter(filter_list: String, required_filter: String) -> bool:
	for filter_variant in filter_list.split(",", false):
		if String(filter_variant).strip_edges() == required_filter:
			return true
	return false


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
