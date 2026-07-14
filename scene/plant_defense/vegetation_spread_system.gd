extends Node2D
class_name VegetationSpreadSystem

signal authoritative_terrain_changed(
	cell_xy: PackedInt32Array,
	terrain_types: PackedInt32Array
)

const SPREAD_RADIUS := 5
## Fill the eight nearest cells just outside the strict radius-five disc so the
## four cardinal caps are three cells wide instead of ending in a single-tile
## spike. This keeps the five-ring schedule while only expanding the last ring.
const OUTER_RING_RADIUS_SQUARED := SPREAD_RADIUS * SPREAD_RADIUS + 1
const SECONDS_PER_RING := 10.0
const TOTAL_SPREAD_SECONDS := SPREAD_RADIUS * SECONDS_PER_RING
const MAX_REVEALED_PIXELS := 48
const UPDATE_INTERVAL_SECONDS := 0.1
const RUNTIME_STATE_SCHEMA := 1

@onready var growth_overlay: MultiMeshInstance2D = $GrowthOverlay

var terrain_map: DualGridTilemap = null
var frozen_bounds := Rect2i()
var authoritative := true

var _baseline_raw_terrain: Dictionary = {}
var _sources: Dictionary = {}
var _generated_cells: Dictionary = {}
var _tick_accumulator := 0.0


func _ready() -> void:
	_clear_overlay()
	set_process(false)


func setup(
	new_terrain_map: DualGridTilemap,
	new_frozen_bounds: Rect2i,
	new_authoritative: bool = true
) -> bool:
	if new_terrain_map == null or new_terrain_map.world_map_layer == null:
		push_error("VegetationSpreadSystem requires a terrain map with a WorldLayer.")
		return false
	if new_frozen_bounds.size.x <= 0 or new_frozen_bounds.size.y <= 0:
		push_error("VegetationSpreadSystem requires non-empty frozen bounds.")
		return false
	if not _sources.is_empty() or not _generated_cells.is_empty():
		push_error("VegetationSpreadSystem cannot be reconfigured while sources are active.")
		return false

	terrain_map = new_terrain_map
	frozen_bounds = new_frozen_bounds
	authoritative = new_authoritative
	_baseline_raw_terrain.clear()
	for y in range(frozen_bounds.position.y, frozen_bounds.end.y):
		for x in range(frozen_bounds.position.x, frozen_bounds.end.x):
			var cell := Vector2i(x, y)
			_baseline_raw_terrain[cell] = terrain_map.get_terrain_type(cell)
	_tick_accumulator = 0.0
	_clear_overlay()
	set_process(true)
	return true


func set_authoritative(value: bool) -> void:
	authoritative = value


func is_configured() -> bool:
	return terrain_map != null and frozen_bounds.has_area()


func register_source(
	source_id: int,
	origin_cell: Vector2i,
	initial_elapsed_seconds: float = 0.0
) -> bool:
	if terrain_map == null:
		push_error("VegetationSpreadSystem must be set up before registering a source.")
		return false
	if source_id <= 0:
		push_error("VegetationSpreadSystem source_id must be positive.")
		return false
	if not frozen_bounds.has_point(origin_cell):
		push_error("VegetationSpreadSystem source origin is outside frozen bounds: %s" % origin_cell)
		return false
	if _sources.has(source_id):
		var existing: Dictionary = _sources[source_id]
		if existing["origin"] != origin_cell:
			push_error("VegetationSpreadSystem cannot move an existing source.")
			return false
		return _set_source_elapsed_forward(source_id, initial_elapsed_seconds)

	var source := _build_source(origin_cell, initial_elapsed_seconds)
	_sources[source_id] = source
	_resolve_due_sources()
	_rebuild_overlay()
	return true


func cancel_source(source_id: int) -> bool:
	if not _sources.has(source_id):
		return false

	var source: Dictionary = _sources[source_id]
	_sources.erase(source_id)
	var terrain_changes: Dictionary = {}
	var owned_cells: Dictionary = source["owned"]
	for cell_variant in owned_cells:
		var cell: Vector2i = cell_variant
		if not _generated_cells.has(cell):
			continue
		var generated: Dictionary = _generated_cells[cell]
		var owners: Dictionary = generated["owners"]
		owners.erase(source_id)
		if not owners.is_empty():
			generated["owners"] = owners
			_generated_cells[cell] = generated
			continue

		var original_raw_terrain := int(generated["original_raw_terrain"])
		_generated_cells.erase(cell)
		terrain_map.set_tile(cell, original_raw_terrain)
		terrain_changes[cell] = original_raw_terrain

	_emit_terrain_changes(terrain_changes)
	_rebuild_overlay()
	return true


func advance_time(delta_seconds: float) -> void:
	if terrain_map == null or delta_seconds < 0.0:
		return
	if delta_seconds > 0.0:
		for source_id_variant in _sources:
			var source_id := int(source_id_variant)
			var source: Dictionary = _sources[source_id]
			source["elapsed"] = minf(
				float(source["elapsed"]) + delta_seconds,
				TOTAL_SPREAD_SECONDS
			)
			_sources[source_id] = source
	_resolve_due_sources()
	_rebuild_overlay()


func has_source(source_id: int) -> bool:
	return _sources.has(source_id)


func get_source_count() -> int:
	return _sources.size()


func get_source_origin(source_id: int) -> Vector2i:
	if not _sources.has(source_id):
		return Vector2i.MAX
	var origin: Vector2i = _sources[source_id]["origin"]
	return origin


func get_source_elapsed_seconds(source_id: int) -> float:
	if not _sources.has(source_id):
		return 0.0
	return float(_sources[source_id]["elapsed"])


func export_source_runtime_state(source_id: int) -> Dictionary:
	if not _sources.has(source_id):
		return {}
	return {
		"schema": RUNTIME_STATE_SCHEMA,
		"spread_elapsed_seconds": get_source_elapsed_seconds(source_id),
	}


func apply_source_runtime_state(
	source_id: int,
	origin_cell: Vector2i,
	state: Dictionary,
	mapped_sample_time_seconds: float = -1.0
) -> bool:
	if int(state.get("schema", 0)) != RUNTIME_STATE_SCHEMA:
		return false
	var elapsed_seconds := float(state.get("spread_elapsed_seconds", -1.0))
	if elapsed_seconds < 0.0:
		return false
	if mapped_sample_time_seconds >= 0.0:
		var local_now_seconds := float(Time.get_ticks_msec()) * 0.001
		elapsed_seconds += maxf(local_now_seconds - mapped_sample_time_seconds, 0.0)
	if not _sources.has(source_id):
		return register_source(source_id, origin_cell, elapsed_seconds)
	var source: Dictionary = _sources[source_id]
	if source["origin"] != origin_cell:
		return false
	return _set_source_elapsed_forward(source_id, elapsed_seconds)


func get_overlay_cell_count() -> int:
	if growth_overlay == null or growth_overlay.multimesh == null:
		return 0
	return growth_overlay.multimesh.instance_count


func get_overlay_progress(cell: Vector2i) -> float:
	return float(_collect_overlay_progress().get(cell, 0.0))


static func get_ring_offsets(ring: int) -> Array[Vector2i]:
	var offsets: Array[Vector2i] = []
	if ring < 1 or ring > SPREAD_RADIUS:
		return offsets
	for y in range(-SPREAD_RADIUS, SPREAD_RADIUS + 1):
		for x in range(-SPREAD_RADIUS, SPREAD_RADIUS + 1):
			var offset := Vector2i(x, y)
			if _ring_for_offset(offset) == ring:
				offsets.append(offset)
	offsets.sort_custom(_sort_cells)
	return offsets


static func get_revealed_pixel_indices(
	cell: Vector2i,
	progress: float
) -> PackedInt32Array:
	var result := PackedInt32Array()
	var seeds := _cell_visual_seeds(cell)
	var offset := int(seeds.x)
	var odd_multiplier := int(seeds.y) * 2 + 1
	var reveal_count := int(floor(clampf(progress, 0.0, 1.0) * MAX_REVEALED_PIXELS + 0.0001))
	for pixel_index in range(256):
		var rank := posmod(pixel_index * odd_multiplier + offset, 256)
		if rank < reveal_count:
			result.append(pixel_index)
	return result


func _process(delta: float) -> void:
	if _sources.is_empty():
		return
	_tick_accumulator += delta
	if _tick_accumulator < UPDATE_INTERVAL_SECONDS:
		return
	var elapsed_step := _tick_accumulator
	_tick_accumulator = 0.0
	advance_time(elapsed_step)


func _build_source(origin_cell: Vector2i, initial_elapsed_seconds: float) -> Dictionary:
	var rings: Array = []
	rings.resize(SPREAD_RADIUS + 1)
	for ring in range(SPREAD_RADIUS + 1):
		var empty_ring: Array[Vector2i] = []
		rings[ring] = empty_ring
	for ring in range(1, SPREAD_RADIUS + 1):
		var ring_cells: Array[Vector2i] = []
		for offset in get_ring_offsets(ring):
			var cell := origin_cell + offset
			if not frozen_bounds.has_point(cell):
				continue
			var baseline_raw := int(_baseline_raw_terrain.get(
				cell,
				DualGridTilemap.TerrainType.EMPTY
			))
			if (
				baseline_raw == DualGridTilemap.TerrainType.EMPTY
				or baseline_raw == DualGridTilemap.TerrainType.DIRT
			):
				ring_cells.append(cell)
		rings[ring] = ring_cells
	return {
		"origin": origin_cell,
		"elapsed": clampf(initial_elapsed_seconds, 0.0, TOTAL_SPREAD_SECONDS),
		"rings": rings,
		"resolved": {},
		"owned": {},
	}


func _set_source_elapsed_forward(source_id: int, elapsed_seconds: float) -> bool:
	var source: Dictionary = _sources[source_id]
	var current_elapsed := float(source["elapsed"])
	var new_elapsed := clampf(elapsed_seconds, 0.0, TOTAL_SPREAD_SECONDS)
	if new_elapsed <= current_elapsed:
		return true
	source["elapsed"] = new_elapsed
	_sources[source_id] = source
	_resolve_due_sources()
	_rebuild_overlay()
	return true


func _resolve_due_sources() -> void:
	if not authoritative:
		return
	var terrain_changes: Dictionary = {}
	var source_ids := _sources.keys()
	source_ids.sort()
	for source_id_variant in source_ids:
		var source_id := int(source_id_variant)
		var source: Dictionary = _sources[source_id]
		var resolved: Dictionary = source["resolved"]
		var owned: Dictionary = source["owned"]
		var rings: Array = source["rings"]

		for ring in range(1, SPREAD_RADIUS + 1):
			var ring_cells: Array[Vector2i] = rings[ring]
			for cell in ring_cells:
				if resolved.has(cell):
					continue
				if _generated_cells.has(cell):
					if float(source["elapsed"]) < float(ring) * SECONDS_PER_RING:
						continue
					_add_generated_owner(cell, source_id)
					resolved[cell] = true
					owned[cell] = true
					continue

				var raw_terrain := terrain_map.get_terrain_type(cell)
				if (
					raw_terrain != DualGridTilemap.TerrainType.EMPTY
					and raw_terrain != DualGridTilemap.TerrainType.DIRT
				):
					resolved[cell] = true
					continue
				if float(source["elapsed"]) < float(ring) * SECONDS_PER_RING:
					continue

				_generated_cells[cell] = {
					"original_raw_terrain": raw_terrain,
					"owners": {source_id: true},
				}
				resolved[cell] = true
				owned[cell] = true
				terrain_map.set_tile(cell, DualGridTilemap.TerrainType.GRASS)
				terrain_changes[cell] = DualGridTilemap.TerrainType.GRASS

		source["resolved"] = resolved
		source["owned"] = owned
		_sources[source_id] = source
	_emit_terrain_changes(terrain_changes)


func _add_generated_owner(cell: Vector2i, source_id: int) -> void:
	var generated: Dictionary = _generated_cells[cell]
	var owners: Dictionary = generated["owners"]
	owners[source_id] = true
	generated["owners"] = owners
	_generated_cells[cell] = generated


func _collect_overlay_progress() -> Dictionary:
	var overlay_progress: Dictionary = {}
	if terrain_map == null:
		return overlay_progress
	for source_id_variant in _sources:
		var source: Dictionary = _sources[int(source_id_variant)]
		var resolved: Dictionary = source["resolved"]
		var elapsed := float(source["elapsed"])
		var rings: Array = source["rings"]
		for ring in range(1, SPREAD_RADIUS + 1):
			var ring_start := float(ring - 1) * SECONDS_PER_RING
			var progress := clampf((elapsed - ring_start) / SECONDS_PER_RING, 0.0, 1.0)
			if progress <= 0.0:
				continue
			var ring_cells: Array[Vector2i] = rings[ring]
			for cell in ring_cells:
				if resolved.has(cell):
					continue
				var raw_terrain := terrain_map.get_terrain_type(cell)
				if (
					raw_terrain != DualGridTilemap.TerrainType.EMPTY
					and raw_terrain != DualGridTilemap.TerrainType.DIRT
				):
					continue
				overlay_progress[cell] = maxf(
					float(overlay_progress.get(cell, 0.0)),
					progress
				)
	return overlay_progress


func _rebuild_overlay() -> void:
	if growth_overlay == null or growth_overlay.multimesh == null:
		return
	var overlay_progress := _collect_overlay_progress()
	var cells: Array[Vector2i] = []
	for cell_variant in overlay_progress:
		var cell: Vector2i = cell_variant
		cells.append(cell)
	cells.sort_custom(_sort_cells)

	var multimesh := growth_overlay.multimesh
	multimesh.instance_count = cells.size()
	for index in range(cells.size()):
		var cell := cells[index]
		var cell_global_position := terrain_map.world_map_layer.to_global(
			terrain_map.world_map_layer.map_to_local(cell)
		)
		var cell_local_position := growth_overlay.to_local(cell_global_position)
		multimesh.set_instance_transform_2d(
			index,
			Transform2D(0.0, cell_local_position)
		)
		var seeds := _cell_visual_seeds(cell)
		multimesh.set_instance_custom_data(
			index,
			Color(
				float(overlay_progress[cell]),
				(float(seeds.x) + 0.5) / 256.0,
				(float(seeds.y) + 0.5) / 128.0,
				1.0
			)
		)


func _clear_overlay() -> void:
	if growth_overlay != null and growth_overlay.multimesh != null:
		growth_overlay.multimesh.instance_count = 0


func _emit_terrain_changes(changes: Dictionary) -> void:
	if changes.is_empty():
		return
	var cells: Array[Vector2i] = []
	for cell_variant in changes:
		var cell: Vector2i = cell_variant
		cells.append(cell)
	cells.sort_custom(_sort_cells)
	var cell_xy := PackedInt32Array()
	var terrain_types := PackedInt32Array()
	for cell in cells:
		cell_xy.append(cell.x)
		cell_xy.append(cell.y)
		terrain_types.append(int(changes[cell]))
	authoritative_terrain_changed.emit(cell_xy, terrain_types)


static func _ring_for_offset(offset: Vector2i) -> int:
	var distance_squared := offset.length_squared()
	if distance_squared <= 0 or distance_squared > OUTER_RING_RADIUS_SQUARED:
		return 0
	for ring in range(1, SPREAD_RADIUS + 1):
		var ring_radius_squared := ring * ring
		if ring == SPREAD_RADIUS:
			ring_radius_squared = OUTER_RING_RADIUS_SQUARED
		if distance_squared <= ring_radius_squared:
			return ring
	return 0


static func _cell_visual_seeds(cell: Vector2i) -> Vector2i:
	var hash_value: int = (
		(cell.x * 73856093)
		^ (cell.y * 19349663)
		^ 0x5F356495
	) & 0x7FFFFFFF
	hash_value = ((hash_value ^ (hash_value >> 13)) * 1274126177) & 0x7FFFFFFF
	hash_value = (hash_value ^ (hash_value >> 16)) & 0x7FFFFFFF
	return Vector2i(hash_value & 255, (hash_value >> 8) & 127)


static func _sort_cells(a: Vector2i, b: Vector2i) -> bool:
	if a.y == b.y:
		return a.x < b.x
	return a.y < b.y
