extends SceneTree

const TOWER_SCENE := preload(
	"res://scene/plant_defense/grape_arc_tower.tscn"
)
const TOWER_CONFIG := preload(
	"res://resources/config/plant_defense/grape_arc_tower.tres"
)
const ENEMY_SCENE := preload("res://scene/enemy/enemy.tscn")
const HYDRANGEA_SCENE := preload(
	"res://scene/plant_defense/hydrangea_rain_tower.tscn"
)
const HYDRANGEA_CONFIG := preload(
	"res://resources/config/plant_defense/hydrangea_rain_tower.tres"
)

var failures: Array[String] = []


class ChainRuntime:
	extends CombatRuntimeTestFixture

	var targets: Array[Enemy] = []
	var damage_targets: Array[Enemy] = []
	var damage_amounts := PackedInt32Array()
	var damage_types := PackedInt32Array()
	var query_count := 0

	func query_combat_targets_into(
		center: Vector2,
		radius: float,
		result: Array[Enemy],
		max_count: int = 0
	) -> void:
		query_count += 1
		result.clear()
		var radius_squared := radius * radius
		for target in targets:
			if (
				target != null
				and is_instance_valid(target)
				and not target.is_dead
				and center.distance_squared_to(target.global_position)
				<= radius_squared
			):
				result.append(target)
		result.sort_custom(func(a: Enemy, b: Enemy) -> bool:
			var a_distance := center.distance_squared_to(a.global_position)
			var b_distance := center.distance_squared_to(b.global_position)
			if not is_equal_approx(a_distance, b_distance):
				return a_distance < b_distance
			return a.get_instance_id() < b.get_instance_id()
		)
		if max_count > 0 and result.size() > max_count:
			result.resize(max_count)

	func apply_authoritative_plant_enemy_damage(
		_source_id: int,
		target: Enemy,
		amount: int,
		_direction: Vector2,
		damage_type: EnemyConfig.DamageType
	) -> void:
		damage_targets.append(target)
		damage_amounts.append(amount)
		damage_types.append(damage_type)


class ChainGameplayPort:
	extends TowerPlantGameplayTestPort

	var fixture_runtime: ChainRuntime = null

	func apply_authoritative_plant_enemy_damage(
		_source_id: int,
		target: Node2D,
		amount: int,
		direction: Vector2,
		damage_type: int
	) -> bool:
		var enemy := target as Enemy
		if fixture_runtime == null or enemy == null:
			return false
		fixture_runtime.apply_authoritative_plant_enemy_damage(
			_source_id,
			enemy,
			amount,
			direction,
			damage_type as EnemyConfig.DamageType
		)
		return true


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	var runtime := ChainRuntime.new()
	runtime.install_base_runtime_nodes()
	root.add_child(runtime)
	var gameplay_port := ChainGameplayPort.new()
	gameplay_port.fixture_runtime = runtime
	runtime.add_child(gameplay_port)

	var tower := TOWER_SCENE.instantiate() as GrapeArcTower
	tower.bind_gameplay_context(runtime, gameplay_port)
	runtime.add_child(tower)
	tower.set_meta(&"net_id", 71001)
	tower.setup(TOWER_CONFIG, null, [], false, -1, 0, -1, false)
	tower.attack_timer.stop()
	_expect(
		not tower.idle_scan_timer.is_stopped()
		and tower.idle_scan_timer.one_shot
		and tower.idle_scan_timer.time_left
		>= GrapeArcTower.IDLE_SCAN_INITIAL_DELAY_MIN_SECONDS
		and tower.idle_scan_timer.time_left
		<= (
			GrapeArcTower.IDLE_SCAN_INITIAL_DELAY_MIN_SECONDS
			+ GrapeArcTower.IDLE_SCAN_INITIAL_DELAY_SPREAD_SECONDS
		),
		"葡萄塔进入运行态后必须用独立一次性计时器错峰安排首次待机扫描。"
	)
	tower.idle_scan_timer.stop()

	_expect(TOWER_CONFIG.is_valid(), "葡萄电弧塔配置必须有效。")
	_expect(
		TOWER_CONFIG.max_health == 2600
		and TOWER_CONFIG.physical_defense == 10
		and TOWER_CONFIG.magic_defense == 30
		and TOWER_CONFIG.attack_damage == 96
		and is_equal_approx(TOWER_CONFIG.attack_speed, 100.0 / 1.4)
		and is_equal_approx(TOWER_CONFIG.get_attack_interval(), 1.4)
		and TOWER_CONFIG.description.contains("每1.4秒")
		and TOWER_CONFIG.description.contains("96点")
		and tower.configured_attack_damage == 96
		and is_equal_approx(
			tower.attack_timer.wait_time,
			GrapeArcTower.calculate_initial_attack_delay_seconds(1.4, 71001)
		)
		and is_equal_approx(GrapeArcTower.DEFAULT_ATTACK_INTERVAL, 1.4),
		"葡萄塔必须拥有2600生命、10物防、30法防，并以96点法术伤害和1.4秒完整周期运行。"
	)
	_expect(
		PlantDefenseRegistry.get_config(&"grape_arc_tower") == TOWER_CONFIG,
		"公共植物注册表必须返回葡萄电弧塔。"
	)
	var lower_trellis_region := tower.support_sprite.texture as AtlasTexture
	var upper_trellis := tower.get_node_or_null(
		"VisualRoot/UpperTrellisSprite"
	) as Sprite2D
	var upper_trellis_region := (
		upper_trellis.texture as AtlasTexture
		if upper_trellis != null
		else null
	)
	_expect(
		lower_trellis_region != null
		and upper_trellis != null
		and upper_trellis_region != null
		and lower_trellis_region.atlas == upper_trellis_region.atlas
		and lower_trellis_region.atlas.get_size() == Vector2(64, 64)
		and lower_trellis_region.region == Rect2(0, 40, 64, 24)
		and upper_trellis_region.region == Rect2(0, 0, 64, 40)
		and tower.support_sprite.position == Vector2(0, 20)
		and upper_trellis.position == Vector2(0, -12)
		and tower.support_sprite.z_index == 1
		and upper_trellis.z_index == 4
		and tower.support_sprite.texture_filter
		== CanvasItem.TEXTURE_FILTER_NEAREST
		and upper_trellis.texture_filter
		== CanvasItem.TEXTURE_FILTER_NEAREST
		and upper_trellis.material == tower.support_sprite.material
		and tower.lifecycle_visual_paths
		== [
			NodePath("VisualRoot/SupportSprite"),
			NodePath("VisualRoot/UpperTrellisSprite"),
			NodePath("VisualRoot/GrapeClusterRoot/SideGrapesSprite"),
			NodePath(
				"VisualRoot/GrapeClusterRoot/FiringGrapeRoot/"
				+ "FiringGrapesSprite"
			),
		],
		"葡萄架必须由无重叠的上下切片组成，红圈内上层固定以z=4遮挡玩家与敌人，并同步生命周期视觉。"
	)
	_expect(
		tower.side_grapes_sprite.texture.get_size() == Vector2(64, 64)
		and tower.firing_grapes_sprite.texture.get_size() == Vector2(64, 64),
		"侧边蓄电葡萄与中央发射葡萄必须保持64×64原生画布。"
	)
	_expect(
		is_equal_approx(
			float(tower.side_charge_overlay.get_instance_shader_parameter(
				&"charge_uv_top"
			)),
			GrapeArcTower.SIDE_GRAPE_UV_TOP
		)
		and is_equal_approx(
			float(tower.side_charge_overlay.get_instance_shader_parameter(
				&"charge_uv_bottom"
			)),
			GrapeArcTower.SIDE_GRAPE_UV_BOTTOM
		)
		and is_equal_approx(
			float(tower.firing_charge_overlay.get_instance_shader_parameter(
				&"charge_uv_top"
			)),
			GrapeArcTower.FIRING_GRAPE_UV_TOP
		)
		and is_equal_approx(
			float(tower.firing_charge_overlay.get_instance_shader_parameter(
				&"charge_uv_bottom"
			)),
			GrapeArcTower.FIRING_GRAPE_UV_BOTTOM
		),
		"侧边与中央葡萄必须分别使用自身像素边界，蓝色扫描不得只掠过半串葡萄。"
	)
	_expect(
		tower.get_node_or_null("VisualRoot/GrapeClusterRoot/CoreRoot") == null,
		"新造型不得保留夸张核心葡萄节点。"
	)
	_expect(
		tower.get_node("VisualRoot").scale == Vector2(0.5, 0.5),
		"64px葡萄架必须使用0.5世界缩放适配2×2地块。"
	)
	_expect(
		is_equal_approx(TOWER_CONFIG.attack_range, 96.0)
		and TOWER_CONFIG.max_chain_targets == 4
		and is_equal_approx(TOWER_CONFIG.chain_jump_range, 72.0),
		"葡萄塔必须使用6格索敌、最多4目标与72像素跳跃范围。"
	)
	_expect(tower.zap_audio.stream != null, "葡萄电弧释放音效必须成功加载。")
	tower.call("_begin_idle_scan")
	var first_idle_scan_tween := tower.idle_scan_tween
	_expect(
		tower.idle_scan_active
		and first_idle_scan_tween != null
		and tower.idle_scan_timer.is_stopped(),
		"无敌人时待机扫描必须由唯一Tween接管，扫描期间不得叠加计时器。"
	)
	_expect(
		runtime.query_count == 0
		and runtime.damage_targets.is_empty()
		and not tower.arc_layer.visible
		and not tower.zap_audio.playing,
		"待机扫描只能播放葡萄着色器，不能索敌、伤害、放电弧或播放攻击音效。"
	)
	tower.call("_begin_idle_scan")
	_expect(
		tower.idle_scan_tween == first_idle_scan_tween,
		"重复触发待机扫描时不得创建第二条Tween。"
	)
	tower.call("_set_idle_scan_progress", 0.20)
	var early_side_scan := float(
		tower.side_charge_overlay.get_instance_shader_parameter(
			&"idle_scan_strength"
		)
	)
	var early_firing_scan := float(
		tower.firing_charge_overlay.get_instance_shader_parameter(
			&"idle_scan_strength"
		)
	)
	_expect(
		early_side_scan > 0.0 and is_zero_approx(early_firing_scan),
		"待机蓝光必须先扫描两侧葡萄，不能一开始就点亮中央发射葡萄。"
	)
	tower.call("_set_idle_scan_progress", 0.55)
	var gathered_firing_scan := float(
		tower.firing_charge_overlay.get_instance_shader_parameter(
			&"idle_scan_strength"
		)
	)
	_expect(
		gathered_firing_scan > 0.0,
		"待机蓝光经过两侧后必须继续汇入中央发射葡萄。"
	)
	first_idle_scan_tween.custom_step(1.0)
	_expect(
		not tower.idle_scan_active
		and tower.idle_scan_tween == null
		and not tower.idle_scan_timer.is_stopped()
		and is_equal_approx(
			tower.idle_scan_timer.time_left,
			GrapeArcTower.IDLE_SCAN_COOLDOWN_SECONDS
		),
		"待机扫描结束后必须清理Tween并从完成时刻安排下一轮扫描。"
	)
	tower.idle_scan_timer.stop()
	tower.call("_set_charge_progress", 0.3)
	var side_charge := float(
		tower.side_charge_overlay.get_instance_shader_parameter(
			&"charge_progress"
		)
	)
	var firing_charge := float(
		tower.firing_charge_overlay.get_instance_shader_parameter(
			&"charge_progress"
		)
	)
	_expect(
		side_charge > firing_charge,
		"蓄力必须先点亮两侧葡萄，再向中央发射葡萄汇聚。"
	)
	tower.call("_set_charge_progress", 0.0)

	var positions := [
		Vector2(50, 0),
		Vector2(110, 0),
		Vector2(170, 0),
		Vector2(230, 0),
	]
	for position in positions:
		var enemy := ENEMY_SCENE.instantiate() as Enemy
		runtime.add_child(enemy)
		enemy.global_position = position
		enemy.set_process(false)
		enemy.set_physics_process(false)
		runtime.targets.append(enemy)

	tower.call("_begin_idle_scan")
	tower.call("_on_attack_timer_timeout")
	_expect(tower.attack_locked, "发现目标后必须进入逐颗充能阶段。")
	_expect(
		is_equal_approx(tower.attack_timer.wait_time, 1.4)
		and tower.attack_timer.time_left > 0.0
		and tower.attack_timer.time_left <= 1.4,
		"每次成功锁敌后必须立即按1.4秒完整周期安排下一次攻击。"
	)
	_expect(
		not tower.idle_scan_active
		and tower.idle_scan_tween == null
		and tower.idle_scan_timer.is_stopped()
		and is_zero_approx(float(
			tower.side_charge_overlay.get_instance_shader_parameter(
				&"idle_scan_strength"
			)
		)),
		"真实攻击开始时必须原子取消待机扫描并清空其着色器状态。"
	)
	tower.attack_timer.stop()
	tower.release_timer.stop()
	tower.call("_on_release_timer_timeout")
	_expect(
		runtime.damage_targets.size() == 4,
		"密集队列必须从首个目标连续跳跃并命中最多4个不同敌人。"
	)
	var unique_damage_targets := {}
	for target in runtime.damage_targets:
		unique_damage_targets[target] = true
	_expect(
		unique_damage_targets.size() == 4,
		"连锁电弧不能在单一目标上重复弹射。"
	)
	for amount in runtime.damage_amounts:
		_expect(amount == 96, "每次电弧命中必须造成配置中的96点伤害。")
	for damage_type in runtime.damage_types:
		_expect(
			damage_type == EnemyConfig.DamageType.MAGIC,
			"葡萄电弧必须结算法术伤害。"
		)
	_expect(tower.arc_layer.visible, "释放时必须显示电弧折线。")
	_expect(
		(tower._arc_cores[0] as Line2D).points.size() == 7,
		"每段电弧必须使用多折点形成跳动轮廓。"
	)
	tower.attack_animation_player.advance(0.14)
	_expect(
		tower.firing_grape_root.scale.y > 1.0,
		"释放瞬间必须只拉长中央发射葡萄。"
	)
	_expect(
		tower.grape_cluster_root.position == Vector2.ZERO
		and tower.grape_cluster_root.scale == Vector2.ONE,
		"两侧蓄电葡萄不能随中央发射葡萄整体脱离藤架。"
	)
	tower.call("_on_attack_animation_finished", &"release")
	_expect(not tower.attack_locked, "释放恢复动画结束后必须解除攻击锁。")
	_expect(not tower.arc_layer.visible, "电流释放后必须及时隐藏电弧。")
	_expect(
		not tower.idle_scan_timer.is_stopped(),
		"真实攻击结束后必须重新安排待机扫描。"
	)
	tower.idle_scan_timer.stop()

	var proxy := TOWER_SCENE.instantiate() as GrapeArcTower
	proxy.bind_gameplay_context(runtime, gameplay_port)
	runtime.add_child(proxy)
	proxy.set_meta(&"net_id", 71002)
	proxy.setup(TOWER_CONFIG, null, [], true, -1, 0, -1, false)
	proxy.attack_timer.stop()
	proxy.idle_scan_timer.stop()
	proxy.call("_on_attack_timer_timeout")
	proxy.attack_timer.stop()
	proxy.release_timer.stop()
	proxy.call("_on_release_timer_timeout")
	_expect(
		runtime.damage_targets.size() == 4,
		"多人副本只能复现充能和电弧视觉，不能重复结算权威伤害。"
	)
	_expect(proxy.arc_layer.visible, "多人副本必须能够本地复现连锁电弧。")
	proxy.call("_on_attack_animation_finished", &"release")
	proxy.idle_scan_timer.stop()
	proxy.call("_begin_idle_scan")
	proxy.call("_on_removal_started", PlantDefense.RemovalMode.SILENT)
	_expect(
		not proxy.idle_scan_active
		and proxy.idle_scan_tween == null
		and proxy.idle_scan_timer.is_stopped()
		and is_zero_approx(float(
			proxy.firing_charge_overlay.get_instance_shader_parameter(
				&"idle_scan_strength"
			)
		)),
		"移除或失活时必须停止待机计时器、杀死Tween并复位中央葡萄。"
	)

	var hydrangea := HYDRANGEA_SCENE.instantiate() as HydrangeaRainTower
	hydrangea.bind_gameplay_context(runtime, gameplay_port)
	runtime.add_child(hydrangea)
	hydrangea.setup(HYDRANGEA_CONFIG, null, [], false, -1, 0, -1, false)
	hydrangea.cycle_timer.stop()
	_expect(
		hydrangea.rain_audio.stream != null,
		"紫阳花雨幕攻击音效必须成功加载。"
	)

	for child in runtime.get_children():
		child.queue_free()
	await process_frame
	runtime.queue_free()
	await process_frame

	if failures.is_empty():
		print("GRAPE_ARC_TOWER_SMOKE_TEST_OK")
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	quit(1)


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
