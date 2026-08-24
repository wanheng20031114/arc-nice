extends RefCounted
class_name CombatContactShapeProxy

## Immutable, translation-only contact geometry captured from a Shape2D.
##
## Circle and capsule shapes are represented exactly as a point/segment core
## plus a radius. Rectangle and convex-polygon shapes retain their convex core,
## while SegmentShape2D retains its two endpoints. A translation sweep is the
## convex hull of the core at both endpoints, so fast movers cannot tunnel
## through another supported convex shape.
##
## The captured basis is deliberately immutable. Non-uniform scale, shear,
## reflection, rotation changes, and scale changes are explicit unsupported
## states rather than silent approximations.

enum ShapeKind {
	UNSUPPORTED,
	CIRCLE,
	CAPSULE,
	RECTANGLE,
	CONVEX_POLYGON,
	SEGMENT,
	COMPOUND,
}

enum SupportStatus {
	SUPPORTED,
	NULL_SHAPE,
	UNSUPPORTED_SHAPE,
	INVALID_GEOMETRY,
	NON_FINITE_TRANSFORM,
	NON_UNIFORM_SCALE,
	SHEARED_TRANSFORM,
	REFLECTED_TRANSFORM,
	ROTATION_CHANGED,
	SCALE_CHANGED,
}

const BASIS_EPSILON := 0.0001
const DISTANCE_EPSILON := 0.00001
const MIN_SCALE := 0.00001
const DEFAULT_TOI_BISECTION_ITERATIONS := 18

var shape_kind: ShapeKind = ShapeKind.UNSUPPORTED
var support_status: SupportStatus = SupportStatus.NULL_SHAPE
var capture_position := Vector2.ZERO
var capture_rotation := 0.0
var capture_scale := 1.0
var core_radius := 0.0

var _core_offsets := PackedVector2Array()
var _minimum_offset := Vector2.ZERO
var _maximum_offset := Vector2.ZERO
var _compound_children: Array[CombatContactShapeProxy] = []
var _compound_child_anchor_offsets := PackedVector2Array()


static func create(
	shape: Shape2D,
	world_transform: Transform2D = Transform2D.IDENTITY
) -> CombatContactShapeProxy:
	var proxy := CombatContactShapeProxy.new()
	proxy._capture(shape, world_transform)
	return proxy


static func from_collision_shape(
	shape_node: CollisionShape2D
) -> CombatContactShapeProxy:
	if shape_node == null or not is_instance_valid(shape_node):
		return create(null)
	return create(shape_node.shape, shape_node.global_transform)


## Captures a non-convex union around one translation-only root anchor. Child
## shapes stay independent: gaps between authored shapes never become contact.
static func create_compound(
	shapes: Array[Shape2D],
	world_transforms: Array[Transform2D],
	anchor_transform: Transform2D = Transform2D.IDENTITY
) -> CombatContactShapeProxy:
	var proxy := CombatContactShapeProxy.new()
	proxy._capture_compound(shapes, world_transforms, anchor_transform)
	return proxy


static func from_collision_shapes(
	shape_nodes: Array[CollisionShape2D],
	anchor_transform: Transform2D
) -> CombatContactShapeProxy:
	var shapes: Array[Shape2D] = []
	var world_transforms: Array[Transform2D] = []
	for shape_node in shape_nodes:
		if shape_node == null or not is_instance_valid(shape_node):
			return create(null)
		shapes.append(shape_node.shape)
		world_transforms.append(shape_node.global_transform)
	return create_compound(shapes, world_transforms, anchor_transform)


func is_supported() -> bool:
	return support_status == SupportStatus.SUPPORTED


func get_support_reason() -> StringName:
	return status_to_name(support_status)


func get_core_point_count() -> int:
	if shape_kind == ShapeKind.COMPOUND:
		var point_count := 0
		for child in _compound_children:
			point_count += child.get_core_point_count()
		return point_count
	return _core_offsets.size()


func get_compound_child_count() -> int:
	return _compound_children.size() if shape_kind == ShapeKind.COMPOUND else 0


func get_bounding_radius() -> float:
	if not is_supported():
		return 0.0
	if shape_kind == ShapeKind.COMPOUND:
		var compound_radius := 0.0
		for child_index in range(_compound_children.size()):
			compound_radius = maxf(
				compound_radius,
				_compound_child_anchor_offsets[child_index].length()
					+ _compound_children[child_index].get_bounding_radius()
			)
		return compound_radius
	var maximum_squared := 0.0
	for point in _core_offsets:
		maximum_squared = maxf(maximum_squared, point.length_squared())
	return sqrt(maximum_squared) + core_radius


func validate_translation_transform(world_transform: Transform2D) -> SupportStatus:
	if not is_supported():
		return support_status
	var basis_status := _validate_basis(world_transform)
	if basis_status != SupportStatus.SUPPORTED:
		return basis_status
	var next_rotation := world_transform.get_rotation()
	if absf(wrapf(next_rotation - capture_rotation, -PI, PI)) > BASIS_EPSILON:
		return SupportStatus.ROTATION_CHANGED
	var next_scale := world_transform.x.length()
	if not is_equal_approx(next_scale, capture_scale):
		return SupportStatus.SCALE_CHANGED
	return SupportStatus.SUPPORTED


func is_translation_transform_supported(world_transform: Transform2D) -> bool:
	return validate_translation_transform(world_transform) == SupportStatus.SUPPORTED


func get_world_aabb_at(world_position: Vector2) -> Rect2:
	if not is_supported() or not world_position.is_finite():
		return Rect2()
	var radius_vector := Vector2.ONE * core_radius
	var minimum := world_position + _minimum_offset - radius_vector
	var maximum := world_position + _maximum_offset + radius_vector
	return Rect2(minimum, maximum - minimum)


func get_swept_world_aabb(
	from_position: Vector2,
	to_position: Vector2
) -> Rect2:
	if (
		not is_supported()
		or not from_position.is_finite()
		or not to_position.is_finite()
	):
		return Rect2()
	return get_world_aabb_at(from_position).merge(get_world_aabb_at(to_position))


func overlaps_at(
	world_position: Vector2,
	other: CombatContactShapeProxy,
	other_world_position: Vector2
) -> bool:
	if not _can_compare(world_position, other, other_world_position):
		return false
	if shape_kind == ShapeKind.COMPOUND:
		return _compound_overlaps_at(world_position, other, other_world_position)
	if other.shape_kind == ShapeKind.COMPOUND:
		return other._compound_overlaps_at(
			other_world_position,
			self,
			world_position
		)
	var self_core := _translated_core(world_position)
	var other_core := other._translated_core(other_world_position)
	return _cores_overlap_with_radius(
		self_core,
		other_core,
		core_radius + other.core_radius
	)


func swept_overlaps(
	from_position: Vector2,
	to_position: Vector2,
	other: CombatContactShapeProxy,
	other_from_position: Vector2,
	other_to_position: Vector2
) -> bool:
	if (
		not _can_compare(from_position, other, other_from_position)
		or not to_position.is_finite()
		or not other_to_position.is_finite()
	):
		return false
	if shape_kind == ShapeKind.COMPOUND:
		return _compound_swept_overlaps(
			from_position,
			to_position,
			other,
			other_from_position,
			other_to_position
		)
	if other.shape_kind == ShapeKind.COMPOUND:
		return other._compound_swept_overlaps(
			other_from_position,
			other_to_position,
			self,
			from_position,
			to_position
		)
	# Express both movers in the other's start frame. The first core translates
	# by the relative displacement while the second remains stationary.
	var relative_displacement := (
		(to_position - from_position)
		- (other_to_position - other_from_position)
	)
	var self_start_core := _translated_core(from_position)
	var swept_core := _swept_convex_core(
		self_start_core,
		relative_displacement
	)
	var other_start_core := other._translated_core(other_from_position)
	return _cores_overlap_with_radius(
		swept_core,
		other_start_core,
		core_radius + other.core_radius
	)


## Returns the earliest normalized time at which the two translation-only
## sweeps touch. Callers must first establish that swept_overlaps() is true;
## when no sweep contact exists this method deliberately returns 1.0, the same
## safe fraction as an endpoint-only contact.
##
## Endpoint overlap is not a monotonic predicate (a mover can enter and leave
## during one tick), so the bisection uses "did any contact occur in [0, t]".
## That prefix-sweep predicate is monotonic and therefore cannot skip a fast
## crossing whose two endpoints are separated.
func get_earliest_swept_overlap_fraction(
	from_position: Vector2,
	to_position: Vector2,
	other: CombatContactShapeProxy,
	other_from_position: Vector2,
	other_to_position: Vector2,
	bisection_iterations: int = DEFAULT_TOI_BISECTION_ITERATIONS
) -> float:
	if (
		not _can_compare(from_position, other, other_from_position)
		or not to_position.is_finite()
		or not other_to_position.is_finite()
	):
		return 1.0
	if shape_kind == ShapeKind.COMPOUND or other.shape_kind == ShapeKind.COMPOUND:
		return _compound_earliest_swept_overlap_fraction(
			from_position,
			to_position,
			other,
			other_from_position,
			other_to_position,
			bisection_iterations
		)
	if overlaps_at(from_position, other, other_from_position):
		return 0.0
	if not swept_overlaps(
		from_position,
		to_position,
		other,
		other_from_position,
		other_to_position
	):
		return 1.0

	var lower_fraction := 0.0
	var upper_fraction := 1.0
	for _iteration in range(maxi(bisection_iterations, 1)):
		var middle_fraction := (
			lower_fraction + upper_fraction
		) * 0.5
		var middle_position := from_position.lerp(
			to_position,
			middle_fraction
		)
		var other_middle_position := other_from_position.lerp(
			other_to_position,
			middle_fraction
		)
		if swept_overlaps(
			from_position,
			middle_position,
			other,
			other_from_position,
			other_middle_position
		):
			upper_fraction = middle_fraction
		else:
			lower_fraction = middle_fraction
	return clampf(upper_fraction, 0.0, 1.0)


## Conservative variant for an unverified target plan. The target may finish at
## any point along its planned translation (for example after wall/contact
## clipping), so its complete swept volume is treated as one fixed envelope.
## The returned fraction is the earliest prefix of this proxy's path whose
## swept volume touches that envelope. The prefix volume grows monotonically,
## making this bisection safe even when the optimistic synchronized sweep misses.
func get_earliest_overlap_fraction_against_swept_envelope(
	from_position: Vector2,
	to_position: Vector2,
	other: CombatContactShapeProxy,
	other_from_position: Vector2,
	other_to_position: Vector2,
	bisection_iterations: int = DEFAULT_TOI_BISECTION_ITERATIONS
) -> float:
	if (
		not _can_compare(from_position, other, other_from_position)
		or not to_position.is_finite()
		or not other_to_position.is_finite()
	):
		return 1.0
	if shape_kind == ShapeKind.COMPOUND or other.shape_kind == ShapeKind.COMPOUND:
		return _compound_earliest_overlap_fraction_against_swept_envelope(
			from_position,
			to_position,
			other,
			other_from_position,
			other_to_position,
			bisection_iterations
		)
	var other_envelope := other._swept_convex_core(
		other._translated_core(other_from_position),
		other_to_position - other_from_position
	)
	if _path_prefix_overlaps_core_envelope(
		from_position,
		from_position,
		other,
		other_envelope
	):
		return 0.0
	if not _path_prefix_overlaps_core_envelope(
		from_position,
		to_position,
		other,
		other_envelope
	):
		return 1.0
	var lower_fraction := 0.0
	var upper_fraction := 1.0
	for _iteration in range(maxi(bisection_iterations, 1)):
		var middle_fraction := (
			lower_fraction + upper_fraction
		) * 0.5
		if _path_prefix_overlaps_core_envelope(
			from_position,
			from_position.lerp(to_position, middle_fraction),
			other,
			other_envelope
		):
			upper_fraction = middle_fraction
		else:
			lower_fraction = middle_fraction
	return clampf(upper_fraction, 0.0, 1.0)


func _path_prefix_overlaps_core_envelope(
	from_position: Vector2,
	to_position: Vector2,
	other: CombatContactShapeProxy,
	other_envelope: PackedVector2Array
) -> bool:
	var source_envelope := _swept_convex_core(
		_translated_core(from_position),
		to_position - from_position
	)
	return _cores_overlap_with_radius(
		source_envelope,
		other_envelope,
		core_radius + other.core_radius
	)


static func status_to_name(value: int) -> StringName:
	match value:
		SupportStatus.SUPPORTED:
			return &"SUPPORTED"
		SupportStatus.NULL_SHAPE:
			return &"NULL_SHAPE"
		SupportStatus.UNSUPPORTED_SHAPE:
			return &"UNSUPPORTED_SHAPE"
		SupportStatus.INVALID_GEOMETRY:
			return &"INVALID_GEOMETRY"
		SupportStatus.NON_FINITE_TRANSFORM:
			return &"NON_FINITE_TRANSFORM"
		SupportStatus.NON_UNIFORM_SCALE:
			return &"NON_UNIFORM_SCALE"
		SupportStatus.SHEARED_TRANSFORM:
			return &"SHEARED_TRANSFORM"
		SupportStatus.REFLECTED_TRANSFORM:
			return &"REFLECTED_TRANSFORM"
		SupportStatus.ROTATION_CHANGED:
			return &"ROTATION_CHANGED"
		SupportStatus.SCALE_CHANGED:
			return &"SCALE_CHANGED"
	return &"UNKNOWN"


func _capture(shape: Shape2D, world_transform: Transform2D) -> void:
	shape_kind = ShapeKind.UNSUPPORTED
	support_status = SupportStatus.NULL_SHAPE
	_core_offsets.clear()
	_compound_children.clear()
	_compound_child_anchor_offsets.clear()
	core_radius = 0.0
	if shape == null:
		return
	support_status = _validate_basis(world_transform)
	if support_status != SupportStatus.SUPPORTED:
		return
	capture_position = world_transform.origin
	capture_rotation = world_transform.get_rotation()
	capture_scale = world_transform.x.length()

	var local_core := PackedVector2Array()
	var local_radius := 0.0
	if shape is CircleShape2D:
		var circle := shape as CircleShape2D
		if not is_finite(circle.radius) or circle.radius < 0.0:
			support_status = SupportStatus.INVALID_GEOMETRY
			return
		shape_kind = ShapeKind.CIRCLE
		local_core.append(Vector2.ZERO)
		local_radius = circle.radius
	elif shape is CapsuleShape2D:
		var capsule := shape as CapsuleShape2D
		if (
			not is_finite(capsule.radius)
			or not is_finite(capsule.height)
			or capsule.radius < 0.0
			or capsule.height < 0.0
		):
			support_status = SupportStatus.INVALID_GEOMETRY
			return
		shape_kind = ShapeKind.CAPSULE
		var half_core_length := maxf(capsule.height * 0.5 - capsule.radius, 0.0)
		local_core.append(Vector2(0.0, -half_core_length))
		local_core.append(Vector2(0.0, half_core_length))
		local_radius = capsule.radius
	elif shape is RectangleShape2D:
		var rectangle := shape as RectangleShape2D
		if (
			not rectangle.size.is_finite()
			or rectangle.size.x < 0.0
			or rectangle.size.y < 0.0
		):
			support_status = SupportStatus.INVALID_GEOMETRY
			return
		shape_kind = ShapeKind.RECTANGLE
		var half_size := rectangle.size * 0.5
		local_core = PackedVector2Array([
			Vector2(-half_size.x, -half_size.y),
			Vector2(half_size.x, -half_size.y),
			Vector2(half_size.x, half_size.y),
			Vector2(-half_size.x, half_size.y),
		])
	elif shape is ConvexPolygonShape2D:
		var convex := shape as ConvexPolygonShape2D
		if convex.points.size() < 3:
			support_status = SupportStatus.INVALID_GEOMETRY
			return
		for point in convex.points:
			if not point.is_finite():
				support_status = SupportStatus.INVALID_GEOMETRY
				return
		shape_kind = ShapeKind.CONVEX_POLYGON
		local_core = Geometry2D.convex_hull(convex.points)
		_remove_closed_hull_duplicate(local_core)
		if local_core.size() < 3:
			support_status = SupportStatus.INVALID_GEOMETRY
			return
	elif shape is SegmentShape2D:
		var segment := shape as SegmentShape2D
		if not segment.a.is_finite() or not segment.b.is_finite():
			support_status = SupportStatus.INVALID_GEOMETRY
			return
		shape_kind = ShapeKind.SEGMENT
		local_core.append(segment.a)
		local_core.append(segment.b)
	else:
		support_status = SupportStatus.UNSUPPORTED_SHAPE
		return

	for local_point in local_core:
		_core_offsets.append(world_transform.basis_xform(local_point))
	core_radius = local_radius * capture_scale
	if _core_offsets.is_empty() or not is_finite(core_radius):
		support_status = SupportStatus.INVALID_GEOMETRY
		shape_kind = ShapeKind.UNSUPPORTED
		return
	_recalculate_bounds()
	support_status = SupportStatus.SUPPORTED


func _capture_compound(
	shapes: Array[Shape2D],
	world_transforms: Array[Transform2D],
	anchor_transform: Transform2D
) -> void:
	shape_kind = ShapeKind.UNSUPPORTED
	support_status = SupportStatus.NULL_SHAPE
	_core_offsets.clear()
	_compound_children.clear()
	_compound_child_anchor_offsets.clear()
	core_radius = 0.0
	if shapes.is_empty() or shapes.size() != world_transforms.size():
		return
	support_status = _validate_basis(anchor_transform)
	if support_status != SupportStatus.SUPPORTED:
		return
	capture_position = anchor_transform.origin
	capture_rotation = anchor_transform.get_rotation()
	capture_scale = anchor_transform.x.length()
	for child_index in range(shapes.size()):
		var child := create(shapes[child_index], world_transforms[child_index])
		if not child.is_supported():
			support_status = child.support_status
			_compound_children.clear()
			_compound_child_anchor_offsets.clear()
			return
		_compound_children.append(child)
		_compound_child_anchor_offsets.append(
			child.capture_position - capture_position
		)
	shape_kind = ShapeKind.COMPOUND
	_recalculate_compound_bounds()
	support_status = SupportStatus.SUPPORTED


func _validate_basis(world_transform: Transform2D) -> SupportStatus:
	if (
		not world_transform.origin.is_finite()
		or not world_transform.x.is_finite()
		or not world_transform.y.is_finite()
	):
		return SupportStatus.NON_FINITE_TRANSFORM
	var x_length := world_transform.x.length()
	var y_length := world_transform.y.length()
	if x_length <= MIN_SCALE or y_length <= MIN_SCALE:
		return SupportStatus.INVALID_GEOMETRY
	var scale_tolerance := BASIS_EPSILON * maxf(maxf(x_length, y_length), 1.0)
	if absf(x_length - y_length) > scale_tolerance:
		return SupportStatus.NON_UNIFORM_SCALE
	var normalized_dot := absf(
		world_transform.x.dot(world_transform.y) / (x_length * y_length)
	)
	if normalized_dot > BASIS_EPSILON:
		return SupportStatus.SHEARED_TRANSFORM
	if world_transform.determinant() <= 0.0:
		return SupportStatus.REFLECTED_TRANSFORM
	return SupportStatus.SUPPORTED


func _compound_overlaps_at(
	world_position: Vector2,
	other: CombatContactShapeProxy,
	other_world_position: Vector2
) -> bool:
	for self_index in range(_get_union_child_count()):
		var self_child := _get_union_child(self_index)
		var self_position := world_position + _get_union_child_offset(self_index)
		for other_index in range(other._get_union_child_count()):
			var other_child := other._get_union_child(other_index)
			var other_position := (
				other_world_position
				+ other._get_union_child_offset(other_index)
			)
			if self_child.overlaps_at(
				self_position,
				other_child,
				other_position
			):
				return true
	return false


func _compound_swept_overlaps(
	from_position: Vector2,
	to_position: Vector2,
	other: CombatContactShapeProxy,
	other_from_position: Vector2,
	other_to_position: Vector2
) -> bool:
	for self_index in range(_get_union_child_count()):
		var self_child := _get_union_child(self_index)
		var self_offset := _get_union_child_offset(self_index)
		for other_index in range(other._get_union_child_count()):
			var other_child := other._get_union_child(other_index)
			var other_offset := other._get_union_child_offset(other_index)
			if self_child.swept_overlaps(
				from_position + self_offset,
				to_position + self_offset,
				other_child,
				other_from_position + other_offset,
				other_to_position + other_offset
			):
				return true
	return false


func _compound_earliest_swept_overlap_fraction(
	from_position: Vector2,
	to_position: Vector2,
	other: CombatContactShapeProxy,
	other_from_position: Vector2,
	other_to_position: Vector2,
	bisection_iterations: int
) -> float:
	var earliest_fraction := 1.0
	for self_index in range(_get_union_child_count()):
		var self_child := _get_union_child(self_index)
		var self_offset := _get_union_child_offset(self_index)
		for other_index in range(other._get_union_child_count()):
			var other_child := other._get_union_child(other_index)
			var other_offset := other._get_union_child_offset(other_index)
			var self_from := from_position + self_offset
			var self_to := to_position + self_offset
			var other_from := other_from_position + other_offset
			var other_to := other_to_position + other_offset
			if not self_child.swept_overlaps(
				self_from,
				self_to,
				other_child,
				other_from,
				other_to
			):
				continue
			earliest_fraction = minf(
				earliest_fraction,
				self_child.get_earliest_swept_overlap_fraction(
					self_from,
					self_to,
					other_child,
					other_from,
					other_to,
					bisection_iterations
				)
			)
	return earliest_fraction


func _compound_earliest_overlap_fraction_against_swept_envelope(
	from_position: Vector2,
	to_position: Vector2,
	other: CombatContactShapeProxy,
	other_from_position: Vector2,
	other_to_position: Vector2,
	bisection_iterations: int
) -> float:
	var earliest_fraction := 1.0
	for self_index in range(_get_union_child_count()):
		var self_child := _get_union_child(self_index)
		var self_offset := _get_union_child_offset(self_index)
		for other_index in range(other._get_union_child_count()):
			var other_child := other._get_union_child(other_index)
			var other_offset := other._get_union_child_offset(other_index)
			earliest_fraction = minf(
				earliest_fraction,
				self_child.get_earliest_overlap_fraction_against_swept_envelope(
					from_position + self_offset,
					to_position + self_offset,
					other_child,
					other_from_position + other_offset,
					other_to_position + other_offset,
					bisection_iterations
				)
			)
	return earliest_fraction


func _get_union_child_count() -> int:
	return _compound_children.size() if shape_kind == ShapeKind.COMPOUND else 1


func _get_union_child(index: int) -> CombatContactShapeProxy:
	if shape_kind == ShapeKind.COMPOUND:
		return _compound_children[index]
	return self


func _get_union_child_offset(index: int) -> Vector2:
	if shape_kind == ShapeKind.COMPOUND:
		return _compound_child_anchor_offsets[index]
	return Vector2.ZERO


func _can_compare(
	world_position: Vector2,
	other: CombatContactShapeProxy,
	other_world_position: Vector2
) -> bool:
	return (
		is_supported()
		and other != null
		and other.is_supported()
		and world_position.is_finite()
		and other_world_position.is_finite()
	)


func _translated_core(world_position: Vector2) -> PackedVector2Array:
	var result := PackedVector2Array()
	result.resize(_core_offsets.size())
	for index in range(_core_offsets.size()):
		result[index] = world_position + _core_offsets[index]
	return result


func _swept_convex_core(
	start_core: PackedVector2Array,
	displacement: Vector2
) -> PackedVector2Array:
	if displacement.is_zero_approx():
		return start_core
	var combined := PackedVector2Array()
	combined.resize(start_core.size() * 2)
	for index in range(start_core.size()):
		combined[index] = start_core[index]
		combined[index + start_core.size()] = start_core[index] + displacement
	if combined.size() <= 2:
		return combined
	var hull := Geometry2D.convex_hull(combined)
	_remove_closed_hull_duplicate(hull)
	return hull


func _cores_overlap_with_radius(
	first: PackedVector2Array,
	second: PackedVector2Array,
	combined_radius: float
) -> bool:
	if first.is_empty() or second.is_empty():
		return false
	var distance_squared := _convex_core_distance_squared(first, second)
	var safe_radius := maxf(combined_radius, 0.0)
	return distance_squared <= safe_radius * safe_radius + DISTANCE_EPSILON


func _convex_core_distance_squared(
	first: PackedVector2Array,
	second: PackedVector2Array
) -> float:
	if _cores_intersect(first, second):
		return 0.0
	var nearest_squared := INF
	if first.size() == 1 and second.size() == 1:
		return first[0].distance_squared_to(second[0])
	for point in first:
		nearest_squared = minf(
			nearest_squared,
			_point_to_core_distance_squared(point, second)
		)
	for point in second:
		nearest_squared = minf(
			nearest_squared,
			_point_to_core_distance_squared(point, first)
		)
	return nearest_squared


func _cores_intersect(
	first: PackedVector2Array,
	second: PackedVector2Array
) -> bool:
	if first.size() >= 3 and Geometry2D.is_point_in_polygon(second[0], first):
		return true
	if second.size() >= 3 and Geometry2D.is_point_in_polygon(first[0], second):
		return true
	var first_edges := _get_core_edges(first)
	var second_edges := _get_core_edges(second)
	for first_edge in first_edges:
		for second_edge in second_edges:
			if _segments_touch_or_cross(
				first_edge[0],
				first_edge[1],
				second_edge[0],
				second_edge[1]
			):
				return true
	return false


func _point_to_core_distance_squared(
	point: Vector2,
	core: PackedVector2Array
) -> float:
	if core.size() == 1:
		return point.distance_squared_to(core[0])
	if core.size() >= 3 and Geometry2D.is_point_in_polygon(point, core):
		return 0.0
	var nearest_squared := INF
	for edge in _get_core_edges(core):
		var closest := Geometry2D.get_closest_point_to_segment(
			point,
			edge[0],
			edge[1]
		)
		nearest_squared = minf(nearest_squared, point.distance_squared_to(closest))
	return nearest_squared


func _get_core_edges(core: PackedVector2Array) -> Array[PackedVector2Array]:
	var result: Array[PackedVector2Array] = []
	if core.size() < 2:
		return result
	if core.size() == 2:
		result.append(PackedVector2Array([core[0], core[1]]))
		return result
	for index in range(core.size()):
		result.append(PackedVector2Array([
			core[index],
			core[(index + 1) % core.size()],
		]))
	return result


func _segments_touch_or_cross(
	first_a: Vector2,
	first_b: Vector2,
	second_a: Vector2,
	second_b: Vector2
) -> bool:
	var first_closest := Geometry2D.get_closest_point_to_segment(
		first_a,
		second_a,
		second_b
	)
	if first_a.distance_squared_to(first_closest) <= DISTANCE_EPSILON:
		return true
	var first_b_closest := Geometry2D.get_closest_point_to_segment(
		first_b,
		second_a,
		second_b
	)
	if first_b.distance_squared_to(first_b_closest) <= DISTANCE_EPSILON:
		return true
	var second_closest := Geometry2D.get_closest_point_to_segment(
		second_a,
		first_a,
		first_b
	)
	if second_a.distance_squared_to(second_closest) <= DISTANCE_EPSILON:
		return true
	var second_b_closest := Geometry2D.get_closest_point_to_segment(
		second_b,
		first_a,
		first_b
	)
	if second_b.distance_squared_to(second_b_closest) <= DISTANCE_EPSILON:
		return true
	return Geometry2D.segment_intersects_segment(
		first_a,
		first_b,
		second_a,
		second_b
	) != null


func _recalculate_bounds() -> void:
	_minimum_offset = _core_offsets[0]
	_maximum_offset = _core_offsets[0]
	for point in _core_offsets:
		_minimum_offset.x = minf(_minimum_offset.x, point.x)
		_minimum_offset.y = minf(_minimum_offset.y, point.y)
		_maximum_offset.x = maxf(_maximum_offset.x, point.x)
		_maximum_offset.y = maxf(_maximum_offset.y, point.y)


func _recalculate_compound_bounds() -> void:
	if _compound_children.is_empty():
		_minimum_offset = Vector2.ZERO
		_maximum_offset = Vector2.ZERO
		return
	var merged_aabb := _compound_children[0].get_world_aabb_at(
		_compound_child_anchor_offsets[0]
	)
	for child_index in range(1, _compound_children.size()):
		merged_aabb = merged_aabb.merge(
			_compound_children[child_index].get_world_aabb_at(
				_compound_child_anchor_offsets[child_index]
			)
		)
	_minimum_offset = merged_aabb.position
	_maximum_offset = merged_aabb.end


static func _remove_closed_hull_duplicate(points: PackedVector2Array) -> void:
	if points.size() >= 2 and points[0].is_equal_approx(points[points.size() - 1]):
		points.resize(points.size() - 1)
