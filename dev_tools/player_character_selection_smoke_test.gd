extends SceneTree

const CHOICE_OVERLAY_SCENE := preload(
	"res://scene/character_selection/player_character_choice_overlay.tscn"
)
const MAIN_MENU_SCENE := preload("res://scene/main_menu.tscn")
const MULTIPLAYER_LOBBY_SCENE := preload("res://scene/multiplayer/multiplayer_lobby.tscn")


class FakeLobbyNetManager:
	extends Node

	signal player_joined(peer_id: int, player_name: String)
	signal player_left(peer_id: int)
	signal player_list_changed
	signal connection_failed(reason: String)
	signal connection_state_changed(new_state: int)
	signal player_character_changed(peer_id: int, character_id: StringName, confirmed: bool)

	var connected_players: Dictionary = {1: "SelectionTester"}
	var connected_player_characters: Dictionary = {}
	var confirmed_character_peers: Dictionary = {}
	var local_player_name := "SelectionTester"
	var local_character_id: StringName = PlayerCharacterRegistry.DEFAULT_CHARACTER_ID
	var local_character_confirmed := false
	var connection_state := NetManagerStore.ConnectionState.CONNECTED_IN_LOBBY


	func set_local_character_id(character_id: StringName, confirmed: bool = true) -> bool:
		if not PlayerCharacterRegistry.is_valid_character_id(character_id):
			return false
		local_character_id = character_id
		local_character_confirmed = confirmed
		connected_player_characters[1] = character_id
		confirmed_character_peers[1] = confirmed
		player_character_changed.emit(1, character_id, confirmed)
		player_list_changed.emit()
		return true


	func get_local_peer_id() -> int:
		return 1


	func get_host_peer_id() -> int:
		return 1


	func is_host() -> bool:
		return true


	func get_player_character_id(peer_id: int) -> StringName:
		return StringName(connected_player_characters.get(peer_id, PlayerCharacterRegistry.DEFAULT_CHARACTER_ID))


	func is_player_character_confirmed(peer_id: int) -> bool:
		return bool(confirmed_character_peers.get(peer_id, false))


	func are_all_player_characters_confirmed() -> bool:
		for peer_id_variant in connected_players:
			var peer_id := int(peer_id_variant)
			if not is_player_character_confirmed(peer_id):
				return false
		return not connected_players.is_empty()


	func clear_public_room_context() -> void:
		pass

var failures: Array[String] = []


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	_test_registry_and_run_state()
	await _test_choice_overlay()
	await _test_main_menu_entry()
	await _test_multiplayer_lobby_character_flow()

	if failures.is_empty():
		print("PLAYER_CHARACTER_SELECTION_SMOKE_TEST_OK")
		quit()
		return
	for failure in failures:
		push_error(failure)
	quit(1)


func _test_registry_and_run_state() -> void:
	var configs := PlayerCharacterRegistry.get_all_configs()
	_expect(configs.size() == 3, "Character registry must expose exactly three launch characters.")
	_expect(
		configs.size() == 3
		and configs[0].character_id == PlayerCharacterRegistry.WEISHIDAIER_ID
		and configs[1].character_id == PlayerCharacterRegistry.HOE_CAT_ID
		and configs[2].character_id == PlayerCharacterRegistry.TIYI_ID,
		"Character card order must remain Weishidaier, Hoe Cat, then Tiyi."
	)
	_expect(
		PlayerCharacterRegistry.is_valid_character_id(PlayerCharacterRegistry.WEISHIDAIER_ID),
		"Weishidaier character id must be registered."
	)
	_expect(
		PlayerCharacterRegistry.is_valid_character_id(PlayerCharacterRegistry.HOE_CAT_ID),
		"Hoe Cat character id must be registered."
	)
	_expect(
		PlayerCharacterRegistry.is_valid_character_id(PlayerCharacterRegistry.TIYI_ID),
		"Tiyi character id must be registered."
	)
	_expect(
		PlayerCharacterRegistry.get_config(PlayerCharacterRegistry.HOE_CAT_ID).starting_max_health == 80,
		"Hoe Cat config must expose 80 starting health."
	)
	_expect(
		PlayerCharacterRegistry.get_config(PlayerCharacterRegistry.HOE_CAT_ID).starting_attack_damage == 15
		and is_equal_approx(
			PlayerCharacterRegistry.get_config(PlayerCharacterRegistry.HOE_CAT_ID).attack_damage_per_upgrade,
			5.5
		),
		"Hoe Cat config must expose 15 starting attack damage and 5.5 attack per upgrade."
	)
	_expect(
		PlayerCharacterRegistry.get_config(PlayerCharacterRegistry.HOE_CAT_ID).english_name == "Hoe Cat"
		and PlayerCharacterRegistry.get_config(PlayerCharacterRegistry.WEISHIDAIER_ID).english_name == "Weishidaier"
		and PlayerCharacterRegistry.get_config(PlayerCharacterRegistry.TIYI_ID).english_name == "Tiyi",
		"Character configs must expose all characters' English names."
	)
	_expect(
		is_equal_approx(PlayerCharacterRegistry.get_config(PlayerCharacterRegistry.HOE_CAT_ID).attack_speed_units_per_attack, 200.0)
		and is_equal_approx(PlayerCharacterRegistry.get_config(PlayerCharacterRegistry.WEISHIDAIER_ID).attack_speed_units_per_attack, 100.0)
		and is_equal_approx(PlayerCharacterRegistry.get_config(PlayerCharacterRegistry.TIYI_ID).attack_speed_units_per_attack, 250.0),
		"Character configs must expose each character's attack-speed conversion scale."
	)
	var tiyi_config := PlayerCharacterRegistry.get_config(PlayerCharacterRegistry.TIYI_ID)
	_expect(
		tiyi_config.starting_max_health == 50
		and tiyi_config.starting_attack_damage == 100
		and is_equal_approx(tiyi_config.starting_attack_speed, 250.0)
		and is_equal_approx(tiyi_config.attack_speed_units_per_attack, 250.0)
		and is_equal_approx(tiyi_config.starting_move_speed, 120.0)
		and is_equal_approx(tiyi_config.attack_damage_per_upgrade, 20.0),
		"Tiyi config must expose its starting stats and 20 attack per upgrade."
	)
	_expect(
		tiyi_config.title == "呼呼呼"
		and tiyi_config.description == "以五发弹仓的重型狙击枪处决强敌，并在「午时已到」中锁定多个目标。"
		and tiyi_config.playstyle == "远程 · 单点爆发"
		and tiyi_config.skill_description.contains("4秒")
		and tiyi_config.skill_description.contains("400范围")
		and tiyi_config.skill_description.contains("每0.08秒")
		and tiyi_config.skill_description.contains("最多25名")
		and tiyi_config.skill_description.contains("350%")
		and tiyi_config.skill_description.contains("法术伤害"),
		"Tiyi card copy and skill text must preserve the authored content."
	)
	_expect(
		PlayerCharacterRegistry.get_config(PlayerCharacterRegistry.HOE_CAT_ID).title
		== "会耕地的はじみ"
		and PlayerCharacterRegistry.get_config(PlayerCharacterRegistry.HOE_CAT_ID).portrait_offset
		== Vector2(8.0, 0.0),
		"Hoe Cat selection copy and portrait offset must match the authored card layout."
	)

	var run_state := root.get_node("RunState") as RunStateStore
	_expect(run_state != null, "RunState autoload must be available to character selection.")
	if run_state == null:
		return
	run_state.begin_new_run()
	_expect(
		run_state.selected_character_id == PlayerCharacterRegistry.WEISHIDAIER_ID,
		"begin_new_run() must default to Weishidaier."
	)
	_expect(
		run_state.set_selected_character(PlayerCharacterRegistry.HOE_CAT_ID),
		"RunState must accept the registered Hoe Cat id."
	)
	run_state.begin_new_run(PlayerCharacterRegistry.HOE_CAT_ID)
	_expect(
		run_state.selected_character_id == PlayerCharacterRegistry.HOE_CAT_ID,
		"Starting a run must preserve the confirmed character id."
	)
	_expect(
		run_state.set_selected_character(PlayerCharacterRegistry.TIYI_ID),
		"RunState must accept the registered Tiyi id."
	)
	run_state.begin_new_run(PlayerCharacterRegistry.TIYI_ID)
	_expect(
		run_state.selected_character_id == PlayerCharacterRegistry.TIYI_ID,
		"Starting a run must preserve the confirmed Tiyi id."
	)


func _test_choice_overlay() -> void:
	var overlay := CHOICE_OVERLAY_SCENE.instantiate() as PlayerCharacterChoiceOverlay
	root.add_child(overlay)
	await process_frame
	overlay.open(PlayerCharacterRegistry.HOE_CAT_ID)
	for _frame in range(4):
		await process_frame

	_expect(overlay.is_open(), "Character choice overlay must become visible when opened.")
	_expect(overlay.cards.size() == 3, "Character choice overlay must build three character cards.")
	_expect(
		overlay.selected_character_id == PlayerCharacterRegistry.HOE_CAT_ID,
		"Character choice overlay must honor the initial character id."
	)
	var content := overlay.get_node("Root/Center/Content") as Control
	_expect(
		content.size.x <= overlay.root_control.size.x and content.size.y <= overlay.root_control.size.y,
		"Character choice content must fit inside the launch viewport."
	)
	if overlay.cards.size() == 3:
		var first_style := overlay.cards[0].get_theme_stylebox(&"panel") as StyleBoxFlat
		var second_style := overlay.cards[1].get_theme_stylebox(&"panel") as StyleBoxFlat
		var third_style := overlay.cards[2].get_theme_stylebox(&"panel") as StyleBoxFlat
		_expect(
			first_style != null and second_style != null and third_style != null,
			"Each character card must own a panel style."
		)
		if first_style != null and second_style != null and third_style != null:
			_expect(
				not first_style.border_color.is_equal_approx(second_style.border_color)
				and not first_style.border_color.is_equal_approx(third_style.border_color)
				and not second_style.border_color.is_equal_approx(third_style.border_color),
				"Character cards must use different character-specific edge colors."
			)
			_expect(
				is_zero_approx(first_style.get_content_margin(SIDE_TOP))
				and is_zero_approx(second_style.get_content_margin(SIDE_TOP))
				and is_zero_approx(third_style.get_content_margin(SIDE_TOP)),
				"Character card border state must not alter its content margins."
			)
		_expect(
			overlay.cards[0].size.is_equal_approx(overlay.cards[1].size)
			and overlay.cards[1].size.is_equal_approx(overlay.cards[2].size),
			"Selected and unselected character cards must keep identical layout dimensions."
		)
		for card in overlay.cards:
			var title_label := card.get_node("Margin/Content/Title") as Label
			var name_label := card.get_node("Margin/Content/Name") as Label
			var description_label := card.get_node("Margin/Content/Description") as RichTextLabel
			var portrait_frame := card.get_node("Margin/Content/PortraitFrame") as PanelContainer
			var portrait := card.get_node(
				"Margin/Content/PortraitFrame/PortraitLayer/Portrait"
			) as TextureRect
			var title_font := title_label.get_theme_font(&"font")
			var title_font_variation := title_font as FontVariation
			var name_font := name_label.get_theme_font(&"font")
			var portrait_style := portrait_frame.get_theme_stylebox(&"panel") as StyleBoxFlat
			_expect(
				title_label.custom_minimum_size.y >= title_font.get_height(
					title_label.get_theme_font_size(&"font_size")
				) + 10.0,
				"Character card titles must keep enough top and bottom safety around CJK glyphs."
			)
			_expect(
				title_font_variation != null and title_font_variation.spacing_top >= 2,
				"Character card title fonts must reserve glyph space above the text line."
			)
			_expect(
				title_label.size.y >= title_label.custom_minimum_size.y,
				"Character card title layout must preserve its authored safe height."
			)
			_expect(
				title_label.position.y + title_label.size.y <= portrait_frame.position.y,
				"Character card titles must not overlap their portrait frames."
			)
			_expect(
				name_label.custom_minimum_size.y >= name_font.get_height(
					name_label.get_theme_font_size(&"font_size")
				) + 4.0,
				"Character names must leave vertical breathing room around large CJK glyphs."
			)
			_expect(
				title_label.vertical_alignment == VERTICAL_ALIGNMENT_CENTER
				and name_label.vertical_alignment == VERTICAL_ALIGNMENT_CENTER,
				"Character card CJK labels must center glyphs inside their safe line boxes."
			)
			_expect(
				portrait.texture_filter == CanvasItem.TEXTURE_FILTER_NEAREST
				and portrait.stretch_mode == TextureRect.STRETCH_KEEP_CENTERED,
				"Pixel-art portraits must remain nearest-filtered at their native scale."
			)
			_expect(
				portrait_style != null and portrait_style.bg_color.a < 0.5,
				"Character portraits must use a translucent backdrop."
			)
			_expect(
				portrait.position.is_equal_approx(card.character_config.portrait_offset),
				"Character portrait controls must preserve their configured offsets."
			)
			if card.character_config.character_id == PlayerCharacterRegistry.TIYI_ID:
				_expect(
					title_label.text == "呼呼呼"
					and description_label.text
					== "以五发弹仓的重型狙击枪处决强敌，并在「午时已到」中锁定多个目标。",
					"Tiyi's character card must display the authored title and description."
				)
		var hovered_card := overlay.cards[1]
		hovered_card.call("_on_mouse_entered")
		await create_timer(0.15).timeout
		_expect(
			hovered_card.scale.is_equal_approx(Vector2.ONE),
			"Hover feedback must keep character-card fonts at native scale."
		)
		hovered_card.call("_on_mouse_exited")

	var confirmation := {"character_id": &""}
	overlay.character_confirmed.connect(func(character_id: StringName) -> void:
		confirmation["character_id"] = character_id
	)
	overlay.confirmation_lock_time_left = 0.0
	overlay.call("_confirm_selection")
	await create_timer(0.4).timeout
	_expect(
		confirmation["character_id"] == PlayerCharacterRegistry.HOE_CAT_ID,
		"Character choice confirmation must emit the selected character id."
	)
	_expect(
		not overlay.confirmation_in_progress,
		"Character choice overlay must unlock after its confirmation animation."
	)
	overlay.close()
	_expect(not overlay.is_open(), "Character choice overlay must close after confirmation.")
	overlay.open(PlayerCharacterRegistry.WEISHIDAIER_ID)
	await process_frame
	_expect(
		overlay.is_open()
		and overlay.selected_character_id == PlayerCharacterRegistry.WEISHIDAIER_ID
		and not overlay.back_button.disabled,
		"Character choice overlay must reopen with a new initial selection after confirmation."
	)
	overlay.close()
	overlay.queue_free()
	await process_frame


func _test_main_menu_entry() -> void:
	var main_menu := MAIN_MENU_SCENE.instantiate()
	root.add_child(main_menu)
	await process_frame
	main_menu.call("_on_singleplayer_pressed")
	var overlay := main_menu.get_node("PlayerCharacterChoiceOverlay") as PlayerCharacterChoiceOverlay
	_expect(
		overlay != null and overlay.is_open(),
		"Single-player button must open character selection before loading the game."
	)
	main_menu.queue_free()
	await process_frame


func _test_multiplayer_lobby_character_flow() -> void:
	var real_net_manager := root.get_node("NetManager")
	root.remove_child(real_net_manager)
	var fake_net_manager := FakeLobbyNetManager.new()
	fake_net_manager.name = "NetManager"
	root.add_child(fake_net_manager)

	var run_state := root.get_node("RunState") as RunStateStore
	run_state.set_selected_character(PlayerCharacterRegistry.HOE_CAT_ID)
	var lobby := MULTIPLAYER_LOBBY_SCENE.instantiate()
	root.add_child(lobby)
	await process_frame

	_expect(
		not fake_net_manager.local_character_confirmed,
		"Entering the multiplayer lobby must initialize the local character as unconfirmed."
	)
	lobby.call("_enter_room_wait", {"name": "Selection Test", "room_id": "TEST"})
	for _frame in range(3):
		await process_frame
	var overlay := lobby.get_node("PlayerCharacterChoiceOverlay") as PlayerCharacterChoiceOverlay
	_expect(
		overlay.is_open(),
		"Room wait must automatically open character selection for an unconfirmed player."
	)

	overlay.call("_select_character", PlayerCharacterRegistry.WEISHIDAIER_ID)
	overlay.confirmation_lock_time_left = 0.0
	overlay.call("_confirm_selection")
	await create_timer(0.4).timeout
	_expect(
		fake_net_manager.local_character_confirmed
		and fake_net_manager.local_character_id == PlayerCharacterRegistry.WEISHIDAIER_ID,
		"Confirming a lobby character must synchronize the selected id and confirmation state."
	)
	_expect(not overlay.is_open(), "Lobby confirmation must close the character overlay.")
	_expect(
		run_state.selected_character_id == PlayerCharacterRegistry.WEISHIDAIER_ID,
		"Lobby confirmation must persist the selected character in RunState."
	)

	lobby.call("_on_choose_character_pressed")
	_expect(
		overlay.is_open() and overlay.selected_character_id == PlayerCharacterRegistry.WEISHIDAIER_ID,
		"A confirmed player must be able to reopen selection on the current character."
	)
	overlay.call("_select_character", PlayerCharacterRegistry.HOE_CAT_ID)
	overlay.confirmation_lock_time_left = 0.0
	overlay.call("_confirm_selection")
	await create_timer(0.4).timeout
	_expect(
		fake_net_manager.local_character_confirmed
		and fake_net_manager.local_character_id == PlayerCharacterRegistry.HOE_CAT_ID
		and not overlay.is_open(),
		"Reselecting a lobby character must synchronize and close cleanly."
	)

	lobby.call("_on_choose_character_pressed")
	_expect(
		overlay.is_open() and overlay.selected_character_id == PlayerCharacterRegistry.HOE_CAT_ID,
		"Character overlay must remain reusable after a second confirmation."
	)
	overlay.close()
	lobby.queue_free()
	await process_frame
	root.remove_child(fake_net_manager)
	fake_net_manager.free()
	root.add_child(real_net_manager)


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
