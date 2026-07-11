extends Node2D
class_name TiyiSniperHitEffect

@onready var hit_sprite: AnimatedSprite2D = $HitSprite
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
		hit_sprite.play(&"hit")
	get_tree().create_timer(0.32).timeout.connect(_finish)


func _on_hit_sprite_animation_finished() -> void:
	_finish()


func _finish() -> void:
	if not is_queued_for_deletion():
		queue_free()
