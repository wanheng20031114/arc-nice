extends SceneTree

const ENCOUNTER_CONFIG := preload(
	"res://resources/config/rogue_combat/encounter_01.tres"
)
const ENCOUNTER_CONFIG_SCRIPT := preload(
	"res://resources/config/rogue_combat/rogue_combat_encounter_config.gd"
)
const ROGUE_CAMPAIGN := preload(
	"res://resources/config/campaigns/rogue_combat/encounter_01/campaign.tres"
)
const ROGUE_COMBAT_MUSIC := preload(
	"res://resources/audio/1-28 Journey of the Prairie King (The Outlaw).mp3"
)
const COMBAT_ROBOT := preload(
	"res://resources/config/enemies/combat_robot.tres"
)
const STANDARD_SINGLEPLAYER_CAMPAIGN := preload(
	"res://resources/config/campaigns/standard/singleplayer/campaign.tres"
)
const STANDARD_MULTIPLAYER_CAMPAIGN := preload(
	"res://resources/config/campaigns/standard/multiplayer/campaign.tres"
)

var _failures := PackedStringArray()


class SpawnBatchProbe:
	extends WaveCombatRuntimeBase

	var spawn_attempts := 0

	func _try_spawn_enemy(
		_enemy_config: EnemyConfig,
		_xirang_kill_reward_override: int = -1
	) -> bool:
		spawn_attempts += 1
		active_wave_enemy_ids[spawn_attempts] = true
		return true

	func _check_wave_completion() -> void:
		pass


func _init() -> void:
	call_deferred(&"_run")


func _run() -> void:
	_test_confirmed_fixed_contract()
	_test_unconfirmed_config_is_rejected()
	_test_all_explicit_decisions_enable_a_copy()
	_test_fixed_contract_rejects_drift()
	_test_spawn_policy_matches_authored_scene()
	_test_single_wave_campaign()
	_test_ten_enemy_spawn_batch()
	_test_standard_spawn_batch_values_unchanged()

	if _failures.is_empty():
		print("ROGUE_COMBAT_ENCOUNTER_CONFIG_SMOKE_TEST_OK")
		quit(0)
		return
	for failure in _failures:
		push_error(failure)
	quit(1)


func _test_confirmed_fixed_contract() -> void:
	_expect(
		ENCOUNTER_CONFIG.encounter_id == &"narrow_road_01",
		"战斗事件 ID 必须固定为 narrow_road_01。"
	)
	_expect(ENCOUNTER_CONFIG.event_title == "狭路相逢", "战斗事件标题必须为狭路相逢。")
	_expect(
		ENCOUNTER_CONFIG.combat_scene_path
		== "res://scene/game_modes/rogue/combat/rogue_combat_game_01.tscn",
		"战斗事件必须指向独立 Rouge 战斗场景。"
	)
	_expect(ENCOUNTER_CONFIG.campaign == ROGUE_CAMPAIGN, "战斗事件必须绑定独立 Campaign。")
	_expect(ENCOUNTER_CONFIG.preparation_seconds == 3, "准备倒计时必须固定为 3 秒。")
	_expect(ENCOUNTER_CONFIG.combat_limit_seconds == 90, "作战时限必须固定为 90 秒。")
	_expect(ENCOUNTER_CONFIG.enemy_count == 10, "战斗事件必须固定生成 10 个敌人。")
	_expect(ENCOUNTER_CONFIG.extra_xirang == 500, "通关额外息壤必须固定为 500。")
	_expect(
		ENCOUNTER_CONFIG.is_ready_to_enable(),
		"玩家确认后的正式狭路相逢配置必须允许启用。"
	)
	_expect(
		ENCOUNTER_CONFIG.deadline_start
		== ENCOUNTER_CONFIG_SCRIPT.DeadlineStart.WAVE_START
		and ENCOUNTER_CONFIG.spawn_point_mask
		== ENCOUNTER_CONFIG_SCRIPT.REQUIRED_SCENE_SPAWN_POINT_MASK
		and ENCOUNTER_CONFIG.spawn_count_per_tick == 10,
		"正式配置必须在三秒后开始90秒计时，并从三门同批生成10台机器人。"
	)
	_expect(
		ENCOUNTER_CONFIG.keep_enemy_kill_xirang
		== ENCOUNTER_CONFIG_SCRIPT.Decision.YES
		and ENCOUNTER_CONFIG.filter_loot_by_character
		== ENCOUNTER_CONFIG_SCRIPT.Decision.YES
		and ENCOUNTER_CONFIG.reward_dead_players_on_victory
		== ENCOUNTER_CONFIG_SCRIPT.Decision.YES
		and ENCOUNTER_CONFIG.return_to_route_before_result
		== ENCOUNTER_CONFIG_SCRIPT.Decision.YES
		and ENCOUNTER_CONFIG.show_failure_result
		== ENCOUNTER_CONFIG_SCRIPT.Decision.YES
		and ENCOUNTER_CONFIG.consume_node_on_failure
		== ENCOUNTER_CONFIG_SCRIPT.Decision.YES
		and ENCOUNTER_CONFIG.enemy_pickup_drops
		== ENCOUNTER_CONFIG_SCRIPT.Decision.NO
		and ENCOUNTER_CONFIG.inherit_route_xirang
		== ENCOUNTER_CONFIG_SCRIPT.Decision.YES
		and ENCOUNTER_CONFIG.support_singleplayer
		== ENCOUNTER_CONFIG_SCRIPT.Decision.YES
		and ENCOUNTER_CONFIG.support_multiplayer
		== ENCOUNTER_CONFIG_SCRIPT.Decision.YES,
		"正式配置必须完整保存玩家确认的奖励、返回、内容与模式口径。"
	)


func _test_unconfirmed_config_is_rejected() -> void:
	var unconfirmed := ENCOUNTER_CONFIG.duplicate(true) as RogueCombatEncounterConfig
	unconfirmed.decisions_confirmed = false
	unconfirmed.deadline_start = ENCOUNTER_CONFIG_SCRIPT.DeadlineStart.UNSPECIFIED
	unconfirmed.spawn_point_mask = 0
	unconfirmed.spawn_count_per_tick = 0
	unconfirmed.inherit_route_xirang = ENCOUNTER_CONFIG_SCRIPT.Decision.UNSPECIFIED
	var errors := unconfirmed.validate_config()
	_expect(not errors.is_empty(), "存在未确认决策的配置副本必须校验失败。")
	_expect(
		not unconfirmed.is_ready_to_enable(),
		"存在未确认决策的配置副本绝不能启用。"
	)
	_expect(
		_has_error_containing(errors, "尚未由玩家确认"),
		"未确认配置必须明确报告玩家尚未确认。"
	)
	_expect(
		_has_error_containing(errors, "时限起点尚未指定")
		and _has_error_containing(errors, "哪些红门尚未指定")
		and _has_error_containing(errors, "单次生成数量尚未指定"),
		"未确认配置必须逐项报告计时与刷怪策略。"
	)
	_expect(
		_has_error_containing(errors, "是否继承 Rouge 路线息壤尚未指定"),
		"继承路线息壤必须是独立且显式的待确认决策。"
	)


func _test_all_explicit_decisions_enable_a_copy() -> void:
	var ready := _make_ready_config()

	var errors: PackedStringArray = ready.call("validate_config")
	_expect(
		errors.is_empty(),
		"填满全部显式决策的配置副本应通过校验：%s" % [errors]
	)
	_expect(bool(ready.call("is_ready_to_enable")), "完整配置副本必须允许启用。")

	ready.inherit_route_xirang = ENCOUNTER_CONFIG_SCRIPT.Decision.UNSPECIFIED
	_expect(
		not bool(ready.call("is_ready_to_enable"))
		and _has_error_containing(ready.call("validate_config"), "继承 Rouge 路线息壤"),
		"仅遗漏 inherit_route_xirang 时也必须重新禁用。"
	)


func _test_fixed_contract_rejects_drift() -> void:
	var mutations := [
		[&"encounter_id", &"wrong_encounter"],
		[&"event_title", "错误标题"],
		[&"combat_scene_path", "res://scene/game_modes/standard/standard_game.tscn"],
		[&"preparation_seconds", 4],
		[&"combat_limit_seconds", 91],
		[&"enemy_count", 11],
		[&"extra_xirang", 501],
	]
	for mutation in mutations:
		var ready := _make_ready_config()
		ready.set(mutation[0], mutation[1])
		_expect(
			not ready.is_ready_to_enable(),
			"固定规则字段 %s 漂移后必须禁止启用。" % String(mutation[0])
		)


func _test_spawn_policy_matches_authored_scene() -> void:
	var ready := _make_ready_config()
	ready.spawn_point_mask = 1
	_expect(
		not ready.is_ready_to_enable(),
		"只启用 Spawn1 必须被拒绝，场景 01 必须完整使用三扇红门。"
	)
	ready = _make_ready_config()
	ready.spawn_point_mask = 8
	_expect(
		not ready.is_ready_to_enable(),
		"引用场景中不存在的 Spawn4 必须被配置校验拒绝。"
	)
	ready = _make_ready_config()
	ready.spawn_count_per_tick = 2
	_expect(
		ready.is_ready_to_enable(),
		"三门掩码固定时，合法的 occurrence 刷怪批量仍应允许调整。"
	)
	ready.spawn_count_per_tick = 11
	_expect(
		not ready.is_ready_to_enable(),
		"单次生成数量不得超过本场固定的 10 个敌人。"
	)


func _make_ready_config() -> RogueCombatEncounterConfig:
	var ready := ENCOUNTER_CONFIG.duplicate(true) as RogueCombatEncounterConfig
	ready.decisions_confirmed = true
	ready.deadline_start = ENCOUNTER_CONFIG_SCRIPT.DeadlineStart.WAVE_START
	ready.spawn_point_mask = (
		ENCOUNTER_CONFIG_SCRIPT.REQUIRED_SCENE_SPAWN_POINT_MASK
	)
	ready.spawn_count_per_tick = 10
	ready.keep_enemy_kill_xirang = ENCOUNTER_CONFIG_SCRIPT.Decision.YES
	ready.filter_loot_by_character = ENCOUNTER_CONFIG_SCRIPT.Decision.YES
	ready.reward_dead_players_on_victory = ENCOUNTER_CONFIG_SCRIPT.Decision.YES
	ready.return_to_route_before_result = ENCOUNTER_CONFIG_SCRIPT.Decision.YES
	ready.show_failure_result = ENCOUNTER_CONFIG_SCRIPT.Decision.YES
	ready.consume_node_on_failure = ENCOUNTER_CONFIG_SCRIPT.Decision.YES
	ready.enemy_pickup_drops = (
		ENCOUNTER_CONFIG_SCRIPT.Decision.NO
	)
	ready.inherit_route_xirang = ENCOUNTER_CONFIG_SCRIPT.Decision.YES
	ready.support_singleplayer = ENCOUNTER_CONFIG_SCRIPT.Decision.YES
	ready.support_multiplayer = ENCOUNTER_CONFIG_SCRIPT.Decision.YES
	return ready


func _test_single_wave_campaign() -> void:
	_expect(
		ROGUE_CAMPAIGN.validate_campaign().is_empty(),
		"Rouge 战斗 Campaign 必须通过流程资源校验。"
	)
	var waves := ROGUE_CAMPAIGN.get_waves()
	_expect(waves.size() == 1, "Rouge 战斗 Campaign 必须只有一个波次。")
	if waves.size() != 1:
		return
	var wave := waves[0]
	_expect(wave.exits.is_empty(), "唯一战斗波次必须是无出口的终点。")
	_expect(wave.enemy_entries.size() == 1, "唯一波次必须只有一个敌人条目。")
	_expect(wave.get_total_enemy_count() == 10, "唯一波次必须精确生成 10 台机器人。")
	_expect(
		wave.spawn_point_mask
		== ENCOUNTER_CONFIG_SCRIPT.REQUIRED_SCENE_SPAWN_POINT_MASK,
		"技术波次必须预置与场景一致的三扇红门掩码 7。"
	)
	_expect(wave.spawn_count_per_tick == 10, "技术波次必须支持单次生成 10 台机器人。")
	_expect(wave.max_alive_enemies == 10, "技术波次必须允许 10 台机器人同时存活。")
	_expect(
		wave.music == ROGUE_COMBAT_MUSIC
		and ROGUE_COMBAT_MUSIC is AudioStreamMP3
		and (ROGUE_COMBAT_MUSIC as AudioStreamMP3).loop,
		"唯一波次必须使用循环导入的 1-28 作为作战音乐来源。"
	)
	var singleplayer_occurrence := ENCOUNTER_CONFIG.build_occurrence_campaign(
		"combat:music:singleplayer"
	)
	var multiplayer_occurrence := ENCOUNTER_CONFIG.build_occurrence_campaign(
		"combat:music:multiplayer"
	)
	_expect(
		singleplayer_occurrence != null
		and multiplayer_occurrence != null
		and singleplayer_occurrence.get_waves()[0].music == ROGUE_COMBAT_MUSIC
		and multiplayer_occurrence.get_waves()[0].music == ROGUE_COMBAT_MUSIC,
		"单人和多人 occurrence Campaign 必须继承同一份 1-28 波次音乐。"
	)
	if wave.enemy_entries.size() == 1:
		var entry := wave.enemy_entries[0]
		_expect(entry.enemy_config == COMBAT_ROBOT, "唯一敌人条目必须是基础作战机器人。")
		_expect(entry.count == 10, "作战机器人条目数量必须精确为 10。")
		_expect(
			entry.xirang_kill_reward_override == -1,
			"技术资源必须暂时继承机器人默认击杀息壤，不冒充最终决策。"
		)


func _test_ten_enemy_spawn_batch() -> void:
	var wave := ROGUE_CAMPAIGN.get_waves()[0]
	var probe := SpawnBatchProbe.new()
	probe.wave_state = CombatFlowState.State.WAVE_ACTIVE
	probe.current_flow_step = wave
	probe.enemy_spawn_timer = Timer.new()
	probe.call("_build_wave_spawn_queue", wave)
	probe.call("_spawn_wave_batch")
	_expect(probe.spawn_attempts == 10, "WaveCombatRuntimeBase 单个刷怪 tick 必须实际尝试生成 10 个敌人。")
	_expect(probe.current_wave_spawned == 10, "WaveCombatRuntimeBase 单个刷怪 tick 必须记录 10 个已生成敌人。")
	_expect(
		probe.pending_enemy_configs.is_empty(),
		"单次批量生成 10 个敌人后不应残留待生成队列。"
	)
	probe.enemy_spawn_timer.free()
	probe.free()


func _test_standard_spawn_batch_values_unchanged() -> void:
	var expected: Array[int] = [1, 1, 1, 2, 2, 2, 2, 2, 2, 2, 2, 2]
	_expect(
		_get_spawn_batch_values(STANDARD_SINGLEPLAYER_CAMPAIGN) == expected,
		"扩展 Rouge 批量能力不得改变标准单人 12 波的刷怪批量值。"
	)
	_expect(
		_get_spawn_batch_values(STANDARD_MULTIPLAYER_CAMPAIGN) == expected,
		"扩展 Rouge 批量能力不得改变标准多人 12 波的刷怪批量值。"
	)


func _get_spawn_batch_values(campaign: WaveCampaignConfig) -> Array[int]:
	var result: Array[int] = []
	for wave in campaign.get_waves():
		result.append(wave.spawn_count_per_tick)
	return result


func _has_error_containing(errors: PackedStringArray, needle: String) -> bool:
	for error in errors:
		if needle in error:
			return true
	return false


func _expect(condition: bool, message: String) -> void:
	if not condition:
		_failures.append(message)
