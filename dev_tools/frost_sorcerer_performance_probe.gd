extends SceneTree

# ColdStatusScheduler pressure probe. Targets are lightweight Enemy nodes kept
# outside the SceneTree: this isolates the scheduler's indexed min-heap from
# rendering, navigation and collision costs while still exercising its real
# Player/Enemy target gate.
const TARGET_COUNTS := [300, 1000]
const HITS_PER_TARGET := 5
const STABLE_SAMPLE_FRAMES := 120
const STAGGER_BUCKET_COUNT := 60
const STAGGER_DRAIN_FRAMES := 181
const TEST_DELTA := 1.0 / 60.0
const SAME_FRAME_EXPIRY_BUDGET_USEC := 16_600


class ColdCallbackSink:
	extends RefCounted

	var callback_count := 0
	var cleared_count := 0
	var last_stack_count := -1
	var last_multiplier := -1.0

	func receive_state(stack_count: int, multiplier: float) -> void:
		callback_count += 1
		last_stack_count = stack_count
		last_multiplier = multiplier
		if stack_count == 0:
			cleared_count += 1

	func reset() -> void:
		callback_count = 0
		cleared_count = 0
		last_stack_count = -1
		last_multiplier = -1.0


var failures: Array[String] = []
var scheduler: Node = null


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	scheduler = root.get_node("ColdStatusScheduler")
	scheduler.call("clear_all")
	scheduler.set_physics_process(false)
	scheduler.call("set_performance_metrics_enabled", true)

	for target_count in TARGET_COUNTS:
		_run_heap_cohort(target_count)

	scheduler.call("set_performance_metrics_enabled", false)
	scheduler.call("clear_all")
	scheduler.set_physics_process(false)
	await process_frame

	if failures.is_empty():
		print("FROST_SORCERER_PERFORMANCE_PROBE_OK")
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	quit(1)


func _run_heap_cohort(target_count: int) -> void:
	var same_expiry_result := _run_same_frame_five_hit_case(target_count)
	var staggered_result := _run_staggered_expiry_case(target_count)
	var freed_result := _run_freed_target_case(target_count)
	var cleared_latest_result := _run_cleared_latest_expiry_case(target_count)

	print(
		(
			"FROST_COLD_HEAP_PERFORMANCE targets=%d "
			+ "five_hit_apply_usec=%d apply_heap_updates=%d apply_callbacks=%d "
			+ "stable_p50_usec=%d stable_p95_usec=%d stable_p99_usec=%d "
			+ "stable_max_usec=%d "
			+ "stable_root_checks=%d stable_physics_usec=%d "
			+ "same_expiry_usec=%d same_root_checks=%d "
			+ "same_expired=%d stagger_p95_usec=%d stagger_p99_usec=%d "
			+ "stagger_max_usec=%d "
			+ "stagger_root_checks=%d stagger_expired=%d "
			+ "freed_targets=%d freed_root_checks=%d freed_expired=%d "
			+ "freed_callbacks=%d cleared_latest_usec=%d "
			+ "cleared_latest_root_checks=%d cleared_latest_expired=%d"
		)
		% [
			target_count,
			int(same_expiry_result.get("five_hit_apply_usec", -1)),
			int(same_expiry_result.get("apply_heap_updates", -1)),
			int(same_expiry_result.get("apply_callbacks", -1)),
			int(same_expiry_result.get("stable_p50_usec", -1)),
			int(same_expiry_result.get("stable_p95_usec", -1)),
			int(same_expiry_result.get("stable_p99_usec", -1)),
			int(same_expiry_result.get("stable_max_usec", -1)),
			int(same_expiry_result.get("stable_root_checks", -1)),
			int(same_expiry_result.get("stable_physics_usec", -1)),
			int(same_expiry_result.get("expiry_usec", -1)),
			int(same_expiry_result.get("expiry_root_checks", -1)),
			int(same_expiry_result.get("expired_targets", -1)),
			int(staggered_result.get("p95_usec", -1)),
			int(staggered_result.get("p99_usec", -1)),
			int(staggered_result.get("max_usec", -1)),
			int(staggered_result.get("root_checks", -1)),
			int(staggered_result.get("expired_targets", -1)),
			int(freed_result.get("freed_targets", -1)),
			int(freed_result.get("root_checks", -1)),
			int(freed_result.get("expired_targets", -1)),
			int(freed_result.get("callbacks", -1)),
			int(cleared_latest_result.get("expiry_usec", -1)),
			int(cleared_latest_result.get("root_checks", -1)),
			int(cleared_latest_result.get("expired_targets", -1)),
		]
	)


func _run_same_frame_five_hit_case(target_count: int) -> Dictionary:
	scheduler.call("clear_all")
	scheduler.call("reset_performance_metrics")
	var sink := ColdCallbackSink.new()
	var targets := _make_targets(target_count)
	var callback := Callable(sink, "receive_state")

	var rejected_hit_count := 0
	var apply_started_usec := Time.get_ticks_usec()
	for target in targets:
		for _hit_index in range(HITS_PER_TARGET):
			if not bool(scheduler.call("apply_cold", target, callback)):
				rejected_hit_count += 1
	var five_hit_apply_usec := maxi(
		Time.get_ticks_usec() - apply_started_usec,
		0
	)
	_expect(
		rejected_hit_count == 0,
		"Valid performance targets rejected %d cold hits." % rejected_hit_count
	)

	var apply_metrics := _get_metrics()
	var sample_target := targets[0]
	var sample_snapshot := (
		scheduler.call("get_state_snapshot", sample_target) as Dictionary
	)
	_expect(
		int(sample_snapshot.get("stack_count", -1)) == 4
		and is_equal_approx(float(sample_snapshot.get("time_left", -1.0)), 7.0)
		and is_equal_approx(float(sample_snapshot.get("multiplier", -1.0)), 0.10),
		"Five same-frame hits must produce L4, seven seconds, and x0.10."
	)
	_expect(
		int(scheduler.call("get_active_target_count")) == target_count
		and int(scheduler.call("get_heap_size")) == target_count,
		"Five hits must update one heap node per target instead of appending five."
	)
	_expect(
		int(apply_metrics.get("accepted_applications", -1))
			== target_count * HITS_PER_TARGET
		and int(apply_metrics.get("first_applications", -1)) == target_count
		and int(apply_metrics.get("stack_increases", -1)) == target_count * 3
		and int(apply_metrics.get("max_stack_extensions", -1)) == target_count
		and int(apply_metrics.get("callbacks", -1))
			== target_count * HITS_PER_TARGET
		and int(apply_metrics.get("peak_active_targets", -1)) == target_count
		and sink.callback_count == target_count * HITS_PER_TARGET
		and sink.last_stack_count == 4
		and is_equal_approx(sink.last_multiplier, 0.10),
		"Five-hit metrics must distinguish first, L2-L4, and capped-L4 updates."
	)
	var apply_budget_usec := 16_600 if target_count <= 300 else 50_000
	_expect(
		five_hit_apply_usec <= apply_budget_usec,
		"The %d-target five-hit apply burst exceeded %d usec: %d usec."
		% [target_count, apply_budget_usec, five_hit_apply_usec]
	)

	# During a stable interval no target is due. An indexed min-heap checks only
	# its root once per frame; target-wide scans or callbacks are regressions.
	scheduler.call("reset_performance_metrics")
	sink.reset()
	var stable_samples: Array[int] = []
	for _frame_index in range(STABLE_SAMPLE_FRAMES):
		var started_usec := Time.get_ticks_usec()
		scheduler.call("_physics_process", TEST_DELTA)
		stable_samples.append(maxi(Time.get_ticks_usec() - started_usec, 0))
	var stable_metrics := _get_metrics()
	var stable_summary := _summarize(stable_samples)
	_expect(
		int(stable_metrics.get("physics_calls", -1)) == STABLE_SAMPLE_FRAMES
		and int(stable_metrics.get("heap_root_checks", -1))
			<= STABLE_SAMPLE_FRAMES + 1
		and int(stable_metrics.get("heap_updates", -1)) == 0
		and int(stable_metrics.get("expired_targets", -1)) == 0
		and int(stable_metrics.get("callbacks", -1)) == 0,
		"A stable heap must perform one root check per frame, not an N-target scan."
	)
	var stable_budget_usec := 1_500 if target_count <= 300 else 3_000
	_expect(
		int(stable_summary.get("p95", 0)) <= stable_budget_usec,
		"Stable %d-target cold heap p95 exceeded %d usec: %s."
		% [target_count, stable_budget_usec, stable_summary]
	)

	# The first two seconds elapsed above. Advancing the remaining five seconds
	# creates the deliberately worst same-frame expiry burst.
	scheduler.call("reset_performance_metrics")
	sink.reset()
	var expiry_started_usec := Time.get_ticks_usec()
	scheduler.call("_physics_process", 5.0)
	var expiry_usec := maxi(Time.get_ticks_usec() - expiry_started_usec, 0)
	var expiry_metrics := _get_metrics()
	_expect(
		int(expiry_metrics.get("expired_targets", -1)) == target_count
		and int(expiry_metrics.get("callbacks", -1)) == target_count
		and int(expiry_metrics.get("heap_root_checks", -1)) >= 1
		and int(expiry_metrics.get("heap_root_checks", -1)) <= target_count
		and int(expiry_metrics.get("bulk_expiry_passes", -1)) == 1
		and int(expiry_metrics.get("bulk_expiry_targets", -1)) == target_count
		and sink.cleared_count == target_count
		and int(scheduler.call("get_active_target_count")) == 0
		and int(scheduler.call("get_heap_size")) == 0,
		"The same-frame burst must expire and notify every live target exactly once."
	)
	_expect(
		expiry_usec <= SAME_FRAME_EXPIRY_BUDGET_USEC,
		"The %d-target same-frame expiry burst exceeded one 60 FPS frame: %d usec."
		% [target_count, expiry_usec]
	)

	_free_targets(targets)
	return {
		"five_hit_apply_usec": five_hit_apply_usec,
		"apply_heap_updates": int(apply_metrics.get("heap_updates", 0)),
		"apply_callbacks": int(apply_metrics.get("callbacks", 0)),
		"stable_p50_usec": int(stable_summary.get("p50", 0)),
		"stable_p95_usec": int(stable_summary.get("p95", 0)),
		"stable_p99_usec": int(stable_summary.get("p99", 0)),
		"stable_max_usec": int(stable_summary.get("max", 0)),
		"stable_root_checks": int(stable_metrics.get("heap_root_checks", 0)),
		"stable_physics_usec": int(stable_metrics.get("physics_usec", 0)),
		"expiry_usec": expiry_usec,
		"expiry_root_checks": int(expiry_metrics.get("heap_root_checks", 0)),
		"expired_targets": int(expiry_metrics.get("expired_targets", 0)),
	}


func _run_staggered_expiry_case(target_count: int) -> Dictionary:
	scheduler.call("clear_all")
	var sink := ColdCallbackSink.new()
	var targets := _make_targets(target_count)
	var callback := Callable(sink, "receive_state")
	var cursor := 0

	# Schedule all targets across exactly sixty buckets without letting the first
	# three-second status expire during setup.
	for bucket_index in range(STAGGER_BUCKET_COUNT):
		var remaining_targets := target_count - cursor
		var remaining_buckets := STAGGER_BUCKET_COUNT - bucket_index
		var bucket_size := ceili(
			float(remaining_targets) / float(remaining_buckets)
		)
		var bucket_end := mini(cursor + bucket_size, target_count)
		while cursor < bucket_end:
			_expect(
				bool(scheduler.call("apply_cold", targets[cursor], callback)),
				"A staggered performance target rejected cold."
			)
			cursor += 1
		if bucket_index + 1 < STAGGER_BUCKET_COUNT:
			scheduler.call("_advance_active_colds", TEST_DELTA)

	_expect(
		cursor == target_count
		and int(scheduler.call("get_heap_size")) == target_count,
		"Stagger setup must retain exactly one heap entry per target."
	)
	scheduler.call("reset_performance_metrics")
	sink.reset()
	var samples: Array[int] = []
	for _frame_index in range(STAGGER_DRAIN_FRAMES):
		var started_usec := Time.get_ticks_usec()
		scheduler.call("_physics_process", TEST_DELTA)
		samples.append(maxi(Time.get_ticks_usec() - started_usec, 0))
	var metrics := _get_metrics()
	var summary := _summarize(samples)
	_expect(
		int(metrics.get("expired_targets", -1)) == target_count
		and int(metrics.get("callbacks", -1)) == target_count
		and int(metrics.get("heap_root_checks", -1))
			<= target_count + STAGGER_DRAIN_FRAMES
		and sink.cleared_count == target_count
		and int(scheduler.call("get_active_target_count")) == 0
		and int(scheduler.call("get_heap_size")) == 0,
		"Staggered expiry must drain every target and leave the heap empty."
	)
	var stagger_budget_usec := 3_000 if target_count <= 300 else 5_000
	_expect(
		int(summary.get("p95", 0)) <= stagger_budget_usec
		and int(summary.get("max", 0)) <= SAME_FRAME_EXPIRY_BUDGET_USEC,
		"Staggered %d-target expiry exceeded its frame budget: %s."
		% [target_count, summary]
	)

	_free_targets(targets)
	return {
		"p95_usec": int(summary.get("p95", 0)),
		"p99_usec": int(summary.get("p99", 0)),
		"max_usec": int(summary.get("max", 0)),
		"root_checks": int(metrics.get("heap_root_checks", 0)),
		"expired_targets": int(metrics.get("expired_targets", 0)),
	}


func _run_freed_target_case(target_count: int) -> Dictionary:
	scheduler.call("clear_all")
	var sink := ColdCallbackSink.new()
	var targets := _make_targets(target_count)
	var callback := Callable(sink, "receive_state")
	for target in targets:
		_expect(
			bool(scheduler.call("apply_cold", target, callback)),
			"A free-target fixture rejected cold."
		)

	var freed_target_count := target_count / 10
	for target_index in range(freed_target_count):
		targets[target_index].free()
		targets[target_index] = null
	scheduler.call("reset_performance_metrics")
	sink.reset()
	scheduler.call("_physics_process", 3.0)
	var metrics := _get_metrics()
	var surviving_target_count := target_count - freed_target_count
	_expect(
		int(metrics.get("expired_targets", -1)) == surviving_target_count
		and int(metrics.get("callbacks", -1)) == surviving_target_count
		and int(metrics.get("heap_root_checks", -1)) >= 1
		and int(metrics.get("heap_root_checks", -1)) <= target_count
		and int(metrics.get("bulk_expiry_passes", -1)) == 1
		and int(metrics.get("bulk_expiry_targets", -1)) == target_count
		and sink.cleared_count == surviving_target_count,
		"Freed WeakRefs must be discarded without callbacks; live targets expire once."
	)
	_expect(
		int(scheduler.call("get_active_target_count")) == 0
		and int(scheduler.call("get_heap_size")) == 0,
		"Ten-percent early free must not leave active-table or heap residue."
	)

	_free_targets(targets)
	return {
		"freed_targets": freed_target_count,
		"root_checks": int(metrics.get("heap_root_checks", 0)),
		"expired_targets": int(metrics.get("expired_targets", 0)),
		"callbacks": int(metrics.get("callbacks", 0)),
	}


func _run_cleared_latest_expiry_case(target_count: int) -> Dictionary:
	scheduler.call("clear_all")
	var sink := ColdCallbackSink.new()
	var targets := _make_targets(target_count)
	var callback := Callable(sink, "receive_state")
	for target in targets:
		_expect(
			bool(scheduler.call("apply_cold", target, callback)),
			"A manual-clear performance target rejected cold."
		)
	# Make one target the unique latest expiry, then clear it as death/exit paths
	# do. The remaining same-expiry cohort must still regain the O(n) bulk path.
	_expect(
		bool(scheduler.call("apply_cold", targets[0], callback))
		and bool(scheduler.call("clear_target", targets[0])),
		"The unique latest-expiry target must be clearable."
	)
	scheduler.call("reset_performance_metrics")
	sink.reset()
	var expiry_started_usec := Time.get_ticks_usec()
	scheduler.call("_physics_process", 3.0)
	var expiry_usec := maxi(Time.get_ticks_usec() - expiry_started_usec, 0)
	var metrics := _get_metrics()
	var expected_expired_count := target_count - 1
	_expect(
		int(metrics.get("expired_targets", -1)) == expected_expired_count
		and int(metrics.get("callbacks", -1)) == expected_expired_count
		and int(metrics.get("heap_root_checks", -1)) == 1
		and int(metrics.get("bulk_expiry_passes", -1)) == 1
		and int(metrics.get("bulk_expiry_targets", -1))
			== expected_expired_count
		and sink.cleared_count == expected_expired_count
		and int(scheduler.call("get_active_target_count")) == 0,
		"Clearing the latest expiry must not disable the remaining cohort's bulk drain."
	)
	_expect(
		expiry_usec <= SAME_FRAME_EXPIRY_BUDGET_USEC,
		"The %d-target post-clear bulk expiry exceeded one frame: %d usec."
		% [target_count, expiry_usec]
	)
	_free_targets(targets)
	return {
		"expiry_usec": expiry_usec,
		"root_checks": int(metrics.get("heap_root_checks", 0)),
		"expired_targets": int(metrics.get("expired_targets", 0)),
	}


func _make_targets(target_count: int) -> Array[Enemy]:
	var targets: Array[Enemy] = []
	targets.resize(target_count)
	for target_index in range(target_count):
		targets[target_index] = Enemy.new()
	return targets


func _free_targets(targets: Array[Enemy]) -> void:
	for target in targets:
		if target != null and is_instance_valid(target):
			target.free()


func _get_metrics() -> Dictionary:
	return scheduler.call("get_performance_metrics") as Dictionary


func _summarize(samples: Array[int]) -> Dictionary:
	if samples.is_empty():
		return {"p50": 0, "p95": 0, "p99": 0, "max": 0}
	var sorted := samples.duplicate()
	sorted.sort()
	return {
		"p50": _nearest_rank(sorted, 0.50),
		"p95": _nearest_rank(sorted, 0.95),
		"p99": _nearest_rank(sorted, 0.99),
		"max": sorted.back(),
	}


func _nearest_rank(sorted_samples: Array[int], percentile: float) -> int:
	var rank := ceili(clampf(percentile, 0.0, 1.0) * sorted_samples.size())
	return sorted_samples[clampi(rank - 1, 0, sorted_samples.size() - 1)]


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
