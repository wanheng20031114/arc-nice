extends SceneTree

const FIRE_SORCERER_SCENE := preload(
	"res://scene/enemy/fire_sorcerer.tscn"
)
const FIRE_SORCERER_CONFIG := preload(
	"res://resources/config/enemies/fire_sorcerer.tres"
)

var failures: Array[String] = []
var test_root: Node2D = null


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	test_root = Node2D.new()
	test_root.name = "RangedEnemyIdleAnimationSmokeTest"
	root.add_child(test_root)
	current_scene = test_root

	_test_authoritative_hold_animation_transitions()
	_test_low_speed_retarget_transition()
	_test_multiplayer_proxy_motion_and_action_restore()

	current_scene = null
	test_root.queue_free()
	await process_frame
	await physics_frame

	if failures.is_empty():
		print("RANGED_ENEMY_IDLE_ANIMATION_SMOKE_TEST_OK")
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	quit(1)


func _test_authoritative_hold_animation_transitions() -> void:
	var enemy := _spawn_fire_sorcerer()
	var sprite := enemy.animated_sprite
	var authored_speed := sprite.speed_scale

	enemy.call("_play_scene_animation", FIRE_SORCERER_CONFIG.move_animation_name)
	sprite.set_frame_and_progress(2, 0.5)
	enemy.call("_set_ranged_attack_position_held", true)
	_expect(
		sprite.animation == FIRE_SORCERER_CONFIG.move_animation_name
		and sprite.frame == 0
		and is_zero_approx(sprite.frame_progress)
		and not sprite.is_playing()
		and is_zero_approx(sprite.get_playing_speed()),
		"权威端进入远程攻击站位时必须在move第0帧冻结，而不是原地走路。"
	)
	_expect(
		is_equal_approx(sprite.speed_scale, authored_speed),
		"站立冻结必须保留资源的动画速度，不能占用speed_scale的可见性裁剪语义。"
	)

	enemy.call("_set_ranged_attack_position_held", false)
	_expect(
		sprite.animation == FIRE_SORCERER_CONFIG.move_animation_name
		and sprite.is_playing()
		and sprite.get_playing_speed() > 0.0,
		"权威端离开远程攻击站位时必须恢复move循环。"
	)

	enemy.call("_play_scene_animation", FIRE_SORCERER_CONFIG.windup_animation_name)
	enemy.call("_set_ranged_attack_position_held", true)
	_expect(
		sprite.animation == FIRE_SORCERER_CONFIG.windup_animation_name
		and sprite.is_playing(),
		"进入站位不能冻结或替换正在播放的前摇动画。"
	)
	enemy.call("_play_scene_animation", FIRE_SORCERER_CONFIG.attack_animation_name)
	_expect(
		sprite.animation == FIRE_SORCERER_CONFIG.attack_animation_name
		and sprite.is_playing(),
		"站位中的攻击动画必须保持正常播放。"
	)
	enemy.call("_play_scene_animation", &"death")
	_expect(
		sprite.animation == &"death" and sprite.is_playing(),
		"站位状态不能影响死亡动画。"
	)

	# Attack completion restores move while the target is still in range. The
	# common animation entry point must freeze immediately, without waiting for a
	# later physics-frame poll.
	enemy.call("_play_scene_animation", FIRE_SORCERER_CONFIG.move_animation_name)
	_expect(
		sprite.animation == FIRE_SORCERER_CONFIG.move_animation_name
		and sprite.frame == 0
		and not sprite.is_playing(),
		"攻击结束后在站位中恢复move时必须立即回到静止第0帧。"
	)
	enemy.call("_set_ranged_attack_position_held", false)
	_expect(sprite.is_playing(), "站位解除后，攻击结束留下的静止move必须重新播放。")
	enemy.queue_free()


func _test_low_speed_retarget_transition() -> void:
	var enemy := _spawn_fire_sorcerer()
	var sprite := enemy.animated_sprite
	var next_objective := Node2D.new()
	test_root.add_child(next_objective)

	enemy.call("_play_scene_animation", FIRE_SORCERER_CONFIG.move_animation_name)
	enemy.call("_set_ranged_attack_position_held", true)
	_expect(
		is_zero_approx(sprite.get_playing_speed()),
		"低速回归前置条件必须先让远程敌人进入驻足状态。"
	)

	# Target replacement is the real transition out of a ranged hold. It must go
	# through the same state boundary as the combat loop, otherwise a paused move
	# frame survives and merely slides once movement resumes.
	enemy.set_objective_target(next_objective)
	enemy.velocity = Vector2.RIGHT * 0.01
	_expect(
		enemy.get_locomotion_state() == Enemy.LocomotionState.MOVING
		and sprite.animation == FIRE_SORCERER_CONFIG.move_animation_name
		and sprite.is_playing()
		and sprite.get_playing_speed() > 0.0,
		"目标切换后即使速度只有0.01，move动画也必须恢复推进。"
	)

	sprite.set_frame_and_progress(2, 0.5)
	enemy.set_objective_target(next_objective)
	_expect(
		sprite.frame == 2
		and is_equal_approx(sprite.frame_progress, 0.5)
		and sprite.get_playing_speed() > 0.0,
		"重复提交相同目标不能重播或重置正在推进的低速move动画。"
	)
	enemy.is_dead = true
	_expect(
		enemy.get_locomotion_state() == Enemy.LocomotionState.IDLE,
		"死亡必须高于残余速度，始终导出静止移动状态。"
	)

	next_objective.queue_free()
	enemy.queue_free()


func _test_multiplayer_proxy_motion_and_action_restore() -> void:
	var proxy := _spawn_fire_sorcerer()
	proxy.configure_multiplayer_proxy()
	var sprite := proxy.animated_sprite

	_expect(
		sprite.animation == FIRE_SORCERER_CONFIG.move_animation_name
		and sprite.frame == 0
		and not sprite.is_playing()
		and is_zero_approx(sprite.get_playing_speed()),
		"零速多人代理初始化时必须显示静止move第0帧。"
	)

	proxy.apply_multiplayer_proxy_motion(
		Vector2(10.0, 20.0),
		Vector2.RIGHT * 0.01,
		Enemy.LocomotionState.MOVING
	)
	_expect(
		sprite.animation == FIRE_SORCERER_CONFIG.move_animation_name
		and sprite.is_playing()
		and sprite.get_playing_speed() > 0.0,
		"多人代理收到低速移动状态时必须恢复move循环。"
	)

	sprite.set_frame_and_progress(2, 0.5)
	proxy.apply_multiplayer_proxy_motion(
		Vector2(10.1, 20.0),
		Vector2.ZERO,
		Enemy.LocomotionState.MOVING
	)
	_expect(
		sprite.frame == 2
		and is_equal_approx(sprite.frame_progress, 0.5)
		and sprite.get_playing_speed() > 0.0,
		"量化速度为零时，明确的移动状态必须继续推进且不能重置move动画。"
	)

	proxy.apply_multiplayer_proxy_motion(
		Vector2(10.1, 20.0),
		Vector2.RIGHT * 24.0,
		Enemy.LocomotionState.IDLE
	)
	_expect(
		sprite.frame == 0
		and not sprite.is_playing()
		and is_zero_approx(sprite.get_playing_speed()),
		"明确的静止状态必须压过残留插值速度并冻结move第0帧。"
	)
	proxy.apply_multiplayer_proxy_motion(
		Vector2(10.1, 20.0),
		Vector2.ZERO,
		Enemy.LocomotionState.IDLE
	)
	_expect(
		sprite.frame == 0 and is_zero_approx(sprite.get_playing_speed()),
		"连续静止状态不能反复重播已经暂停的move动画。"
	)

	proxy.set_multiplayer_proxy_visual_active(false)
	_expect(
		is_zero_approx(sprite.speed_scale) and not sprite.is_playing(),
		"不可见代理仍应由speed_scale单独裁剪，且保持零速静止。"
	)
	proxy.apply_multiplayer_proxy_motion(
		Vector2(10.2, 20.0),
		Vector2.ZERO,
		Enemy.LocomotionState.MOVING
	)
	_expect(
		sprite.is_playing()
		and is_zero_approx(sprite.get_playing_speed())
		and is_zero_approx(sprite.speed_scale),
		"离屏代理可切换到移动语义，但可见性裁剪仍必须独立阻止动画耗时。"
	)
	proxy.set_multiplayer_proxy_visual_active(true)
	_expect(
		is_equal_approx(
			sprite.speed_scale,
			proxy.multiplayer_proxy_authored_animation_speed
		)
		and sprite.is_playing()
		and sprite.get_playing_speed() > 0.0,
		"移动代理重新可见时应恢复资源速度，并从原有move状态继续推进。"
	)
	proxy.apply_multiplayer_proxy_motion(
		Vector2(10.2, 20.0),
		Vector2.ZERO,
		Enemy.LocomotionState.IDLE
	)

	proxy.call(
		"_play_multiplayer_proxy_action_animation",
		FIRE_SORCERER_CONFIG.windup_animation_name
	)
	_expect(
		sprite.animation == FIRE_SORCERER_CONFIG.windup_animation_name
		and sprite.is_playing(),
		"零速多人代理的前摇动作不能被静止move规则冻结。"
	)
	proxy.apply_multiplayer_proxy_motion(
		Vector2(10.1, 20.0),
		Vector2.ZERO,
		Enemy.LocomotionState.IDLE
	)
	_expect(
		sprite.animation == FIRE_SORCERER_CONFIG.windup_animation_name
		and sprite.is_playing(),
		"动作期间收到零速快照时必须保留当前动作。"
	)
	proxy.call(
		"_restore_multiplayer_proxy_move_animation",
		proxy.proxy_action_restore_token,
		FIRE_SORCERER_CONFIG.windup_animation_name
	)
	_expect(
		sprite.animation == FIRE_SORCERER_CONFIG.move_animation_name
		and sprite.frame == 0
		and not sprite.is_playing()
		and is_zero_approx(sprite.get_playing_speed()),
		"多人动作恢复move后，如果最新状态仍为静止，必须立即回到静止帧。"
	)

	proxy.apply_multiplayer_proxy_motion(
		Vector2(12.0, 20.0),
		Vector2.ZERO,
		Enemy.LocomotionState.MOVING
	)
	_expect(
		sprite.is_playing() and sprite.get_playing_speed() > 0.0,
		"动作恢复后，低速量化为零的移动状态必须再次播放move。"
	)
	proxy.queue_free()


func _spawn_fire_sorcerer() -> FireSorcerer:
	var enemy := FIRE_SORCERER_SCENE.instantiate() as FireSorcerer
	test_root.add_child(enemy)
	enemy.setup(FIRE_SORCERER_CONFIG, null, null)
	enemy.set_physics_process(false)
	enemy.set_process(false)
	return enemy


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
