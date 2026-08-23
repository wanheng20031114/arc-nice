extends MultiplayerGameplaySession

const _NetConstants := preload("res://scene/multiplayer/net_constants.gd")
const MpProjectileCoordinatorScript := preload(
	"res://scene/multiplayer/projectile/mp_projectile_coordinator.gd"
)
const MpWorldFlowCoordinatorScript := preload(
	"res://scene/multiplayer/world_flow/mp_world_flow_coordinator.gd"
)
const MpTowerEconomyCoordinatorScript := preload(
	"res://scene/game_modes/tower_defense/multiplayer/economy/mp_tower_economy_coordinator.gd"
)
const MpMerchantTransactionsCoordinatorScript := preload(
	"res://scene/multiplayer/merchant_transactions/mp_merchant_transactions_coordinator.gd"
)
const MpTowerFateCoordinatorScript := preload(
	"res://scene/game_modes/tower_defense/multiplayer/fate/mp_tower_fate_coordinator.gd"
)
const MpCollectiblePresentationCoordinatorScript := preload(
	"res://scene/multiplayer/collectible_presentation/mp_collectible_presentation_coordinator.gd"
)
const MpNetworkDiagnosticsCoordinatorScript := preload(
	"res://scene/multiplayer/network_diagnostics/mp_network_diagnostics_coordinator.gd"
)
const MpPeerLedgerCoordinatorScript := preload(
	"res://scene/multiplayer/peer_ledger/mp_peer_ledger_coordinator.gd"
)
const CLIENT_PROJECTILE_SPAWN_POSITION_TOLERANCE := (
	MpProjectileCoordinatorScript.CLIENT_PROJECTILE_SPAWN_POSITION_TOLERANCE
)
const CombatTargetIndexScript := preload("res://scene/combat/targeting/combat_target_index.gd")
const GAME_RUNTIME_HOST_AUTHORITY := 1
const GAME_RUNTIME_CLIENT_VIEW := 2
const STATE_DISCONNECTED := 0
const STATE_LOADING_GAME := 5
const STATE_IN_GAME := 6
const RECENT_EVENT_PRUNE_INTERVAL_SECONDS := 5.0
const PEER_RESULT_INVENTORY_SNAPSHOT := &"inventory_snapshot"
const PEER_RESULT_WAREHOUSE_COMMAND := &"warehouse_command"
const PEER_RESULT_PICKUP_COLLECTED := &"pickup_collected"
const PEER_RESULT_UPGRADE_CONFIRMED := &"upgrade_confirmed"
const PEER_RESULT_INVENTORY_ITEM_USED := &"inventory_item_used"
const PEER_RESULT_INVENTORY_ITEM_DISCARDED := &"inventory_item_discarded"
const PEER_RESULT_SIMPLE_CRAFTING := &"simple_crafting"
const PEER_RESULT_SKILL1_PURCHASE := &"skill1_purchase"
const PEER_RESULT_RESEARCH_STATE := &"research_state"
const PEER_RESULT_LUOXI_OFFER_STATE := &"luoxi_offer_state"
const PEER_RESULT_LUOXI_COLLECTIBLE := &"luoxi_collectible"
const PEER_RESULT_LUOXI_REFRESH := &"luoxi_refresh"
const PEER_RESULT_LUOXI_SPECIAL_STARTED := &"luoxi_special_started"
const PEER_RESULT_LUOXI_SPECIAL_CARD := &"luoxi_special_card"
const PEER_RESULT_LUOXI_SPECIAL_FINISHED := &"luoxi_special_finished"
const PEER_RESULT_CHEAT_XIRANG := &"cheat_xirang"
const PEER_RESULT_DEBUG_COLLECTIBLE := &"debug_collectible"
## 这 17 个 RPC 的两个末尾身份参数统一由发送边界追加。字典值指出 subject
## 所在参数；warehouse 的 -1 表示 subject 位于首个 Dictionary 的 peer_id。
const PEER_RESULT_RPC_METHODS := {
	&"net_warehouse_command_result": -1,
	&"net_inventory_snapshot": 0,
	&"net_research_state_updated": 1,
	&"net_pickup_collected": 1,
	&"net_upgrade_confirmed": 0,
	&"net_inventory_item_used": 0,
	&"net_inventory_item_discarded": 0,
	&"net_simple_crafting_result": 0,
	&"net_skill1_purchase_confirmed": 0,
	&"net_luoxi_collectible_offer_state": 0,
	&"net_luoxi_collectible_confirmed": 0,
	&"net_luoxi_collectible_refresh_confirmed": 0,
	&"net_luoxi_special_game_started": 0,
	&"net_luoxi_special_game_card_revealed": 0,
	&"net_luoxi_special_game_finished": 0,
	&"net_cheat_xirang_confirmed": 0,
	&"net_debug_collectible_granted": 0,
}
const SUBJECT_IDENTITY_MARKER := &"__canonical_peer_subject__"
const PLAYER_PROJECTION_RETRY_INTERVAL_SECONDS := 0.25
const PLAYER_PROJECTION_RETRY_TIMEOUT_SECONDS := 2.0
const PLAYER_PROJECTION_MAX_ATTEMPTS := 5
# Application payload budget. Keep room for Godot RPC, ENet, UDP/IP headers before MTU pressure.
const HOST_STARTUP_SNAPSHOT_GRACE_SECONDS := 0.5
# Multiplayer protocol map:
# - CH_AUTH: authentication, loading barrier, and complete-state repair.
# - CH_INPUT: client input and predicted pose reports.
# - CH_PLAYER_STATE / CH_ENEMY_STATE: independent realtime snapshots.
# - CH_PROJECTILE: projectile intents and replicated projectile presentation.
# - CH_WORLD_EVENT: durable spawn, terminal, plant, terrain, base, and flow events.
# - CH_TRANSACTION: inventory, Luoxi, economy, and shared-warehouse commands.
# - CH_FEEDBACK: discardable combat numbers, status visuals, and progress batches.
# Host owns enemy AI, player damage confirmation, death, revive, pickups, upgrades, and wave lifecycle.

@onready var net_manager: NetManagerStore = NetManagerStore.get_autoload_instance()
@onready var run_state: RunStateStore = get_node("/root/RunState") as RunStateStore
@onready var session_coordinator: MpSessionCoordinator = $SessionCoordinator
@onready var player_coordinator: MpPlayerCoordinator = $PlayerCoordinator
@onready var enemy_coordinator: MpEnemyCoordinator = $EnemyCoordinator
@onready var projectile_coordinator: MpProjectileCoordinatorScript = $ProjectileCoordinator
@onready var world_flow_coordinator: MpWorldFlowCoordinatorScript = $WorldFlowCoordinator
@onready var transactions_coordinator: MpTransactionsCoordinator = $TransactionsCoordinator
@onready var tower_economy_coordinator: MpTowerEconomyCoordinatorScript = $TowerEconomyCoordinator
@onready var tower_world_coordinator: MpTowerWorldCoordinator = $TowerWorldCoordinator
@onready var merchant_transactions_coordinator: MpMerchantTransactionsCoordinatorScript = (
	$MerchantTransactionsCoordinator
)
@onready var tower_fate_coordinator: MpTowerFateCoordinatorScript = $TowerFateCoordinator
@onready var collectible_presentation_coordinator: MpCollectiblePresentationCoordinatorScript = (
	$CollectiblePresentationCoordinator
)
@onready var network_diagnostics_coordinator: MpNetworkDiagnosticsCoordinatorScript = (
	$NetworkDiagnosticsCoordinator
)
@onready var peer_ledger_coordinator: MpPeerLedgerCoordinatorScript = (
	$PeerLedgerCoordinator
)
@onready var tower_rogue_route_bridge: MpRogueRoute = $TowerRogueRouteBridge
@onready var public_room_lease: PublicRoomLeaseStore = (
	PublicRoomLeaseStore.get_autoload_instance()
)

var game: CombatRuntimeBase = null
var _gameplay_gateway: MultiplayerGameplayGateway = null
var _mode_adapter: MultiplayerModeAdapter = null
var tower_mode_adapter: TowerDefenseMultiplayerModeAdapter = null
var _linglan_boss_runtime_port: LinglanBossRuntimePort = null
var _disconnected_player_reconnect_states: Dictionary[int, Dictionary] = {}
var _recent_event_prune_time_left: float = RECENT_EVENT_PRUNE_INTERVAL_SECONDS
var _host_startup_snapshot_grace_time_left: float = 0.0
var _client_host_game_ready: bool = false
var _embedded_runtime_active := false
var _embedded_participant_peer_ids: Dictionary[int, bool] = {}
var _suspended_embedded_participant_peer_ids: Dictionary[int, bool] = {}
## 身份已经迁移、但 Player 尚未完成投影的内嵌战斗参与者。该集合只是一份
## 能力租约，不复制成员身份或 Player 状态；完成、挂起或最终离场时必须释放。
var _projecting_embedded_participant_peer_ids: Dictionary[int, bool] = {}
## exploration session uses CH_AUTH while the established tower flow RPC uses
## CH_WORLD_EVENT. Preserve each channel's protocol and defer the cross-channel
## transition until both authoritative halves describe the same active state.
var _pending_tower_rogue_flow_state: Dictionary = {}
var _peer_ledger_generation := 0
var _peer_result_repair_queued := false
## repair_needed 是异常修复的唯一债务真源；queued 只表示已有 deferred 调度，
## SessionCoordinator 则唯一拥有网络请求租约与冷却。
var _peer_result_repair_needed := false
## 身份已提交但 Player 尚未建立时，只保存重试时钟与认证参数；权威瞬时状态
## 仍唯一存放在 `_disconnected_player_reconnect_states`，避免出现第二份状态副本。
var _pending_reconnected_player_projections: Dictionary[int, Dictionary] = {}
## 已完成映射以 old peer 为键，既能幂等识别同一通知，也能拒绝 old->多个 new。
var _completed_reconnected_player_projections: Dictionary[int, int] = {}
var _public_return_in_progress := false
var _lobby_return_in_progress := false
var _game_setup_failure_reason := ""
var _preparation_generation := 0


func _ready() -> void:
	_preparation_generation = begin_runtime_preparation(
		"正在创建多人战场…",
		1
	)
	update_runtime_preparation_progress(
		_preparation_generation,
		"正在创建多人战场…",
		0,
		1
	)
	if (
		net_manager == null
		or (
			not embedded_runtime
			and not net_manager.register_reconnect_delivery_preparer(
				prepare_reconnected_member_delivery
			)
		)
	):
		var reason := "顶层多人会话无法取得重连首帧准备能力。"
		push_error("MpGame: %s" % reason)
		mark_runtime_preparation_failed(_preparation_generation, reason)
		_defer_lobby_return_without_active_loader()
		return
	session_coordinator.bind_transport_dependencies(net_manager)
	_connect_session_coordinator_signals()
	player_coordinator.randomize_revive_generator()
	merchant_transactions_coordinator.randomize_offer_generator()
	_connect_world_flow_coordinator_signals()
	_connect_peer_ledger_signals()
	set_multiplayer_authority(_get_host_peer_id())
	if not net_manager.connection_state_changed.is_connected(_on_connection_state_changed):
		net_manager.connection_state_changed.connect(_on_connection_state_changed)
	if not net_manager.player_left.is_connected(_on_net_player_left):
		net_manager.player_left.connect(_on_net_player_left)
	if not net_manager.player_reconnected.is_connected(_on_net_player_reconnected):
		net_manager.player_reconnected.connect(_on_net_player_reconnected)
	if not net_manager.session_membership_changed.is_connected(
		_on_session_membership_changed
	):
		net_manager.session_membership_changed.connect(
			_on_session_membership_changed
		)
	if not net_manager.session_member_final_departed.is_connected(
		_on_session_member_final_departed
	):
		net_manager.session_member_final_departed.connect(
			_on_session_member_final_departed
		)
	if net_manager.is_host():
		if not _setup_game(GAME_RUNTIME_HOST_AUTHORITY):
			mark_runtime_preparation_failed(
				_preparation_generation,
				_game_setup_failure_reason
			)
			_defer_lobby_return_without_active_loader()
			return
		_host_startup_snapshot_grace_time_left = HOST_STARTUP_SNAPSHOT_GRACE_SECONDS
		_client_host_game_ready = true
	elif net_manager.is_client():
		if not _setup_game(GAME_RUNTIME_CLIENT_VIEW):
			mark_runtime_preparation_failed(
				_preparation_generation,
				_game_setup_failure_reason
			)
			_defer_lobby_return_without_active_loader()
			return
		_client_host_game_ready = net_manager.host_game_ready
	else:
		var reason := "多人战场启动时没有有效连接。"
		push_warning("MpGame: %s" % reason)
		mark_runtime_preparation_failed(_preparation_generation, reason)
		_defer_lobby_return_without_active_loader()
		return
	if embedded_runtime:
		_client_host_game_ready = false
		_announce_embedded_runtime_when_prepared(_preparation_generation)
	else:
		_report_game_loaded_when_prepared(_preparation_generation)


func _connect_session_coordinator_signals() -> void:
	if not session_coordinator.rpc_to_peer_requested.is_connected(
		_on_session_rpc_to_peer_requested
	):
		session_coordinator.rpc_to_peer_requested.connect(
			_on_session_rpc_to_peer_requested
		)
	if not session_coordinator.runtime_repair_plant_roster_requested.is_connected(
		_on_session_runtime_repair_plant_roster_requested
	):
		session_coordinator.runtime_repair_plant_roster_requested.connect(
			_on_session_runtime_repair_plant_roster_requested
		)
	if not session_coordinator.client_runtime_repair_available.is_connected(
		_on_client_runtime_repair_available
	):
		session_coordinator.client_runtime_repair_available.connect(
			_on_client_runtime_repair_available
		)


func _on_session_rpc_to_peer_requested(
	peer_id: int,
	method_name: StringName,
	arguments: Array
) -> void:
	if peer_id <= 0 or not is_inside_tree() or not net_manager.is_host():
		return
	_rpc_to_peer(peer_id, method_name, arguments)


func _on_session_runtime_repair_plant_roster_requested(peer_id: int) -> void:
	if peer_id <= 0 or not is_inside_tree() or not net_manager.is_host():
		return
	_send_live_plant_roster_to_peer(peer_id)


func _on_client_runtime_repair_available() -> void:
	if not _peer_result_repair_needed:
		return
	_schedule_peer_result_full_repair()


func _connect_world_flow_coordinator_signals() -> void:
	var signal_bindings: Array[Array] = [
		[
			world_flow_coordinator.rpc_to_peer_requested,
			_on_world_flow_rpc_to_peer_requested,
		],
		[
			world_flow_coordinator.rpc_broadcast_requested,
			_on_world_flow_rpc_broadcast_requested,
		],
		[
			world_flow_coordinator.merchant_active_broadcast_requested,
			_on_world_flow_merchant_active_broadcast_requested,
		],
		[
			world_flow_coordinator.wave_progress_broadcast_requested,
			_on_world_flow_wave_progress_broadcast_requested,
		],
		[
			world_flow_coordinator.flow_state_broadcast_requested,
			_on_world_flow_state_broadcast_requested,
		],
		[
			world_flow_coordinator.boss_started_broadcast_requested,
			_on_world_flow_boss_started_broadcast_requested,
		],
		[
			world_flow_coordinator.defeat_broadcast_requested,
			_on_world_flow_defeat_broadcast_requested,
		],
		[
			world_flow_coordinator.victory_broadcast_requested,
			_on_world_flow_victory_broadcast_requested,
		],
		[
			world_flow_coordinator.terminal_flow_started,
			_clear_pending_player_revives,
		],
	]
	for binding in signal_bindings:
		var source: Signal = binding[0]
		var target: Callable = binding[1]
		if not source.is_connected(target):
			source.connect(target)


func _connect_peer_ledger_signals() -> void:
	var signal_bindings: Array[Array] = [
		[
			peer_ledger_coordinator.envelope_rejected,
			_on_peer_result_envelope_rejected,
		],
		[
			peer_ledger_coordinator.pending_envelope_expired,
			_on_peer_result_envelope_expired,
		],
	]
	for binding in signal_bindings:
		var source: Signal = binding[0]
		var target: Callable = binding[1]
		if not source.is_connected(target):
			source.connect(target)


func _on_peer_result_envelope_rejected(
	peer_id: int,
	stream_id: StringName,
	revision: int,
	reason: StringName
) -> void:
	push_warning(
		"MpGame: 玩家 %d 的跨信道结果被拒绝，stream=%s revision=%d reason=%s。"
		% [peer_id, stream_id, revision, reason]
	)
	_request_peer_result_full_repair()


func _on_peer_result_envelope_expired(
	peer_id: int,
	stream_id: StringName,
	revision: int
) -> void:
	push_warning(
		"MpGame: 玩家 %d 的跨信道结果已过期，stream=%s revision=%d。"
		% [peer_id, stream_id, revision]
	)
	_request_peer_result_full_repair()


func _request_peer_result_full_repair() -> void:
	if net_manager == null or not net_manager.is_client():
		return
	_peer_result_repair_needed = true
	if _peer_ledger_generation <= 0:
		# 当前局的 RPC 可能在场景 `_ready` 完成账本 bind 前抵达。债务保留到
		# bind 成功；退出场景会显式清理，旧局故障不得污染下一局。
		return
	_schedule_peer_result_full_repair()


func _schedule_peer_result_full_repair() -> void:
	if _peer_result_repair_queued:
		return
	# 同一帧可能同时出现 conflict signal 与 claim 汇总；调度层先合并一次，
	# 跨帧放大控制由 SessionCoordinator 的 in-flight 租约统一负责。
	_peer_result_repair_queued = true
	call_deferred(
		"_flush_peer_result_full_repair",
		_peer_ledger_generation
	)


func _flush_peer_result_full_repair(expected_generation: int) -> void:
	_peer_result_repair_queued = false
	if (
		not _peer_result_repair_needed
		or expected_generation <= 0
		or expected_generation != _peer_ledger_generation
	):
		return
	if _request_runtime_state_from_host(true):
		_peer_result_repair_needed = false


func _clear_peer_result_repair_state() -> void:
	_peer_result_repair_queued = false
	_peer_result_repair_needed = false


func _on_world_flow_rpc_to_peer_requested(
	peer_id: int,
	method_name: StringName,
	arguments: Array
) -> void:
	if peer_id <= 0 or not is_inside_tree() or not net_manager.is_host():
		return
	_rpc_to_peer(peer_id, method_name, arguments)


func _on_world_flow_rpc_broadcast_requested(
	method_name: StringName,
	arguments: Array
) -> void:
	if not is_inside_tree() or not net_manager.is_host():
		return
	_rpc_to_connected_clients(method_name, arguments)


func _on_player_life_rpc_broadcast_requested(
	method_name: StringName,
	arguments: Array
) -> void:
	_rpc_to_connected_clients(method_name, arguments)


func _on_player_life_state_correction_requested(
	peer_id: int,
	corrected_position: Vector2,
	corrected_velocity: Vector2
) -> void:
	_rpc_to_peer(
		peer_id,
		&"net_player_state_corrected",
		[corrected_position, corrected_velocity]
	)


func _on_player_state_rejected(
	_peer_id: int,
	_sequence: int,
	reason: StringName
) -> void:
	_get_network_diagnostics_coordinator().record_player_input_rejection(reason)


func _on_player_action_rpc_to_host_requested(
	method_name: StringName,
	arguments: Array
) -> void:
	if (
		not net_manager.is_client()
		or _is_tower_world_suspended_for_rogue_exploration()
	):
		return
	_rpc_to_peer(_get_host_peer_id(), method_name, arguments)


func _on_player_action_rpc_to_peer_requested(
	peer_id: int,
	method_name: StringName,
	arguments: Array
) -> void:
	if peer_id <= 0 or not net_manager.is_host():
		return
	_rpc_to_peer(peer_id, method_name, arguments)


func _on_player_action_rpc_broadcast_requested(
	method_name: StringName,
	arguments: Array
) -> void:
	_rpc_to_connected_clients(method_name, arguments)


func _on_player_snapshot_send_requested(
	peer_id: int,
	host_timestamp: float,
	data: PackedByteArray,
	entity_count: int
) -> void:
	if (
		peer_id <= 0
		or not net_manager.is_host()
		or _is_tower_world_suspended_for_rogue_exploration()
	):
		return
	_record_snapshot_packet_size(&"player", data.size(), entity_count)
	_rpc_to_peer(
		peer_id,
		&"_rpc_receive_player_snapshot",
		[host_timestamp, data],
		false
	)


func _on_player_authoritative_teleport_broadcast_requested(
	peer_id: int,
	target_position: Vector2,
	snapshot_sequence_cutoff: int
) -> void:
	if not net_manager.is_host():
		return
	_rpc_to_connected_clients(
		&"net_player_authoritative_teleported",
		[peer_id, target_position, snapshot_sequence_cutoff]
	)


func _on_stale_player_peer_detected(peer_id: int) -> void:
	if peer_id <= 0 or game == null or not net_manager.is_client():
		return
	_clear_peer_network_state(peer_id)
	game.remove_multiplayer_player(peer_id)


func _on_projectile_rpc_to_host_requested(
	method_name: StringName,
	arguments: Array
) -> void:
	if (
		not net_manager.is_client()
		or _is_tower_world_suspended_for_rogue_exploration()
	):
		return
	_rpc_to_peer(_get_host_peer_id(), method_name, arguments)


func _on_projectile_rpc_to_peer_requested(
	peer_id: int,
	method_name: StringName,
	arguments: Array
) -> void:
	if peer_id <= 0 or not net_manager.is_host():
		return
	_rpc_to_peer(peer_id, method_name, arguments)


func _on_projectile_enemy_rapid_fire_action_requested(
	source_enemy_id: int,
	profile: int,
	direction: Vector2,
	source_position: Vector2,
	action_id: int,
	host_action_timestamp: float,
	action_elapsed: float
) -> void:
	if net_manager.is_host() or game == null or source_enemy_id <= 0:
		return
	var action_name: StringName
	match profile:
		RapidFireSimulationService.Profile.AK:
			action_name = &"burst"
		RapidFireSimulationService.Profile.GUNNER, RapidFireSimulationService.Profile.GUNNER_ELITE:
			action_name = &"combat_robot_gunner_burst"
		_:
			return
	var received_at := _get_net_time()
	enemy_coordinator.receive_enemy_action(
		source_enemy_id,
		action_name,
		direction,
		source_position,
		action_id,
		received_at - maxf(action_elapsed, 0.0),
		received_at,
		host_action_timestamp
	)


func _on_projectile_rpc_broadcast_requested(
	method_name: StringName,
	arguments: Array
) -> void:
	_rpc_to_connected_clients(method_name, arguments)


func _on_tiyi_high_noon_damage_requested(
	owner_player: PlayerTiyi,
	enemy_net_id: int,
	enemy: Enemy
) -> void:
	if net_manager == null or not net_manager.is_host():
		return
	enemy_coordinator.apply_tiyi_high_noon_damage(owner_player, enemy_net_id, enemy)


func _on_enemy_lifecycle_rpc_to_peer_requested(
	peer_id: int,
	method_name: StringName,
	arguments: Array
) -> void:
	if peer_id <= 0 or not net_manager.is_host():
		return
	_rpc_to_peer(peer_id, method_name, arguments)


func _on_enemy_lifecycle_rpc_broadcast_requested(
	method_name: StringName,
	arguments: Array
) -> void:
	_rpc_to_connected_clients(method_name, arguments)


func _on_enemy_damage_rpc_broadcast_requested(
	method_name: StringName,
	arguments: Array
) -> void:
	_rpc_to_connected_clients(method_name, arguments)


func _on_enemy_snapshot_send_requested(
	peer_id: int,
	host_timestamp: float,
	data: PackedByteArray,
	batch_id: int,
	chunk_index: int,
	chunk_count: int,
	snapshot_hz: int,
	entity_count: int
) -> void:
	if (
		peer_id <= 0
		or not net_manager.is_host()
		or _is_tower_world_suspended_for_rogue_exploration()
	):
		return
	_record_snapshot_packet_size(&"enemy", data.size(), entity_count)
	_rpc_to_peer(
		peer_id,
		&"_rpc_receive_enemy_snapshot",
		[
			host_timestamp,
			data,
			batch_id,
			chunk_index,
			chunk_count,
			snapshot_hz,
		],
		false
	)


func _exit_tree() -> void:
	if net_manager != null and not embedded_runtime:
		net_manager.unregister_reconnect_delivery_preparer(
			prepare_reconnected_member_delivery
		)
	_clear_reconnected_player_projection_state()
	_clear_peer_result_repair_state()
	if peer_ledger_coordinator != null:
		peer_ledger_coordinator.unbind_session(self)
	_peer_ledger_generation = 0
	if net_manager != null and net_manager.is_host():
		_capture_shared_warehouse_ledger()
	if tower_rogue_route_bridge != null:
		tower_rogue_route_bridge.unbind_embedded_campaign_runtime()
	_pending_tower_rogue_flow_state.clear()
	if net_manager != null and net_manager.connection_state_changed.is_connected(_on_connection_state_changed):
		net_manager.connection_state_changed.disconnect(_on_connection_state_changed)
	if net_manager != null and net_manager.player_left.is_connected(_on_net_player_left):
		net_manager.player_left.disconnect(_on_net_player_left)
	if (
		net_manager != null
		and net_manager.player_reconnected.is_connected(_on_net_player_reconnected)
	):
		net_manager.player_reconnected.disconnect(_on_net_player_reconnected)
	if (
		net_manager != null
		and net_manager.session_membership_changed.is_connected(
			_on_session_membership_changed
		)
	):
		net_manager.session_membership_changed.disconnect(
			_on_session_membership_changed
		)
	if (
		net_manager != null
		and net_manager.session_member_final_departed.is_connected(
			_on_session_member_final_departed
		)
	):
		net_manager.session_member_final_departed.disconnect(
			_on_session_member_final_departed
		)
	if game != null:
		if (
			_mode_adapter != null
			and _mode_adapter.return_to_lobby_requested.is_connected(
				_on_game_return_to_lobby_requested
			)
		):
			_mode_adapter.return_to_lobby_requested.disconnect(
				_on_game_return_to_lobby_requested
			)
		if _gameplay_gateway != null:
			_gameplay_gateway.detach_multiplayer_session(self)
		if _mode_adapter != null:
			_mode_adapter.detach_multiplayer_session(self)
		if session_coordinator != null:
			session_coordinator.unbind_runtime(game)
		if player_coordinator != null:
			player_coordinator.unbind_runtime(game)
		if enemy_coordinator != null:
			enemy_coordinator.unbind_runtime(game)
		if projectile_coordinator != null:
			projectile_coordinator.unbind_runtime(game)
		if world_flow_coordinator != null:
			world_flow_coordinator.unbind_runtime(game)
		if transactions_coordinator != null:
			transactions_coordinator.unbind_session(self)
		if tower_world_coordinator != null:
			tower_world_coordinator.unbind_session(self)
		if tower_economy_coordinator != null:
			tower_economy_coordinator.unbind_runtime(game)
		if merchant_transactions_coordinator != null:
			merchant_transactions_coordinator.unbind_runtime(game)
		if tower_fate_coordinator != null:
			tower_fate_coordinator.unbind_runtime(game)
		if collectible_presentation_coordinator != null:
			collectible_presentation_coordinator.unbind_runtime(game)
	else:
		if session_coordinator != null:
			session_coordinator.reset_session_state()
		if player_coordinator != null:
			player_coordinator.reset_session_state()
		if enemy_coordinator != null:
			enemy_coordinator.reset_session_state()
		if projectile_coordinator != null:
			projectile_coordinator.reset_session_state()
		if world_flow_coordinator != null:
			world_flow_coordinator.reset_session_state()
		if transactions_coordinator != null:
			transactions_coordinator.reset_session_state()
	_gameplay_gateway = null
	_mode_adapter = null
	tower_mode_adapter = null
	_linglan_boss_runtime_port = null
	if session_coordinator != null:
		session_coordinator.unbind_transport_dependencies()
	if tower_economy_coordinator != null:
		tower_economy_coordinator.reset_session_state()
	if tower_world_coordinator != null:
		tower_world_coordinator.reset_session_state()
	if merchant_transactions_coordinator != null:
		merchant_transactions_coordinator.reset_session_state()
	if tower_fate_coordinator != null:
		tower_fate_coordinator.reset_session_state()
	if collectible_presentation_coordinator != null:
		collectible_presentation_coordinator.reset_session_state()
	if network_diagnostics_coordinator != null:
		network_diagnostics_coordinator.reset_session_state()


func _physics_process(delta: float) -> void:
	if embedded_runtime and not _embedded_runtime_active:
		return
	if int(net_manager.connection_state) != STATE_IN_GAME:
		return
	# The outer Tower MpGame remains in the scene while the embedded Rogue route
	# is active. Its child route bridge processes independently, so this freezes
	# Tower realtime simulation without starving route or route-combat transport.
	if _is_tower_world_suspended_for_rogue_exploration():
		return
	_update_recent_event_cache_prune(delta)
	_update_snapshot_packet_warning_timer(delta)
	_update_batched_network_events(delta)
	var frame: int = net_manager.get_physics_frame_count()
	if net_manager.is_host():
		_update_authoritative_tango_charge_lifecycle()
		_host_physics_tick(frame, delta)
	elif net_manager.is_client():
		_client_physics_tick(frame)


func _report_game_loaded_when_prepared(preparation_generation: int) -> void:
	if game == null:
		return
	var expected_game := game
	var child_generation := expected_game.get_runtime_preparation_generation()
	var preparation := await _await_game_runtime_preparation(
		expected_game,
		child_generation
	)
	if (
		not is_inside_tree()
		or game != expected_game
		or not is_runtime_preparation_generation_preparing(
			preparation_generation
		)
	):
		return
	if preparation.state == RuntimePreparationProvider.PreparationState.FAILED:
		mark_runtime_preparation_failed(
			preparation_generation,
			preparation.failure_reason
		)
		_defer_lobby_return_without_active_loader()
		return
	mark_runtime_preparation_complete(preparation_generation)
	if not is_inside_tree() or int(net_manager.connection_state) != STATE_LOADING_GAME:
		return
	net_manager.report_game_loaded()


func _announce_embedded_runtime_when_prepared(preparation_generation: int) -> void:
	if game == null:
		return
	var expected_game := game
	var child_generation := expected_game.get_runtime_preparation_generation()
	var preparation := await _await_game_runtime_preparation(
		expected_game,
		child_generation
	)
	if (
		not is_inside_tree()
		or game != expected_game
		or not is_runtime_preparation_generation_preparing(
			preparation_generation
		)
	):
		return
	if preparation.state == RuntimePreparationProvider.PreparationState.FAILED:
		mark_runtime_preparation_failed(
			preparation_generation,
			preparation.failure_reason
		)
		return
	mark_runtime_preparation_complete(preparation_generation)
	if not is_inside_tree() or not embedded_runtime:
		return
	embedded_runtime_prepared.emit()


func activate_embedded_runtime() -> bool:
	if (
		not embedded_runtime
		or _embedded_runtime_active
		or game == null
		or not game.is_runtime_preparation_complete()
		or int(net_manager.connection_state) != STATE_IN_GAME
	):
		return false
	_embedded_runtime_active = true
	_client_host_game_ready = true
	if net_manager.is_host():
		_host_startup_snapshot_grace_time_left = (
			HOST_STARTUP_SNAPSHOT_GRACE_SECONDS
		)
	game.activate_runtime()
	if net_manager.is_client():
		_request_runtime_state_from_host()
		if _peer_result_repair_needed:
			_schedule_peer_result_full_repair()
	return true


## Freezes the peer roster before an embedded combat runtime enters the tree.
## Route spectators share the multiplayer session but must never acquire combat
## players, snapshots, transactions, or settlement state from this MpGame.
func configure_embedded_participant_roster(
	peer_ids: PackedInt32Array
) -> bool:
	if not embedded_runtime or is_inside_tree() or peer_ids.is_empty():
		return false
	var next_roster: Dictionary[int, bool] = {}
	for peer_id in peer_ids:
		if peer_id <= 0 or next_roster.has(peer_id):
			return false
		next_roster[peer_id] = true
	_embedded_participant_peer_ids = next_roster
	return true


## Removes one connected peer from the current embedded battle without
## disconnecting it from the shared route session. This is used only when a
## late-reconnecting client cannot rebuild its local combat runtime; keeping a
## Player here would continue snapshots and transactions toward a route-only
## spectator that can no longer consume them.
func suspend_embedded_participant_for_current_combat(
	peer_id: int,
	previous_peer_id: int = -1
) -> bool:
	if not embedded_runtime or peer_id <= 0:
		return false
	# MpGame and the route coordinator receive the same reconnect signal. By the
	# time the coordinator performs a spectator downgrade, this roster may still
	# contain the old identity or may already have completed old -> new remapping.
	var roster_peer_id := -1
	if (
		previous_peer_id > 0
		and _embedded_participant_peer_ids.has(previous_peer_id)
	):
		roster_peer_id = previous_peer_id
	elif _embedded_participant_peer_ids.has(peer_id):
		roster_peer_id = peer_id
	if roster_peer_id <= 0:
		return false
	if roster_peer_id != peer_id:
		_embedded_participant_peer_ids.erase(roster_peer_id)
		_embedded_participant_peer_ids[peer_id] = true
		_suspended_embedded_participant_peer_ids.erase(roster_peer_id)
		_projecting_embedded_participant_peer_ids.erase(roster_peer_id)
		_clear_peer_network_state(roster_peer_id)
	_projecting_embedded_participant_peer_ids.erase(peer_id)
	_suspended_embedded_participant_peer_ids[peer_id] = true
	_clear_peer_network_state(peer_id)
	if game != null:
		game.remove_multiplayer_player(peer_id)
	return true


func is_embedded_runtime_active() -> bool:
	return embedded_runtime and _embedded_runtime_active


func get_game_runtime() -> CombatRuntimeBase:
	return game


func get_runtime_preparation_snapshot() -> RuntimePreparationSnapshot:
	var wrapper_preparation := super.get_runtime_preparation_snapshot()
	if (
		wrapper_preparation.state == PreparationState.FAILED
		or game == null
	):
		return wrapper_preparation
	var child_preparation := game.get_runtime_preparation_snapshot()
	# wrapper 保留自己的 generation 域，只镜像子运行时的强类型状态与原因。
	return RuntimePreparationSnapshot.new(
		wrapper_preparation.generation,
		child_preparation.state,
		child_preparation.stage,
		child_preparation.completed,
		child_preparation.total,
		child_preparation.failure_reason
	)


func activate_runtime() -> void:
	if game != null and game.is_runtime_preparation_complete():
		game.activate_runtime()


func _await_game_runtime_preparation(
	expected_game: CombatRuntimeBase,
	expected_generation: int
) -> RuntimePreparationSnapshot:
	var preparation := expected_game.get_runtime_preparation_snapshot()
	while preparation.state == PreparationState.PREPARING:
		await expected_game.runtime_preparation_state_changed
		if not is_inside_tree() or game != expected_game:
			return RuntimePreparationSnapshot.new(
				expected_generation,
				PreparationState.FAILED,
				"多人战场已离开场景树",
				0,
				1,
				"多人战场在准备完成前已离开场景树。"
			)
		preparation = expected_game.get_runtime_preparation_snapshot()
		if preparation.generation != expected_generation:
			return RuntimePreparationSnapshot.new(
				expected_generation,
				PreparationState.FAILED,
				"多人战场准备周期已被替换",
				0,
				1,
				"多人战场准备周期在完成前已被新 generation 替换。"
			)
	return preparation


func _defer_lobby_return_without_active_loader() -> void:
	# 内嵌运行时只拥有本次子战场，不拥有共享传输或 SceneTree。它的准备
	# 失败由 runtime_preparation_failed 回报外层作战协调器统一收口。
	if embedded_runtime:
		return
	var loader := get_node_or_null("/root/GameLoadCoordinator")
	# 加载器持有失败界面、房间成员释放与返回动作；直接启动场景才自行回大厅。
	if loader != null and bool(loader.call("is_loading")):
		return
	call_deferred("_return_to_lobby")


func _process(delta: float) -> void:
	_update_pending_reconnected_player_projections(delta)
	if embedded_runtime and not _embedded_runtime_active:
		return
	session_coordinator.update_transport(delta)
	# Keep lobby/session transport alive, but never interpolate or advance the
	# hidden Tower world during a Rogue exploration interlude.
	if _is_tower_world_suspended_for_rogue_exploration():
		return
	if net_manager.is_client() or net_manager.is_host():
		_client_interpolate_entities()
	if net_manager.is_client() and game != null:
		tower_world_coordinator.update_client(delta)
		enemy_coordinator.update_proxy_visual_budget(delta)
		world_flow_coordinator.update_client_enemy_count()


func request_multiplayer_upgrade(stat_type: int) -> void:
	if _is_tower_management_suspended():
		return
	transactions_coordinator.request_upgrade(stat_type)


func request_multiplayer_inventory_item_use(slot_index: int) -> void:
	if _is_tower_management_suspended():
		return
	transactions_coordinator.request_inventory_item_use(slot_index)


func request_multiplayer_inventory_item_discard(slot_index: int) -> void:
	if _is_tower_management_suspended():
		return
	transactions_coordinator.request_inventory_item_discard(slot_index)


func request_multiplayer_simple_crafting(
	recipe_id: StringName,
	ui_request_token: int
) -> void:
	if _is_tower_management_suspended():
		return
	transactions_coordinator.request_simple_crafting(recipe_id, ui_request_token)


func cancel_multiplayer_simple_crafting_request(ui_request_token: int) -> void:
	transactions_coordinator.cancel_simple_crafting_request(ui_request_token)


func begin_inventory_building_placement(
	slot_index: int,
	expected_inventory_revision: int = -1
) -> bool:
	if (
		not _has_tower_mode()
		or _is_tower_management_suspended()
	):
		return false
	return tower_mode_adapter.begin_inventory_building_placement(
		slot_index,
		expected_inventory_revision
	)


func request_multiplayer_skill1_purchase() -> void:
	if _is_tower_management_suspended():
		return
	transactions_coordinator.request_skill1_purchase()


func _on_transaction_upgrade_request_to_host(stat_type: int) -> void:
	if _is_tower_management_suspended():
		return
	_rpc_to_peer(_get_host_peer_id(), &"net_upgrade_selected", [stat_type])


func _on_transaction_inventory_item_use_request_to_host(
	slot_index: int,
	expected_inventory_revision: int
) -> void:
	if _is_tower_management_suspended():
		return
	_rpc_to_peer(
		_get_host_peer_id(),
		&"net_inventory_item_use_requested",
		[slot_index, expected_inventory_revision]
	)


func _on_transaction_inventory_item_discard_request_to_host(
	slot_index: int,
	expected_inventory_revision: int
) -> void:
	if _is_tower_management_suspended():
		return
	_rpc_to_peer(
		_get_host_peer_id(),
		&"net_inventory_item_discard_requested",
		[slot_index, expected_inventory_revision]
	)


func _on_transaction_simple_crafting_request_to_host(
	request_id: int,
	recipe_id: String,
	expected_inventory_revision: int
) -> void:
	if _is_tower_management_suspended():
		return
	_rpc_to_peer(
		_get_host_peer_id(),
		&"net_simple_crafting_requested",
		[request_id, recipe_id, expected_inventory_revision]
	)


func _on_transaction_skill1_purchase_request_to_host() -> void:
	if _is_tower_management_suspended():
		return
	_rpc_to_peer(_get_host_peer_id(), &"net_skill1_purchase_requested")


func _on_transaction_upgrade_confirmation_broadcast_requested(
	peer_id: int,
	stat_type: int,
	level: int,
	current_xirang: int,
	success: bool,
	free_upgrade: bool
) -> void:
	_rpc_to_connected_clients(
		&"net_upgrade_confirmed",
		[peer_id, stat_type, level, current_xirang, success, free_upgrade]
	)
	if peer_id == _get_local_peer_id():
		transactions_coordinator.receive_upgrade_confirmation(
			peer_id,
			stat_type,
			level,
			current_xirang,
			success,
			free_upgrade
		)


func _on_transaction_inventory_item_used_broadcast_requested(
	peer_id: int,
	slot_index: int,
	config_path: String,
	success: bool,
	inventory_snapshot: Dictionary,
	force_inventory_repair: bool
) -> void:
	_rpc_to_connected_clients(
		&"net_inventory_item_used",
		[
			peer_id,
			slot_index,
			config_path,
			success,
			inventory_snapshot,
			force_inventory_repair,
		]
	)
	if peer_id == _get_local_peer_id():
		transactions_coordinator.receive_inventory_item_used(
			peer_id,
			slot_index,
			config_path,
			success,
			inventory_snapshot,
			force_inventory_repair
		)


func _on_transaction_inventory_item_discarded_broadcast_requested(
	peer_id: int,
	slot_index: int,
	success: bool,
	inventory_snapshot: Dictionary,
	force_inventory_repair: bool
) -> void:
	_rpc_to_connected_clients(
		&"net_inventory_item_discarded",
		[
			peer_id,
			slot_index,
			success,
			inventory_snapshot,
			force_inventory_repair,
		]
	)
	if peer_id == _get_local_peer_id():
		transactions_coordinator.receive_inventory_item_discarded(
			peer_id,
			slot_index,
			success,
			inventory_snapshot,
			force_inventory_repair
		)


func _on_transaction_simple_crafting_result_broadcast_requested(
	peer_id: int,
	request_id: int,
	recipe_id: String,
	result_code: String,
	inventory_snapshot: Dictionary,
	force_inventory_repair: bool
) -> void:
	_rpc_to_connected_clients(
		&"net_simple_crafting_result",
		[
			peer_id,
			request_id,
			recipe_id,
			result_code,
			inventory_snapshot,
			force_inventory_repair,
		]
	)
	if peer_id == _get_local_peer_id():
		transactions_coordinator.receive_simple_crafting_result(
			peer_id,
			request_id,
			recipe_id,
			result_code,
			inventory_snapshot,
			force_inventory_repair
		)


func _on_transaction_skill1_purchase_confirmation_broadcast_requested(
	peer_id: int,
	current_xirang: int,
	skill1_unlocked: bool,
	result_code: int,
	skill1_upgrade_level: int,
	skill1_charge_duration: float
) -> void:
	_rpc_to_connected_clients(
		&"net_skill1_purchase_confirmed",
		[
			peer_id,
			current_xirang,
			skill1_unlocked,
			result_code,
			skill1_upgrade_level,
			skill1_charge_duration,
		]
	)
	if peer_id == _get_local_peer_id():
		transactions_coordinator.receive_skill1_purchase_confirmation(
			peer_id,
			current_xirang,
			skill1_unlocked,
			result_code,
			skill1_upgrade_level,
			skill1_charge_duration
		)
		transactions_coordinator.show_authoritative_local_skill1_purchase_result(
			result_code
		)


func _on_tower_economy_rpc_to_host_requested(
	method_name: StringName,
	args: Array
) -> void:
	if (
		not net_manager.is_client()
		or _is_tower_management_suspended()
	):
		return
	_rpc_to_peer(_get_host_peer_id(), method_name, args)


func _on_tower_economy_rpc_to_peer_requested(
	peer_id: int,
	method_name: StringName,
	args: Array,
	record_outbound: bool
) -> void:
	if peer_id <= 0 or not net_manager.is_host():
		return
	_rpc_to_peer(peer_id, method_name, args, record_outbound)


func _on_tower_economy_rpc_broadcast_requested(
	method_name: StringName,
	args: Array
) -> void:
	_rpc_to_connected_clients(method_name, args)


func _on_tower_economy_inventory_snapshot_broadcast_requested(
	peer_id: int,
	snapshot: Dictionary
) -> void:
	_rpc_to_connected_clients(&"net_inventory_snapshot", [peer_id, snapshot])


func _on_tower_economy_plant_runtime_state_apply_requested(
	plant: PlantDefense,
	state: Dictionary,
	host_sample_time: float
) -> void:
	tower_world_coordinator.apply_plant_runtime_state(
		plant,
		state,
		host_sample_time
	)


func _on_tower_economy_transaction_latency_observed(
	latency_ms: float
) -> void:
	network_diagnostics_coordinator.record_transaction_latency_ms(latency_ms)


func _on_merchant_transactions_rpc_to_host_requested(
	method_name: StringName,
	args: Array
) -> void:
	if not net_manager.is_client() or _is_tower_management_suspended():
		return
	_rpc_to_peer(_get_host_peer_id(), method_name, args)


func _on_merchant_transactions_rpc_to_peer_requested(
	peer_id: int,
	method_name: StringName,
	args: Array
) -> void:
	if peer_id <= 0 or not net_manager.is_host():
		return
	_rpc_to_peer(peer_id, method_name, args)


func _on_merchant_transactions_rpc_broadcast_requested(
	method_name: StringName,
	args: Array
) -> void:
	_rpc_to_connected_clients(method_name, args)


func _on_tower_fate_rpc_to_host_requested(
	method_name: StringName,
	args: Array
) -> void:
	if not net_manager.is_client():
		return
	_rpc_to_peer(_get_host_peer_id(), method_name, args)


func _on_tower_fate_rpc_to_peer_requested(
	peer_id: int,
	method_name: StringName,
	args: Array
) -> void:
	if peer_id <= 0 or not net_manager.is_host():
		return
	_rpc_to_peer(peer_id, method_name, args)


func _on_tower_fate_rpc_broadcast_requested(
	method_name: StringName,
	args: Array
) -> void:
	_rpc_to_connected_clients(method_name, args)


func _on_collectible_presentation_rpc_broadcast_requested(
	method_name: StringName,
	args: Array
) -> void:
	_rpc_to_connected_clients(method_name, args)


func request_multiplayer_start_wave() -> void:
	if not world_flow_coordinator.supports_wave_progress():
		return
	if net_manager.is_host():
		world_flow_coordinator.request_authoritative_wave_start(
			_get_local_peer_id()
		)
	else:
		_rpc_to_peer(_get_host_peer_id(), &"net_tower_defense_start_wave_requested")


func _on_local_xiaocong_interaction_requested() -> void:
	tower_fate_coordinator.request_local_interaction()


func _on_local_xiaocong_vote_requested(
	option_id: StringName,
	permanent_buff_id: StringName
) -> void:
	tower_fate_coordinator.request_local_vote(option_id, permanent_buff_id)


func _on_local_xiaocong_collectible_requested(choice_index: int) -> void:
	tower_fate_coordinator.request_local_collectible_choice(choice_index)


func _is_valid_xiaocong_vote_payload(
	option_id: StringName,
	permanent_buff_id: StringName
) -> bool:
	return MpTowerFateCoordinatorScript.is_valid_vote_payload(
		option_id,
		permanent_buff_id
	)


func notify_local_player_dash_started(direction: Vector2, start_move_input: Vector2) -> void:
	player_coordinator.notify_local_player_dash_started(
		direction,
		start_move_input,
		_client_host_game_ready
	)


func request_hoe_primary_attack(direction: Vector2) -> bool:
	return player_coordinator.request_hoe_primary_attack(
		direction,
		_client_host_game_ready
	)


func request_hoe_whirlwind() -> bool:
	return player_coordinator.request_hoe_whirlwind(_client_host_game_ready)


func request_tango_electric_surge() -> bool:
	return player_coordinator.request_tango_electric_surge(
		_client_host_game_ready
	)


func begin_authoritative_tango_snow_wolf_auto_fire(
	owner_player: Player,
	direction: Vector2
) -> int:
	return player_coordinator.begin_authoritative_tango_snow_wolf_auto_fire(
		owner_player,
		direction
	)


func spawn_authoritative_tango_electric_surge_field(
	owner_player: Player,
	activation_id: int,
	origin: Vector2
) -> bool:
	return player_coordinator.spawn_authoritative_tango_electric_surge_field(
		owner_player,
		activation_id,
		origin
	)


func spawn_remote_tango_electric_surge_visual_field(
	activation_id: int,
	origin: Vector2,
	remaining_seconds: float
) -> bool:
	return player_coordinator.spawn_remote_tango_electric_surge_visual_field(
		activation_id,
		origin,
		remaining_seconds
	)


func request_tango_charge_started(direction: Vector2) -> bool:
	return player_coordinator.request_tango_charge_started(
		direction,
		_client_host_game_ready
	)


func request_tango_charge_released(direction: Vector2) -> bool:
	return player_coordinator.request_tango_charge_released(
		direction,
		_client_host_game_ready
	)


func request_tango_charge_cancelled() -> bool:
	return player_coordinator.request_tango_charge_cancelled(
		_client_host_game_ready
	)


func request_tiyi_high_noon() -> bool:
	return player_coordinator.request_tiyi_high_noon(
		_client_host_game_ready
	)


func notify_tiyi_high_noon_targets_changed(
	peer_id: int,
	activation_id: int,
	target_ids: PackedInt32Array
) -> void:
	player_coordinator.notify_tiyi_high_noon_targets_changed(
		peer_id,
		activation_id,
		target_ids
	)


func resolve_tiyi_high_noon(
	peer_id: int,
	activation_id: int,
	target_ids: PackedInt32Array,
	_hit_positions: PackedVector2Array
) -> void:
	player_coordinator.resolve_tiyi_high_noon(
		peer_id,
		activation_id,
		target_ids,
		_hit_positions
	)


func cancel_tiyi_high_noon(peer_id: int, activation_id: int) -> void:
	player_coordinator.cancel_tiyi_high_noon(peer_id, activation_id)


func uses_authoritative_luoxi_offers() -> bool:
	return merchant_transactions_coordinator.uses_authoritative_luoxi_offers()


func request_luoxi_collectible_offer() -> void:
	if _is_tower_management_suspended():
		return
	merchant_transactions_coordinator.request_luoxi_collectible_offer()


func request_luoxi_collectible_choice(
	choice_index: int,
	_legacy_config_path: String = "",
	offer_revision: int = 0
) -> void:
	if _is_tower_management_suspended():
		return
	merchant_transactions_coordinator.request_luoxi_collectible_choice(
		choice_index,
		offer_revision
	)


func request_luoxi_collectible_refresh(offer_revision: int = 0) -> void:
	if _is_tower_management_suspended():
		return
	merchant_transactions_coordinator.request_luoxi_collectible_refresh(
		offer_revision
	)


func request_luoxi_special_game_start() -> void:
	if _is_tower_management_suspended():
		return
	merchant_transactions_coordinator.request_luoxi_special_game_start()


func supports_luoxi_special_game() -> bool:
	return merchant_transactions_coordinator.supports_luoxi_special_game()


func request_luoxi_special_game_card_reveal(
	session_revision: int,
	card_index: int
) -> void:
	if _is_tower_management_suspended():
		return
	merchant_transactions_coordinator.request_luoxi_special_game_card_reveal(
		session_revision,
		card_index
	)


func request_luoxi_special_game_finish(session_revision: int) -> void:
	if _is_tower_management_suspended():
		return
	merchant_transactions_coordinator.request_luoxi_special_game_finish(
		session_revision
	)


func has_luoxi_collectible_claimed(peer_id: int) -> bool:
	return merchant_transactions_coordinator.has_luoxi_collectible_claimed(peer_id)


func broadcast_collectible_visual_effect(
	effect_type: StringName,
	spawn_position: Vector2,
	radius: float,
	color: Color,
	duration: float
) -> void:
	collectible_presentation_coordinator.broadcast_visual_effect(
		effect_type,
		spawn_position,
		radius,
		color,
		duration
	)


func broadcast_collectible_follow_visual_effect(
	effect_type: StringName,
	owner_peer_id: int,
	radius: float,
	duration: float
) -> void:
	collectible_presentation_coordinator.broadcast_follow_visual_effect(
		effect_type,
		owner_peer_id,
		radius,
		duration
	)


func request_multiplayer_cheat_xirang() -> void:
	if _is_tower_management_suspended():
		return
	merchant_transactions_coordinator.request_cheat_xirang()


func request_debug_collectible(config_path: String) -> void:
	if (
		merchant_transactions_coordinator == null
		or _is_tower_management_suspended()
	):
		return
	merchant_transactions_coordinator.request_debug_collectible(config_path)


func _on_tower_world_rpc_to_peer_requested(
	peer_id: int,
	method_name: StringName,
	args: Array
) -> void:
	if not _has_tower_mode() or not net_manager.is_host() or peer_id <= 0:
		return
	_rpc_to_peer(peer_id, method_name, args)


func _on_tower_world_rpc_broadcast_requested(
	method_name: StringName,
	args: Array
) -> void:
	if not _has_tower_mode() or not net_manager.is_host():
		return
	_rpc_to_connected_clients(method_name, args)


func _on_tower_world_plant_placement_request_to_host(
	request_id: int,
	plant_id: String,
	anchor: Vector2i
) -> void:
	if (
		not _has_tower_mode()
		or not net_manager.is_client()
		or _is_tower_management_suspended()
	):
		return
	_rpc_to_peer(
		_get_host_peer_id(),
		&"net_plant_placement_requested",
		[request_id, plant_id, anchor]
	)


func _on_tower_world_inventory_plant_placement_request_to_host(
	request_id: int,
	plant_id: String,
	anchor: Vector2i,
	slot_index: int,
	expected_inventory_revision: int,
	item_config_path: String
) -> void:
	if (
		not _has_tower_mode()
		or not net_manager.is_client()
		or _is_tower_management_suspended()
	):
		return
	_rpc_to_peer(
		_get_host_peer_id(),
		&"net_inventory_plant_placement_requested",
		[
			request_id,
			plant_id,
			anchor,
			slot_index,
			expected_inventory_revision,
			item_config_path,
		]
	)


func _on_tower_world_nearest_plant_destruction_request_to_host(
	request_id: int,
	target_net_id: int
) -> void:
	if (
		_is_tower_management_suspended()
		or not _has_tower_mode()
		or not net_manager.is_client()
	):
		return
	_rpc_to_peer(
		_get_host_peer_id(),
		&"net_nearest_plant_destruction_requested",
		[request_id, target_net_id]
	)


func _on_tower_world_terrain_snapshot_request_to_host(known_revision: int) -> void:
	if not _has_tower_mode() or not net_manager.is_client():
		return
	_rpc_to_peer(
		_get_host_peer_id(),
		&"net_terrain_snapshot_requested",
		[known_revision]
	)


func _on_tower_world_base_health_send_requested(
	target_peer_id: int,
	current_health: int,
	maximum_health: int,
	revision: int
) -> void:
	if not _has_tower_mode() or not net_manager.is_host():
		return
	if target_peer_id > 0:
		_rpc_to_peer(
			target_peer_id,
			&"net_base_health_changed",
			[current_health, maximum_health, revision]
		)
		return
	_rpc_to_connected_clients(
		&"net_base_health_changed",
		[current_health, maximum_health, revision]
	)


func _on_tower_world_terrain_snapshot_chunk_send_requested(
	target_peer_id: int,
	snapshot_id: int,
	revision: int,
	chunk_index: int,
	chunk_count: int,
	cell_xy: PackedInt32Array,
	terrain_types: PackedInt32Array
) -> void:
	if not _has_tower_mode() or not net_manager.is_host() or target_peer_id <= 0:
		return
	_rpc_to_peer(
		target_peer_id,
		&"net_terrain_snapshot_chunk",
		[
			snapshot_id,
			revision,
			chunk_index,
			chunk_count,
			cell_xy,
			terrain_types,
		]
	)


func _on_tower_world_terrain_delta_broadcast_requested(
	revision: int,
	cell_xy: PackedInt32Array,
	terrain_types: PackedInt32Array
) -> void:
	if not _has_tower_mode() or not net_manager.is_host():
		return
	_rpc_to_connected_clients(
		&"net_terrain_delta",
		[revision, cell_xy, terrain_types]
	)


func _on_tower_world_test_arena_manual_night_send_requested(
	target_peer_id: int,
	enabled: bool
) -> void:
	if not _has_tower_mode() or not net_manager.is_host():
		return
	if target_peer_id > 0:
		_rpc_to_peer(
			target_peer_id,
			&"net_test_arena_manual_night_changed",
			[enabled]
		)
		return
	_rpc_to_connected_clients(
		&"net_test_arena_manual_night_changed",
		[enabled]
	)


func _on_tower_world_plant_projectile_visual_broadcast_requested(
	spawn_position: Vector2,
	direction: Vector2,
	speed: float,
	explosion_radius: float,
	lifetime: float
) -> void:
	if not _has_tower_mode() or not net_manager.is_host():
		return
	_rpc_to_connected_clients(
		&"net_plant_projectile_visual",
		[spawn_position, direction, speed, explosion_radius, lifetime]
	)


func _on_tower_world_bamboo_mortar_visual_batch_broadcast_requested(
	plant_net_ids: PackedInt32Array,
	action_ids: PackedInt32Array,
	stages: PackedByteArray,
	spawn_positions: PackedVector2Array,
	landing_positions: PackedVector2Array,
	committed_windup_durations: PackedFloat32Array,
	host_action_times: PackedFloat64Array
) -> void:
	if not _has_tower_mode() or not net_manager.is_host():
		return
	_rpc_to_connected_clients(
		&"net_bamboo_mortar_visual_batch",
		[
			plant_net_ids,
			action_ids,
			stages,
			spawn_positions,
			landing_positions,
			committed_windup_durations,
			host_action_times,
		]
	)


func _on_tower_world_hydrangea_rain_visual_broadcast_requested(
	plant_net_id: int,
	action_id: int,
	target_position: Vector2,
	host_action_time: float
) -> void:
	if not _has_tower_mode() or not net_manager.is_host():
		return
	_rpc_to_connected_clients(
		&"net_hydrangea_rain_visual",
		[plant_net_id, action_id, target_position, host_action_time]
	)


func _on_tower_world_corn_machine_gun_burst_batch_broadcast_requested(
	plant_net_ids: PackedInt32Array,
	action_ids: PackedInt32Array,
	shot_counts: PackedByteArray,
	directions: PackedVector2Array,
	host_action_times: PackedFloat64Array
) -> void:
	if not _has_tower_mode() or not net_manager.is_host():
		return
	_rpc_to_connected_clients(
		&"net_corn_machine_gun_burst_batch",
		[plant_net_ids, action_ids, shot_counts, directions, host_action_times]
	)


func _consume_remote_player_action_admission(
	peer_id: int,
	now_seconds: float = -1.0
) -> bool:
	return player_coordinator.consume_remote_player_action_admission(
		peer_id,
		now_seconds
	)


func _is_embedded_participant_suspended(peer_id: int) -> bool:
	return (
		embedded_runtime
		and (
			_suspended_embedded_participant_peer_ids.has(peer_id)
			or _projecting_embedded_participant_peer_ids.has(peer_id)
		)
	)


func _has_tower_mode() -> bool:
	return (
		tower_mode_adapter != null
		and is_instance_valid(tower_mode_adapter)
	)


## Only the persistent outer Tower runtime is suspended. Embedded Rogue combat
## owns a separate MpGame and must continue processing normally.
func _is_tower_world_suspended_for_rogue_exploration() -> bool:
	return (
		not embedded_runtime
		and _has_tower_mode()
		and tower_mode_adapter.is_rogue_tower_world_suspended()
	)


func _is_tower_management_suspended() -> bool:
	return (
		not embedded_runtime
		and _has_tower_mode()
		and tower_mode_adapter.is_tower_management_suspended()
	)


## 玩法 RPC 统一在解析 sender 时消费 NetManager 的成员/投影租约。控制面 RPC
## 必须直接读取 multiplayer.get_remote_sender_id()，避免 repair/reconnect 被误挡。
func _get_rpc_sender_id() -> int:
	var sender_id := multiplayer.get_remote_sender_id()
	if (
		net_manager == null
		or not net_manager.is_gameplay_ingress_admitted(sender_id)
	):
		return 0
	return sender_id


func _get_tower_plant(net_id: int) -> PlantDefense:
	if not _has_tower_mode() or tower_world_coordinator == null:
		return null
	return tower_world_coordinator.get_plant(net_id)


func _get_tower_plant_snapshots() -> Array[Dictionary]:
	if not _has_tower_mode() or tower_world_coordinator == null:
		return []
	return tower_world_coordinator.build_live_plant_records()


func broadcast_plant_projectile_visual(
	plant_net_id: int,
	spawn_position: Vector2,
	direction: Vector2,
	speed: float,
	explosion_radius: float,
	lifetime: float
) -> void:
	tower_world_coordinator.broadcast_plant_projectile_visual(
		plant_net_id,
		spawn_position,
		direction,
		speed,
		explosion_radius,
		lifetime
	)


func queue_bamboo_mortar_visual(
	plant_net_id: int,
	action_id: int,
	stage: int,
	spawn_position: Vector2,
	landing_position: Vector2,
	committed_windup_duration_seconds: float
) -> void:
	tower_world_coordinator.queue_bamboo_mortar_visual(
		plant_net_id,
		action_id,
		stage,
		spawn_position,
		landing_position,
		committed_windup_duration_seconds,
		_get_net_time()
	)


func queue_hydrangea_rain_visual(
	plant_net_id: int,
	action_id: int,
	target_position: Vector2,
	action_elapsed_seconds: float
) -> void:
	tower_world_coordinator.queue_hydrangea_rain_visual(
		plant_net_id,
		action_id,
		target_position,
		action_elapsed_seconds,
		_get_net_time()
	)


func queue_corn_machine_gun_burst_visual(
	plant_net_id: int,
	action_id: int,
	direction: Vector2,
	shot_count: int
) -> void:
	tower_world_coordinator.queue_corn_machine_gun_burst_visual(
		plant_net_id,
		action_id,
		direction,
		shot_count,
		_get_net_time()
	)


func apply_authoritative_plant_enemy_damage(
	damage_source_id: int,
	enemy: Enemy,
	damage: int,
	impact_direction: Vector2,
	damage_type: EnemyConfig.DamageType
) -> bool:
	return tower_world_coordinator.apply_authoritative_plant_enemy_damage(
		damage_source_id,
		enemy,
		damage,
		impact_direction,
		damage_type
	)


func request_bamboo_mortar_target(
	owner: Node2D,
	minimum_range: float,
	maximum_range: float,
	callback: Callable
) -> bool:
	return tower_world_coordinator.request_bamboo_mortar_target(
		owner,
		minimum_range,
		maximum_range,
		callback
	)


func cancel_bamboo_mortar_target_request(owner: Node) -> void:
	tower_world_coordinator.cancel_bamboo_mortar_target_request(owner)


func select_bamboo_mortar_target_sync_for_fixture(
	center: Vector2,
	minimum_range: float,
	maximum_range: float
) -> Enemy:
	return tower_world_coordinator.select_bamboo_mortar_target_sync_for_fixture(
		center,
		minimum_range,
		maximum_range
	)


func queue_bamboo_mortar_explosion(
	landing_position: Vector2,
	inner_radius: float,
	outer_radius: float,
	inner_damage: int,
	outer_damage: int,
	damage_source_id: int
) -> bool:
	return tower_world_coordinator.queue_bamboo_mortar_explosion(
		landing_position,
		inner_radius,
		outer_radius,
		inner_damage,
		outer_damage,
		damage_source_id
	)


func apply_authoritative_plant_enemy_damage_batch(
	damage_source_id: int,
	enemy: Enemy,
	damage_amounts: PackedInt64Array,
	hit_counts: PackedInt32Array,
	impact_direction: Vector2,
	damage_type: EnemyConfig.DamageType
) -> bool:
	return tower_world_coordinator.apply_authoritative_plant_enemy_damage_batch(
		damage_source_id,
		enemy,
		damage_amounts,
		hit_counts,
		impact_direction,
		damage_type
	)


func get_bamboo_mortar_combat_metrics() -> Dictionary:
	return tower_world_coordinator.get_bamboo_mortar_combat_metrics()


func _capture_shared_warehouse_ledger() -> bool:
	return tower_economy_coordinator.capture_shared_warehouse_ledger()


func _broadcast_inventory_snapshot(peer_id: int) -> void:
	var snapshot := run_state.export_inventory_snapshot_for_peer(peer_id)
	_rpc_to_connected_clients(&"net_inventory_snapshot", [peer_id, snapshot])


func _on_host_multiplayer_inventory_changed(peer_id: int) -> void:
	if not net_manager.is_host() or peer_id <= 0:
		return
	_broadcast_inventory_snapshot(peer_id)


func is_client_view_runtime() -> bool:
	if game != null:
		return int(game.runtime_mode) == GAME_RUNTIME_CLIENT_VIEW
	return net_manager != null and net_manager.is_client()


func _get_persistent_session_peer_ids() -> PackedInt32Array:
	var peer_ids := PackedInt32Array()
	if net_manager == null:
		return peer_ids
	for peer_id in net_manager.get_session_member_peer_ids():
		peer_ids.append(peer_id)
	return peer_ids


func _on_session_membership_changed(
	_peer_ids: PackedInt32Array,
	membership_revision: int
) -> void:
	# 全局 RunState membership 只由顶层会话投影。内嵌战斗 roster 是可丢弃
	# 子集，若拿它反写同一 revision 会把路线 spectator 误删并触发整局分叉。
	if embedded_runtime:
		return
	if run_state == null or not run_state.run_started or membership_revision <= 0:
		return
	if run_state.reconcile_multiplayer_session_membership(
		_get_persistent_session_peer_ids(),
		membership_revision
	):
		return
	_fail_session_membership_projection(
		"MpGame 无法原子收敛会话成员 revision=%d。" % membership_revision
	)


## NetManager 的 PREPARING_DELIVERY 同步命令。失败会在成员仍是
## RECONNECTING 时 fail-close；最终 ready 信号只保留给不可失败的观察通知。
func prepare_reconnected_member_delivery(
	old_peer_id: int,
	new_peer_id: int,
	outcome: ReconnectedPlayerProjectionOutcome,
	_membership_revision: int
) -> bool:
	if (
		net_manager == null
		or not net_manager.is_host()
		or new_peer_id <= 0
		or not net_manager.is_reconnect_delivery_preparing(new_peer_id)
	):
		return false
	if not projectile_coordinator.send_active_data_visual_snapshot_to_peer(
		new_peer_id
	):
		return false
	if tower_mode_adapter == null:
		return true
	if not _send_tower_rogue_exploration_snapshot_to_peer(new_peer_id, true):
		return false
	return tower_mode_adapter.handle_rogue_combat_reconnected_member_ready(
		old_peer_id,
		new_peer_id,
		outcome
	)


func _on_session_member_final_departed(
	peer_id: int,
	membership_revision: int,
	_reason: StringName
) -> void:
	if peer_id <= 0 or membership_revision <= 0:
		return
	# player_left 只表示 transport 投影消失；断线宽限期间，持久 RunState、
	# 重连捕获和跨信道幂等水位都必须继续存在。只有 NetManager 确认成员最终
	# 离场后，才在同一边界清理这些跨 transport 生命周期的数据。
	if (
		not embedded_runtime
		and
		run_state != null
		and run_state.run_started
		and not run_state.reconcile_multiplayer_session_membership(
			_get_persistent_session_peer_ids(),
			membership_revision
		)
	):
		_fail_session_membership_projection(
			"MpGame 无法收敛最终离场成员 %d，revision=%d。"
			% [peer_id, membership_revision]
		)
		return
	_clear_final_departed_peer_identity_state(peer_id)


func _fail_session_membership_projection(reason: String) -> void:
	push_error("MpGame: %s" % reason)
	if net_manager == null:
		return
	if not net_manager.terminate_for_session_membership_projection_failure(reason):
		push_error("MpGame: 无法终止成员账本已经分叉的多人会话。")


func _setup_game(mode: int) -> bool:
	var session_game_mode := int(net_manager.get_current_game_mode())
	_game_setup_failure_reason = (
		"多人战场初始化失败（会话模式 %d）。"
		% session_game_mode
	)
	if embedded_runtime and _embedded_participant_peer_ids.is_empty():
		return _fail_game_setup("内嵌战斗缺少冻结的参战玩家名单。")
	var has_runtime_scene_override := not runtime_scene_path_override.strip_edges().is_empty()
	var has_runtime_mode_override := (
		runtime_game_mode_id_override
		!= MultiplayerGameplaySession.INVALID_RUNTIME_GAME_MODE_ID
	)
	if has_runtime_scene_override != has_runtime_mode_override:
		return _fail_game_setup(
			"运行时场景 override 与运行时模式契约必须成对配置。"
		)
	var runtime_game_mode := (
		runtime_game_mode_id_override
		if has_runtime_mode_override
		else session_game_mode
	)
	if not GameModeCatalog.is_known_mode_id(runtime_game_mode):
		return _fail_game_setup(
			"运行时模式 %d 未在 GameModeCatalog 中注册。" % runtime_game_mode
		)
	var game_scene_path := _get_game_scene_path_for_mode(runtime_game_mode)
	var game_scene := load(game_scene_path) as PackedScene
	if game_scene == null:
		return _fail_game_setup(
			"无法加载所选多人游戏场景：%s。" % game_scene_path
		)
	game = game_scene.instantiate() as CombatRuntimeBase
	if game == null:
		return _fail_game_setup("无法实例化所选多人游戏场景。")
	game.configure_player_persistent_modifier_projector(
		player_persistent_modifier_projector
	)
	game.defer_runtime_activation()

	var local_peer_id: int = _get_local_peer_id()
	if local_peer_id <= 0 and net_manager.is_host():
		local_peer_id = _get_host_peer_id()
	if embedded_runtime and not _embedded_participant_peer_ids.has(local_peer_id):
		_discard_unparented_game_runtime()
		return _fail_game_setup("路线观战者不得创建内嵌战斗运行时。")
	var runtime_player_names := _filter_embedded_peer_map(
		net_manager.connected_players
	)
	var runtime_character_ids := _filter_embedded_peer_map(
		net_manager.get_player_character_map()
	)
	# 持久账本使用完整 ACTIVE∪SUSPENDED_GRACE；内嵌战斗只消费其中冻结的
	# participant 子集，永远不拥有或改写全局 membership。
	if embedded_runtime:
		for peer_id_variant in _embedded_participant_peer_ids.keys():
			if not run_state.has_multiplayer_peer_state(int(peer_id_variant)):
				_discard_unparented_game_runtime()
				return _fail_game_setup(
					"内嵌参战者缺少顶层会话持久账本。"
				)
	elif not run_state.reconcile_multiplayer_session_membership(
		_get_persistent_session_peer_ids(),
		net_manager.get_session_membership_revision()
	):
		_discard_unparented_game_runtime()
		return _fail_game_setup("无法收敛权威会话成员与运行时账本。")
	game.configure_multiplayer(
		mode,
		local_peer_id,
		runtime_player_names,
		runtime_character_ids
	)
	_gameplay_gateway = game.get_multiplayer_gameplay_gateway()
	_mode_adapter = game.get_multiplayer_mode_adapter()
	var gameplay_gateway := _gameplay_gateway
	var mode_adapter := _mode_adapter
	_linglan_boss_runtime_port = game.get_node_or_null(
		"LinglanBossRuntimePort"
	) as LinglanBossRuntimePort
	if gameplay_gateway == null or mode_adapter == null:
		_discard_unparented_game_runtime()
		return _fail_game_setup(
			"运行时缺少静态 Multiplayer Gateway/ModeAdapter。"
		)
	if not mode_adapter.accepts_game_mode_id(runtime_game_mode):
		_discard_unparented_game_runtime()
		return _fail_game_setup(
			(
				"运行时模式 %d（外层会话模式 %d）与 "
				+ "MultiplayerModeAdapter 不匹配。"
			)
			% [runtime_game_mode, session_game_mode]
		)
	if net_manager == null:
		_discard_unparented_game_runtime()
		return _fail_game_setup("多人协调器缺少强类型 NetManagerStore。")
	session_coordinator.bind_runtime(game)
	player_coordinator.bind_runtime(game)
	player_coordinator.bind_realtime_dependencies(
		net_manager,
		session_coordinator
	)
	enemy_coordinator.bind_runtime(game)
	enemy_coordinator.bind_lifecycle_dependencies(
		net_manager,
		gameplay_gateway,
		_get_net_time
	)
	projectile_coordinator.bind_runtime(game)
	projectile_coordinator.bind_network_facade_dependencies(
		net_manager,
		player_coordinator,
		_get_net_time,
		_get_unbounded_host_event_age,
		_is_embedded_participant_suspended
	)
	enemy_coordinator.bind_damage_dependencies(projectile_coordinator, self)
	world_flow_coordinator.bind_runtime(
		game,
		mode_adapter,
		enemy_coordinator,
		gameplay_gateway,
		run_state,
		net_manager,
		_linglan_boss_runtime_port
	)
	player_coordinator.bind_life_dependencies(
		net_manager,
		mode_adapter,
		projectile_coordinator,
		_get_net_time,
		_cancel_player_life_tango_for_revive_schedule,
		_cancel_player_life_actions_for_revive,
		_clear_player_life_tiyi_lifecycle_state,
		_get_player_life_revive_anchor_position,
		_commit_player_life_revive_position
	)
	player_coordinator.bind_player_action_dependencies(
		net_manager,
		_get_net_time,
		_is_embedded_participant_suspended
	)
	gameplay_gateway.attach_multiplayer_session(self)
	mode_adapter.attach_multiplayer_session(self)
	tower_mode_adapter = mode_adapter as TowerDefenseMultiplayerModeAdapter
	var tower_adapter := tower_mode_adapter
	transactions_coordinator.bind_session(
		self,
		game,
		mode_adapter,
		net_manager,
		run_state,
		_suspended_embedded_participant_peer_ids
	)
	merchant_transactions_coordinator.bind_runtime(
		game,
		mode_adapter,
		run_state,
		net_manager,
		session_coordinator.get_net_time_origin()
	)
	world_flow_coordinator.bind_merchant_transactions_coordinator(
		merchant_transactions_coordinator
	)
	collectible_presentation_coordinator.bind_runtime(
		game,
		self,
		net_manager,
		session_coordinator.get_net_time_origin()
	)
	if tower_adapter != null:
		tower_economy_coordinator.bind_runtime(
			game,
			tower_adapter,
			run_state,
			net_manager,
			session_coordinator.get_net_time_origin()
		)
		tower_world_coordinator.bind_session(
			self,
			session_coordinator,
			game,
			tower_adapter,
			net_manager,
			transactions_coordinator,
			enemy_coordinator,
			tower_economy_coordinator
		)
		tower_fate_coordinator.bind_runtime(
			game,
			tower_adapter,
			net_manager,
			session_coordinator.get_net_time_origin()
		)
	else:
		tower_economy_coordinator.reset_session_state()
		tower_world_coordinator.reset_session_state()
		tower_fate_coordinator.reset_session_state()
	var peer_ledger_role := (
		MpPeerLedgerCoordinatorScript.RuntimeRole.HOST
		if net_manager.is_host()
		else MpPeerLedgerCoordinatorScript.RuntimeRole.CLIENT
	)
	_peer_ledger_generation = peer_ledger_coordinator.bind_session(
		self,
		peer_ledger_role,
		net_manager.get_game_session_incarnation(),
		run_state.has_multiplayer_peer_state,
		_is_peer_result_envelope_ready,
		_commit_pending_peer_ledger_envelope
	)
	if _peer_ledger_generation <= 0:
		return _fail_game_setup("无法绑定跨信道玩家账本协调器。")
	if _peer_result_repair_needed:
		_schedule_peer_result_full_repair()
	session_coordinator.bind_world_manifest_dependencies(
		world_flow_coordinator,
		enemy_coordinator,
		tower_world_coordinator,
		tower_economy_coordinator
	)
	session_coordinator.bind_runtime_repair_dependencies(
		player_coordinator,
		transactions_coordinator,
		merchant_transactions_coordinator,
		tower_fate_coordinator,
		network_diagnostics_coordinator,
		projectile_coordinator,
		tower_mode_adapter
	)
	if net_manager.is_host():
		if _linglan_boss_runtime_port != null:
			_linglan_boss_runtime_port.airdrop_started.connect(
				_on_host_linglan_airdrop_started
			)
		mode_adapter.revive_all_requested.connect(_on_host_revive_all_requested)
		mode_adapter.restore_all_full_health_requested.connect(
			_on_host_restore_all_full_health_requested
		)
		gameplay_gateway.player_teleport_requested.connect(
			_on_host_player_teleport_requested
		)
		if tower_adapter != null:
			tower_adapter.xiaocong_fate_state_changed.connect(
				_on_host_xiaocong_fate_state_changed
			)
			tower_adapter.inventory_changed.connect(
				_on_host_multiplayer_inventory_changed
			)
	mode_adapter.profile_upgrade_requested.connect(
		request_multiplayer_upgrade
	)
	mode_adapter.profile_inventory_item_use_requested.connect(
		request_multiplayer_inventory_item_use
	)
	mode_adapter.profile_inventory_item_discard_requested.connect(
		request_multiplayer_inventory_item_discard
	)
	mode_adapter.profile_simple_crafting_requested.connect(
		request_multiplayer_simple_crafting
	)
	mode_adapter.profile_simple_crafting_cancel_requested.connect(
		cancel_multiplayer_simple_crafting_request
	)
	if tower_adapter != null:
		tower_adapter.xiaocong_interaction_requested.connect(
			_on_local_xiaocong_interaction_requested
		)
		tower_adapter.xiaocong_vote_requested.connect(
			_on_local_xiaocong_vote_requested
		)
		tower_adapter.xiaocong_collectible_requested.connect(
			_on_local_xiaocong_collectible_requested
		)
	mode_adapter.return_to_lobby_requested.connect(
		_on_game_return_to_lobby_requested
	)
	add_child(game)
	if tower_adapter != null:
		var rogue_route := tower_adapter.get_rogue_route()
		var rogue_combat := tower_adapter.get_rogue_combat_coordinator()
		if (
			rogue_route == null
			or rogue_combat == null
			or tower_rogue_route_bridge == null
			or not tower_rogue_route_bridge.bind_embedded_campaign_runtime(
				rogue_route,
				rogue_combat,
				net_manager,
				run_state,
				_send_tower_rogue_route_rpc
			)
		):
			return _fail_game_setup("无法绑定塔防内嵌地下探索多人桥。")
		if not tower_adapter.rogue_exploration_snapshot_changed.is_connected(
			_on_tower_rogue_exploration_snapshot_changed
		):
			tower_adapter.rogue_exploration_snapshot_changed.connect(
				_on_tower_rogue_exploration_snapshot_changed
			)
		if not tower_rogue_route_bridge.embedded_authoritative_snapshot_changed.is_connected(
			_on_tower_rogue_route_snapshot_refresh_requested
		):
			tower_rogue_route_bridge.embedded_authoritative_snapshot_changed.connect(
				_on_tower_rogue_route_snapshot_refresh_requested
			)
		tower_rogue_route_bridge.set_embedded_exploration_active(
			tower_adapter.is_rogue_exploration_active()
		)
	if not run_state.set_active_multiplayer_peer(local_peer_id):
		return _fail_game_setup("本机 peer 尚未注册为持久账本成员。")
	if net_manager.is_host() and _has_tower_mode():
		tower_world_coordinator.broadcast_base_health_snapshot()
	return true


func _fail_game_setup(reason: String) -> bool:
	_game_setup_failure_reason = reason
	push_error("MpGame: %s" % reason)
	return false


func _discard_unparented_game_runtime() -> void:
	_clear_reconnected_player_projection_state()
	_clear_peer_result_repair_state()
	if peer_ledger_coordinator != null:
		peer_ledger_coordinator.unbind_session(self)
	_peer_ledger_generation = 0
	if game != null and session_coordinator != null:
		session_coordinator.unbind_runtime(game)
	if game != null and merchant_transactions_coordinator != null:
		merchant_transactions_coordinator.unbind_runtime(game)
	if game != null and tower_fate_coordinator != null:
		tower_fate_coordinator.unbind_runtime(game)
	if game != null and collectible_presentation_coordinator != null:
		collectible_presentation_coordinator.unbind_runtime(game)
	if game != null and world_flow_coordinator != null:
		world_flow_coordinator.unbind_runtime(game)
	if game != null and player_coordinator != null:
		player_coordinator.unbind_runtime(game)
	if game != null and enemy_coordinator != null:
		enemy_coordinator.unbind_runtime(game)
	if game != null and projectile_coordinator != null:
		projectile_coordinator.unbind_runtime(game)
	if transactions_coordinator != null:
		transactions_coordinator.unbind_session(self)
	if tower_world_coordinator != null:
		tower_world_coordinator.unbind_session(self)
	if game != null and tower_economy_coordinator != null:
		tower_economy_coordinator.unbind_runtime(game)
	if game != null and is_instance_valid(game) and game.get_parent() == null:
		game.free()
	game = null
	_gameplay_gateway = null
	_mode_adapter = null
	tower_mode_adapter = null
	_linglan_boss_runtime_port = null


func _get_game_scene_path_for_mode(game_mode: int) -> String:
	if not runtime_scene_path_override.strip_edges().is_empty():
		return runtime_scene_path_override
	var definition := GameModeCatalog.get_definition(game_mode)
	return definition.multiplayer_runtime_scene_path if definition != null else ""


## CH6 权威结果可能先于 CH0 身份迁移到达。所有入口都先用 Host 分配的成员
## 世代解析当前 canonical peer；PeerLedger 只缓存完整事务，不再猜测旧传输身份。
func _receive_authoritative_peer_result(
	wire_peer_id: int,
	result_type: StringName,
	stream_id: StringName,
	revision: int,
	payload: Dictionary,
	participant_incarnation: int,
	session_incarnation: int,
	applied_replay_policy: int = (
		MpPeerLedgerCoordinatorScript.AppliedReplayPolicy.TRACK_REVISION
	)
) -> bool:
	if not _is_current_authoritative_session_incarnation(
		session_incarnation,
		stream_id
	):
		return false
	var peer_id := (
		net_manager.resolve_session_participant_peer_id(participant_incarnation)
		if net_manager != null
		else 0
	)
	if wire_peer_id <= 0 or peer_id <= 0:
		push_warning(
			"MpGame: 拒绝无法解析成员身份的 CH6 结果，wire_peer=%d participant=%d stream=%s。"
			% [wire_peer_id, participant_incarnation, stream_id]
		)
		_request_peer_result_full_repair()
		return false
	var envelope_result := peer_ledger_coordinator.receive_authoritative_result(
		_peer_ledger_generation,
		session_incarnation,
		peer_id,
		result_type,
		stream_id,
		revision,
		payload,
		-1,
		applied_replay_policy
	)
	if MpPeerLedgerCoordinatorScript.is_accepted_result(envelope_result):
		return true
	push_warning(
		"MpGame: 拒绝玩家 %d 的 %s 权威结果，session=%d stream=%s revision=%d code=%d。"
		% [
			wire_peer_id,
			result_type,
			session_incarnation,
			stream_id,
			revision,
			envelope_result,
		]
	)
	_request_peer_result_full_repair()
	return false


## 同一 RPC 也承载不属于任何玩家的全局科研推进；它不进入玩家账本，但仍须
## 遵守相同 wire 世代，避免旧局全局状态越过玩家信封边界。
func _is_current_authoritative_session_incarnation(
	session_incarnation: int,
	stream_id: StringName
) -> bool:
	var expected_session_incarnation := (
		peer_ledger_coordinator.get_session_incarnation()
		if peer_ledger_coordinator != null
		else 0
	)
	if (
		session_incarnation > 0
		and session_incarnation == expected_session_incarnation
	):
		return true
	push_warning(
		"MpGame: 拒绝 CH6 结果，session=%d expected=%d stream=%s。"
		% [session_incarnation, expected_session_incarnation, stream_id]
	)
	_request_peer_result_full_repair()
	return false


## 空快照是否有效由具体事务决定；非空快照必须先通过纯协议校验，不能等到
## 身份认领后才发现缓存内容无法提交。
func _get_authoritative_inventory_revision(
	peer_id: int,
	inventory_snapshot: Dictionary,
	empty_revision: int = -1
) -> int:
	if inventory_snapshot.is_empty():
		return empty_revision
	if not run_state.validate_inventory_snapshot_envelope(
		peer_id,
		inventory_snapshot
	):
		return -1
	return int(inventory_snapshot["revision"])


## 只有真正读写 Player 瞬时状态的结果需要等待 Player 投影。其余结果
## 仅依赖 RunState/领域账本，不应被断线期间的节点缺席拖住。该查询不写
## 任何状态，实际协议校验仍由下方领域 receiver 唯一负责。
func _is_peer_result_envelope_ready(
	peer_id: int,
	result_type: StringName,
	payload: Dictionary
) -> bool:
	if net_manager != null and not net_manager.is_session_member_active(peer_id):
		# 断线宽限期的 late CH6 必须留在 PeerLedger；否则领域状态会在
		# old peer 下提交，随后身份 remap 只能迁移账本却迁不走领域副作用。
		var runtime_projection_ready := (
			net_manager.is_session_member_reconnecting(peer_id)
			and (
				_completed_reconnected_player_projections.values().has(peer_id)
				or _suspended_embedded_participant_peer_ids.has(peer_id)
			)
		)
		if not runtime_projection_ready:
			return false
	var requires_player_projection := result_type in [
		PEER_RESULT_RESEARCH_STATE,
		PEER_RESULT_LUOXI_OFFER_STATE,
		PEER_RESULT_LUOXI_REFRESH,
		PEER_RESULT_CHEAT_XIRANG,
	]
	if result_type == PEER_RESULT_PICKUP_COLLECTED:
		requires_player_projection = bool(
			payload.get("applied_immediately", false)
		)
	elif result_type == PEER_RESULT_LUOXI_SPECIAL_FINISHED:
		var special_result_variant: Variant = payload.get("result", {})
		requires_player_projection = (
			typeof(special_result_variant) == TYPE_DICTIONARY
			and (special_result_variant as Dictionary).has("current_xirang")
		)
	if not requires_player_projection:
		return true
	if game == null or not is_instance_valid(game):
		return false
	var player_node := game.get_player_for_peer(peer_id)
	return (
		player_node != null
		and is_instance_valid(player_node)
		and not player_node.is_queued_for_deletion()
	)


## PeerLedgerCoordinator 只编排身份、投影就绪、乱序与容量；认领和即时
## 提交都回到同一个原领域 receiver，避免把 durable 账本从 request_id、
## UI token 或实体终结拆开。
func _commit_pending_peer_ledger_envelope(
	peer_id: int,
	result_type: StringName,
	stream_id: StringName,
	_revision: int,
	payload: Dictionary
) -> bool:
	match result_type:
		PEER_RESULT_INVENTORY_SNAPSHOT:
			return transactions_coordinator.receive_inventory_snapshot(
				peer_id,
				_rehydrate_inventory_snapshot(peer_id, payload),
				bool(payload["force_inventory_repair"])
			)
		PEER_RESULT_WAREHOUSE_COMMAND:
			var warehouse_result := _decode_subject_dictionary(
				peer_id,
				payload["result"] as Dictionary
			)
			return tower_economy_coordinator.receive_warehouse_command_result(
				warehouse_result
			)
		PEER_RESULT_PICKUP_COLLECTED:
			return world_flow_coordinator.receive_pickup_collected(
				int(payload["net_id"]),
				peer_id,
				str(payload["config_path"]),
				bool(payload["applied_immediately"]),
				_rehydrate_inventory_snapshot(peer_id, payload)
			)
		PEER_RESULT_UPGRADE_CONFIRMED:
			return transactions_coordinator.receive_upgrade_confirmation(
				peer_id,
				int(payload["stat_type"]),
				int(payload["level"]),
				int(payload["current_xirang"]),
				bool(payload["success"]),
				bool(payload["free_upgrade"])
			)
		PEER_RESULT_INVENTORY_ITEM_USED:
			return transactions_coordinator.receive_inventory_item_used(
				peer_id,
				int(payload["slot_index"]),
				str(payload["config_path"]),
				bool(payload["success"]),
				_rehydrate_inventory_snapshot(peer_id, payload),
				bool(payload["force_inventory_repair"])
			)
		PEER_RESULT_INVENTORY_ITEM_DISCARDED:
			return transactions_coordinator.receive_inventory_item_discarded(
				peer_id,
				int(payload["slot_index"]),
				bool(payload["success"]),
				_rehydrate_inventory_snapshot(peer_id, payload),
				bool(payload["force_inventory_repair"])
			)
		PEER_RESULT_SIMPLE_CRAFTING:
			return transactions_coordinator.receive_simple_crafting_result(
				peer_id,
				int(payload["request_id"]),
				str(payload["recipe_id"]),
				str(payload["result"]),
				_resolve_crafting_inventory_snapshot(peer_id, payload),
				bool(payload["force_inventory_repair"])
			)
		PEER_RESULT_SKILL1_PURCHASE:
			return transactions_coordinator.receive_skill1_purchase_confirmation(
				peer_id,
				int(payload["current_xirang"]),
				bool(payload["skill1_unlocked"]),
				int(payload["result_code"]),
				int(payload["skill1_upgrade_level"]),
				float(payload["skill1_charge_duration"])
			)
		PEER_RESULT_RESEARCH_STATE:
			return tower_economy_coordinator.receive_research_state_updated(
				_decode_research_state_for_subject(peer_id, payload),
				peer_id,
				int(payload["current_xirang"])
			)
		PEER_RESULT_LUOXI_OFFER_STATE:
			return merchant_transactions_coordinator.receive_luoxi_collectible_offer_state(
				peer_id,
				int(payload["offer_revision"]),
				PackedStringArray(payload["config_paths"] as Array),
				int(payload["refresh_count"]),
				int(payload["current_xirang"]),
				int(payload["refresh_result_code"])
			)
		PEER_RESULT_LUOXI_COLLECTIBLE:
			return merchant_transactions_coordinator.receive_luoxi_collectible_confirmation(
				peer_id,
				int(payload["choice_index"]),
				str(payload["config_path"]),
				int(payload["result_code"]),
				int(payload["offer_revision"]),
				_rehydrate_inventory_snapshot(peer_id, payload)
			)
		PEER_RESULT_LUOXI_REFRESH:
			return merchant_transactions_coordinator.receive_luoxi_collectible_refresh_confirmation(
				peer_id,
				int(payload["result_code"]),
				int(payload["refresh_count"]),
				int(payload["current_xirang"])
			)
		PEER_RESULT_LUOXI_SPECIAL_STARTED:
			return merchant_transactions_coordinator.receive_luoxi_special_game_started(
				peer_id,
				_decode_subject_dictionary(
					peer_id,
					payload["result"] as Dictionary
				),
				_rehydrate_inventory_snapshot(peer_id, payload)
			)
		PEER_RESULT_LUOXI_SPECIAL_CARD:
			return merchant_transactions_coordinator.receive_luoxi_special_game_card_revealed(
				peer_id,
				_decode_subject_dictionary(
					peer_id,
					payload["result"] as Dictionary
				)
			)
		PEER_RESULT_LUOXI_SPECIAL_FINISHED:
			return merchant_transactions_coordinator.receive_luoxi_special_game_finished(
				peer_id,
				_decode_subject_dictionary(
					peer_id,
					payload["result"] as Dictionary
				),
				_rehydrate_inventory_snapshot(peer_id, payload)
			)
		PEER_RESULT_CHEAT_XIRANG:
			return merchant_transactions_coordinator.receive_cheat_xirang_confirmation(
				peer_id,
				int(payload["current_xirang"]),
				int(payload["added_amount"])
			)
		PEER_RESULT_DEBUG_COLLECTIBLE:
			return merchant_transactions_coordinator.receive_debug_collectible_granted(
				peer_id,
				str(payload["config_path"]),
				bool(payload["success"]),
				_rehydrate_inventory_snapshot(peer_id, payload)
			)
	push_warning(
		"MpGame: 未识别的玩家权威结果 type=%s stream=%s。"
		% [result_type, stream_id]
	)
	return false


func _rehydrate_inventory_snapshot(
	peer_id: int,
	payload: Dictionary
) -> Dictionary:
	var inventory_snapshot := (
		payload.get("inventory_snapshot", {}) as Dictionary
	).duplicate(true)
	if not inventory_snapshot.is_empty():
		inventory_snapshot["peer_id"] = peer_id
	return inventory_snapshot


func _resolve_crafting_inventory_snapshot(
	peer_id: int,
	payload: Dictionary
) -> Dictionary:
	var inventory_snapshot := _rehydrate_inventory_snapshot(peer_id, payload)
	if inventory_snapshot.is_empty():
		return inventory_snapshot
	var incoming_revision := int(inventory_snapshot.get("revision", -1))
	var current_revision := run_state.get_inventory_revision_for_peer(peer_id)
	if incoming_revision >= current_revision:
		return inventory_snapshot
	# CH0/其他 CH6 可能已经提交了更晚背包。制作结果仍需用 request_id 结算
	# 本地 UI token；用当前权威账本作为 fence，绝不能为了旧结果倒退库存。
	return run_state.export_inventory_snapshot_for_peer(peer_id)


func _make_identity_neutral_inventory_snapshot(snapshot: Dictionary) -> Dictionary:
	var neutral := snapshot.duplicate(true)
	neutral.erase("peer_id")
	return neutral


## 部分领域 Dictionary 会重复携带 subject peer。codec 把每一层 peer_id
## 替换为不含旧值的标记；提交时再用 participant 解析后的 canonical peer 回填。
## 若出现与 envelope subject 不一致的身份，整包拒绝，绝不让嵌套 old id 穿透。
func _encode_subject_dictionary(
	peer_id: int,
	source: Dictionary
) -> Dictionary:
	return _encode_subject_value(peer_id, source)


func _encode_subject_value(peer_id: int, value: Variant) -> Dictionary:
	if typeof(value) == TYPE_DICTIONARY:
		var encoded_dictionary := {}
		for key in (value as Dictionary).keys():
			if (
				typeof(key) in [TYPE_STRING, TYPE_STRING_NAME]
				and str(key) == String(SUBJECT_IDENTITY_MARKER)
			):
				return {"accepted": false, "value": {}}
			if (
				typeof(key) in [TYPE_STRING, TYPE_STRING_NAME]
				and str(key) == "peer_id"
			):
				if typeof((value as Dictionary)[key]) != TYPE_INT:
					return {"accepted": false, "value": {}}
				if int((value as Dictionary)[key]) != peer_id:
					return {"accepted": false, "value": {}}
				encoded_dictionary[SUBJECT_IDENTITY_MARKER] = true
				continue
			var child := _encode_subject_value(
				peer_id,
				(value as Dictionary)[key]
			)
			if not bool(child.get("accepted", false)):
				return {"accepted": false, "value": {}}
			encoded_dictionary[key] = child["value"]
		return {"accepted": true, "value": encoded_dictionary}
	if typeof(value) == TYPE_ARRAY:
		var encoded_array: Array = []
		for child_value in value as Array:
			var child := _encode_subject_value(peer_id, child_value)
			if not bool(child.get("accepted", false)):
				return {"accepted": false, "value": {}}
			encoded_array.append(child["value"])
		return {"accepted": true, "value": encoded_array}
	return {"accepted": true, "value": value}


func _decode_subject_dictionary(
	peer_id: int,
	encoded: Dictionary
) -> Dictionary:
	return _decode_subject_value(peer_id, encoded) as Dictionary


func _decode_subject_value(peer_id: int, value: Variant) -> Variant:
	if typeof(value) == TYPE_DICTIONARY:
		var decoded_dictionary := {}
		for key in (value as Dictionary).keys():
			if key == SUBJECT_IDENTITY_MARKER:
				decoded_dictionary["peer_id"] = peer_id
				continue
			decoded_dictionary[key] = _decode_subject_value(
				peer_id,
				(value as Dictionary)[key]
			)
		return decoded_dictionary
	if typeof(value) == TYPE_ARRAY:
		var decoded_array: Array = []
		for child_value in value as Array:
			decoded_array.append(_decode_subject_value(peer_id, child_value))
		return decoded_array
	return value


func _encode_research_state_for_subject(
	peer_id: int,
	state: Dictionary
) -> Dictionary:
	var encoded := _encode_subject_dictionary(peer_id, state)
	if not bool(encoded.get("accepted", false)):
		return {"accepted": false}
	var neutral_state := (encoded["value"] as Dictionary).duplicate(true)
	var player_levels := (
		neutral_state.get("player_levels", {}) as Dictionary
	).duplicate(true)
	var has_changed_level := player_levels.has(peer_id)
	var changed_level := int(player_levels.get(peer_id, 0))
	player_levels.erase(peer_id)
	neutral_state["player_levels"] = player_levels
	return {
		"accepted": true,
		"state": neutral_state,
		"has_changed_player_level": has_changed_level,
		"changed_player_level": changed_level,
	}


func _decode_research_state_for_subject(
	peer_id: int,
	payload: Dictionary
) -> Dictionary:
	var state := _decode_subject_dictionary(
		peer_id,
		payload["state"] as Dictionary
	)
	if bool(payload["has_changed_player_level"]):
		var player_levels := (
			state.get("player_levels", {}) as Dictionary
		).duplicate(true)
		player_levels[peer_id] = int(payload["changed_player_level"])
		state["player_levels"] = player_levels
	return state


func _claim_pending_peer_ledgers(peer_id: int) -> bool:
	if _peer_ledger_generation <= 0:
		push_warning("MpGame: 玩家身份已迁移，但跨信道账本协调器未绑定。")
		return false
	var claim := peer_ledger_coordinator.claim_authenticated_peer(
		_peer_ledger_generation,
		peer_id
	)
	if not bool(claim.get("accepted", false)):
		push_warning("MpGame: 无法认领玩家 %d 的跨信道账本。" % peer_id)
		_request_peer_result_full_repair()
		return false
	var rejected_count := int(claim.get("rejected", 0))
	if rejected_count <= 0:
		return true
	push_warning(
		"MpGame: 玩家 %d 有 %d 份跨信道账本提交失败，申请完整状态修复。"
		% [peer_id, rejected_count]
	)
	_request_peer_result_full_repair()
	return false


## 重连身份事务只迁移持久身份与 old/new 结果记录。结果认领必须等 Player
## 或 SUSPENDED 终态先建立，否则依赖表现节点的完整 CH6 信封会被提前拒绝。
func _commit_reconnected_peer_identity(
	old_peer_id: int,
	new_peer_id: int,
	membership_revision: int
) -> bool:
	var remap_result := run_state.remap_multiplayer_peer_state(
		old_peer_id,
		new_peer_id,
		membership_revision
	)
	if remap_result not in [
		RunStateStore.MultiplayerPeerRemapResult.MIGRATED,
		RunStateStore.MultiplayerPeerRemapResult.ALREADY_CURRENT,
	]:
		_abort_reconnected_peer_result_identity(old_peer_id, new_peer_id)
		push_error(
			"MpGame: 重连玩家 %d -> %d 的持久账本事务失败，result=%d revision=%d。"
			% [old_peer_id, new_peer_id, remap_result, membership_revision]
		)
		return false
	if _peer_ledger_generation <= 0:
		push_error("MpGame: 身份事务已提交，但跨信道结果协调器没有活动租约。")
		return false
	if net_manager.is_client() and _peer_ledger_generation > 0:
		var ledger_remap := peer_ledger_coordinator.remap_authenticated_peer(
			_peer_ledger_generation,
			old_peer_id,
			new_peer_id
		)
		if not bool(ledger_remap.get("accepted", false)):
			_abort_reconnected_peer_result_identity(old_peer_id, new_peer_id)
			push_warning(
				"MpGame: 玩家 %d -> %d 的跨信道记录迁移失败：%s。"
				% [old_peer_id, new_peer_id, ledger_remap.get("reason", &"")]
			)
			_request_peer_result_full_repair()
			return false
		elif int(ledger_remap.get("conflicts", 0)) > 0:
			_abort_reconnected_peer_result_identity(old_peer_id, new_peer_id)
			push_warning(
				"MpGame: 玩家 %d -> %d 的跨信道结果发生 %d 个冲突，申请完整状态修复。"
				% [
					old_peer_id,
					new_peer_id,
					int(ledger_remap["conflicts"]),
				]
			)
			_request_peer_result_full_repair()
			return false
	return true


func _finalize_reconnected_projection_and_claim(
	old_peer_id: int,
	new_peer_id: int,
	outcome: ReconnectedPlayerProjectionOutcome
) -> bool:
	if not _claim_pending_peer_ledgers(new_peer_id):
		_fail_reconnected_peer_identity(
			old_peer_id,
			new_peer_id,
			"重连投影已建立，但跨信道权威结果无法认领。"
		)
		return false
	# 结果认领已在 Player/路线之后成功；从这一行开始，RESTORED 参与者才拥有
	# 完整战斗能力。SUSPENDED 由独立终态租约继续排除，不与 PROJECTING 混用。
	_projecting_embedded_participant_peer_ids.erase(new_peer_id)
	# capture 只服务本次 old transport。RESTORED 已复制到 Player，SUSPENDED
	# 明确不会在本轮重建 Player；两者都不能留下可被 raw peer ID 复用的旧记录。
	_disconnected_player_reconnect_states.erase(old_peer_id)
	_publish_reconnected_player_projection_outcome(
		old_peer_id,
		new_peer_id,
		outcome
	)
	return true


func _abort_reconnected_peer_result_identity(
	old_peer_id: int,
	new_peer_id: int
) -> void:
	if _peer_ledger_generation <= 0 or peer_ledger_coordinator == null:
		return
	# 身份门失败后本次连接会同步终止；先在领域边界撤销整条 old/new
	# 结果租约，不能依赖稍后的场景切换间接清理跨信道状态。
	peer_ledger_coordinator.abort_authenticated_peer_remap(
		_peer_ledger_generation,
		old_peer_id,
		new_peer_id
	)


func _request_runtime_state_from_host(is_runtime_repair: bool = false) -> bool:
	var repair_request_id := 0
	if is_runtime_repair:
		repair_request_id = (
			session_coordinator.try_begin_client_runtime_repair_request(
				net_manager.is_client(),
				_client_host_game_ready
			)
		)
		if repair_request_id <= 0:
			return false
	elif not session_coordinator.try_begin_client_runtime_state_request(
		net_manager.is_client(),
		_client_host_game_ready
	):
		return false
	tower_world_coordinator.begin_runtime_state_request()
	var request_sent := _rpc_to_peer(
		_get_host_peer_id(),
		&"net_runtime_state_requested",
		[not world_flow_coordinator.has_received_flow_state()]
	)
	if not request_sent and repair_request_id > 0:
		# 发送边界拒绝时释放租约并保留 deferred；不能把“本地未发送”误当成
		# 远端修复完成，也不能立即无界重发。
		session_coordinator.fail_client_runtime_repair_request(
			repair_request_id
		)
	return request_sent


func _send_live_plant_roster_to_peer(peer_id: int) -> void:
	tower_world_coordinator.send_live_plant_roster_to_peer(peer_id)


func _host_physics_tick(frame: int, _delta: float) -> void:
	if game == null:
		return
	player_coordinator.update_player_revives()
	if _host_startup_snapshot_grace_time_left > 0.0:
		_host_startup_snapshot_grace_time_left = maxf(
			_host_startup_snapshot_grace_time_left - _delta,
			0.0
		)
		return
	var client_peer_ids := _get_connected_client_peer_ids()
	_sync_snapshot_cohort_readiness(client_peer_ids)
	player_coordinator.update_host_realtime_snapshots(
		frame,
		client_peer_ids
	)
	var enemy_snapshot_interval_frames := enemy_coordinator.get_snapshot_interval_frames()
	if frame % enemy_snapshot_interval_frames == 0:
		enemy_coordinator.broadcast_host_enemy_snapshots(
			client_peer_ids,
			_get_net_time()
		)
	enemy_coordinator.update_host()


func _sync_snapshot_cohort_readiness(ready_peer_ids: Array[int]) -> void:
	player_coordinator.sync_snapshot_cohort_readiness(ready_peer_ids)
	enemy_coordinator.sync_snapshot_cohort_readiness(ready_peer_ids)


func _get_connected_client_peer_ids() -> Array[int]:
	return session_coordinator.get_connected_client_peer_ids(
		embedded_runtime,
		_embedded_participant_peer_ids,
		_suspended_embedded_participant_peer_ids
	)


func _filter_embedded_peer_map(source: Dictionary) -> Dictionary:
	if not embedded_runtime:
		return source
	var filtered: Dictionary = {}
	for peer_id in _embedded_participant_peer_ids:
		if source.has(peer_id):
			filtered[peer_id] = source[peer_id]
	return filtered


# 协调器先在所有参与者创建稳定 RPC 路径，再打开 prepare/activate 屏障。
# StandardGame._ready() 可能在屏障前发出商店或背包信号；此时抑制瞬时包，
# 激活后的完整运行时修复会补齐所有权威状态信道。
func _rpc_to_peer(
	peer_id: int,
	method_name: StringName,
	args: Array = [],
	record_outbound: bool = true
) -> bool:
	if peer_id <= 0:
		return false
	var wire_args := _build_outbound_rpc_arguments(method_name, args)
	if PEER_RESULT_RPC_METHODS.has(method_name) and wire_args.is_empty():
		return false
	var rpc_args: Array = [peer_id, method_name]
	rpc_args.append_array(wire_args)
	callv(&"rpc_id", rpc_args)
	if record_outbound:
		_record_outbound_rpc(method_name, wire_args)
	return true


func _rpc_to_connected_clients(method_name: StringName, args: Array = []) -> void:
	if embedded_runtime and not _embedded_runtime_active:
		return
	var wire_args := _build_outbound_rpc_arguments(method_name, args)
	if PEER_RESULT_RPC_METHODS.has(method_name) and wire_args.is_empty():
		return
	var peer_ids := _get_connected_client_peer_ids()
	for peer_id in peer_ids:
		var rpc_args: Array = [peer_id, method_name]
		rpc_args.append_array(wire_args)
		callv("rpc_id", rpc_args)
	if not peer_ids.is_empty():
		_record_outbound_rpc(method_name, wire_args, peer_ids.size())


## CH6 结果由唯一发送边界追加成员世代与游戏世代。成员世代描述结果 subject，
## 绝不能误用 `_rpc_to_peer` 的接收者；领域协调器仍只负责业务参数。
func _build_outbound_rpc_arguments(
	method_name: StringName,
	args: Array
) -> Array:
	var wire_args := args.duplicate()
	if not PEER_RESULT_RPC_METHODS.has(method_name):
		return wire_args
	var session_incarnation := net_manager.get_game_session_incarnation()
	if session_incarnation <= 0:
		push_error(
			"MpGame: CH6 玩家结果缺少有效会话世代，拒绝发送 %s。"
			% method_name
		)
		return []
	var subject_peer_id := _extract_peer_result_subject_peer_id(method_name, args)
	if subject_peer_id < 0:
		push_error("MpGame: 无法提取 CH6 结果 %s 的 subject，拒绝发送。" % method_name)
		return []
	var participant_incarnation := 0
	if subject_peer_id == 0:
		if method_name != &"net_research_state_updated":
			push_error("MpGame: 只有全局科研结果允许使用 peer 0。")
			return []
	else:
		participant_incarnation = net_manager.get_session_participant_incarnation(
			subject_peer_id
		)
		if participant_incarnation <= 0:
			push_error(
				"MpGame: CH6 结果 %s 的成员 %d 没有活动 participant incarnation。"
				% [method_name, subject_peer_id]
			)
			return []
	wire_args.append(participant_incarnation)
	wire_args.append(session_incarnation)
	return wire_args


func _extract_peer_result_subject_peer_id(
	method_name: StringName,
	args: Array
) -> int:
	if not PEER_RESULT_RPC_METHODS.has(method_name):
		return -1
	var argument_index := int(PEER_RESULT_RPC_METHODS[method_name])
	if argument_index < 0:
		if args.is_empty() or typeof(args[0]) != TYPE_DICTIONARY:
			return -1
		var result := args[0] as Dictionary
		if typeof(result.get("peer_id")) != TYPE_INT:
			return -1
		return int(result["peer_id"])
	if argument_index >= args.size() or typeof(args[argument_index]) != TYPE_INT:
		return -1
	return int(args[argument_index])


func _record_outbound_rpc(
	method_name: StringName,
	args: Array,
	packet_count: int = 1
) -> void:
	_get_network_diagnostics_coordinator().record_outbound_rpc(
		method_name,
		args,
		packet_count
	)


func set_rpc_payload_diagnostics_enabled(enabled: bool) -> void:
	_get_network_diagnostics_coordinator().set_rpc_payload_diagnostics_enabled(enabled)


func _get_rpc_traffic_channel(method_name: StringName) -> int:
	return _get_network_diagnostics_coordinator().get_rpc_traffic_channel(method_name)


func _update_snapshot_packet_warning_timer(delta: float) -> void:
	_get_network_diagnostics_coordinator().update_snapshot_packet_warning_timer(delta)


func _record_snapshot_packet_size(
	snapshot_type: StringName,
	packet_bytes: int,
	entity_count: int
) -> void:
	_get_network_diagnostics_coordinator().record_snapshot_packet_size(
		snapshot_type,
		packet_bytes,
		entity_count
	)


func get_snapshot_packet_metrics() -> Dictionary:
	var enemy_metrics := enemy_coordinator.get_snapshot_metrics()
	var pool_metrics: Dictionary = {}
	if game != null:
		var object_pool := game.get_node_or_null("SessionObjectPool") as SessionObjectPool
		if object_pool != null:
			pool_metrics = object_pool.get_all_metrics()
	return _get_network_diagnostics_coordinator().get_snapshot_packet_metrics(
		player_coordinator.get_snapshot_encode_count(),
		player_coordinator.get_snapshot_cohort_size(),
		enemy_metrics,
		pool_metrics
	)


func _get_network_diagnostics_coordinator() -> MpNetworkDiagnosticsCoordinatorScript:
	var coordinator := network_diagnostics_coordinator
	# Packed-scene contract tests may call diagnostics before _ready assigns the
	# cached @onready reference. The fixed NodePath still enforces static assembly.
	if coordinator == null:
		coordinator = (
			get_node(^"NetworkDiagnosticsCoordinator")
			as MpNetworkDiagnosticsCoordinatorScript
		)
	if coordinator != null and not coordinator.is_rpc_source_bound():
		if not coordinator.bind_rpc_source(self):
			push_error("MpGame: 无法从 Godot RPC 元数据建立诊断信道表。")
	return coordinator


func _client_physics_tick(frame: int) -> void:
	player_coordinator.update_client_realtime_input(
		frame,
		_client_host_game_ready
	)


func _client_send_input_if_needed(buttons: int) -> void:
	player_coordinator.send_client_input_if_needed(buttons)


func _is_client_input_state_active(
	move_input: Vector2,
	shoot_input: Vector2,
	velocity: Vector2,
	uses_passive_tango_mouse_aim: bool
) -> bool:
	return player_coordinator.is_client_input_state_active(
		move_input,
		shoot_input,
		velocity,
		uses_passive_tango_mouse_aim
	)


func _client_interpolate_entities() -> void:
	if game == null:
		return
	player_coordinator.interpolate_client_players()
	enemy_coordinator.interpolate_remote_enemies(_get_net_time())


@rpc("authority", "call_remote", "unreliable_ordered", 2)
func _rpc_receive_player_snapshot(host_timestamp: float, data: PackedByteArray) -> void:
	if _is_tower_world_suspended_for_rogue_exploration():
		return
	player_coordinator.receive_authoritative_player_snapshot(
		host_timestamp,
		data
	)


@rpc("authority", "call_remote", "unreliable", 3)
func _rpc_receive_enemy_snapshot(
	host_timestamp: float,
	data: PackedByteArray,
	batch_id: int = 0,
	chunk_index: int = 0,
	chunk_count: int = 1,
	snapshot_hz: int = _NetConstants.ENEMY_SNAPSHOT_HZ
) -> void:
	if _is_tower_world_suspended_for_rogue_exploration():
		return
	var snapshot_time := _map_host_timestamp_to_client_time(host_timestamp)
	enemy_coordinator.apply_authoritative_snapshot(
		snapshot_time,
		data,
		batch_id,
		chunk_index,
		chunk_count,
		snapshot_hz
	)


@rpc("any_peer", "call_remote", "unreliable_ordered", 1)
func _rpc_client_player_state(
	sequence: int,
	reported_position: Vector2,
	reported_velocity: Vector2,
	move_input: Vector2,
	shoot_input: Vector2,
	buttons: int,
	dash_request_sequence: int,
	dash_direction: Vector2,
	dash_start_move_input: Vector2
) -> void:
	if (
		_is_tower_world_suspended_for_rogue_exploration()
		or net_manager == null
		or not net_manager.is_host()
	):
		return
	var sender_id := _get_rpc_sender_id()
	player_coordinator.handle_client_player_state(
		sender_id,
		sequence,
		reported_position,
		reported_velocity,
		move_input,
		shoot_input,
		buttons,
		dash_request_sequence,
		dash_direction,
		dash_start_move_input
	)


@rpc("any_peer", "call_remote", "reliable", 5)
func net_player_dash_requested(
	dash_request_sequence: int,
	direction: Vector2,
	start_move_input: Vector2
) -> void:
	if (
		_is_tower_world_suspended_for_rogue_exploration()
		or net_manager == null
		or not net_manager.is_host()
	):
		return
	var sender_id := _get_rpc_sender_id()
	player_coordinator.handle_dash_request(
		sender_id,
		dash_request_sequence,
		direction,
		start_move_input
	)


func _try_accept_client_dash_request(
	peer_id: int,
	player_node: Player,
	dash_request_sequence: int,
	direction: Vector2,
	movement_evidence: Vector2
) -> bool:
	return player_coordinator.try_accept_client_dash_request(
		peer_id,
		player_node,
		dash_request_sequence,
		direction,
		movement_evidence
	)


@rpc("authority", "call_remote", "reliable", 5)
func net_player_dash_confirmed(
	player_peer_id: int,
	direction: Vector2,
	dash_request_sequence: int
) -> void:
	player_coordinator.apply_dash_confirmation(
		player_peer_id,
		direction,
		dash_request_sequence
	)


@rpc("any_peer", "call_remote", "reliable", 5)
func net_hoe_primary_attack_requested(direction: Vector2, request_id: int = 0) -> void:
	if _is_tower_world_suspended_for_rogue_exploration():
		return
	var sender_id := _get_rpc_sender_id()
	player_coordinator.handle_hoe_primary_request(
		sender_id,
		direction,
		request_id
	)


@rpc("any_peer", "call_remote", "reliable", 5)
func net_hoe_whirlwind_requested(request_id: int = 0) -> void:
	if _is_tower_world_suspended_for_rogue_exploration():
		return
	var sender_id := _get_rpc_sender_id()
	player_coordinator.handle_hoe_whirlwind_request(sender_id, request_id)


func _apply_authoritative_hoe_action(
	peer_id: int,
	action_kind: StringName,
	direction: Vector2,
	request_id: int = 0
) -> bool:
	return player_coordinator.apply_authoritative_hoe_action(
		peer_id,
		action_kind,
		direction,
		request_id
	)


@rpc("authority", "call_remote", "reliable", 5)
func net_hoe_action_confirmed(
	peer_id: int,
	action_kind_text: String,
	direction: Vector2,
	action_sequence: int,
	request_id: int = 0,
	accepted: bool = true,
	cooldown_ratio: float = 0.0,
	skill_charge: float = -1.0
) -> void:
	var sender_id := multiplayer.get_remote_sender_id()
	player_coordinator.apply_hoe_action_confirmation(
		sender_id,
		peer_id,
		action_kind_text,
		direction,
		action_sequence,
		request_id,
		accepted,
		cooldown_ratio,
		skill_charge
	)


@rpc("any_peer", "call_remote", "reliable", 5)
func net_tango_electric_surge_requested(request_id: int) -> void:
	if _is_tower_world_suspended_for_rogue_exploration():
		return
	var sender_id := _get_rpc_sender_id()
	player_coordinator.handle_tango_electric_surge_request(sender_id, request_id)


func _apply_authoritative_tango_electric_surge_request(
	peer_id: int,
	request_id: int
) -> bool:
	return player_coordinator.apply_authoritative_tango_electric_surge_request(
		peer_id,
		request_id
	)


@rpc("authority", "call_remote", "reliable", 5)
func net_tango_electric_surge_started(
	peer_id: int,
	activation_id: int,
	origin: Vector2,
	remaining_seconds_at_send: float,
	host_sent_at: float,
	buff_active: bool,
	request_id: int,
	auto_fire_charge_sequence: int
) -> void:
	var sender_id := multiplayer.get_remote_sender_id()
	player_coordinator.receive_tango_electric_surge_started(
		sender_id,
		peer_id,
		activation_id,
		origin,
		remaining_seconds_at_send,
		host_sent_at,
		buff_active,
		request_id,
		auto_fire_charge_sequence
	)


@rpc("authority", "call_remote", "reliable", 5)
func net_tango_electric_surge_finished(peer_id: int, activation_id: int) -> void:
	var sender_id := multiplayer.get_remote_sender_id()
	player_coordinator.apply_tango_electric_surge_finished(
		sender_id,
		peer_id,
		activation_id
	)


func _finish_authoritative_tango_electric_surge(
	peer_id: int,
	activation_id: int
) -> void:
	player_coordinator.finish_authoritative_tango_electric_surge(
		peer_id,
		activation_id
	)


@rpc("any_peer", "call_remote", "reliable", 5)
func net_tango_charge_started_requested(direction: Vector2, request_id: int) -> void:
	if _is_tower_world_suspended_for_rogue_exploration():
		return
	var sender_id := _get_rpc_sender_id()
	player_coordinator.handle_tango_charge_started_request(
		sender_id,
		direction,
		request_id
	)


@rpc("any_peer", "call_remote", "reliable", 5)
func net_tango_charge_released_requested(direction: Vector2, request_id: int) -> void:
	if _is_tower_world_suspended_for_rogue_exploration():
		return
	var sender_id := _get_rpc_sender_id()
	player_coordinator.handle_tango_charge_released_request(
		sender_id,
		direction,
		request_id
	)


@rpc("any_peer", "call_remote", "reliable", 5)
func net_tango_charge_cancelled_requested(request_id: int) -> void:
	if _is_tower_world_suspended_for_rogue_exploration():
		return
	var sender_id := _get_rpc_sender_id()
	player_coordinator.handle_tango_charge_cancelled_request(sender_id, request_id)


func _apply_authoritative_tango_charge_started(
	peer_id: int,
	direction: Vector2,
	request_id: int
) -> bool:
	return player_coordinator.apply_authoritative_tango_charge_started(
		peer_id,
		direction,
		request_id
	)


func _apply_authoritative_tango_charge_cancelled(peer_id: int, request_id: int) -> bool:
	return player_coordinator.apply_authoritative_tango_charge_cancelled(
		peer_id,
		request_id
	)


func _cancel_authoritative_tango_charge(
	peer_id: int,
	broadcast_cancel: bool,
	request_id: int = 0
) -> void:
	player_coordinator.cancel_authoritative_tango_charge(
		peer_id,
		broadcast_cancel,
		request_id
	)


func _update_authoritative_tango_charge_lifecycle() -> void:
	player_coordinator.update_authoritative_tango_charge_lifecycle()


@rpc("authority", "call_remote", "reliable", 5)
func net_tango_charge_started(
	peer_id: int,
	direction: Vector2,
	charge_sequence: int,
	request_id: int
) -> void:
	var sender_id := multiplayer.get_remote_sender_id()
	player_coordinator.apply_tango_charge_started(
		sender_id,
		peer_id,
		direction,
		charge_sequence,
		request_id
	)


@rpc("authority", "call_remote", "reliable", 5)
func net_tango_charge_released(
	peer_id: int,
	direction: Vector2,
	charge_ratio: float,
	charge_sequence: int,
	request_id: int
) -> void:
	var sender_id := multiplayer.get_remote_sender_id()
	player_coordinator.apply_tango_charge_released(
		sender_id,
		peer_id,
		direction,
		charge_ratio,
		charge_sequence,
		request_id
	)


@rpc("authority", "call_remote", "reliable", 5)
func net_tango_charge_cancelled(
	peer_id: int,
	charge_sequence: int,
	request_id: int
) -> void:
	var sender_id := multiplayer.get_remote_sender_id()
	player_coordinator.apply_tango_charge_cancelled(
		sender_id,
		peer_id,
		charge_sequence,
		request_id
	)


@rpc("authority", "call_remote", "reliable", 5)
func net_tango_charge_rejected(peer_id: int, request_id: int, phase_text: String) -> void:
	var sender_id := multiplayer.get_remote_sender_id()
	player_coordinator.apply_tango_charge_rejected(
		sender_id,
		peer_id,
		request_id,
		phase_text
	)


@rpc("any_peer", "call_remote", "reliable", 5)
func net_tiyi_high_noon_requested(activation_id: int) -> void:
	if _is_tower_world_suspended_for_rogue_exploration():
		return
	var sender_id := _get_rpc_sender_id()
	player_coordinator.handle_tiyi_high_noon_request(sender_id, activation_id)


func _apply_authoritative_tiyi_high_noon_request(
	peer_id: int,
	activation_id: int
) -> bool:
	return player_coordinator.apply_authoritative_tiyi_high_noon_request(
		peer_id,
		activation_id
	)


@rpc("authority", "call_remote", "reliable", 5)
func net_tiyi_high_noon_started(peer_id: int, activation_id: int) -> void:
	var sender_id := multiplayer.get_remote_sender_id()
	player_coordinator.apply_tiyi_high_noon_started(
		sender_id,
		peer_id,
		activation_id
	)


@rpc("authority", "call_remote", "reliable", 5)
func net_tiyi_high_noon_targets(
	peer_id: int,
	activation_id: int,
	target_ids: PackedInt32Array
) -> void:
	var sender_id := multiplayer.get_remote_sender_id()
	player_coordinator.apply_tiyi_high_noon_targets(
		sender_id,
		peer_id,
		activation_id,
		target_ids
	)


@rpc("authority", "call_remote", "reliable", 5)
func net_tiyi_high_noon_finished(
	peer_id: int,
	activation_id: int,
	target_ids: PackedInt32Array,
	hit_positions: PackedVector2Array
) -> void:
	var sender_id := multiplayer.get_remote_sender_id()
	player_coordinator.apply_tiyi_high_noon_finished(
		sender_id,
		peer_id,
		activation_id,
		target_ids,
		hit_positions
	)


@rpc("authority", "call_remote", "reliable", 5)
func net_tiyi_high_noon_cancelled(peer_id: int, activation_id: int) -> void:
	var sender_id := multiplayer.get_remote_sender_id()
	player_coordinator.apply_tiyi_high_noon_cancelled(
		sender_id,
		peer_id,
		activation_id
	)


func _cancel_authoritative_tiyi_high_noon(
	peer_id: int,
	activation_id: int,
	broadcast_cancel: bool
) -> void:
	player_coordinator.cancel_authoritative_tiyi_high_noon(
		peer_id,
		activation_id,
		broadcast_cancel
	)


@rpc("authority", "call_remote", "reliable", 5)
func net_player_state_corrected(corrected_position: Vector2, corrected_velocity: Vector2) -> void:
	player_coordinator.apply_local_state_correction(
		corrected_position,
		corrected_velocity
	)


@rpc("authority", "call_remote", "reliable", 5)
func net_player_authoritative_teleported(
	peer_id: int,
	target_position: Vector2,
	snapshot_sequence_cutoff: int
) -> void:
	player_coordinator.queue_authoritative_teleport(
		peer_id,
		target_position,
		snapshot_sequence_cutoff,
		_get_client_view_local_peer_id(),
		_get_net_time()
	)


func _accept_client_player_state(
	peer_id: int,
	sequence: int,
	reported_position: Vector2,
	reported_velocity: Vector2
) -> bool:
	return player_coordinator.accept_client_player_state(
		peer_id,
		sequence,
		reported_position,
		reported_velocity
	)

func register_local_projectile(
	projectile: Node,
	projectile_type: StringName,
	owner_peer_id: int,
	spawn_position: Vector2,
	direction: Vector2,
	damage: int,
	speed: float,
	lifetime: float,
	pierces_enemies: bool = false,
	target_peer_id: int = 0,
	target_enemy_net_id: int = 0
) -> void:
	projectile_coordinator.submit_local_projectile(
		projectile,
		projectile_type,
		owner_peer_id,
		spawn_position,
		direction,
		damage,
		speed,
		lifetime,
		pierces_enemies,
		target_peer_id,
		target_enemy_net_id
	)


func register_local_data_projectile(
	service: RapidFireSimulationService,
	handle: int,
	projectile_type: StringName,
	owner_peer_id: int,
	spawn_position: Vector2,
	direction: Vector2,
	damage: int,
	speed: float,
	lifetime: float,
	damage_source_snapshot: DamageSourceSnapshot = null
) -> int:
	return projectile_coordinator.register_local_data_projectile(
		service,
		handle,
		projectile_type,
		owner_peer_id,
		spawn_position,
		direction,
		damage,
		speed,
		lifetime,
		damage_source_snapshot
	)


func reserve_enemy_rapid_fire_projectile_ids(
	count: int
) -> PackedInt64Array:
	return projectile_coordinator.reserve_host_projectile_id_range(
		MpProjectileCoordinatorScript.PROJECTILE_ID_FALLBACK_OWNER_PEER_ID,
		count
	)


func release_enemy_rapid_fire_projectile_ids(
	projectile_ids: PackedInt64Array
) -> bool:
	return projectile_coordinator.release_reserved_host_projectile_ids(
		projectile_ids
	)


func attach_reserved_enemy_rapid_fire_projectile(
	service: RapidFireSimulationService,
	handle: int,
	projectile_id: int,
	projectile_type: StringName,
	owner_peer_id: int,
	damage: int,
	lifetime: float,
	damage_source_snapshot: DamageSourceSnapshot = null
) -> bool:
	return projectile_coordinator.attach_reserved_local_data_projectile(
		service,
		handle,
		projectile_id,
		projectile_type,
		owner_peer_id,
		damage,
		lifetime,
		damage_source_snapshot
	)


func broadcast_enemy_rapid_fire_burst(
	descriptor: PackedByteArray
) -> bool:
	return projectile_coordinator.broadcast_enemy_rapid_fire_burst(
		_get_net_time(),
		descriptor
	)


func notify_data_projectile_finished(
	projectile_id: int,
	service: RapidFireSimulationService,
	handle: int,
	completion_reason: int = RapidFireSimulationService.CompletionReason.NONE,
	completion_position: Vector2 = Vector2.ZERO,
	completion_direction: Vector2 = Vector2.RIGHT
) -> void:
	projectile_coordinator.notify_data_projectile_finished(
		projectile_id,
		service,
		handle,
		completion_reason,
		completion_position,
		completion_direction
	)


func flush_enemy_rapid_fire_finish_batch() -> bool:
	return projectile_coordinator.flush_enemy_rapid_fire_finish_batch()


func register_local_tango_laser_volley(
	projectiles: Array[Node],
	spawn_positions: PackedVector2Array,
	direction: Vector2,
	owner_peer_id: int,
	damage: int,
	speed: float,
	lifetime: float,
	charge_ratio: float,
	barrage_remaining_seconds: float
) -> bool:
	return projectile_coordinator.submit_local_tango_laser_volley(
		projectiles,
		spawn_positions,
		direction,
		owner_peer_id,
		damage,
		speed,
		lifetime,
		charge_ratio,
		barrage_remaining_seconds
	)


func register_local_linglan_skill1_ring(
	projectiles: Array[Node],
	spawn_positions: PackedVector2Array,
	directions: PackedVector2Array,
	owner_peer_id: int,
	damage: int,
	speed: float,
	lifetime: float
) -> void:
	projectile_coordinator.submit_local_linglan_skill1_ring(
		projectiles,
		spawn_positions,
		directions,
		owner_peer_id,
		damage,
		speed,
		lifetime
	)


@rpc("any_peer", "call_remote", "reliable", 4)
func _rpc_projectile_fired_from_client(
	projectile_id: int,
	projectile_type: String,
	owner_peer_id: int,
	spawn_position: Vector2,
	direction: Vector2,
	damage: int,
	speed: float,
	lifetime: float,
	pierces_enemies: bool = false,
	target_peer_id: int = 0,
	_client_fire_timestamp: float = -1.0,
	target_enemy_net_id: int = 0
) -> void:
	if _is_tower_world_suspended_for_rogue_exploration():
		return
	var sender_id := _get_rpc_sender_id()
	projectile_coordinator.handle_client_projectile_fired(
		sender_id,
		projectile_id,
		projectile_type,
		owner_peer_id,
		spawn_position,
		direction,
		damage,
		speed,
		lifetime,
		pierces_enemies,
		target_peer_id,
		_client_fire_timestamp,
		target_enemy_net_id
	)


@rpc("authority", "call_remote", "unreliable_ordered", 4)
func net_projectile_fired(
	projectile_id: int,
	projectile_type: String,
	owner_peer_id: int,
	spawn_position: Vector2,
	direction: Vector2,
	damage: int,
	speed: float,
	lifetime: float,
	pierces_enemies: bool = false,
	target_peer_id: int = 0,
	host_fire_timestamp: float = -1.0,
	target_enemy_net_id: int = 0
) -> void:
	var sender_id := multiplayer.get_remote_sender_id()
	projectile_coordinator.apply_authority_projectile_fired(
		sender_id,
		projectile_id,
		projectile_type,
		owner_peer_id,
		spawn_position,
		direction,
		damage,
		speed,
		lifetime,
		pierces_enemies,
		target_peer_id,
		host_fire_timestamp,
		target_enemy_net_id
	)


@rpc("authority", "call_remote", "unreliable_ordered", 4)
func net_enemy_rapid_fire_burst(
	host_first_shot_timestamp: float,
	descriptor: PackedByteArray
) -> void:
	projectile_coordinator.apply_authority_enemy_rapid_fire_burst(
		multiplayer.get_remote_sender_id(),
		host_first_shot_timestamp,
		descriptor
	)


@rpc("authority", "call_remote", "reliable", 5)
func net_enemy_rapid_fire_finished_batch(
	host_finish_timestamp: float,
	descriptor: PackedByteArray
) -> void:
	projectile_coordinator.apply_authority_enemy_rapid_fire_finished_batch(
		multiplayer.get_remote_sender_id(),
		host_finish_timestamp,
		descriptor
	)


@rpc("authority", "call_remote", "reliable", 5)
func net_enemy_rapid_fire_repair_burst(
	host_first_shot_timestamp: float,
	descriptor: PackedByteArray
) -> void:
	projectile_coordinator.apply_authority_enemy_rapid_fire_burst(
		multiplayer.get_remote_sender_id(),
		host_first_shot_timestamp,
		descriptor
	)


@rpc("authority", "call_remote", "reliable", 5)
func net_enemy_rapid_fire_snapshot_chunk(
	snapshot_id: int,
	chunk_index: int,
	chunk_count: int,
	host_snapshot_timestamp: float,
	descriptor: PackedByteArray
) -> void:
	projectile_coordinator.apply_authority_enemy_rapid_fire_snapshot_chunk(
		multiplayer.get_remote_sender_id(),
		snapshot_id,
		chunk_index,
		chunk_count,
		host_snapshot_timestamp,
		descriptor
	)


@rpc("authority", "call_remote", "unreliable_ordered", 4)
func net_tango_laser_volley(
	projectile_ids: PackedInt64Array,
	spawn_positions: PackedVector2Array,
	direction: Vector2,
	owner_peer_id: int,
	charge_sequence: int,
	charge_ratio: float,
	barrage_remaining_seconds: float,
	damage: int,
	speed: float,
	lifetime: float,
	host_fire_timestamp: float
) -> void:
	var sender_id := multiplayer.get_remote_sender_id()
	projectile_coordinator.apply_authority_tango_laser_volley(
		sender_id,
		projectile_ids,
		spawn_positions,
		direction,
		owner_peer_id,
		charge_sequence,
		charge_ratio,
		barrage_remaining_seconds,
		damage,
		speed,
		lifetime,
		host_fire_timestamp
	)


@rpc("authority", "call_remote", "unreliable_ordered", 4)
func net_linglan_skill1_ring_batch(
	projectile_ids: PackedInt64Array,
	spawn_positions: PackedVector2Array,
	directions: PackedVector2Array,
	owner_peer_id: int,
	damage: int,
	speed: float,
	lifetime: float,
	host_fire_timestamp: float
) -> void:
	var sender_id := multiplayer.get_remote_sender_id()
	projectile_coordinator.apply_authority_linglan_skill1_ring(
		sender_id,
		projectile_ids,
		spawn_positions,
		directions,
		owner_peer_id,
		damage,
		speed,
		lifetime,
		host_fire_timestamp
	)


func _get_unbounded_host_event_age(host_event_timestamp: float) -> float:
	if host_event_timestamp < 0.0:
		return 0.0
	var mapped_fire_time := host_event_timestamp
	if net_manager == null or not net_manager.is_host():
		mapped_fire_time = _map_host_timestamp_to_client_time(
			host_event_timestamp,
			false
		)
	return maxf(_get_net_time() - mapped_fire_time, 0.0)


## 每颗火球的协议 source type 在本进程内只接受一次首碰。
## Host 记录是最终权威；Client 使用同一入口抑制本地重复预测。
func try_consume_fire_sorcerer_fireball_contact(
	projectile_id: int,
	source_type: StringName
) -> bool:
	return projectile_coordinator.try_consume_fire_sorcerer_fireball_contact(
		projectile_id,
		source_type
	)


func try_consume_frost_sorcerer_ice_spike_contact(
	projectile_id: int,
	source_type: StringName
) -> bool:
	return projectile_coordinator.try_consume_frost_sorcerer_ice_spike_contact(
		projectile_id,
		source_type
	)


func _get_player_projectile_damage_type(
	projectile_type: StringName
) -> EnemyConfig.DamageType:
	return enemy_coordinator.get_player_projectile_damage_type(projectile_type)


func _update_recent_event_cache_prune(delta: float) -> void:
	_recent_event_prune_time_left = maxf(_recent_event_prune_time_left - delta, 0.0)
	if _recent_event_prune_time_left > 0.0:
		return
	_recent_event_prune_time_left = RECENT_EVENT_PRUNE_INTERVAL_SECONDS
	_prune_recent_event_caches(_get_net_time())


func _prune_recent_event_caches(now: float) -> void:
	player_coordinator.prune_recent_player_hit_events(now)
	collectible_presentation_coordinator.prune_recent_effect_events(now)
	projectile_coordinator.prune_records(now)


func request_enemy_hit_report(
	projectile_id: int,
	owner_peer_id: int,
	enemy_net_id: int,
	damage: int,
	impact_direction: Vector2
) -> void:
	if net_manager != null and net_manager.is_host():
		_apply_enemy_hit_report(projectile_id, owner_peer_id, enemy_net_id, damage, impact_direction)
	# Client projectile replicas are visual/predictive only. The Host has already
	# rebuilt the accepted projectile and settles its own collision callback.


func apply_multiplayer_collectible_enemy_damage(
	enemy: Enemy,
	damage: int,
	impact_direction: Vector2,
	damage_type: int = EnemyConfig.DamageType.MAGIC,
	show_hit_particles: bool = true
) -> bool:
	if net_manager == null or not net_manager.is_host():
		return false
	return enemy_coordinator.apply_collectible_enemy_damage(
		enemy,
		damage,
		impact_direction,
		damage_type,
		show_hit_particles
	)


@rpc("any_peer", "call_remote", "reliable", 4)
func _rpc_enemy_hit_report(
	_projectile_id: int,
	_owner_peer_id: int,
	_enemy_net_id: int,
	_damage: int,
	_impact_direction: Vector2
) -> void:
	if _is_tower_world_suspended_for_rogue_exploration():
		return
	var sender_id := _get_rpc_sender_id()
	enemy_coordinator.receive_enemy_hit_report(
		sender_id,
		_projectile_id,
		_owner_peer_id,
		_enemy_net_id,
		_damage,
		_impact_direction
	)


func _apply_enemy_hit_report(
	projectile_id: int,
	owner_peer_id: int,
	enemy_net_id: int,
	reported_damage: int,
	impact_direction: Vector2
) -> void:
	enemy_coordinator.apply_host_enemy_hit_report(
		projectile_id,
		owner_peer_id,
		enemy_net_id,
		reported_damage,
		impact_direction
	)


@rpc("authority", "call_remote", "reliable", 4)
func net_tiyi_sniper_hit_confirmed(
	projectile_id: int,
	enemy_net_id: int,
	hit_position: Vector2,
	direction: Vector2,
	continues_piercing: bool
) -> void:
	var sender_id := multiplayer.get_remote_sender_id()
	enemy_coordinator.receive_tiyi_sniper_hit_confirmation(
		sender_id,
		_get_host_peer_id(),
		projectile_id,
		enemy_net_id,
		hit_position,
		direction,
		continues_piercing
	)


func _update_batched_network_events(delta: float) -> void:
	if not net_manager.is_host():
		return
	enemy_coordinator.update_damage_feedback(delta)
	if tower_world_coordinator != null:
		tower_world_coordinator.update_host(delta)
	if world_flow_coordinator.update_host(delta):
		_flush_tiyi_target_updates()


func _flush_tiyi_target_updates() -> void:
	player_coordinator.flush_tiyi_target_updates()


func _on_tower_world_plant_health_batch_broadcast_requested(
	net_ids: PackedInt32Array,
	health_values: PackedInt32Array,
	maximum_values: PackedInt32Array,
	revisions: PackedInt32Array,
	damage_values: PackedInt32Array,
	healing_values: PackedInt32Array,
	directions: PackedVector2Array,
	damage_types: PackedByteArray,
	world_positions: PackedVector2Array
) -> void:
	if not _has_tower_mode() or not net_manager.is_host():
		return
	_rpc_to_connected_clients(
		&"net_plant_health_batch",
		[
			net_ids,
			health_values,
			maximum_values,
			revisions,
			damage_values,
			healing_values,
			directions,
			damage_types,
			world_positions,
		]
	)


@rpc("authority", "call_remote", "unreliable_ordered", 7)
func net_plant_health_batch(
	net_ids: PackedInt32Array,
	health_values: PackedInt32Array,
	maximum_values: PackedInt32Array,
	revisions: PackedInt32Array,
	damage_values: PackedInt32Array,
	healing_values: PackedInt32Array,
	directions: PackedVector2Array,
	damage_types: PackedByteArray,
	world_positions: PackedVector2Array
) -> void:
	tower_world_coordinator.receive_plant_health_batch(
		net_ids,
		health_values,
		maximum_values,
		revisions,
		damage_values,
		healing_values,
		directions,
		damage_types,
		world_positions
	)


@rpc("authority", "call_remote", "unreliable", 7)
func net_enemy_damage_feedback_batch(
	net_ids: PackedInt32Array,
	health_values: PackedInt32Array,
	health_revisions: PackedInt32Array,
	damage_values: PackedInt32Array,
	directions: PackedVector2Array,
	damage_types: PackedByteArray,
	presentation_flags: PackedByteArray
) -> void:
	enemy_coordinator.apply_damage_feedback_batch(
		net_ids,
		health_values,
		health_revisions,
		damage_values,
		directions,
		damage_types,
		presentation_flags
	)


@rpc("authority", "call_remote", "unreliable", 7)
func net_enemy_damage_applied(
	enemy_net_id: int,
	current_health: int,
	health_revision: int,
	is_dead: bool,
	confirmed_damage: int,
	impact_direction: Vector2,
	damage_type: int = EnemyConfig.DamageType.PHYSICAL,
	presentation_flags: int = 0
) -> void:
	enemy_coordinator.apply_damage_event(
		enemy_net_id,
		current_health,
		health_revision,
		is_dead,
		confirmed_damage,
		impact_direction,
		damage_type,
		presentation_flags
	)


func request_multiplayer_player_damage(
	source_id: int,
	target_peer_id: int,
	damage: int,
	source_type: StringName,
	damage_type_or_source_direction: Variant = EnemyConfig.DamageType.PHYSICAL,
	source_direction_or_is_ranged: Variant = Vector2.ZERO,
	is_ranged: bool = false,
	contact_preconsumed: bool = false
) -> bool:
	return player_coordinator.request_multiplayer_player_damage(
		source_id,
		target_peer_id,
		damage,
		source_type,
		damage_type_or_source_direction,
		source_direction_or_is_ranged,
		is_ranged,
		contact_preconsumed
	)


func request_multiplayer_player_damage_with_source_snapshot(
	source_snapshot: DamageSourceSnapshot,
	target_peer_id: int,
	damage: int,
	damage_type: EnemyConfig.DamageType = EnemyConfig.DamageType.PHYSICAL,
	source_direction: Vector2 = Vector2.ZERO,
	is_ranged: bool = false,
	contact_preconsumed: bool = false
) -> bool:
	return player_coordinator.request_multiplayer_player_damage_with_source_snapshot(
		source_snapshot,
		target_peer_id,
		damage,
		damage_type,
		source_direction,
		is_ranged,
		contact_preconsumed
	)



func request_multiplayer_player_burn_tick(
	player_peer_id: int,
	source_family: StringName
) -> bool:
	return player_coordinator.request_multiplayer_player_burn_tick(
		player_peer_id,
		source_family
	)


## Host-only sink used by authoritative Player status schedulers. This is a
## local method, not an RPC: clients cannot submit arbitrary periodic damage.
func request_multiplayer_player_damage_over_time_tick(
	player_peer_id: int,
	status_id: StringName,
	source_family: StringName,
	tick_damage: int,
	source_snapshot: DamageSourceSnapshot = null
) -> bool:
	return player_coordinator.request_multiplayer_player_damage_over_time_tick(
		player_peer_id,
		status_id,
		source_family,
		tick_damage,
		source_snapshot
	)



## Host-only replication path for Luoxi's explicit HP-loss card effects.
## The Player method deliberately bypasses ordinary combat mitigation; this
## wrapper only publishes the already-applied authoritative health result.
func apply_luoxi_direct_health_loss(
	target_player: Player,
	amount: int,
	minimum_health: int = 0
) -> int:
	return player_coordinator.apply_luoxi_direct_health_loss(
		target_player,
		amount,
		minimum_health
	)



func request_player_hit_report(
	_source_id: int,
	_player_peer_id: int,
	_source_type: StringName,
	_impact_direction: Vector2,
	_damage_flags: int
) -> void:
	# Protocol-v25 compatibility shell. Client hit claims remain disabled.
	return


@rpc("any_peer", "call_remote", "reliable", 5)
func _rpc_player_hit_report(
	_source_id: int,
	_player_peer_id: int,
	_attack_wire_id: int,
	_impact_direction: Vector2,
	_damage_flags: int
) -> void:
	var sender_id := _get_rpc_sender_id()
	player_coordinator.reject_untrusted_player_hit_report(
		sender_id,
		_source_id,
		_player_peer_id,
		_attack_wire_id,
		_impact_direction,
		_damage_flags
	)



@rpc("authority", "call_remote", "reliable", 5)
func net_player_damage_applied(
	player_peer_id: int,
	current_health: int,
	is_dead: bool,
	health_revision: int,
	confirmed_damage: int,
	impact_direction: Vector2,
	damage_type: int,
	grant_hit_invincibility: bool = true,
	apply_confirmed_cold: bool = false,
	combat_outcome: int = 0,
	confirmed_status_mask: int = 0
) -> void:
	player_coordinator.apply_player_damage_confirmation(
		player_peer_id,
		current_health,
		is_dead,
		health_revision,
		confirmed_damage,
		impact_direction,
		damage_type,
		grant_hit_invincibility,
		apply_confirmed_cold,
		combat_outcome,
		confirmed_status_mask
	)



func apply_multiplayer_player_heal(target_player: Player, heal_amount: int) -> bool:
	return player_coordinator.apply_multiplayer_player_heal(
		target_player,
		heal_amount
	)


## Receives an already-applied authoritative heal.
func report_multiplayer_player_healing(
	target_player: Player,
	confirmed_healing: int
) -> void:
	player_coordinator.report_multiplayer_player_healing(
		target_player,
		confirmed_healing
	)


func apply_multiplayer_collectible_player_heal(
	target_player: Player,
	heal_amount: int
) -> bool:
	return player_coordinator.apply_multiplayer_player_heal(
		target_player,
		heal_amount
	)


@rpc("authority", "call_remote", "reliable", 5)
func net_player_healed(
	peer_id: int,
	current_health: int,
	health_revision: int,
	confirmed_healing: int
) -> void:
	player_coordinator.apply_player_heal_confirmation(
		peer_id,
		current_health,
		health_revision,
		confirmed_healing
	)



# Protocol v25 retains these compatibility shells for older relay deployments.
# Xirang orbs no longer exist; all annotated endpoints remain deliberate no-ops.
@rpc("authority", "call_remote", "reliable", 5)
func net_xirang_orb_spawned(orb_id: int, amount: int, spawn_position: Vector2) -> void:
	pass


@rpc("any_peer", "call_remote", "reliable", 6)
func _rpc_xirang_orb_collected(orb_id: int) -> void:
	var _sender_id := _get_rpc_sender_id()
	pass


@rpc("authority", "call_remote", "reliable", 6)
func net_xirang_granted_all(orb_id: int, amount: int, revision: int) -> void:
	pass


@rpc("authority", "call_remote", "reliable", 5)
func net_xirang_orb_removed(orb_id: int) -> void:
	pass

func get_local_multiplayer_player() -> Player:
	if game == null:
		return null
	return game.player


func get_combat_target_by_net_id(enemy_net_id: int) -> Enemy:
	var enemy: Enemy
	if net_manager.is_host():
		enemy = _get_host_enemy_for_net_id(enemy_net_id)
	else:
		enemy = _get_valid_client_enemy_for_net_id(enemy_net_id)
	return enemy if CombatTargetIndexScript.is_enemy_queryable(enemy) else null


func get_all_combat_targets() -> Array[Enemy]:
	if game == null:
		return []
	if net_manager.is_host():
		return game.get_all_combat_targets()
	return enemy_coordinator.get_all_client_combat_targets()


func pick_random_combat_target(center: Vector2, radius: float = 0.0) -> Enemy:
	if game == null:
		return null
	return game.pick_random_combat_target(center, radius)


func find_nearest_combat_target(
	center: Vector2,
	radius: float,
	excluded_instance_ids: Dictionary = {}
) -> Enemy:
	if (
		game == null
		or not center.is_finite()
		or not is_finite(radius)
		or radius < 0.0
	):
		return null
	if net_manager.is_host():
		return game.find_nearest_combat_target(
			center,
			radius,
			excluded_instance_ids
		)
	return enemy_coordinator.find_nearest_client_combat_target(
		center,
		radius,
		excluded_instance_ids
	)


func query_combat_targets(center: Vector2, radius: float, max_count: int = 0) -> Array[Enemy]:
	var result: Array[Enemy] = []
	query_combat_targets_into(center, radius, result, max_count)
	return result


func query_combat_targets_into(
	center: Vector2,
	radius: float,
	result: Array[Enemy],
	max_count: int = 0
) -> void:
	result.clear()
	if game == null:
		return
	if net_manager.is_host():
		game.query_combat_targets_into(center, radius, result, max_count)
		return
	enemy_coordinator.query_client_combat_targets_into(
		center,
		radius,
		result,
		max_count,
		true
	)


func query_combat_targets_unordered_into(
	center: Vector2,
	radius: float,
	result: Array[Enemy]
) -> void:
	result.clear()
	if game == null:
		return
	if net_manager.is_host():
		game.query_combat_targets_unordered_into(center, radius, result)
		return
	enemy_coordinator.query_client_combat_targets_into(
		center,
		radius,
		result,
		0,
		false
	)


func query_living_players_in_radius_into(
	center: Vector2,
	radius: float,
	result: Array[Player]
) -> void:
	result.clear()
	if game == null:
		return
	game.query_living_players_in_radius_into(center, radius, result)


func query_living_plants_in_radius_into(
	center: Vector2,
	radius: float,
	result: Array[PlantDefense]
) -> void:
	result.clear()
	if not _has_tower_mode():
		return
	tower_mode_adapter.query_living_plants_in_radius_into(
		center,
		radius,
		result
	)


func apply_authoritative_player_heal(
	target_player: Player,
	heal_amount: int
) -> bool:
	return player_coordinator.apply_authoritative_player_heal(
		target_player,
		heal_amount
	)


func has_session_object_pool_scene(scene: PackedScene) -> bool:
	return game != null and game.has_session_object_pool_scene(scene)


func acquire_session_object(scene: PackedScene, strict: bool = false) -> Node:
	if game == null:
		return null
	return game.acquire_session_object(scene, strict)


func release_session_object(instance: Node) -> bool:
	return game != null and game.release_session_object(instance)


func grant_xirang_kill_reward(amount: int) -> bool:
	if game == null or not net_manager.is_host():
		return false
	return game.grant_xirang_kill_reward(amount)


func is_host_multiplayer_authority() -> bool:
	return net_manager != null and net_manager.is_host()


func _get_host_enemy_for_net_id(enemy_net_id: int) -> Enemy:
	return enemy_coordinator.get_host_enemy(enemy_net_id)


func _get_valid_client_enemy_for_net_id(enemy_net_id: int) -> Enemy:
	return enemy_coordinator.get_valid_client_enemy(enemy_net_id)

func _cancel_player_life_tango_for_revive_schedule(peer_id: int) -> void:
	player_coordinator.cancel_tango_charge_for_life_transition(peer_id)


func _cancel_player_life_actions_for_revive(peer_id: int) -> void:
	player_coordinator.cancel_tiyi_for_life_transition(peer_id)
	player_coordinator.cancel_tango_charge_for_life_transition(peer_id)


func _clear_player_life_tiyi_lifecycle_state(peer_id: int) -> void:
	player_coordinator.clear_tiyi_lifecycle_state(peer_id)


func _get_player_life_revive_anchor_position(
	peer_id: int,
	player_node: Player
) -> Vector2:
	return player_coordinator.get_player_revive_anchor_position(
		peer_id,
		player_node,
		_get_host_peer_id()
	)


func _commit_player_life_revive_position(
	peer_id: int,
	revive_position: Vector2,
	net_time: float
) -> void:
	player_coordinator.remember_accepted_player_pose(
		peer_id,
		revive_position,
		net_time
	)


func _on_host_revive_all_requested() -> void:
	player_coordinator.revive_all_players()


func _on_host_restore_all_full_health_requested() -> void:
	_mark_disconnected_players_for_rogue_boundary_full_health()
	player_coordinator.restore_all_players_to_full_health()


func _mark_disconnected_players_for_rogue_boundary_full_health() -> void:
	if not net_manager.is_host():
		return
	for peer_id in _disconnected_player_reconnect_states.keys():
		var reconnect_state := (
			_disconnected_player_reconnect_states[peer_id] as Dictionary
		)
		reconnect_state["rogue_boundary_full_health_pending"] = true
		reconnect_state["tower_world_spawn_restore_pending"] = true
		# 已跨过全员满血边界的断线玩家不再继承旧死亡倒计时；重连节点
		# 创建后会按 RunState 当前上限产生一条新的权威健康 revision。
		reconnect_state["revive_at"] = -1.0
		reconnect_state["revive_last_seconds"] = -1
		_disconnected_player_reconnect_states[peer_id] = reconnect_state


@rpc("authority", "call_remote", "reliable", 5)
func net_player_revive_countdown(peer_id: int, seconds_left: int) -> void:
	player_coordinator.apply_player_revive_countdown(peer_id, seconds_left)


@rpc("authority", "call_remote", "reliable", 5)
func net_player_revived(
	peer_id: int,
	revive_position: Vector2,
	current_health: int,
	invincible_seconds: float,
	health_revision: int
) -> void:
	player_coordinator.apply_player_revived(
		peer_id,
		revive_position,
		current_health,
		invincible_seconds,
		health_revision
	)


@rpc("authority", "call_remote", "reliable", 5)
func net_player_full_health_restored(
	peer_id: int,
	restore_position: Vector2,
	maximum_health: int,
	invincible_seconds: float,
	health_revision: int
) -> void:
	player_coordinator.apply_player_full_health_restored(
		peer_id,
		restore_position,
		maximum_health,
		invincible_seconds,
		health_revision
	)



func _on_remote_enemy_spawned(enemy: Enemy) -> void:
	if enemy == null or not _has_tower_mode():
		return
	tower_mode_adapter.configure_runtime_enemy_modifiers(enemy)


func _on_remote_enemy_escape_requested(net_id: int) -> void:
	if not _has_tower_mode():
		return
	tower_mode_adapter.apply_remote_enemy_escape(net_id)


func _on_host_xiaocong_fate_state_changed(state: Dictionary) -> void:
	tower_fate_coordinator.handle_host_fate_state_changed(state)


func _on_host_player_teleport_requested(
	peer_id: int,
	target_position: Vector2
) -> void:
	player_coordinator.handle_authoritative_player_teleport_request(
		peer_id,
		target_position
	)


func _on_host_plant_damage_status_changed(
	net_id: int,
	status_mask: int,
	status_revision: int
) -> void:
	if (
		not _has_tower_mode()
		or not is_inside_tree()
		or not net_manager.is_host()
		or net_id <= 0
		or status_revision <= 0
	):
		return
	_rpc_to_connected_clients(
		&"net_plant_damage_status_changed",
		[net_id, status_mask, status_revision]
	)


func broadcast_enemy_action(
	net_id: int,
	action_name: StringName,
	direction: Vector2,
	action_position: Vector2,
	action_id: int
) -> void:
	enemy_coordinator.broadcast_enemy_action(
		net_id,
		action_name,
		direction,
		action_position,
		action_id
	)


func broadcast_enemy_target_action(
	net_id: int,
	action_name: StringName,
	target_peer_id: int,
	action_position: Vector2,
	action_id: int
) -> void:
	enemy_coordinator.broadcast_enemy_target_action(
		net_id,
		action_name,
		target_peer_id,
		action_position,
		action_id
	)


func broadcast_enemy_lightning_chain(points: PackedVector2Array) -> void:
	enemy_coordinator.broadcast_enemy_lightning_chain(points)


func _on_world_flow_merchant_active_broadcast_requested(active: bool) -> void:
	if not is_inside_tree() or not net_manager.is_host():
		return
	_rpc_to_connected_clients(&"net_merchant_active_changed", [active])


func _on_world_flow_state_broadcast_requested(
	step_id: StringName,
	state: int,
	countdown_seconds: int
) -> void:
	if not is_inside_tree() or not net_manager.is_host():
		return
	# 会话快照先于同一可靠信道上的流程状态到达，客户端不会先进入空的
	# 探索画面；非探索流程同样发送 active=false 以收敛返回边界。
	_broadcast_tower_rogue_exploration_snapshots()
	_rpc_to_connected_clients(&"net_flow_state_changed", [String(step_id), state, countdown_seconds])


func _on_tower_rogue_exploration_snapshot_changed(
	_snapshot: Dictionary
) -> void:
	if not net_manager.is_host() or tower_mode_adapter == null:
		return
	tower_rogue_route_bridge.set_embedded_exploration_active(
		tower_mode_adapter.is_rogue_exploration_active()
	)
	_broadcast_tower_rogue_exploration_snapshots()


func _on_tower_rogue_route_snapshot_refresh_requested() -> void:
	if net_manager.is_host():
		_broadcast_tower_rogue_exploration_snapshots()


func _broadcast_tower_rogue_exploration_snapshots() -> void:
	if not net_manager.is_host() or tower_mode_adapter == null:
		return
	for peer_id in _get_connected_client_peer_ids():
		_send_tower_rogue_exploration_snapshot_to_peer(peer_id)


func _send_tower_rogue_exploration_snapshot_to_peer(
	peer_id: int,
	reconnect_delivery: bool = false
) -> bool:
	var send_ready := (
		net_manager.is_peer_send_ready(peer_id)
		or (
			reconnect_delivery
			and net_manager.is_reconnect_delivery_preparing(peer_id)
		)
	)
	if (
		not net_manager.is_host()
		or tower_mode_adapter == null
		or peer_id <= 0
		or not send_ready
	):
		return false
	var snapshot := (
		tower_mode_adapter.export_rogue_exploration_snapshot_for_peer(peer_id)
	)
	if snapshot.is_empty():
		return false
	return _rpc_to_peer(
		peer_id,
		&"net_tower_rogue_exploration_snapshot",
		[snapshot]
	)


func _apply_tower_rogue_exploration_snapshot(
	sender_id: int,
	snapshot: Dictionary
) -> bool:
	if (
		not net_manager.is_client()
		or sender_id != _get_host_peer_id()
		or tower_mode_adapter == null
		or tower_rogue_route_bridge == null
		or snapshot.is_empty()
	):
		return false
	if not tower_mode_adapter.is_rogue_progression_contract_compatible(snapshot):
		push_error(
			"MpGame: Host 地下探索成长配置契约与本地不一致，拒绝会话快照。"
		)
		return false
	if not tower_mode_adapter.apply_remote_rogue_exploration_snapshot(snapshot):
		return false
	var active := tower_mode_adapter.is_rogue_exploration_active()
	tower_rogue_route_bridge.set_embedded_exploration_active(active)
	if active:
		tower_rogue_route_bridge.synchronize_embedded_route()
	_flush_pending_tower_rogue_flow_state(active)
	return true


func _is_tower_rogue_session_transport_active() -> bool:
	return (
		tower_mode_adapter != null
		and tower_rogue_route_bridge != null
		and tower_mode_adapter.is_rogue_exploration_active()
		and tower_rogue_route_bridge.is_embedded_exploration_active()
	)


func _receive_or_defer_tower_flow_state(
	step_id: String,
	state: int,
	countdown_seconds: int
) -> void:
	if tower_mode_adapter == null:
		world_flow_coordinator.receive_flow_state(
			StringName(step_id),
			state,
			countdown_seconds
		)
		return
	var expects_active_session := (
		state == CombatFlowState.State.ROGUE_EXPLORATION
	)
	var session_active := _is_tower_rogue_session_transport_active()
	if expects_active_session != session_active:
		_pending_tower_rogue_flow_state = {
			"step_id": step_id,
			"state": state,
			"countdown_seconds": countdown_seconds,
		}
		return
	_pending_tower_rogue_flow_state.clear()
	world_flow_coordinator.receive_flow_state(
		StringName(step_id),
		state,
		countdown_seconds
	)


func _flush_pending_tower_rogue_flow_state(session_active: bool) -> void:
	if _pending_tower_rogue_flow_state.is_empty():
		return
	var state := int(_pending_tower_rogue_flow_state.get("state", -1))
	if (
		(state == CombatFlowState.State.ROGUE_EXPLORATION)
		!= session_active
	):
		return
	var pending := _pending_tower_rogue_flow_state.duplicate(true)
	_pending_tower_rogue_flow_state.clear()
	world_flow_coordinator.receive_flow_state(
		StringName(pending.get("step_id", "")),
		state,
		int(pending.get("countdown_seconds", 0))
	)


func _on_world_flow_wave_progress_broadcast_requested(
	progress: Dictionary,
	reliable: bool
) -> void:
	if not is_inside_tree() or not net_manager.is_host() or progress.is_empty():
		return
	_rpc_to_connected_clients(
		(
			&"net_tower_defense_wave_progress_keyframe"
			if reliable
			else &"net_tower_defense_wave_progress_changed"
		),
		[
			int(progress.get("wave_number", 1)),
			int(progress.get("defeated", 0)),
			int(progress.get("escaped", 0)),
			int(progress.get("resolved", 0)),
			int(progress.get("total", 0)),
		]
	)


func _on_world_flow_boss_started_broadcast_requested(
	net_id: int,
	boss_config_path: String,
	spawn_position: Vector2
) -> void:
	if not is_inside_tree() or not net_manager.is_host() or boss_config_path.is_empty():
		return
	_rpc_to_connected_clients(
		&"net_boss_started",
		[net_id, boss_config_path, spawn_position]
	)


func _on_host_linglan_airdrop_started(
	enemy_config: EnemyConfig,
	landing_position: Vector2,
	warning_duration: float,
	drop_height: float,
	drop_duration: float
) -> void:
	if (
		not is_inside_tree()
		or not net_manager.is_host()
		or enemy_config == null
		or enemy_config.resource_path.is_empty()
	):
		return
	_rpc_to_connected_clients(
		&"net_linglan_airdrop_started",
		[
			enemy_config.resource_path,
			landing_position,
			warning_duration,
			drop_height,
			drop_duration,
		]
	)


func _on_world_flow_defeat_broadcast_requested(failure_reason: String) -> void:
	if not is_inside_tree() or not net_manager.is_host():
		return
	_rpc_to_connected_clients(&"net_game_defeated", [failure_reason])


func _on_world_flow_victory_broadcast_requested() -> void:
	if not is_inside_tree() or not net_manager.is_host():
		return
	_rpc_to_connected_clients(&"net_game_victory")


func _clear_pending_player_revives() -> void:
	player_coordinator.clear_pending_revives()


func _on_game_return_to_lobby_requested() -> void:
	# 子战场 UI/Adapter 不拥有外层多人连接；任何结束或失败必须由外层路线
	# 协议决定是回路线、重试还是结束会话。
	if embedded_runtime:
		return
	if net_manager != null and net_manager.is_multiplayer_active():
		if _public_return_in_progress:
			return
		_public_return_in_progress = true
		# 公网身份先结束；断开 ENet 后再由既有状态信号统一切回大厅。
		if public_room_lease != null:
			await public_room_lease.release_current_and_wait(&"game_return_to_lobby")
		if not is_inside_tree():
			return
		net_manager.disconnect_from_game()
		return
	_return_to_lobby()


@rpc("any_peer", "call_remote", "reliable", 0)
func net_runtime_state_requested(include_flow_state: bool = true) -> void:
	var sender_id := multiplayer.get_remote_sender_id()
	if not net_manager.is_host() or game == null:
		return
	_handle_authoritative_runtime_state_request(sender_id, include_flow_state)


func _handle_authoritative_runtime_state_request(
	sender_id: int,
	include_flow_state: bool
) -> bool:
	if not session_coordinator.admit_authoritative_runtime_state_request(
		net_manager.is_host(),
		sender_id,
		_get_net_time()
	):
		return false
	_send_tower_rogue_exploration_snapshot_to_peer(sender_id)
	return session_coordinator.send_authoritative_runtime_state_to_peer(
		sender_id,
		include_flow_state
	)


func _send_tower_rogue_route_rpc(
	peer_id: int,
	method_name: StringName,
	arguments: Array
) -> bool:
	if (
		peer_id <= 0
		or tower_rogue_route_bridge == null
		or not is_instance_valid(tower_rogue_route_bridge)
	):
		return false
	return _rpc_to_peer(peer_id, method_name, arguments)


func _dispatch_tower_rogue_route_rpc(
	method_name: StringName,
	arguments: Array
) -> void:
	if (
		tower_rogue_route_bridge == null
		or not is_instance_valid(tower_rogue_route_bridge)
	):
		return
	tower_rogue_route_bridge.apply_embedded_route_rpc(
		method_name,
		multiplayer.get_remote_sender_id(),
		arguments
	)


@rpc("authority", "call_remote", "reliable", 0)
func net_tower_rogue_exploration_snapshot(snapshot: Dictionary) -> void:
	_apply_tower_rogue_exploration_snapshot(
		multiplayer.get_remote_sender_id(),
		snapshot
	)


@rpc("any_peer", "call_remote", "reliable", 0)
func net_request_route_full_snapshot() -> void:
	_dispatch_tower_rogue_route_rpc(
		&"net_request_route_full_snapshot",
		[]
	)


@rpc("authority", "call_remote", "reliable", 0)
func net_route_full_snapshot(
	layout: Dictionary,
	state: Dictionary,
	encounter_state: Dictionary,
	economy_state: Dictionary,
	shop_state: Dictionary,
	progression_ledger: Dictionary
) -> void:
	_dispatch_tower_rogue_route_rpc(
		&"net_route_full_snapshot",
		[
			layout,
			state,
			encounter_state,
			economy_state,
			shop_state,
			progression_ledger,
		]
	)


@rpc("authority", "call_remote", "reliable", 0)
func net_route_move_delta(delta: Dictionary) -> void:
	_dispatch_tower_rogue_route_rpc(&"net_route_move_delta", [delta])


@rpc("authority", "call_remote", "reliable", 0)
func net_route_briefing_state(snapshot: Dictionary) -> void:
	_dispatch_tower_rogue_route_rpc(&"net_route_briefing_state", [snapshot])


@rpc("any_peer", "call_remote", "reliable", 0)
func net_route_briefing_cover_ready(
	occurrence_key: String,
	briefing_revision: int,
	expected_route_revision: int
) -> void:
	_dispatch_tower_rogue_route_rpc(
		&"net_route_briefing_cover_ready",
		[occurrence_key, briefing_revision, expected_route_revision]
	)


@rpc("any_peer", "call_remote", "reliable", 0)
func net_route_encounter_intro_ack(
	occurrence_key: String,
	expected_revision: int
) -> void:
	_dispatch_tower_rogue_route_rpc(
		&"net_route_encounter_intro_ack",
		[occurrence_key, expected_revision]
	)


@rpc("any_peer", "call_remote", "reliable", 0)
func net_route_encounter_vote(
	occurrence_key: String,
	expected_revision: int,
	option_id: StringName
) -> void:
	_dispatch_tower_rogue_route_rpc(
		&"net_route_encounter_vote",
		[occurrence_key, expected_revision, option_id]
	)


@rpc("any_peer", "call_remote", "reliable", 0)
func net_route_encounter_result_ack(
	occurrence_key: String,
	result_sequence: int
) -> void:
	_dispatch_tower_rogue_route_rpc(
		&"net_route_encounter_result_ack",
		[occurrence_key, result_sequence]
	)


@rpc("authority", "call_remote", "reliable", 0)
func net_route_encounter_snapshot(
	encounter_state: Dictionary,
	economy_state: Dictionary
) -> void:
	_dispatch_tower_rogue_route_rpc(
		&"net_route_encounter_snapshot",
		[encounter_state, economy_state]
	)


@rpc("any_peer", "call_remote", "reliable", 0)
func net_shop_purchase_request(
	request_id: String,
	occurrence_key: String,
	offer_index: int,
	expected_session_revision: int,
	expected_shelf_revision: int,
	expected_inventory_revision: int,
	expected_xirang_revision: int
) -> void:
	_dispatch_tower_rogue_route_rpc(
		&"net_shop_purchase_request",
		[
			request_id,
			occurrence_key,
			offer_index,
			expected_session_revision,
			expected_shelf_revision,
			expected_inventory_revision,
			expected_xirang_revision,
		]
	)


@rpc("any_peer", "call_remote", "reliable", 0)
func net_shop_sell_request(
	request_id: String,
	occurrence_key: String,
	slot_index: int,
	expected_config_path: String,
	expected_session_revision: int,
	expected_inventory_revision: int,
	expected_xirang_revision: int
) -> void:
	_dispatch_tower_rogue_route_rpc(
		&"net_shop_sell_request",
		[
			request_id,
			occurrence_key,
			slot_index,
			expected_config_path,
			expected_session_revision,
			expected_inventory_revision,
			expected_xirang_revision,
		]
	)


@rpc("any_peer", "call_remote", "reliable", 0)
func net_shop_exit_ack(
	occurrence_key: String,
	expected_session_revision: int
) -> void:
	_dispatch_tower_rogue_route_rpc(
		&"net_shop_exit_ack",
		[occurrence_key, expected_session_revision]
	)


@rpc("authority", "call_remote", "reliable", 0)
func net_shop_snapshot(shop_state: Dictionary) -> void:
	_dispatch_tower_rogue_route_rpc(&"net_shop_snapshot", [shop_state])


@rpc("any_peer", "call_remote", "unreliable_ordered", 1)
func net_route_avatar_input(
	sequence: int,
	route_revision: int,
	packed_pose: PackedInt32Array
) -> void:
	_dispatch_tower_rogue_route_rpc(
		&"net_route_avatar_input",
		[sequence, route_revision, packed_pose]
	)


@rpc("authority", "call_remote", "unreliable_ordered", 2)
func net_route_avatar_snapshot(
	snapshot_sequence: int,
	route_revision: int,
	packed_states: PackedInt32Array
) -> void:
	_dispatch_tower_rogue_route_rpc(
		&"net_route_avatar_snapshot",
		[snapshot_sequence, route_revision, packed_states]
	)


@rpc("authority", "call_remote", "reliable", 0)
func net_route_avatar_corrected(
	route_revision: int,
	packed_pose: PackedInt32Array
) -> void:
	_dispatch_tower_rogue_route_rpc(
		&"net_route_avatar_corrected",
		[route_revision, packed_pose]
	)


@rpc("any_peer", "call_remote", "reliable", 0)
func net_terrain_snapshot_requested(known_revision: int) -> void:
	var sender_id := multiplayer.get_remote_sender_id()
	tower_world_coordinator.handle_remote_terrain_snapshot_request(
		sender_id,
		known_revision
	)


@rpc("authority", "call_remote", "reliable", 5)
func net_terrain_snapshot_chunk(
	snapshot_id: int,
	revision: int,
	chunk_index: int,
	chunk_count: int,
	cell_xy: PackedInt32Array,
	terrain_types: PackedInt32Array
) -> void:
	tower_world_coordinator.receive_terrain_snapshot_chunk(
		snapshot_id,
		revision,
		chunk_index,
		chunk_count,
		cell_xy,
		terrain_types
	)


@rpc("authority", "call_remote", "reliable", 5)
func net_terrain_delta(
	revision: int,
	cell_xy: PackedInt32Array,
	terrain_types: PackedInt32Array
) -> void:
	tower_world_coordinator.receive_terrain_delta(
		revision,
		cell_xy,
		terrain_types
	)


@rpc("authority", "call_remote", "reliable", 5)
func net_runtime_world_manifest(
	live_enemy_ids: PackedInt32Array,
	live_pickup_ids: PackedInt32Array,
	live_plant_ids: PackedInt32Array
) -> void:
	if game == null or net_manager.is_host():
		return
	session_coordinator.apply_runtime_world_manifest(
		live_enemy_ids,
		live_pickup_ids,
		live_plant_ids
	)


@rpc("any_peer", "call_remote", "reliable", 5)
func net_plant_placement_requested(
	request_id: int,
	plant_id: String,
	anchor: Vector2i
) -> void:
	var sender_id := _get_rpc_sender_id()
	if (
		_is_tower_management_suspended()
		or not _has_tower_mode()
		or not net_manager.is_host()
		or game == null
	):
		return
	tower_world_coordinator.handle_remote_plant_placement_request(
		sender_id,
		request_id,
		plant_id,
		anchor
	)


@rpc("any_peer", "call_remote", "reliable", 5)
func net_inventory_plant_placement_requested(
	request_id: int,
	plant_id: String,
	anchor: Vector2i,
	slot_index: int,
	expected_inventory_revision: int,
	item_config_path: String
) -> void:
	var sender_id := _get_rpc_sender_id()
	if (
		_is_tower_management_suspended()
		or not _has_tower_mode()
		or not net_manager.is_host()
		or game == null
	):
		return
	tower_world_coordinator.handle_remote_inventory_plant_placement_request(
		sender_id,
		request_id,
		plant_id,
		anchor,
		slot_index,
		expected_inventory_revision,
		item_config_path
	)


@rpc("any_peer", "call_remote", "reliable", 5)
func net_nearest_plant_destruction_requested(
	request_id: int,
	target_net_id: int
) -> void:
	var sender_id := _get_rpc_sender_id()
	if (
		_is_tower_management_suspended()
		or not _has_tower_mode()
		or not net_manager.is_host()
		or game == null
	):
		return
	tower_world_coordinator.handle_remote_nearest_plant_destruction_request(
		sender_id,
		request_id,
		target_net_id
	)


@rpc("any_peer", "call_remote", "reliable", 6)
func net_warehouse_command_requested(command: Dictionary) -> void:
	var sender_id := _get_rpc_sender_id()
	if _is_tower_management_suspended():
		return
	if (
		not _has_tower_mode()
		or not net_manager.is_host()
		or game == null
		or sender_id <= 0
		or not transactions_coordinator.consume_remote_transaction_admission(sender_id)
	):
		return
	tower_economy_coordinator.handle_authoritative_warehouse_command(
		sender_id,
		command
	)


@rpc("any_peer", "call_remote", "reliable", 6)
func net_warehouse_snapshot_requested(warehouse_net_id: int) -> void:
	var sender_id := _get_rpc_sender_id()
	if _is_tower_management_suspended():
		return
	if (
		not _has_tower_mode()
		or not net_manager.is_host()
		or game == null
		or sender_id <= 0
	):
		return
	tower_economy_coordinator.handle_authoritative_warehouse_snapshot_request(
		sender_id,
		warehouse_net_id
	)


@rpc("any_peer", "call_remote", "reliable", 6)
func net_production_command_requested(command: Dictionary) -> void:
	var sender_id := _get_rpc_sender_id()
	if _is_tower_management_suspended():
		return
	if (
		not _has_tower_mode()
		or not net_manager.is_host()
		or game == null
		or sender_id <= 0
		or not transactions_coordinator.consume_remote_transaction_admission(sender_id)
	):
		return
	tower_economy_coordinator.handle_authoritative_production_command(
		sender_id,
		command
	)


@rpc("any_peer", "call_remote", "reliable", 6)
func net_research_command_requested(command: Dictionary) -> void:
	var sender_id := _get_rpc_sender_id()
	if _is_tower_management_suspended():
		return
	if (
		not _has_tower_mode()
		or not net_manager.is_host()
		or game == null
		or sender_id <= 0
		or not transactions_coordinator.consume_remote_transaction_admission(sender_id)
	):
		return
	tower_economy_coordinator.handle_authoritative_research_command(
		sender_id,
		command
	)


@rpc("any_peer", "call_remote", "reliable", 6)
func net_production_snapshot_requested(building_net_id: int) -> void:
	var sender_id := _get_rpc_sender_id()
	if _is_tower_management_suspended():
		return
	if (
		not _has_tower_mode()
		or not net_manager.is_host()
		or game == null
		or sender_id <= 0
	):
		return
	tower_economy_coordinator.handle_authoritative_production_snapshot_request(
		sender_id,
		building_net_id
	)


@rpc("authority", "call_remote", "reliable", 6)
func net_warehouse_command_result(
	result: Dictionary,
	participant_incarnation: int = 0,
	session_incarnation: int = 0
) -> void:
	var peer_id := int(result.get("peer_id", 0))
	var request_id := int(result.get("request_id", 0))
	var warehouse_net_id := int(result.get("warehouse_net_id", 0))
	var inventory_snapshot := result.get("inventory_snapshot", {}) as Dictionary
	var inventory_revision := _get_authoritative_inventory_revision(
		peer_id,
		inventory_snapshot
	)
	var result_revision := request_id
	var encoded_result := _encode_subject_dictionary(peer_id, result)
	if (
		request_id <= 0
		or warehouse_net_id <= 0
		or inventory_revision < 0
		or typeof(result.get("storage_snapshot")) != TYPE_DICTIONARY
		or (result.get("storage_snapshot", {}) as Dictionary).is_empty()
		or not bool(encoded_result.get("accepted", false))
	):
		result_revision = -1
	_receive_authoritative_peer_result(
		peer_id,
		PEER_RESULT_WAREHOUSE_COMMAND,
		StringName("warehouse/%d/%d" % [warehouse_net_id, request_id]),
		result_revision,
		{
			"result": (
				encoded_result.get("value", {}) as Dictionary
			).duplicate(true),
		},
		participant_incarnation,
		session_incarnation
	)


@rpc("authority", "call_remote", "reliable", 6)
func net_production_command_result(result: Dictionary) -> void:
	tower_economy_coordinator.receive_production_command_result(result)


@rpc("authority", "call_remote", "reliable", 6)
func net_production_state_batch(
	net_ids: PackedInt32Array,
	states: Array,
	host_sample_times: PackedFloat64Array
) -> void:
	tower_economy_coordinator.receive_production_state_batch(
		net_ids,
		states,
		host_sample_times
	)


@rpc("authority", "call_remote", "reliable", 6)
func net_inventory_snapshot(
	peer_id: int,
	snapshot: Dictionary,
	force_inventory_repair: bool = false,
	participant_incarnation: int = 0,
	session_incarnation: int = 0
) -> void:
	var revision := _get_authoritative_inventory_revision(peer_id, snapshot)
	_receive_authoritative_peer_result(
		peer_id,
		PEER_RESULT_INVENTORY_SNAPSHOT,
		&"inventory/snapshot",
		revision,
		{
			"inventory_snapshot": _make_identity_neutral_inventory_snapshot(
				snapshot
			),
			"force_inventory_repair": force_inventory_repair,
		},
		participant_incarnation,
		session_incarnation
	)


@rpc("authority", "call_remote", "reliable", 6)
func net_warehouse_storage_snapshot_batch(
	warehouse_net_ids: PackedInt32Array,
	snapshots: Array
) -> void:
	if not _has_tower_mode():
		return
	if not tower_economy_coordinator.receive_warehouse_storage_snapshot_batch(
		warehouse_net_ids,
		snapshots
	):
		push_error("MpGame: rejected an invalid authoritative warehouse snapshot batch.")


@rpc("authority", "call_remote", "reliable", 6)
func net_research_command_result(
	request_id: int,
	building_net_id: int,
	success: bool,
	reason: StringName
) -> void:
	tower_economy_coordinator.receive_research_command_result(
		request_id,
		building_net_id,
		success,
		reason
	)


@rpc("authority", "call_remote", "reliable", 6)
func net_research_state_updated(
	state: Dictionary,
	changed_player_peer_id: int,
	current_xirang: int,
	participant_incarnation: int = 0,
	session_incarnation: int = 0
) -> void:
	if changed_player_peer_id == 0:
		# 全局研究推进不以某位玩家为 subject，保留独立领域入口；失败仍走
		# 同一个完整修复出口，不能伪造 peer 0 塞进玩家结果账本。
		if not _is_current_authoritative_session_incarnation(
			session_incarnation,
			&"research/state"
		):
			return
		if participant_incarnation != 0:
			push_warning("MpGame: 全局科研结果不得绑定玩家 participant incarnation。")
			_request_peer_result_full_repair()
			return
		if not tower_economy_coordinator.receive_research_state_updated(
			state,
			0,
			current_xirang
		):
			_request_peer_result_full_repair()
		return
	if changed_player_peer_id < 0:
		push_warning("MpGame: 科研结果携带非法 subject peer。")
		_request_peer_result_full_repair()
		return
	var encoded_state := _encode_research_state_for_subject(
		changed_player_peer_id,
		state
	)
	var revision := (
		int(state["revision"])
		if typeof(state.get("revision")) == TYPE_INT
		else -1
	)
	if not bool(encoded_state.get("accepted", false)) or current_xirang < 0:
		revision = -1
	_receive_authoritative_peer_result(
		changed_player_peer_id,
		PEER_RESULT_RESEARCH_STATE,
		&"research/state",
		revision,
		{
			"state": encoded_state.get("state", {}),
			"has_changed_player_level": bool(
				encoded_state.get("has_changed_player_level", false)
			),
			"changed_player_level": int(
				encoded_state.get("changed_player_level", 0)
			),
			"current_xirang": current_xirang,
		},
		participant_incarnation,
		session_incarnation
	)


func _apply_warehouse_storage_snapshot(
	warehouse_net_id: int,
	snapshot: Dictionary
) -> bool:
	return tower_economy_coordinator.apply_warehouse_storage_snapshot(
		warehouse_net_id,
		snapshot
	)


func _apply_warehouse_storage_snapshot_batch(
	warehouse_net_ids: PackedInt32Array,
	snapshots: Array
) -> bool:
	return tower_economy_coordinator.receive_warehouse_storage_snapshot_batch(
		warehouse_net_ids,
		snapshots
	)


func _cache_pending_warehouse_snapshot(
	warehouse_net_id: int,
	snapshot: Dictionary
) -> void:
	tower_economy_coordinator.cache_pending_warehouse_snapshot(
		warehouse_net_id,
		snapshot
	)


func _clear_pending_warehouse_snapshots() -> void:
	tower_economy_coordinator.clear_pending_warehouse_snapshots()


func _cache_pending_remote_production_state(
	net_id: int,
	state: Dictionary,
	host_sample_time: float
) -> bool:
	return tower_economy_coordinator.cache_pending_remote_production_state(
		net_id,
		state,
		host_sample_time
	)


func _take_pending_remote_production_state(net_id: int) -> Dictionary:
	return tower_economy_coordinator.take_pending_remote_production_state(net_id)


func _clear_pending_remote_production_states() -> void:
	tower_economy_coordinator.clear_pending_remote_production_states()



@rpc("authority", "call_remote", "reliable", 5)
func net_enemy_spawned(
	net_id: int,
	config_path: String,
	pos_x: float,
	pos_y: float,
	host_spawn_timestamp: float
) -> void:
	enemy_coordinator.receive_enemy_spawn_packet(
		net_id,
		config_path,
		Vector2(pos_x, pos_y),
		host_spawn_timestamp,
		_get_net_time(),
		session_coordinator.has_host_time_offset(),
		session_coordinator.get_host_to_client_time_offset()
	)


@rpc("authority", "call_remote", "reliable", 5)
func net_enemy_spawned_batch(
	net_ids: PackedInt32Array,
	config_paths: PackedStringArray,
	positions: PackedVector2Array,
	spawn_times: PackedFloat64Array
) -> void:
	enemy_coordinator.receive_enemy_spawn_batch(
		net_ids,
		config_paths,
		positions,
		spawn_times,
		_get_net_time(),
		session_coordinator.has_host_time_offset(),
		session_coordinator.get_host_to_client_time_offset()
	)


@rpc("authority", "call_remote", "reliable", 5)
func net_enemy_terminal(
	net_id: int,
	reason: int,
	event_position: Vector2,
	current_health: int = 0,
	health_revision: int = 0,
	confirmed_damage: int = 0,
	impact_direction: Vector2 = Vector2.ZERO,
	damage_type: int = EnemyConfig.DamageType.PHYSICAL,
	presentation_flags: int = 0,
	host_terminal_timestamp: float = -1.0
) -> void:
	if projectile_coordinator != null:
		projectile_coordinator.release_replica_projectiles_for_source(
			net_id,
			host_terminal_timestamp
		)
	enemy_coordinator.receive_enemy_terminal(
		net_id,
		reason,
		event_position,
		current_health,
		health_revision,
		confirmed_damage,
		impact_direction,
		damage_type,
		presentation_flags
	)


@rpc("authority", "call_remote", "reliable", 5)
func net_enemy_defeated(net_id: int, defeat_position: Vector2) -> void:
	if projectile_coordinator != null:
		projectile_coordinator.release_replica_projectiles_for_source(net_id)
	enemy_coordinator.receive_enemy_defeated(net_id, defeat_position)


@rpc("authority", "call_remote", "reliable", 5)
func net_enemy_removed(net_id: int) -> void:
	if projectile_coordinator != null:
		projectile_coordinator.release_replica_projectiles_for_source(net_id)
	enemy_coordinator.receive_enemy_removed(net_id)


@rpc("authority", "call_remote", "reliable", 5)
func net_enemy_escaped(net_id: int) -> void:
	if projectile_coordinator != null:
		projectile_coordinator.release_replica_projectiles_for_source(net_id)
	if not _has_tower_mode():
		return
	enemy_coordinator.receive_enemy_escaped(net_id)


@rpc("authority", "call_remote", "reliable", 5)
func net_base_health_changed(
	current_health: int,
	maximum_health: int,
	revision: int
) -> void:
	tower_world_coordinator.receive_base_health_changed(
		current_health,
		maximum_health,
		revision
	)


@rpc("authority", "call_remote", "unreliable_ordered", 7)
func net_tower_defense_wave_progress_changed(
	wave_number: int,
	defeated: int,
	escaped: int,
	resolved: int,
	total: int
) -> void:
	world_flow_coordinator.receive_wave_progress(
		wave_number,
		defeated,
		escaped,
		resolved,
		total
	)


@rpc("authority", "call_remote", "reliable", 5)
func net_tower_defense_wave_progress_keyframe(
	wave_number: int,
	defeated: int,
	escaped: int,
	resolved: int,
	total: int
) -> void:
	net_tower_defense_wave_progress_changed(
		wave_number,
		defeated,
		escaped,
		resolved,
		total
	)


@rpc("authority", "call_remote", "reliable", 5)
func net_xiaocong_fate_state_changed(state: Dictionary) -> void:
	tower_fate_coordinator.receive_fate_state(
		state,
		multiplayer.get_remote_sender_id()
	)


@rpc("authority", "call_remote", "reliable", 5)
func net_test_arena_manual_night_changed(enabled: bool) -> void:
	var sender_id := multiplayer.get_remote_sender_id()
	tower_world_coordinator.receive_test_arena_manual_night_changed(
		sender_id,
		enabled
	)


@rpc("authority", "call_remote", "reliable", 5)
func net_plant_spawned(
	request_id: int,
	owner_peer_id: int,
	net_id: int,
	plant_id: String,
	anchor: Vector2i,
	current_health: int,
	maximum_health: int,
	health_revision: int,
	runtime_state: Dictionary,
	host_sample_time: float
) -> void:
	tower_world_coordinator.receive_plant_spawn(
		request_id,
		owner_peer_id,
		net_id,
		plant_id,
		anchor,
		current_health,
		maximum_health,
		health_revision,
		runtime_state,
		host_sample_time
	)


@rpc("authority", "call_remote", "reliable", 5)
func net_plant_placement_rejected(request_id: int, reason: String) -> void:
	tower_world_coordinator.receive_plant_placement_rejected(request_id, reason)


@rpc("authority", "call_remote", "unreliable_ordered", 7)
func net_plant_health_changed(
	net_id: int,
	current_health: int,
	maximum_health: int,
	health_revision: int
) -> void:
	tower_world_coordinator.receive_plant_health_changed(
		net_id,
		current_health,
		maximum_health,
		health_revision
	)


@rpc("authority", "call_remote", "reliable", 5)
func net_plant_damage_status_changed(
	net_id: int,
	status_mask: int,
	status_revision: int
) -> void:
	tower_world_coordinator.receive_plant_damage_status_changed(
		net_id,
		status_mask,
		status_revision
	)


@rpc("authority", "call_remote", "reliable", 5)
func net_plant_removed(net_id: int, was_destroyed: bool = false) -> void:
	tower_world_coordinator.receive_plant_removed(net_id, was_destroyed)


@rpc("authority", "call_remote", "unreliable_ordered", 4)
func net_plant_projectile_visual(
	spawn_position: Vector2,
	direction: Vector2,
	speed: float,
	explosion_radius: float,
	lifetime: float
) -> void:
	tower_world_coordinator.receive_plant_projectile_visual(
		spawn_position,
		direction,
		speed,
		explosion_radius,
		lifetime
	)


@rpc("authority", "call_remote", "reliable", 5)
func net_bamboo_mortar_visual_batch(
	plant_net_ids: PackedInt32Array,
	action_ids: PackedInt32Array,
	stages: PackedByteArray,
	spawn_positions: PackedVector2Array,
	landing_positions: PackedVector2Array,
	committed_windup_durations: PackedFloat32Array,
	host_action_times: PackedFloat64Array
) -> void:
	tower_world_coordinator.receive_bamboo_mortar_visual_batch(
		plant_net_ids,
		action_ids,
		stages,
		spawn_positions,
		landing_positions,
		committed_windup_durations,
		host_action_times,
		_get_net_time(),
		session_coordinator.has_host_time_offset(),
		session_coordinator.get_host_to_client_time_offset()
	)


@rpc("authority", "call_remote", "reliable", 5)
func net_hydrangea_rain_visual(
	plant_net_id: int,
	action_id: int,
	target_position: Vector2,
	host_action_time: float
) -> void:
	tower_world_coordinator.receive_hydrangea_rain_visual(
		plant_net_id,
		action_id,
		target_position,
		host_action_time,
		_get_net_time(),
		session_coordinator.has_host_time_offset(),
		session_coordinator.get_host_to_client_time_offset()
	)


@rpc("authority", "call_remote", "unreliable_ordered", 4)
func net_corn_machine_gun_burst_batch(
	plant_net_ids: PackedInt32Array,
	action_ids: PackedInt32Array,
	shot_counts: PackedByteArray,
	directions: PackedVector2Array,
	host_action_times: PackedFloat64Array
) -> void:
	tower_world_coordinator.receive_corn_machine_gun_burst_batch(
		plant_net_ids,
		action_ids,
		shot_counts,
		directions,
		host_action_times,
		_get_net_time(),
		session_coordinator.has_host_time_offset(),
		session_coordinator.get_host_to_client_time_offset()
	)


@rpc("authority", "call_remote", "unreliable_ordered", 7)
func net_enemy_action(
	net_id: int,
	action_name: String,
	direction: Vector2,
	action_position: Vector2,
	action_id: int,
	host_action_timestamp: float = -1.0
) -> void:
	enemy_coordinator.receive_enemy_action_packet(
		net_id,
		action_name,
		direction,
		action_position,
		action_id,
		host_action_timestamp,
		_get_net_time(),
		session_coordinator.has_host_time_offset(),
		session_coordinator.get_host_to_client_time_offset()
	)


@rpc("authority", "call_remote", "unreliable_ordered", 7)
func net_enemy_target_action(
	net_id: int,
	action_name: String,
	target_peer_id: int,
	action_position: Vector2,
	action_id: int,
	host_action_timestamp: float = -1.0
) -> void:
	enemy_coordinator.receive_enemy_target_action_packet(
		net_id,
		action_name,
		target_peer_id,
		action_position,
		action_id,
		host_action_timestamp,
		_get_net_time(),
		session_coordinator.has_host_time_offset(),
		session_coordinator.get_host_to_client_time_offset()
	)


@rpc("authority", "call_remote", "unreliable_ordered", 7)
func net_enemy_lightning_chain(points: PackedVector2Array) -> void:
	enemy_coordinator.receive_enemy_lightning_chain(points)


@rpc("authority", "call_remote", "reliable", 5)
func net_pickup_removed(net_id: int) -> void:
	world_flow_coordinator.receive_pickup_removed(net_id)


@rpc("authority", "call_remote", "reliable", 5)
func net_pickup_spawned(net_id: int, config_path: String, pos_x: float, pos_y: float) -> void:
	world_flow_coordinator.receive_pickup_spawned(
		net_id,
		config_path,
		Vector2(pos_x, pos_y)
	)


@rpc("authority", "call_remote", "reliable", 5)
func net_pickup_collected(
	net_id: int,
	collector_peer_id: int,
	config_path: String,
	applied_immediately: bool,
	inventory_snapshot: Dictionary = {},
	participant_incarnation: int = 0,
	session_incarnation: int = 0
) -> void:
	var revision := _get_authoritative_inventory_revision(
		collector_peer_id,
		inventory_snapshot,
		0 if applied_immediately else -1
	)
	if net_id <= 0 or config_path.is_empty():
		revision = -1
	_receive_authoritative_peer_result(
		collector_peer_id,
		PEER_RESULT_PICKUP_COLLECTED,
		StringName("pickup/%d" % net_id),
		revision,
		{
			"net_id": net_id,
			"config_path": config_path,
			"applied_immediately": applied_immediately,
			"inventory_snapshot": _make_identity_neutral_inventory_snapshot(
				inventory_snapshot
			),
		},
		participant_incarnation,
		session_incarnation
	)


@rpc("authority", "call_remote", "reliable", 5)
func net_merchant_active_changed(active: bool) -> void:
	world_flow_coordinator.receive_merchant_active(active)



@rpc("authority", "call_remote", "reliable", 5)
func net_flow_state_changed(step_id: String, state: int, countdown_seconds: int) -> void:
	_receive_or_defer_tower_flow_state(step_id, state, countdown_seconds)


@rpc("authority", "call_remote", "reliable", 5)
func net_boss_started(net_id: int, boss_config_path: String, spawn_position: Vector2) -> void:
	world_flow_coordinator.receive_boss_started(
		net_id,
		boss_config_path,
		spawn_position,
		_get_net_time()
	)


@rpc("authority", "call_remote", "reliable", 5)
func net_linglan_airdrop_started(
	enemy_config_path: String,
	landing_position: Vector2,
	warning_duration: float,
	drop_height: float,
	drop_duration: float
) -> void:
	world_flow_coordinator.receive_linglan_airdrop_started(
		enemy_config_path,
		landing_position,
		warning_duration,
		drop_height,
		drop_duration
	)


@rpc("authority", "call_remote", "reliable", 5)
func net_game_defeated(failure_reason: String = "") -> void:
	world_flow_coordinator.receive_defeat(failure_reason)


@rpc("authority", "call_remote", "reliable", 5)
func net_game_victory() -> void:
	world_flow_coordinator.receive_victory()


@rpc("any_peer", "call_remote", "reliable", 6)
func net_upgrade_selected(stat_type: int) -> void:
	var sender_id := _get_rpc_sender_id()
	if _is_tower_management_suspended():
		return
	transactions_coordinator.handle_remote_upgrade_selection(sender_id, stat_type)


@rpc("any_peer", "call_remote", "reliable", 6)
func net_inventory_item_use_requested(
	slot_index: int,
	expected_inventory_revision: int = -1
) -> void:
	var sender_id := _get_rpc_sender_id()
	if _is_tower_management_suspended():
		return
	transactions_coordinator.handle_remote_inventory_item_use_request(
		sender_id,
		slot_index,
		expected_inventory_revision
	)


@rpc("any_peer", "call_remote", "reliable", 6)
func net_inventory_item_discard_requested(
	slot_index: int,
	expected_inventory_revision: int = -1
) -> void:
	var sender_id := _get_rpc_sender_id()
	if _is_tower_management_suspended():
		return
	transactions_coordinator.handle_remote_inventory_item_discard_request(
		sender_id,
		slot_index,
		expected_inventory_revision
	)


@rpc("any_peer", "call_remote", "reliable", 6)
func net_simple_crafting_requested(
	request_id: int,
	recipe_id: String,
	expected_inventory_revision: int
) -> void:
	var sender_id := _get_rpc_sender_id()
	if _is_tower_management_suspended():
		return
	transactions_coordinator.handle_remote_simple_crafting_request(
		sender_id,
		request_id,
		recipe_id,
		expected_inventory_revision
	)


@rpc("any_peer", "call_remote", "reliable", 6)
func net_skill1_purchase_requested() -> void:
	var sender_id := _get_rpc_sender_id()
	if _is_tower_management_suspended():
		return
	transactions_coordinator.handle_remote_skill1_purchase_request(sender_id)


@rpc("any_peer", "call_remote", "reliable", 5)
func net_tower_defense_start_wave_requested() -> void:
	var sender_id := multiplayer.get_remote_sender_id()
	if not net_manager.is_host() or not world_flow_coordinator.supports_wave_progress():
		return
	if sender_id <= 0:
		return
	if not transactions_coordinator.consume_remote_transaction_admission(sender_id):
		return
	if game.get_player_for_peer(sender_id) == null:
		return
	world_flow_coordinator.request_authoritative_wave_start(sender_id)


@rpc("any_peer", "call_remote", "reliable", 6)
func net_xiaocong_interaction_requested() -> void:
	var sender_id := multiplayer.get_remote_sender_id()
	if (
		not net_manager.is_host()
		or not _has_tower_mode()
		or sender_id <= 0
		or not transactions_coordinator.consume_remote_transaction_admission(
			sender_id
		)
	):
		return
	tower_fate_coordinator.handle_remote_interaction(sender_id)


@rpc("any_peer", "call_remote", "reliable", 6)
func net_xiaocong_fate_vote_requested(
	option_id: String,
	permanent_buff_id: String
) -> void:
	var sender_id := multiplayer.get_remote_sender_id()
	if (
		not net_manager.is_host()
		or not _has_tower_mode()
		or sender_id <= 0
		or not transactions_coordinator.consume_remote_transaction_admission(
			sender_id
		)
	):
		return
	tower_fate_coordinator.handle_remote_vote(
		sender_id,
		option_id,
		permanent_buff_id
	)


@rpc("any_peer", "call_remote", "reliable", 6)
func net_xiaocong_collectible_choice_requested(choice_index: int) -> void:
	var sender_id := multiplayer.get_remote_sender_id()
	if (
		not net_manager.is_host()
		or not _has_tower_mode()
		or sender_id <= 0
		or not transactions_coordinator.consume_remote_transaction_admission(
			sender_id
		)
	):
		return
	tower_fate_coordinator.handle_remote_collectible_choice(
		sender_id,
		choice_index
	)


@rpc("any_peer", "call_remote", "reliable", 6)
func net_luoxi_collectible_offer_requested() -> void:
	var sender_id := _get_rpc_sender_id()
	if (
		not net_manager.is_host()
		or _is_tower_management_suspended()
		or sender_id <= 0
		or not transactions_coordinator.consume_remote_transaction_admission(
			sender_id
		)
	):
		return
	merchant_transactions_coordinator.handle_remote_luoxi_collectible_offer_requested(
		sender_id
	)


@rpc("any_peer", "call_remote", "reliable", 6)
func net_luoxi_collectible_choice_requested(
	choice_index: int,
	offer_revision: int = 0
) -> void:
	var sender_id := _get_rpc_sender_id()
	if (
		not net_manager.is_host()
		or _is_tower_management_suspended()
		or sender_id <= 0
		or not transactions_coordinator.consume_remote_transaction_admission(
			sender_id
		)
	):
		return
	merchant_transactions_coordinator.handle_remote_luoxi_collectible_choice_requested(
		sender_id,
		choice_index,
		offer_revision
	)


@rpc("any_peer", "call_remote", "reliable", 6)
func net_luoxi_collectible_refresh_requested(offer_revision: int = 0) -> void:
	var sender_id := _get_rpc_sender_id()
	if (
		not net_manager.is_host()
		or _is_tower_management_suspended()
		or sender_id <= 0
		or not transactions_coordinator.consume_remote_transaction_admission(
			sender_id
		)
	):
		return
	merchant_transactions_coordinator.handle_remote_luoxi_collectible_refresh_requested(
		sender_id,
		offer_revision
	)


@rpc("any_peer", "call_remote", "reliable", 6)
func net_luoxi_special_game_start_requested() -> void:
	var sender_id := _get_rpc_sender_id()
	if (
		not net_manager.is_host()
		or _is_tower_management_suspended()
		or sender_id <= 0
		or not transactions_coordinator.consume_remote_transaction_admission(
			sender_id
		)
	):
		return
	merchant_transactions_coordinator.handle_remote_luoxi_special_game_start_requested(
		sender_id
	)


@rpc("any_peer", "call_remote", "reliable", 6)
func net_luoxi_special_game_card_reveal_requested(
	session_revision: int,
	card_index: int
) -> void:
	var sender_id := _get_rpc_sender_id()
	if (
		not net_manager.is_host()
		or _is_tower_management_suspended()
		or sender_id <= 0
		or not transactions_coordinator.consume_remote_transaction_admission(
			sender_id
		)
	):
		return
	merchant_transactions_coordinator.handle_remote_luoxi_special_game_card_reveal_requested(
		sender_id,
		session_revision,
		card_index
	)


@rpc("any_peer", "call_remote", "reliable", 6)
func net_luoxi_special_game_finish_requested(session_revision: int) -> void:
	var sender_id := _get_rpc_sender_id()
	if (
		not net_manager.is_host()
		or _is_tower_management_suspended()
		or sender_id <= 0
		or not transactions_coordinator.consume_remote_transaction_admission(
			sender_id
		)
	):
		return
	merchant_transactions_coordinator.handle_remote_luoxi_special_game_finish_requested(
		sender_id,
		session_revision
	)


@rpc("any_peer", "call_remote", "reliable", 6)
func net_cheat_xirang_requested() -> void:
	var sender_id := _get_rpc_sender_id()
	if (
		not net_manager.is_host()
		or not OS.is_debug_build()
		or _is_tower_management_suspended()
		or sender_id <= 0
		or not transactions_coordinator.consume_remote_transaction_admission(
			sender_id
		)
	):
		return
	merchant_transactions_coordinator.handle_remote_cheat_xirang_requested(
		sender_id
	)


@rpc("any_peer", "call_remote", "reliable", 6)
func net_debug_collectible_requested(config_path: String) -> void:
	var sender_id := _get_rpc_sender_id()
	if (
		not net_manager.is_host()
		or _is_tower_management_suspended()
		or sender_id <= 0
		or not transactions_coordinator.consume_remote_transaction_admission(
			sender_id
		)
	):
		return
	merchant_transactions_coordinator.handle_remote_debug_collectible_requested(
		sender_id,
		config_path
	)


@rpc("authority", "call_remote", "reliable", 6)
func net_upgrade_confirmed(
	peer_id: int,
	stat_type: int,
	level: int,
	current_xirang: int,
	success: bool,
	free_upgrade: bool = false,
	participant_incarnation: int = 0,
	session_incarnation: int = 0
) -> void:
	var revision := level
	var is_progression_state := success
	if (
		not RunStateStore.MAX_UPGRADE_LEVELS.has(stat_type)
		or level < 0
		or level > int(RunStateStore.MAX_UPGRADE_LEVELS[stat_type])
	):
		revision = -1
	_receive_authoritative_peer_result(
		peer_id,
		PEER_RESULT_UPGRADE_CONFIRMED,
		(
			StringName("upgrade/%d" % stat_type)
			if is_progression_state
			else StringName(
				"upgrade-feedback/%d/%d/%d"
				% [stat_type, level, int(success)]
			)
		),
		revision,
		{
			"stat_type": stat_type,
			"level": level,
			"current_xirang": current_xirang,
			"success": success,
			"free_upgrade": free_upgrade,
		},
		participant_incarnation,
		session_incarnation,
		# 包内余额会随时间变化，同一等级的 runtime repair 由领域高水位
		# 幂等收敛，不能在 PeerLedger 中因 payload 不同制造 revision 冲突。
		MpPeerLedgerCoordinatorScript.AppliedReplayPolicy.DOMAIN_OWNED
	)


@rpc("authority", "call_remote", "reliable", 6)
func net_inventory_item_used(
	peer_id: int,
	slot_index: int,
	config_path: String,
	success: bool,
	inventory_snapshot: Dictionary,
	force_inventory_repair: bool = false,
	participant_incarnation: int = 0,
	session_incarnation: int = 0
) -> void:
	var revision := _get_authoritative_inventory_revision(
		peer_id,
		inventory_snapshot
	)
	_receive_authoritative_peer_result(
		peer_id,
		PEER_RESULT_INVENTORY_ITEM_USED,
		StringName(
			"inventory-use/%d/%d/%d/%d"
			% [revision, slot_index, int(success), config_path.hash()]
		),
		revision,
		{
			"slot_index": slot_index,
			"config_path": config_path,
			"success": success,
			"inventory_snapshot": _make_identity_neutral_inventory_snapshot(
				inventory_snapshot
			),
			"force_inventory_repair": force_inventory_repair,
		},
		participant_incarnation,
		session_incarnation
	)


@rpc("authority", "call_remote", "reliable", 6)
func net_inventory_item_discarded(
	peer_id: int,
	slot_index: int,
	success: bool,
	inventory_snapshot: Dictionary,
	force_inventory_repair: bool = false,
	participant_incarnation: int = 0,
	session_incarnation: int = 0
) -> void:
	var revision := _get_authoritative_inventory_revision(
		peer_id,
		inventory_snapshot
	)
	_receive_authoritative_peer_result(
		peer_id,
		PEER_RESULT_INVENTORY_ITEM_DISCARDED,
		StringName(
			"inventory-discard/%d/%d/%d"
			% [revision, slot_index, int(success)]
		),
		revision,
		{
			"slot_index": slot_index,
			"success": success,
			"inventory_snapshot": _make_identity_neutral_inventory_snapshot(
				inventory_snapshot
			),
			"force_inventory_repair": force_inventory_repair,
		},
		participant_incarnation,
		session_incarnation
	)


@rpc("authority", "call_remote", "reliable", 6)
func net_simple_crafting_result(
	peer_id: int,
	request_id: int,
	recipe_id: String,
	result: String,
	inventory_snapshot: Dictionary,
	force_inventory_repair: bool = false,
	participant_incarnation: int = 0,
	session_incarnation: int = 0
) -> void:
	var inventory_revision := _get_authoritative_inventory_revision(
		peer_id,
		inventory_snapshot
	)
	var result_revision := request_id if inventory_revision >= 0 else -1
	if request_id <= 0:
		result_revision = -1
	# request_id 是制作 UI token 的稳定映射，必须成为独立流，不能被较新的
	# 背包 revision 覆盖后让旧面板永远等不到结算。
	_receive_authoritative_peer_result(
		peer_id,
		PEER_RESULT_SIMPLE_CRAFTING,
		StringName("craft/%d" % request_id),
		result_revision,
		{
			"request_id": request_id,
			"recipe_id": recipe_id,
			"result": result,
			"inventory_snapshot": _make_identity_neutral_inventory_snapshot(
				inventory_snapshot
			),
			"force_inventory_repair": force_inventory_repair,
		},
		participant_incarnation,
		session_incarnation
	)


@rpc("authority", "call_remote", "reliable", 6)
func net_skill1_purchase_confirmed(
	peer_id: int,
	current_xirang: int,
	skill1_unlocked: bool,
	result_code: int,
	skill1_upgrade_level: int = -1,
	skill1_charge_duration: float = -1.0,
	participant_incarnation: int = 0,
	session_incarnation: int = 0
) -> void:
	var revision := 0
	var is_progression_repair := (
		result_code == MerchantPurchaseResult.SkillUpgrade.SUCCESS
		and skill1_upgrade_level >= 0
	)
	if is_progression_repair:
		revision = skill1_upgrade_level
	if (
		peer_id <= 0
		or current_xirang < 0
		or result_code < MerchantPurchaseResult.SkillUpgrade.SUCCESS
		or result_code > MerchantPurchaseResult.SkillUpgrade.UPGRADE_MAXED
		or skill1_upgrade_level < -1
		or skill1_upgrade_level > Player.SKILL1_MAX_UPGRADE_LEVEL
		or not is_finite(skill1_charge_duration)
		or (skill1_charge_duration != -1.0 and skill1_charge_duration <= 0.0)
	):
		revision = -1
	# 既有 SUCCESS 码承载无 UI 的稳定 skill1/state 修复流；真实购买反馈仍按
	# 原结算字段分流。二者都由领域内等级高水位处理迟到包。
	_receive_authoritative_peer_result(
		peer_id,
		PEER_RESULT_SKILL1_PURCHASE,
		(
			&"skill1/state"
			if is_progression_repair
			else StringName(
				"skill1/%d/%d/%d/%d"
				% [
					skill1_upgrade_level,
					current_xirang,
					int(skill1_unlocked),
					result_code,
				]
			)
		),
		revision,
		{
			"current_xirang": current_xirang,
			"skill1_unlocked": skill1_unlocked,
			"result_code": result_code,
			"skill1_upgrade_level": skill1_upgrade_level,
			"skill1_charge_duration": skill1_charge_duration,
		},
		participant_incarnation,
		session_incarnation,
		MpPeerLedgerCoordinatorScript.AppliedReplayPolicy.DOMAIN_OWNED
	)


@rpc("authority", "call_remote", "reliable", 6)
func net_luoxi_collectible_offer_state(
	peer_id: int,
	offer_revision: int,
	config_paths: PackedStringArray,
	refresh_count: int,
	current_xirang: int,
	refresh_result_code: int = -1,
	participant_incarnation: int = 0,
	session_incarnation: int = 0
) -> void:
	var revision := offer_revision
	if refresh_count < 0 or current_xirang < 0:
		revision = -1
	var includes_operation_feedback := refresh_result_code >= 0
	_receive_authoritative_peer_result(
		peer_id,
		PEER_RESULT_LUOXI_OFFER_STATE,
		(
			StringName(
				"luoxi/offer-feedback/%d/%d"
				% [refresh_result_code, current_xirang]
			)
			if includes_operation_feedback
			else &"luoxi/offer"
		),
		revision,
		{
			"offer_revision": offer_revision,
			"config_paths": Array(config_paths),
			"refresh_count": refresh_count,
			"current_xirang": current_xirang,
			"refresh_result_code": refresh_result_code,
		},
		participant_incarnation,
		session_incarnation,
		(
			MpPeerLedgerCoordinatorScript.AppliedReplayPolicy.DOMAIN_OWNED
			if includes_operation_feedback
			else MpPeerLedgerCoordinatorScript.AppliedReplayPolicy.TRACK_REVISION
		)
	)


@rpc("authority", "call_remote", "reliable", 6)
func net_luoxi_collectible_confirmed(
	peer_id: int,
	choice_index: int,
	config_path: String,
	result_code: int,
	offer_revision: int = 0,
	inventory_snapshot: Dictionary = {},
	participant_incarnation: int = 0,
	session_incarnation: int = 0
) -> void:
	var inventory_revision := _get_authoritative_inventory_revision(
		peer_id,
		inventory_snapshot,
		maxi(offer_revision, 0)
	)
	_receive_authoritative_peer_result(
		peer_id,
		PEER_RESULT_LUOXI_COLLECTIBLE,
		StringName(
			"luoxi-claim/%d/%d/%d"
			% [offer_revision, choice_index, result_code]
		),
		inventory_revision,
		{
			"choice_index": choice_index,
			"config_path": config_path,
			"result_code": result_code,
			"offer_revision": offer_revision,
			"inventory_snapshot": _make_identity_neutral_inventory_snapshot(
				inventory_snapshot
			),
		},
		participant_incarnation,
		session_incarnation
	)


@rpc("authority", "call_remote", "reliable", 6)
func net_luoxi_collectible_refresh_confirmed(
	peer_id: int,
	result_code: int,
	refresh_count: int,
	current_xirang: int,
	participant_incarnation: int = 0,
	session_incarnation: int = 0
) -> void:
	var revision := refresh_count
	if current_xirang < 0:
		revision = -1
	_receive_authoritative_peer_result(
		peer_id,
		PEER_RESULT_LUOXI_REFRESH,
		StringName("luoxi-refresh/%d/%d" % [result_code, current_xirang]),
		revision,
		{
			"result_code": result_code,
			"refresh_count": refresh_count,
			"current_xirang": current_xirang,
		},
		participant_incarnation,
		session_incarnation,
		MpPeerLedgerCoordinatorScript.AppliedReplayPolicy.DOMAIN_OWNED
	)


@rpc("authority", "call_remote", "reliable", 6)
func net_luoxi_special_game_started(
	peer_id: int,
	result: Dictionary,
	inventory_snapshot: Dictionary = {},
	participant_incarnation: int = 0,
	session_incarnation: int = 0
) -> void:
	var session_revision := (
		int(result["session_revision"])
		if typeof(result.get("session_revision")) == TYPE_INT
		else -1
	)
	var inventory_revision := _get_authoritative_inventory_revision(
		peer_id,
		inventory_snapshot,
		maxi(session_revision, 0)
	)
	var encoded_result := _encode_subject_dictionary(peer_id, result)
	var result_code_valid := (
		typeof(result.get("result_code")) == TYPE_INT
		and int(result["result_code"])
		>= LuoxiSpecialGameCoordinator.ResultCode.SUCCESS
		and int(result["result_code"])
		<= LuoxiSpecialGameCoordinator.ResultCode.PLAYER_DIED
	)
	if (
		session_revision < 0
		or not result_code_valid
		or not bool(encoded_result.get("accepted", false))
	):
		inventory_revision = -1
	_receive_authoritative_peer_result(
		peer_id,
		PEER_RESULT_LUOXI_SPECIAL_STARTED,
		StringName(
			"luoxi-special-start/%d/%d"
			% [session_revision, int(result.get("result_code", -1))]
		),
		inventory_revision,
		{
			"result": encoded_result.get("value", {}),
			"inventory_snapshot": _make_identity_neutral_inventory_snapshot(
				inventory_snapshot
			),
		},
		participant_incarnation,
		session_incarnation
	)


@rpc("authority", "call_remote", "reliable", 6)
func net_luoxi_special_game_card_revealed(
	peer_id: int,
	result: Dictionary,
	participant_incarnation: int = 0,
	session_incarnation: int = 0
) -> void:
	var session_revision := (
		int(result["session_revision"])
		if typeof(result.get("session_revision")) == TYPE_INT
		else -1
	)
	var card_index := (
		int(result["card_index"])
		if typeof(result.get("card_index")) == TYPE_INT
		else -1
	)
	var encoded_result := _encode_subject_dictionary(peer_id, result)
	var revision := session_revision
	var result_code_valid := (
		typeof(result.get("result_code")) == TYPE_INT
		and int(result["result_code"])
		>= LuoxiSpecialGameCoordinator.ResultCode.SUCCESS
		and int(result["result_code"])
		<= LuoxiSpecialGameCoordinator.ResultCode.PLAYER_DIED
	)
	if not result_code_valid or not bool(encoded_result.get("accepted", false)):
		revision = -1
	_receive_authoritative_peer_result(
		peer_id,
		PEER_RESULT_LUOXI_SPECIAL_CARD,
		StringName(
			"luoxi-card/%d/%d/%d"
			% [session_revision, card_index, int(result.get("result_code", -1))]
		),
		revision,
		{"result": encoded_result.get("value", {})},
		participant_incarnation,
		session_incarnation
	)


@rpc("authority", "call_remote", "reliable", 6)
func net_luoxi_special_game_finished(
	peer_id: int,
	result: Dictionary,
	inventory_snapshot: Dictionary = {},
	participant_incarnation: int = 0,
	session_incarnation: int = 0
) -> void:
	var session_revision := (
		int(result["session_revision"])
		if typeof(result.get("session_revision")) == TYPE_INT
		else -1
	)
	var inventory_revision := _get_authoritative_inventory_revision(
		peer_id,
		inventory_snapshot,
		maxi(session_revision, 0)
	)
	var encoded_result := _encode_subject_dictionary(peer_id, result)
	var result_code_valid := (
		typeof(result.get("result_code")) == TYPE_INT
		and int(result["result_code"])
		>= LuoxiSpecialGameCoordinator.ResultCode.SUCCESS
		and int(result["result_code"])
		<= LuoxiSpecialGameCoordinator.ResultCode.PLAYER_DIED
	)
	if (
		session_revision < 0
		or not result_code_valid
		or not bool(encoded_result.get("accepted", false))
	):
		inventory_revision = -1
	_receive_authoritative_peer_result(
		peer_id,
		PEER_RESULT_LUOXI_SPECIAL_FINISHED,
		StringName(
			"luoxi-special-finish/%d/%d"
			% [session_revision, int(result.get("result_code", -1))]
		),
		inventory_revision,
		{
			"result": encoded_result.get("value", {}),
			"inventory_snapshot": _make_identity_neutral_inventory_snapshot(
				inventory_snapshot
			),
		},
		participant_incarnation,
		session_incarnation
	)


@rpc("authority", "call_remote", "unreliable", 7)
func net_collectible_visual_effect(
	effect_type: String,
	spawn_position: Vector2,
	radius: float,
	color: Color,
	duration: float,
	effect_event_id: int = 0
) -> void:
	collectible_presentation_coordinator.receive_visual_effect(
		effect_type,
		spawn_position,
		radius,
		color,
		duration,
		effect_event_id
	)


@rpc("authority", "call_remote", "unreliable", 7)
func net_collectible_follow_visual_effect(
	effect_type: String,
	owner_peer_id: int,
	radius: float,
	duration: float,
	effect_event_id: int = 0
) -> void:
	collectible_presentation_coordinator.receive_follow_visual_effect(
		effect_type,
		owner_peer_id,
		radius,
		duration,
		effect_event_id
	)


@rpc("authority", "call_remote", "reliable", 6)
func net_cheat_xirang_confirmed(
	peer_id: int,
	current_xirang: int,
	added_amount: int,
	participant_incarnation: int = 0,
	session_incarnation: int = 0
) -> void:
	var revision := current_xirang
	if added_amount <= 0:
		revision = -1
	_receive_authoritative_peer_result(
		peer_id,
		PEER_RESULT_CHEAT_XIRANG,
		&"cheat/xirang",
		revision,
		{
			"current_xirang": current_xirang,
			"added_amount": added_amount,
		},
		participant_incarnation,
		session_incarnation
	)


@rpc("authority", "call_remote", "reliable", 6)
func net_debug_collectible_granted(
	peer_id: int,
	config_path: String,
	success: bool,
	inventory_snapshot: Dictionary = {},
	participant_incarnation: int = 0,
	session_incarnation: int = 0
) -> void:
	var inventory_revision := _get_authoritative_inventory_revision(
		peer_id,
		inventory_snapshot,
		0
	)
	_receive_authoritative_peer_result(
		peer_id,
		PEER_RESULT_DEBUG_COLLECTIBLE,
		StringName(
			"debug-grant/%d/%d/%d"
			% [inventory_revision, int(success), config_path.hash()]
		),
		inventory_revision,
		{
			"config_path": config_path,
			"success": success,
			"inventory_snapshot": _make_identity_neutral_inventory_snapshot(
				inventory_snapshot
			),
		},
		participant_incarnation,
		session_incarnation
	)


func _apply_debug_collectible_for_peer(peer_id: int, config_path: String) -> void:
	if merchant_transactions_coordinator == null:
		return
	merchant_transactions_coordinator.apply_debug_collectible_for_peer(
		peer_id,
		config_path
	)


func _get_host_peer_id() -> int:
	return net_manager.get_host_peer_id() if net_manager != null else 1


func _get_local_peer_id() -> int:
	if net_manager == null:
		return 0
	return int(net_manager.get_local_peer_id())


func _get_client_view_local_peer_id() -> int:
	var local_peer_id := _get_local_peer_id()
	if local_peer_id > 0:
		return local_peer_id
	if game != null:
		return int(game.multiplayer_local_peer_id)
	return 0


func _get_net_time() -> float:
	return session_coordinator.get_net_time()


func _map_host_timestamp_to_client_time(host_timestamp: float, update_offset: bool = true) -> float:
	return session_coordinator.map_host_timestamp_to_client_time(
		host_timestamp,
		update_offset
	)


func _on_connection_state_changed(new_state: int) -> void:
	if new_state == STATE_DISCONNECTED:
		_return_to_lobby()
	elif new_state == STATE_IN_GAME:
		if embedded_runtime:
			if _embedded_runtime_active and net_manager.is_client():
				_request_runtime_state_from_host()
				if _peer_result_repair_needed:
					_schedule_peer_result_full_repair()
			return
		_client_host_game_ready = true
		if game != null:
			game.activate_runtime()
		if net_manager.is_client():
			_request_runtime_state_from_host()
			if _peer_result_repair_needed:
				_schedule_peer_result_full_repair()
func _on_net_player_left(peer_id: int) -> void:
	if peer_id <= 0:
		return
	if embedded_runtime and not _is_known_embedded_reconnect_identity(peer_id):
		return
	var member_already_final := (
		net_manager != null
		and net_manager.get_session_membership_revision() > 0
		and not net_manager.has_session_member(peer_id)
	)
	if not member_already_final:
		var reused_pending_capture := (
			_rebase_reconnect_projection_state_for_disconnected_peer(peer_id)
		)
		if not reused_pending_capture:
			_capture_disconnected_player_reconnect_state(peer_id)
	if tower_mode_adapter != null:
		tower_rogue_route_bridge.capture_embedded_route_peer_before_removal(
			peer_id
		)
		if net_manager.is_host():
			tower_mode_adapter.handle_rogue_exploration_peer_left(peer_id)
		else:
			tower_rogue_route_bridge.remove_embedded_route_peer_locally(peer_id)
		tower_rogue_route_bridge.clear_embedded_peer_transport_state(peer_id)
	_clear_peer_network_state(peer_id)
	if game != null:
		game.remove_multiplayer_player(peer_id)


func _clear_final_departed_peer_identity_state(peer_id: int) -> void:
	_disconnected_player_reconnect_states.erase(peer_id)
	for old_peer_id_variant in (
		_pending_reconnected_player_projections.keys().duplicate()
	):
		var old_peer_id := int(old_peer_id_variant)
		var pending := (
			_pending_reconnected_player_projections.get(old_peer_id, {})
			as Dictionary
		)
		if (
			old_peer_id != peer_id
			and int(pending.get("new_peer_id", 0)) != peer_id
		):
			continue
		_pending_reconnected_player_projections.erase(old_peer_id)
		_disconnected_player_reconnect_states.erase(old_peer_id)
	for old_peer_id_variant in (
		_completed_reconnected_player_projections.keys().duplicate()
	):
		var old_peer_id := int(old_peer_id_variant)
		if (
			old_peer_id != peer_id
			and int(_completed_reconnected_player_projections[old_peer_id])
			!= peer_id
		):
			continue
		_completed_reconnected_player_projections.erase(old_peer_id)
		_disconnected_player_reconnect_states.erase(old_peer_id)
	_embedded_participant_peer_ids.erase(peer_id)
	_suspended_embedded_participant_peer_ids.erase(peer_id)
	_projecting_embedded_participant_peer_ids.erase(peer_id)
	if _peer_ledger_generation > 0 and peer_ledger_coordinator != null:
		peer_ledger_coordinator.clear_peer(_peer_ledger_generation, peer_id)


func _capture_disconnected_player_reconnect_state(peer_id: int) -> void:
	if game == null or peer_id <= 0:
		return
	var player_runtime_state := (
		player_coordinator.capture_player_reconnect_state(peer_id)
	)
	if player_runtime_state.is_empty():
		push_error(
			"MpGame: 无法捕获断线玩家 %d 的权威运行时状态。" % peer_id
		)
		return
	var spawn_slot_index := 0
	var wave_death_count := 0
	var tower_world_spawn_restore_pending := false
	if _has_tower_mode():
		spawn_slot_index = (
			tower_mode_adapter.get_reconnect_spawn_slot_index(peer_id)
		)
		wave_death_count = (
			tower_mode_adapter.get_reconnect_wave_death_count(peer_id)
		)
		tower_world_spawn_restore_pending = (
			tower_mode_adapter.is_rogue_tower_world_suspended()
			or tower_mode_adapter.is_fate_interlude_active()
		)
	var owned_plant_net_ids: Array[int] = []
	if _has_tower_mode():
		for plant_snapshot in _get_tower_plant_snapshots():
			if int(plant_snapshot.get("owner_peer_id", 0)) == peer_id:
				owned_plant_net_ids.append(int(plant_snapshot.get("net_id", 0)))
	var reconnect_state := {
		"spawn_slot_index": spawn_slot_index,
		"wave_death_count": wave_death_count,
		"owned_plant_net_ids": owned_plant_net_ids,
		"tower_world_spawn_restore_pending": (
			tower_world_spawn_restore_pending
		),
	}
	reconnect_state.merge(player_runtime_state, true)
	reconnect_state.merge(
		merchant_transactions_coordinator.capture_reconnect_state(peer_id),
		true
	)
	_disconnected_player_reconnect_states[peer_id] = reconnect_state


## 内嵌战斗的 canonical participant 必须在身份账本提交点迁移，不能等待
## Player 节点创建。prepare 只读校验目标是否空闲；commit 随后只有字典键迁移，
## 不再包含可能失败的步骤，因此不会制造“RunState 已迁移、战斗 roster 未迁移”。
func _prepare_embedded_participant_identity_remap(
	old_peer_id: int,
	new_peer_id: int
) -> bool:
	if not embedded_runtime:
		return true
	if _embedded_participant_peer_ids.has(old_peer_id):
		return not _embedded_participant_peer_ids.has(new_peer_id)
	var pending := (
		_pending_reconnected_player_projections.get(old_peer_id, {})
		as Dictionary
	)
	return (
		int(pending.get("new_peer_id", 0)) == new_peer_id
		and _embedded_participant_peer_ids.has(new_peer_id)
		and _projecting_embedded_participant_peer_ids.has(new_peer_id)
	)


func _commit_embedded_participant_identity_remap(
	old_peer_id: int,
	new_peer_id: int
) -> void:
	# pending 重放已经提交过这次键迁移，只需保持原 PROJECTING 租约。
	if not embedded_runtime or not _embedded_participant_peer_ids.has(old_peer_id):
		return
	var was_suspended := _suspended_embedded_participant_peer_ids.has(old_peer_id)
	var was_projecting := _projecting_embedded_participant_peer_ids.has(old_peer_id)
	_embedded_participant_peer_ids.erase(old_peer_id)
	_embedded_participant_peer_ids[new_peer_id] = true
	_suspended_embedded_participant_peer_ids.erase(old_peer_id)
	_projecting_embedded_participant_peer_ids.erase(old_peer_id)
	if was_suspended:
		_suspended_embedded_participant_peer_ids[new_peer_id] = true
	elif was_projecting:
		_projecting_embedded_participant_peer_ids[new_peer_id] = true
	else:
		# 正常重连从身份提交到 Player/路线/CH6 全部收敛前都不可参与战斗。
		_projecting_embedded_participant_peer_ids[new_peer_id] = true


func _is_known_embedded_reconnect_identity(peer_id: int) -> bool:
	if _embedded_participant_peer_ids.has(peer_id):
		return true
	for pending_variant in _pending_reconnected_player_projections.values():
		var pending := pending_variant as Dictionary
		if int(pending.get("new_peer_id", 0)) == peer_id:
			return true
	return _completed_reconnected_player_projections.values().has(peer_id)


func _on_net_player_reconnected(
	old_peer_id: int,
	new_peer_id: int,
	player_name: String,
	character_id: StringName,
	membership_revision: int
) -> void:
	if (
		old_peer_id <= 0
		or new_peer_id <= 0
		or old_peer_id == new_peer_id
	):
		return
	if (
		embedded_runtime
		and _embedded_participant_peer_ids.has(old_peer_id)
		and _suspended_embedded_participant_peer_ids.has(old_peer_id)
	):
		if not _prepare_embedded_participant_identity_remap(
			old_peer_id,
			new_peer_id
		):
			_fail_reconnected_peer_identity(
				old_peer_id,
				new_peer_id,
				"内嵌战斗目标身份已被其他参与者占用。"
			)
			return
		if not _commit_reconnected_peer_identity(
			old_peer_id,
			new_peer_id,
			membership_revision
		):
			_fail_reconnected_peer_identity(
				old_peer_id,
				new_peer_id,
				"内嵌战斗身份账本无法原子迁移。"
			)
			return
		_commit_embedded_participant_identity_remap(old_peer_id, new_peer_id)
		_clear_peer_network_state(old_peer_id)
		_clear_peer_network_state(new_peer_id)
		_finalize_reconnected_projection_and_claim(
			old_peer_id,
			new_peer_id,
			ReconnectedPlayerProjectionOutcome.SUSPENDED
		)
		return
	var completed_new_peer_id := int(
		_completed_reconnected_player_projections.get(old_peer_id, 0)
	)
	if completed_new_peer_id > 0 and completed_new_peer_id != new_peer_id:
		push_error(
			"MpGame: 已完成身份 %d 不得同时投影到 %d/%d。"
			% [old_peer_id, completed_new_peer_id, new_peer_id]
		)
		_fail_reconnected_peer_identity(
			old_peer_id,
			new_peer_id,
			"同一个旧身份被映射到多个新连接。"
		)
		return
	var pending_projection := (
		_pending_reconnected_player_projections.get(old_peer_id, {})
		as Dictionary
	)
	if (
		not pending_projection.is_empty()
		and int(pending_projection.get("new_peer_id", 0)) != new_peer_id
	):
		# 必须在身份账本提交前拒绝一对多映射；否则一次异常重放会创建
		# 第二份 new-id 持久身份，而后续投影重试已无法安全判断真源。
		push_error(
			"MpGame: 待恢复身份 %d 不得同时投影到 %d/%d。"
			% [
				old_peer_id,
				int(pending_projection.get("new_peer_id", 0)),
				new_peer_id,
			]
		)
		_fail_reconnected_peer_identity(
			old_peer_id,
			new_peer_id,
			"待恢复身份出现一对多映射。"
		)
		return
	if completed_new_peer_id == new_peer_id:
		if game == null:
			# 已完成事务没有第二份 capture 可重放；运行时重建完成后由权威
			# roster/keyframe 恢复表现；对当前作战显式报告无法继续参战。
			_publish_reconnected_player_projection_outcome(
				old_peer_id,
				new_peer_id,
				ReconnectedPlayerProjectionOutcome.SUSPENDED
			)
			return
		var replay_projection := game.ensure_reconnected_multiplayer_player(
			old_peer_id,
			new_peer_id,
			player_name,
			character_id,
			null,
			0,
			{}
		)
		if (
			replay_projection.status
			!= CombatRuntimeBase.ReconnectedPlayerProjectionStatus.EXISTING_CURRENT
		):
			push_error(
				"MpGame: 已完成的重连投影 %d -> %d 重放时不再是 current，status=%d。"
				% [old_peer_id, new_peer_id, replay_projection.status]
			)
			_fail_reconnected_peer_identity(
				old_peer_id,
				new_peer_id,
				"已完成的玩家投影不再对应当前身份。"
			)
		else:
			_publish_reconnected_player_projection_outcome(
				old_peer_id,
				new_peer_id,
				ReconnectedPlayerProjectionOutcome.RESTORED
			)
		return
	var reconnect_state := (
		_disconnected_player_reconnect_states.get(old_peer_id, {}) as Dictionary
	)
	var embedded_participant_projection := false
	if embedded_runtime:
		embedded_participant_projection = (
			_prepare_embedded_participant_identity_remap(
				old_peer_id,
				new_peer_id
			)
		)
		if not embedded_participant_projection:
			_publish_reconnected_player_projection_outcome(
				old_peer_id,
				new_peer_id,
				ReconnectedPlayerProjectionOutcome.SUSPENDED
			)
			return
		# 后加入的观察客户端没有该玩家的本地断线捕获，只恢复一个远端占位
		# Player；Host 随后的新身份关键帧与可靠背包快照会收敛全部权威字段。
		# Host 缺失 capture 会在统一校验入口进入有界重试，不能在此静默丢通知。
	if not _commit_reconnected_peer_identity(
		old_peer_id,
		new_peer_id,
		membership_revision
	):
		_fail_reconnected_peer_identity(
			old_peer_id,
			new_peer_id,
			"持久身份或跨信道结果无法原子迁移。"
		)
		return
	if embedded_participant_projection:
		_commit_embedded_participant_identity_remap(old_peer_id, new_peer_id)
	_attempt_reconnected_player_projection(
		old_peer_id,
		new_peer_id,
		player_name,
		character_id,
		reconnect_state
	)

## 内嵌 MpGame 只发布组件结果，由外层路线/塔防唯一聚合；顶层 MpGame 才能
## 向 NetManager 提交会话终态。这样多个世界不会各报一个互相冲突的 enum。
func _publish_reconnected_player_projection_outcome(
	old_peer_id: int,
	new_peer_id: int,
	outcome: ReconnectedPlayerProjectionOutcome
) -> void:
	reconnected_player_projection_resolved.emit(old_peer_id, new_peer_id, outcome)
	if embedded_runtime or net_manager == null or not net_manager.is_host():
		return
	if not net_manager.report_reconnected_runtime_projection(
		old_peer_id,
		new_peer_id,
		outcome
	):
		push_error(
			"MpGame: NetManager 拒绝重连 Player 投影终态：%d -> %d outcome=%d。"
			% [old_peer_id, new_peer_id, outcome]
		)


## 身份门失败必须在同一调用栈同步终止，不能只记录错误并让半个成员继续进入游戏。
func _fail_reconnected_peer_identity(
	old_peer_id: int,
	new_peer_id: int,
	reason: String
) -> void:
	push_error("MpGame: 重连身份提交失败：peer=%d reason=%s" % [new_peer_id, reason])
	_publish_reconnected_player_projection_outcome(
		old_peer_id,
		new_peer_id,
		ReconnectedPlayerProjectionOutcome.FAILED
	)
	# 内嵌组件失败由外层聚合器决定是整局 fail-close，还是安全降级为本轮
	# 作战 spectator；组件不得越权终止拥有它的多人会话。
	if embedded_runtime or net_manager == null:
		return
	if not net_manager.terminate_for_runtime_projection_failure(new_peer_id, reason):
		push_error("MpGame: 无法终止身份提交失败的 peer=%d。" % new_peer_id)


func _attempt_reconnected_player_projection(
	old_peer_id: int,
	new_peer_id: int,
	player_name: String,
	character_id: StringName,
	reconnect_state: Dictionary
) -> bool:
	if game == null:
		_remember_pending_reconnected_player_projection(
			old_peer_id,
			new_peer_id,
			player_name,
			character_id,
			CombatRuntimeBase.ReconnectedPlayerProjectionStatus.CREATE_FAILED
		)
		return false
	var captured_player_state := (
		reconnect_state.get("state") as SnapshotManager.PlayerState
	)
	if (
		net_manager.is_host()
		and (
			captured_player_state == null
			or captured_player_state.peer_id != old_peer_id
			or captured_player_state.character_id != character_id
			or not SnapshotManager.is_player_snapshot_state_serializable(
				captured_player_state
			)
		)
	):
		# Host 的断线快照是 Player 瞬时状态唯一来源；结构损坏不会因等待
		# 自动恢复，必须立即 fail-close，不能把永久错误伪装成暂时缺节点。
		_fail_reconnected_peer_identity(
			old_peer_id,
			new_peer_id,
			"断线 Player 快照身份、角色或数值结构无效。"
		)
		return false
	if (
		net_manager.is_host()
		and not player_coordinator.begin_reconnected_transport_lease(
			old_peer_id,
			new_peer_id,
			reconnect_state
		)
	):
		# 输入水位账本是确定性协议数据；缺键/越界不会随场景加载变好。
		_fail_reconnected_peer_identity(
			old_peer_id,
			new_peer_id,
			"断线输入流账本无效。"
		)
		return false
	var player_state := SnapshotManager.copy_player_state(captured_player_state)
	if player_state != null:
		player_state.peer_id = new_peer_id
	var projection := game.ensure_reconnected_multiplayer_player(
		old_peer_id,
		new_peer_id,
		player_name,
		character_id,
		player_state,
		int(reconnect_state.get("spawn_slot_index", 0)),
		reconnect_state
	)
	if not projection.is_success():
		if projection.status == (
			CombatRuntimeBase.ReconnectedPlayerProjectionStatus.CREATE_FAILED
		):
			_remember_pending_reconnected_player_projection(
				old_peer_id,
				new_peer_id,
				player_name,
				character_id,
				projection.status
			)
		else:
			_fail_reconnected_peer_identity(
				old_peer_id,
				new_peer_id,
				"Player 投影发生不可重试冲突，status=%s。"
				% _get_reconnected_player_projection_status_name(projection.status)
			)
		return false
	var player_node := projection.player
	player_coordinator.restore_reconnect_life_state(
		new_peer_id,
		reconnect_state,
		net_manager.is_host()
	)
	merchant_transactions_coordinator.restore_reconnect_state(
		new_peer_id,
		reconnect_state
	)
	if player_state != null:
		var progression_snapshot := (
			run_state.export_player_run_progression(new_peer_id)
		)
		if not player_coordinator.restore_reconnected_player_snapshot(
			player_node,
			player_state,
			progression_snapshot,
			_get_net_time(),
			net_manager.is_host(),
			_get_client_view_local_peer_id(),
			player_coordinator.has_local_tango_prediction()
		):
			_fail_reconnected_peer_identity(
				old_peer_id,
				new_peer_id,
				"断线瞬态无法在当前成长账本之上安全恢复。"
			)
			return false
		if net_manager.is_host():
			player_coordinator.remember_accepted_player_pose(
				new_peer_id,
				player_state.position,
				_get_net_time()
			)
	if (
		net_manager.is_host()
		and bool(reconnect_state.get("rogue_boundary_full_health_pending", false))
		and tower_mode_adapter != null
	):
		tower_mode_adapter.refresh_players_from_run_state_for_rogue_boundary()
		if not player_coordinator.restore_player_to_full_health(new_peer_id):
			push_error(
				"MpGame: 无法为跨过地下探索满血边界的重连玩家 %d 恢复生命。"
				% new_peer_id
			)
	var owned_plant_ids := reconnect_state.get("owned_plant_net_ids", []) as Array
	for plant_net_id_variant in owned_plant_ids:
		var plant := _get_tower_plant(int(plant_net_id_variant))
		if plant != null and is_instance_valid(plant):
			plant.owner_player = player_node
	var fate_presentation_lease_synchronized := false
	if tower_mode_adapter != null:
		tower_mode_adapter.synchronize_reconnected_player_rogue_suspension(
			new_peer_id
		)
		fate_presentation_lease_synchronized = (
			tower_mode_adapter.synchronize_reconnected_player_presentation_lease(
				new_peer_id
			)
		)
	if (
		net_manager.is_host()
		and tower_mode_adapter != null
		and not tower_mode_adapter.is_fate_interlude_active()
		and not fate_presentation_lease_synchronized
		and bool(
			reconnect_state.get("tower_world_spawn_restore_pending", false)
		)
	):
		var tower_spawn_position: Variant = (
			tower_mode_adapter.get_fixed_multiplayer_respawn_position(new_peer_id)
		)
		if not tower_spawn_position is Vector2:
			push_error(
				"MpGame: 无法解析跨幕间重连玩家 %d 的塔防出生点。"
				% new_peer_id
			)
		elif not player_coordinator.handle_authoritative_player_teleport_request(
			new_peer_id,
			tower_spawn_position as Vector2
		):
			push_error(
				"MpGame: 无法将跨幕间重连玩家 %d 权威传送回塔防出生点。"
				% new_peer_id
			)
	if tower_mode_adapter != null:
		var route_migrated := false
		if net_manager.is_host():
			route_migrated = (
				tower_mode_adapter.handle_rogue_exploration_peer_reconnected(
					old_peer_id,
					new_peer_id,
					player_name,
					character_id
				)
			)
		else:
			route_migrated = (
				tower_rogue_route_bridge.migrate_embedded_route_peer_locally(
					old_peer_id,
					new_peer_id,
					player_name,
					character_id,
					net_manager.get_stable_participant_key(new_peer_id)
				)
			)
		if not route_migrated:
			if net_manager.is_host():
				_fail_reconnected_peer_identity(
					old_peer_id,
					new_peer_id,
					"Host 无法迁移地下探索路线身份。"
				)
				return false
			push_warning(
				"MpGame: Client 地下探索玩家 %d -> %d 将由权威快照修复。"
				% [old_peer_id, new_peer_id]
			)
		tower_rogue_route_bridge.migrate_embedded_peer_transport_state(
			old_peer_id,
			new_peer_id
		)
	_pending_reconnected_player_projections.erase(old_peer_id)
	_completed_reconnected_player_projections[old_peer_id] = new_peer_id
	# Player、路线与 completed marker 均已建立，此时认领才不会把 Player-dependent
	# 结果误当成领域拒绝；失败会在 ready 发布前统一 fail-close。
	if not _finalize_reconnected_projection_and_claim(
		old_peer_id,
		new_peer_id,
		ReconnectedPlayerProjectionOutcome.RESTORED
	):
		return false
	return true


func _remember_pending_reconnected_player_projection(
	old_peer_id: int,
	new_peer_id: int,
	player_name: String,
	character_id: StringName,
	projection_status: int
) -> void:
	var pending := (
		_pending_reconnected_player_projections.get(old_peer_id, {}) as Dictionary
	)
	if (
		not pending.is_empty()
		and int(pending.get("new_peer_id", 0)) != new_peer_id
	):
		push_error(
			"MpGame: old peer %d 同时指向两个待恢复身份 %d/%d。"
			% [old_peer_id, int(pending["new_peer_id"]), new_peer_id]
		)
		return
	if pending.is_empty():
		pending = {
			"new_peer_id": new_peer_id,
			"player_name": player_name,
			"character_id": character_id,
			"attempts": 1,
			"elapsed_seconds": 0.0,
			"retry_time_left": PLAYER_PROJECTION_RETRY_INTERVAL_SECONDS,
		}
		push_warning(
			"MpGame: 玩家 %d -> %d 的 Player 投影暂不可用，进入有界重试，status=%s。"
			% [
				old_peer_id,
				new_peer_id,
				_get_reconnected_player_projection_status_name(projection_status),
			]
		)
		if net_manager.is_client() and is_inside_tree():
			# 完整修复与本地投影重试并行：修复补状态，但绝不负责创建 Player。
			_request_peer_result_full_repair()
	pending["last_status"] = projection_status
	_pending_reconnected_player_projections[old_peer_id] = pending


func _update_pending_reconnected_player_projections(delta: float) -> void:
	if _pending_reconnected_player_projections.is_empty():
		return
	var safe_delta := maxf(delta, 0.0)
	var pending_old_peer_ids := (
		_pending_reconnected_player_projections.keys().duplicate()
	)
	for old_peer_id_variant in pending_old_peer_ids:
		var old_peer_id := int(old_peer_id_variant)
		var pending := (
			_pending_reconnected_player_projections.get(old_peer_id, {})
			as Dictionary
		).duplicate(true)
		if pending.is_empty():
			continue
		var new_peer_id := int(pending.get("new_peer_id", 0))
		if int(
			_completed_reconnected_player_projections.get(old_peer_id, 0)
		) == new_peer_id:
			_pending_reconnected_player_projections.erase(old_peer_id)
			continue
		pending["elapsed_seconds"] = (
			float(pending.get("elapsed_seconds", 0.0)) + safe_delta
		)
		pending["retry_time_left"] = (
			float(pending.get("retry_time_left", 0.0)) - safe_delta
		)
		var attempts := int(pending.get("attempts", 1))
		if (
			attempts >= PLAYER_PROJECTION_MAX_ATTEMPTS
			or float(pending["elapsed_seconds"])
			>= PLAYER_PROJECTION_RETRY_TIMEOUT_SECONDS
		):
			_pending_reconnected_player_projections[old_peer_id] = pending
			_exhaust_reconnected_player_projection(old_peer_id)
			continue
		if float(pending["retry_time_left"]) > 0.0:
			_pending_reconnected_player_projections[old_peer_id] = pending
			continue
		pending["attempts"] = attempts + 1
		pending["retry_time_left"] = PLAYER_PROJECTION_RETRY_INTERVAL_SECONDS
		_pending_reconnected_player_projections[old_peer_id] = pending
		_attempt_reconnected_player_projection(
			old_peer_id,
			new_peer_id,
			str(pending.get("player_name", "")),
			StringName(pending.get("character_id", &"")),
			_disconnected_player_reconnect_states.get(old_peer_id, {})
			as Dictionary
		)


func _exhaust_reconnected_player_projection(old_peer_id: int) -> void:
	var pending := (
		_pending_reconnected_player_projections.get(old_peer_id, {}) as Dictionary
	)
	if pending.is_empty():
		return
	_pending_reconnected_player_projections.erase(old_peer_id)
	var new_peer_id := int(pending.get("new_peer_id", 0))
	var attempts := int(pending.get("attempts", 0))
	var status := int(pending.get(
		"last_status",
		CombatRuntimeBase.ReconnectedPlayerProjectionStatus.CREATE_FAILED
	))
	var failure_resolution := (
		"已交由外层路线降级处理"
		if embedded_runtime
		else "会话将终止"
	)
	var reason := (
		"玩家 %d 的战斗运行时投影在 %d 次尝试后仍失败（%s），%s。"
		% [
			new_peer_id,
			attempts,
			_get_reconnected_player_projection_status_name(status),
			failure_resolution,
		]
	)
	push_error("MpGame: %s" % reason)
	_publish_reconnected_player_projection_outcome(
		old_peer_id,
		new_peer_id,
		ReconnectedPlayerProjectionOutcome.FAILED
	)
	# 内嵌投影失败的终态已经交给外层路线协调器；它会把该成员降级为
	# 本轮观战者。子战场不得因自己的可丢弃 Player 投影关闭共享会话。
	if embedded_runtime:
		_disconnected_player_reconnect_states.erase(old_peer_id)
		return
	if net_manager.is_client() and is_inside_tree():
		_request_peer_result_full_repair()
	var termination_started := (
		net_manager != null
		and net_manager.terminate_for_runtime_projection_failure(
			new_peer_id,
			reason
		)
	)
	if termination_started:
		# 终止会话后该捕获不再有合法消费者；正常失败阶段始终保留到这里。
		_disconnected_player_reconnect_states.erase(old_peer_id)
	else:
		push_error(
			"MpGame: 无法终止 Player 投影失败的 peer %d，会话状态需要人工检查。"
			% new_peer_id
		)


func _get_reconnected_player_projection_status_name(status: int) -> StringName:
	match status:
		CombatRuntimeBase.ReconnectedPlayerProjectionStatus.CREATED:
			return &"created"
		CombatRuntimeBase.ReconnectedPlayerProjectionStatus.EXISTING_CURRENT:
			return &"existing_current"
		CombatRuntimeBase.ReconnectedPlayerProjectionStatus.CONFLICT:
			return &"conflict"
		CombatRuntimeBase.ReconnectedPlayerProjectionStatus.CAPTURE_STATE_INVALID:
			return &"capture_state_invalid"
		CombatRuntimeBase.ReconnectedPlayerProjectionStatus.INGRESS_STATE_INVALID:
			return &"ingress_state_invalid"
		CombatRuntimeBase.ReconnectedPlayerProjectionStatus.INVALID_REQUEST:
			return &"invalid_request"
		_:
			return &"create_failed"


func _clear_reconnected_player_projection_state() -> void:
	_pending_reconnected_player_projections.clear()
	_completed_reconnected_player_projections.clear()
	_projecting_embedded_participant_peer_ids.clear()


func _rebase_reconnect_projection_state_for_disconnected_peer(peer_id: int) -> bool:
	var capture_rebased := false
	for completed_old_peer_id_variant in (
		_completed_reconnected_player_projections.keys().duplicate()
	):
		var completed_old_peer_id := int(completed_old_peer_id_variant)
		if (
			completed_old_peer_id == peer_id
			or int(_completed_reconnected_player_projections[completed_old_peer_id])
			== peer_id
		):
			_completed_reconnected_player_projections.erase(completed_old_peer_id)
	for old_peer_id_variant in (
		_pending_reconnected_player_projections.keys().duplicate()
	):
		var old_peer_id := int(old_peer_id_variant)
		var pending := (
			_pending_reconnected_player_projections.get(old_peer_id, {})
			as Dictionary
		)
		if int(pending.get("new_peer_id", 0)) != peer_id:
			continue
		_pending_reconnected_player_projections.erase(old_peer_id)
		if (
			old_peer_id != peer_id
			and _disconnected_player_reconnect_states.has(old_peer_id)
		):
			# new peer 在投影收敛前再次断线时，把唯一捕获向当前认证身份推进；
			# 下一次 new->newer 重连仍能消费它，同时停止已失效的轮询。
			var rebased_capture := (
				_disconnected_player_reconnect_states[old_peer_id]
				as Dictionary
			).duplicate(true)
			var captured_player_state := (
				rebased_capture.get("state") as SnapshotManager.PlayerState
			)
			if captured_player_state != null:
				var rebased_player_state := SnapshotManager.copy_player_state(
					captured_player_state
				)
				rebased_player_state.peer_id = peer_id
				rebased_capture["state"] = rebased_player_state
			_disconnected_player_reconnect_states[peer_id] = rebased_capture
			_disconnected_player_reconnect_states.erase(old_peer_id)
			capture_rebased = true
	return capture_rebased


func _clear_peer_network_state(peer_id: int) -> void:
	# A surge field is world-owned after activation. Keep its compact roster
	# record (and sequence guards) across caster removal until the field's own
	# finished signal retires it.
	player_coordinator.mark_tango_owner_disconnected(peer_id)
	var active_tiyi_activation_id := (
		player_coordinator.get_active_tiyi_high_noon_activation_id(peer_id)
	)
	if active_tiyi_activation_id > 0 and net_manager != null and net_manager.is_host():
		_cancel_authoritative_tiyi_high_noon(peer_id, active_tiyi_activation_id, true)
	if (
		player_coordinator.has_active_tango_charge(peer_id)
		and net_manager != null
		and net_manager.is_host()
	):
		_cancel_authoritative_tango_charge(peer_id, true)
	enemy_coordinator.clear_peer(peer_id)
	player_coordinator.clear_peer(peer_id)
	tower_world_coordinator.clear_peer(peer_id)
	session_coordinator.clear_peer(peer_id)
	transactions_coordinator.clear_peer(peer_id)
	tower_economy_coordinator.clear_peer(peer_id)
	merchant_transactions_coordinator.clear_peer(peer_id)
	tower_fate_coordinator.clear_peer(peer_id)
	collectible_presentation_coordinator.clear_peer(peer_id)
	network_diagnostics_coordinator.clear_peer(peer_id)
	projectile_coordinator.clear_peer(peer_id)


func _return_to_lobby() -> void:
	# 内嵌运行时既不切场景也不断开共享传输。同步/异步准备失败已经通过
	# RuntimePreparationProvider 的失败信号交还给外层作战协调器。
	if embedded_runtime:
		return
	if _lobby_return_in_progress:
		return
	_lobby_return_in_progress = true
	# 初始化失败、远端断线和主动返回都必须经过同一个跨场景清理门。
	if public_room_lease != null:
		await public_room_lease.release_current_and_wait(&"mp_game_return_to_lobby")
	if not is_inside_tree():
		return
	_complete_return_to_lobby()


func _complete_return_to_lobby() -> void:
	if game != null and is_instance_valid(game):
		game.prepare_for_scene_teardown()
	_clear_reconnected_player_projection_state()
	_clear_peer_result_repair_state()
	if peer_ledger_coordinator != null:
		peer_ledger_coordinator.unbind_session(self)
	_peer_ledger_generation = 0
	player_coordinator.reset_session_state()
	enemy_coordinator.reset_session_state()
	projectile_coordinator.reset_session_state()
	world_flow_coordinator.reset_session_state()
	_disconnected_player_reconnect_states.clear()
	_pending_tower_rogue_flow_state.clear()
	collectible_presentation_coordinator.reset_session_state()
	network_diagnostics_coordinator.reset_session_state()
	tower_economy_coordinator.reset_session_state()
	tower_world_coordinator.reset_session_state()
	merchant_transactions_coordinator.reset_session_state()
	tower_fate_coordinator.reset_session_state()
	session_coordinator.reset_session_state()
	transactions_coordinator.reset_session_state()
	var tree: SceneTree = get_tree()
	if tree == null:
		return
	tree.change_scene_to_file("res://scene/multiplayer/multiplayer_lobby.tscn")
