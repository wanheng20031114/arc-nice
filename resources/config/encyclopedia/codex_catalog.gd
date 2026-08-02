extends RefCounted
class_name CodexCatalog

const COLLECTIBLE_FILTER_KEYS: Array[StringName] = [
	&"common",
	&"rare",
	&"epic",
	&"legendary",
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
## Authored catalog contract used by navigation before any section is materialized.
## The encyclopedia smoke test verifies these counts against the full registries.
const REGISTERED_ENTRY_COUNTS := {
	CodexSection.ENEMY: 53,
	CodexSection.COLLECTIBLE: 123,
	CodexSection.BUILDING: 16,
}
const COLLECTIBLE_ACCENTS: Array[Color] = [
	Color("#f0e3c2"),
	Color("#68d8ff"),
	Color("#c987ff"),
	Color("#ffae32"),
]
const ENEMY_NORMAL_ACCENT := Color("#6fd4bd")
const ENEMY_ELITE_ACCENT := Color("#c58aff")
const ENEMY_BOSS_ACCENT := Color("#ffcf67")
const BUILDING_ACCENT := Color("#7ed9c4")
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
		var visibility := _get_visibility_state(
			CodexSection.COLLECTIBLE,
			entry_id
		)
		if visibility == CodexVisibilityState.HIDDEN:
			continue
		var rarity := int(item.collectible_rarity)
		var rarity_label := PickupConfig.get_collectible_rarity_label(rarity)
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
		entry.stats = [CodexStatRow.new("稀有度", rarity_label)]
		entry.notes = _build_collectible_notes(item)
		entry.visibility_state = visibility
		entry.source_resource = item
		result.append(entry)
	return result


func _build_building_entries() -> Array[CodexEntryViewData]:
	var result: Array[CodexEntryViewData] = []
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
		entry.notes = _build_building_notes(config.plant_id)
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
	if enemy is CombatRobotGunnerConfig:
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
	return stats


func _build_building_notes(plant_id: StringName) -> PackedStringArray:
	var notes := PackedStringArray()
	var recipe := BuildingItemRegistry.get_primary_acquisition_recipe(plant_id)
	if recipe == null:
		return notes
	var recipe_summary := "主要配方：%s（%s；耗时 %s 秒）" % [
		recipe.display_name,
		recipe.get_input_summary(),
		_format_number(recipe.duration_seconds),
	]
	notes.append(recipe_summary)
	if recipe.required_global_research_id == &"":
		notes.append("科研前置：无")
		return notes
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
	return notes


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
	var file_stem := item.resource_path.get_file().get_basename()
	return StringName(file_stem.trim_prefix(CollectibleRegistry.CONFIG_PREFIX))


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
