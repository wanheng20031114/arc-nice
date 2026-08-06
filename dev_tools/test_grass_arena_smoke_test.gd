extends SceneTree

const ARENA_SCENE := preload("res://scene/game_modes/tower_defense/test_arenas/test_grass_arena.tscn")
const TEST_CAMPAIGN := preload(
	"res://resources/config/campaigns/test_arena/singleplayer/campaign.tres"
)
const MULTIPLAYER_TEST_CAMPAIGN := preload(
	"res://resources/config/campaigns/test_arena/multiplayer/campaign.tres"
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
const GREEN_SLIME_CONFIG := preload(
	"res://resources/config/enemies/slime_green.tres"
)
const WOOD_PROCESSING_STATION_CONFIG := preload(
	"res://resources/config/plant_defense/wood_processing_station.tres"
)
const ORDERED_SLIME_CONFIGS := [
	SLIME_CONFIG,
	GOLDEN_SLIME_CONFIG,
	FIRE_SLIME_CONFIG,
	FROST_SLIME_CONFIG,
	GREEN_SLIME_CONFIG,
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
	_test_entry_announcement()
	_test_navigation()
	await _test_plant_shortcut()
	await _test_delete_plant_shortcut()
	await _test_manual_day_night()

	arena.queue_free()
	await process_frame
	await process_frame
	await _test_deferred_entry_announcement()
	_finish()


func _test_entry_announcement() -> void:
	var announcement := arena.day_phase_announcement
	_expect(not arena.day_phase_announcements_enabled, "P1A必须禁用正式昼夜阶段报幕。")
	_expect(
		announcement != null
		and arena.test_entry_announcement_text == "测试场景 P1A"
		and is_equal_approx(
			arena.progression_config.initial_preparation_seconds,
			3.0
		)
		and announcement.presentation_count == 0
		and not announcement.is_presenting(),
		"P1A必须保留完整三秒倒计时，并在波次开始前隐藏入场报幕。"
	)


func _test_deferred_entry_announcement() -> void:
	var deferred_arena := ARENA_SCENE.instantiate() as TestGrassArena
	deferred_arena.auto_start_waves = false
	deferred_arena.defer_runtime_activation()
	root.add_child(deferred_arena)
	await process_frame
	await process_frame
	_expect(
		deferred_arena.day_phase_announcement.presentation_count == 0,
		"P1A加载尚未完成时不得在遮罩后提前播放报幕。"
	)
	deferred_arena.activate_runtime()
	await process_frame
	await process_frame
	_expect(
		deferred_arena.day_phase_announcement.presentation_count == 0,
		"P1A运行时激活后仍必须先等待三声倒计时。"
	)
	var first_step := deferred_arena.call("_get_start_flow_step") as FlowStepConfig
	var countdown_audio := deferred_arena.countdown_audio
	deferred_arena.call("_enter_pre_flow_step", first_step)
	_expect(
		deferred_arena.countdown_seconds == 3
		and countdown_audio.playing
		and deferred_arena.day_phase_announcement.presentation_count == 0,
		"P1A倒计时必须从3开始播放第一声，且不得提前显示报幕。"
	)
	for expected_seconds in [2, 1]:
		countdown_audio.stop()
		deferred_arena.call("_on_state_timer_timeout")
		_expect(
			deferred_arena.countdown_seconds == expected_seconds
			and countdown_audio.playing
			and deferred_arena.day_phase_announcement.presentation_count == 0,
			"P1A倒计时的3、2、1三声结束前不得显示报幕。"
		)
	countdown_audio.stop()
	deferred_arena.call("_on_state_timer_timeout")
	_expect(
		deferred_arena.wave_state == GameRuntimeBase.WaveState.WAVE_ACTIVE
		and deferred_arena.day_phase_announcement.presentation_count == 1
		and deferred_arena.day_phase_announcement.current_text == "测试场景 P1A"
		and deferred_arena.day_phase_announcement.is_presenting(),
		"P1A必须在完整三声倒计时后才显示一次入场大字并播放咚声。"
	)
	var duplicate_handled := bool(
		deferred_arena.call("_announce_wave_phase_start", 1)
	)
	_expect(
		duplicate_handled
		and deferred_arena.day_phase_announcement.presentation_count == 1,
		"重复的首波状态必须由P1A报幕去重，且不得补播普通开战音效。"
	)
	deferred_arena.activate_runtime()
	await process_frame
	_expect(
		deferred_arena.day_phase_announcement.presentation_count == 1,
		"重复激活P1A运行时不得重播入场报幕。"
	)
	deferred_arena.day_phase_announcement.hide_announcement()
	deferred_arena.queue_free()
	await process_frame
	await process_frame


func _test_campaign() -> void:
	_expect(arena.singleplayer_campaign == TEST_CAMPAIGN, "测试场景必须绑定独立单人 Campaign。")
	_expect(
		arena.multiplayer_campaign == MULTIPLAYER_TEST_CAMPAIGN,
		"测试场景必须绑定独立多人 Campaign。"
	)
	_expect(
		TEST_CAMPAIGN.validate_campaign().is_empty(),
		"草地测试 Campaign 必须通过流程校验。"
	)
	_expect(
		MULTIPLAYER_TEST_CAMPAIGN.validate_campaign().is_empty(),
		"草地测试多人 Campaign 必须通过流程校验。"
	)
	var waves := TEST_CAMPAIGN.get_waves()
	_expect(waves.size() == 1, "测试 Campaign 当前必须只包含第一波。")
	if waves.size() != 1:
		return
	var wave := waves[0]
	_expect(wave.get_total_enemy_count() == 1000, "第一波必须正好包含1000个敌人。")
	_expect(wave.enemy_entries.size() == 5, "第一波必须包含五种史莱姆条目。")
	_expect(
		wave.spawn_order == WaveConfig.SpawnOrder.SHUFFLED,
		"P1A 必须保留默认的随机打乱生成顺序。"
	)
	if wave.enemy_entries.size() == ORDERED_SLIME_CONFIGS.size():
		for entry_index in range(ORDERED_SLIME_CONFIGS.size()):
			var entry := wave.enemy_entries[entry_index]
			_expect(
				entry.enemy_config == ORDERED_SLIME_CONFIGS[entry_index],
				"第一波史莱姆条目必须按基础、黄金、火焰、寒冰、绿色排序。"
			)
			_expect(entry.count == 200, "五种史莱姆必须各生成200只。")
	_expect(is_equal_approx(wave.spawn_interval, 3.0), "史莱姆生成间隔必须为3秒。")
	_expect(wave.spawn_count_per_tick == 1, "每次生成必须只有1只史莱姆。")
	_expect(wave.max_alive_enemies == 1000, "测试波次不得被旧的20只场上上限暂停。")
	_expect(wave.spawn_point_mask == 3, "第一波只能使用右侧两个红门出生点。")
	_expect(
		wave.get_enabled_spawn_point_names() == [&"Spawn1", &"Spawn2"],
		"第一波出生点必须精确解析为 Spawn1 和 Spawn2。"
	)
	var multiplayer_waves := MULTIPLAYER_TEST_CAMPAIGN.get_waves()
	_expect(
		multiplayer_waves.size() == 1
		and multiplayer_waves[0].get_total_enemy_count() == 1000,
		"P1A 多人 Campaign 必须保持精确1000只敌人的测试压力。"
	)
	_expect(
		is_zero_approx(
			arena.progression_config.enemy_count_per_extra_player_ratio
		)
		and arena.progression_config.get_scaled_enemy_count(1000, 8) == 1000,
		"P1A 测试敌人数不得随多人房间人数缩放。"
	)
	_expect(
		arena.supports_test_arena_manual_night_sync(),
		"P1A 必须声明多人手动昼夜同步能力。"
	)

	arena.random_generator.seed = 0x5A17
	arena.call("_build_wave_spawn_queue", wave)
	_expect(arena.pending_enemy_configs.size() == 1000, "运行时生成队列必须正好构建1000项。")
	_expect(
		arena.pending_enemy_xirang_kill_rewards.size() == 1000,
		"塔防运行时的敌人与息壤奖励队列必须严格等长。"
	)
	var queue_counts: Dictionary = {}
	var remains_strict_cycle := true
	for queue_index in range(arena.pending_enemy_configs.size()):
		var queued_config := arena.pending_enemy_configs[queue_index]
		_expect(
			arena.pending_enemy_xirang_kill_rewards[queue_index]
			== queued_config.xirang_kill_reward,
			"塔防队列洗牌后，敌人配置与继承的息壤奖励必须保持配对。"
		)
		queue_counts[queued_config] = int(queue_counts.get(queued_config, 0)) + 1
		if queued_config != ORDERED_SLIME_CONFIGS[queue_index % ORDERED_SLIME_CONFIGS.size()]:
			remains_strict_cycle = false
	for expected_config in ORDERED_SLIME_CONFIGS:
		_expect(
			int(queue_counts.get(expected_config, 0)) == 200,
			"随机队列必须包含每种史莱姆各200只，且必须包含绿色史莱姆。"
		)
	_expect(not remains_strict_cycle, "测试场景生成队列必须随机混合，不能继续固定轮询。")
	arena.call("_clear_pending_enemy_spawn_queue")
	_expect(
		arena.pending_enemy_configs.is_empty()
		and arena.pending_enemy_xirang_kill_rewards.is_empty(),
		"塔防运行时清理刷怪队列时必须同时释放敌人与奖励数组。"
	)


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

	var zhuangfangyi := arena.get_node("ZhuangfangyiMerchant") as ZhuangfangyiMerchant
	var luoxi := arena.get_node("LuoxiMerchant") as LuoxiMerchant
	_expect(
		zhuangfangyi != null
		and zhuangfangyi.visible
		and zhuangfangyi.position == Vector2(96, 224),
		"P1A 必须在草地底部放置可见的庄方宜。"
	)
	_expect(
		luoxi != null
		and luoxi.visible
		and luoxi.position == Vector2(154, 224),
		"P1A 必须按正式场景的横向布局在庄方宜右侧放置洛茜。"
	)
	_expect(
		arena.maximum_base_health == TestGrassArena.TEST_BASE_HEALTH
		and arena.current_base_health == TestGrassArena.TEST_BASE_HEALTH
		and arena.current_base_health == 1000,
		"P1A 核心必须以1000/1000生命进入测试。"
	)


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


func _test_delete_plant_shortcut() -> void:
	var plant_system := arena.plant_system
	var near_anchors := _find_valid_anchors_in_distance_band(0.5, 3.0, 2)
	_expect(near_anchors.size() == 2, "测试玩家3格内必须能放置至少两株植物。")
	if near_anchors.size() < 2:
		return

	var nearby_plants: Array[PlantDefense] = []
	for anchor in near_anchors:
		var placed := plant_system.try_place(WOOD_PROCESSING_STATION_CONFIG, anchor)
		_expect(placed != null, "Del快捷键测试必须成功放置近处植物。")
		if placed != null:
			nearby_plants.append(placed)
	if nearby_plants.size() != 2:
		plant_system.clear_all_plants()
		await process_frame
		return

	var far_anchors := _find_valid_anchors_in_distance_band(3.01, 4.0, 1)
	_expect(far_anchors.size() == 1, "测试玩家3格外、4格内必须存在对照锚点。")
	if far_anchors.is_empty():
		plant_system.clear_all_plants()
		await process_frame
		return
	var far_plant := plant_system.try_place(
		WOOD_PROCESSING_STATION_CONFIG,
		far_anchors[0]
	)
	_expect(far_plant != null, "Del快捷键测试必须成功放置范围外对照植物。")
	if far_plant == null:
		plant_system.clear_all_plants()
		await process_frame
		return

	await _send_key(KEY_DELETE)
	for nearby_plant in nearby_plants:
		_expect(
			nearby_plant.current_health == 0
			and nearby_plant.is_dead
			and nearby_plant.is_removing,
			"按Del必须直接摧毁玩家3格内的全部植物。"
		)
		_expect(
			not plant_system.plant_footprints.has(nearby_plant),
			"被Del摧毁的植物必须立即释放占格。"
		)
	_expect(
		far_plant.current_health > 0
		and not far_plant.is_dead
		and not far_plant.is_removing,
		"按Del不得摧毁玩家3格半径之外的植物。"
	)
	_expect(
		"Del：摧毁周围3格植物" in arena.test_controls_hint.text,
		"测试提示必须展示Del快捷键。"
	)
	plant_system.clear_all_plants()
	await process_frame


func _find_valid_anchors_in_distance_band(
	minimum_distance: float,
	maximum_distance: float,
	maximum_count: int
) -> Array[Vector2i]:
	var result: Array[Vector2i] = []
	for anchor in arena.plant_system.get_valid_anchors(WOOD_PROCESSING_STATION_CONFIG):
		var distance := _get_anchor_distance_from_player(anchor)
		if distance < minimum_distance or distance > maximum_distance:
			continue
		result.append(anchor)
		if result.size() >= maximum_count:
			break
	return result


func _get_anchor_distance_from_player(anchor: Vector2i) -> float:
	var tile_map := arena.plant_system.ground_tile_map
	var tile_size := Vector2(tile_map.tile_set.tile_size).abs()
	var player_local := tile_map.to_local(arena.player.global_position)
	var anchor_world := arena.plant_system.get_anchor_world_position(
		anchor,
		WOOD_PROCESSING_STATION_CONFIG
	)
	var anchor_local := tile_map.to_local(anchor_world)
	return Vector2(
		(anchor_local.x - player_local.x) / tile_size.x,
		(anchor_local.y - player_local.y) / tile_size.y
	).length()


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
	await _send_key(KEY_L)


func _send_key(physical_keycode: Key) -> void:
	var press := InputEventKey.new()
	press.physical_keycode = physical_keycode
	press.pressed = true
	Input.parse_input_event(press)
	await process_frame
	var release := InputEventKey.new()
	release.physical_keycode = physical_keycode
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
