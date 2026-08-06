extends SceneTree

const GAME_SCENE := preload("res://scene/game_modes/standard/standard_game.tscn")


func _initialize() -> void:
	root.size = Vector2i(1280, 720)
	var game := GAME_SCENE.instantiate()
	root.add_child(game)
	await process_frame
	await process_frame
	var player := game.get_node("Player") as Player
	var profile_panel := (
		game.get_node("PlayerProfilePanel") as StandardPlayerProfilePanel
	)
	player.unlock_skill1()
	profile_panel.open()
	await process_frame
	await process_frame
	var image := root.get_texture().get_image()
	image.save_png("res://dev_tools/profile_panel_layout_preview.png")
	quit()
