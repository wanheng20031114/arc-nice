extends SceneTree

const HUD_SCENE := preload(
	"res://scene/game_modes/rogue/combat/rogue_combat_hud.tscn"
)
const HUD_SCRIPT := preload(
	"res://scene/game_modes/rogue/combat/rogue_combat_hud.gd"
)
const RESULT_SCENE := preload(
	"res://scene/game_modes/rogue/combat/rogue_combat_result_overlay.tscn"
)
const RESULT_SCRIPT := preload(
	"res://scene/game_modes/rogue/combat/rogue_combat_result_overlay.gd"
)
const COMMON_LOOT_ICON := preload(
	"res://resources/texture/collectibles/candle_stub.png"
)
const COMMON_LOOT_CONFIG: PickupConfig = preload(
	"res://resources/config/collectibles/collectible_candle_stub.tres"
)
const SECOND_COMMON_LOOT_CONFIG: PickupConfig = preload(
	"res://resources/config/collectibles/collectible_apple.tres"
)
const PLANK_CONFIG: PickupConfig = preload(
	"res://resources/config/materials/material_plank.tres"
)
const PREVIEW_PATH := "user://rogue_combat_ui_preview.png"

var failures: Array[String] = []
var dismissed_count := 0
var save_preview := false


func _initialize() -> void:
	save_preview = OS.get_cmdline_user_args().has("--screenshot")
	call_deferred("_run")


func _run() -> void:
	_set_viewport_size(Vector2i(1280, 720))
	var hud: Variant = HUD_SCENE.instantiate()
	var result: Variant = RESULT_SCENE.instantiate()
	_expect(hud != null, "ROGUE 作战 HUD 场景必须能以 RogueCombatHUD 实例化。")
	_expect(
		result != null,
		"ROGUE 作战结算场景必须能以 RogueCombatResultOverlay 实例化。"
	)
	if hud == null or result == null:
		_finish()
		return
	root.add_child(hud)
	root.add_child(result)
	await process_frame
	_expect(not hud.visible, "HUD 在作战控制器首次同步状态前必须保持隐藏。")
	_expect(not result.visible, "结算层在收到本地结果前必须保持隐藏。")
	_expect(
		result.result_panel.get_node_or_null("PanelStack/ResultAccent") == null,
		"结算面板不得保留侵入圆角边框的整宽红绿状态条。"
	)

	hud.show_preparation("狭路相逢", 3.0, 10)
	await process_frame
	_expect(
		hud.visible
		and hud.preparation_center.visible
		and hud.event_title_label.text == "狭路相逢"
		and hud.preparation_event_title.text == "狭路相逢",
		"准备阶段必须同时显示事件标题和中央倒计时卡。"
	)
	_expect(
		hud.preparation_seconds_label.text == "3"
		and hud.time_value_label.text == "3"
		and (hud.enemy_block.get_node("Caption") as Label).text == "已消灭"
		and hud.enemy_value_label.text == "0 / 10",
		"三秒准备状态必须显示 3、已消灭标题以及 0/10 进度。"
	)
	hud.set_preparation_time(0.0)
	_expect(
		hud.preparation_seconds_label.text == "开始！",
		"准备倒计时归零时必须给出明确的开始提示。"
	)

	hud.show_combat("狭路相逢", 90.0, 0, 10)
	_expect(
		not hud.preparation_center.visible
		and hud.time_caption_label.text == "剩余时间"
		and hud.time_value_label.text == "01:30"
		and hud.enemy_value_label.text == "0 / 10",
		"正式作战阶段必须显示 90 秒计时和已消灭/总敌人数。"
	)
	hud.set_combat_remaining_time(9.01)
	_expect(
		hud.time_value_label.text == "00:10"
		and hud.time_value_label.self_modulate.is_equal_approx(
			HUD_SCRIPT.URGENT_TIME_COLOR
		),
		"最后十秒必须向上取整显示，并切换为紧急颜色。"
	)
	hud.set_defeated_enemy_count(10, 10)
	_expect(
		hud.enemy_value_label.text == "10 / 10"
		and hud.enemy_value_label.self_modulate.is_equal_approx(
			HUD_SCRIPT.CLEARED_ENEMY_COLOR
		),
		"消灭全部敌人后 HUD 必须保留总数并显示已肃清状态。"
	)

	_set_viewport_size(Vector2i(640, 360))
	await process_frame
	await process_frame
	_expect_control_inside_width(
		hud.info_panel,
		640.0,
		"较窄窗口中的作战信息条不得横向溢出。"
	)
	hud.show_preparation("狭路相逢", 3.0, 10)
	await process_frame
	_expect_control_inside_viewport(
		hud.preparation_panel,
		Vector2(640.0, 360.0),
		"较窄 16:9 窗口中的准备倒计时面板必须完整可见。"
	)
	_expect(
		hud.preparation_panel.get_global_rect().position.y
		>= hud.info_panel.get_global_rect().end.y,
		"较窄 16:9 窗口中的准备倒计时面板不得遮挡顶部作战信息条。"
	)
	_expect(
		hud.preparation_panel.custom_minimum_size.x <= 600.0,
		"较窄窗口中的准备面板必须保留左右安全边距。"
	)
	hud.show_combat("狭路相逢", 10.0, 0, 10)

	result.dismissed.connect(func() -> void: dismissed_count += 1)
	result.show_victory(500, "蜡烛头", COMMON_LOOT_ICON, false)
	await process_frame
	_expect(
		result.visible
		and result.result_title_label.text == "通过作战"
		and result.extra_xirang_value_label.text == "+500"
		and result.result_title_label.label_settings.font_color.is_equal_approx(
			Color.WHITE
		)
		and result.result_title_label.self_modulate.is_equal_approx(
			RESULT_SCRIPT.VICTORY_TITLE_COLOR
		)
		and result.left_state_rule.color.is_equal_approx(
			RESULT_SCRIPT.VICTORY_RULE_COLOR
		)
		and result.right_state_rule.color.is_equal_approx(
			RESULT_SCRIPT.VICTORY_RULE_COLOR
		),
		"胜利结算必须显示“通过作战”和额外息壤 500。"
	)
	_expect(
		result.loot_name_label.text == "蜡烛头"
		and result.loot_icon_rect.texture == COMMON_LOOT_ICON
		and result.rarity_badge.visible
		and result.rarity_label.text == "普通品质"
		and result.loot_status_label.text == "已放入背包",
		"胜利战利品栏必须显示图标、名称、普通品质和入包状态。"
	)
	_expect_control_inside_viewport(
		result.result_panel,
		Vector2(640.0, 360.0),
		"较窄窗口中的结算面板必须完整落在可视区域内。"
	)

	result.show_victory(500, "蜡烛头", COMMON_LOOT_ICON, true)
	await process_frame
	_expect(
		result.loot_status_label.text == "未获得（背包已满）"
		and result.loot_icon_rect.modulate.a < 0.5,
		"背包已满时必须明确标记战利品未获得，并弱化失效图标。"
	)
	_set_viewport_size(Vector2i(1280, 720))
	await process_frame
	result.present_reward_result({
		"victory": true,
		"extra_xirang": 2600,
		"item_rewards": [
			_make_reward_row(COMMON_LOOT_CONFIG, 1, 1, "普通品质"),
			_make_reward_row(SECOND_COMMON_LOOT_CONFIG, 1, 0, "普通品质"),
			_make_reward_row(PLANK_CONFIG, 6, 4, "物资"),
		],
	})
	await process_frame
	_expect(
		result.extra_xirang_value_label.text == "+2600"
		and result.loot_card.visible
		and result.loot_card_2.visible
		and result.loot_card_3.visible,
		"多奖励结算必须同时显示额外息壤和三条战利品。"
	)
	_expect(
		result.loot_name_label_3.text == "木板 ×6"
		and result.loot_status_label_2.text == "未获得（背包已满）"
		and result.loot_status_label_3.text == "获得4，另有2因背包空间不足而丢失",
		"多奖励结算必须精确显示整项与部分溢出的丢失结果。"
	)
	_expect_control_inside_viewport(
		result.result_panel,
		Vector2(1280.0, 720.0),
		"三条战利品的正式结算面板必须完整落在720p可视区域内。"
	)
	await _verify_render_output()
	_expect_state_rule_layout(result)

	result.close_button.pressed.emit()
	_expect(
		not result.visible and dismissed_count == 1,
		"每个本地结算层的关闭按钮必须隐藏自身并独立发出一次 dismissed。"
	)
	result.show_failure("90 秒已耗尽")
	await process_frame
	_expect(
		result.result_title_label.text == "作战失败"
		and result.result_subtitle_label.text == "90 秒已耗尽"
		and result.extra_xirang_value_label.text == "+0"
		and result.loot_name_label.text == "无"
		and not result.rarity_badge.visible
		and result.result_title_label.self_modulate.is_equal_approx(
			RESULT_SCRIPT.FAILURE_TITLE_COLOR
		)
		and result.left_state_rule.color.is_equal_approx(
			RESULT_SCRIPT.FAILURE_RULE_COLOR
		)
		and result.right_state_rule.color.is_equal_approx(
			RESULT_SCRIPT.FAILURE_RULE_COLOR
		),
		"失败结算必须显示失败原因、零额外息壤和无战利品状态。"
	)
	result.hide_immediately()
	_expect(
		dismissed_count == 1,
		"控制器主动隐藏结算时不得伪造玩家关闭信号。"
	)

	hud.hide_hud()
	root.remove_child(result)
	result.free()
	root.remove_child(hud)
	hud.free()
	await process_frame
	_finish()


func _set_viewport_size(viewport_size: Vector2i) -> void:
	root.content_scale_size = viewport_size
	root.size = viewport_size
	if DisplayServer.get_name() != "headless":
		DisplayServer.window_set_size(viewport_size)


func _make_reward_row(
	item: PickupConfig,
	rolled_count: int,
	granted_count: int,
	rarity_name: String
) -> Dictionary:
	return {
		"config_path": item.resource_path,
		"name": item.display_name,
		"rarity_name": rarity_name,
		"rolled_count": rolled_count,
		"granted_count": granted_count,
	}


func _expect_control_inside_width(
	control: Control,
	viewport_width: float,
	message: String
) -> void:
	var rect := control.get_global_rect()
	_expect(
		rect.position.x >= -1.0 and rect.end.x <= viewport_width + 1.0,
		"%s 当前范围：%s。" % [message, str(rect)]
	)


func _expect_control_inside_viewport(
	control: Control,
	viewport_size: Vector2,
	message: String
) -> void:
	var rect := control.get_global_rect()
	_expect(
		rect.position.x >= -1.0
		and rect.position.y >= -1.0
		and rect.end.x <= viewport_size.x + 1.0
		and rect.end.y <= viewport_size.y + 1.0,
		"%s 当前范围：%s。" % [message, str(rect)]
	)


func _expect_state_rule_layout(result: RogueCombatResultOverlay) -> void:
	var panel_rect := result.result_panel.get_global_rect()
	var title_rect := result.result_title_label.get_global_rect()
	var left_rect := result.left_state_rule.get_global_rect()
	var right_rect := result.right_state_rule.get_global_rect()
	_expect(
		result.left_state_rule.get_parent() == result.result_title_label.get_parent()
		and result.right_state_rule.get_parent() == result.result_title_label.get_parent()
		and left_rect.end.x <= title_rect.position.x + 1.0
		and right_rect.position.x + 1.0 >= title_rect.end.x
		and absf(left_rect.get_center().y - title_rect.get_center().y) <= 1.0
		and absf(right_rect.get_center().y - title_rect.get_center().y) <= 1.0,
		"胜败状态短线必须与标题位于同一行、左右对称并垂直居中。"
	)
	_expect(
		left_rect.size.x <= 48.0
		and right_rect.size.x <= 48.0
		and left_rect.position.x >= panel_rect.position.x + 20.0
		and right_rect.end.x <= panel_rect.end.x - 20.0
		and left_rect.position.y >= panel_rect.position.y + 20.0,
		"状态色必须收束为面板内部的短规则线，不得再次碰触圆角或黄铜边框。"
	)


func _verify_render_output() -> void:
	await create_timer(RESULT_SCRIPT.OPEN_DURATION_SECONDS + 0.03).timeout
	if DisplayServer.get_name() == "headless":
		print("ROGUE_COMBAT_UI_RENDER_SKIPPED=dummy_renderer")
		return
	await RenderingServer.frame_post_draw
	var preview := root.get_texture().get_image()
	_expect(
		preview != null and not preview.is_empty(),
		"作战结算层必须能够完成一帧实际渲染并读回图像。"
	)
	if preview == null or preview.is_empty() or not save_preview:
		return
	if bool(ProjectSettings.get_setting("rendering/viewport/hdr_2d", false)):
		if preview.get_format() not in [Image.FORMAT_RGB8, Image.FORMAT_RGBA8]:
			preview.convert(Image.FORMAT_RGBA8)
		preview.linear_to_srgb()
	var absolute_path := ProjectSettings.globalize_path(PREVIEW_PATH)
	var save_error := preview.save_png(absolute_path)
	_expect(save_error == OK, "作战 UI 预览必须能保存为 PNG。")
	if save_error == OK:
		print("ROGUE_COMBAT_UI_PREVIEW path=%s" % absolute_path)


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)


func _finish() -> void:
	if failures.is_empty():
		print("ROGUE_COMBAT_UI_SMOKE_TEST_OK")
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	quit(1)
