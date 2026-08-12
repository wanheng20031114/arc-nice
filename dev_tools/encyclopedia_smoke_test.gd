extends SceneTree

const ENCYCLOPEDIA_SCENE := preload(
	"res://scene/encyclopedia/encyclopedia_screen.tscn"
)
const ENTRY_CARD_SCENE := preload("res://scene/encyclopedia/entry_card.tscn")
const DETAIL_PANEL_SCENE := preload("res://scene/encyclopedia/detail_panel.tscn")
const BASE_VIEWPORT := Vector2i(1152, 648)
const EXPECTED_LEGENDARY_COLOR := Color("ffae32")
const EXPECTED_SECTION_COUNTS := {
	CodexSection.ENEMY: 64,
	CodexSection.COLLECTIBLE: 125,
	CodexSection.BUILDING: 16,
}
const EXPECTED_COLLECTIBLE_RARITY_COUNTS := {
	&"common": 41,
	&"rare": 43,
	&"epic": 26,
	&"legendary": 13,
	&"special": 2,
}
const EXPECTED_BUILDING_CATEGORY_COUNTS := {
	&"defense_tower": 4,
	&"support_tower": 2,
	&"production_building": 6,
	&"technology_building": 1,
	&"fence": 1,
	&"terrain_building": 1,
	&"storage_building": 1,
}
const EXPECTED_ENEMY_FAMILY_COUNTS := {
	&"yuanshi_insect": 16,
	&"slime": 10,
	&"capoo": 16,
	&"sorcerer": 6,
	&"artificial_creation": 4,
	&"mechanical_life": 11,
	&"boss": 1,
}
const EXPECTED_ENEMY_RANK_COUNTS := {
	EnemyCodexEntryConfig.Rank.NORMAL: 51,
	EnemyCodexEntryConfig.Rank.ELITE: 12,
	EnemyCodexEntryConfig.Rank.BOSS: 1,
}
const ATTACK_STAT_LABELS := [
	"攻击伤害",
	"攻击间隔",
	"攻击范围",
	"每轮攻击",
]


class VisibilityFixture:
	extends CodexVisibilityProvider

	var unknown_section: int
	var unknown_id: StringName
	var hidden_section: int
	var hidden_id: StringName


	func _init(
		initial_unknown_section: int,
		initial_unknown_id: StringName,
		initial_hidden_section: int,
		initial_hidden_id: StringName
	) -> void:
		unknown_section = initial_unknown_section
		unknown_id = initial_unknown_id
		hidden_section = initial_hidden_section
		hidden_id = initial_hidden_id


	func get_state(section: int, entry_id: StringName) -> int:
		if section == unknown_section and entry_id == unknown_id:
			return CodexVisibilityState.UNKNOWN
		if section == hidden_section and entry_id == hidden_id:
			return CodexVisibilityState.HIDDEN
		return CodexVisibilityState.REVEALED


var failures: Array[String] = []


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	var catalog := CodexCatalog.new()
	_test_catalog_counts_and_unique_ids(catalog)
	_test_filter_counts(catalog)
	_test_enemy_rank_counts(catalog)
	_test_entry_content(catalog)
	_test_enemy_stat_contract(catalog)
	_test_building_stat_contract(catalog)
	await _test_visibility_contract(catalog)
	await _test_scene_contract()
	catalog.clear_cache()
	catalog = null
	await _cleanup_root()

	if failures.is_empty():
		print("ENCYCLOPEDIA_SMOKE_TEST_OK")
		quit()
		return
	for failure in failures:
		push_error(failure)
	quit(1)


func _test_catalog_counts_and_unique_ids(catalog: CodexCatalog) -> void:
	_expect(
		EnemyCodexRegistry.validate_contract(),
		"EnemyCodexRegistry must expose 64 valid, ordered and unique enemies."
	)
	var globally_seen_ids: Dictionary = {}
	for section_variant in CodexSection.ALL:
		var section := int(section_variant)
		var entries := catalog.get_entries(section)
		var expected_count := int(EXPECTED_SECTION_COUNTS[section])
		_expect(
			catalog.get_total_count(section) == expected_count
			and entries.size() == expected_count,
			"%s catalog must contain exactly %d entries."
			% [CodexSection.get_label(section), expected_count]
		)
		var section_seen_ids: Dictionary = {}
		for entry in entries:
			_expect(
				entry.entry_id != &"",
				"%s catalog contains an empty stable ID."
				% CodexSection.get_label(section)
			)
			_expect(
				not section_seen_ids.has(entry.entry_id),
				"%s catalog repeats stable ID %s."
				% [CodexSection.get_label(section), entry.entry_id]
			)
			section_seen_ids[entry.entry_id] = true
			_expect(
				not globally_seen_ids.has(entry.entry_id),
				"Stable ID %s is reused by multiple codex sections."
				% entry.entry_id
			)
			globally_seen_ids[entry.entry_id] = section


func _test_filter_counts(catalog: CodexCatalog) -> void:
	_expect_filter_counts(
		catalog,
		CodexSection.COLLECTIBLE,
		EXPECTED_COLLECTIBLE_RARITY_COUNTS,
		"Collectible rarity"
	)
	_expect_filter_counts(
		catalog,
		CodexSection.BUILDING,
		EXPECTED_BUILDING_CATEGORY_COUNTS,
		"Building category"
	)
	_expect_filter_counts(
		catalog,
		CodexSection.ENEMY,
		EXPECTED_ENEMY_FAMILY_COUNTS,
		"Enemy family"
	)


func _expect_filter_counts(
	catalog: CodexCatalog,
	section: int,
	expected_counts: Dictionary,
	contract_name: String
) -> void:
	var actual_counts: Dictionary = {}
	for entry in catalog.get_entries(section):
		actual_counts[entry.filter_key] = (
			int(actual_counts.get(entry.filter_key, 0)) + 1
		)
	_expect(
		actual_counts == expected_counts,
		"%s counts are incorrect: %s." % [contract_name, actual_counts]
	)
	var option_counts: Dictionary = {}
	for option in catalog.get_filter_options(section):
		option_counts[StringName(option["key"])] = int(option["count"])
	_expect(
		option_counts == expected_counts,
		"%s filter options must match the catalog entries: %s."
		% [contract_name, option_counts]
	)


func _test_enemy_rank_counts(catalog: CodexCatalog) -> void:
	var actual_counts: Dictionary = {}
	for entry in catalog.get_entries(CodexSection.ENEMY):
		var source := entry.source_resource as EnemyCodexEntryConfig
		if source == null:
			continue
		actual_counts[source.rank] = int(actual_counts.get(source.rank, 0)) + 1
	_expect(
		actual_counts == EXPECTED_ENEMY_RANK_COUNTS,
		"Enemy ranks must contain 50 normal, eleven elite, and one Boss entry."
	)


func _test_entry_content(catalog: CodexCatalog) -> void:
	for section_variant in CodexSection.ALL:
		var section := int(section_variant)
		for entry in catalog.get_entries(section):
			var entry_context := "%s/%s" % [
				CodexSection.get_key(section),
				entry.entry_id,
			]
			_expect(entry.is_valid(), "%s must be valid view data." % entry_context)
			_expect(
				entry.visibility_state == CodexVisibilityState.REVEALED,
				"Default visibility must reveal %s." % entry_context
			)
			_expect(
				not entry.display_name.strip_edges().is_empty(),
				"%s must have a player-facing name." % entry_context
			)
			_expect(
				not entry.description.strip_edges().is_empty(),
				"%s must have a player-facing description." % entry_context
			)
			_expect(
				entry.icon != null,
				"%s must have a catalog image." % entry_context
			)
			if section == CodexSection.ENEMY:
				_expect(
					entry.preview_frames != null
					and entry.preview_frames.has_animation(entry.preview_animation)
					and entry.preview_frames.get_frame_count(entry.preview_animation) > 0,
					"%s must have a valid detail preview animation."
					% entry_context
				)
			elif section == CodexSection.COLLECTIBLE:
				var item := entry.source_resource as PickupConfig
				_expect(
					item != null and entry.description == item.description,
					"%s must use the collectible's public effect description."
					% entry_context
				)
				if item != null and not item.collectible_design_note.is_empty():
					_expect(
						entry.description != item.collectible_design_note,
						"%s must not expose collectible_design_note."
						% entry_context
					)


func _test_enemy_stat_contract(catalog: CodexCatalog) -> void:
	var saw_green_slime := false
	var saw_guardian := false
	var saw_combat_robot := false
	var saw_combat_robot_elite := false
	var saw_combat_robot_gunner := false
	var saw_combat_robot_gunner_elite := false
	var saw_combat_robot_drone_operator := false
	var saw_combat_robot_drone_operator_elite := false
	var saw_combat_robot_shield_bearer := false
	var saw_combat_robot_shield_bearer_elite := false
	var saw_combat_robot_ninja := false
	var saw_combat_robot_ninja_elite := false
	var saw_combat_robot_main_battle_elite := false
	var saw_linglan := false
	for entry in catalog.get_entries(CodexSection.ENEMY):
		var source := entry.source_resource as EnemyCodexEntryConfig
		_expect(source != null, "%s must retain its enemy codex source." % entry.entry_id)
		if source == null:
			continue
		var config := source.enemy_config
		var stats := _stats_to_dictionary(entry.stats)
		_expect(
			entry.stats.size() >= 7
			and _first_stat_labels(entry.stats, 7) == [
				"生命",
				"单次伤害",
				"物理防御",
				"法术防御",
				"移动速度",
				"基地伤害",
				"击杀息壤",
			],
			"Enemy %s must begin with all seven core stat rows."
			% entry.entry_id
		)
		_expect(
			String(stats.get("生命", "")) == str(config.max_health)
			and String(stats.get("单次伤害", "")) == str(config.attack_damage)
			and String(stats.get("移动速度", "")) == _format_number(config.move_speed)
			and String(stats.get("基地伤害", "")) == str(config.home_damage)
			and String(stats.get("击杀息壤", "")) == str(config.xirang_kill_reward),
			"Enemy %s core stats must match EnemyConfig." % entry.entry_id
		)
		_expect(
			String(stats.get("物理防御", "")) == "%d 点" % config.physical_defense,
			"Enemy %s physical defense must use points." % entry.entry_id
		)
		_expect(
			String(stats.get("法术防御", "")) == str(config.magic_defense),
			"Enemy %s spell defense must use a plain value." % entry.entry_id
		)
		_expect(
			entry.preview_frames == source.preview_frames,
			"Enemy %s view data must reuse its authored SpriteFrames."
			% entry.entry_id
		)
		var scene_enemy := (
			config.enemy_scene.instantiate()
			if config.enemy_scene != null
			else null
		)
		var scene_sprite := (
			scene_enemy.get_node_or_null("AnimatedSprite2D") as AnimatedSprite2D
			if scene_enemy != null
			else null
		)
		_expect(
			scene_sprite != null
			and scene_sprite.sprite_frames == entry.preview_frames,
			"Enemy %s combat scene and codex must share one SpriteFrames resource."
			% entry.entry_id
		)
		if scene_enemy != null:
			scene_enemy.free()
		if config is SlimeConfig and config.variant == SlimeConfig.Variant.GREEN:
			saw_green_slime = true
			_expect(
				String(stats.get("每次回复", ""))
				== str(GreenSlime.REGENERATION_AMOUNT)
				and String(stats.get("回复间隔", ""))
				== "%s 秒" % _format_number(
					GreenSlime.REGENERATION_INTERVAL_SECONDS
				),
				"Green slime codex stats must use its typed regeneration constants."
			)
		if config is YuanshiInsectGuardianConfig:
			saw_guardian = true
			var guardian := config as YuanshiInsectGuardianConfig
			_expect(
				String(stats.get("光环半径", ""))
				== _format_number(guardian.aura_radius)
				and String(stats.get("物防增益", ""))
				== "+%d 点" % guardian.aura_physical_defense_bonus,
				"Guardian codex stats must use its typed aura config."
			)
		if config is CombatRobotDroneOperatorEliteConfig:
			saw_combat_robot_drone_operator_elite = true
			var elite_operator := config as CombatRobotDroneOperatorEliteConfig
			_expect(
				String(stats.get("生命", "")) == "360"
				and String(stats.get("单次伤害", "")) == "100"
				and String(stats.get("物理防御", "")) == "20 点"
				and String(stats.get("法术防御", "")) == "15"
				and String(stats.get("移动速度", "")) == "40"
				and String(stats.get("基地伤害", "")) == "2"
				and String(stats.get("击杀息壤", "")) == "10",
				"Elite drone operator codex must expose its authored core attributes."
			)
			_expect(
				String(stats.get("搜索范围", ""))
				== _format_number(elite_operator.attack_range)
				and String(stats.get("停步距离", ""))
				== _format_number(elite_operator.stop_distance)
				and String(stats.get("部署延迟", ""))
				== "%s 秒" % _format_number(elite_operator.deploy_delay)
				and String(stats.get("攻击冷却", ""))
				== "%s 秒" % _format_number(elite_operator.attack_cooldown)
				and String(stats.get("无人机速度", ""))
				== _format_number(elite_operator.drone_speed)
				and String(stats.get("爆炸半径", ""))
				== _format_number(elite_operator.explosion_radius),
				"Elite drone operator codex stats must use its typed deployment config."
			)
			_expect(
				elite_operator.projectile_type == &"combat_robot_suicide_drone_elite"
				and source.sort_order == 545
				and source.family_id == &"mechanical_life"
				and source.rank == EnemyCodexEntryConfig.Rank.ELITE
				and entry.primary_badge == "机械生命"
				and entry.secondary_badge == "精英"
				and source.description
				== "以紫能核心与强化遥控终端驱动的精英爆炸无人机操作员。它会锁死可见目标所在位置，以90的速度投送不可阻挡的紫能无人机；标记出现后落点不会改变，及时离开标记范围仍可躲避爆炸。"
				and entry.notes == PackedStringArray(
					["精英", "紫能投送", "高速无人机"]
				),
				"Elite drone operator must keep its elite mechanical codex contract."
			)
		elif config is CombatRobotDroneOperatorConfig:
			saw_combat_robot_drone_operator = true
			var operator := config as CombatRobotDroneOperatorConfig
			_expect(
				String(stats.get("生命", "")) == "180"
				and String(stats.get("单次伤害", "")) == "50"
				and String(stats.get("物理防御", "")) == "15 点"
				and String(stats.get("法术防御", "")) == "15"
				and String(stats.get("移动速度", "")) == "30"
				and String(stats.get("基地伤害", "")) == "2"
				and String(stats.get("击杀息壤", "")) == "10",
				"Drone operator codex must expose its authored core attributes."
			)
			_expect(
				String(stats.get("搜索范围", ""))
				== _format_number(operator.attack_range)
				and String(stats.get("停步距离", ""))
				== _format_number(operator.stop_distance)
				and String(stats.get("部署延迟", ""))
				== "%s 秒" % _format_number(operator.deploy_delay)
				and String(stats.get("攻击冷却", ""))
				== "%s 秒" % _format_number(operator.attack_cooldown)
				and String(stats.get("无人机速度", ""))
				== _format_number(operator.drone_speed)
				and String(stats.get("爆炸半径", ""))
				== _format_number(operator.explosion_radius),
				"Drone operator codex stats must use its typed deployment config."
			)
			_expect(
				source.sort_order == 540
				and source.family_id == &"mechanical_life"
				and source.rank == EnemyCodexEntryConfig.Rank.NORMAL
				and entry.primary_badge == "机械生命"
				and entry.secondary_badge == "普通"
				and source.description
				== "手持遥控器的冷灰盒体机器人。它会锁定视野内的玩家或植物，在目标位置留下红色标记并放出不可阻挡的自杀式无人机；红标出现后落点不再改变，离开标记范围可以躲避爆炸。"
				and entry.notes == PackedStringArray(
					["定点无人机", "锁死落点", "机械生命"]
				),
				"Drone operator must keep its normal-rank mechanical codex contract."
			)
		if config is CombatRobotGunnerEliteConfig:
			saw_combat_robot_gunner_elite = true
			var elite_gunner := config as CombatRobotGunnerEliteConfig
			_expect(
				String(stats.get("生命", "")) == "360"
				and String(stats.get("单次伤害", "")) == "50"
				and String(stats.get("物理防御", "")) == "20 点"
				and String(stats.get("法术防御", "")) == "15"
				and String(stats.get("移动速度", "")) == "50"
				and String(stats.get("基地伤害", "")) == "2"
				and String(stats.get("击杀息壤", "")) == "10",
				"Elite combat robot gunner codex must expose its authored core attributes."
			)
			_expect(
				String(stats.get("攻击距离", ""))
				== _format_number(elite_gunner.attack_range)
				and String(stats.get("射击前摇", "")) == "0 秒"
				and String(stats.get("每轮射击", ""))
				== "%d 发" % elite_gunner.burst_count
				and String(stats.get("连射间隔", ""))
				== "%s 秒" % _format_number(elite_gunner.burst_fire_interval)
				and String(stats.get("散布范围", ""))
				== "±%s°" % _format_number(elite_gunner.spread_angle_degrees)
				and String(stats.get("射击移速", ""))
				== "%s%%（基础有效速度 %s）" % [
					_format_number(elite_gunner.burst_move_speed_multiplier * 100.0),
					_format_number(
						elite_gunner.move_speed
						* elite_gunner.burst_move_speed_multiplier
					),
				]
				and String(stats.get("攻击冷却", ""))
				== "%s 秒" % _format_number(elite_gunner.attack_cooldown)
				and String(stats.get("弹体速度", ""))
				== _format_number(elite_gunner.projectile_speed)
				and String(stats.get("弹体寿命", ""))
				== "%s 秒" % _format_number(elite_gunner.projectile_lifetime),
				"Elite combat robot gunner codex stats must use its typed burst-fire config."
			)
			_expect(
				elite_gunner.projectile_type == &"combat_robot_gunner_elite_bullet"
				and source.sort_order == 535
				and source.family_id == &"mechanical_life"
				and source.rank == EnemyCodexEntryConfig.Rank.ELITE
				and entry.primary_badge == "机械生命"
				and entry.secondary_badge == "精英"
				and source.description
				== "由紫能核心、轻度重装机体与强化卡宾枪构成的精英持枪战斗机器人。它会锁死目标方向，在追击中快速连射十二发紫能弹；更高的移动速度与更短的冷却使连续火力更加密集。"
				and entry.notes == PackedStringArray(
					["精英", "紫能连射", "强化追击"]
				),
				"Elite gunner must keep its elite mechanical codex contract."
			)
		elif config is CombatRobotGunnerConfig:
			saw_combat_robot_gunner = true
			var gunner := config as CombatRobotGunnerConfig
			_expect(
				String(stats.get("生命", "")) == "180"
				and String(stats.get("单次伤害", "")) == "35"
				and String(stats.get("物理防御", "")) == "10 点"
				and String(stats.get("法术防御", "")) == "15"
				and String(stats.get("移动速度", "")) == "30"
				and String(stats.get("基地伤害", "")) == "2"
				and String(stats.get("击杀息壤", "")) == "10",
				"Combat robot gunner codex must expose its authored core attributes."
			)
			_expect(
				String(stats.get("攻击距离", ""))
				== _format_number(gunner.attack_range)
				and String(stats.get("射击前摇", "")) == "0 秒"
				and String(stats.get("每轮射击", ""))
				== "%d 发" % gunner.burst_count
				and String(stats.get("连射间隔", ""))
				== "%s 秒" % _format_number(gunner.burst_fire_interval)
				and String(stats.get("散布范围", ""))
				== "±%s°" % _format_number(gunner.spread_angle_degrees)
				and String(stats.get("射击移速", ""))
				== "%s%%（基础有效速度 %s）" % [
					_format_number(gunner.burst_move_speed_multiplier * 100.0),
					_format_number(
						gunner.move_speed * gunner.burst_move_speed_multiplier
					),
				]
				and String(stats.get("攻击冷却", ""))
				== "%s 秒" % _format_number(gunner.attack_cooldown)
				and String(stats.get("弹体速度", ""))
				== _format_number(gunner.projectile_speed)
				and String(stats.get("弹体寿命", ""))
				== "%s 秒" % _format_number(gunner.projectile_lifetime),
				"Combat robot gunner codex stats must use its typed burst-fire config."
			)
			_expect(
				source.sort_order == 530
				and source.family_id == &"mechanical_life"
				and source.rank == EnemyCodexEntryConfig.Rank.NORMAL
				and entry.primary_badge == "机械生命"
				and entry.secondary_badge == "普通"
				and source.description
				== "由冷灰方盒机体与线性关节构成的持枪战斗机器人。它锁定玩家或植物后会立即锁死射击方向，以半速追击并移动连射十二发轻微散布弹丸；进入目标 24 像素近距时停步射击，完成一轮后进入冷却。"
				and entry.notes == PackedStringArray(
					["12发连射", "追击射击", "机械生命"]
				),
				"Combat robot gunner must keep its normal-rank mechanical codex contract."
			)
		if config is CombatRobotShieldBearerEliteConfig:
			saw_combat_robot_shield_bearer_elite = true
			var elite_shield_bearer := config as CombatRobotShieldBearerEliteConfig
			_expect(
				String(stats.get("生命", "")) == "400"
				and String(stats.get("单次伤害", "")) == "60"
				and String(stats.get("物理防御", "")) == "35 点"
				and String(stats.get("法术防御", "")) == "20"
				and String(stats.get("移动速度", "")) == "40"
				and String(stats.get("基地伤害", "")) == "2"
				and String(stats.get("击杀息壤", "")) == "10"
				and String(stats.get("盾牌抵消", ""))
				== "%d 次" % elite_shield_bearer.shield_max_blocks
				and String(stats.get("开裂阈值", ""))
				== "%d 次" % elite_shield_bearer.shield_cracked_remaining
				and String(stats.get("危急阈值", ""))
				== "%d 次" % elite_shield_bearer.shield_critical_remaining,
				"Elite shield bearer codex must expose 400/60/35/20/40 and 50/33/16."
			)
			_expect(
				source.entry_id == &"combat_robot_shield_bearer_elite"
				and source.sort_order == 555
				and source.family_id == &"mechanical_life"
				and source.rank == EnemyCodexEntryConfig.Rank.ELITE
				and entry.primary_badge == "机械生命"
				and entry.secondary_badge == "精英"
				and source.description
				== "以紫能纵脊强化塔盾的精英举盾战斗机器人。它能从正面完整格挡50发实体弹丸或机枪塔射线，第50发会击碎盾牌，第51发起可直接命中本体；爆炸弹仍会在盾面引爆并可能以范围伤害波及本体，绕过盾缘或从侧后方进攻也能避开塔盾。"
				and entry.notes == PackedStringArray(
					["精英", "50次格挡", "紫能塔盾"]
				),
				"Elite shield bearer must keep its elite mechanical codex contract."
			)
		elif config is CombatRobotShieldBearerConfig:
			saw_combat_robot_shield_bearer = true
			var shield_bearer := config as CombatRobotShieldBearerConfig
			_expect(
				String(stats.get("生命", "")) == "180"
				and String(stats.get("单次伤害", "")) == "30"
				and String(stats.get("物理防御", "")) == "25 点"
				and String(stats.get("法术防御", "")) == "10"
				and String(stats.get("移动速度", "")) == "30"
				and String(stats.get("基地伤害", "")) == "2"
				and String(stats.get("击杀息壤", "")) == "10"
				and String(stats.get("盾牌抵消", ""))
				== "%d 次" % shield_bearer.shield_max_blocks
				and String(stats.get("开裂阈值", ""))
				== "%d 次" % shield_bearer.shield_cracked_remaining
				and String(stats.get("危急阈值", ""))
				== "%d 次" % shield_bearer.shield_critical_remaining,
				"Shield bearer codex must expose its authored attributes and shield stages."
			)
			_expect(
				source.sort_order == 550
				and source.family_id == &"mechanical_life"
				and source.rank == EnemyCodexEntryConfig.Rank.NORMAL
				and entry.primary_badge == "机械生命"
				and entry.secondary_badge == "普通"
				and entry.notes == PackedStringArray(
					["正面盾牌", "20次格挡", "机械生命"]
				),
				"Shield bearer must keep its normal-rank mechanical codex contract."
			)
		if config is CombatRobotNinjaEliteConfig:
			saw_combat_robot_ninja_elite = true
			var elite_ninja := config as CombatRobotNinjaEliteConfig
			_expect(
				String(stats.get("生命", "")) == "360"
				and String(stats.get("单次伤害", "")) == "70"
				and String(stats.get("物理防御", "")) == "20 点"
				and String(stats.get("法术防御", "")) == "20"
				and String(stats.get("移动速度", "")) == "80"
				and String(stats.get("基地伤害", "")) == "2"
				and String(stats.get("击杀息壤", "")) == "10"
				and String(stats.get("受击加速", ""))
				== "%s 倍" % _format_number(elite_ninja.boost_speed_multiplier)
				and String(stats.get("加速持续", ""))
				== "%s 秒" % _format_number(elite_ninja.boost_duration)
				and String(stats.get("触发冷却", ""))
				== "%s 秒" % _format_number(elite_ninja.boost_cooldown),
				"Elite ninja robot codex must expose its authored attributes and boost contract."
			)
			_expect(
				source.sort_order == 565
				and source.family_id == &"mechanical_life"
				and source.rank == EnemyCodexEntryConfig.Rank.ELITE
				and entry.primary_badge == "机械生命"
				and entry.secondary_badge == "精英"
				and source.description
				== "由紫能双刃与腕部强化结构升级的精英忍者战斗机器人。任何实际扣血都会令其立刻进入短暂反击疾跑，当前有效移动速度提高至2倍并持续0.5秒，触发冷却为2秒；持续期间再次受伤不会刷新或排队。"
				and entry.notes == PackedStringArray(
					["精英", "高频反击", "紫能双刃"]
				),
				"Elite ninja robot must keep its elite mechanical codex contract."
			)
		elif config is CombatRobotNinjaConfig:
			saw_combat_robot_ninja = true
			var ninja := config as CombatRobotNinjaConfig
			_expect(
				String(stats.get("生命", "")) == "180"
				and String(stats.get("单次伤害", "")) == "35"
				and String(stats.get("物理防御", "")) == "10 点"
				and String(stats.get("法术防御", "")) == "15"
				and String(stats.get("移动速度", "")) == "80"
				and String(stats.get("基地伤害", "")) == "2"
				and String(stats.get("击杀息壤", "")) == "10"
				and String(stats.get("受击加速", ""))
				== "%s 倍" % _format_number(ninja.boost_speed_multiplier)
				and String(stats.get("加速持续", ""))
				== "%s 秒" % _format_number(ninja.boost_duration)
				and String(stats.get("触发冷却", ""))
				== "%s 秒" % _format_number(ninja.boost_cooldown),
				"Ninja robot codex must expose its authored attributes and boost contract."
			)
			_expect(
				source.sort_order == 560
				and source.family_id == &"mechanical_life"
				and source.rank == EnemyCodexEntryConfig.Rank.NORMAL
				and entry.primary_badge == "机械生命"
				and entry.secondary_badge == "普通"
				and source.description
				== "双持长刃的高速冷灰盒体机器人。它会持续追踪玩家或植物，并以刀刃和身体造成接触伤害；任何实际扣血都会令其立刻进入短暂疾跑，移动速度提高至两倍并留下反向尾影。加速不会改变追踪方向，也不能穿过墙体或水域。"
				and entry.notes == PackedStringArray(
					["受击加速", "双刃接触", "机械生命"]
				),
				"Ninja robot must keep its normal-rank mechanical codex contract."
			)
		if config is CombatRobotMainBattleEliteConfig:
			saw_combat_robot_main_battle_elite = true
			_expect(
				source.entry_id == &"combat_robot_main_battle_elite"
				and source.sort_order == 570
				and source.family_id == &"mechanical_life"
				and source.rank == EnemyCodexEntryConfig.Rank.ELITE
				and entry.primary_badge == "机械生命"
				and entry.secondary_badge == "精英"
				and source.preview_animation == &"move"
				and source.preview_scale.is_equal_approx(Vector2(0.125, 0.125))
				and entry.preview_scale.is_equal_approx(source.preview_scale)
				and source.description
				== "双持重剑的精英主战机器人。它会锁定方向高速冲锋并以双剑圆斩点燃周围目标，也会短暂升空，以限速移动的十字追踪目标后落地发动双剑扇斩。"
				and entry.notes == PackedStringArray(
					["精英", "双持重剑", "冲锋落砸"]
				),
				"Main battle robot must keep its released elite mechanical codex contract."
			)
		if config is CombatRobotEliteConfig:
			saw_combat_robot_elite = true
			var elite_robot := config as CombatRobotEliteConfig
			_expect(
				String(stats.get("生命", "")) == "360"
				and String(stats.get("单次伤害", "")) == "70"
				and String(stats.get("物理防御", "")) == "15 点"
				and String(stats.get("法术防御", "")) == "20"
				and String(stats.get("移动速度", "")) == "40"
				and String(stats.get("基地伤害", "")) == "2"
				and String(stats.get("击杀息壤", "")) == "10",
				"Elite combat robot codex must expose its authored core attributes."
			)
			_expect(
				String(stats.get("锁定范围", ""))
				== _format_number(elite_robot.dash_trigger_range)
				and String(stats.get("冲刺前摇", ""))
				== "%s 秒" % _format_number(elite_robot.dash_windup)
				and String(stats.get("冲刺速度", ""))
				== _format_number(elite_robot.dash_speed)
				and String(stats.get("最长冲刺", ""))
				== "%s 秒" % _format_number(elite_robot.dash_duration)
				and String(stats.get("冲刺冷却", ""))
				== "%s 秒" % _format_number(elite_robot.dash_cooldown),
				"Elite combat robot codex stats must use its typed dash config."
			)
			_expect(
				source.sort_order == 525
				and source.family_id == &"mechanical_life"
				and source.rank == EnemyCodexEntryConfig.Rank.ELITE
				and entry.primary_badge == "机械生命"
				and entry.secondary_badge == "精英"
				and source.description
				== "由紫能核心与轻度重装结构强化的精英战斗机器人。它拥有更高的生命、攻击与追踪速度，并会以更快的冲刺速度贯穿目标，在前方留下长达182像素的紫色冲刺走廊。"
				and entry.notes == PackedStringArray(
					["精英", "强化冲刺", "紫能重装"]
				),
				"Elite combat robot must keep its elite mechanical codex contract."
			)
		elif config is CombatRobotConfig:
			saw_combat_robot = true
			var robot := config as CombatRobotConfig
			_expect(
				String(stats.get("锁定范围", ""))
				== _format_number(robot.dash_trigger_range)
				and String(stats.get("冲刺前摇", ""))
				== "%s 秒" % _format_number(robot.dash_windup)
				and String(stats.get("冲刺速度", ""))
				== _format_number(robot.dash_speed)
				and String(stats.get("最长冲刺", ""))
				== "%s 秒" % _format_number(robot.dash_duration)
				and String(stats.get("冲刺冷却", ""))
				== "%s 秒" % _format_number(robot.dash_cooldown),
				"Combat robot codex stats must use its typed dash config."
			)
			_expect(
				entry.primary_badge == "机械生命"
				and entry.notes == PackedStringArray(
					["定向冲刺", "冲刺可穿透", "机械生命"]
				),
				"Combat robot must expose its mechanical-life family and dash traits."
			)
		if source.boss_config != null:
			saw_linglan = true
			_expect(
				stats.has("环形弹幕")
				and stats.has("追踪火箭")
				and stats.has("膨胀光球")
				and stats.has("收缩激光"),
				"Linglan must expose typed values for all four boss skills."
			)
	_expect(
		saw_green_slime
		and saw_guardian
		and saw_combat_robot
		and saw_combat_robot_elite
		and saw_combat_robot_gunner
		and saw_combat_robot_gunner_elite
		and saw_combat_robot_drone_operator
		and saw_combat_robot_drone_operator_elite
		and saw_combat_robot_shield_bearer
		and saw_combat_robot_shield_bearer_elite
		and saw_combat_robot_ninja
		and saw_combat_robot_ninja_elite
		and saw_combat_robot_main_battle_elite
		and saw_linglan,
		"Enemy stat contract must cover regeneration, aura, all released mechanical enemies including the main battle robot, and Boss adapters."
	)


func _test_building_stat_contract(catalog: CodexCatalog) -> void:
	var zero_attack_count := 0
	for entry in catalog.get_entries(CodexSection.BUILDING):
		var config := entry.source_resource as PlantDefenseConfig
		_expect(config != null, "%s must retain its building config." % entry.entry_id)
		if config == null:
			continue
		var stats := _stats_to_dictionary(entry.stats)
		_expect(
			String(stats.get("生命", "")) == str(config.max_health)
			and String(stats.get("物理防御", "")) == "%d 点" % config.physical_defense
			and String(stats.get("法术防御", "")) == str(config.magic_defense),
			"Building %s defenses must match PlantDefenseConfig display values."
			% entry.entry_id
		)
		_expect(
			entry.primary_badge
			== PlantDefenseConfig.get_building_category_label(config.building_category)
			and entry.secondary_badge
			== PlantDefenseConfig.get_placement_surface_label(config.placement_surface),
			"Building %s must expose category and terrain labels."
			% entry.entry_id
		)
		_expect(
			entry.notes.size() >= 2
			and entry.notes[0].begins_with("主要配方：")
			and entry.notes[1].begins_with("科研前置："),
			"Building %s must expose its primary recipe and research prerequisite."
			% entry.entry_id
		)
		if config.attack_damage > 0:
			continue
		zero_attack_count += 1
		for attack_label in ATTACK_STAT_LABELS:
			_expect(
				not stats.has(attack_label),
				"Zero-attack building %s must omit %s."
				% [entry.entry_id, attack_label]
			)
	_expect(
		zero_attack_count > 0,
		"Building contract must exercise at least one zero-attack building."
	)


func _test_visibility_contract(default_catalog: CodexCatalog) -> void:
	var default_enemies := default_catalog.get_entries(CodexSection.ENEMY)
	_expect(
		default_enemies.size() >= 2,
		"Visibility fixture requires at least two enemy entries."
	)
	if default_enemies.size() < 2:
		return
	var unknown_source := default_enemies[0]
	var hidden_source := default_enemies[1]
	var provider := VisibilityFixture.new(
		CodexSection.ENEMY,
		unknown_source.entry_id,
		CodexSection.ENEMY,
		hidden_source.entry_id
	)
	var catalog := CodexCatalog.new(provider)
	var entries := catalog.get_entries(CodexSection.ENEMY)
	var unknown_entry := _find_entry(entries, unknown_source.entry_id)
	var hidden_entry := _find_entry(entries, hidden_source.entry_id)
	_expect(
		entries.size() == int(EXPECTED_SECTION_COUNTS[CodexSection.ENEMY]) - 1,
		"HIDDEN must remove exactly one enemy from the catalog."
	)
	_expect(
		unknown_entry != null
		and unknown_entry.visibility_state == CodexVisibilityState.UNKNOWN,
		"UNKNOWN must remain in the catalog with its visibility state."
	)
	_expect(hidden_entry == null, "HIDDEN must be absent from catalog results.")
	if unknown_entry == null:
		return
	_expect(
		unknown_entry.display_name == unknown_source.display_name
		and unknown_entry.icon == unknown_source.icon,
		"UNKNOWN view data must retain authoritative content for the UI mask."
	)
	await _test_unknown_ui_mask(unknown_entry)


func _test_unknown_ui_mask(entry: CodexEntryViewData) -> void:
	var card := ENTRY_CARD_SCENE.instantiate() as EncyclopediaEntryCard
	root.add_child(card)
	await process_frame
	card.setup(entry)
	var icon := card.get_node("Margin/Content/ArtworkFrame/Icon") as TextureRect
	var glyph := card.get_node("Margin/Content/ArtworkFrame/UnknownGlyph") as Label
	var name := card.get_node("Margin/Content/Name") as Label
	var badge := card.get_node("Margin/Content/Badge") as Label
	var button := card.get_node("SelectButton") as Button
	_expect(
		not icon.visible and icon.texture == null and glyph.visible and glyph.text == "?",
		"UNKNOWN card must replace the real image with a question mark."
	)
	_expect(
		name.text == "未发现" and badge.text == "未知档案",
		"UNKNOWN card must hide the real name and badge."
	)
	var pressed_entries: Array[CodexEntryViewData] = []
	card.entry_pressed.connect(
		func(pressed_entry: CodexEntryViewData) -> void:
			pressed_entries.append(pressed_entry)
	)
	button.pressed.emit()
	_expect(
		pressed_entries.is_empty(),
		"UNKNOWN card must not open its detail view."
	)

	var detail := DETAIL_PANEL_SCENE.instantiate() as EncyclopediaDetailPanel
	root.add_child(detail)
	await process_frame
	detail.show_entry(entry)
	_expect(
		detail.current_entry == null,
		"Detail panel must reject UNKNOWN entries."
	)
	detail.queue_free()
	card.queue_free()
	await process_frame


func _test_scene_contract() -> void:
	root.content_scale_size = BASE_VIEWPORT
	root.size = BASE_VIEWPORT
	var screen := ENCYCLOPEDIA_SCENE.instantiate() as EncyclopediaScreen
	_expect(screen != null, "Encyclopedia scene must instantiate as EncyclopediaScreen.")
	if screen == null:
		return
	root.add_child(screen)
	current_scene = screen
	await _wait_frames(3)
	await _wait_for_grid_build(screen)
	var expected_enemy_count := int(
		EXPECTED_SECTION_COUNTS[CodexSection.ENEMY]
	)

	_expect(
		screen.enemy_button.text == "敌人  %d" % expected_enemy_count
		and screen.collectible_button.text == "收藏品  125"
		and screen.building_button.text == "建筑物  16",
		"Sidebar must display all three section totals."
	)
	var nav_style := screen.enemy_button.get_theme_stylebox(&"normal") as StyleBoxFlat
	_expect(
		nav_style != null and nav_style.content_margin_left >= 12.0,
		"Sidebar section labels must keep at least 12 px of left breathing room."
	)
	_expect(
		int(screen.get("_current_section")) == CodexSection.ENEMY
		and screen.section_title.text == "敌人档案"
		and screen.archive_index.text == "%03d 条记录" % expected_enemy_count,
		"Encyclopedia must open on the enemy section."
	)
	var cards: Array = screen.get("_cards")
	_expect(
		cards.size() == expected_enemy_count
		and screen.entry_grid.get_child_count() == expected_enemy_count
		and screen.result_count.text
		== "显示 %d / %d" % [expected_enemy_count, expected_enemy_count],
		"Initial enemy grid must render every registered enemy entry."
	)
	_expect(
		screen.search_edit.text.is_empty()
		and screen.filter_button.item_count
		== EXPECTED_ENEMY_FAMILY_COUNTS.size() + 1,
		"Initial toolbar must have an empty search and all enemy family filters."
	)
	_expect(
		not screen.detail_panel.visible
		and screen.detail_panel.current_entry == null,
		"Detail inspector must start closed."
	)
	_expect(
		screen.grid_scroll.follow_focus
		and screen.enemy_button.focus_mode == Control.FOCUS_ALL,
		"Initial catalog must support keyboard and gamepad focus navigation."
	)

	await create_timer(EncyclopediaScreen.PAGE_ENTRANCE_DURATION + 0.06).timeout
	_expect(
		screen.enemy_button.has_focus(),
		"Page entrance must finish with focus on the enemy section button."
	)
	await _test_detail_layout_regression(screen, cards)
	await _test_compact_detail_layout(screen)
	await _test_short_filter_anchor(screen)
	await _test_detail_section_switch_race(screen)
	await _test_collectible_filter_visuals(screen)
	await _test_search_filter_and_section_state(screen)
	current_scene = null
	screen.queue_free()
	await _wait_frames(3)


func _test_detail_layout_regression(
	screen: EncyclopediaScreen,
	cards: Array
) -> void:
	_expect(not cards.is_empty(), "Detail layout fixture requires at least one card.")
	if cards.is_empty():
		return
	var closed_columns := screen.entry_grid.columns
	var closed_scroll := screen.grid_scroll.scroll_vertical
	_expect(
		closed_columns > 1,
		"Closed 1152×648 grid must expose multiple columns."
	)
	var selected_index := mini(maxi(closed_columns - 1, 0), cards.size() - 1)
	var selected_card := cards[selected_index] as EncyclopediaEntryCard
	_expect(
		selected_card != null,
		"Responsive-grid fixture must select a valid card near the first-row edge."
	)
	if selected_card == null:
		return
	var selected_focus := selected_card.get_focus_control()
	selected_focus.grab_focus()
	await _wait_frames(2)
	var closed_anchor_y := selected_card.global_position.y
	_expect_grid_row_fill(screen, cards, closed_columns, "Closed grid")

	selected_focus.pressed.emit()
	await create_timer(EncyclopediaScreen.DETAIL_TRANSITION_DURATION * 0.22).timeout
	var opening_grid_progress := clampf(
		absf(screen.grid_pane.offset_right)
		/ (EncyclopediaScreen.DETAIL_WIDTH + EncyclopediaScreen.DETAIL_GAP),
		0.0,
		1.0
	)
	var opening_detail_progress := clampf(
		absf(screen.detail_panel.offset_left) / EncyclopediaScreen.DETAIL_WIDTH,
		0.0,
		1.0
	)
	_expect(
		opening_grid_progress > 0.05
		and opening_grid_progress < 0.98
		and absf(opening_grid_progress - opening_detail_progress) <= 0.08,
		(
			"Grid pane and detail inspector must narrow in sync; "
			+ "grid=%.3f detail=%.3f."
		)
		% [opening_grid_progress, opening_detail_progress]
	)
	await create_timer(
		EncyclopediaScreen.DETAIL_TRANSITION_DURATION + 0.06
	).timeout
	await _wait_frames(3)
	var open_columns := screen.entry_grid.columns
	var workspace_rect := screen.workspace.get_global_rect()
	var first_card_rect := (cards[0] as EncyclopediaEntryCard).get_global_rect()
	var detail_rect := screen.detail_panel.get_global_rect()
	_expect(
		open_columns < closed_columns,
		"Opening the 344 px inspector must reduce the responsive grid column count."
	)
	_expect(
		first_card_rect.position.x >= workspace_rect.position.x - 1.0,
		"Opening details must not push the first card left of the workspace."
	)
	_expect(
		detail_rect.position.x >= workspace_rect.position.x - 1.0
		and detail_rect.position.y >= workspace_rect.position.y - 1.0
		and detail_rect.end.x <= workspace_rect.end.x + 1.0
		and detail_rect.end.y <= workspace_rect.end.y + 1.0,
		"Detail inspector must remain fully inside the workspace at 1152×648."
	)
	_expect(
		absf(detail_rect.size.x - EncyclopediaScreen.DETAIL_WIDTH) <= 2.0,
		"Detail inspector width must remain approximately 344 px; got %.2f px."
		% detail_rect.size.x
	)
	_expect(
		absf(selected_card.global_position.y - closed_anchor_y) <= 3.0,
		"Grid reflow must preserve the selected card's screen-space Y anchor."
	)
	_expect(
		selected_focus.has_focus(),
		"Opening details must retain focus on the selected card."
	)
	_expect_grid_row_fill(screen, cards, open_columns, "Open grid")

	screen.detail_panel.get_close_button().pressed.emit()
	await create_timer(EncyclopediaScreen.DETAIL_TRANSITION_DURATION * 0.22).timeout
	var closing_grid_progress := clampf(
		1.0
		- absf(screen.grid_pane.offset_right)
		/ (EncyclopediaScreen.DETAIL_WIDTH + EncyclopediaScreen.DETAIL_GAP),
		0.0,
		1.0
	)
	var closing_detail_progress := clampf(
		1.0
		- absf(screen.detail_panel.offset_left)
		/ EncyclopediaScreen.DETAIL_WIDTH,
		0.0,
		1.0
	)
	_expect(
		closing_grid_progress > 0.05
		and closing_grid_progress < 0.98
		and absf(closing_grid_progress - closing_detail_progress) <= 0.08,
		(
			"Grid pane and detail inspector must widen in sync; "
			+ "grid=%.3f detail=%.3f."
		)
		% [closing_grid_progress, closing_detail_progress]
	)
	await create_timer(
		EncyclopediaScreen.DETAIL_TRANSITION_DURATION + 0.06
	).timeout
	await _wait_frames(3)
	_expect(
		screen.entry_grid.columns == closed_columns,
		"Closing details must restore the original responsive column count."
	)
	_expect(
		screen.grid_scroll.scroll_vertical == closed_scroll,
		"Closing details must restore the prior grid scroll position."
	)
	_expect(
		absf(selected_card.global_position.y - closed_anchor_y) <= 3.0,
		"Closing details must restore the selected card's screen-space anchor."
	)
	_expect(
		selected_focus.has_focus(),
		"Closing details must restore focus to the selected card."
	)
	_expect_grid_row_fill(screen, cards, closed_columns, "Restored grid")


func _expect_grid_row_fill(
	screen: EncyclopediaScreen,
	cards: Array,
	columns: int,
	context: String
) -> void:
	if cards.is_empty() or columns <= 0:
		_expect(false, "%s requires cards and at least one column." % context)
		return
	var right_index := mini(columns - 1, cards.size() - 1)
	var right_card := cards[right_index] as EncyclopediaEntryCard
	if right_card == null:
		_expect(false, "%s right-edge card is invalid." % context)
		return
	var right_gap := (
		screen.grid_scroll.get_global_rect().end.x
		- right_card.get_global_rect().end.x
	)
	_expect(
		right_gap >= 8.0 and right_gap <= 40.0,
		"%s must distribute its first row across the available width; gap=%.2f px."
		% [context, right_gap]
	)


func _test_compact_detail_layout(screen: EncyclopediaScreen) -> void:
	var compact_viewport := Vector2i(1024, 640)
	root.content_scale_size = compact_viewport
	root.size = compact_viewport
	await _wait_frames(4)
	var cards: Array = screen.get("_cards")
	_expect(not cards.is_empty(), "Compact detail fixture requires at least one card.")
	if cards.is_empty():
		root.content_scale_size = BASE_VIEWPORT
		root.size = BASE_VIEWPORT
		await _wait_frames(4)
		return
	var selected_index := mini(maxi(screen.entry_grid.columns - 1, 0), cards.size() - 1)
	var selected_card := cards[selected_index] as EncyclopediaEntryCard
	var selected_anchor_y := selected_card.global_position.y
	selected_card.get_focus_control().pressed.emit()
	await create_timer(
		EncyclopediaScreen.DETAIL_TRANSITION_DURATION + 0.06
	).timeout
	await _wait_frames(3)
	var workspace_rect := screen.workspace.get_global_rect()
	var grid_rect := screen.grid_pane.get_global_rect()
	var detail_rect := screen.detail_panel.get_global_rect()
	_expect(
		grid_rect.position.x >= workspace_rect.position.x - 1.0
		and detail_rect.position.x - grid_rect.end.x >= 8.0,
		(
			"Compact 1024×640 layout must keep the grid pane inside its animated region; "
			+ "workspace=%s grid=%s detail=%s."
		)
		% [workspace_rect, grid_rect, detail_rect]
	)
	_expect(
		screen.grid_pane.get_combined_minimum_size().x <= screen.grid_pane.size.x + 1.0,
		"Compact detail toolbar must not force the grid pane wider than its viewport."
	)
	for control in [screen.section_title, screen.search_edit, screen.filter_button]:
		var control_rect: Rect2 = control.get_global_rect()
		_expect(
			control_rect.position.x >= grid_rect.position.x - 1.0
			and control_rect.end.x <= grid_rect.end.x + 1.0,
			"Compact detail header and toolbar controls must not be clipped by reflow."
		)
	_expect(
		absf(selected_card.global_position.y - selected_anchor_y) <= 3.0,
		"Compact detail reflow must preserve the selected card's screen-space Y anchor."
	)
	screen.detail_panel.get_close_button().pressed.emit()
	await create_timer(
		EncyclopediaScreen.DETAIL_TRANSITION_DURATION + 0.06
	).timeout
	root.content_scale_size = BASE_VIEWPORT
	root.size = BASE_VIEWPORT
	await _wait_frames(4)


func _test_short_filter_anchor(screen: EncyclopediaScreen) -> void:
	_expect(
		_select_filter(screen, &"sorcerer"),
		"Enemy toolbar must expose the six-entry sorcerer filter."
	)
	await _wait_frames(4)
	await _wait_for_grid_build(screen)
	var cards: Array = screen.get("_cards")
	_expect(
		cards.size() == 6,
		"Short anchor regression requires exactly six sorcerer cards."
	)
	if cards.size() != 6:
		_select_filter(screen, &"")
		await _wait_frames(3)
		await _wait_for_grid_build(screen)
		return
	var selected_card := cards[5] as EncyclopediaEntryCard
	var selected_anchor_y := selected_card.global_position.y
	selected_card.get_focus_control().pressed.emit()
	await create_timer(
		EncyclopediaScreen.DETAIL_TRANSITION_DURATION + 0.08
	).timeout
	await _wait_frames(4)
	_expect(
		absf(selected_card.global_position.y - selected_anchor_y) <= 3.0,
		(
			"A short filtered grid must preserve the selected card anchor even when "
			+ "its original content has no scroll range."
		)
	)
	_expect(
		int(screen.get("_grid_anchor_extra_bottom")) > 0,
		"Short filtered reflow must reserve temporary scroll capacity for anchoring."
	)
	_expect(
		_select_filter(screen, &""),
		"Changing filters while details are open must remain available."
	)
	await _wait_frames(4)
	await _wait_for_grid_build(screen)
	_expect(
		int(screen.get("_grid_anchor_extra_bottom")) == 0
		and screen.grid_margin.get_theme_constant(&"margin_bottom")
		== EncyclopediaScreen.GRID_BASE_BOTTOM_MARGIN,
		"Rebuilding an open detail grid must remove stale anchor padding."
	)
	screen.detail_panel.get_close_button().pressed.emit()
	await create_timer(
		EncyclopediaScreen.DETAIL_TRANSITION_DURATION + 0.08
	).timeout
	await _wait_frames(5)
	_expect(
		int(screen.get("_grid_anchor_extra_bottom")) == 0,
		"Temporary anchor padding must be removed after the inspector closes."
	)


func _test_detail_section_switch_race(screen: EncyclopediaScreen) -> void:
	var cards: Array = screen.get("_cards")
	_expect(not cards.is_empty(), "Detail race fixture requires an enemy card.")
	if cards.is_empty():
		return
	(cards[0] as EncyclopediaEntryCard).get_focus_control().pressed.emit()
	await create_timer(
		EncyclopediaScreen.DETAIL_TRANSITION_DURATION + 0.05
	).timeout
	screen.detail_panel.get_close_button().pressed.emit()
	await create_timer(0.03).timeout
	screen.collectible_button.pressed.emit()
	await create_timer(
		EncyclopediaScreen.DETAIL_TRANSITION_DURATION
		+ EncyclopediaScreen.SECTION_TRANSITION_DURATION
		+ 0.08
	).timeout
	await _wait_frames(4)
	_expect(
		int(screen.get("_current_section")) == CodexSection.COLLECTIBLE
		and not screen.detail_panel.visible
		and is_zero_approx(screen.grid_pane.offset_right)
		and is_equal_approx(screen.grid_area.modulate.a, 1.0),
		"Switching sections during detail close must settle on a clean catalog layout."
	)
	_expect(
		screen.get("_detail_tween") == null
		and screen.get("_grid_reflow_tween") == null
		and not bool(screen.get("_layout_transition_active")),
		"A section switch must cancel stale detail and grid-reflow tweens."
	)
	await _switch_section(screen, screen.enemy_button)


func _test_collectible_filter_visuals(screen: EncyclopediaScreen) -> void:
	await _switch_section(screen, screen.collectible_button)
	_expect(
		screen.filter_button.item_count
		== EXPECTED_COLLECTIBLE_RARITY_COUNTS.size() + 2,
		"Collectible filters must include all, four rarities and stackable."
	)
	for key_variant in EXPECTED_COLLECTIBLE_RARITY_COUNTS:
		var key := StringName(key_variant)
		var index := _find_filter_index(screen, key)
		_expect(index >= 0, "Collectible filter must expose %s." % key)
		if index < 0:
			continue
		var icon := screen.filter_button.get_item_icon(index) as GradientTexture2D
		_expect(
			icon != null
			and icon.width == 12
			and icon.height == 12
			and icon.gradient != null,
			"Collectible rarity %s must have a visible 12 px color swatch." % key
		)
		if icon != null and icon.gradient != null and key == &"legendary":
			_expect(
				icon.gradient.get_color(0).is_equal_approx(
					EXPECTED_LEGENDARY_COLOR
				),
				"Legendary filter swatch must use the vivid amber-gold palette."
			)

	var catalog: CodexCatalog = screen.get("_catalog")
	var stackable_count := 0
	for entry in catalog.get_entries(CodexSection.COLLECTIBLE):
		if entry.secondary_badge == "可叠加":
			stackable_count += 1
		if entry.filter_key == &"legendary":
			_expect(
				entry.accent_color.is_equal_approx(EXPECTED_LEGENDARY_COLOR),
				"Legendary cards and details must share the vivid amber-gold accent."
			)
	var stackable_index := _find_filter_index(
		screen,
		EncyclopediaScreen.STACKABLE_FILTER_KEY
	)
	_expect(stackable_index >= 0, "Collectible filters must expose stackable.")
	if stackable_index >= 0:
		_expect(
			screen.filter_button.get_item_text(stackable_index)
			== "可叠加  %d" % stackable_count,
			"Stackable filter must display its authoritative result count."
		)
		_expect(
			screen.filter_button.get_item_icon(stackable_index) != null,
			"Stackable filter must have a dedicated visual marker."
		)
		_expect(
			_select_filter(screen, EncyclopediaScreen.STACKABLE_FILTER_KEY),
			"Stackable filter must be selectable."
		)
		await _wait_frames(3)
		await _wait_for_grid_build(screen)
		var stackable_cards: Array = screen.get("_cards")
		_expect(
			stackable_cards.size() == stackable_count,
			"Stackable filter result count must match catalog metadata."
		)
		for card_variant in stackable_cards:
			var card := card_variant as EncyclopediaEntryCard
			_expect(
				card != null and card.entry_data.secondary_badge == "可叠加",
				"Stackable filter must exclude unique-effect collectibles."
			)

	_expect(_select_filter(screen, &""), "Collectible filters must reset to all.")
	await _wait_frames(3)
	await _wait_for_grid_build(screen)
	await _switch_section(screen, screen.enemy_button)


func _test_search_filter_and_section_state(
	screen: EncyclopediaScreen
) -> void:
	var expected_enemy_count := int(
		EXPECTED_SECTION_COUNTS[CodexSection.ENEMY]
	)
	_set_search_query(screen, "铃兰")
	await _wait_frames(3)
	await _wait_for_grid_build(screen)
	var search_cards: Array = screen.get("_cards")
	_expect(
		not search_cards.is_empty()
		and search_cards.size() < expected_enemy_count,
		"Enemy name search must narrow the visible result set."
	)
	_expect(
		screen.result_count.text
		== "显示 %d / %d" % [search_cards.size(), expected_enemy_count],
		"Result count must stay synchronized with name-search results."
	)
	for card_variant in search_cards:
		var search_card := card_variant as EncyclopediaEntryCard
		_expect(
			search_card != null
			and search_card.entry_data.display_name.contains("铃兰"),
			"Enemy name search must only keep matching cards."
		)

	_set_search_query(screen, "")
	await _wait_frames(3)
	await _wait_for_grid_build(screen)
	var enemy_filter_key := &"yuanshi_insect"
	_expect(
		_select_filter(screen, enemy_filter_key),
		"Enemy toolbar must expose the yuanshi_insect family filter."
	)
	await _wait_frames(3)
	await _wait_for_grid_build(screen)
	_set_search_query(screen, "原石虫")
	await _wait_frames(3)
	await _wait_for_grid_build(screen)
	var enemy_cards: Array = screen.get("_cards")
	_expect(
		not enemy_cards.is_empty()
		and _all_cards_match_filter(enemy_cards, enemy_filter_key),
		"Enemy family filtering must only retain cards from that family."
	)
	var enemy_selected_card := (
		enemy_cards[1] as EncyclopediaEntryCard
		if enemy_cards.size() > 1
		else enemy_cards[0] as EncyclopediaEntryCard
	)
	enemy_selected_card.get_focus_control().grab_focus()
	await _wait_frames(2)
	screen.call("_save_current_section_state")
	var all_states: Dictionary = screen.get("_section_states")
	var enemy_state: Dictionary = (
		all_states[CodexSection.ENEMY] as Dictionary
	).duplicate(true)
	_expect(
		String(enemy_state["query"]) == "原石虫"
		and StringName(enemy_state["filter"]) == enemy_filter_key
		and StringName(enemy_state["selected_id"])
		== enemy_selected_card.entry_data.entry_id,
		"Enemy section must record its query, filter and selected card."
	)

	await _switch_section(screen, screen.collectible_button)
	_expect(
		int(screen.get("_current_section")) == CodexSection.COLLECTIBLE,
		"Section navigation must switch from enemies to collectibles."
	)
	var collectible_filter_key := &"rare"
	_expect(
		_select_filter(screen, collectible_filter_key),
		"Collectible toolbar must expose the rare filter."
	)
	await _wait_frames(3)
	await _wait_for_grid_build(screen)
	var collectible_query := "指"
	_set_search_query(screen, collectible_query)
	await _wait_frames(3)
	await _wait_for_grid_build(screen)
	var collectible_cards: Array = screen.get("_cards")
	_expect(
		not collectible_cards.is_empty()
		and collectible_cards.size() < 43
		and _all_cards_match_filter(
			collectible_cards,
			collectible_filter_key
		),
		"Collectible search/filter state must remain independent of enemies."
	)
	for card_variant in collectible_cards:
		var collectible_card := card_variant as EncyclopediaEntryCard
		_expect(
			collectible_card != null
			and collectible_card.entry_data.display_name.contains(
				collectible_query
			),
			"Collectible name search must only retain matching rare cards."
		)
	var collectible_selected_card := (
		collectible_cards[collectible_cards.size() - 1]
		as EncyclopediaEntryCard
	)
	collectible_selected_card.get_focus_control().grab_focus()
	await _wait_frames(2)
	# A small explicit scroll fixture lets this state-persistence contract use a
	# meaningful name query even when its few matches fit in one natural row.
	screen.entry_grid.custom_minimum_size.y = screen.grid_scroll.size.y + 160.0
	await _wait_frames(3)
	var scroll_bar := screen.grid_scroll.get_v_scroll_bar()
	var max_scroll := maxi(
		roundi(scroll_bar.max_value - scroll_bar.page),
		0
	)
	_expect(max_scroll > 0, "Filtered collectibles must provide scrollable content.")
	if max_scroll > 0:
		screen.grid_scroll.scroll_vertical = mini(72, max_scroll)
	await process_frame
	_expect(
		screen.grid_scroll.scroll_vertical > 0,
		"Collectible section fixture must establish a non-zero scroll position."
	)
	screen.call("_save_current_section_state")
	all_states = screen.get("_section_states")
	var collectible_state: Dictionary = (
		all_states[CodexSection.COLLECTIBLE] as Dictionary
	).duplicate(true)
	_expect(
		String(collectible_state["query"]) == collectible_query
		and StringName(collectible_state["filter"])
		== collectible_filter_key
		and int(collectible_state["scroll"]) > 0
		and StringName(collectible_state["selected_id"])
		== collectible_selected_card.entry_data.entry_id,
		"Collectible section must record independent query/filter/scroll/selection."
	)

	await _switch_section(screen, screen.enemy_button)
	all_states = screen.get("_section_states")
	var restored_enemy_state: Dictionary = all_states[CodexSection.ENEMY]
	_expect(
		String(screen.search_edit.text) == String(enemy_state["query"])
		and _get_selected_filter_key(screen)
		== StringName(enemy_state["filter"])
		and screen.grid_scroll.scroll_vertical == int(enemy_state["scroll"]),
		"Returning to enemies must restore its query, filter and scroll."
	)
	_expect(
		StringName(restored_enemy_state["selected_id"])
		== StringName(enemy_state["selected_id"])
		and _cards_contain_entry_id(
			screen.get("_cards"),
			StringName(enemy_state["selected_id"])
		),
		"Returning to enemies must retain its selected entry."
	)

	await _switch_section(screen, screen.collectible_button)
	all_states = screen.get("_section_states")
	var restored_collectible_state: Dictionary = (
		all_states[CodexSection.COLLECTIBLE]
	)
	_expect(
		screen.search_edit.text == String(collectible_state["query"])
		and _get_selected_filter_key(screen)
		== StringName(collectible_state["filter"])
		and screen.grid_scroll.scroll_vertical
		== int(collectible_state["scroll"]),
		(
			"Returning to collectibles must restore query/filter/scroll; "
			+ "got query=%s filter=%s scroll=%d, expected query=%s filter=%s scroll=%d."
		)
		% [
			screen.search_edit.text,
			_get_selected_filter_key(screen),
			screen.grid_scroll.scroll_vertical,
			String(collectible_state["query"]),
			StringName(collectible_state["filter"]),
			int(collectible_state["scroll"]),
		]
	)
	_expect(
		StringName(restored_collectible_state["selected_id"])
		== StringName(collectible_state["selected_id"])
		and _cards_contain_entry_id(
			screen.get("_cards"),
			StringName(collectible_state["selected_id"])
		),
		"Returning to collectibles must retain its selected entry."
	)
	screen.entry_grid.custom_minimum_size = Vector2.ZERO


func _set_search_query(screen: EncyclopediaScreen, query: String) -> void:
	screen.search_edit.text = query
	screen.search_edit.text_changed.emit(query)


func _find_filter_index(
	screen: EncyclopediaScreen,
	filter_key: StringName
) -> int:
	for index in screen.filter_button.item_count:
		if StringName(screen.filter_button.get_item_metadata(index)) == filter_key:
			return index
	return -1


func _select_filter(screen: EncyclopediaScreen, filter_key: StringName) -> bool:
	var index := _find_filter_index(screen, filter_key)
	if index < 0:
		return false
	screen.filter_button.select(index)
	screen.filter_button.item_selected.emit(index)
	return true


func _get_selected_filter_key(screen: EncyclopediaScreen) -> StringName:
	if screen.filter_button.selected < 0:
		return &""
	return StringName(
		screen.filter_button.get_item_metadata(screen.filter_button.selected)
	)


func _all_cards_match_filter(cards: Array, filter_key: StringName) -> bool:
	for card_variant in cards:
		var card := card_variant as EncyclopediaEntryCard
		if card == null or card.entry_data.filter_key != filter_key:
			return false
	return true


func _cards_contain_entry_id(cards: Array, entry_id: StringName) -> bool:
	for card_variant in cards:
		var card := card_variant as EncyclopediaEntryCard
		if card != null and card.entry_data.entry_id == entry_id:
			return true
	return false


func _switch_section(screen: EncyclopediaScreen, button: Button) -> void:
	button.pressed.emit()
	await create_timer(
		EncyclopediaScreen.SECTION_TRANSITION_DURATION + 0.06
	).timeout
	await _wait_frames(3)
	await _wait_for_grid_build(screen)


func _wait_for_grid_build(screen: EncyclopediaScreen) -> void:
	for _frame in 180:
		if screen.is_grid_build_complete():
			return
		await process_frame
	_expect(false, "Encyclopedia grid build did not finish within 180 frames.")


func _find_entry(
	entries: Array[CodexEntryViewData],
	entry_id: StringName
) -> CodexEntryViewData:
	for entry in entries:
		if entry.entry_id == entry_id:
			return entry
	return null


func _stats_to_dictionary(rows: Array[CodexStatRow]) -> Dictionary:
	var result: Dictionary = {}
	for row in rows:
		result[row.label] = row.value
	return result


func _first_stat_labels(rows: Array[CodexStatRow], count: int) -> Array[String]:
	var labels: Array[String] = []
	for index in mini(count, rows.size()):
		labels.append(rows[index].label)
	return labels


func _format_number(value: float) -> String:
	if is_equal_approx(value, roundf(value)):
		return str(int(roundf(value)))
	return "%.2f" % value


func _wait_frames(frame_count: int) -> void:
	for _frame in frame_count:
		await process_frame


func _cleanup_root() -> void:
	current_scene = null
	for child in root.get_children():
		if child.name in [
			&"UserSettings",
			&"RunState",
			&"NetManager",
			&"UIAudio",
			&"GameLoadCoordinator",
			&"StatusEffectExpiryScheduler",
			&"BurnStatusScheduler",
			&"BleedStatusScheduler",
			&"ColdStatusScheduler",
			&"EnemyCollectibleStatusScheduler",
		]:
			continue
		child.queue_free()
	await _wait_frames(3)


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
