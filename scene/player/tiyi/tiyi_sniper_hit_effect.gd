extends Node2D
class_name TiyiSniperHitEffect

const NIGHT_VFX_FLASH_POOL := preload("res://scene/lighting/night_vfx_flash_pool.gd")

@onready var hit_sprite: AnimatedSprite2D = $HitSprite
@onready var emission_overlay: AnimatedSprite2D = $HitSprite/EmissionOverlay
@onready var fragment_particles: GPUParticles2D = $FragmentParticles

var _impact_direction: Vector2 = Vector2.RIGHT


func setup(direction: Vector2) -> void:
	if direction != Vector2.ZERO:
		_impact_direction = direction.normalized()
	rotation = _impact_direction.angle()


func _ready() -> void:
	rotation = _impact_direction.angle()
	if fragment_particles != null:
		fragment_particles.restart()
	if (
		hit_sprite != null
		and hit_sprite.sprite_frames != null
		and hit_sprite.sprite_frames.has_animation(&"hit")
	):
		hit_sprite.stop()
		emission_overlay.stop()
		hit_sprite.set_frame_and_progress(0, 0.0)
		emission_overlay.animation = &"hit"
		emission_overlay.set_frame_and_progress(0, 0.0)
		hit_sprite.play(&"hit")
		emission_overlay.play(&"hit")
	call_deferred("_request_night_flash")
	get_tree().create_timer(0.32, false).timeout.connect(_finish)


func _request_night_flash() -> void:
	NIGHT_VFX_FLASH_POOL.request_from(
		self,
		global_position,
		Color(0.82, 0.5, 1.0, 1.0),
		0.7,
		0.30,
		0.02,
		0.025,
		0.17,
		1
	)


func _on_hit_sprite_animation_finished() -> void:
	_finish()


func _finish() -> void:
	if not is_queued_for_deletion():
		queue_free()
