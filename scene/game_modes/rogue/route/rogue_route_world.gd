extends Node2D
class_name RogueRouteWorld

@onready var route_board: RogueRouteBoard = $RouteBoard
@onready var map_camera: Camera2D = $Camera2D
@onready var backdrop: Parallax2D = $Backdrop
@onready var ruins_background: Sprite2D = $Backdrop/RuinsBackground
@onready var left_boundary: CollisionShape2D = $WorldBounds/Left
@onready var right_boundary: CollisionShape2D = $WorldBounds/Right
@onready var top_boundary: CollisionShape2D = $WorldBounds/Top
@onready var bottom_boundary: CollisionShape2D = $WorldBounds/Bottom


func _ready() -> void:
	if not route_board.layout_bounds_changed.is_connected(
		_on_layout_bounds_changed
	):
		route_board.layout_bounds_changed.connect(_on_layout_bounds_changed)
	configure_world_bounds()


func configure_world_bounds() -> void:
	_on_layout_bounds_changed(route_board.get_world_bounds())


func attach_camera_to_player(player: Player) -> void:
	if player == null or not is_instance_valid(player):
		return
	var metrics := route_board.get_world_metrics()
	if metrics == null:
		return
	map_camera.process_callback = Camera2D.CAMERA2D_PROCESS_PHYSICS
	player.physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_ON
	if map_camera.get_parent() != player:
		map_camera.reparent(player)
	map_camera.physics_interpolation_mode = (
		Node.PHYSICS_INTERPOLATION_MODE_INHERIT
	)
	map_camera.position = Vector2.ZERO
	map_camera.zoom = metrics.get_camera_zoom_vector()
	map_camera.position_smoothing_enabled = false
	map_camera.enabled = true
	configure_world_bounds()
	player.reset_physics_interpolation()
	map_camera.reset_physics_interpolation()


func detach_camera_from_player() -> void:
	if map_camera.get_parent() != self:
		map_camera.reparent(self, true)


func apply_camera_drag(
	player: Player,
	screen_delta: Vector2,
	viewport_size: Vector2
) -> void:
	if player == null or not is_instance_valid(player):
		return
	map_camera.position -= screen_delta / map_camera.zoom
	clamp_camera_drag(player, viewport_size)


func clamp_camera_drag(player: Player, viewport_size: Vector2) -> void:
	if player == null or not is_instance_valid(player):
		return
	var bounds := route_board.get_world_bounds()
	var half_view := viewport_size / map_camera.zoom * 0.5
	var min_center := bounds.position + half_view
	var max_center := bounds.end - half_view
	if min_center.x > max_center.x:
		min_center.x = bounds.get_center().x
		max_center.x = min_center.x
	if min_center.y > max_center.y:
		min_center.y = bounds.get_center().y
		max_center.y = min_center.y
	var requested_center := player.global_position + map_camera.position
	var clamped_center := Vector2(
		clampf(requested_center.x, min_center.x, max_center.x),
		clampf(requested_center.y, min_center.y, max_center.y)
	)
	# zoom=2 时半个世界像素恰好对应一个屏幕像素，既保留平滑移动，
	# 又避免拖拽偏移把世界字体落在半屏幕像素上。
	var drag_snap := 1.0 / maxf(map_camera.zoom.x, 0.001)
	var local_offset := clamped_center - player.global_position
	map_camera.position = Vector2(
		snappedf(local_offset.x, drag_snap),
		snappedf(local_offset.y, drag_snap)
	)


func recenter_camera(player: Player, viewport_size: Vector2) -> void:
	if player == null or not is_instance_valid(player):
		return
	map_camera.position = Vector2.ZERO
	clamp_camera_drag(player, viewport_size)
	map_camera.reset_physics_interpolation()


func _on_layout_bounds_changed(bounds: Rect2) -> void:
	var metrics := route_board.get_world_metrics()
	if metrics == null:
		return
	map_camera.limit_left = floori(bounds.position.x)
	map_camera.limit_top = floori(bounds.position.y)
	map_camera.limit_right = ceili(bounds.end.x)
	map_camera.limit_bottom = ceili(bounds.end.y)

	var local_start := to_local(bounds.position)
	var local_end := to_local(bounds.end)
	var local_bounds := Rect2(local_start, local_end - local_start).abs()
	var thickness := metrics.boundary_thickness
	var half_thickness := thickness * 0.5
	var center := local_bounds.get_center()
	_set_rectangle_size(
		left_boundary,
		Vector2(thickness, local_bounds.size.y + thickness * 2.0)
	)
	_set_rectangle_size(
		right_boundary,
		Vector2(thickness, local_bounds.size.y + thickness * 2.0)
	)
	_set_rectangle_size(
		top_boundary,
		Vector2(local_bounds.size.x + thickness * 2.0, thickness)
	)
	_set_rectangle_size(
		bottom_boundary,
		Vector2(local_bounds.size.x + thickness * 2.0, thickness)
	)
	left_boundary.position = Vector2(
		local_bounds.position.x - half_thickness,
		center.y
	)
	right_boundary.position = Vector2(
		local_bounds.end.x + half_thickness,
		center.y
	)
	top_boundary.position = Vector2(
		center.x,
		local_bounds.position.y - half_thickness
	)
	bottom_boundary.position = Vector2(
		center.x,
		local_bounds.end.y + half_thickness
	)
	ruins_background.position = center
	if ruins_background.texture != null:
		# 保持原背景像素比例，同时让 Parallax2D 按实际显示尺寸平铺；
		# 宽屏、方形和竖屏窗口都不会露出地图底色。
		backdrop.repeat_size = (
			ruins_background.texture.get_size() * ruins_background.scale.abs()
		)
	backdrop.scroll_scale = Vector2(
		metrics.parallax_scroll_scale,
		metrics.parallax_scroll_scale
	)


func _set_rectangle_size(
	boundary: CollisionShape2D,
	shape_size: Vector2
) -> void:
	var rectangle := boundary.shape as RectangleShape2D
	if rectangle != null:
		rectangle.size = shape_size
