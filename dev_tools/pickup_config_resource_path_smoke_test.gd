extends SceneTree

const CONFIG_ROOT := "res://resources/config"
const CURRENT_PICKUP_CONFIG_PATH := "res://resources/config/pickup_config.gd"
const LEGACY_PICKUP_CONFIG_PATH := (
	"res://resources/config/pickups/pickup_config.gd"
)
const TOWER_PROGRESSION_PATH := (
	"res://resources/config/campaigns/tower_defense/formal_progression.tres"
)

var failures: Array[String] = []


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	_expect(
		ResourceLoader.exists(CURRENT_PICKUP_CONFIG_PATH),
		"PickupConfig公共脚本必须位于迁移后的配置根目录。"
	)
	_expect(
		not ResourceLoader.exists(LEGACY_PICKUP_CONFIG_PATH),
		"已取消的pickups目录不得保留PickupConfig兼容壳。"
	)
	_scan_directory_for_legacy_path(CONFIG_ROOT)

	var recipes := SimpleCraftingRegistry.get_all_recipes()
	_expect(
		recipes.size() == SimpleCraftingRegistry.RECIPES.size(),
		"全部简易制作配方都必须保留可加载的投入与产出引用。"
	)
	for recipe in recipes:
		_expect(
			recipe != null and recipe.is_valid(),
			"简易制作配方加载后必须保持有效：%s" % (
				recipe.resource_path if recipe != null else "<null>"
			)
		)

	var research_configs := GlobalResearchRegistry.get_all_configs()
	_expect(
		research_configs.size() == GlobalResearchRegistry.RESEARCH_ORDER.size(),
		"全部全局科研配置都必须保留可加载的材料引用。"
	)
	for config in research_configs:
		_expect(
			config != null and config.is_valid(),
			"全局科研配置加载后必须保持有效：%s" % (
				config.resource_path if config != null else "<null>"
			)
		)

	var progression := load(TOWER_PROGRESSION_PATH) as TowerDefenseProgressionConfig
	_expect(
		progression != null and progression.is_valid(),
		"塔防正式进度配置必须保留起步物资与追踪材料引用。"
	)

	if failures.is_empty():
		print("PICKUP_CONFIG_RESOURCE_PATH_SMOKE_TEST_OK")
		quit()
		return
	for failure in failures:
		push_error(failure)
	quit(1)


func _scan_directory_for_legacy_path(directory_path: String) -> void:
	var directory := DirAccess.open(directory_path)
	if directory == null:
		failures.append("无法扫描配置目录：%s" % directory_path)
		return
	for file_name in directory.get_files():
		if not file_name.ends_with(".tres"):
			continue
		var resource_path := directory_path.path_join(file_name)
		var source := FileAccess.get_file_as_string(resource_path)
		_expect(
			not source.contains(LEGACY_PICKUP_CONFIG_PATH),
			"资源仍引用已取消的PickupConfig路径：%s" % resource_path
		)
	for child_name in directory.get_directories():
		_scan_directory_for_legacy_path(directory_path.path_join(child_name))


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
