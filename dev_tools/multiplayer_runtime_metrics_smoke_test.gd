extends SceneTree

const MetricsScript := preload("res://scene/multiplayer/multiplayer_runtime_metrics.gd")

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
	if failures.is_empty():
		print("MULTIPLAYER_RUNTIME_METRICS_SMOKE_TEST_OK")
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	quit(1)


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
