extends RefCounted
class_name DamageSourceSnapshot

## Value-only attribution captured when an attack or status is created.
##
## The fields intentionally contain no Object references: a projectile or
## delayed status therefore keeps its launch faction and credit owner even if
## the instigator later changes faction or leaves the tree. Instances are
## immutable by convention; APIs accepting a snapshot always retain a copy.

const LEGACY_SOURCE_TYPE := &"legacy_player_owned"

var source_faction_id: int = CombatRelationService.PLAYER_ALLIED
var credit_peer_id: int = 0
var instigator_entity_id: int = 0
var event_source_id: int = 0
var source_type: StringName = LEGACY_SOURCE_TYPE


static func create(
	initial_source_faction_id: int,
	initial_credit_peer_id: int = 0,
	initial_instigator_entity_id: int = 0,
	initial_event_source_id: int = 0,
	initial_source_type: StringName = &""
) -> DamageSourceSnapshot:
	var snapshot := DamageSourceSnapshot.new()
	snapshot.source_faction_id = initial_source_faction_id
	snapshot.credit_peer_id = initial_credit_peer_id
	snapshot.instigator_entity_id = initial_instigator_entity_id
	snapshot.event_source_id = initial_event_source_id
	snapshot.source_type = initial_source_type
	return snapshot


static func legacy_player_owned(
	initial_event_source_id: int = 0,
	initial_source_type: StringName = LEGACY_SOURCE_TYPE,
	initial_credit_peer_id: int = 0,
	initial_instigator_entity_id: int = 0
) -> DamageSourceSnapshot:
	return create(
		CombatRelationService.PLAYER_ALLIED,
		initial_credit_peer_id,
		initial_instigator_entity_id,
		initial_event_source_id,
		initial_source_type if initial_source_type != &"" else LEGACY_SOURCE_TYPE
	)


func duplicate_snapshot() -> DamageSourceSnapshot:
	return create(
		source_faction_id,
		credit_peer_id,
		instigator_entity_id,
		event_source_id,
		source_type
	)


func is_valid() -> bool:
	return (
		CombatRelationService.is_valid_faction_id(source_faction_id)
		and credit_peer_id >= 0
		and instigator_entity_id >= 0
		and event_source_id >= 0
	)


func is_player_allied() -> bool:
	return (
		is_valid()
		and source_faction_id == CombatRelationService.PLAYER_ALLIED
	)
