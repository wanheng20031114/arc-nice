extends SceneTree

const COORDINATOR_SCENE := preload(
	"res://scene/plant_defense/production_coordinator.tscn"
)
const WAREHOUSE_SCENE := preload("res://scene/plant_defense/oak_warehouse.tscn")
const PANEL_SCENE := preload("res://scene/plant_defense/production_building_panel.tscn")
const PLAYER_SCENE := preload("res://scene/player/weishidaier/player_weishidaier.tscn")
const MP_GAME_SCENE := preload("res://scene/multiplayer/mp_game.tscn")
const WOOD := preload("res://resources/config/materials/material_wood.tres")
const SAPLING := preload("res://resources/config/materials/material_sapling.tres")
const PLANK := preload("res://resources/config/materials/material_plank.tres")
const WATER_BOTTLE := preload(
	"res://resources/config/materials/material_water_bottle.tres"
)
const WOODEN_CORE := preload(
	"res://resources/config/materials/material_wooden_core.tres"
)

var failures: PackedStringArray = []


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var test_root := Node.new()
	test_root.name = "ProductionBuildingSmokeTest"
	root.add_child(test_root)

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
		and panel.has_node("Overlay/PanelRoot/ToggleButton"),
		"生产面板必须原生搭建左右各3个候选槽位、物资列表与右上角开关。"
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
	_expect(
		panel.recipe_rows[0].icon == PLANK.icon_texture
		and panel.recipe_rows[0].icon != WOOD.icon_texture
		and panel.recipe_rows[1].icon == WOODEN_CORE.icon_texture,
		"右侧配方列表必须分别显示木板和木制核心的产物图标。"
	)
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
		station.recipes.size() == 2
		and station.recipes[0].input_items == [WOOD]
		and station.recipes[0].input_amounts == [1]
		and station.recipes[0].output_items == [PLANK]
		and station.recipes[0].output_amounts == [2]
		and is_equal_approx(station.recipes[0].duration_seconds, 10.0)
		and station.recipes[1].input_items == [PLANK, SAPLING, WATER_BOTTLE]
		and station.recipes[1].input_amounts == [10, 1, 5]
		and station.recipes[1].output_items == [WOODEN_CORE]
		and station.recipes[1].output_amounts == [1],
		"加工站必须保留木材锯切，并新增10木板、1树苗、5水瓶制作1木制核心的配方。"
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
		and is_zero_approx(station.progress_elapsed_seconds),
		"第10秒必须在同一事务中扣1木头并向仓库加入2木板。"
	)
	if production_border != null:
		_expect(
			is_zero_approx(
				float(production_border.get_instance_shader_parameter(&"progress_value"))
			),
			"一轮完成后环形进度必须从零开始平滑显示下一轮，不能改变权威生产事务。"
		)

	station.advance_shared_production_tick(10.0)
	_expect(
		is_equal_approx(station.get_progress_ratio(), 1.0)
		and station.completion_wait_reason == ProductionCoordinator.RESULT_MISSING_INPUT
		and coordinator.get_total_item_count(PLANK) == 2,
		"缺料时生产仍须到剩余0秒并停在那里，且不得凭空产出。"
	)
	_expect(warehouse.try_add_storage_item_count(WOOD, 1), "仓库必须能补入等待中的原料。")
	_expect(
		coordinator.get_total_item_count(WOOD) == 0
		and coordinator.get_total_item_count(PLANK) == 4
		and is_zero_approx(station.progress_elapsed_seconds),
		"等待中的原料一进入任意仓库，必须在同帧完成一轮生产。"
	)

	_expect(warehouse.try_add_storage_item_count(WOOD, 1), "仓库必须能加入暂停测试原料。")
	_expect(warehouse.try_add_storage_item_count(SAPLING, 1), "仓库必须能加入无效树苗。")
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
		and coordinator.get_total_item_count(PLANK) == 6
		and coordinator.get_total_item_count(SAPLING) == 1,
		"加工站必须能跨仓扣料并把产物自动写入全场仓库网络，且不影响树苗。"
	)
	_expect(second_warehouse.try_add_storage_item_count(PLANK, 4), "核心配方必须能准备余下4份木板。")
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

	var building_texture := load(
		"res://resources/texture/plant_defense/wood_processing_station/wood_processing_station.png"
	) as Texture2D
	var plank_texture := PLANK.icon_texture
	var wooden_core_texture := WOODEN_CORE.icon_texture
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
	_expect(panel_texture != null and panel_texture.get_size() == Vector2(728, 544), "通用生产面板背景必须为728×544。")
	var game_scene := load("res://scene/game_tower_defense.tscn") as PackedScene
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

	await _test_multiplayer_production_contract(test_root, config)

	_finish(test_root)


func _test_multiplayer_production_contract(
	test_root: Node,
	config: PlantDefenseConfig
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
			"operation": ProductionBuildingProtocol.OPERATION_SELECT_RECIPE,
			"request_id": 1,
			"building_net_id": 7,
			"peer_id": 2,
			"expected_production_revision": 0,
			"recipe_id": 123,
		}),
		"生产协议必须严格拒绝类型非法的配方ID。"
	)
	var authority := config.plant_scene.instantiate() as ProductionBuilding
	test_root.add_child(authority)
	await process_frame
	authority.setup(config, null, [Vector2i(4, 0)])
	var first_command := ProductionBuildingProtocol.make_select_recipe_command(
		1,
		8,
		2,
		0,
		&"wood_to_plank"
	)
	var forged_peer_command := first_command.duplicate(true)
	forged_peer_command["peer_id"] = 99
	_expect(
		ProductionBuildingProtocol.command_peer_matches(first_command, 2)
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
	_expect(
		authority.apply_authoritative_multiplayer_production_command(first_command)
		== ProductionBuildingProtocol.RESULT_SUCCESS
		and authority.apply_authoritative_multiplayer_production_command(
			competing_command
		) == ProductionBuildingProtocol.RESULT_STALE_STATE
		and authority.production_enabled
		and authority.production_revision == 1,
		"相同revision的并发命令必须只接受首个有效命令，后到者返回stale_state且零写入。"
	)
	var invalid_recipe_command := ProductionBuildingProtocol.make_select_recipe_command(
		3,
		8,
		2,
		1,
		&"missing_recipe"
	)
	_expect(
		authority.apply_authoritative_multiplayer_production_command(
			invalid_recipe_command
		) == ProductionBuildingProtocol.RESULT_INVALID_RECIPE
		and authority.production_revision == 1,
		"非法配方必须返回invalid_recipe且不得写入生产状态。"
	)
	var mp_game := MP_GAME_SCENE.instantiate()
	var rate_buckets: Dictionary = {}
	var burst_was_accepted := true
	for _request_index in 12:
		burst_was_accepted = burst_was_accepted and bool(mp_game.call(
			"_consume_peer_rate_token",
			rate_buckets,
			2,
			8.0,
			12.0
		))
	_expect(
		burst_was_accepted
		and not bool(mp_game.call(
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
	mp_game.call(
		"_cache_production_command_result",
		2,
		8,
		1,
		cached_result
	)
	_expect(
		mp_game.call("_get_cached_production_command_result", 2, 8, 1)
		== cached_result,
		"重复生产请求必须命中幂等结果缓存而不是再次执行。"
	)
	mp_game.free()
	var proxy := config.plant_scene.instantiate() as ProductionBuilding
	test_root.add_child(proxy)
	await process_frame
	proxy.setup(config, null, [Vector2i(3, 0)], true, config.max_health, 1)
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
		and proxy.active_recipe_id == &""
		and proxy.production_enabled,
		"客户端生产副本不得通过单人接口直接改配方或开关。"
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
		"active_recipe_id": "wood_to_plank",
		"progress_elapsed_seconds": 4.0,
		"wait_reason": "",
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
		and proxy.production_revision == 1
		and is_equal_approx(proxy.progress_elapsed_seconds, 4.0),
		"成功或失败结果都必须以完整权威状态结束请求。"
	)
	var stale_state := authoritative_state.duplicate(true)
	stale_state["revision"] = 0
	stale_state["enabled"] = false
	proxy.apply_multiplayer_runtime_state(
		stale_state,
		Time.get_ticks_msec() / 1000.0
	)
	_expect(
		proxy.production_enabled and proxy.production_revision == 1,
		"过期状态包不得覆盖客户端已应用的较新权威状态。"
	)
	_expect(
		proxy.request_multiplayer_enabled_change(false),
		"同步完成后客户端必须能提交下一条开关命令。"
	)
	proxy.call("_on_multiplayer_production_request_timeout")
	_expect(
		not proxy.multiplayer_production_request_pending
		and not proxy.multiplayer_production_snapshot_ready
		and snapshot_requests == [7],
		"4秒命令超时必须取消假操作并请求权威快照。"
	)
	proxy.multiplayer_production_request_timer.stop()


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
		push_error(message)


func _finish(test_root: Node) -> void:
	test_root.queue_free()
	await process_frame
	if failures.is_empty():
		print("PRODUCTION_BUILDING_SMOKE_TEST_OK")
		quit(0)
	else:
		print("PRODUCTION_BUILDING_SMOKE_TEST_FAILED: %d" % failures.size())
		quit(1)
