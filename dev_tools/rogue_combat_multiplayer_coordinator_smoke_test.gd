extends SceneTree

const COORDINATOR := preload(
	"res://scene/rogue_combat/rogue_combat_multiplayer_coordinator.gd"
)
const FORMAL_CONFIG := preload(
	"res://resources/config/rogue_combat/encounter_01.tres"
)

var _failures: PackedStringArray = []


func _init() -> void:
	call_deferred(&"_run")


func _run() -> void:
	_test_confirmed_formal_config_is_enabled()
	_test_occurrence_campaign_is_isolated()
	_test_kill_reward_policy_is_explicit()
	_test_protocol_contract_is_static_and_order_safe()

	if _failures.is_empty():
		print("ROGUE_COMBAT_MULTIPLAYER_COORDINATOR_SMOKE_TEST_OK")
		quit(0)
		return
	for failure in _failures:
		push_error(failure)
	quit(1)


func _test_confirmed_formal_config_is_enabled() -> void:
	_expect(
		COORDINATOR.is_config_enabled_for_multiplayer(FORMAL_CONFIG),
		"玩家确认后的正式配置必须启用多人协调器。"
	)
	var scene_source := FileAccess.get_file_as_string(
		"res://scene/multiplayer/mp_rogue_route.tscn"
	)
	_expect(
		scene_source.contains(
			"[node name=\"RogueCombatCoordinator\" type=\"Node\" parent=\".\"]"
		),
		"MpRogueRoute 必须静态保存稳定 RPC NodePath 的协调器节点。"
	)
	_expect(
		scene_source.contains("manage_return_locally = false"),
		"多人路线不得自行执行单人返回流程。"
	)


func _test_occurrence_campaign_is_isolated() -> void:
	var config := _make_confirmed_config()
	config.enemy_pickup_drops = (
		RogueCombatEncounterConfig.Decision.NO
	)
	config.keep_enemy_kill_xirang = RogueCombatEncounterConfig.Decision.YES
	_expect(
		COORDINATOR.is_config_enabled_for_multiplayer(config),
		"内存中的完整确认配置应允许多人协调器启用。"
	)
	var campaign := COORDINATOR.build_occurrence_campaign(
		config,
		"combat:test:peer-party:1"
	)
	_expect(campaign != null, "应能构造 occurrence-local Campaign。")
	if campaign == null:
		return
	var source_wave := config.campaign.get_waves()[0]
	var wave := campaign.get_waves()[0]
	var source_entry := source_wave.enemy_entries[0]
	var entry := wave.enemy_entries[0]
	_expect(campaign != config.campaign, "Campaign 不得复用共享资源实例。")
	_expect(campaign.flow_graph != config.campaign.flow_graph, "FlowGraph 必须复制。")
	_expect(wave != source_wave, "WaveConfig 必须复制。")
	_expect(entry != source_entry, "WaveEnemyEntry 必须复制。")
	_expect(
		entry.enemy_config == source_entry.enemy_config
		and not entry.enemy_config.resource_path.is_empty(),
		"EnemyConfig 必须保留可供多人刷怪序列化的正式资源身份。"
	)
	_expect(
		entry.enemy_config.drop_table != null,
		"关闭掉落不得污染或复制无路径的共享敌人配置。"
	)
	_expect(wave.spawn_point_mask == config.spawn_point_mask, "应应用已确认红门掩码。")
	_expect(
		wave.spawn_count_per_tick == config.spawn_count_per_tick,
		"应应用已确认的同批生成数量。"
	)
	_expect(wave.get_total_enemy_count() == 10, "本次波次必须恰好包含10个作战机器人。")


func _test_kill_reward_policy_is_explicit() -> void:
	var config := _make_confirmed_config()
	config.enemy_pickup_drops = (
		RogueCombatEncounterConfig.Decision.YES
	)
	config.keep_enemy_kill_xirang = RogueCombatEncounterConfig.Decision.NO
	var campaign := COORDINATOR.build_occurrence_campaign(
		config,
		"combat:test:no-kill-reward:1"
	)
	_expect(campaign != null, "关闭击杀息壤仍应能构造合法波次。")
	if campaign == null:
		return
	var entry := campaign.get_waves()[0].enemy_entries[0]
	_expect(entry.xirang_kill_reward_override == 0, "关闭时必须明确覆盖为0。")
	_expect(entry.enemy_config.drop_table != null, "开启敌人拾取物掉落时不得清空掉落表。")


func _test_protocol_contract_is_static_and_order_safe() -> void:
	var source := FileAccess.get_file_as_string(
		"res://scene/rogue_combat/rogue_combat_multiplayer_coordinator.gd"
	)
	_expect(not source.is_empty(), "多人协调器源码必须可读取。")
	_expect(
		source.contains("func net_combat_prepared(occurrence_key: String)")
		and source.contains("func net_combat_activate(occurrence_key: String)"),
		"协议必须先收齐 prepared ack，再由房主激活战场。"
	)
	_expect(
		source.contains("not _local_outcome_received")
		and source.contains("not _settlement_received"),
		"本地退出必须同时等待 MpGame outcome 与房主 settlement。"
	)
	_expect(
		source.contains("RogueCombatRewardResolver.resolve_reward(")
		and source.contains("export_inventory_snapshot_for_peer(peer_id)"),
		"房主必须逐 peer 独立结算收藏品并同步权威背包快照。"
	)
	_expect(
		source.contains("_combat_game.auto_start_waves = true"),
		"Occurrence 配置完成后必须显式打开波次自动开始。"
	)
	_expect(
		source.contains("func net_combat_terminal_ready(")
		and source.contains("func net_combat_safe_to_teardown("),
		"跨信道结果到齐后还需安全 teardown 握手，避免缺失 RPC NodePath。"
	)
	_expect(
		source.contains("func _on_host_layout_committed(")
		and source.contains("_consumed_node_ids.clear()"),
		"重新生成路线后必须清理只属于旧布局的已消费节点 ID。"
	)
	_expect(
		source.contains("if not _show_local_result():")
		and source.contains("_return_to_route_local()"),
		"结算 UI 数据异常时也必须安全回图，不能永久锁在隐藏路线。"
	)
	var release_source := _slice_between(
		source,
		"func _try_release_local_runtime() -> void:",
		"func _resolve_stale_local_result_before_prepare() -> void:"
	)
	_expect(
		release_source.contains("not _terminal_safe_received")
		and not release_source.contains("_local_result_visible")
		and not release_source.contains("_local_route_returned"),
		"Terminal safe 后必须独立释放协议运行时，不能等待某位玩家关闭结果框。"
	)
	_expect(
		source.contains("var _local_result_occurrence_key := \"\"")
		and source.contains("_resolve_stale_local_result_before_prepare()")
		and source.contains(
			"_route.complete_normal_combat(_local_result_occurrence_key)"
		),
		"结果框必须保存独立 occurrence；下一场 prepare 可自动收起旧结果并回图。"
	)
	var player_left_source := _slice_between(
		source,
		"func _on_player_left(peer_id: int) -> void:",
		"func _on_player_joined(peer_id: int, _player_name: String) -> void:"
	)
	_expect(
		player_left_source.contains("_disconnected_participants[peer_id]")
		and not player_left_source.contains("_participant_peer_ids.erase(peer_id)")
		and source.contains("func _remap_pending_settlement_peer("),
		"断线只应退出 barrier，不得丢失可供重连迁移的参战身份与结算映射。"
	)
	_expect(
		source.contains("func net_combat_abort_requested(")
		and source.contains("func net_combat_aborted(")
		and source.contains("_abort_authoritative_protocol(&\"runtime_config_failed\")")
		and source.contains("_abort_authoritative_protocol(&\"host_runtime_activate_failed\")"),
		"准备、配置或激活失败必须进入房主权威 abort 广播，所有端可恢复路线。"
	)


func _make_confirmed_config() -> RogueCombatEncounterConfig:
	var config := FORMAL_CONFIG.duplicate(false) as RogueCombatEncounterConfig
	config.decisions_confirmed = true
	config.deadline_start = RogueCombatEncounterConfig.DeadlineStart.WAVE_START
	config.spawn_point_mask = RogueCombatEncounterConfig.REQUIRED_SCENE_SPAWN_POINT_MASK
	config.spawn_count_per_tick = 10
	config.keep_enemy_kill_xirang = RogueCombatEncounterConfig.Decision.YES
	config.filter_loot_by_character = RogueCombatEncounterConfig.Decision.YES
	config.reward_dead_players_on_victory = RogueCombatEncounterConfig.Decision.YES
	config.return_to_route_before_result = RogueCombatEncounterConfig.Decision.YES
	config.show_failure_result = RogueCombatEncounterConfig.Decision.YES
	config.consume_node_on_failure = RogueCombatEncounterConfig.Decision.YES
	config.enemy_pickup_drops = (
		RogueCombatEncounterConfig.Decision.NO
	)
	config.inherit_route_xirang = RogueCombatEncounterConfig.Decision.YES
	config.support_singleplayer = RogueCombatEncounterConfig.Decision.YES
	config.support_multiplayer = RogueCombatEncounterConfig.Decision.YES
	return config


func _expect(condition: bool, message: String) -> void:
	if not condition:
		_failures.append(message)


func _slice_between(source: String, start_marker: String, end_marker: String) -> String:
	var start := source.find(start_marker)
	var end := source.find(end_marker, start + start_marker.length())
	if start < 0 or end <= start:
		return ""
	return source.substr(start, end - start)
