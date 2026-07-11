@tool
extends Node2D
class_name DualGridTilemap

const PLACEHOLDER_SOURCE_ID := 0
const EMPTY_ATLAS_COORDS := Vector2i(-1, -1)
const GRASS_DETAIL_HASH_SALT := 101
const DIRT_DETAIL_HASH_SALT := 211
const DETAIL_GATE_SALT_OFFSET := 307
const DETAIL_VARIANT_SALT_OFFSET := 613
const NEIGHBOURS := [
	Vector2i(0, 0),
	Vector2i(1, 0),
	Vector2i(0, 1),
	Vector2i(1, 1),
]

const MASK_TO_ATLAS_COORDS := {
	15: Vector2i(2, 1), # All corners.
	8: Vector2i(1, 3), # Outer bottom-right corner.
	4: Vector2i(0, 0), # Outer bottom-left corner.
	2: Vector2i(0, 2), # Outer top-right corner.
	1: Vector2i(3, 3), # Outer top-left corner.
	10: Vector2i(1, 0), # Right edge.
	5: Vector2i(3, 2), # Left edge.
	12: Vector2i(3, 0), # Bottom edge.
	3: Vector2i(1, 2), # Top edge.
	14: Vector2i(1, 1), # Inner bottom-right corner.
	13: Vector2i(2, 0), # Inner bottom-left corner.
	11: Vector2i(2, 2), # Inner top-right corner.
	7: Vector2i(3, 1), # Inner top-left corner.
	6: Vector2i(2, 3), # Bottom-left and top-right corners.
	9: Vector2i(0, 1), # Top-left and bottom-right corners.
	0: EMPTY_ATLAS_COORDS,
}

# Animated water tiles are stored as a horizontal strip per dual-grid mask.
# Grass, dirt, and metal retain the original shared 4x4 coordinates.
const WATER_MASK_TO_ATLAS_COORDS := {
	15: Vector2i(0, 0),
	8: Vector2i(0, 1),
	4: Vector2i(0, 2),
	2: Vector2i(0, 3),
	1: Vector2i(0, 4),
	10: Vector2i(0, 5),
	5: Vector2i(0, 6),
	12: Vector2i(0, 7),
	3: Vector2i(0, 8),
	14: Vector2i(0, 9),
	13: Vector2i(0, 10),
	11: Vector2i(0, 11),
	7: Vector2i(0, 12),
	6: Vector2i(0, 13),
	9: Vector2i(0, 14),
}

enum TerrainType {
	EMPTY = -1,
	GRASS = 1,
	DIRT = 2,
	WATER = 3,
	METAL = 4,
}

@export var world_map_layer: TileMapLayer
@export var base_dirt_map_layer: TileMapLayer
@export var grass_display_map_layer: TileMapLayer
@export var dirt_display_map_layer: TileMapLayer
@export var water_display_map_layer: TileMapLayer
@export var metal_display_map_layer: TileMapLayer
@export var terrain_detail_map_layer: TileMapLayer
@export var grass_placeholder_atlas_coords := Vector2i(0, 0)
@export var dirt_placeholder_atlas_coords := Vector2i(1, 0)
@export var water_placeholder_atlas_coords := Vector2i(2, 0)
@export var metal_placeholder_atlas_coords := Vector2i(3, 0)
@export var base_dirt_fill_origin := Vector2i.ZERO
@export var base_dirt_fill_cells := Vector2i.ZERO
@export var base_dirt_source_id := TerrainType.DIRT
@export var base_dirt_atlas_coords := Vector2i(2, 1)
@export_range(0.0, 0.11, 0.01) var grass_flower_density := 0.10
@export_range(0.0, 0.11, 0.01) var dirt_clay_density := 0.07
@export var terrain_detail_seed := 3
@export var grass_detail_source_id := 5
@export var dirt_detail_source_id := 6
@export_range(1, 32, 1) var detail_variant_count := 6

var _base_dirt_generation_key: Array = []


func _ready() -> void:
	refresh_all_tiles()


func _process(_delta: float) -> void:
	if Engine.is_editor_hint():
		refresh_all_tiles()


func refresh_all_tiles() -> void:
	if not _has_required_layers():
		return

	_refresh_base_dirt_layer()
	grass_display_map_layer.clear()
	dirt_display_map_layer.clear()
	water_display_map_layer.clear()
	metal_display_map_layer.clear()
	terrain_detail_map_layer.clear()
	for cell_pos in world_map_layer.get_used_cells():
		_refresh_display_tile(cell_pos, grass_display_map_layer, TerrainType.GRASS)
		_refresh_display_tile(cell_pos, dirt_display_map_layer, TerrainType.DIRT)
		_refresh_display_tile(cell_pos, water_display_map_layer, TerrainType.WATER)
		_refresh_display_tile(cell_pos, metal_display_map_layer, TerrainType.METAL)

	var detail_positions := {}
	for cell_pos in world_map_layer.get_used_cells():
		for neighbour in NEIGHBOURS:
			detail_positions[cell_pos + neighbour] = true
	for display_pos in detail_positions:
		_refresh_detail_tile(display_pos)


func clear_tiles() -> void:
	if not _has_required_layers():
		return
	world_map_layer.clear()
	grass_display_map_layer.clear()
	dirt_display_map_layer.clear()
	water_display_map_layer.clear()
	metal_display_map_layer.clear()
	terrain_detail_map_layer.clear()


func local_to_map(local_position: Vector2) -> Vector2i:
	if world_map_layer == null:
		return Vector2i.ZERO
	return world_map_layer.local_to_map(local_position)


func world_to_map(world_position: Vector2) -> Vector2i:
	if world_map_layer == null:
		return Vector2i.ZERO
	return world_map_layer.local_to_map(world_map_layer.to_local(world_position))


func set_tile_from_world(world_position: Vector2, terrain_type: int) -> void:
	set_tile(world_to_map(world_position), terrain_type)


func set_tile(coords: Vector2i, terrain_type: int) -> void:
	if not _has_required_layers():
		return

	var old_terrain_type := get_terrain_type(coords)
	if terrain_type == TerrainType.EMPTY:
		world_map_layer.erase_cell(coords)
	else:
		world_map_layer.set_cell(coords, PLACEHOLDER_SOURCE_ID, _get_placeholder_atlas_coords(terrain_type))

	if terrain_type != TerrainType.EMPTY:
		_refresh_display_tile(coords, _get_display_layer(terrain_type), terrain_type)

	if old_terrain_type != TerrainType.EMPTY:
		_refresh_display_tile(coords, _get_display_layer(old_terrain_type), old_terrain_type)

	for neighbour in NEIGHBOURS:
		_refresh_detail_tile(coords + neighbour)


func get_terrain_type(cell_pos: Vector2i) -> int:
	if world_map_layer == null:
		return TerrainType.EMPTY
	if world_map_layer.get_cell_source_id(cell_pos) != PLACEHOLDER_SOURCE_ID:
		return TerrainType.EMPTY

	var placeholder_atlas_coords := world_map_layer.get_cell_atlas_coords(cell_pos)
	if placeholder_atlas_coords == grass_placeholder_atlas_coords:
		return TerrainType.GRASS
	if placeholder_atlas_coords == dirt_placeholder_atlas_coords:
		return TerrainType.DIRT
	if placeholder_atlas_coords == water_placeholder_atlas_coords:
		return TerrainType.WATER
	if placeholder_atlas_coords == metal_placeholder_atlas_coords:
		return TerrainType.METAL
	return TerrainType.EMPTY


func _refresh_display_tile(pos: Vector2i, display_layer: TileMapLayer, terrain_type: int) -> void:
	if display_layer == null:
		return

	for neighbour in NEIGHBOURS:
		var display_pos: Vector2i = pos + neighbour
		var atlas_coords := _calculate_display_tile_atlas_coords(display_pos, terrain_type)
		if atlas_coords == EMPTY_ATLAS_COORDS:
			display_layer.erase_cell(display_pos)
		else:
			display_layer.set_cell(display_pos, terrain_type, atlas_coords)


func _refresh_base_dirt_layer() -> void:
	if base_dirt_map_layer == null or base_dirt_fill_cells.x <= 0 or base_dirt_fill_cells.y <= 0:
		return

	var fill_rect := Rect2i(base_dirt_fill_origin, base_dirt_fill_cells)
	var generation_key := [
		base_dirt_map_layer.get_instance_id(),
		base_dirt_fill_origin,
		base_dirt_fill_cells,
		base_dirt_source_id,
		base_dirt_atlas_coords,
	]
	if _base_dirt_generation_key == generation_key and _base_dirt_layer_matches(fill_rect):
		return

	base_dirt_map_layer.clear()
	for y in range(fill_rect.position.y, fill_rect.end.y):
		for x in range(fill_rect.position.x, fill_rect.end.x):
			base_dirt_map_layer.set_cell(Vector2i(x, y), base_dirt_source_id, base_dirt_atlas_coords)
	_base_dirt_generation_key = generation_key


func _base_dirt_layer_matches(fill_rect: Rect2i) -> bool:
	if base_dirt_map_layer.get_used_rect() != fill_rect:
		return false
	for coords in [fill_rect.position, fill_rect.end - Vector2i.ONE]:
		if base_dirt_map_layer.get_cell_source_id(coords) != base_dirt_source_id:
			return false
		if base_dirt_map_layer.get_cell_atlas_coords(coords) != base_dirt_atlas_coords:
			return false
	return true


func _calculate_display_tile_atlas_coords(coords: Vector2i, terrain_type: int) -> Vector2i:
	var mask := _calculate_terrain_mask(coords, terrain_type)
	if mask == 0:
		return EMPTY_ATLAS_COORDS
	if terrain_type == TerrainType.WATER:
		return WATER_MASK_TO_ATLAS_COORDS[mask]
	return MASK_TO_ATLAS_COORDS[mask]


func _calculate_terrain_mask(coords: Vector2i, terrain_type: int) -> int:
	var mask := 0
	if _is_matching_terrain(coords - Vector2i(1, 1), terrain_type):
		mask |= 1
	if _is_matching_terrain(coords - Vector2i(0, 1), terrain_type):
		mask |= 2
	if _is_matching_terrain(coords - Vector2i(1, 0), terrain_type):
		mask |= 4
	if _is_matching_terrain(coords - Vector2i(0, 0), terrain_type):
		mask |= 8
	return mask


func _refresh_detail_tile(display_pos: Vector2i) -> void:
	terrain_detail_map_layer.erase_cell(display_pos)
	if _calculate_terrain_mask(display_pos, TerrainType.GRASS) == 15:
		if _should_place_detail(display_pos, grass_flower_density, GRASS_DETAIL_HASH_SALT):
			var variant := _detail_hash(display_pos, GRASS_DETAIL_HASH_SALT + DETAIL_VARIANT_SALT_OFFSET) % detail_variant_count
			terrain_detail_map_layer.set_cell(display_pos, grass_detail_source_id, Vector2i(variant, 0))
		return
	if _calculate_terrain_mask(display_pos, TerrainType.DIRT) == 15:
		if _should_place_detail(display_pos, dirt_clay_density, DIRT_DETAIL_HASH_SALT):
			var variant := _detail_hash(display_pos, DIRT_DETAIL_HASH_SALT + DETAIL_VARIANT_SALT_OFFSET) % detail_variant_count
			terrain_detail_map_layer.set_cell(display_pos, dirt_detail_source_id, Vector2i(variant, 0))


func _should_place_detail(coords: Vector2i, density: float, salt: int) -> bool:
	if density <= 0.0 or not _is_local_hash_peak(coords, salt):
		return false
	var gate := clampf(density * 9.0, 0.0, 1.0)
	return _detail_hash_unit(coords, salt + DETAIL_GATE_SALT_OFFSET) < gate


func _is_local_hash_peak(coords: Vector2i, salt: int) -> bool:
	var score := _detail_hash(coords, salt)
	for y in range(-1, 2):
		for x in range(-1, 2):
			if x == 0 and y == 0:
				continue
			if _detail_hash(coords + Vector2i(x, y), salt) >= score:
				return false
	return true


func _detail_hash_unit(coords: Vector2i, salt: int) -> float:
	return float(_detail_hash(coords, salt)) / 2147483647.0


func _detail_hash(coords: Vector2i, salt: int) -> int:
	var value: int = (
		(coords.x * 73856093)
		^ (coords.y * 19349663)
		^ (terrain_detail_seed * 83492791)
		^ (salt * 2654435761)
	) & 0xFFFFFFFF
	value = (((value >> 16) ^ value) * 0x45D9F3B) & 0xFFFFFFFF
	value = (((value >> 16) ^ value) * 0x45D9F3B) & 0xFFFFFFFF
	return ((value >> 16) ^ value) & 0x7FFFFFFF


func _is_matching_terrain(coords: Vector2i, terrain_type: int) -> bool:
	if world_map_layer.get_cell_source_id(coords) != PLACEHOLDER_SOURCE_ID:
		return false
	return world_map_layer.get_cell_atlas_coords(coords) == _get_placeholder_atlas_coords(terrain_type)


func _get_placeholder_atlas_coords(terrain_type: int) -> Vector2i:
	match terrain_type:
		TerrainType.GRASS:
			return grass_placeholder_atlas_coords
		TerrainType.DIRT:
			return dirt_placeholder_atlas_coords
		TerrainType.WATER:
			return water_placeholder_atlas_coords
		TerrainType.METAL:
			return metal_placeholder_atlas_coords
		_:
			return EMPTY_ATLAS_COORDS


func _get_display_layer(terrain_type: int) -> TileMapLayer:
	match terrain_type:
		TerrainType.GRASS:
			return grass_display_map_layer
		TerrainType.DIRT:
			return dirt_display_map_layer
		TerrainType.WATER:
			return water_display_map_layer
		TerrainType.METAL:
			return metal_display_map_layer
		_:
			return null


func _has_required_layers() -> bool:
	return (
		world_map_layer != null
		and grass_display_map_layer != null
		and dirt_display_map_layer != null
		and water_display_map_layer != null
		and metal_display_map_layer != null
		and terrain_detail_map_layer != null
	)
