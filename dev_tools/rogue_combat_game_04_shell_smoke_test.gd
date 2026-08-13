extends SceneTree

const GAME_SCENE := preload(
	"res://scene/game_modes/rogue/combat/rogue_combat_game_04.tscn"
)
const UNDERGROUND_SEWER_CAMPAIGN: WaveCampaignConfig = preload(
	"res://resources/config/campaigns/rogue_combat/underground_sewer_01/campaign.tres"
)
const YUANSHI_INSECT_FAST: EnemyConfig = preload(
	"res://resources/config/enemies/yuanshi_insect_fast.tres"
)
const YUANSHI_INSECT_FIRE_RANGED: EnemyConfig = preload(
	"res://resources/config/enemies/yuanshi_insect_fire_ranged.tres"
)
const YUANSHI_INSECT_BOMBER: EnemyConfig = preload(
	"res://resources/config/enemies/yuanshi_insect_bomber.tres"
)
const CAPOO_MAGE: EnemyConfig = preload(
	"res://resources/config/enemies/capoo_mage.tres"
)
const BACKGROUND_PATH := (
	"res://resources/texture/rogue_combat/underground_sewer/"
	+ "underground_sewer_background.png"
)
const EXPECTED_WORLD_RECT := Rect2i(0, 0, 26, 18)
const EXPECTED_OPEN_RECT := Rect2i(0, 6, 26, 7)
const EXPECTED_MAX_ENEMY_OPEN_RECT := Rect2i(1, 7, 24, 5)
const EXPECTED_BLOCKED_CELL_COUNT := 286
const EXPECTED_WALL_SHAPE_COUNT := 4
const NAVIGATION_CELL_PROBE_SIZE := Vector2(15.98, 15.98)
const EXPECTED_SPAWN_MASK := (
	WaveConfig.SPAWN_POINT_1_MASK | WaveConfig.SPAWN_POINT_2_MASK
)
const EXPECTED_SPAWN_POSITIONS: Dictionary[StringName, Vector2] = {
	&"Spawn1": Vector2(376, 120),
	&"Spawn2": Vector2(376, 184),
}
const EXPECTED_TORCHES: Dictionary[StringName, Array] = {
	&"LeftWallTorch": [Vector2(136, 56), 1.35],
	&"RightWallTorch": [Vector2(280, 56), 1.55],
}
const MAX_AUTHORED_ENEMY_HALF_EXTENTS := Vector2(12, 10)
const PLAYER_RADIUS := 16.0
const PLAYER_SPAWN_OFFSETS: Array[Vector2] = [
	Vector2.ZERO,
	Vector2(18, 0),
	Vector2(0, 18),
	Vector2(18, 18),
	Vector2(-18, 0),
	Vector2(0, -18),
	Vector2(-18, -18),
	Vector2(18, -18),
]
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
	^"UndergroundSewerWallTorchLayout",
	^"GroundTileMapLayer",
	^"GridPathfinder",
	^"Camera2D",
	^"PlayerSpawn",
	^"CurrencyHUD",
	^"PlayerProfilePanel",
	^"SettingsLayer/SettingsPanel",
	^"SettingsLayer/DebugCollectibleWindow",
	^"DamageNumberPool",
	^"SniperLockVisualCoordinator",
	^"SessionObjectPool",
	^"CapooProjectileMotionSystem",
	^"CombatRobotDroneMotionSystem",
	^"BossContainer",
	^"EnemyContainer",
	^"GuardianAuraSystem",
	^"EnemySpawnPoints",
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
	_expect(game != null, "地下水道场景必须能实例化为 RogueCombatGame。")
	if game == null:
		_finish()
		return
	var pathfinder := game.get_node(^"GridPathfinder") as GridPathfinder
	pathfinder.rebuild()
	_test_runtime_shell(game)
	_test_background_and_torches(game)
	_test_collision_and_navigation(game)
	_test_spawns(game)
	_test_combat_content(game)
	game.free()
	_finish()


func _test_runtime_shell(game: RogueCombatGame) -> void:
	_expect(game.name == &"RogueCombatGame04", "根节点必须命名为 RogueCombatGame04。")
	_expect(game.event_title == "地下水道", "事件标题必须为“地下水道”。")
	_expect(game.world_lighting_policy == 2, "地下水道必须使用常驻黑夜策略。")
	for path in REQUIRED_RUNTIME_NODES:
		_expect(
			game.get_node_or_null(path) != null,
			"场景壳缺少通用运行时节点：%s。" % path
		)


func _test_background_and_torches(game: RogueCombatGame) -> void:
	var background := game.get_node_or_null(
		^"UndergroundSewerBackground"
	) as Sprite2D
	_expect(background != null, "场景必须包含地下水道背景。")
	if background != null:
		_expect(
			background.texture != null
			and background.texture.resource_path == BACKGROUND_PATH,
			"背景必须引用正式地下水道 PNG。"
		)
		_expect(
			background.texture.get_width() == 416
			and background.texture.get_height() == 288,
			"地下水道背景必须严格为416×288。"
		)
		_expect(
			background.position.is_equal_approx(Vector2(208, 144))
			and background.scale.is_equal_approx(Vector2.ONE)
			and background.centered
			and background.z_index == -10
			and background.texture_filter
				== CanvasItem.TEXTURE_FILTER_NEAREST,
			"背景必须以原生像素覆盖Rect2(0,0,416,288)。"
		)
	var camera := game.get_node(^"Camera2D") as Camera2D
	_expect(
		camera.position.is_equal_approx(Vector2(208, 144))
		and camera.zoom.is_equal_approx(Vector2(2, 2)),
		"相机必须与416×288背景居中对齐。"
	)
	var layout := game.get_node(^"UndergroundSewerWallTorchLayout")
	_expect(
		layout.get_child_count() == EXPECTED_TORCHES.size(),
		"地下水道必须只包含两盏 authored 壁挂火把。"
	)
	for torch_name in EXPECTED_TORCHES:
		var torch := layout.get_node_or_null(
			NodePath(String(torch_name))
		) as UndergroundChurchWallTorch
		_expect(torch != null, "缺少壁挂火把 %s。" % torch_name)
		if torch == null:
			continue
		var expected: Array = EXPECTED_TORCHES[torch_name]
		_expect(
			torch.position.is_equal_approx(expected[0] as Vector2)
			and is_equal_approx(torch.half_cycle_seconds, float(expected[1])),
			"火把 %s 的位置或呼吸周期不正确。" % torch_name
		)
		var sprite := torch.get_node(^"Sprite") as Sprite2D
		var light := torch.get_node(^"NightPointLight") as NightPointLight2D
		_expect(
			sprite.texture_filter == CanvasItem.TEXTURE_FILTER_NEAREST
			and sprite.position.is_equal_approx(Vector2(0, -12))
			and sprite.texture != null
			and sprite.texture.get_size() == Vector2(16, 24),
			"火把 %s 必须保留16×24 nearest像素素材。" % torch_name
		)
		_expect(
			light.position.is_equal_approx(Vector2(0, -18))
			and light.color.is_equal_approx(Color(1.0, 0.58, 0.26, 1.0))
			and is_equal_approx(light.night_energy, 0.36),
			"火把 %s 必须保留微弱暖色夜间光。" % torch_name
		)


func _test_collision_and_navigation(game: RogueCombatGame) -> void:
	var wall := game.get_node(^"WorldBounds/Wall") as StaticBody2D
	_expect(wall.get_child_count() == EXPECTED_WALL_SHAPE_COUNT, "应有四块 authored 边界碰撞。")
	var ground := game.get_node(^"GroundTileMapLayer") as TileMapLayer
	_expect(not ground.visible, "隐藏导航层不得可见。")
	_expect(
		not ground.collision_enabled
		and not ground.navigation_enabled
		and not ground.occlusion_enabled,
		"隐藏导航层只能提供 GridPathfinder 语义。"
	)
	_expect(ground.get_used_rect() == EXPECTED_WORLD_RECT, "导航必须严格为26×18格。")
	_expect(ground.get_used_cells().size() == 468, "导航必须预置完整468格。")
	var blocked_count := 0
	var open_cells: Dictionary[Vector2i, bool] = {}
	var cell_probe := RectangleShape2D.new()
	cell_probe.size = NAVIGATION_CELL_PROBE_SIZE
	for y in range(EXPECTED_WORLD_RECT.position.y, EXPECTED_WORLD_RECT.end.y):
		for x in range(EXPECTED_WORLD_RECT.position.x, EXPECTED_WORLD_RECT.end.x):
			var cell := Vector2i(x, y)
			var tile_data := ground.get_cell_tile_data(cell)
			_expect(tile_data != null, "导航格%s缺少TileData。" % cell)
			if tile_data == null:
				continue
			var navigation_blocked := tile_data.get_collision_polygons_count(0) > 0
			var wall_blocked := _shape_hits_wall(
				ground.map_to_local(cell), cell_probe, wall
			)
			_expect(
				navigation_blocked == wall_blocked,
				"导航格%s必须与 authored Wall 格心采样一致。" % cell
			)
			if navigation_blocked:
				blocked_count += 1
			else:
				open_cells[cell] = true
	_expect(blocked_count == EXPECTED_BLOCKED_CELL_COUNT, "导航阻挡格必须为286。")
	_expect(open_cells.size() == 182, "开放战斗区必须为182格。")
	for y in range(EXPECTED_OPEN_RECT.position.y, EXPECTED_OPEN_RECT.end.y):
		for x in range(EXPECTED_OPEN_RECT.position.x, EXPECTED_OPEN_RECT.end.x):
			_expect(open_cells.has(Vector2i(x, y)), "中央26×7行动区必须全部开放。")
	_expect(
		_count_four_way_connected_cells(open_cells) == open_cells.size(),
		"全部开放格必须四方向连通。"
	)
	var pathfinder := game.get_node(^"GridPathfinder") as GridPathfinder
	_expect(
		pathfinder.is_built
		and pathfinder.astar_grid.region == EXPECTED_WORLD_RECT,
		"GridPathfinder必须绑定26×18隐藏导航层。"
	)
	_expect(
		game.validate_encounter_scene_contract(EXPECTED_SPAWN_MASK).is_empty(),
		"两点地下水道场景必须满足spawn mask=3的作战合同。"
	)


func _test_spawns(game: RogueCombatGame) -> void:
	var player_spawn := game.get_node(^"PlayerSpawn") as Marker2D
	var ground := game.get_node(^"GroundTileMapLayer") as TileMapLayer
	var pathfinder := game.get_node(^"GridPathfinder") as GridPathfinder
	var wall := game.get_node(^"WorldBounds/Wall") as StaticBody2D
	_expect(
		player_spawn.position.is_equal_approx(Vector2(56, 152)),
		"玩家出生锚点必须位于左侧并为八人偏移保留净空。"
	)
	_expect(_is_open_position(ground, player_spawn.global_position), "玩家必须出生在开放格。")
	var player_probe := CircleShape2D.new()
	player_probe.radius = PLAYER_RADIUS
	for offset in PLAYER_SPAWN_OFFSETS:
		var player_position := player_spawn.global_position + offset
		_expect(
			_is_open_position(ground, player_position)
			and not _shape_hits_wall(
				wall.to_local(player_position), player_probe, wall
			),
			"八人偏移位置%s必须完全位于开放战斗区。" % player_position
		)
	var spawn_root := game.get_node(^"EnemySpawnPoints") as Node2D
	_expect(spawn_root.get_child_count() == 2, "最右侧必须只有两个敌人生成Point。")
	var enemy_probe := RectangleShape2D.new()
	enemy_probe.size = MAX_AUTHORED_ENEMY_HALF_EXTENTS * 2.0
	for spawn_name in EXPECTED_SPAWN_POSITIONS:
		var spawn := spawn_root.get_node_or_null(
			NodePath(String(spawn_name))
		) as Marker2D
		_expect(spawn != null, "缺少敌人生成点%s。" % spawn_name)
		if spawn == null:
			continue
		_expect(
			spawn.position.is_equal_approx(EXPECTED_SPAWN_POSITIONS[spawn_name]),
			"生成点%s位置不正确。" % spawn_name
		)
		var night_light := spawn.get_node_or_null(^"NightLight") as NightPointLight2D
		_expect(
			night_light != null
			and is_equal_approx(night_light.texture_scale, 0.3375)
			and is_equal_approx(night_light.night_energy, 0.3),
			"生成点%s必须保留夜间门灯。" % spawn_name
		)
		_expect(_is_open_position(ground, spawn.global_position), "%s必须位于开放格。" % spawn_name)
		_expect(
			not _shape_hits_wall(
				wall.to_local(spawn.global_position), enemy_probe, wall
			),
			"%s必须为当前最大敌人体型保留完整净空。" % spawn_name
		)
		for offset in PLAYER_SPAWN_OFFSETS:
			var player_target := player_spawn.global_position + offset
			var path := pathfinder.get_global_path(
				spawn.global_position,
				player_target,
				MAX_AUTHORED_ENEMY_HALF_EXTENTS
			)
			_expect(
				not path.is_empty()
				and path[-1].is_equal_approx(player_target),
				"%s必须允许当前最大敌人体型抵达八人位置%s。"
				% [spawn_name, player_target]
			)
	var profile := pathfinder.try_get_agent_navigation_profile(
		MAX_AUTHORED_ENEMY_HALF_EXTENTS
	)
	_expect(profile != null, "最大敌人体型导航Profile必须可同步取得。")
	if profile == null:
		return
	var agent_open_cells: Dictionary[Vector2i, bool] = {}
	for y in range(EXPECTED_WORLD_RECT.position.y, EXPECTED_WORLD_RECT.end.y):
		for x in range(EXPECTED_WORLD_RECT.position.x, EXPECTED_WORLD_RECT.end.x):
			var cell := Vector2i(x, y)
			if not profile.path_grid.is_point_solid(cell):
				agent_open_cells[cell] = true
	_expect(
		agent_open_cells.size()
			== EXPECTED_MAX_ENEMY_OPEN_RECT.size.x
				* EXPECTED_MAX_ENEMY_OPEN_RECT.size.y,
		"最大敌人体型必须保留24×5的120格安全行动区。"
	)
	for y in range(
		EXPECTED_MAX_ENEMY_OPEN_RECT.position.y,
		EXPECTED_MAX_ENEMY_OPEN_RECT.end.y
	):
		for x in range(
			EXPECTED_MAX_ENEMY_OPEN_RECT.position.x,
			EXPECTED_MAX_ENEMY_OPEN_RECT.end.x
		):
			_expect(
				agent_open_cells.has(Vector2i(x, y)),
				"最大敌人体型安全区格%s不得被阻挡。" % Vector2i(x, y)
			)
	_expect(
		_count_four_way_connected_cells(agent_open_cells)
			== agent_open_cells.size(),
		"最大敌人体型的全部安全格必须四方向连通。"
	)


func _test_combat_content(game: RogueCombatGame) -> void:
	_expect(
		game.singleplayer_campaign == UNDERGROUND_SEWER_CAMPAIGN
		and game.multiplayer_campaign == UNDERGROUND_SEWER_CAMPAIGN,
		"地下水道单人与多人默认入口必须绑定专属普通Campaign。"
	)
	for runtime_mode in [
		CombatRuntimeBase.RuntimeMode.SINGLEPLAYER,
		CombatRuntimeBase.RuntimeMode.HOST_AUTHORITY,
	]:
		game.runtime_mode = runtime_mode
		_expect(
			bool(game.call("_configure_active_campaign"))
			and game.active_campaign == UNDERGROUND_SEWER_CAMPAIGN
			and game.waves.size() == 1,
			"地下水道在单人与Host权威模式下必须选择同一份专属Campaign。"
		)
	var waves := UNDERGROUND_SEWER_CAMPAIGN.get_waves()
	_expect(waves.size() == 1, "地下水道Campaign必须只有一个终点波次。")
	if waves.size() != 1:
		return
	var wave := waves[0]
	_expect(
		wave.enemy_entries.size() == 4
		and wave.get_total_enemy_count() == 47
		and _count_enemy(wave, YUANSHI_INSECT_FAST) == 20
		and _count_enemy(wave, YUANSHI_INSECT_FIRE_RANGED) == 20
		and _count_enemy(wave, YUANSHI_INSECT_BOMBER) == 4
		and _count_enemy(wave, CAPOO_MAGE) == 3,
		"地下水道普通作战必须严格配置20迅捷、20火焰弹、4自爆原石虫与3法师Capoo，共47只。"
	)
	_expect(
		is_equal_approx(wave.spawn_interval, 0.2)
		and wave.spawn_count_per_tick == 1
		and wave.max_alive_enemies == 15
		and wave.spawn_point_mask == EXPECTED_SPAWN_MASK
		and wave.get_enabled_spawn_point_names() == [&"Spawn1", &"Spawn2"]
		and wave.spawn_point_order
		== WaveConfig.SpawnPointOrder.BALANCED_SHUFFLE_BAG
		and wave.spawn_order == WaveConfig.SpawnOrder.SHUFFLED,
		"地下水道必须保持0.2秒批1、cap15、mask3与两点均衡乱序。"
	)
	game.random_generator.seed = 20260814
	game.call("_build_wave_spawn_queue", wave)
	_expect(
		game.pending_enemy_configs.size() == 47
		and _count_queued_enemy(game, YUANSHI_INSECT_FAST) == 20
		and _count_queued_enemy(game, YUANSHI_INSECT_FIRE_RANGED) == 20
		and _count_queued_enemy(game, YUANSHI_INSECT_BOMBER) == 4
		and _count_queued_enemy(game, CAPOO_MAGE) == 3,
		"地下水道运行时刷怪队列必须完整保留20/20/4/3的47只敌人。"
	)


func _count_enemy(wave: WaveConfig, enemy_config: EnemyConfig) -> int:
	var result := 0
	for entry in wave.enemy_entries:
		if entry != null and entry.enemy_config == enemy_config:
			result += entry.count
	return result


func _count_queued_enemy(game: RogueCombatGame, enemy_config: EnemyConfig) -> int:
	var result := 0
	for queued_config in game.pending_enemy_configs:
		if queued_config == enemy_config:
			result += 1
	return result


func _is_open_position(ground: TileMapLayer, global_position: Vector2) -> bool:
	var cell := ground.local_to_map(ground.to_local(global_position))
	var tile_data := ground.get_cell_tile_data(cell)
	return tile_data != null and tile_data.get_collision_polygons_count(0) == 0


func _shape_hits_wall(
	center: Vector2,
	probe: Shape2D,
	wall: StaticBody2D
) -> bool:
	var probe_transform := Transform2D(0.0, center)
	for child in wall.get_children():
		var collision_shape := child as CollisionShape2D
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
		for direction: Vector2i in [
			Vector2i.LEFT,
			Vector2i.RIGHT,
			Vector2i.UP,
			Vector2i.DOWN,
		]:
			var neighbor := cell + direction
			if open_cells.has(neighbor) and not visited.has(neighbor):
				pending.append(neighbor)
	return visited.size()


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)


func _finish() -> void:
	if failures.is_empty():
		print("ROGUE_COMBAT_GAME_04_SHELL_SMOKE_TEST_OK")
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	quit(1)
