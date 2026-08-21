extends MultiplayerPeerExtension

## Authentication-aware ENet relay transport shared by the game and Relay projects.
##
## SceneMultiplayer's built-in server_relay couples authentication, peer discovery,
## and packet forwarding on its private system path. With more than two transports
## that path can produce asymmetric peer discovery in Godot 4.6. This wrapper keeps
## SceneMultiplayer's RPC protocol intact while making relay topology explicit:
## the Relay marks only authenticated physical peers as routable, and clients learn
## logical peers solely from Relay-authored control frames.

const FRAME_MAGIC := 0x41524C59 # "ARLY"
const FRAME_VERSION := 1
const FRAME_TYPE_DATA := 1
const FRAME_TYPE_ADD_PEER := 2
const FRAME_TYPE_REMOVE_PEER := 3
const FRAME_HEADER_SIZE := 14
const TOPOLOGY_CHANNEL := 9
## Relay service RPCs share the topology channel so an ADD frame and the
## registration it enables are reliable and ordered on the same ENet stream.
const RELAY_SERVICE_CHANNEL := TOPOLOGY_CHANNEL
const MAX_TRANSPORT_PACKETS_PER_POLL := 256
const MAX_CONNECT_SIGNAL_DEFERRED_PACKETS := 32
const MAX_CONNECT_SIGNAL_DEFERRED_BYTES := 256 * 1024
const MAX_INCOMING_PACKETS := 256
const MAX_INCOMING_BYTES := 1024 * 1024
const MAX_PENDING_TOPOLOGY_PEERS := 32
const MAX_PENDING_UNKNOWN_PACKETS := 64
const MAX_PENDING_UNKNOWN_BYTES := 256 * 1024

var _transport: ENetMultiplayerPeer = null
var _server_mode := false
var _closed := true
var _target_peer := MultiplayerPeer.TARGET_PEER_BROADCAST
var _transfer_mode := MultiplayerPeer.TRANSFER_MODE_RELIABLE
var _transfer_channel := 0
var _physical_peers: Dictionary[int, bool] = {}
var _pending_transport_connected_peers: Array[int] = []
var _pending_transport_disconnected_peers: Array[int] = []
var _publishing_transport_connections := false
var _connect_signal_deferred_packets: Array[Dictionary] = []
var _connect_signal_deferred_packet_head := 0
var _connect_signal_deferred_bytes := 0
var _authenticated_peers: Dictionary[int, bool] = {}
var _known_logical_peers: Dictionary[int, bool] = {}
var _incoming_packets: Array[Dictionary] = []
var _incoming_packet_head := 0
var _incoming_bytes := 0
var _topology_enabled := false
var _pending_topology_controls: Dictionary[int, int] = {}
var _pending_unknown_packets: Array[Dictionary] = []
var _pending_unknown_bytes := 0


func configure(transport: ENetMultiplayerPeer, server_mode: bool) -> Error:
	if transport == null or transport.get_connection_status() == CONNECTION_DISCONNECTED:
		return ERR_INVALID_PARAMETER
	if _transport != null:
		return ERR_ALREADY_IN_USE
	_transport = transport
	_server_mode = server_mode
	_closed = false
	_topology_enabled = server_mode
	_transport.peer_connected.connect(_on_transport_peer_connected)
	_transport.peer_disconnected.connect(_on_transport_peer_disconnected)
	return OK


## Client-side topology is enabled only after peer 1 completes mutual auth. Control
## frames received earlier are retained, so logical peers never enter SceneMultiplayer's
## auth callback as if they were independent physical authentication sessions.
func enable_authenticated_topology() -> void:
	if _server_mode or _closed or _topology_enabled:
		return
	_topology_enabled = true
	var pending_peer_ids := _pending_topology_controls.keys()
	pending_peer_ids.sort()
	var pending := _pending_topology_controls.duplicate()
	_pending_topology_controls.clear()
	for peer_id_variant: Variant in pending_peer_ids:
		var peer_id := int(peer_id_variant)
		_apply_topology_control(
			int(pending[peer_id]),
			peer_id
		)


## Called by the Relay only after SceneMultiplayer has completed mutual ticket auth.
## This is the sole operation that turns a physical ENet connection into a routable
## logical room member.
func mark_peer_authenticated(peer_id: int) -> bool:
	if (
		not _server_mode
		or _closed
		or peer_id <= 1
		or not _physical_peers.has(peer_id)
	):
		return false
	if _authenticated_peers.has(peer_id):
		return true
	var existing_peers := _authenticated_peers.keys()
	_authenticated_peers[peer_id] = true
	var publish_succeeded := true
	for existing_variant: Variant in existing_peers:
		var existing_peer_id := int(existing_variant)
		if (
			_send_topology_control(
				FRAME_TYPE_ADD_PEER,
				existing_peer_id,
				peer_id
			) != OK
		):
			publish_succeeded = false
		if (
			_send_topology_control(
				FRAME_TYPE_ADD_PEER,
				peer_id,
				existing_peer_id
			) != OK
		):
			publish_succeeded = false
	# RelayServer disconnects a peer when this returns false. Keep it in the
	# authenticated set until the physical disconnect so REMOVE is sent to any
	# existing peers that may already have received a partial ADD publication.
	return publish_succeeded


func is_peer_authenticated(peer_id: int) -> bool:
	return _authenticated_peers.has(peer_id)


func _poll() -> void:
	if _transport == null or _closed:
		return
	# Disconnects discovered by the previous native poll are published only after
	# SceneMultiplayer has had one turn to consume the packets queued before them.
	_flush_pending_transport_disconnections()
	if _transport == null or _closed:
		return
	_transport.poll()
	if _transport == null or _closed:
		return
	# Transport signals can synchronously make NetManager close this wrapper.
	# Re-check after poll and after every consumed packet before dereferencing it.
	var consumed_packet_count := 0
	while (
		_transport != null
		and not _closed
		and consumed_packet_count < MAX_TRANSPORT_PACKETS_PER_POLL
		and _transport.get_available_packet_count() > 0
	):
		var source_peer_id := _transport.get_packet_peer()
		var packet_mode := _transport.get_packet_mode()
		var packet_channel := _transport.get_packet_channel()
		var frame := _transport.get_packet()
		_consume_transport_frame(
			source_peer_id,
			frame,
			packet_mode,
			packet_channel
		)
		consumed_packet_count += 1
	# Native events and their packets are fully drained before logical publication.
	# SceneMultiplayer establishes pending auth during this signal phase; writes it
	# triggers are held by the narrow barrier and flushed after the signal stack ends.
	_flush_pending_transport_connections()
	if _transport == null or _closed:
		return
	_flush_connect_signal_deferred_packets()


func _flush_pending_transport_connections() -> void:
	if _pending_transport_connected_peers.is_empty():
		return
	var pending := _pending_transport_connected_peers.duplicate()
	_pending_transport_connected_peers.clear()
	_publishing_transport_connections = true
	for peer_id: int in pending:
		if _closed:
			break
		if _physical_peers.has(peer_id):
			emit_signal("peer_connected", peer_id)
	_publishing_transport_connections = false


func _flush_pending_transport_disconnections() -> void:
	if _pending_transport_disconnected_peers.is_empty():
		return
	var pending := _pending_transport_disconnected_peers.duplicate()
	_pending_transport_disconnected_peers.clear()
	for peer_id: int in pending:
		if _closed:
			return
		if _server_mode:
			_remove_authenticated_peer(peer_id)
		else:
			_known_logical_peers.clear()
			_pending_topology_controls.clear()
			_pending_unknown_packets.clear()
			_pending_unknown_bytes = 0
		emit_signal("peer_disconnected", peer_id)


func _consume_transport_frame(
	physical_source_peer_id: int,
	frame: PackedByteArray,
	packet_mode: MultiplayerPeer.TransferMode,
	packet_channel: int
) -> void:
	if not _is_valid_frame(frame):
		return
	var frame_type := int(frame[5])
	var claimed_source_peer_id := frame.decode_s32(6)
	var target_peer_id := frame.decode_s32(10)
	var payload := frame.slice(FRAME_HEADER_SIZE)
	if not _is_valid_frame_metadata(
		frame_type,
		payload,
		packet_mode,
		packet_channel
	):
		return
	if _server_mode:
		_consume_client_frame(
			physical_source_peer_id,
			claimed_source_peer_id,
			target_peer_id,
			frame_type,
			payload,
			packet_mode,
			packet_channel
		)
		return
	_consume_server_frame(
		physical_source_peer_id,
		claimed_source_peer_id,
		target_peer_id,
		frame_type,
		payload,
		packet_mode,
		packet_channel
	)


func _consume_client_frame(
	physical_source_peer_id: int,
	claimed_source_peer_id: int,
	target_peer_id: int,
	frame_type: int,
	payload: PackedByteArray,
	packet_mode: MultiplayerPeer.TransferMode,
	packet_channel: int
) -> void:
	if (
		frame_type != FRAME_TYPE_DATA
		or physical_source_peer_id <= 1
		or claimed_source_peer_id != physical_source_peer_id
		or not _is_valid_client_target_peer_id(target_peer_id)
		or target_peer_id == claimed_source_peer_id
	):
		return
	# Authentication traffic is addressed to peer 1 and must reach
	# SceneMultiplayer before this physical peer is in the allowlist.
	if target_peer_id == MultiplayerPeer.TARGET_PEER_SERVER:
		if not _enqueue_packet(
			physical_source_peer_id,
			payload,
			packet_mode,
			packet_channel
		):
			# SceneMultiplayer cannot safely continue an auth/control session after
			# a reliable wrapper handoff was lost. Close exactly that transport.
			_fail_closed_physical_peer(physical_source_peer_id)
		return
	if not _authenticated_peers.has(physical_source_peer_id):
		return
	if target_peer_id > 1:
		if _authenticated_peers.has(target_peer_id):
			var send_error := _send_data_frame(
				physical_source_peer_id,
				target_peer_id,
				payload,
				packet_mode,
				packet_channel
			)
			if (
				send_error != OK
				and packet_mode == MultiplayerPeer.TRANSFER_MODE_RELIABLE
			):
				_fail_closed_physical_peer(target_peer_id)
		return
	var excluded_peer_id := -target_peer_id if target_peer_id < 0 else 0
	var failed_reliable_targets: Array[int] = []
	for candidate_variant: Variant in _authenticated_peers.keys():
		var candidate_peer_id := int(candidate_variant)
		if (
			candidate_peer_id == physical_source_peer_id
			or candidate_peer_id == excluded_peer_id
		):
			continue
		var send_error := _send_data_frame(
			physical_source_peer_id,
			candidate_peer_id,
			payload,
			packet_mode,
			packet_channel
		)
		if (
			send_error != OK
			and packet_mode == MultiplayerPeer.TRANSFER_MODE_RELIABLE
		):
			failed_reliable_targets.append(candidate_peer_id)
	for failed_peer_id: int in failed_reliable_targets:
		_fail_closed_physical_peer(failed_peer_id)
	if excluded_peer_id != MultiplayerPeer.TARGET_PEER_SERVER:
		var local_enqueue_succeeded := _enqueue_packet(
			physical_source_peer_id,
			payload,
			packet_mode,
			packet_channel
		)
		if (
			not local_enqueue_succeeded
			and packet_mode == MultiplayerPeer.TRANSFER_MODE_RELIABLE
		):
			# Remote targets may already have accepted this broadcast. The Relay
			# cannot continue the source session after losing its reliable copy.
			_fail_closed_physical_peer(physical_source_peer_id)


func _consume_server_frame(
	physical_source_peer_id: int,
	claimed_source_peer_id: int,
	target_peer_id: int,
	frame_type: int,
	payload: PackedByteArray,
	packet_mode: MultiplayerPeer.TransferMode,
	packet_channel: int
) -> void:
	if physical_source_peer_id != MultiplayerPeer.TARGET_PEER_SERVER:
		return
	if frame_type in [FRAME_TYPE_ADD_PEER, FRAME_TYPE_REMOVE_PEER]:
		if (
			target_peer_id != _get_unique_id()
			or claimed_source_peer_id <= MultiplayerPeer.TARGET_PEER_SERVER
			or claimed_source_peer_id == target_peer_id
		):
			return
		if _topology_enabled:
			_apply_topology_control(frame_type, claimed_source_peer_id)
		elif not _queue_pending_topology_control(
			frame_type,
			claimed_source_peer_id
		):
			# Topology controls are always reliable. A client that cannot retain
			# the pre-auth topology must not enter the logical session.
			_fail_closed_physical_peer(MultiplayerPeer.TARGET_PEER_SERVER)
		return
	if (
		frame_type != FRAME_TYPE_DATA
		or claimed_source_peer_id < MultiplayerPeer.TARGET_PEER_SERVER
		or target_peer_id != _get_unique_id()
		or claimed_source_peer_id == target_peer_id
	):
		return
	var packet := {
		"source": claimed_source_peer_id,
		"payload": payload,
		"mode": packet_mode,
		"channel": packet_channel,
	}
	if (
		claimed_source_peer_id == MultiplayerPeer.TARGET_PEER_SERVER
		or _known_logical_peers.has(claimed_source_peer_id)
	):
		if (
			not _enqueue_packet_dictionary(packet)
			and packet_mode == MultiplayerPeer.TRANSFER_MODE_RELIABLE
		):
			# Auth replies (CH0) and Relay service control (CH9) are both
			# state-changing reliable messages. Losing either must close the
			# single client transport instead of leaving Scene state divergent.
			_fail_closed_physical_peer(MultiplayerPeer.TARGET_PEER_SERVER)
		return
	if (
		not _buffer_unknown_packet(packet)
		and packet_mode == MultiplayerPeer.TRANSFER_MODE_RELIABLE
	):
		_fail_closed_physical_peer(MultiplayerPeer.TARGET_PEER_SERVER)


func _queue_pending_topology_control(frame_type: int, peer_id: int) -> bool:
	if _pending_topology_controls.has(peer_id):
		_pending_topology_controls[peer_id] = frame_type
		return true
	if _pending_topology_controls.size() >= MAX_PENDING_TOPOLOGY_PEERS:
		return false
	_pending_topology_controls[peer_id] = frame_type
	return true


func _apply_topology_control(frame_type: int, peer_id: int) -> void:
	if peer_id <= 1 or peer_id == _get_unique_id():
		return
	if frame_type == FRAME_TYPE_ADD_PEER:
		if _known_logical_peers.has(peer_id):
			return
		_known_logical_peers[peer_id] = true
		emit_signal("peer_connected", peer_id)
		_flush_unknown_packets_from(peer_id)
		return
	if frame_type == FRAME_TYPE_REMOVE_PEER:
		_drop_unknown_packets_from(peer_id)
		if not _known_logical_peers.erase(peer_id):
			return
		emit_signal("peer_disconnected", peer_id)


func _put_packet_script(payload: PackedByteArray) -> Error:
	if (
		_transport == null
		or _closed
		or _transport.get_connection_status() != CONNECTION_CONNECTED
	):
		return ERR_UNCONFIGURED
	if (
		payload.is_empty()
		or not _is_valid_data_transfer_metadata(_transfer_mode, _transfer_channel)
	):
		return ERR_INVALID_PARAMETER
	if _server_mode:
		return _send_server_packet(payload)
	return _send_client_packet(payload)


func _send_server_packet(payload: PackedByteArray) -> Error:
	if _target_peer > 0:
		if (
			_target_peer <= MultiplayerPeer.TARGET_PEER_SERVER
			or not _physical_peers.has(_target_peer)
		):
			return ERR_INVALID_PARAMETER
		var send_error := _send_data_frame(
			MultiplayerPeer.TARGET_PEER_SERVER,
			_target_peer,
			payload,
			_transfer_mode,
			_transfer_channel
		)
		if (
			send_error != OK
			and _transfer_mode == MultiplayerPeer.TRANSFER_MODE_RELIABLE
		):
			_fail_closed_physical_peer(_target_peer)
		return send_error
	var excluded_peer_id := -_target_peer if _target_peer < 0 else 0
	var first_error := OK
	var failed_reliable_targets: Array[int] = []
	for candidate_variant: Variant in _authenticated_peers.keys():
		var candidate_peer_id := int(candidate_variant)
		if candidate_peer_id == excluded_peer_id:
			continue
		var send_error := _send_data_frame(
			MultiplayerPeer.TARGET_PEER_SERVER,
			candidate_peer_id,
			payload,
			_transfer_mode,
			_transfer_channel
		)
		if first_error == OK and send_error != OK:
			first_error = send_error
		if (
			send_error != OK
			and _transfer_mode == MultiplayerPeer.TRANSFER_MODE_RELIABLE
		):
			failed_reliable_targets.append(candidate_peer_id)
	for failed_peer_id: int in failed_reliable_targets:
		_fail_closed_physical_peer(failed_peer_id)
	return first_error


func _send_client_packet(payload: PackedByteArray) -> Error:
	if (
		not _is_valid_client_target_peer_id(_target_peer)
		or _target_peer == _get_unique_id()
	):
		return ERR_INVALID_PARAMETER
	var send_error := _send_transport_frame(
		_make_frame(
			FRAME_TYPE_DATA,
			_get_unique_id(),
			_target_peer,
			payload
		),
		MultiplayerPeer.TARGET_PEER_SERVER,
		_transfer_mode,
		_transfer_channel
	)
	if (
		send_error != OK
		and _transfer_mode == MultiplayerPeer.TRANSFER_MODE_RELIABLE
	):
		_fail_closed_physical_peer(MultiplayerPeer.TARGET_PEER_SERVER)
	return send_error


func _send_data_frame(
	source_peer_id: int,
	target_peer_id: int,
	payload: PackedByteArray,
	packet_mode: MultiplayerPeer.TransferMode,
	packet_channel: int
) -> Error:
	if (
		source_peer_id < MultiplayerPeer.TARGET_PEER_SERVER
		or target_peer_id <= MultiplayerPeer.TARGET_PEER_SERVER
		or source_peer_id == target_peer_id
		or payload.is_empty()
		or not _is_valid_data_transfer_metadata(packet_mode, packet_channel)
	):
		return ERR_INVALID_PARAMETER
	return _send_transport_frame(
		_make_frame(
			FRAME_TYPE_DATA,
			source_peer_id,
			target_peer_id,
			payload
		),
		target_peer_id,
		packet_mode,
		packet_channel
	)


func _send_topology_control(
	frame_type: int,
	logical_peer_id: int,
	target_peer_id: int
) -> Error:
	if (
		frame_type not in [FRAME_TYPE_ADD_PEER, FRAME_TYPE_REMOVE_PEER]
		or logical_peer_id <= MultiplayerPeer.TARGET_PEER_SERVER
		or target_peer_id <= MultiplayerPeer.TARGET_PEER_SERVER
		or logical_peer_id == target_peer_id
	):
		return ERR_INVALID_PARAMETER
	return _send_transport_frame(
		_make_frame(
			frame_type,
			logical_peer_id,
			target_peer_id,
			PackedByteArray()
		),
		target_peer_id,
		MultiplayerPeer.TRANSFER_MODE_RELIABLE,
		TOPOLOGY_CHANNEL
	)


func _send_transport_frame(
	frame: PackedByteArray,
	physical_target_peer_id: int,
	packet_mode: MultiplayerPeer.TransferMode,
	packet_channel: int
) -> Error:
	if _transport == null or _closed:
		return ERR_UNCONFIGURED
	if _publishing_transport_connections:
		if (
			_connect_signal_deferred_packets.size()
			- _connect_signal_deferred_packet_head
			>= MAX_CONNECT_SIGNAL_DEFERRED_PACKETS
			or _connect_signal_deferred_bytes + frame.size()
			> MAX_CONNECT_SIGNAL_DEFERRED_BYTES
		):
			return ERR_OUT_OF_MEMORY
		_connect_signal_deferred_packets.append({
			"frame": frame,
			"target": physical_target_peer_id,
			"mode": packet_mode,
			"channel": packet_channel,
		})
		_connect_signal_deferred_bytes += frame.size()
		return OK
	return _write_transport_frame(
		frame,
		physical_target_peer_id,
		packet_mode,
		packet_channel
	)


func _flush_connect_signal_deferred_packets() -> void:
	while (
		_transport != null
		and not _closed
		and _connect_signal_deferred_packet_head
		< _connect_signal_deferred_packets.size()
	):
		var packet := _connect_signal_deferred_packets[
			_connect_signal_deferred_packet_head
		]
		var frame: PackedByteArray = packet["frame"]
		var send_error := _write_transport_frame(
			frame,
			int(packet["target"]),
			int(packet["mode"]) as MultiplayerPeer.TransferMode,
			int(packet["channel"])
		)
		_connect_signal_deferred_packet_head += 1
		_connect_signal_deferred_bytes -= frame.size()
		if send_error != OK:
			# _send_transport_frame already returned OK to Scene while the narrow
			# connect-signal barrier was active. A later native write failure cannot
			# be reported through that call, so fail the affected physical session.
			_fail_closed_physical_peer(int(packet["target"]))
	if (
		_connect_signal_deferred_packet_head
		== _connect_signal_deferred_packets.size()
	):
		_connect_signal_deferred_packets.clear()
		_connect_signal_deferred_packet_head = 0


func _write_transport_frame(
	frame: PackedByteArray,
	physical_target_peer_id: int,
	packet_mode: MultiplayerPeer.TransferMode,
	packet_channel: int
) -> Error:
	if _transport == null or _closed:
		return ERR_UNCONFIGURED
	_transport.set_target_peer(physical_target_peer_id)
	_transport.set_transfer_mode(packet_mode)
	_transport.set_transfer_channel(packet_channel)
	return _transport.put_packet(frame)


static func _make_frame(
	frame_type: int,
	source_peer_id: int,
	target_peer_id: int,
	payload: PackedByteArray
) -> PackedByteArray:
	var frame := PackedByteArray()
	frame.resize(FRAME_HEADER_SIZE)
	frame.encode_u32(0, FRAME_MAGIC)
	frame[4] = FRAME_VERSION
	frame[5] = frame_type
	frame.encode_s32(6, source_peer_id)
	frame.encode_s32(10, target_peer_id)
	frame.append_array(payload)
	return frame


static func _is_valid_frame(frame: PackedByteArray) -> bool:
	return (
		frame.size() >= FRAME_HEADER_SIZE
		and frame.decode_u32(0) == FRAME_MAGIC
		and int(frame[4]) == FRAME_VERSION
		and int(frame[5]) in [
			FRAME_TYPE_DATA,
			FRAME_TYPE_ADD_PEER,
			FRAME_TYPE_REMOVE_PEER,
		]
	)


static func _is_valid_frame_metadata(
	frame_type: int,
	payload: PackedByteArray,
	packet_mode: MultiplayerPeer.TransferMode,
	packet_channel: int
) -> bool:
	if frame_type == FRAME_TYPE_DATA:
		return (
			not payload.is_empty()
			and _is_valid_data_transfer_metadata(packet_mode, packet_channel)
		)
	return (
		frame_type in [FRAME_TYPE_ADD_PEER, FRAME_TYPE_REMOVE_PEER]
		and payload.is_empty()
		and packet_mode == MultiplayerPeer.TRANSFER_MODE_RELIABLE
		and packet_channel == TOPOLOGY_CHANNEL
	)


static func _is_valid_data_transfer_metadata(
	packet_mode: MultiplayerPeer.TransferMode,
	packet_channel: int
) -> bool:
	return (
		packet_mode in [
			MultiplayerPeer.TRANSFER_MODE_UNRELIABLE,
			MultiplayerPeer.TRANSFER_MODE_UNRELIABLE_ORDERED,
			MultiplayerPeer.TRANSFER_MODE_RELIABLE,
		]
		and packet_channel >= 0
		and (
			packet_channel < TOPOLOGY_CHANNEL
			or packet_channel == RELAY_SERVICE_CHANNEL
		)
	)


static func _is_valid_client_target_peer_id(peer_id: int) -> bool:
	# INT32_MIN cannot be negated safely when decoding Godot's exclusion target.
	return peer_id != -2147483648


func _enqueue_packet(
	source_peer_id: int,
	payload: PackedByteArray,
	packet_mode: MultiplayerPeer.TransferMode,
	packet_channel: int
) -> bool:
	return _enqueue_packet_dictionary({
		"source": source_peer_id,
		"payload": payload,
		"mode": packet_mode,
		"channel": packet_channel,
	})


func _enqueue_packet_dictionary(packet: Dictionary) -> bool:
	var payload: PackedByteArray = packet["payload"]
	if (
		_get_available_packet_count() >= MAX_INCOMING_PACKETS
		or _incoming_bytes + payload.size() > MAX_INCOMING_BYTES
	):
		return false
	_incoming_packets.append(packet)
	_incoming_bytes += payload.size()
	return true


func _buffer_unknown_packet(packet: Dictionary) -> bool:
	var payload: PackedByteArray = packet["payload"]
	if (
		_pending_unknown_packets.size() >= MAX_PENDING_UNKNOWN_PACKETS
		or _pending_unknown_bytes + payload.size() > MAX_PENDING_UNKNOWN_BYTES
	):
		# Unreliable traffic may be discarded at this explicit bounded queue.
		# The caller closes the client session when a reliable packet cannot fit.
		return false
	_pending_unknown_packets.append(packet)
	_pending_unknown_bytes += payload.size()
	return true


func _flush_unknown_packets_from(peer_id: int) -> void:
	var retained: Array[Dictionary] = []
	var retained_bytes := 0
	for packet: Dictionary in _pending_unknown_packets:
		var payload: PackedByteArray = packet["payload"]
		if int(packet["source"]) == peer_id:
			if (
				not _enqueue_packet_dictionary(packet)
				and int(packet["mode"])
				== MultiplayerPeer.TRANSFER_MODE_RELIABLE
			):
				# The ADD has already made this source visible. Continuing after
				# losing a reliable pre-ADD packet would expose divergent state.
				_fail_closed_physical_peer(MultiplayerPeer.TARGET_PEER_SERVER)
				return
		else:
			retained.append(packet)
			retained_bytes += payload.size()
	_pending_unknown_packets = retained
	_pending_unknown_bytes = retained_bytes


func _drop_unknown_packets_from(peer_id: int) -> void:
	var retained: Array[Dictionary] = []
	var retained_bytes := 0
	for packet: Dictionary in _pending_unknown_packets:
		var payload: PackedByteArray = packet["payload"]
		if int(packet["source"]) == peer_id:
			continue
		retained.append(packet)
		retained_bytes += payload.size()
	_pending_unknown_packets = retained
	_pending_unknown_bytes = retained_bytes


func _fail_closed_physical_peer(peer_id: int) -> void:
	if _transport == null or _closed:
		return
	if _server_mode:
		if peer_id > MultiplayerPeer.TARGET_PEER_SERVER and _physical_peers.has(peer_id):
			_transport.disconnect_peer(peer_id, true)
		return
	# A client owns one physical connection only; any reliable handoff/write
	# failure invalidates that whole session.
	_transport.close()


func _get_available_packet_count() -> int:
	return _incoming_packets.size() - _incoming_packet_head


func _get_packet_script() -> PackedByteArray:
	if _get_available_packet_count() <= 0:
		return PackedByteArray()
	var packet := _incoming_packets[_incoming_packet_head]
	var payload: PackedByteArray = packet["payload"]
	_incoming_packet_head += 1
	_incoming_bytes -= payload.size()
	_compact_incoming_packets()
	return payload


func _get_packet_peer() -> int:
	if _get_available_packet_count() <= 0:
		return MultiplayerPeer.TARGET_PEER_SERVER
	return int(_incoming_packets[_incoming_packet_head]["source"])


func _get_packet_mode() -> MultiplayerPeer.TransferMode:
	if _get_available_packet_count() <= 0:
		return MultiplayerPeer.TRANSFER_MODE_RELIABLE
	return int(_incoming_packets[_incoming_packet_head]["mode"]) as MultiplayerPeer.TransferMode


func _get_packet_channel() -> int:
	if _get_available_packet_count() <= 0:
		return 0
	return int(_incoming_packets[_incoming_packet_head]["channel"])


func _compact_incoming_packets() -> void:
	if _incoming_packet_head == _incoming_packets.size():
		_incoming_packets.clear()
		_incoming_packet_head = 0
		return
	if (
		_incoming_packet_head < 64
		or _incoming_packet_head * 2 < _incoming_packets.size()
	):
		return
	var retained: Array[Dictionary] = []
	for index: int in range(_incoming_packet_head, _incoming_packets.size()):
		retained.append(_incoming_packets[index])
	_incoming_packets = retained
	_incoming_packet_head = 0


func _get_max_packet_size() -> int:
	if _transport == null:
		return 0
	return maxi(_transport.get_max_packet_size() - FRAME_HEADER_SIZE, 0)


func _set_target_peer(peer_id: int) -> void:
	_target_peer = peer_id


func _set_transfer_mode(mode: MultiplayerPeer.TransferMode) -> void:
	_transfer_mode = mode


func _get_transfer_mode() -> MultiplayerPeer.TransferMode:
	return _transfer_mode


func _set_transfer_channel(channel: int) -> void:
	_transfer_channel = channel


func _get_transfer_channel() -> int:
	return _transfer_channel


func _is_server() -> bool:
	return _server_mode


func _get_unique_id() -> int:
	if _transport == null:
		return 0
	return _transport.get_unique_id()


func _get_connection_status() -> MultiplayerPeer.ConnectionStatus:
	if _transport == null or _closed:
		return MultiplayerPeer.CONNECTION_DISCONNECTED
	return _transport.get_connection_status()


func _is_server_relay_supported() -> bool:
	return false


func _set_refuse_new_connections(enabled: bool) -> void:
	if _transport != null:
		_transport.set_refuse_new_connections(enabled)


func _is_refusing_new_connections() -> bool:
	return _transport != null and _transport.is_refusing_new_connections()


func _disconnect_peer(peer_id: int, force: bool) -> void:
	if _transport == null or _closed:
		return
	if _server_mode:
		if _physical_peers.has(peer_id):
			_transport.disconnect_peer(peer_id, force)
		return
	if peer_id == MultiplayerPeer.TARGET_PEER_SERVER:
		_transport.close()


func _close() -> void:
	if _closed:
		return
	_closed = true
	if _transport != null:
		_disconnect_transport_signals()
		_transport.close()
	_transport = null
	_physical_peers.clear()
	_pending_transport_connected_peers.clear()
	_pending_transport_disconnected_peers.clear()
	_publishing_transport_connections = false
	_connect_signal_deferred_packets.clear()
	_connect_signal_deferred_packet_head = 0
	_connect_signal_deferred_bytes = 0
	_authenticated_peers.clear()
	_known_logical_peers.clear()
	_incoming_packets.clear()
	_incoming_packet_head = 0
	_incoming_bytes = 0
	_pending_topology_controls.clear()
	_pending_unknown_packets.clear()
	_pending_unknown_bytes = 0


func _on_transport_peer_connected(peer_id: int) -> void:
	if _closed or peer_id <= 0:
		return
	_physical_peers[peer_id] = true
	if not _pending_transport_connected_peers.has(peer_id):
		_pending_transport_connected_peers.append(peer_id)


func _on_transport_peer_disconnected(peer_id: int) -> void:
	if _closed or peer_id <= 0:
		return
	_physical_peers.erase(peer_id)
	# A connect and disconnect completed within one native poll was never visible
	# to SceneMultiplayer, so do not publish a synthetic disconnected peer.
	if _pending_transport_connected_peers.has(peer_id):
		_pending_transport_connected_peers.erase(peer_id)
		return
	if not _pending_transport_disconnected_peers.has(peer_id):
		_pending_transport_disconnected_peers.append(peer_id)


func _remove_authenticated_peer(peer_id: int) -> void:
	if not _authenticated_peers.erase(peer_id):
		return
	var failed_remove_targets: Array[int] = []
	for candidate_variant: Variant in _authenticated_peers.keys():
		var candidate_peer_id := int(candidate_variant)
		# Several sockets may disappear in one native poll. Their logical
		# disconnect signals are intentionally deferred, but ENet can no longer
		# accept a REMOVE targeted at a physical peer already gone.
		if not _physical_peers.has(candidate_peer_id):
			continue
		if _send_topology_control(
			FRAME_TYPE_REMOVE_PEER,
			peer_id,
			candidate_peer_id
		) != OK:
			failed_remove_targets.append(candidate_peer_id)
	# Disconnect only after iterating the authenticated snapshot: the native
	# transport may publish disconnect signals synchronously on some backends.
	for failed_peer_id: int in failed_remove_targets:
		_fail_closed_physical_peer(failed_peer_id)


func _disconnect_transport_signals() -> void:
	if _transport == null:
		return
	if _transport.peer_connected.is_connected(_on_transport_peer_connected):
		_transport.peer_connected.disconnect(_on_transport_peer_connected)
	if _transport.peer_disconnected.is_connected(_on_transport_peer_disconnected):
		_transport.peer_disconnected.disconnect(_on_transport_peer_disconnected)
