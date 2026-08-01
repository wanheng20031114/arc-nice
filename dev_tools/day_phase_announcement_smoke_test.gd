extends SceneTree

const ANNOUNCEMENT_SCENE := preload("res://scene/day_phase_announcement.tscn")

var failures: Array[String] = []


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	var announcement := ANNOUNCEMENT_SCENE.instantiate() as DayPhaseAnnouncement
	_expect(announcement != null, "昼夜报幕场景必须能够实例化。")
	if announcement == null:
		_finish()
		return
	root.add_child(announcement)
	await process_frame

	_test_scene_contract(announcement)
	await _test_reference_screenshot_layout(announcement)
	_test_text_formatting()
	_test_presentation(announcement)
	_test_phase_boundary_deduplication(announcement)

	announcement.hide_announcement()
	announcement.queue_free()
	await process_frame
	_finish()


func _test_scene_contract(announcement: DayPhaseAnnouncement) -> void:
	var root_control := announcement.get_node("PresentationRoot") as Control
	var title := announcement.get_node("PresentationRoot/Title") as Label
	var audio := announcement.get_node("AnnouncementAudio") as AudioStreamPlayer
	var presentation_timer := announcement.get_node("PresentationTimer") as Timer
	var font_variation := title.label_settings.font as FontVariation
	_expect(announcement.layer == 19, "报幕必须位于常规HUD和P1提示之上、模态界面之下。")
	_expect(
		root_control.mouse_filter == Control.MOUSE_FILTER_IGNORE
		and title.mouse_filter == Control.MOUSE_FILTER_IGNORE,
		"报幕必须完全透传鼠标输入。"
	)
	_expect(
		is_equal_approx(DayPhaseAnnouncement.PRESENTATION_DURATION_SECONDS, 3.0)
		and presentation_timer != null
		and presentation_timer.one_shot
		and not presentation_timer.ignore_time_scale
		and presentation_timer.process_callback == Timer.TIMER_PROCESS_PHYSICS
		and is_equal_approx(
			presentation_timer.wait_time,
			DayPhaseAnnouncement.PRESENTATION_DURATION_SECONDS
		)
		and not announcement.has_node("AnimationPlayer"),
		"静态报幕必须由物理帧单次计时器严格保持3秒，且不保留动画节点。"
	)
	_expect(
		root_control.position == Vector2.ZERO
		and root_control.modulate == Color.WHITE,
		"报幕必须以零位移和完全不透明状态瞬时出现。"
	)
	_expect(
		font_variation != null
		and font_variation.base_font.resource_path.ends_with(
			"resources/font/NotoSansHans-Black.otf"
		)
		and is_zero_approx(font_variation.variation_embolden)
		and font_variation.spacing_glyph == 2,
		"1152×648基准画布必须使用生成器的Noto黑体、2像素字距且不再模拟加粗。"
	)
	_expect(
		title.label_settings.font_size == 140
		and title.label_settings.outline_size == 0
		and title.label_settings.shadow_size == 0
		and title.label_settings.font_color == Color.WHITE,
		"1152×648基准画布必须使用140号纯白字，并移除描边和投影。"
	)
	_expect(
		is_zero_approx(title.offset_top) and is_zero_approx(title.offset_bottom),
		"标题必须严格在屏幕中线居中。"
	)
	_expect(
		audio.stream != null
		and audio.stream.resource_path.ends_with(
			"resources/audio/ui/day_phase_announcement_dong.wav"
		)
		and is_equal_approx(audio.stream.get_length(), 0.42)
		and audio.bus == &"SFX"
		and is_equal_approx(audio.volume_db, -4.0)
		and is_equal_approx(audio.pitch_scale, 1.0)
		and audio.max_polyphony == 1,
		"0.42秒低沉关门咚声必须通过独立的单声部SFX播放器，以原速和-4dB播放。"
	)


func _test_text_formatting() -> void:
	_expect(
		DayPhaseAnnouncement.format_day_phase_text(1, false) == "第一日 白昼",
		"第一日白昼文案格式错误。"
	)
	_expect(
		DayPhaseAnnouncement.format_day_phase_text(1, true) == "第一日 黑夜",
		"第一日黑夜文案格式错误。"
	)
	_expect(
		DayPhaseAnnouncement.format_day_phase_text(12, false) == "第十二日 白昼",
		"两位数日期必须保持中文数字格式。"
	)


func _test_reference_screenshot_layout(baseline_announcement: DayPhaseAnnouncement) -> void:
	var compact_viewport := SubViewport.new()
	compact_viewport.size = Vector2i(1074, 313)
	root.add_child(compact_viewport)
	var compact_announcement := ANNOUNCEMENT_SCENE.instantiate() as DayPhaseAnnouncement
	compact_viewport.add_child(compact_announcement)
	await process_frame
	var compact_title := compact_announcement.get_node("PresentationRoot/Title") as Label
	var compact_font_variation := compact_title.label_settings.font as FontVariation
	var baseline_title := (
		baseline_announcement.get_node("PresentationRoot/Title") as Label
	)
	_expect(
		compact_title.label_settings.font_size == 68
		and compact_font_variation.spacing_glyph == 2,
		"1074×313参考画面必须按缩小后的比例使用68号字和2像素字距。"
	)
	_expect(
		baseline_title.label_settings.font_size == 140,
		"不同视口的报幕字体资源必须彼此隔离，不能串改主画布字号。"
	)
	compact_announcement.queue_free()
	compact_viewport.queue_free()
	await process_frame


func _test_presentation(announcement: DayPhaseAnnouncement) -> void:
	var presentation_root := announcement.get_node("PresentationRoot") as Control
	var presentation_timer := announcement.get_node("PresentationTimer") as Timer
	var title := announcement.get_node("PresentationRoot/Title") as Label
	var finished_texts: Array[String] = []
	announcement.announcement_finished.connect(
		func(display_text: String) -> void: finished_texts.append(display_text)
	)
	announcement.show_announcement("测试场景 P1")
	_expect(
		announcement.presentation_count == 1
		and announcement.current_text == "测试场景 P1"
		and title.text == "测试场景 P1"
		and presentation_root.visible
		and presentation_root.modulate == Color.WHITE
		and presentation_root.position == Vector2.ZERO
		and announcement.is_presenting(),
		"自定义报幕必须立即更新文字，并以完全不透明、零位移状态出现。"
	)
	presentation_timer.timeout.emit()
	_expect(
		not presentation_root.visible
		and not announcement.is_presenting()
		and finished_texts == ["测试场景 P1"],
		"3秒结束时大字必须瞬时隐藏并仅发送一次结束信号。"
	)


func _test_phase_boundary_deduplication(
	announcement: DayPhaseAnnouncement
) -> void:
	var game := GameTowerDefense.new()
	game.day_phase_announcement = announcement
	game.day_phase_announcements_enabled = true
	var baseline_count := announcement.presentation_count
	var first_day_handled := bool(game.call("_announce_wave_phase_start", 1))
	var duplicate_day_handled := bool(game.call("_announce_wave_phase_start", 1))
	var ordinary_wave_handled := bool(game.call("_announce_wave_phase_start", 2))
	_expect(
		first_day_handled
		and duplicate_day_handled
		and not ordinary_wave_handled
		and announcement.presentation_count == baseline_count + 1
		and announcement.current_text == "第一日 白昼",
		"同一白昼阶段只能报幕一次，重复首波状态也必须继续占用开战提示音。"
	)
	game.call("_announce_wave_phase_start", 3)
	game.call("_announce_wave_phase_start", 4)
	_expect(
		announcement.presentation_count == baseline_count + 2
		and announcement.current_text == "第一日 黑夜",
		"黑夜只能在夜段首波报幕一次。"
	)
	game.call("_announce_wave_phase_start", 5)
	_expect(
		announcement.presentation_count == baseline_count + 3
		and announcement.current_text == "第二日 白昼",
		"下一日首波必须显示新的白昼报幕。"
	)
	game.free()


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)


func _finish() -> void:
	if failures.is_empty():
		print("DAY_PHASE_ANNOUNCEMENT_SMOKE_TEST_OK")
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	quit(1)
