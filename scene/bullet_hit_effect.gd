extends GPUParticles2D
class_name BulletHitEffect

## 一次性子弹命中粒子效果。
## 播放完毕后自动释放。


func _ready() -> void:
	one_shot = true
	emitting = true
	finished.connect(_on_finished)


func setup(impact_direction: Vector2) -> void:
	if impact_direction != Vector2.ZERO:
		rotation = impact_direction.angle()


func _on_finished() -> void:
	queue_free()
