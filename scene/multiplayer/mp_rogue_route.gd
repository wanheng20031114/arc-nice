extends RuntimePreparationProvider
class_name MpRogueRoute

signal embedded_authoritative_snapshot_changed

const _NetConstants := preload("res://scene/multiplayer/net_constants.gd")
const MultiplayerReconnectTypesScript := preload(
	"res://scene/multiplayer/reconnect/multiplayer_reconnect_types.gd"
)
const MULTIPLAYER_LOBBY_SCENE_PATH := (
	"res://scene/multiplayer/multiplayer_lobby.tscn"
)
const STATE_DISCONNECTED := NetManagerStore.ConnectionState.DISCONNECTED
const STATE_LOADING_GAME := NetManagerStore.ConnectionState.LOADING_GAME
const STATE_IN_GAME := NetManagerStore.ConnectionState.IN_GAME
const AVATAR_POSE_FIELD_COUNT := 6
const AVATAR_SNAPSHOT_FIELD_COUNT := 7
const AVATAR_QUANTIZATION_SCALE := 10.0
const AVATAR_MAX_SEQUENCE := 0x7FFFFFFF
const AVATAR_FACING_MIN := 0
const AVATAR_FACING_MAX := 3
const AVATAR_ANIM_STATE_MAX := 15
const AVATAR_INITIAL_POSITION_TOLERANCE := 32.0
const AVATAR_POSITION_TOLERANCE := 8.0
const AVATAR_SPEED_TOLERANCE_MULTIPLIER := 1.75
const AVATAR_VELOCITY_TOLERANCE_MULTIPLIER := 2.5
const AVATAR_MAX_VALIDATION_SECONDS := 0.5
const AVATAR_CORRECTION_INTERVAL_MSEC := 84
const AVATAR_RECONNECT_POSE_RETENTION_MSEC := 90_000
const SNAPSHOT_REQUEST_RETRY_BASE_MSEC := 250
const SNAPSHOT_REQUEST_RETRY_MAX_MSEC := 2_000
const SNAPSHOT_REQUEST_RETRY_MAX_EXPONENT := 3
const ROUTE_REPAIR_RATE_PER_SECOND := 0.5
const ROUTE_REPAIR_RATE_BURST := 2.0
const ROUTE_ENCOUNTER_COMMAND_RATE_PER_SECOND := 4.0
const ROUTE_ENCOUNTER_COMMAND_RATE_BURST := 6.0
const ROUTE_SHOP_COMMAND_RATE_PER_SECOND := 6.0
const ROUTE_SHOP_COMMAND_RATE_BURST := 8.0
const ROUTE_UPGRADE_COMMAND_RATE_PER_SECOND := 6.0
const ROUTE_UPGRADE_COMMAND_RATE_BURST := 8.0
const SHOP_EXIT_ACK_RETRY_MSEC := 500
const BRIEFING_COVER_BARRIER_TIMEOUT_MSEC := 10_000

## 独立 P3 场景保持自动绑定；塔防中的静态桥节点由 MpGame 在正式运行时
## 准备完成后显式绑定，避免它误把自己当成顶层路线场景并切回大厅。
@export var auto_bind_scene_runtime := true

var _route: RogueRouteGame = null
var _combat_coordinator: RogueCombatMultiplayerCoordinator = null
var _net_manager: NetManagerStore = null
var _run_state: RunStateStore = null
var _runtime_prepared := false
var _return_scheduled := false
var _public_return_in_progress := false
var _snapshot_request_pending := false
var _snapshot_request_retry_at_msec := 0
var _snapshot_request_retry_exponent := 0
var _full_snapshot_apply_in_progress := false
var _latest_layout_snapshot: Dictionary = {}
var _latest_state_snapshot: Dictionary = {}
var _latest_encounter_snapshot: Dictionary = {}
var _latest_economy_snapshot: Dictionary = {}
var _latest_shop_snapshot: Dictionary = {}
var _briefing_cover_expected_peers: Dictionary = {}
var _briefing_cover_ready_peers: Dictionary = {}
var _briefing_cover_occurrence_key := ""
var _briefing_cover_revision := -1
var _briefing_cover_expected_route_revision := -1
var _briefing_move_commit_started := false
var _briefing_cover_deadline_msec := 0
var _avatar_sync_time_left := 0.0
var _client_avatar_sequence := 0
var _host_avatar_snapshot_sequence := 0
var _last_host_avatar_snapshot_sequence := 0
var _last_client_avatar_sequences: Dictionary = {}
var _accepted_avatar_positions: Dictionary = {}
var _accepted_avatar_times_msec: Dictionary = {}
var _disconnected_avatar_poses: Dictionary = {}
var _last_avatar_correction_times_msec: Dictionary = {}
var _last_avatar_correction_sequences: Dictionary = {}
var _route_repair_request_rate_buckets: Dictionary = {}
var _route_encounter_command_rate_buckets: Dictionary = {}
var _route_shop_command_rate_buckets: Dictionary = {}
var _route_upgrade_command_rate_buckets: Dictionary = {}
var _pending_shop_exit_ack: Dictionary = {}
var _pending_shop_exit_retry_at_msec := 0
var _embedded_campaign_mode := false
var _embedded_exploration_active := false
var _embedded_rpc_sender_id := 0
var _rpc_transport: Callable = Callable()
var _preparation_generation := 0
var _route_preparation_generation := 0


func _ready() -> void:
	_preparation_generation = begin_runtime_preparation(
		"正在创建多人 Rogue 路线框架…",
		1
	)
	if not auto_bind_scene_runtime:
		return
	update_runtime_preparation_progress(
		_preparation_generation,
		"正在创建多人 Rogue 路线框架…",
		0,
		1
	)
	_route = get_node_or_null("RogueRoute") as RogueRouteGame
	_combat_coordinator = get_node_or_null(
		"RogueCombatCoordinator"
	) as RogueCombatMultiplayerCoordinator
	_net_manager = NetManagerStore.get_autoload_instance()
	_run_state = get_node_or_null("/root/RunState") as RunStateStore
	if (
		_net_manager == null
		or _run_state == null
		or _route == null
		or _combat_coordinator == null
	):
		var reason := "P3 多人运行时契约不完整。"
		push_error("MpRogueRoute: %s" % reason)
		mark_runtime_preparation_failed(_preparation_generation, reason)
		_defer_lobby_return_without_active_loader()
		return
	_combat_coordinator.bind_network_dependencies(
		_route,
		_net_manager,
		_run_state,
		RogueCombatMultiplayerCoordinator.SessionProjectionOwner.THIS_COORDINATOR
	)

	_connect_route_signals()
	set_multiplayer_authority(_get_host_peer_id())
	if not _connect_net_manager_signals():
		mark_runtime_preparation_failed(
			_preparation_generation,
			"P3 多人网络信号契约绑定失败。"
		)
		_defer_lobby_return_without_active_loader()
		return
	if not _configure_route_players():
		var reason := "无法按房间角色表创建 P3 玩家。"
		push_error("MpRogueRoute: %s" % reason)
		mark_runtime_preparation_failed(_preparation_generation, reason)
		_defer_lobby_return_without_active_loader()
		return
	if _is_host():
		_route.set_authority_enabled(true)
		_route_preparation_generation = (
			_route.get_runtime_preparation_generation()
		)
		if not _route.start_authoritative_session(
			_generate_session_seed(),
			false
		):
			var reason := "Host 无法生成 P3 路线。"
			push_error("MpRogueRoute: %s" % reason)
			mark_runtime_preparation_failed(_preparation_generation, reason)
			_defer_lobby_return_without_active_loader()
			return
		_route.mark_runtime_preparation_complete(
			_route_preparation_generation
		)
		_refresh_authoritative_snapshot_cache()
	elif _is_client():
		_reset_snapshot_request_state()
		_route.set_authority_enabled(false)
		_route_preparation_generation = _route.start_client_waiting()
	else:
		var reason := "启动时没有有效多人连接。"
		push_warning("MpRogueRoute: %s" % reason)
		mark_runtime_preparation_failed(_preparation_generation, reason)
		_defer_lobby_return_without_active_loader()
		return

	_runtime_prepared = true
	mark_runtime_preparation_complete(_preparation_generation)
	call_deferred("_report_game_loaded")
	if _get_connection_state() == STATE_IN_GAME:
		call_deferred("_synchronize_after_barrier")


## 复用 P3 已验证的路线运输逻辑，但由塔防 MpGame 根节点承载 wire RPC。
## 路线、作战协调器与桥节点均静态存在；本入口不生成地图、不发放行动力，
## 因而普通塔防全量修复不会重建路线或重复传送玩家。
func bind_embedded_campaign_runtime(
	route_instance: RogueRouteGame,
	combat_coordinator_instance: RogueCombatMultiplayerCoordinator,
	net_manager_instance: NetManagerStore,
	run_state_instance: RunStateStore,
	rpc_transport: Callable
) -> bool:
	if (
		auto_bind_scene_runtime
		or route_instance == null
		or combat_coordinator_instance == null
		or net_manager_instance == null
		or run_state_instance == null
		or not rpc_transport.is_valid()
	):
		return false
	if _runtime_prepared:
		return (
			_route == route_instance
			and _combat_coordinator == combat_coordinator_instance
			and _net_manager == net_manager_instance
			and _run_state == run_state_instance
		)
	_preparation_generation = begin_runtime_preparation(
		"正在绑定塔防内嵌 Rogue 路线框架…",
		1
	)
	_route = route_instance
	_route_preparation_generation = _route.get_runtime_preparation_generation()
	_combat_coordinator = combat_coordinator_instance
	_net_manager = net_manager_instance
	_run_state = run_state_instance
	_rpc_transport = rpc_transport
	_embedded_campaign_mode = true
	_combat_coordinator.bind_network_dependencies(
		_route,
		_net_manager,
		_run_state,
		RogueCombatMultiplayerCoordinator.SessionProjectionOwner.ENCLOSING_RUNTIME
	)
	_connect_route_signals()
	set_multiplayer_authority(_get_host_peer_id())
	_reset_snapshot_request_state()
	_runtime_prepared = true
	mark_runtime_preparation_complete(_preparation_generation)
	return true


func unbind_embedded_campaign_runtime() -> void:
	if not _embedded_campaign_mode:
		return
	_disconnect_route_signals()
	_route = null
	_combat_coordinator = null
	_net_manager = null
	_run_state = null
	_rpc_transport = Callable()
	_embedded_campaign_mode = false
	_embedded_exploration_active = false
	_embedded_rpc_sender_id = 0
	_runtime_prepared = false
	_preparation_generation = begin_runtime_preparation(
		"等待重新绑定多人 Rogue 路线框架…",
		1
	)
	_route_preparation_generation = 0
	_reset_snapshot_request_state()
	_reset_avatar_sync_state()
	_reset_briefing_cover_barrier()


func synchronize_embedded_route() -> void:
	if not _embedded_campaign_mode or not _runtime_prepared or _route == null:
		return
	_route.activate_runtime()
	if (
		_is_host()
		and _embedded_exploration_active
		and _route.is_route_ready()
	):
		embedded_authoritative_snapshot_changed.emit()
	elif _is_client() and _route.is_route_ready():
		_request_full_snapshot()


func set_embedded_exploration_active(active: bool) -> void:
	if not _embedded_campaign_mode:
		return
	_embedded_exploration_active = active
	if not active:
		_reset_snapshot_request_state()
		_pending_shop_exit_ack.clear()
		_pending_shop_exit_retry_at_msec = 0
		_reset_briefing_cover_barrier()
		_route_repair_request_rate_buckets.clear()
		_route_encounter_command_rate_buckets.clear()
		_route_shop_command_rate_buckets.clear()
		_route_upgrade_command_rate_buckets.clear()
		# 离线玩家姿态是跨断线的语义状态，不属于当日 active 运输缓存；
		# 保留到 authenticated reconnect 或既有 TTL 到期。
		_reset_avatar_sync_state(true)


func is_embedded_exploration_active() -> bool:
	return _embedded_campaign_mode and _embedded_exploration_active


func capture_embedded_route_peer_before_removal(peer_id: int) -> void:
	if not _embedded_campaign_mode or peer_id <= 0 or _route == null:
		return
	_prune_disconnected_avatar_poses()
	var preserved_pose := _get_avatar_pose_for_peer(peer_id)
	if not preserved_pose.is_empty():
		preserved_pose["stored_at_msec"] = Time.get_ticks_msec()
		_disconnected_avatar_poses[peer_id] = preserved_pose.duplicate(true)
	clear_embedded_peer_transport_state(peer_id)


func clear_embedded_peer_transport_state(peer_id: int) -> void:
	if not _embedded_campaign_mode or peer_id <= 0:
		return
	_route_repair_request_rate_buckets.erase(peer_id)
	_route_encounter_command_rate_buckets.erase(peer_id)
	_route_shop_command_rate_buckets.erase(peer_id)
	_route_upgrade_command_rate_buckets.erase(peer_id)
	if _is_host() and _briefing_cover_expected_peers.has(peer_id):
		_briefing_cover_expected_peers.erase(peer_id)
		_briefing_cover_ready_peers.erase(peer_id)
		_try_commit_briefed_move_after_cover_barrier()
	_clear_avatar_peer_sync_state(peer_id)


func remove_embedded_route_peer_locally(peer_id: int) -> void:
	if not _embedded_campaign_mode or peer_id <= 0 or _route == null:
		return
	capture_embedded_route_peer_before_removal(peer_id)
	_route.remove_multiplayer_player(peer_id)


func migrate_embedded_route_peer_locally(
	old_peer_id: int,
	new_peer_id: int,
	player_name: String,
	character_id: StringName,
	stable_participant_key: String
) -> bool:
	if (
		not _embedded_campaign_mode
		or _route == null
		or old_peer_id <= 0
		or new_peer_id <= 0
		or old_peer_id == new_peer_id
	):
		return false
	_prune_disconnected_avatar_poses()
	var preserved_pose := (
		_disconnected_avatar_poses.get(old_peer_id, {}) as Dictionary
	)
	var migrated := _route.migrate_multiplayer_player(
		old_peer_id,
		new_peer_id,
		player_name,
		character_id
	)
	if not migrated and _route.get_player_for_peer(new_peer_id) == null:
		var anchor := _route.get_player_for_peer(_get_host_peer_id())
		var spawn_position := (
			_route.clamp_avatar_position(anchor.global_position)
			if anchor != null
			else _route.clamp_avatar_position(Vector2.ZERO)
		)
		migrated = _route.add_multiplayer_player(
			new_peer_id,
			player_name,
			character_id,
			spawn_position
		)
	if not migrated:
		return false
	if not preserved_pose.is_empty():
		_route.apply_avatar_snapshot(
			new_peer_id,
			preserved_pose.get("position", Vector2.ZERO) as Vector2,
			preserved_pose.get("velocity", Vector2.ZERO) as Vector2,
			int(preserved_pose.get("facing", 0)),
			int(preserved_pose.get("anim_state", 0)),
			true
		)
	if (
		not stable_participant_key.is_empty()
		and not _route.set_multiplayer_participant_stable_key(
			new_peer_id,
			stable_participant_key
		)
	):
		return false
	migrate_embedded_peer_transport_state(old_peer_id, new_peer_id)
	return true


func migrate_embedded_peer_transport_state(
	old_peer_id: int,
	new_peer_id: int
) -> void:
	if (
		not _embedded_campaign_mode
		or old_peer_id <= 0
		or new_peer_id <= 0
		or old_peer_id == new_peer_id
	):
		return
	var replace_briefing_peer := (
		_is_host() and _briefing_cover_expected_peers.has(old_peer_id)
	)
	for peer_id in [old_peer_id, new_peer_id]:
		_route_repair_request_rate_buckets.erase(peer_id)
		_route_encounter_command_rate_buckets.erase(peer_id)
		_route_shop_command_rate_buckets.erase(peer_id)
		_route_upgrade_command_rate_buckets.erase(peer_id)
		_briefing_cover_expected_peers.erase(peer_id)
		_briefing_cover_ready_peers.erase(peer_id)
		_clear_avatar_peer_sync_state(peer_id)
	if replace_briefing_peer and not _briefing_move_commit_started:
		_briefing_cover_expected_peers[new_peer_id] = true
	_restore_embedded_disconnected_avatar_pose(old_peer_id, new_peer_id)


func _restore_embedded_disconnected_avatar_pose(
	old_peer_id: int,
	new_peer_id: int
) -> bool:
	if _route == null:
		return false
	_prune_disconnected_avatar_poses()
	var preserved_pose := (
		_disconnected_avatar_poses.get(old_peer_id, {}) as Dictionary
	)
	var player_node := _route.get_player_for_peer(new_peer_id)
	if preserved_pose.is_empty() or player_node == null:
		return false
	var applied := _route.apply_avatar_snapshot(
		new_peer_id,
		preserved_pose.get("position", Vector2.ZERO) as Vector2,
		preserved_pose.get("velocity", Vector2.ZERO) as Vector2,
		int(preserved_pose.get("facing", 0)),
		int(preserved_pose.get("anim_state", 0)),
		true
	)
	if applied:
		_disconnected_avatar_poses.erase(old_peer_id)
	return applied


func send_embedded_full_route_snapshot_to_peer(peer_id: int) -> void:
	if _embedded_campaign_mode:
		_send_full_snapshot_to_peer(peer_id)


func apply_embedded_route_rpc(
	method_name: StringName,
	sender_id: int,
	arguments: Array
) -> Variant:
	if (
		not _embedded_campaign_mode
		or not _runtime_prepared
		or not _embedded_exploration_active
		or sender_id <= 0
		or _embedded_rpc_sender_id > 0
	):
		return false
	if method_name not in [
		&"net_route_encounter_intro_ack",
		&"net_route_encounter_vote",
		&"net_route_encounter_result_ack",
		&"net_route_encounter_snapshot",
		&"net_shop_purchase_request",
		&"net_shop_sell_request",
		&"net_shop_exit_ack",
		&"net_shop_snapshot",
		&"net_route_upgrade_requested",
		&"net_route_avatar_input",
		&"net_route_avatar_snapshot",
		&"net_route_avatar_corrected",
		&"net_request_route_full_snapshot",
		&"net_route_full_snapshot",
		&"net_route_move_delta",
		&"net_route_briefing_state",
		&"net_route_briefing_cover_ready",
	]:
		return false
	_embedded_rpc_sender_id = sender_id
	callv(method_name, arguments)
	_embedded_rpc_sender_id = 0
	return true


func _send_route_rpc(
	peer_id: int,
	method_name: StringName,
	arguments: Array = []
) -> bool:
	if (
		peer_id <= 0
		or (_embedded_campaign_mode and not _embedded_exploration_active)
	):
		return false
	if _rpc_transport.is_valid():
		return bool(_rpc_transport.call(peer_id, method_name, arguments))
	var rpc_arguments: Array = [peer_id, method_name]
	rpc_arguments.append_array(arguments)
	callv(&"rpc_id", rpc_arguments)
	return true


func _get_route_rpc_sender_id() -> int:
	if _embedded_campaign_mode:
		return _embedded_rpc_sender_id
	return multiplayer.get_remote_sender_id()


func _physics_process(delta: float) -> void:
	if (
		not _runtime_prepared
		or (_embedded_campaign_mode and not _embedded_exploration_active)
		or _get_connection_state() != STATE_IN_GAME
		or _route == null
	):
		return
	if _is_host():
		_poll_briefing_cover_timeout()
	if _is_client() and _snapshot_request_pending:
		_retry_full_snapshot_if_due()
	if _is_client() and not _pending_shop_exit_ack.is_empty():
		_retry_pending_shop_exit_ack_if_due()
	if not _route.is_route_ready():
		return
	if _route.is_encounter_active():
		return
	_avatar_sync_time_left -= maxf(delta, 0.0)
	if _avatar_sync_time_left > 0.0:
		return
	_avatar_sync_time_left = _NetConstants.ROGUE_ROUTE_AVATAR_SYNC_INTERVAL_SECONDS
	if _is_host():
		_broadcast_avatar_snapshot()
	elif _is_client():
		_send_local_avatar_pose()


func _exit_tree() -> void:
	_route_repair_request_rate_buckets.clear()
	_route_encounter_command_rate_buckets.clear()
	_route_shop_command_rate_buckets.clear()
	_route_upgrade_command_rate_buckets.clear()
	_pending_shop_exit_ack.clear()
	_pending_shop_exit_retry_at_msec = 0
	_disconnect_net_manager_signals()
	_disconnect_route_signals()


func activate_runtime() -> void:
	if _runtime_prepared and _route != null:
		_route.activate_runtime()


func _defer_lobby_return_without_active_loader() -> void:
	var loader := get_node_or_null("/root/GameLoadCoordinator")
	if loader != null and bool(loader.call("is_loading")):
		return
	call_deferred("_return_to_lobby")


func _connect_route_signals() -> void:
	if not _route.host_layout_committed.is_connected(
		_on_host_layout_committed
	):
		_route.host_layout_committed.connect(_on_host_layout_committed)
	if not _route.host_move_committed.is_connected(_on_host_move_committed):
		_route.host_move_committed.connect(_on_host_move_committed)
	if not _route.host_briefing_state_committed.is_connected(
		_on_host_briefing_state_committed
	):
		_route.host_briefing_state_committed.connect(
			_on_host_briefing_state_committed
		)
	if not _route.briefing_cover_completed.is_connected(
		_on_local_briefing_cover_completed
	):
		_route.briefing_cover_completed.connect(
			_on_local_briefing_cover_completed
		)
	if not _route.host_encounter_snapshot_committed.is_connected(
		_on_host_encounter_snapshot_committed
	):
		_route.host_encounter_snapshot_committed.connect(
			_on_host_encounter_snapshot_committed
		)
	if not _route.encounter_intro_ack_requested.is_connected(
		_on_local_encounter_intro_ack_requested
	):
		_route.encounter_intro_ack_requested.connect(
			_on_local_encounter_intro_ack_requested
		)
	if not _route.encounter_vote_requested.is_connected(
		_on_local_encounter_vote_requested
	):
		_route.encounter_vote_requested.connect(
			_on_local_encounter_vote_requested
		)
	if not _route.encounter_result_ack_requested.is_connected(
		_on_local_encounter_result_ack_requested
	):
		_route.encounter_result_ack_requested.connect(
			_on_local_encounter_result_ack_requested
		)
	if not _route.host_shop_snapshot_committed.is_connected(
		_on_host_shop_snapshot_committed
	):
		_route.host_shop_snapshot_committed.connect(
			_on_host_shop_snapshot_committed
		)
	if not _route.shop_purchase_requested.is_connected(
		_on_local_shop_purchase_requested
	):
		_route.shop_purchase_requested.connect(
			_on_local_shop_purchase_requested
		)
	if not _route.shop_sell_requested.is_connected(
		_on_local_shop_sell_requested
	):
		_route.shop_sell_requested.connect(_on_local_shop_sell_requested)
	if not _route.shop_exit_ack_requested.is_connected(
		_on_local_shop_exit_ack_requested
	):
		_route.shop_exit_ack_requested.connect(
			_on_local_shop_exit_ack_requested
		)
	if not _route.player_upgrade_requested.is_connected(
		_on_local_player_upgrade_requested
	):
		_route.player_upgrade_requested.connect(
			_on_local_player_upgrade_requested
		)
	if not _route.return_requested.is_connected(_on_return_requested):
		_route.return_requested.connect(_on_return_requested)


func _disconnect_route_signals() -> void:
	if _route == null or not is_instance_valid(_route):
		return
	if _route.host_layout_committed.is_connected(_on_host_layout_committed):
		_route.host_layout_committed.disconnect(_on_host_layout_committed)
	if _route.host_move_committed.is_connected(_on_host_move_committed):
		_route.host_move_committed.disconnect(_on_host_move_committed)
	if _route.host_briefing_state_committed.is_connected(
		_on_host_briefing_state_committed
	):
		_route.host_briefing_state_committed.disconnect(
			_on_host_briefing_state_committed
		)
	if _route.briefing_cover_completed.is_connected(
		_on_local_briefing_cover_completed
	):
		_route.briefing_cover_completed.disconnect(
			_on_local_briefing_cover_completed
		)
	if _route.host_encounter_snapshot_committed.is_connected(
		_on_host_encounter_snapshot_committed
	):
		_route.host_encounter_snapshot_committed.disconnect(
			_on_host_encounter_snapshot_committed
		)
	if _route.encounter_intro_ack_requested.is_connected(
		_on_local_encounter_intro_ack_requested
	):
		_route.encounter_intro_ack_requested.disconnect(
			_on_local_encounter_intro_ack_requested
		)
	if _route.encounter_vote_requested.is_connected(
		_on_local_encounter_vote_requested
	):
		_route.encounter_vote_requested.disconnect(
			_on_local_encounter_vote_requested
		)
	if _route.encounter_result_ack_requested.is_connected(
		_on_local_encounter_result_ack_requested
	):
		_route.encounter_result_ack_requested.disconnect(
			_on_local_encounter_result_ack_requested
		)
	if _route.host_shop_snapshot_committed.is_connected(
		_on_host_shop_snapshot_committed
	):
		_route.host_shop_snapshot_committed.disconnect(
			_on_host_shop_snapshot_committed
		)
	if _route.shop_purchase_requested.is_connected(
		_on_local_shop_purchase_requested
	):
		_route.shop_purchase_requested.disconnect(
			_on_local_shop_purchase_requested
		)
	if _route.shop_sell_requested.is_connected(
		_on_local_shop_sell_requested
	):
		_route.shop_sell_requested.disconnect(_on_local_shop_sell_requested)
	if _route.shop_exit_ack_requested.is_connected(
		_on_local_shop_exit_ack_requested
	):
		_route.shop_exit_ack_requested.disconnect(
			_on_local_shop_exit_ack_requested
		)
	if _route.player_upgrade_requested.is_connected(
		_on_local_player_upgrade_requested
	):
		_route.player_upgrade_requested.disconnect(
			_on_local_player_upgrade_requested
		)
	if _route.return_requested.is_connected(_on_return_requested):
		_route.return_requested.disconnect(_on_return_requested)


func _connect_net_manager_signals() -> bool:
	if not _net_manager.register_reconnect_delivery_preparer(
		prepare_reconnected_member_delivery
	):
		push_error("MpRogueRoute: 无法取得顶层重连首帧准备能力。")
		# 启动失败只能由 _ready 发布 generation-scoped FAILED；加载器随后统一收口。
		return false
	if not _net_manager.connection_state_changed.is_connected(
		_on_connection_state_changed
	):
		_net_manager.connection_state_changed.connect(_on_connection_state_changed)
	if not _net_manager.player_reconnected.is_connected(_on_player_reconnected):
		_net_manager.player_reconnected.connect(_on_player_reconnected)
	if not _net_manager.player_left.is_connected(_on_player_left):
		_net_manager.player_left.connect(_on_player_left)
	if not _net_manager.player_joined.is_connected(_on_player_joined):
		_net_manager.player_joined.connect(_on_player_joined)
	if not _net_manager.session_membership_changed.is_connected(
		_on_session_membership_changed
	):
		_net_manager.session_membership_changed.connect(
			_on_session_membership_changed
		)
	if not _net_manager.session_member_final_departed.is_connected(
		_on_session_member_final_departed
	):
		_net_manager.session_member_final_departed.connect(
			_on_session_member_final_departed
		)
	return true


func _disconnect_net_manager_signals() -> void:
	if _net_manager == null or not is_instance_valid(_net_manager):
		return
	_net_manager.unregister_reconnect_delivery_preparer(
		prepare_reconnected_member_delivery
	)
	if _net_manager.connection_state_changed.is_connected(
		_on_connection_state_changed
	):
		_net_manager.connection_state_changed.disconnect(
			_on_connection_state_changed
		)
	if _net_manager.player_reconnected.is_connected(_on_player_reconnected):
		_net_manager.player_reconnected.disconnect(_on_player_reconnected)
	if _net_manager.player_left.is_connected(_on_player_left):
		_net_manager.player_left.disconnect(_on_player_left)
	if _net_manager.player_joined.is_connected(_on_player_joined):
		_net_manager.player_joined.disconnect(_on_player_joined)
	if _net_manager.session_membership_changed.is_connected(
		_on_session_membership_changed
	):
		_net_manager.session_membership_changed.disconnect(
			_on_session_membership_changed
		)
	if _net_manager.session_member_final_departed.is_connected(
		_on_session_member_final_departed
	):
		_net_manager.session_member_final_departed.disconnect(
			_on_session_member_final_departed
		)


func _report_game_loaded() -> void:
	if (
		_runtime_prepared
		and is_inside_tree()
		and _get_connection_state() == STATE_LOADING_GAME
	):
		_net_manager.report_game_loaded()


func _synchronize_after_barrier() -> void:
	# 只提出激活请求；路线场景会等全局加载遮罩真正退场后再播放
	# 入场动画。客户端尚未收到布局时，请求会保留到首个有效快照。
	_route.activate_runtime()
	if _is_host():
		_broadcast_full_snapshot()
	elif _is_client():
		_request_full_snapshot()


func _on_connection_state_changed(new_state: int) -> void:
	if new_state == STATE_DISCONNECTED:
		_return_to_lobby()
	elif new_state == STATE_IN_GAME:
		_synchronize_after_barrier()


func _on_session_membership_changed(
	_peer_ids: PackedInt32Array,
	membership_revision: int
) -> void:
	if membership_revision <= 0:
		return
	if _reconcile_run_state_to_session_membership():
		return
	_fail_session_membership_projection(
		"路线无法原子收敛会话成员 revision=%d。" % membership_revision
	)


func _on_session_member_final_departed(
	peer_id: int,
	_membership_revision: int,
	_reason: StringName
) -> void:
	if peer_id <= 0:
		return
	# player_left 只撤销路线 Player，并保留姿态供宽限重连；final departure
	# 才终结该身份的持久账本和姿态捕获。reconcile 使用 NetManager 当前完整
	# 成员集，避免再次把 transport connected_players 当作会话成员真源。
	if not _reconcile_run_state_to_session_membership():
		_fail_session_membership_projection(
			"路线无法清理最终离场成员 %d 的持久账本。" % peer_id
		)
		return
	_disconnected_avatar_poses.erase(peer_id)
	_clear_avatar_peer_sync_state(peer_id)


func _reconcile_run_state_to_session_membership() -> bool:
	if _run_state == null or _net_manager == null or not _run_state.run_started:
		return false
	return _run_state.reconcile_multiplayer_session_membership(
		_net_manager.get_session_member_peer_ids(),
		_net_manager.get_session_membership_revision()
	)


func _fail_session_membership_projection(reason: String) -> void:
	push_error("MpRogueRoute: %s" % reason)
	if _net_manager == null:
		return
	if not _net_manager.terminate_for_session_membership_projection_failure(reason):
		push_error("MpRogueRoute: 无法终止成员账本已经分叉的多人会话。")


func _on_player_reconnected(
	old_peer_id: int,
	new_peer_id: int,
	player_name: String,
	character_id: StringName,
	membership_revision: int
) -> void:
	# NetManager 会在该信号返回后继续发布 roster/ready；路线身份门必须同步
	# 完成，失败也必须同步终止，不能用 deferred 猜测多个监听者的执行顺序。
	if not _finish_player_reconnect(
		old_peer_id,
		new_peer_id,
		player_name,
		character_id,
		membership_revision
	):
		_fail_reconnected_route_identity(
			new_peer_id,
			"路线持久身份或玩家投影无法原子迁移。"
		)


## P3 顶层路线在 NetManager PREPARING_DELIVERY 内同步补发完整路线与当前
## 作战 prepare。任何一步失败都在 ACTIVE/host-ready 发布前终止该成员。
func prepare_reconnected_member_delivery(
	old_peer_id: int,
	new_peer_id: int,
	outcome: MultiplayerReconnectTypesScript.RuntimeProjectionOutcome,
	_membership_revision: int
) -> bool:
	if (
		not _is_host()
		or new_peer_id <= 0
		or _net_manager == null
		or not _net_manager.is_reconnect_delivery_preparing(new_peer_id)
		or _combat_coordinator == null
		or not is_instance_valid(_combat_coordinator)
	):
		return false
	if not _send_full_snapshot_to_peer(new_peer_id, true):
		return false
	return _combat_coordinator.handle_reconnected_member_ready(
		old_peer_id,
		new_peer_id,
		outcome
	)


func _finish_player_reconnect(
	old_peer_id: int,
	new_peer_id: int,
	player_name: String,
	character_id: StringName,
	membership_revision: int
) -> bool:
	if (
		not is_inside_tree()
		or _net_manager == null
		or _route == null
		or _run_state == null
		or membership_revision <= 0
		or _net_manager.get_session_membership_revision() != membership_revision
		or (
			not _net_manager.is_session_member_active(new_peer_id)
			and not _net_manager.is_session_member_reconnecting(new_peer_id)
		)
	):
		return false
	var stable_participant_key := _net_manager.get_stable_participant_key(
		new_peer_id
	)
	if _is_host() and stable_participant_key.is_empty():
		push_error(
			"MpRogueRoute: 重连玩家 %d 缺少已认证的稳定参与者身份。"
			% new_peer_id
		)
		return false
	_prune_disconnected_avatar_poses()
	var preserved_pose := _get_avatar_pose_for_peer(old_peer_id)
	if preserved_pose.is_empty():
		preserved_pose = (
			_disconnected_avatar_poses.get(old_peer_id, {}) as Dictionary
		).duplicate(true)
	var fallback_position := _get_reconnect_avatar_fallback_position()
	if not preserved_pose.is_empty():
		fallback_position = _route.clamp_avatar_position(
			preserved_pose.get("position", fallback_position) as Vector2
		)
	var route_preparation := (
		_route.prepare_reconnected_multiplayer_player_identity(
			old_peer_id,
			new_peer_id,
			player_name,
			character_id,
			stable_participant_key,
			fallback_position
		)
	)
	var route_preparation_result := int(route_preparation.get(
		"result",
		RogueRouteGame.ReconnectedPlayerIdentityProjectionResult.INVALID
	))
	if route_preparation_result not in [
		RogueRouteGame.ReconnectedPlayerIdentityProjectionResult.READY,
		RogueRouteGame.ReconnectedPlayerIdentityProjectionResult.ALREADY_CURRENT,
	]:
		_route.discard_reconnected_multiplayer_player_identity(route_preparation)
		return false
	var run_state_preparation := _run_state.prepare_multiplayer_peer_state_remap(
		old_peer_id,
		new_peer_id,
		membership_revision
	)
	if run_state_preparation not in [
		RunStateStore.MultiplayerPeerRemapResult.MIGRATED,
		RunStateStore.MultiplayerPeerRemapResult.ALREADY_CURRENT,
	]:
		_route.discard_reconnected_multiplayer_player_identity(route_preparation)
		push_error(
			"MpRogueRoute: 重连玩家 %d -> %d 的 RunState 预检失败，result=%d。"
			% [old_peer_id, new_peer_id, run_state_preparation]
		)
		return false
	if (
		route_preparation_result
		== RogueRouteGame.ReconnectedPlayerIdentityProjectionResult.ALREADY_CURRENT
		and run_state_preparation
		!= RunStateStore.MultiplayerPeerRemapResult.ALREADY_CURRENT
	):
		# 路线已是 new、持久账本仍是 old 不是可靠重放，而是此前留下的半事务。
		return false
	if route_preparation_result == (
		RogueRouteGame.ReconnectedPlayerIdentityProjectionResult.READY
	):
		var route_commit_result := (
			_route.commit_reconnected_multiplayer_player_identity(
				route_preparation
			)
		)
		if route_commit_result != (
			RogueRouteGame.ReconnectedPlayerIdentityProjectionResult.MIGRATED
		):
			_route.discard_reconnected_multiplayer_player_identity(
				route_preparation
			)
			push_error(
				"MpRogueRoute: 路线身份在提交前已改变，result=%d。"
				% route_commit_result
			)
			return false
	var remap_result := _run_state.remap_multiplayer_peer_state(
		old_peer_id,
		new_peer_id,
		membership_revision
	)
	if remap_result != run_state_preparation:
		# route commit 不读取或写入 RunState，且中间没有 await/信号发布；
		# 因而纯预检与正式提交结果必须相同，否则属于内部事务违约。
		push_error(
			"MpRogueRoute: RunState 预检/提交结果漂移：prepared=%d committed=%d。"
			% [run_state_preparation, remap_result]
		)
		return false
	if route_preparation_result == (
		RogueRouteGame.ReconnectedPlayerIdentityProjectionResult.READY
	):
		_route.finalize_reconnected_multiplayer_player_identity(
			route_preparation
		)
	if not preserved_pose.is_empty():
		if not _route.apply_avatar_snapshot(
			new_peer_id,
			preserved_pose.get("position", fallback_position) as Vector2,
			preserved_pose.get("velocity", Vector2.ZERO) as Vector2,
			int(preserved_pose.get("facing", 0)),
			int(preserved_pose.get("anim_state", 0)),
			true
		):
			push_warning(
				"MpRogueRoute: 身份已提交，但玩家 %d 的保留姿态无效，将由权威快照修复。"
				% new_peer_id
			)
	_disconnected_avatar_poses.erase(old_peer_id)
	_clear_avatar_peer_sync_state(old_peer_id)
	_clear_avatar_peer_sync_state(new_peer_id)
	if _is_host():
		_route_repair_request_rate_buckets.erase(old_peer_id)
		_route_repair_request_rate_buckets.erase(new_peer_id)
		_route_encounter_command_rate_buckets.erase(old_peer_id)
		_route_encounter_command_rate_buckets.erase(new_peer_id)
		_route_shop_command_rate_buckets.erase(old_peer_id)
		_route_shop_command_rate_buckets.erase(new_peer_id)
		_route_upgrade_command_rate_buckets.erase(old_peer_id)
		_route_upgrade_command_rate_buckets.erase(new_peer_id)
		_route.host_migrate_encounter_peer(old_peer_id, new_peer_id)
		_route.host_migrate_shop_peer_as_exited(old_peer_id, new_peer_id)
		if _briefing_cover_expected_peers.has(old_peer_id):
			_briefing_cover_expected_peers.erase(old_peer_id)
			_briefing_cover_ready_peers.erase(old_peer_id)
			if not _briefing_move_commit_started:
				_briefing_cover_expected_peers[new_peer_id] = true
	var runtime_projection_outcome := (
		MultiplayerReconnectTypesScript.RuntimeProjectionOutcome.RESTORED
	)
	var waits_for_embedded_projection := false
	if _combat_coordinator != null and is_instance_valid(_combat_coordinator):
		waits_for_embedded_projection = (
			_combat_coordinator.reconnect_requires_embedded_player_projection(
				old_peer_id
			)
		)
		if not _combat_coordinator.handle_reconnected_identity_committed(
			old_peer_id,
			new_peer_id
		):
			return false
		runtime_projection_outcome = (
			MultiplayerReconnectTypesScript.RuntimeProjectionOutcome.SUSPENDED
		)
	if (
		_is_host()
		and not waits_for_embedded_projection
		and not _net_manager.report_reconnected_runtime_projection(
			old_peer_id,
			new_peer_id,
			runtime_projection_outcome
		)
	):
		return false
	return true


func _fail_reconnected_route_identity(new_peer_id: int, reason: String) -> void:
	push_error(
		"MpRogueRoute: 重连身份提交失败：peer=%d reason=%s"
		% [new_peer_id, reason]
	)
	if _net_manager == null:
		return
	if not _net_manager.terminate_for_runtime_projection_failure(new_peer_id, reason):
		push_error("MpRogueRoute: 无法终止身份失败的 peer=%d。" % new_peer_id)


func _get_reconnect_avatar_fallback_position() -> Vector2:
	if _route == null:
		return Vector2.ZERO
	for candidate_peer_id in [_get_host_peer_id(), _get_local_peer_id()]:
		var candidate := _route.get_player_for_peer(candidate_peer_id)
		if candidate != null and is_instance_valid(candidate):
			return _route.clamp_avatar_position(candidate.global_position)
	return _route.clamp_avatar_position(Vector2.ZERO)


func _on_player_left(peer_id: int) -> void:
	_route_repair_request_rate_buckets.erase(peer_id)
	_route_encounter_command_rate_buckets.erase(peer_id)
	_route_shop_command_rate_buckets.erase(peer_id)
	_route_upgrade_command_rate_buckets.erase(peer_id)
	if _is_host() and _briefing_cover_expected_peers.has(peer_id):
		_briefing_cover_expected_peers.erase(peer_id)
		_briefing_cover_ready_peers.erase(peer_id)
		_try_commit_briefed_move_after_cover_barrier()
	if _route != null:
		if _is_host():
			_route.host_remove_encounter_peer(peer_id)
			_route.host_remove_shop_peer(peer_id)
		_prune_disconnected_avatar_poses()
		var preserved_pose := _get_avatar_pose_for_peer(peer_id)
		var retains_session_membership := (
			_net_manager != null and _net_manager.has_session_member(peer_id)
		)
		if retains_session_membership and not preserved_pose.is_empty():
			preserved_pose["stored_at_msec"] = Time.get_ticks_msec()
			_disconnected_avatar_poses[peer_id] = preserved_pose.duplicate(true)
		_route.remove_multiplayer_player(peer_id)
	_clear_avatar_peer_sync_state(peer_id)


func _on_player_joined(peer_id: int, player_name: String) -> void:
	if (
		not _runtime_prepared
		or _route == null
		or peer_id <= 0
		or _route.get_player_for_peer(peer_id) != null
	):
		return
	var character_id := PlayerCharacterRegistry.DEFAULT_CHARACTER_ID
	var stable_participant_key := _net_manager.get_stable_participant_key(peer_id)
	if _is_host() and stable_participant_key.is_empty():
		push_error(
			"MpRogueRoute: 新加入玩家 %d 缺少已认证的稳定参与者身份。"
			% peer_id
		)
		return
	var character_ids := _net_manager.get_player_character_map()
	character_id = StringName(
		character_ids.get(peer_id, character_id)
	)
	var anchor := _route.get_player_for_peer(_get_host_peer_id())
	var spawn_position := (
		anchor.global_position
		if anchor != null
		else Vector2.ZERO
	)
	# player_joined 只代表 transport ACTIVE；持久成员统一从 NetManager
	# 会话 revision 收敛，禁止路线节点自行创建第二套成员真源。
	if not _reconcile_run_state_to_session_membership():
		_fail_session_membership_projection(
			"路线无法收敛新加入玩家 %d 的持久账本。" % peer_id
		)
		return
	if not _route.add_multiplayer_player(
		peer_id,
		player_name,
		character_id,
		spawn_position
	):
		return
	if not stable_participant_key.is_empty():
		if not _route.set_multiplayer_participant_stable_key(
			peer_id,
			stable_participant_key
		):
			push_error(
				"MpRogueRoute: 无法记录新加入玩家 %d 的稳定参与者身份。"
				% peer_id
			)
			return
	if _is_host():
		_route.host_add_encounter_spectator(peer_id)
		_route.host_add_shop_spectator(peer_id)
		if (
			not _briefing_move_commit_started
			and not _briefing_cover_occurrence_key.is_empty()
			and _is_peer_send_ready(peer_id)
		):
			_briefing_cover_expected_peers[peer_id] = true
		_send_full_snapshot_to_peer(peer_id)


func _on_host_layout_committed(layout: Dictionary, state: Dictionary) -> void:
	if not _is_host() or layout.is_empty() or state.is_empty():
		return
	_reset_briefing_cover_barrier()
	_reset_avatar_validation_positions()
	_latest_layout_snapshot = layout.duplicate(true)
	_latest_state_snapshot = state.duplicate(true)
	if _embedded_campaign_mode:
		# Route creation happens before the coordinator atomically flips the
		# embedded session active. Never publish the half-entered active=false/day=N
		# coordinator snapshot; the coordinator's formal active snapshot owns entry.
		if _embedded_exploration_active:
			embedded_authoritative_snapshot_changed.emit()
		return
	if _get_connection_state() == STATE_IN_GAME:
		_broadcast_full_snapshot()


func _on_host_move_committed(delta: Dictionary) -> void:
	if not _is_host() or delta.is_empty():
		return
	_refresh_authoritative_state_cache()
	_reset_avatar_validation_positions()
	if _get_connection_state() != STATE_IN_GAME or not _has_network_peer():
		return
	for peer_id in _get_remote_player_peer_ids():
		if _is_peer_send_ready(peer_id):
			_send_route_rpc(
				peer_id,
				&"net_route_move_delta",
				[delta.duplicate(true)]
			)


func _on_host_briefing_state_committed(snapshot: Dictionary) -> void:
	if not _is_host() or snapshot.is_empty():
		return
	_configure_briefing_cover_barrier(snapshot)
	_refresh_authoritative_state_cache()
	if _get_connection_state() != STATE_IN_GAME or not _has_network_peer():
		return
	for peer_id in _get_remote_player_peer_ids():
		if _is_peer_send_ready(peer_id):
			_send_route_rpc(
				peer_id,
				&"net_route_briefing_state",
				[snapshot.duplicate(true)]
			)


func _configure_briefing_cover_barrier(snapshot: Dictionary) -> void:
	_reset_briefing_cover_barrier()
	if (
		int(snapshot.get("phase", -1))
		!= RogueRouteGame.BriefingPhase.ENTERING
	):
		return
	_briefing_cover_occurrence_key = str(
		snapshot.get("occurrence_key", "")
	)
	_briefing_cover_revision = int(snapshot.get("revision", -1))
	_briefing_cover_expected_route_revision = int(
		snapshot.get("expected_route_revision", -1)
	)
	var local_peer_id := _get_local_peer_id()
	if local_peer_id > 0:
		_briefing_cover_expected_peers[local_peer_id] = true
	for peer_id in _get_remote_player_peer_ids():
		if _is_peer_send_ready(peer_id):
			_briefing_cover_expected_peers[peer_id] = true
	if _is_host() and not _briefing_cover_occurrence_key.is_empty():
		_briefing_cover_deadline_msec = (
			Time.get_ticks_msec() + BRIEFING_COVER_BARRIER_TIMEOUT_MSEC
		)


func _reset_briefing_cover_barrier() -> void:
	_briefing_cover_expected_peers.clear()
	_briefing_cover_ready_peers.clear()
	_briefing_cover_occurrence_key = ""
	_briefing_cover_revision = -1
	_briefing_cover_expected_route_revision = -1
	_briefing_move_commit_started = false
	_briefing_cover_deadline_msec = 0


func _poll_briefing_cover_timeout(now_msec: int = -1) -> bool:
	var now := Time.get_ticks_msec() if now_msec < 0 else now_msec
	if (
		not _is_host()
		or _briefing_move_commit_started
		or _briefing_cover_occurrence_key.is_empty()
		or _briefing_cover_deadline_msec <= 0
		or now < _briefing_cover_deadline_msec
	):
		return false
	var occurrence_key := _briefing_cover_occurrence_key
	_briefing_cover_deadline_msec = 0
	_route.abort_briefing_entry(occurrence_key)
	return true


func _on_local_briefing_cover_completed(
	occurrence_key: String,
	briefing_revision: int,
	expected_route_revision: int
) -> void:
	var local_peer_id := _get_local_peer_id()
	if _is_host():
		_accept_briefing_cover_ready(
			local_peer_id,
			occurrence_key,
			briefing_revision,
			expected_route_revision
		)
		return
	if (
		_is_client()
		and local_peer_id > 0
		and _is_peer_send_ready(_get_host_peer_id())
	):
		_send_route_rpc(
			_get_host_peer_id(),
			&"net_route_briefing_cover_ready",
			[
				occurrence_key,
				briefing_revision,
				expected_route_revision,
			]
		)


func _accept_briefing_cover_ready(
	peer_id: int,
	occurrence_key: String,
	briefing_revision: int,
	expected_route_revision: int
) -> bool:
	if (
		not _is_host()
		or _briefing_move_commit_started
		or peer_id <= 0
		or not _briefing_cover_expected_peers.has(peer_id)
		or _briefing_cover_ready_peers.has(peer_id)
		or occurrence_key != _briefing_cover_occurrence_key
		or briefing_revision != _briefing_cover_revision
		or expected_route_revision
		!= _briefing_cover_expected_route_revision
	):
		return false
	_briefing_cover_ready_peers[peer_id] = true
	_try_commit_briefed_move_after_cover_barrier()
	return true


func _try_commit_briefed_move_after_cover_barrier() -> void:
	if (
		not _is_host()
		or _briefing_move_commit_started
		or _briefing_cover_expected_peers.is_empty()
	):
		return
	for peer_id_variant in _briefing_cover_expected_peers.keys():
		if not _briefing_cover_ready_peers.has(int(peer_id_variant)):
			return
	_briefing_move_commit_started = true
	if not _route.host_commit_briefing_entry(
		_briefing_cover_occurrence_key,
		_briefing_cover_revision,
		_briefing_cover_expected_route_revision
	):
		# 路线会自行恢复已过期或被拒绝的进入状态；保持锁定可防止重复 ready
		# 在恢复协程完成前再次尝试提交。
		return


func _on_host_encounter_snapshot_committed(
	encounter_snapshot: Dictionary,
	economy_snapshot: Dictionary
) -> void:
	if (
		not _is_host()
		or encounter_snapshot.is_empty()
		or economy_snapshot.is_empty()
	):
		return
	var previous_action_points_revision := int(
		_latest_state_snapshot.get("action_points_revision", -1)
	)
	_refresh_authoritative_state_cache()
	_latest_encounter_snapshot = encounter_snapshot.duplicate(true)
	_latest_economy_snapshot = economy_snapshot.duplicate(true)
	if (
		_embedded_campaign_mode
		and _embedded_exploration_active
		and int(_latest_state_snapshot.get("action_points_revision", -1))
		!= previous_action_points_revision
	):
		embedded_authoritative_snapshot_changed.emit()
		return
	if _get_connection_state() != STATE_IN_GAME or not _has_network_peer():
		return
	for peer_id in _get_remote_player_peer_ids():
		if _is_peer_send_ready(peer_id):
			_send_encounter_snapshot_to_peer(peer_id)


func _on_local_encounter_intro_ack_requested(
	occurrence_key: String,
	expected_revision: int
) -> void:
	var local_peer_id := _get_local_peer_id()
	if _is_host():
		_route.host_submit_encounter_intro_ack(
			local_peer_id,
			occurrence_key,
			expected_revision
		)
	elif _is_client() and _has_network_peer():
		var host_peer_id := _get_host_peer_id()
		if host_peer_id > 0 and _is_peer_send_ready(host_peer_id):
			_send_route_rpc(
				host_peer_id,
				&"net_route_encounter_intro_ack",
				[occurrence_key, expected_revision]
			)


func _on_local_encounter_vote_requested(
	occurrence_key: String,
	expected_revision: int,
	option_id: StringName
) -> void:
	var local_peer_id := _get_local_peer_id()
	if _is_host():
		_route.host_submit_encounter_vote(
			local_peer_id,
			occurrence_key,
			expected_revision,
			option_id
		)
	elif _is_client() and _has_network_peer():
		var host_peer_id := _get_host_peer_id()
		if host_peer_id > 0 and _is_peer_send_ready(host_peer_id):
			_send_route_rpc(
				host_peer_id,
				&"net_route_encounter_vote",
				[occurrence_key, expected_revision, option_id]
			)


func _on_local_encounter_result_ack_requested(
	occurrence_key: String,
	result_sequence: int
) -> void:
	var local_peer_id := _get_local_peer_id()
	if _is_host():
		_route.host_submit_encounter_result_ack(
			local_peer_id,
			occurrence_key,
			result_sequence
		)
	elif _is_client() and _has_network_peer():
		var host_peer_id := _get_host_peer_id()
		if host_peer_id > 0 and _is_peer_send_ready(host_peer_id):
			_send_route_rpc(
				host_peer_id,
				&"net_route_encounter_result_ack",
				[occurrence_key, result_sequence]
			)


func _on_host_shop_snapshot_committed(
	target_peer_id: int,
	shop_snapshot: Dictionary
) -> void:
	if not _is_host() or target_peer_id <= 0 or shop_snapshot.is_empty():
		return
	if target_peer_id == _get_local_peer_id():
		_latest_shop_snapshot = shop_snapshot.duplicate(true)
		return
	if (
		_get_connection_state() == STATE_IN_GAME
		and _has_network_peer()
		and _is_peer_send_ready(target_peer_id)
	):
		_send_route_rpc(
			target_peer_id,
			&"net_shop_snapshot",
			[shop_snapshot.duplicate(true)]
		)


func _on_local_shop_purchase_requested(
	request_id: String,
	occurrence_key: String,
	offer_index: int,
	expected_session_revision: int,
	expected_shelf_revision: int,
	expected_inventory_revision: int,
	expected_xirang_revision: int
) -> void:
	if _route == null:
		return
	var local_peer_id := _get_local_peer_id()
	if _is_host():
		_route.host_submit_shop_purchase(
			local_peer_id,
			request_id,
			occurrence_key,
			offer_index,
			expected_session_revision,
			expected_shelf_revision,
			expected_inventory_revision,
			expected_xirang_revision
		)
		return
	if not _is_client() or not _has_network_peer():
		return
	var host_peer_id := _get_host_peer_id()
	if host_peer_id <= 0 or not _is_peer_send_ready(host_peer_id):
		return
	_send_route_rpc(
		host_peer_id,
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


func _on_local_shop_sell_requested(
	request_id: String,
	occurrence_key: String,
	slot_index: int,
	expected_config_path: String,
	expected_session_revision: int,
	expected_inventory_revision: int,
	expected_xirang_revision: int
) -> void:
	if _route == null:
		return
	var local_peer_id := _get_local_peer_id()
	if _is_host():
		_route.host_submit_shop_sell(
			local_peer_id,
			request_id,
			occurrence_key,
			slot_index,
			expected_config_path,
			expected_session_revision,
			expected_inventory_revision,
			expected_xirang_revision
		)
		return
	if not _is_client() or not _has_network_peer():
		return
	var host_peer_id := _get_host_peer_id()
	if host_peer_id <= 0 or not _is_peer_send_ready(host_peer_id):
		return
	_send_route_rpc(
		host_peer_id,
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


func _on_local_shop_exit_ack_requested(
	occurrence_key: String,
	expected_session_revision: int
) -> void:
	if _route == null:
		return
	var local_peer_id := _get_local_peer_id()
	if _is_host():
		_route.host_submit_shop_exit(
			local_peer_id,
			occurrence_key,
			expected_session_revision
		)
		return
	if not _is_client():
		return
	_pending_shop_exit_ack = {
		"occurrence_key": occurrence_key,
		"expected_session_revision": expected_session_revision,
	}
	_pending_shop_exit_retry_at_msec = 0
	_try_send_pending_shop_exit_ack()


func _on_local_player_upgrade_requested(
	stat_type: int,
	expected_level: int,
	expected_xirang_revision: int
) -> void:
	if _route == null or _run_state == null:
		return
	var local_peer_id := _get_local_peer_id()
	if _is_host():
		_submit_authoritative_route_upgrade(
			local_peer_id,
			stat_type,
			expected_level,
			expected_xirang_revision
		)
		return
	if not _is_client() or not _has_network_peer():
		return
	var host_peer_id := _get_host_peer_id()
	if host_peer_id <= 0 or not _is_peer_send_ready(host_peer_id):
		return
	_send_route_rpc(
		host_peer_id,
		&"net_route_upgrade_requested",
		[stat_type, expected_level, expected_xirang_revision]
	)


func _submit_authoritative_route_upgrade(
	peer_id: int,
	stat_type: int,
	expected_level: int,
	expected_xirang_revision: int
) -> bool:
	if (
		not _is_host()
		or _route == null
		or _run_state == null
		or not _route.is_route_ready()
		or not RunStateStore.MAX_UPGRADE_LEVELS.has(stat_type)
		or not _run_state.has_multiplayer_peer_state(peer_id)
		or _run_state.get_upgrade_level_for_peer(peer_id, stat_type)
		!= expected_level
		or _run_state.get_party_xirang_ledger_revision()
		!= expected_xirang_revision
	):
		return false
	var route_player := _route.get_player_for_peer(peer_id)
	if (
		route_player == null
		or not is_instance_valid(route_player)
		or route_player.peer_id != peer_id
		or not route_player.uses_run_party_xirang_ledger(peer_id)
		or not _run_state.try_upgrade_for_peer(
			peer_id,
			stat_type,
			route_player
		)
	):
		return false
	# RunState 已在任何信号前同时提交余额与等级；此后只广播绝对快照。
	_broadcast_full_snapshot()
	return true


func _try_send_pending_shop_exit_ack(now_msec: int = -1) -> bool:
	if (
		not _is_client()
		or _pending_shop_exit_ack.is_empty()
		or not _has_network_peer()
	):
		return false
	var host_peer_id := _get_host_peer_id()
	if host_peer_id <= 0 or not _is_peer_send_ready(host_peer_id):
		return false
	var resolved_now := Time.get_ticks_msec() if now_msec < 0 else now_msec
	_send_route_rpc(
		host_peer_id,
		&"net_shop_exit_ack",
		[
			str(_pending_shop_exit_ack.get("occurrence_key", "")),
			int(_pending_shop_exit_ack.get("expected_session_revision", -1)),
		]
	)
	_pending_shop_exit_retry_at_msec = resolved_now + SHOP_EXIT_ACK_RETRY_MSEC
	return true


func _retry_pending_shop_exit_ack_if_due(now_msec: int = -1) -> void:
	var resolved_now := Time.get_ticks_msec() if now_msec < 0 else now_msec
	if resolved_now < _pending_shop_exit_retry_at_msec:
		return
	_pending_shop_exit_retry_at_msec = resolved_now + SHOP_EXIT_ACK_RETRY_MSEC
	_try_send_pending_shop_exit_ack(resolved_now)


func _reconcile_pending_shop_exit_ack(shop_state: Dictionary) -> void:
	if _pending_shop_exit_ack.is_empty() or shop_state.is_empty():
		return
	var pending_occurrence := str(
		_pending_shop_exit_ack.get("occurrence_key", "")
	)
	var incoming_occurrence := str(shop_state.get("occurrence_key", ""))
	if incoming_occurrence != pending_occurrence:
		_pending_shop_exit_ack.clear()
		_pending_shop_exit_retry_at_msec = 0
		return
	if bool(shop_state.get("target_exited", false)):
		_pending_shop_exit_ack.clear()
		_pending_shop_exit_retry_at_msec = 0
		return
	_pending_shop_exit_ack["expected_session_revision"] = int(
		shop_state.get("session_revision", -1)
	)
	_pending_shop_exit_retry_at_msec = 0


func _refresh_authoritative_snapshot_cache() -> bool:
	if (
		_route == null
		or not _route.is_route_ready()
	):
		return false
	var layout := _route.export_layout_snapshot()
	var state := _route.export_state_snapshot()
	var encounter := _route.export_encounter_snapshot()
	var economy := _route.export_encounter_economy_snapshot()
	if (
		layout.is_empty()
		or state.is_empty()
		or encounter.is_empty()
		or economy.is_empty()
	):
		return false
	_latest_layout_snapshot = layout.duplicate(true)
	_latest_state_snapshot = state.duplicate(true)
	_latest_encounter_snapshot = encounter.duplicate(true)
	_latest_economy_snapshot = economy.duplicate(true)
	return true


func _refresh_authoritative_state_cache() -> bool:
	if _route == null or not _route.is_route_ready():
		return false
	var state := _route.export_state_snapshot()
	if state.is_empty():
		return false
	_latest_state_snapshot = state.duplicate(true)
	return true


func _capture_player_health_upgrade_levels() -> Dictionary:
	var result: Dictionary = {}
	if _run_state == null:
		return result
	for peer_id in _run_state.get_registered_multiplayer_peer_ids():
		result[peer_id] = _run_state.get_upgrade_level_for_peer(
			peer_id,
			RunStateStore.StatType.HEALTH
		)
	return result


func _broadcast_full_snapshot() -> void:
	if not _is_host() or not _has_network_peer():
		return
	if not _refresh_authoritative_snapshot_cache():
		return
	for peer_id in _get_remote_player_peer_ids():
		_send_full_snapshot_to_peer(peer_id)


func _send_full_snapshot_to_peer(
	peer_id: int,
	reconnect_delivery: bool = false
) -> bool:
	var send_ready := (
		_is_peer_send_ready(peer_id)
		or (
			reconnect_delivery
			and _net_manager != null
			and _net_manager.is_reconnect_delivery_preparing(peer_id)
		)
	)
	if (
		not _is_host()
		or _run_state == null
		or peer_id <= 0
		or peer_id == _get_host_peer_id()
		or not _has_network_peer()
		or not send_ready
		or not _refresh_authoritative_snapshot_cache()
	):
		return false
	var shop_state := _route.export_shop_snapshot_for_peer(peer_id)
	var encounter_state := _route.export_encounter_snapshot(peer_id)
	var economy_state := _route.export_encounter_economy_snapshot(peer_id)
	var progression_ledger := _run_state.export_player_upgrade_ledger()
	if (
		encounter_state.is_empty()
		or economy_state.is_empty()
		or progression_ledger.is_empty()
	):
		return false
	return _send_route_rpc(
		peer_id,
		&"net_route_full_snapshot",
		[
			_latest_layout_snapshot.duplicate(true),
			_latest_state_snapshot.duplicate(true),
			encounter_state.duplicate(true),
			economy_state.duplicate(true),
			shop_state.duplicate(true),
			progression_ledger.duplicate(true),
		]
	)


func _request_full_snapshot() -> void:
	if (
		not _is_client()
		or not _has_network_peer()
	):
		return
	var host_peer_id := _get_host_peer_id()
	if host_peer_id <= 0 or not _reserve_full_snapshot_request():
		return
	_send_route_rpc(host_peer_id, &"net_request_route_full_snapshot")


func _reserve_full_snapshot_request(now_msec: int = -1) -> bool:
	var resolved_now_msec := (
		Time.get_ticks_msec()
		if now_msec < 0
		else now_msec
	)
	if (
		_snapshot_request_pending
		and resolved_now_msec < _snapshot_request_retry_at_msec
	):
		return false
	_snapshot_request_pending = true
	var retry_delay_msec := mini(
		SNAPSHOT_REQUEST_RETRY_BASE_MSEC
		* (1 << _snapshot_request_retry_exponent),
		SNAPSHOT_REQUEST_RETRY_MAX_MSEC
	)
	_snapshot_request_retry_at_msec = resolved_now_msec + retry_delay_msec
	_snapshot_request_retry_exponent = mini(
		_snapshot_request_retry_exponent + 1,
		SNAPSHOT_REQUEST_RETRY_MAX_EXPONENT
	)
	return true


func _admit_route_repair_request(peer_id: int) -> bool:
	return (
		_is_registered_route_peer(peer_id)
		and _consume_route_repair_request(peer_id)
	)


func _admit_route_encounter_command(peer_id: int) -> bool:
	return (
		_is_gameplay_ingress_admitted(peer_id)
		and _is_registered_route_peer(peer_id)
		and _consume_peer_rate_token(
			_route_encounter_command_rate_buckets,
			peer_id,
			ROUTE_ENCOUNTER_COMMAND_RATE_PER_SECOND,
			ROUTE_ENCOUNTER_COMMAND_RATE_BURST
		)
	)


func _admit_route_shop_command(peer_id: int) -> bool:
	return (
		_is_gameplay_ingress_admitted(peer_id)
		and _is_registered_route_peer(peer_id)
		and _consume_peer_rate_token(
			_route_shop_command_rate_buckets,
			peer_id,
			ROUTE_SHOP_COMMAND_RATE_PER_SECOND,
			ROUTE_SHOP_COMMAND_RATE_BURST
		)
	)


func _admit_route_upgrade_command(peer_id: int) -> bool:
	return (
		_is_gameplay_ingress_admitted(peer_id)
		and _is_registered_route_peer(peer_id)
		and _consume_peer_rate_token(
			_route_upgrade_command_rate_buckets,
			peer_id,
			ROUTE_UPGRADE_COMMAND_RATE_PER_SECOND,
			ROUTE_UPGRADE_COMMAND_RATE_BURST
		)
	)


func _is_gameplay_ingress_admitted(peer_id: int) -> bool:
	return (
		_net_manager != null
		and _net_manager.is_gameplay_ingress_admitted(peer_id)
	)


func _is_registered_route_peer(peer_id: int) -> bool:
	if _net_manager == null or _get_connection_state() != STATE_IN_GAME:
		return false
	var connected_players := _net_manager.connected_players
	return (
		peer_id > 0
		and peer_id != _get_host_peer_id()
		and connected_players.has(peer_id)
		and _route != null
		and _route.get_player_for_peer(peer_id) != null
		and _is_peer_send_ready(peer_id)
	)


func _consume_route_repair_request(
	peer_id: int,
	now_seconds: float = -1.0
) -> bool:
	return _consume_peer_rate_token(
		_route_repair_request_rate_buckets,
		peer_id,
		ROUTE_REPAIR_RATE_PER_SECOND,
		ROUTE_REPAIR_RATE_BURST,
		now_seconds
	)


func _consume_peer_rate_token(
	buckets: Dictionary,
	peer_id: int,
	rate_per_second: float,
	burst: float,
	now_seconds: float = -1.0
) -> bool:
	if peer_id <= 0 or rate_per_second <= 0.0 or burst <= 0.0:
		return false
	var now := (
		float(Time.get_ticks_msec()) / 1000.0
		if now_seconds < 0.0
		else now_seconds
	)
	var bucket := buckets.get(peer_id, {}) as Dictionary
	if bucket.is_empty():
		bucket = {
			"tokens": burst,
			"last_time": now,
		}
		buckets[peer_id] = bucket
	var tokens := minf(
		burst,
		float(bucket.get("tokens", burst))
		+ maxf(now - float(bucket.get("last_time", now)), 0.0)
		* rate_per_second
	)
	var accepted := tokens >= 1.0
	if accepted:
		tokens -= 1.0
	bucket["tokens"] = tokens
	bucket["last_time"] = now
	return accepted


func _retry_full_snapshot_if_due() -> void:
	if Time.get_ticks_msec() >= _snapshot_request_retry_at_msec:
		_request_full_snapshot()


func _schedule_full_snapshot_retry() -> void:
	if _snapshot_request_pending:
		return
	_snapshot_request_pending = true
	_snapshot_request_retry_at_msec = (
		Time.get_ticks_msec() + SNAPSHOT_REQUEST_RETRY_BASE_MSEC
	)
	_snapshot_request_retry_exponent = 1


func _reset_snapshot_request_state() -> void:
	_snapshot_request_pending = false
	_snapshot_request_retry_at_msec = 0
	_snapshot_request_retry_exponent = 0


func _configure_route_players() -> bool:
	if _route == null or _net_manager == null:
		return false
	var player_names := _net_manager.connected_players
	var character_ids := _net_manager.get_player_character_map()
	var local_peer_id := _get_local_peer_id()
	if local_peer_id <= 0 or not player_names.has(local_peer_id):
		return false
	var participant_stable_keys: Dictionary = {}
	for peer_id_variant in player_names:
		var peer_id := int(peer_id_variant)
		var stable_key := _net_manager.get_stable_participant_key(peer_id)
		if _is_host() and stable_key.is_empty():
			push_error(
				"MpRogueRoute: 玩家 %d 缺少已认证的稳定参与者身份，拒绝启动路线。"
				% peer_id
			)
			return false
		if not stable_key.is_empty():
			participant_stable_keys[peer_id] = stable_key
	if _run_state == null:
		return false
	# 路线 Player 只创建在线投影；持久账本从会话成员全集收敛，保留仍在
	# grace 的离线玩家，等待重连 alias 或 final departure。
	if not _reconcile_run_state_to_session_membership():
		return false
	if not _route.configure_multiplayer_players(
		local_peer_id,
		player_names.duplicate(),
		character_ids.duplicate(),
		participant_stable_keys
	):
		return false
	# 与 MpGame 保持相同生命周期：进入多人运行时绑定本机 peer；切场不清空，
	# 让路线、战斗与遭遇继续共享同一背包。
	return _run_state.set_active_multiplayer_peer(local_peer_id)


func _send_local_avatar_pose() -> void:
	if not _is_client() or not _has_network_peer():
		return
	var host_peer_id := _get_host_peer_id()
	if host_peer_id <= 0 or not _is_peer_send_ready(host_peer_id):
		return
	var snapshot := _route.get_local_avatar_snapshot()
	var packed_pose := _encode_avatar_pose(snapshot)
	if packed_pose.size() != AVATAR_POSE_FIELD_COUNT:
		return
	_client_avatar_sequence = _next_avatar_sequence(_client_avatar_sequence)
	_send_route_rpc(
		host_peer_id,
		&"net_route_avatar_input",
		[
			_client_avatar_sequence,
			_route.get_route_revision(),
			packed_pose,
		]
	)


func _broadcast_avatar_snapshot() -> void:
	if not _is_host() or not _has_network_peer():
		return
	var route_revision := _route.get_route_revision()
	if route_revision < 0:
		return
	var host_peer_id := _get_host_peer_id()
	_enforce_host_avatar_bounds(host_peer_id)
	var player_names := _net_manager.connected_players
	var peer_ids: Array[int] = []
	for peer_id_variant in player_names:
		var peer_id := int(peer_id_variant)
		if peer_id > 0 and _route.get_player_for_peer(peer_id) != null:
			peer_ids.append(peer_id)
	peer_ids.sort()
	var packed_states := PackedInt32Array()
	for peer_id in peer_ids:
		var pose := _get_avatar_pose_for_peer(peer_id)
		var packed_pose := _encode_avatar_pose(pose)
		if packed_pose.size() != AVATAR_POSE_FIELD_COUNT:
			continue
		packed_states.append(peer_id)
		packed_states.append_array(packed_pose)
	if packed_states.is_empty():
		return
	_host_avatar_snapshot_sequence = _next_avatar_sequence(
		_host_avatar_snapshot_sequence
	)
	for peer_id in _get_remote_player_peer_ids():
		if _is_peer_send_ready(peer_id):
			_send_route_rpc(
				peer_id,
				&"net_route_avatar_snapshot",
				[
					_host_avatar_snapshot_sequence,
					route_revision,
					packed_states,
				]
			)


func _get_avatar_pose_for_peer(peer_id: int) -> Dictionary:
	var player_node := _route.get_player_for_peer(peer_id)
	if player_node == null or not is_instance_valid(player_node):
		return {}
	return {
		"position": player_node.global_position,
		"velocity": player_node.velocity,
		"facing": player_node.get_multiplayer_facing_id(),
		"anim_state": player_node.get_multiplayer_anim_state(),
	}


func _enforce_host_avatar_bounds(host_peer_id: int) -> void:
	var pose := _get_avatar_pose_for_peer(host_peer_id)
	if pose.is_empty():
		return
	var position := pose.get("position", Vector2.ZERO) as Vector2
	if _route.is_avatar_position_in_world(position):
		return
	var safe_position := _route.clamp_avatar_position(position)
	_route.apply_avatar_snapshot(
		host_peer_id,
		safe_position,
		Vector2.ZERO,
		int(pose.get("facing", 0)),
		int(pose.get("anim_state", 0)),
		true
	)


func _encode_avatar_pose(snapshot: Dictionary) -> PackedInt32Array:
	if snapshot.is_empty():
		return PackedInt32Array()
	var position := snapshot.get("position", Vector2.INF) as Vector2
	var velocity := snapshot.get("velocity", Vector2.INF) as Vector2
	var facing := int(snapshot.get("facing", -1))
	var anim_state := int(snapshot.get("anim_state", -1))
	if (
		not position.is_finite()
		or not velocity.is_finite()
		or facing < AVATAR_FACING_MIN
		or facing > AVATAR_FACING_MAX
		or anim_state < 0
		or anim_state > AVATAR_ANIM_STATE_MAX
	):
		return PackedInt32Array()
	return PackedInt32Array([
		roundi(position.x * AVATAR_QUANTIZATION_SCALE),
		roundi(position.y * AVATAR_QUANTIZATION_SCALE),
		roundi(velocity.x * AVATAR_QUANTIZATION_SCALE),
		roundi(velocity.y * AVATAR_QUANTIZATION_SCALE),
		facing,
		anim_state,
	])


func _decode_avatar_pose(
	packed_pose: PackedInt32Array,
	start_offset: int = 0
) -> Dictionary:
	if start_offset < 0 or packed_pose.size() - start_offset < AVATAR_POSE_FIELD_COUNT:
		return {}
	var facing := int(packed_pose[start_offset + 4])
	var anim_state := int(packed_pose[start_offset + 5])
	if (
		facing < AVATAR_FACING_MIN
		or facing > AVATAR_FACING_MAX
		or anim_state < 0
		or anim_state > AVATAR_ANIM_STATE_MAX
	):
		return {}
	var inverse_scale := 1.0 / AVATAR_QUANTIZATION_SCALE
	var position := Vector2(
		float(packed_pose[start_offset]) * inverse_scale,
		float(packed_pose[start_offset + 1]) * inverse_scale
	)
	var velocity := Vector2(
		float(packed_pose[start_offset + 2]) * inverse_scale,
		float(packed_pose[start_offset + 3]) * inverse_scale
	)
	if not position.is_finite() or not velocity.is_finite():
		return {}
	return {
		"position": position,
		"velocity": velocity,
		"facing": facing,
		"anim_state": anim_state,
	}


func _next_avatar_sequence(current_sequence: int) -> int:
	return mini(current_sequence + 1, AVATAR_MAX_SEQUENCE)


@rpc("any_peer", "call_remote", "reliable", 0)
func net_route_encounter_intro_ack(
	occurrence_key: String,
	expected_revision: int
) -> void:
	if not _is_host() or _route == null:
		return
	var sender_id := _get_route_rpc_sender_id()
	if not _admit_route_encounter_command(sender_id):
		return
	if not _route.host_submit_encounter_intro_ack(
		sender_id,
		occurrence_key,
		expected_revision
	) and _admit_route_repair_request(sender_id):
		_send_encounter_snapshot_to_peer(sender_id)


@rpc("any_peer", "call_remote", "reliable", 0)
func net_route_encounter_vote(
	occurrence_key: String,
	expected_revision: int,
	option_id: StringName
) -> void:
	if not _is_host() or _route == null:
		return
	var sender_id := _get_route_rpc_sender_id()
	if not _admit_route_encounter_command(sender_id):
		return
	if not _route.host_submit_encounter_vote(
		sender_id,
		occurrence_key,
		expected_revision,
		option_id
	) and _admit_route_repair_request(sender_id):
		_send_encounter_snapshot_to_peer(sender_id)


@rpc("any_peer", "call_remote", "reliable", 0)
func net_route_encounter_result_ack(
	occurrence_key: String,
	result_sequence: int
) -> void:
	if not _is_host() or _route == null:
		return
	var sender_id := _get_route_rpc_sender_id()
	if not _admit_route_encounter_command(sender_id):
		return
	if not _route.host_submit_encounter_result_ack(
		sender_id,
		occurrence_key,
		result_sequence
	) and _admit_route_repair_request(sender_id):
		_send_encounter_snapshot_to_peer(sender_id)


@rpc("authority", "call_remote", "reliable", 0)
func net_route_encounter_snapshot(
	encounter_state: Dictionary,
	economy_state: Dictionary
) -> void:
	_apply_encounter_snapshot_from_peer(
		_get_route_rpc_sender_id(),
		encounter_state,
		economy_state
	)


func _apply_encounter_snapshot_from_peer(
	sender_id: int,
	encounter_state: Dictionary,
	economy_state: Dictionary
) -> bool:
	if (
		not _is_client()
		or sender_id != _get_host_peer_id()
		or encounter_state.is_empty()
		or economy_state.is_empty()
		or _route == null
	):
		return false
	if _route.apply_encounter_snapshot(
		encounter_state.duplicate(true),
		economy_state.duplicate(true)
	):
		_latest_encounter_snapshot = encounter_state.duplicate(true)
		_latest_economy_snapshot = economy_state.duplicate(true)
		return true
	_request_full_snapshot()
	return false


func _send_encounter_snapshot_to_peer(peer_id: int) -> bool:
	if (
		not _is_host()
		or peer_id <= 0
		or peer_id == _get_host_peer_id()
		or not _has_network_peer()
		or not _is_peer_send_ready(peer_id)
		or _route == null
	):
		return false
	var encounter_state := _route.export_encounter_snapshot(peer_id)
	var economy_state := _route.export_encounter_economy_snapshot(peer_id)
	if encounter_state.is_empty() or economy_state.is_empty():
		return false
	_send_route_rpc(
		peer_id,
		&"net_route_encounter_snapshot",
		[
			encounter_state.duplicate(true),
			economy_state.duplicate(true),
		]
	)
	return true


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
	if not _is_host() or _route == null:
		return
	var sender_id := _get_route_rpc_sender_id()
	if not _admit_route_shop_command(sender_id):
		return
	_route.host_submit_shop_purchase(
		sender_id,
		request_id,
		occurrence_key,
		offer_index,
		expected_session_revision,
		expected_shelf_revision,
		expected_inventory_revision,
		expected_xirang_revision
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
	if not _is_host() or _route == null:
		return
	var sender_id := _get_route_rpc_sender_id()
	if not _admit_route_shop_command(sender_id):
		return
	_route.host_submit_shop_sell(
		sender_id,
		request_id,
		occurrence_key,
		slot_index,
		expected_config_path,
		expected_session_revision,
		expected_inventory_revision,
		expected_xirang_revision
	)


@rpc("any_peer", "call_remote", "reliable", 0)
func net_shop_exit_ack(
	occurrence_key: String,
	expected_session_revision: int
) -> void:
	if not _is_host() or _route == null:
		return
	var sender_id := _get_route_rpc_sender_id()
	# 退出回执关闭本地 UI 后没有人工重试入口，不能与高频买卖共用会
	# 静默耗尽的 token bucket；仍严格要求已注册、可发送的 RPC sender。
	if (
		not _is_gameplay_ingress_admitted(sender_id)
		or not _is_registered_route_peer(sender_id)
	):
		return
	_route.host_submit_shop_exit(
		sender_id,
		occurrence_key,
		expected_session_revision
	)


@rpc("authority", "call_remote", "reliable", 0)
func net_shop_snapshot(shop_state: Dictionary) -> void:
	_apply_shop_snapshot_from_peer(
		_get_route_rpc_sender_id(),
		shop_state
	)


func _apply_shop_snapshot_from_peer(
	sender_id: int,
	shop_state: Dictionary
) -> bool:
	if (
		not _is_client()
		or sender_id != _get_host_peer_id()
		or shop_state.is_empty()
		or _route == null
	):
		return false
	if _route.apply_shop_snapshot(shop_state.duplicate(true)):
		_latest_shop_snapshot = shop_state.duplicate(true)
		_reconcile_pending_shop_exit_ack(shop_state)
		return true
	_request_full_snapshot()
	return false


@rpc("any_peer", "call_remote", "unreliable_ordered", 1)
func net_route_avatar_input(
	sequence: int,
	route_revision: int,
	packed_pose: PackedInt32Array
) -> void:
	if not _is_host():
		return
	var sender_id := _get_route_rpc_sender_id()
	if (
		not _is_gameplay_ingress_admitted(sender_id)
		or sender_id <= 0
		or sender_id == _get_host_peer_id()
		or sequence <= int(_last_client_avatar_sequences.get(sender_id, 0))
		or sequence > AVATAR_MAX_SEQUENCE
	):
		return
	if not _accept_client_avatar_pose(
		sender_id,
		sequence,
		route_revision,
		packed_pose
	):
		_try_send_avatar_correction(sender_id, sequence)


func _accept_client_avatar_pose(
	peer_id: int,
	sequence: int,
	route_revision: int,
	packed_pose: PackedInt32Array
) -> bool:
	if (
		peer_id <= 0
		or peer_id == _get_host_peer_id()
		or sequence <= int(_last_client_avatar_sequences.get(peer_id, 0))
		or sequence > AVATAR_MAX_SEQUENCE
		or packed_pose.size() != AVATAR_POSE_FIELD_COUNT
		or _route.get_player_for_peer(peer_id) == null
		or _route.is_encounter_active()
	):
		return false
	if route_revision != _route.get_route_revision():
		return false
	var pose := _decode_avatar_pose(packed_pose)
	if pose.is_empty():
		return false
	var position := pose.get("position", Vector2.ZERO) as Vector2
	var velocity := pose.get("velocity", Vector2.ZERO) as Vector2
	if not _route.is_avatar_position_in_world(position):
		return false
	var player_node := _route.get_player_for_peer(peer_id)
	var move_speed := maxf(player_node.move_speed, 1.0)
	if velocity.length() > (
		move_speed * AVATAR_VELOCITY_TOLERANCE_MULTIPLIER
		+ AVATAR_POSITION_TOLERANCE
	):
		return false
	var now_msec := Time.get_ticks_msec()
	if not _accepted_avatar_positions.has(peer_id):
		var authoritative_position := player_node.global_position
		if authoritative_position.distance_to(position) > AVATAR_INITIAL_POSITION_TOLERANCE:
			return false
	else:
		var previous_position := _accepted_avatar_positions[peer_id] as Vector2
		var previous_time_msec := int(
			_accepted_avatar_times_msec.get(peer_id, now_msec)
		)
		var elapsed := clampf(
			float(now_msec - previous_time_msec) / 1000.0,
			1.0 / 120.0,
			AVATAR_MAX_VALIDATION_SECONDS
		)
		var allowed_distance := (
			move_speed * elapsed * AVATAR_SPEED_TOLERANCE_MULTIPLIER
			+ AVATAR_POSITION_TOLERANCE
		)
		if position.distance_to(previous_position) > allowed_distance:
			return false
	var applied := _route.apply_avatar_snapshot(
		peer_id,
		position,
		velocity,
		int(pose.get("facing", 0)),
		int(pose.get("anim_state", 0))
	)
	if applied:
		_accepted_avatar_positions[peer_id] = position
		_accepted_avatar_times_msec[peer_id] = now_msec
		_last_client_avatar_sequences[peer_id] = sequence
	return applied


func _try_send_avatar_correction(
	peer_id: int,
	input_sequence: int,
	now_msec: int = -1
) -> bool:
	if (
		not _is_host()
		or peer_id <= 0
		or not _has_network_peer()
		or not _is_peer_send_ready(peer_id)
	):
		return false
	var packed_pose := _encode_avatar_pose(_get_avatar_pose_for_peer(peer_id))
	if packed_pose.size() != AVATAR_POSE_FIELD_COUNT:
		return false
	if not _reserve_avatar_correction(peer_id, input_sequence, now_msec):
		return false
	_send_route_rpc(
		peer_id,
		&"net_route_avatar_corrected",
		[_route.get_route_revision(), packed_pose]
	)
	return true


func _reserve_avatar_correction(
	peer_id: int,
	input_sequence: int,
	now_msec: int = -1
) -> bool:
	if (
		peer_id <= 0
		or input_sequence <= int(_last_client_avatar_sequences.get(peer_id, 0))
		or input_sequence > AVATAR_MAX_SEQUENCE
		or input_sequence == int(
			_last_avatar_correction_sequences.get(peer_id, -1)
		)
	):
		return false
	var resolved_now_msec := Time.get_ticks_msec() if now_msec < 0 else now_msec
	var previous_correction_msec := int(
		_last_avatar_correction_times_msec.get(
			peer_id,
			resolved_now_msec - AVATAR_CORRECTION_INTERVAL_MSEC
		)
	)
	if resolved_now_msec - previous_correction_msec < AVATAR_CORRECTION_INTERVAL_MSEC:
		return false
	_last_avatar_correction_times_msec[peer_id] = resolved_now_msec
	_last_avatar_correction_sequences[peer_id] = input_sequence
	return true


@rpc("authority", "call_remote", "unreliable_ordered", 2)
func net_route_avatar_snapshot(
	snapshot_sequence: int,
	route_revision: int,
	packed_states: PackedInt32Array
) -> void:
	if (
		not _is_client()
		or _get_route_rpc_sender_id() != _get_host_peer_id()
		or snapshot_sequence <= _last_host_avatar_snapshot_sequence
		or snapshot_sequence > AVATAR_MAX_SEQUENCE
		or route_revision != _route.get_route_revision()
		or packed_states.is_empty()
		or packed_states.size() % AVATAR_SNAPSHOT_FIELD_COUNT != 0
	):
		return
	_last_host_avatar_snapshot_sequence = snapshot_sequence
	for state_offset in range(0, packed_states.size(), AVATAR_SNAPSHOT_FIELD_COUNT):
		var peer_id := int(packed_states[state_offset])
		if peer_id <= 0:
			continue
		var pose := _decode_avatar_pose(packed_states, state_offset + 1)
		if pose.is_empty():
			continue
		var position := pose.get("position", Vector2.ZERO) as Vector2
		if not _route.is_avatar_position_in_world(position):
			continue
		_route.apply_avatar_snapshot(
			peer_id,
			position,
			pose.get("velocity", Vector2.ZERO) as Vector2,
			int(pose.get("facing", 0)),
			int(pose.get("anim_state", 0))
		)


@rpc("authority", "call_remote", "reliable", 0)
func net_route_avatar_corrected(
	route_revision: int,
	packed_pose: PackedInt32Array
) -> void:
	if (
		not _is_client()
		or _get_route_rpc_sender_id() != _get_host_peer_id()
		or route_revision != _route.get_route_revision()
		or packed_pose.size() != AVATAR_POSE_FIELD_COUNT
	):
		return
	var pose := _decode_avatar_pose(packed_pose)
	if pose.is_empty():
		return
	_route.apply_avatar_snapshot(
		_get_local_peer_id(),
		pose.get("position", Vector2.ZERO) as Vector2,
		pose.get("velocity", Vector2.ZERO) as Vector2,
		int(pose.get("facing", 0)),
		int(pose.get("anim_state", 0)),
		true
	)


func _reset_avatar_validation_positions() -> void:
	_accepted_avatar_positions.clear()
	_accepted_avatar_times_msec.clear()


func _reset_avatar_sync_state(
	preserve_disconnected_poses: bool = false
) -> void:
	_client_avatar_sequence = 0
	_last_host_avatar_snapshot_sequence = 0
	_last_client_avatar_sequences.clear()
	_last_avatar_correction_times_msec.clear()
	_last_avatar_correction_sequences.clear()
	if not preserve_disconnected_poses:
		_disconnected_avatar_poses.clear()
	_reset_avatar_validation_positions()


func _clear_avatar_peer_sync_state(peer_id: int) -> void:
	_last_client_avatar_sequences.erase(peer_id)
	_accepted_avatar_positions.erase(peer_id)
	_accepted_avatar_times_msec.erase(peer_id)
	_last_avatar_correction_times_msec.erase(peer_id)
	_last_avatar_correction_sequences.erase(peer_id)


func _prune_disconnected_avatar_poses() -> void:
	var now_msec := Time.get_ticks_msec()
	for peer_id_variant in _disconnected_avatar_poses.keys():
		var pose := _disconnected_avatar_poses.get(peer_id_variant, {}) as Dictionary
		if (
			pose.is_empty()
			or now_msec - int(pose.get("stored_at_msec", 0))
			> AVATAR_RECONNECT_POSE_RETENTION_MSEC
		):
			_disconnected_avatar_poses.erase(peer_id_variant)


@rpc("any_peer", "call_remote", "reliable", 0)
func net_request_route_full_snapshot() -> void:
	if not _is_host():
		return
	var sender_id := _get_route_rpc_sender_id()
	if not _admit_route_repair_request(sender_id):
		return
	_send_full_snapshot_to_peer(sender_id)


@rpc("any_peer", "call_remote", "reliable", 0)
func net_route_upgrade_requested(
	stat_type: int,
	expected_level: int,
	expected_xirang_revision: int
) -> void:
	if not _is_host():
		return
	var sender_id := _get_route_rpc_sender_id()
	if not _admit_route_upgrade_command(sender_id):
		return
	if not _submit_authoritative_route_upgrade(
		sender_id,
		stat_type,
		expected_level,
		expected_xirang_revision
	):
		# 拒绝与过期请求都回收到 Host 高水位，不让本地 UI 猜测继续滞留。
		_send_full_snapshot_to_peer(sender_id)


@rpc("authority", "call_remote", "reliable", 0)
func net_route_full_snapshot(
	layout: Dictionary,
	state: Dictionary,
	encounter_state: Dictionary,
	economy_state: Dictionary,
	shop_state: Dictionary,
	progression_ledger: Dictionary
) -> void:
	_apply_full_snapshot_from_peer(
		_get_route_rpc_sender_id(),
		layout,
		state,
		encounter_state,
		economy_state,
		shop_state,
		progression_ledger
	)


func _apply_full_snapshot_from_peer(
	sender_id: int,
	layout: Dictionary,
	state: Dictionary,
	encounter_state: Dictionary,
	economy_state: Dictionary,
	shop_state: Dictionary = {},
	progression_ledger: Dictionary = {}
) -> bool:
	if (
		_full_snapshot_apply_in_progress
		or _route == null
		or not _route.try_begin_full_snapshot_transaction()
	):
		return false
	_full_snapshot_apply_in_progress = true
	var applied := _apply_full_snapshot_from_peer_guarded(
		sender_id,
		layout,
		state,
		encounter_state,
		economy_state,
		shop_state,
		progression_ledger
	)
	_full_snapshot_apply_in_progress = false
	_route.end_full_snapshot_transaction()
	return applied


## RPC/owner signal 都可能同步回入；组合事务不排队第二份快照，也不允许
## 嵌套取得 Player signal 屏障。public wrapper 会在所有返回路径释放门。
func _apply_full_snapshot_from_peer_guarded(
	sender_id: int,
	layout: Dictionary,
	state: Dictionary,
	encounter_state: Dictionary,
	economy_state: Dictionary,
	shop_state: Dictionary = {},
	progression_ledger: Dictionary = {}
) -> bool:
	if (
		not _is_client()
		or sender_id != _get_host_peer_id()
		or _route == null
		or _run_state == null
	):
		return false
	if (
		layout.is_empty()
		or state.is_empty()
		or encounter_state.is_empty()
		or economy_state.is_empty()
		or progression_ledger.is_empty()
	):
		_schedule_full_snapshot_retry()
		return false
	var prepared_progression := _run_state.prepare_player_upgrade_ledger(
		progression_ledger.duplicate(true),
		true
	)
	if prepared_progression.is_empty():
		_schedule_full_snapshot_retry()
		return false
	var route_local_peer_id := _route.get_configured_local_peer_id()
	var network_local_peer_id := _get_local_peer_id()
	if (
		route_local_peer_id <= 0
		or (
			network_local_peer_id > 0
			and route_local_peer_id != network_local_peer_id
		)
	):
		_schedule_full_snapshot_retry()
		return false
	var prepared_route := _route.prepare_full_snapshot(
		layout.duplicate(true),
		state.duplicate(true),
		encounter_state.duplicate(true),
		economy_state.duplicate(true),
		shop_state.duplicate(true),
		route_local_peer_id
	)
	var prepared_player_projection := (
		_route.prepare_authoritative_player_progression(
			prepared_progression,
			prepared_route
		)
		if not prepared_route.is_empty()
		else {}
	)
	if (
		prepared_route.is_empty()
		or prepared_player_projection.is_empty()
		or not _run_state.can_commit_prepared_player_upgrade_ledger(
			prepared_progression
		)
		or not _route.can_commit_prepared_full_snapshot(prepared_route)
		or not _route.can_commit_prepared_authoritative_player_progression(
			prepared_player_projection
		)
	):
		_route.discard_prepared_full_snapshot(prepared_route)
		_schedule_full_snapshot_retry()
		return false
	_route.begin_validated_authoritative_player_projection(
		prepared_player_projection
	)
	_run_state.commit_validated_player_upgrade_ledger(
		prepared_progression,
		false
	)
	_route.commit_validated_full_snapshot(prepared_route, false)
	_route.commit_validated_authoritative_player_progression(
		prepared_player_projection
	)
	_route.commit_validated_authoritative_player_xirang(
		prepared_player_projection
	)
	_route.stage_validated_authoritative_player_projection_publish(
		prepared_player_projection,
		false
	)
	_run_state.publish_prepared_player_upgrade_ledger(prepared_progression)
	_route.publish_prepared_full_snapshot_changes(prepared_route)
	_route.publish_validated_authoritative_player_projection(
		prepared_player_projection
	)
	_route.complete_prepared_full_snapshot_presentation()
	_route.mark_runtime_preparation_complete(_route_preparation_generation)
	if not _route.is_route_ready():
		_schedule_full_snapshot_retry()
		return false
	_reset_snapshot_request_state()
	_reset_avatar_validation_positions()
	_latest_encounter_snapshot = encounter_state.duplicate(true)
	_latest_economy_snapshot = economy_state.duplicate(true)
	_latest_shop_snapshot = shop_state.duplicate(true)
	_reconcile_pending_shop_exit_ack(shop_state)
	return true


@rpc("authority", "call_remote", "reliable", 0)
func net_route_move_delta(delta: Dictionary) -> void:
	_apply_move_delta_from_peer(_get_route_rpc_sender_id(), delta)


func _apply_move_delta_from_peer(sender_id: int, delta: Dictionary) -> bool:
	if (
		not _is_client()
		or sender_id != _get_host_peer_id()
		or delta.is_empty()
		or _route == null
	):
		return false
	if _route.apply_move_delta(delta.duplicate(true)):
		return true
	_request_full_snapshot()
	return false


@rpc("authority", "call_remote", "reliable", 0)
func net_route_briefing_state(snapshot: Dictionary) -> void:
	_apply_briefing_state_from_peer(
		_get_route_rpc_sender_id(),
		snapshot
	)


func _apply_briefing_state_from_peer(
	sender_id: int,
	snapshot: Dictionary
) -> bool:
	if (
		not _is_client()
		or sender_id != _get_host_peer_id()
		or snapshot.is_empty()
		or _route == null
	):
		return false
	if _route.apply_briefing_state_snapshot(snapshot.duplicate(true)):
		return true
	_request_full_snapshot()
	return false


@rpc("any_peer", "call_remote", "reliable", 0)
func net_route_briefing_cover_ready(
	occurrence_key: String,
	briefing_revision: int,
	expected_route_revision: int
) -> void:
	if not _is_host():
		return
	var sender_id := _get_route_rpc_sender_id()
	if (
		_briefing_cover_ready_peers.has(sender_id)
		or not _admit_route_encounter_command(sender_id)
	):
		return
	_accept_briefing_cover_ready(
		sender_id,
		occurrence_key,
		briefing_revision,
		expected_route_revision
	)


func _on_return_requested() -> void:
	if _embedded_campaign_mode:
		return
	if _public_return_in_progress:
		return
	_public_return_in_progress = true
	var public_room_lease := PublicRoomLeaseStore.get_autoload_instance()
	if public_room_lease != null:
		await public_room_lease.release_current_and_wait(&"rogue_return_to_lobby")
	if not is_inside_tree():
		return
	if _net_manager != null:
		_net_manager.disconnect_from_game()
	_return_to_lobby()


func _return_to_lobby() -> void:
	if _return_scheduled:
		return
	_return_scheduled = true
	call_deferred("_release_before_change_to_lobby")


func _release_before_change_to_lobby() -> void:
	# P3 的任意启动/运行失败都通过同一个清理门；standalone 也必须先断 transport。
	var public_room_lease := PublicRoomLeaseStore.get_autoload_instance()
	if public_room_lease != null:
		await public_room_lease.release_current_and_wait(&"rogue_return_to_lobby")
	if not is_inside_tree():
		return
	if _net_manager != null:
		_net_manager.disconnect_from_game()
	_change_to_lobby()


func _change_to_lobby() -> void:
	var tree := get_tree()
	if tree != null:
		tree.change_scene_to_file(MULTIPLAYER_LOBBY_SCENE_PATH)


func _generate_session_seed() -> int:
	return int(Time.get_unix_time_from_system() * 1_000_000.0) ^ Time.get_ticks_usec()


func _get_connection_state() -> int:
	if _net_manager == null:
		return STATE_DISCONNECTED
	return int(_net_manager.connection_state)


func _get_host_peer_id() -> int:
	return _net_manager.get_host_peer_id() if _net_manager != null else 0


func _get_local_peer_id() -> int:
	if multiplayer != null and multiplayer.has_multiplayer_peer():
		return multiplayer.get_unique_id()
	if _is_host():
		return _get_host_peer_id()
	return 0


func _is_host() -> bool:
	return _net_manager != null and _net_manager.is_host()


func _is_client() -> bool:
	return _net_manager != null and _net_manager.is_client()


func _is_peer_send_ready(peer_id: int) -> bool:
	return _net_manager != null and _net_manager.is_peer_send_ready(peer_id)


func _get_remote_player_peer_ids() -> Array[int]:
	var result: Array[int] = []
	if _net_manager == null:
		return result
	var connected_players := _net_manager.connected_players
	var host_peer_id := _get_host_peer_id()
	for peer_id_variant in connected_players:
		var peer_id := int(peer_id_variant)
		if peer_id > 0 and peer_id != host_peer_id:
			result.append(peer_id)
	result.sort()
	return result


func _has_network_peer() -> bool:
	return multiplayer != null and multiplayer.has_multiplayer_peer()
