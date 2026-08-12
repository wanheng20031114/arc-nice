extends SceneTree

const COORDINATOR_SCENE := preload(
	"res://scene/game_modes/tower_defense/economy/production/production_coordinator.tscn"
)
const WAREHOUSE_SCENE := preload(
	"res://scene/plant_defense/oak_warehouse.tscn"
)
const PLANT_SELECTION_HUD_SCENE := preload(
	"res://scene/game_modes/tower_defense/ui/plant_selection/plant_selection_hud.tscn"
)
const CULTIVATION_CENTER_SCENE := preload(
	"res://scene/plant_defense/plant_cultivation_center.tscn"
)
const DAY_NIGHT_CONTROLLER_SCENE := preload(
	"res://scene/lighting/day_night_controller.tscn"
)
const PLAYER_SCENE := preload(
	"res://scene/player/hoe_cat/player_hoe_cat.tscn"
)
const ENEMY_SCENE := preload("res://scene/enemy/enemy.tscn")
const LINGLAN_BOSS_SCENE := preload(
	"res://scene/boss/linglan/linglan_boss.tscn"
)
const HOTSPOT_LIGHT_TEXTURE := preload(
	"res://resources/lighting/planting_base_hotspots.svg"
)
const SAPLING := preload(
	"res://resources/config/materials/material_sapling.tres"
)
const WOOD := preload(
	"res://resources/config/materials/material_wood.tres"
)

const PLANTING_BASE_TEXTURE_PATH := (
	"res://resources/texture/plant_defense/planting_base/planting_base.png"
)
const LOWER_BODY_TEXTURE_PATH := (
	"res://resources/texture/plant_defense/planting_base/layers/lower_body.png"
)
const UPPER_CANOPY_TEXTURE_PATH := (
	"res://resources/texture/plant_defense/planting_base/layers/upper_canopy.png"
)
const CULTIVATION_BORDER_SHADER_PATH := (
	"res://resources/shader/plant_cultivation_center_border.gdshader"
)

var failures: PackedStringArray = []


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var test_root := Node.new()
	test_root.name = "PlantingBaseSmokeTest"
	root.add_child(test_root)

	var config := PlantDefenseRegistry.get_config(&"planting_base")
	_expect(
		config != null
		and config.is_valid()
		and config.plant_id == &"planting_base"
		and config.display_name == "种植基地"
		and config.supports_multiplayer
		and config.max_health == 2000
		and config.physical_defense == 5
		and config.magic_defense == 10
		and config.footprint_size == Vector2i(2, 2)
		and config.placement_surface
		== PlantDefenseConfig.PlacementSurface.GRASS_ONLY,
		"种植基地必须是支持联机的2×2草地建筑，并具有2000生命、5物防和10法防。"
	)
	if config == null or not config.is_valid():
		await _finish(test_root)
		return

	var warehouse_config := PlantDefenseRegistry.get_config(&"oak_warehouse")
	var day_night_controller := (
		DAY_NIGHT_CONTROLLER_SCENE.instantiate() as DayNightController
	)
	var coordinator := COORDINATOR_SCENE.instantiate() as ProductionCoordinator
	var warehouse := WAREHOUSE_SCENE.instantiate() as OakWarehouse
	var planting_base := config.plant_scene.instantiate() as PlantingBase
	test_root.add_child(day_night_controller)
	test_root.add_child(coordinator)
	test_root.add_child(warehouse)
	if planting_base != null:
		test_root.add_child(planting_base)
	await process_frame
	coordinator.production_tick_timer.stop()
	day_night_controller.set_night_factor_immediate(1.0)

	_expect(planting_base != null, "种植基地场景根节点必须继承PlantingBase。")
	if planting_base == null or warehouse_config == null:
		await _finish(test_root)
		return

	warehouse.setup(warehouse_config, null, [Vector2i.ZERO])
	planting_base.setup(
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
	coordinator.register_plant(planting_base)

	_test_scene_contract(planting_base)
	_test_world_glow_contract(planting_base, day_night_controller)
	_test_recipe_contract(planting_base)
	_test_border_contract(planting_base)
	_test_asset_contract()
	_test_completion_transactions(planting_base, warehouse, coordinator)
	await _test_full_storage_retry(test_root, config, warehouse_config)
	await _test_multiplayer_runtime_contract(test_root, config, planting_base)
	await _test_hud_follow_focus(test_root, config)

	await _finish(test_root)


func _test_scene_contract(planting_base: PlantingBase) -> void:
	var visual_root := planting_base.get_node_or_null("VisualRoot") as Node2D
	var lower_body := planting_base.get_node_or_null(
		"VisualRoot/LowerBody"
	) as Sprite2D
	var upper_canopy := planting_base.get_node_or_null(
		"VisualRoot/UpperCanopy"
	) as Sprite2D
	var lifecycle_material := (
		lower_body.material as ShaderMaterial
		if lower_body != null
		else null
	)
	var request_timer := planting_base.get_node_or_null(
		"MultiplayerProductionRequestTimer"
	) as Timer
	var direct_timers := planting_base.find_children("*", "Timer", false, false)
	_expect(
		planting_base.get_node_or_null("ProductionBorder") is MeshInstance2D
		and visual_root != null
		and visual_root.scale == Vector2(0.5, 0.5)
		and not visual_root.y_sort_enabled
		and lower_body != null
		and upper_canopy != null
		and lower_body.z_index == 0
		and upper_canopy.z_index == 4
		and lower_body.z_as_relative
		and upper_canopy.z_as_relative
		and lower_body.texture_filter == CanvasItem.TEXTURE_FILTER_NEAREST
		and upper_canopy.texture_filter == CanvasItem.TEXTURE_FILTER_NEAREST
		and lower_body.texture != null
		and upper_canopy.texture != null
		and lower_body.texture.get_size() == Vector2(64, 64)
		and upper_canopy.texture.get_size() == Vector2(64, 64)
		and lifecycle_material != null
		and lifecycle_material.resource_path
		== "res://resources/shader/plant_lifecycle_material.tres"
		and upper_canopy.material == lifecycle_material
		and planting_base.lifecycle_visual_paths
		== [
			NodePath("VisualRoot/LowerBody"),
			NodePath("VisualRoot/UpperCanopy"),
		]
		and planting_base.get_node_or_null("CollisionShape2D") is CollisionShape2D
		and planting_base.get_node_or_null("PlayerCoreBody/CollisionShape2D")
		is CollisionShape2D
		and planting_base.get_node_or_null("InteractionArea/CollisionShape2D")
		is CollisionShape2D
		and planting_base.get_node_or_null("InteractionPrompt") is Control
		and planting_base.get_node_or_null("HealthBar") is PlantHealthBar,
		"种植基地必须用互补双层原生Sprite搭建32像素世界主体，并保留碰撞、交互提示与公共血条。"
	)
	if lower_body != null and upper_canopy != null:
		planting_base.call(
			"_set_lifecycle_parameter",
			&"construction_progress",
			0.375
		)
		_expect(
			is_equal_approx(
				float(
					lower_body.get_instance_shader_parameter(
						&"construction_progress"
					)
				),
				0.375
			)
			and is_equal_approx(
				float(
					upper_canopy.get_instance_shader_parameter(
						&"construction_progress"
					)
				),
				0.375
			),
			"上下互补层必须同步接收同一建造/拆除生命周期实例参数，不能产生分层接缝。"
		)
		planting_base.call(
			"_set_lifecycle_parameter",
			&"construction_progress",
			1.0
		)
	_test_foreground_z_contract(visual_root, lower_body, upper_canopy)
	_expect(
		direct_timers.size() == 1
		and request_timer != null
		and request_timer.one_shot
		and is_equal_approx(request_timer.wait_time, 4.0),
		"种植基地直属节点只能预置4秒多人生产请求Timer。"
	)


func _test_foreground_z_contract(
	visual_root: Node2D,
	lower_body: Sprite2D,
	upper_canopy: Sprite2D
) -> void:
	var player := PLAYER_SCENE.instantiate() as Player
	var enemy := ENEMY_SCENE.instantiate() as Enemy
	var boss := LINGLAN_BOSS_SCENE.instantiate() as Enemy
	var player_sprite := (
		player.get_node_or_null("BodySprite") as AnimatedSprite2D
		if player != null
		else null
	)
	var enemy_sprite := (
		enemy.get_node_or_null("AnimatedSprite2D") as AnimatedSprite2D
		if enemy != null
		else null
	)
	var boss_sprite := (
		boss.get_node_or_null("AnimatedSprite2D") as AnimatedSprite2D
		if boss != null
		else null
	)
	_expect(
		visual_root != null
		and lower_body != null
		and upper_canopy != null
		and _effective_z_index(lower_body) == 0
		and player_sprite != null
		and _effective_z_index(player_sprite) == 1
		and enemy_sprite != null
		and _effective_z_index(enemy_sprite) == 2
		and boss_sprite != null
		and _effective_z_index(boss_sprite) == 3
		and _effective_z_index(upper_canopy) == 4,
		"蓝圈上层必须复用竹筒迫击炮的z=4前景规则，严格覆盖玩家、普通敌人与Boss身体。"
	)
	if player != null:
		player.free()
	if enemy != null:
		enemy.free()
	if boss != null:
		boss.free()


func _test_world_glow_contract(
	planting_base: PlantingBase,
	day_night_controller: DayNightController
) -> void:
	var hotspot_glow := planting_base.get_node_or_null(
		"HotspotGlow"
	) as NightPointLight2D
	var authored_lights: Array[Node] = planting_base.find_children(
		"*",
		"Light2D",
		true,
		false
	)
	var cultivation_center := (
		CULTIVATION_CENTER_SCENE.instantiate() as PlantCultivationCenter
	)
	var reference_glow := (
		cultivation_center.get_node_or_null("HotspotGlow") as NightPointLight2D
		if cultivation_center != null
		else null
	)
	_expect(
		hotspot_glow != null
		and authored_lights.size() == 1
		and hotspot_glow.texture == HOTSPOT_LIGHT_TEXTURE
		and HOTSPOT_LIGHT_TEXTURE.get_size() == Vector2(256, 256)
		and hotspot_glow.texture_filter == CanvasItem.TEXTURE_FILTER_LINEAR
		and reference_glow != null
		and hotspot_glow.color.is_equal_approx(reference_glow.color)
		and is_equal_approx(
			hotspot_glow.texture_scale,
			reference_glow.texture_scale
		)
		and is_equal_approx(
			hotspot_glow.night_energy,
			reference_glow.night_energy
		)
		and not hotspot_glow.shadow_enabled
		and not hotspot_glow.starts_emitting
		and hotspot_glow.is_emission_allowed()
		and hotspot_glow.get("_controller") == day_night_controller
		and hotspot_glow.enabled
		and is_equal_approx(hotspot_glow.energy, 0.84),
		"红圈三处必须共用一盏参数与培育中心完全一致、已绑定昼夜系统的嫩绿色多热点夜灯。"
	)
	day_night_controller.set_night_factor_immediate(0.0)
	_expect(
		hotspot_glow != null
		and not hotspot_glow.enabled
		and is_zero_approx(hotspot_glow.energy),
		"种植基地三热点灯必须在白天彻底关闭。"
	)
	day_night_controller.set_night_factor_immediate(1.0)
	planting_base.call("_on_construction_started")
	_expect(
		hotspot_glow != null
		and not hotspot_glow.is_emission_allowed()
		and not hotspot_glow.enabled
		and is_zero_approx(hotspot_glow.energy),
		"种植基地建造期间必须关闭三处夜间热点。"
	)
	planting_base.call("_on_construction_finished", false)
	_expect(
		hotspot_glow != null
		and hotspot_glow.is_emission_allowed()
		and hotspot_glow.enabled
		and is_equal_approx(hotspot_glow.energy, 0.84),
		"种植基地建造完成后必须恢复三处夜间热点。"
	)
	planting_base.call(
		"_on_removal_started",
		PlantDefense.RemovalMode.SILENT
	)
	_expect(
		hotspot_glow != null
		and not hotspot_glow.is_emission_allowed()
		and not hotspot_glow.enabled,
		"种植基地拆除开始时必须立即关闭夜间热点。"
	)
	var hotspot_source := FileAccess.get_file_as_string(
		"res://resources/lighting/planting_base_hotspots.svg"
	)
	_expect(
		hotspot_source.count("<circle ") == 3
		and hotspot_source.contains(
			"cx=\"31.75\" cy=\"23.25\" r=\"6.5\""
		)
		and hotspot_source.contains(
			"cx=\"31.75\" cy=\"29.75\" r=\"6\""
		)
		and hotspot_source.contains(
			"cx=\"31.75\" cy=\"36.75\" r=\"5\""
		),
		"夜灯遮罩必须严格对应顶部叶晶、中央树苗和前部晶核三个红圈位置。"
	)
	if cultivation_center != null:
		cultivation_center.free()


func _test_recipe_contract(planting_base: PlantingBase) -> void:
	_expect(
		planting_base.recipes.size() == 2
		and planting_base.recipes[0].is_valid()
		and planting_base.recipes[0].recipe_id == &"sapling_propagation"
		and planting_base.recipes[0].input_items == [SAPLING]
		and planting_base.recipes[0].input_amounts == [1]
		and planting_base.recipes[0].output_items == [SAPLING]
		and planting_base.recipes[0].output_amounts == [2]
		and planting_base.recipes[0].input_source
		== ProductionRecipe.InputSource.SHARED_STORAGE
		and planting_base.recipes[0].output_destination
		== ProductionRecipe.OutputDestination.SHARED_STORAGE
		and is_equal_approx(
			planting_base.recipes[0].duration_seconds,
			30.0
		)
		and planting_base.recipes[1].is_valid()
		and planting_base.recipes[1].recipe_id == &"sapling_to_wood"
		and planting_base.recipes[1].input_items == [SAPLING]
		and planting_base.recipes[1].input_amounts == [1]
		and planting_base.recipes[1].output_items == [WOOD]
		and planting_base.recipes[1].output_amounts == [5]
		and planting_base.recipes[1].input_source
		== ProductionRecipe.InputSource.SHARED_STORAGE
		and planting_base.recipes[1].output_destination
		== ProductionRecipe.OutputDestination.SHARED_STORAGE
		and is_equal_approx(
			planting_base.recipes[1].duration_seconds,
			60.0
		),
		"种植基地必须按固定顺序提供仓库1树苗→30秒2树苗、1树苗→60秒5木头两条配方。"
	)


func _test_border_contract(planting_base: PlantingBase) -> void:
	var border := planting_base.get_node_or_null("ProductionBorder") as MeshInstance2D
	var border_mesh := border.mesh as QuadMesh if border != null else null
	var border_material := (
		border.material as ShaderMaterial
		if border != null
		else null
	)
	var cultivation_center := (
		CULTIVATION_CENTER_SCENE.instantiate() as PlantCultivationCenter
	)
	var reference_border := cultivation_center.get_node_or_null(
		"ProductionBorder"
	) as MeshInstance2D
	var reference_material := (
		reference_border.material as ShaderMaterial
		if reference_border != null
		else null
	)
	_expect(
		border != null
		and border_mesh != null
		and border_mesh.size == Vector2(32, 32)
		and border_material != null
		and reference_material != null
		and border_material.shader == reference_material.shader
		and border_material.shader.resource_path == CULTIVATION_BORDER_SHADER_PATH
		and border_material.shader.code.contains(
			"pixel.x < 2.0 || pixel.y < 2.0"
		)
		and border_material.shader.code.contains(
			"pixel.x >= 30.0 || pixel.y >= 30.0"
		),
		"种植基地必须直接复用培育中心32×32、四边2像素宽的绿色生产边框Shader。"
	)
	if border_material != null and reference_material != null:
		var base_idle_green: Color = border_material.get_shader_parameter(
			&"idle_green"
		)
		var reference_idle_green: Color = reference_material.get_shader_parameter(
			&"idle_green"
		)
		var base_idle_shadow: Color = border_material.get_shader_parameter(
			&"idle_shadow"
		)
		var reference_idle_shadow: Color = reference_material.get_shader_parameter(
			&"idle_shadow"
		)
		var base_progress_green: Color = border_material.get_shader_parameter(
			&"progress_green"
		)
		var reference_progress_green: Color = reference_material.get_shader_parameter(
			&"progress_green"
		)
		_expect(
			base_idle_green.is_equal_approx(reference_idle_green)
			and base_idle_shadow.is_equal_approx(reference_idle_shadow)
			and base_progress_green.is_equal_approx(reference_progress_green)
			and is_equal_approx(
				float(border_material.get_shader_parameter(&"leaf_noise_speed")),
				float(reference_material.get_shader_parameter(&"leaf_noise_speed"))
			),
			"种植基地绿色边框的三种颜色与叶片噪波速度必须和培育中心完全一致。"
		)
	cultivation_center.free()


func _test_asset_contract() -> void:
	var texture := load(PLANTING_BASE_TEXTURE_PATH) as Texture2D
	var image := Image.load_from_file(
		ProjectSettings.globalize_path(PLANTING_BASE_TEXTURE_PATH)
	)
	var lower_image := Image.load_from_file(
		ProjectSettings.globalize_path(LOWER_BODY_TEXTURE_PATH)
	)
	var upper_image := Image.load_from_file(
		ProjectSettings.globalize_path(UPPER_CANOPY_TEXTURE_PATH)
	)
	_expect(
		texture != null
		and texture.get_size() == Vector2(64, 64)
		and image != null
		and not image.is_empty()
		and image.get_size() == Vector2i(64, 64)
		and lower_image != null
		and not lower_image.is_empty()
		and lower_image.get_size() == Vector2i(64, 64)
		and upper_image != null
		and not upper_image.is_empty()
		and upper_image.get_size() == Vector2i(64, 64),
		"种植基地组合图与上下互补层必须全部保持64×64完整画布。"
	)
	if (
		image == null
		or image.is_empty()
		or lower_image == null
		or lower_image.is_empty()
		or upper_image == null
		or upper_image.is_empty()
	):
		return
	var used_rect := image.get_used_rect()
	var alpha_is_binary := true
	var transparent_rgb_is_clean := true
	var visible_colors: Dictionary = {}
	for y in image.get_height():
		for x in image.get_width():
			var pixel := image.get_pixel(x, y)
			if not is_zero_approx(pixel.a) and not is_equal_approx(pixel.a, 1.0):
				alpha_is_binary = false
			if is_zero_approx(pixel.a):
				if not (
					is_zero_approx(pixel.r)
					and is_zero_approx(pixel.g)
					and is_zero_approx(pixel.b)
				):
					transparent_rgb_is_clean = false
			else:
				visible_colors[pixel] = true
	_expect(
		used_rect.size.x <= 60
		and used_rect.size.y <= 60
		and alpha_is_binary
		and transparent_rgb_is_clean
		and visible_colors.size() <= 64,
		"种植基地主体必须限制在60×60内，并保持二值透明、透明RGB清零和至多64色。"
	)
	var upper_visible_pixels := 0
	var lower_visible_pixels := 0
	var layers_overlap := false
	var lossless_recomposition := true
	for y in image.get_height():
		for x in image.get_width():
			var source_pixel := image.get_pixel(x, y)
			var lower_pixel := lower_image.get_pixel(x, y)
			var upper_pixel := upper_image.get_pixel(x, y)
			var lower_visible := lower_pixel.a > 0.0
			var upper_visible := upper_pixel.a > 0.0
			if lower_visible:
				lower_visible_pixels += 1
			if upper_visible:
				upper_visible_pixels += 1
			if lower_visible and upper_visible:
				layers_overlap = true
			var recomposed_pixel := (
				upper_pixel if upper_visible else lower_pixel
			)
			if recomposed_pixel != source_pixel:
				lossless_recomposition = false
	_expect(
		not layers_overlap
		and lossless_recomposition
		and upper_visible_pixels == 383
		and lower_visible_pixels == 1823,
		"蓝圈上层与下层必须逐像素互斥，并以383/1823个可见像素无损重组正式贴图。"
	)


func _test_completion_transactions(
	planting_base: PlantingBase,
	warehouse: OakWarehouse,
	coordinator: ProductionCoordinator
) -> void:
	var storage_events: Array[int] = []
	warehouse.storage_changed.connect(
		func() -> void: storage_events.append(warehouse.get_storage_revision())
	)
	_expect(
		warehouse.try_add_storage_item_count(SAPLING, 1)
		and planting_base.select_recipe(&"sapling_propagation"),
		"树苗繁育事务测试必须能准备1棵树苗并选择配方。"
	)
	storage_events.clear()
	var propagation_revision := warehouse.get_storage_revision()
	planting_base.advance_shared_production_tick(29.0)
	_expect(
		coordinator.get_total_item_count(SAPLING) == 1
		and coordinator.get_total_item_count(WOOD) == 0
		and is_equal_approx(planting_base.progress_elapsed_seconds, 29.0)
		and warehouse.get_storage_revision() == propagation_revision
		and storage_events.is_empty(),
		"树苗繁育到29秒时不得提前读取、扣除或写入仓库。"
	)
	planting_base.advance_shared_production_tick(1.0)
	_expect(
		coordinator.get_total_item_count(SAPLING) == 2
		and coordinator.get_total_item_count(WOOD) == 0
		and is_zero_approx(planting_base.progress_elapsed_seconds)
		and warehouse.get_storage_revision() == propagation_revision + 1
		and storage_events.size() == 1,
		"树苗繁育必须在第30秒以一次仓库事务把1棵树苗瞬间转为2棵。"
	)

	storage_events.clear()
	_expect(
		planting_base.select_recipe(&"sapling_to_wood"),
		"木材培育事务测试必须能切换至树苗转木头配方。"
	)
	var wood_revision := warehouse.get_storage_revision()
	planting_base.advance_shared_production_tick(59.0)
	_expect(
		coordinator.get_total_item_count(SAPLING) == 2
		and coordinator.get_total_item_count(WOOD) == 0
		and is_equal_approx(planting_base.progress_elapsed_seconds, 59.0)
		and warehouse.get_storage_revision() == wood_revision
		and storage_events.is_empty(),
		"木材培育到59秒时不得提前读取、扣除或写入仓库。"
	)
	planting_base.advance_shared_production_tick(1.0)
	_expect(
		coordinator.get_total_item_count(SAPLING) == 1
		and coordinator.get_total_item_count(WOOD) == 5
		and is_zero_approx(planting_base.progress_elapsed_seconds)
		and warehouse.get_storage_revision() == wood_revision + 1
		and storage_events.size() == 1,
		"木材培育必须在第60秒以一次仓库事务把1棵树苗瞬间转为5份木头。"
	)


func _test_full_storage_retry(
	test_root: Node,
	config: PlantDefenseConfig,
	warehouse_config: PlantDefenseConfig
) -> void:
	var coordinator := COORDINATOR_SCENE.instantiate() as ProductionCoordinator
	var warehouse := WAREHOUSE_SCENE.instantiate() as OakWarehouse
	var planting_base := config.plant_scene.instantiate() as PlantingBase
	test_root.add_child(coordinator)
	test_root.add_child(warehouse)
	test_root.add_child(planting_base)
	await process_frame
	coordinator.production_tick_timer.stop()
	warehouse.setup(warehouse_config, null, [Vector2i(4, 0)])
	planting_base.setup(
		config,
		null,
		[
			Vector2i(5, 0),
			Vector2i(6, 0),
			Vector2i(5, 1),
			Vector2i(6, 1),
		]
	)

	var full_items: Array[PickupConfig] = []
	var full_counts: Array[int] = []
	full_items.resize(OakWarehouse.STORAGE_CAPACITY)
	full_counts.resize(OakWarehouse.STORAGE_CAPACITY)
	for slot_index in OakWarehouse.STORAGE_CAPACITY:
		full_items[slot_index] = SAPLING if slot_index == 0 else WOOD
		full_counts[slot_index] = 999
	_expect(
		warehouse.apply_production_storage_snapshot(
			full_items,
			full_counts,
			warehouse.get_storage_revision()
		),
		"满仓测试必须能准备1格999树苗与其余满木头栈。"
	)
	coordinator.register_plant(warehouse)
	coordinator.register_plant(planting_base)
	var storage_events: Array[int] = []
	warehouse.storage_changed.connect(
		func() -> void: storage_events.append(warehouse.get_storage_revision())
	)
	var before_snapshot := warehouse.export_production_storage_snapshot()
	var before_revision := warehouse.get_storage_revision()
	_expect(
		planting_base.select_recipe(&"sapling_propagation"),
		"满仓测试必须能选择同物品投入与产出的树苗繁育配方。"
	)
	planting_base.advance_shared_production_tick(30.0)
	var blocked_snapshot := warehouse.export_production_storage_snapshot()
	_expect(
		planting_base.completion_wait_reason
		== ProductionCoordinator.RESULT_STORAGE_FULL
		and is_equal_approx(planting_base.progress_elapsed_seconds, 30.0)
		and warehouse.get_storage_revision() == before_revision
		and blocked_snapshot["items"] == before_snapshot["items"]
		and blocked_snapshot["counts"] == before_snapshot["counts"]
		and storage_events.is_empty()
		and coordinator.get_total_item_count(SAPLING) == 999,
		"满仓时同物品配方也必须整轮零写入，不能先扣树苗再留下部分产物。"
	)
	_expect(
		warehouse.discard_storage_item(1)
		and coordinator.get_total_item_count(SAPLING) == 1000
		and is_zero_approx(planting_base.progress_elapsed_seconds)
		and planting_base.completion_wait_reason == &""
		and warehouse.get_storage_revision() == before_revision + 2
		and storage_events.size() == 2,
		"腾出一个仓库槽后，等待中的繁育轮次必须同帧重试并以第二次原子事务净增1棵树苗。"
	)


func _test_multiplayer_runtime_contract(
	test_root: Node,
	config: PlantDefenseConfig,
	authority: PlantingBase
) -> void:
	var exported_state := authority.export_multiplayer_runtime_state()
	_expect(
		int(exported_state.get("schema", 0))
		== ProductionBuilding.RUNTIME_STATE_SCHEMA
		and StringName(exported_state.get("active_recipe_id", ""))
		== &"sapling_to_wood"
		and int(exported_state.get("personal_output_peer_id", -1)) == 0,
		"种植基地权威runtime state必须复用通用生产schema并同步共享仓库配方ID。"
	)

	var proxy := config.plant_scene.instantiate() as PlantingBase
	test_root.add_child(proxy)
	await process_frame
	proxy.setup(
		config,
		null,
		[
			Vector2i(7, 0),
			Vector2i(8, 0),
			Vector2i(7, 1),
			Vector2i(8, 1),
		],
		true,
		config.max_health,
		1
	)
	proxy.configure_multiplayer_production(701, 2, true)
	var requested_commands: Array[Dictionary] = []
	proxy.production_command_requested.connect(
		func(command: Dictionary) -> void: requested_commands.append(command)
	)
	_expect(
		not proxy.select_recipe(&"sapling_to_wood")
		and proxy.active_recipe_id == &"",
		"种植基地客户端副本不得通过单人接口直接切换生产配方。"
	)
	proxy.advance_shared_production_tick(60.0)
	_expect(
		is_zero_approx(proxy.progress_elapsed_seconds),
		"种植基地客户端副本不得自行推进权威生产进度。"
	)
	_expect(
		proxy.request_multiplayer_recipe_selection(&"sapling_to_wood")
		and requested_commands.size() == 1
		and ProductionBuildingProtocol.get_operation(requested_commands[0])
		== ProductionBuildingProtocol.OPERATION_SELECT_RECIPE
		and int(requested_commands[0]["building_net_id"]) == 701
		and int(requested_commands[0]["peer_id"]) == 2
		and int(requested_commands[0]["expected_production_revision"]) == 0
		and StringName(requested_commands[0]["recipe_id"])
		== &"sapling_to_wood",
		"客户端必须用通用生产命令携带种植基地net_id、peer、revision与配方ID。"
	)

	var authoritative_state := exported_state.duplicate(true)
	authoritative_state["progress_elapsed_seconds"] = 12.5
	authoritative_state["revision"] = int(exported_state["revision"]) + 5
	authoritative_state["wait_reason"] = ""
	var sample_time := float(Time.get_ticks_msec()) / 1000.0
	proxy.apply_multiplayer_runtime_state(authoritative_state, sample_time)
	var result := ProductionBuildingProtocol.make_result(
		requested_commands[0],
		true,
		ProductionBuildingProtocol.RESULT_SUCCESS,
		int(authoritative_state["revision"]),
		authoritative_state,
		sample_time
	)
	_expect(
		proxy.complete_multiplayer_production_request(result)
		and proxy.active_recipe_id == &"sapling_to_wood"
		and is_equal_approx(proxy.progress_elapsed_seconds, 12.5)
		and proxy.production_revision == int(authoritative_state["revision"])
		and not proxy.multiplayer_production_request_pending,
		"种植基地客户端副本必须接受完整权威runtime state并结束对应请求。"
	)
	var stale_state := authoritative_state.duplicate(true)
	stale_state["revision"] = int(authoritative_state["revision"]) - 1
	stale_state["enabled"] = false
	proxy.apply_multiplayer_runtime_state(stale_state, sample_time)
	_expect(
		proxy.production_enabled
		and proxy.production_revision == int(authoritative_state["revision"]),
		"过期runtime state不得回滚种植基地客户端副本。"
	)
	proxy.multiplayer_production_request_timer.stop()


func _test_hud_follow_focus(
	test_root: Node,
	config: PlantDefenseConfig
) -> void:
	var hud := PLANT_SELECTION_HUD_SCENE.instantiate() as PlantSelectionHUD
	test_root.add_child(hud)
	await process_frame
	var card_scroll := hud.get_node_or_null(
		"Root/ScreenMargin/Content/Margin/Layout/CatalogScroll"
	) as ScrollContainer
	var configs := PlantDefenseRegistry.get_all_configs()
	var planting_base_index := configs.find(config)
	_expect(
		card_scroll != null
		and card_scroll.follow_focus
		and hud.open(configs)
		and configs.size() == 18
		and configs.has(PlantDefenseRegistry.get_config(&"excavator"))
		and configs.has(PlantDefenseRegistry.get_config(&"stone_mill"))
		and configs.has(PlantDefenseRegistry.get_config(&"simple_fence"))
		and configs.has(PlantDefenseRegistry.get_config(&"life_tower"))
		and configs.has(PlantDefenseRegistry.get_config(&"speed_tower"))
		and planting_base_index >= 0
		and hud.cards.size() == 18
		and hud.cards[planting_base_index].plant_config == config,
		"18张建筑卡必须包含生命、移速强化塔与既有正式建筑，外层目录须启用follow_focus。"
	)
	if card_scroll == null or not hud.is_open():
		return
	hud.call("_select_config", config)
	await process_frame
	await process_frame
	_expect(
		hud.selected_config == config
		and card_scroll.follow_focus,
		"切换到种植基地时，外层目录必须持续启用follow_focus。"
	)
	hud.close()


func _effective_z_index(item: CanvasItem) -> int:
	var effective_z := 0
	var current: CanvasItem = item
	while current != null:
		effective_z += current.z_index
		if not current.z_as_relative:
			break
		current = current.get_parent() as CanvasItem
	return effective_z


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
		push_error(message)


func _finish(test_root: Node) -> void:
	test_root.queue_free()
	await process_frame
	if failures.is_empty():
		print("PLANTING_BASE_SMOKE_TEST_OK")
		quit(0)
	else:
		print("PLANTING_BASE_SMOKE_TEST_FAILED: %d" % failures.size())
		quit(1)
