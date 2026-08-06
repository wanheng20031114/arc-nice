extends SceneTree

const MP_GAME_SCENE := preload("res://scene/multiplayer/mp_game.tscn")
const OVERRIDE_RUNTIME_SCENE_PATH := "res://scene/game_modes/standard/standard_game.tscn"
const TEST_PORT := 19_347
const PREPARATION_TIMEOUT_MSEC := 30_000
const FLOAT_EPSILON := 0.0001

var failures: Array[String] = []
var mp_game: Node = null
var net_manager: NetManagerStore = null


func _init() -> void:
	call_deferred(&"_run")


func _run() -> void:
	_test_static_embedded_runtime_contract()
	_test_embedded_participant_roster_contract()
	await _test_embedded_runtime_lifecycle()
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
			+ "\tif embedded_runtime and not _embedded_runtime_active:\n"
			+ "\t\treturn\n"
			+ "\t_update_public_room_keepalive(delta)"
		),
		"Embedded MpGame must gate _process before keepalive and interpolation work."
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
			+ "\t\t_announce_embedded_runtime_when_prepared()\n"
			+ "\telse:\n"
			+ "\t\t_report_game_loaded_when_prepared()"
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
		source.contains("[game.get_multiplayer_defeat_reason() if game != null else \"\"]")
		and source.contains("func net_game_defeated(failure_reason: String = \"\")")
		and source.contains("game.apply_remote_defeat_with_reason(failure_reason)"),
		"The terminal defeat RPC must preserve the Host's authoritative failure reason."
	)
	var game_source := FileAccess.get_file_as_string("res://scene/game_modes/standard/standard_game.gd")
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
	_expect(
		bool(contract.call(
			"suspend_embedded_participant_for_current_combat",
			2
		))
		and (contract.get("_embedded_participant_peer_ids") as Dictionary)
			== {1: true, 2: true}
		and (contract.get(
			"_suspended_embedded_participant_peer_ids"
		) as Dictionary) == {2: true}
		and not bool(contract.call(
			"_consume_remote_transaction_admission",
			2
		)),
		(
			"A combat-only spectator downgrade must preserve the frozen identity "
			+ "while rejecting subsequent transaction ingress."
		)
	)
	contract.call(
		"_on_net_player_reconnected",
		2,
		4,
		"ParticipantReconnectedAgain",
		&"weishidaier"
	)
	_expect(
		(contract.get("_embedded_participant_peer_ids") as Dictionary)
			== {1: true, 4: true}
		and (contract.get(
			"_suspended_embedded_participant_peer_ids"
		) as Dictionary) == {4: true},
		"A suspended participant's canonical identity must follow another reconnect."
	)
	_expect(
		bool(contract.call(
			"suspend_embedded_participant_for_current_combat",
			4,
			2
		))
		and (contract.get("_embedded_participant_peer_ids") as Dictionary)
			== {1: true, 4: true}
		and (contract.get(
			"_suspended_embedded_participant_peer_ids"
		) as Dictionary) == {4: true},
		(
			"Spectator downgrade must also succeed when MpGame has already "
			+ "remapped the old identity before the coordinator callback runs."
		)
	)
	contract.free()


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
		net_manager.set_host_game_mode(NetManagerStore.GameMode.TOWER_DEFENSE),
		"The fixture must select tower defense before applying the standard-scene override."
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

	var runtime := mp_game.call("get_game_runtime") as GameRuntimeBase
	_expect(runtime != null, "Embedded MpGame must instantiate a GameRuntimeBase child.")
	if runtime == null:
		return
	_expect(
		runtime.scene_file_path == OVERRIDE_RUNTIME_SCENE_PATH
		and not runtime.supports_tower_defense(),
		(
			"The explicit standard-scene override must win even while NetManager selects "
			+ "tower-defense mode."
		)
	)
	_expect(
		runtime.runtime_activation_deferred
		and not runtime.runtime_activated
		and runtime.process_mode == Node.PROCESS_MODE_DISABLED,
		"Embedded gameplay must remain frozen throughout preparation."
	)

	_test_inactive_process_gates()

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

	# Exercise the preparation guard against a real configured runtime without
	# rebuilding or replacing its production preparation pipeline.
	runtime.runtime_preparation_complete = false
	_expect(
		not bool(mp_game.call("activate_embedded_runtime")),
		"Embedded activation must reject a configured runtime marked incomplete."
	)
	_expect(
		not runtime.runtime_activated
		and not bool(mp_game.call("is_embedded_runtime_active")),
		"A rejected activation must leave both wrapper and runtime inactive."
	)
	runtime.runtime_preparation_complete = true

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
		"Successful activation must reach GameRuntimeBase.activate_runtime()."
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


func _test_inactive_process_gates() -> void:
	const SENTINEL := 7.5
	const DELTA := 1.25
	mp_game.set("_public_room_keepalive_time_left", SENTINEL)
	mp_game.call("_process", DELTA)
	_expect(
		is_equal_approx(
			float(mp_game.get("_public_room_keepalive_time_left")),
			SENTINEL
		),
		"Inactive embedded _process must not enter the network keepalive path."
	)

	mp_game.set("_recent_event_prune_time_left", SENTINEL)
	mp_game.set("_snapshot_packet_warn_time_left", SENTINEL)
	mp_game.call("_physics_process", DELTA)
	_expect(
		absf(float(mp_game.get("_recent_event_prune_time_left")) - SENTINEL)
		<= FLOAT_EPSILON
		and absf(float(mp_game.get("_snapshot_packet_warn_time_left")) - SENTINEL)
		<= FLOAT_EPSILON,
		"Inactive embedded _physics_process must not enter either network timer path."
	)


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
