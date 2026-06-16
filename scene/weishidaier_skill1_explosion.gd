extends Node2D
class_name WeishidaierSkill1Explosion

@onready var animated_sprite: AnimatedSprite2D = $AnimatedSprite2D
@onready var explosion_audio: AudioStreamPlayer2D = $ExplosionAudio


func _ready() -> void:
	animated_sprite.animation_finished.connect(queue_free)
	animated_sprite.play(&"explode")
	explosion_audio.play()
