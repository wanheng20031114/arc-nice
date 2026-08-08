extends RefCounted
class_name EnemyCodexRegistry

const ENTRY_COUNT := 57
const SORCERER_ENTRY_COUNT := 6
const EXPECTED_FAMILY_COUNTS := {
	&"yuanshi_insect": 16,
	&"slime": 10,
	&"capoo": 16,
	&"sorcerer": 6,
	&"artificial_creation": 2,
	&"mechanical_life": 6,
	&"boss": 1,
}
const EXPECTED_RANK_COUNTS := {
	EnemyCodexEntryConfig.Rank.NORMAL: 49,
	EnemyCodexEntryConfig.Rank.ELITE: 7,
	EnemyCodexEntryConfig.Rank.BOSS: 1,
}

const ENTRIES: Array[EnemyCodexEntryConfig] = [
	preload("res://resources/config/encyclopedia/enemies/yuanshi_insect_basic.tres"),
	preload("res://resources/config/encyclopedia/enemies/yuanshi_insect_shell.tres"),
	preload("res://resources/config/encyclopedia/enemies/yuanshi_insect_fast.tres"),
	preload("res://resources/config/encyclopedia/enemies/yuanshi_insect_bomber.tres"),
	preload("res://resources/config/encyclopedia/enemies/yuanshi_insect_purple_bomber.tres"),
	preload("res://resources/config/encyclopedia/enemies/yuanshi_insect_green_shell.tres"),
	preload("res://resources/config/encyclopedia/enemies/yuanshi_insect_fire_ranged.tres"),
	preload("res://resources/config/encyclopedia/enemies/yuanshi_insect_guardian.tres"),
	preload("res://resources/config/encyclopedia/enemies/stone_eroded_yuanshi_insect_basic.tres"),
	preload("res://resources/config/encyclopedia/enemies/stone_eroded_yuanshi_insect_shell.tres"),
	preload("res://resources/config/encyclopedia/enemies/stone_eroded_yuanshi_insect_fast.tres"),
	preload("res://resources/config/encyclopedia/enemies/stone_eroded_yuanshi_insect_bomber.tres"),
	preload("res://resources/config/encyclopedia/enemies/stone_eroded_yuanshi_insect_purple_bomber.tres"),
	preload("res://resources/config/encyclopedia/enemies/stone_eroded_yuanshi_insect_green_shell.tres"),
	preload("res://resources/config/encyclopedia/enemies/stone_eroded_yuanshi_insect_fire_ranged.tres"),
	preload("res://resources/config/encyclopedia/enemies/stone_eroded_yuanshi_insect_guardian.tres"),
	preload("res://resources/config/encyclopedia/enemies/slime_basic.tres"),
	preload("res://resources/config/encyclopedia/enemies/slime_fire.tres"),
	preload("res://resources/config/encyclopedia/enemies/slime_frost.tres"),
	preload("res://resources/config/encyclopedia/enemies/slime_green.tres"),
	preload("res://resources/config/encyclopedia/enemies/slime_golden.tres"),
	preload("res://resources/config/encyclopedia/enemies/stone_eroded_slime.tres"),
	preload("res://resources/config/encyclopedia/enemies/stone_eroded_slime_fire.tres"),
	preload("res://resources/config/encyclopedia/enemies/stone_eroded_slime_frost.tres"),
	preload("res://resources/config/encyclopedia/enemies/stone_eroded_slime_green.tres"),
	preload("res://resources/config/encyclopedia/enemies/stone_eroded_slime_golden.tres"),
	preload("res://resources/config/encyclopedia/enemies/capoo_knight.tres"),
	preload("res://resources/config/encyclopedia/enemies/capoo_knight_elite.tres"),
	preload("res://resources/config/encyclopedia/enemies/capoo_swordsman.tres"),
	preload("res://resources/config/encyclopedia/enemies/capoo_smg.tres"),
	preload("res://resources/config/encyclopedia/enemies/capoo_ak47.tres"),
	preload("res://resources/config/encyclopedia/enemies/capoo_rpg.tres"),
	preload("res://resources/config/encyclopedia/enemies/capoo_mage.tres"),
	preload("res://resources/config/encyclopedia/enemies/capoo_sniper.tres"),
	preload("res://resources/config/encyclopedia/enemies/stone_eroded_capoo_knight.tres"),
	preload("res://resources/config/encyclopedia/enemies/stone_eroded_capoo_knight_elite.tres"),
	preload("res://resources/config/encyclopedia/enemies/stone_eroded_capoo_swordsman.tres"),
	preload("res://resources/config/encyclopedia/enemies/stone_eroded_capoo_smg.tres"),
	preload("res://resources/config/encyclopedia/enemies/stone_eroded_capoo_ak47.tres"),
	preload("res://resources/config/encyclopedia/enemies/stone_eroded_capoo_rpg.tres"),
	preload("res://resources/config/encyclopedia/enemies/stone_eroded_capoo_mage.tres"),
	preload("res://resources/config/encyclopedia/enemies/stone_eroded_capoo_sniper.tres"),
	preload("res://resources/config/encyclopedia/enemies/fire_sorcerer.tres"),
	preload("res://resources/config/encyclopedia/enemies/fire_sorcerer_elite.tres"),
	preload("res://resources/config/encyclopedia/enemies/frost_sorcerer.tres"),
	preload("res://resources/config/encyclopedia/enemies/frost_sorcerer_elite.tres"),
	preload("res://resources/config/encyclopedia/enemies/lightning_sorcerer.tres"),
	preload("res://resources/config/encyclopedia/enemies/lightning_sorcerer_elite.tres"),
	preload("res://resources/config/encyclopedia/enemies/stone_golem.tres"),
	preload("res://resources/config/encyclopedia/enemies/stone_golem_elite.tres"),
	preload("res://resources/config/encyclopedia/enemies/combat_robot.tres"),
	preload("res://resources/config/encyclopedia/enemies/combat_robot_elite.tres"),
	preload("res://resources/config/encyclopedia/enemies/combat_robot_gunner.tres"),
	preload("res://resources/config/encyclopedia/enemies/combat_robot_drone_operator.tres"),
	preload("res://resources/config/encyclopedia/enemies/combat_robot_shield_bearer.tres"),
	preload("res://resources/config/encyclopedia/enemies/combat_robot_ninja.tres"),
	preload("res://resources/config/encyclopedia/enemies/linglan_boss.tres"),
]


static func get_all_entries() -> Array[EnemyCodexEntryConfig]:
	return ENTRIES.duplicate()


static func get_entry(entry_id: StringName) -> EnemyCodexEntryConfig:
	for entry in ENTRIES:
		if entry.entry_id == entry_id:
			return entry
	return null


static func get_rank_label(rank: EnemyCodexEntryConfig.Rank) -> String:
	match rank:
		EnemyCodexEntryConfig.Rank.ELITE:
			return "精英"
		EnemyCodexEntryConfig.Rank.BOSS:
			return "Boss"
		_:
			return "普通"


static func validate_contract() -> bool:
	if ENTRIES.size() != ENTRY_COUNT:
		return false
	var seen_ids := {}
	var seen_enemy_config_paths := {}
	var previous_sort_order := -1
	var sorcerer_count := 0
	var family_counts := {}
	var rank_counts := {}
	for entry in ENTRIES:
		if entry == null or not entry.is_valid():
			return false
		if seen_ids.has(entry.entry_id):
			return false
		seen_ids[entry.entry_id] = true
		var enemy_config_path := entry.enemy_config.resource_path
		if enemy_config_path.is_empty() or seen_enemy_config_paths.has(enemy_config_path):
			return false
		seen_enemy_config_paths[enemy_config_path] = true
		if entry.sort_order <= previous_sort_order:
			return false
		previous_sort_order = entry.sort_order
		if entry.family_id == &"sorcerer":
			sorcerer_count += 1
		family_counts[entry.family_id] = int(family_counts.get(entry.family_id, 0)) + 1
		rank_counts[entry.rank] = int(rank_counts.get(entry.rank, 0)) + 1
		if entry.rank == EnemyCodexEntryConfig.Rank.BOSS:
			if entry.boss_config.get_enemy_config() != entry.enemy_config:
				return false
	return (
		sorcerer_count == SORCERER_ENTRY_COUNT
		and family_counts == EXPECTED_FAMILY_COUNTS
		and rank_counts == EXPECTED_RANK_COUNTS
	)
