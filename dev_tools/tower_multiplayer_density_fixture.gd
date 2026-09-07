extends Node

var result: Dictionary = {}
var _finishing := false
var root: Window
var current_scene: Node:
	get:
		return get_tree().current_scene
	set(value):
		get_tree().current_scene = value

const ENEMY_COHORT = preload("res://dev_tools/tower_density_enemy_cohort.gd")

## Six separate Godot processes use the real LAN admission, loading barrier,
## MpGame RPC paths, tower simulation and client proxies. Only fixture setup
## bypasses terrain placement restrictions and raises health to retain density.
var role := "host"
var fixture_index := 0
var port := 28798
var participant_count := 6
var building_count := 400
var enemy_count := 300
var enemy_wave := ""
var _enemy_paths := PackedStringArray()
var _minimum_sample_enemies := 2147483647
var _maximum_sample_enemies := 0
var _sample_dead_players: Dictionary[int, bool] = {}
var _minimum_sample_player_max_health := 2147483647
var sample_frames := 300
var transport := "lan"
var active_input := false
var reconnect_last_client := false
var prepare_route_identity := false
var detailed_metrics := false
var production_period := 5.0
var output_directory := "res://dev_tools/output/tower_network_density"
var runtime: TowerDefenseGame
var session: Node
var net: NetManagerStore
var _deadline_msec := 0
var _sampling := false
var _last_frame_usec := 0
var _last_physics_usec := 0
var _frame_samples: Array[float] = []
var _physics_samples: Array[float] = []
var _process_work_samples: Array[float] = []
var _physics_work_samples: Array[float] = []
var _load_started := false
var _load_start_msec := 0
var _load_elapsed_msec := 0
var _failed := false
var _controls_enabled := false
var _control_frame := 0
var _movement_action := ""


func _ready() -> void:
	root = get_tree().root
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--role="): role = arg.trim_prefix("--role=")
		elif arg.begins_with("--index="): fixture_index = int(arg.trim_prefix("--index="))
		elif arg.begins_with("--port="): port = int(arg.trim_prefix("--port="))
		elif arg.begins_with("--players="): participant_count = int(arg.trim_prefix("--players="))
		elif arg.begins_with("--buildings="): building_count = int(arg.trim_prefix("--buildings="))
		elif arg.begins_with("--enemies="): enemy_count = int(arg.trim_prefix("--enemies="))
		elif arg.begins_with("--enemy-wave="): enemy_wave = arg.trim_prefix("--enemy-wave=")
		elif arg.begins_with("--frames="): sample_frames = int(arg.trim_prefix("--frames="))
		elif arg.begins_with("--transport="): transport = arg.trim_prefix("--transport=")
		elif arg == "--active-input": active_input = true
		elif arg == "--reconnect-last-client": reconnect_last_client = true
		elif arg == "--prepare-route-identity": prepare_route_identity = true
		elif arg == "--detailed-metrics": detailed_metrics = true
		elif arg.begins_with("--production-period="): production_period = float(arg.trim_prefix("--production-period="))
		elif arg.begins_with("--output-dir="): output_directory = arg.trim_prefix("--output-dir=")
	_deadline_msec = Time.get_ticks_msec() + 180000
	_run.call_deferred()


func _process(_delta: float) -> void:
	if Time.get_ticks_msec() > _deadline_msec and not _failed:
		_fail("180 second fixture deadline")
	if _sampling:
		var now := Time.get_ticks_usec()
		if _last_frame_usec > 0:
			_frame_samples.append(float(now - _last_frame_usec) / 1000.0)
		_last_frame_usec = now
		_process_work_samples.append(Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0)
		_physics_work_samples.append(Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS) * 1000.0)



func _physics_process(_delta: float) -> void:
	if _controls_enabled:
		if _control_frame % 120 == 0:
			if not _movement_action.is_empty():
				Input.action_release(_movement_action)
			_movement_action = "move_left" if (_control_frame / 120 + fixture_index) % 2 == 0 else "move_right"
			Input.action_press(_movement_action)
		_control_frame += 1
	if _sampling:
		if role == "host":
			for player: Player in runtime.peer_players.values():
				_minimum_sample_player_max_health = mini(_minimum_sample_player_max_health, player.max_health)
				if player.is_dead:
					_sample_dead_players[player.peer_id] = true
		var current_enemy_count := runtime.get_network_enemy_count()
		_minimum_sample_enemies = mini(_minimum_sample_enemies, current_enemy_count)
		_maximum_sample_enemies = maxi(_maximum_sample_enemies, current_enemy_count)
		var now := Time.get_ticks_usec()
		if _last_physics_usec > 0:
			_physics_samples.append(float(now - _last_physics_usec) / 1000.0)
		_last_physics_usec = now



func _run() -> void:
	Engine.max_fps = 60
	seed(20260908)
	_enemy_paths = ENEMY_COHORT.build_paths(enemy_count, enemy_wave)
	# Same canonical recipe on every participant; only this fixture's in-memory
	# period is accelerated so a ten-second measurement includes storage commits.
	var water_recipe := load("res://resources/config/production/water_to_bottle.tres") as ProductionRecipe
	water_recipe.duration_seconds = production_period
	net = root.get_node("NetManager") as NetManagerStore
	net.local_player_name = "Density%d" % fixture_index
	net.set_local_character_id(&"weishidaier", true)
	net.connection_failed.connect(_fail)
	net.connection_state_changed.connect(_on_connection_state_changed)
	(root.get_node("GameLoadCoordinator") as Node).loading_failed.connect(_fail)
	var connect_error := OK
	var relay_context: Dictionary = {}
	if transport == "relay":
		relay_context = JSON.parse_string(FileAccess.get_file_as_string(output_directory.path_join("relay_context.json")))
	if role == "host":
		net.set_host_game_mode(NetManagerStore.GameMode.TOWER_DEFENSE)
		if transport == "relay":
			connect_error = net.host_create_relay_room("127.0.0.1", port, participant_count,
				relay_context["room_id"], relay_context["tickets"][fixture_index])
		else:
			connect_error = net.host_create_lan_server(port, participant_count)
	else:
		if transport == "relay":
			var host_info: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(output_directory.path_join("host_ready.json")))
			connect_error = net.client_join_relay_room("127.0.0.1", port, int(host_info["host_peer_id"]),
				relay_context["room_id"], relay_context["tickets"][fixture_index])
		else:
			connect_error = net.client_connect_lan("127.0.0.1", port)
	if connect_error != OK:
		_fail(transport + " connection returned " + error_string(connect_error))
		return
	if role == "host":
		while net.connection_state not in [NetManagerStore.ConnectionState.HOSTING_LAN, NetManagerStore.ConnectionState.CONNECTED_IN_LOBBY]:
			await get_tree().process_frame
		_write_json("host_ready.json", {"host_peer_id": net.get_host_peer_id()})
		while net.connected_players.size() != participant_count or not net.are_all_player_characters_confirmed():
			await get_tree().process_frame
		print("DENSITY_ALL_REGISTERED ", net.connected_players)
		net.host_start_game()
	while net.connection_state != NetManagerStore.ConnectionState.IN_GAME:
		await get_tree().process_frame
	_load_elapsed_msec = Time.get_ticks_msec() - _load_start_msec
	session = root.get_node("MpGame")
	runtime = session.get("game") as TowerDefenseGame
	if runtime == null:
		_fail("Loaded runtime is not TowerDefenseGame")
		return
	runtime.auto_start_waves = false
	runtime.day_phase_announcements_enabled = false
	runtime.enemy_spawn_timer.stop()
	runtime.state_timer.stop()
	runtime.plant_terrain_decay_timer.stop()
	session.set_rpc_payload_diagnostics_enabled(detailed_metrics)
	if role == "host":
		await _populate()
		_write_json("setup.json", {"ready": true})
	else:
		while (
			runtime.get_network_enemy_count() < (enemy_count if enemy_wave.is_empty() else 1)
			or runtime.plant_system.plants_by_net_id.size() < building_count
			or not FileAccess.file_exists(output_directory.path_join("setup.json"))
		):
			await get_tree().process_frame
	print("DENSITY_LOADED role=", role, " peer=", net.get_local_peer_id(),
		" players=", net.connected_players.size(), " enemies=", runtime.get_network_enemy_count(),
		" plants=", runtime.plant_system.plants_by_net_id.size())
	if active_input:
		_controls_enabled = true
		Input.action_press("shoot_up")
	for frame in 120:
		await get_tree().physics_frame
	# Keep every participant moving/firing throughout the Host's measurement.
	# A slow Host may need more than 30 wall seconds for 1800 simulation ticks;
	# clients must not finish early and silently remove that input workload.
	_write_json("sample_ready_%d.json" % fixture_index, {"ready": true})
	if role == "host":
		for index in participant_count:
			while not FileAccess.file_exists(output_directory.path_join("sample_ready_%d.json" % index)):
				await get_tree().process_frame
		_write_json("host_sampling.json", {"starting": true})
	else:
		while not FileAccess.file_exists(output_directory.path_join("host_sampling.json")):
			await get_tree().process_frame
	Enemy.set_performance_metrics_enabled(detailed_metrics)
	var simulation := runtime.get_enemy_simulation_coordinator()
	simulation.get_metrics(true)
	session.set_network_cpu_profiling_enabled(detailed_metrics)
	var initial_network_metrics: Dictionary = session.get_snapshot_packet_metrics()
	var initial_warehouse_state := _warehouse_summary()
	var initial_projectile_sequence: int = session.projectile_coordinator.get("_next_projectile_sequence")
	_pop_native_transport_stats()
	_sampling = true
	var sample_start := Time.get_ticks_msec()
	var measured_physics_ticks := 0
	if role == "host":
		for frame in sample_frames:
			await get_tree().physics_frame
			measured_physics_ticks += 1
	else:
		while not FileAccess.file_exists(output_directory.path_join("host_sample_complete.json")):
			await get_tree().physics_frame
			measured_physics_ticks += 1
	_sampling = false
	if role == "host":
		_write_json("host_sample_complete.json", {"physics_ticks": measured_physics_ticks})
	var native_transport_stats := _pop_native_transport_stats()
	var final_network_metrics: Dictionary = session.get_snapshot_packet_metrics()
	var elapsed_ms := Time.get_ticks_msec() - sample_start
	var steady_channels: Array[Dictionary] = []
	for channel in (final_network_metrics["channel_metrics"] as Array).size():
		var initial: Dictionary = initial_network_metrics["channel_metrics"][channel]
		var final: Dictionary = final_network_metrics["channel_metrics"][channel]
		steady_channels.append({
			"channel": channel,
			"bytes_per_second": float(final["payload_bytes_total"] - initial["payload_bytes_total"]) * 1000.0 / elapsed_ms,
			"packets_per_second": float(final["packet_count"] - initial["packet_count"]) * 1000.0 / elapsed_ms,
		})
	var measurement := {
		"debug_build": OS.is_debug_build(), "editor_feature": OS.has_feature("editor"),
		"executable_path": OS.get_executable_path(),
		"role": role, "index": fixture_index, "peer_id": net.get_local_peer_id(),
		"transport": transport, "active_input": active_input,
		"detailed_metrics": detailed_metrics,
		"load_elapsed_ms": _load_elapsed_msec,
		"local_projectiles_allocated": int(session.projectile_coordinator.get("_next_projectile_sequence")) - initial_projectile_sequence,
		"fixture_production_period_seconds": production_period,
		"participants": net.connected_players.size(),
		"host_sample_dead_player_ids": _sample_dead_players.keys(),
		"host_minimum_sample_player_max_health": _minimum_sample_player_max_health if role == "host" else null,
		"player_health_end": _player_health_summary(),
		"requested_buildings": building_count, "requested_enemies": enemy_count,
		"enemy_wave": enemy_wave, "configured_enemy_cohort": ENEMY_COHORT.summarize(_enemy_paths),
		"minimum_sample_enemies": _minimum_sample_enemies,
		"maximum_sample_enemies": _maximum_sample_enemies,
		"plants": runtime.plant_system.plants_by_net_id.size(),
		"enemies": runtime.get_network_enemy_count(),
		"frames": sample_frames, "elapsed_ms": elapsed_ms,
		"sampled_physics_ticks": measured_physics_ticks, "sampling_scope": "host_wall_clock_window",
		"frame_ms": _summarize(_frame_samples),
		"physics_interval_ms": _summarize(_physics_samples),
		"process_work_ms": _summarize(_process_work_samples),
		"physics_work_ms": _summarize(_physics_work_samples),
		"simulation": simulation.get_metrics(true),
		"enemy_metrics": Enemy.get_performance_metrics(true),
		"network_cpu": session.get_network_cpu_metrics(),
		"native_transport": native_transport_stats,
		"input_sequences": _input_sequences(),
		"steady_channels": steady_channels,
		"warehouse_start": initial_warehouse_state,
		"warehouse_end": _warehouse_summary(),
		"steady_snapshot_batches": {
			"completed": final_network_metrics["enemy_snapshot_completed_batch_count"] - initial_network_metrics["enemy_snapshot_completed_batch_count"],
			"incomplete_evicted": final_network_metrics["enemy_snapshot_incomplete_batch_evict_count"] - initial_network_metrics["enemy_snapshot_incomplete_batch_evict_count"],
			"stale_chunks": final_network_metrics["enemy_snapshot_stale_chunk_count"] - initial_network_metrics["enemy_snapshot_stale_chunk_count"],
		},
		"metrics": final_network_metrics,
		"nodes": Performance.get_monitor(Performance.OBJECT_NODE_COUNT),
		"memory_bytes": Performance.get_monitor(Performance.MEMORY_STATIC),
		"headless": DisplayServer.get_name() == "headless",
	}
	_write_json("peer_%d.json" % fixture_index, measurement)
	_controls_enabled = false
	if active_input:
		Input.action_release("shoot_up")
		if not _movement_action.is_empty():
			Input.action_release(_movement_action)
	print("DENSITY_PEER_RESULT ", JSON.stringify(measurement))
	# Once every measured state is saved, the other process may legitimately
	# close. Do not report its coordinated teardown as a connection failure.
	net.connection_failed.disconnect(_fail)
	net.connection_state_changed.disconnect(_on_connection_state_changed)
	if role == "host":
		for index in range(1, participant_count):
			while not FileAccess.file_exists(output_directory.path_join("peer_%d.json" % index)):
				await get_tree().process_frame
	if reconnect_last_client:
		if prepare_route_identity:
			if not runtime.rogue_exploration_coordinator._ensure_route_runtime_identity():
				_fail("Could not initialize the embedded route's authenticated identity")
				return
			_write_json("route_identity_ready_%d.json" % fixture_index, {"ready": true})
			for index in participant_count:
				while not FileAccess.file_exists(output_directory.path_join("route_identity_ready_%d.json" % index)):
					await get_tree().process_frame
		if role == "host":
			await _verify_host_reconnect()
		elif fixture_index == participant_count - 1:
			await _perform_client_reconnect(relay_context)
		if _failed:
			return
	if role == "host":
		# Measurement windows finish at different wall times when the host catches
		# up physics ticks. Freeze only AFTER everyone's sample, then verify one
		# shared final revision through the real reliable replication path.
		runtime.production_coordinator.production_tick_timer.stop()
		_write_json("warehouse_checkpoint.json", _warehouse_summary())
	else:
		while not FileAccess.file_exists(output_directory.path_join("warehouse_checkpoint.json")):
			await get_tree().process_frame
	var checkpoint: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(output_directory.path_join("warehouse_checkpoint.json")))
	while not _warehouse_checkpoint_matches(checkpoint):
		await get_tree().process_frame
	if prepare_route_identity:
		if not _verify_retained_route_identity():
			return
	_write_json("checkpoint_peer_%d.json" % fixture_index, _warehouse_summary())
	if role == "host":
		for index in range(1, participant_count):
			while not FileAccess.file_exists(output_directory.path_join("checkpoint_peer_%d.json" % index)):
				await get_tree().process_frame
		_write_json("stop.json", {"complete": true})
	else:
		while not FileAccess.file_exists(output_directory.path_join("stop.json")):
			await get_tree().process_frame
	# Close transport BEFORE removing the stable RPC root; otherwise queued peer
	# snapshots can be polled after /root/MpGame is gone.
	if root.multiplayer.multiplayer_peer != null:
		root.multiplayer.multiplayer_peer.close()
	net.disconnect_from_game()
	if is_instance_valid(runtime):
		runtime.prepare_for_scene_teardown()
	current_scene = null
	if is_instance_valid(session):
		session.queue_free()
	session = null
	runtime = null
	Enemy.set_performance_metrics_enabled(false)
	for frame in 6:
		await get_tree().process_frame
	_finish(0)


func _verify_host_reconnect() -> void:
	while not FileAccess.file_exists(output_directory.path_join("reconnect_disconnected.json")):
		await get_tree().process_frame
	var previous: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(output_directory.path_join("reconnect_disconnected.json")))
	var old_peer_id := int(previous["old_peer_id"])
	while not net.is_session_member_suspended(old_peer_id):
		await get_tree().process_frame
	var stable_key := net.get_stable_participant_key(old_peer_id)
	var incarnation := net.get_session_participant_incarnation(old_peer_id)
	if stable_key != previous["stable_key"] or incarnation != int(previous["incarnation"]):
		_fail("Suspended member lost its stable participant identity")
		return
	_write_json("reconnect_suspended.json", {"old_peer_id": old_peer_id})
	while not FileAccess.file_exists(output_directory.path_join("reconnect_client.json")):
		await get_tree().process_frame
	var restored: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(output_directory.path_join("reconnect_client.json")))
	var new_peer_id := int(restored["new_peer_id"])
	while not net.is_session_member_active(new_peer_id):
		await get_tree().process_frame
	if (
		new_peer_id == old_peer_id or net.has_session_member(old_peer_id)
		or net.get_stable_participant_key(new_peer_id) != stable_key
		or net.get_session_participant_incarnation(new_peer_id) != incarnation
		or net.get_active_session_member_peer_ids().size() != participant_count
		or runtime.get_player_for_peer(new_peer_id) == null
		or int(_input_sequences()["host_accepted"].get(new_peer_id, 0)) <= 0
	):
		_fail("Host did not migrate the reconnect identity, player and active input lease")
		return
	var enemy_ids := runtime.get_network_enemy_ids()
	enemy_ids.sort()
	var plant_ids := runtime.plant_system.plants_by_net_id.keys()
	plant_ids.sort()
	_write_json("reconnect_host.json", {
		"old_peer_id": old_peer_id, "new_peer_id": new_peer_id,
		"stable_key": stable_key, "incarnation": incarnation,
		"enemy_ids": enemy_ids, "plant_ids": plant_ids,
		"active_players": net.get_active_session_member_peer_ids().size(),
		"host_accepted_input": _input_sequences()["host_accepted"][new_peer_id],
	})
	while not FileAccess.file_exists(output_directory.path_join("reconnect_roster_pass.json")):
		await get_tree().process_frame


func _perform_client_reconnect(relay_context: Dictionary) -> void:
	if transport == "relay":
		_write_json("reconnect_ticket_refresh_requested.json", {"requested": true})
		while not FileAccess.file_exists(output_directory.path_join("reconnect_tickets_refreshed.json")):
			await get_tree().process_frame
		relay_context = JSON.parse_string(FileAccess.get_file_as_string(output_directory.path_join("relay_context.json")))
	var old_peer_id := net.get_local_peer_id()
	var stable_key := net.get_stable_participant_key(old_peer_id)
	var incarnation := net.get_session_participant_incarnation(old_peer_id)
	var started_msec := Time.get_ticks_msec()
	_write_json("reconnect_disconnected.json", {
		"old_peer_id": old_peer_id, "stable_key": stable_key, "incarnation": incarnation,
	})
	root.multiplayer.multiplayer_peer.close()
	net.disconnect_from_game()
	runtime.prepare_for_scene_teardown()
	current_scene = null
	session.queue_free()
	session = null
	runtime = null
	for frame in 6:
		await get_tree().process_frame
	while not FileAccess.file_exists(output_directory.path_join("reconnect_suspended.json")):
		await get_tree().process_frame
	# Exercise the public refusal path before using the retained identity. This
	# proves the uninitialized-route fix did not grant a new identity admission.
	var retained_token := net.local_reconnect_token
	var invalid_token := retained_token.sha256_text().left(32)
	if invalid_token == retained_token or not net.set_local_reconnect_token(invalid_token):
		_fail("Could not prepare independent rejected reconnect identity")
		return
	var rejected_reasons: Array[String] = []
	var capture_rejection := func(reason: String) -> void: rejected_reasons.append(reason)
	net.connection_failed.connect(capture_rejection)
	var rejected_error := _connect_reconnect_transport(relay_context, true)
	if rejected_error != OK:
		_fail("Unknown-identity probe failed before admission")
		return
	while rejected_reasons.is_empty() or net.connection_state != NetManagerStore.ConnectionState.DISCONNECTED:
		await get_tree().process_frame
	net.connection_failed.disconnect(capture_rejection)
	_write_json("reconnect_unknown_identity_result.json", {"reasons": rejected_reasons})
	if rejected_reasons != ["房间已经开始；该身份没有可恢复的断线席位。"] or not net.set_local_reconnect_token(retained_token):
		_fail("Unknown reconnect identity did not receive the exact missing-seat refusal")
		return
	_write_json("reconnect_unknown_identity_rejected.json", {"rejected": true})
	_load_started = false
	net.connection_failed.connect(_fail)
	net.connection_state_changed.connect(_on_connection_state_changed)
	var connect_error := _connect_reconnect_transport(relay_context, false)
	if connect_error != OK:
		_fail("Reconnect transport returned " + error_string(connect_error))
		return
	while net.connection_state != NetManagerStore.ConnectionState.IN_GAME:
		await get_tree().process_frame
	session = root.get_node("MpGame")
	runtime = session.get("game") as TowerDefenseGame
	var new_peer_id := net.get_local_peer_id()
	if (
		new_peer_id == old_peer_id or net.get_stable_participant_key(new_peer_id) != stable_key
		or net.get_session_participant_incarnation(new_peer_id) != incarnation
	):
		_fail("Client did not retain its stable identity across the new transport peer")
		return
	_controls_enabled = true
	Input.action_press("shoot_up")
	var starting_projectiles: int = session.projectile_coordinator.get("_next_projectile_sequence")
	for frame in 120:
		await get_tree().physics_frame
	_controls_enabled = false
	Input.action_release("shoot_up")
	if not _movement_action.is_empty():
		Input.action_release(_movement_action)
	var new_projectiles := int(session.projectile_coordinator.get("_next_projectile_sequence")) - starting_projectiles
	if new_projectiles <= 0 or int(_input_sequences()["sent"]) <= 0:
		_fail("Restored client could not resume authoritative input and firing")
		return
	_write_json("reconnect_client.json", {
		"old_peer_id": old_peer_id, "new_peer_id": new_peer_id,
		"stable_key": stable_key, "incarnation": incarnation,
		"elapsed_ms": Time.get_ticks_msec() - started_msec,
		"local_projectiles": new_projectiles, "input_sent": _input_sequences()["sent"],
	})
	while not FileAccess.file_exists(output_directory.path_join("reconnect_host.json")):
		await get_tree().process_frame
	var host_state: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(output_directory.path_join("reconnect_host.json")))
	var roster_deadline := Time.get_ticks_msec() + 10000
	while true:
		var enemy_ids := runtime.get_network_enemy_ids()
		enemy_ids.sort()
		var plant_ids := runtime.plant_system.plants_by_net_id.keys()
		plant_ids.sort()
		if _same_network_ids(enemy_ids, host_state["enemy_ids"]) and _same_network_ids(plant_ids, host_state["plant_ids"]):
			break
		if Time.get_ticks_msec() > roster_deadline:
			_write_json("reconnect_roster_mismatch.json", {"enemy_ids": enemy_ids, "plant_ids": plant_ids, "metrics": session.get_snapshot_packet_metrics()})
			_fail("Restored client roster did not converge: enemies=%d plants=%d" % [enemy_ids.size(), plant_ids.size()])
			return
		await get_tree().process_frame
	_write_json("reconnect_roster_pass.json", {"enemies": runtime.get_network_enemy_count(), "plants": runtime.plant_system.plants_by_net_id.size()})
	net.connection_failed.disconnect(_fail)
	net.connection_state_changed.disconnect(_on_connection_state_changed)


func _connect_reconnect_transport(relay_context: Dictionary, rejected_identity: bool) -> Error:
	if transport == "relay":
		var host_info: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(output_directory.path_join("host_ready.json")))
		return net.client_join_relay_room("127.0.0.1", port, int(host_info["host_peer_id"]),
			relay_context["room_id"], relay_context["rejected_identity_ticket" if rejected_identity else "reconnect_ticket"])
	return net.client_connect_lan("127.0.0.1", port)


func _same_network_ids(actual: Array, expected: Array) -> bool:
	if actual.size() != expected.size():
		return false
	for index in actual.size():
		# JSON numbers are floats; compare the integer wire identity, not text
		# formatting such as [1] versus [1.0]. No state is applied from these files.
		if int(actual[index]) != int(expected[index]):
			return false
	return true


func _verify_retained_route_identity() -> bool:
	# A fresh reconnecting process initializes from the final authenticated
	# roster; surviving processes must migrate their already retained avatars.
	var exploration := runtime.rogue_exploration_coordinator
	if not exploration._ensure_route_runtime_identity():
		_fail("Restored embedded route identity could not initialize")
		return false
	var route := exploration.get_node("RogueRoute") as RogueRouteGame
	var host_state: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(output_directory.path_join("reconnect_host.json")))
	var old_peer_id := int(host_state["old_peer_id"])
	var new_peer_id := int(host_state["new_peer_id"])
	var knows_reconnected_stable_key := role == "host" or fixture_index == participant_count - 1
	if (
		route.get_player_for_peer(old_peer_id) != null
		or route.get_player_for_peer(new_peer_id) == null
		or route.peer_players.size() != participant_count
		or (
			knows_reconnected_stable_key
			and route.get("_player_stable_keys").get(new_peer_id, "") != host_state["stable_key"]
		)
	):
		_write_json("route_identity_mismatch_%d.json" % fixture_index, {
			"old_exists": route.get_player_for_peer(old_peer_id) != null,
			"new_exists": route.get_player_for_peer(new_peer_id) != null,
			"players": route.peer_players.size(), "knows_stable_key": knows_reconnected_stable_key,
		})
		_fail("Retained inactive route did not migrate its avatar and stable identity")
		return false
	_write_json("route_identity_peer_%d.json" % fixture_index, {"players": route.peer_players.size(), "old_removed": true, "new_peer_id": new_peer_id})
	return true


func _on_connection_state_changed(state: int) -> void:
	print("DENSITY_STATE ", fixture_index, " ", state)
	if state != NetManagerStore.ConnectionState.LOADING_GAME or _load_started:
		return
	_load_started = true
	_load_start_msec = Time.get_ticks_msec()
	(root.get_node("RunState") as RunStateStore).begin_new_run(&"weishidaier", true)
	(root.get_node("GameLoadCoordinator") as Node).call_deferred(&"begin_multiplayer")


func _populate() -> void:
	runtime.random_generator.seed = 20260908
	for peer_id in net.connected_players:
		var player := runtime.get_player_for_peer(peer_id)
		player.configure_run_stat_bonuses({"max_health": 10000000})
		player.current_health = player.max_health
	var plant_ids := [&"corn_machine_gun", &"agave_cannon", &"water_collector", &"oak_warehouse"]
	var candidate_cells: Array[Vector2i] = []
	var placement_area := runtime.plant_system.placement_area
	for y in range(placement_area.position.y, placement_area.end.y - 1, 2):
		for x in range(placement_area.position.x, placement_area.end.x - 1, 2):
			var cell := Vector2i(x, y)
			var available := true
			for offset in [Vector2i.ZERO, Vector2i.RIGHT, Vector2i.DOWN, Vector2i.ONE]:
				if runtime.plant_system.reserved_cells.has(cell + offset):
					available = false
					break
			if available:
				candidate_cells.append(cell)
	if candidate_cells.size() < building_count:
		_fail("Fixture requires more unreserved 2x2 cells than the production map provides")
		return
	for index in building_count:
		var plant_id: StringName = plant_ids[index % plant_ids.size()]
		var config := runtime.plant_system.get_config(plant_id).duplicate() as PlantDefenseConfig
		config.max_health = 10000000
		var cell := candidate_cells[index]
		var building := runtime.plant_system._instantiate_registered_plant(
			config, cell, runtime.player, index + 1, false, -1, 0, -1, false
		)
		if building == null:
			_fail("Failed fixture building " + str(index))
			return
		session.tower_world_coordinator._on_host_plant_spawned(
			0, net.get_local_peer_id(), index + 1, plant_id, cell,
			building.current_health, building.max_health, building.health_revision
		)
		if building is ProductionBuilding:
			var producer := building as ProductionBuilding
			producer.recipe_unlock_checker = Callable()
			if not producer.recipes.is_empty():
				producer.select_recipe(producer.recipes[0].recipe_id)
				producer.set_production_loop_enabled(true)
		if index % 16 == 15:
			await get_tree().process_frame
	for index in enemy_count:
		var config_path := _enemy_paths[index]
		var wire_config := load(config_path) as EnemyConfig
		var enemy := wire_config.enemy_scene.instantiate() as Enemy
		runtime.enemy_container.add_child(enemy)
		enemy.global_position = Vector2(560 + index % 25 * 12, 130 + index / 25 * 18)
		enemy.setup(wire_config, runtime.player, null, runtime)
		# Keep the registered canonical config identity: reconnect spawn rosters
		# correctly reject duplicated Resources with an empty resource_path.
		enemy.set_runtime_max_health_multiplier(10000000.0 / wire_config.max_health, true)
		runtime.enemy_coordinator.assign_enemy_targets(enemy, enemy.global_position)
		runtime.enemy_coordinator.finalize_authoritative_enemy_spawn(
			enemy, wire_config, enemy.global_position, true
		)
		if index % 16 == 15:
			await get_tree().process_frame


func _write_json(name: String, value: Dictionary) -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(output_directory))
	var file := FileAccess.open(output_directory.path_join(name), FileAccess.WRITE)
	file.store_string(JSON.stringify(value, "\t"))
	file.close()


func _player_health_summary() -> Dictionary:
	var states := {}
	for player: Player in runtime.peer_players.values():
		states[player.peer_id] = {"max_health": player.max_health, "health": player.current_health, "dead": player.is_dead}
	return states


func _warehouse_summary() -> Dictionary:
	var water_count := 0
	var revisions: Dictionary = {}
	for building: PlantDefense in runtime.plant_system.plants_by_net_id.values():
		if building is OakWarehouse:
			var warehouse := building as OakWarehouse
			revisions[str(warehouse.warehouse_net_id)] = warehouse.storage_revision
			for slot in warehouse.STORAGE_CAPACITY:
				var item := warehouse.storage_items[slot]
				if item != null and item.resource_path == "res://resources/config/materials/material_water_bottle.tres":
					water_count += warehouse.get_storage_item_count(slot)
	return {"water_count": water_count, "revisions": revisions}


func _warehouse_checkpoint_matches(expected: Dictionary) -> bool:
	var actual := _warehouse_summary()
	if int(actual["water_count"]) != int(expected["water_count"]):
		return false
	var actual_revisions: Dictionary = actual["revisions"]
	var expected_revisions: Dictionary = expected["revisions"]
	if actual_revisions.size() != expected_revisions.size():
		return false
	for warehouse_id: String in expected_revisions:
		if int(actual_revisions.get(warehouse_id, -1)) != int(expected_revisions[warehouse_id]):
			return false
	return true


func _input_sequences() -> Dictionary:
	var accepted: Dictionary = {}
	if role == "host":
		for peer_id: int in net.connected_players:
			if peer_id != net.get_local_peer_id():
				accepted[peer_id] = session.player_coordinator.get_last_accepted_player_input_sequence(peer_id)
	return {"sent": session.player_coordinator.get_realtime_input_sequence(), "host_accepted": accepted}


func _pop_native_transport_stats() -> Dictionary:
	var native_peer: ENetMultiplayerPeer
	if transport == "relay":
		native_peer = root.multiplayer.multiplayer_peer.get("_transport") as ENetMultiplayerPeer
	else:
		native_peer = root.multiplayer.multiplayer_peer as ENetMultiplayerPeer
	var connection := native_peer.host
	var peers: Array[Dictionary] = []
	for peer: ENetPacketPeer in connection.get_peers():
		peers.append({
			"remote_port": peer.get_remote_port(),
			"mean_reliable_rtt_ms": peer.get_statistic(ENetPacketPeer.PEER_ROUND_TRIP_TIME),
			"mean_reliable_loss_ratio": peer.get_statistic(ENetPacketPeer.PEER_PACKET_LOSS) / ENetPacketPeer.PACKET_LOSS_SCALE,
			"unreliable_throttle_ratio": peer.get_statistic(ENetPacketPeer.PEER_PACKET_THROTTLE) / ENetPacketPeer.PACKET_THROTTLE_SCALE,
		})
	# These native counters include ENet framing and retransmissions without the
	# opt-in extra Variant serialization. No other project caller consumes them.
	return {
		"sent_bytes": connection.pop_statistic(ENetConnection.HOST_TOTAL_SENT_DATA),
		"sent_udp_packets": connection.pop_statistic(ENetConnection.HOST_TOTAL_SENT_PACKETS),
		"received_bytes": connection.pop_statistic(ENetConnection.HOST_TOTAL_RECEIVED_DATA),
		"received_udp_packets": connection.pop_statistic(ENetConnection.HOST_TOTAL_RECEIVED_PACKETS),
		"physical_peers": peers,
	}


func _fail(message: String) -> void:
	if _failed:
		return
	_failed = true
	printerr("DENSITY_FAILURE ", fixture_index, " ", message)
	_write_json("failure_%d.json" % fixture_index, {"error": message})
	_finish(2)


func _summarize(values: Array[float]) -> Dictionary:
	if values.is_empty():
		return {}
	values.sort()
	return {
		"count": values.size(), "p50": values[int((values.size() - 1) * 0.5)],
		"p95": values[int((values.size() - 1) * 0.95)],
		"p99": values[int((values.size() - 1) * 0.99)], "max": values[-1]
	}


func _finish(exit_code: int) -> void:
	if _finishing:
		return
	_finishing = true
	_sampling = false
	_controls_enabled = false
	result["exit_code"] = exit_code
	queue_free()
