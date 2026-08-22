extends Node
class_name RogueCombatMultiplayerCoordinator

## 多人 Rouge 路线与一次性作战运行时之间的权威协调器。
##
## 此节点必须静态存在于 MpRogueRoute 场景中，保证所有 peer 的 RPC
## NodePath 恒定。楼层普通作战池无效或未确认时，本节点不会连接路线的
## normal_combat_requested 信号，因此不会意外锁住测试地图。

## MpGame 的塔防根场景现在静态挂载 MpRogueRoute 运输桥；这里若继续
## preload MpGame 会形成 MpGame -> MpRogueRoute -> RogueCombat -> MpGame
## 的资源加载环。只在真正进入路线作战时从缓存加载 PackedScene。
const MP_GAME_SCENE_PATH := "res://scene/multiplayer/mp_game.tscn"

const COMBAT_RUNTIME_NODE_NAME := &"RogueCombatNetwork"
const STANDARD_BATTLE_XIRANG := 1000
const INVALID_NODE_ID := -1
const TERMINAL_PROCESS_MODE := Node.PROCESS_MODE_DISABLED
const PREPARE_BARRIER_TIMEOUT_MSEC := 30_000
const RECONNECT_ACTIVATION_TIMEOUT_MSEC := 15_000
const TERMINAL_BARRIER_TIMEOUT_MSEC := 15_000
const TERMINAL_SPECTATOR_SYNC_TIMEOUT_MSEC := 30_000
const EMERGENCY_REWARD_WIRE_SCHEMA_VERSION := 1
const INVALID_REWARD_OFFER_INDEX := -1
const YUANSHI_FIRE_PROJECTILE_POOL_SCENE := preload(
	"res://scene/enemy/yuanshi_insect/yuanshi_insect_fire_projectile.tscn"
)
const SUITCASE_COMBAT_CONFIG_ID := &"suitcase_battle"
const SUITCASE_ELITE_BULLET_POOL_CAPACITY := 480
const UNDERGROUND_CHURCH_COMBAT_CONFIG_ID := &"underground_church_01"
const UNDERGROUND_CHURCH_GUNNER_BULLET_POOL_CAPACITY := 240
const UNDERGROUND_SEWER_COMBAT_CONFIG_ID := &"underground_sewer_01"
const EMERGENCY_UNDERGROUND_SEWER_COMBAT_CONFIG_ID := (
	&"emergency_underground_sewer_01"
)
const UNDERGROUND_SEWER_FIRE_PROJECTILE_PREWARM_COUNT := 48
const UNDERGROUND_SEWER_FIRE_PROJECTILE_RETAINED_CAPACITY := 192
const EMERGENCY_UNDERGROUND_SEWER_ELITE_BULLET_POOL_CAPACITY := 144
const CLIENT_PREPARATION_ABORT_REASONS := {
	&"local_config_disabled": true,
	&"config_mismatch": true,
	&"route_start_rejected": true,
	&"runtime_create_failed": true,
	&"runtime_preparation_failed": true,
	&"runtime_config_failed": true,
	&"client_runtime_activate_failed": true,
	&"entry_reveal_failed": true,
	&"runtime_activate_failed": true,
}

enum ProtocolPhase {
	IDLE,
	PREPARING,
	ACTIVE,
	REWARD_SELECTING,
	SETTLED,
}

enum SessionProjectionOwner {
	## 外层 MpGame 已拥有会话级 Player 投影，本协调器只管理当前作战参与者。
	ENCLOSING_RUNTIME,
	## 独立 P3 路线没有另一层游戏运行时，由本协调器汇总内嵌 Player 结果。
	THIS_COORDINATOR,
}

var _route: RogueRouteGame = null
var _net_manager: NetManagerStore = null
var _run_state: RunStateStore = null
var _player_persistent_modifier_projector: PlayerPersistentModifierProjector = null
var _enabled := false
var _phase := ProtocolPhase.IDLE

var _active_node_id := INVALID_NODE_ID
var _active_content_seed := 0
var _active_occurrence_key := ""
var _active_combat_config_id: StringName = &""
var _active_encounter_config: RogueCombatEncounterConfig = null
var _active_config_signature := ""
var _participant_peer_ids: Dictionary = {}
var _entry_xirang_by_peer: Dictionary = {}
var _participant_character_ids: Dictionary = {}
var _participant_stable_keys: Dictionary = {}
## participant incarnation 是跨 raw peer 重连仍不变的会话身份。它只用于
## 校验 component-first 结果确实属于当前参战者，不能拿 raw peer 猜同一性。
var _participant_incarnations: Dictionary[int, int] = {}
var _last_combat_xirang_by_peer: Dictionary = {}
var _disconnected_participants: Dictionary = {}
var _pending_spectator_peers: Dictionary = {}
var _reconnecting_peer_ids: Dictionary = {}
var _pending_reconnect_prepare_peers: Dictionary = {}
## NetManager 只在 PREPARING_DELIVERY 控制面阶段发布该一次性投递租约。
## 与 prepare intent 分开保存，使“Player 先恢复”与“投递租约先到”可交换。
var _reconnected_member_ready_outcomes: Dictionary[int, Dictionary] = {}
## 路线身份提交与内嵌 Player 投影来自同一个 reconnect 信号的不同监听者。
## 以 new peer 为键汇合两个明确结果，彻底消除信号连接先后顺序的影响。
var _pending_reconnected_identity_resolutions: Dictionary[int, Dictionary] = {}
## pending 被消费后仍保留首次终态，既让可靠信号重放幂等，也让冲突终态
## fail-close/降级，而不是重新创建一笔看似合法的 outcome-first 事务。
var _resolved_reconnected_identity_resolutions: Dictionary[int, Dictionary] = {}
var _pending_terminal_spectator_syncs: Dictionary = {}
var _route_spectator_occurrence_key := ""
## 终局重连成员可能在结算到达前先降级为路线观战者；这里冻结其原始参战
## 集合，不能在协议 reset 后用空字典退回“恢复所有路线 Player”。
var _route_spectator_participant_peer_ids: Dictionary = {}
var _session_projection_owner := SessionProjectionOwner.ENCLOSING_RUNTIME

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
var _abort_settlement_in_progress := false
var _settled_occurrences: Dictionary = {}

var _emergency_reward_session: RogueEmergencyRewardSelectionSession = null
var _emergency_reward_overlay: RogueEmergencyRewardChoiceOverlay = null
var _emergency_reward_client_snapshot: Dictionary = {}
var _emergency_reward_rollback_state: Dictionary = {}
var _emergency_reward_completion_failure_by_peer: Dictionary = {}
var _emergency_reward_completion_retry_requested := false

var _expected_terminal_peers: Dictionary = {}
var _terminal_ready_peers: Dictionary = {}
var _terminal_safe_received := false
var _terminal_safe_broadcast := false
var _terminal_barrier_deadline_msec := 0

var _local_result_visible := false
var _local_route_returned := false
var _local_result_occurrence_key := ""
## 结算面板可能晚于协议 runtime 释放；参战集合随结果生命周期单独持有，
## 不能在 _reset_protocol_state 后退回“恢复路线所有玩家”。
var _local_result_participant_peer_ids: Dictionary = {}
var _local_terminal_finalized := false
var _consumed_node_ids: Dictionary = {}
var _terminal_sequence_serial := 0


## Tower 嵌入式探索在创建任何 MpGame/Combat Player 前注入持久层投影器。
func configure_player_persistent_modifier_projector(
	projector: PlayerPersistentModifierProjector
) -> void:
	_player_persistent_modifier_projector = projector


func bind_network_dependencies(
	route_instance: RogueRouteGame,
	net_manager_instance: NetManagerStore,
	run_state_instance: RunStateStore,
	session_projection_owner: SessionProjectionOwner
) -> void:
	assert(route_instance != null, "肉鸽作战协调器缺少路线运行时。")
	assert(net_manager_instance != null, "肉鸽作战协调器缺少 NetManagerStore。")
	assert(run_state_instance != null, "肉鸽作战协调器缺少 RunStateStore。")
	assert(
		session_projection_owner in [
			SessionProjectionOwner.ENCLOSING_RUNTIME,
			SessionProjectionOwner.THIS_COORDINATOR,
		],
		"肉鸽作战协调器缺少明确的会话投影所有者。"
	)
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
	_session_projection_owner = session_projection_owner
	_emergency_reward_overlay = _route.emergency_reward_choice_overlay
	_connect_emergency_reward_overlay_signals()
	_enabled = _has_enabled_multiplayer_combat_pool(_route)
	set_multiplayer_authority(_get_host_peer_id())
	if not _enabled:
		return

	if not _route.combat_requested.is_connected(
		_on_combat_requested
	):
		_route.combat_requested.connect(_on_combat_requested)
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
	if not _route.normal_combat_snapshot_reconciled.is_connected(
		_on_route_normal_combat_snapshot_reconciled
	):
		_route.normal_combat_snapshot_reconciled.connect(
			_on_route_normal_combat_snapshot_reconciled
		)
	_connect_net_manager_signals()


func _physics_process(delta: float) -> void:
	if not _enabled or not _is_host():
		return
	var now_msec := Time.get_ticks_msec()
	_poll_pending_terminal_spectator_syncs(now_msec)
	if _phase == ProtocolPhase.IDLE:
		return
	if (
		_phase == ProtocolPhase.REWARD_SELECTING
		and _emergency_reward_session != null
	):
		if _emergency_reward_session.is_choosing():
			_emergency_reward_session.advance(delta)
		_try_complete_host_emergency_rewards()
		return
	_capture_live_combat_xirang()
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
			or _phase == ProtocolPhase.REWARD_SELECTING
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
				_local_result_participant_peer_ids = _participant_peer_ids.duplicate()
			if not _return_to_route_local():
				push_error("Rogue 多人终局超时无法恢复路线 Player，拒绝释放本地战场。")
				continue
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
		var occurrence_key := str(pending.get("occurrence_key", ""))
		var settlement := pending.get("settlement", {}) as Dictionary
		if (
			settlement.is_empty()
			and _settlement_received
			and occurrence_key == _active_occurrence_key
			and not _pending_settlement.is_empty()
		):
			pending["settlement"] = _pending_settlement.duplicate(true)
			pending["expires_msec"] = (
				now + TERMINAL_SPECTATOR_SYNC_TIMEOUT_MSEC
			)
			_pending_terminal_spectator_syncs[peer_id] = pending
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
	_reset_emergency_reward_selection()
	_disconnect_emergency_reward_overlay_signals()
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


static func _has_enabled_multiplayer_combat_pool(
	route_instance: RogueRouteGame
) -> bool:
	if (
		route_instance == null
		or route_instance.floor_definition == null
		or route_instance.floor_definition.normal_combat_pool == null
		or not route_instance.floor_definition.normal_combat_pool.is_ready_to_enable()
		or route_instance.floor_definition.emergency_combat_pool == null
		or not route_instance.floor_definition.emergency_combat_pool.is_ready_to_enable()
	):
		return false
	var configs: Array[RogueCombatEncounterConfig] = []
	configs.append_array(
		route_instance.floor_definition.get_sorted_normal_combat_configs()
	)
	configs.append_array(
		route_instance.floor_definition.get_sorted_emergency_combat_configs()
	)
	if configs.is_empty():
		return false
	for config in configs:
		if not is_config_enabled_for_multiplayer(config):
			return false
	return true


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


func _disconnect_route_signals() -> void:
	if _route == null or not is_instance_valid(_route):
		return
	if _route.combat_requested.is_connected(
		_on_combat_requested
	):
		_route.combat_requested.disconnect(_on_combat_requested)
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
	if _route.normal_combat_snapshot_reconciled.is_connected(
		_on_route_normal_combat_snapshot_reconciled
	):
		_route.normal_combat_snapshot_reconciled.disconnect(
			_on_route_normal_combat_snapshot_reconciled
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


func _on_combat_requested(
	node_id: int,
	content_seed: int,
	occurrence_key: String,
	combat_config_id: StringName
) -> void:
	var resolved_config: RogueCombatEncounterConfig = (
		_route.resolve_combat_config(combat_config_id) as RogueCombatEncounterConfig
		if _route != null
		else null
	)
	if (
		not _enabled
		or not _is_host()
		or _phase != ProtocolPhase.IDLE
		or not is_config_enabled_for_multiplayer(resolved_config)
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

	var participants := (
		_route.get_followup_combat_participant_peer_ids(
			occurrence_key,
			combat_config_id
		)
		if _route.is_special_combat_config_id(combat_config_id)
		else _capture_current_participants()
	)
	if participants.is_empty():
		_route.abort_briefing_entry(occurrence_key)
		_route.complete_normal_combat(occurrence_key)
		return
	var entry_xirang := _capture_entry_xirang(participants, resolved_config)
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
		false,
		combat_config_id,
		resolved_config
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
			_active_combat_config_id,
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
	activate_when_prepared: bool,
	combat_config_id: StringName,
	resolved_config: RogueCombatEncounterConfig
) -> bool:
	if (
		_phase != ProtocolPhase.IDLE
		or node_id < 0
		or occurrence_key.is_empty()
		or participant_peer_ids.is_empty()
		or combat_config_id == &""
		or not is_config_enabled_for_multiplayer(resolved_config)
		or resolved_config.encounter_id != combat_config_id
	):
		return false
	_discard_pending_terminal_spectator_syncs_except(occurrence_key)
	_resolve_stale_local_result_before_prepare()
	_route_spectator_occurrence_key = ""
	_active_node_id = node_id
	_active_content_seed = content_seed
	_active_occurrence_key = occurrence_key
	_active_combat_config_id = combat_config_id
	_active_encounter_config = resolved_config
	_active_config_signature = _make_config_signature(_active_encounter_config)
	_participant_peer_ids = _index_peer_ids(participant_peer_ids)
	_entry_xirang_by_peer = entry_xirang_by_peer.duplicate(true)
	_last_combat_xirang_by_peer = _entry_xirang_by_peer.duplicate(true)
	if not _freeze_participant_reward_identities() and _is_host():
		return false
	if not _freeze_participant_incarnations():
		return false
	_reset_emergency_reward_selection()
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
	_abort_settlement_in_progress = false
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
	combat_config_id: StringName,
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
	var resolved_config: RogueCombatEncounterConfig = (
		_route.resolve_combat_config(combat_config_id) as RogueCombatEncounterConfig
		if _route != null
		else null
	)
	if (
		not is_config_enabled_for_multiplayer(resolved_config)
		or config_signature != _make_config_signature(resolved_config)
	):
		_request_authoritative_abort(occurrence_key, &"config_mismatch")
		return
	if _phase != ProtocolPhase.IDLE:
		if (
			occurrence_key != _active_occurrence_key
			or combat_config_id != _active_combat_config_id
		):
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
		occurrence_key,
		combat_config_id
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
		activate_when_prepared,
		combat_config_id,
		resolved_config
	):
		_request_authoritative_abort(occurrence_key, &"runtime_create_failed")


func _create_embedded_runtime() -> bool:
	if (
		_combat_network != null
		or _active_occurrence_key.is_empty()
		or _active_encounter_config == null
	):
		return false
	var packed_scene := load(MP_GAME_SCENE_PATH) as PackedScene
	if packed_scene == null:
		push_error(
			"RogueCombatMultiplayerCoordinator: 无法加载 MpGame 嵌入战斗场景。"
		)
		return false
	var raw_instance := packed_scene.instantiate()
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
	instance.configure_player_persistent_modifier_projector(
		_player_persistent_modifier_projector
	)
	if not instance.configure_embedded_runtime_contract(
		_active_encounter_config.combat_scene_path,
		GameModeCatalog.MODE_ROGUE,
		_pack_peer_ids(_participant_peer_ids)
	):
		push_error(
			(
				"RogueCombatMultiplayerCoordinator: 无法提交内嵌战斗的"
				+ "场景、模式与参战名单契约。"
			)
		)
		instance.free()
		return false
	if not instance.embedded_runtime_prepared.is_connected(
		_on_embedded_runtime_prepared
	):
		instance.embedded_runtime_prepared.connect(
			_on_embedded_runtime_prepared
		)
	if not instance.reconnected_player_projection_resolved.is_connected(
		_on_embedded_reconnected_player_projection_resolved
	):
		instance.reconnected_player_projection_resolved.connect(
			_on_embedded_reconnected_player_projection_resolved
		)
	var failed_callback := Callable(
		self,
		&"_on_embedded_runtime_preparation_failed"
	).bind(instance, _active_occurrence_key)
	instance.runtime_preparation_failed.connect(
		failed_callback,
		CONNECT_ONE_SHOT
	)
	_combat_network = instance
	add_child(instance)
	# add_child 会同步执行 MpGame._ready()。不能把已经进入 FAILED 的子战场
	# 当作创建成功，否则 Host 会继续发送 prepare 并一直等到屏障超时。
	if instance.is_runtime_preparation_failed():
		var preparation := instance.get_runtime_preparation_snapshot()
		push_error(
			"RogueCombatMultiplayerCoordinator: 内嵌战场同步准备失败：%s"
			% preparation.failure_reason
		)
		instance.queue_free()
		if _combat_network == instance:
			_combat_network = null
		return false
	return true


func _on_embedded_runtime_preparation_failed(
	reason: String,
	expected_runtime: MultiplayerGameplaySession,
	occurrence_key: String
) -> void:
	# 同步 _ready 失败由 _create_embedded_runtime 的返回值立即阻止 prepare
	# 派发；这里 deferred 后同时覆盖子场景的异步预热失败，并避免在子节点
	# 发信号的调用栈里拆除它。
	call_deferred(
		&"_handle_embedded_runtime_preparation_failed",
		reason,
		expected_runtime,
		occurrence_key
	)


func _handle_embedded_runtime_preparation_failed(
	reason: String,
	expected_runtime: MultiplayerGameplaySession,
	occurrence_key: String
) -> void:
	if (
		_phase != ProtocolPhase.PREPARING
		or occurrence_key.is_empty()
		or occurrence_key != _active_occurrence_key
		or not is_instance_valid(expected_runtime)
		or _combat_network != expected_runtime
	):
		return
	push_error(
		"RogueCombatMultiplayerCoordinator: 内嵌战场准备失败：%s" % reason
	)
	_request_authoritative_abort(occurrence_key, &"runtime_preparation_failed")


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
		_active_encounter_config.get_spawn_point_mask()
	)
	if not scene_contract_errors.is_empty():
		for error in scene_contract_errors:
			push_error(error)
		return false
	var campaign := build_occurrence_campaign(
		_active_encounter_config,
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
	_combat_game.event_title = _active_encounter_config.event_title
	_combat_game.pre_wave_duration = float(
		_active_encounter_config.preparation_seconds
	)
	_combat_game.combat_time_limit_seconds = float(
		_active_encounter_config.combat_limit_seconds
	)
	_combat_game.deadline_start = (
		RogueCombatGame.DeadlineStart.PREPARATION_START
		if _active_encounter_config.deadline_start
		== RogueCombatEncounterConfig.DeadlineStart.PREPARATION_START
		else RogueCombatGame.DeadlineStart.WAVE_START
	)
	_combat_game.enemy_pickup_drops_enabled = (
		_active_encounter_config.enemy_pickup_drops
		== RogueCombatEncounterConfig.Decision.YES
	)
	if _active_combat_config_id == SUITCASE_COMBAT_CONFIG_ID:
		CombatRuntimeBase.register_combat_robot_gunner_elite_bullet_pool(
			_combat_game.session_object_pool,
			SUITCASE_ELITE_BULLET_POOL_CAPACITY,
			SUITCASE_ELITE_BULLET_POOL_CAPACITY
		)
	elif _active_combat_config_id == UNDERGROUND_CHURCH_COMBAT_CONFIG_ID:
		CombatRuntimeBase.register_combat_robot_gunner_bullet_pool(
			_combat_game.session_object_pool,
			UNDERGROUND_CHURCH_GUNNER_BULLET_POOL_CAPACITY,
			UNDERGROUND_CHURCH_GUNNER_BULLET_POOL_CAPACITY
		)
	_apply_underground_sewer_projectile_pool_overrides(
		_combat_game.session_object_pool,
		_active_combat_config_id
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


func _apply_underground_sewer_projectile_pool_overrides(
	pool: SessionObjectPool,
	encounter_id: StringName
) -> void:
	if (
		pool == null
		or not (
			encounter_id == UNDERGROUND_SEWER_COMBAT_CONFIG_ID
			or encounter_id == EMERGENCY_UNDERGROUND_SEWER_COMBAT_CONFIG_ID
		)
	):
		return
	# 火焰弹理论并发约30；48个预热实例保留余量，192回收上限沿用公共池。
	pool.register_scene(
		YUANSHI_FIRE_PROJECTILE_POOL_SCENE,
		UNDERGROUND_SEWER_FIRE_PROJECTILE_PREWARM_COUNT,
		UNDERGROUND_SEWER_FIRE_PROJECTILE_RETAINED_CAPACITY
	)
	if encounter_id == EMERGENCY_UNDERGROUND_SEWER_COMBAT_CONFIG_ID:
		# 10名精英枪手一轮至多120发；144为完整齐射保留20%余量。
		CombatRuntimeBase.register_combat_robot_gunner_elite_bullet_pool(
			pool,
			EMERGENCY_UNDERGROUND_SEWER_ELITE_BULLET_POOL_CAPACITY,
			EMERGENCY_UNDERGROUND_SEWER_ELITE_BULLET_POOL_CAPACITY
		)


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
		or not _is_gameplay_ingress_admitted(sender_id)
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
		or not _is_gameplay_ingress_admitted(sender_id)
		or occurrence_key != _active_occurrence_key
		or not _is_dispatched_reconnect_prepare(sender_id, occurrence_key)
		or not (
			_phase in [
				ProtocolPhase.ACTIVE,
				ProtocolPhase.REWARD_SELECTING,
				ProtocolPhase.SETTLED,
			]
			or (
				_phase == ProtocolPhase.PREPARING
				and _activation_dispatch_started
			)
		)
	):
		return
	_pending_reconnect_prepare_peers.erase(sender_id)
	_reconnected_member_ready_outcomes.erase(sender_id)


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


func _connect_emergency_reward_overlay_signals() -> void:
	if _emergency_reward_overlay == null:
		return
	if not _emergency_reward_overlay.choice_selected.is_connected(
		_on_emergency_reward_choice_selected
	):
		_emergency_reward_overlay.choice_selected.connect(
			_on_emergency_reward_choice_selected
		)
	if not _emergency_reward_overlay.inventory_requested.is_connected(
		_on_emergency_reward_inventory_requested
	):
		_emergency_reward_overlay.inventory_requested.connect(
			_on_emergency_reward_inventory_requested
		)


func _disconnect_emergency_reward_overlay_signals() -> void:
	if _emergency_reward_overlay == null or not is_instance_valid(
		_emergency_reward_overlay
	):
		return
	if _emergency_reward_overlay.choice_selected.is_connected(
		_on_emergency_reward_choice_selected
	):
		_emergency_reward_overlay.choice_selected.disconnect(
			_on_emergency_reward_choice_selected
		)
	if _emergency_reward_overlay.inventory_requested.is_connected(
		_on_emergency_reward_inventory_requested
	):
		_emergency_reward_overlay.inventory_requested.disconnect(
			_on_emergency_reward_inventory_requested
		)


func _is_active_emergency_reward_encounter() -> bool:
	return (
		_route != null
		and _active_encounter_config != null
		and _route.is_emergency_combat_config_id(_active_combat_config_id)
		and _active_encounter_config.reward_config != null
		and _active_encounter_config.reward_config.uses_collectible_choices()
		and _active_encounter_config.reward_config.uses_random_item_reward()
	)


func _begin_host_emergency_reward_selection(
	occurrence_key: String
) -> bool:
	if (
		not _is_host()
		or _phase != ProtocolPhase.ACTIVE
		or occurrence_key != _active_occurrence_key
		or not _is_active_emergency_reward_encounter()
		or _emergency_reward_session != null
	):
		return false
	var rollback_state := _capture_host_reward_rollback_state()
	if rollback_state.is_empty():
		return false
	_capture_live_combat_xirang()
	var peer_ids: Array[int] = []
	var base_xirang_by_peer: Dictionary = {}
	for peer_id_variant in _participant_peer_ids.keys():
		var peer_id := int(peer_id_variant)
		peer_ids.append(peer_id)
		base_xirang_by_peer[peer_id] = int(_last_combat_xirang_by_peer.get(
			peer_id,
			_entry_xirang_by_peer.get(peer_id, 0)
		))
	peer_ids.sort()
	var session := RogueEmergencyRewardSelectionSession.new()
	if not session.begin_authority(
		_run_state,
		StringName(occurrence_key),
		_active_content_seed,
		peer_ids,
		_active_encounter_config.reward_config,
		_active_encounter_config.filter_loot_by_character
		== RogueCombatEncounterConfig.Decision.YES,
		_participant_stable_keys,
		_participant_character_ids,
		base_xirang_by_peer
	):
		return false
	for peer_id_variant in _disconnected_participants.keys():
		session.mark_peer_disconnected(int(peer_id_variant), occurrence_key)
	_emergency_reward_session = session
	_emergency_reward_rollback_state = rollback_state
	_emergency_reward_completion_failure_by_peer.clear()
	_emergency_reward_completion_retry_requested = true
	_emergency_reward_session.state_changed.connect(
		_on_emergency_reward_session_state_changed
	)
	_phase = ProtocolPhase.REWARD_SELECTING
	_freeze_local_combat_for_reward_selection()
	_broadcast_emergency_reward_state()
	_try_complete_host_emergency_rewards()
	return true


func _freeze_local_combat_for_reward_selection() -> void:
	if _combat_game == null or not is_instance_valid(_combat_game):
		return
	# 战场模拟冻结，但保留资料面板与 MpGame 事务节点；这样背包满时仍可
	# 使用既有多人权威丢弃流程整理背包。
	_combat_game.process_mode = Node.PROCESS_MODE_DISABLED
	if _combat_game.player_profile_panel != null:
		_combat_game.player_profile_panel.process_mode = Node.PROCESS_MODE_ALWAYS


func _on_emergency_reward_session_state_changed(_snapshot: Dictionary) -> void:
	if not _is_host() or _phase != ProtocolPhase.REWARD_SELECTING:
		return
	_emergency_reward_completion_failure_by_peer.clear()
	if (
		_emergency_reward_session != null
		and _emergency_reward_session.is_ready_to_settle()
	):
		_emergency_reward_completion_retry_requested = true
	_broadcast_emergency_reward_state()


func _broadcast_emergency_reward_state() -> void:
	if (
		not _is_host()
		or _phase != ProtocolPhase.REWARD_SELECTING
		or _emergency_reward_session == null
	):
		return
	for peer_id_variant in _participant_peer_ids.keys():
		var peer_id := int(peer_id_variant)
		if _disconnected_participants.has(peer_id):
			continue
		var projection := _build_emergency_reward_projection(peer_id)
		if projection.is_empty():
			continue
		if peer_id == _get_local_peer_id():
			_apply_emergency_reward_projection(projection)
		elif _is_peer_send_ready(peer_id):
			net_emergency_reward_snapshot.rpc_id(
				peer_id,
				_active_occurrence_key,
				projection
			)


func _send_emergency_reward_state_to_peer(peer_id: int) -> void:
	if (
		not _is_host()
		or peer_id <= 0
		or _disconnected_participants.has(peer_id)
		or not _is_peer_send_ready(peer_id)
	):
		return
	var projection := _build_emergency_reward_projection(peer_id)
	if not projection.is_empty():
		net_emergency_reward_snapshot.rpc_id(
			peer_id,
			_active_occurrence_key,
			projection
		)


func _build_emergency_reward_projection(peer_id: int) -> Dictionary:
	if _emergency_reward_session == null or peer_id <= 0:
		return {}
	var full_snapshot := _emergency_reward_session.export_state()
	var local_state: Dictionary = {}
	var waiting_online_count := 0
	for participant_variant in full_snapshot.get("participants", []) as Array:
		if not participant_variant is Dictionary:
			return {}
		var participant := participant_variant as Dictionary
		var participant_peer_id := int(participant.get("peer_id", -1))
		var complete := bool(participant.get("complete", false))
		var forfeited := bool(participant.get("forfeited", false))
		if not complete and not forfeited:
			waiting_online_count += 1
		if participant_peer_id != peer_id:
			continue
		var selected_paths := participant.get("selected_paths", []) as Array
		var rounds := participant.get("rounds", []) as Array
		var retry_offer_paths: Array = []
		var retry_offer_index := INVALID_REWARD_OFFER_INDEX
		if not selected_paths.is_empty():
			var selected_round_index := selected_paths.size() - 1
			if selected_round_index >= 0 and selected_round_index < rounds.size():
				retry_offer_paths = (
					(rounds[selected_round_index] as Dictionary).get(
						"paths",
						[]
					) as Array
				).duplicate()
				retry_offer_index = retry_offer_paths.find(
					selected_paths[selected_round_index]
				)
		local_state = {
			"peer_id": participant_peer_id,
			"current_round_index": int(participant.get(
				"current_round_index",
				participant.get("round_index", 0)
			)),
			"current_offer_paths": (
				participant.get("current_offer_paths", []) as Array
			).duplicate(),
			"deadline_seconds_remaining": float(participant.get(
				"deadline_seconds_remaining",
				participant.get("remaining_seconds", 0.0)
			)),
			"timeout_choice_index": int(participant.get(
				"timeout_choice_index",
				INVALID_REWARD_OFFER_INDEX
			)),
			"forfeited": forfeited,
			"complete": complete,
			"retry_offer_paths": retry_offer_paths,
			"retry_offer_index": retry_offer_index,
		}
	if local_state.is_empty():
		return {}
	return {
		"schema_version": EMERGENCY_REWARD_WIRE_SCHEMA_VERSION,
		"revision": int(full_snapshot.get("revision", 0)),
		"phase": str(full_snapshot.get("phase", "")),
		"occurrence_id": str(full_snapshot.get("occurrence_id", "")),
		"content_seed": int(full_snapshot.get("content_seed", 0)),
		"reward_contract_hash": str(full_snapshot.get(
			"reward_contract_hash",
			""
		)),
		"round_count": (
			_active_encounter_config.reward_config.collectible_choice_round_count
		),
		"waiting_online_count": waiting_online_count,
		"local_completion_blocked": (
			_emergency_reward_completion_failure_by_peer.has(peer_id)
		),
		"local_participant": local_state,
	}


@rpc("authority", "call_remote", "reliable", 0)
func net_emergency_reward_snapshot(
	occurrence_key: String,
	projection: Dictionary
) -> void:
	if (
		not _is_client()
		or multiplayer.get_remote_sender_id() != _get_host_peer_id()
		or occurrence_key != _active_occurrence_key
		or _phase not in [ProtocolPhase.ACTIVE, ProtocolPhase.REWARD_SELECTING]
	):
		return
	if _apply_emergency_reward_projection(projection):
		_phase = ProtocolPhase.REWARD_SELECTING
		_freeze_local_combat_for_reward_selection()


func _apply_emergency_reward_projection(projection: Dictionary) -> bool:
	if not _validate_emergency_reward_projection(projection):
		return false
	if (
		not _emergency_reward_client_snapshot.is_empty()
		and int(projection.get("revision", 0))
		< int(_emergency_reward_client_snapshot.get("revision", 0))
	):
		return false
	_emergency_reward_client_snapshot = projection.duplicate(true)
	_render_local_emergency_reward_projection()
	return true


func _validate_emergency_reward_projection(projection: Dictionary) -> bool:
	if (
		_active_encounter_config == null
		or _active_encounter_config.reward_config == null
		or int(projection.get("schema_version", -1))
		!= EMERGENCY_REWARD_WIRE_SCHEMA_VERSION
		or typeof(projection.get("revision")) != TYPE_INT
		or int(projection.get("revision", 0)) < 1
		or str(projection.get("occurrence_id", "")) != _active_occurrence_key
		or int(projection.get("content_seed", 0)) != _active_content_seed
		or str(projection.get("reward_contract_hash", ""))
		!= _active_encounter_config.reward_config.compute_runtime_contract_hash()
		or typeof(projection.get("local_participant")) != TYPE_DICTIONARY
		or typeof(projection.get("waiting_online_count")) != TYPE_INT
		or int(projection.get("waiting_online_count", -1)) < 0
	):
		return false
	var phase := StringName(projection.get("phase", ""))
	if phase not in [
		RogueEmergencyRewardSelectionSession.PHASE_CHOOSING,
		RogueEmergencyRewardSelectionSession.PHASE_READY,
		RogueEmergencyRewardSelectionSession.PHASE_SETTLED,
	]:
		return false
	var local_peer_id := _get_local_peer_id()
	var local_state := projection["local_participant"] as Dictionary
	var complete := bool(local_state.get("complete", false))
	var forfeited := bool(local_state.get("forfeited", false))
	var round_index := int(local_state.get("current_round_index", -1))
	var round_count := int(projection.get("round_count", -1))
	var remaining := float(local_state.get("deadline_seconds_remaining", -1.0))
	var timeout_index := int(local_state.get(
		"timeout_choice_index",
		-2
	))
	if (
		int(local_state.get("peer_id", -1)) != local_peer_id
		or round_count
		!= _active_encounter_config.reward_config.collectible_choice_round_count
		or round_index < 0
		or round_index > round_count
		or remaining < 0.0
		or remaining
		> _active_encounter_config.reward_config.collectible_choice_seconds_per_round
		or timeout_index < INVALID_REWARD_OFFER_INDEX
		or timeout_index
		>= _active_encounter_config.reward_config.collectible_choice_offer_count
		or (forfeited and not complete)
		or (not complete and phase != RogueEmergencyRewardSelectionSession.PHASE_CHOOSING)
	):
		return false
	var offer_paths := local_state.get("current_offer_paths", []) as Array
	if complete:
		var retry_offer_paths := local_state.get(
			"retry_offer_paths",
			[]
		) as Array
		var retry_offer_index := int(local_state.get(
			"retry_offer_index",
			INVALID_REWARD_OFFER_INDEX
		))
		return (
			offer_paths.is_empty()
			and (
				retry_offer_paths.is_empty()
				or (
					retry_offer_paths.size()
					== _active_encounter_config.reward_config.collectible_choice_offer_count
					and retry_offer_index >= 0
					and retry_offer_index < retry_offer_paths.size()
				)
			)
		)
	if (
		offer_paths.size()
		!= _active_encounter_config.reward_config.collectible_choice_offer_count
		or round_index >= round_count
	):
		return false
	var local_peer_ids: Array[int] = [local_peer_id]
	var offer_result := RogueCombatRewardResolver.build_emergency_collectible_offers(
		StringName(_active_occurrence_key),
		_active_content_seed,
		local_peer_ids,
		_active_encounter_config.reward_config,
		_active_encounter_config.filter_loot_by_character
		== RogueCombatEncounterConfig.Decision.YES,
		{local_peer_id: _participant_stable_keys.get(local_peer_id, "")},
		{local_peer_id: _participant_character_ids.get(local_peer_id, &"")}
	)
	if not bool(offer_result.get("resolved", false)):
		return false
	var expected_rounds := (
		(offer_result.get("offers_by_peer", {}) as Dictionary).get(
			local_peer_id,
			[]
		) as Array
	)
	return (
		round_index < expected_rounds.size()
		and offer_paths
		== (
			(expected_rounds[round_index] as Dictionary).get("paths", [])
			as Array
		)
	)


func _render_local_emergency_reward_projection() -> void:
	if _emergency_reward_overlay == null:
		return
	var local_state := (
		_emergency_reward_client_snapshot.get("local_participant", {}) as Dictionary
	)
	if local_state.is_empty() or bool(local_state.get("forfeited", false)):
		_emergency_reward_overlay.hide_and_reset()
		return
	var complete := bool(local_state.get("complete", false))
	if complete:
		if bool(_emergency_reward_client_snapshot.get(
			"local_completion_blocked",
			false
		)):
			var retry_offer_paths := local_state.get(
				"retry_offer_paths",
				[]
			) as Array
			var retry_offer_index := int(local_state.get(
				"retry_offer_index",
				INVALID_REWARD_OFFER_INDEX
			))
			if (
				retry_offer_paths.size() == 2
				and retry_offer_index >= 0
				and retry_offer_index < retry_offer_paths.size()
			):
				_emergency_reward_overlay.show_round(
					retry_offer_paths,
					maxi(int(local_state.get(
						"current_round_index",
						1
					)), 1),
					maxi(int(_emergency_reward_client_snapshot.get(
						"round_count",
						2
					)), 1),
					0.0,
					"背包空间不足 · 已选奖励保留",
					false,
					true
				)
				_emergency_reward_overlay.set_choice_pending(
					retry_offer_index
				)
			_emergency_reward_overlay.show_inventory_full_error(
				"背包空间不足 · 已选奖励保留，请整理后重试"
			)
		else:
			var waiting_count := int(_emergency_reward_client_snapshot.get(
				"waiting_online_count",
				0
			))
			_emergency_reward_overlay.set_waiting(
				"两轮选择已完成 · 等待其他在线玩家（%d）" % waiting_count
			)
		return
	var offer_paths := local_state.get("current_offer_paths", []) as Array
	var round_index := int(local_state.get("current_round_index", 0))
	var round_count := int(_emergency_reward_client_snapshot.get(
		"round_count",
		2
	))
	var remaining := float(local_state.get(
		"deadline_seconds_remaining",
		0.0
	))
	_emergency_reward_overlay.show_round(
		offer_paths,
		round_index + 1,
		round_count,
		remaining,
		"请选择其中一件收藏品",
		true,
		true
	)
	var locked_index := int(local_state.get(
		"timeout_choice_index",
		INVALID_REWARD_OFFER_INDEX
	))
	if locked_index >= 0 and remaining <= 0.0:
		_emergency_reward_overlay.set_choice_pending(locked_index)
		_emergency_reward_overlay.show_inventory_full_error()


func _on_emergency_reward_choice_selected(
	round_number: int,
	offer_index: int
) -> void:
	if (
		_phase != ProtocolPhase.REWARD_SELECTING
		or _emergency_reward_client_snapshot.is_empty()
	):
		return
	var local_peer_id := _get_local_peer_id()
	var expected_revision := int(_emergency_reward_client_snapshot.get(
		"revision",
		0
	))
	if bool(_emergency_reward_client_snapshot.get(
		"local_completion_blocked",
		false
	)):
		if _is_host():
			_handle_emergency_reward_completion_retry(local_peer_id)
		elif _is_peer_send_ready(_get_host_peer_id()):
			net_emergency_reward_completion_retry_requested.rpc_id(
				_get_host_peer_id(),
				_active_occurrence_key,
				expected_revision
			)
		return
	if _is_host():
		_handle_emergency_reward_choice_request(
			local_peer_id,
			expected_revision,
			round_number - 1,
			offer_index
		)
	elif _is_peer_send_ready(_get_host_peer_id()):
		net_emergency_reward_choice_requested.rpc_id(
			_get_host_peer_id(),
			_active_occurrence_key,
			expected_revision,
			round_number - 1,
			offer_index
		)


@rpc("any_peer", "call_remote", "reliable", 0)
func net_emergency_reward_choice_requested(
	occurrence_key: String,
	expected_revision: int,
	round_index: int,
	offer_index: int
) -> void:
	if not _is_host() or occurrence_key != _active_occurrence_key:
		return
	var sender_id := multiplayer.get_remote_sender_id()
	if not _net_manager.is_gameplay_ingress_admitted(sender_id):
		return
	_handle_emergency_reward_choice_request(
		sender_id,
		expected_revision,
		round_index,
		offer_index
	)


func _handle_emergency_reward_choice_request(
	peer_id: int,
	expected_revision: int,
	round_index: int,
	offer_index: int
) -> void:
	if (
		_phase != ProtocolPhase.REWARD_SELECTING
		or _emergency_reward_session == null
		or not _participant_peer_ids.has(peer_id)
		or _disconnected_participants.has(peer_id)
		or expected_revision < 1
		or expected_revision > _emergency_reward_session.get_revision()
	):
		_send_emergency_reward_state_to_peer(peer_id)
		return
	var result := _emergency_reward_session.submit_choice(
		peer_id,
		_active_occurrence_key,
		round_index,
		offer_index
	)
	if not bool(result.get("accepted", false)):
		_send_emergency_reward_state_to_peer(peer_id)
	_try_complete_host_emergency_rewards()


@rpc("any_peer", "call_remote", "reliable", 0)
func net_emergency_reward_completion_retry_requested(
	occurrence_key: String,
	expected_revision: int
) -> void:
	var sender_id := multiplayer.get_remote_sender_id()
	if (
		not _is_host()
		or not _net_manager.is_gameplay_ingress_admitted(sender_id)
		or occurrence_key != _active_occurrence_key
		or _emergency_reward_session == null
		or expected_revision < 1
		or expected_revision > _emergency_reward_session.get_revision()
	):
		return
	_handle_emergency_reward_completion_retry(
		sender_id
	)


func _handle_emergency_reward_completion_retry(peer_id: int) -> void:
	if (
		_phase != ProtocolPhase.REWARD_SELECTING
		or not _emergency_reward_completion_failure_by_peer.has(peer_id)
	):
		return
	_emergency_reward_completion_failure_by_peer.clear()
	_emergency_reward_completion_retry_requested = true
	_try_complete_host_emergency_rewards()


func _on_emergency_reward_inventory_requested() -> void:
	if (
		_phase != ProtocolPhase.REWARD_SELECTING
		or _combat_game == null
		or not is_instance_valid(_combat_game)
		or _combat_game.player_profile_panel == null
	):
		return
	_combat_game.player_profile_panel.process_mode = Node.PROCESS_MODE_ALWAYS
	_combat_game.player_profile_panel.configure_multiplayer_requests(true)
	_combat_game.player_profile_panel.open()


func _try_complete_host_emergency_rewards() -> void:
	if (
		not _is_host()
		or _phase != ProtocolPhase.REWARD_SELECTING
		or _emergency_reward_session == null
		or not _emergency_reward_session.is_ready_to_settle()
		or not _emergency_reward_completion_retry_requested
	):
		return
	_emergency_reward_completion_retry_requested = false
	var reward_batch := _emergency_reward_session.complete_rewards()
	if not bool(reward_batch.get("resolved", false)):
		for peer_id_variant in reward_batch.get(
			"inventory_full_peer_ids",
			[]
		) as Array:
			_emergency_reward_completion_failure_by_peer[int(peer_id_variant)] = true
		if _emergency_reward_completion_failure_by_peer.is_empty():
			push_error(
				"RogueCombatMultiplayerCoordinator: 紧急奖励事务失败：%s"
				% str(reward_batch.get("failure_reason", "unknown"))
			)
			_abort_authoritative_protocol(&"emergency_reward_transaction_failed")
			return
		_broadcast_emergency_reward_state()
		return
	var results_by_peer := (
		reward_batch.get("results_by_peer", {}) as Dictionary
	).duplicate(true)
	var shared_light_stone_reward := int(reward_batch.get(
		"shared_light_stone_reward",
		0
	))
	for peer_id_variant in results_by_peer.keys():
		var peer_id := int(peer_id_variant)
		var result := (results_by_peer[peer_id_variant] as Dictionary).duplicate(true)
		result["victory"] = true
		result["shared_light_stone_reward"] = shared_light_stone_reward
		results_by_peer[peer_id] = result
	var final_xirang_by_peer := (
		reward_batch.get("final_xirang_by_peer", {}) as Dictionary
	).duplicate(true)
	_apply_xirang_map_to_game(_combat_game, final_xirang_by_peer)
	var settlement := {
		"node_id": _active_node_id,
		"content_seed": _active_content_seed,
		"occurrence_key": _active_occurrence_key,
		"victory": true,
		"failure_reason": "",
		"consume_node": true,
		"final_xirang_by_peer": final_xirang_by_peer,
		"inventory_snapshots_by_peer": (
			reward_batch.get("inventory_snapshots_by_peer", {}) as Dictionary
		).duplicate(true),
		"results_by_peer": results_by_peer,
		"light_stone_ledger": (
			reward_batch.get("light_stone_ledger", {}) as Dictionary
		).duplicate(true),
	}
	if not _publish_host_settlement(
		_active_occurrence_key,
		settlement,
		_emergency_reward_rollback_state
	):
		push_error(
			"RogueCombatMultiplayerCoordinator: 紧急奖励结算发布失败。"
		)


func _reset_emergency_reward_selection() -> void:
	if (
		_emergency_reward_session != null
		and _emergency_reward_session.state_changed.is_connected(
			_on_emergency_reward_session_state_changed
		)
	):
		_emergency_reward_session.state_changed.disconnect(
			_on_emergency_reward_session_state_changed
		)
	_emergency_reward_session = null
	_emergency_reward_client_snapshot.clear()
	_emergency_reward_rollback_state.clear()
	_emergency_reward_completion_failure_by_peer.clear()
	_emergency_reward_completion_retry_requested = false
	if _emergency_reward_overlay != null and is_instance_valid(
		_emergency_reward_overlay
	):
		_emergency_reward_overlay.hide_and_reset()
	if (
		_combat_game != null
		and is_instance_valid(_combat_game)
		and _combat_game.player_profile_panel != null
		and _combat_game.player_profile_panel.is_open()
	):
		_combat_game.player_profile_panel.close()


func _on_local_combat_outcome_started(
	victory: bool,
	failure_reason: String
) -> void:
	if (
		_phase not in [
			ProtocolPhase.ACTIVE,
			ProtocolPhase.REWARD_SELECTING,
			ProtocolPhase.SETTLED,
		]
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
	if victory and _is_active_emergency_reward_encounter():
		if not _begin_host_emergency_reward_selection(occurrence_key):
			push_error(
				"RogueCombatMultiplayerCoordinator: 无法启动紧急奖励选择。"
			)
			_abort_authoritative_protocol(&"emergency_reward_session_failed")
			return
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
		_active_encounter_config.filter_loot_by_character
		== RogueCombatEncounterConfig.Decision.YES
	)
	var reward_dead_players := (
		_active_encounter_config.reward_dead_players_on_victory
		== RogueCombatEncounterConfig.Decision.YES
	)
	var eligible_peer_ids: Array[int] = []
	var reward_players_by_peer: Dictionary = {}
	var base_xirang_by_peer: Dictionary = {}
	_capture_live_combat_xirang()
	for peer_id_variant in _participant_peer_ids.keys():
		var peer_id := int(peer_id_variant)
		var battle_player := _combat_game.get_player_for_peer(peer_id)
		if battle_player == null or not is_instance_valid(battle_player):
			var last_combat_xirang := int(_last_combat_xirang_by_peer.get(
				peer_id,
				_entry_xirang_by_peer.get(peer_id, 0)
			))
			final_xirang_by_peer[peer_id] = last_combat_xirang
			inventory_snapshots_by_peer[peer_id] = (
				_run_state.export_inventory_snapshot_for_peer(peer_id)
			)
			if victory and reward_dead_players:
				eligible_peer_ids.append(peer_id)
				base_xirang_by_peer[peer_id] = last_combat_xirang
			elif victory:
				results_by_peer[peer_id] = _make_unrewarded_victory_result(peer_id)
			else:
				results_by_peer[peer_id] = {
					"victory": false,
					"failure_reason": failure_reason,
					"peer_id": peer_id,
				}
			continue
		var eligible := reward_dead_players or not battle_player.is_dead
		if victory and eligible:
			eligible_peer_ids.append(peer_id)
			reward_players_by_peer[peer_id] = battle_player
			base_xirang_by_peer[peer_id] = battle_player.get_xirang()
		elif victory:
			results_by_peer[peer_id] = _make_unrewarded_victory_result(peer_id)
		else:
			results_by_peer[peer_id] = {
				"victory": false,
				"failure_reason": failure_reason,
				"peer_id": peer_id,
			}
		final_xirang_by_peer[peer_id] = battle_player.get_xirang()

	if victory and not eligible_peer_ids.is_empty():
		var reward_batch := RogueCombatRewardResolver.resolve_party_rewards(
			_run_state,
			StringName(occurrence_key),
			_active_content_seed,
			eligible_peer_ids,
			_active_encounter_config.reward_config,
			filter_by_character,
			reward_players_by_peer,
			base_xirang_by_peer,
			_participant_stable_keys,
			_participant_character_ids
		)
		if not bool(reward_batch.get("resolved", false)):
			push_error(
				"RogueCombatMultiplayerCoordinator: 全队奖励原子结算失败：%s"
				% str(reward_batch.get("failure_reason", "unknown"))
			)
			_abort_authoritative_protocol(&"reward_transaction_failed")
			return
		var rewarded_results := reward_batch.get("results_by_peer", {}) as Dictionary
		var rewarded_xirang := (
			reward_batch.get("final_xirang_by_peer", {}) as Dictionary
		)
		for peer_id in eligible_peer_ids:
			if (
				not rewarded_results.has(peer_id)
				or not rewarded_results[peer_id] is Dictionary
				or not rewarded_xirang.has(peer_id)
			):
				push_error(
					"RogueCombatMultiplayerCoordinator: 奖励事务缺少玩家%d结果。"
					% peer_id
				)
				if not _rollback_host_reward_mutations(reward_rollback_state):
					push_error(
						"RogueCombatMultiplayerCoordinator: 缺失奖励结果后的回滚失败。"
					)
				_abort_authoritative_protocol(&"reward_result_missing")
				return
			var result := (rewarded_results[peer_id] as Dictionary).duplicate(true)
			result["victory"] = true
			results_by_peer[peer_id] = result
			final_xirang_by_peer[peer_id] = int(rewarded_xirang[peer_id])
		_apply_xirang_map_to_game(_combat_game, rewarded_xirang)

	# 奖励 CAS 完成后统一导出正式快照，避免 settlement 携带奖励前的 revision。
	for peer_id_variant in _participant_peer_ids.keys():
		var peer_id := int(peer_id_variant)
		inventory_snapshots_by_peer[peer_id] = (
			_run_state.export_inventory_snapshot_for_peer(peer_id)
		)

	var consume_node := victory or (
		_active_encounter_config.consume_node_on_failure
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


## 激活后的协议中止不能回到战前余额。Host 先把每名参与者的 staged
## 战斗余额与当前背包发布成 consume_node=false 的终局结算，再允许拆战场。
func _publish_host_abort_settlement(
	occurrence_key: String,
	reason: StringName
) -> bool:
	if (
		not _is_host()
		or occurrence_key.is_empty()
		or occurrence_key != _active_occurrence_key
		or _run_state == null
		or _participant_peer_ids.is_empty()
	):
		return false
	_capture_live_combat_xirang()
	var final_xirang_by_peer: Dictionary = {}
	var inventory_snapshots_by_peer: Dictionary = {}
	var results_by_peer: Dictionary = {}
	for peer_id_variant in _participant_peer_ids.keys():
		var peer_id := int(peer_id_variant)
		var inventory_snapshot := (
			_run_state.export_inventory_snapshot_for_peer(peer_id)
		)
		if inventory_snapshot.is_empty():
			return false
		final_xirang_by_peer[peer_id] = int(
			_last_combat_xirang_by_peer.get(
				peer_id,
				_entry_xirang_by_peer.get(peer_id, 0)
			)
		)
		inventory_snapshots_by_peer[peer_id] = inventory_snapshot
		results_by_peer[peer_id] = {
			"victory": false,
			"failure_reason": String(reason),
			"peer_id": peer_id,
		}
	var settlement := {
		"node_id": _active_node_id,
		"content_seed": _active_content_seed,
		"occurrence_key": occurrence_key,
		"victory": false,
		"failure_reason": String(reason),
		"consume_node": false,
		"final_xirang_by_peer": final_xirang_by_peer,
		"inventory_snapshots_by_peer": inventory_snapshots_by_peer,
		"results_by_peer": results_by_peer,
	}
	return _publish_host_settlement(occurrence_key, settlement)


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
	_poll_pending_terminal_spectator_syncs()
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
		"party_xirang_by_peer": _get_party_xirang_balances_for_participants(),
		"light_stone_ledger": _run_state.export_party_light_stone_ledger(),
	}


func _rollback_host_reward_mutations(rollback_state: Dictionary) -> bool:
	if (
		not _is_host()
		or _run_state == null
		or typeof(rollback_state.get("inventory_snapshots_by_peer"))
		!= TYPE_DICTIONARY
		or typeof(rollback_state.get("combat_xirang_by_peer"))
		!= TYPE_DICTIONARY
		or typeof(rollback_state.get("party_xirang_by_peer"))
		!= TYPE_DICTIONARY
		or typeof(rollback_state.get("light_stone_ledger"))
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
	if not _run_state.set_party_xirang_balances(
		rollback_state["party_xirang_by_peer"] as Dictionary
	):
		return false
	var light_rollback := (
		rollback_state["light_stone_ledger"] as Dictionary
	).duplicate(true)
	light_rollback["revision"] = (
		_run_state.get_party_light_stone_ledger_revision() + 1
	)
	return _run_state.apply_party_light_stone_ledger(light_rollback)


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
		_reconnected_member_ready_outcomes.erase(peer_id)
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
		_apply_route_spectator_settlement(
			occurrence_key,
			settlement,
			_route_spectator_participant_peer_ids
		)


func _apply_route_spectator_settlement(
	occurrence_key: String,
	settlement: Dictionary,
	restore_participant_peer_ids: Dictionary
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
		or typeof(settlement.get("party_xirang_ledger")) != TYPE_DICTIONARY
		or (
			settlement.has("light_stone_ledger")
			and typeof(settlement.get("light_stone_ledger")) != TYPE_DICTIONARY
		)
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
	var resolved_restore_participants := (
		restore_participant_peer_ids.duplicate()
	)
	if resolved_restore_participants.is_empty():
		# fresh reconnect 进程没有旧 ACTIVE roster；此时只允许从 Host 已完整
		# 校验且三张 exact-key map 一致的 settlement 冻结参与者集合。
		for raw_peer_id in final_xirang.keys():
			resolved_restore_participants[int(raw_peer_id)] = true
	elif resolved_restore_participants.size() != final_xirang.size():
		return false
	for raw_peer_id in resolved_restore_participants.keys():
		if (
			typeof(raw_peer_id) != TYPE_INT
			or typeof(resolved_restore_participants[raw_peer_id]) != TYPE_BOOL
			or not bool(resolved_restore_participants[raw_peer_id])
			or not final_xirang.has(int(raw_peer_id))
		):
			return false
	if not resolved_restore_participants.has(local_peer_id):
		# pure late-join spectator 不在结算 participant maps 中，不能由空集合
		# 退回“恢复全部 Player”。
		return false
	if not _apply_authoritative_settlement_economy(
		final_xirang,
		inventory_snapshots,
		settlement["party_xirang_ledger"] as Dictionary,
		settlement.get("light_stone_ledger", {}) as Dictionary
	):
		return false
	_apply_xirang_map_to_route(final_xirang)
	if bool(settlement["consume_node"]):
		var node_id := int(settlement.get("node_id", INVALID_NODE_ID))
		if node_id >= 0:
			_consumed_node_ids[node_id] = true
	if not _route.restore_players_for_route_scene_entry(
		resolved_restore_participants
	):
		push_error("Rogue 路线观战结算无法恢复完整玩家成长边界。")
		return false
	_route.complete_normal_combat(occurrence_key)
	_route.set_route_presentation_enabled(true)
	_route_spectator_occurrence_key = ""
	_route_spectator_participant_peer_ids.clear()
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
		or (
			not _is_host()
			and typeof(settlement.get("party_xirang_ledger"))
			!= TYPE_DICTIONARY
		)
		or (
			settlement.has("party_xirang_ledger")
			and typeof(settlement.get("party_xirang_ledger"))
			!= TYPE_DICTIONARY
		)
		or (
			settlement.has("light_stone_ledger")
			and typeof(settlement.get("light_stone_ledger")) != TYPE_DICTIONARY
		)
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
		inventory_snapshots,
		settlement.get("party_xirang_ledger", {}) as Dictionary,
		settlement.get("light_stone_ledger", {}) as Dictionary
	):
		return false
	if _is_host():
		# Host 先提交 staged 余额，再把这一次真实的权威 revision
		# 写入结算载荷；Client 不再本地猜测 revision。
		settlement["party_xirang_ledger"] = (
			_run_state.export_party_xirang_ledger()
		)
	_apply_xirang_map_to_game(_combat_game, final_xirang)
	_apply_xirang_map_to_route(final_xirang)
	if _emergency_reward_overlay != null:
		_emergency_reward_overlay.hide_and_reset()
	if (
		_combat_game != null
		and is_instance_valid(_combat_game)
		and _combat_game.player_profile_panel != null
		and _combat_game.player_profile_panel.is_open()
	):
		_combat_game.player_profile_panel.close()
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
	inventory_snapshots: Dictionary,
	party_xirang_ledger: Dictionary,
	light_stone_ledger: Dictionary = {}
) -> bool:
	if not _is_host():
		if (
			party_xirang_ledger.is_empty()
			or not _does_xirang_ledger_match_settlement(
				party_xirang_ledger,
				final_xirang
			)
		):
			return false
		var peer_ids := PackedInt32Array()
		for peer_id_variant in inventory_snapshots.keys():
			peer_ids.append(int(peer_id_variant))
		peer_ids.sort()
		var party_snapshot := _run_state.export_party_economy_snapshot(peer_ids)
		var inventories: Array[Dictionary] = []
		for peer_id in peer_ids:
			if (
				not inventory_snapshots.has(peer_id)
				or not inventory_snapshots[peer_id] is Dictionary
			):
				return false
			inventories.append(
				(inventory_snapshots[peer_id] as Dictionary).duplicate(true)
			)
		party_snapshot["inventories"] = inventories
		party_snapshot["xirang_ledger"] = party_xirang_ledger.duplicate(true)
		if not light_stone_ledger.is_empty():
			party_snapshot["light_stone_ledger"] = (
				light_stone_ledger.duplicate(true)
			)
		# 三类战利品先按完整 Party Economy 一次预检，再一次提交。
		if not _run_state.validate_party_economy_snapshot(party_snapshot):
			return false
		return _run_state.apply_party_economy_snapshot(party_snapshot)
	if (
		not light_stone_ledger.is_empty()
		and _run_state.export_party_light_stone_ledger() != light_stone_ledger
	):
		return false
	return _run_state.set_party_xirang_balances(final_xirang)


func _does_xirang_ledger_match_settlement(
	ledger: Dictionary,
	final_xirang: Dictionary
) -> bool:
	if (
		typeof(ledger.get("schema_version")) != TYPE_INT
		or typeof(ledger.get("revision")) != TYPE_INT
		or int(ledger.get("revision", -1)) < 0
		or typeof(ledger.get("values")) != TYPE_DICTIONARY
	):
		return false
	var values := ledger["values"] as Dictionary
	for peer_id_variant in final_xirang.keys():
		var peer_id := int(peer_id_variant)
		var key := str(peer_id)
		if (
			peer_id <= 0
			or not values.has(key)
			or typeof(values[key]) != TYPE_INT
			or int(values[key]) != int(final_xirang[peer_id_variant])
		):
			return false
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
	_local_result_participant_peer_ids = _participant_peer_ids.duplicate()
	_local_result_visible = false
	_local_route_returned = false

	var victory := bool(_pending_settlement.get("victory", false))
	if victory:
		_play_local_victory_terminal(_active_occurrence_key)
		return
	var should_show_result := victory or (
		_active_encounter_config.show_failure_result
		== RogueCombatEncounterConfig.Decision.YES
	)
	var return_before_result := (
		_active_encounter_config.return_to_route_before_result
		== RogueCombatEncounterConfig.Decision.YES
	)
	if return_before_result or not should_show_result:
		if not _return_to_route_local():
			return
	if should_show_result:
		if not _show_local_result():
			if not _return_to_route_local():
				return
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
	if not _return_to_route_local():
		_abort_interrupted_victory_terminal(occurrence_key)
		return
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


## 权威全快照已经同时携带路线与结算后的持久账本；这里只释放旧本地
## 战场协议，禁止再调用 Route.abort_briefing_entry 清掉刚提交的新 Briefing。
func _on_route_normal_combat_snapshot_reconciled(
	occurrence_key: String
) -> void:
	if (
		not occurrence_key.is_empty()
		and occurrence_key == _route_spectator_occurrence_key
	):
		_route_spectator_occurrence_key = ""
		return
	if (
		_phase == ProtocolPhase.IDLE
		or occurrence_key.is_empty()
		or occurrence_key != _active_occurrence_key
	):
		return
	_interrupt_terminal_presentation()
	prepare_active_runtime_for_scene_teardown()
	if _combat_network != null and is_instance_valid(_combat_network):
		_combat_network.queue_free()
	_combat_network = null
	_combat_game = null
	_reset_protocol_state()


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
	var sender_id := multiplayer.get_remote_sender_id()
	if (
		not _is_host()
		or not _is_gameplay_ingress_admitted(sender_id)
		or not _settlement_received
		or occurrence_key != _active_occurrence_key
	):
		return
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
	if not _show_route_combat_result(result):
		return false
	_local_result_visible = true
	return true


func _show_route_combat_result(result: Dictionary) -> bool:
	if _route == null or not is_instance_valid(_route):
		return false
	if not _route.show_combat_result(result):
		return false
	if (
		bool(result.get("victory", false))
		and not (result.get("item_rewards", []) as Array).is_empty()
		and _route.combat_result_overlay != null
	):
		_route.combat_result_overlay.present_reward_result(result)
	return true


func _on_combat_result_dismissed() -> void:
	if not _local_result_visible:
		return
	_local_result_visible = false
	_route.hide_combat_result()
	if not _local_route_returned:
		if not _return_to_route_local():
			return
	_clear_local_result_lifecycle()


func _return_to_route_local() -> bool:
	if _local_route_returned:
		return true
	if _route == null or not is_instance_valid(_route):
		return false
	# settlement 已先提交 economy；此处再绝对恢复所有现存路线 Player，
	# 成功后才切相机/显现路线，避免玩家看到一帧旧面板或异常状态。
	var restore_participants := (
		_local_result_participant_peer_ids
		if not _local_result_participant_peer_ids.is_empty()
		else _participant_peer_ids
	)
	if not _route.restore_players_for_route_scene_entry(restore_participants):
		return false
	_local_route_returned = true
	_set_combat_presentation_visible(false)
	_route.complete_normal_combat(_local_result_occurrence_key)
	_route.set_route_presentation_enabled(true)
	return true


func _stop_local_combat_processing() -> void:
	if _combat_network == null or not is_instance_valid(_combat_network):
		return
	# Host 停止继续发战场快照；客户端仍保留稳定 RPC NodePath，直至
	# 所有参战端均确认已收到 outcome + settlement。
	_combat_network.process_mode = TERMINAL_PROCESS_MODE


func _set_combat_presentation_visible(visible: bool) -> void:
	if _combat_game != null and is_instance_valid(_combat_game):
		# 隐藏 Node2D 不会释放其 Camera2D 的 Viewport 所有权；终局安全
		# 屏障期间 runtime 仍会留树，必须先显式停用战斗相机再恢复路线。
		_combat_game.presentation_camera.enabled = visible
	if _combat_network != null and is_instance_valid(_combat_network):
		_combat_network.visible = visible


func prepare_active_runtime_for_scene_teardown() -> void:
	var runtime := _combat_game as CombatRuntimeBase
	if (
		(runtime == null or not is_instance_valid(runtime))
		and _combat_network != null
		and is_instance_valid(_combat_network)
	):
		runtime = _combat_network.get_game_runtime()
	if runtime != null and is_instance_valid(runtime):
		runtime.prepare_for_scene_teardown()


func _try_release_local_runtime() -> void:
	if not _terminal_safe_received:
		return
	prepare_active_runtime_for_scene_teardown()
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
		if not _return_to_route_local():
			return
	_clear_local_result_lifecycle()


func _clear_local_result_lifecycle() -> void:
	_local_result_visible = false
	_local_route_returned = false
	_local_result_occurrence_key = ""
	_local_result_participant_peer_ids.clear()


func _reset_protocol_state() -> void:
	_interrupt_terminal_presentation()
	_reset_emergency_reward_selection()
	_phase = ProtocolPhase.IDLE
	_active_node_id = INVALID_NODE_ID
	_active_content_seed = 0
	_active_occurrence_key = ""
	_active_combat_config_id = &""
	_active_encounter_config = null
	_active_config_signature = ""
	_participant_peer_ids.clear()
	_route_spectator_participant_peer_ids.clear()
	_entry_xirang_by_peer.clear()
	_participant_character_ids.clear()
	_participant_stable_keys.clear()
	_participant_incarnations.clear()
	_last_combat_xirang_by_peer.clear()
	_disconnected_participants.clear()
	_reconnecting_peer_ids.clear()
	_pending_reconnect_prepare_peers.clear()
	_reconnected_member_ready_outcomes.clear()
	_pending_reconnected_identity_resolutions.clear()
	_resolved_reconnected_identity_resolutions.clear()
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
	if not _is_gameplay_ingress_admitted(sender_id):
		return
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
			_phase in [
				ProtocolPhase.ACTIVE,
				ProtocolPhase.REWARD_SELECTING,
				ProtocolPhase.SETTLED,
			]
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


## 激活确认只能消费 Host 已实际发出的本次 prepare 租约。身份已提交但尚未
## 进入 PREPARING_DELIVERY 的玩家即使知道 occurrence_key，也不能提前关闭恢复窗口。
func _is_dispatched_reconnect_prepare(
	peer_id: int,
	occurrence_key: String
) -> bool:
	if not _is_pending_reconnect_prepare(peer_id, occurrence_key):
		return false
	var pending := (
		_pending_reconnect_prepare_peers.get(peer_id, {}) as Dictionary
	)
	return bool(pending.get("prepare_dispatched", false))


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
	var activated_combat := (
		_local_runtime_activated
		or _phase in [
			ProtocolPhase.ACTIVE,
			ProtocolPhase.REWARD_SELECTING,
			ProtocolPhase.SETTLED,
		]
	)
	if activated_combat and not _settlement_received:
		if _abort_settlement_in_progress:
			return
		_abort_settlement_in_progress = true
		var abort_settled := _publish_host_abort_settlement(
			occurrence_key,
			reason
		)
		_abort_settlement_in_progress = false
		if not abort_settled:
			push_error(
				"RogueCombatMultiplayerCoordinator: 激活战斗中止结算失败，拒绝拆除。"
			)
			return
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
	var activated_combat := (
		_local_runtime_activated
		or _phase in [
			ProtocolPhase.ACTIVE,
			ProtocolPhase.REWARD_SELECTING,
			ProtocolPhase.SETTLED,
		]
	)
	if activated_combat:
		if not _settlement_received:
			push_error("Rogue 多人激活战斗缺少终局结算，拒绝执行协议中止拆除。")
			return
		if (
			_route == null
			or not is_instance_valid(_route)
			or not _route.restore_players_for_route_scene_entry(
				_participant_peer_ids
			)
		):
			push_error("Rogue 多人协议中止无法恢复路线 Player，拒绝拆除战场。")
			return
	prepare_active_runtime_for_scene_teardown()
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
	_reconnected_member_ready_outcomes.erase(peer_id)
	_clear_pending_reconnected_identity_resolution(peer_id)
	if _phase == ProtocolPhase.IDLE or peer_id <= 0:
		return
	_pending_reconnect_prepare_peers.erase(peer_id)
	if not _participant_peer_ids.has(peer_id):
		return
	_mark_participant_disconnected_from_barriers(peer_id)
	if _is_host():
		if _phase == ProtocolPhase.PREPARING:
			_try_activate_host_barrier()
		elif (
			_phase == ProtocolPhase.REWARD_SELECTING
			and _emergency_reward_session != null
		):
			_emergency_reward_session.mark_peer_disconnected(
				peer_id,
				_active_occurrence_key
			)
			_try_complete_host_emergency_rewards()
		elif _phase == ProtocolPhase.SETTLED:
			_try_broadcast_safe_teardown()


func _mark_participant_disconnected_from_barriers(peer_id: int) -> void:
	if peer_id <= 0 or not _participant_peer_ids.has(peer_id):
		return
	_capture_live_combat_xirang(peer_id)
	_disconnected_participants[peer_id] = {
		"entry_xirang": int(_entry_xirang_by_peer.get(peer_id, 0)),
		"last_combat_xirang": int(_last_combat_xirang_by_peer.get(
			peer_id,
			_entry_xirang_by_peer.get(peer_id, 0)
		)),
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
	_route_spectator_participant_peer_ids.clear()
	_route.hide_combat_entry_transition()
	_route.set_route_presentation_enabled(true)


func _release_local_combat_to_route_spectator(occurrence_key: String) -> void:
	if (
		occurrence_key.is_empty()
		or occurrence_key != _active_occurrence_key
	):
		return
	prepare_active_runtime_for_scene_teardown()
	if _combat_network != null and is_instance_valid(_combat_network):
		_combat_network.queue_free()
	var received_settlement := (
		_pending_settlement.duplicate(true)
		if _settlement_received
		else {}
	)
	# reset 会清除活跃 participant；必须先冻结本场的精确集合并显式传入
	# 结算恢复，pure late-join spectator 永远不会取得这份治疗租约。
	var restore_participant_peer_ids := _participant_peer_ids.duplicate()
	_combat_network = null
	_combat_game = null
	_route.hide_combat_entry_transition()
	_reset_protocol_state()
	_route_spectator_occurrence_key = occurrence_key
	_route_spectator_participant_peer_ids = (
		restore_participant_peer_ids.duplicate()
	)
	if not received_settlement.is_empty():
		if not _apply_route_spectator_settlement(
			occurrence_key,
			received_settlement,
			restore_participant_peer_ids
		):
			push_error("Rogue 终局观战者无法应用结算并恢复路线 Player。")
		return
	# 尚在进行中的战斗把该成员降级为旁观者时，不构造虚假的治疗边界。
	_route.set_route_presentation_enabled(true)


## 只由 MpRogueRoute 在 RunState、路线 Player 与稳定参与者身份全部提交后调用。
## raw peer 是作战结算的规范地址，因此这里立即 old -> new；Player 投影能力
## 仍由 _reconnecting_peer_ids 关闭，直到明确 RESTORED/SUSPENDED/FAILED。
func handle_reconnected_identity_committed(
	old_peer_id: int,
	new_peer_id: int
) -> bool:
	if old_peer_id <= 0 or new_peer_id <= 0 or old_peer_id == new_peer_id:
		return false
	_pending_spectator_peers.erase(new_peer_id)
	var resolved := (
		_resolved_reconnected_identity_resolutions.get(new_peer_id, {})
		as Dictionary
	)
	var pending_replay := (
		_pending_reconnected_identity_resolutions.get(new_peer_id, {})
		as Dictionary
	)
	if (
		_participant_peer_ids.has(new_peer_id)
		and not _participant_peer_ids.has(old_peer_id)
		and int(pending_replay.get("old_peer_id", 0)) == old_peer_id
		and bool(pending_replay.get("route_committed", false))
	):
		# PROJECTING 中的 route 重放只确认同一事务；能力门必须继续保持。
		return true
	if (
		_participant_peer_ids.has(new_peer_id)
		and not _participant_peer_ids.has(old_peer_id)
		and int(resolved.get("old_peer_id", 0)) == old_peer_id
	):
		# 已完成事务的 route 重放不能重开 PROJECTING，也不能撤销既有能力门。
		return true
	if _phase == ProtocolPhase.IDLE:
		_reconnecting_peer_ids[new_peer_id] = true
		if _is_host() and not _local_result_occurrence_key.is_empty():
			call_deferred(
				"_send_terminal_reconnect_spectator",
				new_peer_id,
				_local_result_occurrence_key
			)
		else:
			_reconnecting_peer_ids.erase(new_peer_id)
		return true
	var pending := _get_reconnected_identity_resolution(
		old_peer_id,
		new_peer_id
	)
	if pending.is_empty():
		return false
	if not pending.has("requires_projection"):
		pending["requires_projection"] = (
			_reconnect_requires_embedded_player_projection(old_peer_id)
		)
	var expected_incarnation := int(
		_participant_incarnations.get(old_peer_id, 0)
	)
	if expected_incarnation <= 0 and _net_manager != null:
		expected_incarnation = (
			_net_manager.get_session_participant_incarnation(old_peer_id)
		)
	if expected_incarnation <= 0:
		push_error(
			"RogueCombatMultiplayerCoordinator: 无法确认参战者 %d 的 incarnation。"
			% old_peer_id
		)
		return false
	pending["participant_incarnation"] = expected_incarnation
	var disconnected_record := _commit_reconnected_participant_identity(
		old_peer_id,
		new_peer_id
	)
	if disconnected_record.is_empty():
		return false
	pending["disconnected_record"] = disconnected_record.duplicate(true)
	pending["route_committed"] = true
	if (
		not bool(pending.get("requires_projection", false))
		and int(pending.get("projection_outcome", -1)) < 0
	):
		pending["projection_outcome"] = int(
			MultiplayerGameplaySession.ReconnectedPlayerProjectionOutcome.SUSPENDED
		)
		pending["first_projection_outcome"] = int(
			MultiplayerGameplaySession.ReconnectedPlayerProjectionOutcome.SUSPENDED
		)
	_pending_reconnected_identity_resolutions[new_peer_id] = pending
	_try_resolve_reconnected_identity(new_peer_id)
	return true


## 外层路线用该纯查询决定本次 ready 是否还必须等待内嵌 MpGame 的 Player
## 投影终态；不能通过“当前是否恰好有 Player 节点”猜测监听顺序。
func reconnect_requires_embedded_player_projection(old_peer_id: int) -> bool:
	return _reconnect_requires_embedded_player_projection(old_peer_id)


func _on_embedded_reconnected_player_projection_resolved(
	old_peer_id: int,
	new_peer_id: int,
	outcome: MultiplayerGameplaySession.ReconnectedPlayerProjectionOutcome
) -> void:
	if (
		old_peer_id <= 0
		or new_peer_id <= 0
		or old_peer_id == new_peer_id
		or outcome not in [
			MultiplayerGameplaySession.ReconnectedPlayerProjectionOutcome.RESTORED,
			MultiplayerGameplaySession.ReconnectedPlayerProjectionOutcome.SUSPENDED,
			MultiplayerGameplaySession.ReconnectedPlayerProjectionOutcome.FAILED,
		]
	):
		return
	if _resolved_reconnected_identity_resolutions.has(new_peer_id):
		_handle_resolved_projection_outcome_replay(
			old_peer_id,
			new_peer_id,
			int(outcome)
		)
		return
	var has_pending_resolution := (
		_pending_reconnected_identity_resolutions.has(new_peer_id)
	)
	if (
		not has_pending_resolution
		and not _can_admit_outcome_first_reconnect(old_peer_id, new_peer_id)
	):
		# component 结果可先于 route 监听者，但只能为 NetManager 当前同一
		# incarnation 的 RECONNECTING 成员建事务；迟到的旧 hop 直接丢弃。
		return
	_pending_spectator_peers.erase(new_peer_id)
	_reconnecting_peer_ids[new_peer_id] = true
	var pending := _get_reconnected_identity_resolution(
		old_peer_id,
		new_peer_id
	)
	if pending.is_empty():
		return
	if not pending.has("requires_projection"):
		pending["requires_projection"] = true
	if not pending.has("participant_incarnation"):
		pending["participant_incarnation"] = int(
			_participant_incarnations.get(old_peer_id, 0)
		)
	pending = _merge_reconnected_projection_outcome(
		pending,
		old_peer_id,
		new_peer_id,
		int(outcome)
	)
	_pending_reconnected_identity_resolutions[new_peer_id] = pending
	_try_resolve_reconnected_identity(new_peer_id)


func _get_reconnected_identity_resolution(
	old_peer_id: int,
	new_peer_id: int
) -> Dictionary:
	if old_peer_id <= 0 or new_peer_id <= 0 or old_peer_id == new_peer_id:
		return {}
	var pending := (
		_pending_reconnected_identity_resolutions.get(new_peer_id, {})
		as Dictionary
	).duplicate(true)
	if pending.is_empty():
		return {
			"old_peer_id": old_peer_id,
			"route_committed": false,
			"projection_outcome": -1,
			"first_projection_outcome": -1,
		}
	if int(pending.get("old_peer_id", 0)) != old_peer_id:
		push_error(
			"RogueCombatMultiplayerCoordinator: new peer %d 同时等待 old peer %d/%d。"
			% [new_peer_id, int(pending.get("old_peer_id", 0)), old_peer_id]
		)
		return {}
	return pending


func _can_admit_outcome_first_reconnect(
	old_peer_id: int,
	new_peer_id: int
) -> bool:
	if (
		_net_manager == null
		or not _reconnect_requires_embedded_player_projection(old_peer_id)
		or not _net_manager.is_session_member_reconnecting(new_peer_id)
	):
		return false
	var expected_incarnation := int(
		_participant_incarnations.get(old_peer_id, 0)
	)
	var current_incarnation := (
		_net_manager.get_session_participant_incarnation(new_peer_id)
	)
	return (
		expected_incarnation > 0
		and current_incarnation == expected_incarnation
	)


## 投影终态是一次性 CAS：相同值是可靠重放，不同值永远不能把 FAILED 或
## SUSPENDED 升回 RESTORED。独立 owner fail-close，外层 owner 降级旁观。
func _merge_reconnected_projection_outcome(
	pending: Dictionary,
	old_peer_id: int,
	new_peer_id: int,
	outcome: int
) -> Dictionary:
	var current_outcome := int(pending.get("first_projection_outcome", -1))
	if current_outcome < 0:
		pending["first_projection_outcome"] = outcome
		pending["projection_outcome"] = outcome
		if (
			outcome
			== MultiplayerGameplaySession.ReconnectedPlayerProjectionOutcome.FAILED
			and _session_projection_owner == SessionProjectionOwner.THIS_COORDINATOR
		):
			pending["fail_close_required"] = true
		return pending
	if current_outcome == outcome:
		return pending
	push_error(
		"RogueCombatMultiplayerCoordinator: 重连投影终态冲突，old=%d new=%d first=%d replay=%d。"
		% [old_peer_id, new_peer_id, current_outcome, outcome]
	)
	pending["projection_conflicted"] = true
	if _session_projection_owner == SessionProjectionOwner.THIS_COORDINATOR:
		pending["projection_outcome"] = int(
			MultiplayerGameplaySession.ReconnectedPlayerProjectionOutcome.FAILED
		)
		pending["fail_close_required"] = true
	else:
		pending["projection_outcome"] = int(
			MultiplayerGameplaySession.ReconnectedPlayerProjectionOutcome.SUSPENDED
		)
	return pending


func _try_resolve_reconnected_identity(new_peer_id: int) -> void:
	var pending := (
		_pending_reconnected_identity_resolutions.get(new_peer_id, {})
		as Dictionary
	)
	if (
		pending.is_empty()
		or not bool(pending.get("route_committed", false))
		or int(pending.get("projection_outcome", -1)) < 0
	):
		return
	var old_peer_id := int(pending.get("old_peer_id", 0))
	var outcome := int(pending.get("projection_outcome", -1))
	var resolved_record := pending.duplicate(true)
	resolved_record["effective_outcome"] = outcome
	if (
		outcome
		== MultiplayerGameplaySession.ReconnectedPlayerProjectionOutcome.FAILED
		and _session_projection_owner == SessionProjectionOwner.THIS_COORDINATOR
	):
		resolved_record["fail_close_dispatched"] = true
	_resolved_reconnected_identity_resolutions[new_peer_id] = resolved_record
	_pending_reconnected_identity_resolutions.erase(new_peer_id)
	if outcome == (
		MultiplayerGameplaySession.ReconnectedPlayerProjectionOutcome.FAILED
	):
		if _session_projection_owner == SessionProjectionOwner.THIS_COORDINATOR:
			if not bool(pending.get("fail_close_dispatched", false)):
				_fail_close_owned_projection(
					old_peer_id,
					new_peer_id,
					"独立路线无法恢复重连 Player 投影。"
				)
		else:
			# 塔防外层 Player 已恢复时，内嵌战斗失败只会把本轮作战降级为
			# spectator；不得让一个组件越过外层聚合器终止整个会话。
			_finish_player_reconnected(
				old_peer_id,
				new_peer_id,
				MultiplayerGameplaySession.ReconnectedPlayerProjectionOutcome.SUSPENDED
			)
		return
	_finish_player_reconnected(old_peer_id, new_peer_id, outcome)
	if _session_projection_owner == SessionProjectionOwner.THIS_COORDINATOR:
		_report_session_projection_outcome(
			old_peer_id,
			new_peer_id,
			outcome
		)


func _handle_resolved_projection_outcome_replay(
	old_peer_id: int,
	new_peer_id: int,
	outcome: int
) -> void:
	var resolved := (
		_resolved_reconnected_identity_resolutions.get(new_peer_id, {})
		as Dictionary
	).duplicate(true)
	if resolved.is_empty() or int(resolved.get("old_peer_id", 0)) != old_peer_id:
		return
	if int(resolved.get("first_projection_outcome", -1)) == outcome:
		return
	if bool(resolved.get("replay_conflict_handled", false)):
		return
	push_error(
		"RogueCombatMultiplayerCoordinator: 已完成重连收到冲突投影，old=%d new=%d first=%d replay=%d。"
		% [
			old_peer_id,
			new_peer_id,
			int(resolved.get("first_projection_outcome", -1)),
			outcome,
		]
	)
	resolved["replay_conflict_handled"] = true
	if _session_projection_owner == SessionProjectionOwner.THIS_COORDINATOR:
		resolved["effective_outcome"] = int(
			MultiplayerGameplaySession.ReconnectedPlayerProjectionOutcome.FAILED
		)
		var should_fail_close := not bool(
			resolved.get("fail_close_dispatched", false)
		)
		resolved["fail_close_dispatched"] = true
		_resolved_reconnected_identity_resolutions[new_peer_id] = resolved
		if should_fail_close:
			_fail_close_owned_projection(
				old_peer_id,
				new_peer_id,
				"已完成的独立路线重连收到冲突的 Player 投影终态。"
			)
		return
	resolved["effective_outcome"] = int(
		MultiplayerGameplaySession.ReconnectedPlayerProjectionOutcome.SUSPENDED
	)
	_resolved_reconnected_identity_resolutions[new_peer_id] = resolved
	var disconnected_record := (
		resolved.get("disconnected_record", {}) as Dictionary
	).duplicate(true)
	_keep_reconnected_participant_as_spectator(
		old_peer_id,
		new_peer_id,
		disconnected_record
	)


func _fail_close_owned_projection(
	old_peer_id: int,
	new_peer_id: int,
	reason: String
) -> bool:
	if _net_manager == null:
		return false
	if _is_host():
		return _report_session_projection_outcome(
			old_peer_id,
			new_peer_id,
			MultiplayerGameplaySession.ReconnectedPlayerProjectionOutcome.FAILED
		)
	# Client 没有会话级报告权；本地视图已经不可证明收敛，必须退出整局。
	return _net_manager.terminate_for_session_membership_projection_failure(reason)


func _report_session_projection_outcome(
	old_peer_id: int,
	new_peer_id: int,
	outcome: MultiplayerGameplaySession.ReconnectedPlayerProjectionOutcome
) -> bool:
	if _net_manager == null:
		return false
	if not _is_host():
		if outcome == (
			MultiplayerGameplaySession.ReconnectedPlayerProjectionOutcome.FAILED
		):
			return _net_manager.terminate_for_session_membership_projection_failure(
				"独立路线无法提交本地重连 Player 投影。"
			)
		return true
	if _net_manager.report_reconnected_runtime_projection(
		old_peer_id,
		new_peer_id,
		outcome
	):
		return true
	push_error(
		"RogueCombatMultiplayerCoordinator: 会话聚合器拒绝重连投影终态，"
		+ "old=%d new=%d outcome=%d。" % [old_peer_id, new_peer_id, outcome]
	)
	_net_manager.terminate_for_runtime_projection_failure(
		new_peer_id,
		"路线作战无法提交唯一的重连投影终态。"
	)
	return false


func _reconnect_requires_embedded_player_projection(old_peer_id: int) -> bool:
	return (
		old_peer_id > 0
		and not _terminal_safe_broadcast
		and _phase in [ProtocolPhase.PREPARING, ProtocolPhase.ACTIVE]
		and (
			_participant_peer_ids.has(old_peer_id)
			or _disconnected_participants.has(old_peer_id)
		)
	)


func _clear_pending_reconnected_identity_resolution(peer_id: int) -> void:
	if peer_id <= 0:
		return
	_reconnecting_peer_ids.erase(peer_id)
	_reconnected_member_ready_outcomes.erase(peer_id)
	for new_peer_id_variant in (
		_pending_reconnected_identity_resolutions.keys().duplicate()
	):
		var new_peer_id := int(new_peer_id_variant)
		var pending := (
			_pending_reconnected_identity_resolutions[new_peer_id] as Dictionary
		)
		if (
			new_peer_id == peer_id
			or int(pending.get("old_peer_id", 0)) == peer_id
		):
			_pending_reconnected_identity_resolutions.erase(new_peer_id)
			_reconnecting_peer_ids.erase(new_peer_id)
	for new_peer_id_variant in (
		_resolved_reconnected_identity_resolutions.keys().duplicate()
	):
		var new_peer_id := int(new_peer_id_variant)
		var resolved := (
			_resolved_reconnected_identity_resolutions[new_peer_id] as Dictionary
		)
		if (
			new_peer_id == peer_id
			or int(resolved.get("old_peer_id", 0)) == peer_id
		):
			_resolved_reconnected_identity_resolutions.erase(new_peer_id)


func _finish_player_reconnected(
	old_peer_id: int,
	new_peer_id: int,
	projection_outcome: int = (
		MultiplayerGameplaySession.ReconnectedPlayerProjectionOutcome.RESTORED
	)
) -> void:
	if (
		_phase == ProtocolPhase.IDLE
		or old_peer_id <= 0
		or new_peer_id <= 0
	):
		_reconnecting_peer_ids.erase(new_peer_id)
		if _is_host() and _phase != ProtocolPhase.IDLE:
			_pending_spectator_peers[new_peer_id] = true
			call_deferred("_defer_route_spectator_sync", new_peer_id)
		return
	var disconnected_record: Dictionary = {}
	if (
		_participant_peer_ids.has(old_peer_id)
		or _disconnected_participants.has(old_peer_id)
	):
		# 聚焦测试与仅处理终结阶段的调用方可能直接进入；正式流程已由路线层
		# 先提交规范 peer 身份，避免监听顺序成为隐藏依赖。
		disconnected_record = _commit_reconnected_participant_identity(
			old_peer_id,
			new_peer_id
		)
	elif _participant_peer_ids.has(new_peer_id):
		disconnected_record = (
			_disconnected_participants.get(new_peer_id, {}) as Dictionary
		).duplicate(true)
		if disconnected_record.is_empty():
			var resolved := (
				_resolved_reconnected_identity_resolutions.get(new_peer_id, {})
				as Dictionary
			)
			disconnected_record = (
				resolved.get("disconnected_record", {}) as Dictionary
			).duplicate(true)
	if disconnected_record.is_empty():
		_reconnecting_peer_ids.erase(new_peer_id)
		if _is_host():
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
	if _phase == ProtocolPhase.REWARD_SELECTING:
		if _is_host():
			_keep_reconnected_participant_as_spectator(
				old_peer_id,
				new_peer_id,
				disconnected_record
			)
		else:
			_reconnecting_peer_ids.erase(new_peer_id)
			_emergency_reward_client_snapshot.clear()
			if _emergency_reward_overlay != null:
				_emergency_reward_overlay.hide_and_reset()
		return
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
	if projection_outcome != (
		MultiplayerGameplaySession.ReconnectedPlayerProjectionOutcome.RESTORED
	):
		# MpGame 已明确该身份不能回到当前战场。身份仍用于路线经济与结算，
		# 但不得再发送本机无法模拟的 prepare。
		_keep_reconnected_participant_as_spectator(
			old_peer_id,
			new_peer_id,
			disconnected_record
		)
		return

	_disconnected_participants.erase(new_peer_id)
	if (
		_phase == ProtocolPhase.PREPARING
		and not _activation_dispatch_started
	):
		_expected_prepared_peers[new_peer_id] = true
	_reconnecting_peer_ids.erase(new_peer_id)
	if not _is_host():
		return
	# 身份信号返回前 NetManager 仍处于 PROJECTING。这里只建立作战恢复意图；
	# PREPARING_DELIVERY 租约到达后再真正发包。
	_pending_reconnect_prepare_peers[new_peer_id] = {
		"old_peer_id": old_peer_id,
		"occurrence_key": _active_occurrence_key,
		"deadline_msec": 0,
		"prepare_dispatched": false,
	}
	_try_dispatch_reconnected_combat_prepare(new_peer_id)


## route identity commit 的唯一原子边界。这里迁移所有长期 raw-peer 数据，但把
## new peer 留在 disconnected + reconnecting(PROJECTING)，绝不顺手授予战斗能力。
func _commit_reconnected_participant_identity(
	old_peer_id: int,
	new_peer_id: int
) -> Dictionary:
	if (
		old_peer_id <= 0
		or new_peer_id <= 0
		or old_peer_id == new_peer_id
	):
		return {}
	if (
		_participant_peer_ids.has(new_peer_id)
		and not _participant_peer_ids.has(old_peer_id)
	):
		return (
			_disconnected_participants.get(new_peer_id, {}) as Dictionary
		).duplicate(true)
	if (
		not _participant_peer_ids.has(old_peer_id)
		and not _disconnected_participants.has(old_peer_id)
	):
		return {}
	if (
		_participant_peer_ids.has(new_peer_id)
		or _disconnected_participants.has(new_peer_id)
	):
		push_error(
			"RogueCombatMultiplayerCoordinator: 拒绝覆盖已存在的作战 peer %d。"
			% new_peer_id
		)
		return {}
	if (
		_is_host()
		and _phase == ProtocolPhase.REWARD_SELECTING
		and _emergency_reward_session != null
		and not _emergency_reward_session.remap_disconnected_peer(
			old_peer_id,
			new_peer_id
		)
	):
		_abort_authoritative_protocol(&"emergency_reward_reconnect_remap_failed")
		return {}
	var participant_incarnation := int(
		_participant_incarnations.get(old_peer_id, 0)
	)
	if participant_incarnation <= 0 and _net_manager != null:
		participant_incarnation = (
			_net_manager.get_session_participant_incarnation(old_peer_id)
		)
	if participant_incarnation <= 0:
		return {}
	_participant_incarnations[old_peer_id] = participant_incarnation
	var disconnected_record := _remap_reconnected_participant_identity(
		old_peer_id,
		new_peer_id,
		false
	)
	_resolved_reconnected_identity_resolutions.erase(old_peer_id)
	_disconnected_participants[new_peer_id] = disconnected_record.duplicate(true)
	_reconnecting_peer_ids.erase(old_peer_id)
	_reconnecting_peer_ids[new_peer_id] = true
	return disconnected_record


## NetManager 在 PREPARING_DELIVERY 内同步调用。该租约与 Player 投影结果按
## new peer 汇合，二者先后顺序不影响最终一次性发包。
func handle_reconnected_member_ready(
	old_peer_id: int,
	new_peer_id: int,
	outcome: MultiplayerGameplaySession.ReconnectedPlayerProjectionOutcome
) -> bool:
	if (
		not _is_host()
		or old_peer_id <= 0
		or new_peer_id <= 0
		or old_peer_id == new_peer_id
		or outcome not in [
			MultiplayerGameplaySession.ReconnectedPlayerProjectionOutcome.RESTORED,
			MultiplayerGameplaySession.ReconnectedPlayerProjectionOutcome.SUSPENDED,
		]
	):
		return false
	_reconnected_member_ready_outcomes[new_peer_id] = {
		"old_peer_id": old_peer_id,
		"outcome": int(outcome),
	}
	if outcome == (
		MultiplayerGameplaySession.ReconnectedPlayerProjectionOutcome.SUSPENDED
	):
		return true
	if _pending_reconnect_prepare_peers.has(new_peer_id):
		return _try_dispatch_reconnected_combat_prepare(new_peer_id)
	# 外层塔防可以先 ready，内嵌 Player 结果随后到达；保留租约等待意图。
	return (
		_phase == ProtocolPhase.IDLE
		or _terminal_safe_broadcast
		or _reconnecting_peer_ids.has(new_peer_id)
		or _disconnected_participants.has(new_peer_id)
		or _participant_peer_ids.has(new_peer_id)
	)


func _try_dispatch_reconnected_combat_prepare(new_peer_id: int) -> bool:
	var pending := (
		_pending_reconnect_prepare_peers.get(new_peer_id, {}) as Dictionary
	)
	var ready := (
		_reconnected_member_ready_outcomes.get(new_peer_id, {}) as Dictionary
	)
	if pending.is_empty() or ready.is_empty():
		return true
	if (
		int(pending.get("old_peer_id", 0))
		!= int(ready.get("old_peer_id", 0))
		or int(ready.get("outcome", -1))
		!= MultiplayerGameplaySession.ReconnectedPlayerProjectionOutcome.RESTORED
		or str(pending.get("occurrence_key", "")) != _active_occurrence_key
		or _active_occurrence_key.is_empty()
	):
		return false
	if bool(pending.get("prepare_dispatched", false)):
		return true
	if not _is_reconnect_prepare_delivery_ready(new_peer_id):
		return false
	var activate_immediately := _phase in [
		ProtocolPhase.ACTIVE,
		ProtocolPhase.REWARD_SELECTING,
		ProtocolPhase.SETTLED,
	] or _activation_dispatch_started
	pending["prepare_dispatched"] = true
	pending["deadline_msec"] = (
		Time.get_ticks_msec() + RECONNECT_ACTIVATION_TIMEOUT_MSEC
		if activate_immediately
		else 0
	)
	_pending_reconnect_prepare_peers[new_peer_id] = pending
	_dispatch_reconnected_combat_prepare(new_peer_id, activate_immediately)
	return true


## 单一可替换发送边界让状态机测试验证“PREPARING_DELIVERY 租约内一次”，
## 无需伪造 ENet。正式实现仍只发送权威快照，不在此改任何领域状态。
func _dispatch_reconnected_combat_prepare(
	new_peer_id: int,
	activate_immediately: bool
) -> void:
	net_combat_prepare.rpc_id(
		new_peer_id,
		_active_node_id,
		_active_content_seed,
		_active_occurrence_key,
		_active_combat_config_id,
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
	_reconnected_member_ready_outcomes.erase(new_peer_id)
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
func _remap_reconnected_participant_identity(
	old_peer_id: int,
	new_peer_id: int,
	include_combat_barriers: bool = true
) -> Dictionary:
	var disconnected_record := (
		(_disconnected_participants[old_peer_id] as Dictionary).duplicate(true)
		if _disconnected_participants.has(old_peer_id)
		else {
			"entry_xirang": int(_entry_xirang_by_peer.get(old_peer_id, 0)),
			"last_combat_xirang": int(_last_combat_xirang_by_peer.get(
				old_peer_id,
				_entry_xirang_by_peer.get(old_peer_id, 0)
			)),
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
	_remap_frozen_reward_identity(old_peer_id, new_peer_id)
	if _participant_incarnations.has(old_peer_id):
		_participant_incarnations[new_peer_id] = (
			_participant_incarnations[old_peer_id]
		)
		_participant_incarnations.erase(old_peer_id)
	_disconnected_participants.erase(old_peer_id)
	_pending_reconnect_prepare_peers.erase(old_peer_id)
	_expected_prepared_peers.erase(old_peer_id)
	_prepared_peers.erase(old_peer_id)
	_expected_terminal_peers.erase(old_peer_id)
	_terminal_ready_peers.erase(old_peer_id)
	if (
		include_combat_barriers
		and
		_phase == ProtocolPhase.PREPARING
		and not _activation_dispatch_started
	):
		_expected_prepared_peers[new_peer_id] = true
	elif include_combat_barriers and _phase == ProtocolPhase.SETTLED:
		_expected_terminal_peers[new_peer_id] = true
	if _phase == ProtocolPhase.SETTLED:
		_remap_pending_settlement_peer(old_peer_id, new_peer_id)
	return disconnected_record


func _remap_frozen_reward_identity(old_peer_id: int, new_peer_id: int) -> void:
	for peer_map in [
		_participant_character_ids,
		_participant_stable_keys,
		_last_combat_xirang_by_peer,
	]:
		if not peer_map.has(old_peer_id):
			continue
		peer_map[new_peer_id] = peer_map[old_peer_id]
		peer_map.erase(old_peer_id)
	_remap_emergency_reward_rollback_identity(old_peer_id, new_peer_id)


## 紧急奖励选择开始时已冻结奖励前状态。选择期间发生重连时，回滚快照必须与
## 正式参战者 peer 一起迁移，否则奖励 CAS 后若终局提交失败将无法恢复该玩家。
func _remap_emergency_reward_rollback_identity(
	old_peer_id: int,
	new_peer_id: int
) -> void:
	if _emergency_reward_rollback_state.is_empty():
		return
	var snapshots := (
		_emergency_reward_rollback_state.get(
			"inventory_snapshots_by_peer",
			{}
		) as Dictionary
	)
	if snapshots.has(old_peer_id):
		var snapshot := (snapshots[old_peer_id] as Dictionary).duplicate(true)
		snapshot["peer_id"] = new_peer_id
		snapshots[new_peer_id] = snapshot
		snapshots.erase(old_peer_id)
		_emergency_reward_rollback_state["inventory_snapshots_by_peer"] = snapshots
	for map_name in ["combat_xirang_by_peer", "party_xirang_by_peer"]:
		var peer_map := (
			_emergency_reward_rollback_state.get(map_name, {}) as Dictionary
		)
		if not peer_map.has(old_peer_id):
			continue
		peer_map[new_peer_id] = peer_map[old_peer_id]
		peer_map.erase(old_peer_id)
		_emergency_reward_rollback_state[map_name] = peer_map


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
		"route_spectator_sent": false,
		"expires_msec": (
			Time.get_ticks_msec() + TERMINAL_SPECTATOR_SYNC_TIMEOUT_MSEC
			if not settlement.is_empty()
			else 0
		),
	}
	_flush_pending_terminal_spectator_sync(peer_id)


func _flush_pending_terminal_spectator_sync(peer_id: int) -> bool:
	if (
		not _is_host()
		or peer_id <= 0
		or not _pending_terminal_spectator_syncs.has(peer_id)
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
		pending["settlement"] = settlement
		pending["expires_msec"] = (
			Time.get_ticks_msec() + TERMINAL_SPECTATOR_SYNC_TIMEOUT_MSEC
		)
		_pending_terminal_spectator_syncs[peer_id] = pending
	if not _is_peer_send_ready(peer_id):
		return false
	var route_spectator_sent := bool(
		pending.get("route_spectator_sent", false)
	)
	if settlement.is_empty():
		if not route_spectator_sent:
			_dispatch_terminal_spectator_sync(
				peer_id,
				occurrence_key,
				{},
				true
			)
			pending["route_spectator_sent"] = true
			_pending_terminal_spectator_syncs[peer_id] = pending
		return true
	_dispatch_terminal_spectator_sync(
		peer_id,
		occurrence_key,
		settlement,
		not route_spectator_sent
	)
	_pending_terminal_spectator_syncs.erase(peer_id)
	return true


func _dispatch_terminal_spectator_sync(
	peer_id: int,
	occurrence_key: String,
	settlement: Dictionary,
	include_route_spectator: bool = true
) -> void:
	if include_route_spectator:
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
	if _run_state != null:
		# RunState 先完成稳定身份重映射；已结算载荷随后收敛到同一份
		# 权威余额账本，避免迟到观战者再看到旧 peer key。
		_pending_settlement["party_xirang_ledger"] = (
			_run_state.export_party_xirang_ledger()
		)


func _capture_current_participants() -> PackedInt32Array:
	var result := PackedInt32Array()
	var connected_players := _net_manager.connected_players
	for peer_id_variant in connected_players.keys():
		var peer_id := int(peer_id_variant)
		if peer_id > 0 and _route.get_player_for_peer(peer_id) != null:
			result.append(peer_id)
	result.sort()
	return result


func _freeze_participant_reward_identities() -> bool:
	_participant_character_ids.clear()
	_participant_stable_keys.clear()
	if _route == null or not is_instance_valid(_route):
		return false
	var route_stable_keys := _route.export_participant_stable_keys()
	for peer_id_variant in _participant_peer_ids.keys():
		var peer_id := int(peer_id_variant)
		var route_player := _route.get_player_for_peer(peer_id)
		if route_player == null or not is_instance_valid(route_player):
			return false
		var character_id := route_player.get_character_id()
		if not PlayerCharacterRegistry.is_valid_character_id(character_id):
			return false
		_participant_character_ids[peer_id] = character_id
		var stable_key := str(route_stable_keys.get(
			peer_id,
			route_stable_keys.get(str(peer_id), "")
		)).strip_edges()
		_participant_stable_keys[peer_id] = (
			stable_key if not stable_key.is_empty() else "peer:%d" % peer_id
		)
	return (
		_participant_character_ids.size() == _participant_peer_ids.size()
		and _participant_stable_keys.size() == _participant_peer_ids.size()
	)


## incarnation 与 raw peer 分离保存。组件结果先到时，只有 NetManager 当前
## RECONNECTING 成员携带同一 incarnation 才能为它创建投影事务。
func _freeze_participant_incarnations() -> bool:
	_participant_incarnations.clear()
	if _net_manager == null:
		return false
	for peer_id_variant in _participant_peer_ids.keys():
		var peer_id := int(peer_id_variant)
		var participant_incarnation := (
			_net_manager.get_session_participant_incarnation(peer_id)
		)
		if participant_incarnation <= 0:
			_participant_incarnations.clear()
			return false
		_participant_incarnations[peer_id] = participant_incarnation
	return _participant_incarnations.size() == _participant_peer_ids.size()


func _capture_live_combat_xirang(peer_id: int = -1) -> void:
	if _combat_game == null or not is_instance_valid(_combat_game):
		return
	var peer_ids: Array = (
		[peer_id] if peer_id > 0 else _participant_peer_ids.keys()
	)
	for peer_id_variant in peer_ids:
		var resolved_peer_id := int(peer_id_variant)
		var battle_player := _combat_game.get_player_for_peer(resolved_peer_id)
		if battle_player != null and is_instance_valid(battle_player):
			_last_combat_xirang_by_peer[resolved_peer_id] = (
				battle_player.get_xirang()
			)


func _capture_entry_xirang(
	peer_ids: PackedInt32Array,
	config: RogueCombatEncounterConfig
) -> Dictionary:
	var result: Dictionary = {}
	var inherit_route_xirang := (
		config != null
		and config.inherit_route_xirang
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
		player.set_xirang_balance(amount)


func _apply_xirang_map_to_route(xirang_by_peer: Dictionary) -> void:
	if _route == null:
		return
	for peer_id_variant in xirang_by_peer.keys():
		var peer_id := int(peer_id_variant)
		var player := _route.get_player_for_peer(peer_id)
		if player == null or not is_instance_valid(player):
			continue
		var amount := maxi(int(xirang_by_peer[peer_id_variant]), 0)
		player.set_xirang_balance(amount)


func _get_party_xirang_balances_for_participants() -> Dictionary:
	var result: Dictionary = {}
	if _run_state == null:
		return result
	var ledger := _run_state.export_party_xirang_ledger()
	var values := ledger.get("values", {}) as Dictionary
	for peer_id_variant in _participant_peer_ids.keys():
		var peer_id := int(peer_id_variant)
		result[peer_id] = maxi(int(values.get(str(peer_id), 0)), 0)
	return result


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
		"item_rewards": [],
	}


static func _make_config_signature(
	config: RogueCombatEncounterConfig
) -> String:
	return config.compute_runtime_contract_hash() if config != null else ""


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


## reconnect prepare 是 ACTIVE 发布前唯一允许的玩法投递。NetManager 的
## PREPARING_DELIVERY 租约只开放这个窄出口，不放宽其他 gameplay ingress。
func _is_reconnect_prepare_delivery_ready(peer_id: int) -> bool:
	return (
		_is_peer_send_ready(peer_id)
		or (
			_net_manager != null
			and peer_id > 0
			and _net_manager.is_reconnect_delivery_preparing(peer_id)
		)
	)


## 玩法 RPC 只接受 ACTIVE 会话成员；重连身份已认证但 Player/路线投影尚未
## 完成时仍属于控制面，不能提前修改作战 barrier 或权威结算状态。
func _is_gameplay_ingress_admitted(peer_id: int) -> bool:
	return (
		_net_manager != null
		and peer_id > 0
		and _net_manager.is_gameplay_ingress_admitted(peer_id)
	)
