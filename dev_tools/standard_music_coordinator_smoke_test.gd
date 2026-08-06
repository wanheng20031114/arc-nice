extends SceneTree

const STANDARD_GAME_SCENE := preload(
	"res://scene/game_modes/standard/standard_game.tscn"
)
const WAVE_04 := preload("res://resources/config/waves/wave_04.tres")

var failures: Array[String] = []
var test_root: Node2D


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	test_root = Node2D.new()
	test_root.name = "StandardMusicCoordinatorSmokeTest"
	root.add_child(test_root)
	current_scene = test_root

	_test_source_boundaries()
	await _test_static_binding_fade_and_music_rules()

	test_root.queue_free()
	for _cleanup_frame in range(6):
		await process_frame
		await physics_frame
	if failures.is_empty():
		print("STANDARD_MUSIC_COORDINATOR_SMOKE_TEST_OK")
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	quit(1)


func _test_source_boundaries() -> void:
	var root_source := FileAccess.get_file_as_string(
		"res://scene/game_modes/standard/standard_game.gd"
	)
	var coordinator_source := FileAccess.get_file_as_string(
		"res://scene/game_modes/standard/music/standard_music_coordinator.gd"
	)
	var standard_scene := FileAccess.get_file_as_string(
		"res://scene/game_modes/standard/standard_game.tscn"
	)
	for concrete_rule in [
		"stream.get_property_list()",
		"stream.set(&\"loop\"",
		"node_name.contains(\"bgm\")",
		"_pause_background_music_players(child)",
	]:
		_expect(
			not root_source.contains(concrete_rule),
			"StandardGame 根不得继续实现音乐具体规则：%s。" % concrete_rule
		)
	for forbidden_dependency in [
		"StandardGame",
		"TowerDefense",
		"Rogue",
		"current_scene",
		"get_tree()",
		"get_parent()",
		"get_node(",
		"get_node_or_null(",
		"has_method(",
		"call(",
	]:
		_expect(
			not coordinator_source.contains(forbidden_dependency),
			"StandardMusicCoordinator 不得反向猜测模式根或其他模式：%s。"
			% forbidden_dependency
		)
	_expect(
		root_source.contains(
			"standard_music.bind_dependencies(music_player, self)"
		),
		"StandardGame 必须显式注入 MusicPlayer 与背景音乐递归 scope。"
	)
	_expect(
		not root_source.contains("StandardMusicCoordinator.new(")
		and not root_source.contains("standard_music_coordinator.tscn\").instantiate"),
		"StandardGame 不得动态创建 MusicCoordinator。"
	)
	_expect(
		standard_scene.contains(
			"res://scene/game_modes/standard/music/standard_music_coordinator.tscn"
		)
		and standard_scene.contains("[node name=\"MusicCoordinator\""),
		"StandardGame 场景必须静态实例化 MusicCoordinator。"
	)
	_expect(
		standard_scene.contains(
			"[node name=\"MusicPlayer\" type=\"AudioStreamPlayer\" parent=\".\""
		)
		and standard_scene.contains("bus = &\"Music\"")
		and standard_scene.contains("volume_db = -6.0"),
		"原 MusicPlayer 节点、Music 总线与 -6 dB 配置必须保持不变。"
	)


func _test_static_binding_fade_and_music_rules() -> void:
	var game := STANDARD_GAME_SCENE.instantiate() as StandardGame
	_expect(game != null, "StandardGame 必须可实例化用于音乐协调器测试。")
	if game == null:
		return
	game.auto_start_waves = false
	var music_player := game.get_node("MusicPlayer") as AudioStreamPlayer
	music_player.autoplay = false

	var pending_fade := test_root.create_tween()
	pending_fade.tween_interval(60.0)
	pending_fade.pause()
	game.set("music_fade_tween", pending_fade)
	_expect(
		game.get("music_fade_tween") == pending_fade,
		"pre-ready music_fade_tween 必须由根 backing 保持。"
	)

	test_root.add_child(game)
	await process_frame
	await physics_frame
	var coordinator := game.get_node_or_null(
		"MusicCoordinator"
	) as StandardMusicCoordinator
	_expect(
		coordinator != null
		and coordinator.is_bound()
		and coordinator.get_music_player() == music_player,
		"静态 MusicCoordinator 必须显式绑定原 MusicPlayer。"
	)
	_expect(
		game.get("music_fade_tween") == pending_fade
		and coordinator.music_fade_tween == pending_fade,
		"绑定后 music_fade_tween façade 必须迁移同一 Tween 真源。"
	)
	game.set("music_fade_tween", null)
	pending_fade.kill()
	_expect(
		game.get("music_fade_tween") == null
		and coordinator.music_fade_tween == null,
		"绑定后的 music_fade_tween 写入必须同步协调器。"
	)

	_test_null_and_non_loop_stream_rules(game, music_player)
	await _test_wave_post_wave_boss_and_fade_rules(game, music_player)
	await _test_recursive_pause_rules(game, music_player)

	_stop_audio_players(game)
	game.queue_free()
	await process_frame
	await physics_frame


func _test_null_and_non_loop_stream_rules(
	game: StandardGame,
	music_player: AudioStreamPlayer
) -> void:
	var initial_stream := music_player.stream
	var initial_volume := music_player.volume_db
	music_player.stream_paused = true
	var initial_paused := music_player.stream_paused
	var initial_playing := music_player.playing
	game.call(
		"_play_music_stream",
		null,
		-2.0,
		4.0,
		true
	)
	_expect(
		music_player.stream == initial_stream
		and is_equal_approx(music_player.volume_db, initial_volume)
		and music_player.stream_paused == initial_paused
		and music_player.playing == initial_playing
		and game.get("music_fade_tween") == null,
		"null stream 必须完全保持当前播放器与 fade 状态。"
	)

	var generator := AudioStreamGenerator.new()
	_expect(
		not bool(game.call("_audio_stream_has_property", generator, &"loop"))
		and not bool(
			game.call(
				"_audio_stream_has_property",
				generator,
				&"loop_offset"
			)
		),
		"无 loop 属性的 AudioStream 类型必须被准确识别。"
	)
	game.call("_configure_music_loop", generator, 8.0)


func _test_wave_post_wave_boss_and_fade_rules(
	game: StandardGame,
	music_player: AudioStreamPlayer
) -> void:
	game.call("_update_wave_music", WAVE_04)
	var wave_fade := game.get("music_fade_tween") as Tween
	_expect(
		music_player.stream == WAVE_04.music
		and music_player.playing
		and not music_player.stream_paused
		and is_equal_approx(
			music_player.volume_db,
			StandardGame.MUSIC_FADE_IN_START_VOLUME_DB
		)
		and wave_fade != null,
		"wave music 必须在 MusicPlayer 上以 -12 dB 开始 3 秒 fade。"
	)
	if wave_fade != null:
		game.call(
			"_play_music_stream",
			WAVE_04.music,
			-2.0,
			1.25,
			false
		)
		_expect(
			game.get("music_fade_tween") == wave_fade
			and is_equal_approx(
				music_player.volume_db,
				StandardGame.MUSIC_FADE_IN_START_VOLUME_DB
			),
			"相同且正在播放的 stream 必须只解 pause，不得重启或替换 fade。"
		)
		_expect(
			_read_float_property(WAVE_04.music, &"loop_offset") == 1.25,
			"same-stream 守卫前仍必须更新 loop_offset。"
		)
		wave_fade.custom_step(StandardGame.MUSIC_FADE_IN_SECONDS + 0.25)
		await process_frame
		_expect(
			game.get("music_fade_tween") == null
			and is_equal_approx(
				music_player.volume_db,
				StandardGame.DEFAULT_MUSIC_VOLUME_DB
			),
			"fade 完成后必须到达 -6 dB 并清空 Tween 真源。"
		)

	game.call("_update_post_wave_music", WAVE_04)
	var post_fade := game.get("music_fade_tween") as Tween
	_expect(
		music_player.stream == WAVE_04.post_wave_music
		and post_fade != null,
		"post-wave music 必须来自完成波次并建立同款 fade。"
	)

	var boss_stream := WAVE_04.music.duplicate() as AudioStream
	var boss_config := BossConfig.new()
	boss_config.music = boss_stream
	boss_config.music_volume_db = -4.5
	boss_config.music_loop_offset = 2.75
	game.call("_update_boss_music", boss_config)
	_expect(
		post_fade == null or not post_fade.is_valid(),
		"切换 Boss music 必须 kill 先前 post-wave fade。"
	)
	_expect(
		music_player.stream == boss_stream
		and music_player.playing
		and is_equal_approx(music_player.volume_db, -4.5)
		and game.get("music_fade_tween") == null
		and _read_bool_property(boss_stream, &"loop")
		and is_equal_approx(
			_read_float_property(boss_stream, &"loop_offset"),
			2.75
		),
		"Boss music 必须保持独立音量、loop 与 loop_offset，且不 fade。"
	)

	var replacement_stream := WAVE_04.post_wave_music.duplicate() as AudioStream
	game.call("_play_music_stream", replacement_stream, -5.0, 0.0, true)
	var replacement_fade := game.get("music_fade_tween") as Tween
	_expect(replacement_fade != null, "替换 stream 必须建立新的 fade Tween。")
	game.call("_stop_music_fade_tween")
	_expect(
		game.get("music_fade_tween") == null
		and (
			replacement_fade == null
			or not replacement_fade.is_valid()
		),
		"显式停止 fade 必须 kill Tween 并清空 façade。"
	)


func _test_recursive_pause_rules(
	game: StandardGame,
	music_player: AudioStreamPlayer
) -> void:
	var nested_root := Node.new()
	nested_root.name = "NestedAudioScope"
	game.add_child(nested_root)
	var deeper_root := Node2D.new()
	deeper_root.name = "DeeperAudioScope"
	nested_root.add_child(deeper_root)
	var sample_stream := _create_long_audio_stream()

	var bus_music := AudioStreamPlayer.new()
	bus_music.name = "Ambience"
	bus_music.bus = &"Music"
	bus_music.stream = sample_stream
	nested_root.add_child(bus_music)
	var named_bgm := AudioStreamPlayer2D.new()
	named_bgm.name = "AmbientBGM"
	named_bgm.bus = &"SFX"
	named_bgm.stream = sample_stream
	deeper_root.add_child(named_bgm)
	var named_music := AudioStreamPlayer3D.new()
	named_music.name = "WorldMusicLayer"
	named_music.bus = &"SFX"
	named_music.stream = sample_stream
	deeper_root.add_child(named_music)
	var deep_bus_music := AudioStreamPlayer.new()
	deep_bus_music.name = "DeepAmbience"
	deep_bus_music.bus = &"Music"
	deep_bus_music.stream = sample_stream
	deeper_root.add_child(deep_bus_music)
	var plain_sfx := AudioStreamPlayer.new()
	plain_sfx.name = "Dialogue"
	plain_sfx.bus = &"SFX"
	plain_sfx.stream = sample_stream
	nested_root.add_child(plain_sfx)
	var stopped_music := AudioStreamPlayer.new()
	stopped_music.name = "StoppedMusic"
	stopped_music.bus = &"Music"
	stopped_music.stream = sample_stream
	nested_root.add_child(stopped_music)

	bus_music.play()
	named_bgm.play()
	named_music.play()
	deep_bus_music.play()
	plain_sfx.play()
	await process_frame
	await physics_frame
	_expect(named_bgm.playing, "2D BGM 测试播放器必须先进入播放状态。")
	_expect(named_music.playing, "3D Music 测试播放器必须先进入播放状态。")
	_expect(
		bool(game.call("_is_background_music_player", named_bgm)),
		"2D BGM 测试播放器必须命中背景音乐分类。"
	)
	_expect(
		bool(game.call("_is_background_music_player", named_music)),
		"3D Music 测试播放器必须命中背景音乐分类。"
	)
	music_player.stream_paused = false
	var fade_stream := WAVE_04.music.duplicate() as AudioStream
	game.call("_play_music_stream", fade_stream, -6.0, 0.0, true)
	var active_fade := game.get("music_fade_tween") as Tween
	game.pause_all_background_music()
	_expect(
		active_fade != null
		and not active_fade.is_valid()
		and game.get("music_fade_tween") == null,
		"pause_all_background_music 必须先 kill 活跃 fade。"
	)
	_expect(music_player.stream_paused, "根 MusicPlayer 必须被递归暂停。")
	_expect(bus_music.stream_paused, "Music 总线的 1D 播放器必须被递归暂停。")
	_expect(
		deep_bus_music.stream_paused,
		"深层 scope 内的 1D Music 播放器必须被递归暂停。"
	)
	_expect(
		not plain_sfx.stream_paused
		and not stopped_music.stream_paused,
		"递归暂停不得影响纯 SFX 或未播放的音乐节点。"
	)


func _read_bool_property(stream: AudioStream, property_name: StringName) -> bool:
	if stream == null:
		return false
	for property in stream.get_property_list():
		if property.get("name") == property_name:
			return bool(stream.get(property_name))
	return false


func _read_float_property(
	stream: AudioStream,
	property_name: StringName
) -> float:
	if stream == null:
		return -1.0
	for property in stream.get_property_list():
		if property.get("name") == property_name:
			return float(stream.get(property_name))
	return -1.0


func _create_long_audio_stream() -> AudioStreamWAV:
	var stream := AudioStreamWAV.new()
	stream.format = AudioStreamWAV.FORMAT_8_BITS
	stream.mix_rate = 8000
	stream.stereo = false
	var sample_data := PackedByteArray()
	sample_data.resize(80000)
	sample_data.fill(128)
	stream.data = sample_data
	return stream


func _stop_audio_players(root_node: Node) -> void:
	for child in root_node.get_children():
		if child is AudioStreamPlayer:
			(child as AudioStreamPlayer).stop()
			(child as AudioStreamPlayer).stream = null
		elif child is AudioStreamPlayer2D:
			(child as AudioStreamPlayer2D).stop()
			(child as AudioStreamPlayer2D).stream = null
		elif child is AudioStreamPlayer3D:
			(child as AudioStreamPlayer3D).stop()
			(child as AudioStreamPlayer3D).stream = null
		_stop_audio_players(child)


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
