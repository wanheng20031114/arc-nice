extends SceneTree

const TOWER_SCENE := preload("res://scene/game_tower_defense.tscn")
const PLAYER_SCENE := preload("res://scene/player/weishidaier/player_weishidaier.tscn")
const TIYI_SCENE := preload("res://scene/player/tiyi/player_tiyi.tscn")
const HOE_CAT_SCENE := preload("res://scene/player/hoe_cat/player_hoe_cat.tscn")
const PLANT_SYSTEM_SCRIPT := preload("res://scene/plant_defense/plant_system.gd")
const PLACEMENT_CONTROLLER_SCENE := preload(
	"res://scene/plant_defense/plant_placement_controller.tscn"
)
const CANNONBALL_SCENE := preload("res://scene/plant_defense/agave_cannonball.tscn")
const PLANT_HEALTH_BAR_SCRIPT := preload("res://scene/plant_defense/ui/plant_health_bar.gd")
const ENEMY_CONFIG := preload("res://resources/config/enemies/yuanshi_insect_basic.tres")
const PLANT_VISUAL_PIXEL_SNAP_SHADER := preload(
	"res://resources/shader/plant_visual_pixel_snap.gdshader"
)
const PLANT_LIFECYCLE_SHADER := preload(
	"res://resources/shader/plant_lifecycle.gdshader"
)

var failures: Array[String] = []
var test_root: Node2D
var tile_map: TileMapLayer
var player: Player
var plant_system: PlantSystem
var plant_container: Node2D
var agave_config: PlantDefenseConfig
var corn_config: PlantDefenseConfig
var vegetation_stake_config: PlantDefenseConfig


class AnchorCountingPlantSystem:
	extends PlantSystem

	var validation_calls := 0

	func is_placement_valid_for_player(
		_top_left_cell: Vector2i,
		_config: PlantDefenseConfig,
		_placement_player: Player
	) -> bool:
		validation_calls += 1
		return true


class CandidateCacheInspectingPlantSystem:
	extends PlantSystem

	var candidate_build_calls := 0

	func _build_nearest_plant_candidates(
		center_cell: Vector2i,
		search_radius: int
	) -> Array[PlantDefense]:
		candidate_build_calls += 1
		return super._build_nearest_plant_candidates(center_cell, search_radius)

	func get_candidate_cache_size() -> int:
		return _nearest_plant_candidate_cache.size()

	func get_cached_candidate_count(center_cell: Vector2i, search_radius: int) -> int:
		var cache_key := Vector3i(center_cell.x, center_cell.y, search_radius)
		var cached := _nearest_plant_candidate_cache.get(cache_key, []) as Array
		return cached.size()


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	_build_fixture()
	await physics_frame
	_test_config_and_scene_contracts()
	_test_plant_defense_mitigation()
	await _test_player_core_collision()
	_test_large_area_anchor_enumeration()
	await _test_grid_and_occupancy_rules()
	await _test_nearest_plant_candidate_cache()
	await _test_realtime_selection_and_cancel()
	await _test_enemy_contact_and_release()
	await _test_multiplayer_authority_contracts()
	await _test_cannonball_aoe_deduplication()

	if test_root != null and is_instance_valid(test_root):
		test_root.queue_free()
	for _cleanup_frame in range(3):
		await process_frame
	test_root = null
	tile_map = null
	player = null
	plant_system = null
	plant_container = null
	agave_config = null
	corn_config = null
	vegetation_stake_config = null
	Input.action_release(&"plant")
	Input.flush_buffered_events()

	if failures.is_empty():
		print("PLANT_DEFENSE_BATCH1_SMOKE_TEST_OK")
		quit()
		return
	for failure in failures:
		push_error(failure)
	quit(1)


func _build_fixture() -> void:
	test_root = Node2D.new()
	test_root.name = "PlantDefenseBatch1Fixture"
	root.add_child(test_root)

	var tower_template := TOWER_SCENE.instantiate()
	tile_map = tower_template.get_node("GroundTileMapLayer").duplicate() as TileMapLayer
	tower_template.free()
	# Keep this API/physics suite deterministic when the authored tower map changes.
	# The real scene's grass/water integration is covered by the terrain smoke test.
	tile_map.clear()
	var fixture_area := PlantSystem.DEFAULT_PLACEMENT_AREA
	for y in range(fixture_area.position.y, fixture_area.end.y):
		for x in range(fixture_area.position.x, fixture_area.end.x):
			tile_map.set_cell(Vector2i(x, y), 0, Vector2i.ZERO, 0)
	test_root.add_child(tile_map)

	player = PLAYER_SCENE.instantiate() as Player
	test_root.add_child(player)
	player.set_controls_locked(true)
	player.set_physics_process(false)

	plant_container = Node2D.new()
	plant_container.name = "PlantContainer"
	test_root.add_child(plant_container)
	plant_system = PLANT_SYSTEM_SCRIPT.new() as PlantSystem
	test_root.add_child(plant_system)
	plant_system.setup(
		tile_map,
		player,
		plant_container,
		PlantSystem.DEFAULT_PLACEMENT_AREA
	)
	agave_config = PlantDefenseRegistry.get_config(&"agave_cannon")
	corn_config = PlantDefenseRegistry.get_config(&"corn_machine_gun")
	vegetation_stake_config = PlantDefenseRegistry.get_config(&"vegetation_stake")


func _test_config_and_scene_contracts() -> void:
	_expect(agave_config != null and agave_config.is_valid(), "龙舌兰配置必须有效。")
	_expect(corn_config != null and corn_config.is_valid(), "玉米机枪塔配置必须有效。")
	_expect(
		vegetation_stake_config != null and vegetation_stake_config.is_valid(),
		"植被桩配置必须有效。"
	)
	if agave_config == null or corn_config == null or vegetation_stake_config == null:
		return
	var oak_config := PlantDefenseRegistry.get_config(&"oak_warehouse")
	_expect(oak_config != null and oak_config.is_valid(), "橡木仓库配置必须有效。")
	var wood_station_config := PlantDefenseRegistry.get_config(&"wood_processing_station")
	_expect(wood_station_config != null and wood_station_config.is_valid(), "木头加工站配置必须有效。")
	if oak_config == null or wood_station_config == null:
		return
	var registered_configs := PlantDefenseRegistry.get_all_configs()
	_expect(
		registered_configs.size() == 5
		and registered_configs.has(agave_config)
		and registered_configs.has(corn_config)
		and registered_configs.has(oak_config)
		and registered_configs.has(vegetation_stake_config)
		and registered_configs.has(wood_station_config),
		"植物注册表必须公开四种既有植物与木头加工站。"
	)
	_expect(
		wood_station_config.max_health == 2000
		and wood_station_config.physical_defense == 10
		and wood_station_config.magic_defense == 0
		and wood_station_config.footprint_size == Vector2i.ONE
		and not wood_station_config.supports_multiplayer,
		"木头加工站必须拥有2000生命、10物防、0法防、占1格且暂不进入多人放置。"
	)
	_expect(agave_config.max_health == 2000, "龙舌兰生命值必须为2000。")
	_expect(
		agave_config.physical_defense == 10 and agave_config.magic_defense == 20,
		"龙舌兰必须拥有10物理防御与20法术防御。"
	)
	_expect(agave_config.attack_damage == 25, "龙舌兰炮弹伤害必须为25。")
	_expect(is_equal_approx(agave_config.attack_speed, 50.0), "龙舌兰攻速必须为50。")
	_expect(agave_config.supports_multiplayer, "龙舌兰必须继续支持多人权威放置。")
	_expect(is_equal_approx(agave_config.get_attack_interval(), 2.0), "龙舌兰攻击间隔必须为2秒。")
	_expect(is_equal_approx(agave_config.attack_range, 176.0), "龙舌兰索敌半径必须为176。")
	_expect(
		agave_config.attack_burst_count == 1
		and is_zero_approx(agave_config.attack_burst_shot_interval),
		"旧植物必须继续使用单发默认配置。"
	)
	_expect(agave_config.footprint_size == Vector2i(2, 2), "龙舌兰必须继续占2×2格。")
	_expect(corn_config.display_name == "玉米机枪塔", "玉米配置必须使用正式显示名。")
	_expect(
		corn_config.max_health == 2500
		and corn_config.physical_defense == 10
		and corn_config.magic_defense == 20
		and corn_config.attack_damage == 30,
		"玉米机枪塔必须拥有2500生命、10物防、20法抗与30点单发伤害。"
	)
	_expect(
		is_equal_approx(corn_config.get_attack_interval(), 0.9)
		and corn_config.attack_burst_count == 6
		and is_equal_approx(corn_config.attack_burst_shot_interval, 0.06),
		"玉米机枪塔必须每0.9秒进行一轮间隔0.06秒的6发连射。"
	)
	_expect(
		is_equal_approx(corn_config.attack_range, 160.0)
		and corn_config.footprint_size == Vector2i(2, 2)
		and corn_config.supports_multiplayer,
		"玉米机枪塔必须拥有160范围、占2×2格并支持多人。"
	)
	_expect(oak_config.footprint_size == Vector2i(2, 2), "橡木仓库必须继续占2×2格。")
	_expect(
		vegetation_stake_config.max_health == 4000
		and vegetation_stake_config.physical_defense == 10
		and vegetation_stake_config.magic_defense == 50
		and vegetation_stake_config.attack_damage == 0,
		"植被桩必须拥有4000生命、10物防、50法抗且攻击力为0。"
	)
	_expect(
		vegetation_stake_config.footprint_size == Vector2i.ONE,
		"植被桩必须只占1×1格。"
	)
	_expect(vegetation_stake_config.supports_multiplayer, "植被桩必须支持多人权威放置。")
	var stake_anchor_cell := Vector2i(4, 3)
	_expect(
		plant_system.get_anchor_world_position(stake_anchor_cell, vegetation_stake_config)
		== tile_map.to_global(tile_map.map_to_local(stake_anchor_cell)),
		"1×1植被桩的放置锚点必须严格位于目标格中心。"
	)
	_expect(
		agave_config.plant_scene.resource_path.begins_with("res://scene/plant_defense/"),
		"龙舌兰必须继续由scene/plant_defense下的独立场景实例化。"
	)
	_expect(
		ProjectSettings.get_setting("layer_names/2d_physics/layer_10") == "PlantBody",
		"物理层10必须命名为PlantBody。"
	)
	_expect(
		ProjectSettings.get_setting("layer_names/2d_physics/layer_11") == "TowerCore",
		"物理层11必须命名为TowerCore。"
	)
	for player_scene: PackedScene in [PLAYER_SCENE, TIYI_SCENE, HOE_CAT_SCENE]:
		var player_probe := player_scene.instantiate() as Player
		_expect(
			player_probe != null and (player_probe.collision_mask & 1024) != 0,
			"所有玩家角色都必须碰撞TowerCore层。"
		)
		if player_probe != null:
			player_probe.free()
	_expect(
		preload("res://scene/settings/settings_manager.gd").BINDABLE_ACTIONS.has("plant"),
		"plant必须是正式可改键动作。"
	)
	var has_default_t := false
	for event in InputMap.action_get_events(&"plant"):
		if event is InputEventKey:
			has_default_t = has_default_t or (event as InputEventKey).physical_keycode == KEY_T
	_expect(has_default_t, "plant默认按键必须真实绑定为T。")
	var t_match_probe := InputEventKey.new()
	t_match_probe.physical_keycode = KEY_T
	t_match_probe.pressed = true
	_expect(t_match_probe.is_action_pressed(&"plant"), "T键事件必须匹配plant动作。")

	var tower_instance := TOWER_SCENE.instantiate()
	_expect(tower_instance.get_node_or_null("PlantSystem") is PlantSystem, "塔防场景必须预建PlantSystem。")
	_expect(tower_instance.get_node_or_null("PlantContainer") is Node2D, "塔防场景必须预建植物容器。")
	_expect(
		tower_instance.get_node_or_null("PlantPlacementController") is PlantPlacementController,
		"塔防场景必须预建放置控制器。"
	)
	_expect(
		(tower_instance.get_node("Camera2D") as Camera2D).zoom == Vector2(2, 2),
		"64px素材的0.5世界缩放必须继续由塔防2倍镜头形成一源像素一屏幕像素。"
	)
	var ghost := tower_instance.get_node(
		"PlantPlacementController/PlantPlacementPreview/GhostSprite"
	) as Sprite2D
	_expect(
		ghost.texture_filter == CanvasItem.TEXTURE_FILTER_NEAREST,
		"植物放置幽灵必须使用邻近采样。"
	)
	_expect(
		ghost.position == Vector2.ZERO and ghost.scale == Vector2(0.5, 0.5),
		"64px植物放置幽灵必须在锚点原点以0.5静态缩放显示。"
	)
	for config in PlantDefenseRegistry.get_all_configs():
		_expect(
			config.icon != null and config.icon.get_size() == Vector2(64, 64),
			"每种植物配置都必须提供64×64组合图标。"
		)

	var vegetation_stake := vegetation_stake_config.plant_scene.instantiate() as PlantDefense
	_expect(vegetation_stake != null, "植被桩场景根节点必须继承PlantDefense。")
	if vegetation_stake != null:
		var main_sprite := vegetation_stake.get_node_or_null("MainSprite") as Sprite2D
		var top_glow := vegetation_stake.get_node_or_null("TopGlow") as Sprite2D
		var glow_motes := vegetation_stake.get_node_or_null("GlowMotes") as GPUParticles2D
		var cell_border := vegetation_stake.get_node_or_null("CellBorder") as MeshInstance2D
		var stake_health_bar := vegetation_stake.get_node_or_null("HealthBar") as Control
		_expect(
			main_sprite != null
			and top_glow != null
			and glow_motes != null
			and cell_border != null,
			"植被桩必须在场景中原生预建MainSprite、TopGlow、GlowMotes与CellBorder节点。"
		)
		if main_sprite != null and top_glow != null:
			_expect(
				main_sprite.scale == Vector2(0.5, 0.5)
				and top_glow.scale == Vector2(0.5, 0.5)
				and main_sprite.texture_filter == CanvasItem.TEXTURE_FILTER_NEAREST
				and top_glow.texture_filter == CanvasItem.TEXTURE_FILTER_NEAREST,
				"植被桩主体与发光层必须以0.5缩放和nearest采样保持像素轮廓。"
			)
			var stake_main_material := main_sprite.material as ShaderMaterial
			_expect(
				stake_main_material != null
				and stake_main_material.shader == PLANT_LIFECYCLE_SHADER,
				"植被桩主体必须使用兼具像素相位修正的生命周期shader。"
			)
		if cell_border != null:
			var border_quad := cell_border.mesh as QuadMesh
			var border_material := cell_border.material as ShaderMaterial
			var border_shader_code := (
				border_material.shader.code
				if border_material != null and border_material.shader != null
				else ""
			)
			_expect(
				border_quad != null
				and border_quad.size == Vector2(16, 16)
				and border_shader_code.contains("pixel.x < 2.0")
				and border_shader_code.contains("pixel.y < 2.0")
				and border_shader_code.contains("pixel.x >= 14.0")
				and border_shader_code.contains("pixel.y >= 14.0"),
				"植被桩边框必须覆盖16×16地块且只绘制最外两圈逻辑像素。"
			)
			_expect(
				border_shader_code.contains(
					"COLOR = vec4(base_color.rgb * brightness, 1.0);"
				)
				and not border_shader_code.contains("base_color.a"),
				"植被桩所有可见边框像素必须保持完全不透明，亮度动画只能改变RGB。"
			)
		if glow_motes != null:
			var mote_material := glow_motes.process_material as ParticleProcessMaterial
			_expect(
				glow_motes.texture == null
				and glow_motes.texture_filter == CanvasItem.TEXTURE_FILTER_NEAREST
				and glow_motes.amount == 16
				and glow_motes.position == Vector2(0, -3.25)
				and glow_motes.visibility_rect == Rect2(-5.5, -2.5, 11, 3.5)
				and mote_material != null
				and mote_material.emission_box_extents == Vector3(4.75, 0.5, 1)
				and mote_material.direction == Vector3(0, -1, 0)
				and is_equal_approx(mote_material.spread, 14.0)
				and is_equal_approx(mote_material.initial_velocity_min, 1.2)
				and is_equal_approx(mote_material.initial_velocity_max, 2.4)
				and mote_material.scale_min >= 0.5
				and mote_material.scale_max <= 1.0,
				"植被桩飘光必须横向覆盖顶部核心，并向下多覆盖一个屏幕像素。"
			)
		if stake_health_bar != null:
			_expect(
				stake_health_bar.custom_minimum_size == Vector2(12, 3)
				and is_equal_approx(stake_health_bar.offset_left, -6.0)
				and is_equal_approx(stake_health_bar.offset_right, 6.0)
				and is_equal_approx(stake_health_bar.offset_top, -9.0)
				and is_equal_approx(stake_health_bar.offset_bottom, -6.0)
				and stake_health_bar.scale == Vector2.ONE
				and stake_health_bar.damage_trail_color.is_equal_approx(
					Color(0.92156863, 0.28235295, 0.18039216, 1.0)
				)
				and is_equal_approx(
					(stake_health_bar.offset_left + stake_health_bar.offset_right) * 0.5,
					0.0
				),
				"植被桩血条必须以12×3逻辑像素原生绘制、居中且继承公共红色残血。"
			)
		vegetation_stake.free()

	var agave := agave_config.plant_scene.instantiate() as AgaveCannon
	_expect(agave != null, "龙舌兰场景根节点必须继承PlantDefense。")
	if agave != null:
		test_root.add_child(agave)
		_expect(agave.collision_layer == 512, "植物必须位于PlantBody层。")
		var visual_root := agave.get_node("VisualRoot") as Node2D
		var body_sprite := agave.get_node("VisualRoot/BodySprite") as AnimatedSprite2D
		var cannon_pivot := agave.get_node("VisualRoot/CannonPivot") as Node2D
		var cannon_sprite := agave.get_node(
			"VisualRoot/CannonPivot/CannonSprite"
		) as AnimatedSprite2D
		var muzzle := agave.get_node("VisualRoot/CannonPivot/Muzzle") as Marker2D
		_expect(
			visual_root.position == Vector2.ZERO
			and visual_root.scale == Vector2(0.5, 0.5),
			"龙舌兰必须只对独立VisualRoot应用0.5静态缩放。"
		)
		_expect(
			body_sprite.texture_filter == CanvasItem.TEXTURE_FILTER_NEAREST,
			"植物身体动画必须使用邻近采样。"
		)
		_expect(
			cannon_sprite.texture_filter == CanvasItem.TEXTURE_FILTER_NEAREST,
			"植物开火动画必须使用邻近采样。"
		)
		var body_material := body_sprite.material as ShaderMaterial
		var cannon_material := cannon_sprite.material as ShaderMaterial
		_expect(
			body_material != null
			and cannon_material != null
			and body_material == cannon_material
			and body_material.shader == PLANT_LIFECYCLE_SHADER,
			"龙舌兰身体与炮头必须共用兼具像素相位修正的生命周期shader。"
		)
		_expect(
			agave.material == null and visual_root.material == null,
			"龙舌兰像素相位修正不得作用于玩法根、炮口或碰撞树。"
		)
		_expect(
			body_sprite.scale == Vector2.ONE
			and cannon_sprite.scale == Vector2.ONE
			and cannon_sprite.position == Vector2(-4, -6)
			and body_sprite.centered
			and cannon_sprite.centered
			and body_sprite.offset == Vector2.ZERO
			and cannon_sprite.offset == Vector2.ZERO,
			"龙舌兰64px身体与炮头必须共用居中的无偏移源坐标。"
		)
		_expect(
			cannon_pivot.position == Vector2(4, 0)
			and muzzle.position == Vector2(14, 1),
			"龙舌兰必须围绕炮管后半主体中心旋转，并保持原始炮口合成坐标。"
		)
		var pivot_world_position := visual_root.transform * cannon_pivot.position
		var muzzle_world_position := (
			visual_root.transform * (cannon_pivot.transform * muzzle.position)
		)
		_expect(
			pivot_world_position == Vector2(2, 0)
			and muzzle_world_position == Vector2(9, 0.5),
			"修正枢轴后必须保持默认朝向的炮口世界坐标不变。"
		)
		for aim_direction in [Vector2.RIGHT, Vector2.DOWN, Vector2(-1, -1).normalized()]:
			agave.call(
				"_point_cannon_at",
				cannon_pivot.global_position + aim_direction * 100.0
			)
			var visual_muzzle_direction := cannon_pivot.global_position.direction_to(
				muzzle.global_position
			)
			_expect(
				visual_muzzle_direction.dot(aim_direction) > 0.9999,
				"龙舌兰瞄准必须抵消固定美术角，使视觉炮口与目标方向一致。"
			)
		cannon_pivot.rotation = 0.0
		var idle_aim_timer := agave.get_node("IdleAimTimer") as Timer
		_expect(
			idle_aim_timer.one_shot
			and is_equal_approx(idle_aim_timer.wait_time, 0.7),
			"龙舌兰待机炮口必须使用0.7秒原生单次Timer，而非逐帧轮询。"
		)
		agave.set_idle_aim_random_seed(20260714)
		agave.call("_start_idle_aim")
		var previous_idle_rotation := cannon_pivot.rotation
		var previous_idle_direction := 0
		for step_index in range(8):
			agave.call("_on_idle_aim_timer_timeout")
			var rotation_delta := cannon_pivot.rotation - previous_idle_rotation
			var direction := signi(roundi(rotation_delta * 1000000.0))
			_expect(direction != 0, "每次待机活动都必须产生可见的小幅瞬时旋转。")
			if previous_idle_direction != 0:
				_expect(
					direction == -previous_idle_direction,
					"龙舌兰相邻两次待机旋转必须严格交替顺逆时针。"
				)
			var relative_rotation := cannon_pivot.rotation - agave.idle_aim_center_rotation
			_expect(
				absf(relative_rotation) >= deg_to_rad(3.0) - 0.00001
				and absf(relative_rotation) <= deg_to_rad(15.0) + 0.00001,
				"龙舌兰待机随机目标必须位于中心两侧3至15度内。"
			)
			_expect(
				signi(roundi(relative_rotation * 1000000.0)) == direction,
				"每次待机目标必须落在本次移动方向对应的半弧。"
			)
			var is_burst_followup := step_index % 4 == 2
			_expect(
				idle_aim_timer.wait_time >= (
					AgaveCannon.IDLE_AIM_BURST_INTERVAL_MIN
					if is_burst_followup
					else AgaveCannon.IDLE_AIM_INTERVAL_MIN
				)
				and idle_aim_timer.wait_time <= (
					AgaveCannon.IDLE_AIM_BURST_INTERVAL_MAX
					if is_burst_followup
					else AgaveCannon.IDLE_AIM_INTERVAL_MAX
				),
				"龙舌兰待机普通与双步间隔必须落在各自的随机范围。"
			)
			previous_idle_rotation = cannon_pivot.rotation
			previous_idle_direction = direction
		agave.call("_stop_idle_aim")
		_expect(
			idle_aim_timer.is_stopped() and not agave.idle_aim_active,
			"进入索敌或死亡状态时必须能完整停止待机炮口活动。"
		)
		var body_shape := agave.get_node("CollisionShape2D") as CollisionShape2D
		var rectangle := body_shape.shape as RectangleShape2D
		_expect(
			rectangle != null
			and rectangle.size == Vector2(28, 27)
			and body_shape.position == Vector2(0, 3.5),
			"龙舌兰接触碰撞必须贴合当前下沉半像素的28×27主体。"
		)
		var player_core := agave.get_node("PlayerCoreBody") as StaticBody2D
		var player_core_shape := player_core.get_node("CollisionShape2D") as CollisionShape2D
		var player_core_capsule := player_core_shape.shape as CapsuleShape2D
		_expect(
			player_core.collision_layer == 1024
			and player_core.collision_mask == 2
			and player_core.position == Vector2(0, 1)
			and player_core_shape.position == Vector2(0, 2)
			and player_core_capsule != null
			and is_equal_approx(player_core_capsule.radius, 7.0)
			and is_equal_approx(player_core_capsule.height, 14.0),
			"龙舌兰核心必须使用仅供玩家碰撞的TowerCore胶囊体积。"
		)
		var target_shape := agave.get_node("TargetingArea/CollisionShape2D") as CollisionShape2D
		var target_circle := target_shape.shape as CircleShape2D
		_expect(target_circle != null and is_equal_approx(target_circle.radius, 176.0), "索敌Area半径必须为176。")
		var plant_health_bar := agave.get_node("HealthBar") as Control
		_expect(
			plant_health_bar != null
			and plant_health_bar.get_script() == PLANT_HEALTH_BAR_SCRIPT
			and plant_health_bar.size == Vector2(32, 5)
			and plant_health_bar.scale == Vector2.ONE
			and plant_health_bar.position == Vector2(-16, -15),
			"龙舌兰必须实例化位于-15..-10的32×5无缩放植物血条。"
		)
		_test_agave_visual_bounds(visual_root, body_sprite, cannon_pivot, cannon_sprite)
		_test_preview_runtime_alignment(ghost, agave, body_sprite, cannon_pivot, cannon_sprite)
		agave.free()

	var corn := corn_config.plant_scene.instantiate() as CornMachineGun
	_expect(corn != null, "玉米机枪场景根节点必须继承PlantDefense。")
	if corn != null:
		var corn_body := corn.get_node("VisualRoot/BodySprite") as AnimatedSprite2D
		var corn_turret := corn.get_node(
			"VisualRoot/AimPivot/TurretSprite"
		) as AnimatedSprite2D
		var corn_flash := corn.get_node(
			"VisualRoot/AimPivot/MuzzleFlashSprite"
		) as AnimatedSprite2D
		var corn_body_material := corn_body.material as ShaderMaterial
		var corn_turret_material := corn_turret.material as ShaderMaterial
		var corn_flash_material := corn_flash.material as ShaderMaterial
		_expect(
			corn_body_material != null
			and corn_turret_material != null
			and corn_body_material == corn_turret_material
			and corn_body_material.shader == PLANT_LIFECYCLE_SHADER,
			"玉米机枪身体与炮塔必须共用生命周期shader。"
		)
		_expect(
			corn_flash_material != null
			and corn_flash_material.shader == PLANT_VISUAL_PIXEL_SNAP_SHADER,
			"玉米枪口火焰不参与溶解，必须继续使用独立像素相位修正shader。"
		)
		corn.free()
	tower_instance.free()

	var cannonball := CANNONBALL_SCENE.instantiate() as AgaveCannonball
	_expect(cannonball != null, "黑球炮弹场景必须可独立实例化。")
	if cannonball != null:
		var cannonball_sprite := cannonball.get_node("CannonballSprite") as Sprite2D
		_expect(
			cannonball_sprite.texture_filter == CanvasItem.TEXTURE_FILTER_NEAREST
			and cannonball_sprite.scale == Vector2(0.5, 0.5),
			"缩小后的黑球Sprite必须以0.5整数屏幕像素比例使用邻近采样。"
		)
		var flight_cast := cannonball.get_node("FlightCast") as ShapeCast2D
		var flight_circle := flight_cast.shape as CircleShape2D
		_expect(flight_circle != null and is_equal_approx(flight_circle.radius, 2.5), "缩小后的黑球扫掠半径必须为2.5。")
		var blast_shape := cannonball.get_node("ExplosionQueryArea/CollisionShape2D") as CollisionShape2D
		var blast_circle := blast_shape.shape as CircleShape2D
		_expect(blast_circle != null and is_equal_approx(blast_circle.radius, 18.0), "黑球爆炸半径必须为18。")
		_expect(is_equal_approx(cannonball.speed, 180.0), "黑球飞行速度必须为180。")
		_expect(cannonball.damage == 25, "黑球炮弹默认伤害必须为25。")
		cannonball.free()


func _test_agave_visual_bounds(
	visual_root: Node2D,
	body_sprite: AnimatedSprite2D,
	cannon_pivot: Node2D,
	cannon_sprite: AnimatedSprite2D
) -> void:
	var footprint_rect := Rect2(Vector2(-16, -16), Vector2(32, 32))
	for texture in _get_animation_textures(body_sprite):
		_expect(texture.get_size() == Vector2(64, 64), "龙舌兰全部身体帧必须为64×64。")
		var body_rect := _get_animated_sprite_subject_rect(
			body_sprite,
			texture,
			visual_root.transform
		)
		_expect(
			footprint_rect.grow(0.01).encloses(body_rect),
			"龙舌兰身体帧应用VisualRoot变换后不得越出32×32占格。"
		)

	var original_rotation := cannon_pivot.rotation
	for texture in _get_animation_textures(cannon_sprite):
		_expect(texture.get_size() == Vector2(64, 64), "龙舌兰全部炮头帧必须为64×64。")
		_expect(
			_get_max_opaque_radius(texture, Vector2(32, 32)) <= 24.1,
			"龙舌兰炮头相对共享枢轴的像素中心半径不得超过24.1源像素。"
		)
		for direction_index in range(8):
			cannon_pivot.rotation = float(direction_index) * PI / 4.0
			var cannon_rect := _get_animated_sprite_subject_rect(
				cannon_sprite,
				texture,
				visual_root.transform * cannon_pivot.transform
			)
			_expect(
				footprint_rect.grow(0.01).encloses(cannon_rect),
				"龙舌兰炮头任意八方向旋转时不得越出32×32占格。"
			)
	cannon_pivot.rotation = original_rotation


func _test_preview_runtime_alignment(
	ghost: Sprite2D,
	agave: AgaveCannon,
	body_sprite: AnimatedSprite2D,
	cannon_pivot: Node2D,
	cannon_sprite: AnimatedSprite2D
) -> void:
	ghost.texture = agave_config.icon
	var ghost_rect := _get_sprite_subject_rect(ghost, agave_config.icon, Transform2D.IDENTITY)
	var body_texture := body_sprite.sprite_frames.get_frame_texture(&"idle", 0)
	var cannon_texture := cannon_sprite.sprite_frames.get_frame_texture(&"idle", 0)
	var visual_root := agave.get_node("VisualRoot") as Node2D
	var runtime_rect := _get_animated_sprite_subject_rect(
		body_sprite,
		body_texture,
		visual_root.transform
	)
	runtime_rect = runtime_rect.merge(
		_get_animated_sprite_subject_rect(
			cannon_sprite,
			cannon_texture,
			visual_root.transform * cannon_pivot.transform
		)
	)
	_expect(
		_rect_edges_are_close(ghost_rect, runtime_rect, 0.5),
		"龙舌兰放置预览与默认运行外观的包围盒和脚点误差不得超过0.5世界像素。"
	)

	var warehouse_config := PlantDefenseRegistry.get_config(&"oak_warehouse")
	var warehouse := warehouse_config.plant_scene.instantiate() as OakWarehouse
	var warehouse_sprite := warehouse.get_node("Sprite2D") as Sprite2D
	var warehouse_material := warehouse_sprite.material as ShaderMaterial
	_expect(
		warehouse_material != null
		and warehouse_material.shader == PLANT_LIFECYCLE_SHADER
		and warehouse.material == null,
		"仓库必须只对主体Sprite应用兼具像素相位修正的生命周期shader。"
	)
	ghost.texture = warehouse_config.icon
	ghost_rect = _get_sprite_subject_rect(ghost, warehouse_config.icon, Transform2D.IDENTITY)
	runtime_rect = _get_sprite_subject_rect(
		warehouse_sprite,
		warehouse_sprite.texture,
		Transform2D.IDENTITY
	)
	_expect(
		_rect_edges_are_close(ghost_rect, runtime_rect, 0.5),
		"橡木仓库放置预览与运行建筑的包围盒和脚点误差不得超过0.5世界像素。"
	)
	warehouse.free()


func _get_animation_textures(sprite: AnimatedSprite2D) -> Array[Texture2D]:
	var textures: Array[Texture2D] = []
	for animation_name in sprite.sprite_frames.get_animation_names():
		for frame_index in range(sprite.sprite_frames.get_frame_count(animation_name)):
			var texture := sprite.sprite_frames.get_frame_texture(animation_name, frame_index)
			if texture != null and not textures.has(texture):
				textures.append(texture)
	return textures


func _get_animated_sprite_subject_rect(
	sprite: AnimatedSprite2D,
	texture: Texture2D,
	parent_transform: Transform2D
) -> Rect2:
	return _get_transformed_subject_rect(
		texture,
		sprite.centered,
		sprite.offset,
		parent_transform * sprite.transform
	)


func _get_sprite_subject_rect(
	sprite: Sprite2D,
	texture: Texture2D,
	parent_transform: Transform2D
) -> Rect2:
	return _get_transformed_subject_rect(
		texture,
		sprite.centered,
		sprite.offset,
		parent_transform * sprite.transform
	)


func _get_transformed_subject_rect(
	texture: Texture2D,
	centered: bool,
	offset: Vector2,
	transform: Transform2D
) -> Rect2:
	var opaque_bounds := _get_texture_opaque_bounds(texture)
	var source_rect := Rect2(Vector2(opaque_bounds.position), Vector2(opaque_bounds.size))
	if centered:
		source_rect.position -= texture.get_size() * 0.5
	source_rect.position += offset
	return _transform_rect(source_rect, transform)


func _transform_rect(rect: Rect2, transform: Transform2D) -> Rect2:
	var corners: Array[Vector2] = [
		rect.position,
		Vector2(rect.end.x, rect.position.y),
		rect.end,
		Vector2(rect.position.x, rect.end.y),
	]
	var first_point := transform * corners[0]
	var transformed := Rect2(first_point, Vector2.ZERO)
	for corner_index in range(1, corners.size()):
		transformed = transformed.expand(transform * corners[corner_index])
	return transformed


func _get_texture_opaque_bounds(texture: Texture2D) -> Rect2i:
	var image := texture.get_image()
	var minimum := Vector2i(image.get_width(), image.get_height())
	var maximum := Vector2i(-1, -1)
	for y in range(image.get_height()):
		for x in range(image.get_width()):
			if image.get_pixel(x, y).a <= 0.001:
				continue
			minimum.x = mini(minimum.x, x)
			minimum.y = mini(minimum.y, y)
			maximum.x = maxi(maximum.x, x + 1)
			maximum.y = maxi(maximum.y, y + 1)
	if maximum.x < minimum.x or maximum.y < minimum.y:
		return Rect2i()
	return Rect2i(minimum, maximum - minimum)


func _get_max_opaque_radius(texture: Texture2D, pivot: Vector2) -> float:
	var image := texture.get_image()
	var maximum_radius := 0.0
	for y in range(image.get_height()):
		for x in range(image.get_width()):
			if image.get_pixel(x, y).a <= 0.001:
				continue
			maximum_radius = maxf(
				maximum_radius,
				Vector2(float(x) + 0.5, float(y) + 0.5).distance_to(pivot)
			)
	return maximum_radius


func _rect_edges_are_close(first: Rect2, second: Rect2, tolerance: float) -> bool:
	return (
		absf(first.position.x - second.position.x) <= tolerance
		and absf(first.position.y - second.position.y) <= tolerance
		and absf(first.end.x - second.end.x) <= tolerance
		and absf(first.end.y - second.end.y) <= tolerance
	)


func _test_plant_defense_mitigation() -> void:
	var defense_probe := PlantDefense.new()
	test_root.add_child(defense_probe)
	defense_probe.setup(agave_config, player, [])
	var full_health := defense_probe.current_health
	_expect(
		defense_probe.receive_damage(50, null, Vector2.ZERO, EnemyConfig.DamageType.PHYSICAL)
		and defense_probe.current_health == full_health - 40,
		"10点物防必须把50点物理伤害降为40。"
	)
	defense_probe.receive_healing(50)
	_expect(
		defense_probe.receive_damage(50, null, Vector2.ZERO, EnemyConfig.DamageType.MAGIC)
		and defense_probe.current_health == full_health - 40,
		"20点法防必须把50点法术伤害按20%降为40。"
	)
	defense_probe.receive_healing(50)
	_expect(
		defense_probe.receive_damage(7, null, Vector2.ZERO, EnemyConfig.DamageType.PHYSICAL)
		and defense_probe.current_health == full_health - 1,
		"防御后的有效伤害必须至少为1。"
	)
	defense_probe.receive_healing(1)
	defense_probe.physical_defense = 999
	var revision_before_unmitigated_damage := defense_probe.health_revision
	_expect(
		defense_probe.receive_unmitigated_damage(50)
		and defense_probe.current_health == full_health - 50
		and defense_probe.health_revision == revision_before_unmitigated_damage + 1,
		"无视防御伤害必须完整扣除数值并沿用权威生命revision链。"
	)
	_expect(
		PlantSystem.calculate_unsupported_terrain_damage(1001) == 101
		and PlantSystem.calculate_unsupported_terrain_damage(501) == 51
		and PlantSystem.calculate_unsupported_terrain_damage(500) == 50
		and PlantSystem.calculate_unsupported_terrain_damage(1) == 50,
		"非草地衰败必须按当前生命10%向上取整，并保持每秒至少50点。"
	)
	defense_probe.queue_free()


func _test_player_core_collision() -> void:
	var collision_plant := agave_config.plant_scene.instantiate() as AgaveCannon
	collision_plant.global_position = Vector2(2000, 2000)
	test_root.add_child(collision_plant)
	collision_plant.setup(agave_config, player, [Vector2i.ZERO])
	collision_plant.attack_timer.stop()
	player.global_position = Vector2(1975, 2001)
	await physics_frame
	var player_collision := player.move_and_collide(Vector2(50, 0), true)
	_expect(
		player_collision != null
		and player_collision.get_collider() == collision_plant.get_node("PlayerCoreBody"),
		"玩家向植物核心移动时必须被TowerCore实体碰撞阻挡。"
	)

	var enemy_probe := ENEMY_CONFIG.enemy_scene.instantiate() as Enemy
	enemy_probe.global_position = Vector2(1975, 2001)
	test_root.add_child(enemy_probe)
	enemy_probe.setup(ENEMY_CONFIG, player)
	enemy_probe.set_physics_process(false)
	await physics_frame
	var enemy_collision := enemy_probe.move_and_collide(Vector2(50, 0), true)
	_expect(
		enemy_collision == null
		or enemy_collision.get_collider() != collision_plant.get_node("PlayerCoreBody"),
		"敌人身体不得被仅供玩家使用的TowerCore体积阻挡。"
	)
	enemy_probe.queue_free()
	collision_plant.queue_free()
	await process_frame


func _test_large_area_anchor_enumeration() -> void:
	if agave_config == null or not agave_config.is_valid():
		return

	var counting_system := AnchorCountingPlantSystem.new()
	test_root.add_child(counting_system)
	counting_system.setup(
		tile_map,
		player,
		plant_container,
		Rect2i(-120, -88, 256, 192)
	)
	_assert_anchor_enumeration_case(counting_system, Vector2i(40, 35))

	counting_system.placement_area = Rect2i(38, 34, 5, 4)
	_assert_anchor_enumeration_case(counting_system, Vector2i(42, 37))
	counting_system.queue_free()


func _assert_anchor_enumeration_case(
	counting_system: AnchorCountingPlantSystem,
	player_cell: Vector2i
) -> void:
	_set_player_cell(player_cell)
	counting_system.validation_calls = 0
	var anchors := counting_system.get_valid_anchors_for_player(agave_config, player)
	var expected := _get_expected_nearby_anchors(
		counting_system.placement_area,
		agave_config.footprint_size,
		player_cell,
		counting_system.max_placement_manhattan_distance
	)
	var actual := {}
	for anchor in anchors:
		actual[anchor] = true
		for cell in counting_system.get_footprint_cells(anchor, agave_config):
			_expect(
				counting_system.placement_area.has_point(cell),
				"大地图候选锚的完整植物足迹必须位于placement_area内。"
			)

	_expect(
		actual == expected,
		"大地图候选锚必须精确等于玩家Manhattan窗口与合法足迹锚区域的交集。"
	)
	_expect(
		counting_system.validation_calls == expected.size(),
		"大地图枚举不得对玩家附近Manhattan窗口之外的锚执行完整放置校验。"
	)
	_expect(
		counting_system.validation_calls <= 128,
		"2×2植物、距离4的放置枚举必须保持为常量级候选集。"
	)


func _get_expected_nearby_anchors(
	area: Rect2i,
	footprint_size: Vector2i,
	player_cell: Vector2i,
	radius: int
) -> Dictionary:
	var expected := {}
	var legal_anchor_size := area.size - footprint_size + Vector2i.ONE
	if legal_anchor_size.x <= 0 or legal_anchor_size.y <= 0:
		return expected
	var legal_anchor_area := Rect2i(area.position, legal_anchor_size)
	for y in range(player_cell.y - radius, player_cell.y + radius + 1):
		for x in range(player_cell.x - radius, player_cell.x + radius + 1):
			var nearby_cell := Vector2i(x, y)
			if (
				absi(nearby_cell.x - player_cell.x)
				+ absi(nearby_cell.y - player_cell.y)
				> radius
			):
				continue
			for footprint_y in range(footprint_size.y):
				for footprint_x in range(footprint_size.x):
					var anchor := nearby_cell - Vector2i(footprint_x, footprint_y)
					if legal_anchor_area.has_point(anchor):
						expected[anchor] = true
	return expected


func _test_grid_and_occupancy_rules() -> void:
	var anchor := _find_open_anchor_with_left_margin()
	_expect(anchor != Vector2i(9999, 9999), "实际塔防地面中必须存在可用2×2测试格。")
	if anchor == Vector2i(9999, 9999):
		return

	_set_player_cell(anchor + Vector2i(-4, 0))
	await physics_frame
	_expect(plant_system.is_placement_valid(anchor, agave_config), "距footprint最近格曼哈顿4应允许放置。")
	_set_player_cell(anchor + Vector2i(-5, 0))
	_expect(not plant_system.is_placement_valid(anchor, agave_config), "曼哈顿距离5必须拒绝。")

	_set_player_cell(anchor + Vector2i(-4, 0))
	plant_system.reserve_cell(anchor + Vector2i.ONE)
	_expect(not plant_system.is_placement_valid(anchor, agave_config), "footprint含保留格时必须拒绝。")
	plant_system.clear_reserved_cells()
	_expect(
		not plant_system.is_placement_valid(Vector2i(18, 16), agave_config),
		"2×2 footprint越出arena时必须拒绝。"
	)

	var missing_cell := anchor + Vector2i.ONE
	var source_id := tile_map.get_cell_source_id(missing_cell)
	var atlas_coords := tile_map.get_cell_atlas_coords(missing_cell)
	var alternative := tile_map.get_cell_alternative_tile(missing_cell)
	tile_map.erase_cell(missing_cell)
	_expect(not plant_system.is_placement_valid(anchor, agave_config), "四格中缺少TileData时必须拒绝。")
	tile_map.set_cell(missing_cell, source_id, atlas_coords, alternative)

	var blocker := CharacterBody2D.new()
	# Transient enemies, bosses and loose pickups are deliberately ignored so a
	# crowd cannot erase the complete placement radius. A world-layer body still
	# proves that authored persistent blockers reject overlapping placement.
	blocker.collision_layer = 1
	blocker.collision_mask = 0
	var blocker_shape := CollisionShape2D.new()
	var blocker_rectangle := RectangleShape2D.new()
	blocker_rectangle.size = Vector2(8, 8)
	blocker_shape.shape = blocker_rectangle
	blocker.add_child(blocker_shape)
	test_root.add_child(blocker)
	blocker.global_position = plant_system.get_anchor_world_position(anchor, agave_config)
	await physics_frame
	_expect(not plant_system.is_placement_valid(anchor, agave_config), "世界实体重叠必须拒绝。")
	blocker.queue_free()
	await physics_frame

	var plant := plant_system.try_place(agave_config, anchor)
	_expect(plant != null, "合法位置必须成功放置龙舌兰。")
	if plant == null:
		return
	_expect(not plant_system.is_placement_valid(anchor, agave_config), "已占用footprint必须拒绝重复放置。")
	_expect(plant.footprint_cells.size() == 4, "植物实例必须保存四个占用格。")
	var placed_agave := plant as AgaveCannon
	_expect(is_equal_approx(placed_agave.attack_timer.wait_time, 2.0), "放置后攻击计时器必须严格为2秒。")
	_expect(
		not placed_agave.is_operational and placed_agave.attack_timer.is_stopped(),
		"放置动画完成前龙舌兰必须占格但不能启动攻击。"
	)
	await create_timer(PlantDefense.CONSTRUCTION_DURATION_SECONDS + 0.08).timeout
	_expect(placed_agave.is_operational, "0.7秒构建完成后龙舌兰必须进入运行状态。")
	_expect(placed_agave.attack_timer.time_left > 1.8, "首次攻击必须等待完整攻击间隔。")
	_expect(
		placed_agave.world_los_query != null
		and placed_agave.world_los_exclude.size() == 1
		and placed_agave.world_los_exclude[0] == placed_agave.get_rid(),
		"龙舌兰必须为全部LOS检查复用同一个查询对象和自身RID排除数组。"
	)
	var tile_width := float(tile_map.tile_set.tile_size.x)
	var plant_local_position := tile_map.to_local(plant.global_position)
	var exactly_eight_cells_away := tile_map.to_global(
		plant_local_position - Vector2(tile_width * 8.0, 0.0)
	)
	_expect(
		plant_system.find_nearest_living_plant(exactly_eight_cells_away, 8.0) == plant,
		"植物空间索引必须包含恰好8格的半径边界。"
	)
	var outside_eight_cells := tile_map.to_global(
		plant_local_position - Vector2(tile_width * 8.01, 0.0)
	)
	_expect(
		plant_system.find_nearest_living_plant(outside_eight_cells, 8.0) == null,
		"植物空间索引不得返回8格半径外的目标。"
	)
	plant.set_meta(&"batch1_test_anchor", anchor)


func _test_nearest_plant_candidate_cache() -> void:
	var cache_container := Node2D.new()
	cache_container.name = "CandidateCachePlantContainer"
	test_root.add_child(cache_container)
	var cache_system := CandidateCacheInspectingPlantSystem.new()
	cache_system.name = "CandidateCachePlantSystem"
	test_root.add_child(cache_system)
	cache_system.setup(
		tile_map,
		player,
		cache_container,
		PlantSystem.DEFAULT_PLACEMENT_AREA
	)

	var center_cell := Vector2i(8, 7)
	var left_anchor := center_cell + Vector2i.LEFT
	var right_anchor := center_cell + Vector2i.RIGHT
	var agave_anchor := Vector2i(13, 11)

	_set_player_cell(left_anchor + Vector2i(0, 3))
	await physics_frame
	var left_stake := cache_system.try_place(
		vegetation_stake_config,
		left_anchor
	)
	_expect(left_stake != null, "候选缓存测试必须成功放置左侧植被桩。")

	_set_player_cell(agave_anchor + Vector2i(0, 3))
	await physics_frame
	var multi_cell_agave := cache_system.try_place(agave_config, agave_anchor)
	_expect(multi_cell_agave != null, "候选缓存测试必须成功放置2×2龙舌兰。")
	if left_stake == null or multi_cell_agave == null:
		cache_system.clear_all_plants()
		cache_system.queue_free()
		cache_container.queue_free()
		await process_frame
		return

	var center_world := tile_map.to_global(tile_map.map_to_local(center_cell))
	var initial_target := cache_system.find_nearest_living_plant(center_world, 8.0)
	_expect(initial_target == left_stake, "候选缓存首次查询必须返回真实最近植物。")
	_expect(cache_system.candidate_build_calls == 1, "首次中心瓦片查询必须只构建一次候选缓存。")
	_expect(
		cache_system.get_cached_candidate_count(center_cell, 9) == 2,
		"2×2植物在同一候选缓存中必须去重为单个植物引用。"
	)
	var repeated_target := cache_system.find_nearest_living_plant(center_world, 8.0)
	_expect(
		repeated_target == left_stake and cache_system.candidate_build_calls == 1,
		"相同中心瓦片与搜索半径必须命中缓存且保持最近目标。"
	)

	_set_player_cell(right_anchor + Vector2i(0, 3))
	await physics_frame
	var right_stake := cache_system.try_place(
		vegetation_stake_config,
		right_anchor
	)
	_expect(right_stake != null, "候选缓存测试必须成功放置右侧植被桩。")
	_expect(
		cache_system.get_candidate_cache_size() == 0,
		"新增植物必须在occupancy信号发出前失效全部候选缓存。"
	)
	if right_stake == null:
		cache_system.clear_all_plants()
		cache_system.queue_free()
		cache_container.queue_free()
		await process_frame
		return

	var tied_target := cache_system.find_nearest_living_plant(center_world, 8.0)
	_expect(
		tied_target == left_stake and cache_system.candidate_build_calls == 2,
		"拓扑变化后必须重建缓存，并按稳定的格子顺序确定等距目标。"
	)
	_expect(
		cache_system.get_cached_candidate_count(center_cell, 9) == 3,
		"重建缓存必须包含两个单格植物和一个去重后的多格植物。"
	)
	for _repeat_index in range(4):
		_expect(
			cache_system.find_nearest_living_plant(center_world, 8.0) == left_stake,
			"等距最近目标在连续缓存命中间必须保持确定性。"
		)

	var tile_width := float(tile_map.tile_set.tile_size.x)
	var left_biased_world := tile_map.to_global(
		tile_map.map_to_local(center_cell) + Vector2(-tile_width * 0.4, 0.0)
	)
	var right_biased_world := tile_map.to_global(
		tile_map.map_to_local(center_cell) + Vector2(tile_width * 0.4, 0.0)
	)
	_expect(
		tile_map.local_to_map(tile_map.to_local(left_biased_world)) == center_cell
		and tile_map.local_to_map(tile_map.to_local(right_biased_world)) == center_cell,
		"实际位置变化回归的两个采样点必须处于同一中心瓦片。"
	)
	_expect(
		cache_system.find_nearest_living_plant(left_biased_world, 8.0) == left_stake
		and cache_system.find_nearest_living_plant(right_biased_world, 8.0) == right_stake,
		"候选集合可以复用，但每次查询必须用真实世界位置重新选择最近植物。"
	)
	_expect(
		cache_system.candidate_build_calls == 2,
		"同瓦片内实际位置变化不得重复构建候选集合。"
	)

	_expect(
		cache_system.find_nearest_living_plant(center_world, 4.0) == left_stake
		and cache_system.candidate_build_calls == 3,
		"不同搜索半径必须使用独立缓存键并保持精确距离语义。"
	)
	_expect(
		cache_system.find_nearest_living_plant(center_world, 8.0) == left_stake
		and cache_system.candidate_build_calls == 3,
		"建立其他半径缓存后，原搜索半径仍必须继续命中已有缓存。"
	)

	right_stake.receive_damage(99999)
	_expect(
		cache_system.get_candidate_cache_size() == 0,
		"植物死亡释放footprint时必须立即失效候选缓存。"
	)
	_expect(
		cache_system.find_nearest_living_plant(right_biased_world, 8.0) == left_stake
		and cache_system.candidate_build_calls == 4,
		"死亡拓扑失效后不得从旧缓存返回已死亡植物。"
	)

	cache_system.clear_all_plants()
	_expect(
		cache_system.get_candidate_cache_size() == 0
		and cache_system.find_nearest_living_plant(center_world, 8.0) == null,
		"清空全部植物必须同步清空候选缓存与最近目标结果。"
	)
	cache_system.queue_free()
	cache_container.queue_free()
	for _cleanup_frame in range(2):
		await process_frame
	_set_player_cell(Vector2i.ZERO)
	await physics_frame


func _test_realtime_selection_and_cancel() -> void:
	var controller := PLACEMENT_CONTROLLER_SCENE.instantiate() as PlantPlacementController
	test_root.add_child(controller)
	controller.setup(plant_system, player)
	var lock_events: Array[bool] = []
	controller.player_lock_requested.connect(func(locked: bool) -> void: lock_events.append(locked))
	var was_paused := paused
	var plant_press := InputEventAction.new()
	plant_press.action = &"plant"
	plant_press.pressed = true
	Input.parse_input_event(plant_press)
	for _input_frame in range(2):
		await process_frame
	_expect(controller.is_selecting(), "打开后状态必须为SELECTING。")
	_expect(controller.selection_hud.is_open(), "真实plant动作输入必须显示植物选择界面。")
	_expect(
		controller.selection_hud.available_configs.size() == 5
		and controller.selection_hud.available_configs.has(agave_config)
		and controller.selection_hud.available_configs.has(corn_config)
		and controller.selection_hud.available_configs.has(
			PlantDefenseRegistry.get_config(&"oak_warehouse")
		)
		and controller.selection_hud.available_configs.has(vegetation_stake_config)
		and controller.selection_hud.available_configs.has(
			PlantDefenseRegistry.get_config(&"wood_processing_station")
		)
		and controller.selection_hud.cards.size() == 5,
		"单人植物选择界面必须生成四张既有卡片与木头加工站卡片。"
	)
	var agave_card: PlantSelectionCard = null
	var corn_card: PlantSelectionCard = null
	for card in controller.selection_hud.cards:
		if card.plant_config == agave_config:
			agave_card = card
		elif card.plant_config == corn_config:
			corn_card = card
	_expect(
		agave_card != null
		and agave_card.stats_label.text == "生命 2000  ·  伤害 25  ·  间隔 2 秒  ·  半径 176",
		"单发旧植物的属性文案必须保持原样。"
	)
	_expect(
		corn_card != null
		and corn_card.stats_label.text == "生命 2500  ·  伤害 30×6  ·  轮间隔 0.9 秒  ·  半径 160",
		"玉米机枪塔卡片必须显示整轮伤害与轮间隔。"
	)
	_expect(paused == was_paused and not paused, "选择植物不得暂停SceneTree。")
	_expect(not lock_events.is_empty() and lock_events.back(), "选择期间必须请求锁定玩家。")
	var plant_release := InputEventAction.new()
	plant_release.action = &"plant"
	plant_release.pressed = false
	Input.parse_input_event(plant_release)
	Input.flush_buffered_events()
	plant_press = null
	plant_release = null
	controller.selection_hud.selection_confirmed.emit(agave_config)
	await process_frame
	_expect(controller.is_placing(), "确认卡片后必须进入PLACING。")
	_expect(not controller.valid_anchors.is_empty(), "放置阶段必须生成合法绿色位置标记。")
	controller.cancel_placement()
	_expect(not controller.is_active(), "取消后必须回到IDLE。")
	_expect(not lock_events.is_empty() and not lock_events.back(), "取消后必须请求解锁玩家。")
	controller.queue_free()
	await process_frame


func _test_enemy_contact_and_release() -> void:
	var plant: PlantDefense = null
	for child in plant_container.get_children():
		if child is PlantDefense:
			plant = child as PlantDefense
			break
	_expect(plant != null, "接触伤害测试需要已放置植物。")
	if plant == null:
		return

	var enemy := ENEMY_CONFIG.enemy_scene.instantiate() as Enemy
	test_root.add_child(enemy)
	enemy.setup(ENEMY_CONFIG, player)
	enemy.set_physics_process(false)
	enemy.global_position = plant.global_position + Vector2(20.0, 0.0)
	var starting_health := plant.current_health
	var contact_damage := maxi(ENEMY_CONFIG.attack_damage - agave_config.physical_defense, 1)
	enemy._on_touch_damage_area_body_entered(plant)
	_expect(not enemy._has_player_contact(), "初次接触龙舌兰外缘时必须继续向内贴近。")
	_expect(plant.current_health == starting_health - contact_damage, "敌人接触必须立即结算一次物防后的伤害。")
	enemy._update_touch_damage(0.1)
	_expect(plant.current_health == starting_health - contact_damage, "接触冷却内不得重复伤害。")
	enemy._update_touch_damage(enemy.touch_damage_interval)
	_expect(plant.current_health == starting_health - contact_damage * 2, "冷却结束后必须再次结算防御后伤害。")
	enemy.global_position = plant.global_position + Vector2(14.0, 0.0)
	_expect(enemy._has_player_contact(), "向龙舌兰内部推进6像素后必须形成稳定停止接触。")
	enemy.velocity = Vector2(30, 0)
	enemy._move_until_player_contact()
	_expect(enemy.velocity == Vector2.ZERO, "接触植物时敌人必须停止而不改A*。")

	var occupied_cell := plant.footprint_cells[0]
	plant.receive_damage(99999, enemy)
	_expect(not plant_system.is_cell_occupied(occupied_cell), "植物死亡必须立即释放四格占用。")
	_expect(not enemy._has_player_contact(), "植物死亡必须立即从敌人接触表移除。")
	enemy.queue_free()
	await process_frame


func _test_multiplayer_authority_contracts() -> void:
	var anchor := _find_open_anchor_with_left_margin()
	_expect(anchor != Vector2i(9999, 9999), "多人植物测试需要可用2×2测试格。")
	if anchor == Vector2i(9999, 9999):
		return

	var requesting_player := PLAYER_SCENE.instantiate() as Player
	test_root.add_child(requesting_player)
	requesting_player.set_controls_locked(true)
	requesting_player.set_physics_process(false)
	_set_specific_player_cell(player, anchor + Vector2i(-6, 0))
	_set_specific_player_cell(requesting_player, anchor + Vector2i(-4, 0))
	await physics_frame
	_expect(
		not plant_system.is_placement_valid(anchor, agave_config),
		"默认owner距离过远时不得通过放置校验。"
	)
	_expect(
		plant_system.is_placement_valid_for_player(anchor, agave_config, requesting_player),
		"主机必须按请求玩家自身的位置校验放置距离。"
	)
	_expect(
		not plant_system.is_placement_valid_for_player(anchor, agave_config, null),
		"请求玩家不存在时不得回退到房主或本地owner。"
	)

	const HOST_PLANT_NET_ID := 4101
	var authoritative_plant := plant_system.try_place_for_player(
		agave_config,
		anchor,
		requesting_player,
		HOST_PLANT_NET_ID
	)
	_expect(authoritative_plant != null, "主机必须能以指定玩家和net_id放置植物。")
	if authoritative_plant == null:
		requesting_player.queue_free()
		await process_frame
		return
	_expect(
		plant_system.get_plant_by_net_id(HOST_PLANT_NET_ID) == authoritative_plant,
		"主机植物必须注册到net_id索引。"
	)
	_expect(
		int(authoritative_plant.get_meta(&"net_id", 0)) == HOST_PLANT_NET_ID,
		"主机植物节点必须携带稳定net_id。"
	)
	_expect(authoritative_plant.owner_player == requesting_player, "植物owner必须是请求玩家。")
	_expect(authoritative_plant.health_revision == 1, "权威植物初始生命revision必须为1。")
	var health_events: Array[Vector3i] = []
	authoritative_plant.authoritative_health_changed.connect(
		func(current: int, maximum: int, revision: int) -> void:
			health_events.append(Vector3i(current, maximum, revision))
	)
	var host_health_before := authoritative_plant.current_health
	_expect(authoritative_plant.receive_damage(7), "权威植物必须接受主机伤害。")
	_expect(
		authoritative_plant.current_health == host_health_before - 1
		and authoritative_plant.health_revision == 2,
		"权威植物必须在结算物防后同时推进生命值和revision。"
	)
	_expect(
		health_events.size() == 1
		and health_events[0] == Vector3i(host_health_before - 1, agave_config.max_health, 2),
		"生命revision信号必须携带同一份权威状态。"
	)
	_expect(
		plant_system.remove_plant_by_net_id(HOST_PLANT_NET_ID),
		"按net_id移除权威植物必须成功。"
	)
	_expect(
		plant_system.get_plant_by_net_id(HOST_PLANT_NET_ID) == null
		and not plant_system.is_cell_occupied(anchor),
		"按net_id移除后必须立即释放索引和占格。"
	)
	await physics_frame
	const WAREHOUSE_REPLICA_NET_ID := 4100
	var warehouse_replica := plant_system.spawn_multiplayer_replica(
		&"oak_warehouse",
		anchor,
		requesting_player,
		WAREHOUSE_REPLICA_NET_ID,
		5000,
		5000,
		1
	) as OakWarehouse
	_expect(warehouse_replica != null, "共享仓库必须能生成多人客户端副本。")
	if warehouse_replica != null:
		_expect(warehouse_replica.is_multiplayer_proxy, "共享仓库副本必须标记为多人代理。")
		_expect(
			plant_system.remove_plant_by_net_id(WAREHOUSE_REPLICA_NET_ID),
			"共享仓库副本必须能按net_id移除并释放占格。"
		)
	await physics_frame

	const REPLICA_NET_ID := 4102
	var replica := plant_system.spawn_multiplayer_replica(
		agave_config.plant_id,
		anchor,
		requesting_player,
		REPLICA_NET_ID,
		180,
		200,
		8
	) as AgaveCannon
	_expect(replica != null, "客户端必须能按权威状态创建植物副本。")
	if replica == null:
		requesting_player.queue_free()
		await process_frame
		return
	await physics_frame
	_expect(replica.is_multiplayer_proxy, "客户端植物必须标记为multiplayer proxy。")
	_expect(replica.attack_timer.is_stopped(), "客户端植物副本不得运行攻击计时器。")
	_expect(
		not replica.idle_aim_timer.is_stopped(),
		"客户端植物副本可以运行纯本地低频待机炮口活动。"
	)
	_expect(not replica.targeting_area.monitoring, "客户端植物副本不得运行本地索敌。")
	var replica_health_before := replica.current_health
	_expect(not replica.receive_damage(25), "客户端植物副本必须拒绝本地伤害。")
	_expect(
		not replica.receive_unmitigated_damage(50),
		"客户端植物副本必须拒绝本地无视防御伤害。"
	)
	_expect(replica.current_health == replica_health_before, "本地伤害不得改变副本生命值。")
	_expect(
		not replica.apply_remote_health(120, 200, 8),
		"重复或过期revision不得回滚副本生命。"
	)
	_expect(
		replica.apply_remote_health(120, 200, 9)
		and replica.current_health == 120
		and replica.health_revision == 9,
		"更新revision必须原子应用远端生命状态。"
	)

	var attack_probe := ENEMY_CONFIG.enemy_scene.instantiate() as Enemy
	test_root.add_child(attack_probe)
	attack_probe.setup(ENEMY_CONFIG, requesting_player)
	attack_probe.set_physics_process(false)
	attack_probe.global_position = replica.global_position + Vector2(24, 0)
	replica.target_candidates[attack_probe.get_instance_id()] = attack_probe
	replica._on_attack_timer_timeout()
	_expect(
		replica.cannon_sprite.animation == &"idle" and replica.pending_target == null,
		"客户端植物副本即使收到本地timeout也不得开始攻击。"
	)
	attack_probe.queue_free()

	var replica_cell := replica.footprint_cells[0]
	_expect(replica.apply_remote_health(0, 200, 10), "权威零生命更新必须被副本接受。")
	_expect(
		plant_system.get_plant_by_net_id(REPLICA_NET_ID) == null
		and not plant_system.is_cell_occupied(replica_cell),
		"副本零生命必须走统一死亡路径并立即释放net_id与占格。"
	)
	await physics_frame

	var controller := PLACEMENT_CONTROLLER_SCENE.instantiate() as PlantPlacementController
	test_root.add_child(controller)
	controller.setup(plant_system, requesting_player)
	controller.set_multiplayer_request_mode(true)
	_expect(controller.open_selection(), "多人植物选择必须仍可打开。")
	_expect(
		controller.selection_hud.available_configs.size() == 4
		and controller.selection_hud.available_configs.has(agave_config)
		and controller.selection_hud.available_configs.has(corn_config)
		and controller.selection_hud.available_configs.has(
			PlantDefenseRegistry.get_config(&"oak_warehouse")
		)
		and controller.selection_hud.available_configs.has(vegetation_stake_config)
		and controller.selection_hud.cards.size() == 4,
		"多人植物选择必须公开龙舌兰、玉米机枪塔、共享仓库与植被桩四张卡片。"
	)
	controller.cancel_placement()
	var placement_requests: Array[Dictionary] = []
	controller.multiplayer_placement_requested.connect(
		func(request_id: int, plant_id: StringName, requested_anchor: Vector2i) -> void:
			placement_requests.append({
				"request_id": request_id,
				"plant_id": plant_id,
				"anchor": requested_anchor,
			})
	)
	controller.selected_config = agave_config
	controller.placement_state = PlantPlacementController.PlacementState.PLACING
	controller.hovered_anchor = anchor
	controller.has_hovered_anchor = true
	var plant_count_before_request := plant_container.get_child_count()
	controller.call("_try_place_hovered")
	_expect(placement_requests.size() == 1, "多人放置必须只发送一次带request_id的请求。")
	if placement_requests.size() == 1:
		_expect(
			int(placement_requests[0]["request_id"]) == 1
			and placement_requests[0]["plant_id"] == agave_config.plant_id
			and placement_requests[0]["anchor"] == anchor,
			"多人放置请求必须包含request_id、plant_id和anchor。"
		)
	_expect(
		plant_container.get_child_count() == plant_count_before_request
		and not plant_system.is_cell_occupied(anchor),
		"客户端提交放置请求时不得本地预测生成植物。"
	)
	controller.queue_free()
	requesting_player.queue_free()
	await process_frame


func _test_cannonball_aoe_deduplication() -> void:
	var enemy_a := ENEMY_CONFIG.enemy_scene.instantiate() as Enemy
	var enemy_b := ENEMY_CONFIG.enemy_scene.instantiate() as Enemy
	enemy_a.position = Vector2(500, 500)
	enemy_b.position = Vector2(512, 500)
	test_root.add_child(enemy_a)
	test_root.add_child(enemy_b)
	enemy_a.setup(ENEMY_CONFIG, player)
	enemy_b.setup(ENEMY_CONFIG, player)
	# Keep both targets alive after the authoritative blast so the following
	# client-visual projectile assertion exercises live enemies instead of being skipped.
	var test_target_health := agave_config.attack_damage * 3
	enemy_a.current_health = test_target_health
	enemy_b.current_health = test_target_health
	enemy_a.set_physics_process(false)
	enemy_b.set_physics_process(false)
	# This test verifies damage semantics, not audio playback. Avoid leaving
	# active AudioStreamPlaybackWAV objects when the headless SceneTree exits.
	enemy_a.hit_audio.stream = null
	enemy_b.hit_audio.stream = null

	var cannonball := CANNONBALL_SCENE.instantiate() as AgaveCannonball
	cannonball.position = Vector2(506, 500)
	test_root.add_child(cannonball)
	cannonball.setup(Vector2.RIGHT, agave_config.attack_damage, 180.0, 18.0, 1.0)
	cannonball.set_physics_process(false)
	await physics_frame
	var health_a := enemy_a.current_health
	var health_b := enemy_b.current_health
	var retained_explosion_query := cannonball.explosion_query
	var retained_explosion_targets := cannonball.explosion_targets
	cannonball._apply_explosion_damage(enemy_a)
	_expect(enemy_a.current_health == health_a - 25, "直接命中目标在AOE查询中只能承受25点伤害。")
	_expect(enemy_b.current_health == health_b - 25, "爆炸半径内第二目标必须承受25点伤害。")
	_expect(enemy_a.last_damage_taken == 25 and enemy_b.last_damage_taken == 25, "AOE伤害必须为25。")
	_expect(
		is_same(retained_explosion_query, cannonball.explosion_query)
		and is_same(retained_explosion_targets, cannonball.explosion_targets)
		and cannonball.explosion_targets.is_empty(),
		"池化黑球必须跨爆炸复用查询容器，并在伤害结算后立即释放目标引用。"
	)

	var visual_cannonball := CANNONBALL_SCENE.instantiate() as AgaveCannonball
	visual_cannonball.position = Vector2(506, 500)
	test_root.add_child(visual_cannonball)
	visual_cannonball.setup(
		Vector2.RIGHT,
		agave_config.attack_damage,
		180.0,
		18.0,
		1.0,
		false,
		4102
	)
	visual_cannonball.set_physics_process(false)
	await physics_frame
	var visual_health_a := enemy_a.current_health
	var visual_health_b := enemy_b.current_health
	visual_cannonball._apply_explosion_damage(enemy_a)
	_expect(
		enemy_a.current_health == visual_health_a and enemy_b.current_health == visual_health_b,
		"客户端视觉炮弹不得对直接目标或AOE目标造成伤害。"
	)
	visual_cannonball.queue_free()
	cannonball.queue_free()
	enemy_a.queue_free()
	enemy_b.queue_free()
	await process_frame


func _find_open_anchor_with_left_margin() -> Vector2i:
	var area := PlantSystem.DEFAULT_PLACEMENT_AREA
	for y in range(area.position.y, area.end.y - 1):
		for x in range(area.position.x + 5, area.end.x - 1):
			var anchor := Vector2i(x, y)
			var all_floor := true
			for cell in plant_system.get_footprint_cells(anchor, agave_config):
				var tile_data := tile_map.get_cell_tile_data(cell)
				if tile_data == null or tile_data.get_collision_polygons_count(0) > 0:
					all_floor = false
					break
			if all_floor:
				return anchor
	return Vector2i(9999, 9999)


func _set_player_cell(cell: Vector2i) -> void:
	_set_specific_player_cell(player, cell)


func _set_specific_player_cell(target_player: Player, cell: Vector2i) -> void:
	target_player.global_position = tile_map.to_global(tile_map.map_to_local(cell))


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
