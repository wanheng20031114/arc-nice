extends SceneTree

const ABANDONED_MINE: RogueCombatEncounterConfig = preload(
	"res://resources/config/rogue_combat/abandoned_mine_01.tres"
)
const NORMAL_REWARD: RogueCombatRewardConfig = preload(
	"res://resources/config/rogue_combat/reward_encounter_01.tres"
)
const CAPOO_MAGE: EnemyConfig = preload(
	"res://resources/config/enemies/capoo_mage.tres"
)
const FROST_SORCERER: EnemyConfig = preload(
	"res://resources/config/enemies/frost_sorcerer.tres"
)
const COMBAT_ROBOT: EnemyConfig = preload(
	"res://resources/config/enemies/combat_robot.tres"
)
const BACKGROUND_PATH := (
	"res://resources/texture/rogue_combat/abandoned_mine/"
	+ "abandoned_mine_background.png"
)

var _failures := PackedStringArray()


func _init() -> void:
	call_deferred(&"_run")


func _run() -> void:
	_test_encounter_config()
	_test_briefing_visual()
	_test_campaign_content()
	if _failures.is_empty():
		print("ROGUE_ABANDONED_MINE_RESOURCE_SMOKE_TEST_OK")
		quit(0)
		return
	for failure in _failures:
		push_error(failure)
	quit(1)


func _test_encounter_config() -> void:
	_expect(
		ABANDONED_MINE.validate_config().is_empty(),
		"废弃矿场正式配置必须完整有效：%s"
		% [ABANDONED_MINE.validate_config()]
	)
	_expect(
		ABANDONED_MINE.encounter_id == &"abandoned_mine_01"
		and ABANDONED_MINE.event_title == "废弃矿场"
		and ABANDONED_MINE.combat_scene_path
			== "res://scene/game_modes/rogue/combat/rogue_combat_game_03.tscn"
		and ABANDONED_MINE.preparation_seconds == 3
		and ABANDONED_MINE.combat_limit_seconds == 90,
		"废弃矿场必须绑定稳定ID、game03、3秒准备与90秒时限。"
	)
	_expect(
		ABANDONED_MINE.reward_config == NORMAL_REWARD
		and ABANDONED_MINE.extra_xirang == 500
		and ABANDONED_MINE.decisions_confirmed
		and ABANDONED_MINE.deadline_start
			== RogueCombatEncounterConfig.DeadlineStart.WAVE_START
		and ABANDONED_MINE.keep_enemy_kill_xirang
			== RogueCombatEncounterConfig.Decision.YES
		and ABANDONED_MINE.filter_loot_by_character
			== RogueCombatEncounterConfig.Decision.YES
		and ABANDONED_MINE.reward_dead_players_on_victory
			== RogueCombatEncounterConfig.Decision.YES
		and ABANDONED_MINE.return_to_route_before_result
			== RogueCombatEncounterConfig.Decision.YES
		and ABANDONED_MINE.show_failure_result
			== RogueCombatEncounterConfig.Decision.YES
		and ABANDONED_MINE.consume_node_on_failure
			== RogueCombatEncounterConfig.Decision.YES
		and ABANDONED_MINE.enemy_pickup_drops
			== RogueCombatEncounterConfig.Decision.NO
		and ABANDONED_MINE.inherit_route_xirang
			== RogueCombatEncounterConfig.Decision.YES
		and ABANDONED_MINE.support_singleplayer
			== RogueCombatEncounterConfig.Decision.YES
		and ABANDONED_MINE.support_multiplayer
			== RogueCombatEncounterConfig.Decision.YES,
		"废弃矿场必须显式复用普通作战的500息壤、1件收藏品及完整结算策略。"
	)


func _test_briefing_visual() -> void:
	var visual := ABANDONED_MINE.briefing_visual as AtlasTexture
	_expect(visual != null, "废弃矿场简报必须使用背景图 AtlasTexture 裁片。")
	if visual == null:
		return
	_expect(
		visual.region == Rect2(0, 24, 320, 72)
		and visual.atlas != null
		and visual.atlas.resource_path == BACKGROUND_PATH,
		"废弃矿场简报必须精确裁取正式背景图 Rect2(0,24,320,72)。"
	)


func _test_campaign_content() -> void:
	var campaign := ABANDONED_MINE.campaign
	_expect(campaign != null, "废弃矿场必须绑定独立 Campaign。")
	if campaign == null:
		return
	_expect(
		campaign.validate_campaign().is_empty(),
		"废弃矿场 Campaign 必须完整有效：%s"
		% [campaign.validate_campaign()]
	)
	_expect(
		campaign.campaign_id == &"rogue_combat_abandoned_mine_01"
		and campaign.flow_graph != null
		and campaign.flow_graph.graph_name == "Rouge 普通作战：废弃矿场",
		"废弃矿场 Campaign 与 FlowGraph 必须使用专属稳定命名。"
	)
	var waves := campaign.get_waves()
	_expect(waves.size() == 1, "废弃矿场 Campaign 必须只有一个终点波次。")
	if waves.size() != 1:
		return
	var wave := waves[0]
	_expect(
		campaign.flow_graph.start_step == wave
		and campaign.flow_graph.steps.size() == 1
		and wave.step_id == &"abandoned_mine_wave"
		and wave.wave_name == "废弃矿场"
		and wave.exits.is_empty(),
		"废弃矿场 Flow 必须从命名明确的唯一终点波次开始。"
	)
	_expect(
		wave.get_total_enemy_count() == 45
		and _count_enemy(wave, CAPOO_MAGE) == 5
		and _count_enemy(wave, FROST_SORCERER) == 15
		and _count_enemy(wave, COMBAT_ROBOT) == 25,
		"废弃矿场必须严格配置5个法术猫猫虫、15个寒冰术士和25个普通战斗机器人。"
	)
	_expect(
		is_equal_approx(wave.spawn_interval, 0.2)
		and wave.spawn_count_per_tick == 1
		and wave.max_alive_enemies == 15
		and wave.spawn_point_mask
			== RogueCombatEncounterConfig.REQUIRED_SCENE_SPAWN_POINT_MASK
		and wave.spawn_point_order
			== WaveConfig.SpawnPointOrder.BALANCED_SHUFFLE_BAG
		and wave.spawn_order == WaveConfig.SpawnOrder.SHUFFLED,
		"废弃矿场必须保持0.2秒批1、cap15、三点均衡和敌人乱序。"
	)
	_expect(
		_compute_enemy_kill_xirang(wave) == 925,
		"废弃矿场全清必须保留925点敌人击杀息壤。"
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
