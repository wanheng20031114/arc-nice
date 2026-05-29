extends Area2D

class_name Bullet

const WORLD_COLLISION_MASK := 1

@export var speed:float = 320.0
@export var max_lifetime: float = 2.0
# Called when the node enters the scene tree for the first time.

var direction : Vector2 = Vector2.RIGHT
var remaining_lifetime : float = 0.0

func _ready() -> void:
	remaining_lifetime = max_lifetime
	area_entered.connect(_on_area_entered)
	

func setup(initial_direction:Vector2) -> void :
	if initial_direction !=Vector2.ZERO:
		direction = initial_direction.normalized()
		
		
# Called every frame. 'delta' is the elapsed time since the previous frame.
func _process(delta: float) -> void:
	pass


func _on_area_entered(area: Area2D) -> void:
	pass # Replace with function body.
