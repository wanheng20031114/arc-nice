extends SceneTree

# Bootstrap the complete gameplay type graph before standalone plant scenes.
const GAME_SCENE := preload("res://scene/game_modes/tower_defense/tower_defense_game.tscn")
const ORANGE_TOWER_SCENE := preload(
	"res://scene/plant_defense/orange_charging_tower.tscn"
)
const ORANGE_CONFIG := preload(
	"res://resources/config/plant_defense/orange_charging_tower.tres"
)
const AGAVE_CONFIG := preload(
	"res://resources/config/plant_defense/agave_cannon.tres"
)
const WOOD_STATION_SCENE := preload(
	"res://scene/plant_defense/wood_processing_station.tscn"
)
const WOOD_STATION_CONFIG := preload(
	"res://resources/config/plant_defense/wood_processing_station.tres"
)
const PLAYER_SCENE := preload(
	"res://scene/player/weishidaier/player_weishidaier.tscn"
)
const ENEMY_SCENE := preload("res://scene/enemy/enemy.tscn")
const LINGLAN_BOSS_SCENE := preload(
	"res://scene/boss/linglan/linglan_boss.tscn"
)
const BODY_TEXTURE := preload(
	"res://resources/texture/plant_defense/orange_charging_tower/body.png"
)
const ICON_TEXTURE := preload(
	"res://resources/texture/plant_defense/orange_charging_tower/icon.png"
)
const ORANGE_TEXTURE := preload(
	"res://resources/texture/plant_defense/orange_charging_tower/orange_layers_glow.png"
)
const GLASS_TEXTURE := preload(
	"res://resources/texture/plant_defense/orange_charging_tower/glass_cycle_glow.png"
)
const ORANGE_CYCLE_MATERIAL := preload(
	"res://resources/shader/orange_charging_tower_orange_cycle.tres"
)
const GLASS_CYCLE_MATERIAL := preload(
	"res://resources/shader/orange_charging_tower_glass_cycle.tres"
)
const CYCLE_SHADER := preload(
	"res://resources/shader/orange_charging_tower_cycle.gdshader"
)

const TILE_SIZE := Vector2i(16, 16)
const EXPECTED_SOURCE_SIZE := Vector2i(128, 128)
const EXPECTED_DISPLAY_SIZE := Vector2(32.0, 32.0)
const EXPECTED_VISUAL_SCALE := Vector2(0.25, 0.25)
const EXPECTED_AURA_RECT := Rect2i(9, 9, 4, 4)
const PLAYER_BONUS_PER_SOURCE := 0.5
const BUILDING_INTERVAL_MULTIPLIER := 0.8
const RENDER_SIZE := Vector2i(160, 160)
const RENDER_SPRITE_CENTER := Vector2(80.0, 80.0)
const SOURCE_TOP_LEFT := Vector2i(16, 16)
const EXPECTED_MIGRATED_BOTTOM_HIGHLIGHTS := 29
const SOURCE_LAYER_BANDS := [
	Vector2i(59, 69),
	Vector2i(49, 59),
	Vector2i(37, 49),
]
const GLASS_STRIP_BANDS := [
	Vector2i(61, 69),
	Vector2i(51, 59),
	Vector2i(40, 48),
]

var failures: Array[String] = []
var fixture: Node2D = null
var ground_tile_map: TileMapLayer = null
var plant_container: Node2D = null
var plant_system: PlantSystem = null
var aura_coordinator: OrangeChargingAuraCoordinator = null
var next_net_id := 700


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	root.size = Vector2i(320, 240)
	root.content_scale_size = root.size
	fixture = Node2D.new()
	fixture.name = "OrangeChargingTowerSmokeFixture"
	root.add_child(fixture)
	current_scene = fixture

	_setup_plant_fixture()
	await process_frame
	_test_config_scene_and_asset_contracts()
	await _test_player_exact_range_stacking_and_lifecycle()
	await _test_building_aura_index_and_cleanup()
	await _test_source_first_target_event_order()
	await _test_proxy_derived_player_state()
	await _test_cycle_shader_render_contract()

	fixture.queue_free()
	await process_frame
	current_scene = null
	if failures.is_empty():
		print("ORANGE_CHARGING_TOWER_SMOKE_TEST_OK")
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	quit(1)


func _setup_plant_fixture() -> void:
	ground_tile_map = TileMapLayer.new()
	ground_tile_map.name = "GroundTileMap"
	var tile_set := TileSet.new()
	tile_set.tile_size = TILE_SIZE
	ground_tile_map.tile_set = tile_set
	fixture.add_child(ground_tile_map)

	plant_container = Node2D.new()
	plant_container.name = "PlantContainer"
	fixture.add_child(plant_container)
	plant_system = PlantSystem.new()
	plant_system.name = "PlantSystem"
	fixture.add_child(plant_system)
	plant_system.setup(
		ground_tile_map,
		null,
		plant_container,
		Rect2i(-32, -32, 96, 96)
	)

	aura_coordinator = OrangeChargingAuraCoordinator.new()
	aura_coordinator.name = "OrangeChargingAuraCoordinator"
	var reconcile_timer := Timer.new()
	reconcile_timer.name = "ReconcileTimer"
	reconcile_timer.wait_time = 2.0
	aura_coordinator.add_child(reconcile_timer)
	fixture.add_child(aura_coordinator)
	aura_coordinator.setup(plant_system)


func _test_config_scene_and_asset_contracts() -> void:
	_expect(
		ORANGE_CONFIG is OrangeChargingTowerConfig
		and ORANGE_CONFIG.is_valid()
		and ORANGE_CONFIG.plant_id == &"orange_charging_tower"
		and ORANGE_CONFIG.footprint_size == Vector2i(2, 2)
		and ORANGE_CONFIG.max_health == 3000
		and ORANGE_CONFIG.physical_defense == 10
		and ORANGE_CONFIG.magic_defense == 20,
		"橘充能塔配置必须保持2×2、3000生命、10物防和20法防。"
	)
	_expect(
		ORANGE_CONFIG.building_category
		== PlantDefenseConfig.BuildingCategory.SUPPORT_TOWER
		and ORANGE_CONFIG.aura_margin_cells == 1
		and is_equal_approx(
			ORANGE_CONFIG.player_skill_charge_bonus_per_second,
			PLAYER_BONUS_PER_SOURCE
		)
		and is_equal_approx(
			ORANGE_CONFIG.defense_attack_interval_multiplier,
			BUILDING_INTERVAL_MULTIPLIER
		)
		and is_equal_approx(
			ORANGE_CONFIG.production_duration_multiplier,
			BUILDING_INTERVAL_MULTIPLIER
		),
		"橘充能塔的玩家与建筑气场数值必须与设计一致。"
	)

	var tower := _make_tower(_footprint(Vector2i(10, 10)))
	var visual_root := tower.get_node("VisualRoot") as Node2D
	var body := tower.get_node("VisualRoot/Body") as Sprite2D
	var lower_body_left := tower.get_node(
		"VisualRoot/LowerBodyLeft"
	) as Sprite2D
	var lower_body_right := tower.get_node(
		"VisualRoot/LowerBodyRight"
	) as Sprite2D
	var upper_chamber := tower.get_node(
		"VisualRoot/UpperChamber"
	) as Sprite2D
	var upper_chamber_rim := tower.get_node(
		"VisualRoot/UpperChamberRim"
	) as Sprite2D
	var orange_layers := tower.get_node(
		"VisualRoot/OrangeLayers"
	) as Sprite2D
	var glass_layers := tower.get_node(
		"VisualRoot/GlassCycleGlow"
	) as Sprite2D
	var aura_shape := tower.get_node(
		"PlayerAuraArea/CollisionShape2D"
	) as CollisionShape2D
	var aura_rectangle := aura_shape.shape as RectangleShape2D
	var ground_rings := tower.get_node("GroundRings") as GPUParticles2D
	var visibility_notifiers := tower.find_children(
		"*", "VisibleOnScreenNotifier2D", true, false
	)
	var night_light := tower.get_node(
		"ChamberNightLight"
	) as NightPointLight2D
	var lower_body_region := body.texture as AtlasTexture
	var lower_body_left_region := lower_body_left.texture as AtlasTexture
	var lower_body_right_region := lower_body_right.texture as AtlasTexture
	var upper_chamber_region := upper_chamber.texture as AtlasTexture
	var upper_chamber_rim_region := upper_chamber_rim.texture as AtlasTexture

	_expect(
		visual_root.scale.is_equal_approx(EXPECTED_VISUAL_SCALE)
		and Vector2(BODY_TEXTURE.get_size()) * visual_root.scale
		== EXPECTED_DISPLAY_SIZE
		and not visual_root.y_sort_enabled
		and body.texture_filter == CanvasItem.TEXTURE_FILTER_NEAREST
		and lower_body_left.texture_filter
		== CanvasItem.TEXTURE_FILTER_NEAREST
		and lower_body_right.texture_filter
		== CanvasItem.TEXTURE_FILTER_NEAREST
		and upper_chamber.texture_filter
		== CanvasItem.TEXTURE_FILTER_NEAREST
		and upper_chamber_rim.texture_filter
		== CanvasItem.TEXTURE_FILTER_NEAREST
		and orange_layers.texture_filter == CanvasItem.TEXTURE_FILTER_NEAREST
		and glass_layers.texture_filter == CanvasItem.TEXTURE_FILTER_NEAREST
		and body.centered
		and lower_body_left.centered
		and lower_body_right.centered
		and upper_chamber.centered
		and upper_chamber_rim.centered,
		"128×128主视觉必须仅通过0.25整数比例显示为32×32，并保持最近邻采样。"
	)
	_expect(
		lower_body_region != null
		and lower_body_left_region != null
		and lower_body_right_region != null
		and upper_chamber_region != null
		and upper_chamber_rim_region != null
		and lower_body_region.atlas == BODY_TEXTURE
		and lower_body_left_region.atlas == BODY_TEXTURE
		and lower_body_right_region.atlas == BODY_TEXTURE
		and upper_chamber_region.atlas == BODY_TEXTURE
		and upper_chamber_rim_region.atlas == BODY_TEXTURE
		and lower_body_region.region == Rect2(0, 80, 128, 48)
		and lower_body_left_region.region == Rect2(0, 74, 27, 6)
		and lower_body_right_region.region == Rect2(101, 74, 27, 6)
		and upper_chamber_region.region == Rect2(0, 0, 128, 74)
		and upper_chamber_rim_region.region == Rect2(27, 74, 74, 6)
		and body.offset == Vector2(0, 40)
		and lower_body_left.offset == Vector2(-50.5, 13)
		and lower_body_right.offset == Vector2(50.5, 13)
		and upper_chamber.offset == Vector2(0, -27)
		and upper_chamber_rim.offset == Vector2(0, 13)
		and body.position == Vector2.ZERO
		and lower_body_left.position == Vector2.ZERO
		and lower_body_right.position == Vector2.ZERO
		and upper_chamber.position == Vector2.ZERO
		and upper_chamber_rim.position == Vector2.ZERO
		and orange_layers.texture == ORANGE_TEXTURE
		and glass_layers.texture == GLASS_TEXTURE
		and orange_layers.position == Vector2.ZERO
		and glass_layers.position == Vector2.ZERO
		and orange_layers.offset == Vector2.ZERO
		and glass_layers.offset == Vector2.ZERO,
		"橘充能塔必须用无重叠互补Atlas保留圈外底座，并把蓝圈中央舱体无损复原到原坐标。"
	)
	var player_z_fixture := PLAYER_SCENE.instantiate()
	var enemy_z_fixture := ENEMY_SCENE.instantiate()
	var boss_z_fixture := LINGLAN_BOSS_SCENE.instantiate()
	var player_sprite := player_z_fixture.get_node_or_null(
		"BodySprite"
	) as CanvasItem
	var enemy_sprite := enemy_z_fixture.get_node_or_null(
		"AnimatedSprite2D"
	) as CanvasItem
	var boss_sprite := boss_z_fixture.get_node_or_null(
		"AnimatedSprite2D"
	) as CanvasItem
	_expect(
		player_sprite != null
		and _effective_z_index(player_sprite) == 1
		and enemy_sprite != null
		and _effective_z_index(enemy_sprite) == 2
		and boss_sprite != null
		and _effective_z_index(boss_sprite) == 3
		and _effective_z_index(body) == 1
		and _effective_z_index(lower_body_left) == 1
		and _effective_z_index(lower_body_right) == 1
		and _effective_z_index(upper_chamber) == 4
		and _effective_z_index(upper_chamber_rim) == 4
		and _effective_z_index(orange_layers) == 5
		and _effective_z_index(glass_layers) == 6,
		"橘充能塔必须严格保持玩家1 < 敌人2 < 首领3 < 蓝圈舱体4 < 橘片5 < 玻璃6。"
	)
	player_z_fixture.free()
	enemy_z_fixture.free()
	boss_z_fixture.free()
	for texture in [BODY_TEXTURE, ORANGE_TEXTURE, GLASS_TEXTURE]:
		_expect(
			texture.get_size() == Vector2(EXPECTED_SOURCE_SIZE),
			"塔身、橘片与玻璃责任贴图必须全部保持128×128源尺寸。"
		)
	var body_image := BODY_TEXTURE.get_image()
	var icon_image := ICON_TEXTURE.get_image()
	var orange_image := ORANGE_TEXTURE.get_image()
	var glass_image := GLASS_TEXTURE.get_image()
	var body_rect := body_image.get_used_rect()
	_expect(
		_count_visible_pixels(body_image, 0.01) > 1800
		and _count_visible_pixels(orange_image, 0.01) > 120
		and _count_visible_pixels(glass_image, 0.01) > 120
		and _count_visible_pixels(orange_image, 0.01)
		< _count_visible_pixels(body_image, 0.01)
		and _count_visible_pixels(glass_image, 0.01)
		< _count_visible_pixels(body_image, 0.01),
		"动画必须使用从单塔拆出的橘片/玻璃责任层，不能塞入多帧完整塔图。"
	)
	_expect(
		body_rect.size.y <= 106
		and body_rect.size.x >= body_rect.size.y
		and _count_visible_pixels_in_rect(
			glass_image,
			Rect2i(52, 35, 24, 34),
			0.01
		) > 400
		and _count_visible_pixels_in_rect(
			glass_image,
			Rect2i(34, 59, 61, 10),
			0.01
		) > 450,
		"三层定稿必须真正压低为宽体轮廓；两侧玻璃必须向中心延伸并完整覆盖最底层。"
	)
	var migrated_bottom_highlights := 0
	var migrated_bottom_contract_valid := true
	for y in range(64, 69):
		for x in range(48, 80):
			var source_color := icon_image.get_pixel(x, y)
			if not _is_baked_bottom_highlight_color(source_color):
				continue
			migrated_bottom_highlights += 1
			var body_color := body_image.get_pixel(x, y)
			var responsibility_color := orange_image.get_pixel(x, y)
			migrated_bottom_contract_valid = (
				migrated_bottom_contract_valid
				and responsibility_color.is_equal_approx(source_color)
				and body_color.a >= 0.99
				and body_color.get_luminance() <= 0.42
			)
	_expect(
		migrated_bottom_highlights
		== EXPECTED_MIGRATED_BOTTOM_HIGHLIGHTS
		and migrated_bottom_contract_valid,
		"最底层29个烘焙高光必须从常驻body迁入活动橘片，并补为同排暗态颜色。"
	)
	for source_band in SOURCE_LAYER_BANDS:
		_expect(
			_count_visible_pixels_in_rect(
				orange_image,
				Rect2i(28, source_band.x, 72, source_band.y - source_band.x),
				0.01
			) > 80,
			"每个橘片责任带都必须保留足够的128像素细节。"
		)
	_expect(
		tower.get_aura_cell_rect() == EXPECTED_AURA_RECT
		and aura_rectangle.size == Vector2(64.0, 64.0),
		"2×2本体向外扩一格后必须得到精确4×4格与64×64像素候选区域。"
	)
	_expect(
		ground_rings.amount == 8
		and ground_rings.lifetime <= 1.2
		and ground_rings.fixed_fps == 30
		and ground_rings.visibility_rect == Rect2(-40, -40, 80, 80)
		and ground_rings.process_mode == Node.PROCESS_MODE_INHERIT
		and ground_rings.local_coords,
		"常驻柑橘环粒子必须维持8粒子、30FPS与紧凑可见区域预算。"
	)
	_expect(
		visibility_notifiers.is_empty(),
		"橘充能塔粒子必须仅依赖原生visibility_rect，避免重复裁剪与进屏重启。"
	)
	_expect(
		night_light.color.is_equal_approx(Color(1.0, 0.42, 0.08, 1.0))
		and is_equal_approx(night_light.night_energy, 0.68)
		and is_equal_approx(night_light.texture_scale, 0.26)
		and not night_light.shadow_enabled,
		"夜间扩散光必须是低开销无阴影橘光，并保持审定强度与范围。"
	)
	_expect(
		tower.lifecycle_visual_paths.size() == 7
		and tower.lifecycle_visual_paths.has(NodePath("VisualRoot/Body"))
		and tower.lifecycle_visual_paths.has(
			NodePath("VisualRoot/LowerBodyLeft")
		)
		and tower.lifecycle_visual_paths.has(
			NodePath("VisualRoot/LowerBodyRight")
		)
		and tower.lifecycle_visual_paths.has(
			NodePath("VisualRoot/UpperChamber")
		)
		and tower.lifecycle_visual_paths.has(
			NodePath("VisualRoot/UpperChamberRim")
		)
		and tower.lifecycle_visual_paths.has(
			NodePath("VisualRoot/OrangeLayers")
		)
		and tower.lifecycle_visual_paths.has(
			NodePath("VisualRoot/GlassCycleGlow")
		)
		and body.material == lower_body_left.material
		and body.material == lower_body_right.material
		and body.material == upper_chamber.material
		and body.material == upper_chamber_rim.material,
		"互补塔身、前景舱体、橘片与玻璃层必须一起参加施工、受伤状态和拆除生命周期。"
	)
	tower.call("_set_lifecycle_parameter", &"construction_progress", 0.375)
	_expect(
		is_equal_approx(float(body.get_instance_shader_parameter(
			&"construction_progress"
		)), 0.375)
		and is_equal_approx(float(lower_body_left.get_instance_shader_parameter(
			&"construction_progress"
		)), 0.375)
		and is_equal_approx(float(lower_body_right.get_instance_shader_parameter(
			&"construction_progress"
		)), 0.375)
		and is_equal_approx(float(upper_chamber.get_instance_shader_parameter(
			&"construction_progress"
		)), 0.375)
		and is_equal_approx(float(upper_chamber_rim.get_instance_shader_parameter(
			&"construction_progress"
		)), 0.375)
		and is_equal_approx(float(orange_layers.get_instance_shader_parameter(
			&"construction_progress"
		)), 0.375)
		and is_equal_approx(float(glass_layers.get_instance_shader_parameter(
			&"construction_progress"
		)), 0.375),
		"后层、蓝圈前景与动态责任层必须同步接收同一生命周期进度。"
	)
	tower.call("_set_lifecycle_parameter", &"construction_progress", 1.0)
	tower.queue_free()


func _test_player_exact_range_stacking_and_lifecycle() -> void:
	var player := await _make_player()
	var source_a := _make_tower(_footprint(Vector2i(10, 10)))
	var source_b := _make_tower(_footprint(Vector2i(12, 10)))
	_expect(
		source_a.get_support_source_id() != source_b.get_support_source_id(),
		"不同橘充能塔必须生成不同的玩家技力来源ID。"
	)

	_set_player_cell(player, Vector2i(11, 10))
	source_a.call("_on_player_aura_body_entered", player)
	source_b.call("_on_player_aura_body_entered", player)
	_expect(
		is_equal_approx(player.get_skill_charge_rate_modifier_total(), 1.0),
		"两座重叠橘充能塔必须按来源为玩家叠加到每秒额外1.0技力。"
	)
	source_a.call("_on_player_aura_body_entered", player)
	_expect(
		is_equal_approx(player.get_skill_charge_rate_modifier_total(), 1.0),
		"同一座塔重复收到进入事件时不得重复叠加玩家技力。"
	)

	source_b.call("_on_player_aura_body_exited", player)
	_set_player_cell(player, Vector2i(12, 12))
	source_a.call("_reconcile_player_candidates")
	_expect(
		is_equal_approx(
			player.get_skill_charge_rate_modifier_total(),
			PLAYER_BONUS_PER_SOURCE
		),
		"4×4区域右下角(12,12)必须仍属于精确气场范围。"
	)
	_set_player_cell(player, Vector2i(13, 12))
	source_a.call("_reconcile_player_candidates")
	_expect(
		is_zero_approx(player.get_skill_charge_rate_modifier_total()),
		"右边界外第一格(13,12)必须立即移除玩家技力来源。"
	)
	_set_player_cell(player, Vector2i(9, 9))
	source_a.call("_reconcile_player_candidates")
	_expect(
		is_equal_approx(
			player.get_skill_charge_rate_modifier_total(),
			PLAYER_BONUS_PER_SOURCE
		),
		"4×4区域左上角(9,9)必须属于精确气场范围。"
	)
	_set_player_cell(player, Vector2i(8, 9))
	source_a.call("_reconcile_player_candidates")
	_expect(
		is_zero_approx(player.get_skill_charge_rate_modifier_total()),
		"左边界外第一格(8,9)必须立即移除玩家技力来源。"
	)

	var constructing := _make_tower(
		_footprint(Vector2i(20, 20)),
		true,
		false
	)
	_set_player_cell(player, Vector2i(20, 20))
	constructing.call("_on_player_aura_body_entered", player)
	_expect(
		not constructing.is_operational
		and is_zero_approx(player.get_skill_charge_rate_modifier_total()),
		"施工中的橘充能塔不得提前为玩家充能。"
	)
	constructing.call("_stop_construction_tween")
	constructing.call("_finish_construction", false)
	_expect(
		constructing.is_operational
		and is_equal_approx(
			player.get_skill_charge_rate_modifier_total(),
			PLAYER_BONUS_PER_SOURCE
		),
		"施工完成时必须用既有候选玩家立即建立充能来源。"
	)
	constructing.begin_removal(PlantDefense.RemovalMode.ANIMATED)
	_expect(
		is_zero_approx(player.get_skill_charge_rate_modifier_total())
		and constructing.get_node("PlayerReconcileTimer").is_stopped()
		and not constructing.ground_rings.emitting
		and constructing.ground_rings.process_mode == Node.PROCESS_MODE_INHERIT
		and not constructing.chamber_night_light.is_emission_allowed(),
		"拆除开始必须同步清理玩家来源、确认计时、粒子与夜灯。"
	)

	source_a.call("_on_player_aura_body_exited", player)
	source_a.queue_free()
	source_b.queue_free()
	constructing.queue_free()
	player.queue_free()
	await process_frame


func _test_building_aura_index_and_cleanup() -> void:
	var defense_inside := PlantDefense.new()
	defense_inside.name = "DefenseInside"
	plant_container.add_child(defense_inside)
	var defense_cells := _footprint(Vector2i(12, 12))
	defense_inside.setup(AGAVE_CONFIG, null, defense_cells)
	_register_fixture_plant(defense_inside, defense_cells)

	var defense_outside := PlantDefense.new()
	defense_outside.name = "DefenseOutside"
	plant_container.add_child(defense_outside)
	var outside_cells := _footprint(Vector2i(15, 12))
	defense_outside.setup(AGAVE_CONFIG, null, outside_cells)
	_register_fixture_plant(defense_outside, outside_cells)

	var production := WOOD_STATION_SCENE.instantiate() as ProductionBuilding
	production.name = "ProductionInside"
	plant_container.add_child(production)
	var production_cells := _footprint(Vector2i(10, 12))
	production.setup(WOOD_STATION_CONFIG, null, production_cells)
	_register_fixture_plant(production, production_cells)

	var source_a := _make_tower(_footprint(Vector2i(10, 10)))
	var source_b := _make_tower(_footprint(Vector2i(12, 10)))
	_register_fixture_plant(source_a, source_a.footprint_cells)
	_register_fixture_plant(source_b, source_b.footprint_cells)
	var source_a_id := source_a.get_support_source_id()
	var source_b_id := source_b.get_support_source_id()

	_expect(
		aura_coordinator.get_registered_source_count() == 2
		and aura_coordinator.get_source_ids_at_cell(Vector2i(11, 10)).size()
		== 2
		and is_equal_approx(
			defense_inside.get_attack_interval_multiplier(),
			BUILDING_INTERVAL_MULTIPLIER
		)
		and is_equal_approx(
			production.get_production_duration_multiplier(),
			BUILDING_INTERVAL_MULTIPLIER
		),
		"双塔重叠时格索引必须保留两个来源，但防御与生产倍率只能取一次0.8。"
	)
	_expect(
		defense_inside.attack_interval_multiplier_modifiers.size() == 2
		and production.production_duration_multiplier_modifiers.size() == 2,
		"建筑必须分别记住两个来源，以便单塔移除后继续维持不可叠加加速。"
	)
	_expect(
		is_equal_approx(defense_outside.get_attack_interval_multiplier(), 1.0)
		and not defense_outside.attack_interval_multiplier_modifiers.has(
			source_a_id
		)
		and not defense_outside.attack_interval_multiplier_modifiers.has(
			source_b_id
		),
		"与4×4矩形没有任一占地格相交的建筑不得收到气场。"
	)

	_unregister_fixture_plant(source_a)
	_expect(
		aura_coordinator.get_registered_source_count() == 1
		and is_equal_approx(
			defense_inside.get_attack_interval_multiplier(),
			BUILDING_INTERVAL_MULTIPLIER
		)
		and is_equal_approx(
			production.get_production_duration_multiplier(),
			BUILDING_INTERVAL_MULTIPLIER
		)
		and not defense_inside.attack_interval_multiplier_modifiers.has(
			source_a_id
		)
		and defense_inside.attack_interval_multiplier_modifiers.has(source_b_id),
		"移除一个重叠来源时必须只清该来源，另一座塔仍维持0.8效果。"
	)
	_unregister_fixture_plant(source_b)
	_expect(
		aura_coordinator.get_registered_source_count() == 0
		and is_equal_approx(defense_inside.get_attack_interval_multiplier(), 1.0)
		and is_equal_approx(production.get_production_duration_multiplier(), 1.0)
		and aura_coordinator.get_source_ids_at_cell(Vector2i(11, 10)).is_empty(),
		"最后一个来源移除后必须恢复建筑原速并清空格索引。"
	)

	var constructing := _make_tower(
		_footprint(Vector2i(10, 10)),
		true,
		false
	)
	_register_fixture_plant(constructing, constructing.footprint_cells)
	_expect(
		aura_coordinator.get_registered_source_count() == 0
		and aura_coordinator.pending_sources.has(constructing)
		and is_equal_approx(defense_inside.get_attack_interval_multiplier(), 1.0),
		"施工中的来源必须只进入待激活集合，不能提前加速建筑。"
	)
	constructing.call("_stop_construction_tween")
	constructing.call("_finish_construction", false)
	_expect(
		aura_coordinator.get_registered_source_count() == 1
		and not aura_coordinator.pending_sources.has(constructing)
		and is_equal_approx(
			defense_inside.get_attack_interval_multiplier(),
			BUILDING_INTERVAL_MULTIPLIER
		),
		"施工完成信号必须把来源原子地注册进气场索引。"
	)
	constructing.begin_removal(PlantDefense.RemovalMode.ANIMATED)
	_unregister_fixture_plant(constructing)
	_expect(
		aura_coordinator.get_registered_source_count() == 0
		and is_equal_approx(defense_inside.get_attack_interval_multiplier(), 1.0),
		"来源进入销毁期并从PlantSystem释放时必须立即清除建筑倍率。"
	)

	for plant in [
		defense_inside,
		defense_outside,
		production,
		source_a,
		source_b,
		constructing,
	]:
		_unregister_fixture_plant(plant)
		if is_instance_valid(plant):
			plant.queue_free()
	await process_frame


func _test_source_first_target_event_order() -> void:
	var source := _make_tower(_footprint(Vector2i(30, 30)))
	_register_fixture_plant(source, source.footprint_cells)
	var source_id := source.get_support_source_id()

	var late_defense := PlantDefense.new()
	late_defense.name = "LateDefense"
	plant_container.add_child(late_defense)
	var defense_cells := _footprint(Vector2i(31, 31))
	late_defense.setup(AGAVE_CONFIG, null, defense_cells)
	_register_fixture_plant(late_defense, defense_cells)

	var late_production := WOOD_STATION_SCENE.instantiate() as ProductionBuilding
	late_production.name = "LateProduction"
	plant_container.add_child(late_production)
	var production_cells := _footprint(Vector2i(29, 31))
	late_production.setup(WOOD_STATION_CONFIG, null, production_cells)
	_register_fixture_plant(late_production, production_cells)

	var tracked_targets: Dictionary = aura_coordinator.source_targets.get(
		source_id,
		{}
	)
	_expect(
		is_equal_approx(
			late_defense.get_attack_interval_multiplier(),
			BUILDING_INTERVAL_MULTIPLIER
		)
		and is_equal_approx(
			late_production.get_production_duration_multiplier(),
			BUILDING_INTERVAL_MULTIPLIER
		)
		and tracked_targets.has(late_defense)
		and tracked_targets.has(late_production),
		"来源先放置时，后续建筑必须仅凭plant_placed事件立即接入既有4×4格索引。"
	)

	_unregister_fixture_plant(late_defense)
	_unregister_fixture_plant(late_production)
	tracked_targets = aura_coordinator.source_targets.get(source_id, {})
	_expect(
		is_equal_approx(late_defense.get_attack_interval_multiplier(), 1.0)
		and is_equal_approx(
			late_production.get_production_duration_multiplier(),
			1.0
		)
		and not tracked_targets.has(late_defense)
		and not tracked_targets.has(late_production),
		"目标单独移除时必须立即清理来源反向索引和全部倍率。"
	)

	_unregister_fixture_plant(source)
	for plant in [late_defense, late_production, source]:
		if is_instance_valid(plant):
			plant.queue_free()
	await process_frame


func _test_proxy_derived_player_state() -> void:
	var local_player := await _make_player()
	local_player.uses_local_input = true
	var remote_player := await _make_player()
	remote_player.uses_local_input = false
	var proxy := _make_tower(
		_footprint(Vector2i(24, 24)),
		false,
		true,
		9123
	)
	_set_player_cell(local_player, Vector2i(24, 24))
	_set_player_cell(remote_player, Vector2i(24, 24))
	proxy.call("_on_player_aura_body_entered", local_player)
	proxy.call("_on_player_aura_body_entered", remote_player)
	_expect(
		proxy.is_multiplayer_proxy
		and proxy.get_support_source_id()
		== OrangeChargingTower.PLAYER_CHARGE_SOURCE_NAMESPACE + 9123
		and is_equal_approx(
			local_player.get_skill_charge_rate_modifier_total(),
			PLAYER_BONUS_PER_SOURCE
		)
		and is_equal_approx(
			remote_player.get_skill_charge_rate_modifier_total(),
			PLAYER_BONUS_PER_SOURCE
		),
		"多人代理必须由稳定net_id派生同一气场，并覆盖本地预测玩家与主机侧远端玩家。"
	)
	proxy.begin_removal(PlantDefense.RemovalMode.ANIMATED)
	_expect(
		is_zero_approx(local_player.get_skill_charge_rate_modifier_total())
		and is_zero_approx(remote_player.get_skill_charge_rate_modifier_total()),
		"多人代理移除时也必须清理所有派生玩家来源，不能等待网络快照兜底。"
	)
	proxy.queue_free()
	local_player.queue_free()
	remote_player.queue_free()
	await process_frame


func _test_cycle_shader_render_contract() -> void:
	var shader_code := CYCLE_SHADER.code
	_expect(
		shader_code.contains("LAYER_SECONDS * 3.0")
		and shader_code.contains(
			"active_layer = floor(sequence_time / LAYER_SECONDS)"
		)
		and shader_code.contains("cycle_time_override_seconds >= 0.0")
		and shader_code.contains("0.16 + glass_layer_match * 0.84")
		and shader_code.contains("smoothstep(0.56, 0.78")
		and shader_code.contains(
			"result.a *= clamp(visible_strength, 0.0, 1.0)"
		),
		"三层shader必须使用单一活动层、0.78后的严格黑场与零alpha关闭契约。"
	)
	_expect(
		shader_code.contains("float glass_bent_band_mask(vec2 local_position)")
		and shader_code.contains(
			"vec2(-27.0, -12.0)"
		)
		and shader_code.contains(
			"vec2(-9.0, -3.0)"
		)
		and shader_code.contains(
			"vec2(-12.0, 4.0)"
		)
		and shader_code.contains(
			"vec2(-30.0, -5.0)"
		)
		and shader_code.contains(
			"authored_glass_layer_from_position(pixel_position)"
		)
		and shader_code.contains(
			"pixel_position - vec2(64.0, 64.0)"
		)
		and shader_code.contains(
			"pixel_position - vec2(64.0, 54.0)"
		)
		and shader_code.contains(
			"pixel_position - vec2(64.0, 43.0)"
		)
		and shader_code.contains(
			"authored_layer_from_y(pixel_position.y)"
		)
		and shader_code.contains(
			"0.16 + glass_layer_match * 0.84"
		),
		"玻璃强光必须由中央水平段与两侧斜矩形连续斜切相接，且不得扭曲橘片原像素。"
	)
	_expect(
		_glass_bent_band_contains(Vector2(64.0, 64.0), 64.0)
		and _glass_bent_band_contains(Vector2(44.5, 60.0), 64.0)
		and _glass_bent_band_contains(Vector2(35.5, 57.5), 64.0)
		and _glass_bent_band_contains(Vector2(83.5, 60.0), 64.0)
		and _glass_bent_band_contains(Vector2(92.5, 57.5), 64.0)
		and not _glass_bent_band_contains(Vector2(44.5, 65.0), 64.0)
		and not _glass_bent_band_contains(Vector2(83.5, 65.0), 64.0),
		"玻璃折带必须保持中央水平、左右1:2连续斜臂及斜切接缝，旧水平肩部不得仍属强光。"
	)
	_expect(
		_glass_layer_at(Vector2(64.0, 44.0)) == 2
		and _glass_layer_at(Vector2(44.5, 39.0)) == 2
		and _glass_layer_at(Vector2(64.0, 55.0)) == 1
		and _glass_layer_at(Vector2(44.5, 50.0)) == 1
		and _glass_layer_at(Vector2(64.0, 65.0)) == 0
		and _glass_layer_at(Vector2(44.5, 60.0)) == 0
		and _glass_layer_at(Vector2(44.5, 65.0)) == -8,
		"三道玻璃强光必须表达同一空间高度：中央水平、两侧连续斜升，而不是错层矩形。"
	)
	var rendering_driver := RenderingServer.get_current_rendering_driver_name()
	if (
		DisplayServer.get_name() == "headless"
		or rendering_driver.is_empty()
		or rendering_driver == "dummy"
	):
		print(
			"ORANGE_CYCLE_RENDER_SKIPPED: headless/dummy renderer; "
			+ "static shader and source-alpha contracts passed."
		)
		return
	var viewport := SubViewport.new()
	viewport.name = "OrangeCycleRenderViewport"
	viewport.size = RENDER_SIZE
	viewport.disable_3d = true
	viewport.transparent_bg = true
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	root.add_child(viewport)
	var sprite := Sprite2D.new()
	sprite.position = RENDER_SPRITE_CENTER
	sprite.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	sprite.texture = ORANGE_TEXTURE
	sprite.material = ORANGE_CYCLE_MATERIAL.duplicate()
	viewport.add_child(sprite)

	var orange_rendered := await _verify_rendered_responsibility_cycle(
		sprite,
		viewport,
		"橘片",
		0.18
	)
	if orange_rendered:
		sprite.texture = GLASS_TEXTURE
		sprite.material = GLASS_CYCLE_MATERIAL.duplicate()
		await _verify_rendered_responsibility_cycle(
			sprite,
			viewport,
			"玻璃",
			0.35
		)

	viewport.queue_free()
	await process_frame


func _cross_2d(first: Vector2, second: Vector2) -> float:
	return first.x * second.y - first.y * second.x


func _inside_ccw_quad(
	point: Vector2,
	corner_a: Vector2,
	corner_b: Vector2,
	corner_c: Vector2,
	corner_d: Vector2
) -> bool:
	return (
		_cross_2d(corner_b - corner_a, point - corner_a) >= 0.0
		and _cross_2d(corner_c - corner_b, point - corner_b) >= 0.0
		and _cross_2d(corner_d - corner_c, point - corner_c) >= 0.0
		and _cross_2d(corner_a - corner_d, point - corner_d) >= 0.0
	)


func _glass_bent_band_contains(
	pixel_position: Vector2,
	center_y: float
) -> bool:
	var local_position := pixel_position - Vector2(64.0, center_y)
	var left_arm := _inside_ccw_quad(
		local_position,
		Vector2(-27.0, -12.0),
		Vector2(-9.0, -3.0),
		Vector2(-12.0, 4.0),
		Vector2(-30.0, -5.0)
	)
	var center := (
		local_position.x >= -12.0
		and local_position.x <= 12.0
		and local_position.y >= -3.0
		and local_position.y <= 4.0
	)
	var right_arm := _inside_ccw_quad(
		local_position,
		Vector2(9.0, -3.0),
		Vector2(27.0, -12.0),
		Vector2(30.0, -5.0),
		Vector2(12.0, 4.0)
	)
	return left_arm or center or right_arm


func _glass_layer_at(pixel_position: Vector2) -> int:
	var center_heights: Array[float] = [64.0, 54.0, 43.0]
	for layer_index in center_heights.size():
		if _glass_bent_band_contains(
			pixel_position,
			center_heights[layer_index]
		):
			return layer_index
	return -8


func _verify_rendered_responsibility_cycle(
	sprite: Sprite2D,
	viewport: SubViewport,
	role_name: String,
	maximum_other_delta_ratio: float
) -> bool:
	var black_frame := await _capture_cycle_phase(sprite, viewport, 0.79)
	var active_frames: Array[Image] = []
	for layer_index in 3:
		active_frames.append(
			await _capture_cycle_phase(
				sprite,
				viewport,
				float(layer_index) * 0.8 + 0.30
			)
		)
	var render_readback_available := (
		black_frame != null
		and not black_frame.is_empty()
		and active_frames.size() == 3
	)
	for active_image in active_frames:
		render_readback_available = (
			render_readback_available
			and active_image != null
			and not active_image.is_empty()
		)
	if not render_readback_available:
		print(
			"ORANGE_CYCLE_RENDER_SKIPPED: %s viewport readback unavailable; "
			% role_name
			+ "static shader and source-alpha contracts passed."
		)
		return false
	var black_visible := _count_visible_pixels(black_frame, 0.01)
	_expect(
		black_visible == 0,
		"%s责任层的0.79相位必须是严格透明黑场，当前仍有%d个可见像素。"
		% [role_name, black_visible]
	)
	for layer_index in 3:
		var active_image := active_frames[layer_index]
		var role_layer_band: Vector2i = (
			GLASS_STRIP_BANDS[layer_index]
			if role_name == "玻璃"
			else SOURCE_LAYER_BANDS[layer_index]
		)
		var own_delta := (
			_maximum_center_glass_band_luminance_delta(
				active_image,
				black_frame,
				role_layer_band
			)
			if role_name == "玻璃"
			else _maximum_band_luminance_delta(
				active_image,
				black_frame,
				SOURCE_LAYER_BANDS[layer_index]
			)
		)
		var strongest_other_delta := 0.0
		for other_index in 3:
			if other_index == layer_index:
				continue
			var other_role_layer_band: Vector2i = (
				GLASS_STRIP_BANDS[other_index]
				if role_name == "玻璃"
				else SOURCE_LAYER_BANDS[other_index]
			)
			strongest_other_delta = maxf(
				strongest_other_delta,
				(
					_maximum_center_glass_band_luminance_delta(
						active_image,
						black_frame,
						other_role_layer_band
					)
					if role_name == "玻璃"
					else _maximum_band_luminance_delta(
						active_image,
						black_frame,
						SOURCE_LAYER_BANDS[other_index]
					)
				)
			)
		_expect(
			own_delta >= 0.08
			and strongest_other_delta
			<= own_delta * maximum_other_delta_ratio,
			"%s激活第%d层时必须以该层为主发亮（自身%.3f，其他%.3f）。"
			% [role_name, layer_index + 1, own_delta, strongest_other_delta]
		)
		_expect(
			active_image.get_pixel(0, 0).a <= 0.001
			and active_image.get_pixel(159, 159).a <= 0.001,
			"%s真实shader渲染不得把透明角落扩成矩形色带。" % role_name
		)
	if role_name == "玻璃":
		_verify_rendered_glass_bent_bands(active_frames)
	return true


func _verify_rendered_glass_bent_bands(
	active_frames: Array[Image]
) -> void:
	var outer_rows: Array[int] = [58, 48, 37]
	var middle_rows: Array[int] = [60, 50, 39]
	var flat_rows: Array[int] = [65, 55, 44]
	for layer_index in 3:
		var active_image := active_frames[layer_index]
		var left_outer_alpha := _source_alpha(
			active_image,
			Vector2i(35, outer_rows[layer_index])
		)
		var right_outer_alpha := _source_alpha(
			active_image,
			Vector2i(93, outer_rows[layer_index])
		)
		var outer_alpha := (left_outer_alpha + right_outer_alpha) * 0.5
		var left_middle_alpha := _source_alpha(
			active_image,
			Vector2i(44, middle_rows[layer_index])
		)
		var right_middle_alpha := _source_alpha(
			active_image,
			Vector2i(84, middle_rows[layer_index])
		)
		var middle_alpha := (
			left_middle_alpha + right_middle_alpha
		) * 0.5
		var old_horizontal_alpha := (
			_source_alpha(
				active_image,
				Vector2i(44, flat_rows[layer_index])
			)
			+ _source_alpha(
				active_image,
				Vector2i(84, flat_rows[layer_index])
			)
		) * 0.5
		var flat_inner_alpha := (
			_source_alpha(
				active_image,
				Vector2i(58, flat_rows[layer_index])
			)
			+ _source_alpha(
				active_image,
				Vector2i(70, flat_rows[layer_index])
			)
		) * 0.5
		_expect(
			outer_alpha >= old_horizontal_alpha + 0.15
			and middle_alpha >= old_horizontal_alpha + 0.15
			and flat_inner_alpha >= 0.20
			and absf(left_outer_alpha - right_outer_alpha) <= 0.05,
			(
				"玻璃第%d层必须真实渲染为中央平直、左右斜臂连续的强光带"
				+ "（外端%.3f，中段%.3f，旧水平位%.3f，平段%.3f）。"
			)
			% [
				layer_index + 1,
				outer_alpha,
				middle_alpha,
				old_horizontal_alpha,
				flat_inner_alpha,
			]
		)


func _capture_cycle_phase(
	sprite: Sprite2D,
	viewport: SubViewport,
	sequence_seconds: float
) -> Image:
	sprite.set_instance_shader_parameter(
		&"cycle_time_override_seconds",
		sequence_seconds
	)
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	await process_frame
	RenderingServer.force_draw(true, 0.0)
	var viewport_texture := viewport.get_texture()
	if viewport_texture == null:
		return Image.new()
	var image := viewport_texture.get_image()
	return image if image != null else Image.new()


func _make_tower(
	cells: Array[Vector2i],
	play_placement_effect: bool = false,
	as_multiplayer_proxy: bool = false,
	explicit_net_id: int = 0
) -> OrangeChargingTower:
	var tower := ORANGE_TOWER_SCENE.instantiate() as OrangeChargingTower
	var net_id := explicit_net_id
	if net_id <= 0:
		next_net_id += 1
		net_id = next_net_id
	tower.set_meta(&"net_id", net_id)
	plant_container.add_child(tower)
	tower.global_position = _anchor_world_position(cells)
	tower.setup(
		ORANGE_CONFIG,
		null,
		cells,
		as_multiplayer_proxy,
		-1,
		0,
		-1,
		play_placement_effect
	)
	tower.set_ground_tile_map(ground_tile_map)
	return tower


func _make_player() -> Player:
	var run_state := root.get_node("RunState") as RunStateStore
	run_state.begin_new_run(&"weishidaier", false)
	var player := PLAYER_SCENE.instantiate() as Player
	fixture.add_child(player)
	await process_frame
	player.set_physics_process(false)
	player.set_process_input(false)
	player.set_process_unhandled_input(false)
	_stop_audio_players(player)
	return player


func _set_player_cell(player: Player, cell: Vector2i) -> void:
	player.global_position = ground_tile_map.to_global(
		ground_tile_map.map_to_local(cell)
	)


func _anchor_world_position(cells: Array[Vector2i]) -> Vector2:
	var first_center := ground_tile_map.to_global(
		ground_tile_map.map_to_local(cells[0])
	)
	var last_center := ground_tile_map.to_global(
		ground_tile_map.map_to_local(cells[cells.size() - 1])
	)
	return (first_center + last_center) * 0.5


func _footprint(top_left: Vector2i) -> Array[Vector2i]:
	return [
		top_left,
		top_left + Vector2i.RIGHT,
		top_left + Vector2i.DOWN,
		top_left + Vector2i.ONE,
	]


func _register_fixture_plant(
	plant: PlantDefense,
	cells: Array[Vector2i]
) -> void:
	plant_system.plant_footprints[plant] = cells.duplicate()
	for cell in cells:
		plant_system.occupied_cells[cell] = plant
	plant_system.plant_placed.emit(plant)


func _unregister_fixture_plant(plant: PlantDefense) -> void:
	if plant == null or not plant_system.plant_footprints.has(plant):
		return
	var cells: Array = plant_system.plant_footprints[plant]
	plant_system.plant_footprints.erase(plant)
	for cell_variant in cells:
		var cell := cell_variant as Vector2i
		if plant_system.occupied_cells.get(cell) == plant:
			plant_system.occupied_cells.erase(cell)
	plant_system.plant_removed.emit(plant)


func _count_visible_pixels(image: Image, alpha_threshold: float) -> int:
	if image == null or image.is_empty():
		return 0
	var count := 0
	for y in image.get_height():
		for x in image.get_width():
			if image.get_pixel(x, y).a > alpha_threshold:
				count += 1
	return count


func _count_visible_pixels_in_rect(
	image: Image,
	rect: Rect2i,
	alpha_threshold: float
) -> int:
	if image == null or image.is_empty():
		return 0
	var clipped := rect.intersection(Rect2i(Vector2i.ZERO, image.get_size()))
	var count := 0
	for y in range(clipped.position.y, clipped.end.y):
		for x in range(clipped.position.x, clipped.end.x):
			if image.get_pixel(x, y).a > alpha_threshold:
				count += 1
	return count


func _is_pipeline_orange_color(color: Color) -> bool:
	var red := roundi(color.r * 255.0)
	var green := roundi(color.g * 255.0)
	var blue := roundi(color.b * 255.0)
	return (
		color.a > 0.0
		and red >= 82
		and float(red) >= float(green) * 1.18
		and float(green) >= float(blue) * 0.95
		and red - blue >= 34
	)


func _is_baked_bottom_highlight_color(color: Color) -> bool:
	var red := roundi(color.r * 255.0)
	var green := roundi(color.g * 255.0)
	var blue := roundi(color.b * 255.0)
	return (
		not _is_pipeline_orange_color(color)
		and color.a > 0.0
		and red >= 240
		and green >= 210
		and blue <= 135
	)


func _maximum_band_luminance_delta(
	active_image: Image,
	black_image: Image,
	source_y_band: Vector2i
) -> float:
	var maximum_delta := 0.0
	var x_start := SOURCE_TOP_LEFT.x + 35
	var x_end := SOURCE_TOP_LEFT.x + 94
	var y_start := SOURCE_TOP_LEFT.y + source_y_band.x
	var y_end := SOURCE_TOP_LEFT.y + source_y_band.y
	for y in range(y_start, y_end):
		for x in range(x_start, x_end):
			maximum_delta = maxf(
				maximum_delta,
				active_image.get_pixel(x, y).get_luminance()
				- black_image.get_pixel(x, y).get_luminance()
			)
	return maximum_delta


func _maximum_center_glass_band_luminance_delta(
	active_image: Image,
	black_image: Image,
	source_y_band: Vector2i
) -> float:
	var maximum_delta := 0.0
	var center_x_ranges: Array[Vector2i] = [
		Vector2i(56, 60),
		Vector2i(69, 73),
	]
	var y_start := SOURCE_TOP_LEFT.y + source_y_band.x
	var y_end := SOURCE_TOP_LEFT.y + source_y_band.y
	for source_x_range in center_x_ranges:
		var x_start := SOURCE_TOP_LEFT.x + source_x_range.x
		var x_end := SOURCE_TOP_LEFT.x + source_x_range.y
		for y in range(y_start, y_end):
			for x in range(x_start, x_end):
				maximum_delta = maxf(
					maximum_delta,
					active_image.get_pixel(x, y).get_luminance()
					- black_image.get_pixel(x, y).get_luminance()
				)
	return maximum_delta


func _source_alpha(image: Image, source_position: Vector2i) -> float:
	return image.get_pixelv(SOURCE_TOP_LEFT + source_position).a


func _effective_z_index(item: CanvasItem) -> int:
	var effective_z := 0
	var current: CanvasItem = item
	while current != null:
		effective_z += current.z_index
		if not current.z_as_relative:
			break
		current = current.get_parent() as CanvasItem
	return effective_z


func _stop_audio_players(node: Node) -> void:
	if node is AudioStreamPlayer:
		(node as AudioStreamPlayer).stop()
	elif node is AudioStreamPlayer2D:
		(node as AudioStreamPlayer2D).stop()
	for child in node.get_children():
		_stop_audio_players(child)


func _expect(condition: bool, message: String) -> void:
	if condition:
		return
	failures.append(message)
	push_error(message)
