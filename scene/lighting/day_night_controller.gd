extends CanvasModulate
class_name DayNightController

signal night_factor_changed(night_factor: float)
signal transition_completed(is_night: bool)

const REFERENCE_NIGHT_COLOR := Color(
	87.0 / 255.0,
	123.0 / 255.0,
	158.0 / 255.0,
	1.0
)

@export var day_color := Color.WHITE
@export var night_color := REFERENCE_NIGHT_COLOR
@export_range(0.0, 10.0, 0.1, "or_greater") var transition_duration := 5.0

var night_factor := 0.0
var _target_night_factor := 0.0
var _transition_tween: Tween = null


func _ready() -> void:
	_apply_night_factor(night_factor, true)


func transition_to_night(duration_seconds: float = -1.0) -> void:
	_transition_to_factor(1.0, duration_seconds)


func transition_to_day(duration_seconds: float = -1.0) -> void:
	_transition_to_factor(0.0, duration_seconds)


func set_night_factor_immediate(value: float) -> void:
	_stop_transition()
	_target_night_factor = clampf(value, 0.0, 1.0)
	_apply_night_factor(_target_night_factor)
	transition_completed.emit(_target_night_factor >= 0.999)


func is_night() -> bool:
	return night_factor >= 0.999


func is_transitioning() -> bool:
	return _transition_tween != null and _transition_tween.is_valid()


func _transition_to_factor(
	target_factor: float,
	duration_seconds: float
) -> void:
	var safe_target := clampf(target_factor, 0.0, 1.0)
	if (
		is_transitioning()
		and is_equal_approx(_target_night_factor, safe_target)
	):
		return
	_stop_transition()
	_target_night_factor = safe_target
	var safe_duration := (
		transition_duration
		if duration_seconds < 0.0
		else maxf(duration_seconds, 0.0)
	)
	if safe_duration <= 0.0 or is_equal_approx(night_factor, safe_target):
		_apply_night_factor(safe_target)
		transition_completed.emit(safe_target >= 0.999)
		return

	_transition_tween = create_tween()
	_transition_tween.set_trans(Tween.TRANS_SINE)
	_transition_tween.set_ease(Tween.EASE_IN_OUT)
	_transition_tween.tween_method(
		_apply_night_factor,
		night_factor,
		safe_target,
		safe_duration
	)
	_transition_tween.tween_callback(
		_finish_transition.bind(safe_target)
	)


func _apply_night_factor(
	value: float,
	force_emit: bool = false
) -> void:
	var safe_factor := clampf(value, 0.0, 1.0)
	var factor_changed := night_factor != safe_factor
	night_factor = safe_factor
	if night_factor == 0.0:
		color = day_color
	elif night_factor == 1.0:
		color = night_color
	else:
		color = day_color.lerp(night_color, night_factor)
	if force_emit or factor_changed:
		night_factor_changed.emit(night_factor)


func _finish_transition(target_factor: float) -> void:
	_transition_tween = null
	_apply_night_factor(target_factor)
	transition_completed.emit(target_factor >= 0.999)


func _stop_transition() -> void:
	if _transition_tween != null and _transition_tween.is_valid():
		_transition_tween.kill()
	_transition_tween = null
