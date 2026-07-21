extends Node

const INITIAL_DURATION_SECONDS := 3.0
const REAPPLICATION_EXTENSION_SECONDS := 1.0
const MAX_STACK_COUNT := 4
const STACK_MULTIPLIERS := [0.75, 0.60, 0.35, 0.10]
const EXPIRY_EPSILON := 0.000001


class ColdState:
	var target_id := 0
	var target_ref: WeakRef = null
	var state_callback := Callable()
	var stack_count := 0
	var expires_at := 0.0
	var heap_index := -1


var _physics_clock := 0.0
var _latest_expiry_hint := 0.0
var _latest_expiry_hint_dirty := false
var _states_by_target_id: Dictionary[int, ColdState] = {}
var _expiry_heap: Array[ColdState] = []
var _performance_metrics_enabled := false
var _performance_metrics := {
	"physics_calls": 0,
	"physics_usec": 0,
	"heap_root_checks": 0,
	"heap_updates": 0,
	"callbacks": 0,
	"apply_calls": 0,
	"accepted_applications": 0,
	"first_applications": 0,
	"stack_increases": 0,
	"max_stack_extensions": 0,
	"expired_targets": 0,
	"manually_cleared_targets": 0,
	"rejected_applications": 0,
	"heap_repair_steps": 0,
	"bulk_expiry_passes": 0,
	"bulk_expiry_targets": 0,
	"peak_active_targets": 0,
}


func _ready() -> void:
	set_physics_process(false)


func apply_cold(target: Object, state_callback: Callable) -> bool:
	_increment_metric("apply_calls")
	if not _is_supported_target(target) or not state_callback.is_valid():
		_increment_metric("rejected_applications")
		return false

	var target_id := int(target.get_instance_id())
	var state := _states_by_target_id.get(target_id) as ColdState
	if state != null and state.target_ref.get_ref() != target:
		_remove_state(state, false, false)
		state = null
	if state != null and state.expires_at <= _physics_clock + EXPIRY_EPSILON:
		_remove_state(state, true, false)
		state = null

	if state == null:
		state = ColdState.new()
		state.target_id = target_id
		state.target_ref = weakref(target)
		state.state_callback = state_callback
		state.stack_count = 1
		state.expires_at = _physics_clock + INITIAL_DURATION_SECONDS
		_record_latest_expiry_hint(state.expires_at)
		_states_by_target_id[target_id] = state
		_push_heap(state)
		_increment_metric("first_applications")
		_update_peak_active_targets()
	else:
		state.state_callback = state_callback
		if state.stack_count < MAX_STACK_COUNT:
			state.stack_count += 1
			_increment_metric("stack_increases")
		else:
			_increment_metric("max_stack_extensions")
		state.expires_at += REAPPLICATION_EXTENSION_SECONDS
		_record_latest_expiry_hint(state.expires_at)
		_repair_heap_at(state.heap_index)

	_increment_metric("accepted_applications")
	set_physics_process(true)
	_increment_metric("callbacks")
	state.state_callback.call(
		state.stack_count,
		_get_stack_multiplier(state.stack_count)
	)
	return true


func clear_target(target: Object) -> bool:
	if target == null or not is_instance_valid(target):
		return false
	var target_id := int(target.get_instance_id())
	var state := _states_by_target_id.get(target_id) as ColdState
	if state == null or state.target_ref.get_ref() != target:
		return false
	_remove_state(state, true, true)
	return true


func clear_all() -> void:
	if _expiry_heap.is_empty():
		_states_by_target_id.clear()
		_latest_expiry_hint = 0.0
		_latest_expiry_hint_dirty = false
		set_physics_process(false)
		return
	var states_to_clear: Array[ColdState] = []
	states_to_clear.assign(_expiry_heap)
	_expiry_heap.clear()
	_states_by_target_id.clear()
	_latest_expiry_hint = 0.0
	_latest_expiry_hint_dirty = false
	set_physics_process(false)
	for state in states_to_clear:
		state.heap_index = -1
		_increment_metric("manually_cleared_targets")
		_notify_state_cleared(state)


func has_cold(target: Object) -> bool:
	return _get_current_state(target) != null


func get_stack_count(target: Object) -> int:
	var state := _get_current_state(target)
	return state.stack_count if state != null else 0


func get_state_snapshot(target: Object) -> Dictionary:
	var state := _get_current_state(target)
	if state == null:
		return {}
	return {
		"stack_count": state.stack_count,
		"multiplier": _get_stack_multiplier(state.stack_count),
		"time_left": maxf(state.expires_at - _physics_clock, 0.0),
	}


func get_active_target_count() -> int:
	return _states_by_target_id.size()


func get_heap_size() -> int:
	return _expiry_heap.size()


func set_performance_metrics_enabled(enabled: bool) -> void:
	_performance_metrics_enabled = enabled
	reset_performance_metrics()


func reset_performance_metrics() -> void:
	for metric_key in _performance_metrics:
		_performance_metrics[metric_key] = 0


func get_performance_metrics(reset_after_read: bool = false) -> Dictionary:
	var snapshot := _performance_metrics.duplicate()
	snapshot["active_targets"] = _states_by_target_id.size()
	snapshot["heap_size"] = _expiry_heap.size()
	if reset_after_read:
		reset_performance_metrics()
	return snapshot


func _physics_process(delta: float) -> void:
	var started_usec := Time.get_ticks_usec() if _performance_metrics_enabled else 0
	_advance_active_colds(delta)
	if _performance_metrics_enabled:
		_performance_metrics["physics_calls"] = (
			int(_performance_metrics["physics_calls"]) + 1
		)
		_performance_metrics["physics_usec"] = (
			int(_performance_metrics["physics_usec"])
			+ maxi(Time.get_ticks_usec() - started_usec, 0)
		)


func _advance_active_colds(delta: float) -> void:
	_physics_clock += maxf(delta, 0.0)
	if (
		_latest_expiry_hint_dirty
		and not _expiry_heap.is_empty()
		and _expiry_heap[0].expires_at
			<= _physics_clock + EXPIRY_EPSILON
	):
		_recompute_latest_expiry_hint()
	# Same-frame volleys commonly produce a large cohort with one shared expiry.
	# The hint is a conservative upper bound: when it is due, every remaining
	# state is due and can be retired in O(n), avoiding an O(n log n) heap drain.
	if (
		not _expiry_heap.is_empty()
		and _latest_expiry_hint <= _physics_clock + EXPIRY_EPSILON
	):
		_increment_metric("heap_root_checks")
		_expire_all_current_states()
		return
	while not _expiry_heap.is_empty():
		_increment_metric("heap_root_checks")
		var state := _expiry_heap[0]
		var target: Object = state.target_ref.get_ref()
		if target == null or not is_instance_valid(target):
			_remove_state(state, false, false)
			continue
		if state.expires_at > _physics_clock + EXPIRY_EPSILON:
			break
		_remove_state(state, true, false)
		_increment_metric("expired_targets")
	if _expiry_heap.is_empty():
		_latest_expiry_hint = 0.0
		_latest_expiry_hint_dirty = false
		set_physics_process(false)


func _expire_all_current_states() -> void:
	var expiring_states: Array[ColdState] = []
	expiring_states.assign(_expiry_heap)
	_expiry_heap.clear()
	_states_by_target_id.clear()
	_latest_expiry_hint = 0.0
	_latest_expiry_hint_dirty = false
	set_physics_process(false)
	_add_metric("heap_updates", expiring_states.size())
	_increment_metric("bulk_expiry_passes")
	_add_metric("bulk_expiry_targets", expiring_states.size())
	var expired_target_count := 0
	for state in expiring_states:
		state.heap_index = -1
		var target: Object = state.target_ref.get_ref()
		if target == null or not is_instance_valid(target):
			continue
		expired_target_count += 1
		_notify_state_cleared(state)
	_add_metric("expired_targets", expired_target_count)


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


func _get_current_state(target: Object) -> ColdState:
	if target == null or not is_instance_valid(target):
		return null
	var state := _states_by_target_id.get(int(target.get_instance_id())) as ColdState
	if state == null:
		return null
	if state.target_ref.get_ref() != target:
		_remove_state(state, false, false)
		return null
	if state.expires_at <= _physics_clock + EXPIRY_EPSILON:
		_remove_state(state, true, false)
		_increment_metric("expired_targets")
		return null
	return state


func _get_stack_multiplier(stack_count: int) -> float:
	var stack_index := clampi(stack_count, 1, MAX_STACK_COUNT) - 1
	return float(STACK_MULTIPLIERS[stack_index])


func _push_heap(state: ColdState) -> void:
	state.heap_index = _expiry_heap.size()
	_expiry_heap.append(state)
	_increment_metric("heap_updates")
	_sift_up(state.heap_index)


func _remove_state(
	state: ColdState,
	notify_target: bool,
	manual_clear: bool
) -> void:
	if state == null:
		return
	if _states_by_target_id.get(state.target_id) == state:
		_states_by_target_id.erase(state.target_id)
	var removed_latest_expiry := (
		state.expires_at >= _latest_expiry_hint - EXPIRY_EPSILON
	)
	_remove_heap_at(state.heap_index)
	if manual_clear:
		_increment_metric("manually_cleared_targets")
	if notify_target:
		_notify_state_cleared(state)
	if _expiry_heap.is_empty():
		_latest_expiry_hint = 0.0
		_latest_expiry_hint_dirty = false
		set_physics_process(false)
	elif removed_latest_expiry:
		# Keep the old value as a safe upper bound. Recompute it only when the
		# next real expiry is due, so repeated deaths/exit clears cannot cause an
		# O(n^2) series of maximum scans.
		_latest_expiry_hint_dirty = true


func _notify_state_cleared(state: ColdState) -> void:
	var target: Object = state.target_ref.get_ref()
	if (
		target == null
		or not is_instance_valid(target)
		or not state.state_callback.is_valid()
	):
		return
	_increment_metric("callbacks")
	state.state_callback.call(0, 1.0)


func _remove_heap_at(index: int) -> void:
	if index < 0 or index >= _expiry_heap.size():
		return
	var removed_state := _expiry_heap[index]
	var last_state: ColdState = _expiry_heap.pop_back()
	_increment_metric("heap_updates")
	removed_state.heap_index = -1
	if index >= _expiry_heap.size():
		return
	_expiry_heap[index] = last_state
	last_state.heap_index = index
	_repair_heap_at(index)


func _repair_heap_at(index: int) -> void:
	if index < 0 or index >= _expiry_heap.size():
		return
	_increment_metric("heap_updates")
	var parent_index := (index - 1) >> 1
	if index > 0 and _is_earlier(_expiry_heap[index], _expiry_heap[parent_index]):
		_sift_up(index)
		return
	_sift_down(index)


func _sift_up(start_index: int) -> void:
	var index := start_index
	while index > 0:
		var parent_index := (index - 1) >> 1
		if not _is_earlier(_expiry_heap[index], _expiry_heap[parent_index]):
			break
		_swap_heap_entries(index, parent_index)
		index = parent_index
		_increment_metric("heap_repair_steps")


func _sift_down(start_index: int) -> void:
	var index := start_index
	while true:
		var left_index := index * 2 + 1
		if left_index >= _expiry_heap.size():
			return
		var right_index := left_index + 1
		var earlier_child_index := left_index
		if (
			right_index < _expiry_heap.size()
			and _is_earlier(
				_expiry_heap[right_index],
				_expiry_heap[left_index]
			)
		):
			earlier_child_index = right_index
		if not _is_earlier(_expiry_heap[earlier_child_index], _expiry_heap[index]):
			return
		_swap_heap_entries(index, earlier_child_index)
		index = earlier_child_index
		_increment_metric("heap_repair_steps")


func _swap_heap_entries(first_index: int, second_index: int) -> void:
	var first_state := _expiry_heap[first_index]
	var second_state := _expiry_heap[second_index]
	_expiry_heap[first_index] = second_state
	_expiry_heap[second_index] = first_state
	first_state.heap_index = second_index
	second_state.heap_index = first_index
	_increment_metric("heap_updates")


func _is_earlier(first: ColdState, second: ColdState) -> bool:
	if first.expires_at != second.expires_at:
		return first.expires_at < second.expires_at
	return first.target_id < second.target_id


func _record_latest_expiry_hint(expires_at: float) -> void:
	if expires_at > _latest_expiry_hint + EXPIRY_EPSILON:
		_latest_expiry_hint = expires_at
		_latest_expiry_hint_dirty = false
	elif (
		_latest_expiry_hint_dirty
		and expires_at >= _latest_expiry_hint - EXPIRY_EPSILON
	):
		# A new/extended live state now occupies the stale upper bound, making it
		# exact again without scanning the heap.
		_latest_expiry_hint = expires_at
		_latest_expiry_hint_dirty = false


func _recompute_latest_expiry_hint() -> void:
	var latest_expiry := 0.0
	for state in _expiry_heap:
		latest_expiry = maxf(latest_expiry, state.expires_at)
	_latest_expiry_hint = latest_expiry
	_latest_expiry_hint_dirty = false


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
