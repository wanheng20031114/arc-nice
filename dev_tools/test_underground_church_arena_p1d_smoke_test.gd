extends SceneTree

const ARENA_SCENE := preload(
	"res://scene/game_modes/tower_defense/test_arenas/test_grass_arena_p1d.tscn"
)
const SINGLEPLAYER_CAMPAIGN := preload(
	"res://resources/config/campaigns/test_arena/p1d/singleplayer/campaign.tres"
)
const MULTIPLAYER_CAMPAIGN := preload(
	"res://resources/config/campaigns/test_arena/p1d/multiplayer/campaign.tres"
)
const CARDBOARD_CONFIG := preload(
	"res://resources/config/enemies/cardboard_monster.tres"
)
const BACKGROUND_PATH := (
	"res://resources/texture/rogue_combat/underground_church/"
	+ "underground_church_background.png"
)
const EXPECTED_WORLD_RECT := Rect2i(0, -2, 20, 20)
const EXPECTED_NAVIGATION_BLOCKED_CELLS := 212
const EXPECTED_ENEMY_COUNT := 1000
const EXPECTED_SPAWN_POSITIONS: Dictionary[StringName, Vector2] = {
	&"Spawn1": Vector2(267, 73),
	&"Spawn2": Vector2(269, 119),
	&"Spawn3": Vector2(270, 182),
}
const EXPECTED_HOME_GATE_CELLS: Array[Vector2i] = [
	Vector2i(2, 7),
	Vector2i(2, 8),
]
const CARDBOARD_HALF_EXTENTS := Vector2(7, 6)
const EXPECTED_WALL_SHAPE_COUNT := 10

var failures: Array[String] = []


func _initialize() -> void:
	call_deferred(&"_run")


func _run() -> void:
	var arena := ARENA_SCENE.instantiate() as TestGrassArena
	_expect(arena != null, "P1D 必须实例化为 TestGrassArena。")
	if arena == null:
		_finish()
		return
	var authored_camera := arena.get_node("Camera2D") as Camera2D
	_expect(
		authored_camera.position.is_equal_approx(Vector2(160, 128)),
		"P1D authored 相机必须位于地下教堂画面中心。"
	)
	arena.auto_start_waves = false
	var fate := arena.get_node_or_null("FateCoordinator") as FateCoordinator
	if fate != null:
		fate.elite_enemy_config_loads_requested = true
	root.add_child(arena)
	current_scene = arena
	await process_frame
	await process_frame

	_test_scene_contract(arena)
	_test_authored_map_contract(arena)
	_test_torch_layout_contract(arena)
	_test_navigation_wall_contract(arena)
	_test_spawn_and_home_routes(arena)
	_test_campaign_contract(SINGLEPLAYER_CAMPAIGN, "单人")
	_test_campaign_contract(MULTIPLAYER_CAMPAIGN, "多人")

	current_scene = null
	arena.queue_free()
	await process_frame
	await process_frame
	_finish()


func _test_scene_contract(arena: TestGrassArena) -> void:
	var definition := GameModeCatalog.get_definition(
		GameModeCatalog.MODE_TEST_ARENA_P1D
	)
	_expect(
		definition != null
		and definition.mode_id == 7
		and definition.wire_key == &"test_arena_p1d",
		"P1D 必须使用稳定 mode=7、wire=test_arena_p1d。"
	)
	_expect(
		arena.mode_definition == definition
		and arena.singleplayer_campaign == SINGLEPLAYER_CAMPAIGN
		and arena.multiplayer_campaign == MULTIPLAYER_CAMPAIGN,
		"P1D 必须绑定自己的单人/多人 Campaign。"
	)
	_expect(
		arena.test_scene_label == "P1D"
		and arena.test_entry_announcement_text == "测试场景 P1D"
		and arena.test_environment_title == "地下教会测试场景"
		and not arena.day_phase_announcements_enabled
		and arena.sandbox_free_building_enabled,
		"P1D 必须保留 P1 测试运行时，并显示地下教堂环境标题。"
	)
	_expect(
		arena.test_controls_hint.text.begins_with(
			"地下教会测试场景 P1D｜当前：白天"
		),
		"P1D 控制提示不得继续显示草地环境名。"
	)
	_expect(
		is_zero_approx(arena.progression_config.enemy_count_per_extra_player_ratio)
		and arena.progression_config.get_scaled_enemy_count(
			EXPECTED_ENEMY_COUNT,
			8
		) == EXPECTED_ENEMY_COUNT,
		"P1D 的1000只纸箱怪不得随多人数量放大。"
	)


func _test_authored_map_contract(arena: TestGrassArena) -> void:
	var background := arena.get_node_or_null(
		"UndergroundChurchBackground"
	) as Sprite2D
	_expect(background != null, "P1D 必须 authored 地复用地下教堂背景。")
	if background != null:
		_expect(
			background.texture != null
			and background.texture.resource_path == BACKGROUND_PATH
			and background.texture.get_width() == 320
			and background.texture.get_height() == 320,
			"P1D 必须直接使用320×320地下教堂正式 PNG。"
		)
		_expect(
			background.position.is_equal_approx(Vector2(160, 128))
			and background.scale.is_equal_approx(Vector2.ONE)
			and background.z_index == -10
			and background.texture_filter
			== CanvasItem.TEXTURE_FILTER_NEAREST,
			"P1D 背景必须原生比例、nearest 并对齐相机中心。"
		)
	var ground := arena.get_node("GroundTileMapLayer") as TileMapLayer
	_expect(
		not ground.visible
		and not ground.collision_enabled
		and not ground.navigation_enabled
		and not ground.occlusion_enabled,
		"P1D 导航层只能提供隐藏的 GridPathfinder 数据。"
	)
	_expect(
		ground.get_used_rect() == EXPECTED_WORLD_RECT
		and ground.get_used_cells().size() == 400,
		"P1D 隐藏导航必须严格覆盖 Rect2i(0,-2,20,20) 的400格。"
	)
	var terrain := arena.get_node("DualGridTerrain") as DualGridTilemap
	_expect(not terrain.visible, "P1D 必须隐藏旧草地视觉层。")
	_expect(
		terrain.world_map_layer.get_used_rect() == EXPECTED_WORLD_RECT
		and terrain.world_map_layer.get_used_cells().size() == 400,
		"P1D 语义地形必须同步扩展为20×20，而非沿用16×16。"
	)
	for cell in terrain.world_map_layer.get_used_cells():
		_expect(
			terrain.get_terrain_type(cell) == DualGridTilemap.TerrainType.GRASS,
			"P1D 语义格 %s 必须维持可自由建造的草地语义。" % cell
		)
	var overlay := arena.get_node("OverlayTileMapLayer") as TileMapLayer
	_expect(not overlay.visible, "地下教堂完整背景已含门洞，逻辑门层必须隐藏。")
	var home_controller := arena.get_node(
		"HomeGateController"
	) as HomeGateController
	_expect(
		home_controller.get_home_gate_cells() == EXPECTED_HOME_GATE_CELLS,
		"P1D 逻辑核心门必须 authored 在墙内侧的(2,7)/(2,8)。"
	)


func _test_torch_layout_contract(arena: TestGrassArena) -> void:
	var layout := arena.get_node_or_null(
		"UndergroundChurchWallTorchLayout"
	) as Node2D
	_expect(layout != null, "P1D 必须复用正式地下教会三火把布局。")
	if layout == null:
		return
	var expected: Dictionary[StringName, Array] = {
		&"UpperLeftTorch": [Vector2(104, 52), 1.35],
		&"UpperRightTorch": [Vector2(216, 52), 1.55],
		&"LowerTorch": [Vector2(160, 256), 1.75],
	}
	_expect(layout.get_child_count() == 3, "P1D 必须恰好实例化三盏火把。")
	for torch_name in expected:
		var torch := layout.get_node_or_null(
			NodePath(String(torch_name))
		) as UndergroundChurchWallTorch
		var authored: Array = expected[torch_name]
		_expect(
			torch != null
			and torch.position.is_equal_approx(authored[0] as Vector2)
			and is_equal_approx(
				torch.half_cycle_seconds,
				float(authored[1]),
			),
			"P1D 火把 %s 必须保持正式布局坐标和异步周期。" % torch_name,
		)
		if torch != null:
			_expect(
				is_zero_approx(torch.night_light.energy),
				"P1D 默认白天时火把 %s 的光源必须关闭。" % torch_name,
			)


func _test_navigation_wall_contract(arena: TestGrassArena) -> void:
	var ground := arena.get_node("GroundTileMapLayer") as TileMapLayer
	var wall := arena.get_node_or_null("WorldBounds/Wall") as StaticBody2D
	_expect(wall != null, "P1D 必须复用 game02 的 authored Wall。")
	if wall == null:
		return
	_expect(
		(wall.collision_layer & 1) != 0,
		"P1D Wall 必须保留 World 物理层1。"
	)
	var shape_count := 0
	for child in wall.get_children():
		var collision_shape := child as CollisionShape2D
		_expect(
			collision_shape != null
			and not collision_shape.disabled
			and collision_shape.shape != null,
			"P1D Wall 只能直接包含启用的 CollisionShape2D。"
		)
		if collision_shape != null:
			shape_count += 1
	_expect(
		shape_count == EXPECTED_WALL_SHAPE_COUNT,
		"P1D 必须完整复用 game02 的10个墙体形状。"
	)
	var point_probe := CircleShape2D.new()
	point_probe.radius = 0.01
	var blocked_cell_count := 0
	for y in range(EXPECTED_WORLD_RECT.position.y, EXPECTED_WORLD_RECT.end.y):
		for x in range(EXPECTED_WORLD_RECT.position.x, EXPECTED_WORLD_RECT.end.x):
			var cell := Vector2i(x, y)
			var tile_data := ground.get_cell_tile_data(cell)
			_expect(tile_data != null, "P1D 导航格 %s 不得为空。" % cell)
			if tile_data == null:
				continue
			var navigation_blocked := (
				tile_data.get_collision_polygons_count(0) > 0
			)
			var wall_blocked := _shape_hits_wall(
				ground.map_to_local(cell),
				point_probe,
				wall
			)
			_expect(
				navigation_blocked == wall_blocked,
				"P1D 导航格 %s 与 authored Wall 中心采样不一致。" % cell
			)
			if navigation_blocked:
				blocked_cell_count += 1
	_expect(
		blocked_cell_count == EXPECTED_NAVIGATION_BLOCKED_CELLS,
		"P1D 必须精确复用 game02 的212个阻挡格，实际%d。"
		% blocked_cell_count
	)
	var pathfinder := arena.get_node("GridPathfinder") as GridPathfinder
	_expect(
		pathfinder.is_built
		and pathfinder.obstacle_tile_layer == ground
		and pathfinder.astar_grid.region == EXPECTED_WORLD_RECT,
		"P1D GridPathfinder 必须绑定并构建20×20地下教堂导航。"
	)


func _test_spawn_and_home_routes(arena: TestGrassArena) -> void:
	var ground := arena.get_node("GroundTileMapLayer") as TileMapLayer
	var wall := arena.get_node("WorldBounds/Wall") as StaticBody2D
	var pathfinder := arena.get_node("GridPathfinder") as GridPathfinder
	var home_targets := arena.get_home_objective_targets()
	_expect(home_targets.size() == 1, "P1D 两格核心门必须合并为一个目标。")
	if home_targets.size() != 1:
		return
	var home_position := home_targets[0].global_position
	_expect(
		home_position.is_equal_approx(Vector2(40, 128)),
		"P1D 核心目标必须位于墙内安全位置(40,128)。"
	)
	var clearance_probe := CircleShape2D.new()
	clearance_probe.radius = 16.0
	var player_spawn := arena.get_node("PlayerSpawn") as Marker2D
	_expect(
		player_spawn.position.is_equal_approx(Vector2(79, 128))
		and not _shape_hits_wall(player_spawn.position, clearance_probe, wall),
		"P1D 玩家出生点必须复用 game02 的(79,128)并保留16px净空。"
	)
	for spawn_name in EXPECTED_SPAWN_POSITIONS:
		var marker := arena.get_node(
			"EnemySpawnPoints/%s" % String(spawn_name)
		) as Marker2D
		_expect(
			marker.position.is_equal_approx(
				EXPECTED_SPAWN_POSITIONS[spawn_name]
			),
			"P1D %s 坐标必须与 game02 一致。" % String(spawn_name)
		)
		_expect(
			not _shape_hits_wall(marker.position, clearance_probe, wall),
			"P1D %s 必须保留16px墙体净空。" % String(spawn_name)
		)
		var spawn_cell := ground.local_to_map(marker.position)
		var tile_data := ground.get_cell_tile_data(spawn_cell)
		_expect(
			tile_data != null
			and tile_data.get_collision_polygons_count(0) == 0,
			"P1D %s 不得位于导航墙格 %s。"
			% [String(spawn_name), spawn_cell]
		)
		var path: PackedVector2Array = pathfinder.call(
			"get_global_path",
			marker.global_position,
			home_position,
			CARDBOARD_HALF_EXTENTS
		)
		_expect(
			not path.is_empty()
			and path[-1].is_equal_approx(home_position),
			"P1D %s 必须允许纸箱怪抵达核心门。" % String(spawn_name)
		)


func _test_campaign_contract(
	campaign: WaveCampaignConfig,
	mode_label: String
) -> void:
	_expect(
		campaign.validate_campaign().is_empty(),
		"P1D %s Campaign 必须通过校验。" % mode_label
	)
	var waves := campaign.get_waves()
	_expect(waves.size() == 1, "P1D %s必须只有一个波次。" % mode_label)
	if waves.size() != 1:
		return
	var wave := waves[0] as WaveConfig
	_expect(
		wave != null
		and wave.enemy_entries.size() == 1
		and wave.enemy_entries[0].enemy_config == CARDBOARD_CONFIG
		and wave.enemy_entries[0].count == EXPECTED_ENEMY_COUNT
		and wave.get_total_enemy_count() == EXPECTED_ENEMY_COUNT,
		"P1D %s波次必须只含1000只纸箱怪。" % mode_label
	)
	_expect(
		is_equal_approx(wave.spawn_interval, 3.0)
		and wave.spawn_count_per_tick == 1
		and wave.max_alive_enemies == EXPECTED_ENEMY_COUNT,
		"P1D %s必须严格每3秒生成1只纸箱怪。" % mode_label
	)
	_expect(
		wave.spawn_order == WaveConfig.SpawnOrder.ENTRY_ROUND_ROBIN
		and wave.spawn_point_mask == 7
		and wave.get_enabled_spawn_point_names()
		== [&"Spawn1", &"Spawn2", &"Spawn3"],
		"P1D %s必须启用地下教堂三处出生点。" % mode_label
	)


func _shape_hits_wall(
	center: Vector2,
	probe: Shape2D,
	wall: StaticBody2D
) -> bool:
	var probe_transform := Transform2D(0.0, center)
	for child in wall.get_children():
		var collision_shape := child as CollisionShape2D
		if (
			collision_shape == null
			or collision_shape.disabled
			or collision_shape.shape == null
		):
			continue
		if collision_shape.shape.collide(
			collision_shape.transform,
			probe,
			probe_transform
		):
			return true
	return false


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)


func _finish() -> void:
	if failures.is_empty():
		print("TEST_UNDERGROUND_CHURCH_ARENA_P1D_SMOKE_TEST_OK")
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	quit(1)
