extends SceneTree

const GAME_SCENE := preload("res://scene/game.tscn")
const TOWER_SCENE := preload("res://scene/game_tower_defense.tscn")
const DAY_NIGHT_SCENE := preload(
	"res://scene/lighting/day_night_controller.tscn"
)
const NIGHT_LIGHT_SCENE := preload(
	"res://scene/lighting/night_point_light.tscn"
)
const VEGETATION_STAKE_SCENE := preload(
	"res://scene/plant_defense/vegetation_stake.tscn"
)
const PLAYER_SCENES: Array[PackedScene] = [
	preload("res://scene/player/weishidaier/player_weishidaier.tscn"),
	preload("res://scene/player/hoe_cat/player_hoe_cat.tscn"),
	preload("res://scene/player/tiyi/player_tiyi.tscn"),
]
const NPC_SCENE_FIXTURES: Array[Dictionary] = [
	{
		"label": "庄方宜",
		"scene": preload("res://scene/zhuangfangyi_merchant.tscn"),
	},
	{
		"label": "洛曦",
		"scene": preload("res://scene/luoxi_merchant.tscn"),
	},
]
const SOFT_WHITE_TEXTURE := preload(
	"res://resources/lighting/soft_white_point_light.tres"
)
const SOFT_PLAYER_TEXTURE := preload(
	"res://resources/lighting/soft_player_point_light.tres"
)
const SOFT_MICRO_TEXTURE := preload(
	"res://resources/lighting/soft_micro_point_light.tres"
)
const VEGETATION_RING_TEXTURE := preload(
	"res://resources/lighting/vegetation_ring_point_light.tres"
)
const LEGACY_VEGETATION_RING_RADIUS := 64.0 * 0.52 * 0.5
const MIN_EXPANDED_VEGETATION_RING_RADIUS := (
	LEGACY_VEGETATION_RING_RADIUS * 2.0
)

var failures: Array[String] = []


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	await _test_controller_and_day_suppression()
	await _test_parallel_world_isolation()
	await _test_vegetation_ring_night_behavior()
	await _test_npc_night_behavior()
	_test_authored_scene_contracts()
	await _test_every_wave_gradual_transition()
	await _test_tower_wave_lighting()
	await _test_fresh_client_remote_flow_lighting()
	for _cleanup_frame in range(4):
		await process_frame
		await physics_frame
	call_deferred("_finish")


func _test_controller_and_day_suppression() -> void:
	var test_root := Node2D.new()
	root.add_child(test_root)
	var controller := DAY_NIGHT_SCENE.instantiate() as DayNightController
	var light := NIGHT_LIGHT_SCENE.instantiate() as NightPointLight2D
	var factor_signal_count: Array[int] = [0]
	controller.night_factor_changed.connect(
		func(_factor: float) -> void:
			factor_signal_count[0] += 1
	)
	test_root.add_child(controller)
	test_root.add_child(light)
	await process_frame

	_expect(
		controller != null
		and controller.color.is_equal_approx(Color.WHITE)
		and is_zero_approx(controller.night_factor)
		and is_equal_approx(controller.transition_duration, 5.0),
		"昼夜控制器必须以纯白白天状态启动，并使用5秒默认渐变。"
	)
	var signal_count_before_repeated_factor: int = factor_signal_count[0]
	controller.set_night_factor_immediate(0.0)
	light.set_night_factor(0.0)
	_expect(
		factor_signal_count[0] == signal_count_before_repeated_factor,
		"重复写入相同昼夜因子时不得产生冗余的全灯广播。"
	)
	_expect(
		light != null
		and not light.enabled
		and is_zero_approx(light.energy)
		and not light.shadow_enabled
		and not light.is_processing()
		and not light.is_physics_processing(),
		"白天灯光必须彻底禁用，且常驻PointLight2D不得注册逐帧脚本处理。"
	)

	controller.transition_to_night(0.0)
	_expect(
		controller.is_night()
		and controller.color.is_equal_approx(
			DayNightController.REFERENCE_NIGHT_COLOR
		)
		and light.enabled
		and is_equal_approx(light.energy, light.night_energy),
		"立即切换黑夜时必须应用#577B9E环境色与完整灯光能量。"
	)
	var signal_count_at_night: int = factor_signal_count[0]
	controller.set_night_factor_immediate(1.0)
	_expect(
		factor_signal_count[0] == signal_count_at_night,
		"重复写入夜间终点不得再次广播所有局部灯。"
	)
	controller.transition_to_day(0.0)
	_expect(
		controller.color.is_equal_approx(Color.WHITE)
		and not light.enabled
		and is_zero_approx(light.energy),
		"重回白天必须恢复纯白环境色并关闭灯光。"
	)

	test_root.queue_free()
	await process_frame


func _test_parallel_world_isolation() -> void:
	var viewport_a := SubViewport.new()
	viewport_a.size = Vector2i(64, 64)
	viewport_a.disable_3d = true
	viewport_a.render_target_update_mode = SubViewport.UPDATE_DISABLED
	root.add_child(viewport_a)
	var viewport_b := SubViewport.new()
	viewport_b.size = Vector2i(64, 64)
	viewport_b.disable_3d = true
	viewport_b.render_target_update_mode = SubViewport.UPDATE_DISABLED
	root.add_child(viewport_b)
	var world_a := Node2D.new()
	var world_b := Node2D.new()
	viewport_a.add_child(world_a)
	viewport_b.add_child(world_b)
	var controller_a := DAY_NIGHT_SCENE.instantiate() as DayNightController
	var controller_b := DAY_NIGHT_SCENE.instantiate() as DayNightController
	var light_a := NIGHT_LIGHT_SCENE.instantiate() as NightPointLight2D
	var light_b := NIGHT_LIGHT_SCENE.instantiate() as NightPointLight2D
	world_a.add_child(controller_a)
	world_a.add_child(light_a)
	world_b.add_child(controller_b)
	world_b.add_child(light_b)
	await process_frame

	controller_a.transition_to_night(0.0)
	_expect(
		light_a.enabled
		and light_a.energy > 0.0
		and not light_b.enabled
		and is_zero_approx(light_b.energy)
		and controller_b.color.is_equal_approx(Color.WHITE),
		"并存的两个游戏世界必须各自控制灯光，不能跨场景串扰。"
	)
	controller_b.transition_to_night(0.0)
	controller_a.transition_to_day(0.0)
	_expect(
		not light_a.enabled
		and is_zero_approx(light_a.energy)
		and light_b.enabled
		and light_b.energy > 0.0
		and controller_b.is_night(),
		"任一世界回到白天时，不得关闭另一个世界的夜间灯光。"
	)

	viewport_a.queue_free()
	viewport_b.queue_free()
	await process_frame


func _test_vegetation_ring_night_behavior() -> void:
	var test_root := Node2D.new()
	root.add_child(test_root)
	var controller := DAY_NIGHT_SCENE.instantiate() as DayNightController
	var stake := VEGETATION_STAKE_SCENE.instantiate() as VegetationStake
	test_root.add_child(controller)
	test_root.add_child(stake)
	await process_frame

	var ring_light := (
		stake.get_node_or_null(
			"CellBorder/NightRingLight"
		) as NightPointLight2D
	)
	_expect(
		ring_light != null,
		"植被桩场景必须预置绿色夜间环灯。"
	)
	if ring_light == null:
		test_root.queue_free()
		await process_frame
		return
	_expect(
		not ring_light.enabled
		and is_zero_approx(ring_light.energy),
		"植被桩环灯在白天必须彻底关闭。"
	)
	controller.transition_to_night(0.0)
	_expect(
		ring_light.enabled
		and is_equal_approx(
			ring_light.energy,
			ring_light.night_energy
		)
		and ring_light.is_visible_in_tree(),
		"植被桩绿色环灯必须只在夜间以完整配置能量显示。"
	)
	stake.call("_on_construction_started")
	_expect(
		not ring_light.is_emission_allowed()
		and not ring_light.enabled
		and is_zero_approx(ring_light.energy)
		and not ring_light.is_visible_in_tree(),
		"植被桩建造时必须同时隐藏环灯并停止其夜间能量更新。"
	)
	stake.call("_on_construction_finished", false)
	_expect(
		ring_light.is_emission_allowed()
		and ring_light.enabled
		and is_equal_approx(ring_light.energy, ring_light.night_energy)
		and ring_light.is_visible_in_tree(),
		"植被桩建造完成后必须恢复夜间光环与额定能量。"
	)
	stake.call("_on_removal_started", PlantDefense.RemovalMode.SILENT)
	_expect(
		not ring_light.is_emission_allowed()
		and not ring_light.enabled
		and is_zero_approx(ring_light.energy)
		and not ring_light.is_visible_in_tree(),
		"植被桩拆除时必须立即禁用隐藏的夜间环灯。"
	)

	test_root.queue_free()
	await process_frame


func _test_npc_night_behavior() -> void:
	var test_root := Node2D.new()
	test_root.name = "NpcNightLightingSmokeWorld"
	root.add_child(test_root)
	var controller := DAY_NIGHT_SCENE.instantiate() as DayNightController
	test_root.add_child(controller)

	for fixture in NPC_SCENE_FIXTURES:
		var label := String(fixture["label"])
		var npc_scene := fixture["scene"] as PackedScene
		var npc := npc_scene.instantiate() as Node2D
		test_root.add_child(npc)
		await process_frame
		await process_frame

		var npc_light := (
			npc.get_node_or_null("NightLight") as NightPointLight2D
		)
		_expect(
			npc_light != null
			and npc_light.texture == SOFT_PLAYER_TEXTURE
			and is_equal_approx(
				SOFT_PLAYER_TEXTURE.width * npc_light.texture_scale,
				120.0
			)
			and is_equal_approx(npc_light.night_energy, 0.56)
			and not npc_light.shadow_enabled,
			"%s必须复用玩家的120像素、0.56能量无阴影柔光。" % label
		)
		if npc_light == null:
			npc.queue_free()
			await process_frame
			continue
		_expect(
			bool(npc.get("is_active"))
			and npc.visible
			and npc_light.is_emission_allowed()
			and not npc_light.enabled
			and is_zero_approx(npc_light.energy),
			"%s白天可见时应许可夜灯，但必须保持零能量关闭。" % label
		)

		controller.set_night_factor_immediate(1.0)
		_expect(
			npc_light.enabled
			and is_equal_approx(npc_light.energy, 0.56),
			"%s进入夜晚后必须达到与玩家相同的完整亮度。" % label
		)
		npc.call("set_active", false)
		_expect(
			not bool(npc.get("is_active"))
			and not npc.visible
			and not npc_light.is_emission_allowed()
			and not npc_light.enabled
			and is_zero_approx(npc_light.energy),
			"%s隐藏时必须同步停止发光并归零能量。" % label
		)
		npc.call("set_active", true)
		_expect(
			npc.visible
			and npc_light.is_emission_allowed()
			and npc_light.enabled
			and is_equal_approx(npc_light.energy, 0.56),
			"%s在夜晚重新激活后必须立即恢复玩家同等级柔光。" % label
		)
		controller.set_night_factor_immediate(0.0)
		_expect(
			not npc_light.enabled and is_zero_approx(npc_light.energy),
			"%s返回白天后必须关闭真实灯光。" % label
		)

		npc.queue_free()
		await process_frame

	test_root.queue_free()
	await process_frame


func _test_authored_scene_contracts() -> void:
	_expect(
		SOFT_WHITE_TEXTURE is GradientTexture2D
		and SOFT_WHITE_TEXTURE.width == 256
		and SOFT_WHITE_TEXTURE.height == 256
		and SOFT_WHITE_TEXTURE.fill == GradientTexture2D.FILL_RADIAL
		and not SOFT_WHITE_TEXTURE.use_hdr
		and SOFT_WHITE_TEXTURE.gradient.sample(0.0).r > 0.95
		and SOFT_WHITE_TEXTURE.gradient.sample(0.5).r > 0.45
		and SOFT_WHITE_TEXTURE.gradient.sample(0.5).r < 0.5
		and SOFT_WHITE_TEXTURE.gradient.sample(0.86).r > 0.055
		and SOFT_WHITE_TEXTURE.gradient.sample(0.86).r < 0.07
		and SOFT_WHITE_TEXTURE.gradient.sample(1.0).r < 0.01,
		"背景柔光必须使用256×256多段径向渐变，避免低分辨率采样形成网格或色阶。"
	)
	_expect(
		SOFT_MICRO_TEXTURE is GradientTexture2D
		and SOFT_MICRO_TEXTURE.width == 32
		and SOFT_MICRO_TEXTURE.height == 32
		and SOFT_MICRO_TEXTURE.fill == GradientTexture2D.FILL_RADIAL
		and SOFT_MICRO_TEXTURE.gradient.sample(0.0).r > 0.95
		and SOFT_MICRO_TEXTURE.gradient.sample(1.0).r < 0.01,
		"状态格微光必须使用独立的小半径连续径向纹理。"
	)
	_expect(
		SOFT_PLAYER_TEXTURE is GradientTexture2D
		and SOFT_PLAYER_TEXTURE.width == 256
		and SOFT_PLAYER_TEXTURE.height == 256
		and SOFT_PLAYER_TEXTURE.fill
		== GradientTexture2D.FILL_RADIAL
		and SOFT_PLAYER_TEXTURE.gradient.sample(0.82).r
		> 0.06
		and SOFT_PLAYER_TEXTURE.gradient.sample(0.82).r
		< 0.07
		and SOFT_PLAYER_TEXTURE.gradient.sample(0.9).r
		> 0.015
		and SOFT_PLAYER_TEXTURE.gradient.sample(0.9).r
		< 0.02
		and SOFT_PLAYER_TEXTURE.gradient.sample(0.96).r
		< 0.005
		and SOFT_PLAYER_TEXTURE.gradient.sample(1.0).r
		< 0.001,
		"玩家柔光必须使用低亮度长尾径向渐变，让最外缘连续衰减至不可见。"
	)
	var vegetation_ring_gradient := VEGETATION_RING_TEXTURE.gradient
	_expect(
		VEGETATION_RING_TEXTURE is GradientTexture2D
		and VEGETATION_RING_TEXTURE.width == 128
		and VEGETATION_RING_TEXTURE.height == 128
		and VEGETATION_RING_TEXTURE.fill
		== GradientTexture2D.FILL_RADIAL
		and vegetation_ring_gradient != null
		and vegetation_ring_gradient.sample(0.0).r < 0.001
		and vegetation_ring_gradient.sample(0.13).r > 0.03
		and vegetation_ring_gradient.sample(0.13).r < 0.04
		and vegetation_ring_gradient.sample(0.223).r > 0.99
		and vegetation_ring_gradient.sample(0.297).r > 0.31
		and vegetation_ring_gradient.sample(0.297).r < 0.33
		and vegetation_ring_gradient.sample(0.48).r > 0.17
		and vegetation_ring_gradient.sample(0.48).r < 0.19
		and vegetation_ring_gradient.sample(0.7).r > 0.1
		and vegetation_ring_gradient.sample(0.7).r < 0.11
		and vegetation_ring_gradient.sample(0.85).r > 0.045
		and vegetation_ring_gradient.sample(0.85).r < 0.06
		and vegetation_ring_gradient.sample(0.95).r > 0.005
		and vegetation_ring_gradient.sample(0.95).r < 0.02
		and vegetation_ring_gradient.sample(1.0).r < 0.001,
		"植被桩环灯必须保留核心亮环，并以128采样向两倍以上半径平滑衰减。"
	)

	for player_scene in PLAYER_SCENES:
		var player := player_scene.instantiate() as Player
		var player_light := (
			player.get_node_or_null("NightLight") as NightPointLight2D
		)
		_expect(
			player_light != null
			and player_light.texture == SOFT_PLAYER_TEXTURE
			and is_equal_approx(
				SOFT_PLAYER_TEXTURE.width
				* player_light.texture_scale,
				120.0
			)
			and is_equal_approx(player_light.night_energy, 0.56)
			and not player_light.shadow_enabled,
			"玩家灯光必须使用120像素低能量长尾柔光，弱化最外圈边界。"
		)
		player.free()

	var stake := VEGETATION_STAKE_SCENE.instantiate() as VegetationStake
	var motes := (
		stake.get_node_or_null("GlowMotes") as GPUParticles2D
	)
	var mote_material := motes.material as CanvasItemMaterial
	var ring_light := (
		stake.get_node_or_null(
			"CellBorder/NightRingLight"
		) as NightPointLight2D
	)
	var stake_lights := _collect_night_lights(stake)
	_expect(
		stake_lights.size() == 1
		and ring_light != null
		and ring_light.get_parent()
		== stake.get_node_or_null("CellBorder")
		and ring_light.texture == VEGETATION_RING_TEXTURE
		and ring_light.color.is_equal_approx(
			Color(0.52, 1.0, 0.24, 1.0)
		)
		and is_equal_approx(ring_light.texture_scale, 0.56)
		and is_equal_approx(ring_light.night_energy, 0.4)
		and (
			float(VEGETATION_RING_TEXTURE.get_width())
			* ring_light.texture_scale
			* 0.5
			> MIN_EXPANDED_VEGETATION_RING_RADIUS
		)
		and not ring_light.shadow_enabled
		and stake.get_node_or_null("CoreNightLight") == null
		and stake.get_node_or_null("NightRingLight") == null,
		"植被桩必须只保留一盏核心亮度稳定、半径超过旧版两倍的柔和绿色夜间环灯。"
	)
	_expect(
		motes.texture == null
		and motes.texture_filter == CanvasItem.TEXTURE_FILTER_NEAREST
		and mote_material != null
		and mote_material.blend_mode
		== CanvasItemMaterial.BLEND_MODE_MIX
		and mote_material.light_mode
		== CanvasItemMaterial.LIGHT_MODE_UNSHADED,
		"植被桩粒子必须保持最近邻、普通混合和UNSHADED，只让粒子自身不受夜色压暗。"
	)
	stake.free()

	var game := GAME_SCENE.instantiate() as Game
	_expect(
		game.get_node_or_null("DayNightController") is DayNightController,
		"普通模式主场景必须直接包含昼夜CanvasModulate控制器。"
	)
	var standard_all_lights := _collect_night_lights(game)
	var standard_npc_lights := _collect_merchant_night_lights(game)
	var standard_gate_lights := _collect_night_lights(
		game.get_node("EnemySpawnPoints")
	)
	_expect(
		standard_all_lights.size() == 7
		and standard_npc_lights.size() == 2
		and standard_gate_lights.size() == 5,
		"普通模式必须常驻5盏红门灯与2盏NPC灯。"
	)
	for gate_light in standard_gate_lights:
		_expect(
			gate_light.texture == SOFT_WHITE_TEXTURE
			and gate_light.night_energy <= 0.3
			and not gate_light.shadow_enabled,
			"普通模式红门必须共享低亮度柔白纹理并关闭阴影。"
		)
	game.free()

	var tower := TOWER_SCENE.instantiate() as GameTowerDefense
	_expect(
		tower.get_node_or_null("DayNightController") is DayNightController,
		"塔防主场景必须直接包含昼夜CanvasModulate控制器。"
	)
	var tower_all_lights := _collect_night_lights(tower)
	var tower_npc_lights := _collect_merchant_night_lights(tower)
	var red_gate_lights := _collect_night_lights(
		tower.get_node("EnemySpawnPoints")
	)
	_expect(
		tower_all_lights.size() == 9
		and tower_npc_lights.size() == 2
		and red_gate_lights.size() == 6,
		"塔防地图必须常驻6盏红门灯、1盏蓝门灯与2盏NPC灯。"
	)
	for gate_light in red_gate_lights:
		_expect(
			gate_light.texture == SOFT_WHITE_TEXTURE
			and gate_light.night_energy <= 0.35
			and not gate_light.shadow_enabled,
			"门灯必须共享低亮度柔白纹理并关闭阴影。"
		)
	var blue_light := tower.get_node_or_null(
		"HomeGateController/BlueGateNightLight"
	) as NightPointLight2D
	_expect(
		blue_light != null
		and blue_light.position == Vector2(48, 368)
		and blue_light.texture == SOFT_WHITE_TEXTURE
		and blue_light.night_energy <= 0.35
		and not blue_light.shadow_enabled,
		"蓝门灯光必须位于2×2蓝门的几何中心。"
	)
	tower.free()


func _test_every_wave_gradual_transition() -> void:
	var run_state := root.get_node_or_null("RunState") as RunStateStore
	if run_state != null:
		run_state.set_selected_character(
			PlayerCharacterRegistry.WEISHIDAIER_ID
		)
	var game := GAME_SCENE.instantiate() as Game
	game.auto_start_waves = false
	game.linglan_boss_enabled = false
	root.add_child(game)
	current_scene = game
	await process_frame
	await process_frame
	await _await_runtime_preparation(game)

	var controller := game.day_night_controller
	_expect(controller != null, "普通模式运行时必须解析昼夜控制器。")
	if controller == null:
		game.queue_free()
		current_scene = null
		await process_frame
		return
	controller.transition_duration = 0.18
	_expect(
		controller.color.is_equal_approx(Color.WHITE)
		and is_zero_approx(controller.night_factor),
		"第一波开始前必须保持默认白天。"
	)
	_expect(not game.waves.is_empty(), "普通模式必须提供可测试的第一波。")
	if not game.waves.is_empty():
		game.current_flow_step = game.waves[0]
		game.call("_begin_wave_config", game.waves[0])
		await create_timer(0.06).timeout
		_expect(
			controller.night_factor > 0.0
			and controller.night_factor < 1.0
			and not controller.color.is_equal_approx(Color.WHITE)
			and not controller.color.is_equal_approx(
				DayNightController.REFERENCE_NIGHT_COLOR
			),
			"第一波开始后必须处于渐变中的中间亮度，不能瞬间跳到黑夜。"
		)
		await create_timer(0.22).timeout
		_expect(
			controller.is_night()
			and controller.color.is_equal_approx(
				DayNightController.REFERENCE_NIGHT_COLOR
			),
			"第一波夜幕渐变结束后必须达到参考图#577B9E亮度。"
		)

		var player_light: NightPointLight2D = null
		if game.player != null:
			player_light = game.player.get_node_or_null(
				"NightLight"
			) as NightPointLight2D
		_expect(
			player_light != null
			and player_light.enabled
			and player_light.energy > 0.0,
			"第一波黑夜中玩家柔白灯必须启用。"
		)
		var next_wave := (
			game.waves[1]
			if game.waves.size() > 1
			else game.waves[0]
		)
		game.call("_enter_intermission", next_wave)
		await create_timer(0.06).timeout
		_expect(
			controller.night_factor > 0.0
			and controller.night_factor < 1.0,
			"重回白天也必须经过中间亮度。"
		)
		await create_timer(0.22).timeout
		_expect(
			controller.color.is_equal_approx(Color.WHITE)
			and is_zero_approx(controller.night_factor)
			and player_light != null
			and not player_light.enabled
			and is_zero_approx(player_light.energy),
			"白天渐变结束后必须恢复纯白且玩家灯光无能耗。"
		)
		game.call("_begin_flow_step", next_wave)
		game.enemy_spawn_timer.stop()
		await create_timer(0.06).timeout
		_expect(
			game.wave_state == GameRuntimeBase.WaveState.WAVE_ACTIVE
			and controller.night_factor > 0.0
			and controller.night_factor < 1.0
			and not controller.color.is_equal_approx(Color.WHITE),
			"第二波战斗开始后也必须从白天平滑进入黑夜。"
		)
		await create_timer(0.22).timeout
		_expect(
			controller.is_night()
			and controller.color.is_equal_approx(
				DayNightController.REFERENCE_NIGHT_COLOR
			)
			and player_light != null
			and player_light.enabled
			and player_light.energy > 0.0,
			"第二波夜幕渐变结束后必须恢复完整黑夜与玩家照明。"
		)
		game.call("_enter_intermission", next_wave)
		await create_timer(0.22).timeout
		_expect(
			game.wave_state == GameRuntimeBase.WaveState.INTERMISSION
			and is_zero_approx(controller.night_factor)
			and controller.color.is_equal_approx(Color.WHITE)
			and player_light != null
			and not player_light.enabled,
			"第二波结算休整也必须重新回到白昼并关闭夜间玩家灯。"
		)

	game.state_timer.stop()
	game.enemy_spawn_timer.stop()
	game.queue_free()
	current_scene = null
	await process_frame
	await process_frame


func _test_tower_wave_lighting() -> void:
	var tower := TOWER_SCENE.instantiate() as GameTowerDefense
	tower.auto_start_waves = false
	tower.linglan_boss_enabled = false
	root.add_child(tower)
	current_scene = tower
	await process_frame
	await process_frame
	await _await_runtime_preparation(tower)

	var controller := tower.day_night_controller
	_expect(controller != null, "塔防运行时必须解析昼夜控制器。")
	_expect(not tower.waves.is_empty(), "塔防模式必须提供可测试的第一波。")
	if controller == null or tower.waves.is_empty():
		tower.queue_free()
		current_scene = null
		await process_frame
		return

	controller.transition_duration = 0.12
	tower.current_flow_step = tower.waves[0]
	tower.call("_begin_wave_config", tower.waves[0])
	tower.enemy_spawn_timer.stop()
	await create_timer(0.18).timeout
	_expect(
		controller.is_night()
		and controller.color.is_equal_approx(
			DayNightController.REFERENCE_NIGHT_COLOR
		),
		"塔防第一波开始后也必须渐变至参考黑夜亮度。"
	)

	var next_wave := (
		tower.waves[1]
		if tower.waves.size() > 1
		else tower.waves[0]
	)
	tower.call("_enter_intermission", next_wave)
	await create_timer(0.18).timeout
	_expect(
		is_zero_approx(controller.night_factor)
		and controller.color.is_equal_approx(Color.WHITE),
		"塔防进入休整时必须自动渐变回白天。"
	)

	tower.state_timer.stop()
	tower.enemy_spawn_timer.stop()
	tower.queue_free()
	current_scene = null
	await process_frame
	await process_frame


func _test_fresh_client_remote_flow_lighting() -> void:
	var fixtures: Array[Dictionary] = [
		{
			"label": "普通模式",
			"scene": GAME_SCENE,
		},
		{
			"label": "塔防模式",
			"scene": TOWER_SCENE,
		},
	]
	for fixture in fixtures:
		var label := String(fixture["label"])
		var packed_scene := fixture["scene"] as PackedScene
		var game := packed_scene.instantiate() as GameRuntimeBase
		_expect(game != null, "%s客户端场景必须能够实例化。" % label)
		if game == null:
			continue
		game.defer_runtime_activation()
		game.configure_multiplayer(
			GameRuntimeBase.RuntimeMode.CLIENT_VIEW,
			2,
			{1: "Host", 2: "Client"},
			{
				1: PlayerCharacterRegistry.HOE_CAT_ID,
				2: PlayerCharacterRegistry.WEISHIDAIER_ID,
			}
		)
		game.set("auto_start_waves", false)
		game.set("linglan_boss_enabled", false)
		root.add_child(game)
		current_scene = game
		await process_frame
		await process_frame
		await _await_runtime_preparation(game)
		game.activate_runtime()
		await process_frame

		var controller := game.day_night_controller
		var waves := game.get("waves") as Array
		_expect(
			game.runtime_mode == GameRuntimeBase.RuntimeMode.CLIENT_VIEW
			and controller != null
			and not waves.is_empty(),
			"%s必须按真实入树顺序完成CLIENT_VIEW初始化。" % label
		)
		var player_lights: Array[NightPointLight2D] = []
		for player_variant in game.peer_players.values():
			var peer_player := player_variant as Player
			if peer_player == null:
				continue
			var player_light := peer_player.get_node_or_null(
				"NightLight"
			) as NightPointLight2D
			if player_light != null:
				player_lights.append(player_light)
		_expect(
			player_lights.size() == 2
			and _all_lights_disabled(player_lights),
			"%s真实客户端的动态玩家必须全部绑定昼夜灯，且白天关闭。"
			% label
		)
		if controller != null and not waves.is_empty():
			controller.transition_duration = 0.12
			var first_wave := waves[0] as WaveConfig
			game.call(
				"apply_remote_flow_state",
				first_wave.step_id,
				GameRuntimeBase.WaveState.WAVE_ACTIVE,
				0
			)
			await create_timer(0.18).timeout
			_expect(
				controller.is_night()
				and _all_lights_enabled(player_lights),
				"%s客户端收到第一波激活状态时必须同步黑夜和玩家灯。"
				% label
			)
			game.call(
				"apply_remote_flow_state",
				first_wave.step_id,
				GameRuntimeBase.WaveState.INTERMISSION,
				1
			)
			await create_timer(0.18).timeout
			_expect(
				is_zero_approx(controller.night_factor)
				and controller.color.is_equal_approx(Color.WHITE)
				and _all_lights_disabled(player_lights),
				"%s客户端收到休整状态时必须同步回白天并关闭玩家灯。"
				% label
			)
			controller.set_night_factor_immediate(1.0)
			game.call(
				"apply_remote_flow_state",
				&"",
				GameRuntimeBase.WaveState.VICTORY,
				0
			)
			await create_timer(0.18).timeout
			_expect(
				is_zero_approx(controller.night_factor)
				and controller.color.is_equal_approx(Color.WHITE)
				and _all_lights_disabled(player_lights),
				"%s客户端进入胜利结果态时必须离开战斗黑夜。"
				% label
			)
			controller.set_night_factor_immediate(1.0)
			game.call(
				"apply_remote_flow_state",
				&"",
				GameRuntimeBase.WaveState.DEFEAT,
				0
			)
			await create_timer(0.18).timeout
			_expect(
				is_zero_approx(controller.night_factor)
				and controller.color.is_equal_approx(Color.WHITE)
				and _all_lights_disabled(player_lights),
				"%s客户端进入失败结果态时也必须离开战斗黑夜。"
				% label
			)

		var state_timer := game.get_node_or_null("StateTimer") as Timer
		var enemy_spawn_timer := (
			game.get_node_or_null("EnemySpawnTimer") as Timer
		)
		if state_timer != null:
			state_timer.stop()
		if enemy_spawn_timer != null:
			enemy_spawn_timer.stop()
		game.queue_free()
		current_scene = null
		await process_frame
		await process_frame


func _await_runtime_preparation(game: GameRuntimeBase) -> void:
	if game.is_runtime_preparation_complete():
		return
	if game.has_method("_schedule_enemy_navigation_prewarm"):
		game.call("_schedule_enemy_navigation_prewarm")
	var deadline := Time.get_ticks_msec() + 30000
	while (
		not game.is_runtime_preparation_complete()
		and Time.get_ticks_msec() < deadline
	):
		await process_frame
	_expect(
		game.is_runtime_preparation_complete(),
		"昼夜流程测试必须先完成游戏运行时预热。"
	)


func _collect_night_lights(node: Node) -> Array[NightPointLight2D]:
	var result: Array[NightPointLight2D] = []
	for candidate in node.find_children("*", "", true, false):
		if (
			candidate is NightPointLight2D
			and not candidate is NightVfxFlash2D
		):
			result.append(candidate as NightPointLight2D)
	return result


func _collect_merchant_night_lights(
	node: Node
) -> Array[NightPointLight2D]:
	var result: Array[NightPointLight2D] = []
	for merchant_name in ["ZhuangfangyiMerchant", "LuoxiMerchant"]:
		var light := node.get_node_or_null(
			NodePath("%s/NightLight" % merchant_name)
		) as NightPointLight2D
		if light != null:
			result.append(light)
	return result


func _all_lights_enabled(lights: Array[NightPointLight2D]) -> bool:
	for light in lights:
		if (
			light == null
			or not is_instance_valid(light)
			or not light.enabled
			or light.energy <= 0.0
		):
			return false
	return not lights.is_empty()


func _all_lights_disabled(lights: Array[NightPointLight2D]) -> bool:
	for light in lights:
		if (
			light != null
			and is_instance_valid(light)
			and (light.enabled or not is_zero_approx(light.energy))
		):
			return false
	return true


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)


func _finish() -> void:
	if failures.is_empty():
		print("DAY_NIGHT_LIGHTING_SMOKE_TEST_OK")
		quit()
		return
	for failure in failures:
		push_error(failure)
	quit(1)
