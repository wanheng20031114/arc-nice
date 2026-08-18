extends SceneTree

const DIAGNOSTICS_SCENE := preload(
	"res://scene/multiplayer/network_diagnostics/mp_network_diagnostics_coordinator.tscn"
)
const MP_GAME_SCENE := preload("res://scene/multiplayer/mp_game.tscn")
const MP_GAME_SOURCE_PATH := "res://scene/multiplayer/mp_game.gd"

var failures: Array[String] = []


func _init() -> void:
	var diagnostics := (
		DIAGNOSTICS_SCENE.instantiate()
		as MpNetworkDiagnosticsCoordinator
	)
	_expect(diagnostics != null, "NetworkDiagnosticsCoordinator scene must instantiate.")
	if diagnostics != null:
		_test_static_boundary(diagnostics)
		_test_metrics_contract(diagnostics)
		diagnostics.free()
	_finish()


func _test_static_boundary(diagnostics: MpNetworkDiagnosticsCoordinator) -> void:
	var mp_game := MP_GAME_SCENE.instantiate()
	_expect(
		mp_game != null
		and mp_game.get_node_or_null("NetworkDiagnosticsCoordinator")
		is MpNetworkDiagnosticsCoordinator,
		"MpGame must statically contain NetworkDiagnosticsCoordinator."
	)
	if mp_game != null:
		mp_game.free()
	var source := FileAccess.get_file_as_string(MP_GAME_SOURCE_PATH)
	var rpc_pattern := RegEx.new()
	rpc_pattern.compile("(?m)^@rpc\\(")
	_expect(
		rpc_pattern.search_all(source).size() == 144,
		"Diagnostics extraction must preserve all 144 protocol-v85 MpGame RPC facades."
	)
	var send_body := _function_body(source, "_rpc_to_connected_clients")
	_expect(
		send_body.find("callv(\"rpc_id\"") >= 0
		and send_body.find("_record_outbound_rpc(")
		> send_body.find("callv(\"rpc_id\""),
		"MpGame must record broadcast diagnostics only after actual sends."
	)
	_expect(
		not source.contains("var _rpc_payload_call_counts")
		and not source.contains("var _snapshot_packet_warn_time_left")
		and not source.contains("const TRANSACTION_RPC_METHODS")
		and source.contains(
			"_get_network_diagnostics_coordinator().record_outbound_rpc"
		),
		"MpGame must delegate extracted diagnostics state and algorithms."
	)
	var diagnostics_source := diagnostics.get_script().source_code as String
	_expect(
		not diagnostics_source.contains("current_scene")
		and not diagnostics_source.contains("has_method")
		and not diagnostics_source.contains(".call("),
		"Network diagnostics must not guess runtime capabilities."
	)
	_expect(
		MpNetworkDiagnosticsCoordinator.get_rpc_traffic_channel(
			&"net_projectile_fired"
		) == 4
		and MpNetworkDiagnosticsCoordinator.get_rpc_traffic_channel(
			&"net_inventory_snapshot"
		) == 6
		and MpNetworkDiagnosticsCoordinator.get_rpc_traffic_channel(
			&"net_enemy_action"
		) == 7
		and MpNetworkDiagnosticsCoordinator.get_rpc_traffic_channel(
			&"net_enemy_spawned"
		) == 5,
		"Stable RPC channel classification must remain 4/6/7/5."
	)


func _test_metrics_contract(diagnostics: MpNetworkDiagnosticsCoordinator) -> void:
	diagnostics.record_outbound_rpc(&"net_enemy_action", [1, Vector2.ONE], 3)
	var initial := diagnostics.get_snapshot_packet_metrics(0, 0, {}, {})
	var initial_channels := initial.get("channel_metrics", []) as Array
	_expect(
		initial_channels.size() == 8
		and int((initial_channels[7] as Dictionary).get("packet_count", 0)) == 3
		and int((initial_channels[7] as Dictionary).get("payload_bytes_total", -1)) == 0,
		"Production diagnostics must count packets without serializing payloads."
	)

	diagnostics.set_rpc_payload_diagnostics_enabled(true)
	for sample_index in range(64):
		diagnostics.record_outbound_rpc(
			&"net_inventory_snapshot",
			[sample_index, {"revision": sample_index}],
			1
		)
	diagnostics.record_snapshot_packet_size(&"player", 128, 4)
	diagnostics.record_snapshot_packet_size(&"enemy", 1400, 90)
	diagnostics.update_snapshot_packet_warning_timer(10.0)
	diagnostics.record_snapshot_packet_size(&"enemy", 1500, 91)
	diagnostics.record_state_repair()
	for latency_ms in [10.0, 20.0, 50.0]:
		diagnostics.record_transaction_latency_ms(latency_ms)
	diagnostics.record_player_input_rejection(&"non_finite_input")
	diagnostics.record_player_input_rejection(&"non_finite_input")
	diagnostics.record_player_input_rejection(&"sequence_jump")
	var enemy_metrics := {
		"enemy_snapshot_batch_count": 7,
		"enemy_snapshot_chunk_encode_count": 8,
		"enemy_snapshot_cohort_size": 3,
		"enemy_snapshot_completed_batch_count": 6,
		"enemy_snapshot_incomplete_batch_evict_count": 2,
		"enemy_snapshot_stale_chunk_count": 1,
		"offscreen_enemy_proxy_count": 9,
	}
	var pool_metrics := {"enemy": {"active": 12}}
	var metrics := diagnostics.get_snapshot_packet_metrics(
		11,
		4,
		enemy_metrics,
		pool_metrics
	)
	var channels := metrics.get("channel_metrics", []) as Array
	_expect(
		int(metrics.get("max_player_snapshot_packet_bytes", 0)) == 128
		and int(metrics.get("max_enemy_snapshot_packet_bytes", 0)) == 1500
		and int(metrics.get("large_player_snapshot_packet_count", -1)) == 0
		and int(metrics.get("large_enemy_snapshot_packet_count", 0)) == 2
		and int(metrics.get("enemy_snapshot_payload_bytes_total", 0)) == 2900
		and int(metrics.get("enemy_snapshot_packet_count", 0)) == 2,
		"Snapshot packet maxima, totals, and warning counts must remain exact."
	)
	_expect(
		bool(metrics.get("rpc_payload_diagnostics_enabled", false))
		and int(metrics.get("rpc_payload_diagnostic_sample_interval", 0)) == 64
		and int(metrics.get("rpc_payload_diagnostic_sample_count", 0)) == 2
		and int(metrics.get("state_repair_count", 0)) == 1
		and int(metrics.get("transaction_latency_sample_count", 0)) == 3
		and is_equal_approx(
			float(metrics.get("transaction_latency_p95_ms", 0.0)),
			50.0
		),
		"Payload sampling, repair, and latency summary semantics must remain unchanged."
	)
	var input_rejection_counts := (
		metrics.get("player_input_rejection_counts", {}) as Dictionary
	)
	_expect(
		int(metrics.get("player_input_rejection_total", 0)) == 3
		and int(input_rejection_counts.get(&"non_finite_input", 0)) == 2
		and int(input_rejection_counts.get(&"sequence_jump", 0)) == 1,
		"玩家输入拒绝必须按原因汇总到生产网络诊断。"
	)
	_expect(
		int(metrics.get("player_snapshot_encode_count", 0)) == 11
		and int(metrics.get("player_snapshot_cohort_size", 0)) == 4
		and int(metrics.get("enemy_snapshot_batch_count", 0)) == 7
		and int(metrics.get("offscreen_enemy_proxy_count", 0)) == 9
		and metrics.get("pool_metrics", {}) == pool_metrics,
		"External snapshot and pool metrics must pass through unchanged."
	)
	_expect(
		channels.size() == 8
		and int((channels[2] as Dictionary).get("payload_bytes_total", 0)) == 144
		and int((channels[3] as Dictionary).get("payload_bytes_total", 0)) == 2948
		and int((channels[6] as Dictionary).get("packet_count", 0)) == 64,
		"Per-channel snapshot overhead, payload bytes, and packet totals must remain exact."
	)
	_expect(
		not metrics.has("player_snapshot_packet_p50_bytes")
		and not metrics.has("enemy_snapshot_packet_p95_bytes"),
		"Extraction must not invent new snapshot percentile dictionary keys."
	)

	diagnostics.clear_peer(2)
	var after_peer_clear := diagnostics.get_snapshot_packet_metrics(0, 0, {}, {})
	_expect(
		int(after_peer_clear.get("enemy_snapshot_packet_count", 0)) == 2,
		"Peer cleanup must retain session-wide aggregate diagnostics."
	)
	diagnostics.reset_session_state()
	var reset_metrics := diagnostics.get_snapshot_packet_metrics(0, 0, {}, {})
	var reset_channels := reset_metrics.get("channel_metrics", []) as Array
	_expect(
		not bool(reset_metrics.get("rpc_payload_diagnostics_enabled", true))
		and int(reset_metrics.get("enemy_snapshot_packet_count", -1)) == 0
		and int(reset_metrics.get("state_repair_count", -1)) == 0
		and int(reset_metrics.get("player_input_rejection_total", -1)) == 0
		and (
			reset_metrics.get("player_input_rejection_counts", {}) as Dictionary
		).is_empty()
		and reset_channels.size() == 8
		and int((reset_channels[7] as Dictionary).get("packet_count", -1)) == 0,
		"Session reset must clear every diagnostic counter and restore production mode."
	)


func _function_body(source: String, function_name: String) -> String:
	var function_start := source.find("func %s(" % function_name)
	if function_start < 0:
		return ""
	var body_start := source.find(") -> void:\n", function_start)
	if body_start < 0:
		return ""
	body_start += ") -> void:".length()
	var next_function := source.find("\nfunc ", body_start + 1)
	var body_end := source.length() if next_function < 0 else next_function
	return source.substr(body_start + 1, body_end - body_start - 1)


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)


func _finish() -> void:
	if failures.is_empty():
		print("MP_NETWORK_DIAGNOSTICS_COORDINATOR_SMOKE_TEST_OK")
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	quit(1)
