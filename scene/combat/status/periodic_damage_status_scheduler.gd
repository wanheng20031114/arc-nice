extends Node
class_name PeriodicDamageStatusScheduler

# Shared event-driven engine for periodic damage statuses. Dedicated autoload
# lanes select a stacking policy while reusing the same heap implementation.
const DEFAULT_TICK_INTERVAL_SECONDS := 1.0
const MIN_EVENT_DELAY_SECONDS := 0.000001
const DETACHED_HEAP_INDEX := -2
# Sparse staggered applications are common when attacks land across consecutive
# frames. Pop a small due set through the heap; switch to one linear cohort scan
# only after enough roots prove that a dense synchronized burst is in progress.
const SPARSE_DUE_POP_LIMIT := 32

enum TickPolicy {
	STRONGEST_SOURCE,
	ALL_SOURCES,
}


class SourceState:
	var source_family := StringName()
	# 同伤害来源的稳定排序键只在首次注册时构造，避免每个调度事件
	# 重复把 StringName 转成 String。
	var source_sort_key := ""
	var time_left := 0.0
	var tick_damage := 0
	var tick_time_left := DEFAULT_TICK_INTERVAL_SECONDS
	var tick_interval := DEFAULT_TICK_INTERVAL_SECONDS


class TargetState:
	var target_id := 0
	var target_ref: WeakRef = null
	var tick_callback := Callable()
	var state_callback := Callable()
	var tick_policy := TickPolicy.STRONGEST_SOURCE
	var sources: Array[SourceState] = []
	var active := true
	# 每个目标在最小堆中只占一个可原位更新的槽位。下一次有效跳伤
	# 或任一来源到期时，才需要重新遍历该目标的来源。
	var last_advance_clock := 0.0
	var next_event_at := 0.0
	var heap_index := -1


var _physics_clock := 0.0
var _active_targets: Dictionary = {}
var _event_heap: Array[TargetState] = []
# 同刻到期/跳伤在成批攻击中是常态。复用一个批缓冲，并在批前、批后
# 各执行一次 O(n) heapify，避免 300 个同刻目标逐个 O(log n) 下沉。
var _due_event_buffer: Array[TargetState] = []
var _due_event_count := 0
var _due_batch_uses_dense_scan := false
var _callback_event_clock := -1.0
var _performance_metrics_enabled := false
var _performance_metrics := {
	"physics_calls": 0,
	"physics_usec": 0,
	"target_steps": 0,
	"damage_ticks": 0,
	"heap_root_checks": 0,
	"heap_updates": 0,
	"heap_repair_steps": 0,
	"source_state_allocations": 0,
	"source_refreshes": 0,
	"sparse_due_pops": 0,
	"dense_due_scans": 0,
	"dense_candidates_scanned": 0,
}


func _ready() -> void:
	set_physics_process(false)


func apply_periodic_status(
	target: Object,
	tick_callback: Callable,
	source_family: StringName,
	duration: float,
	tick_damage: int,
	tick_interval: float,
	tick_policy: int,
	state_callback: Callable = Callable()
) -> bool:
	if (
		target == null
		or not is_instance_valid(target)
		or not tick_callback.is_valid()
		or source_family == &""
		or duration <= 0.0
		or tick_damage <= 0
		or tick_interval <= 0.0
		or tick_policy not in [
			TickPolicy.STRONGEST_SOURCE,
			TickPolicy.ALL_SOURCES,
		]
	):
		return false

	var target_id := int(target.get_instance_id())
	var application_clock := (
		_callback_event_clock
		if _callback_event_clock >= 0.0
		else _physics_clock
	)
	var target_state := _active_targets.get(target_id) as TargetState
	if (
		target_state != null
		and (
			not target_state.active
			or target_state.target_ref == null
			or target_state.target_ref.get_ref() != target
		)
	):
		_remove_target_state(target_state)
		target_state = null
	var should_notify_active := false
	if target_state == null:
		target_state = TargetState.new()
		target_state.target_id = target_id
		target_state.target_ref = weakref(target)
		target_state.last_advance_clock = application_clock
		target_state.tick_policy = tick_policy
		_active_targets[target_id] = target_state
		should_notify_active = state_callback.is_valid()
	else:
		# 通常这里没有到期事件；同步单个目标是为了让发生在两个调度
		# 事件之间的刷新从“本次命中”重新计时，而不是误吃此前的时间。
		_synchronize_target_to_clock(target_state, application_clock)
		if not target_state.active:
			var replacement := (
				_active_targets.get(target_id) as TargetState
			)
			if (
				replacement != null
				and replacement.active
				and replacement.target_ref != null
				and replacement.target_ref.get_ref() == target
			):
				target_state = replacement
			else:
				target_state = TargetState.new()
				target_state.target_id = target_id
				target_state.target_ref = weakref(target)
				target_state.last_advance_clock = application_clock
				target_state.tick_policy = tick_policy
				_active_targets[target_id] = target_state
				should_notify_active = state_callback.is_valid()
	if target_state.tick_policy != tick_policy:
		push_error("Periodic damage scheduler lane cannot mix tick policies.")
		return false
	if (
		target_state.tick_callback.is_valid()
		and target_state.tick_callback != tick_callback
	):
		push_error("A periodic damage lane cannot replace its active tick callback.")
		return false
	if (
		state_callback.is_valid()
		and target_state.state_callback.is_valid()
		and target_state.state_callback != state_callback
	):
		push_error("A periodic damage lane cannot replace its active state callback.")
		return false
	target_state.tick_callback = tick_callback
	if state_callback.is_valid():
		if not target_state.state_callback.is_valid():
			should_notify_active = true
		target_state.state_callback = state_callback

	# 同一伤害族共用 source_family；再次命中完整刷新持续时间和首跳
	# 倒计时。不同族是否同时跳伤由该通道的 TickPolicy 决定。刷新时
	# 原位复用状态，避免连续攻击在命中热路径制造短命对象。
	var source_state: SourceState = null
	for existing_source in target_state.sources:
		if existing_source.source_family == source_family:
			source_state = existing_source
			break
	if source_state == null:
		source_state = SourceState.new()
		source_state.source_family = source_family
		source_state.source_sort_key = String(source_family)
		target_state.sources.append(source_state)
		_increment_metric("source_state_allocations")
	else:
		_increment_metric("source_refreshes")
	source_state.time_left = maxf(duration, 0.05)
	source_state.tick_damage = maxi(tick_damage, 1)
	source_state.tick_interval = maxf(tick_interval, 0.05)
	source_state.tick_time_left = source_state.tick_interval

	_schedule_target_state(target_state)
	set_physics_process(true)
	if should_notify_active and target_state.state_callback.is_valid():
		target_state.state_callback.call(true)
	return true


func clear_target(target: Object) -> void:
	if target == null or not is_instance_valid(target):
		return
	var target_id := int(target.get_instance_id())
	var target_state := _active_targets.get(target_id) as TargetState
	if (
		target_state != null
		and target_state.target_ref != null
		and target_state.target_ref.get_ref() == target
	):
		_remove_target_state(target_state)


func clear_all() -> void:
	# 状态回调允许在清除时同步重新施加效果。先完整摘除旧状态，再通知
	# 目标；回调创建的新状态不得被旧批次继续清理或关闭视觉。
	var states_to_clear: Array[TargetState] = []
	states_to_clear.assign(_active_targets.values())
	for target_state in states_to_clear:
		target_state.active = false
		target_state.heap_index = -1
	for due_index in range(_due_event_count):
		var target_state := _due_event_buffer[due_index]
		target_state.active = false
		target_state.heap_index = -1
	_active_targets.clear()
	_event_heap.clear()
	set_physics_process(false)
	for target_state in states_to_clear:
		_notify_state_cleared_if_not_replaced(target_state)


func has_status(target: Object, source_family: StringName = &"") -> bool:
	var target_state := _get_target_state(target)
	if target_state == null:
		return false
	if source_family == &"":
		return not target_state.sources.is_empty()
	for source_state in target_state.sources:
		if source_state.source_family == source_family:
			return true
	return false


func get_active_target_count() -> int:
	return _active_targets.size()


func get_source_count(target: Object) -> int:
	var target_state := _get_target_state(target)
	return target_state.sources.size() if target_state != null else 0


func get_source_snapshot(
	target: Object,
	source_family: StringName
) -> Dictionary:
	if source_family == &"":
		return {}
	var target_state := _get_target_state(target)
	if target_state == null:
		return {}
	var strongest_state := _find_strongest_source(target_state)
	var snapshot_clock := (
		_callback_event_clock
		if _callback_event_clock >= 0.0
		else _physics_clock
	)
	var elapsed_since_advance := maxf(
		snapshot_clock - target_state.last_advance_clock,
		0.0
	)
	for source_state in target_state.sources:
		if source_state.source_family != source_family:
			continue
		var tick_time_left := source_state.tick_time_left
		if (
			target_state.tick_policy == TickPolicy.ALL_SOURCES
			or source_state == strongest_state
		):
			tick_time_left -= elapsed_since_advance
		return {
			"time_left": maxf(
				source_state.time_left - elapsed_since_advance,
				0.0
			),
			"tick_damage": source_state.tick_damage,
			"tick_interval": source_state.tick_interval,
			"tick_time_left": maxf(tick_time_left, 0.0),
		}
	return {}


func get_heap_size() -> int:
	return _event_heap.size()


func set_performance_metrics_enabled(enabled: bool) -> void:
	_performance_metrics_enabled = enabled
	reset_performance_metrics()


func reset_performance_metrics() -> void:
	for metric_key in _performance_metrics:
		_performance_metrics[metric_key] = 0


func get_performance_metrics(reset_after_read := false) -> Dictionary:
	var snapshot := _performance_metrics.duplicate()
	snapshot["active_targets"] = _active_targets.size()
	snapshot["heap_size"] = _event_heap.size()
	if reset_after_read:
		reset_performance_metrics()
	return snapshot


func _physics_process(delta: float) -> void:
	var started_usec := (
		Time.get_ticks_usec()
		if _performance_metrics_enabled
		else 0
	)
	_advance_active_statuses(maxf(delta, 0.0))
	if not _performance_metrics_enabled:
		return
	_performance_metrics["physics_calls"] = (
		int(_performance_metrics["physics_calls"]) + 1
	)
	_performance_metrics["physics_usec"] = (
		int(_performance_metrics["physics_usec"])
		+ maxi(Time.get_ticks_usec() - started_usec, 0)
	)


func _advance_active_statuses(delta: float) -> void:
	if delta <= 0.0 or _event_heap.is_empty():
		return
	_physics_clock += delta
	_process_due_target_events()


func _process_due_target_events() -> void:
	while not _event_heap.is_empty():
		_increment_metric("heap_root_checks")
		if (
			_event_heap[0].next_event_at
				> _physics_clock + MIN_EVENT_DELAY_SECONDS
		):
			break
		_collect_due_target_events()
		_sort_mixed_deadline_due_events()
		for due_index in range(_due_event_count):
			var target_state := _due_event_buffer[due_index]
			if not target_state.active:
				continue
			# A callback from an earlier member can refresh another detached due
			# target. Do not consume that target's newly scheduled future event.
			if (
				target_state.next_event_at
					> _physics_clock + MIN_EVENT_DELAY_SECONDS
			):
				_requeue_due_target(target_state)
				continue
			var target: Object = (
				target_state.target_ref.get_ref()
				if target_state.target_ref != null
				else null
			)
			if target == null or not is_instance_valid(target):
				_remove_target_state(target_state)
				continue
			_advance_target_to_scheduled_event(target_state)
			if target_state.active:
				_schedule_target_state(target_state)
			_requeue_due_target(target_state)
		_release_due_event_buffer_entries()
		if _due_batch_uses_dense_scan:
			_heapify_event_queue()
	if _event_heap.is_empty() and _due_event_count == 0:
		set_physics_process(false)


func _collect_due_target_events() -> void:
	_due_event_count = 0
	_due_batch_uses_dense_scan = false
	# In the staggered steady state, extracting only the due roots keeps work at
	# O(k log N) and never walks unrelated targets. The threshold also bounds the
	# proof cost before a synchronized cohort switches to the O(N) batch path.
	while (
		not _event_heap.is_empty()
		and _event_heap[0].next_event_at
			<= _physics_clock + MIN_EVENT_DELAY_SECONDS
		and _due_event_count < SPARSE_DUE_POP_LIMIT
	):
		var target_state := _event_heap[0]
		_remove_heap_at(0)
		target_state.heap_index = DETACHED_HEAP_INDEX
		_append_due_event(target_state)
		_increment_metric("sparse_due_pops")
	if (
		_event_heap.is_empty()
		or _event_heap[0].next_event_at
			> _physics_clock + MIN_EVENT_DELAY_SECONDS
	):
		return

	# More than the sparse limit is due at once. Compact every remaining due
	# member in one pass and heapify once; reinsertion after callbacks is also
	# batched, preserving the dense-cohort advantage.
	_due_batch_uses_dense_scan = true
	_increment_metric("dense_due_scans")
	if _performance_metrics_enabled:
		_performance_metrics["dense_candidates_scanned"] = (
			int(_performance_metrics["dense_candidates_scanned"])
			+ _event_heap.size()
		)
	var write_index := 0
	for read_index in range(_event_heap.size()):
		var target_state := _event_heap[read_index]
		if (
			target_state.next_event_at
				<= _physics_clock + MIN_EVENT_DELAY_SECONDS
		):
			target_state.heap_index = DETACHED_HEAP_INDEX
			_append_due_event(target_state)
			continue
		if write_index != read_index:
			_event_heap[write_index] = target_state
		target_state.heap_index = write_index
		write_index += 1
	_event_heap.resize(write_index)
	_heapify_event_queue()


func _append_due_event(target_state: TargetState) -> void:
	if _due_event_count >= _due_event_buffer.size():
		_due_event_buffer.append(target_state)
	else:
		_due_event_buffer[_due_event_count] = target_state
	_due_event_count += 1


func _sort_mixed_deadline_due_events() -> void:
	if not _due_batch_uses_dense_scan or _due_event_count <= 1:
		return
	var first_deadline := _due_event_buffer[0].next_event_at
	var has_mixed_deadlines := false
	for due_index in range(1, _due_event_count):
		if absf(
			_due_event_buffer[due_index].next_event_at
			- first_deadline
		) > MIN_EVENT_DELAY_SECONDS:
			has_mixed_deadlines = true
			break
	if not has_mixed_deadlines:
		return
	var ordered_events: Array[TargetState] = []
	ordered_events.resize(_due_event_count)
	for due_index in range(_due_event_count):
		ordered_events[due_index] = _due_event_buffer[due_index]
	ordered_events.sort_custom(_is_earlier)
	for due_index in range(_due_event_count):
		_due_event_buffer[due_index] = ordered_events[due_index]


func _requeue_due_target(target_state: TargetState) -> void:
	if (
		target_state == null
		or not target_state.active
		or target_state.heap_index != DETACHED_HEAP_INDEX
	):
		return
	if _due_batch_uses_dense_scan:
		target_state.heap_index = _event_heap.size()
		_event_heap.append(target_state)
		_increment_metric("heap_updates")
		return
	target_state.heap_index = -1
	_push_heap(target_state)


func _release_due_event_buffer_entries() -> void:
	# 保留批缓冲的高水位容量，但释放对象引用；常见同刻 cohort 在首轮
	# 扩容后不再每秒重建 Array backing store。
	for due_index in range(_due_event_count):
		_due_event_buffer[due_index] = null
	_due_event_count = 0


func _advance_target_to_scheduled_event(
	target_state: TargetState
) -> void:
	if target_state == null or not target_state.active:
		return
	var event_clock := minf(
		target_state.next_event_at,
		_physics_clock
	)
	# 标记当前槽位已经消费。回调中的同目标刷新可以据此从当前事件
	# 时刻重新排程，而不会再次消费同一个截止时间。
	target_state.next_event_at = INF
	_advance_target_to_clock(target_state, event_clock)


func _synchronize_target_to_clock(
	target_state: TargetState,
	target_clock: float
) -> void:
	while (
		target_state != null
		and target_state.active
		and target_state.next_event_at
			<= target_clock + MIN_EVENT_DELAY_SECONDS
	):
		_advance_target_to_scheduled_event(target_state)
		if target_state.active:
			_schedule_target_state(target_state)
	if target_state != null and target_state.active:
		_advance_target_to_clock(target_state, target_clock)


func _advance_target_to_clock(
	target_state: TargetState,
	target_clock: float
) -> void:
	if target_state == null or not target_state.active:
		return
	var elapsed := maxf(
		target_clock - target_state.last_advance_clock,
		0.0
	)
	if elapsed <= 0.0:
		return
	target_state.last_advance_clock = target_clock
	_advance_target_status(target_state, elapsed)


func _advance_target_status(
	target_state: TargetState,
	delta: float
) -> void:
	if target_state.tick_policy == TickPolicy.ALL_SOURCES:
		_advance_all_sources_status(target_state, delta)
		return
	_increment_metric("target_steps")

	# 先记录这段时间真正占用跳伤时钟的来源，再统一处理到期。较弱
	# 来源要在最强来源到期后才恢复自己的时钟，不能把两个事件之间
	# 的整段时间错误记到刚刚接班的来源上。
	var strongest_state := _find_strongest_source(target_state)
	if strongest_state == null:
		_remove_target_state(target_state)
		return
	strongest_state.tick_time_left -= delta
	var strongest_source_survived := true
	for source_index in range(
		target_state.sources.size() - 1,
		-1,
		-1
	):
		var source_state := target_state.sources[source_index]
		source_state.time_left -= delta
		if source_state.time_left <= MIN_EVENT_DELAY_SECONDS:
			if source_state == strongest_state:
				strongest_source_survived = false
			target_state.sources.remove_at(source_index)
	if target_state.sources.is_empty():
		_remove_target_state(target_state)
		return

	# 到期与跳伤同刻发生时仍然是到期优先；同时，新的最强来源从该
	# 精确事件时刻才开始推进，消除物理帧长或测试步长造成的提前跳伤。
	if not strongest_source_survived:
		return

	while strongest_state.tick_time_left <= MIN_EVENT_DELAY_SECONDS:
		strongest_state.tick_time_left += strongest_state.tick_interval
		if not target_state.tick_callback.is_valid():
			_remove_target_state(target_state)
			break
		var previous_callback_event_clock := _callback_event_clock
		_callback_event_clock = target_state.last_advance_clock
		target_state.tick_callback.call(
			strongest_state.source_family,
			strongest_state.tick_damage
		)
		_callback_event_clock = previous_callback_event_clock
		_increment_metric("damage_ticks")
		if not target_state.active:
			break
		if _find_strongest_source(target_state) != strongest_state:
			break


func _advance_all_sources_status(
	target_state: TargetState,
	delta: float
) -> void:
	_increment_metric("target_steps")
	for source_index in range(
		target_state.sources.size() - 1,
		-1,
		-1
	):
		var source_state := target_state.sources[source_index]
		source_state.time_left -= delta
		if source_state.time_left <= MIN_EVENT_DELAY_SECONDS:
			target_state.sources.remove_at(source_index)
			continue
		source_state.tick_time_left -= delta
	if target_state.sources.is_empty():
		_remove_target_state(target_state)
		return

	var due_sources := target_state.sources.duplicate()
	for source_state_variant in due_sources:
		var source_state := source_state_variant as SourceState
		while (
			target_state.active
			and target_state.sources.has(source_state)
			and source_state.tick_time_left <= MIN_EVENT_DELAY_SECONDS
		):
			source_state.tick_time_left += source_state.tick_interval
			if not target_state.tick_callback.is_valid():
				_remove_target_state(target_state)
				return
			var previous_callback_event_clock := _callback_event_clock
			_callback_event_clock = target_state.last_advance_clock
			target_state.tick_callback.call(
				source_state.source_family,
				source_state.tick_damage
			)
			_callback_event_clock = previous_callback_event_clock
			_increment_metric("damage_ticks")
			if not target_state.active:
				return


func _find_strongest_source(
	target_state: TargetState
) -> SourceState:
	var strongest_state: SourceState = null
	for source_state in target_state.sources:
		if (
			strongest_state == null
			or source_state.tick_damage > strongest_state.tick_damage
			or (
				source_state.tick_damage == strongest_state.tick_damage
				and source_state.source_sort_key
					< strongest_state.source_sort_key
			)
		):
			strongest_state = source_state
	return strongest_state


func _schedule_target_state(target_state: TargetState) -> void:
	if target_state == null or not target_state.active:
		return
	var next_delay := INF
	if target_state.tick_policy == TickPolicy.STRONGEST_SOURCE:
		var strongest_state := _find_strongest_source(target_state)
		if strongest_state == null:
			_remove_target_state(target_state)
			return
		next_delay = strongest_state.tick_time_left
		for source_state in target_state.sources:
			next_delay = minf(next_delay, source_state.time_left)
	else:
		for source_state in target_state.sources:
			next_delay = minf(
				next_delay,
				minf(source_state.time_left, source_state.tick_time_left)
			)
	target_state.next_event_at = (
		target_state.last_advance_clock
		+ maxf(next_delay, MIN_EVENT_DELAY_SECONDS)
	)
	if target_state.heap_index == DETACHED_HEAP_INDEX:
		return
	if target_state.heap_index < 0:
		_push_heap(target_state)
	else:
		_repair_heap_at(target_state.heap_index)


func _get_target_state(target: Object) -> TargetState:
	if target == null or not is_instance_valid(target):
		return null
	var target_state := (
		_active_targets.get(int(target.get_instance_id()))
		as TargetState
	)
	if target_state == null:
		return null
	if (
		not target_state.active
		or target_state.target_ref == null
		or target_state.target_ref.get_ref() != target
	):
		_remove_target_state(target_state)
		return null
	return target_state


func _remove_target_state(target_state: TargetState) -> void:
	if target_state == null:
		return
	target_state.active = false
	if _active_targets.get(target_state.target_id) == target_state:
		_active_targets.erase(target_state.target_id)
	if target_state.heap_index == DETACHED_HEAP_INDEX:
		target_state.heap_index = -1
	else:
		_remove_heap_at(target_state.heap_index)
	if _event_heap.is_empty() and _due_event_count == 0:
		set_physics_process(false)
	_notify_state_cleared_if_not_replaced(target_state)


func _notify_state_cleared_if_not_replaced(
	target_state: TargetState
) -> void:
	if (
		target_state == null
		or _active_targets.has(target_state.target_id)
		or not target_state.state_callback.is_valid()
	):
		return
	var target: Object = (
		target_state.target_ref.get_ref()
		if target_state.target_ref != null
		else null
	)
	if target == null or not is_instance_valid(target):
		return
	target_state.state_callback.call(false)


func _push_heap(target_state: TargetState) -> void:
	target_state.heap_index = _event_heap.size()
	_event_heap.append(target_state)
	_increment_metric("heap_updates")
	_sift_up(target_state.heap_index)


func _remove_heap_at(index: int) -> void:
	if index < 0 or index >= _event_heap.size():
		return
	var removed_state := _event_heap[index]
	var last_state: TargetState = _event_heap.pop_back()
	removed_state.heap_index = -1
	_increment_metric("heap_updates")
	if index >= _event_heap.size():
		return
	_event_heap[index] = last_state
	last_state.heap_index = index
	_repair_heap_at(index)


func _repair_heap_at(index: int) -> void:
	if index < 0 or index >= _event_heap.size():
		return
	_increment_metric("heap_updates")
	var parent_index := (index - 1) >> 1
	if (
		index > 0
		and _is_earlier(
			_event_heap[index],
			_event_heap[parent_index]
		)
	):
		_sift_up(index)
		return
	_sift_down(index)


func _sift_up(start_index: int) -> void:
	var index := start_index
	while index > 0:
		var parent_index := (index - 1) >> 1
		if not _is_earlier(_event_heap[index], _event_heap[parent_index]):
			break
		_swap_heap_entries(index, parent_index)
		index = parent_index
		_increment_metric("heap_repair_steps")


func _sift_down(start_index: int) -> void:
	var index := start_index
	while true:
		var left_index := index * 2 + 1
		if left_index >= _event_heap.size():
			return
		var right_index := left_index + 1
		var earlier_child_index := left_index
		if (
			right_index < _event_heap.size()
			and _is_earlier(
				_event_heap[right_index],
				_event_heap[left_index]
			)
		):
			earlier_child_index = right_index
		if not _is_earlier(
			_event_heap[earlier_child_index],
			_event_heap[index]
		):
			return
		_swap_heap_entries(index, earlier_child_index)
		index = earlier_child_index
		_increment_metric("heap_repair_steps")


func _swap_heap_entries(first_index: int, second_index: int) -> void:
	var first_state := _event_heap[first_index]
	var second_state := _event_heap[second_index]
	_event_heap[first_index] = second_state
	_event_heap[second_index] = first_state
	first_state.heap_index = second_index
	second_state.heap_index = first_index
	_increment_metric("heap_updates")


func _heapify_event_queue() -> void:
	for index in range((_event_heap.size() >> 1) - 1, -1, -1):
		_sift_down(index)


func _is_earlier(
	first_state: TargetState,
	second_state: TargetState
) -> bool:
	if first_state.next_event_at != second_state.next_event_at:
		return first_state.next_event_at < second_state.next_event_at
	return first_state.target_id < second_state.target_id


func _increment_metric(metric_key: String) -> void:
	if not _performance_metrics_enabled:
		return
	_performance_metrics[metric_key] = (
		int(_performance_metrics[metric_key]) + 1
	)
