extends SceneTree

const GAME_SCENE := preload(
	"res://scene/game_modes/rogue/combat/rogue_combat_game_03.tscn"
)
const ABANDONED_MINE_CAMPAIGN: WaveCampaignConfig = preload(
	"res://resources/config/campaigns/rogue_combat/abandoned_mine_01/campaign.tres"
)
const CAPOO_MAGE: EnemyConfig = preload(
	"res://resources/config/enemies/capoo_mage.tres"
)
const FROST_SORCERER: EnemyConfig = preload(
	"res://resources/config/enemies/frost_sorcerer.tres"
)
const COMBAT_ROBOT: EnemyConfig = preload(
	"res://resources/config/enemies/combat_robot.tres"
)
const BACKGROUND_PATH := (
	"res://resources/texture/rogue_combat/abandoned_mine/"
	+ "abandoned_mine_background.png"
)
const EXPECTED_WORLD_RECT := Rect2i(0, -2, 20, 20)
const EXPECTED_CLEAR_CENTER_RECT := Rect2i(4, 3, 12, 10)
const EXPECTED_WALL_SHAPE_COUNT := 11
const EXPECTED_BLOCKED_CELL_COUNT := 214
const MAX_AUTHORED_ENEMY_HALF_EXTENTS := Vector2(11, 10)
const EXPECTED_SPAWN_POSITIONS: Dictionary[StringName, Vector2] = {
	&"Spawn1": Vector2(160, 222),
	&"Spawn2": Vector2(162, 43),
	&"Spawn3": Vector2(251, 91),
}
const REQUIRED_RUNTIME_NODES: Array[NodePath] = [
	^"MultiplayerGameplayGateway",
	^"MultiplayerModeAdapter",
	^"PlayerRosterCoordinator",
	^"PickupRegistry",
	^"WorldEnvironment",
	^"DayNightController",
	^"NightVfxFlashPool",
	^"MusicPlayer",
	^"CountdownAudio",
	^"WaveStartAudio",
	^"GroundTileMapLayer",
	^"GridPathfinder",
	^"Camera2D",
	^"PlayerSpawn",
	^"CurrencyHUD",
	^"PlayerProfilePanel",
	^"SettingsLayer/SettingsPanel",
	^"SettingsLayer/DebugCollectibleWindow",
	^"DamageNumberPool",
	^"SessionObjectPool",
	^"CapooProjectileMotionSystem",
	^"CombatRobotDroneMotionSystem",
	^"BossContainer",
	^"EnemyContainer",
	^"GuardianAuraSystem",
	^"EnemySpawnPoints",
	^"EnemySpawnPoints/Spawn1/NightLight",
	^"EnemySpawnPoints/Spawn2/NightLight",
	^"EnemySpawnPoints/Spawn3/NightLight",
	^"EnemySpawnTimer",
	^"StateTimer",
	^"CombatDeadlineTimer",
	^"RogueCombatHUD",
	^"PlayerLifeStatusLayer/PlayerLifeStatusHUD",
	^"WorldBounds/Wall",
]

var failures: Array[String] = []


func _initialize() -> void:
	var game := GAME_SCENE.instantiate() as RogueCombatGame
	_expect(game != null, "废弃矿场场景必须能实例化为 RogueCombatGame。")
	if game == null:
		_finish()
		return

	var pathfinder := game.get_node(^"GridPathfinder") as GridPathfinder
	pathfinder.rebuild()

	_test_runtime_shell(game)
	_test_background_contract(game)
	_test_collision_and_navigation_contract(game)
	_test_spawn_contract(game)
	_test_combat_content(game)

	game.free()
	_finish()


func _test_runtime_shell(game: RogueCombatGame) -> void:
	_expect(game.name == &"RogueCombatGame03", "根节点必须命名为 RogueCombatGame03。")
	_expect(game.event_title == "废弃矿场", "事件标题必须为“废弃矿场”。")
	_expect(
		game.position.is_equal_approx(Vector2(1, 0)),
		"场景壳必须保留现有 Rouge 作战根坐标。"
	)
	_expect(game.world_lighting_policy == 2, "地下矿场必须使用常驻黑夜策略。")
	for node_path in REQUIRED_RUNTIME_NODES:
		_expect(
			game.get_node_or_null(node_path) != null,
			"场景壳缺少通用运行时节点：%s。" % node_path
		)


func _test_background_contract(game: RogueCombatGame) -> void:
	var background := game.get_node_or_null(
		^"AbandonedMineBackground"
	) as Sprite2D
	_expect(background != null, "场景壳必须包含废弃矿场背景。")
	if background == null:
		return
	_expect(
		background.texture != null
		and background.texture.resource_path == BACKGROUND_PATH,
		"背景必须引用选定的正式废弃矿场 PNG。"
	)
	_expect(
		background.texture.get_width() == 320
		and background.texture.get_height() == 320,
		"废弃矿场背景必须严格为 320×320。"
	)
	_expect(
		background.position.is_equal_approx(Vector2(160, 128))
		and background.scale.is_equal_approx(Vector2.ONE)
		and background.centered
		and background.z_index == -10,
		"背景必须原生覆盖 Rect2(0,-32,320,320)。"
	)
	_expect(
		background.texture_filter == CanvasItem.TEXTURE_FILTER_NEAREST,
		"像素背景必须显式使用 nearest 过滤。"
	)
	var camera := game.get_node(^"Camera2D") as Camera2D
	_expect(
		camera.position.is_equal_approx(Vector2(160, 128))
		and camera.zoom.is_equal_approx(Vector2(2, 2)),
		"相机必须与 320×320 完整背景居中对齐。"
	)


func _test_collision_and_navigation_contract(game: RogueCombatGame) -> void:
	var wall := game.get_node_or_null(^"WorldBounds/Wall") as StaticBody2D
	_expect(wall != null, "废弃矿场必须包含 authored WorldBounds/Wall。")
	if wall == null:
		return
	_expect((wall.collision_layer & 1) != 0, "Wall 必须位于 World 物理层 1。")
	var authored_shape_count := 0
	for child in wall.get_children():
		var collision_shape := child as CollisionShape2D
		_expect(
			collision_shape != null,
			"Wall 只能直接包含 CollisionShape2D：%s。" % child.name
		)
		if collision_shape == null:
			continue
		authored_shape_count += 1
		_expect(
			not collision_shape.disabled and collision_shape.shape != null,
			"墙体形状 %s 必须启用并绑定 Shape2D。" % child.name
		)
	_expect(
		authored_shape_count == EXPECTED_WALL_SHAPE_COUNT,
		"废弃矿场应保留%d个 authored 墙体形状，实际%d个。"
		% [EXPECTED_WALL_SHAPE_COUNT, authored_shape_count]
	)

	var ground := game.get_node_or_null(^"GroundTileMapLayer") as TileMapLayer
	_expect(ground != null, "废弃矿场必须挂载隐藏导航 TileMapLayer。")
	if ground == null:
		return
	_expect(not ground.visible, "导航 TileMapLayer 必须完全隐藏。")
	_expect(
		not ground.collision_enabled
		and not ground.navigation_enabled
		and not ground.occlusion_enabled,
		"隐藏层只提供 GridPathfinder 数据，不应重复生成物理或导航。"
	)
	var world_bounds := game.get_node(^"WorldBounds") as Node2D
	_expect(
		ground.transform.is_equal_approx(Transform2D.IDENTITY)
		and world_bounds.transform.is_equal_approx(Transform2D.IDENTITY)
		and wall.transform.is_equal_approx(Transform2D.IDENTITY),
		"格心采样要求 GroundTileMapLayer、WorldBounds 与 Wall 保持同一局部坐标系。"
	)
	_expect(
		ground.get_used_rect() == EXPECTED_WORLD_RECT,
		"导航区域必须严格为 Rect2i(0,-2,20,20)。"
	)
	var used_cells := ground.get_used_cells()
	_expect(used_cells.size() == 400, "导航层必须预置完整400格。")
	var point_probe := CircleShape2D.new()
	point_probe.radius = 0.01
	var blocked_count := 0
	var open_cells: Dictionary[Vector2i, bool] = {}
	for y in range(EXPECTED_WORLD_RECT.position.y, EXPECTED_WORLD_RECT.end.y):
		for x in range(EXPECTED_WORLD_RECT.position.x, EXPECTED_WORLD_RECT.end.x):
			var cell := Vector2i(x, y)
			var tile_data := ground.get_cell_tile_data(cell)
			_expect(tile_data != null, "导航格 %s 缺少 TileData。" % cell)
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
				"导航格 %s 与 authored Wall 的格心采样不一致。" % cell
			)
			if navigation_blocked:
				blocked_count += 1
			else:
				open_cells[cell] = true
	_expect(
		blocked_count == EXPECTED_BLOCKED_CELL_COUNT,
		"废弃矿场导航应有%d个阻挡格，实际%d个。"
		% [EXPECTED_BLOCKED_CELL_COUNT, blocked_count]
	)
	_expect(
		_count_four_way_connected_cells(open_cells) == open_cells.size(),
		"全部开放导航格必须属于同一个四方向连通区域。"
	)
	for y in range(
		EXPECTED_CLEAR_CENTER_RECT.position.y,
		EXPECTED_CLEAR_CENTER_RECT.end.y
	):
		for x in range(
			EXPECTED_CLEAR_CENTER_RECT.position.x,
			EXPECTED_CLEAR_CENTER_RECT.end.x
		):
			var center_cell := Vector2i(x, y)
			var center_tile_data := ground.get_cell_tile_data(center_cell)
			_expect(
				center_tile_data != null
				and center_tile_data.get_collision_polygons_count(0) == 0,
				"中央行动区格子 %s 必须保持开放。" % center_cell
			)
	var pathfinder := game.get_node(^"GridPathfinder") as GridPathfinder
	_expect(pathfinder.is_built, "GridPathfinder 必须建立完整网格。")
	_expect(
		pathfinder.obstacle_tile_layer == ground
		and pathfinder.astar_grid.region == EXPECTED_WORLD_RECT,
		"GridPathfinder 必须绑定废弃矿场的20×20隐藏层。"
	)
	var contract_errors := game.validate_encounter_scene_contract(
		RogueCombatEncounterConfig.REQUIRED_SCENE_SPAWN_POINT_MASK
	)
	_expect(
		contract_errors.is_empty(),
		"废弃矿场场景必须满足 Rouge 作战场景合同：%s" % [contract_errors]
	)


func _test_spawn_contract(game: RogueCombatGame) -> void:
	var player_spawn := game.get_node(^"PlayerSpawn") as Marker2D
	var ground := game.get_node(^"GroundTileMapLayer") as TileMapLayer
	var wall := game.get_node(^"WorldBounds/Wall") as StaticBody2D
	var pathfinder := game.get_node(^"GridPathfinder") as GridPathfinder
	_expect(
		player_spawn.position.is_equal_approx(Vector2(160, 128)),
		"玩家出生点必须位于中央安全区。"
	)
	var player_cell := ground.local_to_map(
		ground.to_local(player_spawn.global_position)
	)
	var player_tile_data := ground.get_cell_tile_data(player_cell)
	_expect(
		player_tile_data != null
		and player_tile_data.get_collision_polygons_count(0) == 0,
		"玩家出生点必须位于开放格。"
	)
	var enemy_spawn_probe := RectangleShape2D.new()
	enemy_spawn_probe.size = MAX_AUTHORED_ENEMY_HALF_EXTENTS * 2.0
	var spawn_root := game.get_node(^"EnemySpawnPoints") as Node2D
	_expect(
		spawn_root.get_child_count() == EXPECTED_SPAWN_POSITIONS.size(),
		"EnemySpawnPoints 必须包含三个用户 authored 生成点。"
	)
	for spawn_name in EXPECTED_SPAWN_POSITIONS:
		var spawn_point := spawn_root.get_node_or_null(
			NodePath(String(spawn_name))
		) as Marker2D
		_expect(spawn_point != null, "缺少敌人生成点 %s。" % spawn_name)
		if spawn_point == null:
			continue
		_expect(
			spawn_point.position.is_equal_approx(
				EXPECTED_SPAWN_POSITIONS[spawn_name]
			),
			"敌人生成点 %s 必须保留用户 authored 坐标。" % spawn_name
		)
		var night_light := spawn_point.get_node_or_null(
			^"NightLight"
		) as NightPointLight2D
		_expect(
			night_light != null
			and is_equal_approx(night_light.texture_scale, 0.3375)
			and is_equal_approx(night_light.night_energy, 0.3),
			"敌人生成点 %s 必须保留 game2 同款 NightLight。" % spawn_name
		)
		var spawn_cell := ground.local_to_map(
			ground.to_local(spawn_point.global_position)
		)
		var spawn_tile_data := ground.get_cell_tile_data(spawn_cell)
		_expect(
			spawn_tile_data != null
			and spawn_tile_data.get_collision_polygons_count(0) == 0,
			"%s 必须直接位于开放导航格 %s。" % [spawn_name, spawn_cell]
		)
		_expect(
			not _shape_hits_wall(
				wall.to_local(spawn_point.global_position),
				enemy_spawn_probe,
				wall
			),
			"%s 的最大已用敌人体型不得与 authored Wall 重叠。" % spawn_name
		)
		var path: PackedVector2Array = pathfinder.get_global_path(
			spawn_point.global_position,
			player_spawn.global_position,
			MAX_AUTHORED_ENEMY_HALF_EXTENTS
		)
		_expect(
			not path.is_empty()
			and path[-1].is_equal_approx(player_spawn.global_position),
			"%s 必须允许当前最大已用敌人体型抵达玩家区域。" % spawn_name
		)


func _test_combat_content(game: RogueCombatGame) -> void:
	_expect(
		game.singleplayer_campaign == ABANDONED_MINE_CAMPAIGN
		and game.multiplayer_campaign == ABANDONED_MINE_CAMPAIGN,
		"废弃矿场的单人及多人模式必须绑定专属 Campaign。"
	)
	for runtime_mode in [
		CombatRuntimeBase.RuntimeMode.SINGLEPLAYER,
		CombatRuntimeBase.RuntimeMode.HOST_AUTHORITY,
	]:
		game.runtime_mode = runtime_mode
		_expect(
			bool(game.call("_configure_active_campaign"))
			and game.active_campaign == ABANDONED_MINE_CAMPAIGN
			and game.waves.size() == 1,
			"废弃矿场在单人及 Host 权威模式下必须选择同一份专属 Campaign。"
		)
	var waves := ABANDONED_MINE_CAMPAIGN.get_waves()
	_expect(waves.size() == 1, "废弃矿场 Campaign 必须只有一个终点波次。")
	if waves.size() == 1:
		var wave := waves[0]
		_expect(
			wave.get_total_enemy_count() == 45
			and _count_enemy(wave, CAPOO_MAGE) == 5
			and _count_enemy(wave, FROST_SORCERER) == 15
			and _count_enemy(wave, COMBAT_ROBOT) == 25,
			"废弃矿场必须配置5个法术猫猫虫、15个寒冰术士和25个普通战斗机器人。"
		)
		_expect(
			is_equal_approx(wave.spawn_interval, 0.2)
			and wave.spawn_count_per_tick == 1
			and wave.max_alive_enemies == 15
			and wave.spawn_point_mask
				== RogueCombatEncounterConfig.REQUIRED_SCENE_SPAWN_POINT_MASK
			and wave.spawn_point_order
				== WaveConfig.SpawnPointOrder.BALANCED_SHUFFLE_BAG
			and wave.spawn_order == WaveConfig.SpawnOrder.SHUFFLED,
			"废弃矿场必须保持0.2秒批1、场上最多15名敌人及三点均衡乱序。"
		)
		game.random_generator.seed = 20260812
		game.call("_build_wave_spawn_queue", wave)
		_expect(
			game.pending_enemy_configs.size() == 45
			and _count_queued_enemy(game, CAPOO_MAGE) == 5
			and _count_queued_enemy(game, FROST_SORCERER) == 15
			and _count_queued_enemy(game, COMBAT_ROBOT) == 25,
			"运行时刷怪队列必须完整保留5/15/25的45名敌人组成。"
		)
	_expect(
		game.get_node_or_null(^"UndergroundChurchBackground") == null
		and game.get_node_or_null(^"UndergroundChurchWallTorchLayout") == null,
		"废弃矿场场景不得残留地下教会专属视觉节点。"
	)


func _count_enemy(wave: WaveConfig, enemy_config: EnemyConfig) -> int:
	var result := 0
	for entry in wave.enemy_entries:
		if entry != null and entry.enemy_config == enemy_config:
			result += entry.count
	return result


func _count_queued_enemy(
	game: RogueCombatGame,
	enemy_config: EnemyConfig
) -> int:
	var result := 0
	for queued_config in game.pending_enemy_configs:
		if queued_config == enemy_config:
			result += 1
	return result


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


func _count_four_way_connected_cells(
	open_cells: Dictionary[Vector2i, bool]
) -> int:
	if open_cells.is_empty():
		return 0
	var pending: Array[Vector2i] = [open_cells.keys()[0] as Vector2i]
	var visited: Dictionary[Vector2i, bool] = {}
	var cursor := 0
	while cursor < pending.size():
		var cell := pending[cursor]
		cursor += 1
		if visited.has(cell):
			continue
		visited[cell] = true
		var directions: Array[Vector2i] = [
			Vector2i.LEFT,
			Vector2i.RIGHT,
			Vector2i.UP,
			Vector2i.DOWN,
		]
		for direction: Vector2i in directions:
			var neighbor: Vector2i = cell + direction
			if open_cells.has(neighbor) and not visited.has(neighbor):
				pending.append(neighbor)
	return visited.size()


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)


func _finish() -> void:
	if failures.is_empty():
		print("ROGUE_COMBAT_GAME_03_SHELL_SMOKE_TEST_OK")
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	quit(1)
