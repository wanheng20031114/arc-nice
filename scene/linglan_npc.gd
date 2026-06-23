extends Node2D
class_name LinglanNpc

@onready var collision_shape: CollisionShape2D = $StaticBody2D/CollisionShape2D
@onready var interaction_area: Area2D = $InteractionArea

var is_active: bool = false


func _ready() -> void:
	set_active(visible)


func set_active(active: bool) -> void:
	is_active = active
	visible = active
	interaction_area.set_deferred("monitoring", active)
	collision_shape.set_deferred("disabled", not active)
