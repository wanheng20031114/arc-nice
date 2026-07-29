extends RefCounted
class_name CodexStatRow

var label: String
var value: String


func _init(initial_label: String = "", initial_value: String = "") -> void:
	label = initial_label
	value = initial_value


func is_valid() -> bool:
	return not label.is_empty() and not value.is_empty()
