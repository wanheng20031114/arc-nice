extends RefCounted
class_name RogueEncounterRegistry

const MAGICAL_ENCOUNTER_POOL := &"magical_encounter"
const CHICKEN_BRO := &"chicken_bro"

const _POOLS := {
	MAGICAL_ENCOUNTER_POOL: [CHICKEN_BRO],
}


static func select_encounter(
	content_pool_id: StringName,
	node_content_seed: int
) -> StringName:
	var raw_entries: Variant = _POOLS.get(content_pool_id)
	if typeof(raw_entries) != TYPE_ARRAY:
		return &""
	var entries := raw_entries as Array
	if entries.is_empty():
		return &""
	var index := RogueEncounterRandom.choose_index(
		node_content_seed,
		&"content_selection",
		entries.size()
	)
	return StringName(entries[index])


static func has_pool(content_pool_id: StringName) -> bool:
	return _POOLS.has(content_pool_id)


static func get_pool_entries(content_pool_id: StringName) -> Array[StringName]:
	var result: Array[StringName] = []
	var raw_entries: Variant = _POOLS.get(content_pool_id)
	if typeof(raw_entries) != TYPE_ARRAY:
		return result
	for entry in raw_entries as Array:
		result.append(StringName(entry))
	return result
