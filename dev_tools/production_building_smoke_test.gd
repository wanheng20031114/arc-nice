extends SceneTree

const COORDINATOR_SCENE := preload(
	"res://scene/plant_defense/production_coordinator.tscn"
)
const WAREHOUSE_SCENE := preload("res://scene/plant_defense/oak_warehouse.tscn")
const PANEL_SCENE := preload("res://scene/plant_defense/production_building_panel.tscn")
const PLAYER_SCENE := preload("res://scene/player/weishidaier/player_weishidaier.tscn")
const WOOD := preload("res://resources/config/materials/material_wood.tres")
const SAPLING := preload("res://resources/config/materials/material_sapling.tres")
const PLANK := preload("res://resources/config/materials/material_plank.tres")

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

	_expect(
		coordinator.get_node("ProductionTickTimer") is Timer
		and station.find_children("*", "Timer", true, false).is_empty(),
		"全场生产必须只有协调器的共享Timer，加工站实例不得自带生产Timer。"
	)
	var health_bar := station.get_node("HealthBar") as PlantHealthBar
	_expect(
		health_bar != null
		and health_bar.size == Vector2(12, 3)
		and health_bar.position == Vector2(-6, -13)
		and health_bar.scale == Vector2.ONE,
		"木头加工站必须使用与植被桩一致的12×3原生像素血条，不得比例缩放。"
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
		panel.has_node("Overlay/PanelRoot/InputSlot")
		and panel.has_node("Overlay/PanelRoot/OutputSlot1")
		and panel.has_node("Overlay/PanelRoot/OutputSlot2")
		and panel.has_node("Overlay/PanelRoot/OutputSlot3")
		and panel.has_node("Overlay/PanelRoot/MaterialList")
		and panel.has_node("Overlay/PanelRoot/ToggleButton"),
		"生产面板必须原生搭建1个原料槽、3个产物槽、物资列表与右上角开关。"
	)
	panel.open_for(station, player)
	await process_frame
	_expect(panel.is_open() and panel.visible and player.controls_locked, "靠近交互打开生产面板后必须锁定玩家控制。")
	panel.call("_on_input_slot_pressed")
	_expect(
		panel.material_list.visible
		and panel.wood_button.text.contains("木头")
		and panel.sapling_button.text.contains("树苗"),
		"点击原料槽必须显示带图像与名称的木头、树苗列表。"
	)
	panel.call("_on_sapling_pressed")
	_expect(panel.status_label.text.contains("不匹配"), "选择树苗必须明确显示无效且不改变配方。")
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
		station.recipes.size() == 1
		and station.recipes[0].input_item == WOOD
		and station.recipes[0].input_amount == 1
		and station.recipes[0].output_items == [PLANK]
		and station.recipes[0].output_amounts == [2]
		and is_equal_approx(station.recipes[0].duration_seconds, 10.0),
		"木材锯切配方必须为1木头、10秒、产出2木板。"
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

	var building_texture := load(
		"res://resources/texture/plant_defense/wood_processing_station/wood_processing_station.png"
	) as Texture2D
	var plank_texture := PLANK.icon_texture
	var panel_texture := load(
		"res://resources/texture/production/production_panel_background.png"
	) as Texture2D
	_expect(building_texture != null and building_texture.get_size() == Vector2(64, 64), "加工站必须使用64×64像素画。")
	_expect(plank_texture != null and plank_texture.get_size() == Vector2(32, 32), "木板必须使用32×32物资图标。")
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

	_finish(test_root)


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
