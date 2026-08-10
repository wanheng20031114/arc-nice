extends Node2D
class_name MpRogueRoute

const _NetConstants := preload("res://scene/multiplayer/net_constants.gd")
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
const SHOP_EXIT_ACK_RETRY_MSEC := 500
const BRIEFING_COVER_BARRIER_TIMEOUT_MSEC := 10_000

var _route: RogueRouteGame = null
var _combat_coordinator: RogueCombatMultiplayerCoordinator = null
var _net_manager: NetManagerStore = null
var _run_state: RunStateStore = null
var _runtime_prepared := false
var _return_scheduled := false
var _snapshot_request_pending := false
var _snapshot_request_retry_at_msec := 0
var _snapshot_request_retry_exponent := 0
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
var _pending_shop_exit_ack: Dictionary = {}
var _pending_shop_exit_retry_at_msec := 0


func _ready() -> void:
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
		push_error("MpRogueRoute: P3 多人运行时契约不完整。")
		call_deferred("_return_to_lobby")
		return
	_combat_coordinator.bind_network_dependencies(
		_route,
		_net_manager,
		_run_state
	)

	_connect_route_signals()
	set_multiplayer_authority(_get_host_peer_id())
	_connect_net_manager_signals()
	if not _configure_route_players():
		push_error("MpRogueRoute: 无法按房间角色表创建 P3 玩家。")
		call_deferred("_return_to_lobby")
		return
	if _is_host():
		_route.set_authority_enabled(true)
		if not _route.start_authoritative_session(
			_generate_session_seed(),
			false
		):
			push_error("MpRogueRoute: Host 无法生成 P3 路线。")
			call_deferred("_return_to_lobby")
			return
		_refresh_authoritative_snapshot_cache()
	elif _is_client():
		_reset_snapshot_request_state()
		_route.set_authority_enabled(false)
		_route.start_client_waiting()
	else:
		push_warning("MpRogueRoute: 启动时没有有效多人连接，返回大厅。")
		call_deferred("_return_to_lobby")
		return

	_runtime_prepared = true
	call_deferred("_report_game_loaded")
	if _get_connection_state() == STATE_IN_GAME:
		call_deferred("_synchronize_after_barrier")


func _physics_process(delta: float) -> void:
	if (
		not _runtime_prepared
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
	_pending_shop_exit_ack.clear()
	_pending_shop_exit_retry_at_msec = 0
	_disconnect_net_manager_signals()
	_disconnect_route_signals()


func is_runtime_preparation_complete() -> bool:
	return _runtime_prepared


func get_runtime_preparation_progress() -> Dictionary:
	return {
		"stage": (
			"路线框架已准备"
			if _runtime_prepared
			else "正在创建多人路线框架"
		),
		"completed": 1 if _runtime_prepared else 0,
		"total": 1,
	}


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
	if _route.return_requested.is_connected(_on_return_requested):
		_route.return_requested.disconnect(_on_return_requested)


func _connect_net_manager_signals() -> void:
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


func _disconnect_net_manager_signals() -> void:
	if _net_manager == null or not is_instance_valid(_net_manager):
		return
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


func _on_player_reconnected(
	old_peer_id: int,
	new_peer_id: int,
	player_name: String,
	character_id: StringName
) -> void:
	# Host 需等待 NetManager 先把身份通知排入各客户端的可靠信道；既有客户端
	# 则立即清理 old peer，保证后续同信道全量经济快照不会与旧背包并存。
	if not _is_host():
		_finish_player_reconnect(
			old_peer_id,
			new_peer_id,
			player_name,
			character_id
		)
		return
	call_deferred(
		"_finish_player_reconnect",
		old_peer_id,
		new_peer_id,
		player_name,
		character_id
	)


func _finish_player_reconnect(
	old_peer_id: int,
	new_peer_id: int,
	player_name: String,
	character_id: StringName
) -> bool:
	if not is_inside_tree():
		return false
	var route_already_uses_new_peer := (
		_route != null
		and _route.get_player_for_peer(old_peer_id) == null
		and _route.get_player_for_peer(new_peer_id) != null
		and _route.get_player_for_peer(new_peer_id).get_character_id()
		== character_id
	)
	if not route_already_uses_new_peer and not _can_migrate_reconnected_player(
		old_peer_id,
		new_peer_id,
		character_id
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
	var shared_run_state := get_node_or_null("/root/RunState") as RunStateStore
	var had_old_run_state := (
		shared_run_state != null
		and shared_run_state.has_multiplayer_peer_state(old_peer_id)
	)
	var had_new_run_state := (
		shared_run_state != null
		and shared_run_state.has_multiplayer_peer_state(new_peer_id)
	)
	if not _migrate_reconnected_run_state(
		old_peer_id,
		new_peer_id,
		not _is_host()
	):
		push_error(
			"MpRogueRoute: 无法迁移重连玩家 %d -> %d 的背包状态。"
			% [old_peer_id, new_peer_id]
		)
		return false
	if not route_already_uses_new_peer and not _migrate_reconnected_player(
		old_peer_id,
		new_peer_id,
		player_name,
		character_id
	):
		if _is_host() and had_old_run_state and not had_new_run_state:
			_rollback_reconnected_run_state(old_peer_id, new_peer_id)
		return false
	if (
		not stable_participant_key.is_empty()
		and not _route.set_multiplayer_participant_stable_key(
			new_peer_id,
			stable_participant_key
		)
	):
		push_error(
			"MpRogueRoute: 无法为重连玩家 %d 恢复稳定参与者身份。"
			% new_peer_id
		)
		return false
	if _is_host():
		_route_repair_request_rate_buckets.erase(old_peer_id)
		_route_repair_request_rate_buckets.erase(new_peer_id)
		_route_encounter_command_rate_buckets.erase(old_peer_id)
		_route_encounter_command_rate_buckets.erase(new_peer_id)
		_route_shop_command_rate_buckets.erase(old_peer_id)
		_route_shop_command_rate_buckets.erase(new_peer_id)
		_route.host_migrate_encounter_peer(old_peer_id, new_peer_id)
		_route.host_migrate_shop_peer_as_exited(old_peer_id, new_peer_id)
		if _briefing_cover_expected_peers.has(old_peer_id):
			_briefing_cover_expected_peers.erase(old_peer_id)
			_briefing_cover_ready_peers.erase(old_peer_id)
			if not _briefing_move_commit_started:
				_briefing_cover_expected_peers[new_peer_id] = true
		_send_full_snapshot_to_peer(new_peer_id)
	return true


func _can_migrate_reconnected_player(
	old_peer_id: int,
	new_peer_id: int,
	character_id: StringName
) -> bool:
	if (
		old_peer_id <= 0
		or new_peer_id <= 0
		or old_peer_id == new_peer_id
		or _route == null
		or _route.get_player_for_peer(new_peer_id) != null
	):
		return false
	var old_player := _route.get_player_for_peer(old_peer_id)
	if old_player != null:
		return old_player.get_character_id() == character_id
	# The reconnect signal was authenticated by NetManager's Host RPC. A client
	# that itself rejoined later may never have observed the old avatar, so it
	# must be allowed to create a placeholder for the new authoritative identity.
	return PlayerCharacterRegistry.is_valid_character_id(character_id)


func _migrate_reconnected_run_state(
	old_peer_id: int,
	new_peer_id: int,
	replace_existing_target: bool = false
) -> bool:
	if (
		old_peer_id <= 0
		or new_peer_id <= 0
		or old_peer_id == new_peer_id
	):
		return false
	var shared_run_state := get_node_or_null("/root/RunState") as RunStateStore
	if shared_run_state == null:
		return false
	# RunState.remap_multiplayer_peer_state() 会同步发出 inventory_changed。
	# 仍在路线树中的旧 Player 若继续以 old_peer_id 响应该信号，会立刻重建
	# 一个空的旧背包。先只暂存其背包查询身份；权威字典与节点名仍由后续
	# _migrate_reconnected_player() 一次性迁移。
	var live_player: Player = null
	if _route != null:
		live_player = _route.get_player_for_peer(old_peer_id)
	var staged_live_peer := (
		live_player != null
		and is_instance_valid(live_player)
		and live_player.peer_id == old_peer_id
	)
	var staged_inventory_owner := (
		_route != null
		and _route.stage_inventory_owner_peer_remap(
			old_peer_id,
			new_peer_id
		)
	)
	if staged_live_peer:
		live_player.peer_id = new_peer_id
	var migrated := true
	if shared_run_state.has_multiplayer_peer_state(old_peer_id):
		migrated = shared_run_state.remap_multiplayer_peer_state(
			old_peer_id,
			new_peer_id,
			replace_existing_target,
			replace_existing_target
		)
	else:
		shared_run_state.ensure_multiplayer_peer_state(new_peer_id)
		migrated = shared_run_state.has_multiplayer_peer_state(new_peer_id)
	if not migrated and staged_live_peer:
		live_player.peer_id = old_peer_id
	if not migrated and staged_inventory_owner:
		_route.stage_inventory_owner_peer_remap(new_peer_id, old_peer_id)
	return migrated


func _rollback_reconnected_run_state(
	old_peer_id: int,
	new_peer_id: int
) -> bool:
	var shared_run_state := get_node_or_null("/root/RunState") as RunStateStore
	if shared_run_state == null:
		return false
	var live_player: Player = null
	if _route != null:
		live_player = _route.get_player_for_peer(old_peer_id)
	if (
		live_player != null
		and is_instance_valid(live_player)
		and live_player.peer_id == new_peer_id
	):
		live_player.peer_id = old_peer_id
	return shared_run_state.remap_multiplayer_peer_state(
		new_peer_id,
		old_peer_id
	)


func _migrate_reconnected_player(
	old_peer_id: int,
	new_peer_id: int,
	player_name: String,
	character_id: StringName
) -> bool:
	if (
		old_peer_id <= 0
		or new_peer_id <= 0
		or old_peer_id == new_peer_id
		or _route == null
	):
		return false
	var preserved_pose := _get_avatar_pose_for_peer(old_peer_id)
	var old_player := _route.get_player_for_peer(old_peer_id)
	var migrated := false
	if old_player != null:
		migrated = _route.migrate_multiplayer_player(
			old_peer_id,
			new_peer_id,
			player_name,
			character_id
		)
	else:
		_prune_disconnected_avatar_poses()
		preserved_pose = _disconnected_avatar_poses.get(old_peer_id, {}) as Dictionary
		var fallback_position := _get_reconnect_avatar_fallback_position()
		migrated = _route.add_multiplayer_player(
			new_peer_id,
			player_name,
			character_id,
			(
				preserved_pose.get("position", fallback_position) as Vector2
				if not preserved_pose.is_empty()
				else fallback_position
			)
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
	_disconnected_avatar_poses.erase(old_peer_id)
	_clear_avatar_peer_sync_state(old_peer_id)
	_clear_avatar_peer_sync_state(new_peer_id)
	return true


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
		if not preserved_pose.is_empty():
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
			net_route_move_delta.rpc_id(peer_id, delta.duplicate(true))


func _on_host_briefing_state_committed(snapshot: Dictionary) -> void:
	if not _is_host() or snapshot.is_empty():
		return
	_configure_briefing_cover_barrier(snapshot)
	_refresh_authoritative_state_cache()
	if _get_connection_state() != STATE_IN_GAME or not _has_network_peer():
		return
	for peer_id in _get_remote_player_peer_ids():
		if _is_peer_send_ready(peer_id):
			net_route_briefing_state.rpc_id(
				peer_id,
				snapshot.duplicate(true)
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
		net_route_briefing_cover_ready.rpc_id(
			_get_host_peer_id(),
			occurrence_key,
			briefing_revision,
			expected_route_revision
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
	if not _route.host_commit_briefed_move(
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
	_latest_encounter_snapshot = encounter_snapshot.duplicate(true)
	_latest_economy_snapshot = economy_snapshot.duplicate(true)
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
			net_route_encounter_intro_ack.rpc_id(
				host_peer_id,
				occurrence_key,
				expected_revision
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
			net_route_encounter_vote.rpc_id(
				host_peer_id,
				occurrence_key,
				expected_revision,
				option_id
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
			net_route_encounter_result_ack.rpc_id(
				host_peer_id,
				occurrence_key,
				result_sequence
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
		net_shop_snapshot.rpc_id(
			target_peer_id,
			shop_snapshot.duplicate(true)
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
	net_shop_purchase_request.rpc_id(
		host_peer_id,
		request_id,
		occurrence_key,
		offer_index,
		expected_session_revision,
		expected_shelf_revision,
		expected_inventory_revision,
		expected_xirang_revision
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
	net_shop_sell_request.rpc_id(
		host_peer_id,
		request_id,
		occurrence_key,
		slot_index,
		expected_config_path,
		expected_session_revision,
		expected_inventory_revision,
		expected_xirang_revision
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
	net_shop_exit_ack.rpc_id(
		host_peer_id,
		str(_pending_shop_exit_ack.get("occurrence_key", "")),
		int(_pending_shop_exit_ack.get("expected_session_revision", -1))
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


func _broadcast_full_snapshot() -> void:
	if not _is_host() or not _has_network_peer():
		return
	if not _refresh_authoritative_snapshot_cache():
		return
	for peer_id in _get_remote_player_peer_ids():
		_send_full_snapshot_to_peer(peer_id)


func _send_full_snapshot_to_peer(peer_id: int) -> void:
	if (
		not _is_host()
		or peer_id <= 0
		or peer_id == _get_host_peer_id()
		or not _has_network_peer()
		or not _is_peer_send_ready(peer_id)
		or not _refresh_authoritative_snapshot_cache()
	):
		return
	var shop_state := _route.export_shop_snapshot_for_peer(peer_id)
	var encounter_state := _route.export_encounter_snapshot(peer_id)
	var economy_state := _route.export_encounter_economy_snapshot(peer_id)
	if encounter_state.is_empty() or economy_state.is_empty():
		return
	net_route_full_snapshot.rpc_id(
		peer_id,
		_latest_layout_snapshot.duplicate(true),
		_latest_state_snapshot.duplicate(true),
		encounter_state.duplicate(true),
		economy_state.duplicate(true),
		shop_state.duplicate(true)
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
	net_request_route_full_snapshot.rpc_id(host_peer_id)


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
		_is_registered_route_peer(peer_id)
		and _consume_peer_rate_token(
			_route_encounter_command_rate_buckets,
			peer_id,
			ROUTE_ENCOUNTER_COMMAND_RATE_PER_SECOND,
			ROUTE_ENCOUNTER_COMMAND_RATE_BURST
		)
	)


func _admit_route_shop_command(peer_id: int) -> bool:
	return (
		_is_registered_route_peer(peer_id)
		and _consume_peer_rate_token(
			_route_shop_command_rate_buckets,
			peer_id,
			ROUTE_SHOP_COMMAND_RATE_PER_SECOND,
			ROUTE_SHOP_COMMAND_RATE_BURST
		)
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
	if not _route.configure_multiplayer_players(
		local_peer_id,
		player_names.duplicate(),
		character_ids.duplicate(),
		participant_stable_keys
	):
		return false
	if _run_state == null:
		return false
	# 与 MpGame 保持相同生命周期：进入多人运行时绑定本机 peer；切场不清空，
	# 让路线、战斗与遭遇继续共享同一背包。
	_run_state.set_active_multiplayer_peer(local_peer_id)
	return true


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
	net_route_avatar_input.rpc_id(
		host_peer_id,
		_client_avatar_sequence,
		_route.get_route_revision(),
		packed_pose
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
			net_route_avatar_snapshot.rpc_id(
				peer_id,
				_host_avatar_snapshot_sequence,
				route_revision,
				packed_states
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
	var sender_id := multiplayer.get_remote_sender_id()
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
	var sender_id := multiplayer.get_remote_sender_id()
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
	var sender_id := multiplayer.get_remote_sender_id()
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
		multiplayer.get_remote_sender_id(),
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
	net_route_encounter_snapshot.rpc_id(
		peer_id,
		encounter_state.duplicate(true),
		economy_state.duplicate(true)
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
	var sender_id := multiplayer.get_remote_sender_id()
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
	var sender_id := multiplayer.get_remote_sender_id()
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
	var sender_id := multiplayer.get_remote_sender_id()
	# 退出回执关闭本地 UI 后没有人工重试入口，不能与高频买卖共用会
	# 静默耗尽的 token bucket；仍严格要求已注册、可发送的 RPC sender。
	if not _is_registered_route_peer(sender_id):
		return
	_route.host_submit_shop_exit(
		sender_id,
		occurrence_key,
		expected_session_revision
	)


@rpc("authority", "call_remote", "reliable", 0)
func net_shop_snapshot(shop_state: Dictionary) -> void:
	_apply_shop_snapshot_from_peer(
		multiplayer.get_remote_sender_id(),
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
	var sender_id := multiplayer.get_remote_sender_id()
	if (
		sender_id <= 0
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
	net_route_avatar_corrected.rpc_id(
		peer_id,
		_route.get_route_revision(),
		packed_pose
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
		or multiplayer.get_remote_sender_id() != _get_host_peer_id()
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
		or multiplayer.get_remote_sender_id() != _get_host_peer_id()
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


func _reset_avatar_sync_state() -> void:
	_client_avatar_sequence = 0
	_last_host_avatar_snapshot_sequence = 0
	_last_client_avatar_sequences.clear()
	_last_avatar_correction_times_msec.clear()
	_last_avatar_correction_sequences.clear()
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
	var sender_id := multiplayer.get_remote_sender_id()
	if not _admit_route_repair_request(sender_id):
		return
	_send_full_snapshot_to_peer(sender_id)


@rpc("authority", "call_remote", "reliable", 0)
func net_route_full_snapshot(
	layout: Dictionary,
	state: Dictionary,
	encounter_state: Dictionary,
	economy_state: Dictionary,
	shop_state: Dictionary
) -> void:
	_apply_full_snapshot_from_peer(
		multiplayer.get_remote_sender_id(),
		layout,
		state,
		encounter_state,
		economy_state,
		shop_state
	)


func _apply_full_snapshot_from_peer(
	sender_id: int,
	layout: Dictionary,
	state: Dictionary,
	encounter_state: Dictionary,
	economy_state: Dictionary,
	shop_state: Dictionary = {}
) -> bool:
	if (
		not _is_client()
		or sender_id != _get_host_peer_id()
		or _route == null
	):
		return false
	if (
		layout.is_empty()
		or state.is_empty()
		or encounter_state.is_empty()
		or economy_state.is_empty()
	):
		_schedule_full_snapshot_retry()
		return false
	if not _route.apply_full_snapshot(
		layout.duplicate(true),
		state.duplicate(true),
		encounter_state.duplicate(true),
		economy_state.duplicate(true),
		shop_state.duplicate(true)
	):
		_schedule_full_snapshot_retry()
		return false
	if not _route.is_route_ready():
		_schedule_full_snapshot_retry()
		return false
	_reset_snapshot_request_state()
	_reset_avatar_validation_positions()
	_latest_encounter_snapshot = encounter_state.duplicate(true)
	_latest_economy_snapshot = economy_state.duplicate(true)
	_latest_shop_snapshot = shop_state.duplicate(true)
	_reconcile_pending_shop_exit_ack(shop_state)
	_prune_client_inventory_states_to_connected_players()
	return true


func _prune_client_inventory_states_to_connected_players() -> int:
	if not is_inside_tree() or not _is_client() or _net_manager == null:
		return 0
	if _run_state == null:
		return 0
	var connected_players := _net_manager.connected_players
	var allowed_peer_ids := PackedInt32Array()
	for raw_peer_id in connected_players.keys():
		var peer_id := int(raw_peer_id)
		if peer_id > 0:
			allowed_peer_ids.append(peer_id)
	allowed_peer_ids.sort()
	return _run_state.prune_multiplayer_peer_states(allowed_peer_ids)


@rpc("authority", "call_remote", "reliable", 0)
func net_route_move_delta(delta: Dictionary) -> void:
	_apply_move_delta_from_peer(multiplayer.get_remote_sender_id(), delta)


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
		multiplayer.get_remote_sender_id(),
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
	var sender_id := multiplayer.get_remote_sender_id()
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
	if _net_manager != null:
		_net_manager.disconnect_from_game()
	_return_to_lobby()


func _return_to_lobby() -> void:
	if _return_scheduled:
		return
	_return_scheduled = true
	call_deferred("_change_to_lobby")


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
