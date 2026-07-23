extends GPUParticles2D
class_name PlantRemovalSmoke

const SPATIAL_AUDIO_VOICE_LIMITER := preload(
	"res://scene/spatial_audio_voice_limiter.gd"
)
const COLLAPSE_AUDIO_GROUP := &"limited_plant_collapse_audio_players"
const MAX_SIMULTANEOUS_COLLAPSE_VOICES := 4
const COLLAPSE_STACK_ATTENUATION_DB := 3.0
const MAX_COLLAPSE_STACK_ATTENUATION_DB := 9.0

@onready var collapse_audio: AudioStreamPlayer2D = $CollapseAudio

var _effect_active := false
var _collapse_audio_base_volume_db := 0.0


func _ready() -> void:
	one_shot = true
	emitting = false
	_collapse_audio_base_volume_db = collapse_audio.volume_db
	if not finished.is_connected(_on_finished):
		finished.connect(_on_finished)


func _exit_tree() -> void:
	_reset_effect_state()


func on_pool_acquired(_generation: int) -> void:
	_reset_effect_state()


func on_pool_released(_generation: int) -> void:
	_reset_effect_state()


func restart_effect(effect_scale: float, play_collapse_audio: bool = false) -> void:
	_reset_effect_state()
	_effect_active = true
	scale = Vector2.ONE * maxf(effect_scale, 0.01)
	restart()
	emitting = true
	if play_collapse_audio:
		_play_collapse_audio()


func _reset_effect_state() -> void:
	_stop_collapse_audio()
	_effect_active = false
	emitting = false
	scale = Vector2.ONE


func _play_collapse_audio() -> void:
	_stop_collapse_audio()
	var active_voice_count := SPATIAL_AUDIO_VOICE_LIMITER.claim_voice(
		collapse_audio,
		COLLAPSE_AUDIO_GROUP,
		MAX_SIMULTANEOUS_COLLAPSE_VOICES
	)
	if active_voice_count == SPATIAL_AUDIO_VOICE_LIMITER.REJECTED_ACTIVE_COUNT:
		return
	collapse_audio.add_to_group(COLLAPSE_AUDIO_GROUP)
	collapse_audio.volume_db = (
		_collapse_audio_base_volume_db
		- minf(
			active_voice_count * COLLAPSE_STACK_ATTENUATION_DB,
			MAX_COLLAPSE_STACK_ATTENUATION_DB
		)
	)
	collapse_audio.play()
	if not collapse_audio.playing:
		_remove_collapse_audio_voice()


func _stop_collapse_audio() -> void:
	collapse_audio.stop()
	collapse_audio.volume_db = _collapse_audio_base_volume_db
	_remove_collapse_audio_voice()


func _on_collapse_audio_finished() -> void:
	if collapse_audio.playing:
		return
	_remove_collapse_audio_voice()


func _remove_collapse_audio_voice() -> void:
	if collapse_audio.is_in_group(COLLAPSE_AUDIO_GROUP):
		collapse_audio.remove_from_group(COLLAPSE_AUDIO_GROUP)


func _on_finished() -> void:
	if not _effect_active:
		return
	_effect_active = false
	emitting = false
	if SessionObjectPool.release_to_owner(self):
		return
	queue_free()
