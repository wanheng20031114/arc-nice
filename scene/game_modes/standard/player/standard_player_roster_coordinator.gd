extends CombatPlayerRosterCoordinatorBase
class_name StandardPlayerRosterCoordinator


func get_player_for_peer_or_singleplayer(peer_id: int) -> Player:
	if runtime == null:
		return null
	if peer_id <= 0:
		return runtime.player
	return get_player_for_peer(peer_id)
