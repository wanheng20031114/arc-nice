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
	var caret := lobby.get_node_or_null(
		"LobbyCenter/UsernamePanel/MarginContainer/VBoxContainer/NameCard/CardVBox/InputSurface/InputLayer/UsernameCaret"
	) as ColorRect
	var username_panel := lobby.get_node_or_null("LobbyCenter/UsernamePanel") as PanelContainer
	var tile_pattern := lobby.get_node_or_null("TilePattern") as TextureRect
	var game_mode_selector := lobby.get_node_or_null(
		"LobbyCenter/RoomBrowserPanel/MarginContainer/VBoxContainer/"
		+ "BrowserBodyScroll/BrowserBodyVBox/RoomSettingsCard/"
		+ "SettingsMargin/SettingsVBox/GameModeRow/GameModeSelector"
	) as OptionButton
	var max_players_spin := lobby.get_node_or_null(
		"LobbyCenter/RoomBrowserPanel/MarginContainer/VBoxContainer/"
		+ "BrowserBodyScroll/BrowserBodyVBox/RoomSettingsCard/"
		+ "SettingsMargin/SettingsVBox/PlayerCountRow/MaxPlayersSpinBox"
	) as SpinBox
	var room_mode_label := lobby.get_node_or_null(
		"LobbyCenter/RoomWaitPanel/MarginContainer/VBoxContainer/RoomModeLabel"
	) as Label
	var room_capacity_label := lobby.get_node_or_null(
		"LobbyCenter/RoomWaitPanel/MarginContainer/VBoxContainer/RoomCapacityLabel"
	) as Label

	_expect(
		tile_pattern != null and tile_pattern.texture_filter == CanvasItem.TEXTURE_FILTER_NEAREST,
		"Pixel-art lobby background must keep Nearest filtering."
	)
	_expect(username_panel != null, "UsernamePanel must exist.")
	_expect(game_mode_selector != null, "Lobby must expose a native game-mode selector.")
	_expect(max_players_spin != null, "Lobby must expose a shared room-capacity selector.")
	_expect(room_mode_label != null, "Room wait panel must expose the synchronized mode label.")
	_expect(room_capacity_label != null, "Room wait panel must expose synchronized room capacity.")
	if game_mode_selector != null:
		_expect(game_mode_selector.item_count == 4, "Game-mode selector must contain all four supported modes.")
		_expect(
			game_mode_selector.get_item_id(0) == NetManagerStore.GameMode.STANDARD
			and game_mode_selector.get_item_id(1) == NetManagerStore.GameMode.TOWER_DEFENSE,
			"Formal game-mode selector ids must match the network enum."
		)
		_expect(
			game_mode_selector.get_item_id(2) == NetManagerStore.GameMode.TEST_ARENA_P1
			and game_mode_selector.get_item_id(3) == NetManagerStore.GameMode.TEST_ARENA_P2,
			"Test-arena selector ids must match the network enum."
		)
		for item_index in range(game_mode_selector.item_count):
			_expect(
				game_mode_selector.get_item_icon(item_index) != null,
				"Every game mode must have a readable pixel-art icon."
			)
		game_mode_selector.select(1)
		lobby.call("_on_game_mode_selected", 1)
		_expect(
			(root.get_node("NetManager") as NetManagerStore).get_current_game_mode()
			== NetManagerStore.GameMode.TOWER_DEFENSE,
			"Disconnected room hosts must be able to select tower-defense mode."
		)
		lobby.call("_update_room_mode_label")
		_expect(
			room_mode_label != null and room_mode_label.text.contains("塔防模式"),
			"Room wait mode label must reflect NetManager authority."
		)
	if max_players_spin != null:
		_expect(
			int(max_players_spin.min_value) == 2
			and int(max_players_spin.max_value) == 8
			and int(max_players_spin.value) == 4,
			"Room capacity selector must default to four total players within the 2..8 contract."
		)
	if username_panel != null:
		_expect(username_panel.scale == Vector2.ONE, "UsernamePanel intro must never scale its text subtree.")
	_expect(input != null, "Username LineEdit must remain available as the real input control.")
	_expect(display != null, "BouncyNameDisplay must exist.")
	_expect(caret != null, "UsernameCaret must exist as the visible input-state indicator.")
	_expect(audio != null and audio.stream != null, "Typing blip audio must be wired.")
	_expect(header == null, "Username card must not keep the HELLO header block.")
	_expect(footer == null, "Username card must not keep the click-to-type footer block.")
	_expect(placeholder == null, "Username input must not keep placeholder text.")

	if input != null:
		_expect(input.max_length == MAX_PLAYER_NAME_LENGTH, "Username input must keep the network name length limit.")
		_expect(input.get_theme_color(&"font_color").a == 0.0, "Real LineEdit text must stay transparent behind the custom display.")
		_expect(input.placeholder_text.is_empty(), "Real LineEdit placeholder must stay empty.")
	if caret != null:
		_expect(caret.custom_minimum_size == Vector2(2.0, 34.0), "Username caret must stay a narrow vertical line.")
		_expect(caret.mouse_filter == Control.MOUSE_FILTER_IGNORE, "Username caret must not intercept input clicks.")
		_expect(caret.color == Color(0.96, 0.88, 0.62, 1), "Username caret must use the lobby accent color.")
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
			var letter := display.get_child(index) as Label
			_expect(letter.get_script() == BOUNCY_NAME_LETTER_SCRIPT, "Every name display child must be a BouncyNameLetter.")
			_expect(letter.scale == Vector2.ONE, "Bouncy name letters must keep unit scale.")

	if input != null and display != null:
		var empty_caret_x := 0.0
		if caret != null:
			input.grab_focus()
			lobby.call("_reset_username_caret_blink")
			lobby.call("_refresh_username_caret")
			await process_frame
			empty_caret_x = caret.position.x
			_expect(caret.visible, "Username caret must be visible when the username input has focus.")
			lobby.call("_update_username_caret_blink", 0.5)
			_expect(not caret.visible, "Username caret must blink off on a fixed interval.")
			lobby.call("_update_username_caret_blink", 0.5)
			_expect(caret.visible, "Username caret must blink back on a fixed interval.")
			lobby.call("_reset_username_caret_blink")

		input.text = "Christophe"
		lobby.call("_on_username_text_changed", input.text)
		await process_frame
		_expect(str(display.call("get_displayed_text")) == "Christophe", "BouncyNameDisplay must mirror the current username.")
		if caret != null:
			lobby.call("_reset_username_caret_blink")
			lobby.call("_refresh_username_caret")
			await process_frame
			_expect(caret.visible, "Username caret must stay visible immediately after typing.")
			_expect(caret.position.x > empty_caret_x, "Username caret must move to the end of the displayed username.")
		if audio != null:
			_expect(audio.playing, "Typing blip audio must play after visible username input changes.")
		_expect((display.get_child(0) as Label).text == "C", "First visible name label must contain the first typed letter.")
		_expect((display.get_child(9) as Label).text == "e", "Last typed name label must contain the last typed letter.")
		_expect(not display.get_child(10).visible, "Unused name label slots must stay hidden.")
		for index in range(input.text.length()):
			_expect(
				(display.get_child(index) as Label).scale == Vector2.ONE,
				"Animated name letters must stay at unit scale."
			)

		input.text = ""
		lobby.call("_on_username_text_changed", input.text)
		await process_frame
		_expect(str(display.call("get_displayed_text")).is_empty(), "BouncyNameDisplay must clear when username input is empty.")
		if caret != null:
			input.release_focus()
			await process_frame
			_expect(not caret.visible, "Username caret must hide when the username input loses focus.")

	if audio != null:
		audio.stop()
	(root.get_node("NetManager") as NetManagerStore).disconnect_from_game()
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
