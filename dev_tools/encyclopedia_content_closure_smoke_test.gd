extends SceneTree

const RecipeRegistry := preload(
	"res://resources/config/production/production_recipe_registry.gd"
)
const INTERNAL_WATER_SOURCE_PATH := (
	"res://resources/config/production/water_source.tres"
)

var failures: Array[String] = []


func _init() -> void:
	call_deferred(&"_run")


func _run() -> void:
	var catalog := CodexCatalog.new()
	_test_enemy_closure(catalog)
	_test_pickup_partition(catalog)
	_test_building_closure(catalog)
	_test_character_closure(catalog)
	_test_recipe_closure(catalog)
	_test_research_closure(catalog)
	catalog.clear_cache()
	if failures.is_empty():
		print("ENCYCLOPEDIA_CONTENT_CLOSURE_SMOKE_TEST_OK")
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	quit(1)


func _test_enemy_closure(catalog: CodexCatalog) -> void:
	var runtime_paths := _value_set(RuntimeContentCatalog.get_enemy_entries())
	var codex_paths := {}
	for source in EnemyCodexRegistry.get_all_entries():
		if source != null and source.enemy_config != null:
			codex_paths[source.enemy_config.resource_path] = true
	_expect(
		runtime_paths.size() == 64
		and codex_paths.size() == 64
		and runtime_paths == codex_paths
		and catalog.get_entries(CodexSection.ENEMY).size() == 64,
		"运行时64种敌人与敌人百科必须按资源路径形成完整闭包。"
	)


func _test_pickup_partition(catalog: CodexCatalog) -> void:
	var runtime_paths := _value_set(RuntimeContentCatalog.get_pickup_entries())
	var building_paths := {}
	for item in BuildingItemRegistry.get_all_items():
		building_paths[item.resource_path] = true
	var collectible_paths := {}
	for item in CollectibleRegistry.get_all():
		collectible_paths[item.resource_path] = true
	var collectible_entry_paths := {}
	for entry in catalog.get_entries(CodexSection.COLLECTIBLE):
		var item := entry.source_resource as PickupConfig
		_expect(item != null, "收藏品百科条目必须保留PickupConfig来源。")
		if item == null:
			continue
		collectible_entry_paths[item.resource_path] = true
		_expect(
			entry.entry_id
			== StringName(
				RuntimeContentCatalog.get_pickup_id_for_path(item.resource_path)
			),
			"收藏品百科必须复用运行时稳定ID：%s。" % item.resource_path
		)
	var general_item_paths := {}
	for entry in catalog.get_entries(CodexSection.ITEM):
		var item := entry.source_resource as PickupConfig
		_expect(item != null, "通用物品百科条目必须保留PickupConfig来源。")
		if item == null:
			continue
		general_item_paths[item.resource_path] = true
		_expect(
			entry.entry_id
			== StringName(
				RuntimeContentCatalog.get_pickup_id_for_path(item.resource_path)
			),
			"通用物品百科必须复用运行时稳定ID：%s。" % item.resource_path
		)
	var internal_paths := {INTERNAL_WATER_SOURCE_PATH: true}
	var partition_union := {}
	for path_set in [
		building_paths,
		collectible_paths,
		general_item_paths,
		internal_paths,
	]:
		for path_variant in path_set:
			partition_union[String(path_variant)] = true
	var partition_size_sum := (
		building_paths.size()
		+ collectible_paths.size()
		+ general_item_paths.size()
		+ internal_paths.size()
	)
	_expect(
		building_paths.size() == 19
		and collectible_paths.size() == 125
		and collectible_entry_paths == collectible_paths
		and general_item_paths.size() == 36
		and partition_size_sum == 181
		and partition_union.size() == partition_size_sum
		and partition_union == runtime_paths,
		"181项运行时道具必须无重叠地归入建筑19、收藏品125、通用物品36或内部水源1。"
	)
	_expect(
		runtime_paths.has(INTERNAL_WATER_SOURCE_PATH)
		and not general_item_paths.has(INTERNAL_WATER_SOURCE_PATH),
		"环境水源必须显式保留为内部配方投入，不能出现在玩家物品百科。"
	)


func _test_building_closure(catalog: CodexCatalog) -> void:
	var config_ids := {}
	for config in PlantDefenseRegistry.get_all_configs():
		config_ids[config.plant_id] = true
		_expect(
			BuildingItemRegistry.get_item(config.plant_id) != null,
			"每个建筑配置都必须有对应建筑物品：%s。" % config.plant_id
		)
	var entry_ids := {}
	for entry in catalog.get_entries(CodexSection.BUILDING):
		entry_ids[entry.entry_id] = true
	_expect(
		config_ids.size() == 19
		and entry_ids.size() == 19
		and config_ids == entry_ids,
		"建筑注册表、建筑物品映射与建筑百科必须19对19闭合。"
	)


func _test_character_closure(catalog: CodexCatalog) -> void:
	var expected_paths := {}
	for config in PlayerCharacterRegistry.get_all_configs():
		expected_paths[config.resource_path] = true
	var actual_paths := {}
	for entry in catalog.get_entries(CodexSection.CHARACTER):
		var config := entry.source_resource as PlayerCharacterConfig
		_expect(config != null, "角色百科条目必须保留PlayerCharacterConfig来源。")
		if config == null:
			continue
		actual_paths[config.resource_path] = true
		_expect(
			entry.entry_id == StringName("character.%s" % config.character_id),
			"角色百科必须使用带命名空间的稳定ID：%s。" % config.character_id
		)
	_expect(
		expected_paths.size() == 4 and expected_paths == actual_paths,
		"4个可玩角色必须全部进入角色百科。"
	)


func _test_recipe_closure(catalog: CodexCatalog) -> void:
	_expect(RecipeRegistry.validate_contract(), "32条生产配方注册表必须有效。")
	var expected_paths := {}
	for recipe in RecipeRegistry.get_all_recipes():
		expected_paths[recipe.resource_path] = true
	var actual_paths := {}
	for entry in catalog.get_entries(CodexSection.RECIPE):
		var recipe := entry.source_resource as ProductionRecipe
		_expect(recipe != null, "配方百科条目必须保留ProductionRecipe来源。")
		if recipe == null:
			continue
		actual_paths[recipe.resource_path] = true
		_expect(
			entry.entry_id == StringName("recipe.%s" % recipe.recipe_id),
			"配方百科必须使用带命名空间的稳定ID：%s。" % recipe.recipe_id
		)
	_expect(
		expected_paths.size() == 32 and expected_paths == actual_paths,
		"9条简易制作与23条建筑生产配方必须全部进入配方百科。"
	)


func _test_research_closure(catalog: CodexCatalog) -> void:
	var expected_ids := {}
	for config in GlobalResearchRegistry.get_all_configs():
		expected_ids[config.research_id] = true
	var actual_ids := {}
	for entry in catalog.get_entries(CodexSection.RESEARCH):
		var config := entry.source_resource as GlobalResearchConfig
		_expect(config != null, "科研百科条目必须保留GlobalResearchConfig来源。")
		if config == null:
			continue
		actual_ids[config.research_id] = true
		_expect(
			entry.entry_id == StringName("research.%s" % config.research_id),
			"科研百科必须使用带命名空间的稳定ID：%s。" % config.research_id
		)
	_expect(
		expected_ids.size() == 9 and expected_ids == actual_ids,
		"9项全局科研必须全部进入科研百科。"
	)


func _value_set(entries: Dictionary) -> Dictionary:
	var result := {}
	for value_variant in entries.values():
		result[String(value_variant)] = true
	return result


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
