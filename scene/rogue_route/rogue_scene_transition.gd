extends CanvasLayer
class_name RogueSceneTransition

const COVER_DURATION_SECONDS := 0.32
const REVEAL_DURATION_SECONDS := 0.38

@onready var cover_rect: ColorRect = $Cover
@onready var cover_audio: AudioStreamPlayer = $CoverAudio
@onready var reveal_audio: AudioStreamPlayer = $RevealAudio

var progress := 0.0
var _transition_tween: Tween = null
var _transition_serial := 0


func _ready() -> void:
	hide_immediately()


func cover() -> bool:
	_stop_transition_tween()
	_transition_serial += 1
	var serial := _transition_serial
	visible = true
	cover_rect.mouse_filter = Control.MOUSE_FILTER_STOP
	if progress >= 0.999:
		_set_progress(1.0)
		return true
	cover_audio.play()
	var duration := maxf(
		COVER_DURATION_SECONDS * (1.0 - progress),
		0.01
	)
	_transition_tween = create_tween()
	_transition_tween.tween_method(
		_set_progress,
		progress,
		1.0,
		duration
	).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	await get_tree().create_timer(duration, true).timeout
	if serial != _transition_serial:
		return false
	_transition_tween = null
	_set_progress(1.0)
	return true


func reveal() -> bool:
	_stop_transition_tween()
	_transition_serial += 1
	var serial := _transition_serial
	visible = true
	cover_rect.mouse_filter = Control.MOUSE_FILTER_STOP
	_set_progress(1.0)
	reveal_audio.play()
	_transition_tween = create_tween()
	_transition_tween.tween_method(
		_set_progress,
		1.0,
		0.0,
		REVEAL_DURATION_SECONDS
	).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	await get_tree().create_timer(REVEAL_DURATION_SECONDS, true).timeout
	if serial != _transition_serial:
		return false
	_transition_tween = null
	_set_progress(0.0)
	cover_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	visible = false
	return true


func hide_immediately() -> void:
	_transition_serial += 1
	_stop_transition_tween()
	cover_audio.stop()
	reveal_audio.stop()
	_set_progress(0.0)
	if is_node_ready():
		cover_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	visible = false


func is_covered() -> bool:
	return visible and progress >= 0.999


func _stop_transition_tween() -> void:
	if _transition_tween == null:
		return
	_transition_tween.kill()
	_transition_tween = null


func _set_progress(value: float) -> void:
	progress = clampf(value, 0.0, 1.0)
	if cover_rect != null:
		cover_rect.set_instance_shader_parameter(&"cover_progress", progress)
