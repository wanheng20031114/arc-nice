extends SceneTree

const LINGLAN_FRAMES := preload("res://resources/animation/linglan.tres")
const LINGLAN_CONFIG := preload("res://resources/config/enemies/linglan_boss.tres")
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


func _test_boss_scene_contract() -> void:
	var linglan := LINGLAN_SCENE.instantiate() as LinglanBoss
	_expect(linglan != null, "Linglan scene must instantiate as LinglanBoss.")
	if linglan == null:
		return
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

	var body_shape := linglan.get_node_or_null("CollisionShape2D") as CollisionShape2D
	var touch_shape := linglan.get_node_or_null("TouchDamageArea/CollisionShape2D") as CollisionShape2D
	_expect(body_shape != null and body_shape.shape is CapsuleShape2D, "Linglan must have a capsule body collision.")
	_expect(touch_shape != null and touch_shape.shape is CapsuleShape2D, "Linglan must have a capsule touch/damage area.")
	if body_shape != null and body_shape.shape is CapsuleShape2D:
		_expect((body_shape.shape as CapsuleShape2D).radius >= 18.0, "Linglan boss body collision must not keep a small enemy radius.")

	_expect(linglan.current_health == 2000, "Linglan must start with 2000 health.")
	_expect(linglan.apply_damage(125, Vector2.RIGHT), "Linglan must accept player-style damage.")
	_expect(linglan.current_health == 1875, "Linglan health did not decrease after damage.")
	linglan.queue_free()
	await process_frame


func _test_boss_hud_binding() -> void:
	var linglan := LINGLAN_SCENE.instantiate() as LinglanBoss
	var hud := BOSS_HEALTH_HUD_SCENE.instantiate() as BossHealthHUD
	_expect(linglan != null and hud != null, "Linglan HUD test scenes must instantiate.")
	if linglan == null or hud == null:
		return
	test_root.add_child(linglan)
	test_root.add_child(hud)
	await process_frame
	linglan.config = LINGLAN_CONFIG
	linglan.activate_boss(null, null)
	hud.show_for_boss(linglan, "铃兰")
	await process_frame

	var health_bar := hud.get_node_or_null("Root/HealthBar") as TextureProgressBar
	var name_label := hud.get_node_or_null("Root/Nameplate/Name") as Label
	_expect(health_bar != null and health_bar.max_value == 2000.0, "Boss HUD must use Linglan max health.")
	_expect(name_label != null and name_label.text == "铃兰", "Boss HUD must show Linglan's Chinese name.")
	linglan.apply_damage(500)
	await process_frame
	_expect(health_bar != null and health_bar.value == 1500.0, "Boss HUD must track Linglan damage.")

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

	game.current_wave_index = game.waves.size() - 1
	game.call("_begin_linglan_boss_intro")
	await process_frame
	_expect(game.wave_state == Game.WaveState.BOSS_INTRO, "Game must enter Linglan boss intro state.")
	var boss := game.get_node_or_null("BossContainer/LinglanBoss") as LinglanBoss
	_expect(boss != null and not boss.visible, "Linglan must stay hidden during petal convergence.")

	var ground_layer := game.get_node("GroundTileMapLayer") as TileMapLayer
	var used_rect := ground_layer.get_used_rect()
	var inner_cell := used_rect.position + Vector2i(1, 1)
	_expect(
		ground_layer.get_cell_source_id(inner_cell) == 0 and ground_layer.get_cell_atlas_coords(inner_cell) == Vector2i(0, 0),
		"Boss opening must convert inner arena cells to floor tiles."
	)

	game.call("_on_linglan_boss_intro_finished")
	await process_frame
	await physics_frame
	_expect(game.wave_state == Game.WaveState.BOSS_ACTIVE, "Game must activate Linglan after intro VFX.")
	_expect(boss != null and boss.visible and boss.current_health == 2000, "Linglan must appear active with 2000 health.")
	var hud := game.get_node_or_null("BossHealthHUD") as BossHealthHUD
	_expect(hud != null and (hud.get_node("Root") as Control).visible, "Boss health HUD must appear after Linglan activates.")

	game.queue_free()
	await process_frame
	await physics_frame


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
