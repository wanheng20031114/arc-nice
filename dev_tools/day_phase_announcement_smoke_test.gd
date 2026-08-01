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
	var animation := (
		announcement.get_node("AnimationPlayer") as AnimationPlayer
	).get_animation(&"show")
	var font_variation := title.label_settings.font as FontVariation
	_expect(announcement.layer == 19, "报幕必须位于常规HUD和P1提示之上、模态界面之下。")
	_expect(
		root_control.mouse_filter == Control.MOUSE_FILTER_IGNORE
		and title.mouse_filter == Control.MOUSE_FILTER_IGNORE,
		"报幕必须完全透传鼠标输入。"
	)
	_expect(
		animation != null
		and is_equal_approx(animation.length, DayPhaseAnnouncement.PRESENTATION_DURATION_SECONDS),
		"报幕动画总长必须严格为3.5秒。"
	)
	_expect(
		font_variation != null
		and is_equal_approx(font_variation.variation_embolden, 1.2)
		and font_variation.spacing_glyph == 4,
		"标题必须使用紧凑、加粗的现有中文字体变体。"
	)
	_expect(
		title.label_settings.font_size == 100
		and title.label_settings.outline_size == 1
		and title.label_settings.font_color == Color.WHITE,
		"1152×648基准画布必须使用100号纯白字和极细暗边。"
	)
	_expect(
		audio.stream != null
		and audio.stream.resource_path.ends_with("resources/audio/ui/countdown_tick.wav")
		and audio.bus == &"SFX"
		and is_equal_approx(audio.volume_db, -10.0)
		and audio.max_polyphony == 1,
		"dong提示音必须通过独立的单声部SFX播放器，以-10dB播放。"
	)


func _test_text_formatting() -> void:
	_expect(
		DayPhaseAnnouncement.format_day_phase_text(1, false) == "第一日　白昼",
		"第一日白昼文案格式错误。"
	)
	_expect(
		DayPhaseAnnouncement.format_day_phase_text(1, true) == "第一日　黑夜",
		"第一日黑夜文案格式错误。"
	)
	_expect(
		DayPhaseAnnouncement.format_day_phase_text(12, false) == "第十二日　白昼",
		"两位数日期必须保持中文数字格式。"
	)


func _test_presentation(announcement: DayPhaseAnnouncement) -> void:
	var animation_player := announcement.get_node("AnimationPlayer") as AnimationPlayer
	var title := announcement.get_node("PresentationRoot/Title") as Label
	announcement.show_announcement("测试场景 P1")
	_expect(
		announcement.presentation_count == 1
		and announcement.current_text == "测试场景 P1"
		and title.text == "测试场景 P1"
		and announcement.is_presenting(),
		"自定义报幕必须立即更新文字并开始播放。"
	)
	animation_player.seek(DayPhaseAnnouncement.PRESENTATION_DURATION_SECONDS, true)
	_expect(
		not (announcement.get_node("PresentationRoot") as Control).visible,
		"3.5秒结束时大字必须完全隐藏。"
	)


func _test_phase_boundary_deduplication(
	announcement: DayPhaseAnnouncement
) -> void:
	var game := GameTowerDefense.new()
	game.day_phase_announcement = announcement
	game.day_phase_announcements_enabled = true
	var baseline_count := announcement.presentation_count
	game.call("_announce_wave_phase_start", 1)
	game.call("_announce_wave_phase_start", 1)
	game.call("_announce_wave_phase_start", 2)
	_expect(
		announcement.presentation_count == baseline_count + 1
		and announcement.current_text == "第一日　白昼",
		"同一白昼阶段只能在首波报幕一次。"
	)
	game.call("_announce_wave_phase_start", 3)
	game.call("_announce_wave_phase_start", 4)
	_expect(
		announcement.presentation_count == baseline_count + 2
		and announcement.current_text == "第一日　黑夜",
		"黑夜只能在夜段首波报幕一次。"
	)
	game.call("_announce_wave_phase_start", 5)
	_expect(
		announcement.presentation_count == baseline_count + 3
		and announcement.current_text == "第二日　白昼",
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
