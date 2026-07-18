extends SceneTree

const PRODUCTION_COORDINATOR_SCENE := preload(
	"res://scene/plant_defense/production_coordinator.tscn"
)
const RESEARCH_COORDINATOR_SCENE := preload(
	"res://scene/plant_defense/research_coordinator.tscn"
)
const WAREHOUSE_SCENE := preload("res://scene/plant_defense/oak_warehouse.tscn")
const PANEL_SCENE := preload("res://scene/plant_defense/research_center_panel.tscn")
const WEISHIDAIER_SCENE := preload(
	"res://scene/player/weishidaier/player_weishidaier.tscn"
)
const TIYI_SCENE := preload("res://scene/player/tiyi/player_tiyi.tscn")
const HOE_CAT_SCENE := preload("res://scene/player/hoe_cat/player_hoe_cat.tscn")
const PLANK := preload("res://resources/config/materials/material_plank.tres")
const SAPLING := preload("res://resources/config/materials/material_sapling.tres")
const WATER_BOTTLE := preload(
	"res://resources/config/materials/material_water_bottle.tres"
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
	var warehouse := WAREHOUSE_SCENE.instantiate() as OakWarehouse
	var second_warehouse := WAREHOUSE_SCENE.instantiate() as OakWarehouse
	var plant_system := PlantSystem.new()
	var panel := PANEL_SCENE.instantiate() as ResearchCenterPanel
	var weishidaier := WEISHIDAIER_SCENE.instantiate() as Player
	var tiyi := TIYI_SCENE.instantiate() as Player
	var hoe_cat := HOE_CAT_SCENE.instantiate() as Player
	var config := PlantDefenseRegistry.get_config(&"research_center")
	var center := (
		config.plant_scene.instantiate() as ResearchCenter
		if config != null
		else null
	)
	for node in [
		production,
		research,
		warehouse,
		second_warehouse,
		plant_system,
		panel,
		weishidaier,
		tiyi,
		hoe_cat,
		center,
	]:
		if node != null:
			test_root.add_child(node)
	await process_frame
	production.production_tick_timer.stop()
	research.research_tick_timer.stop()

	_test_config_and_scene(config, center, panel)
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
	production.register_plant(warehouse)
	production.register_plant(second_warehouse)
	research.setup(production, plant_system, null)
	research.register_player(weishidaier)
	research.register_player(tiyi)
	research.register_player(hoe_cat)
	center.set_research_services(research, panel)
	plant_system.plant_footprints[center] = center.footprint_cells.duplicate()

	_expect(warehouse.try_add_storage_item_count(PLANK, 30), "第一测试仓库必须能加入30木板。")
	_expect(warehouse.try_add_storage_item_count(SAPLING, 10), "第一测试仓库必须能加入10树苗。")
	_expect(warehouse.try_add_storage_item_count(WATER_BOTTLE, 5), "第一测试仓库必须能加入5水瓶。")
	_expect(second_warehouse.try_add_storage_item_count(PLANK, 40), "第二测试仓库必须能加入40木板。")
	_expect(second_warehouse.try_add_storage_item_count(SAPLING, 9), "第二测试仓库必须能加入9树苗。")
	_expect(second_warehouse.try_add_storage_item_count(WATER_BOTTLE, 20), "第二测试仓库必须能加入20水瓶。")
	var missing_result := center.try_start_global_research()
	_expect(
		missing_result == ResearchCoordinator.RESULT_MISSING_INPUT
		and production.get_total_item_count(PLANK) == 70
		and production.get_total_item_count(SAPLING) == 19
		and production.get_total_item_count(WATER_BOTTLE) == 25,
		"任一研究材料不足时，多仓库事务必须整体失败且不能预扣其他材料。"
	)
	_expect(second_warehouse.try_add_storage_item_count(SAPLING, 11), "第二测试仓库必须能补入11树苗。")
	var start_result := center.try_start_global_research()
	_expect(start_result == ResearchCoordinator.RESULT_SUCCESS, "材料足够时必须立即开始全局研究。")
	_expect(
		production.get_total_item_count(PLANK) == 20
		and production.get_total_item_count(SAPLING) == 10
		and production.get_total_item_count(WATER_BOTTLE) == 5,
		"开始研究的同一帧必须原子扣除50木板、20树苗与20水瓶。"
	)
	research.advance_global_research(59.0)
	_expect(
		research.global_state == ResearchCoordinator.GlobalResearchState.RESEARCHING
		and center.get_effective_physical_defense() == 5,
		"研究未满60秒时不得提前提供建筑物防。"
	)
	research.advance_global_research(1.0)
	_expect(
		research.global_state == ResearchCoordinator.GlobalResearchState.COMPLETED
		and plant_system.get_global_physical_defense_bonus() == 10
		and center.get_effective_physical_defense() == 15,
		"研究完成后必须永久给现有建筑增加10点物防。"
	)
	_expect(
		center.try_start_global_research() == ResearchCoordinator.RESULT_COMPLETED,
		"完成的全局科技必须不可重复提交。"
	)

	await _test_player_technology(research, center, panel, weishidaier, tiyi, hoe_cat)
	_test_multiplayer_request_contract(config, research, panel, test_root)
	_finish(test_root)


func _test_config_and_scene(
	config: PlantDefenseConfig,
	center: ResearchCenter,
	panel: ResearchCenterPanel
) -> void:
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
		var sprite := center.get_node_or_null("VisualRoot/MainSprite") as Sprite2D
		var request_timer := center.get_node_or_null(
			"MultiplayerResearchRequestTimer"
		) as Timer
		_expect(
			visual_root != null
			and visual_root.scale == Vector2(0.5, 0.5)
			and sprite != null
			and sprite.texture != null
			and sprite.texture.get_size() == Vector2(64, 64)
			and sprite.texture_filter == CanvasItem.TEXTURE_FILTER_NEAREST,
			"科研中心必须以64×64源图、0.5世界缩放和nearest采样显示。"
		)
		_expect(
			request_timer != null
			and request_timer.one_shot
			and is_equal_approx(request_timer.wait_time, 4.0),
			"科研中心必须原生预建4秒一次性多人请求超时Timer。"
		)
	_expect(
		panel != null
		and panel.has_node("Overlay/PanelRoot/GlobalPage/PlankSlot")
		and panel.has_node("Overlay/PanelRoot/GlobalPage/SaplingSlot")
		and panel.has_node("Overlay/PanelRoot/GlobalPage/WaterBottleSlot")
		and panel.has_node("Overlay/PanelRoot/PlayerPage/TechNode1")
		and panel.has_node("Overlay/PanelRoot/PlayerPage/TechNode2")
		and panel.has_node("Overlay/PanelRoot/PlayerPage/TechNode3")
		and not panel.has_node("Overlay/PanelRoot/ToggleButton"),
		"科研UI必须原生包含双页与三处技术节点，并且不能有开关。"
	)
	if panel != null:
		var background := panel.get_node("Overlay/PanelRoot/Background") as TextureRect
		_expect(
			background.texture != null
			and background.texture.get_size() == Vector2(728, 544),
			"科研UI必须使用独立生成的728×544蓝色科技背景。"
		)


func _test_player_technology(
	research: ResearchCoordinator,
	center: ResearchCenter,
	panel: ResearchCenterPanel,
	weishidaier: Player,
	tiyi: Player,
	hoe_cat: Player
) -> void:
	for player in [weishidaier, tiyi, hoe_cat]:
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
	proxy.research_command_requested.connect(
		func(command: Dictionary) -> void: captured.append(command)
	)
	var result := proxy.try_purchase_player_technology(null)
	_expect(
		result == ResearchCoordinator.RESULT_REQUEST_SENT
		and proxy.multiplayer_research_request_pending
		and captured.size() == 1
		and int(captured[0].get("building_net_id", 0)) == 37
		and int(captured[0].get("peer_id", 0)) == 9
		and str(captured[0].get("operation", "")) == "player",
		"多人客户端研究必须只发送带建筑、玩家与操作类型的权威请求。"
	)
	proxy.complete_multiplayer_research_request(
		int(captured[0].get("request_id", 0)),
		false,
		ResearchCoordinator.RESULT_INSUFFICIENT_XIRANG
	)
	_expect(
		not proxy.multiplayer_research_request_pending,
		"主机结果返回后必须解除客户端研究请求锁。"
	)


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
