extends Node2D
class_name ZhuangfangyiMerchant

@onready var collision_shape: CollisionShape2D = $StaticBody2D/CollisionShape2D


func _ready() -> void:
	set_active(visible)


func set_active(active: bool) -> void:
	visible = active
	collision_shape.disabled = not active
