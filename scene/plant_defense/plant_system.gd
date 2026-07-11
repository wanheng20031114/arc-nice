extends Node
class_name PlantSystem

signal plant_placed(plant: PlantDefense)
signal plant_removed(plant: PlantDefense)
signal occupancy_changed

const DEFAULT_PLACEMENT_AREA: Rect2i = Rect2i(-3, -1, 22, 18)
const MAX_PLACEMENT_MANHATTAN_DISTANCE: int = 4
const ENTITY_BLOCKING_MASK: int = 1 | 2 | 4 | 32 | 256
const FOOTPRINT_COLLISION_INSET: Vector2 = Vector2(4.0, 4.0)

var ground_tile_map: TileMapLayer = null
var owner_player: Player = null
var plant_container: Node2D = null
var placement_area: Rect2i = DEFAULT_PLACEMENT_AREA

var occupied_cells: Dictionary = {}
var plant_footprints: Dictionary = {}
var reserved_cells: Dictionary = {}


func setup(
	new_ground_tile_map: TileMapLayer,
	new_owner_player: Player,
	new_plant_container: Node2D,
	new_placement_area: Rect2i = DEFAULT_PLACEMENT_AREA
) -> void:
	ground_tile_map = new_ground_tile_map
	owner_player = new_owner_player
	plant_container = new_plant_container
	placement_area = new_placement_area


func configure(
	new_ground_tile_map: TileMapLayer,
	new_owner_player: Player,
	new_plant_container: Node2D,
	new_placement_area: Rect2i = DEFAULT_PLACEMENT_AREA
) -> void:
	setup(new_ground_tile_map, new_owner_player, new_plant_container, new_placement_area)


func get_available_configs() -> Array[PlantDefenseConfig]:
	return PlantDefenseRegistry.get_all_configs()


func get_config(plant_id: StringName) -> PlantDefenseConfig:
	return PlantDefenseRegistry.get_config(plant_id)


func get_footprint_cells(
	top_left_cell: Vector2i,
	config: PlantDefenseConfig
) -> Array[Vector2i]:
	var cells: Array[Vector2i] = []
	if config == null:
		return cells

	for y in range(config.footprint_size.y):
		for x in range(config.footprint_size.x):
			cells.append(top_left_cell + Vector2i(x, y))
	return cells


func get_anchor_world_position(
	top_left_cell: Vector2i,
	config: PlantDefenseConfig
) -> Vector2:
	if ground_tile_map == null or config == null:
		return Vector2.ZERO

	var bottom_right_cell := top_left_cell + config.footprint_size - Vector2i.ONE
	var first_center := ground_tile_map.to_global(ground_tile_map.map_to_local(top_left_cell))
	var last_center := ground_tile_map.to_global(ground_tile_map.map_to_local(bottom_right_cell))
	return (first_center + last_center) * 0.5


func get_valid_anchors(config: PlantDefenseConfig) -> Array[Vector2i]:
	var valid_anchors: Array[Vector2i] = []
	if not _is_ready_for_placement() or config == null or not config.is_valid():
		return valid_anchors

	var last_top_left_exclusive := placement_area.end - config.footprint_size + Vector2i.ONE
	for y in range(placement_area.position.y, last_top_left_exclusive.y):
		for x in range(placement_area.position.x, last_top_left_exclusive.x):
			var top_left_cell := Vector2i(x, y)
			if is_placement_valid(top_left_cell, config):
				valid_anchors.append(top_left_cell)
	return valid_anchors


func is_placement_valid(top_left_cell: Vector2i, config: PlantDefenseConfig) -> bool:
	if not _is_ready_for_placement() or config == null or not config.is_valid():
		return false

	var cells := get_footprint_cells(top_left_cell, config)
	if cells.size() != config.footprint_size.x * config.footprint_size.y:
		return false
	if not _is_within_player_distance(cells):
		return false

	for cell in cells:
		if not placement_area.has_point(cell):
			return false
		if reserved_cells.has(cell) or occupied_cells.has(cell):
			return false
		if not _is_floor_cell_available(cell):
			return false

	return _is_entity_space_clear(top_left_cell, config)


func try_place(config: PlantDefenseConfig, top_left_cell: Vector2i) -> PlantDefense:
	if not is_placement_valid(top_left_cell, config):
		return null

	var instance := config.plant_scene.instantiate()
	var plant := instance as PlantDefense
	if plant == null:
		push_error("Plant scene root must inherit PlantDefense: %s" % config.plant_id)
		instance.free()
		return null

	var cells := get_footprint_cells(top_left_cell, config)
	plant.name = "%s_%d" % [String(config.plant_id), plant.get_instance_id()]
	plant_container.add_child(plant)
	plant.global_position = get_anchor_world_position(top_left_cell, config)
	_register_plant_footprint(plant, cells)
	plant.died.connect(_on_plant_died.bind(plant), CONNECT_ONE_SHOT)
	plant.tree_exiting.connect(_on_plant_tree_exiting.bind(plant), CONNECT_ONE_SHOT)
	plant.setup(config, owner_player, cells)
	plant_placed.emit(plant)
	return plant


func try_place_by_id(plant_id: StringName, top_left_cell: Vector2i) -> PlantDefense:
	return try_place(get_config(plant_id), top_left_cell)


func get_plant_at_cell(cell: Vector2i) -> PlantDefense:
	return occupied_cells.get(cell) as PlantDefense


func is_cell_occupied(cell: Vector2i) -> bool:
	return occupied_cells.has(cell)


func set_reserved_cells(cells: Array[Vector2i]) -> void:
	reserved_cells.clear()
	for cell in cells:
		reserved_cells[cell] = true


func reserve_cell(cell: Vector2i) -> void:
	reserved_cells[cell] = true


func reserve_world_position(world_position: Vector2, cell_radius: int = 0) -> void:
	if ground_tile_map == null:
		return

	var center_cell := ground_tile_map.local_to_map(ground_tile_map.to_local(world_position))
	var radius := maxi(cell_radius, 0)
	for y in range(center_cell.y - radius, center_cell.y + radius + 1):
		for x in range(center_cell.x - radius, center_cell.x + radius + 1):
			reserved_cells[Vector2i(x, y)] = true


func clear_reserved_cells() -> void:
	reserved_cells.clear()


func clear_all_plants() -> void:
	var plants := plant_footprints.keys()
	for plant_variant in plants:
		var plant := plant_variant as PlantDefense
		_release_plant_footprint(plant)
		if is_instance_valid(plant):
			plant.queue_free()


func _is_ready_for_placement() -> bool:
	return (
		ground_tile_map != null
		and ground_tile_map.tile_set != null
		and is_instance_valid(owner_player)
		and is_instance_valid(plant_container)
	)


func _is_within_player_distance(cells: Array[Vector2i]) -> bool:
	if ground_tile_map == null or not is_instance_valid(owner_player):
		return false

	var player_cell := ground_tile_map.local_to_map(
		ground_tile_map.to_local(owner_player.global_position)
	)
	var closest_distance := 1 << 30
	for cell in cells:
		var distance := absi(cell.x - player_cell.x) + absi(cell.y - player_cell.y)
		closest_distance = mini(closest_distance, distance)
	return closest_distance <= MAX_PLACEMENT_MANHATTAN_DISTANCE


func _is_floor_cell_available(cell: Vector2i) -> bool:
	var tile_data := ground_tile_map.get_cell_tile_data(cell)
	if tile_data == null:
		return false
	return tile_data.get_collision_polygons_count(0) == 0


func _is_entity_space_clear(
	top_left_cell: Vector2i,
	config: PlantDefenseConfig
) -> bool:
	if not is_inside_tree():
		return false

	var tile_size := Vector2(ground_tile_map.tile_set.tile_size)
	var query_shape := RectangleShape2D.new()
	query_shape.size = tile_size * Vector2(config.footprint_size) - FOOTPRINT_COLLISION_INSET

	var query := PhysicsShapeQueryParameters2D.new()
	query.shape = query_shape
	query.transform = Transform2D(0.0, get_anchor_world_position(top_left_cell, config))
	query.collision_mask = ENTITY_BLOCKING_MASK
	query.collide_with_areas = true
	query.collide_with_bodies = true
	return ground_tile_map.get_world_2d().direct_space_state.intersect_shape(query, 1).is_empty()


func _register_plant_footprint(plant: PlantDefense, cells: Array[Vector2i]) -> void:
	plant_footprints[plant] = cells.duplicate()
	for cell in cells:
		occupied_cells[cell] = plant
	occupancy_changed.emit()


func _release_plant_footprint(plant: PlantDefense) -> void:
	if plant == null or not plant_footprints.has(plant):
		return

	var cells: Array = plant_footprints[plant]
	plant_footprints.erase(plant)
	for cell_variant in cells:
		var cell: Vector2i = cell_variant
		if occupied_cells.get(cell) == plant:
			occupied_cells.erase(cell)
	occupancy_changed.emit()
	plant_removed.emit(plant)


func _on_plant_died(plant: PlantDefense) -> void:
	_release_plant_footprint(plant)


func _on_plant_tree_exiting(plant: PlantDefense) -> void:
	_release_plant_footprint(plant)
