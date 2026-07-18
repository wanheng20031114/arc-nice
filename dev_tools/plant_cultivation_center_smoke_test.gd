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
		PlantDefenseRegistry.get_all_configs().size() == 9,
		"公共注册表必须同时包含植物培育中心与竹筒迫击炮，共9种建筑。"
	)
	if config == null:
		_finish(test_root)
		return

	var coordinator := COORDINATOR_SCENE.instantiate() as ProductionCoordinator
	var warehouse := WAREHOUSE_SCENE.instantiate() as OakWarehouse
	var center := config.plant_scene.instantiate() as PlantCultivationCenter
	var panel := PANEL_SCENE.instantiate() as ProductionBuildingPanel
	var player := PLAYER_SCENE.instantiate() as Player
	test_root.add_child(coordinator)
	test_root.add_child(warehouse)
	test_root.add_child(center)
	test_root.add_child(panel)
	test_root.add_child(player)
	await process_frame
	coordinator.production_tick_timer.stop()

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
		center.recipes.size() == 2
		and center.recipes[0].input_items == [WOODEN_CORE]
		and center.recipes[0].input_amounts == [1]
		and center.recipes[0].output_items == [AGAVE_BUILDING_ITEM]
		and center.recipes[0].output_amounts == [1]
		and center.recipes[0].outputs_to_player_inventory()
		and center.recipes[1].input_items == [WOODEN_CORE]
		and center.recipes[1].input_amounts == [1]
		and center.recipes[1].output_items == [CORN_BUILDING_ITEM]
		and center.recipes[1].output_amounts == [1]
		and center.recipes[1].outputs_to_player_inventory(),
		"培育中心必须提供两个消耗1个木制核心、产物进入个人背包的建筑配方。"
	)
	_expect(
		AGAVE_BUILDING_ITEM.pickup_type == PickupConfig.PickupType.BUILDING
		and AGAVE_BUILDING_ITEM.placeable_plant_id == &"agave_cannon"
		and AGAVE_BUILDING_ITEM.stackable
		and CORN_BUILDING_ITEM.pickup_type == PickupConfig.PickupType.BUILDING
		and CORN_BUILDING_ITEM.placeable_plant_id == &"corn_machine_gun"
		and CORN_BUILDING_ITEM.stackable,
		"两种产物必须是可叠加且指向正确建筑配置的建筑物品。"
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

	var run_state := root.get_node("RunState") as RunStateStore
	run_state.begin_new_run()
	_expect(
		warehouse.try_add_storage_item_count(WOODEN_CORE, 1)
		and center.select_recipe(&"wooden_core_to_agave_cannon"),
		"培育测试必须能准备木制核心并选择加农炮配方。"
	)
	center.advance_shared_production_tick(10.0)
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
	center.advance_shared_production_tick(10.0)
	center.advance_shared_production_tick(10.0)
	_expect(
		run_state.get_item(0) == AGAVE_BUILDING_ITEM
		and run_state.get_item_count(0) == 3,
		"相同建筑产物必须在背包同一槽位叠加。"
	)
	_expect(
		warehouse.try_add_storage_item_count(WOODEN_CORE, 1)
		and center.select_recipe(&"wooden_core_to_corn_machine_gun"),
		"培育测试必须能切换至玉米机枪塔配方。"
	)
	center.advance_shared_production_tick(10.0)
	_expect(
		run_state.get_item(1) == CORN_BUILDING_ITEM
		and run_state.get_item_count(1) == 1,
		"玉米机枪塔必须作为独立可叠加建筑物品进入背包。"
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
	var committed_peer_ids: Array[int] = []
	coordinator.personal_inventory_output_committed.connect(
		func(peer_id: int) -> void: committed_peer_ids.append(peer_id)
	)
	_expect(
		warehouse.try_add_storage_item_count(WOODEN_CORE, 1)
		and center.select_recipe(&"wooden_core_to_agave_cannon", 2),
		"联机权威建筑必须记录选择配方的玩家。"
	)
	center.advance_shared_production_tick(10.0)
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

	panel.open_for(center, player)
	await process_frame
	var progress_fill := panel.progress_bar.get_theme_stylebox(
		"fill"
	) as StyleBoxFlat
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
		and progress_fill != null
		and progress_fill.bg_color.g > 0.75,
		"培育中心UI必须使用植物面板、嫩绿进度条，并按1投入1产物自适配槽位。"
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


func _test_asset_contracts() -> void:
	var building_texture := load(
		"res://resources/texture/plant_defense/plant_cultivation_center/plant_cultivation_center.png"
	) as Texture2D
	_expect(
		building_texture != null
		and building_texture.get_size() == Vector2(64, 64),
		"培育中心正式世界素材必须为64×64。"
	)
	for item in [AGAVE_BUILDING_ITEM, CORN_BUILDING_ITEM]:
		_expect(
			item.icon_texture != null
			and item.icon_texture.get_size() == Vector2(32, 32),
			"2×2建筑的背包图标必须严格整数缩半为32×32。"
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
	run_state.begin_new_run()
	_expect(
		run_state.try_add_item_count(AGAVE_BUILDING_ITEM, 2),
		"放置测试必须能加入2个加农炮建筑物品。"
	)
	var initial_revision := run_state.get_inventory_revision()
	_expect(
		run_state.try_consume_item_at_slot_if_revision(
			0,
			AGAVE_BUILDING_ITEM,
			initial_revision
		)
		and run_state.get_item_count(0) == 1
		and not run_state.try_consume_item_at_slot_if_revision(
			0,
			AGAVE_BUILDING_ITEM,
			initial_revision
		),
		"建筑物品必须一次只消耗1个，并拒绝过期背包revision。"
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
		and controller.selection_hud.available_configs.size() == 9,
		"T键免费调试入口必须继续展示全部9种建筑。"
	)
	controller.cancel_placement()


func _test_authoritative_placement_rollback_sync(
	config: PlantDefenseConfig,
	run_state: RunStateStore,
	player: Player
) -> void:
	run_state.begin_new_run()
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
