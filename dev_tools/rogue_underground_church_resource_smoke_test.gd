extends SceneTree

const UNDERGROUND_CHURCH: RogueCombatEncounterConfig = preload(
	"res://resources/config/rogue_combat/underground_church_01.tres"
)
const NARROW_ROAD: RogueCombatEncounterConfig = preload(
	"res://resources/config/rogue_combat/encounter_01.tres"
)
const ABANDONED_MINE: RogueCombatEncounterConfig = preload(
	"res://resources/config/rogue_combat/abandoned_mine_01.tres"
)
const UNDERGROUND_SEWER: RogueCombatEncounterConfig = preload(
	"res://resources/config/rogue_combat/underground_sewer_01.tres"
)
const SUITCASE_BATTLE: RogueCombatEncounterConfig = preload(
	"res://resources/config/rogue_combat/suitcase_battle.tres"
)
const NORMAL_POOL: RogueCombatPoolConfig = preload(
	"res://resources/config/rogue_combat/shallow_mine_normal_combat_pool.tres"
)
const NORMAL_REWARD: RogueCombatRewardConfig = preload(
	"res://resources/config/rogue_combat/reward_encounter_01.tres"
)
const CARDBOARD_MONSTER: EnemyConfig = preload(
	"res://resources/config/enemies/cardboard_monster.tres"
)
const COMBAT_ROBOT_GUNNER: EnemyConfig = preload(
	"res://resources/config/enemies/combat_robot_gunner.tres"
)
const SLIME: EnemyConfig = preload(
	"res://resources/config/enemies/slime.tres"
)

var _failures := PackedStringArray()


func _init() -> void:
	call_deferred(&"_run")


func _run() -> void:
	_test_underground_church_config()
	_test_briefing_visuals()
	_test_normal_combat_pool()
	if _failures.is_empty():
		print("ROGUE_UNDERGROUND_CHURCH_RESOURCE_SMOKE_TEST_OK")
		quit(0)
		return
	for failure in _failures:
		push_error(failure)
	quit(1)


func _test_underground_church_config() -> void:
	_expect(
		UNDERGROUND_CHURCH.validate_config().is_empty(),
		"地下教会正式配置必须完整有效：%s"
		% [UNDERGROUND_CHURCH.validate_config()]
	)
	_expect(
		UNDERGROUND_CHURCH.encounter_id == &"underground_church_01"
		and UNDERGROUND_CHURCH.event_title == "地下教会"
		and UNDERGROUND_CHURCH.combat_scene_path
			== "res://scene/game_modes/rogue/combat/rogue_combat_game_02.tscn"
		and UNDERGROUND_CHURCH.preparation_seconds == 3
		and UNDERGROUND_CHURCH.combat_limit_seconds == 90,
		"地下教会必须绑定稳定ID、game02、3秒准备与90秒时限。"
	)
	_expect(
		UNDERGROUND_CHURCH.reward_config == NORMAL_REWARD
		and UNDERGROUND_CHURCH.extra_xirang == 500
		and UNDERGROUND_CHURCH.keep_enemy_kill_xirang
			== RogueCombatEncounterConfig.Decision.YES
		and UNDERGROUND_CHURCH.enemy_pickup_drops
			== RogueCombatEncounterConfig.Decision.NO,
		"地下教会必须复用普通作战的500息壤、1件普通收藏品和击杀奖励策略。"
	)

	var waves := UNDERGROUND_CHURCH.campaign.get_waves()
	_expect(waves.size() == 1, "地下教会Campaign必须只有一个终点波次。")
	if waves.size() != 1:
		return
	var wave := waves[0]
	_expect(
		wave.get_total_enemy_count() == 70
		and is_equal_approx(wave.spawn_interval, 0.2)
		and wave.spawn_count_per_tick == 1
		and wave.max_alive_enemies == 15
		and wave.spawn_point_mask
			== RogueCombatEncounterConfig.REQUIRED_SCENE_SPAWN_POINT_MASK
		and wave.spawn_point_order
			== WaveConfig.SpawnPointOrder.BALANCED_SHUFFLE_BAG
		and wave.spawn_order == WaveConfig.SpawnOrder.SHUFFLED,
		"地下教会必须保持70名敌人、0.2秒批1、cap15与三门均衡乱序。"
	)
	_expect(
		_count_enemy(wave, CARDBOARD_MONSTER) == 10
		and _count_enemy(wave, COMBAT_ROBOT_GUNNER) == 20
		and _count_enemy(wave, SLIME) == 40,
		"地下教会敌人组成必须严格为10纸箱怪、20持枪机器人、40史莱姆。"
	)
	_expect(
		_compute_enemy_kill_xirang(wave) == 270,
		"地下教会全清必须保留270点敌人击杀息壤。"
	)


func _test_briefing_visuals() -> void:
	_expect(
		NARROW_ROAD.briefing_visual != null
		and SUITCASE_BATTLE.briefing_visual != null,
		"狭路相逢与皮箱之战必须显式绑定既有作战简报图。"
	)
	var church_visual := UNDERGROUND_CHURCH.briefing_visual as AtlasTexture
	_expect(church_visual != null, "地下教会简报必须使用背景图AtlasTexture裁片。")
	if church_visual == null:
		return
	_expect(
		church_visual.region == Rect2(0, 24, 320, 72)
		and church_visual.atlas != null
		and church_visual.atlas.resource_path
			== (
				"res://resources/texture/rogue_combat/underground_church/"
				+ "underground_church_background.png"
			),
		"地下教会简报必须精确裁取背景图Rect2(0,24,320,72)。"
	)


func _test_normal_combat_pool() -> void:
	_expect(
		NORMAL_POOL.validate_config().is_empty(),
		"浅层矿洞普通作战池必须完整有效：%s" % [NORMAL_POOL.validate_config()]
	)
	_expect(
		NORMAL_POOL.pool_id == &"normal_combat"
		and NORMAL_POOL.entries.size() == 4
		and NORMAL_POOL.get_combat_config(&"narrow_road_01") == NARROW_ROAD
		and NORMAL_POOL.get_combat_config(&"underground_church_01")
		== UNDERGROUND_CHURCH
		and NORMAL_POOL.get_combat_config(&"abandoned_mine_01")
		== ABANDONED_MINE
		and NORMAL_POOL.get_combat_config(&"underground_sewer_01")
		== UNDERGROUND_SEWER,
		"普通作战池必须只收录狭路相逢、地下教会、废弃矿场和地下水道。"
	)
	var weights := {}
	var total_weight := 0
	for entry in NORMAL_POOL.entries:
		if entry == null or entry.combat_config == null:
			continue
		weights[entry.combat_config.encounter_id] = entry.selection_weight
		total_weight += entry.selection_weight
	_expect(
		total_weight == 4
		and int(weights.get(&"narrow_road_01", 0)) == 1
		and int(weights.get(&"underground_church_01", 0)) == 1
		and int(weights.get(&"abandoned_mine_01", 0)) == 1
		and int(weights.get(&"underground_sewer_01", 0)) == 1,
		"四种普通作战的选择权重必须精确为1、1、1、1。"
	)
	var pool_hash := NORMAL_POOL.compute_runtime_contract_hash()
	_expect(
		pool_hash.length() == 64
		and pool_hash == NORMAL_POOL.compute_runtime_contract_hash(),
		"普通作战池必须生成稳定的SHA-256运行合同。"
	)
	for seed_value in range(-32, 33):
		var first := NORMAL_POOL.select_config(seed_value)
		var repeated := NORMAL_POOL.select_config(seed_value)
		_expect(
			first != null
			and first == repeated
			and first.encounter_id in [
				&"narrow_road_01",
				&"underground_church_01",
				&"abandoned_mine_01",
				&"underground_sewer_01",
			],
			"普通作战池必须对节点种子%d给出稳定且合法的配置。" % seed_value
		)


func _count_enemy(wave: WaveConfig, enemy_config: EnemyConfig) -> int:
	var result := 0
	for entry in wave.enemy_entries:
		if entry != null and entry.enemy_config == enemy_config:
			result += entry.count
	return result


func _compute_enemy_kill_xirang(wave: WaveConfig) -> int:
	var result := 0
	for entry in wave.enemy_entries:
		if entry != null and entry.enemy_config != null:
			result += entry.count * entry.resolve_xirang_kill_reward()
	return result


func _expect(condition: bool, message: String) -> void:
	if not condition:
		_failures.append(message)
