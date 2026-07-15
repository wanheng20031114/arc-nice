extends RefCounted
class_name WorldEffectVisibility


static func is_position_near_viewport(
	context: Node,
	world_position: Vector2,
	margin: float = 192.0
) -> bool:
	if context == null or not context.is_inside_tree():
		return true
	var viewport := context.get_viewport()
	if viewport == null:
		return true
	var camera := viewport.get_camera_2d()
	if camera == null:
		return true
	var safe_zoom := Vector2(
		maxf(absf(camera.zoom.x), 0.001),
		maxf(absf(camera.zoom.y), 0.001)
	)
	var visible_world_size := viewport.get_visible_rect().size / safe_zoom
	var margin_vector := Vector2.ONE * maxf(margin, 0.0)
	var visible_world_rect := Rect2(
		camera.get_screen_center_position() - visible_world_size * 0.5 - margin_vector,
		visible_world_size + margin_vector * 2.0
	)
	return visible_world_rect.has_point(world_position)
