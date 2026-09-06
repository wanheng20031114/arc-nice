extends Node2D
class_name MirageMap
## Hand-authored Mirage layout. Geometry, landmarks and markers live in .tscn.

const WORLD_RECT := Rect2(0, 0, 1920, 1600)

var _obstacle_rects: Array[Rect2] = []


func _ready() -> void:
	for body: Node2D in get_tree().get_nodes_in_group("mirage_obstacle"):
		if is_ancestor_of(body):
			var local_rect: Rect2 = body.get_meta("obstacle_rect")
			_obstacle_rects.append(Rect2(body.global_position + local_rect.position, local_rect.size))


func get_spawn_position(team: String, index: int) -> Vector2:
	assert(team in ["CT", "T"], "Unknown Mirage team")
	var markers := get_node("Spawns/" + team)
	return (markers.get_child(posmod(index, markers.get_child_count())) as Marker2D).global_position


func is_in_buy_zone(pos: Vector2, team: String) -> bool:
	if team not in ["CT", "T"]:
		return false
	var zone := get_node("BuyZones/" + team) as Node2D
	var local_rect: Rect2 = zone.get_meta("buy_rect")
	return Rect2(zone.global_position + local_rect.position, local_rect.size).has_point(pos)


func get_obstacle_rects() -> Array[Rect2]:
	return _obstacle_rects


func get_callout(pos: Vector2) -> String:
	var nearest := "荒漠迷城"
	var nearest_distance := INF
	for marker: Marker2D in $Callouts.get_children():
		var region: PackedVector2Array = marker.get_meta("region")
		if Geometry2D.is_point_in_polygon(to_local(pos), region):
			return String(marker.get_meta("callout"))
		var distance := marker.global_position.distance_squared_to(pos)
		if distance < nearest_distance:
			nearest_distance = distance
			nearest = String(marker.get_meta("callout"))
	return nearest


func update_archway_visibility(viewer_position: Vector2) -> void:
	for arch: Sprite2D in get_tree().get_nodes_in_group("mirage_arch"):
		arch.modulate.a = 0.3 if arch.global_position.distance_to(viewer_position) < 70.0 else 0.82
