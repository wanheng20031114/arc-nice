extends Node

## RPC surface stub for /root/MpRogueRoute while the relay project only
## forwards packets. Annotations and signatures must mirror the game wrapper.

@rpc("any_peer", "call_remote", "reliable", 0)
func net_request_route_full_snapshot() -> void:
	pass


@rpc("authority", "call_remote", "reliable", 0)
func net_route_full_snapshot(
	layout: Dictionary,
	state: Dictionary,
	encounter_state: Dictionary,
	economy_state: Dictionary
) -> void:
	pass


@rpc("authority", "call_remote", "reliable", 0)
func net_route_move_delta(delta: Dictionary) -> void:
	pass


@rpc("any_peer", "call_remote", "reliable", 0)
func net_route_encounter_intro_ack(
	occurrence_key: String,
	expected_revision: int
) -> void:
	pass


@rpc("any_peer", "call_remote", "reliable", 0)
func net_route_encounter_vote(
	occurrence_key: String,
	expected_revision: int,
	option_id: StringName
) -> void:
	pass


@rpc("authority", "call_remote", "reliable", 0)
func net_route_encounter_snapshot(
	encounter_state: Dictionary,
	economy_state: Dictionary
) -> void:
	pass


@rpc("any_peer", "call_remote", "unreliable_ordered", 1)
func net_route_avatar_input(
	sequence: int,
	route_revision: int,
	packed_pose: PackedInt32Array
) -> void:
	pass


@rpc("authority", "call_remote", "unreliable_ordered", 2)
func net_route_avatar_snapshot(
	snapshot_sequence: int,
	route_revision: int,
	packed_states: PackedInt32Array
) -> void:
	pass


@rpc("authority", "call_remote", "reliable", 0)
func net_route_avatar_corrected(
	route_revision: int,
	packed_pose: PackedInt32Array
) -> void:
	pass
