extends Control

const GAME_SCENE_PATH := "res://scene/game.tscn"

@onready var settings_panel: Control = $SettingsPanel


func _on_singleplayer_pressed() -> void:
	var run_state: RunStateStore = get_node("/root/RunState") as RunStateStore
	run_state.begin_new_run()
	get_tree().change_scene_to_file(GAME_SCENE_PATH)


func _on_multiplayer_pressed() -> void:
	get_tree().change_scene_to_file("res://scene/multiplayer/multiplayer_lobby.tscn")


func _on_settings_pressed() -> void:
	if settings_panel != null and settings_panel.has_method("open"):
		settings_panel.call("open")


func _on_quit_pressed() -> void:
	get_tree().quit()
