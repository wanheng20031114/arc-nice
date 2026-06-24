extends Node2D
class_name CollectibleFrostAreaEffect

const VISUAL_BASE_RADIUS := 64.0

@onready var visual: AnimatedSprite2D = $Visual

var effect_radius: float = 72.0
var lifetime: float = 0.72
var age: float = 0.0


func setup(radius: float, duration: float = 0.72) -> void:
	effect_radius = maxf(radius, 1.0)
	lifetime = maxf(duration, 0.08)
	age = 0.0
	if is_node_ready():
		_apply_visual_layout()


func _ready() -> void:
	_apply_visual_layout()
	visual.play(&"burst")


func _process(delta: float) -> void:
	age += delta
	if age >= lifetime:
		queue_free()


func _apply_visual_layout() -> void:
	visual.scale = Vector2.ONE * (effect_radius / VISUAL_BASE_RADIUS)
	visual.frame = 0
	var frames := visual.sprite_frames
	if frames == null or not frames.has_animation(&"burst"):
		return
	var frame_count := frames.get_frame_count(&"burst")
	var animation_speed := frames.get_animation_speed(&"burst")
	if frame_count <= 0 or animation_speed <= 0.0:
		return
	var animation_length := float(frame_count) / animation_speed
	visual.speed_scale = animation_length / lifetime
