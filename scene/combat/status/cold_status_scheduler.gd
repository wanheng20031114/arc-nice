extends Node

# Cold applications only create a small number of distinct absolute deadlines
# in normal combat: every first hit starts at the current physics clock + 3 s,
# and every reapplication adds exactly 1 s. Indexing every target in the heap
# makes a same-frame volley pay O(targets * hits * log(targets)). Instead, this
# scheduler keeps one heap entry per distinct deadline and an intrusive O(1)
# target cohort behind it.
const INITIAL_DURATION_SECONDS := 3.0
const REAPPLICATION_EXTENSION_SECONDS := 1.0
const MAX_STACK_COUNT := 4
const STACK_MULTIPLIERS := [0.75, 0.60, 0.35, 0.10]
const EXPIRY_EPSILON := 0.000001
const EXPIRY_BUCKET_POOL_LIMIT := 128


class ColdState:
	var target_id := 0
	var target_ref: WeakRef = null
	var state_callback := Callable()
	var stack_count := 0
	var expires_at := 0.0
	var expiry_bucket = null
	var previous_state: ColdState = null
	var next_state: ColdState = null
	var expiry_update_queued := false


class ExpiryBucket:
	var expires_at := 0.0
	var first_state: ColdState = null
	var last_state: ColdState = null
	var state_count := 0
	var heap_index := -1
	# Empty buckets stay indexed until the next physics step. A same-frame volley
	# can then reuse its handful of +1 s deadlines instead of allocating and
	# pushing the same transient buckets once per target.
	var empty_cleanup_queued := false


var _physics_clock := 0.0
var _states_by_target_id: Dictionary[int, ColdState] = {}
var _buckets_by_expiry: Dictionary[float, ExpiryBucket] = {}
var _expiry_heap: Array[ExpiryBucket] = []
var _empty_bucket_cleanup_queue: Array[ExpiryBucket] = []
var _expiry_update_queue: Array[ColdState] = []
var _expiry_bucket_pool: Array[ExpiryBucket] = []
var _active_expiry_cohort_count := 0
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
	"deferred_expiry_updates": 0,
	"cohort_state_moves": 0,
	"empty_cohort_prunes": 0,
	"bucket_pool_reuses": 0,
	"peak_active_targets": 0,
	"peak_expiry_cohorts": 0,
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
		_increment_metric("expired_targets")
		# The clear callback is allowed to synchronously reapply cold. Treat that
		# replacement as the first hit and continue this outer application as the
		# next hit; never overwrite its dictionary entry and strand its cohort.
		state = _states_by_target_id.get(target_id) as ColdState
		if state != null and state.target_ref.get_ref() != target:
			_remove_state(state, false, false)
			state = null

	if state == null:
		state = ColdState.new()
		state.target_id = target_id
		state.target_ref = weakref(target)
		state.state_callback = state_callback
		state.stack_count = 1
		state.expires_at = _physics_clock + INITIAL_DURATION_SECONDS
		_states_by_target_id[target_id] = state
		_attach_state_to_expiry(state, state.expires_at)
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
		_queue_expiry_update(state)
		_increment_metric("deferred_expiry_updates")

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
	if _states_by_target_id.is_empty():
		_clear_expiry_index()
		set_physics_process(false)
		return
	var states_to_clear: Array[ColdState] = []
	states_to_clear.assign(_states_by_target_id.values())
	_states_by_target_id.clear()
	_clear_expiry_index()
	set_physics_process(false)
	for state in states_to_clear:
		_reset_state_expiry_links(state)
		_increment_metric("manually_cleared_targets")
		_notify_state_cleared_if_not_replaced(state)


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


func get_expiry_cohort_count() -> int:
	return _active_expiry_cohort_count


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
	snapshot["active_expiry_cohorts"] = _active_expiry_cohort_count
	snapshot["pooled_expiry_buckets"] = _expiry_bucket_pool.size()
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
	_flush_expiry_updates()
	_prune_empty_expiry_buckets()
	while not _expiry_heap.is_empty():
		_increment_metric("heap_root_checks")
		var bucket := _expiry_heap[0]
		if bucket.expires_at > _physics_clock + EXPIRY_EPSILON:
			break
		_expire_bucket(bucket)
	if _states_by_target_id.is_empty():
		_clear_expiry_index()
		set_physics_process(false)


func _expire_bucket(bucket: ExpiryBucket) -> void:
	if bucket == null or bucket.heap_index < 0:
		return
	_remove_bucket_from_index(bucket)
	if bucket.state_count > 0:
		_active_expiry_cohort_count -= 1
	_increment_metric("bulk_expiry_passes")
	_add_metric("bulk_expiry_targets", bucket.state_count)
	# Remove the whole cohort from the authoritative table before invoking any
	# callback. A callback may synchronously clear or reapply cold to another
	# target from this same deadline; it must observe that the old cohort has
	# already expired and must not be able to splice the list being traversed.
	var state := bucket.first_state
	while state != null:
		var next_state := state.next_state
		if _states_by_target_id.get(state.target_id) == state:
			_states_by_target_id.erase(state.target_id)
		state = next_state
	state = bucket.first_state
	while state != null:
		var next_state := state.next_state
		_reset_state_expiry_links(state)
		var target: Object = state.target_ref.get_ref()
		if target != null and is_instance_valid(target):
			_increment_metric("expired_targets")
			_notify_state_cleared_if_not_replaced(state)
		state = next_state
	_release_expiry_bucket(bucket)


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
		var replacement := (
			_states_by_target_id.get(int(target.get_instance_id()))
			as ColdState
		)
		if replacement != null and replacement.target_ref.get_ref() == target:
			return replacement
		return null
	return state


func _get_stack_multiplier(stack_count: int) -> float:
	var stack_index := clampi(stack_count, 1, MAX_STACK_COUNT) - 1
	return float(STACK_MULTIPLIERS[stack_index])


func _attach_state_to_expiry(state: ColdState, expires_at: float) -> void:
	var bucket := _get_or_create_expiry_bucket(expires_at)
	var was_empty := bucket.state_count == 0
	state.expiry_bucket = bucket
	state.previous_state = bucket.last_state
	state.next_state = null
	if bucket.last_state != null:
		bucket.last_state.next_state = state
	else:
		bucket.first_state = state
	bucket.last_state = state
	bucket.state_count += 1
	if was_empty:
		_active_expiry_cohort_count += 1
		_update_peak_expiry_cohorts()


func _detach_state_from_expiry(state: ColdState) -> void:
	var bucket := state.expiry_bucket as ExpiryBucket
	if bucket == null:
		return
	if state.previous_state != null:
		state.previous_state.next_state = state.next_state
	else:
		bucket.first_state = state.next_state
	if state.next_state != null:
		state.next_state.previous_state = state.previous_state
	else:
		bucket.last_state = state.previous_state
	bucket.state_count -= 1
	_reset_state_expiry_links(state)
	if bucket.state_count == 0:
		_active_expiry_cohort_count -= 1
		_queue_empty_expiry_bucket(bucket)


func _remove_state(
	state: ColdState,
	notify_target: bool,
	manual_clear: bool
) -> void:
	if state == null:
		return
	if _states_by_target_id.get(state.target_id) == state:
		_states_by_target_id.erase(state.target_id)
	_detach_state_from_expiry(state)
	if manual_clear:
		_increment_metric("manually_cleared_targets")
	if notify_target:
		_notify_state_cleared_if_not_replaced(state)
	if _states_by_target_id.is_empty():
		_clear_expiry_index()
		set_physics_process(false)


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


func _notify_state_cleared_if_not_replaced(state: ColdState) -> void:
	# An earlier callback from the same synchronous expiry/clear wave may have
	# reapplied cold to this target. Its new L1 callback is authoritative; a late
	# clear from the retired state must not overwrite that runtime multiplier.
	if _states_by_target_id.has(state.target_id):
		return
	_notify_state_cleared(state)


func _get_or_create_expiry_bucket(expires_at: float) -> ExpiryBucket:
	var bucket := _buckets_by_expiry.get(expires_at) as ExpiryBucket
	if bucket != null:
		return bucket
	if _expiry_bucket_pool.is_empty():
		bucket = ExpiryBucket.new()
	else:
		bucket = _expiry_bucket_pool.pop_back()
		_increment_metric("bucket_pool_reuses")
	bucket.expires_at = expires_at
	bucket.first_state = null
	bucket.last_state = null
	bucket.state_count = 0
	bucket.heap_index = -1
	bucket.empty_cleanup_queued = false
	_buckets_by_expiry[expires_at] = bucket
	_push_expiry_bucket(bucket)
	return bucket


func _queue_empty_expiry_bucket(bucket: ExpiryBucket) -> void:
	if bucket.empty_cleanup_queued:
		return
	bucket.empty_cleanup_queued = true
	_empty_bucket_cleanup_queue.append(bucket)


func _queue_expiry_update(state: ColdState) -> void:
	if state.expiry_update_queued:
		return
	state.expiry_update_queued = true
	_expiry_update_queue.append(state)


func _flush_expiry_updates() -> void:
	if _expiry_update_queue.is_empty():
		return
	for state in _expiry_update_queue:
		if not state.expiry_update_queued:
			continue
		state.expiry_update_queued = false
		if (
			_states_by_target_id.get(state.target_id) != state
			or state.expiry_bucket == null
		):
			continue
		var current_bucket := state.expiry_bucket as ExpiryBucket
		if absf(current_bucket.expires_at - state.expires_at) <= EXPIRY_EPSILON:
			continue
		_detach_state_from_expiry(state)
		_attach_state_to_expiry(state, state.expires_at)
		_increment_metric("cohort_state_moves")
	_expiry_update_queue.clear()


func _prune_empty_expiry_buckets() -> void:
	if _empty_bucket_cleanup_queue.is_empty():
		return
	for bucket in _empty_bucket_cleanup_queue:
		bucket.empty_cleanup_queued = false
		if bucket.heap_index < 0 or bucket.state_count > 0:
			continue
		_remove_bucket_from_index(bucket)
		_release_expiry_bucket(bucket)
		_increment_metric("empty_cohort_prunes")
	_empty_bucket_cleanup_queue.clear()


func _remove_bucket_from_index(bucket: ExpiryBucket) -> void:
	if _buckets_by_expiry.get(bucket.expires_at) == bucket:
		_buckets_by_expiry.erase(bucket.expires_at)
	_remove_expiry_heap_at(bucket.heap_index)


func _clear_expiry_index() -> void:
	for state in _expiry_update_queue:
		state.expiry_update_queued = false
	_expiry_update_queue.clear()
	for bucket in _expiry_heap:
		bucket.empty_cleanup_queued = false
		_release_expiry_bucket(bucket)
	_expiry_heap.clear()
	_buckets_by_expiry.clear()
	_empty_bucket_cleanup_queue.clear()
	_active_expiry_cohort_count = 0


func _release_expiry_bucket(bucket: ExpiryBucket) -> void:
	bucket.expires_at = 0.0
	bucket.first_state = null
	bucket.last_state = null
	bucket.state_count = 0
	bucket.heap_index = -1
	bucket.empty_cleanup_queued = false
	if _expiry_bucket_pool.size() < EXPIRY_BUCKET_POOL_LIMIT:
		_expiry_bucket_pool.append(bucket)


func _reset_state_expiry_links(state: ColdState) -> void:
	state.expiry_bucket = null
	state.previous_state = null
	state.next_state = null
	state.expiry_update_queued = false


func _push_expiry_bucket(bucket: ExpiryBucket) -> void:
	bucket.heap_index = _expiry_heap.size()
	_expiry_heap.append(bucket)
	_increment_metric("heap_updates")
	_sift_up(bucket.heap_index)


func _remove_expiry_heap_at(index: int) -> void:
	if index < 0 or index >= _expiry_heap.size():
		return
	var removed_bucket := _expiry_heap[index]
	var last_bucket: ExpiryBucket = _expiry_heap.pop_back()
	removed_bucket.heap_index = -1
	_increment_metric("heap_updates")
	if index >= _expiry_heap.size():
		return
	_expiry_heap[index] = last_bucket
	last_bucket.heap_index = index
	_repair_heap_at(index)


func _repair_heap_at(index: int) -> void:
	if index < 0 or index >= _expiry_heap.size():
		return
	_increment_metric("heap_updates")
	var parent_index := (index - 1) >> 1
	if (
		index > 0
		and _expiry_heap[index].expires_at
			< _expiry_heap[parent_index].expires_at
	):
		_sift_up(index)
		return
	_sift_down(index)


func _sift_up(start_index: int) -> void:
	var index := start_index
	while index > 0:
		var parent_index := (index - 1) >> 1
		if (
			_expiry_heap[index].expires_at
			>= _expiry_heap[parent_index].expires_at
		):
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
			and _expiry_heap[right_index].expires_at
				< _expiry_heap[left_index].expires_at
		):
			earlier_child_index = right_index
		if (
			_expiry_heap[earlier_child_index].expires_at
			>= _expiry_heap[index].expires_at
		):
			return
		_swap_heap_entries(index, earlier_child_index)
		index = earlier_child_index
		_increment_metric("heap_repair_steps")


func _swap_heap_entries(first_index: int, second_index: int) -> void:
	var first_bucket := _expiry_heap[first_index]
	var second_bucket := _expiry_heap[second_index]
	_expiry_heap[first_index] = second_bucket
	_expiry_heap[second_index] = first_bucket
	first_bucket.heap_index = second_index
	second_bucket.heap_index = first_index
	_increment_metric("heap_updates")


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


func _update_peak_expiry_cohorts() -> void:
	if not _performance_metrics_enabled:
		return
	_performance_metrics["peak_expiry_cohorts"] = maxi(
		int(_performance_metrics["peak_expiry_cohorts"]),
		_active_expiry_cohort_count
	)
