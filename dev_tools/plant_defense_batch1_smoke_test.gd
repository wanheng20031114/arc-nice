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

var failures: Array[String] = []
var test_root: Node2D
var tile_map: TileMapLayer
var player: Player
var plant_system: PlantSystem
var plant_container: Node2D
var agave_config: PlantDefenseConfig


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


func _test_config_and_scene_contracts() -> void:
	_expect(agave_config != null and agave_config.is_valid(), "龙舌兰配置必须有效。")
	if agave_config == null:
		return
	_expect(PlantDefenseRegistry.get_all_configs().size() == 2, "植物注册表必须公开龙舌兰与橡木仓库。")
	_expect(agave_config.max_health == 2000, "龙舌兰生命值必须为2000。")
	_expect(
		agave_config.physical_defense == 10 and agave_config.magic_defense == 20,
		"龙舌兰必须拥有10物理防御与20法术防御。"
	)
	_expect(agave_config.attack_damage == 50, "龙舌兰炮弹伤害必须为50。")
	_expect(is_equal_approx(agave_config.attack_speed, 50.0), "龙舌兰攻速必须为50。")
	_expect(agave_config.supports_multiplayer, "龙舌兰必须继续支持多人权威放置。")
	_expect(is_equal_approx(agave_config.get_attack_interval(), 2.0), "龙舌兰攻击间隔必须为2秒。")
	_expect(is_equal_approx(agave_config.attack_range, 176.0), "龙舌兰索敌半径必须为176。")
	_expect(agave_config.footprint_size == Vector2i(2, 2), "植物必须占2×2格。")
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
	var ghost := tower_instance.get_node(
		"PlantPlacementController/PlantPlacementPreview/GhostSprite"
	) as Sprite2D
	_expect(
		ghost.texture_filter == CanvasItem.TEXTURE_FILTER_NEAREST,
		"植物放置幽灵必须使用邻近采样。"
	)
	tower_instance.free()

	var agave := agave_config.plant_scene.instantiate() as AgaveCannon
	_expect(agave != null, "龙舌兰场景根节点必须继承PlantDefense。")
	if agave != null:
		_expect(agave.collision_layer == 512, "植物必须位于PlantBody层。")
		_expect(
			(agave.get_node("BodySprite") as AnimatedSprite2D).texture_filter
			== CanvasItem.TEXTURE_FILTER_NEAREST,
			"植物身体动画必须使用邻近采样。"
		)
		_expect(
			(agave.get_node("CannonPivot/CannonSprite") as AnimatedSprite2D).texture_filter
			== CanvasItem.TEXTURE_FILTER_NEAREST,
			"植物开火动画必须使用邻近采样。"
		)
		var body_shape := agave.get_node("CollisionShape2D") as CollisionShape2D
		var rectangle := body_shape.shape as RectangleShape2D
		_expect(rectangle != null and rectangle.size == Vector2(28, 28), "植物接触碰撞必须为28×28。")
		var player_core := agave.get_node("PlayerCoreBody") as StaticBody2D
		var player_core_shape := player_core.get_node("CollisionShape2D") as CollisionShape2D
		var player_core_circle := player_core_shape.shape as CircleShape2D
		_expect(
			player_core.collision_layer == 1024
			and player_core.collision_mask == 2
			and player_core_circle != null
			and is_equal_approx(player_core_circle.radius, 7.0),
			"龙舌兰核心必须使用仅供玩家碰撞的TowerCore圆形体积。"
		)
		var target_shape := agave.get_node("TargetingArea/CollisionShape2D") as CollisionShape2D
		var target_circle := target_shape.shape as CircleShape2D
		_expect(target_circle != null and is_equal_approx(target_circle.radius, 176.0), "索敌Area半径必须为176。")
		var plant_health_bar := agave.get_node("HealthBar") as Control
		_expect(
			plant_health_bar != null
			and plant_health_bar.get_script() == PLANT_HEALTH_BAR_SCRIPT
			and plant_health_bar.size == Vector2(32, 5)
			and plant_health_bar.scale == Vector2.ONE,
			"龙舌兰必须实例化32×5且无缩放的独立植物血条。"
		)
		agave.free()

	var cannonball := CANNONBALL_SCENE.instantiate() as AgaveCannonball
	_expect(cannonball != null, "黑球炮弹场景必须可独立实例化。")
	if cannonball != null:
		_expect(
			(cannonball.get_node("CannonballSprite") as Sprite2D).texture_filter
			== CanvasItem.TEXTURE_FILTER_NEAREST,
			"黑球Sprite必须使用邻近采样。"
		)
		var flight_cast := cannonball.get_node("FlightCast") as ShapeCast2D
		var flight_circle := flight_cast.shape as CircleShape2D
		_expect(flight_circle != null and is_equal_approx(flight_circle.radius, 4.5), "黑球扫掠半径必须为4.5。")
		var blast_shape := cannonball.get_node("ExplosionQueryArea/CollisionShape2D") as CollisionShape2D
		var blast_circle := blast_shape.shape as CircleShape2D
		_expect(blast_circle != null and is_equal_approx(blast_circle.radius, 18.0), "黑球爆炸半径必须为18。")
		_expect(is_equal_approx(cannonball.speed, 180.0), "黑球飞行速度必须为180。")
		_expect(cannonball.damage == 50, "黑球炮弹默认伤害必须为50。")
		cannonball.free()


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
	blocker.collision_layer = 4
	blocker.collision_mask = 0
	var blocker_shape := CollisionShape2D.new()
	var blocker_rectangle := RectangleShape2D.new()
	blocker_rectangle.size = Vector2(8, 8)
	blocker_shape.shape = blocker_rectangle
	blocker.add_child(blocker_shape)
	test_root.add_child(blocker)
	blocker.global_position = plant_system.get_anchor_world_position(anchor, agave_config)
	await physics_frame
	_expect(not plant_system.is_placement_valid(anchor, agave_config), "实体重叠必须拒绝。")
	blocker.queue_free()
	await physics_frame

	var plant := plant_system.try_place(agave_config, anchor)
	_expect(plant != null, "合法交点必须成功放置龙舌兰。")
	if plant == null:
		return
	_expect(not plant_system.is_placement_valid(anchor, agave_config), "已占用footprint必须拒绝重复放置。")
	_expect(plant.footprint_cells.size() == 4, "植物实例必须保存四个占用格。")
	_expect(is_equal_approx((plant as AgaveCannon).attack_timer.wait_time, 2.0), "放置后攻击计时器必须严格为2秒。")
	_expect((plant as AgaveCannon).attack_timer.time_left > 1.8, "首次攻击必须等待完整攻击间隔。")
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
	_expect(not controller.valid_anchors.is_empty(), "放置阶段必须生成合法绿色交点。")
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
	enemy.global_position = Vector2(600, 600)
	var starting_health := plant.current_health
	var contact_damage := maxi(ENEMY_CONFIG.attack_damage - agave_config.physical_defense, 1)
	enemy._on_touch_damage_area_body_entered(plant)
	_expect(enemy._has_player_contact(), "接触植物后旧接触包装必须报告true。")
	_expect(plant.current_health == starting_health - contact_damage, "敌人接触必须立即结算一次物防后的伤害。")
	enemy._update_touch_damage(0.1)
	_expect(plant.current_health == starting_health - contact_damage, "接触冷却内不得重复伤害。")
	enemy._update_touch_damage(enemy.touch_damage_interval)
	_expect(plant.current_health == starting_health - contact_damage * 2, "冷却结束后必须再次结算防御后伤害。")
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
	_expect(
		plant_system.spawn_multiplayer_replica(
			&"oak_warehouse",
			anchor,
			requesting_player,
			4100,
			5000,
			5000,
			1
		) == null,
		"未实现库存同步的橡木仓库不得生成多人客户端副本。"
	)

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
	_expect(not replica.targeting_area.monitoring, "客户端植物副本不得运行本地索敌。")
	var replica_health_before := replica.current_health
	_expect(not replica.receive_damage(25), "客户端植物副本必须拒绝本地伤害。")
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
		controller.selection_hud.available_configs.size() == 1
		and controller.selection_hud.available_configs[0] == agave_config,
		"多人植物选择必须只公开显式支持联网的龙舌兰。"
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
	cannonball._apply_explosion_damage(enemy_a)
	_expect(enemy_a.current_health == health_a - 50, "直接命中目标在AOE查询中只能承受50点伤害。")
	_expect(enemy_b.current_health == health_b - 50, "爆炸半径内第二目标必须承受50点伤害。")
	_expect(enemy_a.last_damage_taken == 50 and enemy_b.last_damage_taken == 50, "AOE伤害必须为50。")

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
