extends HBoxContainer
class_name BouncyNameDisplay

const BOUNCY_NAME_LETTER_SCRIPT := preload("res://scene/multiplayer/bouncy_name_letter.gd")

@export var max_length := 12

var input_audio: AudioStreamPlayer
var _displayed_text := ""


func update_text(new_text: String, play_sound: bool = false) -> void:
	var visible_text := new_text.left(max_length)
	var changed_visible_letter := false
	_displayed_text = visible_text

	for index in range(max_length):
		var letter_label := get_child(index) as Label
		if letter_label == null or letter_label.get_script() != BOUNCY_NAME_LETTER_SCRIPT:
			push_error("BouncyNameDisplay requires BouncyNameLetter children.")
			return
		if index < visible_text.length():
			var letter := visible_text.substr(index, 1)
			var changed := letter_label.text != letter
			letter_label.text = letter
			letter_label.show()
			if changed:
				changed_visible_letter = true
				letter_label.call_deferred("restart_animation")
		else:
			letter_label.text = ""
			letter_label.hide()

	if play_sound and changed_visible_letter and input_audio != null and input_audio.stream != null:
		input_audio.play()


func get_displayed_text() -> String:
	return _displayed_text
