extends SceneTree

const MAIN_MP_GAME_PATH := "res://scene/multiplayer/mp_game.gd"
const RELAY_MP_GAME_PATH := "res://relay_servers/relay_godot_project/relay_mp_game_stub.gd"
const MAIN_NET_MANAGER_PATH := "res://scene/multiplayer/net_manager.gd"
const RELAY_NET_MANAGER_PATH := "res://relay_servers/relay_godot_project/relay_net_manager_stub.gd"
const NetConstants := preload("res://scene/multiplayer/net_constants.gd")

var failures: Array[String] = []


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	var main_rpcs := _extract_rpc_surface(MAIN_MP_GAME_PATH)
	var relay_rpcs := _extract_rpc_surface(RELAY_MP_GAME_PATH)
	_compare_rpc_surfaces("MpGame", main_rpcs, relay_rpcs)
	for required_method in [
		"net_tiyi_high_noon_requested",
		"net_tiyi_high_noon_started",
		"net_tiyi_high_noon_targets",
		"net_tiyi_high_noon_finished",
		"net_tiyi_high_noon_cancelled",
		"net_tiyi_sniper_hit_confirmed",
	]:
		_expect(main_rpcs.has(required_method), "Tiyi RPC %s must be registered." % required_method)
	if main_rpcs.has("net_tiyi_high_noon_requested"):
		_expect(
			String(main_rpcs["net_tiyi_high_noon_requested"]).contains("activation_id:int"),
			"High-noon requests must carry their monotonic activation id."
		)

	var main_net_manager_rpcs := _extract_rpc_surface(MAIN_NET_MANAGER_PATH)
	var relay_net_manager_rpcs := _extract_rpc_surface(RELAY_NET_MANAGER_PATH)
	_compare_rpc_surfaces("NetManager", main_net_manager_rpcs, relay_net_manager_rpcs)
	for required_method in [
		"_rpc_register_player",
		"_rpc_protocol_rejected",
		"_rpc_set_player_character",
		"_rpc_sync_player_list",
		"_rpc_start_game",
		"_rpc_host_game_ready",
	]:
		_expect(
			main_net_manager_rpcs.has(required_method),
			"NetManager RPC %s must be registered in the main and Relay projects." % required_method
		)
	if main_net_manager_rpcs.has("_rpc_register_player"):
		_expect(
			String(main_net_manager_rpcs["_rpc_register_player"]).contains(
				"protocol_version:int=-1"
			),
			"Player registration must carry a protocol version and reject legacy omitted values."
		)
	_test_registration_protocol_handshake_source()
	_expect(NetConstants.PROTOCOL_VERSION == 2, "Tiyi multiplayer requires protocol version 2.")

	if failures.is_empty():
		print("RELAY_RPC_PARITY_SMOKE_TEST_OK")
		quit()
		return
	for failure in failures:
		push_error(failure)
	quit(1)


func _compare_rpc_surfaces(label: String, main_rpcs: Dictionary, relay_rpcs: Dictionary) -> void:
	_expect(not main_rpcs.is_empty(), "Main %s RPC surface must not be empty." % label)
	_expect(
		main_rpcs.size() == relay_rpcs.size(),
		"Relay RPC count must match main %s (%d != %d)."
		% [label, relay_rpcs.size(), main_rpcs.size()]
	)
	for method_name_variant in main_rpcs.keys():
		var method_name := String(method_name_variant)
		_expect(relay_rpcs.has(method_name), "Relay %s is missing RPC %s." % [label, method_name])
		if relay_rpcs.has(method_name):
			_expect(
				String(relay_rpcs[method_name]) == String(main_rpcs[method_name]),
				"Relay %s RPC annotation/signature differs for %s." % [label, method_name]
			)
	for method_name_variant in relay_rpcs.keys():
		var method_name := String(method_name_variant)
		_expect(main_rpcs.has(method_name), "Relay %s has stale extra RPC %s." % [label, method_name])


func _test_registration_protocol_handshake_source() -> void:
	var source := FileAccess.get_file_as_string(MAIN_NET_MANAGER_PATH)
	_expect(not source.is_empty(), "Main NetManager source must be readable for protocol checks.")
	if source.is_empty():
		return
	var registration_call_regex := RegEx.new()
	var compile_error := registration_call_regex.compile(
		"(?ms)_rpc_register_player\\.rpc_id\\s*\\(.*?NetConstants\\.PROTOCOL_VERSION\\s*\\)"
	)
	if compile_error != OK:
		failures.append("Unable to compile registration protocol parser regex.")
		return
	_expect(
		registration_call_regex.search_all(source).size() == 2,
		"LAN and Relay registration must both send NetConstants.PROTOCOL_VERSION."
	)
	var whitespace_regex := RegEx.new()
	if whitespace_regex.compile("\\s+") != OK:
		failures.append("Unable to compile protocol whitespace regex.")
		return
	var compact_source := whitespace_regex.sub(source, "", true)
	_expect(
		compact_source.contains("ifnot_is_protocol_version_compatible(protocol_version):"),
		"Host registration must reject an incompatible protocol before adding the player."
	)
	_expect(
		compact_source.contains(
			"_rpc_protocol_rejected.rpc_id(sender_id,NetConstants.PROTOCOL_VERSION)"
		),
		"Host registration rejection must report the expected protocol version."
	)
	_expect(
		compact_source.contains("call_deferred(\"_disconnect_incompatible_peer\",sender_id)"),
		"Host registration rejection must disconnect the incompatible peer after reporting it."
	)


func _extract_rpc_surface(path: String) -> Dictionary:
	var source := FileAccess.get_file_as_string(path)
	if source.is_empty():
		failures.append("Unable to read RPC source: %s" % path)
		return {}
	var block_regex := RegEx.new()
	var compile_error := block_regex.compile(
		"(?ms)^@rpc\\([^\\r\\n]+\\)\\r?\\nfunc\\s+[A-Za-z0-9_]+\\s*\\(.*?\\)\\s*->\\s*void:"
	)
	if compile_error != OK:
		failures.append("Unable to compile RPC parser regex.")
		return {}
	var name_regex := RegEx.new()
	if name_regex.compile("(?m)^func\\s+([A-Za-z0-9_]+)") != OK:
		failures.append("Unable to compile RPC name regex.")
		return {}
	var whitespace_regex := RegEx.new()
	if whitespace_regex.compile("\\s+") != OK:
		failures.append("Unable to compile whitespace regex.")
		return {}
	var surface: Dictionary = {}
	for block_match in block_regex.search_all(source):
		var block := block_match.get_string()
		var name_match := name_regex.search(block)
		if name_match == null:
			failures.append("RPC block without a method name in %s." % path)
			continue
		var method_name := name_match.get_string(1)
		if surface.has(method_name):
			failures.append("Duplicate RPC %s in %s." % [method_name, path])
			continue
		# The relay project intentionally has no EnemyConfig class. PHYSICAL is enum value 0.
		block = block.replace("EnemyConfig.DamageType.PHYSICAL", "0")
		surface[method_name] = whitespace_regex.sub(block, "", true)
	return surface


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
