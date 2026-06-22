extends SceneTree

const LOBBY_SCENE := preload("res://scene/multiplayer/multiplayer_lobby.tscn")
const BOUNCY_NAME_DISPLAY_SCRIPT := preload("res://scene/multiplayer/bouncy_name_display.gd")
const BOUNCY_NAME_LETTER_SCRIPT := preload("res://scene/multiplayer/bouncy_name_letter.gd")
const MAX_PLAYER_NAME_LENGTH := 12

var failures: Array[String] = []


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	var lobby := LOBBY_SCENE.instantiate()
	_expect(lobby != null, "Multiplayer lobby scene must instantiate.")
	if lobby == null:
		_finish()
		return

	root.add_child(lobby)
	await process_frame

	var input := lobby.get_node_or_null(
		"LobbyCenter/UsernamePanel/MarginContainer/VBoxContainer/NameCard/CardVBox/InputSurface/InputLayer/UsernameInput"
	) as LineEdit
	var display := lobby.get_node_or_null(
		"LobbyCenter/UsernamePanel/MarginContainer/VBoxContainer/NameCard/CardVBox/InputSurface/InputLayer/BouncyNameDisplay"
	) as HBoxContainer
	var audio := lobby.get_node_or_null("LobbyCenter/UsernamePanel/TypingBlipAudio") as AudioStreamPlayer
	var header := lobby.get_node_or_null("LobbyCenter/UsernamePanel/MarginContainer/VBoxContainer/NameCard/CardVBox/Header")
	var footer := lobby.get_node_or_null("LobbyCenter/UsernamePanel/MarginContainer/VBoxContainer/NameCard/CardVBox/Footer")
	var placeholder := lobby.get_node_or_null(
		"LobbyCenter/UsernamePanel/MarginContainer/VBoxContainer/NameCard/CardVBox/InputSurface/InputLayer/NamePlaceholder"
	)

	_expect(input != null, "Username LineEdit must remain available as the real input control.")
	_expect(display != null, "BouncyNameDisplay must exist.")
	_expect(audio != null and audio.stream != null, "Typing blip audio must be wired.")
	_expect(header == null, "Username card must not keep the HELLO header block.")
	_expect(footer == null, "Username card must not keep the click-to-type footer block.")
	_expect(placeholder == null, "Username input must not keep placeholder text.")

	if input != null:
		_expect(input.max_length == MAX_PLAYER_NAME_LENGTH, "Username input must keep the network name length limit.")
		_expect(input.get_theme_color(&"font_color").a == 0.0, "Real LineEdit text must stay transparent behind the custom display.")
		_expect(input.placeholder_text.is_empty(), "Real LineEdit placeholder must stay empty.")
	if audio != null:
		_expect(audio.stream is AudioStreamRandomizer, "Typing blip audio must use AudioStreamRandomizer.")
		_expect(audio.max_polyphony == 4, "Typing blip audio must allow overlapping quick keystrokes.")
		_expect(audio.bus == "SFX", "Typing blip audio must route through the SFX bus.")
	if display != null:
		_expect(display.get_script() == BOUNCY_NAME_DISPLAY_SCRIPT, "BouncyNameDisplay must use the bouncy display script.")
		_expect(display.get_child_count() == MAX_PLAYER_NAME_LENGTH, "BouncyNameDisplay must own one fixed label per allowed character.")
		_expect(int(display.get("max_length")) == MAX_PLAYER_NAME_LENGTH, "BouncyNameDisplay length must match network name limit.")
		_expect(display.get("input_audio") == audio, "BouncyNameDisplay must use the scene audio player.")
		for index in range(MAX_PLAYER_NAME_LENGTH):
			_expect(display.get_child(index).get_script() == BOUNCY_NAME_LETTER_SCRIPT, "Every name display child must be a BouncyNameLetter.")

	if input != null and display != null:
		input.text = "Christophe"
		lobby.call("_on_username_text_changed", input.text)
		await process_frame
		_expect(str(display.call("get_displayed_text")) == "Christophe", "BouncyNameDisplay must mirror the current username.")
		if audio != null:
			_expect(audio.playing, "Typing blip audio must play after visible username input changes.")
		_expect((display.get_child(0) as Label).text == "C", "First visible name label must contain the first typed letter.")
		_expect((display.get_child(9) as Label).text == "e", "Last typed name label must contain the last typed letter.")
		_expect(not display.get_child(10).visible, "Unused name label slots must stay hidden.")

		input.text = ""
		lobby.call("_on_username_text_changed", input.text)
		await process_frame
		_expect(str(display.call("get_displayed_text")).is_empty(), "BouncyNameDisplay must clear when username input is empty.")

	if audio != null:
		audio.stop()
	for _frame_index in range(32):
		await process_frame
	lobby.queue_free()
	for _cleanup_frame_index in range(3):
		await process_frame
	_finish()


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)


func _finish() -> void:
	if failures.is_empty():
		print("MULTIPLAYER_LOBBY_NAME_INPUT_SMOKE_TEST_OK")
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	quit(1)
