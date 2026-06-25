extends GPUParticles2D
class_name LinglanSakuraHitEffect


func _ready() -> void:
	one_shot = true
	emitting = true
	finished.connect(_on_finished)


func setup(impact_direction: Vector2) -> void:
	if impact_direction != Vector2.ZERO:
		rotation = impact_direction.angle()


func _on_finished() -> void:
	queue_free()
