extends Node

## Godot Headless Relay Server。
## 以无头模式运行，通过认证感知包装层转发 ENet 包。
## 命令行参数包含端口、容量以及三段互不混用的生命周期租约。

const AuthenticatedRelayMultiplayerPeer = preload(
	"res://authenticated_relay_multiplayer_peer.gd"
)

const DEFAULT_PORT := 40001
const DEFAULT_STARTUP_IDLE_TIMEOUT_SEC := 120.0
const DEFAULT_EMPTY_IDLE_TIMEOUT_SEC := 120.0
const DEFAULT_MAX_LIFETIME_SEC := 10.0 * 60.0 * 60.0
const MIN_CLIENTS := 2
const MAX_CLIENTS := 8
const DEFAULT_MAX_CLIENTS := MAX_CLIENTS
## 最坏情况下 Host 与 7 名成员可同时处于短暂票据认证；认证成功后的房间
## 容量仍由 _max_clients 独立约束。
const AUTH_PENDING_RESERVE := MAX_CLIENTS
const MAX_TRANSPORT_CLIENTS := MAX_CLIENTS + AUTH_PENDING_RESERVE
const CH_MEMBERSHIP := 8
const RELAY_CONTROL_CHANNEL := CH_MEMBERSHIP + 1
const RELAY_SERVICE_CHANNEL := RELAY_CONTROL_CHANNEL
const ENET_MAX_CHANNEL := RELAY_CONTROL_CHANNEL
const CHANNEL_COUNT := CH_MEMBERSHIP + 1
const PROTOCOL_VERSION := 96
const AUTH_PROTOCOL_VERSION := 1
const AUTH_TICKET_PREFIX := "ra1"
const AUTH_TIMEOUT_SEC := 5.0
const AUTH_MAX_PAYLOAD_BYTES := 4096
const AUTH_MAX_TICKET_LENGTH := 2048
const MAX_REGISTRATION_PLAYER_NAME_LENGTH := 64
const MAX_REGISTRATION_CHARACTER_ID_LENGTH := 64
const RECONNECT_TOKEN_HEX_LENGTH := 32
const CONTENT_DIGEST_HEX_LENGTH := 64
const AUTH_REQUEST_KEYS := [
	"v",
	"ticket",
	"player_name",
	"character_id",
	"character_confirmed",
	"protocol_version",
	"reconnect_token",
	"content_manifest_schema",
	"content_digest",
]
const AUTH_CLOCK_SKEW_SEC := 30
const AUTH_MAX_TICKET_TTL_SEC := 120
const ROOM_ID_ENV := "ARC_NICE_RELAY_ROOM_ID"
const ADMISSION_SECRET_ENV := "ARC_NICE_RELAY_ADMISSION_SECRET"
const MIN_ADMISSION_SECRET_LENGTH := 32
const MAX_ADMISSION_SECRET_LENGTH := 256
const MAX_TICKET_NONCE_LENGTH := 64
# Lobby 允许的最坏边界：每个成员在 120 秒 TTL 内每 5 秒最多刷新 3 次，
# 加每成员初始票和 64 个 Host/控制重试余量；账本容量由当前公网人数上限推导。
const MAX_REFRESH_TICKETS_PER_MEMBER := 1 + 3 * 24
const CONSUMED_NONCE_CONTROL_RESERVE := 64
const MAX_CONSUMED_TICKET_NONCES := (
	1 + (MAX_CLIENTS - 1) * MAX_REFRESH_TICKETS_PER_MEMBER
	+ CONSUMED_NONCE_CONTROL_RESERVE
)
const MAX_IDENTITY_LOOKUP_REQUEST_ID := 2_147_483_647

var _port: int = DEFAULT_PORT
var _startup_idle_timeout_sec: float = DEFAULT_STARTUP_IDLE_TIMEOUT_SEC
var _empty_idle_timeout_sec: float = DEFAULT_EMPTY_IDLE_TIMEOUT_SEC
var _max_lifetime_sec: float = DEFAULT_MAX_LIFETIME_SEC
var _max_clients: int = DEFAULT_MAX_CLIENTS
var _relay_peer: MultiplayerPeerExtension = null
var _started_at_msec: int = 0
var _empty_since_msec: int = 0
var _has_had_connections: bool = false
var _host_peer_id: int = 0
var _has_invalid_argument: bool = false
var _room_id: String = ""
var _admission_secret: String = ""
var _identity_by_peer: Dictionary = {}
var _peer_by_player_name: Dictionary = {}
var _registration_by_peer: Dictionary = {}
var _consumed_ticket_nonces: Dictionary = {}
var _host_was_authenticated: bool = false


func _ready() -> void:
	_load_admission_environment()
	_parse_command_line()
	if _has_invalid_argument:
		get_tree().quit(2)
		return
	_start_server()


func _load_admission_environment() -> void:
	_room_id = OS.get_environment(ROOM_ID_ENV).strip_edges()
	_admission_secret = OS.get_environment(ADMISSION_SECRET_ENV)
	if not _is_safe_room_id(_room_id):
		printerr("[Relay] 缺少有效的房间认证上下文")
		_has_invalid_argument = true
	if (
		_admission_secret.length() < MIN_ADMISSION_SECRET_LENGTH
		or _admission_secret.length() > MAX_ADMISSION_SECRET_LENGTH
		or not _is_ascii(_admission_secret)
	):
		printerr("[Relay] 缺少有效的房间认证秘密")
		_has_invalid_argument = true


func _parse_command_line() -> void:
	var args := OS.get_cmdline_user_args()
	for arg: String in args:
		if arg.begins_with("--port="):
			var port_str := arg.substr(7)
			if port_str.is_valid_int():
				_port = port_str.to_int()
				print("[Relay] 端口参数: %d" % _port)
		elif arg.begins_with("--startup-idle-timeout="):
			var parsed_startup_timeout := _parse_positive_timeout(
				arg,
				"--startup-idle-timeout=",
				"首次连接空闲超时"
			)
			if parsed_startup_timeout > 0.0:
				_startup_idle_timeout_sec = parsed_startup_timeout
		elif arg.begins_with("--empty-idle-timeout="):
			var parsed_empty_timeout := _parse_positive_timeout(
				arg,
				"--empty-idle-timeout=",
				"断线后空载超时"
			)
			if parsed_empty_timeout > 0.0:
				_empty_idle_timeout_sec = parsed_empty_timeout
		elif arg.begins_with("--max-lifetime="):
			var parsed_max_lifetime := _parse_positive_timeout(
				arg,
				"--max-lifetime=",
				"绝对生命周期"
			)
			if parsed_max_lifetime > 0.0:
				_max_lifetime_sec = parsed_max_lifetime
		elif arg.begins_with("--max-clients="):
			var max_clients_str := arg.substr(14)
			if not max_clients_str.is_valid_int():
				push_error("[Relay] 最大连接数参数不是整数: %s" % max_clients_str)
				_has_invalid_argument = true
				continue
			var parsed_max_clients := max_clients_str.to_int()
			if parsed_max_clients < MIN_CLIENTS or parsed_max_clients > MAX_CLIENTS:
				push_error(
					"[Relay] 最大连接数必须在 %d..%d 之间: %d"
					% [MIN_CLIENTS, MAX_CLIENTS, parsed_max_clients]
				)
				_has_invalid_argument = true
				continue
			_max_clients = parsed_max_clients
			print("[Relay] 最大连接数参数: %d" % _max_clients)


func _parse_positive_timeout(arg: String, prefix: String, label: String) -> float:
	var timeout_str := arg.trim_prefix(prefix)
	if not timeout_str.is_valid_float():
		push_error("[Relay] %s参数不是数字: %s" % [label, timeout_str])
		_has_invalid_argument = true
		return -1.0
	var value := timeout_str.to_float()
	if not is_finite(value) or value <= 0.0:
		push_error("[Relay] %s必须大于 0: %s" % [label, timeout_str])
		_has_invalid_argument = true
		return -1.0
	print("[Relay] %s参数: %.3f 秒" % [label, value])
	return value


func _start_server() -> void:
	var transport := ENetMultiplayerPeer.new()
	var transport_capacity := transport_capacity_for_room(_max_clients)
	var err := transport.create_server(_port, transport_capacity, ENET_MAX_CHANNEL)
	if err != OK:
		push_error("[Relay] 创建服务器失败 (port=%d): %s" % [_port, error_string(err)])
		get_tree().quit(1)
		return
	_relay_peer = AuthenticatedRelayMultiplayerPeer.new()
	err = _relay_peer.configure(transport, true)
	if err != OK:
		transport.close()
		_relay_peer = null
		push_error("[Relay] 初始化认证感知转发层失败: %s" % error_string(err))
		get_tree().quit(1)
		return

	# 禁用 SceneMultiplayer 的隐式 mesh。认证感知包装层只向已验票 transport
	# 发布拓扑并转发包，避免 auth_callback 与内置 ADD_PEER 的多成员时序缺陷。
	multiplayer.server_relay = false
	multiplayer.auth_timeout = AUTH_TIMEOUT_SEC
	multiplayer.auth_callback = _on_auth_payload

	multiplayer.peer_connected.connect(_on_peer_connected)
	multiplayer.peer_disconnected.connect(_on_peer_disconnected)
	multiplayer.peer_authenticating.connect(_on_peer_authenticating)
	multiplayer.peer_authentication_failed.connect(_on_peer_authentication_failed)
	multiplayer.multiplayer_peer = _relay_peer
	_started_at_msec = Time.get_ticks_msec()
	_empty_since_msec = _started_at_msec

	print(
		(
			"[Relay] 服务器已启动, port=%d, max_clients=%d, transport_clients=%d, protocol=v%d, "
			+ "startup_idle=%.3f, empty_idle=%.3f, max_lifetime=%.3f, "
			+ "server_relay=authenticated_wrapper, authentication=required"
		)
		% [
			_port,
			_max_clients,
			transport_capacity,
			PROTOCOL_VERSION,
			_startup_idle_timeout_sec,
			_empty_idle_timeout_sec,
			_max_lifetime_sec,
		]
	)


func _process(_delta: float) -> void:
	# ticks 是不受 wall clock 回拨与游戏 time scale 影响的进程单调时钟。
	var now_msec := Time.get_ticks_msec()
	if _elapsed_seconds(_started_at_msec, now_msec) >= _max_lifetime_sec:
		print("[Relay] 达到绝对生命周期上限，自动退出")
		get_tree().quit(0)
		return

	# 首次连接租约独立于游戏绝对时长，遗失创建响应不会长期占住进程。
	if not _has_had_connections:
		if _elapsed_seconds(_empty_since_msec, now_msec) >= _startup_idle_timeout_sec:
			print("[Relay] 首次连接超时，自动退出")
			get_tree().quit(0)
		return

	# 有过连接后，检查是否全部断开
	if not multiplayer.has_multiplayer_peer():
		return

	var connected_peers := multiplayer.get_peers()
	if connected_peers.is_empty():
		if _elapsed_seconds(_empty_since_msec, now_msec) >= _empty_idle_timeout_sec:
			print("[Relay] 所有玩家离开且重连窗口已过，自动退出")
			get_tree().quit(0)
	else:
		_empty_since_msec = now_msec


static func _elapsed_seconds(started_at_msec: int, now_msec: int) -> float:
	return float(maxi(now_msec - started_at_msec, 0)) / 1000.0


static func transport_capacity_for_room(room_capacity: int) -> int:
	return mini(
		maxi(room_capacity, MIN_CLIENTS) + AUTH_PENDING_RESERVE,
		MAX_TRANSPORT_CLIENTS
	)


static func can_accept_auth_pending(pending_count_including_candidate: int) -> bool:
	return (
		pending_count_including_candidate > 0
		and pending_count_including_candidate <= AUTH_PENDING_RESERVE
	)


static func has_authenticated_room_capacity(
	authenticated_count: int,
	room_capacity: int
) -> bool:
	return (
		authenticated_count >= 0
		and room_capacity >= MIN_CLIENTS
		and room_capacity <= MAX_CLIENTS
		and authenticated_count < room_capacity
	)


static func consumed_nonce_capacity_for_room(room_capacity: int) -> int:
	var bounded_room_capacity := clampi(room_capacity, MIN_CLIENTS, MAX_CLIENTS)
	return mini(
		1
		+ (bounded_room_capacity - 1) * MAX_REFRESH_TICKETS_PER_MEMBER
		+ CONSUMED_NONCE_CONTROL_RESERVE,
		MAX_CONSUMED_TICKET_NONCES
	)


func _on_peer_connected(peer_id: int) -> void:
	if not _identity_by_peer.has(peer_id):
		push_error("[Relay] 认证状态缺失，断开异常 peer")
		multiplayer.disconnect_peer(peer_id)
		return
	if _relay_peer == null or not _relay_peer.mark_peer_authenticated(peer_id):
		push_error("[Relay] 无法发布已认证 peer 拓扑: %d" % peer_id)
		multiplayer.disconnect_peer(peer_id)
		return
	_has_had_connections = true
	_empty_since_msec = Time.get_ticks_msec()
	var connected_count := multiplayer.get_peers().size()
	var identity: Dictionary = _identity_by_peer[peer_id]
	if str(identity.get("role", "")) == "host":
		# 只有双方 complete_auth 后才永久封闭本 Relay 世代的 Host 槽。
		# 若 success ack 丢失导致认证失败，Host 可用新 nonce 重试；真正进入过
		# peer_connected 的 Host 断线后则绝不迁移。
		_host_was_authenticated = true
	elif str(identity.get("role", "")) == "member":
		# mark_peer_authenticated() has just emitted ADD on reliable CH9. The
		# registration RPC uses that same physical channel, so Host observes the
		# topology before this one-shot authoritative registration tuple.
		if not _forward_authenticated_player_registration(peer_id):
			push_error("[Relay] 无法转发认证注册 peer_id=%d" % peer_id)
			multiplayer.disconnect_peer(peer_id)
			return
	print(
		"[Relay] 已认证玩家连接 peer_id=%d role=%s (当前 %d 人)"
		% [peer_id, str(identity.get("role", "")), connected_count]
	)


func _on_peer_disconnected(peer_id: int) -> void:
	_clear_peer_identity(peer_id)
	var connected_count := multiplayer.get_peers().size()
	if connected_count == 0:
		# 空载宽限从最后一名玩家离开时起算，不吞掉任何重连窗口。
		_empty_since_msec = Time.get_ticks_msec()
	print("[Relay] 玩家断开 peer_id=%d (剩余 %d 人)" % [peer_id, connected_count])


func _on_peer_authentication_failed(peer_id: int) -> void:
	_clear_peer_identity(peer_id)
	print("[Relay] peer 认证未完成 peer_id=%d" % peer_id)


func _on_peer_authenticating(peer_id: int) -> void:
	var authenticating_peers: PackedInt32Array = (
		multiplayer.get_authenticating_peers()
	)
	var pending_count: int = authenticating_peers.size()
	if not authenticating_peers.has(peer_id):
		pending_count += 1
	if not can_accept_auth_pending(pending_count):
		_reject_auth(peer_id, "auth_busy")


func _on_auth_payload(peer_id: int, payload: PackedByteArray) -> void:
	_process_auth_payload(peer_id, payload)


func _process_auth_payload(peer_id: int, payload: PackedByteArray) -> void:
	if (
		payload.is_empty()
		or payload.size() > AUTH_MAX_PAYLOAD_BYTES
		or not multiplayer.get_authenticating_peers().has(peer_id)
	):
		_reject_auth(peer_id, "invalid_request")
		return
	if not can_accept_auth_pending(multiplayer.get_authenticating_peers().size()):
		_reject_auth(peer_id, "auth_busy")
		return
	var parsed_request: Variant = JSON.parse_string(payload.get_string_from_utf8())
	if typeof(parsed_request) != TYPE_DICTIONARY:
		_reject_auth(peer_id, "invalid_request")
		return
	var request: Dictionary = parsed_request
	if not _has_exact_auth_request_schema(request):
		_reject_auth(peer_id, "invalid_request")
		return
	if _strict_nonnegative_integer(request.get("v")) != AUTH_PROTOCOL_VERSION:
		_reject_auth(peer_id, "invalid_request")
		return
	var ticket_variant: Variant = request.get("ticket")
	if typeof(ticket_variant) != TYPE_STRING:
		_reject_auth(peer_id, "invalid_ticket")
		return
	var registration := _parse_registration_request(request)
	if registration.is_empty():
		_reject_auth(peer_id, "invalid_request")
		return
	var claims := verify_admission_ticket(
		str(ticket_variant),
		_admission_secret,
		_room_id,
		int(Time.get_unix_time_from_system())
	)
	if claims.is_empty():
		_reject_auth(peer_id, "invalid_ticket")
		return
	var role := str(claims.get("role", ""))
	var player_name := str(claims.get("player_name", ""))
	if not _registration_matches_claims(registration, claims):
		_reject_auth(peer_id, "identity_mismatch")
		return
	if not is_admission_claim_allowed(
		role,
		player_name,
		_host_peer_id,
		_peer_by_player_name,
		_host_was_authenticated
	):
		_reject_auth(peer_id, "role_not_available")
		return
	if not has_authenticated_room_capacity(
		_identity_by_peer.size(),
		_max_clients
	):
		_reject_auth(peer_id, "room_full")
		return
	if not try_consume_ticket_nonce(
		claims,
		_consumed_ticket_nonces,
		int(Time.get_unix_time_from_system()),
		consumed_nonce_capacity_for_room(_max_clients)
	):
		_reject_auth(peer_id, "replayed_ticket")
		return

	_identity_by_peer[peer_id] = claims
	_registration_by_peer[peer_id] = registration
	_peer_by_player_name[player_name] = peer_id
	if role == "host":
		_host_peer_id = peer_id
		_set_stub_authority(peer_id)

	if _send_authenticated_peer_ack(peer_id):
		_complete_authenticated_peer(peer_id)


func _send_authenticated_peer_ack(peer_id: int) -> bool:
	if (
		not _identity_by_peer.has(peer_id)
		or not multiplayer.get_authenticating_peers().has(peer_id)
	):
		return false
	var identity := _identity_by_peer[peer_id] as Dictionary
	var acknowledgement := {
		"v": AUTH_PROTOCOL_VERSION,
		"ok": true,
		"room_id": _room_id,
		"role": str(identity.get("role", "")),
		"player_name": str(identity.get("player_name", "")),
		"peer_id": peer_id,
	}
	var send_error: Error = multiplayer.send_auth(
		peer_id,
		JSON.stringify(acknowledgement).to_utf8_buffer()
	)
	if send_error == OK:
		return true
	_clear_peer_identity(peer_id)
	multiplayer.disconnect_peer(peer_id)
	return false


func _complete_authenticated_peer(peer_id: int) -> bool:
	var complete_error: Error = multiplayer.complete_auth(peer_id)
	if complete_error != OK:
		_clear_peer_identity(peer_id)
		multiplayer.disconnect_peer(peer_id)
		return false
	return true


static func _has_exact_auth_request_schema(request: Dictionary) -> bool:
	if request.size() != AUTH_REQUEST_KEYS.size():
		return false
	for key: String in AUTH_REQUEST_KEYS:
		if not request.has(key):
			return false
	return true


static func _parse_registration_request(request: Dictionary) -> Dictionary:
	var player_name_variant: Variant = request.get("player_name")
	var character_id_variant: Variant = request.get("character_id")
	var character_confirmed_variant: Variant = request.get("character_confirmed")
	var reconnect_token_variant: Variant = request.get("reconnect_token")
	var content_digest_variant: Variant = request.get("content_digest")
	if (
		typeof(player_name_variant) != TYPE_STRING
		or str(player_name_variant).is_empty()
		or str(player_name_variant).length() > MAX_REGISTRATION_PLAYER_NAME_LENGTH
		or typeof(character_id_variant) != TYPE_STRING
		or str(character_id_variant).length() > MAX_REGISTRATION_CHARACTER_ID_LENGTH
		or typeof(character_confirmed_variant) != TYPE_BOOL
		or typeof(reconnect_token_variant) != TYPE_STRING
		or str(reconnect_token_variant).length() != RECONNECT_TOKEN_HEX_LENGTH
		or not _is_lowercase_hex(str(reconnect_token_variant))
		or typeof(content_digest_variant) != TYPE_STRING
		or str(content_digest_variant).length() != CONTENT_DIGEST_HEX_LENGTH
		or not _is_lowercase_hex(str(content_digest_variant))
	):
		return {}
	var protocol_version := _strict_nonnegative_integer(
		request.get("protocol_version")
	)
	var content_manifest_schema := _strict_nonnegative_integer(
		request.get("content_manifest_schema")
	)
	if protocol_version < 0 or content_manifest_schema < 0:
		return {}
	return {
		"player_name": str(player_name_variant),
		"character_id": str(character_id_variant),
		"character_confirmed": bool(character_confirmed_variant),
		"protocol_version": protocol_version,
		"reconnect_token": str(reconnect_token_variant),
		"content_manifest_schema": content_manifest_schema,
		"content_digest": str(content_digest_variant),
	}


static func _registration_matches_claims(
	registration: Dictionary,
	claims: Dictionary
) -> bool:
	var registration_name_variant: Variant = registration.get("player_name")
	var claim_name_variant: Variant = claims.get("player_name")
	return (
		typeof(registration_name_variant) == TYPE_STRING
		and typeof(claim_name_variant) == TYPE_STRING
		and not str(registration_name_variant).is_empty()
		and str(registration_name_variant) == str(claim_name_variant)
	)


func _reject_auth(peer_id: int, code: String) -> void:
	var acknowledgement := {
		"v": AUTH_PROTOCOL_VERSION,
		"ok": false,
		"code": code,
	}
	if multiplayer.get_authenticating_peers().has(peer_id):
		multiplayer.send_auth(
			peer_id,
			JSON.stringify(acknowledgement).to_utf8_buffer()
		)
	call_deferred("_disconnect_authenticating_peer", peer_id)


func _disconnect_authenticating_peer(peer_id: int) -> void:
	if multiplayer.get_authenticating_peers().has(peer_id):
		multiplayer.disconnect_peer(peer_id)


func _clear_peer_identity(peer_id: int) -> void:
	var was_host := _host_peer_id == peer_id
	_registration_by_peer.erase(peer_id)
	var identity_variant: Variant = _identity_by_peer.get(peer_id)
	_identity_by_peer.erase(peer_id)
	if typeof(identity_variant) != TYPE_DICTIONARY:
		return
	var identity: Dictionary = identity_variant
	var player_name := str(identity.get("player_name", ""))
	if int(_peer_by_player_name.get(player_name, 0)) == peer_id:
		_peer_by_player_name.erase(player_name)
	if was_host:
		_registration_by_peer.clear()
		_host_peer_id = 0
		_set_stub_authority(1)


func _set_stub_authority(peer_id: int) -> void:
	var net_manager_stub := get_node_or_null("/root/NetManager")
	if net_manager_stub != null:
		net_manager_stub.set_multiplayer_authority(peer_id)
	var mp_game_stub := get_node_or_null("/root/MpGame")
	if mp_game_stub != null:
		mp_game_stub.set_multiplayer_authority(peer_id)
	var rogue_route_stub := get_node_or_null("/root/MpRogueRoute")
	if rogue_route_stub != null:
		rogue_route_stub.set_multiplayer_authority(peer_id)


static func is_admission_claim_allowed(
	role: String,
	player_name: String,
	registered_host_peer_id: int,
	active_peer_by_player_name: Dictionary,
	host_was_authenticated: bool = false
) -> bool:
	if player_name.is_empty() or active_peer_by_player_name.has(player_name):
		return false
	if role == "host":
		return registered_host_peer_id <= 0 and not host_was_authenticated
	if role == "member":
		return registered_host_peer_id > 0 and host_was_authenticated
	return false


static func try_consume_ticket_nonce(
	claims: Dictionary,
	consumed_nonce_expiry: Dictionary,
	now_unix: int,
	max_consumed_nonces: int = MAX_CONSUMED_TICKET_NONCES
) -> bool:
	for nonce_variant: Variant in consumed_nonce_expiry.keys():
		if _strict_nonnegative_integer(
			consumed_nonce_expiry.get(nonce_variant)
		) <= now_unix:
			consumed_nonce_expiry.erase(nonce_variant)
	var nonce_variant: Variant = claims.get("nonce")
	if typeof(nonce_variant) != TYPE_STRING:
		return false
	var nonce := str(nonce_variant)
	if nonce.is_empty() or nonce.length() > MAX_TICKET_NONCE_LENGTH:
		return false
	var expires_at := _strict_nonnegative_integer(claims.get("exp"))
	if expires_at <= now_unix or consumed_nonce_expiry.has(nonce):
		return false
	# 票据是单次能力；即使持有合法 member_token 的客户端持续换票并连接，
	# 也不能让短期消费账本无界增长。过期项已在上方清理，满载时 fail-close。
	if (
		max_consumed_nonces <= 0
		or max_consumed_nonces > MAX_CONSUMED_TICKET_NONCES
		or consumed_nonce_expiry.size() >= max_consumed_nonces
	):
		return false
	consumed_nonce_expiry[nonce] = expires_at
	return true


static func verify_admission_ticket(
	ticket: String,
	room_secret: String,
	expected_room_id: String,
	now_unix: int
) -> Dictionary:
	if (
		ticket.is_empty()
		or ticket.length() > AUTH_MAX_TICKET_LENGTH
		or room_secret.length() < MIN_ADMISSION_SECRET_LENGTH
		or expected_room_id.is_empty()
	):
		return {}
	var parts := ticket.split(".", true)
	if parts.size() != 3 or parts[0] != AUTH_TICKET_PREFIX:
		return {}
	var payload := str(parts[1])
	var supplied_signature := str(parts[2])
	if payload.is_empty() or supplied_signature.length() != 64:
		return {}
	if not _is_base64url(payload) or not _is_lowercase_hex(supplied_signature):
		return {}
	var signed_message := "%s.%s" % [AUTH_TICKET_PREFIX, payload]
	var crypto := Crypto.new()
	var expected_signature := crypto.hmac_digest(
		HashingContext.HASH_SHA256,
		room_secret.to_utf8_buffer(),
		signed_message.to_utf8_buffer()
	).hex_encode()
	if not _constant_time_ascii_equal(supplied_signature, expected_signature):
		return {}

	var normalized_payload := payload.replace("-", "+").replace("_", "/")
	while normalized_payload.length() % 4 != 0:
		normalized_payload += "="
	var payload_bytes := Marshalls.base64_to_raw(normalized_payload)
	if payload_bytes.is_empty():
		return {}
	var parsed_claims: Variant = JSON.parse_string(payload_bytes.get_string_from_utf8())
	if typeof(parsed_claims) != TYPE_DICTIONARY:
		return {}
	var claims: Dictionary = parsed_claims
	var required_keys := [
		"v", "room_id", "role", "player_name", "iat", "exp", "nonce"
	]
	if claims.size() != required_keys.size():
		return {}
	for key: String in required_keys:
		if not claims.has(key):
			return {}
	if _strict_nonnegative_integer(claims.get("v")) != AUTH_PROTOCOL_VERSION:
		return {}
	if typeof(claims.get("room_id")) != TYPE_STRING:
		return {}
	if str(claims.get("room_id")) != expected_room_id:
		return {}
	var role_variant: Variant = claims.get("role")
	var player_name_variant: Variant = claims.get("player_name")
	var nonce_variant: Variant = claims.get("nonce")
	if (
		typeof(role_variant) != TYPE_STRING
		or not ["host", "member"].has(str(role_variant))
		or typeof(player_name_variant) != TYPE_STRING
		or str(player_name_variant).is_empty()
		or str(player_name_variant).length() > 32
		or typeof(nonce_variant) != TYPE_STRING
		or str(nonce_variant).is_empty()
		or str(nonce_variant).length() > MAX_TICKET_NONCE_LENGTH
	):
		return {}
	var issued_at := _strict_nonnegative_integer(claims.get("iat"))
	var expires_at := _strict_nonnegative_integer(claims.get("exp"))
	if (
		issued_at < 0
		or expires_at <= issued_at
		or expires_at - issued_at > AUTH_MAX_TICKET_TTL_SEC
		or now_unix < issued_at - AUTH_CLOCK_SKEW_SEC
		or now_unix >= expires_at
	):
		return {}
	return claims


static func _strict_nonnegative_integer(value: Variant) -> int:
	if typeof(value) != TYPE_INT and typeof(value) != TYPE_FLOAT:
		return -1
	var number := float(value)
	if (
		not is_finite(number)
		or number < 0.0
		or number > 9_007_199_254_740_991.0
		or floor(number) != number
	):
		return -1
	return int(number)


static func _is_base64url(value: String) -> bool:
	if value.length() % 4 == 1:
		return false
	for index in value.length():
		var code := value.unicode_at(index)
		if not (
			(code >= 48 and code <= 57)
			or (code >= 65 and code <= 90)
			or (code >= 97 and code <= 122)
			or code == 45
			or code == 95
		):
			return false
	return true


static func _is_safe_room_id(value: String) -> bool:
	if value.is_empty() or value.length() > 64:
		return false
	for index in value.length():
		var code := value.unicode_at(index)
		if not (
			(code >= 48 and code <= 57)
			or (code >= 65 and code <= 90)
			or (code >= 97 and code <= 122)
			or code == 45
			or code == 95
		):
			return false
	return true


static func _is_ascii(value: String) -> bool:
	for index in value.length():
		if value.unicode_at(index) > 127:
			return false
	return true


static func _is_lowercase_hex(value: String) -> bool:
	for index in value.length():
		var code := value.unicode_at(index)
		if not ((code >= 48 and code <= 57) or (code >= 97 and code <= 102)):
			return false
	return true


static func _constant_time_ascii_equal(left: String, right: String) -> bool:
	var difference := left.length() ^ right.length()
	var maximum_length := maxi(left.length(), right.length())
	for index in maximum_length:
		var left_code := left.unicode_at(index) if index < left.length() else 0
		var right_code := right.unicode_at(index) if index < right.length() else 0
		difference |= left_code ^ right_code
	return difference == 0


## Relay 的 server_relay 拓扑下，逻辑 Host 只有到服务端（peer 1）的
## ENet 连接，不能自行取得其他逻辑客户端的 ENetPacketPeer。这个控制面只
## 接受本房间已登记 Host 发出的可靠请求；任何客户端都不能借此踢出他人。
func request_host_peer_disconnect(sender_peer_id: int, target_peer_id: int) -> bool:
	var connected_peers := multiplayer.get_peers()
	if not is_authorized_host_kick_request(
		_host_peer_id,
		sender_peer_id,
		target_peer_id,
		connected_peers
	):
		push_warning(
			"[Relay] 拒绝未经授权的断开请求 sender=%d target=%d host=%d"
			% [sender_peer_id, target_peer_id, _host_peer_id]
		)
		return false
	if _relay_peer == null:
		return false
	_relay_peer.disconnect_peer(target_peer_id, true)
	return true


## Client 在 auth data 中一次性提交原始注册元组。mark_peer_authenticated()
## 先在 CH9 发布 ADD，随后本函数在同一可靠有序信道向 Host 单次转发 Relay
## 账本中的元组；不存在客户端自提交或业务层重试的第二真源。
func _forward_authenticated_player_registration(peer_id: int) -> bool:
	var connected_peers := multiplayer.get_peers()
	if (
		peer_id <= 0
		or peer_id == _host_peer_id
		or _host_peer_id <= 0
		or not connected_peers.has(peer_id)
		or not connected_peers.has(_host_peer_id)
	):
		return false
	var identity_variant: Variant = _identity_by_peer.get(peer_id)
	var registration_variant: Variant = _registration_by_peer.get(peer_id)
	if (
		typeof(identity_variant) != TYPE_DICTIONARY
		or typeof(registration_variant) != TYPE_DICTIONARY
	):
		return false
	var identity: Dictionary = identity_variant
	var registration: Dictionary = registration_variant
	if (
		str(identity.get("role", "")) != "member"
		or str(identity.get("player_name", ""))
		!= str(registration.get("player_name", ""))
	):
		return false
	var net_manager_stub := get_node_or_null("/root/NetManager")
	if net_manager_stub == null:
		return false
	net_manager_stub._rpc_relay_player_registration_forward.rpc_id(
		_host_peer_id,
		peer_id,
		str(registration.get("player_name", "")),
		str(registration.get("character_id", "")),
		bool(registration.get("character_confirmed", false)),
		int(registration.get("protocol_version", -1)),
		str(registration.get("reconnect_token", "")),
		int(registration.get("content_manifest_schema", -1)),
		str(registration.get("content_digest", ""))
	)
	print("[Relay] 已转发认证注册 peer_id=%d" % peer_id)
	return true


## Host 在提交业务注册前向 peer 1 查询 transport 对应的票据身份。结果只从
## Relay 的认证账本产生；请求者提供的 target/name/role 都不能成为身份真源。
func request_authenticated_peer_identity(
	sender_peer_id: int,
	schema_version: int,
	request_id: int,
	target_peer_id: int
) -> bool:
	var connected_peers := multiplayer.get_peers()
	if not is_authorized_host_control_sender(
		_host_peer_id,
		sender_peer_id,
		connected_peers
	):
		return false
	var identity_found := (
		schema_version == AUTH_PROTOCOL_VERSION
		and request_id > 0
		and request_id <= MAX_IDENTITY_LOOKUP_REQUEST_ID
		and is_authorized_host_identity_lookup_target(
			_host_peer_id,
			target_peer_id,
			connected_peers,
			_identity_by_peer
		)
	)
	var player_name := ""
	var role := ""
	if identity_found:
		var identity: Dictionary = _identity_by_peer[target_peer_id]
		player_name = str(identity.get("player_name", ""))
		role = str(identity.get("role", ""))
	var net_manager_stub := get_node_or_null("/root/NetManager")
	if net_manager_stub == null:
		return false
	print(
		"[Relay] 身份查询 host=%d target=%d request=%d found=%s"
		% [sender_peer_id, target_peer_id, request_id, identity_found]
	)
	net_manager_stub._rpc_relay_identity_result.rpc_id(
		sender_peer_id,
		AUTH_PROTOCOL_VERSION,
		request_id,
		target_peer_id,
		_room_id,
		player_name,
		role,
		identity_found
	)
	return identity_found


static func is_authorized_host_control_sender(
	registered_host_peer_id: int,
	sender_peer_id: int,
	connected_peers: PackedInt32Array
) -> bool:
	return (
		registered_host_peer_id > 0
		and sender_peer_id == registered_host_peer_id
		and connected_peers.has(sender_peer_id)
	)


static func is_authorized_host_identity_lookup_target(
	registered_host_peer_id: int,
	target_peer_id: int,
	connected_peers: PackedInt32Array,
	identity_by_peer: Dictionary
) -> bool:
	if (
		target_peer_id <= 0
		or target_peer_id == registered_host_peer_id
		or not connected_peers.has(target_peer_id)
	):
		return false
	var identity_variant: Variant = identity_by_peer.get(target_peer_id)
	if typeof(identity_variant) != TYPE_DICTIONARY:
		return false
	var identity: Dictionary = identity_variant
	return (
		str(identity.get("role", "")) == "member"
		and not str(identity.get("player_name", "")).is_empty()
	)


static func is_authorized_host_kick_request(
	registered_host_peer_id: int,
	sender_peer_id: int,
	target_peer_id: int,
	connected_peers: PackedInt32Array
) -> bool:
	return (
		is_authorized_host_control_sender(
			registered_host_peer_id,
			sender_peer_id,
			connected_peers
		)
		and target_peer_id > 0
		and target_peer_id != registered_host_peer_id
		and connected_peers.has(target_peer_id)
	)
