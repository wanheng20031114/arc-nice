extends SceneTree

const DAY_NIGHT_CONTROLLER_SCENE := preload(
	"res://scene/lighting/day_night_controller.tscn"
)
const FLASH_POOL_SCENE := preload(
	"res://scene/lighting/night_vfx_flash_pool.tscn"
)
const REQUEST_POSITION := Vector2(160.0, 120.0)
const ATTACK_SECONDS := 0.015
const HOLD_SECONDS := 0.025
const DECAY_SECONDS := 0.10
const FLASH_DURATION_SECONDS := (
	ATTACK_SECONDS + HOLD_SECONDS + DECAY_SECONDS
)
const EXPIRED_REJECTION_PROBE_COUNT := 100_000

var failures: PackedStringArray = []


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	root.size = Vector2i(320, 240)
	root.content_scale_size = Vector2i(320, 240)

	var world := Node2D.new()
	world.name = "NightVfxFlashPoolLifecycleWorld"
	root.add_child(world)
	current_scene = world
	var controller := (
		DAY_NIGHT_CONTROLLER_SCENE.instantiate() as DayNightController
	)
	world.add_child(controller)
	controller.set_night_factor_immediate(1.0)
	var pool := FLASH_POOL_SCENE.instantiate() as NightVfxFlashPool
	world.add_child(pool)
	var camera := Camera2D.new()
	camera.position = REQUEST_POSITION
	camera.enabled = true
	world.add_child(camera)
	await process_frame
	await process_frame

	_verify_expired_request_cannot_steal_capacity(pool)
	_verify_expired_request_cannot_mutate_idle_slot(pool)
	_verify_non_finite_timing_cannot_mutate_pool(pool)
	_probe_expired_rejection_cost(pool)

	current_scene = null
	world.queue_free()
	await process_frame
	if failures.is_empty():
		print("NIGHT_VFX_FLASH_POOL_LIFECYCLE_SMOKE_TEST_PASSED")
		quit(0)
		return
	print(
		"NIGHT_VFX_FLASH_POOL_LIFECYCLE_SMOKE_TEST_FAILED count=%d"
		% failures.size()
	)
	quit(1)


func _verify_expired_request_cannot_steal_capacity(
	pool: NightVfxFlashPool
) -> void:
	_stop_all_flashes(pool)
	for request_index in range(pool.get_capacity()):
		_expect(
			_request_flash(
				pool,
				Vector2(132.0 + request_index * 8.0, 120.0),
				2,
				0.0
			),
			"用于生命周期回归的8个正常请求必须填满灯光池。"
		)
	var original_positions := PackedVector2Array()
	for child in pool.get_children():
		var flash := child as NightVfxFlash2D
		original_positions.append(flash.global_position)

	_expect(
		not _request_flash(
			pool,
			REQUEST_POSITION + Vector2(0.0, 24.0),
			3,
			FLASH_DURATION_SECONDS
		),
		"恰好到达灯光生命周期终点的延迟请求必须被拒绝。"
	)
	_expect(
		pool.get_active_flash_count() == pool.get_capacity(),
		"已过期高优先级请求不得停止或抢占满池中的正常闪光。"
	)
	for slot_index in range(pool.get_capacity()):
		var flash := pool.get_child(slot_index) as NightVfxFlash2D
		_expect(
			flash.is_flash_active()
			and flash.global_position == original_positions[slot_index],
			"已过期请求不得改写任何活跃槽位：%d" % slot_index
		)

	_expect(
		not _request_flash(
			pool,
			REQUEST_POSITION + Vector2(0.0, -24.0),
			1,
			0.0
		),
		"过期请求不得制造可供后续低优先级请求占用的空槽。"
	)
	_expect(
		_request_flash(
			pool,
			REQUEST_POSITION + Vector2(24.0, 0.0),
			3,
			FLASH_DURATION_SECONDS - 0.001
		),
		"仍剩余灯光生命周期的高优先级请求必须保留正常抢占能力。"
	)
	_expect(
		pool.get_active_flash_count() == pool.get_capacity(),
		"有效抢占后活跃灯数量必须维持固定容量。"
	)


func _verify_expired_request_cannot_mutate_idle_slot(
	pool: NightVfxFlashPool
) -> void:
	_stop_all_flashes(pool)
	var first_flash := pool.get_child(0) as NightVfxFlash2D
	first_flash.global_position = Vector2(80.0, 80.0)
	var original_color := first_flash.color
	_expect(
		not _request_flash(
			pool,
			REQUEST_POSITION,
			3,
			FLASH_DURATION_SECONDS + 0.25
		),
		"远超灯光生命周期的延迟请求必须被拒绝。"
	)
	_expect(
		pool.get_active_flash_count() == 0
		and first_flash.global_position == Vector2(80.0, 80.0)
		and first_flash.color == original_color,
		"已过期请求不得污染待机槽位的位置、颜色或活跃状态。"
	)


func _verify_non_finite_timing_cannot_mutate_pool(
	pool: NightVfxFlashPool
) -> void:
	_stop_all_flashes(pool)
	var first_flash := pool.get_child(0) as NightVfxFlash2D
	first_flash.global_position = Vector2(64.0, 64.0)
	var original_color := first_flash.color
	for invalid_elapsed in [NAN, INF, -INF]:
		_expect(
			not _request_flash(pool, REQUEST_POSITION, 3, invalid_elapsed),
			"非有限延迟时间必须在槽位选择前被拒绝。"
		)
	_expect(
		pool.get_active_flash_count() == 0
		and first_flash.global_position == Vector2(64.0, 64.0)
		and first_flash.color == original_color,
		"非有限时间请求不得污染待机槽位。"
	)


func _probe_expired_rejection_cost(pool: NightVfxFlashPool) -> void:
	_stop_all_flashes(pool)
	var started_usec := Time.get_ticks_usec()
	for probe_index in range(EXPIRED_REJECTION_PROBE_COUNT):
		_request_flash(
			pool,
			REQUEST_POSITION,
			3,
			FLASH_DURATION_SECONDS + float(probe_index & 1)
		)
	var elapsed_usec := Time.get_ticks_usec() - started_usec
	_expect(
		pool.get_active_flash_count() == 0,
		"高频过期拒绝探针不得激活或反复配置任何真实灯。"
	)
	print(
		"NIGHT_VFX_FLASH_POOL_EXPIRED_REJECT_100K_USEC=%d"
		% elapsed_usec
	)


func _request_flash(
	pool: NightVfxFlashPool,
	world_position: Vector2,
	priority: int,
	elapsed_seconds: float
) -> bool:
	return pool.request_flash(
		world_position,
		Color(1.0, 0.76, 0.22, 1.0),
		0.62,
		0.30,
		ATTACK_SECONDS,
		HOLD_SECONDS,
		DECAY_SECONDS,
		priority,
		elapsed_seconds
	)


func _stop_all_flashes(pool: NightVfxFlashPool) -> void:
	for child in pool.get_children():
		(child as NightVfxFlash2D).stop_flash()


func _expect(condition: bool, message: String) -> void:
	if condition:
		return
	failures.append(message)
	push_error(message)
