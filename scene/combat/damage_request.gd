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
var source_snapshot: DamageSourceSnapshot = null
var source_snapshot_is_explicit := false
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
	source_snapshot = null
	source_snapshot_is_explicit = false
	if (
		new_source != null
		and is_instance_valid(new_source)
		and new_source.has_method(&"create_damage_source_snapshot")
	):
		var captured: Variant = new_source.call(
			&"create_damage_source_snapshot",
			new_source_id,
			new_source_type
		)
		if captured is DamageSourceSnapshot:
			with_source_snapshot(captured as DamageSourceSnapshot)
			source = new_source
	return self


func with_stable_source(
	new_source_enemy_id: int,
	new_source_projectile_id: int,
	new_source_type: StringName,
	new_source_snapshot: DamageSourceSnapshot = null
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
	source_snapshot = null
	source_snapshot_is_explicit = false
	if new_source_snapshot != null:
		with_source_snapshot(new_source_snapshot)
		# Stable data-oriented identities remain the canonical diagnostic fields;
		# the frozen snapshot supplies faction/credit and the event identity used
		# by admission, dedupe and reward settlement.
		source_enemy_id = maxi(new_source_enemy_id, 0)
		source_projectile_id = maxi(new_source_projectile_id, 0)
		source_id = (
			source_projectile_id
			if source_projectile_id > 0
			else source_enemy_id
		)
	return self


func with_source_snapshot(
	new_source_snapshot: DamageSourceSnapshot
) -> DamageRequest:
	source_snapshot = (
		new_source_snapshot.duplicate_snapshot()
		if new_source_snapshot != null
		else null
	)
	source_snapshot_is_explicit = new_source_snapshot != null
	if source_snapshot != null:
		source_id = source_snapshot.event_source_id
		source_type = source_snapshot.source_type
	return self


## Freezes legacy requests as player-owned on first authoritative inspection.
## The retained snapshot prevents later caller or faction mutation from changing
## admission, defeat credit or delayed settlement.
func get_or_create_source_snapshot() -> DamageSourceSnapshot:
	if source_snapshot == null:
		source_snapshot = DamageSourceSnapshot.legacy_player_owned(
			maxi(source_id, 0),
			source_type,
			0,
			_get_source_entity_id()
		)
	return source_snapshot


func get_source_snapshot_copy() -> DamageSourceSnapshot:
	return get_or_create_source_snapshot().duplicate_snapshot()


func _get_source_entity_id() -> int:
	if source == null or not is_instance_valid(source):
		return 0
	return maxi(int(source.get_meta(&"net_id", source.get_instance_id())), 0)


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
