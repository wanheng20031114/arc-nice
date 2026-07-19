extends SceneTree

const MetricsScript := preload("res://scene/multiplayer/multiplayer_runtime_metrics.gd")
const MpGameScript := preload("res://scene/multiplayer/mp_game.gd")

var failures: Array[String] = []


func _init() -> void:
	var metrics: Variant = MetricsScript.new(8)
	metrics.call("record_packet", 3, 1066, 20)
	metrics.call("record_packet", 6, 240, 2)
	metrics.call("record_packet", 8, 999, 1)
	metrics.call("record_state_repair")
	metrics.call("record_incomplete_batch")
	for latency in [25.0, 30.0, 40.0, 80.0, 110.0]:
		metrics.call("record_transaction_latency_ms", latency)
	var summary := metrics.call("get_summary") as Dictionary
	var channels := summary.get("channels", []) as Array
	_expect(channels.size() == 8, "Protocol v14 telemetry must expose all eight channels.")
	if channels.size() == 8:
		var enemy_channel := channels[3] as Dictionary
		_expect(
			int(enemy_channel.get("payload_bytes_total", 0)) == 21_320
			and int(enemy_channel.get("packet_count", 0)) == 20
			and int(enemy_channel.get("max_packet_bytes", 0)) == 1066,
			"Enemy-channel telemetry must retain bytes, packets, and maximum packet size."
		)
	_expect(
		int(summary.get("state_repair_count", 0)) == 1
		and int(summary.get("incomplete_batch_count", 0)) == 1,
		"Repair and incomplete-batch counters must remain independently observable."
	)
	_expect(
		is_equal_approx(float(summary.get("transaction_latency_p95_ms", 0.0)), 110.0),
		"Transaction telemetry must report a bounded p95 sample."
	)
	_test_mp_game_rpc_payload_diagnostics()
	_test_outbound_rpc_channel_classification()
	_test_authoritative_plant_registry_count()
	_test_client_enemy_count_render_cache()
	if failures.is_empty():
		print("MULTIPLAYER_RUNTIME_METRICS_SMOKE_TEST_OK")
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	quit(1)


func _test_mp_game_rpc_payload_diagnostics() -> void:
	var mp_game := MpGameScript.new()
	mp_game.call("_record_outbound_rpc", &"net_enemy_action", [1, Vector2.ONE], 3)
	var production_metrics := mp_game.call("get_snapshot_packet_metrics") as Dictionary
	var production_channels := production_metrics.get("channel_metrics", []) as Array
	_expect(
		not bool(production_metrics.get("rpc_payload_diagnostics_enabled", true))
		and int(production_metrics.get("rpc_payload_diagnostic_sample_count", -1)) == 0,
		"Production RPC metrics must not serialize payload arguments by default."
	)
	if production_channels.size() == 8:
		var feedback_channel := production_channels[7] as Dictionary
		_expect(
			int(feedback_channel.get("packet_count", 0)) == 3
			and int(feedback_channel.get("payload_bytes_total", -1)) == 0,
			"Disabled payload diagnostics must retain exact packet counts without byte serialization."
		)

	mp_game.call("set_rpc_payload_diagnostics_enabled", true)
	for sample_index in range(64):
		mp_game.call(
			"_record_outbound_rpc",
			&"net_enemy_action",
			[sample_index, Vector2(sample_index, -sample_index)],
			1
		)
	var diagnostic_metrics := mp_game.call("get_snapshot_packet_metrics") as Dictionary
	_expect(
		bool(diagnostic_metrics.get("rpc_payload_diagnostics_enabled", false))
		and int(diagnostic_metrics.get("rpc_payload_diagnostic_sample_interval", 0)) == 64
		and int(diagnostic_metrics.get("rpc_payload_diagnostic_sample_count", 0)) == 2,
		"Opt-in RPC bytes must sample once immediately and refresh at the documented interval."
	)
	mp_game.free()


func _test_outbound_rpc_channel_classification() -> void:
	var source := FileAccess.get_file_as_string("res://scene/multiplayer/mp_game.gd")
	var rpc_regex := RegEx.new()
	var rpc_compile_error := rpc_regex.compile(
		"(?ms)@rpc\\([^)]*,\\s*([0-9]+)\\)\\s*func\\s+([A-Za-z0-9_]+)\\s*\\("
	)
	_expect(rpc_compile_error == OK, "RPC channel audit regex must compile.")
	if rpc_compile_error != OK:
		return
	var declared_channels: Dictionary = {}
	for rpc_match in rpc_regex.search_all(source):
		declared_channels[StringName(rpc_match.get_string(2))] = int(
			rpc_match.get_string(1)
		)

	var outbound_regex := RegEx.new()
	var outbound_compile_error := outbound_regex.compile(
		"(?ms)(?:_rpc_to_connected_clients|_record_outbound_rpc)"
		+ "\\s*\\(\\s*&\"([A-Za-z0-9_]+)\""
	)
	_expect(outbound_compile_error == OK, "Outbound RPC audit regex must compile.")
	if outbound_compile_error != OK:
		return
	var mp_game := MpGameScript.new()
	var checked_methods: Dictionary = {}
	for outbound_match in outbound_regex.search_all(source):
		var method_name := StringName(outbound_match.get_string(1))
		if checked_methods.has(method_name):
			continue
		checked_methods[method_name] = true
		var declared_channel := int(declared_channels.get(method_name, -1))
		_expect(
			declared_channel >= 0,
			"Outbound telemetry method %s must have a declared RPC." % method_name
		)
		if declared_channel < 0:
			continue
		_expect(
			int(mp_game.call("_get_rpc_traffic_channel", method_name))
			== declared_channel,
			"Outbound telemetry for %s must use declared channel %d."
			% [method_name, declared_channel]
		)
	_expect(
		checked_methods.size() >= 30,
		"Outbound channel audit must cover the complete literal RPC send surface."
	)
	mp_game.free()


func _test_authoritative_plant_registry_count() -> void:
	var mp_game := MpGameScript.new()
	var tower_game := GameTowerDefense.new()
	var plant_system := PlantSystem.new()
	var plant := PlantDefense.new()
	tower_game.plant_system = plant_system
	plant_system.plants_by_net_id[41] = plant
	mp_game.game = tower_game
	_expect(
		int(mp_game.call("_get_authoritative_team_plant_count")) == 1,
		"Multiplayer plant limits must read the authoritative O(1) registry count."
	)
	plant_system.plants_by_net_id.clear()
	plant.free()
	plant_system.free()
	tower_game.free()
	mp_game.free()


func _test_client_enemy_count_render_cache() -> void:
	var source := FileAccess.get_file_as_string("res://scene/multiplayer/mp_game.gd")
	_expect(
		source.contains(
			"if remote_enemy_count != _last_applied_remote_enemy_count:"
		)
		and source.contains(
			"_last_applied_remote_enemy_count = remote_enemy_count"
		)
		and source.contains(
			"_last_applied_remote_enemy_count = -1\n\tgame.apply_remote_flow_state"
		),
		"Client enemy-count HUD writes must occur only on count changes and invalidate on flow transitions."
	)


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
