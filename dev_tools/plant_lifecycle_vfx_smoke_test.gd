extends SceneTree

const AGAVE_SCENE := preload("res://scene/plant_defense/agave_cannon.tscn")
const CORN_SCENE := preload("res://scene/plant_defense/corn_machine_gun.tscn")
const OAK_SCENE := preload("res://scene/plant_defense/oak_warehouse.tscn")
const VEGETATION_STAKE_SCENE := preload("res://scene/plant_defense/vegetation_stake.tscn")
const PLACEMENT_PARTICLES_SCENE := preload(
	"res://scene/plant_defense/effects/plant_placement_particles.tscn"
)
const REMOVAL_SMOKE_SCENE := preload(
	"res://scene/plant_defense/effects/plant_removal_smoke.tscn"
)
const LIFECYCLE_SHADER := preload("res://resources/shader/plant_lifecycle.gdshader")
const LIFECYCLE_MATERIAL := preload(
	"res://resources/shader/plant_lifecycle_material.tres"
)
const LIFECYCLE_NOISE := preload("res://resources/shader/plant_lifecycle_noise.tres")

var failures: Array[String] = []
var fixture_root: Node2D = null


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	fixture_root = Node2D.new()
	fixture_root.name = "PlantLifecycleVfxSmokeFixture"
	root.add_child(fixture_root)
	await process_frame

	_test_scene_lifecycle_contracts()
	await _test_instance_uniform_isolation()
	await _test_construction_operational_gates()
	await _test_animated_external_removal()
	await _test_lethal_removal()
	await _test_particle_scenes_and_pool_release()

	if fixture_root != null and is_instance_valid(fixture_root):
		fixture_root.queue_free()
	for _cleanup_frame in range(3):
		await process_frame
	fixture_root = null

	if failures.is_empty():
		print("PLANT_LIFECYCLE_VFX_SMOKE_TEST_OK")
		quit()
		return
	for failure in failures:
		push_error(failure)
	quit(1)


func _test_scene_lifecycle_contracts() -> void:
	var contracts: Array[Dictionary] = [
		{
			"name": "龙舌兰炮",
			"scene": AGAVE_SCENE,
			"paths": [
				NodePath("VisualRoot/BodySprite"),
				NodePath("VisualRoot/CannonPivot/CannonSprite"),
			],
			"top": -8.0,
			"bottom": 16.0,
			"particle_scale": 1.0,
		},
		{
			"name": "玉米机枪",
			"scene": CORN_SCENE,
			"paths": [
				NodePath("VisualRoot/BodySprite"),
				NodePath("VisualRoot/AimPivot/TurretSprite"),
			],
			"top": -9.0,
			"bottom": 16.0,
			"particle_scale": 1.0,
		},
		{
			"name": "橡木仓库",
			"scene": OAK_SCENE,
			"paths": [NodePath("Sprite2D")],
			"top": -16.0,
			"bottom": 16.0,
			"particle_scale": 1.0,
		},
		{
			"name": "植被桩",
			"scene": VEGETATION_STAKE_SCENE,
			"paths": [NodePath("MainSprite")],
			"top": -5.0,
			"bottom": 7.0,
			"particle_scale": 0.65,
		},
	]
	for contract in contracts:
		var packed_scene := contract["scene"] as PackedScene
		var plant := packed_scene.instantiate() as PlantDefense
		var display_name := str(contract["name"])
		_expect(plant != null, "%s场景根节点必须继承PlantDefense。" % display_name)
		if plant == null:
			continue
		var expected_paths: Array = contract["paths"]
		_expect(
			plant.lifecycle_visual_paths == expected_paths
			and is_equal_approx(plant.lifecycle_effect_top_y, float(contract["top"]))
			and is_equal_approx(plant.lifecycle_effect_bottom_y, float(contract["bottom"]))
			and is_equal_approx(
				plant.get_lifecycle_particle_scale(),
				float(contract["particle_scale"])
			),
			"%s必须保持约定的生命周期NodePath、Y范围与粒子比例。" % display_name
		)
		var shared_material: ShaderMaterial = null
		for visual_path_variant in expected_paths:
			var visual_path := visual_path_variant as NodePath
			var visual := plant.get_node_or_null(visual_path) as CanvasItem
			var material: ShaderMaterial = null
			if visual != null:
				material = visual.material as ShaderMaterial
			_expect(
				visual != null
				and material != null
				and material == LIFECYCLE_MATERIAL
				and material.shader == LIFECYCLE_SHADER,
				"%s的生命周期目标%s必须使用共享生命周期shader。"
				% [display_name, visual_path]
			)
			if material != null:
				if shared_material == null:
					shared_material = material
				else:
					_expect(
						material == shared_material,
						"%s的复合Sprite必须共享同一ShaderMaterial资源。" % display_name
					)
		plant.free()

	var shader_code := LIFECYCLE_SHADER.code
	_expect(
		shader_code.contains("instance uniform float construction_progress")
		and shader_code.contains("instance uniform float removal_progress")
		and shader_code.contains("MODEL_MATRIX")
		and shader_code.contains("vec4 result = COLOR;")
		and not shader_code.contains("texture(TEXTURE, UV) * COLOR")
		and shader_code.contains("vec3(3.2)")
		and shader_code.contains("if (removal_enabled)")
		and shader_code.find("texture(lifecycle_noise")
			> shader_code.find("if (removal_enabled)"),
		"生命周期shader必须保留CanvasItem原始贴图色、使用实例参数与统一世界坐标白色揭示线，并仅在移除分支采样噪波。"
	)
	_expect(
		LIFECYCLE_NOISE is NoiseTexture2D
		and LIFECYCLE_NOISE.width == 64
		and LIFECYCLE_NOISE.height == 64
		and LIFECYCLE_NOISE.noise is FastNoiseLite,
		"生命周期材质必须共享一张64×64 FastNoiseLite噪波纹理。"
	)
	_expect(
		is_equal_approx(PlantDefense.CONSTRUCTION_DURATION_SECONDS, 0.7)
		and is_equal_approx(PlantDefense.REMOVAL_DURATION_SECONDS, 0.7),
		"植物构建与溶解时长必须分别固定为0.7秒。"
	)


func _test_instance_uniform_isolation() -> void:
	var config := PlantDefenseRegistry.get_config(&"agave_cannon")
	var constructing := AGAVE_SCENE.instantiate() as AgaveCannon
	var complete := AGAVE_SCENE.instantiate() as AgaveCannon
	fixture_root.add_child(constructing)
	fixture_root.add_child(complete)
	constructing.setup(config, null, [], false, -1, 0, -1, true)
	complete.setup(config, null, [], false, -1, 0, -1, false)

	var constructing_body := constructing.get_node("VisualRoot/BodySprite") as AnimatedSprite2D
	var constructing_cannon := constructing.get_node(
		"VisualRoot/CannonPivot/CannonSprite"
	) as AnimatedSprite2D
	var complete_body := complete.get_node("VisualRoot/BodySprite") as AnimatedSprite2D
	_expect(
		constructing_body.material == complete_body.material,
		"两个同类建筑实例必须复用同一生命周期材质。"
	)
	_expect(
		is_zero_approx(float(constructing_body.get_instance_shader_parameter(
			&"construction_progress"
		)))
		and is_zero_approx(float(constructing_cannon.get_instance_shader_parameter(
			&"construction_progress"
		)))
		and is_equal_approx(float(complete_body.get_instance_shader_parameter(
			&"construction_progress"
		)), 1.0),
		"共享材质的两个建筑必须保留各自的construction_progress，且复合Sprite同步。"
	)

	constructing.begin_removal(PlantDefense.RemovalMode.SILENT)
	complete.begin_removal(PlantDefense.RemovalMode.SILENT)
	await process_frame


func _test_construction_operational_gates() -> void:
	var agave_config := PlantDefenseRegistry.get_config(&"agave_cannon")
	var oak_config := PlantDefenseRegistry.get_config(&"oak_warehouse")
	var agave := AGAVE_SCENE.instantiate() as AgaveCannon
	var oak := OAK_SCENE.instantiate() as OakWarehouse
	fixture_root.add_child(agave)
	fixture_root.add_child(oak)
	agave.setup(agave_config, null, [], false, -1, 0, -1, true)
	oak.setup(oak_config, null, [], false, -1, 0, -1, true)
	oak.configure_multiplayer_storage(91, 2, true)

	_expect(
		not agave.is_operational
		and agave.attack_timer.is_stopped()
		and not oak.is_operational
		and not oak.interaction_area.monitoring
		and not oak.is_multiplayer_storage_ready(),
		"0.7秒构建期间攻击计时器以及仓库本地/网络交互必须保持停用。"
	)
	var health_before_damage := agave.current_health
	_expect(
		agave.receive_damage(
			agave.get_effective_physical_defense() + 50,
			null,
			Vector2.ZERO,
			EnemyConfig.DamageType.PHYSICAL
		)
		and agave.current_health == health_before_damage - 50,
		"生成中的建筑必须已经可以承受正常伤害。"
	)
	await create_timer(0.35).timeout
	_expect(
		not agave.is_operational and agave.attack_timer.is_stopped(),
		"构建动画中点不能提前启用攻击。"
	)
	await create_timer(0.42).timeout
	await physics_frame
	_expect(
		agave.is_operational
		and not agave.attack_timer.is_stopped()
		and oak.is_operational
		and oak.interaction_area.monitoring
		and oak.is_multiplayer_storage_ready(),
		"构建完成后必须启用龙舌兰攻击计时器以及仓库本地/网络交互。"
	)

	agave.begin_removal(PlantDefense.RemovalMode.SILENT)
	oak.begin_removal(PlantDefense.RemovalMode.SILENT)
	await process_frame


func _test_animated_external_removal() -> void:
	var config := PlantDefenseRegistry.get_config(&"vegetation_stake")
	var plant := VEGETATION_STAKE_SCENE.instantiate() as VegetationStake
	fixture_root.add_child(plant)
	plant.setup(config, null, [], false, -1, 0, -1, true)
	var died_events: Array[bool] = []
	var removal_events: Array[int] = []
	plant.died.connect(func() -> void: died_events.append(true))
	plant.removal_started.connect(
		func(mode: int) -> void: removal_events.append(mode)
	)

	await create_timer(0.2).timeout
	var main_sprite := plant.get_node("MainSprite") as Sprite2D
	var progress_before := float(main_sprite.get_instance_shader_parameter(
		&"construction_progress"
	))
	var health_before := plant.current_health
	_expect(
		progress_before > 0.0 and progress_before < 1.0,
		"外部撤除夹具必须处于构建动画中段。"
	)
	plant.begin_removal(PlantDefense.RemovalMode.ANIMATED)
	plant.begin_removal(PlantDefense.RemovalMode.ANIMATED)
	var progress_after := float(main_sprite.get_instance_shader_parameter(
		&"construction_progress"
	))
	_expect(
		plant.is_removing
		and not plant.is_dead
		and plant.current_health == health_before
		and died_events.is_empty()
		and removal_events == [PlantDefense.RemovalMode.ANIMATED],
		"普通动画撤除不得触发死亡、清零生命或重复发出removal_started。"
	)
	_expect(
		is_equal_approx(progress_after, progress_before)
		and bool(main_sprite.get_instance_shader_parameter(&"removal_enabled")),
		"生成中撤除必须冻结当前揭示进度，并只溶解已经显示的部分。"
	)

	await create_timer(0.75).timeout
	await process_frame
	_expect(not is_instance_valid(plant), "动画撤除必须在约0.7秒后释放建筑残影。")


func _test_lethal_removal() -> void:
	var config := PlantDefenseRegistry.get_config(&"oak_warehouse")
	var plant := OAK_SCENE.instantiate() as OakWarehouse
	fixture_root.add_child(plant)
	plant.setup(config, null, [], false, -1, 0, -1, false)
	var lifecycle_events: Array[String] = []
	plant.died.connect(func() -> void: lifecycle_events.append("died"))
	plant.removal_started.connect(
		func(_mode: int) -> void: lifecycle_events.append("removal_started")
	)
	_expect(
		plant.receive_damage(
			plant.current_health + plant.get_effective_physical_defense(),
			null,
			Vector2.ZERO,
			EnemyConfig.DamageType.PHYSICAL
		),
		"致死夹具必须接受权威伤害。"
	)
	_expect(
		plant.is_dead
		and plant.is_removing
		and plant.current_health == 0
		and plant.removal_mode == PlantDefense.RemovalMode.ANIMATED
		and lifecycle_events == ["died", "removal_started"],
		"致死伤害必须按died后removal_started的顺序进入动画移除。"
	)
	await create_timer(0.75).timeout
	await process_frame
	_expect(not is_instance_valid(plant), "死亡溶解结束后必须释放建筑节点。")


func _test_particle_scenes_and_pool_release() -> void:
	var placement := PLACEMENT_PARTICLES_SCENE.instantiate() as PlantPlacementParticles
	var placement_material := placement.process_material as ParticleProcessMaterial
	var placement_audio := placement.get_node_or_null(
		"PlacementAudio"
	) as AudioStreamPlayer2D
	var placement_stream := (
		placement_audio.stream as AudioStreamWAV
		if placement_audio != null
		else null
	)
	_expect(
		placement.amount == 20
		and is_equal_approx(placement.lifetime, 0.6)
		and not placement.one_shot
		and not placement.local_coords
		and placement.fixed_fps == 30
		and placement_material != null
		and placement_material.emission_shape == ParticleProcessMaterial.EMISSION_SHAPE_RING
		and placement_material.emission_ring_axis == Vector3(0, 0, 1)
		and is_equal_approx(placement_material.emission_ring_inner_radius, 5.0)
		and is_equal_approx(placement_material.emission_ring_radius, 9.0)
		and is_equal_approx(placement_material.radial_velocity_min, 8.0)
		and is_equal_approx(placement_material.radial_velocity_max, 18.0)
		and placement_material.color_initial_ramp != null
		and placement_material.color_ramp != null,
		"生成粒子必须使用20粒子、5~9半径环带、8~18径向速度、随机初色与生命周期渐隐。"
	)
	_expect(
		placement_audio != null
		and placement_stream != null
		and placement_audio.bus == &"SFX"
		and is_equal_approx(placement_audio.volume_db, -8.0)
		and is_equal_approx(placement_audio.max_distance, 300.0)
		and placement_audio.max_polyphony == 1
		and placement_stream.mix_rate == 44100
		and not placement_stream.stereo
		and placement_stream.get_length() >= 0.29
		and placement_stream.get_length() <= 0.32,
		"建筑放置声必须使用SFX总线、克制空间混音与约0.3秒的44.1kHz单声道短音效。"
	)
	_expect(
		is_equal_approx(PlantPlacementParticles.FULL_EMISSION_DURATION, 0.7)
		and is_equal_approx(PlantPlacementParticles.EMISSION_FADE_DURATION, 0.9)
		and is_equal_approx(PlantPlacementParticles.PARTICLE_TAIL_DURATION, 0.6)
		and is_equal_approx(
			PlantPlacementParticles.EMISSION_FADE_DURATION
			+ PlantPlacementParticles.PARTICLE_TAIL_DURATION,
			1.5
		),
		"生成主体完成后的发射衰减与粒子尾迹必须合计1.5秒。"
	)
	_expect(
		PlantPlacementParticles.MAX_SIMULTANEOUS_PLACEMENT_VOICES == 4
		and PlantPlacementParticles.PLACEMENT_AUDIO_GROUP
		!= PlantAttackAudioLimiter.AUDIO_GROUP,
		"放置声必须拥有独立的四声部空间限制，不能与植物攻击音效互相抢占。"
	)
	placement.free()

	var smoke := REMOVAL_SMOKE_SCENE.instantiate() as PlantRemovalSmoke
	var smoke_material := smoke.process_material as ParticleProcessMaterial
	_expect(
		smoke.amount == 10
		and is_equal_approx(smoke.lifetime, 0.7)
		and smoke.one_shot
		and not smoke.local_coords
		and smoke.fixed_fps == 30
		and smoke_material != null
		and smoke_material.emission_shape == ParticleProcessMaterial.EMISSION_SHAPE_BOX
		and smoke_material.emission_box_extents == Vector3(8, 10, 1)
		and smoke_material.direction == Vector3(0, -1, 0)
		and is_equal_approx(smoke_material.initial_velocity_min, 4.0)
		and is_equal_approx(smoke_material.initial_velocity_max, 9.0)
		and is_equal_approx(smoke_material.radial_velocity_min, 8.0)
		and is_equal_approx(smoke_material.radial_velocity_max, 16.0)
		and smoke.visibility_rect == Rect2(-48, -48, 96, 96)
		and smoke_material.scale_curve != null
		and smoke_material.color_initial_ramp != null
		and smoke_material.color_ramp != null,
		"消亡烟雾必须保持10粒子、0.7秒，并以径向速度向更远处扩散且不被裁切。"
	)
	smoke.free()
	_expect(
		GameTowerDefense.PLANT_LIFECYCLE_VFX_PREWARM_COUNT == 8
		and GameTowerDefense.PLANT_LIFECYCLE_VFX_RETAINED_CAPACITY == 32,
		"两种建筑生命周期粒子池必须预热8个并最多保留32个。"
	)

	var pool := SessionObjectPool.new()
	pool.name = "LifecycleVfxPool"
	fixture_root.add_child(pool)
	pool.register_scene(PLACEMENT_PARTICLES_SCENE, 1, 2)
	pool.register_scene(REMOVAL_SMOKE_SCENE, 1, 2)
	var source := VEGETATION_STAKE_SCENE.instantiate() as VegetationStake
	fixture_root.add_child(source)
	source.setup(
		PlantDefenseRegistry.get_config(&"vegetation_stake"),
		null,
		[],
		false,
		-1,
		0,
		-1,
		true
	)
	var placement_lease := pool.acquire(
		PLACEMENT_PARTICLES_SCENE
	) as PlantPlacementParticles
	placement_lease.restart_effect(source, 0.65)
	var lease_audio := placement_lease.get_node(
		"PlacementAudio"
	) as AudioStreamPlayer2D
	_expect(
		placement_lease.emitting
		and is_equal_approx(placement_lease.amount_ratio, 1.0)
		and placement_lease.scale == Vector2(0.65, 0.65)
		and lease_audio.playing
		and lease_audio.is_in_group(
			PlantPlacementParticles.PLACEMENT_AUDIO_GROUP
		)
		and int(pool.get_metrics(PLACEMENT_PARTICLES_SCENE.resource_path).get(
			"in_use", 0
		)) == 1,
		"池化生成效果必须按建筑比例启动粒子，并同时播放一次空间放置声。"
	)
	await create_timer(0.08).timeout
	source.begin_removal(PlantDefense.RemovalMode.ANIMATED)
	_expect(
		not placement_lease.emitting and is_zero_approx(placement_lease.amount_ratio),
		"建筑生成中被移除时，绿色粒子必须立即停止继续发射。"
	)
	await create_timer(0.65).timeout
	await physics_frame
	await physics_frame
	var placement_metrics := pool.get_metrics(PLACEMENT_PARTICLES_SCENE.resource_path)
	_expect(
		int(placement_metrics.get("in_use", -1)) == 0
		and int(placement_metrics.get("pending_release", -1)) == 0
		and int(placement_metrics.get("inactive", -1)) == 1,
		"提前停止后的生成粒子租约必须在尾迹结束后完整归还对象池。"
	)
	_expect(
		not lease_audio.playing
		and not lease_audio.is_in_group(
			PlantPlacementParticles.PLACEMENT_AUDIO_GROUP
		),
		"生成效果归还对象池时必须停止放置声并释放空间声部。"
	)

	var smoke_lease := pool.acquire(REMOVAL_SMOKE_SCENE) as PlantRemovalSmoke
	smoke_lease.restart_effect(1.0)
	_expect(
		smoke_lease.emitting
		and int(pool.get_metrics(REMOVAL_SMOKE_SCENE.resource_path).get(
			"in_use", 0
		)) == 1,
		"死亡烟雾租约必须以one-shot状态启动。"
	)
	# Dummy/headless rendering does not consistently advance GPU particle
	# completion. Emitting the native completion signal deterministically checks
	# the production finished -> pool release contract without changing it.
	smoke_lease.finished.emit()
	await physics_frame
	await physics_frame
	var smoke_metrics := pool.get_metrics(REMOVAL_SMOKE_SCENE.resource_path)
	_expect(
		int(smoke_metrics.get("in_use", -1)) == 0
		and int(smoke_metrics.get("pending_release", -1)) == 0
		and int(smoke_metrics.get("inactive", -1)) == 1,
		"死亡烟雾finished后必须完整归还对象池。"
	)

	pool.queue_free()
	await process_frame


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
