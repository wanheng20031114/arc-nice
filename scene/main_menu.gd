extends Control

const GAME_SCENE_PATH := "res://scene/game.tscn"


func _on_singleplayer_pressed() -> void:
	var run_state := get_node("/root/RunState") as RunStateStore
	run_state.begin_new_run()
	get_tree().change_scene_to_file(GAME_SCENE_PATH)


func _on_multiplayer_pressed() -> void:
	# 多人模式 - 暂未实现
	pass


func _on_settings_pressed() -> void:
	# 设置 - 暂未实现
	pass


func _on_quit_pressed() -> void:
	get_tree().quit()
