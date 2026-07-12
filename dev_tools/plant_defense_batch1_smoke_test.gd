extends SceneTree

const TOWER_SCENE := preload("res://scene/game_tower_defense.tscn")
const PLAYER_SCENE := preload("res://scene/player/weishidaier/player_weishidaier.tscn")
const PLANT_SYSTEM_SCRIPT := preload("res://scene/plant_defense/plant_system.gd")
const PLACEMENT_CONTROLLER_SCENE := preload(
	"res://scene/plant_defense/plant_placement_controller.tscn"
)
const CANNONBALL_SCENE := preload("res://scene/plant_defense/agave_cannonball.tscn")
const ENEMY_CONFIG := preload("res://resources/config/enemies/yuanshi_insect_basic.tres")

var failures: Array[String] = []
var test_root: Node2D
var tile_map: TileMapLayer
var player: Player
var plant_system: PlantSystem
var plant_container: Node2D
var agave_config: PlantDefenseConfig


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	_build_fixture()
	await physics_frame
	_test_config_and_scene_contracts()
	await _test_grid_and_occupancy_rules()
	await _test_realtime_selection_and_cancel()
	await _test_enemy_contact_and_release()
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
	_expect(agave_config.max_health == 200, "龙舌兰生命值必须为200。")
	_expect(agave_config.attack_damage == 10, "龙舌兰攻击力必须为10。")
	_expect(is_equal_approx(agave_config.attack_speed, 50.0), "龙舌兰攻速必须为50。")
	_expect(is_equal_approx(agave_config.get_attack_interval(), 2.0), "龙舌兰攻击间隔必须为2秒。")
	_expect(is_equal_approx(agave_config.attack_range, 160.0), "龙舌兰索敌半径必须为160。")
	_expect(agave_config.footprint_size == Vector2i(2, 2), "植物必须占2×2格。")
	_expect(
		ProjectSettings.get_setting("layer_names/2d_physics/layer_10") == "PlantBody",
		"物理层10必须命名为PlantBody。"
	)
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
		var target_shape := agave.get_node("TargetingArea/CollisionShape2D") as CollisionShape2D
		var target_circle := target_shape.shape as CircleShape2D
		_expect(target_circle != null and is_equal_approx(target_circle.radius, 160.0), "索敌Area半径必须为160。")
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
		cannonball.free()


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
	enemy._on_touch_damage_area_body_entered(plant)
	_expect(enemy._has_player_contact(), "接触植物后旧接触包装必须报告true。")
	_expect(plant.current_health == starting_health - ENEMY_CONFIG.attack_damage, "敌人接触必须立即伤害植物一次。")
	enemy._update_touch_damage(0.1)
	_expect(plant.current_health == starting_health - ENEMY_CONFIG.attack_damage, "接触冷却内不得重复伤害。")
	enemy._update_touch_damage(enemy.touch_damage_interval)
	_expect(plant.current_health == starting_health - ENEMY_CONFIG.attack_damage * 2, "冷却结束后必须再次伤害。")
	enemy.velocity = Vector2(30, 0)
	enemy._move_until_player_contact()
	_expect(enemy.velocity == Vector2.ZERO, "接触植物时敌人必须停止而不改A*。")

	var occupied_cell := plant.footprint_cells[0]
	plant.receive_damage(99999, enemy)
	_expect(not plant_system.is_cell_occupied(occupied_cell), "植物死亡必须立即释放四格占用。")
	_expect(not enemy._has_player_contact(), "植物死亡必须立即从敌人接触表移除。")
	enemy.queue_free()
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
	enemy_a.set_physics_process(false)
	enemy_b.set_physics_process(false)

	var cannonball := CANNONBALL_SCENE.instantiate() as AgaveCannonball
	cannonball.position = Vector2(506, 500)
	test_root.add_child(cannonball)
	cannonball.setup(Vector2.RIGHT, 10, 180.0, 18.0, 1.0)
	cannonball.set_physics_process(false)
	await physics_frame
	var health_a := enemy_a.current_health
	var health_b := enemy_b.current_health
	cannonball._apply_explosion_damage(enemy_a)
	_expect(enemy_a.current_health == health_a - 10, "直接命中目标在AOE查询中只能承伤一次。")
	_expect(enemy_b.current_health == health_b - 10, "爆炸半径内第二目标必须承伤一次。")
	_expect(enemy_a.last_damage_taken == 10 and enemy_b.last_damage_taken == 10, "AOE伤害必须为10。")
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
	player.global_position = tile_map.to_global(tile_map.map_to_local(cell))


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
