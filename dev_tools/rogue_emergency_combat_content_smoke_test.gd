extends SceneTree

const EMERGENCY_POOL: RogueCombatPoolConfig = preload(
	"res://resources/config/rogue_combat/shallow_mine_emergency_combat_pool.tres"
)
const EMERGENCY_NARROW_ROAD: RogueCombatEncounterConfig = preload(
	"res://resources/config/rogue_combat/emergency_narrow_road_01.tres"
)
const EMERGENCY_UNDERGROUND_CHURCH: RogueCombatEncounterConfig = preload(
	"res://resources/config/rogue_combat/emergency_underground_church_01.tres"
)
const EMERGENCY_ABANDONED_MINE: RogueCombatEncounterConfig = preload(
	"res://resources/config/rogue_combat/emergency_abandoned_mine_01.tres"
)
const EMERGENCY_UNDERGROUND_SEWER: RogueCombatEncounterConfig = preload(
	"res://resources/config/rogue_combat/emergency_underground_sewer_01.tres"
)
const NORMAL_NARROW_ROAD: RogueCombatEncounterConfig = preload(
	"res://resources/config/rogue_combat/encounter_01.tres"
)
const NORMAL_UNDERGROUND_CHURCH: RogueCombatEncounterConfig = preload(
	"res://resources/config/rogue_combat/underground_church_01.tres"
)
const NORMAL_ABANDONED_MINE: RogueCombatEncounterConfig = preload(
	"res://resources/config/rogue_combat/abandoned_mine_01.tres"
)
const NORMAL_UNDERGROUND_SEWER: RogueCombatEncounterConfig = preload(
	"res://resources/config/rogue_combat/underground_sewer_01.tres"
)
const EMERGENCY_REWARD: RogueCombatRewardConfig = preload(
	"res://resources/config/rogue_combat/reward_emergency_combat.tres"
)

const COMBAT_ROBOT: EnemyConfig = preload(
	"res://resources/config/enemies/combat_robot.tres"
)
const COMBAT_ROBOT_ELITE: EnemyConfig = preload(
	"res://resources/config/enemies/combat_robot_elite.tres"
)
const DRONE_OPERATOR_ELITE: EnemyConfig = preload(
	"res://resources/config/enemies/combat_robot_drone_operator_elite.tres"
)
const GUNNER_ELITE: EnemyConfig = preload(
	"res://resources/config/enemies/combat_robot_gunner_elite.tres"
)
const CARDBOARD_MONSTER: EnemyConfig = preload(
	"res://resources/config/enemies/cardboard_monster.tres"
)
const SLIME: EnemyConfig = preload(
	"res://resources/config/enemies/slime.tres"
)
const CAPOO_MAGE: EnemyConfig = preload(
	"res://resources/config/enemies/capoo_mage.tres"
)
const FROST_SORCERER_ELITE: EnemyConfig = preload(
	"res://resources/config/enemies/frost_sorcerer_elite.tres"
)
const YUANSHI_INSECT_FAST: EnemyConfig = preload(
	"res://resources/config/enemies/yuanshi_insect_fast.tres"
)
const YUANSHI_INSECT_FIRE_RANGED: EnemyConfig = preload(
	"res://resources/config/enemies/yuanshi_insect_fire_ranged.tres"
)
const STONE_GOLEM: EnemyConfig = preload(
	"res://resources/config/enemies/stone_golem.tres"
)

var _failures := PackedStringArray()


func _init() -> void:
	call_deferred(&"_run")


func _run() -> void:
	_test_equal_weight_pool()
	_test_emergency_reward()
	_test_combat_scene_reuse()
	_test_authored_elite_replacements()
	_test_occurrence_count_scaling()
	_test_normal_encounter_is_unchanged()
	_test_count_contract_and_validation()

	if _failures.is_empty():
		print("ROGUE_EMERGENCY_COMBAT_CONTENT_SMOKE_TEST_OK")
		quit(0)
		return
	for failure in _failures:
		push_error(failure)
	quit(1)


func _test_equal_weight_pool() -> void:
	_expect(
		EMERGENCY_POOL.pool_id == &"emergency_combat"
		and EMERGENCY_POOL.entries.size() == 4
		and EMERGENCY_POOL.get_total_selection_weight() == 4
		and EMERGENCY_POOL.validate_config().is_empty(),
		"紧急作战池必须是包含四个有效等权条目的独立池。"
	)
	var seen_ids: Dictionary = {}
	for bucket in range(EMERGENCY_POOL.get_total_selection_weight()):
		var selected := EMERGENCY_POOL.select_config_for_weight_bucket(bucket)
		if selected != null:
			seen_ids[selected.encounter_id] = true
	for entry in EMERGENCY_POOL.entries:
		_expect(entry != null and entry.selection_weight == 1, "紧急作战池条目权重必须为1。")
	_expect(
		seen_ids.size() == 4
		and seen_ids.has(&"emergency_narrow_road_01")
		and seen_ids.has(&"emergency_underground_church_01")
		and seen_ids.has(&"emergency_abandoned_mine_01")
		and seen_ids.has(&"emergency_underground_sewer_01"),
		"四个权重桶必须一一覆盖四种紧急作战。"
	)


func _test_emergency_reward() -> void:
	_expect(
		EMERGENCY_REWARD.validate_config().is_empty()
		and EMERGENCY_REWARD.xirang_minimum == 1000
		and EMERGENCY_REWARD.xirang_maximum == 2000
		and EMERGENCY_REWARD.xirang_step == 100
		and EMERGENCY_REWARD.collectible_count == 0
		and EMERGENCY_REWARD.collectible_choice_round_count == 2
		and EMERGENCY_REWARD.collectible_choice_offer_count == 2
		and EMERGENCY_REWARD.collectible_choice_rarities
		== PackedInt32Array([0, 1, 2])
		and EMERGENCY_REWARD.random_item_reward_count == 3
		and EMERGENCY_REWARD.random_item_reward_pool.size() == 3
		and EMERGENCY_REWARD.shared_light_stone_reward == 1,
		"紧急作战奖励必须为整百息壤、两轮收藏品选择、基础物资×3与光石+1。"
	)
	for config in _get_emergency_configs():
		_expect(
			config.reward_config == EMERGENCY_REWARD
			and config.extra_xirang == 1000
			and config.is_ready_to_enable(),
			"%s 必须绑定有效紧急奖励：%s"
			% [config.event_title, config.validate_config()]
		)
	for config in _get_scaled_emergency_configs():
		_expect(
			config.enemy_count_increase_minimum_percent == 5
			and config.enemy_count_increase_maximum_percent == 10,
			"%s 必须保留既有5%%–10%%敌人增幅。" % config.event_title
		)
	_expect(
		EMERGENCY_UNDERGROUND_SEWER.enemy_count_increase_minimum_percent == 0
		and EMERGENCY_UNDERGROUND_SEWER.enemy_count_increase_maximum_percent == 0,
		"地下水道紧急作战必须严格采用固定20/2/15/10编成，不做敌人数增幅。"
	)


func _test_combat_scene_reuse() -> void:
	_expect(
		EMERGENCY_NARROW_ROAD.combat_scene_path
		== NORMAL_NARROW_ROAD.combat_scene_path
		and EMERGENCY_UNDERGROUND_CHURCH.combat_scene_path
		== NORMAL_UNDERGROUND_CHURCH.combat_scene_path
		and EMERGENCY_ABANDONED_MINE.combat_scene_path
		== NORMAL_ABANDONED_MINE.combat_scene_path
		and EMERGENCY_UNDERGROUND_SEWER.combat_scene_path
		== NORMAL_UNDERGROUND_SEWER.combat_scene_path,
		"四个紧急作战必须分别复用对应普通关卡场景，不更换地图美术。"
	)


func _test_authored_elite_replacements() -> void:
	_expect_wave_entries(
		EMERGENCY_NARROW_ROAD,
		[COMBAT_ROBOT_ELITE, DRONE_OPERATOR_ELITE, GUNNER_ELITE],
		[10, 4, 8],
		"狭路相逢"
	)
	_expect_wave_entries(
		EMERGENCY_UNDERGROUND_CHURCH,
		[CARDBOARD_MONSTER, GUNNER_ELITE, SLIME],
		[10, 20, 40],
		"地下教会"
	)
	_expect_wave_entries(
		EMERGENCY_ABANDONED_MINE,
		[CAPOO_MAGE, FROST_SORCERER_ELITE, COMBAT_ROBOT_ELITE],
		[5, 15, 25],
		"废弃矿场"
	)
	_expect_wave_entries(
		EMERGENCY_UNDERGROUND_SEWER,
		[
			YUANSHI_INSECT_FAST,
			STONE_GOLEM,
			YUANSHI_INSECT_FIRE_RANGED,
			GUNNER_ELITE,
		],
		[20, 2, 15, 10],
		"地下水道"
	)


func _test_occurrence_count_scaling() -> void:
	_test_config_occurrences(EMERGENCY_NARROW_ROAD, 24, 24)
	_test_config_occurrences(EMERGENCY_UNDERGROUND_CHURCH, 74, 77)
	_test_config_occurrences(EMERGENCY_ABANDONED_MINE, 48, 49)
	_test_config_occurrences(EMERGENCY_UNDERGROUND_SEWER, 47, 47)


func _test_config_occurrences(
	config: RogueCombatEncounterConfig,
	minimum_total: int,
	maximum_total: int
) -> void:
	var source_wave := config.campaign.get_waves()[0]
	var source_counts := _get_wave_counts(source_wave)
	for sample_index in range(32):
		var occurrence_key := "emergency:test:%s:%d" % [config.encounter_id, sample_index]
		var first := config.build_occurrence_campaign(occurrence_key)
		var repeated := config.build_occurrence_campaign(occurrence_key)
		_expect(first != null and repeated != null, "%s 必须能构建 occurrence。" % config.event_title)
		if first == null or repeated == null:
			continue
		var first_counts := _get_wave_counts(first.get_waves()[0])
		var repeated_counts := _get_wave_counts(repeated.get_waves()[0])
		var target_total := _sum_counts(first_counts)
		_expect(
			first_counts == repeated_counts,
			"%s 对相同 occurrence key 的敌人数必须确定。" % config.event_title
		)
		_expect(
			target_total >= minimum_total and target_total <= maximum_total,
			"%s 整波总人数%d不在%d–%d范围。"
			% [config.event_title, target_total, minimum_total, maximum_total]
		)
		_expect(
			first_counts == _allocate_largest_remainder(source_counts, target_total),
			"%s 必须按原条目比例使用最大余数法分配新增敌人。" % config.event_title
		)
	_expect(
		_get_wave_counts(source_wave) == source_counts,
		"构建%s occurrence 不得污染 authored Wave。" % config.event_title
	)


func _test_normal_encounter_is_unchanged() -> void:
	_expect(
		NORMAL_NARROW_ROAD.enemy_count_increase_minimum_percent == 0
		and NORMAL_NARROW_ROAD.enemy_count_increase_maximum_percent == 0,
		"普通作战的敌人增幅默认值必须保持为0。"
	)
	var occurrence := NORMAL_NARROW_ROAD.build_occurrence_campaign(
		"emergency:test:normal:unchanged"
	)
	_expect(
		occurrence != null
		and _get_wave_counts(occurrence.get_waves()[0]) == [10, 4, 8],
		"普通狭路相逢 occurrence 必须继续保持10/4/8。"
	)


func _test_count_contract_and_validation() -> void:
	_expect(
		RogueCombatEncounterConfig.RUNTIME_CONTRACT_SCHEMA == 4,
		"敌人数量增幅必须进入schema4运行契约。"
	)
	var changed := NORMAL_NARROW_ROAD.duplicate(false) as RogueCombatEncounterConfig
	changed.enemy_count_increase_minimum_percent = 5
	changed.enemy_count_increase_maximum_percent = 10
	_expect(
		changed.compute_runtime_contract_hash()
		!= NORMAL_NARROW_ROAD.compute_runtime_contract_hash(),
		"修改敌人数量增幅必须改变运行契约。"
	)
	changed.enemy_count_increase_minimum_percent = 11
	changed.enemy_count_increase_maximum_percent = 10
	_expect(
		_has_error_containing(changed.validate_config(), "最大增幅不能小于"),
		"倒置的敌人数量增幅范围必须被拒绝。"
	)


func _expect_wave_entries(
	config: RogueCombatEncounterConfig,
	expected_configs: Array,
	expected_counts: Array,
	label: String
) -> void:
	var waves := config.campaign.get_waves()
	_expect(waves.size() == 1, "%s紧急作战必须只有一个波次。" % label)
	if waves.size() != 1:
		return
	var entries := waves[0].enemy_entries
	_expect(entries.size() == expected_configs.size(), "%s紧急作战敌人条目数错误。" % label)
	for entry_index in range(mini(entries.size(), expected_configs.size())):
		_expect(
			entries[entry_index].enemy_config == expected_configs[entry_index]
			and entries[entry_index].count == expected_counts[entry_index],
			"%s紧急作战第%d个敌人条目未正确替换或数量漂移。"
			% [label, entry_index + 1]
		)


func _allocate_largest_remainder(source_counts: Array[int], target_total: int) -> Array[int]:
	var result := source_counts.duplicate()
	var source_total := _sum_counts(source_counts)
	var increase := target_total - source_total
	var remainders: Array[int] = []
	var allocated := 0
	for entry_index in range(source_counts.size()):
		var numerator := source_counts[entry_index] * increase
		var entry_increase := floori(float(numerator) / float(source_total))
		result[entry_index] += entry_increase
		remainders.append(numerator % source_total)
		allocated += entry_increase
	var awarded: Dictionary = {}
	for _leftover_index in range(increase - allocated):
		var best_index := -1
		var best_remainder := -1
		for entry_index in range(remainders.size()):
			if awarded.has(entry_index):
				continue
			if remainders[entry_index] > best_remainder:
				best_remainder = remainders[entry_index]
				best_index = entry_index
		if best_index >= 0:
			result[best_index] += 1
			awarded[best_index] = true
	return result


func _get_emergency_configs() -> Array[RogueCombatEncounterConfig]:
	return [
		EMERGENCY_NARROW_ROAD,
		EMERGENCY_UNDERGROUND_CHURCH,
		EMERGENCY_ABANDONED_MINE,
		EMERGENCY_UNDERGROUND_SEWER,
	]


func _get_scaled_emergency_configs() -> Array[RogueCombatEncounterConfig]:
	return [
		EMERGENCY_NARROW_ROAD,
		EMERGENCY_UNDERGROUND_CHURCH,
		EMERGENCY_ABANDONED_MINE,
	]


func _get_wave_counts(wave: WaveConfig) -> Array[int]:
	var result: Array[int] = []
	for entry in wave.enemy_entries:
		result.append(entry.count)
	return result


func _sum_counts(counts: Array[int]) -> int:
	var result := 0
	for count in counts:
		result += count
	return result


func _has_error_containing(errors: PackedStringArray, needle: String) -> bool:
	for error in errors:
		if needle in error:
			return true
	return false


func _expect(condition: bool, message: String) -> void:
	if not condition:
		_failures.append(message)
