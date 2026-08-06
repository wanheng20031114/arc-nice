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
const PREPARE_BARRIER_TIMEOUT_MSEC := 30_000
const RECONNECT_ACTIVATION_TIMEOUT_MSEC := 15_000
const TERMINAL_BARRIER_TIMEOUT_MSEC := 15_000
const TERMINAL_SPECTATOR_SYNC_TIMEOUT_MSEC := 30_000
const CLIENT_PREPARATION_ABORT_REASONS := {
	&"local_config_disabled": true,
	&"config_mismatch": true,
	&"route_start_rejected": true,
	&"runtime_create_failed": true,
	&"runtime_config_failed": true,
	&"client_runtime_activate_failed": true,
	&"entry_reveal_failed": true,
	&"runtime_activate_failed": true,
}

enum ProtocolPhase {
	IDLE,
	PREPARING,
	ACTIVE,
	SETTLED,
}

@export var encounter_config: RogueCombatEncounterConfig = (
	DEFAULT_ENCOUNTER_CONFIG
)

var _route: RogueRouteGame = null
var _net_manager: NetManagerStore = null
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
var _pending_reconnect_prepare_peers: Dictionary = {}
var _pending_terminal_spectator_syncs: Dictionary = {}
var _route_spectator_occurrence_key := ""

var _expected_prepared_peers: Dictionary = {}
var _prepared_peers: Dictionary = {}
var _activate_when_prepared := false
var _activation_dispatch_started := false
var _local_runtime_prepared := false
var _local_runtime_activated := false
var _local_activation_requested := false
var _prepare_barrier_deadline_msec := 0

var _combat_network: MultiplayerGameplaySession = null
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
var _terminal_barrier_deadline_msec := 0

var _local_result_visible := false
var _local_route_returned := false
var _local_result_occurrence_key := ""
var _local_terminal_finalized := false
var _consumed_node_ids: Dictionary = {}
var _terminal_sequence_serial := 0


func bind_network_dependencies(
	route_instance: RogueRouteGame,
	net_manager_instance: NetManagerStore,
	run_state_instance: RunStateStore
) -> void:
	assert(route_instance != null, "肉鸽作战协调器缺少路线运行时。")
	assert(net_manager_instance != null, "肉鸽作战协调器缺少 NetManagerStore。")
	assert(run_state_instance != null, "肉鸽作战协调器缺少 RunStateStore。")
	assert(
		_route == null or _route == route_instance,
		"肉鸽作战协调器不得在会话中途更换路线运行时。"
	)
	assert(
		_net_manager == null or _net_manager == net_manager_instance,
		"肉鸽作战协调器不得在会话中途更换网络管理器。"
	)
	assert(
		_run_state == null or _run_state == run_state_instance,
		"肉鸽作战协调器不得在会话中途更换 RunState。"
	)
	_route = route_instance
	_net_manager = net_manager_instance
	_run_state = run_state_instance
	_enabled = (
		is_config_enabled_for_multiplayer(encounter_config)
	)
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


func _physics_process(_delta: float) -> void:
	if not _enabled or not _is_host():
		return
	var now_msec := Time.get_ticks_msec()
	_poll_pending_terminal_spectator_syncs(now_msec)
	if _phase == ProtocolPhase.IDLE:
		return
	_poll_prepare_barrier_timeout(now_msec)
	_poll_reconnect_activation_timeouts(now_msec)
	_poll_terminal_barrier_timeout(now_msec)


func _poll_prepare_barrier_timeout(now_msec: int = -1) -> void:
	var now := Time.get_ticks_msec() if now_msec < 0 else now_msec
	if (
		not _is_host()
		or _phase != ProtocolPhase.PREPARING
		or _activation_dispatch_started
		or _prepare_barrier_deadline_msec <= 0
		or now < _prepare_barrier_deadline_msec
	):
		return
	_prepare_barrier_deadline_msec = 0
	_abort_authoritative_protocol(&"prepare_barrier_timeout")


func _poll_reconnect_activation_timeouts(now_msec: int = -1) -> void:
	if (
		not _is_host()
		or not (
			_phase == ProtocolPhase.ACTIVE
			or (
				_phase == ProtocolPhase.PREPARING
				and _activation_dispatch_started
			)
		)
	):
		return
	var now := Time.get_ticks_msec() if now_msec < 0 else now_msec
	var timed_out_peer_ids: Array[int] = []
	for peer_id_variant in _pending_reconnect_prepare_peers.keys():
		var pending := (
			_pending_reconnect_prepare_peers[peer_id_variant] as Dictionary
		)
		var deadline_msec := int(pending.get("deadline_msec", 0))
		if deadline_msec > 0 and now >= deadline_msec:
			timed_out_peer_ids.append(int(peer_id_variant))
	for peer_id in timed_out_peer_ids:
		_downgrade_pending_reconnect_to_spectator(
			peer_id,
			&"reconnect_activation_timeout"
		)


func _poll_terminal_barrier_timeout(now_msec: int = -1) -> void:
	var now := Time.get_ticks_msec() if now_msec < 0 else now_msec
	if (
		not _is_host()
		or _phase != ProtocolPhase.SETTLED
		or _terminal_barrier_deadline_msec <= 0
		or now < _terminal_barrier_deadline_msec
	):
		return
	_terminal_barrier_deadline_msec = 0
	var occurrence_key := _active_occurrence_key
	var local_peer_id := _get_local_peer_id()
	var timed_out_peer_ids: Array[int] = []
	for peer_id_variant in _expected_terminal_peers.keys():
		var peer_id := int(peer_id_variant)
		if not _terminal_ready_peers.has(peer_id):
			timed_out_peer_ids.append(peer_id)
	for peer_id in timed_out_peer_ids:
		if peer_id == local_peer_id:
			_interrupt_terminal_presentation()
			if _local_result_occurrence_key.is_empty():
				_local_result_occurrence_key = occurrence_key
			_return_to_route_local()
			if not _show_local_result():
				_clear_local_result_lifecycle()
			_terminal_ready_peers[peer_id] = true
			continue
		_mark_participant_disconnected_from_barriers(peer_id)
		if _combat_network != null and is_instance_valid(_combat_network):
			_combat_network.suspend_embedded_participant_for_current_combat(
				peer_id
			)
		_send_terminal_reconnect_spectator(peer_id, occurrence_key)
	_try_broadcast_safe_teardown()


func _poll_pending_terminal_spectator_syncs(
	now_msec: int = -1
) -> void:
	if not _is_host() or _pending_terminal_spectator_syncs.is_empty():
		return
	var now := Time.get_ticks_msec() if now_msec < 0 else now_msec
	for peer_id_variant in _pending_terminal_spectator_syncs.keys():
		var peer_id := int(peer_id_variant)
		var pending := (
			_pending_terminal_spectator_syncs.get(peer_id, {}) as Dictionary
		)
		var expires_msec := int(pending.get("expires_msec", 0))
		if expires_msec > 0 and now >= expires_msec:
			_pending_terminal_spectator_syncs.erase(peer_id)
			push_warning((
				"RogueCombatMultiplayerCoordinator: peer %d 的路线观战结算同步"
				+ "等待 send-ready 超时，交由后续路线权威快照收敛。"
			) % peer_id)
			continue
		_flush_pending_terminal_spectator_sync(peer_id)


func _discard_pending_terminal_spectator_syncs_except(
	occurrence_key: String
) -> void:
	for peer_id_variant in _pending_terminal_spectator_syncs.keys():
		var pending := (
			_pending_terminal_spectator_syncs[peer_id_variant] as Dictionary
		)
		if str(pending.get("occurrence_key", "")) != occurrence_key:
			_pending_terminal_spectator_syncs.erase(peer_id_variant)


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
	# Node ids and occurrence keys are scoped to one generated layout. A newly
	# committed route must not inherit either idempotency cache; otherwise a
	# deterministic key reused by a later run could be mistaken for an old result.
	if _phase == ProtocolPhase.IDLE:
		_consumed_node_ids.clear()
		_settled_occurrences.clear()


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
		_route.abort_briefing_entry(occurrence_key)
		for peer_id in _capture_current_participants():
			if (
				peer_id == _get_local_peer_id()
				or not _is_peer_send_ready(peer_id)
			):
				continue
			net_combat_route_spectator.rpc_id(peer_id, occurrence_key)
		_route.complete_normal_combat(occurrence_key)
		return

	var participants := _capture_current_participants()
	if participants.is_empty():
		_route.abort_briefing_entry(occurrence_key)
		_route.complete_normal_combat(occurrence_key)
		return
	var entry_xirang := _capture_entry_xirang(participants)
	if entry_xirang.size() != participants.size():
		push_error("RogueCombatMultiplayerCoordinator: 无法捕获完整入口息壤。")
		_route.abort_briefing_entry(occurrence_key)
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
	_discard_pending_terminal_spectator_syncs_except(occurrence_key)
	_resolve_stale_local_result_before_prepare()
	_route_spectator_occurrence_key = ""
	_active_node_id = node_id
	_active_content_seed = content_seed
	_active_occurrence_key = occurrence_key
	_active_config_signature = _make_config_signature(encounter_config)
	_participant_peer_ids = _index_peer_ids(participant_peer_ids)
	_entry_xirang_by_peer = entry_xirang_by_peer.duplicate(true)
	_disconnected_participants.clear()
	_pending_reconnect_prepare_peers.clear()
	_expected_prepared_peers = _participant_peer_ids.duplicate()
	_prepared_peers.clear()
	_activate_when_prepared = activate_when_prepared
	_activation_dispatch_started = activate_when_prepared
	_local_runtime_prepared = false
	_local_runtime_activated = false
	_local_activation_requested = false
	_prepare_barrier_deadline_msec = (
		Time.get_ticks_msec() + PREPARE_BARRIER_TIMEOUT_MSEC
	)
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
			_request_local_runtime_activation()
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
	var raw_instance := MP_GAME_SCENE.instantiate()
	var instance := raw_instance as MultiplayerGameplaySession
	if instance == null:
		push_error(
			"RogueCombatMultiplayerCoordinator: MpGame 未实现 MultiplayerGameplaySession。"
		)
		if raw_instance != null:
			raw_instance.free()
		return false
	instance.name = COMBAT_RUNTIME_NODE_NAME
	instance.embedded_runtime = true
	if not instance.configure_embedded_participant_roster(
		_pack_peer_ids(_participant_peer_ids)
	):
		push_error(
			"RogueCombatMultiplayerCoordinator: 无法冻结内嵌战斗参战名单。"
		)
		instance.free()
		return false
	instance.runtime_scene_path_override = encounter_config.combat_scene_path
	if not instance.embedded_runtime_prepared.is_connected(
		_on_embedded_runtime_prepared
	):
		instance.embedded_runtime_prepared.connect(
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
	elif (
		_is_client()
		and not _activate_when_prepared
		and _is_peer_send_ready(_get_host_peer_id())
	):
		net_combat_prepared.rpc_id(
			_get_host_peer_id(),
			_active_occurrence_key
		)
	if _activate_when_prepared:
		if not _request_local_runtime_activation():
			if _is_host():
				_abort_authoritative_protocol(&"runtime_activate_failed")
			else:
				_request_authoritative_abort(
					_active_occurrence_key,
					&"runtime_activate_failed"
				)


func _configure_occurrence_runtime() -> bool:
	if _combat_network == null or not is_instance_valid(_combat_network):
		return false
	var game_runtime := _combat_network.get_game_runtime()
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
	_accept_combat_prepared(
		multiplayer.get_remote_sender_id(),
		occurrence_key
	)


func _accept_combat_prepared(sender_id: int, occurrence_key: String) -> void:
	if (
		not _is_host()
		or sender_id <= 0
		or _phase != ProtocolPhase.PREPARING
		or occurrence_key != _active_occurrence_key
		or not _expected_prepared_peers.has(sender_id)
		or _prepared_peers.has(sender_id)
	):
		return
	_prepared_peers[sender_id] = true
	_try_activate_host_barrier()


@rpc("any_peer", "call_remote", "reliable", 0)
func net_combat_activated(occurrence_key: String) -> void:
	_accept_combat_activated(
		multiplayer.get_remote_sender_id(),
		occurrence_key
	)


func _accept_combat_activated(sender_id: int, occurrence_key: String) -> void:
	if (
		not _is_host()
		or sender_id <= 0
		or occurrence_key != _active_occurrence_key
		or not _is_pending_reconnect_prepare(sender_id, occurrence_key)
		or not (
			_phase in [ProtocolPhase.ACTIVE, ProtocolPhase.SETTLED]
			or (
				_phase == ProtocolPhase.PREPARING
				and _activation_dispatch_started
			)
		)
	):
		return
	_pending_reconnect_prepare_peers.erase(sender_id)


func _try_activate_host_barrier() -> void:
	if (
		not _is_host()
		or _phase != ProtocolPhase.PREPARING
		or _activation_dispatch_started
		or not _local_runtime_prepared
		or not _contains_all_keys(
			_prepared_peers,
			_expected_prepared_peers
		)
	):
		return
	_activation_dispatch_started = true
	_activate_when_prepared = true
	_prepare_barrier_deadline_msec = 0
	var reconnect_deadline := (
		Time.get_ticks_msec() + RECONNECT_ACTIVATION_TIMEOUT_MSEC
	)
	for peer_id_variant in _pending_reconnect_prepare_peers.keys():
		var pending := (
			_pending_reconnect_prepare_peers[peer_id_variant] as Dictionary
		)
		pending["deadline_msec"] = reconnect_deadline
	for peer_id_variant in _participant_peer_ids.keys():
		var peer_id := int(peer_id_variant)
		if peer_id == _get_local_peer_id() or not _is_peer_send_ready(peer_id):
			continue
		net_combat_activate.rpc_id(peer_id, _active_occurrence_key)
	if not _request_local_runtime_activation():
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
	_activation_dispatch_started = true
	_activate_when_prepared = true
	if _local_runtime_prepared:
		if not _request_local_runtime_activation():
			_request_authoritative_abort(
				_active_occurrence_key,
				&"client_runtime_activate_failed"
			)


func _request_local_runtime_activation() -> bool:
	if _local_runtime_activated or _local_activation_requested:
		return true
	if (
		_phase != ProtocolPhase.PREPARING
		or not _local_runtime_prepared
		or _active_occurrence_key.is_empty()
	):
		return false
	_local_activation_requested = true
	call_deferred(
		&"_activate_local_runtime_after_entry_reveal",
		_active_occurrence_key
	)
	return true


func _activate_local_runtime_after_entry_reveal(
	occurrence_key: String
) -> void:
	var revealed := await _route.reveal_normal_combat_entry(occurrence_key)
	if (
		_phase != ProtocolPhase.PREPARING
		or occurrence_key != _active_occurrence_key
		or not _local_activation_requested
	):
		return
	_local_activation_requested = false
	if not revealed:
		_request_authoritative_abort(
			occurrence_key,
			&"entry_reveal_failed"
		)
		return
	if _is_host():
		_route.complete_briefing_entry(occurrence_key)
	if not _activate_local_runtime():
		_request_authoritative_abort(
			occurrence_key,
			&"runtime_activate_failed"
		)


func _activate_local_runtime() -> bool:
	if (
		_local_runtime_activated
		or _phase != ProtocolPhase.PREPARING
		or _settlement_received
		or not _local_runtime_prepared
		or _combat_network == null
		or not is_instance_valid(_combat_network)
	):
		return false
	if not _combat_network.activate_embedded_runtime():
		return false
	_local_runtime_activated = true
	_phase = ProtocolPhase.ACTIVE
	# PREPARED and ACTIVATED are distinct idempotent protocol stages. Reusing one
	# acknowledgement would let a duplicated PREPARED packet close the reconnect
	# failure window before entry reveal and runtime activation actually finish.
	if _is_client() and _is_peer_send_ready(_get_host_peer_id()):
		net_combat_activated.rpc_id(
			_get_host_peer_id(),
			_active_occurrence_key
		)
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
	var reward_rollback_state := _capture_host_reward_rollback_state()
	if reward_rollback_state.is_empty():
		push_error(
			"RogueCombatMultiplayerCoordinator: 无法捕获结算前奖励状态，已中止结算。"
		)
		_abort_authoritative_protocol(&"reward_rollback_capture_failed")
		return
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
	if not _publish_host_settlement(
		occurrence_key,
		settlement,
		reward_rollback_state
	):
		push_error(
			"RogueCombatMultiplayerCoordinator: Host 本地结算提交失败，已阻止向客户端发布。"
		)


func _publish_host_settlement(
	occurrence_key: String,
	settlement: Dictionary,
	reward_rollback_state: Dictionary = {}
) -> bool:
	if (
		not _is_host()
		or occurrence_key.is_empty()
		or occurrence_key != _active_occurrence_key
		or _settled_occurrences.has(occurrence_key)
		or str(settlement.get("occurrence_key", "")) != occurrence_key
	):
		return false
	# Host is the transaction coordinator: no remote peer may observe settlement
	# until the authoritative local validation and ledger commit have succeeded.
	# The idempotency tombstone is likewise written only after that commit, so a
	# local failure cannot both split the party and suppress recovery. Reward
	# generation mutates the Host inventory and Player Xirang before this point;
	# restore those values with a new monotonic inventory revision before returning
	# to the route, otherwise retrying the unconsumed node could duplicate rewards.
	if not _commit_host_settlement_locally(settlement):
		if (
			not reward_rollback_state.is_empty()
			and not _rollback_host_reward_mutations(reward_rollback_state)
		):
			push_error(
				"RogueCombatMultiplayerCoordinator: Host 结算失败后的奖励回滚失败。"
			)
		_abort_authoritative_protocol(&"settlement_commit_failed")
		return false
	_settled_occurrences[occurrence_key] = true
	_downgrade_pending_reconnects_before_settlement_broadcast(
		occurrence_key
	)
	_broadcast_authoritative_settlement(occurrence_key, settlement)
	_try_broadcast_safe_teardown()
	return true


func _capture_host_reward_rollback_state() -> Dictionary:
	if not _is_host() or _run_state == null or _participant_peer_ids.is_empty():
		return {}
	var inventory_snapshots_by_peer: Dictionary = {}
	var combat_xirang_by_peer: Dictionary = {}
	for peer_id_variant in _participant_peer_ids.keys():
		if typeof(peer_id_variant) != TYPE_INT:
			return {}
		var peer_id := int(peer_id_variant)
		if peer_id <= 0:
			return {}
		var snapshot := _run_state.export_inventory_snapshot_for_peer(peer_id)
		if snapshot.is_empty():
			return {}
		inventory_snapshots_by_peer[peer_id] = snapshot.duplicate(true)
		if _combat_game == null or not is_instance_valid(_combat_game):
			continue
		var player := _combat_game.get_player_for_peer(peer_id)
		if player != null and is_instance_valid(player):
			combat_xirang_by_peer[peer_id] = player.get_xirang()
	return {
		"inventory_snapshots_by_peer": inventory_snapshots_by_peer,
		"combat_xirang_by_peer": combat_xirang_by_peer,
	}


func _rollback_host_reward_mutations(rollback_state: Dictionary) -> bool:
	if (
		not _is_host()
		or _run_state == null
		or typeof(rollback_state.get("inventory_snapshots_by_peer"))
		!= TYPE_DICTIONARY
		or typeof(rollback_state.get("combat_xirang_by_peer"))
		!= TYPE_DICTIONARY
	):
		return false
	var snapshots := (
		rollback_state["inventory_snapshots_by_peer"] as Dictionary
	)
	if snapshots.size() != _participant_peer_ids.size():
		return false

	# Prepare every rollback first. Each restored inventory advances from the
	# reward revision to reward_revision + 1, so observers never see revision time
	# move backwards even though the pre-reward contents are restored.
	var prepared_rollbacks: Dictionary = {}
	for peer_id_variant in _participant_peer_ids.keys():
		var peer_id := int(peer_id_variant)
		if (
			typeof(peer_id_variant) != TYPE_INT
			or peer_id <= 0
			or not snapshots.has(peer_id)
			or not snapshots[peer_id] is Dictionary
		):
			return false
		var rollback_snapshot := (
			(snapshots[peer_id] as Dictionary).duplicate(true)
		)
		var rollback_revision := (
			_run_state.get_inventory_revision_for_peer(peer_id) + 1
		)
		rollback_snapshot["revision"] = rollback_revision
		var slots := rollback_snapshot.get("slots", []) as Array
		if slots.size() != RunStateStore.INVENTORY_CAPACITY:
			return false
		for slot_variant in slots:
			if not slot_variant is Dictionary:
				return false
			(slot_variant as Dictionary)["revision"] = rollback_revision
		var prepared := _run_state.prepare_inventory_snapshot_for_peer(
			peer_id,
			rollback_snapshot
		)
		if prepared.is_empty():
			return false
		prepared_rollbacks[peer_id] = prepared

	for peer_id_variant in _participant_peer_ids.keys():
		var peer_id := int(peer_id_variant)
		if not _run_state.commit_prepared_inventory_snapshot_for_peer(
			prepared_rollbacks[peer_id] as Dictionary,
			false
		):
			return false
	_run_state.notify_inventory_snapshot_committed()
	_apply_xirang_map_to_game(
		_combat_game,
		rollback_state["combat_xirang_by_peer"] as Dictionary
	)
	return true


func _downgrade_pending_reconnects_before_settlement_broadcast(
	occurrence_key: String
) -> void:
	if (
		not _is_host()
		or not _settlement_received
		or occurrence_key.is_empty()
		or occurrence_key != _active_occurrence_key
		or _pending_reconnect_prepare_peers.is_empty()
	):
		return
	var pending_peer_ids: Array[int] = []
	for peer_id_variant in _pending_reconnect_prepare_peers.keys():
		pending_peer_ids.append(int(peer_id_variant))
	pending_peer_ids.sort()
	for peer_id in pending_peer_ids:
		if not _is_pending_reconnect_prepare(peer_id, occurrence_key):
			_pending_reconnect_prepare_peers.erase(peer_id)
			continue
		_mark_participant_disconnected_from_barriers(peer_id)
		if _combat_network != null and is_instance_valid(_combat_network):
			_combat_network.suspend_embedded_participant_for_current_combat(
				peer_id
			)
		_pending_reconnect_prepare_peers.erase(peer_id)
		_pending_spectator_peers.erase(peer_id)
		_send_terminal_reconnect_spectator(peer_id, occurrence_key)
	# The caller tests the terminal barrier only after the ordinary participant
	# settlement broadcast, so safe-to-teardown can never overtake settlement.


func _commit_host_settlement_locally(settlement: Dictionary) -> bool:
	return _apply_settlement(settlement)


func _broadcast_authoritative_settlement(
	occurrence_key: String,
	settlement: Dictionary
) -> void:
	for peer_id_variant in _participant_peer_ids.keys():
		var peer_id := int(peer_id_variant)
		if (
			peer_id == _get_local_peer_id()
			or _disconnected_participants.has(peer_id)
			or not _is_peer_send_ready(peer_id)
		):
			continue
		net_combat_settlement.rpc_id(
			peer_id,
			occurrence_key,
			settlement.duplicate(true)
		)


@rpc("authority", "call_remote", "reliable", 0)
func net_combat_settlement(
	occurrence_key: String,
	settlement: Dictionary
) -> void:
	if (
		not _is_client()
		or multiplayer.get_remote_sender_id() != _get_host_peer_id()
	):
		return
	if occurrence_key == _active_occurrence_key:
		_apply_settlement(settlement)
		return
	if occurrence_key == _route_spectator_occurrence_key:
		_apply_route_spectator_settlement(occurrence_key, settlement)


func _apply_route_spectator_settlement(
	occurrence_key: String,
	settlement: Dictionary
) -> bool:
	if (
		occurrence_key.is_empty()
		or occurrence_key != _route_spectator_occurrence_key
		or str(settlement.get("occurrence_key", "")) != occurrence_key
		or typeof(settlement.get("consume_node")) != TYPE_BOOL
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
	var local_peer_id := _get_local_peer_id()
	if (
		local_peer_id <= 0
		or final_xirang.is_empty()
		or final_xirang.size() != inventory_snapshots.size()
		or final_xirang.size() != results.size()
		or not final_xirang.has(local_peer_id)
		or not inventory_snapshots.has(local_peer_id)
	):
		return false

	for peer_id_variant in final_xirang.keys():
		var peer_id := int(peer_id_variant)
		if (
			typeof(peer_id_variant) != TYPE_INT
			or peer_id <= 0
			or typeof(final_xirang[peer_id_variant]) != TYPE_INT
			or int(final_xirang[peer_id_variant]) < 0
			or not inventory_snapshots.has(peer_id)
			or not inventory_snapshots[peer_id] is Dictionary
			or not results.has(peer_id)
			or not results[peer_id] is Dictionary
		):
			return false
		var snapshot := inventory_snapshots[peer_id] as Dictionary
		if int(snapshot.get("peer_id", -1)) != peer_id:
			return false
	if not _apply_authoritative_settlement_economy(
		final_xirang,
		inventory_snapshots
	):
		return false
	_apply_xirang_map_to_route(final_xirang)
	if bool(settlement["consume_node"]):
		var node_id := int(settlement.get("node_id", INVALID_NODE_ID))
		if node_id >= 0:
			_consumed_node_ids[node_id] = true
	_route.complete_normal_combat(occurrence_key)
	_route.set_route_presentation_enabled(true)
	_route_spectator_occurrence_key = ""
	return true


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

	if not _apply_authoritative_settlement_economy(
		final_xirang,
		inventory_snapshots
	):
		return false
	_apply_xirang_map_to_game(_combat_game, final_xirang)
	_apply_xirang_map_to_route(final_xirang)
	if bool(settlement.get("consume_node", false)):
		_consumed_node_ids[int(settlement.get("node_id", INVALID_NODE_ID))] = true

	_pending_settlement = settlement.duplicate(true)
	_settlement_received = true
	_phase = ProtocolPhase.SETTLED
	_expected_terminal_peers = _participant_peer_ids.duplicate()
	for disconnected_peer_id in _disconnected_participants.keys():
		_expected_terminal_peers.erase(disconnected_peer_id)
	if _is_host():
		_terminal_barrier_deadline_msec = (
			Time.get_ticks_msec() + TERMINAL_BARRIER_TIMEOUT_MSEC
		)
	_try_finalize_local_terminal()
	return true


func _apply_authoritative_settlement_economy(
	final_xirang: Dictionary,
	inventory_snapshots: Dictionary
) -> bool:
	if not _is_host():
		# Preflight every peer snapshot before publishing any inventory signal.
		# This prevents malformed Host data from exposing a half-updated party.
		var prepared_snapshots: Dictionary = {}
		for peer_id_variant in inventory_snapshots.keys():
			var peer_id := int(peer_id_variant)
			var snapshot := inventory_snapshots[peer_id_variant] as Dictionary
			var prepared := _run_state.prepare_inventory_snapshot_for_peer(
				peer_id,
				snapshot,
				true
			)
			if prepared.is_empty():
				return false
			prepared_snapshots[peer_id] = prepared
		for peer_id_variant in prepared_snapshots.keys():
			if not _run_state.commit_prepared_inventory_snapshot_for_peer(
				prepared_snapshots[peer_id_variant] as Dictionary,
				false
			):
				push_error(
					"RogueCombatMultiplayerCoordinator: 结算背包提交失去原子性。"
				)
				return false
		_run_state.notify_inventory_snapshot_committed()
	return _run_state.set_party_xirang_balances(final_xirang)


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
		# A local presentation failure is not an authoritative combat failure.
		# Mark this peer terminal-ready so it cannot hold the Host barrier, then
		# clean up only this client's interrupted result flow.
		if _is_peer_send_ready(_get_host_peer_id()):
			net_combat_terminal_ready.rpc_id(
				_get_host_peer_id(),
				occurrence_key
			)
	_apply_protocol_abort(occurrence_key)


func _on_route_normal_combat_stage_reset(occurrence_key: String) -> void:
	if (
		not occurrence_key.is_empty()
		and occurrence_key == _route_spectator_occurrence_key
	):
		_route_spectator_occurrence_key = ""
		return
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
	if (
		not _expected_terminal_peers.has(sender_id)
		or _terminal_ready_peers.has(sender_id)
	):
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
	_terminal_barrier_deadline_msec = 0
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
	if _combat_network != null and is_instance_valid(_combat_network):
		_combat_network.visible = visible


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
	_pending_reconnect_prepare_peers.clear()
	_expected_prepared_peers.clear()
	_prepared_peers.clear()
	_activate_when_prepared = false
	_activation_dispatch_started = false
	_local_runtime_prepared = false
	_local_runtime_activated = false
	_local_activation_requested = false
	_prepare_barrier_deadline_msec = 0
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
	_terminal_barrier_deadline_msec = 0
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
	var sender_id := multiplayer.get_remote_sender_id()
	if _can_accept_client_abort_request(sender_id, occurrence_key, reason):
		_abort_authoritative_protocol(reason)
		return
	if _can_withdraw_failed_runtime_participant(
		sender_id,
		occurrence_key,
		reason
	):
		_withdraw_failed_runtime_participant(sender_id, occurrence_key, reason)


func _can_accept_client_abort_request(
	sender_id: int,
	occurrence_key: String,
	reason: StringName
) -> bool:
	return (
		_is_host()
		and _phase == ProtocolPhase.PREPARING
		and not _activation_dispatch_started
		and occurrence_key == _active_occurrence_key
		and _participant_peer_ids.has(sender_id)
		and CLIENT_PREPARATION_ABORT_REASONS.has(reason)
	)


func _can_withdraw_failed_runtime_participant(
	sender_id: int,
	occurrence_key: String,
	reason: StringName
) -> bool:
	return (
		_is_host()
		and occurrence_key == _active_occurrence_key
		and _participant_peer_ids.has(sender_id)
		and _is_pending_reconnect_prepare(sender_id, occurrence_key)
		and CLIENT_PREPARATION_ABORT_REASONS.has(reason)
		and (
			_phase in [ProtocolPhase.ACTIVE, ProtocolPhase.SETTLED]
			or (
				_phase == ProtocolPhase.PREPARING
				and _activation_dispatch_started
			)
		)
	)


func _is_pending_reconnect_prepare(
	peer_id: int,
	occurrence_key: String
) -> bool:
	var pending := (
		_pending_reconnect_prepare_peers.get(peer_id, {}) as Dictionary
	)
	return (
		peer_id > 0
		and not occurrence_key.is_empty()
		and str(pending.get("occurrence_key", "")) == occurrence_key
	)


func _withdraw_failed_runtime_participant(
	peer_id: int,
	occurrence_key: String,
	reason: StringName
) -> void:
	if not _can_withdraw_failed_runtime_participant(
		peer_id,
		occurrence_key,
		reason
	):
		return
	_downgrade_pending_reconnect_to_spectator(peer_id, reason)


func _downgrade_pending_reconnect_to_spectator(
	peer_id: int,
	reason: StringName
) -> void:
	if (
		not _is_host()
		or peer_id <= 0
		or not _participant_peer_ids.has(peer_id)
		or not _is_pending_reconnect_prepare(
			peer_id,
			_active_occurrence_key
		)
	):
		return
	var occurrence_key := _active_occurrence_key
	# A late reconnect failure belongs to this participant, not the already
	# running authoritative battle. Treat it like a combat-only disconnect while
	# keeping the peer connected to the route as a spectator.
	_on_player_left(peer_id)
	if _combat_network != null and is_instance_valid(_combat_network):
		_combat_network.suspend_embedded_participant_for_current_combat(
			peer_id
		)
	push_warning((
		"RogueCombatMultiplayerCoordinator: peer %d 战斗运行时恢复失败"
		+ "（%s），已降级为路线观战。"
	) % [peer_id, reason])
	_pending_reconnect_prepare_peers.erase(peer_id)
	_send_terminal_reconnect_spectator(peer_id, occurrence_key)


func _abort_authoritative_protocol(reason: StringName) -> void:
	if not _is_host() or _active_occurrence_key.is_empty():
		return
	var occurrence_key := _active_occurrence_key
	_route.abort_briefing_entry(occurrence_key)
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
		_route.abort_briefing_entry(occurrence_key)
		_route.complete_normal_combat(occurrence_key)
		_route.set_route_presentation_enabled(true)
	_reset_protocol_state()


func _on_player_left(peer_id: int) -> void:
	_pending_spectator_peers.erase(peer_id)
	_pending_terminal_spectator_syncs.erase(peer_id)
	if _phase == ProtocolPhase.IDLE or peer_id <= 0:
		return
	_pending_reconnect_prepare_peers.erase(peer_id)
	if not _participant_peer_ids.has(peer_id):
		return
	_mark_participant_disconnected_from_barriers(peer_id)
	if _is_host():
		if _phase == ProtocolPhase.PREPARING:
			_try_activate_host_barrier()
		elif _phase == ProtocolPhase.SETTLED:
			_try_broadcast_safe_teardown()


func _mark_participant_disconnected_from_barriers(peer_id: int) -> void:
	if peer_id <= 0 or not _participant_peer_ids.has(peer_id):
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
	if (
		_phase != ProtocolPhase.IDLE
		and occurrence_key == _active_occurrence_key
	):
		_release_local_combat_to_route_spectator(occurrence_key)
		return
	_route_spectator_occurrence_key = occurrence_key
	_route.hide_combat_entry_transition()
	_route.set_route_presentation_enabled(true)


func _release_local_combat_to_route_spectator(occurrence_key: String) -> void:
	if (
		occurrence_key.is_empty()
		or occurrence_key != _active_occurrence_key
	):
		return
	if _combat_network != null and is_instance_valid(_combat_network):
		_combat_network.queue_free()
	var received_settlement := (
		_pending_settlement.duplicate(true)
		if _settlement_received
		else {}
	)
	_combat_network = null
	_combat_game = null
	_route.hide_combat_entry_transition()
	_route.set_route_presentation_enabled(true)
	_reset_protocol_state()
	_route_spectator_occurrence_key = occurrence_key
	if not received_settlement.is_empty():
		_apply_route_spectator_settlement(
			occurrence_key,
			received_settlement
		)


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
		if _is_host() and _phase != ProtocolPhase.IDLE:
			_pending_spectator_peers[new_peer_id] = true
			call_deferred("_defer_route_spectator_sync", new_peer_id)
		return
	if _terminal_safe_broadcast:
		if _is_host():
			_send_terminal_reconnect_spectator(
				new_peer_id,
				_active_occurrence_key
			)
		_reconnecting_peer_ids.erase(new_peer_id)
		return

	var host_runtime_missing := _host_runtime_is_missing_peer(new_peer_id)
	var disconnected_record := _remap_reconnected_participant_identity(
		old_peer_id,
		new_peer_id
	)
	if _is_host() and _phase == ProtocolPhase.SETTLED:
		# The outcome already exists; rebuilding and activating a combat scene only
		# races its deferred prepared signal against the settlement packet. Restore
		# authoritative economy directly on a route spectator instead.
		_keep_reconnected_participant_as_spectator(
			old_peer_id,
			new_peer_id,
			disconnected_record
		)
		return
	if host_runtime_missing:
		# MpGame had no authoritative PlayerState to restore. Keep the canonical
		# identity migrated for route economy/settlement, but never send a prepare
		# that the Host itself cannot simulate.
		_keep_reconnected_participant_as_spectator(
			old_peer_id,
			new_peer_id,
			disconnected_record
		)
		return

	_reconnecting_peer_ids.erase(new_peer_id)
	if not _is_host():
		return
	if not _is_peer_send_ready(new_peer_id):
		_keep_reconnected_participant_as_spectator(
			old_peer_id,
			new_peer_id,
			disconnected_record
		)
		return
	var activate_immediately := _phase in [
		ProtocolPhase.ACTIVE,
		ProtocolPhase.SETTLED,
	] or _activation_dispatch_started
	_pending_reconnect_prepare_peers[new_peer_id] = {
		"occurrence_key": _active_occurrence_key,
		"deadline_msec": (
			Time.get_ticks_msec() + RECONNECT_ACTIVATION_TIMEOUT_MSEC
			if activate_immediately
			else 0
		),
	}
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


func _keep_reconnected_participant_as_spectator(
	old_peer_id: int,
	new_peer_id: int,
	disconnected_record: Dictionary
) -> void:
	_disconnected_participants[new_peer_id] = disconnected_record.duplicate(true)
	_pending_reconnect_prepare_peers.erase(new_peer_id)
	_expected_prepared_peers.erase(new_peer_id)
	_prepared_peers.erase(new_peer_id)
	_expected_terminal_peers.erase(new_peer_id)
	_terminal_ready_peers.erase(new_peer_id)
	if _combat_network != null and is_instance_valid(_combat_network):
		_combat_network.suspend_embedded_participant_for_current_combat(
			new_peer_id,
			old_peer_id
		)
	_reconnecting_peer_ids.erase(new_peer_id)
	_send_terminal_reconnect_spectator(
		new_peer_id,
		_active_occurrence_key
	)


func _host_runtime_is_missing_peer(peer_id: int) -> bool:
	if not _is_host() or peer_id <= 0:
		return false
	if _combat_network == null or not is_instance_valid(_combat_network):
		return true
	var runtime := _combat_network.get_game_runtime()
	return (
		runtime == null
		or not is_instance_valid(runtime)
		or runtime.get_player_for_peer(peer_id) == null
	)


func _remap_reconnected_participant_identity(
	old_peer_id: int,
	new_peer_id: int
) -> Dictionary:
	var disconnected_record := (
		(_disconnected_participants[old_peer_id] as Dictionary).duplicate(true)
		if _disconnected_participants.has(old_peer_id)
		else {
			"entry_xirang": int(_entry_xirang_by_peer.get(old_peer_id, 0)),
			"was_prepared": _prepared_peers.has(old_peer_id),
			"was_terminal_ready": _terminal_ready_peers.has(old_peer_id),
		}
	)
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
	_pending_reconnect_prepare_peers.erase(old_peer_id)
	_expected_prepared_peers.erase(old_peer_id)
	_prepared_peers.erase(old_peer_id)
	_expected_terminal_peers.erase(old_peer_id)
	_terminal_ready_peers.erase(old_peer_id)
	if (
		_phase == ProtocolPhase.PREPARING
		and not _activation_dispatch_started
	):
		_expected_prepared_peers[new_peer_id] = true
	elif _phase == ProtocolPhase.SETTLED:
		_expected_terminal_peers[new_peer_id] = true
		_remap_pending_settlement_peer(old_peer_id, new_peer_id)
	return disconnected_record


func _send_terminal_reconnect_spectator(
	peer_id: int,
	occurrence_key: String
) -> void:
	_reconnecting_peer_ids.erase(peer_id)
	if not _is_host() or peer_id <= 0 or occurrence_key.is_empty():
		return
	var settlement: Dictionary = {}
	if (
		_settlement_received
		and occurrence_key == _active_occurrence_key
		and not _pending_settlement.is_empty()
	):
		settlement = _pending_settlement.duplicate(true)
	_pending_terminal_spectator_syncs[peer_id] = {
		"occurrence_key": occurrence_key,
		"settlement": settlement,
		"expires_msec": (
			Time.get_ticks_msec() + TERMINAL_SPECTATOR_SYNC_TIMEOUT_MSEC
		),
	}
	_flush_pending_terminal_spectator_sync(peer_id)


func _flush_pending_terminal_spectator_sync(peer_id: int) -> bool:
	if (
		not _is_host()
		or peer_id <= 0
		or not _pending_terminal_spectator_syncs.has(peer_id)
		or not _is_peer_send_ready(peer_id)
	):
		return false
	var pending := (
		_pending_terminal_spectator_syncs[peer_id] as Dictionary
	)
	var occurrence_key := str(pending.get("occurrence_key", ""))
	if occurrence_key.is_empty():
		_pending_terminal_spectator_syncs.erase(peer_id)
		return false
	var settlement := pending.get("settlement", {}) as Dictionary
	if (
		settlement.is_empty()
		and _settlement_received
		and occurrence_key == _active_occurrence_key
		and not _pending_settlement.is_empty()
	):
		settlement = _pending_settlement.duplicate(true)
	_dispatch_terminal_spectator_sync(
		peer_id,
		occurrence_key,
		settlement
	)
	_pending_terminal_spectator_syncs.erase(peer_id)
	return true


func _dispatch_terminal_spectator_sync(
	peer_id: int,
	occurrence_key: String,
	settlement: Dictionary
) -> void:
	net_combat_route_spectator.rpc_id(peer_id, occurrence_key)
	if not settlement.is_empty():
		net_combat_settlement.rpc_id(
			peer_id,
			occurrence_key,
			settlement.duplicate(true)
		)


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
	var connected_players := _net_manager.connected_players
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
			typeof(peer_id_variant) != TYPE_INT
			or peer_id <= 0
			or not xirang_by_peer.has(peer_id)
			or typeof(xirang_by_peer[peer_id]) != TYPE_INT
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
	return _net_manager.get_host_peer_id() if _net_manager != null else 0


func _get_local_peer_id() -> int:
	if _net_manager != null:
		var local_peer_id := _net_manager.get_local_peer_id()
		if local_peer_id > 0:
			return local_peer_id
	return _get_host_peer_id() if _is_host() else 0


func _is_host() -> bool:
	return _net_manager != null and _net_manager.is_host()


func _is_client() -> bool:
	return _net_manager != null and _net_manager.is_client()


func _is_peer_send_ready(peer_id: int) -> bool:
	return (
		_net_manager != null
		and peer_id > 0
		and _net_manager.is_peer_send_ready(peer_id)
	)
