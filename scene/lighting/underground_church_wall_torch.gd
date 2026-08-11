extends Node2D
class_name UndergroundChurchWallTorch

const MIN_EMISSION_STRENGTH := 0.9
const MAX_EMISSION_STRENGTH := 1.0

@export_range(0.1, 10.0, 0.05, "or_greater") var half_cycle_seconds := 1.35

@onready var night_light: NightPointLight2D = $NightPointLight

var breathing_tween: Tween


func _ready() -> void:
	night_light.set_emission_strength(MIN_EMISSION_STRENGTH)
	breathing_tween = create_tween().bind_node(self).set_loops()
	breathing_tween.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	breathing_tween.tween_method(
		night_light.set_emission_strength,
		MIN_EMISSION_STRENGTH,
		MAX_EMISSION_STRENGTH,
		half_cycle_seconds,
	)
	breathing_tween.tween_method(
		night_light.set_emission_strength,
		MAX_EMISSION_STRENGTH,
		MIN_EMISSION_STRENGTH,
		half_cycle_seconds,
	)
