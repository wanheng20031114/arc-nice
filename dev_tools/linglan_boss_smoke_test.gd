extends SceneTree

const LINGLAN_FRAMES := preload("res://resources/animation/linglan.tres")
const LINGLAN_CONFIG := preload("res://resources/config/enemies/linglan_boss.tres")
const BOSS_CONFIG_SCRIPT := preload("res://resources/config/bosses/boss_config.gd")
const LINGLAN_BOSS_ENTRY := preload("res://resources/config/bosses/boss_01_linglan.tres")
const LINGLAN_SCENE := preload("res://scene/linglan_boss.tscn")
const BOSS_HEALTH_HUD_SCENE := preload("res://scene/boss_health_hud.tscn")
const INTRO_VFX_SCENE := preload("res://scene/linglan_boss_intro_vfx.tscn")
const GAME_SCENE := preload("res://scene/game.tscn")

var failures: Array[String] = []
var test_root: Node2D


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	test_root = Node2D.new()
	test_root.name = "LinglanBossSmokeTest"
	root.add_child(test_root)
	current_scene = test_root

	_test_animation_resource()
	_test_boss_entry_resource()
	await _test_boss_scene_contract()
	await _test_boss_hud_binding()
	await _test_intro_vfx_scene()
	await _test_game_boss_opening_flow()

	test_root.queue_free()
	for _cleanup_frame in range(4):
		await process_frame
		await physics_frame

	if failures.is_empty():
		print("LINGLAN_BOSS_SMOKE_TEST_OK")
		quit()
		return

	for failure in failures:
		push_error(failure)
	quit(1)


func _test_animation_resource() -> void:
	var expected_counts := {
		&"idle": 8,
		&"move": 8,
		&"move_up": 8,
		&"move_down": 8,
		&"move_left": 8,
		&"move_right": 8,
		&"idle_up": 1,
		&"idle_down": 1,
		&"idle_left": 1,
		&"idle_right": 1,
		&"die": 8,
	}
	for animation_name in expected_counts.keys():
		_expect(
			LINGLAN_FRAMES.has_animation(animation_name),
			"Linglan animation %s must exist." % animation_name
		)
		if not LINGLAN_FRAMES.has_animation(animation_name):
			continue
		_expect(
			LINGLAN_FRAMES.get_frame_count(animation_name) == expected_counts[animation_name],
			"Linglan animation %s has an unexpected frame count." % animation_name
		)
		var first_texture := LINGLAN_FRAMES.get_frame_texture(animation_name, 0)
		_expect(first_texture != null, "Linglan animation %s must have a texture." % animation_name)
		if first_texture != null:
			var frame_size := first_texture.get_size()
			_expect(frame_size.x >= 220.0 and frame_size.y >= 220.0, "Linglan boss frames must keep high-resolution pixel art detail.")
	_expect(not LINGLAN_FRAMES.get_animation_loop(&"die"), "Linglan die animation must not loop.")


func _test_boss_entry_resource() -> void:
	_expect(LINGLAN_BOSS_ENTRY.get_script() == BOSS_CONFIG_SCRIPT, "Linglan boss entry must use the BossConfig script.")
	_expect(LINGLAN_BOSS_ENTRY.boss_name == "铃兰", "Linglan boss entry must expose the display name.")
	_expect(LINGLAN_BOSS_ENTRY.enemy_config == LINGLAN_CONFIG, "Linglan boss entry must point to the Linglan enemy config.")
	_expect(LINGLAN_BOSS_ENTRY.starts_after_wave_number == 1, "Linglan boss entry must start after wave 1 for debugging.")
	_expect(LINGLAN_BOSS_ENTRY.arena_center == Vector2(128, 128), "Linglan boss entry must keep the center spawn point.")
	_expect(LINGLAN_BOSS_ENTRY.arena_floor_rect == Rect2i(-3, -1, 22, 18), "Linglan boss entry must only floor the requested arena rectangle.")


func _test_boss_scene_contract() -> void:
	var linglan := LINGLAN_SCENE.instantiate() as LinglanBoss
	_expect(linglan != null, "Linglan scene must instantiate as LinglanBoss.")
	if linglan == null:
		return
	_expect(linglan.visible, "Linglan scene root must stay visible for editor-side tuning.")
	test_root.add_child(linglan)
	await process_frame
	await physics_frame

	_expect(linglan is Enemy, "Linglan boss must inherit Enemy so player bullets can hit it.")
	linglan.config = LINGLAN_CONFIG
	linglan.activate_boss(null, null)
	await process_frame
	await physics_frame

	var sprite := linglan.get_node_or_null("AnimatedSprite2D") as AnimatedSprite2D
	_expect(sprite != null, "Linglan scene must include AnimatedSprite2D.")
	if sprite != null:
		_expect(sprite.sprite_frames == LINGLAN_FRAMES, "Linglan sprite must use linglan.tres.")
		_expect(sprite.animation == &"idle", "Linglan scene must default to idle.")
		_expect(is_equal_approx(sprite.scale.x, 0.318), "Linglan visual scale must be close to twice the player height.")
		_expect(sprite.scale.y == sprite.scale.x, "Linglan visual scale must stay uniform.")

	var body_shape := linglan.get_node_or_null("CollisionShape2D") as CollisionShape2D
	var touch_shape := linglan.get_node_or_null("TouchDamageArea/CollisionShape2D") as CollisionShape2D
	_expect(body_shape != null and body_shape.shape is CapsuleShape2D, "Linglan must have a capsule body collision.")
	_expect(touch_shape != null and touch_shape.shape is CapsuleShape2D, "Linglan must have a capsule touch/damage area.")
	if body_shape != null and body_shape.shape is CapsuleShape2D:
		var body_capsule := body_shape.shape as CapsuleShape2D
		_expect(body_capsule.radius <= 13.0 and body_capsule.height <= 44.0, "Linglan boss body collision must match its smaller visual scale.")
	if touch_shape != null and touch_shape.shape is CapsuleShape2D:
		var touch_capsule := touch_shape.shape as CapsuleShape2D
		_expect(touch_capsule.radius <= 16.0 and touch_capsule.height <= 50.0, "Linglan touch collision must match its smaller visual scale.")

	var max_health := LINGLAN_CONFIG.max_health
	_expect(linglan.current_health == max_health, "Linglan must start with its configured max health.")
	_expect(linglan.apply_damage(125, Vector2.RIGHT), "Linglan must accept player-style damage.")
	_expect(linglan.current_health == max_health - 125, "Linglan health did not decrease after damage.")
	_expect(linglan.get_node_or_null("OverheadHUD") == null, "Linglan must not use an overhead mini HUD.")
	linglan.queue_free()
	await process_frame


func _test_boss_hud_binding() -> void:
	var linglan := LINGLAN_SCENE.instantiate() as LinglanBoss
	var hud := BOSS_HEALTH_HUD_SCENE.instantiate() as BossHealthHUD
	_expect(linglan != null and hud != null, "Linglan HUD test scenes must instantiate.")
	if linglan == null or hud == null:
		return
	var authored_hud_root := hud.get_node_or_null("Root") as Control
	_expect(authored_hud_root != null and authored_hud_root.visible, "Boss HUD root must stay visible in the authored scene for editor tuning.")
	test_root.add_child(linglan)
	test_root.add_child(hud)
	await process_frame
	linglan.config = LINGLAN_CONFIG
	linglan.activate_boss(null, null)
	hud.show_for_boss(linglan, "铃兰")
	await process_frame

	var root_control := hud.get_node_or_null("Root") as Control
	var frame := hud.get_node_or_null("Root/Frame") as TextureRect
	var health_bar := hud.get_node_or_null("Root/HealthBar") as ProgressBar
	var name_label := hud.get_node_or_null("Root/Nameplate/Name") as Label
	var max_health := LINGLAN_CONFIG.max_health
	_expect(root_control != null and root_control.visible, "Boss HUD root must become visible.")
	_expect(frame != null and frame.size.x <= 760.0 and frame.size.y <= 130.0, "Boss HUD frame must stay within the designed top bar size.")
	_expect(health_bar != null and health_bar.max_value == float(max_health), "Boss HUD must use Linglan max health.")
	_expect(name_label != null and name_label.text == "铃兰", "Boss HUD must show Linglan's Chinese name.")
	linglan.apply_damage(500)
	await process_frame
	_expect(health_bar != null and health_bar.value == float(max_health - 500), "Boss HUD must track Linglan damage.")

	hud.queue_free()
	linglan.queue_free()
	await process_frame


func _test_intro_vfx_scene() -> void:
	var intro := INTRO_VFX_SCENE.instantiate() as LinglanBossIntroVFX
	_expect(intro != null, "Linglan intro VFX scene must instantiate.")
	if intro == null:
		return
	test_root.add_child(intro)
	await process_frame
	intro.play_intro(Vector2(128, 128))
	await process_frame
	_expect(intro.visible, "Intro VFX must become visible while playing.")
	_expect((intro.get_node("ConvergenceSprite") as AnimatedSprite2D).sprite_frames != null, "Intro VFX must include convergence animation frames.")
	intro.stop_intro()
	intro.queue_free()
	await process_frame


func _test_game_boss_opening_flow() -> void:
	var game := GAME_SCENE.instantiate() as Game
	_expect(game != null, "Game scene must instantiate for Linglan boss flow.")
	if game == null:
		return
	game.auto_start_waves = false
	test_root.add_child(game)
	await process_frame
	await physics_frame

	_expect(game.bosses.size() == 1, "Game must load the Linglan boss entry.")
	if game.bosses.size() >= 1:
		_expect(game.bosses[0] == LINGLAN_BOSS_ENTRY, "Game boss list must use boss_01_linglan.")

	var ground_layer := game.get_node("GroundTileMapLayer") as TileMapLayer
	var overlay_layer := game.get_node("OverlayTileMapLayer") as TileMapLayer
	var first_rect_cell := Vector2i(-3, -1)
	var last_rect_cell := Vector2i(18, 16)
	var outside_overlay_cell := Vector2i(-4, 8)
	overlay_layer.set_cell(Vector2i(0, 0), 0, Vector2i(0, 0), 0)
	overlay_layer.set_cell(outside_overlay_cell, 0, Vector2i(0, 0), 0)

	game.current_wave_index = 0
	game.call("_begin_linglan_boss_intro")
	await process_frame
	_expect(game.wave_state == Game.WaveState.BOSS_INTRO, "Game must enter Linglan boss intro state.")
	var boss := game.get_node_or_null("BossContainer/LinglanBoss") as LinglanBoss
	_expect(boss != null and not boss.visible, "Linglan must stay hidden during petal convergence.")

	_expect(
		ground_layer.get_cell_source_id(first_rect_cell) == 0 and ground_layer.get_cell_atlas_coords(first_rect_cell) == Vector2i(0, 0),
		"Boss opening must convert the requested rectangle start to floor tiles."
	)
	_expect(
		ground_layer.get_cell_source_id(last_rect_cell) == 0 and ground_layer.get_cell_atlas_coords(last_rect_cell) == Vector2i(0, 0),
		"Boss opening must convert the requested rectangle end to floor tiles."
	)
	_expect(overlay_layer.get_cell_source_id(Vector2i(0, 0)) == -1, "Boss opening must clear overlay cells inside the requested rectangle.")
	_expect(
		overlay_layer.get_cell_source_id(outside_overlay_cell) != -1,
		"Boss opening must leave overlay cells outside the requested rectangle untouched."
	)

	game.call("_on_linglan_boss_intro_finished")
	await process_frame
	await physics_frame
	_expect(game.wave_state == Game.WaveState.BOSS_ACTIVE, "Game must activate Linglan after intro VFX.")
	_expect(boss != null and boss.visible and boss.current_health == LINGLAN_CONFIG.max_health, "Linglan must appear active with configured health.")
	var hud := game.get_node_or_null("BossHealthHUD") as BossHealthHUD
	_expect(hud != null and (hud.get_node("Root") as Control).visible, "Top boss HUD must appear after Linglan activates.")
	if hud != null:
		var hud_frame := hud.get_node_or_null("Root/Frame") as TextureRect
		_expect(hud_frame != null and hud_frame.size.x <= 760.0 and hud_frame.size.y <= 130.0, "Top boss HUD must stay inside its bounded layout.")
	_expect(boss == null or boss.get_node_or_null("OverheadHUD") == null, "Linglan must not show a mini overhead HUD.")

	game.queue_free()
	await process_frame
	await physics_frame


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
