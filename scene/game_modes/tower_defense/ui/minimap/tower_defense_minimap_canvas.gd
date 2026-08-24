extends Control
class_name TowerDefenseMinimapCanvas

signal tile_coordinate_changed(tile_coordinate: Vector2i)

const OVERVIEW_VIEW_MULTIPLIER := 3.0
const RED_GATE_ATLAS_COORDS := Vector2i(0, 0)
const HOME_GATE_ROLE := &"home_gate"

@onready var static_layer: TowerDefenseMinimapStaticLayer = $StaticLayer
@onready var dynamic_layer: TowerDefenseMinimapDynamicLayer = $DynamicLayer

var local_player: Player = null
var map_camera: Camera2D = null
var ground_tile_map_layer: TileMapLayer = null
var dual_grid_terrain: DualGridTilemap = null
var overlay_tile_map_layer: TileMapLayer = null
var players_root: Node = null
var enemy_container: Node2D = null
var boss_container: Node2D = null
var plant_system: PlantSystem = null
var combat_query_facade: CombatQueryFacade = null
var _visible_combat_targets: Array[Node2D] = []
var _visible_plants: Array[PlantDefense] = []

var _sample_camera_phase := true
var _static_rebuild_pending := false
var _has_tile_coordinate := false
var _last_tile_coordinate := Vector2i.ZERO


func setup(
	new_local_player: Player,
	new_map_camera: Camera2D,
	new_ground_tile_map_layer: TileMapLayer,
	new_dual_grid_terrain: DualGridTilemap,
	new_overlay_tile_map_layer: TileMapLayer,
	new_players_root: Node,
	new_enemy_container: Node2D,
	new_boss_container: Node2D,
	new_plant_system: PlantSystem
) -> void:
	_disconnect_topology_signals()
	local_player = new_local_player
	map_camera = new_map_camera
	ground_tile_map_layer = new_ground_tile_map_layer
	dual_grid_terrain = new_dual_grid_terrain
	overlay_tile_map_layer = new_overlay_tile_map_layer
	players_root = new_players_root
	enemy_container = new_enemy_container
	boss_container = new_boss_container
	plant_system = new_plant_system
	var combat_runtime := new_players_root as CombatRuntimeBase
	combat_query_facade = (
		combat_runtime.get_combat_query_facade()
		if combat_runtime != null
		else null
	)
	_has_tile_coordinate = false

	_rebuild_static_topology()
	_connect_topology_signals()
	_sample_camera_and_local_player()
	_sample_world_entities()
	_sample_camera_phase = false


func sample_next_phase() -> void:
	if _sample_camera_phase:
		_sample_camera_and_local_player()
	else:
		_sample_world_entities()
	_sample_camera_phase = not _sample_camera_phase


func get_tile_coordinate() -> Vector2i:
	return _last_tile_coordinate


func _sample_camera_and_local_player() -> void:
	if map_camera == null or ground_tile_map_layer == null:
		return
	if not is_instance_valid(map_camera):
		return

	var viewport_size := map_camera.get_viewport().get_visible_rect().size
	var safe_zoom := Vector2(
		maxf(absf(map_camera.zoom.x), 0.001),
		maxf(absf(map_camera.zoom.y), 0.001)
	)
	var visible_world_size := viewport_size / safe_zoom
	var camera_center := map_camera.get_screen_center_position()
	var overview_world_size := visible_world_size * OVERVIEW_VIEW_MULTIPLIER
	static_layer.set_projection(camera_center, overview_world_size, visible_world_size)
	dynamic_layer.set_projection(camera_center, overview_world_size)

	var local_position := camera_center
	if local_player != null and is_instance_valid(local_player):
		local_position = local_player.global_position
		var tile_coordinate := ground_tile_map_layer.local_to_map(
			ground_tile_map_layer.to_local(local_position)
		)
		if not _has_tile_coordinate or tile_coordinate != _last_tile_coordinate:
			_has_tile_coordinate = true
			_last_tile_coordinate = tile_coordinate
			tile_coordinate_changed.emit(tile_coordinate)
	dynamic_layer.set_local_player_position(local_position)


func _sample_world_entities() -> void:
	var remote_player_positions := PackedVector2Array()
	if players_root != null and is_instance_valid(players_root):
		for child in players_root.get_children():
			var candidate := child as Player
			if candidate == null or candidate == local_player or candidate.is_dead:
				continue
			remote_player_positions.append(candidate.global_position)

	var enemy_positions := PackedVector2Array()
	_visible_combat_targets.clear()
	if combat_query_facade != null:
		combat_query_facade.query_world_aabb_into(
			dynamic_layer.get_overview_world_aabb(),
			_visible_combat_targets,
			null,
			0,
			false,
			false,
			true
		)
	for target in _visible_combat_targets:
		var enemy := target as Enemy
		if enemy == null or enemy.is_dead:
			continue
		var parent := enemy.get_parent()
		if parent != enemy_container and parent != boss_container:
			continue
		enemy_positions.append(enemy.global_position)

	var plant_positions := PackedVector2Array()
	if plant_system != null and is_instance_valid(plant_system):
		plant_system.query_living_plants_in_world_aabb_into(
			dynamic_layer.get_overview_world_aabb(),
			_visible_plants
		)
		for plant in _visible_plants:
			plant_positions.append(plant.global_position)

	dynamic_layer.set_world_entities(
		remote_player_positions,
		enemy_positions,
		plant_positions
	)

func _rebuild_static_topology() -> void:
	_static_rebuild_pending = false
	if (
		ground_tile_map_layer == null
		or ground_tile_map_layer.tile_set == null
		or dual_grid_terrain == null
		or dual_grid_terrain.world_map_layer == null
		or overlay_tile_map_layer == null
	):
		return

	var tile_world_size := _get_world_tile_size(ground_tile_map_layer)
	var wall_positions := PackedVector2Array()
	for cell in ground_tile_map_layer.get_used_cells():
		var tile_data := ground_tile_map_layer.get_cell_tile_data(cell)
		if tile_data == null or tile_data.get_collision_polygons_count(0) <= 0:
			continue
		wall_positions.append(_cell_global_position(ground_tile_map_layer, cell))

	var water_positions := PackedVector2Array()
	var terrain_layer := dual_grid_terrain.world_map_layer
	for cell in terrain_layer.get_used_cells_by_id(
		DualGridTilemap.PLACEHOLDER_SOURCE_ID,
		dual_grid_terrain.water_placeholder_atlas_coords
	):
		water_positions.append(_cell_global_position(terrain_layer, cell))

	var home_gate_positions := PackedVector2Array()
	var enemy_gate_positions := PackedVector2Array()
	for cell in overlay_tile_map_layer.get_used_cells():
		var tile_data := overlay_tile_map_layer.get_cell_tile_data(cell)
		if tile_data != null and tile_data.get_custom_data("overlay_role") == HOME_GATE_ROLE:
			home_gate_positions.append(_cell_global_position(overlay_tile_map_layer, cell))
		elif (
			overlay_tile_map_layer.get_cell_source_id(cell) == 0
			and overlay_tile_map_layer.get_cell_atlas_coords(cell) == RED_GATE_ATLAS_COORDS
		):
			enemy_gate_positions.append(_cell_global_position(overlay_tile_map_layer, cell))

	static_layer.set_topology(
		tile_world_size,
		wall_positions,
		water_positions,
		home_gate_positions,
		enemy_gate_positions
	)
	dynamic_layer.set_tile_world_size(tile_world_size)


func _get_world_tile_size(tile_map_layer: TileMapLayer) -> Vector2:
	var origin := tile_map_layer.to_global(tile_map_layer.map_to_local(Vector2i.ZERO))
	var right := tile_map_layer.to_global(tile_map_layer.map_to_local(Vector2i.RIGHT))
	var down := tile_map_layer.to_global(tile_map_layer.map_to_local(Vector2i.DOWN))
	return Vector2(origin.distance_to(right), origin.distance_to(down))


func _cell_global_position(tile_map_layer: TileMapLayer, cell: Vector2i) -> Vector2:
	return tile_map_layer.to_global(tile_map_layer.map_to_local(cell))


func _connect_topology_signals() -> void:
	if ground_tile_map_layer != null:
		ground_tile_map_layer.changed.connect(_request_static_topology_rebuild)
	if overlay_tile_map_layer != null:
		overlay_tile_map_layer.changed.connect(_request_static_topology_rebuild)
	if dual_grid_terrain != null:
		dual_grid_terrain.terrain_changed.connect(_on_terrain_topology_changed)


func _disconnect_topology_signals() -> void:
	if (
		ground_tile_map_layer != null
		and ground_tile_map_layer.changed.is_connected(_request_static_topology_rebuild)
	):
		ground_tile_map_layer.changed.disconnect(_request_static_topology_rebuild)
	if (
		overlay_tile_map_layer != null
		and overlay_tile_map_layer.changed.is_connected(_request_static_topology_rebuild)
	):
		overlay_tile_map_layer.changed.disconnect(_request_static_topology_rebuild)
	if (
		dual_grid_terrain != null
		and dual_grid_terrain.terrain_changed.is_connected(_on_terrain_topology_changed)
	):
		dual_grid_terrain.terrain_changed.disconnect(_on_terrain_topology_changed)


func _on_terrain_topology_changed(
	_cell: Vector2i,
	previous_terrain: int,
	current_terrain: int
) -> void:
	if not _does_terrain_change_affect_static_topology(previous_terrain, current_terrain):
		return
	_request_static_topology_rebuild()


func _does_terrain_change_affect_static_topology(
	previous_terrain: int,
	current_terrain: int
) -> bool:
	var was_water := previous_terrain == DualGridTilemap.TerrainType.WATER
	var is_water := current_terrain == DualGridTilemap.TerrainType.WATER
	return was_water != is_water


func _request_static_topology_rebuild() -> void:
	if _static_rebuild_pending:
		return
	_static_rebuild_pending = true
	call_deferred("_rebuild_static_topology")
