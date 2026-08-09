extends SceneTree

const OVERLAY_SCENE := preload(
	"res://scene/game_modes/rogue/supply/rogue_supply_overlay.tscn"
)
const VIEWPORT_SIZE := Vector2i(1152, 648)
const OUTPUT_DIRECTORY := "res://dev_tools/output/rogue_supply"
const COLLECTIBLE_PATHS: Array[String] = [
	"res://resources/config/collectibles/collectible_admin_doll.tres",
	"res://resources/config/collectibles/collectible_apple.tres",
	"res://resources/config/collectibles/collectible_moon_amulet.tres",
]


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	if DisplayServer.get_name() == "headless":
		push_error("物资界面视觉捕获必须使用图形显示驱动运行。")
		quit(2)
		return
	root.content_scale_size = VIEWPORT_SIZE
	root.size = VIEWPORT_SIZE
	DisplayServer.window_set_size(VIEWPORT_SIZE)
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUTPUT_DIRECTORY))

	var overlay := OVERLAY_SCENE.instantiate() as RogueSupplyOverlay
	if overlay == null:
		push_error("无法实例化物资节点界面。")
		quit(1)
		return
	root.add_child(overlay)
	var character_id := PlayerCharacterRegistry.get_default_character_id()
	overlay.configure_local_context(
		1,
		{1: "本地玩家", 2: "队友"},
		{1: character_id, 2: character_id}
	)
	overlay.apply_state(_make_voting_state())
	for _frame in range(40):
		await process_frame
	if not await _capture("supply_voting.png"):
		_finish(overlay, 1)
		return
	overlay.apply_state(_make_collectible_state())
	for _frame in range(5):
		await process_frame
	if not await _capture("supply_collectible_choice.png"):
		_finish(overlay, 1)
		return
	_finish(overlay, 0)


func _make_voting_state() -> Dictionary:
	return {
		"schema_version": 1,
		"revision": 2,
		"phase": "voting",
		"node_id": 42,
		"node_content_seed": 7788,
		"occurrence_key": "supply:42",
		"participant_peer_ids": [1, 2],
		"active_peer_ids": [1, 2],
		"disconnected_peer_ids": [],
		"intro_confirmed_peer_ids": [1, 2],
		"remaining_seconds": 47,
		"timer_running": true,
		"option_ids": [
			String(RogueSupplyRegistry.OPTION_CORE_REPAIR),
			String(RogueSupplyRegistry.OPTION_LIGHT_STONE_COLLECTIBLES),
			String(RogueSupplyRegistry.OPTION_FLYING_ENVELOPE),
		],
		"option_availability": {
			String(RogueSupplyRegistry.OPTION_CORE_REPAIR): true,
			String(RogueSupplyRegistry.OPTION_LIGHT_STONE_COLLECTIBLES): true,
			String(RogueSupplyRegistry.OPTION_FLYING_ENVELOPE): true,
		},
		"light_stone_amount": 0,
		"votes": [
			{"peer_id": 1, "option_id": "core_repair"},
			{"peer_id": 2, "option_id": "flying_envelope"},
		],
		"winning_option": "",
		"result": {},
		"result_text": "",
		"collectible_offers": [],
		"claimed_peer_ids": [],
		"personal_messages": [],
		"result_ack_peer_ids": [],
		"resolved_node_ids": [],
		"settlement_committed": false,
	}


func _make_collectible_state() -> Dictionary:
	var state := _make_voting_state()
	state["revision"] = 3
	state["phase"] = "collectible_choice"
	state["winning_option"] = String(
		RogueSupplyRegistry.OPTION_LIGHT_STONE_COLLECTIBLES
	)
	state["collectible_offers"] = [
		{"peer_id": 1, "paths": COLLECTIBLE_PATHS}
	]
	return state


func _capture(file_name: String) -> bool:
	await RenderingServer.frame_post_draw
	var image := root.get_texture().get_image()
	if image == null or image.is_empty():
		push_error("当前显示驱动无法读取物资界面预览帧。")
		return false
	if bool(ProjectSettings.get_setting("rendering/viewport/hdr_2d", false)):
		if image.get_format() not in [Image.FORMAT_RGB8, Image.FORMAT_RGBA8]:
			image.convert(Image.FORMAT_RGBA8)
		image.linear_to_srgb()
	var output_path := "%s/%s" % [OUTPUT_DIRECTORY, file_name]
	var error := image.save_png(ProjectSettings.globalize_path(output_path))
	if error != OK:
		push_error("无法保存物资界面视觉预览：%s" % error_string(error))
		return false
	print("ROGUE_SUPPLY_UI_CAPTURE path=%s" % ProjectSettings.globalize_path(output_path))
	return true


func _finish(overlay: RogueSupplyOverlay, exit_code: int) -> void:
	root.remove_child(overlay)
	overlay.free()
	quit(exit_code)
