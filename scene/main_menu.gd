extends Control

const LOBBY_SCENE_PATH := "res://scene/lobby.tscn"


func _on_start_pressed() -> void:
	get_tree().change_scene_to_file(LOBBY_SCENE_PATH)


func _on_quit_pressed() -> void:
	get_tree().quit()
