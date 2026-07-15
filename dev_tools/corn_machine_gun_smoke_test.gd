extends SceneTree

const CORN_SCENE := preload("res://scene/plant_defense/corn_machine_gun.tscn")
const CORN_CONFIG := preload("res://resources/config/plant_defense/corn_machine_gun.tres")
const ENEMY_SCENE := preload("res://scene/enemy/enemy.tscn")
const FIRE_STREAM := preload("res://resources/audio/capoo_smg_fire.wav")
const AUDIO_LIMITER := preload("res://scene/plant_defense/plant_attack_audio_limiter.gd")
const TEST_SEED := 20260715

var failures: Array[String] = []
var fixture: Node2D = null


class TargetRuntimeStub:
	extends Node2D

	var candidate: Enemy = null
	var candidates: Array[Enemy] = []
	var query_call_count := 0
	var unordered_query_call_count := 0
	var reused_output_buffer := true
	var all_queries_requested_nearest := true
	var first_output_buffer: Array[Enemy] = []
	var has_output_buffer := false

	func query_combat_targets_into(
		_center: Vector2,
		_radius: float,
		result: Array[Enemy],
		max_count: int = 0
	) -> void:
		query_call_count += 1
		all_queries_requested_nearest = all_queries_requested_nearest and max_count == 1
		_track_output_buffer(result)
		result.clear()
		if not candidates.is_empty():
			result.append(candidates[0])
			return
		if candidate != null and is_instance_valid(candidate):
			result.append(candidate)

	func query_combat_targets_unordered_into(
		_center: Vector2,
		_radius: float,
		result: Array[Enemy]
	) -> void:
		unordered_query_call_count += 1
		_track_output_buffer(result)
		result.clear()
		for target in candidates:
			if target != null and is_instance_valid(target):
				result.append(target)

	func _track_output_buffer(result: Array[Enemy]) -> void:
		if not has_output_buffer:
			first_output_buffer = result
			has_output_buffer = true
			return
		reused_output_buffer = reused_output_buffer and is_same(
			first_output_buffer,
			result
		)


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	fixture = Node2D.new()
	fixture.name = "CornMachineGunSmokeFixture"
	root.add_child(fixture)

	var authority := _create_tower(false)
	var proxy := _create_tower(true)
	if authority != null and proxy != null:
		_test_scene_contract(authority)
		_test_physical_defense_round_totals()
		_test_six_shot_frame_catchup(authority)
		_test_proxy_elapsed_and_monotonic_actions(proxy)
		_test_idle_aim_alternation(authority)
		await _test_target_and_ray_query_reuse(authority)
		await _test_blocked_nearest_adaptive_selection(authority)
		await _test_hitscan_first_collision(authority)
	_test_shared_audio_limiter()

	_stop_fixture_audio(fixture)
	fixture.queue_free()
	for _cleanup_frame in range(4):
		await process_frame

	if failures.is_empty():
		print("CORN_MACHINE_GUN_SMOKE_TEST_OK")
		quit()
		return
	for failure in failures:
		push_error(failure)
	quit(1)


func _create_tower(as_proxy: bool) -> CornMachineGun:
	var tower := CORN_SCENE.instantiate() as CornMachineGun
	_expect(tower != null, "玉米机枪塔场景必须实例化为 CornMachineGun。")
	if tower == null:
		return null
	fixture.add_child(tower)
	tower.setup(CORN_CONFIG, null, [], as_proxy)
	tower.attack_timer.stop()
	return tower


func _test_scene_contract(tower: CornMachineGun) -> void:
	var muzzle_markers := tower.find_children("Muzzle", "Marker2D", true, false)
	_expect(muzzle_markers.size() == 1, "场景必须且只能预置一个 Muzzle Marker2D。")
	_expect(tower.get_node_or_null("TargetingArea") == null, "玉米机枪塔不得创建独立 TargetingArea。")
	_expect(
		tower.get_node_or_null("VisualRoot/AimPivot/ForwardMarker") is Marker2D,
		"炮塔必须使用独立 ForwardMarker 校准瞄准轴。"
	)
	_expect(
		tower.aim_pivot.position == Vector2(3, -1)
		and tower.turret_sprite.position == Vector2(-5, 0)
		and tower.forward_marker.position == Vector2(20, 1)
		and tower.muzzle.position == Vector2(20, 1)
		and tower.muzzle_flash_sprite.position == Vector2(20, 1),
		"炮塔枢轴必须位于炮头后半中心，中央枪口与公共闪光必须匹配补偿坐标。"
	)
	_expect(
		tower.aim_pivot.position + tower.turret_sprite.position == Vector2(-2, -1)
		and tower.aim_pivot.position + tower.muzzle.position == Vector2(23, 0)
		and tower.aim_pivot.position + tower.muzzle_flash_sprite.position == Vector2(23, 0),
		"移动旋转轴后，默认炮头、真实枪口与公共闪光的位置不得发生漂移。"
	)
	var aim_probe_direction := Vector2(1.0, 0.37).normalized()
	tower.call("_point_aim_at_direction", aim_probe_direction)
	var authored_forward_direction := tower.aim_pivot.global_position.direction_to(
		tower.forward_marker.global_position
	)
	_expect(
		authored_forward_direction.dot(aim_probe_direction) > 0.9999,
		"ForwardMarker 旋转后的方向必须严格对齐锁定方向。"
	)
	_expect(tower.tracer is Line2D, "Tracer 必须是场景预置的 Line2D。")
	_expect(tower.tracer_fade is AnimationPlayer, "TracerFade 必须是场景预置的 AnimationPlayer。")
	_expect(tower.tracer.is_set_as_top_level(), "Tracer 必须脱离 0.5 VisualRoot 缩放以保持世界长度。")
	_expect(is_equal_approx(tower.tracer.width, 0.5), "Tracer 世界宽度必须为0.5。")
	var fade_animation := tower.tracer_fade.get_animation(&"fade")
	_expect(
		fade_animation != null and is_equal_approx(fade_animation.length, 0.06),
		"Tracer 必须在0.06秒内淡出。"
	)
	_expect(
		tower.turret_sprite.sprite_frames.get_frame_count(&"spin") == 4
		and is_equal_approx(
			tower.turret_sprite.sprite_frames.get_animation_speed(&"spin"),
			20.0
		),
		"炮塔 spin 必须是4帧20fps循环。"
	)
	_expect(
		is_equal_approx(
			tower.body_sprite.sprite_frames.get_animation_speed(&"idle"),
			3.0
		),
		"机身 idle 必须保持3 FPS。"
	)
	_expect(
		is_equal_approx(
			tower.muzzle_flash_sprite.sprite_frames.get_animation_speed(&"flash"),
			50.0
		),
		"两帧公共枪口闪光总时长必须约为0.04秒。"
	)
	_expect(CORN_CONFIG.attack_burst_count == 6, "玉米配置必须为每轮6发。")
	_expect(
		is_equal_approx(CORN_CONFIG.attack_burst_shot_interval, 0.06),
		"玉米配置发间隔必须为0.06秒。"
	)
	_expect(
		tower.fire_audio.max_polyphony == 1
		and tower.fire_audio.stream != null
		and tower.fire_audio.stream.resource_path.ends_with("capoo_smg_fire.wav"),
		"每轮音效必须复用 capoo_smg_fire.wav，且单节点只占一个声部。"
	)
	_expect(
		AUDIO_LIMITER.MAX_SIMULTANEOUS_VOICES == 6,
		"植物攻击音频限制器必须共享最多6个声部。"
	)


func _test_six_shot_frame_catchup(tower: CornMachineGun) -> void:
	# Combat scheduling is under direct test; keeping the stream detached avoids
	# an unrelated active playback surviving a failing assertion.
	tower.fire_audio.stream = null
	var emitted_indices: Array[int] = []
	var emitted_authority: Array[bool] = []
	tower.burst_shot_emitted.connect(
		func(shot_index: int, authoritative: bool) -> void:
			emitted_indices.append(shot_index)
			emitted_authority.append(authoritative)
	)
	var fixture_children_before := fixture.get_child_count()
	var tower_children_before := tower.get_child_count()
	var hitscan_queries_before := tower.get_hitscan_query_count()
	var authored_idle_center := tower.idle_aim_center_rotation
	tower.call("_begin_burst", Vector2.RIGHT, 1, 0.0, true)
	_expect(emitted_indices == [0], "权威 Burst 必须在 t=0 立即发射第一发。")
	_expect(
		absf(angle_difference(tower.aim_pivot.rotation, authored_idle_center)) > 0.01,
		"回正测试必须先让 Burst 锁定到非默认角度。"
	)
	_expect(
		tower.burst_muzzle_position.is_equal_approx(tower.muzzle.global_position)
		and tower.tracer.global_position.is_equal_approx(tower.burst_muzzle_position)
		and is_equal_approx(tower.tracer.global_rotation, Vector2.RIGHT.angle())
		and tower.tracer.get_point_position(0) == Vector2.ZERO,
		"锁定 Burst 必须复用唯一 Muzzle 的精确世界位置、方向和静态 Tracer 起点。"
	)
	tower.call("_physics_process", 0.30)
	_expect(
		emitted_indices == [0, 1, 2, 3, 4, 5],
		"单个0.30秒物理帧必须按时间线补齐完整6发且不漏发。"
	)
	_expect(
		not emitted_authority.has(false),
		"权威 Burst 的每发都必须携带权威标记。"
	)
	_expect(not tower.burst_active, "第6发后 Burst 必须立即结束。")
	_expect(
		tower.get_hitscan_query_count() == hitscan_queries_before + 6,
		"权威6发 Burst 必须且只能执行6次首碰撞射线。"
	)
	_expect(not tower.is_physics_processing(), "待机状态不得持续运行物理处理。")
	_expect(
		fixture.get_child_count() == fixture_children_before
		and tower.get_child_count() == tower_children_before,
		"六发 Hitscan 不得动态创建投射物或其它运行时节点。"
	)
	_expect(
		is_zero_approx(angle_difference(
			tower.idle_aim_center_rotation,
			authored_idle_center
		))
		and is_zero_approx(angle_difference(
			tower.aim_pivot.rotation,
			authored_idle_center
		))
		and tower.idle_aim_active,
		"战斗结束后必须回到场景默认角，再从该中心恢复待机摆动。"
	)


func _test_physical_defense_round_totals() -> void:
	var enemy := Enemy.new()
	var enemy_config := EnemyConfig.new()
	enemy.config = enemy_config
	var defense_cases: Array[Vector2i] = [
		Vector2i(0, 60),
		Vector2i(5, 30),
		Vector2i(10, 6),
		Vector2i(25, 6),
	]
	for defense_case in defense_cases:
		enemy_config.physical_defense = defense_case.x
		enemy.call("_refresh_effective_physical_defense_cache")
		var per_shot_damage := int(
			enemy.call(
				"_calculate_incoming_damage",
				CORN_CONFIG.attack_damage,
				EnemyConfig.DamageType.PHYSICAL
			)
		)
		var round_damage := per_shot_damage * CORN_CONFIG.attack_burst_count
		_expect(
			round_damage == defense_case.y,
			"敌人物防%d时，玉米一轮6发总伤害必须为%d，实际为%d。"
			% [defense_case.x, defense_case.y, round_damage]
		)
	enemy.free()


func _test_proxy_elapsed_and_monotonic_actions(proxy: CornMachineGun) -> void:
	proxy.fire_audio.stream = null
	var authored_idle_center := proxy.idle_aim_center_rotation
	_expect(proxy.is_multiplayer_proxy, "代理测试塔必须标记为 multiplayer proxy。")
	_expect(proxy.attack_timer.is_stopped(), "代理必须停止本地索敌计时器。")
	_expect(not proxy.is_physics_processing(), "空闲代理不得运行物理处理。")
	var proxy_indices: Array[int] = []
	var proxy_authority: Array[bool] = []
	proxy.burst_shot_emitted.connect(
		func(shot_index: int, authoritative: bool) -> void:
			proxy_indices.append(shot_index)
			proxy_authority.append(authoritative)
	)

	proxy.play_multiplayer_burst(Vector2.RIGHT, 10, 0.13)
	_expect(proxy.latest_proxy_action_id == 10, "代理必须接受更新的 action_id。")
	_expect(
		proxy.burst_next_shot_index == 3 and proxy_indices.is_empty(),
		"elapsed=0.13 必须跳过0/.06/.12三发，只保留未来发次。"
	)
	_expect(
		proxy.turret_sprite.frame == 2
		and is_equal_approx(proxy.turret_sprite.frame_progress, 0.6),
		"代理必须按 elapsed 恢复 spin 的整数帧与小数进度。"
	)
	var elapsed_before_duplicate := proxy.burst_elapsed_seconds
	proxy.play_multiplayer_burst(Vector2.UP, 10, 0.0)
	proxy.play_multiplayer_burst(Vector2.UP, 9, 0.0)
	_expect(
		is_equal_approx(proxy.burst_elapsed_seconds, elapsed_before_duplicate)
		and proxy.burst_direction == Vector2.RIGHT,
		"重复或倒退 action_id 不得重置代理 Burst。"
	)
	proxy.call("_physics_process", 0.05)
	_expect(proxy_indices == [3], "代理到 t=.18 时只应播放第4发。")
	_expect(
		proxy.tracer.points.size() == 2
		and is_equal_approx(proxy.tracer.points[1].x, 20.0),
		"代理每发必须直接播放固定20世界单位 Tracer。"
	)
	proxy.call("_physics_process", 0.12)
	_expect(proxy_indices == [3, 4, 5], "代理必须继续播放其余未来发次。")
	_expect(
		not proxy.burst_active
		and proxy.idle_aim_active
		and is_zero_approx(angle_difference(
			proxy.aim_pivot.rotation,
			authored_idle_center
		)),
		"代理播放完未来发次后必须回到默认角的待机状态。"
	)
	_expect(
		not proxy_authority.has(true),
		"代理 Burst 的每发都必须是纯视觉、非权威。"
	)
	_expect(
		proxy.get_hitscan_query_count() == 0,
		"客户端代理完整 Burst 必须执行0次物理射线查询。"
	)

	proxy.play_multiplayer_burst(
		Vector2.UP,
		11,
		CornMachineGun.PROXY_BURST_EXPIRY_SECONDS
	)
	_expect(
		proxy.latest_proxy_action_id == 11
		and not proxy.burst_active
		and not proxy.is_physics_processing()
		and proxy.turret_sprite.animation == &"idle",
		"elapsed>=0.32 的动作必须只推进去重序号，不启动spin或物理处理。"
	)
	proxy.play_multiplayer_burst(Vector2.DOWN, 12, 0.0)
	_expect(
		proxy.latest_proxy_action_id == 12
		and proxy_indices.back() == 0
		and proxy.burst_active,
		"更新 action_id 且 elapsed=0 时必须立即播放首发。"
	)
	proxy.play_multiplayer_burst(
		Vector2.LEFT,
		13,
		CornMachineGun.PROXY_BURST_EXPIRY_SECONDS
	)
	_expect(
		proxy.latest_proxy_action_id == 13
		and not proxy.burst_active
		and not proxy.is_physics_processing()
		and proxy.idle_aim_active
		and is_zero_approx(angle_difference(
			proxy.idle_aim_center_rotation,
			authored_idle_center
		))
		and is_zero_approx(angle_difference(
			proxy.aim_pivot.rotation,
			authored_idle_center
		)),
		"更新且已过期的动作必须终止旧表现、回到默认角并保持物理处理关闭。"
	)


func _test_idle_aim_alternation(tower: CornMachineGun) -> void:
	tower.call("_stop_idle_aim")
	var authored_idle_center := tower.idle_aim_center_rotation
	tower.call("_point_aim_at_direction", Vector2.UP)
	tower.set_idle_aim_random_seed(TEST_SEED)
	tower.call("_start_idle_aim")
	_expect(
		is_zero_approx(angle_difference(
			tower.aim_pivot.rotation,
			authored_idle_center
		))
		and is_zero_approx(angle_difference(
			tower.idle_aim_center_rotation,
			authored_idle_center
		)),
		"进入待机时必须先回到场景默认角，且不得把最后瞄准角写成新中心。"
	)
	var previous_rotation := tower.aim_pivot.rotation
	var previous_move_direction := 0
	for _step_index in range(24):
		tower.call("_apply_idle_aim_step")
		var rotation_delta := tower.aim_pivot.rotation - previous_rotation
		var move_direction := signi(roundi(rotation_delta * 1000000.0))
		_expect(move_direction != 0, "每次待机移动必须具有非零方向。")
		if previous_move_direction != 0:
			_expect(
				move_direction == -previous_move_direction,
				"相邻待机移动方向必须严格相反。"
			)
		var target_offset := absf(
			tower.aim_pivot.rotation - tower.idle_aim_center_rotation
		)
		_expect(
			target_offset >= CornMachineGun.IDLE_AIM_MIN_TARGET_OFFSET - 0.00001
			and target_offset <= CornMachineGun.IDLE_AIM_LIMIT + 0.00001,
			"待机目标必须位于中心两侧3至15度范围内。"
		)
		var sampled_interval := float(tower.call("_sample_idle_aim_interval"))
		_expect(
			sampled_interval >= CornMachineGun.IDLE_AIM_INTERVAL_MIN
			and sampled_interval <= CornMachineGun.IDLE_AIM_INTERVAL_MAX,
			"待机间隔必须保持在0.75至1.15秒。"
		)
		previous_rotation = tower.aim_pivot.rotation
		previous_move_direction = move_direction
	tower.call("_stop_idle_aim")
	tower.aim_pivot.rotation = authored_idle_center


func _test_target_and_ray_query_reuse(tower: CornMachineGun) -> void:
	var runtime := TargetRuntimeStub.new()
	runtime.name = "CornTargetRuntimeStub"
	fixture.add_child(runtime)
	var enemy := ENEMY_SCENE.instantiate() as Enemy
	_expect(enemy != null, "Target reuse fixture must instantiate an Enemy.")
	if enemy == null:
		runtime.queue_free()
		return
	fixture.add_child(enemy)
	enemy.set_process(false)
	enemy.set_physics_process(false)
	enemy.is_dead = false
	enemy.collision_layer = 4
	enemy.collision_mask = 0
	tower.global_position = Vector2(256.0, 192.0)
	enemy.global_position = tower.aim_pivot.global_position + Vector2(40.0, 0.0)
	runtime.candidate = enemy
	tower.set("_combat_runtime", runtime)
	await physics_frame

	var ray_query_before: PhysicsRayQueryParameters2D = tower.get("_ray_query")
	var first_target := tower.call("_select_nearest_visible_enemy") as Enemy
	var second_target := tower.call("_select_nearest_visible_enemy") as Enemy
	var hit_result := tower.call("_cast_locked_hitscan", Vector2.RIGHT) as Dictionary
	var ray_query_after: PhysicsRayQueryParameters2D = tower.get("_ray_query")
	_expect(
		first_target == enemy and second_target == enemy,
		"Repeated Corn acquisition must preserve nearest-visible target semantics."
	)
	_expect(
		runtime.query_call_count == 2
		and runtime.reused_output_buffer
		and runtime.all_queries_requested_nearest,
		"Open-field Corn acquisition must reuse its target array and request only the nearest candidate."
	)
	_expect(
		is_same(ray_query_before, ray_query_after)
		and hit_result.get("collider") == enemy,
		"Acquisition LOS and firing must reuse one ray-query object without changing first-hit semantics."
	)
	_expect(
		ray_query_after.collision_mask == CornMachineGun.WORLD_AND_ENEMY_COLLISION_MASK
		and ray_query_after.exclude.size() == 1
		and ray_query_after.exclude[0] == tower.get_rid()
		and ray_query_after.collide_with_bodies
		and not ray_query_after.collide_with_areas,
		"The reused Corn ray query must retain its mask, exclusion and collision flags."
	)
	var source := FileAccess.get_file_as_string(
		"res://scene/plant_defense/corn_machine_gun.gd"
	)
	_expect(
		source.contains("query_combat_targets_into")
		and not source.contains("var candidate_values := current_scene.call"),
		"Corn acquisition must use the allocation-reusing combat query path."
	)
	_expect(
		source.contains("tracer.set_point_position")
		and not source.contains("tracer.points = PackedVector2Array"),
		"Six-shot tracers must update authored points instead of allocating a packed array per shot."
	)
	runtime.candidate = null
	enemy.queue_free()
	runtime.queue_free()
	await physics_frame


func _test_blocked_nearest_adaptive_selection(tower: CornMachineGun) -> void:
	var runtime := TargetRuntimeStub.new()
	runtime.name = "CornBlockedTargetRuntimeStub"
	fixture.add_child(runtime)
	var blocked_enemy := ENEMY_SCENE.instantiate() as Enemy
	var clear_enemy := ENEMY_SCENE.instantiate() as Enemy
	_expect(
		blocked_enemy != null and clear_enemy != null,
		"Blocked-target fixture must instantiate both candidate enemies."
	)
	if blocked_enemy == null or clear_enemy == null:
		for enemy in [blocked_enemy, clear_enemy]:
			if enemy != null:
				enemy.queue_free()
		runtime.queue_free()
		return
	for enemy in [blocked_enemy, clear_enemy]:
		fixture.add_child(enemy)
		enemy.set_process(false)
		enemy.set_physics_process(false)
		enemy.is_dead = false
		enemy.collision_layer = 4
		enemy.collision_mask = 0
	tower.global_position = Vector2(640.0, 384.0)
	var ray_origin := tower.aim_pivot.global_position
	blocked_enemy.global_position = ray_origin + Vector2(48.0, 0.0)
	clear_enemy.global_position = ray_origin + Vector2(0.0, 80.0)
	runtime.candidates.assign([blocked_enemy, clear_enemy])
	tower.set("_combat_runtime", runtime)

	var blocker := _create_hitscan_probe(&"AdaptiveSelectionWall", 1)
	blocker.global_position = ray_origin + Vector2(24.0, 0.0)
	var blocker_shape := blocker.get_child(0) as CollisionShape2D
	(blocker_shape.shape as RectangleShape2D).size = Vector2(12.0, 24.0)
	await physics_frame

	var selected := tower.call("_select_nearest_visible_enemy") as Enemy
	_expect(
		selected == clear_enemy,
		"Corn must skip a wall-blocked exact nearest target and retain the next-visible target."
	)
	_expect(
		runtime.query_call_count == 1
		and runtime.unordered_query_call_count == 1
		and runtime.all_queries_requested_nearest
		and runtime.reused_output_buffer,
		"Blocked Corn acquisition must reuse one output buffer and avoid a full ordered query."
	)

	blocker.queue_free()
	blocked_enemy.queue_free()
	clear_enemy.queue_free()
	runtime.queue_free()
	await physics_frame


func _test_hitscan_first_collision(tower: CornMachineGun) -> void:
	var wall := _create_hitscan_probe(&"WallProbe", 1)
	var first_enemy := _create_hitscan_probe(&"FirstEnemyProbe", 4)
	var rear_enemy := _create_hitscan_probe(&"RearEnemyProbe", 4)
	var ray_origin := tower.muzzle.global_position
	wall.global_position = ray_origin + Vector2(6.0, 0.0)
	first_enemy.global_position = ray_origin + Vector2(12.0, 0.0)
	rear_enemy.global_position = ray_origin + Vector2(18.0, 0.0)
	await physics_frame

	var blocked_result := tower.call("_cast_locked_hitscan", Vector2.RIGHT) as Dictionary
	_expect(
		blocked_result.get("collider") == wall,
		"mask5 Hitscan 必须把前方世界墙体作为第一碰撞并阻挡后方敌人。"
	)
	wall.queue_free()
	await physics_frame
	var enemy_result := tower.call("_cast_locked_hitscan", Vector2.RIGHT) as Dictionary
	_expect(
		enemy_result.get("collider") == first_enemy,
		"墙体移除后 Hitscan 必须只返回最近敌人碰撞，不能穿透到后方目标。"
	)
	first_enemy.queue_free()
	rear_enemy.queue_free()
	await physics_frame


func _create_hitscan_probe(probe_name: StringName, collision_layer: int) -> StaticBody2D:
	var body := StaticBody2D.new()
	body.name = probe_name
	body.collision_layer = collision_layer
	body.collision_mask = 0
	var collision := CollisionShape2D.new()
	var shape := RectangleShape2D.new()
	shape.size = Vector2(2.0, 8.0)
	collision.shape = shape
	body.add_child(collision)
	fixture.add_child(body)
	return body


func _test_shared_audio_limiter() -> void:
	var audio_root := Node2D.new()
	audio_root.name = "PlantAttackAudioLimiterFixture"
	fixture.add_child(audio_root)
	var players: Array[AudioStreamPlayer2D] = []
	var accepted_count := 0
	for index in range(AUDIO_LIMITER.MAX_SIMULTANEOUS_VOICES + 1):
		var player := AudioStreamPlayer2D.new()
		player.stream = FIRE_STREAM
		player.max_polyphony = 1
		audio_root.add_child(player)
		players.append(player)
		if AUDIO_LIMITER.play_burst(player, 0.01 if index == 0 else 0.0):
			accepted_count += 1
	_expect(accepted_count == 6, "共享植物攻击音频必须只接受前6个并发声部。")
	_expect(players[0].playing, "音频限制器必须支持从 elapsed 偏移开始播放。")
	_expect(not players.back().playing, "第7个并发植物攻击声部必须被拒绝。")
	_expect(
		AUDIO_LIMITER.get_active_voice_count(self) == 6,
		"活动植物攻击音频计数必须等于共享上限。"
	)

	var expired_player := AudioStreamPlayer2D.new()
	expired_player.stream = FIRE_STREAM
	expired_player.max_polyphony = 1
	audio_root.add_child(expired_player)
	_expect(
		not AUDIO_LIMITER.play_burst(expired_player, FIRE_STREAM.get_length()),
		"elapsed 超过音频长度时不得从头重播过期的一轮音效。"
	)
	for player in players:
		player.stop()
	_expect(
		AUDIO_LIMITER.get_active_voice_count(self) == 0,
		"停止的音频必须立即从共享声部计数中清理。"
	)

	var camera := Camera2D.new()
	camera.enabled = true
	audio_root.add_child(camera)
	for index in range(AUDIO_LIMITER.MAX_SIMULTANEOUS_VOICES):
		players[index].position = Vector2(600.0 - float(index) * 80.0, 0.0)
		players[index].max_distance = 800.0
		_expect(AUDIO_LIMITER.play_burst(players[index]), "镜头内声部必须可重新占用共享槽位。")
	var near_player := AudioStreamPlayer2D.new()
	near_player.stream = FIRE_STREAM
	near_player.max_polyphony = 1
	near_player.max_distance = 800.0
	near_player.position = Vector2(24.0, 0.0)
	audio_root.add_child(near_player)
	_expect(AUDIO_LIMITER.play_burst(near_player), "更近的植物攻击音效必须替换最远声部。")
	_expect(not players[0].playing, "空间优先级必须停止最远的植物攻击声部。")
	_expect(
		AUDIO_LIMITER.get_active_voice_count(self) == AUDIO_LIMITER.MAX_SIMULTANEOUS_VOICES,
		"空间替换后植物攻击音效仍必须严格遵守共享上限。"
	)
	var far_player := AudioStreamPlayer2D.new()
	far_player.stream = FIRE_STREAM
	far_player.max_polyphony = 1
	far_player.max_distance = 800.0
	far_player.position = Vector2(700.0, 0.0)
	audio_root.add_child(far_player)
	_expect(not AUDIO_LIMITER.play_burst(far_player), "更远的请求不得抢占镜头附近声部。")
	var inaudible_player := AudioStreamPlayer2D.new()
	inaudible_player.stream = FIRE_STREAM
	inaudible_player.max_polyphony = 1
	inaudible_player.max_distance = 100.0
	inaudible_player.position = Vector2(200.0, 0.0)
	audio_root.add_child(inaudible_player)
	_expect(not AUDIO_LIMITER.play_burst(inaudible_player), "max_distance 外的植物攻击音效不得占槽。")
	audio_root.queue_free()


func _stop_fixture_audio(node: Node) -> void:
	if node is AudioStreamPlayer2D:
		(node as AudioStreamPlayer2D).stop()
	for child in node.get_children():
		_stop_fixture_audio(child)


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
