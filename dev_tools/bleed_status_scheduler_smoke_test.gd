extends SceneTree

const SOURCE_A := &"bleed_source_a"
const SOURCE_B := &"bleed_source_b"
const REENTRANT_SOURCE := &"reentrant_bleed"
const EPSILON := 0.0001


class BleedProbe:
	extends RefCounted

	var scheduler: Node = null
	var tick_events: Array[StringName] = []
	var tick_damage_total := 0
	var ticks_by_source: Dictionary = {}
	var state_events: Array[bool] = []
	var reapply_on_state_clear := false
	var clear_and_reapply_on_first_tick := false

	func receive_bleed_tick(
		source_family: StringName,
		tick_damage: int
	) -> bool:
		tick_events.append(source_family)
		tick_damage_total += tick_damage
		ticks_by_source[source_family] = (
			int(ticks_by_source.get(source_family, 0)) + 1
		)
		if clear_and_reapply_on_first_tick and scheduler != null:
			clear_and_reapply_on_first_tick = false
			scheduler.call("clear_target", self)
			scheduler.call(
				"apply_bleed",
				self,
				Callable(self, "receive_bleed_tick"),
				REENTRANT_SOURCE,
				1.0,
				11,
				0.25,
				Callable(self, "receive_bleed_state")
			)
		return true

	func receive_bleed_state(active: bool) -> void:
		state_events.append(active)
		if active or not reapply_on_state_clear or scheduler == null:
			return
		reapply_on_state_clear = false
		scheduler.call(
			"apply_bleed",
			self,
			Callable(self, "receive_bleed_tick"),
			REENTRANT_SOURCE,
			1.0,
			11,
			0.25,
			Callable(self, "receive_bleed_state")
		)


var failures: Array[String] = []
var scheduler: Node = null


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	scheduler = root.get_node("BleedStatusScheduler")
	scheduler.call("clear_all")
	scheduler.set_physics_process(false)

	_test_same_source_refreshes_in_place()
	_test_different_sources_tick_independently()
	_test_coarse_and_fine_physics_steps_match()
	_test_expiry_wins_over_same_time_tick()
	_test_active_callback_spans_first_to_last_source()
	_test_clear_callback_can_reapply()
	_test_tick_callback_can_clear_and_reapply()
	_test_all_source_snapshots_advance()
	_test_generic_kernel_rejects_invalid_policy()

	scheduler.call("clear_all")
	await process_frame
	if failures.is_empty():
		print("BLEED_STATUS_SCHEDULER_SMOKE_TEST_OK")
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	quit(1)


func _test_same_source_refreshes_in_place() -> void:
	scheduler.call("clear_all")
	var target := BleedProbe.new()
	_apply_bleed(target, SOURCE_A, 2.0, 3, 0.5)
	_advance(0.3)
	var before_refresh := _snapshot(target, SOURCE_A)
	_expect(
		_is_near(float(before_refresh.get("time_left", -1.0)), 1.7)
		and _is_near(
			float(before_refresh.get("tick_time_left", -1.0)),
			0.2
		),
		"流血快照必须反映刷新前已经经过的物理时间。"
	)

	_apply_bleed(target, SOURCE_A, 1.5, 5, 0.5)
	var refreshed := _snapshot(target, SOURCE_A)
	_expect(
		int(scheduler.call("get_source_count", target)) == 1
		and _is_near(float(refreshed.get("time_left", -1.0)), 1.5)
		and _is_near(
			float(refreshed.get("tick_time_left", -1.0)),
			0.5
		)
		and int(refreshed.get("tick_damage", -1)) == 5,
		"同来源流血应原位刷新持续时间、伤害和首跳时钟，而不是叠层。"
	)
	_advance(0.49)
	_expect(target.tick_events.is_empty(), "刷新后的流血不得沿用旧首跳相位。")
	_advance(0.01)
	_expect(
		target.tick_events == [SOURCE_A]
		and target.tick_damage_total == 5,
		"同来源刷新后必须按新的间隔和伤害跳一次。"
	)


func _test_different_sources_tick_independently() -> void:
	scheduler.call("clear_all")
	var target := BleedProbe.new()
	_apply_bleed(target, SOURCE_A, 2.0, 3, 0.5)
	_apply_bleed(target, SOURCE_B, 2.0, 7, 0.25)
	_advance(0.5)
	_expect(
		int(target.ticks_by_source.get(SOURCE_A, 0)) == 1
		and int(target.ticks_by_source.get(SOURCE_B, 0)) == 2
		and target.tick_damage_total == 17
		and int(scheduler.call("get_source_count", target)) == 2,
		"不同来源流血必须保留各自相位并独立叠加伤害。"
	)


func _test_coarse_and_fine_physics_steps_match() -> void:
	var coarse_result := _simulate_two_sources([1.7])
	var fine_steps: Array[float] = []
	for _frame_index in range(102):
		fine_steps.append(1.0 / 60.0)
	var fine_result := _simulate_two_sources(fine_steps)
	_expect(
		coarse_result == fine_result
		and int(coarse_result.get(SOURCE_A, -1)) == 6
		and int(coarse_result.get(SOURCE_B, -1)) == 4
		and int(coarse_result.get(&"damage_total", -1)) == 24,
		"粗步进和 60 Hz 细步进必须得到完全相同的独立流血跳数。"
	)


func _simulate_two_sources(steps: Array[float]) -> Dictionary:
	scheduler.call("clear_all")
	var target := BleedProbe.new()
	_apply_bleed(target, SOURCE_A, 2.2, 2, 0.25)
	_apply_bleed(target, SOURCE_B, 2.2, 3, 0.4)
	for delta in steps:
		_advance(delta)
	return {
		SOURCE_A: int(target.ticks_by_source.get(SOURCE_A, 0)),
		SOURCE_B: int(target.ticks_by_source.get(SOURCE_B, 0)),
		&"damage_total": target.tick_damage_total,
	}


func _test_expiry_wins_over_same_time_tick() -> void:
	scheduler.call("clear_all")
	var target := BleedProbe.new()
	_apply_bleed(target, SOURCE_A, 0.5, 9, 0.5)
	_advance(0.5)
	_expect(
		target.tick_events.is_empty()
		and not bool(scheduler.call("has_bleed", target)),
		"流血到期与跳伤同刻时必须先到期，不得追加边界伤害。"
	)


func _test_active_callback_spans_first_to_last_source() -> void:
	scheduler.call("clear_all")
	var target := BleedProbe.new()
	var state_callback := Callable(target, "receive_bleed_state")
	_apply_bleed(target, SOURCE_A, 0.2, 1, 1.0, state_callback)
	_apply_bleed(target, SOURCE_B, 0.4, 1, 1.0, state_callback)
	_expect(
		target.state_events == [true],
		"只有首个流血来源应开启一次目标 active 状态。"
	)
	_advance(0.21)
	_expect(
		target.state_events == [true]
		and not bool(scheduler.call("has_bleed", target, SOURCE_A))
		and bool(scheduler.call("has_bleed", target, SOURCE_B)),
		"一个来源到期时，剩余来源必须继续维持 active 状态。"
	)
	_advance(0.20)
	_expect(
		target.state_events == [true, false],
		"最后一个来源到期时才应关闭一次目标 active 状态。"
	)


func _test_clear_callback_can_reapply() -> void:
	scheduler.call("clear_all")
	var target := BleedProbe.new()
	target.scheduler = scheduler
	target.reapply_on_state_clear = true
	var state_callback := Callable(target, "receive_bleed_state")
	_apply_bleed(target, SOURCE_A, 1.0, 2, 0.5, state_callback)
	scheduler.call("clear_all")
	_expect(
		target.state_events == [true, false, true]
		and bool(scheduler.call("has_bleed", target, REENTRANT_SOURCE)),
		"clear 回调中的重入施加必须保留替代状态及其 active 通知。"
	)
	scheduler.call("clear_all")
	_expect(
		target.state_events == [true, false, true, false],
		"替代流血被清除时必须且只能补发一次 inactive 通知。"
	)


func _test_tick_callback_can_clear_and_reapply() -> void:
	scheduler.call("clear_all")
	var target := BleedProbe.new()
	target.scheduler = scheduler
	target.clear_and_reapply_on_first_tick = true
	var state_callback := Callable(target, "receive_bleed_state")
	_apply_bleed(target, SOURCE_A, 1.0, 3, 0.25, state_callback)
	_apply_bleed(target, SOURCE_B, 1.0, 7, 0.25, state_callback)
	_advance(0.25)
	_expect(
		target.tick_events == [SOURCE_A]
		and target.state_events == [true, false, true]
		and bool(scheduler.call("has_bleed", target, REENTRANT_SOURCE))
		and int(scheduler.call("get_source_count", target)) == 1,
		"跳伤回调清除目标后必须停止同刻其余来源，并安全保留重入状态。"
	)
	_advance(0.25)
	_expect(
		target.tick_events == [SOURCE_A, REENTRANT_SOURCE]
		and target.tick_damage_total == 14,
		"跳伤回调中重入创建的来源必须从回调时刻开始自己的完整相位。"
	)


func _test_all_source_snapshots_advance() -> void:
	scheduler.call("clear_all")
	var target := BleedProbe.new()
	_apply_bleed(target, SOURCE_A, 2.0, 2, 0.5)
	_apply_bleed(target, SOURCE_B, 2.0, 3, 0.8)
	_advance(0.2)
	var source_a_snapshot := _snapshot(target, SOURCE_A)
	var source_b_snapshot := _snapshot(target, SOURCE_B)
	_expect(
		_is_near(float(source_a_snapshot.get("time_left", -1.0)), 1.8)
		and _is_near(
			float(source_a_snapshot.get("tick_time_left", -1.0)),
			0.3
		)
		and _is_near(float(source_b_snapshot.get("time_left", -1.0)), 1.8)
		and _is_near(
			float(source_b_snapshot.get("tick_time_left", -1.0)),
			0.6
		),
		"ALL_SOURCES 快照必须推进每个来源，而非只推进最强来源。"
	)
	_advance(0.3)
	source_a_snapshot = _snapshot(target, SOURCE_A)
	source_b_snapshot = _snapshot(target, SOURCE_B)
	_expect(
		_is_near(
			float(source_a_snapshot.get("tick_time_left", -1.0)),
			0.5
		)
		and _is_near(
			float(source_b_snapshot.get("tick_time_left", -1.0)),
			0.3
		),
		"任一来源跳伤后，其他来源的独立剩余相位必须继续可观测。"
	)


func _test_generic_kernel_rejects_invalid_policy() -> void:
	scheduler.call("clear_all")
	var target := BleedProbe.new()
	var accepted := bool(scheduler.call(
		"apply_periodic_status",
		target,
		Callable(target, "receive_bleed_tick"),
		SOURCE_A,
		1.0,
		2,
		0.5,
		999,
		Callable(target, "receive_bleed_state")
	))
	_expect(
		not accepted
		and int(scheduler.call("get_active_target_count")) == 0
		and target.state_events.is_empty(),
		"通用周期伤害内核必须拒绝非法 tick policy，且不能遗留半成品状态。"
	)


func _apply_bleed(
	target: BleedProbe,
	source_family: StringName,
	duration: float,
	tick_damage: int,
	tick_interval: float,
	state_callback: Callable = Callable()
) -> void:
	_expect(
		bool(scheduler.call(
			"apply_bleed",
			target,
			Callable(target, "receive_bleed_tick"),
			source_family,
			duration,
			tick_damage,
			tick_interval,
			state_callback
		)),
		"流血调度器拒绝了合法来源。"
	)


func _snapshot(target: BleedProbe, source_family: StringName) -> Dictionary:
	return scheduler.call(
		"get_source_snapshot",
		target,
		source_family
	) as Dictionary


func _advance(delta: float) -> void:
	scheduler.call("_advance_active_statuses", delta)


func _is_near(actual: float, expected: float) -> bool:
	return absf(actual - expected) <= EPSILON


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
