extends SceneTree

const OVERLAY_SCENE := preload(
	"res://scene/game_modes/rogue/encounter/rogue_encounter_overlay.tscn"
)
const CHICKEN_PREVIEW_PATH := "user://rogue_encounter_chicken_bro_preview.png"
const GHOST_PREVIEW_PATH := "user://rogue_encounter_ghost_shadow_preview.png"
const FLUORESCENT_PIT_PREVIEW_PATH := (
	"user://rogue_encounter_fluorescent_pit_preview.png"
)


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	DisplayServer.window_set_size(Vector2i(1280, 720))
	await process_frame
	var backdrop := ColorRect.new()
	backdrop.color = Color("10252b")
	backdrop.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	root.add_child(backdrop)
	var overlay := OVERLAY_SCENE.instantiate() as RogueEncounterOverlay
	root.add_child(overlay)
	overlay.configure_local_context(
		1,
		{1: "玩家一", 2: "玩家二"},
		{1: PlayerCharacterRegistry.get_default_character_id(), 2: &"tiyi"}
	)
	overlay.apply_state({
		"schema_version": 4,
		"revision": 4,
		"phase": "voting",
		"node_id": 12,
		"node_content_seed": 9981,
		"occurrence_key": "12:9981",
		"encounter_id": "chicken_bro",
		"remaining_seconds": 47.0,
		"voting_timer_running": true,
		"participant_peer_ids": [1, 2],
		"active_peer_ids": [1, 2],
		"spectator_peer_ids": [],
		"intro_confirmed_peer_ids": [1, 2],
		"votes": [{"peer_id": 2, "option_id": "ask_for_free"}],
		"abstained_peer_ids": [],
		"option_availability": {
			"purchase_basketball": true,
			"ask_for_free": true,
		},
		"winning_option": "",
		"economy_result": {},
		"result_text": "",
		"result_pages": [],
		"round_index": 0,
		"result_sequence": 0,
		"disabled_option_ids": [],
		"round_recipient_peer_ids": [],
		"result_ack_peer_ids": [],
		"terminal_result": false,
		"run_failed": false,
		"personal_result_pages": {},
	})
	await overlay.cover_map_for_encounter()
	await overlay.reveal_encounter()
	for _frame in range(3):
		await process_frame
	var preview := root.get_texture().get_image()
	if preview == null or preview.is_empty():
		push_error("当前显示驱动无法读取鸡哥遭遇预览。")
		quit(1)
		return
	if bool(ProjectSettings.get_setting("rendering/viewport/hdr_2d", false)):
		if preview.get_format() not in [Image.FORMAT_RGB8, Image.FORMAT_RGBA8]:
			preview.convert(Image.FORMAT_RGBA8)
		preview.linear_to_srgb()
	var absolute_path := ProjectSettings.globalize_path(CHICKEN_PREVIEW_PATH)
	var save_error := preview.save_png(absolute_path)
	if save_error != OK:
		push_error("无法保存鸡哥遭遇预览：%s" % error_string(save_error))
		quit(1)
		return
	overlay.hide_immediately()
	overlay.apply_state({
		"schema_version": 4,
		"revision": 2,
		"phase": "voting",
		"node_id": 81,
		"node_content_seed": 8181,
		"occurrence_key": "81:8181",
		"encounter_id": "ghost_shadow",
		"remaining_seconds": 52.0,
		"voting_timer_running": true,
		"participant_peer_ids": [1, 2],
		"active_peer_ids": [1, 2],
		"spectator_peer_ids": [],
		"intro_confirmed_peer_ids": [1, 2],
		"votes": [{"peer_id": 2, "option_id": "ghost_who_are_you"}],
		"abstained_peer_ids": [],
		"option_availability": {
			"ghost_run_away": true,
			"ghost_who_are_you": true,
		},
		"winning_option": "",
		"economy_result": {},
		"result_text": "",
		"result_pages": [],
		"round_index": 0,
		"result_sequence": 0,
		"disabled_option_ids": [],
		"round_recipient_peer_ids": [],
		"result_ack_peer_ids": [],
		"terminal_result": false,
		"run_failed": false,
		"personal_result_pages": {},
	})
	await overlay.cover_map_for_encounter()
	await overlay.reveal_encounter()
	for _frame in range(3):
		await process_frame
	preview = root.get_texture().get_image()
	if preview == null or preview.is_empty():
		push_error("当前显示驱动无法读取鬼影遭遇预览。")
		quit(1)
		return
	if bool(ProjectSettings.get_setting("rendering/viewport/hdr_2d", false)):
		if preview.get_format() not in [Image.FORMAT_RGB8, Image.FORMAT_RGBA8]:
			preview.convert(Image.FORMAT_RGBA8)
		preview.linear_to_srgb()
	var ghost_absolute_path := ProjectSettings.globalize_path(GHOST_PREVIEW_PATH)
	save_error = preview.save_png(ghost_absolute_path)
	if save_error != OK:
		push_error("无法保存鬼影遭遇预览：%s" % error_string(save_error))
		quit(1)
		return
	overlay.hide_immediately()
	overlay.apply_state({
		"schema_version": 4,
		"revision": 8,
		"phase": "voting",
		"node_id": 109,
		"node_content_seed": 621947,
		"occurrence_key": "109:621947",
		"encounter_id": "fluorescent_pit",
		"remaining_seconds": 60.0,
		"voting_timer_running": true,
		"participant_peer_ids": [1, 2],
		"active_peer_ids": [1, 2],
		"spectator_peer_ids": [],
		"intro_confirmed_peer_ids": [1, 2],
		"votes": [],
		"abstained_peer_ids": [],
		"option_availability": {
			"explore_pit": true,
			"leave_pit": true,
		},
		"winning_option": "",
		"economy_result": {},
		"result_text": "",
		"result_pages": [],
		"round_index": 0,
		"result_sequence": 0,
		"disabled_option_ids": [],
		"round_recipient_peer_ids": [],
		"result_ack_peer_ids": [],
		"terminal_result": false,
		"run_failed": false,
		"personal_result_pages": {},
	})
	await overlay.cover_map_for_encounter()
	await overlay.reveal_encounter()
	for _frame in range(3):
		await process_frame
	preview = root.get_texture().get_image()
	if preview == null or preview.is_empty():
		push_error("当前显示驱动无法读取荧光坑洞遭遇预览。")
		quit(1)
		return
	if bool(ProjectSettings.get_setting("rendering/viewport/hdr_2d", false)):
		if preview.get_format() not in [Image.FORMAT_RGB8, Image.FORMAT_RGBA8]:
			preview.convert(Image.FORMAT_RGBA8)
		preview.linear_to_srgb()
	var fluorescent_pit_absolute_path := ProjectSettings.globalize_path(
		FLUORESCENT_PIT_PREVIEW_PATH
	)
	save_error = preview.save_png(fluorescent_pit_absolute_path)
	if save_error != OK:
		push_error("无法保存荧光坑洞遭遇预览：%s" % error_string(save_error))
		quit(1)
		return
	print(
		(
			"ROGUE_ENCOUNTER_OVERLAY_VISUAL_TEST_OK "
			+ "chicken=%s ghost=%s fluorescent_pit=%s"
		)
		% [absolute_path, ghost_absolute_path, fluorescent_pit_absolute_path]
	)
	overlay.queue_free()
	backdrop.queue_free()
	await process_frame
	quit(0)
