extends Node2D
class_name CollectibleLightningEffect

const VISUAL_BASE_HEIGHT := 160.0

@onready var visual: AnimatedSprite2D = $Visual

var lifetime: float = 0.24
var age: float = 0.0
var strike_height: float = 160.0


func setup(duration: float = 0.24, height: float = 160.0) -> void:
	lifetime = maxf(duration, 0.05)
	strike_height = maxf(height, 16.0)
	age = 0.0
	if is_node_ready():
		_apply_visual_layout()


func _ready() -> void:
	_apply_visual_layout()
	visual.play(&"strike")


func _process(delta: float) -> void:
	age += delta
	if age >= lifetime:
		queue_free()
		return


func _apply_visual_layout() -> void:
	var scale_factor := strike_height / VISUAL_BASE_HEIGHT
	visual.scale = Vector2.ONE * scale_factor
	visual.position = Vector2(0.0, -VISUAL_BASE_HEIGHT * 0.5 * scale_factor)
