extends SceneTree

var game_scene: PackedScene = null
var basic_config: EnemyConfig = null
var default_campaign: WaveCampaignConfig = null
var default_waves: Array[WaveConfig] = []
var merchant_frames: SpriteFrames = null

const DEFAULT_CAMPAIGN_PATH := (
	"res://resources/config/campaigns/standard/singleplayer/campaign.tres"
)

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
	var selected_case := OS.get_environment("ARC_WAVE_SMOKE_CASE")
	test_root = Node2D.new()
	test_root.name = "WaveSystemSmokeTest"
	root.add_child(test_root)
	current_scene = test_root

	if selected_case.is_empty():
		_load_test_resources("resources")
		_test_default_wave_resources()
		_test_merchant_asset()
		_release_test_resources()
		await process_frame
		_load_test_resources("flow")
		_test_game_scene_wave_list()
		await _test_grid_pathfinder_budget()
		await _test_wave_state_flow()
		await _test_defeat_stops_flow()
	else:
		_load_test_resources(selected_case)
	match selected_case:
		"resources":
			_test_default_wave_resources()
			_test_merchant_asset()
		"scene":
			_test_game_scene_wave_list()
		"pathfinder":
			await _test_grid_pathfinder_budget()
		"flow":
			await _test_wave_state_flow()
		"defeat":
			await _test_defeat_stops_flow()
		_:
			if not selected_case.is_empty():
				failures.append(
					"Unknown ARC_WAVE_SMOKE_CASE: %s" % selected_case
				)
	current_scene = null
	test_root.queue_free()
	test_root = null
	await process_frame
	await physics_frame
	for _cleanup_frame in range(4):
		await process_frame
		await physics_frame
	_release_test_resources()
	await process_frame

	if failures.is_empty():
		print("WAVE_SYSTEM_SMOKE_TEST_OK")
		quit()
		return

	for failure in failures:
		push_error(failure)
	quit(1)


func _test_default_wave_resources() -> void:
	var expected_rests := [20.0, 20.0, 20.0, 20.0, 20.0, 30.0, 30.0, 30.0, 30.0, 30.0, 30.0, 30.0]
	_expect(default_campaign != null, "Formal Standard Campaign resource is missing.")
	if default_campaign == null:
		return
	_expect(
		default_campaign.resource_path == DEFAULT_CAMPAIGN_PATH,
		"Wave resources must come from the formal Standard Campaign."
	)
	_expect(
		default_campaign.validate_campaign().is_empty(),
		"Formal Standard Campaign content closure is invalid."
	)
	_expect(default_waves.size() == expected_rests.size(), "Formal Standard Campaign must contain 12 waves.")
	for wave_index in range(mini(default_waves.size(), expected_rests.size())):
		var wave_config := default_waves[wave_index]
		_expect(wave_config != null, "Wave %d resource is missing." % (wave_index + 1))
		if wave_config == null:
			continue
		_expect(
			wave_config.get_total_enemy_count() > 0,
			"Wave %d must contain at least one enemy." % (wave_index + 1)
		)
		_expect(
			is_equal_approx(
				wave_config.post_clear_rest_duration,
				expected_rests[wave_index]
			),
			"Wave %d rest duration is incorrect." % (wave_index + 1)
		)
		_expect(wave_config.music != null, "Wave %d music is missing." % (wave_index + 1))
		_expect(
			wave_config.max_alive_enemies > 0,
			"Wave %d max alive enemies must be positive." % (wave_index + 1)
		)
		for entry in wave_config.enemy_entries:
			_expect(entry != null, "Wave %d contains a null entry." % (wave_index + 1))
			if entry != null:
				_expect(
					entry.enemy_config != null and entry.count >= 0,
					"Wave %d contains an invalid enemy entry." % (wave_index + 1)
				)


func _test_game_scene_wave_list() -> void:
	_expect(game_scene != null, "StandardGame scene resource failed to load.")
	if game_scene == null:
		return
	var game := game_scene.instantiate() as Node2D
	_expect(game != null, "StandardGame scene failed to instantiate.")
	if game == null:
		return
	var campaign_configured := bool(game.call("_configure_active_campaign"))
	_expect(campaign_configured, "StandardGame scene must configure its singleplayer Campaign.")
	var configured_campaign := game.get("singleplayer_campaign") as WaveCampaignConfig
	_expect(
		configured_campaign != null
		and configured_campaign.resource_path == DEFAULT_CAMPAIGN_PATH,
		"StandardGame must bind the formal singleplayer Campaign resource."
	)
	var game_waves: Array = game.get("waves")
	var flow_graph := game.get("flow_graph") as FlowGraphConfig
	_expect(game_waves.size() == 12, "StandardGame scene must load 12 waves.")
	_expect(flow_graph != null, "StandardGame scene must load the default flow graph.")
	if flow_graph != null:
		_expect(flow_graph.start_step == game_waves[0], "Default flow must start at the first wave.")
		_expect(flow_graph.steps.size() >= game_waves.size() + 1, "Default flow must include waves plus the boss node.")
		_expect(flow_graph.get_step_by_id(&"boss_01_linglan") is BossConfig, "Default flow must include the Linglan boss node.")
	if game_waves.size() >= 1:
		var first_wave := game_waves[0] as WaveConfig
		_expect(first_wave != null, "StandardGame first wave resource is missing.")
		if first_wave != null:
			_expect(first_wave.get_total_enemy_count() > 0, "StandardGame first wave must contain enemies.")
	if game_waves.size() >= 12:
		var final_wave := game_waves[11] as WaveConfig
		_expect(
			final_wave != null and final_wave.get_total_enemy_count() == 560,
			"StandardGame final normal wave must include the late-game enemy set."
		)
	game.free()


func _test_merchant_asset() -> void:
	_expect(merchant_frames != null, "Merchant SpriteFrames resource failed to load.")
	if merchant_frames == null:
		return
	_expect(merchant_frames.has_animation(&"idle"), "Merchant idle animation is missing.")
	_expect(
		merchant_frames.get_frame_count(&"idle") == 8,
		"Merchant idle animation must contain 8 frames."
	)
	_expect(
		is_equal_approx(merchant_frames.get_animation_speed(&"idle"), 6.5),
		"Merchant idle animation must run at 6.5 FPS."
	)

	var texture := load("res://resources/texture/zhuangfangyi_idle.png") as Texture2D
	var image := texture.get_image() if texture != null else null
	_expect(image != null and not image.is_empty(), "Merchant runtime sprite sheet is missing.")
	if image == null or image.is_empty():
		return
	_expect(image.get_size() == Vector2i(256, 32), "Merchant sheet must be 256x32.")
	_expect(image.get_format() == Image.FORMAT_RGBA8, "Merchant sheet must use RGBA8.")
	for frame_index in range(8):
		var frame_rect := Rect2i(frame_index * 32, 0, 32, 32)
		var frame := image.get_region(frame_rect)
		_expect(not frame.is_invisible(), "Merchant frame %d is empty." % frame_index)
		var frame_bbox := frame.get_used_rect()
		_expect(
			frame_bbox.size.y >= 29 and frame_bbox.size.y <= 30,
			"Merchant frame %d has an unexpected subject height." % frame_index
		)
		for corner in [Vector2i(0, 0), Vector2i(31, 0), Vector2i(0, 31), Vector2i(31, 31)]:
			_expect(
				frame.get_pixelv(corner).a == 0.0,
				"Merchant frame %d has a non-transparent corner." % frame_index
			)


func _test_grid_pathfinder_budget() -> void:
	_expect(game_scene != null, "Pathfinder case requires a loaded StandardGame scene.")
	if game_scene == null:
		return
	var game := _create_test_game()
	test_root.add_child(game)
	await process_frame
	await physics_frame
	# Keep the fixture's own navigation prewarmer/player callbacks from consuming
	# the single-query budget while this test exercises the counter directly.
	game.process_mode = Node.PROCESS_MODE_DISABLED

	var pathfinder := game.get_node("GridPathfinder") as GridPathfinder
	var player := game.get_node("Player") as Player
	_expect(pathfinder != null, "StandardGame must provide GridPathfinder.")
	_expect(player != null, "StandardGame must provide Player for pathfinder budget test.")
	if pathfinder == null or player == null:
		game.queue_free()
		await process_frame
		return

	pathfinder.max_path_queries_per_physics_frame = 1
	var from_position := player.global_position
	var first_result: Variant = pathfinder.try_get_global_path(
		from_position,
		from_position + Vector2(16.0, 0.0)
	)
	var second_result: Variant = pathfinder.try_get_global_path(
		from_position,
		from_position + Vector2(32.0, 0.0)
	)
	_expect(first_result != null, "Pathfinder first query in a frame must be allowed.")
	_expect(second_result == null, "Pathfinder must reject queries after the per-frame budget is exhausted.")

	var budget_process_frame := pathfinder.path_query_budget_frame
	await physics_frame
	var catch_up_result: Variant = pathfinder.try_get_global_path(
		from_position,
		from_position + Vector2(48.0, 0.0)
	)
	if Engine.get_process_frames() == budget_process_frame:
		_expect(
			catch_up_result == null,
			"Catch-up physics ticks in one render frame must share one path budget."
		)
	var budget_frame_after_catch_up := pathfinder.path_query_budget_frame
	var render_frame_wait_count := 0
	while (
		Engine.get_process_frames() == budget_frame_after_catch_up
		and render_frame_wait_count < 120
	):
		await process_frame
		render_frame_wait_count += 1
	_expect(
		Engine.get_process_frames() != budget_frame_after_catch_up,
		"Pathfinder test did not reach a new rendered/process frame within 120 frames."
	)
	if Engine.get_process_frames() == budget_frame_after_catch_up:
		game.queue_free()
		await process_frame
		return
	var next_render_result: Variant = pathfinder.try_get_global_path(
		from_position,
		from_position + Vector2(48.0, 0.0)
	)
	_expect(
		next_render_result != null,
		(
			"Pathfinder budget must reset on the next rendered/process frame "
			+ "(process=%d budget=%d used=%d)."
		) % [
			Engine.get_process_frames(),
			pathfinder.path_query_budget_frame,
			pathfinder.path_queries_used_this_frame,
		]
	)

	game.queue_free()
	await process_frame
	await physics_frame


func _test_wave_state_flow() -> void:
	_expect(game_scene != null, "Flow case requires a loaded StandardGame scene.")
	_expect(basic_config != null, "Flow case requires a loaded EnemyConfig.")
	if game_scene == null or basic_config == null:
		return
	var game := _create_test_game()
	test_root.add_child(game)
	await process_frame
	await physics_frame

	var merchant := game.get_node("ZhuangfangyiMerchant") as Node2D
	var merchant_sprite := merchant.get_node("AnimatedSprite2D") as AnimatedSprite2D
	var merchant_collision := (
		merchant.get_node("StaticBody2D/CollisionShape2D") as CollisionShape2D
	)
	var wave_hud := game.get_node("WaveHUD") as StandardWaveHUD
	var test_waves := _configure_test_campaign(game, 3)
	game.set("pre_wave_duration", 5.0)
	game.call("_enter_pre_flow_step", test_waves[0])

	_expect(
		merchant_sprite.scale == Vector2.ONE,
		"Merchant v2 must render at native 32px sprite scale."
	)
	_expect(
		merchant_collision.shape != null,
		"Merchant must provide a blocking collision shape."
	)
	_expect(
		wave_hud.has_node("WaveInfoBar"),
		"Wave HUD must expose WaveInfoBar as an editable scene node."
	)
	_expect(game.get("wave_state") == STATE_PRE_WAVE, "StandardGame did not enter PRE_WAVE.")
	_expect(game.get("countdown_seconds") == 5, "Opening countdown must start at 5.")
	_expect(
		not (game.get_node("CountdownAudio") as AudioStreamPlayer).playing,
		"Countdown tick must not play before final 3 seconds."
	)
	_expect(not merchant.visible, "Merchant appeared during the opening countdown.")
	_expect(merchant_collision.disabled, "Merchant collision was active before intermission.")
	_expect(wave_hud.status_label.text.contains("5"), "Wave HUD did not show opening countdown.")

	game.call("_begin_flow_step", test_waves[0])
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

	game.set("countdown_seconds", 4)
	game.call("_on_state_timer_timeout")
	_expect(game.get("countdown_seconds") == 3, "Final countdown did not reach 3.")
	_expect(
		is_equal_approx((game.get_node("CountdownAudio") as AudioStreamPlayer).pitch_scale, 1.0),
		"Final countdown pitch must be 1.0 at 3 seconds."
	)
	_expect(wave_hud.status_label.text.contains("3"), "HUD did not emphasize final countdown.")
	game.call("_on_state_timer_timeout")
	_expect(
		is_equal_approx((game.get_node("CountdownAudio") as AudioStreamPlayer).pitch_scale, 1.0),
		"Final countdown pitch must stay 1.0 at 2 seconds."
	)

	game.call("_begin_flow_step", test_waves[1])
	await physics_frame
	_expect(not merchant.visible, "Merchant did not hide when wave 2 began.")
	await physics_frame
	_expect(merchant_collision.disabled, "Merchant collision remained active during combat.")
	await _defeat_only_enemy(game)
	_expect(game.get("wave_state") == STATE_INTERMISSION, "Wave 2 did not enter intermission.")

	game.call("_begin_flow_step", test_waves[2])
	await physics_frame
	await _defeat_only_enemy(game)
	_expect(game.get("wave_state") == STATE_VICTORY, "Third wave did not enter victory.")
	_expect(not merchant.visible, "Merchant remained visible after victory.")
	_expect(wave_hud.result_overlay.visible, "Victory overlay is hidden.")
	_expect(wave_hud.result_title.text == "通关", "Victory text is incorrect.")
	var player := game.get_node("Player") as Player
	_expect(not player.controls_locked, "Victory incorrectly locked player controls.")

	game.queue_free()
	await process_frame
	await physics_frame


func _test_defeat_stops_flow() -> void:
	_expect(game_scene != null, "Defeat case requires a loaded StandardGame scene.")
	_expect(basic_config != null, "Defeat case requires a loaded EnemyConfig.")
	if game_scene == null or basic_config == null:
		return
	var game := _create_test_game()
	test_root.add_child(game)
	await process_frame
	await physics_frame

	var test_waves := _configure_test_campaign(game, 1)
	game.call("_begin_flow_step", test_waves[0])
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

	_settle_remaining_wave_enemies(game)
	game.queue_free()
	await process_frame
	await physics_frame


func _create_test_game() -> Node2D:
	var game := game_scene.instantiate() as Node2D
	game.set("auto_start_waves", false)
	var music_player := game.get_node("MusicPlayer") as AudioStreamPlayer
	music_player.autoplay = false
	return game


func _create_test_waves(wave_count: int) -> Array[WaveConfig]:
	var result: Array[WaveConfig] = []
	for wave_index in range(wave_count):
		var entry := WaveEnemyEntry.new()
		entry.enemy_config = basic_config
		entry.count = 1
		var wave_config := WaveConfig.new()
		wave_config.step_id = StringName("test_wave_%02d" % (wave_index + 1))
		wave_config.wave_name = "测试波次 %d" % (wave_index + 1)
		wave_config.enemy_entries = [entry]
		wave_config.spawn_interval = 60.0
		wave_config.max_alive_enemies = 1
		wave_config.post_clear_rest_duration = 30.0
		result.append(wave_config)
	for wave_index in range(result.size() - 1):
		var flow_exit := FlowExitConfig.new()
		flow_exit.exit_name = FlowExitConfig.DEFAULT_EXIT_NAME
		flow_exit.target_step_id = result[wave_index + 1].step_id
		result[wave_index].exits = [flow_exit]
	return result


func _configure_test_campaign(game: Node2D, wave_count: int) -> Array[WaveConfig]:
	var test_waves := _create_test_waves(wave_count)
	var flow_graph := FlowGraphConfig.new()
	flow_graph.graph_name = "Smoke Test Flow"
	flow_graph.steps.assign(test_waves)
	flow_graph.start_step = test_waves[0] if not test_waves.is_empty() else null

	var campaign := WaveCampaignConfig.new()
	campaign.campaign_id = &"wave_system_smoke_test"
	campaign.flow_graph = flow_graph
	game.set("singleplayer_campaign", campaign)
	_expect(
		bool(game.call("_configure_active_campaign")),
		"Test Campaign must initialize through the flow-only Campaign path."
	)
	return test_waves


func _defeat_only_enemy(game: Node2D) -> void:
	var enemy_container := game.get_node("EnemyContainer") as Node2D
	var enemy: Enemy = null
	for child in enemy_container.get_children():
		enemy = child as Enemy
		if enemy != null:
			break
	_expect(enemy != null, "Wave did not spawn its enemy.")
	if enemy == null:
		return
	enemy.apply_damage(enemy.current_health)
	for _frame_index in range(45):
		await physics_frame


func _settle_remaining_wave_enemies(game: Node2D) -> void:
	var enemy_container := game.get_node("EnemyContainer") as Node2D
	for child in enemy_container.get_children():
		var enemy := child as Enemy
		if enemy == null:
			continue
		_expect(
			bool(
				game.call(
					"try_resolve_active_wave_enemy",
					enemy.get_instance_id(),
					CombatTypes.EnemyTerminalReason.REMOVED
				)
			),
			"Defeat cleanup must resolve every remaining wave enemy through the Campaign owner."
		)


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)


func _load_test_resources(selected_case: String) -> void:
	if selected_case in ["", "scene", "pathfinder", "flow", "defeat"]:
		game_scene = load(
			"res://scene/game_modes/standard/standard_game.tscn"
		) as PackedScene
	if selected_case in ["", "flow", "defeat"]:
		basic_config = load(
			"res://resources/config/enemies/yuanshi_insect_basic.tres"
		) as EnemyConfig
	if selected_case in ["", "resources"]:
		default_campaign = load(DEFAULT_CAMPAIGN_PATH) as WaveCampaignConfig
		merchant_frames = load(
			"res://resources/animation/zhuangfangyi.tres"
		) as SpriteFrames
		if default_campaign != null:
			default_waves.assign(default_campaign.get_waves())


func _release_test_resources() -> void:
	default_waves.clear()
	game_scene = null
	basic_config = null
	default_campaign = null
	merchant_frames = null
