extends SceneTree

const GAME_01 := preload(
	"res://scene/game_modes/rogue/combat/rogue_combat_game_01.tscn"
)
const GAME_02 := preload(
	"res://scene/game_modes/rogue/combat/rogue_combat_game_02.tscn"
)
const UNDERGROUND_CHURCH_CAMPAIGN := preload(
	"res://resources/config/campaigns/rogue_combat/underground_church_01/campaign.tres"
)
const BACKGROUND_PATH := (
	"res://resources/texture/rogue_combat/underground_church/"
	+ "underground_church_background.png"
)
const EXPECTED_WORLD_RECT := Rect2i(0, -2, 20, 20)
const EXPECTED_SPAWN_POSITIONS: Dictionary[StringName, Vector2] = {
	&"Spawn1": Vector2(267, 73),
	&"Spawn2": Vector2(269, 119),
	&"Spawn3": Vector2(270, 182),
}
const EXPECTED_WALL_SHAPE_COUNT := 10
const MAX_AUTHORED_ENEMY_HALF_EXTENTS := Vector2(4, 9)

var failures: Array[String] = []


func _initialize() -> void:
	call_deferred(&"_run")


func _run() -> void:
	var game := GAME_02.instantiate() as RogueCombatGame
	_expect(game != null, "地下教堂场景必须能实例化为 RogueCombatGame。")
	if game == null:
		_finish()
		return
	game.auto_start_waves = false
	(game.get_node("MusicPlayer") as AudioStreamPlayer).autoplay = false
	root.add_child(game)
	await process_frame

	_test_authored_scene_structure(game)
	_test_background_contract(game)
	_test_torch_layout_contract(game)
	_test_navigation_authoring_contract(game)
	_test_navigation_binding_contract(game)
	_test_spawn_wall_clearance(game)

	game.queue_free()
	await process_frame
	await physics_frame
	_finish()


func _test_authored_scene_structure(game: RogueCombatGame) -> void:
	var game_01 := GAME_01.instantiate()
	var expected_names: Dictionary[StringName, bool] = {}
	for child in game_01.get_children():
		expected_names[child.name] = true
	# game02 的三扇门已画入完整背景，不再重复叠加 game01 的瓦片门。
	expected_names.erase(&"OverlayTileMapLayer")
	for child in game.get_children():
		if child.name in [
			&"UndergroundChurchBackground",
			&"UndergroundChurchWallTorchLayout",
			&"WorldBounds",
			&"Player",
		]:
			continue
		_expect(
			expected_names.erase(child.name),
			"game02 不应新增或改名运行时根节点：%s。" % child.name
		)
	_expect(expected_names.is_empty(), "game02 必须保留 game1 的全部运行时根节点。")
	game_01.free()
	_expect(game.name == &"RogueCombatGame02", "新场景根节点必须命名为 RogueCombatGame02。")
	_expect(game.event_title == "地下教会", "新场景的玩家可见备用名称必须为地下教会。")
	_expect(
		game.singleplayer_campaign == UNDERGROUND_CHURCH_CAMPAIGN
		and game.multiplayer_campaign == UNDERGROUND_CHURCH_CAMPAIGN,
		"地下教会编辑器直跑必须使用自己的正式 Campaign。",
	)
	_expect(
		game.get_node_or_null("OverlayTileMapLayer") == null,
		"完整背景已包含门洞，地下教堂不应重复叠加 game01 的瓦片门。"
	)
	var wall := game.get_node_or_null("WorldBounds/Wall") as StaticBody2D
	_expect(wall != null, "地下教堂必须保留 authored WorldBounds/Wall。")
	if wall != null:
		_expect(
			(wall.collision_layer & 1) != 0,
			"地下教堂墙体必须保留 World 物理层1。"
		)
		var wall_shape_count := 0
		for child in wall.get_children():
			var collision_shape := child as CollisionShape2D
			_expect(
				collision_shape != null,
				"Wall 只能直接包含 CollisionShape2D：%s。" % child.name
			)
			if collision_shape == null:
				continue
			wall_shape_count += 1
			_expect(
				not collision_shape.disabled and collision_shape.shape != null,
				"墙体形状 %s 必须启用并绑定 Shape2D。" % child.name
			)
		_expect(
			wall_shape_count == EXPECTED_WALL_SHAPE_COUNT,
			"地下教堂应保留%d个 authored 墙体形状，实际%d个。"
			% [EXPECTED_WALL_SHAPE_COUNT, wall_shape_count]
		)
	var contract_errors := game.validate_encounter_scene_contract(
		RogueCombatEncounterConfig.REQUIRED_SCENE_SPAWN_POINT_MASK
	)
	_expect(
		contract_errors.is_empty(),
		"地下教堂场景必须保留 Rouge 三门运行时契约：%s" % [contract_errors]
	)


func _test_background_contract(game: RogueCombatGame) -> void:
	var background := game.get_node_or_null(
		"UndergroundChurchBackground"
	) as Sprite2D
	_expect(background != null, "地下教堂必须使用 authored Sprite2D 完整背景。")
	if background == null:
		return
	_expect(
		background.texture != null
		and background.texture.resource_path == BACKGROUND_PATH,
		"地下教堂背景必须引用唯一正式 PNG。"
	)
	_expect(
		background.texture.get_width() == 320
		and background.texture.get_height() == 320,
		"地下教堂完整背景必须严格为 320×320 逻辑像素。"
	)
	_expect(
		background.position.is_equal_approx(Vector2(160, 128))
		and background.scale.is_equal_approx(Vector2.ONE)
		and background.centered
		and background.z_index == -10,
		"背景必须以原生比例覆盖 Rect2(0,-32,320,320)，不得二次缩放。"
	)
	_expect(
		background.texture_filter == CanvasItem.TEXTURE_FILTER_NEAREST,
		"地下教堂像素背景必须显式使用 nearest 过滤。"
	)
	var camera := game.get_node("Camera2D") as Camera2D
	_expect(
		camera.position.is_equal_approx(Vector2(160, 128)),
		"新场景相机必须居中完整 320×320 世界区域。"
	)


func _test_torch_layout_contract(game: RogueCombatGame) -> void:
	var layout := game.get_node_or_null(
		"UndergroundChurchWallTorchLayout"
	) as Node2D
	_expect(layout != null, "地下教会必须实例化共享三火把布局。")
	if layout == null:
		return
	var expected_positions: Dictionary[StringName, Vector2] = {
		&"UpperLeftTorch": Vector2(104, 52),
		&"UpperRightTorch": Vector2(216, 52),
		&"LowerTorch": Vector2(160, 256),
	}
	_expect(layout.get_child_count() == 3, "地下教会必须恰好放置三盏火把。")
	for torch_name in expected_positions:
		var torch := layout.get_node_or_null(
			NodePath(String(torch_name))
		) as UndergroundChurchWallTorch
		_expect(
			torch != null
			and torch.position.is_equal_approx(expected_positions[torch_name]),
			"地下教会火把 %s 必须保持共享布局坐标。" % torch_name,
		)
		if torch != null:
			_expect(
				torch.night_light.energy > 0.0,
				"固定夜晚下火把 %s 必须实际发光。" % torch_name,
			)


func _test_navigation_authoring_contract(game: RogueCombatGame) -> void:
	var ground := game.get_node_or_null("GroundTileMapLayer") as TileMapLayer
	_expect(ground != null, "地下教堂必须保留隐藏导航 TileMapLayer。")
	if ground == null:
		return
	_expect(not ground.visible, "导航 TileMapLayer 必须对玩家完全隐藏。")
	_expect(
		not ground.collision_enabled
		and not ground.navigation_enabled
		and not ground.occlusion_enabled,
		"隐藏层仅提供 GridPathfinder 数据，不应重复生成物理、导航或遮挡。"
	)
	_expect(
		ground.get_used_rect() == EXPECTED_WORLD_RECT,
		"导航 authored 区域必须严格覆盖20×20格：%s。" % ground.get_used_rect()
	)
	var used_cells := ground.get_used_cells()
	_expect(used_cells.size() == 400, "导航层必须预置完整400格。")
	var wall := game.get_node_or_null("WorldBounds/Wall") as StaticBody2D
	_expect(wall != null, "导航栅格校验需要 authored Wall。")
	if wall == null:
		return
	var point_probe := CircleShape2D.new()
	point_probe.radius = 0.01
	var blocked_cell_count := 0
	for y in range(EXPECTED_WORLD_RECT.position.y, EXPECTED_WORLD_RECT.end.y):
		for x in range(EXPECTED_WORLD_RECT.position.x, EXPECTED_WORLD_RECT.end.x):
			var cell := Vector2i(x, y)
			var tile_data := ground.get_cell_tile_data(cell)
			_expect(
				tile_data != null,
				"导航格 %s 必须绑定可审计的 TileData。" % cell
			)
			if tile_data == null:
				continue
			var navigation_blocked := (
				tile_data.get_collision_polygons_count(0) > 0
			)
			var wall_blocked := _shape_hits_wall(
				ground.map_to_local(cell), point_probe, wall
			)
			_expect(
				navigation_blocked == wall_blocked,
				"导航格 %s 与 authored Wall 的中心采样不一致。" % cell
			)
			if navigation_blocked:
				blocked_cell_count += 1
	_expect(
		blocked_cell_count > 0 and blocked_cell_count < used_cells.size(),
		"导航层必须同时包含墙格和可行走格。"
	)
	var pathfinder := game.get_node("GridPathfinder") as GridPathfinder
	_expect(pathfinder.is_built, "GridPathfinder 必须能由隐藏导航层建立完整网格。")
	_expect(
		pathfinder.obstacle_tile_layer == ground,
		"GridPathfinder 必须绑定地下教堂的 GroundTileMapLayer。"
	)
	_expect(
		pathfinder.astar_grid.region == EXPECTED_WORLD_RECT,
		"寻路网格区域必须与20×20 authored 区域完全一致。"
	)


func _test_spawn_wall_clearance(game: RogueCombatGame) -> void:
	var ground := game.get_node("GroundTileMapLayer") as TileMapLayer
	var wall := game.get_node("WorldBounds/Wall") as StaticBody2D
	var clearance_probe := CircleShape2D.new()
	clearance_probe.radius = 16.0
	var player_spawn := game.get_node("PlayerSpawn") as Marker2D
	_expect(
		player_spawn.position.is_equal_approx(Vector2(79, 128)),
		"地下教堂暂时沿用 game1 队伍出生锚点。"
	)
	_expect(
		not _shape_hits_wall(player_spawn.position, clearance_probe, wall),
		"队伍出生点必须为最大角色碰撞体保留16px墙体净空。"
	)
	for spawn_name in EXPECTED_SPAWN_POSITIONS:
		var marker := game.get_node(
			"EnemySpawnPoints/%s" % String(spawn_name)
		) as Marker2D
		_expect(
			marker.position.is_equal_approx(EXPECTED_SPAWN_POSITIONS[spawn_name]),
			"%s 必须保留用户 authored 出生坐标。" % String(spawn_name)
		)
		_expect(
			not _shape_hits_wall(marker.position, clearance_probe, wall),
			"%s 必须为敌人碰撞体保留16px墙体净空。" % String(spawn_name)
		)
		var spawn_cell := ground.local_to_map(marker.position)
		var spawn_tile_data := ground.get_cell_tile_data(spawn_cell)
		_expect(
			spawn_tile_data != null
			and spawn_tile_data.get_collision_polygons_count(0) == 0,
			"%s 不能落在导航墙格 %s。" % [String(spawn_name), spawn_cell]
		)
		var path: PackedVector2Array = game.grid_pathfinder.call(
			"get_global_path",
			marker.global_position,
			player_spawn.global_position,
			MAX_AUTHORED_ENEMY_HALF_EXTENTS
		)
		_expect(
			not path.is_empty()
			and path[-1].is_equal_approx(player_spawn.global_position),
			"%s 必须允许当前最大机器人沿墙体栅格抵达玩家区域。" % String(spawn_name)
		)


func _test_navigation_binding_contract(game: RogueCombatGame) -> void:
	var pathfinder := game.get_node("GridPathfinder") as GridPathfinder
	var authored_path := pathfinder.obstacle_tile_layer_path
	pathfinder.obstacle_tile_layer_path = NodePath()
	var errors := game.validate_encounter_scene_contract(
		RogueCombatEncounterConfig.REQUIRED_SCENE_SPAWN_POINT_MASK
	)
	_expect(
		errors.has("Rouge 作战场景的 GridPathfinder 未绑定障碍层。"),
		"作战场景契约必须拒绝被清空的 GridPathfinder 障碍层引用。"
	)
	pathfinder.obstacle_tile_layer_path = authored_path


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
		print("ROGUE_COMBAT_GAME_02_SMOKE_TEST_OK")
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	quit(1)
