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
	_expect(
		idle_timer != null
		and idle_timer.one_shot
		and is_equal_approx(idle_timer.wait_time, 15.0)
		and is_equal_approx(health_bar.idle_fade_delay, 15.0)
		and is_equal_approx(health_bar.idle_fade_duration, 0.8)
		and is_equal_approx(health_bar.idle_alpha, 0.18),
		"公共建筑血条必须预置15秒单次计时，并平滑降至18%不透明度。"
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
	_expect(
		health_bar.visible
		and is_equal_approx(
			health_bar.modulate.a,
			health_bar.idle_alpha
		)
		and idle_timer != null
		and idle_timer.is_stopped(),
		"无新伤害超时后血条必须保持可辨识并大幅变透明。"
	)

	health_bar.set_health(90, 100)
	_expect(
		is_equal_approx(
			health_bar.modulate.a,
			health_bar.idle_alpha
		)
		and idle_timer != null
		and idle_timer.is_stopped(),
		"局部治疗只能更新血量，不得重新点亮或重启弱化计时。"
	)

	health_bar.set_health(70, 100)
	_expect(
		is_equal_approx(health_bar.modulate.a, 1.0)
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
