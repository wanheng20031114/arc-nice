extends SceneTree

const RuntimeContentManifestScript := preload(
	"res://resources/config/generated/runtime_content_manifest.gd"
)
const PlantDefenseRegistryScript := preload(
	"res://resources/config/plant_defense/plant_defense_registry.gd"
)
const ProductionRecipeRegistryScript := preload(
	"res://resources/config/production/production_recipe_registry.gd"
)
const MANIFEST_PATH := (
	"res://resources/config/generated/runtime_content_manifest.schema1.json"
)
const GENERATOR_PATH := "res://dev_tools/generate_runtime_content_manifest.gd"
const INVALID_BOSS_PATH_FIXTURE_ARGUMENT := "--check-invalid-boss-path-fixture"
const INVALID_BOSS_PATH_FIXTURE := "res://__manifest_fixture_missing__/missing.tscn"
const LINGLAN_BOSS_CONFIG_PATH := "res://resources/config/bosses/boss_01_linglan.tres"
const LINGLAN_BOSS_DYNAMIC_SCENE_PATHS := [
	"res://scene/boss/linglan/boss_health_hud.tscn",
	"res://scene/boss/linglan/linglan_boss_intro_vfx.tscn",
]
const WOOD_PROCESSING_STATION_PATH := (
	"res://scene/plant_defense/wood_processing_station.tscn"
)
const TOWER_DEFENSE_GAME_SCENE_PATH := (
	"res://scene/game_modes/tower_defense/tower_defense_game.tscn"
)
const PLANT_SYSTEM_SCRIPT_PATH := (
	"res://scene/game_modes/tower_defense/plant/runtime/plant_system.gd"
)
const PRODUCTION_BUILDING_PANEL_SCRIPT_PATH := (
	"res://scene/game_modes/tower_defense/economy/production/production_building_panel.gd"
)
const PLANT_DEFENSE_REGISTRY_PATH := (
	"res://resources/config/plant_defense/plant_defense_registry.gd"
)
const PRODUCTION_RECIPE_REGISTRY_PATH := (
	"res://resources/config/production/production_recipe_registry.gd"
)
const EXCAVATOR_CYCLE_PATH := (
	"res://resources/config/production/excavator_cycle.tres"
)
const GLOBAL_RESEARCH_REGISTRY_PATH := (
	"res://resources/config/research/global_research_registry.gd"
)
const COLLECTIBLE_REGISTRY_PATH := (
	"res://resources/config/collectibles/collectible_registry.gd"
)
const ROGUE_ENCOUNTER_REGISTRY_PATH := (
	"res://scene/game_modes/rogue/encounter/rogue_encounter_registry.gd"
)
const DEEP_SEA_RUINS_BACKGROUND_PATH := (
	"res://resources/texture/rogue_encounter/deep_sea_ruins.png"
)
const RESEARCH_EFFECT_SCRIPT_PATHS := [
	"res://resources/config/research/global_research_effect.gd",
	"res://resources/config/research/global_research_additive_modifier_effect.gd",
	"res://resources/config/research/global_research_multiplier_modifier_effect.gd",
	"res://resources/config/research/global_research_recipe_unlock_effect.gd",
	"res://resources/config/research/global_research_tower_on_hit_slow_effect.gd",
	"res://resources/config/research/global_research_tower_on_hit_timed_status_effect.gd",
	"res://resources/config/research/global_research_tower_conditional_damage_bonus_effect.gd",
]
const ENHANCEMENT_TOWER_RECIPE_PATHS := [
	"res://resources/config/production/life_tower_assembly.tres",
	"res://resources/config/production/speed_tower_assembly.tres",
	"res://resources/config/production/attack_speed_tower_assembly.tres",
]
const EXPECTED_PLANT_DEFENSE_CONFIG_COUNT := 19
const EXPECTED_PRODUCTION_RECIPE_COUNT := 32
const GOLDEN_CONTENT_SHA256 := (
	"e27f2aefb0258bf565f51d0ff83f977686a208d78680e6097d678f58ebaaf7f2"
)

var failures: Array[String] = []


func _init() -> void:
	call_deferred(&"_run")


func _run() -> void:
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(MANIFEST_PATH))
	_expect(typeof(parsed) == TYPE_DICTIONARY, "schema 1 内容清单必须是合法 JSON 对象。")
	if typeof(parsed) == TYPE_DICTIONARY:
		_validate_manifest(parsed as Dictionary)
	_expect(
		RuntimeContentManifestScript.is_valid(),
		"运行时内容清单常量必须通过严格结构校验。"
	)
	_expect(
		RuntimeContentManifestScript.CONTENT_SHA256 == GOLDEN_CONTENT_SHA256,
		"内容摘要偏离人工冻结 golden；内容变更必须显式审核并更新基线。"
	)
	_expect(
		RuntimeContentManifestScript.is_valid_wire_digest(GOLDEN_CONTENT_SHA256)
		and not RuntimeContentManifestScript.is_valid_wire_digest(
			GOLDEN_CONTENT_SHA256.to_upper()
		)
		and not RuntimeContentManifestScript.is_valid_wire_digest(
			GOLDEN_CONTENT_SHA256.substr(0, 63)
		),
		"wire 摘要只允许 64 位小写十六进制。"
	)
	_test_invalid_boss_path_check_fails()
	_finish()


func _validate_manifest(manifest: Dictionary) -> void:
	var enemy_roots := manifest.get("enemy_roots", []) as Array
	var pickup_roots := manifest.get("pickup_roots", []) as Array
	var campaign_roots := manifest.get("campaign_roots", []) as Array
	var dependencies := manifest.get("dependencies", []) as Array
	_expect(int(manifest.get("schema_version", -1)) == 1, "内容清单 schema 必须固定为 1。")
	_expect(enemy_roots.size() == 64, "内容清单必须包含 64 个敌人根。")
	_expect(pickup_roots.size() == 181, "内容清单必须包含 181 个道具根。")
	_expect(campaign_roots.size() == 26, "内容清单必须包含 26 个 Campaign 根。")
	_expect(
		dependencies.size() == RuntimeContentManifestScript.DEPENDENCY_COUNT
		and dependencies.size() > enemy_roots.size() + pickup_roots.size() + campaign_roots.size(),
		"内容清单必须保存完整依赖闭包，而不只是根路径。"
	)
	var canonical_lines := PackedStringArray(["schema|1"])
	_append_root_lines(canonical_lines, "enemy", enemy_roots)
	_append_root_lines(canonical_lines, "pickup", pickup_roots)
	_append_root_lines(canonical_lines, "campaign", campaign_roots)
	var previous_dependency_path := ""
	var dependency_paths: Dictionary[String, bool] = {}
	var dependency_hashes: Dictionary[String, String] = {}
	for dependency_variant in dependencies:
		var dependency := dependency_variant as Dictionary
		var dependency_path := str(dependency.get("path", ""))
		var dependency_sha256 := str(dependency.get("sha256", ""))
		_expect(
			previous_dependency_path.is_empty() or previous_dependency_path < dependency_path,
			"依赖闭包必须按路径严格排序且不得重复：%s。" % dependency_path
		)
		_expect(
			RuntimeContentManifestScript.is_valid_wire_digest(dependency_sha256),
			"依赖条目必须携带 64 位小写摘要：%s。" % dependency_path
		)
		previous_dependency_path = dependency_path
		dependency_paths[dependency_path] = true
		dependency_hashes[dependency_path] = dependency_sha256
		canonical_lines.append(
			"dependency|%s|%s" % [dependency_path, dependency_sha256]
		)
	for roots in [enemy_roots, pickup_roots, campaign_roots]:
		for root_variant in roots:
			var root_entry := root_variant as Dictionary
			_expect(
				dependency_paths.has(str(root_entry.get("path", ""))),
				"每个内容根本身都必须进入依赖闭包。"
			)
	var recomputed_sha256 := "\n".join(canonical_lines).sha256_text()
	_expect(
		recomputed_sha256 == str(manifest.get("content_sha256", ""))
		and recomputed_sha256 == RuntimeContentManifestScript.CONTENT_SHA256,
		"JSON 清单、规范行与运行时常量必须收敛到同一摘要。"
	)
	_validate_explicit_boss_dependency_closure(dependency_hashes)
	_validate_boss_digest_mutation_sensitivity(canonical_lines, dependency_hashes)
	_validate_tower_defense_dependency_closure(
		canonical_lines,
		dependency_hashes
	)
	_validate_plant_defense_config_dependency_closure(dependency_hashes)
	_validate_production_recipe_dependency_closure(
		canonical_lines,
		dependency_hashes
	)
	_validate_research_dependency_closure(canonical_lines, dependency_hashes)
	_validate_rogue_encounter_dependency_closure(
		canonical_lines,
		dependency_hashes
	)


func _validate_tower_defense_dependency_closure(
	canonical_lines: PackedStringArray,
	dependency_hashes: Dictionary[String, String]
) -> void:
	for dependency_path in [
		TOWER_DEFENSE_GAME_SCENE_PATH,
		PLANT_SYSTEM_SCRIPT_PATH,
		PRODUCTION_BUILDING_PANEL_SCRIPT_PATH,
	]:
		_expect(
			FileAccess.file_exists(dependency_path)
			and dependency_hashes.has(dependency_path),
			"塔防主场景及其运行时代码必须进入内容摘要：%s。"
			% dependency_path
		)
	if not dependency_hashes.has(PLANT_SYSTEM_SCRIPT_PATH):
		return
	var mutated_plant_system_source := (
		_get_canonical_text(PLANT_SYSTEM_SCRIPT_PATH)
		+ "\n# plant system manifest mutation fixture"
	)
	_expect_dependency_mutation_changes_digest(
		canonical_lines,
		PLANT_SYSTEM_SCRIPT_PATH,
		mutated_plant_system_source.sha256_text(),
		PLANT_SYSTEM_SCRIPT_PATH
	)


func _validate_plant_defense_config_dependency_closure(
	dependency_hashes: Dictionary[String, String]
) -> void:
	_expect(
		FileAccess.file_exists(PLANT_DEFENSE_REGISTRY_PATH)
		and dependency_hashes.has(PLANT_DEFENSE_REGISTRY_PATH),
		"建筑配置注册表必须作为多人玩法内容摘要根。"
	)
	var configs := PlantDefenseRegistryScript.get_all_configs()
	_expect(
		configs.size() == EXPECTED_PLANT_DEFENSE_CONFIG_COUNT,
		"内容摘要验证必须覆盖完整%d项建筑配置。"
		% EXPECTED_PLANT_DEFENSE_CONFIG_COUNT
	)
	for config in configs:
		var config_path := config.resource_path if config != null else ""
		_expect(
			config != null
			and config.is_valid()
			and FileAccess.file_exists(config_path)
			and dependency_hashes.has(config_path),
			"每项正式建筑配置都必须存在并进入内容摘要：%s。" % config_path
		)


func _validate_production_recipe_dependency_closure(
	canonical_lines: PackedStringArray,
	dependency_hashes: Dictionary[String, String]
) -> void:
	_expect(
		FileAccess.file_exists(PRODUCTION_RECIPE_REGISTRY_PATH)
		and dependency_hashes.has(PRODUCTION_RECIPE_REGISTRY_PATH),
		"正式生产配方注册表必须作为多人玩法内容摘要根。"
	)
	_expect(
		dependency_hashes.has(WOOD_PROCESSING_STATION_PATH),
		"木头加工站必须作为多人生产内容摘要的显式玩法依赖根。"
	)
	var recipes := ProductionRecipeRegistryScript.get_all_recipes()
	_expect(
		ProductionRecipeRegistryScript.validate_contract()
		and recipes.size() == EXPECTED_PRODUCTION_RECIPE_COUNT,
		"内容摘要验证必须覆盖完整%d条正式生产配方。"
		% EXPECTED_PRODUCTION_RECIPE_COUNT
	)
	for recipe in recipes:
		var recipe_path := recipe.resource_path if recipe != null else ""
		_expect(
			recipe != null
			and recipe.is_valid()
			and FileAccess.file_exists(recipe_path)
			and dependency_hashes.has(recipe_path),
			"每条正式生产配方都必须存在并进入内容摘要：%s。" % recipe_path
		)
	for recipe_path_variant in ENHANCEMENT_TOWER_RECIPE_PATHS:
		var recipe_path := str(recipe_path_variant)
		_expect(
			dependency_hashes.has(recipe_path),
			"强化塔配方必须进入多人生产内容摘要：%s。" % recipe_path
		)
		if not dependency_hashes.has(recipe_path):
			continue
		var mutated_recipe_source := (
			_get_canonical_text(recipe_path)
			+ "\n# production recipe manifest mutation fixture"
		)
		_expect_dependency_mutation_changes_digest(
			canonical_lines,
			recipe_path,
			mutated_recipe_source.sha256_text(),
			recipe_path
		)
	_expect(
		dependency_hashes.has(EXCAVATOR_CYCLE_PATH),
		"挖土装置权威循环配方必须进入多人内容摘要。"
	)
	if dependency_hashes.has(EXCAVATOR_CYCLE_PATH):
		var mutated_excavator_cycle_source := (
			_get_canonical_text(EXCAVATOR_CYCLE_PATH)
			+ "\n# excavator cycle manifest mutation fixture"
		)
		_expect_dependency_mutation_changes_digest(
			canonical_lines,
			EXCAVATOR_CYCLE_PATH,
			mutated_excavator_cycle_source.sha256_text(),
			EXCAVATOR_CYCLE_PATH
		)


func _validate_research_dependency_closure(
	canonical_lines: PackedStringArray,
	dependency_hashes: Dictionary[String, String]
) -> void:
	_expect(
		dependency_hashes.has(GLOBAL_RESEARCH_REGISTRY_PATH),
		"全局科研注册表必须作为多人科研内容摘要的显式玩法依赖根。"
	)
	var configs := GlobalResearchRegistry.get_all_configs()
	_expect(
		GlobalResearchRegistry.is_registry_valid() and configs.size() == 15,
		"内容摘要验证必须覆盖完整15项类型化科研注册表。"
	)
	for config in configs:
		var research_path := config.resource_path
		_expect(
			dependency_hashes.has(research_path),
			"每项科研资源都必须进入多人内容摘要：%s。" % research_path
		)
		if not dependency_hashes.has(research_path):
			continue
		var mutated_source := (
			_get_canonical_text(research_path)
			+ "\n# research manifest mutation fixture"
		)
		_expect_dependency_mutation_changes_digest(
			canonical_lines,
			research_path,
			mutated_source.sha256_text(),
			research_path
		)
	for effect_script_path_variant in RESEARCH_EFFECT_SCRIPT_PATHS:
		var effect_script_path := str(effect_script_path_variant)
		_expect(
			dependency_hashes.has(effect_script_path),
			"类型化科研效果脚本必须进入多人内容摘要：%s。"
			% effect_script_path
		)


func _validate_rogue_encounter_dependency_closure(
	canonical_lines: PackedStringArray,
	dependency_hashes: Dictionary[String, String]
) -> void:
	for dependency_path in [
		COLLECTIBLE_REGISTRY_PATH,
		ROGUE_ENCOUNTER_REGISTRY_PATH,
		DEEP_SEA_RUINS_BACKGROUND_PATH,
	]:
		_expect(
			FileAccess.file_exists(dependency_path)
			and dependency_hashes.has(dependency_path),
			"神奇遭遇的稳定池、内容 ID 与动态背景必须进入内容摘要：%s。"
			% dependency_path
		)
		if not dependency_hashes.has(dependency_path):
			continue
		var original_sha256 := str(dependency_hashes[dependency_path])
		var mutated_sha256 := (
			("0" if original_sha256.substr(0, 1) != "0" else "1")
			+ original_sha256.substr(1)
		)
		_expect_dependency_mutation_changes_digest(
			canonical_lines,
			dependency_path,
			mutated_sha256,
			dependency_path
		)


func _validate_explicit_boss_dependency_closure(
	dependency_hashes: Dictionary[String, String]
) -> void:
	_expect(
		dependency_hashes.has(LINGLAN_BOSS_CONFIG_PATH),
		"Campaign 闭包必须包含触发强类型路径扩展的 BossConfig。"
	)
	for scene_path_variant in LINGLAN_BOSS_DYNAMIC_SCENE_PATHS:
		var scene_path := str(scene_path_variant)
		_expect(
			dependency_hashes.has(scene_path),
			"BossConfig 显式 String 场景路径必须进入清单：%s。" % scene_path
		)
		_assert_native_dependency_closure(
			scene_path,
			dependency_hashes,
			{}
		)


func _assert_native_dependency_closure(
	resource_path: String,
	dependency_hashes: Dictionary[String, String],
	visited: Dictionary[String, bool]
) -> void:
	if visited.has(resource_path):
		return
	visited[resource_path] = true
	_expect(
		dependency_hashes.has(resource_path),
		"Boss 显式场景的传递依赖缺失：%s。" % resource_path
	)
	if not FileAccess.file_exists(resource_path):
		return
	for raw_dependency in ResourceLoader.get_dependencies(resource_path):
		var sections := String(raw_dependency).split("::", false)
		if sections.is_empty():
			continue
		var dependency_path := sections[sections.size() - 1]
		if not dependency_path.begins_with("res://"):
			continue
		_assert_native_dependency_closure(
			dependency_path,
			dependency_hashes,
			visited
		)


func _validate_boss_digest_mutation_sensitivity(
	canonical_lines: PackedStringArray,
	dependency_hashes: Dictionary[String, String]
) -> void:
	var boss_source := _get_canonical_text(LINGLAN_BOSS_CONFIG_PATH)
	for field_name in [
		"enemy_config_path",
		"intro_vfx_scene_path",
		"boss_hud_scene_path",
	]:
		var marker := "%s = \"" % field_name
		var value_start := boss_source.find(marker)
		var value_end := -1
		if value_start >= 0:
			value_start += marker.length()
			value_end = boss_source.find("\"", value_start)
		_expect(
			value_start >= marker.length() and value_end > value_start,
			"BossConfig fixture 缺少显式路径字段：%s。" % field_name
		)
		if value_start < marker.length() or value_end <= value_start:
			continue
		var mutated_source := (
			boss_source.substr(0, value_end)
			+ ".manifest_mutation"
			+ boss_source.substr(value_end)
		)
		_expect_dependency_mutation_changes_digest(
			canonical_lines,
			LINGLAN_BOSS_CONFIG_PATH,
			mutated_source.sha256_text(),
			"BossConfig.%s" % field_name
		)
	for scene_path_variant in LINGLAN_BOSS_DYNAMIC_SCENE_PATHS:
		var scene_path := str(scene_path_variant)
		_expect(
			dependency_hashes.has(scene_path),
			"Boss 场景变异测试缺少清单条目：%s。" % scene_path
		)
		var mutated_scene_source := (
			_get_canonical_text(scene_path)
			+ "\n# runtime content manifest mutation fixture"
		)
		_expect_dependency_mutation_changes_digest(
			canonical_lines,
			scene_path,
			mutated_scene_source.sha256_text(),
			scene_path
		)


func _expect_dependency_mutation_changes_digest(
	canonical_lines: PackedStringArray,
	dependency_path: String,
	mutated_sha256: String,
	mutation_label: String
) -> void:
	var mutated_lines := canonical_lines.duplicate()
	var line_prefix := "dependency|%s|" % dependency_path
	var replaced := false
	for line_index in range(mutated_lines.size()):
		if mutated_lines[line_index].begins_with(line_prefix):
			mutated_lines[line_index] = line_prefix + mutated_sha256
			replaced = true
			break
	_expect(replaced, "变异目标未进入规范行：%s。" % mutation_label)
	if not replaced:
		return
	_expect(
		"\n".join(mutated_lines).sha256_text()
		!= RuntimeContentManifestScript.CONTENT_SHA256,
		"任一显式玩法依赖字段或文件变化都必须改变最终摘要：%s。" % mutation_label
	)


func _get_canonical_text(resource_path: String) -> String:
	return FileAccess.get_file_as_string(resource_path).replace("\r\n", "\n").replace(
		"\r",
		"\n"
	)


func _test_invalid_boss_path_check_fails() -> void:
	var output: Array = []
	var exit_code := OS.execute(
		OS.get_executable_path(),
		PackedStringArray([
			"--headless",
			"--editor",
			"--path",
			ProjectSettings.globalize_path("res://"),
			"--script",
			GENERATOR_PATH,
			"--",
			"--check",
			INVALID_BOSS_PATH_FIXTURE_ARGUMENT,
		]),
		output,
		true,
		false
	)
	var combined_output := "\n".join(PackedStringArray(output))
	_expect(
		exit_code == 1
		and combined_output.contains("CHECK_INVALID_BOSS_PATH_FIXTURE_REJECTED"),
		(
			"BossConfig 非空坏路径必须让真实生成器 --check 以 exit 1 失败："
			+ "exit=%d output=%s" % [exit_code, combined_output]
		)
	)


func _append_root_lines(
	lines: PackedStringArray,
	kind: String,
	entries: Array
) -> void:
	var previous_id := ""
	for entry_variant in entries:
		var entry := entry_variant as Dictionary
		var content_id := str(entry.get("id", ""))
		var resource_path := str(entry.get("path", ""))
		_expect(
			previous_id.is_empty() or previous_id < content_id,
			"%s 根必须按稳定 ID 严格排序且不得重复：%s。" % [kind, content_id]
		)
		previous_id = content_id
		lines.append("root|%s|%s|%s" % [kind, content_id, resource_path])


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)


func _finish() -> void:
	if failures.is_empty():
		print("RUNTIME_CONTENT_MANIFEST_SMOKE_TEST_OK")
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	quit(1)
