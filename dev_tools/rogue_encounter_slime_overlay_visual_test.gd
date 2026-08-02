extends SceneTree

const OVERLAY_SCENE := preload(
	"res://scene/rogue_encounter/rogue_encounter_overlay.tscn"
)
const PREVIEW_PATH := "user://rogue_encounter_slime_talkers_preview.png"


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
		"schema_version": 2,
		"revision": 4,
		"phase": "voting",
		"node_id": 21,
		"node_content_seed": 77821,
		"occurrence_key": "21:77821",
		"encounter_id": "slime_talkers",
		"remaining_seconds": 47.0,
		"voting_timer_running": true,
		"participant_peer_ids": [1, 2],
		"active_peer_ids": [1, 2],
		"spectator_peer_ids": [],
		"intro_confirmed_peer_ids": [1, 2],
		"votes": [{"peer_id": 2, "option_id": "kick_slimes"}],
		"abstained_peer_ids": [],
		"option_availability": {
			"help_slimes": true,
			"kick_slimes": true,
			"leave_slimes": true,
		},
		"winning_option": "",
		"economy_result": {},
		"result_text": "",
		"result_pages": [],
	})
	await overlay.cover_map_for_encounter()
	await overlay.reveal_encounter()
	for _frame in range(3):
		await process_frame
	var preview := root.get_texture().get_image()
	if preview == null or preview.is_empty():
		push_error("当前显示驱动无法读取史莱姆遭遇预览。")
		quit(1)
		return
	if bool(ProjectSettings.get_setting("rendering/viewport/hdr_2d", false)):
		if preview.get_format() not in [Image.FORMAT_RGB8, Image.FORMAT_RGBA8]:
			preview.convert(Image.FORMAT_RGBA8)
		preview.linear_to_srgb()
	var absolute_path := ProjectSettings.globalize_path(PREVIEW_PATH)
	var save_error := preview.save_png(absolute_path)
	if save_error != OK:
		push_error("无法保存史莱姆遭遇预览：%s" % error_string(save_error))
		quit(1)
		return
	print("ROGUE_ENCOUNTER_SLIME_VISUAL_TEST_OK path=%s" % absolute_path)
	overlay.queue_free()
	backdrop.queue_free()
	await process_frame
	quit(0)
