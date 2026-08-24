extends Node
class_name EnemyDamageableSpatialIndex

## Lifecycle-driven broad phase for plant damageables hit by enemy-owned,
## data-oriented projectiles. Players intentionally remain outside this index.
##
## Each plant stores the complete world AABB and exact geometry of every enabled
## CollisionShape2D authored directly below its PlantDefense root. A broad query
## only proves AABB overlap; callers use damageable_overlaps_shape() for the
## cached exact Shape2D posterior without traversing the scene tree.

const DEFAULT_BUCKET_SIZE := 64.0
const MIN_VECTOR2I_COMPONENT := -2147483648.0
const MAX_VECTOR2I_COMPONENT_EXCLUSIVE := 2147483648.0
const INVALID_BOUNDS_POSITION := Vector2(INF, INF)

signal runtime_teardown_prepared(spatial_index: Node)


class GeometrySnapshot:
	extends RefCounted

	var world_aabb := Rect2(INVALID_BOUNDS_POSITION, Vector2.ZERO)
	var root_shapes: Array[Shape2D] = []
	var root_shape_world_transforms: Array[Transform2D] = []


class Entry:
	extends RefCounted

	var damageable: StaticBody2D
	var world_aabb := Rect2()
	var bucket_cells: Array[Vector2i] = []
	var root_shapes: Array[Shape2D] = []
	var root_shape_world_transforms: Array[Transform2D] = []


	func _init(
		registered_damageable: StaticBody2D,
		geometry: GeometrySnapshot
	) -> void:
		damageable = registered_damageable
		set_geometry(geometry)


	func set_geometry(geometry: GeometrySnapshot) -> void:
		world_aabb = geometry.world_aabb
		root_shapes.assign(geometry.root_shapes)
		root_shape_world_transforms.assign(
			geometry.root_shape_world_transforms
		)


@export_range(16.0, 512.0, 1.0, "or_greater") var bucket_size := (
	DEFAULT_BUCKET_SIZE
)

var _combat_runtime: Node = null
var _enemy_simulation_coordinator: Node = null
var _entries_by_instance_id: Dictionary[int, Entry] = {}
var _buckets: Dictionary[Vector2i, Array] = {}
var _query_candidate_instance_ids: Array[int] = []
var _query_visit_generation_by_instance_id: Dictionary[int, int] = {}
var _query_generation := 0
var _membership_count := 0
var _teardown_prepared := false
var _teardown_count := 0
var _registrations_total := 0
var _updates_total := 0
var _unregistrations_total := 0
var _rejected_operations_total := 0
var _queries_total := 0
var _exact_shape_queries_total := 0
var _geometry_revision := 1


func _init() -> void:
	set_process(false)
	set_physics_process(false)


func bind_context(
	combat_runtime: Node,
	coordinator: Node
) -> bool:
	if _teardown_prepared:
		return false
	if (
		combat_runtime == null
		or coordinator == null
		or not is_instance_valid(combat_runtime)
		or not is_instance_valid(coordinator)
		or coordinator.get_parent() != combat_runtime
	):
		return false
	if (
		_combat_runtime != null
		and (
			_combat_runtime != combat_runtime
			or _enemy_simulation_coordinator != coordinator
		)
	):
		return false
	_combat_runtime = combat_runtime
	_enemy_simulation_coordinator = coordinator
	return true


func is_bound() -> bool:
	return (
		_combat_runtime != null
		and _enemy_simulation_coordinator != null
		and is_instance_valid(_combat_runtime)
		and is_instance_valid(_enemy_simulation_coordinator)
	)


func is_bound_to(
	combat_runtime: Node,
	coordinator: Node
) -> bool:
	return (
		is_bound()
		and _combat_runtime == combat_runtime
		and _enemy_simulation_coordinator == coordinator
	)


## Registers the authoritative root collision AABB. Re-registering the same
## plant is idempotent and refreshes its current collision transforms.
func register_damageable(damageable: StaticBody2D) -> bool:
	if not _can_accept_damageable(damageable):
		_rejected_operations_total += 1
		return false
	var geometry := _capture_damageable_geometry(damageable)
	if not _is_valid_geometry_snapshot(geometry):
		_rejected_operations_total += 1
		return false
	var instance_id := damageable.get_instance_id()
	var existing := _entries_by_instance_id.get(instance_id) as Entry
	if existing != null:
		if existing.damageable != damageable:
			_rejected_operations_total += 1
			return false
		return _update_entry(existing, geometry, false)

	var entry := Entry.new(damageable, geometry)
	if not _populate_bucket_cells(entry.bucket_cells, geometry.world_aabb):
		_rejected_operations_total += 1
		return false
	_entries_by_instance_id[instance_id] = entry
	_add_entry_to_buckets(instance_id, entry.bucket_cells)
	_registrations_total += 1
	_geometry_revision += 1
	return true


## Refreshes a moved or shape-mutated plant without scanning any scene nodes
## during projectile queries. Movement owners must call this explicitly.
func update_damageable(damageable: StaticBody2D) -> bool:
	if not _can_accept_damageable(damageable):
		_rejected_operations_total += 1
		return false
	var entry := (
		_entries_by_instance_id.get(damageable.get_instance_id()) as Entry
	)
	if entry == null or entry.damageable != damageable:
		_rejected_operations_total += 1
		return false
	var geometry := _capture_damageable_geometry(damageable)
	if not _is_valid_geometry_snapshot(geometry):
		_rejected_operations_total += 1
		return false
	return _update_entry(entry, geometry, true)


func unregister_damageable(damageable: StaticBody2D) -> bool:
	if damageable == null or not is_instance_valid(damageable):
		_rejected_operations_total += 1
		return false
	var instance_id := damageable.get_instance_id()
	var entry := _entries_by_instance_id.get(instance_id) as Entry
	if entry == null or entry.damageable != damageable:
		_rejected_operations_total += 1
		return false
	_remove_entry_from_buckets(instance_id, entry.bucket_cells)
	_entries_by_instance_id.erase(instance_id)
	_query_visit_generation_by_instance_id.erase(instance_id)
	entry.damageable = null
	entry.bucket_cells.clear()
	entry.root_shapes.clear()
	entry.root_shape_world_transforms.clear()
	_unregistrations_total += 1
	_geometry_revision += 1
	return true


func contains_damageable(damageable: StaticBody2D) -> bool:
	if damageable == null or not is_instance_valid(damageable):
		return false
	var entry := (
		_entries_by_instance_id.get(damageable.get_instance_id()) as Entry
	)
	return entry != null and entry.damageable == damageable


func has_registered_damageables() -> bool:
	return not _entries_by_instance_id.is_empty()


## Exact posterior for a broad-phase candidate. This only reads shape resources
## and transforms cached by register/update; it never traverses plant children.
func damageable_overlaps_shape(
	damageable: StaticBody2D,
	projectile_shape: Shape2D,
	projectile_world_transform: Transform2D
) -> bool:
	_exact_shape_queries_total += 1
	if (
		projectile_shape == null
		or not _is_finite_transform(projectile_world_transform)
		or damageable == null
		or not is_instance_valid(damageable)
	):
		_rejected_operations_total += 1
		return false
	var entry := (
		_entries_by_instance_id.get(damageable.get_instance_id()) as Entry
	)
	if entry == null or entry.damageable != damageable:
		return false
	return _entry_overlaps_shape(
		entry,
		projectile_shape,
		projectile_world_transform
	)


func _entry_overlaps_shape(
	entry: Entry,
	shape: Shape2D,
	world_transform: Transform2D
) -> bool:
	for shape_index in range(entry.root_shapes.size()):
		var cached_shape := entry.root_shapes[shape_index]
		if (
			cached_shape != null
			and cached_shape.collide(
				entry.root_shape_world_transforms[shape_index],
				shape,
				world_transform
			)
		):
			return true
	return false


## Combined broad/exact query for callers advancing one reusable Shape2D.
## The caller-owned result is first filled in stable instance-ID order by the
## existing AABB query, then compacted in place to exact cached-geometry hits.
## No candidate Array or scene-tree geometry traversal is introduced here.
func query_overlapping_damageables_into(
	shape: Shape2D,
	world_transform: Transform2D,
	result: Array
) -> int:
	result.clear()
	if shape == null or not _is_finite_transform(world_transform):
		_rejected_operations_total += 1
		return 0

	var world_aabb := _transform_rect_to_world_aabb(
		shape.get_rect(),
		world_transform
	)
	if query_world_aabb_into(world_aabb, result) <= 0:
		return 0

	var write_index := 0
	var candidate_count := result.size()
	for read_index in range(candidate_count):
		var damageable := result[read_index] as StaticBody2D
		var entry := (
			_entries_by_instance_id.get(damageable.get_instance_id()) as Entry
			if damageable != null
			else null
		)
		_exact_shape_queries_total += 1
		if (
			entry == null
			or entry.damageable != damageable
			or not _entry_overlaps_shape(entry, shape, world_transform)
		):
			continue
		result[write_index] = damageable
		write_index += 1
	result.resize(write_index)
	return write_index


## Fills caller-owned storage and returns its final size. Results are unique and
## sorted by instance ID, so repeated queries have a stable order regardless of
## bucket traversal, updates, or multi-bucket memberships. All edges are closed.
func query_world_aabb_into(world_aabb: Rect2, result: Array) -> int:
	result.clear()
	_queries_total += 1
	var normalized_query := _normalize_finite_world_aabb(world_aabb)
	if not _is_valid_normalized_world_aabb(normalized_query):
		_rejected_operations_total += 1
		return 0
	if _entries_by_instance_id.is_empty():
		return 0

	_query_candidate_instance_ids.clear()
	if (
		not _can_convert_to_bucket(normalized_query.position)
		or not _can_convert_to_bucket(normalized_query.end)
	):
		_collect_registry_candidate_ids()
	else:
		var minimum_bucket := _to_bucket(normalized_query.position)
		var maximum_bucket := _to_bucket(normalized_query.end)
		var columns := int(maximum_bucket.x) - int(minimum_bucket.x) + 1
		var rows := int(maximum_bucket.y) - int(minimum_bucket.y) + 1
		var should_scan_registry := (
			columns >= _entries_by_instance_id.size()
			or rows > _entries_by_instance_id.size() / columns
		)
		if should_scan_registry:
			_collect_registry_candidate_ids()
		else:
			_collect_bucket_candidate_ids(minimum_bucket, maximum_bucket)

	_query_candidate_instance_ids.sort()
	for instance_id in _query_candidate_instance_ids:
		var entry := _entries_by_instance_id.get(instance_id) as Entry
		if (
			entry != null
			and entry.damageable != null
			and is_instance_valid(entry.damageable)
			and _closed_aabbs_intersect(entry.world_aabb, normalized_query)
		):
			result.append(entry.damageable)
	return result.size()


## Returns the cached broad-phase AABB. An invalid position means the object is
## not registered; callers still own any exact Shape2D posterior test.
func get_registered_world_aabb(damageable: StaticBody2D) -> Rect2:
	if damageable == null or not is_instance_valid(damageable):
		return Rect2(INVALID_BOUNDS_POSITION, Vector2.ZERO)
	var entry := (
		_entries_by_instance_id.get(damageable.get_instance_id()) as Entry
	)
	if entry == null or entry.damageable != damageable:
		return Rect2(INVALID_BOUNDS_POSITION, Vector2.ZERO)
	return entry.world_aabb


## Monotonic invalidation token for consumers caching broad/exact results.
## Authoritative movement and shape owners already update this index explicitly.
func get_geometry_revision() -> int:
	return _geometry_revision


## Computes the union of enabled root collision shapes in world space. Nested
## PlayerCoreBody/interaction shapes are deliberately excluded because they are
## not the PlantDefense root body hit by enemy projectiles.
static func calculate_damageable_world_aabb(
	damageable: StaticBody2D
) -> Rect2:
	return _capture_damageable_geometry(damageable).world_aabb


static func _capture_damageable_geometry(
	damageable: StaticBody2D
) -> GeometrySnapshot:
	var geometry := GeometrySnapshot.new()
	if damageable == null or not is_instance_valid(damageable):
		return geometry
	var has_bounds := false
	var combined := Rect2()
	for child in damageable.get_children():
		var collision_shape := child as CollisionShape2D
		if (
			collision_shape == null
			or collision_shape.disabled
			or collision_shape.shape == null
		):
			continue
		var shape_bounds := _transform_rect_to_world_aabb(
			collision_shape.shape.get_rect(),
			collision_shape.global_transform
		)
		if not _is_valid_normalized_world_aabb(shape_bounds):
			return GeometrySnapshot.new()
		combined = shape_bounds if not has_bounds else combined.merge(shape_bounds)
		has_bounds = true
		geometry.root_shapes.append(collision_shape.shape)
		geometry.root_shape_world_transforms.append(
			collision_shape.global_transform
		)
	if has_bounds:
		geometry.world_aabb = combined
	return geometry


func clear() -> void:
	for entry in _entries_by_instance_id.values():
		var typed_entry := entry as Entry
		if typed_entry != null:
			typed_entry.damageable = null
			typed_entry.bucket_cells.clear()
			typed_entry.root_shapes.clear()
			typed_entry.root_shape_world_transforms.clear()
	_entries_by_instance_id.clear()
	_buckets.clear()
	_query_candidate_instance_ids.clear()
	_query_visit_generation_by_instance_id.clear()
	_query_generation = 0
	_membership_count = 0
	_geometry_revision += 1


func prepare_for_runtime_teardown() -> void:
	if _teardown_prepared:
		return
	_teardown_prepared = true
	_teardown_count += 1
	runtime_teardown_prepared.emit(self)
	clear()
	_combat_runtime = null
	_enemy_simulation_coordinator = null


func get_metrics() -> Dictionary:
	return {
		"bound": is_bound(),
		"teardown_prepared": _teardown_prepared,
		"teardown_count": _teardown_count,
		"registered_count": _entries_by_instance_id.size(),
		"bucket_count": _buckets.size(),
		"membership_count": _membership_count,
		"registrations_total": _registrations_total,
		"updates_total": _updates_total,
		"unregistrations_total": _unregistrations_total,
		"rejected_operations_total": _rejected_operations_total,
		"queries_total": _queries_total,
		"exact_shape_queries_total": _exact_shape_queries_total,
		"geometry_revision": _geometry_revision,
	}


func _can_accept_damageable(damageable: StaticBody2D) -> bool:
	return (
		is_bound()
		and not _teardown_prepared
		and damageable != null
		and is_instance_valid(damageable)
		and not damageable.is_queued_for_deletion()
	)


func _update_entry(
	entry: Entry,
	geometry: GeometrySnapshot,
	count_update: bool
) -> bool:
	var replacement_cells: Array[Vector2i] = []
	if not _populate_bucket_cells(replacement_cells, geometry.world_aabb):
		_rejected_operations_total += 1
		return false
	var instance_id := entry.damageable.get_instance_id()
	_remove_entry_from_buckets(instance_id, entry.bucket_cells)
	entry.set_geometry(geometry)
	entry.bucket_cells = replacement_cells
	_add_entry_to_buckets(instance_id, entry.bucket_cells)
	if count_update:
		_updates_total += 1
	_geometry_revision += 1
	return true


func _populate_bucket_cells(
	result: Array[Vector2i],
	world_aabb: Rect2
) -> bool:
	result.clear()
	if (
		not _is_valid_normalized_world_aabb(world_aabb)
		or not _can_convert_to_bucket(world_aabb.position)
		or not _can_convert_to_bucket(world_aabb.end)
	):
		return false
	var minimum_bucket := _to_bucket(world_aabb.position)
	var maximum_bucket := _to_bucket(world_aabb.end)
	for bucket_y in range(minimum_bucket.y, maximum_bucket.y + 1):
		for bucket_x in range(minimum_bucket.x, maximum_bucket.x + 1):
			result.append(Vector2i(bucket_x, bucket_y))
	return not result.is_empty()


func _add_entry_to_buckets(
	instance_id: int,
	bucket_cells: Array[Vector2i]
) -> void:
	for bucket_cell in bucket_cells:
		var bucket: Array = []
		if _buckets.has(bucket_cell):
			bucket = _buckets[bucket_cell]
		else:
			bucket = []
			_buckets[bucket_cell] = bucket
		bucket.append(instance_id)
		_membership_count += 1


func _remove_entry_from_buckets(
	instance_id: int,
	bucket_cells: Array[Vector2i]
) -> void:
	for bucket_cell in bucket_cells:
		if not _buckets.has(bucket_cell):
			continue
		var bucket: Array = _buckets[bucket_cell]
		var slot := bucket.find(instance_id)
		if slot < 0:
			continue
		bucket.remove_at(slot)
		_membership_count = maxi(_membership_count - 1, 0)
		if bucket.is_empty():
			_buckets.erase(bucket_cell)


func _collect_registry_candidate_ids() -> void:
	for instance_id_variant in _entries_by_instance_id:
		_query_candidate_instance_ids.append(int(instance_id_variant))


func _collect_bucket_candidate_ids(
	minimum_bucket: Vector2i,
	maximum_bucket: Vector2i
) -> void:
	_advance_query_generation()
	for bucket_y in range(minimum_bucket.y, maximum_bucket.y + 1):
		for bucket_x in range(minimum_bucket.x, maximum_bucket.x + 1):
			var bucket_cell := Vector2i(bucket_x, bucket_y)
			if not _buckets.has(bucket_cell):
				continue
			var bucket: Array = _buckets[bucket_cell]
			for instance_id_variant in bucket:
				var instance_id := int(instance_id_variant)
				if (
					_query_visit_generation_by_instance_id.get(instance_id, 0)
					== _query_generation
				):
					continue
				_query_visit_generation_by_instance_id[instance_id] = (
					_query_generation
				)
				_query_candidate_instance_ids.append(instance_id)


func _advance_query_generation() -> void:
	_query_generation += 1
	if _query_generation > 2147483647:
		_query_visit_generation_by_instance_id.clear()
		_query_generation = 1


func _to_bucket(world_position: Vector2) -> Vector2i:
	return Vector2i(
		floori(world_position.x / bucket_size),
		floori(world_position.y / bucket_size)
	)


func _can_convert_to_bucket(world_position: Vector2) -> bool:
	if not world_position.is_finite() or not is_finite(bucket_size) or bucket_size <= 0.0:
		return false
	var scaled := world_position / bucket_size
	return (
		scaled.x >= MIN_VECTOR2I_COMPONENT
		and scaled.x < MAX_VECTOR2I_COMPONENT_EXCLUSIVE
		and scaled.y >= MIN_VECTOR2I_COMPONENT
		and scaled.y < MAX_VECTOR2I_COMPONENT_EXCLUSIVE
	)


static func _normalize_finite_world_aabb(world_aabb: Rect2) -> Rect2:
	if not world_aabb.position.is_finite() or not world_aabb.size.is_finite():
		return Rect2(INVALID_BOUNDS_POSITION, Vector2.ZERO)
	var opposite_corner := world_aabb.position + world_aabb.size
	if not opposite_corner.is_finite():
		return Rect2(INVALID_BOUNDS_POSITION, Vector2.ZERO)
	var minimum := Vector2(
		minf(world_aabb.position.x, opposite_corner.x),
		minf(world_aabb.position.y, opposite_corner.y)
	)
	var maximum := Vector2(
		maxf(world_aabb.position.x, opposite_corner.x),
		maxf(world_aabb.position.y, opposite_corner.y)
	)
	return Rect2(minimum, maximum - minimum)


static func _is_valid_normalized_world_aabb(world_aabb: Rect2) -> bool:
	return (
		world_aabb.position.is_finite()
		and world_aabb.size.is_finite()
		and world_aabb.size.x >= 0.0
		and world_aabb.size.y >= 0.0
		and (world_aabb.position + world_aabb.size).is_finite()
	)


static func _is_valid_geometry_snapshot(geometry: GeometrySnapshot) -> bool:
	return (
		geometry != null
		and _is_valid_normalized_world_aabb(geometry.world_aabb)
		and not geometry.root_shapes.is_empty()
		and geometry.root_shapes.size()
			== geometry.root_shape_world_transforms.size()
	)


static func _is_finite_transform(value: Transform2D) -> bool:
	return value.x.is_finite() and value.y.is_finite() and value.origin.is_finite()


static func _closed_aabbs_intersect(first: Rect2, second: Rect2) -> bool:
	return (
		first.position.x <= second.end.x
		and first.end.x >= second.position.x
		and first.position.y <= second.end.y
		and first.end.y >= second.position.y
	)


static func _transform_rect_to_world_aabb(
	local_rect: Rect2,
	world_transform: Transform2D
) -> Rect2:
	var local_end := local_rect.end
	var first_corner := world_transform * local_rect.position
	var second_corner := world_transform * Vector2(
		local_end.x,
		local_rect.position.y
	)
	var third_corner := world_transform * local_end
	var fourth_corner := world_transform * Vector2(
		local_rect.position.x,
		local_end.y
	)
	var minimum := (
		first_corner.min(second_corner).min(third_corner).min(fourth_corner)
	)
	var maximum := (
		first_corner.max(second_corner).max(third_corner).max(fourth_corner)
	)
	return Rect2(minimum, maximum - minimum)


func _exit_tree() -> void:
	prepare_for_runtime_teardown()
