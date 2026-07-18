extends SceneTree

const COORDINATOR_SCENE := preload(
	"res://scene/plant_defense/production_coordinator.tscn"
)
const WAREHOUSE_SCENE := preload("res://scene/plant_defense/oak_warehouse.tscn")
const PANEL_SCENE := preload("res://scene/plant_defense/production_building_panel.tscn")
const PLAYER_SCENE := preload(
	"res://scene/player/weishidaier/player_weishidaier.tscn"
)
const GAME_SCENE := preload("res://scene/game_tower_defense.tscn")
const WATER_COLLECTOR_CONFIG := preload(
	"res://resources/config/plant_defense/water_collector.tres"
)
const WAREHOUSE_CONFIG := preload(
	"res://resources/config/plant_defense/oak_warehouse.tres"
)
const WATER_SOURCE := preload(
	"res://resources/config/production/water_source.tres"
)
const WATER_BOTTLE := preload(
	"res://resources/config/materials/material_water_bottle.tres"
)

var failures: PackedStringArray = []


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var test_root := Node.new()
	test_root.name = "WaterCollectorSmokeTest"
	root.add_child(test_root)

	var coordinator := COORDINATOR_SCENE.instantiate() as ProductionCoordinator
	var warehouse := WAREHOUSE_SCENE.instantiate() as OakWarehouse
	var collector := (
		WATER_COLLECTOR_CONFIG.plant_scene.instantiate() as WaterCollector
	)
	var panel := PANEL_SCENE.instantiate() as ProductionBuildingPanel
	var player := PLAYER_SCENE.instantiate() as Player
	test_root.add_child(coordinator)
	test_root.add_child(warehouse)
	test_root.add_child(collector)
	test_root.add_child(panel)
	test_root.add_child(player)
	await process_frame
	coordinator.production_tick_timer.stop()

	_test_config_and_assets(collector)
	await _test_multiplayer_water_collector_contract(test_root)
	warehouse.setup(WAREHOUSE_CONFIG, player, [Vector2i(-1, 0)])
	collector.setup(
		WATER_COLLECTOR_CONFIG,
		player,
		[
			Vector2i(0, 0),
			Vector2i(1, 0),
			Vector2i(0, 1),
			Vector2i(1, 1),
		]
	)
	coordinator.register_plant(warehouse)
	coordinator.register_plant(collector)
	collector.set_shared_production_panel(panel)

	_expect(
		collector.active_recipe_id == &"water_to_bottle"
		and collector.get_active_recipe() != null
		and collector.get_active_recipe().uses_environment_source(),
		"水源采集器必须在完成搭建时自动选择唯一的环境采集配方。"
	)
	collector.advance_shared_production_tick(19.0)
	_test_collection_progress_ring(collector, 0.95)
	_expect(
		coordinator.get_total_item_count(WATER_BOTTLE) == 0
		and is_equal_approx(collector.progress_elapsed_seconds, 19.0),
		"前19秒不得提前产出水瓶。"
	)
	collector.advance_shared_production_tick(1.0)
	_expect(
		coordinator.get_total_item_count(WATER_BOTTLE) == 1
		and is_zero_approx(collector.progress_elapsed_seconds)
		and is_zero_approx(collector.collection_progress_ring.value),
		"第20秒必须无原料消耗地向仓库存入1个水瓶。"
	)
	collector.advance_shared_production_tick(7.0)
	collector.set_production_enabled(false)
	_expect(
		is_zero_approx(collector.progress_elapsed_seconds)
		and collector.collection_progress_ring.visible
		and is_zero_approx(collector.collection_progress_ring.value)
		and coordinator.get_total_item_count(WATER_BOTTLE) == 1,
		"暂停采集必须清空本轮进度与瓶身进度环，且不能额外产出。"
	)
	collector.set_production_enabled(true)

	panel.open_for(collector, player)
	await process_frame
	_expect(
		panel.is_open()
		and not panel.recipe_title.visible
		and not panel.recipe_scroll.visible
		and panel.input_title.text == "水源"
		and panel.output_title.text == "采集产物",
		"采集器面板必须隐藏配方栏并呈现水源—进度—产物的单行布局。"
	)
	_expect(
		panel.input_slots[0].item == WATER_SOURCE
		and not panel.input_slots[1].visible
		and not panel.input_slots[2].visible
		and panel.output_slots[0].item == WATER_BOTTLE
		and not panel.output_slots[1].visible
		and not panel.output_slots[2].visible,
		"采集器面板左侧必须显示水瓦片，右侧只显示1个水瓶产物槽。"
	)
	_expect(
		panel.background.texture
		== collector.production_panel_background_override
		and panel.background.texture.get_size() == Vector2(728, 544),
		"采集器必须使用专属728×544莲叶水源面板背景。"
	)
	panel.call("_on_toggle_pressed")
	_expect(
		not collector.production_enabled
		and panel.progress_label.text.contains("已暂停"),
		"面板右上角开关必须能暂停采集器。"
	)
	panel.close()
	_expect(not player.controls_locked, "关闭采集器面板必须恢复玩家控制。")

	await _test_four_water_cell_support(test_root)
	_finish(test_root)


func _test_config_and_assets(collector: WaterCollector) -> void:
	_expect(
		WATER_COLLECTOR_CONFIG.is_valid()
		and WATER_COLLECTOR_CONFIG.supports_multiplayer
		and WATER_COLLECTOR_CONFIG.max_health == 2000
		and WATER_COLLECTOR_CONFIG.physical_defense == 10
		and WATER_COLLECTOR_CONFIG.magic_defense == 0
		and WATER_COLLECTOR_CONFIG.footprint_size == Vector2i(2, 2)
		and WATER_COLLECTOR_CONFIG.placement_surface
		== PlantDefenseConfig.PlacementSurface.WATER,
		"采集器必须为2000生命、10物防、0法防、2×2占格且只支持水面。"
	)
	_expect(
		collector != null
		and collector.recipes.size() == 1
		and collector.recipes[0].input_items == [WATER_SOURCE]
		and collector.recipes[0].input_amounts == [0]
		and collector.recipes[0].output_items == [WATER_BOTTLE]
		and collector.recipes[0].output_amounts == [1]
		and is_equal_approx(collector.recipes[0].duration_seconds, 20.0),
		"采集配方必须以水面为无消耗来源，每20秒产出1个水瓶。"
	)
	_expect(
		not WATER_SOURCE.can_store_in_inventory
		and WATER_BOTTLE.can_store_in_inventory
		and WATER_BOTTLE.stackable
		and WATER_BOTTLE.inventory_stack_limit == 999,
		"水瓦片只用于界面展示，水瓶必须能以999上限堆叠存入仓库。"
	)
	var building_texture := load(
		"res://resources/texture/plant_defense/water_collector/water_collector.png"
	) as Texture2D
	var bottle_texture := WATER_BOTTLE.icon_texture
	_expect(
		building_texture != null
		and building_texture.get_size() == Vector2(64, 64)
		and bottle_texture != null
		and bottle_texture.get_size() == Vector2(32, 32),
		"采集器必须使用64×64源图，水瓶必须使用32×32物资图标。"
	)
	var visual_root := collector.get_node_or_null("VisualRoot") as Node2D
	var progress_ring := collector.get_node_or_null(
		"VisualRoot/CollectionProgressRing"
	) as TextureProgressBar
	_expect(
		visual_root != null and visual_root.scale == Vector2(0.5, 0.5),
		"2×2采集器必须按现有建筑规范以0.5缩放显示为32×32世界像素。"
	)
	_expect(
		progress_ring != null
		and progress_ring.fill_mode == TextureProgressBar.FILL_CLOCKWISE
		and is_equal_approx(
			fposmod(progress_ring.radial_initial_angle, 360.0),
			270.0
		)
		and is_equal_approx(progress_ring.max_value, 1.0)
		and progress_ring.texture_under != null
		and progress_ring.texture_progress != null
		and progress_ring.texture_progress.get_size() == Vector2(12, 12)
		and progress_ring.size == Vector2(16, 16)
		and progress_ring.position == Vector2(-8, 12)
		and progress_ring.position.y > 8.0
		and progress_ring.tint_under.a >= 0.9
		and progress_ring.tint_progress.b >= 0.99
		and progress_ring.tint_progress.g >= 0.9,
		"采集器底座必须预置16×16顺时针高对比度青色收集进度环。"
	)


func _test_collection_progress_ring(
	collector: WaterCollector,
	expected_authoritative_ratio: float
) -> void:
	var progress_ring := collector.collection_progress_ring
	var progress_tween := collector.get("_collection_progress_tween") as Tween
	_expect(
		progress_ring != null
		and progress_ring.visible
		and is_equal_approx(
			progress_ring.value,
			expected_authoritative_ratio
		)
		and progress_tween != null
		and progress_tween.is_valid(),
		"底座进度环必须从真实采集进度开始，并仅在状态变化后启动平滑Tween。"
	)
	if progress_tween == null or not progress_tween.is_valid():
		return
	progress_tween.custom_step(
		collector.get_visual_projection_duration_seconds() * 0.5
	)
	var expected_half_step := lerpf(
		expected_authoritative_ratio,
		1.0,
		0.5
	)
	_expect(
		is_equal_approx(progress_ring.value, expected_half_step),
		"底座进度环Tween必须线性平滑补间到下一次真实采集进度。"
	)


func _test_multiplayer_water_collector_contract(test_root: Node) -> void:
	var proxy := WATER_COLLECTOR_CONFIG.plant_scene.instantiate() as WaterCollector
	test_root.add_child(proxy)
	await process_frame
	proxy.setup(
		WATER_COLLECTOR_CONFIG,
		null,
		[Vector2i(4, 0), Vector2i(5, 0), Vector2i(4, 1), Vector2i(5, 1)],
		true,
		WATER_COLLECTOR_CONFIG.max_health,
		1
	)
	proxy.configure_multiplayer_production(41, 2, true)
	var requested_commands: Array[Dictionary] = []
	var snapshot_requests: Array[int] = []
	proxy.production_command_requested.connect(
		func(command: Dictionary) -> void: requested_commands.append(command)
	)
	proxy.production_snapshot_requested.connect(
		func(building_net_id: int) -> void: snapshot_requests.append(building_net_id)
	)
	proxy.advance_shared_production_tick(20.0)
	_expect(
		proxy.is_multiplayer_proxy
		and proxy.active_recipe_id == &"water_to_bottle"
		and is_zero_approx(proxy.progress_elapsed_seconds),
		"多人水源采集器副本必须保留自动配方，且不得自行推进20秒权威采集。"
	)
	_expect(
		proxy.request_multiplayer_enabled_change(false)
		and requested_commands.size() == 1
		and requested_commands[0]["operation"]
		== ProductionBuildingProtocol.OPERATION_SET_ENABLED
		and int(requested_commands[0]["building_net_id"]) == 41
		and int(requested_commands[0]["peer_id"]) == 2
		and int(requested_commands[0]["expected_production_revision"]) == 0,
		"客户端暂停水源采集器必须发送带建筑、玩家与revision的多人命令。"
	)
	var authoritative_state := {
		"schema": ProductionBuilding.RUNTIME_STATE_SCHEMA,
		"enabled": false,
		"active_recipe_id": "water_to_bottle",
		"progress_elapsed_seconds": 0.0,
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
		and not proxy.production_enabled
		and proxy.production_revision == 1,
		"Host确认后水源采集器副本必须以完整权威状态解除请求锁。"
	)
	var stale_state := authoritative_state.duplicate(true)
	stale_state["revision"] = 0
	stale_state["enabled"] = true
	proxy.apply_multiplayer_runtime_state(
		stale_state,
		Time.get_ticks_msec() / 1000.0
	)
	_expect(
		not proxy.production_enabled and proxy.production_revision == 1,
		"过期水源采集器状态不得覆盖客户端较新的暂停状态。"
	)
	_expect(
		proxy.request_multiplayer_enabled_change(true),
		"同步完成后客户端必须能请求恢复水源采集。"
	)
	proxy.call("_on_multiplayer_production_request_timeout")
	_expect(
		not proxy.multiplayer_production_request_pending
		and not proxy.multiplayer_production_snapshot_ready
		and snapshot_requests == [41],
		"水源采集命令超时必须解除假操作并请求Host权威快照。"
	)
	proxy.multiplayer_production_request_timer.stop()
	proxy.free()


func _test_four_water_cell_support(test_root: Node) -> void:
	var game := GAME_SCENE.instantiate() as GameTowerDefense
	test_root.add_child(game)
	await process_frame
	var terrain := game.dual_grid_terrain
	var plant_system := game.plant_system
	_expect(
		terrain != null and plant_system != null,
		"四格水面验证需要塔防场景的真实地形与PlantSystem。"
	)
	if terrain == null or plant_system == null:
		return

	var anchor := _find_two_by_two_water_anchor(terrain, plant_system)
	_expect(anchor != Vector2i(9999, 9999), "实际地图必须存在完整2×2水面测试区域。")
	if anchor == Vector2i(9999, 9999):
		return
	var cells := plant_system.get_footprint_cells(anchor, WATER_COLLECTOR_CONFIG)
	var all_supported := true
	for cell in cells:
		all_supported = all_supported and bool(
			plant_system.call(
				"_is_floor_cell_available",
				cell,
				WATER_COLLECTOR_CONFIG
			)
		)
	_expect(all_supported and cells.size() == 4, "四个占用格全部为水面时必须全部通过地基检查。")

	var changed_cell := cells[3]
	terrain.set_tile(changed_cell, DualGridTilemap.TerrainType.GRASS)
	var still_all_supported := true
	for cell in cells:
		still_all_supported = still_all_supported and bool(
			plant_system.call(
				"_is_floor_cell_available",
				cell,
				WATER_COLLECTOR_CONFIG
			)
		)
	_expect(
		not still_all_supported,
		"2×2范围中任意一格不是水面时必须拒绝整座采集器。"
	)
	_expect(
		bool(plant_system.call(
			"_is_floor_cell_available",
			changed_cell,
			PlantDefenseRegistry.get_config(&"agave_cannon")
		)),
		"同一格改为草地后普通植物应恢复支持，证明水上建筑不依赖草地判定。"
	)
	terrain.set_tile(changed_cell, DualGridTilemap.TerrainType.WATER)
	_stop_audio_players(game)
	game.queue_free()
	await process_frame
	await process_frame


func _stop_audio_players(root: Node) -> void:
	for node in root.find_children("*", "AudioStreamPlayer", true, false):
		var player := node as AudioStreamPlayer
		player.stop()
		player.stream = null
	for node in root.find_children("*", "AudioStreamPlayer2D", true, false):
		var player := node as AudioStreamPlayer2D
		player.stop()
		player.stream = null
	for node in root.find_children("*", "AudioStreamPlayer3D", true, false):
		var player := node as AudioStreamPlayer3D
		player.stop()
		player.stream = null


func _find_two_by_two_water_anchor(
	terrain: DualGridTilemap,
	plant_system: PlantSystem
) -> Vector2i:
	var used_rect := terrain.world_map_layer.get_used_rect()
	for y in range(used_rect.position.y, used_rect.end.y - 1):
		for x in range(used_rect.position.x, used_rect.end.x - 1):
			var anchor := Vector2i(x, y)
			var all_water := true
			var offsets: Array[Vector2i] = [
				Vector2i.ZERO,
				Vector2i.RIGHT,
				Vector2i.DOWN,
				Vector2i.ONE,
			]
			for offset: Vector2i in offsets:
				var cell: Vector2i = anchor + offset
				if (
					terrain.get_terrain_type(cell)
					!= DualGridTilemap.TerrainType.WATER
					or not bool(plant_system.call(
						"_is_floor_cell_available",
						cell,
						WATER_COLLECTOR_CONFIG
					))
				):
					all_water = false
					break
			if all_water:
				return anchor
	return Vector2i(9999, 9999)


func _finish(test_root: Node) -> void:
	if test_root != null and is_instance_valid(test_root):
		test_root.free()
	if failures.is_empty():
		print("WATER_COLLECTOR_SMOKE_TEST_OK")
		quit()
		return
	for failure in failures:
		push_error(failure)
	quit(1)


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
