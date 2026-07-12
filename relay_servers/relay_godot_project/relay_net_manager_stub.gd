extends Node

## RPC surface stub for /root/NetManager while this project runs as a pure relay.

@rpc("any_peer", "call_remote", "reliable", 0)
func _rpc_register_player(
	player_name: String,
	character_id: String = "weishidaier",
	character_confirmed: bool = true,
	protocol_version: int = -1
) -> void:
	pass


@rpc("authority", "call_remote", "reliable", 0)
func _rpc_protocol_rejected(expected_protocol_version: int) -> void:
	pass


@rpc("any_peer", "call_remote", "reliable", 0)
func _rpc_set_player_character(character_id: String, confirmed: bool) -> void:
	pass


@rpc("authority", "call_remote", "reliable", 0)
func _rpc_sync_player_list(
	player_list: Array,
	new_host_peer_id: int = 0,
	game_mode: int = 0
) -> void:
	pass


@rpc("authority", "call_remote", "reliable", 0)
func _rpc_start_game(game_mode: int = 0) -> void:
	pass


@rpc("authority", "call_remote", "reliable", 0)
func _rpc_host_game_ready() -> void:
	pass
