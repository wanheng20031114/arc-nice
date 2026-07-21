extends SceneTree

const PRODUCTION_COORDINATOR_SCENE := preload(
	"res://scene/plant_defense/production_coordinator.tscn"
)
const RESEARCH_COORDINATOR_SCENE := preload(
	"res://scene/plant_defense/research_coordinator.tscn"
)
const DAY_NIGHT_CONTROLLER_SCENE := preload(
	"res://scene/lighting/day_night_controller.tscn"
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
const BUILDING_DEFENSE_RESEARCH_ID := (
	GlobalResearchRegistry.BUILDING_DEFENSE_ID
)
const PLAYER_MOVE_SPEED_RESEARCH_ID := (
	GlobalResearchRegistry.PLAYER_MOVE_SPEED_ID
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
	var day_night := (
		DAY_NIGHT_CONTROLLER_SCENE.instantiate() as DayNightController
	)
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
		day_night,
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
	day_night.set_night_factor_immediate(1.0)
	await process_frame
	production.production_tick_timer.stop()
	research.research_tick_timer.stop()
	_expect(
		is_equal_approx(research.research_tick_timer.wait_time, 0.25),
		"科研进度必须以4Hz权威事件步进，使外框无需逐帧CPU Tween。"
	)

	_test_config_and_scene(config, center, panel, day_night)
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
	_test_operational_night_visuals(center, day_night)
	production.register_plant(warehouse)
	production.register_plant(second_warehouse)
	research.setup(production, plant_system, null)
	research.register_player(weishidaier)
	research.register_player(tiyi)
	research.register_player(hoe_cat)
	center.set_research_services(research, panel)
	await _test_panel_mouse_navigation(panel, center, weishidaier)
	plant_system.plant_footprints[center] = center.footprint_cells.duplicate()
	center.call("_sync_research_border")
	_expect_research_border_state(
		center,
		false,
		0.0,
		"没有全局研究时科研中心外框必须保持淡蓝噪波空闲态。"
	)

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
	center.call("_sync_research_border")
	_expect_research_border_state(
		center,
		true,
		0.0,
		"研究开始时科研中心外框必须立即切换为从顶部零点起步的进度态。"
	)
	await _test_research_border_event_step(center)
	_expect(
		production.get_total_item_count(PLANK) == 20
		and production.get_total_item_count(SAPLING) == 10
		and production.get_total_item_count(WATER_BOTTLE) == 5,
		"开始研究的同一帧必须原子扣除50木板、20树苗与20水瓶。"
	)
	var water_before_conflicting_request := production.get_total_item_count(
		WATER_BOTTLE
	)
	_expect(
		center.try_start_global_research(PLAYER_MOVE_SPEED_RESEARCH_ID)
		== ResearchCoordinator.RESULT_IN_PROGRESS
		and production.get_total_item_count(WATER_BOTTLE)
		== water_before_conflicting_request,
		"同一时刻只能进行一项全局研究，冲突请求不得预扣材料。"
	)
	research.advance_global_research(59.0)
	center.call("_sync_research_border")
	_expect_research_border_state(
		center,
		true,
		59.0 / 60.0,
		"研究未完成时科研中心外框必须准确采用最新权威进度。"
	)
	_expect(
		research.get_global_research_state(BUILDING_DEFENSE_RESEARCH_ID)
		== ResearchCoordinator.GlobalResearchState.RESEARCHING
		and is_equal_approx(
			research.get_global_elapsed_seconds(BUILDING_DEFENSE_RESEARCH_ID),
			59.0
		)
		and center.get_effective_physical_defense() == 5,
		"研究未满60秒时不得提前提供建筑物防。"
	)
	research.advance_global_research(1.0)
	center.call("_sync_research_border")
	_expect_research_border_state(
		center,
		false,
		0.0,
		"研究完成后科研中心外框必须退出进度态并恢复淡蓝空闲态。"
	)
	_expect(
		research.get_global_research_state(BUILDING_DEFENSE_RESEARCH_ID)
		== ResearchCoordinator.GlobalResearchState.COMPLETED
		and plant_system.get_global_physical_defense_bonus() == 10
		and center.get_effective_physical_defense() == 15,
		"研究完成后必须永久给现有建筑增加10点物防。"
	)
	_expect(
		center.try_start_global_research() == ResearchCoordinator.RESULT_COMPLETED,
		"完成的全局科技必须不可重复提交。"
	)

	await _test_global_move_speed_research(
		research,
		center,
		production,
		warehouse,
		second_warehouse,
		plant_system,
		[weishidaier, tiyi, hoe_cat],
		test_root
	)
	await _test_player_technology(research, center, panel, weishidaier, tiyi, hoe_cat)
	_test_multiplayer_request_contract(config, research, panel, test_root)
	_finish(test_root)


func _test_config_and_scene(
	config: PlantDefenseConfig,
	center: ResearchCenter,
	panel: ResearchCenterPanel,
	day_night: DayNightController
) -> void:
	var defense_research := GlobalResearchRegistry.get_config(
		BUILDING_DEFENSE_RESEARCH_ID
	)
	var move_speed_research := GlobalResearchRegistry.get_config(
		PLAYER_MOVE_SPEED_RESEARCH_ID
	)
	_expect(
		defense_research != null
		and defense_research.is_valid()
		and is_equal_approx(defense_research.duration_seconds, 60.0)
		and defense_research.effect_type
		== GlobalResearchConfig.EffectType.BUILDING_PHYSICAL_DEFENSE
		and is_equal_approx(defense_research.effect_amount, 10.0)
		and defense_research.input_items.size() == 3
		and defense_research.input_amounts == [50, 20, 20],
		"建筑结构强化必须是60秒、三种材料与全建筑物防+10的数据配置。"
	)
	_expect(
		move_speed_research != null
		and move_speed_research.is_valid()
		and is_equal_approx(move_speed_research.duration_seconds, 60.0)
		and move_speed_research.effect_type
		== GlobalResearchConfig.EffectType.PLAYER_MOVE_SPEED
		and is_equal_approx(move_speed_research.effect_amount, 15.0)
		and move_speed_research.input_items == [WATER_BOTTLE]
		and move_speed_research.input_amounts == [50],
		"全员移动训练必须消耗50水瓶、持续60秒并提供全员移速+15。"
	)
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
		var research_border := center.get_node_or_null(
			"ResearchBorder"
		) as MeshInstance2D
		var border_mesh := (
			research_border.mesh as QuadMesh
			if research_border != null
			else null
		)
		var border_material := (
			research_border.material as ShaderMaterial
			if research_border != null
			else null
		)
		var hotspot_glow := center.get_node_or_null(
			"HotspotGlow"
		) as NightPointLight2D
		var authored_lights: Array[Node] = center.find_children(
			"*",
			"Light2D",
			true,
			false
		)
		var hotspot_texture_source := FileAccess.get_file_as_string(
			"res://resources/lighting/research_center_hotspots.svg"
		)
		var request_timer := center.get_node_or_null(
			"MultiplayerResearchRequestTimer"
		) as Timer
		_expect(
			visual_root != null
			and visual_root.scale == Vector2(0.5, 0.5)
			and lower_sprite != null
			and upper_sprite != null
			and lower_sprite.texture != null
			and upper_sprite.texture != null
			and lower_sprite.texture.get_size() == Vector2(64, 64)
			and upper_sprite.texture.get_size() == Vector2(64, 64)
			and lower_sprite.texture_filter
			== CanvasItem.TEXTURE_FILTER_NEAREST
			and upper_sprite.texture_filter
			== CanvasItem.TEXTURE_FILTER_NEAREST
			and lower_sprite.z_index == 0
			and upper_sprite.z_index == 4
			and center.lifecycle_visual_paths
			== [
				NodePath("VisualRoot/LowerBody"),
				NodePath("VisualRoot/UpperForeground"),
			],
			"科研中心必须以两张互补64×64贴图、0.5世界缩放和nearest采样分层显示。"
		)
		_expect(
			lower_material != null
			and upper_material != null
			and not lower_material.resource_local_to_scene
			and not upper_material.resource_local_to_scene
			and lower_material.shader != null
			and lower_material.shader == upper_material.shader
			and lower_material.shader.resource_path
			== "res://resources/shader/research_center_lifecycle_glow.gdshader"
			and (
				lower_material.get_shader_parameter(&"lifecycle_noise")
				is Texture2D
			)
			and float(
				lower_material.get_shader_parameter(&"glow_core_strength")
			) > float(
				lower_material.get_shader_parameter(&"glow_halo_strength")
			)
			and float(
				lower_material.get_shader_parameter(&"glow_pulse_amount")
			) > 0.0
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
			"科研中心上下两层必须共用蓝色生命周期Shader，透明晕光只能由下层绘制。"
		)
		_expect(
			research_border != null
			and research_border.get_parent() == center
			and research_border.z_index == -1
			and research_border.texture_filter
			== CanvasItem.TEXTURE_FILTER_NEAREST
			and border_mesh != null
			and border_mesh.size == Vector2(32, 32)
			and border_material != null
			and not border_material.resource_local_to_scene
			and border_material.shader != null
			and border_material.shader.resource_path
			== "res://resources/shader/research_center_border.gdshader",
			"科研中心必须在未缩放根节点预建32×32、两个像素宽的独立科研进度外框。"
		)
		if border_material != null:
			var idle_blue: Color = border_material.get_shader_parameter(
				&"idle_blue"
			)
			var idle_shadow: Color = border_material.get_shader_parameter(
				&"idle_shadow"
			)
			var progress_cyan: Color = border_material.get_shader_parameter(
				&"progress_cyan"
			)
			var progress_aquamarine: Color = (
				border_material.get_shader_parameter(
					&"progress_aquamarine"
				)
			)
			_expect(
				idle_blue.is_equal_approx(
					Color(0.0, 191.0 / 255.0, 1.0, 1.0)
				)
				and idle_shadow.b > idle_shadow.g
				and progress_cyan.g >= 0.99
				and progress_cyan.b >= 0.99
				and progress_aquamarine.get_luminance()
				> idle_blue.get_luminance()
				and float(
					border_material.get_shader_parameter(
						&"data_noise_speed"
					)
				) > 0.0,
				"科研外框必须以#00BFFF为默认蓝，并以更明亮的青色噪波显示已完成进度。"
			)
		_expect(
			not center.has_method("_set_research_border_progress")
			and not center.has_method("_stop_border_progress_tween"),
			"科研外框进度必须只跟随低频权威研究事件更新，不能保留逐帧写参数的Tween回调。"
		)
		_expect(
			hotspot_glow != null
			and authored_lights.size() == 1
			and hotspot_glow.texture != null
			and hotspot_glow.texture.resource_path
			== "res://resources/lighting/research_center_hotspots.svg"
			and hotspot_glow.color.is_equal_approx(
				Color(112.0 / 255.0, 217.0 / 255.0, 1.0, 1.0)
			)
			and hotspot_glow.texture.get_size() == Vector2(256, 256)
			and is_equal_approx(hotspot_glow.texture_scale, 0.25)
			and is_equal_approx(hotspot_glow.night_energy, 0.72)
			and not hotspot_glow.starts_emitting
			and not hotspot_glow.shadow_enabled
			and not hotspot_glow.is_processing()
			and not hotspot_glow.is_physics_processing()
			and not hotspot_glow.is_emission_allowed()
			and not hotspot_glow.enabled
			and is_zero_approx(hotspot_glow.energy)
			and hotspot_glow.get("_controller") == day_night,
			"科研中心必须原生预建一盏绑定昼夜控制器、覆盖三处热点的淡蓝夜间灯。"
		)
		_expect(
			hotspot_texture_source.count("<circle ") == 3
			and hotspot_texture_source.contains(
				"cx=\"41.25\" cy=\"28.85\" r=\"5.5\""
			)
			and hotspot_texture_source.contains(
				"cx=\"22.63\" cy=\"41.55\" r=\"6.5\""
			)
			and hotspot_texture_source.contains(
				"cx=\"41.5\" cy=\"41.35\" r=\"6.5\""
			),
			"科研中心三处淡蓝热点必须保持光心位置并使用扩大的扩散半径。"
		)
		_expect(
			request_timer != null
			and request_timer.one_shot
			and is_equal_approx(request_timer.wait_time, 4.0),
			"科研中心必须原生预建4秒一次性多人请求超时Timer。"
		)
	_expect(
		panel != null
		and panel.has_node(
			"Overlay/PanelRoot/GlobalPage/ResearchListFrame/ResearchScroll"
		)
		and panel.has_node(
			"Overlay/PanelRoot/GlobalPage/ResearchListFrame/ResearchScroll/ResearchList/DefenseResearchButton"
		)
		and panel.has_node(
			"Overlay/PanelRoot/GlobalPage/ResearchListFrame/ResearchScroll/ResearchList/MoveSpeedResearchButton"
		)
		and panel.has_node("Overlay/PanelRoot/GlobalPage/PlankSlot")
		and panel.has_node("Overlay/PanelRoot/GlobalPage/SaplingSlot")
		and panel.has_node("Overlay/PanelRoot/GlobalPage/WaterBottleSlot")
		and panel.has_node("Overlay/PanelRoot/PlayerPage/TechNode1")
		and panel.has_node("Overlay/PanelRoot/PlayerPage/TechNode2")
		and panel.has_node("Overlay/PanelRoot/PlayerPage/TechNode3")
		and not panel.has_node("Overlay/PanelRoot/ToggleButton"),
		"科研UI必须原生包含双页与三处技术节点，并且不能有开关。"
	)
	_expect(
		is_equal_approx(
			ResearchCenterPanel.get_pixel_perfect_panel_scale(
				Vector2(1920.0, 1080.0)
			),
			1.0
		)
		and is_equal_approx(
			ResearchCenterPanel.get_pixel_perfect_panel_scale(
				Vector2(2560.0, 1440.0)
			),
			2.0
		)
		and is_equal_approx(
			ResearchCenterPanel.get_pixel_perfect_panel_scale(
				Vector2(640.0, 480.0)
			),
			0.5
		),
		"科研UI必须只使用整数放大或整数倒数缩小，避免模糊且不能在小窗口裁切。"
	)
	if panel != null:
		var background := panel.get_node("Overlay/PanelRoot/Background") as TextureRect
		var title_label := panel.get_node(
			"Overlay/PanelRoot/Title"
		) as Label
		var global_page := panel.get_node(
			"Overlay/PanelRoot/GlobalPage"
		) as Control
		var player_page := panel.get_node(
			"Overlay/PanelRoot/PlayerPage"
		) as Control
		var global_tab := panel.get_node(
			"Overlay/PanelRoot/GlobalTab"
		) as Button
		var player_tab := panel.get_node(
			"Overlay/PanelRoot/PlayerTab"
		) as Button
		var tab_style := global_tab.get_theme_stylebox(
			&"normal"
		) as StyleBoxFlat
		var close_button := panel.get_node(
			"Overlay/PanelRoot/CloseButton"
		) as Button
		var research_list_frame := panel.get_node(
			"Overlay/PanelRoot/GlobalPage/ResearchListFrame"
		) as Panel
		var research_scroll := panel.get_node(
			"Overlay/PanelRoot/GlobalPage/ResearchListFrame/ResearchScroll"
		) as ScrollContainer
		var list_hint := panel.get_node(
			"Overlay/PanelRoot/GlobalPage/ResearchListFrame/ListHint"
		) as Label
		var research_detail_frame := panel.get_node(
			"Overlay/PanelRoot/GlobalPage/ResearchDetailFrame"
		) as Panel
		var status_label := panel.get_node(
			"Overlay/PanelRoot/StatusLabel"
		) as Label
		var action_button := panel.get_node(
			"Overlay/PanelRoot/ActionButton"
		) as Button
		_expect(
			background.texture != null
			and background.texture.get_size() == Vector2(728, 544),
			"科研UI必须使用独立生成的728×544蓝色科技背景。"
		)
		_expect(
			global_page.mouse_filter == Control.MOUSE_FILTER_IGNORE
			and player_page.mouse_filter == Control.MOUSE_FILTER_IGNORE
			and global_tab.z_index > global_page.z_index
			and player_tab.z_index > player_page.z_index
			and close_button.z_index > global_page.z_index,
			"科研UI内容页必须忽略自身空白区鼠标，页签与关闭键必须显式位于内容页上层。"
		)
		_expect(
			title_label.get_rect().is_equal_approx(
				Rect2(168.0, 15.0, 392.0, 46.0)
			)
			and global_tab.get_rect().is_equal_approx(
				Rect2(49.0, 76.0, 155.0, 38.0)
			)
			and player_tab.get_rect().is_equal_approx(
				Rect2(204.0, 76.0, 145.0, 38.0)
			)
			and is_equal_approx(
				global_tab.position.x + global_tab.size.x,
				player_tab.position.x
			)
			and close_button.get_rect().is_equal_approx(
				Rect2(666.0, 18.0, 40.0, 41.0)
			),
			"科研UI标题、双页签与关闭热区必须贴合背景原生槽位。"
		)
		_expect(
			tab_style != null
			and tab_style.corner_radius_top_left == 9
			and tab_style.corner_radius_top_right == 9
			and tab_style.corner_radius_bottom_left == 2
			and tab_style.corner_radius_bottom_right == 2,
			"科研UI页签上沿必须贴合背景槽斜角，下沿保持近似直角。"
		)
		_expect(
			research_list_frame.get_rect().is_equal_approx(
				Rect2(42.0, 129.0, 182.0, 321.0)
			)
			and research_scroll.get_rect().is_equal_approx(
				Rect2(8.0, 40.0, 166.0, 246.0)
			)
			and list_hint.get_rect().is_equal_approx(
				Rect2(12.0, 294.0, 156.0, 19.0)
			)
			and research_detail_frame.get_rect().is_equal_approx(
				Rect2(234.0, 129.0, 452.0, 321.0)
			),
			"科研UI主内容框与研究列表底部必须保留一致的背景呼吸空间。"
		)
		_expect(
			status_label.get_rect().is_equal_approx(
				Rect2(96.0, 474.0, 326.0, 32.0)
			)
			and action_button.get_rect().is_equal_approx(
				Rect2(469.0, 470.0, 165.0, 40.0)
			),
			"科研UI状态文字与动作按钮必须完整落入底部背景槽。"
		)


func _test_panel_mouse_navigation(
	panel: ResearchCenterPanel,
	center: ResearchCenter,
	player: Player
) -> void:
	panel.open_for(center, player)
	await process_frame
	await process_frame
	_expect(
		panel.is_open()
		and player.controls_locked
		and panel.active_page == ResearchCenterPanel.Page.GLOBAL_TECH
		and panel.global_page.visible
		and not panel.player_page.visible,
		"科研面板打开时必须默认显示全局科技页并锁定玩家控制。"
	)

	await _click_panel_control(panel.player_tab)
	_expect(
		root.gui_get_hovered_control() == panel.player_tab
		and panel.active_page == ResearchCenterPanel.Page.PLAYER_TECH
		and not panel.global_page.visible
		and panel.player_page.visible
		and panel.player_tab.button_pressed,
		"真实点击玩家技术页签必须命中按钮并切换到玩家技术页。"
	)

	await _click_panel_control(panel.global_tab)
	_expect(
		root.gui_get_hovered_control() == panel.global_tab
		and panel.active_page == ResearchCenterPanel.Page.GLOBAL_TECH
		and panel.global_page.visible
		and not panel.player_page.visible
		and panel.global_tab.button_pressed,
		"真实点击全局科技页签必须命中按钮并切回全局科技页。"
	)

	await _click_panel_control(panel.close_button)
	_expect(
		not panel.is_open()
		and not panel.visible
		and not player.controls_locked,
		"真实点击右上关闭键必须关闭科研面板并恢复玩家控制。"
	)


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


func _test_operational_night_visuals(
	center: ResearchCenter,
	day_night: DayNightController
) -> void:
	var hotspot_glow := center.get_node_or_null(
		"HotspotGlow"
	) as NightPointLight2D
	_expect(
		hotspot_glow != null
		and center.is_operational
		and day_night.is_night()
		and hotspot_glow.visible
		and hotspot_glow.is_visible_in_tree()
		and hotspot_glow.is_emission_allowed()
		and hotspot_glow.enabled
		and is_equal_approx(hotspot_glow.energy, 0.72),
		"科研中心完成建造后，三处淡蓝热点必须在黑夜立即启用额定微光。"
	)
	day_night.set_night_factor_immediate(0.0)
	_expect(
		hotspot_glow != null
		and not hotspot_glow.enabled
		and is_zero_approx(hotspot_glow.energy),
		"科研中心三处热点必须在白昼关闭真实灯光，不能常驻耗费灯光预算。"
	)
	day_night.set_night_factor_immediate(1.0)
	_expect(
		hotspot_glow != null
		and hotspot_glow.enabled
		and is_equal_approx(hotspot_glow.energy, 0.72),
		"科研中心三处热点必须能随昼夜控制器重新进入淡蓝夜间微光态。"
	)
	var research_border := center.get_node_or_null(
		"ResearchBorder"
	) as MeshInstance2D
	center.call("_on_construction_started")
	_expect(
		research_border != null
		and not research_border.visible
		and hotspot_glow != null
		and not hotspot_glow.is_emission_allowed()
		and not hotspot_glow.enabled
		and is_zero_approx(hotspot_glow.energy),
		"科研中心建造过程中必须同时隐藏科研外框并关闭三热点灯。"
	)
	center.call("_on_construction_finished", false)
	_expect(
		research_border != null
		and research_border.visible
		and is_equal_approx(research_border.modulate.a, 1.0)
		and hotspot_glow != null
		and hotspot_glow.is_emission_allowed()
		and hotspot_glow.enabled
		and is_equal_approx(hotspot_glow.energy, 0.72),
		"科研中心建造完成后必须恢复科研外框与三热点夜间微光。"
	)


func _expect_research_border_state(
	center: ResearchCenter,
	expected_working: bool,
	expected_progress: float,
	message: String
) -> void:
	var research_border := center.get_node_or_null(
		"ResearchBorder"
	) as MeshInstance2D
	if research_border == null:
		_expect(false, message)
		return
	var actual_working := bool(
		research_border.get_instance_shader_parameter(&"working_active")
	)
	var actual_progress := float(
		research_border.get_instance_shader_parameter(&"progress_value")
	)
	_expect(
		actual_working == expected_working
		and absf(actual_progress - expected_progress) <= 0.0001,
		"%s（working=%s，progress=%.4f）" % [
			message,
			str(actual_working),
			actual_progress,
		]
	)


func _test_research_border_event_step(center: ResearchCenter) -> void:
	var research_border := center.get_node_or_null(
		"ResearchBorder"
	) as MeshInstance2D
	if research_border == null:
		_expect(false, "科研外框事件步进测试必须找到ResearchBorder节点。")
		return
	var progress_anchor := float(
		research_border.get_instance_shader_parameter(&"progress_value")
	)
	await create_timer(0.05).timeout
	var progress_after_time := float(
		research_border.get_instance_shader_parameter(&"progress_value")
	)
	_expect(
		absf(progress_after_time - progress_anchor) <= 0.000001,
		"没有权威研究事件时外框进度必须保持不变，不能保留逐帧CPU Tween。"
	)


func _test_global_move_speed_research(
	research: ResearchCoordinator,
	center: ResearchCenter,
	production: ProductionCoordinator,
	warehouse: OakWarehouse,
	second_warehouse: OakWarehouse,
	plant_system: PlantSystem,
	players: Array,
	test_root: Node
) -> void:
	var speeds_before: Dictionary = {}
	for player_variant in players:
		var player := player_variant as Player
		speeds_before[player.get_instance_id()] = player.move_speed

	_expect(
		warehouse.try_add_storage_item_count(WATER_BOTTLE, 44),
		"移动研究测试必须能把共享水瓶补到49个。"
	)
	_expect(
		production.get_total_item_count(WATER_BOTTLE) == 49
		and center.try_start_global_research(PLAYER_MOVE_SPEED_RESEARCH_ID)
		== ResearchCoordinator.RESULT_MISSING_INPUT
		and production.get_total_item_count(WATER_BOTTLE) == 49,
		"全员移动训练缺少第50个水瓶时必须原子失败且不得扣料。"
	)
	_expect(
		second_warehouse.try_add_storage_item_count(WATER_BOTTLE, 1),
		"移动研究测试必须能补入最后1个水瓶。"
	)
	_expect(
		center.try_start_global_research(PLAYER_MOVE_SPEED_RESEARCH_ID)
		== ResearchCoordinator.RESULT_SUCCESS
		and production.get_total_item_count(WATER_BOTTLE) == 0,
		"全员移动训练开始时必须一次且仅一次扣除50个水瓶。"
	)
	research.advance_global_research(59.0)
	for player_variant in players:
		var player := player_variant as Player
		_expect(
			is_equal_approx(
				player.move_speed,
				float(speeds_before[player.get_instance_id()])
			),
			"全员移动训练未满60秒时不得提前增加玩家移速。"
		)
	research.advance_global_research(1.0)
	_expect(
		research.get_global_research_state(PLAYER_MOVE_SPEED_RESEARCH_ID)
		== ResearchCoordinator.GlobalResearchState.COMPLETED
		and research.get_active_global_research_id().is_empty()
		and plant_system.get_global_physical_defense_bonus() == 10,
		"移动研究完成后必须保留已完成的建筑防御研究，并清空研究队列。"
	)
	for player_variant in players:
		var player := player_variant as Player
		var expected_speed := (
			float(speeds_before[player.get_instance_id()])
			+ ResearchCoordinator.GLOBAL_PLAYER_MOVE_SPEED_BONUS
		)
		_expect(
			is_equal_approx(player.move_speed, expected_speed),
			"移动研究完成后必须给每个已注册玩家增加15点移速。"
		)
		player.call("_refresh_collectible_stats", false)
		_expect(
			is_equal_approx(player.move_speed, expected_speed),
			"收藏品属性刷新后必须保留科研提供的15点移速。"
		)
	_expect(
		center.try_start_global_research(PLAYER_MOVE_SPEED_RESEARCH_ID)
		== ResearchCoordinator.RESULT_COMPLETED,
		"全员移动训练完成后不得重复扣水瓶或重复叠加。"
	)

	var late_player := WEISHIDAIER_SCENE.instantiate() as Player
	test_root.add_child(late_player)
	await process_frame
	late_player.peer_id = 4
	var late_base_speed := late_player.move_speed
	research.register_player(late_player)
	_expect(
		is_equal_approx(
			late_player.move_speed,
			late_base_speed + ResearchCoordinator.GLOBAL_PLAYER_MOVE_SPEED_BONUS
		),
		"移动研究完成后注册的新玩家必须立即获得15点移速。"
	)

	var remote_research := (
		RESEARCH_COORDINATOR_SCENE.instantiate() as ResearchCoordinator
	)
	var remote_plant_system := PlantSystem.new()
	var remote_player := TIYI_SCENE.instantiate() as Player
	test_root.add_child(remote_research)
	test_root.add_child(remote_plant_system)
	test_root.add_child(remote_player)
	await process_frame
	remote_research.research_tick_timer.stop()
	remote_research.setup(null, remote_plant_system, null)
	remote_research.set_authoritative_processing_enabled(false)
	remote_player.peer_id = 8
	var remote_base_speed := remote_player.move_speed
	remote_research.register_player(remote_player)
	var snapshot := research.export_runtime_state()
	remote_research.apply_multiplayer_runtime_state(snapshot)
	_expect(
		int(snapshot.get("schema", 0))
		== ResearchCoordinator.RUNTIME_STATE_SCHEMA
		and remote_research.get_global_research_state(
			BUILDING_DEFENSE_RESEARCH_ID
		) == ResearchCoordinator.GlobalResearchState.COMPLETED
		and remote_research.get_global_research_state(
			PLAYER_MOVE_SPEED_RESEARCH_ID
		) == ResearchCoordinator.GlobalResearchState.COMPLETED
		and remote_plant_system.get_global_physical_defense_bonus() == 10
		and is_equal_approx(
			remote_player.move_speed,
			remote_base_speed + ResearchCoordinator.GLOBAL_PLAYER_MOVE_SPEED_BONUS
		),
		"多人科研快照必须同时同步两项全局效果。"
	)
	var replayed_snapshot := snapshot.duplicate(true)
	replayed_snapshot["revision"] = int(snapshot["revision"]) + 1
	remote_research.apply_multiplayer_runtime_state(replayed_snapshot)
	_expect(
		is_equal_approx(
			remote_player.move_speed,
			remote_base_speed + ResearchCoordinator.GLOBAL_PLAYER_MOVE_SPEED_BONUS
		),
		"重复应用更高revision的完成态快照也不得重复叠加移速。"
	)
	var accepted_revision := remote_research.research_revision
	var forged_snapshot := replayed_snapshot.duplicate(true)
	forged_snapshot["revision"] = accepted_revision + 1
	forged_snapshot["active_global_research_id"] = "forged_research"
	remote_research.apply_multiplayer_runtime_state(forged_snapshot)
	_expect(
		remote_research.research_revision == accepted_revision
		and is_equal_approx(
			remote_player.move_speed,
			remote_base_speed + ResearchCoordinator.GLOBAL_PLAYER_MOVE_SPEED_BONUS
		),
		"客户端必须拒绝未知研究ID的多人快照且不能污染既有效果。"
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
	var result_contexts: Array[Dictionary] = []
	proxy.research_command_requested.connect(
		func(command: Dictionary) -> void: captured.append(command)
	)
	proxy.multiplayer_research_result.connect(
		func(
			success: bool,
			reason: StringName,
			operation: StringName,
			research_id: StringName
		) -> void:
			result_contexts.append({
				"success": success,
				"reason": reason,
				"operation": operation,
				"research_id": research_id,
			})
	)
	var result := proxy.try_purchase_player_technology(null)
	_expect(
		result == ResearchCoordinator.RESULT_REQUEST_SENT
		and proxy.multiplayer_research_request_pending
		and captured.size() == 1
		and int(captured[0].get("schema", 0)) == 2
		and int(captured[0].get("building_net_id", 0)) == 37
		and int(captured[0].get("peer_id", 0)) == 9
		and str(captured[0].get("operation", "")) == "player"
		and str(captured[0].get("research_id", "")).is_empty(),
		"多人客户端个人研究必须发送schema2、建筑、玩家与操作类型。"
	)
	proxy.complete_multiplayer_research_request(
		int(captured[0].get("request_id", 0)),
		false,
		ResearchCoordinator.RESULT_INSUFFICIENT_XIRANG
	)
	_expect(
		not proxy.multiplayer_research_request_pending
		and result_contexts.size() == 1
		and result_contexts[0].get("operation", &"") == &"player"
		and result_contexts[0].get("research_id", &"") == &"",
		"主机结果返回后必须解除请求锁，并保留个人研究请求类型。"
	)
	var global_result := proxy.try_start_global_research(
		PLAYER_MOVE_SPEED_RESEARCH_ID
	)
	_expect(
		global_result == ResearchCoordinator.RESULT_REQUEST_SENT
		and captured.size() == 2
		and int(captured[1].get("schema", 0)) == 2
		and str(captured[1].get("operation", "")) == "global"
		and str(captured[1].get("research_id", ""))
		== String(PLAYER_MOVE_SPEED_RESEARCH_ID),
		"多人全局研究请求必须只携带白名单研究ID，由主机决定材料与效果。"
	)
	proxy.complete_multiplayer_research_request(
		int(captured[1].get("request_id", 0)),
		true,
		ResearchCoordinator.RESULT_SUCCESS
	)
	_expect(
		result_contexts.size() == 2
		and result_contexts[1].get("operation", &"") == &"global"
		and result_contexts[1].get("research_id", &"")
		== PLAYER_MOVE_SPEED_RESEARCH_ID,
		"多人回包必须携带原全局研究ID，面板重开后也能显示正确项目。"
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
