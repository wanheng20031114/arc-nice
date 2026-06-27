extends SceneTree

const LINGLAN_FRAMES := preload("res://resources/animation/linglan.tres")
const LINGLAN_CONFIG := preload("res://resources/config/enemies/linglan_boss.tres")
const BOSS_CONFIG_SCRIPT := preload("res://resources/config/bosses/boss_config.gd")
const LINGLAN_BOSS_ENTRY := preload("res://resources/config/bosses/boss_01_linglan.tres")
const LINGLAN_SCENE := preload("res://scene/linglan_boss.tscn")
const BOSS_HEALTH_HUD_SCENE := preload("res://scene/boss_health_hud.tscn")
const INTRO_VFX_SCENE := preload("res://scene/linglan_boss_intro_vfx.tscn")
const GAME_SCENE := preload("res://scene/game.tscn")
const DEFAULT_FLOW := preload("res://resources/config/flow/default_combat_flow.tres")

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
	await _test_host_boss_multiplayer_flow_signals()

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
		&"attack": 6,
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
		if animation_name == &"die":
			_expect(not LINGLAN_FRAMES.get_animation_loop(animation_name), "Linglan die animation must not loop.")
			_expect(is_equal_approx(LINGLAN_FRAMES.get_animation_speed(animation_name), 8.0), "Linglan die animation speed must match the authored dissolve timing.")
		if animation_name == &"attack":
			_expect(LINGLAN_FRAMES.get_animation_loop(animation_name), "Linglan attack animation must loop during boss casting phases.")
			_expect(is_equal_approx(LINGLAN_FRAMES.get_animation_speed(animation_name), 9.0), "Linglan attack animation speed mismatch.")
			for frame_index in range(LINGLAN_FRAMES.get_frame_count(animation_name)):
				var visible_rect := _get_texture_visible_rect(LINGLAN_FRAMES.get_frame_texture(animation_name, frame_index))
				var visible_bottom := visible_rect.position.y + visible_rect.size.y
				_expect(visible_bottom >= 364 and visible_bottom <= 366, "Linglan attack frame %d must keep the idle foot baseline." % frame_index)
				if frame_index == 0 or frame_index == LINGLAN_FRAMES.get_frame_count(animation_name) - 1:
					_expect(visible_rect.position.y <= 80, "Linglan attack endpoint frame %d must keep the authored body height." % frame_index)
					_expect(visible_rect.size.y >= 285, "Linglan attack endpoint frame %d must keep idle-scale body height." % frame_index)


func _test_boss_entry_resource() -> void:
	_expect(LINGLAN_BOSS_ENTRY.get_script() == BOSS_CONFIG_SCRIPT, "Linglan boss entry must use the BossConfig script.")
	_expect(LINGLAN_BOSS_ENTRY.boss_name == "铃兰", "Linglan boss entry must expose the display name.")
	_expect(LINGLAN_BOSS_ENTRY.enemy_config == null, "Linglan boss entry must keep Linglan config lazy-loaded.")
	_expect(LINGLAN_BOSS_ENTRY.step_id == &"boss_01_linglan", "Linglan boss entry must expose a flow step id.")
	_expect(LINGLAN_BOSS_ENTRY.post_clear_rest_duration == 0.0, "Linglan boss entry must use the shared post-clear rest field.")
	_expect(LINGLAN_BOSS_ENTRY.exits.is_empty(), "Linglan boss entry must be terminal in the default flow.")
	_expect(LINGLAN_BOSS_ENTRY.enemy_config_path == "res://resources/config/enemies/linglan_boss.tres", "Linglan boss entry must point to the Linglan enemy config path.")
	_expect(LINGLAN_BOSS_ENTRY.intro_vfx_scene_path == "res://scene/linglan_boss_intro_vfx.tscn", "Linglan boss entry must point to the configured intro VFX scene.")
	_expect(LINGLAN_BOSS_ENTRY.boss_hud_scene_path == "res://scene/boss_health_hud.tscn", "Linglan boss entry must point to the configured boss HUD scene.")
	_expect(LINGLAN_BOSS_ENTRY.music != null, "Linglan boss entry must configure a boss music stream.")
	if LINGLAN_BOSS_ENTRY.music != null:
		_expect(LINGLAN_BOSS_ENTRY.music.resource_path == "res://resources/audio/BGM_The_Truth_Never_Spoken.mp3", "Linglan boss music must use The Truth Never Spoken.")
		_expect(LINGLAN_BOSS_ENTRY.music.get(&"loop") == true, "Linglan boss music must loop.")
		_expect(is_equal_approx(float(LINGLAN_BOSS_ENTRY.music.get(&"loop_offset")), 1.0), "Linglan boss music must skip the first second after the first loop.")
	_expect(is_equal_approx(LINGLAN_BOSS_ENTRY.music_volume_db, 0.0), "Linglan boss music must use the louder boss-specific volume.")
	_expect(is_equal_approx(LINGLAN_BOSS_ENTRY.music_loop_offset, 1.0), "Linglan boss music must expose the configured loop offset.")
	_expect(LINGLAN_BOSS_ENTRY.get_enemy_config() == LINGLAN_CONFIG, "Linglan boss entry must resolve the Linglan enemy config on demand.")
	_expect(LINGLAN_CONFIG.max_health == 1000, "Linglan boss health must be configured to 1000.")
	_expect(LINGLAN_CONFIG.death_animation_name == &"die", "Linglan boss must play the sakura dissolve die animation on death.")
	_expect(DEFAULT_FLOW.get_step_by_id(&"boss_01_linglan") == LINGLAN_BOSS_ENTRY, "Default flow must include Linglan as a flow node.")
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
		_expect(is_equal_approx(sprite.scale.x, 0.148), "Linglan visual scale must match the authored boss scene.")
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
	var authored_frame := hud.get_node_or_null("Root/Frame") as TextureRect
	var authored_health_bar := hud.get_node_or_null("HealthBar") as ProgressBar
	var authored_nameplate := hud.get_node_or_null("Root/Nameplate") as TextureRect
	var authored_frame_position := authored_frame.position if authored_frame != null else Vector2.ZERO
	var authored_frame_size := authored_frame.size if authored_frame != null else Vector2.ZERO
	var authored_health_bar_position := authored_health_bar.position if authored_health_bar != null else Vector2.ZERO
	var authored_health_bar_size := authored_health_bar.size if authored_health_bar != null else Vector2.ZERO
	var authored_nameplate_position := authored_nameplate.position if authored_nameplate != null else Vector2.ZERO
	var authored_nameplate_size := authored_nameplate.size if authored_nameplate != null else Vector2.ZERO
	test_root.add_child(linglan)
	test_root.add_child(hud)
	await process_frame
	linglan.config = LINGLAN_CONFIG
	linglan.activate_boss(null, null)
	hud.show_for_boss(linglan, "铃兰")
	await process_frame

	var root_control := hud.get_node_or_null("Root") as Control
	var frame := hud.get_node_or_null("Root/Frame") as TextureRect
	var health_bar := hud.get_node_or_null("HealthBar") as ProgressBar
	var nameplate := hud.get_node_or_null("Root/Nameplate") as TextureRect
	var name_label := hud.get_node_or_null("Root/Nameplate/Name") as Label
	var max_health := LINGLAN_CONFIG.max_health
	_expect(root_control != null and root_control.visible, "Boss HUD root must become visible.")
	_expect(
		frame != null and frame.position == authored_frame_position and frame.size == authored_frame_size,
		"Boss HUD frame must keep the authored scene layout after runtime loading."
	)
	_expect(
		health_bar != null and health_bar.position == authored_health_bar_position and health_bar.size == authored_health_bar_size,
		"Boss HUD health bar must keep the authored scene layout after runtime loading."
	)
	_expect(
		nameplate != null and nameplate.position == authored_nameplate_position and nameplate.size == authored_nameplate_size,
		"Boss HUD nameplate must keep the authored scene layout after runtime loading."
	)
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
	_expect(game.get_node_or_null("BossContainer/LinglanBoss") == null, "Game must lazy-instantiate Linglan instead of loading boss art on scene entry.")
	_expect(game.get_node_or_null("BossHealthHUD") == null, "Game must lazy-instantiate the boss HUD instead of loading it on scene entry.")
	_expect(game.get_node_or_null("LinglanBossIntroVFX") == null, "Game must lazy-instantiate the boss intro VFX instead of loading it on scene entry.")

	var ground_layer := game.get_node("GroundTileMapLayer") as TileMapLayer
	var overlay_layer := game.get_node("OverlayTileMapLayer") as TileMapLayer
	var first_rect_cell := Vector2i(-3, -1)
	var last_rect_cell := Vector2i(18, 16)
	var outside_overlay_cell := Vector2i(-4, 8)
	overlay_layer.set_cell(Vector2i(0, 0), 0, Vector2i(0, 0), 0)
	overlay_layer.set_cell(outside_overlay_cell, 0, Vector2i(0, 0), 0)

	game.current_flow_step = LINGLAN_BOSS_ENTRY
	game.call("_begin_linglan_boss_intro", LINGLAN_BOSS_ENTRY)
	await process_frame
	_expect(game.wave_state == Game.WaveState.BOSS_INTRO, "Game must enter Linglan boss intro state.")
	var music_player := game.get_node("MusicPlayer") as AudioStreamPlayer
	_expect(music_player.stream == LINGLAN_BOSS_ENTRY.music, "Game must switch to Linglan boss music when the intro starts.")
	_expect(is_equal_approx(music_player.volume_db, LINGLAN_BOSS_ENTRY.music_volume_db), "Game must apply the Linglan boss music volume.")
	_expect(is_equal_approx(float(music_player.stream.get(&"loop_offset")), LINGLAN_BOSS_ENTRY.music_loop_offset), "Game must apply the Linglan boss music loop offset.")
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
		var hud_health_bar := hud.get_node_or_null("HealthBar") as ProgressBar
		_expect(hud_frame != null and hud_health_bar != null and hud_health_bar.visible, "Top boss HUD must use the authored large HUD nodes.")
	_expect(boss == null or boss.get_node_or_null("OverheadHUD") == null, "Linglan must not show a mini overhead HUD.")
	if boss != null:
		_expect(music_player.playing, "Linglan boss music must be playing before boss death.")
		music_player.stream_paused = false
		boss.apply_damage(boss.current_health)
		await process_frame
		_expect(music_player.stream_paused, "Linglan death must pause the active background music immediately.")

	game.queue_free()
	await process_frame
	await physics_frame


func _test_host_boss_multiplayer_flow_signals() -> void:
	var game := GAME_SCENE.instantiate() as Game
	_expect(game != null, "Game scene must instantiate for host Linglan boss sync.")
	if game == null:
		return
	game.auto_start_waves = false
	game.configure_multiplayer(Game.RuntimeMode.HOST_AUTHORITY, 1, {1: "host"})

	var flow_events: Array[Dictionary] = []
	var boss_events: Array[Dictionary] = []
	var victory_events := [0]
	game.multiplayer_flow_state_changed.connect(
		func(step_id: StringName, state: int, countdown_seconds: int) -> void:
			flow_events.append({
				"step_id": step_id,
				"state": state,
				"countdown_seconds": countdown_seconds,
			})
	)
	game.multiplayer_boss_started.connect(
		func(net_id: int, boss_config: BossConfig, spawn_position: Vector2) -> void:
			boss_events.append({
				"net_id": net_id,
				"boss_config": boss_config,
				"spawn_position": spawn_position,
			})
	)
	game.multiplayer_victory_started.connect(
		func() -> void:
			victory_events[0] += 1
	)

	test_root.add_child(game)
	await process_frame
	await physics_frame

	game.current_flow_step = LINGLAN_BOSS_ENTRY
	game.call("_begin_linglan_boss_intro", LINGLAN_BOSS_ENTRY)
	await process_frame
	game.call("_on_linglan_boss_intro_finished")
	await process_frame
	await physics_frame

	_expect(game.wave_state == Game.WaveState.BOSS_ACTIVE, "Host flow must activate Linglan boss.")
	_expect(boss_events.size() == 1, "Host must emit one boss_started event.")
	var boss_net_id := int(boss_events[0].get("net_id", 0)) if not boss_events.is_empty() else 0
	_expect(boss_net_id > 0, "Host boss_started event must include a network id.")
	var has_boss_active_flow_event := false
	for event in flow_events:
		if (
			event.get("step_id") == &"boss_01_linglan"
			and int(event.get("state", -1)) == int(Game.WaveState.BOSS_ACTIVE)
		):
			has_boss_active_flow_event = true
			break
	_expect(
		has_boss_active_flow_event,
		"Host must broadcast boss active flow state."
	)

	var snapshot_has_boss := false
	for state in game.collect_enemy_snapshot_states():
		if state.net_id == boss_net_id:
			snapshot_has_boss = true
			break
	_expect(snapshot_has_boss, "Host enemy snapshots must include the active boss.")

	var boss := game.linglan_boss
	_expect(boss != null and is_instance_valid(boss), "Host must keep a Linglan boss instance.")
	if boss != null and is_instance_valid(boss):
		boss.apply_damage(boss.current_health)
		await create_timer(1.5).timeout
		await process_frame
		_expect(game.wave_state == Game.WaveState.VICTORY, "Host boss defeat must advance the flow to victory.")
		_expect(victory_events[0] == 1, "Host must broadcast victory after terminal boss defeat.")

	game.queue_free()
	await process_frame
	await physics_frame


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)


func _get_texture_visible_rect(texture: Texture2D) -> Rect2i:
	if texture == null:
		return Rect2i()
	var image := texture.get_image()
	if image == null:
		return Rect2i()
	var min_x := image.get_width()
	var min_y := image.get_height()
	var max_x := -1
	var max_y := -1
	for y in range(image.get_height()):
		for x in range(image.get_width()):
			if image.get_pixel(x, y).a <= 0.01:
				continue
			min_x = mini(min_x, x)
			min_y = mini(min_y, y)
			max_x = maxi(max_x, x)
			max_y = maxi(max_y, y)
	if max_x < min_x or max_y < min_y:
		return Rect2i()
	return Rect2i(min_x, min_y, max_x - min_x + 1, max_y - min_y + 1)
