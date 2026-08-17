extends SceneTree

const COORDINATOR_SCENE := preload(
	"res://scene/game_modes/tower_defense/economy/production/production_coordinator.tscn"
)
const WAREHOUSE_SCENE := preload(
	"res://scene/plant_defense/oak_warehouse.tscn"
)
const PANEL_SCENE := preload(
	"res://scene/game_modes/tower_defense/economy/production/production_building_panel.tscn"
)
const PLACEMENT_CONTROLLER_SCENE := preload(
	"res://scene/game_modes/tower_defense/plant/placement/plant_placement_controller.tscn"
)
const PLAYER_SCENE := preload(
	"res://scene/player/weishidaier/player_weishidaier.tscn"
)
const PROFILE_PANEL_SCENE := preload(
	"res://scene/game_modes/tower_defense/ui/tower_defense_player_profile_panel.tscn"
)
const WOODEN_CORE := preload(
	"res://resources/config/materials/material_wooden_core.tres"
)
const WATER_BOTTLE := preload(
	"res://resources/config/materials/material_water_bottle.tres"
)
const SORCERER_VIOLET_POWDER := preload(
	"res://resources/config/materials/material_sorcerer_violet_powder.tres"
)
const AGAVE_BUILDING_ITEM := preload(
	"res://resources/config/buildings/building_agave_cannon.tres"
)
const CORN_BUILDING_ITEM := preload(
	"res://resources/config/buildings/building_corn_machine_gun.tres"
)
const BAMBOO_MORTAR_BUILDING_ITEM := preload(
	"res://resources/config/buildings/building_bamboo_mortar.tres"
)
const HYDRANGEA_RAIN_TOWER_BUILDING_ITEM := preload(
	"res://resources/config/buildings/building_hydrangea_rain_tower.tres"
)
const GRAPE_ARC_TOWER_BUILDING_ITEM := preload(
	"res://resources/config/buildings/building_grape_arc_tower.tres"
)
const ORANGE_CHARGING_TOWER_BUILDING_ITEM := preload(
	"res://resources/config/buildings/building_orange_charging_tower.tres"
)
const DIRT_BLOCK := preload(
	"res://resources/config/materials/material_dirt_block.tres"
)
const WHITE_CRYSTAL_POWDER := preload(
	"res://resources/config/materials/material_white_crystal_powder.tres"
)
const HOTSPOT_LIGHT_TEXTURE := preload(
	"res://resources/lighting/plant_cultivation_center_hotspots.svg"
)
const DAY_NIGHT_CONTROLLER_SCENE := preload(
	"res://scene/lighting/day_night_controller.tscn"
)


class PlacementRollbackPlantSystem:
	extends PlantSystem

	var test_config: PlantDefenseConfig

	func _init(config: PlantDefenseConfig) -> void:
		test_config = config

	func get_config(plant_id: StringName) -> PlantDefenseConfig:
		return test_config if plant_id == test_config.plant_id else null

	func is_placement_valid_for_player(
		_top_left_cell: Vector2i,
		config: PlantDefenseConfig,
		_placement_player: Player
	) -> bool:
		return config == test_config

	func try_place_for_player(
		_config: PlantDefenseConfig,
		_top_left_cell: Vector2i,
		_placement_player: Player,
		_net_id: int = 0
	) -> PlantDefense:
		return null


var failures: PackedStringArray = []
var completed_research_ids: Dictionary[StringName, bool] = {}


func _is_research_completed(research_id: StringName) -> bool:
	return completed_research_ids.has(research_id)


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var test_root := Node.new()
	test_root.name = "PlantCultivationCenterSmokeTest"
	root.add_child(test_root)

	var config := PlantDefenseRegistry.get_config(&"plant_cultivation_center")
	_expect(config != null and config.is_valid(), "植物培育中心配置必须有效。")
	_expect(
		config != null
		and config.footprint_size == Vector2i(2, 2)
		and config.max_health == 1500
		and config.physical_defense == 10
		and config.magic_defense == 10
		and config.supports_multiplayer,
		"植物培育中心必须占2×2格，拥有1500生命、10物防、10法防并支持联机。"
	)
	_expect(
		PlantDefenseRegistry.get_all_configs().size() == 19
		and PlantDefenseRegistry.get_all_configs().has(
			PlantDefenseRegistry.get_config(&"excavator")
		)
		and PlantDefenseRegistry.get_all_configs().has(
			PlantDefenseRegistry.get_config(&"stone_mill")
		)
		and PlantDefenseRegistry.get_all_configs().has(
			PlantDefenseRegistry.get_config(&"simple_fence")
		)
		and PlantDefenseRegistry.get_all_configs().has(
			PlantDefenseRegistry.get_config(&"life_tower")
		)
		and PlantDefenseRegistry.get_all_configs().has(
			PlantDefenseRegistry.get_config(&"speed_tower")
		)
		and PlantDefenseRegistry.get_all_configs().has(
			PlantDefenseRegistry.get_config(&"attack_speed_tower")
		),
		"公共注册表必须包含生命、移速与攻速强化塔及既有全部正式建筑，共19种建筑。"
	)
	if config == null:
		_finish(test_root)
		return

	var coordinator := COORDINATOR_SCENE.instantiate() as ProductionCoordinator
	var warehouse := WAREHOUSE_SCENE.instantiate() as OakWarehouse
	var center := config.plant_scene.instantiate() as PlantCultivationCenter
	var panel := PANEL_SCENE.instantiate() as ProductionBuildingPanel
	var player := PLAYER_SCENE.instantiate() as Player
	var day_night_controller := (
		DAY_NIGHT_CONTROLLER_SCENE.instantiate() as DayNightController
	)
	test_root.add_child(day_night_controller)
	test_root.add_child(coordinator)
	test_root.add_child(warehouse)
	test_root.add_child(center)
	test_root.add_child(panel)
	test_root.add_child(player)
	await process_frame
	coordinator.production_tick_timer.stop()
	day_night_controller.set_night_factor_immediate(1.0)

	var warehouse_config := PlantDefenseRegistry.get_config(&"oak_warehouse")
	warehouse.setup(warehouse_config, null, [Vector2i.ZERO])
	center.setup(
		config,
		null,
		[
			Vector2i(1, 0),
			Vector2i(2, 0),
			Vector2i(1, 1),
			Vector2i(2, 1),
		]
	)
	coordinator.register_plant(warehouse)
	coordinator.register_plant(center)
	center.set_recipe_unlock_checker(Callable(self, "_is_research_completed"))
	center.set_shared_production_panel(panel)

	_expect(
		center.recipes.size() == 6
		and center.recipes[0].input_items == [WOODEN_CORE]
		and center.recipes[0].input_amounts == [1]
		and center.recipes[0].output_items == [AGAVE_BUILDING_ITEM]
		and center.recipes[0].output_amounts == [1]
		and is_equal_approx(center.recipes[0].duration_seconds, 20.0)
		and not center.recipes[0].outputs_to_player_inventory()
		and center.recipes[1].input_items == [WOODEN_CORE]
		and center.recipes[1].input_amounts == [1]
		and center.recipes[1].output_items == [CORN_BUILDING_ITEM]
		and center.recipes[1].output_amounts == [1]
		and is_equal_approx(center.recipes[1].duration_seconds, 20.0)
		and not center.recipes[1].outputs_to_player_inventory()
		and center.recipes[2].input_items == [WOODEN_CORE]
		and center.recipes[2].input_amounts == [1]
		and center.recipes[2].output_items
		== [BAMBOO_MORTAR_BUILDING_ITEM]
		and center.recipes[2].output_amounts == [1]
		and is_equal_approx(center.recipes[2].duration_seconds, 30.0)
		and not center.recipes[2].outputs_to_player_inventory()
		and center.recipes[3].input_items == [WOODEN_CORE, WATER_BOTTLE]
		and center.recipes[3].input_amounts == [2, 2]
		and center.recipes[3].output_items
		== [HYDRANGEA_RAIN_TOWER_BUILDING_ITEM]
		and center.recipes[3].output_amounts == [1]
		and center.recipes[3].required_global_research_id
		== GlobalResearchRegistry.HYDRANGEA_RAIN_TOWER_CRAFTING_ID
		and is_equal_approx(center.recipes[3].duration_seconds, 30.0)
		and not center.recipes[3].outputs_to_player_inventory()
		and center.recipes[4].input_items
		== [WOODEN_CORE, DIRT_BLOCK, WHITE_CRYSTAL_POWDER]
		and center.recipes[4].input_amounts == [1, 2, 1]
		and center.recipes[4].output_items == [GRAPE_ARC_TOWER_BUILDING_ITEM]
		and center.recipes[4].output_amounts == [1]
		and is_equal_approx(center.recipes[4].duration_seconds, 40.0)
		and not center.recipes[4].outputs_to_player_inventory()
		and center.recipes[5].input_items
		== [WOODEN_CORE, SORCERER_VIOLET_POWDER]
		and center.recipes[5].input_amounts == [1, 1]
		and center.recipes[5].output_items
		== [ORANGE_CHARGING_TOWER_BUILDING_ITEM]
		and center.recipes[5].output_amounts == [1]
		and center.recipes[5].required_global_research_id
		== GlobalResearchRegistry.ORANGE_CHARGING_TOWER_CRAFTING_ID
		and is_equal_approx(center.recipes[5].duration_seconds, 30.0)
		and not center.recipes[5].outputs_to_player_inventory(),
		"培育中心必须只保留六种植物培育配方。"
	)
	_expect(
		AGAVE_BUILDING_ITEM.pickup_type == PickupConfig.PickupType.BUILDING
		and AGAVE_BUILDING_ITEM.placeable_plant_id == &"agave_cannon"
		and AGAVE_BUILDING_ITEM.stackable
		and AGAVE_BUILDING_ITEM.inventory_stack_limit == 999
		and CORN_BUILDING_ITEM.pickup_type == PickupConfig.PickupType.BUILDING
		and CORN_BUILDING_ITEM.placeable_plant_id == &"corn_machine_gun"
		and CORN_BUILDING_ITEM.stackable
		and CORN_BUILDING_ITEM.inventory_stack_limit == 999
		and BAMBOO_MORTAR_BUILDING_ITEM.pickup_type
		== PickupConfig.PickupType.BUILDING
		and BAMBOO_MORTAR_BUILDING_ITEM.placeable_plant_id
		== &"bamboo_mortar"
		and BAMBOO_MORTAR_BUILDING_ITEM.stackable
		and BAMBOO_MORTAR_BUILDING_ITEM.inventory_stack_limit == 999
		and HYDRANGEA_RAIN_TOWER_BUILDING_ITEM.pickup_type
		== PickupConfig.PickupType.BUILDING
		and HYDRANGEA_RAIN_TOWER_BUILDING_ITEM.placeable_plant_id
		== &"hydrangea_rain_tower"
		and HYDRANGEA_RAIN_TOWER_BUILDING_ITEM.stackable
		and HYDRANGEA_RAIN_TOWER_BUILDING_ITEM.inventory_stack_limit == 999
		and GRAPE_ARC_TOWER_BUILDING_ITEM.pickup_type
		== PickupConfig.PickupType.BUILDING
		and GRAPE_ARC_TOWER_BUILDING_ITEM.placeable_plant_id
		== &"grape_arc_tower"
		and GRAPE_ARC_TOWER_BUILDING_ITEM.stackable
		and GRAPE_ARC_TOWER_BUILDING_ITEM.inventory_stack_limit == 999
		and ORANGE_CHARGING_TOWER_BUILDING_ITEM.pickup_type
		== PickupConfig.PickupType.BUILDING
		and ORANGE_CHARGING_TOWER_BUILDING_ITEM.placeable_plant_id
		== &"orange_charging_tower"
		and ORANGE_CHARGING_TOWER_BUILDING_ITEM.stackable
		and ORANGE_CHARGING_TOWER_BUILDING_ITEM.inventory_stack_limit == 999,
		"六种产物必须可堆叠至999且指向正确建筑配置。"
	)

	var border := center.get_node_or_null("ProductionBorder") as MeshInstance2D
	var border_mesh := border.mesh as QuadMesh if border != null else null
	var border_material := border.material as ShaderMaterial if border != null else null
	_expect(
		border != null
		and border_mesh != null
		and border_mesh.size == Vector2(32, 32)
		and border_material != null
		and border_material.shader.resource_path
		== "res://resources/shader/plant_cultivation_center_border.gdshader",
		"培育中心必须使用32×32方形绿色噪波边框。"
	)
	if border_material != null:
		var idle_green: Color = border_material.get_shader_parameter(&"idle_green")
		var progress_green: Color = border_material.get_shader_parameter(
			&"progress_green"
		)
		_expect(
			progress_green.get_luminance() > idle_green.get_luminance() + 0.2,
			"工作进度必须使用明显亮于默认深绿色的嫩绿色。"
		)
	_test_world_glow_contract(center, config, day_night_controller)

	var run_state := root.get_node("RunState") as RunStateStore
	run_state.begin_new_run(&"weishidaier", false)
	_expect(
		warehouse.try_add_storage_item_count(WOODEN_CORE, 1)
		and center.select_recipe(&"wooden_core_to_agave_cannon"),
		"培育测试必须能准备木制核心并选择加农炮配方。"
	)
	center.advance_shared_production_tick(20.0)
	_expect(
		coordinator.get_total_item_count(WOODEN_CORE) == 0
		and coordinator.get_total_item_count(AGAVE_BUILDING_ITEM) == 1
		and run_state.get_inventory_item_total(AGAVE_BUILDING_ITEM) == 0
		and is_zero_approx(center.progress_elapsed_seconds),
		"单人完成配方时必须原子扣除木制核心并把加农炮建筑物品放入共享仓库。"
	)
	_expect(
		warehouse.try_add_storage_item_count(WOODEN_CORE, 2),
		"堆叠测试必须能准备两个木制核心。"
	)
	center.advance_shared_production_tick(20.0)
	center.advance_shared_production_tick(20.0)
	_expect(
		coordinator.get_total_item_count(AGAVE_BUILDING_ITEM) == 3
		and run_state.get_inventory_item_total(AGAVE_BUILDING_ITEM) == 0,
		"连续完成的相同建筑产物必须全部留在共享仓库，不得写入玩家背包。"
	)
	_expect(
		warehouse.try_add_storage_item_count(WOODEN_CORE, 1)
		and center.select_recipe(&"wooden_core_to_corn_machine_gun"),
		"培育测试必须能切换至玉米机枪塔配方。"
	)
	center.advance_shared_production_tick(20.0)
	_expect(
		coordinator.get_total_item_count(CORN_BUILDING_ITEM) == 1
		and run_state.get_inventory_item_total(CORN_BUILDING_ITEM) == 0,
		"玉米机枪塔必须作为建筑物品进入共享仓库。"
	)
	_expect(
		not center.select_recipe(&"wooden_core_to_bamboo_mortar")
		and not center.select_recipe(&"wooden_core_to_hydrangea_rain_tower")
		and not center.select_recipe(&"wooden_core_to_orange_charging_tower"),
		"竹筒、紫阳花与橘充能塔培育必须在各自科研完成前保持锁定。"
	)
	completed_research_ids[
		GlobalResearchRegistry.BAMBOO_MORTAR_CRAFTING_ID
	] = true
	_expect(
		warehouse.try_add_storage_item_count(WOODEN_CORE, 1)
		and center.select_recipe(&"wooden_core_to_bamboo_mortar"),
		"培育测试必须能切换至竹筒迫击炮配方。"
	)
	center.advance_shared_production_tick(29.0)
	_expect(
		coordinator.get_total_item_count(BAMBOO_MORTAR_BUILDING_ITEM) == 0
		and is_equal_approx(center.progress_elapsed_seconds, 29.0),
		"迫击炮培育到29秒时不得提前完成。"
	)
	center.advance_shared_production_tick(1.0)
	_expect(
		coordinator.get_total_item_count(BAMBOO_MORTAR_BUILDING_ITEM) == 1
		and run_state.get_inventory_item_total(BAMBOO_MORTAR_BUILDING_ITEM) == 0
		and is_zero_approx(center.progress_elapsed_seconds),
		"迫击炮必须在累计30秒时完成并进入共享仓库。"
	)
	_expect(
		not center.select_recipe(&"wooden_core_to_hydrangea_rain_tower")
		and not center.select_recipe(&"wooden_core_to_orange_charging_tower"),
		"完成竹筒科研不得顺带解锁紫阳花或橘充能塔培育。"
	)
	completed_research_ids[
		GlobalResearchRegistry.HYDRANGEA_RAIN_TOWER_CRAFTING_ID
	] = true
	_expect(
		warehouse.try_add_storage_item_count(WOODEN_CORE, 2)
		and warehouse.try_add_storage_item_count(WATER_BOTTLE, 2)
		and center.select_recipe(&"wooden_core_to_hydrangea_rain_tower"),
		"培育测试必须能准备2个木制核心和2个水瓶并切换至紫阳花雨幕塔配方。"
	)
	center.advance_shared_production_tick(29.0)
	_expect(
		coordinator.get_total_item_count(HYDRANGEA_RAIN_TOWER_BUILDING_ITEM) == 0
		and is_equal_approx(center.progress_elapsed_seconds, 29.0),
		"紫阳花雨幕塔培育到29秒时不得提前完成。"
	)
	center.advance_shared_production_tick(1.0)
	_expect(
		coordinator.get_total_item_count(HYDRANGEA_RAIN_TOWER_BUILDING_ITEM) == 1
		and run_state.get_inventory_item_total(
			HYDRANGEA_RAIN_TOWER_BUILDING_ITEM
		) == 0
		and warehouse.get_storage_item_total(WOODEN_CORE) == 0
		and warehouse.get_storage_item_total(WATER_BOTTLE) == 0
		and is_zero_approx(center.progress_elapsed_seconds),
		"紫阳花雨幕塔必须在累计30秒时原子消费两种材料并进入共享仓库。"
	)
	_expect(
		not center.select_recipe(&"wooden_core_to_orange_charging_tower"),
		"完成紫阳花科研不得顺带解锁橘充能塔培育。"
	)
	completed_research_ids[
		GlobalResearchRegistry.ORANGE_CHARGING_TOWER_CRAFTING_ID
	] = true
	_expect(
		warehouse.try_add_storage_item_count(WOODEN_CORE, 1)
		and warehouse.try_add_storage_item_count(SORCERER_VIOLET_POWDER, 1)
		and center.select_recipe(&"wooden_core_to_orange_charging_tower"),
		"培育测试必须能准备木制核心和术士紫晶粉并切换至橘充能塔配方。"
	)
	center.advance_shared_production_tick(29.0)
	_expect(
		coordinator.get_total_item_count(ORANGE_CHARGING_TOWER_BUILDING_ITEM) == 0
		and is_equal_approx(center.progress_elapsed_seconds, 29.0),
		"橘充能塔培育到29秒时不得提前完成。"
	)
	center.advance_shared_production_tick(1.0)
	_expect(
		coordinator.get_total_item_count(ORANGE_CHARGING_TOWER_BUILDING_ITEM) == 1
		and run_state.get_inventory_item_total(
			ORANGE_CHARGING_TOWER_BUILDING_ITEM
		) == 0
		and warehouse.get_storage_item_total(WOODEN_CORE) == 0
		and warehouse.get_storage_item_total(SORCERER_VIOLET_POWDER) == 0
		and is_zero_approx(center.progress_elapsed_seconds),
		"橘充能塔必须在累计30秒时原子消费两种材料并进入共享仓库。"
	)
	_expect(
		run_state.try_add_item(AGAVE_BUILDING_ITEM),
		"背包详情夹具必须显式准备一个加农炮建筑物品。"
	)
	var profile_panel := (
		PROFILE_PANEL_SCENE.instantiate() as TowerDefensePlayerProfilePanel
	)
	test_root.add_child(profile_panel)
	await process_frame
	profile_panel.bind_player(player)
	profile_panel.open()
	profile_panel.call("_on_slot_selected", 0)
	await process_frame
	_expect(
		profile_panel.item_detail_category_label.text == "建筑"
		and profile_panel.item_detail_use_button.visible
		and profile_panel.item_detail_use_button.text == "建造"
		and profile_panel.item_detail_discard_button.text == "销毁"
		and profile_panel.item_detail_hint.text.contains("建造模式"),
		"背包详情必须把建筑物品标为“建筑”，并提供“建造”和“销毁”操作。"
	)
	var detail_rect := profile_panel.item_detail_panel.get_global_rect()
	var title_rect := profile_panel.item_detail_title.get_global_rect()
	var category_rect := (
		profile_panel.item_detail_category_backing.get_global_rect()
	)
	var use_button_rect := profile_panel.item_detail_use_button.get_global_rect()
	var discard_button_rect := (
		profile_panel.item_detail_discard_button.get_global_rect()
	)
	_expect(
		title_rect.position.x - detail_rect.position.x >= 17.0
		and detail_rect.end.x - category_rect.end.x >= 17.0
		and title_rect.position.y - detail_rect.position.y >= 16.0,
		"建筑详情标题和类别标记必须避开装饰边框的文字安全区。"
	)
	_expect(
		use_button_rect.position.x - detail_rect.position.x >= 25.0
		and detail_rect.end.x - discard_button_rect.end.x >= 25.0
		and detail_rect.end.y - use_button_rect.end.y >= 19.0
		and detail_rect.end.y - discard_button_rect.end.y >= 19.0,
		"建筑详情操作按钮必须与面板四周保留稳定安全距离。"
	)
	profile_panel.close()
	profile_panel.queue_free()

	run_state.register_multiplayer_peer_state(2)
	coordinator.configure_multiplayer_output_peers([2])
	var committed_peer_ids: Array[int] = []
	coordinator.personal_inventory_output_committed.connect(
		func(peer_id: int) -> void: committed_peer_ids.append(peer_id)
	)
	var agave_storage_total_before := coordinator.get_total_item_count(
		AGAVE_BUILDING_ITEM
	)
	_expect(
		warehouse.try_add_storage_item_count(WOODEN_CORE, 1)
		and center.select_recipe(&"wooden_core_to_agave_cannon", 2),
		"联机权威建筑必须能选择共享仓库产物配方。"
	)
	center.advance_shared_production_tick(20.0)
	_expect(
		coordinator.get_total_item_count(AGAVE_BUILDING_ITEM)
		== agave_storage_total_before + 1
		and run_state.get_inventory_item_total_for_peer(
			2,
			AGAVE_BUILDING_ITEM
		) == 0
		and committed_peer_ids.is_empty()
		and center.personal_output_peer_id == 0,
		"联机建筑产物必须进入共享仓库，不得绑定或写入选择者背包。"
	)
	var runtime_state := center.export_multiplayer_runtime_state()
	_expect(
		int(runtime_state.get("schema", 0))
		== ProductionBuilding.RUNTIME_STATE_SCHEMA
		and int(runtime_state.get("personal_output_peer_id", 0)) == 0,
		"共享仓库产物的权威状态不得携带个人产物接收者。"
	)
	coordinator.configure_local_output_peer()

	panel.open_for(center, player)
	await process_frame
	var progress_fill := panel.progress_bar.get_theme_stylebox(
		"fill"
	) as StyleBoxFlat
	var recipe_rows_container := panel.recipe_rows[0].get_parent() as VBoxContainer
	_expect(
		panel.background.texture != null
		and panel.background.texture.resource_path
		== "res://resources/texture/production/plant_cultivation_center_panel_background.png"
		and panel.background.texture.get_size() == Vector2(728, 544)
		and panel.output_title.text == "仓库产物"
		and panel.input_slots[0].visible
		and not panel.input_slots[1].visible
		and not panel.input_slots[2].visible
		and panel.output_slots[0].visible
		and not panel.output_slots[1].visible
		and not panel.output_slots[2].visible
		and panel.recipe_rows[0].visible
		and panel.recipe_rows[0].tooltip_text.contains("约 20.0 秒")
		and panel.recipe_rows[1].visible
		and panel.recipe_rows[1].tooltip_text.contains("约 20.0 秒")
		and panel.recipe_rows[2].visible
		and panel.recipe_rows[2].tooltip_text.contains("约 30.0 秒")
		and panel.recipe_rows[3].visible
		and panel.recipe_rows[3].tooltip_text.contains("约 30.0 秒")
		and panel.recipe_rows[4].visible
		and panel.recipe_rows[4].tooltip_text.contains("约 40.0 秒")
		and panel.recipe_rows[5].visible
		and panel.recipe_rows[5].tooltip_text.contains("约 30.0 秒")
		and not panel.recipe_rows[6].visible
		and not panel.recipe_rows[7].visible
		and not panel.recipe_rows[8].visible
		and not panel.recipe_rows[9].visible
		and progress_fill != null
		and progress_fill.bg_color.g > 0.75,
		"培育中心UI必须使用植物面板、嫩绿进度条，并只显示六条耗时正确的培育配方。"
	)
	_expect(
		panel.building_title.position == Vector2(96.0, 23.0)
		and panel.building_title.size == Vector2(536.0, 39.0)
		and is_equal_approx(
			panel.building_title.position.x + panel.building_title.size.x * 0.5,
			364.0
		)
		and panel.recipe_title.position == Vector2(504.0, 112.0)
		and panel.recipe_title.size == Vector2(180.0, 31.0)
		and is_equal_approx(
			panel.recipe_title.position.x + panel.recipe_title.size.x * 0.5,
			594.0
		),
		"培育中心主标题和配方标题必须分别对齐背景徽章与右栏中心。"
	)
	_expect(
		panel.recipe_scroll.position == Vector2(504.0, 151.0)
		and panel.recipe_scroll.size == Vector2(180.0, 270.0)
		and panel.recipe_scroll.clip_contents
		and panel.recipe_scroll.follow_focus
		and panel.recipe_scroll.horizontal_scroll_mode
			== ScrollContainer.SCROLL_MODE_DISABLED
		and not panel.recipe_scroll.get_h_scroll_bar().visible
		and recipe_rows_container != null
		and recipe_rows_container.custom_minimum_size.x == 0.0
		and recipe_rows_container.size_flags_horizontal
			== Control.SIZE_EXPAND_FILL,
		"培育中心配方滚动区必须完整收进右栏，禁止横滚并让内容横向填满。"
	)
	var recipe_scroll_rect := panel.recipe_scroll.get_global_rect()
	for row_index in 3:
		var row := panel.recipe_rows[row_index]
		_expect(
			row.visible
			and row.custom_minimum_size == Vector2(0.0, 72.0)
			and row.size_flags_horizontal == Control.SIZE_EXPAND_FILL
			and row.clip_text
			and row.autowrap_mode == TextServer.AUTOWRAP_WORD_SMART
			and recipe_scroll_rect.encloses(row.get_global_rect()),
			"培育中心第%d条配方必须换行收缩且不得越出滚动区。"
			% (row_index + 1)
		)
	for row_index in center.recipes.size():
		var row := panel.recipe_rows[row_index]
		var recipe := center.recipes[row_index]
		_expect(
			row.get_theme_constant("icon_max_width") == 34
			and row.icon == recipe.output_items[0].icon_texture,
			"培育中心第%d条配方必须使用原生主题上限将产物图标限制为34像素宽。"
			% (row_index + 1)
		)
	var icon_size_probe_row := panel.recipe_rows[0]
	var original_probe_icon := icon_size_probe_row.icon
	icon_size_probe_row.icon = AGAVE_BUILDING_ITEM.icon_texture
	await process_frame
	var icon_64_row_minimum := icon_size_probe_row.get_minimum_size()
	icon_size_probe_row.icon = HYDRANGEA_RAIN_TOWER_BUILDING_ITEM.icon_texture
	await process_frame
	var icon_128_row_minimum := icon_size_probe_row.get_minimum_size()
	icon_size_probe_row.icon = original_probe_icon
	_expect(
		icon_128_row_minimum == icon_64_row_minimum,
		"128×128的紫阳花与橘充能塔图标必须额外二分之一缩放，不得撑大配方行。"
	)
	_expect(
		panel.recipe_rows[0].text
			== "培育龙舌兰加农炮\n木制核心 ×1 · 20秒"
		and panel.recipe_rows[1].text
			== "培育玉米机枪塔\n木制核心 ×1 · 20秒"
		and panel.recipe_rows[2].text
			== "培育竹筒迫击炮\n木制核心 ×1 · 30秒"
		and panel.recipe_rows[3].text
			== "培育紫阳花雨幕塔\n2 种原料 · 30秒"
		and panel.recipe_rows[4].text
			== "培育葡萄电弧塔\n3 种原料 · 40秒"
		and panel.recipe_rows[5].text
			== "培育橘充能塔\n2 种原料 · 30秒",
		"建筑产物配方摘要必须只显示投入与耗时，避免在窄栏重复长产物名。"
	)
	_expect(
		panel.progress_label.position == Vector2(165.0, 314.0)
		and panel.progress_label.size == Vector2(180.0, 34.0)
		and panel.progress_label.autowrap_mode
			== TextServer.AUTOWRAP_WORD_SMART
		and not panel.progress_label.clip_text
		and panel.status_label.position == Vector2(61.0, 420.0)
		and panel.status_label.size == Vector2(392.0, 48.0)
		and panel.status_label.position.y + panel.status_label.size.y <= 468.0
		and panel.close_button.position == Vector2(540.0, 431.0)
		and panel.close_button.size == Vector2(108.0, 37.0)
		and is_equal_approx(
			panel.close_button.position.x + panel.close_button.size.x * 0.5,
			594.0
		)
		and panel.close_button.position.y + panel.close_button.size.y <= 468.0,
		"培育中心进度、状态与关闭控件必须完整落在各自背景安全区。"
	)
	await _click_panel_control(panel.recipe_rows[1])
	_expect(
		root.gui_get_hovered_control() == panel.recipe_rows[1]
		and center.active_recipe_id == &"wooden_core_to_corn_machine_gun"
		and panel.recipe_rows[1].button_pressed,
		"真实点击右栏可见配方必须命中按钮并切换培育方案。"
	)
	await _click_panel_control(panel.close_button)
	_expect(
		not panel.is_open()
		and not panel.visible
		and not player.controls_locked,
		"真实点击培育中心关闭按钮必须关闭面板并恢复玩家控制。"
	)
	panel.close()

	_test_asset_contracts()
	await _test_inventory_placement_request(test_root, config, run_state)
	_test_authoritative_placement_rollback_sync(
		PlantDefenseRegistry.get_config(&"agave_cannon"),
		run_state,
		player
	)
	_finish(test_root)


func _test_world_glow_contract(
	center: PlantCultivationCenter,
	config: PlantDefenseConfig,
	day_night_controller: DayNightController
) -> void:
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
	var hotspot_glow := (
		center.get_node_or_null(
			"HotspotGlow"
		) as NightPointLight2D
	)
	var authored_lights: Array[Node] = center.find_children(
		"*",
		"Light2D",
		true,
		false
	)
	_expect(
		visual_root != null
		and visual_root.scale == Vector2(0.5, 0.5)
		and lower_sprite != null
		and upper_sprite != null
		and lower_sprite.z_index == 0
		and upper_sprite.z_index == 4
		and lower_sprite.texture_filter
		== CanvasItem.TEXTURE_FILTER_NEAREST
		and upper_sprite.texture_filter
		== CanvasItem.TEXTURE_FILTER_NEAREST
		and center.lifecycle_visual_paths
		== [
			NodePath("VisualRoot/LowerBody"),
			NodePath("VisualRoot/UpperForeground"),
		]
		and center.get_node_or_null("VisualRoot/GlowOverlay") == null,
		"培育中心必须以z=0下层与z=4立体前景分层，且两层保持0.5整数缩放和nearest采样。"
	)
	_expect(
		hotspot_glow != null
		and authored_lights.size() == 1
		and hotspot_glow.texture == HOTSPOT_LIGHT_TEXTURE
		and hotspot_glow.color.is_equal_approx(
			Color(0.4814815, 1.0, 0.1666667, 1.0)
		)
		and HOTSPOT_LIGHT_TEXTURE.get_size() == Vector2(256, 256)
		and is_equal_approx(hotspot_glow.texture_scale, 0.25)
		and is_equal_approx(hotspot_glow.night_energy, 0.84)
		and not hotspot_glow.shadow_enabled
		and hotspot_glow.visible
		and hotspot_glow.is_visible_in_tree()
		and hotspot_glow.is_emission_allowed()
		and hotspot_glow.get("_controller") == day_night_controller
		and hotspot_glow.enabled
		and is_equal_approx(hotspot_glow.energy, 0.84),
		"五处亮核必须共用一盏可见、已绑定昼夜系统且强度足够的嫩绿色夜间PointLight2D。"
	)
	_expect(
		lower_material != null
		and upper_material != null
		and not lower_material.resource_local_to_scene
		and not upper_material.resource_local_to_scene
		and lower_material.shader == upper_material.shader
		and lower_material.shader.resource_path
		== "res://resources/shader/plant_cultivation_center_lifecycle_glow.gdshader"
		and is_equal_approx(
			float(
				lower_material.get_shader_parameter(
					&"glow_pulse_amount"
				)
			),
			0.006
		)
		and (
			lower_material.get_shader_parameter(&"glow_color") as Color
		).g > 1.0
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
		"培育中心上下层必须共享嫩草绿HDR Shader，透明晕光只能由下层绘制。"
	)
	var second_center := (
		config.plant_scene.instantiate() as PlantCultivationCenter
	)
	if second_center != null:
		var second_lower := second_center.get_node_or_null(
			"VisualRoot/LowerBody"
		) as Sprite2D
		var second_upper := second_center.get_node_or_null(
			"VisualRoot/UpperForeground"
		) as Sprite2D
		var second_hotspot_glow := (
			second_center.get_node_or_null(
				"HotspotGlow"
			) as NightPointLight2D
		)
		_expect(
			second_lower != null
			and second_upper != null
			and second_lower.material == lower_material
			and second_upper.material == upper_material,
			"多个培育中心的上下层必须分别共享同一不可变ShaderMaterial。"
		)
		_expect(
			second_hotspot_glow != null
			and not second_hotspot_glow.starts_emitting,
			"未完成建造的培育中心热点灯必须默认禁止发光。"
		)
		second_center.free()
	center.call("_on_construction_started")
	_expect(
		hotspot_glow != null
		and not hotspot_glow.is_emission_allowed()
		and not hotspot_glow.enabled
		and is_zero_approx(hotspot_glow.energy),
		"培育中心建造期间必须关闭五热点环境微光。"
	)
	center.call("_on_construction_finished", false)
	_expect(
		hotspot_glow != null
		and hotspot_glow.is_emission_allowed()
		and hotspot_glow.enabled
		and is_equal_approx(hotspot_glow.energy, 0.84),
		"培育中心建造完成后必须恢复五热点环境微光。"
	)
	var shader_source := FileAccess.get_file_as_string(
		"res://resources/shader/plant_cultivation_center_lifecycle_glow.gdshader"
	)
	var hotspot_texture_source := FileAccess.get_file_as_string(
		"res://resources/lighting/plant_cultivation_center_hotspots.svg"
	)
	_expect(
		shader_source.contains(
			"small_light_core(pixel_position, vec2(32.0, 12.0))"
		)
		and shader_source.contains(
			"small_light_core(pixel_position, vec2(10.0, 32.0))"
		)
		and shader_source.contains(
			"small_light_core(pixel_position, vec2(54.0, 32.0))"
		)
		and shader_source.contains(
			"small_light_core(pixel_position, vec2(22.0, 40.0))"
		)
		and shader_source.contains(
			"pixel_position - vec2(32.5, 52.5)"
		)
		and not shader_source.contains("vec2(42.0, 40.0)"),
		"微光遮罩必须严格对应截图圈出的顶部、左右立柱、左内侧与底部面板五处。"
	)
	_expect(
		hotspot_texture_source.count("<circle ") == 5
		and hotspot_texture_source.contains(
			"cx=\"32\" cy=\"22\" r=\"8\""
		)
		and hotspot_texture_source.contains(
			"cx=\"21\" cy=\"32\" r=\"7.5\""
		)
		and hotspot_texture_source.contains(
			"cx=\"43\" cy=\"32\" r=\"7.5\""
		)
		and hotspot_texture_source.contains(
			"cx=\"27\" cy=\"36\" r=\"6.25\""
		)
		and hotspot_texture_source.contains(
			"cx=\"32.25\" cy=\"42.25\" r=\"9.5\""
		),
		"单灯纹理必须保持五处亮核坐标，并使用扩大的嫩绿扩散半径。"
	)
	_expect(
		shader_source.contains("vec4 result = COLOR")
		and shader_source.contains(
			"instance uniform float construction_progress"
		)
		and shader_source.contains("instance uniform bool removal_enabled")
		and shader_source.contains("uniform sampler2D lifecycle_noise")
		and shader_source.contains("varying float glow_pulse")
		and shader_source.contains(
			"glow_pulse_amount * sin("
		),
		"专用发光Shader必须完整保留建造/拆除生命周期，并在顶点阶段计算极弱呼吸。"
	)


func _test_asset_contracts() -> void:
	var building_texture := load(
		"res://resources/texture/plant_defense/plant_cultivation_center/plant_cultivation_center.png"
	) as Texture2D
	_expect(
		building_texture != null
		and building_texture.get_size() == Vector2(64, 64),
		"培育中心正式世界素材必须为64×64。"
	)
	for item in [
		AGAVE_BUILDING_ITEM,
		CORN_BUILDING_ITEM,
		BAMBOO_MORTAR_BUILDING_ITEM,
	]:
		var plant_config := PlantDefenseRegistry.get_config(
			item.placeable_plant_id
		)
		_expect(
			plant_config != null
			and item.icon_texture != null
			and item.icon_texture.resource_path
			== plant_config.icon.resource_path
			and item.icon_texture.get_size() == Vector2(64, 64)
			and item.icon_scale == Vector2(0.5, 0.5)
			and item.icon_texture.get_size() * item.icon_scale
			== Vector2(32, 32),
			"2×2建筑物品必须复用64×64原图，并以0.5缩放符合32×32显示规范。"
		)
	for item in [
		HYDRANGEA_RAIN_TOWER_BUILDING_ITEM,
		ORANGE_CHARGING_TOWER_BUILDING_ITEM,
	]:
		var plant_config := PlantDefenseRegistry.get_config(
			item.placeable_plant_id
		)
		_expect(
			plant_config != null
			and item.icon_texture != null
			and item.icon_texture.resource_path
			== plant_config.icon.resource_path
			and item.icon_texture.get_size() == Vector2(128, 128)
			and item.icon_scale == Vector2(0.25, 0.25)
			and item.icon_texture.get_size() * item.icon_scale
			== Vector2(32, 32),
			"128×128建筑物品必须复用原图，并以0.25整数倍缩放到32×32。"
		)
	var image_path := ProjectSettings.globalize_path(
		"res://resources/texture/plant_defense/plant_cultivation_center/plant_cultivation_center.png"
	)
	var image := Image.load_from_file(image_path)
	var bbox := image.get_used_rect()
	_expect(
		image.get_size() == Vector2i(64, 64)
		and bbox.size.x <= 60
		and bbox.size.y <= 60,
		"培育中心非透明主体不得超过60×60视觉像素。"
	)


func _test_inventory_placement_request(
	test_root: Node,
	config: PlantDefenseConfig,
	run_state: RunStateStore
) -> void:
	run_state.begin_new_run(&"weishidaier", false)
	_expect(
		run_state.try_add_item_count(AGAVE_BUILDING_ITEM, 2),
		"放置测试必须能加入2个加农炮建筑物品。"
	)
	_expect(
		run_state.get_item(0) == AGAVE_BUILDING_ITEM
		and run_state.get_item_count(0) == 2
		and run_state.get_item(1) == null,
		"相同建筑物品必须合并到同一个999上限背包堆栈。"
	)
	var initial_revision := run_state.get_inventory_revision()
	_expect(
		run_state.try_consume_item_at_slot_if_revision(
			0,
			AGAVE_BUILDING_ITEM,
			initial_revision
		)
		and run_state.get_item(0) == AGAVE_BUILDING_ITEM
		and run_state.get_item_count(0) == 1
		and not run_state.try_consume_item_at_slot_if_revision(
			0,
			AGAVE_BUILDING_ITEM,
			initial_revision
		),
		"建造一个建筑必须只把同槽堆栈从2减到1，并拒绝过期背包revision。"
	)
	run_state.begin_new_run(&"weishidaier", false)
	_expect(
		run_state.try_add_item_count(AGAVE_BUILDING_ITEM, 3),
		"连续放置请求测试必须准备3个加农炮建筑物品。"
	)

	var controller := (
		PLACEMENT_CONTROLLER_SCENE.instantiate() as PlantPlacementController
	)
	var plant_system := PlantSystem.new()
	var placement_owner := PLAYER_SCENE.instantiate() as Player
	test_root.add_child(plant_system)
	test_root.add_child(placement_owner)
	test_root.add_child(controller)
	await process_frame
	placement_owner.set_process(false)
	placement_owner.set_physics_process(false)
	controller.setup(plant_system, placement_owner)
	controller.configure_inventory_catalog(run_state, null, 0, false)
	var requests: Array[Dictionary] = []
	var lock_events: Array[bool] = []
	var unavailable_events: Array[bool] = []
	controller.player_lock_requested.connect(
		func(locked: bool) -> void: lock_events.append(locked)
	)
	controller.selection_unavailable.connect(
		func() -> void: unavailable_events.append(true)
	)
	controller.inventory_placement_requested.connect(
		func(
			request_id: int,
			plant_id: StringName,
			anchor: Vector2i,
			slot_index: int,
			expected_revision: int,
			item_config_path: String
		) -> void:
			requests.append({
				"request_id": request_id,
				"plant_id": plant_id,
				"anchor": anchor,
				"slot_index": slot_index,
				"expected_revision": expected_revision,
				"item_config_path": item_config_path,
			})
	)
	var agave_config := PlantDefenseRegistry.get_config(&"agave_cannon")
	var current_revision := run_state.get_inventory_revision()
	var shift_click := InputEventMouseButton.new()
	shift_click.button_index = MOUSE_BUTTON_LEFT
	shift_click.pressed = true
	shift_click.shift_pressed = true
	var normal_click := InputEventMouseButton.new()
	normal_click.button_index = MOUSE_BUTTON_LEFT
	normal_click.pressed = true
	var bare_shift := InputEventKey.new()
	bare_shift.keycode = KEY_SHIFT
	bare_shift.pressed = true
	var plant_key := InputEventKey.new()
	plant_key.physical_keycode = KEY_T
	plant_key.pressed = true
	_expect(
		PlantPlacementController._is_shift_modifier_event(bare_shift)
		and not PlantPlacementController._is_shift_modifier_event(
			plant_key
		),
		"放置态只能保留裸Shift修饰键，普通T仍必须保持植物键取消语义。"
	)
	_expect(
		controller.begin_inventory_placement(
			agave_config,
			0,
			current_revision,
			AGAVE_BUILDING_ITEM.resource_path
		),
		"背包建筑物品必须能绕过T键选择页直接进入指定建筑放置模式。"
	)
	var added_shift_binding := not InputMap.action_has_event(&"plant", bare_shift)
	if added_shift_binding:
		InputMap.action_add_event(&"plant", bare_shift)
	controller.call("_unhandled_input", bare_shift)
	if added_shift_binding:
		InputMap.action_erase_event(&"plant", bare_shift)
	_expect(
		controller.is_placing() and requests.is_empty(),
		"即使裸Shift被绑定为植物键，放置态也只能把它当作连续放置修饰键。"
	)
	controller.has_hovered_anchor = true
	controller.hovered_anchor = Vector2i(3, 4)
	controller.call("_unhandled_input", shift_click)
	_expect(
		requests.size() == 1
		and requests[0]["plant_id"] == &"agave_cannon"
		and requests[0]["anchor"] == Vector2i(3, 4)
		and int(requests[0]["slot_index"]) == 0
		and int(requests[0]["expected_revision"]) == current_revision
		and requests[0]["item_config_path"]
		== AGAVE_BUILDING_ITEM.resource_path
		and controller.is_placing()
		and controller.has_pending_placement_request()
		and controller.get_pending_placement_request_id()
		== int(requests[0]["request_id"])
		and controller.placement_hint_label.text.contains("等待放置确认")
		and run_state.get_item_count(0) == 3,
		"Shift左键必须只发送一个权威请求，保留放置态且不得预扣物品。"
	)
	controller.call("_unhandled_input", shift_click)
	_expect(requests.size() == 1, "权威回执前的重复点击不得产生第二个放置请求。")
	if requests.size() != 1:
		controller.cancel_placement()
		return

	var first_request_id := int(requests[0]["request_id"])
	controller.notify_placement_succeeded(first_request_id + 1)
	_expect(
		controller.get_pending_placement_request_id() == first_request_id
		and controller.placement_hint_label.text.contains("等待放置确认"),
		"本地玩家的错误request_id也不得误确认当前连续放置。"
	)
	controller.notify_placement_succeeded(first_request_id)
	_expect(
		controller.has_pending_placement_request()
		and controller.placement_hint_label.text.contains("等待物品同步"),
		"生成回执早于背包同步时必须继续等待，不得复用旧revision。"
	)
	_expect(
		run_state.try_consume_item_at_slot_if_revision(
			0,
			AGAVE_BUILDING_ITEM,
			current_revision
		),
		"首次连续放置必须能模拟权威扣除一个物品。"
	)
	current_revision = run_state.get_inventory_revision()
	_expect(
		controller.is_placing()
		and not controller.has_pending_placement_request()
		and controller.inventory_expected_revision == current_revision
		and run_state.get_item_count(0) == 2,
		"背包同步到达后必须更新revision并恢复同建筑连续放置。"
	)

	controller.has_hovered_anchor = true
	controller.hovered_anchor = Vector2i(4, 4)
	controller.call("_unhandled_input", shift_click)
	_expect(
		requests.size() == 2
		and int(requests[1]["expected_revision"]) == current_revision,
		"第二次连续放置必须携带首次扣除后的新revision。"
	)
	if requests.size() != 2:
		controller.cancel_placement()
		return
	var second_request_id := int(requests[1]["request_id"])
	_expect(
		run_state.try_consume_item_at_slot_if_revision(
			0,
			AGAVE_BUILDING_ITEM,
			current_revision
		),
		"第二次连续放置必须能先到达背包同步。"
	)
	_expect(
		controller.has_pending_placement_request(),
		"背包同步早于生成回执时不得提前解锁下一次点击。"
	)
	controller.notify_placement_succeeded(second_request_id)
	current_revision = run_state.get_inventory_revision()
	_expect(
		controller.is_placing()
		and not controller.has_pending_placement_request()
		and controller.inventory_expected_revision == current_revision
		and run_state.get_item_count(0) == 1,
		"生成回执到达后必须与先到的背包同步汇合，且只解锁一次。"
	)

	controller.has_hovered_anchor = true
	controller.hovered_anchor = Vector2i(5, 4)
	controller.call("_unhandled_input", shift_click)
	_expect(requests.size() == 3, "第三次连续放置必须且只能发送第三个权威请求。")
	if requests.size() != 3:
		controller.cancel_placement()
		return
	var third_request_id := int(requests[2]["request_id"])
	_expect(
		run_state.try_consume_item_at_slot_if_revision(
			0,
			AGAVE_BUILDING_ITEM,
			current_revision
		),
		"第三次连续放置必须耗尽最后一个物品。"
	)
	controller.notify_placement_succeeded(third_request_id)
	_expect(
		requests.size() == 3
		and not controller.is_active()
		and not controller.has_pending_placement_request()
		and run_state.get_item_count(0) == 0
		and not lock_events.is_empty()
		and not lock_events.back(),
		"第三次成功后资源耗尽必须自动退出并解除玩家控制锁。"
	)
	_expect(
		controller.pending_placement_timeout.one_shot
		and is_equal_approx(controller.pending_placement_timeout.wait_time, 5.0),
		"连续放置必须使用场景内一次性5秒超时Timer。"
	)

	run_state.begin_new_run(&"weishidaier", false)
	_expect(run_state.try_add_item(AGAVE_BUILDING_ITEM), "普通放置回归测试必须准备1个建筑物品。")
	current_revision = run_state.get_inventory_revision()
	_expect(
		controller.begin_inventory_placement(
			agave_config,
			0,
			current_revision,
			AGAVE_BUILDING_ITEM.resource_path
		),
		"普通放置回归测试必须进入放置态。"
	)
	controller.has_hovered_anchor = true
	controller.hovered_anchor = Vector2i(6, 4)
	controller.call("_unhandled_input", normal_click)
	_expect(
		requests.size() == 4
		and not controller.is_active()
		and not controller.has_pending_placement_request()
		and run_state.get_item_count(0) == 1,
		"普通左键必须继续在提交前退出，且不得自行预扣物品。"
	)

	var right_click := InputEventMouseButton.new()
	right_click.button_index = MOUSE_BUTTON_RIGHT
	right_click.pressed = true
	var escape_key := InputEventKey.new()
	escape_key.keycode = KEY_ESCAPE
	escape_key.pressed = true
	for resolution in [
		&"cancel",
		&"reject",
		&"timeout",
		&"right_click",
		&"escape",
		&"plant_key",
		&"owner_unavailable",
		&"input_disabled",
	]:
		var began_pending_case := controller.begin_inventory_placement(
				agave_config,
				0,
				current_revision,
				AGAVE_BUILDING_ITEM.resource_path
			)
		_expect(
			began_pending_case,
			"迟到回执测试必须重新进入放置态。"
		)
		if not began_pending_case:
			return
		controller.has_hovered_anchor = true
		controller.hovered_anchor = Vector2i(7 + requests.size(), 4)
		var request_count_before := requests.size()
		controller.call("_unhandled_input", shift_click)
		var pending_id := controller.get_pending_placement_request_id()
		var pending_started := (
			requests.size() == request_count_before + 1
			and pending_id > 0
			and int(requests.back()["request_id"]) == pending_id
			and not controller.pending_placement_timeout.is_stopped()
		)
		_expect(
			pending_started,
			"每个中断场景都必须先真实发送一次Shift请求并启动pending超时：%s" % resolution
		)
		if not pending_started:
			controller.cancel_placement()
			break
		match resolution:
			&"cancel":
				controller.cancel_placement()
			&"reject":
				controller.notify_multiplayer_placement_rejected(pending_id)
				controller.notify_multiplayer_placement_rejected(pending_id)
			&"timeout":
				controller.pending_placement_timeout.timeout.emit()
			&"right_click":
				controller.call("_unhandled_input", right_click)
			&"escape":
				controller.call("_unhandled_input", escape_key)
			&"plant_key":
				controller.call("_unhandled_input", plant_key)
			&"owner_unavailable":
				placement_owner.died.emit()
			&"input_disabled":
				controller.set_placement_input_enabled(false)
				controller.set_placement_input_enabled(true)
		controller.notify_placement_succeeded(pending_id)
		_expect(
			not controller.is_active()
			and not controller.has_pending_placement_request()
			and controller.pending_placement_timeout.is_stopped()
			and not lock_events.is_empty()
			and not lock_events.back(),
			"取消、拒绝、超时或流程中断后的迟到回执不得恢复放置或残留控制锁：%s" % resolution
		)
		if controller.is_active():
			controller.cancel_placement()
	_expect(unavailable_events.size() == 2, "拒绝与超时必须各提示一次放置不可用。")
	_expect(
		controller.open_selection()
		and controller.selection_hud.available_configs.size() == 19
		and controller.selection_hud.available_configs.has(
			PlantDefenseRegistry.get_config(&"excavator")
		)
		and controller.selection_hud.available_configs.has(
			PlantDefenseRegistry.get_config(&"stone_mill")
		)
		and controller.selection_hud.available_configs.has(
			PlantDefenseRegistry.get_config(&"simple_fence")
		)
		and controller.selection_hud.available_configs.has(
			PlantDefenseRegistry.get_config(&"life_tower")
		)
		and controller.selection_hud.available_configs.has(
			PlantDefenseRegistry.get_config(&"speed_tower")
		)
		and controller.selection_hud.available_configs.has(
			PlantDefenseRegistry.get_config(&"attack_speed_tower")
		),
		"T键免费调试入口必须展示包括生命、移速与攻速强化塔在内的全部19种建筑。"
	)
	controller.cancel_placement()


func _test_authoritative_placement_rollback_sync(
	config: PlantDefenseConfig,
	run_state: RunStateStore,
	player: Player
) -> void:
	run_state.begin_new_run(&"weishidaier", false)
	run_state.register_multiplayer_peer_state(2)
	_expect(
		run_state.try_add_item_for_peer(2, AGAVE_BUILDING_ITEM),
		"多人回滚测试必须能准备加农炮建筑物品。"
	)
	var initial_revision := run_state.get_inventory_revision_for_peer(2)
	var plant_system := PlacementRollbackPlantSystem.new(config)
	var host_game := TowerDefenseGame.new()
	host_game.runtime_mode = CombatRuntimeBase.RuntimeMode.HOST_AUTHORITY
	host_game.run_state = run_state
	host_game.plant_system = plant_system
	host_game.peer_players = {2: player}
	var plant_runtime := TowerDefensePlantRuntimeCoordinator.new()
	plant_runtime.name = "PlantRuntimeCoordinator"
	host_game.add_child(plant_runtime)
	host_game.plant_runtime_coordinator = plant_runtime
	plant_runtime.setup(host_game.runtime_mode, null, null, plant_system, null)
	var rejected_requests: Array[int] = []
	var changed_inventory_peers: Array[int] = []
	var succeeded_requests: Array[int] = []
	plant_runtime.plant_placement_rejected.connect(
		func(request_id: int, _peer_id: int, _reason: StringName) -> void:
			rejected_requests.append(request_id)
	)
	plant_runtime.inventory_changed.connect(
		func(peer_id: int) -> void: changed_inventory_peers.append(peer_id)
	)
	plant_runtime.placement_request_succeeded.connect(
		func(request_id: int, _placement_player: Player) -> void:
			succeeded_requests.append(request_id)
	)
	plant_runtime.request_multiplayer_inventory_placement(
		2,
		77,
		&"agave_cannon",
		Vector2i(2, 3),
		0,
		initial_revision,
		AGAVE_BUILDING_ITEM.resource_path,
		run_state,
		player,
		false
	)
	_expect(
		rejected_requests == [77]
		and run_state.get_item_for_peer(2, 0) == AGAVE_BUILDING_ITEM
		and run_state.get_item_count_for_peer(2, 0) == 1
		and run_state.get_inventory_revision_for_peer(2) == initial_revision + 2
		and changed_inventory_peers == [2]
		and succeeded_requests.is_empty(),
		"多人落地竞争失败后必须恢复物品，并广播回滚后的背包revision。"
	)
	host_game.free()
	plant_system.free()
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


func _finish(test_root: Node) -> void:
	test_root.free()
	if failures.is_empty():
		print("PLANT_CULTIVATION_CENTER_SMOKE_TEST_PASSED")
		quit(0)
		return
	print("PLANT_CULTIVATION_CENTER_SMOKE_TEST_FAILED: %d" % failures.size())
	quit(1)


func _expect(condition: bool, message: String) -> void:
	if condition:
		return
	failures.append(message)
	push_error(message)
