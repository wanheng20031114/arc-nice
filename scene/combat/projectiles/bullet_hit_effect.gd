extends GPUParticles2D
class_name BulletHitEffect

## 一次性子弹命中粒子效果。
## 播放完毕后自动释放。

var pool_active := true


func _ready() -> void:
	one_shot = true
	emitting = false
	pool_active = not has_meta(SessionObjectPool.POOL_OWNER_META)
	if not finished.is_connected(_on_finished):
		finished.connect(_on_finished)


func on_pool_acquired(_generation: int) -> void:
	pool_active = true
	emitting = false
	rotation = 0.0


func on_pool_released(_generation: int) -> void:
	pool_active = false
	emitting = false
	rotation = 0.0


func setup(impact_direction: Vector2) -> void:
	if impact_direction != Vector2.ZERO:
		rotation = impact_direction.angle()
	restart()
	emitting = true


func _on_finished() -> void:
	if not pool_active:
		return
	pool_active = false
	if SessionObjectPool.release_to_owner(self):
		return
	queue_free()
