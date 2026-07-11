extends Node2D
class_name LinglanBossIntroVFX

signal intro_finished

@export var intro_duration: float = 2.4

@onready var convergence_sprite: AnimatedSprite2D = $ConvergenceSprite
@onready var petal_particles: Array[GPUParticles2D] = [
	$PetalTop,
	$PetalBottom,
	$PetalLeft,
	$PetalRight,
]

var intro_tween: Tween = null


func _ready() -> void:
	stop_intro()


func play_intro(center_position: Vector2) -> void:
	_stop_intro_tween()
	global_position = center_position
	visible = true
	modulate = Color.WHITE
	for particles in petal_particles:
		particles.emitting = false
		particles.restart()
		particles.emitting = true

	convergence_sprite.visible = true
	convergence_sprite.scale = Vector2.ONE * 0.88
	convergence_sprite.modulate = Color(1.0, 1.0, 1.0, 0.0)
	convergence_sprite.play(&"converge")

	intro_tween = create_tween()
	intro_tween.set_parallel(true)
	intro_tween.tween_property(convergence_sprite, "scale", Vector2.ONE * 0.24, intro_duration).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_IN_OUT)
	intro_tween.tween_property(convergence_sprite, "modulate", Color.WHITE, 0.26).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_OUT)
	intro_tween.tween_property(convergence_sprite, "modulate", Color(1.0, 1.0, 1.0, 0.0), 0.34).set_delay(maxf(intro_duration - 0.34, 0.0)).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN)
	intro_tween.tween_callback(_finish_intro).set_delay(intro_duration)


func stop_intro() -> void:
	_stop_intro_tween()
	visible = false
	if convergence_sprite != null:
		convergence_sprite.visible = false
		convergence_sprite.stop()
	for particles in petal_particles:
		if particles != null:
			particles.emitting = false


func _finish_intro() -> void:
	for particles in petal_particles:
		particles.emitting = false
	convergence_sprite.visible = false
	intro_tween = null
	intro_finished.emit()


func _stop_intro_tween() -> void:
	if intro_tween != null:
		intro_tween.kill()
		intro_tween = null
