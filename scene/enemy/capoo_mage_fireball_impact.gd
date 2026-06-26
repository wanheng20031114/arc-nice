extends Node2D
class_name CapooMageFireballImpact

@onready var animated_sprite: AnimatedSprite2D = $AnimatedSprite2D
@onready var impact_audio: AudioStreamPlayer2D = $ImpactAudio

var _animation_done: bool = false
var _audio_done: bool = false


func _ready() -> void:
	if animated_sprite.sprite_frames != null and animated_sprite.sprite_frames.has_animation(&"impact"):
		animated_sprite.animation_finished.connect(_on_animation_finished)
		animated_sprite.play(&"impact")
	else:
		_animation_done = true

	if impact_audio.stream != null:
		impact_audio.finished.connect(_on_audio_finished)
		impact_audio.play()
	else:
		_audio_done = true

	_try_release()


func _on_animation_finished() -> void:
	_animation_done = true
	animated_sprite.visible = false
	_try_release()


func _on_audio_finished() -> void:
	_audio_done = true
	_try_release()


func _try_release() -> void:
	if _animation_done and _audio_done:
		queue_free()
