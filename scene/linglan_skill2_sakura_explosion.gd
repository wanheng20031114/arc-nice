extends Node2D
class_name LinglanSkill2SakuraExplosion

const EXPLOSION_AUDIO_LIMITER := preload("res://scene/explosion_audio_limiter.gd")

@onready var animated_sprite: AnimatedSprite2D = $AnimatedSprite2D
@onready var explosion_audio: AudioStreamPlayer2D = $ExplosionAudio


func _ready() -> void:
	animated_sprite.animation_finished.connect(queue_free)
	animated_sprite.play(&"explode")
	EXPLOSION_AUDIO_LIMITER.play(explosion_audio)
