extends Control

# 大厅场景的路径
const LOBBY_SCENE_PATH := "res://scene/lobby.tscn"


# 当“开始游戏”按钮被按下时调用，切换到大厅场景
func _on_start_pressed() -> void:
	var run_state := get_node("/root/RunState") as RunStateStore
	run_state.begin_new_run()
	get_tree().change_scene_to_file(LOBBY_SCENE_PATH)


# 当“退出”按钮被按下时调用，退出整个游戏程序
func _on_quit_pressed() -> void:
	get_tree().quit()
