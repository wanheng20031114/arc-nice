extends SceneTree

const NINJA_SCENE := preload(
	"res://scene/enemy/mechanical_life/combat_robot_ninja.tscn"
)
const NINJA_CONFIG := preload(
	"res://resources/config/enemies/combat_robot_ninja.tres"
)
const PLAYER_SCENE := preload(
	"res://scene/player/weishidaier/player_weishidaier.tscn"
)
const ENEMY_ATTACK_AUDIO_LIMITER := preload(
	"res://scene/combat/audio/enemy_attack_audio_limiter.gd"
)
const BOOST_STATUS_MASK := 1 << 5


class EnemyActionRecorder:
	extends MultiplayerGameplayGateway

	var enemy_actions: Array[Dictionary] = []
	var damage_target: Player = null


	func broadcast_enemy_action(
		net_id: int,
		action_name: StringName,
		direction: Vector2,
		action_position: Vector2,
		action_id: int
	) -> void:
		enemy_actions.append({
			"net_id": net_id,
			"action_name": action_name,
			"direction": direction,
			"action_position": action_position,
			"action_id": action_id,
		})


	func request_player_damage(
		_source_id: int,
		target_peer_id: int,
		damage: int,
		_source_type: StringName,
		damage_type: EnemyConfig.DamageType = EnemyConfig.DamageType.PHYSICAL,
		_source_direction: Vector2 = Vector2.ZERO,
		_is_ranged: bool = false,
		_contact_preconsumed: bool = false
	) -> bool:
		if (
			damage_target == null
			or not is_instance_valid(damage_target)
			or damage_target.peer_id != target_peer_id
		):
			return false
		return damage_target.apply_damage(damage, damage_type)


var failures: Array[String] = []
var test_root: EnemyActionRecorder


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	test_root = EnemyActionRecorder.new()
	test_root.name = "CombatRobotNinjaSmokeTest"
	root.add_child(test_root)
	current_scene = test_root

	_test_resource_and_scene_contract()
	await _test_authoritative_damage_boost_contract()
	await _test_batch_and_status_tick_damage_contract()
	await _test_real_touch_area_and_blade_collision_contract()
	await _test_rejected_lethal_and_proxy_damage_contract()
	await _test_proxy_action_and_snapshot_contract()
	await _test_lifecycle_cleanup_contract()

	current_scene = null
	test_root.queue_free()
	await process_frame
	await physics_frame
	for _cleanup_frame in range(3):
		await process_frame

	if failures.is_empty():
		print("COMBAT_ROBOT_NINJA_SMOKE_TEST_OK")
		quit()
		return
	for failure in failures:
		push_error(failure)
	quit(1)


func _test_resource_and_scene_contract() -> void:
	_expect(
		NINJA_CONFIG is CombatRobotNinjaConfig,
		"忍者机器人必须使用 CombatRobotNinjaConfig。"
	)
	_expect(
		NINJA_CONFIG.display_name == "忍者战斗机器人"
		and NINJA_CONFIG.enemy_scene == NINJA_SCENE,
		"忍者机器人的显示名和场景绑定必须稳定。"
	)
	_expect(
		NINJA_CONFIG.max_health == 180
		and NINJA_CONFIG.attack_damage == 35
		and NINJA_CONFIG.physical_defense == 10
		and NINJA_CONFIG.magic_defense == 15
		and is_equal_approx(NINJA_CONFIG.move_speed, 80.0)
		and NINJA_CONFIG.home_damage == 2
		and NINJA_CONFIG.xirang_kill_reward == 10,
		"忍者机器人基础属性必须为180/35/10/15/80/2/10。"
	)
	_expect(
		NINJA_CONFIG.category_tags
		== PackedStringArray(["mechanical_life"]),
		"忍者机器人只能属于机械生命。"
	)
	_expect(
		NINJA_CONFIG.drop_table != null
		and NINJA_CONFIG.drop_table.resource_path.ends_with(
			"default_enemy_drop_table.tres"
		),
		"忍者机器人必须继续使用完整通用掉落表。"
	)
	_expect(
		NINJA_CONFIG.boost_animation_name == &"boost"
		and is_equal_approx(NINJA_CONFIG.boost_speed_multiplier, 2.0)
		and is_equal_approx(NINJA_CONFIG.boost_duration, 0.5)
		and is_equal_approx(NINJA_CONFIG.boost_cooldown, 3.0),
		"受击加速参数必须为2倍、0.5秒、3秒冷却。"
	)

	var ninja := NINJA_SCENE.instantiate() as CombatRobotNinja
	_expect(ninja != null, "忍者机器人场景必须实例化强类型本体。")
	if ninja == null:
		return
	var sprite := ninja.get_node_or_null("AnimatedSprite2D") as AnimatedSprite2D
	var body_shapes := _collect_direct_collision_shapes(ninja)
	var touch_area := ninja.get_node_or_null("TouchDamageArea") as Area2D
	var touch_shapes := _collect_direct_collision_shapes(touch_area)
	var boost_timer_node := ninja.get_node_or_null("BoostTimer") as Timer
	var cooldown_timer_node := ninja.get_node_or_null("CooldownTimer") as Timer
	var slash_audio_node := ninja.get_node_or_null(
		"SlashAudio"
	) as AudioStreamPlayer2D
	_expect(
		sprite != null
		and sprite.sprite_frames != null
		and sprite.sprite_frames.has_animation(&"move")
		and sprite.sprite_frames.has_animation(&"boost")
		and sprite.sprite_frames.has_animation(&"death")
		and sprite.sprite_frames.get_frame_count(&"move") == 8
		and sprite.sprite_frames.get_frame_count(&"boost") == 8
		and sprite.sprite_frames.get_frame_count(&"death") == 8,
		"运行时必须预置move/boost/death三组八帧动画。"
	)
	_expect(
		body_shapes.size() == 1
		and body_shapes[0].shape is RectangleShape2D
		and (body_shapes[0].shape as RectangleShape2D).size == Vector2(8, 17),
		"世界碰撞只能包含8×17方盒身体，双刃不得加入世界碰撞。"
	)
	_expect(
		touch_shapes.size() == 5
		and touch_shapes[0].shape is RectangleShape2D
		and (touch_shapes[0].shape as RectangleShape2D).size == Vector2(8, 17),
		"接触区必须包含8×17身体和两套预置双刃。"
	)
	if touch_shapes.size() == 5:
		for blade_index in range(1, 5):
			_expect(
				touch_shapes[blade_index].shape is ConvexPolygonShape2D,
				"四个刀刃接触形状必须全部使用凸多边形。"
			)
		_expect(
			not touch_shapes[1].disabled
			and not touch_shapes[2].disabled
			and touch_shapes[3].disabled
			and touch_shapes[4].disabled,
			"出生时只能启用M1移动双刃接触形状。"
		)
	_expect(
		boost_timer_node != null
		and cooldown_timer_node != null
		and boost_timer_node.process_callback == Timer.TIMER_PROCESS_PHYSICS
		and cooldown_timer_node.process_callback == Timer.TIMER_PROCESS_PHYSICS
		and boost_timer_node.one_shot
		and cooldown_timer_node.one_shot,
		"加速与冷却必须由预置的物理帧one-shot Timer驱动。"
	)
	_expect(
		slash_audio_node != null
		and slash_audio_node.stream == NINJA_CONFIG.boost_audio_stream
		and slash_audio_node.bus == &"SFX"
		and slash_audio_node.volume_db <= -18.0
		and slash_audio_node.max_polyphony == 1,
		"受击加速必须预置低音量、单复音的SFX挥刀音频。"
	)
	_expect(
		bool(ninja.call("_uses_inherited_touch_damage"))
		and int(ninja.call("_get_touch_damage_type"))
		== EnemyConfig.DamageType.PHYSICAL,
		"忍者机器人必须沿用35点物理接触伤害。"
	)
	ninja.free()


func _test_authoritative_damage_boost_contract() -> void:
	test_root.enemy_actions.clear()
	var ninja := _spawn_ninja(false)
	ninja.set_meta("net_id", 7101)
	ninja.animated_sprite.set_frame_and_progress(3, 0.25)
	ninja.add_move_speed_modifier(7102, 0.5)
	_expect(
		is_equal_approx(ninja.get_effective_move_speed(), 40.0),
		"已有0.5倍减速必须先把80基础移速降至40。"
	)

	var accepted := _apply_damage_without_hit_flash(
		ninja,
		11,
		Vector2.LEFT
	)
	_expect(accepted, "非致死实际扣血必须被伤害入口接受。")
	_expect(
		ninja.is_damage_boost_active()
		and ninja.is_damage_boost_on_cooldown()
		and is_equal_approx(ninja.get_effective_move_speed(), 80.0),
		"受击同帧必须把当前有效移速动态乘2并立即开始冷却。"
	)
	_expect(
		ninja.animated_sprite.animation == &"boost"
		and ninja.animated_sprite.frame == 3
		and is_equal_approx(ninja.animated_sprite.frame_progress, 0.25),
		"move切换boost必须保留帧号与frame_progress。"
	)
	_expect(
		ninja.boost_timer.time_left > 0.45
		and ninja.boost_timer.time_left <= 0.5
		and ninja.cooldown_timer.time_left > 2.9
		and ninja.cooldown_timer.time_left <= 3.0,
		"0.5秒持续与3秒冷却必须在同一触发帧开始。"
	)
	_expect(
		(ninja.get_collectible_visual_status_mask() & BOOST_STATUS_MASK) != 0
		and ninja.animated_sprite.material != null,
		"权威加速必须写入bit5快照并附加共享状态材质。"
	)
	_expect(
		test_root.enemy_actions.size() == 1
		and StringName(test_root.enemy_actions[0]["action_name"])
		== &"combat_robot_ninja_boost"
		and int(test_root.enemy_actions[0]["action_id"]) == 1,
		"首次受击加速必须广播唯一、有序的boost动作。"
	)

	var boost_time_before_second_hit := ninja.boost_timer.time_left
	var cooldown_time_before_second_hit := ninja.cooldown_timer.time_left
	_apply_damage_without_hit_flash(
		ninja,
		11,
		Vector2.RIGHT
	)
	_expect(
		test_root.enemy_actions.size() == 1
		and is_equal_approx(
			ninja.boost_timer.time_left,
			boost_time_before_second_hit
		)
		and is_equal_approx(
			ninja.cooldown_timer.time_left,
			cooldown_time_before_second_hit
		),
		"加速或冷却期间的再次受击不得刷新、排队或广播。"
	)

	ninja.remove_move_speed_modifier(7102)
	_expect(
		is_equal_approx(ninja.get_effective_move_speed(), 160.0),
		"加速期间移除减速后必须实时恢复到80×2。"
	)
	ninja.add_move_speed_modifier(7102, 0.5)
	var boost_frame := ninja.animated_sprite.frame
	var boost_progress := ninja.animated_sprite.frame_progress
	ninja.call("_on_boost_timer_timeout")
	_expect(
		not ninja.is_damage_boost_active()
		and ninja.is_damage_boost_on_cooldown()
		and is_equal_approx(ninja.get_effective_move_speed(), 40.0),
		"0.5秒结束只能取消2倍速，3秒冷却仍须继续。"
	)
	_expect(
		ninja.animated_sprite.animation == &"move"
		and ninja.animated_sprite.frame == boost_frame
		and is_equal_approx(
			ninja.animated_sprite.frame_progress,
			boost_progress
		),
		"boost切回move必须保留腿部动画相位。"
	)
	_expect(
		(ninja.get_collectible_visual_status_mask() & BOOST_STATUS_MASK) == 0
		and ninja.animated_sprite.material != null,
		"加速结束必须清bit5，但已有寒冷视觉仍须保活共享材质。"
	)
	ninja.remove_move_speed_modifier(7102)
	_expect(
		is_equal_approx(ninja.get_effective_move_speed(), 80.0)
		and ninja.animated_sprite.material == null,
		"最后一个视觉效果结束后必须释放共享材质绑定。"
	)

	var actions_before_cooldown_hit := test_root.enemy_actions.size()
	_apply_damage_without_hit_flash(
		ninja,
		11,
		Vector2.ZERO
	)
	_expect(
		test_root.enemy_actions.size() == actions_before_cooldown_hit
		and not ninja.is_damage_boost_active(),
		"冷却中的实际扣血不得再次启动加速。"
	)
	ninja.call("_on_cooldown_timer_timeout")
	_apply_damage_without_hit_flash(
		ninja,
		11,
		Vector2.ZERO
	)
	_expect(
		ninja.is_damage_boost_active()
		and test_root.enemy_actions.size() == actions_before_cooldown_hit + 1
		and int(test_root.enemy_actions[-1]["action_id"]) == 2,
		"3秒冷却结束后的下一次实际扣血必须正常触发第二次加速。"
	)

	await physics_frame
	_expect(
		ninja.move_rear_blade_shape.disabled
		and ninja.move_front_blade_shape.disabled
		and not ninja.boost_upper_blade_shape.disabled
		and not ninja.boost_lower_blade_shape.disabled,
		"S1加速期间必须只启用后掠双刃接触形状。"
	)
	ninja.call("_update_facing", Vector2.LEFT)
	_expect(
		ninja.facing_left
		and ninja.boost_upper_blade_shape.position.x > 0.0
		and ninja.boost_upper_blade_shape.rotation < 0.0,
		"左向时后掠凸多边形必须同时镜像位置和倾角。"
	)
	ninja.queue_free()
	await process_frame


func _test_batch_and_status_tick_damage_contract() -> void:
	test_root.enemy_actions.clear()
	var batched_ninja := _spawn_ninja(false)
	batched_ninja.set_physics_process(false)
	var batch_health_before := batched_ninja.current_health
	var batch_revision_before := batched_ninja.health_revision
	var batch_accepted := batched_ninja.apply_damage_batch(
		PackedInt64Array([20, 15]),
		PackedInt32Array([2, 1]),
		Vector2.RIGHT,
		EnemyConfig.DamageType.PHYSICAL,
		false
	)
	_expect(
		batch_accepted
		and batched_ninja.current_health == batch_health_before - 25
		and batched_ninja.health_revision == batch_revision_before + 1
		and batched_ninja.last_damage_result.accepted_hit_count == 3,
		"一次三击批伤必须统一结算25点实际伤害并只推进一次生命修订。"
	)
	_expect(
		batched_ninja.is_damage_boost_active()
		and test_root.enemy_actions.size() == 1,
		"apply_damage_batch即使聚合三次命中，也只能触发并广播一次受击加速。"
	)
	var batch_boost_time_left := batched_ninja.boost_timer.time_left
	var batch_cooldown_time_left := batched_ninja.cooldown_timer.time_left
	batched_ninja.apply_damage_batch(
		PackedInt64Array([20]),
		PackedInt32Array([2]),
		Vector2.LEFT,
		EnemyConfig.DamageType.PHYSICAL,
		false
	)
	_expect(
		test_root.enemy_actions.size() == 1
		and is_equal_approx(
			batched_ninja.boost_timer.time_left,
			batch_boost_time_left
		)
		and is_equal_approx(
			batched_ninja.cooldown_timer.time_left,
			batch_cooldown_time_left
		),
		"加速/冷却期间再次接受批伤不得刷新Timer、排队或追加动作。"
	)
	batched_ninja.queue_free()
	await process_frame

	var scheduler := root.get_node_or_null(
		"EnemyCollectibleStatusScheduler"
	)
	_expect(scheduler != null, "真实DoT验收需要全局状态截止调度器。")
	if scheduler == null:
		return
	scheduler.call("clear_all")
	test_root.enemy_actions.clear()
	var status_ninja := _spawn_ninja(false)
	status_ninja.set_physics_process(false)
	var status_health_before := status_ninja.current_health
	status_ninja.apply_collectible_status(
		&"bleed",
		73101,
		1.1,
		20,
		0.5,
		EnemyConfig.DamageType.PHYSICAL
	)
	_expect(
		not status_ninja.is_damage_boost_active()
		and test_root.enemy_actions.is_empty(),
		"仅施加流血状态不得提前触发受击加速。"
	)
	scheduler.call("advance_for_test", 0.5)
	_expect(
		status_ninja.current_health == status_health_before - 10
		and status_ninja.is_damage_boost_active()
		and status_ninja.is_damage_boost_on_cooldown()
		and test_root.enemy_actions.size() == 1,
		"一次真实流血tick必须通过统一伤害入口扣除物防后的10点并触发一次boost。"
	)
	var status_boost_time_left := status_ninja.boost_timer.time_left
	var status_cooldown_time_left := status_ninja.cooldown_timer.time_left
	scheduler.call("advance_for_test", 0.5)
	_expect(
		status_ninja.current_health == status_health_before - 20
		and test_root.enemy_actions.size() == 1
		and is_equal_approx(
			status_ninja.boost_timer.time_left,
			status_boost_time_left
		)
		and is_equal_approx(
			status_ninja.cooldown_timer.time_left,
			status_cooldown_time_left
		),
		"加速/冷却期间的后续真实DoT tick必须正常扣血但不得刷新或再次广播boost。"
	)
	status_ninja.queue_free()
	await process_frame
	scheduler.call("clear_all")


func _test_real_touch_area_and_blade_collision_contract() -> void:
	test_root.enemy_actions.clear()
	var ninja := _spawn_ninja(false)
	ninja.set_physics_process(false)
	ninja.global_position = Vector2.ZERO
	var player := _spawn_contact_player(Vector2(512.0, 0.0))
	var entered_shape_indices: Array[int] = []
	var exited_shape_indices: Array[int] = []
	ninja.touch_damage_area.body_shape_entered.connect(
		func(
			_body_rid: RID,
			body: Node2D,
			_body_shape_index: int,
			local_shape_index: int
		) -> void:
			if body == player and not entered_shape_indices.has(local_shape_index):
				entered_shape_indices.append(local_shape_index)
	)
	ninja.touch_damage_area.body_shape_exited.connect(
		func(
			_body_rid: RID,
			body: Node2D,
			_body_shape_index: int,
			local_shape_index: int
		) -> void:
			if body == player and not exited_shape_indices.has(local_shape_index):
				exited_shape_indices.append(local_shape_index)
	)
	await physics_frame
	var player_health_before := player.current_health
	player.global_position = Vector2.ZERO
	await _wait_physics_frames(4)
	_expect(
		ninja.touch_damage_area.overlaps_body(player)
		and ninja.touching_players.size() == 1
		and entered_shape_indices.has(0)
		and entered_shape_indices.has(1)
		and entered_shape_indices.has(2),
		"真实Player夹具必须同时进入身体与M1双刃，但TouchDamageArea只登记一个目标。"
	)
	_expect(
		player.last_damage_result != null
		and player.last_damage_result.applied_damage == 35
		and player.current_health == player_health_before - 35,
		"身体与双刃同时覆盖同一Player时必须只结算一次35点接触伤害。"
	)

	# 左移少量，让同一个Player同时覆盖身体、M1后刃和两把S1后掠刃；
	# 这样shape切换的离开/进入信号都来自真实窄刃几何，而非直接调用回调。
	player.global_position = Vector2(-6.0, 1.5)
	await _wait_physics_frames(2)
	entered_shape_indices.clear()
	exited_shape_indices.clear()
	var player_health_after_move_contact := player.current_health
	ninja.apply_damage(
		11,
		Vector2.RIGHT,
		EnemyConfig.DamageType.PHYSICAL,
		false
	)
	await _wait_physics_frames(3)
	_expect(
		ninja.move_rear_blade_shape.disabled
		and ninja.move_front_blade_shape.disabled
		and not ninja.boost_upper_blade_shape.disabled
		and not ninja.boost_lower_blade_shape.disabled
		and exited_shape_indices.has(1)
		and entered_shape_indices.has(3)
		and entered_shape_indices.has(4),
		"真实TouchDamageArea必须在boost时退出M1双刃并进入S1后掠双刃；entered=%s exited=%s。"
		% [entered_shape_indices, exited_shape_indices]
	)
	_expect(
		ninja.touching_players.size() == 1
		and player.current_health == player_health_after_move_contact,
		"切换四个刀刃shape不得重复登记目标或绕过0.5秒接触冷却。"
	)
	ninja.call("_on_boost_timer_timeout")
	await _wait_physics_frames(3)
	_expect(
		not ninja.move_rear_blade_shape.disabled
		and not ninja.move_front_blade_shape.disabled
		and ninja.boost_upper_blade_shape.disabled
		and ninja.boost_lower_blade_shape.disabled,
		"boost结束后必须在物理帧安全恢复M1双刃碰撞形状。"
	)

	player.global_position = Vector2(512.0, 0.0)
	await _wait_physics_frames(3)
	var wall := StaticBody2D.new()
	wall.name = "NinjaBladeWorldCollisionProbe"
	wall.collision_layer = 1
	wall.collision_mask = 0
	var wall_shape := CollisionShape2D.new()
	var wall_rectangle := RectangleShape2D.new()
	wall_rectangle.size = Vector2(2.0, 64.0)
	wall_shape.shape = wall_rectangle
	wall.add_child(wall_shape)
	test_root.add_child(wall)
	wall.global_position = Vector2(20.0, 0.0)
	ninja.global_position = Vector2.ZERO
	await _wait_physics_frames(2)
	var wall_collision := ninja.move_and_collide(Vector2.RIGHT * 30.0)
	_expect(
		wall_collision != null
		and ninja.global_position.x > 10.0
		and ninja.global_position.x < 16.0,
		"双刃不得参与World碰撞：本体应穿过刀尖触墙位置，直到8像素宽身体撞上墙。"
	)

	wall.queue_free()
	player.queue_free()
	ninja.queue_free()
	await physics_frame
	await process_frame


func _test_rejected_lethal_and_proxy_damage_contract() -> void:
	test_root.enemy_actions.clear()
	var rejected_ninja := _spawn_ninja(false)
	var rejected_result := rejected_ninja.apply_combat_damage(null)
	_expect(
		not rejected_result.accepted
		and not rejected_ninja.is_damage_boost_active()
		and test_root.enemy_actions.is_empty(),
		"无效伤害请求不得触发受击加速。"
	)
	rejected_ninja.queue_free()
	await process_frame

	var lethal_ninja := _spawn_ninja(false)
	lethal_ninja.apply_damage(
		9999,
		Vector2.LEFT,
		EnemyConfig.DamageType.PHYSICAL,
		false
	)
	_expect(
		lethal_ninja.is_dead
		and not lethal_ninja.is_damage_boost_active()
		and lethal_ninja.boost_timer.is_stopped(),
		"致死伤害必须直接进入死亡并保持加速Timer停止。"
	)
	lethal_ninja.queue_free()
	await process_frame

	var proxy := _spawn_ninja(true)
	var proxy_result := proxy.apply_combat_damage(
		DamageRequest.new(999, EnemyConfig.DamageType.PHYSICAL)
	)
	_expect(
		not proxy_result.accepted
		and not proxy.is_damage_boost_active(),
		"多人代理端拒绝的伤害不得启动加速。"
	)
	proxy.queue_free()
	await process_frame


func _test_proxy_action_and_snapshot_contract() -> void:
	ENEMY_ATTACK_AUDIO_LIMITER.reset_metrics()
	var proxy := _spawn_ninja(true)
	await physics_frame
	_expect(
		proxy.is_multiplayer_proxy
		and _all_blade_shapes_disabled(proxy),
		"代理端必须禁用全部接触刀刃且不参与伤害。"
	)

	proxy.velocity = Vector2(60.0, 80.0)
	proxy.apply_multiplayer_visual_status_mask(BOOST_STATUS_MASK)
	var snapshot_afterimage_direction: Vector2 = (
		proxy.animated_sprite.get_instance_shader_parameter(
			&"ninja_afterimage_direction"
		)
	)
	_expect(
		proxy.is_damage_boost_active()
		and proxy.animated_sprite.animation == &"boost"
		and proxy.animated_sprite.is_playing()
		and proxy.animated_sprite.material != null
		and snapshot_afterimage_direction.is_equal_approx(Vector2(0.6, 0.8))
		and int(
			ENEMY_ATTACK_AUDIO_LIMITER.get_metrics()[&"heavy_requests"]
		) == 0,
		"bit5快照必须在动作丢失时按代理真实斜向速度恢复加速表现。"
	)
	var snapshot_time_left := proxy.boost_timer.time_left
	proxy.apply_multiplayer_visual_status_mask(BOOST_STATUS_MASK)
	_expect(
		is_equal_approx(proxy.boost_timer.time_left, snapshot_time_left),
		"重复的活跃快照不得刷新0.5秒表现兜底。"
	)
	proxy.set_multiplayer_proxy_visual_active(false)
	_expect(
		proxy.is_damage_boost_active()
		and proxy.animated_sprite.material == null,
		"离屏代理必须保留逻辑状态但释放尾影材质。"
	)
	proxy.set_multiplayer_proxy_visual_active(true)
	_expect(
		proxy.animated_sprite.material != null,
		"代理重新可见时必须恢复仍在持续的尾影。"
	)
	proxy.call("_on_boost_timer_timeout")
	_expect(
		not proxy.is_damage_boost_active(),
		"快照兜底计时结束后必须关闭本地尾影。"
	)
	proxy.apply_multiplayer_visual_status_mask(BOOST_STATUS_MASK)
	_expect(
		not proxy.is_damage_boost_active(),
		"同一轮仍为bit5=1的旧快照不得重新启动或延长尾影。"
	)
	proxy.apply_multiplayer_visual_status_mask(0)
	_expect(
		not proxy.is_damage_boost_active()
		and proxy.animated_sprite.animation == &"move",
		"bit5清除必须解锁下一次快照上升沿并保持move。"
	)
	proxy.apply_multiplayer_visual_status_mask(BOOST_STATUS_MASK)
	_expect(
		proxy.is_damage_boost_active(),
		"明确观察到bit5=0后，下一次bit5上升沿必须能恢复新一轮尾影。"
	)
	proxy.apply_multiplayer_visual_status_mask(0)

	proxy.play_multiplayer_enemy_action_with_context(
		&"combat_robot_ninja_boost",
		Vector2(0.6, 0.8),
		Vector2.ZERO,
		7,
		0.2
	)
	_expect(
		proxy.is_damage_boost_active()
		and proxy.latest_proxy_action_id == 7
		and proxy.animated_sprite.animation == &"boost"
		and proxy.animated_sprite.is_playing()
		and proxy.animated_sprite.frame == 4
		and is_equal_approx(proxy.animated_sprite.frame_progress, 0.8)
		and proxy.boost_timer.time_left > 0.29
		and proxy.boost_timer.time_left <= 0.3
		and int(
			ENEMY_ATTACK_AUDIO_LIMITER.get_metrics()[&"heavy_requests"]
		) == 1,
		"代理动作必须按elapsed补播到S1的正确帧并只保留剩余时长。"
	)
	var action_time_left := proxy.boost_timer.time_left
	proxy.apply_multiplayer_visual_status_mask(0)
	_expect(
		proxy.is_damage_boost_active()
		and is_equal_approx(proxy.boost_timer.time_left, action_time_left),
		"动作后迟到的触发前bit5=0快照不得提前取消elapsed校正的尾影。"
	)
	proxy.play_multiplayer_enemy_action_with_context(
		&"combat_robot_ninja_boost",
		Vector2.LEFT,
		Vector2.ZERO,
		7,
		0.0
	)
	_expect(
		is_equal_approx(proxy.boost_timer.time_left, action_time_left),
		"重复action_id不得刷新代理动作。"
	)
	proxy.apply_multiplayer_proxy_motion(
		Vector2(8, 9),
		Vector2.LEFT * 160.0,
		Enemy.LocomotionState.MOVING
	)
	_expect(
		proxy.global_position == Vector2(8, 9)
		and proxy.facing_left
		and proxy.animated_sprite.animation == &"boost",
		"加速代理必须继续消费位置/速度快照且不能被move覆盖。"
	)
	proxy.call("_on_boost_timer_timeout")
	_expect(
		not proxy.is_damage_boost_active()
		and proxy.animated_sprite.animation == &"move",
		"动作源尾影必须由自己的剩余Timer正常结束。"
	)
	proxy.play_multiplayer_enemy_action_with_context(
		&"combat_robot_ninja_boost",
		Vector2.RIGHT,
		Vector2.ZERO,
		8,
		0.6
	)
	_expect(
		not proxy.is_damage_boost_active()
		and proxy.latest_proxy_action_id == 8
		and proxy.animated_sprite.animation == &"move"
		and int(
			ENEMY_ATTACK_AUDIO_LIMITER.get_metrics()[&"heavy_requests"]
		) == 1,
		"已过0.5秒的迟包必须只推进序号并立即恢复move。"
	)
	proxy.apply_multiplayer_visual_status_mask(BOOST_STATUS_MASK)
	_expect(
		not proxy.is_damage_boost_active(),
		"动作已结束后迟到的同轮bit5=1快照不得重新启动完整尾影。"
	)
	proxy.apply_multiplayer_visual_status_mask(0)
	proxy.queue_free()
	await process_frame


func _test_lifecycle_cleanup_contract() -> void:
	var ninja := _spawn_ninja(false)
	ninja.apply_damage(
		11,
		Vector2.ZERO,
		EnemyConfig.DamageType.PHYSICAL,
		false
	)
	_expect(
		ninja.is_damage_boost_active()
		and ninja.animated_sprite.material != null,
		"清理测试前必须同时启动加速与真实受击闪白。"
	)
	var ninja_reference: WeakRef = weakref(ninja)
	var removed := ninja.remove_for_home_escape()
	_expect(
		removed
		and ninja.is_dead
		and not ninja.is_damage_boost_active()
		and ninja.boost_timer.is_stopped()
		and ninja.cooldown_timer.is_stopped()
		and not ninja.visible
		and ninja.is_queued_for_deletion(),
		"进入基地必须停止Timer与动作、隐藏本体并排队释放。"
	)
	await process_frame
	_expect(
		ninja_reference.get_ref() == null,
		"进入基地后的下一帧必须完成本体与受击闪白材质清理。"
	)


func _apply_damage_without_hit_flash(
	ninja: CombatRobotNinja,
	amount: int,
	impact_direction: Vector2
) -> bool:
	var request := DamageRequest.new(amount, CombatTypes.DamageType.PHYSICAL)
	request.with_directions(impact_direction)
	request.with_flag(CombatTypes.DamageFlag.SUPPRESS_HIT_FLASH)
	return ninja.apply_combat_damage(request).accepted


func _spawn_ninja(proxy: bool) -> CombatRobotNinja:
	var ninja := NINJA_SCENE.instantiate() as CombatRobotNinja
	test_root.add_child(ninja)
	ninja.setup(NINJA_CONFIG, null, null)
	ninja.bind_gameplay_gateway(test_root)
	if proxy:
		ninja.configure_multiplayer_proxy()
	return ninja


func _spawn_contact_player(spawn_position: Vector2) -> Player:
	var player := PLAYER_SCENE.instantiate() as Player
	player.global_position = spawn_position
	test_root.add_child(player)
	player.invincibility_duration = 0.0
	player.invincibility_time_left = 0.0
	player.set("_base_max_health", 100000)
	player.max_health = 100000
	player.current_health = 100000
	player.health_bar.setup(player.max_health, player.current_health)
	player.set_physics_process(false)
	player.set_process(false)
	test_root.damage_target = player
	return player


func _wait_physics_frames(frame_count: int) -> void:
	for _frame_index in range(maxi(frame_count, 0)):
		await physics_frame


func _collect_direct_collision_shapes(parent: Node) -> Array[CollisionShape2D]:
	var result: Array[CollisionShape2D] = []
	if parent == null:
		return result
	for child in parent.get_children():
		var shape_node := child as CollisionShape2D
		if shape_node != null:
			result.append(shape_node)
	return result


func _all_blade_shapes_disabled(ninja: CombatRobotNinja) -> bool:
	return (
		ninja.move_rear_blade_shape.disabled
		and ninja.move_front_blade_shape.disabled
		and ninja.boost_upper_blade_shape.disabled
		and ninja.boost_lower_blade_shape.disabled
	)


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
