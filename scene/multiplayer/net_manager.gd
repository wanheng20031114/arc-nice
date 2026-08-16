extends Node
class_name NetManagerStore

const NetConstants := preload("res://scene/multiplayer/net_constants.gd")
const MultiplayerReconnectTypesScript := preload(
	"res://scene/multiplayer/reconnect/multiplayer_reconnect_types.gd"
)

signal connection_state_changed(new_state: ConnectionState)
signal player_joined(peer_id: int, player_name: String)
signal player_left(peer_id: int)
signal player_reconnected(
	old_peer_id: int,
	new_peer_id: int,
	player_name: String,
	character_id: StringName,
	membership_revision: int
)
## Host 在成员已从 RECONNECTING 提升为 ACTIVE、pending send gate 已释放且
## host-ready 已排入传输后发布。这是不可失败的最终通知，不得承载快照准备。
signal player_reconnect_ready(
	old_peer_id: int,
	new_peer_id: int,
	outcome: MultiplayerReconnectTypesScript.RuntimeProjectionOutcome,
	membership_revision: int
)
signal session_membership_changed(peer_ids: PackedInt32Array, revision: int)
signal session_member_final_departed(
	peer_id: int,
	revision: int,
	reason: StringName
)
signal player_list_changed
signal player_character_changed(peer_id: int, character_id: StringName, confirmed: bool)
signal connection_failed(reason: String)
signal game_mode_changed(new_game_mode: GameMode)
signal room_capacity_changed(current_players: int, max_players: int)
signal game_load_progress_changed(ready_count: int, total_count: int)

const DEFAULT_CHARACTER_ID := &"weishidaier"
const RECONNECT_TOKEN_HEX_LENGTH := 32
const RECONNECT_GRACE_MILLISECONDS := 90_000
const RECONNECT_LOAD_TIMEOUT_MILLISECONDS := 30_000
const RECONNECT_PROJECTION_TIMEOUT_MILLISECONDS := 3_000
const RECONNECT_DELIVERY_PREPARATION_TIMEOUT_MILLISECONDS := 3_000
const LATE_REGISTRATION_TIMEOUT_MILLISECONDS := 5_000
const LOBBY_COMMAND_RATE_PER_SECOND := 6.0
const LOBBY_COMMAND_RATE_BURST := 12.0
const MAX_LOBBY_PLAYER_NAME_WIRE_LENGTH := 64
const MAX_LOBBY_CHARACTER_ID_WIRE_LENGTH := 64
const STABLE_PARTICIPANT_KEY_DOMAIN := "arc-nice:rogue-participant:v1:"
const SESSION_MEMBERSHIP_SCHEMA_VERSION := 2
const FINAL_DEPARTURE_DISCONNECTED := &"disconnected"
const FINAL_DEPARTURE_GRACE_EXPIRED := &"grace_expired"
const FINAL_DEPARTURE_PROJECTION_FAILED := &"projection_failed"
const RELAY_SERVICE_PEER_ID := 1

static var _autoload_instance: NetManagerStore = null

enum NetRole { NONE, HOST, CLIENT }
enum ConnMode { DIRECT, RELAY }
enum SessionMemberState {
	ACTIVE,
	SUSPENDED_GRACE,
	RECONNECTING,
}
const ReconnectPendingPhase := MultiplayerReconnectTypesScript.PendingPhase
enum GameMode {
	STANDARD = GameModeCatalog.MODE_STANDARD,
	TOWER_DEFENSE = GameModeCatalog.MODE_TOWER_DEFENSE,
	TEST_ARENA_P1 = GameModeCatalog.MODE_TEST_ARENA_P1,
	TEST_ARENA_P2 = GameModeCatalog.MODE_TEST_ARENA_P2,
	TEST_ARENA_P3 = GameModeCatalog.MODE_TEST_ARENA_P3,
	TEST_ARENA_P1B = GameModeCatalog.MODE_TEST_ARENA_P1B,
	TEST_ARENA_P1C = GameModeCatalog.MODE_TEST_ARENA_P1C,
	TEST_ARENA_P1D = GameModeCatalog.MODE_TEST_ARENA_P1D,
	TEST_ARENA_P1E = GameModeCatalog.MODE_TEST_ARENA_P1E,
}
enum ConnectionState {
	DISCONNECTED,
	HOSTING_LAN,
	CONNECTING_LAN,
	CONNECTED_IN_LOBBY,
	LOADING_GAME,
	IN_GAME,
}

var net_role: NetRole = NetRole.NONE
var conn_mode: ConnMode = ConnMode.DIRECT
var connection_state: ConnectionState = ConnectionState.DISCONNECTED
var local_player_name: String = ""
var local_character_id: StringName = DEFAULT_CHARACTER_ID
var local_character_confirmed: bool = true
var lan_port: int = NetConstants.ENET_PORT_DEFAULT
var relay_ip: String = ""
var relay_port: int = 0
var connected_players: Dictionary = {}
var connected_player_characters: Dictionary = {}
var confirmed_character_peers: Dictionary = {}
var host_peer_id: int = 1
var host_game_ready: bool = false
var public_room_id: String = ""
var public_host_token: String = ""
var public_is_host: bool = false
var current_game_mode: GameMode = GameMode.STANDARD
## 开发 Host 权限只能由显式 fixture API 获取，并在断线时恢复为 RELEASE。
var _host_mode_selection_audience := GameModeDefinition.SelectionAudience.RELEASE
## roster 可保存 known wire，但运行加载只消费此受众；默认永远是 RELEASE。
var _runtime_mode_selection_audience := GameModeDefinition.SelectionAudience.RELEASE
## 房间允许的总人数，包含房主。
var room_max_players: int = NetConstants.MAX_PLAYERS
## 当前 Host 权威游戏会话世代。断线时可清零当前值，但分配水位不得回退，
## 否则重开房间会让旧 CH6 包与新局发生 ABA。
var loading_session_id: int = 0
var _last_game_session_incarnation: int = 0
var local_reconnect_token: String = ""

var _physics_frame_count: int = 0
var _enet_peer: ENetMultiplayerPeer = null
var _disconnect_in_progress: bool = false
var _relay_register_pending: bool = false
var _connect_started_msec: int = 0
var _connect_timeout_ms: int = 0
var _connect_target_description: String = ""
var _connected_signal_handled: bool = false
var _expected_game_load_peers: Dictionary = {}
var _ready_game_load_peers: Dictionary = {}
var _reported_game_load_ready_count: int = 0
var _reported_game_load_total_count: int = 0
var _peer_reconnect_tokens: Dictionary[int, String] = {}
## 会话成员与传输连接分离：这里是 ACTIVE ∪ SUSPENDED_GRACE 的唯一真源。
## reconnect slot 只作为 token 索引，姓名、角色与状态一律从本表读取。
var _session_members: Dictionary[int, Dictionary] = {}
var _session_membership_revision: int = 0
## 只由本机担任 Host 时分配。成员表清空不会回退水位，确保最终离场后
## 同一个 transport ID 再次出现时也不能获得旧成员世代。
var _last_host_participant_incarnation: int = 0
var _disconnected_reconnect_slots: Dictionary[String, int] = {}
var _pending_reconnect_loads: Dictionary[int, Dictionary] = {}
## 已完成报告只服务于可靠重放幂等，不参与后续身份路由；transport 离开时清除。
var _completed_reconnect_runtime_projections: Dictionary[int, Dictionary] = {}
## 同一时刻只有一个顶层玩法会话拥有重连准备能力。Callable 必须同步
## 返回 bool，避免 signal 无法汇总返回值导致的半发布。
var _reconnect_delivery_preparer: Callable = Callable()
## 运行时投影被判定不可恢复后，后续 ENet 断线不得再生成新的宽限席位。
var _forced_final_departure_peer_ids: Dictionary[int, bool] = {}
## 成员账本无法投影到本地运行时时，整个本地会话已不再可信。先同步关闭
## admission，再延后一帧断网，避免在 NetManager 自己的 signal 栈中重入清表。
var _session_projection_failure_active: bool = false
var _late_registration_deadlines: Dictionary[int, int] = {}
var _lobby_command_rate_buckets: Dictionary[int, Dictionary] = {}


func _enter_tree() -> void:
	if name != &"NetManager" or get_parent() != get_tree().root:
		return
	assert(
		_autoload_instance == null or _autoload_instance == self,
		"NetManagerStore 只允许一个项目级自动加载实例。"
	)
	_autoload_instance = self


func _ready() -> void:
	_ensure_local_reconnect_token()


func _exit_tree() -> void:
	if _autoload_instance == self:
		_autoload_instance = null


static func get_autoload_instance() -> NetManagerStore:
	return _autoload_instance


func _physics_process(_delta: float) -> void:
	_physics_frame_count += 1
	_poll_pending_connection()
	_poll_reconnect_deadlines()
	if _relay_register_pending:
		_try_send_relay_registration()


func get_physics_frame_count() -> int:
	return _physics_frame_count


func set_local_reconnect_token(token: String) -> bool:
	if is_multiplayer_active():
		return false
	var normalized := token.strip_edges().to_lower()
	if not _is_valid_reconnect_token(normalized):
		return false
	local_reconnect_token = normalized
	return true


func _ensure_local_reconnect_token() -> void:
	if _is_valid_reconnect_token(local_reconnect_token):
		return
	local_reconnect_token = Crypto.new().generate_random_bytes(16).hex_encode()
	if not _is_valid_reconnect_token(local_reconnect_token):
		push_error("NetManager: 无法生成有效的重连身份令牌。")


func _is_valid_reconnect_token(token: String) -> bool:
	return (
		token.length() == RECONNECT_TOKEN_HEX_LENGTH
		and token == token.to_lower()
		and token.is_valid_hex_number(false)
	)


## 为需要跨重连保持确定性的运行时系统提供不透明参与者身份。
## 只暴露带域前缀的 SHA-256 摘要，绝不把重连令牌交给玩法或网络快照层。
func get_stable_participant_key(peer_id: int) -> String:
	if peer_id == 0 and not is_multiplayer_active():
		return "rogue-participant:v1:singleplayer"
	if peer_id <= 0:
		return ""
	var reconnect_token := ""
	var local_peer_id := get_local_peer_id() if is_inside_tree() else 0
	if peer_id == local_peer_id:
		reconnect_token = local_reconnect_token
	elif is_host():
		reconnect_token = str(_peer_reconnect_tokens.get(peer_id, ""))
		if not _is_valid_reconnect_token(reconnect_token) and _session_members.has(peer_id):
			reconnect_token = str(
				(_session_members[peer_id] as Dictionary).get(
					"reconnect_token",
					""
				)
			)
	if not _is_valid_reconnect_token(reconnect_token):
		return ""
	return "rogue-participant:v1:%s" % (
		STABLE_PARTICIPANT_KEY_DOMAIN + reconnect_token
	).sha256_text()


## 会话成员包含当前在线与仍在重连宽限期内的玩家；传输层 connected_players
## 只描述当前可发包的身份，玩法 roster 必须使用以下接口。
func get_session_membership_revision() -> int:
	return _session_membership_revision


func get_session_participant_incarnation(peer_id: int) -> int:
	if peer_id <= 0 or not _session_members.has(peer_id):
		return 0
	var participant_incarnation := int(
		(_session_members[peer_id] as Dictionary).get(
			"participant_incarnation",
			0
		)
	)
	if (
		participant_incarnation <= 0
		or participant_incarnation > NetConstants.MAX_PARTICIPANT_INCARNATION
	):
		return 0
	return participant_incarnation


## participant incarnation 是成员租约身份；peer_id 只是它当前占用的传输地址。
## 成员数最多为八，直接扫描可以避免维护一份可能与 roster 分叉的反向索引。
func resolve_session_participant_peer_id(participant_incarnation: int) -> int:
	if (
		participant_incarnation <= 0
		or participant_incarnation > NetConstants.MAX_PARTICIPANT_INCARNATION
	):
		return 0
	var resolved_peer_id := 0
	for peer_id in get_session_member_peer_ids():
		if get_session_participant_incarnation(peer_id) != participant_incarnation:
			continue
		if resolved_peer_id > 0:
			return 0
		resolved_peer_id = peer_id
	return resolved_peer_id


func has_session_member(peer_id: int) -> bool:
	return peer_id > 0 and _session_members.has(peer_id)


func is_session_member_active(peer_id: int) -> bool:
	if not has_session_member(peer_id):
		return false
	return int((_session_members[peer_id] as Dictionary).get("state", -1)) == int(
		SessionMemberState.ACTIVE
	)


func is_session_member_suspended(peer_id: int) -> bool:
	if not has_session_member(peer_id):
		return false
	return int((_session_members[peer_id] as Dictionary).get("state", -1)) == int(
		SessionMemberState.SUSPENDED_GRACE
	)


## 玩法 RPC 的统一入站租约。connected 只证明 transport 已建立；重连者必须
## 等身份、成员 ACTIVE 与运行时 Player 投影全部提交后，才可修改权威玩法状态。
## loaded、repair、reconnect 等控制面继续读取 raw sender，不调用此接口。
func is_gameplay_ingress_admitted(peer_id: int) -> bool:
	return (
		is_host()
		and connection_state == ConnectionState.IN_GAME
		and peer_id > 0
		and connected_players.has(peer_id)
		and is_session_member_active(peer_id)
		and not _pending_reconnect_loads.has(peer_id)
		and not _forced_final_departure_peer_ids.has(peer_id)
		and not _session_projection_failure_active
	)


func is_session_member_reconnecting(peer_id: int) -> bool:
	if not has_session_member(peer_id):
		return false
	return int((_session_members[peer_id] as Dictionary).get("state", -1)) == int(
		SessionMemberState.RECONNECTING
	)


func get_session_member_peer_ids() -> PackedInt32Array:
	var peer_ids := PackedInt32Array()
	for raw_peer_id in _session_members.keys():
		peer_ids.append(int(raw_peer_id))
	peer_ids.sort()
	return peer_ids


func get_active_session_member_peer_ids() -> PackedInt32Array:
	var peer_ids := PackedInt32Array()
	for peer_id in get_session_member_peer_ids():
		if is_session_member_active(peer_id):
			peer_ids.append(peer_id)
	return peer_ids


func get_session_player_name_map() -> Dictionary:
	var result: Dictionary = {}
	for peer_id in get_session_member_peer_ids():
		result[peer_id] = str(
			(_session_members[peer_id] as Dictionary).get("player_name", "Player")
		)
	return result


func get_session_player_character_map() -> Dictionary:
	var result: Dictionary = {}
	for peer_id in get_session_member_peer_ids():
		result[peer_id] = StringName(
			(_session_members[peer_id] as Dictionary).get(
				"character_id",
				DEFAULT_CHARACTER_ID
			)
		)
	return result


func get_session_membership_snapshot(recipient_peer_id: int = 0) -> Dictionary:
	return {
		"schema_version": SESSION_MEMBERSHIP_SCHEMA_VERSION,
		"revision": _session_membership_revision,
		"members": _build_session_member_list_array(recipient_peer_id),
	}


func set_public_room_context(room_id: String, host_token: String, is_public_host: bool) -> void:
	public_room_id = room_id.strip_edges()
	public_host_token = host_token.strip_edges()
	public_is_host = is_public_host


func clear_public_room_context() -> void:
	public_room_id = ""
	public_host_token = ""
	public_is_host = false


func set_host_game_mode(game_mode: GameMode) -> bool:
	return _set_host_game_mode_for_audience(
		game_mode,
		GameModeDefinition.SelectionAudience.RELEASE
	)


## 仅供调试构建中的联机 fixture；生产 UI 和正式导出不能取得该准入。
func set_development_host_game_mode_for_fixture(game_mode: GameMode) -> bool:
	if not OS.is_debug_build():
		return false
	return _set_host_game_mode_for_audience(
		game_mode,
		GameModeDefinition.SelectionAudience.DEVELOPMENT
	)


## 调试 Client 必须在收到隐藏模式 start 前显式获取运行许可。
func enable_development_runtime_modes_for_fixture() -> bool:
	if not OS.is_debug_build():
		return false
	_runtime_mode_selection_audience = (
		GameModeDefinition.SelectionAudience.DEVELOPMENT
	)
	return true


func is_runtime_game_mode_admitted(game_mode: int) -> bool:
	return GameModeCatalog.is_selectable_for_audience(
		game_mode,
		_runtime_mode_selection_audience
	)


func _set_host_game_mode_for_audience(
	game_mode: GameMode,
	audience: GameModeDefinition.SelectionAudience
) -> bool:
	var definition := GameModeCatalog.get_definition(int(game_mode))
	if definition == null or not definition.is_selectable_for(audience):
		return false
	if is_client() or connection_state >= ConnectionState.LOADING_GAME:
		return false
	_host_mode_selection_audience = audience
	_runtime_mode_selection_audience = audience
	_set_current_game_mode(game_mode)
	if is_host():
		_broadcast_player_list_to_clients()
	return true


func set_pending_game_mode(game_mode: GameMode) -> bool:
	if not _is_release_game_mode(int(game_mode)):
		return false
	if is_multiplayer_active() or net_role != NetRole.NONE:
		return false
	_host_mode_selection_audience = GameModeDefinition.SelectionAudience.RELEASE
	_runtime_mode_selection_audience = GameModeDefinition.SelectionAudience.RELEASE
	_set_current_game_mode(game_mode)
	return true


func get_current_game_mode() -> GameMode:
	return current_game_mode


static func game_mode_to_key(game_mode: GameMode) -> String:
	var definition := GameModeCatalog.get_definition(int(game_mode))
	if definition == null:
		definition = GameModeCatalog.get_definition(
			GameModeCatalog.DEFAULT_MODE_ID
		)
	return String(definition.wire_key) if definition != null else ""


static func game_mode_from_key(game_mode_key: String) -> GameMode:
	return (
		GameModeCatalog.resolve_wire_key_or_default(game_mode_key)
		as GameMode
	)


static func get_game_mode_display_name(game_mode: GameMode) -> String:
	var definition := GameModeCatalog.get_definition(int(game_mode))
	if definition == null:
		definition = GameModeCatalog.get_definition(
			GameModeCatalog.DEFAULT_MODE_ID
		)
	return definition.display_name if definition != null else ""


func set_pending_room_max_players(max_players: int) -> bool:
	if not _is_valid_room_max_players(max_players):
		return false
	if is_multiplayer_active() or net_role != NetRole.NONE:
		return false
	room_max_players = max_players
	_emit_room_capacity_changed()
	return true


func get_room_max_players() -> int:
	return room_max_players


func is_multiplayer_active() -> bool:
	return (
		not _disconnect_in_progress
		and not _session_projection_failure_active
		and net_role != NetRole.NONE
		and connection_state != ConnectionState.DISCONNECTED
	)


func is_host() -> bool:
	return (
		not _disconnect_in_progress
		and not _session_projection_failure_active
		and net_role == NetRole.HOST
	)


func is_client() -> bool:
	return (
		not _disconnect_in_progress
		and not _session_projection_failure_active
		and net_role == NetRole.CLIENT
	)


func host_create_lan_server(
	port: int = NetConstants.ENET_PORT_DEFAULT,
	max_players: int = NetConstants.MAX_PLAYERS
) -> Error:
	if not _validate_host_game_mode_admission():
		return ERR_UNAVAILABLE
	_ensure_local_reconnect_token()
	if not _is_valid_room_max_players(max_players):
		connection_failed.emit(
			"房间人数必须在 %d 到 %d 之间"
			% [NetConstants.MIN_ROOM_PLAYERS, NetConstants.MAX_PLAYERS]
		)
		return ERR_INVALID_PARAMETER
	var configured_game_mode := current_game_mode
	var configured_mode_audience := _host_mode_selection_audience
	if _enet_peer != null:
		disconnect_from_game()
	_set_current_game_mode(configured_game_mode)
	_host_mode_selection_audience = configured_mode_audience
	_runtime_mode_selection_audience = configured_mode_audience
	room_max_players = max_players

	lan_port = port
	_enet_peer = ENetMultiplayerPeer.new()
	var err: Error = _enet_peer.create_server(
		port,
		room_max_players - 1,
		NetConstants.CHANNEL_COUNT
	)
	if err != OK:
		_enet_peer = null
		connection_failed.emit("创建局域网主机失败: %s" % error_string(err))
		return err

	_connect_multiplayer_signals(false)
	multiplayer.multiplayer_peer = _enet_peer
	net_role = NetRole.HOST
	conn_mode = ConnMode.DIRECT
	connected_players.clear()
	connected_player_characters.clear()
	confirmed_character_peers.clear()
	_clear_reconnect_session_state()
	_reset_session_membership()
	host_peer_id = get_local_peer_id()
	if host_peer_id <= 0:
		host_peer_id = 1
	set_multiplayer_authority(host_peer_id)
	connected_players[host_peer_id] = _sanitize_player_name(local_player_name)
	connected_player_characters[host_peer_id] = _sanitize_character_id(local_character_id)
	confirmed_character_peers[host_peer_id] = local_character_confirmed
	if not _register_active_session_member(
		host_peer_id,
		connected_players[host_peer_id],
		connected_player_characters[host_peer_id],
		local_character_confirmed,
		local_reconnect_token
	):
		connection_failed.emit("Host 成员世代已耗尽，请重启游戏后重新建房。")
		disconnect_from_game()
		return ERR_OUT_OF_MEMORY
	_physics_frame_count = 0
	_set_connection_state(ConnectionState.HOSTING_LAN)
	player_joined.emit(host_peer_id, connected_players[host_peer_id])
	player_list_changed.emit()
	_emit_room_capacity_changed()
	_debug_log(
		"NetManager: LAN Host 已创建, port=%d, max_players=%d"
		% [port, room_max_players]
	)
	return OK


func host_create_server(
	port: int = NetConstants.ENET_PORT_DEFAULT,
	max_players: int = NetConstants.MAX_PLAYERS
) -> Error:
	return host_create_lan_server(port, max_players)


func client_connect_lan(host_ip: String, port: int = NetConstants.ENET_PORT_DEFAULT) -> Error:
	_ensure_local_reconnect_token()
	var pending_game_mode := current_game_mode
	var pending_room_max_players := room_max_players
	if _enet_peer != null:
		disconnect_from_game()
	_set_current_game_mode(pending_game_mode)
	room_max_players = pending_room_max_players

	var trimmed_ip := host_ip.strip_edges()
	if trimmed_ip.is_empty():
		connection_failed.emit("主机 IP 不能为空")
		return ERR_INVALID_PARAMETER

	lan_port = port
	_enet_peer = ENetMultiplayerPeer.new()
	var err: Error = _enet_peer.create_client(trimmed_ip, port, NetConstants.CHANNEL_COUNT)
	if err != OK:
		_enet_peer = null
		connection_failed.emit("连接局域网主机失败: %s" % error_string(err))
		return err

	net_role = NetRole.CLIENT
	conn_mode = ConnMode.DIRECT
	connected_players.clear()
	connected_player_characters.clear()
	confirmed_character_peers.clear()
	_reset_session_membership()
	host_peer_id = 1
	set_multiplayer_authority(host_peer_id)
	_physics_frame_count = 0
	_begin_connection_attempt(
		NetConstants.DIRECT_CONNECT_TIMEOUT_MS,
		"局域网主机 %s:%d" % [trimmed_ip, port]
	)
	_set_connection_state(ConnectionState.CONNECTING_LAN)
	_connect_multiplayer_signals(true)
	multiplayer.multiplayer_peer = _enet_peer
	_debug_log("NetManager: Client 正在连接 LAN Host %s:%d" % [trimmed_ip, port])
	return OK


func client_connect_direct(host_ip: String, port: int = NetConstants.ENET_PORT_DEFAULT) -> Error:
	return client_connect_lan(host_ip, port)


func host_create_relay_room(
	target_relay_ip: String,
	target_relay_port: int,
	max_players: int = NetConstants.MAX_PLAYERS
) -> Error:
	if not _validate_host_game_mode_admission():
		return ERR_UNAVAILABLE
	_ensure_local_reconnect_token()
	if not _is_valid_room_max_players(max_players):
		connection_failed.emit(
			"房间人数必须在 %d 到 %d 之间"
			% [NetConstants.MIN_ROOM_PLAYERS, NetConstants.MAX_PLAYERS]
		)
		return ERR_INVALID_PARAMETER
	var configured_game_mode := current_game_mode
	var configured_mode_audience := _host_mode_selection_audience
	if _enet_peer != null:
		disconnect_from_game()
	_set_current_game_mode(configured_game_mode)
	_host_mode_selection_audience = configured_mode_audience
	_runtime_mode_selection_audience = configured_mode_audience
	room_max_players = max_players

	var trimmed_ip := target_relay_ip.strip_edges()
	if trimmed_ip.is_empty():
		connection_failed.emit("Relay 地址不能为空")
		return ERR_INVALID_PARAMETER
	if target_relay_port <= 0:
		connection_failed.emit("Relay 端口无效")
		return ERR_INVALID_PARAMETER

	relay_ip = trimmed_ip
	relay_port = target_relay_port
	_enet_peer = ENetMultiplayerPeer.new()
	var err: Error = _enet_peer.create_client(trimmed_ip, target_relay_port, NetConstants.CHANNEL_COUNT)
	if err != OK:
		_enet_peer = null
		connection_failed.emit("连接公网 Relay 失败: %s" % error_string(err))
		return err

	net_role = NetRole.HOST
	conn_mode = ConnMode.RELAY
	connected_players.clear()
	connected_player_characters.clear()
	confirmed_character_peers.clear()
	_clear_reconnect_session_state()
	_reset_session_membership()
	host_peer_id = 0
	set_multiplayer_authority(1)
	_relay_register_pending = false
	_physics_frame_count = 0
	_begin_connection_attempt(
		NetConstants.RELAY_CONNECT_TIMEOUT_MS,
		"公网 Relay %s:%d" % [trimmed_ip, target_relay_port]
	)
	_set_connection_state(ConnectionState.CONNECTING_LAN)
	_connect_multiplayer_signals(true)
	multiplayer.multiplayer_peer = _enet_peer
	_debug_log("NetManager: Host 正在连接 Relay %s:%d" % [trimmed_ip, target_relay_port])
	return OK


func client_join_relay_room(
	target_relay_ip: String,
	target_relay_port: int,
	target_host_peer_id: int
) -> Error:
	_ensure_local_reconnect_token()
	var pending_game_mode := current_game_mode
	var pending_room_max_players := room_max_players
	if _enet_peer != null:
		disconnect_from_game()
	_set_current_game_mode(pending_game_mode)
	room_max_players = pending_room_max_players

	var trimmed_ip := target_relay_ip.strip_edges()
	if trimmed_ip.is_empty():
		connection_failed.emit("Relay 地址不能为空")
		return ERR_INVALID_PARAMETER
	if target_relay_port <= 0 or target_host_peer_id <= 0:
		connection_failed.emit("Relay 房间信息无效")
		return ERR_INVALID_PARAMETER

	relay_ip = trimmed_ip
	relay_port = target_relay_port
	_enet_peer = ENetMultiplayerPeer.new()
	var err: Error = _enet_peer.create_client(trimmed_ip, target_relay_port, NetConstants.CHANNEL_COUNT)
	if err != OK:
		_enet_peer = null
		connection_failed.emit("连接公网 Relay 失败: %s" % error_string(err))
		return err

	net_role = NetRole.CLIENT
	conn_mode = ConnMode.RELAY
	connected_players.clear()
	connected_player_characters.clear()
	confirmed_character_peers.clear()
	_reset_session_membership()
	host_peer_id = target_host_peer_id
	set_multiplayer_authority(host_peer_id)
	_relay_register_pending = false
	_physics_frame_count = 0
	_begin_connection_attempt(
		NetConstants.RELAY_CONNECT_TIMEOUT_MS,
		"公网 Relay %s:%d" % [trimmed_ip, target_relay_port]
	)
	_set_connection_state(ConnectionState.CONNECTING_LAN)
	_connect_multiplayer_signals(true)
	multiplayer.multiplayer_peer = _enet_peer
	_debug_log("NetManager: Client 正在连接 Relay %s:%d host=%d" % [trimmed_ip, target_relay_port, target_host_peer_id])
	return OK


func disconnect_from_game() -> void:
	_disconnect_in_progress = true
	_cleanup_multiplayer_signals()
	if multiplayer.has_multiplayer_peer():
		multiplayer.multiplayer_peer = null

	_enet_peer = null
	net_role = NetRole.NONE
	conn_mode = ConnMode.DIRECT
	relay_ip = ""
	relay_port = 0
	connected_players.clear()
	connected_player_characters.clear()
	confirmed_character_peers.clear()
	_clear_reconnect_session_state()
	_reset_session_membership(true)
	host_peer_id = 1
	set_multiplayer_authority(host_peer_id)
	host_game_ready = false
	loading_session_id = 0
	_expected_game_load_peers.clear()
	_ready_game_load_peers.clear()
	_reported_game_load_ready_count = 0
	_reported_game_load_total_count = 0
	clear_public_room_context()
	_set_current_game_mode(GameMode.STANDARD)
	_host_mode_selection_audience = GameModeDefinition.SelectionAudience.RELEASE
	_runtime_mode_selection_audience = GameModeDefinition.SelectionAudience.RELEASE
	room_max_players = NetConstants.MAX_PLAYERS
	_relay_register_pending = false
	_clear_connection_attempt()
	_physics_frame_count = 0
	_set_connection_state(ConnectionState.DISCONNECTED)
	player_list_changed.emit()
	_emit_room_capacity_changed()
	_debug_log("NetManager: 已断开连接")
	_disconnect_in_progress = false
	_session_projection_failure_active = false


## Player 身份已认证但战斗投影持续无法建立时，会话不能继续保留半个成员。
## Host 只拒绝故障 peer；Client 无法修复本地视图时退出整局并重新加载。
func terminate_for_runtime_projection_failure(
	peer_id: int,
	reason: String
) -> bool:
	var safe_reason := reason.strip_edges()
	if safe_reason.is_empty():
		safe_reason = "玩家运行时投影无法建立，请重新连接。"
	if is_host():
		if (
			peer_id <= 0
			or peer_id == get_host_peer_id()
			or not connected_players.has(peer_id)
		):
			return false
		# 多个运行时监听者可能在同一个 reconnect 信号栈中发现同一故障。
		# 首个监听者已经开始 final departure 后，其余监听者只确认该事务，
		# 不得重复广播 roster、拒绝包或安排第二次断开。
		if _forced_final_departure_peer_ids.has(peer_id):
			return true
		var final_member_peer_id := peer_id
		if _pending_reconnect_loads.has(peer_id):
			var pending := _pending_reconnect_loads[peer_id] as Dictionary
			# 身份事务提交前，session 真源仍是 old；提交后则已经是 new。
			# 两阶段 ready 会保留 pending 到 Player 投影完成，不能固定清 old。
			final_member_peer_id = (
				peer_id
				if bool(pending.get("identity_committed", false))
				else int(pending.get("old_peer_id", peer_id))
			)
		_forced_final_departure_peer_ids[peer_id] = true
		_finalize_session_member_departures(
			PackedInt32Array([final_member_peer_id]),
			FINAL_DEPARTURE_PROJECTION_FAILED
		)
		_broadcast_player_list_to_clients()
		if (
			is_inside_tree()
			and multiplayer.has_multiplayer_peer()
			and is_peer_control_send_ready(peer_id)
		):
			_rpc_join_rejected.rpc_id(peer_id, safe_reason)
		call_deferred("_disconnect_incompatible_peer", peer_id)
		return true
	if not is_client():
		return false
	connection_failed.emit(safe_reason)
	disconnect_from_game()
	return true


## 会话成员是所有持久 peer 账本的根身份。任一运行时无法按同一 revision
## 原子投影该集合时，本机不能继续接受网络状态；Host 与 Client 都退出整局，
## 而不是删除一部分证据后伪装成已收敛。
func terminate_for_session_membership_projection_failure(reason: String) -> bool:
	if _session_projection_failure_active:
		return true
	if _disconnect_in_progress or connection_state == ConnectionState.DISCONNECTED:
		return false
	var safe_reason := reason.strip_edges()
	if safe_reason.is_empty():
		safe_reason = "多人会话成员账本无法收敛，请重新进入房间。"
	_session_projection_failure_active = true
	connection_failed.emit(safe_reason)
	call_deferred("_disconnect_after_session_membership_projection_failure")
	return true


func _disconnect_after_session_membership_projection_failure() -> void:
	if not _session_projection_failure_active:
		return
	disconnect_from_game()


func host_start_game() -> void:
	if not is_host():
		return
	if connection_state >= ConnectionState.LOADING_GAME:
		return
	if not _validate_host_game_mode_admission():
		return
	if not are_all_player_characters_confirmed():
		connection_failed.emit("仍有玩家尚未确认角色")
		return
	host_game_ready = false
	loading_session_id = _issue_next_game_session_incarnation()
	if loading_session_id <= 0:
		connection_failed.emit("游戏会话世代已耗尽，请重启游戏后重新建房。")
		return
	_expected_game_load_peers.clear()
	_ready_game_load_peers.clear()
	for peer_id_variant in connected_players:
		_expected_game_load_peers[int(peer_id_variant)] = true
	_set_connection_state(ConnectionState.LOADING_GAME)
	_emit_game_load_progress()
	_send_start_game_to_clients()


func host_broadcast_start_game() -> void:
	if not is_host():
		return
	if connection_state != ConnectionState.LOADING_GAME:
		return
	_send_start_game_to_clients()


func mark_in_game() -> void:
	if not is_host():
		return
	if connection_state != ConnectionState.LOADING_GAME:
		return
	if not _are_all_game_load_peers_ready():
		return
	host_game_ready = true
	_set_connection_state(ConnectionState.IN_GAME)
	_send_host_game_ready_to_clients()


func report_game_loaded() -> void:
	if connection_state != ConnectionState.LOADING_GAME or loading_session_id <= 0:
		return
	var local_peer_id := get_local_peer_id()
	if local_peer_id <= 0 and is_host():
		local_peer_id = get_host_peer_id()
	if local_peer_id <= 0:
		return
	if is_host():
		_mark_peer_game_loaded(local_peer_id, loading_session_id)
	elif is_client():
		_rpc_report_game_loaded.rpc_id(get_host_peer_id(), loading_session_id)


func get_game_load_progress() -> Dictionary:
	return {
		"ready": _reported_game_load_ready_count,
		"total": _reported_game_load_total_count,
		"session_id": loading_session_id,
	}


func get_game_session_incarnation() -> int:
	if (
		loading_session_id <= 0
		or loading_session_id > NetConstants.MAX_GAME_SESSION_INCARNATION
	):
		return 0
	return loading_session_id


## 只由 Host 开始新局时分配；水位跨 disconnect 保留，当前 session 清零不会
## 让下一局重新使用 1。客户端也会记录见过的水位，之后切换为 Host 仍不回退。
func _issue_next_game_session_incarnation() -> int:
	var baseline := maxi(
		_last_game_session_incarnation,
		loading_session_id
	)
	if baseline >= NetConstants.MAX_GAME_SESSION_INCARNATION:
		return 0
	_last_game_session_incarnation = baseline + 1
	return _last_game_session_incarnation


func _issue_next_participant_incarnation() -> int:
	if _last_host_participant_incarnation >= NetConstants.MAX_PARTICIPANT_INCARNATION:
		return 0
	_last_host_participant_incarnation += 1
	return _last_host_participant_incarnation


func set_local_character_id(character_id: StringName, confirmed: bool = true) -> bool:
	if is_multiplayer_active() and connection_state >= ConnectionState.LOADING_GAME:
		return false
	var resolved_character_id := _sanitize_character_id(character_id)
	if resolved_character_id != character_id:
		return false
	local_character_id = resolved_character_id
	local_character_confirmed = confirmed
	var local_peer_id := get_local_peer_id()
	if local_peer_id <= 0 or not is_multiplayer_active():
		return true
	if is_host():
		_set_peer_character(local_peer_id, resolved_character_id, confirmed)
		_broadcast_player_list_to_clients()
	elif connection_state >= ConnectionState.CONNECTED_IN_LOBBY:
		_rpc_set_player_character.rpc_id(
			get_host_peer_id(),
			String(resolved_character_id),
			confirmed
		)
	return true


func confirm_local_character() -> void:
	set_local_character_id(local_character_id, true)


func get_player_character_id(peer_id: int) -> StringName:
	if _session_members.has(peer_id):
		return StringName(
			(_session_members[peer_id] as Dictionary).get(
				"character_id",
				DEFAULT_CHARACTER_ID
			)
		)
	return StringName(connected_player_characters.get(peer_id, DEFAULT_CHARACTER_ID))


func get_player_character_map() -> Dictionary:
	return connected_player_characters.duplicate()


func is_player_character_confirmed(peer_id: int) -> bool:
	if _session_members.has(peer_id):
		return bool(
			(_session_members[peer_id] as Dictionary).get(
				"character_confirmed",
				false
			)
		)
	return bool(confirmed_character_peers.get(peer_id, false))


func are_all_player_characters_confirmed() -> bool:
	if connected_players.is_empty():
		return false
	for peer_id_variant in connected_players:
		var peer_id := int(peer_id_variant)
		if not connected_player_characters.has(peer_id):
			return false
		if not PlayerCharacterRegistry.is_valid_character_id(get_player_character_id(peer_id)):
			return false
		if not is_player_character_confirmed(peer_id):
			return false
	return true


func get_player_name_by_id(peer_id: int) -> String:
	if _session_members.has(peer_id):
		return str(
			(_session_members[peer_id] as Dictionary).get("player_name", "")
		)
	return connected_players.get(peer_id, "")


func get_local_peer_id() -> int:
	if not multiplayer.has_multiplayer_peer():
		return 0
	return multiplayer.get_unique_id()


func get_host_peer_id() -> int:
	if is_host():
		var local_id := get_local_peer_id()
		if local_id > 0:
			return local_id
	return host_peer_id if host_peer_id > 0 else 1


func is_peer_send_ready(peer_id: int) -> bool:
	if (
		peer_id <= 0
		or _disconnect_in_progress
		or _session_projection_failure_active
		or _pending_reconnect_loads.has(peer_id)
	):
		return false
	return is_peer_control_send_ready(peer_id)


## 顶层玩法会话显式登记唯一同步准备入口。重复登记同一 Callable 幂等；不同
## 会话争用说明场景生命周期已重叠，必须拒绝，不能猜测谁是当前所有者。
func register_reconnect_delivery_preparer(preparer: Callable) -> bool:
	if not preparer.is_valid():
		return false
	if _reconnect_delivery_preparer.is_valid():
		return _reconnect_delivery_preparer == preparer
	_reconnect_delivery_preparer = preparer
	return true


func unregister_reconnect_delivery_preparer(preparer: Callable) -> bool:
	if not preparer.is_valid():
		return false
	if not _reconnect_delivery_preparer.is_valid():
		_reconnect_delivery_preparer = Callable()
		return true
	if _reconnect_delivery_preparer != preparer:
		return false
	_reconnect_delivery_preparer = Callable()
	return true


## 只在唯一 prepare Callable 的同步调用栈内开放。它不是 gameplay ingress：
## 成员仍为 RECONNECTING，输入、事务与普通状态广播继续被 pending gate 拒绝。
func is_reconnect_delivery_preparing(peer_id: int) -> bool:
	if not is_host() or peer_id <= 0 or not is_session_member_reconnecting(peer_id):
		return false
	var pending := _pending_reconnect_loads.get(peer_id, {}) as Dictionary
	return (
		not pending.is_empty()
		and not bool(pending.get("timed_out", false))
		and int(pending.get("phase", -1))
		== int(ReconnectPendingPhase.PREPARING_DELIVERY)
		and bool(pending.get("delivery_preparation_active", false))
		and not _forced_final_departure_peer_ids.has(peer_id)
		and is_peer_control_send_ready(peer_id)
	)


## 终止/拒绝属于 transport 控制面，可以在 RECONNECTING 玩法门仍关闭时发送。
## 调用者不得用它发送 gameplay RPC；玩法必须继续走 is_peer_send_ready。
func is_peer_control_send_ready(peer_id: int) -> bool:
	if peer_id <= 0 or _disconnect_in_progress:
		return false
	if _enet_peer == null or not multiplayer.has_multiplayer_peer():
		return false
	if conn_mode == ConnMode.RELAY:
		return connected_players.has(peer_id) or multiplayer.get_peers().has(peer_id)
	var packet_peer := _enet_peer.get_peer(peer_id)
	if packet_peer == null:
		return false
	return packet_peer.get_state() == ENetPacketPeer.STATE_CONNECTED


func get_lan_ip_candidates() -> PackedStringArray:
	var result := PackedStringArray()
	for address in IP.get_local_addresses():
		if address == "127.0.0.1" or address == "::1":
			continue
		if address.contains(":"):
			continue
		if address.begins_with("169.254."):
			continue
		result.append(address)
	return result


func _connect_multiplayer_signals(include_client_signals: bool) -> void:
	_cleanup_multiplayer_signals()
	multiplayer.peer_connected.connect(_on_peer_connected)
	multiplayer.peer_disconnected.connect(_on_peer_disconnected)
	if include_client_signals:
		multiplayer.connected_to_server.connect(_on_connected_to_server)
		multiplayer.connection_failed.connect(_on_connection_failed)
		multiplayer.server_disconnected.connect(_on_server_disconnected)


func _cleanup_multiplayer_signals() -> void:
	if multiplayer.peer_connected.is_connected(_on_peer_connected):
		multiplayer.peer_connected.disconnect(_on_peer_connected)
	if multiplayer.peer_disconnected.is_connected(_on_peer_disconnected):
		multiplayer.peer_disconnected.disconnect(_on_peer_disconnected)
	if multiplayer.connected_to_server.is_connected(_on_connected_to_server):
		multiplayer.connected_to_server.disconnect(_on_connected_to_server)
	if multiplayer.connection_failed.is_connected(_on_connection_failed):
		multiplayer.connection_failed.disconnect(_on_connection_failed)
	if multiplayer.server_disconnected.is_connected(_on_server_disconnected):
		multiplayer.server_disconnected.disconnect(_on_server_disconnected)


func _on_peer_connected(peer_id: int) -> void:
	_debug_log("NetManager: Peer 已连接, id=%d" % peer_id)
	if is_host() and not _is_registration_open() and peer_id != get_host_peer_id():
		_late_registration_deadlines[peer_id] = (
			Time.get_ticks_msec() + LATE_REGISTRATION_TIMEOUT_MILLISECONDS
		)
		return
	if _relay_register_pending:
		_try_send_relay_registration()


func _reject_late_connected_peer(peer_id: int) -> void:
	if not is_host() or _is_registration_open() or peer_id <= 0:
		return
	if connected_players.has(peer_id):
		return
	if is_peer_send_ready(peer_id):
		_rpc_join_rejected.rpc_id(
			peer_id,
			"房间已经开始；未提供有效的断线重连身份。"
		)
	call_deferred("_disconnect_incompatible_peer", peer_id)


func _on_peer_disconnected(peer_id: int) -> void:
	var was_connected := connected_players.has(peer_id)
	var player_name: String = str(connected_players.get(peer_id, "Unknown"))
	var pending_reconnect := (
		_pending_reconnect_loads.get(peer_id, {}) as Dictionary
	)
	var reconnect_token := str(
		pending_reconnect.get(
			"token",
			_peer_reconnect_tokens.get(peer_id, "")
		)
	)
	var reconnect_old_peer_id := (
		peer_id
		if bool(pending_reconnect.get("identity_committed", false))
		else int(pending_reconnect.get("old_peer_id", peer_id))
	)
	var forced_final_departure := _forced_final_departure_peer_ids.has(peer_id)
	var transport_owns_session_identity := (
		was_connected
		or not pending_reconnect.is_empty()
		or _peer_reconnect_tokens.has(peer_id)
		or forced_final_departure
	)
	var membership_changed := false
	var pending_final_peer_id := 0
	var pending_final_reason := FINAL_DEPARTURE_DISCONNECTED
	if (
		is_host()
		and transport_owns_session_identity
		and _session_members.has(reconnect_old_peer_id)
	):
		var can_keep_grace := (
			connection_state == ConnectionState.IN_GAME
			and not forced_final_departure
			and _is_valid_reconnect_token(reconnect_token)
			and player_name != "Unknown"
		)
		if can_keep_grace:
			var member := _session_members[reconnect_old_peer_id] as Dictionary
			var expires_msec := int(member.get("grace_expires_msec", 0))
			if expires_msec <= 0:
				expires_msec = Time.get_ticks_msec() + RECONNECT_GRACE_MILLISECONDS
			if expires_msec > Time.get_ticks_msec():
				membership_changed = _suspend_session_member_for_grace(
					reconnect_old_peer_id,
					reconnect_token,
					expires_msec
				)
			else:
				pending_final_peer_id = reconnect_old_peer_id
				pending_final_reason = FINAL_DEPARTURE_GRACE_EXPIRED
		else:
			pending_final_peer_id = reconnect_old_peer_id
			pending_final_reason = (
				FINAL_DEPARTURE_PROJECTION_FAILED
				if forced_final_departure
				else FINAL_DEPARTURE_DISCONNECTED
			)
	connected_players.erase(peer_id)
	connected_player_characters.erase(peer_id)
	confirmed_character_peers.erase(peer_id)
	_peer_reconnect_tokens.erase(peer_id)
	_pending_reconnect_loads.erase(peer_id)
	_completed_reconnect_runtime_projections.erase(peer_id)
	_forced_final_departure_peer_ids.erase(peer_id)
	_late_registration_deadlines.erase(peer_id)
	_lobby_command_rate_buckets.erase(peer_id)
	if is_host() and connection_state == ConnectionState.LOADING_GAME:
		_expected_game_load_peers.erase(peer_id)
		_ready_game_load_peers.erase(peer_id)
		_emit_game_load_progress()
		_broadcast_game_load_progress()
		_try_finish_game_loading()
	if was_connected:
		player_left.emit(peer_id)
	# transport-left 必须先让运行时捕获/撤销 Player；final departure 随后才
	# 清理跨 transport 账本。反向顺序会让 player_left 在 final 后重新制造
	# 一份永远无人消费的重连 capture。
	if pending_final_peer_id > 0:
		membership_changed = (
			_finalize_session_member_departures(
				PackedInt32Array([pending_final_peer_id]),
				pending_final_reason
			) > 0
		)
	player_list_changed.emit()
	_emit_room_capacity_changed()
	if conn_mode == ConnMode.RELAY and net_role == NetRole.CLIENT and peer_id == get_host_peer_id():
		connection_failed.emit("主机已断开")
		disconnect_from_game()
		return
	if is_host() and (membership_changed or connection_state != ConnectionState.IN_GAME):
		call_deferred("_broadcast_player_list_to_clients")
	_debug_log("NetManager: Peer 已断开, id=%d (%s)" % [peer_id, player_name])


func _on_connected_to_server() -> void:
	_handle_connected_to_server()


func _handle_connected_to_server() -> void:
	if _connected_signal_handled:
		return
	_connected_signal_handled = true
	_clear_connection_attempt()

	if conn_mode == ConnMode.RELAY and net_role == NetRole.HOST:
		host_peer_id = get_local_peer_id()
		if host_peer_id <= 0:
			connection_failed.emit("Relay 未分配有效 Host Peer ID")
			disconnect_from_game()
			return
		set_multiplayer_authority(host_peer_id)
		connected_players.clear()
		connected_player_characters.clear()
		confirmed_character_peers.clear()
		connected_players[host_peer_id] = _sanitize_player_name(local_player_name)
		connected_player_characters[host_peer_id] = _sanitize_character_id(local_character_id)
		confirmed_character_peers[host_peer_id] = local_character_confirmed
		if not _register_active_session_member(
			host_peer_id,
			connected_players[host_peer_id],
			connected_player_characters[host_peer_id],
			local_character_confirmed,
			local_reconnect_token
		):
			connection_failed.emit("Host 成员世代已耗尽，请重启游戏后重新建房。")
			disconnect_from_game()
			return
		player_joined.emit(host_peer_id, connected_players[host_peer_id])
		player_list_changed.emit()
		_emit_room_capacity_changed()
		_set_connection_state(ConnectionState.HOSTING_LAN)
		_debug_log("NetManager: Host 已连接到 Relay, host_peer_id=%d" % host_peer_id)
		return

	connected_players.clear()
	if conn_mode == ConnMode.RELAY:
		_relay_register_pending = true
		_try_send_relay_registration()
		return
	_rpc_register_player.rpc_id(
		get_host_peer_id(),
		_get_safe_local_name(),
		String(local_character_id),
		local_character_confirmed,
		NetConstants.PROTOCOL_VERSION,
		local_reconnect_token
	)
	_set_connection_state(ConnectionState.CONNECTED_IN_LOBBY)
	_debug_log("NetManager: 已连接到 LAN Host")


func _on_connection_failed() -> void:
	var reason := "连接局域网主机失败"
	if conn_mode == ConnMode.RELAY:
		reason = "连接公网 Relay 失败"
	_fail_pending_connection(reason)


func _on_server_disconnected() -> void:
	var reason := "主机已断开"
	if conn_mode == ConnMode.RELAY:
		reason = "Relay 已断开"
	connection_failed.emit(reason)
	disconnect_from_game()


func _begin_connection_attempt(timeout_ms: int, target_description: String) -> void:
	_connect_started_msec = Time.get_ticks_msec()
	_connect_timeout_ms = timeout_ms
	_connect_target_description = target_description
	_connected_signal_handled = false


func _clear_connection_attempt() -> void:
	_connect_started_msec = 0
	_connect_timeout_ms = 0
	_connect_target_description = ""


func _poll_pending_connection() -> void:
	if connection_state != ConnectionState.CONNECTING_LAN:
		return
	if _enet_peer == null:
		return

	var status: int = int(_enet_peer.get_connection_status())
	if status == int(MultiplayerPeer.CONNECTION_CONNECTED):
		_handle_connected_to_server()
		return

	if _connect_timeout_ms <= 0:
		return

	var elapsed_msec := Time.get_ticks_msec() - _connect_started_msec
	if elapsed_msec < _connect_timeout_ms:
		return

	var target := _connect_target_description
	if target.is_empty():
		target = "目标服务器"
	_fail_pending_connection("连接%s超时，请检查服务器 UDP 端口和防火墙" % target)


func _fail_pending_connection(reason: String) -> void:
	connection_failed.emit(reason)
	disconnect_from_game()


func _try_send_relay_registration() -> void:
	if conn_mode != ConnMode.RELAY or net_role != NetRole.CLIENT:
		_relay_register_pending = false
		return
	if not multiplayer.has_multiplayer_peer():
		return
	var target_host_id := get_host_peer_id()
	if target_host_id <= 0 or not multiplayer.get_peers().has(target_host_id):
		return
	_relay_register_pending = false
	_rpc_register_player.rpc_id(
		target_host_id,
		_get_safe_local_name(),
		String(local_character_id),
		local_character_confirmed,
		NetConstants.PROTOCOL_VERSION,
		local_reconnect_token
	)
	_set_connection_state(ConnectionState.CONNECTED_IN_LOBBY)
	_debug_log("NetManager: 已连接到 Relay Host %d" % target_host_id)


@rpc("any_peer", "call_remote", "reliable", 0)
func _rpc_register_player(
	player_name: String,
	character_id: String = "weishidaier",
	character_confirmed: bool = true,
	protocol_version: int = -1,
	reconnect_token: String = ""
) -> void:
	_handle_player_registration(
		multiplayer.get_remote_sender_id(),
		player_name,
		character_id,
		character_confirmed,
		protocol_version,
		reconnect_token
	)


func _handle_player_registration(
	sender_id: int,
	player_name: String,
	character_id: String,
	character_confirmed: bool,
	protocol_version: int,
	reconnect_token: String
) -> bool:
	if not is_host() or sender_id <= 0:
		return false
	# Registration is immutable for one connected ENet identity. Reliable replay
	# or a malicious token/name rotation must not emit player_joined again or
	# amplify one packet into a full-room player-list broadcast.
	if connected_players.has(sender_id):
		return false
	if not _consume_lobby_command_admission(sender_id):
		return false
	if (
		player_name.length() > MAX_LOBBY_PLAYER_NAME_WIRE_LENGTH
		or character_id.length() > MAX_LOBBY_CHARACTER_ID_WIRE_LENGTH
		or reconnect_token.length() > RECONNECT_TOKEN_HEX_LENGTH
	):
		return false
	if not _is_protocol_version_compatible(protocol_version):
		push_warning(
			"NetManager: 拒绝 peer %d 的协议版本 %d，当前版本为 %d。"
			% [sender_id, protocol_version, NetConstants.PROTOCOL_VERSION]
		)
		_rpc_protocol_rejected.rpc_id(sender_id, NetConstants.PROTOCOL_VERSION)
		call_deferred("_disconnect_incompatible_peer", sender_id)
		return false
	var normalized_reconnect_token := reconnect_token.strip_edges().to_lower()
	if not _is_valid_reconnect_token(normalized_reconnect_token):
		_rpc_join_rejected.rpc_id(sender_id, "无效的联机重连身份。")
		call_deferred("_disconnect_incompatible_peer", sender_id)
		return false
	_late_registration_deadlines.erase(sender_id)
	if not _is_registration_open():
		if (
			connection_state == ConnectionState.IN_GAME
			and _begin_peer_reconnect(
				sender_id,
				player_name,
				normalized_reconnect_token
			)
		):
			return true
		_rpc_join_rejected.rpc_id(
			sender_id,
			"房间已经开始；该身份没有可恢复的断线席位。"
		)
		call_deferred("_disconnect_incompatible_peer", sender_id)
		return false
	if _peer_reconnect_tokens.values().has(normalized_reconnect_token):
		_rpc_join_rejected.rpc_id(sender_id, "该联机身份已在房间中使用。")
		call_deferred("_disconnect_incompatible_peer", sender_id)
		return false
	if _session_members.size() >= room_max_players:
		_rpc_join_rejected.rpc_id(
			sender_id,
			"房间已满（%d/%d）。" % [_session_members.size(), room_max_players]
		)
		call_deferred("_disconnect_incompatible_peer", sender_id)
		return false

	connected_players[sender_id] = _sanitize_player_name(player_name)
	var requested_character_id := StringName(character_id)
	var character_is_valid := PlayerCharacterRegistry.is_valid_character_id(requested_character_id)
	_set_peer_character(
		sender_id,
		requested_character_id if character_is_valid else DEFAULT_CHARACTER_ID,
		character_confirmed and character_is_valid
	)
	_peer_reconnect_tokens[sender_id] = normalized_reconnect_token
	if not _register_active_session_member(
		sender_id,
		connected_players[sender_id],
		get_player_character_id(sender_id),
		is_player_character_confirmed(sender_id),
		normalized_reconnect_token
	):
		connected_players.erase(sender_id)
		connected_player_characters.erase(sender_id)
		confirmed_character_peers.erase(sender_id)
		_peer_reconnect_tokens.erase(sender_id)
		return false
	player_joined.emit(sender_id, connected_players[sender_id])
	player_list_changed.emit()
	_emit_room_capacity_changed()
	_broadcast_player_list_to_clients()
	_debug_log("NetManager: 玩家注册, id=%d, name=%s" % [sender_id, connected_players[sender_id]])
	return true


func _begin_peer_reconnect(
	new_peer_id: int,
	requested_player_name: String,
	reconnect_token: String
) -> bool:
	if (
		new_peer_id <= 0
		or loading_session_id <= 0
		or not _disconnected_reconnect_slots.has(reconnect_token)
	):
		return false
	var old_peer_id := int(_disconnected_reconnect_slots[reconnect_token])
	if old_peer_id <= 0 or not _session_members.has(old_peer_id):
		_disconnected_reconnect_slots.erase(reconnect_token)
		return false
	# 当前 wire 身份仍以 peer_id 承载 old->new 迁移。目标地址必须在整个会话
	# 成员租约中空闲，而不只是 transport 字典空闲；否则两个 SUSPENDED 成员
	# 会短暂共享同一 peer_id，最终 roster 与身份 CAS 都无法收敛。
	if _session_members.has(new_peer_id):
		push_warning(
			"NetManager: 重连目标 peer_id=%d 已由会话成员占用。"
			% new_peer_id
		)
		return false
	var member := _session_members[old_peer_id] as Dictionary
	var expires_msec := int(member.get("grace_expires_msec", 0))
	if (
		int(member.get("state", -1)) != int(SessionMemberState.SUSPENDED_GRACE)
		or str(member.get("reconnect_token", "")) != reconnect_token
		or expires_msec <= Time.get_ticks_msec()
	):
		_disconnected_reconnect_slots.erase(reconnect_token)
		if expires_msec <= Time.get_ticks_msec():
			_finalize_session_member_departures(
				PackedInt32Array([old_peer_id]),
				FINAL_DEPARTURE_GRACE_EXPIRED
			)
			_broadcast_player_list_to_clients()
		return false
	if (
		_sanitize_player_name(requested_player_name)
		!= str(member.get("player_name", ""))
	):
		return false
	var player_name := str(member.get("player_name", "Player"))
	var character_id := _sanitize_character_id(
		StringName(member.get("character_id", DEFAULT_CHARACTER_ID))
	)
	if old_peer_id <= 0 or connected_players.has(new_peer_id):
		return false
	_disconnected_reconnect_slots.erase(reconnect_token)
	_completed_reconnect_runtime_projections.erase(new_peer_id)
	connected_players[new_peer_id] = player_name
	connected_player_characters[new_peer_id] = character_id
	confirmed_character_peers[new_peer_id] = bool(
		member.get("character_confirmed", true)
	)
	_peer_reconnect_tokens[new_peer_id] = reconnect_token
	_pending_reconnect_loads[new_peer_id] = {
		"old_peer_id": old_peer_id,
		"token": reconnect_token,
		"deadline_msec": (
			Time.get_ticks_msec() + RECONNECT_LOAD_TIMEOUT_MILLISECONDS
		),
		"grace_expires_msec": expires_msec,
		"phase": int(ReconnectPendingPhase.LOADING),
		"identity_committed": false,
		"membership_revision": 0,
		"runtime_projection_outcome": -1,
		"completion_signal_active": false,
		"delivery_preparation_active": false,
	}
	_rpc_sync_player_list.rpc_id(
		new_peer_id,
		_build_session_member_list_array(new_peer_id),
		get_host_peer_id(),
		int(current_game_mode),
		room_max_players,
		_session_membership_revision
	)
	_rpc_start_game.rpc_id(
		new_peer_id,
		int(current_game_mode),
		loading_session_id
	)
	player_list_changed.emit()
	_debug_log(
		"NetManager: 玩家开始重连, old_peer=%d new_peer=%d name=%s"
		% [old_peer_id, new_peer_id, player_name]
	)
	return true


func _is_protocol_version_compatible(protocol_version: int) -> bool:
	return protocol_version == NetConstants.PROTOCOL_VERSION


func _is_registration_open() -> bool:
	return connection_state < ConnectionState.LOADING_GAME


func _poll_reconnect_deadlines(now_msec: int = -1) -> void:
	if not is_host():
		return
	var resolved_now_msec := (
		Time.get_ticks_msec()
		if now_msec < 0
		else now_msec
	)
	for peer_id in _late_registration_deadlines.keys():
		if resolved_now_msec < int(_late_registration_deadlines[peer_id]):
			continue
		_late_registration_deadlines.erase(peer_id)
		_reject_late_connected_peer(int(peer_id))
	var expired_member_peer_ids := PackedInt32Array()
	for member_peer_id in get_session_member_peer_ids():
		var member := _session_members[member_peer_id] as Dictionary
		if (
			int(member.get("state", -1))
			== int(SessionMemberState.SUSPENDED_GRACE)
			and resolved_now_msec >= int(member.get("grace_expires_msec", 0))
		):
			expired_member_peer_ids.append(member_peer_id)
	for pending_peer_id_variant in _pending_reconnect_loads.keys():
		var pending_peer_id := int(pending_peer_id_variant)
		var pending := _pending_reconnect_loads[pending_peer_id] as Dictionary
		var retained_member_peer_id := (
			pending_peer_id
			if bool(pending.get("identity_committed", false))
			else int(pending.get("old_peer_id", 0))
		)
		if expired_member_peer_ids.has(retained_member_peer_id):
			_forced_final_departure_peer_ids[pending_peer_id] = true
			if is_inside_tree() and multiplayer.has_multiplayer_peer():
				_rpc_join_rejected.rpc_id(pending_peer_id, "断线重连宽限期已结束。")
			call_deferred("_disconnect_incompatible_peer", pending_peer_id)
	if not expired_member_peer_ids.is_empty():
		_finalize_session_member_departures(
			expired_member_peer_ids,
			FINAL_DEPARTURE_GRACE_EXPIRED
		)
		_broadcast_player_list_to_clients()
	for reconnect_token in _disconnected_reconnect_slots.keys():
		if not _session_members.has(int(_disconnected_reconnect_slots[reconnect_token])):
			_disconnected_reconnect_slots.erase(reconnect_token)
	for peer_id in _pending_reconnect_loads.keys():
		var pending := _pending_reconnect_loads[peer_id] as Dictionary
		if (
			bool(pending.get("timed_out", false))
			or resolved_now_msec < int(pending.get("deadline_msec", 0))
		):
			continue
		_expire_pending_reconnect(
			int(peer_id),
			int(pending.get("phase", -1)),
			int(pending.get("deadline_msec", 0))
		)


## completion/report 与逐帧 poll 共用同一个截止校验，避免“deadline 已过、
## poll 尚未运行”的节点顺序把超时身份先发布为 ACTIVE。
func _is_live_pending_reconnect_phase(
	peer_id: int,
	expected_phase: ReconnectPendingPhase,
	now_msec: int = -1
) -> bool:
	var pending := _pending_reconnect_loads.get(peer_id, {}) as Dictionary
	if (
		pending.is_empty()
		or bool(pending.get("timed_out", false))
		or int(pending.get("phase", -1)) != int(expected_phase)
		or _forced_final_departure_peer_ids.has(peer_id)
	):
		return false
	var resolved_now_msec := (
		Time.get_ticks_msec()
		if now_msec < 0
		else now_msec
	)
	if resolved_now_msec < int(pending.get("deadline_msec", 0)):
		return true
	_expire_pending_reconnect(
		peer_id,
		int(expected_phase),
		int(pending.get("deadline_msec", 0))
	)
	return false


## deadline、phase 与 pending 表一起做比较并交换；poll 持有的旧阶段快照不得
## 把刚进入下一阶段、获得新截止时间的事务误标成超时。
func _expire_pending_reconnect(
	peer_id: int,
	expected_phase: int,
	expected_deadline_msec: int
) -> bool:
	var pending := _pending_reconnect_loads.get(peer_id, {}) as Dictionary
	if (
		peer_id <= 0
		or pending.is_empty()
		or bool(pending.get("timed_out", false))
		or int(pending.get("phase", -1)) != expected_phase
		or int(pending.get("deadline_msec", 0)) != expected_deadline_msec
	):
		return false
	# 保留身份记录直到 transport 真正离开，但先原子关闭 completion 资格。
	pending["timed_out"] = true
	pending["delivery_preparation_active"] = false
	_pending_reconnect_loads[peer_id] = pending
	if is_peer_control_send_ready(peer_id):
		var timeout_reason := "断线重连加载超时，请重新连接。"
		match int(pending.get("phase", -1)):
			int(ReconnectPendingPhase.PROJECTING):
				timeout_reason = "重连玩家投影超时，请重新连接。"
			int(ReconnectPendingPhase.PREPARING_DELIVERY):
				timeout_reason = "重连首帧快照准备超时，请重新连接。"
		_rpc_join_rejected.rpc_id(peer_id, timeout_reason)
	call_deferred("_disconnect_incompatible_peer", peer_id)
	return true


func _clear_reconnect_session_state() -> void:
	_peer_reconnect_tokens.clear()
	_disconnected_reconnect_slots.clear()
	_pending_reconnect_loads.clear()
	_completed_reconnect_runtime_projections.clear()
	_forced_final_departure_peer_ids.clear()
	_late_registration_deadlines.clear()
	_lobby_command_rate_buckets.clear()


func _consume_lobby_command_admission(
	peer_id: int,
	now_seconds: float = -1.0
) -> bool:
	if peer_id <= 0:
		return false
	var now := (
		float(Time.get_ticks_msec()) / 1000.0
		if now_seconds < 0.0
		else now_seconds
	)
	var bucket: Dictionary
	if _lobby_command_rate_buckets.has(peer_id):
		bucket = _lobby_command_rate_buckets[peer_id] as Dictionary
	else:
		bucket = {
			"tokens": LOBBY_COMMAND_RATE_BURST,
			"last_time": now,
		}
		_lobby_command_rate_buckets[peer_id] = bucket
	var tokens := float(bucket.get("tokens", LOBBY_COMMAND_RATE_BURST))
	var last_time := float(bucket.get("last_time", now))
	tokens = minf(
		LOBBY_COMMAND_RATE_BURST,
		tokens + maxf(now - last_time, 0.0) * LOBBY_COMMAND_RATE_PER_SECOND
	)
	var accepted := tokens >= 1.0
	if accepted:
		tokens -= 1.0
	bucket["tokens"] = tokens
	bucket["last_time"] = now
	return accepted


func _disconnect_incompatible_peer(peer_id: int) -> void:
	if peer_id <= 0:
		return
	await get_tree().create_timer(0.1).timeout
	if conn_mode == ConnMode.RELAY:
		_request_relay_peer_disconnect(peer_id)
		return
	if _enet_peer == null:
		return
	var packet_peer := _enet_peer.get_peer(peer_id)
	if packet_peer != null:
		packet_peer.peer_disconnect()


## Relay 客户端的 ENet transport 只直接连接 server peer 1，因此 Host 无法
## 取得 target 的 ENetPacketPeer。由 RelayServer 验证当前 sender 就是登记
## Host 后，在服务端断开目标；直连模式仍走上方原生 peer_disconnect。
func _request_relay_peer_disconnect(peer_id: int) -> bool:
	if (
		not is_host()
		or conn_mode != ConnMode.RELAY
		or peer_id <= 0
		or peer_id == get_host_peer_id()
		or not is_peer_control_send_ready(peer_id)
	):
		return false
	_rpc_relay_kick_peer.rpc_id(RELAY_SERVICE_PEER_ID, peer_id)
	return true


## 该方法只由 Relay 服务端的同路径 stub 执行。普通游戏实例绝不处理来自
## 逻辑客户端的踢人请求；Host 仅通过 _request_relay_peer_disconnect 发往 peer 1。
@rpc("any_peer", "call_remote", "reliable", 0)
func _rpc_relay_kick_peer(target_peer_id: int) -> void:
	pass


@rpc("authority", "call_remote", "reliable", 0)
func _rpc_protocol_rejected(expected_protocol_version: int) -> void:
	if is_host():
		return
	connection_failed.emit(
		"联机协议版本不匹配：需要版本 %d，请使用相同构建。"
		% expected_protocol_version
	)
	disconnect_from_game()


@rpc("authority", "call_remote", "reliable", 0)
func _rpc_join_rejected(reason: String) -> void:
	if is_host():
		return
	var resolved_reason := reason.strip_edges()
	if resolved_reason.is_empty():
		resolved_reason = "房间已经开始，无法加入。"
	connection_failed.emit(resolved_reason)
	disconnect_from_game()


@rpc("any_peer", "call_remote", "reliable", 0)
func _rpc_set_player_character(character_id: String, confirmed: bool) -> void:
	_handle_player_character_request(
		multiplayer.get_remote_sender_id(),
		character_id,
		confirmed
	)


func _handle_player_character_request(
	sender_id: int,
	character_id: String,
	confirmed: bool
) -> bool:
	if (
		not is_host()
		or connection_state >= ConnectionState.LOADING_GAME
		or sender_id <= 0
		or not connected_players.has(sender_id)
		or not _consume_lobby_command_admission(sender_id)
		or character_id.length() > MAX_LOBBY_CHARACTER_ID_WIRE_LENGTH
	):
		return false
	var requested_id := StringName(character_id)
	if not PlayerCharacterRegistry.is_valid_character_id(requested_id):
		return false
	if (
		StringName(connected_player_characters.get(sender_id, DEFAULT_CHARACTER_ID))
		== requested_id
		and bool(confirmed_character_peers.get(sender_id, false)) == confirmed
	):
		return false
	_set_peer_character(sender_id, requested_id, confirmed)
	_broadcast_player_list_to_clients()
	return true


@rpc("authority", "call_remote", "reliable", 0)
func _rpc_sync_player_list(
	player_list: Array,
	new_host_peer_id: int = 0,
	game_mode: int = 0,
	max_players: int = 8,
	session_membership_revision: int = -1
) -> void:
	if is_host():
		return
	var sender_id := multiplayer.get_remote_sender_id()
	var resolved_host_id := new_host_peer_id
	if resolved_host_id <= 0:
		resolved_host_id = sender_id
	if resolved_host_id <= 0:
		resolved_host_id = host_peer_id
	if sender_id > 0 and resolved_host_id > 0 and sender_id != resolved_host_id:
		return
	var prepared_members := _prepare_session_member_list(player_list)
	if prepared_members.is_empty() or not prepared_members.has(resolved_host_id):
		return
	if (
		int((prepared_members[resolved_host_id] as Dictionary).get("state", -1))
		!= int(SessionMemberState.ACTIVE)
	):
		return
	if not _is_known_game_mode(game_mode):
		return
	if not _is_valid_room_max_players(max_players):
		return
	if session_membership_revision < _session_membership_revision:
		return
	if (
		session_membership_revision > _session_membership_revision
		and not _apply_inferred_reconnected_identities_from_roster(
			prepared_members,
			session_membership_revision
		)
	):
		push_warning(
			"NetManager: 无法从成员世代原子恢复缺失的重连身份，拒绝 roster revision=%d。"
			% session_membership_revision
		)
		return
	if session_membership_revision < _session_membership_revision:
		return
	if session_membership_revision == _session_membership_revision:
		if not _session_member_sets_match(_session_members, prepared_members):
			push_warning(
				"NetManager: 拒绝同 revision 不同内容的会话成员表 revision=%d。"
				% session_membership_revision
			)
			return
		# membership revision 只保护成员 CAS；模式与容量是同一 CH0 信封中的
		# 独立房间上下文。成员未变时仍须应用它们，否则 set_host_game_mode()
		# 的合法广播会被误判为整包幂等。
		if (
			host_peer_id == resolved_host_id
			and int(current_game_mode) == game_mode
			and room_max_players == max_players
		):
			return
		host_peer_id = resolved_host_id
		set_multiplayer_authority(host_peer_id)
		_set_current_game_mode(game_mode as GameMode)
		room_max_players = max_players
		player_list_changed.emit()
		_emit_room_capacity_changed()
		return
	var previous_players := connected_players.duplicate()
	var previous_characters := connected_player_characters.duplicate()
	var previous_confirmations := confirmed_character_peers.duplicate()
	var previous_session_members := _session_members.duplicate(true)
	var synced_players: Dictionary = {}
	var synced_characters: Dictionary = {}
	var synced_confirmations: Dictionary = {}
	for raw_peer_id in prepared_members.keys():
		var peer_id := int(raw_peer_id)
		var member := prepared_members[peer_id] as Dictionary
		if int(member.get("state", -1)) != int(SessionMemberState.ACTIVE):
			continue
		synced_players[peer_id] = str(member.get("player_name", "Player"))
		synced_characters[peer_id] = StringName(
			member.get("character_id", DEFAULT_CHARACTER_ID)
		)
		synced_confirmations[peer_id] = bool(
			member.get("character_confirmed", false)
		)
	host_peer_id = resolved_host_id
	set_multiplayer_authority(host_peer_id)
	_set_current_game_mode(game_mode as GameMode)
	room_max_players = max_players
	connected_players = synced_players
	connected_player_characters = synced_characters
	confirmed_character_peers = synced_confirmations
	_session_members = prepared_members
	_session_membership_revision = session_membership_revision
	var local_peer_id := get_local_peer_id()
	if local_peer_id > 0 and connected_player_characters.has(local_peer_id):
		local_character_id = get_player_character_id(local_peer_id)
		local_character_confirmed = is_player_character_confirmed(local_peer_id)
	for previous_peer_id_variant in previous_players:
		var previous_peer_id := int(previous_peer_id_variant)
		if not connected_players.has(previous_peer_id):
			player_left.emit(previous_peer_id)
	for peer_id_variant in connected_players:
		var peer_id := int(peer_id_variant)
		var player_name := str(connected_players[peer_id])
		if (
			not previous_players.has(peer_id)
			or str(previous_players.get(peer_id, "")) != player_name
		):
			player_joined.emit(peer_id, player_name)
		var character_id := get_player_character_id(peer_id)
		var character_confirmed := is_player_character_confirmed(peer_id)
		if (
			not previous_characters.has(peer_id)
			or StringName(previous_characters.get(peer_id, DEFAULT_CHARACTER_ID)) != character_id
			or bool(previous_confirmations.get(peer_id, false)) != character_confirmed
		):
			player_character_changed.emit(peer_id, character_id, character_confirmed)
	_emit_session_membership_changed()
	for previous_peer_id_variant in previous_session_members.keys():
		var previous_peer_id := int(previous_peer_id_variant)
		if _session_members.has(previous_peer_id):
			continue
		var previous_member := previous_session_members[previous_peer_id] as Dictionary
		var reason := (
			FINAL_DEPARTURE_GRACE_EXPIRED
			if int(previous_member.get("state", -1))
			== int(SessionMemberState.SUSPENDED_GRACE)
			else FINAL_DEPARTURE_DISCONNECTED
		)
		session_member_final_departed.emit(
			previous_peer_id,
			_session_membership_revision,
			reason
		)
	player_list_changed.emit()
	_emit_room_capacity_changed()


@rpc("authority", "call_remote", "reliable", 0)
func _rpc_start_game(game_mode: int = 0, session_id: int = 0) -> void:
	if multiplayer.get_remote_sender_id() != get_host_peer_id():
		return
	_apply_authoritative_start_game(game_mode, session_id)


## wire 解码与运行准入在这里汇合：roster 可记录隐藏模式，但 start 必须
## 匹配本机显式受众。拒绝时立即断开，避免 Client 永久停在大厅等待加载。
func _apply_authoritative_start_game(game_mode: int, session_id: int) -> bool:
	if session_id <= 0 or session_id > NetConstants.MAX_GAME_SESSION_INCARNATION:
		return false
	if not _is_known_game_mode(game_mode):
		_reject_authoritative_runtime_mode(game_mode, false)
		return false
	if not is_runtime_game_mode_admitted(game_mode):
		_reject_authoritative_runtime_mode(game_mode, true)
		return false
	if connection_state >= ConnectionState.LOADING_GAME:
		# Reliable delivery should only apply this transition once. Ignore a stale or
		# duplicated start packet instead of resetting already reported readiness.
		return false
	_set_current_game_mode(game_mode as GameMode)
	host_game_ready = false
	loading_session_id = session_id
	_last_game_session_incarnation = maxi(
		_last_game_session_incarnation,
		session_id
	)
	_expected_game_load_peers.clear()
	_ready_game_load_peers.clear()
	for peer_id_variant in connected_players:
		_expected_game_load_peers[int(peer_id_variant)] = true
	_set_connection_state(ConnectionState.LOADING_GAME)
	_emit_game_load_progress()
	return true


func _reject_authoritative_runtime_mode(game_mode: int, is_known: bool) -> void:
	var reason := "Host 请求启动未知游戏模式 %d，连接已关闭。" % game_mode
	if is_known:
		var definition := GameModeCatalog.get_definition(game_mode)
		var wire_key := (
			String(definition.wire_key)
			if definition != null
			else "unknown"
		)
		reason = (
			"Host 请求启动当前构建未获准运行的模式 %s（%d），连接已关闭。"
			% [wire_key, game_mode]
		)
	push_warning("NetManager: %s" % reason)
	connection_failed.emit(reason)
	disconnect_from_game()


@rpc("authority", "call_remote", "reliable", 0)
func _rpc_host_game_ready(session_id: int = 0) -> void:
	if multiplayer.get_remote_sender_id() != get_host_peer_id():
		return
	if session_id != loading_session_id:
		return
	host_game_ready = true
	if connection_state >= ConnectionState.LOADING_GAME:
		_set_connection_state(ConnectionState.IN_GAME)


@rpc("any_peer", "call_remote", "reliable", 0)
func _rpc_report_game_loaded(session_id: int) -> void:
	_handle_report_game_loaded(
		multiplayer.get_remote_sender_id(),
		session_id
	)


func _handle_report_game_loaded(
	sender_id: int,
	session_id: int,
	now_msec: int = -1
) -> void:
	if not is_host() or sender_id <= 0:
		return
	if _can_complete_pending_reconnect_load(sender_id, session_id, now_msec):
		_complete_peer_reconnect(sender_id)
		return
	if connection_state != ConnectionState.LOADING_GAME:
		return
	_mark_peer_game_loaded(sender_id, session_id)


func _can_complete_pending_reconnect_load(
	peer_id: int,
	session_id: int,
	now_msec: int = -1
) -> bool:
	if (
		peer_id <= 0
		or connection_state != ConnectionState.IN_GAME
		or session_id != loading_session_id
		or not _pending_reconnect_loads.has(peer_id)
	):
		return false
	var pending := _pending_reconnect_loads[peer_id] as Dictionary
	var resolved_now_msec := (
		Time.get_ticks_msec()
		if now_msec < 0
		else now_msec
	)
	if int(pending.get("grace_expires_msec", 0)) <= resolved_now_msec:
		_expire_pending_reconnect(
			peer_id,
			int(pending.get("phase", -1)),
			int(pending.get("deadline_msec", 0))
		)
		return false
	return _is_live_pending_reconnect_phase(
		peer_id,
		ReconnectPendingPhase.LOADING,
		resolved_now_msec
	)


func _complete_peer_reconnect(new_peer_id: int) -> void:
	var pending := _pending_reconnect_loads.get(new_peer_id, {}) as Dictionary
	if pending.is_empty():
		return
	var old_peer_id := int(pending.get("old_peer_id", 0))
	if old_peer_id <= 0 or not connected_players.has(new_peer_id):
		return
	if bool(pending.get("identity_committed", false)):
		_try_publish_completed_peer_reconnect(new_peer_id)
		return
	if not _remap_session_member_identity(old_peer_id, new_peer_id, false):
		return
	var committed_membership_revision := _session_membership_revision
	var player_name := str(connected_players[new_peer_id])
	var character_id := get_player_character_id(new_peer_id)
	var projection_started_msec := Time.get_ticks_msec()
	var projection_deadline_msec := (
		projection_started_msec + RECONNECT_PROJECTION_TIMEOUT_MILLISECONDS
	)
	var grace_expires_msec := int(pending.get("grace_expires_msec", 0))
	if grace_expires_msec > 0:
		projection_deadline_msec = mini(
			projection_deadline_msec,
			grace_expires_msec
		)
	pending["phase"] = int(ReconnectPendingPhase.PROJECTING)
	pending["deadline_msec"] = projection_deadline_msec
	pending["identity_committed"] = true
	pending["membership_revision"] = committed_membership_revision
	pending["runtime_projection_outcome"] = -1
	pending["completion_signal_active"] = true
	pending["identity_announced"] = false
	pending["delivery_preparation_active"] = false
	_pending_reconnect_loads[new_peer_id] = pending
	player_reconnected.emit(
		old_peer_id,
		new_peer_id,
		player_name,
		character_id,
		committed_membership_revision
	)
	# signal 返回只说明各运行时已看见身份事务；Player 可能仍在有界创建重试。
	# 只有显式 RESTORED/SUSPENDED 才发布 ACTIVE roster 与 host-ready。
	if (
		_forced_final_departure_peer_ids.has(new_peer_id)
		or not _session_members.has(new_peer_id)
	):
		return
	pending = _pending_reconnect_loads.get(new_peer_id, {}) as Dictionary
	if pending.is_empty():
		return
	pending["completion_signal_active"] = false
	_pending_reconnect_loads[new_peer_id] = pending
	if not _announce_reconnected_identity(new_peer_id):
		terminate_for_runtime_projection_failure(
			new_peer_id,
			"重连身份提交后无法按同一成员 revision 发布。"
		)
		return
	_try_publish_completed_peer_reconnect(new_peer_id)


## 先把 old->new 身份以 RECONNECTING 状态发布给既有观察者。它拥有独立的
## membership revision，因此投影等待期间的其他成员变化仍可继续有序收敛。
func _announce_reconnected_identity(new_peer_id: int) -> bool:
	var pending := _pending_reconnect_loads.get(new_peer_id, {}) as Dictionary
	if (
		pending.is_empty()
		or not bool(pending.get("identity_committed", false))
		or bool(pending.get("completion_signal_active", false))
	):
		return false
	if bool(pending.get("identity_announced", false)):
		return true
	var old_peer_id := int(pending.get("old_peer_id", 0))
	var committed_membership_revision := int(
		pending.get("membership_revision", 0)
	)
	if (
		old_peer_id <= 0
		or committed_membership_revision != _session_membership_revision
		or not is_session_member_reconnecting(new_peer_id)
	):
		return false
	pending["identity_announced"] = true
	_pending_reconnect_loads[new_peer_id] = pending
	_emit_session_membership_changed()
	var player_name := str(connected_players.get(new_peer_id, ""))
	var character_id := get_player_character_id(new_peer_id)
	var host_id := get_host_peer_id()
	for peer_id_variant in connected_players:
		var peer_id := int(peer_id_variant)
		if (
			peer_id <= 0
			or peer_id == host_id
			or peer_id == new_peer_id
			or not is_peer_send_ready(peer_id)
		):
			continue
		# 重连者本人由 setup 直接持有 new identity；只有观察过 old 的既有
		# 客户端需要消费显式身份事务。
		_rpc_player_reconnected.rpc_id(
			peer_id,
			old_peer_id,
			new_peer_id,
			player_name,
			String(character_id),
			committed_membership_revision
		)
	_broadcast_player_list_to_clients()
	player_list_changed.emit()
	return true


## 游戏运行时在 Player 已恢复、或本轮明确安全降级为旁观后回报。报告可在
## player_reconnected 信号栈内或稍后的有界重试中到达，重复同值严格幂等。
func report_reconnected_runtime_projection(
	old_peer_id: int,
	new_peer_id: int,
	outcome: MultiplayerReconnectTypesScript.RuntimeProjectionOutcome
) -> bool:
	if (
		not is_host()
		or old_peer_id <= 0
		or new_peer_id <= 0
		or old_peer_id == new_peer_id
		or not MultiplayerReconnectTypesScript.is_valid_runtime_projection_outcome(outcome)
	):
		return false
	var pending := _pending_reconnect_loads.get(new_peer_id, {}) as Dictionary
	if pending.is_empty():
		var completed := (
			_completed_reconnect_runtime_projections.get(new_peer_id, {})
			as Dictionary
		)
		if completed.is_empty() or int(completed.get("old_peer_id", 0)) != old_peer_id:
			return false
		if int(completed.get("outcome", -1)) == int(outcome):
			return is_session_member_active(new_peer_id)
		terminate_for_runtime_projection_failure(
			new_peer_id,
			"已完成的重连运行时收到了冲突的投影终态。"
		)
		return false
	if (
		int(pending.get("old_peer_id", 0)) != old_peer_id
		or not bool(pending.get("identity_committed", false))
	):
		return false
	var pending_phase := int(pending.get("phase", -1))
	if pending_phase not in [
		int(ReconnectPendingPhase.PROJECTING),
		int(ReconnectPendingPhase.PREPARING_DELIVERY),
	]:
		return false
	if not _is_live_pending_reconnect_phase(
		new_peer_id,
		pending_phase as ReconnectPendingPhase
	):
		return false
	var current_outcome := int(pending.get("runtime_projection_outcome", -1))
	if current_outcome >= 0 and current_outcome != int(outcome):
		terminate_for_runtime_projection_failure(
			new_peer_id,
			"重连运行时对玩家投影终态给出了互相冲突的报告。"
		)
		return false
	if current_outcome < 0:
		if pending_phase != int(ReconnectPendingPhase.PROJECTING):
			return false
		pending["runtime_projection_outcome"] = int(outcome)
		_pending_reconnect_loads[new_peer_id] = pending
	if outcome == MultiplayerReconnectTypesScript.RuntimeProjectionOutcome.FAILED:
		terminate_for_runtime_projection_failure(
			new_peer_id,
			"重连玩家运行时投影明确失败。"
		)
		return true
	if (
		pending_phase == int(ReconnectPendingPhase.PROJECTING)
		and not bool(pending.get("completion_signal_active", false))
	):
		_try_publish_completed_peer_reconnect(new_peer_id)
	return true


func _try_publish_completed_peer_reconnect(new_peer_id: int) -> bool:
	if not _is_live_pending_reconnect_phase(
		new_peer_id,
		ReconnectPendingPhase.PROJECTING
	):
		return false
	var pending := _pending_reconnect_loads.get(new_peer_id, {}) as Dictionary
	if (
		pending.is_empty()
		or not bool(pending.get("identity_committed", false))
		or bool(pending.get("completion_signal_active", false))
		or not _session_members.has(new_peer_id)
	):
		return false
	var outcome := int(pending.get("runtime_projection_outcome", -1))
	if outcome not in [
		MultiplayerReconnectTypesScript.RuntimeProjectionOutcome.RESTORED,
		MultiplayerReconnectTypesScript.RuntimeProjectionOutcome.SUSPENDED,
	]:
		return false
	if (
		not is_session_member_reconnecting(new_peer_id)
		or not connected_players.has(new_peer_id)
	):
		terminate_for_runtime_projection_failure(
			new_peer_id,
			"重连 ready 前会话成员 revision 已漂移。"
		)
		return false
	var old_peer_id := int(pending.get("old_peer_id", 0))
	var player_name := str(connected_players[new_peer_id])
	var preparation_started_msec := Time.get_ticks_msec()
	var preparation_deadline_msec := (
		preparation_started_msec
		+ RECONNECT_DELIVERY_PREPARATION_TIMEOUT_MILLISECONDS
	)
	var grace_expires_msec := int(pending.get("grace_expires_msec", 0))
	if grace_expires_msec > 0:
		preparation_deadline_msec = mini(
			preparation_deadline_msec,
			grace_expires_msec
		)
	pending["phase"] = int(ReconnectPendingPhase.PREPARING_DELIVERY)
	pending["deadline_msec"] = preparation_deadline_msec
	pending["delivery_preparation_active"] = true
	_pending_reconnect_loads[new_peer_id] = pending
	if not _is_live_pending_reconnect_phase(
		new_peer_id,
		ReconnectPendingPhase.PREPARING_DELIVERY,
		preparation_started_msec
	):
		return false
	var preparation_succeeded := _run_reconnect_delivery_preparation(
		old_peer_id,
		new_peer_id,
		outcome as MultiplayerReconnectTypesScript.RuntimeProjectionOutcome,
		_session_membership_revision
	)
	pending = _pending_reconnect_loads.get(new_peer_id, {}) as Dictionary
	var preparation_lease_returned_active := (
		not pending.is_empty()
		and bool(pending.get("delivery_preparation_active", false))
	)
	# Callable 一返回就关闭专用发送租约；失败清理与后续 ACTIVE 提交都不得
	# 继续借用 PREPARING_DELIVERY 的控制面能力。
	if not pending.is_empty():
		pending["delivery_preparation_active"] = false
		_pending_reconnect_loads[new_peer_id] = pending
	if (
		not preparation_succeeded
		or not preparation_lease_returned_active
		or pending.is_empty()
		or _forced_final_departure_peer_ids.has(new_peer_id)
	):
		if not _forced_final_departure_peer_ids.has(new_peer_id):
			terminate_for_runtime_projection_failure(
				new_peer_id,
				"重连首帧快照准备失败。"
			)
		return false
	if not _is_live_pending_reconnect_phase(
		new_peer_id,
		ReconnectPendingPhase.PREPARING_DELIVERY
	):
		return false
	pending = _pending_reconnect_loads.get(new_peer_id, {}) as Dictionary
	if (
		pending.is_empty()
		or bool(pending.get("delivery_preparation_active", false))
		or int(pending.get("runtime_projection_outcome", -1)) != outcome
		or not is_session_member_reconnecting(new_peer_id)
	):
		terminate_for_runtime_projection_failure(
			new_peer_id,
			"重连首帧准备返回后事务状态已漂移。"
		)
		return false
	# ENet RPC 入队没有可恢复的返回值，因此先在尚可回滚的 RECONNECTING
	# 阶段做 transport 预检；通过后，提交路径只执行不可失败的本地写入与通知。
	if not _can_send_reconnect_game_ready_to_peer(new_peer_id):
		terminate_for_runtime_projection_failure(
			new_peer_id,
			"重连首帧已准备，但 Host transport 无法发送 ready。"
		)
		return false
	if not _activate_reconnecting_session_member(new_peer_id):
		terminate_for_runtime_projection_failure(
			new_peer_id,
			"重连首帧已准备，但成员无法从 RECONNECTING 激活。"
		)
		return false
	_completed_reconnect_runtime_projections[new_peer_id] = {
		"old_peer_id": old_peer_id,
		"outcome": outcome,
	}
	_pending_reconnect_loads.erase(new_peer_id)
	_broadcast_player_list_to_clients()
	_send_reconnect_game_ready_to_peer(new_peer_id)
	player_reconnect_ready.emit(
		old_peer_id,
		new_peer_id,
		outcome as MultiplayerReconnectTypesScript.RuntimeProjectionOutcome,
		_session_membership_revision
	)
	player_list_changed.emit()
	_debug_log(
		"NetManager: 玩家重连完成, old_peer=%d new_peer=%d name=%s"
		% [old_peer_id, new_peer_id, player_name]
	)
	return true


func _run_reconnect_delivery_preparation(
	old_peer_id: int,
	new_peer_id: int,
	outcome: MultiplayerReconnectTypesScript.RuntimeProjectionOutcome,
	membership_revision: int
) -> bool:
	if not _reconnect_delivery_preparer.is_valid():
		push_error("NetManager: 当前玩法会话没有登记重连首帧准备入口。")
		return false
	var result: Variant = _reconnect_delivery_preparer.call(
		old_peer_id,
		new_peer_id,
		outcome,
		membership_revision
	)
	if typeof(result) != TYPE_BOOL:
		push_error("NetManager: 重连首帧准备入口必须同步返回 bool。")
		return false
	return bool(result)


## 可覆盖预检让状态机测试无需伪造 ENet。正式路径只检查控制面 transport；
## gameplay send gate 仍因 pending 存在而关闭。
func _can_send_reconnect_game_ready_to_peer(peer_id: int) -> bool:
	return is_peer_control_send_ready(peer_id)


## 调用前已经完成 transport 预检与 ACTIVE 提交；RPC 排队本身没有失败回执，
## 因而这里只做不可失败通知，不能再触发成员回滚。
func _send_reconnect_game_ready_to_peer(peer_id: int) -> void:
	_rpc_host_game_ready.rpc_id(peer_id, loading_session_id)


@rpc("authority", "call_remote", "reliable", 0)
func _rpc_player_reconnected(
	old_peer_id: int,
	new_peer_id: int,
	player_name: String,
	character_id: String,
	membership_revision: int
) -> void:
	if (
		is_host()
		or multiplayer.get_remote_sender_id() != get_host_peer_id()
		or old_peer_id <= 0
		or new_peer_id <= 0
		or new_peer_id == get_host_peer_id()
	):
		return
	_apply_player_reconnected_identity(
		old_peer_id,
		new_peer_id,
		player_name,
		StringName(character_id),
		membership_revision
	)


func _apply_player_reconnected_identity(
	old_peer_id: int,
	new_peer_id: int,
	player_name: String,
	character_id: StringName,
	membership_revision: int
) -> bool:
	if (
		old_peer_id <= 0
		or new_peer_id <= 0
		or old_peer_id == new_peer_id
		or new_peer_id == get_host_peer_id()
		or membership_revision <= 0
		or not PlayerCharacterRegistry.is_valid_character_id(character_id)
	):
		return false
	var resolved_player_name := _sanitize_player_name(player_name)
	var has_old_member := _session_members.has(old_peer_id)
	var has_new_member := _session_members.has(new_peer_id)
	if not has_old_member and has_new_member:
		# 可靠 RPC 重放只在所有字段均已收敛时幂等；任何差异都交给随后
		# 的权威 roster 修复，绝不能覆盖一个已经存在的 new identity。
		var current_member := _session_members[new_peer_id] as Dictionary
		return (
			_session_membership_revision == membership_revision
			and
			int(current_member.get("state", -1))
			== int(SessionMemberState.RECONNECTING)
			and str(current_member.get("player_name", "")) == resolved_player_name
			and StringName(current_member.get("character_id", DEFAULT_CHARACTER_ID))
			== character_id
			and bool(current_member.get("character_confirmed", false))
			and not connected_players.has(new_peer_id)
			and not connected_player_characters.has(new_peer_id)
			and not confirmed_character_peers.has(new_peer_id)
		)
	if not has_old_member or has_new_member:
		push_warning(
			"NetManager: 拒绝冲突的重连身份 %d -> %d，等待权威 roster 修复。"
			% [old_peer_id, new_peer_id]
		)
		return false
	# reconnect RPC 与随后 roster 共用 CH0；显式 revision 使会话身份与
	# RunState 账本使用同一个 CAS 边界，而不是让客户端猜测“当前值 + 1”。
	if membership_revision != _session_membership_revision + 1:
		push_warning(
			"NetManager: 重连身份 %d -> %d 的成员 revision 不连续：%d -> %d。"
			% [
				old_peer_id,
				new_peer_id,
				_session_membership_revision,
				membership_revision,
			]
		)
		return false
	var old_member := _session_members[old_peer_id] as Dictionary
	if (
		int(old_member.get("state", -1))
		!= int(SessionMemberState.SUSPENDED_GRACE)
		or str(old_member.get("player_name", "")) != resolved_player_name
		or StringName(old_member.get("character_id", DEFAULT_CHARACTER_ID))
		!= character_id
		or not bool(old_member.get("character_confirmed", false))
		or connected_players.has(new_peer_id)
		or connected_player_characters.has(new_peer_id)
		or confirmed_character_peers.has(new_peer_id)
	):
		push_warning(
			"NetManager: 重连身份 %d -> %d 的认证字段冲突，整包拒绝。"
			% [old_peer_id, new_peer_id]
		)
		return false
	if (
		connected_players.has(old_peer_id)
		and (
			str(connected_players[old_peer_id]) != resolved_player_name
			or StringName(
				connected_player_characters.get(
					old_peer_id,
					DEFAULT_CHARACTER_ID
				)
			) != character_id
		)
	):
		return false

	# 所有约束先校验完，再用副本一次替换 transport 与 session 两层投影；
	# 监听者只能看到 old 或 new 的完整状态，不会看到半迁移身份。
	var next_players := connected_players.duplicate()
	var next_characters := connected_player_characters.duplicate()
	var next_confirmations := confirmed_character_peers.duplicate()
	var next_members := _session_members.duplicate(true)
	next_players.erase(old_peer_id)
	next_characters.erase(old_peer_id)
	next_confirmations.erase(old_peer_id)
	var next_member := (next_members[old_peer_id] as Dictionary).duplicate(true)
	next_member["state"] = int(SessionMemberState.RECONNECTING)
	next_member["grace_expires_msec"] = 0
	next_members.erase(old_peer_id)
	next_members[new_peer_id] = next_member
	connected_players = next_players
	connected_player_characters = next_characters
	confirmed_character_peers = next_confirmations
	_session_members = next_members
	_session_membership_revision = membership_revision
	player_reconnected.emit(
		old_peer_id,
		new_peer_id,
		resolved_player_name,
		character_id,
		membership_revision
	)
	# 与 Host 保持同一观察顺序：专用身份事务先让运行时迁移 old->new，
	# 随后成员集合信号再投影同一 revision。后续同版 roster 可严格幂等。
	_emit_session_membership_changed()
	player_list_changed.emit()
	return true


@rpc("authority", "call_remote", "reliable", 0)
func _rpc_game_load_progress(session_id: int, ready_count: int, total_count: int) -> void:
	if multiplayer.get_remote_sender_id() != get_host_peer_id():
		return
	if session_id != loading_session_id:
		return
	_reported_game_load_total_count = maxi(total_count, 0)
	_reported_game_load_ready_count = clampi(
		ready_count,
		0,
		_reported_game_load_total_count
	)
	game_load_progress_changed.emit(
		_reported_game_load_ready_count,
		_reported_game_load_total_count
	)


func _broadcast_player_list_to_clients() -> void:
	if not is_host() or _enet_peer == null or not multiplayer.has_multiplayer_peer():
		return
	var host_id := get_host_peer_id()
	var player_list := _build_session_member_list_array()
	for peer_id_variant in connected_players:
		var peer_id := int(peer_id_variant)
		if peer_id <= 0 or peer_id == host_id:
			continue
		if not is_peer_send_ready(peer_id):
			continue
		_rpc_sync_player_list.rpc_id(
			peer_id,
			player_list,
			host_id,
			int(current_game_mode),
			room_max_players,
			_session_membership_revision
		)


func _send_start_game_to_clients() -> void:
	var host_id := get_host_peer_id()
	for peer_id_variant in connected_players:
		var peer_id := int(peer_id_variant)
		if peer_id <= 0 or peer_id == host_id:
			continue
		if not is_peer_send_ready(peer_id):
			continue
		_rpc_start_game.rpc_id(peer_id, int(current_game_mode), loading_session_id)


func _send_host_game_ready_to_clients() -> void:
	var host_id := get_host_peer_id()
	for peer_id_variant in connected_players:
		var peer_id := int(peer_id_variant)
		if peer_id <= 0 or peer_id == host_id:
			continue
		if not is_peer_send_ready(peer_id):
			continue
		_rpc_host_game_ready.rpc_id(peer_id, loading_session_id)


func _mark_peer_game_loaded(peer_id: int, session_id: int) -> void:
	if not is_host() or connection_state != ConnectionState.LOADING_GAME:
		return
	if session_id != loading_session_id or not _expected_game_load_peers.has(peer_id):
		return
	if _ready_game_load_peers.has(peer_id):
		return
	_ready_game_load_peers[peer_id] = true
	_emit_game_load_progress()
	_broadcast_game_load_progress()
	_try_finish_game_loading()


func _try_finish_game_loading() -> void:
	if not is_host() or connection_state != ConnectionState.LOADING_GAME:
		return
	if not _are_all_game_load_peers_ready():
		return
	mark_in_game()


func _are_all_game_load_peers_ready() -> bool:
	if _expected_game_load_peers.is_empty():
		return false
	for peer_id_variant in _expected_game_load_peers:
		if not _ready_game_load_peers.has(int(peer_id_variant)):
			return false
	return true


func _emit_game_load_progress() -> void:
	_reported_game_load_ready_count = _ready_game_load_peers.size()
	_reported_game_load_total_count = _expected_game_load_peers.size()
	game_load_progress_changed.emit(
		_reported_game_load_ready_count,
		_reported_game_load_total_count
	)


func _broadcast_game_load_progress() -> void:
	if not is_host():
		return
	var host_id := get_host_peer_id()
	for peer_id_variant in _expected_game_load_peers:
		var peer_id := int(peer_id_variant)
		if peer_id <= 0 or peer_id == host_id or not is_peer_send_ready(peer_id):
			continue
		_rpc_game_load_progress.rpc_id(
			peer_id,
			loading_session_id,
			_ready_game_load_peers.size(),
			_expected_game_load_peers.size()
		)


func _set_connection_state(new_state: ConnectionState) -> void:
	if connection_state == new_state:
		return
	connection_state = new_state
	connection_state_changed.emit(new_state)


func _set_current_game_mode(game_mode: GameMode) -> void:
	if current_game_mode == game_mode:
		return
	current_game_mode = game_mode
	game_mode_changed.emit(current_game_mode)


func _is_known_game_mode(game_mode: int) -> bool:
	# 可靠 RPC 仍须理解冻结的旧 wire；这不是新房间的发布许可。
	return GameModeCatalog.is_known_mode_id(game_mode)


func _is_release_game_mode(game_mode: int) -> bool:
	return GameModeCatalog.is_release_selectable(game_mode)


func _validate_host_game_mode_admission() -> bool:
	var definition := GameModeCatalog.get_definition(int(current_game_mode))
	if (
		definition != null
		and definition.is_selectable_for(_host_mode_selection_audience)
	):
		return true
	connection_failed.emit(
		"当前游戏模式仅用于协议兼容或开发测试，不能创建正式房间。"
	)
	return false


func _is_valid_room_max_players(max_players: int) -> bool:
	return (
		max_players >= NetConstants.MIN_ROOM_PLAYERS
		and max_players <= NetConstants.MAX_PLAYERS
	)


func _emit_room_capacity_changed() -> void:
	room_capacity_changed.emit(_session_members.size(), room_max_players)


func _get_safe_local_name() -> String:
	return _sanitize_player_name(local_player_name)


func _make_session_member_record(
	player_name: String,
	character_id: StringName,
	character_confirmed: bool,
	state: SessionMemberState,
	participant_incarnation: int,
	reconnect_token: String = "",
	grace_expires_msec: int = 0
) -> Dictionary:
	return {
		"player_name": _sanitize_player_name(player_name),
		"character_id": _sanitize_character_id(character_id),
		"character_confirmed": character_confirmed,
		"state": int(state),
		"participant_incarnation": participant_incarnation,
		"reconnect_token": reconnect_token,
		"grace_expires_msec": maxi(grace_expires_msec, 0),
	}


func _reset_session_membership(emit_change: bool = false) -> void:
	var had_members := not _session_members.is_empty()
	_session_members.clear()
	_session_membership_revision = 0
	_forced_final_departure_peer_ids.clear()
	if emit_change and had_members:
		session_membership_changed.emit(PackedInt32Array(), 0)


func _register_active_session_member(
	peer_id: int,
	player_name: String,
	character_id: StringName,
	character_confirmed: bool,
	reconnect_token: String
) -> bool:
	if not is_host() or peer_id <= 0 or _session_members.has(peer_id):
		return false
	var participant_incarnation := _issue_next_participant_incarnation()
	if participant_incarnation <= 0:
		push_error("NetManager: Host 成员世代已经耗尽，拒绝登记新成员。")
		return false
	_session_members[peer_id] = _make_session_member_record(
		player_name,
		character_id,
		character_confirmed,
		SessionMemberState.ACTIVE,
		participant_incarnation,
		reconnect_token
	)
	_publish_host_session_membership_change()
	return true


func _suspend_session_member_for_grace(
	peer_id: int,
	reconnect_token: String,
	expires_msec: int
) -> bool:
	if not _session_members.has(peer_id) or not _is_valid_reconnect_token(reconnect_token):
		return false
	var member := _session_members[peer_id] as Dictionary
	member["state"] = int(SessionMemberState.SUSPENDED_GRACE)
	member["reconnect_token"] = reconnect_token
	member["grace_expires_msec"] = expires_msec
	_session_members[peer_id] = member
	_disconnected_reconnect_slots[reconnect_token] = peer_id
	_publish_host_session_membership_change()
	return true


func _remap_session_member_identity(
	old_peer_id: int,
	new_peer_id: int,
	emit_change: bool = true
) -> bool:
	if (
		old_peer_id <= 0
		or new_peer_id <= 0
		or old_peer_id == new_peer_id
		or not _session_members.has(old_peer_id)
		or _session_members.has(new_peer_id)
		or not is_session_member_suspended(old_peer_id)
	):
		return false
	var member := (_session_members[old_peer_id] as Dictionary).duplicate(true)
	# 身份已经迁到 new，但运行时 Player 尚未完成投影。RECONNECTING 会进入
	# 持久成员全集，却不会进入可发送输入/玩法的 ACTIVE roster。
	member["state"] = int(SessionMemberState.RECONNECTING)
	# 身份换了 transport，但仍属于同一条宽限租约；投影超时后再次断线只能
	# 使用原 deadline，不能靠反复完成认证无限续期。
	_session_members.erase(old_peer_id)
	_session_members[new_peer_id] = member
	_session_membership_revision += 1
	if emit_change:
		_emit_session_membership_changed()
	return true


func _activate_reconnecting_session_member(peer_id: int) -> bool:
	if not is_host() or not is_session_member_reconnecting(peer_id):
		return false
	var member := (_session_members[peer_id] as Dictionary).duplicate(true)
	member["state"] = int(SessionMemberState.ACTIVE)
	member["grace_expires_msec"] = 0
	_session_members[peer_id] = member
	_publish_host_session_membership_change()
	return true


func _finalize_session_member_departures(
	peer_ids: PackedInt32Array,
	reason: StringName
) -> int:
	var removed_peer_ids := PackedInt32Array()
	var seen: Dictionary[int, bool] = {}
	for peer_id in peer_ids:
		if peer_id <= 0 or seen.has(peer_id) or not _session_members.has(peer_id):
			continue
		seen[peer_id] = true
		var member := _session_members[peer_id] as Dictionary
		var reconnect_token := str(member.get("reconnect_token", ""))
		if (
			_is_valid_reconnect_token(reconnect_token)
			and int(_disconnected_reconnect_slots.get(reconnect_token, 0)) == peer_id
		):
			_disconnected_reconnect_slots.erase(reconnect_token)
		_session_members.erase(peer_id)
		_completed_reconnect_runtime_projections.erase(peer_id)
		removed_peer_ids.append(peer_id)
	if removed_peer_ids.is_empty():
		return 0
	_publish_host_session_membership_change()
	for peer_id in removed_peer_ids:
		session_member_final_departed.emit(
			peer_id,
			_session_membership_revision,
			reason
		)
	return removed_peer_ids.size()


func _publish_host_session_membership_change() -> void:
	_session_membership_revision += 1
	_emit_session_membership_changed()


func _emit_session_membership_changed() -> void:
	session_membership_changed.emit(
		get_session_member_peer_ids(),
		_session_membership_revision
	)


func _build_session_member_list_array(recipient_peer_id: int = 0) -> Array:
	var result: Array = []
	var replaced_old_peer_id := 0
	if _pending_reconnect_loads.has(recipient_peer_id):
		replaced_old_peer_id = int(
			(_pending_reconnect_loads[recipient_peer_id] as Dictionary).get(
				"old_peer_id",
				0
			)
		)
	for peer_id in get_session_member_peer_ids():
		var member := _session_members[peer_id] as Dictionary
		var wire_peer_id := recipient_peer_id if peer_id == replaced_old_peer_id else peer_id
		var wire_state := (
			SessionMemberState.ACTIVE
			if peer_id == replaced_old_peer_id
			else int(member.get("state", SessionMemberState.ACTIVE)) as SessionMemberState
		)
		result.append({
			"id": wire_peer_id,
			"participant_incarnation": int(
				member.get("participant_incarnation", 0)
			),
			"name": (
				str(connected_players.get(recipient_peer_id, member.get("player_name", "Player")))
				if peer_id == replaced_old_peer_id
				else str(member.get("player_name", "Player"))
			),
			"character_id": String(
				connected_player_characters.get(
					recipient_peer_id,
					member.get("character_id", DEFAULT_CHARACTER_ID)
				)
				if peer_id == replaced_old_peer_id
				else member.get("character_id", DEFAULT_CHARACTER_ID)
			),
			"character_confirmed": (
				bool(confirmed_character_peers.get(recipient_peer_id, true))
				if peer_id == replaced_old_peer_id
				else bool(member.get("character_confirmed", false))
			),
			"session_state": int(wire_state),
		})
	return result


func _prepare_session_member_list(player_list: Array) -> Dictionary:
	var prepared_members: Dictionary[int, Dictionary] = {}
	var seen_participant_incarnations: Dictionary[int, bool] = {}
	for entry_variant in player_list:
		if typeof(entry_variant) != TYPE_DICTIONARY:
			return {}
		var entry := entry_variant as Dictionary
		var peer_id := int(entry.get("id", 0))
		var state := int(entry.get("session_state", -1))
		var character_id := StringName(entry.get("character_id", DEFAULT_CHARACTER_ID))
		if typeof(entry.get("participant_incarnation")) != TYPE_INT:
			return {}
		var participant_incarnation := int(entry["participant_incarnation"])
		if (
			peer_id <= 0
			or prepared_members.has(peer_id)
			or participant_incarnation <= 0
			or participant_incarnation > NetConstants.MAX_PARTICIPANT_INCARNATION
			or seen_participant_incarnations.has(participant_incarnation)
			or state < int(SessionMemberState.ACTIVE)
			or state > int(SessionMemberState.RECONNECTING)
			or not PlayerCharacterRegistry.is_valid_character_id(character_id)
		):
			return {}
		seen_participant_incarnations[participant_incarnation] = true
		prepared_members[peer_id] = _make_session_member_record(
			str(entry.get("name", "")),
			character_id,
			bool(entry.get("character_confirmed", false)),
			state as SessionMemberState,
			participant_incarnation
		)
	return prepared_members


## 两个玩家同时处于重连加载时，Host 不会向尚未 send-ready 的客户端发送
## 旁路 identity RPC。最终 roster 仍携带稳定 participant incarnation，因此
## Client 可在提交 roster 前恢复漏掉的 old->new 事务，再让最终 revision 收敛
## ACTIVE/SUSPENDED 等状态；禁止把同一成员误当成“一删一增”而丢失账本。
func _apply_inferred_reconnected_identities_from_roster(
	prepared_members: Dictionary[int, Dictionary],
	target_membership_revision: int
) -> bool:
	var prepared_peer_by_incarnation: Dictionary[int, int] = {}
	for prepared_peer_id_variant in prepared_members.keys():
		var prepared_peer_id := int(prepared_peer_id_variant)
		var prepared_member := prepared_members[prepared_peer_id] as Dictionary
		prepared_peer_by_incarnation[int(
			prepared_member.get("participant_incarnation", 0)
		)] = prepared_peer_id
	var transitions: Array[Dictionary] = []
	for old_peer_id in get_session_member_peer_ids():
		if prepared_members.has(old_peer_id):
			continue
		var old_member := _session_members[old_peer_id] as Dictionary
		var participant_incarnation := int(
			old_member.get("participant_incarnation", 0)
		)
		var new_peer_id := int(
			prepared_peer_by_incarnation.get(participant_incarnation, 0)
		)
		if new_peer_id <= 0:
			# participant 不在新表中表示真实 final departure，由最终 reconcile 处理。
			continue
		if (
			new_peer_id == old_peer_id
			or int(old_member.get("state", -1))
			!= int(SessionMemberState.SUSPENDED_GRACE)
		):
			return false
		var new_member := prepared_members[new_peer_id] as Dictionary
		if (
			str(new_member.get("player_name", ""))
			!= str(old_member.get("player_name", ""))
			or StringName(new_member.get("character_id", DEFAULT_CHARACTER_ID))
			!= StringName(old_member.get("character_id", DEFAULT_CHARACTER_ID))
			or not bool(new_member.get("character_confirmed", false))
			or int(new_member.get("state", -1)) not in [
				SessionMemberState.RECONNECTING,
				SessionMemberState.ACTIVE,
			]
		):
			return false
		transitions.append({
			"old_peer_id": old_peer_id,
			"new_peer_id": new_peer_id,
			"player_name": str(new_member.get("player_name", "")),
			"character_id": StringName(
				new_member.get("character_id", DEFAULT_CHARACTER_ID)
			),
			"participant_incarnation": participant_incarnation,
		})
	if transitions.is_empty():
		return true
	transitions.sort_custom(func(left: Dictionary, right: Dictionary) -> bool:
		return int(left["participant_incarnation"]) < int(
			right["participant_incarnation"]
		)
	)
	if (
		target_membership_revision - _session_membership_revision
		< transitions.size()
	):
		return false
	# 所有 transition 已完成纯预检；逐个使用连续 revision 发布既有强类型
	# identity signal。最终 roster 可以再以更高 revision 原子收敛其余成员变化。
	for transition in transitions:
		if not _apply_player_reconnected_identity(
			int(transition["old_peer_id"]),
			int(transition["new_peer_id"]),
			str(transition["player_name"]),
			StringName(transition["character_id"]),
			_session_membership_revision + 1
		):
			return false
	return true


func _session_member_sets_match(left: Dictionary, right: Dictionary) -> bool:
	if left.size() != right.size():
		return false
	for raw_peer_id in left.keys():
		var peer_id := int(raw_peer_id)
		if not right.has(peer_id):
			return false
		var left_member := left[peer_id] as Dictionary
		var right_member := right[peer_id] as Dictionary
		for key in [
			"player_name",
			"character_id",
			"character_confirmed",
			"state",
			"participant_incarnation",
		]:
			if left_member.get(key) != right_member.get(key):
				return false
	return true


func _set_peer_character(peer_id: int, character_id: StringName, confirmed: bool) -> void:
	if peer_id <= 0:
		return
	var resolved_character_id := _sanitize_character_id(character_id)
	var changed := (
		StringName(connected_player_characters.get(peer_id, DEFAULT_CHARACTER_ID))
		!= resolved_character_id
		or bool(confirmed_character_peers.get(peer_id, false)) != confirmed
	)
	connected_player_characters[peer_id] = resolved_character_id
	confirmed_character_peers[peer_id] = confirmed
	if changed and _session_members.has(peer_id):
		var member := _session_members[peer_id] as Dictionary
		member["character_id"] = resolved_character_id
		member["character_confirmed"] = confirmed
		_session_members[peer_id] = member
		_publish_host_session_membership_change()
	if changed:
		player_character_changed.emit(peer_id, resolved_character_id, confirmed)
		player_list_changed.emit()


func _sanitize_character_id(character_id: StringName) -> StringName:
	if PlayerCharacterRegistry.is_valid_character_id(character_id):
		return character_id
	return DEFAULT_CHARACTER_ID


func _sanitize_player_name(raw_name: String) -> String:
	var trimmed_name := raw_name.strip_edges()
	if trimmed_name.length() > NetConstants.MAX_PLAYER_NAME_LENGTH:
		trimmed_name = trimmed_name.left(NetConstants.MAX_PLAYER_NAME_LENGTH)
	return trimmed_name if not trimmed_name.is_empty() else "Player"


func _debug_log(message: String) -> void:
	if OS.is_debug_build():
		print(message)
