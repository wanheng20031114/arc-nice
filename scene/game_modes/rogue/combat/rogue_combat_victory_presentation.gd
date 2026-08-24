extends CanvasLayer
class_name RogueCombatVictoryPresentation

signal playback_finished

const VISUAL_DURATION_SECONDS := 1.65
const VICTORY_AUDIO_DELAY_SECONDS := 0.08
const MUSIC_FADE_SECONDS := 0.30
const MUSIC_SILENCE_DB := -80.0
const LETTER_INTERVAL_SECONDS := 0.12
const LETTER_START_SECONDS := 0.18

@onready var root: Control = $Root
@onready var shade: ColorRect = $Root/Shade
@onready var left_line: ColorRect = $Root/LeftLine
@onready var right_line: ColorRect = $Root/RightLine
@onready var victory_audio: AudioStreamPlayer = $VictoryAudio

@onready var letters: Array[Label] = [
	$Root/VictoryTitle,
	$Root/WinnerTitle,
	$Root/IsTitle,
	$Root/KingTitle,
]

var _letter_target_positions: Array[Vector2] = []
var _visual_tween: Tween = null
var _music_tween: Tween = null
var _active_music_player: AudioStreamPlayer = null
var _music_original_process_mode := Node.PROCESS_MODE_INHERIT
var _music_original_volume_db := 0.0
var _music_original_stream_paused := false
var _play_serial := 0
var _playing := false


func _ready() -> void:
	for letter in letters:
		_letter_target_positions.append(letter.position)
		letter.pivot_offset = letter.size * 0.5
	hide_immediately()


func play(music_player: AudioStreamPlayer) -> bool:
	interrupt_and_reset()
	_play_serial += 1
	var serial := _play_serial
	_playing = true
	visible = true
	_prepare_visuals()
	_start_music_fade(music_player)
	_start_visual_animation()
	await get_tree().create_timer(VICTORY_AUDIO_DELAY_SECONDS, false).timeout
	if serial != _play_serial:
		return false
	victory_audio.play()
	var audio_duration := (
		victory_audio.stream.get_length()
		if victory_audio.stream != null
		else 0.0
	)
	var remaining_duration := maxf(
		VISUAL_DURATION_SECONDS - VICTORY_AUDIO_DELAY_SECONDS,
		audio_duration
	)
	await get_tree().create_timer(remaining_duration, false).timeout
	if serial != _play_serial:
		return false
	_finish_visuals()
	_playing = false
	playback_finished.emit()
	return true


func interrupt_and_reset() -> void:
	_play_serial += 1
	_playing = false
	if _visual_tween != null:
		_visual_tween.kill()
		_visual_tween = null
	victory_audio.stop()
	_stop_and_restore_music()
	if is_node_ready():
		_prepare_visuals()
	visible = false


func hide_immediately() -> void:
	interrupt_and_reset()


func is_playing() -> bool:
	return _playing


func get_title_text() -> String:
	var title := ""
	for letter in letters:
		title += letter.text
	return title


func _prepare_visuals() -> void:
	root.modulate = Color.WHITE
	shade.color = Color(0.012, 0.018, 0.03, 0.0)
	left_line.scale = Vector2(0.0, 1.0)
	right_line.scale = Vector2(0.0, 1.0)
	left_line.modulate = Color.WHITE
	right_line.modulate = Color.WHITE
	for index in range(letters.size()):
		var letter := letters[index]
		letter.position = _letter_target_positions[index] + Vector2(0.0, 22.0)
		letter.scale = Vector2.ONE * 0.86
		letter.modulate = Color(1.0, 1.0, 1.0, 0.0)


func _start_visual_animation() -> void:
	_visual_tween = create_tween().set_parallel(true)
	_visual_tween.tween_property(
		shade,
		"color",
		Color(0.012, 0.018, 0.03, 0.82),
		0.18
	).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_OUT)
	_visual_tween.tween_property(
		left_line,
		"scale",
		Vector2.ONE,
		0.42
	).set_delay(0.20).set_trans(Tween.TRANS_QUART).set_ease(Tween.EASE_OUT)
	_visual_tween.tween_property(
		right_line,
		"scale",
		Vector2.ONE,
		0.42
	).set_delay(0.20).set_trans(Tween.TRANS_QUART).set_ease(Tween.EASE_OUT)
	for index in range(letters.size()):
		var letter := letters[index]
		var start_time := LETTER_START_SECONDS + index * LETTER_INTERVAL_SECONDS
		_visual_tween.tween_property(
			letter,
			"modulate",
			Color.WHITE,
			0.18
		).set_delay(start_time).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_OUT)
		_visual_tween.tween_property(
			letter,
			"position",
			_letter_target_positions[index],
			0.28
		).set_delay(start_time).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
		_visual_tween.tween_property(
			letter,
			"scale",
			Vector2.ONE,
			0.26
		).set_delay(start_time).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
		_visual_tween.tween_property(
			letter,
			"scale",
			Vector2.ONE * 1.025,
			0.14
		).set_delay(0.90).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
		_visual_tween.tween_property(
			letter,
			"scale",
			Vector2.ONE,
			0.16
		).set_delay(1.04).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	_visual_tween.tween_property(
		root,
		"modulate",
		Color(1.0, 1.0, 1.0, 0.0),
		0.40
	).set_delay(1.25).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN)


func _start_music_fade(music_player: AudioStreamPlayer) -> void:
	if music_player == null or not is_instance_valid(music_player):
		return
	_active_music_player = music_player
	_music_original_process_mode = music_player.process_mode
	_music_original_volume_db = music_player.volume_db
	_music_original_stream_paused = music_player.stream_paused
	music_player.process_mode = Node.PROCESS_MODE_PAUSABLE
	music_player.stream_paused = false
	if not music_player.playing:
		_restore_music_player_state()
		return
	_music_tween = create_tween()
	_music_tween.tween_property(
		music_player,
		"volume_db",
		MUSIC_SILENCE_DB,
		MUSIC_FADE_SECONDS
	).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN)
	_music_tween.tween_callback(_finish_music_fade)


func _finish_music_fade() -> void:
	_music_tween = null
	if _active_music_player != null and is_instance_valid(_active_music_player):
		_active_music_player.stop()
	_restore_music_player_state()


func _stop_and_restore_music() -> void:
	if _music_tween != null:
		_music_tween.kill()
		_music_tween = null
	if _active_music_player != null and is_instance_valid(_active_music_player):
		_active_music_player.stop()
	_restore_music_player_state()


func _restore_music_player_state() -> void:
	if _active_music_player != null and is_instance_valid(_active_music_player):
		_active_music_player.volume_db = _music_original_volume_db
		_active_music_player.process_mode = _music_original_process_mode
		_active_music_player.stream_paused = _music_original_stream_paused
	_active_music_player = null


func _finish_visuals() -> void:
	if _visual_tween != null:
		_visual_tween.kill()
		_visual_tween = null
	root.modulate = Color(1.0, 1.0, 1.0, 0.0)
	visible = false
