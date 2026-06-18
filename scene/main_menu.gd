extends Control

const GAME_SCENE_PATH := "res://scene/game.tscn"


func _on_singleplayer_pressed() -> void:
	var run_state: RunStateStore = get_node("/root/RunState") as RunStateStore
	run_state.begin_new_run()
	get_tree().change_scene_to_file(GAME_SCENE_PATH)


func _on_multiplayer_pressed() -> void:
	get_tree().change_scene_to_file("res://scene/multiplayer/multiplayer_lobby.tscn")


func _on_settings_pressed() -> void:
	# 设置 - 暂未实现
	pass


func _on_quit_pressed() -> void:
	get_tree().quit()
