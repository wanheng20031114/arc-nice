extends SceneTree

const WAVE_HUD_SCENE := preload("res://scene/wave_hud.tscn")

var failures: Array[String] = []


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	await _verify_standard_mode_compatibility()
	await _verify_tower_defense_layout_and_updates()
	_finish()


func _verify_standard_mode_compatibility() -> void:
	var hud := WAVE_HUD_SCENE.instantiate() as WaveHUD
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
		hud.status_label.visible and not hud.tower_defense_stats.visible,
		"The standard HUD must keep the legacy single-label layout."
	)

	hud.queue_free()
	await process_frame


func _verify_tower_defense_layout_and_updates() -> void:
	var hud := WAVE_HUD_SCENE.instantiate() as WaveHUD
	root.add_child(hud)
	await process_frame
	hud.configure_tower_defense(100, 100)

	_expect(hud.tower_defense_mode, "Tower-defense mode must require explicit configuration.")
	_expect(
		hud.top_bar.custom_minimum_size == Vector2(528.0, 66.0)
		and is_equal_approx(hud.top_bar.offset_left, -264.0)
		and is_equal_approx(hud.top_bar.offset_top, 8.0)
		and is_equal_approx(hud.top_bar.offset_right, 264.0)
		and is_equal_approx(hud.top_bar.offset_bottom, 74.0),
		"Tower-defense configuration must expand the main strip to 528 by 66."
	)
	_expect(
		hud.top_bar_margin.get_theme_constant("margin_left") == 14
		and hud.top_bar_margin.get_theme_constant("margin_top") == 7
		and hud.top_bar_margin.get_theme_constant("margin_right") == 14
		and hud.top_bar_margin.get_theme_constant("margin_bottom") == 7,
		"Tower-defense configuration must apply its dedicated spacious margins."
	)
	_expect(
		not hud.status_label.visible and hud.tower_defense_stats.visible,
		"Tower-defense configuration must replace the legacy text with three stats."
	)
	_expect(
		hud.core_title_label.text == "核心生命"
		and hud.enemy_title_label.text == "场上敌人"
		and hud.wave_title_label.text == "第 1 波",
		"All three tower-defense columns must expose stable public labels."
	)
	_expect(
		hud.core_value_label.text == "100/100"
		and hud.enemy_value_label.text == "0"
		and hud.wave_value_label.text == "0%",
		"Tower-defense configuration must initialize all cached values."
	)
	_expect(
		not hud.core_progress_bar.show_percentage
		and not hud.wave_progress_bar.show_percentage,
		"Native progress bars must hide their built-in percentage text."
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
		and hud.wave_title_label.text == "第 3 波"
		and hud.wave_value_label.text == "33%",
		"Independent tower-defense setters must not overwrite sibling columns."
	)
	_expect(
		hud.core_stat.self_modulate != Color.WHITE
		and hud.enemy_stat.self_modulate == Color.WHITE
		and hud.wave_stat.self_modulate == Color.WHITE,
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
		hud.core_value_label.self_modulate == WaveHUD.CORE_CRITICAL_COLOR,
		"Core health at 25 percent must use the critical red treatment."
	)
	hud.set_tower_defense_wave_progress(3, 2, 3)
	_expect(
		hud.wave_value_label.text == "67%"
		and is_equal_approx(hud.wave_progress_bar.value, 67.0),
		"Wave progress must round resolved/total to the nearest percentage."
	)
	hud.set_tower_defense_wave_progress(4, 7, 0)
	_expect(
		hud.wave_title_label.text == "第 4 波"
		and hud.wave_value_label.text == "0%"
		and is_zero_approx(hud.wave_progress_bar.value),
		"A zero-total wave must display safe zero progress."
	)

	hud.show_countdown(3, true)
	_expect(
		hud.top_bar.visible
		and hud.tower_defense_stats.visible
		and hud.stage_banner.visible
		and hud.stage_label.text.contains("00:03"),
		"Tower-defense rest time must use a separate banner below the three stats."
	)
	_expect(
		hud.status_label.text == "下一波将在 00:03 后开始",
		"The hidden compatibility label must retain the existing countdown wording."
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
		hud.wave_value_label.text == "75%",
		"The compatibility wave method must forward to the percentage setter."
	)

	hud.show_tower_defense_boss_progress(0, 1)
	_expect(
		hud.top_bar.visible
		and hud.tower_defense_stats.visible
		and hud.wave_title_label.text == "首领战"
		and hud.wave_value_label.text == "0%",
		"Boss combat must keep the merged HUD visible with dedicated progress wording."
	)
	hud.show_tower_defense_boss_progress(1, 1)
	_expect(
		hud.wave_title_label.text == "首领战"
		and hud.wave_value_label.text == "100%",
		"Boss defeat must advance the merged HUD to one hundred percent."
	)

	hud.show_tower_defense_defeat()
	_expect(
		not hud.top_bar.visible and not hud.stage_banner.visible,
		"Victory and defeat presentation must hide the complete gameplay HUD."
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
