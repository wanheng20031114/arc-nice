extends SceneTree

const RecipeRegistry := preload(
	"res://resources/config/production/production_recipe_registry.gd"
)
const EXPECTED_RECIPE_IDS: Array[StringName] = [
	&"herbal_health_potion",
	&"wood_processing_station",
	&"oak_warehouse",
	&"vegetation_stake",
	&"stone_mill",
	&"simple_fence",
	&"gel_to_water_bottle",
	&"bamboo_mortar",
	&"hydrangea_rain_tower",
	&"wood_to_plank",
	&"wooden_core_assembly",
	&"gambler_ticket_assembly",
	&"water_collector_assembly",
	&"planting_base_assembly",
	&"plant_cultivation_center_assembly",
	&"research_center_assembly",
	&"excavator_assembly",
	&"life_tower_assembly",
	&"speed_tower_assembly",
	&"attack_speed_tower_assembly",
	&"sapling_propagation",
	&"sapling_to_wood",
	&"water_to_bottle",
	&"white_crystal_to_powder",
	&"capoo_blue_crystal_to_powder",
	&"wooden_core_to_agave_cannon",
	&"wooden_core_to_corn_machine_gun",
	&"wooden_core_to_bamboo_mortar",
	&"wooden_core_to_hydrangea_rain_tower",
	&"wooden_core_to_grape_arc_tower",
	&"wooden_core_to_orange_charging_tower",
	&"excavator_cycle",
]
const EXPECTED_CATEGORY_COUNTS := {
	RecipeRegistry.Category.SIMPLE_CRAFTING: 9,
	RecipeRegistry.Category.SHARED_PRODUCTION: 22,
	RecipeRegistry.Category.LOCAL_OUTPUT_CYCLE: 1,
}
const PRODUCER_SCENE_PATHS := {
	RecipeRegistry.WOOD_PROCESSING_STATION_PRODUCER_ID: (
		"res://scene/plant_defense/wood_processing_station.tscn"
	),
	RecipeRegistry.PLANTING_BASE_PRODUCER_ID: (
		"res://scene/plant_defense/planting_base.tscn"
	),
	RecipeRegistry.WATER_COLLECTOR_PRODUCER_ID: (
		"res://scene/plant_defense/water_collector.tscn"
	),
	RecipeRegistry.STONE_MILL_PRODUCER_ID: (
		"res://scene/plant_defense/stone_mill.tscn"
	),
	RecipeRegistry.PLANT_CULTIVATION_CENTER_PRODUCER_ID: (
		"res://scene/plant_defense/plant_cultivation_center.tscn"
	),
	RecipeRegistry.EXCAVATOR_PRODUCER_ID: (
		"res://scene/plant_defense/excavator.tscn"
	),
}

var failures: Array[String] = []


func _init() -> void:
	call_deferred(&"_run")


func _run() -> void:
	_test_registry_contract()
	_test_enhancement_tower_recipe_ids_and_inputs()
	_test_runtime_source_closure()
	_test_research_gate_closure()
	if failures.is_empty():
		print("PRODUCTION_RECIPE_REGISTRY_SMOKE_TEST_OK")
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	quit(1)


func _test_registry_contract() -> void:
	var recipes := RecipeRegistry.get_all_recipes()
	var actual_ids: Array[StringName] = []
	var seen_ids := {}
	var seen_paths := {}
	var category_counts := {}
	_expect(
		RecipeRegistry.get_registered_count() == 32
		and recipes.size() == 32
		and RecipeRegistry.validate_contract(),
		"配方注册表必须显式公开32条完整有效的作者配方。"
	)
	for recipe in recipes:
		actual_ids.append(recipe.recipe_id)
		_expect(
			recipe.is_valid()
			and not seen_ids.has(recipe.recipe_id)
			and not seen_paths.has(recipe.resource_path)
			and RecipeRegistry.get_recipe(recipe.recipe_id) == recipe,
			"配方ID、资源路径与注册反查必须形成唯一闭环：%s。"
			% recipe.recipe_id
		)
		seen_ids[recipe.recipe_id] = true
		seen_paths[recipe.resource_path] = true
		var category := RecipeRegistry.get_category_for_recipe(recipe)
		category_counts[category] = int(category_counts.get(category, 0)) + 1
		_expect(
			category != RecipeRegistry.INVALID_CATEGORY
			and RecipeRegistry.get_category_key(category) != &""
			and not RecipeRegistry.get_category_label(category).is_empty()
			and RecipeRegistry.get_producer_id(recipe.recipe_id) != &""
			and RecipeRegistry.get_producer_label(recipe.recipe_id)
			!= "未知生产端",
			"每条配方都必须提供稳定的百科分类与生产端标签：%s。"
			% recipe.recipe_id
		)
		match category:
			RecipeRegistry.Category.SIMPLE_CRAFTING:
				_expect(
					recipe.inputs_from_player_inventory()
					and recipe.outputs_to_player_inventory(),
					"简易制作必须从背包投入并回到背包：%s。"
					% recipe.recipe_id
				)
			RecipeRegistry.Category.SHARED_PRODUCTION:
				_expect(
					not recipe.inputs_from_player_inventory()
					and not recipe.outputs_to_player_inventory()
					and not recipe.outputs_to_local_slot(),
					"共享生产必须从共享来源投入并产入共享仓库：%s。"
					% recipe.recipe_id
				)
			RecipeRegistry.Category.LOCAL_OUTPUT_CYCLE:
				_expect(
					not recipe.inputs_from_player_inventory()
					and recipe.outputs_to_local_slot(),
					"本地循环必须使用共享来源并产入建筑本地产物格：%s。"
					% recipe.recipe_id
				)
	_expect(
		actual_ids == EXPECTED_RECIPE_IDS,
		"配方注册表顺序必须稳定，实际为：%s。" % [actual_ids]
	)
	_expect(
		category_counts == EXPECTED_CATEGORY_COUNTS,
		"配方分类必须固定为简易9、共享生产22、本地循环1，实际为：%s。"
		% [category_counts]
	)
	_expect(
		not seen_ids.has(&"water_source")
		and not seen_paths.has(
			"res://resources/config/production/water_source.tres"
		),
		"环境水瓦片只能作为配方投入，不得被登记成生产配方。"
	)


func _test_runtime_source_closure() -> void:
	var registered_simple_ids := _registered_ids_for_producer(
		RecipeRegistry.SIMPLE_CRAFTING_PRODUCER_ID
	)
	var runtime_simple_ids := {}
	for recipe in SimpleCraftingRegistry.get_all_recipes():
		runtime_simple_ids[recipe.recipe_id] = true
	_expect(
		registered_simple_ids == runtime_simple_ids,
		"配方百科的9条简易制作必须与SimpleCraftingRegistry完全一致。"
	)
	for producer_id_variant in PRODUCER_SCENE_PATHS:
		var producer_id := StringName(producer_id_variant)
		var scene_path := String(PRODUCER_SCENE_PATHS[producer_id])
		var packed := load(scene_path) as PackedScene
		var building := (
			packed.instantiate() as ProductionBuilding
			if packed != null
			else null
		)
		_expect(building != null, "生产端场景必须可实例化：%s。" % scene_path)
		if building == null:
			continue
		var runtime_ids := {}
		for recipe in building.recipes:
			if recipe != null:
				runtime_ids[recipe.recipe_id] = true
		var registered_ids := _registered_ids_for_producer(producer_id)
		_expect(
			registered_ids == runtime_ids,
			"配方注册表必须与生产端%s场景挂载的配方完全一致。"
			% producer_id
		)
		building.free()


func _registered_ids_for_producer(producer_id: StringName) -> Dictionary:
	var result := {}
	for recipe_id in RecipeRegistry.RECIPE_ORDER:
		if RecipeRegistry.get_producer_id(recipe_id) == producer_id:
			result[recipe_id] = true
	return result


func _test_research_gate_closure() -> void:
	var gated_recipe_count := 0
	for recipe in RecipeRegistry.get_all_recipes():
		if not recipe.requires_global_research():
			continue
		gated_recipe_count += 1
		var category := RecipeRegistry.get_category_for_recipe(recipe)
		var reverse_research_id := (
			GlobalResearchRegistry.get_unlock_research_id_for_simple_crafting_recipe(
				recipe.recipe_id
			)
			if category == RecipeRegistry.Category.SIMPLE_CRAFTING
			else GlobalResearchRegistry.get_unlock_research_id_for_production_recipe(
				recipe.recipe_id
			)
		)
		_expect(
			reverse_research_id == recipe.required_global_research_id,
			"配方到科研的运行门禁必须能由科研元数据反查：%s。"
			% recipe.recipe_id
		)
	for research in GlobalResearchRegistry.get_all_configs():
		_expect(research.is_valid(), "登记科研必须保持有效：%s。" % research.research_id)
		if research.unlocked_simple_crafting_recipe_id != &"":
			var simple_recipe := RecipeRegistry.get_recipe(
				research.unlocked_simple_crafting_recipe_id
			)
			_expect(
				simple_recipe != null
				and RecipeRegistry.get_category_for_recipe(simple_recipe)
				== RecipeRegistry.Category.SIMPLE_CRAFTING
				and simple_recipe.required_global_research_id
				== research.research_id
				and GlobalResearchRegistry.get_unlock_research_id_for_simple_crafting_recipe(
					simple_recipe.recipe_id
				) == research.research_id,
				"科研声明的简易配方必须存在并反向指回同一科研：%s。"
				% research.research_id
			)
		if research.unlocked_production_recipe_id != &"":
			var production_recipe := RecipeRegistry.get_recipe(
				research.unlocked_production_recipe_id
			)
			_expect(
				production_recipe != null
				and RecipeRegistry.get_category_for_recipe(production_recipe)
				!= RecipeRegistry.Category.SIMPLE_CRAFTING
				and production_recipe.required_global_research_id
				== research.research_id
				and GlobalResearchRegistry.get_unlock_research_id_for_production_recipe(
					production_recipe.recipe_id
				) == research.research_id,
				"科研声明的生产配方必须存在并反向指回同一科研：%s。"
				% research.research_id
			)
	_expect(gated_recipe_count == 5, "当前科研门禁必须完整覆盖5条配方。")
	var bamboo := GlobalResearchRegistry.BAMBOO_MORTAR_CRAFTING
	var hydrangea := GlobalResearchRegistry.HYDRANGEA_RAIN_TOWER_CRAFTING
	_expect(
		bamboo.unlocked_simple_crafting_recipe_id == &"bamboo_mortar"
		and bamboo.unlocked_production_recipe_id
		== &"wooden_core_to_bamboo_mortar"
		and bamboo.description.contains("简易制作")
		and bamboo.description.contains("植物培育中心"),
		"竹筒迫击炮科研必须同时说明并索引简易制作与植物培育配方。"
	)
	_expect(
		hydrangea.unlocked_simple_crafting_recipe_id == &"hydrangea_rain_tower"
		and hydrangea.unlocked_production_recipe_id
		== &"wooden_core_to_hydrangea_rain_tower"
		and hydrangea.description.contains("简易制作")
		and hydrangea.description.contains("植物培育中心"),
		"紫阳花科研必须同时说明并索引简易制作与植物培育配方。"
	)


func _test_enhancement_tower_recipe_ids_and_inputs() -> void:
	for recipe_id in [
		&"life_tower_assembly",
		&"speed_tower_assembly",
		&"attack_speed_tower_assembly",
	]:
		var recipe := RecipeRegistry.get_recipe(recipe_id)
		_expect(
			recipe != null
			and recipe.recipe_id == recipe_id
			and not String(recipe.recipe_id).contains("wooden_core")
			and recipe.input_items.size() == 2
			and recipe.input_amounts == [10, 2]
			and recipe.input_items[0].resource_path
			== "res://resources/config/materials/material_plank.tres"
			and recipe.input_items[1].resource_path
			== "res://resources/config/materials/material_sapling.tres",
			"强化塔组装配方ID必须与10木板、2树苗的真实投入一致：%s。"
			% recipe_id
		)


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
