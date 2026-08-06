extends SceneTree

const VICTORY_SCENE := preload(
	"res://scene/game_modes/rogue/combat/rogue_combat_victory_presentation.tscn"
)
const TRANSITION_SCENE := preload(
	"res://scene/game_modes/rogue/route/rogue_scene_transition.tscn"
)
const COMBAT_MUSIC := preload(
	"res://resources/audio/1-28 Journey of the Prairie King (The Outlaw).mp3"
)

var failures: Array[String] = []


func _initialize() -> void:
	call_deferred(&"_run")


func _run() -> void:
	var fixture := Node.new()
	fixture.name = "VictoryTransitionFixture"
	root.add_child(fixture)
	var presentation := (
		VICTORY_SCENE.instantiate() as RogueCombatVictoryPresentation
	)
	var transition := TRANSITION_SCENE.instantiate() as RogueSceneTransition
	fixture.add_child(presentation)
	fixture.add_child(transition)
	await process_frame

	_expect(
		presentation.process_mode == Node.PROCESS_MODE_ALWAYS
		and presentation.layer == 110
		and presentation.get_title_text() == "胜者为王"
		and presentation.victory_audio.bus == &"SFX"
		and is_equal_approx(presentation.victory_audio.volume_db, -5.0)
		and presentation.victory_audio.max_polyphony == 1,
		"胜利层必须常驻、暂停时仍运行，并严格显示“胜者为王”。"
	)
	_expect(
		transition.process_mode == Node.PROCESS_MODE_ALWAYS
		and transition.layer == 120
		and transition.cover_audio.bus == &"SFX"
		and transition.reveal_audio.bus == &"SFX",
		"通用转场层必须位于胜利层之上，并在暂停树中继续运行。"
	)
	var victory_stream := presentation.victory_audio.stream as AudioStreamWAV
	var wav_file := FileAccess.open(
		"res://resources/audio/ui/rogue_combat_victory.wav",
		FileAccess.READ
	)
	var source_channels := -1
	var source_rate := -1
	var source_bit_depth := -1
	var source_peak := 0.0
	var source_rms := 0.0
	if wav_file != null:
		wav_file.seek(22)
		source_channels = wav_file.get_16()
		source_rate = wav_file.get_32()
		wav_file.seek(34)
		source_bit_depth = wav_file.get_16()
		wav_file.seek(44)
		var square_sum := 0.0
		var sample_count := 0
		while wav_file.get_position() + 1 < wav_file.get_length():
			var sample := wav_file.get_16()
			if sample > 32767:
				sample -= 65536
			var normalized_sample := float(sample) / 32768.0
			source_peak = maxf(source_peak, absf(normalized_sample))
			square_sum += normalized_sample * normalized_sample
			sample_count += 1
		if sample_count > 0:
			source_rms = sqrt(square_sum / float(sample_count))
		wav_file.close()
	_expect(
		victory_stream != null
		and wav_file != null
		and source_channels == 1
		and source_rate == 44100
		and source_bit_depth == 16
		and source_peak >= 0.81
		and source_peak <= 0.83
		and source_rms >= 0.19
		and source_rms <= 0.21
		and victory_stream.mix_rate == 44100
		and not victory_stream.stereo
		and victory_stream.loop_mode == AudioStreamWAV.LOOP_DISABLED
		and is_equal_approx(victory_stream.get_length(), 1.65),
		"胜利短乐句必须是 44.1kHz、16-bit、单声道、1.65秒且不循环。"
	)

	var music_player := AudioStreamPlayer.new()
	music_player.name = "FrozenCombatMusic"
	music_player.stream = COMBAT_MUSIC
	music_player.volume_db = -6.0
	music_player.bus = &"Music"
	fixture.add_child(music_player)
	music_player.play()
	await process_frame
	fixture.process_mode = Node.PROCESS_MODE_DISABLED
	presentation.play(music_player)
	await create_timer(0.15, true).timeout
	var sampled_fade := (
		music_player.volume_db < -6.0
		and music_player.volume_db > -80.0
	)
	await presentation.playback_finished
	_expect(
		sampled_fade
		and not music_player.playing
		and music_player.process_mode == Node.PROCESS_MODE_INHERIT
		and is_equal_approx(music_player.volume_db, -6.0)
		and not presentation.visible
		and not presentation.is_playing(),
		"战场冻结后，1-28 仍必须在0.30秒内淡停并恢复播放器配置。"
	)

	paused = true
	await transition.cover()
	_expect(
		transition.is_covered()
		and transition.visible
		and is_equal_approx(transition.progress, 1.0),
		"暂停树中 cover() 必须完成0.32秒全遮盖。"
	)
	await transition.reveal()
	paused = false
	_expect(
		not transition.visible
		and is_equal_approx(transition.progress, 0.0),
		"reveal() 必须在0.38秒后完全揭示并释放输入遮挡。"
	)

	fixture.process_mode = Node.PROCESS_MODE_INHERIT
	music_player.play()
	presentation.play(music_player)
	await create_timer(0.02, true).timeout
	presentation.interrupt_and_reset()
	transition.hide_immediately()
	_expect(
		not presentation.visible
		and not presentation.is_playing()
		and not music_player.playing
		and not transition.visible,
		"中断清理必须立即停止标题、音乐和转场，避免旧协程复现。"
	)
	await create_timer(0.08, true).timeout

	fixture.queue_free()
	await process_frame
	await process_frame
	_finish()


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)


func _finish() -> void:
	if failures.is_empty():
		print("ROGUE_COMBAT_VICTORY_TRANSITION_SMOKE_OK")
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	quit(1)
