extends Node
class_name TowerDefenseCampaignRuntimePort

var _runtime: CombatRuntimeBase


func bind_runtime(runtime: CombatRuntimeBase) -> void:
	_runtime = runtime


func is_bound() -> bool:
	return _runtime != null and is_instance_valid(_runtime)


func get_runtime_mode() -> int:
	return int(_runtime.runtime_mode)


func get_runtime_preparation_generation() -> int:
	return _runtime.get_runtime_preparation_generation()


func get_local_peer_id() -> int:
	return _runtime.multiplayer_local_peer_id


func has_peer_player(peer_id: int) -> bool:
	return _runtime.peer_players.has(peer_id)


func get_progression_player_count() -> int:
	if _runtime.runtime_mode == CombatRuntimeBase.RuntimeMode.SINGLEPLAYER:
		return 1
	return maxi(_runtime.peer_players.size(), 1)


func get_peer_ids() -> Array[int]:
	var peer_ids: Array[int] = []
	for peer_id_variant in _runtime.peer_players:
		peer_ids.append(int(peer_id_variant))
	peer_ids.sort()
	return peer_ids


func get_local_player() -> Player:
	return _runtime.player
