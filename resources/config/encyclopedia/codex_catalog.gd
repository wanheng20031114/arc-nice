extends RefCounted
class_name CodexCatalog

const ProductionRecipeRegistryScript := preload(
	"res://resources/config/production/production_recipe_registry.gd"
)
const COLLECTIBLE_FILTER_KEYS: Array[StringName] = [
	&"common",
	&"rare",
	&"epic",
	&"legendary",
	&"special",
]
const BUILDING_FILTER_KEYS: Array[StringName] = [
	&"defense_tower",
	&"support_tower",
	&"production_building",
	&"technology_building",
	&"fence",
	&"terrain_building",
	&"storage_building",
]
const ITEM_FILTER_KEYS := {
	&"material": "材料",
	&"consumable": "消耗品",
	&"instant": "即时道具",
	&"fate": "命运物品",
}
const CHARACTER_FILTER_KEYS := {
	&"ranged": "远程",
	&"melee": "近战",
}
const RECIPE_FILTER_KEYS := {
	&"simple_crafting": "简易制作",
	&"shared_production": "共享仓库生产",
	&"local_output_cycle": "本地产物循环",
}
const RESEARCH_FILTER_KEYS := {
	&"attribute": "属性强化",
	&"recipe_unlock": "配方解锁",
	&"building_enhancement": "建筑增强",
}
## Authored catalog contract used by navigation before any section is materialized.
## The encyclopedia smoke test verifies these counts against the full registries.
const REGISTERED_ENTRY_COUNTS := {
	CodexSection.ENEMY: 64,
	CodexSection.COLLECTIBLE: 125,
	CodexSection.BUILDING: 19,
	CodexSection.ITEM: 36,
	CodexSection.CHARACTER: 4,
	CodexSection.RECIPE: 32,
	CodexSection.RESEARCH: 7,
}
const COLLECTIBLE_ACCENTS: Array[Color] = [
	Color("#f0e3c2"),
	Color("#68d8ff"),
	Color("#c987ff"),
	Color("#ffae32"),
	Color("#7EE3C4"),
]
const ENEMY_NORMAL_ACCENT := Color("#6fd4bd")
const ENEMY_ELITE_ACCENT := Color("#c58aff")
const ENEMY_BOSS_ACCENT := Color("#ffcf67")
const BUILDING_ACCENT := Color("#7ed9c4")
const ITEM_ACCENTS := {
	&"material": Color("#d7b978"),
	&"consumable": Color("#72d49b"),
	&"instant": Color("#68bde8"),
	&"fate": Color("#c58aff"),
}
const RECIPE_ACCENT := Color("#68c9d6")
const AUTHORED_TOWER_DEFENSE_TILE_SIZE := 16.0
const RESEARCH_ACCENTS := {
	&"attribute": Color("#e3b96a"),
	&"recipe_unlock": Color("#8dc9ff"),
	&"building_enhancement": Color("#8fd89e"),
}
const LINGLAN_SKILL_1: LinglanSkillConfig = preload(
	"res://resources/config/bosses/linglan_skill1.tres"
)
const LINGLAN_SKILL_2: LinglanSkill2Config = preload(
	"res://resources/config/bosses/linglan_skill2.tres"
)
const LINGLAN_SKILL_3: LinglanSkill3Config = preload(
	"res://resources/config/bosses/linglan_skill3.tres"
)
const LINGLAN_SKILL_4: LinglanSkill4Config = preload(
	"res://resources/config/bosses/linglan_skill4.tres"
)

var _visibility_provider: CodexVisibilityProvider
var _uses_default_visibility_provider: bool
var _entries_by_section: Dictionary = {}
var _filter_options_by_section: Dictionary = {}


func _init(provider: CodexVisibilityProvider = null) -> void:
	_uses_default_visibility_provider = provider == null
	_visibility_provider = provider if provider != null else CodexVisibilityProvider.new()


func set_visibility_provider(provider: CodexVisibilityProvider) -> void:
	_uses_default_visibility_provider = provider == null
	_visibility_provider = provider if provider != null else CodexVisibilityProvider.new()
	clear_cache()


func get_visibility_provider() -> CodexVisibilityProvider:
	return _visibility_provider


func get_entries(section: int) -> Array[CodexEntryViewData]:
	if not CodexSection.is_valid(section):
		return []
	_ensure_section(section)
	var entries: Array[CodexEntryViewData] = _entries_by_section.get(section, [])
	return entries.duplicate()


func get_filter_options(section: int) -> Array[Dictionary]:
	if not CodexSection.is_valid(section):
		return []
	_ensure_section(section)
	var options: Array[Dictionary] = _filter_options_by_section.get(section, [])
	return options.duplicate(true)


## Returns the visible navigation total. The production provider reveals every
## authored entry, so its fast path can use the manifest without materializing
## a section. Custom providers retain the original HIDDEN-aware semantics.
func get_total_count(section: int) -> int:
	if _uses_default_visibility_provider:
		return get_registered_count(section)
	return get_visible_count(section)


## Returns the number of records exposed by the current visibility provider.
## Unlike the lightweight registered count, this intentionally materializes
## the requested section so custom HIDDEN states are reflected exactly.
func get_visible_count(section: int) -> int:
	if not CodexSection.is_valid(section):
		return 0
	_ensure_section(section)
	var entries: Array[CodexEntryViewData] = _entries_by_section.get(section, [])
	return entries.size()


## Returns the raw number of registered records, independent of visibility.
## This method never materializes a catalog section or loads collectible configs.
func get_registered_count(section: int) -> int:
	if not CodexSection.is_valid(section):
		return 0
	return int(REGISTERED_ENTRY_COUNTS[section])


func clear_cache(section: int = -1) -> void:
	if section == -1:
		_entries_by_section.clear()
		_filter_options_by_section.clear()
		return
	if not CodexSection.is_valid(section):
		return
	_entries_by_section.erase(section)
	_filter_options_by_section.erase(section)


func _ensure_section(section: int) -> void:
	if _entries_by_section.has(section):
		return
	var entries: Array[CodexEntryViewData] = []
	match section:
		CodexSection.ENEMY:
			entries = _build_enemy_entries()
		CodexSection.COLLECTIBLE:
			entries = _build_collectible_entries()
		CodexSection.BUILDING:
			entries = _build_building_entries()
		CodexSection.ITEM:
			entries = _build_item_entries()
		CodexSection.CHARACTER:
			entries = _build_character_entries()
		CodexSection.RECIPE:
			entries = _build_recipe_entries()
		CodexSection.RESEARCH:
			entries = _build_research_entries()
	entries.sort_custom(_entry_precedes)
	_entries_by_section[section] = entries
	_filter_options_by_section[section] = _build_filter_options(entries)


func _build_enemy_entries() -> Array[CodexEntryViewData]:
	var result: Array[CodexEntryViewData] = []
	for source in EnemyCodexRegistry.get_all_entries():
		if source == null or not source.visible_in_codex:
			continue
		var visibility := _get_visibility_state(CodexSection.ENEMY, source.entry_id)
		if visibility == CodexVisibilityState.HIDDEN:
			continue
		var enemy := source.enemy_config
		var entry := CodexEntryViewData.new()
		entry.entry_id = source.entry_id
		entry.section = CodexSection.ENEMY
		entry.display_name = enemy.display_name
		entry.description = source.description
		entry.icon = source.get_icon()
		entry.preview_frames = source.preview_frames
		entry.preview_animation = source.preview_animation
		entry.preview_scale = source.preview_scale
		entry.preview_offset = source.preview_offset
		entry.primary_badge = source.family_label
		entry.secondary_badge = EnemyCodexRegistry.get_rank_label(source.rank)
		entry.accent_color = _get_enemy_rank_accent(source.rank)
		entry.filter_key = source.family_id
		entry.filter_label = source.family_label
		entry.sort_group = 0
		entry.sort_order = source.sort_order
		entry.stats = _build_enemy_stats(enemy, source)
		entry.notes = source.traits.duplicate()
		if enemy.explode_on_death:
			entry.notes.append(
				"死亡自爆：造成 %d 点伤害，作用半径 %s" % [
					enemy.explosion_damage,
					_format_number(enemy.explosion_radius),
				]
			)
		entry.visibility_state = visibility
		entry.source_resource = source
		result.append(entry)
	return result


func _build_collectible_entries() -> Array[CodexEntryViewData]:
	var configs := CollectibleRegistry.get_all()
	configs.sort_custom(_collectible_precedes)
	var result: Array[CodexEntryViewData] = []
	for config_index in configs.size():
		var item := configs[config_index]
		var entry_id := _get_collectible_entry_id(item)
		if entry_id == &"":
			push_error(
				"Collectible is missing a stable RuntimeContentCatalog ID: %s"
				% item.resource_path
			)
			continue
		var visibility := _get_visibility_state(
			CodexSection.COLLECTIBLE,
			entry_id
		)
		if visibility == CodexVisibilityState.HIDDEN:
			continue
		var rarity := int(item.collectible_rarity)
		var rarity_label := PickupConfig.get_collectible_rarity_label(rarity)
		var classification_stat_label := (
			PickupConfig.get_collectible_classification_stat_label(rarity)
		)
		var entry := CodexEntryViewData.new()
		entry.entry_id = entry_id
		entry.section = CodexSection.COLLECTIBLE
		entry.display_name = item.display_name
		entry.description = item.description
		entry.icon = item.icon_texture
		entry.primary_badge = rarity_label
		entry.secondary_badge = _get_collectible_stack_badge(item)
		entry.accent_color = COLLECTIBLE_ACCENTS[rarity]
		entry.filter_key = COLLECTIBLE_FILTER_KEYS[rarity]
		entry.filter_label = rarity_label
		entry.sort_group = rarity
		entry.sort_order = config_index
		entry.stats = [CodexStatRow.new(classification_stat_label, rarity_label)]
		entry.notes = _build_collectible_notes(item)
		entry.visibility_state = visibility
		entry.source_resource = item
		result.append(entry)
	return result


func _build_building_entries() -> Array[CodexEntryViewData]:
	var result: Array[CodexEntryViewData] = []
	var recipes := ProductionRecipeRegistryScript.get_all_recipes()
	for config in PlantDefenseRegistry.get_all_configs():
		var visibility := _get_visibility_state(
			CodexSection.BUILDING,
			config.plant_id
		)
		if visibility == CodexVisibilityState.HIDDEN:
			continue
		var category := int(config.building_category)
		var category_label := PlantDefenseConfig.get_building_category_label(category)
		var entry := CodexEntryViewData.new()
		entry.entry_id = config.plant_id
		entry.section = CodexSection.BUILDING
		entry.display_name = config.display_name
		entry.description = config.description
		entry.icon = config.icon
		entry.preview_scale = config.placement_preview_display_size / 32.0
		entry.preview_offset = config.placement_preview_offset
		entry.primary_badge = category_label
		entry.secondary_badge = PlantDefenseConfig.get_placement_surface_label(
			config.placement_surface
		)
		entry.accent_color = BUILDING_ACCENT
		entry.filter_key = BUILDING_FILTER_KEYS[category - 1]
		entry.filter_label = category_label
		entry.sort_group = category
		entry.sort_order = config.menu_order
		entry.stats = _build_building_stats(config)
		entry.notes = _build_building_notes(config.plant_id, recipes)
		entry.visibility_state = visibility
		entry.source_resource = config
		result.append(entry)
	return result


func _build_item_entries() -> Array[CodexEntryViewData]:
	var manifest_entries := RuntimeContentCatalog.get_pickup_entries()
	var manifest_ids: Array = manifest_entries.keys()
	manifest_ids.sort()
	var result: Array[CodexEntryViewData] = []
	for manifest_index in manifest_ids.size():
		var manifest_id := String(manifest_ids[manifest_index])
		if not _is_general_item_manifest_id(manifest_id):
			continue
		var manifest_path := RuntimeContentCatalog.get_pickup_path_for_id(
			manifest_id
		)
		var item := RuntimeContentCatalog.load_pickup_config_from_path(
			manifest_path
		)
		if item == null:
			continue
		var entry_id := StringName(manifest_id)
		var visibility := _get_visibility_state(CodexSection.ITEM, entry_id)
		if visibility == CodexVisibilityState.HIDDEN:
			continue
		var filter_key := _get_item_filter_key(manifest_id)
		var entry := CodexEntryViewData.new()
		entry.entry_id = entry_id
		entry.section = CodexSection.ITEM
		entry.display_name = item.display_name
		entry.description = item.description
		entry.icon = item.icon_texture
		entry.primary_badge = String(ITEM_FILTER_KEYS[filter_key])
		entry.secondary_badge = _get_item_storage_badge(item)
		entry.accent_color = ITEM_ACCENTS[filter_key]
		entry.filter_key = filter_key
		entry.filter_label = String(ITEM_FILTER_KEYS[filter_key])
		entry.sort_group = _get_item_sort_group(filter_key)
		entry.sort_order = manifest_index
		entry.stats = _build_item_stats(item, filter_key)
		entry.notes = _build_item_notes(item, filter_key, manifest_id)
		entry.visibility_state = visibility
		entry.source_resource = item
		result.append(entry)
	return result


func _build_character_entries() -> Array[CodexEntryViewData]:
	var result: Array[CodexEntryViewData] = []
	var configs := PlayerCharacterRegistry.get_all_configs()
	for config_index in configs.size():
		var config := configs[config_index]
		if config == null or not config.is_valid():
			continue
		var entry_id := StringName("character.%s" % config.character_id)
		var visibility := _get_visibility_state(
			CodexSection.CHARACTER,
			entry_id
		)
		if visibility == CodexVisibilityState.HIDDEN:
			continue
		var filter_key := _get_character_filter_key(config)
		var entry := CodexEntryViewData.new()
		entry.entry_id = entry_id
		entry.section = CodexSection.CHARACTER
		entry.display_name = config.display_name
		entry.description = config.description
		entry.icon = _load_catalog_texture(config.portrait_texture)
		entry.primary_badge = String(CHARACTER_FILTER_KEYS[filter_key])
		entry.secondary_badge = config.title
		entry.accent_color = config.card_accent_color
		entry.filter_key = filter_key
		entry.filter_label = String(CHARACTER_FILTER_KEYS[filter_key])
		entry.sort_group = 0 if filter_key == &"ranged" else 1
		entry.sort_order = config_index
		entry.stats = _build_character_stats(config)
		entry.notes = _build_character_notes(config)
		entry.visibility_state = visibility
		entry.source_resource = config
		result.append(entry)
	return result


func _build_recipe_entries() -> Array[CodexEntryViewData]:
	var result: Array[CodexEntryViewData] = []
	var recipes := ProductionRecipeRegistryScript.get_all_recipes()
	for recipe_index in recipes.size():
		var recipe := recipes[recipe_index]
		if recipe == null or not recipe.is_valid():
			continue
		var entry_id := StringName("recipe.%s" % recipe.recipe_id)
		var visibility := _get_visibility_state(CodexSection.RECIPE, entry_id)
		if visibility == CodexVisibilityState.HIDDEN:
			continue
		var filter_key := _get_recipe_filter_key(recipe)
		var entry := CodexEntryViewData.new()
		entry.entry_id = entry_id
		entry.section = CodexSection.RECIPE
		entry.display_name = recipe.display_name
		entry.description = _build_recipe_description(recipe)
		entry.icon = recipe.output_items[0].icon_texture
		entry.primary_badge = String(RECIPE_FILTER_KEYS[filter_key])
		entry.secondary_badge = "%s 秒" % _format_number(
			recipe.duration_seconds
		)
		entry.accent_color = RECIPE_ACCENT
		entry.filter_key = filter_key
		entry.filter_label = String(RECIPE_FILTER_KEYS[filter_key])
		entry.sort_group = _get_recipe_sort_group(filter_key)
		entry.sort_order = recipe_index
		entry.stats = _build_recipe_stats(recipe)
		entry.notes = _build_recipe_notes(recipe)
		entry.visibility_state = visibility
		entry.source_resource = recipe
		result.append(entry)
	return result


func _build_research_entries() -> Array[CodexEntryViewData]:
	var result: Array[CodexEntryViewData] = []
	var recipes := ProductionRecipeRegistryScript.get_all_recipes()
	var configs := GlobalResearchRegistry.get_all_configs()
	for config_index in configs.size():
		var config := configs[config_index]
		if config == null or not config.is_valid():
			continue
		var entry_id := StringName("research.%s" % config.research_id)
		var visibility := _get_visibility_state(
			CodexSection.RESEARCH,
			entry_id
		)
		if visibility == CodexVisibilityState.HIDDEN:
			continue
		var filter_key := _get_research_filter_key(config)
		var entry := CodexEntryViewData.new()
		entry.entry_id = entry_id
		entry.section = CodexSection.RESEARCH
		entry.display_name = config.display_name
		entry.description = config.description
		entry.icon = config.input_items[0].icon_texture
		entry.primary_badge = String(RESEARCH_FILTER_KEYS[filter_key])
		entry.secondary_badge = "%s 秒" % _format_number(
			config.duration_seconds
		)
		entry.accent_color = RESEARCH_ACCENTS[filter_key]
		entry.filter_key = filter_key
		entry.filter_label = String(RESEARCH_FILTER_KEYS[filter_key])
		entry.sort_group = _get_research_sort_group(filter_key)
		entry.sort_order = config_index
		entry.stats = _build_research_stats(config)
		entry.notes = _build_research_notes(config, recipes)
		entry.visibility_state = visibility
		entry.source_resource = config
		result.append(entry)
	return result


func _build_enemy_stats(
	enemy: EnemyConfig,
	source: EnemyCodexEntryConfig
) -> Array[CodexStatRow]:
	var stats: Array[CodexStatRow] = [
		CodexStatRow.new("生命", str(enemy.max_health)),
		CodexStatRow.new("单次伤害", str(enemy.attack_damage)),
		CodexStatRow.new("物理防御", "%d 点" % enemy.physical_defense),
		CodexStatRow.new("法术防御", str(enemy.magic_defense)),
		CodexStatRow.new("移动速度", _format_number(enemy.move_speed)),
		CodexStatRow.new("基地伤害", str(enemy.home_damage)),
		CodexStatRow.new("击杀息壤", str(enemy.xirang_kill_reward)),
	]
	stats.append_array(_build_enemy_specific_stats(enemy))
	if source.boss_config != null:
		stats.append_array(_build_linglan_boss_stats())
	return stats


func _build_enemy_specific_stats(enemy: EnemyConfig) -> Array[CodexStatRow]:
	var stats: Array[CodexStatRow] = []
	if enemy is CombatRobotNinjaConfig:
		var config := enemy as CombatRobotNinjaConfig
		stats.append(
			CodexStatRow.new(
				"受击加速",
				"%s 倍" % _format_number(config.boost_speed_multiplier)
			)
		)
		stats.append(
			CodexStatRow.new(
				"加速持续", "%s 秒" % _format_number(config.boost_duration)
			)
		)
		stats.append(
			CodexStatRow.new(
				"触发冷却", "%s 秒" % _format_number(config.boost_cooldown)
			)
		)
	elif enemy is CombatRobotDroneOperatorConfig:
		var config := enemy as CombatRobotDroneOperatorConfig
		stats.append(
			CodexStatRow.new("搜索范围", _format_number(config.attack_range))
		)
		stats.append(
			CodexStatRow.new("停步距离", _format_number(config.stop_distance))
		)
		stats.append(
			CodexStatRow.new(
				"部署延迟", "%s 秒" % _format_number(config.deploy_delay)
			)
		)
		stats.append(
			CodexStatRow.new(
				"攻击冷却", "%s 秒" % _format_number(config.attack_cooldown)
			)
		)
		stats.append(
			CodexStatRow.new("无人机速度", _format_number(config.drone_speed))
		)
		stats.append(
			CodexStatRow.new("爆炸半径", _format_number(config.explosion_radius))
		)
	elif enemy is CombatRobotShieldBearerConfig:
		var config := enemy as CombatRobotShieldBearerConfig
		stats.append(
			CodexStatRow.new("盾牌抵消", "%d 次" % config.shield_max_blocks)
		)
		stats.append(
			CodexStatRow.new(
				"开裂阈值", "%d 次" % config.shield_cracked_remaining
			)
		)
		stats.append(
			CodexStatRow.new(
				"危急阈值", "%d 次" % config.shield_critical_remaining
			)
		)
	elif enemy is CombatRobotGunnerConfig:
		var config := enemy as CombatRobotGunnerConfig
		stats.append(CodexStatRow.new("攻击距离", _format_number(config.attack_range)))
		stats.append(CodexStatRow.new("射击前摇", "0 秒"))
		stats.append(CodexStatRow.new("每轮射击", "%d 发" % config.burst_count))
		stats.append(CodexStatRow.new("连射间隔", "%s 秒" % _format_number(config.burst_fire_interval)))
		stats.append(CodexStatRow.new("散布范围", "±%s°" % _format_number(config.spread_angle_degrees)))
		stats.append(
			CodexStatRow.new(
				"射击移速",
				"%s%%（基础有效速度 %s）" % [
					_format_number(config.burst_move_speed_multiplier * 100.0),
					_format_number(config.move_speed * config.burst_move_speed_multiplier),
				]
			)
		)
		stats.append(CodexStatRow.new("攻击冷却", "%s 秒" % _format_number(config.attack_cooldown)))
		stats.append(CodexStatRow.new("弹体速度", _format_number(config.projectile_speed)))
		stats.append(CodexStatRow.new("弹体寿命", "%s 秒" % _format_number(config.projectile_lifetime)))
	elif enemy is CombatRobotConfig:
		var config := enemy as CombatRobotConfig
		stats.append(CodexStatRow.new("锁定范围", _format_number(config.dash_trigger_range)))
		stats.append(CodexStatRow.new("冲刺前摇", "%s 秒" % _format_number(config.dash_windup)))
		stats.append(CodexStatRow.new("冲刺速度", _format_number(config.dash_speed)))
		stats.append(CodexStatRow.new("最长冲刺", "%s 秒" % _format_number(config.dash_duration)))
		stats.append(CodexStatRow.new("冲刺冷却", "%s 秒" % _format_number(config.dash_cooldown)))
	# StoneGolemConfig inherits CapooKnightConfig, so it must be handled before
	# the broader knight branch to expose its ground-slam data.
	elif enemy is StoneGolemConfig:
		var config := enemy as StoneGolemConfig
		stats.append(CodexStatRow.new("砸地半径", _format_number(config.slam_radius)))
	elif enemy is CapooAK47Config:
		var config := enemy as CapooAK47Config
		stats.append(CodexStatRow.new("攻击距离", _format_number(config.attack_range)))
		stats.append(CodexStatRow.new("每轮射击", "%d 发" % config.burst_count))
		stats.append(CodexStatRow.new("连射间隔", "%s 秒" % _format_number(config.burst_fire_interval)))
		stats.append(CodexStatRow.new("攻击冷却", "%s 秒" % _format_number(config.attack_interval)))
		stats.append(CodexStatRow.new("弹体速度", _format_number(config.projectile_speed)))
	elif enemy is CapooSMGConfig:
		var config := enemy as CapooSMGConfig
		stats.append(CodexStatRow.new("攻击距离", _format_number(config.attack_range)))
		stats.append(CodexStatRow.new("射击间隔", "%s 秒" % _format_number(config.fire_interval)))
		stats.append(CodexStatRow.new("散布角度", "%s°" % _format_number(config.spread_angle_degrees)))
		stats.append(CodexStatRow.new("弹体速度", _format_number(config.projectile_speed)))
	elif enemy is CapooMageConfig:
		var config := enemy as CapooMageConfig
		stats.append(CodexStatRow.new("攻击距离", _format_number(config.attack_range)))
		stats.append(CodexStatRow.new("攻击冷却", "%s 秒" % _format_number(config.attack_interval)))
		stats.append(CodexStatRow.new("弹体速度", _format_number(config.projectile_speed)))
		stats.append(
			CodexStatRow.new(
				"追踪转速",
				"%s 弧度/秒" % _format_number(config.fireball_homing_turn_rate)
			)
		)
	elif enemy is CapooRPGConfig:
		var config := enemy as CapooRPGConfig
		stats.append(CodexStatRow.new("攻击距离", _format_number(config.attack_range)))
		stats.append(CodexStatRow.new("攻击冷却", "%s 秒" % _format_number(config.attack_interval)))
		stats.append(CodexStatRow.new("火箭速度", _format_number(config.projectile_speed)))
		stats.append(CodexStatRow.new("爆炸半径", _format_number(config.explosion_radius)))
	elif enemy is CapooSniperConfig:
		var config := enemy as CapooSniperConfig
		stats.append(CodexStatRow.new("锁定距离", _format_number(config.attack_range)))
		stats.append(CodexStatRow.new("锁定时间", "%s 秒" % _format_number(config.lock_duration)))
		stats.append(CodexStatRow.new("攻击冷却", "%s 秒" % _format_number(config.attack_interval)))
	elif enemy is CapooKnightConfig:
		var config := enemy as CapooKnightConfig
		stats.append(CodexStatRow.new("攻击距离", _format_number(config.attack_range)))
		stats.append(CodexStatRow.new("攻击冷却", "%s 秒" % _format_number(config.attack_interval)))
		stats.append(CodexStatRow.new("斩击角度", "%s°" % _format_number(config.slash_angle_degrees)))
		stats.append(CodexStatRow.new("斩击外径", _format_number(config.slash_outer_radius)))
	elif enemy is FireSorcererConfig:
		var config := enemy as FireSorcererConfig
		stats.append(CodexStatRow.new("攻击距离", _format_number(config.attack_range)))
		stats.append(CodexStatRow.new("每轮火球", "3 枚"))
		stats.append(CodexStatRow.new("攻击冷却", "%s 秒" % _format_number(config.attack_interval)))
		stats.append(CodexStatRow.new("弹体速度", _format_number(config.projectile_speed)))
		stats.append(
			CodexStatRow.new(
				"灼烧",
				"%d 伤害 / %s 秒" % [
					config.burn_level,
					_format_number(config.burn_duration),
				]
			)
		)
	elif enemy is FrostSorcererConfig:
		var config := enemy as FrostSorcererConfig
		stats.append(CodexStatRow.new("攻击距离", _format_number(config.attack_range)))
		stats.append(CodexStatRow.new("攻击冷却", "%s 秒" % _format_number(config.attack_interval)))
		stats.append(CodexStatRow.new("弹体速度", _format_number(config.projectile_speed)))
	elif enemy is LightningSorcererConfig:
		var config := enemy as LightningSorcererConfig
		stats.append(CodexStatRow.new("攻击距离", _format_number(config.attack_range)))
		stats.append(CodexStatRow.new("连锁距离", _format_number(config.chain_range)))
		stats.append(CodexStatRow.new("最多连锁", "%d 次" % config.max_chain_bounces))
		stats.append(CodexStatRow.new("攻击冷却", "%s 秒" % _format_number(config.attack_interval)))
	elif enemy is YuanshiInsectFireRangedConfig:
		var config := enemy as YuanshiInsectFireRangedConfig
		stats.append(CodexStatRow.new("攻击距离", _format_number(config.attack_range)))
		stats.append(CodexStatRow.new("攻击冷却", "%s 秒" % _format_number(config.attack_interval)))
		stats.append(CodexStatRow.new("弹体速度", _format_number(config.projectile_speed)))
	elif enemy is YuanshiInsectGreenShellConfig:
		var config := enemy as YuanshiInsectGreenShellConfig
		stats.append(CodexStatRow.new("光环半径", _format_number(config.aura_radius)))
		stats.append(CodexStatRow.new("光环伤害", str(config.attack_damage)))
		stats.append(CodexStatRow.new("伤害间隔", "%s 秒" % _format_number(config.aura_damage_interval)))
	elif enemy is YuanshiInsectGuardianConfig:
		var config := enemy as YuanshiInsectGuardianConfig
		stats.append(CodexStatRow.new("光环半径", _format_number(config.aura_radius)))
		stats.append(CodexStatRow.new("物防增益", "+%d 点" % config.aura_physical_defense_bonus))
	elif enemy is SlimeConfig:
		var config := enemy as SlimeConfig
		if config.variant == SlimeConfig.Variant.GREEN:
			stats.append(CodexStatRow.new("每次回复", str(GreenSlime.REGENERATION_AMOUNT)))
			stats.append(
				CodexStatRow.new(
					"回复间隔",
					"%s 秒" % _format_number(
						GreenSlime.REGENERATION_INTERVAL_SECONDS
					)
				)
			)
		elif config.variant == SlimeConfig.Variant.FIRE:
			var duration := CombatAttackRegistry.get_burn_duration(CombatAttackRegistry.FIRE_SLIME_TOUCH)
			var damage := CombatAttackRegistry.get_burn_tick_damage(CombatAttackRegistry.FIRE_SLIME_TOUCH)
			stats.append(CodexStatRow.new("接触灼烧", "%d 伤害 / %s 秒" % [damage, _format_number(duration)]))
	return stats


func _build_linglan_boss_stats() -> Array[CodexStatRow]:
	return [
		CodexStatRow.new(
			"环形弹幕",
			"%d 向 · %d 伤害" % [
				LINGLAN_SKILL_1.ring_direction_count,
				LINGLAN_SKILL_1.projectile_damage,
			]
		),
		CodexStatRow.new("弹幕间隔", "%s 秒" % _format_number(LINGLAN_SKILL_1.get_fire_interval())),
		CodexStatRow.new(
			"追踪火箭",
			"%d 发 · %d 伤害" % [
				LINGLAN_SKILL_2.attack_count,
				LINGLAN_SKILL_2.rocket_damage,
			]
		),
		CodexStatRow.new("火箭爆炸半径", _format_number(LINGLAN_SKILL_2.rocket_explosion_radius)),
		CodexStatRow.new(
			"膨胀光球",
			"%d 发 · %d 伤害" % [
				LINGLAN_SKILL_3.get_shot_count(),
				LINGLAN_SKILL_3.orb_damage,
			]
		),
		CodexStatRow.new("收缩激光", "%d 伤害" % LINGLAN_SKILL_4.laser_damage),
		CodexStatRow.new(
			"夹击光球",
			"每侧 %d 枚 · %d 伤害" % [
				LINGLAN_SKILL_4.orb_count_per_side,
				LINGLAN_SKILL_4.orb_damage,
			]
		),
	]


func _build_collectible_notes(item: PickupConfig) -> PackedStringArray:
	var notes := PackedStringArray()
	if PickupConfig.is_special_collectible_category(item.collectible_rarity):
		notes.append("当前战斗效果：无")
		notes.append("获取方式：事件限定")
		if (
			item.collectible_effect_id
			== PickupConfig.COLLECTIBLE_EFFECT_FLYING_ENVELOPE
		):
			notes.append("持有规则：全队本局限一份，可放入背包或共享仓库")
			notes.append("出售规则：地下商店不回收")
		else:
			notes.append("持有规则：可重复获得，每份独立占用一个背包或仓库槽位")
		return notes
	if item.collectible_stacks_by_copy:
		if item.collectible_max_copies > 0:
			notes.append(
				"叠加规则：每份均可生效，最多 %d 份参与效果计算"
				% item.collectible_max_copies
			)
		else:
			notes.append("叠加规则：持有的每一份都会生效")
	else:
		notes.append("叠加规则：同名收藏品仅有一份参与效果计算")
	if item.requires_projectile_primary_attack and item.requires_ammunition:
		notes.append("角色限制：仅适用于普通攻击可生成投射物且具有弹药机制的角色")
	elif item.requires_projectile_primary_attack:
		notes.append("角色限制：仅适用于普通攻击可生成投射物的角色")
	elif item.requires_ammunition:
		notes.append("角色限制：仅适用于具有弹药与换弹机制的角色")
	else:
		notes.append("角色限制：所有角色均可使用")
	return notes


func _build_building_stats(config: PlantDefenseConfig) -> Array[CodexStatRow]:
	var stats: Array[CodexStatRow] = [
		CodexStatRow.new("生命", str(config.max_health)),
		CodexStatRow.new("物理防御", "%d 点" % config.physical_defense),
		CodexStatRow.new("法术防御", str(config.magic_defense)),
		CodexStatRow.new(
			"占地",
			"%d × %d 格" % [config.footprint_size.x, config.footprint_size.y]
		),
		CodexStatRow.new(
			"放置地形",
			PlantDefenseConfig.get_placement_surface_label(config.placement_surface)
		),
	]
	if config.attack_damage > 0:
		stats.append(CodexStatRow.new("攻击伤害", str(config.attack_damage)))
	if config.attack_speed > 0.0:
		stats.append(
			CodexStatRow.new(
				"攻击间隔",
				"%s 秒" % _format_number(config.get_attack_interval())
			)
		)
	if config.attack_range > 0.0:
		stats.append(
			CodexStatRow.new("攻击范围", _format_number(config.attack_range))
		)
	if config.attack_burst_count > 1:
		stats.append(
			CodexStatRow.new("每轮攻击", "%d 发" % config.attack_burst_count)
		)
	if config is LifeTowerConfig:
		var life_config := config as LifeTowerConfig
		stats.append(
			CodexStatRow.new(
				"最大生命加成",
				"+%s%%" % _format_number(life_config.max_health_bonus_ratio * 100.0)
			)
		)
	elif config is SpeedTowerConfig:
		var speed_config := config as SpeedTowerConfig
		stats.append(
			CodexStatRow.new(
				"移动速度加成",
				"+%s" % _format_number(speed_config.move_speed_bonus)
			)
		)
	elif config is AttackSpeedTowerConfig:
		var attack_speed_config := config as AttackSpeedTowerConfig
		stats.append(
			CodexStatRow.new(
				"攻击速度加成",
				"+%s%%" % _format_number(
					attack_speed_config.attack_speed_bonus_ratio * 100.0
				)
			)
		)
	elif config is OrangeChargingTowerConfig:
		var orange_config := config as OrangeChargingTowerConfig
		stats.append_array([
			CodexStatRow.new("气场外扩", "%d 格" % orange_config.aura_margin_cells),
			CodexStatRow.new(
				"玩家技力回复",
				"+%s / 秒" % _format_number(
					orange_config.player_skill_charge_bonus_per_second
				)
			),
			CodexStatRow.new(
				"防御塔攻击间隔",
				"×%s" % _format_number(
					orange_config.defense_attack_interval_multiplier
				)
			),
			CodexStatRow.new(
				"生产耗时",
				"×%s" % _format_number(
					orange_config.production_duration_multiplier
				)
			),
		])
	elif config is GrapeArcTowerConfig:
		var grape_config := config as GrapeArcTowerConfig
		stats.append_array([
			CodexStatRow.new("最多连锁", "%d 个目标" % grape_config.max_chain_targets),
			CodexStatRow.new(
				"连锁距离",
				_format_world_distance(grape_config.chain_jump_range)
			),
			CodexStatRow.new(
				"蓄力时间",
				"%s 秒" % _format_number(grape_config.charge_seconds)
			),
		])
	elif config is HydrangeaRainTowerConfig:
		var hydrangea_config := config as HydrangeaRainTowerConfig
		stats.append_array([
			CodexStatRow.new(
				"施放间隔",
				"%s 秒" % _format_number(hydrangea_config.rain_interval_seconds)
			),
			CodexStatRow.new(
				"雨幕持续",
				"%s 秒" % _format_number(hydrangea_config.rain_duration_seconds)
			),
			CodexStatRow.new(
				"效果持续",
				"%s 秒" % _format_number(hydrangea_config.effect_duration_seconds)
			),
			CodexStatRow.new(
				"生效间隔",
				"%s 秒" % _format_number(
					hydrangea_config.rain_tick_interval_seconds
				)
			),
			CodexStatRow.new("每次治疗", str(hydrangea_config.healing_per_tick)),
			CodexStatRow.new(
				"每次法伤",
				str(hydrangea_config.magic_damage_per_tick)
			),
			CodexStatRow.new(
				"敌人攻击倍率",
				"×%s" % _format_number(
					hydrangea_config.enemy_attack_damage_multiplier
				)
			),
			CodexStatRow.new(
				"搜索半径",
				"%s 格" % _format_number(
					hydrangea_config.target_search_radius_cells
				)
			),
			CodexStatRow.new(
				"雨幕半径",
				_format_world_distance(hydrangea_config.rain_radius)
			),
		])
	if config.plant_id == &"oak_warehouse":
		stats.append(
			CodexStatRow.new("仓库槽位", "%d 格" % RunStateStore.INVENTORY_CAPACITY)
		)
	return stats


func _build_building_notes(
	plant_id: StringName,
	all_recipes: Array[ProductionRecipe]
) -> PackedStringArray:
	var notes := PackedStringArray()
	var item := BuildingItemRegistry.get_item(plant_id)
	if item != null:
		notes.append(
			"背包规则：同格叠加，单格上限 %d"
			% PickupConfig.get_inventory_stack_limit(item)
		)
		for recipe in all_recipes:
			if not _recipe_outputs_item(recipe, item):
				continue
			notes.append(_build_building_acquisition_note(recipe))
	var produced_recipe_count := 0
	for recipe in all_recipes:
		if (
			ProductionRecipeRegistryScript.get_producer_id(recipe.recipe_id)
			!= plant_id
		):
			continue
		produced_recipe_count += 1
		notes.append(
			"生产配方：%s（%s → %s；%s 秒；产入%s）" % [
				recipe.display_name,
				recipe.get_input_summary(),
				recipe.get_output_summary(),
				_format_number(recipe.duration_seconds),
				_get_recipe_output_destination_label(recipe),
			]
		)
	if produced_recipe_count > 0:
		notes.append("可运行配方总数：%d" % produced_recipe_count)
	return notes


func _recipe_outputs_item(
	recipe: ProductionRecipe,
	item: PickupConfig
) -> bool:
	for output_item in recipe.output_items:
		if PickupConfig.inventory_identity_matches(output_item, item):
			return true
	return false


func _build_building_acquisition_note(recipe: ProductionRecipe) -> String:
	var research_label := "无科研前置"
	if recipe.required_global_research_id != &"":
		var research := GlobalResearchRegistry.get_config(
			recipe.required_global_research_id
		)
		research_label = "需%s" % (
			research.display_name
			if research != null
			else String(recipe.required_global_research_id)
		)
	return "获取配方：%s · %s（%s；%s 秒；产入%s；%s）" % [
		ProductionRecipeRegistryScript.get_producer_label(recipe.recipe_id),
		recipe.display_name,
		recipe.get_input_summary(),
		_format_number(recipe.duration_seconds),
		_get_recipe_output_destination_label(recipe),
		research_label,
	]


func _is_general_item_manifest_id(manifest_id: String) -> bool:
	return (
		manifest_id.begins_with("item.materials.")
		or manifest_id.begins_with("item.consumables.")
		or manifest_id.begins_with("item.pickup_triggered_items.")
		or manifest_id.begins_with("item.fate.")
	)


func _get_item_filter_key(manifest_id: String) -> StringName:
	if manifest_id.begins_with("item.consumables."):
		return &"consumable"
	if manifest_id.begins_with("item.pickup_triggered_items."):
		return &"instant"
	if manifest_id.begins_with("item.fate."):
		return &"fate"
	return &"material"


func _get_item_sort_group(filter_key: StringName) -> int:
	match filter_key:
		&"consumable":
			return 1
		&"instant":
			return 2
		&"fate":
			return 3
		_:
			return 0


func _get_item_storage_badge(item: PickupConfig) -> String:
	if item.inventory_locked:
		return "背包锁定"
	if not item.can_store_in_inventory:
		return "拾取生效"
	return "可叠加" if item.stackable else "独立占格"


func _build_item_stats(
	item: PickupConfig,
	filter_key: StringName
) -> Array[CodexStatRow]:
	var stats: Array[CodexStatRow] = [
		CodexStatRow.new("分类", String(ITEM_FILTER_KEYS[filter_key])),
	]
	if not item.can_store_in_inventory:
		stats.append(CodexStatRow.new("获得方式", "拾取后立即生效"))
		return stats
	stats.append(CodexStatRow.new("背包存放", "允许"))
	stats.append(
		CodexStatRow.new(
			"叠加规则",
			"同格叠加" if item.stackable else "每件独立占格"
		)
	)
	if item.stackable:
		stats.append(
			CodexStatRow.new(
				"单格上限",
				str(PickupConfig.get_inventory_stack_limit(item))
			)
		)
	return stats


func _build_item_notes(
	item: PickupConfig,
	filter_key: StringName,
	manifest_id: String
) -> PackedStringArray:
	var notes := PackedStringArray()
	if item.inventory_locked:
		notes.append("背包锁定：不可使用、丢弃、转移或作为制作投入")
	elif filter_key == &"consumable":
		notes.append("使用规则：主动使用成功后消耗 1 个")
	elif filter_key == &"instant":
		notes.append("生效规则：接触拾取后立即触发，不进入背包")
	elif filter_key == &"material":
		match manifest_id:
			"item.materials.material_gambler_ticket":
				notes.append("用途：从共享仓库取回背包后，用于洛茜特殊玩法")
			"item.materials.material_small_stone":
				notes.append("当前用途：暂无配方或科研消费者，作为扩展物料保留")
			_:
				notes.append("用途：可作为简易制作、建筑生产或全局科研投入")
	return notes


func _get_character_filter_key(
	config: PlayerCharacterConfig
) -> StringName:
	return &"melee" if config.playstyle.begins_with("近战") else &"ranged"


func _build_character_stats(
	config: PlayerCharacterConfig
) -> Array[CodexStatRow]:
	var attack_interval := (
		config.attack_speed_units_per_attack / config.starting_attack_speed
	)
	return [
		CodexStatRow.new("初始生命", str(config.starting_max_health)),
		CodexStatRow.new("初始攻击", str(config.starting_attack_damage)),
		CodexStatRow.new(
			"基础攻击间隔",
			"%s 秒" % _format_number(attack_interval)
		),
		CodexStatRow.new("初始移速", _format_number(config.starting_move_speed)),
		CodexStatRow.new(
			"弹药机制",
			"使用弹药" if config.supports_ammunition else "无需弹药"
		),
	]


func _build_character_notes(
	config: PlayerCharacterConfig
) -> PackedStringArray:
	var notes := PackedStringArray()
	if not config.english_name.is_empty():
		notes.append("英文名：%s" % config.english_name)
	if not config.playstyle.is_empty():
		notes.append("战斗定位：%s" % config.playstyle)
	if not config.skill_display_name.is_empty():
		notes.append(
			"技能「%s」：%s" % [
				config.skill_display_name,
				config.skill_description,
			]
		)
	return notes


func _get_recipe_filter_key(recipe: ProductionRecipe) -> StringName:
	var category := ProductionRecipeRegistryScript.get_category_for_recipe(recipe)
	return ProductionRecipeRegistryScript.get_category_key(category)


func _get_recipe_sort_group(filter_key: StringName) -> int:
	match filter_key:
		&"shared_production":
			return 1
		&"local_output_cycle":
			return 2
		_:
			return 0


func _build_recipe_description(recipe: ProductionRecipe) -> String:
	var input_clause := (
		"无需材料，自动生产"
		if recipe.input_items.is_empty()
		else "投入%s" % recipe.get_input_summary()
	)
	return "%s，经过%s秒后产出%s。" % [
		input_clause,
		_format_number(recipe.duration_seconds),
		recipe.get_output_summary(),
	]


func _build_recipe_stats(
	recipe: ProductionRecipe
) -> Array[CodexStatRow]:
	return [
		CodexStatRow.new("投入", recipe.get_input_summary()),
		CodexStatRow.new("产出", recipe.get_output_summary()),
		CodexStatRow.new(
			"生产时间",
			"%s 秒" % _format_number(recipe.duration_seconds)
		),
		CodexStatRow.new("材料来源", _get_recipe_input_source_label(recipe)),
		CodexStatRow.new("产物去向", _get_recipe_output_destination_label(recipe)),
	]


func _build_recipe_notes(recipe: ProductionRecipe) -> PackedStringArray:
	var notes := PackedStringArray()
	var producer_label := ProductionRecipeRegistryScript.get_producer_label(
		recipe.recipe_id
	)
	if not producer_label.is_empty():
		notes.append("制作位置：%s" % producer_label)
	if recipe.required_global_research_id == &"":
		notes.append("科研前置：无")
	else:
		var research := GlobalResearchRegistry.get_config(
			recipe.required_global_research_id
		)
		notes.append(
			"科研前置：%s" % (
				research.display_name
				if research != null
				else String(recipe.required_global_research_id)
			)
		)
	if recipe.outputs_to_local_slot():
		notes.append("本地产物格容量：%d" % recipe.get_local_output_capacity())
	return notes


func _get_recipe_input_source_label(recipe: ProductionRecipe) -> String:
	if recipe.input_items.is_empty():
		return "无需材料（自动生产）"
	if recipe.uses_environment_source():
		return "环境来源"
	if recipe.inputs_from_player_inventory():
		return "玩家背包"
	return "共享仓库"


func _get_recipe_output_destination_label(recipe: ProductionRecipe) -> String:
	match recipe.output_destination:
		ProductionRecipe.OutputDestination.PLAYER_INVENTORY:
			return "玩家背包"
		ProductionRecipe.OutputDestination.LOCAL_OUTPUT_SLOT:
			return "建筑本地产物格"
		_:
			return "共享仓库"


func _get_research_filter_key(
	config: GlobalResearchConfig
) -> StringName:
	match config.effect_type:
		GlobalResearchConfig.EffectType.SIMPLE_CRAFTING_RECIPE_UNLOCK, \
		GlobalResearchConfig.EffectType.PRODUCTION_RECIPE_UNLOCK:
			return &"recipe_unlock"
		GlobalResearchConfig.EffectType.VEGETATION_SPREAD_SPEED_MULTIPLIER:
			return &"building_enhancement"
		_:
			return &"attribute"


func _get_research_sort_group(filter_key: StringName) -> int:
	match filter_key:
		&"recipe_unlock":
			return 1
		&"building_enhancement":
			return 2
		_:
			return 0


func _build_research_stats(
	config: GlobalResearchConfig
) -> Array[CodexStatRow]:
	return [
		CodexStatRow.new("投入", _get_research_input_summary(config)),
		CodexStatRow.new(
			"研究时间",
			"%s 秒" % _format_number(config.duration_seconds)
		),
		CodexStatRow.new("研究成果", config.result_summary),
	]


func _get_research_input_summary(config: GlobalResearchConfig) -> String:
	var parts := PackedStringArray()
	for input_index in config.input_items.size():
		parts.append(
			"%s ×%d" % [
				config.input_items[input_index].display_name,
				config.input_amounts[input_index],
			]
		)
	return "、".join(parts)


func _build_research_notes(
	config: GlobalResearchConfig,
	recipes: Array[ProductionRecipe]
) -> PackedStringArray:
	var notes := PackedStringArray()
	var unlocked_recipe_names := PackedStringArray()
	for recipe in recipes:
		if recipe.required_global_research_id == config.research_id:
			unlocked_recipe_names.append(recipe.display_name)
	if not unlocked_recipe_names.is_empty():
		notes.append(
			"实际解锁配方：%s" % "、".join(unlocked_recipe_names)
		)
	else:
		notes.append("研究效果：%s" % config.result_summary)
	return notes


func _load_catalog_texture(path: String) -> Texture2D:
	if path.is_empty() or not ResourceLoader.exists(path, "Texture2D"):
		return null
	return ResourceLoader.load(path, "Texture2D") as Texture2D


func _format_world_distance(value: float) -> String:
	return "%s 像素（%s 格）" % [
		_format_number(value),
		_format_number(value / AUTHORED_TOWER_DEFENSE_TILE_SIZE),
	]


func _get_visibility_state(section: int, entry_id: StringName) -> int:
	var state := _visibility_provider.get_state(section, entry_id)
	if not CodexVisibilityState.is_valid(state):
		push_error(
			"Codex visibility provider returned invalid state %d for %s/%s"
			% [state, CodexSection.get_key(section), entry_id]
		)
		return CodexVisibilityState.REVEALED
	return state


func _build_filter_options(
	entries: Array[CodexEntryViewData]
) -> Array[Dictionary]:
	var counts: Dictionary = {}
	var labels: Dictionary = {}
	var ordered_keys: Array[StringName] = []
	for entry in entries:
		if entry.filter_key == &"":
			continue
		if not counts.has(entry.filter_key):
			ordered_keys.append(entry.filter_key)
			counts[entry.filter_key] = 0
			labels[entry.filter_key] = entry.filter_label
		counts[entry.filter_key] = int(counts[entry.filter_key]) + 1
	var options: Array[Dictionary] = []
	for key in ordered_keys:
		options.append({
			"key": key,
			"label": String(labels[key]),
			"count": int(counts[key]),
		})
	return options


func _get_collectible_entry_id(item: PickupConfig) -> StringName:
	return StringName(
		RuntimeContentCatalog.get_pickup_id_for_path(item.resource_path)
	)


func _get_collectible_stack_badge(item: PickupConfig) -> String:
	return "可叠加" if item.collectible_stacks_by_copy else "唯一生效"


func _get_enemy_rank_accent(rank: int) -> Color:
	match rank:
		EnemyCodexEntryConfig.Rank.ELITE:
			return ENEMY_ELITE_ACCENT
		EnemyCodexEntryConfig.Rank.BOSS:
			return ENEMY_BOSS_ACCENT
		_:
			return ENEMY_NORMAL_ACCENT


func _format_number(value: float) -> String:
	if is_equal_approx(value, roundf(value)):
		return str(int(roundf(value)))
	return "%.2f" % value


func _entry_precedes(
	left: CodexEntryViewData,
	right: CodexEntryViewData
) -> bool:
	if left.sort_group != right.sort_group:
		return left.sort_group < right.sort_group
	if left.sort_order != right.sort_order:
		return left.sort_order < right.sort_order
	var name_comparison := left.display_name.naturalnocasecmp_to(right.display_name)
	if name_comparison != 0:
		return name_comparison < 0
	return String(left.entry_id) < String(right.entry_id)


func _collectible_precedes(left: PickupConfig, right: PickupConfig) -> bool:
	var left_rarity := int(left.collectible_rarity)
	var right_rarity := int(right.collectible_rarity)
	if left_rarity != right_rarity:
		return left_rarity < right_rarity
	var name_comparison := left.display_name.naturalnocasecmp_to(right.display_name)
	if name_comparison != 0:
		return name_comparison < 0
	return left.resource_path < right.resource_path
