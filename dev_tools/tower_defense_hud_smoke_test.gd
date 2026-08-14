extends SceneTree

const STANDARD_WAVE_HUD_SCENE := preload(
	"res://scene/game_modes/standard/ui/standard_wave_hud.tscn"
)
const TOWER_DEFENSE_WAVE_HUD_SCENE := preload(
	"res://scene/game_modes/tower_defense/ui/tower_defense_wave_hud.tscn"
)

var failures: Array[String] = []


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	await _verify_standard_mode_compatibility()
	await _verify_tower_defense_layout_and_updates()
	_finish()


func _verify_standard_mode_compatibility() -> void:
	var hud := STANDARD_WAVE_HUD_SCENE.instantiate() as StandardWaveHUD
	root.add_child(hud)
	await process_frame
	_expect(
		hud.top_bar.custom_minimum_size == Vector2(310.0, 34.0)
		and is_equal_approx(hud.top_bar.offset_left, -155.0)
		and is_equal_approx(hud.top_bar.offset_top, 8.0)
		and is_equal_approx(hud.top_bar.offset_right, 155.0)
		and is_equal_approx(hud.top_bar.offset_bottom, 42.0),
		"The shared scene must retain its original compact standard-mode geometry."
	)
	_expect(
		hud.top_bar_margin.get_theme_constant("margin_left") == 12
		and hud.top_bar_margin.get_theme_constant("margin_top") == 4
		and hud.top_bar_margin.get_theme_constant("margin_right") == 12
		and hud.top_bar_margin.get_theme_constant("margin_bottom") == 4,
		"Standard mode must retain its original WaveInfoBar margins."
	)

	hud.show_wave_progress(2, 3, 7)
	_expect(
		hud.status_label.text == "第 2 波  已消灭 3/7",
		"Standard wave-progress text must remain byte-for-byte compatible."
	)
	hud.show_enemy_count(4, -2)
	_expect(
		hud.status_label.text == "第 4 波  场上敌人 0",
		"Standard enemy-count text must retain its original clamping and wording."
	)
	hud.show_countdown(5)
	_expect(
		hud.status_label.text == "下一波将在 5 秒 后开始",
		"Standard countdown text must remain byte-for-byte compatible."
	)
	_expect(
		hud.status_label.visible
		and hud.get_node_or_null("WaveInfoBar/Margin/TowerDefenseStats") == null
		and hud.get_node_or_null("GlobalWaveNotice") == null,
		"StandardWaveHUD must keep only the standard single-label layout."
	)

	hud.queue_free()
	await process_frame


func _verify_tower_defense_layout_and_updates() -> void:
	var hud := TOWER_DEFENSE_WAVE_HUD_SCENE.instantiate() as TowerDefenseWaveHUD
	root.add_child(hud)
	await process_frame
	hud.configure_tower_defense(100, 100)
	await process_frame

	_expect(
		hud.top_bar.custom_minimum_size == Vector2(404.0, 50.0)
		and is_equal_approx(hud.top_bar.offset_left, -202.0)
		and is_equal_approx(hud.top_bar.offset_top, 6.0)
		and is_equal_approx(hud.top_bar.offset_right, 202.0)
		and is_equal_approx(hud.top_bar.offset_bottom, 56.0),
		"Tower-defense configuration must use the redesigned 404 by 50 main strip."
	)
	_expect(
		hud.top_bar_margin.get_theme_constant("margin_left") == 10
		and hud.top_bar_margin.get_theme_constant("margin_top") == 3
		and hud.top_bar_margin.get_theme_constant("margin_right") == 10
		and hud.top_bar_margin.get_theme_constant("margin_bottom") == 3,
		"Tower-defense configuration must apply its dedicated compact margins."
	)
	_expect(
		hud.day_label.label_settings.font_size == 15
		and hud.phase_label.label_settings.font_size == 10
		and hud.core_title_label.label_settings.font_size == 10
		and hud.core_value_label.label_settings.font_size == 17
		and hud.enemy_value_label.label_settings.font_size == 18
		and hud.stage_label.label_settings.font_size == 11
		and hud.start_wave_button.get_theme_font_size("font_size") == 11,
		"Day-cycle, combat stats, and rest controls must retain a compact font hierarchy."
	)
	_expect(
		hud.day_dial.custom_minimum_size == Vector2(38.0, 38.0)
		and is_equal_approx(hud.day_dial.size.x, hud.day_dial.size.y)
		and hud.day_dial.phase_count == hud.day_cycle_config.waves_per_day
		and hud.day_dial.night_start_phase_index
			== hud.day_cycle_config.night_start_wave_in_day - 1
		and not hud.wave_stat.visible,
		"The old linear wave column must be replaced by a square four-segment day dial."
	)
	_expect(
		hud.core_progress_bar.custom_minimum_size == Vector2(132.0, 3.0)
		and not hud.core_progress_bar.show_percentage,
		"Core health must retain its unobtrusive thin native progress accent."
	)
	_expect(
		hud.top_bar.size.x <= 404.0
		and hud.tower_defense_stats.size.x <= hud.top_bar_margin.size.x
		and hud.enemy_stat.position.x + hud.enemy_stat.size.x
			<= hud.tower_defense_stats.size.x + 0.01,
		"The day cycle and combat stats must remain inside the 404 px top bar."
	)
	_expect(
		hud.stage_banner.custom_minimum_size == Vector2(190.0, 26.0)
		and hud.start_wave_button.custom_minimum_size == Vector2(190.0, 26.0)
		and is_equal_approx(hud.stage_banner.offset_left, -202.0)
		and is_equal_approx(hud.stage_banner.offset_top, 60.0)
		and is_equal_approx(hud.stage_banner.offset_right, -5.0)
		and is_equal_approx(hud.stage_banner.offset_bottom, 86.0)
		and is_equal_approx(hud.start_wave_button.offset_left, 5.0)
		and is_equal_approx(hud.start_wave_button.offset_top, 60.0)
		and is_equal_approx(hud.start_wave_button.offset_right, 202.0)
		and is_equal_approx(hud.start_wave_button.offset_bottom, 86.0),
		"Rest status and early-start action must share one compact 26 px row."
	)
	_expect(
		hud.get_node_or_null("WaveInfoBar/Margin/Status") == null
		and hud.tower_defense_stats.visible,
		"TowerDefenseWaveHUD must author only the day-cycle layout."
	)
	_expect(
		hud.day_label.text == "第 1 日"
		and hud.phase_label.text == "白昼 1/2"
		and hud.core_title_label.text == "核心生命"
		and hud.enemy_title_label.text == "场上敌人"
		and hud.day_dial.phase_index == 0,
		"The initial tower-defense display must be day one, daytime wave one of two."
	)
	_expect(
		hud.core_value_label.text == "100/100"
		and hud.enemy_value_label.text == "0"
		and is_zero_approx(hud.day_dial.wave_progress),
		"Tower-defense configuration must initialize core, enemy, and circular progress values."
	)
	_expect(
		hud.global_wave_notice.visible
		and hud.global_wave_label.text == "全局第 1 波"
		and hud.global_wave_label.label_settings.font_size == 11
		and hud.global_wave_label.label_settings.font_color.a > 0.9
		and is_zero_approx(hud.global_wave_notice.anchor_left)
		and is_equal_approx(hud.global_wave_notice.anchor_top, 1.0),
		"A small rounded white global-wave notice must be anchored at the lower-left."
	)
	var first_notice_tween := hud.global_wave_tween
	hud.set_tower_defense_wave_progress(1, 1, 4)
	var first_dial_tween := hud.day_dial.progress_tween
	hud.day_dial.set_day_progress(
		0,
		hud.day_cycle_config.waves_per_day,
		hud.day_cycle_config.night_start_wave_in_day - 1,
		1,
		4
	)
	_expect(
		hud.global_wave_tween == first_notice_tween
		and hud.day_dial.progress_tween == first_dial_tween
		and is_equal_approx(hud.day_dial.target_wave_progress, 0.25),
		"Repeated progress within one wave must retain its target without replaying either Tween."
	)
	hud.set_tower_defense_wave_progress(2, 0, 4)
	_expect(
		hud.global_wave_tween != first_notice_tween
		and hud.global_wave_label.text == "全局第 2 波",
		"Moving to a new global wave must create exactly one fresh notice Tween."
	)

	for wave_number in range(1, 9):
		hud.set_tower_defense_wave_progress(wave_number, 1, 4)
		var wave_in_day := hud.day_cycle_config.get_wave_in_day(wave_number)
		var is_night := hud.day_cycle_config.is_night_wave(wave_number)
		var phase_start := (
			hud.day_cycle_config.night_start_wave_in_day if is_night else 1
		)
		var phase_end := (
			hud.day_cycle_config.waves_per_day
			if is_night
			else hud.day_cycle_config.night_start_wave_in_day - 1
		)
		var expected_phase_label := "%s %d/%d" % [
			"黑夜" if is_night else "白昼",
			wave_in_day - phase_start + 1,
			maxi(phase_end - phase_start + 1, 1),
		]
		_expect(
			hud.day_label.text
				== "第 %d 日" % hud.day_cycle_config.get_day_number(wave_number)
			and hud.phase_label.text == expected_phase_label
			and hud.day_dial.phase_index == wave_in_day - 1
			and is_equal_approx(hud.day_dial.target_wave_progress, 0.25),
			"Each global wave must map through the shared day-cycle configuration."
		)
	_expect(
		hud.global_wave_label.text == "全局第 8 波"
		and hud.phase_label.text == "黑夜 2/2",
		"The lower-left notice must keep the absolute wave number across day boundaries."
	)

	hud.set_tower_defense_core_health(90, 100, false)
	_expect(
		hud.core_value_label.text == "90/100" and hud.core_pulse_tween == null,
		"An initial authoritative snapshot must update health without faking a damage pulse."
	)
	hud.set_tower_defense_enemy_count(9)
	hud.set_tower_defense_wave_progress(3, 1, 3)
	hud.set_tower_defense_core_health(80, 100)
	var damage_tween := hud.core_pulse_tween
	_expect(
		hud.core_value_label.text == "80/100"
		and hud.enemy_value_label.text == "9"
		and hud.day_label.text == "第 1 日"
		and hud.phase_label.text == "黑夜 1/2",
		"Independent tower-defense setters must not overwrite sibling stats or phase labels."
	)
	_expect(
		hud.core_stat.self_modulate != Color.WHITE
		and hud.enemy_stat.self_modulate == Color.WHITE
		and hud.day_dial.self_modulate == Color.WHITE,
		"Taking damage must flash only the core-health column."
	)
	hud.set_tower_defense_core_health(80, 100)
	_expect(
		hud.core_pulse_tween == damage_tween,
		"An unchanged health snapshot must be rejected by the setter cache."
	)
	hud.set_tower_defense_enemy_count(9)
	_expect(hud._cached_enemy_count == 9, "Enemy snapshots must retain their cached value.")

	hud.set_tower_defense_core_health(25, 100)
	_expect(
		hud.core_value_label.self_modulate
		== TowerDefenseWaveHUD.CORE_CRITICAL_COLOR,
		"Core health at 25 percent must use the critical red treatment."
	)
	hud.set_tower_defense_wave_progress(3, 2, 3)
	_expect(
		is_equal_approx(hud.day_dial.target_wave_progress, 2.0 / 3.0)
		and hud.day_dial.progress_tween != null,
		"Wave progress must drive a short ease-out Tween toward the circular ring target."
	)
	await create_timer(TowerDefenseDayDial.PROGRESS_TWEEN_SECONDS + 0.04).timeout
	_expect(
		is_equal_approx(hud.day_dial.wave_progress, 2.0 / 3.0),
		"The circular progress Tween must settle exactly on its authoritative target."
	)
	hud.set_tower_defense_wave_progress(4, 7, 0)
	_expect(
		hud.phase_label.text == "黑夜 2/2"
		and is_zero_approx(hud.day_dial.target_wave_progress)
		and is_zero_approx(hud.day_dial.wave_progress),
		"A zero-total wave must retain its phase while displaying safe zero circular progress."
	)

	hud.show_countdown(3, true)
	_expect(
		hud.top_bar.visible
		and hud.tower_defense_stats.visible
		and hud.stage_banner.visible
		and hud.start_wave_button.visible
		and hud.stage_label.text == "休整  ·  00:03"
		and hud.start_wave_button.text == "立即开始下一波",
		"Tower-defense rest controls must use the short same-row countdown wording."
	)
	_expect(
		hud.get_node_or_null("WaveInfoBar/Margin/Status") == null,
		"TowerDefenseWaveHUD must not retain the hidden standard countdown label."
	)
	_expect(
		hud.stage_pulse_tween != null,
		"The final three seconds must pulse the stage banner."
	)

	hud.show_tower_defense_wave_progress(4, 2, 1, 3, 4)
	_expect(
		hud.top_bar.visible
		and hud.tower_defense_stats.visible
		and not hud.stage_banner.visible
		and not hud.start_wave_button.visible,
		"Active combat must retain the stats while hiding rest-stage controls."
	)
	_expect(
		is_equal_approx(hud.day_dial.target_wave_progress, 0.75)
		and hud.phase_label.text == "黑夜 2/2",
		"The compatibility wave method must forward to the circular phase-progress setter."
	)

	hud.show_tower_defense_boss_progress(0, 1)
	_expect(
		hud.top_bar.visible
		and hud.tower_defense_stats.visible
		and is_zero_approx(hud.day_dial.target_wave_progress),
		"Boss combat must keep the merged HUD visible and reuse its circular progress ring."
	)
	hud.show_tower_defense_boss_progress(1, 1)
	_expect(
		is_equal_approx(hud.day_dial.target_wave_progress, 1.0),
		"Boss defeat must advance the circular progress ring to one hundred percent."
	)
	hud.show_tower_defense_boss_day_preparation(4, 60, false)
	_expect(
		hud.day_label.text == "第 4 日"
		and hud.phase_label.text == "白昼"
		and hud.wave_title_label.text == "首领战准备"
		and hud.wave_value_label.text == "--"
		and not hud.global_wave_notice.visible,
		"Day-four preparation must not reuse the cached day-three/wave-twelve context."
	)
	hud.show_tower_defense_boss_day_progress(4, 1, 2)
	_expect(
		hud.day_label.text == "第 4 日"
		and hud.phase_label.text == "白昼"
		and hud.wave_title_label.text == "首领战"
		and hud.wave_value_label.text == "50%"
		and not hud.global_wave_notice.visible,
		"Day-four Boss progress must remain independent from ordinary wave numbering."
	)

	hud.set_tower_defense_wave_progress(5, 0, 1)
	hud.hide_all()
	_expect(
		not hud.global_wave_notice.visible,
		"The day-end black interlude must not retain the lower-left global-wave notice."
	)
	hud.set_tower_defense_wave_progress(6, 0, 1)
	hud.show_tower_defense_defeat()
	_expect(
		not hud.top_bar.visible
		and not hud.stage_banner.visible
		and not hud.global_wave_notice.visible,
		"Victory and defeat presentation must hide every gameplay HUD element."
	)

	hud.queue_free()
	await process_frame


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
		push_error(message)


func _finish() -> void:
	if failures.is_empty():
		print("TOWER_DEFENSE_HUD_SMOKE_TEST_OK")
		quit(0)
		return
	print("TOWER_DEFENSE_HUD_SMOKE_TEST_FAILED: %d" % failures.size())
	quit(1)
