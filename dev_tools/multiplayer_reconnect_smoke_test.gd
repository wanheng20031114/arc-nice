extends SceneTree

const GAME_SCENE := preload("res://scene/game_modes/tower_defense/tower_defense_game.tscn")
const STANDARD_GAME_SCENE := preload(
	"res://scene/game_modes/standard/standard_game.tscn"
)
const NET_CONSTANTS := preload("res://scene/multiplayer/net_constants.gd")
const MP_GAME_SCRIPT := preload("res://scene/multiplayer/mp_game.gd")
const NET_MANAGER_SOURCE_PATH := "res://scene/multiplayer/net_manager.gd"
const WOOD_MATERIAL: PickupConfig = preload(
	"res://resources/config/materials/material_wood.tres"
)

const HOST_PEER_ID := 101
const OLD_PEER_ID := 202
const FATE_BYSTANDER_PEER_ID := 250
const FATE_BYSTANDER_RECONNECTED_PEER_ID := 260
const NEW_PEER_ID := 303
const ROGUE_RECONNECTED_PEER_ID := 313
const FATE_RECONNECTED_PEER_ID := 707
const POST_FATE_RECONNECTED_PEER_ID := 909
const RESTORED_POSITION := Vector2(384.0, 256.0)
const CLIENT_LOCAL_PEER_ID := 404
const UNSEEN_OLD_PEER_ID := 505
const UNSEEN_NEW_PEER_ID := 606


class HostNetManagerStub:
	extends NetManagerStore
	var projection_termination_count := 0
	var projection_termination_peer_id := 0

	func is_host() -> bool:
		return true

	func get_local_peer_id() -> int:
		return HOST_PEER_ID

	func get_session_participant_incarnation(peer_id: int) -> int:
		return peer_id if peer_id > 0 else 0

	func resolve_session_participant_peer_id(participant_incarnation: int) -> int:
		return participant_incarnation if participant_incarnation > 0 else 0

	func get_game_session_incarnation() -> int:
		return 1

	func is_session_member_active(peer_id: int) -> bool:
		return peer_id > 0

	func is_gameplay_ingress_admitted(peer_id: int) -> bool:
		return peer_id > 0

	func report_reconnected_runtime_projection(
		_old_peer_id: int,
		_new_peer_id: int,
		_outcome: MultiplayerReconnectTypes.RuntimeProjectionOutcome
	) -> bool:
		return true

	func terminate_for_runtime_projection_failure(
		peer_id: int,
		_reason: String
	) -> bool:
		projection_termination_count += 1
		projection_termination_peer_id = peer_id
		return true


class ClientNetManagerStub:
	extends NetManagerStore
	var projection_termination_count := 0
	var projection_termination_peer_id := 0
	var local_peer_id := CLIENT_LOCAL_PEER_ID

	func is_host() -> bool:
		return false

	func is_client() -> bool:
		return true

	func get_local_peer_id() -> int:
		return local_peer_id

	func get_host_peer_id() -> int:
		return HOST_PEER_ID

	func get_session_participant_incarnation(peer_id: int) -> int:
		return peer_id if peer_id > 0 else 0

	func resolve_session_participant_peer_id(participant_incarnation: int) -> int:
		return participant_incarnation if participant_incarnation > 0 else 0

	func get_game_session_incarnation() -> int:
		return 1

	func is_session_member_active(peer_id: int) -> bool:
		return peer_id > 0

	func terminate_for_runtime_projection_failure(
		peer_id: int,
		_reason: String
	) -> bool:
		projection_termination_count += 1
		projection_termination_peer_id = peer_id
		return true


class ProjectionTerminationNetManagerStub:
	extends NetManagerStore

	var roster_broadcast_count := 0


	func _broadcast_player_list_to_clients() -> void:
		roster_broadcast_count += 1

	func get_local_peer_id() -> int:
		return HOST_PEER_ID

	func get_host_peer_id() -> int:
		return HOST_PEER_ID


class FailOnceReconnectRuntimeStub:
	extends TowerDefenseGame

	var restored_player: Player = null
	var projection_attempt_count := 0
	var failed_attempts_remaining := 1


	func _ready() -> void:
		pass


	func ensure_reconnected_multiplayer_player(
		_old_peer_id: int,
		new_peer_id: int,
		player_name: String,
		_character_id: StringName,
		_state: SnapshotManager.PlayerState,
		_spawn_slot_index: int,
		_reconnect_state: Dictionary = {}
	) -> CombatRuntimeBase.ReconnectedPlayerProjection:
		projection_attempt_count += 1
		if failed_attempts_remaining > 0:
			failed_attempts_remaining -= 1
			return CombatRuntimeBase.ReconnectedPlayerProjection.new(
				CombatRuntimeBase.ReconnectedPlayerProjectionStatus.CREATE_FAILED
			)
		var projection_status := (
			CombatRuntimeBase.ReconnectedPlayerProjectionStatus.EXISTING_CURRENT
		)
		if restored_player == null:
			restored_player = PlayerCharacterRegistry.instantiate_character(
				PlayerCharacterRegistry.WEISHIDAIER_ID
			) as Player
			projection_status = (
				CombatRuntimeBase.ReconnectedPlayerProjectionStatus.CREATED
			)
		restored_player.peer_id = new_peer_id
		restored_player.multiplayer_display_name = player_name
		return CombatRuntimeBase.ReconnectedPlayerProjection.new(
			projection_status,
			restored_player
		)


class RebuiltClientRuntimeStub:
	extends CombatRuntimeBase


	func configure_multiplayer(
		_mode: int,
		_local_peer_id: int,
		_player_names: Dictionary,
		_player_character_ids: Dictionary = {}
	) -> void:
		pass

	func get_player_for_peer(peer_id: int) -> Player:
		return peer_players.get(peer_id) as Player

	func get_enemy_for_net_id(_net_id: int) -> Enemy:
		return null

	func get_pickup_for_net_id(_net_id: int) -> Pickup:
		return null

	func remove_multiplayer_player(peer_id: int) -> void:
		peer_players.erase(peer_id)

	func collect_player_snapshot_states() -> Array[SnapshotManager.PlayerState]:
		return []

	func collect_enemy_snapshot_states() -> Array[SnapshotManager.EnemyState]:
		return []

	func play_remote_enemy_spawn_effect(_spawn_global_position: Vector2) -> void:
		pass


class PeerLedgerClaimProbe:
	extends MpPeerLedgerCoordinator

	var run_state: RunStateStore = null
	var old_peer_id := 0
	var claim_saw_remapped_identity := false


	func remap_authenticated_peer(
		_generation: int,
		_old_peer_id: int,
		new_peer_id: int,
		_now_msec: int = -1
	) -> Dictionary:
		return {
			"accepted": (
				run_state != null
				and not run_state.has_multiplayer_peer_state(old_peer_id)
				and run_state.has_multiplayer_peer_state(new_peer_id)
			),
			"reason": &"",
		}


	func claim_authenticated_peer(
		_generation: int,
		peer_id: int,
		_now_msec: int = -1
	) -> Dictionary:
		claim_saw_remapped_identity = (
			run_state != null
			and not run_state.has_multiplayer_peer_state(old_peer_id)
			and run_state.has_multiplayer_peer_state(peer_id)
		)
		return {
			"accepted": true,
			"committed": 0,
			"rejected": 0,
		}


var failures: Array[String] = []
var reconnect_deadline_events: Array[PackedInt32Array] = []
var lobby_registration_events: Array[int] = []
var fixture_teleport_player_coordinator: MpPlayerCoordinator = null
var fixture_authoritative_teleport_broadcasts: Array[Dictionary] = []


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	await _test_reconnect_token_contract()
	_test_reconnect_identity_rpc_recipient_contract()
	_test_projection_termination_stops_reconnect_completion()
	_test_late_loaded_report_cannot_revive_timed_out_reconnect()
	_test_lobby_ingress_is_bounded_and_idempotent()
	await _test_observer_reuses_precreated_reconnect_target()
	_test_failed_player_projection_keeps_retry_state()
	_test_embedded_projection_survives_two_transport_reconnects()
	_test_player_projection_retry_exhaustion_terminates_session()
	_test_corrupt_ingress_capture_never_exposes_player_projection()
	await _test_authoritative_player_state_remap()
	await _test_embedded_client_restores_unseen_participant()
	await _cleanup_root()
	if failures.is_empty():
		print("MULTIPLAYER_RECONNECT_SMOKE_TEST_OK")
		quit()
		return
	for failure in failures:
		push_error(failure)
	quit(1)


func _test_reconnect_token_contract() -> void:
	var net_manager := NetManagerStore.new()
	root.add_child(net_manager)
	await process_frame
	_expect(
		net_manager.local_reconnect_token.length()
		== NetManagerStore.RECONNECT_TOKEN_HEX_LENGTH
		and net_manager.call(
			"_is_valid_reconnect_token",
			net_manager.local_reconnect_token
		),
		"NetManager must generate a private 128-bit reconnect identity."
	)
	_expect(
		not net_manager.set_local_reconnect_token("short")
		and net_manager.set_local_reconnect_token(
			"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
		),
		"Reconnect identities must reject malformed values and accept 32 lowercase hex characters."
	)
	net_manager.queue_free()
	await process_frame


func _test_reconnect_identity_rpc_recipient_contract() -> void:
	var source := FileAccess.get_file_as_string(NET_MANAGER_SOURCE_PATH)
	var identity_source := _extract_function_source(
		source,
		"_announce_reconnected_identity"
	)
	var ready_source := _extract_function_source(
		source,
		"_try_publish_completed_peer_reconnect"
	)
	var identity_rpc_index := identity_source.find(
		"_rpc_player_reconnected.rpc_id("
	)
	var prepare_index := ready_source.find(
		"_run_reconnect_delivery_preparation("
	)
	var activate_index := ready_source.find(
		"_activate_reconnecting_session_member(new_peer_id)"
	)
	var roster_index := ready_source.find(
		"_broadcast_player_list_to_clients()"
	)
	var host_ready_index := ready_source.find(
		"\n\t_send_reconnect_game_ready_to_peer(new_peer_id)"
	)
	var ready_notice_index := ready_source.find(
		"player_reconnect_ready.emit("
	)
	_expect(
		not identity_source.is_empty()
		and not ready_source.is_empty()
		and identity_rpc_index >= 0
		and identity_source.find("or peer_id == new_peer_id") >= 0
		and prepare_index >= 0
		and prepare_index < activate_index
		and activate_index < roster_index
		and roster_index < host_ready_index
		and host_ready_index < ready_notice_index
		and ready_source.find("runtime_projection_outcome") >= 0,
		(
			"NetManager 只能把 old→new 发给持有旧 roster 的既有观察者；"
			+ "重连者本人由 setup 建立身份，且 prepare 必须先于 ACTIVE/roster/"
			+ "host-ready/最终通知。"
		)
	)


func _test_projection_termination_stops_reconnect_completion() -> void:
	const FIXTURE_OLD_PEER_ID := 1101
	const FIXTURE_NEW_PEER_ID := 1102
	const FIXTURE_TOKEN := "abababababababababababababababab"
	var net_manager := ProjectionTerminationNetManagerStub.new()
	net_manager.net_role = NetManagerStore.NetRole.HOST
	net_manager.connection_state = NetManagerStore.ConnectionState.IN_GAME
	net_manager.loading_session_id = 91
	_expect(
		net_manager._register_active_session_member(
			FIXTURE_OLD_PEER_ID,
			"ProjectionTarget",
			PlayerCharacterRegistry.WEISHIDAIER_ID,
			true,
			FIXTURE_TOKEN
		),
		"投影终止夹具必须先建立旧身份会话成员。"
	)
	var suspended_member := (
		net_manager._session_members[FIXTURE_OLD_PEER_ID] as Dictionary
	)
	suspended_member["state"] = int(
		NetManagerStore.SessionMemberState.SUSPENDED_GRACE
	)
	suspended_member["grace_expires_msec"] = Time.get_ticks_msec() + 10_000
	net_manager._session_members[FIXTURE_OLD_PEER_ID] = suspended_member
	net_manager.connected_players[FIXTURE_NEW_PEER_ID] = "ProjectionTarget"
	net_manager.connected_player_characters[FIXTURE_NEW_PEER_ID] = (
		PlayerCharacterRegistry.WEISHIDAIER_ID
	)
	net_manager.confirmed_character_peers[FIXTURE_NEW_PEER_ID] = true
	net_manager._peer_reconnect_tokens[FIXTURE_NEW_PEER_ID] = FIXTURE_TOKEN
	net_manager._pending_reconnect_loads[FIXTURE_NEW_PEER_ID] = {
		"old_peer_id": FIXTURE_OLD_PEER_ID,
		"token": FIXTURE_TOKEN,
		"deadline_msec": Time.get_ticks_msec() + 5_000,
	}
	var player_list_changed_count := [0]
	net_manager.player_list_changed.connect(func() -> void:
		player_list_changed_count[0] = int(player_list_changed_count[0]) + 1
	)
	net_manager.player_reconnected.connect(
		func(
			_old_peer_id: int,
			new_peer_id: int,
			_player_name: String,
			_character_id: StringName,
			_membership_revision: int
		) -> void:
			net_manager.terminate_for_runtime_projection_failure(
				new_peer_id,
				"fixture projection failure"
			)
	)
	net_manager._complete_peer_reconnect(FIXTURE_NEW_PEER_ID)
	_expect(
		net_manager.roster_broadcast_count == 1
		and int(player_list_changed_count[0]) == 0
		and net_manager._forced_final_departure_peer_ids.has(
			FIXTURE_NEW_PEER_ID
		)
		and not net_manager._session_members.has(FIXTURE_OLD_PEER_ID)
		and not net_manager._session_members.has(FIXTURE_NEW_PEER_ID),
		(
			"player_reconnected 同步终止投影后，只能发布一次 final roster，"
			+ "完成流程不得继续发送旧 roster、ready 或 player_list_changed。"
		)
	)
	net_manager._on_peer_disconnected(FIXTURE_NEW_PEER_ID)
	_expect(
		net_manager._disconnected_reconnect_slots.is_empty()
		and net_manager._session_members.is_empty()
		and not net_manager._forced_final_departure_peer_ids.has(
			FIXTURE_NEW_PEER_ID
		),
		"投影强制终止后的物理断线必须保持 final departure，不得重新创建 grace。"
	)
	net_manager.free()


func _test_observer_reuses_precreated_reconnect_target() -> void:
	const FIXTURE_OLD_PEER_ID := 1202
	const FIXTURE_NEW_PEER_ID := 1303
	var run_state := root.get_node("RunState") as RunStateStore
	run_state.begin_new_run(&"weishidaier", false)
	_expect(
		run_state.register_multiplayer_peer_states(PackedInt32Array([
			CLIENT_LOCAL_PEER_ID,
			FIXTURE_OLD_PEER_ID,
		])),
		"既有观察者夹具必须只注册认证过的 old identity。"
	)
	_expect(
		run_state.try_add_item_count_for_peer(
			FIXTURE_OLD_PEER_ID,
			WOOD_MATERIAL,
			1
		),
		"既有观察者夹具必须在 old-id 账本保存权威背包。"
	)
	var old_inventory_revision := run_state.get_inventory_revision_for_peer(
		FIXTURE_OLD_PEER_ID
	)
	var membership_revision := _next_membership_revision(run_state)
	var runtime := STANDARD_GAME_SCENE.instantiate() as StandardGame
	runtime.auto_start_waves = false
	runtime.configure_multiplayer(
		CombatRuntimeBase.RuntimeMode.CLIENT_VIEW,
		CLIENT_LOCAL_PEER_ID,
		{
			CLIENT_LOCAL_PEER_ID: "Observer",
			FIXTURE_NEW_PEER_ID: "SetupTarget",
		},
		{
			CLIENT_LOCAL_PEER_ID: PlayerCharacterRegistry.WEISHIDAIER_ID,
			FIXTURE_NEW_PEER_ID: PlayerCharacterRegistry.WEISHIDAIER_ID,
		}
	)
	root.add_child(runtime)
	await process_frame
	await process_frame
	var precreated_player := runtime.get_player_for_peer(
		FIXTURE_NEW_PEER_ID
	) as Player
	_expect(
		precreated_player != null,
		"既有观察者 setup 必须真实预创建 new-id Player 投影。"
	)
	var peer_restored_events: Array[PackedInt32Array] = []
	runtime.player_roster_coordinator.peer_restored.connect(
		func(old_peer_id: int, new_peer_id: int) -> void:
			peer_restored_events.append(
				PackedInt32Array([old_peer_id, new_peer_id])
			)
	)
	var mp_game := MP_GAME_SCRIPT.new()
	var net_stub := ClientNetManagerStub.new()
	var ledger_probe := PeerLedgerClaimProbe.new()
	ledger_probe.run_state = run_state
	ledger_probe.old_peer_id = FIXTURE_OLD_PEER_ID
	mp_game.game = runtime
	mp_game.run_state = run_state
	mp_game.net_manager = net_stub
	_bind_multiplayer_runtime(mp_game, runtime)
	mp_game.peer_ledger_coordinator = ledger_probe
	mp_game.set("_peer_ledger_generation", 1)
	mp_game.call(
		"_on_net_player_reconnected",
		FIXTURE_OLD_PEER_ID,
		FIXTURE_NEW_PEER_ID,
		"TargetNew",
		PlayerCharacterRegistry.WEISHIDAIER_ID,
		membership_revision
	)
	var converged_player := runtime.get_player_for_peer(
		FIXTURE_NEW_PEER_ID
	) as Player
	_expect(
		precreated_player != null
		and is_same(precreated_player, converged_player)
		and converged_player.peer_id == FIXTURE_NEW_PEER_ID
		and converged_player.multiplayer_display_name == "TargetNew"
		and not run_state.has_multiplayer_peer_state(FIXTURE_OLD_PEER_ID)
		and run_state.has_multiplayer_peer_state(FIXTURE_NEW_PEER_ID)
		and run_state.get_inventory_revision_for_peer(FIXTURE_NEW_PEER_ID)
		== old_inventory_revision
		and run_state.get_inventory_item_total_for_peer(
			FIXTURE_NEW_PEER_ID,
			WOOD_MATERIAL
		) == 1
		and ledger_probe.claim_saw_remapped_identity,
		(
			"场景即使已见到 new-id Player，也只能复用表现节点；持久 old-id 账本"
			+ "必须整体迁移到空目标，并在身份收敛后认领 CH6。"
		)
	)
	mp_game.call(
		"_on_net_player_reconnected",
		FIXTURE_OLD_PEER_ID,
		FIXTURE_NEW_PEER_ID,
		"TargetNew",
		PlayerCharacterRegistry.WEISHIDAIER_ID,
		membership_revision
	)
	_expect(
		is_same(
			precreated_player,
			runtime.get_player_for_peer(FIXTURE_NEW_PEER_ID)
		)
		and peer_restored_events.is_empty()
		and not mp_game._pending_reconnected_player_projections.has(
			FIXTURE_OLD_PEER_ID
		),
		(
			"setup 已完成出生生命周期的 new-id Player 在通知重放时必须只做"
			+ "幂等校准，不得伪造 peer_restored 或重复进入恢复事务。"
		)
	)
	ledger_probe.free()
	net_stub.free()
	mp_game.free()
	runtime.queue_free()
	await process_frame


func _test_failed_player_projection_keeps_retry_state() -> void:
	const FIXTURE_OLD_PEER_ID := 1404
	const FIXTURE_NEW_PEER_ID := 1505
	const CONFLICTING_NEW_PEER_ID := 1506
	var run_state := RunStateStore.new()
	run_state.begin_new_run(&"weishidaier", false)
	_expect(
		run_state.register_multiplayer_peer_state(FIXTURE_OLD_PEER_ID),
		"投影重试夹具必须建立唯一 old-id 身份账本。"
	)
	var mp_game := MP_GAME_SCRIPT.new()
	var runtime := FailOnceReconnectRuntimeStub.new()
	var net_stub := ClientNetManagerStub.new()
	var player_coordinator := MpPlayerCoordinator.new()
	var merchant_coordinator := MpMerchantTransactionsCoordinator.new()
	var ledger_probe := PeerLedgerClaimProbe.new()
	ledger_probe.run_state = run_state
	ledger_probe.old_peer_id = FIXTURE_OLD_PEER_ID
	mp_game.game = runtime
	mp_game.run_state = run_state
	mp_game.net_manager = net_stub
	mp_game.player_coordinator = player_coordinator
	mp_game.merchant_transactions_coordinator = merchant_coordinator
	mp_game.peer_ledger_coordinator = ledger_probe
	mp_game.set("_peer_ledger_generation", 1)
	mp_game._disconnected_player_reconnect_states[FIXTURE_OLD_PEER_ID] = {
		"spawn_slot_index": 2,
	}
	var membership_revision := _next_membership_revision(run_state)
	mp_game.call(
		"_on_net_player_reconnected",
		FIXTURE_OLD_PEER_ID,
		FIXTURE_NEW_PEER_ID,
		"RetryTarget",
		PlayerCharacterRegistry.WEISHIDAIER_ID,
		membership_revision
	)
	_expect(
		runtime.projection_attempt_count == 1
		and mp_game._disconnected_player_reconnect_states.has(
			FIXTURE_OLD_PEER_ID
		)
		and not run_state.has_multiplayer_peer_state(FIXTURE_OLD_PEER_ID)
		and run_state.has_multiplayer_peer_state(FIXTURE_NEW_PEER_ID),
		(
			"Player 投影首次失败后必须保留唯一 reconnect capture，同时保持"
			+ "已经提交的 new-id 身份，禁止假设 runtime repair 会凭空创建节点。"
		)
	)
	_expect(
		mp_game._pending_reconnected_player_projections.has(
			FIXTURE_OLD_PEER_ID
		),
		"首次失败必须登记有界 Player 投影重试，而不是等待不存在的第二份 CH0。"
	)
	mp_game.call(
		"_on_net_player_reconnected",
		FIXTURE_OLD_PEER_ID,
		CONFLICTING_NEW_PEER_ID,
		"ConflictingTarget",
		PlayerCharacterRegistry.WEISHIDAIER_ID,
		membership_revision
	)
	_expect(
		runtime.projection_attempt_count == 1
		and not run_state.has_multiplayer_peer_state(CONFLICTING_NEW_PEER_ID)
		and int(
			mp_game._pending_reconnected_player_projections[
				FIXTURE_OLD_PEER_ID
			].get("new_peer_id", 0)
		) == FIXTURE_NEW_PEER_ID,
		"pending old identity 必须在提交账本前拒绝一对多 new-id 映射。"
	)
	mp_game.call(
		"_update_pending_reconnected_player_projections",
		MP_GAME_SCRIPT.PLAYER_PROJECTION_RETRY_INTERVAL_SECONDS
	)
	_expect(
		runtime.projection_attempt_count == 2
		and runtime.restored_player != null
		and not mp_game._pending_reconnected_player_projections.has(
			FIXTURE_OLD_PEER_ID
		)
		and not mp_game._disconnected_player_reconnect_states.has(
			FIXTURE_OLD_PEER_ID
		),
		"MpGame 自身轮询必须消费保留状态并完成 Player 投影，无需重放 CH0。"
	)
	if runtime.restored_player != null:
		runtime.restored_player.free()
	ledger_probe.free()
	merchant_coordinator.free()
	player_coordinator.free()
	net_stub.free()
	runtime.free()
	mp_game.free()
	run_state.free()


func _test_embedded_projection_survives_two_transport_reconnects() -> void:
	const FIRST_OLD_PEER_ID := 1414
	const FIRST_NEW_PEER_ID := 1515
	const SECOND_NEW_PEER_ID := 1616
	var run_state := RunStateStore.new()
	run_state.begin_new_run(&"weishidaier", false)
	_expect(
		run_state.register_multiplayer_peer_state(FIRST_OLD_PEER_ID),
		"两跳重连夹具必须建立唯一的初始战斗参与身份。"
	)
	var mp_game := MP_GAME_SCRIPT.new()
	mp_game.embedded_runtime = true
	_expect(
		mp_game.configure_embedded_participant_roster(
			PackedInt32Array([FIRST_OLD_PEER_ID])
		),
		"两跳重连夹具必须冻结初始内嵌战斗 roster。"
	)
	var runtime := FailOnceReconnectRuntimeStub.new()
	var net_stub := ClientNetManagerStub.new()
	var player_coordinator := MpPlayerCoordinator.new()
	var merchant_coordinator := MpMerchantTransactionsCoordinator.new()
	var ledger_probe := PeerLedgerClaimProbe.new()
	ledger_probe.run_state = run_state
	ledger_probe.old_peer_id = FIRST_OLD_PEER_ID
	mp_game.game = runtime
	mp_game.run_state = run_state
	mp_game.net_manager = net_stub
	mp_game.player_coordinator = player_coordinator
	mp_game.merchant_transactions_coordinator = merchant_coordinator
	mp_game.peer_ledger_coordinator = ledger_probe
	mp_game.set("_peer_ledger_generation", 1)
	mp_game._disconnected_player_reconnect_states[FIRST_OLD_PEER_ID] = {
		"spawn_slot_index": 0,
	}
	mp_game.call(
		"_on_net_player_reconnected",
		FIRST_OLD_PEER_ID,
		FIRST_NEW_PEER_ID,
		"FirstTransport",
		PlayerCharacterRegistry.WEISHIDAIER_ID,
		_next_membership_revision(run_state)
	)
	_expect(
		runtime.projection_attempt_count == 1
		and not mp_game._embedded_participant_peer_ids.has(FIRST_OLD_PEER_ID)
		and mp_game._embedded_participant_peer_ids.has(FIRST_NEW_PEER_ID)
		and mp_game._projecting_embedded_participant_peer_ids.has(
			FIRST_NEW_PEER_ID
		)
		and mp_game._pending_reconnected_player_projections.has(
			FIRST_OLD_PEER_ID
		),
		(
			"第一次 Player 创建失败后，canonical combat identity 必须立即推进到"
			+ " new peer，并由独立 PROJECTING 租约关闭战斗能力。"
		)
	)
	_expect(
		bool(mp_game.call(
			"_rebase_reconnect_projection_state_for_disconnected_peer",
			FIRST_NEW_PEER_ID
		))
		and not mp_game._pending_reconnected_player_projections.has(
			FIRST_OLD_PEER_ID
		)
		and not mp_game._disconnected_player_reconnect_states.has(
			FIRST_OLD_PEER_ID
		)
		and mp_game._disconnected_player_reconnect_states.has(FIRST_NEW_PEER_ID),
		(
			"投影完成前 new transport 再断线时必须取消旧轮询，并把唯一 capture"
			+ "重键到当前 canonical identity。"
		)
	)
	mp_game.call(
		"_on_net_player_reconnected",
		FIRST_NEW_PEER_ID,
		SECOND_NEW_PEER_ID,
		"SecondTransport",
		PlayerCharacterRegistry.WEISHIDAIER_ID,
		_next_membership_revision(run_state)
	)
	mp_game.call(
		"_update_pending_reconnected_player_projections",
		MP_GAME_SCRIPT.PLAYER_PROJECTION_RETRY_INTERVAL_SECONDS
	)
	_expect(
		runtime.projection_attempt_count == 2
		and runtime.restored_player != null
		and runtime.restored_player.peer_id == SECOND_NEW_PEER_ID
		and not mp_game._embedded_participant_peer_ids.has(FIRST_OLD_PEER_ID)
		and not mp_game._embedded_participant_peer_ids.has(FIRST_NEW_PEER_ID)
		and mp_game._embedded_participant_peer_ids.has(SECOND_NEW_PEER_ID)
		and not mp_game._projecting_embedded_participant_peer_ids.has(
			SECOND_NEW_PEER_ID
		)
		and not mp_game._pending_reconnected_player_projections.has(
			FIRST_NEW_PEER_ID
		)
		and not mp_game._disconnected_player_reconnect_states.has(
			FIRST_NEW_PEER_ID
		)
		and run_state.has_multiplayer_peer_state(SECOND_NEW_PEER_ID),
		(
			"连续 2→7→8 transport 重连必须只恢复最终身份，不得留下祖先 roster、"
			+ "陈旧轮询或幽灵 Player。"
		)
	)
	if runtime.restored_player != null:
		runtime.restored_player.free()
	ledger_probe.free()
	merchant_coordinator.free()
	player_coordinator.free()
	net_stub.free()
	runtime.free()
	mp_game.free()
	run_state.free()


func _test_player_projection_retry_exhaustion_terminates_session() -> void:
	const FIXTURE_OLD_PEER_ID := 1606
	const FIXTURE_NEW_PEER_ID := 1707
	var run_state := RunStateStore.new()
	run_state.begin_new_run(&"weishidaier", false)
	run_state.register_multiplayer_peer_state(FIXTURE_OLD_PEER_ID)
	var mp_game := MP_GAME_SCRIPT.new()
	var runtime := FailOnceReconnectRuntimeStub.new()
	runtime.failed_attempts_remaining = 100
	var net_stub := ClientNetManagerStub.new()
	var player_coordinator := MpPlayerCoordinator.new()
	var merchant_coordinator := MpMerchantTransactionsCoordinator.new()
	var ledger_probe := PeerLedgerClaimProbe.new()
	ledger_probe.run_state = run_state
	ledger_probe.old_peer_id = FIXTURE_OLD_PEER_ID
	mp_game.game = runtime
	mp_game.run_state = run_state
	mp_game.net_manager = net_stub
	mp_game.player_coordinator = player_coordinator
	mp_game.merchant_transactions_coordinator = merchant_coordinator
	mp_game.peer_ledger_coordinator = ledger_probe
	mp_game.set("_peer_ledger_generation", 1)
	mp_game._disconnected_player_reconnect_states[FIXTURE_OLD_PEER_ID] = {
		"spawn_slot_index": 1,
	}
	mp_game.call(
		"_on_net_player_reconnected",
		FIXTURE_OLD_PEER_ID,
		FIXTURE_NEW_PEER_ID,
		"NeverReady",
		PlayerCharacterRegistry.WEISHIDAIER_ID,
		_next_membership_revision(run_state)
	)
	for _attempt in range(MP_GAME_SCRIPT.PLAYER_PROJECTION_MAX_ATTEMPTS + 1):
		mp_game.call(
			"_update_pending_reconnected_player_projections",
			MP_GAME_SCRIPT.PLAYER_PROJECTION_RETRY_INTERVAL_SECONDS
		)
	_expect(
		net_stub.projection_termination_count == 1
		and net_stub.projection_termination_peer_id == FIXTURE_NEW_PEER_ID
		and not mp_game._pending_reconnected_player_projections.has(
			FIXTURE_OLD_PEER_ID
		)
		and not mp_game._disconnected_player_reconnect_states.has(
			FIXTURE_OLD_PEER_ID
		)
		and runtime.projection_attempt_count
		== MP_GAME_SCRIPT.PLAYER_PROJECTION_MAX_ATTEMPTS,
		"Player 投影重试超限后必须恰好终止一次故障会话并释放终局状态。"
	)
	ledger_probe.free()
	merchant_coordinator.free()
	player_coordinator.free()
	net_stub.free()
	runtime.free()
	mp_game.free()
	run_state.free()


func _test_corrupt_ingress_capture_never_exposes_player_projection() -> void:
	const FIXTURE_OLD_PEER_ID := 1808
	const FIXTURE_NEW_PEER_ID := 1909
	var run_state := RunStateStore.new()
	run_state.begin_new_run(&"weishidaier", false)
	run_state.register_multiplayer_peer_state(FIXTURE_OLD_PEER_ID)
	var mp_game := MP_GAME_SCRIPT.new()
	var runtime := FailOnceReconnectRuntimeStub.new()
	runtime.failed_attempts_remaining = 0
	var net_stub := HostNetManagerStub.new()
	var player_coordinator := MpPlayerCoordinator.new()
	var merchant_coordinator := MpMerchantTransactionsCoordinator.new()
	var ledger_probe := PeerLedgerClaimProbe.new()
	ledger_probe.run_state = run_state
	ledger_probe.old_peer_id = FIXTURE_OLD_PEER_ID
	mp_game.game = runtime
	mp_game.run_state = run_state
	mp_game.net_manager = net_stub
	mp_game.player_coordinator = player_coordinator
	mp_game.merchant_transactions_coordinator = merchant_coordinator
	mp_game.peer_ledger_coordinator = ledger_probe
	mp_game.set("_peer_ledger_generation", 1)
	var captured_player_state := SnapshotManager.PlayerState.new()
	captured_player_state.peer_id = FIXTURE_OLD_PEER_ID
	captured_player_state.character_id = PlayerCharacterRegistry.WEISHIDAIER_ID
	captured_player_state.max_health = 100
	captured_player_state.current_health = 100
	mp_game._disconnected_player_reconnect_states[FIXTURE_OLD_PEER_ID] = {
		"spawn_slot_index": 1,
		# 缺失 Dash 冷却是明确损坏，而不是可采用默认值的旧格式。
	}
	mp_game.call(
		"_on_net_player_reconnected",
		FIXTURE_OLD_PEER_ID,
		FIXTURE_NEW_PEER_ID,
		"CorruptIngress",
		PlayerCharacterRegistry.WEISHIDAIER_ID,
		_next_membership_revision(run_state)
	)
	_expect(
		runtime.projection_attempt_count == 0
		and runtime.restored_player == null
		and not mp_game._pending_reconnected_player_projections.has(
			FIXTURE_OLD_PEER_ID
		)
		and mp_game._disconnected_player_reconnect_states.has(
			FIXTURE_OLD_PEER_ID
		)
		and net_stub.projection_termination_count == 1
		and net_stub.projection_termination_peer_id == FIXTURE_NEW_PEER_ID,
		(
			"Host 必须先校验权威快照再创建 Player；永久损坏必须同步 fail-close，"
			+ "不得伪装成可通过轮询恢复的暂时错误。"
		)
	)
	ledger_probe.free()
	merchant_coordinator.free()
	player_coordinator.free()
	net_stub.free()
	runtime.free()
	mp_game.free()
	run_state.free()


func _test_late_loaded_report_cannot_revive_timed_out_reconnect() -> void:
	var net_manager := NetManagerStore.new()
	net_manager.net_role = NetManagerStore.NetRole.HOST
	net_manager.connection_state = NetManagerStore.ConnectionState.IN_GAME
	net_manager.loading_session_id = 73
	net_manager.connected_players[NEW_PEER_ID] = "Reconnect"
	net_manager.connected_player_characters[NEW_PEER_ID] = &"weishidaier"
	net_manager.confirmed_character_peers[NEW_PEER_ID] = true
	net_manager._peer_reconnect_tokens[NEW_PEER_ID] = (
		"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
	)
	net_manager._pending_reconnect_loads[NEW_PEER_ID] = {
		"old_peer_id": OLD_PEER_ID,
		"token": "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
		"deadline_msec": 10_000,
		"grace_expires_msec": 20_000,
		"phase": int(NetManagerStore.ReconnectPendingPhase.LOADING),
	}
	reconnect_deadline_events.clear()
	net_manager.player_reconnected.connect(
		_on_deadline_fixture_player_reconnected
	)

	var eligible_before_deadline := bool(
		net_manager._can_complete_pending_reconnect_load(
			NEW_PEER_ID,
			73,
			9_999
		)
	)
	net_manager._handle_report_game_loaded(NEW_PEER_ID, 73, 10_001)
	var pending := (
		net_manager._pending_reconnect_loads[NEW_PEER_ID] as Dictionary
	)
	_expect(
		eligible_before_deadline
		and bool(pending.get("timed_out", false))
		and not net_manager._can_complete_pending_reconnect_load(
			NEW_PEER_ID,
			73,
			10_001
		)
		and net_manager._pending_reconnect_loads.has(NEW_PEER_ID)
		and reconnect_deadline_events.is_empty(),
		(
			"未等待 poll 的迟到加载报告也必须原子关闭 completion 资格，"
			+ "不得发出 player_reconnected，并保留旧身份供断线清理。"
		)
	)
	net_manager.player_reconnected.disconnect(
		_on_deadline_fixture_player_reconnected
	)
	net_manager.free()


func _on_deadline_fixture_player_reconnected(
	old_peer_id: int,
	new_peer_id: int,
	_player_name: String,
	_character_id: StringName,
	_membership_revision: int
) -> void:
	reconnect_deadline_events.append(
		PackedInt32Array([old_peer_id, new_peer_id])
	)


func _test_lobby_ingress_is_bounded_and_idempotent() -> void:
	var net_manager := NetManagerStore.new()
	net_manager.net_role = NetManagerStore.NetRole.HOST
	net_manager.connection_state = NetManagerStore.ConnectionState.HOSTING_LAN
	lobby_registration_events.clear()
	net_manager.player_joined.connect(_on_lobby_fixture_player_joined)
	var reconnect_token := "cccccccccccccccccccccccccccccccc"
	var registered := net_manager._handle_player_registration(
		OLD_PEER_ID,
		"Remote",
		"weishidaier",
		true,
		NET_CONSTANTS.PROTOCOL_VERSION,
		reconnect_token
	)
	var replayed := net_manager._handle_player_registration(
		OLD_PEER_ID,
		"MutatedName",
		"hoe_cat",
		false,
		NET_CONSTANTS.PROTOCOL_VERSION,
		"dddddddddddddddddddddddddddddddd"
	)
	var character_changed := net_manager._handle_player_character_request(
		OLD_PEER_ID,
		"hoe_cat",
		true
	)
	var no_op_character_replay := net_manager._handle_player_character_request(
		OLD_PEER_ID,
		"hoe_cat",
		true
	)

	var rate_peer_id := 707
	var admitted_at_once := 0
	for _attempt in range(int(NetManagerStore.LOBBY_COMMAND_RATE_BURST) + 1):
		if net_manager._consume_lobby_command_admission(rate_peer_id, 100.0):
			admitted_at_once += 1
	var admitted_after_refill := net_manager._consume_lobby_command_admission(
		rate_peer_id,
		101.0
	)
	_expect(
		registered
		and not replayed
		and lobby_registration_events == [OLD_PEER_ID]
		and str(net_manager.connected_players.get(OLD_PEER_ID, "")) == "Remote"
		and str(net_manager._peer_reconnect_tokens.get(OLD_PEER_ID, ""))
		== reconnect_token
		and character_changed
		and not no_op_character_replay
		and net_manager.get_player_character_id(OLD_PEER_ID)
		== PlayerCharacterRegistry.HOE_CAT_ID,
		(
			"A connected lobby identity must register once, retain its reconnect token, "
			+ "and broadcast character state only when that state actually changes."
		)
	)
	_expect(
		admitted_at_once == int(NetManagerStore.LOBBY_COMMAND_RATE_BURST)
		and admitted_after_refill,
		(
			"The shared lobby command bucket must cap one peer's immediate reliable "
			+ "ingress while refilling for legitimate later input."
		)
	)
	net_manager.player_joined.disconnect(_on_lobby_fixture_player_joined)
	net_manager.free()


func _on_lobby_fixture_player_joined(peer_id: int, _player_name: String) -> void:
	lobby_registration_events.append(peer_id)


func _test_authoritative_player_state_remap() -> void:
	var run_state := root.get_node("RunState") as RunStateStore
	run_state.begin_new_run(&"weishidaier")
	_expect(
		run_state.register_multiplayer_peer_states(PackedInt32Array([
			HOST_PEER_ID,
			OLD_PEER_ID,
			FATE_BYSTANDER_PEER_ID,
		])),
		"重连夹具必须在创建 Tower Player 前显式注册权威账本成员。"
	)
	var game := GAME_SCENE.instantiate() as TowerDefenseGame
	_disable_tower_fixture_background_loads(game)
	game.auto_start_waves = false
	game.configure_multiplayer(
		CombatRuntimeBase.RuntimeMode.HOST_AUTHORITY,
		HOST_PEER_ID,
		{
			HOST_PEER_ID: "Host",
			OLD_PEER_ID: "Reconnect",
			FATE_BYSTANDER_PEER_ID: "Bystander",
		},
		{
			HOST_PEER_ID: &"weishidaier",
			OLD_PEER_ID: &"weishidaier",
			FATE_BYSTANDER_PEER_ID: &"weishidaier",
		}
	)
	root.add_child(game)
	current_scene = game
	for _frame in 4:
		await process_frame
		await physics_frame
	var old_player := game.get_player_for_peer(OLD_PEER_ID) as Player
	_expect(old_player != null, "Reconnect fixture must create the original remote player.")
	if old_player == null:
		current_scene = null
		game.queue_free()
		return
	old_player.global_position = RESTORED_POSITION
	old_player.grant_xirang_reward(4321)
	old_player.set_multiplayer_health_state(old_player.max_health - 11, false)
	var expected_xirang := old_player.current_xirang
	var expected_health := old_player.current_health
	game.player_wave_death_counts[OLD_PEER_ID] = 2
	game.research_coordinator.player_technology_levels[OLD_PEER_ID] = 2
	var expected_wood := run_state.get_inventory_item_total_for_peer(
		OLD_PEER_ID,
		WOOD_MATERIAL
	) + 7
	_expect(
		run_state.try_add_item_count_for_peer(OLD_PEER_ID, WOOD_MATERIAL, 7),
		"Reconnect fixture must seed the authoritative peer inventory."
	)
	# Route and embedded-combat avatars share the global RunState signal. Keep a
	# route-like stale listener alive across the combat remap to prove that a
	# read-side cache refresh cannot recreate the removed old-peer ledger.
	var stale_route_player := PlayerCharacterRegistry.instantiate_character(
		PlayerCharacterRegistry.WEISHIDAIER_ID
	) as Player
	root.add_child(stale_route_player)
	await process_frame
	stale_route_player.configure_multiplayer_control(
		OLD_PEER_ID,
		false,
		"StaleRouteAvatar"
	)
	stale_route_player.set_process(false)
	stale_route_player.set_physics_process(false)

	var mp_game := MP_GAME_SCRIPT.new()
	var net_stub := HostNetManagerStub.new()
	mp_game.game = game
	mp_game.run_state = run_state
	mp_game.net_manager = net_stub
	_bind_multiplayer_runtime(mp_game, game)
	mp_game.player_coordinator.bind_player_action_dependencies(
		net_stub,
		Callable(mp_game, "_get_net_time"),
		Callable(mp_game, "_is_embedded_participant_suspended")
	)
	fixture_teleport_player_coordinator = mp_game.player_coordinator
	fixture_authoritative_teleport_broadcasts.clear()
	mp_game.player_coordinator.authoritative_teleport_broadcast_requested.connect(
		_on_fixture_authoritative_teleport_broadcast_requested
	)
	game.multiplayer_gateway.player_teleport_requested.connect(
		_on_fixture_player_teleport_requested
	)
	# Roster 的瞬时采样默认 revision=0；制造一个真实可靠生命 revision，
	# 证明断线捕获必须由 MpPlayerCoordinator 在同一事务内附上水位。
	mp_game.player_coordinator.apply_player_damage_confirmation(
		OLD_PEER_ID,
		expected_health,
		false,
		7,
		11,
		Vector2.LEFT,
		EnemyConfig.DamageType.PHYSICAL,
		false
	)
	# 先把旧 transport 推进到很高水位；真实客户端重连会重建 MpGame 与
	# PlayerCoordinator，新连接的第一帧仍然必须从 sequence=1 开始。
	for input_sequence in range(250, 5001, 250):
		mp_game.player_coordinator.handle_client_player_state(
			OLD_PEER_ID,
			input_sequence,
			old_player.global_position,
			Vector2.ZERO,
			Vector2.ZERO,
			Vector2.ZERO,
			0,
			0,
			Vector2.ZERO,
			Vector2.ZERO
		)
	var admitted_actions_at_once := 0
	for _attempt in range(int(MpPlayerCoordinator.PLAYER_ACTION_INGRESS_RATE_BURST) + 1):
		if mp_game._consume_remote_player_action_admission(
			OLD_PEER_ID,
			200.0
		):
			admitted_actions_at_once += 1
	var admitted_action_after_refill := (
		mp_game._consume_remote_player_action_admission(
			OLD_PEER_ID,
			201.0
		)
	)
	_expect(
		admitted_actions_at_once
		== int(MpPlayerCoordinator.PLAYER_ACTION_INGRESS_RATE_BURST)
		and admitted_action_after_refill,
		(
			"Reliable player actions must share a bounded per-peer ingress budget "
			+ "without blocking legitimate input after refill."
		)
	)
	var expected_revive_at := float(mp_game.call("_get_net_time")) + 5.0
	mp_game.player_coordinator._dead_player_revive_times[OLD_PEER_ID] = (
		expected_revive_at
	)
	mp_game.player_coordinator._dead_player_revive_last_seconds[OLD_PEER_ID] = 5
	mp_game.call("_on_net_player_left", OLD_PEER_ID)
	var captured_reconnect_state := (
		mp_game._disconnected_player_reconnect_states.get(OLD_PEER_ID, {})
		as Dictionary
	)
	var captured_player_state := (
		captured_reconnect_state.get("state") as SnapshotManager.PlayerState
	)
	_expect(
		captured_player_state != null
		and captured_player_state.current_health == expected_health
		and captured_player_state.health_revision == 7
		and int(captured_reconnect_state.get("health_revision", 0)) == 7
		and not captured_reconnect_state.has("player_input_sequence")
		and not captured_reconnect_state.has("dash_request_sequence"),
		"断线捕获必须保存角色与生命状态，并排除旧 transport 的请求序列。"
	)
	for _frame in 3:
		await process_frame
		await physics_frame
	_expect(
		game.get_player_for_peer(OLD_PEER_ID) == null,
		"Disconnect must remove the obsolete peer runtime before reconnect."
	)
	mp_game.call(
		"_on_net_player_reconnected",
		OLD_PEER_ID,
		NEW_PEER_ID,
		"Reconnect",
		&"weishidaier",
		_next_membership_revision(run_state)
	)
	var restored := game.get_player_for_peer(NEW_PEER_ID) as Player
	_expect(
		restored != null
		and restored.global_position == RESTORED_POSITION
		and restored.current_xirang == expected_xirang
		and restored.current_health == expected_health,
		"Reconnect must restore position, Xirang, and life state under the new ENet peer id."
	)
	_expect(
		mp_game.player_coordinator.get_last_accepted_player_input_sequence(
			NEW_PEER_ID
		) == 0
		and mp_game.player_coordinator.get_last_accepted_dash_request_sequence(
			NEW_PEER_ID
		) == 0,
		"Host 必须为 new peer 建立初始输入水位，不能迁移 old peer 的序列。"
	)

	# 建立一套全新的客户端 MpGame/Coordinator，并把它的首个真实输入包交给
	# Host；输入帧与 Dash 子序列都应从 1 开始。
	var rebuilt_client_mp_game := MP_GAME_SCRIPT.new()
	var rebuilt_client_runtime := RebuiltClientRuntimeStub.new()
	var rebuilt_client_coordinator := MpPlayerCoordinator.new()
	var rebuilt_client_session := MpSessionCoordinator.new()
	var rebuilt_client_net := ClientNetManagerStub.new()
	rebuilt_client_net.local_peer_id = NEW_PEER_ID
	rebuilt_client_mp_game.add_child(rebuilt_client_runtime)
	rebuilt_client_mp_game.add_child(rebuilt_client_coordinator)
	rebuilt_client_mp_game.add_child(rebuilt_client_session)
	rebuilt_client_mp_game.player_coordinator = rebuilt_client_coordinator
	rebuilt_client_runtime.runtime_mode = CombatRuntimeBase.RuntimeMode.CLIENT_VIEW
	rebuilt_client_runtime.multiplayer_local_peer_id = NEW_PEER_ID
	var rebuilt_client_player := Player.new()
	rebuilt_client_player.peer_id = NEW_PEER_ID
	rebuilt_client_player.global_position = restored.global_position
	rebuilt_client_player.dash_time_left = 0.1
	rebuilt_client_player.dash_distance_left = 10.0
	rebuilt_client_runtime.add_child(rebuilt_client_player)
	rebuilt_client_runtime.player = rebuilt_client_player
	rebuilt_client_runtime.peer_players[NEW_PEER_ID] = rebuilt_client_player
	rebuilt_client_coordinator.bind_runtime(rebuilt_client_runtime)
	rebuilt_client_coordinator.bind_realtime_dependencies(
		rebuilt_client_net,
		rebuilt_client_session
	)
	rebuilt_client_coordinator.bind_player_action_dependencies(
		rebuilt_client_net,
		Callable(rebuilt_client_mp_game, "_get_net_time"),
		Callable(rebuilt_client_mp_game, "_is_embedded_participant_suspended")
	)
	var rebuilt_realtime_packets: Array[Array] = []
	var rebuilt_dash_packets: Array[Array] = []
	rebuilt_client_coordinator.realtime_rpc_to_host_requested.connect(
		func(method_name: StringName, arguments: Array) -> void:
			if method_name == &"_rpc_client_player_state":
				rebuilt_realtime_packets.append(arguments.duplicate(true))
	)
	rebuilt_client_coordinator.player_action_rpc_to_host_requested.connect(
		func(method_name: StringName, arguments: Array) -> void:
			if method_name == &"net_player_dash_requested":
				rebuilt_dash_packets.append(arguments.duplicate(true))
	)
	rebuilt_client_coordinator.notify_local_player_dash_started(
		Vector2.RIGHT,
		Vector2.RIGHT,
		true
	)
	_expect(
		rebuilt_client_coordinator.send_client_input_if_needed(
			MpPlayerCoordinator.INPUT_BUTTON_DASH
		)
		and rebuilt_realtime_packets.size() == 1
		and rebuilt_dash_packets.size() == 1
		and int(rebuilt_realtime_packets[0][0]) == 1
		and int(rebuilt_realtime_packets[0][6]) == 1
		and int(rebuilt_dash_packets[0][0]) == 1,
		"重建的客户端 MpGame/Coordinator 必须从 input=1、dash=1 发出首包。"
	)
	if rebuilt_realtime_packets.size() == 1:
		var first_rebuilt_packet := rebuilt_realtime_packets[0]
		mp_game.player_coordinator.handle_client_player_state(
			NEW_PEER_ID,
			int(first_rebuilt_packet[0]),
			first_rebuilt_packet[1] as Vector2,
			first_rebuilt_packet[2] as Vector2,
			first_rebuilt_packet[3] as Vector2,
			first_rebuilt_packet[4] as Vector2,
			int(first_rebuilt_packet[5]),
			int(first_rebuilt_packet[6]),
			first_rebuilt_packet[7] as Vector2,
			first_rebuilt_packet[8] as Vector2
		)
	_expect(
		mp_game.player_coordinator.get_last_accepted_player_input_sequence(
			NEW_PEER_ID
		) == 1
		and mp_game.player_coordinator.get_last_accepted_dash_request_sequence(
			NEW_PEER_ID
		) == 1,
		"Host 必须立即接纳重建客户端的 sequence=1 输入与 Dash。"
	)
	mp_game.player_coordinator.handle_client_player_state(
		OLD_PEER_ID,
		5001,
		restored.global_position,
		Vector2.ZERO,
		Vector2.RIGHT,
		Vector2.ZERO,
		MpPlayerCoordinator.INPUT_BUTTON_DASH,
		201,
		Vector2.RIGHT,
		Vector2.RIGHT
	)
	_expect(
		mp_game.player_coordinator.get_last_accepted_player_input_sequence(
			OLD_PEER_ID
		) == 0
		and mp_game.player_coordinator.get_last_accepted_player_input_sequence(
			NEW_PEER_ID
		) == 1
		and mp_game.player_coordinator.get_last_accepted_dash_request_sequence(
			NEW_PEER_ID
		) == 1,
		"old peer 的迟到包不得推进或污染 new peer 的 transport 租约。"
	)
	rebuilt_client_mp_game.free()
	rebuilt_client_net.free()
	_expect(
		not run_state.has_multiplayer_peer_state(OLD_PEER_ID)
		and run_state.has_multiplayer_peer_state(NEW_PEER_ID)
		and run_state.get_inventory_item_total_for_peer(
			NEW_PEER_ID,
			WOOD_MATERIAL
		) == expected_wood,
		"Reconnect must atomically remap the authoritative personal inventory."
	)
	_expect(
		game.multiplayer_spawn_slot_indices.has(NEW_PEER_ID)
		and game.production_coordinator.is_personal_output_peer_available(
			NEW_PEER_ID
		)
		and int(game.player_wave_death_counts.get(NEW_PEER_ID, 0)) == 2
		and int(
			game.research_coordinator.player_technology_levels.get(
				NEW_PEER_ID,
				-1
			)
		) == 2
		and is_equal_approx(
			float(
				mp_game.player_coordinator.capture_reconnect_life_state(
					NEW_PEER_ID
				).get("revive_at", -1.0)
			),
			expected_revive_at
		),
		(
			"Reconnect must restore spawn, production, research, and pending respawn "
			+ "state. slot=%s production=%s deaths=%s research=%s revive=%s expected=%s"
		)
		% [
			game.multiplayer_spawn_slot_indices.get(NEW_PEER_ID),
			game.production_coordinator.is_personal_output_peer_available(
				NEW_PEER_ID
			),
			game.player_wave_death_counts.get(NEW_PEER_ID),
			game.research_coordinator.player_technology_levels.get(NEW_PEER_ID),
			mp_game.player_coordinator.capture_reconnect_life_state(
				NEW_PEER_ID
			).get("revive_at"),
			expected_revive_at,
		]
	)
	var rogue_coordinator := game.rogue_exploration_coordinator
	game.campaign_coordinator.replace_flow_state_for_fixture(
		CombatFlowState.State.ROGUE_EXPLORATION
	)
	rogue_coordinator.set("_active", true)
	rogue_coordinator.call("_freeze_tower_runtime")
	_expect(
		not restored.visible
		and restored.process_mode == Node.PROCESS_MODE_DISABLED
		and restored.has_combat_action_lock(&"tower_rogue_exploration"),
		"Rogue 入口必须冻结并隐藏既有 Tower Player。"
	)
	mp_game.call("_on_net_player_left", NEW_PEER_ID)
	for _frame in 3:
		await process_frame
		await physics_frame
	mp_game.call(
		"_on_net_player_reconnected",
		NEW_PEER_ID,
		ROGUE_RECONNECTED_PEER_ID,
		"RogueReconnect",
		&"weishidaier",
		_next_membership_revision(run_state)
	)
	var rogue_restored := game.get_player_for_peer(
		ROGUE_RECONNECTED_PEER_ID
	) as Player
	_expect(
		rogue_restored != null
		and not rogue_restored.visible
		and rogue_restored.process_mode == Node.PROCESS_MODE_DISABLED
		and rogue_restored.has_combat_action_lock(
			&"tower_rogue_exploration"
		),
		(
			"Active Rogue reconnect must enroll the new Tower Player in the "
			+ "existing visibility/process/combat suspension lease."
		)
	)
	rogue_coordinator.set("_active", false)
	rogue_coordinator.call("_restore_tower_runtime")
	game.campaign_coordinator.replace_flow_state_for_fixture(
		CombatFlowState.State.INTERMISSION
	)
	_expect(
		rogue_restored != null
		and rogue_restored.visible
		and rogue_restored.process_mode == Node.PROCESS_MODE_INHERIT
		and not rogue_restored.has_combat_action_lock(
			&"tower_rogue_exploration"
		),
		"Rogue 退出必须按同一账本恢复重连玩家的原始表现与战斗租约。"
	)
	restored = rogue_restored
	var bystander_before_boundary := game.get_player_for_peer(
		FATE_BYSTANDER_PEER_ID
	) as Player
	var stale_bystander_position := Vector2(812.0, 346.0)
	bystander_before_boundary.global_position = stale_bystander_position
	mp_game.call("_on_net_player_left", FATE_BYSTANDER_PEER_ID)
	var pre_boundary_reconnect_state := (
		mp_game._disconnected_player_reconnect_states.get(
			FATE_BYSTANDER_PEER_ID,
			{}
		) as Dictionary
	)
	_expect(
		not bool(
			pre_boundary_reconnect_state.get(
				"tower_world_spawn_restore_pending",
				false
			)
		),
		"A disconnect before Rogue must not claim the return boundary early."
	)
	mp_game.call("_mark_disconnected_players_for_rogue_boundary_full_health")
	_expect(
		bool(
			pre_boundary_reconnect_state.get(
				"tower_world_spawn_restore_pending",
				false
			)
		),
		"The Rogue full-health boundary must mark earlier disconnects for world return."
	)
	mp_game.call(
		"_on_net_player_reconnected",
		FATE_BYSTANDER_PEER_ID,
		FATE_BYSTANDER_RECONNECTED_PEER_ID,
		"BoundaryReconnect",
		&"weishidaier",
		_next_membership_revision(run_state)
	)
	var bystander := game.get_player_for_peer(
		FATE_BYSTANDER_RECONNECTED_PEER_ID
	) as Player
	var bystander_world_position: Variant = (
		game.tower_multiplayer_mode_adapter
		.get_fixed_multiplayer_respawn_position(
			FATE_BYSTANDER_RECONNECTED_PEER_ID
		)
	)
	_expect(
		bystander != null
		and bystander_world_position is Vector2
		and bystander.global_position == (bystander_world_position as Vector2)
		and bystander.global_position != stale_bystander_position
		and game.multiplayer_spawn_slot_indices.get(
			FATE_BYSTANDER_RECONNECTED_PEER_ID
		) == 2,
		"A pre-Rogue disconnect must return to its stable PlayerSpawn slot after the boundary."
	)
	game.campaign_coordinator.replace_flow_state_for_fixture(
		CombatFlowState.State.FATE_INTERLUDE
	)
	game.fate_flow_coordinator.teleport_authoritative_players_to_room()
	var stale_fate_position := Vector2(917.0, 563.0)
	restored.global_position = stale_fate_position
	restored.velocity = Vector2(21.0, -7.0)
	mp_game.call("_on_net_player_left", ROGUE_RECONNECTED_PEER_ID)
	var fate_reconnect_state := (
		mp_game._disconnected_player_reconnect_states.get(
			ROGUE_RECONNECTED_PEER_ID,
			{}
		) as Dictionary
	)
	_expect(
		bool(
			fate_reconnect_state.get(
				"tower_world_spawn_restore_pending",
				false
			)
		),
		"A Fate-room disconnect must retain a pending Tower world return."
	)
	for _frame in 3:
		await process_frame
		await physics_frame
	mp_game.call(
		"_on_net_player_reconnected",
		ROGUE_RECONNECTED_PEER_ID,
		FATE_RECONNECTED_PEER_ID,
		"FateReconnect",
		&"weishidaier",
		_next_membership_revision(run_state)
	)
	var fate_restored := game.get_player_for_peer(
		FATE_RECONNECTED_PEER_ID
	) as Player
	var fate_room_position := (
		game.xiaocong_fate_interlude.get_player_spawn_position(1)
	)
	_expect(
		fate_restored != null
		and fate_room_position != stale_fate_position
		and fate_restored.global_position == fate_room_position
		and fate_restored.velocity == Vector2.ZERO
		and fate_restored.combat_actions_locked
		and not fate_restored.controls_locked
		and game.multiplayer_spawn_slot_indices.get(FATE_RECONNECTED_PEER_ID) == 1
		and bystander != null
		and bystander.global_position
		== game.xiaocong_fate_interlude.get_player_spawn_position(2)
		and bystander.global_position != fate_restored.global_position,
		(
			"Fate reconnect must supersede the stale snapshot with its stable room "
			+ "slot, without colliding after the new peer ID changes sort order."
		)
	)
	_expect(
		mp_game.player_coordinator.get_accepted_player_position(
			FATE_RECONNECTED_PEER_ID
		) == fate_room_position,
		"Fate reconnect must replace the Host accepted pose before runtime repair."
	)
	mp_game.call("_on_net_player_left", FATE_RECONNECTED_PEER_ID)
	game.fate_flow_coordinator.restore_authoritative_players_from_room()
	game.campaign_coordinator.replace_flow_state_for_fixture(
		CombatFlowState.State.INTERMISSION
	)
	mp_game.call(
		"_on_net_player_reconnected",
		FATE_RECONNECTED_PEER_ID,
		POST_FATE_RECONNECTED_PEER_ID,
		"PostFateReconnect",
		&"weishidaier",
		_next_membership_revision(run_state)
	)
	var post_fate_restored := game.get_player_for_peer(
		POST_FATE_RECONNECTED_PEER_ID
	) as Player
	var post_fate_world_position: Variant = (
		game.tower_multiplayer_mode_adapter
		.get_fixed_multiplayer_respawn_position(POST_FATE_RECONNECTED_PEER_ID)
	)
	var final_teleport_broadcast := (
		fixture_authoritative_teleport_broadcasts.back() as Dictionary
		if not fixture_authoritative_teleport_broadcasts.is_empty()
		else {}
	)
	_expect(
		post_fate_restored != null
		and post_fate_world_position is Vector2
		and post_fate_restored.global_position
		== (post_fate_world_position as Vector2)
		and post_fate_restored.velocity == Vector2.ZERO
		and not post_fate_restored.combat_actions_locked
		and mp_game.player_coordinator.get_accepted_player_position(
			POST_FATE_RECONNECTED_PEER_ID
		) == post_fate_world_position
		and int(final_teleport_broadcast.get("peer_id", 0))
		== POST_FATE_RECONNECTED_PEER_ID
		and final_teleport_broadcast.get("target_position")
		== post_fate_world_position,
		(
			"A player disconnected through Fate departure must be authoritatively "
			+ "returned to PlayerSpawn instead of restoring the stale room pose."
		)
	)
	fixture_teleport_player_coordinator = null
	mp_game.free()
	net_stub.free()
	stale_route_player.queue_free()
	current_scene = null
	game.queue_free()
	for _frame in 4:
		await process_frame
		await physics_frame


func _test_embedded_client_restores_unseen_participant() -> void:
	var run_state := root.get_node("RunState") as RunStateStore
	run_state.begin_new_run(&"weishidaier", false)
	_expect(
		run_state.register_multiplayer_peer_states(PackedInt32Array([
			HOST_PEER_ID,
			CLIENT_LOCAL_PEER_ID,
			UNSEEN_OLD_PEER_ID,
		])),
		"内嵌客户端夹具必须在创建 Player 投影前注册完整认证 roster。"
	)
	var game := GAME_SCENE.instantiate() as TowerDefenseGame
	_disable_tower_fixture_background_loads(game)
	game.auto_start_waves = false
	game.configure_multiplayer(
		CombatRuntimeBase.RuntimeMode.CLIENT_VIEW,
		CLIENT_LOCAL_PEER_ID,
		{
			HOST_PEER_ID: "Host",
			CLIENT_LOCAL_PEER_ID: "ClientA",
		},
		{
			HOST_PEER_ID: &"weishidaier",
			CLIENT_LOCAL_PEER_ID: &"weishidaier",
		}
	)
	root.add_child(game)
	current_scene = game
	for _frame in 4:
		await process_frame
		await physics_frame

	var mp_game := MP_GAME_SCRIPT.new()
	mp_game.embedded_runtime = true
	_expect(
		mp_game.configure_embedded_participant_roster(PackedInt32Array([
			HOST_PEER_ID,
			CLIENT_LOCAL_PEER_ID,
			UNSEEN_OLD_PEER_ID,
		])),
		"Client placeholder fixture must freeze the original combat roster."
	)
	var net_stub := ClientNetManagerStub.new()
	mp_game.game = game
	mp_game.run_state = run_state
	mp_game.net_manager = net_stub
	_bind_multiplayer_runtime(mp_game, game)
	mp_game.call(
		"_on_net_player_reconnected",
		UNSEEN_OLD_PEER_ID,
		UNSEEN_NEW_PEER_ID,
		"ClientB",
		&"weishidaier",
		_next_membership_revision(run_state)
	)
	var restored := game.get_player_for_peer(UNSEEN_NEW_PEER_ID) as Player
	_expect(
		restored != null
		and not mp_game._embedded_participant_peer_ids.has(UNSEEN_OLD_PEER_ID)
		and mp_game._embedded_participant_peer_ids.has(UNSEEN_NEW_PEER_ID)
		and run_state.has_multiplayer_peer_state(UNSEEN_NEW_PEER_ID),
		(
			"A rejoined client with no old local capture must create a remote combat "
			+ "placeholder and remap the frozen roster."
		)
	)
	if restored != null:
		var authoritative_state := SnapshotManager.PlayerState.new()
		authoritative_state.peer_id = UNSEEN_NEW_PEER_ID
		authoritative_state.character_id = &"weishidaier"
		authoritative_state.position = Vector2(512.0, 288.0)
		authoritative_state.velocity = Vector2(10.0, -2.0)
		authoritative_state.current_health = 17
		authoritative_state.max_health = 120
		authoritative_state.health_revision = 4
		authoritative_state.current_xirang = 345
		authoritative_state.ammo_capacity = 12
		authoritative_state.current_ammo = 7
		restored.apply_multiplayer_snapshot_motion(
			authoritative_state.position,
			authoritative_state.velocity,
			authoritative_state.facing,
			authoritative_state.anim_state
		)
		mp_game.player_coordinator.call(
			"_apply_realtime_snapshot",
			restored,
			authoritative_state
		)
		_expect(
			restored.global_position == authoritative_state.position
			and restored.current_health == 17
			and restored.max_health == 120
			and restored.current_xirang == 345
			and restored.current_ammo == 7,
			(
				"The next Host player keyframe must fully converge the placeholder; "
				+ "actual pos=%s health=%d/%d xirang=%d ammo=%d."
			)
			% [
				restored.global_position,
				restored.current_health,
				restored.max_health,
				restored.current_xirang,
				restored.current_ammo,
			]
		)

	var authoritative_run_state := RunStateStore.new()
	authoritative_run_state.begin_new_run(&"weishidaier", false)
	authoritative_run_state.register_multiplayer_peer_state(UNSEEN_NEW_PEER_ID)
	_expect(
		authoritative_run_state.try_add_item_count_for_peer(
			UNSEEN_NEW_PEER_ID,
			WOOD_MATERIAL,
			2
		),
		"Authoritative inventory fixture must create a new-id snapshot."
	)
	var inventory_snapshot := (
		authoritative_run_state.export_inventory_snapshot_for_peer(
			UNSEEN_NEW_PEER_ID
		)
	)
	mp_game.call(
		"net_inventory_snapshot",
		UNSEEN_NEW_PEER_ID,
		inventory_snapshot,
		true,
		mp_game.net_manager.get_session_participant_incarnation(
			UNSEEN_NEW_PEER_ID
		),
		mp_game.net_manager.get_game_session_incarnation()
	)
	_expect(
		run_state.get_inventory_item_total_for_peer(
			UNSEEN_NEW_PEER_ID,
			WOOD_MATERIAL
		) == 2,
		"The reliable Host inventory snapshot must converge the placeholder RunState."
	)
	authoritative_run_state.free()
	mp_game.free()
	net_stub.free()
	current_scene = null
	game.queue_free()
	for _frame in 4:
		await process_frame
		await physics_frame


func _cleanup_root() -> void:
	current_scene = null
	for _frame in 4:
		await process_frame
		await physics_frame


## 测试直接调用身份事务时仍必须模拟 NetManager 提交的单调成员 revision。
func _next_membership_revision(run_state: RunStateStore) -> int:
	return maxi(run_state.get_multiplayer_session_membership_revision() + 1, 1)


func _disable_tower_fixture_background_loads(game: TowerDefenseGame) -> void:
	var fate_coordinator := game.get_node_or_null("FateCoordinator") as FateCoordinator
	if fate_coordinator != null:
		fate_coordinator.elite_enemy_config_loads_requested = true


func _bind_multiplayer_runtime(
	mp_game,
	game: CombatRuntimeBase
) -> void:
	# 运行时夹具必须显式拥有 wire 会话世代，不能依赖生产边界的空值兜底。
	if mp_game.net_manager.get_game_session_incarnation() <= 0:
		mp_game.net_manager.loading_session_id = 1
	var session_coordinator := MpSessionCoordinator.new()
	session_coordinator.name = "SessionCoordinator"
	mp_game.add_child(session_coordinator)
	mp_game.session_coordinator = session_coordinator
	session_coordinator.bind_runtime(game)
	var player_coordinator := MpPlayerCoordinator.new()
	player_coordinator.name = "PlayerCoordinator"
	game.add_child(player_coordinator)
	mp_game.player_coordinator = player_coordinator
	player_coordinator.bind_runtime(game)
	var enemy_coordinator := MpEnemyCoordinator.new()
	enemy_coordinator.name = "EnemyCoordinator"
	mp_game.add_child(enemy_coordinator)
	mp_game.enemy_coordinator = enemy_coordinator
	var projectile_coordinator := MpProjectileCoordinator.new()
	projectile_coordinator.name = "ProjectileCoordinator"
	mp_game.add_child(projectile_coordinator)
	mp_game.projectile_coordinator = projectile_coordinator
	var tower_world_coordinator := MpTowerWorldCoordinator.new()
	tower_world_coordinator.name = "TowerWorldCoordinator"
	mp_game.add_child(tower_world_coordinator)
	mp_game.tower_world_coordinator = tower_world_coordinator
	var tower_economy_coordinator := MpTowerEconomyCoordinator.new()
	tower_economy_coordinator.name = "TowerEconomyCoordinator"
	mp_game.add_child(tower_economy_coordinator)
	mp_game.tower_economy_coordinator = tower_economy_coordinator
	var tower_fate_coordinator := MpTowerFateCoordinator.new()
	tower_fate_coordinator.name = "TowerFateCoordinator"
	mp_game.add_child(tower_fate_coordinator)
	mp_game.tower_fate_coordinator = tower_fate_coordinator
	var collectible_presentation_coordinator := (
		MpCollectiblePresentationCoordinator.new()
	)
	collectible_presentation_coordinator.name = "CollectiblePresentationCoordinator"
	mp_game.add_child(collectible_presentation_coordinator)
	mp_game.collectible_presentation_coordinator = (
		collectible_presentation_coordinator
	)
	var network_diagnostics_coordinator := MpNetworkDiagnosticsCoordinator.new()
	network_diagnostics_coordinator.name = "NetworkDiagnosticsCoordinator"
	mp_game.add_child(network_diagnostics_coordinator)
	mp_game.network_diagnostics_coordinator = network_diagnostics_coordinator
	var peer_ledger_coordinator := MpPeerLedgerCoordinator.new()
	peer_ledger_coordinator.name = "PeerLedgerCoordinator"
	mp_game.add_child(peer_ledger_coordinator)
	mp_game.peer_ledger_coordinator = peer_ledger_coordinator
	var ledger_role := (
		MpPeerLedgerCoordinator.RuntimeRole.HOST
		if mp_game.net_manager.is_host()
		else MpPeerLedgerCoordinator.RuntimeRole.CLIENT
	)
	mp_game.set(
		"_peer_ledger_generation",
		peer_ledger_coordinator.bind_session(
			mp_game,
			ledger_role,
			mp_game.net_manager.get_game_session_incarnation(),
			mp_game.run_state.has_multiplayer_peer_state,
			Callable(mp_game, "_is_peer_result_envelope_ready"),
			Callable(mp_game, "_commit_pending_peer_ledger_envelope")
		)
	)
	var gameplay_gateway := game.get_multiplayer_gameplay_gateway()
	var mode_adapter := game.get_multiplayer_mode_adapter()
	mp_game._gameplay_gateway = gameplay_gateway
	mp_game._mode_adapter = mode_adapter
	mp_game.tower_mode_adapter = (
		mode_adapter as TowerDefenseMultiplayerModeAdapter
	)
	player_coordinator.bind_life_dependencies(
		mp_game.net_manager,
		mode_adapter,
		projectile_coordinator,
		Callable(mp_game, "_get_net_time"),
		Callable(mp_game, "_cancel_player_life_tango_for_revive_schedule"),
		Callable(mp_game, "_cancel_player_life_actions_for_revive"),
		Callable(mp_game, "_clear_player_life_tiyi_lifecycle_state"),
		Callable(mp_game, "_get_player_life_revive_anchor_position"),
		Callable(mp_game, "_commit_player_life_revive_position")
	)
	var transactions_coordinator := MpTransactionsCoordinator.new()
	transactions_coordinator.name = "TransactionsCoordinator"
	mp_game.add_child(transactions_coordinator)
	mp_game.transactions_coordinator = transactions_coordinator
	transactions_coordinator.bind_session(
		mp_game,
		game,
		mode_adapter,
		mp_game.net_manager,
		mp_game.run_state,
		mp_game._suspended_embedded_participant_peer_ids
	)
	var merchant_transactions_coordinator := (
		MpMerchantTransactionsCoordinator.new()
	)
	merchant_transactions_coordinator.name = "MerchantTransactionsCoordinator"
	mp_game.add_child(merchant_transactions_coordinator)
	mp_game.merchant_transactions_coordinator = merchant_transactions_coordinator
	merchant_transactions_coordinator.bind_runtime(
		game,
		mode_adapter,
		mp_game.run_state,
		mp_game.net_manager,
		session_coordinator.get_net_time_origin()
	)
	var rogue_route_bridge := MpRogueRoute.new()
	rogue_route_bridge.name = "TowerRogueRouteBridge"
	rogue_route_bridge.auto_bind_scene_runtime = false
	mp_game.add_child(rogue_route_bridge)
	mp_game.tower_rogue_route_bridge = rogue_route_bridge
	if gameplay_gateway != null:
		gameplay_gateway.attach_multiplayer_session(mp_game)
	if mode_adapter != null:
		mode_adapter.attach_multiplayer_session(mp_game)


func _on_fixture_player_teleport_requested(
	peer_id: int,
	target_position: Vector2
) -> void:
	_expect(
		fixture_teleport_player_coordinator != null
		and fixture_teleport_player_coordinator.handle_authoritative_player_teleport_request(
			peer_id,
			target_position
		),
		"Reconnect fixture failed to commit the authoritative Fate teleport."
	)


func _on_fixture_authoritative_teleport_broadcast_requested(
	peer_id: int,
	target_position: Vector2,
	snapshot_sequence_cutoff: int
) -> void:
	fixture_authoritative_teleport_broadcasts.append({
		"peer_id": peer_id,
		"target_position": target_position,
		"snapshot_sequence_cutoff": snapshot_sequence_cutoff,
	})


func _extract_function_source(source: String, function_name: String) -> String:
	var start_marker := "func %s(" % function_name
	var start_index := source.find(start_marker)
	if start_index < 0:
		return ""
	var next_function_index := source.find("\nfunc ", start_index + start_marker.length())
	return (
		source.substr(start_index)
		if next_function_index < 0
		else source.substr(start_index, next_function_index - start_index)
	)


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
