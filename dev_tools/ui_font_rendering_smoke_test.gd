extends SceneTree

const DIALOGUE_SCENE_PATHS: PackedStringArray = [
	"res://scene/luoxi_dialogue_bubble.tscn",
	"res://scene/merchant_dialogue_bubble.tscn",
]
const XIAOCONG_DIALOGUE_SCENE_PATH := "res://scene/xiaocong_dialogue_bubble.tscn"
const BOSS_HUD_SCENE_PATH := "res://scene/boss/linglan/boss_health_hud.tscn"

var failures: Array[String] = []


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	for scene_path in DIALOGUE_SCENE_PATHS:
		_test_high_resolution_dialogue(scene_path)
	_test_native_xiaocong_dialogue()
	_test_high_resolution_boss_nameplate()
	await _test_wave_hud_feedback()
	await _test_currency_hud_feedback()

	if failures.is_empty():
		print("UI_FONT_RENDERING_SMOKE_TEST_OK")
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	quit(1)


func _test_high_resolution_dialogue(scene_path: String) -> void:
	var packed_scene := load(scene_path) as PackedScene
	_expect(packed_scene != null, "%s must load for the font contract test." % scene_path)
	if packed_scene == null:
		return
	var bubble := packed_scene.instantiate() as Node2D
	_expect(bubble != null, "%s must instantiate as a world-space dialogue bubble." % scene_path)
	if bubble == null:
		return
	var panel := bubble.get_node_or_null("BubblePanel") as Control
	var dialogue_text := bubble.get_node_or_null("BubblePanel/Margin/Content/Text") as RichTextLabel
	var name_label := bubble.get_node_or_null("NamePlate/Name") as Label
	var keyboard_prompt := bubble.get_node_or_null(
		"BubblePanel/Margin/Content/PromptRow/KeyboardPrompt"
	) as Label
	_expect(
		bubble.scale.is_equal_approx(Vector2(0.5, 0.5)),
		"%s must retain its authored high-resolution half-scale transform." % scene_path
	)
	_expect(
		panel != null and panel.size.is_equal_approx(Vector2(300.0, 116.0)),
		"%s must keep its double-resolution 300 x 116 internal panel size." % scene_path
	)
	_expect(
		dialogue_text != null and dialogue_text.get_theme_font_size("normal_font_size") == 17,
		"%s dialogue text must rasterize at the authored 17 px size before half-scaling." % scene_path
	)
	_expect(
		name_label != null and name_label.label_settings != null
		and name_label.label_settings.font_size == 18,
		"%s name text must rasterize at the authored 18 px size before half-scaling." % scene_path
	)
	_expect(
		keyboard_prompt != null and keyboard_prompt.label_settings != null
		and keyboard_prompt.label_settings.font_size == 11,
		"%s prompt text must rasterize at the authored 11 px size before half-scaling." % scene_path
	)
	bubble.free()


func _test_native_xiaocong_dialogue() -> void:
	var packed_scene := load(XIAOCONG_DIALOGUE_SCENE_PATH) as PackedScene
	_expect(packed_scene != null, "Xiaocong dialogue must load for the font contract test.")
	if packed_scene == null:
		return
	var bubble := packed_scene.instantiate() as Node2D
	var panel := bubble.get_node_or_null("BubblePanel") as Control
	var dialogue_text := bubble.get_node_or_null(
		"BubblePanel/Margin/Content/Text"
	) as RichTextLabel
	var name_label := bubble.get_node_or_null("NamePlate/Name") as Label
	var blip_audio := bubble.get_node_or_null("BlipAudio") as AudioStreamPlayer
	_expect(
		bubble.scale == Vector2.ONE
		and bubble.position == bubble.position.round()
		and panel != null
		and panel.custom_minimum_size == Vector2(308, 122),
		"Xiaocong dialogue must use an integer-positioned native screen-space layout."
	)
	_expect(
		dialogue_text != null
		and dialogue_text.get_theme_font_size("normal_font_size") == 17
		and name_label != null
		and name_label.label_settings.font_size == 18
		and blip_audio != null,
		"Xiaocong dialogue text and audio must stay native-resolution and non-positional."
	)
	bubble.free()


func _test_high_resolution_boss_nameplate() -> void:
	var packed_scene := load(BOSS_HUD_SCENE_PATH) as PackedScene
	_expect(packed_scene != null, "Boss HUD must load for the font contract test.")
	if packed_scene == null:
		return
	var hud := packed_scene.instantiate()
	var nameplate := hud.get_node_or_null("Root/Nameplate") as TextureRect
	var name_label := hud.get_node_or_null("Root/Nameplate/Name") as Label
	_expect(
		nameplate != null and nameplate.scale.is_equal_approx(Vector2(0.5, 0.5))
		and nameplate.size.is_equal_approx(Vector2(260.0, 79.4)),
		"Boss nameplate must retain its authored double-resolution half-scale layout."
	)
	_expect(
		name_label != null and name_label.label_settings != null
		and name_label.label_settings.font_size == 22
		and name_label.label_settings.outline_size == 4,
		"Boss name must rasterize at 22 px with a 4 px outline before half-scaling."
	)
	hud.free()


func _test_wave_hud_feedback() -> void:
	var wave_hud := (load("res://scene/wave_hud.tscn") as PackedScene).instantiate() as WaveHUD
	root.add_child(wave_hud)
	await process_frame
	wave_hud.call("_pulse_top_bar")
	await create_timer(0.1).timeout
	_expect(
		wave_hud.top_bar.scale.is_equal_approx(Vector2.ONE),
		"Wave HUD pulse feedback must never scale its status text."
	)
	wave_hud.show_victory()
	await create_timer(0.2).timeout
	_expect(
		wave_hud.result_panel.scale.is_equal_approx(Vector2.ONE),
		"Wave result feedback must never scale its text panel."
	)
	wave_hud.queue_free()
	await process_frame


func _test_currency_hud_feedback() -> void:
	var currency_hud := (load("res://scene/currency_hud.tscn") as PackedScene).instantiate() as CurrencyHUD
	root.add_child(currency_hud)
	await process_frame
	currency_hud.call("_on_xirang_changed", 123, 1)
	await create_timer(0.1).timeout
	_expect(
		currency_hud.panel.scale.is_equal_approx(Vector2.ONE),
		"Currency feedback must never scale its count text."
	)
	currency_hud.queue_free()
	await process_frame


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
