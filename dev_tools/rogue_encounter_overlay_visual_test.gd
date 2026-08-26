extends SceneTree

const OVERLAY_SCENE := preload(
	"res://scene/game_modes/rogue/encounter/rogue_encounter_overlay.tscn"
)
const ENCOUNTER_SCENE := preload(
	"res://scene/game_modes/rogue/encounter/rogue_encounter_scene.tscn"
)
const CHICKEN_PREVIEW_PATH := "user://rogue_encounter_chicken_bro_preview.png"
const GHOST_PREVIEW_PATH := "user://rogue_encounter_ghost_shadow_preview.png"
const FLUORESCENT_PIT_PREVIEW_PATH := (
	"user://rogue_encounter_fluorescent_pit_preview.png"
)
const DEEP_SEA_PREVIEW_1280_FILENAME := (
	"arc_nice_deep_sea_ruins_1280x720.png"
)
const DEEP_SEA_PREVIEW_1600_FILENAME := (
	"arc_nice_deep_sea_ruins_1600x720.png"
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
	overlay.queue_free()
	backdrop.queue_free()
	await process_frame
	var deep_sea_preview_paths := await _capture_deep_sea_previews()
	if deep_sea_preview_paths.is_empty():
		quit(1)
		return
	print(
		(
			"ROGUE_ENCOUNTER_OVERLAY_VISUAL_TEST_OK "
			+ "chicken=%s ghost=%s fluorescent_pit=%s "
			+ "deep_sea_1280=%s deep_sea_1600=%s"
		)
		% [
			absolute_path,
			ghost_absolute_path,
			fluorescent_pit_absolute_path,
			deep_sea_preview_paths[0],
			deep_sea_preview_paths[1],
		]
	)
	quit(0)


func _capture_deep_sea_previews() -> PackedStringArray:
	var temp_directory := OS.get_environment("TEMP")
	if temp_directory.is_empty():
		push_error("系统 TEMP 目录为空，无法保存深海遗迹视觉验收图。")
		return PackedStringArray()
	var preview_paths := PackedStringArray([
		temp_directory.path_join(DEEP_SEA_PREVIEW_1280_FILENAME),
		temp_directory.path_join(DEEP_SEA_PREVIEW_1600_FILENAME),
	])
	var encounter_scene := ENCOUNTER_SCENE.instantiate() as RogueEncounterScene
	root.add_child(encounter_scene)
	encounter_scene.configure_local_context(
		1,
		{1: "玩家一", 2: "玩家二"},
		{1: PlayerCharacterRegistry.get_default_character_id(), 2: &"tiyi"}
	)
	encounter_scene.apply_state(_make_deep_sea_voting_state())
	await encounter_scene.cover_route_for_encounter()
	await encounter_scene.reveal_encounter()
	var viewport_sizes := [Vector2i(1280, 720), Vector2i(1600, 720)]
	for index in viewport_sizes.size():
		var viewport_size: Vector2i = viewport_sizes[index]
		root.content_scale_size = viewport_size
		root.size = viewport_size
		DisplayServer.window_set_size(viewport_size)
		for _frame in range(4):
			await process_frame
		if not _validate_deep_sea_layout(encounter_scene, viewport_size):
			encounter_scene.queue_free()
			await process_frame
			return PackedStringArray()
		var preview := root.get_texture().get_image()
		if (
			preview == null
			or preview.is_empty()
			or preview.get_size() != viewport_size
		):
			push_error(
				"无法读取 %sx%s 深海遗迹预览，实际尺寸为 %s。"
				% [
					viewport_size.x,
					viewport_size.y,
					Vector2i.ZERO if preview == null else preview.get_size(),
				]
			)
			encounter_scene.queue_free()
			await process_frame
			return PackedStringArray()
		_prepare_preview_for_png(preview)
		var save_error := preview.save_png(preview_paths[index])
		if save_error != OK:
			push_error(
				"无法保存 %sx%s 深海遗迹预览：%s"
				% [
					viewport_size.x,
					viewport_size.y,
					error_string(save_error),
				]
			)
			encounter_scene.queue_free()
			await process_frame
			return PackedStringArray()

	encounter_scene.apply_state(_make_legacy_restore_state())
	for _frame in range(3):
		await process_frame
	if not _validate_legacy_restoration(encounter_scene):
		encounter_scene.queue_free()
		await process_frame
		return PackedStringArray()
	encounter_scene.hide_immediately()
	encounter_scene.queue_free()
	await process_frame
	return preview_paths


func _validate_deep_sea_layout(
	encounter_scene: RogueEncounterScene,
	viewport_size: Vector2i
) -> bool:
	var overlay := encounter_scene.presentation
	var decision_rect := overlay.decision_panel.get_global_rect()
	var logical_viewport_size := root.get_visible_rect().size
	var valid := (
		encounter_scene.encounter_backdrop.visible
		and encounter_scene.encounter_backdrop.texture != null
		and encounter_scene.encounter_backdrop.get_global_rect().size
		== logical_viewport_size
		and encounter_scene.encounter_backdrop.stretch_mode == 6
		and overlay.portrait_stage.visible
		and overlay.portrait_stage.size.x >= 420.0
		and not overlay.actor_center.visible
		and not overlay.name_plate.visible
		and not overlay.encounter_hint.visible
		and decision_rect.get_center().x > logical_viewport_size.x * 0.5
		and decision_rect.position.x >= 0.0
		and decision_rect.end.x <= logical_viewport_size.x
		and overlay.choice_first.title_label.text == "拿走水晶！"
		and overlay.choice_first.description_label.text == "获得2个光石"
		and overlay.choice_second.title_label.text == "拿走戒指！"
		and overlay.choice_second.description_label.text
		== "每个玩家随机获得一个戒指类收藏品"
	)
	if not valid:
		push_error(
			(
				"%sx%s 深海遗迹布局不符合右侧选项、左列留白与全屏背景合同："
				+ "background=%s portrait_width=%s decision=%s logical=%s "
				+ "actor=%s name=%s hint=%s titles=%s/%s"
			)
			% [
				viewport_size.x,
				viewport_size.y,
				encounter_scene.encounter_backdrop.get_global_rect(),
				overlay.portrait_stage.size.x,
				decision_rect,
				logical_viewport_size,
				overlay.actor_center.visible,
				overlay.name_plate.visible,
				overlay.encounter_hint.visible,
				overlay.choice_first.title_label.text,
				overlay.choice_second.title_label.text,
			]
		)
	return valid


func _validate_legacy_restoration(
	encounter_scene: RogueEncounterScene
) -> bool:
	var overlay := encounter_scene.presentation
	var valid := (
		not encounter_scene.encounter_backdrop.visible
		and encounter_scene.encounter_backdrop.texture == null
		and encounter_scene.opaque_backdrop.visible
		and encounter_scene.chamber_frame.visible
		and encounter_scene.top_ambient_band.visible
		and encounter_scene.bottom_ambient_band.visible
		and overlay.actor_center.visible
		and overlay.name_plate.visible
		and overlay.encounter_hint.visible
		and overlay.map_shade.color
		== RogueEncounterOverlay.DEFAULT_MAP_SHADE_COLOR
	)
	if not valid:
		push_error("深海遗迹后切回旧遭遇时，默认表现没有完整恢复。")
	return valid


func _make_deep_sea_voting_state() -> Dictionary:
	return {
		"schema_version": 4,
		"revision": 4,
		"phase": "voting",
		"node_id": 911,
		"node_content_seed": 88911,
		"occurrence_key": "911:88911",
		"encounter_id": "deep_sea_ruins",
		"remaining_seconds": 52.0,
		"voting_timer_running": true,
		"participant_peer_ids": [1, 2],
		"active_peer_ids": [1, 2],
		"spectator_peer_ids": [],
		"intro_confirmed_peer_ids": [1, 2],
		"votes": [{"peer_id": 2, "option_id": "take_rings"}],
		"abstained_peer_ids": [],
		"option_availability": {
			"take_crystals": true,
			"take_rings": true,
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
	}


func _make_legacy_restore_state() -> Dictionary:
	var state := _make_deep_sea_voting_state()
	state["revision"] = 5
	state["node_id"] = 912
	state["node_content_seed"] = 88912
	state["occurrence_key"] = "912:88912"
	state["encounter_id"] = "slime_talkers"
	state["votes"] = []
	state["option_availability"] = {
		"help_slimes": true,
		"kick_slimes": true,
		"leave_slimes": true,
	}
	return state


func _prepare_preview_for_png(preview: Image) -> void:
	if not bool(ProjectSettings.get_setting("rendering/viewport/hdr_2d", false)):
		return
	if preview.get_format() not in [Image.FORMAT_RGB8, Image.FORMAT_RGBA8]:
		preview.convert(Image.FORMAT_RGBA8)
	preview.linear_to_srgb()
