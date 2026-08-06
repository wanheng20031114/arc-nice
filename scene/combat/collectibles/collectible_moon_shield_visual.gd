extends Node2D
class_name CollectibleMoonShieldVisual

const VISUAL_BASE_RADIUS := 64.0

@onready var visual: AnimatedSprite2D = $Visual

var shield_radius: float = 64.0
var duration_left: float = 8.0


func setup(radius: float, duration: float) -> void:
	shield_radius = maxf(radius, 1.0)
	duration_left = maxf(duration, 0.05)
	if is_node_ready():
		_apply_visual_layout()


func _ready() -> void:
	_apply_visual_layout()
	visual.play(&"pulse")


func _process(delta: float) -> void:
	duration_left -= delta
	if duration_left <= 0.0:
		queue_free()


func _apply_visual_layout() -> void:
	visual.scale = Vector2.ONE * (shield_radius / VISUAL_BASE_RADIUS)
