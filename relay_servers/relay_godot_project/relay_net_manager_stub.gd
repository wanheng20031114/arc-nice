extends Node

## RPC surface stub for /root/NetManager while this project runs as a pure relay.

@rpc("any_peer", "call_remote", "reliable", 0)
func _rpc_register_player(player_name: String) -> void:
	pass


@rpc("authority", "call_remote", "reliable", 0)
func _rpc_sync_player_list(player_list: Array, new_host_peer_id: int = 0) -> void:
	pass


@rpc("authority", "call_remote", "reliable", 0)
func _rpc_start_game() -> void:
	pass


@rpc("authority", "call_remote", "reliable", 0)
func _rpc_host_game_ready() -> void:
	pass
