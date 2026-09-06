extends Control
## A compact, high-contrast aim mark aligned to the same pointer used for fire.


func _draw() -> void:
	for direction: Vector2 in [Vector2.LEFT, Vector2.RIGHT, Vector2.UP, Vector2.DOWN]:
		draw_line(direction * 4.0, direction * 8.0, Color("091116"), 3.0)
		draw_line(direction * 4.0, direction * 8.0, Color("eee9de"), 1.0)
	draw_rect(Rect2(-1, -1, 2, 2), Color("eee9de"))
