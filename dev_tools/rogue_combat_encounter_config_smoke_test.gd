extends SceneTree

const ENCOUNTER_CONFIG: RogueCombatEncounterConfig = preload(
	"res://resources/config/rogue_combat/encounter_01.tres"
)
const ROGUE_CAMPAIGN: WaveCampaignConfig = preload(
	"res://resources/config/campaigns/rogue_combat/encounter_01/campaign.tres"
)
const ROGUE_COMBAT_MUSIC := preload(
	"res://resources/audio/1-28 Journey of the Prairie King (The Outlaw).mp3"
)
const COMBAT_ROBOT: EnemyConfig = preload(
	"res://resources/config/enemies/combat_robot.tres"
)
const DRONE_OPERATOR: EnemyConfig = preload(
	"res://resources/config/enemies/combat_robot_drone_operator.tres"
)
const GUNNER: EnemyConfig = preload(
	"res://resources/config/enemies/combat_robot_gunner.tres"
)
const STANDARD_SINGLEPLAYER_CAMPAIGN: WaveCampaignConfig = preload(
	"res://resources/config/campaigns/standard/singleplayer/campaign.tres"
)
const STANDARD_MULTIPLAYER_CAMPAIGN: WaveCampaignConfig = preload(
	"res://resources/config/campaigns/standard/multiplayer/campaign.tres"
)

var _failures := PackedStringArray()


class SpawnCapProbe:
	extends WaveCombatRuntimeBase

	var spawn_attempts := 0

	func configure_multiplayer(
		_mode: int,
		_local_peer_id: int,
		_player_names: Dictionary,
		_player_character_ids: Dictionary = {}
	) -> void:
		pass

	func get_player_for_peer(_peer_id: int) -> Player:
		return null

	func get_pickup_for_net_id(_net_id: int) -> Pickup:
		return null

	func remove_multiplayer_player(_peer_id: int) -> void:
		pass

	func collect_player_snapshot_states() -> Array[SnapshotManager.PlayerState]:
		return []

	func _configure_singleplayer_player() -> void:
		pass

	func _configure_multiplayer_players() -> void:
		pass

	func _connect_mode_singleplayer_player_death_signal() -> void:
		pass

	func _update_multiplayer_remote_player_passive_state(_delta: float) -> void:
		pass

	func _connect_mode_dynamic_pickup_containers() -> void:
		pass

	func _register_static_multiplayer_pickups() -> void:
		pass

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
	_test_formal_encounter_resource()
	_test_formal_wave_resource()
	_test_occurrence_campaign_is_isolated()
	_test_kill_reward_policy_applies_to_every_entry()
	_test_runtime_contract_hash()
	_test_wave_alive_cap()
	_test_invalid_authored_content_is_rejected()
	_test_standard_spawn_batches_unchanged()

	if _failures.is_empty():
		print("ROGUE_COMBAT_ENCOUNTER_CONFIG_SMOKE_TEST_OK")
		quit(0)
		return
	for failure in _failures:
		push_error(failure)
	quit(1)


func _test_formal_encounter_resource() -> void:
	_expect(ENCOUNTER_CONFIG.encounter_id == &"narrow_road_01", "狭路相逢 ID 漂移。")
	_expect(ENCOUNTER_CONFIG.event_title == "狭路相逢", "狭路相逢标题漂移。")
	_expect(
		ENCOUNTER_CONFIG.objective_text == "击败全部战斗机器人",
		"狭路相逢必须配置独立目标文本。"
	)
	_expect(
		ENCOUNTER_CONFIG.combat_scene_path
		== "res://scene/game_modes/rogue/combat/rogue_combat_game_01.tscn",
		"狭路相逢必须使用 rogue_combat_game_01。"
	)
	_expect(ENCOUNTER_CONFIG.campaign == ROGUE_CAMPAIGN, "狭路相逢 Campaign 绑定错误。")
	_expect(
		ENCOUNTER_CONFIG.get_total_enemy_count() == 22
		and ENCOUNTER_CONFIG.get_spawn_point_mask() == 7,
		"EncounterConfig 必须从 Wave 派生22名敌人与三扇红门。"
	)
	_expect(
		ENCOUNTER_CONFIG.preparation_seconds == 3
		and ENCOUNTER_CONFIG.combat_limit_seconds == 90
		and ENCOUNTER_CONFIG.extra_xirang == 500,
		"狭路相逢既有倒计时与额外奖励不得漂移。"
	)
	_expect(
		ENCOUNTER_CONFIG.is_ready_to_enable(),
		"正式狭路相逢配置必须通过校验：%s" % [ENCOUNTER_CONFIG.validate_config()]
	)


func _test_formal_wave_resource() -> void:
	_expect(ROGUE_CAMPAIGN.validate_campaign().is_empty(), "狭路相逢 Campaign 必须有效。")
	var waves := ROGUE_CAMPAIGN.get_waves()
	_expect(waves.size() == 1, "狭路相逢必须只有一个终点波次。")
	if waves.size() != 1:
		return
	var wave := waves[0]
	_expect(wave.exits.is_empty(), "狭路相逢唯一波次必须是终点。")
	_expect(
		wave.enemy_entries.size() == 3 and wave.get_total_enemy_count() == 22,
		"狭路相逢必须由三个条目共22名敌人组成。"
	)
	if wave.enemy_entries.size() == 3:
		_expect_entry(wave.enemy_entries[0], COMBAT_ROBOT, 10, "普通战斗机器人")
		_expect_entry(wave.enemy_entries[1], DRONE_OPERATOR, 4, "无人机操作员")
		_expect_entry(wave.enemy_entries[2], GUNNER, 8, "持枪战斗机器人")
	_expect(
		wave.spawn_point_mask == 7
		and wave.spawn_point_order == WaveConfig.SpawnPointOrder.BALANCED_SHUFFLE_BAG,
		"狭路相逢必须从三扇红门进行低方差随机生成。"
	)
	_expect(
		wave.spawn_order == WaveConfig.SpawnOrder.SHUFFLED
		and is_equal_approx(wave.spawn_interval, 0.3)
		and wave.spawn_count_per_tick == 1
		and wave.max_alive_enemies == 10,
		"狭路相逢必须每0.3秒生成1名敌人且场上最多10名。"
	)
	_expect(
		wave.music == ROGUE_COMBAT_MUSIC
		and ROGUE_COMBAT_MUSIC is AudioStreamMP3
		and (ROGUE_COMBAT_MUSIC as AudioStreamMP3).loop,
		"狭路相逢必须保留循环作战音乐。"
	)


func _test_occurrence_campaign_is_isolated() -> void:
	var occurrence := ENCOUNTER_CONFIG.build_occurrence_campaign("combat:test:isolated")
	_expect(occurrence != null, "必须能创建 occurrence-local Campaign。")
	if occurrence == null:
		return
	var source_wave := ROGUE_CAMPAIGN.get_waves()[0]
	var wave := occurrence.get_waves()[0]
	_expect(
		occurrence != ROGUE_CAMPAIGN
		and occurrence.flow_graph != ROGUE_CAMPAIGN.flow_graph
		and wave != source_wave,
		"Occurrence 必须隔离 Campaign、FlowGraph 与 Wave 实例。"
	)
	_expect(
		wave.enemy_entries.size() == source_wave.enemy_entries.size(),
		"Occurrence 必须完整复制全部敌人条目。"
	)
	for entry_index in range(mini(wave.enemy_entries.size(), source_wave.enemy_entries.size())):
		var source_entry := source_wave.enemy_entries[entry_index]
		var entry := wave.enemy_entries[entry_index]
		_expect(
			entry != source_entry
			and entry.enemy_config == source_entry.enemy_config
			and entry.count == source_entry.count,
			"Occurrence 条目%d必须隔离实例并保留正式敌人资源与数量。" % entry_index
		)
	_expect(
		is_equal_approx(wave.spawn_interval, source_wave.spawn_interval)
		and wave.spawn_count_per_tick == source_wave.spawn_count_per_tick
		and wave.max_alive_enemies == 10
		and wave.spawn_point_order == source_wave.spawn_point_order,
		"Occurrence 不得覆盖 Wave 的生成节奏与场上上限。"
	)
	if not wave.enemy_entries.is_empty():
		wave.enemy_entries[0].count = 99
		_expect(
			source_wave.enemy_entries[0].count == 10,
			"修改 occurrence 条目不得污染 authored Wave。"
		)


func _test_kill_reward_policy_applies_to_every_entry() -> void:
	var inherited := ENCOUNTER_CONFIG.build_occurrence_campaign("combat:test:reward:inherit")
	_expect(inherited != null, "保留击杀息壤时必须能创建 occurrence。")
	if inherited != null:
		for entry in inherited.get_waves()[0].enemy_entries:
			_expect(entry.xirang_kill_reward_override == -1, "全部条目都必须继承击杀息壤。")

	var no_kill_reward := ENCOUNTER_CONFIG.duplicate(true) as RogueCombatEncounterConfig
	no_kill_reward.keep_enemy_kill_xirang = RogueCombatEncounterConfig.Decision.NO
	var suppressed := no_kill_reward.build_occurrence_campaign("combat:test:reward:none")
	_expect(suppressed != null, "关闭击杀息壤时必须能创建 occurrence。")
	if suppressed != null:
		for entry in suppressed.get_waves()[0].enemy_entries:
			_expect(entry.xirang_kill_reward_override == 0, "全部条目都必须关闭击杀息壤。")


func _test_runtime_contract_hash() -> void:
	var baseline := ENCOUNTER_CONFIG.compute_runtime_contract_hash()
	_expect(
		RogueCombatEncounterConfig.RUNTIME_CONTRACT_SCHEMA == 4
		and baseline.length() == 64
		and baseline == ENCOUNTER_CONFIG.compute_runtime_contract_hash(),
		"作战 runtime contract 必须使用包含奖励与敌人增幅的schema4稳定SHA-256。"
	)

	var presentation_only := ENCOUNTER_CONFIG.duplicate(false) as RogueCombatEncounterConfig
	var presentation_baseline := presentation_only.compute_runtime_contract_hash()
	presentation_only.event_title = "仅修改表现标题"
	presentation_only.objective_text = "仅修改表现目标"
	_expect(
		presentation_only.compute_runtime_contract_hash() == presentation_baseline,
		"表现标题与目标文本不得改变权威运行契约。"
	)

	var mutations: Array[Callable] = [
		func(config: RogueCombatEncounterConfig) -> void:
			config.campaign.get_waves()[0].enemy_entries[0].enemy_config = DRONE_OPERATOR,
		func(config: RogueCombatEncounterConfig) -> void:
			config.campaign.get_waves()[0].enemy_entries[0].count += 1,
		func(config: RogueCombatEncounterConfig) -> void:
			config.campaign.get_waves()[0].spawn_interval = 0.4,
		func(config: RogueCombatEncounterConfig) -> void:
			config.campaign.get_waves()[0].max_alive_enemies = 9,
		func(config: RogueCombatEncounterConfig) -> void:
			config.campaign.get_waves()[0].spawn_point_order = (
				WaveConfig.SpawnPointOrder.UNIFORM_RANDOM
			),
		func(config: RogueCombatEncounterConfig) -> void:
			config.reward_config = config.reward_config.duplicate(true)
			config.reward_config.xirang_maximum += 100,
	]
	for mutation_index in range(mutations.size()):
		var changed := _make_isolated_config("hash:%d" % mutation_index)
		var isolated_baseline := changed.compute_runtime_contract_hash()
		mutations[mutation_index].call(changed)
		_expect(
			changed.compute_runtime_contract_hash() != isolated_baseline,
			"敌人、生成规则或奖励变更%d必须改变作战运行契约。" % mutation_index
		)


func _test_wave_alive_cap() -> void:
	var wave := ROGUE_CAMPAIGN.get_waves()[0]
	var probe := SpawnCapProbe.new()
	probe.wave_state = CombatFlowState.State.WAVE_ACTIVE
	probe.current_flow_step = wave
	probe.enemy_spawn_timer = Timer.new()
	probe.call("_build_wave_spawn_queue", wave)
	probe.reset_wave_progress(probe.pending_enemy_configs.size())
	for _tick in range(15):
		probe.call("_spawn_wave_batch")
	_expect(
		probe.spawn_attempts == 10
		and probe.current_wave_spawned == 10
		and probe.active_wave_enemy_ids.size() == 10
		and probe.pending_enemy_config_index == 10,
		"场上达到10名敌人后必须暂停生成并保留剩余12名队列：attempts=%d spawned=%d active=%d cursor=%d queue=%d"
		% [
			probe.spawn_attempts,
			probe.current_wave_spawned,
			probe.active_wave_enemy_ids.size(),
			probe.pending_enemy_config_index,
			probe.pending_enemy_configs.size(),
		]
	)
	probe.remove_active_wave_enemy(1)
	probe.call("_spawn_wave_batch")
	_expect(
		probe.spawn_attempts == 11
		and probe.current_wave_spawned == 11
		and probe.active_wave_enemy_ids.size() == 10,
		"一名敌人离场后，下个生成 tick 必须补回到场上10名：attempts=%d spawned=%d active=%d"
		% [
			probe.spawn_attempts,
			probe.current_wave_spawned,
			probe.active_wave_enemy_ids.size(),
		]
	)
	probe.enemy_spawn_timer.free()
	probe.free()


func _test_invalid_authored_content_is_rejected() -> void:
	var missing_objective := ENCOUNTER_CONFIG.duplicate(true) as RogueCombatEncounterConfig
	missing_objective.objective_text = ""
	_expect(
		_has_error_containing(missing_objective.validate_config(), "目标文本"),
		"作战配置必须拒绝空目标文本。"
	)
	var drifting_reward_summary := (
		ENCOUNTER_CONFIG.duplicate(true) as RogueCombatEncounterConfig
	)
	drifting_reward_summary.extra_xirang = 400
	_expect(
		_has_error_containing(
			drifting_reward_summary.validate_config(),
			"旧息壤摘要"
		),
		"旧extra_xirang摘要不得与正式奖励资源下限漂移。"
	)

	var invalid_cap := _make_isolated_config("invalid:cap")
	var wave := invalid_cap.campaign.get_waves()[0]
	wave.spawn_count_per_tick = 2
	wave.max_alive_enemies = 1
	_expect(
		_has_error_containing(invalid_cap.validate_config(), "不能超过场上敌人上限"),
		"单次生成量超过场上上限时必须校验失败。"
	)


func _test_standard_spawn_batches_unchanged() -> void:
	var expected: Array[int] = [1, 1, 1, 2, 2, 2, 2, 2, 2, 2, 2, 2]
	_expect(
		_get_spawn_batch_values(STANDARD_SINGLEPLAYER_CAMPAIGN) == expected
		and _get_spawn_batch_values(STANDARD_MULTIPLAYER_CAMPAIGN) == expected,
		"狭路相逢资源化不得改变标准模式12波的刷怪批量。"
	)


func _expect_entry(
	entry: WaveEnemyEntry,
	expected_config: EnemyConfig,
	expected_count: int,
	label: String
) -> void:
	_expect(
		entry != null
		and entry.enemy_config == expected_config
		and entry.count == expected_count
		and entry.xirang_kill_reward_override == -1,
		"%s条目配置或数量错误。" % label
	)


func _make_isolated_config(suffix: String) -> RogueCombatEncounterConfig:
	var result := ENCOUNTER_CONFIG.duplicate(false) as RogueCombatEncounterConfig
	result.campaign = ENCOUNTER_CONFIG.build_occurrence_campaign(
		"combat:test:isolated:%s" % suffix
	)
	return result


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
