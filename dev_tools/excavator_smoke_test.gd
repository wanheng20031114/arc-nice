extends SceneTree

const COORDINATOR_SCENE := preload(
	"res://scene/game_modes/tower_defense/economy/production/production_coordinator.tscn"
)
const PANEL_SCENE := preload(
	"res://scene/game_modes/tower_defense/economy/production/production_building_panel.tscn"
)
const WAREHOUSE_SCENE := preload("res://scene/plant_defense/oak_warehouse.tscn")
const PLAYER_SCENE := preload(
	"res://scene/player/weishidaier/player_weishidaier.tscn"
)
const EXCAVATOR_CONFIG: PlantDefenseConfig = preload(
	"res://resources/config/plant_defense/excavator.tres"
)
const WAREHOUSE_CONFIG: PlantDefenseConfig = preload(
	"res://resources/config/plant_defense/oak_warehouse.tres"
)
const WOOD_PROCESSING_CONFIG: PlantDefenseConfig = preload(
	"res://resources/config/plant_defense/wood_processing_station.tres"
)
const EXCAVATOR_CYCLE: ProductionRecipe = preload(
	"res://resources/config/production/excavator_cycle.tres"
)
const EXCAVATOR_ASSEMBLY: ProductionRecipe = preload(
	"res://resources/config/production/excavator_assembly.tres"
)
const EXCAVATOR_ITEM: PickupConfig = preload(
	"res://resources/config/buildings/building_excavator.tres"
)
const DIRT_BLOCK: PickupConfig = preload(
	"res://resources/config/materials/material_dirt_block.tres"
)
const PLANK: PickupConfig = preload(
	"res://resources/config/materials/material_plank.tres"
)

const EXCAVATOR_SCENE_PATH := "res://scene/plant_defense/excavator.tscn"
const EXCAVATOR_TEXTURE_PATH := (
	"res://resources/texture/plant_defense/excavator/excavator.png"
)
const EXCAVATOR_CELLS: Array[Vector2i] = [
	Vector2i.ZERO,
	Vector2i.RIGHT,
	Vector2i.DOWN,
	Vector2i.ONE,
]
const WAREHOUSE_CELLS: Array[Vector2i] = [
	Vector2i(-2, 0),
	Vector2i(-1, 0),
	Vector2i(-2, 1),
	Vector2i(-1, 1),
]

var failures: PackedStringArray = []


func _initialize() -> void:
	call_deferred(&"_run")


func _run() -> void:
	var test_root := Node.new()
	test_root.name = "ExcavatorSmokeTest"
	root.add_child(test_root)

	var coordinator := COORDINATOR_SCENE.instantiate() as ProductionCoordinator
	var panel := PANEL_SCENE.instantiate() as ProductionBuildingPanel
	var warehouse := WAREHOUSE_SCENE.instantiate() as OakWarehouse
	var excavator := EXCAVATOR_CONFIG.plant_scene.instantiate() as Excavator
	var wood_station := (
		WOOD_PROCESSING_CONFIG.plant_scene.instantiate() as ProductionBuilding
	)
	var owner_player := PLAYER_SCENE.instantiate() as Player
	test_root.add_child(coordinator)
	test_root.add_child(panel)
	test_root.add_child(owner_player)
	if warehouse != null:
		test_root.add_child(warehouse)
	if excavator != null:
		test_root.add_child(excavator)
	if wood_station != null:
		test_root.add_child(wood_station)
	await process_frame
	coordinator.production_tick_timer.stop()

	_test_config_and_scene(excavator)
	_test_recipe_contract()
	_test_assembly_recipe(wood_station)
	if warehouse == null or excavator == null:
		await _finish(test_root)
		return

	warehouse.setup(WAREHOUSE_CONFIG, owner_player, WAREHOUSE_CELLS)
	excavator.setup(EXCAVATOR_CONFIG, owner_player, EXCAVATOR_CELLS)
	coordinator.register_plant(excavator)
	_test_automatic_panel_layout(panel, excavator, owner_player)
	_test_missing_warehouse_retry(coordinator, warehouse, excavator)
	_clear_warehouse(warehouse)
	_expect(
		excavator.set_production_enabled(true),
		"缺仓补交夹具结束后必须能重启默认单次挖掘。"
	)
	_test_direct_warehouse_production(coordinator, warehouse, excavator)
	await _test_multiplayer_buffer_contract(test_root, excavator)
	await _finish(test_root)


func _test_config_and_scene(excavator: Excavator) -> void:
	_expect(
		PlantDefenseRegistry.get_config(PlantDefenseRegistry.EXCAVATOR_ID)
		== EXCAVATOR_CONFIG
		and EXCAVATOR_CONFIG.is_valid()
		and EXCAVATOR_CONFIG.plant_id == &"excavator"
		and EXCAVATOR_CONFIG.plant_scene != null
		and EXCAVATOR_CONFIG.plant_scene.resource_path == EXCAVATOR_SCENE_PATH
		and EXCAVATOR_CONFIG.supports_multiplayer,
		"挖土装置必须以独立有效配置和场景注册，并允许多人同步。"
	)
	_expect(
		EXCAVATOR_CONFIG.footprint_size == Vector2i(2, 2)
		and EXCAVATOR_CONFIG.placement_surface
		== PlantDefenseConfig.PlacementSurface.ANY_LAND,
		"挖土装置必须占2×2格，并显式支持任意陆地。"
	)
	_expect(
		excavator != null
		and excavator.get_script() != null
		and excavator.get_script().resource_path
		== "res://scene/plant_defense/excavator.gd",
		"挖土装置场景根节点必须使用Excavator生产建筑脚本。"
	)
	if excavator == null:
		return

	var sprite := excavator.get_node_or_null("MainSprite") as Sprite2D
	var texture := sprite.texture if sprite != null else null
	_expect(
		sprite != null
		and texture != null
		and texture.resource_path == EXCAVATOR_TEXTURE_PATH
		and texture.get_size() == Vector2(64, 64)
		and sprite.scale == Vector2(0.5, 0.5)
		and texture.get_size() * sprite.scale == Vector2(32, 32)
		and sprite.texture_filter == CanvasItem.TEXTURE_FILTER_NEAREST,
		"挖土装置必须使用64×64原图、0.5缩放和邻近过滤显示为32×32世界像素。"
	)
	_expect(
		EXCAVATOR_ITEM.pickup_type == PickupConfig.PickupType.BUILDING
		and EXCAVATOR_ITEM.placeable_plant_id == &"excavator"
		and EXCAVATOR_ITEM.icon_texture == texture
		and EXCAVATOR_ITEM.icon_scale == Vector2(0.5, 0.5),
		"装箱后的挖土装置必须复用同一像素图并以0.5图标缩放指向excavator。"
	)
	_expect(
		excavator.recipes == [EXCAVATOR_CYCLE]
		and excavator.auto_select_first_recipe
		and EXCAVATOR_CONFIG.description.contains("每20秒")
		and EXCAVATOR_CONFIG.description.contains("直接存入全场仓库")
		and EXCAVATOR_CONFIG.description.contains("仓库无空间时等待"),
		"挖土装置必须只挂载自动挖掘配方，并明确展示20秒仓库直存与满仓等待规则。"
	)


func _test_recipe_contract() -> void:
	_expect(
		EXCAVATOR_CYCLE.is_valid()
		and EXCAVATOR_CYCLE.recipe_id == &"excavator_cycle"
		and EXCAVATOR_CYCLE.display_name == "自动挖掘"
		and EXCAVATOR_CYCLE.input_items.is_empty()
		and EXCAVATOR_CYCLE.input_amounts.is_empty()
		and EXCAVATOR_CYCLE.output_items == [DIRT_BLOCK]
		and EXCAVATOR_CYCLE.output_amounts == [1]
		and not EXCAVATOR_CYCLE.outputs_to_player_inventory()
		and not EXCAVATOR_CYCLE.outputs_to_local_slot()
		and EXCAVATOR_CYCLE.output_destination
		== ProductionRecipe.OutputDestination.SHARED_STORAGE
		and EXCAVATOR_CYCLE.get_local_output_capacity() == 0
		and is_equal_approx(EXCAVATOR_CYCLE.duration_seconds, 20.0),
		"自动挖掘必须无需投入、每20秒向共享仓库产出1个土块，且不得再声明本地产物格。"
	)


func _test_assembly_recipe(wood_station: ProductionBuilding) -> void:
	_expect(
		EXCAVATOR_ASSEMBLY.is_valid()
		and EXCAVATOR_ASSEMBLY.recipe_id == &"excavator_assembly"
		and EXCAVATOR_ASSEMBLY.input_items == [PLANK]
		and EXCAVATOR_ASSEMBLY.input_amounts == [10]
		and EXCAVATOR_ASSEMBLY.output_items == [EXCAVATOR_ITEM]
		and EXCAVATOR_ASSEMBLY.output_amounts == [1]
		and not EXCAVATOR_ASSEMBLY.outputs_to_player_inventory()
		and is_equal_approx(EXCAVATOR_ASSEMBLY.duration_seconds, 30.0),
		"挖土装置组装配方必须消耗10木板、耗时30秒并向共享仓库产出1个建筑物品。"
	)
	_expect(
		wood_station != null
		and wood_station.get_recipe(&"excavator_assembly")
		== EXCAVATOR_ASSEMBLY,
		"木头加工站必须注册挖土装置组装配方。"
	)


func _test_automatic_panel_layout(
	panel: ProductionBuildingPanel,
	excavator: Excavator,
	owner_player: Player
) -> void:
	panel.bind_building(excavator, owner_player)
	var output_slot := panel.output_slots[0]
	_expect(
		panel.building_title.position == Vector2(85, 106)
		and panel.building_title.size == Vector2(311, 50)
		and panel.loop_button.get_rect()
		== ProductionBuildingPanel.STANDARD_LOOP_BUTTON_RECT
		and not panel.loop_button.get_rect().intersects(
			panel.building_title.get_rect()
		)
		and panel.loop_button.get_rect().end.y <= panel.input_title.position.y
		and panel.input_title.text == "无需材料"
		and panel.input_title.size == Vector2(290, 40)
		and panel.output_title.text == "仓库产物"
		and panel.output_title.size == Vector2(186, 40)
		and panel.progress_label.size == Vector2(320, 40)
		and panel.status_label.size == Vector2(372, 70)
		and panel.input_title.vertical_alignment
		== VERTICAL_ALIGNMENT_CENTER
		and panel.output_title.vertical_alignment
		== VERTICAL_ALIGNMENT_CENTER
		and not panel.progress_label.clip_text,
		"挖土装置必须保留无需材料—进度—仓库产物的自动挖掘布局。"
	)
	_expect(
		not panel.input_slots[0].visible
		and output_slot.visible
		and output_slot.position == Vector2(561, 246)
		and output_slot.size == Vector2(64, 70)
		and output_slot.item == DIRT_BLOCK
		and output_slot.stack_count == 1
		and not output_slot.stack_count_label.visible
		and output_slot.stack_count_label.text == "1"
		and not output_slot.disabled
		and output_slot.mouse_filter == Control.MOUSE_FILTER_IGNORE
		and output_slot.tooltip_text.contains("仓库"),
		"仓库产物槽必须正常展示每轮1个土块、忽略点击且明确说明直接存入仓库。"
	)
	_expect(
		panel.status_label.text.contains("20")
		and panel.status_label.text.contains("全场仓库"),
		"自动挖掘状态文案必须明确每20秒向全场仓库直存土块。"
	)
	var transient_before := panel.transient_status
	output_slot.pressed.emit()
	_expect(
		panel.transient_status == transient_before
		and not excavator.has_buffered_output(),
		"不可点击的仓库产物槽不得触发旧的本地产物领取流程。"
	)
	panel.bind_building(null, null)


func _test_direct_warehouse_production(
	coordinator: ProductionCoordinator,
	warehouse: OakWarehouse,
	excavator: Excavator
) -> void:
	_expect(
		excavator.active_recipe_id == &"excavator_cycle"
		and excavator.get_active_recipe() == EXCAVATOR_CYCLE
		and coordinator.warehouses == [warehouse]
		and excavator.production_enabled
		and not excavator.production_loop_enabled
		and not excavator.has_buffered_output(),
		"挖土装置必须自动选择唯一配方、绑定共享仓库，并默认只挖掘一轮。"
	)

	excavator.advance_shared_production_tick(19.0)
	_expect(
		coordinator.get_total_item_count(DIRT_BLOCK) == 0
		and is_equal_approx(excavator.progress_elapsed_seconds, 19.0)
		and excavator.completion_wait_reason == &""
		and not excavator.has_buffered_output(),
		"前19秒不得提前生成或缓冲土块。"
	)
	excavator.advance_shared_production_tick(1.0)
	_expect(
		coordinator.get_total_item_count(DIRT_BLOCK) == 1
		and warehouse.get_storage_item_total(DIRT_BLOCK) == 1
		and is_zero_approx(excavator.progress_elapsed_seconds)
		and excavator.completion_wait_reason == &""
		and not excavator.production_enabled
		and not excavator.production_loop_enabled
		and not excavator.has_buffered_output(),
		"默认单次挖掘必须在第20秒把1个土块直接存入仓库、保持本地缓冲为空并停止。"
	)
	var stopped_revision := excavator.production_revision
	excavator.advance_shared_production_tick(120.0)
	_expect(
		coordinator.get_total_item_count(DIRT_BLOCK) == 1
		and is_zero_approx(excavator.progress_elapsed_seconds)
		and excavator.production_revision == stopped_revision
		and not excavator.has_buffered_output(),
		"默认单次挖掘停止后即使再过120秒也不得产生第二个土块。"
	)

	_expect(
		excavator.set_production_loop_enabled(true)
		and excavator.set_production_enabled(true),
		"挖土装置必须允许显式开启循环并重新启动。"
	)
	for expected_total in range(2, 5):
		excavator.advance_shared_production_tick(20.0)
		_expect(
			coordinator.get_total_item_count(DIRT_BLOCK) == expected_total
			and warehouse.get_storage_item_total(DIRT_BLOCK) == expected_total
			and excavator.production_enabled
			and excavator.production_loop_enabled
			and is_zero_approx(excavator.progress_elapsed_seconds)
			and excavator.completion_wait_reason == &""
			and not excavator.has_buffered_output(),
			"循环挖掘每个20秒周期都必须直接向共享仓库增加1个土块。"
		)

	_clear_warehouse(warehouse)
	var filler_count := (
		OakWarehouse.STORAGE_CAPACITY
		* PickupConfig.get_inventory_stack_limit(EXCAVATOR_ITEM)
	)
	_expect(
		warehouse.try_add_storage_item_count(EXCAVATOR_ITEM, filler_count)
		and coordinator.get_total_item_count(DIRT_BLOCK) == 0,
		"满仓重试夹具必须用无关物品填满所有仓库槽位。"
	)
	excavator.advance_shared_production_tick(20.0)
	_expect(
		coordinator.get_total_item_count(DIRT_BLOCK) == 0
		and is_equal_approx(
			excavator.progress_elapsed_seconds,
			EXCAVATOR_CYCLE.duration_seconds
		)
		and excavator.completion_wait_reason
		== ProductionCoordinator.RESULT_STORAGE_FULL
		and excavator.production_enabled
		and excavator.production_loop_enabled
		and not excavator.has_buffered_output(),
		"仓库满时已完成的挖掘周期必须停在storage_full，不能生成本地缓冲或丢失产物。"
	)
	var blocked_revision := excavator.production_revision
	excavator.advance_shared_production_tick(120.0)
	_expect(
		coordinator.get_total_item_count(DIRT_BLOCK) == 0
		and excavator.production_revision == blocked_revision
		and is_equal_approx(
			excavator.progress_elapsed_seconds,
			EXCAVATOR_CYCLE.duration_seconds
		),
		"storage_full等待必须由仓库事件唤醒，额外计时不得轮询或重复提交。"
	)

	var warehouse_revision_before_release := warehouse.get_storage_revision()
	_expect(
		warehouse.discard_storage_item(0, warehouse_revision_before_release),
		"满仓重试夹具必须能通过公开仓库事务腾出一个槽位。"
	)
	_expect(
		coordinator.get_total_item_count(DIRT_BLOCK) == 1
		and warehouse.get_storage_item_total(DIRT_BLOCK) == 1
		and is_zero_approx(excavator.progress_elapsed_seconds)
		and excavator.completion_wait_reason == &""
		and excavator.production_enabled
		and excavator.production_loop_enabled
		and not excavator.has_buffered_output()
		and warehouse.get_storage_revision()
		== warehouse_revision_before_release + 2,
		"仓库腾槽信号必须同步重试并提交等待中的土块，不得依赖下一次生产tick。"
	)


func _test_missing_warehouse_retry(
	coordinator: ProductionCoordinator,
	warehouse: OakWarehouse,
	excavator: Excavator
) -> void:
	_expect(
		coordinator.warehouses.is_empty()
		and excavator.production_enabled
		and not excavator.production_loop_enabled,
		"缺仓补交测试必须从只有挖土装置、没有共享仓库的默认单次状态开始。"
	)
	excavator.advance_shared_production_tick(20.0)
	_expect(
		is_equal_approx(
			excavator.progress_elapsed_seconds,
			EXCAVATOR_CYCLE.duration_seconds
		)
		and excavator.completion_wait_reason
		== ProductionCoordinator.RESULT_MISSING_INPUT
		and excavator.production_enabled
		and not excavator.production_loop_enabled
		and not excavator.has_buffered_output()
		and coordinator.get_total_item_count(DIRT_BLOCK) == 0,
		"没有仓库时已完成周期必须停在missing_input完成点，不能缓冲、丢失或提前停机。"
	)
	var waiting_revision := excavator.production_revision
	excavator.advance_shared_production_tick(120.0)
	_expect(
		excavator.production_revision == waiting_revision
		and is_equal_approx(
			excavator.progress_elapsed_seconds,
			EXCAVATOR_CYCLE.duration_seconds
		)
		and excavator.completion_wait_reason
		== ProductionCoordinator.RESULT_MISSING_INPUT,
		"missing_input完成态必须等待仓库事件，额外计时不得轮询。"
	)

	coordinator.register_plant(warehouse)
	_expect(
		coordinator.warehouses == [warehouse]
		and coordinator.get_total_item_count(DIRT_BLOCK) == 1
		and warehouse.get_storage_item_total(DIRT_BLOCK) == 1
		and is_zero_approx(excavator.progress_elapsed_seconds)
		and excavator.completion_wait_reason == &""
		and not excavator.production_enabled
		and not excavator.production_loop_enabled
		and not excavator.has_buffered_output(),
		"注册空仓库产生的存储事件必须同步补交土块，并让默认单次挖掘在成功后停机。"
	)


func _test_multiplayer_buffer_contract(
	test_root: Node,
	authority: Excavator
) -> void:
	var authoritative_state := authority.export_multiplayer_runtime_state()
	_expect(
		String(authoritative_state.get("buffered_output_config_path", ""))
		== ""
		and int(authoritative_state.get("buffered_output_count", -1)) == 0,
		"权威挖土装置状态必须始终把本地产物缓冲编码为空。"
	)

	var proxy := EXCAVATOR_CONFIG.plant_scene.instantiate() as Excavator
	_expect(proxy != null, "多人挖土装置副本必须能从同一场景实例化。")
	if proxy == null:
		return
	test_root.add_child(proxy)
	await process_frame
	proxy.setup(
		EXCAVATOR_CONFIG,
		null,
		[
			Vector2i(4, 0),
			Vector2i(5, 0),
			Vector2i(4, 1),
			Vector2i(5, 1),
		],
		true,
		EXCAVATOR_CONFIG.max_health,
		1
	)
	proxy.configure_multiplayer_production(77, 2, true)
	var requested_commands: Array[Dictionary] = []
	proxy.production_command_requested.connect(
		func(command: Dictionary) -> void: requested_commands.append(command)
	)
	var sample_time := Time.get_ticks_msec() / 1000.0
	proxy.apply_multiplayer_runtime_state(authoritative_state, sample_time)
	_expect(
		proxy.production_revision
		== int(authoritative_state.get("revision", -1))
		and proxy.active_recipe_id == &"excavator_cycle"
		and not proxy.has_buffered_output()
		and proxy.get_buffered_output_item() == null
		and proxy.get_buffered_output_count() == 0,
		"客户端挖土装置副本必须接受权威生产状态，同时保持本地缓冲恒空。"
	)

	var accepted_revision := proxy.production_revision
	_expect(
		proxy.production_loop_enabled
		and proxy.request_multiplayer_loop_change(false)
		and proxy.multiplayer_production_request_pending
		and proxy.production_loop_enabled
		and requested_commands.size() == 1,
		"客户端关闭循环必须只提交请求，在Host新状态到达前不得本地改写loop_enabled。"
	)
	if requested_commands.is_empty():
		proxy.multiplayer_production_request_timer.stop()
		proxy.free()
		return
	var loop_command := requested_commands[0]
	_expect(
		ProductionBuildingProtocol.is_valid_command(loop_command)
		and ProductionBuildingProtocol.get_operation(loop_command)
		== ProductionBuildingProtocol.OPERATION_SET_LOOP_ENABLED
		and int(loop_command.get("building_net_id", 0)) == 77
		and int(loop_command.get("peer_id", 0)) == 2
		and int(loop_command.get("expected_production_revision", -1))
		== accepted_revision
		and loop_command.get("loop_enabled") == false,
		"循环切换命令必须绑定建筑、玩家、期望revision与目标布尔值。"
	)
	var loop_disabled_state := authoritative_state.duplicate(true)
	loop_disabled_state["loop_enabled"] = false
	loop_disabled_state["revision"] = accepted_revision + 1
	var loop_result := ProductionBuildingProtocol.make_result(
		loop_command,
		true,
		ProductionBuildingProtocol.RESULT_SUCCESS,
		int(loop_disabled_state["revision"]),
		loop_disabled_state,
		sample_time + 0.001
	)
	proxy.apply_multiplayer_runtime_state(
		loop_disabled_state,
		sample_time + 0.001
	)
	_expect(
		not proxy.production_loop_enabled
		and proxy.production_revision == accepted_revision + 1
		and proxy.multiplayer_production_request_pending,
		"只有Host的新revision状态才能关闭客户端循环，请求锁必须等待对应结果解除。"
	)
	_expect(
		proxy.complete_multiplayer_production_request(loop_result)
		and not proxy.multiplayer_production_request_pending
		and not proxy.production_loop_enabled,
		"Host结果必须解除循环切换请求锁，并保留已同步的权威状态。"
	)
	requested_commands.clear()

	var synced_revision := proxy.production_revision
	var forged_buffer_state := loop_disabled_state.duplicate(true)
	forged_buffer_state["buffered_output_config_path"] = DIRT_BLOCK.resource_path
	forged_buffer_state["buffered_output_count"] = 1
	forged_buffer_state["revision"] = synced_revision + 1
	proxy.apply_multiplayer_runtime_state(forged_buffer_state, sample_time + 0.002)
	_expect(
		proxy.production_revision == synced_revision
		and not proxy.has_buffered_output()
		and proxy.get_buffered_output_item() == null
		and proxy.get_buffered_output_count() == 0,
		"客户端必须整包拒绝伪造非空缓冲的挖土装置状态。"
	)
	_expect(
		not proxy.request_multiplayer_output_collection()
		and requested_commands.is_empty(),
		"仓库直存挖土装置不得提交旧的collect_output多人命令。"
	)
	proxy.multiplayer_production_request_timer.stop()
	proxy.free()


func _clear_warehouse(warehouse: OakWarehouse) -> void:
	for slot_index in OakWarehouse.STORAGE_CAPACITY:
		if warehouse.get_storage_item(slot_index) == null:
			continue
		_expect(
			warehouse.discard_storage_item(slot_index),
			"仓库测试夹具必须能清空槽位%d。" % slot_index
		)


func _finish(test_root: Node) -> void:
	if test_root != null and is_instance_valid(test_root):
		test_root.free()
	await process_frame
	if failures.is_empty():
		print("EXCAVATOR_SMOKE_TEST_OK")
		quit()
		return
	for failure in failures:
		push_error(failure)
	quit(1)


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
