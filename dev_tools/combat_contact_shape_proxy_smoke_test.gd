extends SceneTree

const PROXY := preload(
	"res://scene/combat/contact/combat_contact_shape_proxy.gd"
)

var failures: Array[String] = []


func _init() -> void:
	_test_supported_shape_boundaries()
	_test_translation_sweeps()
	_test_earliest_swept_overlap_fraction()
	_test_non_convex_compound_union()
	_test_transform_rejections()
	_test_fixed_seed_circle_sweeps()
	if failures.is_empty():
		print("COMBAT_CONTACT_SHAPE_PROXY_SMOKE_TEST_OK")
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	quit(1)


func _test_supported_shape_boundaries() -> void:
	var circle_a := CircleShape2D.new()
	circle_a.radius = 4.0
	var circle_b := CircleShape2D.new()
	circle_b.radius = 6.0
	var circle_a_proxy = PROXY.create(circle_a)
	var circle_b_proxy = PROXY.create(circle_b)
	_expect(circle_a_proxy.is_supported(), "CircleShape2D must be supported.")
	_expect(
		circle_a_proxy.overlaps_at(Vector2.ZERO, circle_b_proxy, Vector2(10.0, 0.0)),
		"Closed circle boundaries must count as contact."
	)
	_expect(
		not circle_a_proxy.overlaps_at(
			Vector2.ZERO,
			circle_b_proxy,
			Vector2(10.01, 0.0)
		),
		"Separated circles must not report contact."
	)

	var capsule := CapsuleShape2D.new()
	capsule.radius = 2.0
	capsule.height = 10.0
	var capsule_proxy = PROXY.create(capsule)
	_expect(capsule_proxy.is_supported(), "CapsuleShape2D must be supported.")
	_expect(
		capsule_proxy.overlaps_at(Vector2.ZERO, circle_a_proxy, Vector2(6.0, 0.0)),
		"Capsule-to-circle tangency must use the exact rounded core radius."
	)
	_expect(
		not capsule_proxy.overlaps_at(Vector2.ZERO, circle_a_proxy, Vector2(6.02, 0.0)),
		"Capsule-to-circle separation must be rejected."
	)

	var rectangle := RectangleShape2D.new()
	rectangle.size = Vector2(10.0, 4.0)
	var rectangle_proxy = PROXY.create(rectangle)
	_expect(rectangle_proxy.is_supported(), "RectangleShape2D must be supported.")
	_expect(
		rectangle_proxy.overlaps_at(Vector2.ZERO, circle_a_proxy, Vector2(9.0, 0.0)),
		"Rectangle-to-circle edge tangency must count as contact."
	)
	_expect(
		not rectangle_proxy.overlaps_at(Vector2.ZERO, circle_a_proxy, Vector2(9.02, 0.0)),
		"Rectangle-to-circle separation must be rejected."
	)

	var convex := ConvexPolygonShape2D.new()
	convex.points = PackedVector2Array([
		Vector2(-3.0, -3.0),
		Vector2(3.0, -3.0),
		Vector2(0.0, 3.0),
	])
	var convex_proxy = PROXY.create(convex)
	_expect(convex_proxy.is_supported(), "ConvexPolygonShape2D must be supported.")
	_expect(
		convex_proxy.overlaps_at(Vector2.ZERO, rectangle_proxy, Vector2.ZERO),
		"Overlapping convex polygon and rectangle cores must be detected."
	)

	var segment := SegmentShape2D.new()
	segment.a = Vector2(-8.0, 0.0)
	segment.b = Vector2(8.0, 0.0)
	var segment_proxy = PROXY.create(segment)
	_expect(segment_proxy.is_supported(), "SegmentShape2D must be supported.")
	_expect(
		segment_proxy.overlaps_at(Vector2.ZERO, rectangle_proxy, Vector2.ZERO),
		"A segment crossing a rectangle must be detected."
	)
	_expect(
		not segment_proxy.overlaps_at(Vector2(0.0, 3.0), rectangle_proxy, Vector2.ZERO),
		"A segment outside the rectangle boundary must remain separated."
	)

	var rotated_proxy = PROXY.create(
		rectangle,
		Transform2D(PI * 0.5, Vector2(12.0, -7.0))
	)
	var rotated_aabb: Rect2 = rotated_proxy.get_world_aabb_at(Vector2(12.0, -7.0))
	_expect(
		rotated_aabb.size.is_equal_approx(Vector2(4.0, 10.0)),
		"Captured rotation must be reflected in the immutable proxy AABB."
	)


func _test_translation_sweeps() -> void:
	var circle := CircleShape2D.new()
	circle.radius = 2.0
	var circle_proxy = PROXY.create(circle)
	var rectangle := RectangleShape2D.new()
	rectangle.size = Vector2(4.0, 12.0)
	var rectangle_proxy = PROXY.create(rectangle)
	_expect(
		circle_proxy.swept_overlaps(
			Vector2(-20.0, 0.0),
			Vector2(20.0, 0.0),
			rectangle_proxy,
			Vector2.ZERO,
			Vector2.ZERO
		),
		"A fast circle crossing a rectangle between endpoints must not tunnel."
	)
	_expect(
		not circle_proxy.swept_overlaps(
			Vector2(-20.0, 9.0),
			Vector2(20.0, 9.0),
			rectangle_proxy,
			Vector2.ZERO,
			Vector2.ZERO
		),
		"A swept circle outside the expanded rectangle must not false-positive."
	)
	_expect(
		not circle_proxy.swept_overlaps(
			Vector2(-20.0, 0.0),
			Vector2(20.0, 0.0),
			circle_proxy,
			Vector2(-20.0, 8.0),
			Vector2(20.0, 8.0)
		),
		"Equal parallel motion must be reduced to its unchanged relative separation."
	)
	_expect(
		circle_proxy.swept_overlaps(
			Vector2(-10.0, 0.0),
			Vector2(10.0, 0.0),
			circle_proxy,
			Vector2(10.0, 0.0),
			Vector2(-10.0, 0.0)
		),
		"Two fast movers crossing in opposite directions must collide."
	)
	var swept_aabb: Rect2 = circle_proxy.get_swept_world_aabb(
		Vector2(-20.0, 0.0),
		Vector2(20.0, 0.0)
	)
	_expect(
		swept_aabb == Rect2(Vector2(-22.0, -2.0), Vector2(44.0, 4.0)),
		"Swept AABB must cover both translated endpoints and the round radius."
	)


func _test_earliest_swept_overlap_fraction() -> void:
	var circle := CircleShape2D.new()
	circle.radius = 2.0
	var proxy = PROXY.create(circle)
	var opposing_fraction: float = proxy.get_earliest_swept_overlap_fraction(
		Vector2(-10.0, 0.0),
		Vector2(10.0, 0.0),
		proxy,
		Vector2(10.0, 0.0),
		Vector2(-10.0, 0.0)
	)
	_expect(
		absf(opposing_fraction - 0.4) <= 0.00002,
		"Opposing fast circles must resolve the analytic first-contact fraction."
	)
	var static_fraction: float = proxy.get_earliest_swept_overlap_fraction(
		Vector2(-10.0, 0.0),
		Vector2(10.0, 0.0),
		proxy,
		Vector2.ZERO,
		Vector2.ZERO
	)
	_expect(
		absf(static_fraction - 0.3) <= 0.00002,
		"A fast mover crossing a static circle must stop at the first shell boundary."
	)
	_expect(
		is_zero_approx(proxy.get_earliest_swept_overlap_fraction(
			Vector2.ZERO,
			Vector2(20.0, 0.0),
			proxy,
			Vector2(3.0, 0.0),
			Vector2(3.0, 0.0)
		)),
		"A sweep that starts overlapped must return a zero safe fraction."
	)
	_expect(
		is_equal_approx(proxy.get_earliest_swept_overlap_fraction(
			Vector2(-10.0, 10.0),
			Vector2(10.0, 10.0),
			proxy,
			Vector2.ZERO,
			Vector2.ZERO
		), 1.0),
		"A separated sweep must preserve the complete safe fraction."
	)
	_expect(
		not proxy.swept_overlaps(
			Vector2.ZERO,
			Vector2(10.0, 0.0),
			proxy,
			Vector2(13.0, 0.0),
			Vector2(21.0, 0.0)
		)
		and absf(
			proxy.get_earliest_overlap_fraction_against_swept_envelope(
				Vector2.ZERO,
				Vector2(10.0, 0.0),
				proxy,
				Vector2(13.0, 0.0),
				Vector2(21.0, 0.0)
			) - 0.9
		) <= 0.00002,
		"An uncertified target moving away must retain its stationary-start envelope."
	)


func _test_non_convex_compound_union() -> void:
	var child_shape_a := CircleShape2D.new()
	child_shape_a.radius = 2.0
	var child_shape_b := CircleShape2D.new()
	child_shape_b.radius = 2.0
	var compound_shapes: Array[Shape2D] = [child_shape_a, child_shape_b]
	var compound_transforms: Array[Transform2D] = [
		Transform2D(0.0, Vector2(-10.0, 0.0)),
		Transform2D(0.0, Vector2(10.0, 0.0)),
	]
	var compound = PROXY.create_compound(
		compound_shapes,
		compound_transforms,
		Transform2D.IDENTITY
	)
	var target_shape := CircleShape2D.new()
	target_shape.radius = 1.0
	var target = PROXY.create(target_shape)
	_expect(
		compound.is_supported()
		and compound.shape_kind == PROXY.ShapeKind.COMPOUND
		and compound.get_compound_child_count() == 2
		and compound.get_world_aabb_at(Vector2.ZERO)
			== Rect2(Vector2(-12.0, -2.0), Vector2(24.0, 4.0)),
		"Compound capture must preserve both root-relative children and merge their AABBs."
	)
	_expect(
		not compound.overlaps_at(Vector2.ZERO, target, Vector2.ZERO),
		"Compound contact must remain a non-convex union instead of filling the gap between children."
	)
	_expect(
		compound.overlaps_at(Vector2.ZERO, target, Vector2(-7.0, 0.0)),
		"Any touching compound child must admit current contact."
	)
	var target_compound_shapes: Array[Shape2D] = [target_shape]
	var target_compound_transforms: Array[Transform2D] = [
		Transform2D.IDENTITY,
	]
	var target_compound = PROXY.create_compound(
		target_compound_shapes,
		target_compound_transforms,
		Transform2D.IDENTITY
	)
	var earliest := compound.get_earliest_swept_overlap_fraction(
		Vector2.ZERO,
		Vector2(20.0, 0.0),
		target_compound,
		Vector2.ZERO,
		Vector2.ZERO
	)
	_expect(
		compound.swept_overlaps(
			Vector2.ZERO,
			Vector2(20.0, 0.0),
			target_compound,
			Vector2.ZERO,
			Vector2.ZERO
		)
		and absf(earliest - 0.35) <= 0.00002,
		"Compound sweep and TOI must select the earliest real child-pair hit."
	)
	var unsupported_shapes: Array[Shape2D] = [
		child_shape_a,
		WorldBoundaryShape2D.new(),
	]
	var unsupported_transforms: Array[Transform2D] = [
		Transform2D.IDENTITY,
		Transform2D.IDENTITY,
	]
	var unsupported = PROXY.create_compound(
		unsupported_shapes,
		unsupported_transforms,
		Transform2D.IDENTITY
	)
	_expect(
		not unsupported.is_supported()
		and unsupported.support_status == PROXY.SupportStatus.UNSUPPORTED_SHAPE,
		"One unsupported compound child must fail the complete capture closed."
	)


func _test_transform_rejections() -> void:
	var circle := CircleShape2D.new()
	circle.radius = 4.0
	var non_uniform = PROXY.create(
		circle,
		Transform2D(Vector2(2.0, 0.0), Vector2(0.0, 1.0), Vector2.ZERO)
	)
	_expect(
		non_uniform.support_status == PROXY.SupportStatus.NON_UNIFORM_SCALE,
		"Non-uniform scale must be an explicit unsupported status."
	)
	var reflected = PROXY.create(
		circle,
		Transform2D(Vector2(-1.0, 0.0), Vector2(0.0, 1.0), Vector2.ZERO)
	)
	_expect(
		reflected.support_status == PROXY.SupportStatus.REFLECTED_TRANSFORM,
		"Reflected transforms must not be silently approximated."
	)
	var captured = PROXY.create(circle, Transform2D(0.25, Vector2.ZERO))
	_expect(
		captured.validate_translation_transform(
			Transform2D(0.35, Vector2(50.0, 10.0))
		) == PROXY.SupportStatus.ROTATION_CHANGED,
		"Rotation changes after capture must return ROTATION_CHANGED."
	)
	_expect(
		captured.validate_translation_transform(
			Transform2D(0.25, Vector2(2.0, 2.0), 0.0, Vector2(50.0, 10.0))
		) == PROXY.SupportStatus.SCALE_CHANGED,
		"Uniform scale changes after capture must return SCALE_CHANGED."
	)
	var unsupported = PROXY.create(WorldBoundaryShape2D.new())
	_expect(
		unsupported.support_status == PROXY.SupportStatus.UNSUPPORTED_SHAPE,
		"Unlisted Shape2D families must fail closed with UNSUPPORTED_SHAPE."
	)


func _test_fixed_seed_circle_sweeps() -> void:
	var random := RandomNumberGenerator.new()
	random.seed = 0x5EED_C011
	for sample in range(256):
		var first_shape := CircleShape2D.new()
		first_shape.radius = random.randf_range(0.5, 8.0)
		var second_shape := CircleShape2D.new()
		second_shape.radius = random.randf_range(0.5, 8.0)
		var first_from := Vector2(
			random.randf_range(-40.0, 40.0),
			random.randf_range(-40.0, 40.0)
		)
		var first_to := Vector2(
			random.randf_range(-40.0, 40.0),
			random.randf_range(-40.0, 40.0)
		)
		var second_from := Vector2(
			random.randf_range(-40.0, 40.0),
			random.randf_range(-40.0, 40.0)
		)
		var second_to := Vector2(
			random.randf_range(-40.0, 40.0),
			random.randf_range(-40.0, 40.0)
		)
		var first_proxy = PROXY.create(first_shape)
		var second_proxy = PROXY.create(second_shape)
		var relative_from := first_from - second_from
		var relative_to := first_to - second_to
		var closest := Geometry2D.get_closest_point_to_segment(
			Vector2.ZERO,
			relative_from,
			relative_to
		)
		var combined_radius := first_shape.radius + second_shape.radius
		var expected := closest.length_squared() <= combined_radius * combined_radius + 0.00001
		var actual := first_proxy.swept_overlaps(
			first_from,
			first_to,
			second_proxy,
			second_from,
			second_to
		)
		_expect(
			actual == expected,
			"Fixed-seed circle sweep %d must match the analytic result." % sample
		)
		_expect(
			actual == second_proxy.swept_overlaps(
				second_from,
				second_to,
				first_proxy,
				first_from,
				first_to
			),
			"Fixed-seed circle sweep %d must be symmetric." % sample
		)


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
