extends RefCounted

const StepClock := preload("res://scene/combat/simulation/enemy_simulation_step_clock.gd")

var _clock: StepClock
var _remaining := 0.0
var _observed_tick := 0
var _epoch_index := 0
var _awaiting_first_event := false


func set_remaining(value: float) -> void:
	_remaining = maxf(value, 0.0)
	if _clock != null:
		_observed_tick = _clock.tick


func get_remaining() -> float:
	_synchronize()
	return _remaining


func bind_clock(clock: StepClock) -> void:
	if _clock == clock:
		return
	detach_clock()
	_clock = clock
	_observed_tick = clock.tick
	_epoch_index = maxi(clock.epoch_ticks.size() - 1, 0)
	# Registration and resumption have an activation fence. Only the first
	# admitted event establishes its first eligible quantum, never wall frames.
	_awaiting_first_event = true


func detach_clock() -> void:
	_synchronize()
	_clock = null
	_awaiting_first_event = false


func advance_event(step_delta: float) -> void:
	if _clock == null:
		_remaining = maxf(_remaining - maxf(step_delta, 0.0), 0.0)
		return
	if _awaiting_first_event:
		_observed_tick = _clock.tick - 1
		_awaiting_first_event = false
	_synchronize()


func get_event_delta(authored_delta: float) -> float:
	return _clock.delta if _clock != null else authored_delta


func _synchronize() -> void:
	if _clock == null or _awaiting_first_event or _observed_tick >= _clock.tick:
		return
	if _remaining > 0.0:
		var next_tick := _observed_tick + 1
		while next_tick <= _clock.tick and _remaining > 0.0:
			while (
				_epoch_index + 1 < _clock.epoch_ticks.size()
				and _clock.epoch_ticks[_epoch_index + 1] <= next_tick
			):
				_epoch_index += 1
			var last_tick := _clock.tick
			if _epoch_index + 1 < _clock.epoch_ticks.size():
				last_tick = mini(last_tick, _clock.epoch_ticks[_epoch_index + 1] - 1)
			var step_delta := _clock.epoch_deltas[_epoch_index]
			# Multiplication followed by one subtraction changes the exact zero
			# edge. Preserve the authored repeated floating-point operations.
			for _step in range(next_tick, last_tick + 1):
				_remaining = maxf(_remaining - step_delta, 0.0)
				if _remaining <= 0.0:
					break
			next_tick = last_tick + 1
	_observed_tick = _clock.tick
