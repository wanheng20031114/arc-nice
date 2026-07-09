extends Node2D
class_name CollectibleSakuraExplosion

const EXPLOSION_AUDIO_LIMITER := preload("res://scene/explosion_audio_limiter.gd")
const AUTHORED_EXPLOSION_RADIUS := 47.0

@onready var animated_sprite: AnimatedSprite2D = $AnimatedSprite2D
@onready var explosion_audio: AudioStreamPlayer2D = $ExplosionAudio

var visual_radius: float = AUTHORED_EXPLOSION_RADIUS


func setup(explosion_radius: float) -> void:
	visual_radius = maxf(explosion_radius, 1.0)


func _ready() -> void:
	animated_sprite.scale = Vector2.ONE * (visual_radius / AUTHORED_EXPLOSION_RADIUS)
	animated_sprite.animation_finished.connect(queue_free)
	animated_sprite.play(&"explode")
	EXPLOSION_AUDIO_LIMITER.play(explosion_audio)
