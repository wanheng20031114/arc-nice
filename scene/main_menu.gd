extends Control

const GAME_SCENE_PATH := "res://scene/game.tscn"

@onready var settings_panel: Control = $SettingsPanel
@onready var singleplayer_button: Button = $MenuCenter/MenuPanel/MarginContainer/MenuStack/SinglePlayer
@onready var character_choice_overlay: PlayerCharacterChoiceOverlay = $PlayerCharacterChoiceOverlay


func _ready() -> void:
	character_choice_overlay.character_confirmed.connect(_on_character_confirmed)
	character_choice_overlay.selection_closed.connect(_on_character_selection_closed)


func _on_singleplayer_pressed() -> void:
	var run_state: RunStateStore = get_node("/root/RunState") as RunStateStore
	character_choice_overlay.open(run_state.get_selected_character_id())


func _on_character_confirmed(character_id: StringName) -> void:
	var run_state: RunStateStore = get_node("/root/RunState") as RunStateStore
	if not run_state.set_selected_character(character_id):
		push_error("Main menu received an invalid character selection: %s" % character_id)
		return
	run_state.begin_new_run(character_id)
	get_tree().change_scene_to_file(GAME_SCENE_PATH)


func _on_character_selection_closed() -> void:
	singleplayer_button.grab_focus()


func _on_multiplayer_pressed() -> void:
	get_tree().change_scene_to_file("res://scene/multiplayer/multiplayer_lobby.tscn")


func _on_settings_pressed() -> void:
	if settings_panel != null and settings_panel.has_method("open"):
		settings_panel.call("open")


func _on_quit_pressed() -> void:
	get_tree().quit()
