extends Node2D
class_name MerchantDialogueBubble

const LETTER_TIME := 0.035
const COMMA_TIME := 0.12
const PUNCTUATION_TIME := 0.22
const SILENT_CHARACTERS := " ，。？！、,.?![]◆"

@onready var text_label: RichTextLabel = $BubblePanel/Margin/Content/Text
@onready var blip_audio: AudioStreamPlayer2D = $BlipAudio

var reveal_serial: int = 0
var is_revealing: bool = false
var current_text: String = ""
var reveal_index: int = 0
var reveal_delay_left: float = 0.0


func _ready() -> void:
	set_process(false)


func _process(delta: float) -> void:
	if not is_revealing:
		set_process(false)
		return

	reveal_delay_left = maxf(reveal_delay_left - delta, 0.0)
	if reveal_delay_left > 0.0:
		return

	if reveal_index >= current_text.length():
		text_label.visible_characters = -1
		is_revealing = false
		set_process(false)
		return

	var character := current_text.substr(reveal_index, 1)
	text_label.visible_characters = reveal_index + 1
	if not SILENT_CHARACTERS.contains(character):
		blip_audio.pitch_scale = 0.96 + float(reveal_index % 3) * 0.035
		blip_audio.play()
	reveal_index += 1
	reveal_delay_left = _get_character_delay(character)


func say(text: String) -> void:
	visible = true
	reveal_serial += 1
	current_text = _get_reveal_text(text)
	reveal_index = 0
	reveal_delay_left = 0.0
	text_label.text = text
	text_label.visible_characters = 0
	is_revealing = true
	set_process(true)


func finish_line() -> void:
	reveal_serial += 1
	text_label.visible_characters = -1
	is_revealing = false
	set_process(false)


func hide_bubble() -> void:
	finish_line()
	visible = false


func _get_character_delay(character: String) -> float:
	if character == "，" or character == "," or character == "、":
		return COMMA_TIME
	if character == "。" or character == "？" or character == "！" or character == "." or character == "?" or character == "!":
		return PUNCTUATION_TIME
	return LETTER_TIME


func _get_reveal_text(bbcode_text: String) -> String:
	var parsed := ""
	var index := 0
	while index < bbcode_text.length():
		var character := bbcode_text.substr(index, 1)
		if character != "[":
			parsed += character
			index += 1
			continue

		var end_index := bbcode_text.find("]", index)
		if end_index == -1:
			parsed += character
			index += 1
			continue

		var tag := bbcode_text.substr(index + 1, end_index - index - 1)
		if tag.begins_with("img"):
			parsed += "◆"
			var close_index := bbcode_text.find("[/img]", end_index + 1)
			index = close_index + 6 if close_index != -1 else end_index + 1
		else:
			index = end_index + 1
	return parsed
