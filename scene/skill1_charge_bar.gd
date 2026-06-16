extends Control
class_name Skill1ChargeBar

@onready var progress_bar: ProgressBar = $ProgressBar


func set_unlocked(unlocked: bool) -> void:
	visible = unlocked


func set_charge(current: float, maximum: float, ready: bool) -> void:
	progress_bar.max_value = maxf(maximum, 0.01)
	progress_bar.value = clampf(current, 0.0, progress_bar.max_value)
	modulate = Color(1.0, 1.0, 1.0, 1.0) if ready else Color(0.72, 0.9, 0.74, 0.84)
