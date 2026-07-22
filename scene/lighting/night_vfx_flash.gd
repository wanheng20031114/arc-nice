extends NightPointLight2D
class_name NightVfxFlash2D

## A short, night-only light envelope for impacts and explosions.
## The visible sprite remains responsible for the hot core; this light only
## supplies the brief illumination that reaches the surrounding world.

@export var auto_play := true
@export_range(0.0, 1.0, 0.005, "or_greater") var attack_seconds := 0.04
@export_range(0.0, 1.0, 0.005, "or_greater") var hold_seconds := 0.06
@export_range(0.01, 2.0, 0.005, "or_greater") var decay_seconds := 0.30
@export_range(0.0, 1.0, 0.01) var initial_strength := 0.58
@export_range(0.0, 1.0, 0.01) var hold_end_strength := 0.78
@export_range(0.25, 8.0, 0.05, "or_greater") var decay_exponent := 1.8
@export_range(0.1, 2.0, 0.01, "or_greater") var start_scale_multiplier := 0.74
@export_range(0.1, 2.0, 0.01, "or_greater") var end_scale_multiplier := 0.84

var _elapsed_seconds := 0.0
var _authored_texture_scale := 1.0
var _flash_active := false


func _enter_tree() -> void:
	_authored_texture_scale = texture_scale
	_flash_active = false
	set_process(false)
	if auto_play:
		call_deferred("play_flash")


func _exit_tree() -> void:
	super._exit_tree()


func _process(delta: float) -> void:
	if not _flash_active:
		set_process(false)
		return
	_elapsed_seconds += maxf(delta, 0.0)
	_apply_envelope()


func play_flash(elapsed_seconds: float = 0.0) -> void:
	stop_flash()
	var total_duration := get_flash_duration()
	_elapsed_seconds = clampf(elapsed_seconds, 0.0, total_duration)
	if _elapsed_seconds >= total_duration:
		return
	_flash_active = true
	set_emission_allowed(true)
	_apply_envelope()
	set_process(_flash_active)


func stop_flash() -> void:
	_flash_active = false
	_elapsed_seconds = 0.0
	set_process(false)
	set_emission_strength(0.0)
	set_emission_allowed(false)
	texture_scale = _authored_texture_scale


func is_flash_active() -> bool:
	return _flash_active


static func get_configured_duration_seconds(
	configured_attack_seconds: float,
	configured_hold_seconds: float,
	configured_decay_seconds: float
) -> float:
	return (
		maxf(configured_attack_seconds, 0.0)
		+ maxf(configured_hold_seconds, 0.0)
		+ maxf(configured_decay_seconds, 0.01)
	)


func get_flash_duration() -> float:
	return get_configured_duration_seconds(
		attack_seconds,
		hold_seconds,
		decay_seconds
	)


func _apply_envelope() -> void:
	var total_duration := get_flash_duration()
	if _elapsed_seconds >= total_duration:
		stop_flash()
		return

	var strength := 0.0
	var scale_multiplier := 1.0
	if attack_seconds > 0.0 and _elapsed_seconds < attack_seconds:
		var attack_progress := smoothstep(
			0.0,
			1.0,
			_elapsed_seconds / attack_seconds
		)
		strength = lerpf(initial_strength, 1.0, attack_progress)
		scale_multiplier = lerpf(
			start_scale_multiplier,
			1.0,
			attack_progress
		)
	elif _elapsed_seconds < attack_seconds + hold_seconds:
		var hold_progress := (
			1.0
			if hold_seconds <= 0.0
			else clampf(
				(_elapsed_seconds - attack_seconds) / hold_seconds,
				0.0,
				1.0
			)
		)
		strength = lerpf(1.0, hold_end_strength, hold_progress)
		scale_multiplier = 1.0
	else:
		var decay_progress := clampf(
			(
				_elapsed_seconds
				- attack_seconds
				- hold_seconds
			) / decay_seconds,
			0.0,
			1.0
		)
		strength = hold_end_strength * pow(
			1.0 - decay_progress,
			decay_exponent
		)
		scale_multiplier = lerpf(
			1.0,
			end_scale_multiplier,
			decay_progress
		)
	set_emission_strength(strength)
	texture_scale = _authored_texture_scale * scale_multiplier


func configure_flash(
	flash_color: Color,
	peak_energy: float,
	peak_texture_scale: float,
	new_attack_seconds: float,
	new_hold_seconds: float,
	new_decay_seconds: float
) -> void:
	stop_flash()
	color = flash_color
	set_night_energy(maxf(peak_energy, 0.0))
	_authored_texture_scale = maxf(peak_texture_scale, 0.01)
	texture_scale = _authored_texture_scale
	attack_seconds = maxf(new_attack_seconds, 0.0)
	hold_seconds = maxf(new_hold_seconds, 0.0)
	decay_seconds = maxf(new_decay_seconds, 0.01)
