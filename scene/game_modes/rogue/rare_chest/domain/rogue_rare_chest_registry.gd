extends RefCounted
class_name RogueRareChestRegistry

const RUNTIME_CONTRACT_SCHEMA := 1
const CHOICE_COUNT := 3

const OPTION_MAX_HEALTH := &"max_health"
const OPTION_PHYSICAL_DEFENSE := &"physical_defense"
const OPTION_MAGIC_DEFENSE := &"magic_defense"
const OPTION_MOVE_SPEED := &"move_speed"
const OPTION_AMMO_CAPACITY := &"ammo_capacity"
const OPTION_ATTACK_DAMAGE := &"attack_damage"
const OPTION_DODGE_PERCENT_POINTS := &"dodge_percent_points"

const _ORDERED_OPTIONS: Array[StringName] = [
	OPTION_MAX_HEALTH,
	OPTION_PHYSICAL_DEFENSE,
	OPTION_MAGIC_DEFENSE,
	OPTION_MOVE_SPEED,
	OPTION_AMMO_CAPACITY,
	OPTION_ATTACK_DAMAGE,
	OPTION_DODGE_PERCENT_POINTS,
]

const _DEFINITIONS := {
	OPTION_MAX_HEALTH: {
		"effect_text": "生命值永久+10",
		"detail_text": "同时回复10点生命值",
		"stat_id": OPTION_MAX_HEALTH,
		"stat_delta": 10,
	},
	OPTION_PHYSICAL_DEFENSE: {
		"effect_text": "物理防御永久+2",
		"detail_text": "",
		"stat_id": OPTION_PHYSICAL_DEFENSE,
		"stat_delta": 2,
	},
	OPTION_MAGIC_DEFENSE: {
		"effect_text": "法术防御永久+1",
		"detail_text": "",
		"stat_id": OPTION_MAGIC_DEFENSE,
		"stat_delta": 1,
	},
	OPTION_MOVE_SPEED: {
		"effect_text": "移动速度永久+5",
		"detail_text": "",
		"stat_id": OPTION_MOVE_SPEED,
		"stat_delta": 5,
	},
	OPTION_AMMO_CAPACITY: {
		"effect_text": "弹夹容量永久+1",
		"detail_text": "",
		"stat_id": OPTION_AMMO_CAPACITY,
		"stat_delta": 1,
	},
	OPTION_ATTACK_DAMAGE: {
		"effect_text": "攻击力永久+2",
		"detail_text": "",
		"stat_id": OPTION_ATTACK_DAMAGE,
		"stat_delta": 2,
	},
	OPTION_DODGE_PERCENT_POINTS: {
		"effect_text": "闪避率永久+1%",
		"detail_text": "",
		"stat_id": OPTION_DODGE_PERCENT_POINTS,
		"stat_delta": 1,
	},
}


static func get_all_option_ids() -> Array[StringName]:
	return _ORDERED_OPTIONS.duplicate()


static func has_option(option_id: StringName) -> bool:
	return _DEFINITIONS.has(option_id)


static func get_option_definition(option_id: StringName) -> Dictionary:
	var raw_definition: Variant = _DEFINITIONS.get(option_id)
	return (
		(raw_definition as Dictionary).duplicate(true)
		if typeof(raw_definition) == TYPE_DICTIONARY
		else {}
	)


static func get_stat_id(option_id: StringName) -> StringName:
	return StringName(get_option_definition(option_id).get("stat_id", &""))


static func get_stat_delta(option_id: StringName) -> int:
	return int(get_option_definition(option_id).get("stat_delta", 0))


static func select_options(
	node_content_seed: int,
	participant_stable_key: String,
	valid_option_ids: Array[StringName]
) -> Array[StringName]:
	if participant_stable_key.strip_edges().is_empty():
		return []
	var candidates: Array[StringName] = []
	for option_id in _ORDERED_OPTIONS:
		if valid_option_ids.has(option_id):
			candidates.append(option_id)
	if candidates.size() < CHOICE_COUNT:
		return []
	var order := _shuffled_indices(
		node_content_seed,
		StringName(
			"rare_chest_options|stable:%s|contract:%s"
			% [
				participant_stable_key,
				compute_option_contract_hash(candidates),
			]
		),
		candidates.size()
	)
	var selected: Array[StringName] = []
	for candidate_index in order:
		selected.append(candidates[candidate_index])
		if selected.size() == CHOICE_COUNT:
			break
	return selected


static func compute_option_contract_hash(
	valid_option_ids: Array[StringName]
) -> String:
	var parts := PackedStringArray()
	for option_id in _ORDERED_OPTIONS:
		if not valid_option_ids.has(option_id):
			continue
		var definition := get_option_definition(option_id)
		parts.append(
			"%s:%s:%d"
			% [
				String(option_id),
				String(definition.get("stat_id", &"")),
				int(definition.get("stat_delta", 0)),
			]
		)
	return "\n".join(parts).sha256_text()


static func compute_runtime_contract_hash() -> String:
	var parts := PackedStringArray([
		"schema=%d" % RUNTIME_CONTRACT_SCHEMA,
		"choice_count=%d" % CHOICE_COUNT,
		"selection=equal_without_replacement_per_peer",
		"seed=route_node_content_seed_plus_participant_stable_key_plus_option_contract_hash",
	])
	for option_id in _ORDERED_OPTIONS:
		var definition := get_option_definition(option_id)
		parts.append(
			"option=%s|stat=%s|delta=%d"
			% [
				String(option_id),
				String(definition.get("stat_id", &"")),
				int(definition.get("stat_delta", 0)),
			]
		)
	parts.append("ammo_requires_character_capability=1")
	parts.append("magic_and_dodge_cap=100")
	parts.append("ammo_cap=65535")
	return "\n".join(parts).sha256_text()


static func _choose_index(
	seed_value: int,
	salt: StringName,
	count: int
) -> int:
	if count <= 0:
		return -1
	var digest := ("%d|%s" % [seed_value, String(salt)]).sha256_text()
	return int(digest.substr(0, 15).hex_to_int() % count)


static func _shuffled_indices(
	seed_value: int,
	salt: StringName,
	count: int
) -> Array[int]:
	var result: Array[int] = []
	for index in range(maxi(count, 0)):
		result.append(index)
	for tail in range(result.size() - 1, 0, -1):
		var swap_index := _choose_index(
			seed_value,
			StringName("%s|tail:%d" % [String(salt), tail]),
			tail + 1
		)
		var previous := result[tail]
		result[tail] = result[swap_index]
		result[swap_index] = previous
	return result
