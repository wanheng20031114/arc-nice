extends PlantDefense
class_name VegetationStake

signal spread_runtime_state_changed(elapsed_seconds: float)

const RUNTIME_STATE_SCHEMA := 1
const TOTAL_SPREAD_SECONDS := 50.0
const AMBIENT_REVEAL_SECONDS := 0.15

@onready var health_bar: PlantHealthBar = $HealthBar
@onready var cell_border: MeshInstance2D = $CellBorder
@onready var top_glow: Sprite2D = $TopGlow
@onready var glow_motes: GPUParticles2D = $GlowMotes

var _spread_elapsed_at_sync: float = 0.0
var _spread_sync_ticks: float = 0.0
var _ambient_reveal_tween: Tween = null


func _on_setup_completed() -> void:
	_spread_elapsed_at_sync = 0.0
	_spread_sync_ticks = 0.0
	health_bar.setup(max_health, current_health)
	if not health_changed.is_connected(_on_health_changed):
		health_changed.connect(_on_health_changed)


func _on_construction_started() -> void:
	_stop_ambient_reveal_tween()
	cell_border.hide()
	top_glow.hide()
	glow_motes.emitting = false
	glow_motes.hide()


func _on_construction_finished(was_animated: bool) -> void:
	if not was_animated:
		_show_ambient_visuals_immediate()
		return

	cell_border.modulate.a = 0.0
	top_glow.modulate.a = 0.0
	glow_motes.modulate.a = 0.0
	cell_border.show()
	top_glow.show()
	glow_motes.show()
	glow_motes.emitting = true
	glow_motes.restart()
	_ambient_reveal_tween = create_tween().set_parallel(true)
	_ambient_reveal_tween.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_OUT)
	_ambient_reveal_tween.tween_property(
		cell_border,
		"modulate:a",
		1.0,
		AMBIENT_REVEAL_SECONDS
	)
	_ambient_reveal_tween.tween_property(
		top_glow,
		"modulate:a",
		1.0,
		AMBIENT_REVEAL_SECONDS
	)
	_ambient_reveal_tween.tween_property(
		glow_motes,
		"modulate:a",
		1.0,
		AMBIENT_REVEAL_SECONDS
	)


func _on_operational_started() -> void:
	_spread_elapsed_at_sync = 0.0
	_spread_sync_ticks = _now_seconds()


func _on_removal_started(_mode: RemovalMode) -> void:
	_stop_ambient_reveal_tween()
	health_bar.hide()
	cell_border.hide()
	top_glow.hide()
	glow_motes.emitting = false
	glow_motes.hide()
	_spread_elapsed_at_sync = 0.0
	_spread_sync_ticks = 0.0


func _on_health_changed(new_health: int, new_max_health: int) -> void:
	health_bar.set_health(new_health, new_max_health)


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
	if not is_operational:
		_spread_elapsed_at_sync = 0.0
		_spread_sync_ticks = 0.0
		spread_runtime_state_changed.emit(0.0)
		return
	_spread_elapsed_at_sync = received_elapsed
	_spread_sync_ticks = now_seconds
	spread_runtime_state_changed.emit(get_spread_elapsed_seconds())


func _show_ambient_visuals_immediate() -> void:
	_stop_ambient_reveal_tween()
	cell_border.modulate.a = 1.0
	top_glow.modulate.a = 1.0
	glow_motes.modulate.a = 1.0
	cell_border.show()
	top_glow.show()
	glow_motes.show()
	glow_motes.emitting = true


func _stop_ambient_reveal_tween() -> void:
	if _ambient_reveal_tween != null and _ambient_reveal_tween.is_valid():
		_ambient_reveal_tween.kill()
	_ambient_reveal_tween = null


func _now_seconds() -> float:
	return Time.get_ticks_msec() / 1000.0
