extends Node
class_name MpSessionCoordinator

const _NetConstants := preload("res://scene/multiplayer/net_constants.gd")

const RUNTIME_STATE_REQUEST_RATE_PER_SECOND := 0.5
const RUNTIME_STATE_REQUEST_RATE_BURST := 2.0
const HOST_TIME_OFFSET_SMOOTH_WEIGHT := 0.08


class RuntimeWorldManifest:
	extends RefCounted

	var enemy_id_set: Dictionary[int, bool] = {}
	var pickup_id_set: Dictionary[int, bool] = {}
	var plant_id_set: Dictionary[int, bool] = {}
	var positive_plant_ids := PackedInt32Array()


var _runtime: CombatRuntimeBase = null
var _net_manager: NetManagerStore = null
var _public_room_keepalive_request: HTTPRequest = null
var _runtime_state_requested := false
var _runtime_state_request_rate_buckets: Dictionary = {}
var _net_time_origin: float = 0.0
var _has_host_time_offset := false
var _host_to_client_time_offset: float = 0.0
var _public_room_keepalive_time_left: float = 0.0
var _public_room_keepalive_in_flight := false


func bind_transport_dependencies(
	net_manager_instance: NetManagerStore,
	public_room_keepalive_request: HTTPRequest
) -> void:
	assert(net_manager_instance != null, "MpSessionCoordinator 缺少 NetManagerStore。")
	assert(
		public_room_keepalive_request != null,
		"MpSessionCoordinator 缺少静态 PublicRoomKeepaliveRequest。"
	)
	if (
		_net_manager != net_manager_instance
		or _public_room_keepalive_request != public_room_keepalive_request
	):
		unbind_transport_dependencies()
		_net_manager = net_manager_instance
		_public_room_keepalive_request = public_room_keepalive_request
	reset_transport_state()
	if not _public_room_keepalive_request.request_completed.is_connected(
		_on_public_room_keepalive_completed
	):
		_public_room_keepalive_request.request_completed.connect(
			_on_public_room_keepalive_completed
		)


func unbind_transport_dependencies() -> void:
	if _public_room_keepalive_request != null:
		if _public_room_keepalive_request.request_completed.is_connected(
			_on_public_room_keepalive_completed
		):
			_public_room_keepalive_request.request_completed.disconnect(
				_on_public_room_keepalive_completed
			)
		_cancel_public_room_keepalive_request()
	_net_manager = null
	_public_room_keepalive_request = null
	_reset_transport_values()


func update_transport(delta: float) -> void:
	if not should_send_public_room_keepalive():
		_public_room_keepalive_time_left = 0.0
		return
	if _public_room_keepalive_in_flight:
		return
	_public_room_keepalive_time_left -= delta
	if _public_room_keepalive_time_left > 0.0:
		return
	_send_public_room_keepalive()


func get_net_time() -> float:
	return Time.get_ticks_msec() / 1000.0 - _net_time_origin


func get_net_time_origin() -> float:
	return _net_time_origin


func map_host_timestamp_to_client_time(
	host_timestamp: float,
	update_offset: bool = true
) -> float:
	var receive_time := get_net_time()
	var sampled_offset := receive_time - host_timestamp
	if not update_offset:
		if _has_host_time_offset:
			return host_timestamp + _host_to_client_time_offset
		return receive_time
	if not _has_host_time_offset:
		_host_to_client_time_offset = sampled_offset
		_has_host_time_offset = true
	else:
		_host_to_client_time_offset = lerpf(
			_host_to_client_time_offset,
			sampled_offset,
			HOST_TIME_OFFSET_SMOOTH_WEIGHT
		)
	return host_timestamp + _host_to_client_time_offset


func has_host_time_offset() -> bool:
	return _has_host_time_offset


func get_host_to_client_time_offset() -> float:
	return _host_to_client_time_offset


func should_send_public_room_keepalive() -> bool:
	if _public_room_keepalive_request == null or _net_manager == null:
		return false
	if not _net_manager.is_host():
		return false
	if int(_net_manager.conn_mode) != int(NetManagerStore.ConnMode.RELAY):
		return false
	if not _net_manager.public_is_host:
		return false
	return (
		not _net_manager.public_room_id.strip_edges().is_empty()
		and not _net_manager.public_host_token.strip_edges().is_empty()
	)


func get_public_room_keepalive_time_left() -> float:
	return _public_room_keepalive_time_left


func is_public_room_keepalive_in_flight() -> bool:
	return _public_room_keepalive_in_flight


func bind_runtime(runtime_instance: CombatRuntimeBase) -> void:
	assert(runtime_instance != null, "MpSessionCoordinator 缺少战斗运行时。")
	if _runtime == runtime_instance:
		return
	_runtime = runtime_instance
	reset_session_state()


func unbind_runtime(runtime_instance: CombatRuntimeBase) -> void:
	if _runtime != runtime_instance:
		return
	_runtime = null
	reset_session_state()


func is_bound() -> bool:
	return _runtime != null and is_instance_valid(_runtime)


func try_begin_client_runtime_state_request(
	is_client: bool,
	host_game_ready: bool
) -> bool:
	if (
		not is_bound()
		or not is_client
		or not host_game_ready
		or _runtime_state_requested
	):
		return false
	_runtime_state_requested = true
	return true


func admit_authoritative_runtime_state_request(
	is_host: bool,
	sender_id: int,
	now_seconds: float
) -> bool:
	if not is_host or not is_bound() or sender_id <= 0:
		return false
	if not _consume_runtime_state_request_token(sender_id, now_seconds):
		return false
	return _runtime.get_player_for_peer(sender_id) != null


func parse_runtime_world_manifest(
	live_enemy_ids: PackedInt32Array,
	live_pickup_ids: PackedInt32Array,
	live_plant_ids: PackedInt32Array
) -> RuntimeWorldManifest:
	var manifest := RuntimeWorldManifest.new()
	for net_id in live_enemy_ids:
		if net_id > 0:
			manifest.enemy_id_set[net_id] = true
	for net_id in live_pickup_ids:
		if net_id > 0:
			manifest.pickup_id_set[net_id] = true
	for net_id in live_plant_ids:
		if net_id <= 0:
			continue
		manifest.plant_id_set[net_id] = true
		# The old repair path cleared one removal marker per wire entry. Preserve
		# both ordering and duplicates even though membership itself is deduplicated.
		manifest.positive_plant_ids.append(net_id)
	return manifest


func clear_peer(peer_id: int) -> void:
	_runtime_state_request_rate_buckets.erase(peer_id)


func reset_session_state() -> void:
	_runtime_state_requested = false
	_runtime_state_request_rate_buckets.clear()
	reset_transport_state()


func reset_transport_state() -> void:
	_cancel_public_room_keepalive_request()
	_reset_transport_values()


func has_requested_runtime_state() -> bool:
	return _runtime_state_requested


func _send_public_room_keepalive() -> void:
	var room_id := _net_manager.public_room_id.strip_edges()
	var host_token := _net_manager.public_host_token.strip_edges()
	if room_id.is_empty() or host_token.is_empty():
		return
	var body := JSON.stringify({"host_token": host_token})
	var headers := PackedStringArray(["Content-Type: application/json"])
	var err := _public_room_keepalive_request.request(
		"%s/rooms/%s/keepalive" % [_NetConstants.PUBLIC_LOBBY_API_BASE_URL, room_id],
		headers,
		HTTPClient.METHOD_POST,
		body
	)
	if err != OK:
		_public_room_keepalive_time_left = (
			_NetConstants.PUBLIC_ROOM_KEEPALIVE_INTERVAL_SECONDS
		)
		push_warning("MpGame: 公网房间续租请求启动失败: %s" % error_string(err))
		return
	_public_room_keepalive_in_flight = true


func _on_public_room_keepalive_completed(
	result: int,
	response_code: int,
	_headers: PackedStringArray,
	body: PackedByteArray
) -> void:
	_public_room_keepalive_in_flight = false
	_public_room_keepalive_time_left = (
		_NetConstants.PUBLIC_ROOM_KEEPALIVE_INTERVAL_SECONDS
	)
	if not should_send_public_room_keepalive():
		return
	if result != HTTPRequest.RESULT_SUCCESS or response_code < 200 or response_code >= 300:
		var error_body_text := body.get_string_from_utf8()
		push_warning(
			"MpGame: 公网房间续租失败 result=%d status=%d body=%s"
			% [result, response_code, error_body_text.left(160)]
		)
		return

	var parsed: Variant = null
	var response_body_text := body.get_string_from_utf8()
	if not response_body_text.is_empty():
		parsed = JSON.parse_string(response_body_text)
	var parsed_dict := parsed as Dictionary
	if (
		parsed_dict != null
		and parsed_dict.has("relay_running")
		and not bool(parsed_dict["relay_running"])
	):
		push_warning("MpGame: 公网房间续租成功，但云端 Relay 进程已不在运行。")


func _cancel_public_room_keepalive_request() -> void:
	if (
		_public_room_keepalive_request != null
		and _public_room_keepalive_request.get_http_client_status()
		!= HTTPClient.STATUS_DISCONNECTED
	):
		_public_room_keepalive_request.cancel_request()
	_public_room_keepalive_in_flight = false


func _reset_transport_values() -> void:
	_net_time_origin = Time.get_ticks_msec() / 1000.0
	_has_host_time_offset = false
	_host_to_client_time_offset = 0.0
	_public_room_keepalive_time_left = 0.0
	_public_room_keepalive_in_flight = false


func _consume_runtime_state_request_token(
	peer_id: int,
	now_seconds: float
) -> bool:
	if peer_id <= 0:
		return false
	var bucket: Dictionary
	if _runtime_state_request_rate_buckets.has(peer_id):
		bucket = _runtime_state_request_rate_buckets[peer_id] as Dictionary
	else:
		bucket = {
			"tokens": RUNTIME_STATE_REQUEST_RATE_BURST,
			"last_time": now_seconds,
		}
		_runtime_state_request_rate_buckets[peer_id] = bucket
	var tokens := float(bucket.get("tokens", RUNTIME_STATE_REQUEST_RATE_BURST))
	var last_time := float(bucket.get("last_time", now_seconds))
	tokens = minf(
		RUNTIME_STATE_REQUEST_RATE_BURST,
		tokens
		+ maxf(now_seconds - last_time, 0.0)
		* RUNTIME_STATE_REQUEST_RATE_PER_SECOND
	)
	var accepted := tokens >= 1.0
	if accepted:
		tokens -= 1.0
	bucket["tokens"] = tokens
	bucket["last_time"] = now_seconds
	return accepted
