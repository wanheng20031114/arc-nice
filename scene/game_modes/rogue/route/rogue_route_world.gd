extends Node2D
class_name RogueRouteWorld

const MINIMUM_INTEGER_PIXEL_SCALE := 2
# 仅属于本地路线表现，不进入地图快照或运行契约。物理宽高达到
# 1280×720 支持阈值后，以整数 K 呈现同一份 640×360 安全视野；更小的
# 物理窗口优先保持 K2 的可读尺寸，允许少显示一部分路线内容。
const REFERENCE_VISIBLE_WORLD_SIZE := Vector2(640.0, 360.0)

@onready var route_board: RogueRouteBoard = $RouteBoard
@onready var map_camera: Camera2D = $Camera2D
@onready var backdrop: Parallax2D = $Backdrop
@onready var ruins_background: Sprite2D = $Backdrop/RuinsBackground
@onready var left_boundary: CollisionShape2D = $WorldBounds/Left
@onready var right_boundary: CollisionShape2D = $WorldBounds/Right
@onready var top_boundary: CollisionShape2D = $WorldBounds/Top
@onready var bottom_boundary: CollisionShape2D = $WorldBounds/Bottom

var _route_pixel_snap_enabled := true
var _integer_pixel_scale := 0
var _last_stretch_transform := Transform2D()
var _has_last_stretch_transform := false
var _last_viewport_size := Vector2.ZERO
var _has_last_viewport_size := false
var _canvas_transform_before_route := Transform2D()
var _has_canvas_transform_before_route := false


func _enter_tree() -> void:
	var viewport := get_viewport()
	if viewport == null:
		return
	_canvas_transform_before_route = viewport.canvas_transform
	_has_canvas_transform_before_route = true


func _ready() -> void:
	if not route_board.layout_bounds_changed.is_connected(
		_on_layout_bounds_changed
	):
		route_board.layout_bounds_changed.connect(_on_layout_bounds_changed)
	configure_world_bounds()
	refresh_integer_route_scale()


func _exit_tree() -> void:
	set_route_pixel_snap_enabled(false)
	var viewport := get_viewport()
	# 子节点会先于 World 退出；此时路线 Camera2D 已无法通过
	# force_update_scroll() 写回原生 Canvas。若没有外部相机接管，就显式
	# 恢复进入路线前的变换，避免像素吸附残留到下一场景首帧。
	if (
		_has_canvas_transform_before_route
		and viewport != null
		and viewport.get_camera_2d() == null
	):
		viewport.canvas_transform = _canvas_transform_before_route
	_has_canvas_transform_before_route = false


## Camera2D 会先在内部 process 中提交带物理插值的 canvas_transform；World
## 使用更晚的 process priority，只量化这一帧最终的物理屏幕原点。逻辑相机、
## 玩家位置和碰撞始终保留完整精度，因此不会积累舍入误差。
func _process(_delta: float) -> void:
	if not is_route_pixel_snap_active():
		return
	var viewport := get_viewport()
	if viewport == null:
		return
	var stretch_transform := viewport.get_stretch_transform()
	var viewport_size := viewport.get_visible_rect().size
	if (
		not _has_last_stretch_transform
		or not stretch_transform.is_equal_approx(_last_stretch_transform)
		or not _has_last_viewport_size
		or not viewport_size.is_equal_approx(_last_viewport_size)
	):
		if not refresh_integer_route_scale():
			return
	apply_route_canvas_pixel_snap()


func configure_world_bounds() -> void:
	_on_layout_bounds_changed(route_board.get_world_bounds())


func attach_camera_to_player(player: Player) -> void:
	if player == null or not is_instance_valid(player):
		return
	var metrics := route_board.get_world_metrics()
	if metrics == null:
		return
	if map_camera.process_callback != Camera2D.CAMERA2D_PROCESS_PHYSICS:
		map_camera.process_callback = Camera2D.CAMERA2D_PROCESS_PHYSICS
	player.physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_ON
	if map_camera.get_parent() != player:
		map_camera.reparent(player)
	map_camera.physics_interpolation_mode = (
		Node.PHYSICS_INTERPOLATION_MODE_INHERIT
	)
	map_camera.position = Vector2.ZERO
	refresh_integer_route_scale()
	map_camera.position_smoothing_enabled = false
	map_camera.enabled = true
	configure_world_bounds()
	player.reset_physics_interpolation()
	map_camera.reset_physics_interpolation()
	map_camera.make_current()
	map_camera.force_update_scroll()
	apply_route_canvas_pixel_snap()


## 外部战斗场景拥有过同一 Viewport 的 Camera2D 后，单纯恢复 enabled
## 并不会重新取得 current。保留玩家此前的拖拽偏移，重新声明路线相机
## 的父子、采样、边界与插值契约，再强制刷新共享 Canvas 变换。
func restore_camera_after_external_scene(
	player: Player,
	viewport_size: Vector2
) -> bool:
	if player == null or not is_instance_valid(player):
		return false
	var metrics := route_board.get_world_metrics()
	if metrics == null:
		return false
	var preserved_offset := map_camera.position
	if map_camera.get_parent() != player:
		map_camera.physics_interpolation_mode = (
			Node.PHYSICS_INTERPOLATION_MODE_OFF
		)
		if map_camera.process_callback != Camera2D.CAMERA2D_PROCESS_PHYSICS:
			map_camera.process_callback = Camera2D.CAMERA2D_PROCESS_PHYSICS
		map_camera.reparent(player, false)
		# 异常父节点下的 local offset 不属于路线玩家坐标系，直接回到玩家中心。
		preserved_offset = Vector2.ZERO
	if map_camera.process_callback != Camera2D.CAMERA2D_PROCESS_PHYSICS:
		map_camera.process_callback = Camera2D.CAMERA2D_PROCESS_PHYSICS
	player.physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_ON
	map_camera.physics_interpolation_mode = (
		Node.PHYSICS_INTERPOLATION_MODE_INHERIT
	)
	map_camera.position = preserved_offset
	if not refresh_integer_route_scale():
		return false
	map_camera.position_smoothing_enabled = false
	configure_world_bounds()
	clamp_camera_drag(player, viewport_size)
	map_camera.enabled = true
	map_camera.make_current()
	player.reset_physics_interpolation()
	map_camera.reset_physics_interpolation()
	map_camera.force_update_scroll()
	apply_route_canvas_pixel_snap()
	return map_camera.get_viewport().get_camera_2d() == map_camera


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
	var local_offset := clamped_center - player.global_position
	# 拖拽目标保持完整世界精度；物理像素相位只在最终 canvas transform 上
	# 量化。若在这里再次吸附，会把 root stretch 的小数倍率重新引入。
	map_camera.position = local_offset


func recenter_camera(player: Player, viewport_size: Vector2) -> void:
	if player == null or not is_instance_valid(player):
		return
	map_camera.position = Vector2.ZERO
	clamp_camera_drag(player, viewport_size)
	map_camera.reset_physics_interpolation()


func set_route_pixel_snap_enabled(enabled: bool) -> void:
	if _route_pixel_snap_enabled == enabled:
		return
	if not enabled:
		# 我们只在路线相机仍实际拥有该 Viewport 时，先让 Camera2D 写回
		# 原生（未相位吸附）的 canvas transform。若战斗相机已接管，绝不
		# 覆盖外部相机这一帧提交的 transform。
		var viewport := get_viewport()
		if (
			map_camera != null
			and map_camera.is_inside_tree()
			and viewport != null
			and viewport.get_camera_2d() == map_camera
		):
			map_camera.force_update_scroll()
		_route_pixel_snap_enabled = false
		return
	_route_pixel_snap_enabled = enabled
	if not refresh_integer_route_scale():
		return
	if map_camera != null and map_camera.is_inside_tree():
		map_camera.reset_physics_interpolation()
		map_camera.force_update_scroll()
	apply_route_canvas_pixel_snap()


func refresh_integer_route_scale() -> bool:
	if map_camera == null or route_board == null:
		return false
	var viewport := get_viewport()
	if viewport == null:
		return false
	var stretch_transform := viewport.get_stretch_transform()
	var stretch_scale := stretch_transform.get_scale().abs()
	if not _is_valid_stretch_scale(stretch_scale):
		return false
	var viewport_size := viewport.get_visible_rect().size
	var physical_viewport_size := viewport_size * stretch_scale
	var selected_scale := calculate_safe_integer_pixel_scale(
		physical_viewport_size
	)
	var compensated_zoom := calculate_compensated_camera_zoom(
		selected_scale,
		stretch_scale
	)
	var zoom_changed := not map_camera.zoom.is_equal_approx(compensated_zoom)
	var viewport_size_changed := (
		not _has_last_viewport_size
		or not viewport_size.is_equal_approx(_last_viewport_size)
	)
	_integer_pixel_scale = selected_scale
	_last_stretch_transform = stretch_transform
	_has_last_stretch_transform = true
	_last_viewport_size = viewport_size
	_has_last_viewport_size = true
	if zoom_changed:
		map_camera.zoom = compensated_zoom
	if zoom_changed or viewport_size_changed:
		var camera_player := map_camera.get_parent() as Player
		if camera_player != null and is_instance_valid(camera_player):
			# EXPAND 模式下，窗口比例变化可能只改变可见逻辑尺寸而不改变
			# stretch basis；因此与 zoom 变化一样需要重新收紧拖拽边界。
			clamp_camera_drag(camera_player, viewport_size)
	if zoom_changed:
		if map_camera.is_inside_tree():
			# 视口 resize 不得在旧、新 zoom 之间插值一帧。
			map_camera.reset_physics_interpolation()
			if viewport.get_camera_2d() == map_camera:
				map_camera.force_update_scroll()
	return true


func apply_route_canvas_pixel_snap() -> bool:
	if not is_route_pixel_snap_active():
		return false
	var viewport := get_viewport()
	if viewport == null:
		return false
	viewport.canvas_transform = snap_canvas_transform_to_physical_pixels(
		viewport.canvas_transform,
		viewport.get_stretch_transform()
	)
	return true


func get_integer_pixel_scale() -> int:
	return _integer_pixel_scale


func get_effective_physical_world_scale() -> Vector2:
	var viewport := get_viewport()
	if viewport == null or map_camera == null:
		return Vector2.ZERO
	return (
		viewport.get_stretch_transform().get_scale().abs()
		* map_camera.zoom.abs()
	)


func is_route_pixel_snap_active() -> bool:
	if (
		not _route_pixel_snap_enabled
		or map_camera == null
		or not map_camera.enabled
		or not is_visible_in_tree()
	):
		return false
	var viewport := get_viewport()
	return viewport != null and viewport.get_camera_2d() == map_camera


func get_rendered_camera_center() -> Vector2:
	var viewport := get_viewport()
	if viewport == null:
		return Vector2.ZERO
	return viewport.canvas_transform.affine_inverse() * (
		viewport.get_visible_rect().size * 0.5
	)


static func calculate_safe_integer_pixel_scale(
	physical_viewport_size: Vector2,
	reference_visible_world_size: Vector2 = REFERENCE_VISIBLE_WORLD_SIZE
) -> int:
	if (
		not _is_valid_positive_size(physical_viewport_size)
		or not _is_valid_positive_size(reference_visible_world_size)
	):
		return MINIMUM_INTEGER_PIXEL_SCALE
	var safe_scale := minf(
		physical_viewport_size.x / reference_visible_world_size.x,
		physical_viewport_size.y / reference_visible_world_size.y
	)
	# 达到 1280×720 支持阈值后向下取整，保证 K 不会裁掉 640×360
	# 安全框；最低 K2 则让 1152×648 设计画布保持可读的节点尺寸。
	return maxi(
		floori(safe_scale),
		MINIMUM_INTEGER_PIXEL_SCALE
	)


static func calculate_compensated_camera_zoom(
	integer_pixel_scale: int,
	stretch_scale: Vector2
) -> Vector2:
	if not _is_valid_stretch_scale(stretch_scale):
		return Vector2.ONE
	var safe_integer_scale := maxi(
		integer_pixel_scale,
		MINIMUM_INTEGER_PIXEL_SCALE
	)
	return Vector2(
		float(safe_integer_scale) / stretch_scale.x,
		float(safe_integer_scale) / stretch_scale.y
	)


static func snap_canvas_transform_to_physical_pixels(
	canvas_transform: Transform2D,
	stretch_transform: Transform2D
) -> Transform2D:
	if is_zero_approx(stretch_transform.determinant()):
		return canvas_transform
	var physical_transform := stretch_transform * canvas_transform
	physical_transform.origin = physical_transform.origin.round()
	return stretch_transform.affine_inverse() * physical_transform


static func _is_valid_stretch_scale(stretch_scale: Vector2) -> bool:
	return _is_valid_positive_size(stretch_scale)


static func _is_valid_positive_size(value: Vector2) -> bool:
	return (
		value.is_finite()
		and value.x > 0.0
		and value.y > 0.0
	)


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
