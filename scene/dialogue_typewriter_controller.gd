extends Node
class_name DialogueTypewriterController

const LETTER_TIME := 0.035
const COMMA_TIME := 0.12
const PUNCTUATION_TIME := 0.22
const NO_BREAK_MARK := "⁠" # U+2060 WORD JOINER，避免句号等标点孤立换行。
const NO_BREAK_PUNCTUATION := "，。？！、,.?!；：;:"
const SILENT_CHARACTERS := " ，。？！、,.?![]◆"

signal line_finished

var text_label: RichTextLabel = null
var blip_audio: AudioStreamPlayer = null
var current_text := ""
var reveal_index := 0
var reveal_delay_left := 0.0
var _is_revealing := false


func _ready() -> void:
	set_process(false)


func configure(
	new_text_label: RichTextLabel,
	new_blip_audio: AudioStreamPlayer
) -> void:
	text_label = new_text_label
	blip_audio = new_blip_audio
	set_process(_is_revealing)


func _process(delta: float) -> void:
	if not _is_revealing or text_label == null:
		return
	reveal_delay_left = maxf(reveal_delay_left - delta, 0.0)
	if reveal_delay_left > 0.0:
		return
	if reveal_index >= current_text.length():
		finish_line()
		return
	var character := current_text.substr(reveal_index, 1)
	text_label.visible_characters = reveal_index + 1
	if (
		blip_audio != null
		and character != NO_BREAK_MARK
		and not SILENT_CHARACTERS.contains(character)
	):
		blip_audio.pitch_scale = 0.96 + float(reveal_index % 3) * 0.035
		blip_audio.play()
	reveal_index += 1
	reveal_delay_left = _get_character_delay(character)


func say(text: String) -> void:
	if text_label == null:
		return
	var display_text := _add_no_break_before_punctuation(text)
	current_text = _get_reveal_text(display_text)
	reveal_index = 0
	reveal_delay_left = 0.0
	text_label.text = display_text
	text_label.visible_characters = 0
	_is_revealing = true
	set_process(true)


func finish_line() -> void:
	if text_label != null:
		text_label.visible_characters = -1
	var should_emit := _is_revealing
	_is_revealing = false
	set_process(false)
	if should_emit:
		line_finished.emit()


func clear() -> void:
	_is_revealing = false
	current_text = ""
	reveal_index = 0
	reveal_delay_left = 0.0
	set_process(false)
	if text_label != null:
		text_label.text = ""
		text_label.visible_characters = -1


func is_revealing() -> bool:
	return _is_revealing


func _get_character_delay(character: String) -> float:
	if character == NO_BREAK_MARK:
		return 0.0
	if character == "，" or character == "," or character == "、":
		return COMMA_TIME
	if (
		character == "。"
		or character == "？"
		or character == "！"
		or character == "."
		or character == "?"
		or character == "!"
	):
		return PUNCTUATION_TIME
	return LETTER_TIME


func _add_no_break_before_punctuation(bbcode_text: String) -> String:
	var formatted := ""
	var index := 0
	while index < bbcode_text.length():
		var character := bbcode_text.substr(index, 1)
		if character == "[":
			var end_index := bbcode_text.find("]", index)
			if end_index == -1:
				formatted += character
				index += 1
				continue
			var tag := bbcode_text.substr(index + 1, end_index - index - 1)
			formatted += bbcode_text.substr(index, end_index - index + 1)
			index = end_index + 1
			if tag.begins_with("img"):
				var close_index := bbcode_text.find("[/img]", index)
				if close_index != -1:
					formatted += bbcode_text.substr(index, close_index - index + 6)
					index = close_index + 6
			continue
		if (
			NO_BREAK_PUNCTUATION.contains(character)
			and not formatted.ends_with(NO_BREAK_MARK)
		):
			formatted += NO_BREAK_MARK
		formatted += character
		index += 1
	return formatted


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
