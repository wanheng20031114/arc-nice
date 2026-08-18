extends SceneTree

const PRODUCTION_COORDINATOR_SCENE := preload(
	"res://scene/game_modes/tower_defense/economy/production/production_coordinator.tscn"
)
const RESEARCH_COORDINATOR_SCENE := preload(
	"res://scene/game_modes/tower_defense/economy/research/research_coordinator.tscn"
)
const DAY_NIGHT_CONTROLLER_SCENE := preload(
	"res://scene/lighting/day_night_controller.tscn"
)
const WAREHOUSE_SCENE := preload("res://scene/plant_defense/oak_warehouse.tscn")
const PANEL_SCENE := preload("res://scene/game_modes/tower_defense/economy/research/research_center_panel.tscn")
const WEISHIDAIER_SCENE := preload(
	"res://scene/player/weishidaier/player_weishidaier.tscn"
)
const TIYI_SCENE := preload("res://scene/player/tiyi/player_tiyi.tscn")
const HOE_CAT_SCENE := preload("res://scene/player/hoe_cat/player_hoe_cat.tscn")
const TANGO_SCENE := preload("res://scene/player/tango/player_tango.tscn")
const PLANK := preload("res://resources/config/materials/material_plank.tres")
const SAPLING := preload("res://resources/config/materials/material_sapling.tres")
const WATER_BOTTLE := preload(
	"res://resources/config/materials/material_water_bottle.tres"
)
const WHITE_CRYSTAL_POWDER := preload(
	"res://resources/config/materials/material_white_crystal_powder.tres"
)
const DIRT_BLOCK := preload(
	"res://resources/config/materials/material_dirt_block.tres"
)
const WOODEN_CORE := preload(
	"res://resources/config/materials/material_wooden_core.tres"
)
const BUILDING_DEFENSE_RESEARCH_ID := (
	GlobalResearchRegistry.BUILDING_DEFENSE_ID
)
const BUILDING_DEFENSE_II_RESEARCH_ID := (
	GlobalResearchRegistry.BUILDING_DEFENSE_II_ID
)
const BUILDING_DEFENSE_III_RESEARCH_ID := (
	GlobalResearchRegistry.BUILDING_DEFENSE_III_ID
)
const PLAYER_MOVE_SPEED_RESEARCH_ID := (
	GlobalResearchRegistry.PLAYER_MOVE_SPEED_ID
)
const BAMBOO_MORTAR_CRAFTING_RESEARCH_ID := (
	GlobalResearchRegistry.BAMBOO_MORTAR_CRAFTING_ID
)
const HYDRANGEA_RAIN_TOWER_CRAFTING_RESEARCH_ID := (
	GlobalResearchRegistry.HYDRANGEA_RAIN_TOWER_CRAFTING_ID
)
const ORANGE_CHARGING_TOWER_CRAFTING_RESEARCH_ID := (
	GlobalResearchRegistry.ORANGE_CHARGING_TOWER_CRAFTING_ID
)
const VEGETATION_STAKE_SPREAD_ENHANCEMENT_RESEARCH_ID := (
	GlobalResearchRegistry.VEGETATION_STAKE_SPREAD_ENHANCEMENT_ID
)
const VEGETATION_ENHANCEMENT_RESEARCH_ID := (
	GlobalResearchRegistry.VEGETATION_ENHANCEMENT_ID
)
const WATER_COLLECTION_RATE_ENHANCEMENT_RESEARCH_ID := (
	GlobalResearchRegistry.WATER_COLLECTION_RATE_ENHANCEMENT_ID
)
const FENCE_REINFORCEMENT_RESEARCH_ID := (
	GlobalResearchRegistry.FENCE_REINFORCEMENT_ID
)
const AGAVE_CANNON_MUZZLE_IMPROVEMENT_RESEARCH_ID := (
	GlobalResearchRegistry.AGAVE_CANNON_MUZZLE_IMPROVEMENT_ID
)
const CORN_MACHINE_GUN_COOLING_SYSTEM_IMPROVEMENT_RESEARCH_ID := (
	GlobalResearchRegistry.CORN_MACHINE_GUN_COOLING_SYSTEM_IMPROVEMENT_ID
)
const BAMBOO_MORTAR_CONCUSSIVE_MODIFICATION_RESEARCH_ID := (
	GlobalResearchRegistry.BAMBOO_MORTAR_CONCUSSIVE_MODIFICATION_ID
)
const GRAPE_ARC_TOWER_SURGE_MODIFICATION_RESEARCH_ID := (
	GlobalResearchRegistry.GRAPE_ARC_TOWER_SURGE_MODIFICATION_ID
)

var failures: PackedStringArray = []


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var test_root := Node.new()
	test_root.name = "ResearchCenterSmokeTest"
	root.add_child(test_root)

	var production := (
		PRODUCTION_COORDINATOR_SCENE.instantiate() as ProductionCoordinator
	)
	var research := RESEARCH_COORDINATOR_SCENE.instantiate() as ResearchCoordinator
	var day_night := (
		DAY_NIGHT_CONTROLLER_SCENE.instantiate() as DayNightController
	)
	var warehouse := WAREHOUSE_SCENE.instantiate() as OakWarehouse
	var second_warehouse := WAREHOUSE_SCENE.instantiate() as OakWarehouse
	var plant_system := PlantSystem.new()
	var panel := PANEL_SCENE.instantiate() as ResearchCenterPanel
	var weishidaier := WEISHIDAIER_SCENE.instantiate() as Player
	var tiyi := TIYI_SCENE.instantiate() as Player
	var hoe_cat := HOE_CAT_SCENE.instantiate() as Player
	var tango := TANGO_SCENE.instantiate() as PlayerTango
	var config := PlantDefenseRegistry.get_config(&"research_center")
	var center := (
		config.plant_scene.instantiate() as ResearchCenter
		if config != null
		else null
	)
	for node in [
		day_night,
		production,
		research,
		warehouse,
		second_warehouse,
		plant_system,
		panel,
		weishidaier,
		tiyi,
		hoe_cat,
		tango,
		center,
	]:
		if node != null:
			test_root.add_child(node)
	await process_frame
	day_night.set_night_factor_immediate(1.0)
	await process_frame
	production.production_tick_timer.stop()
	research.research_tick_timer.stop()
	_expect(
		is_equal_approx(research.research_tick_timer.wait_time, 0.25),
		"科研进度必须以4Hz权威事件步进，使外框无需逐帧CPU Tween。"
	)

	_test_config_and_scene(config, center, panel, day_night)
	_test_interaction_candidate_ordering(test_root)
	if config == null or center == null:
		_finish(test_root)
		return

	var warehouse_config := PlantDefenseRegistry.get_config(&"oak_warehouse")
	warehouse.setup(warehouse_config, weishidaier, [Vector2i.ZERO])
	second_warehouse.setup(warehouse_config, weishidaier, [Vector2i(-1, 0)])
	weishidaier.peer_id = 1
	tiyi.peer_id = 2
	hoe_cat.peer_id = 3
	tango.peer_id = 4
	center.setup(
		config,
		weishidaier,
		[
			Vector2i.ZERO,
			Vector2i.RIGHT,
			Vector2i.DOWN,
			Vector2i.ONE,
		]
	)
	_test_operational_night_visuals(center, day_night)
	production.register_plant(warehouse)
	production.register_plant(second_warehouse)
	research.setup(production, plant_system, null)
	research.register_player(weishidaier)
	research.register_player(tiyi)
	research.register_player(hoe_cat)
	research.register_player(tango)
	center.set_research_services(research, panel)
	await _test_panel_mouse_navigation(panel, center, weishidaier)
	await _test_building_defense_research_chain(test_root, config)
	await _test_tower_specific_research_projection(test_root)
	plant_system.plant_footprints[center] = center.footprint_cells.duplicate()
	center.call("_sync_research_border")
	_expect_research_border_state(
		center,
		false,
		0.0,
		"没有全局研究时科研中心外框必须保持淡蓝噪波空闲态。"
	)

	_expect(warehouse.try_add_storage_item_count(PLANK, 30), "第一测试仓库必须能加入30木板。")
	_expect(warehouse.try_add_storage_item_count(SAPLING, 10), "第一测试仓库必须能加入10树苗。")
	_expect(warehouse.try_add_storage_item_count(WATER_BOTTLE, 25), "第一测试仓库必须能加入25水瓶。")
	_expect(second_warehouse.try_add_storage_item_count(PLANK, 20), "第二测试仓库必须能加入20木板。")
	_expect(second_warehouse.try_add_storage_item_count(SAPLING, 9), "第二测试仓库必须能加入9树苗。")
	_expect(second_warehouse.try_add_storage_item_count(WATER_BOTTLE, 30), "第二测试仓库必须能加入30水瓶。")
	var missing_result := center.try_start_global_research()
	_expect(
		missing_result == ResearchCoordinator.RESULT_MISSING_INPUT
		and production.get_total_item_count(PLANK) == 50
		and production.get_total_item_count(SAPLING) == 19
		and production.get_total_item_count(WATER_BOTTLE) == 55,
		"任一研究材料不足时，多仓库事务必须整体失败且不能预扣其他材料。"
	)
	_expect(second_warehouse.try_add_storage_item_count(SAPLING, 11), "第二测试仓库必须能补入11树苗。")
	var start_result := center.try_start_global_research()
	_expect(start_result == ResearchCoordinator.RESULT_SUCCESS, "材料足够时必须立即开始全局研究。")
	center.call("_sync_research_border")
	_expect_research_border_state(
		center,
		true,
		0.0,
		"研究开始时科研中心外框必须立即切换为从顶部零点起步的进度态。"
	)
	await _test_research_border_event_step(center)
	_expect(
		production.get_total_item_count(PLANK) == 20
		and production.get_total_item_count(SAPLING) == 10
		and production.get_total_item_count(WATER_BOTTLE) == 5,
		"开始研究的同一帧必须原子扣除30木板、20树苗与50水瓶。"
	)
	var water_before_conflicting_request := production.get_total_item_count(
		WATER_BOTTLE
	)
	_expect(
		center.try_start_global_research(PLAYER_MOVE_SPEED_RESEARCH_ID)
		== ResearchCoordinator.RESULT_IN_PROGRESS
		and production.get_total_item_count(WATER_BOTTLE)
		== water_before_conflicting_request,
		"同一时刻只能进行一项全局研究，冲突请求不得预扣材料。"
	)
	research.advance_global_research(39.0)
	center.call("_sync_research_border")
	_expect_research_border_state(
		center,
		true,
		39.0 / 40.0,
		"研究未完成时科研中心外框必须准确采用最新权威进度。"
	)
	_expect(
		research.get_global_research_state(BUILDING_DEFENSE_RESEARCH_ID)
		== ResearchCoordinator.GlobalResearchState.RESEARCHING
		and is_equal_approx(
			research.get_global_elapsed_seconds(BUILDING_DEFENSE_RESEARCH_ID),
			39.0
		)
		and center.get_effective_physical_defense() == 5,
		"建筑结构强化I未满40秒时不得提前提供建筑物防。"
	)
	research.advance_global_research(1.0)
	center.call("_sync_research_border")
	_expect_research_border_state(
		center,
		false,
		0.0,
		"研究完成后科研中心外框必须退出进度态并恢复淡蓝空闲态。"
	)
	_expect(
		research.get_global_research_state(BUILDING_DEFENSE_RESEARCH_ID)
		== ResearchCoordinator.GlobalResearchState.COMPLETED
		and plant_system.get_global_physical_defense_bonus() == 5
		and center.get_effective_physical_defense() == 10,
		"建筑结构强化I完成后必须永久给现有建筑增加5点物防。"
	)
	_expect(
		center.try_start_global_research() == ResearchCoordinator.RESULT_COMPLETED,
		"完成的全局科技必须不可重复提交。"
	)

	await _test_global_move_speed_research(
		research,
		center,
		production,
		warehouse,
		second_warehouse,
		plant_system,
		[weishidaier, tiyi, hoe_cat, tango],
		test_root
	)
	await _test_recipe_unlock_research(
		research,
		center,
		production,
		warehouse,
		plant_system,
		test_root
	)
	await _test_player_technology(
		research,
		center,
		panel,
		weishidaier,
		tiyi,
		hoe_cat,
		tango
	)
	_test_multiplayer_request_contract(config, research, panel, test_root)
	_finish(test_root)


func _test_config_and_scene(
	config: PlantDefenseConfig,
	center: ResearchCenter,
	panel: ResearchCenterPanel,
	day_night: DayNightController
) -> void:
	var defense_research := GlobalResearchRegistry.get_config(
		BUILDING_DEFENSE_RESEARCH_ID
	)
	var defense_ii_research := GlobalResearchRegistry.get_config(
		BUILDING_DEFENSE_II_RESEARCH_ID
	)
	var defense_iii_research := GlobalResearchRegistry.get_config(
		BUILDING_DEFENSE_III_RESEARCH_ID
	)
	var move_speed_research := GlobalResearchRegistry.get_config(
		PLAYER_MOVE_SPEED_RESEARCH_ID
	)
	var bamboo_mortar_research := GlobalResearchRegistry.get_config(
		BAMBOO_MORTAR_CRAFTING_RESEARCH_ID
	)
	var hydrangea_research := GlobalResearchRegistry.get_config(
		HYDRANGEA_RAIN_TOWER_CRAFTING_RESEARCH_ID
	)
	var orange_research := GlobalResearchRegistry.get_config(
		ORANGE_CHARGING_TOWER_CRAFTING_RESEARCH_ID
	)
	var vegetation_spread_research := GlobalResearchRegistry.get_config(
		VEGETATION_STAKE_SPREAD_ENHANCEMENT_RESEARCH_ID
	)
	var vegetation_enhancement_research := GlobalResearchRegistry.get_config(
		VEGETATION_ENHANCEMENT_RESEARCH_ID
	)
	var water_collection_rate_research := GlobalResearchRegistry.get_config(
		WATER_COLLECTION_RATE_ENHANCEMENT_RESEARCH_ID
	)
	var fence_reinforcement_research := GlobalResearchRegistry.get_config(
		FENCE_REINFORCEMENT_RESEARCH_ID
	)
	var agave_cannon_research := GlobalResearchRegistry.get_config(
		AGAVE_CANNON_MUZZLE_IMPROVEMENT_RESEARCH_ID
	)
	var corn_machine_gun_research := GlobalResearchRegistry.get_config(
		CORN_MACHINE_GUN_COOLING_SYSTEM_IMPROVEMENT_RESEARCH_ID
	)
	var bamboo_concussive_research := GlobalResearchRegistry.get_config(
		BAMBOO_MORTAR_CONCUSSIVE_MODIFICATION_RESEARCH_ID
	)
	var grape_surge_research := GlobalResearchRegistry.get_config(
		GRAPE_ARC_TOWER_SURGE_MODIFICATION_RESEARCH_ID
	)
	var registered_research_projects := GlobalResearchRegistry.get_all_configs()
	_expect(
		registered_research_projects == [
			defense_research,
			defense_ii_research,
			defense_iii_research,
			move_speed_research,
			bamboo_mortar_research,
			hydrangea_research,
			orange_research,
			vegetation_spread_research,
			vegetation_enhancement_research,
			water_collection_rate_research,
			fence_reinforcement_research,
			agave_cannon_research,
			corn_machine_gun_research,
			bamboo_concussive_research,
			grape_surge_research,
		]
		and registered_research_projects.size() == 15
		and GlobalResearchRegistry.is_registry_valid()
		and GlobalResearchConfig.MAX_INPUT_ITEMS == 4
		and ResearchCoordinator.RUNTIME_STATE_SCHEMA == 3,
		"全局科研注册表必须按固定顺序公开十五个合法项目、允许四种材料并继续使用runtime schema3。"
	)
	_expect(
		defense_research != null
		and defense_research.is_valid()
		and defense_research.display_name == "建筑结构强化I"
		and defense_research.prerequisite_research_id == &""
		and is_equal_approx(defense_research.duration_seconds, 40.0)
		and defense_research.effects.size() == 1
		and is_equal_approx(
			GlobalResearchEffectResolver.get_additive_bonus(
				defense_research.effects,
				GlobalResearchAdditiveModifierEffect.ATTRIBUTE_BUILDING_PHYSICAL_DEFENSE
			),
			5.0
		)
		and defense_research.input_items.size() == 3
		and defense_research.input_items == [PLANK, SAPLING, WATER_BOTTLE]
		and defense_research.input_amounts == [30, 20, 50],
		"建筑结构强化I必须只以类型化效果表达40秒、30木板/20树苗/50水瓶与全建筑物防+5。"
	)
	_expect(
		defense_ii_research != null
		and defense_ii_research.is_valid()
		and defense_ii_research.display_name == "建筑结构强化II"
		and defense_ii_research.prerequisite_research_id
		== BUILDING_DEFENSE_RESEARCH_ID
		and is_equal_approx(defense_ii_research.duration_seconds, 50.0)
		and defense_ii_research.effects.size() == 1
		and is_equal_approx(
			GlobalResearchEffectResolver.get_additive_bonus(
				defense_ii_research.effects,
				GlobalResearchAdditiveModifierEffect.ATTRIBUTE_BUILDING_PHYSICAL_DEFENSE
			),
			5.0
		)
		and defense_ii_research.input_items == [PLANK, SAPLING, WATER_BOTTLE]
		and defense_ii_research.input_amounts == [50, 30, 50],
		"建筑结构强化II必须以前级为前置，耗时50秒、投入50木板/30树苗/50水瓶并再提供物防+5。"
	)
	_expect(
		defense_iii_research != null
		and defense_iii_research.is_valid()
		and defense_iii_research.display_name == "建筑结构强化III"
		and defense_iii_research.prerequisite_research_id
		== BUILDING_DEFENSE_II_RESEARCH_ID
		and is_equal_approx(defense_iii_research.duration_seconds, 70.0)
		and defense_iii_research.effects.size() == 1
		and is_equal_approx(
			GlobalResearchEffectResolver.get_additive_bonus(
				defense_iii_research.effects,
				GlobalResearchAdditiveModifierEffect.ATTRIBUTE_BUILDING_PHYSICAL_DEFENSE
			),
			5.0
		)
		and defense_iii_research.input_items
		== [PLANK, WATER_BOTTLE, DIRT_BLOCK, WHITE_CRYSTAL_POWDER]
		and defense_iii_research.input_amounts == [100, 100, 100, 10],
		"建筑结构强化III必须以前级为前置，耗时70秒、投入四种指定材料并再提供物防+5。"
	)
	_expect(
		move_speed_research != null
		and move_speed_research.is_valid()
		and is_equal_approx(move_speed_research.duration_seconds, 60.0)
		and move_speed_research.effects.size() == 1
		and is_equal_approx(
			GlobalResearchEffectResolver.get_additive_bonus(
				move_speed_research.effects,
				GlobalResearchAdditiveModifierEffect.ATTRIBUTE_PLAYER_MOVE_SPEED
			),
			15.0
		)
		and move_speed_research.input_items == [WATER_BOTTLE]
		and move_speed_research.input_amounts == [50],
		"全员移动训练必须消耗50水瓶、持续60秒并提供全员移速+15。"
	)
	_expect(
		bamboo_mortar_research != null
		and bamboo_mortar_research.is_valid()
		and bamboo_mortar_research.input_items == [WOODEN_CORE, SAPLING]
		and bamboo_mortar_research.input_amounts == [2, 5]
		and is_equal_approx(bamboo_mortar_research.duration_seconds, 30.0)
		and bamboo_mortar_research.effects.size() == 2
		and GlobalResearchEffectResolver.get_recipe_unlock_effects(
			bamboo_mortar_research.effects,
			GlobalResearchRecipeUnlockEffect.CATALOG_SIMPLE_CRAFTING
		).size() == 1
		and GlobalResearchEffectResolver.get_recipe_unlock_effects(
			bamboo_mortar_research.effects,
			GlobalResearchRecipeUnlockEffect.CATALOG_SIMPLE_CRAFTING
		)[0].recipe_id == SimpleCraftingRegistry.BAMBOO_MORTAR_ID
		and GlobalResearchEffectResolver.get_recipe_unlock_effects(
			bamboo_mortar_research.effects,
			GlobalResearchRecipeUnlockEffect.CATALOG_PRODUCTION
		).size() == 1
		and GlobalResearchRegistry.get_unlock_research_id_for_simple_crafting_recipe(
			SimpleCraftingRegistry.BAMBOO_MORTAR_ID
		) == BAMBOO_MORTAR_CRAFTING_RESEARCH_ID,
		"竹筒迫击炮装配研究必须是消耗2木制核心和5树苗、持续30秒的合法配方解锁研究。"
	)
	_expect(
		hydrangea_research != null
		and hydrangea_research.is_valid()
		and hydrangea_research.input_items == [WOODEN_CORE, SAPLING]
		and hydrangea_research.input_amounts == [2, 5]
		and is_equal_approx(hydrangea_research.duration_seconds, 30.0)
		and hydrangea_research.effects.size() == 2
		and GlobalResearchEffectResolver.get_recipe_unlock_effects(
			hydrangea_research.effects,
			GlobalResearchRecipeUnlockEffect.CATALOG_SIMPLE_CRAFTING
		).size() == 1
		and GlobalResearchEffectResolver.get_recipe_unlock_effects(
			hydrangea_research.effects,
			GlobalResearchRecipeUnlockEffect.CATALOG_SIMPLE_CRAFTING
		)[0].recipe_id == SimpleCraftingRegistry.HYDRANGEA_RAIN_TOWER_ID
		and GlobalResearchEffectResolver.get_recipe_unlock_effects(
			hydrangea_research.effects,
			GlobalResearchRecipeUnlockEffect.CATALOG_PRODUCTION
		).size() == 1
		and GlobalResearchRegistry.get_unlock_research_id_for_simple_crafting_recipe(
			SimpleCraftingRegistry.HYDRANGEA_RAIN_TOWER_ID
		) == HYDRANGEA_RAIN_TOWER_CRAFTING_RESEARCH_ID,
		"紫阳花雨幕塔培育研究必须是消耗2木制核心和5树苗、持续30秒的合法配方解锁研究。"
	)
	_expect(
		orange_research != null
		and orange_research.is_valid()
		and orange_research.input_items == [WOODEN_CORE, SAPLING]
		and orange_research.input_amounts == [2, 5]
		and is_equal_approx(orange_research.duration_seconds, 30.0)
		and orange_research.effects.size() == 1
		and GlobalResearchEffectResolver.get_recipe_unlock_effects(
			orange_research.effects,
			GlobalResearchRecipeUnlockEffect.CATALOG_SIMPLE_CRAFTING
		).is_empty()
		and GlobalResearchEffectResolver.get_recipe_unlock_effects(
			orange_research.effects,
			GlobalResearchRecipeUnlockEffect.CATALOG_PRODUCTION
		).size() == 1
		and GlobalResearchEffectResolver.get_recipe_unlock_effects(
			orange_research.effects,
			GlobalResearchRecipeUnlockEffect.CATALOG_PRODUCTION
		)[0].recipe_id == &"wooden_core_to_orange_charging_tower"
		and GlobalResearchRegistry.get_unlock_research_id_for_production_recipe(
			&"wooden_core_to_orange_charging_tower"
		) == ORANGE_CHARGING_TOWER_CRAFTING_RESEARCH_ID,
		"橘充能塔培育研究必须与紫阳花同为2木制核心、5树苗和30秒，但只解锁培育中心配方。"
	)
	_expect(
		vegetation_spread_research != null
		and vegetation_spread_research.is_valid()
		and vegetation_spread_research.input_items == [PLANK, WATER_BOTTLE]
		and vegetation_spread_research.input_amounts == [20, 5]
		and is_equal_approx(
			vegetation_spread_research.duration_seconds,
			60.0
		)
		and vegetation_spread_research.effects.size() == 1
		and is_equal_approx(
			GlobalResearchEffectResolver.get_multiplier(
				vegetation_spread_research.effects,
				GlobalResearchMultiplierModifierEffect.METRIC_VEGETATION_STAKE_SPREAD_SPEED
			),
			2.0
		),
		"植被桩蔓延增强必须消耗20木板和5水瓶、持续60秒，并将蔓延速率设为2倍。"
	)
	_expect(
		vegetation_enhancement_research != null
		and vegetation_enhancement_research.is_valid()
		and vegetation_enhancement_research.input_items
		== [WHITE_CRYSTAL_POWDER, WATER_BOTTLE, SAPLING]
		and vegetation_enhancement_research.input_amounts == [5, 30, 10]
		and is_equal_approx(
			vegetation_enhancement_research.duration_seconds,
			30.0
		)
		and vegetation_enhancement_research.effects.size() == 1
		and is_equal_approx(
			GlobalResearchEffectResolver.get_additive_bonus(
				vegetation_enhancement_research.effects,
				GlobalResearchAdditiveModifierEffect.ATTRIBUTE_GRASS_HEAL_MAX_HEALTH_RATIO
			),
			0.2
		),
		"植被强化必须消耗5白色水晶粉末、30水瓶和10树苗，持续30秒并额外提供20%草地回血。"
	)
	_expect(
		water_collection_rate_research != null
		and water_collection_rate_research.is_valid()
		and water_collection_rate_research.input_items
		== [WHITE_CRYSTAL_POWDER, WATER_BOTTLE, PLANK]
		and water_collection_rate_research.input_amounts == [3, 10, 20]
		and is_equal_approx(
			water_collection_rate_research.duration_seconds,
			30.0
		)
		and water_collection_rate_research.effects.size() == 1
		and is_equal_approx(
			GlobalResearchEffectResolver.get_multiplier(
				water_collection_rate_research.effects,
				GlobalResearchMultiplierModifierEffect.METRIC_WATER_COLLECTOR_CYCLE_DURATION
			),
			0.5
		),
		"采水速率提升必须消耗3白色水晶粉末、10水瓶和20木板，持续30秒并把单轮耗时缩短50%。"
	)
	_expect(
		fence_reinforcement_research != null
		and fence_reinforcement_research.is_valid()
		and fence_reinforcement_research.input_items == [PLANK, SAPLING]
		and fence_reinforcement_research.input_amounts == [100, 100]
		and is_equal_approx(
			fence_reinforcement_research.duration_seconds,
			30.0
		)
		and fence_reinforcement_research.effects.size() == 2
		and is_equal_approx(
			GlobalResearchEffectResolver.get_additive_bonus(
				fence_reinforcement_research.effects,
				GlobalResearchAdditiveModifierEffect.ATTRIBUTE_FENCE_MAX_HEALTH
			),
			1000.0
		)
		and is_equal_approx(
			GlobalResearchEffectResolver.get_additive_bonus(
				fence_reinforcement_research.effects,
				GlobalResearchAdditiveModifierEffect.ATTRIBUTE_FENCE_PHYSICAL_DEFENSE
			),
			5.0
		),
		"围栏强化必须消耗100木板和100树苗，持续30秒并提供1000生命与5物防。"
	)
	var bamboo_slow_effects := (
		GlobalResearchEffectResolver.get_tower_on_hit_slow_effects(
			bamboo_concussive_research.effects,
			PlantDefenseRegistry.BAMBOO_MORTAR_ID
		)
	)
	var grape_status_effects := (
		GlobalResearchEffectResolver.get_tower_on_hit_timed_status_effects(
			grape_surge_research.effects,
			PlantDefenseRegistry.GRAPE_ARC_TOWER_ID,
			GlobalResearchTowerOnHitTimedStatusEffect.STATUS_ELECTROMAGNETIC
		)
	)
	_expect(
		agave_cannon_research != null
		and agave_cannon_research.research_id
		== &"agave_cannon_muzzle_improvement"
		and agave_cannon_research.display_name == "加农炮炮口改进"
		and agave_cannon_research.category_id
		== GlobalResearchConfig.CATEGORY_BUILDING_ENHANCEMENT
		and agave_cannon_research.prerequisite_research_id == &""
		and is_equal_approx(agave_cannon_research.duration_seconds, 40.0)
		and agave_cannon_research.input_items == [PLANK, WATER_BOTTLE]
		and agave_cannon_research.input_amounts == [50, 50]
		and agave_cannon_research.effects.size() == 1
		and GlobalResearchEffectResolver.get_additive_int_bonus(
			agave_cannon_research.effects,
			GlobalResearchAdditiveModifierEffect.ATTRIBUTE_AGAVE_CANNON_ATTACK_DAMAGE
		) == 10,
		"加农炮炮口改进必须以稳定ID、40秒、50木板/50水瓶和龙舌兰伤害+10的类型化效果登记。"
	)
	_expect(
		corn_machine_gun_research != null
		and corn_machine_gun_research.research_id
		== &"corn_machine_gun_cooling_system_improvement"
		and corn_machine_gun_research.display_name == "机枪塔冷却系统改进"
		and corn_machine_gun_research.category_id
		== GlobalResearchConfig.CATEGORY_BUILDING_ENHANCEMENT
		and corn_machine_gun_research.prerequisite_research_id == &""
		and is_equal_approx(corn_machine_gun_research.duration_seconds, 40.0)
		and corn_machine_gun_research.input_items == [PLANK, WATER_BOTTLE]
		and corn_machine_gun_research.input_amounts == [50, 50]
		and corn_machine_gun_research.effects.size() == 1
		and GlobalResearchEffectResolver.get_additive_int_bonus(
			corn_machine_gun_research.effects,
			GlobalResearchAdditiveModifierEffect.ATTRIBUTE_CORN_MACHINE_GUN_BURST_COUNT
		) == 2,
		"机枪塔冷却系统改进必须以完整稳定ID、40秒、50木板/50水瓶和每轮+2发登记。"
	)
	_expect(
		bamboo_concussive_research != null
		and bamboo_concussive_research.research_id
		== &"bamboo_mortar_concussive_modification"
		and bamboo_concussive_research.display_name == "迫击炮弹震爆改造"
		and bamboo_concussive_research.category_id
		== GlobalResearchConfig.CATEGORY_BUILDING_ENHANCEMENT
		and bamboo_concussive_research.prerequisite_research_id == &""
		and is_equal_approx(bamboo_concussive_research.duration_seconds, 40.0)
		and bamboo_concussive_research.input_items == [PLANK, WATER_BOTTLE]
		and bamboo_concussive_research.input_amounts == [80, 50]
		and bamboo_concussive_research.effects.size() == 1
		and bamboo_slow_effects.size() == 1
		and is_equal_approx(bamboo_slow_effects[0].slow_ratio, 0.25)
		and is_equal_approx(bamboo_slow_effects[0].duration_seconds, 3.0),
		"迫击炮弹震爆改造必须保存25%减速与3秒时长的具名字段，而非匿名倍率槽。"
	)
	_expect(
		grape_surge_research != null
		and grape_surge_research.research_id
		== &"grape_arc_tower_surge_modification"
		and grape_surge_research.display_name == "电弧塔电涌改造"
		and grape_surge_research.category_id
		== GlobalResearchConfig.CATEGORY_BUILDING_ENHANCEMENT
		and grape_surge_research.prerequisite_research_id == &""
		and is_equal_approx(grape_surge_research.duration_seconds, 60.0)
		and grape_surge_research.input_items == [PLANK, WATER_BOTTLE, DIRT_BLOCK]
		and grape_surge_research.input_amounts == [50, 100, 100]
		and grape_surge_research.effects.size() == 2
		and grape_status_effects.size() == 1
		and is_equal_approx(grape_status_effects[0].duration_seconds, 10.0)
		and is_equal_approx(
			GlobalResearchEffectResolver.get_conditional_damage_bonus_ratio(
				grape_surge_research.effects,
				PlantDefenseRegistry.GRAPE_ARC_TOWER_ID,
				GlobalResearchTowerConditionalDamageBonusEffect.STATUS_ELECTROMAGNETIC
			),
			0.5
		)
		and GlobalResearchEffectFormatter.format_badge(
			grape_surge_research.effects
		) == "电磁附着\n10秒 / +50%",
		"电弧塔电涌改造必须组合10秒电磁附着与对电磁目标+50%两项独立类型化效果。"
	)
	_expect(
		config != null
		and config.is_valid()
		and config.max_health == 2800
		and config.physical_defense == 5
		and config.magic_defense == 20
		and config.footprint_size == Vector2i(2, 2)
		and config.supports_multiplayer,
		"科研中心配置必须为2800生命、5物防、20法防、2×2且支持多人。"
	)
	if center != null:
		var visual_root := center.get_node_or_null("VisualRoot") as Node2D
		var lower_sprite := center.get_node_or_null(
			"VisualRoot/LowerBody"
		) as Sprite2D
		var upper_sprite := center.get_node_or_null(
			"VisualRoot/UpperForeground"
		) as Sprite2D
		var lower_material := (
			lower_sprite.material as ShaderMaterial
			if lower_sprite != null
			else null
		)
		var upper_material := (
			upper_sprite.material as ShaderMaterial
			if upper_sprite != null
			else null
		)
		var research_border := center.get_node_or_null(
			"ResearchBorder"
		) as MeshInstance2D
		var border_mesh := (
			research_border.mesh as QuadMesh
			if research_border != null
			else null
		)
		var border_material := (
			research_border.material as ShaderMaterial
			if research_border != null
			else null
		)
		var hotspot_glow := center.get_node_or_null(
			"HotspotGlow"
		) as NightPointLight2D
		var authored_lights: Array[Node] = center.find_children(
			"*",
			"Light2D",
			true,
			false
		)
		var hotspot_texture_source := FileAccess.get_file_as_string(
			"res://resources/lighting/research_center_hotspots.svg"
		)
		var request_timer := center.get_node_or_null(
			"MultiplayerResearchRequestTimer"
		) as Timer
		_expect(
			visual_root != null
			and visual_root.scale == Vector2(0.5, 0.5)
			and lower_sprite != null
			and upper_sprite != null
			and lower_sprite.texture != null
			and upper_sprite.texture != null
			and lower_sprite.texture.get_size() == Vector2(64, 64)
			and upper_sprite.texture.get_size() == Vector2(64, 64)
			and lower_sprite.texture_filter
			== CanvasItem.TEXTURE_FILTER_NEAREST
			and upper_sprite.texture_filter
			== CanvasItem.TEXTURE_FILTER_NEAREST
			and lower_sprite.z_index == 0
			and upper_sprite.z_index == 4
			and center.lifecycle_visual_paths
			== [
				NodePath("VisualRoot/LowerBody"),
				NodePath("VisualRoot/UpperForeground"),
			],
			"科研中心必须以两张互补64×64贴图、0.5世界缩放和nearest采样分层显示。"
		)
		_expect(
			lower_material != null
			and upper_material != null
			and not lower_material.resource_local_to_scene
			and not upper_material.resource_local_to_scene
			and lower_material.shader != null
			and lower_material.shader == upper_material.shader
			and lower_material.shader.resource_path
			== "res://resources/shader/research_center_lifecycle_glow.gdshader"
			and (
				lower_material.get_shader_parameter(&"lifecycle_noise")
				is Texture2D
			)
			and float(
				lower_material.get_shader_parameter(&"glow_core_strength")
			) > float(
				lower_material.get_shader_parameter(&"glow_halo_strength")
			)
			and float(
				lower_material.get_shader_parameter(&"glow_pulse_amount")
			) > 0.0
			and is_equal_approx(
				float(
					lower_material.get_shader_parameter(
						&"transparent_halo_weight"
					)
				),
				1.0
			)
			and is_zero_approx(
				float(
					upper_material.get_shader_parameter(
						&"transparent_halo_weight"
					)
				)
			),
			"科研中心上下两层必须共用蓝色生命周期Shader，透明晕光只能由下层绘制。"
		)
		_expect(
			research_border != null
			and research_border.get_parent() == center
			and research_border.z_index == -1
			and research_border.texture_filter
			== CanvasItem.TEXTURE_FILTER_NEAREST
			and border_mesh != null
			and border_mesh.size == Vector2(32, 32)
			and border_material != null
			and not border_material.resource_local_to_scene
			and border_material.shader != null
			and border_material.shader.resource_path
			== "res://resources/shader/research_center_border.gdshader",
			"科研中心必须在未缩放根节点预建32×32、两个像素宽的独立科研进度外框。"
		)
		if border_material != null:
			var idle_blue: Color = border_material.get_shader_parameter(
				&"idle_blue"
			)
			var idle_shadow: Color = border_material.get_shader_parameter(
				&"idle_shadow"
			)
			var progress_cyan: Color = border_material.get_shader_parameter(
				&"progress_cyan"
			)
			var progress_aquamarine: Color = (
				border_material.get_shader_parameter(
					&"progress_aquamarine"
				)
			)
			_expect(
				idle_blue.is_equal_approx(
					Color(0.0, 191.0 / 255.0, 1.0, 1.0)
				)
				and idle_shadow.b > idle_shadow.g
				and progress_cyan.g >= 0.99
				and progress_cyan.b >= 0.99
				and progress_aquamarine.get_luminance()
				> idle_blue.get_luminance()
				and float(
					border_material.get_shader_parameter(
						&"data_noise_speed"
					)
				) > 0.0,
				"科研外框必须以#00BFFF为默认蓝，并以更明亮的青色噪波显示已完成进度。"
			)
		_expect(
			not center.has_method("_set_research_border_progress")
			and not center.has_method("_stop_border_progress_tween"),
			"科研外框进度必须只跟随低频权威研究事件更新，不能保留逐帧写参数的Tween回调。"
		)
		_expect(
			hotspot_glow != null
			and authored_lights.size() == 1
			and hotspot_glow.texture != null
			and hotspot_glow.texture.resource_path
			== "res://resources/lighting/research_center_hotspots.svg"
			and hotspot_glow.color.is_equal_approx(
				Color(112.0 / 255.0, 217.0 / 255.0, 1.0, 1.0)
			)
			and hotspot_glow.texture.get_size() == Vector2(256, 256)
			and is_equal_approx(hotspot_glow.texture_scale, 0.25)
			and is_equal_approx(hotspot_glow.night_energy, 0.72)
			and not hotspot_glow.starts_emitting
			and not hotspot_glow.shadow_enabled
			and not hotspot_glow.is_processing()
			and not hotspot_glow.is_physics_processing()
			and not hotspot_glow.is_emission_allowed()
			and not hotspot_glow.enabled
			and is_zero_approx(hotspot_glow.energy)
			and hotspot_glow.get("_controller") == day_night,
			"科研中心必须原生预建一盏绑定昼夜控制器、覆盖三处热点的淡蓝夜间灯。"
		)
		_expect(
			hotspot_texture_source.count("<circle ") == 3
			and hotspot_texture_source.contains(
				"cx=\"41.25\" cy=\"28.85\" r=\"5.5\""
			)
			and hotspot_texture_source.contains(
				"cx=\"22.63\" cy=\"41.55\" r=\"6.5\""
			)
			and hotspot_texture_source.contains(
				"cx=\"41.5\" cy=\"41.35\" r=\"6.5\""
			),
			"科研中心三处淡蓝热点必须保持光心位置并使用扩大的扩散半径。"
		)
		_expect(
			request_timer != null
			and request_timer.one_shot
			and is_equal_approx(request_timer.wait_time, 4.0),
			"科研中心必须原生预建4秒一次性多人请求超时Timer。"
		)
	_expect(
		panel != null
		and panel.has_node(
			"Overlay/PanelRoot/GlobalPage/ResearchListFrame/ResearchScroll"
		)
		and panel.has_node(
			"Overlay/PanelRoot/GlobalPage/ResearchListFrame/ResearchScroll/ResearchList/DefenseResearchButton"
		)
		and panel.has_node(
			"Overlay/PanelRoot/GlobalPage/ResearchListFrame/ResearchScroll/ResearchList/DefenseIIResearchButton"
		)
		and panel.has_node(
			"Overlay/PanelRoot/GlobalPage/ResearchListFrame/ResearchScroll/ResearchList/DefenseIIIResearchButton"
		)
		and panel.has_node(
			"Overlay/PanelRoot/GlobalPage/ResearchListFrame/ResearchScroll/ResearchList/MoveSpeedResearchButton"
		)
		and panel.has_node(
			"Overlay/PanelRoot/GlobalPage/ResearchListFrame/ResearchScroll/ResearchList/BambooMortarResearchButton"
		)
		and panel.has_node(
			"Overlay/PanelRoot/GlobalPage/ResearchListFrame/ResearchScroll/ResearchList/HydrangeaResearchButton"
		)
		and panel.has_node(
			"Overlay/PanelRoot/GlobalPage/ResearchListFrame/ResearchScroll/ResearchList/OrangeChargingTowerResearchButton"
		)
		and panel.has_node(
			"Overlay/PanelRoot/GlobalPage/ResearchListFrame/ResearchScroll/ResearchList/VegetationStakeSpreadResearchButton"
		)
		and panel.has_node(
			"Overlay/PanelRoot/GlobalPage/ResearchListFrame/ResearchScroll/ResearchList/VegetationEnhancementResearchButton"
		)
		and panel.has_node(
			"Overlay/PanelRoot/GlobalPage/ResearchListFrame/ResearchScroll/ResearchList/WaterCollectionRateResearchButton"
		)
		and panel.has_node(
			"Overlay/PanelRoot/GlobalPage/ResearchListFrame/ResearchScroll/ResearchList/FenceReinforcementResearchButton"
		)
		and panel.has_node(
			"Overlay/PanelRoot/GlobalPage/ResearchListFrame/ResearchScroll/ResearchList/AgaveCannonMuzzleResearchButton"
		)
		and panel.has_node(
			"Overlay/PanelRoot/GlobalPage/ResearchListFrame/ResearchScroll/ResearchList/CornMachineGunCoolingResearchButton"
		)
		and panel.has_node(
			"Overlay/PanelRoot/GlobalPage/ResearchListFrame/ResearchScroll/ResearchList/BambooMortarConcussionResearchButton"
		)
		and panel.has_node(
			"Overlay/PanelRoot/GlobalPage/ResearchListFrame/ResearchScroll/ResearchList/GrapeArcTowerSurgeResearchButton"
		)
		and panel.global_research_buttons.size() == 15
		and not panel.defense_ii_research_button.visible
		and not panel.defense_iii_research_button.visible
		and panel.agave_cannon_muzzle_research_button.visible
		and panel.corn_machine_gun_cooling_research_button.visible
		and panel.bamboo_mortar_concussion_research_button.visible
		and panel.grape_arc_tower_surge_research_button.visible
		and panel.has_node("Overlay/PanelRoot/GlobalPage/PlankSlot")
		and panel.has_node("Overlay/PanelRoot/GlobalPage/SaplingSlot")
		and panel.has_node("Overlay/PanelRoot/GlobalPage/WaterBottleSlot")
		and panel.has_node("Overlay/PanelRoot/GlobalPage/MaterialSlot4")
		and panel.material_slots.size() == 4
		and panel.material_labels.size() == 4
		and panel.has_node("Overlay/PanelRoot/PlayerPage/TechNode1")
		and panel.has_node("Overlay/PanelRoot/PlayerPage/TechNode2")
		and panel.has_node("Overlay/PanelRoot/PlayerPage/TechNode3")
		and not panel.has_node("Overlay/PanelRoot/ToggleButton"),
		"科研UI必须原生包含十五项全局研究、四个材料槽、双页与三处技术节点，并且不能有开关。"
	)
	_expect(
		is_equal_approx(
			ResearchCenterPanel.get_pixel_perfect_panel_scale(
				Vector2(1920.0, 1080.0)
			),
			1.0
		)
		and is_equal_approx(
			ResearchCenterPanel.get_pixel_perfect_panel_scale(
				Vector2(2560.0, 1440.0)
			),
			2.0
		)
		and is_equal_approx(
			ResearchCenterPanel.get_pixel_perfect_panel_scale(
				Vector2(640.0, 480.0)
			),
			0.5
		),
		"科研UI必须只使用整数放大或整数倒数缩小，避免模糊且不能在小窗口裁切。"
	)
	if panel != null:
		var background := panel.get_node("Overlay/PanelRoot/Background") as TextureRect
		var title_label := panel.get_node(
			"Overlay/PanelRoot/Title"
		) as Label
		var global_page := panel.get_node(
			"Overlay/PanelRoot/GlobalPage"
		) as Control
		var player_page := panel.get_node(
			"Overlay/PanelRoot/PlayerPage"
		) as Control
		var global_tab := panel.get_node(
			"Overlay/PanelRoot/GlobalTab"
		) as Button
		var player_tab := panel.get_node(
			"Overlay/PanelRoot/PlayerTab"
		) as Button
		var tab_style := global_tab.get_theme_stylebox(
			&"normal"
		) as StyleBoxFlat
		var close_button := panel.get_node(
			"Overlay/PanelRoot/CloseButton"
		) as Button
		var research_list_frame := panel.get_node(
			"Overlay/PanelRoot/GlobalPage/ResearchListFrame"
		) as Panel
		var research_scroll := panel.get_node(
			"Overlay/PanelRoot/GlobalPage/ResearchListFrame/ResearchScroll"
		) as ScrollContainer
		var list_hint := panel.get_node(
			"Overlay/PanelRoot/GlobalPage/ResearchListFrame/ListHint"
		) as Label
		var research_detail_frame := panel.get_node(
			"Overlay/PanelRoot/GlobalPage/ResearchDetailFrame"
		) as Panel
		var status_label := panel.get_node(
			"Overlay/PanelRoot/StatusLabel"
		) as Label
		var action_button := panel.get_node(
			"Overlay/PanelRoot/ActionButton"
		) as Button
		_expect(
			background.texture != null
			and background.texture.get_size() == Vector2(728, 544),
			"科研UI必须使用独立生成的728×544蓝色科技背景。"
		)
		_expect(
			global_page.mouse_filter == Control.MOUSE_FILTER_IGNORE
			and player_page.mouse_filter == Control.MOUSE_FILTER_IGNORE
			and global_tab.z_index > global_page.z_index
			and player_tab.z_index > player_page.z_index
			and close_button.z_index > global_page.z_index,
			"科研UI内容页必须忽略自身空白区鼠标，页签与关闭键必须显式位于内容页上层。"
		)
		_expect(
			title_label.get_rect().is_equal_approx(
				Rect2(168.0, 15.0, 392.0, 46.0)
			)
			and global_tab.get_rect().is_equal_approx(
				Rect2(49.0, 76.0, 155.0, 38.0)
			)
			and player_tab.get_rect().is_equal_approx(
				Rect2(204.0, 76.0, 145.0, 38.0)
			)
			and is_equal_approx(
				global_tab.position.x + global_tab.size.x,
				player_tab.position.x
			)
			and close_button.get_rect().is_equal_approx(
				Rect2(666.0, 18.0, 40.0, 41.0)
			),
			"科研UI标题、双页签与关闭热区必须贴合背景原生槽位。"
		)
		_expect(
			tab_style != null
			and tab_style.corner_radius_top_left == 9
			and tab_style.corner_radius_top_right == 9
			and tab_style.corner_radius_bottom_left == 2
			and tab_style.corner_radius_bottom_right == 2,
			"科研UI页签上沿必须贴合背景槽斜角，下沿保持近似直角。"
		)
		_expect(
			research_list_frame.get_rect().is_equal_approx(
				Rect2(42.0, 129.0, 182.0, 321.0)
			)
			and research_scroll.get_rect().is_equal_approx(
				Rect2(8.0, 40.0, 166.0, 246.0)
			)
			and list_hint.get_rect().is_equal_approx(
				Rect2(12.0, 294.0, 156.0, 19.0)
			)
			and research_detail_frame.get_rect().is_equal_approx(
				Rect2(234.0, 129.0, 452.0, 321.0)
			),
			"科研UI主内容框与研究列表底部必须保留一致的背景呼吸空间。"
		)
		_expect(
			status_label.get_rect().is_equal_approx(
				Rect2(96.0, 474.0, 326.0, 32.0)
			)
			and action_button.get_rect().is_equal_approx(
				Rect2(469.0, 470.0, 165.0, 40.0)
			),
			"科研UI状态文字与动作按钮必须完整落入底部背景槽。"
		)


func _test_panel_mouse_navigation(
	panel: ResearchCenterPanel,
	center: ResearchCenter,
	player: Player
) -> void:
	panel.open_for(center, player)
	await process_frame
	await process_frame
	_expect(
		panel.is_open()
		and player.controls_locked
		and panel.active_page == ResearchCenterPanel.Page.GLOBAL_TECH
		and panel.global_page.visible
		and not panel.player_page.visible
		and panel.selected_global_research_id == BUILDING_DEFENSE_RESEARCH_ID
		and panel.defense_research_button.visible
		and not panel.defense_ii_research_button.visible
		and not panel.defense_iii_research_button.visible
		and not panel.material_slots[3].visible,
		"科研面板打开时必须默认选择建筑结构强化I、隐藏未解锁的II/III并锁定玩家控制。"
	)

	await _click_panel_control(panel.player_tab)
	_expect(
		root.gui_get_hovered_control() == panel.player_tab
		and panel.active_page == ResearchCenterPanel.Page.PLAYER_TECH
		and not panel.global_page.visible
		and panel.player_page.visible
		and panel.player_tab.button_pressed,
		"真实点击玩家技术页签必须命中按钮并切换到玩家技术页。"
	)

	await _click_panel_control(panel.global_tab)
	_expect(
		root.gui_get_hovered_control() == panel.global_tab
		and panel.active_page == ResearchCenterPanel.Page.GLOBAL_TECH
		and panel.global_page.visible
		and not panel.player_page.visible
		and panel.global_tab.button_pressed,
		"真实点击全局科技页签必须命中按钮并切回全局科技页。"
	)

	await _click_panel_control(panel.bamboo_mortar_research_button)
	_expect(
		root.gui_get_hovered_control() == panel.bamboo_mortar_research_button
		and panel.selected_global_research_id
		== BAMBOO_MORTAR_CRAFTING_RESEARCH_ID
		and panel.bamboo_mortar_research_button.button_pressed
		and panel.material_slots[0].visible
		and panel.material_slots[1].visible
		and not panel.material_slots[2].visible
		and not panel.material_slots[3].visible
		and panel.material_slots[0].position
		== ResearchCenterPanel.DOUBLE_MATERIAL_SLOT_POSITIONS[0]
		and panel.material_slots[1].position
		== ResearchCenterPanel.DOUBLE_MATERIAL_SLOT_POSITIONS[1]
		and panel.material_labels[0].position
		== Vector2(
			ResearchCenterPanel.DOUBLE_MATERIAL_SLOT_POSITIONS[0].x - 14.0,
			327.0
		)
		and panel.material_labels[1].position
		== Vector2(
			ResearchCenterPanel.DOUBLE_MATERIAL_SLOT_POSITIONS[1].x - 14.0,
			327.0
		),
		"选择迫击炮研发后必须使用居中的双材料槽布局，并保持第三槽隐藏。"
	)
	panel.global_research_scroll.ensure_control_visible(
		panel.orange_charging_tower_research_button
	)
	await process_frame
	await _click_panel_control(panel.orange_charging_tower_research_button)
	_expect(
		root.gui_get_hovered_control()
		== panel.orange_charging_tower_research_button
		and panel.selected_global_research_id
		== ORANGE_CHARGING_TOWER_CRAFTING_RESEARCH_ID
		and panel.orange_charging_tower_research_button.button_pressed
		and panel.material_slots[0].visible
		and panel.material_slots[1].visible
		and not panel.material_slots[2].visible
		and not panel.material_slots[3].visible
		and panel.material_slots[0].item == WOODEN_CORE
		and panel.material_slots[1].item == SAPLING,
		"滚动后点击橘充能塔研究必须选中独立项目，并展示与紫阳花相同的双材料需求。"
	)
	panel.global_research_scroll.ensure_control_visible(
		panel.vegetation_stake_spread_research_button
	)
	await process_frame
	await _click_panel_control(panel.vegetation_stake_spread_research_button)
	_expect(
		root.gui_get_hovered_control()
		== panel.vegetation_stake_spread_research_button
		and panel.selected_global_research_id
		== VEGETATION_STAKE_SPREAD_ENHANCEMENT_RESEARCH_ID
		and panel.vegetation_stake_spread_research_button.button_pressed
		and panel.material_slots[0].visible
		and panel.material_slots[1].visible
		and not panel.material_slots[2].visible
		and not panel.material_slots[3].visible
		and panel.material_slots[0].item == PLANK
		and panel.material_slots[1].item == WATER_BOTTLE,
		"滚动后点击植被桩蔓延增强必须选中独立项目，并展示20木板与5水瓶的双材料布局。"
	)
	panel.global_research_scroll.ensure_control_visible(
		panel.vegetation_enhancement_research_button
	)
	await process_frame
	await _click_panel_control(panel.vegetation_enhancement_research_button)
	_expect(
		root.gui_get_hovered_control()
		== panel.vegetation_enhancement_research_button
		and panel.selected_global_research_id
		== VEGETATION_ENHANCEMENT_RESEARCH_ID
		and panel.vegetation_enhancement_research_button.button_pressed
		and panel.material_slots[0].visible
		and panel.material_slots[1].visible
		and panel.material_slots[2].visible
		and not panel.material_slots[3].visible
		and panel.material_slots[0].item == WHITE_CRYSTAL_POWDER
		and panel.material_slots[1].item == WATER_BOTTLE
		and panel.material_slots[2].item == SAPLING,
		"滚动后点击植被强化必须选中独立项目，并按顺序展示白色水晶粉末、水瓶和树苗。"
	)
	panel.global_research_scroll.ensure_control_visible(
		panel.water_collection_rate_research_button
	)
	await process_frame
	await _click_panel_control(panel.water_collection_rate_research_button)
	_expect(
		root.gui_get_hovered_control()
		== panel.water_collection_rate_research_button
		and panel.selected_global_research_id
		== WATER_COLLECTION_RATE_ENHANCEMENT_RESEARCH_ID
		and panel.water_collection_rate_research_button.button_pressed
		and panel.material_slots[0].visible
		and panel.material_slots[1].visible
		and panel.material_slots[2].visible
		and not panel.material_slots[3].visible
		and panel.material_slots[0].item == WHITE_CRYSTAL_POWDER
		and panel.material_slots[1].item == WATER_BOTTLE
		and panel.material_slots[2].item == PLANK,
		"滚动后点击采水速率提升必须按顺序展示白色水晶粉末、水瓶和木板。"
	)
	panel.global_research_scroll.ensure_control_visible(
		panel.fence_reinforcement_research_button
	)
	await process_frame
	await _click_panel_control(panel.fence_reinforcement_research_button)
	_expect(
		root.gui_get_hovered_control()
		== panel.fence_reinforcement_research_button
		and panel.selected_global_research_id
		== FENCE_REINFORCEMENT_RESEARCH_ID
		and panel.fence_reinforcement_research_button.button_pressed
		and panel.material_slots[0].visible
		and panel.material_slots[1].visible
		and not panel.material_slots[2].visible
		and not panel.material_slots[3].visible
		and panel.material_slots[0].item == PLANK
		and panel.material_slots[1].item == SAPLING
		and panel.global_result_badge.text == "生命 +1000\n物防 +5",
		"滚动后点击围栏强化必须展示100木板、100树苗与两项强化结果。"
	)

	await _click_panel_control(panel.close_button)
	_expect(
		not panel.is_open()
		and not panel.visible
		and not player.controls_locked,
		"真实点击右上关闭键必须关闭科研面板并恢复玩家控制。"
	)
	panel.open_for(center, player)
	player.died.emit()
	_expect(
		not panel.is_open()
		and not player.has_control_lock(ResearchCenterPanel.CONTROL_LOCK_OWNER),
		"玩家死亡时科研面板必须关闭并只释放自己的控制锁 owner。"
	)


func _test_tower_specific_research_projection(test_root: Node) -> void:
	var production := (
		PRODUCTION_COORDINATOR_SCENE.instantiate() as ProductionCoordinator
	)
	var research := RESEARCH_COORDINATOR_SCENE.instantiate() as ResearchCoordinator
	var plant_system := PlantSystem.new()
	var bamboo_combat := BambooMortarCombatSystem.new()
	var warehouse := WAREHOUSE_SCENE.instantiate() as OakWarehouse
	var owner := WEISHIDAIER_SCENE.instantiate() as Player
	for node in [
		production,
		research,
		plant_system,
		bamboo_combat,
		warehouse,
		owner,
	]:
		test_root.add_child(node)
	await process_frame
	production.production_tick_timer.stop()
	owner.peer_id = 61
	warehouse.setup(
		PlantDefenseRegistry.get_config(PlantDefenseRegistry.OAK_WAREHOUSE_ID),
		owner,
		[Vector2i.ZERO]
	)
	production.register_plant(warehouse)

	var agave := _create_research_projection_tower(
		PlantDefenseRegistry.AGAVE_CANNON_ID,
		owner,
		Vector2i(2, 0),
		test_root
	) as AgaveCannon
	var corn := _create_research_projection_tower(
		PlantDefenseRegistry.CORN_MACHINE_GUN_ID,
		owner,
		Vector2i(4, 0),
		test_root
	) as CornMachineGun
	var grape := _create_research_projection_tower(
		PlantDefenseRegistry.GRAPE_ARC_TOWER_ID,
		owner,
		Vector2i(6, 0),
		test_root
	) as GrapeArcTower
	for tower in [agave, corn, grape]:
		plant_system.plant_footprints[tower] = tower.footprint_cells.duplicate()
	research.setup(production, plant_system, null, bamboo_combat)
	research.research_tick_timer.stop()

	_expect(
		research.is_global_research_unlocked(
			AGAVE_CANNON_MUZZLE_IMPROVEMENT_RESEARCH_ID
		)
		and research.is_global_research_unlocked(
			CORN_MACHINE_GUN_COOLING_SYSTEM_IMPROVEMENT_RESEARCH_ID
		)
		and research.is_global_research_unlocked(
			BAMBOO_MORTAR_CONCUSSIVE_MODIFICATION_RESEARCH_ID
		)
		and research.is_global_research_unlocked(
			GRAPE_ARC_TOWER_SURGE_MODIFICATION_RESEARCH_ID
		),
		"四项塔专属科研必须无前置并在新局初始可用。"
	)

	_expect(
		warehouse.try_add_storage_item_count(PLANK, 50)
		and warehouse.try_add_storage_item_count(WATER_BOTTLE, 50)
		and research.try_start_global_research(
			AGAVE_CANNON_MUZZLE_IMPROVEMENT_RESEARCH_ID
		) == ResearchCoordinator.RESULT_SUCCESS
		and production.get_total_item_count(PLANK) == 0
		and production.get_total_item_count(WATER_BOTTLE) == 0,
		"加农炮科研必须原子扣除50木板与50水瓶。"
	)
	research.advance_global_research(40.0)
	_expect(
		research.get_agave_cannon_attack_damage_bonus() == 10
		and plant_system.get_global_agave_cannon_attack_damage_bonus() == 10
		and agave.get_research_attack_damage_bonus() == 10
		and agave.configured_attack_damage == 30,
		"加农炮科研完成后必须把既有龙舌兰伤害从20绝对投影为30。"
	)

	_expect(
		warehouse.try_add_storage_item_count(PLANK, 50)
		and warehouse.try_add_storage_item_count(WATER_BOTTLE, 50)
		and research.try_start_global_research(
			CORN_MACHINE_GUN_COOLING_SYSTEM_IMPROVEMENT_RESEARCH_ID
		) == ResearchCoordinator.RESULT_SUCCESS,
		"机枪塔科研必须能用50木板与50水瓶启动。"
	)
	research.advance_global_research(40.0)
	_expect(
		research.get_corn_machine_gun_burst_count_bonus() == 2
		and plant_system.get_global_corn_machine_gun_burst_shot_count_bonus() == 2
		and corn.get_research_burst_shot_count_bonus() == 2
		and corn.configured_burst_count == 8,
		"机枪塔科研完成后必须把既有玉米塔下一轮射击数绝对投影为8。"
	)

	_expect(
		warehouse.try_add_storage_item_count(PLANK, 80)
		and warehouse.try_add_storage_item_count(WATER_BOTTLE, 50)
		and research.try_start_global_research(
			BAMBOO_MORTAR_CONCUSSIVE_MODIFICATION_RESEARCH_ID
		) == ResearchCoordinator.RESULT_SUCCESS,
		"迫击炮震爆科研必须能用80木板与50水瓶启动。"
	)
	research.advance_global_research(40.0)
	_expect(
		is_equal_approx(research.get_bamboo_mortar_slow_ratio(), 0.25)
		and is_equal_approx(
			research.get_bamboo_mortar_slow_duration_seconds(),
			3.0
		)
		and is_equal_approx(
			bamboo_combat.get_research_concussion_move_speed_multiplier(),
			0.75
		)
		and is_equal_approx(
			bamboo_combat.get_research_concussion_duration_seconds(),
			3.0
		),
		"震爆科研必须把25%减速、3秒时长投射为迫击炮中央结算参数。"
	)

	_expect(
		warehouse.try_add_storage_item_count(PLANK, 50)
		and warehouse.try_add_storage_item_count(WATER_BOTTLE, 100)
		and warehouse.try_add_storage_item_count(DIRT_BLOCK, 99),
		"电弧科研原子事务夹具必须能准备仅缺1土块的材料。"
	)
	var before_missing_grape := {
		"plank": production.get_total_item_count(PLANK),
		"water": production.get_total_item_count(WATER_BOTTLE),
		"dirt": production.get_total_item_count(DIRT_BLOCK),
	}
	_expect(
		research.try_start_global_research(
			GRAPE_ARC_TOWER_SURGE_MODIFICATION_RESEARCH_ID
		) == ResearchCoordinator.RESULT_MISSING_INPUT
		and production.get_total_item_count(PLANK)
		== int(before_missing_grape["plank"])
		and production.get_total_item_count(WATER_BOTTLE)
		== int(before_missing_grape["water"])
		and production.get_total_item_count(DIRT_BLOCK)
		== int(before_missing_grape["dirt"]),
		"电弧科研任一材料不足时不得预扣其余三项投入。"
	)
	_expect(
		warehouse.try_add_storage_item_count(DIRT_BLOCK, 1)
		and research.try_start_global_research(
			GRAPE_ARC_TOWER_SURGE_MODIFICATION_RESEARCH_ID
		) == ResearchCoordinator.RESULT_SUCCESS
		and production.get_total_item_count(PLANK) == 0
		and production.get_total_item_count(WATER_BOTTLE) == 0
		and production.get_total_item_count(DIRT_BLOCK) == 0,
		"电弧科研材料齐备时必须一次性扣除50木板、100水瓶与100土块。"
	)
	research.advance_global_research(60.0)
	_expect(
		is_equal_approx(
			research.get_grape_electromagnetic_duration_seconds(),
			10.0
		)
		and is_equal_approx(
			research.get_grape_electromagnetic_damage_multiplier(),
			1.5
		)
		and is_equal_approx(
			plant_system.get_global_grape_electromagnetic_attachment_duration_seconds(),
			10.0
		)
		and is_equal_approx(
			plant_system.get_global_grape_electromagnetic_damage_multiplier(),
			1.5
		)
		and is_equal_approx(
			grape.get_research_electromagnetic_attachment_duration_seconds(),
			10.0
		)
		and is_equal_approx(
			grape.get_research_electromagnetic_damage_multiplier(),
			1.5
		),
		"电弧科研必须向既有葡萄塔投射10秒电磁附着与1.5倍条件伤害。"
	)

	var late_agave := _create_research_projection_tower(
		PlantDefenseRegistry.AGAVE_CANNON_ID,
		owner,
		Vector2i(8, 0),
		test_root
	) as AgaveCannon
	var late_corn := _create_research_projection_tower(
		PlantDefenseRegistry.CORN_MACHINE_GUN_ID,
		owner,
		Vector2i(10, 0),
		test_root
	) as CornMachineGun
	var late_grape := _create_research_projection_tower(
		PlantDefenseRegistry.GRAPE_ARC_TOWER_ID,
		owner,
		Vector2i(12, 0),
		test_root
	) as GrapeArcTower
	for tower in [late_agave, late_corn, late_grape]:
		plant_system.call("_apply_research_stat_bonuses", tower)
	_expect(
		late_agave.configured_attack_damage == 30
		and late_corn.configured_burst_count == 8
		and is_equal_approx(
			late_grape.get_research_electromagnetic_attachment_duration_seconds(),
			10.0
		)
		and is_equal_approx(
			late_grape.get_research_electromagnetic_damage_multiplier(),
			1.5
		),
		"完成科研后新建的三类塔必须从基础配置得到同一绝对效果投影。"
	)

	var remote_research := RESEARCH_COORDINATOR_SCENE.instantiate() as ResearchCoordinator
	var remote_plant_system := PlantSystem.new()
	var remote_bamboo_combat := BambooMortarCombatSystem.new()
	for node in [remote_research, remote_plant_system, remote_bamboo_combat]:
		test_root.add_child(node)
	await process_frame
	remote_research.research_tick_timer.stop()
	remote_research.setup(null, remote_plant_system, null, remote_bamboo_combat)
	remote_research.set_authoritative_processing_enabled(false)
	var snapshot := research.export_runtime_state()
	_expect(
		remote_research.apply_multiplayer_runtime_state(snapshot)
		and remote_plant_system.get_global_agave_cannon_attack_damage_bonus() == 10
		and remote_plant_system.get_global_corn_machine_gun_burst_shot_count_bonus() == 2
		and is_equal_approx(
			remote_bamboo_combat.get_research_concussion_move_speed_multiplier(),
			0.75
		)
		and is_equal_approx(
			remote_plant_system.get_global_grape_electromagnetic_damage_multiplier(),
			1.5
		),
		"15项schema3快照必须在远端幂等恢复四项塔专属科研投影。"
	)
	var replay := snapshot.duplicate(true)
	replay["revision"] = int(snapshot["revision"]) + 1
	_expect(
		remote_research.apply_multiplayer_runtime_state(replay)
		and remote_plant_system.get_global_agave_cannon_attack_damage_bonus() == 10
		and remote_plant_system.get_global_corn_machine_gun_burst_shot_count_bonus() == 2
		and is_equal_approx(
			remote_plant_system.get_global_grape_electromagnetic_damage_multiplier(),
			1.5
		),
		"重复发布同一完成态的更高revision快照不得重复叠加塔科研。"
	)


func _create_research_projection_tower(
	tower_id: StringName,
	owner: Player,
	anchor: Vector2i,
	test_root: Node
) -> PlantDefense:
	var config := PlantDefenseRegistry.get_config(tower_id)
	var tower := config.plant_scene.instantiate() as PlantDefense
	test_root.add_child(tower)
	tower.setup(config, owner, [anchor])
	tower.set_process(false)
	tower.set_physics_process(false)
	return tower


func _test_building_defense_research_chain(
	test_root: Node,
	center_config: PlantDefenseConfig
) -> void:
	var chain_production := (
		PRODUCTION_COORDINATOR_SCENE.instantiate() as ProductionCoordinator
	)
	var chain_research := (
		RESEARCH_COORDINATOR_SCENE.instantiate() as ResearchCoordinator
	)
	var chain_warehouse := WAREHOUSE_SCENE.instantiate() as OakWarehouse
	var chain_plant_system := PlantSystem.new()
	var chain_panel := PANEL_SCENE.instantiate() as ResearchCenterPanel
	var chain_player := WEISHIDAIER_SCENE.instantiate() as Player
	var chain_center := (
		center_config.plant_scene.instantiate() as ResearchCenter
		if center_config != null
		else null
	)
	for node in [
		chain_production,
		chain_research,
		chain_warehouse,
		chain_plant_system,
		chain_panel,
		chain_player,
		chain_center,
	]:
		if node != null:
			test_root.add_child(node)
	await process_frame
	if chain_center == null:
		_expect(false, "三级建筑结构强化隔离测试必须能实例化科研中心。")
		return
	chain_production.production_tick_timer.stop()
	chain_research.research_tick_timer.stop()
	chain_player.peer_id = 21
	var warehouse_config := PlantDefenseRegistry.get_config(&"oak_warehouse")
	chain_warehouse.setup(warehouse_config, chain_player, [Vector2i(20, 20)])
	chain_center.setup(
		center_config,
		chain_player,
		[
			Vector2i(22, 20),
			Vector2i(23, 20),
			Vector2i(22, 21),
			Vector2i(23, 21),
		]
	)
	chain_production.register_plant(chain_warehouse)
	chain_research.setup(chain_production, chain_plant_system, null)
	chain_center.set_research_services(chain_research, chain_panel)
	chain_plant_system.plant_footprints[chain_center] = (
		chain_center.footprint_cells.duplicate()
	)

	_expect(
		chain_warehouse.try_add_storage_item_count(PLANK, 180)
		and chain_warehouse.try_add_storage_item_count(SAPLING, 50)
		and chain_warehouse.try_add_storage_item_count(WATER_BOTTLE, 200)
		and chain_warehouse.try_add_storage_item_count(DIRT_BLOCK, 100)
		and chain_warehouse.try_add_storage_item_count(
			WHITE_CRYSTAL_POWDER,
			9
		),
		"三级建筑结构强化隔离测试必须能准备除最后1份白色水晶粉外的全部材料。"
	)
	chain_panel.open_for(chain_center, chain_player)
	await process_frame
	_expect(
		chain_panel.selected_global_research_id
		== BUILDING_DEFENSE_RESEARCH_ID
		and chain_panel.defense_research_button.visible
		and not chain_panel.defense_ii_research_button.visible
		and not chain_panel.defense_iii_research_button.visible,
		"初始打开科研面板必须默认选中I，并实时隐藏前置未完成的II与III。"
	)

	var totals_before_skip := {
		PLANK: chain_production.get_total_item_count(PLANK),
		SAPLING: chain_production.get_total_item_count(SAPLING),
		WATER_BOTTLE: chain_production.get_total_item_count(WATER_BOTTLE),
		DIRT_BLOCK: chain_production.get_total_item_count(DIRT_BLOCK),
		WHITE_CRYSTAL_POWDER: chain_production.get_total_item_count(
			WHITE_CRYSTAL_POWDER
		),
	}
	_expect(
		chain_center.try_start_global_research(
			BUILDING_DEFENSE_II_RESEARCH_ID
		) == ResearchCoordinator.RESULT_UNAVAILABLE
		and chain_center.try_start_global_research(
			BUILDING_DEFENSE_III_RESEARCH_ID
		) == ResearchCoordinator.RESULT_UNAVAILABLE
		and _research_material_totals_match(
			chain_production,
			totals_before_skip
		),
		"完成I之前直接或伪造请求II/III必须在扣料前拒绝，且共享仓库完全不变。"
	)

	_expect(
		chain_center.try_start_global_research(BUILDING_DEFENSE_RESEARCH_ID)
		== ResearchCoordinator.RESULT_SUCCESS
		and chain_production.get_total_item_count(PLANK) == 150
		and chain_production.get_total_item_count(SAPLING) == 30
		and chain_production.get_total_item_count(WATER_BOTTLE) == 150,
		"建筑结构强化I必须原子扣除30木板、20树苗和50水瓶。"
	)
	chain_research.advance_global_research(40.0)
	_expect(
		chain_plant_system.get_global_physical_defense_bonus() == 5
		and chain_center.get_effective_physical_defense() == 10
		and chain_research.is_global_research_unlocked(
			BUILDING_DEFENSE_II_RESEARCH_ID
		)
		and not chain_research.is_global_research_unlocked(
			BUILDING_DEFENSE_III_RESEARCH_ID
		)
		and chain_panel.selected_global_research_id
		== BUILDING_DEFENSE_RESEARCH_ID
		and chain_panel.defense_ii_research_button.visible
		and not chain_panel.defense_iii_research_button.visible
		and chain_panel.defense_research_button.text.contains("已完成"),
		"I完成后必须累计物防+5、仅显示II，并保持当前选择在I。"
	)

	totals_before_skip = {
		PLANK: chain_production.get_total_item_count(PLANK),
		SAPLING: chain_production.get_total_item_count(SAPLING),
		WATER_BOTTLE: chain_production.get_total_item_count(WATER_BOTTLE),
		DIRT_BLOCK: chain_production.get_total_item_count(DIRT_BLOCK),
		WHITE_CRYSTAL_POWDER: chain_production.get_total_item_count(
			WHITE_CRYSTAL_POWDER
		),
	}
	_expect(
		chain_center.try_start_global_research(
			BUILDING_DEFENSE_III_RESEARCH_ID
		) == ResearchCoordinator.RESULT_UNAVAILABLE
		and _research_material_totals_match(
			chain_production,
			totals_before_skip
		),
		"I完成但II未完成时越级请求III仍必须在扣料前拒绝。"
	)
	_expect(
		chain_center.try_start_global_research(
			BUILDING_DEFENSE_II_RESEARCH_ID
		) == ResearchCoordinator.RESULT_SUCCESS
		and chain_production.get_total_item_count(PLANK) == 100
		and chain_production.get_total_item_count(SAPLING) == 0
		and chain_production.get_total_item_count(WATER_BOTTLE) == 100,
		"建筑结构强化II必须原子扣除50木板、30树苗和50水瓶。"
	)
	chain_research.advance_global_research(50.0)
	_expect(
		chain_plant_system.get_global_physical_defense_bonus() == 10
		and chain_center.get_effective_physical_defense() == 15
		and chain_research.is_global_research_unlocked(
			BUILDING_DEFENSE_III_RESEARCH_ID
		)
		and chain_panel.selected_global_research_id
		== BUILDING_DEFENSE_RESEARCH_ID
		and chain_panel.defense_ii_research_button.visible
		and chain_panel.defense_iii_research_button.visible
		and chain_panel.defense_ii_research_button.text.contains("已完成"),
		"II完成后必须累计物防+10、显示III，并且新等级出现时不能自动切换选择。"
	)

	chain_panel.call(
		"_select_global_research",
		BUILDING_DEFENSE_III_RESEARCH_ID
	)
	await process_frame
	var result_badge_rect := chain_panel.global_result_badge.get_rect()
	var four_material_layout_valid := true
	for index in chain_panel.material_slots.size():
		var material_label := chain_panel.material_labels[index]
		four_material_layout_valid = (
			four_material_layout_valid
			and chain_panel.material_slots[index].visible
			and material_label.visible
			and chain_panel.material_slots[index].position
			== ResearchCenterPanel.FOUR_MATERIAL_SLOT_POSITIONS[index]
			and is_equal_approx(
				material_label.size.x,
				ResearchCenterPanel.FOUR_MATERIAL_LABEL_SIZE.x
			)
			and material_label.size.y
			>= ResearchCenterPanel.FOUR_MATERIAL_LABEL_SIZE.y
			and not material_label.get_rect().intersects(result_badge_rect)
		)
	_expect(
		chain_panel.selected_global_research_id
		== BUILDING_DEFENSE_III_RESEARCH_ID
		and four_material_layout_valid
		and chain_panel.material_slots[0].item == PLANK
		and chain_panel.material_slots[1].item == WATER_BOTTLE
		and chain_panel.material_slots[2].item == DIRT_BLOCK
		and chain_panel.material_slots[3].item == WHITE_CRYSTAL_POWDER
		and chain_panel.material_labels[3].text == "白色水晶粉\n9 / 10"
		and chain_panel.material_labels[3].get_line_count() == 2
		and chain_panel.material_labels[3].get_minimum_size().x
		<= chain_panel.material_labels[3].size.x
		and chain_panel.material_labels[3].get_minimum_size().y
		<= chain_panel.material_labels[3].size.y
		and chain_panel.global_result_badge.text == "全建筑物防\n+5",
		(
			"III详情必须原生展示四个紧凑单行材料槽，白色水晶粉以两行完整显示且不得侵入成果徽章。"
			+ "（layout=%s，text=%s，lines=%d，min=%s，size=%s，badge=%s）"
		) % [
			str(four_material_layout_valid),
			chain_panel.material_labels[3].text,
			chain_panel.material_labels[3].get_line_count(),
			str(chain_panel.material_labels[3].get_minimum_size()),
			str(chain_panel.material_labels[3].size),
			chain_panel.global_result_badge.text,
		]
	)

	var iii_materials_before_missing := {
		PLANK: 100,
		WATER_BOTTLE: 100,
		DIRT_BLOCK: 100,
		WHITE_CRYSTAL_POWDER: 9,
	}
	_expect(
		chain_center.try_start_global_research(
			BUILDING_DEFENSE_III_RESEARCH_ID
		) == ResearchCoordinator.RESULT_MISSING_INPUT
		and _research_material_totals_match(
			chain_production,
			iii_materials_before_missing
		),
		"III缺少任一份白色水晶粉时四种材料必须全部保持不变。"
	)
	_expect(
		chain_warehouse.try_add_storage_item_count(WHITE_CRYSTAL_POWDER, 1)
		and chain_center.try_start_global_research(
			BUILDING_DEFENSE_III_RESEARCH_ID
		) == ResearchCoordinator.RESULT_SUCCESS
		and chain_production.get_total_item_count(PLANK) == 0
		and chain_production.get_total_item_count(WATER_BOTTLE) == 0
		and chain_production.get_total_item_count(DIRT_BLOCK) == 0
		and chain_production.get_total_item_count(WHITE_CRYSTAL_POWDER) == 0,
		"III材料齐全时必须一次原子扣除100木板、100水瓶、100土块和10白色水晶粉。"
	)
	chain_research.advance_global_research(70.0)
	_expect(
		chain_research.get_completed_global_research_ids() == [
			BUILDING_DEFENSE_RESEARCH_ID,
			BUILDING_DEFENSE_II_RESEARCH_ID,
			BUILDING_DEFENSE_III_RESEARCH_ID,
		]
		and chain_plant_system.get_global_physical_defense_bonus() == 15
		and chain_center.get_effective_physical_defense() == 20
		and chain_panel.defense_research_button.visible
		and chain_panel.defense_ii_research_button.visible
		and chain_panel.defense_iii_research_button.visible
		and chain_panel.defense_iii_research_button.text.contains("已完成"),
		"I/II/III完成后必须按注册顺序保留全部完成项并累计全建筑物防+15。"
	)

	var remote_research := (
		RESEARCH_COORDINATOR_SCENE.instantiate() as ResearchCoordinator
	)
	var remote_plant_system := PlantSystem.new()
	test_root.add_child(remote_research)
	test_root.add_child(remote_plant_system)
	await process_frame
	remote_research.research_tick_timer.stop()
	remote_research.setup(null, remote_plant_system, null)
	remote_research.set_authoritative_processing_enabled(false)
	var chain_snapshot := chain_research.export_runtime_state()
	remote_research.apply_multiplayer_runtime_state(chain_snapshot)
	_expect(
		int(chain_snapshot.get("schema", 0)) == 3
		and (chain_snapshot["global_states"] as Dictionary).size() == 15
		and (chain_snapshot["global_elapsed"] as Dictionary).size() == 15
		and remote_research.get_completed_global_research_ids() == [
			BUILDING_DEFENSE_RESEARCH_ID,
			BUILDING_DEFENSE_II_RESEARCH_ID,
			BUILDING_DEFENSE_III_RESEARCH_ID,
		]
		and remote_plant_system.get_global_physical_defense_bonus() == 15,
		"schema3远端快照必须完整携带15项科研，并把三级累计物防+15投射到客户端。"
	)
	var accepted_remote_revision := remote_research.research_revision
	var invalid_chain_snapshot := chain_snapshot.duplicate(true)
	invalid_chain_snapshot["revision"] = accepted_remote_revision + 1
	var invalid_chain_states := (
		invalid_chain_snapshot["global_states"] as Dictionary
	)
	var invalid_chain_elapsed := (
		invalid_chain_snapshot["global_elapsed"] as Dictionary
	)
	invalid_chain_states[String(BUILDING_DEFENSE_II_RESEARCH_ID)] = (
		ResearchCoordinator.GlobalResearchState.AVAILABLE
	)
	invalid_chain_elapsed[String(BUILDING_DEFENSE_II_RESEARCH_ID)] = 0.0
	remote_research.apply_multiplayer_runtime_state(invalid_chain_snapshot)
	_expect(
		remote_research.research_revision == accepted_remote_revision
		and remote_research.get_completed_global_research_ids() == [
			BUILDING_DEFENSE_RESEARCH_ID,
			BUILDING_DEFENSE_II_RESEARCH_ID,
			BUILDING_DEFENSE_III_RESEARCH_ID,
		]
		and remote_plant_system.get_global_physical_defense_bonus() == 15,
		"远端必须拒绝II未完成但III已完成的非法前置链快照，且不能污染已接受状态。"
	)
	var late_center := center_config.plant_scene.instantiate() as ResearchCenter
	var fence_config := PlantDefenseRegistry.get_config(&"simple_fence")
	var late_fence := (
		fence_config.plant_scene.instantiate() as PlantDefense
		if fence_config != null
		else null
	)
	if late_center != null:
		test_root.add_child(late_center)
	if late_fence != null:
		test_root.add_child(late_fence)
	await process_frame
	if late_center != null:
		late_center.setup(
			center_config,
			chain_player,
			[
				Vector2i(30, 20),
				Vector2i(31, 20),
				Vector2i(30, 21),
				Vector2i(31, 21),
			]
		)
		chain_plant_system.plant_footprints[late_center] = (
			late_center.footprint_cells.duplicate()
		)
		chain_plant_system.call("_apply_research_stat_bonuses", late_center)
	if late_fence != null:
		late_fence.setup(fence_config, chain_player, [Vector2i(32, 20)])
		chain_plant_system.plant_footprints[late_fence] = (
			late_fence.footprint_cells.duplicate()
		)
		chain_plant_system.call("_apply_research_stat_bonuses", late_fence)
	chain_plant_system.set_global_fence_physical_defense_bonus(5)
	_expect(
		late_center != null
		and late_fence != null
		and late_center.get_effective_physical_defense()
		== center_config.physical_defense + 15
		and late_fence.get_effective_physical_defense()
		== fence_config.physical_defense + 20
		and chain_center.get_effective_physical_defense()
		== center_config.physical_defense + 15,
		"三级+15必须覆盖现有与后建建筑，围栏专属+5还要在全局加成基础上继续叠加。"
	)
	chain_panel.close()
	_expect(not chain_player.controls_locked, "三级科研链测试关闭面板后必须释放玩家控制。")


func _research_material_totals_match(
	production: ProductionCoordinator,
	expected_totals: Dictionary
) -> bool:
	for item_variant in expected_totals:
		var item := item_variant as PickupConfig
		if (
			item == null
			or production.get_total_item_count(item)
			!= int(expected_totals[item_variant])
		):
			return false
	return true


func _click_panel_control(control: Control) -> void:
	var position := control.get_global_rect().get_center()
	var motion := InputEventMouseMotion.new()
	motion.position = position
	motion.global_position = position
	root.push_input(motion, true)
	await process_frame

	var press := InputEventMouseButton.new()
	press.position = position
	press.global_position = position
	press.button_index = MOUSE_BUTTON_LEFT
	press.button_mask = MOUSE_BUTTON_MASK_LEFT
	press.pressed = true
	root.push_input(press, true)
	await process_frame

	var release := InputEventMouseButton.new()
	release.position = position
	release.global_position = position
	release.button_index = MOUSE_BUTTON_LEFT
	release.button_mask = 0
	release.pressed = false
	root.push_input(release, true)
	await process_frame


func _test_operational_night_visuals(
	center: ResearchCenter,
	day_night: DayNightController
) -> void:
	var hotspot_glow := center.get_node_or_null(
		"HotspotGlow"
	) as NightPointLight2D
	_expect(
		hotspot_glow != null
		and center.is_operational
		and day_night.is_night()
		and hotspot_glow.visible
		and hotspot_glow.is_visible_in_tree()
		and hotspot_glow.is_emission_allowed()
		and hotspot_glow.enabled
		and is_equal_approx(hotspot_glow.energy, 0.72),
		"科研中心完成建造后，三处淡蓝热点必须在黑夜立即启用额定微光。"
	)
	day_night.set_night_factor_immediate(0.0)
	_expect(
		hotspot_glow != null
		and not hotspot_glow.enabled
		and is_zero_approx(hotspot_glow.energy),
		"科研中心三处热点必须在白昼关闭真实灯光，不能常驻耗费灯光预算。"
	)
	day_night.set_night_factor_immediate(1.0)
	_expect(
		hotspot_glow != null
		and hotspot_glow.enabled
		and is_equal_approx(hotspot_glow.energy, 0.72),
		"科研中心三处热点必须能随昼夜控制器重新进入淡蓝夜间微光态。"
	)
	var research_border := center.get_node_or_null(
		"ResearchBorder"
	) as MeshInstance2D
	center.call("_on_construction_started")
	_expect(
		research_border != null
		and not research_border.visible
		and hotspot_glow != null
		and not hotspot_glow.is_emission_allowed()
		and not hotspot_glow.enabled
		and is_zero_approx(hotspot_glow.energy),
		"科研中心建造过程中必须同时隐藏科研外框并关闭三热点灯。"
	)
	center.call("_on_construction_finished", false)
	_expect(
		research_border != null
		and research_border.visible
		and is_equal_approx(research_border.modulate.a, 1.0)
		and hotspot_glow != null
		and hotspot_glow.is_emission_allowed()
		and hotspot_glow.enabled
		and is_equal_approx(hotspot_glow.energy, 0.72),
		"科研中心建造完成后必须恢复科研外框与三热点夜间微光。"
	)


func _expect_research_border_state(
	center: ResearchCenter,
	expected_working: bool,
	expected_progress: float,
	message: String
) -> void:
	var research_border := center.get_node_or_null(
		"ResearchBorder"
	) as MeshInstance2D
	if research_border == null:
		_expect(false, message)
		return
	var actual_working := bool(
		research_border.get_instance_shader_parameter(&"working_active")
	)
	var actual_progress := float(
		research_border.get_instance_shader_parameter(&"progress_value")
	)
	_expect(
		actual_working == expected_working
		and absf(actual_progress - expected_progress) <= 0.0001,
		"%s（working=%s，progress=%.4f）" % [
			message,
			str(actual_working),
			actual_progress,
		]
	)


func _test_research_border_event_step(center: ResearchCenter) -> void:
	var research_border := center.get_node_or_null(
		"ResearchBorder"
	) as MeshInstance2D
	if research_border == null:
		_expect(false, "科研外框事件步进测试必须找到ResearchBorder节点。")
		return
	var progress_anchor := float(
		research_border.get_instance_shader_parameter(&"progress_value")
	)
	await create_timer(0.05).timeout
	var progress_after_time := float(
		research_border.get_instance_shader_parameter(&"progress_value")
	)
	_expect(
		absf(progress_after_time - progress_anchor) <= 0.000001,
		"没有权威研究事件时外框进度必须保持不变，不能保留逐帧CPU Tween。"
	)


func _test_global_move_speed_research(
	research: ResearchCoordinator,
	center: ResearchCenter,
	production: ProductionCoordinator,
	warehouse: OakWarehouse,
	second_warehouse: OakWarehouse,
	plant_system: PlantSystem,
	players: Array,
	test_root: Node
) -> void:
	var speeds_before: Dictionary = {}
	for player_variant in players:
		var player := player_variant as Player
		speeds_before[player.get_instance_id()] = player.move_speed

	_expect(
		warehouse.try_add_storage_item_count(WATER_BOTTLE, 44),
		"移动研究测试必须能把共享水瓶补到49个。"
	)
	_expect(
		production.get_total_item_count(WATER_BOTTLE) == 49
		and center.try_start_global_research(PLAYER_MOVE_SPEED_RESEARCH_ID)
		== ResearchCoordinator.RESULT_MISSING_INPUT
		and production.get_total_item_count(WATER_BOTTLE) == 49,
		"全员移动训练缺少第50个水瓶时必须原子失败且不得扣料。"
	)
	_expect(
		second_warehouse.try_add_storage_item_count(WATER_BOTTLE, 1),
		"移动研究测试必须能补入最后1个水瓶。"
	)
	_expect(
		center.try_start_global_research(PLAYER_MOVE_SPEED_RESEARCH_ID)
		== ResearchCoordinator.RESULT_SUCCESS
		and production.get_total_item_count(WATER_BOTTLE) == 0,
		"全员移动训练开始时必须一次且仅一次扣除50个水瓶。"
	)
	research.advance_global_research(59.0)
	for player_variant in players:
		var player := player_variant as Player
		_expect(
			is_equal_approx(
				player.move_speed,
				float(speeds_before[player.get_instance_id()])
			),
			"全员移动训练未满60秒时不得提前增加玩家移速。"
		)
	research.advance_global_research(1.0)
	_expect(
		research.get_global_research_state(PLAYER_MOVE_SPEED_RESEARCH_ID)
		== ResearchCoordinator.GlobalResearchState.COMPLETED
		and research.get_active_global_research_id().is_empty()
		and plant_system.get_global_physical_defense_bonus() == 5,
		"移动研究完成后必须保留已完成的建筑防御研究，并清空研究队列。"
	)
	for player_variant in players:
		var player := player_variant as Player
		var expected_speed := (
			float(speeds_before[player.get_instance_id()])
			+ _get_expected_global_move_speed_bonus()
		)
		_expect(
			is_equal_approx(player.move_speed, expected_speed),
			"移动研究完成后必须给每个已注册玩家增加15点移速。"
		)
		player.call("_refresh_collectible_stats", false)
		_expect(
			is_equal_approx(player.move_speed, expected_speed),
			"收藏品属性刷新后必须保留科研提供的15点移速。"
		)
	_expect(
		center.try_start_global_research(PLAYER_MOVE_SPEED_RESEARCH_ID)
		== ResearchCoordinator.RESULT_COMPLETED,
		"全员移动训练完成后不得重复扣水瓶或重复叠加。"
	)

	var late_player := WEISHIDAIER_SCENE.instantiate() as Player
	test_root.add_child(late_player)
	await process_frame
	late_player.peer_id = 5
	var late_base_speed := late_player.move_speed
	research.register_player(late_player)
	_expect(
		is_equal_approx(
			late_player.move_speed,
			late_base_speed + _get_expected_global_move_speed_bonus()
		),
		"移动研究完成后注册的新玩家必须立即获得15点移速。"
	)

func _test_recipe_unlock_research(
	research: ResearchCoordinator,
	center: ResearchCenter,
	production: ProductionCoordinator,
	warehouse: OakWarehouse,
	plant_system: PlantSystem,
	test_root: Node
) -> void:
	var simple_fence_recipe := SimpleCraftingRegistry.get_recipe(
		SimpleCraftingRegistry.SIMPLE_FENCE_ID
	)
	var bamboo_recipe := SimpleCraftingRegistry.get_recipe(
		SimpleCraftingRegistry.BAMBOO_MORTAR_ID
	)
	var hydrangea_recipe := SimpleCraftingRegistry.get_recipe(
		SimpleCraftingRegistry.HYDRANGEA_RAIN_TOWER_ID
	)
	var completed_ids := research.get_completed_global_research_ids()
	var available_recipes := SimpleCraftingRegistry.get_available_recipes(
		completed_ids
	)
	_expect(
		completed_ids == [
			BUILDING_DEFENSE_RESEARCH_ID,
			PLAYER_MOVE_SPEED_RESEARCH_ID,
		]
		and available_recipes.size() == 7
		and available_recipes.has(simple_fence_recipe)
		and not available_recipes.has(bamboo_recipe)
		and not available_recipes.has(hydrangea_recipe),
		"两项配方研究开始前，简易围栏必须直接可用且两条研究配方保持锁定。"
	)
	_expect(
		production.get_total_item_count(SAPLING) == 10
		and warehouse.try_add_storage_item_count(SAPLING, 5)
		and warehouse.try_add_storage_item_count(WOODEN_CORE, 6),
		"配方解锁研究测试必须为三项塔研究准备恰好6木制核心和15树苗。"
	)

	_expect(
		center.try_start_global_research(BAMBOO_MORTAR_CRAFTING_RESEARCH_ID)
		== ResearchCoordinator.RESULT_SUCCESS
		and production.get_total_item_count(WOODEN_CORE) == 4
		and production.get_total_item_count(SAPLING) == 10,
		"迫击炮研发启动时必须原子扣除2木制核心和5树苗。"
	)
	research.advance_global_research(29.9)
	completed_ids = research.get_completed_global_research_ids()
	_expect(
		research.get_global_research_state(BAMBOO_MORTAR_CRAFTING_RESEARCH_ID)
		== ResearchCoordinator.GlobalResearchState.RESEARCHING
		and is_equal_approx(
			research.get_global_elapsed_seconds(
				BAMBOO_MORTAR_CRAFTING_RESEARCH_ID
			),
			29.9
		)
		and BAMBOO_MORTAR_CRAFTING_RESEARCH_ID not in completed_ids
		and not SimpleCraftingRegistry.is_recipe_unlocked(
			bamboo_recipe,
			completed_ids
		),
		"迫击炮研发进行29.9秒时不得提前完成或解锁简易制作配方。"
	)
	research.advance_global_research(0.1)
	completed_ids = research.get_completed_global_research_ids()
	available_recipes = SimpleCraftingRegistry.get_available_recipes(completed_ids)
	_expect(
		research.get_global_research_state(BAMBOO_MORTAR_CRAFTING_RESEARCH_ID)
		== ResearchCoordinator.GlobalResearchState.COMPLETED
		and research.get_active_global_research_id().is_empty()
		and completed_ids == [
			BUILDING_DEFENSE_RESEARCH_ID,
			PLAYER_MOVE_SPEED_RESEARCH_ID,
			BAMBOO_MORTAR_CRAFTING_RESEARCH_ID,
		]
		and available_recipes.size() == 8
		and available_recipes.has(simple_fence_recipe)
		and available_recipes.has(bamboo_recipe)
		and not available_recipes.has(hydrangea_recipe),
		"迫击炮研发满30秒后必须导出完成ID并只解锁迫击炮简易配方。"
	)

	_expect(
		center.try_start_global_research(
			HYDRANGEA_RAIN_TOWER_CRAFTING_RESEARCH_ID
		) == ResearchCoordinator.RESULT_SUCCESS
		and production.get_total_item_count(WOODEN_CORE) == 2
		and production.get_total_item_count(SAPLING) == 5,
		"紫阳花研发启动时必须原子扣除2木制核心和5树苗。"
	)
	research.advance_global_research(29.9)
	completed_ids = research.get_completed_global_research_ids()
	_expect(
		research.get_global_research_state(
			HYDRANGEA_RAIN_TOWER_CRAFTING_RESEARCH_ID
		) == ResearchCoordinator.GlobalResearchState.RESEARCHING
		and is_equal_approx(
			research.get_global_elapsed_seconds(
				HYDRANGEA_RAIN_TOWER_CRAFTING_RESEARCH_ID
			),
			29.9
		)
		and HYDRANGEA_RAIN_TOWER_CRAFTING_RESEARCH_ID not in completed_ids
		and not SimpleCraftingRegistry.is_recipe_unlocked(
			hydrangea_recipe,
			completed_ids
		),
		"紫阳花研发进行29.9秒时不得提前完成或解锁简易制作配方。"
	)
	research.advance_global_research(0.1)
	completed_ids = research.get_completed_global_research_ids()
	available_recipes = SimpleCraftingRegistry.get_available_recipes(completed_ids)
	var completed_before_orange: Array[StringName] = [
		BUILDING_DEFENSE_RESEARCH_ID,
		PLAYER_MOVE_SPEED_RESEARCH_ID,
		BAMBOO_MORTAR_CRAFTING_RESEARCH_ID,
		HYDRANGEA_RAIN_TOWER_CRAFTING_RESEARCH_ID,
	]
	_expect(
		research.get_global_research_state(
			HYDRANGEA_RAIN_TOWER_CRAFTING_RESEARCH_ID
		) == ResearchCoordinator.GlobalResearchState.COMPLETED
		and research.get_active_global_research_id().is_empty()
		and completed_ids == completed_before_orange
		and available_recipes.size() == 9
		and available_recipes.has(simple_fence_recipe)
		and available_recipes.has(bamboo_recipe)
		and available_recipes.has(hydrangea_recipe),
		"紫阳花研发满30秒后必须导出四项完成ID，并让全部九条简易配方可用。"
	)
	_expect(
		center.try_start_global_research(
			ORANGE_CHARGING_TOWER_CRAFTING_RESEARCH_ID
		) == ResearchCoordinator.RESULT_SUCCESS
		and production.get_total_item_count(WOODEN_CORE) == 0
		and production.get_total_item_count(SAPLING) == 0,
		"橘充能塔研发启动时必须按紫阳花相同成本原子扣除2木制核心和5树苗。"
	)
	research.advance_global_research(29.9)
	completed_ids = research.get_completed_global_research_ids()
	_expect(
		research.get_global_research_state(
			ORANGE_CHARGING_TOWER_CRAFTING_RESEARCH_ID
		) == ResearchCoordinator.GlobalResearchState.RESEARCHING
		and is_equal_approx(
			research.get_global_elapsed_seconds(
				ORANGE_CHARGING_TOWER_CRAFTING_RESEARCH_ID
			),
			29.9
		)
		and ORANGE_CHARGING_TOWER_CRAFTING_RESEARCH_ID not in completed_ids
		and SimpleCraftingRegistry.get_available_recipes(completed_ids).size() == 9,
		"橘充能塔研发进行29.9秒时不得提前完成，也不得改变简易制作配方集合。"
	)
	research.advance_global_research(0.1)
	completed_ids = research.get_completed_global_research_ids()
	available_recipes = SimpleCraftingRegistry.get_available_recipes(completed_ids)
	var expected_completed_ids: Array[StringName] = [
		BUILDING_DEFENSE_RESEARCH_ID,
		PLAYER_MOVE_SPEED_RESEARCH_ID,
		BAMBOO_MORTAR_CRAFTING_RESEARCH_ID,
		HYDRANGEA_RAIN_TOWER_CRAFTING_RESEARCH_ID,
		ORANGE_CHARGING_TOWER_CRAFTING_RESEARCH_ID,
	]
	_expect(
		research.get_global_research_state(
			ORANGE_CHARGING_TOWER_CRAFTING_RESEARCH_ID
		) == ResearchCoordinator.GlobalResearchState.COMPLETED
		and research.get_active_global_research_id().is_empty()
		and completed_ids == expected_completed_ids
		and available_recipes.size() == 9
		and available_recipes.has(simple_fence_recipe)
		and available_recipes.has(bamboo_recipe)
		and available_recipes.has(hydrangea_recipe),
		"橘充能塔研发满30秒后必须仅新增独立完成ID，不得污染简易制作解锁。"
	)
	_expect(
		is_equal_approx(
			research.get_vegetation_spread_speed_multiplier(),
			1.0
		)
		and production.get_total_item_count(PLANK) == 20
		and warehouse.try_add_storage_item_count(WATER_BOTTLE, 4)
		and center.try_start_global_research(
			VEGETATION_STAKE_SPREAD_ENHANCEMENT_RESEARCH_ID
		) == ResearchCoordinator.RESULT_MISSING_INPUT
		and production.get_total_item_count(PLANK) == 20
		and production.get_total_item_count(WATER_BOTTLE) == 4,
		"植被桩蔓延增强缺少第5个水瓶时必须原子失败，且完成前倍率保持1。"
	)
	_expect(
		warehouse.try_add_storage_item_count(WATER_BOTTLE, 1)
		and center.try_start_global_research(
			VEGETATION_STAKE_SPREAD_ENHANCEMENT_RESEARCH_ID
		) == ResearchCoordinator.RESULT_SUCCESS
		and production.get_total_item_count(PLANK) == 0
		and production.get_total_item_count(WATER_BOTTLE) == 0,
		"植被桩蔓延增强开始时必须原子扣除20木板与5水瓶。"
	)
	research.advance_global_research(59.9)
	_expect(
		research.get_global_research_state(
			VEGETATION_STAKE_SPREAD_ENHANCEMENT_RESEARCH_ID
		) == ResearchCoordinator.GlobalResearchState.RESEARCHING
		and is_equal_approx(
			research.get_vegetation_spread_speed_multiplier(),
			1.0
		),
		"植被桩蔓延增强未满60秒时不得提前提高蔓延速率。"
	)
	research.advance_global_research(0.1)
	expected_completed_ids.append(
		VEGETATION_STAKE_SPREAD_ENHANCEMENT_RESEARCH_ID
	)
	completed_ids = research.get_completed_global_research_ids()
	_expect(
		completed_ids == expected_completed_ids
		and research.get_active_global_research_id().is_empty()
		and is_equal_approx(
			research.get_vegetation_spread_speed_multiplier(),
			2.0
		)
		and SimpleCraftingRegistry.get_available_recipes(completed_ids).size()
		== 9,
		"植被桩蔓延增强满60秒后必须把蔓延倍率设为2，且不得污染配方解锁。"
	)
	_expect(
		warehouse.try_add_storage_item_count(WHITE_CRYSTAL_POWDER, 4)
		and warehouse.try_add_storage_item_count(WATER_BOTTLE, 30)
		and warehouse.try_add_storage_item_count(SAPLING, 10)
		and center.try_start_global_research(
			VEGETATION_ENHANCEMENT_RESEARCH_ID
		) == ResearchCoordinator.RESULT_MISSING_INPUT
		and production.get_total_item_count(WHITE_CRYSTAL_POWDER) == 4
		and production.get_total_item_count(WATER_BOTTLE) == 30
		and production.get_total_item_count(SAPLING) == 10,
		"植被强化缺少第5个白色水晶粉末时必须原子失败且不能预扣水瓶或树苗。"
	)
	_expect(
		warehouse.try_add_storage_item_count(WHITE_CRYSTAL_POWDER, 1)
		and center.try_start_global_research(
			VEGETATION_ENHANCEMENT_RESEARCH_ID
		) == ResearchCoordinator.RESULT_SUCCESS
		and production.get_total_item_count(WHITE_CRYSTAL_POWDER) == 0
		and production.get_total_item_count(WATER_BOTTLE) == 0
		and production.get_total_item_count(SAPLING) == 0,
		"植被强化开始时必须原子扣除5白色水晶粉末、30水瓶和10树苗。"
	)
	research.advance_global_research(29.9)
	_expect(
		research.get_global_research_state(VEGETATION_ENHANCEMENT_RESEARCH_ID)
		== ResearchCoordinator.GlobalResearchState.RESEARCHING
		and is_zero_approx(research.get_grass_heal_ratio_bonus()),
		"植被强化未满30秒时不得提前提供额外草地回血。"
	)
	research.advance_global_research(0.1)
	expected_completed_ids.append(VEGETATION_ENHANCEMENT_RESEARCH_ID)
	completed_ids = research.get_completed_global_research_ids()
	_expect(
		completed_ids == expected_completed_ids
		and research.get_active_global_research_id().is_empty()
		and is_equal_approx(research.get_grass_heal_ratio_bonus(), 0.2)
		and SimpleCraftingRegistry.get_available_recipes(completed_ids).size()
		== 9,
		"植被强化满30秒后必须额外提供20%草地回血，且不得污染配方解锁。"
	)
	_expect(
		warehouse.try_add_storage_item_count(WHITE_CRYSTAL_POWDER, 2)
		and warehouse.try_add_storage_item_count(WATER_BOTTLE, 10)
		and warehouse.try_add_storage_item_count(PLANK, 20)
		and center.try_start_global_research(
			WATER_COLLECTION_RATE_ENHANCEMENT_RESEARCH_ID
		) == ResearchCoordinator.RESULT_MISSING_INPUT
		and production.get_total_item_count(WHITE_CRYSTAL_POWDER) == 2
		and production.get_total_item_count(WATER_BOTTLE) == 10
		and production.get_total_item_count(PLANK) == 20,
		"采水速率提升缺少第3个白色水晶粉末时必须原子失败且不能预扣水瓶或木板。"
	)
	_expect(
		warehouse.try_add_storage_item_count(WHITE_CRYSTAL_POWDER, 1)
		and center.try_start_global_research(
			WATER_COLLECTION_RATE_ENHANCEMENT_RESEARCH_ID
		) == ResearchCoordinator.RESULT_SUCCESS
		and production.get_total_item_count(WHITE_CRYSTAL_POWDER) == 0
		and production.get_total_item_count(WATER_BOTTLE) == 0
		and production.get_total_item_count(PLANK) == 0,
		"采水速率提升开始时必须原子扣除3白色水晶粉末、10水瓶和20木板。"
	)
	research.advance_global_research(29.9)
	_expect(
		research.get_global_research_state(
			WATER_COLLECTION_RATE_ENHANCEMENT_RESEARCH_ID
		) == ResearchCoordinator.GlobalResearchState.RESEARCHING
		and is_equal_approx(
			research.get_water_collector_duration_multiplier(),
			1.0
		)
		and is_equal_approx(
			plant_system.get_global_water_collector_duration_multiplier(),
			1.0
		),
		"采水速率提升未满30秒时不得提前缩短水收集器耗时。"
	)
	research.advance_global_research(0.1)
	expected_completed_ids.append(
		WATER_COLLECTION_RATE_ENHANCEMENT_RESEARCH_ID
	)
	completed_ids = research.get_completed_global_research_ids()
	_expect(
		completed_ids == expected_completed_ids
		and research.get_active_global_research_id().is_empty()
		and is_equal_approx(
			research.get_water_collector_duration_multiplier(),
			0.5
		)
		and is_equal_approx(
			plant_system.get_global_water_collector_duration_multiplier(),
			0.5
		)
		and SimpleCraftingRegistry.get_available_recipes(completed_ids).size()
		== 9,
		"采水速率提升满30秒后必须把水收集器单轮耗时倍率设为0.5，且不得污染配方解锁。"
	)
	_expect(
		warehouse.try_add_storage_item_count(PLANK, 99)
		and warehouse.try_add_storage_item_count(SAPLING, 100)
		and center.try_start_global_research(FENCE_REINFORCEMENT_RESEARCH_ID)
		== ResearchCoordinator.RESULT_MISSING_INPUT
		and production.get_total_item_count(PLANK) == 99
		and production.get_total_item_count(SAPLING) == 100,
		"围栏强化缺少第100块木板时必须原子失败且不能预扣树苗。"
	)
	_expect(
		warehouse.try_add_storage_item_count(PLANK, 1)
		and center.try_start_global_research(FENCE_REINFORCEMENT_RESEARCH_ID)
		== ResearchCoordinator.RESULT_SUCCESS
		and production.get_total_item_count(PLANK) == 0
		and production.get_total_item_count(SAPLING) == 0,
		"围栏强化开始时必须原子扣除100木板和100树苗。"
	)
	research.advance_global_research(29.9)
	_expect(
		research.get_global_research_state(FENCE_REINFORCEMENT_RESEARCH_ID)
		== ResearchCoordinator.GlobalResearchState.RESEARCHING
		and research.get_fence_max_health_bonus() == 0
		and research.get_fence_physical_defense_bonus() == 0
		and plant_system.get_global_fence_max_health_bonus() == 0
		and plant_system.get_global_fence_physical_defense_bonus() == 0,
		"围栏强化未满30秒时不得提前增加围栏生命或物防。"
	)
	research.advance_global_research(0.1)
	expected_completed_ids.append(FENCE_REINFORCEMENT_RESEARCH_ID)
	completed_ids = research.get_completed_global_research_ids()
	_expect(
		completed_ids == expected_completed_ids
		and research.get_active_global_research_id().is_empty()
		and research.get_fence_max_health_bonus() == 1000
		and research.get_fence_physical_defense_bonus() == 5
		and plant_system.get_global_fence_max_health_bonus() == 1000
		and plant_system.get_global_fence_physical_defense_bonus() == 5
		and SimpleCraftingRegistry.get_available_recipes(completed_ids).size()
		== 9,
		"围栏强化满30秒后必须提供1000生命与5物防，且不得污染配方解锁。"
	)

	var remote_research := (
		RESEARCH_COORDINATOR_SCENE.instantiate() as ResearchCoordinator
	)
	var remote_plant_system := PlantSystem.new()
	var remote_player := TIYI_SCENE.instantiate() as Player
	test_root.add_child(remote_research)
	test_root.add_child(remote_plant_system)
	test_root.add_child(remote_player)
	await process_frame
	remote_research.research_tick_timer.stop()
	remote_research.setup(null, remote_plant_system, null)
	remote_research.set_authoritative_processing_enabled(false)
	remote_player.peer_id = 8
	var remote_base_speed := remote_player.move_speed
	remote_research.register_player(remote_player)
	var snapshot := research.export_runtime_state()
	remote_research.apply_multiplayer_runtime_state(snapshot)
	var snapshot_states := snapshot.get("global_states", {}) as Dictionary
	var snapshot_elapsed := snapshot.get("global_elapsed", {}) as Dictionary
	_expect(
		int(snapshot.get("schema", 0)) == 3
		and snapshot_states.size() == 15
		and snapshot_elapsed.size() == 15
		and remote_research.get_completed_global_research_ids()
		== expected_completed_ids
		and is_equal_approx(
			remote_research.get_vegetation_spread_speed_multiplier(),
			2.0
		)
		and is_equal_approx(
			remote_research.get_grass_heal_ratio_bonus(),
			0.2
		)
		and is_equal_approx(
			remote_research.get_water_collector_duration_multiplier(),
			0.5
		)
		and is_equal_approx(
			remote_plant_system.get_global_water_collector_duration_multiplier(),
			0.5
		)
		and remote_plant_system.get_global_physical_defense_bonus() == 5
		and remote_research.get_fence_max_health_bonus() == 1000
		and remote_research.get_fence_physical_defense_bonus() == 5
		and remote_plant_system.get_global_fence_max_health_bonus() == 1000
		and remote_plant_system.get_global_fence_physical_defense_bonus() == 5
		and is_equal_approx(
			remote_player.move_speed,
			remote_base_speed + _get_expected_global_move_speed_bonus()
		),
		"schema3多人科研快照必须完整同步十五个项目、数值效果与三项配方解锁。"
	)
	var replayed_snapshot := snapshot.duplicate(true)
	replayed_snapshot["revision"] = int(snapshot["revision"]) + 1
	remote_research.apply_multiplayer_runtime_state(replayed_snapshot)
	_expect(
		remote_research.get_completed_global_research_ids()
		== expected_completed_ids
		and is_equal_approx(
			remote_research.get_vegetation_spread_speed_multiplier(),
			2.0
		)
		and is_equal_approx(
			remote_research.get_grass_heal_ratio_bonus(),
			0.2
		)
		and is_equal_approx(
			remote_research.get_water_collector_duration_multiplier(),
			0.5
		)
		and is_equal_approx(
			remote_plant_system.get_global_water_collector_duration_multiplier(),
			0.5
		)
		and remote_research.get_fence_max_health_bonus() == 1000
		and remote_research.get_fence_physical_defense_bonus() == 5
		and remote_plant_system.get_global_fence_max_health_bonus() == 1000
		and remote_plant_system.get_global_fence_physical_defense_bonus() == 5
		and is_equal_approx(
			remote_player.move_speed,
			remote_base_speed + _get_expected_global_move_speed_bonus()
		),
		"重复应用更高revision的十五项目完成态快照不得重复叠加数值效果。"
	)

	var accepted_revision := remote_research.research_revision
	var invalid_snapshots: Array[Dictionary] = []
	var wrong_schema := replayed_snapshot.duplicate(true)
	wrong_schema["schema"] = 2
	wrong_schema["revision"] = accepted_revision + 1
	invalid_snapshots.append(wrong_schema)
	var unknown_active_id := replayed_snapshot.duplicate(true)
	unknown_active_id["revision"] = accepted_revision + 1
	unknown_active_id["active_global_research_id"] = "forged_research"
	invalid_snapshots.append(unknown_active_id)
	var missing_project_state := replayed_snapshot.duplicate(true)
	missing_project_state["revision"] = accepted_revision + 1
	var missing_states := missing_project_state["global_states"] as Dictionary
	missing_states.erase(String(FENCE_REINFORCEMENT_RESEARCH_ID))
	invalid_snapshots.append(missing_project_state)
	var legacy_v84_snapshot := replayed_snapshot.duplicate(true)
	legacy_v84_snapshot["revision"] = accepted_revision + 1
	var legacy_states := legacy_v84_snapshot["global_states"] as Dictionary
	var legacy_elapsed := legacy_v84_snapshot["global_elapsed"] as Dictionary
	for research_id in [
		AGAVE_CANNON_MUZZLE_IMPROVEMENT_RESEARCH_ID,
		CORN_MACHINE_GUN_COOLING_SYSTEM_IMPROVEMENT_RESEARCH_ID,
		BAMBOO_MORTAR_CONCUSSIVE_MODIFICATION_RESEARCH_ID,
		GRAPE_ARC_TOWER_SURGE_MODIFICATION_RESEARCH_ID,
	]:
		legacy_states.erase(String(research_id))
		legacy_elapsed.erase(String(research_id))
	invalid_snapshots.append(legacy_v84_snapshot)
	var wrong_elapsed_type := replayed_snapshot.duplicate(true)
	wrong_elapsed_type["revision"] = accepted_revision + 1
	var typed_elapsed := wrong_elapsed_type["global_elapsed"] as Dictionary
	typed_elapsed[String(BAMBOO_MORTAR_CRAFTING_RESEARCH_ID)] = "30.0"
	invalid_snapshots.append(wrong_elapsed_type)
	var incomplete_completed_elapsed := replayed_snapshot.duplicate(true)
	incomplete_completed_elapsed["revision"] = accepted_revision + 1
	var incomplete_elapsed := (
		incomplete_completed_elapsed["global_elapsed"] as Dictionary
	)
	incomplete_elapsed[String(ORANGE_CHARGING_TOWER_CRAFTING_RESEARCH_ID)] = 29.9
	invalid_snapshots.append(incomplete_completed_elapsed)
	for invalid_snapshot in invalid_snapshots:
		remote_research.apply_multiplayer_runtime_state(invalid_snapshot)
	_expect(
		remote_research.research_revision == accepted_revision
		and remote_research.get_completed_global_research_ids()
		== expected_completed_ids
		and is_equal_approx(
			remote_research.get_vegetation_spread_speed_multiplier(),
			2.0
		)
		and is_equal_approx(
			remote_research.get_water_collector_duration_multiplier(),
			0.5
		)
		and is_equal_approx(
			remote_plant_system.get_global_water_collector_duration_multiplier(),
			0.5
		)
		and remote_plant_system.get_global_physical_defense_bonus() == 5
		and remote_research.get_fence_max_health_bonus() == 1000
		and remote_research.get_fence_physical_defense_bonus() == 5
		and remote_plant_system.get_global_fence_max_health_bonus() == 1000
		and remote_plant_system.get_global_fence_physical_defense_bonus() == 5
		and is_equal_approx(
			remote_player.move_speed,
			remote_base_speed + _get_expected_global_move_speed_bonus()
		),
		"客户端必须拒绝错误schema、未知ID、缺失项目、v84十一项目快照、错误类型与矛盾进度字段。"
	)


func _test_player_technology(
	research: ResearchCoordinator,
	center: ResearchCenter,
	panel: ResearchCenterPanel,
	weishidaier: Player,
	tiyi: Player,
	hoe_cat: Player,
	tango: PlayerTango
) -> void:
	for player in [weishidaier, tiyi, hoe_cat, tango]:
		_expect(player.grant_cheat_xirang(22000), "角色必须能获得技术测试息壤。")

	panel.open_for(center, weishidaier)
	panel.call("_switch_page", ResearchCenterPanel.Page.PLAYER_TECH)
	panel.call("_on_action_pressed")
	_expect(
		weishidaier.get_research_technology_level() == 1
		and weishidaier.get_xirang() == 20000
		and weishidaier.get_research_burn_tick_damage() == 10,
		"威士戴尔一级技术必须花费2000息壤并获得5秒10级燃烧参数。"
	)
	_expect(
		panel.tech_nodes[0].scale != Vector2.ONE,
		"技术节点点亮时必须启动可见缩放动画。"
	)
	await create_timer(0.6).timeout
	_expect(
		panel.tech_nodes[0].scale.is_equal_approx(Vector2.ONE)
		and panel.tech_nodes[0].modulate.is_equal_approx(
			ResearchCenterPanel.NODE_ON_COLORS[0]
		),
		"节点动画结束后必须保持持续点亮亮度。"
	)
	await create_timer(1.5).timeout
	panel.close()
	_expect(not weishidaier.controls_locked, "关闭科研面板必须恢复玩家控制。")

	_expect(
		research.try_purchase_player_technology(weishidaier)
		== ResearchCoordinator.RESULT_SUCCESS
		and research.try_purchase_player_technology(weishidaier)
		== ResearchCoordinator.RESULT_SUCCESS
		and weishidaier.get_xirang() == 0
		and weishidaier.get_research_burn_tick_damage() == 30,
		"威士戴尔三级研究总计必须花费22000息壤并提升至30级燃烧。"
	)
	for _level in range(3):
		_expect(
			research.try_purchase_player_technology(tiyi)
			== ResearchCoordinator.RESULT_SUCCESS,
			"提伊的三次玩家技术升级都必须成功。"
		)
	_expect(
		tiyi.get_xirang() == 0
		and is_equal_approx(tiyi.get_research_tiyi_slow_multiplier(), 0.2),
		"提伊三级锁定研究必须花费相同成本并形成80%减速。"
	)
	for _level in range(3):
		_expect(
			research.try_purchase_player_technology(hoe_cat)
			== ResearchCoordinator.RESULT_SUCCESS,
			"锄头猫猫的三次玩家技术升级都必须成功。"
		)
	var defense_before := hoe_cat.physical_defense
	hoe_cat.call("_activate_research_whirlwind_defense")
	_expect(
		hoe_cat.get_xirang() == 0
		and hoe_cat.get_research_hoe_physical_defense_bonus() == 50
		and hoe_cat.physical_defense == defense_before + 50
		and is_equal_approx(hoe_cat.research_defense_timer.wait_time, 2.0),
		"锄头猫猫三级旋风研究必须在技能后提供2秒50点临时物防。"
	)
	hoe_cat.call("_on_research_defense_timer_timeout")
	_expect(
		hoe_cat.physical_defense == defense_before,
		"锄头猫猫的科研临时物防必须在2秒计时结束时完全移除。"
	)

	var tango_research_costs := [2000, 5000, 15000]
	for expected_cost in tango_research_costs:
		_expect(
			tango.get_next_research_technology_cost() == int(expected_cost)
			and research.try_purchase_player_technology(tango)
			== ResearchCoordinator.RESULT_SUCCESS,
			"探戈的三次玩家技术升级必须复用提伊的2000/5000/15000息壤成本。"
		)
	_expect(
		tango.get_xirang() == 0
		and tango.get_research_technology_level() == 3
		and tango.get_research_tango_defense_bonus() == 50,
		"探戈三级电涌装甲必须总计花费22000息壤并提供50点双防参数。"
	)
	panel.open_for(center, tango)
	panel.call("_switch_page", ResearchCenterPanel.Page.PLAYER_TECH)
	_expect(
		panel.player_tech_name.text == "电涌装甲"
		and panel.player_tech_description.text.contains("8秒")
		and panel.node_effect_labels[0].text == "双防+10"
		and panel.node_effect_labels[1].text == "双防+25"
		and panel.node_effect_labels[2].text == "双防+50",
		"科研中心必须完整显示探戈的技术说明与三档双防增益。"
	)
	panel.close()
	var tango_physical_defense_before := tango.physical_defense
	var tango_magic_defense_before := tango.magic_defense
	tango.call("_begin_electric_surge", 91, Vector2.ZERO, 8.0, true)
	_expect(
		tango.physical_defense == tango_physical_defense_before + 50
		and tango.magic_defense == tango_magic_defense_before + 50,
		"探戈三级科研必须在电能涌动强化期间同时增加50点物防和法防。"
	)
	tango.call("_refresh_collectible_stats", false)
	_expect(
		tango.physical_defense == tango_physical_defense_before + 50
		and tango.magic_defense == tango_magic_defense_before + 50,
		"探戈科研双防不得被收藏品属性重算覆盖。"
	)
	tango.call("_on_electric_surge_duration_timer_timeout")
	_expect(
		tango.physical_defense == tango_physical_defense_before
		and tango.magic_defense == tango_magic_defense_before,
		"探戈科研双防必须随8秒技能强化状态一同结束。"
	)


func _test_interaction_candidate_ordering(test_root: Node) -> void:
	var first := PlantDefense.new()
	var second := PlantDefense.new()
	test_root.add_child(first)
	test_root.add_child(second)

	first.global_position = Vector2(8.0, 8.0)
	second.global_position = Vector2(-8.0, -8.0)
	first.set_meta(&"net_id", 4)
	second.set_meta(&"net_id", 9)
	_expect(
		PlantDefense.is_interaction_candidate_preferred(first, 64.0, second, 64.0)
		and not PlantDefense.is_interaction_candidate_preferred(
			second,
			64.0,
			first,
			64.0
		),
		"多人等距交互必须忽略节点遍历顺序，并稳定选择较小的正net_id。"
	)
	_expect(
		PlantDefense.is_interaction_candidate_preferred(second, 63.0, first, 64.0),
		"真实距离更近的建筑必须始终优先于net_id。"
	)

	first.set_meta(&"net_id", 4)
	second.set_meta(&"net_id", 0)
	_expect(
		PlantDefense.is_interaction_candidate_preferred(second, 64.0, first, 64.0),
		"只有一侧具备正net_id时，等距交互必须回退到稳定的y坐标排序。"
	)
	first.set_meta(&"net_id", 0)
	first.global_position = Vector2(8.0, -8.0)
	second.global_position = Vector2(-8.0, -8.0)
	_expect(
		PlantDefense.is_interaction_candidate_preferred(second, 64.0, first, 64.0),
		"单人等距且y坐标相同时，交互必须稳定选择较小的x坐标。"
	)
	first.global_position = Vector2.ZERO
	second.global_position = Vector2.ZERO
	var lower_instance := (
		first if first.get_instance_id() < second.get_instance_id() else second
	)
	var higher_instance := second if lower_instance == first else first
	_expect(
		PlantDefense.is_interaction_candidate_preferred(
			lower_instance,
			64.0,
			higher_instance,
			64.0
		),
		"单人等距且坐标相同时，交互必须以instance_id完成稳定排序。"
	)


func _test_multiplayer_request_contract(
	config: PlantDefenseConfig,
	research: ResearchCoordinator,
	panel: ResearchCenterPanel,
	test_root: Node
) -> void:
	var proxy := config.plant_scene.instantiate() as ResearchCenter
	test_root.add_child(proxy)
	proxy.setup(config, null, [Vector2i.ZERO], true)
	proxy.set_research_services(research, panel)
	proxy.configure_multiplayer_research(37, 9)
	proxy.multiplayer_research_request_pending = true
	proxy.multiplayer_research_pending_request_id = 99
	proxy.configure_multiplayer_research(37, 9)
	_expect(
		proxy.multiplayer_research_request_pending
		and proxy.multiplayer_research_pending_request_id == 99,
		"相同多人身份的重复配置不得清除正在等待的科研请求。"
	)
	proxy.multiplayer_research_request_pending = false
	proxy.multiplayer_research_pending_request_id = 0
	var captured: Array[Dictionary] = []
	var result_contexts: Array[Dictionary] = []
	proxy.research_command_requested.connect(
		func(command: Dictionary) -> void: captured.append(command)
	)
	proxy.multiplayer_research_result.connect(
		func(
			success: bool,
			reason: StringName,
			operation: StringName,
			research_id: StringName
		) -> void:
			result_contexts.append({
				"success": success,
				"reason": reason,
				"operation": operation,
				"research_id": research_id,
			})
	)
	var result := proxy.try_purchase_player_technology(null)
	_expect(
		result == ResearchCoordinator.RESULT_REQUEST_SENT
		and proxy.multiplayer_research_request_pending
		and captured.size() == 1
		and int(captured[0].get("schema", 0)) == 2
		and int(captured[0].get("building_net_id", 0)) == 37
		and int(captured[0].get("peer_id", 0)) == 9
		and str(captured[0].get("operation", "")) == "player"
		and str(captured[0].get("research_id", "")).is_empty(),
		"多人客户端个人研究必须发送schema2、建筑、玩家与操作类型。"
	)
	proxy.complete_multiplayer_research_request(
		int(captured[0].get("request_id", 0)),
		false,
		ResearchCoordinator.RESULT_INSUFFICIENT_XIRANG
	)
	_expect(
		not proxy.multiplayer_research_request_pending
		and result_contexts.size() == 1
		and result_contexts[0].get("operation", &"") == &"player"
		and result_contexts[0].get("research_id", &"") == &"",
		"主机结果返回后必须解除请求锁，并保留个人研究请求类型。"
	)
	var global_result := proxy.try_start_global_research(
		PLAYER_MOVE_SPEED_RESEARCH_ID
	)
	_expect(
		global_result == ResearchCoordinator.RESULT_REQUEST_SENT
		and captured.size() == 2
		and int(captured[1].get("schema", 0)) == 2
		and str(captured[1].get("operation", "")) == "global"
		and str(captured[1].get("research_id", ""))
		== String(PLAYER_MOVE_SPEED_RESEARCH_ID),
		"多人全局研究请求必须只携带白名单研究ID，由主机决定材料与效果。"
	)
	proxy.complete_multiplayer_research_request(
		int(captured[1].get("request_id", 0)),
		true,
		ResearchCoordinator.RESULT_SUCCESS
	)
	_expect(
		result_contexts.size() == 2
		and result_contexts[1].get("operation", &"") == &"global"
		and result_contexts[1].get("research_id", &"")
		== PLAYER_MOVE_SPEED_RESEARCH_ID,
		"多人回包必须携带原全局研究ID，面板重开后也能显示正确项目。"
	)


func _get_expected_global_move_speed_bonus() -> float:
	return GlobalResearchEffectResolver.from_completed_ids(
		GlobalResearchRegistry.get_all_configs(),
		[PLAYER_MOVE_SPEED_RESEARCH_ID]
	).player_move_speed_bonus


func _finish(test_root: Node) -> void:
	if test_root != null and is_instance_valid(test_root):
		test_root.free()
	if failures.is_empty():
		print("RESEARCH_CENTER_SMOKE_TEST_OK")
		quit()
		return
	for failure in failures:
		push_error(failure)
	quit(1)


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
