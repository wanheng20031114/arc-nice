extends SceneTree

# A/B guard for the production regression that motivated the deadline-cohort
# scheduler. The legacy side is the former one-heap-entry-per-target algorithm;
# both sides execute the same target gate, WeakRef lookup, five callbacks per
# target and final expiry-index maintenance with performance metrics disabled.
const TARGET_COUNTS := [300, 1000]
const HITS_PER_TARGET := 5
const MEASUREMENT_ROUNDS := 7
const MULTIPLIERS := [0.75, 0.60, 0.35, 0.10]
const MINIMUM_MEDIAN_SPEEDUP := 1.35


class CallbackSink:
	extends RefCounted

	var callback_count := 0
	var last_stack_count := 0
	var last_multiplier := 1.0

	func receive_state(stack_count: int, multiplier: float) -> void:
		callback_count += 1
		last_stack_count = stack_count
		last_multiplier = multiplier

	func reset() -> void:
		callback_count = 0
		last_stack_count = 0
		last_multiplier = 1.0


class LegacyState:
	extends RefCounted

	var target_id := 0
	var target_ref: WeakRef = null
	var state_callback := Callable()
	var stack_count := 0
	var expires_at := 0.0
	var heap_index := -1


class LegacyTargetHeap:
	extends RefCounted

	var states_by_target_id: Dictionary[int, LegacyState] = {}
	var expiry_heap: Array[LegacyState] = []
	var heap_updates := 0
	var heap_repair_steps := 0

	func apply_cold(target: Object, state_callback: Callable) -> bool:
		_touch_disabled_metric()
		if not _is_supported_target(target) or not state_callback.is_valid():
			_touch_disabled_metric()
			return false
		var target_id := int(target.get_instance_id())
		var state := states_by_target_id.get(target_id) as LegacyState
		if state != null and state.target_ref.get_ref() != target:
			return false
		if state == null:
			state = LegacyState.new()
			state.target_id = target_id
			state.target_ref = weakref(target)
			state.state_callback = state_callback
			state.stack_count = 1
			state.expires_at = 3.0
			states_by_target_id[target_id] = state
			_push_heap(state)
			_touch_disabled_metric()
			_touch_disabled_metric()
		else:
			state.state_callback = state_callback
			if state.stack_count < 4:
				state.stack_count += 1
			else:
				_touch_disabled_metric()
			state.expires_at += 1.0
			_repair_heap_at(state.heap_index)
		_touch_disabled_metric()
		_touch_disabled_metric()
		state.state_callback.call(
			state.stack_count,
			float(MULTIPLIERS[state.stack_count - 1])
		)
		return true

	func clear() -> void:
		for state in expiry_heap:
			state.heap_index = -1
		expiry_heap.clear()
		states_by_target_id.clear()
		heap_updates = 0
		heap_repair_steps = 0

	func get_sample_state(target: Object) -> LegacyState:
		return states_by_target_id.get(
			int(target.get_instance_id())
		) as LegacyState

	func _is_supported_target(target: Object) -> bool:
		if target == null or not is_instance_valid(target):
			return false
		if target is PlantDefense:
			return false
		var player := target as Player
		if player != null:
			return not player.is_dead and not player.is_queued_for_deletion()
		var enemy := target as Enemy
		return (
			enemy != null
			and not enemy.is_dead
			and not enemy.is_multiplayer_proxy
			and not enemy.is_queued_for_deletion()
		)

	func _push_heap(state: LegacyState) -> void:
		state.heap_index = expiry_heap.size()
		expiry_heap.append(state)
		heap_updates += 1
		_touch_disabled_metric()
		_sift_up(state.heap_index)

	func _repair_heap_at(index: int) -> void:
		if index < 0 or index >= expiry_heap.size():
			return
		heap_updates += 1
		_touch_disabled_metric()
		var parent_index := (index - 1) >> 1
		if (
			index > 0
			and _is_earlier(expiry_heap[index], expiry_heap[parent_index])
		):
			_sift_up(index)
			return
		_sift_down(index)

	func _sift_up(start_index: int) -> void:
		var index := start_index
		while index > 0:
			var parent_index := (index - 1) >> 1
			if not _is_earlier(expiry_heap[index], expiry_heap[parent_index]):
				break
			_swap_heap_entries(index, parent_index)
			index = parent_index
			heap_repair_steps += 1
			_touch_disabled_metric()

	func _sift_down(start_index: int) -> void:
		var index := start_index
		while true:
			var left_index := index * 2 + 1
			if left_index >= expiry_heap.size():
				return
			var right_index := left_index + 1
			var earlier_child_index := left_index
			if (
				right_index < expiry_heap.size()
				and _is_earlier(
					expiry_heap[right_index],
					expiry_heap[left_index]
				)
			):
				earlier_child_index = right_index
			if not _is_earlier(
				expiry_heap[earlier_child_index],
				expiry_heap[index]
			):
				return
			_swap_heap_entries(index, earlier_child_index)
			index = earlier_child_index
			heap_repair_steps += 1
			_touch_disabled_metric()

	func _swap_heap_entries(first_index: int, second_index: int) -> void:
		var first_state := expiry_heap[first_index]
		var second_state := expiry_heap[second_index]
		expiry_heap[first_index] = second_state
		expiry_heap[second_index] = first_state
		first_state.heap_index = second_index
		second_state.heap_index = first_index
		heap_updates += 1
		_touch_disabled_metric()

	func _is_earlier(first: LegacyState, second: LegacyState) -> bool:
		if first.expires_at != second.expires_at:
			return first.expires_at < second.expires_at
		return first.target_id < second.target_id

	func _touch_disabled_metric() -> void:
		# The former production implementation called its disabled metric gate
		# throughout this path. Retain that dispatch cost in the A side.
		return


var failures: Array[String] = []
var scheduler: Node = null
var legacy := LegacyTargetHeap.new()
var sink := CallbackSink.new()


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	scheduler = root.get_node("ColdStatusScheduler")
	scheduler.call("clear_all")
	scheduler.call("set_performance_metrics_enabled", false)
	scheduler.set_physics_process(false)

	for target_count in TARGET_COUNTS:
		_run_target_count(target_count)

	scheduler.call("clear_all")
	scheduler.set_physics_process(false)
	await process_frame
	if failures.is_empty():
		print("COLD_STATUS_SCHEDULER_PERFORMANCE_AB_OK")
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	quit(1)


func _run_target_count(target_count: int) -> void:
	var targets := _make_targets(target_count)
	var callback := Callable(sink, "receive_state")
	# Untimed warmup ensures script dispatch and both allocation paths are hot.
	_measure_legacy(targets, callback)
	_measure_cohort(targets, callback)

	var legacy_samples: Array[int] = []
	var cohort_samples: Array[int] = []
	for round_index in range(MEASUREMENT_ROUNDS):
		if round_index % 2 == 0:
			legacy_samples.append(_measure_legacy(targets, callback))
			cohort_samples.append(_measure_cohort(targets, callback))
		else:
			cohort_samples.append(_measure_cohort(targets, callback))
			legacy_samples.append(_measure_legacy(targets, callback))

	legacy_samples.sort()
	cohort_samples.sort()
	var legacy_p50 := _nearest_rank(legacy_samples, 0.50)
	var legacy_p95 := _nearest_rank(legacy_samples, 0.95)
	var cohort_p50 := _nearest_rank(cohort_samples, 0.50)
	var cohort_p95 := _nearest_rank(cohort_samples, 0.95)
	var speedup := float(legacy_p50) / float(maxi(cohort_p50, 1))
	print(
		(
			"COLD_STATUS_SCHEDULER_AB targets=%d "
			+ "legacy_p50/p95_usec=%d/%d cohort_p50/p95_usec=%d/%d "
			+ "speedup_p50=%.2f legacy_heap_updates=%d "
			+ "legacy_heap_repairs=%d"
		)
		% [
			target_count,
			legacy_p50,
			legacy_p95,
			cohort_p50,
			cohort_p95,
			speedup,
			legacy.heap_updates,
			legacy.heap_repair_steps,
		]
	)
	_expect(
		speedup >= MINIMUM_MEDIAN_SPEEDUP,
		(
			"The %d-target deadline cohort median speedup regressed below %.2fx: "
			+ "legacy=%d usec cohort=%d usec."
		)
		% [
			target_count,
			MINIMUM_MEDIAN_SPEEDUP,
			legacy_p50,
			cohort_p50,
		]
	)
	var cohort_budget_usec := 16_600 if target_count <= 300 else 50_000
	_expect(
		cohort_p95 <= cohort_budget_usec,
		"The %d-target cohort p95 exceeded %d usec: %d usec."
		% [target_count, cohort_budget_usec, cohort_p95]
	)
	_free_targets(targets)


func _measure_legacy(
	targets: Array[Enemy],
	callback: Callable
) -> int:
	legacy.clear()
	sink.reset()
	var started_usec := Time.get_ticks_usec()
	for target in targets:
		for _hit_index in range(HITS_PER_TARGET):
			legacy.apply_cold(target, callback)
	var elapsed_usec := maxi(Time.get_ticks_usec() - started_usec, 0)
	var sample_state := legacy.get_sample_state(targets[0])
	_expect(
		legacy.states_by_target_id.size() == targets.size()
		and legacy.expiry_heap.size() == targets.size()
		and sink.callback_count == targets.size() * HITS_PER_TARGET
		and sample_state != null
		and sample_state.stack_count == 4
		and is_equal_approx(sample_state.expires_at, 7.0),
		"The legacy A fixture did not reproduce five-hit semantics."
	)
	return elapsed_usec


func _measure_cohort(
	targets: Array[Enemy],
	callback: Callable
) -> int:
	scheduler.call("clear_all")
	scheduler.set_physics_process(false)
	sink.reset()
	var started_usec := Time.get_ticks_usec()
	for target in targets:
		for _hit_index in range(HITS_PER_TARGET):
			scheduler.call("apply_cold", target, callback)
	# Include deferred expiry-index movement in B rather than shifting that work
	# outside the measured attack frame.
	scheduler.call("_advance_active_colds", 0.0)
	var elapsed_usec := maxi(Time.get_ticks_usec() - started_usec, 0)
	var sample_snapshot := (
		scheduler.call("get_state_snapshot", targets[0]) as Dictionary
	)
	_expect(
		int(scheduler.call("get_active_target_count")) == targets.size()
		and int(scheduler.call("get_heap_size")) == 1
		and int(scheduler.call("get_expiry_cohort_count")) == 1
		and sink.callback_count == targets.size() * HITS_PER_TARGET
		and int(sample_snapshot.get("stack_count", -1)) == 4
		and is_equal_approx(float(sample_snapshot.get("time_left", -1.0)), 7.0),
		"The deadline-cohort B fixture did not preserve five-hit semantics."
	)
	return elapsed_usec


func _make_targets(target_count: int) -> Array[Enemy]:
	var targets: Array[Enemy] = []
	targets.resize(target_count)
	for target_index in range(target_count):
		targets[target_index] = Enemy.new()
	return targets


func _free_targets(targets: Array[Enemy]) -> void:
	scheduler.call("clear_all")
	legacy.clear()
	for target in targets:
		if target != null and is_instance_valid(target):
			target.free()


func _nearest_rank(sorted_samples: Array[int], percentile: float) -> int:
	var rank := ceili(clampf(percentile, 0.0, 1.0) * sorted_samples.size())
	return sorted_samples[clampi(rank - 1, 0, sorted_samples.size() - 1)]


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
