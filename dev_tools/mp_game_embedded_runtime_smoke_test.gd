extends SceneTree

const MP_GAME_SCENE := preload("res://scene/multiplayer/mp_game.tscn")
const OVERRIDE_RUNTIME_SCENE_PATH := "res://scene/game_modes/standard/standard_game.tscn"
const TEST_PORT := 19_347
const PREPARATION_TIMEOUT_MSEC := 30_000
const FLOAT_EPSILON := 0.0001

var failures: Array[String] = []
var mp_game: Node = null
var net_manager: NetManagerStore = null
var static_contract_completed := false
var roster_contract_completed := false
var lifecycle_contract_completed := false
var reconnect_contract_completed := false
var inactive_process_contract_completed := false


func _init() -> void:
	call_deferred(&"_run")


func _run() -> void:
	_test_static_embedded_runtime_contract()
	_expect(
		static_contract_completed,
		"静态内嵌运行时契约必须完整执行到阶段终点。"
	)
	_test_embedded_participant_roster_contract()
	_expect(
		roster_contract_completed,
		"参战者 roster 契约必须完整执行到阶段终点。"
	)
	await _test_embedded_runtime_lifecycle()
	_expect(
		lifecycle_contract_completed,
		"内嵌运行时生命周期契约必须完整执行到阶段终点。"
	)
	await _cleanup()
	_finish()


func _test_static_embedded_runtime_contract() -> void:
	var source := FileAccess.get_file_as_string("res://scene/multiplayer/mp_game.gd")
	_expect(not source.is_empty(), "MpGame embedded-runtime source must be readable.")
	_expect(
		source.contains(
			"if embedded_runtime and not _embedded_runtime_active:\n\t\treturn\n"
			+ "\tif int(net_manager.connection_state) != STATE_IN_GAME:"
		),
		"Embedded MpGame must gate _physics_process before any network tick work."
	)
	_expect(
		source.contains(
			"func _process(delta: float) -> void:\n"
			+ "\t_update_pending_reconnected_player_projections(delta)\n"
			+ "\tif embedded_runtime and not _embedded_runtime_active:\n"
			+ "\t\treturn\n"
			+ "\tsession_coordinator.update_transport(delta)"
		),
		(
			"Inactive embedded MpGame must continue bounded reconnect projection retries, "
			+ "then gate session transport and interpolation work."
		)
	)
	_expect(
		source.contains(
			"func _rpc_to_connected_clients(method_name: StringName, args: Array = []) -> void:\n"
			+ "\tif embedded_runtime and not _embedded_runtime_active:\n"
			+ "\t\treturn"
		),
		(
			"Inactive embedded setup must not emit RPCs before every peer creates the "
			+ "stable runtime path."
		)
	)
	_expect(
			source.contains(
				"if embedded_runtime:\n"
				+ "\t\t_client_host_game_ready = false\n"
				+ "\t\t_announce_embedded_runtime_when_prepared(_preparation_generation)\n"
				+ "\telse:\n"
				+ "\t\t_report_game_loaded_when_prepared(_preparation_generation)"
			),
		(
			"Embedded setup must announce local preparation without entering the initial "
			+ "LOADING_GAME report path."
		)
	)
	_expect(
		source.contains(
			"or not game.is_runtime_preparation_complete()\n"
			+ "\t\tor int(net_manager.connection_state) != STATE_IN_GAME"
		),
		"Embedded activation must reject an incomplete runtime outside IN_GAME."
	)
	_expect(
		source.contains(
			"if not runtime_scene_path_override.strip_edges().is_empty():\n"
			+ "\t\treturn runtime_scene_path_override"
		),
		"An explicit embedded runtime scene path must take priority over game mode."
	)
	_expect(
		source.contains(
			"func net_game_defeated(failure_reason: String = \"\") -> void:\n"
			+ "\tworld_flow_coordinator.receive_defeat(failure_reason)"
		),
		"The terminal defeat RPC must delegate its authoritative reason to world flow."
	)
	var world_flow_source := FileAccess.get_file_as_string(
		"res://scene/multiplayer/world_flow/mp_world_flow_coordinator.gd"
	)
	_expect(
		world_flow_source.contains(
			"_mode_adapter.get_multiplayer_defeat_reason()"
		)
		and world_flow_source.contains(
			"_mode_adapter.apply_remote_defeat_with_reason(failure_reason)"
		),
		(
			"World flow must preserve the Host's defeat reason across broadcast and "
			+ "ClientView application."
		)
	)
	var game_source := FileAccess.get_file_as_string(
		"res://scene/combat/runtime/wave_combat_runtime_base.gd"
	)
	_expect(
		game_source.contains(
			"if not runtime_activation_deferred:\n"
			+ "\t\t\t_start_client_flow_countdown("
		),
		(
			"A deferred ClientView runtime must keep an empty flow state until its "
			+ "occurrence campaign is installed and the Host synchronizes activation."
		)
	)
	static_contract_completed = true


func _test_embedded_participant_roster_contract() -> void:
	var contract := MP_GAME_SCENE.instantiate()
	contract.set("embedded_runtime", true)
	_expect(
		bool(contract.call(
			"configure_embedded_participant_roster",
			PackedInt32Array([1, 2])
		)),
		"Embedded MpGame must accept one valid frozen roster before entering the tree."
	)
	var filtered := contract.call(
		"_filter_embedded_peer_map",
		{1: "Host", 2: "Participant", 3: "RouteSpectator"}
	) as Dictionary
	_expect(
		filtered == {1: "Host", 2: "Participant"},
		"Embedded runtime setup must exclude every connected route spectator."
	)
	_expect(
		not bool(contract.call(
			"configure_embedded_participant_roster",
			PackedInt32Array([1, 1])
		))
		and (contract.get("_embedded_participant_peer_ids") as Dictionary)
			== {1: true, 2: true},
		"An invalid replacement roster must be rejected without corrupting the frozen roster."
	)
	# 挂起与重连会清理真实协调器状态，只能在节点完成 `_ready` 且持久账本
	# 已建立后验证；这里仅覆盖进入树前唯一合法的 roster 冻结边界。
	contract.free()
	roster_contract_completed = true


func _test_embedded_runtime_lifecycle() -> void:
	net_manager = root.get_node_or_null("NetManager") as NetManagerStore
	_expect(net_manager != null, "NetManager autoload must exist for embedded runtime coverage.")
	if net_manager == null:
		return

	net_manager.disconnect_from_game()
	net_manager.local_player_name = "EmbeddedRuntimeSmokeHost"
	net_manager.set_local_character_id(&"weishidaier", true)
	var host_error := net_manager.host_create_lan_server(TEST_PORT)
	_expect(host_error == OK, "Embedded runtime smoke must create a local Host.")
	if host_error != OK:
		return
	_expect(
		net_manager.set_host_game_mode(NetManagerStore.GameMode.STANDARD),
		"The fixture must select the mode owned by the standard runtime override."
	)
	net_manager.host_start_game()
	_expect(
		net_manager.connection_state == NetManagerStore.ConnectionState.LOADING_GAME,
		"The fixture must establish and complete its initial loading barrier first."
	)
	net_manager.report_game_loaded()
	_expect(
		net_manager.connection_state == NetManagerStore.ConnectionState.IN_GAME,
		"Embedded runtime setup must begin from an already active multiplayer session."
	)
	if net_manager.connection_state != NetManagerStore.ConnectionState.IN_GAME:
		return
	var run_state := root.get_node_or_null("RunState") as RunStateStore
	_expect(run_state != null, "Embedded runtime fixture must have the RunState autoload.")
	if run_state == null:
		return
	# 内嵌战斗只能消费顶层会话已经提交的持久账本；测试夹具不得再依赖
	# MpGame 为缺失身份补建状态。
	run_state.begin_new_run(PlayerCharacterRegistry.WEISHIDAIER_ID, false)
	var session_member_peer_ids := net_manager.get_session_member_peer_ids()
	var session_membership_revision := net_manager.get_session_membership_revision()
	var persistent_ledger_ready := (
		session_membership_revision > 0
		and run_state.reconcile_multiplayer_session_membership(
			session_member_peer_ids,
			session_membership_revision
		)
	)
	_expect(
		persistent_ledger_ready,
		"The fixture must project the authoritative session roster into RunState first."
	)
	if not persistent_ledger_ready:
		return

	var load_progress_before := net_manager.get_game_load_progress().duplicate(true)
	var host_ready_before := net_manager.host_game_ready
	mp_game = MP_GAME_SCENE.instantiate()
	mp_game.set("embedded_runtime", true)
	mp_game.set("runtime_scene_path_override", OVERRIDE_RUNTIME_SCENE_PATH)
	_expect(
		bool(mp_game.call(
			"configure_embedded_participant_roster",
			PackedInt32Array([net_manager.get_local_peer_id()])
		)),
		"The embedded lifecycle fixture must freeze its Host-only participant roster."
	)
	_expect(
		not bool(mp_game.call("activate_embedded_runtime")),
		"An embedded MpGame without a prepared child runtime must refuse activation."
	)

	var prepared_signal_count := [0]
	mp_game.connect(
		&"embedded_runtime_prepared",
		func() -> void:
			prepared_signal_count[0] = int(prepared_signal_count[0]) + 1
	)
	root.add_child(mp_game)

	var runtime := mp_game.call("get_game_runtime") as CombatRuntimeBase
	_expect(runtime != null, "Embedded MpGame must instantiate a CombatRuntimeBase child.")
	if runtime == null:
		return
	_expect(
		runtime.scene_file_path == OVERRIDE_RUNTIME_SCENE_PATH
		and runtime is StandardGame
		and not (
			runtime.get_multiplayer_mode_adapter()
			is TowerDefenseMultiplayerModeAdapter
		),
		(
			"The explicit standard-scene override must resolve to its matching typed "
			+ "runtime and adapter."
		)
	)
	_expect(
		runtime.runtime_activation_deferred
		and not runtime.runtime_activated
		and runtime.process_mode == Node.PROCESS_MODE_DISABLED,
		"Embedded gameplay must remain frozen throughout preparation."
	)

	_test_inactive_process_gates()
	_expect(
		inactive_process_contract_completed,
		"未激活处理门禁契约必须完整执行到阶段终点。"
	)

	var deadline_msec := Time.get_ticks_msec() + PREPARATION_TIMEOUT_MSEC
	while Time.get_ticks_msec() < deadline_msec:
		if bool(mp_game.call("is_runtime_preparation_complete")):
			break
		await process_frame
	_expect(
		bool(mp_game.call("is_runtime_preparation_complete")),
		"Embedded runtime preparation must complete before the timeout."
	)
	if not bool(mp_game.call("is_runtime_preparation_complete")):
		return
	await process_frame
	_expect(
		int(prepared_signal_count[0]) == 1,
		"Embedded MpGame must announce preparation exactly once without auto-activation."
	)
	_expect(
		runtime.runtime_activation_deferred
		and not runtime.runtime_activated
		and not bool(mp_game.call("is_embedded_runtime_active")),
		"Preparation completion alone must not activate embedded gameplay."
	)

	# READY 只能通过新 generation 合法重开；测试也不得直接篡改旧 bool 镜像。
	var activation_guard_generation := runtime.begin_runtime_preparation(
		"嵌入战场激活守卫",
		1
	)
	_expect(
		not bool(mp_game.call("activate_embedded_runtime")),
		"Embedded activation must reject a configured runtime marked incomplete."
	)
	_expect(
		not runtime.runtime_activated
		and not bool(mp_game.call("is_embedded_runtime_active")),
		"A rejected activation must leave both wrapper and runtime inactive."
	)
	runtime.mark_runtime_preparation_complete(activation_guard_generation)

	var first_activation := bool(mp_game.call("activate_embedded_runtime"))
	var second_activation := bool(mp_game.call("activate_embedded_runtime"))
	_expect(
		first_activation
		and not second_activation
		and bool(mp_game.call("is_embedded_runtime_active")),
		"Embedded runtime activation must succeed once and reject duplicate calls."
	)
	_expect(
		runtime.runtime_activated
		and not runtime.runtime_activation_deferred
		and runtime.process_mode == Node.PROCESS_MODE_INHERIT,
		"Successful activation must reach CombatRuntimeBase.activate_runtime()."
	)
	_expect(
		net_manager.connection_state == NetManagerStore.ConnectionState.IN_GAME
		and net_manager.host_game_ready == host_ready_before
		and net_manager.get_game_load_progress() == load_progress_before,
		(
			"Preparing an embedded runtime inside IN_GAME must not mutate or restart the "
			+ "completed initial loading barrier."
		)
	)

	_test_suspended_participant_reconnect_contract(
		run_state,
		net_manager.get_local_peer_id()
	)
	_expect(
		reconnect_contract_completed,
		"挂起参战者重连契约必须完整执行到阶段终点。"
	)
	lifecycle_contract_completed = true


func _test_suspended_participant_reconnect_contract(
	run_state: RunStateStore,
	old_peer_id: int
) -> void:
	const RECONNECTED_PEER_ID := 4
	var ledger_revision_before := (
		run_state.get_multiplayer_session_membership_revision()
	)
	var inventory_revision_before := run_state.get_inventory_revision_for_peer(
		old_peer_id
	)
	var suspended := bool(mp_game.call(
		"suspend_embedded_participant_for_current_combat",
		old_peer_id
	))
	_expect(
		suspended
		and (mp_game.get("_embedded_participant_peer_ids") as Dictionary)
			== {old_peer_id: true}
		and (mp_game.get(
			"_suspended_embedded_participant_peer_ids"
		) as Dictionary) == {old_peer_id: true}
		and (
			mp_game.get_node("TransactionsCoordinator")
			as MpTransactionsCoordinator
		).get("_suspended_peer_ids") == {old_peer_id: true},
		(
			"A combat-only spectator downgrade must preserve the canonical identity and "
			+ "publish the same suspension lease to transaction ingress."
		)
	)
	if not suspended or ledger_revision_before < 0:
		reconnect_contract_completed = true
		return

	# v77 的重连通知携带显式 membership revision。这里模拟认证层已经签发
	# 下一 revision，验证 suspended 终态与全部 RunState 分账本原子迁移。
	mp_game.call(
		"_on_net_player_reconnected",
		old_peer_id,
		RECONNECTED_PEER_ID,
		"ParticipantReconnectedAgain",
		PlayerCharacterRegistry.WEISHIDAIER_ID,
		ledger_revision_before + 1
	)
	_expect(
		(mp_game.get("_embedded_participant_peer_ids") as Dictionary)
			== {RECONNECTED_PEER_ID: true}
		and (mp_game.get(
			"_suspended_embedded_participant_peer_ids"
		) as Dictionary) == {RECONNECTED_PEER_ID: true}
		and not run_state.has_multiplayer_peer_state(old_peer_id)
		and run_state.has_multiplayer_peer_state(RECONNECTED_PEER_ID)
		and run_state.get_inventory_revision_for_peer(RECONNECTED_PEER_ID)
			== inventory_revision_before
		and run_state.get_multiplayer_session_membership_revision()
			== ledger_revision_before + 1,
		(
			"A suspended reconnect must move the frozen roster and persistent ledger "
			+ "under the same explicit membership revision."
		)
	)
	reconnect_contract_completed = true


func _test_inactive_process_gates() -> void:
	const SENTINEL := 7.5
	const DELTA := 1.25
	var session := mp_game.get_node("SessionCoordinator") as MpSessionCoordinator
	var diagnostics := mp_game.get_node(
		"NetworkDiagnosticsCoordinator"
	) as MpNetworkDiagnosticsCoordinator
	session.set("_client_runtime_repair_cooldown_time_left", SENTINEL)
	mp_game.call("_process", DELTA)
	_expect(
		is_equal_approx(
			float(session.get("_client_runtime_repair_cooldown_time_left")),
			SENTINEL
		),
		"Inactive embedded _process must not advance session transport leases."
	)

	mp_game.set("_recent_event_prune_time_left", SENTINEL)
	diagnostics.set("_snapshot_packet_warn_time_left", SENTINEL)
	mp_game.call("_physics_process", DELTA)
	_expect(
		absf(float(mp_game.get("_recent_event_prune_time_left")) - SENTINEL)
		<= FLOAT_EPSILON
		and absf(float(diagnostics.get("_snapshot_packet_warn_time_left")) - SENTINEL)
		<= FLOAT_EPSILON,
		"Inactive embedded _physics_process must not enter either network timer path."
	)
	inactive_process_contract_completed = true


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
		print("MpGame embedded runtime smoke test passed.")
		quit(0)
		return
	print("MpGame embedded runtime smoke test failed: %d issue(s)." % failures.size())
	for failure in failures:
		print(" - %s" % failure)
	quit(1)
