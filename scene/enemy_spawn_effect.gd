extends Node2D

@export var duration: float = 0.38
@export var start_scale: float = 0.55
@export var end_scale: float = 1.05

@onready var outer_ring: Line2D = $OuterRing
@onready var inner_ring: Line2D = $InnerRing


func _ready() -> void:
	scale = Vector2.ONE * start_scale
	modulate.a = 0.0

	var tween := create_tween()
	tween.set_parallel(true)
	tween.tween_property(self, "scale", Vector2.ONE * end_scale, duration).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_OUT)
	tween.tween_property(self, "modulate:a", 1.0, duration * 0.18).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_OUT)
	tween.chain().tween_property(self, "modulate:a", 0.0, duration * 0.62).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN)
	tween.finished.connect(queue_free)

	outer_ring.rotation = randf_range(0.0, TAU)
	inner_ring.rotation = randf_range(0.0, TAU)
