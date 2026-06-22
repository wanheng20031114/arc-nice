extends Node

## RPC surface stub for /root/MpGame while this project runs as a pure relay.
## The methods intentionally do nothing; they only mirror the game RPC table.

@rpc("authority", "call_remote", "unreliable_ordered", 2)
func _rpc_receive_player_snapshot(host_timestamp: float, data: PackedByteArray) -> void:
	pass


@rpc("authority", "call_remote", "unreliable_ordered", 2)
func _rpc_receive_enemy_snapshot(host_timestamp: float, data: PackedByteArray) -> void:
	pass


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
	pass


@rpc("authority", "call_remote", "reliable", 4)
func net_player_state_corrected(corrected_position: Vector2, corrected_velocity: Vector2) -> void:
	pass


@rpc("any_peer", "call_remote", "unreliable_ordered", 3)
func _rpc_projectile_fired_from_client(
	projectile_id: int,
	projectile_type: String,
	owner_peer_id: int,
	spawn_position: Vector2,
	direction: Vector2,
	damage: int,
	speed: float,
	lifetime: float
) -> void:
	pass


@rpc("authority", "call_remote", "unreliable_ordered", 3)
func net_projectile_fired(
	projectile_id: int,
	projectile_type: String,
	owner_peer_id: int,
	spawn_position: Vector2,
	direction: Vector2,
	damage: int,
	speed: float,
	lifetime: float
) -> void:
	pass


@rpc("any_peer", "call_remote", "reliable", 4)
func _rpc_enemy_hit_report(
	projectile_id: int,
	owner_peer_id: int,
	enemy_net_id: int,
	damage: int,
	impact_direction: Vector2
) -> void:
	pass


@rpc("authority", "call_remote", "reliable", 4)
func net_enemy_damage_applied(
	enemy_net_id: int,
	current_health: int,
	is_dead: bool,
	confirmed_damage: int,
	impact_direction: Vector2
) -> void:
	pass


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
	pass


@rpc("authority", "call_remote", "reliable", 4)
func net_player_damage_applied(
	player_peer_id: int,
	current_health: int,
	is_dead: bool,
	health_revision: int
) -> void:
	pass


@rpc("authority", "call_remote", "reliable", 4)
func net_xirang_orb_spawned(orb_id: int, amount: int, spawn_position: Vector2) -> void:
	pass


@rpc("any_peer", "call_remote", "reliable", 4)
func _rpc_xirang_orb_collected(orb_id: int) -> void:
	pass


@rpc("authority", "call_remote", "reliable", 4)
func net_xirang_granted_all(orb_id: int, amount: int, revision: int) -> void:
	pass


@rpc("authority", "call_remote", "reliable", 4)
func net_xirang_orb_removed(orb_id: int) -> void:
	pass


@rpc("authority", "call_remote", "reliable", 4)
func net_player_revive_countdown(peer_id: int, seconds_left: int) -> void:
	pass


@rpc("authority", "call_remote", "reliable", 4)
func net_player_revived(
	peer_id: int,
	revive_position: Vector2,
	current_health: int,
	invincible_seconds: float,
	health_revision: int
) -> void:
	pass


@rpc("authority", "call_remote", "reliable", 4)
func net_enemy_spawned(
	net_id: int,
	config_path: String,
	pos_x: float,
	pos_y: float,
	host_spawn_timestamp: float
) -> void:
	pass


@rpc("authority", "call_remote", "reliable", 4)
func net_enemy_defeated(net_id: int, defeat_position: Vector2) -> void:
	pass


@rpc("authority", "call_remote", "reliable", 4)
func net_enemy_removed(net_id: int) -> void:
	pass


@rpc("authority", "call_remote", "reliable", 4)
func net_enemy_action(
	net_id: int,
	action_name: String,
	direction: Vector2,
	action_position: Vector2,
	action_id: int
) -> void:
	pass


@rpc("authority", "call_remote", "reliable", 4)
func net_pickup_removed(net_id: int) -> void:
	pass


@rpc("authority", "call_remote", "reliable", 4)
func net_pickup_spawned(net_id: int, config_path: String, pos_x: float, pos_y: float) -> void:
	pass


@rpc("authority", "call_remote", "reliable", 4)
func net_pickup_collected(
	net_id: int,
	collector_peer_id: int,
	config_path: String,
	applied_immediately: bool
) -> void:
	pass


@rpc("authority", "call_remote", "reliable", 4)
func net_merchant_active_changed(active: bool) -> void:
	pass


@rpc("authority", "call_remote", "reliable", 4)
func net_wave_started(wave_index: int) -> void:
	pass


@rpc("authority", "call_remote", "reliable", 4)
func net_game_defeated() -> void:
	pass


@rpc("any_peer", "call_remote", "reliable", 4)
func net_upgrade_selected(stat_type: int) -> void:
	pass


@rpc("any_peer", "call_remote", "reliable", 4)
func net_skill1_purchase_requested() -> void:
	pass


@rpc("any_peer", "call_remote", "reliable", 4)
func net_cheat_xirang_requested() -> void:
	pass


@rpc("authority", "call_remote", "reliable", 4)
func net_upgrade_confirmed(
	peer_id: int,
	stat_type: int,
	level: int,
	current_xirang: int,
	success: bool
) -> void:
	pass


@rpc("authority", "call_remote", "reliable", 4)
func net_skill1_purchase_confirmed(
	peer_id: int,
	current_xirang: int,
	skill1_unlocked: bool,
	result_code: int,
	skill1_upgrade_level: int = -1,
	skill1_charge_duration: float = -1.0
) -> void:
	pass


@rpc("authority", "call_remote", "reliable", 4)
func net_cheat_xirang_confirmed(peer_id: int, current_xirang: int, added_amount: int) -> void:
	pass
