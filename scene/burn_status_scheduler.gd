extends Node

# 与 Enemy 的既有燃烧规则保持一致：固定每秒一次法术跳伤。
const TICK_INTERVAL_SECONDS := 1.0


class BurnSourceState:
	var source_family := StringName()
	var time_left := 0.0
	var tick_damage := 0
	var tick_time_left := TICK_INTERVAL_SECONDS


class BurnTargetState:
	var target_id := 0
	var target_ref: WeakRef = null
	var tick_callback := Callable()
	var sources: Array[BurnSourceState] = []
	var active := true


var _active_targets: Dictionary = {}
var _active_target_states: Array[BurnTargetState] = []
var _is_advancing := false
var _performance_metrics_enabled := false
var _performance_metrics := {
	"physics_calls": 0,
	"physics_usec": 0,
	"target_steps": 0,
	"damage_ticks": 0,
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
	var target_state := _active_targets.get(target_id) as BurnTargetState
	if target_state == null:
		target_state = BurnTargetState.new()
		target_state.target_id = target_id
		target_state.target_ref = weakref(target)
		_active_targets[target_id] = target_state
		_active_target_states.append(target_state)
	target_state.tick_callback = tick_callback

	# 同一齐射的三枚火球共用 source_family。再次命中会完整刷新持续时间
	# 和首跳倒计时，而不是叠成三份独立燃烧。
	var source_state := BurnSourceState.new()
	source_state.source_family = source_family
	source_state.time_left = maxf(duration, 0.05)
	source_state.tick_damage = maxi(tick_damage, 1)
	source_state.tick_time_left = TICK_INTERVAL_SECONDS
	var replaced_existing_source := false
	for source_index in range(target_state.sources.size()):
		if (
			target_state.sources[source_index].source_family
			== source_family
		):
			target_state.sources[source_index] = source_state
			replaced_existing_source = true
			break
	if not replaced_existing_source:
		target_state.sources.append(source_state)
	set_physics_process(true)
	return true


func clear_target(target: Object) -> void:
	if target == null:
		return
	var target_id := int(target.get_instance_id())
	var target_state := _active_targets.get(target_id) as BurnTargetState
	if target_state != null:
		_deactivate_target(target_state)
	if _active_targets.is_empty():
		set_physics_process(false)
		if not _is_advancing:
			_active_target_states.clear()


func clear_all() -> void:
	_active_targets.clear()
	_active_target_states.clear()
	set_physics_process(false)


func has_burn(target: Object, source_family: StringName = &"") -> bool:
	if target == null:
		return false
	var target_state := (
		_active_targets.get(int(target.get_instance_id()))
		as BurnTargetState
	)
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
	if target == null:
		return 0
	var target_state := (
		_active_targets.get(int(target.get_instance_id()))
		as BurnTargetState
	)
	return target_state.sources.size() if target_state != null else 0


func get_source_snapshot(
	target: Object,
	source_family: StringName
) -> Dictionary:
	if target == null or source_family == &"":
		return {}
	var target_state := (
		_active_targets.get(int(target.get_instance_id()))
		as BurnTargetState
	)
	if target_state == null:
		return {}
	for source_state in target_state.sources:
		if source_state.source_family != source_family:
			continue
		return {
			"time_left": source_state.time_left,
			"tick_damage": source_state.tick_damage,
			"tick_time_left": source_state.tick_time_left,
		}
	return {}


func set_performance_metrics_enabled(enabled: bool) -> void:
	_performance_metrics_enabled = enabled
	reset_performance_metrics()


func reset_performance_metrics() -> void:
	for metric_key in _performance_metrics:
		_performance_metrics[metric_key] = 0


func get_performance_metrics(reset_after_read := false) -> Dictionary:
	var snapshot := _performance_metrics.duplicate()
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
	if delta <= 0.0 or _active_targets.is_empty():
		return
	_is_advancing = true
	var has_inactive_states := false
	for target_state in _active_target_states:
		if not target_state.active:
			has_inactive_states = true
			continue
		var target: Object = (
			target_state.target_ref.get_ref()
			if target_state.target_ref != null
			else null
		)
		if (
			target == null
			or not is_instance_valid(target)
		):
			_deactivate_target(target_state)
			has_inactive_states = true
			continue
		_advance_target_burn(target_state, delta)
		if not target_state.active:
			has_inactive_states = true

	_is_advancing = false
	if has_inactive_states:
		_compact_inactive_target_states()

	if _active_targets.is_empty():
		set_physics_process(false)


func _advance_target_burn(
	target_state: BurnTargetState,
	delta: float
) -> void:
	if _performance_metrics_enabled:
		_performance_metrics["target_steps"] = (
			int(_performance_metrics["target_steps"]) + 1
		)

	# 与 Enemy 状态系统一样，先统一处理到期，再决定本帧跳伤。这样在
	# duration 的精确边界不会因 Dictionary 顺序不同而多结算一次。
	var strongest_family := StringName()
	var strongest_state: BurnSourceState = null
	for source_index in range(
		target_state.sources.size() - 1,
		-1,
		-1
	):
		var source_state := target_state.sources[source_index]
		source_state.time_left -= delta
		if source_state.time_left <= 0.0:
			target_state.sources.remove_at(source_index)
			continue
		var source_family := source_state.source_family
		if (
			strongest_state == null
			or source_state.tick_damage > strongest_state.tick_damage
			or (
				source_state.tick_damage == strongest_state.tick_damage
				and String(source_family) < String(strongest_family)
			)
		):
			strongest_family = source_family
			strongest_state = source_state
	if target_state.sources.is_empty():
		_deactivate_target(target_state)
		return

	if strongest_state == null:
		_deactivate_target(target_state)
		return

	# 多个来源同时存在时只推进最高等级燃烧的跳伤时钟；较弱来源的
	# 持续时间照常流逝，避免叠层爆发。
	strongest_state.tick_time_left -= delta
	while strongest_state.tick_time_left <= 0.0:
		strongest_state.tick_time_left += TICK_INTERVAL_SECONDS
		if not target_state.tick_callback.is_valid():
			_deactivate_target(target_state)
			break
		target_state.tick_callback.call(
			strongest_family,
			strongest_state.tick_damage
		)
		if _performance_metrics_enabled:
			_performance_metrics["damage_ticks"] = (
				int(_performance_metrics["damage_ticks"]) + 1
			)
		if not target_state.active:
			break


func _deactivate_target(target_state: BurnTargetState) -> void:
	if target_state == null or not target_state.active:
		return
	target_state.active = false
	if _active_targets.get(target_state.target_id) == target_state:
		_active_targets.erase(target_state.target_id)


func _compact_inactive_target_states() -> void:
	var write_index := 0
	for read_index in range(_active_target_states.size()):
		var target_state := _active_target_states[read_index]
		if not target_state.active:
			continue
		if write_index != read_index:
			_active_target_states[write_index] = target_state
		write_index += 1
	_active_target_states.resize(write_index)
