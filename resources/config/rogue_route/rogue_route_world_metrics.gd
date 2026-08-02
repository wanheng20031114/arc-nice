@tool
extends Resource
class_name RogueRouteWorldMetrics

## 路线世界中唯一的几何度量来源。路线板、相机、物理墙和联机位置校验
## 都必须从同一份资源读取，避免视觉缩放后各系统仍使用旧边界。

@export_group("网格布局")
@export var default_grid_size := Vector2i(11, 9)
@export var cell_spacing := Vector2(88.0, 48.0)
@export var board_margin := Vector2(96.0, 96.0)

@export_group("探索交互")
@export_range(1.0, 256.0, 1.0) var node_interaction_radius := 28.0
@export_range(2.0, 64.0, 1.0) var boundary_thickness := 16.0

@export_group("镜头")
@export_range(1.0, 4.0, 0.25) var camera_zoom := 2.0
@export_range(0.01, 1.0, 0.01) var parallax_scroll_scale := 0.10


func validate_metrics() -> PackedStringArray:
	var errors := PackedStringArray()
	if default_grid_size.x <= 0 or default_grid_size.y <= 0:
		errors.append("default_grid_size 必须为正数。")
	if (
		not cell_spacing.is_finite()
		or cell_spacing.x <= 0.0
		or cell_spacing.y <= 0.0
	):
		errors.append("cell_spacing 必须是有限正数。")
	if (
		not board_margin.is_finite()
		or board_margin.x < 0.0
		or board_margin.y < 0.0
	):
		errors.append("board_margin 必须是有限非负数。")
	if (
		not is_finite(node_interaction_radius)
		or node_interaction_radius <= 0.0
	):
		errors.append("node_interaction_radius 必须是有限正数。")
	elif node_interaction_radius >= minf(cell_spacing.x, cell_spacing.y):
		errors.append("node_interaction_radius 必须小于最短节点间距。")
	if not is_finite(boundary_thickness) or boundary_thickness <= 0.0:
		errors.append("boundary_thickness 必须是有限正数。")
	if not is_finite(camera_zoom) or camera_zoom <= 0.0:
		errors.append("camera_zoom 必须是有限正数。")
	if (
		not is_finite(parallax_scroll_scale)
		or parallax_scroll_scale <= 0.0
		or parallax_scroll_scale > 1.0
	):
		errors.append("parallax_scroll_scale 必须位于 0（不含）到 1。")
	return errors


func get_layout_size(grid_size: Vector2i) -> Vector2:
	return Vector2(
		board_margin.x * 2.0
		+ cell_spacing.x * float(maxi(grid_size.x - 1, 0)),
		board_margin.y * 2.0
		+ cell_spacing.y * float(maxi(grid_size.y - 1, 0))
	)


func get_camera_zoom_vector() -> Vector2:
	return Vector2(camera_zoom, camera_zoom)


func compute_contract_hash() -> String:
	return "\n".join(PackedStringArray([
		"schema=1",
		"default_grid=%d,%d" % [default_grid_size.x, default_grid_size.y],
		"spacing=%.3f,%.3f" % [cell_spacing.x, cell_spacing.y],
		"margin=%.3f,%.3f" % [board_margin.x, board_margin.y],
		"interaction_radius=%.3f" % node_interaction_radius,
		"boundary_thickness=%.3f" % boundary_thickness,
		"camera_zoom=%.3f" % camera_zoom,
		"parallax=%.3f" % parallax_scroll_scale,
	])).sha256_text()
