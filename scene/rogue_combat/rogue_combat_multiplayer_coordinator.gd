extends Node
class_name RogueCombatMultiplayerCoordinator

## 多人 Rouge 路线与一次性作战运行时之间的权威协调器。
##
## 此节点必须静态存在于 MpRogueRoute 场景中，保证所有 peer 的 RPC
## NodePath 恒定。encounter 配置无效或未确认时，本节点不会连接路线的
## normal_combat_requested 信号，因此不会意外锁住测试地图。

const MP_GAME_SCENE := preload("res://scene/multiplayer/mp_game.tscn")
const DEFAULT_ENCOUNTER_CONFIG := preload(
	"res://resources/config/rogue_combat/encounter_01.tres"
)

const COMBAT_RUNTIME_NODE_NAME := &"RogueCombatNetwork"
const STANDARD_BATTLE_XIRANG := 1000
const INVALID_NODE_ID := -1
const TERMINAL_PROCESS_MODE := Node.PROCESS_MODE_DISABLED

enum ProtocolPhase {
	IDLE,
	PREPARING,
	ACTIVE,
	SETTLED,
}

@export var encounter_config: RogueCombatEncounterConfig = (
	DEFAULT_ENCOUNTER_CONFIG
)

var _route: TestRogueRouteP3 = null
var _net_manager: Node = null
var _run_state: RunStateStore = null
var _enabled := false
var _phase := ProtocolPhase.IDLE

var _active_node_id := INVALID_NODE_ID
var _active_content_seed := 0
var _active_occurrence_key := ""
var _active_config_signature := ""
var _participant_peer_ids: Dictionary = {}
var _entry_xirang_by_peer: Dictionary = {}
var _disconnected_participants: Dictionary = {}
var _pending_spectator_peers: Dictionary = {}
var _reconnecting_peer_ids: Dictionary = {}

var _expected_prepared_peers: Dictionary = {}
var _prepared_peers: Dictionary = {}
var _activate_when_prepared := false
var _local_runtime_prepared := false
var _local_runtime_activated := false

var _combat_network: Node = null
var _combat_game: RogueCombatGame = null
var _local_outcome_received := false
var _local_outcome_victory := false
var _local_outcome_failure_reason := ""
var _settlement_received := false
var _pending_settlement: Dictionary = {}
var _settlement_scheduled := false
var _settled_occurrences: Dictionary = {}

var _expected_terminal_peers: Dictionary = {}
var _terminal_ready_peers: Dictionary = {}
var _terminal_safe_received := false
var _terminal_safe_broadcast := false

var _local_result_visible := false
var _local_route_returned := false
var _local_result_occurrence_key := ""
var _local_terminal_finalized := false
var _consumed_node_ids: Dictionary = {}
var _terminal_sequence_serial := 0


func _ready() -> void:
	_route = get_node_or_null("../RogueRoute") as TestRogueRouteP3
	_net_manager = get_node_or_null("/root/NetManager")
	_run_state = get_node_or_null("/root/RunState") as RunStateStore
	_enabled = (
		_route != null
		and _net_manager != null
		and _run_state != null
		and is_config_enabled_for_multiplayer(encounter_config)
	)
	if _net_manager != null:
		set_multiplayer_authority(_get_host_peer_id())
	if not _enabled:
		return

	if not _route.normal_combat_requested.is_connected(
		_on_normal_combat_requested
	):
		_route.normal_combat_requested.connect(_on_normal_combat_requested)
	if not _route.combat_result_dismissed.is_connected(
		_on_combat_result_dismissed
	):
		_route.combat_result_dismissed.connect(_on_combat_result_dismissed)
	if not _route.host_layout_committed.is_connected(
		_on_host_layout_committed
	):
		_route.host_layout_committed.connect(_on_host_layout_committed)
	if not _route.normal_combat_stage_reset.is_connected(
		_on_route_normal_combat_stage_reset
	):
		_route.normal_combat_stage_reset.connect(
			_on_route_normal_combat_stage_reset
		)
	_connect_net_manager_signals()


func _exit_tree() -> void:
	_interrupt_terminal_presentation()
	_disconnect_route_signals()
	_disconnect_net_manager_signals()


func is_enabled() -> bool:
	return _enabled


func is_combat_active() -> bool:
	return _phase != ProtocolPhase.IDLE


static func is_config_enabled_for_multiplayer(
	config: RogueCombatEncounterConfig
) -> bool:
	return (
		config != null
		and config.is_ready_to_enable()
		and config.support_multiplayer
		== RogueCombatEncounterConfig.Decision.YES
	)


## 复制完整 occurrence 资源图，调用方可安全修改而不污染共享 .tres。
static func build_occurrence_campaign(
	config: RogueCombatEncounterConfig,
	occurrence_key: String
) -> WaveCampaignConfig:
	return (
		config.build_occurrence_campaign(occurrence_key)
		if config != null
		else null
	)


func _connect_net_manager_signals() -> void:
	if not _net_manager.player_left.is_connected(_on_player_left):
		_net_manager.player_left.connect(_on_player_left)
	if not _net_manager.player_joined.is_connected(_on_player_joined):
		_net_manager.player_joined.connect(_on_player_joined)
	if not _net_manager.player_reconnected.is_connected(
		_on_player_reconnected
	):
		_net_manager.player_reconnected.connect(_on_player_reconnected)


func _disconnect_route_signals() -> void:
	if _route == null or not is_instance_valid(_route):
		return
	if _route.normal_combat_requested.is_connected(
		_on_normal_combat_requested
	):
		_route.normal_combat_requested.disconnect(_on_normal_combat_requested)
	if _route.combat_result_dismissed.is_connected(
		_on_combat_result_dismissed
	):
		_route.combat_result_dismissed.disconnect(
			_on_combat_result_dismissed
		)
	if _route.host_layout_committed.is_connected(
		_on_host_layout_committed
	):
		_route.host_layout_committed.disconnect(_on_host_layout_committed)
	if _route.normal_combat_stage_reset.is_connected(
		_on_route_normal_combat_stage_reset
	):
		_route.normal_combat_stage_reset.disconnect(
			_on_route_normal_combat_stage_reset
		)


func _on_host_layout_committed(
	_layout_snapshot: Dictionary,
	_state_snapshot: Dictionary
) -> void:
	# Node ids are scoped to one generated layout. A newly committed route must
	# not inherit consumed combat nodes from the previous layout.
	if _phase == ProtocolPhase.IDLE:
		_consumed_node_ids.clear()


func _disconnect_net_manager_signals() -> void:
	if _net_manager == null or not is_instance_valid(_net_manager):
		return
	if _net_manager.player_left.is_connected(_on_player_left):
		_net_manager.player_left.disconnect(_on_player_left)
	if _net_manager.player_joined.is_connected(_on_player_joined):
		_net_manager.player_joined.disconnect(_on_player_joined)
	if _net_manager.player_reconnected.is_connected(
		_on_player_reconnected
	):
		_net_manager.player_reconnected.disconnect(_on_player_reconnected)


func _on_normal_combat_requested(
	node_id: int,
	content_seed: int,
	occurrence_key: String
) -> void:
	if (
		not _enabled
		or not _is_host()
		or _phase != ProtocolPhase.IDLE
		or not is_config_enabled_for_multiplayer(encounter_config)
		or node_id < 0
		or occurrence_key.is_empty()
	):
		return
	if _consumed_node_ids.has(node_id):
		_route.complete_normal_combat(occurrence_key)
		return

	var participants := _capture_current_participants()
	if participants.is_empty():
		_route.complete_normal_combat(occurrence_key)
		return
	var entry_xirang := _capture_entry_xirang(participants)
	if entry_xirang.size() != participants.size():
		push_error("RogueCombatMultiplayerCoordinator: 无法捕获完整入口息壤。")
		_route.complete_normal_combat(occurrence_key)
		return

	if not _begin_protocol(
		node_id,
		content_seed,
		occurrence_key,
		participants,
		entry_xirang,
		false
	):
		_abort_authoritative_protocol(&"host_runtime_create_failed")
		return
	for peer_id_variant in _participant_peer_ids.keys():
		var peer_id := int(peer_id_variant)
		if peer_id == _get_local_peer_id() or not _is_peer_send_ready(peer_id):
			continue
		net_combat_prepare.rpc_id(
			peer_id,
			_active_node_id,
			_active_content_seed,
			_active_occurrence_key,
			_active_config_signature,
			_pack_peer_ids(_participant_peer_ids),
			_entry_xirang_by_peer.duplicate(true),
			false
		)


func _begin_protocol(
	node_id: int,
	content_seed: int,
	occurrence_key: String,
	participant_peer_ids: PackedInt32Array,
	entry_xirang_by_peer: Dictionary,
	activate_when_prepared: bool
) -> bool:
	if (
		_phase != ProtocolPhase.IDLE
		or node_id < 0
		or occurrence_key.is_empty()
		or participant_peer_ids.is_empty()
	):
		return false
	_resolve_stale_local_result_before_prepare()
	_active_node_id = node_id
	_active_content_seed = content_seed
	_active_occurrence_key = occurrence_key
	_active_config_signature = _make_config_signature(encounter_config)
	_participant_peer_ids = _index_peer_ids(participant_peer_ids)
	_entry_xirang_by_peer = entry_xirang_by_peer.duplicate(true)
	_disconnected_participants.clear()
	_expected_prepared_peers = _participant_peer_ids.duplicate()
	_prepared_peers.clear()
	_activate_when_prepared = activate_when_prepared
	_local_runtime_prepared = false
	_local_runtime_activated = false
	_local_outcome_received = false
	_local_outcome_victory = false
	_local_outcome_failure_reason = ""
	_settlement_received = false
	_pending_settlement.clear()
	_settlement_scheduled = false
	_expected_terminal_peers.clear()
	_terminal_ready_peers.clear()
	_terminal_safe_received = false
	_terminal_safe_broadcast = false
	_local_terminal_finalized = false
	_phase = ProtocolPhase.PREPARING
	_route.set_route_presentation_enabled(false)
	return _create_embedded_runtime()


@rpc("authority", "call_remote", "reliable", 0)
func net_combat_prepare(
	node_id: int,
	content_seed: int,
	occurrence_key: String,
	config_signature: String,
	participant_peer_ids: PackedInt32Array,
	entry_xirang_by_peer: Dictionary,
	activate_when_prepared: bool
) -> void:
	if (
		not _is_client()
		or multiplayer.get_remote_sender_id() != _get_host_peer_id()
	):
		return
	if not _enabled:
		_request_authoritative_abort(occurrence_key, &"local_config_disabled")
		return
	if config_signature != _make_config_signature(encounter_config):
		_request_authoritative_abort(occurrence_key, &"config_mismatch")
		return
	if _phase != ProtocolPhase.IDLE:
		if occurrence_key != _active_occurrence_key:
			return
		_activate_when_prepared = (
			_activate_when_prepared or activate_when_prepared
		)
		if _activate_when_prepared and _local_runtime_prepared:
			_activate_local_runtime()
		return
	_resolve_stale_local_result_before_prepare()
	if not _route.apply_normal_combat_started(
		node_id,
		content_seed,
		occurrence_key
	):
		push_error(
			"RogueCombatMultiplayerCoordinator: 客户端拒绝了无法复算的作战启动包。"
		)
		_request_authoritative_abort(occurrence_key, &"route_start_rejected")
		return
	if not _begin_protocol(
		node_id,
		content_seed,
		occurrence_key,
		participant_peer_ids,
		entry_xirang_by_peer,
		activate_when_prepared
	):
		_request_authoritative_abort(occurrence_key, &"runtime_create_failed")


func _create_embedded_runtime() -> bool:
	if _combat_network != null or _active_occurrence_key.is_empty():
		return false
	var instance := MP_GAME_SCENE.instantiate()
	if instance == null:
		push_error("RogueCombatMultiplayerCoordinator: 无法实例化 MpGame。")
		return false
	instance.name = COMBAT_RUNTIME_NODE_NAME
	instance.set("embedded_runtime", true)
	instance.set(
		"runtime_scene_path_override",
		encounter_config.combat_scene_path
	)
	if not instance.is_connected(
		&"embedded_runtime_prepared",
		_on_embedded_runtime_prepared
	):
		instance.connect(
			&"embedded_runtime_prepared",
			_on_embedded_runtime_prepared
		)
	_combat_network = instance
	add_child(instance)
	return true


func _on_embedded_runtime_prepared() -> void:
	if (
		_phase != ProtocolPhase.PREPARING
		or _combat_network == null
		or not is_instance_valid(_combat_network)
		or not _configure_occurrence_runtime()
	):
		push_error(
			"RogueCombatMultiplayerCoordinator: 嵌入战场准备完成但 occurrence 配置失败。"
		)
		if _is_host():
			_abort_authoritative_protocol(&"runtime_config_failed")
		else:
			_request_authoritative_abort(
				_active_occurrence_key,
				&"runtime_config_failed"
			)
		return
	_local_runtime_prepared = true
	var local_peer_id := _get_local_peer_id()
	if local_peer_id <= 0 or not _participant_peer_ids.has(local_peer_id):
		return
	if _is_host():
		_prepared_peers[local_peer_id] = true
		_try_activate_host_barrier()
	elif _is_client() and _is_peer_send_ready(_get_host_peer_id()):
		net_combat_prepared.rpc_id(
			_get_host_peer_id(),
			_active_occurrence_key
		)
	if _activate_when_prepared:
		if not _activate_local_runtime():
			if _is_host():
				_abort_authoritative_protocol(&"runtime_activate_failed")
			else:
				_request_authoritative_abort(
					_active_occurrence_key,
					&"runtime_activate_failed"
				)


func _configure_occurrence_runtime() -> bool:
	if not _combat_network.has_method("get_game_runtime"):
		return false
	var game_runtime := (
		_combat_network.call("get_game_runtime") as GameRuntimeBase
	)
	_combat_game = game_runtime as RogueCombatGame
	if _combat_game == null or _combat_game.current_flow_step != null:
		return false
	var scene_contract_errors := _combat_game.validate_encounter_scene_contract(
		encounter_config.spawn_point_mask
	)
	if not scene_contract_errors.is_empty():
		for error in scene_contract_errors:
			push_error(error)
		return false
	var campaign := build_occurrence_campaign(
		encounter_config,
		_active_occurrence_key
	)
	if campaign == null or not campaign.validate_campaign().is_empty():
		return false

	# MpGame 当前没有 campaign override 构造参数；prepared 阶段仍未激活，
	# 可在 current_flow_step 为空时原子换入 occurrence-local 资源图。
	_combat_game.multiplayer_campaign = campaign
	_combat_game.active_campaign = campaign
	_combat_game.flow_graph = campaign.flow_graph
	_combat_game.waves.assign(campaign.get_waves())
	_combat_game.bosses.clear()
	_combat_game.event_title = encounter_config.event_title
	_combat_game.pre_wave_duration = float(
		encounter_config.preparation_seconds
	)
	_combat_game.combat_time_limit_seconds = float(
		encounter_config.combat_limit_seconds
	)
	_combat_game.deadline_start = (
		RogueCombatGame.DeadlineStart.PREPARATION_START
		if encounter_config.deadline_start
		== RogueCombatEncounterConfig.DeadlineStart.PREPARATION_START
		else RogueCombatGame.DeadlineStart.WAVE_START
	)
	_combat_game.linglan_boss_enabled = false
	_combat_game.enemy_pickup_drops_enabled = (
		encounter_config.enemy_pickup_drops
		== RogueCombatEncounterConfig.Decision.YES
	)
	_apply_xirang_map_to_game(_combat_game, _entry_xirang_by_peer)
	for raw_peer_id in _participant_peer_ids.keys():
		var peer_id := int(raw_peer_id)
		var battle_player := _combat_game.get_player_for_peer(peer_id)
		if battle_player != null and is_instance_valid(battle_player):
			battle_player.set_run_max_health_penalty(
				_run_state.get_max_health_penalty_for_peer(peer_id)
			)
	if not _combat_game.combat_outcome_started.is_connected(
		_on_local_combat_outcome_started
	):
		_combat_game.combat_outcome_started.connect(
			_on_local_combat_outcome_started
		)
	# 必须最后打开，确保 activate_runtime() 看到完整 campaign / 经济 / 环境。
	_combat_game.auto_start_waves = true
	return true


@rpc("any_peer", "call_remote", "reliable", 0)
func net_combat_prepared(occurrence_key: String) -> void:
	if (
		not _is_host()
		or _phase != ProtocolPhase.PREPARING
		or occurrence_key != _active_occurrence_key
	):
		return
	var sender_id := multiplayer.get_remote_sender_id()
	if not _expected_prepared_peers.has(sender_id):
		return
	_prepared_peers[sender_id] = true
	_try_activate_host_barrier()


func _try_activate_host_barrier() -> void:
	if (
		not _is_host()
		or _phase != ProtocolPhase.PREPARING
		or not _local_runtime_prepared
		or not _contains_all_keys(
			_prepared_peers,
			_expected_prepared_peers
		)
	):
		return
	for peer_id_variant in _participant_peer_ids.keys():
		var peer_id := int(peer_id_variant)
		if peer_id == _get_local_peer_id() or not _is_peer_send_ready(peer_id):
			continue
		net_combat_activate.rpc_id(peer_id, _active_occurrence_key)
	if not _activate_local_runtime():
		_abort_authoritative_protocol(&"host_runtime_activate_failed")


@rpc("authority", "call_remote", "reliable", 0)
func net_combat_activate(occurrence_key: String) -> void:
	if (
		not _is_client()
		or multiplayer.get_remote_sender_id() != _get_host_peer_id()
		or _phase != ProtocolPhase.PREPARING
		or occurrence_key != _active_occurrence_key
	):
		return
	_activate_when_prepared = true
	if _local_runtime_prepared:
		if not _activate_local_runtime():
			_request_authoritative_abort(
				_active_occurrence_key,
				&"client_runtime_activate_failed"
			)


func _activate_local_runtime() -> bool:
	if (
		_local_runtime_activated
		or not _local_runtime_prepared
		or _combat_network == null
		or not is_instance_valid(_combat_network)
		or not _combat_network.has_method("activate_embedded_runtime")
	):
		return false
	if not bool(_combat_network.call("activate_embedded_runtime")):
		return false
	_local_runtime_activated = true
	_phase = ProtocolPhase.ACTIVE
	return true


func _on_local_combat_outcome_started(
	victory: bool,
	failure_reason: String
) -> void:
	if (
		_phase not in [ProtocolPhase.ACTIVE, ProtocolPhase.SETTLED]
		or _local_outcome_received
	):
		return
	_local_outcome_received = true
	_local_outcome_victory = victory
	_local_outcome_failure_reason = failure_reason
	if _is_host() and not _settlement_scheduled:
		_settlement_scheduled = true
		# 最后一名敌人的击杀息壤通过 deferred 批处理；结算也 deferred，
		# 保证读取 final_xirang 时已包含最后一次击杀奖励。
		call_deferred(
			"_settle_host_outcome",
			_active_occurrence_key,
			victory,
			failure_reason
		)
	# 本地结果同样可能来自 body_entered 等物理回调；若结算快照已经
	# 到达，立即 finalize 会递归禁用战场碰撞体，因此统一延迟收束。
	call_deferred(&"_try_finalize_local_terminal")


func _settle_host_outcome(
	occurrence_key: String,
	victory: bool,
	failure_reason: String
) -> void:
	if (
		not _is_host()
		or occurrence_key != _active_occurrence_key
		or _settled_occurrences.has(occurrence_key)
		or _combat_game == null
		or not is_instance_valid(_combat_game)
	):
		return
	_settled_occurrences[occurrence_key] = true
	var final_xirang_by_peer: Dictionary = {}
	var inventory_snapshots_by_peer: Dictionary = {}
	var results_by_peer: Dictionary = {}
	var filter_by_character := (
		encounter_config.filter_loot_by_character
		== RogueCombatEncounterConfig.Decision.YES
	)
	var reward_dead_players := (
		encounter_config.reward_dead_players_on_victory
		== RogueCombatEncounterConfig.Decision.YES
	)
	for peer_id_variant in _participant_peer_ids.keys():
		var peer_id := int(peer_id_variant)
		var battle_player := _combat_game.get_player_for_peer(peer_id)
		if battle_player == null or not is_instance_valid(battle_player):
			var route_player := _route.get_player_for_peer(peer_id)
			final_xirang_by_peer[peer_id] = (
				route_player.get_xirang()
				if route_player != null and is_instance_valid(route_player)
				else int(_entry_xirang_by_peer.get(peer_id, 0))
			)
			inventory_snapshots_by_peer[peer_id] = (
				_run_state.export_inventory_snapshot_for_peer(peer_id)
			)
			results_by_peer[peer_id] = (
				_make_unrewarded_victory_result(peer_id)
				if victory
				else {
					"victory": false,
					"failure_reason": failure_reason,
					"peer_id": peer_id,
				}
			)
			continue
		var result: Dictionary
		var eligible := reward_dead_players or not battle_player.is_dead
		if victory and eligible:
			battle_player.grant_xirang_reward(
				encounter_config.extra_xirang,
				false
			)
			result = RogueCombatRewardResolver.resolve_reward(
				_run_state,
				StringName(occurrence_key),
				_active_content_seed,
				peer_id,
				encounter_config.extra_xirang,
				filter_by_character,
				battle_player
			)
			result["victory"] = true
		elif victory:
			result = _make_unrewarded_victory_result(peer_id)
		else:
			result = {
				"victory": false,
				"failure_reason": failure_reason,
				"peer_id": peer_id,
			}
		final_xirang_by_peer[peer_id] = battle_player.get_xirang()
		inventory_snapshots_by_peer[peer_id] = (
			_run_state.export_inventory_snapshot_for_peer(peer_id)
		)
		results_by_peer[peer_id] = result

	var consume_node := victory or (
		encounter_config.consume_node_on_failure
		== RogueCombatEncounterConfig.Decision.YES
	)
	var settlement := {
		"node_id": _active_node_id,
		"content_seed": _active_content_seed,
		"occurrence_key": occurrence_key,
		"victory": victory,
		"failure_reason": failure_reason,
		"consume_node": consume_node,
		"final_xirang_by_peer": final_xirang_by_peer,
		"inventory_snapshots_by_peer": inventory_snapshots_by_peer,
		"results_by_peer": results_by_peer,
	}
	for peer_id_variant in _participant_peer_ids.keys():
		var peer_id := int(peer_id_variant)
		if peer_id == _get_local_peer_id() or not _is_peer_send_ready(peer_id):
			continue
		net_combat_settlement.rpc_id(
			peer_id,
			occurrence_key,
			settlement.duplicate(true)
		)
	_apply_settlement(settlement)


@rpc("authority", "call_remote", "reliable", 0)
func net_combat_settlement(
	occurrence_key: String,
	settlement: Dictionary
) -> void:
	if (
		not _is_client()
		or multiplayer.get_remote_sender_id() != _get_host_peer_id()
		or occurrence_key != _active_occurrence_key
	):
		return
	_apply_settlement(settlement)


func _apply_settlement(settlement: Dictionary) -> bool:
	if (
		_settlement_received
		or settlement.is_empty()
		or str(settlement.get("occurrence_key", ""))
		!= _active_occurrence_key
		or typeof(settlement.get("victory")) != TYPE_BOOL
		or typeof(settlement.get("final_xirang_by_peer"))
		!= TYPE_DICTIONARY
		or typeof(settlement.get("inventory_snapshots_by_peer"))
		!= TYPE_DICTIONARY
		or typeof(settlement.get("results_by_peer")) != TYPE_DICTIONARY
	):
		return false
	var final_xirang := settlement["final_xirang_by_peer"] as Dictionary
	var inventory_snapshots := (
		settlement["inventory_snapshots_by_peer"] as Dictionary
	)
	var results := settlement["results_by_peer"] as Dictionary
	if not _validate_authoritative_peer_maps(
		final_xirang,
		inventory_snapshots,
		results
	):
		return false

	_apply_xirang_map_to_game(_combat_game, final_xirang)
	_apply_xirang_map_to_route(final_xirang)
	for peer_id_variant in inventory_snapshots.keys():
		var peer_id := int(peer_id_variant)
		var snapshot := inventory_snapshots[peer_id_variant] as Dictionary
		if not _is_host():
			_run_state.apply_inventory_snapshot_for_peer(peer_id, snapshot, true)
	if bool(settlement.get("consume_node", false)):
		_consumed_node_ids[int(settlement.get("node_id", INVALID_NODE_ID))] = true

	_pending_settlement = settlement.duplicate(true)
	_settlement_received = true
	_phase = ProtocolPhase.SETTLED
	_expected_terminal_peers = _participant_peer_ids.duplicate()
	for disconnected_peer_id in _disconnected_participants.keys():
		_expected_terminal_peers.erase(disconnected_peer_id)
	_try_finalize_local_terminal()
	return true


func _try_finalize_local_terminal() -> void:
	if (
		_local_terminal_finalized
		or not _local_outcome_received
		or not _settlement_received
	):
		return
	if (
		bool(_pending_settlement.get("victory", false))
		!= _local_outcome_victory
	):
		push_error(
			"RogueCombatMultiplayerCoordinator: 本地战斗结果与房主结算不一致。"
		)
		return
	_local_terminal_finalized = true
	_stop_local_combat_processing()
	_local_result_occurrence_key = _active_occurrence_key
	_local_result_visible = false
	_local_route_returned = false

	var victory := bool(_pending_settlement.get("victory", false))
	if victory:
		_play_local_victory_terminal(_active_occurrence_key)
		return
	var should_show_result := victory or (
		encounter_config.show_failure_result
		== RogueCombatEncounterConfig.Decision.YES
	)
	var return_before_result := (
		encounter_config.return_to_route_before_result
		== RogueCombatEncounterConfig.Decision.YES
	)
	if return_before_result or not should_show_result:
		_return_to_route_local()
	if should_show_result:
		if not _show_local_result():
			_return_to_route_local()
			_clear_local_result_lifecycle()
	else:
		_clear_local_result_lifecycle()
	_mark_local_terminal_ready()


func _play_local_victory_terminal(occurrence_key: String) -> void:
	if (
		_route == null
		or _combat_game == null
		or not is_instance_valid(_route)
		or not is_instance_valid(_combat_game)
	):
		_abort_interrupted_victory_terminal(occurrence_key)
		return
	_terminal_sequence_serial += 1
	var serial := _terminal_sequence_serial
	var game := _combat_game
	var presentation := _route.combat_victory_presentation
	var transition := _route.combat_scene_transition
	var title_completed := await presentation.play(game.music_player)
	if not title_completed:
		_abort_interrupted_victory_terminal(occurrence_key)
		return
	if not _is_current_victory_terminal(serial, occurrence_key, game):
		_abort_interrupted_victory_terminal(occurrence_key)
		return
	var cover_completed := await transition.cover()
	if not cover_completed:
		_abort_interrupted_victory_terminal(occurrence_key)
		return
	if not _is_current_victory_terminal(serial, occurrence_key, game):
		_abort_interrupted_victory_terminal(occurrence_key)
		return
	_return_to_route_local()
	var reveal_completed := await transition.reveal()
	if not reveal_completed:
		_abort_interrupted_victory_terminal(occurrence_key)
		return
	if not _is_current_victory_terminal(serial, occurrence_key, game):
		_abort_interrupted_victory_terminal(occurrence_key)
		return
	if not _show_local_result():
		_clear_local_result_lifecycle()
	_mark_local_terminal_ready()


func _is_current_victory_terminal(
	serial: int,
	occurrence_key: String,
	game: RogueCombatGame
) -> bool:
	return (
		serial == _terminal_sequence_serial
		and _local_terminal_finalized
		and _phase == ProtocolPhase.SETTLED
		and occurrence_key == _active_occurrence_key
		and occurrence_key == _local_result_occurrence_key
		and game == _combat_game
		and is_instance_valid(game)
		and _settlement_received
		and _local_outcome_received
		and _local_outcome_victory
		and bool(_pending_settlement.get("victory", false))
	)


func _abort_interrupted_victory_terminal(occurrence_key: String) -> void:
	if (
		occurrence_key.is_empty()
		or _phase == ProtocolPhase.IDLE
		or occurrence_key != _active_occurrence_key
	):
		return
	_interrupt_terminal_presentation()
	if _is_host():
		call_deferred(
			&"_abort_authoritative_protocol",
			&"victory_presentation_interrupted"
		)
		return
	if _is_client():
		_request_authoritative_abort(
			occurrence_key,
			&"victory_presentation_interrupted"
		)
	_apply_protocol_abort(occurrence_key)


func _on_route_normal_combat_stage_reset(occurrence_key: String) -> void:
	_abort_interrupted_victory_terminal(
		occurrence_key
		if not occurrence_key.is_empty()
		else _active_occurrence_key
	)


func _mark_local_terminal_ready() -> void:
	var local_peer_id := _get_local_peer_id()
	if local_peer_id <= 0:
		return
	if _is_host():
		_terminal_ready_peers[local_peer_id] = true
		_try_broadcast_safe_teardown()
	elif _is_client() and _is_peer_send_ready(_get_host_peer_id()):
		net_combat_terminal_ready.rpc_id(
			_get_host_peer_id(),
			_active_occurrence_key
		)


@rpc("any_peer", "call_remote", "reliable", 0)
func net_combat_terminal_ready(occurrence_key: String) -> void:
	if (
		not _is_host()
		or not _settlement_received
		or occurrence_key != _active_occurrence_key
	):
		return
	var sender_id := multiplayer.get_remote_sender_id()
	if not _expected_terminal_peers.has(sender_id):
		return
	_terminal_ready_peers[sender_id] = true
	_try_broadcast_safe_teardown()


func _try_broadcast_safe_teardown() -> void:
	if (
		not _is_host()
		or _terminal_safe_broadcast
		or not _settlement_received
		or not _contains_all_keys(
			_terminal_ready_peers,
			_expected_terminal_peers
		)
	):
		return
	_terminal_safe_broadcast = true
	for peer_id_variant in _participant_peer_ids.keys():
		var peer_id := int(peer_id_variant)
		if peer_id == _get_local_peer_id() or not _is_peer_send_ready(peer_id):
			continue
		net_combat_safe_to_teardown.rpc_id(peer_id, _active_occurrence_key)
	_receive_safe_to_teardown(_active_occurrence_key)


@rpc("authority", "call_remote", "reliable", 0)
func net_combat_safe_to_teardown(occurrence_key: String) -> void:
	if (
		not _is_client()
		or multiplayer.get_remote_sender_id() != _get_host_peer_id()
	):
		return
	_receive_safe_to_teardown(occurrence_key)


func _receive_safe_to_teardown(occurrence_key: String) -> void:
	if occurrence_key != _active_occurrence_key:
		return
	_terminal_safe_received = true
	_try_release_local_runtime()


func _show_local_result() -> bool:
	if _local_result_visible or _route == null:
		return false
	var local_peer_id := _get_local_peer_id()
	var results := _pending_settlement.get("results_by_peer", {}) as Dictionary
	var result := results.get(local_peer_id, {}) as Dictionary
	if result.is_empty():
		return false
	# ResultOverlay 与战场 HUD 都是 CanvasLayer；明确提升结算层，避免
	# return_to_route_before_result=NO 时被仍保留的战场 UI 覆盖。
	if _route.combat_result_overlay != null:
		_route.combat_result_overlay.layer = 100
	if not _route.show_combat_result(result):
		return false
	_local_result_visible = true
	return true


func _on_combat_result_dismissed() -> void:
	if not _local_result_visible:
		return
	_local_result_visible = false
	_route.hide_combat_result()
	if not _local_route_returned:
		_return_to_route_local()
	_clear_local_result_lifecycle()


func _return_to_route_local() -> void:
	if _local_route_returned or _route == null:
		return
	_local_route_returned = true
	_set_combat_presentation_visible(false)
	_route.complete_normal_combat(_local_result_occurrence_key)
	_route.set_route_presentation_enabled(true)


func _stop_local_combat_processing() -> void:
	if _combat_network == null or not is_instance_valid(_combat_network):
		return
	# Host 停止继续发战场快照；客户端仍保留稳定 RPC NodePath，直至
	# 所有参战端均确认已收到 outcome + settlement。
	_combat_network.process_mode = TERMINAL_PROCESS_MODE


func _set_combat_presentation_visible(visible: bool) -> void:
	if _combat_network is CanvasItem and is_instance_valid(_combat_network):
		(_combat_network as CanvasItem).visible = visible


func _try_release_local_runtime() -> void:
	if not _terminal_safe_received:
		return
	if _combat_network != null and is_instance_valid(_combat_network):
		_combat_network.queue_free()
	_combat_network = null
	_combat_game = null
	_reset_protocol_state()


func _resolve_stale_local_result_before_prepare() -> void:
	if _local_result_occurrence_key.is_empty():
		return
	if _local_result_visible and _route != null:
		_route.hide_combat_result()
	_local_result_visible = false
	if not _local_route_returned:
		_return_to_route_local()
	_clear_local_result_lifecycle()


func _clear_local_result_lifecycle() -> void:
	_local_result_visible = false
	_local_route_returned = false
	_local_result_occurrence_key = ""


func _reset_protocol_state() -> void:
	_interrupt_terminal_presentation()
	_phase = ProtocolPhase.IDLE
	_active_node_id = INVALID_NODE_ID
	_active_content_seed = 0
	_active_occurrence_key = ""
	_active_config_signature = ""
	_participant_peer_ids.clear()
	_entry_xirang_by_peer.clear()
	_disconnected_participants.clear()
	_reconnecting_peer_ids.clear()
	_expected_prepared_peers.clear()
	_prepared_peers.clear()
	_activate_when_prepared = false
	_local_runtime_prepared = false
	_local_runtime_activated = false
	_local_outcome_received = false
	_local_outcome_victory = false
	_local_outcome_failure_reason = ""
	_settlement_received = false
	_pending_settlement.clear()
	_settlement_scheduled = false
	_expected_terminal_peers.clear()
	_terminal_ready_peers.clear()
	_terminal_safe_received = false
	_terminal_safe_broadcast = false
	_local_terminal_finalized = false


func _interrupt_terminal_presentation() -> void:
	_terminal_sequence_serial += 1
	if _route == null or not is_instance_valid(_route):
		return
	_route.combat_victory_presentation.interrupt_and_reset()
	_route.combat_scene_transition.hide_immediately()


func _request_authoritative_abort(
	occurrence_key: String,
	reason: StringName
) -> void:
	if occurrence_key.is_empty():
		return
	if _is_host():
		_abort_authoritative_protocol(reason)
		return
	if _is_client() and _is_peer_send_ready(_get_host_peer_id()):
		net_combat_abort_requested.rpc_id(
			_get_host_peer_id(),
			occurrence_key,
			reason
		)


@rpc("any_peer", "call_remote", "reliable", 0)
func net_combat_abort_requested(
	occurrence_key: String,
	reason: StringName
) -> void:
	if (
		not _is_host()
		or occurrence_key != _active_occurrence_key
		or not _participant_peer_ids.has(multiplayer.get_remote_sender_id())
	):
		return
	_abort_authoritative_protocol(reason)


func _abort_authoritative_protocol(reason: StringName) -> void:
	if not _is_host() or _active_occurrence_key.is_empty():
		return
	var occurrence_key := _active_occurrence_key
	for peer_id_variant in _participant_peer_ids.keys():
		var peer_id := int(peer_id_variant)
		if peer_id == _get_local_peer_id() or not _is_peer_send_ready(peer_id):
			continue
		net_combat_aborted.rpc_id(peer_id, occurrence_key, reason)
	_apply_protocol_abort(occurrence_key)


@rpc("authority", "call_remote", "reliable", 0)
func net_combat_aborted(
	occurrence_key: String,
	_reason: StringName
) -> void:
	if (
		not _is_client()
		or multiplayer.get_remote_sender_id() != _get_host_peer_id()
	):
		return
	_apply_protocol_abort(occurrence_key)


func _apply_protocol_abort(occurrence_key: String) -> void:
	if (
		occurrence_key.is_empty()
		or (
			not _active_occurrence_key.is_empty()
			and occurrence_key != _active_occurrence_key
		)
	):
		return
	if _combat_network != null and is_instance_valid(_combat_network):
		_combat_network.queue_free()
	_combat_network = null
	_combat_game = null
	if _route != null and is_instance_valid(_route):
		_route.complete_normal_combat(occurrence_key)
		_route.set_route_presentation_enabled(true)
	_reset_protocol_state()


func _on_player_left(peer_id: int) -> void:
	if _phase == ProtocolPhase.IDLE or peer_id <= 0:
		return
	if not _participant_peer_ids.has(peer_id):
		return
	_disconnected_participants[peer_id] = {
		"entry_xirang": int(_entry_xirang_by_peer.get(peer_id, 0)),
		"was_prepared": _prepared_peers.has(peer_id),
		"was_terminal_ready": _terminal_ready_peers.has(peer_id),
	}
	_expected_prepared_peers.erase(peer_id)
	_prepared_peers.erase(peer_id)
	_expected_terminal_peers.erase(peer_id)
	_terminal_ready_peers.erase(peer_id)
	if _is_host():
		if _phase == ProtocolPhase.PREPARING:
			_try_activate_host_barrier()
		elif _phase == ProtocolPhase.SETTLED:
			_try_broadcast_safe_teardown()


func _on_player_joined(peer_id: int, _player_name: String) -> void:
	if (
		not _is_host()
		or peer_id <= 0
		or _participant_peer_ids.has(peer_id)
		or (
			_phase == ProtocolPhase.IDLE
			and _local_result_occurrence_key.is_empty()
		)
	):
		return
	# 战斗开始后加入者明确留在路线观战，不加入已经冻结的 barrier roster。
	_pending_spectator_peers[peer_id] = true
	call_deferred("_defer_route_spectator_sync", peer_id)


func _defer_route_spectator_sync(peer_id: int) -> void:
	call_deferred("_send_route_spectator_sync", peer_id)


func _send_route_spectator_sync(peer_id: int) -> void:
	var occurrence_key := (
		_active_occurrence_key
		if not _active_occurrence_key.is_empty()
		else _local_result_occurrence_key
	)
	if (
		not _is_host()
		or not _pending_spectator_peers.has(peer_id)
		or _reconnecting_peer_ids.has(peer_id)
		or _participant_peer_ids.has(peer_id)
		or not _is_peer_send_ready(peer_id)
		or occurrence_key.is_empty()
	):
		return
	_pending_spectator_peers.erase(peer_id)
	net_combat_route_spectator.rpc_id(peer_id, occurrence_key)


@rpc("authority", "call_remote", "reliable", 0)
func net_combat_route_spectator(occurrence_key: String) -> void:
	if (
		not _is_client()
		or multiplayer.get_remote_sender_id() != _get_host_peer_id()
		or occurrence_key.is_empty()
	):
		return
	# 不创建 MpGame，也不参与 prepare barrier；路线本身仍由房主权威锁定。
	_route.set_route_presentation_enabled(true)


func _on_player_reconnected(
	old_peer_id: int,
	new_peer_id: int,
	_player_name: String,
	_character_id: StringName
) -> void:
	_pending_spectator_peers.erase(new_peer_id)
	_reconnecting_peer_ids[new_peer_id] = true
	if _phase == ProtocolPhase.IDLE:
		if _is_host() and not _local_result_occurrence_key.is_empty():
			call_deferred(
				"_send_terminal_reconnect_spectator",
				new_peer_id,
				_local_result_occurrence_key
			)
		else:
			_reconnecting_peer_ids.erase(new_peer_id)
		return
	# MpRogueRoute 与 MpGame 也监听相同信号；延后两次，确保身份和 Player
	# 节点已先完成 old -> new 迁移。
	call_deferred(
		"_defer_finish_player_reconnected",
		old_peer_id,
		new_peer_id
	)


func _defer_finish_player_reconnected(
	old_peer_id: int,
	new_peer_id: int
) -> void:
	call_deferred(
		"_finish_player_reconnected",
		old_peer_id,
		new_peer_id
	)


func _finish_player_reconnected(old_peer_id: int, new_peer_id: int) -> void:
	if (
		_phase == ProtocolPhase.IDLE
		or old_peer_id <= 0
		or new_peer_id <= 0
		or (
			not _participant_peer_ids.has(old_peer_id)
			and not _disconnected_participants.has(old_peer_id)
		)
	):
		_reconnecting_peer_ids.erase(new_peer_id)
		return
	if _terminal_safe_broadcast:
		if _is_host():
			_send_terminal_reconnect_spectator(
				new_peer_id,
				_active_occurrence_key
			)
		_reconnecting_peer_ids.erase(new_peer_id)
		return

	_participant_peer_ids.erase(old_peer_id)
	_participant_peer_ids[new_peer_id] = true
	if _entry_xirang_by_peer.has(old_peer_id):
		_entry_xirang_by_peer[new_peer_id] = _entry_xirang_by_peer[old_peer_id]
		_entry_xirang_by_peer.erase(old_peer_id)
	elif _disconnected_participants.has(old_peer_id):
		var record := _disconnected_participants[old_peer_id] as Dictionary
		_entry_xirang_by_peer[new_peer_id] = int(
			record.get("entry_xirang", 0)
		)
	_disconnected_participants.erase(old_peer_id)
	_expected_prepared_peers.erase(old_peer_id)
	_prepared_peers.erase(old_peer_id)
	_expected_terminal_peers.erase(old_peer_id)
	_terminal_ready_peers.erase(old_peer_id)
	if _phase == ProtocolPhase.PREPARING:
		_expected_prepared_peers[new_peer_id] = true
	elif _phase == ProtocolPhase.SETTLED:
		_expected_terminal_peers[new_peer_id] = true
		_remap_pending_settlement_peer(old_peer_id, new_peer_id)
	_reconnecting_peer_ids.erase(new_peer_id)
	if not _is_host() or not _is_peer_send_ready(new_peer_id):
		return
	var activate_immediately := _phase in [
		ProtocolPhase.ACTIVE,
		ProtocolPhase.SETTLED,
	]
	net_combat_prepare.rpc_id(
		new_peer_id,
		_active_node_id,
		_active_content_seed,
		_active_occurrence_key,
		_active_config_signature,
		_pack_peer_ids(_participant_peer_ids),
		_entry_xirang_by_peer.duplicate(true),
		activate_immediately
	)
	if _settlement_received:
		net_combat_settlement.rpc_id(
			new_peer_id,
			_active_occurrence_key,
			_pending_settlement.duplicate(true)
		)


func _send_terminal_reconnect_spectator(
	peer_id: int,
	occurrence_key: String
) -> void:
	_reconnecting_peer_ids.erase(peer_id)
	if (
		not _is_host()
		or occurrence_key.is_empty()
		or not _is_peer_send_ready(peer_id)
	):
		return
	net_combat_route_spectator.rpc_id(peer_id, occurrence_key)


func _remap_pending_settlement_peer(
	old_peer_id: int,
	new_peer_id: int
) -> void:
	if _pending_settlement.is_empty():
		return
	for map_key in [
		"final_xirang_by_peer",
		"inventory_snapshots_by_peer",
		"results_by_peer",
	]:
		var peer_map := _pending_settlement.get(map_key, {}) as Dictionary
		if not peer_map.has(old_peer_id):
			continue
		var value: Variant = peer_map[old_peer_id]
		peer_map.erase(old_peer_id)
		if value is Dictionary:
			var peer_payload := (value as Dictionary).duplicate(true)
			peer_payload["peer_id"] = new_peer_id
			value = peer_payload
		peer_map[new_peer_id] = value
		_pending_settlement[map_key] = peer_map


func _capture_current_participants() -> PackedInt32Array:
	var result := PackedInt32Array()
	var connected_players := _net_manager.get("connected_players") as Dictionary
	for peer_id_variant in connected_players.keys():
		var peer_id := int(peer_id_variant)
		if peer_id > 0 and _route.get_player_for_peer(peer_id) != null:
			result.append(peer_id)
	result.sort()
	return result


func _capture_entry_xirang(peer_ids: PackedInt32Array) -> Dictionary:
	var result: Dictionary = {}
	var inherit_route_xirang := (
		encounter_config.inherit_route_xirang
		== RogueCombatEncounterConfig.Decision.YES
	)
	for peer_id in peer_ids:
		var route_player := _route.get_player_for_peer(peer_id)
		if route_player == null or not is_instance_valid(route_player):
			return {}
		result[peer_id] = (
			route_player.get_xirang()
			if inherit_route_xirang
			else STANDARD_BATTLE_XIRANG
		)
	return result


static func _apply_xirang_map_to_game(
	game: RogueCombatGame,
	xirang_by_peer: Dictionary
) -> void:
	if game == null:
		return
	for peer_id_variant in xirang_by_peer.keys():
		var peer_id := int(peer_id_variant)
		var player := game.get_player_for_peer(peer_id)
		if player == null or not is_instance_valid(player):
			continue
		var amount := maxi(int(xirang_by_peer[peer_id_variant]), 0)
		if player.current_xirang == amount:
			continue
		var delta := amount - player.current_xirang
		player.current_xirang = amount
		player.xirang_changed.emit(amount, delta)


func _apply_xirang_map_to_route(xirang_by_peer: Dictionary) -> void:
	if _route == null:
		return
	for peer_id_variant in xirang_by_peer.keys():
		var peer_id := int(peer_id_variant)
		var player := _route.get_player_for_peer(peer_id)
		if player == null or not is_instance_valid(player):
			continue
		var amount := maxi(int(xirang_by_peer[peer_id_variant]), 0)
		if player.current_xirang == amount:
			continue
		var delta := amount - player.current_xirang
		player.current_xirang = amount
		player.xirang_changed.emit(amount, delta)


func _validate_authoritative_peer_maps(
	xirang_by_peer: Dictionary,
	inventory_snapshots_by_peer: Dictionary,
	results_by_peer: Dictionary
) -> bool:
	if (
		xirang_by_peer.size() != _participant_peer_ids.size()
		or inventory_snapshots_by_peer.size() != _participant_peer_ids.size()
		or results_by_peer.size() != _participant_peer_ids.size()
	):
		return false
	for peer_id_variant in _participant_peer_ids.keys():
		var peer_id := int(peer_id_variant)
		if (
			peer_id <= 0
			or not xirang_by_peer.has(peer_id)
			or int(xirang_by_peer[peer_id]) < 0
			or not inventory_snapshots_by_peer.has(peer_id)
			or not inventory_snapshots_by_peer[peer_id] is Dictionary
			or not results_by_peer.has(peer_id)
			or not results_by_peer[peer_id] is Dictionary
		):
			return false
		var snapshot := inventory_snapshots_by_peer[peer_id] as Dictionary
		if int(snapshot.get("peer_id", -1)) != peer_id:
			return false
	return true


func _make_unrewarded_victory_result(peer_id: int) -> Dictionary:
	return {
		"victory": true,
		"occurrence_id": _active_occurrence_key,
		"content_seed": _active_content_seed,
		"peer_id": peer_id,
		"extra_xirang": 0,
		"loot": {
			"config_path": "",
			"id": "",
			"name": "",
			"rarity": -1,
			"rarity_name": "",
			"granted": false,
			"failure_reason": &"player_dead_not_rewarded",
		},
	}


static func _make_config_signature(
	config: RogueCombatEncounterConfig
) -> String:
	if config == null or config.campaign == null:
		return ""
	return "%s|%s|%s|%d|%d|%d|%d|%d|%d|%d|%d|%d|%d|%d|%d|%d|%d|%d|%d" % [
		String(config.encounter_id),
		config.combat_scene_path,
		String(config.campaign.campaign_id),
		config.preparation_seconds,
		config.combat_limit_seconds,
		config.enemy_count,
		config.extra_xirang,
		int(config.deadline_start),
		config.spawn_point_mask,
		config.spawn_count_per_tick,
		int(config.keep_enemy_kill_xirang),
		int(config.filter_loot_by_character),
		int(config.reward_dead_players_on_victory),
		int(config.return_to_route_before_result),
		int(config.show_failure_result),
		int(config.consume_node_on_failure),
		int(config.enemy_pickup_drops),
		int(config.inherit_route_xirang),
		int(config.support_multiplayer),
	]


static func _index_peer_ids(peer_ids: PackedInt32Array) -> Dictionary:
	var result: Dictionary = {}
	for peer_id in peer_ids:
		if peer_id > 0:
			result[peer_id] = true
	return result


static func _pack_peer_ids(peer_id_index: Dictionary) -> PackedInt32Array:
	var result := PackedInt32Array()
	for peer_id_variant in peer_id_index.keys():
		var peer_id := int(peer_id_variant)
		if peer_id > 0:
			result.append(peer_id)
	result.sort()
	return result


static func _contains_all_keys(values: Dictionary, expected: Dictionary) -> bool:
	for key in expected.keys():
		if not values.has(key):
			return false
	return true


func _get_host_peer_id() -> int:
	if _net_manager != null and _net_manager.has_method("get_host_peer_id"):
		return int(_net_manager.call("get_host_peer_id"))
	return 0


func _get_local_peer_id() -> int:
	if _net_manager != null and _net_manager.has_method("get_local_peer_id"):
		var local_peer_id := int(_net_manager.call("get_local_peer_id"))
		if local_peer_id > 0:
			return local_peer_id
	return _get_host_peer_id() if _is_host() else 0


func _is_host() -> bool:
	return (
		_net_manager != null
		and _net_manager.has_method("is_host")
		and bool(_net_manager.call("is_host"))
	)


func _is_client() -> bool:
	return (
		_net_manager != null
		and _net_manager.has_method("is_client")
		and bool(_net_manager.call("is_client"))
	)


func _is_peer_send_ready(peer_id: int) -> bool:
	return (
		_net_manager != null
		and peer_id > 0
		and _net_manager.has_method("is_peer_send_ready")
		and bool(_net_manager.call("is_peer_send_ready", peer_id))
	)
