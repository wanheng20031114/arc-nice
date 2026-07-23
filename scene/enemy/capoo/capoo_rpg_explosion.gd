extends Node2D
class_name CapooRPGExplosion

const EXPLOSION_AUDIO_LIMITER := preload("res://scene/explosion_audio_limiter.gd")
const NIGHT_VFX_FLASH_POOL := preload("res://scene/lighting/night_vfx_flash_pool.gd")

@onready var animated_sprite: AnimatedSprite2D = $AnimatedSprite2D
@onready var emission_overlay: AnimatedSprite2D = $AnimatedSprite2D/EmissionOverlay
@onready var explosion_audio: AudioStreamPlayer2D = $ExplosionAudio


func _ready() -> void:
	animated_sprite.animation_finished.connect(queue_free)
	animated_sprite.play(&"explode")
	emission_overlay.play(&"explode")
	call_deferred("_request_night_flash")
	EXPLOSION_AUDIO_LIMITER.play(explosion_audio)


func _request_night_flash() -> void:
	NIGHT_VFX_FLASH_POOL.request_from(
		self,
		global_position,
		Color(1.0, 0.56, 0.22, 1.0),
		1.08,
		0.82,
		0.04,
		0.06,
		0.30,
		2
	)
