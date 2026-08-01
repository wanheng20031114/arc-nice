extends SceneTree

const ARCHIVE_ARGUMENT_PREFIX := "--archive="
const COLLECTIBLE_CONFIG_DIR := "res://resources/config/collectibles"
const COLLECTIBLE_CONFIG_PREFIX := "collectible_"
const REQUIRED_ARCHIVE_PATHS := [
	"resources/font/NotoSansHans-Black-Apache-2.0.txt",
	"resources/font/ResourceHanRounded-OFL.txt",
]
const FORBIDDEN_ARCHIVE_PREFIXES := [
	"dev_tools/",
	"tmp/",
	"dev_assets/",
	"resources/样例用/",
	"addons/flow_graph_editor/",
	"relay_servers/",
	"reports/",
	"agent_skills/",
	"临时资源库(只取不写)/",
	"resources/config/campaigns/tower_defense/performance/",
]
const FORBIDDEN_ARCHIVE_PATHS := [
	"resources/texture/boss_linglan/attack backup.png",
	"resources/texture/boss_linglan/attack backup.png.import",
	"resources/texture/player/tiyi/24x24_backup.png",
	"resources/texture/player/tiyi/24x24_backup.png.import",
	"resources/texture/luoxi_idle_hd.png",
	"resources/texture/luoxi_idle_hd.png.import",
	"resources/animation/luoxi_hd.tres",
	"resources/animation/luoxi_hd.tres.remap",
	"resources/texture/zhuangfangyi_idle_hd.png",
	"resources/texture/zhuangfangyi_idle_hd.png.import",
	"resources/animation/zhuangfangyi_hd.tres",
	"resources/animation/zhuangfangyi_hd.tres.remap",
	"resources/texture/zhuangfangyi_idle_hd_v2.png",
	"resources/texture/zhuangfangyi_idle_hd_v2.png.import",
	"resources/animation/zhuangfangyi_hd_v2.tres",
	"resources/animation/zhuangfangyi_hd_v2.tres.remap",
	"resources/terrain/dual_grid/gray_metal_floor_reference_tile_32.png",
	"resources/terrain/dual_grid/gray_metal_floor_reference_tile_32.png.import",
]
const FORBIDDEN_IMPORTED_NAME_FRAGMENTS := [
	"attack backup.png-",
	"24x24_backup.png-",
	"luoxi_idle_hd.png-",
	"zhuangfangyi_idle_hd.png-",
	"zhuangfangyi_idle_hd_v2.png-",
	"gray_metal_floor_reference_tile_32.png-",
]

var failures: Array[String] = []


func _init() -> void:
	var archive_path := _get_archive_path()
	_expect(
		not archive_path.is_empty(),
		"Pass a real Godot export ZIP with --archive=<path>."
	)
	if not archive_path.is_empty():
		_validate_export_zip(archive_path)

	if failures.is_empty():
		print("EXPORT_PACKAGE_CONTENTS_SMOKE_TEST_OK")
		quit()
		return
	for failure in failures:
		push_error(failure)
	quit(1)


func _get_archive_path() -> String:
	for argument_variant in OS.get_cmdline_user_args():
		var argument := String(argument_variant)
		if argument.begins_with(ARCHIVE_ARGUMENT_PREFIX):
			var path := argument.trim_prefix(ARCHIVE_ARGUMENT_PREFIX)
			if path.begins_with("res://") or path.begins_with("user://"):
				return ProjectSettings.globalize_path(path)
			return path
	return ""


func _validate_export_zip(archive_path: String) -> void:
	_expect(FileAccess.file_exists(archive_path), "Export archive must exist: %s" % archive_path)
	if not FileAccess.file_exists(archive_path):
		return
	var reader := ZIPReader.new()
	var open_error := reader.open(archive_path)
	_expect(
		open_error == OK,
		"Export archive must be a readable ZIP produced by --export-pack: %s"
		% error_string(open_error)
	)
	if open_error != OK:
		return
	var archive_entries := reader.get_files()
	reader.close()
	var entry_set := {}
	for entry_variant in archive_entries:
		var entry := String(entry_variant).replace("\\", "/")
		entry_set[entry] = true
		_validate_entry_is_production_safe(entry)
	_validate_runtime_contract(entry_set)


func _validate_entry_is_production_safe(entry: String) -> void:
	for forbidden_prefix in FORBIDDEN_ARCHIVE_PREFIXES:
		_expect(
			not entry.begins_with(forbidden_prefix),
			"Production export contains forbidden path: %s" % entry
		)
	for forbidden_path in FORBIDDEN_ARCHIVE_PATHS:
		_expect(entry != forbidden_path, "Production export contains forbidden file: %s" % entry)
	if entry.begins_with(".godot/imported/"):
		for fragment in FORBIDDEN_IMPORTED_NAME_FRAGMENTS:
			_expect(
				not entry.contains(fragment),
				"Production export contains imported cache for excluded source: %s" % entry
			)


func _validate_runtime_contract(entry_set: Dictionary) -> void:
	_expect(entry_set.has("project.binary"), "Production export must contain project.binary.")
	for required_path in REQUIRED_ARCHIVE_PATHS:
		_expect(
			entry_set.has(required_path),
			"Production export is missing bundled font license: %s" % required_path
		)
	_expect(
		entry_set.has("scene/main_menu.tscn") or entry_set.has("scene/main_menu.tscn.remap"),
		"Production export must contain the main menu scene mapping."
	)
	var collectible_files := PackedStringArray()
	for file_name in ResourceLoader.list_directory(COLLECTIBLE_CONFIG_DIR):
		if (
			file_name.get_extension() == "tres"
			and file_name.begins_with(COLLECTIBLE_CONFIG_PREFIX)
		):
			collectible_files.append(file_name)
	collectible_files.sort()
	_expect(not collectible_files.is_empty(), "Development project must expose collectible configs.")
	for file_name in collectible_files:
		var source_path := "%s/%s" % [COLLECTIBLE_CONFIG_DIR.trim_prefix("res://"), file_name]
		_expect(
			entry_set.has(source_path) or entry_set.has("%s.remap" % source_path),
			"Production export is missing collectible config mapping: %s" % source_path
		)


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
