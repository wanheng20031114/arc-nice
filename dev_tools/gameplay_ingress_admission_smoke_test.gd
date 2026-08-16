extends SceneTree

const ROUTE_SCRIPT := preload("res://scene/multiplayer/mp_rogue_route.gd")
const NET_MANAGER_SOURCE_PATH := "res://scene/multiplayer/net_manager.gd"
const MP_GAME_SOURCE_PATH := "res://scene/multiplayer/mp_game.gd"
const ROUTE_SOURCE_PATH := "res://scene/multiplayer/mp_rogue_route.gd"
const COMBAT_SOURCE_PATH := (
	"res://scene/game_modes/rogue/combat/rogue_combat_multiplayer_coordinator.gd"
)


class DeniedNetManager:
	extends NetManagerStore

	func is_gameplay_ingress_admitted(_peer_id: int) -> bool:
		return false


var failures: Array[String] = []


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	_test_mp_game_gameplay_sender_boundary()
	_test_all_any_peer_gameplay_endpoints_are_classified()
	_test_route_denial_is_zero_write()
	_test_combat_requests_gate_before_domain_mutation()
	_test_control_plane_keeps_raw_sender()
	_finish()


func _test_mp_game_gameplay_sender_boundary() -> void:
	var source := FileAccess.get_file_as_string(MP_GAME_SOURCE_PATH)
	var sender_body := _get_function_body(source, "_get_rpc_sender_id")
	_expect(
		sender_body.contains("net_manager.is_gameplay_ingress_admitted(sender_id)"),
		"MpGame 玩法 sender 边界必须统一消费 NetManager 租约。"
	)
	for function_name in [
		"net_warehouse_command_requested",
		"net_warehouse_snapshot_requested",
		"net_production_command_requested",
		"net_research_command_requested",
		"net_production_snapshot_requested",
	]:
		var body := _get_function_body(source, function_name)
		_expect(
			body.contains("var sender_id := _get_rpc_sender_id()"),
			"%s 必须从统一玩法 sender 边界取得身份。" % function_name
		)
	var warehouse_body := _get_function_body(
		source,
		"net_warehouse_command_requested"
	)
	_expect(
		_gate_precedes_call(
			warehouse_body,
			"consume_remote_transaction_admission(sender_id)",
			"handle_authoritative_warehouse_command("
		),
		"仓库写入口必须位于共享事务门禁之后。"
	)


func _test_all_any_peer_gameplay_endpoints_are_classified() -> void:
	var mp_game_source := FileAccess.get_file_as_string(MP_GAME_SOURCE_PATH)
	var route_source := FileAccess.get_file_as_string(ROUTE_SOURCE_PATH)
	var control_endpoints := {
		"net_runtime_state_requested": true,
		"net_request_route_full_snapshot": true,
		"net_terrain_snapshot_requested": true,
	}
	for function_name in _get_any_peer_function_names(mp_game_source):
		var body := _get_function_body(mp_game_source, function_name)
		var classified := (
			control_endpoints.has(function_name)
			or body.contains("_get_rpc_sender_id()")
			or body.contains("consume_remote_transaction_admission(")
			or body.contains("_dispatch_tower_rogue_route_rpc(")
		)
		_expect(
			classified,
			"MpGame any_peer 入口 %s 缺少玩法门或明确控制面分类。" % function_name
		)
	for function_name in _get_any_peer_function_names(route_source):
		var body := _get_function_body(route_source, function_name)
		var classified := (
			function_name == "net_request_route_full_snapshot"
			or body.contains("_admit_route_encounter_command(")
			or body.contains("_admit_route_shop_command(")
			or body.contains("_is_gameplay_ingress_admitted(")
		)
		_expect(
			classified,
			"MpRogueRoute any_peer 入口 %s 缺少玩法门或 repair 分类。" % function_name
		)


func _test_route_denial_is_zero_write() -> void:
	var route_wrapper := ROUTE_SCRIPT.new()
	var net_manager := DeniedNetManager.new()
	route_wrapper.set("_net_manager", net_manager)
	_expect(
		not bool(route_wrapper.call("_admit_route_encounter_command", 2))
		and not bool(route_wrapper.call("_admit_route_shop_command", 2))
		and (
			route_wrapper.get("_route_encounter_command_rate_buckets") as Dictionary
		).is_empty()
		and (
			route_wrapper.get("_route_shop_command_rate_buckets") as Dictionary
		).is_empty(),
		"玩法租约未提交时，路线命令必须零写且不创建限流状态。"
	)
	route_wrapper.free()
	net_manager.free()


func _test_combat_requests_gate_before_domain_mutation() -> void:
	var source := FileAccess.get_file_as_string(COMBAT_SOURCE_PATH)
	var helper_body := _get_function_body(
		source,
		"_is_gameplay_ingress_admitted"
	)
	_expect(
		helper_body.contains("_net_manager.is_gameplay_ingress_admitted(peer_id)"),
		"战斗协议门必须委托 NetManager 的统一玩法租约。"
	)
	var contracts := [
		[
			"_accept_combat_prepared",
			"_is_gameplay_ingress_admitted(sender_id)",
			"_prepared_peers[sender_id] = true",
		],
		[
			"_accept_combat_activated",
			"_is_gameplay_ingress_admitted(sender_id)",
			"_pending_reconnect_prepare_peers.erase(sender_id)",
		],
		[
			"net_emergency_reward_choice_requested",
			"is_gameplay_ingress_admitted(sender_id)",
			"_handle_emergency_reward_choice_request(",
		],
		[
			"net_emergency_reward_completion_retry_requested",
			"is_gameplay_ingress_admitted(sender_id)",
			"_handle_emergency_reward_completion_retry(",
		],
		[
			"net_combat_terminal_ready",
			"_is_gameplay_ingress_admitted(sender_id)",
			"_terminal_ready_peers[sender_id] = true",
		],
		[
			"net_combat_abort_requested",
			"_is_gameplay_ingress_admitted(sender_id)",
			"_can_accept_client_abort_request(",
		],
	]
	for contract in contracts:
		_expect(
			_gate_precedes_call(
				_get_function_body(source, str(contract[0])),
				str(contract[1]),
				str(contract[2])
			),
			"战斗入口 %s 必须先消费玩法租约，再进入领域写路径。" % contract[0]
		)


func _test_control_plane_keeps_raw_sender() -> void:
	var net_manager_source := FileAccess.get_file_as_string(
		NET_MANAGER_SOURCE_PATH
	)
	var mp_game_source := FileAccess.get_file_as_string(MP_GAME_SOURCE_PATH)
	var route_source := FileAccess.get_file_as_string(ROUTE_SOURCE_PATH)
	for function_name in [
		"_rpc_register_player",
		"_rpc_report_game_loaded",
	]:
		var body := _get_function_body(net_manager_source, function_name)
		_expect(
			body.contains("multiplayer.get_remote_sender_id()")
			and not body.contains("is_gameplay_ingress_admitted"),
			"%s 会话控制面必须保留 raw sender。" % function_name
		)
	for function_name in [
		"net_runtime_state_requested",
		"net_terrain_snapshot_requested",
	]:
		var body := _get_function_body(mp_game_source, function_name)
		_expect(
			body.contains("multiplayer.get_remote_sender_id()")
			and not body.contains("_get_rpc_sender_id()"),
			"%s 控制面必须保留 raw sender，不能误用玩法门禁。" % function_name
		)
	var repair_body := _get_function_body(
		route_source,
		"_admit_route_repair_request"
	)
	_expect(
		not repair_body.contains("_is_gameplay_ingress_admitted"),
		"路线 repair 控制面不得依赖玩法租约。"
	)


func _gate_precedes_call(body: String, gate: String, domain_call: String) -> bool:
	var gate_offset := body.find(gate)
	var call_offset := body.find(domain_call)
	return gate_offset >= 0 and call_offset > gate_offset


func _get_function_body(source: String, function_name: String) -> String:
	var function_offset := source.find("func %s" % function_name)
	if function_offset < 0:
		return ""
	var next_function_offset := source.find("\nfunc ", function_offset + 5)
	if next_function_offset < 0:
		return source.substr(function_offset)
	return source.substr(
		function_offset,
		next_function_offset - function_offset
	)


func _get_any_peer_function_names(source: String) -> PackedStringArray:
	var pattern := RegEx.new()
	pattern.compile(
		"(?m)^@rpc\\(\"any_peer\"[^\\n]*\\)\\nfunc ([^(]+)"
	)
	var names := PackedStringArray()
	for match_result in pattern.search_all(source):
		names.append(match_result.get_string(1))
	return names


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)


func _finish() -> void:
	if failures.is_empty():
		print("GAMEPLAY_INGRESS_ADMISSION_SMOKE_TEST_OK")
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	quit(1)
