extends Control
## Static floor layout plus friendly positions. Enemy positions are never drawn.

const WORLD_SIZE := Vector2(1920, 1600)
var _floor_cells: Array[Vector2i] = []
var _obstacles: Array[Rect2] = []
var _markers: Array = []
var _local_id := 0
var _local_team := "CT"
var _map_loaded := false


func set_map(map: Node2D) -> void:
	var floor_layer: TileMapLayer = map.get_node("WalkableFloor")
	_floor_cells = floor_layer.get_used_cells()
	_obstacles = map.get_obstacle_rects()
	_map_loaded = true
	queue_redraw()


func update_players(players: Array, local_id: int, local_team: String) -> void:
	_markers = players
	_local_id = local_id
	_local_team = local_team
	queue_redraw()


func _draw() -> void:
	if not _map_loaded:
		return
	var scale_factor := minf(size.x / WORLD_SIZE.x, size.y / WORLD_SIZE.y)
	var origin := (size - WORLD_SIZE * scale_factor) * 0.5
	for cell: Vector2i in _floor_cells:
		draw_rect(Rect2(origin + Vector2(cell) * 32.0 * scale_factor, Vector2.ONE * (32.0 * scale_factor + 0.25)), Color(0.58, 0.56, 0.48, 0.8))
	for obstacle: Rect2 in _obstacles:
		draw_rect(Rect2(origin + obstacle.position * scale_factor, obstacle.size * scale_factor), Color(0.09, 0.13, 0.14, 1.0))
	for player: Dictionary in _markers:
		if player["team"] != _local_team or not player["alive"]:
			continue
		var point: Vector2 = origin + player["position"] * scale_factor
		var is_self: bool = player["peer_id"] == _local_id
		var color := Color.WHITE if is_self else (PvpHUD.CT_COLOR if _local_team == "CT" else PvpHUD.T_COLOR)
		draw_circle(point, 4.6 if is_self else 3.8, Color("0b1418"))
		draw_circle(point, 3.0 if is_self else 2.3, color)
		if is_self:
			draw_arc(point, 6.0, 0.0, TAU, 20, color, 1.0, true)
