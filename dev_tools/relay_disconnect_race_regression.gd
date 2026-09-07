extends SceneTree

const RelayPeer := preload("res://scene/multiplayer/transport/authenticated_relay_multiplayer_peer.gd")
var _failures: Array[String] = []


func _initialize() -> void:
	_run.call_deferred()


func _check(condition: bool, message: String) -> void:
	if not condition:
		_failures.append(message)
		printerr("FAIL: ", message)


func _run() -> void:
	var transport := ENetMultiplayerPeer.new()
	_check(transport.create_server(0, 2, 9) == OK, "Native ENet server did not open")
	var relay := RelayPeer.new()
	_check(relay.configure(transport, true) == OK, "Relay wrapper did not configure")
	# Reproduce the exact lifetime boundary observed during the real Relay test:
	# native peer_disconnected has removed a transport, while logical membership
	# deliberately remains until the next poll drains preceding inbound packets.
	relay._physical_peers[111] = true
	relay._physical_peers[222] = true
	relay._authenticated_peers[111] = true
	relay._authenticated_peers[222] = true
	relay._on_transport_peer_disconnected(222)
	_check(relay.is_peer_authenticated(222), "Fixture lost deferred logical membership")
	_check(not relay._physical_peers.has(222), "Native disconnect did not invalidate routing")
	var payload := PackedByteArray([4, 5, 6])
	for mode: MultiplayerPeer.TransferMode in [MultiplayerPeer.TRANSFER_MODE_RELIABLE, MultiplayerPeer.TRANSFER_MODE_UNRELIABLE_ORDERED]:
		relay._consume_client_frame(111, 111, 222, relay.FRAME_TYPE_DATA, payload, mode, 4)
		relay._consume_client_frame(111, 111, 0, relay.FRAME_TYPE_DATA, payload, mode, 4)
		_check(
			relay._write_transport_frame(payload, 222, mode, 4) == ERR_CONNECTION_ERROR,
			"A dead physical target reached native put_packet"
		)
	_check(relay.get_available_packet_count() == 2, "Broadcasts no longer reached the local Relay consumer")
	# The narrow connect-signal barrier can outlive the same physical peer.
	# It must drain safely without publishing an impossible native write.
	relay._publishing_transport_connections = true
	_check(relay._send_transport_frame(payload, 222, MultiplayerPeer.TRANSFER_MODE_RELIABLE, 9) == OK, "Connect barrier did not queue the packet")
	relay._publishing_transport_connections = false
	relay._flush_connect_signal_deferred_packets()
	_check(relay._connect_signal_deferred_packets.is_empty() and relay._connect_signal_deferred_bytes == 0, "Failed deferred target leaked the barrier queue")
	_check(relay.is_peer_authenticated(111), "Dead recipient invalidated an unrelated source")
	relay.close()
	_check(transport.get_connection_status() == MultiplayerPeer.CONNECTION_DISCONNECTED, "Native ENet transport remained open")
	print("RELAY_DISCONNECT_RACE ", JSON.stringify({"failures": _failures}))
	quit(0 if _failures.is_empty() else 1)
