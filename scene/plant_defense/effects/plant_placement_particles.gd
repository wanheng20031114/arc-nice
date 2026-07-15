extends GPUParticles2D
class_name PlantPlacementParticles

const FULL_EMISSION_DURATION := 0.7
const EMISSION_FADE_DURATION := 0.9
const PARTICLE_TAIL_DURATION := 0.6
const REMOVAL_STARTED_SIGNAL: StringName = &"removal_started"

var _effect_tween: Tween = null
var _source: PlantDefense = null
var _effect_active := false


func _ready() -> void:
	one_shot = false
	emitting = false
	amount_ratio = 0.0


func on_pool_acquired(_generation: int) -> void:
	_reset_effect_state()


func on_pool_released(_generation: int) -> void:
	_reset_effect_state()


func restart_effect(source: PlantDefense, effect_scale: float) -> void:
	_reset_effect_state()
	_effect_active = true
	if source == null:
		push_error("PlantPlacementParticles requires a source plant.")
		_finish_effect()
		return

	_source = source
	scale = Vector2.ONE * maxf(effect_scale, 0.01)
	_connect_source_removal()

	amount_ratio = 1.0
	restart()
	emitting = true

	_effect_tween = create_tween()
	_effect_tween.tween_interval(FULL_EMISSION_DURATION)
	_effect_tween.tween_property(
		self,
		^"amount_ratio",
		0.0,
		EMISSION_FADE_DURATION
	).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	_effect_tween.tween_callback(_stop_emitting)
	_effect_tween.tween_interval(PARTICLE_TAIL_DURATION)
	_effect_tween.finished.connect(_finish_effect)


func _connect_source_removal() -> void:
	var callback := Callable(self, "_on_source_removal_started")
	if not _source.is_connected(REMOVAL_STARTED_SIGNAL, callback):
		_source.connect(REMOVAL_STARTED_SIGNAL, callback)


func _disconnect_source_removal() -> void:
	if _source == null or not is_instance_valid(_source):
		_source = null
		return
	var callback := Callable(self, "_on_source_removal_started")
	if _source.is_connected(REMOVAL_STARTED_SIGNAL, callback):
		_source.disconnect(REMOVAL_STARTED_SIGNAL, callback)
	_source = null


func _on_source_removal_started(_mode: int) -> void:
	if not _effect_active:
		return
	_disconnect_source_removal()
	_kill_effect_tween()
	_stop_emitting()
	_effect_tween = create_tween()
	_effect_tween.tween_interval(PARTICLE_TAIL_DURATION)
	_effect_tween.finished.connect(_finish_effect)


func _stop_emitting() -> void:
	amount_ratio = 0.0
	emitting = false


func _reset_effect_state() -> void:
	_kill_effect_tween()
	_disconnect_source_removal()
	_effect_active = false
	emitting = false
	amount_ratio = 0.0
	scale = Vector2.ONE


func _kill_effect_tween() -> void:
	if _effect_tween != null and _effect_tween.is_valid():
		_effect_tween.kill()
	_effect_tween = null


func _finish_effect() -> void:
	if not _effect_active:
		return
	_effect_tween = null
	_disconnect_source_removal()
	_effect_active = false
	_stop_emitting()
	if SessionObjectPool.release_to_owner(self):
		return
	queue_free()
