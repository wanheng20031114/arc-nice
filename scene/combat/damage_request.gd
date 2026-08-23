extends RefCounted
class_name DamageRequest

## Immutable-by-convention input to every authoritative damage sink. GDScript
## int is signed int64 and remains the runtime combat representation; fixed-width
## network boundaries validate separately before serialization.
var amount: int = 0
var damage_type: int = CombatTypes.DamageType.PHYSICAL
var source: Node = null
var source_id: int = 0
## Stable identities for data-oriented attacks. They deliberately do not imply
## a live Node and remain valid after an enemy or projectile visual is retired.
## `source_id` stays as the compatibility projection used by older sinks.
var source_enemy_id: int = 0
var source_projectile_id: int = 0
var source_type: StringName = &""
var impact_direction: Vector2 = Vector2.ZERO
var source_direction: Vector2 = Vector2.ZERO
var flags: int = 0


func _init(
	initial_amount: int = 0,
	initial_damage_type: int = CombatTypes.DamageType.PHYSICAL
) -> void:
	amount = initial_amount
	damage_type = CombatTypes.normalize_damage_type(initial_damage_type)


func with_source(
	new_source: Node,
	new_source_id: int = 0,
	new_source_type: StringName = &""
) -> DamageRequest:
	source = new_source
	source_id = new_source_id
	source_enemy_id = 0
	source_projectile_id = 0
	source_type = new_source_type
	return self


func with_stable_source(
	new_source_enemy_id: int,
	new_source_projectile_id: int,
	new_source_type: StringName
) -> DamageRequest:
	source = null
	source_enemy_id = maxi(new_source_enemy_id, 0)
	source_projectile_id = maxi(new_source_projectile_id, 0)
	source_id = (
		source_projectile_id
		if source_projectile_id > 0
		else source_enemy_id
	)
	source_type = new_source_type
	return self


func with_directions(
	new_impact_direction: Vector2,
	new_source_direction: Vector2 = Vector2.ZERO
) -> DamageRequest:
	impact_direction = _normalized_or_zero(new_impact_direction)
	source_direction = _normalized_or_zero(new_source_direction)
	return self


func with_flag(flag: int, enabled: bool = true) -> DamageRequest:
	if enabled:
		flags |= flag
	else:
		flags &= ~flag
	return self


func has_flag(flag: int) -> bool:
	return CombatTypes.has_flag(flags, flag)


func get_safe_impact_direction() -> Vector2:
	return _normalized_or_zero(impact_direction)


func get_safe_source_direction() -> Vector2:
	return _normalized_or_zero(source_direction)


static func _normalized_or_zero(direction: Vector2) -> Vector2:
	if not direction.is_finite() or direction.length_squared() <= 0.001:
		return Vector2.ZERO
	return direction.normalized()
