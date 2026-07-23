extends SceneTree

const COORDINATOR_SCENE := preload(
	"res://scene/plant_defense/production_coordinator.tscn"
)
const WAREHOUSE_SCENE := preload(
	"res://scene/plant_defense/oak_warehouse.tscn"
)
const PANEL_SCENE := preload(
	"res://scene/plant_defense/production_building_panel.tscn"
)
const PLACEMENT_CONTROLLER_SCENE := preload(
	"res://scene/plant_defense/plant_placement_controller.tscn"
)
const PLAYER_SCENE := preload(
	"res://scene/player/weishidaier/player_weishidaier.tscn"
)
const PROFILE_PANEL_SCENE := preload(
	"res://scene/player/ui/player_profile_panel.tscn"
)
const WOODEN_CORE := preload(
	"res://resources/config/materials/material_wooden_core.tres"
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
		PlantDefenseRegistry.get_all_configs().size() == 11,
		"公共注册表必须同时包含植物培育中心、竹筒迫击炮、种植基地与紫阳花雨幕塔，共11种建筑。"
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
	center.set_shared_production_panel(panel)

	_expect(
		center.recipes.size() == 4
		and center.recipes[0].input_items == [WOODEN_CORE]
		and center.recipes[0].input_amounts == [1]
		and center.recipes[0].output_items == [AGAVE_BUILDING_ITEM]
		and center.recipes[0].output_amounts == [1]
		and is_equal_approx(center.recipes[0].duration_seconds, 20.0)
		and center.recipes[0].outputs_to_player_inventory()
		and center.recipes[1].input_items == [WOODEN_CORE]
		and center.recipes[1].input_amounts == [1]
		and center.recipes[1].output_items == [CORN_BUILDING_ITEM]
		and center.recipes[1].output_amounts == [1]
		and is_equal_approx(center.recipes[1].duration_seconds, 20.0)
		and center.recipes[1].outputs_to_player_inventory()
		and center.recipes[2].input_items == [WOODEN_CORE]
		and center.recipes[2].input_amounts == [1]
		and center.recipes[2].output_items
		== [BAMBOO_MORTAR_BUILDING_ITEM]
		and center.recipes[2].output_amounts == [1]
		and is_equal_approx(center.recipes[2].duration_seconds, 30.0)
		and center.recipes[2].outputs_to_player_inventory()
		and center.recipes[3].input_items == [WOODEN_CORE]
		and center.recipes[3].input_amounts == [1]
		and center.recipes[3].output_items
		== [HYDRANGEA_RAIN_TOWER_BUILDING_ITEM]
		and center.recipes[3].output_amounts == [1]
		and is_equal_approx(center.recipes[3].duration_seconds, 30.0)
		and center.recipes[3].outputs_to_player_inventory(),
		"培育中心必须提供四个消耗1个木制核心的个人背包配方，并使用20、20、30、30秒培育时间。"
	)
	_expect(
		AGAVE_BUILDING_ITEM.pickup_type == PickupConfig.PickupType.BUILDING
		and AGAVE_BUILDING_ITEM.placeable_plant_id == &"agave_cannon"
		and not AGAVE_BUILDING_ITEM.stackable
		and AGAVE_BUILDING_ITEM.inventory_stack_limit == 1
		and CORN_BUILDING_ITEM.pickup_type == PickupConfig.PickupType.BUILDING
		and CORN_BUILDING_ITEM.placeable_plant_id == &"corn_machine_gun"
		and not CORN_BUILDING_ITEM.stackable
		and CORN_BUILDING_ITEM.inventory_stack_limit == 1
		and BAMBOO_MORTAR_BUILDING_ITEM.pickup_type
		== PickupConfig.PickupType.BUILDING
		and BAMBOO_MORTAR_BUILDING_ITEM.placeable_plant_id
		== &"bamboo_mortar"
		and not BAMBOO_MORTAR_BUILDING_ITEM.stackable
		and BAMBOO_MORTAR_BUILDING_ITEM.inventory_stack_limit == 1
		and HYDRANGEA_RAIN_TOWER_BUILDING_ITEM.pickup_type
		== PickupConfig.PickupType.BUILDING
		and HYDRANGEA_RAIN_TOWER_BUILDING_ITEM.placeable_plant_id
		== &"hydrangea_rain_tower"
		and not HYDRANGEA_RAIN_TOWER_BUILDING_ITEM.stackable
		and HYDRANGEA_RAIN_TOWER_BUILDING_ITEM.inventory_stack_limit == 1,
		"四种产物必须是不可叠加且指向正确建筑配置的建筑物品。"
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
		and run_state.get_item(0) == AGAVE_BUILDING_ITEM
		and run_state.get_item_count(0) == 1
		and is_zero_approx(center.progress_elapsed_seconds),
		"单人完成配方时必须原子扣除木制核心并把加农炮建筑物品放入背包。"
	)
	_expect(
		warehouse.try_add_storage_item_count(WOODEN_CORE, 2),
		"堆叠测试必须能准备两个木制核心。"
	)
	center.advance_shared_production_tick(20.0)
	center.advance_shared_production_tick(20.0)
	_expect(
		run_state.get_item(0) == AGAVE_BUILDING_ITEM
		and run_state.get_item_count(0) == 1
		and run_state.get_item(1) == AGAVE_BUILDING_ITEM
		and run_state.get_item_count(1) == 1
		and run_state.get_item(2) == AGAVE_BUILDING_ITEM
		and run_state.get_item_count(2) == 1,
		"相同建筑产物必须各自占用独立背包槽且数量固定为1。"
	)
	_expect(
		warehouse.try_add_storage_item_count(WOODEN_CORE, 1)
		and center.select_recipe(&"wooden_core_to_corn_machine_gun"),
		"培育测试必须能切换至玉米机枪塔配方。"
	)
	center.advance_shared_production_tick(20.0)
	_expect(
		run_state.get_item(3) == CORN_BUILDING_ITEM
		and run_state.get_item_count(3) == 1,
		"玉米机枪塔必须作为独立且不可叠加的建筑物品进入背包。"
	)
	_expect(
		warehouse.try_add_storage_item_count(WOODEN_CORE, 1)
		and center.select_recipe(&"wooden_core_to_bamboo_mortar"),
		"培育测试必须能切换至竹筒迫击炮配方。"
	)
	center.advance_shared_production_tick(29.0)
	_expect(
		run_state.get_item(4) == null
		and is_equal_approx(center.progress_elapsed_seconds, 29.0),
		"迫击炮培育到29秒时不得提前完成。"
	)
	center.advance_shared_production_tick(1.0)
	_expect(
		run_state.get_item(4) == BAMBOO_MORTAR_BUILDING_ITEM
		and run_state.get_item_count(4) == 1
		and is_zero_approx(center.progress_elapsed_seconds),
		"迫击炮必须在累计30秒时完成并进入独立背包槽位。"
	)
	_expect(
		warehouse.try_add_storage_item_count(WOODEN_CORE, 1)
		and center.select_recipe(&"wooden_core_to_hydrangea_rain_tower"),
		"培育测试必须能切换至紫阳花雨幕塔配方。"
	)
	center.advance_shared_production_tick(29.0)
	_expect(
		run_state.get_item(5) == null
		and is_equal_approx(center.progress_elapsed_seconds, 29.0),
		"紫阳花雨幕塔培育到29秒时不得提前完成。"
	)
	center.advance_shared_production_tick(1.0)
	_expect(
		run_state.get_item(5) == HYDRANGEA_RAIN_TOWER_BUILDING_ITEM
		and run_state.get_item_count(5) == 1
		and is_zero_approx(center.progress_elapsed_seconds),
		"紫阳花雨幕塔必须在累计30秒时完成并进入独立背包槽位。"
	)
	var profile_panel := (
		PROFILE_PANEL_SCENE.instantiate() as PlayerProfilePanel
	)
	test_root.add_child(profile_panel)
	await process_frame
	profile_panel.bind_player(player)
	profile_panel.open()
	profile_panel.call("_on_slot_selected", 0)
	_expect(
		profile_panel.item_detail_category_label.text == "建筑"
		and profile_panel.item_detail_use_button.visible
		and profile_panel.item_detail_use_button.text == "建造"
		and profile_panel.item_detail_discard_button.text == "销毁"
		and profile_panel.item_detail_hint.text.contains("建造模式"),
		"背包详情必须把建筑物品标为“建筑”，并提供“建造”和“销毁”操作。"
	)
	profile_panel.close()
	profile_panel.queue_free()

	run_state.ensure_multiplayer_peer_state(2)
	coordinator.configure_multiplayer_output_peers([2])
	var committed_peer_ids: Array[int] = []
	coordinator.personal_inventory_output_committed.connect(
		func(peer_id: int) -> void: committed_peer_ids.append(peer_id)
	)
	_expect(
		warehouse.try_add_storage_item_count(WOODEN_CORE, 1)
		and center.select_recipe(&"wooden_core_to_agave_cannon", 2),
		"联机权威建筑必须记录选择配方的玩家。"
	)
	center.advance_shared_production_tick(20.0)
	_expect(
		run_state.get_item_for_peer(2, 0) == AGAVE_BUILDING_ITEM
		and run_state.get_item_count_for_peer(2, 0) == 1
		and committed_peer_ids == [2]
		and center.personal_output_peer_id == 2,
		"联机产物只能进入配方选择者背包，并发出对应玩家的同步事件。"
	)
	var runtime_state := center.export_multiplayer_runtime_state()
	_expect(
		int(runtime_state.get("schema", 0)) == 3
		and int(runtime_state.get("personal_output_peer_id", 0)) == 2,
		"生产权威状态必须同步个人产物接收者。"
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
		and panel.output_title.text == "背包产物"
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
		and not panel.recipe_rows[4].visible
		and progress_fill != null
		and progress_fill.bg_color.g > 0.75,
		"培育中心UI必须使用植物面板、嫩绿进度条，显示四条正确耗时的1投入1产物配方。"
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
	_expect(
		panel.recipe_rows[0].text
			== "培育龙舌兰加农炮\n木制核心 ×1 · 20秒"
		and panel.recipe_rows[1].text
			== "培育玉米机枪塔\n木制核心 ×1 · 20秒"
		and panel.recipe_rows[2].text
			== "培育竹筒迫击炮\n木制核心 ×1 · 30秒",
		"背包产物配方摘要必须只显示投入与耗时，避免在窄栏重复长产物名。"
	)
	_expect(
		panel.progress_label.position == Vector2(165.0, 314.0)
		and panel.progress_label.size == Vector2(180.0, 34.0)
		and panel.progress_label.autowrap_mode
			== TextServer.AUTOWRAP_WORD_SMART
		and panel.progress_label.clip_text
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
		and run_state.get_item_count(0) == 1
		and run_state.get_item(1) == AGAVE_BUILDING_ITEM
		and run_state.get_item_count(1) == 1,
		"不可叠加建筑物品必须各占一个背包槽。"
	)
	var initial_revision := run_state.get_inventory_revision()
	_expect(
		run_state.try_consume_item_at_slot_if_revision(
			0,
			AGAVE_BUILDING_ITEM,
			initial_revision
		)
		and run_state.get_item(0) == null
		and run_state.get_item(1) == AGAVE_BUILDING_ITEM
		and run_state.get_item_count(1) == 1
		and not run_state.try_consume_item_at_slot_if_revision(
			1,
			AGAVE_BUILDING_ITEM,
			initial_revision
		),
		"建筑物品必须一次清空一个独立槽，并拒绝过期背包revision。"
	)
	run_state.begin_new_run(&"weishidaier", false)
	_expect(
		run_state.try_add_item(AGAVE_BUILDING_ITEM),
		"放置请求测试必须重新准备一个加农炮建筑物品。"
	)

	var controller := (
		PLACEMENT_CONTROLLER_SCENE.instantiate() as PlantPlacementController
	)
	var plant_system := PlantSystem.new()
	test_root.add_child(plant_system)
	test_root.add_child(controller)
	await process_frame
	controller.setup(plant_system, null)
	var requests: Array[Dictionary] = []
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
	_expect(
		controller.begin_inventory_placement(
			agave_config,
			0,
			current_revision,
			AGAVE_BUILDING_ITEM.resource_path
		),
		"背包建筑物品必须能绕过T键选择页直接进入指定建筑放置模式。"
	)
	controller.has_hovered_anchor = true
	controller.hovered_anchor = Vector2i(3, 4)
	controller.call("_try_place_hovered")
	_expect(
		requests.size() == 1
		and requests[0]["plant_id"] == &"agave_cannon"
		and requests[0]["anchor"] == Vector2i(3, 4)
		and int(requests[0]["slot_index"]) == 0
		and int(requests[0]["expected_revision"]) == current_revision
		and requests[0]["item_config_path"]
		== AGAVE_BUILDING_ITEM.resource_path
		and not controller.is_active()
		and run_state.get_item_count(0) == 1,
		"放置控制器必须携带槽位、revision和物品路径请求权威落地，且不能自行提前扣除物品。"
	)
	_expect(
		controller.open_selection()
		and controller.selection_hud.available_configs.size() == 11,
		"T键免费调试入口必须继续展示全部11种建筑。"
	)
	controller.cancel_placement()


func _test_authoritative_placement_rollback_sync(
	config: PlantDefenseConfig,
	run_state: RunStateStore,
	player: Player
) -> void:
	run_state.begin_new_run(&"weishidaier", false)
	run_state.ensure_multiplayer_peer_state(2)
	_expect(
		run_state.try_add_item_for_peer(2, AGAVE_BUILDING_ITEM),
		"多人回滚测试必须能准备加农炮建筑物品。"
	)
	var initial_revision := run_state.get_inventory_revision_for_peer(2)
	var plant_system := PlacementRollbackPlantSystem.new(config)
	var host_game := GameTowerDefense.new()
	host_game.runtime_mode = GameRuntimeBase.RuntimeMode.HOST_AUTHORITY
	host_game.run_state = run_state
	host_game.plant_system = plant_system
	host_game.peer_players = {2: player}
	var rejected_requests: Array[int] = []
	var changed_inventory_peers: Array[int] = []
	host_game.multiplayer_plant_placement_rejected.connect(
		func(request_id: int, _peer_id: int, _reason: StringName) -> void:
			rejected_requests.append(request_id)
	)
	host_game.multiplayer_inventory_changed.connect(
		func(peer_id: int) -> void: changed_inventory_peers.append(peer_id)
	)
	host_game.request_multiplayer_inventory_plant_placement(
		2,
		77,
		&"agave_cannon",
		Vector2i(2, 3),
		0,
		initial_revision,
		AGAVE_BUILDING_ITEM.resource_path
	)
	_expect(
		rejected_requests == [77]
		and run_state.get_item_for_peer(2, 0) == AGAVE_BUILDING_ITEM
		and run_state.get_item_count_for_peer(2, 0) == 1
		and run_state.get_inventory_revision_for_peer(2) == initial_revision + 2
		and changed_inventory_peers == [2],
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
