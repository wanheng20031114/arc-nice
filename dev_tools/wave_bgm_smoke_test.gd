extends SceneTree

const GAME_SCENE := preload("res://scene/game.tscn")
const WAVE_04 := preload("res://resources/config/waves/wave_04.tres")
const WAVE_07 := preload("res://resources/config/waves/wave_07.tres")

const EXPECTED_WAVE_MUSIC := {
	4: {
		"combat": "res://resources/audio/shenmu_forest_combat.ogg",
		"intermission": "res://resources/audio/shenmu_forest_intermission.ogg",
	},
	5: {
		"combat": "res://resources/audio/shenmu_forest_combat.ogg",
		"intermission": "res://resources/audio/shenmu_forest_intermission.ogg",
	},
	6: {
		"combat": "res://resources/audio/shenmu_forest_combat.ogg",
		"intermission": "res://resources/audio/shenmu_forest_intermission.ogg",
	},
	7: {
		"combat": "res://resources/audio/shenmu_swamp_combat.ogg",
		"intermission": "res://resources/audio/shenmu_swamp_intermission.ogg",
	},
	8: {
		"combat": "res://resources/audio/shenmu_swamp_combat.ogg",
		"intermission": "res://resources/audio/shenmu_swamp_intermission.ogg",
	},
	9: {
		"combat": "res://resources/audio/shenmu_swamp_combat.ogg",
		"intermission": "res://resources/audio/shenmu_swamp_intermission.ogg",
	},
	10: {
		"combat": "res://resources/audio/shenmu_town_combat.ogg",
		"intermission": "res://resources/audio/shenmu_town_intermission.ogg",
	},
	11: {
		"combat": "res://resources/audio/shenmu_town_combat.ogg",
		"intermission": "res://resources/audio/shenmu_town_intermission.ogg",
	},
	12: {
		"combat": "res://resources/audio/shenmu_town_combat.ogg",
		"intermission": "res://resources/audio/shenmu_town_intermission.ogg",
	},
}

var failures: Array[String] = []
var test_root: Node2D


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	test_root = Node2D.new()
	test_root.name = "WaveBGMSmokeTest"
	root.add_child(test_root)
	current_scene = test_root

	_test_wave_music_config()
	await _test_wave_music_fade()
	await _test_intermission_music_owner_and_fade()

	test_root.queue_free()
	await _drain_cleanup_frames()

	if failures.is_empty():
		print("WAVE_BGM_SMOKE_TEST_OK")
		quit()
		return

	for failure in failures:
		push_error(failure)
	quit(1)


func _test_wave_music_config() -> void:
	for wave_number in EXPECTED_WAVE_MUSIC.keys():
		var wave := load("res://resources/config/waves/wave_%02d.tres" % wave_number) as WaveConfig
		var expected := EXPECTED_WAVE_MUSIC[wave_number] as Dictionary
		_expect(wave != null, "Wave %02d must load." % wave_number)
		if wave == null:
			continue
		_expect(
			_stream_path(wave.music) == expected["combat"],
			"Wave %02d combat BGM path mismatch." % wave_number
		)
		_expect(
			_stream_path(wave.post_wave_music) == expected["intermission"],
			"Wave %02d intermission BGM path mismatch." % wave_number
		)
		_expect(_stream_loops(wave.music), "Wave %02d combat BGM must loop." % wave_number)
		_expect(_stream_loops(wave.post_wave_music), "Wave %02d intermission BGM must loop." % wave_number)


func _test_wave_music_fade() -> void:
	var game := _create_game()
	test_root.add_child(game)
	await process_frame

	game.call("_update_wave_music", WAVE_04)
	var music_player := game.get_node("MusicPlayer") as AudioStreamPlayer
	_expect(_stream_path(music_player.stream) == _stream_path(WAVE_04.music), "Wave combat BGM did not start.")
	_expect(music_player.playing, "Wave combat BGM player must be playing.")
	_expect(
		_float_close(music_player.volume_db, Game.MUSIC_FADE_IN_START_VOLUME_DB, 0.05),
		"Wave combat BGM must start at the fade-in floor."
	)
	await _finish_music_fade(game)
	_expect(
		_float_close(music_player.volume_db, Game.DEFAULT_MUSIC_VOLUME_DB, 0.2),
		"Wave combat BGM must fade to the default music volume."
	)

	_stop_audio_players(game)
	game.queue_free()
	await _drain_cleanup_frames()


func _test_intermission_music_owner_and_fade() -> void:
	var game := _create_game()
	test_root.add_child(game)
	await process_frame

	game.set("current_flow_step", WAVE_04)
	game.call("_enter_intermission", WAVE_07)
	var music_player := game.get_node("MusicPlayer") as AudioStreamPlayer
	_expect(
		_stream_path(music_player.stream) == _stream_path(WAVE_04.post_wave_music),
		"Intermission BGM must come from the completed wave."
	)
	_expect(
		_stream_path(music_player.stream) != _stream_path(WAVE_07.post_wave_music),
		"Intermission BGM must not come from the next wave."
	)
	_expect(music_player.playing, "Intermission BGM player must be playing.")
	_expect(
		_float_close(music_player.volume_db, Game.MUSIC_FADE_IN_START_VOLUME_DB, 0.05),
		"Intermission BGM must start at the fade-in floor."
	)
	await _finish_music_fade(game)
	_expect(
		_float_close(music_player.volume_db, Game.DEFAULT_MUSIC_VOLUME_DB, 0.2),
		"Intermission BGM must fade to the default music volume."
	)

	_stop_audio_players(game)
	game.queue_free()
	await _drain_cleanup_frames()


func _create_game() -> Game:
	var game := GAME_SCENE.instantiate() as Game
	game.auto_start_waves = false
	var music_player := game.get_node("MusicPlayer") as AudioStreamPlayer
	music_player.autoplay = false
	return game


func _finish_music_fade(game: Game) -> void:
	var fade_tween := game.get("music_fade_tween") as Tween
	_expect(fade_tween != null, "Music fade tween must be active.")
	if fade_tween != null:
		fade_tween.custom_step(Game.MUSIC_FADE_IN_SECONDS + 0.25)
	await process_frame


func _drain_cleanup_frames() -> void:
	for _cleanup_frame in range(4):
		await process_frame
		await physics_frame


func _stream_path(stream: AudioStream) -> String:
	if stream == null:
		return ""
	return stream.resource_path


func _stream_loops(stream: AudioStream) -> bool:
	if stream == null:
		return false
	for property in stream.get_property_list():
		if property.get("name") == &"loop":
			return bool(stream.get(&"loop"))
	return false


func _stop_audio_players(node: Node) -> void:
	for child in node.get_children():
		var audio_player := child as AudioStreamPlayer
		if audio_player != null:
			audio_player.stop()
			audio_player.stream = null
		var audio_player_2d := child as AudioStreamPlayer2D
		if audio_player_2d != null:
			audio_player_2d.stop()
			audio_player_2d.stream = null
		_stop_audio_players(child)


func _float_close(actual: float, expected: float, tolerance: float) -> bool:
	return absf(actual - expected) <= tolerance


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
