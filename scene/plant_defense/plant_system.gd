extends Node
class_name PlantSystem

signal plant_placed(plant: PlantDefense)
signal plant_removed(plant: PlantDefense)
signal occupancy_changed

const DEFAULT_PLACEMENT_AREA: Rect2i = Rect2i(-3, -1, 22, 18)
const MAX_PLACEMENT_MANHATTAN_DISTANCE: int = 4
const ENTITY_BLOCKING_MASK: int = 1 | 2 | 4 | 32 | 256
const FOOTPRINT_COLLISION_INSET: Vector2 = Vector2(4.0, 4.0)

@export_range(0, 64, 1) var max_placement_manhattan_distance: int = (
	MAX_PLACEMENT_MANHATTAN_DISTANCE
)

var ground_tile_map: TileMapLayer = null
var terrain_map: DualGridTilemap = null
var owner_player: Player = null
var plant_container: Node2D = null
var placement_area: Rect2i = DEFAULT_PLACEMENT_AREA

var occupied_cells: Dictionary = {}
var plant_footprints: Dictionary = {}
var reserved_cells: Dictionary = {}
var plants_by_net_id: Dictionary[int, PlantDefense] = {}
var _nearest_plant_candidate_cache: Dictionary = {}


func setup(
	new_ground_tile_map: TileMapLayer,
	new_owner_player: Player,
	new_plant_container: Node2D,
	new_placement_area: Rect2i = DEFAULT_PLACEMENT_AREA,
	new_terrain_map: DualGridTilemap = null
) -> void:
	ground_tile_map = new_ground_tile_map
	terrain_map = new_terrain_map
	owner_player = new_owner_player
	plant_container = new_plant_container
	placement_area = new_placement_area
	_invalidate_nearest_plant_candidate_cache()


func configure(
	new_ground_tile_map: TileMapLayer,
	new_owner_player: Player,
	new_plant_container: Node2D,
	new_placement_area: Rect2i = DEFAULT_PLACEMENT_AREA,
	new_terrain_map: DualGridTilemap = null
) -> void:
	setup(
		new_ground_tile_map,
		new_owner_player,
		new_plant_container,
		new_placement_area,
		new_terrain_map
	)


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
	return get_valid_anchors_for_player(config, owner_player)


func get_valid_anchors_for_player(
	config: PlantDefenseConfig,
	placement_player: Player
) -> Array[Vector2i]:
	var valid_anchors: Array[Vector2i] = []
	if not _is_ready_for_placement(placement_player) or config == null or not config.is_valid():
		return valid_anchors

	var player_cell := _get_player_cell(placement_player)
	var candidate_area := _get_candidate_anchor_area(config, player_cell)
	for y in range(candidate_area.position.y, candidate_area.end.y):
		for x in range(candidate_area.position.x, candidate_area.end.x):
			var top_left_cell := Vector2i(x, y)
			if (
				_get_footprint_manhattan_distance(
					top_left_cell,
					config.footprint_size,
					player_cell
				)
				> maxi(max_placement_manhattan_distance, 0)
			):
				continue
			if is_placement_valid_for_player(top_left_cell, config, placement_player):
				valid_anchors.append(top_left_cell)
	return valid_anchors


func is_placement_valid(top_left_cell: Vector2i, config: PlantDefenseConfig) -> bool:
	return is_placement_valid_for_player(top_left_cell, config, owner_player)


func is_placement_valid_for_player(
	top_left_cell: Vector2i,
	config: PlantDefenseConfig,
	placement_player: Player
) -> bool:
	if not _is_ready_for_placement(placement_player) or config == null or not config.is_valid():
		return false

	var cells := get_footprint_cells(top_left_cell, config)
	if cells.size() != config.footprint_size.x * config.footprint_size.y:
		return false
	if (
		_get_footprint_manhattan_distance(
			top_left_cell,
			config.footprint_size,
			_get_player_cell(placement_player)
		)
		> maxi(max_placement_manhattan_distance, 0)
	):
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
	return try_place_for_player(config, top_left_cell, owner_player)


func try_place_for_player(
	config: PlantDefenseConfig,
	top_left_cell: Vector2i,
	placement_player: Player,
	net_id: int = 0
) -> PlantDefense:
	if net_id < 0:
		push_error("PlantSystem net_id cannot be negative.")
		return null
	if net_id > 0 and plants_by_net_id.has(net_id):
		push_error("PlantSystem duplicate authoritative net_id: %d." % net_id)
		return null
	if not is_placement_valid_for_player(top_left_cell, config, placement_player):
		return null
	return _instantiate_registered_plant(
		config,
		top_left_cell,
		placement_player,
		net_id,
		false,
		-1,
		0,
		-1
	)


func spawn_multiplayer_replica(
	plant_id: StringName,
	top_left_cell: Vector2i,
	placement_player: Player,
	net_id: int,
	current_health: int,
	maximum_health: int,
	health_revision: int
) -> PlantDefense:
	var config := get_config(plant_id)
	if (
		config == null
		or not config.is_valid()
		or not config.supports_multiplayer
		or net_id <= 0
		or ground_tile_map == null
		or ground_tile_map.tile_set == null
		or not is_instance_valid(plant_container)
	):
		return null
	if plants_by_net_id.has(net_id):
		var existing_plant := plants_by_net_id[net_id] as PlantDefense
		if (
			existing_plant != null
			and is_instance_valid(existing_plant)
			and not existing_plant.is_queued_for_deletion()
		):
			return existing_plant
		plants_by_net_id.erase(net_id)
	var cells := get_footprint_cells(top_left_cell, config)
	for cell in cells:
		if not placement_area.has_point(cell):
			push_error("PlantSystem replica footprint is outside placement area at %s." % cell)
			return null
		if reserved_cells.has(cell) or occupied_cells.has(cell):
			push_error("PlantSystem replica footprint conflicts at %s." % cell)
			return null
	return _instantiate_registered_plant(
		config,
		top_left_cell,
		placement_player,
		net_id,
		true,
		clampi(current_health, 0, maxi(maximum_health, 1)),
		health_revision,
		maximum_health
	)


func _instantiate_registered_plant(
	config: PlantDefenseConfig,
	top_left_cell: Vector2i,
	placement_player: Player,
	net_id: int,
	as_multiplayer_proxy: bool,
	initial_health: int,
	initial_health_revision: int,
	initial_maximum_health: int
) -> PlantDefense:

	var instance := config.plant_scene.instantiate()
	var plant := instance as PlantDefense
	if plant == null:
		push_error("Plant scene root must inherit PlantDefense: %s" % config.plant_id)
		instance.free()
		return null

	var cells := get_footprint_cells(top_left_cell, config)
	plant.name = (
		"%s_net_%d" % [String(config.plant_id), net_id]
		if net_id > 0
		else "%s_%d" % [String(config.plant_id), plant.get_instance_id()]
	)
	plant_container.add_child(plant)
	plant.global_position = get_anchor_world_position(top_left_cell, config)
	if net_id > 0:
		plant.set_meta(&"net_id", net_id)
		plants_by_net_id[net_id] = plant
	_register_plant_footprint(plant, cells)
	plant.died.connect(_on_plant_died.bind(plant), CONNECT_ONE_SHOT)
	plant.tree_exiting.connect(_on_plant_tree_exiting.bind(plant), CONNECT_ONE_SHOT)
	plant.setup(
		config,
		placement_player,
		cells,
		as_multiplayer_proxy,
		initial_health,
		initial_health_revision,
		initial_maximum_health
	)
	if plant.is_dead:
		return null
	plant_placed.emit(plant)
	return plant


func try_place_by_id(plant_id: StringName, top_left_cell: Vector2i) -> PlantDefense:
	return try_place(get_config(plant_id), top_left_cell)


func get_plant_at_cell(cell: Vector2i) -> PlantDefense:
	return occupied_cells.get(cell) as PlantDefense


func find_nearest_living_plant(
	from_global_position: Vector2,
	max_radius_cells: float
) -> PlantDefense:
	if (
		ground_tile_map == null
		or ground_tile_map.tile_set == null
		or occupied_cells.is_empty()
		or max_radius_cells < 0.0
	):
		return null

	# occupied_cells already is the authoritative spatial index for every
	# single-player, host and replicated plant. A bounded cell query keeps target
	# selection independent of the total plant count and avoids a SceneTree scan
	# for every enemy retarget.
	var tile_size := Vector2(ground_tile_map.tile_set.tile_size).abs()
	if tile_size.x <= 0.0 or tile_size.y <= 0.0:
		return null
	var from_local := ground_tile_map.to_local(from_global_position)
	var center_cell := ground_tile_map.local_to_map(from_local)
	# One extra cell covers sub-cell source positions and even-sized footprints
	# whose authored anchor lies between two logical cells.
	var search_radius := ceili(max_radius_cells) + 1
	var maximum_distance_squared := max_radius_cells * max_radius_cells
	var nearest_plant: PlantDefense = null
	var nearest_distance_squared := INF
	var candidates := _get_nearest_plant_candidates(center_cell, search_radius)
	for candidate_variant in candidates:
		var plant := candidate_variant as PlantDefense
		if (
			plant == null
			or not is_instance_valid(plant)
			or plant.is_dead
			or plant.is_queued_for_deletion()
		):
			continue
		# Candidate membership is cached by logical cell topology, but distance
		# always uses the current world positions. Enemies sharing a cell can
		# therefore reuse the broad candidate set without sharing a target result.
		var plant_local := ground_tile_map.to_local(plant.global_position)
		var offset_in_cells := Vector2(
			(plant_local.x - from_local.x) / tile_size.x,
			(plant_local.y - from_local.y) / tile_size.y
		)
		var distance_squared := offset_in_cells.length_squared()
		if (
			distance_squared <= maximum_distance_squared
			and distance_squared < nearest_distance_squared
		):
			nearest_distance_squared = distance_squared
			nearest_plant = plant
	return nearest_plant


func _get_nearest_plant_candidates(
	center_cell: Vector2i,
	search_radius: int
) -> Array:
	var safe_search_radius := maxi(search_radius, 0)
	var cache_key := Vector3i(center_cell.x, center_cell.y, safe_search_radius)
	if _nearest_plant_candidate_cache.has(cache_key):
		return _nearest_plant_candidate_cache[cache_key] as Array

	var candidates := _build_nearest_plant_candidates(
		center_cell,
		safe_search_radius
	)
	_nearest_plant_candidate_cache[cache_key] = candidates
	return candidates


func _build_nearest_plant_candidates(
	center_cell: Vector2i,
	search_radius: int
) -> Array[PlantDefense]:
	var candidates: Array[PlantDefense] = []
	var seen_instance_ids: Dictionary[int, bool] = {}
	for cell_y in range(
		center_cell.y - search_radius,
		center_cell.y + search_radius + 1
	):
		for cell_x in range(
			center_cell.x - search_radius,
			center_cell.x + search_radius + 1
		):
			var plant := occupied_cells.get(Vector2i(cell_x, cell_y)) as PlantDefense
			if (
				plant == null
				or not is_instance_valid(plant)
				or plant.is_dead
				or plant.is_queued_for_deletion()
			):
				continue
			var instance_id := plant.get_instance_id()
			if seen_instance_ids.has(instance_id):
				continue
			seen_instance_ids[instance_id] = true
			candidates.append(plant)
	return candidates


func _invalidate_nearest_plant_candidate_cache() -> void:
	_nearest_plant_candidate_cache.clear()


func get_plant_by_net_id(net_id: int) -> PlantDefense:
	return plants_by_net_id.get(net_id) as PlantDefense


func remove_plant_by_net_id(net_id: int) -> bool:
	var plant := get_plant_by_net_id(net_id)
	if plant == null or not is_instance_valid(plant):
		plants_by_net_id.erase(net_id)
		return false
	_release_plant_footprint(plant)
	plant.queue_free()
	return true


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


func _is_ready_for_placement(placement_player: Player) -> bool:
	return (
		ground_tile_map != null
		and ground_tile_map.tile_set != null
		and is_instance_valid(placement_player)
		and is_instance_valid(plant_container)
	)


func _get_player_cell(placement_player: Player) -> Vector2i:
	return ground_tile_map.local_to_map(
		ground_tile_map.to_local(placement_player.global_position)
	)


func _get_candidate_anchor_area(
	config: PlantDefenseConfig,
	player_cell: Vector2i
) -> Rect2i:
	var placement_anchor_size := (
		placement_area.size - config.footprint_size + Vector2i.ONE
	)
	if placement_anchor_size.x <= 0 or placement_anchor_size.y <= 0:
		return Rect2i()

	var placement_anchor_area := Rect2i(placement_area.position, placement_anchor_size)
	var radius := maxi(max_placement_manhattan_distance, 0)
	var footprint_extension := config.footprint_size - Vector2i.ONE
	var nearby_anchor_area := Rect2i(
		player_cell - Vector2i(radius, radius) - footprint_extension,
		Vector2i(radius * 2 + 1, radius * 2 + 1) + footprint_extension
	)
	return placement_anchor_area.intersection(nearby_anchor_area)


func _get_footprint_manhattan_distance(
	top_left_cell: Vector2i,
	footprint_size: Vector2i,
	player_cell: Vector2i
) -> int:
	var bottom_right_cell := top_left_cell + footprint_size - Vector2i.ONE
	var x_distance := 0
	if player_cell.x < top_left_cell.x:
		x_distance = top_left_cell.x - player_cell.x
	elif player_cell.x > bottom_right_cell.x:
		x_distance = player_cell.x - bottom_right_cell.x

	var y_distance := 0
	if player_cell.y < top_left_cell.y:
		y_distance = top_left_cell.y - player_cell.y
	elif player_cell.y > bottom_right_cell.y:
		y_distance = player_cell.y - bottom_right_cell.y
	return x_distance + y_distance


func _is_floor_cell_available(cell: Vector2i) -> bool:
	var tile_data := ground_tile_map.get_cell_tile_data(cell)
	if tile_data != null and tile_data.get_collision_polygons_count(0) > 0:
		return false
	if terrain_map == null:
		return tile_data != null
	var world_cell_center := ground_tile_map.to_global(ground_tile_map.map_to_local(cell))
	return terrain_map.is_world_position_plantable(world_cell_center)


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
	_invalidate_nearest_plant_candidate_cache()
	occupancy_changed.emit()


func _release_plant_footprint(plant: PlantDefense) -> void:
	if plant == null or not plant_footprints.has(plant):
		return

	var cells: Array = plant_footprints[plant]
	plant_footprints.erase(plant)
	var net_id := int(plant.get_meta(&"net_id", 0)) if is_instance_valid(plant) else 0
	if net_id > 0 and plants_by_net_id.get(net_id) == plant:
		plants_by_net_id.erase(net_id)
	for cell_variant in cells:
		var cell: Vector2i = cell_variant
		if occupied_cells.get(cell) == plant:
			occupied_cells.erase(cell)
	_invalidate_nearest_plant_candidate_cache()
	occupancy_changed.emit()
	plant_removed.emit(plant)


func _on_plant_died(plant: PlantDefense) -> void:
	_release_plant_footprint(plant)


func _on_plant_tree_exiting(plant: PlantDefense) -> void:
	_release_plant_footprint(plant)
