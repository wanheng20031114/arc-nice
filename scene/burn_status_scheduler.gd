extends Node

# 与 Enemy 的既有燃烧规则保持一致：固定每秒一次法术跳伤。
const TICK_INTERVAL_SECONDS := 1.0
const MIN_EVENT_DELAY_SECONDS := 0.000001
const DETACHED_HEAP_INDEX := -2
# Sparse staggered burns are common when projectiles land across consecutive
# frames. Pop a small due set through the heap; switch to one linear cohort scan
# only after enough roots prove that a dense synchronized burst is in progress.
const SPARSE_DUE_POP_LIMIT := 32


class BurnSourceState:
	var source_family := StringName()
	# 同伤害来源的稳定排序键只在首次注册时构造，避免每个调度事件
	# 重复把 StringName 转成 String。
	var source_sort_key := ""
	var time_left := 0.0
	var tick_damage := 0
	var tick_time_left := TICK_INTERVAL_SECONDS


class BurnTargetState:
	var target_id := 0
	var target_ref: WeakRef = null
	var tick_callback := Callable()
	var sources: Array[BurnSourceState] = []
	var active := true
	# 每个目标在最小堆中只占一个可原位更新的槽位。只有最强来源的
	# 下一跳或任一来源到期时，才需要重新遍历该目标的来源。
	var last_advance_clock := 0.0
	var next_event_at := 0.0
	var heap_index := -1


var _physics_clock := 0.0
var _active_targets: Dictionary = {}
var _event_heap: Array[BurnTargetState] = []
# 同刻到期/跳伤在火球齐射中是常态。复用一个批缓冲，并在批前、批后
# 各执行一次 O(n) heapify，避免 300 个同刻目标逐个 O(log n) 下沉。
var _due_event_buffer: Array[BurnTargetState] = []
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


func apply_burn(
	target: Object,
	tick_callback: Callable,
	source_family: StringName,
	duration: float,
	tick_damage: int
) -> bool:
	if (
		target == null
		or not is_instance_valid(target)
		or not tick_callback.is_valid()
		or source_family == &""
		or duration <= 0.0
		or tick_damage <= 0
	):
		return false

	var target_id := int(target.get_instance_id())
	var application_clock := (
		_callback_event_clock
		if _callback_event_clock >= 0.0
		else _physics_clock
	)
	var target_state := _active_targets.get(target_id) as BurnTargetState
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
	if target_state == null:
		target_state = BurnTargetState.new()
		target_state.target_id = target_id
		target_state.target_ref = weakref(target)
		target_state.last_advance_clock = application_clock
		_active_targets[target_id] = target_state
	else:
		# 通常这里没有到期事件；同步单个目标是为了让发生在两个调度
		# 事件之间的刷新从“本次命中”重新计时，而不是误吃此前的时间。
		_synchronize_target_to_clock(target_state, application_clock)
		if not target_state.active:
			target_state = BurnTargetState.new()
			target_state.target_id = target_id
			target_state.target_ref = weakref(target)
			target_state.last_advance_clock = application_clock
			_active_targets[target_id] = target_state
	target_state.tick_callback = tick_callback

	# 同一齐射的三枚火球共用 source_family。再次命中会完整刷新持续时间
	# 和首跳倒计时，而不是叠成三份独立燃烧。刷新时原位复用状态，避免
	# 三连发以及后续补射在命中热路径持续制造短命 RefCounted 对象。
	var source_state: BurnSourceState = null
	for existing_source in target_state.sources:
		if existing_source.source_family == source_family:
			source_state = existing_source
			break
	if source_state == null:
		source_state = BurnSourceState.new()
		source_state.source_family = source_family
		source_state.source_sort_key = String(source_family)
		target_state.sources.append(source_state)
		_increment_metric("source_state_allocations")
	else:
		_increment_metric("source_refreshes")
	source_state.time_left = maxf(duration, 0.05)
	source_state.tick_damage = maxi(tick_damage, 1)
	source_state.tick_time_left = TICK_INTERVAL_SECONDS

	_schedule_target_state(target_state)
	set_physics_process(true)
	return true


func clear_target(target: Object) -> void:
	if target == null or not is_instance_valid(target):
		return
	var target_id := int(target.get_instance_id())
	var target_state := _active_targets.get(target_id) as BurnTargetState
	if (
		target_state != null
		and target_state.target_ref != null
		and target_state.target_ref.get_ref() == target
	):
		_remove_target_state(target_state)


func clear_all() -> void:
	# tick_callback 允许在跳伤期间触发死亡并重入 clear_all。先标记旧
	# 状态失效，确保当前 catch-up 循环不会在清空后继续结算伤害。
	for target_state in _event_heap:
		target_state.active = false
		target_state.heap_index = -1
	for due_index in range(_due_event_count):
		var target_state := _due_event_buffer[due_index]
		target_state.active = false
		target_state.heap_index = -1
	_active_targets.clear()
	_event_heap.clear()
	set_physics_process(false)


func has_burn(target: Object, source_family: StringName = &"") -> bool:
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
	var elapsed_since_advance := maxf(
		_physics_clock - target_state.last_advance_clock,
		0.0
	)
	for source_state in target_state.sources:
		if source_state.source_family != source_family:
			continue
		var tick_time_left := source_state.tick_time_left
		if source_state == strongest_state:
			tick_time_left -= elapsed_since_advance
		return {
			"time_left": maxf(
				source_state.time_left - elapsed_since_advance,
				0.0
			),
			"tick_damage": source_state.tick_damage,
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
	_advance_active_burns(maxf(delta, 0.0))
	if not _performance_metrics_enabled:
		return
	_performance_metrics["physics_calls"] = (
		int(_performance_metrics["physics_calls"]) + 1
	)
	_performance_metrics["physics_usec"] = (
		int(_performance_metrics["physics_usec"])
		+ maxi(Time.get_ticks_usec() - started_usec, 0)
	)


func _advance_active_burns(delta: float) -> void:
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


func _append_due_event(target_state: BurnTargetState) -> void:
	if _due_event_count >= _due_event_buffer.size():
		_due_event_buffer.append(target_state)
	else:
		_due_event_buffer[_due_event_count] = target_state
	_due_event_count += 1


func _requeue_due_target(target_state: BurnTargetState) -> void:
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
	target_state: BurnTargetState
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
	target_state: BurnTargetState,
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
	target_state: BurnTargetState,
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
	_advance_target_burn(target_state, elapsed)


func _advance_target_burn(
	target_state: BurnTargetState,
	delta: float
) -> void:
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
		strongest_state.tick_time_left += TICK_INTERVAL_SECONDS
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


func _find_strongest_source(
	target_state: BurnTargetState
) -> BurnSourceState:
	var strongest_state: BurnSourceState = null
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


func _schedule_target_state(target_state: BurnTargetState) -> void:
	if target_state == null or not target_state.active:
		return
	var strongest_state := _find_strongest_source(target_state)
	if strongest_state == null:
		_remove_target_state(target_state)
		return
	var next_delay := strongest_state.tick_time_left
	for source_state in target_state.sources:
		next_delay = minf(next_delay, source_state.time_left)
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


func _get_target_state(target: Object) -> BurnTargetState:
	if target == null or not is_instance_valid(target):
		return null
	var target_state := (
		_active_targets.get(int(target.get_instance_id()))
		as BurnTargetState
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


func _remove_target_state(target_state: BurnTargetState) -> void:
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


func _push_heap(target_state: BurnTargetState) -> void:
	target_state.heap_index = _event_heap.size()
	_event_heap.append(target_state)
	_increment_metric("heap_updates")
	_sift_up(target_state.heap_index)


func _remove_heap_at(index: int) -> void:
	if index < 0 or index >= _event_heap.size():
		return
	var removed_state := _event_heap[index]
	var last_state: BurnTargetState = _event_heap.pop_back()
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
	first_state: BurnTargetState,
	second_state: BurnTargetState
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
