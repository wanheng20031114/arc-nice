extends Node2D
class_name CapooKnightSlashEffect

@onready var animated_sprite: AnimatedSprite2D = $AnimatedSprite2D


func _ready() -> void:
	animated_sprite.animation_finished.connect(queue_free)
	animated_sprite.play(&"slash")
