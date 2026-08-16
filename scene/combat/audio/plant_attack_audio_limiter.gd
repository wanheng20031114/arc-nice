extends RefCounted
class_name PlantAttackAudioLimiter

const SPATIAL_VOICE_LIMITER := preload("res://scene/combat/audio/spatial_audio_voice_limiter.gd")
const AUDIO_GROUP := &"limited_plant_attack_audio_players"
const MAX_SIMULTANEOUS_VOICES := 6


static func play_burst(
	audio_player: AudioStreamPlayer2D,
	elapsed_seconds: float = 0.0,
	explicit_audio_scope: Node = null
) -> bool:
	if (
		audio_player == null
		or audio_player.stream == null
		or not audio_player.is_inside_tree()
	):
		return false

	var playback_offset := maxf(elapsed_seconds, 0.0)
	var stream_length := audio_player.stream.get_length()
	if stream_length > 0.0 and playback_offset >= stream_length:
		return false

	var audio_scope := SPATIAL_VOICE_LIMITER.resolve_audio_scope(
		audio_player,
		explicit_audio_scope
	)
	if audio_scope == null:
		return false
	var active_count := SPATIAL_VOICE_LIMITER.claim_voice(
		audio_player,
		audio_scope,
		AUDIO_GROUP,
		MAX_SIMULTANEOUS_VOICES
	)
	if active_count == SPATIAL_VOICE_LIMITER.REJECTED_ACTIVE_COUNT:
		return false

	if not audio_player.is_in_group(AUDIO_GROUP):
		audio_player.add_to_group(AUDIO_GROUP)
	var finished_callback := _on_audio_finished.bind(audio_player)
	if not audio_player.finished.is_connected(finished_callback):
		audio_player.finished.connect(finished_callback)
	audio_player.play(playback_offset)
	if not audio_player.playing:
		_remove_voice(audio_player)
		return false
	return true


static func get_active_voice_count(audio_scope: Node) -> int:
	if audio_scope == null:
		return 0
	return SPATIAL_VOICE_LIMITER.get_active_voice_count(
		audio_scope,
		AUDIO_GROUP
	)


static func _on_audio_finished(audio_player: AudioStreamPlayer2D) -> void:
	# One player can report an intermediate playback finishing while a same-frame
	# replay is still active. Only the final playback releases the shared voice.
	if is_instance_valid(audio_player) and audio_player.playing:
		return
	_remove_voice(audio_player)


static func _remove_voice(audio_player: AudioStreamPlayer2D) -> void:
	SPATIAL_VOICE_LIMITER.release_voice(audio_player, AUDIO_GROUP)
