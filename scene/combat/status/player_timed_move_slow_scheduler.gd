extends Node

## Central authoritative timeline for short Player movement slows. One target
## owns one record and one source-family entry, so same-family applications
## refresh instead of stacking. The target callback receives the strongest
## (lowest) currently active multiplier.
const EXPIRY_EPSILON := 0.000001


class SlowState:
	var target_id := 0
	var target_ref: WeakRef = null
	var state_callback := Callable()
	var sources: Dictionary = {}


var _physics_clock := 0.0
var _states_by_target_id: Dictionary[int, SlowState] = {}


func _ready() -> void:
	set_physics_process(false)


func apply_slow(
	target: Object,
	state_callback: Callable,
	source_family: StringName,
	duration: float,
	multiplier: float
) -> bool:
	if (
		not _is_supported_target(target)
		or not state_callback.is_valid()
		or source_family == &""
		or duration <= 0.0
		or multiplier < 0.0
		or multiplier >= 1.0
	):
		return false

	var target_id := int(target.get_instance_id())
	var state := _states_by_target_id.get(target_id) as SlowState
	if state != null and state.target_ref.get_ref() != target:
		_states_by_target_id.erase(target_id)
		state = null
	if state == null:
		state = SlowState.new()
		state.target_id = target_id
		state.target_ref = weakref(target)
		_states_by_target_id[target_id] = state
	state.state_callback = state_callback
	state.sources[source_family] = {
		"expires_at": _physics_clock + duration,
		"multiplier": clampf(multiplier, 0.0, 1.0),
	}
	_notify_state(state)
	set_physics_process(true)
	return true


func clear_target(target: Object) -> bool:
	if target == null or not is_instance_valid(target):
		return false
	var target_id := int(target.get_instance_id())
	var state := _states_by_target_id.get(target_id) as SlowState
	if state == null or state.target_ref.get_ref() != target:
		return false
	_states_by_target_id.erase(target_id)
	_notify_cleared_if_not_replaced(state)
	if _states_by_target_id.is_empty():
		set_physics_process(false)
	return true


func clear_all() -> void:
	var states: Array[SlowState] = []
	states.assign(_states_by_target_id.values())
	_states_by_target_id.clear()
	set_physics_process(false)
	for state in states:
		_notify_cleared_if_not_replaced(state)


func has_slow(target: Object, source_family: StringName = &"") -> bool:
	var state := _get_current_state(target)
	if state == null:
		return false
	return source_family == &"" or state.sources.has(source_family)


func get_source_count(target: Object) -> int:
	var state := _get_current_state(target)
	return state.sources.size() if state != null else 0


func get_effective_multiplier(target: Object) -> float:
	var state := _get_current_state(target)
	return _get_strongest_multiplier(state) if state != null else 1.0


func get_source_snapshot(
	target: Object,
	source_family: StringName
) -> Dictionary:
	var state := _get_current_state(target)
	if state == null:
		return {}
	var source := state.sources.get(source_family, {}) as Dictionary
	if source.is_empty():
		return {}
	return {
		"time_left": maxf(
			float(source.get("expires_at", 0.0)) - _physics_clock,
			0.0
		),
		"multiplier": float(source.get("multiplier", 1.0)),
	}


func _physics_process(delta: float) -> void:
	_advance_active_slows(delta)


func _advance_active_slows(delta: float) -> void:
	_physics_clock += maxf(delta, 0.0)
	var target_ids: Array[int] = []
	target_ids.assign(_states_by_target_id.keys())
	for target_id in target_ids:
		var state := _states_by_target_id.get(target_id) as SlowState
		if state == null:
			continue
		var target: Object = state.target_ref.get_ref()
		if target == null or not is_instance_valid(target):
			_states_by_target_id.erase(target_id)
			continue
		var expired_sources: Array[StringName] = []
		for source_family_variant in state.sources:
			var source_family := StringName(source_family_variant)
			var source := state.sources.get(source_family, {}) as Dictionary
			if (
				source.is_empty()
				or float(source.get("expires_at", 0.0))
					<= _physics_clock + EXPIRY_EPSILON
			):
				expired_sources.append(source_family)
		for source_family in expired_sources:
			state.sources.erase(source_family)
		if state.sources.is_empty():
			_states_by_target_id.erase(target_id)
			_notify_cleared_if_not_replaced(state)
		elif not expired_sources.is_empty():
			_notify_state(state)
	if _states_by_target_id.is_empty():
		set_physics_process(false)


func _get_current_state(target: Object) -> SlowState:
	if target == null or not is_instance_valid(target):
		return null
	var target_id := int(target.get_instance_id())
	var state := _states_by_target_id.get(target_id) as SlowState
	if state == null:
		return null
	if state.target_ref.get_ref() != target:
		_states_by_target_id.erase(target_id)
		return null
	return state


func _get_strongest_multiplier(state: SlowState) -> float:
	var strongest := 1.0
	if state == null:
		return strongest
	for source in state.sources.values():
		var source_data := source as Dictionary
		strongest = minf(
			strongest,
			clampf(float(source_data.get("multiplier", 1.0)), 0.0, 1.0)
		)
	return strongest


func _notify_state(state: SlowState) -> void:
	if state == null or not state.state_callback.is_valid():
		return
	state.state_callback.call(_get_strongest_multiplier(state))


func _notify_cleared_if_not_replaced(state: SlowState) -> void:
	if state == null or _states_by_target_id.has(state.target_id):
		return
	var target: Object = state.target_ref.get_ref()
	if (
		target != null
		and is_instance_valid(target)
		and state.state_callback.is_valid()
	):
		state.state_callback.call(1.0)


func _is_supported_target(target: Object) -> bool:
	var player := target as Player
	return (
		player != null
		and not player.is_dead
		and not player.is_queued_for_deletion()
	)
