extends SceneTree

const HEALTH_BAR_SCENE := preload(
	"res://scene/plant_defense/ui/plant_health_bar.tscn"
)

var failures: Array[String] = []


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	var fixture := Node2D.new()
	fixture.name = "PlantHealthBarIdleFadeSmokeFixture"
	root.add_child(fixture)
	var health_bar := HEALTH_BAR_SCENE.instantiate() as PlantHealthBar
	fixture.add_child(health_bar)
	await process_frame

	var idle_timer := health_bar.get_node_or_null("IdleFadeTimer") as Timer
	var health_bar_material := health_bar.material as CanvasItemMaterial
	_expect(
		idle_timer != null
		and idle_timer.one_shot
		and is_equal_approx(idle_timer.wait_time, 15.0)
		and is_equal_approx(health_bar.idle_fade_delay, 15.0)
		and is_equal_approx(health_bar.idle_fade_duration, 0.8)
		and is_equal_approx(health_bar.idle_color_brightness, 0.90)
		and is_equal_approx(health_bar.idle_slot_alpha, 0.82)
		and health_bar_material != null
		and health_bar_material.light_mode
		== CanvasItemMaterial.LIGHT_MODE_UNSHADED,
		"公共建筑血条必须预置15秒单次计时，并使用不受昼夜光照影响的分层弱化样式。"
	)
	health_bar.fade_duration = 0.0
	health_bar.fill_duration = 0.0
	health_bar.damage_trail_delay = 0.0
	health_bar.damage_trail_duration = 0.0
	health_bar.idle_fade_delay = 1.0
	health_bar.idle_fade_duration = 0.0
	health_bar.setup(100, 100)
	_expect(
		not health_bar.visible
		and idle_timer != null
		and idle_timer.one_shot
		and idle_timer.is_stopped()
		and not health_bar.is_processing()
		and not health_bar.is_physics_processing(),
		"满血建筑必须隐藏血条、停止单次计时器且不注册脚本逐帧处理。"
	)

	health_bar.set_health(80, 100)
	_expect(
		health_bar.visible
		and is_equal_approx(health_bar.modulate.a, 1.0)
		and idle_timer != null
		and not idle_timer.is_stopped(),
		"建筑受伤后血条必须立即清晰显示并启动单次弱化计时。"
	)

	if idle_timer != null:
		idle_timer.stop()
		idle_timer.timeout.emit()
	var idle_fill: Color = health_bar.call(
		"_resolve_idle_color",
		health_bar.health_fill_color,
		health_bar.idle_color_brightness,
		1.0,
		1.08
	)
	var idle_frame: Color = health_bar.call(
		"_resolve_idle_color",
		health_bar.frame_color,
		health_bar.idle_color_brightness,
		1.0,
		0.96
	)
	var idle_slot: Color = health_bar.call(
		"_resolve_idle_color",
		health_bar.slot_color,
		health_bar.idle_color_brightness,
		health_bar.idle_slot_alpha,
		1.0
	)
	_expect(
		health_bar.visible
		and is_equal_approx(health_bar.modulate.a, 1.0)
		and is_equal_approx(
			float(health_bar.get("_idle_style_amount")),
			1.0
		)
		and idle_timer != null
		and idle_timer.is_stopped(),
		"无新伤害超时后必须保持整体不透明，只弱化各绘制层的颜色。"
	)
	_expect(
		is_equal_approx(idle_fill.a, health_bar.health_fill_color.a)
		and is_equal_approx(idle_frame.a, health_bar.frame_color.a)
		and idle_slot.a < health_bar.slot_color.a
		and idle_slot.a >= 0.75
		and idle_fill.g > idle_fill.r
		and idle_fill.g > idle_fill.b,
		"闲置样式只能让空槽略微透出背景，关键边框和绿色填充必须保持不透明且颜色明确。"
	)

	health_bar.set_health(90, 100)
	_expect(
		is_equal_approx(health_bar.modulate.a, 1.0)
		and is_equal_approx(
			float(health_bar.get("_idle_style_amount")),
			1.0
		)
		and idle_timer != null
		and idle_timer.is_stopped(),
		"局部治疗只能更新血量，不得重新点亮或重启弱化计时。"
	)

	health_bar.set_health(70, 100)
	_expect(
		is_equal_approx(health_bar.modulate.a, 1.0)
		and is_zero_approx(
			float(health_bar.get("_idle_style_amount"))
		)
		and idle_timer != null
		and not idle_timer.is_stopped(),
		"已经弱化的血条再次受伤时必须立即恢复清晰并重置计时。"
	)

	health_bar.set_health(100, 100)
	_expect(
		not health_bar.visible
		and idle_timer != null
		and idle_timer.is_stopped(),
		"建筑回满生命后必须完全隐藏血条并停止计时器。"
	)

	health_bar.setup(100, 75)
	_expect(
		health_bar.visible
		and is_equal_approx(health_bar.modulate.a, 1.0)
		and idle_timer != null
		and not idle_timer.is_stopped(),
		"初次载入已经残血的多人建筑也必须显示血条并安排一次弱化。"
	)

	health_bar.idle_fade_duration = 0.12
	health_bar.fade_duration = 0.06
	if idle_timer != null:
		idle_timer.stop()
		idle_timer.timeout.emit()
	var active_idle_tween := health_bar.get(
		"_idle_style_tween"
	) as Tween
	if active_idle_tween != null:
		active_idle_tween.custom_step(0.04)
	var partial_idle_amount := float(
		health_bar.get("_idle_style_amount")
	)
	_expect(
		partial_idle_amount > 0.0
		and partial_idle_amount < 1.0
		and active_idle_tween != null
		and active_idle_tween.is_valid(),
		"真实0.8秒样式路径的缩时夹具必须能观察到进行中的分层弱化Tween。"
	)
	health_bar.set_health(65, 100)
	_expect(
		is_zero_approx(
			float(health_bar.get("_idle_style_amount"))
		)
		and health_bar.get("_idle_style_tween") == null,
		"弱化动画进行中再次受伤必须立即终止Tween并恢复清晰样式。"
	)

	if idle_timer != null:
		idle_timer.stop()
		idle_timer.timeout.emit()
	var second_idle_tween := health_bar.get(
		"_idle_style_tween"
	) as Tween
	if second_idle_tween != null:
		second_idle_tween.custom_step(0.04)
	health_bar.set_health(100, 100)
	var fade_out_tween := health_bar.get(
		"_visibility_tween"
	) as Tween
	if fade_out_tween != null:
		fade_out_tween.custom_step(0.08)
	_expect(
		not health_bar.visible
		and is_zero_approx(
			float(health_bar.get("_idle_style_amount"))
		)
		and health_bar.get("_idle_style_tween") == null,
		"弱化动画进行中回满必须停止样式Tween，淡出后留下干净隐藏态。"
	)
	health_bar.setup(100, 100)

	fixture.queue_free()
	for _cleanup_frame in range(3):
		await process_frame
	if failures.is_empty():
		print("PLANT_HEALTH_BAR_IDLE_FADE_SMOKE_TEST_OK")
		quit(0)
	else:
		print(
			"PLANT_HEALTH_BAR_IDLE_FADE_SMOKE_TEST_FAILED: %d"
			% failures.size()
		)
		quit(1)


func _expect(condition: bool, message: String) -> void:
	if condition:
		return
	failures.append(message)
	push_error(message)
