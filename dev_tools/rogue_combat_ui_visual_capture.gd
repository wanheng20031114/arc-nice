extends SceneTree

const VIEWPORT_SIZE := Vector2i(1280, 720)
const OUTPUT_DIRECTORY := "res://dev_tools/visual_output"
const COMBAT_SCENE := preload(
	"res://scene/game_modes/rogue/combat/rogue_combat_game_01.tscn"
)
const RESULT_SCENE := preload(
	"res://scene/game_modes/rogue/combat/rogue_combat_result_overlay.tscn"
)
const COMMON_LOOT := preload(
	"res://resources/config/collectibles/collectible_candle_stub.tres"
)

var _failures: PackedStringArray = []
var _combat: RogueCombatGame = null
var _result: RogueCombatResultOverlay = null


func _initialize() -> void:
	call_deferred(&"_run")


func _run() -> void:
	_mute_audio()
	_configure_window()
	DirAccess.make_dir_recursive_absolute(
		ProjectSettings.globalize_path(OUTPUT_DIRECTORY)
	)

	_combat = COMBAT_SCENE.instantiate() as RogueCombatGame
	_result = RESULT_SCENE.instantiate() as RogueCombatResultOverlay
	_expect(_combat != null, "无法实例化 Rouge 作战场景。")
	_expect(_result != null, "无法实例化 Rouge 作战结算层。")
	if _combat == null or _result == null:
		_finish()
		return
	_combat.auto_start_waves = false
	root.add_child(_combat)
	current_scene = _combat
	root.add_child(_result)
	await _wait_frames(4)

	await _capture_preparation_hud()
	await _capture_combat_hud()
	await _capture_victory_result(false)
	await _capture_victory_result(true)
	await _capture_failure_result()
	await _capture_permanent_death()

	_result.hide_immediately()
	current_scene = null
	root.remove_child(_result)
	_result.free()
	_result = null
	root.remove_child(_combat)
	_combat.free()
	_combat = null
	await _wait_frames(3)
	_finish()


func _capture_preparation_hud() -> void:
	_result.hide_immediately()
	_combat.player_life_status_hud.clear_all_respawns()
	_combat.rogue_combat_hud.show_preparation("狭路相逢", 3.0, 10)
	await _wait_frames(2)
	_expect(
		_combat.rogue_combat_hud.preparation_seconds_label.text == "3"
		and _combat.rogue_combat_hud.enemy_value_label.text == "0 / 10",
		"准备 HUD 文案与数量不符合 3 秒、10 名敌人的设计。"
	)
	_expect_control_inside_viewport(
		_combat.rogue_combat_hud.info_panel,
		"准备 HUD 顶部信息条"
	)
	_expect_control_inside_viewport(
		_combat.rogue_combat_hud.preparation_panel,
		"准备 HUD 中央事件卡"
	)
	_expect(
		_combat.rogue_combat_hud.preparation_panel.get_global_rect().position.y
		>= _combat.rogue_combat_hud.info_panel.get_global_rect().end.y,
		"准备事件卡不得遮挡顶部信息条。"
	)
	await _capture("rogue_combat_preparation_hud.png")


func _capture_combat_hud() -> void:
	_combat.rogue_combat_hud.show_combat("狭路相逢", 90.0, 0, 10)
	await _wait_frames(2)
	_expect(
		_combat.rogue_combat_hud.time_value_label.text == "01:30"
		and _combat.rogue_combat_hud.enemy_value_label.text == "0 / 10"
		and not _combat.rogue_combat_hud.preparation_center.visible,
		"战斗 HUD 必须显示 01:30、0/10 已消灭进度，且不保留准备卡。"
	)
	_expect_control_inside_viewport(
		_combat.rogue_combat_hud.info_panel,
		"战斗 HUD 顶部信息条"
	)
	await _capture("rogue_combat_combat_hud.png")


func _capture_victory_result(inventory_full: bool) -> void:
	_result.show_victory(
		500,
		COMMON_LOOT.display_name,
		COMMON_LOOT.icon_texture,
		inventory_full
	)
	await create_timer(0.28).timeout
	_expect(
		_result.result_title_label.text == "通过作战"
		and _result.extra_xirang_value_label.text == "+500"
		and _result.rarity_label.text == "普通品质"
		and _result.loot_name_label.text == COMMON_LOOT.display_name,
		"胜利结算必须显示通过作战、+500 和普通品质收藏品。"
	)
	_expect(
		_result.loot_status_label.text
		== ("未获得（背包已满）" if inventory_full else "已放入背包"),
		"胜利结算的背包状态文案不正确。"
	)
	_expect_control_inside_viewport(_result.result_panel, "胜利结算面板")
	await _capture(
		"rogue_combat_victory_inventory_full.png"
		if inventory_full
		else "rogue_combat_victory_common_loot.png"
	)


func _capture_failure_result() -> void:
	_result.show_failure("作战时间已耗尽")
	await create_timer(0.28).timeout
	_expect(
		_result.result_title_label.text == "作战失败"
		and _result.result_subtitle_label.text == "作战时间已耗尽"
		and _result.extra_xirang_value_label.text == "+0"
		and _result.loot_name_label.text == "无"
		and not _result.rarity_badge.visible,
		"失败结算必须显示时限原因、+0 和无战利品。"
	)
	_expect_control_inside_viewport(_result.result_panel, "失败结算面板")
	await _capture("rogue_combat_failure_result.png")


func _capture_permanent_death() -> void:
	_result.hide_immediately()
	_combat.rogue_combat_hud.show_combat("狭路相逢", 47.0, 4, 10)
	_combat.player_life_status_hud.set_dead_player_list_enabled(false)
	_combat.player_life_status_hud.show_local_permanent_death(0)
	# 捕捉实际入场动画的完整提示阶段：卡片已完全显现，仍明确写出
	# “本次作战无法复活”，同时全屏死亡遮罩正在淡入。
	await create_timer(0.32).timeout
	var death_hud := _combat.player_life_status_hud
	_expect(
		death_hud.local_countdown_label.text == "本次作战无法复活"
		and death_hud.local_permanent_death_active,
		"永久死亡 UI 必须明确告知本次作战无法复活。"
	)
	_expect(
		death_hud.death_screen_effect.visible
		and not death_hud.dead_players_panel.visible,
		"永久死亡必须显示全屏遮罩且隐藏右侧复活列表。"
	)
	_expect_control_inside_viewport(
		death_hud.local_death_center,
		"永久死亡中央提示卡"
	)
	await _capture("rogue_combat_permanent_death_mask.png")


func _capture(file_name: String) -> void:
	await RenderingServer.frame_post_draw
	var image := root.get_texture().get_image()
	_expect(
		image != null and not image.is_empty(),
		"无法读取实际渲染帧：%s。" % file_name
	)
	if image == null or image.is_empty():
		return
	if bool(ProjectSettings.get_setting("rendering/viewport/hdr_2d", false)):
		if image.get_format() not in [Image.FORMAT_RGB8, Image.FORMAT_RGBA8]:
			image.convert(Image.FORMAT_RGBA8)
		image.linear_to_srgb()
	var output_path := "%s/%s" % [OUTPUT_DIRECTORY, file_name]
	var absolute_path := ProjectSettings.globalize_path(output_path)
	var save_error := image.save_png(absolute_path)
	_expect(save_error == OK, "无法保存视觉验证图：%s。" % file_name)
	if save_error == OK:
		print("ROGUE_COMBAT_UI_CAPTURE path=%s" % absolute_path)


func _configure_window() -> void:
	root.content_scale_size = VIEWPORT_SIZE
	root.size = VIEWPORT_SIZE
	if DisplayServer.get_name() != "headless":
		DisplayServer.window_set_size(VIEWPORT_SIZE)


func _expect_control_inside_viewport(control: Control, label: String) -> void:
	var rect := control.get_global_rect()
	_expect(
		rect.position.x >= -1.0
		and rect.position.y >= -1.0
		and rect.end.x <= float(VIEWPORT_SIZE.x) + 1.0
		and rect.end.y <= float(VIEWPORT_SIZE.y) + 1.0,
		"%s 超出 1280×720：%s。" % [label, str(rect)]
	)


func _wait_frames(count: int) -> void:
	for _index in range(count):
		await process_frame


func _mute_audio() -> void:
	for bus_index in range(AudioServer.bus_count):
		AudioServer.set_bus_mute(bus_index, true)


func _expect(condition: bool, message: String) -> void:
	if condition:
		return
	_failures.append(message)
	push_error(message)


func _finish() -> void:
	if _failures.is_empty():
		print("ROGUE_COMBAT_UI_VISUAL_CAPTURE_OK")
		quit(0)
		return
	print("ROGUE_COMBAT_UI_VISUAL_CAPTURE_FAILED count=%d" % _failures.size())
	quit(1)
