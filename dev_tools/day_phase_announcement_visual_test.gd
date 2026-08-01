extends SceneTree

const ARENA_SCENE := preload("res://scene/test_arena/test_grass_arena.tscn")
const PREVIEW_PATHS := {
	false: {
		false: "user://day_phase_announcement_p1_preview.png",
		true: "user://day_phase_announcement_p1_wide_preview.png",
	},
	true: {
		false: "user://day_phase_announcement_day_preview.png",
		true: "user://day_phase_announcement_day_wide_preview.png",
	},
}


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	var wide_preview := OS.get_cmdline_user_args().has("--wide")
	var day_preview := OS.get_cmdline_user_args().has("--day")
	DisplayServer.window_set_size(Vector2i(1600, 648) if wide_preview else Vector2i(1152, 648))
	await process_frame
	var arena := ARENA_SCENE.instantiate() as TestGrassArena
	arena.auto_start_waves = false
	if day_preview:
		arena.test_entry_announcement_text = ""
	root.add_child(arena)
	current_scene = arena
	await process_frame
	await process_frame
	if day_preview:
		arena.day_phase_announcement.show_day_phase(1, false)
	var animation_player := (
		arena.day_phase_announcement.get_node("AnimationPlayer") as AnimationPlayer
	)
	animation_player.seek(0.35, true)
	await process_frame
	await process_frame
	var preview := root.get_texture().get_image()
	if preview == null:
		push_error("当前显示驱动无法读取昼夜报幕视觉预览。")
		quit(1)
		return
	var absolute_path := ProjectSettings.globalize_path(
		PREVIEW_PATHS[day_preview][wide_preview]
	)
	var save_error := preview.save_png(absolute_path)
	if save_error != OK:
		push_error("无法保存昼夜报幕视觉预览：%s" % error_string(save_error))
		quit(1)
		return
	print("DAY_PHASE_ANNOUNCEMENT_VISUAL_TEST_OK path=%s" % absolute_path)
	arena.day_phase_announcement.hide_announcement()
	current_scene = null
	arena.queue_free()
	await process_frame
	await process_frame
	quit(0)
