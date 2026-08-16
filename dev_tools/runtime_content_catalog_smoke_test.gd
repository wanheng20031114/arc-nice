extends SceneTree

const Catalog := preload("res://resources/config/runtime_content_catalog.gd")
const UNKNOWN_ENEMY_PATH := (
	"res://dev_tools/fixtures/runtime_content_catalog_outside_enemy.tres"
)
const UNKNOWN_PICKUP_PATH := (
	"res://dev_tools/fixtures/runtime_content_catalog_outside_pickup.tres"
)

var failures: Array[String] = []


func _init() -> void:
	call_deferred(&"_run")


func _run() -> void:
	_validate_catalog_entries()
	_validate_authored_content_graph()
	if failures.is_empty():
		print("RUNTIME_CONTENT_CATALOG_SMOKE_TEST_OK")
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	quit(1)


func _validate_catalog_entries() -> void:
	var enemy_entries := Catalog.get_enemy_entries()
	var pickup_entries := Catalog.get_pickup_entries()
	_expect(
		Catalog.get_enemy_count() == 64 and enemy_entries.size() == 64,
		"运行时敌人目录必须显式固定为 64 项。"
	)
	_expect(
		Catalog.get_pickup_count() == 181 and pickup_entries.size() == 181,
		"运行时道具目录必须显式固定为 181 项。"
	)
	for raw_id in enemy_entries:
		var enemy_id := str(raw_id)
		var path := str(enemy_entries[raw_id])
		var config := Catalog.load_enemy_config_from_path(path)
		_expect(
			enemy_id.begins_with("enemy.")
			and Catalog.get_enemy_path_for_id(enemy_id) == path
			and Catalog.get_enemy_id_for_path(path) == enemy_id
			and config != null
			and config.resource_path == path,
			"敌人目录必须保持稳定 ID、作者路径和反向索引闭环：%s" % enemy_id
		)
		var enemy_instance: Node = null
		if config != null and config.enemy_scene != null:
			enemy_instance = config.enemy_scene.instantiate()
		_expect(
			enemy_instance is Enemy,
			"目录内 EnemyConfig.enemy_scene 必须可实例化为 Enemy：%s" % enemy_id
		)
		if enemy_instance != null and is_instance_valid(enemy_instance):
			enemy_instance.free()
	for raw_id in pickup_entries:
		var pickup_id := str(raw_id)
		var path := str(pickup_entries[raw_id])
		var config := Catalog.load_pickup_config_from_path(path)
		_expect(
			pickup_id.begins_with("item.")
			and Catalog.get_pickup_path_for_id(pickup_id) == path
			and Catalog.get_pickup_id_for_path(path) == pickup_id
			and config != null
			and config.resource_path == path,
			"道具目录必须保持稳定 ID、作者路径和反向索引闭环：%s" % pickup_id
		)
	enemy_entries.clear()
	pickup_entries.clear()
	_expect(
		Catalog.get_enemy_count() == 64 and Catalog.get_pickup_count() == 181,
		"调用方只能获得目录副本，不得改写进程级信任根。"
	)
	var outside_enemy := ResourceLoader.load(UNKNOWN_ENEMY_PATH) as EnemyConfig
	var outside_enemy_instance: Node = null
	if outside_enemy != null and outside_enemy.enemy_scene != null:
		outside_enemy_instance = outside_enemy.enemy_scene.instantiate()
	_expect(
		outside_enemy_instance is Enemy
		and ResourceLoader.load(UNKNOWN_PICKUP_PATH) is PickupConfig
		and
		Catalog.get_enemy_id_for_path(UNKNOWN_ENEMY_PATH).is_empty()
		and Catalog.load_enemy_config_from_path(UNKNOWN_ENEMY_PATH) == null
		and Catalog.get_pickup_id_for_path(UNKNOWN_PICKUP_PATH).is_empty()
		and Catalog.load_pickup_config_from_path(UNKNOWN_PICKUP_PATH) == null,
		"语法合法但不属于对应目录的资源路径必须 fail-close。"
	)
	if outside_enemy_instance != null and is_instance_valid(outside_enemy_instance):
		outside_enemy_instance.free()
	_expect(
		Catalog.get_enemy_path_for_id("enemy.敌人").is_empty()
		and Catalog.get_pickup_path_for_id("item.materials material_wood").is_empty()
		and Catalog.get_enemy_id_for_path("res://resources/config/enemies/\nslime.tres").is_empty(),
		"非 ASCII ID、空白路径和非法字符必须在索引转换前拒绝。"
	)


func _validate_authored_content_graph() -> void:
	var config_paths: Array[String] = []
	var path_lookup: Dictionary[String, bool] = {}
	for root_path in [
		"res://resources/config/campaigns",
		"res://resources/config/enemies",
		"res://resources/config/bosses",
		"res://resources/config/rogue_combat",
		"res://resources/config/rogue_shop",
		"res://resources/config/rogue_route",
		"res://resources/config/production",
		"res://resources/config/research",
	]:
		var root_paths: Array[String] = []
		_collect_tres_paths(root_path, root_paths)
		for path in root_paths:
			path_lookup[path] = true
	config_paths.assign(path_lookup.keys())
	config_paths.sort()
	var visited: Dictionary[int, bool] = {}
	var campaign_path_count := 0
	var stats := {
		"campaigns": 0,
		"drop_tables": 0,
		"reward_configs": 0,
		"shop_configs": 0,
	}
	for path in config_paths:
		var resource := ResourceLoader.load(path) as Resource
		if resource == null:
			_failures_append_once("配置资源无法加载：%s" % path)
			continue
		if resource is WaveCampaignConfig:
			campaign_path_count += 1
		_inspect_authored_value(resource, path, visited, stats)
	_expect(
		campaign_path_count == 26,
		"内容闭包必须遍历全部 26 个 WaveCampaignConfig。"
	)
	_expect(
		int(stats["drop_tables"]) > 0
		and int(stats["reward_configs"]) > 0
		and int(stats["shop_configs"]) > 0,
		"内容闭包必须覆盖敌人掉落、Rogue 奖励与地下商店配置。"
	)


func _collect_tres_paths(directory_path: String, result: Array[String]) -> void:
	var directory := DirAccess.open(directory_path)
	if directory == null:
		_failures_append_once("无法遍历配置目录：%s" % directory_path)
		return
	directory.list_dir_begin()
	var entry_name := directory.get_next()
	while not entry_name.is_empty():
		if entry_name.begins_with("."):
			entry_name = directory.get_next()
			continue
		var entry_path := directory_path.path_join(entry_name)
		if directory.current_is_dir():
			_collect_tres_paths(entry_path, result)
		elif entry_name.ends_with(".tres"):
			result.append(entry_path)
		entry_name = directory.get_next()
	directory.list_dir_end()


func _inspect_authored_value(
	value: Variant,
	owner_path: String,
	visited: Dictionary[int, bool],
	stats: Dictionary
) -> void:
	if value is Array:
		for element in value as Array:
			_inspect_authored_value(element, owner_path, visited, stats)
		return
	if value is Dictionary:
		for element in (value as Dictionary).values():
			_inspect_authored_value(element, owner_path, visited, stats)
		return
	if typeof(value) != TYPE_OBJECT or not value is Resource:
		return
	var resource := value as Resource
	var instance_id := resource.get_instance_id()
	if visited.has(instance_id):
		return
	visited[instance_id] = true
	if resource is EnemyConfig:
		_expect(
			Catalog.is_registered_enemy_config(resource as EnemyConfig),
			"作者内容引用了目录外 EnemyConfig：%s（来自 %s）"
			% [resource.resource_path, owner_path]
		)
	if resource is PickupConfig:
		_expect(
			Catalog.is_registered_pickup_config(resource as PickupConfig),
			"作者内容引用了目录外 PickupConfig：%s（来自 %s）"
			% [resource.resource_path, owner_path]
		)
	if resource is WaveCampaignConfig:
		stats["campaigns"] = int(stats["campaigns"]) + 1
	if resource is EnemyDropTable:
		stats["drop_tables"] = int(stats["drop_tables"]) + 1
	if resource is RogueCombatRewardConfig:
		stats["reward_configs"] = int(stats["reward_configs"]) + 1
	if resource is RogueUndergroundShopConfig:
		stats["shop_configs"] = int(stats["shop_configs"]) + 1
	if (
		not resource.resource_path.is_empty()
		and not resource.resource_path.begins_with("res://resources/config/")
	):
		return
	for property in resource.get_property_list():
		if int(property.get("usage", 0)) & PROPERTY_USAGE_STORAGE == 0:
			continue
		var property_name := StringName(property.get("name", ""))
		if property_name == &"script":
			continue
		_inspect_authored_value(
			resource.get(property_name),
			owner_path,
			visited,
			stats
		)


func _expect(condition: bool, message: String) -> void:
	if not condition:
		_failures_append_once(message)


func _failures_append_once(message: String) -> void:
	if not failures.has(message):
		failures.append(message)
