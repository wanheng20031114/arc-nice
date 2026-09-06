class_name PvpVisibility
extends Node2D
## Obstacle shadows preserve the original map colors in all visible areas.
## The render mask and enemy visibility share the same local observer.

@onready var shadow_viewport: SubViewport = $ShadowMask
@onready var shadow_canvas: Node2D = $ShadowMask/ShadowCanvas
@onready var fog: ColorRect = $FogLayer/Fog

var observer: Node2D
var _local_player: Node2D
var _players_root: Node
var _obstacles: Array[Rect2] = []
var _has_context := false
var _mask_initialized := false
var _last_origin := Vector2.INF
var _last_canvas_transform := Transform2D.IDENTITY


func _ready() -> void:
	process_priority = 100
	(fog.material as ShaderMaterial).set_shader_parameter("shadow_mask", shadow_viewport.get_texture())
	(fog.material as ShaderMaterial).set_shader_parameter("hdr_linear_space", get_viewport().use_hdr_2d and RenderingServer.get_current_rendering_method() != "gl_compatibility")
	fog.hide()


func set_context(local_player: Node2D, map: Node2D, players_root: Node) -> void:
	_local_player = local_player
	_players_root = players_root
	_obstacles = map.get_obstacle_rects()
	_mask_initialized = false
	observer = local_player
	_has_context = true
	fog.show()
	_update_mask()


func _process(_delta: float) -> void:
	if not _has_context or not is_instance_valid(_local_player):
		return
	_choose_observer()
	_update_mask()


func _physics_process(_delta: float) -> void:
	if not _has_context or not is_instance_valid(_local_player):
		return
	_choose_observer()
	var space := get_world_2d().direct_space_state
	for player: Node2D in _players_root.get_children():
		if player.team == _local_player.team:
			player.visible = true
			continue
		var query := PhysicsRayQueryParameters2D.create(observer.global_position, player.global_position, 1)
		query.collide_with_areas = false
		query.hit_from_inside = true
		player.visible = space.intersect_ray(query).is_empty()


func _choose_observer() -> void:
	if _local_player.alive:
		observer = _local_player
		return
	if is_instance_valid(observer) and observer.alive and observer.team == _local_player.team:
		return
	observer = _local_player
	for player: Node2D in _players_root.get_children():
		if player.team == _local_player.team and player.alive:
			observer = player
			break


func get_observer_position() -> Vector2:
	return observer.global_position if is_instance_valid(observer) else Vector2.ZERO


func _update_mask() -> void:
	var screen_size := Vector2i(get_viewport_rect().size)
	if screen_size.x < 2 or screen_size.y < 2:
		return
	if shadow_viewport.size != screen_size:
		shadow_viewport.size = screen_size
		_mask_initialized = false
	var canvas_transform := get_viewport().get_canvas_transform()
	if _mask_initialized and observer.global_position == _last_origin and canvas_transform == _last_canvas_transform:
		return
	# Reach beyond the furthest map edge at every supported camera zoom.
	var reach := maxf(12000.0, Vector2(screen_size).length() / maxf(canvas_transform.x.length(), 0.05) * 4.0)
	shadow_canvas.update_shadows(_obstacles, observer.global_position, canvas_transform, reach, Vector2(screen_size))
	shadow_viewport.render_target_update_mode = SubViewport.UPDATE_ONCE
	_last_origin = observer.global_position
	_last_canvas_transform = canvas_transform
	_mask_initialized = true


static func build_shadow_polygon(obstacle: Rect2, origin: Vector2, reach: float) -> PackedVector2Array:
	var corners := PackedVector2Array([
		obstacle.position, Vector2(obstacle.end.x, obstacle.position.y),
		obstacle.end, Vector2(obstacle.position.x, obstacle.end.y),
	])
	var points := corners.duplicate()
	for corner: Vector2 in corners:
		points.append(corner + (corner - origin).normalized() * reach)
	var hull := Geometry2D.convex_hull(points)
	if hull.size() > 1 and hull[0].is_equal_approx(hull[hull.size() - 1]):
		hull.remove_at(hull.size() - 1)
	return hull
