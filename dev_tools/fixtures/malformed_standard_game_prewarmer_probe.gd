extends StandardGame

var validation_reached := false


func _validate_mode_scene_content() -> bool:
	validation_reached = true
	return false
