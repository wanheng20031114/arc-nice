extends PlantDefense
class_name VegetationStake

signal spread_runtime_state_changed(elapsed_seconds: float)

const RUNTIME_STATE_SCHEMA := 1
const TOTAL_SPREAD_SECONDS := 50.0

var _spread_elapsed_at_sync: float = 0.0
var _spread_sync_ticks: float = 0.0


func _on_setup_completed() -> void:
	_spread_elapsed_at_sync = 0.0
	_spread_sync_ticks = _now_seconds()


func get_spread_elapsed_seconds() -> float:
	if _spread_sync_ticks <= 0.0:
		return 0.0
	return clampf(
		_spread_elapsed_at_sync + _now_seconds() - _spread_sync_ticks,
		0.0,
		TOTAL_SPREAD_SECONDS
	)


func export_multiplayer_runtime_state() -> Dictionary:
	return {
		"schema": RUNTIME_STATE_SCHEMA,
		"spread_elapsed_seconds": get_spread_elapsed_seconds(),
	}


func apply_multiplayer_runtime_state(
	state: Dictionary,
	mapped_sample_time: float
) -> void:
	if int(state.get("schema", 0)) != RUNTIME_STATE_SCHEMA:
		return
	var now_seconds := _now_seconds()
	var sample_time := (
		minf(mapped_sample_time, now_seconds)
		if mapped_sample_time > 0.0
		else now_seconds
	)
	var received_elapsed := clampf(
		float(state.get("spread_elapsed_seconds", 0.0))
		+ maxf(now_seconds - sample_time, 0.0),
		0.0,
		TOTAL_SPREAD_SECONDS
	)
	if received_elapsed + 0.001 < get_spread_elapsed_seconds():
		return
	_spread_elapsed_at_sync = received_elapsed
	_spread_sync_ticks = now_seconds
	spread_runtime_state_changed.emit(get_spread_elapsed_seconds())


func _now_seconds() -> float:
	return Time.get_ticks_msec() / 1000.0
