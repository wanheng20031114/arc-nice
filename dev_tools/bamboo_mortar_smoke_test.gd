extends SceneTree

const MORTAR_SCENE := preload(
	"res://scene/plant_defense/bamboo_mortar.tscn"
)
const MORTAR_CONFIG := preload(
	"res://resources/config/plant_defense/bamboo_mortar.tres"
)
const SHELL_SCENE := preload(
	"res://scene/plant_defense/bamboo_mortar_shell.tscn"
)
const ENEMY_SCENE := preload("res://scene/enemy/enemy.tscn")
const ARMORED_ENEMY_CONFIG := preload(
	"res://resources/config/enemies/yuanshi_insect_shell.tres"
)

var failures: Array[String] = []
var runtime: MortarRuntimeStub = null
var enemies: Array[Enemy] = []


class MortarRuntimeStub:
	extends Node2D

	var candidates: Array[Enemy] = []
	var query_count := 0
	var last_query_radius := 0.0
	var queued_visuals: Array[Dictionary] = []
	var damage_records: Array[Dictionary] = []
	var session_object_pool: SessionObjectPool = null
	var apply_real_damage := false

	func install_pool() -> void:
		session_object_pool = SessionObjectPool.new()
		session_object_pool.name = "SessionObjectPool"
		add_child(session_object_pool)
		session_object_pool.register_scene(SHELL_SCENE, 1, 8)

	func query_combat_targets_unordered_into(
		center: Vector2,
		radius: float,
		result: Array[Enemy]
	) -> void:
		query_count += 1
		last_query_radius = radius
		result.clear()
		var radius_squared := radius * radius
		for candidate in candidates:
			if (
				candidate != null
				and is_instance_valid(candidate)
				and not candidate.is_dead
				and center.distance_squared_to(candidate.global_position)
				<= radius_squared
			):
				result.append(candidate)

	func queue_bamboo_mortar_visual(
		plant_net_id: int,
		action_id: int,
		stage: int,
		spawn_position: Vector2,
		landing_position: Vector2
	) -> void:
		queued_visuals.append({
			"plant_net_id": plant_net_id,
			"action_id": action_id,
			"stage": stage,
			"spawn_position": spawn_position,
			"landing_position": landing_position,
		})

	func apply_authoritative_plant_enemy_damage(
		source_id: int,
		enemy: Enemy,
		damage: int,
		impact_direction: Vector2,
		damage_type: EnemyConfig.DamageType
	) -> bool:
		damage_records.append({
			"source_id": source_id,
			"enemy": enemy,
			"damage": damage,
			"impact_direction": impact_direction,
			"damage_type": damage_type,
		})
		if apply_real_damage:
			return enemy.apply_damage(
				damage,
				impact_direction,
				damage_type,
				false
			)
		return true

	func has_session_object_pool_scene(scene: PackedScene) -> bool:
		return (
			session_object_pool != null
			and session_object_pool.is_registered(scene)
		)

	func acquire_session_object(
		scene: PackedScene,
		strict: bool = false
	) -> Node:
		if session_object_pool == null:
			return null
		return (
			session_object_pool.try_acquire(scene)
			if strict
			else session_object_pool.acquire(scene)
		)


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	runtime = MortarRuntimeStub.new()
	runtime.name = "BambooMortarSmokeFixture"
	root.add_child(runtime)
	current_scene = runtime
	runtime.install_pool()

	var authority := _create_mortar(false, 701)
	var proxy := _create_mortar(true, 702)
	if authority != null and proxy != null:
		_test_config_and_scene_contract(authority)
		await _test_target_ring_and_tracking(authority)
		await _test_windup_fire_and_fixed_landing(authority)
		await _test_shell_duration_and_late_join(authority)
		await _test_explosion_damage_boundaries()
		await _test_physical_defense_settlement()
		await _test_proxy_actions_and_runtime_state(authority, proxy)
		await _test_pool_reuse()

	await _cleanup()
	if failures.is_empty():
		print("BAMBOO_MORTAR_SMOKE_TEST_OK")
		quit()
		return
	for failure in failures:
		push_error(failure)
	quit(1)


func _create_mortar(as_proxy: bool, net_id: int) -> BambooMortar:
	var mortar := MORTAR_SCENE.instantiate() as BambooMortar
	_expect(mortar != null, "竹筒迫击炮场景必须实例化为 BambooMortar。")
	if mortar == null:
		return null
	mortar.set_meta(&"net_id", net_id)
	runtime.add_child(mortar)
	mortar.setup(MORTAR_CONFIG, null, [], as_proxy)
	mortar.attack_timer.stop()
	mortar.target_track_timer.stop()
	return mortar


func _test_config_and_scene_contract(mortar: BambooMortar) -> void:
	_expect(MORTAR_CONFIG.is_valid(), "竹筒迫击炮配置必须有效。")
	_expect(
		MORTAR_CONFIG.plant_id == &"bamboo_mortar"
		and MORTAR_CONFIG.display_name == "竹筒迫击炮"
		and MORTAR_CONFIG.max_health == 2000
		and MORTAR_CONFIG.physical_defense == 10
		and MORTAR_CONFIG.magic_defense == 20
		and MORTAR_CONFIG.attack_damage == 100
		and is_equal_approx(MORTAR_CONFIG.get_attack_interval(), 2.0)
		and is_equal_approx(MORTAR_CONFIG.attack_range, 160.0)
		and MORTAR_CONFIG.footprint_size == Vector2i(2, 2)
		and MORTAR_CONFIG.placement_surface
		== PlantDefenseConfig.PlacementSurface.GRASS
		and MORTAR_CONFIG.supports_multiplayer,
		"迫击炮数值必须为2000生命、10物防、20法防、100中心伤害、2秒冷却、160范围、草地2×2且支持多人。"
	)
	_expect(
		PlantDefenseRegistry.get_config(&"bamboo_mortar")
		== MORTAR_CONFIG
		and PlantDefenseRegistry.get_all_configs().size() == 9
		and PlantDefenseRegistry.get_all_configs().back() == MORTAR_CONFIG,
		"迫击炮必须作为第九种植物进入公共注册表。"
	)
	_expect(
		mortar.main_sprite.sprite_frames.get_frame_count(&"charge") == 8
		and is_equal_approx(
			mortar.main_sprite.sprite_frames.get_animation_speed(&"charge"),
			2.0
		)
		and not mortar.main_sprite.sprite_frames.get_animation_loop(&"charge"),
		"蓄热必须是8帧、2 FPS、非循环动画，总时长4秒。"
	)
	_expect(
		mortar.main_sprite.sprite_frames.get_frame_count(&"fire") == 4
		and is_equal_approx(
			mortar.main_sprite.sprite_frames.get_animation_speed(&"fire"),
			12.0
		)
		and not mortar.main_sprite.sprite_frames.get_animation_loop(&"fire"),
		"蓄热后必须播放4帧、12 FPS、非循环的明确出膛动画。"
	)
	_expect(
		mortar.get_node_or_null("TargetingArea") == null
		and mortar.get_node_or_null("VisualRoot/Muzzle") is Marker2D
		and mortar.get_node_or_null("VisualRoot/StatusLight") is Polygon2D
		and mortar.get_node_or_null("VisualRoot/GlowSprite") == null
		and mortar.get_node_or_null("AttackTimer") is Timer
		and mortar.get_node_or_null("TargetTrackTimer") is Timer
		and mortar.get_node_or_null("FireAudio") is AudioStreamPlayer2D,
		"迫击炮必须用预建Marker、独立方形状态灯、Timer与音效节点，且不能常驻TargetingArea或纹理灯遮罩。"
	)
	_expect(
		mortar.attack_timer.one_shot
		and is_equal_approx(mortar.attack_timer.wait_time, 2.0)
		and is_equal_approx(
			mortar.target_track_timer.wait_time,
			0.5
		),
		"场景计时器必须保持2秒冷却和0.5秒目标位置采样。"
	)
	_expect(
		mortar.get_node("VisualRoot").scale == Vector2(0.5, 0.5)
		and mortar.main_sprite.texture_filter
		== CanvasItem.TEXTURE_FILTER_NEAREST
		and mortar.status_light.polygon
		== PackedVector2Array([
			Vector2(-8, -8),
			Vector2(8, -8),
			Vector2(8, 8),
			Vector2(-8, 8),
		])
		and mortar.status_light.uv
		== PackedVector2Array([
			Vector2(0, 0),
			Vector2(1, 0),
			Vector2(1, 1),
			Vector2(0, 1),
		]),
		"64×64主体必须以0.5缩放和邻近过滤显示，状态灯必须以单个16×16逻辑像素节点绘制清晰6×6核心、深色边界与分层光晕。"
	)
	var mortar_source := FileAccess.get_file_as_string(
		"res://scene/plant_defense/bamboo_mortar.gd"
	)
	var shell_source := FileAccess.get_file_as_string(
		"res://scene/plant_defense/bamboo_mortar_shell.gd"
	)
	var glow_shader_source := FileAccess.get_file_as_string(
		"res://resources/shader/bamboo_mortar_glow.gdshader"
	)
	_expect(
		not mortar_source.contains("func _process(")
		and not mortar_source.contains("PhysicsRayQueryParameters2D")
		and mortar_source.contains(
			"query_combat_targets_unordered_into"
		)
		and shell_source.contains(
			"query_combat_targets_unordered_into"
		)
		and not shell_source.contains("intersect_shape"),
		"迫击炮不得常驻逐帧脚本、视线射线或物理分页爆炸查询，索敌与爆炸必须复用共享索引。"
	)
	_expect(
		bool(
			ProjectSettings.get_setting(
				"rendering/viewport/hdr_2d",
				false
			)
		)
		and glow_shader_source.contains("instance uniform")
		and glow_shader_source.contains("blend_mix")
		and glow_shader_source.contains("varying vec2 shape_uv")
		and glow_shader_source.contains(
			"shape_uv = (VERTEX + vec2(8.0)) / 16.0"
		)
		and not glow_shader_source.contains(
			"abs(UV - vec2(0.5))"
		)
		and glow_shader_source.contains("core_mask")
		and glow_shader_source.contains("core_border_mask")
		and glow_shader_source.contains("inner_halo_mask")
		and glow_shader_source.contains("outer_halo_mask")
		and not FileAccess.file_exists(
			"res://resources/texture/plant_defense/bamboo_mortar/glow_mask.png"
		),
		"中下部状态灯必须由一个Godot节点以对应颜色绘制不透明亮核、深色边界与内外光晕，不能用纯加色吞掉核心，也不能残留贴图灯或逐实例材质复制。"
	)


func _test_target_ring_and_tracking(mortar: BambooMortar) -> void:
	await _clear_enemies()
	var too_close := _spawn_enemy(Vector2(64.0, 0.0))
	var nearest_valid := _spawn_enemy(Vector2(64.25, 0.0))
	var farther_valid := _spawn_enemy(Vector2(120.0, 0.0))
	var outer_edge := _spawn_enemy(Vector2(160.0, 0.0))
	var outside := _spawn_enemy(Vector2(160.25, 0.0))
	runtime.candidates.assign(enemies)
	var selected := mortar.call(
		"_select_nearest_target_in_ring"
	) as Enemy
	_expect(
		selected == nearest_valid,
		"索敌必须排除64像素边界并选择(64,160]内最近敌人。"
	)
	nearest_valid.is_dead = true
	selected = mortar.call("_select_nearest_target_in_ring") as Enemy
	_expect(
		selected == farther_valid,
		"最近目标失效后必须在同一无序候选缓冲中选择下一名目标。"
	)
	farther_valid.global_position = Vector2(100.0, 0.0)
	mortar.pending_target = farther_valid
	mortar.last_valid_target_position = Vector2(80.0, 0.0)
	mortar.call("_update_last_valid_target_position")
	_expect(
		mortar.last_valid_target_position == Vector2(100.0, 0.0),
		"有效目标的位置必须按0.5秒采样更新。"
	)
	farther_valid.global_position = Vector2(200.0, 0.0)
	mortar.call("_update_last_valid_target_position")
	farther_valid.is_dead = true
	mortar.call("_update_last_valid_target_position")
	_expect(
		mortar.last_valid_target_position == Vector2(100.0, 0.0),
		"目标离开范围或死亡后必须保留最后一次有效落点。"
	)
	var freed_during_windup := _spawn_enemy(Vector2(112.0, 0.0))
	mortar.pending_target = freed_during_windup
	var preserved_position := mortar.last_valid_target_position
	freed_during_windup.queue_free()
	await process_frame
	mortar.call("_update_last_valid_target_position")
	_expect(
		mortar.pending_target == null
		and mortar.last_valid_target_position == preserved_position,
		"目标在4秒前摇期间被释放时，必须安全清空引用并保留最后有效落点。"
	)
	_expect(
		too_close != null
		and outer_edge != null
		and outside != null
		and is_equal_approx(runtime.last_query_radius, 160.0),
		"边界样本与160像素共享索引查询必须完整建立。"
	)
	runtime.queued_visuals.clear()
	mortar.pending_target = null
	mortar.combat_phase = BambooMortar.CombatPhase.IDLE
	mortar.attack_timer.stop()
	var operational_query_count := runtime.query_count
	mortar.call("_on_operational_started")
	_expect(
		runtime.query_count == operational_query_count + 1
		and mortar.pending_target == outer_edge
		and mortar.combat_phase == BambooMortar.CombatPhase.WINDUP
		and mortar.attack_timer.is_stopped()
		and runtime.queued_visuals.size() == 1,
		"建造完成进入可用状态时必须立即索敌并开始前摇，不能先空等2秒冷却。"
	)
	mortar.target_track_timer.stop()
	mortar.pending_target = null
	mortar.combat_phase = BambooMortar.CombatPhase.IDLE
	mortar.main_sprite.play(&"idle")
	mortar.call("_set_glow_state", false, 0)


func _test_windup_fire_and_fixed_landing(
	mortar: BambooMortar
) -> void:
	runtime.queued_visuals.clear()
	var target := enemies[2]
	target.is_dead = false
	target.global_position = Vector2(96.0, 0.0)
	mortar.call("_begin_authoritative_windup", target)
	_expect(
		mortar.combat_phase == BambooMortar.CombatPhase.WINDUP
		and mortar.main_sprite.animation == &"charge"
		and not mortar.target_track_timer.is_stopped()
		and runtime.queued_visuals.size() == 1
		and int(runtime.queued_visuals[0].get("stage", -1))
		== BambooMortar.NETWORK_STAGE_WINDUP,
		"开始攻击必须进入4秒蓄热、启用0.5秒采样并只排队一次蓄热网络事件。"
	)
	mortar.last_valid_target_position = Vector2(96.0, 0.0)
	target.is_dead = true
	mortar.call("_fire_authoritative_shell")
	_expect(
		mortar.combat_phase == BambooMortar.CombatPhase.FIRING
		and mortar.main_sprite.animation == &"fire"
		and mortar.main_sprite.frame
		== BambooMortar.FIRE_LAUNCH_FRAME
		and mortar.main_sprite.position
		== BambooMortar.FIRE_RECOIL_OFFSET
		and is_equal_approx(
			mortar.attack_timer.time_left,
			BambooMortar.ATTACK_COOLDOWN_SECONDS
		)
		and runtime.queued_visuals.size() == 2
		and int(runtime.queued_visuals[1].get("stage", -1))
		== BambooMortar.NETWORK_STAGE_FIRE
		and runtime.queued_visuals[1].get(
			"landing_position",
			Vector2.ZERO
		) == Vector2(96.0, 0.0),
		"目标死亡后仍须在可见爆闪/后坐帧向最后有效位置出膛，并从出膛时开始2秒冷却。"
	)
	var active_shell := _find_active_shell()
	var expected_flight_duration := (
		clampf(
			active_shell.start_position.distance_to(
				active_shell.landing_position
			) / BambooMortarShell.PROJECTILE_SPEED_PIXELS_PER_SECOND,
			BambooMortarShell.MIN_FLIGHT_DURATION_SECONDS,
			BambooMortarShell.MAX_FLIGHT_DURATION_SECONDS
		)
		if active_shell != null
		else 0.0
	)
	_expect(
		active_shell != null
		and active_shell.landing_position == Vector2(96.0, 0.0)
		and is_equal_approx(
			active_shell.flight_duration_seconds,
			expected_flight_duration
		)
		and active_shell.flight_duration_seconds <= 0.55
		and is_equal_approx(
			active_shell.arc_height,
			clampf(
				active_shell.start_position.distance_to(
					active_shell.landing_position
				) * BambooMortarShell.ARC_HEIGHT_DISTANCE_FACTOR,
				BambooMortarShell.MIN_ARC_HEIGHT,
				BambooMortarShell.MAX_ARC_HEIGHT
			)
		)
		and active_shell.ground_shadow is Polygon2D
		and active_shell.ground_shadow.visible
		and active_shell.ground_shadow.polygon
		== PackedVector2Array([
			Vector2(-3, 0),
			Vector2(-2, -1),
			Vector2(2, -1),
			Vector2(3, 0),
			Vector2(2, 1),
			Vector2(-2, 1),
		]),
		"炮弹必须以300像素/秒和0.28至0.55秒距离限幅锁定落点，采用更低更快的抛物线，并复用场景内预建的像素地面影子。"
	)
	if active_shell != null:
		active_shell.set_physics_process(false)
		active_shell.flight_elapsed_seconds = (
			active_shell.flight_duration_seconds * 0.5
		)
		active_shell.call("_update_flight_position")
		var expected_shadow_midpoint := (
			active_shell.shadow_start_position.lerp(
				active_shell.landing_position,
				0.5
			)
		)
		var expected_projectile_apex := (
			active_shell.start_position.lerp(
				active_shell.landing_position,
				0.5
			)
			+ Vector2.UP * active_shell.arc_height
		)
		_expect(
			active_shell.global_position.is_equal_approx(
				expected_shadow_midpoint
			)
			and active_shell.visual.global_position.is_equal_approx(
				expected_projectile_apex
			)
			and is_equal_approx(
				active_shell.ground_shadow.modulate.a,
				BambooMortarShell.SHADOW_APEX_ALPHA_FACTOR
			),
			"飞行中点必须让根节点和影子沿地面前进，炮弹视觉独立到达抛物线顶点，并随高度淡化影子。"
		)
	mortar.call("_finish_fire_visual")
	_expect(
		mortar.combat_phase == BambooMortar.CombatPhase.COOLDOWN
		and mortar.main_sprite.animation == &"idle"
		and mortar.main_sprite.position == Vector2.ZERO,
		"开火动画结束后必须复位主体并进入冷却，不得从蓄热直接跳回待机。"
	)
	await _finish_active_shells()


func _test_shell_duration_and_late_join(
	mortar: BambooMortar
) -> void:
	var pool := runtime.session_object_pool
	var start := Vector2(12.0, 18.0)
	var short_landing := start + Vector2(24.0, 0.0)
	var short_shell := pool.acquire(SHELL_SCENE) as BambooMortarShell
	_expect(short_shell != null, "短程飞行测试必须成功租用炮弹。")
	if short_shell != null:
		short_shell.setup(
			start,
			short_landing,
			100,
			50,
			false,
			0,
			0.0
		)
		_expect(
			is_equal_approx(
				short_shell.flight_duration_seconds,
				BambooMortarShell.MIN_FLIGHT_DURATION_SECONDS
			),
			"近距离炮弹必须使用0.28秒下限，既加速又保留可读的飞行帧。"
		)
		short_shell.call("_impact")
		short_shell.call("_on_visual_animation_finished")
	await physics_frame
	await physics_frame

	var far_landing := start + Vector2(300.0, 0.0)
	var far_shell := pool.acquire(SHELL_SCENE) as BambooMortarShell
	_expect(far_shell != null, "远程飞行测试必须成功复用炮弹。")
	if far_shell != null:
		far_shell.setup(
			start,
			far_landing,
			100,
			50,
			false,
			0,
			0.0
		)
		_expect(
			is_equal_approx(
				far_shell.flight_duration_seconds,
				BambooMortarShell.MAX_FLIGHT_DURATION_SECONDS
			),
			"远距离炮弹必须受0.55秒上限约束，不能恢复为长时间滞空。"
		)
		far_shell.call("_impact")
		far_shell.call("_on_visual_animation_finished")
	await physics_frame
	await physics_frame

	var late_landing := start + Vector2(160.0, 0.0)
	var late_flight_duration := (
		BambooMortarShell.get_flight_duration_seconds(
			start,
			late_landing
		)
	)
	var late_elapsed := (
		late_flight_duration
		+ BambooMortarShell.EXPLOSION_DURATION_SECONDS * 0.25
	)
	var late_shell := pool.acquire(SHELL_SCENE) as BambooMortarShell
	_expect(late_shell != null, "延迟加入爆炸恢复测试必须成功复用炮弹。")
	if late_shell != null:
		late_shell.setup(
			start,
			late_landing,
			100,
			50,
			false,
			0,
			late_elapsed
		)
		_expect(
			bool(late_shell.get("_has_impacted"))
			and late_shell.global_position == late_landing
			and late_shell.visual.position == Vector2.ZERO
			and late_shell.visual.animation == &"explosion"
			and not late_shell.ground_shadow.visible,
			"客户端晚到飞行事件若已进入爆炸阶段，必须直接在落点恢复爆炸并隐藏地影。"
		)
		late_shell.call("_on_visual_animation_finished")
	await physics_frame
	await physics_frame

	var snapshot_action_id := 8801
	var snapshot_landing := start + Vector2(120.0, 16.0)
	var snapshot_total_duration := (
		BambooMortarShell.get_total_visual_duration_seconds(
			start,
			snapshot_landing
		)
	)
	mortar.set("_last_projectile_action_id", snapshot_action_id)
	mortar.set("_last_projectile_spawn_position", start)
	mortar.set(
		"_last_projectile_landing_position",
		snapshot_landing
	)
	mortar.set(
		"_last_projectile_started_at_seconds",
		Time.get_ticks_msec() / 1000.0 - 0.1
	)
	var active_snapshot := mortar.export_multiplayer_runtime_state()
	mortar.set(
		"_last_projectile_started_at_seconds",
		Time.get_ticks_msec() / 1000.0
		- snapshot_total_duration
		- 0.01
	)
	var expired_snapshot := mortar.export_multiplayer_runtime_state()
	_expect(
		int(active_snapshot.get("projectile_action_id", 0))
		== snapshot_action_id
		and active_snapshot.get(
			"projectile_landing_position",
			Vector2.ZERO
		) == snapshot_landing
		and not expired_snapshot.has("projectile_action_id"),
		"运行时快照必须按本次端点的实际总时长保留飞行事件，并在视觉结束后立即停止同步。"
	)
	mortar.set("_last_projectile_action_id", 0)
	mortar.set("_last_projectile_started_at_seconds", -INF)
	mortar.set("_last_projectile_spawn_position", Vector2.ZERO)
	mortar.set("_last_projectile_landing_position", Vector2.ZERO)

	var metrics_before_expired := pool.get_metrics(
		SHELL_SCENE.resource_path
	)
	var expired_shell := mortar.call(
		"_spawn_shell",
		start,
		late_landing,
		false,
		BambooMortarShell.get_total_visual_duration_seconds(
			start,
			late_landing
		)
	) as BambooMortarShell
	var metrics_after_expired := pool.get_metrics(
		SHELL_SCENE.resource_path
	)
	_expect(
		expired_shell == null
		and int(metrics_after_expired.get("in_use", -1))
		== int(metrics_before_expired.get("in_use", -2))
		and int(metrics_after_expired.get("created", -1))
		== int(metrics_before_expired.get("created", -2)),
		"已超过实际总时长的联机事件必须在租池前丢弃，不能短暂激活或扩容炮弹。"
	)


func _test_explosion_damage_boundaries() -> void:
	await _clear_enemies()
	var inner_edge := _spawn_enemy(Vector2(16.0, 0.0))
	var outer_start := _spawn_enemy(Vector2(16.25, 0.0))
	var outer_edge := _spawn_enemy(Vector2(32.0, 0.0))
	var outside := _spawn_enemy(Vector2(32.25, 0.0))
	runtime.candidates.assign(enemies)
	runtime.damage_records.clear()
	var queries_before := runtime.query_count
	var shell := runtime.acquire_session_object(
		SHELL_SCENE,
		false
	) as BambooMortarShell
	_expect(shell != null, "爆炸边界测试必须能从共享对象池租用炮弹。")
	if shell == null:
		return
	shell.setup(Vector2.ZERO, Vector2.ZERO, 100, 50, true, 9001, 0.0)
	shell.call("_impact")
	_expect(
		runtime.query_count == queries_before + 1,
		"一次爆炸必须且只能执行一次半径32的共享索引查询。"
	)
	var damage_by_enemy: Dictionary[int, int] = {}
	for record in runtime.damage_records:
		var enemy := record.get("enemy") as Enemy
		if enemy != null:
			damage_by_enemy[enemy.get_instance_id()] = int(
				record.get("damage", 0)
			)
		_expect(
			int(record.get("damage_type", -1))
			== EnemyConfig.DamageType.PHYSICAL,
			"迫击炮所有爆炸伤害必须标记为物理伤害。"
		)
	_expect(
		damage_by_enemy.get(inner_edge.get_instance_id(), 0) == 100
		and damage_by_enemy.get(outer_start.get_instance_id(), 0) == 50
		and damage_by_enemy.get(outer_edge.get_instance_id(), 0) == 50
		and not damage_by_enemy.has(outside.get_instance_id())
		and damage_by_enemy.size() == 3,
		"0至16像素必须造成100伤害，(16,32]造成50伤害，32外不得受伤。"
	)
	shell.call("_on_visual_animation_finished")
	await physics_frame
	await physics_frame


func _test_physical_defense_settlement() -> void:
	await _clear_enemies()
	var armored := (
		ARMORED_ENEMY_CONFIG.enemy_scene.instantiate() as Enemy
	)
	_expect(armored != null, "物理防御实结算必须成功实例化硬壳敌人。")
	if armored == null:
		return
	runtime.add_child(armored)
	armored.global_position = Vector2.ZERO
	armored.setup(ARMORED_ENEMY_CONFIG, null, null)
	armored.set_process(false)
	armored.set_physics_process(false)
	if armored.touch_damage_area != null:
		armored.touch_damage_area.set_deferred("monitoring", false)
		armored.touch_damage_area.set_deferred("monitorable", false)
	enemies.append(armored)
	runtime.candidates.assign(enemies)
	runtime.damage_records.clear()
	runtime.apply_real_damage = true
	var shell := runtime.acquire_session_object(
		SHELL_SCENE,
		false
	) as BambooMortarShell
	_expect(shell != null, "物理防御实结算必须能租用迫击炮弹。")
	if shell != null:
		shell.setup(
			Vector2.ZERO,
			Vector2.ZERO,
			100,
			50,
			true,
			9100,
			0.0
		)
		shell.call("_impact")
	_expect(
		armored.current_health == ARMORED_ENEMY_CONFIG.max_health - 97
		and armored.last_damage_taken == 97
		and runtime.damage_records.size() == 1
		and int(
			runtime.damage_records[0].get("damage_type", -1)
			if not runtime.damage_records.is_empty()
			else -1
		) == EnemyConfig.DamageType.PHYSICAL,
		"100点中心物理伤害命中3点物防敌人时必须且只能扣除97点生命。"
	)
	runtime.apply_real_damage = false
	if shell != null:
		shell.call("_on_visual_animation_finished")
	await physics_frame
	await physics_frame


func _test_proxy_actions_and_runtime_state(
	authority: BambooMortar,
	proxy: BambooMortar
) -> void:
	proxy.main_sprite.position = BambooMortar.FIRE_RECOIL_OFFSET
	proxy.play_multiplayer_action(
		BambooMortar.NETWORK_STAGE_WINDUP,
		17,
		proxy.muzzle.global_position,
		Vector2(88.0, 0.0),
		1.25
	)
	var first_frame := proxy.main_sprite.frame
	proxy.play_multiplayer_action(
		BambooMortar.NETWORK_STAGE_WINDUP,
		17,
		proxy.muzzle.global_position,
		Vector2(120.0, 0.0),
		0.0
	)
	_expect(
		first_frame == 2
		and proxy.main_sprite.frame == first_frame
		and proxy.main_sprite.position
		== BambooMortar.MAIN_SPRITE_REST_POSITION
		and proxy.latest_proxy_action_id == 17,
		"客户端必须复位旧后坐位移、按Host时间快进至对应蓄热帧，并拒绝重复阶段回滚。"
	)
	proxy.call("_on_main_sprite_animation_finished")
	_expect(
		proxy.main_sprite.animation == &"fire"
		and proxy.main_sprite.frame == 0
		and proxy.combat_phase == BambooMortar.CombatPhase.FIRING,
		"客户端蓄热结束后必须先显示与Host一致的fire_0预备帧，不能停在charge末帧等待出膛事件。"
	)
	proxy.play_multiplayer_action(
		BambooMortar.NETWORK_STAGE_FIRE,
		17,
		proxy.muzzle.global_position,
		Vector2(88.0, 0.0),
		0.0
	)
	var proxy_shell_count := _count_active_shells()
	_expect(
		proxy.main_sprite.animation == &"fire"
		and proxy.main_sprite.frame
		== BambooMortar.FIRE_LAUNCH_FRAME
		and proxy.combat_phase == BambooMortar.CombatPhase.FIRING,
		"客户端收到出膛事件时必须显示对应爆闪/后坐帧，不能直接跳回idle。"
	)
	proxy.play_multiplayer_action(
		BambooMortar.NETWORK_STAGE_FIRE,
		17,
		proxy.muzzle.global_position,
		Vector2(88.0, 0.0),
		0.0
	)
	_expect(
		_count_active_shells() == proxy_shell_count
		and proxy.latest_proxy_stage
		== BambooMortar.NETWORK_STAGE_FIRE,
		"同一action_id的重复出膛记录不得生成第二枚客户端视觉炮弹。"
	)
	authority.combat_phase = BambooMortar.CombatPhase.WINDUP
	authority.next_authoritative_action_id = 23
	authority.last_valid_target_position = Vector2(112.0, 8.0)
	authority.set(
		"_windup_started_at_seconds",
		Time.get_ticks_msec() / 1000.0 - 1.5
	)
	var snapshot := authority.export_multiplayer_runtime_state()
	var fresh_proxy := _create_mortar(true, 703)
	if fresh_proxy != null:
		fresh_proxy.apply_multiplayer_runtime_state(
			snapshot,
			Time.get_ticks_msec() / 1000.0
		)
		_expect(
			fresh_proxy.latest_proxy_action_id == 23
			and fresh_proxy.combat_phase
			== BambooMortar.CombatPhase.WINDUP
			and fresh_proxy.main_sprite.frame >= 2,
			"中途加入的客户端必须从运行时快照恢复当前action与蓄热进度。"
		)
	await _finish_active_shells()


func _test_pool_reuse() -> void:
	var pool := runtime.session_object_pool
	var before := pool.get_metrics(SHELL_SCENE.resource_path)
	var first := pool.acquire(SHELL_SCENE) as BambooMortarShell
	_expect(first != null, "对象池复用测试必须成功租用炮弹。")
	if first == null:
		return
	var first_id := first.get_instance_id()
	first.setup(Vector2.ZERO, Vector2(80.0, 0.0), 100, 50, false, 0, 0.0)
	first.call("_impact")
	first.call("_on_visual_animation_finished")
	await physics_frame
	await physics_frame
	var second := pool.acquire(SHELL_SCENE) as BambooMortarShell
	_expect(
		second != null
		and second.get_instance_id() == first_id
		and not second.get("_has_impacted")
		and second.inner_damage == 100
		and second.outer_damage == 50,
		"炮弹租约必须复用同一实例并完整复位命中、伤害和动画状态。"
	)
	if second != null:
		second.setup(Vector2.ZERO, Vector2(80.0, 0.0), 100, 50, false, 0, 0.0)
		second.call("_impact")
		second.call("_on_visual_animation_finished")
	await physics_frame
	await physics_frame
	var after := pool.get_metrics(SHELL_SCENE.resource_path)
	_expect(
		int(after.get("created", -1))
		== int(before.get("created", -2))
		and int(after.get("in_use", -1)) == 0
		and int(after.get("pending_release", -1)) == 0,
		"预热后的重复租约不得新增节点，测试结束必须归还全部炮弹。"
	)


func _spawn_enemy(position: Vector2) -> Enemy:
	var enemy := ENEMY_SCENE.instantiate() as Enemy
	_expect(enemy != null, "边界测试敌人必须成功实例化。")
	if enemy == null:
		return null
	runtime.add_child(enemy)
	enemy.global_position = position
	enemy.is_dead = false
	enemy.set_process(false)
	enemy.set_physics_process(false)
	if enemy.touch_damage_area != null:
		enemy.touch_damage_area.set_deferred("monitoring", false)
		enemy.touch_damage_area.set_deferred("monitorable", false)
	enemies.append(enemy)
	return enemy


func _clear_enemies() -> void:
	runtime.candidates.clear()
	for enemy in enemies:
		if enemy != null and is_instance_valid(enemy):
			enemy.queue_free()
	enemies.clear()
	await process_frame


func _find_active_shell() -> BambooMortarShell:
	for child in runtime.session_object_pool.get_children():
		var shell := child as BambooMortarShell
		if (
			shell != null
			and bool(
				shell.get_meta(
					SessionObjectPool.POOL_ACTIVE_META,
					false
				)
			)
		):
			return shell
	return null


func _count_active_shells() -> int:
	var count := 0
	for child in runtime.session_object_pool.get_children():
		if (
			child is BambooMortarShell
			and bool(
				child.get_meta(
					SessionObjectPool.POOL_ACTIVE_META,
					false
				)
			)
		):
			count += 1
	return count


func _finish_active_shells() -> void:
	for child in runtime.session_object_pool.get_children():
		var shell := child as BambooMortarShell
		if (
			shell == null
			or not bool(
				shell.get_meta(
					SessionObjectPool.POOL_ACTIVE_META,
					false
				)
			)
		):
			continue
		if not bool(shell.get("_has_impacted")):
			shell.call("_impact")
		shell.call("_on_visual_animation_finished")
	await physics_frame
	await physics_frame


func _cleanup() -> void:
	await _finish_active_shells()
	await _clear_enemies()
	current_scene = null
	if runtime != null and is_instance_valid(runtime):
		runtime.queue_free()
	for _frame in range(4):
		await process_frame
		await physics_frame


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
