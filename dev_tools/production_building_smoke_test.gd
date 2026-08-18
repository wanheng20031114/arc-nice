extends SceneTree

const COORDINATOR_SCENE := preload(
	"res://scene/game_modes/tower_defense/economy/production/production_coordinator.tscn"
)
const WAREHOUSE_SCENE := preload("res://scene/plant_defense/oak_warehouse.tscn")
const PANEL_SCENE := preload("res://scene/game_modes/tower_defense/economy/production/production_building_panel.tscn")
const PLAYER_SCENE := preload("res://scene/player/weishidaier/player_weishidaier.tscn")
const MP_GAME_SCENE := preload("res://scene/multiplayer/mp_game.tscn")
const WOOD := preload("res://resources/config/materials/material_wood.tres")
const DIRT_BLOCK := preload(
	"res://resources/config/materials/material_dirt_block.tres"
)
const SAPLING := preload("res://resources/config/materials/material_sapling.tres")
const PLANK := preload("res://resources/config/materials/material_plank.tres")
const WATER_BOTTLE := preload(
	"res://resources/config/materials/material_water_bottle.tres"
)
const WOODEN_CORE := preload(
	"res://resources/config/materials/material_wooden_core.tres"
)
const GAMBLER_TICKET := preload(
	"res://resources/config/materials/material_gambler_ticket.tres"
)
const BASKETBALL := preload(
	"res://resources/config/collectibles/collectible_basketball.tres"
)
const WATER_COLLECTOR_ITEM := preload(
	"res://resources/config/buildings/building_water_collector.tres"
)
const PLANTING_BASE_ITEM := preload(
	"res://resources/config/buildings/building_planting_base.tres"
)
const PLANT_CULTIVATION_CENTER_ITEM := preload(
	"res://resources/config/buildings/building_plant_cultivation_center.tres"
)
const RESEARCH_CENTER_ITEM := preload(
	"res://resources/config/buildings/building_research_center.tres"
)
const EXCAVATOR_ITEM := preload(
	"res://resources/config/buildings/building_excavator.tres"
)
const LIFE_TOWER_ITEM := preload(
	"res://resources/config/buildings/building_life_tower.tres"
)
const SPEED_TOWER_ITEM := preload(
	"res://resources/config/buildings/building_speed_tower.tres"
)
const ATTACK_SPEED_TOWER_ITEM := preload(
	"res://resources/config/buildings/building_attack_speed_tower.tres"
)

var failures: PackedStringArray = []


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var test_root := Node.new()
	test_root.name = "ProductionBuildingSmokeTest"
	root.add_child(test_root)
	var run_state := root.get_node("RunState") as RunStateStore
	run_state.begin_new_run(&"weishidaier", false)

	var coordinator := COORDINATOR_SCENE.instantiate() as ProductionCoordinator
	var warehouse := WAREHOUSE_SCENE.instantiate() as OakWarehouse
	var config := PlantDefenseRegistry.get_config(&"wood_processing_station")
	var station := config.plant_scene.instantiate() as ProductionBuilding if config != null else null
	var second_station := (
		config.plant_scene.instantiate() as ProductionBuilding
		if config != null
		else null
	)
	var panel := PANEL_SCENE.instantiate() as ProductionBuildingPanel
	var player := PLAYER_SCENE.instantiate() as Player
	test_root.add_child(coordinator)
	test_root.add_child(warehouse)
	if station != null:
		test_root.add_child(station)
	if second_station != null:
		test_root.add_child(second_station)
	test_root.add_child(panel)
	test_root.add_child(player)
	await process_frame
	coordinator.production_tick_timer.stop()

	_expect(config != null and config.is_valid(), "木头加工站配置必须有效。")
	_expect(
		config != null and config.supports_multiplayer,
		"木头加工站必须允许进入多人建造与生产网络。"
	)
	_expect(
		config != null
		and config.max_health == 2000
		and config.physical_defense == 10
		and config.magic_defense == 0
		and config.footprint_size == Vector2i.ONE,
		"木头加工站必须为2000生命、10物防、0法防且只占一格。"
	)
	_expect(station != null, "木头加工站场景根节点必须继承ProductionBuilding。")
	if station == null or config == null:
		_finish(test_root)
		return

	var warehouse_config := PlantDefenseRegistry.get_config(&"oak_warehouse")
	warehouse.setup(warehouse_config, null, [Vector2i.ZERO])
	station.setup(config, null, [Vector2i.ONE])
	if second_station != null:
		second_station.setup(config, null, [Vector2i(2, 0)])
	coordinator.register_plant(warehouse)
	coordinator.register_plant(station)
	if second_station != null:
		coordinator.register_plant(second_station)
	station.set_shared_production_panel(panel)

	var station_direct_timers := station.find_children(
		"*",
		"Timer",
		false,
		false
	)
	var request_timer := station.get_node_or_null(
		"MultiplayerProductionRequestTimer"
	) as Timer
	_expect(
		coordinator.get_node("ProductionTickTimer") is Timer
		and station_direct_timers.size() == 1
		and request_timer != null
		and request_timer.one_shot
		and is_equal_approx(request_timer.wait_time, 4.0),
		"加工站直属节点只能预置4秒多人请求Timer，生产刻度仍必须由全场协调器统一推进。"
	)
	var health_bar := station.get_node("HealthBar") as PlantHealthBar
	var health_bar_idle_timer := (
		health_bar.get_node_or_null("IdleFadeTimer") as Timer
		if health_bar != null
		else null
	)
	_expect(
		health_bar != null
		and health_bar.size == Vector2(12, 3)
		and health_bar.position == Vector2(-6, -9)
		and health_bar.scale == Vector2.ONE
		and health_bar_idle_timer != null
		and health_bar_idle_timer.one_shot
		and health_bar_idle_timer.is_stopped()
		and not health_bar.is_processing()
		and not health_bar.is_physics_processing(),
		"木头加工站必须使用12×3公共血条；满血计时器停止且不得注册脚本逐帧处理。"
	)
	var production_border := station.get_node("ProductionBorder") as MeshInstance2D
	var border_mesh := production_border.mesh as QuadMesh if production_border != null else null
	var border_material := production_border.material as ShaderMaterial if production_border != null else null
	_expect(
		production_border != null
		and border_mesh != null
		and border_mesh.size == Vector2(16, 16)
		and border_material != null
		and border_material.shader.resource_path
		== "res://resources/shader/wood_processing_station_border.gdshader",
		"木头加工站必须拥有16×16独立棕色噪波像素外圈。"
	)
	if border_material != null:
		var idle_brown: Color = border_material.get_shader_parameter(&"idle_brown")
		var idle_shadow: Color = border_material.get_shader_parameter(&"idle_shadow")
		var progress_brown: Color = border_material.get_shader_parameter(
			&"progress_brown"
		)
		_expect(
			idle_brown.get_luminance() >= 0.4
			and idle_shadow.get_luminance() >= 0.15
			and progress_brown.get_luminance()
				- idle_brown.get_luminance() >= 0.2,
			"默认棕色外圈必须清晰可见，同时与高亮生产进度保持足够亮度差。"
		)
		_expect(
			float(border_material.get_shader_parameter(&"grain_speed")) >= 1.5,
			"木纹噪波必须保持清晰而活跃的流动速度。"
		)
	if production_border != null:
		_expect(
			not bool(production_border.get_instance_shader_parameter(&"working_active")),
			"未选择配方时加工站外圈必须保持棕色非工作模式。"
		)
	var second_production_border := (
		second_station.get_node("ProductionBorder") as MeshInstance2D
		if second_station != null
		else null
	)
	if production_border != null and second_production_border != null:
		_expect(
			production_border.material == second_production_border.material
			and not is_equal_approx(
				float(production_border.get_instance_shader_parameter(&"noise_seed")),
				float(second_production_border.get_instance_shader_parameter(&"noise_seed"))
			),
			"同类加工站必须共享材质但使用独立噪波相位，避免复制材质或同步闪烁。"
		)
	_expect(not panel.visible and not panel.is_open(), "常驻生产面板必须默认隐藏。")
	_expect(
		panel.has_node("Overlay/PanelRoot/InputSlot1")
		and panel.has_node("Overlay/PanelRoot/InputSlot2")
		and panel.has_node("Overlay/PanelRoot/InputSlot3")
		and panel.has_node("Overlay/PanelRoot/OutputSlot1")
		and panel.has_node("Overlay/PanelRoot/OutputSlot2")
		and panel.has_node("Overlay/PanelRoot/OutputSlot3")
		and panel.has_node("Overlay/PanelRoot/MaterialList")
		and panel.has_node("Overlay/PanelRoot/ToggleButton")
		and panel.has_node("Overlay/PanelRoot/LoopButton")
		and panel.has_node("Overlay/PanelRoot/RecipeScroll/RecipeRows/RecipeRow8")
		and panel.has_node("Overlay/PanelRoot/RecipeScroll/RecipeRows/RecipeRow9")
		and panel.has_node("Overlay/PanelRoot/RecipeScroll/RecipeRows/RecipeRow10")
		and panel.has_node("Overlay/PanelRoot/RecipeScroll/RecipeRows/RecipeRow11"),
		"生产面板必须原生搭建左右各3个候选槽位、物资列表、顶部启停按钮及生产框循环按钮。"
	)
	_expect(
		panel.status_label.position == Vector2(61.0, 420.0)
		and panel.status_label.size == Vector2(392.0, 48.0)
		and panel.close_button.position == Vector2(540.0, 431.0)
		and panel.close_button.size == Vector2(108.0, 37.0),
		"生产面板底部状态文字和关闭按钮必须完整收进背景安全区。"
	)
	panel.open_for(station, player)
	await process_frame
	_expect(panel.is_open() and panel.visible and player.controls_locked, "靠近交互打开生产面板后必须锁定玩家控制。")
	var loop_button := panel.get_node("Overlay/PanelRoot/LoopButton") as Button
	var toggle_button := panel.get_node("Overlay/PanelRoot/ToggleButton") as Button
	var loop_off_style := loop_button.get_theme_stylebox("normal") as StyleBoxFlat
	_expect(
		loop_button != null
		and toggle_button != null
		and loop_button.visible
		and loop_button.text.is_empty()
		and loop_button.icon != null
		and loop_button.icon.resource_path
		== "res://resources/texture/production/production_loop_icon.svg"
		and loop_button.texture_filter
		== CanvasItem.TEXTURE_FILTER_LINEAR
		and loop_button.get_theme_constant("icon_max_width") == 28
		and loop_button.toggle_mode
		and not loop_button.button_pressed
		and loop_button.get_rect()
		== ProductionBuildingPanel.STANDARD_LOOP_BUTTON_RECT
		and loop_button.position.y > panel.building_title.get_rect().end.y
		and loop_button.get_rect().end.y <= panel.input_title.position.y
		and loop_button.get_rect().end.x < panel.recipe_title.position.x
		and loop_off_style != null
		and loop_off_style.bg_color.r > loop_off_style.bg_color.g
		and not station.production_loop_enabled,
		"循环按钮必须使用完整SVG图标，以红色关闭态位于材料—产物大框右上角，且建筑默认采用单次生产。"
	)
	panel.call("_on_loop_pressed")
	var loop_on_style := loop_button.get_theme_stylebox("normal") as StyleBoxFlat
	_expect(
		station.production_loop_enabled
		and loop_button.button_pressed
		and loop_on_style != null
		and loop_on_style.bg_color.g > loop_on_style.bg_color.r
		and loop_button.tooltip_text.contains("循环生产"),
		"点击∞必须只开启循环并将按钮切换为绿色语义态。"
	)
	panel.call("_on_loop_pressed")
	_expect(
		not station.production_loop_enabled
		and not loop_button.button_pressed
		and station.production_enabled,
		"再次点击∞必须恢复红色单次模式，且不得改变建筑启停状态。"
	)
	_expect(
		panel.recipe_rows[0].icon == PLANK.icon_texture
		and panel.recipe_rows[0].icon != WOOD.icon_texture
		and panel.recipe_rows[1].icon == WOODEN_CORE.icon_texture
		and panel.recipe_rows[2].icon == GAMBLER_TICKET.icon_texture
		and panel.recipe_rows[3].icon == WATER_COLLECTOR_ITEM.icon_texture
		and panel.recipe_rows[4].icon == PLANTING_BASE_ITEM.icon_texture
		and panel.recipe_rows[5].icon == PLANT_CULTIVATION_CENTER_ITEM.icon_texture
		and panel.recipe_rows[6].icon == RESEARCH_CENTER_ITEM.icon_texture
		and panel.recipe_rows[7].icon == EXCAVATOR_ITEM.icon_texture
		and panel.recipe_rows[8].icon == LIFE_TOWER_ITEM.icon_texture
		and panel.recipe_rows[9].icon == SPEED_TOWER_ITEM.icon_texture
		and panel.recipe_rows[10].icon == ATTACK_SPEED_TOWER_ITEM.icon_texture
		and panel.recipe_rows.all(func(row: Button) -> bool: return row.visible)
		and panel.recipe_rows[2].text.contains("赌怪专用券制作")
		and panel.recipe_rows[3].text.contains("水源采集器组装")
		and panel.recipe_rows[4].text.contains("种植基地组装")
		and panel.recipe_rows[5].text.contains("植物培育中心组装")
		and panel.recipe_rows[6].text.contains("科研中心组装")
		and panel.recipe_rows[7].text.contains("挖土装置组装")
		and panel.recipe_rows[8].text.contains("生命强化塔组装")
		and panel.recipe_rows[9].text.contains("移速强化塔组装")
		and panel.recipe_rows[10].text.contains("攻速强化塔组装")
		and panel.recipe_rows[3].text.contains("30秒")
		and panel.recipe_rows[8].text.contains("30秒")
		and panel.recipe_rows[9].text.contains("30秒")
		and panel.recipe_rows[10].text.contains("30秒"),
		"右侧十一条配方必须显示正确产物图标，八种功能建筑统一标明30秒。"
	)
	panel.recipe_scroll.ensure_control_visible(panel.recipe_rows[9])
	await process_frame
	await _click_panel_control(panel.recipe_rows[9])
	_expect(
		panel.recipe_scroll.get_global_rect().encloses(
			panel.recipe_rows[9].get_global_rect()
		)
		and station.active_recipe_id == &"speed_tower_assembly"
		and panel.recipe_rows[9].button_pressed
		and panel.input_slots[0].visible
		and panel.input_slots[0].item == PLANK
		and panel.input_slots[0].stack_count == 10
		and panel.input_slots[1].visible
		and panel.input_slots[1].item == SAPLING
		and panel.input_slots[1].stack_count == 2
		and not panel.input_slots[2].visible
		and panel.output_slots[0].visible
		and panel.output_slots[0].item == SPEED_TOWER_ITEM
		and panel.output_title.text == "仓库产物",
		"滚动到第十条配方后必须能选择移速强化塔，并显示10木板、2树苗与仓库产物。"
	)
	panel.recipe_scroll.ensure_control_visible(panel.recipe_rows[10])
	await process_frame
	await _click_panel_control(panel.recipe_rows[10])
	_expect(
		panel.recipe_scroll.get_global_rect().encloses(
			panel.recipe_rows[10].get_global_rect()
		)
		and station.active_recipe_id == &"attack_speed_tower_assembly"
		and panel.recipe_rows[10].button_pressed
		and panel.input_slots[0].visible
		and panel.input_slots[0].item == PLANK
		and panel.input_slots[0].stack_count == 10
		and panel.input_slots[1].visible
		and panel.input_slots[1].item == SAPLING
		and panel.input_slots[1].stack_count == 2
		and not panel.input_slots[2].visible
		and panel.output_slots[0].visible
		and panel.output_slots[0].item == ATTACK_SPEED_TOWER_ITEM,
		"滚动到第十一条配方后必须能选择攻速强化塔，并显示10木板、2树苗与仓库产物。"
	)
	panel.call("_on_recipe_row_pressed", 0)
	_expect(
		panel.input_slots[0].visible
		and not panel.input_slots[1].visible
		and not panel.input_slots[2].visible
		and panel.output_slots[0].visible
		and not panel.output_slots[1].visible
		and not panel.output_slots[2].visible
		and panel.input_slots[0].position.x == 98.0
		and panel.output_slots[0].position.x == 360.0,
		"木头转木板配方必须左右各只显示1个居中槽位。"
	)
	panel.call("_on_input_slot_pressed", 0)
	_expect(
		panel.material_list.visible
		and panel.material_buttons[0].visible
		and panel.material_buttons[0].text.contains("木头")
		and not panel.material_buttons[1].visible
		and not panel.material_buttons[2].visible,
		"单投入配方的原料详情必须只列出当前所需木头。"
	)
	panel.call("_on_material_button_pressed", 0)
	_expect(panel.status_label.text.contains("每轮需要 1 个木头"), "原料详情必须说明配方需求量。")
	panel.call("_on_recipe_row_pressed", 1)
	_expect(
		station.active_recipe_id == &"wooden_core_assembly"
		and panel.input_slots.all(func(slot: InventorySlot) -> bool: return slot.visible)
		and panel.input_slots[0].item == PLANK
		and panel.input_slots[0].stack_count == 10
		and panel.input_slots[1].item == SAPLING
		and panel.input_slots[1].stack_count == 1
		and panel.input_slots[2].item == WATER_BOTTLE
		and panel.input_slots[2].stack_count == 5
		and panel.output_slots[0].item == WOODEN_CORE
		and panel.output_slots[0].visible
		and not panel.output_slots[1].visible
		and not panel.output_slots[2].visible
		and panel.input_slots[0].position.x == 42.0
		and panel.input_slots[1].position.x == 98.0
		and panel.input_slots[2].position.x == 154.0
		and panel.output_slots[0].position.x == 360.0,
		"木制核心配方必须显示3个投入槽和1个居中产物槽，并标出10/1/5需求量。"
	)
	panel.call("_on_input_slot_pressed", 2)
	_expect(
		panel.material_list.visible
		and panel.material_buttons.all(func(button: Button) -> bool: return button.visible)
		and panel.material_buttons[0].text.contains("木板")
		and panel.material_buttons[1].text.contains("树苗")
		and panel.material_buttons[2].text.contains("水瓶"),
		"多投入配方的原料详情必须恰好列出木板、树苗和水瓶。"
	)
	panel.call("_on_recipe_row_pressed", 0)
	panel.call("_on_recipe_row_pressed", 0)
	_expect(
		station.active_recipe_id == &"wood_to_plank"
		and panel.recipe_rows[0].button_pressed,
		"当前生产配方必须持续高亮，重复点击不得取消方案。"
	)
	panel.close()
	_expect(not panel.is_open() and not player.controls_locked, "关闭生产面板必须恢复玩家控制。")
	if second_station != null:
		panel.open_for(station, player)
		panel.bind_building(second_station, player)
		_expect(
			not panel.is_open()
			and not player.has_control_lock(
				ProductionBuildingPanel.CONTROL_LOCK_OWNER
			)
			and panel.is_bound_to_building(second_station),
			"可见生产面板重绑建筑时必须先关闭旧会话并释放旧玩家锁。"
		)
	station.nearby_player = player
	station.call("_set_interaction_target", true)
	var interact_event := InputEventKey.new()
	interact_event.physical_keycode = KEY_F
	interact_event.pressed = true
	_expect(interact_event.is_action_pressed(&"interact"), "键盘F必须映射到建筑interact动作。")
	station._unhandled_input(interact_event)
	_expect(panel.is_open() and player.controls_locked, "第一次按F必须打开木头加工站并锁定玩家。")
	panel._input(interact_event)
	_expect(
		not panel.is_open() and not player.controls_locked,
		"木头加工站打开后第二次按F必须关闭并解除玩家锁定。"
	)
	station.call("_set_interaction_target", true)
	station._unhandled_input(interact_event)
	_expect(panel.is_open(), "同一建筑UI关闭后必须能再次按F打开。")
	var joypad_y := InputEventJoypadButton.new()
	joypad_y.button_index = JOY_BUTTON_Y
	joypad_y.pressed = true
	_expect(joypad_y.is_action_pressed(&"interact"), "手柄Y必须复用建筑UI开关动作。")
	panel._input(joypad_y)
	_expect(
		not panel.is_open() and not player.controls_locked,
		"所有建筑面板必须通过统一关闭规则支持第二次交互键关闭。"
	)
	_expect(
		station.recipes.size() == 11
		and _recipe_matches(
			station.recipes[0],
			&"wood_to_plank",
			[WOOD],
			[1],
			PLANK,
			2,
			10.0,
			true
		)
		and _recipe_matches(
			station.recipes[1],
			&"wooden_core_assembly",
			[PLANK, SAPLING, WATER_BOTTLE],
			[10, 1, 5],
			WOODEN_CORE,
			1,
			10.0,
			true
		)
		and _recipe_matches(
			station.recipes[2],
			&"gambler_ticket_assembly",
			[DIRT_BLOCK],
			[20],
			GAMBLER_TICKET,
			1,
			10.0,
			true
		)
		and _recipe_matches(
			station.recipes[3],
			&"water_collector_assembly",
			[PLANK],
			[10],
			WATER_COLLECTOR_ITEM,
			1,
			30.0,
			true
		)
		and _recipe_matches(
			station.recipes[4],
			&"planting_base_assembly",
			[PLANK, SAPLING, WATER_BOTTLE],
			[20, 5, 5],
			PLANTING_BASE_ITEM,
			1,
			30.0,
			true
		)
		and _recipe_matches(
			station.recipes[5],
			&"plant_cultivation_center_assembly",
			[PLANK, WATER_BOTTLE],
			[30, 10],
			PLANT_CULTIVATION_CENTER_ITEM,
			1,
			30.0,
			true
		)
		and _recipe_matches(
			station.recipes[6],
			&"research_center_assembly",
			[PLANK, WATER_BOTTLE],
			[30, 10],
			RESEARCH_CENTER_ITEM,
			1,
			30.0,
			true
		)
		and _recipe_matches(
			station.recipes[7],
			&"excavator_assembly",
			[PLANK],
			[10],
			EXCAVATOR_ITEM,
			1,
			30.0,
			true
		)
		and _recipe_matches(
			station.recipes[8],
			&"life_tower_assembly",
			[PLANK, SAPLING],
			[10, 2],
			LIFE_TOWER_ITEM,
			1,
			30.0,
			true
		)
		and _recipe_matches(
			station.recipes[9],
			&"speed_tower_assembly",
			[PLANK, SAPLING],
			[10, 2],
			SPEED_TOWER_ITEM,
			1,
			30.0,
			true
		)
		and _recipe_matches(
			station.recipes[10],
			&"attack_speed_tower_assembly",
			[PLANK, SAPLING],
			[10, 2],
			ATTACK_SPEED_TOWER_ITEM,
			1,
			30.0,
			true
		),
		"加工站必须按固定顺序提供三条材料配方与八条30秒功能建筑配方。"
	)
	_expect(
		_is_valid_building_item(WATER_COLLECTOR_ITEM, &"water_collector")
		and _is_valid_building_item(PLANTING_BASE_ITEM, &"planting_base")
		and _is_valid_building_item(
			PLANT_CULTIVATION_CENTER_ITEM,
			&"plant_cultivation_center"
		)
		and _is_valid_building_item(RESEARCH_CENTER_ITEM, &"research_center")
		and _is_valid_building_item(EXCAVATOR_ITEM, &"excavator")
		and _is_valid_building_item(LIFE_TOWER_ITEM, &"life_tower")
		and _is_valid_building_item(SPEED_TOWER_ITEM, &"speed_tower")
		and _is_valid_building_item(
			ATTACK_SPEED_TOWER_ITEM,
			&"attack_speed_tower"
		),
		"八种功能建筑物品必须复用原图、缩放至32×32且指向有效建筑配置。"
	)

	station.set_production_enabled(false)
	station.set_production_enabled(true)
	_expect(warehouse.try_add_storage_item_count(WOOD, 1), "仓库必须能加入测试木头。")
	_expect(station.select_recipe(&"wood_to_plank"), "玩家必须能选择木材锯切配方。")
	if production_border != null:
		_expect(
			bool(production_border.get_instance_shader_parameter(&"working_active"))
			and is_zero_approx(
				float(production_border.get_instance_shader_parameter(&"progress_value"))
			),
			"开始生产时外圈必须从顶部起按一秒一个逻辑步长顺时针平滑推进。"
		)
	if second_production_border != null:
		_expect(
			not bool(
				second_production_border.get_instance_shader_parameter(&"working_active")
			),
			"一个加工站开始生产时不得串改另一个实例的边框状态。"
		)
	await create_timer(0.05).timeout
	# A long headless startup frame can fire SceneTreeTimer before that same
	# frame's Tween phase. Wait for the next process boundary before sampling.
	await process_frame
	_expect(
		is_zero_approx(station.get_progress_ratio())
		and station.get_visual_progress_ratio() > 0.0
		and station.get_visual_progress_ratio() < 0.1,
		"生产权威值必须仍按秒推进，而显示值必须在两个逻辑刻度之间连续插值。"
	)
	if production_border != null:
		var first_segment_progress := float(
			production_border.get_instance_shader_parameter(&"progress_value")
		)
		_expect(
			first_segment_progress > 0.0 and first_segment_progress < 0.1,
			(
				"加工站shader实例进度必须跨渲染帧连续推进，"
				+ "不能混用脚本与渲染时钟后瞬间跳到目标，实际为%.4f。"
				% first_segment_progress
			)
		)
	station.advance_shared_production_tick(9.0)
	if production_border != null:
		var final_segment_start := float(
			production_border.get_instance_shader_parameter(&"progress_value")
		)
		_expect(
			is_equal_approx(final_segment_start, 0.9),
			(
				"最后一个逻辑秒必须从90%开始，不能提前跳满一整圈，"
				+ "实际为%.4f。" % final_segment_start
			)
		)
	await create_timer(0.05).timeout
	if production_border != null:
		var final_segment_progress := float(
			production_border.get_instance_shader_parameter(&"progress_value")
		)
		_expect(
			final_segment_progress > 0.9 and final_segment_progress < 1.0,
			(
				"最后一个逻辑秒必须跨渲染帧从90%连续走满，"
				+ "实际为%.4f。" % final_segment_progress
			)
		)
	_expect(
		coordinator.get_total_item_count(WOOD) == 1
		and coordinator.get_total_item_count(PLANK) == 0,
		"生产完成前不得访问、扣除原料或提前加入产物。"
	)
	station.advance_shared_production_tick(1.0)
	_expect(
		coordinator.get_total_item_count(WOOD) == 0
		and coordinator.get_total_item_count(PLANK) == 2
		and is_zero_approx(station.progress_elapsed_seconds)
		and not station.production_enabled
		and not station.production_loop_enabled,
		"默认单次模式第10秒必须原子结算一轮、进度归零并自动停止。"
	)
	if production_border != null:
		_expect(
			is_zero_approx(
				float(production_border.get_instance_shader_parameter(&"progress_value"))
			),
			"单次一轮完成后环形进度必须归零，不能保留已完成进度。"
		)

	station.advance_shared_production_tick(10.0)
	_expect(
		is_zero_approx(station.get_progress_ratio())
		and station.completion_wait_reason == &""
		and coordinator.get_total_item_count(PLANK) == 2,
		"单次完成停机后即使继续推进时间也不得暗中开始第二轮。"
	)
	_expect(
		station.set_production_enabled(true)
		and not station.production_loop_enabled,
		"默认单次模式必须能由▶重新启动一轮。"
	)
	station.advance_shared_production_tick(10.0)
	_expect(
		station.production_enabled
		and not station.production_loop_enabled
		and is_equal_approx(station.get_progress_ratio(), 1.0)
		and station.completion_wait_reason == ProductionCoordinator.RESULT_MISSING_INPUT
		and coordinator.get_total_item_count(PLANK) == 2,
		"单次模式缺料到100%时必须继续等待，不能把阻塞当作成功而提前停机。"
	)
	_expect(warehouse.try_add_storage_item_count(WOOD, 1), "单次缺料等待必须能补入测试木头。")
	_expect(
		coordinator.get_total_item_count(WOOD) == 0
		and coordinator.get_total_item_count(PLANK) == 4
		and not station.production_enabled
		and not station.production_loop_enabled
		and is_zero_approx(station.progress_elapsed_seconds),
		"单次阻塞解除后必须只原子结算一次并立即停机。"
	)
	_expect(
		station.set_production_loop_enabled(true)
		and not station.production_enabled
		and station.set_production_enabled(true),
		"点亮∞只能设定后续循环，停机建筑仍必须由▶显式启动。"
	)
	station.advance_shared_production_tick(10.0)
	_expect(
		is_equal_approx(station.get_progress_ratio(), 1.0)
		and station.completion_wait_reason == ProductionCoordinator.RESULT_MISSING_INPUT
		and station.production_enabled
		and station.production_loop_enabled
		and coordinator.get_total_item_count(PLANK) == 4,
		"循环模式缺料时必须停在完成态等待，不能把阻塞误判为本轮成功。"
	)
	_expect(warehouse.try_add_storage_item_count(WOOD, 1), "仓库必须能补入等待中的原料。")
	_expect(
		coordinator.get_total_item_count(WOOD) == 0
		and coordinator.get_total_item_count(PLANK) == 6
		and is_zero_approx(station.progress_elapsed_seconds),
		"等待中的原料一进入任意仓库，必须在同帧完成一轮生产。"
	)

	_expect(warehouse.try_add_storage_item_count(WOOD, 1), "仓库必须能加入中途关闭循环的测试原料。")
	_expect(warehouse.try_add_storage_item_count(SAPLING, 1), "仓库必须能加入无效树苗。")
	station.advance_shared_production_tick(5.0)
	station.set_production_loop_enabled(false)
	_expect(
		station.production_enabled
		and not station.production_loop_enabled
		and is_equal_approx(station.progress_elapsed_seconds, 5.0),
		"运行中关闭∞不得停止建筑或清空已经推进的半轮进度。"
	)
	station.advance_shared_production_tick(5.0)
	_expect(
		not station.production_enabled
		and is_zero_approx(station.progress_elapsed_seconds)
		and coordinator.get_total_item_count(WOOD) == 0
		and coordinator.get_total_item_count(PLANK) == 8,
		"运行中关闭∞必须在当前轮成功结算后才停止。"
	)
	_expect(
		warehouse.try_add_storage_item_count(WOOD, 1)
		and station.set_production_loop_enabled(true)
		and station.set_production_enabled(true),
		"暂停回归夹具必须重新显式开启循环与生产。"
	)
	station.advance_shared_production_tick(5.0)
	station.set_production_enabled(false)
	_expect(
		is_zero_approx(station.progress_elapsed_seconds)
		and coordinator.get_total_item_count(WOOD) == 1
		and coordinator.get_total_item_count(SAPLING) == 1,
		"关闭生产必须清空半轮进度，且木头和无效树苗都继续留在仓库。"
	)
	if production_border != null:
		_expect(
			not bool(production_border.get_instance_shader_parameter(&"working_active")),
			"暂停生产后像素外圈必须立即回到棕色噪波常态。"
		)
	for slot_index in OakWarehouse.STORAGE_CAPACITY:
		if warehouse.get_storage_item(slot_index) == WOOD:
			warehouse.discard_storage_item(slot_index)
			break
	var second_warehouse := WAREHOUSE_SCENE.instantiate() as OakWarehouse
	test_root.add_child(second_warehouse)
	await process_frame
	second_warehouse.setup(warehouse_config, null, [Vector2i(2, 0)])
	coordinator.register_plant(second_warehouse)
	_expect(second_warehouse.try_add_storage_item_count(WOOD, 1), "第二座仓库必须能加入跨仓原料。")
	_expect(coordinator.get_total_item_count(WOOD) == 1, "生产网络必须汇总全部仓库中的原料。")
	station.set_production_enabled(true)
	station.advance_shared_production_tick(10.0)
	_expect(
		coordinator.get_total_item_count(WOOD) == 0
		and coordinator.get_total_item_count(PLANK) == 10
		and coordinator.get_total_item_count(SAPLING) == 1,
		"加工站必须能跨仓扣料并把产物自动写入全场仓库网络，且不影响树苗。"
	)
	_expect(warehouse.try_add_storage_item_count(WATER_BOTTLE, 4), "核心配方缺料测试必须先准备4瓶水。")
	_expect(station.select_recipe(&"wooden_core_assembly"), "玩家必须能选择木制核心组装配方。")
	station.advance_shared_production_tick(10.0)
	_expect(
		coordinator.get_total_item_count(PLANK) == 10
		and coordinator.get_total_item_count(SAPLING) == 1
		and coordinator.get_total_item_count(WATER_BOTTLE) == 4
		and coordinator.get_total_item_count(WOODEN_CORE) == 0
		and station.completion_wait_reason == ProductionCoordinator.RESULT_MISSING_INPUT,
		"缺少任一投入时，核心配方不得部分扣除木板、树苗或水瓶。"
	)
	_expect(second_warehouse.try_add_storage_item_count(WATER_BOTTLE, 1), "补入第5瓶水必须成功。")
	_expect(
		coordinator.get_total_item_count(PLANK) == 0
		and coordinator.get_total_item_count(SAPLING) == 0
		and coordinator.get_total_item_count(WATER_BOTTLE) == 0
		and coordinator.get_total_item_count(WOODEN_CORE) == 1
		and is_zero_approx(station.progress_elapsed_seconds),
		"三种投入跨仓凑齐时必须在同一事务中扣除10/1/5并产出1个木制核心。"
	)
	_expect(
		second_warehouse.try_add_storage_item_count(DIRT_BLOCK, 20),
		"券配方必须能从共享仓库准备20个土块。"
	)
	_expect(
		station.select_recipe(&"gambler_ticket_assembly"),
		"玩家必须能选择赌怪专用券制作配方。"
	)
	station.advance_shared_production_tick(10.0)
	_expect(
		coordinator.get_total_item_count(DIRT_BLOCK) == 0
		and coordinator.get_total_item_count(GAMBLER_TICKET) == 1
		and run_state.get_inventory_item_total(GAMBLER_TICKET) == 0,
		"第10秒必须原子扣除共享仓库20土块、向共享仓库产出1张券，不能直接写入玩家背包。"
	)
	_test_utility_building_recipe_transactions(
		station,
		warehouse,
		coordinator,
		run_state
	)

	var building_texture := load(
		"res://resources/texture/plant_defense/wood_processing_station/wood_processing_station.png"
	) as Texture2D
	var plank_texture := PLANK.icon_texture
	var wooden_core_texture := WOODEN_CORE.icon_texture
	var gambler_ticket_texture := GAMBLER_TICKET.icon_texture
	var panel_texture := load(
		"res://resources/texture/production/production_panel_background.png"
	) as Texture2D
	_expect(building_texture != null and building_texture.get_size() == Vector2(64, 64), "加工站必须使用64×64像素画。")
	_expect(plank_texture != null and plank_texture.get_size() == Vector2(32, 32), "木板必须使用32×32物资图标。")
	_expect(
		wooden_core_texture != null
		and wooden_core_texture.get_size() == Vector2(32, 32),
		"木制核心必须使用32×32物资图标。"
	)
	_expect(
		gambler_ticket_texture != null
		and gambler_ticket_texture.get_size() == Vector2(32, 32)
		and GAMBLER_TICKET.description == "可以用于和洛茜进行特殊游戏"
		and GAMBLER_TICKET.stackable
		and GAMBLER_TICKET.inventory_stack_limit == 999,
		"赌怪专用券必须使用32×32图标、精确说明文字并支持999堆叠。"
	)
	_expect(panel_texture != null and panel_texture.get_size() == Vector2(728, 544), "通用生产面板背景必须为728×544。")
	var game_scene := load("res://scene/game_modes/tower_defense/tower_defense_game.tscn") as PackedScene
	var game_instance := game_scene.instantiate() if game_scene != null else null
	_expect(
		game_instance != null
		and game_instance.has_node("ProductionCoordinator")
		and game_instance.has_node("ProductionBuildingPanel")
		and not (game_instance.get_node("ProductionBuildingPanel") as CanvasLayer).visible,
		"塔防主场景必须常驻共享生产协调器与默认隐藏的生产面板。"
	)
	if game_instance != null:
		game_instance.free()

	await _test_nonstackable_production_input(test_root)
	await _test_multiplayer_production_contract(
		test_root,
		config,
		coordinator,
		panel,
		player
	)

	_finish(test_root)


func _test_nonstackable_production_input(test_root: Node) -> void:
	var isolated_coordinator := COORDINATOR_SCENE.instantiate() as ProductionCoordinator
	var isolated_warehouse := WAREHOUSE_SCENE.instantiate() as OakWarehouse
	test_root.add_child(isolated_coordinator)
	test_root.add_child(isolated_warehouse)
	await process_frame
	isolated_coordinator.production_tick_timer.stop()
	isolated_warehouse.setup(
		PlantDefenseRegistry.get_config(&"oak_warehouse"),
		null,
		[Vector2i(20, 0)]
	)
	isolated_coordinator.register_plant(isolated_warehouse)

	var recipe := ProductionRecipe.new()
	recipe.recipe_id = &"nonstackable_input_probe"
	recipe.display_name = "非堆叠投入探针"
	var input_items: Array[PickupConfig] = [BASKETBALL]
	var input_amounts: Array[int] = [2]
	var output_items: Array[PickupConfig] = [WOOD]
	var output_amounts: Array[int] = [1]
	recipe.input_items = input_items
	recipe.input_amounts = input_amounts
	recipe.output_items = output_items
	recipe.output_amounts = output_amounts
	recipe.output_destination = ProductionRecipe.OutputDestination.SHARED_STORAGE
	recipe.duration_seconds = 1.0

	_expect(
		recipe.is_valid()
		and isolated_warehouse.try_add_storage_item_count(BASKETBALL, 2)
		and isolated_warehouse.get_storage_item_total(BASKETBALL) == 2
		and isolated_coordinator.try_commit_recipe(recipe)
		== ProductionCoordinator.RESULT_SUCCESS
		and isolated_warehouse.get_storage_item_total(BASKETBALL) == 0
		and isolated_warehouse.get_storage_item_total(WOOD) == 1,
		"非堆叠物品必须能跨独立槽位统计并作为生产输入消费，但不能合并槽位。"
	)


func _recipe_matches(
	recipe: ProductionRecipe,
	expected_recipe_id: StringName,
	expected_input_items: Array,
	expected_input_amounts: Array,
	expected_output_item: PickupConfig,
	expected_output_amount: int,
	expected_duration_seconds: float,
	expected_outputs_to_shared_storage: bool
) -> bool:
	return (
		recipe != null
		and recipe.is_valid()
		and recipe.recipe_id == expected_recipe_id
		and recipe.input_items == expected_input_items
		and recipe.input_amounts == expected_input_amounts
		and recipe.output_items == [expected_output_item]
		and recipe.output_amounts == [expected_output_amount]
		and not recipe.inputs_from_player_inventory()
		and (
			recipe.output_destination
			== ProductionRecipe.OutputDestination.SHARED_STORAGE
		) == expected_outputs_to_shared_storage
		and is_equal_approx(
			recipe.duration_seconds,
			expected_duration_seconds
		)
	)


func _is_valid_building_item(
	item: PickupConfig,
	expected_plant_id: StringName
) -> bool:
	var plant_config := PlantDefenseRegistry.get_config(expected_plant_id)
	return (
		item != null
		and plant_config != null
		and item.pickup_type == PickupConfig.PickupType.BUILDING
		and item.can_store_in_inventory
		and item.stackable
		and item.inventory_stack_limit == 999
		and item.placeable_plant_id == expected_plant_id
		and item.icon_texture != null
		and item.icon_texture.resource_path == plant_config.icon.resource_path
		and item.icon_texture.get_size() == Vector2(64, 64)
		and item.icon_scale == Vector2(0.5, 0.5)
		and item.icon_texture.get_size() * item.icon_scale
		== Vector2(32, 32)
	)


func _test_utility_building_recipe_transactions(
	station: ProductionBuilding,
	warehouse: OakWarehouse,
	coordinator: ProductionCoordinator,
	run_state: RunStateStore
) -> void:
	var recipe_cases: Array[Dictionary] = [
		{
			"recipe_id": &"water_collector_assembly",
			"display_name": "水源采集器",
			"input_items": [PLANK],
			"input_amounts": [10],
			"output_item": WATER_COLLECTOR_ITEM,
		},
		{
			"recipe_id": &"planting_base_assembly",
			"display_name": "种植基地",
			"input_items": [PLANK, SAPLING, WATER_BOTTLE],
			"input_amounts": [20, 5, 5],
			"output_item": PLANTING_BASE_ITEM,
		},
		{
			"recipe_id": &"plant_cultivation_center_assembly",
			"display_name": "植物培育中心",
			"input_items": [PLANK, WATER_BOTTLE],
			"input_amounts": [30, 10],
			"output_item": PLANT_CULTIVATION_CENTER_ITEM,
		},
		{
			"recipe_id": &"research_center_assembly",
			"display_name": "科研中心",
			"input_items": [PLANK, WATER_BOTTLE],
			"input_amounts": [30, 10],
			"output_item": RESEARCH_CENTER_ITEM,
		},
		{
			"recipe_id": &"life_tower_assembly",
			"display_name": "生命强化塔",
			"input_items": [PLANK, SAPLING],
			"input_amounts": [10, 2],
			"output_item": LIFE_TOWER_ITEM,
		},
		{
			"recipe_id": &"speed_tower_assembly",
			"display_name": "移速强化塔",
			"input_items": [PLANK, SAPLING],
			"input_amounts": [10, 2],
			"output_item": SPEED_TOWER_ITEM,
		},
		{
			"recipe_id": &"attack_speed_tower_assembly",
			"display_name": "攻速强化塔",
			"input_items": [PLANK, SAPLING],
			"input_amounts": [10, 2],
			"output_item": ATTACK_SPEED_TOWER_ITEM,
		},
	]
	for recipe_case in recipe_cases:
		var recipe_id := StringName(recipe_case["recipe_id"])
		var display_name := String(recipe_case["display_name"])
		var input_items: Array = recipe_case["input_items"]
		var input_amounts: Array = recipe_case["input_amounts"]
		var output_item := recipe_case["output_item"] as PickupConfig
		var inputs_added := true
		for input_index in input_items.size():
			inputs_added = (
				warehouse.try_add_storage_item_count(
					input_items[input_index] as PickupConfig,
					int(input_amounts[input_index])
				)
				and inputs_added
			)
		_expect(inputs_added, "%s配方必须能准备全部测试原料。" % display_name)
		_expect(station.select_recipe(recipe_id), "必须能选择%s组装配方。" % display_name)
		var warehouse_output_total_before := coordinator.get_total_item_count(output_item)
		var inventory_output_total_before := run_state.get_inventory_item_total(output_item)
		var inventory_revision_before := run_state.get_inventory_revision()
		station.advance_shared_production_tick(29.0)
		var inputs_unchanged := true
		for input_index in input_items.size():
			inputs_unchanged = (
				coordinator.get_total_item_count(
					input_items[input_index] as PickupConfig
				) == int(input_amounts[input_index])
				and inputs_unchanged
			)
		_expect(
			inputs_unchanged
			and coordinator.get_total_item_count(output_item)
			== warehouse_output_total_before
			and run_state.get_inventory_item_total(output_item)
			== inventory_output_total_before
			and run_state.get_inventory_revision() == inventory_revision_before
			and is_equal_approx(station.progress_elapsed_seconds, 29.0),
			"%s组装到29秒时不得扣料或提前进入仓库。" % display_name
		)
		station.advance_shared_production_tick(1.0)
		var inputs_consumed := true
		for input_item in input_items:
			inputs_consumed = (
				coordinator.get_total_item_count(input_item as PickupConfig) == 0
				and inputs_consumed
			)
		_expect(
			inputs_consumed
			and coordinator.get_total_item_count(output_item)
			== warehouse_output_total_before + 1
			and run_state.get_inventory_item_total(output_item)
			== inventory_output_total_before
			and run_state.get_inventory_revision() == inventory_revision_before
			and is_zero_approx(station.progress_elapsed_seconds),
			"%s必须在第30秒原子扣料并作为建筑物品进入共享仓库。" % display_name
		)


func _make_personal_output_recipe_fixture() -> ProductionRecipe:
	var recipe := ProductionRecipe.new()
	recipe.recipe_id = &"personal_output_contract_fixture"
	recipe.display_name = "个人产物契约夹具"
	var output_items: Array[PickupConfig] = [WATER_COLLECTOR_ITEM]
	var output_amounts: Array[int] = [1]
	recipe.output_items = output_items
	recipe.output_amounts = output_amounts
	recipe.output_destination = ProductionRecipe.OutputDestination.PLAYER_INVENTORY
	recipe.duration_seconds = 1.0
	return recipe


func _test_multiplayer_production_contract(
	test_root: Node,
	config: PlantDefenseConfig,
	coordinator: ProductionCoordinator,
	panel: ProductionBuildingPanel,
	player: Player
) -> void:
	_expect(
		not ProductionBuildingProtocol.is_valid_command({
			"operation": ProductionBuildingProtocol.OPERATION_SET_ENABLED,
			"request_id": "1",
			"building_net_id": 7,
			"peer_id": 2,
			"expected_production_revision": 0,
			"enabled": true,
		}),
		"生产协议必须拒绝伪装成字符串的请求ID。"
	)
	_expect(
		not ProductionBuildingProtocol.is_valid_command({
			"operation": ProductionBuildingProtocol.OPERATION_SET_LOOP_ENABLED,
			"request_id": 2,
			"building_net_id": 7,
			"peer_id": 2,
			"expected_production_revision": 0,
			"loop_enabled": 1,
		}),
		"循环生产命令必须严格拒绝用整数伪装的布尔值。"
	)
	_expect(
		not ProductionBuildingProtocol.is_valid_command({
			"operation": ProductionBuildingProtocol.OPERATION_SELECT_RECIPE,
			"request_id": 1,
			"building_net_id": 7,
			"peer_id": 2,
			"expected_production_revision": 0,
			"recipe_id": 123,
		}),
		"生产协议必须严格拒绝类型非法的配方ID。"
	)
	var collect_output_command := (
		ProductionBuildingProtocol.make_collect_output_command(7, 8, 2, 3)
	)
	_expect(
		ProductionBuildingProtocol.is_valid_command(collect_output_command)
		and ProductionBuildingProtocol.get_operation(collect_output_command)
		== ProductionBuildingProtocol.OPERATION_COLLECT_OUTPUT
		and ProductionBuildingProtocol.canonicalize_command(
			collect_output_command,
			2
		) == collect_output_command,
		"领取产物命令必须可构造、通过严格校验并完整通过Host白名单规范化。"
	)
	var authority := config.plant_scene.instantiate() as ProductionBuilding
	var personal_recipe := _make_personal_output_recipe_fixture()
	authority.recipes.append(personal_recipe)
	test_root.add_child(authority)
	await process_frame
	authority.setup(config, null, [Vector2i(4, 0)])
	coordinator.configure_multiplayer_output_peers([2, 3])
	coordinator.register_plant(authority)
	var replication_flags: Array[bool] = []
	authority.production_state_changed.connect(
		func(replicate: bool) -> void: replication_flags.append(replicate)
	)
	var first_command := ProductionBuildingProtocol.make_select_recipe_command(
		1,
		8,
		2,
		0,
		&"water_collector_assembly"
	)
	var command_with_untrusted_extensions := first_command.duplicate()
	command_with_untrusted_extensions["nested_junk"] = {
		"payload": [
			{"unexpected": "value"},
		],
	}
	var canonical_command := ProductionBuildingProtocol.canonicalize_command(
		command_with_untrusted_extensions,
		2
	)
	var oversized_recipe_command := first_command.duplicate()
	oversized_recipe_command["recipe_id"] = "x".repeat(
		ProductionBuildingProtocol.MAX_RECIPE_ID_WIRE_LENGTH + 1
	)
	_expect(
		canonical_command == first_command
		and not canonical_command.has("nested_junk")
		and ProductionBuildingProtocol.canonicalize_command(
			oversized_recipe_command,
			2
		).is_empty(),
		"Host生产命令解码必须只复制白名单字段，并拒绝超长配方ID。"
	)
	var forged_peer_command := first_command.duplicate(true)
	forged_peer_command["peer_id"] = 99
	_expect(
		ProductionBuildingProtocol.command_peer_matches(first_command, 2)
		and ProductionBuildingProtocol.canonicalize_command(
			forged_peer_command,
			2
		).is_empty()
		and not ProductionBuildingProtocol.command_peer_matches(
			forged_peer_command,
			2
		),
		"主机必须拒绝命令内伪造或类型不匹配的peer ID。"
	)
	var interaction_player := PLAYER_SCENE.instantiate() as Player
	test_root.add_child(interaction_player)
	await process_frame
	authority.global_position = Vector2.ZERO
	interaction_player.global_position = Vector2(48, 0)
	var edge_is_allowed := authority.is_player_within_multiplayer_interaction_distance(
		interaction_player,
		48.0
	)
	interaction_player.global_position = Vector2(48.01, 0)
	_expect(
		edge_is_allowed
		and not authority.is_player_within_multiplayer_interaction_distance(
			interaction_player,
			48.0
		),
		"多人生产交互必须严格限制在48像素内。"
	)
	var competing_command := ProductionBuildingProtocol.make_set_enabled_command(
		2,
		8,
		3,
		0,
		false
	)
	var loop_command := ProductionBuildingProtocol.make_set_loop_enabled_command(
		3,
		8,
		2,
		1,
		true
	)
	_expect(
		authority.apply_authoritative_multiplayer_production_command(first_command)
		== ProductionBuildingProtocol.RESULT_SUCCESS
		and ProductionBuildingProtocol.is_valid_command(loop_command)
		and ProductionBuildingProtocol.canonicalize_command(loop_command, 2)
		== loop_command
		and authority.apply_authoritative_multiplayer_production_command(loop_command)
		== ProductionBuildingProtocol.RESULT_SUCCESS
		and authority.apply_authoritative_multiplayer_production_command(
			competing_command
		) == ProductionBuildingProtocol.RESULT_STALE_STATE
		and authority.production_enabled
		and authority.production_loop_enabled
		and authority.active_recipe_id == &"water_collector_assembly"
		and authority.personal_output_peer_id == 0
		and authority.production_revision == 2,
		"Host必须权威应用严格布尔循环命令；相同revision的后到命令必须零写入。"
	)
	var invalid_recipe_command := ProductionBuildingProtocol.make_select_recipe_command(
		3,
		8,
		2,
		2,
		&"missing_recipe"
	)
	_expect(
		authority.apply_authoritative_multiplayer_production_command(
			invalid_recipe_command
		) == ProductionBuildingProtocol.RESULT_INVALID_RECIPE
		and authority.production_revision == 2,
		"非法配方必须返回invalid_recipe且不得写入生产状态。"
	)
	var personal_command := ProductionBuildingProtocol.make_select_recipe_command(
		4,
		8,
		2,
		2,
		personal_recipe.recipe_id
	)
	_expect(
		authority.apply_authoritative_multiplayer_production_command(
			personal_command
		) == ProductionBuildingProtocol.RESULT_SUCCESS
		and authority.active_recipe_id == personal_recipe.recipe_id
		and authority.personal_output_peer_id == 2
		and authority.production_revision == 3,
		"合成的个人产物夹具必须继续覆盖选择者Peer绑定契约。"
	)
	var run_state := root.get_node("RunState") as RunStateStore
	coordinator.deactivate_personal_output_peer(2)
	_expect(
		authority.active_recipe_id == &""
		and authority.personal_output_peer_id == 0
		and authority.completion_wait_reason
		== ProductionCoordinator.RESULT_OUTPUT_PEER_UNAVAILABLE
		and authority.production_revision == 4
		and replication_flags == [true, true, true, false]
		and not run_state.has_multiplayer_peer_state(2)
		and coordinator.try_commit_recipe(personal_recipe, 2)
		== ProductionCoordinator.RESULT_OUTPUT_PEER_UNAVAILABLE
		and not run_state.has_multiplayer_peer_state(2),
		"玩家断线必须本地撤销个人产物绑定，且不得发布生产包或创建幽灵背包。"
	)
	var mp_game := MP_GAME_SCENE.instantiate()
	var tower_economy := mp_game.get_node("TowerEconomyCoordinator")
	var rate_buckets: Dictionary = {}
	var burst_was_accepted := true
	for _request_index in 12:
		burst_was_accepted = burst_was_accepted and bool(tower_economy.call(
			"_consume_peer_rate_token",
			rate_buckets,
			2,
			8.0,
			12.0
		))
	_expect(
		burst_was_accepted
		and not bool(tower_economy.call(
			"_consume_peer_rate_token",
			rate_buckets,
			2,
			8.0,
			12.0
		)),
		"每名玩家的生产命令限流必须允许突发12次并拒绝紧随其后的第13次。"
	)
	var cached_result := ProductionBuildingProtocol.make_result(
		first_command,
		true,
		ProductionBuildingProtocol.RESULT_SUCCESS,
		1,
		authority.export_multiplayer_runtime_state(),
		0.0
	)
	tower_economy.call(
		"_cache_production_command_result",
		2,
		8,
		1,
		cached_result
	)
	_expect(
		tower_economy.call("_get_cached_production_command_result", 2, 8, 1)
		== cached_result,
		"重复生产请求必须命中幂等结果缓存而不是再次执行。"
	)
	mp_game.free()
	var proxy := config.plant_scene.instantiate() as ProductionBuilding
	proxy.recipes.append(personal_recipe)
	test_root.add_child(proxy)
	await process_frame
	proxy.setup(config, null, [Vector2i(3, 0)], true, config.max_health, 1)
	coordinator.register_plant(proxy)
	proxy.configure_multiplayer_production(7, 2, true)
	var requested_commands: Array[Dictionary] = []
	var snapshot_requests: Array[int] = []
	proxy.production_command_requested.connect(
		func(command: Dictionary) -> void: requested_commands.append(command)
	)
	proxy.production_snapshot_requested.connect(
		func(building_net_id: int) -> void: snapshot_requests.append(building_net_id)
	)
	_expect(
		not proxy.select_recipe(&"wood_to_plank")
		and not proxy.set_production_enabled(false)
		and not proxy.set_production_loop_enabled(true)
		and proxy.active_recipe_id == &""
		and proxy.production_enabled
		and not proxy.production_loop_enabled,
		"客户端生产副本不得通过单人接口直接改配方、启停或循环状态。"
	)
	proxy.advance_shared_production_tick(10.0)
	_expect(
		is_zero_approx(proxy.progress_elapsed_seconds),
		"客户端生产副本不得自行推进权威进度。"
	)
	_expect(
		proxy.request_multiplayer_recipe_selection(&"wood_to_plank")
		and requested_commands.size() == 1
		and int(requested_commands[0]["expected_production_revision"]) == 0
		and proxy.multiplayer_production_request_pending,
		"客户端选择配方必须携带当前revision并进入等待主机状态。"
	)
	var authoritative_state := {
		"schema": ProductionBuilding.RUNTIME_STATE_SCHEMA,
		"enabled": true,
		"loop_enabled": true,
		"active_recipe_id": "wood_to_plank",
		"progress_elapsed_seconds": 4.0,
		"wait_reason": "",
		"buffered_output_config_path": "",
		"buffered_output_count": 0,
		"personal_output_peer_id": 0,
		"revision": 1,
		"projection_duration_seconds": 0.5,
	}
	var result := ProductionBuildingProtocol.make_result(
		requested_commands[0],
		true,
		ProductionBuildingProtocol.RESULT_SUCCESS,
		1,
		authoritative_state,
		Time.get_ticks_msec() / 1000.0
	)
	proxy.apply_multiplayer_runtime_state(
		authoritative_state,
		Time.get_ticks_msec() / 1000.0
	)
	_expect(
		proxy.complete_multiplayer_production_request(result)
		and not proxy.multiplayer_production_request_pending
		and proxy.active_recipe_id == &"wood_to_plank"
		and proxy.production_loop_enabled
		and proxy.production_revision == 1
		and is_equal_approx(proxy.progress_elapsed_seconds, 4.0),
		"成功或失败结果都必须以完整权威状态结束请求。"
	)
	var stale_state := authoritative_state.duplicate(true)
	stale_state["revision"] = 0
	stale_state["enabled"] = false
	stale_state["loop_enabled"] = false
	proxy.apply_multiplayer_runtime_state(
		stale_state,
		Time.get_ticks_msec() / 1000.0
	)
	_expect(
		proxy.production_enabled
		and proxy.production_loop_enabled
		and proxy.production_revision == 1,
		"过期状态包不得覆盖客户端已应用的较新权威状态。"
	)
	var missing_loop_state := authoritative_state.duplicate(true)
	missing_loop_state.erase("loop_enabled")
	missing_loop_state["revision"] = 2
	proxy.apply_multiplayer_runtime_state(
		missing_loop_state,
		Time.get_ticks_msec() / 1000.0 + 0.001
	)
	var invalid_loop_state := authoritative_state.duplicate(true)
	invalid_loop_state["loop_enabled"] = 1
	invalid_loop_state["revision"] = 2
	proxy.apply_multiplayer_runtime_state(
		invalid_loop_state,
		Time.get_ticks_msec() / 1000.0 + 0.002
	)
	_expect(
		proxy.production_loop_enabled and proxy.production_revision == 1,
		"schema 5状态缺少循环字段或循环字段不是严格布尔值时必须整包拒绝。"
	)
	panel.bind_building(proxy, player)
	_expect(
		not panel.loop_button.disabled and not panel.toggle_button.disabled,
		"多人状态就绪且无请求在途时，启停与∞按钮都必须可用。"
	)
	_expect(
		proxy.request_multiplayer_loop_change(false)
		and requested_commands.size() == 2
		and requested_commands[1]["operation"]
		== ProductionBuildingProtocol.OPERATION_SET_LOOP_ENABLED
		and requested_commands[1]["loop_enabled"] == false
		and panel.loop_button.disabled
		and panel.toggle_button.disabled,
		"客户端提交循环命令后必须锁定启停与∞按钮，直至Host确认或超时补快照。"
	)
	proxy.call("_on_multiplayer_production_request_timeout")
	_expect(
		not proxy.multiplayer_production_request_pending
		and not proxy.multiplayer_production_snapshot_ready
		and snapshot_requests == [7],
		"4秒命令超时必须取消假操作并请求权威快照。"
	)
	proxy.multiplayer_production_request_timer.stop()
	var late_disconnected_peer_state := authoritative_state.duplicate(true)
	late_disconnected_peer_state["active_recipe_id"] = String(personal_recipe.recipe_id)
	late_disconnected_peer_state["personal_output_peer_id"] = 2
	late_disconnected_peer_state["progress_elapsed_seconds"] = 29.0
	late_disconnected_peer_state["revision"] = 2
	proxy.apply_multiplayer_runtime_state(
		late_disconnected_peer_state,
		Time.get_ticks_msec() / 1000.0
	)
	_expect(
		proxy.production_revision == 2
		and proxy.active_recipe_id == &""
		and proxy.personal_output_peer_id == 0
		and is_zero_approx(proxy.progress_elapsed_seconds)
		and proxy.completion_wait_reason
		== ProductionCoordinator.RESULT_OUTPUT_PEER_UNAVAILABLE,
		"断线事件之后到达的可靠旧状态不得复活已失效的个人产物绑定。"
	)


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
		push_error(message)


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
	test_root.queue_free()
	await process_frame
	if failures.is_empty():
		print("PRODUCTION_BUILDING_SMOKE_TEST_OK")
		quit(0)
	else:
		print("PRODUCTION_BUILDING_SMOKE_TEST_FAILED: %d" % failures.size())
		quit(1)
