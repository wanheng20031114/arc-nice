extends GPUParticles2D
class_name PlantRemovalSmoke

var _effect_active := false


func _ready() -> void:
	one_shot = true
	emitting = false
	if not finished.is_connected(_on_finished):
		finished.connect(_on_finished)


func on_pool_acquired(_generation: int) -> void:
	_effect_active = false
	emitting = false
	scale = Vector2.ONE


func on_pool_released(_generation: int) -> void:
	_effect_active = false
	emitting = false
	scale = Vector2.ONE


func restart_effect(effect_scale: float) -> void:
	_effect_active = true
	scale = Vector2.ONE * maxf(effect_scale, 0.01)
	restart()
	emitting = true


func _on_finished() -> void:
	if not _effect_active:
		return
	_effect_active = false
	emitting = false
	if SessionObjectPool.release_to_owner(self):
		return
	queue_free()
