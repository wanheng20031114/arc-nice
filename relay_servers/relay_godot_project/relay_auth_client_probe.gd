extends SceneTree

const PROBE_TICKET_ENV := "ARC_NICE_RELAY_PROBE_TICKET"
const PROTOCOL_VERSION := 91
const PROBE_RECONNECT_TOKEN := "11111111111111111111111111111111"
const PROBE_CONTENT_DIGEST := (
	"0000000000000000000000000000000000000000000000000000000000000000"
)

var _port: int = 0
var _ticket: String = ""
var _player_name: String = ""
var _expected_result: String = "accept"
var _expected_role: String = "member"
var _hold_seconds: float = 0.0
var _started_at_msec: int = 0
var _connected_at_msec: int = 0
var _finished: bool = false
var _api: SceneMultiplayer


func _initialize() -> void:
	_parse_arguments()
	_ticket = OS.get_environment(PROBE_TICKET_ENV)
	if _port <= 0 or _ticket.is_empty():
		_fail("Missing probe port or ticket")
		return
	if _player_name.is_empty():
		_player_name = _read_ticket_player_name(_ticket)
	if _expected_result == "accept" and _player_name.is_empty():
		_fail("Accepted probe ticket omitted a readable player_name claim")
		return
	if _player_name.is_empty():
		_player_name = "Probe"
	_api = get_multiplayer() as SceneMultiplayer
	if _api == null:
		_fail("Default MultiplayerAPI is not SceneMultiplayer")
		return
	_api.auth_timeout = 3.0
	_api.auth_callback = _on_auth_response
	_api.peer_authenticating.connect(_on_peer_authenticating)
	_api.peer_authentication_failed.connect(_on_peer_authentication_failed)
	_api.connected_to_server.connect(_on_connected_to_server)
	_api.connection_failed.connect(_on_connection_failed)
	_api.server_disconnected.connect(_on_server_disconnected)
	var peer := ENetMultiplayerPeer.new()
	var error := peer.create_client("127.0.0.1", _port, 8)
	if error != OK:
		_fail("Unable to create probe client: %s" % error_string(error))
		return
	_api.multiplayer_peer = peer
	_started_at_msec = Time.get_ticks_msec()


func _process(_delta: float) -> bool:
	if _finished:
		return true
	var now := Time.get_ticks_msec()
	if _connected_at_msec > 0:
		if float(now - _connected_at_msec) / 1000.0 >= _hold_seconds:
			_finish_success()
			return true
		return false
	if float(now - _started_at_msec) / 1000.0 >= 8.0:
		_fail("Probe timed out")
	return _finished


func _parse_arguments() -> void:
	for argument: String in OS.get_cmdline_user_args():
		if argument.begins_with("--port="):
			_port = argument.trim_prefix("--port=").to_int()
		elif argument.begins_with("--expect="):
			_expected_result = argument.trim_prefix("--expect=")
		elif argument.begins_with("--role="):
			_expected_role = argument.trim_prefix("--role=")
		elif argument.begins_with("--player-name="):
			_player_name = argument.trim_prefix("--player-name=")
		elif argument.begins_with("--hold="):
			_hold_seconds = maxf(
				argument.trim_prefix("--hold=").to_float(),
				0.0
			)


func _on_peer_authenticating(peer_id: int) -> void:
	var request := {
		"v": 1,
		"ticket": _ticket,
		"player_name": _player_name,
		"character_id": "weishidaier",
		"character_confirmed": true,
		"protocol_version": PROTOCOL_VERSION,
		"reconnect_token": PROBE_RECONNECT_TOKEN,
		"content_manifest_schema": 1,
		"content_digest": PROBE_CONTENT_DIGEST,
	}
	var error: Error = _api.send_auth(
		peer_id,
		JSON.stringify(request).to_utf8_buffer()
	)
	if error != OK:
		_fail("Unable to send probe auth payload: %s" % error_string(error))


func _read_ticket_player_name(ticket: String) -> String:
	var segments := ticket.split(".", true)
	if segments.size() != 3 or segments[1].is_empty():
		return ""
	var encoded_payload := segments[1].replace("-", "+").replace("_", "/")
	while encoded_payload.length() % 4 != 0:
		encoded_payload += "="
	var payload_bytes := Marshalls.base64_to_raw(encoded_payload)
	if payload_bytes.is_empty():
		return ""
	var parsed: Variant = JSON.parse_string(payload_bytes.get_string_from_utf8())
	if not (parsed is Dictionary):
		return ""
	return str((parsed as Dictionary).get("player_name", ""))


func _on_auth_response(peer_id: int, payload: PackedByteArray) -> void:
	var parsed: Variant = JSON.parse_string(payload.get_string_from_utf8())
	if typeof(parsed) != TYPE_DICTIONARY:
		_fail("Relay auth response is not JSON object")
		return
	var response: Dictionary = parsed
	var accepted := bool(response.get("ok", false))
	if not accepted:
		if _expected_result == "reject":
			_finish_success()
		else:
			_fail("Relay rejected a ticket expected to pass")
		return
	if _expected_result != "accept":
		_fail("Relay accepted a ticket expected to fail")
		return
	if str(response.get("role", "")) != _expected_role:
		_fail("Relay acknowledgement role mismatch")
		return
	if int(response.get("peer_id", 0)) <= 0:
		_fail("Relay acknowledgement omitted assigned peer id")
		return
	var error: Error = _api.complete_auth(peer_id)
	if error != OK:
		_fail("Client complete_auth failed: %s" % error_string(error))


func _on_connected_to_server() -> void:
	if _expected_result != "accept":
		_fail("Rejected probe reached connected_to_server")
		return
	_connected_at_msec = Time.get_ticks_msec()
	if _hold_seconds <= 0.0:
		_finish_success()


func _on_peer_authentication_failed(_peer_id: int) -> void:
	if _expected_result == "reject":
		_finish_success()
	else:
		_fail("Authentication failed unexpectedly")


func _on_connection_failed() -> void:
	if _expected_result == "reject":
		_finish_success()
	else:
		_fail("Connection failed unexpectedly")


func _on_server_disconnected() -> void:
	if _expected_result == "reject":
		_finish_success()
	elif not _finished:
		_fail("Server disconnected accepted probe")


func _finish_success() -> void:
	if _finished:
		return
	_finished = true
	print(
		"RELAY_AUTH_CLIENT_PROBE_OK expect=%s role=%s"
		% [_expected_result, _expected_role]
	)
	quit(0)


func _fail(message: String) -> void:
	if _finished:
		return
	_finished = true
	push_error(message)
	quit(1)
