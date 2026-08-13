extends SceneTree

const COORDINATOR := preload(
	"res://scene/game_modes/rogue/combat/rogue_combat_multiplayer_coordinator.gd"
)
const SINGLE_COORDINATOR := preload(
	"res://scene/game_modes/rogue/combat/rogue_combat_singleplayer_coordinator.gd"
)
const FORMAL_CONFIG := preload(
	"res://resources/config/rogue_combat/encounter_01.tres"
)
const UNDERGROUND_CHURCH_CONFIG := preload(
	"res://resources/config/rogue_combat/underground_church_01.tres"
)
const ROUTE_SCENE := preload(
	"res://scene/game_modes/rogue/route/rogue_route_game.tscn"
)

var _failures: PackedStringArray = []


func _init() -> void:
	call_deferred(&"_run")


func _run() -> void:
	_test_confirmed_formal_config_is_enabled()
	_test_floor_pool_enables_coordinator_without_bootstrap()
	_test_occurrence_campaign_is_isolated()
	_test_kill_reward_policy_is_explicit()
	_test_config_signature_uses_complete_runtime_contract()
	_test_protocol_contract_is_static_and_order_safe()

	if _failures.is_empty():
		print("ROGUE_COMBAT_MULTIPLAYER_COORDINATOR_SMOKE_TEST_OK")
		quit(0)
		return
	for failure in _failures:
		push_error(failure)
	quit(1)


func _test_floor_pool_enables_coordinator_without_bootstrap() -> void:
	var route := ROUTE_SCENE.instantiate() as RogueRouteGame
	_expect(
		route != null
		and COORDINATOR._has_enabled_multiplayer_combat_pool(route),
		"多人协调器必须由楼层普通作战池启用。"
	)
	_expect(
		route != null
		and SINGLE_COORDINATOR._has_enabled_singleplayer_combat_pool(route),
		"单人协调器必须由楼层普通作战池启用。"
	)
	_expect(
		COORDINATOR.is_config_enabled_for_multiplayer(UNDERGROUND_CHURCH_CONFIG),
		"地下教会配置必须支持多人作战。"
	)
	var source := FileAccess.get_file_as_string(
		"res://scene/game_modes/rogue/combat/rogue_combat_multiplayer_coordinator.gd"
	)
	var single_source := FileAccess.get_file_as_string(
		"res://scene/game_modes/rogue/combat/rogue_combat_singleplayer_coordinator.gd"
	)
	_expect(
		not source.contains("DEFAULT_ENCOUNTER_CONFIG")
		and not source.contains("@export var encounter_config")
		and not source.contains("else encounter_config"),
		"多人协调器不得保留单一默认配置、编辑器导出或协议回退。"
	)
	_expect(
		not single_source.contains("@export var encounter_config")
		and not single_source.contains("default_combat_config"),
		"单人协调器不得保留单一作战配置门禁或默认作战回退。"
	)
	if route != null:
		route.free()


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
	_expect(campaign != config.campaign, "Campaign 不得复用共享资源实例。")
	_expect(campaign.flow_graph != config.campaign.flow_graph, "FlowGraph 必须复制。")
	_expect(wave != source_wave, "WaveConfig 必须复制。")
	_expect(
		wave.enemy_entries.size() == 3
		and wave.enemy_entries.size() == source_wave.enemy_entries.size(),
		"多人 occurrence 必须完整复制三个正式敌人条目。"
	)
	for entry_index in range(mini(wave.enemy_entries.size(), source_wave.enemy_entries.size())):
		var source_entry := source_wave.enemy_entries[entry_index]
		var entry := wave.enemy_entries[entry_index]
		_expect(entry != source_entry, "WaveEnemyEntry %d 必须复制。" % entry_index)
		_expect(
			entry.enemy_config == source_entry.enemy_config
			and not entry.enemy_config.resource_path.is_empty()
			and entry.enemy_config.drop_table != null
			and entry.count == source_entry.count,
			"EnemyConfig %d 必须保留正式资源身份、掉落表与数量。" % entry_index
		)
	_expect(wave.spawn_point_mask == config.get_spawn_point_mask(), "应保留 Wave 红门掩码。")
	_expect(
		is_equal_approx(wave.spawn_interval, 0.3)
		and wave.spawn_count_per_tick == 1
		and wave.max_alive_enemies == 10
		and wave.spawn_point_order
		== WaveConfig.SpawnPointOrder.BALANCED_SHUFFLE_BAG,
		"Occurrence 必须保留0.3秒单刷、10名上限与低方差红门策略。"
	)
	_expect(
		wave.music == source_wave.music
		and wave.music is AudioStreamMP3
		and wave.music.resource_path.ends_with(
			"1-28 Journey of the Prairie King (The Outlaw).mp3"
		)
		and (wave.music as AudioStreamMP3).loop,
		"多人 occurrence 波次必须继承共享的循环 1-28 音乐。"
	)
	_expect(wave.get_total_enemy_count() == 22, "本次波次必须恰好包含22个战斗机器人。")


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
	for entry in campaign.get_waves()[0].enemy_entries:
		_expect(entry.xirang_kill_reward_override == 0, "关闭时全部条目必须明确覆盖为0。")
		_expect(entry.enemy_config.drop_table != null, "开启敌人拾取物掉落时不得清空掉落表。")


func _test_config_signature_uses_complete_runtime_contract() -> void:
	var baseline := FORMAL_CONFIG.compute_runtime_contract_hash()
	_expect(
		COORDINATOR._make_config_signature(FORMAL_CONFIG) == baseline,
		"多人准备签名必须直接委托 EncounterConfig 的完整运行契约。"
	)
	var changed := FORMAL_CONFIG.duplicate(false) as RogueCombatEncounterConfig
	changed.campaign = FORMAL_CONFIG.build_occurrence_campaign(
		"combat:test:signature:isolation"
	)
	var isolated_baseline := COORDINATOR._make_config_signature(changed)
	changed.campaign.get_waves()[0].enemy_entries[2].count += 1
	_expect(
		COORDINATOR._make_config_signature(changed) != isolated_baseline,
		"任一敌人条目数量变化必须触发多人配置签名不匹配。"
	)


func _test_protocol_contract_is_static_and_order_safe() -> void:
	var rpc_config: Dictionary = (COORDINATOR as Script).get_rpc_config()
	var actual_rpc_names := PackedStringArray()
	for rpc_name_variant in rpc_config.keys():
		actual_rpc_names.append(String(rpc_name_variant))
	actual_rpc_names.sort()
	var expected_rpc_names := PackedStringArray([
		"net_combat_abort_requested",
		"net_combat_aborted",
		"net_combat_activate",
		"net_combat_activated",
		"net_combat_prepare",
		"net_combat_prepared",
		"net_combat_route_spectator",
		"net_combat_safe_to_teardown",
		"net_combat_settlement",
		"net_combat_terminal_ready",
		"net_emergency_reward_choice_requested",
		"net_emergency_reward_completion_retry_requested",
		"net_emergency_reward_snapshot",
	])
	expected_rpc_names.sort()
	var any_peer_rpc_names := {
		"net_combat_abort_requested": true,
		"net_combat_activated": true,
		"net_combat_prepared": true,
		"net_combat_terminal_ready": true,
		"net_emergency_reward_choice_requested": true,
		"net_emergency_reward_completion_retry_requested": true,
	}
	_expect(
		actual_rpc_names == expected_rpc_names,
		"肉鸽作战协调器必须严格保留既有10个入口并新增3个紧急奖励RPC。"
	)
	for rpc_name in expected_rpc_names:
		var config := rpc_config.get(StringName(rpc_name), {}) as Dictionary
		_expect(
			int(config.get("transfer_mode", -1))
			== MultiplayerPeer.TRANSFER_MODE_RELIABLE
			and int(config.get("channel", -1)) == 0
			and not bool(config.get("call_local", true))
			and int(config.get("rpc_mode", -1))
			== (
				MultiplayerAPI.RPC_MODE_ANY_PEER
				if any_peer_rpc_names.has(rpc_name)
				else MultiplayerAPI.RPC_MODE_AUTHORITY
			),
			"肉鸽作战 RPC %s 必须保持 ch0 reliable/call_remote。" % rpc_name
		)
	var source := FileAccess.get_file_as_string(
		"res://scene/game_modes/rogue/combat/rogue_combat_multiplayer_coordinator.gd"
	)
	var reward_source := FileAccess.get_file_as_string(
		"res://scene/game_modes/rogue/combat/rogue_combat_reward_resolver.gd"
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
		source.contains("RogueCombatRewardResolver.resolve_party_rewards(")
		and reward_source.contains("apply_authoritative_party_transaction(")
		and source.contains("export_inventory_snapshot_for_peer(peer_id)"),
		"房主必须用一次Party Economy CAS结算多奖励并同步权威背包快照。"
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
	var victory_terminal_source := _slice_between(
		source,
		"func _play_local_victory_terminal(occurrence_key: String) -> void:",
		"func _is_current_victory_terminal("
	)
	var title_index := victory_terminal_source.find(
		"await presentation.play(game.music_player)"
	)
	var cover_index := victory_terminal_source.find("await transition.cover()")
	var return_index := victory_terminal_source.find("_return_to_route_local()")
	var reveal_index := victory_terminal_source.find("await transition.reveal()")
	var result_index := victory_terminal_source.find("_show_local_result()")
	var ready_index := victory_terminal_source.find("_mark_local_terminal_ready()")
	_expect(
		title_index >= 0
		and cover_index > title_index
		and return_index > cover_index
		and reveal_index > return_index
		and result_index > reveal_index
		and ready_index > result_index,
		"多人胜利必须按标题→遮盖→回图→揭示→结算→terminal-ready 顺序执行。"
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
		and source.contains("func _remap_pending_settlement_peer(")
		and source.contains("_participant_character_ids")
		and source.contains("_participant_stable_keys")
		and source.contains("_last_combat_xirang_by_peer")
		and source.contains("get_followup_combat_participant_peer_ids("),
		(
			"断线只应退出 barrier；角色、稳定身份、最后息壤与跟随作战参战名单"
			+ "都必须独立冻结并参与后续结算。"
		)
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
