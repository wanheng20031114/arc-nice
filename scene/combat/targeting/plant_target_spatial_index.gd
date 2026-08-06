extends RefCounted
class_name PlantTargetSpatialIndex

## A lifecycle-driven spatial hash for stationary plant targets.
##
## The caller owns target validity and must explicitly call [method update] after
## changing an anchor. Queries never inspect scene-tree state or target transforms.
## Every registered target has exactly one bucket membership, so registration,
## removal and migration use constant-time dictionary lookups and swap-removal.

const DEFAULT_BUCKET_SIZE: float = 64.0
const MAX_SIGNED_INT: int = 9223372036854775807
const MIN_VECTOR2I_COMPONENT: float = -2147483648.0
const MAX_VECTOR2I_COMPONENT_EXCLUSIVE: float = 2147483648.0

var _bucket_size: float = DEFAULT_BUCKET_SIZE
var _query_metrics_enabled := false
var _plants_by_instance_id: Dictionary[int, Object] = {}
var _anchors_by_instance_id: Dictionary[int, Vector2] = {}
var _bucket_by_instance_id: Dictionary[int, Vector2i] = {}
var _bucket_slot_by_instance_id: Dictionary[int, int] = {}
var _buckets: Dictionary[Vector2i, Array] = {}
var _membership_count := 0

var _registrations_total := 0
var _duplicate_registrations_total := 0
var _updates_total := 0
var _unregistrations_total := 0
var _bucket_migrations_total := 0
var _bucket_swap_removals_total := 0
var _bucket_rebuilds_total := 0
var _rejected_operations_total := 0
var _queries_total := 0

var _last_query_valid := false
var _last_query_mode: StringName = &"none"
var _last_query_normalized_aabb := Rect2()
var _last_query_minimum_bucket := Vector2i.ZERO
var _last_query_maximum_bucket := Vector2i.ZERO
var _last_query_bucket_cells_considered := 0
var _last_query_bucket_cells_pruned_by_radius := 0
var _last_query_bucket_cells_pruned_by_nearest := 0
var _last_query_non_empty_buckets_visited := 0
var _last_query_candidates_visited := 0
var _last_query_results_written := 0


func _init(configured_bucket_size: float = DEFAULT_BUCKET_SIZE) -> void:
	if _is_valid_bucket_size(configured_bucket_size):
		_bucket_size = configured_bucket_size
	else:
		_bucket_size = DEFAULT_BUCKET_SIZE
		_rejected_operations_total = 1


func get_bucket_size() -> float:
	return _bucket_size


## Query instrumentation is opt-in so production chain queries do not pay for
## diagnostic counter resets or per-bucket/per-candidate increments.
func set_query_metrics_enabled(enabled: bool) -> void:
	_query_metrics_enabled = enabled


func is_query_metrics_enabled() -> bool:
	return _query_metrics_enabled


## Changes the bucket size and rebuilds existing memberships when necessary.
## A rejected value leaves the current structure untouched.
func configure_bucket_size(configured_bucket_size: float) -> bool:
	if not _is_valid_bucket_size(configured_bucket_size):
		_rejected_operations_total += 1
		return false
	if is_equal_approx(configured_bucket_size, _bucket_size):
		return true
	for instance_id_variant in _anchors_by_instance_id:
		var instance_id := int(instance_id_variant)
		if not _can_convert_to_bucket_with_size(
			_anchors_by_instance_id[instance_id],
			configured_bucket_size
		):
			_rejected_operations_total += 1
			return false

	_bucket_size = configured_bucket_size
	_buckets.clear()
	_bucket_by_instance_id.clear()
	_bucket_slot_by_instance_id.clear()
	_membership_count = 0
	for instance_id_variant in _anchors_by_instance_id:
		var instance_id := int(instance_id_variant)
		_add_to_bucket(instance_id, _to_bucket(_anchors_by_instance_id[instance_id]))
	_bucket_rebuilds_total += 1
	return true


## Registers one plant at its authoritative world anchor. Registering the same
## object again is idempotent and also refreshes its stored anchor.
func register(plant: Object, world_anchor: Vector2) -> bool:
	if (
		plant == null
		or not is_instance_valid(plant)
		or not world_anchor.is_finite()
		or not _can_convert_to_bucket(world_anchor)
	):
		_rejected_operations_total += 1
		return false

	var instance_id := plant.get_instance_id()
	if _plants_by_instance_id.has(instance_id):
		var registered_plant: Object = _plants_by_instance_id[instance_id]
		if registered_plant != plant:
			_rejected_operations_total += 1
			return false
		_duplicate_registrations_total += 1
		_relocate_registered_plant(instance_id, world_anchor)
		return true

	_plants_by_instance_id[instance_id] = plant
	_anchors_by_instance_id[instance_id] = world_anchor
	_add_to_bucket(instance_id, _to_bucket(world_anchor))
	_registrations_total += 1
	return true


## Removes a registered plant. The vacated bucket slot is filled from the end of
## the same bucket, and the moved plant's reverse slot is repaired in O(1).
func unregister(plant: Object) -> bool:
	if plant == null or not is_instance_valid(plant):
		_rejected_operations_total += 1
		return false

	var instance_id := plant.get_instance_id()
	if (
		not _plants_by_instance_id.has(instance_id)
		or _plants_by_instance_id[instance_id] != plant
	):
		_rejected_operations_total += 1
		return false

	_remove_from_bucket(instance_id)
	_plants_by_instance_id.erase(instance_id)
	_anchors_by_instance_id.erase(instance_id)
	_unregistrations_total += 1
	return true


## Updates a registered plant's authoritative anchor. Same-bucket movement only
## changes the stored anchor; cross-bucket movement uses O(1) remove/add work.
func update(plant: Object, world_anchor: Vector2) -> bool:
	if (
		plant == null
		or not is_instance_valid(plant)
		or not world_anchor.is_finite()
		or not _can_convert_to_bucket(world_anchor)
	):
		_rejected_operations_total += 1
		return false

	var instance_id := plant.get_instance_id()
	if (
		not _plants_by_instance_id.has(instance_id)
		or _plants_by_instance_id[instance_id] != plant
	):
		_rejected_operations_total += 1
		return false

	_relocate_registered_plant(instance_id, world_anchor)
	_updates_total += 1
	return true


## Clears all registrations and resets lifetime and last-query metrics.
func clear() -> void:
	_plants_by_instance_id.clear()
	_anchors_by_instance_id.clear()
	_bucket_by_instance_id.clear()
	_bucket_slot_by_instance_id.clear()
	_buckets.clear()
	_membership_count = 0
	_registrations_total = 0
	_duplicate_registrations_total = 0
	_updates_total = 0
	_unregistrations_total = 0
	_bucket_migrations_total = 0
	_bucket_swap_removals_total = 0
	_bucket_rebuilds_total = 0
	_rejected_operations_total = 0
	_queries_total = 0
	_reset_last_query_metrics()


## Returns the registered object with the nearest authoritative world anchor in
## the closed circle. Equal distances are resolved by the lower instance ID.
##
## The query allocates no candidate array. Narrow circles scan intersecting
## buckets, while broad or non-bucket-representable finite circles scan the
## compact registry. Registered-object lifecycle is owned by the caller, so this
## generic index only rejects null or invalid object references.
func find_nearest_world_anchor(
	center: Vector2,
	radius: float,
	excluded_instance_ids: Dictionary = {}
) -> Object:
	var collect_query_metrics := _query_metrics_enabled
	if collect_query_metrics:
		_queries_total += 1
		_reset_last_query_metrics()
	if not center.is_finite() or not is_finite(radius) or radius < 0.0:
		if collect_query_metrics:
			_last_query_mode = &"invalid"
		_rejected_operations_total += 1
		return null
	if _plants_by_instance_id.is_empty():
		if collect_query_metrics:
			_last_query_valid = true
			_last_query_mode = &"empty"
		return null

	var radius_vector := Vector2.ONE * radius
	var minimum := center - radius_vector
	var maximum := center + radius_vector
	var bounds_are_finite := minimum.is_finite() and maximum.is_finite()
	if collect_query_metrics:
		_last_query_valid = true
		if bounds_are_finite:
			var normalized_size := maximum - minimum
			if normalized_size.is_finite():
				_last_query_normalized_aabb = Rect2(minimum, normalized_size)
	var minimum_bucket := Vector2i.ZERO
	var maximum_bucket := Vector2i.ZERO
	var bucket_columns := 0
	var bucket_rows := 0
	var can_scan_buckets := (
		bounds_are_finite
		and _can_convert_to_bucket(minimum)
		and _can_convert_to_bucket(maximum)
	)
	var should_scan_registry := not can_scan_buckets
	if can_scan_buckets:
		minimum_bucket = _to_bucket(minimum)
		maximum_bucket = _to_bucket(maximum)
		bucket_columns = (
			int(maximum_bucket.x) - int(minimum_bucket.x) + 1
		)
		bucket_rows = int(maximum_bucket.y) - int(minimum_bucket.y) + 1
		should_scan_registry = (
			bucket_columns >= _plants_by_instance_id.size()
			or bucket_rows > _plants_by_instance_id.size() / bucket_columns
		)

	if collect_query_metrics:
		if can_scan_buckets:
			_last_query_minimum_bucket = minimum_bucket
			_last_query_maximum_bucket = maximum_bucket
			# Registry mode records the AABB cell span used by the adaptive
			# decision. Bucket mode increments this metric per ring cell below.
			if should_scan_registry:
				var bucket_cells_considered := MAX_SIGNED_INT
				if bucket_rows <= MAX_SIGNED_INT / bucket_columns:
					bucket_cells_considered = bucket_columns * bucket_rows
				_last_query_bucket_cells_considered = bucket_cells_considered
		else:
			# A finite radius may still overflow its derived bounds or lie outside
			# Vector2i's representable bucket domain. Registry scan stays correct.
			_last_query_bucket_cells_considered = MAX_SIGNED_INT

	var maximum_distance_squared := radius * radius
	var nearest: Object = null
	var nearest_distance_squared := maximum_distance_squared
	var nearest_instance_id := 0
	if should_scan_registry:
		if collect_query_metrics:
			_last_query_mode = &"registry"
			_last_query_candidates_visited = _anchors_by_instance_id.size()
		for instance_id_variant in _anchors_by_instance_id:
			var instance_id := int(instance_id_variant)
			if excluded_instance_ids.has(instance_id):
				continue
			var plant: Object = _plants_by_instance_id[instance_id]
			if plant == null or not is_instance_valid(plant):
				continue
			var anchor: Vector2 = _anchors_by_instance_id[instance_id]
			# Scalar math remains float64 even when Vector2 storage is float32;
			# this keeps distinct extreme finite distances from collapsing to INF.
			var delta_x := float(anchor.x) - float(center.x)
			var delta_y := float(anchor.y) - float(center.y)
			var distance_squared := delta_x * delta_x + delta_y * delta_y
			if distance_squared > maximum_distance_squared:
				continue
			if (
				nearest == null
				or distance_squared < nearest_distance_squared
				or (
					distance_squared == nearest_distance_squared
					and instance_id < nearest_instance_id
				)
			):
				nearest = plant
				nearest_distance_squared = distance_squared
				nearest_instance_id = instance_id
	else:
		if collect_query_metrics:
			_last_query_mode = &"buckets"
		var center_bucket := _to_bucket(center)
		var maximum_ring := maxi(
			maxi(
				absi(int(minimum_bucket.x) - int(center_bucket.x)),
				absi(int(maximum_bucket.x) - int(center_bucket.x))
			),
			maxi(
				absi(int(minimum_bucket.y) - int(center_bucket.y)),
				absi(int(maximum_bucket.y) - int(center_bucket.y))
			)
		)
		var center_x := float(center.x)
		var center_y := float(center.y)
		var center_bucket_minimum_x := (
			float(center_bucket.x) * _bucket_size
		)
		var center_bucket_minimum_y := (
			float(center_bucket.y) * _bucket_size
		)
		var center_bucket_maximum_x := (
			center_bucket_minimum_x + _bucket_size
		)
		var center_bucket_maximum_y := (
			center_bucket_minimum_y + _bucket_size
		)
		for ring in range(maximum_ring + 1):
			if ring > 0:
				# Every later square ring is at least this far from center. Once
				# the whole ring is strictly farther than the closed radius or the
				# known nearest anchor, no later ring can improve the result. Equal
				# distance must continue so a lower instance ID can still win.
				var ring_offset := float(ring - 1) * _bucket_size
				var left_distance := (
					center_x - center_bucket_minimum_x + ring_offset
				)
				var right_distance := (
					center_bucket_maximum_x - center_x + ring_offset
				)
				var top_distance := (
					center_y - center_bucket_minimum_y + ring_offset
				)
				var bottom_distance := (
					center_bucket_maximum_y - center_y + ring_offset
				)
				var ring_minimum_distance_squared := minf(
					minf(
						left_distance * left_distance,
						right_distance * right_distance
					),
					minf(
						top_distance * top_distance,
						bottom_distance * bottom_distance
					)
				)
				var ring_cutoff_distance_squared := maximum_distance_squared
				if nearest != null:
					ring_cutoff_distance_squared = nearest_distance_squared
				if (
					ring_minimum_distance_squared
					> ring_cutoff_distance_squared
				):
					break
			for bucket_y in range(
				center_bucket.y - ring,
				center_bucket.y + ring + 1
			):
				for bucket_x in range(
					center_bucket.x - ring,
					center_bucket.x + ring + 1
				):
					if (
						maxi(
							absi(bucket_x - center_bucket.x),
							absi(bucket_y - center_bucket.y)
						) != ring
					):
						continue
					if (
						bucket_x < minimum_bucket.x
						or bucket_x > maximum_bucket.x
						or bucket_y < minimum_bucket.y
						or bucket_y > maximum_bucket.y
					):
						continue
					if collect_query_metrics:
						_last_query_bucket_cells_considered += 1
					var bucket_cell := Vector2i(bucket_x, bucket_y)
					# Empty cells have no anchor whose lower bound matters. Reject
					# them with one hash lookup before doing the closed-AABB math.
					if not _buckets.has(bucket_cell):
						continue
					var bucket_minimum_distance_squared := (
						_distance_squared_to_bucket_closed_aabb(
							center,
							bucket_cell
						)
					)
					if bucket_minimum_distance_squared > maximum_distance_squared:
						if collect_query_metrics:
							_last_query_bucket_cells_pruned_by_radius += 1
						continue
					if (
						nearest != null
						and bucket_minimum_distance_squared
						> nearest_distance_squared
					):
						if collect_query_metrics:
							_last_query_bucket_cells_pruned_by_nearest += 1
						continue
					var bucket := _buckets[bucket_cell] as Array
					if collect_query_metrics:
						_last_query_non_empty_buckets_visited += 1
						_last_query_candidates_visited += bucket.size()
					for instance_id_variant in bucket:
						var instance_id := int(instance_id_variant)
						if excluded_instance_ids.has(instance_id):
							continue
						var plant: Object = _plants_by_instance_id[instance_id]
						if plant == null or not is_instance_valid(plant):
							continue
						var anchor: Vector2 = _anchors_by_instance_id[instance_id]
						var delta_x := float(anchor.x) - float(center.x)
						var delta_y := float(anchor.y) - float(center.y)
						var distance_squared := delta_x * delta_x + delta_y * delta_y
						if distance_squared > maximum_distance_squared:
							continue
						if (
							nearest == null
							or distance_squared < nearest_distance_squared
							or (
								distance_squared == nearest_distance_squared
								and instance_id < nearest_instance_id
							)
						):
							nearest = plant
							nearest_distance_squared = distance_squared
							nearest_instance_id = instance_id

	if collect_query_metrics:
		_last_query_results_written = 0 if nearest == null else 1
	return nearest


## Clears and fills a caller-owned array with targets whose stored anchors are in
## the normalized AABB. All four edges are inclusive, including a zero-size AABB.
##
## Very broad queries scan the compact registry instead of walking more empty
## bucket cells than there are registered targets. Both modes apply the exact same
## stored-anchor filter and expose their work through last-query metrics. Local
## viewport consumers may request bucket traversal whenever the finite bounds are
## representable, making distant-population work independent of registry size.
func query_world_aabb_into(
	world_aabb: Rect2,
	result: Array,
	prefer_bucket_scan: bool = false
) -> int:
	result.clear()
	if _query_metrics_enabled:
		_queries_total += 1
		_reset_last_query_metrics()
	if not world_aabb.position.is_finite() or not world_aabb.size.is_finite():
		if _query_metrics_enabled:
			_last_query_mode = &"invalid"
		_rejected_operations_total += 1
		return 0

	var opposite_corner := world_aabb.position + world_aabb.size
	# Rect2's fields can each be finite while their addition overflows. Reject the
	# derived corner before normalization or bucket conversion.
	if not opposite_corner.is_finite():
		if _query_metrics_enabled:
			_last_query_mode = &"invalid"
		_rejected_operations_total += 1
		return 0
	var minimum := Vector2(
		minf(world_aabb.position.x, opposite_corner.x),
		minf(world_aabb.position.y, opposite_corner.y)
	)
	var maximum := Vector2(
		maxf(world_aabb.position.x, opposite_corner.x),
		maxf(world_aabb.position.y, opposite_corner.y)
	)
	if _query_metrics_enabled:
		_last_query_valid = true
		_last_query_normalized_aabb = Rect2(minimum, maximum - minimum)

	if _plants_by_instance_id.is_empty():
		if _query_metrics_enabled:
			_last_query_mode = &"empty"
		return 0

	var minimum_bucket := Vector2i.ZERO
	var maximum_bucket := Vector2i.ZERO
	var bucket_columns := 0
	var bucket_rows := 0
	var can_scan_buckets := (
		_can_convert_to_bucket(minimum)
		and _can_convert_to_bucket(maximum)
	)
	var should_scan_registry := not can_scan_buckets
	if can_scan_buckets:
		minimum_bucket = _to_bucket(minimum)
		maximum_bucket = _to_bucket(maximum)
		bucket_columns = maximum_bucket.x - minimum_bucket.x + 1
		bucket_rows = maximum_bucket.y - minimum_bucket.y + 1
		should_scan_registry = (
			not prefer_bucket_scan
			and (
				bucket_columns >= _plants_by_instance_id.size()
				or bucket_rows > _plants_by_instance_id.size() / bucket_columns
			)
		)
	if _query_metrics_enabled:
		# Keep observability safe even when a finite AABB spans enough Vector2i
		# cells for the mathematical product to exceed a signed 64-bit metric.
		# A finite AABB may also lie outside Vector2i's representable bucket range;
		# registry mode remains exact without performing an overflowing conversion.
		if can_scan_buckets:
			var bucket_cells_considered := MAX_SIGNED_INT
			if bucket_rows <= MAX_SIGNED_INT / bucket_columns:
				bucket_cells_considered = bucket_columns * bucket_rows
			_last_query_minimum_bucket = minimum_bucket
			_last_query_maximum_bucket = maximum_bucket
			_last_query_bucket_cells_considered = bucket_cells_considered
		else:
			_last_query_bucket_cells_considered = MAX_SIGNED_INT

	if should_scan_registry:
		if _query_metrics_enabled:
			_last_query_mode = &"registry"
			for instance_id_variant in _anchors_by_instance_id:
				var instance_id := int(instance_id_variant)
				var anchor: Vector2 = _anchors_by_instance_id[instance_id]
				_last_query_candidates_visited += 1
				if _is_anchor_in_closed_aabb(anchor, minimum, maximum):
					result.append(_plants_by_instance_id[instance_id])
		else:
			for instance_id_variant in _anchors_by_instance_id:
				var instance_id := int(instance_id_variant)
				var anchor: Vector2 = _anchors_by_instance_id[instance_id]
				if _is_anchor_in_closed_aabb(anchor, minimum, maximum):
					result.append(_plants_by_instance_id[instance_id])
	else:
		if _query_metrics_enabled:
			_last_query_mode = &"buckets"
			for bucket_y in range(minimum_bucket.y, maximum_bucket.y + 1):
				for bucket_x in range(minimum_bucket.x, maximum_bucket.x + 1):
					var bucket_cell := Vector2i(bucket_x, bucket_y)
					if not _buckets.has(bucket_cell):
						continue
					_last_query_non_empty_buckets_visited += 1
					var bucket := _buckets[bucket_cell] as Array
					for instance_id_variant in bucket:
						var instance_id := int(instance_id_variant)
						var anchor: Vector2 = _anchors_by_instance_id[instance_id]
						_last_query_candidates_visited += 1
						if _is_anchor_in_closed_aabb(anchor, minimum, maximum):
							result.append(_plants_by_instance_id[instance_id])
		else:
			for bucket_y in range(minimum_bucket.y, maximum_bucket.y + 1):
				for bucket_x in range(minimum_bucket.x, maximum_bucket.x + 1):
					var bucket_cell := Vector2i(bucket_x, bucket_y)
					if not _buckets.has(bucket_cell):
						continue
					var bucket := _buckets[bucket_cell] as Array
					for instance_id_variant in bucket:
						var instance_id := int(instance_id_variant)
						var anchor: Vector2 = _anchors_by_instance_id[instance_id]
						if _is_anchor_in_closed_aabb(anchor, minimum, maximum):
							result.append(_plants_by_instance_id[instance_id])

	if _query_metrics_enabled:
		_last_query_results_written = result.size()
	return result.size()


## Returns O(1) counters that make the one-membership invariant observable.
func get_structure_metrics() -> Dictionary:
	var registered_count := _plants_by_instance_id.size()
	return {
		"query_metrics_enabled": _query_metrics_enabled,
		"bucket_size": _bucket_size,
		"registered_count": registered_count,
		"bucket_count": _buckets.size(),
		"membership_count": _membership_count,
		"anchor_reverse_count": _anchors_by_instance_id.size(),
		"bucket_reverse_count": _bucket_by_instance_id.size(),
		"slot_reverse_count": _bucket_slot_by_instance_id.size(),
		"structure_counts_consistent": (
			registered_count == _membership_count
			and registered_count == _anchors_by_instance_id.size()
			and registered_count == _bucket_by_instance_id.size()
			and registered_count == _bucket_slot_by_instance_id.size()
		),
		"registrations_total": _registrations_total,
		"duplicate_registrations_total": _duplicate_registrations_total,
		"updates_total": _updates_total,
		"unregistrations_total": _unregistrations_total,
		"bucket_migrations_total": _bucket_migrations_total,
		"bucket_swap_removals_total": _bucket_swap_removals_total,
		"bucket_rebuilds_total": _bucket_rebuilds_total,
		"rejected_operations_total": _rejected_operations_total,
		"queries_total": _queries_total,
	}


func get_last_query_metrics() -> Dictionary:
	return {
		"valid": _last_query_valid,
		"query_mode": _last_query_mode,
		"normalized_aabb": _last_query_normalized_aabb,
		"minimum_bucket": _last_query_minimum_bucket,
		"maximum_bucket": _last_query_maximum_bucket,
		"bucket_cells_considered": _last_query_bucket_cells_considered,
		"bucket_cells_pruned_by_radius": (
			_last_query_bucket_cells_pruned_by_radius
		),
		"bucket_cells_pruned_by_nearest": (
			_last_query_bucket_cells_pruned_by_nearest
		),
		"non_empty_buckets_visited": _last_query_non_empty_buckets_visited,
		"candidates_visited": _last_query_candidates_visited,
		"results_written": _last_query_results_written,
	}


func _relocate_registered_plant(instance_id: int, world_anchor: Vector2) -> void:
	var next_bucket := _to_bucket(world_anchor)
	var previous_bucket: Vector2i = _bucket_by_instance_id[instance_id]
	_anchors_by_instance_id[instance_id] = world_anchor
	if previous_bucket == next_bucket:
		return
	_remove_from_bucket(instance_id)
	_add_to_bucket(instance_id, next_bucket)
	_bucket_migrations_total += 1


func _add_to_bucket(instance_id: int, bucket_cell: Vector2i) -> void:
	if _buckets.has(bucket_cell):
		var bucket := _buckets[bucket_cell] as Array
		_bucket_slot_by_instance_id[instance_id] = bucket.size()
		bucket.append(instance_id)
	else:
		_buckets[bucket_cell] = [instance_id]
		_bucket_slot_by_instance_id[instance_id] = 0
	_bucket_by_instance_id[instance_id] = bucket_cell
	_membership_count += 1


func _remove_from_bucket(instance_id: int) -> void:
	var bucket_cell: Vector2i = _bucket_by_instance_id[instance_id]
	var slot := int(_bucket_slot_by_instance_id[instance_id])
	var bucket := _buckets[bucket_cell] as Array
	var last_slot := bucket.size() - 1
	_bucket_by_instance_id.erase(instance_id)
	_bucket_slot_by_instance_id.erase(instance_id)
	if slot != last_slot:
		var moved_instance_id := int(bucket[last_slot])
		bucket[slot] = moved_instance_id
		_bucket_slot_by_instance_id[moved_instance_id] = slot
		_bucket_swap_removals_total += 1
	bucket.pop_back()
	_membership_count -= 1
	if bucket.is_empty():
		_buckets.erase(bucket_cell)


func _to_bucket(world_anchor: Vector2) -> Vector2i:
	return Vector2i(
		floori(world_anchor.x / _bucket_size),
		floori(world_anchor.y / _bucket_size)
	)


func _can_convert_to_bucket(world_position: Vector2) -> bool:
	return _can_convert_to_bucket_with_size(world_position, _bucket_size)


func _can_convert_to_bucket_with_size(
	world_position: Vector2,
	configured_bucket_size: float
) -> bool:
	var scaled_x := float(world_position.x) / configured_bucket_size
	var scaled_y := float(world_position.y) / configured_bucket_size
	return (
		is_finite(scaled_x)
		and is_finite(scaled_y)
		and scaled_x >= MIN_VECTOR2I_COMPONENT
		and scaled_x < MAX_VECTOR2I_COMPONENT_EXCLUSIVE
		and scaled_y >= MIN_VECTOR2I_COMPONENT
		and scaled_y < MAX_VECTOR2I_COMPONENT_EXCLUSIVE
	)


func _distance_squared_to_bucket_closed_aabb(
	center: Vector2,
	bucket_cell: Vector2i
) -> float:
	var bucket_minimum_x := float(bucket_cell.x) * _bucket_size
	var bucket_minimum_y := float(bucket_cell.y) * _bucket_size
	var bucket_maximum_x := bucket_minimum_x + _bucket_size
	var bucket_maximum_y := bucket_minimum_y + _bucket_size
	var center_x := float(center.x)
	var center_y := float(center.y)
	var closest_x := clampf(center_x, bucket_minimum_x, bucket_maximum_x)
	var closest_y := clampf(center_y, bucket_minimum_y, bucket_maximum_y)
	var delta_x := center_x - closest_x
	var delta_y := center_y - closest_y
	return delta_x * delta_x + delta_y * delta_y


func _is_anchor_in_closed_aabb(
	anchor: Vector2,
	minimum: Vector2,
	maximum: Vector2
) -> bool:
	return (
		anchor.x >= minimum.x
		and anchor.x <= maximum.x
		and anchor.y >= minimum.y
		and anchor.y <= maximum.y
	)


func _is_valid_bucket_size(configured_bucket_size: float) -> bool:
	return is_finite(configured_bucket_size) and configured_bucket_size > 0.0


func _reset_last_query_metrics() -> void:
	_last_query_valid = false
	_last_query_mode = &"none"
	_last_query_normalized_aabb = Rect2()
	_last_query_minimum_bucket = Vector2i.ZERO
	_last_query_maximum_bucket = Vector2i.ZERO
	_last_query_bucket_cells_considered = 0
	_last_query_bucket_cells_pruned_by_radius = 0
	_last_query_bucket_cells_pruned_by_nearest = 0
	_last_query_non_empty_buckets_visited = 0
	_last_query_candidates_visited = 0
	_last_query_results_written = 0
