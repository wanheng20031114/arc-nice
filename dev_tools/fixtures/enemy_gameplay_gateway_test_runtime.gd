extends CombatRuntimeBase
class_name EnemyGameplayGatewayTestRuntime

## Lightweight real combat runtime used by enemy-domain smoke tests. The
## fixture scene authors the same gateway boundary as production runtimes, so
## projectiles never need to discover networking through an implicit scene root.


func attach_gameplay_session(session: MultiplayerGameplaySession) -> void:
	var gateway := get_multiplayer_gameplay_gateway()
	if gateway != null:
		gateway.attach_multiplayer_session(session)


func detach_gameplay_session(session: MultiplayerGameplaySession) -> void:
	var gateway := get_multiplayer_gameplay_gateway()
	if gateway != null:
		gateway.detach_multiplayer_session(session)


func configure_multiplayer(
	_mode: int,
	_local_peer_id: int,
	_player_names: Dictionary,
	_player_character_ids: Dictionary = {}
) -> void:
	pass


func get_player_for_peer(peer_id: int) -> Player:
	return peer_players.get(peer_id) as Player


func get_enemy_for_net_id(net_id: int) -> Enemy:
	return multiplayer_enemies_by_net_id.get(net_id) as Enemy


func get_pickup_for_net_id(net_id: int) -> Pickup:
	return multiplayer_pickups.get(net_id) as Pickup


func remove_multiplayer_player(peer_id: int) -> void:
	peer_players.erase(peer_id)


func collect_player_snapshot_states() -> Array[SnapshotManager.PlayerState]:
	return []


func collect_enemy_snapshot_states() -> Array[SnapshotManager.EnemyState]:
	return []


func play_remote_enemy_spawn_effect(_spawn_global_position: Vector2) -> void:
	pass
