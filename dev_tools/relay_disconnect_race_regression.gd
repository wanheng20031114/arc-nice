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
	await _check_native_topology_order()
	print("RELAY_DISCONNECT_RACE ", JSON.stringify({"failures": _failures}))
	quit(0 if _failures.is_empty() else 1)


func _check_native_topology_order() -> void:
	var server := ENetMultiplayerPeer.new()
	var connected_server_peers: Array[int] = []
	server.peer_connected.connect(func(peer_id: int) -> void: connected_server_peers.append(peer_id))
	_check(server.create_server(0, 2, 10) == OK, "Native topology server did not open")
	var client := ENetMultiplayerPeer.new()
	_check(client.create_client("127.0.0.1", server.host.get_local_port(), 10) == OK, "Native topology client did not open")
	var wrapper := RelayPeer.new()
	_check(wrapper.configure(client, false) == OK, "Native topology wrapper did not configure")
	var api := SceneMultiplayer.new()
	api.root_path = NodePath("/root")
	api.server_relay = false
	api.multiplayer_peer = wrapper
	var events: Array[String] = []
	api.peer_connected.connect(func(peer_id: int) -> void:
		if peer_id == 111: events.append("add"))
	api.peer_disconnected.connect(func(peer_id: int) -> void:
		if peer_id == 111: events.append("remove"))
	api.peer_packet.connect(func(peer_id: int, bytes: PackedByteArray) -> void:
		events.append("data:%d:%d" % [peer_id, bytes[0]]))
	var deadline := Time.get_ticks_msec() + 5000
	while (not api.get_peers().has(1) or not connected_server_peers.has(client.get_unique_id())) and Time.get_ticks_msec() < deadline:
		server.poll()
		api.poll()
		await process_frame
	_check(api.get_peers().has(1), "Native topology transport never connected")
	wrapper.enable_authenticated_topology()
	server.set_target_peer(client.get_unique_id())
	server.set_transfer_mode(MultiplayerPeer.TRANSFER_MODE_RELIABLE)
	server.set_transfer_channel(9)
	# Actual ENet coalesces these reliable frames into one receive backlog. The
	# SceneMultiplayer raw header is command 3 in Godot 4.6's documented source.
	# Reusing the same logical ID immediately after REMOVE exercises ordering,
	# not merely suppression of the native disconnected-sender diagnostic.
	var expected: Array[String] = []
	for cycle in 12:
		for frame: PackedByteArray in [
			wrapper._make_frame(wrapper.FRAME_TYPE_ADD_PEER, 111, client.get_unique_id(), PackedByteArray()),
			wrapper._make_frame(wrapper.FRAME_TYPE_DATA, 111, client.get_unique_id(), PackedByteArray([3, cycle])),
			wrapper._make_frame(wrapper.FRAME_TYPE_REMOVE_PEER, 111, client.get_unique_id(), PackedByteArray()),
		]:
			_check(server.put_packet(frame) == OK, "Native topology frame was not sent")
		expected.append_array(["add", "data:111:%d" % cycle, "remove"])
	server.host.flush()
	# Let ENet accumulate every frame before SceneMultiplayer's first read.
	deadline = Time.get_ticks_msec() + 5000
	while client.get_available_packet_count() < 36 and Time.get_ticks_msec() < deadline:
		server.poll()
		client.poll()
		await process_frame
	_check(client.get_available_packet_count() == 36, "Native topology backlog was incomplete")
	api.poll()
	_check(events == ["add", "data:111:0"], "First poll did not deliver DATA before REMOVE")
	_check(api.get_peers().has(111), "Native logical member disappeared before its DATA was read")
	for cycle in 12:
		api.poll()
	_check(events == expected, "Reliable DATA/REMOVE/reused ADD order changed: " + str(events))
	_check(not api.get_peers().has(111), "Final native logical member was retained")
	_check(wrapper.get_available_packet_count() == 0 and client.get_available_packet_count() == 0, "Native topology backlog was not drained")
	wrapper.close()
	api.multiplayer_peer = null
	server.close()
