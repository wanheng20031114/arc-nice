extends Node2D
class_name LinglanSkill2SakuraExplosion

const EXPLOSION_AUDIO_LIMITER := preload("res://scene/explosion_audio_limiter.gd")
const NIGHT_VFX_FLASH_POOL := preload("res://scene/lighting/night_vfx_flash_pool.gd")
const AUTHORED_EXPLOSION_RADIUS := 110.0
const DEFAULT_EXPLOSION_RADIUS := 78.0

@onready var animated_sprite: AnimatedSprite2D = $AnimatedSprite2D
@onready var emission_overlay: AnimatedSprite2D = $AnimatedSprite2D/EmissionOverlay
@onready var explosion_audio: AudioStreamPlayer2D = $ExplosionAudio

var visual_radius: float = DEFAULT_EXPLOSION_RADIUS


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
		Color(1.0, 0.5, 0.86, 1.0),
		1.18,
		1.05 * (visual_radius / DEFAULT_EXPLOSION_RADIUS),
		0.045,
		0.065,
		0.32,
		3
	)
