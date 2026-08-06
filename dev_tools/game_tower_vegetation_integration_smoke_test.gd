extends SceneTree

const TOWER_SCENE := preload("res://scene/game_modes/tower_defense/tower_defense_game.tscn")
const VEGETATION_STAKE_CONFIG := preload(
	"res://resources/config/plant_defense/vegetation_stake.tres"
)
const VEGETATION_RING_TEXTURE := preload(
	"res://resources/lighting/vegetation_ring_point_light.tres"
)
const LEGACY_VEGETATION_RING_RADIUS := 64.0 * 0.52 * 0.5
const AGAVE_CONFIG := preload("res://resources/config/plant_defense/agave_cannon.tres")
const ENEMY_CONFIG := preload("res://resources/config/enemies/capoo_ak47.tres")
const AUTHORITATIVE_BATCH_CELL_COUNT := 193
const LIFECYCLE_PLANT_NET_ID := 900001
const MULTI_CELL_DECAY_PLANT_NET_ID := 900003
const ROSTER_PLANT_NET_ID := 900004
const REALTIME_PLANT_NET_ID := 900005

var failures: Array[String] = []
var emitted_terrain_batches: Array[Dictionary] = []
var lifecycle_events: Array[String] = []
var record_lifecycle_events := false
var lifecycle_plant_was_destroyed := false


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	await _test_vegetation_stake_scene_contract()

	var game := TOWER_SCENE.instantiate() as TowerDefenseGame
	_expect(game != null, "TowerDefenseGame场景必须能够实例化。")
	if game == null:
		_finish()
		return
	game.auto_start_waves = false
	root.add_child(game)
	current_scene = game
	await process_frame
	await process_frame

	_test_preauthored_spread_system(game)
	_test_authoritative_batching(game)
	_test_client_snapshot_replacement_and_revision(game)
	await _test_multiplayer_lifecycle_effect_routing(game)
	await _test_real_plant_lifecycle(game)
	await _test_multi_cell_unsupported_terrain_damage(game)

	game.queue_free()
	await process_frame
	await process_frame
	_finish()


func _test_vegetation_stake_scene_contract() -> void:
	var config := VEGETATION_STAKE_CONFIG as PlantDefenseConfig
	_expect(config != null, "植被桩配置必须能够加载为PlantDefenseConfig。")
	if config == null:
		return
	_expect(config.plant_id == &"vegetation_stake", "植被桩配置ID必须稳定。")
	_expect(config.display_name == "植被桩", "植被桩显示名必须正确。")
	_expect(config.footprint_size == Vector2i.ONE, "植被桩必须严格占用1x1格。")
	_expect(config.supports_multiplayer, "植被桩必须声明完整多人支持。")
	_expect(config.max_health == 4000, "植被桩生命值必须为4000。")
	_expect(config.physical_defense == 10, "植被桩物理防御必须为10。")
	_expect(config.magic_defense == 50, "植被桩法术防御必须为50。")
	_expect(config.attack_damage == 0, "植被桩不能造成攻击伤害。")
	_expect(config.plant_scene != null, "植被桩配置必须引用可实例化场景。")
	if config.plant_scene == null:
		return

	var stake := config.plant_scene.instantiate() as VegetationStake
	_expect(stake != null, "植被桩场景根节点必须为VegetationStake。")
	if stake == null:
		return
	var border := stake.get_node_or_null("CellBorder") as MeshInstance2D
	var main_sprite := stake.get_node_or_null("MainSprite") as Sprite2D
	var top_glow := stake.get_node_or_null("TopGlow") as Sprite2D
	var glow_motes := stake.get_node_or_null("GlowMotes") as GPUParticles2D
	var ring_light := (
		stake.get_node_or_null(
			"CellBorder/NightRingLight"
		) as NightPointLight2D
	)
	var health_bar := stake.get_node_or_null("HealthBar") as PlantHealthBar
	_expect(border != null and border.mesh is QuadMesh, "植被桩场景必须预置地面边框QuadMesh。")
	if border != null and border.mesh is QuadMesh:
		_expect(
			(border.mesh as QuadMesh).size == Vector2(16, 16),
			"植被桩地面边框必须严格覆盖16x16逻辑瓦片。"
		)
	_expect(main_sprite != null and main_sprite.scale == Vector2(0.5, 0.5), "植被桩主体必须沿用0.5像素素材缩放。")
	_expect(top_glow != null and top_glow.texture != null, "植被桩必须预置独立顶部发光层。")
	_expect(glow_motes != null and glow_motes.amount > 0, "植被桩必须预置少量GPU飘光粒子。")
	_expect(
		stake.get_node_or_null("CoreNightLight") == null
		and stake.get_node_or_null("NightRingLight") == null
		and ring_light != null
		and ring_light.get_parent() == border
		and ring_light.texture == VEGETATION_RING_TEXTURE
		and ring_light.color.is_equal_approx(
			Color(0.52, 1.0, 0.24, 1.0)
		)
		and is_equal_approx(ring_light.texture_scale, 0.75)
		and is_equal_approx(ring_light.night_energy, 0.5)
		and is_equal_approx(
			float(VEGETATION_RING_TEXTURE.get_width())
			* ring_light.texture_scale
			* 0.5,
			48.0
		)
		and (
			float(VEGETATION_RING_TEXTURE.get_width())
			* ring_light.texture_scale
			* 0.5
			> LEGACY_VEGETATION_RING_RADIUS * 2.0
		)
		and not ring_light.shadow_enabled,
		"植被桩必须只预置一盏由地块边框控制、中心增亮且半径48像素的绿色夜间环灯。"
	)
	_expect(health_bar != null, "植被桩必须预置并绑定公共植物血条。")
	root.add_child(stake)
	_expect(
		health_bar != null
		and health_bar.position == Vector2(-6, -9)
		and health_bar.size == Vector2(12, 3)
		and health_bar.scale == Vector2.ONE,
		"植被桩血条必须使用12×3逻辑像素的无缩放布局，避免像素栅格闪烁。"
	)
	stake.setup(
		config,
		null,
		[Vector2i.ZERO],
		true,
		config.max_health - 100,
		4,
		config.max_health
	)
	_expect(
		health_bar != null
		and health_bar.visible
		and health_bar.max_health_value == config.max_health,
		"初始残血的植被桩多人代理必须立即显示正确上限的血条。"
	)
	_expect(
		stake.apply_remote_health(config.max_health - 200, config.max_health, 5)
		and health_bar != null
		and health_bar.visible,
		"植被桩多人代理收到更新revision后必须持续刷新并显示残血血条。"
	)
	var sample_now := Time.get_ticks_msec() / 1000.0
	var first_sample_age := minf(sample_now * 0.5, 0.25)
	var first_sample_time := maxf(sample_now - first_sample_age, 0.000001)
	stake.apply_multiplayer_runtime_state(
		{"schema": 1, "spread_elapsed_seconds": 12.0},
		first_sample_time
	)
	var first_elapsed := stake.get_spread_elapsed_seconds()
	_expect(
		absf(first_elapsed - (12.0 + sample_now - first_sample_time)) < 0.1,
		"运行时状态必须计入Host采样后的映射时间。"
	)
	stake.apply_multiplayer_runtime_state(
		{"schema": 1, "spread_elapsed_seconds": 8.0},
		Time.get_ticks_msec() / 1000.0
	)
	_expect(
		stake.get_spread_elapsed_seconds() + 0.001 >= first_elapsed,
		"较旧的重复运行时状态不能让传播时间倒退。"
	)
	var advanced_now := Time.get_ticks_msec() / 1000.0
	var advanced_sample_age := minf(advanced_now * 0.5, 0.5)
	var advanced_sample_time := maxf(
		advanced_now - advanced_sample_age,
		0.000001
	)
	var advanced_raw_elapsed := first_elapsed - advanced_sample_age * 0.5
	stake.apply_multiplayer_runtime_state(
		{"schema": 1, "spread_elapsed_seconds": advanced_raw_elapsed},
		advanced_sample_time
	)
	_expect(
		stake.get_spread_elapsed_seconds() > first_elapsed,
		"原始elapsed较小但映射到当前更先进的状态仍必须被接受。"
	)
	var exported_state := stake.export_multiplayer_runtime_state()
	_expect(
		int(exported_state.get("schema", 0)) == 1
		and float(exported_state.get("spread_elapsed_seconds", -1.0)) <= 50.0,
		"植被桩导出的运行时状态必须保持schema 1并封顶50秒。"
	)
	stake.queue_free()
	await process_frame


func _test_preauthored_spread_system(game: TowerDefenseGame) -> void:
	_expect(game.supports_multiplayer_terrain_state(), "塔防运行时必须启用多人地形状态。")
	var spread_node := game.get_node_or_null("VegetationSpreadSystem")
	_expect(spread_node is VegetationSpreadSystem, "GameTower场景必须预置VegetationSpreadSystem。")
	_expect(
		spread_node == game.vegetation_spread_system,
		"GameTower运行时引用必须指向场景预置的传播系统。"
	)
	if spread_node is VegetationSpreadSystem:
		var overlay := spread_node.get_node_or_null("GrowthOverlay") as MultiMeshInstance2D
		_expect(overlay != null and overlay.multimesh != null, "传播系统必须预置共享MultiMesh覆盖层。")
	var decay_timer := game.get_node_or_null("PlantTerrainDecayTimer") as Timer
	_expect(
		decay_timer != null
		and decay_timer == game.plant_terrain_decay_timer
		and is_equal_approx(decay_timer.wait_time, 1.0)
		and decay_timer.process_callback == Timer.TIMER_PROCESS_PHYSICS
		and not decay_timer.is_stopped(),
		"塔防场景必须预置并启动权威端1秒植物失地衰败Timer。"
	)
	_expect(
		TowerDefenseGame.TERRAIN_NETWORK_BATCH_MAX_CELLS == 96,
		"塔防权威地形网络批次上限必须为96格。"
	)
	_expect(
		int(DualGridTilemap.TerrainType.EMPTY) == -1,
		"多人地形协议必须保留EMPTY=-1。"
	)


func _test_authoritative_batching(game: TowerDefenseGame) -> void:
	_expect(
		game.authored_terrain_baseline.size() >= AUTHORITATIVE_BATCH_CELL_COUNT,
		"塔防 authored baseline 必须足够覆盖193格分块测试。"
	)
	if game.authored_terrain_baseline.size() < AUTHORITATIVE_BATCH_CELL_COUNT:
		return

	var cells: Array[Vector2i] = []
	for cell_variant in game.authored_terrain_baseline.keys():
		cells.append(cell_variant as Vector2i)
	cells.sort_custom(_sort_cells)
	cells.resize(AUTHORITATIVE_BATCH_CELL_COUNT)

	var cell_xy := PackedInt32Array()
	var terrain_types := PackedInt32Array()
	for cell in cells:
		var replacement := _different_terrain_type(
			int(game.authored_terrain_baseline[cell])
		)
		cell_xy.append(cell.x)
		cell_xy.append(cell.y)
		terrain_types.append(replacement)
		# The authoritative signal contract says the batch is already committed.
		game.dual_grid_terrain.set_tile(cell, replacement)

	emitted_terrain_batches.clear()
	if not game.multiplayer_terrain_delta.is_connected(_on_terrain_delta):
		game.multiplayer_terrain_delta.connect(_on_terrain_delta)
	game.runtime_mode = GameRuntimeBase.RuntimeMode.HOST_AUTHORITY
	game.call(
		"_on_authoritative_vegetation_terrain_changed",
		cell_xy,
		terrain_types
	)

	_expect(game.multiplayer_terrain_revision == 3, "193格权威批次必须产生3个连续revision。")
	_expect(game.multiplayer_terrain_overrides.size() == 193, "权威批次必须完整维护193个terrain override。")
	_expect(emitted_terrain_batches.size() == 3, "193格权威批次必须按96/96/1发出三包。")
	var expected_sizes := [96, 96, 1]
	for batch_index in range(emitted_terrain_batches.size()):
		var batch := emitted_terrain_batches[batch_index]
		_expect(
			int(batch.get("revision", -1)) == batch_index + 1,
			"权威地形批次revision必须从1严格连续递增。"
		)
		_expect(
			(batch.get("terrain_types", PackedInt32Array()) as PackedInt32Array).size()
			== expected_sizes[batch_index],
			"第%d个权威地形包格数必须为%d。" % [batch_index + 1, expected_sizes[batch_index]]
		)

	var snapshot := game.get_multiplayer_terrain_snapshot()
	_expect(int(snapshot.get("revision", -1)) == 3, "权威地形快照必须携带当前revision。")
	_expect(
		(snapshot.get("terrain_types", PackedInt32Array()) as PackedInt32Array).size() == 193,
		"权威地形快照必须包含完整override集合。"
	)


func _test_client_snapshot_replacement_and_revision(game: TowerDefenseGame) -> void:
	var empty_target := Vector2i.ZERO
	var found_empty_target := false
	for cell_variant in game.authored_terrain_baseline.keys():
		var cell := cell_variant as Vector2i
		if int(game.authored_terrain_baseline[cell]) != int(DualGridTilemap.TerrainType.EMPTY):
			empty_target = cell
			found_empty_target = true
			break
	_expect(found_empty_target, "测试地图必须至少有一个非EMPTY authored格用于验证EMPTY=-1。")
	if not found_empty_target:
		return

	var restored_cell := Vector2i.ZERO
	var found_restored_cell := false
	for cell_variant in game.multiplayer_terrain_overrides.keys():
		var cell := cell_variant as Vector2i
		if cell != empty_target:
			restored_cell = cell
			found_restored_cell = true
			break
	_expect(found_restored_cell, "客户端完整替换测试必须保留一个将被删除的旧override。")
	if not found_restored_cell:
		return

	game.runtime_mode = GameRuntimeBase.RuntimeMode.CLIENT_VIEW
	var snapshot_applied := game.apply_remote_terrain_snapshot(
		7,
		PackedInt32Array([empty_target.x, empty_target.y]),
		PackedInt32Array([DualGridTilemap.TerrainType.EMPTY])
	)
	_expect(snapshot_applied, "客户端必须接受合法的完整地形快照。")
	_expect(game.multiplayer_terrain_revision == 7, "完整快照必须替换客户端terrain revision。")
	_expect(game.multiplayer_terrain_overrides.size() == 1, "完整快照必须删除所有未列出的旧override。")
	_expect(
		int(game.multiplayer_terrain_overrides.get(empty_target, 99)) == -1,
		"完整快照必须在override字典中保留EMPTY=-1。"
	)
	_expect(
		game.dual_grid_terrain.get_terrain_type(restored_cell)
		== int(game.authored_terrain_baseline[restored_cell]),
		"完整快照必须把缺席的旧override恢复到authored baseline。"
	)
	var replaced_snapshot := game.get_multiplayer_terrain_snapshot()
	_expect(
		(replaced_snapshot.get("terrain_types", PackedInt32Array()) as PackedInt32Array)
		== PackedInt32Array([-1]),
		"导出的客户端快照不能丢弃EMPTY=-1。"
	)

	var baseline_type := int(game.authored_terrain_baseline[empty_target])
	var delta_xy := PackedInt32Array([empty_target.x, empty_target.y])
	var delta_types := PackedInt32Array([baseline_type])
	_expect(
		not game.apply_remote_terrain_delta(9, delta_xy, delta_types),
		"客户端必须拒绝跳过revision 8的地形delta。"
	)
	_expect(game.multiplayer_terrain_revision == 7, "被拒绝的delta不能推进客户端revision。")
	_expect(
		game.dual_grid_terrain.get_terrain_type(empty_target)
		== DualGridTilemap.TerrainType.EMPTY,
		"被拒绝的delta不能部分修改地形。"
	)
	_expect(
		game.apply_remote_terrain_delta(8, delta_xy, delta_types),
		"客户端必须接受恰好下一个revision的合法delta。"
	)
	_expect(game.multiplayer_terrain_revision == 8, "合法delta必须推进一次revision。")
	_expect(game.multiplayer_terrain_overrides.is_empty(), "恢复baseline的delta必须移除对应override。")


func _test_real_plant_lifecycle(game: TowerDefenseGame) -> void:
	var spread := game.vegetation_spread_system
	var plant_system := game.plant_system
	var config := VEGETATION_STAKE_CONFIG as PlantDefenseConfig
	_expect(spread != null and plant_system != null, "真实生命周期测试需要GameTower完整植物与传播系统。")
	if spread == null or plant_system == null or config == null:
		return

	var was_processing := spread.is_processing()
	spread.set_process(false)
	var fixture := _find_lifecycle_fixture(game, config)
	_expect(
		not fixture.is_empty(),
		"实际地图中必须存在合法草地锚点，并在前四圈内包含泥地目标和下一圈临时覆盖格。"
	)
	if fixture.is_empty():
		spread.set_process(was_processing)
		return

	var anchor := fixture["anchor"] as Vector2i
	var target := fixture["target"] as Vector2i
	var pending_target := fixture["pending_target"] as Vector2i
	var target_ring := int(fixture["target_ring"])
	var target_baseline := int(game.authored_terrain_baseline[target])
	_expect(
		game.dual_grid_terrain.get_terrain_type(anchor) == DualGridTilemap.TerrainType.GRASS,
		"真实植被桩锚点必须是草地。"
	)
	_expect(
		plant_system.is_placement_valid_for_player(anchor, config, game.player),
		"真实植被桩锚点必须通过PlantSystem完整合法性检查。"
	)
	_expect(
		target_baseline in [DualGridTilemap.TerrainType.EMPTY, DualGridTilemap.TerrainType.DIRT],
		"真实传播目标的authored baseline必须是EMPTY或DIRT。"
	)

	game.runtime_mode = GameRuntimeBase.RuntimeMode.HOST_AUTHORITY
	if not game.multiplayer_plant_removed.is_connected(_on_lifecycle_plant_removed):
		game.multiplayer_plant_removed.connect(_on_lifecycle_plant_removed)
	var starting_revision := game.multiplayer_terrain_revision
	var plant := plant_system.try_place_for_player(
		config,
		anchor,
		game.player,
		LIFECYCLE_PLANT_NET_ID
	) as VegetationStake
	_expect(plant != null, "PlantSystem必须能用真实vegetation_stake配置完成放置。")
	if plant == null:
		spread.set_process(was_processing)
		return
	var lifecycle_ring_light := plant.get_node_or_null(
		"CellBorder/NightRingLight"
	) as NightPointLight2D
	_expect(
		not plant.is_operational
		and not spread.has_source(LIFECYCLE_PLANT_NET_ID)
		and lifecycle_ring_light != null
		and not lifecycle_ring_light.is_emission_allowed()
		and not lifecycle_ring_light.enabled,
		"植被桩构建完成前必须占格但不能注册传播来源或启用隐藏环灯。"
	)
	await create_timer(PlantDefense.CONSTRUCTION_DURATION_SECONDS + 0.08).timeout
	_expect(
		plant.is_operational
		and spread.has_source(LIFECYCLE_PLANT_NET_ID)
		and lifecycle_ring_light != null
		and lifecycle_ring_light.is_emission_allowed(),
		"植被桩0.7秒构建完成后必须注册传播来源并开放昼夜环灯。"
	)
	_expect(spread.get_source_origin(LIFECYCLE_PLANT_NET_ID) == anchor, "传播来源原点必须等于1x1放置锚点。")
	var health_bar := plant.get_node_or_null("HealthBar") as PlantHealthBar
	_expect(
		health_bar != null and not health_bar.visible,
		"满生命的权威植被桩血条必须保持隐藏。"
	)
	var health_before_damage := plant.current_health
	_expect(
		plant.receive_damage(
			plant.get_effective_physical_defense() + 100,
			null,
			Vector2.ZERO,
			EnemyConfig.DamageType.PHYSICAL
		),
		"权威植被桩必须接受非致死伤害以驱动血条。"
	)
	_expect(
		plant.current_health == health_before_damage - 100
		and health_bar != null
		and health_bar.visible,
		"权威植被桩残血后必须立即显示公共植物血条。"
	)

	spread.advance_time(
		float(target_ring) * VegetationSpreadSystem.SECONDS_PER_RING + 5.0
	)
	spread.call("_process", 0.0)
	_expect(
		game.dual_grid_terrain.get_terrain_type(target) == DualGridTilemap.TerrainType.GRASS,
		"手动推进到第%d圈结算后，真实目标必须变成草地。" % target_ring
	)
	_expect(
		int(game.multiplayer_terrain_overrides.get(target, 99))
		== DualGridTilemap.TerrainType.GRASS,
		"Host结算后的真实目标必须进入terrain override集合。"
	)
	_expect(
		spread.get_overlay_progress(pending_target) > 0.0,
		"结算后继续推进5秒，下一圈必须存在可由死亡清除的临时覆盖。"
	)
	_expect(spread.get_overlay_cell_count() > 0, "下一圈临时覆盖必须已提交到共享MultiMesh。")
	_expect(
		game.multiplayer_terrain_revision == starting_revision + 1,
		"真实传播结算必须只提交一个权威terrain revision。"
	)

	lifecycle_events.clear()
	lifecycle_plant_was_destroyed = false
	record_lifecycle_events = true
	var lethal_damage := plant.current_health + plant.get_effective_physical_defense()
	_expect(
		plant.receive_damage(
			lethal_damage,
			null,
			Vector2.ZERO,
			EnemyConfig.DamageType.PHYSICAL
		),
		"真实植被桩必须接受足以致死的权威物理伤害。"
	)
	record_lifecycle_events = false
	_expect(plant.is_dead, "致死伤害必须进入真实PlantDefense死亡流程。")
	var collapse_voices := get_nodes_in_group(
		PlantRemovalSmoke.COLLAPSE_AUDIO_GROUP
	)
	_expect(
		lifecycle_plant_was_destroyed
		and collapse_voices.size() == 1
		and (collapse_voices[0] as AudioStreamPlayer2D).playing,
		"真实建筑死亡必须标记可靠摧毁原因，并启动一次池化空间垮塌声。"
	)
	_expect(
		lifecycle_ring_light != null
		and not lifecycle_ring_light.is_emission_allowed()
		and not lifecycle_ring_light.enabled,
		"植被桩进入拆除生命周期时必须立即关闭隐藏环灯。"
	)
	_expect(
		plant_system.get_plant_by_net_id(LIFECYCLE_PLANT_NET_ID) == null,
		"PlantSystem死亡回调必须立即释放真实植被桩net_id。"
	)
	_expect(
		not spread.has_source(LIFECYCLE_PLANT_NET_ID),
		"PlantSystem removal必须同步触发传播来源cancel。"
	)
	_expect(
		spread.get_overlay_cell_count() > 0,
		"来源cancel只能标记覆盖层为脏，不能在死亡调用栈内同步重建MultiMesh。"
	)
	spread.call("_process", 0.0)
	_expect(spread.get_overlay_cell_count() == 0, "真实植被桩死亡后的下一次覆盖冲刷必须清空临时实例。")
	_expect(
		game.dual_grid_terrain.get_terrain_type(target) == target_baseline,
		"真实植被桩死亡必须把目标精确恢复到authored EMPTY/DIRT baseline。"
	)
	_expect(
		not game.multiplayer_terrain_overrides.has(target),
		"恢复baseline后必须从Host terrain override集合删除目标。"
	)
	_expect(game.multiplayer_terrain_overrides.is_empty(), "真实来源销毁后不能残留任何传播override。")
	_expect(
		game.multiplayer_terrain_revision == starting_revision + 2,
		"真实来源销毁与地形恢复必须再提交一个连续terrain revision。"
	)
	_expect(
		lifecycle_events == ["plant_removed", "terrain_delta"],
		"真实Host死亡链路必须先发植物移除，再发同通道地形恢复delta。"
	)

	await process_frame
	spread.set_process(was_processing)


func _test_multiplayer_lifecycle_effect_routing(game: TowerDefenseGame) -> void:
	var plant_system := game.plant_system
	var config := VEGETATION_STAKE_CONFIG as PlantDefenseConfig
	if plant_system == null or config == null:
		failures.append("多人生命周期路由测试需要真实PlantSystem与植被桩配置。")
		return
	var anchors := plant_system.get_valid_anchors_for_player(config, game.player)
	_expect(not anchors.is_empty(), "多人生命周期路由测试需要至少一个合法植被桩锚点。")
	if anchors.is_empty():
		return

	game.runtime_mode = GameRuntimeBase.RuntimeMode.CLIENT_VIEW
	var anchor := anchors[0]
	game.apply_remote_plant_spawn(
		0,
		2,
		ROSTER_PLANT_NET_ID,
		config.plant_id,
		anchor,
		config.max_health,
		config.max_health,
		1
	)
	var roster_plant := game.get_multiplayer_plant_node(
		ROSTER_PLANT_NET_ID
	) as VegetationStake
	_expect(
		roster_plant != null
		and roster_plant.is_operational
		and not roster_plant.is_construction_visual_active()
		and game.get_tree().get_nodes_in_group(
			PlantPlacementParticles.PLACEMENT_AUDIO_GROUP
		).is_empty(),
		"迟加入roster与修复包的request_id=0必须直接显示完整建筑且保持静音。"
	)
	game.apply_remote_plant_removed_silently(ROSTER_PLANT_NET_ID)
	_expect(
		roster_plant != null
		and roster_plant.is_removing
		and roster_plant.removal_mode == PlantDefense.RemovalMode.SILENT
		and game.get_multiplayer_plant_node(ROSTER_PLANT_NET_ID) == null,
		"manifest纠偏必须静默并在调用栈内释放客户端植物索引。"
	)
	await process_frame

	game.apply_remote_plant_spawn(
		77,
		2,
		REALTIME_PLANT_NET_ID,
		config.plant_id,
		anchor,
		config.max_health,
		config.max_health,
		1
	)
	var realtime_plant := game.get_multiplayer_plant_node(
		REALTIME_PLANT_NET_ID
	) as VegetationStake
	_expect(
		realtime_plant != null
		and not realtime_plant.is_operational
		and realtime_plant.is_construction_visual_active()
		and int(game.session_object_pool.get_metrics(
			"res://scene/plant_defense/effects/plant_placement_particles.tscn"
		).get("in_use", 0)) == 1
		and game.get_tree().get_nodes_in_group(
			PlantPlacementParticles.PLACEMENT_AUDIO_GROUP
		).size() == 1,
		"实时客户端request_id>0必须播放0.7秒生成效果与一次空间放置声。"
	)
	if realtime_plant == null:
		game.runtime_mode = GameRuntimeBase.RuntimeMode.HOST_AUTHORITY
		return

	# Keep ample distance from the 0.305 s cue's natural finish so a slow
	# headless frame cannot turn the duplicate-spawn assertion into a timing
	# false negative.
	await create_timer(0.08).timeout
	var main_sprite := realtime_plant.get_node("MainSprite") as Sprite2D
	var progress_before_duplicate := float(
		main_sprite.get_instance_shader_parameter(&"construction_progress")
	)
	game.apply_remote_plant_spawn(
		0,
		2,
		REALTIME_PLANT_NET_ID,
		config.plant_id,
		anchor,
		config.max_health,
		config.max_health,
		1
	)
	_expect(
		game.get_multiplayer_plant_node(REALTIME_PLANT_NET_ID) == realtime_plant
		and is_equal_approx(
			float(main_sprite.get_instance_shader_parameter(&"construction_progress")),
			progress_before_duplicate
		)
		and game.get_tree().get_nodes_in_group(
			PlantPlacementParticles.PLACEMENT_AUDIO_GROUP
		).size() == 1,
		"重复spawn必须复用现有副本，且不能重启生成视觉或放置声。"
	)

	var enemy := ENEMY_CONFIG.enemy_scene.instantiate() as Enemy
	game.enemy_container.add_child(enemy)
	enemy.setup(ENEMY_CONFIG, game.player)
	enemy.set_physics_process(false)
	enemy.set_objective_target(realtime_plant)
	game.apply_remote_plant_removed(REALTIME_PLANT_NET_ID)
	_expect(
		realtime_plant.is_removing
		and not realtime_plant.is_dead
		and realtime_plant.removal_mode == PlantDefense.RemovalMode.ANIMATED
		and game.get_multiplayer_plant_node(REALTIME_PLANT_NET_ID) == null
		and enemy.objective_target == null,
		"reliable remove必须显式溶解非死亡副本，并在同一调用栈释放索引与敌人目标引用。"
	)
	var active_smoke: PlantRemovalSmoke = null
	for pool_child in game.session_object_pool.get_children():
		var smoke_candidate := pool_child as PlantRemovalSmoke
		if (
			smoke_candidate != null
			and bool(smoke_candidate.get_meta(&"pool_active", false))
		):
			active_smoke = smoke_candidate
			break
	_expect(active_smoke != null, "reliable remove必须从受限对象池启动一份死亡烟雾。")
	# DummyRenderer不会稳定推进GPU粒子的finished；手动发出原生信号只负责
	# 确认生产中的 finished -> pool release 接口。
	if active_smoke != null:
		active_smoke.finished.emit()
	enemy.queue_free()
	await create_timer(PlantDefense.REMOVAL_DURATION_SECONDS + 0.08).timeout
	await process_frame
	await physics_frame
	await physics_frame
	_expect(not is_instance_valid(realtime_plant), "reliable remove残影必须在0.7秒后释放。")
	var placement_metrics := game.session_object_pool.get_metrics(
		"res://scene/plant_defense/effects/plant_placement_particles.tscn"
	)
	var smoke_metrics := game.session_object_pool.get_metrics(
		"res://scene/plant_defense/effects/plant_removal_smoke.tscn"
	)
	_expect(
		int(placement_metrics.get("in_use", -1)) == 0
		and int(placement_metrics.get("pending_release", -1)) == 0
		and int(smoke_metrics.get("in_use", -1)) == 0
		and int(smoke_metrics.get("pending_release", -1)) == 0
		and game.get_tree().get_nodes_in_group(
			PlantPlacementParticles.PLACEMENT_AUDIO_GROUP
		).is_empty(),
		"实时生成后提前撤除时，两套粒子租约与放置声部最终都必须完整释放。"
	)
	game.runtime_mode = GameRuntimeBase.RuntimeMode.HOST_AUTHORITY


func _test_multi_cell_unsupported_terrain_damage(game: TowerDefenseGame) -> void:
	var config := AGAVE_CONFIG as PlantDefenseConfig
	var plant_system := game.plant_system
	_expect(config != null and plant_system != null, "2x2失地衰败测试需要龙舌兰配置与PlantSystem。")
	if config == null or plant_system == null:
		return

	game.runtime_mode = GameRuntimeBase.RuntimeMode.HOST_AUTHORITY
	var valid_anchors := plant_system.get_valid_anchors_for_player(config, game.player)
	_expect(not valid_anchors.is_empty(), "真实地图必须保留可放置2x2植物的草地锚点。")
	if valid_anchors.is_empty():
		return
	var plant := plant_system.try_place_for_player(
		config,
		valid_anchors[0],
		game.player,
		MULTI_CELL_DECAY_PLANT_NET_ID
	) as AgaveCannon
	_expect(plant != null, "PlantSystem必须能放置2x2衰败测试植物。")
	if plant == null:
		return
	plant.attack_timer.stop()
	_expect(plant.footprint_cells.size() == 4, "龙舌兰衰败测试必须覆盖完整2x2占地。")

	var original_terrain: Dictionary[Vector2i, int] = {}
	for cell in plant.footprint_cells:
		var terrain_type := game.dual_grid_terrain.get_terrain_type(cell)
		original_terrain[cell] = terrain_type
		_expect(
			terrain_type == DualGridTilemap.TerrainType.GRASS,
			"合法放置的2x2植物所有占地格初始都必须是草地。"
		)
		game.dual_grid_terrain.set_tile(cell, DualGridTilemap.TerrainType.DIRT)

	var full_health := plant.current_health
	game.runtime_mode = GameRuntimeBase.RuntimeMode.CLIENT_VIEW
	game.plant_terrain_decay_timer.timeout.emit()
	_expect(
		plant.current_health == full_health,
		"CLIENT_VIEW不能本地结算2x2植物的失地衰败伤害。"
	)
	game.runtime_mode = GameRuntimeBase.RuntimeMode.HOST_AUTHORITY
	game.plant_terrain_decay_timer.timeout.emit()
	_expect(
		plant.current_health == full_health - 200,
		"2x2植物即使四格全部失去草地，每个tick也只能无视防御扣一次当前生命10%。"
	)
	for cell in plant.footprint_cells:
		game.dual_grid_terrain.set_tile(cell, original_terrain[cell])
	var restored_health := plant.current_health
	game.plant_terrain_decay_timer.timeout.emit()
	_expect(
		plant.current_health == restored_health,
		"2x2植物全部占地恢复草地后必须立即停止衰败。"
	)
	_expect(
		plant.receive_unmitigated_damage(plant.current_health - 501),
		"衰败下限测试必须能把2x2植物准备到501点生命。"
	)
	for cell in plant.footprint_cells:
		game.dual_grid_terrain.set_tile(cell, DualGridTilemap.TerrainType.DIRT)
	game.plant_terrain_decay_timer.timeout.emit()
	_expect(
		plant.current_health == 450,
		"501点当前生命的衰败伤害必须向上取整为51。"
	)
	game.plant_terrain_decay_timer.timeout.emit()
	_expect(
		plant.current_health == 400,
		"当前生命低于500后，衰败伤害必须保持每秒最低50点。"
	)
	for cell in plant.footprint_cells:
		game.dual_grid_terrain.set_tile(cell, original_terrain[cell])
	plant.receive_unmitigated_damage(plant.current_health)
	_expect(
		plant_system.get_plant_by_net_id(MULTI_CELL_DECAY_PLANT_NET_ID) == null,
		"2x2衰败测试植物死亡后必须释放net_id与占地。"
	)
	await process_frame


func _find_lifecycle_fixture(
	game: TowerDefenseGame,
	config: PlantDefenseConfig
) -> Dictionary:
	var anchors := game.plant_system.get_valid_anchors_for_player(config, game.player)
	for anchor in anchors:
		for ring in range(1, VegetationSpreadSystem.SPREAD_RADIUS):
			var target := _find_authored_spread_cell(game, anchor, ring)
			if target == Vector2i.MAX:
				continue
			var pending_target := _find_authored_spread_cell(game, anchor, ring + 1)
			if pending_target == Vector2i.MAX:
				continue
			return {
				"anchor": anchor,
				"target": target,
				"pending_target": pending_target,
				"target_ring": ring,
			}
	return {}


func _find_authored_spread_cell(
	game: TowerDefenseGame,
	anchor: Vector2i,
	ring: int
) -> Vector2i:
	for offset in VegetationSpreadSystem.get_ring_offsets(ring):
		var cell := anchor + offset
		if not game.authored_terrain_baseline.has(cell):
			continue
		var baseline := int(game.authored_terrain_baseline[cell])
		if baseline in [DualGridTilemap.TerrainType.EMPTY, DualGridTilemap.TerrainType.DIRT]:
			return cell
	return Vector2i.MAX


func _different_terrain_type(baseline_type: int) -> int:
	return (
		DualGridTilemap.TerrainType.DIRT
		if baseline_type == DualGridTilemap.TerrainType.GRASS
		else DualGridTilemap.TerrainType.GRASS
	)


func _sort_cells(a: Vector2i, b: Vector2i) -> bool:
	if a.y == b.y:
		return a.x < b.x
	return a.y < b.y


func _on_terrain_delta(
	revision: int,
	cell_xy: PackedInt32Array,
	terrain_types: PackedInt32Array
) -> void:
	emitted_terrain_batches.append({
		"revision": revision,
		"cell_xy": cell_xy.duplicate(),
		"terrain_types": terrain_types.duplicate(),
	})
	if record_lifecycle_events:
		lifecycle_events.append("terrain_delta")


func _on_lifecycle_plant_removed(net_id: int, was_destroyed: bool) -> void:
	if record_lifecycle_events and net_id == LIFECYCLE_PLANT_NET_ID:
		lifecycle_events.append("plant_removed")
		lifecycle_plant_was_destroyed = was_destroyed


func _finish() -> void:
	if failures.is_empty():
		print("GAME_TOWER_VEGETATION_INTEGRATION_SMOKE_TEST_OK")
		quit()
		return
	for failure in failures:
		push_error(failure)
	quit(1)


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
