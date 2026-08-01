extends Node

## RPC surface stub for /root/MpRogueRoute while the relay project only
## forwards packets. Annotations and signatures must mirror the game wrapper.

@rpc("any_peer", "call_remote", "reliable", 0)
func net_request_route_full_snapshot() -> void:
	pass


@rpc("authority", "call_remote", "reliable", 0)
func net_route_full_snapshot(layout: Dictionary, state: Dictionary) -> void:
	pass


@rpc("authority", "call_remote", "reliable", 0)
func net_route_move_delta(delta: Dictionary) -> void:
	pass
