extends Node2D
class_name CapooMageFireballImpact

const EXPLOSION_AUDIO_LIMITER := preload("res://scene/explosion_audio_limiter.gd")
const SPATIAL_AUDIO_VOICE_LIMITER := preload("res://scene/spatial_audio_voice_limiter.gd")

@onready var animated_sprite: AnimatedSprite2D = $AnimatedSprite2D
@onready var impact_audio: AudioStreamPlayer2D = $ImpactAudio

var pool_active: bool = true
var _running: bool = false
var _animation_done: bool = true
var _audio_done: bool = true


func _ready() -> void:
	pool_active = not has_meta(SessionObjectPool.POOL_OWNER_META)
	if not animated_sprite.animation_finished.is_connected(_on_animation_finished):
		animated_sprite.animation_finished.connect(_on_animation_finished)
	if not impact_audio.finished.is_connected(_on_audio_finished):
		impact_audio.finished.connect(_on_audio_finished)
	impact_audio.set_meta(
		SPATIAL_AUDIO_VOICE_LIMITER.VOICE_PREEMPTED_CALLBACK_META,
		_on_audio_preempted
	)
	_reset_playback()


func on_pool_acquired(_generation: int) -> void:
	pool_active = true
	_reset_playback()


func on_pool_released(_generation: int) -> void:
	pool_active = false
	_reset_playback()


## Starts one visual/audio lease only after its final world position is known.
## Prewarmed instances deliberately remain stopped and invisible until here.
func restart() -> void:
	if not pool_active:
		return
	_reset_playback()
	_running = true
	if (
		animated_sprite.sprite_frames != null
		and animated_sprite.sprite_frames.has_animation(&"impact")
	):
		_animation_done = false
		animated_sprite.visible = true
		animated_sprite.play(&"impact")
	else:
		_animation_done = true

	if impact_audio.stream != null:
		EXPLOSION_AUDIO_LIMITER.play(impact_audio)
		# The shared limiter can reject inaudible or over-budget voices. In that
		# case there is no audio completion to wait for.
		_audio_done = not impact_audio.playing
	else:
		_audio_done = true
	_try_release()


func _on_animation_finished() -> void:
	if not _running:
		return
	_animation_done = true
	animated_sprite.visible = false
	_try_release()


func _on_audio_finished() -> void:
	if not _running:
		return
	_audio_done = true
	_try_release()


func _on_audio_preempted() -> void:
	if not _running:
		return
	_audio_done = true
	_try_release()


func _try_release() -> void:
	if not _running or not _animation_done or not _audio_done:
		return
	_running = false
	if SessionObjectPool.release_to_owner(self):
		return
	queue_free()


func _reset_playback() -> void:
	_running = false
	_animation_done = true
	_audio_done = true
	if animated_sprite != null:
		animated_sprite.stop()
		animated_sprite.frame = 0
		animated_sprite.frame_progress = 0.0
		animated_sprite.visible = false
	if impact_audio != null:
		EXPLOSION_AUDIO_LIMITER.stop(impact_audio)


func _exit_tree() -> void:
	if impact_audio != null:
		EXPLOSION_AUDIO_LIMITER.stop(impact_audio)
