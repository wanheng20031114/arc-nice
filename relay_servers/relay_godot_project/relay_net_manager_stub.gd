extends Node

## RPC surface stub for /root/NetManager while this project runs as a pure relay.

@rpc("any_peer", "call_remote", "reliable", 0)
func _rpc_register_player(
	player_name: String,
	character_id: String = "weishidaier",
	character_confirmed: bool = true,
	protocol_version: int = -1,
	reconnect_token: String = ""
) -> void:
	pass


@rpc("authority", "call_remote", "reliable", 0)
func _rpc_protocol_rejected(expected_protocol_version: int) -> void:
	pass

@rpc("authority", "call_remote", "reliable", 0)
func _rpc_join_rejected(reason: String) -> void:
	pass


## Relay 专用控制面。逻辑 Host 发送给服务端 peer 1；RelayServer 会用真实
## sender ID 验证 Host 身份并断开目标 transport，绝不由 stub 自行决定目标。
@rpc("any_peer", "call_remote", "reliable", 0)
func _rpc_relay_kick_peer(target_peer_id: int) -> void:
	var relay_server := get_node_or_null("/root/RelayServer")
	if relay_server == null:
		return
	relay_server.request_host_peer_disconnect(
		multiplayer.get_remote_sender_id(),
		target_peer_id
	)


@rpc("any_peer", "call_remote", "reliable", 0)
func _rpc_set_player_character(character_id: String, confirmed: bool) -> void:
	pass


@rpc("authority", "call_remote", "reliable", 0)
func _rpc_sync_player_list(
	player_list: Array,
	new_host_peer_id: int = 0,
	game_mode: int = 0,
	max_players: int = 8,
	session_membership_revision: int = -1
) -> void:
	pass


@rpc("authority", "call_remote", "reliable", 0)
func _rpc_start_game(game_mode: int = 0, session_id: int = 0) -> void:
	pass


@rpc("authority", "call_remote", "reliable", 0)
func _rpc_host_game_ready(session_id: int = 0) -> void:
	pass


@rpc("any_peer", "call_remote", "reliable", 0)
func _rpc_report_game_loaded(session_id: int) -> void:
	pass


@rpc("authority", "call_remote", "reliable", 0)
func _rpc_game_load_progress(session_id: int, ready_count: int, total_count: int) -> void:
	pass


@rpc("authority", "call_remote", "reliable", 0)
func _rpc_player_reconnected(
	old_peer_id: int,
	new_peer_id: int,
	player_name: String,
	character_id: String,
	membership_revision: int
) -> void:
	pass
