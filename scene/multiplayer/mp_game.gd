extends Node2D

const _NetConstants := preload("res://scene/multiplayer/net_constants.gd")
const GAME_SCENE := preload("res://scene/game.tscn")
const PICKUP_SCENE := preload("res://scene/pickup.tscn")
const BULLET_SCENE := preload("res://scene/bullet.tscn")
const COLLECTIBLE_ARROW_PROJECTILE_SCENE := preload("res://scene/collectible_arrow_projectile.tscn")
const COLLECTIBLE_ARROW_PROJECTILE_SCRIPT := preload("res://scene/collectible_arrow_projectile.gd")
const SKILL1_BOMB_SCENE := preload("res://scene/weishidaier_skill1_bomb.tscn")
const COLLECTIBLE_AREA_EFFECT_SCENE := preload("res://scene/collectible_area_effect.tscn")
const COLLECTIBLE_FROST_AREA_EFFECT_SCENE := preload("res://scene/collectible_frost_area_effect.tscn")
const COLLECTIBLE_LIGHTNING_EFFECT_SCENE := preload("res://scene/collectible_lightning_effect.tscn")
const COLLECTIBLE_MOON_SHIELD_VISUAL_SCENE := preload("res://scene/collectible_moon_shield_visual.tscn")
const CAPOO_AK47_BULLET_SCENE := preload("res://scene/enemy/capoo_ak47_bullet.tscn")
const CAPOO_RPG_ROCKET_SCENE := preload("res://scene/enemy/capoo_rpg_rocket.tscn")
const CAPOO_MAGE_FIREBALL_SCENE := preload("res://scene/enemy/capoo_mage_fireball.tscn")
const CAPOO_SMG_BULLET_SCENE := preload("res://scene/enemy/capoo_smg_bullet.tscn")
const YUANSHI_FIRE_PROJECTILE_SCENE := preload("res://scene/enemy/yuanshi_insect_fire_projectile.tscn")
const LINGLAN_SAKURA_BULLET_SCENE := preload("res://scene/linglan_skill1_sakura_bullet.tscn")
const DEFAULT_LINGLAN_SKILL2_CONFIG := preload("res://resources/config/bosses/linglan_skill2.tres")
const LINGLAN_SKILL2_ROCKET_SCENE := preload("res://scene/linglan_skill2_sakura_rocket.tscn")
const DEFAULT_LINGLAN_SKILL3_CONFIG := preload("res://resources/config/bosses/linglan_skill3.tres")
const LINGLAN_SKILL3_ORB_SCENE := preload("res://scene/linglan_skill3_light_orb.tscn")
const DEFAULT_LINGLAN_SKILL4_CONFIG := preload("res://resources/config/bosses/linglan_skill4.tres")
const LINGLAN_SKILL4_ORB_SCENE := preload("res://scene/linglan_skill4_light_orb.tscn")
const LINGLAN_SKILL4_ORB_SCRIPT := preload("res://scene/linglan_skill4_light_orb.gd")
const XIRANG_DROP_SCENE := preload("res://scene/xirang_drop.tscn")

const INPUT_BUTTON_SKILL1 := 1
const GAME_RUNTIME_HOST_AUTHORITY := 1
const GAME_RUNTIME_CLIENT_VIEW := 2
const STATE_DISCONNECTED := 0
const STATE_IN_GAME := 5
const HOST_TIME_OFFSET_SMOOTH_WEIGHT := 0.08
const INPUT_CHANGE_EPSILON := 0.001
const PLAYER_STATE_MAX_ACCEPTED_JUMP_DISTANCE := 2048.0
const PLAYER_REVIVE_DELAY_SECONDS := 10.0
const PLAYER_REVIVE_INVINCIBILITY_SECONDS := 3.0
const CHEAT_XIRANG_AMOUNT := 1000
const HIT_DEDUP_RETENTION_SECONDS := 30.0
const ORB_DEDUP_RETENTION_SECONDS := 60.0
const RECENT_EVENT_PRUNE_INTERVAL_SECONDS := 5.0
const PROJECTILE_RECORD_RETENTION_SECONDS := 5.0
const PROJECTILE_ID_NAMESPACE_SIZE := 1000000
const CLIENT_PROJECTILE_SPAWN_POSITION_TOLERANCE := 224.0
const CLIENT_PROJECTILE_DIRECTION_MIN_LENGTH := 0.2
const CLIENT_PROJECTILE_DIRECTION_MAX_LENGTH := 1.5
const PROJECTILE_TIME_COMPENSATION_MAX_SECONDS := 0.25
# Application payload budget. Keep room for Godot RPC, ENet, UDP/IP headers before MTU pressure.
const SNAPSHOT_PACKET_WARN_BYTES := 1200
const SNAPSHOT_PACKET_WARN_INTERVAL_SECONDS := 5.0
const HOST_STARTUP_SNAPSHOT_GRACE_SECONDS := 0.5
const PLAYER_DELTA_KEYFRAME_INTERVAL_SECONDS := 0.5
const ENEMY_DELTA_KEYFRAME_INTERVAL_SECONDS := 0.5
const ENEMY_ACTION_SNAPSHOT_REORDER_TOLERANCE_SECONDS := 0.075
# Multiplayer protocol map:
# - CH_INPUT unreliable_ordered: client player pose/input to host.
# - CH_STATE unreliable_ordered: host player/enemy snapshots to clients.
# - CH_PROJECTILE unreliable_ordered: projectile visual spawn events.
# - CH_EVENT reliable: damage, death, revive, spawn/despawn, pickups, upgrades, wave/HUD events.
# Host owns enemy AI, player damage confirmation, death, revive, pickups, upgrades, and wave lifecycle.

@onready var net_manager: Node = get_node("/root/NetManager")
@onready var run_state: RunStateStore = get_node("/root/RunState") as RunStateStore
@onready var public_room_keepalive_request: HTTPRequest = $PublicRoomKeepaliveRequest

var snapshot_mgr := SnapshotManager.new()
var _linglan_skill2_config: LinglanSkill2Config = DEFAULT_LINGLAN_SKILL2_CONFIG
var _linglan_skill3_config: LinglanSkill3Config = DEFAULT_LINGLAN_SKILL3_CONFIG
var _linglan_skill4_config: LinglanSkill4Config = DEFAULT_LINGLAN_SKILL4_CONFIG
# Client-view only: remote player visual timeline. Host gameplay never reads this.
var player_visual_interpolators: Dictionary = {}
var enemy_interpolators: Dictionary = {}
var game: Game = null
var input_sequence: int = 0
var _net_time_origin: float = 0.0
var _net_enemies: Dictionary = {}
var _enemy_spawn_snapshot_times: Dictionary = {}
var _has_host_time_offset: bool = false
var _host_to_client_time_offset: float = 0.0
var _has_sent_input: bool = false
var _last_sent_move_input: Vector2 = Vector2.ZERO
var _last_sent_shoot_input: Vector2 = Vector2.ZERO
var _input_frames_since_last_send: int = _NetConstants.INPUT_KEEPALIVE_INTERVAL_FRAMES
var _last_player_state_sequences: Dictionary = {}
var _accepted_player_state_positions: Dictionary = {}
var _accepted_player_state_times: Dictionary = {}
var _host_latest_client_player_snapshot_states: Dictionary = {}
var _next_projectile_id: int = 1
var _known_projectiles: Dictionary = {}
var _projectile_records: Dictionary = {}
var _processed_enemy_hit_ids: Dictionary = {}
var _processed_player_hit_ids: Dictionary = {}
var _next_xirang_orb_id: int = 1
var _xirang_orbs: Dictionary = {}
var _collected_xirang_orbs: Dictionary = {}
var _granted_xirang_orbs: Dictionary = {}
var _host_player_snapshot_sequence: int = 0
var _player_health_revisions: Dictionary = {}
var _local_player_hit_revision: int = 0
var _dead_player_revive_times: Dictionary = {}
var _dead_player_revive_last_seconds: Dictionary = {}
var _xirang_revision: int = 0
var _recent_event_prune_time_left: float = RECENT_EVENT_PRUNE_INTERVAL_SECONDS
var _snapshot_packet_warn_time_left: float = 0.0
var _host_startup_snapshot_grace_time_left: float = 0.0
var _client_host_game_ready: bool = false
var _max_player_snapshot_packet_bytes: int = 0
var _max_enemy_snapshot_packet_bytes: int = 0
var _large_player_snapshot_packet_count: int = 0
var _large_enemy_snapshot_packet_count: int = 0
var _last_player_keyframe_time_by_peer: Dictionary = {}
var _last_enemy_keyframe_time_by_peer: Dictionary = {}
var _public_room_keepalive_time_left: float = 0.0
var _public_room_keepalive_in_flight: bool = false
var _revive_random_generator := RandomNumberGenerator.new()


func _ready() -> void:
	_net_time_origin = Time.get_ticks_msec() / 1000.0
	_revive_random_generator.randomize()
	set_multiplayer_authority(_get_host_peer_id())
	if not net_manager.connection_state_changed.is_connected(_on_connection_state_changed):
		net_manager.connection_state_changed.connect(_on_connection_state_changed)
	if not net_manager.player_left.is_connected(_on_net_player_left):
		net_manager.player_left.connect(_on_net_player_left)
	if not public_room_keepalive_request.request_completed.is_connected(_on_public_room_keepalive_completed):
		public_room_keepalive_request.request_completed.connect(_on_public_room_keepalive_completed)
	if net_manager.is_host():
		_setup_game(GAME_RUNTIME_HOST_AUTHORITY)
		_host_startup_snapshot_grace_time_left = HOST_STARTUP_SNAPSHOT_GRACE_SECONDS
		_client_host_game_ready = true
	elif net_manager.is_client():
		_setup_game(GAME_RUNTIME_CLIENT_VIEW)
		_client_host_game_ready = bool(net_manager.get("host_game_ready"))
	else:
		push_warning("MpGame 启动时没有有效的多人连接，返回大厅。")
		call_deferred("_return_to_lobby")
		return
	if net_manager.is_host() or _client_host_game_ready:
		net_manager.mark_in_game()


func _exit_tree() -> void:
	if net_manager != null and net_manager.connection_state_changed.is_connected(_on_connection_state_changed):
		net_manager.connection_state_changed.disconnect(_on_connection_state_changed)
	if net_manager != null and net_manager.player_left.is_connected(_on_net_player_left):
		net_manager.player_left.disconnect(_on_net_player_left)
	if game != null and game.return_to_lobby_requested.is_connected(_on_game_return_to_lobby_requested):
		game.return_to_lobby_requested.disconnect(_on_game_return_to_lobby_requested)
	if public_room_keepalive_request != null:
		if public_room_keepalive_request.request_completed.is_connected(_on_public_room_keepalive_completed):
			public_room_keepalive_request.request_completed.disconnect(_on_public_room_keepalive_completed)
		if public_room_keepalive_request.get_http_client_status() != HTTPClient.STATUS_DISCONNECTED:
			public_room_keepalive_request.cancel_request()
	snapshot_mgr.reset_delta_cache()
	_public_room_keepalive_in_flight = false


func _physics_process(delta: float) -> void:
	_update_recent_event_cache_prune(delta)
	_update_snapshot_packet_warning_timer(delta)
	var frame: int = net_manager.get_physics_frame_count()
	if net_manager.is_host():
		_host_physics_tick(frame, delta)
	elif net_manager.is_client():
		_client_physics_tick(frame)


func _process(delta: float) -> void:
	_update_public_room_keepalive(delta)
	if net_manager.is_client() or net_manager.is_host():
		_client_interpolate_entities()
	if net_manager.is_client() and game != null:
		game.apply_remote_enemy_count(_net_enemies.size())


func request_multiplayer_upgrade(stat_type: int) -> void:
	if net_manager.is_host():
		_apply_upgrade_for_peer(_get_local_peer_id(), stat_type)
	else:
		net_upgrade_selected.rpc_id(_get_host_peer_id(), stat_type)


func request_multiplayer_inventory_item_use(slot_index: int) -> void:
	if net_manager.is_host():
		_apply_inventory_item_use_for_peer(_get_local_peer_id(), slot_index)
	else:
		net_inventory_item_use_requested.rpc_id(_get_host_peer_id(), slot_index)


func request_multiplayer_inventory_item_discard(slot_index: int) -> void:
	if net_manager.is_host():
		_apply_inventory_item_discard_for_peer(_get_local_peer_id(), slot_index)
	else:
		net_inventory_item_discard_requested.rpc_id(_get_host_peer_id(), slot_index)


func request_multiplayer_skill1_purchase() -> void:
	if net_manager.is_host():
		_apply_skill1_purchase_for_peer(_get_local_peer_id())
	else:
		net_skill1_purchase_requested.rpc_id(_get_host_peer_id())


func request_luoxi_collectible_choice(choice_index: int, config_path: String = "") -> void:
	if net_manager.is_host():
		_apply_luoxi_collectible_choice_for_peer(_get_local_peer_id(), choice_index, config_path)
	else:
		net_luoxi_collectible_choice_requested.rpc_id(_get_host_peer_id(), choice_index, config_path)


func has_luoxi_collectible_claimed(peer_id: int) -> bool:
	if game == null:
		return false
	return game.has_luoxi_collectible_claimed(peer_id)


func broadcast_collectible_visual_effect(
	effect_type: StringName,
	spawn_position: Vector2,
	radius: float,
	color: Color,
	duration: float
) -> void:
	if net_manager == null or not net_manager.is_host():
		return
	_rpc_to_connected_clients(
		&"net_collectible_visual_effect",
		[String(effect_type), spawn_position, radius, color, duration]
	)


func broadcast_collectible_follow_visual_effect(
	effect_type: StringName,
	owner_peer_id: int,
	radius: float,
	duration: float
) -> void:
	if net_manager == null or not net_manager.is_host():
		return
	if owner_peer_id <= 0:
		return
	_rpc_to_connected_clients(
		&"net_collectible_follow_visual_effect",
		[String(effect_type), owner_peer_id, radius, duration]
	)


func request_multiplayer_cheat_xirang() -> void:
	if net_manager.is_host():
		_apply_cheat_xirang_for_peer(_get_local_peer_id())
	else:
		net_cheat_xirang_requested.rpc_id(_get_host_peer_id())


func request_debug_collectible(config_path: String) -> void:
	if net_manager.is_host():
		_apply_debug_collectible_for_peer(_get_local_peer_id(), config_path)
	else:
		net_debug_collectible_requested.rpc_id(_get_host_peer_id(), config_path)


func is_client_view_runtime() -> bool:
	if game != null:
		return int(game.runtime_mode) == GAME_RUNTIME_CLIENT_VIEW
	return net_manager != null and net_manager.is_client()


func _setup_game(mode: int) -> void:
	game = GAME_SCENE.instantiate() as Game
	if game == null:
		push_error("MpGame: 无法实例化 game.tscn")
		return

	var local_peer_id: int = _get_local_peer_id()
	if local_peer_id <= 0 and net_manager.is_host():
		local_peer_id = _get_host_peer_id()
	game.configure_multiplayer(mode, local_peer_id, net_manager.connected_players)
	add_child(game)
	run_state.set_active_multiplayer_peer(local_peer_id)

	if net_manager.is_host():
		game.multiplayer_enemy_spawned.connect(_on_host_enemy_spawned)
		game.multiplayer_enemy_defeated.connect(_on_host_enemy_defeated)
		game.multiplayer_enemy_removed.connect(_on_host_enemy_removed)
		game.multiplayer_pickup_spawned.connect(_on_host_pickup_spawned)
		game.multiplayer_pickup_collected.connect(_on_host_pickup_collected)
		game.multiplayer_pickup_removed.connect(_on_host_pickup_removed)
		game.multiplayer_merchant_active_changed.connect(_on_host_merchant_active_changed)
		game.multiplayer_wave_started.connect(_on_host_wave_started)
		game.multiplayer_flow_state_changed.connect(_on_host_flow_state_changed)
		game.multiplayer_boss_started.connect(_on_host_boss_started)
		game.multiplayer_defeat_started.connect(_on_host_defeat_started)
		game.multiplayer_victory_started.connect(_on_host_victory_started)
		game.multiplayer_revive_all_requested.connect(_on_host_revive_all_requested)
	game.return_to_lobby_requested.connect(_on_game_return_to_lobby_requested)


func _host_physics_tick(frame: int, _delta: float) -> void:
	if game == null:
		return
	_host_update_player_revives()
	if _host_startup_snapshot_grace_time_left > 0.0:
		_host_startup_snapshot_grace_time_left = maxf(
			_host_startup_snapshot_grace_time_left - _delta,
			0.0
		)
		return
	if frame % _NetConstants.PLAYER_SNAPSHOT_INTERVAL_FRAMES == 0:
		_host_broadcast_player_snapshots()
	if frame % _NetConstants.ENEMY_SNAPSHOT_INTERVAL_FRAMES == 0:
		_host_broadcast_enemy_snapshots()


func _host_broadcast_player_snapshots() -> void:
	var states: Array[SnapshotManager.PlayerState] = game.collect_player_snapshot_states()
	if states.is_empty():
		return
	_apply_latest_client_player_snapshot_states(states)
	_host_player_snapshot_sequence += 1
	for state in states:
		state.sequence = _host_player_snapshot_sequence
	var snapshot_time := _get_net_time()
	for peer_id in _get_connected_client_peer_ids():
		var force_keyframe := _should_force_player_delta_keyframe(peer_id, snapshot_time)
		var data := snapshot_mgr.encode_player_snapshots_for_peer(peer_id, states, force_keyframe)
		if force_keyframe:
			_last_player_keyframe_time_by_peer[peer_id] = snapshot_time
		_record_snapshot_packet_size(&"player", data.size(), states.size())
		_rpc_receive_player_snapshot.rpc_id(peer_id, snapshot_time, data)


func _apply_latest_client_player_snapshot_states(states: Array[SnapshotManager.PlayerState]) -> void:
	if _host_latest_client_player_snapshot_states.is_empty():
		return
	for state in states:
		if state == null or state.is_dead:
			continue
		var latest_variant: Variant = _host_latest_client_player_snapshot_states.get(state.peer_id)
		if latest_variant == null:
			continue
		var latest := latest_variant as Dictionary
		if latest.is_empty():
			continue
		state.position = latest["position"] as Vector2
		state.velocity = latest["velocity"] as Vector2
		state.facing = int(latest["facing"])
		state.anim_state = int(latest["anim_state"])


func _host_broadcast_enemy_snapshots() -> void:
	var states: Array[SnapshotManager.EnemyState] = game.collect_enemy_snapshot_states()
	var snapshot_time := _get_net_time()
	for peer_id in _get_connected_client_peer_ids():
		var force_keyframe := _should_force_enemy_delta_keyframe(peer_id, snapshot_time)
		var data := snapshot_mgr.encode_enemy_snapshots_for_peer(peer_id, states, force_keyframe)
		if force_keyframe:
			_last_enemy_keyframe_time_by_peer[peer_id] = snapshot_time
		_record_snapshot_packet_size(&"enemy", data.size(), states.size())
		_rpc_receive_enemy_snapshot.rpc_id(peer_id, snapshot_time, data)


func _should_force_player_delta_keyframe(peer_id: int, snapshot_time: float) -> bool:
	if peer_id <= 0:
		return true
	if not _last_player_keyframe_time_by_peer.has(peer_id):
		return true
	var last_keyframe_time := float(_last_player_keyframe_time_by_peer.get(peer_id, -INF))
	return snapshot_time - last_keyframe_time >= PLAYER_DELTA_KEYFRAME_INTERVAL_SECONDS


func _should_force_enemy_delta_keyframe(peer_id: int, snapshot_time: float) -> bool:
	if peer_id <= 0:
		return true
	if not _last_enemy_keyframe_time_by_peer.has(peer_id):
		return true
	var last_keyframe_time := float(_last_enemy_keyframe_time_by_peer.get(peer_id, -INF))
	return snapshot_time - last_keyframe_time >= ENEMY_DELTA_KEYFRAME_INTERVAL_SECONDS


func _get_connected_client_peer_ids() -> Array[int]:
	var result: Array[int] = []
	if net_manager == null:
		return result
	var connected_players := net_manager.get("connected_players") as Dictionary
	var host_peer_id := _get_host_peer_id()
	for peer_id_variant in connected_players:
		var peer_id := int(peer_id_variant)
		if peer_id <= 0 or peer_id == host_peer_id:
			continue
		if (
			net_manager.has_method("is_peer_send_ready")
			and not bool(net_manager.call("is_peer_send_ready", peer_id))
		):
			continue
		result.append(peer_id)
	return result


func _rpc_to_connected_clients(method_name: StringName, args: Array = []) -> void:
	for peer_id in _get_connected_client_peer_ids():
		var rpc_args: Array = [peer_id, method_name]
		rpc_args.append_array(args)
		callv("rpc_id", rpc_args)


func _update_snapshot_packet_warning_timer(delta: float) -> void:
	_snapshot_packet_warn_time_left = maxf(_snapshot_packet_warn_time_left - delta, 0.0)


func _record_snapshot_packet_size(snapshot_type: StringName, packet_bytes: int, entity_count: int) -> void:
	if snapshot_type == &"player":
		_max_player_snapshot_packet_bytes = maxi(_max_player_snapshot_packet_bytes, packet_bytes)
		if packet_bytes <= SNAPSHOT_PACKET_WARN_BYTES:
			return
		_large_player_snapshot_packet_count += 1
	elif snapshot_type == &"enemy":
		_max_enemy_snapshot_packet_bytes = maxi(_max_enemy_snapshot_packet_bytes, packet_bytes)
		if packet_bytes <= SNAPSHOT_PACKET_WARN_BYTES:
			return
		_large_enemy_snapshot_packet_count += 1
	else:
		return
	if _snapshot_packet_warn_time_left > 0.0:
		return
	_snapshot_packet_warn_time_left = SNAPSHOT_PACKET_WARN_INTERVAL_SECONDS
	if is_inside_tree():
		push_warning(
			"MpGame: %s snapshot packet is %d bytes for %d entities; monitor bandwidth under latency/loss."
			% [String(snapshot_type), packet_bytes, entity_count]
		)


func get_snapshot_packet_metrics() -> Dictionary:
	return {
		"max_player_snapshot_packet_bytes": _max_player_snapshot_packet_bytes,
		"max_enemy_snapshot_packet_bytes": _max_enemy_snapshot_packet_bytes,
		"large_player_snapshot_packet_count": _large_player_snapshot_packet_count,
		"large_enemy_snapshot_packet_count": _large_enemy_snapshot_packet_count,
	}


func _update_public_room_keepalive(delta: float) -> void:
	if not _should_send_public_room_keepalive():
		_public_room_keepalive_time_left = 0.0
		return
	if _public_room_keepalive_in_flight:
		return
	_public_room_keepalive_time_left -= delta
	if _public_room_keepalive_time_left > 0.0:
		return
	_send_public_room_keepalive()


func _should_send_public_room_keepalive() -> bool:
	if public_room_keepalive_request == null or net_manager == null:
		return false
	if not net_manager.is_host():
		return false
	if int(net_manager.get("conn_mode")) != int(NetManagerStore.ConnMode.RELAY):
		return false
	if not bool(net_manager.get("public_is_host")):
		return false
	return (
		not str(net_manager.get("public_room_id")).strip_edges().is_empty()
		and not str(net_manager.get("public_host_token")).strip_edges().is_empty()
	)


func _send_public_room_keepalive() -> void:
	var room_id := str(net_manager.get("public_room_id")).strip_edges()
	var host_token := str(net_manager.get("public_host_token")).strip_edges()
	if room_id.is_empty() or host_token.is_empty():
		return
	var body := JSON.stringify({"host_token": host_token})
	var headers := PackedStringArray(["Content-Type: application/json"])
	var err := public_room_keepalive_request.request(
		"%s/rooms/%s/keepalive" % [_NetConstants.PUBLIC_LOBBY_API_BASE_URL, room_id],
		headers,
		HTTPClient.METHOD_POST,
		body
	)
	if err != OK:
		_public_room_keepalive_time_left = _NetConstants.PUBLIC_ROOM_KEEPALIVE_INTERVAL_SECONDS
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
	_public_room_keepalive_time_left = _NetConstants.PUBLIC_ROOM_KEEPALIVE_INTERVAL_SECONDS
	if not _should_send_public_room_keepalive():
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
	if parsed_dict != null and parsed_dict.has("relay_running") and not bool(parsed_dict["relay_running"]):
		push_warning("MpGame: 公网房间续租成功，但云端 Relay 进程已不在运行。")


func _create_player_interpolator() -> NetInterpolator:
	return NetInterpolator.new(
		1.0 / float(_NetConstants.PLAYER_SNAPSHOT_HZ),
		_NetConstants.PLAYER_INTERPOLATION_DELAY_FACTOR,
		_NetConstants.PLAYER_MAX_EXTRAPOLATION_SECONDS
	)


func _create_enemy_interpolator() -> NetInterpolator:
	return NetInterpolator.new(
		1.0 / float(_NetConstants.ENEMY_SNAPSHOT_HZ),
		_NetConstants.ENEMY_INTERPOLATION_DELAY_FACTOR,
		_NetConstants.ENEMY_MAX_EXTRAPOLATION_SECONDS
	)


func _client_physics_tick(frame: int) -> void:
	if not _client_host_game_ready:
		return
	_input_frames_since_last_send += 1
	var buttons := 0
	if frame % _NetConstants.INPUT_SEND_INTERVAL_FRAMES == 0 or buttons != 0:
		_client_send_input_if_needed(buttons)


func _client_send_input_if_needed(buttons: int) -> void:
	var move_input := Input.get_vector("move_left", "move_right", "move_up", "move_down")
	var shoot_input := _get_client_shoot_input()
	var player_node: Player = null
	if game != null:
		player_node = game.player
	if player_node == null:
		return
	var input_changed := (
		not _has_sent_input
		or move_input.distance_squared_to(_last_sent_move_input) > INPUT_CHANGE_EPSILON
		or shoot_input.distance_squared_to(_last_sent_shoot_input) > INPUT_CHANGE_EPSILON
	)
	var keepalive_due := (
		_input_frames_since_last_send >= _NetConstants.INPUT_KEEPALIVE_INTERVAL_FRAMES
	)
	var active_realtime_state := (
		move_input != Vector2.ZERO
		or shoot_input != Vector2.ZERO
		or player_node.velocity.length_squared() > INPUT_CHANGE_EPSILON
		or player_node.skill1_unlocked
		or player_node.invincibility_time_left > 0.0
		or player_node.current_form_mode != PickupConfig.PlayerFormMode.NORMAL
		or player_node.current_shot_pattern != PickupConfig.ShotPattern.NORMAL
	)
	if not input_changed and not keepalive_due and buttons == 0 and not active_realtime_state:
		return
	input_sequence += 1
	_has_sent_input = true
	_last_sent_move_input = move_input
	_last_sent_shoot_input = shoot_input
	_input_frames_since_last_send = 0
	_rpc_client_player_state.rpc_id(
		_get_host_peer_id(),
		input_sequence,
		player_node.global_position,
		player_node.velocity,
		shoot_input,
		buttons,
		player_node.current_health,
		player_node.max_health,
		player_node.current_xirang,
		player_node.is_dead,
		player_node.invincibility_time_left,
		player_node.skill1_unlocked,
		player_node.skill1_charge,
		player_node.skill1_charge_duration,
		player_node.current_form_mode,
		player_node.current_shot_pattern
	)


func _get_client_shoot_input() -> Vector2:
	var shoot_input := Input.get_vector("shoot_left", "shoot_right", "shoot_up", "shoot_down")
	if shoot_input != Vector2.ZERO:
		return shoot_input
	if game == null or game.player == null:
		return Vector2.ZERO
	if not Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT):
		return Vector2.ZERO
	return game.player.global_position.direction_to(game.player.get_global_mouse_position())


func _client_interpolate_entities() -> void:
	if game == null:
		return
	var current_time := _get_net_time()
	var local_peer_id: int = _get_client_view_local_peer_id()
	if is_client_view_runtime():
		for peer_id_variant in player_visual_interpolators.keys():
			var peer_id := int(peer_id_variant)
			if peer_id == local_peer_id:
				continue
			var interp := player_visual_interpolators[peer_id] as NetInterpolator
			var player_node: Player = game.get_player_for_peer(peer_id)
			if interp != null and player_node != null and is_instance_valid(player_node):
				var frame_state: NetInterpolator.FrameSnapshot = interp.get_current_state(current_time)
				player_node.apply_multiplayer_snapshot_motion(
					interp.get_interpolated_position(current_time),
					interp.get_interpolated_velocity(current_time),
					frame_state.facing,
					frame_state.anim_state
				)
	for net_id_variant in enemy_interpolators.keys():
		var net_id := int(net_id_variant)
		var enemy_interp := enemy_interpolators[net_id] as NetInterpolator
		var enemy_node: Enemy = _get_valid_client_enemy_for_net_id(net_id)
		if enemy_interp != null and enemy_node != null and is_instance_valid(enemy_node):
			var enemy_position: Vector2 = enemy_interp.get_interpolated_position(current_time)
			var enemy_velocity: Vector2 = enemy_interp.get_interpolated_velocity(current_time)
			enemy_node.apply_multiplayer_proxy_motion(enemy_position, enemy_velocity)


@rpc("authority", "call_remote", "unreliable_ordered", 2)
func _rpc_receive_player_snapshot(host_timestamp: float, data: PackedByteArray) -> void:
	if game == null:
		return
	if not is_client_view_runtime():
		return
	var snapshot_time := _map_host_timestamp_to_client_time(host_timestamp)
	var states := snapshot_mgr.decode_player_snapshots_with_baseline(data)
	var snapshot_has_full_roster := _is_complete_player_snapshot_batch(data, states.size())
	var seen_player_ids: Dictionary = {}
	for state in states:
		var player_state := state as SnapshotManager.PlayerState
		if player_state == null:
			continue
		if player_state.peer_id <= 0:
			continue
		seen_player_ids[player_state.peer_id] = true
		if is_client_view_runtime() and player_state.peer_id == _get_client_view_local_peer_id():
			continue
		if not player_visual_interpolators.has(player_state.peer_id):
			player_visual_interpolators[player_state.peer_id] = _create_player_interpolator()
		var interp := player_visual_interpolators[player_state.peer_id] as NetInterpolator
		interp.push_snapshot(
			snapshot_time,
			player_state.position,
			player_state.velocity,
			player_state.facing,
			player_state.anim_state,
			0,
			false
		)
		var player_node: Player = game.get_player_for_peer(player_state.peer_id)
		if player_node != null and is_instance_valid(player_node):
			player_node.apply_multiplayer_realtime_state(
				player_state.current_health,
				player_state.max_health,
				player_state.current_xirang,
				player_state.is_dead,
				player_state.invincibility_time_left,
				player_state.skill1_unlocked,
				player_state.skill1_charge,
				player_state.skill1_charge_duration,
				player_state.form_mode,
				player_state.shot_pattern,
				player_state.skill1_upgrade_level
			)
	if snapshot_has_full_roster:
		_reconcile_player_roster(seen_player_ids)


func _is_complete_player_snapshot_batch(data: PackedByteArray, decoded_count: int) -> bool:
	if data.is_empty():
		return false
	var expected_count := int(data[0])
	return expected_count > 0 and decoded_count == expected_count


func _reconcile_player_roster(seen_player_ids: Dictionary) -> void:
	if game == null or seen_player_ids.is_empty():
		return
	if int(game.runtime_mode) != GAME_RUNTIME_CLIENT_VIEW:
		return
	var local_peer_id := _get_local_peer_id()
	if local_peer_id <= 0:
		local_peer_id = game.multiplayer_local_peer_id
	for peer_id_variant in game.peer_players.keys():
		var peer_id := int(peer_id_variant)
		if peer_id == local_peer_id:
			continue
		if seen_player_ids.has(peer_id):
			continue
		_clear_peer_network_state(peer_id)
		game.remove_multiplayer_player(peer_id)


@rpc("authority", "call_remote", "unreliable_ordered", 2)
func _rpc_receive_enemy_snapshot(host_timestamp: float, data: PackedByteArray) -> void:
	if game == null:
		return
	if not is_client_view_runtime():
		return
	var snapshot_time := _map_host_timestamp_to_client_time(host_timestamp)
	var states := snapshot_mgr.decode_enemy_snapshots_with_baseline(data)
	var snapshot_has_full_roster := _is_complete_enemy_snapshot_batch(data, states.size())
	var seen_enemy_ids: Dictionary = {}
	for state in states:
		var enemy_state := state as SnapshotManager.EnemyState
		if enemy_state == null:
			continue
		if enemy_state.net_id <= 0:
			continue
		seen_enemy_ids[enemy_state.net_id] = true
		if enemy_state.is_dead:
			var dead_enemy: Enemy = _get_valid_client_enemy_for_net_id(enemy_state.net_id)
			if dead_enemy != null and is_instance_valid(dead_enemy):
				dead_enemy.global_position = enemy_state.position
				_apply_enemy_network_health(dead_enemy, enemy_state.health)
			_remove_client_enemy(enemy_state.net_id, true)
			continue
		if not enemy_interpolators.has(enemy_state.net_id):
			enemy_interpolators[enemy_state.net_id] = _create_enemy_interpolator()
		var interp := enemy_interpolators[enemy_state.net_id] as NetInterpolator
		interp.push_snapshot(
			snapshot_time,
			enemy_state.position,
			enemy_state.velocity,
			0,
			0,
			enemy_state.health,
			enemy_state.is_dead
		)
		var enemy_node: Enemy = _get_valid_client_enemy_for_net_id(enemy_state.net_id)
		if enemy_node != null and is_instance_valid(enemy_node):
			_apply_enemy_network_health(enemy_node, enemy_state.health)
			enemy_node.is_dead = enemy_state.is_dead
	if snapshot_has_full_roster:
		_reconcile_enemy_roster(seen_enemy_ids, snapshot_time)


func _is_complete_enemy_snapshot_batch(data: PackedByteArray, decoded_count: int) -> bool:
	if data.size() < 2:
		return false
	var stream := StreamPeerBuffer.new()
	stream.data_array = data
	var expected_count := stream.get_u16()
	return decoded_count == expected_count


func _apply_enemy_network_health(enemy_node: Enemy, current_health: int) -> void:
	if enemy_node == null:
		return
	if enemy_node.has_method("apply_multiplayer_health_snapshot"):
		enemy_node.call("apply_multiplayer_health_snapshot", current_health)
	else:
		enemy_node.current_health = current_health


@rpc("any_peer", "call_remote", "unreliable_ordered", 1)
func _rpc_client_player_state(
	sequence: int,
	reported_position: Vector2,
	reported_velocity: Vector2,
	shoot_input: Vector2,
	buttons: int,
	current_health: int,
	max_health: int,
	current_xirang: int,
	is_dead: bool,
	invincibility_time_left: float,
	skill1_unlocked: bool,
	skill1_charge: float,
	skill1_charge_duration: float,
	form_mode: int,
	shot_pattern: int
) -> void:
	if not net_manager.is_host() or game == null:
		return
	var sender_id := multiplayer.get_remote_sender_id()
	if sender_id <= 0:
		return
	var player_node := game.get_player_for_peer(sender_id)
	if player_node == null or not is_instance_valid(player_node):
		return
	if player_node.is_dead or player_node.controls_locked:
		net_player_state_corrected.rpc_id(sender_id, player_node.global_position, player_node.velocity)
		return
	if is_dead or current_health <= 0:
		net_player_state_corrected.rpc_id(sender_id, player_node.global_position, player_node.velocity)
		return
	if not _accept_client_player_state(sender_id, sequence, reported_position, reported_velocity):
		net_player_state_corrected.rpc_id(sender_id, player_node.global_position, player_node.velocity)
		return
	var use_skill1: bool = (buttons & INPUT_BUTTON_SKILL1) != 0
	_apply_accepted_client_player_state(
		sender_id,
		player_node,
		reported_position,
		reported_velocity,
		shoot_input,
		use_skill1
	)


func _apply_accepted_client_player_state(
	sender_id: int,
	player_node: Player,
	reported_position: Vector2,
	reported_velocity: Vector2,
	shoot_input: Vector2,
	use_skill1: bool
) -> void:
	if sender_id <= 0 or player_node == null or not is_instance_valid(player_node):
		return
	player_node.apply_remote_multiplayer_state(
		reported_position,
		reported_velocity,
		shoot_input,
		use_skill1
	)
	_remember_latest_client_player_snapshot_state(
		sender_id,
		reported_position,
		reported_velocity,
		player_node.get_multiplayer_facing_id(),
		player_node.get_multiplayer_anim_state()
	)

@rpc("authority", "call_remote", "reliable", 4)
func net_player_state_corrected(corrected_position: Vector2, corrected_velocity: Vector2) -> void:
	if game == null or game.player == null:
		return
	game.player.global_position = corrected_position
	game.player.velocity = corrected_velocity


func _reset_player_visual_interpolator_to_state(
	peer_id: int,
	player_position: Vector2,
	player_velocity: Vector2,
	facing_id: int,
	anim_state: int
) -> void:
	if peer_id <= 0:
		return
	if not player_visual_interpolators.has(peer_id):
		player_visual_interpolators[peer_id] = _create_player_interpolator()
	var interp: NetInterpolator = player_visual_interpolators[peer_id] as NetInterpolator
	if interp == null:
		return
	interp.clear()
	interp.push_snapshot(
		_get_net_time(),
		player_position,
		player_velocity,
		facing_id,
		anim_state,
		0,
		false
	)


func _remember_latest_client_player_snapshot_state(
	peer_id: int,
	player_position: Vector2,
	player_velocity: Vector2,
	facing_id: int,
	anim_state: int
) -> void:
	if not net_manager.is_host() or peer_id <= 0:
		return
	_host_latest_client_player_snapshot_states[peer_id] = {
		"position": player_position,
		"velocity": player_velocity,
		"facing": facing_id,
		"anim_state": anim_state,
	}


func _accept_client_player_state(
	peer_id: int,
	sequence: int,
	reported_position: Vector2,
	reported_velocity: Vector2
) -> bool:
	var last_sequence := int(_last_player_state_sequences.get(peer_id, 0))
	if sequence <= last_sequence:
		return false
	_last_player_state_sequences[peer_id] = sequence
	if not _is_finite_vector2(reported_position) or not _is_finite_vector2(reported_velocity):
		return false
	var now := _get_net_time()
	if not _accepted_player_state_positions.has(peer_id):
		_accepted_player_state_positions[peer_id] = reported_position
		_accepted_player_state_times[peer_id] = now
		return true
	var previous_position := _accepted_player_state_positions[peer_id] as Vector2
	if previous_position.distance_to(reported_position) > PLAYER_STATE_MAX_ACCEPTED_JUMP_DISTANCE:
		return false
	_accepted_player_state_positions[peer_id] = reported_position
	_accepted_player_state_times[peer_id] = now
	return true

func register_local_projectile(
	projectile: Node,
	projectile_type: StringName,
	owner_peer_id: int,
	spawn_position: Vector2,
	direction: Vector2,
	damage: int,
	speed: float,
	lifetime: float,
	pierces_enemies: bool = false,
	target_peer_id: int = 0
) -> void:
	if projectile == null:
		return
	if net_manager == null or not net_manager.is_multiplayer_active():
		return
	var projectile_namespace: int = owner_peer_id
	if projectile_namespace <= 0:
		projectile_namespace = 999999
	var projectile_id := projectile_namespace * 1000000 + _next_projectile_id
	_next_projectile_id += 1
	_setup_projectile_network_identity(projectile, projectile_id, owner_peer_id, projectile_type)
	_known_projectiles[projectile_id] = projectile
	var host_fire_timestamp := _get_net_time()
	_remember_projectile_record(
		projectile_id,
		owner_peer_id,
		projectile_type,
		damage,
		lifetime,
		pierces_enemies
	)
	if net_manager.is_host():
		_rpc_to_connected_clients(
			&"net_projectile_fired",
			[
				projectile_id,
				String(projectile_type),
				owner_peer_id,
				spawn_position,
				direction,
				damage,
				speed,
				lifetime,
				pierces_enemies,
				target_peer_id,
				host_fire_timestamp,
			]
		)
	else:
		_rpc_projectile_fired_from_client.rpc_id(
			_get_host_peer_id(),
			projectile_id,
			String(projectile_type),
			owner_peer_id,
			spawn_position,
			direction,
			damage,
			speed,
			lifetime,
			pierces_enemies,
			target_peer_id,
			host_fire_timestamp
		)


@rpc("any_peer", "call_remote", "unreliable_ordered", 3)
func _rpc_projectile_fired_from_client(
	projectile_id: int,
	projectile_type: String,
	owner_peer_id: int,
	spawn_position: Vector2,
	direction: Vector2,
	damage: int,
	speed: float,
	lifetime: float,
	pierces_enemies: bool = false,
	target_peer_id: int = 0,
	_client_fire_timestamp: float = -1.0
) -> void:
	if not net_manager.is_host():
		return
	var sender_id := multiplayer.get_remote_sender_id()
	if sender_id <= 0 or owner_peer_id != sender_id:
		return
	if _known_projectiles.has(projectile_id):
		return
	if not _is_projectile_id_valid_for_owner(projectile_id, owner_peer_id):
		return
	var accepted_direction := _get_valid_client_projectile_direction(direction)
	if accepted_direction == Vector2.ZERO:
		return
	if not _is_client_projectile_spawn_position_allowed(
		StringName(projectile_type),
		owner_peer_id,
		spawn_position
	):
		return
	var accepted_parameters := _get_authoritative_client_projectile_parameters(
		StringName(projectile_type),
		owner_peer_id
	)
	if accepted_parameters.is_empty():
		return
	var accepted_damage := int(accepted_parameters["damage"])
	var accepted_speed := float(accepted_parameters["speed"])
	var accepted_lifetime := float(accepted_parameters["lifetime"])
	var accepted_pierces_enemies := (
		pierces_enemies
		and bool(accepted_parameters.get("can_pierce_enemies", false))
	)
	var host_fire_timestamp := _get_net_time()
	_rpc_to_connected_clients(
		&"net_projectile_fired",
		[
			projectile_id,
			projectile_type,
			owner_peer_id,
			spawn_position,
			accepted_direction,
			accepted_damage,
			accepted_speed,
			accepted_lifetime,
			accepted_pierces_enemies,
			target_peer_id,
			host_fire_timestamp,
		]
	)
	net_projectile_fired(
		projectile_id,
		projectile_type,
		owner_peer_id,
		spawn_position,
		accepted_direction,
		accepted_damage,
		accepted_speed,
		accepted_lifetime,
		accepted_pierces_enemies,
		target_peer_id,
		host_fire_timestamp
	)


@rpc("authority", "call_remote", "unreliable_ordered", 3)
func net_projectile_fired(
	projectile_id: int,
	projectile_type: String,
	owner_peer_id: int,
	spawn_position: Vector2,
	direction: Vector2,
	damage: int,
	speed: float,
	lifetime: float,
	pierces_enemies: bool = false,
	target_peer_id: int = 0,
	host_fire_timestamp: float = -1.0
) -> void:
	if _known_projectiles.has(projectile_id):
		return
	_spawn_network_projectile(
		projectile_id,
		StringName(projectile_type),
		owner_peer_id,
		spawn_position,
		direction,
		damage,
		speed,
		lifetime,
		pierces_enemies,
		target_peer_id,
		host_fire_timestamp
	)


func _spawn_network_projectile(
	projectile_id: int,
	projectile_type: StringName,
	owner_peer_id: int,
	spawn_position: Vector2,
	direction: Vector2,
	damage: int,
	speed: float,
	lifetime: float,
	pierces_enemies: bool = false,
	target_peer_id: int = 0,
	host_fire_timestamp: float = -1.0
) -> void:
	var projectile := _instantiate_projectile(
		projectile_type,
		owner_peer_id,
		direction,
		damage,
		speed,
		lifetime,
		pierces_enemies,
		target_peer_id
	)
	if projectile == null:
		return
	_setup_projectile_network_identity(projectile, projectile_id, owner_peer_id, projectile_type)
	_known_projectiles[projectile_id] = projectile
	var compensation_age := _get_projectile_time_compensation_age(host_fire_timestamp, lifetime)
	_remember_projectile_record(
		projectile_id,
		owner_peer_id,
		projectile_type,
		damage,
		lifetime,
		pierces_enemies
	)
	add_child(projectile)
	projectile.global_position = (
		spawn_position
		+ direction.normalized() * maxf(speed, 0.0) * compensation_age
	)
	_apply_projectile_lifetime_compensation(projectile, lifetime, compensation_age)


func _get_projectile_time_compensation_age(host_fire_timestamp: float, lifetime: float) -> float:
	if host_fire_timestamp < 0.0:
		return 0.0
	var mapped_fire_time := host_fire_timestamp
	if net_manager == null or not net_manager.is_host():
		mapped_fire_time = _map_host_timestamp_to_client_time(host_fire_timestamp, false)
	var age := _get_net_time() - mapped_fire_time
	return clampf(age, 0.0, minf(PROJECTILE_TIME_COMPENSATION_MAX_SECONDS, maxf(lifetime, 0.0)))


func _apply_projectile_lifetime_compensation(
	projectile: Node,
	lifetime: float,
	compensation_age: float
) -> void:
	if projectile == null or compensation_age <= 0.0:
		return
	var remaining := maxf(lifetime - compensation_age, 0.05)
	var bullet := projectile as Bullet
	if bullet != null:
		bullet.remaining_lifetime = remaining
		return
	if projectile != null and projectile.get_script() == COLLECTIBLE_ARROW_PROJECTILE_SCRIPT:
		projectile.set("remaining_lifetime", remaining)
		return
	var bomb := projectile as WeishidaierSkill1Bomb
	if bomb != null:
		bomb.remaining_lifetime = remaining
		return
	var capoo_bullet := projectile as CapooAK47Bullet
	if capoo_bullet != null:
		capoo_bullet.remaining_lifetime = remaining
		return
	var rpg_rocket := projectile as CapooRPGRocket
	if rpg_rocket != null:
		rpg_rocket.remaining_lifetime = remaining
		return
	var fireball := projectile as CapooMageFireball
	if fireball != null:
		fireball.remaining_lifetime = remaining
		return
	var fire_projectile := projectile as YuanshiInsectFireProjectile
	if fire_projectile != null:
		fire_projectile.remaining_lifetime = remaining
		return
	var sakura_bullet := projectile as LinglanSakuraBullet
	if sakura_bullet != null:
		sakura_bullet.remaining_lifetime = remaining
		return
	var sakura_rocket := projectile as LinglanSkill2SakuraRocket
	if sakura_rocket != null:
		sakura_rocket.remaining_lifetime = remaining
		return
	if projectile != null and projectile.get_script() == LINGLAN_SKILL4_ORB_SCRIPT:
		projectile.set("remaining_lifetime", remaining)
		return


func _instantiate_projectile(
	projectile_type: StringName,
	owner_peer_id: int,
	direction: Vector2,
	damage: int,
	speed: float,
	lifetime: float,
	pierces_enemies: bool = false,
	target_peer_id: int = 0
) -> Node:
	match projectile_type:
		&"player_bullet":
			var bullet := BULLET_SCENE.instantiate() as Bullet
			if bullet == null:
				return null
			bullet.top_level = true
			bullet.setup(direction, damage, pierces_enemies)
			if pierces_enemies:
				bullet.modulate = Player.PIERCING_BULLET_TINT
			bullet.speed = speed
			bullet.max_lifetime = lifetime
			bullet.remaining_lifetime = lifetime
			return bullet
		&"collectible_arrow":
			var collectible_arrow := COLLECTIBLE_ARROW_PROJECTILE_SCENE.instantiate()
			if collectible_arrow == null:
				return null
			collectible_arrow.top_level = true
			collectible_arrow.call("setup", direction, damage)
			collectible_arrow.set("speed", speed)
			collectible_arrow.set("max_lifetime", lifetime)
			collectible_arrow.set("remaining_lifetime", lifetime)
			return collectible_arrow
		&"skill1_bomb":
			var bomb := SKILL1_BOMB_SCENE.instantiate() as WeishidaierSkill1Bomb
			if bomb == null:
				return null
			bomb.top_level = true
			bomb.setup(game.get_player_for_peer(owner_peer_id), direction, damage)
			bomb.speed = speed
			bomb.max_lifetime = lifetime
			bomb.remaining_lifetime = lifetime
			return bomb
		&"capoo_ak47_bullet":
			var capoo_bullet := CAPOO_AK47_BULLET_SCENE.instantiate() as CapooAK47Bullet
			if capoo_bullet == null:
				return null
			capoo_bullet.top_level = true
			capoo_bullet.setup(direction, damage, speed, lifetime)
			return capoo_bullet
		&"capoo_rpg_rocket":
			var rpg_rocket := CAPOO_RPG_ROCKET_SCENE.instantiate() as CapooRPGRocket
			if rpg_rocket == null:
				return null
			rpg_rocket.top_level = true
			rpg_rocket.setup(direction, damage, speed, lifetime)
			return rpg_rocket
		&"capoo_mage_fireball":
			var fireball := CAPOO_MAGE_FIREBALL_SCENE.instantiate() as CapooMageFireball
			if fireball == null:
				return null
			fireball.top_level = true
			fireball.setup(direction, damage, speed, lifetime)
			return fireball
		&"capoo_smg_bullet":
			var smg_bullet := CAPOO_SMG_BULLET_SCENE.instantiate() as CapooAK47Bullet
			if smg_bullet == null:
				return null
			smg_bullet.top_level = true
			smg_bullet.setup(direction, damage, speed, lifetime)
			return smg_bullet
		&"yuanshi_fire_projectile":
			var fire_projectile := YUANSHI_FIRE_PROJECTILE_SCENE.instantiate() as YuanshiInsectFireProjectile
			if fire_projectile == null:
				return null
			fire_projectile.top_level = true
			fire_projectile.setup(direction, damage, speed, lifetime)
			return fire_projectile
		&"linglan_skill1":
			var sakura_bullet := LINGLAN_SAKURA_BULLET_SCENE.instantiate() as LinglanSakuraBullet
			if sakura_bullet == null:
				return null
			sakura_bullet.top_level = true
			sakura_bullet.setup(direction, damage, speed, lifetime)
			return sakura_bullet
		&"linglan_skill2_rocket":
			var sakura_rocket := LINGLAN_SKILL2_ROCKET_SCENE.instantiate() as LinglanSkill2SakuraRocket
			if sakura_rocket == null:
				return null
			sakura_rocket.top_level = true
			var rocket_target: Player = null
			if game != null and target_peer_id > 0:
				rocket_target = game.get_player_for_peer(target_peer_id)
			sakura_rocket.setup(
				direction,
				damage,
				speed,
				lifetime,
				_linglan_skill2_config.rocket_explosion_radius,
				rocket_target,
				_linglan_skill2_config.rocket_homing_turn_rate
			)
			return sakura_rocket
		&"linglan_skill3_orb":
			var light_orb := LINGLAN_SKILL3_ORB_SCENE.instantiate() as LinglanSkill3LightOrb
			if light_orb == null:
				return null
			light_orb.top_level = true
			light_orb.setup(
				direction,
				damage,
				speed,
				lifetime,
				_linglan_skill3_config.orb_base_radius,
				_linglan_skill3_config.orb_grow_scale,
				_linglan_skill3_config.orb_expanded_hold_duration,
				_linglan_skill3_config.orb_flash_lead_time
			)
			return light_orb
		&"linglan_skill4_orb":
			var skill4_orb := LINGLAN_SKILL4_ORB_SCENE.instantiate() as Node2D
			if skill4_orb == null:
				return null
			skill4_orb.top_level = true
			skill4_orb.call(
				"setup",
				direction,
				damage,
				speed,
				lifetime,
				_linglan_skill4_config.orb_radius,
				_linglan_skill4_config.orb_damage_radius
			)
			return skill4_orb
		_:
			return null


func _get_authoritative_client_projectile_parameters(
	projectile_type: StringName,
	owner_peer_id: int
) -> Dictionary:
	var owner_player: Player = null
	if game != null:
		owner_player = game.get_player_for_peer(owner_peer_id)
	if owner_player == null or not is_instance_valid(owner_player):
		return {}
	match projectile_type:
		&"player_bullet":
			var bullet := BULLET_SCENE.instantiate() as Bullet
			if bullet == null:
				return {}
			var bullet_result := {
				"damage": owner_player.get_outgoing_damage(
					owner_player.attack_damage,
					EnemyConfig.DamageType.PHYSICAL
				),
				"speed": bullet.speed,
				"lifetime": bullet.max_lifetime,
				"can_pierce_enemies": owner_player._get_inventory_bullet_pierce_chance() > 0.0,
			}
			bullet.free()
			return bullet_result
		&"skill1_bomb":
			if not owner_player.consume_multiplayer_skill1_charge():
				return {}
			owner_player.activate_collectible_skill_effects_from_multiplayer()
			var bomb := SKILL1_BOMB_SCENE.instantiate() as WeishidaierSkill1Bomb
			if bomb == null:
				return {}
			var bomb_result := {
				"damage": owner_player.get_skill1_bomb_damage(),
				"speed": bomb.speed,
				"lifetime": bomb.max_lifetime,
			}
			bomb.free()
			return bomb_result
		&"collectible_arrow":
			var arrow_damage := _get_authoritative_collectible_arrow_damage(owner_player)
			if arrow_damage <= 0:
				return {}
			var arrow := COLLECTIBLE_ARROW_PROJECTILE_SCENE.instantiate()
			if arrow == null:
				return {}
			var arrow_result := {
				"damage": arrow_damage,
				"speed": float(arrow.get("speed")),
				"lifetime": float(arrow.get("max_lifetime")),
			}
			arrow.free()
			return arrow_result
		_:
			return {}


func _get_authoritative_collectible_arrow_damage(owner_player: Player) -> int:
	if owner_player == null or not is_instance_valid(owner_player):
		return -1
	var active_items_variant: Variant = owner_player.call("_get_active_collectible_items")
	if not (active_items_variant is Array):
		return -1

	var best_damage := -1
	for item_variant in active_items_variant:
		var item := item_variant as PickupConfig
		if item == null:
			continue
		if item.periodic_effect_id != PickupConfig.PERIODIC_EFFECT_ARCHER:
			continue
		var damage_multiplier := maxf(item.periodic_attack_damage_multiplier, 0.0)
		if damage_multiplier <= 0.0:
			damage_multiplier = 1.0
		var arrow_damage := owner_player.get_outgoing_damage(
			maxi(roundi(float(owner_player.attack_damage) * damage_multiplier), 1),
			EnemyConfig.DamageType.PHYSICAL
		)
		best_damage = maxi(best_damage, arrow_damage)
	return best_damage


func _remember_projectile_record(
	projectile_id: int,
	owner_peer_id: int,
	projectile_type: StringName,
	damage: int,
	lifetime: float,
	pierces_enemies: bool = false
) -> void:
	if projectile_id <= 0:
		return
	_projectile_records[projectile_id] = {
		"owner_peer_id": owner_peer_id,
		"projectile_type": projectile_type,
		"damage": maxi(damage, 0),
		"pierces_enemies": pierces_enemies,
		"expires_at": _get_net_time() + maxf(lifetime, 0.0) + PROJECTILE_RECORD_RETENTION_SECONDS,
	}


func _get_authoritative_projectile_damage(
	projectile_id: int,
	owner_peer_id: int,
	reported_damage: int
) -> int:
	if not _is_projectile_id_valid_for_owner(projectile_id, owner_peer_id):
		return -1
	var record_variant: Variant = _projectile_records.get(projectile_id)
	if record_variant != null:
		var record := record_variant as Dictionary
		if record.is_empty():
			return -1
		if int(record.get("owner_peer_id", 0)) != owner_peer_id:
			return -1
		return int(record.get("damage", -1))
	return _get_bounded_player_projectile_damage(owner_peer_id, reported_damage)


func _get_bounded_player_projectile_damage(owner_peer_id: int, reported_damage: int) -> int:
	if reported_damage <= 0:
		return -1
	var owner_player: Player = null
	if game != null:
		owner_player = game.get_player_for_peer(owner_peer_id)
	if owner_player == null or not is_instance_valid(owner_player):
		return -1
	var max_authoritative_damage := owner_player.get_outgoing_damage(
		owner_player.attack_damage,
		EnemyConfig.DamageType.PHYSICAL
	)
	if owner_player.has_skill1():
		max_authoritative_damage = maxi(
			max_authoritative_damage,
			owner_player.get_skill1_bomb_damage()
		)
	return clampi(reported_damage, 1, max_authoritative_damage)


func _is_projectile_id_valid_for_owner(projectile_id: int, owner_peer_id: int) -> bool:
	if projectile_id <= 0 or owner_peer_id <= 0:
		return false
	var projectile_namespace := floori(float(projectile_id) / float(PROJECTILE_ID_NAMESPACE_SIZE))
	return projectile_namespace == owner_peer_id


func _get_valid_client_projectile_direction(direction: Vector2) -> Vector2:
	if not _is_finite_vector2(direction):
		return Vector2.ZERO
	var direction_length := direction.length()
	if (
		direction_length < CLIENT_PROJECTILE_DIRECTION_MIN_LENGTH
		or direction_length > CLIENT_PROJECTILE_DIRECTION_MAX_LENGTH
	):
		return Vector2.ZERO
	return direction / direction_length


func _is_client_projectile_spawn_position_allowed(
	projectile_type: StringName,
	owner_peer_id: int,
	spawn_position: Vector2
) -> bool:
	if not _is_finite_vector2(spawn_position):
		return false
	var owner_player: Player = null
	if game != null:
		owner_player = game.get_player_for_peer(owner_peer_id)
	if owner_player == null or not is_instance_valid(owner_player):
		return false
	var allowed_distance := CLIENT_PROJECTILE_SPAWN_POSITION_TOLERANCE
	match projectile_type:
		&"player_bullet":
			allowed_distance += owner_player.bullet_spawn_distance
		&"skill1_bomb":
			allowed_distance += owner_player.skill1_bomb_spawn_distance
		_:
			return false
	if owner_player.global_position.distance_to(spawn_position) <= allowed_distance:
		return true
	if _accepted_player_state_positions.has(owner_peer_id):
		var accepted_position := _accepted_player_state_positions[owner_peer_id] as Vector2
		if accepted_position.distance_to(spawn_position) <= allowed_distance:
			return true
	return false


func _is_finite_vector2(value: Vector2) -> bool:
	return is_finite(value.x) and is_finite(value.y)


func _prune_projectile_records(now: float) -> void:
	var expired_projectile_ids: Array[int] = []
	for projectile_id_variant in _projectile_records.keys():
		var projectile_id := int(projectile_id_variant)
		var record := _projectile_records[projectile_id] as Dictionary
		if record.is_empty() or float(record.get("expires_at", 0.0)) <= now:
			expired_projectile_ids.append(projectile_id)
	for projectile_id in expired_projectile_ids:
		_projectile_records.erase(projectile_id)


func _setup_projectile_network_identity(
	projectile: Node,
	projectile_id: int,
	owner_peer_id: int,
	projectile_type: StringName
) -> void:
	if projectile.has_method("setup_multiplayer"):
		projectile.call("setup_multiplayer", projectile_id, owner_peer_id, projectile_type)
	projectile.tree_exited.connect(_on_network_projectile_tree_exited.bind(projectile_id))


func _on_network_projectile_tree_exited(projectile_id: int) -> void:
	_known_projectiles.erase(projectile_id)


func _update_recent_event_cache_prune(delta: float) -> void:
	_recent_event_prune_time_left = maxf(_recent_event_prune_time_left - delta, 0.0)
	if _recent_event_prune_time_left > 0.0:
		return
	_recent_event_prune_time_left = RECENT_EVENT_PRUNE_INTERVAL_SECONDS
	_prune_recent_event_caches(_get_net_time())


func _prune_recent_event_caches(now: float) -> void:
	_prune_recent_event_cache(_processed_enemy_hit_ids, now)
	_prune_recent_event_cache(_processed_player_hit_ids, now)
	_prune_recent_event_cache(_collected_xirang_orbs, now)
	_prune_recent_event_cache(_granted_xirang_orbs, now)
	_prune_projectile_records(now)


func _prune_recent_event_cache(cache: Dictionary, now: float) -> void:
	var expired_keys: Array = []
	for key in cache:
		if float(cache[key]) <= now:
			expired_keys.append(key)
	for key in expired_keys:
		cache.erase(key)


func _is_recent_event_cached(cache: Dictionary, key: Variant, now: float) -> bool:
	var expires_at_variant: Variant = cache.get(key)
	if expires_at_variant == null:
		return false
	var expires_at := float(expires_at_variant)
	if expires_at > now:
		return true
	cache.erase(key)
	return false


func _remember_recent_event(
	cache: Dictionary,
	key: Variant,
	retention_seconds: float,
	now: float
) -> void:
	cache[key] = now + retention_seconds


func request_enemy_hit_report(
	projectile_id: int,
	owner_peer_id: int,
	enemy_net_id: int,
	damage: int,
	impact_direction: Vector2
) -> void:
	if net_manager.is_host():
		_apply_enemy_hit_report(projectile_id, owner_peer_id, enemy_net_id, damage, impact_direction)
	else:
		_rpc_enemy_hit_report.rpc_id(
			_get_host_peer_id(),
			projectile_id,
			owner_peer_id,
			enemy_net_id,
			damage,
			impact_direction
		)


func apply_multiplayer_collectible_enemy_damage(
	enemy: Enemy,
	damage: int,
	impact_direction: Vector2,
	damage_type: int = EnemyConfig.DamageType.MAGIC
) -> bool:
	if net_manager == null or not net_manager.is_host():
		return false
	if enemy == null or not is_instance_valid(enemy):
		return false
	var enemy_net_id := int(enemy.get_meta("net_id", 0))
	if enemy_net_id <= 0:
		return enemy.apply_damage(damage, impact_direction, damage_type as EnemyConfig.DamageType)
	return _apply_confirmed_enemy_damage(
		enemy_net_id,
		enemy,
		damage,
		impact_direction,
		damage_type as EnemyConfig.DamageType
	)


@rpc("any_peer", "call_remote", "reliable", 4)
func _rpc_enemy_hit_report(
	projectile_id: int,
	owner_peer_id: int,
	enemy_net_id: int,
	damage: int,
	impact_direction: Vector2
) -> void:
	if not net_manager.is_host():
		return
	var sender_id := multiplayer.get_remote_sender_id()
	if sender_id > 0 and owner_peer_id != sender_id:
		return
	_apply_enemy_hit_report(projectile_id, owner_peer_id, enemy_net_id, damage, impact_direction)


func _apply_enemy_hit_report(
	projectile_id: int,
	owner_peer_id: int,
	enemy_net_id: int,
	reported_damage: int,
	impact_direction: Vector2
) -> void:
	if projectile_id <= 0 or owner_peer_id <= 0 or enemy_net_id <= 0:
		return
	if not _is_projectile_id_valid_for_owner(projectile_id, owner_peer_id):
		return
	var authoritative_damage := _get_authoritative_projectile_damage(
		projectile_id,
		owner_peer_id,
		reported_damage
	)
	if authoritative_damage <= 0:
		return
	var hit_key := "%d:%d" % [projectile_id, enemy_net_id]
	var now := _get_net_time()
	if _is_recent_event_cached(_processed_enemy_hit_ids, hit_key, now):
		return
	var enemy := _get_host_enemy_for_net_id(enemy_net_id)
	if enemy == null or not is_instance_valid(enemy):
		return
	if not _apply_confirmed_enemy_damage(
		enemy_net_id,
		enemy,
		authoritative_damage,
		impact_direction,
		EnemyConfig.DamageType.PHYSICAL
	):
		return
	_remember_recent_event(_processed_enemy_hit_ids, hit_key, HIT_DEDUP_RETENTION_SECONDS, now)


func _apply_confirmed_enemy_damage(
	enemy_net_id: int,
	enemy: Enemy,
	damage: int,
	impact_direction: Vector2,
	damage_type: EnemyConfig.DamageType
) -> bool:
	if enemy_net_id <= 0 or enemy == null or not is_instance_valid(enemy):
		return false
	if not enemy.apply_damage(damage, impact_direction, damage_type):
		return false
	var confirmed_damage := enemy.last_damage_taken
	if is_inside_tree():
		_rpc_to_connected_clients(
			&"net_enemy_damage_applied",
			[
				enemy_net_id,
				enemy.current_health,
				enemy.is_dead,
				confirmed_damage,
				impact_direction,
				int(damage_type),
			]
		)
	return true


@rpc("authority", "call_remote", "reliable", 4)
func net_enemy_damage_applied(
	enemy_net_id: int,
	current_health: int,
	is_dead: bool,
	confirmed_damage: int,
	impact_direction: Vector2,
	damage_type: int = EnemyConfig.DamageType.PHYSICAL
) -> void:
	var enemy := _get_client_enemy_for_net_id(enemy_net_id)
	if enemy == null or not is_instance_valid(enemy):
		return
	_apply_enemy_network_health(enemy, current_health)
	enemy.show_damage_number(
		confirmed_damage,
		impact_direction,
		damage_type as EnemyConfig.DamageType
	)
	if impact_direction != Vector2.ZERO:
		enemy.play_multiplayer_damage_feedback(impact_direction)
	if is_dead:
		_remove_client_enemy(enemy_net_id, true)


func _next_player_hit_revision() -> int:
	_local_player_hit_revision += 1
	return _local_player_hit_revision


func request_multiplayer_player_damage(
	source_id: int,
	target_peer_id: int,
	damage: int,
	source_type: StringName,
	damage_type_or_source_direction: Variant = EnemyConfig.DamageType.PHYSICAL,
	source_direction_or_is_ranged: Variant = Vector2.ZERO,
	is_ranged: bool = false
) -> bool:
	if source_id <= 0 or target_peer_id <= 0 or damage <= 0:
		return false
	var resolved_damage_type: EnemyConfig.DamageType = EnemyConfig.DamageType.PHYSICAL
	var source_direction := Vector2.ZERO
	var resolved_is_ranged := is_ranged
	if damage_type_or_source_direction is Vector2:
		source_direction = damage_type_or_source_direction as Vector2
		if source_direction_or_is_ranged is bool:
			resolved_is_ranged = bool(source_direction_or_is_ranged)
	elif damage_type_or_source_direction is int:
		resolved_damage_type = int(damage_type_or_source_direction) as EnemyConfig.DamageType
		if source_direction_or_is_ranged is Vector2:
			source_direction = source_direction_or_is_ranged as Vector2
		elif source_direction_or_is_ranged is bool:
			resolved_is_ranged = bool(source_direction_or_is_ranged)
	var damage_context := _build_player_damage_context(source_direction, resolved_is_ranged)
	var hit_key := "%d:%d:%s" % [source_id, target_peer_id, String(source_type)]
	var now := _get_net_time()
	var player_node: Player = null
	if game != null:
		player_node = game.get_player_for_peer(target_peer_id)
	if player_node == null or not is_instance_valid(player_node):
		return false
	if _is_recent_event_cached(_processed_player_hit_ids, hit_key, now):
		return true
	if net_manager.is_client():
		if target_peer_id != _get_local_peer_id():
			return true
		if player_node.is_dead:
			return true
		if player_node.apply_damage(damage, resolved_damage_type, damage_context):
			_remember_recent_event(_processed_player_hit_ids, hit_key, HIT_DEDUP_RETENTION_SECONDS, now)
			request_player_hit_report(
				source_id,
				target_peer_id,
				damage,
				source_type,
				player_node.current_health,
				player_node.is_dead
			)
		return true
	if net_manager.is_host():
		if player_node.is_dead:
			return true
		if player_node.apply_damage(damage, resolved_damage_type, damage_context):
			_apply_player_hit_report(
				source_id,
				target_peer_id,
				damage,
				source_type,
				player_node.current_health,
				player_node.is_dead,
				_next_player_hit_revision()
			)
		return true
	return false


func _build_player_damage_context(source_direction: Vector2, is_ranged: bool) -> Dictionary:
	if not is_ranged:
		return {}
	return {
		"is_ranged": true,
		"source_direction": source_direction.normalized() if source_direction != Vector2.ZERO else Vector2.ZERO,
	}


func request_player_hit_report(
	source_id: int,
	player_peer_id: int,
	damage: int,
	source_type: StringName,
	reported_health_after: int,
	reported_is_dead: bool
) -> void:
	var hit_revision := _next_player_hit_revision()
	if net_manager.is_host():
		_apply_player_hit_report(
			source_id,
			player_peer_id,
			damage,
			source_type,
			reported_health_after,
			reported_is_dead,
			hit_revision
		)
	else:
		_rpc_player_hit_report.rpc_id(
			_get_host_peer_id(),
			source_id,
			player_peer_id,
			damage,
			String(source_type),
			reported_health_after,
			reported_is_dead,
			hit_revision
		)


@rpc("any_peer", "call_remote", "reliable", 4)
func _rpc_player_hit_report(
	source_id: int,
	player_peer_id: int,
	damage: int,
	source_type: String,
	reported_health_after: int,
	reported_is_dead: bool,
	hit_revision: int
) -> void:
	if not net_manager.is_host():
		return
	var sender_id := multiplayer.get_remote_sender_id()
	if sender_id > 0 and sender_id != player_peer_id:
		return
	_apply_player_hit_report(
		source_id,
		player_peer_id,
		damage,
		StringName(source_type),
		reported_health_after,
		reported_is_dead,
		hit_revision
	)


func _apply_player_hit_report(
	source_id: int,
	player_peer_id: int,
	damage: int,
	source_type: StringName,
	reported_health_after: int,
	reported_is_dead: bool,
	_hit_revision: int
) -> void:
	if source_id <= 0 or player_peer_id <= 0 or damage <= 0:
		return
	var hit_key := "%d:%d:%s" % [source_id, player_peer_id, String(source_type)]
	var now := _get_net_time()
	if _is_recent_event_cached(_processed_player_hit_ids, hit_key, now):
		return
	var player_node: Player = null
	if game != null:
		player_node = game.get_player_for_peer(player_peer_id)
	if player_node == null or not is_instance_valid(player_node):
		return
	if player_node.is_dead and not reported_is_dead:
		return
	_remember_recent_event(_processed_player_hit_ids, hit_key, HIT_DEDUP_RETENTION_SECONDS, now)
	var confirmed_health := clampi(reported_health_after, 0, player_node.max_health)
	if player_node.current_health > 0:
		confirmed_health = mini(confirmed_health, player_node.current_health)
	var confirmed_dead := reported_is_dead or confirmed_health <= 0
	player_node.set_multiplayer_health_state(confirmed_health, confirmed_dead)
	var health_revision := _next_player_health_revision(player_peer_id)
	if confirmed_dead:
		_schedule_player_revive(player_peer_id)
	_rpc_to_connected_clients(
		&"net_player_damage_applied",
		[player_peer_id, player_node.current_health, player_node.is_dead, health_revision]
	)
	net_player_damage_applied(
		player_peer_id,
		player_node.current_health,
		player_node.is_dead,
		health_revision
	)


@rpc("authority", "call_remote", "reliable", 4)
func net_player_damage_applied(
	player_peer_id: int,
	current_health: int,
	is_dead: bool,
	health_revision: int
) -> void:
	if player_peer_id <= 0:
		return
	var player_node: Player = null
	if game != null:
		player_node = game.get_player_for_peer(player_peer_id)
	if player_node == null or not is_instance_valid(player_node):
		return
	if health_revision <= int(_player_health_revisions.get(player_peer_id, 0)):
		return
	_player_health_revisions[player_peer_id] = health_revision
	player_node.set_multiplayer_health_state(current_health, is_dead)
	if (
		is_client_view_runtime()
		and player_peer_id == _get_client_view_local_peer_id()
		and not player_node.is_dead
		and player_node.current_health < player_node.max_health
	):
		player_node.start_multiplayer_invincibility(player_node.invincibility_duration)


func apply_multiplayer_collectible_player_heal(target_player: Player, heal_amount: int) -> bool:
	if not net_manager.is_host():
		return false
	if target_player == null or not is_instance_valid(target_player):
		return false
	if heal_amount <= 0 or target_player.peer_id <= 0:
		return false
	if not target_player._try_heal(heal_amount):
		return false
	var health_revision := _next_player_health_revision(target_player.peer_id)
	_rpc_to_connected_clients(
		&"net_player_healed",
		[target_player.peer_id, target_player.current_health, health_revision]
	)
	net_player_healed(target_player.peer_id, target_player.current_health, health_revision)
	return true


@rpc("authority", "call_remote", "reliable", 4)
func net_player_healed(peer_id: int, current_health: int, health_revision: int) -> void:
	if peer_id <= 0:
		return
	var player_node: Player = null
	if game != null:
		player_node = game.get_player_for_peer(peer_id)
	if player_node == null or not is_instance_valid(player_node):
		return
	if health_revision <= int(_player_health_revisions.get(peer_id, 0)):
		return
	if player_node.is_dead:
		return
	_player_health_revisions[peer_id] = health_revision
	player_node.set_multiplayer_health_state(current_health, false)


func register_xirang_orb(drop: XirangDrop, amount: int) -> void:
	if drop == null or not net_manager.is_host():
		return
	var orb_id := _next_xirang_orb_id
	_next_xirang_orb_id += 1
	drop.setup_multiplayer_orb(orb_id, amount, false)
	_xirang_orbs[orb_id] = {"amount": amount, "drop": drop}
	_rpc_to_connected_clients(&"net_xirang_orb_spawned", [orb_id, amount, drop.global_position])


@rpc("authority", "call_remote", "reliable", 4)
func net_xirang_orb_spawned(orb_id: int, amount: int, spawn_position: Vector2) -> void:
	if game == null or net_manager.is_host():
		return
	if _xirang_orbs.has(orb_id):
		return
	var drop := XIRANG_DROP_SCENE.instantiate() as XirangDrop
	if drop == null:
		return
	game.enemy_container.add_child(drop)
	drop.global_position = spawn_position
	drop.setup_multiplayer_orb(orb_id, amount, true)
	_xirang_orbs[orb_id] = {"amount": amount, "drop": drop}


func request_xirang_orb_collected(orb_id: int) -> void:
	if net_manager.is_host():
		_apply_xirang_orb_collected(orb_id, _get_local_peer_id())
	else:
		_rpc_xirang_orb_collected.rpc_id(_get_host_peer_id(), orb_id)


@rpc("any_peer", "call_remote", "reliable", 4)
func _rpc_xirang_orb_collected(orb_id: int) -> void:
	if not net_manager.is_host():
		return
	var sender_id := multiplayer.get_remote_sender_id()
	if sender_id <= 0:
		return
	_apply_xirang_orb_collected(orb_id, sender_id)


func _apply_xirang_orb_collected(orb_id: int, collector_peer_id: int) -> void:
	if not _is_valid_xirang_collector_peer(collector_peer_id):
		return
	var now := _get_net_time()
	if (
		orb_id <= 0
		or _is_recent_event_cached(_collected_xirang_orbs, orb_id, now)
		or not _xirang_orbs.has(orb_id)
	):
		if collector_peer_id > 0 and is_inside_tree():
			net_xirang_orb_removed.rpc_id(collector_peer_id, orb_id)
		return
	_remember_recent_event(_collected_xirang_orbs, orb_id, ORB_DEDUP_RETENTION_SECONDS, now)
	var orb_data := _xirang_orbs[orb_id] as Dictionary
	var amount := int(orb_data.get("amount", 1))
	var revision := _xirang_revision + 1
	if is_inside_tree():
		_rpc_to_connected_clients(&"net_xirang_granted_all", [orb_id, amount, revision])
	net_xirang_granted_all(orb_id, amount, revision)


func _is_valid_xirang_collector_peer(collector_peer_id: int) -> bool:
	if collector_peer_id <= 0 or game == null:
		return false
	var player_node := game.get_player_for_peer(collector_peer_id)
	return player_node != null and is_instance_valid(player_node)


@rpc("authority", "call_remote", "reliable", 4)
func net_xirang_granted_all(orb_id: int, amount: int, revision: int) -> void:
	if orb_id <= 0 or amount <= 0:
		return
	var now := _get_net_time()
	if _is_recent_event_cached(_granted_xirang_orbs, orb_id, now):
		_remove_xirang_orb_local(orb_id, false)
		return
	if revision <= _xirang_revision:
		return
	_remember_recent_event(_granted_xirang_orbs, orb_id, ORB_DEDUP_RETENTION_SECONDS, now)
	_xirang_revision = revision
	_grant_xirang_to_all_players(amount)
	_remove_xirang_orb_local(orb_id, true)


@rpc("authority", "call_remote", "reliable", 4)
func net_xirang_orb_removed(orb_id: int) -> void:
	_remove_xirang_orb_local(orb_id, false)


func _remove_xirang_orb_local(orb_id: int, play_collect_feedback: bool) -> void:
	if not _xirang_orbs.has(orb_id):
		return
	var orb_data := _xirang_orbs[orb_id] as Dictionary
	var drop := orb_data.get("drop") as XirangDrop
	if drop != null and is_instance_valid(drop):
		if play_collect_feedback:
			drop.confirm_multiplayer_collect()
		else:
			drop.queue_free()
	_xirang_orbs.erase(orb_id)


func _grant_xirang_to_all_players(amount: int) -> void:
	if game == null:
		return
	for peer_id_variant in game.peer_players:
		var player_node := game.peer_players[peer_id_variant] as Player
		if player_node != null and is_instance_valid(player_node):
			player_node.grant_multiplayer_xirang(amount)

func get_local_multiplayer_player() -> Player:
	if game == null:
		return null
	return game.player


func is_host_multiplayer_authority() -> bool:
	return net_manager != null and net_manager.is_host()


func _get_host_enemy_for_net_id(enemy_net_id: int) -> Enemy:
	if game == null:
		return null
	return game.get_enemy_for_net_id(enemy_net_id)


func _get_client_enemy_for_net_id(enemy_net_id: int) -> Enemy:
	return _get_valid_client_enemy_for_net_id(enemy_net_id)


func _get_valid_client_enemy_for_net_id(enemy_net_id: int) -> Enemy:
	var enemy_variant: Variant = _net_enemies.get(enemy_net_id)
	if enemy_variant == null:
		return null
	if not is_instance_valid(enemy_variant):
		_net_enemies.erase(enemy_net_id)
		_enemy_spawn_snapshot_times.erase(enemy_net_id)
		enemy_interpolators.erase(enemy_net_id)
		return null
	return enemy_variant as Enemy

func _next_player_health_revision(peer_id: int) -> int:
	var next_revision := int(_player_health_revisions.get(peer_id, 0)) + 1
	_player_health_revisions[peer_id] = next_revision
	return next_revision


func _schedule_player_revive(peer_id: int) -> void:
	if peer_id <= 0 or _dead_player_revive_times.has(peer_id):
		return
	_host_latest_client_player_snapshot_states.erase(peer_id)
	_dead_player_revive_times[peer_id] = _get_net_time() + PLAYER_REVIVE_DELAY_SECONDS
	_dead_player_revive_last_seconds[peer_id] = -1
	_rpc_to_connected_clients(
		&"net_player_revive_countdown",
		[peer_id, int(ceil(PLAYER_REVIVE_DELAY_SECONDS))]
	)
	net_player_revive_countdown(peer_id, int(ceil(PLAYER_REVIVE_DELAY_SECONDS)))


func _host_update_player_revives() -> void:
	if not net_manager.is_host() or game == null:
		return
	if game.wave_state == Game.WaveState.DEFEAT:
		return
	var now := _get_net_time()
	var due_peers: Array[int] = []
	for peer_id_variant in _dead_player_revive_times:
		var peer_id := int(peer_id_variant)
		var revive_at := float(_dead_player_revive_times[peer_id])
		var seconds_left := maxi(ceili(revive_at - now), 0)
		if seconds_left != int(_dead_player_revive_last_seconds.get(peer_id, -1)):
			_dead_player_revive_last_seconds[peer_id] = seconds_left
			_rpc_to_connected_clients(&"net_player_revive_countdown", [peer_id, seconds_left])
			net_player_revive_countdown(peer_id, seconds_left)
		if now >= revive_at:
			due_peers.append(peer_id)
	if due_peers.is_empty():
		return
	var revive_positions := _collect_living_player_revive_positions()
	if revive_positions.is_empty():
		return
	for peer_id in due_peers:
		_revive_player_peer(peer_id, _pick_multiplayer_revive_position(revive_positions))


func _collect_living_player_revive_positions() -> Array[Vector2]:
	var positions: Array[Vector2] = []
	if game == null:
		return positions
	for peer_id_variant in game.peer_players:
		var peer_id := int(peer_id_variant)
		var player_node := game.peer_players[peer_id_variant] as Player
		if player_node == null or not is_instance_valid(player_node) or player_node.is_dead:
			continue
		positions.append(_get_multiplayer_player_revive_anchor_position(peer_id, player_node))
	return positions


func _get_multiplayer_player_revive_anchor_position(peer_id: int, player_node: Player) -> Vector2:
	if peer_id != _get_host_peer_id() and _accepted_player_state_positions.has(peer_id):
		return _accepted_player_state_positions[peer_id] as Vector2
	return player_node.global_position


func _pick_multiplayer_revive_position(revive_positions: Array) -> Vector2:
	if revive_positions.is_empty():
		return Vector2.ZERO
	return revive_positions[_revive_random_generator.randi_range(0, revive_positions.size() - 1)]


func _revive_player_peer(peer_id: int, revive_position: Vector2) -> void:
	var player_node: Player = null
	if game != null:
		player_node = game.get_player_for_peer(peer_id)
	if player_node == null or not is_instance_valid(player_node):
		return
	_dead_player_revive_times.erase(peer_id)
	_dead_player_revive_last_seconds.erase(peer_id)
	var now: float = _get_net_time()
	_accepted_player_state_positions[peer_id] = revive_position
	_accepted_player_state_times[peer_id] = now
	var health_revision := _next_player_health_revision(peer_id)
	player_node.revive_multiplayer(
		revive_position,
		player_node.max_health,
		PLAYER_REVIVE_INVINCIBILITY_SECONDS
	)
	if peer_id != _get_host_peer_id():
		_remember_latest_client_player_snapshot_state(
			peer_id,
			revive_position,
			Vector2.ZERO,
			player_node.get_multiplayer_facing_id(),
			player_node.get_multiplayer_anim_state()
		)
	if peer_id != _get_host_peer_id():
		net_player_state_corrected.rpc_id(peer_id, revive_position, Vector2.ZERO)
	_rpc_to_connected_clients(
		&"net_player_revived",
		[
			peer_id,
			revive_position,
			player_node.current_health,
			PLAYER_REVIVE_INVINCIBILITY_SECONDS,
			health_revision,
		]
	)
	net_player_revived(
		peer_id,
		revive_position,
		player_node.current_health,
		PLAYER_REVIVE_INVINCIBILITY_SECONDS,
		health_revision
	)


func _on_host_revive_all_requested() -> void:
	if not net_manager.is_host() or game == null:
		return
	var revive_positions := _collect_living_player_revive_positions()
	if revive_positions.is_empty():
		return
	for peer_id_variant in game.peer_players:
		var peer_id := int(peer_id_variant)
		var player_node := game.peer_players[peer_id_variant] as Player
		if player_node == null or not is_instance_valid(player_node) or not player_node.is_dead:
			continue
		_revive_player_peer(peer_id, _pick_multiplayer_revive_position(revive_positions))


@rpc("authority", "call_remote", "reliable", 4)
func net_player_revive_countdown(peer_id: int, seconds_left: int) -> void:
	if game == null or peer_id <= 0:
		return
	var player_node := game.get_player_for_peer(peer_id)
	if player_node == null or not is_instance_valid(player_node):
		return
	player_node.set_multiplayer_revive_countdown(seconds_left)


@rpc("authority", "call_remote", "reliable", 4)
func net_player_revived(
	peer_id: int,
	revive_position: Vector2,
	current_health: int,
	invincible_seconds: float,
	health_revision: int
) -> void:
	if peer_id <= 0:
		return
	var player_node: Player = null
	if game != null:
		player_node = game.get_player_for_peer(peer_id)
	if player_node == null or not is_instance_valid(player_node):
		return
	if health_revision <= int(_player_health_revisions.get(peer_id, 0)):
		return
	_player_health_revisions[peer_id] = health_revision
	_dead_player_revive_times.erase(peer_id)
	_dead_player_revive_last_seconds.erase(peer_id)
	player_node.revive_multiplayer(revive_position, current_health, invincible_seconds)
	if is_client_view_runtime() and peer_id != _get_client_view_local_peer_id():
		_reset_player_visual_interpolator_to_state(
			peer_id,
			revive_position,
			Vector2.ZERO,
			player_node.get_multiplayer_facing_id(),
			player_node.get_multiplayer_anim_state()
		)

func _on_host_enemy_spawned(
	net_id: int,
	enemy_config: EnemyConfig,
	spawn_position: Vector2
) -> void:
	if enemy_config == null or not is_inside_tree() or not net_manager.is_host():
		return
	_rpc_to_connected_clients(
		&"net_enemy_spawned",
		[net_id, enemy_config.resource_path, spawn_position.x, spawn_position.y, _get_net_time()]
	)


func _on_host_enemy_defeated(net_id: int, defeat_position: Vector2) -> void:
	if not is_inside_tree() or not net_manager.is_host() or net_id <= 0:
		return
	_rpc_to_connected_clients(&"net_enemy_defeated", [net_id, defeat_position])


func _on_host_enemy_removed(net_id: int) -> void:
	if not is_inside_tree() or not net_manager.is_host():
		return
	_rpc_to_connected_clients(&"net_enemy_removed", [net_id])


func broadcast_enemy_action(
	net_id: int,
	action_name: StringName,
	direction: Vector2,
	action_position: Vector2,
	action_id: int
) -> void:
	if not net_manager.is_host() or net_id <= 0 or action_id <= 0:
		return
	_rpc_to_connected_clients(
		&"net_enemy_action",
		[net_id, String(action_name), direction, action_position, action_id, _get_net_time()]
	)


func broadcast_enemy_target_action(
	net_id: int,
	action_name: StringName,
	target_peer_id: int,
	action_position: Vector2,
	action_id: int
) -> void:
	if not net_manager.is_host() or net_id <= 0 or action_id <= 0:
		return
	_rpc_to_connected_clients(
		&"net_enemy_target_action",
		[net_id, String(action_name), target_peer_id, action_position, action_id, _get_net_time()]
	)


func _on_host_pickup_removed(net_id: int) -> void:
	if not is_inside_tree() or not net_manager.is_host():
		return
	_rpc_to_connected_clients(&"net_pickup_removed", [net_id])


func _on_host_pickup_spawned(
	net_id: int,
	pickup_config: PickupConfig,
	spawn_position: Vector2
) -> void:
	if pickup_config == null or not is_inside_tree() or not net_manager.is_host():
		return
	_rpc_to_connected_clients(
		&"net_pickup_spawned",
		[net_id, pickup_config.resource_path, spawn_position.x, spawn_position.y]
	)


func _on_host_pickup_collected(
	net_id: int,
	collector_peer_id: int,
	pickup_config: PickupConfig,
	applied_immediately: bool
) -> void:
	if not is_inside_tree() or not net_manager.is_host():
		return
	var config_path := pickup_config.resource_path if pickup_config != null else ""
	_rpc_to_connected_clients(
		&"net_pickup_collected",
		[net_id, collector_peer_id, config_path, applied_immediately]
	)


func _on_host_merchant_active_changed(active: bool) -> void:
	if not is_inside_tree() or not net_manager.is_host():
		return
	_rpc_to_connected_clients(&"net_merchant_active_changed", [active])


func _on_host_wave_started(wave_index: int) -> void:
	if not is_inside_tree() or not net_manager.is_host():
		return
	_rpc_to_connected_clients(&"net_wave_started", [wave_index])


func _on_host_flow_state_changed(step_id: StringName, state: int, countdown_seconds: int) -> void:
	if not is_inside_tree() or not net_manager.is_host():
		return
	_rpc_to_connected_clients(&"net_flow_state_changed", [String(step_id), state, countdown_seconds])


func _on_host_boss_started(
	net_id: int,
	boss_config: BossConfig,
	spawn_position: Vector2
) -> void:
	if not is_inside_tree() or not net_manager.is_host() or boss_config == null:
		return
	_rpc_to_connected_clients(
		&"net_boss_started",
		[net_id, boss_config.resource_path, spawn_position]
	)


func _on_host_defeat_started() -> void:
	if not is_inside_tree() or not net_manager.is_host():
		return
	_rpc_to_connected_clients(&"net_game_defeated")


func _on_host_victory_started() -> void:
	if not is_inside_tree() or not net_manager.is_host():
		return
	_rpc_to_connected_clients(&"net_game_victory")


func _on_game_return_to_lobby_requested() -> void:
	if net_manager != null and net_manager.has_method("disconnect_from_game") and net_manager.is_multiplayer_active():
		net_manager.disconnect_from_game()
		return
	_return_to_lobby()

@rpc("authority", "call_remote", "reliable", 4)
func net_enemy_spawned(
	net_id: int,
	config_path: String,
	pos_x: float,
	pos_y: float,
	host_spawn_timestamp: float
) -> void:
	if game == null or net_manager.is_host():
		return
	_remove_client_enemy(net_id, false)
	var enemy_config: EnemyConfig = load(config_path) as EnemyConfig
	if enemy_config == null:
		return
	var spawn_scene := enemy_config.enemy_scene
	if spawn_scene == null:
		return
	var enemy: Enemy = spawn_scene.instantiate() as Enemy
	if enemy == null:
		return
	game.enemy_container.add_child(enemy)
	var spawn_position: Vector2 = Vector2(pos_x, pos_y)
	var mapped_spawn_time: float = _map_host_timestamp_to_client_time(host_spawn_timestamp, false)
	_enemy_spawn_snapshot_times[net_id] = mapped_spawn_time
	enemy.global_position = _get_buffered_enemy_position(net_id, spawn_position)
	enemy.setup(enemy_config, game.player, game.grid_pathfinder)
	enemy.configure_multiplayer_proxy()
	enemy.set_meta("net_id", net_id)
	enemy.tree_exited.connect(_on_client_enemy_tree_exited.bind(net_id, enemy))
	_net_enemies[net_id] = enemy
	game.multiplayer_enemies_by_net_id[net_id] = enemy
	game.multiplayer_enemy_ids_by_instance[enemy.get_instance_id()] = net_id
	game.play_remote_enemy_spawn_effect(spawn_position)


@rpc("authority", "call_remote", "reliable", 4)
func net_enemy_defeated(net_id: int, defeat_position: Vector2) -> void:
	if game == null or net_manager.is_host():
		return
	var enemy: Enemy = _get_valid_client_enemy_for_net_id(net_id)
	if enemy == null or not is_instance_valid(enemy):
		return
	enemy.global_position = defeat_position
	_remove_client_enemy(net_id, true)


@rpc("authority", "call_remote", "reliable", 4)
func net_enemy_removed(net_id: int) -> void:
	_remove_client_enemy(net_id, true)


@rpc("authority", "call_remote", "reliable", 4)
func net_enemy_action(
	net_id: int,
	action_name: String,
	direction: Vector2,
	action_position: Vector2,
	action_id: int,
	host_action_timestamp: float = -1.0
) -> void:
	if game == null or net_manager.is_host():
		return
	var enemy: Enemy = _get_valid_client_enemy_for_net_id(net_id)
	if enemy == null or not is_instance_valid(enemy):
		return
	var action_sample := _push_enemy_action_interpolator_sample(
		net_id,
		action_position,
		host_action_timestamp
	)
	if not bool(action_sample.get("accepted", false)):
		return
	if action_sample.get("apply_direct_position", false):
		enemy.global_position = action_position
	if enemy.has_method("play_multiplayer_enemy_action"):
		enemy.call("play_multiplayer_enemy_action", StringName(action_name), direction, action_id)


@rpc("authority", "call_remote", "reliable", 4)
func net_enemy_target_action(
	net_id: int,
	action_name: String,
	target_peer_id: int,
	action_position: Vector2,
	action_id: int,
	host_action_timestamp: float = -1.0
) -> void:
	if game == null or net_manager.is_host():
		return
	var enemy: Enemy = _get_valid_client_enemy_for_net_id(net_id)
	if enemy == null or not is_instance_valid(enemy):
		return
	var action_sample := _push_enemy_action_interpolator_sample(
		net_id,
		action_position,
		host_action_timestamp
	)
	if not bool(action_sample.get("accepted", false)):
		return
	if action_sample.get("apply_direct_position", false):
		enemy.global_position = action_position
	var target := game.get_player_for_peer(target_peer_id)
	if enemy.has_method("play_multiplayer_enemy_target_action"):
		enemy.call(
			"play_multiplayer_enemy_target_action",
			StringName(action_name),
			target,
			action_id
		)


func _push_enemy_action_interpolator_sample(
	net_id: int,
	action_position: Vector2,
	host_action_timestamp: float
) -> Dictionary:
	if net_id <= 0:
		return {}
	var action_time := _get_net_time()
	if host_action_timestamp >= 0.0:
		action_time = _map_host_timestamp_to_client_time(host_action_timestamp, false)
	var interp := enemy_interpolators.get(net_id) as NetInterpolator
	var had_interpolator_samples := interp != null and interp.get_buffer_size() > 0
	if interp != null:
		var latest_timestamp := interp.get_latest_timestamp()
		if latest_timestamp > 0.0 and action_time < latest_timestamp:
			if latest_timestamp - action_time > ENEMY_ACTION_SNAPSHOT_REORDER_TOLERANCE_SECONDS:
				return {"accepted": false, "apply_direct_position": false}
			return {"accepted": true, "apply_direct_position": false}
	else:
		interp = _create_enemy_interpolator()
		enemy_interpolators[net_id] = interp
	interp.push_snapshot(action_time, action_position, Vector2.ZERO)
	return {"accepted": true, "apply_direct_position": not had_interpolator_samples}



func _on_client_enemy_tree_exited(net_id: int, exiting_enemy: Enemy) -> void:
	var enemy_variant: Variant = _net_enemies.get(net_id)
	if enemy_variant == null:
		return
	if is_instance_valid(enemy_variant) and enemy_variant != exiting_enemy:
		return
	_net_enemies.erase(net_id)
	_enemy_spawn_snapshot_times.erase(net_id)
	enemy_interpolators.erase(net_id)
	if game != null:
		game.multiplayer_enemies_by_net_id.erase(net_id)
		game.multiplayer_enemy_ids_by_instance.erase(exiting_enemy.get_instance_id())

func _get_buffered_enemy_position(net_id: int, fallback_position: Vector2) -> Vector2:
	var interp: NetInterpolator = enemy_interpolators.get(net_id) as NetInterpolator
	if interp == null or interp.get_buffer_size() <= 0:
		return fallback_position
	return interp.get_interpolated_position(_get_net_time())


func _reconcile_enemy_roster(seen_enemy_ids: Dictionary, snapshot_time: float) -> void:
	var stale_ids: Array[int] = []
	for net_id_variant in _net_enemies:
		var net_id := int(net_id_variant)
		if seen_enemy_ids.has(net_id):
			continue
		var spawn_time := float(_enemy_spawn_snapshot_times.get(net_id, -INF))
		if spawn_time > snapshot_time:
			continue
		stale_ids.append(net_id)
	for net_id in stale_ids:
		_remove_client_enemy(net_id, true)


func _remove_client_enemy(net_id: int, clear_interpolator: bool) -> void:
	var enemy_variant: Variant = _net_enemies.get(net_id)
	if enemy_variant != null and is_instance_valid(enemy_variant):
		var enemy: Enemy = enemy_variant as Enemy
		if enemy != null:
			if clear_interpolator:
				enemy.play_multiplayer_death_sequence()
			else:
				enemy.queue_free()
	_net_enemies.erase(net_id)
	_enemy_spawn_snapshot_times.erase(net_id)
	if game != null:
		game.multiplayer_enemies_by_net_id.erase(net_id)
		if enemy_variant != null and is_instance_valid(enemy_variant):
			var enemy_for_instance := enemy_variant as Enemy
			if enemy_for_instance != null:
				game.multiplayer_enemy_ids_by_instance.erase(enemy_for_instance.get_instance_id())
	if clear_interpolator:
		enemy_interpolators.erase(net_id)

@rpc("authority", "call_remote", "reliable", 4)
func net_pickup_removed(net_id: int) -> void:
	if game == null or net_manager.is_host():
		return
	var pickup: Pickup = game.get_pickup_for_net_id(net_id)
	if pickup == null or not is_instance_valid(pickup):
		game.multiplayer_pickups.erase(net_id)
		return
	game.multiplayer_pickups.erase(net_id)
	pickup.queue_free()


@rpc("authority", "call_remote", "reliable", 4)
func net_pickup_spawned(net_id: int, config_path: String, pos_x: float, pos_y: float) -> void:
	if game == null or net_manager.is_host():
		return
	if game.get_pickup_for_net_id(net_id) != null:
		return
	var pickup_config := load(config_path) as PickupConfig
	if pickup_config == null:
		return
	var pickup := PICKUP_SCENE.instantiate() as Pickup
	if pickup == null:
		return
	pickup.config = pickup_config
	game.enemy_container.add_child(pickup)
	pickup.global_position = Vector2(pos_x, pos_y)
	pickup.set_meta("net_id", net_id)
	pickup.collision_layer = 0
	pickup.collision_mask = 0
	game.multiplayer_pickups[net_id] = pickup


@rpc("authority", "call_remote", "reliable", 4)
func net_pickup_collected(
	net_id: int,
	collector_peer_id: int,
	config_path: String,
	applied_immediately: bool
) -> void:
	if game == null or net_manager.is_host():
		return
	var pickup: Pickup = game.get_pickup_for_net_id(net_id)
	if pickup != null and is_instance_valid(pickup):
		game.multiplayer_pickups.erase(net_id)
		pickup.queue_free()
	if config_path.is_empty():
		return
	var pickup_config := load(config_path) as PickupConfig
	if pickup_config == null:
		return
	var player_node: Player = game.get_player_for_peer(collector_peer_id)
	if player_node == null or not is_instance_valid(player_node):
		return
	if applied_immediately:
		player_node.apply_pickup(pickup_config)
	else:
		run_state.try_add_item_for_peer(collector_peer_id, pickup_config)


@rpc("authority", "call_remote", "reliable", 4)
func net_merchant_active_changed(active: bool) -> void:
	if game == null or net_manager.is_host():
		return
	game.apply_remote_merchant_active(active)



@rpc("authority", "call_remote", "reliable", 4)
func net_wave_started(wave_index: int) -> void:
	if game == null or net_manager.is_host():
		return
	game.apply_remote_wave_started(wave_index)


@rpc("authority", "call_remote", "reliable", 4)
func net_flow_state_changed(step_id: String, state: int, countdown_seconds: int) -> void:
	if game == null or net_manager.is_host():
		return
	game.apply_remote_flow_state(StringName(step_id), state, countdown_seconds)


@rpc("authority", "call_remote", "reliable", 4)
func net_boss_started(net_id: int, boss_config_path: String, spawn_position: Vector2) -> void:
	if game == null or net_manager.is_host():
		return
	var boss_config := load(boss_config_path) as BossConfig
	if boss_config == null:
		return
	game.apply_remote_boss_started(net_id, boss_config, spawn_position)
	var boss_enemy := game.get_enemy_for_net_id(net_id) as Enemy
	if boss_enemy != null and is_instance_valid(boss_enemy):
		_net_enemies[net_id] = boss_enemy
		if not boss_enemy.tree_exited.is_connected(_on_client_enemy_tree_exited.bind(net_id, boss_enemy)):
			boss_enemy.tree_exited.connect(_on_client_enemy_tree_exited.bind(net_id, boss_enemy))


@rpc("authority", "call_remote", "reliable", 4)
func net_game_defeated() -> void:
	if game == null or net_manager.is_host():
		return
	game.apply_remote_defeat()


@rpc("authority", "call_remote", "reliable", 4)
func net_game_victory() -> void:
	if game == null or net_manager.is_host():
		return
	game.apply_remote_victory()


@rpc("any_peer", "call_remote", "reliable", 4)
func net_upgrade_selected(stat_type: int) -> void:
	if not net_manager.is_host():
		return
	var sender_id := multiplayer.get_remote_sender_id()
	if sender_id <= 0:
		return
	_apply_upgrade_for_peer(sender_id, stat_type)


@rpc("any_peer", "call_remote", "reliable", 4)
func net_inventory_item_use_requested(slot_index: int) -> void:
	if not net_manager.is_host():
		return
	var sender_id := multiplayer.get_remote_sender_id()
	if sender_id <= 0:
		return
	_apply_inventory_item_use_for_peer(sender_id, slot_index)


@rpc("any_peer", "call_remote", "reliable", 4)
func net_inventory_item_discard_requested(slot_index: int) -> void:
	if not net_manager.is_host():
		return
	var sender_id := multiplayer.get_remote_sender_id()
	if sender_id <= 0:
		return
	_apply_inventory_item_discard_for_peer(sender_id, slot_index)


@rpc("any_peer", "call_remote", "reliable", 4)
func net_skill1_purchase_requested() -> void:
	if not net_manager.is_host():
		return
	var sender_id := multiplayer.get_remote_sender_id()
	if sender_id <= 0:
		return
	_apply_skill1_purchase_for_peer(sender_id)


@rpc("any_peer", "call_remote", "reliable", 4)
func net_luoxi_collectible_choice_requested(choice_index: int, config_path: String) -> void:
	if not net_manager.is_host():
		return
	var sender_id := multiplayer.get_remote_sender_id()
	if sender_id <= 0:
		return
	_apply_luoxi_collectible_choice_for_peer(sender_id, choice_index, config_path)


@rpc("any_peer", "call_remote", "reliable", 4)
func net_cheat_xirang_requested() -> void:
	if not net_manager.is_host():
		return
	var sender_id := multiplayer.get_remote_sender_id()
	if sender_id <= 0:
		return
	_apply_cheat_xirang_for_peer(sender_id)


@rpc("any_peer", "call_remote", "reliable", 4)
func net_debug_collectible_requested(config_path: String) -> void:
	if not net_manager.is_host():
		return
	var sender_id := multiplayer.get_remote_sender_id()
	if sender_id <= 0:
		return
	_apply_debug_collectible_for_peer(sender_id, config_path)


@rpc("authority", "call_remote", "reliable", 4)
func net_upgrade_confirmed(
	peer_id: int,
	stat_type: int,
	level: int,
	current_xirang: int,
	success: bool,
	free_upgrade: bool = false
) -> void:
	if not success:
		return
	if peer_id <= 0 or game == null:
		return
	var player_node: Player = game.get_player_for_peer(peer_id)
	if player_node == null or not is_instance_valid(player_node):
		return
	run_state.ensure_multiplayer_peer_state(peer_id)
	run_state.set_upgrade_level_for_peer(peer_id, stat_type, level)
	var already_applied_on_host: bool = net_manager.is_host() and peer_id == _get_local_peer_id()
	if not already_applied_on_host:
		_apply_confirmed_upgrade_to_player(player_node, stat_type)
	player_node.current_xirang = current_xirang
	player_node.xirang_changed.emit(current_xirang, 0)
	if free_upgrade and not already_applied_on_host:
		player_node.play_lucky_upgrade_feedback()


@rpc("authority", "call_remote", "reliable", 4)
func net_inventory_item_used(
	peer_id: int,
	slot_index: int,
	config_path: String,
	success: bool
) -> void:
	if not success:
		return
	if peer_id <= 0 or game == null:
		return
	var player_node: Player = game.get_player_for_peer(peer_id)
	if player_node == null or not is_instance_valid(player_node):
		return
	var already_applied_on_host: bool = net_manager.is_host() and peer_id == _get_local_peer_id()
	if not already_applied_on_host and not config_path.is_empty():
		var item := load(config_path) as PickupConfig
		if item != null:
			player_node.apply_pickup(item)
	run_state.discard_item_for_peer(peer_id, slot_index)


@rpc("authority", "call_remote", "reliable", 4)
func net_inventory_item_discarded(peer_id: int, slot_index: int, success: bool) -> void:
	if not success:
		return
	if peer_id <= 0 or game == null:
		return
	var player_node: Player = game.get_player_for_peer(peer_id)
	if player_node == null or not is_instance_valid(player_node):
		return
	run_state.discard_item_for_peer(peer_id, slot_index)


func _apply_confirmed_upgrade_to_player(player_node: Player, stat_type: int) -> void:
	match stat_type:
		RunStateStore.StatType.ATTACK:
			player_node.upgrade_attack()
		RunStateStore.StatType.HEALTH:
			player_node.upgrade_max_health()
		RunStateStore.StatType.ATTACK_SPEED:
			player_node.upgrade_attack_speed()
		RunStateStore.StatType.DODGE:
			player_node.upgrade_dodge()


@rpc("authority", "call_remote", "reliable", 4)
func net_skill1_purchase_confirmed(
	peer_id: int,
	current_xirang: int,
	skill1_unlocked: bool,
	result_code: int,
	skill1_upgrade_level: int = -1,
	skill1_charge_duration: float = -1.0
) -> void:
	if game == null:
		return
	game.apply_skill1_purchase_state(
		peer_id,
		current_xirang,
		skill1_unlocked,
		skill1_upgrade_level,
		skill1_charge_duration
	)
	if peer_id == _get_local_peer_id():
		game.show_local_skill1_purchase_result(result_code)


@rpc("authority", "call_remote", "reliable", 4)
func net_luoxi_collectible_confirmed(
	peer_id: int,
	choice_index: int,
	config_path: String,
	result_code: int
) -> void:
	if game == null:
		return
	if result_code == LuoxiMerchant.COLLECTIBLE_RESULT_SUCCESS and not config_path.is_empty():
		game.mark_luoxi_collectible_claimed(peer_id)
		var already_applied_on_host: bool = net_manager.is_host() and peer_id == _get_local_peer_id()
		if not already_applied_on_host:
			var item := load(config_path) as PickupConfig
			if item != null:
				run_state.try_add_item_for_peer(peer_id, item)
	elif result_code == LuoxiMerchant.COLLECTIBLE_RESULT_ALREADY_CLAIMED:
		game.mark_luoxi_collectible_claimed(peer_id)
	if peer_id == _get_local_peer_id():
		game.show_local_luoxi_collectible_result(result_code)


@rpc("authority", "call_remote", "reliable", 4)
func net_collectible_visual_effect(
	effect_type: String,
	spawn_position: Vector2,
	radius: float,
	color: Color,
	duration: float
) -> void:
	_spawn_collectible_visual_effect(effect_type, spawn_position, radius, color, duration)


@rpc("authority", "call_remote", "reliable", 4)
func net_collectible_follow_visual_effect(
	effect_type: String,
	owner_peer_id: int,
	radius: float,
	duration: float
) -> void:
	_spawn_collectible_follow_visual_effect(effect_type, owner_peer_id, radius, duration)


@rpc("authority", "call_remote", "reliable", 4)
func net_cheat_xirang_confirmed(peer_id: int, current_xirang: int, added_amount: int) -> void:
	if game == null:
		return
	var player_node := game.get_player_for_peer(peer_id)
	if player_node == null or not is_instance_valid(player_node):
		return
	player_node.current_xirang = maxi(current_xirang, 0)
	player_node.xirang_changed.emit(player_node.current_xirang, maxi(added_amount, 0))


@rpc("authority", "call_remote", "reliable", 4)
func net_debug_collectible_granted(peer_id: int, config_path: String, success: bool) -> void:
	if game == null:
		return
	if peer_id <= 0:
		return
	if success and not config_path.is_empty():
		var already_applied_on_host: bool = net_manager != null and net_manager.is_host() and peer_id == _get_local_peer_id()
		if not already_applied_on_host:
			var item := LuoxiMerchant.get_collectible_for_path(config_path)
			if item != null:
				run_state.try_add_item_for_peer(peer_id, item)
	if peer_id == _get_local_peer_id():
		game.show_debug_collectible_grant_result(config_path, success)


func _apply_upgrade_for_peer(peer_id: int, stat_type: int) -> void:
	if game == null or peer_id <= 0:
		return
	var player_node: Player = game.get_player_for_peer(peer_id)
	if player_node == null or not is_instance_valid(player_node):
		return
	var success := run_state.try_upgrade_for_peer(peer_id, stat_type, player_node)
	var free_upgrade := success and player_node.consume_last_base_upgrade_free_flag()
	var level := run_state.get_upgrade_level_for_peer(peer_id, stat_type)
	var current_xirang := player_node.current_xirang
	_rpc_to_connected_clients(
		&"net_upgrade_confirmed",
		[peer_id, stat_type, level, current_xirang, success, free_upgrade]
	)
	if peer_id == _get_local_peer_id():
		net_upgrade_confirmed(peer_id, stat_type, level, current_xirang, success, free_upgrade)


func _apply_inventory_item_use_for_peer(peer_id: int, slot_index: int) -> void:
	if game == null or peer_id <= 0:
		return
	var player_node: Player = game.get_player_for_peer(peer_id)
	if player_node == null or not is_instance_valid(player_node):
		return
	var item := run_state.get_item_for_peer(peer_id, slot_index)
	var config_path := item.resource_path if item != null else ""
	var success := run_state.try_use_item_for_peer(peer_id, slot_index, player_node)
	if not success:
		config_path = ""
	_rpc_to_connected_clients(
		&"net_inventory_item_used",
		[peer_id, slot_index, config_path, success]
	)
	if peer_id == _get_local_peer_id():
		net_inventory_item_used(peer_id, slot_index, config_path, success)


func _apply_inventory_item_discard_for_peer(peer_id: int, slot_index: int) -> void:
	if game == null or peer_id <= 0:
		return
	var player_node: Player = game.get_player_for_peer(peer_id)
	if player_node == null or not is_instance_valid(player_node):
		return
	var success := run_state.discard_item_for_peer(peer_id, slot_index)
	_rpc_to_connected_clients(
		&"net_inventory_item_discarded",
		[peer_id, slot_index, success]
	)
	if peer_id == _get_local_peer_id():
		net_inventory_item_discarded(peer_id, slot_index, success)


func _apply_skill1_purchase_for_peer(peer_id: int) -> void:
	if game == null or peer_id <= 0:
		return
	var player_node := game.get_player_for_peer(peer_id)
	if player_node == null or not is_instance_valid(player_node):
		return
	var result_code := game.try_purchase_skill1_for_peer(peer_id)
	var current_xirang := player_node.current_xirang
	var skill1_unlocked := player_node.has_skill1()
	var skill1_upgrade_level := player_node.skill1_upgrade_level
	var skill1_charge_duration := player_node.skill1_charge_duration
	_rpc_to_connected_clients(
		&"net_skill1_purchase_confirmed",
		[
			peer_id,
			current_xirang,
			skill1_unlocked,
			result_code,
			skill1_upgrade_level,
			skill1_charge_duration,
		]
	)
	if peer_id == _get_local_peer_id():
		net_skill1_purchase_confirmed(
			peer_id,
			current_xirang,
			skill1_unlocked,
			result_code,
			skill1_upgrade_level,
			skill1_charge_duration
		)


func _apply_luoxi_collectible_choice_for_peer(
	peer_id: int,
	choice_index: int,
	config_path: String
) -> void:
	if game == null or peer_id <= 0:
		return
	var resolved_config_path := config_path
	if resolved_config_path.is_empty():
		var item := LuoxiMerchant.get_collectible_for_choice(choice_index)
		resolved_config_path = item.resource_path if item != null else ""
	var result_code := game.try_claim_luoxi_collectible_for_peer(peer_id, resolved_config_path)
	if result_code != LuoxiMerchant.COLLECTIBLE_RESULT_SUCCESS:
		resolved_config_path = ""
	_rpc_to_connected_clients(
		&"net_luoxi_collectible_confirmed",
		[peer_id, choice_index, resolved_config_path, result_code]
	)
	if peer_id == _get_local_peer_id():
		net_luoxi_collectible_confirmed(peer_id, choice_index, resolved_config_path, result_code)


func _spawn_collectible_visual_effect(
	effect_type: String,
	spawn_position: Vector2,
	radius: float,
	color: Color,
	duration: float
) -> void:
	match effect_type:
		"lightning":
			var lightning := COLLECTIBLE_LIGHTNING_EFFECT_SCENE.instantiate() as CollectibleLightningEffect
			if lightning == null:
				return
			lightning.top_level = true
			lightning.setup(duration)
			add_child(lightning)
			lightning.global_position = spawn_position
		"area":
			var area := COLLECTIBLE_AREA_EFFECT_SCENE.instantiate() as CollectibleAreaEffect
			if area == null:
				return
			area.top_level = true
			area.setup(radius, color, duration)
			add_child(area)
			area.global_position = spawn_position
		"frost_area":
			var frost_area := COLLECTIBLE_FROST_AREA_EFFECT_SCENE.instantiate()
			if frost_area == null:
				return
			frost_area.top_level = true
			frost_area.call("setup", radius, duration)
			add_child(frost_area)
			frost_area.global_position = spawn_position


func _spawn_collectible_follow_visual_effect(
	effect_type: String,
	owner_peer_id: int,
	radius: float,
	duration: float
) -> void:
	if game == null or owner_peer_id <= 0:
		return
	if owner_peer_id == _get_local_peer_id():
		return
	var owner_player := game.get_player_for_peer(owner_peer_id)
	if owner_player == null or not is_instance_valid(owner_player):
		return
	match effect_type:
		"moon_shield":
			var moon_shield := COLLECTIBLE_MOON_SHIELD_VISUAL_SCENE.instantiate() as CollectibleMoonShieldVisual
			if moon_shield == null:
				return
			moon_shield.setup(radius, duration)
			owner_player.add_child(moon_shield)
			moon_shield.position = Vector2.ZERO


func _apply_cheat_xirang_for_peer(peer_id: int) -> void:
	if game == null:
		return
	var player_node: Player = game.get_player_for_peer(peer_id)
	if player_node == null or not is_instance_valid(player_node):
		return
	if not player_node.grant_cheat_xirang(CHEAT_XIRANG_AMOUNT):
		return
	_rpc_to_connected_clients(
		&"net_cheat_xirang_confirmed",
		[peer_id, player_node.current_xirang, CHEAT_XIRANG_AMOUNT]
	)


func _apply_debug_collectible_for_peer(peer_id: int, config_path: String) -> void:
	if game == null or peer_id <= 0:
		return
	var item := LuoxiMerchant.get_collectible_for_path(config_path)
	var success := false
	if item != null:
		success = run_state.try_add_item_for_peer(peer_id, item)
	_rpc_to_connected_clients(
		&"net_debug_collectible_granted",
		[peer_id, config_path, success]
	)
	if peer_id == _get_local_peer_id():
		net_debug_collectible_granted(peer_id, config_path, success)


func _get_host_peer_id() -> int:
	if net_manager != null and net_manager.has_method("get_host_peer_id"):
		return int(net_manager.get_host_peer_id())
	return 1


func _get_local_peer_id() -> int:
	if net_manager == null:
		return 0
	return int(net_manager.get_local_peer_id())


func _get_client_view_local_peer_id() -> int:
	var local_peer_id := _get_local_peer_id()
	if local_peer_id > 0:
		return local_peer_id
	if game != null:
		return int(game.multiplayer_local_peer_id)
	return 0


func _get_net_time() -> float:
	return Time.get_ticks_msec() / 1000.0 - _net_time_origin


func _map_host_timestamp_to_client_time(host_timestamp: float, update_offset: bool = true) -> float:
	var receive_time := _get_net_time()
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


func _on_connection_state_changed(new_state: int) -> void:
	if new_state == STATE_DISCONNECTED:
		_return_to_lobby()
	elif new_state == STATE_IN_GAME and net_manager.is_client():
		_client_host_game_ready = true


func _on_net_player_left(peer_id: int) -> void:
	if peer_id <= 0:
		return
	_clear_peer_network_state(peer_id)
	if game != null and game.has_method("remove_multiplayer_player"):
		game.call("remove_multiplayer_player", peer_id)


func _clear_peer_network_state(peer_id: int) -> void:
	snapshot_mgr.clear_peer_delta_cache(peer_id)
	_last_player_keyframe_time_by_peer.erase(peer_id)
	_last_enemy_keyframe_time_by_peer.erase(peer_id)
	player_visual_interpolators.erase(peer_id)
	_last_player_state_sequences.erase(peer_id)
	_accepted_player_state_positions.erase(peer_id)
	_accepted_player_state_times.erase(peer_id)
	_host_latest_client_player_snapshot_states.erase(peer_id)
	_player_health_revisions.erase(peer_id)
	_dead_player_revive_times.erase(peer_id)
	_dead_player_revive_last_seconds.erase(peer_id)
	_clear_projectiles_for_peer(peer_id)
	_clear_projectile_records_for_peer(peer_id)


func _clear_projectiles_for_peer(peer_id: int) -> void:
	var projectile_ids: Array[int] = []
	for projectile_id_variant in _known_projectiles.keys():
		var projectile_id := int(projectile_id_variant)
		var projectile_variant: Variant = _known_projectiles.get(projectile_id)
		if projectile_variant == null or not is_instance_valid(projectile_variant):
			projectile_ids.append(projectile_id)
			continue
		var projectile_object := projectile_variant as Object
		if projectile_object == null:
			projectile_ids.append(projectile_id)
			continue
		var projectile_owner := int(projectile_object.get("owner_peer_id"))
		if projectile_owner == peer_id:
			projectile_ids.append(projectile_id)
	for projectile_id in projectile_ids:
		var projectile_variant: Variant = _known_projectiles.get(projectile_id)
		_known_projectiles.erase(projectile_id)
		if projectile_variant != null and is_instance_valid(projectile_variant):
			var projectile_node := projectile_variant as Node
			if projectile_node != null:
				projectile_node.queue_free()


func _clear_projectile_records_for_peer(peer_id: int) -> void:
	var projectile_ids: Array[int] = []
	for projectile_id_variant in _projectile_records.keys():
		var projectile_id := int(projectile_id_variant)
		var record := _projectile_records[projectile_id] as Dictionary
		if record.is_empty() or int(record.get("owner_peer_id", 0)) == peer_id:
			projectile_ids.append(projectile_id)
	for projectile_id in projectile_ids:
		_projectile_records.erase(projectile_id)


func _return_to_lobby() -> void:
	snapshot_mgr.reset_delta_cache()
	_last_player_keyframe_time_by_peer.clear()
	_last_enemy_keyframe_time_by_peer.clear()
	var tree: SceneTree = get_tree()
	if tree == null:
		return
	tree.change_scene_to_file("res://scene/multiplayer/multiplayer_lobby.tscn")
