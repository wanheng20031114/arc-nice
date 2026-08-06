extends Node2D
class_name HomeGateController

signal enemy_reached_home(enemy: Enemy, gate_cell: Vector2i)

const HOME_GATE_ROLE := &"home_gate"
const ENEMY_COLLISION_MASK := 4
const CARDINAL_DIRECTIONS: Array[Vector2i] = [
	Vector2i.RIGHT,
	Vector2i.LEFT,
	Vector2i.DOWN,
	Vector2i.UP,
]

var overlay_tile_map_layer: TileMapLayer = null
var home_gate_cells: Array[Vector2i] = []
var home_gate_areas: Array[Area2D] = []
var home_objective_targets: Array[Node2D] = []


func setup(tile_map_layer: TileMapLayer) -> void:
	_clear_gate_areas()
	overlay_tile_map_layer = tile_map_layer
	if overlay_tile_map_layer == null or overlay_tile_map_layer.tile_set == null:
		push_error("HomeGateController: OverlayTileMapLayer 或 TileSet 缺失。")
		return

	for cell in overlay_tile_map_layer.get_used_cells():
		var tile_data := overlay_tile_map_layer.get_cell_tile_data(cell)
		if tile_data == null:
			continue
		if tile_data.get_custom_data("overlay_role") != HOME_GATE_ROLE:
			continue
		home_gate_cells.append(cell)
	home_gate_cells.sort_custom(_sort_cells)

	for cell in home_gate_cells:
		_create_gate_area(cell)
	_create_objective_targets()

	if home_gate_areas.is_empty() or home_objective_targets.is_empty():
		push_error("HomeGateController: 未在 OverlayTileMapLayer 中找到 home_gate 瓦片。")


func get_objective_targets() -> Array[Node2D]:
	return home_objective_targets.duplicate()


func get_home_gate_cells() -> Array[Vector2i]:
	return home_gate_cells.duplicate()


func _create_gate_area(cell: Vector2i) -> void:
	var area := Area2D.new()
	area.name = "HomeGate_%d_%d" % [cell.x, cell.y]
	area.collision_layer = 0
	area.collision_mask = ENEMY_COLLISION_MASK
	area.monitoring = true
	area.monitorable = false
	area.set_meta("home_gate_cell", cell)
	add_child(area)
	area.global_position = overlay_tile_map_layer.to_global(
		overlay_tile_map_layer.map_to_local(cell)
	)

	var rectangle := RectangleShape2D.new()
	rectangle.size = Vector2(overlay_tile_map_layer.tile_set.tile_size)
	var collision_shape := CollisionShape2D.new()
	collision_shape.name = "CollisionShape2D"
	collision_shape.shape = rectangle
	area.add_child(collision_shape)
	area.body_entered.connect(_on_gate_body_entered.bind(cell))
	home_gate_areas.append(area)


func _create_objective_targets() -> void:
	# A multi-cell gate is one entrance. Targeting individual tile centers can
	# make a large body aim too close to an adjacent wall even though the opening
	# itself is wide enough. One target at each connected component's geometric
	# center preserves the physical per-cell trigger while exposing the actual
	# corridor center to navigation. Future maps may contain several disconnected
	# Home gates; each component gets its own target.
	var remaining_cells: Dictionary = {}
	for cell in home_gate_cells:
		remaining_cells[cell] = true

	for seed_cell in home_gate_cells:
		if not remaining_cells.has(seed_cell):
			continue
		var component: Array[Vector2i] = []
		var pending: Array[Vector2i] = [seed_cell]
		remaining_cells.erase(seed_cell)
		while not pending.is_empty():
			var cell := pending.pop_front() as Vector2i
			component.append(cell)
			for direction in CARDINAL_DIRECTIONS:
				var neighbor := cell + direction
				if not remaining_cells.has(neighbor):
					continue
				remaining_cells.erase(neighbor)
				pending.append(neighbor)

		var objective := Node2D.new()
		objective.name = "HomeObjective_%d" % home_objective_targets.size()
		objective.set_meta("home_gate_cells", component.duplicate())
		add_child(objective)
		var global_center := Vector2.ZERO
		for cell in component:
			global_center += overlay_tile_map_layer.to_global(
				overlay_tile_map_layer.map_to_local(cell)
			)
		objective.global_position = global_center / float(component.size())
		home_objective_targets.append(objective)


func _on_gate_body_entered(body: Node2D, gate_cell: Vector2i) -> void:
	var enemy := body as Enemy
	if enemy == null or enemy.is_dead:
		return
	enemy_reached_home.emit(enemy, gate_cell)


func _clear_gate_areas() -> void:
	for area in home_gate_areas:
		if area != null and is_instance_valid(area):
			area.queue_free()
	home_gate_areas.clear()
	for objective in home_objective_targets:
		if objective != null and is_instance_valid(objective):
			objective.queue_free()
	home_objective_targets.clear()
	home_gate_cells.clear()


static func _sort_cells(a: Vector2i, b: Vector2i) -> bool:
	if a.y == b.y:
		return a.x < b.x
	return a.y < b.y
