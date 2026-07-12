extends Node2D

# 特效播放的总持续时间
@export var duration: float = 0.38
# 特效开始时的初始缩放比例
@export var start_scale: float = 0.55
# 特效结束时的最终缩放比例
@export var end_scale: float = 1.05

@onready var outer_ring: Line2D = $OuterRing
@onready var inner_ring: Line2D = $InnerRing
var active_tween: Tween = null


# 节点进入场景树时调用，初始化特效动画
func _ready() -> void:
	if not has_meta(SessionObjectPool.POOL_OWNER_META):
		restart_effect()


func on_pool_acquired(_lease_generation: int) -> void:
	pass


func on_pool_released(_lease_generation: int) -> void:
	if active_tween != null and active_tween.is_valid():
		active_tween.kill()
	active_tween = null
	scale = Vector2.ONE * start_scale
	modulate.a = 0.0


func restart_effect() -> void:
	if active_tween != null and active_tween.is_valid():
		active_tween.kill()
	# 设置初始状态：较小的缩放比例和完全透明
	scale = Vector2.ONE * start_scale
	modulate.a = 0.0

	active_tween = create_tween()
	active_tween.set_parallel(true)
	# 缩放动画：从初始大小放大到目标大小
	active_tween.tween_property(self, "scale", Vector2.ONE * end_scale, duration).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_OUT)
	# 淡入动画：在特效前段快速变为完全不透明
	active_tween.tween_property(self, "modulate:a", 1.0, duration * 0.18).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_OUT)
	# 淡出动画：在特效后段逐渐变回透明
	active_tween.chain().tween_property(self, "modulate:a", 0.0, duration * 0.62).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN)
	active_tween.finished.connect(_finish_effect)

	# 随机旋转内外环，使特效看起来更具随机性
	outer_ring.rotation = randf_range(0.0, TAU)
	inner_ring.rotation = randf_range(0.0, TAU)


func _finish_effect() -> void:
	active_tween = null
	var pool_owner_id := int(get_meta(SessionObjectPool.POOL_OWNER_META, 0))
	if pool_owner_id > 0:
		var pool_owner := instance_from_id(pool_owner_id) as SessionObjectPool
		if pool_owner != null and pool_owner.release(self):
			return
	queue_free()
