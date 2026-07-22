class_name ProjectileShapeSweep2D
extends RefCounted

const NO_COLLISION_FRACTION := 1.0

var query := PhysicsShapeQueryParameters2D.new()


func configure(shape: Shape2D, collision_mask: int) -> void:
	query.shape = shape
	query.collision_mask = collision_mask
	query.collide_with_bodies = true
	query.collide_with_areas = false
	reset_runtime_state()


func reset_runtime_state() -> void:
	query.motion = Vector2.ZERO
	query.transform = Transform2D.IDENTITY


func cast(
	space_state: PhysicsDirectSpaceState2D,
	shape_transform: Transform2D,
	motion: Vector2
) -> Dictionary:
	query.transform = shape_transform
	query.motion = Vector2.ZERO
	var initial_rest := space_state.get_rest_info(query)
	if not initial_rest.is_empty():
		return _make_result(initial_rest, 0.0)

	query.motion = motion
	var fractions := space_state.cast_motion(query)
	if (
		fractions.size() < 2
		or fractions[1] >= NO_COLLISION_FRACTION
	):
		query.motion = Vector2.ZERO
		return {}

	var unsafe_fraction := clampf(fractions[1], 0.0, 1.0)
	var impact_transform := shape_transform
	impact_transform.origin += motion * unsafe_fraction
	query.transform = impact_transform
	query.motion = Vector2.ZERO
	return _make_result(
		space_state.get_rest_info(query),
		unsafe_fraction
	)


func _make_result(rest_info: Dictionary, fraction: float) -> Dictionary:
	if rest_info.is_empty():
		return {"fraction": fraction}
	var collider_id := int(rest_info.get("collider_id", 0))
	return {
		"collider": instance_from_id(collider_id) if collider_id > 0 else null,
		"fraction": fraction,
	}
