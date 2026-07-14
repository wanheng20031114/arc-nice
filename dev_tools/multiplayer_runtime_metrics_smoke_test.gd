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
	_expect(channels.size() == 8, "Protocol v6 telemetry must expose all eight channels.")
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
	_test_authoritative_plant_registry_count()
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


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
