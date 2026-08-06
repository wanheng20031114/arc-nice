extends CombatRuntimeBase
class_name CombatRuntimeTestFixture


func install_base_runtime_nodes() -> void:
	_add_fixture_child(Node2D.new(), "EnemyContainer")
	_add_fixture_child(Node.new(), "GridPathfinder")
	_add_fixture_child(Node.new(), "CapooProjectileMotionSystem")
	_add_fixture_child(
		CombatRobotDroneMotionSystem.new(),
		"CombatRobotDroneMotionSystem"
	)
	var day_night := DayNightController.new()
	day_night.night_factor = 1.0
	_add_fixture_child(day_night, "DayNightController")
	_add_fixture_child(
		MultiplayerGameplayGateway.new(),
		"MultiplayerGameplayGateway"
	)
	_add_fixture_child(MultiplayerModeAdapter.new(), "MultiplayerModeAdapter")


func _add_fixture_child(child: Node, child_name: String) -> void:
	if has_node(child_name):
		child.free()
		return
	child.name = child_name
	add_child(child)


func configure_multiplayer(
	mode: int,
	local_peer_id: int,
	_player_names: Dictionary,
	_player_character_ids: Dictionary = {}
) -> void:
	runtime_mode = mode
	multiplayer_local_peer_id = local_peer_id


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
