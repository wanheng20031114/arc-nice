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

static var _ring_offsets_cache: Array = []

@onready var growth_overlay: MultiMeshInstance2D = $GrowthOverlay

var terrain_map: DualGridTilemap = null
var frozen_bounds := Rect2i()
var authoritative := true

var _baseline_raw_terrain: Dictionary = {}
var _sources: Dictionary = {}
var _active_source_ids: Dictionary = {}
var _generated_cells: Dictionary = {}
var _pending_restore_cells: Dictionary[Vector2i, int] = {}
var _tick_accumulator := 0.0
var _overlay_dirty := false
var _overlay_cells: Array[Vector2i] = []
var _overlay_progress_by_cell: Dictionary = {}
var _overlay_flush_count := 0
var _overlay_layout_rebuild_count := 0
var _overlay_transform_write_count := 0
var _overlay_custom_data_write_count := 0
var _last_advance_source_count := 0
var _last_overlay_source_count := 0


func _ready() -> void:
	_ensure_ring_offsets_cache()
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
	if (
		not _sources.is_empty()
		or not _generated_cells.is_empty()
		or not _pending_restore_cells.is_empty()
	):
		push_error("VegetationSpreadSystem cannot be reconfigured while sources are active.")
		return false

	terrain_map = new_terrain_map
	frozen_bounds = new_frozen_bounds
	authoritative = new_authoritative
	_baseline_raw_terrain.clear()
	_active_source_ids.clear()
	for y in range(frozen_bounds.position.y, frozen_bounds.end.y):
		for x in range(frozen_bounds.position.x, frozen_bounds.end.x):
			var cell := Vector2i(x, y)
			_baseline_raw_terrain[cell] = terrain_map.get_terrain_type(cell)
	_tick_accumulator = 0.0
	_clear_overlay()
	_refresh_process_enabled()
	return true


func set_authoritative(value: bool) -> void:
	if authoritative == value:
		return
	authoritative = value
	if authoritative:
		_restore_pending_cells()
		_resolve_due_sources(_get_sorted_source_ids(_sources))
	_mark_overlay_dirty()


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
	_update_source_active_state(source_id)
	_resolve_due_sources([source_id])
	_mark_overlay_dirty()
	return true


func cancel_source(source_id: int) -> bool:
	if not _sources.has(source_id):
		return false

	var source: Dictionary = _sources[source_id]
	_sources.erase(source_id)
	_active_source_ids.erase(source_id)
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
		if authoritative:
			_generated_cells.erase(cell)
			terrain_map.set_tile(cell, original_raw_terrain)
			terrain_changes[cell] = original_raw_terrain
		else:
			_generated_cells.erase(cell)
			_pending_restore_cells[cell] = original_raw_terrain

	_emit_terrain_changes(terrain_changes)
	_mark_overlay_dirty()
	return true


func advance_time(delta_seconds: float) -> void:
	if terrain_map == null or delta_seconds < 0.0:
		return
	_last_advance_source_count = 0
	if delta_seconds > 0.0:
		var active_source_ids := _get_sorted_source_ids(_active_source_ids)
		_last_advance_source_count = active_source_ids.size()
		for source_id in active_source_ids:
			if not _sources.has(source_id):
				continue
			var source: Dictionary = _sources[source_id]
			source["elapsed"] = minf(
				float(source["elapsed"]) + delta_seconds,
				TOTAL_SPREAD_SECONDS
			)
			_sources[source_id] = source
		_resolve_due_sources(active_source_ids)
		for source_id in active_source_ids:
			_update_source_active_state(source_id)
	_mark_overlay_dirty()


func has_source(source_id: int) -> bool:
	return _sources.has(source_id)


func get_source_count() -> int:
	return _sources.size()


func get_active_source_count() -> int:
	return _active_source_ids.size()


func get_last_advance_source_count() -> int:
	return _last_advance_source_count


func get_last_overlay_source_count() -> int:
	return _last_overlay_source_count


func get_overlay_update_stats() -> Dictionary:
	return {
		"flush_count": _overlay_flush_count,
		"layout_rebuild_count": _overlay_layout_rebuild_count,
		"transform_write_count": _overlay_transform_write_count,
		"custom_data_write_count": _overlay_custom_data_write_count,
	}


func reset_overlay_update_stats() -> void:
	_overlay_flush_count = 0
	_overlay_layout_rebuild_count = 0
	_overlay_transform_write_count = 0
	_overlay_custom_data_write_count = 0


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


static func _ensure_ring_offsets_cache() -> void:
	if _ring_offsets_cache.size() == SPREAD_RADIUS + 1:
		return
	_ring_offsets_cache.clear()
	_ring_offsets_cache.resize(SPREAD_RADIUS + 1)
	for ring in range(SPREAD_RADIUS + 1):
		var empty_ring: Array[Vector2i] = []
		_ring_offsets_cache[ring] = empty_ring
	for y in range(-SPREAD_RADIUS, SPREAD_RADIUS + 1):
		for x in range(-SPREAD_RADIUS, SPREAD_RADIUS + 1):
			var offset := Vector2i(x, y)
			var ring := _ring_for_offset(offset)
			if ring > 0:
				var offsets: Array[Vector2i] = _ring_offsets_cache[ring]
				offsets.append(offset)
	for ring in range(1, SPREAD_RADIUS + 1):
		var offsets: Array[Vector2i] = _ring_offsets_cache[ring]
		offsets.sort_custom(_sort_cells)


static func get_ring_offsets(ring: int) -> Array[Vector2i]:
	_ensure_ring_offsets_cache()
	if ring < 1 or ring > SPREAD_RADIUS:
		var empty_offsets: Array[Vector2i] = []
		return empty_offsets
	return _get_cached_ring_offsets(ring).duplicate()


static func _get_cached_ring_offsets(ring: int) -> Array[Vector2i]:
	var offsets: Array[Vector2i] = _ring_offsets_cache[ring]
	return offsets


static func get_revealed_pixel_indices(
	cell: Vector2i,
	progress: float
) -> PackedInt32Array:
	var result := PackedInt32Array()
	var seeds := _cell_visual_seeds(cell)
	var reveal_count := int(floor(clampf(progress, 0.0, 1.0) * MAX_REVEALED_PIXELS + 0.0001))
	for pixel_index in range(256):
		var rank := _pixel_reveal_rank(pixel_index, seeds)
		if rank < reveal_count:
			result.append(pixel_index)
	return result


static func _pixel_reveal_rank(pixel_index: int, seeds: Vector2i) -> int:
	var left := pixel_index & 15
	var right := (pixel_index >> 4) & 15
	for round_index in range(4):
		var key_source := seeds.x if round_index < 2 else seeds.y
		var key_shift := (
			round_index * 4
			if round_index < 2
			else (round_index - 2) * 4
		)
		var round_key := (key_source >> key_shift) & 15
		var round_value := posmod(
			right * right * 5
			+ right * (round_key * 2 + 1)
			+ round_key * 7
			+ round_index * 3,
			16
		)
		var next_left := right
		right = posmod(left + round_value, 16)
		left = next_left
	return right * 16 + left


func _process(delta: float) -> void:
	if not _active_source_ids.is_empty():
		_tick_accumulator += delta
		if _tick_accumulator >= UPDATE_INTERVAL_SECONDS:
			var elapsed_step := _tick_accumulator
			_tick_accumulator = 0.0
			advance_time(elapsed_step)
	_flush_overlay_if_dirty()
	_refresh_process_enabled()


func _build_source(origin_cell: Vector2i, initial_elapsed_seconds: float) -> Dictionary:
	_ensure_ring_offsets_cache()
	var rings: Array = []
	rings.resize(SPREAD_RADIUS + 1)
	for ring in range(SPREAD_RADIUS + 1):
		var empty_ring: Array[Vector2i] = []
		rings[ring] = empty_ring
	for ring in range(1, SPREAD_RADIUS + 1):
		var ring_cells: Array[Vector2i] = []
		for offset in _get_cached_ring_offsets(ring):
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
		"next_ring": 1,
		"resolved": {},
		"owned": {},
	}


func _update_source_active_state(source_id: int) -> void:
	if not _sources.has(source_id):
		_active_source_ids.erase(source_id)
		return
	var source: Dictionary = _sources[source_id]
	if float(source.get("elapsed", 0.0)) < TOTAL_SPREAD_SECONDS:
		_active_source_ids[source_id] = true
	else:
		_active_source_ids.erase(source_id)


static func _get_sorted_source_ids(source_set: Dictionary) -> Array[int]:
	var source_ids: Array[int] = []
	for source_id_variant in source_set:
		source_ids.append(int(source_id_variant))
	source_ids.sort()
	return source_ids


func _set_source_elapsed_forward(source_id: int, elapsed_seconds: float) -> bool:
	var source: Dictionary = _sources[source_id]
	var current_elapsed := float(source["elapsed"])
	var new_elapsed := clampf(elapsed_seconds, 0.0, TOTAL_SPREAD_SECONDS)
	if new_elapsed <= current_elapsed:
		_mark_overlay_dirty()
		return true
	source["elapsed"] = new_elapsed
	_sources[source_id] = source
	_resolve_due_sources([source_id])
	_update_source_active_state(source_id)
	_mark_overlay_dirty()
	return true


func _resolve_due_sources(source_ids: Array[int]) -> void:
	if not authoritative:
		return
	var terrain_changes: Dictionary = {}
	for source_id in source_ids:
		if not _sources.has(source_id):
			continue
		var source: Dictionary = _sources[source_id]
		var resolved: Dictionary = source["resolved"]
		var owned: Dictionary = source["owned"]
		var rings: Array = source["rings"]
		var elapsed := float(source["elapsed"])
		var next_ring := clampi(
			int(source.get("next_ring", 1)),
			1,
			SPREAD_RADIUS + 1
		)

		# A ring can change terrain only once, exactly at its authored deadline.
		# Keep the next unresolved ring as a cursor instead of rescanning all 88
		# cells for every source at 10 Hz.
		while (
			next_ring <= SPREAD_RADIUS
			and elapsed >= float(next_ring) * SECONDS_PER_RING
		):
			var ring := next_ring
			var ring_cells: Array[Vector2i] = rings[ring]
			for cell in ring_cells:
				if resolved.has(cell):
					continue
				if _generated_cells.has(cell):
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

				_generated_cells[cell] = {
					"original_raw_terrain": raw_terrain,
					"owners": {source_id: true},
				}
				resolved[cell] = true
				owned[cell] = true
				terrain_map.set_tile(cell, DualGridTilemap.TerrainType.GRASS)
				terrain_changes[cell] = DualGridTilemap.TerrainType.GRASS
			next_ring += 1

		source["next_ring"] = next_ring
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
	_last_overlay_source_count = 0
	if terrain_map == null:
		return overlay_progress
	var source_set := _active_source_ids if authoritative else _sources
	_last_overlay_source_count = source_set.size()
	for source_id_variant in source_set:
		var source: Dictionary = _sources[int(source_id_variant)]
		if authoritative:
			var active_ring := int(source.get("next_ring", 1))
			if active_ring <= SPREAD_RADIUS:
				_collect_source_ring_overlay_progress(
					source,
					active_ring,
					overlay_progress
				)
			continue
		for ring in range(1, SPREAD_RADIUS + 1):
			_collect_source_ring_overlay_progress(source, ring, overlay_progress)
	return overlay_progress


func _restore_pending_cells() -> void:
	if _pending_restore_cells.is_empty():
		return
	var terrain_changes: Dictionary = {}
	for cell in _pending_restore_cells:
		var original_raw_terrain := int(_pending_restore_cells[cell])
		terrain_map.set_tile(cell, original_raw_terrain)
		terrain_changes[cell] = original_raw_terrain
	_pending_restore_cells.clear()
	_emit_terrain_changes(terrain_changes)


func _collect_source_ring_overlay_progress(
	source: Dictionary,
	ring: int,
	overlay_progress: Dictionary
) -> void:
	var elapsed := float(source["elapsed"])
	var ring_start := float(ring - 1) * SECONDS_PER_RING
	var progress := clampf((elapsed - ring_start) / SECONDS_PER_RING, 0.0, 1.0)
	if progress <= 0.0:
		return
	var resolved: Dictionary = source["resolved"]
	var rings: Array = source["rings"]
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


func _refresh_process_enabled() -> void:
	if _active_source_ids.is_empty():
		_tick_accumulator = 0.0
	set_process(terrain_map != null and (not _active_source_ids.is_empty() or _overlay_dirty))


func _mark_overlay_dirty() -> void:
	_overlay_dirty = true
	_refresh_process_enabled()


func _flush_overlay_if_dirty() -> void:
	if not _overlay_dirty:
		return
	_overlay_dirty = false
	_overlay_flush_count += 1
	if growth_overlay == null or growth_overlay.multimesh == null:
		return
	var overlay_progress := _collect_overlay_progress()
	var layout_changed := overlay_progress.size() != _overlay_cells.size()
	if not layout_changed:
		for existing_cell in _overlay_cells:
			if not overlay_progress.has(existing_cell):
				layout_changed = true
				break
	var cells: Array[Vector2i] = _overlay_cells
	if layout_changed:
		cells = []
		for cell_variant in overlay_progress:
			var cell: Vector2i = cell_variant
			cells.append(cell)
		cells.sort_custom(_sort_cells)
	var multimesh := growth_overlay.multimesh
	if layout_changed:
		_overlay_layout_rebuild_count += 1
		_overlay_cells = cells
		multimesh.instance_count = cells.size()
	for index in range(cells.size()):
		var cell := cells[index]
		if layout_changed:
			var cell_global_position := terrain_map.world_map_layer.to_global(
				terrain_map.world_map_layer.map_to_local(cell)
			)
			var cell_local_position := growth_overlay.to_local(cell_global_position)
			multimesh.set_instance_transform_2d(
				index,
				Transform2D(0.0, cell_local_position)
			)
			_overlay_transform_write_count += 1
		var progress := float(overlay_progress[cell])
		if (
			not layout_changed
			and is_equal_approx(
				progress,
				float(_overlay_progress_by_cell.get(cell, -1.0))
			)
		):
			continue
		var seeds := _cell_visual_seeds(cell)
		multimesh.set_instance_custom_data(
			index,
			Color(
				progress,
				(float(seeds.x) + 0.5) / 256.0,
				(float(seeds.y) + 0.5) / 128.0,
				1.0
			)
		)
		_overlay_custom_data_write_count += 1
	_overlay_progress_by_cell = overlay_progress


func _clear_overlay() -> void:
	if growth_overlay != null and growth_overlay.multimesh != null:
		growth_overlay.multimesh.instance_count = 0
	_overlay_dirty = false
	_overlay_cells.clear()
	_overlay_progress_by_cell.clear()


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
