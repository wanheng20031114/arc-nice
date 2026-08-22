extends SceneTree

const MP_GAME_SCENE := preload("res://scene/multiplayer/mp_game.tscn")
const STANDARD_RUNTIME_SCENE_PATH := (
	"res://scene/game_modes/standard/standard_game.tscn"
)
const TEST_PORT := 19_350

var failures: Array[String] = []
var mp_game: MultiplayerGameplaySession = null
var net_manager: NetManagerStore = null


func _init() -> void:
	call_deferred(&"_run")


func _run() -> void:
	await _test_embedded_failure_does_not_own_outer_session()
	await _cleanup()
	_finish()


func _test_embedded_failure_does_not_own_outer_session() -> void:
	net_manager = root.get_node_or_null("NetManager") as NetManagerStore
	_expect(net_manager != null, "NetManager autoload must exist for failure coverage.")
	if net_manager == null:
		return

	net_manager.disconnect_from_game()
	net_manager.local_player_name = "EmbeddedFailureHost"
	net_manager.set_local_character_id(&"weishidaier", true)
	var host_error := net_manager.host_create_lan_server(TEST_PORT)
	_expect(host_error == OK, "Failure-ownership smoke must create a local LAN Host.")
	if host_error != OK:
		return
	_expect(
		net_manager.set_host_game_mode(NetManagerStore.GameMode.TOWER_DEFENSE),
		"The failure fixture must own a tower-defense outer session."
	)
	net_manager.host_start_game()
	net_manager.report_game_loaded()
	_expect(
		net_manager.connection_state == NetManagerStore.ConnectionState.IN_GAME,
		"The intentional child failure must begin inside an active outer session."
	)
	if net_manager.connection_state != NetManagerStore.ConnectionState.IN_GAME:
		return

	var run_state := root.get_node_or_null("RunState") as RunStateStore
	_expect(run_state != null, "RunState autoload must exist for failure coverage.")
	if run_state == null:
		return
	run_state.begin_new_run(PlayerCharacterRegistry.WEISHIDAIER_ID, false)
	var membership_ready := run_state.reconcile_multiplayer_session_membership(
		net_manager.get_session_member_peer_ids(),
		net_manager.get_session_membership_revision()
	)
	_expect(
		membership_ready,
		"The outer session roster must exist before creating the failing child."
	)
	if not membership_ready:
		return

	var outer_mode_before := int(net_manager.get_current_game_mode())
	var transport_before := net_manager.multiplayer.multiplayer_peer
	var load_progress_before := net_manager.get_game_load_progress().duplicate(true)
	var host_ready_before := net_manager.host_game_ready
	var disconnected_observed := [false]
	var state_observer := func(new_state: NetManagerStore.ConnectionState) -> void:
		if new_state == NetManagerStore.ConnectionState.DISCONNECTED:
			disconnected_observed[0] = true
	net_manager.connection_state_changed.connect(state_observer)

	mp_game = MP_GAME_SCENE.instantiate() as MultiplayerGameplaySession
	_expect(mp_game != null, "MpGame scene must instantiate for failure coverage.")
	if mp_game == null:
		_disconnect_state_observer(state_observer)
		return
	mp_game.embedded_runtime = true
	var configured := mp_game.configure_embedded_runtime_contract(
		STANDARD_RUNTIME_SCENE_PATH,
		GameModeCatalog.MODE_ROGUE,
		PackedInt32Array([net_manager.get_local_peer_id()])
	)
	_expect(
		configured,
		(
			"The fixture contract itself must be valid so Standard Adapter versus Rogue "
			+ "mode is the only intended setup failure."
		)
	)
	if not configured:
		_disconnect_state_observer(state_observer)
		return

	var failure_signal_count := [0]
	var failure_reason := [""]
	mp_game.runtime_preparation_failed.connect(
		func(reason: String) -> void:
			failure_signal_count[0] = int(failure_signal_count[0]) + 1
			failure_reason[0] = reason
	)
	root.add_child(mp_game)

	var preparation := mp_game.get_runtime_preparation_snapshot()
	_expect(
		mp_game.is_runtime_preparation_failed()
		and preparation.state == RuntimePreparationProvider.PreparationState.FAILED
		and int(failure_signal_count[0]) == 1
		and str(failure_reason[0]).contains("MultiplayerModeAdapter")
		and mp_game.get_game_runtime() == null,
		(
			"A synchronous Adapter mismatch must atomically enter FAILED, emit one exact "
			+ "failure signal, and discard the rejected child runtime."
		)
	)
	_expect_outer_session_unchanged(
		"immediately after synchronous setup failure",
		outer_mode_before,
		transport_before,
		load_progress_before,
		host_ready_before,
		disconnected_observed
	)

	# 还原 production Coordinator 的 add_child 同步调用栈：它必须看见 MpGame
	# 已进入 FAILED，清掉引用并返回 false；随后迟到的 deferred signal 也不能
	# 再对外层 occurrence 或共享连接采取动作。
	var coordinator := RogueCombatMultiplayerCoordinator.new()
	coordinator.name = "SynchronousFailureCoordinator"
	root.add_child(coordinator)
	var mismatched_config := RogueCombatEncounterConfig.new()
	mismatched_config.combat_scene_path = STANDARD_RUNTIME_SCENE_PATH
	coordinator._phase = RogueCombatMultiplayerCoordinator.ProtocolPhase.PREPARING
	coordinator._active_occurrence_key = "fixture:sync-runtime-create-failure"
	coordinator._active_encounter_config = mismatched_config
	coordinator._participant_peer_ids = {
		net_manager.get_local_peer_id(): true,
	}
	_expect(
		not coordinator.call("_create_embedded_runtime")
		and coordinator._combat_network == null,
		(
			"Coordinator must synchronously reject and release an MpGame that failed "
			+ "inside add_child()."
		)
	)
	await process_frame
	_expect(
		coordinator._combat_network == null
		and coordinator._active_occurrence_key
			== "fixture:sync-runtime-create-failure",
		(
			"The deferred copy of a synchronous failure signal must be stale after "
			+ "the rejected runtime reference is cleared."
		)
	)
	_expect_outer_session_unchanged(
		"after coordinator synchronous failure cleanup",
		outer_mode_before,
		transport_before,
		load_progress_before,
		host_ready_before,
		disconnected_observed
	)
	coordinator.queue_free()
	await process_frame

	# Give the old deferred lobby-return path a frame in which to run. The child
	# owns only its preparation result; it must not own the shared transport.
	await process_frame
	_expect_outer_session_unchanged(
		"after deferred failure handling",
		outer_mode_before,
		transport_before,
		load_progress_before,
		host_ready_before,
		disconnected_observed
	)

	# Reconnect Player 投影也是子战场能力，耗尽重试后只能发布组件失败；
	# 不得借顶层的 fail-close API 关闭共享会话。PROJECTING 租约要一直保留
	# 到外层将该玩家原子降级为 SUSPENDED，避免 component-first 的放行窗口。
	var old_peer_id := 2
	var new_peer_id := 3
	var pending_projections := mp_game.get(
		"_pending_reconnected_player_projections"
	) as Dictionary
	var reconnect_captures := mp_game.get(
		"_disconnected_player_reconnect_states"
	) as Dictionary
	var projecting_peers := mp_game.get(
		"_projecting_embedded_participant_peer_ids"
	) as Dictionary
	pending_projections[old_peer_id] = {
		"new_peer_id": new_peer_id,
		"attempts": 6,
		"last_status": CombatRuntimeBase.ReconnectedPlayerProjectionStatus.CREATE_FAILED,
	}
	reconnect_captures[old_peer_id] = {"fixture": true}
	projecting_peers[new_peer_id] = true
	var projection_failures: Array[PackedInt32Array] = []
	mp_game.reconnected_player_projection_resolved.connect(
		func(
			resolved_old_peer_id: int,
			resolved_new_peer_id: int,
			outcome: MultiplayerGameplaySession.ReconnectedPlayerProjectionOutcome
		) -> void:
			projection_failures.append(PackedInt32Array([
				resolved_old_peer_id,
				resolved_new_peer_id,
				int(outcome),
			]))
	)
	mp_game.call("_exhaust_reconnected_player_projection", old_peer_id)
	_expect(
		projection_failures == [PackedInt32Array([
			old_peer_id,
			new_peer_id,
			int(MultiplayerGameplaySession.ReconnectedPlayerProjectionOutcome.FAILED),
		])]
		and not pending_projections.has(old_peer_id)
		and not reconnect_captures.has(old_peer_id)
		and projecting_peers.has(new_peer_id),
		(
			"Exhausted embedded projection must publish one FAILED result, retire its "
			+ "old capture, and preserve the fail-closed PROJECTING lease."
		)
	)
	_expect_outer_session_unchanged(
		"after embedded reconnect projection exhaustion",
		outer_mode_before,
		transport_before,
		load_progress_before,
		host_ready_before,
		disconnected_observed
	)

	mp_game.call("_on_game_return_to_lobby_requested")
	await process_frame
	_expect_outer_session_unchanged(
		"after the child return-to-lobby request entry point",
		outer_mode_before,
		transport_before,
		load_progress_before,
		host_ready_before,
		disconnected_observed
	)

	mp_game.call("_return_to_lobby")
	await process_frame
	_expect_outer_session_unchanged(
		"after the child internal lobby-return entry point",
		outer_mode_before,
		transport_before,
		load_progress_before,
		host_ready_before,
		disconnected_observed
	)
	_expect(
		int(failure_signal_count[0]) == 1,
		"Repeated failure handling must not emit a second preparation failure signal."
	)
	_disconnect_state_observer(state_observer)


func _expect_outer_session_unchanged(
	stage: String,
	expected_mode: int,
	expected_transport: MultiplayerPeer,
	expected_load_progress: Dictionary,
	expected_host_ready: bool,
	disconnected_observed: Array
) -> void:
	_expect(
		not bool(disconnected_observed[0])
		and net_manager.connection_state == NetManagerStore.ConnectionState.IN_GAME
		and net_manager.is_multiplayer_active()
		and int(net_manager.get_current_game_mode()) == expected_mode
		and expected_mode == GameModeCatalog.MODE_TOWER_DEFENSE
		and net_manager.multiplayer.multiplayer_peer == expected_transport
		and net_manager.get_game_load_progress() == expected_load_progress
		and net_manager.host_game_ready == expected_host_ready,
		(
			"Embedded failure must leave connection, mode, peer, and load barrier intact "
			+ stage
			+ "."
		)
	)


func _disconnect_state_observer(observer: Callable) -> void:
	if (
		net_manager != null
		and net_manager.connection_state_changed.is_connected(observer)
	):
		net_manager.connection_state_changed.disconnect(observer)


func _cleanup() -> void:
	if mp_game != null and is_instance_valid(mp_game):
		mp_game.queue_free()
		await process_frame
	mp_game = null
	if net_manager != null:
		net_manager.disconnect_from_game()
	await process_frame


func _expect(condition: bool, message: String) -> void:
	if condition:
		return
	failures.append(message)
	push_error(message)


func _finish() -> void:
	if failures.is_empty():
		print("MpGame embedded failure ownership smoke test passed.")
		quit(0)
		return
	print(
		"MpGame embedded failure ownership smoke test failed: %d issue(s)."
		% failures.size()
	)
	for failure in failures:
		print(" - %s" % failure)
	quit(1)
