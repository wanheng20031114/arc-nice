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
		and not sprite.is_playing(),
		"权威端进入远程攻击站位时必须在move第0帧冻结，而不是原地走路。"
	)
	_expect(
		is_equal_approx(sprite.speed_scale, authored_speed),
		"站立冻结必须保留资源的动画速度，不能占用speed_scale的可见性裁剪语义。"
	)

	enemy.call("_set_ranged_attack_position_held", false)
	_expect(
		sprite.animation == FIRE_SORCERER_CONFIG.move_animation_name
		and sprite.is_playing(),
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


func _test_multiplayer_proxy_motion_and_action_restore() -> void:
	var proxy := _spawn_fire_sorcerer()
	proxy.configure_multiplayer_proxy()
	var sprite := proxy.animated_sprite

	_expect(
		sprite.animation == FIRE_SORCERER_CONFIG.move_animation_name
		and sprite.frame == 0
		and not sprite.is_playing(),
		"零速多人代理初始化时必须显示静止move第0帧。"
	)

	proxy.apply_multiplayer_proxy_motion(Vector2(10.0, 20.0), Vector2.RIGHT * 24.0)
	_expect(
		sprite.animation == FIRE_SORCERER_CONFIG.move_animation_name
		and sprite.is_playing(),
		"多人代理收到非零速度快照时必须恢复move循环。"
	)
	proxy.apply_multiplayer_proxy_motion(Vector2(10.0, 20.0), Vector2.ZERO)
	_expect(
		sprite.frame == 0 and not sprite.is_playing(),
		"多人代理收到零速快照时必须冻结move第0帧。"
	)
	proxy.apply_multiplayer_proxy_motion(Vector2(10.0, 20.0), Vector2.ZERO)
	_expect(
		sprite.frame == 0 and not sprite.is_playing(),
		"连续零速快照不能反复重播已经暂停的move动画。"
	)

	proxy.set_multiplayer_proxy_visual_active(false)
	_expect(
		is_zero_approx(sprite.speed_scale) and not sprite.is_playing(),
		"不可见代理仍应由speed_scale单独裁剪，且保持零速静止。"
	)
	proxy.set_multiplayer_proxy_visual_active(true)
	_expect(
		is_equal_approx(
			sprite.speed_scale,
			proxy.multiplayer_proxy_authored_animation_speed
		)
		and not sprite.is_playing(),
		"代理重新可见时应恢复资源速度，但零速move仍必须保持暂停。"
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
	proxy.apply_multiplayer_proxy_motion(Vector2(10.0, 20.0), Vector2.ZERO)
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
		and not sprite.is_playing(),
		"多人动作恢复move后，如果最新快照仍为零速，必须立即回到静止帧。"
	)

	proxy.apply_multiplayer_proxy_motion(Vector2(12.0, 20.0), Vector2.LEFT * 24.0)
	_expect(sprite.is_playing(), "动作恢复后收到非零速度快照必须再次播放move。")
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
