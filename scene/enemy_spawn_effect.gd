extends Node2D

# 特效播放的总持续时间
@export var duration: float = 0.38
# 特效开始时的初始缩放比例
@export var start_scale: float = 0.55
# 特效结束时的最终缩放比例
@export var end_scale: float = 1.05

@onready var outer_ring: Line2D = $OuterRing
@onready var inner_ring: Line2D = $InnerRing


# 节点进入场景树时调用，初始化特效动画
func _ready() -> void:
	# 设置初始状态：较小的缩放比例和完全透明
	scale = Vector2.ONE * start_scale
	modulate.a = 0.0

	var tween := create_tween()
	tween.set_parallel(true)
	# 缩放动画：从初始大小放大到目标大小
	tween.tween_property(self, "scale", Vector2.ONE * end_scale, duration).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_OUT)
	# 淡入动画：在特效前段快速变为完全不透明
	tween.tween_property(self, "modulate:a", 1.0, duration * 0.18).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_OUT)
	# 淡出动画：在特效后段逐渐变回透明
	tween.chain().tween_property(self, "modulate:a", 0.0, duration * 0.62).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN)
	# 动画播放完毕后，自动删除该特效节点
	tween.finished.connect(queue_free)

	# 随机旋转内外环，使特效看起来更具随机性
	outer_ring.rotation = randf_range(0.0, TAU)
	inner_ring.rotation = randf_range(0.0, TAU)
