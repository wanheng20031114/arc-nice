extends SceneTree

const LIMITER := preload("res://scene/combat/audio/enemy_attack_audio_limiter.gd")
const RAPID_STREAM := preload("res://resources/audio/capoo_smg_fire.wav")
const HEAVY_STREAM := preload("res://resources/audio/capoo_rpg_launch.wav")

const RAPID_REQUEST_COUNT := 240
const HEAVY_REQUEST_COUNT := 80
const SAMPLE_PAIRS := 14

var failures: Array[String] = []
var fixture: Node2D
var rapid_players: Array[AudioStreamPlayer2D] = []
var heavy_players: Array[AudioStreamPlayer2D] = []
var original_limiting_enabled := true


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	original_limiting_enabled = LIMITER.limiting_enabled
	fixture = Node2D.new()
	fixture.name = "EnemyAttackAudioLimiterPerformanceAB"
	root.add_child(fixture)
	current_scene = fixture
	_build_players()
	await process_frame

	for _warmup in range(4):
		_measure_phase(false)
		_measure_phase(true)

	var direct_samples: Array[float] = []
	var limited_samples: Array[float] = []
	for pair_index in range(SAMPLE_PAIRS):
		if pair_index % 2 == 0:
			direct_samples.append(float(_measure_phase(false)[&"elapsed_usec"]))
			limited_samples.append(float(_measure_phase(true)[&"elapsed_usec"]))
		else:
			limited_samples.append(float(_measure_phase(true)[&"elapsed_usec"]))
			direct_samples.append(float(_measure_phase(false)[&"elapsed_usec"]))

	var direct_result := _measure_phase(false)
	var direct_playing := int(direct_result[&"playing"])
	var limited_result := _measure_phase(true)
	var limited_playing := int(limited_result[&"playing"])
	var limited_metrics: Dictionary = limited_result[&"metrics"]
	var direct_median_usec := _median(direct_samples)
	var limited_median_usec := _median(limited_samples)
	var voice_reduction_ratio := (
		1.0 - float(limited_playing) / maxf(float(direct_playing), 1.0)
	)

	_expect(
		direct_playing == RAPID_REQUEST_COUNT + HEAVY_REQUEST_COUNT,
		"Direct A/B phase must start every requested attack voice."
	)
	_expect(
		limited_playing
		== (
			LIMITER.MAX_SIMULTANEOUS_RAPID_FIRE_VOICES
			+ LIMITER.MAX_SIMULTANEOUS_HEAVY_ATTACK_VOICES
		),
		"Limited A/B phase must retain only the two category caps."
	)
	_expect(
		int(limited_metrics[&"requests"])
		== RAPID_REQUEST_COUNT + HEAVY_REQUEST_COUNT
		and int(limited_metrics[&"admitted"]) == limited_playing
		and int(limited_metrics[&"rejected"])
		== RAPID_REQUEST_COUNT + HEAVY_REQUEST_COUNT - limited_playing,
		"Limited A/B metrics must account for the entire identical request batch."
	)
	_expect(
		voice_reduction_ratio >= 0.95,
		"Shared voice arbitration must remove at least 95% of a 320-request burst."
	)
	print(
		(
			"ENEMY_ATTACK_AUDIO_LIMITER_AB requests=%d "
			+ "direct_playing=%d limited_playing=%d voice_reduction=%.2f%% "
			+ "direct_dispatch_median_usec=%.0f "
			+ "limited_dispatch_median_usec=%.0f dispatch_ratio=%.2fx "
			+ "rapid_peak=%d heavy_peak=%d rejected=%d"
		)
		% [
			RAPID_REQUEST_COUNT + HEAVY_REQUEST_COUNT,
			direct_playing,
			limited_playing,
			voice_reduction_ratio * 100.0,
			direct_median_usec,
			limited_median_usec,
			limited_median_usec / maxf(direct_median_usec, 1.0),
			int(limited_metrics[&"rapid_peak"]),
			int(limited_metrics[&"heavy_peak"]),
			int(limited_metrics[&"rejected"]),
		]
	)

	LIMITER.limiting_enabled = original_limiting_enabled
	_stop_all_players()
	current_scene = null
	fixture.queue_free()
	for _cleanup_frame in range(4):
		await process_frame
		await physics_frame
	if failures.is_empty():
		print("ENEMY_ATTACK_AUDIO_LIMITER_PERFORMANCE_AB_OK")
		quit()
		return
	for failure in failures:
		push_error(failure)
	quit(1)


func _build_players() -> void:
	for index in range(RAPID_REQUEST_COUNT):
		rapid_players.append(_add_audio_player(RAPID_STREAM, -10.0, index))
	for index in range(HEAVY_REQUEST_COUNT):
		heavy_players.append(_add_audio_player(HEAVY_STREAM, -12.0, index))


func _add_audio_player(
	stream: AudioStream,
	base_volume_db: float,
	index: int
) -> AudioStreamPlayer2D:
	var player := AudioStreamPlayer2D.new()
	player.stream = stream
	player.volume_db = base_volume_db
	player.max_distance = 10000.0
	player.max_polyphony = 3
	player.position = Vector2(
		float(index % 40) * 2.0,
		float(index / 40) * 2.0
	)
	fixture.add_child(player)
	return player


func _measure_phase(use_limiter: bool) -> Dictionary:
	_stop_all_players()
	LIMITER.get_active_voice_count(
		fixture,
		LIMITER.AttackAudioClass.RAPID_FIRE
	)
	LIMITER.get_active_voice_count(
		fixture,
		LIMITER.AttackAudioClass.HEAVY_ATTACK
	)
	LIMITER.limiting_enabled = use_limiter
	LIMITER.reset_metrics()
	var started_usec := Time.get_ticks_usec()
	for player in rapid_players:
		LIMITER.play_rapid_fire(player, 0.0, fixture)
	for player in heavy_players:
		LIMITER.play_heavy_attack(player, 0.0, fixture)
	var elapsed_usec := Time.get_ticks_usec() - started_usec
	var playing_count := _count_playing(rapid_players) + _count_playing(heavy_players)
	return {
		&"elapsed_usec": elapsed_usec,
		&"playing": playing_count,
		&"metrics": LIMITER.get_metrics(),
	}


func _stop_all_players() -> void:
	for player in rapid_players:
		player.stop()
	for player in heavy_players:
		player.stop()


func _count_playing(players: Array[AudioStreamPlayer2D]) -> int:
	var playing_count := 0
	for player in players:
		if player.playing:
			playing_count += 1
	return playing_count


func _median(samples: Array[float]) -> float:
	samples.sort()
	return samples[samples.size() / 2]


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
