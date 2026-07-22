extends Node

# Enemy collectible effects are sparse deadline events. Keeping one indexed heap
# entry per affected enemy avoids one render/physics callback per enemy while no
# expiry or damage tick is due.
const DEADLINE_EPSILON := 0.000001
const BULK_COHORT_MIN_TARGETS := 16


class TargetDeadline:
	var target_id := 0
	var target_ref: WeakRef = null
	var callback_method := StringName()
	var deadline := 0.0
	var heap_index := -1


var _scheduler_clock := 0.0
var _states_by_target_id: Dictionary[int, TargetDeadline] = {}
var _deadline_heap: Array[TargetDeadline] = []
var _deadline_counts: Dictionary = {}
var _performance_metrics_enabled := false
var _performance_metrics := {
	"physics_calls": 0,
	"physics_usec": 0,
	"heap_root_checks": 0,
	"heap_updates": 0,
	"heap_repair_steps": 0,
	"schedule_calls": 0,
	"new_targets": 0,
	"rescheduled_targets": 0,
	"deadline_callbacks": 0,
	"bulk_cohort_dispatches": 0,
	"bulk_cohort_targets": 0,
	"cleared_targets": 0,
	"stale_targets": 0,
	"peak_active_targets": 0,
}


func _ready() -> void:
	set_physics_process(false)


func get_clock() -> float:
	return _scheduler_clock


func schedule_target(
	target: Node,
	deadline: float,
	callback_method: StringName
) -> bool:
	_increment_metric("schedule_calls")
	if (
		target == null
		or not is_instance_valid(target)
		or target.is_queued_for_deletion()
		or callback_method == &""
		or not target.has_method(callback_method)
		or not is_finite(deadline)
		or deadline <= _scheduler_clock + DEADLINE_EPSILON
	):
		return false

	var target_id := int(target.get_instance_id())
	var state := _states_by_target_id.get(target_id) as TargetDeadline
	if state != null and state.target_ref.get_ref() != target:
		_remove_state(state, false)
		state = null
	if state == null:
		state = TargetDeadline.new()
		state.target_id = target_id
		state.target_ref = weakref(target)
		state.callback_method = callback_method
		state.deadline = deadline
		_states_by_target_id[target_id] = state
		_push_heap(state)
		_increment_metric("new_targets")
		_update_peak_active_targets()
	else:
		if (
			state.callback_method == callback_method
			and absf(state.deadline - deadline) <= DEADLINE_EPSILON
		):
			set_physics_process(true)
			return true
		_decrement_deadline_count(state.deadline)
		state.callback_method = callback_method
		state.deadline = deadline
		_increment_deadline_count(state.deadline)
		_repair_heap_at(state.heap_index)
		_increment_metric("rescheduled_targets")
	set_physics_process(true)
	return true


func clear_target(target: Node) -> bool:
	if target == null or not is_instance_valid(target):
		return false
	var state := (
		_states_by_target_id.get(int(target.get_instance_id()))
		as TargetDeadline
	)
	if state == null or state.target_ref.get_ref() != target:
		return false
	_remove_state(state, true)
	return true


func clear_all() -> void:
	for state in _deadline_heap:
		state.heap_index = -1
	_deadline_heap.clear()
	_states_by_target_id.clear()
	_deadline_counts.clear()
	set_physics_process(false)


func get_active_target_count() -> int:
	return _states_by_target_id.size()


func get_heap_size() -> int:
	return _deadline_heap.size()


func set_performance_metrics_enabled(enabled: bool) -> void:
	_performance_metrics_enabled = enabled
	reset_performance_metrics()


func reset_performance_metrics() -> void:
	for metric_key in _performance_metrics:
		_performance_metrics[metric_key] = 0


func get_performance_metrics(reset_after_read: bool = false) -> Dictionary:
	var snapshot := _performance_metrics.duplicate()
	snapshot["active_targets"] = _states_by_target_id.size()
	snapshot["heap_size"] = _deadline_heap.size()
	if reset_after_read:
		reset_performance_metrics()
	return snapshot


func advance_for_test(delta: float) -> void:
	_advance_clock(maxf(delta, 0.0))


func _physics_process(delta: float) -> void:
	var started_usec := Time.get_ticks_usec() if _performance_metrics_enabled else 0
	_advance_clock(maxf(delta, 0.0))
	if not _performance_metrics_enabled:
		return
	_increment_metric("physics_calls")
	_performance_metrics["physics_usec"] = (
		int(_performance_metrics["physics_usec"])
		+ maxi(Time.get_ticks_usec() - started_usec, 0)
	)


func _advance_clock(delta: float) -> void:
	_scheduler_clock += delta
	while not _deadline_heap.is_empty():
		_increment_metric("heap_root_checks")
		var state := _deadline_heap[0]
		var target := state.target_ref.get_ref() as Node
		if (
			target == null
			or not is_instance_valid(target)
			or target.is_queued_for_deletion()
		):
			_remove_state(state, false)
			_increment_metric("stale_targets")
			continue
		if state.deadline > _scheduler_clock + DEADLINE_EPSILON:
			break
		if (
			_deadline_heap.size() >= BULK_COHORT_MIN_TARGETS
			and _deadline_counts.size() == 1
		):
			_dispatch_single_deadline_cohort()
			continue

		var callback_method := state.callback_method
		_remove_state(state, false)
		var next_deadline := _invoke_deadline_callback(
			target,
			callback_method
		)
		if next_deadline > 0.0:
			schedule_target(target, next_deadline, callback_method)

	if _deadline_heap.is_empty():
		set_physics_process(false)


func _dispatch_single_deadline_cohort() -> void:
	var cohort: Array[TargetDeadline] = []
	cohort.assign(_deadline_heap)
	_deadline_heap.clear()
	_states_by_target_id.clear()
	_deadline_counts.clear()
	set_physics_process(false)
	_increment_metric("bulk_cohort_dispatches")
	_add_metric("bulk_cohort_targets", cohort.size())
	_add_metric("heap_updates", cohort.size())

	# Callbacks may schedule unrelated work (for example via a defeat signal), so
	# hold recurring cohort entries aside until every callback has completed.
	# Then one bottom-up heapify restores the index in O(n), instead of paying
	# O(n log n) for a synchronized tick/expiry wave.
	var recurring_states: Array[TargetDeadline] = []
	for state in cohort:
		state.heap_index = -1
		var target := state.target_ref.get_ref() as Node
		if (
			target == null
			or not is_instance_valid(target)
			or target.is_queued_for_deletion()
		):
			_increment_metric("stale_targets")
			continue
		var next_deadline := _invoke_deadline_callback(
			target,
			state.callback_method
		)
		if next_deadline <= 0.0:
			continue
		state.deadline = next_deadline
		recurring_states.append(state)

	for state in recurring_states:
		var target := state.target_ref.get_ref() as Node
		if (
			target == null
			or not is_instance_valid(target)
			or target.is_queued_for_deletion()
			or _states_by_target_id.has(state.target_id)
		):
			continue
		state.heap_index = _deadline_heap.size()
		_deadline_heap.append(state)
		_states_by_target_id[state.target_id] = state
		_increment_deadline_count(state.deadline)
		_increment_metric("schedule_calls")
		_increment_metric("rescheduled_targets")

	_heapify_deadline_heap()
	if not _deadline_heap.is_empty():
		set_physics_process(true)


func _invoke_deadline_callback(
	target: Node,
	callback_method: StringName
) -> float:
	_increment_metric("deadline_callbacks")
	var next_deadline_variant: Variant = target.call(
		callback_method,
		_scheduler_clock
	)
	if (
		not is_instance_valid(target)
		or target.is_queued_for_deletion()
		or not (
			typeof(next_deadline_variant) == TYPE_FLOAT
			or typeof(next_deadline_variant) == TYPE_INT
		)
	):
		return 0.0
	var next_deadline := float(next_deadline_variant)
	if not is_finite(next_deadline) or next_deadline <= 0.0:
		return 0.0
	if next_deadline <= _scheduler_clock + DEADLINE_EPSILON:
		push_error(
			"Enemy collectible status callback returned a non-future deadline."
		)
		return 0.0
	return next_deadline


func _heapify_deadline_heap() -> void:
	for heap_index in range(_deadline_heap.size()):
		_deadline_heap[heap_index].heap_index = heap_index
	var parent_index := (_deadline_heap.size() >> 1) - 1
	while parent_index >= 0:
		_sift_down(parent_index)
		parent_index -= 1


func _push_heap(state: TargetDeadline) -> void:
	state.heap_index = _deadline_heap.size()
	_deadline_heap.append(state)
	_increment_deadline_count(state.deadline)
	_increment_metric("heap_updates")
	_sift_up(state.heap_index)


func _remove_state(state: TargetDeadline, manually_cleared: bool) -> void:
	if state == null:
		return
	if _states_by_target_id.get(state.target_id) == state:
		_states_by_target_id.erase(state.target_id)
	_decrement_deadline_count(state.deadline)
	_remove_heap_at(state.heap_index)
	if manually_cleared:
		_increment_metric("cleared_targets")
	if _deadline_heap.is_empty():
		set_physics_process(false)


func _remove_heap_at(index: int) -> void:
	if index < 0 or index >= _deadline_heap.size():
		return
	var removed_state := _deadline_heap[index]
	var last_state: TargetDeadline = _deadline_heap.pop_back()
	removed_state.heap_index = -1
	_increment_metric("heap_updates")
	if index >= _deadline_heap.size():
		return
	_deadline_heap[index] = last_state
	last_state.heap_index = index
	_repair_heap_at(index)


func _repair_heap_at(index: int) -> void:
	if index < 0 or index >= _deadline_heap.size():
		return
	_increment_metric("heap_updates")
	var parent_index := (index - 1) >> 1
	if (
		index > 0
		and _is_earlier(_deadline_heap[index], _deadline_heap[parent_index])
	):
		_sift_up(index)
		return
	_sift_down(index)


func _sift_up(start_index: int) -> void:
	var index := start_index
	while index > 0:
		var parent_index := (index - 1) >> 1
		if not _is_earlier(_deadline_heap[index], _deadline_heap[parent_index]):
			break
		_swap_heap_entries(index, parent_index)
		index = parent_index
		_increment_metric("heap_repair_steps")


func _sift_down(start_index: int) -> void:
	var index := start_index
	while true:
		var left_index := index * 2 + 1
		if left_index >= _deadline_heap.size():
			return
		var right_index := left_index + 1
		var earlier_child_index := left_index
		if (
			right_index < _deadline_heap.size()
			and _is_earlier(
				_deadline_heap[right_index],
				_deadline_heap[left_index]
			)
		):
			earlier_child_index = right_index
		if not _is_earlier(
			_deadline_heap[earlier_child_index],
			_deadline_heap[index]
		):
			return
		_swap_heap_entries(index, earlier_child_index)
		index = earlier_child_index
		_increment_metric("heap_repair_steps")


func _swap_heap_entries(first_index: int, second_index: int) -> void:
	var first_state := _deadline_heap[first_index]
	var second_state := _deadline_heap[second_index]
	_deadline_heap[first_index] = second_state
	_deadline_heap[second_index] = first_state
	first_state.heap_index = second_index
	second_state.heap_index = first_index
	_increment_metric("heap_updates")


func _is_earlier(first: TargetDeadline, second: TargetDeadline) -> bool:
	if first.deadline != second.deadline:
		return first.deadline < second.deadline
	return first.target_id < second.target_id


func _increment_deadline_count(deadline: float) -> void:
	_deadline_counts[deadline] = int(_deadline_counts.get(deadline, 0)) + 1


func _decrement_deadline_count(deadline: float) -> void:
	var next_count := int(_deadline_counts.get(deadline, 0)) - 1
	if next_count <= 0:
		_deadline_counts.erase(deadline)
		return
	_deadline_counts[deadline] = next_count


func _increment_metric(metric_key: String) -> void:
	if not _performance_metrics_enabled:
		return
	_performance_metrics[metric_key] = int(_performance_metrics[metric_key]) + 1


func _add_metric(metric_key: String, amount: int) -> void:
	if not _performance_metrics_enabled or amount == 0:
		return
	_performance_metrics[metric_key] = (
		int(_performance_metrics[metric_key]) + amount
	)


func _update_peak_active_targets() -> void:
	if not _performance_metrics_enabled:
		return
	_performance_metrics["peak_active_targets"] = maxi(
		int(_performance_metrics["peak_active_targets"]),
		_states_by_target_id.size()
	)
