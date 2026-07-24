extends SceneTree

const ARENA_SCENE := preload("res://scene/test_arena/test_grass_arena.tscn")
const TEST_CAMPAIGN := preload(
	"res://resources/config/campaigns/test_arena/singleplayer/campaign.tres"
)
const SLIME_CONFIG := preload("res://resources/config/enemies/slime.tres")
const GOLDEN_SLIME_CONFIG := preload(
	"res://resources/config/enemies/slime_golden.tres"
)
const FIRE_SLIME_CONFIG := preload(
	"res://resources/config/enemies/slime_fire.tres"
)
const FROST_SLIME_CONFIG := preload(
	"res://resources/config/enemies/slime_frost.tres"
)
const ORDERED_SLIME_CONFIGS := [
	SLIME_CONFIG,
	GOLDEN_SLIME_CONFIG,
	FIRE_SLIME_CONFIG,
	FROST_SLIME_CONFIG,
]
const RED_GATE_COORDS := Vector2i(0, 0)
const BLUE_GATE_COORDS := Vector2i(0, 3)

var failures: Array[String] = []
var arena: TestGrassArena


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	arena = ARENA_SCENE.instantiate() as TestGrassArena
	_expect(arena != null, "草地测试场景必须实例化为 TestGrassArena。")
	if arena == null:
		_finish()
		return
	arena.auto_start_waves = false
	root.add_child(arena)
	current_scene = arena
	await process_frame
	await process_frame

	_test_campaign()
	_test_arena_layout()
	_test_navigation()
	await _test_plant_shortcut()
	await _test_manual_day_night()

	arena.queue_free()
	await process_frame
	await process_frame
	_finish()


func _test_campaign() -> void:
	_expect(arena.singleplayer_campaign == TEST_CAMPAIGN, "测试场景必须绑定独立单人 Campaign。")
	_expect(
		TEST_CAMPAIGN.validate_campaign().is_empty(),
		"草地测试 Campaign 必须通过流程校验。"
	)
	var waves := TEST_CAMPAIGN.get_waves()
	_expect(waves.size() == 1, "测试 Campaign 当前必须只包含第一波。")
	if waves.size() != 1:
		return
	var wave := waves[0]
	_expect(wave.get_total_enemy_count() == 1000, "第一波必须正好包含1000个敌人。")
	_expect(wave.enemy_entries.size() == 4, "第一波必须包含四种史莱姆条目。")
	if wave.enemy_entries.size() == 4:
		for entry_index in range(ORDERED_SLIME_CONFIGS.size()):
			var entry := wave.enemy_entries[entry_index]
			_expect(
				entry.enemy_config == ORDERED_SLIME_CONFIGS[entry_index],
				"第一波史莱姆条目必须按基础、黄金、火焰、寒冰排序。"
			)
			_expect(entry.count == 250, "四种史莱姆必须各生成250只。")
	_expect(is_equal_approx(wave.spawn_interval, 3.0), "史莱姆生成间隔必须为3秒。")
	_expect(wave.spawn_count_per_tick == 1, "每次生成必须只有1只史莱姆。")
	_expect(wave.max_alive_enemies == 1000, "测试波次不得被旧的20只场上上限暂停。")
	_expect(wave.spawn_point_mask == 3, "第一波只能使用右侧两个红门出生点。")
	_expect(
		wave.get_enabled_spawn_point_names() == [&"Spawn1", &"Spawn2"],
		"第一波出生点必须精确解析为 Spawn1 和 Spawn2。"
	)

	arena.call("_build_wave_spawn_queue", wave)
	_expect(arena.pending_enemy_configs.size() == 1000, "运行时生成队列必须正好构建1000项。")
	for queue_index in range(arena.pending_enemy_configs.size()):
		_expect(
			arena.pending_enemy_configs[queue_index]
			== ORDERED_SLIME_CONFIGS[queue_index % ORDERED_SLIME_CONFIGS.size()],
			"运行时队列必须严格循环基础、黄金、火焰、寒冰。"
		)
	arena.call("_clear_pending_enemy_spawn_queue")


func _test_arena_layout() -> void:
	var terrain := arena.dual_grid_terrain
	var world_layer := terrain.world_map_layer
	_expect(
		world_layer.get_used_rect() == TestGrassArena.GRASS_RECT,
		"语义草地范围必须精确为16×16。"
	)
	var grass_cells := world_layer.get_used_cells()
	_expect(grass_cells.size() == 256, "16×16草地必须包含256个语义格。")
	for cell in grass_cells:
		_expect(
			terrain.get_terrain_type(cell) == DualGridTilemap.TerrainType.GRASS,
			"草地区域内不得出现非草地地形。"
		)

	_expect(
		arena.ground_tile_map_layer.get_used_rect() == TestGrassArena.GRASS_RECT,
		"透明导航边界必须与16×16草地一致。"
	)
	_expect(
		arena.ground_tile_map_layer.get_used_cells().size() == 2,
		"导航边界只能保留两个无碰撞哨兵瓦片。"
	)

	var overlay := arena.overlay_tile_map_layer
	_expect(overlay.get_used_cells().size() == 4, "场景必须只包含两个蓝门和两个红门。")
	for cell in TestGrassArena.BLUE_GATE_CELLS:
		_expect(
			overlay.get_cell_atlas_coords(cell) == BLUE_GATE_COORDS,
			"左侧双门必须使用蓝色 home_gate 图块。"
		)
	for cell in TestGrassArena.RED_GATE_CELLS:
		_expect(
			overlay.get_cell_atlas_coords(cell) == RED_GATE_COORDS,
			"右侧双门必须使用红色出生门图块。"
		)

	_expect(
		arena.home_gate_controller.get_home_gate_cells() == TestGrassArena.BLUE_GATE_CELLS,
		"HomeGateController 必须识别左侧两个蓝门。"
	)
	_expect(
		arena.home_gate_controller.get_objective_targets().size() == 1,
		"相邻的两个蓝门必须形成一个居中的防守目标。"
	)
	_expect(arena.plant_system.placement_area == TestGrassArena.GRASS_RECT, "植物放置范围必须覆盖完整草地。")

	var spawn1 := arena.get_node("EnemySpawnPoints/Spawn1") as Marker2D
	var spawn2 := arena.get_node("EnemySpawnPoints/Spawn2") as Marker2D
	_expect(spawn1.position == Vector2(248, 120), "Spawn1 必须位于右侧上方红门。")
	_expect(spawn2.position == Vector2(248, 136), "Spawn2 必须位于右侧下方红门。")


func _test_navigation() -> void:
	_expect(arena.grid_pathfinder.is_built, "16×16测试场景必须成功构建寻路网格。")
	var targets := arena.home_gate_controller.get_objective_targets()
	if targets.is_empty():
		return
	for spawn_name in [&"Spawn1", &"Spawn2"]:
		var spawn := arena.get_node("EnemySpawnPoints/%s" % spawn_name) as Marker2D
		var path: PackedVector2Array = arena.grid_pathfinder.call(
			"get_global_path",
			spawn.global_position,
			targets[0].global_position
		)
		_expect(not path.is_empty(), "%s 必须能寻路到左侧蓝门。" % spawn_name)


func _test_plant_shortcut() -> void:
	var controller := arena.plant_placement_controller
	_expect(controller != null, "测试场景必须保留 PlantPlacementController。")
	_expect(
		controller != null and controller.is_processing_unhandled_input(),
		"单人测试场景必须允许植物放置输入。"
	)
	if controller == null:
		return

	var press := InputEventAction.new()
	press.action = &"plant"
	press.pressed = true
	Input.parse_input_event(press)
	await process_frame
	await process_frame
	_expect(controller.is_selecting(), "plant动作（默认T键）必须打开免费植物选择。")
	_expect(controller.selection_hud.is_open(), "T键选择界面必须实际可见。")
	controller.cancel_placement()
	await process_frame
	_expect(not controller.is_active(), "取消选择后植物放置控制器必须回到空闲状态。")

	var has_valid_grass_anchor := false
	for config in arena.plant_system.get_available_configs():
		if not arena.plant_system.get_valid_anchors(config).is_empty():
			has_valid_grass_anchor = true
			break
	_expect(has_valid_grass_anchor, "玩家出生位置附近必须至少存在一个可放置草地锚点。")


func _test_manual_day_night() -> void:
	var controller := arena.day_night_controller
	controller.transition_duration = 0.0
	_expect(not controller.is_night(), "测试场景必须固定从白天开始。")
	arena.transition_world_to_night(0.0)
	_expect(not controller.is_night(), "波次自动入夜入口在测试场景中必须无效。")

	await _send_l_key()
	_expect(controller.is_night(), "按L必须切换到夜晚。")
	_expect(arena.manual_night_enabled, "L切换后必须记录夜晚目标状态。")
	_expect("夜晚" in arena.test_controls_hint.text, "操作提示必须同步显示夜晚状态。")
	arena.transition_world_to_day(0.0)
	_expect(controller.is_night(), "流程自动回昼入口不得覆盖玩家选择的夜晚。")

	await _send_l_key()
	_expect(not controller.is_night(), "再次按L必须切换回白天。")
	_expect(not arena.manual_night_enabled, "再次按L后必须记录白天目标状态。")


func _send_l_key() -> void:
	var press := InputEventKey.new()
	press.physical_keycode = KEY_L
	press.pressed = true
	Input.parse_input_event(press)
	await process_frame
	var release := InputEventKey.new()
	release.physical_keycode = KEY_L
	release.pressed = false
	Input.parse_input_event(release)
	await process_frame


func _finish() -> void:
	if failures.is_empty():
		print("TEST_GRASS_ARENA_SMOKE_TEST_OK")
		quit()
		return
	for failure in failures:
		push_error(failure)
	quit(1)


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
