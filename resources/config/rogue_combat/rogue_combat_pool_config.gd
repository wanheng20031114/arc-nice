@tool
extends Resource
class_name RogueCombatPoolConfig

const RUNTIME_CONTRACT_SCHEMA := 1
const POOL_ENTRY_SCRIPT := preload(
	"res://resources/config/rogue_combat/rogue_combat_pool_entry.gd"
)
const ENCOUNTER_RANDOM_SCRIPT := preload(
	"res://scene/game_modes/rogue/encounter/rogue_encounter_random.gd"
)

@export var pool_id: StringName = &""
@export var entries: Array[POOL_ENTRY_SCRIPT] = []


func validate_config() -> PackedStringArray:
	var errors := PackedStringArray()
	if pool_id == &"":
		errors.append("普通作战池缺少 pool_id。")
	if entries.is_empty():
		errors.append("普通作战池至少需要一个条目。")
	var seen_ids: Dictionary = {}
	for index in range(entries.size()):
		var entry := entries[index]
		if entry == null:
			errors.append("普通作战池第%d项为空。" % (index + 1))
			continue
		errors.append_array(entry.validate_entry())
		if entry.combat_config == null:
			continue
		var config_id := entry.combat_config.encounter_id
		if config_id == &"":
			continue
		if seen_ids.has(config_id):
			errors.append("普通作战池包含重复 ID：%s。" % String(config_id))
		else:
			seen_ids[config_id] = true
	return errors


func is_ready_to_enable() -> bool:
	return validate_config().is_empty()


func get_sorted_entries() -> Array[POOL_ENTRY_SCRIPT]:
	var result: Array[POOL_ENTRY_SCRIPT] = []
	for entry in entries:
		if entry != null:
			result.append(entry)
	result.sort_custom(_entry_less)
	return result


func get_combat_config(config_id: StringName) -> RogueCombatEncounterConfig:
	if config_id == &"":
		return null
	for entry in entries:
		if (
			entry != null
			and entry.combat_config != null
			and entry.combat_config.encounter_id == config_id
		):
			return entry.combat_config
	return null


func select_config(node_content_seed: int) -> RogueCombatEncounterConfig:
	if not is_ready_to_enable():
		return null
	var total_weight := get_total_selection_weight()
	if total_weight <= 0:
		return null
	var contract_hash := compute_runtime_contract_hash()
	if contract_hash.is_empty():
		return null
	var bucket := ENCOUNTER_RANDOM_SCRIPT.choose_index(
		node_content_seed,
		StringName("normal_combat_pool:%s:%s" % [String(pool_id), contract_hash]),
		total_weight
	)
	if bucket < 0:
		return null
	return select_config_for_weight_bucket(bucket)


func get_total_selection_weight() -> int:
	var total_weight := 0
	for entry in entries:
		if entry != null and entry.selection_weight > 0:
			total_weight += entry.selection_weight
	return total_weight


func select_config_for_weight_bucket(
	weight_bucket: int
) -> RogueCombatEncounterConfig:
	if not is_ready_to_enable():
		return null
	var total_weight := get_total_selection_weight()
	if weight_bucket < 0 or weight_bucket >= total_weight:
		return null
	var remaining_bucket := weight_bucket
	for entry in get_sorted_entries():
		if remaining_bucket < entry.selection_weight:
			return entry.combat_config
		remaining_bucket -= entry.selection_weight
	return null


func compute_runtime_contract_hash() -> String:
	if pool_id == &"" or entries.is_empty():
		return ""
	var sorted_entries := get_sorted_entries()
	if sorted_entries.size() != entries.size():
		return ""
	var seen_ids: Dictionary = {}
	var parts := PackedStringArray([
		"schema=%d" % RUNTIME_CONTRACT_SCHEMA,
		"pool_id=%s" % String(pool_id),
		"entry_count=%d" % sorted_entries.size(),
	])
	for entry in sorted_entries:
		if (
			entry.combat_config == null
			or not entry.combat_config.is_ready_to_enable()
			or entry.selection_weight <= 0
			or entry.combat_config.encounter_id == &""
			or seen_ids.has(entry.combat_config.encounter_id)
		):
			return ""
		var config_hash := entry.combat_config.compute_runtime_contract_hash()
		if config_hash.is_empty():
			return ""
		seen_ids[entry.combat_config.encounter_id] = true
		parts.append(
			"entry=%s:%d:%s" % [
				String(entry.combat_config.encounter_id),
				entry.selection_weight,
				config_hash,
			]
		)
	return "\n".join(parts).sha256_text()


func _entry_less(first: POOL_ENTRY_SCRIPT, second: POOL_ENTRY_SCRIPT) -> bool:
	var first_id := String(first.combat_config.encounter_id) if first.combat_config != null else ""
	var second_id := String(second.combat_config.encounter_id) if second.combat_config != null else ""
	if first_id != second_id:
		return first_id < second_id
	var first_path := first.combat_config.resource_path if first.combat_config != null else ""
	var second_path := second.combat_config.resource_path if second.combat_config != null else ""
	return first_path < second_path
