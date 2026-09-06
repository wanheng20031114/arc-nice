extends Node2D

func get_spawn_position(team: String, index: int) -> Vector2:
	return Vector2(100 if team == "CT" else 700, 180 + index * 25)

func is_in_buy_zone(point: Vector2, team: String) -> bool:
	return Rect2(50 if team == "CT" else 650, 120, 100, 150).has_point(point)

func get_callout(_point: Vector2) -> String:
	return "物理测试区"

func get_obstacle_rects() -> Array[Rect2]:
	return [Rect2(420, 70, 32, 230)]
