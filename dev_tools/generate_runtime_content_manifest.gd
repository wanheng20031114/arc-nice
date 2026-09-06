extends SceneTree

const RuntimeContentCatalogScript := preload(
	"res://resources/config/runtime_content_catalog.gd"
)
const PlantDefenseRegistryScript := preload(
	"res://resources/config/plant_defense/plant_defense_registry.gd"
)
const ProductionRecipeRegistryScript := preload(
	"res://resources/config/production/production_recipe_registry.gd"
)

const WRITE_ARGUMENT := "--write"
const CHECK_ARGUMENT := "--check"
const CAMPAIGN_ROOT := "res://resources/config/campaigns"
const MANIFEST_OUTPUT_PATH := (
	"res://resources/config/generated/runtime_content_manifest.schema1.json"
)
const CONSTANTS_OUTPUT_PATH := (
	"res://resources/config/generated/runtime_content_manifest.gd"
)
const SCHEMA_VERSION := 1
const EXPECTED_ENEMY_COUNT := 64
const EXPECTED_PICKUP_COUNT := 181
const EXPECTED_CAMPAIGN_COUNT := 26
const EXPECTED_PLANT_DEFENSE_CONFIG_COUNT := 19
const EXPECTED_PRODUCTION_RECIPE_COUNT := 32
const GLOBAL_RESEARCH_REGISTRY_PATH := (
	"res://resources/config/research/global_research_registry.gd"
)
const PLANT_DEFENSE_REGISTRY_PATH := (
	"res://resources/config/plant_defense/plant_defense_registry.gd"
)
const PRODUCTION_RECIPE_REGISTRY_PATH := (
	"res://resources/config/production/production_recipe_registry.gd"
)
const TOWER_DEFENSE_GAME_SCENE_PATH := (
	"res://scene/game_modes/tower_defense/tower_defense_game.tscn"
)
## 这些玩法资源不是敌人、道具或 Campaign 根，但其中的稳定 ID 会直接进入
## 多人命令与运行时快照，必须参与同构建内容摘要。
const EXPLICIT_GAMEPLAY_DEPENDENCY_ROOTS := [
	GLOBAL_RESEARCH_REGISTRY_PATH,
	PLANT_DEFENSE_REGISTRY_PATH,
	PRODUCTION_RECIPE_REGISTRY_PATH,
	"res://resources/config/collectibles/collectible_registry.gd",
	"res://scene/game_modes/rogue/encounter/rogue_encounter_registry.gd",
	"res://resources/texture/rogue_encounter/deep_sea_ruins.png",
	TOWER_DEFENSE_GAME_SCENE_PATH,
	"res://scene/plant_defense/wood_processing_station.tscn",
	# PVP does not use a WaveCampaign. Include its scene and GDScript-preloaded
	# combat entities explicitly, so mismatched map/weapon/network builds cannot
	# join a shared authoritative match with the same content digest.
	"res://scene/game_modes/game_mode_catalog.tres",
	"res://scene/multiplayer/net_manager.gd",
	"res://scene/multiplayer/net_constants.gd",
	"res://scene/pvp/mirage_pvp.tscn",
	"res://scene/pvp/pvp_player.tscn",
	"res://scene/pvp/pvp_projectile.tscn",
	"res://scene/pvp/pvp_weapon_pickup.tscn",
	"res://scene/pvp/pvp_rules.gd",
]
const TEXT_EXTENSIONS := {
	"cfg": true,
	"csv": true,
	"gd": true,
	"gdshader": true,
	"gdshaderinc": true,
	"import": true,
	"json": true,
	"shader": true,
	"svg": true,
	"tres": true,
	"tscn": true,
	"txt": true,
	"xml": true,
}

var failures: Array[String] = []


func _init() -> void:
	call_deferred(&"_run")


func _run() -> void:
	var arguments := OS.get_cmdline_user_args()
	var should_write := arguments.has(WRITE_ARGUMENT)
	var should_check := arguments.has(CHECK_ARGUMENT)
	if should_write == should_check:
		push_error("请使用 -- --write 生成内容清单，或使用 -- --check 校验已提交清单。")
		quit(2)
		return

	var generated := _build_generated_outputs()
	if failures.is_empty():
		if should_check:
			_check_output(MANIFEST_OUTPUT_PATH, str(generated.get("manifest", "")))
			_check_output(CONSTANTS_OUTPUT_PATH, str(generated.get("constants", "")))
		else:
			_write_output(MANIFEST_OUTPUT_PATH, str(generated.get("manifest", "")))
			_write_output(CONSTANTS_OUTPUT_PATH, str(generated.get("constants", "")))

	if failures.is_empty():
		print(
			"CHECK_RUNTIME_CONTENT_MANIFEST_OK"
			if should_check
			else "GENERATE_RUNTIME_CONTENT_MANIFEST_OK"
		)
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	quit(1)


func _build_generated_outputs() -> Dictionary:
	var enemy_roots := _build_catalog_roots(
		"enemy",
		RuntimeContentCatalogScript.get_enemy_entries(),
		EXPECTED_ENEMY_COUNT
	)
	var pickup_roots := _build_catalog_roots(
		"pickup",
		RuntimeContentCatalogScript.get_pickup_entries(),
		EXPECTED_PICKUP_COUNT
	)
	var campaign_roots := _build_campaign_roots()
	var dependency_entries := _build_dependency_entries(
		enemy_roots,
		pickup_roots,
		campaign_roots
	)
	if not failures.is_empty():
		return {}

	var canonical_lines := PackedStringArray(["schema|%d" % SCHEMA_VERSION])
	_append_root_lines(canonical_lines, "enemy", enemy_roots)
	_append_root_lines(canonical_lines, "pickup", pickup_roots)
	_append_root_lines(canonical_lines, "campaign", campaign_roots)
	for entry in dependency_entries:
		canonical_lines.append(
			"dependency|%s|%s" % [str(entry.get("path", "")), str(entry.get("sha256", ""))]
		)
	var content_sha256 := "\n".join(canonical_lines).sha256_text()
	var manifest_data := {
		"schema_version": SCHEMA_VERSION,
		"content_sha256": content_sha256,
		"enemy_roots": enemy_roots,
		"pickup_roots": pickup_roots,
		"campaign_roots": campaign_roots,
		"dependencies": dependency_entries,
	}
	var manifest_text := JSON.stringify(manifest_data, "\t", false) + "\n"
	var constants_text := _build_constants_source(
		content_sha256,
		enemy_roots.size(),
		pickup_roots.size(),
		campaign_roots.size(),
		dependency_entries.size()
	)
	return {
		"manifest": manifest_text,
		"constants": constants_text,
	}


func _build_catalog_roots(
	kind: String,
	entries: Dictionary,
	expected_count: int
) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	if entries.size() != expected_count:
		failures.append(
			"%s 内容根数量必须为 %d，实际为 %d。"
			% [kind, expected_count, entries.size()]
		)
		return result
	var ids := PackedStringArray(entries.keys())
	ids.sort()
	var seen_paths: Dictionary[String, bool] = {}
	for content_id in ids:
		var resource_path := str(entries.get(content_id, ""))
		if not _is_safe_manifest_field(content_id) or not _is_safe_resource_path(resource_path):
			failures.append("%s 内容根包含非法 ID 或路径：%s -> %s。" % [kind, content_id, resource_path])
			continue
		if seen_paths.has(resource_path):
			failures.append("%s 内容根重复引用路径：%s。" % [kind, resource_path])
			continue
		if not FileAccess.file_exists(resource_path):
			failures.append("%s 内容根不存在：%s。" % [kind, resource_path])
			continue
		seen_paths[resource_path] = true
		result.append({"id": content_id, "path": resource_path})
	return result


func _build_campaign_roots() -> Array[Dictionary]:
	var campaign_paths: Array[String] = []
	_collect_campaign_paths(CAMPAIGN_ROOT, campaign_paths)
	campaign_paths.sort()
	if campaign_paths.size() != EXPECTED_CAMPAIGN_COUNT:
		failures.append(
			"WaveCampaignConfig 内容根数量必须为 %d，实际为 %d。"
			% [EXPECTED_CAMPAIGN_COUNT, campaign_paths.size()]
		)
	var result: Array[Dictionary] = []
	var seen_ids: Dictionary[String, bool] = {}
	for campaign_path in campaign_paths:
		var campaign := ResourceLoader.load(campaign_path) as WaveCampaignConfig
		if campaign == null:
			failures.append("Campaign 内容根无法加载：%s。" % campaign_path)
			continue
		var campaign_id := String(campaign.campaign_id)
		if not _is_safe_manifest_field(campaign_id):
			failures.append("Campaign 缺少合法稳定 ID：%s。" % campaign_path)
			continue
		if seen_ids.has(campaign_id):
			failures.append("Campaign 稳定 ID 重复：%s。" % campaign_id)
			continue
		seen_ids[campaign_id] = true
		result.append({"id": campaign_id, "path": campaign_path})
	return result


func _collect_campaign_paths(directory_path: String, result: Array[String]) -> void:
	var directory := DirAccess.open(directory_path)
	if directory == null:
		failures.append("无法遍历 Campaign 目录：%s。" % directory_path)
		return
	directory.list_dir_begin()
	var entry_names := PackedStringArray()
	var entry_name := directory.get_next()
	while not entry_name.is_empty():
		if not entry_name.begins_with("."):
			entry_names.append(entry_name)
		entry_name = directory.get_next()
	directory.list_dir_end()
	entry_names.sort()
	for sorted_entry_name in entry_names:
		var entry_path := directory_path.path_join(sorted_entry_name)
		if DirAccess.dir_exists_absolute(ProjectSettings.globalize_path(entry_path)):
			_collect_campaign_paths(entry_path, result)
		elif sorted_entry_name == "campaign.tres":
			result.append(entry_path)


func _build_dependency_entries(
	enemy_roots: Array[Dictionary],
	pickup_roots: Array[Dictionary],
	campaign_roots: Array[Dictionary]
) -> Array[Dictionary]:
	var all_root_paths := PackedStringArray()
	for roots in [enemy_roots, pickup_roots, campaign_roots]:
		for entry in roots:
			all_root_paths.append(str(entry.get("path", "")))
	for gameplay_root in EXPLICIT_GAMEPLAY_DEPENDENCY_ROOTS:
		if (
			not _is_safe_resource_path(gameplay_root)
			or not FileAccess.file_exists(gameplay_root)
		):
			failures.append("显式玩法依赖根不存在或路径非法：%s。" % gameplay_root)
			continue
		all_root_paths.append(gameplay_root)
	_append_global_research_config_roots(all_root_paths)
	_append_plant_defense_config_roots(all_root_paths)
	_append_production_recipe_roots(all_root_paths)
	var visited := _collect_dependency_closure(all_root_paths, false)

	# ResourceLoader 能发现资源文件的 ext_resource，但不会展开 GDScript
	# preload，也不会把 @export_file String 视为依赖。科研注册表的配置资源
	# 已在上方显式展开；Campaign 则只在其可达闭包内识别已加载的
	# BossConfig 强类型对象，显式追踪其三个公开资源字段。
	var campaign_root_paths := PackedStringArray()
	for entry in campaign_roots:
		campaign_root_paths.append(str(entry.get("path", "")))
	var campaign_visited := _collect_dependency_closure(campaign_root_paths, true)
	for campaign_dependency_path in campaign_visited:
		visited[campaign_dependency_path] = true

	# 导入参数会改变贴图、音频等运行时资源，即使源文件字节完全相同也必须隔离。
	# .godot/imported 是机器缓存，不能进入跨构建摘要；只纳入已提交的 .import 侧车。
	var dependency_paths := PackedStringArray(visited.keys())
	for dependency_path in dependency_paths:
		var import_settings_path := dependency_path + ".import"
		if FileAccess.file_exists(import_settings_path):
			visited[import_settings_path] = true

	dependency_paths = PackedStringArray(visited.keys())
	dependency_paths.sort()
	var result: Array[Dictionary] = []
	for dependency_path in dependency_paths:
		var sha256 := _get_canonical_file_sha256(dependency_path)
		if sha256.length() != 64:
			failures.append("无法计算内容依赖摘要：%s。" % dependency_path)
			continue
		result.append({"path": dependency_path, "sha256": sha256})
	return result


func _append_global_research_config_roots(
	root_paths: PackedStringArray
) -> void:
	if not GlobalResearchRegistry.is_registry_valid():
		failures.append("全局科研注册表无效，无法生成完整内容摘要。")
		return
	for config in GlobalResearchRegistry.get_all_configs():
		var config_path := config.resource_path
		if (
			not _is_safe_resource_path(config_path)
			or not FileAccess.file_exists(config_path)
		):
			failures.append("全局科研配置不存在或路径非法：%s。" % config_path)
			continue
		root_paths.append(config_path)


func _append_plant_defense_config_roots(
	root_paths: PackedStringArray
) -> void:
	var configs := PlantDefenseRegistryScript.get_all_configs()
	if configs.size() != EXPECTED_PLANT_DEFENSE_CONFIG_COUNT:
		failures.append(
			"正式建筑配置数量必须为 %d，实际为 %d。"
			% [EXPECTED_PLANT_DEFENSE_CONFIG_COUNT, configs.size()]
		)
	var seen_paths: Dictionary[String, bool] = {}
	for config in configs:
		if config == null or not config.is_valid():
			failures.append("正式建筑配置无效，无法生成完整内容摘要。")
			continue
		var config_path := config.resource_path
		if (
			not _is_safe_resource_path(config_path)
			or not FileAccess.file_exists(config_path)
			or seen_paths.has(config_path)
		):
			failures.append("正式建筑配置路径不存在、非法或重复：%s。" % config_path)
			continue
		seen_paths[config_path] = true
		root_paths.append(config_path)


func _append_production_recipe_roots(
	root_paths: PackedStringArray
) -> void:
	if not ProductionRecipeRegistryScript.validate_contract():
		failures.append("正式生产配方注册表无效，无法生成完整内容摘要。")
		return
	var recipes := ProductionRecipeRegistryScript.get_all_recipes()
	if recipes.size() != EXPECTED_PRODUCTION_RECIPE_COUNT:
		failures.append(
			"正式生产配方数量必须为 %d，实际为 %d。"
			% [EXPECTED_PRODUCTION_RECIPE_COUNT, recipes.size()]
		)
	var seen_paths: Dictionary[String, bool] = {}
	for recipe in recipes:
		if recipe == null or not recipe.is_valid():
			failures.append("正式生产配方无效，无法生成完整内容摘要。")
			continue
		var recipe_path := recipe.resource_path
		if (
			not _is_safe_resource_path(recipe_path)
			or not FileAccess.file_exists(recipe_path)
			or seen_paths.has(recipe_path)
		):
			failures.append("正式生产配方路径不存在、非法或重复：%s。" % recipe_path)
			continue
		seen_paths[recipe_path] = true
		root_paths.append(recipe_path)


func _collect_dependency_closure(
	root_paths: PackedStringArray,
	include_campaign_boss_paths: bool
) -> Dictionary[String, bool]:
	var pending := root_paths.duplicate()
	var visited: Dictionary[String, bool] = {}
	while not pending.is_empty():
		pending.sort()
		var current_path := pending[0]
		pending.remove_at(0)
		if visited.has(current_path):
			continue
		if not _is_safe_resource_path(current_path) or not FileAccess.file_exists(current_path):
			failures.append("内容依赖不存在或路径非法：%s。" % current_path)
			continue
		visited[current_path] = true
		if include_campaign_boss_paths:
			_append_explicit_campaign_boss_dependencies(current_path, pending)
		for raw_dependency in ResourceLoader.get_dependencies(current_path):
			var dependency_path := _extract_dependency_path(String(raw_dependency))
			if dependency_path.is_empty() or visited.has(dependency_path):
				continue
			pending.append(dependency_path)
	return visited


func _append_explicit_campaign_boss_dependencies(
	resource_path: String,
	pending: PackedStringArray
) -> void:
	if resource_path.get_extension().to_lower() not in ["tres", "res"]:
		return
	var loaded_resource := ResourceLoader.load(resource_path)
	if loaded_resource == null:
		failures.append("Campaign 闭包中的资源无法加载：%s。" % resource_path)
		return
	var boss_config := loaded_resource as BossConfig
	if boss_config == null:
		return
	var explicit_paths := [
		{
			"field": "enemy_config_path",
			"path": boss_config.enemy_config_path,
		},
		{
			"field": "intro_vfx_scene_path",
			"path": boss_config.intro_vfx_scene_path,
		},
		{
			"field": "boss_hud_scene_path",
			"path": boss_config.boss_hud_scene_path,
		},
	]
	for entry in explicit_paths:
		var explicit_path := str(entry.get("path", ""))
		if explicit_path.is_empty():
			continue
		if not _is_safe_resource_path(explicit_path):
			failures.append(
				"BossConfig %s.%s 不是合法 res:// 路径：%s。"
				% [resource_path, str(entry.get("field", "")), explicit_path]
			)
			continue
		if not FileAccess.file_exists(explicit_path):
			failures.append(
				"BossConfig %s.%s 指向不存在的资源：%s。"
				% [resource_path, str(entry.get("field", "")), explicit_path]
			)
			continue
		pending.append(explicit_path)


func _extract_dependency_path(raw_dependency: String) -> String:
	var sections := raw_dependency.split("::", false)
	if sections.is_empty():
		return ""
	var dependency_path := sections[sections.size() - 1]
	if not _is_safe_resource_path(dependency_path):
		failures.append("ResourceLoader 返回了非法内容依赖：%s。" % raw_dependency)
		return ""
	return dependency_path


func _get_canonical_file_sha256(resource_path: String) -> String:
	var extension := resource_path.get_extension().to_lower()
	if TEXT_EXTENSIONS.has(extension):
		var text := FileAccess.get_file_as_string(resource_path)
		text = text.replace("\r\n", "\n").replace("\r", "\n")
		return text.sha256_text()
	return FileAccess.get_sha256(resource_path)


func _append_root_lines(
	lines: PackedStringArray,
	kind: String,
	entries: Array[Dictionary]
) -> void:
	for entry in entries:
		lines.append(
			"root|%s|%s|%s"
			% [kind, str(entry.get("id", "")), str(entry.get("path", ""))]
		)


func _build_constants_source(
	content_sha256: String,
	enemy_count: int,
	pickup_count: int,
	campaign_count: int,
	dependency_count: int
) -> String:
	return """extends RefCounted
class_name RuntimeContentManifest

## 此文件由 dev_tools/generate_runtime_content_manifest.gd 生成，禁止手改。
## 运行时只信任这组编译期常量；JSON 清单用于代码审查与 --check 重现。
const SCHEMA_VERSION := %d
const CONTENT_SHA256 := \"%s\"
const ENEMY_ROOT_COUNT := %d
const PICKUP_ROOT_COUNT := %d
const CAMPAIGN_ROOT_COUNT := %d
const DEPENDENCY_COUNT := %d


static func is_valid() -> bool:
\treturn (
\t\tSCHEMA_VERSION == 1
\t\tand ENEMY_ROOT_COUNT == 64
\t\tand PICKUP_ROOT_COUNT == 181
\t\tand CAMPAIGN_ROOT_COUNT == 26
\t\tand DEPENDENCY_COUNT > 0
\t\tand is_valid_wire_digest(CONTENT_SHA256)
\t)


static func is_valid_wire_digest(value: String) -> bool:
\tif value.length() != 64 or value != value.to_lower():
\t\treturn false
\tfor index in range(value.length()):
\t\tvar code := value.unicode_at(index)
\t\tif not (code >= 48 and code <= 57) and not (code >= 97 and code <= 102):
\t\t\treturn false
\treturn true
""" % [
		SCHEMA_VERSION,
		content_sha256,
		enemy_count,
		pickup_count,
		campaign_count,
		dependency_count,
	]


func _check_output(path: String, expected_text: String) -> void:
	if not FileAccess.file_exists(path):
		failures.append("缺少已生成内容清单：%s。" % path)
		return
	var actual_text := FileAccess.get_file_as_string(path)
	actual_text = actual_text.replace("\r\n", "\n").replace("\r", "\n")
	if actual_text != expected_text:
		failures.append("已提交内容清单过期，请重新执行 --write：%s。" % path)


func _write_output(path: String, content: String) -> void:
	var directory_path := path.get_base_dir()
	var directory_error := DirAccess.make_dir_recursive_absolute(
		ProjectSettings.globalize_path(directory_path)
	)
	if directory_error != OK:
		failures.append("无法创建内容清单目录 %s：%s。" % [directory_path, error_string(directory_error)])
		return
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		failures.append("无法写入内容清单：%s。" % path)
		return
	file.store_string(content)
	file.close()


func _is_safe_manifest_field(value: String) -> bool:
	if value.is_empty() or value.length() > 256:
		return false
	for index in range(value.length()):
		var code := value.unicode_at(index)
		if code < 33 or code > 126 or code == 124:
			return false
	return true


func _is_safe_resource_path(value: String) -> bool:
	if (
		not value.begins_with("res://")
		or value.length() > 512
		or value.contains("..")
		or value.contains("\\")
	):
		return false
	# 作者资源历史上允许中文与空格；这里只拒绝会破坏规范行或形成隐藏路径的字符。
	for index in range(value.length()):
		var code := value.unicode_at(index)
		if code < 32 or code == 124 or code == 127:
			return false
	return true
