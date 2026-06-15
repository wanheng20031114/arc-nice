extends SceneTree

const GAME_SCENE := preload("res://scene/game.tscn")
const BASIC_CONFIG := preload("res://resources/config/enemies/yuanshi_insect_basic.tres")
const DEFAULT_WAVES: Array[WaveConfig] = [
	preload("res://resources/config/waves/wave_01.tres"),
	preload("res://resources/config/waves/wave_02.tres"),
	preload("res://resources/config/waves/wave_03.tres"),
]
const MERCHANT_FRAMES := preload("res://resources/animation/zhuangfangyi.tres")

const STATE_PRE_WAVE := 0
const STATE_WAVE_ACTIVE := 1
const STATE_INTERMISSION := 2
const STATE_VICTORY := 3
const STATE_DEFEAT := 4

var failures: Array[String] = []
var test_root: Node2D


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	test_root = Node2D.new()
	test_root.name = "WaveSystemSmokeTest"
	root.add_child(test_root)
	current_scene = test_root

	_test_default_wave_resources()
	_test_merchant_asset()
	await _test_wave_state_flow()
	await _test_defeat_stops_flow()
	test_root.queue_free()
	await process_frame
	await physics_frame
	for _cleanup_frame in range(4):
		await process_frame
		await physics_frame

	if failures.is_empty():
		print("WAVE_SYSTEM_SMOKE_TEST_OK")
		quit()
		return

	for failure in failures:
		push_error(failure)
	quit(1)


func _test_default_wave_resources() -> void:
	var expected_totals := [15, 24, 32]
	var expected_rests := [30.0, 30.0, 0.0]
	for wave_index in range(DEFAULT_WAVES.size()):
		var wave_config := DEFAULT_WAVES[wave_index]
		_expect(wave_config != null, "Wave %d resource is missing." % (wave_index + 1))
		if wave_config == null:
			continue
		_expect(
			wave_config.get_total_enemy_count() == expected_totals[wave_index],
			"Wave %d total must be %d." % [wave_index + 1, expected_totals[wave_index]]
		)
		_expect(
			is_equal_approx(
				wave_config.rest_duration_after_wave,
				expected_rests[wave_index]
			),
			"Wave %d rest duration is incorrect." % (wave_index + 1)
		)
		_expect(wave_config.music != null, "Wave %d music is missing." % (wave_index + 1))
		_expect(
			wave_config.max_alive_enemies == 100,
			"Wave %d max alive enemies must be 100." % (wave_index + 1)
		)
		for entry in wave_config.enemy_entries:
			_expect(entry != null, "Wave %d contains a null entry." % (wave_index + 1))
			if entry != null:
				_expect(
					entry.enemy_config != null and entry.count > 0,
					"Wave %d contains an invalid enemy entry." % (wave_index + 1)
				)


func _test_merchant_asset() -> void:
	_expect(MERCHANT_FRAMES.has_animation(&"idle"), "Merchant idle animation is missing.")
	_expect(
		MERCHANT_FRAMES.get_frame_count(&"idle") == 8,
		"Merchant idle animation must contain 8 frames."
	)
	_expect(
		is_equal_approx(MERCHANT_FRAMES.get_animation_speed(&"idle"), 8.0),
		"Merchant idle animation must run at 8 FPS."
	)

	var texture := load("res://resources/texture/zhuangfangyi_idle.png") as Texture2D
	var image := texture.get_image() if texture != null else null
	_expect(image != null and not image.is_empty(), "Merchant runtime sprite sheet is missing.")
	if image == null or image.is_empty():
		return
	_expect(image.get_size() == Vector2i(448, 68), "Merchant sheet must be 448x68.")
	_expect(image.get_format() == Image.FORMAT_RGBA8, "Merchant sheet must use RGBA8.")
	for frame_index in range(8):
		var frame_rect := Rect2i(frame_index * 56, 0, 56, 68)
		var frame := image.get_region(frame_rect)
		_expect(not frame.is_invisible(), "Merchant frame %d is empty." % frame_index)
		var frame_bbox := frame.get_used_rect()
		_expect(
			frame_bbox.size.y >= 63 and frame_bbox.size.y <= 64,
			"Merchant frame %d has an unexpected subject height." % frame_index
		)
		for corner in [Vector2i(0, 0), Vector2i(55, 0), Vector2i(0, 67), Vector2i(55, 67)]:
			_expect(
				frame.get_pixelv(corner).a == 0.0,
				"Merchant frame %d has a non-transparent corner." % frame_index
			)

func _test_wave_state_flow() -> void:
	var game := _create_test_game()
	test_root.add_child(game)
	await process_frame
	await physics_frame

	var merchant := game.get_node("ZhuangfangyiMerchant") as Node2D
	var merchant_sprite := merchant.get_node("AnimatedSprite2D") as AnimatedSprite2D
	var merchant_collision := (
		merchant.get_node("StaticBody2D/CollisionShape2D") as CollisionShape2D
	)
	var wave_hud := game.get_node("WaveHUD") as WaveHUD
	var test_waves := _create_test_waves(3)
	game.set("waves", test_waves)
	game.set("pre_wave_duration", 5.0)
	game.call("_enter_pre_wave", 0)

	_expect(
		merchant_sprite.scale == Vector2(0.3125, 0.3125),
		"Merchant display size must be controlled by the scene scale."
	)
	_expect(
		merchant_collision.shape != null,
		"Merchant must provide a blocking collision shape."
	)
	_expect(
		wave_hud.has_node("WaveInfoBar"),
		"Wave HUD must expose WaveInfoBar as an editable scene node."
	)
	_expect(game.get("wave_state") == STATE_PRE_WAVE, "Game did not enter PRE_WAVE.")
	_expect(game.get("countdown_seconds") == 5, "Opening countdown must start at 5.")
	_expect(not merchant.visible, "Merchant appeared during the opening countdown.")
	_expect(merchant_collision.disabled, "Merchant collision was active before intermission.")
	_expect(wave_hud.status_label.text.contains("5"), "Wave HUD did not show opening countdown.")

	game.call("_begin_wave", 0)
	await physics_frame
	_expect(game.get("wave_state") == STATE_WAVE_ACTIVE, "Wave 1 did not start.")
	_expect(game.get("current_wave_total") == 1, "Test wave total is incorrect.")
	_expect(not merchant.visible, "Merchant remained visible during combat.")
	_expect(
		wave_hud.status_label.text == "第 1 波  已消灭 0/1",
		"Wave HUD combat text is incorrect."
	)
	await _defeat_only_enemy(game)

	_expect(game.get("wave_state") == STATE_INTERMISSION, "Wave 1 did not enter intermission.")
	_expect(game.get("countdown_seconds") == 30, "Intermission must last 30 seconds.")
	_expect(merchant.visible, "Merchant did not appear during intermission.")
	await physics_frame
	_expect(not merchant_collision.disabled, "Merchant collision did not activate.")
	_expect(wave_hud.status_label.text.contains("30"), "HUD did not show intermission countdown.")

	game.set("countdown_seconds", 6)
	game.call("_on_state_timer_timeout")
	_expect(game.get("countdown_seconds") == 5, "Final countdown did not reach 5.")
	_expect(wave_hud.status_label.text.contains("5"), "HUD did not emphasize final countdown.")

	game.call("_begin_wave", 1)
	await physics_frame
	_expect(not merchant.visible, "Merchant did not hide when wave 2 began.")
	await physics_frame
	_expect(merchant_collision.disabled, "Merchant collision remained active during combat.")
	await _defeat_only_enemy(game)
	_expect(game.get("wave_state") == STATE_INTERMISSION, "Wave 2 did not enter intermission.")

	game.call("_begin_wave", 2)
	await physics_frame
	await _defeat_only_enemy(game)
	_expect(game.get("wave_state") == STATE_VICTORY, "Third wave did not enter victory.")
	_expect(not merchant.visible, "Merchant remained visible after victory.")
	_expect(wave_hud.result_overlay.visible, "Victory overlay is hidden.")
	_expect(wave_hud.result_label.text == "通关", "Victory text is incorrect.")
	var player := game.get_node("Player") as Player
	_expect(not player.controls_locked, "Victory incorrectly locked player controls.")

	game.queue_free()
	await process_frame
	await physics_frame


func _test_defeat_stops_flow() -> void:
	var game := _create_test_game()
	test_root.add_child(game)
	await process_frame
	await physics_frame

	game.set("waves", _create_test_waves(1))
	game.call("_begin_wave", 0)
	await physics_frame
	var player := game.get_node("Player") as Player
	player.apply_damage(player.current_health)
	await physics_frame

	_expect(game.get("wave_state") == STATE_DEFEAT, "Player death did not enter DEFEAT.")
	_expect((game.get_node("EnemySpawnTimer") as Timer).is_stopped(), "Spawn timer kept running.")
	_expect((game.get_node("StateTimer") as Timer).is_stopped(), "State timer kept running.")
	_expect(
		not (game.get_node("ZhuangfangyiMerchant") as Node2D).visible,
		"Merchant remained visible after defeat."
	)

	game.queue_free()
	await process_frame
	await physics_frame


func _create_test_game() -> Node2D:
	var game := GAME_SCENE.instantiate() as Node2D
	game.set("auto_start_waves", false)
	var music_player := game.get_node("MusicPlayer") as AudioStreamPlayer
	music_player.autoplay = false
	return game


func _create_test_waves(wave_count: int) -> Array[WaveConfig]:
	var result: Array[WaveConfig] = []
	for wave_index in range(wave_count):
		var entry := WaveEnemyEntry.new()
		entry.enemy_config = BASIC_CONFIG
		entry.count = 1
		var wave_config := WaveConfig.new()
		wave_config.wave_name = "测试波次 %d" % (wave_index + 1)
		wave_config.enemy_entries = [entry]
		wave_config.spawn_interval = 60.0
		wave_config.max_alive_enemies = 1
		wave_config.rest_duration_after_wave = 30.0
		result.append(wave_config)
	return result


func _defeat_only_enemy(game: Node2D) -> void:
	var enemy_container := game.get_node("EnemyContainer") as Node2D
	var enemy: YuanshiInsect = null
	for child in enemy_container.get_children():
		enemy = child as YuanshiInsect
		if enemy != null:
			break
	_expect(enemy != null, "Wave did not spawn its enemy.")
	if enemy == null:
		return
	enemy.apply_damage(enemy.current_health)
	for _frame_index in range(45):
		await physics_frame


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
