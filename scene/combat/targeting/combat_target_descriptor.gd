extends RefCounted
class_name CombatTargetDescriptor

enum Kind {
	NONE,
	PLAYER,
	PLANT,
	ENEMY,
}

const NETWORK_KEY_KIND := "kind"
const NETWORK_KEY_ID := "id"
const NETWORK_KEY_REVISION := "revision"
const NETWORK_KEY_FALLBACK_POSITION := "fallback_position"
var kind: int = Kind.NONE
var id: int = 0
var revision: int = 0
var fallback_position := Vector2.ZERO


static func create_none() -> CombatTargetDescriptor:
	return CombatTargetDescriptor.new()


static func create(
	target_kind: int,
	target_id: int,
	target_revision: int = 0,
	target_fallback_position: Vector2 = Vector2.ZERO
) -> CombatTargetDescriptor:
	var descriptor := CombatTargetDescriptor.new()
	descriptor.kind = target_kind
	descriptor.id = target_id
	descriptor.revision = target_revision
	descriptor.fallback_position = target_fallback_position
	return descriptor if descriptor.is_valid() else null


static func create_player(
	target_id: int,
	target_revision: int = 0,
	target_fallback_position: Vector2 = Vector2.ZERO
) -> CombatTargetDescriptor:
	return create(Kind.PLAYER, target_id, target_revision, target_fallback_position)


static func create_plant(
	target_id: int,
	target_revision: int = 0,
	target_fallback_position: Vector2 = Vector2.ZERO
) -> CombatTargetDescriptor:
	return create(Kind.PLANT, target_id, target_revision, target_fallback_position)


static func create_enemy(
	target_id: int,
	target_revision: int = 0,
	target_fallback_position: Vector2 = Vector2.ZERO
) -> CombatTargetDescriptor:
	return create(Kind.ENEMY, target_id, target_revision, target_fallback_position)


func clear() -> void:
	kind = Kind.NONE
	id = 0
	revision = 0
	fallback_position = Vector2.ZERO


func is_valid() -> bool:
	if not fallback_position.is_finite() or revision < 0:
		return false
	if kind == Kind.NONE:
		return id == 0 and revision == 0 and fallback_position == Vector2.ZERO
	return (
		kind in [Kind.PLAYER, Kind.PLANT, Kind.ENEMY]
		and id > 0
	)


func to_network_dictionary() -> Dictionary:
	if not is_valid():
		return {}
	return {
		NETWORK_KEY_KIND: kind,
		NETWORK_KEY_ID: id,
		NETWORK_KEY_REVISION: revision,
		NETWORK_KEY_FALLBACK_POSITION: fallback_position,
	}


static func from_network_dictionary(payload: Dictionary) -> CombatTargetDescriptor:
	if (
		not payload.has(NETWORK_KEY_KIND)
		or not payload.has(NETWORK_KEY_ID)
		or not payload.has(NETWORK_KEY_REVISION)
		or not payload.has(NETWORK_KEY_FALLBACK_POSITION)
		or typeof(payload[NETWORK_KEY_KIND]) != TYPE_INT
		or typeof(payload[NETWORK_KEY_ID]) != TYPE_INT
		or typeof(payload[NETWORK_KEY_REVISION]) != TYPE_INT
		or typeof(payload[NETWORK_KEY_FALLBACK_POSITION]) != TYPE_VECTOR2
	):
		return null
	var target_kind := int(payload[NETWORK_KEY_KIND])
	var target_id := int(payload[NETWORK_KEY_ID])
	var target_revision := int(payload[NETWORK_KEY_REVISION])
	var target_fallback_position := payload[NETWORK_KEY_FALLBACK_POSITION] as Vector2
	if target_kind == Kind.NONE:
		var empty_descriptor := CombatTargetDescriptor.new()
		empty_descriptor.id = target_id
		empty_descriptor.revision = target_revision
		empty_descriptor.fallback_position = target_fallback_position
		return empty_descriptor if empty_descriptor.is_valid() else null
	return create(
		target_kind,
		target_id,
		target_revision,
		target_fallback_position
	)
