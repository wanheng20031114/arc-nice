extends Node2D
class_name CollectibleSakuraExplosion

const EXPLOSION_AUDIO_LIMITER := preload("res://scene/combat/audio/explosion_audio_limiter.gd")
const NIGHT_VFX_FLASH_POOL := preload("res://scene/lighting/night_vfx_flash_pool.gd")
const AUTHORED_EXPLOSION_RADIUS := 47.0

@onready var animated_sprite: AnimatedSprite2D = $AnimatedSprite2D
@onready var emission_overlay: AnimatedSprite2D = $AnimatedSprite2D/EmissionOverlay
@onready var explosion_audio: AudioStreamPlayer2D = $ExplosionAudio

var visual_radius: float = AUTHORED_EXPLOSION_RADIUS


func setup(explosion_radius: float) -> void:
	visual_radius = maxf(explosion_radius, 1.0)


func _ready() -> void:
	animated_sprite.scale = Vector2.ONE * (visual_radius / AUTHORED_EXPLOSION_RADIUS)
	animated_sprite.animation_finished.connect(queue_free)
	animated_sprite.play(&"explode")
	emission_overlay.play(&"explode")
	call_deferred("_request_night_flash")
	EXPLOSION_AUDIO_LIMITER.play(explosion_audio)


func _request_night_flash() -> void:
	NIGHT_VFX_FLASH_POOL.request_from(
		self,
		global_position,
		Color(1.0, 0.54, 0.82, 1.0),
		0.92,
		0.72 * (visual_radius / AUTHORED_EXPLOSION_RADIUS),
		0.04,
		0.055,
		0.27,
		2
	)
