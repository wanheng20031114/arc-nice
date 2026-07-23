extends SceneTree

const LIMITER := preload("res://scene/enemy_attack_audio_limiter.gd")
const RAPID_STREAM := preload("res://resources/audio/capoo_smg_fire.wav")
const HEAVY_STREAM := preload("res://resources/audio/capoo_rpg_launch.wav")

const ATTACK_AUDIO_CALL_SITES := {
	"res://scene/enemy/capoo/capoo_smg.gd": "play_rapid_fire(attack_audio)",
	"res://scene/enemy/capoo/capoo_ak47.gd": "play_rapid_fire(attack_audio)",
	"res://scene/enemy/capoo/capoo_mage.gd": "play_heavy_attack(attack_audio)",
	"res://scene/enemy/capoo/capoo_knight.gd": "play_heavy_attack(attack_audio)",
	"res://scene/enemy/capoo/capoo_rpg.gd": "play_heavy_attack(attack_audio)",
	"res://scene/enemy/capoo/capoo_sniper.gd": "play_heavy_attack(attack_audio)",
	"res://scene/enemy/yuanshi_insect/yuanshi_insect_fire_ranged.gd": (
		"play_heavy_attack(attack_audio)"
	),
}

var failures: Array[String] = []
var fixture: Node2D
var original_limiting_enabled := true


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	original_limiting_enabled = LIMITER.limiting_enabled
	fixture = Node2D.new()
	fixture.name = "EnemyAttackAudioLimiterSmokeTest"
	root.add_child(fixture)
	current_scene = fixture
	var camera := Camera2D.new()
	camera.enabled = true
	fixture.add_child(camera)
	await process_frame

	_test_call_site_contract()
	_test_independent_voice_caps_and_metrics()
	_test_direct_play_ab_switch()

	LIMITER.limiting_enabled = original_limiting_enabled
	_stop_and_free_audio_children()
	current_scene = null
	fixture.queue_free()
	for _cleanup_frame in range(4):
		await process_frame
		await physics_frame

	if failures.is_empty():
		print("ENEMY_ATTACK_AUDIO_LIMITER_SMOKE_TEST_OK")
		quit()
		return
	for failure in failures:
		push_error(failure)
	quit(1)


func _test_call_site_contract() -> void:
	for script_path in ATTACK_AUDIO_CALL_SITES:
		var source := FileAccess.get_file_as_string(script_path)
		_expect(
			source.contains(str(ATTACK_AUDIO_CALL_SITES[script_path])),
			"%s must route attack audio through the shared limiter." % script_path
		)
		_expect(
			not source.contains("attack_audio.play()"),
			"%s must not retain a direct attack_audio.play() path." % script_path
		)


func _test_independent_voice_caps_and_metrics() -> void:
	LIMITER.limiting_enabled = true
	LIMITER.reset_metrics()
	var rapid_players: Array[AudioStreamPlayer2D] = []
	for index in range(LIMITER.MAX_SIMULTANEOUS_RAPID_FIRE_VOICES + 3):
		var player := _add_audio_player(
			RAPID_STREAM,
			-10.0,
			Vector2(40.0 + float(index) * 8.0, 0.0)
		)
		rapid_players.append(player)
		LIMITER.play_rapid_fire(player)

	var heavy_players: Array[AudioStreamPlayer2D] = []
	for index in range(LIMITER.MAX_SIMULTANEOUS_HEAVY_ATTACK_VOICES + 2):
		var player := _add_audio_player(
			HEAVY_STREAM,
			-12.0,
			Vector2(40.0 + float(index) * 8.0, 24.0)
		)
		heavy_players.append(player)
		LIMITER.play_heavy_attack(player)

	var metrics := LIMITER.get_metrics()
	_expect(
		_count_playing(rapid_players)
		== LIMITER.MAX_SIMULTANEOUS_RAPID_FIRE_VOICES,
		"Rapid gunfire must obey its independent eight-voice cap."
	)
	_expect(
		_count_playing(heavy_players)
		== LIMITER.MAX_SIMULTANEOUS_HEAVY_ATTACK_VOICES,
		"Heavy attacks and spells must obey their independent six-voice cap."
	)
	_expect(
		int(metrics[&"requests"]) == rapid_players.size() + heavy_players.size()
		and int(metrics[&"admitted"])
		== (
			LIMITER.MAX_SIMULTANEOUS_RAPID_FIRE_VOICES
			+ LIMITER.MAX_SIMULTANEOUS_HEAVY_ATTACK_VOICES
		)
		and int(metrics[&"rejected"]) == 5,
		"Limiter request/admission/rejection metrics must match voice arbitration."
	)
	_expect(
		int(metrics[&"rapid_peak"])
		== LIMITER.MAX_SIMULTANEOUS_RAPID_FIRE_VOICES
		and int(metrics[&"heavy_peak"])
		== LIMITER.MAX_SIMULTANEOUS_HEAVY_ATTACK_VOICES
		and int(metrics[&"peak_active"])
		== (
			LIMITER.MAX_SIMULTANEOUS_RAPID_FIRE_VOICES
			+ LIMITER.MAX_SIMULTANEOUS_HEAVY_ATTACK_VOICES
		),
		"Limiter peak metrics must expose each category and their combined peak."
	)
	_expect(
		is_equal_approx(rapid_players[0].volume_db, -10.0)
		and is_equal_approx(rapid_players[1].volume_db, -12.0),
		"Rapid-fire stacks must use the configured two-decibel attenuation ladder."
	)
	_expect(
		is_equal_approx(heavy_players[0].volume_db, -12.0)
		and is_equal_approx(heavy_players[1].volume_db, -15.0),
		"Heavy stacks must use the configured three-decibel attenuation ladder."
	)

	_stop_audio_players(rapid_players)
	_stop_audio_players(heavy_players)
	_expect(
		LIMITER.get_active_voice_count(
			self,
			LIMITER.AttackAudioClass.RAPID_FIRE
		) == 0
		and LIMITER.get_active_voice_count(
			self,
			LIMITER.AttackAudioClass.HEAVY_ATTACK
		) == 0,
		"Stopped attack players must release both limiter voice groups."
	)


func _test_direct_play_ab_switch() -> void:
	LIMITER.limiting_enabled = false
	LIMITER.reset_metrics()
	var direct_players: Array[AudioStreamPlayer2D] = []
	for index in range(LIMITER.MAX_SIMULTANEOUS_RAPID_FIRE_VOICES + 4):
		var player := _add_audio_player(
			RAPID_STREAM,
			-10.0,
			Vector2(float(index) * 4.0, 48.0)
		)
		direct_players.append(player)
		LIMITER.play_rapid_fire(player)

	var metrics := LIMITER.get_metrics()
	_expect(
		_count_playing(direct_players) == direct_players.size(),
		"Disabling the A/B switch must restore the former uncapped direct play path."
	)
	_expect(
		int(metrics[&"requests"]) == direct_players.size()
		and int(metrics[&"admitted"]) == direct_players.size()
		and int(metrics[&"rejected"]) == 0
		and int(metrics[&"bypassed"]) == direct_players.size(),
		"Direct-play A/B metrics must report every bypassed request."
	)
	_stop_audio_players(direct_players)
	LIMITER.limiting_enabled = true


func _add_audio_player(
	stream: AudioStream,
	base_volume_db: float,
	player_position: Vector2
) -> AudioStreamPlayer2D:
	var player := AudioStreamPlayer2D.new()
	player.stream = stream
	player.volume_db = base_volume_db
	player.max_distance = 1000.0
	player.max_polyphony = 3
	player.position = player_position
	fixture.add_child(player)
	return player


func _stop_audio_players(players: Array[AudioStreamPlayer2D]) -> void:
	for player in players:
		player.stop()


func _stop_and_free_audio_children() -> void:
	for child in fixture.get_children():
		var audio_player := child as AudioStreamPlayer2D
		if audio_player == null:
			continue
		audio_player.stop()
		audio_player.stream = null
		audio_player.queue_free()


func _count_playing(players: Array[AudioStreamPlayer2D]) -> int:
	var playing_count := 0
	for player in players:
		if player.playing:
			playing_count += 1
	return playing_count


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
