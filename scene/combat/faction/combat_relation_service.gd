extends RefCounted
class_name CombatRelationService

## Stable faction IDs. These values are part of the multiplayer-facing combat
## contract and must not be reordered after release.
const NEUTRAL := 0
const PLAYER_ALLIED := 1
const HOSTILE_WAVE := 2
const MAX := 32
const MAX_FACTION_COUNT := MAX

var _hostile_masks := PackedInt64Array()
var _revision := 0


func _init() -> void:
	_hostile_masks.resize(MAX)
	reset_default_relations()


## Restores the conservative default: only the authored player/wave pair is
## hostile. Future factions remain non-hostile until a mode configures them.
func reset_default_relations() -> void:
	_hostile_masks.fill(0)
	_hostile_masks[PLAYER_ALLIED] = 1 << HOSTILE_WAVE
	_hostile_masks[HOSTILE_WAVE] = 1 << PLAYER_ALLIED
	_revision += 1


## Changes one directed relation. The reverse direction is deliberately left
## untouched. Same-faction hostility is rejected so faction identity remains a
## reliable friendly grouping for indexes and target filters.
func set_hostile(
	source_faction: int,
	target_faction: int,
	hostile: bool = true
) -> bool:
	if (
		not is_valid_faction(source_faction)
		or not is_valid_faction(target_faction)
		or (hostile and source_faction == target_faction)
	):
		return false
	var target_bit := 1 << target_faction
	var was_hostile := (_hostile_masks[source_faction] & target_bit) != 0
	if was_hostile == hostile:
		return true
	if hostile:
		_hostile_masks[source_faction] |= target_bit
	else:
		_hostile_masks[source_faction] &= ~target_bit
	_revision += 1
	return true


func is_hostile(source_faction: int, target_faction: int) -> bool:
	if (
		not is_valid_faction(source_faction)
		or not is_valid_faction(target_faction)
	):
		return false
	return (_hostile_masks[source_faction] & (1 << target_faction)) != 0


## Returns a value copy of the directed row; callers cannot mutate the service's
## internal PackedInt64Array through this API.
func get_hostile_mask(source_faction: int) -> int:
	if not is_valid_faction(source_faction):
		return 0
	return _hostile_masks[source_faction]


func get_revision() -> int:
	return _revision


static func is_default_hostile(source_faction: int, target_faction: int) -> bool:
	return (
		(source_faction == PLAYER_ALLIED and target_faction == HOSTILE_WAVE)
		or (source_faction == HOSTILE_WAVE and target_faction == PLAYER_ALLIED)
	)


static func is_valid_faction(faction: int) -> bool:
	return faction >= NEUTRAL and faction < MAX


static func is_valid_faction_id(faction: int) -> bool:
	return is_valid_faction(faction)


static func normalize_faction_id(faction: int, fallback: int = NEUTRAL) -> int:
	if is_valid_faction_id(faction):
		return faction
	return fallback if is_valid_faction_id(fallback) else NEUTRAL
