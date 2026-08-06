extends SceneTree

const COORDINATOR_SCENE := preload(
	"res://scene/game_modes/tower_defense/economy/production/production_coordinator.tscn"
)
const PANEL_SCENE := preload(
	"res://scene/game_modes/tower_defense/economy/production/production_building_panel.tscn"
)
const EXCAVATOR_CONFIG: PlantDefenseConfig = preload(
	"res://resources/config/plant_defense/excavator.tres"
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
const FOOTPRINT_CELLS: Array[Vector2i] = [
	Vector2i.ZERO,
	Vector2i.RIGHT,
	Vector2i.DOWN,
	Vector2i.ONE,
]

var failures: PackedStringArray = []


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var test_root := Node.new()
	test_root.name = "ExcavatorSmokeTest"
	root.add_child(test_root)
	var run_state := root.get_node("RunState") as RunStateStore
	run_state.begin_new_run(&"weishidaier", false)

	var coordinator := COORDINATOR_SCENE.instantiate() as ProductionCoordinator
	var panel := PANEL_SCENE.instantiate() as ProductionBuildingPanel
	var excavator := EXCAVATOR_CONFIG.plant_scene.instantiate() as Excavator
	var wood_station := (
		WOOD_PROCESSING_CONFIG.plant_scene.instantiate() as ProductionBuilding
	)
	test_root.add_child(coordinator)
	test_root.add_child(panel)
	if excavator != null:
		test_root.add_child(excavator)
	if wood_station != null:
		test_root.add_child(wood_station)
	await process_frame
	coordinator.production_tick_timer.stop()

	_test_config_and_scene(excavator)
	_test_assembly_recipe(wood_station)
	if excavator == null:
		_finish(test_root)
		return

	excavator.setup(EXCAVATOR_CONFIG, null, FOOTPRINT_CELLS)
	coordinator.register_plant(excavator)
	_test_automatic_panel_layout(panel, excavator)
	await _test_local_output_slot_and_runtime_state(
		test_root,
		coordinator,
		excavator,
		panel,
		run_state
	)
	_finish(test_root)


func _test_automatic_panel_layout(
	panel: ProductionBuildingPanel,
	excavator: Excavator
) -> void:
	excavator.buffered_output_item = DIRT_BLOCK
	excavator.buffered_output_count = 2
	panel.bind_building(excavator, null)
	var output_slot := panel.output_slots[0]
	_expect(
		panel.building_title.size == Vector2(412, 50)
		and panel.input_title.size == Vector2(290, 40)
		and panel.output_title.size == Vector2(186, 40)
		and panel.progress_label.size == Vector2(320, 40)
		and panel.status_label.size == Vector2(372, 70)
		and panel.input_title.vertical_alignment
		== VERTICAL_ALIGNMENT_CENTER
		and panel.output_title.vertical_alignment
		== VERTICAL_ALIGNMENT_CENTER
		and not panel.progress_label.clip_text,
		"挖土装置自动面板的描边文字区域必须保留足够的水平和垂直余量。"
	)
	_expect(
		output_slot.size == Vector2(64, 70)
		and output_slot.item == DIRT_BLOCK
		and output_slot.item_icon.position == output_slot.size * 0.5
		and output_slot.item_icon.scale == Vector2(2, 2)
		and output_slot.item_icon.texture_filter
		== CanvasItem.TEXTURE_FILTER_NEAREST
		and output_slot.stack_count_label.visible
		and output_slot.stack_count_label.text == "2",
		"挖土装置产物格必须把土块以整数2倍清晰缩放并严格居中。"
	)
	panel.bind_building(null, null)
	excavator.buffered_output_item = null
	excavator.buffered_output_count = 0


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
		and EXCAVATOR_CONFIG.description.contains("固定产出1个土块")
		and EXCAVATOR_CONFIG.description.contains("最多暂存5个"),
		"挖土装置必须只挂载自动挖掘配方，并明确展示固定土块与5格暂存规则。"
	)


func _test_assembly_recipe(wood_station: ProductionBuilding) -> void:
	_expect(
		EXCAVATOR_ASSEMBLY.is_valid()
		and EXCAVATOR_ASSEMBLY.recipe_id == &"excavator_assembly"
		and EXCAVATOR_ASSEMBLY.input_items == [PLANK]
		and EXCAVATOR_ASSEMBLY.input_amounts == [10]
		and EXCAVATOR_ASSEMBLY.output_items == [EXCAVATOR_ITEM]
		and EXCAVATOR_ASSEMBLY.output_amounts == [1]
		and EXCAVATOR_ASSEMBLY.outputs_to_player_inventory()
		and is_equal_approx(EXCAVATOR_ASSEMBLY.duration_seconds, 30.0),
		"挖土装置组装配方必须消耗10木板、耗时30秒并向玩家背包产出1个建筑物品。"
	)
	_expect(
		wood_station != null
		and wood_station.get_recipe(&"excavator_assembly")
		== EXCAVATOR_ASSEMBLY,
		"木头加工站必须注册挖土装置组装配方。"
	)


func _test_local_output_slot_and_runtime_state(
	test_root: Node,
	coordinator: ProductionCoordinator,
	excavator: Excavator,
	panel: ProductionBuildingPanel,
	run_state: RunStateStore
) -> void:
	_expect(
		EXCAVATOR_CYCLE.is_valid()
		and EXCAVATOR_CYCLE.recipe_id == &"excavator_cycle"
		and EXCAVATOR_CYCLE.input_items.is_empty()
		and EXCAVATOR_CYCLE.input_amounts.is_empty()
		and EXCAVATOR_CYCLE.output_items == [DIRT_BLOCK]
		and EXCAVATOR_CYCLE.output_amounts == [1]
		and EXCAVATOR_CYCLE.outputs_to_local_slot()
		and EXCAVATOR_CYCLE.get_local_output_capacity() == 5
		and is_equal_approx(EXCAVATOR_CYCLE.duration_seconds, 20.0),
		"挖掘循环必须无需材料、每20秒固定生成1个土块，且本地产物格容量为5。"
	)
	_expect(
		excavator.active_recipe_id == &"excavator_cycle"
		and excavator.get_active_recipe() == EXCAVATOR_CYCLE
		and coordinator.warehouses.is_empty(),
		"挖土装置必须自动启动唯一配方，且运行不要求连接仓库。"
	)

	excavator.advance_shared_production_tick(19.0)
	_expect(
		not excavator.has_buffered_output()
		and is_equal_approx(excavator.progress_elapsed_seconds, 19.0)
		and excavator.completion_wait_reason == &"",
		"前19秒不得提前生成本地产物。"
	)
	excavator.advance_shared_production_tick(1.0)
	var output_item := excavator.get_buffered_output_item()
	_expect(
		excavator.has_buffered_output()
		and excavator.get_buffered_output_count() == 1
		and output_item == DIRT_BLOCK
		and is_zero_approx(excavator.progress_elapsed_seconds)
		and excavator.completion_wait_reason == &""
		and not excavator.is_local_output_slot_full(),
		"第20秒必须固定暂存1个土块，并在未达到5个时继续生产。"
	)
	if output_item == null:
		return

	for expected_count in range(2, 6):
		excavator.advance_shared_production_tick(20.0)
		_expect(
			excavator.get_buffered_output_item() == DIRT_BLOCK
			and excavator.get_buffered_output_count() == expected_count
			and excavator.is_local_output_slot_full() == (expected_count == 5)
			and excavator.completion_wait_reason == (
				ProductionCoordinator.RESULT_OUTPUT_SLOT_OCCUPIED
				if expected_count == 5
				else &""
			),
			"挖土装置必须逐轮叠加土块，并且只在5/5时进入堵塞状态。"
		)
	var blocked_revision := excavator.production_revision
	excavator.advance_shared_production_tick(120.0)
	_expect(
		excavator.get_buffered_output_item() == output_item
		and excavator.get_buffered_output_count() == 5
		and is_zero_approx(excavator.progress_elapsed_seconds)
		and excavator.production_revision == blocked_revision,
		"产物格达到5个后即使再过120秒也必须保持堵塞，不得继续计时或覆盖产物。"
	)

	var authoritative_state := excavator.export_multiplayer_runtime_state()
	await _test_runtime_state_and_collect_protocol(
		test_root,
		authoritative_state,
		output_item,
		panel
	)

	var inventory_filled := true
	for _slot_index in range(RunStateStore.INVENTORY_CAPACITY):
		inventory_filled = (
			run_state.try_add_item(EXCAVATOR_ITEM)
			and inventory_filled
		)
	var full_inventory_revision := run_state.get_inventory_revision()
	var full_output_revision := excavator.production_revision
	_expect(
		inventory_filled
		and excavator.try_collect_buffered_output(0)
		== ProductionBuildingProtocol.RESULT_INVENTORY_FULL
		and excavator.get_buffered_output_item() == output_item
		and excavator.get_buffered_output_count() == 5
		and run_state.get_inventory_revision() == full_inventory_revision
		and excavator.production_revision == full_output_revision,
		"背包已满时领取必须失败且不得丢失、替换本地产物或推进任一revision。"
	)
	for slot_index in range(RunStateStore.INVENTORY_CAPACITY):
		if run_state.get_item(slot_index) == EXCAVATOR_ITEM:
			_expect(
				run_state.discard_item(slot_index),
				"背包满测试结束后必须能清理装箱挖土装置夹具。"
			)

	var inventory_before := run_state.get_inventory_item_total(output_item)
	var inventory_revision_before := run_state.get_inventory_revision()
	_expect(
		excavator.try_collect_buffered_output(0)
		== ProductionBuildingProtocol.RESULT_SUCCESS
		and not excavator.has_buffered_output()
		and excavator.completion_wait_reason == &""
		and run_state.get_inventory_item_total(output_item) == inventory_before + 5
		and run_state.get_inventory_revision() == inventory_revision_before + 1,
		"玩家领取后必须原子清空产物格、解除堵塞并把整叠5个土块加入背包。"
	)
	excavator.advance_shared_production_tick(1.0)
	_expect(
		is_equal_approx(excavator.progress_elapsed_seconds, 1.0)
		and not excavator.has_buffered_output(),
		"领取产物后挖土装置必须从下一轮第1秒恢复生产。"
	)

	excavator.advance_shared_production_tick(19.0)
	var peer_output_item := excavator.get_buffered_output_item()
	for _stack_index in range(4):
		excavator.advance_shared_production_tick(20.0)
	run_state.ensure_multiplayer_peer_state(2)
	coordinator.configure_multiplayer_output_peers([2])
	var committed_peer_ids: Array[int] = []
	coordinator.personal_inventory_output_committed.connect(
		func(peer_id: int) -> void: committed_peer_ids.append(peer_id)
	)
	var peer_inventory_before := run_state.get_inventory_item_total_for_peer(
		2,
		peer_output_item
	)
	var peer_inventory_revision_before := (
		run_state.get_inventory_revision_for_peer(2)
	)
	var multiplayer_output_revision_before := excavator.production_revision
	var collect_command := ProductionBuildingProtocol.make_collect_output_command(
		91,
		77,
		2,
		multiplayer_output_revision_before
	)
	_expect(
		peer_output_item != null
		and excavator.apply_authoritative_multiplayer_production_command(
			collect_command
		) == ProductionBuildingProtocol.RESULT_SUCCESS
		and not excavator.has_buffered_output()
		and run_state.get_inventory_item_total_for_peer(2, peer_output_item)
		== peer_inventory_before + 5
		and run_state.get_inventory_revision_for_peer(2)
		== peer_inventory_revision_before + 1
		and excavator.production_revision
		== multiplayer_output_revision_before + 1
		and committed_peer_ids == [2],
		"Host必须把满叠5个土块原子提交到请求玩家背包，再同步清槽revision与目标peer事件。"
	)
	coordinator.configure_local_output_peer()


func _test_runtime_state_and_collect_protocol(
	test_root: Node,
	authoritative_state: Dictionary,
	output_item: PickupConfig,
	panel: ProductionBuildingPanel
) -> void:
	var required_fields := [
		"schema",
		"enabled",
		"active_recipe_id",
		"progress_elapsed_seconds",
		"wait_reason",
		"buffered_output_config_path",
		"buffered_output_count",
		"personal_output_peer_id",
		"revision",
		"projection_duration_seconds",
	]
	var has_all_fields := true
	for field in required_fields:
		has_all_fields = has_all_fields and authoritative_state.has(field)
	_expect(
		has_all_fields
		and int(authoritative_state.get("schema", -1))
		== ProductionBuilding.RUNTIME_STATE_SCHEMA
		and String(authoritative_state.get("active_recipe_id", ""))
		== "excavator_cycle"
		and String(authoritative_state.get("buffered_output_config_path", ""))
		== output_item.resource_path
		and int(authoritative_state.get("buffered_output_count", 0)) == 5
		and StringName(authoritative_state.get("wait_reason", &""))
		== ProductionCoordinator.RESULT_OUTPUT_SLOT_OCCUPIED,
		"多人运行时状态必须完整携带配方、进度、堵塞原因及本地产物路径/数量。"
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
		and proxy.get_buffered_output_item() == output_item
		and proxy.get_buffered_output_count() == 5
		and proxy.completion_wait_reason
		== ProductionCoordinator.RESULT_OUTPUT_SLOT_OCCUPIED,
		"客户端副本必须从权威状态恢复同一叠5个堵塞土块。"
	)
	var accepted_revision := proxy.production_revision
	var oversized_state := authoritative_state.duplicate(true)
	oversized_state["buffered_output_count"] = 6
	oversized_state["revision"] = accepted_revision + 1
	proxy.apply_multiplayer_runtime_state(oversized_state, sample_time + 0.001)
	var mismatched_state := authoritative_state.duplicate(true)
	mismatched_state["buffered_output_config_path"] = PLANK.resource_path
	mismatched_state["buffered_output_count"] = 1
	mismatched_state["revision"] = accepted_revision + 1
	proxy.apply_multiplayer_runtime_state(mismatched_state, sample_time + 0.002)
	_expect(
		proxy.production_revision == accepted_revision
		and proxy.get_buffered_output_item() == DIRT_BLOCK
		and proxy.get_buffered_output_count() == 5,
		"客户端必须拒绝超过配方容量或与固定配方产物不一致的本地产物状态。"
	)

	var panel_player := Player.new()
	panel_player.peer_id = 2
	panel.bind_building(proxy, panel_player)
	_expect(
		panel.output_slots[0].visible
		and panel.output_slots[0].mouse_filter == Control.MOUSE_FILTER_STOP
		and not panel.output_slots[0].disabled
		and panel.output_slots[0].position == Vector2(561, 246)
		and panel.output_slots[0].size == Vector2(64, 70)
		and panel.building_title.position == Vector2(59, 106)
		and panel.building_title.size == Vector2(412, 50)
		and panel.status_label.position == Vector2(64, 368)
		and panel.status_label.size == Vector2(372, 70),
		"本地产物格必须位于右侧面板并接收鼠标点击，状态文字必须限制在左侧内容框内。"
	)
	panel.output_slots[0].pressed.emit()
	_expect(
		proxy.multiplayer_production_request_pending
		and requested_commands.size() == 1
		and panel.transient_status == "已提交领取请求，等待主机确认。",
		"客户端从产物格领取时必须只提交一条多人生产命令，并等待Host结果而不得继续本地领取。"
	)
	if requested_commands.is_empty():
		panel.close()
		panel_player.free()
		proxy.multiplayer_production_request_timer.stop()
		proxy.free()
		return
	var command := requested_commands[0]
	_expect(
		ProductionBuildingProtocol.is_valid_command(command)
		and ProductionBuildingProtocol.get_operation(command)
		== ProductionBuildingProtocol.OPERATION_COLLECT_OUTPUT
		and int(command.get("building_net_id", 0)) == 77
		and int(command.get("peer_id", 0)) == 2
		and int(command.get("expected_production_revision", -1))
		== proxy.production_revision
		and not command.has("recipe_id")
		and not command.has("enabled")
		and ProductionBuildingProtocol.canonicalize_command(command, 2)
		== command,
		"collect_output协议必须绑定建筑、玩家和期望revision，并通过Host严格白名单。"
	)

	var collected_state := authoritative_state.duplicate(true)
	collected_state["buffered_output_config_path"] = ""
	collected_state["buffered_output_count"] = 0
	collected_state["wait_reason"] = ""
	collected_state["revision"] = proxy.production_revision + 1
	var result := ProductionBuildingProtocol.make_result(
		command,
		true,
		ProductionBuildingProtocol.RESULT_SUCCESS,
		int(collected_state["revision"]),
		collected_state,
		sample_time
	)
	proxy.apply_multiplayer_runtime_state(collected_state, sample_time + 0.001)
	_expect(
		proxy.complete_multiplayer_production_request(result)
		and not proxy.multiplayer_production_request_pending
		and not proxy.has_buffered_output()
		and proxy.completion_wait_reason == &""
		and proxy.production_revision == int(collected_state["revision"]),
		"Host确认collect_output后客户端必须清空同步产物并解除请求锁。"
	)
	panel.close()
	panel_player.free()
	proxy.multiplayer_production_request_timer.stop()
	proxy.free()


func _finish(test_root: Node) -> void:
	if test_root != null and is_instance_valid(test_root):
		test_root.free()
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
