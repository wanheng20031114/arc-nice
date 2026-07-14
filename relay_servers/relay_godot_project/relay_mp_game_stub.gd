extends Node

## RPC surface stub for /root/MpGame while this project runs as a pure relay.
## Methods intentionally do nothing; annotations and signatures mirror the game RPC table.

class _NetConstants:
	const ENEMY_SNAPSHOT_HZ := 30

@rpc("authority", "call_remote", "unreliable_ordered", 2)
func _rpc_receive_player_snapshot(host_timestamp: float, data: PackedByteArray) -> void:
	pass

@rpc("authority", "call_remote", "unreliable", 3)
func _rpc_receive_enemy_snapshot(
	host_timestamp: float,
	data: PackedByteArray,
	batch_id: int = 0,
	chunk_index: int = 0,
	chunk_count: int = 1,
	snapshot_hz: int = _NetConstants.ENEMY_SNAPSHOT_HZ
) -> void:
	pass

@rpc("any_peer", "call_remote", "unreliable_ordered", 1)
func _rpc_client_player_state(
	sequence: int,
	reported_position: Vector2,
	reported_velocity: Vector2,
	move_input: Vector2,
	shoot_input: Vector2,
	buttons: int,
	dash_request_sequence: int,
	dash_direction: Vector2,
	dash_start_move_input: Vector2,
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

@rpc("any_peer", "call_remote", "reliable", 5)
func net_player_dash_requested(
	dash_request_sequence: int,
	direction: Vector2,
	start_move_input: Vector2
) -> void:
	pass

@rpc("authority", "call_remote", "reliable", 5)
func net_player_dash_confirmed(
	player_peer_id: int,
	direction: Vector2,
	dash_request_sequence: int
) -> void:
	pass

@rpc("any_peer", "call_remote", "reliable", 5)
func net_hoe_primary_attack_requested(direction: Vector2, request_id: int = 0) -> void:
	pass

@rpc("any_peer", "call_remote", "reliable", 5)
func net_hoe_whirlwind_requested(request_id: int = 0) -> void:
	pass

@rpc("authority", "call_remote", "reliable", 5)
func net_hoe_action_confirmed(
	peer_id: int,
	action_kind_text: String,
	direction: Vector2,
	action_sequence: int,
	request_id: int = 0,
	accepted: bool = true,
	cooldown_ratio: float = 0.0,
	skill_charge: float = -1.0
) -> void:
	pass

@rpc("any_peer", "call_remote", "reliable", 5)
func net_tiyi_high_noon_requested(activation_id: int) -> void:
	pass

@rpc("authority", "call_remote", "reliable", 5)
func net_tiyi_high_noon_started(peer_id: int, activation_id: int) -> void:
	pass

@rpc("authority", "call_remote", "unreliable_ordered", 7)
func net_tiyi_high_noon_targets(
	peer_id: int,
	activation_id: int,
	target_ids: PackedInt32Array
) -> void:
	pass

@rpc("authority", "call_remote", "reliable", 5)
func net_tiyi_high_noon_finished(
	peer_id: int,
	activation_id: int,
	target_ids: PackedInt32Array,
	hit_positions: PackedVector2Array
) -> void:
	pass

@rpc("authority", "call_remote", "reliable", 5)
func net_tiyi_high_noon_cancelled(peer_id: int, activation_id: int) -> void:
	pass

@rpc("authority", "call_remote", "reliable", 5)
func net_player_state_corrected(corrected_position: Vector2, corrected_velocity: Vector2) -> void:
	pass

@rpc("any_peer", "call_remote", "reliable", 4)
func _rpc_projectile_fired_from_client(
	projectile_id: int,
	projectile_type: String,
	owner_peer_id: int,
	spawn_position: Vector2,
	direction: Vector2,
	damage: int,
	speed: float,
	lifetime: float,
	pierces_enemies: bool = false,
	target_peer_id: int = 0,
	_client_fire_timestamp: float = -1.0,
	target_enemy_net_id: int = 0
) -> void:
	pass

@rpc("authority", "call_remote", "unreliable_ordered", 4)
func net_projectile_fired(
	projectile_id: int,
	projectile_type: String,
	owner_peer_id: int,
	spawn_position: Vector2,
	direction: Vector2,
	damage: int,
	speed: float,
	lifetime: float,
	pierces_enemies: bool = false,
	target_peer_id: int = 0,
	host_fire_timestamp: float = -1.0,
	target_enemy_net_id: int = 0
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
func net_tiyi_sniper_hit_confirmed(
	projectile_id: int,
	enemy_net_id: int,
	hit_position: Vector2,
	direction: Vector2,
	continues_piercing: bool
) -> void:
	pass

@rpc("authority", "call_remote", "unreliable", 7)
func net_enemy_damage_feedback_batch(
	net_ids: PackedInt32Array,
	health_values: PackedInt32Array,
	damage_values: PackedInt32Array,
	directions: PackedVector2Array,
	damage_types: PackedByteArray,
	particle_flags: PackedByteArray
) -> void:
	pass

@rpc("authority", "call_remote", "unreliable", 7)
func net_enemy_damage_applied(
	enemy_net_id: int,
	current_health: int,
	is_dead: bool,
	confirmed_damage: int,
	impact_direction: Vector2,
	damage_type: int = 0,
	show_hit_particles: bool = true
) -> void:
	pass

@rpc("any_peer", "call_remote", "reliable", 5)
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

@rpc("authority", "call_remote", "reliable", 5)
func net_player_damage_applied(
	player_peer_id: int,
	current_health: int,
	is_dead: bool,
	health_revision: int
) -> void:
	pass

@rpc("authority", "call_remote", "reliable", 5)
func net_player_healed(peer_id: int, current_health: int, health_revision: int) -> void:
	pass

@rpc("authority", "call_remote", "reliable", 5)
func net_xirang_orb_spawned(orb_id: int, amount: int, spawn_position: Vector2) -> void:
	pass

@rpc("any_peer", "call_remote", "reliable", 6)
func _rpc_xirang_orb_collected(orb_id: int) -> void:
	pass

@rpc("authority", "call_remote", "reliable", 6)
func net_xirang_granted_all(orb_id: int, amount: int, revision: int) -> void:
	pass

@rpc("authority", "call_remote", "reliable", 5)
func net_xirang_orb_removed(orb_id: int) -> void:
	pass

@rpc("authority", "call_remote", "reliable", 5)
func net_player_revive_countdown(peer_id: int, seconds_left: int) -> void:
	pass

@rpc("authority", "call_remote", "reliable", 5)
func net_player_revived(
	peer_id: int,
	revive_position: Vector2,
	current_health: int,
	invincible_seconds: float,
	health_revision: int
) -> void:
	pass

@rpc("any_peer", "call_remote", "reliable", 0)
func net_runtime_state_requested(include_flow_state: bool = true) -> void:
	pass

@rpc("any_peer", "call_remote", "reliable", 0)
func net_terrain_snapshot_requested(known_revision: int) -> void:
	pass

@rpc("authority", "call_remote", "reliable", 5)
func net_terrain_snapshot_chunk(
	snapshot_id: int,
	revision: int,
	chunk_index: int,
	chunk_count: int,
	cell_xy: PackedInt32Array,
	terrain_types: PackedInt32Array
) -> void:
	pass

@rpc("authority", "call_remote", "reliable", 5)
func net_terrain_delta(
	revision: int,
	cell_xy: PackedInt32Array,
	terrain_types: PackedInt32Array
) -> void:
	pass

@rpc("authority", "call_remote", "reliable", 5)
func net_runtime_world_manifest(
	live_enemy_ids: PackedInt32Array,
	live_pickup_ids: PackedInt32Array,
	live_plant_ids: PackedInt32Array
) -> void:
	pass

@rpc("any_peer", "call_remote", "reliable", 5)
func net_plant_placement_requested(
	request_id: int,
	plant_id: String,
	anchor: Vector2i
) -> void:
	pass

@rpc("authority", "call_remote", "reliable", 5)
func net_enemy_spawned(
	net_id: int,
	config_path: String,
	pos_x: float,
	pos_y: float,
	host_spawn_timestamp: float
) -> void:
	pass

@rpc("authority", "call_remote", "reliable", 5)
func net_enemy_spawned_batch(
	net_ids: PackedInt32Array,
	config_paths: PackedStringArray,
	positions: PackedVector2Array,
	spawn_times: PackedFloat64Array
) -> void:
	pass

@rpc("authority", "call_remote", "reliable", 5)
func net_enemy_terminal(net_id: int, reason: int, event_position: Vector2) -> void:
	pass

@rpc("authority", "call_remote", "reliable", 5)
func net_enemy_defeated(net_id: int, defeat_position: Vector2) -> void:
	pass

@rpc("authority", "call_remote", "reliable", 5)
func net_enemy_removed(net_id: int) -> void:
	pass

@rpc("authority", "call_remote", "reliable", 5)
func net_enemy_escaped(net_id: int) -> void:
	pass

@rpc("authority", "call_remote", "reliable", 5)
func net_base_health_changed(
	current_health: int,
	maximum_health: int,
	revision: int
) -> void:
	pass

@rpc("authority", "call_remote", "unreliable_ordered", 7)
func net_tower_defense_wave_progress_changed(
	wave_number: int,
	defeated: int,
	escaped: int,
	resolved: int,
	total: int
) -> void:
	pass

@rpc("authority", "call_remote", "reliable", 5)
func net_tower_defense_wave_progress_keyframe(
	wave_number: int,
	defeated: int,
	escaped: int,
	resolved: int,
	total: int
) -> void:
	pass

@rpc("authority", "call_remote", "reliable", 5)
func net_plant_spawned(
	request_id: int,
	owner_peer_id: int,
	net_id: int,
	plant_id: String,
	anchor: Vector2i,
	current_health: int,
	maximum_health: int,
	health_revision: int,
	runtime_state: Dictionary,
	host_sample_time: float
) -> void:
	pass

@rpc("authority", "call_remote", "reliable", 5)
func net_plant_placement_rejected(request_id: int, reason: String) -> void:
	pass

@rpc("authority", "call_remote", "unreliable_ordered", 7)
func net_plant_health_changed(
	net_id: int,
	current_health: int,
	maximum_health: int,
	health_revision: int
) -> void:
	pass

@rpc("authority", "call_remote", "unreliable_ordered", 7)
func net_plant_health_batch(
	net_ids: PackedInt32Array,
	health_values: PackedInt32Array,
	maximum_values: PackedInt32Array,
	revisions: PackedInt32Array
) -> void:
	pass

@rpc("any_peer", "call_remote", "reliable", 6)
func net_warehouse_command_requested(command: Dictionary) -> void:
	pass

@rpc("any_peer", "call_remote", "reliable", 6)
func net_warehouse_snapshot_requested(warehouse_net_id: int) -> void:
	pass

@rpc("authority", "call_remote", "reliable", 6)
func net_warehouse_command_result(result: Dictionary) -> void:
	pass

@rpc("authority", "call_remote", "reliable", 6)
func net_inventory_snapshot(
	peer_id: int,
	snapshot: Dictionary,
	force_inventory_repair: bool = false
) -> void:
	pass

@rpc("authority", "call_remote", "reliable", 6)
func net_warehouse_storage_snapshot(warehouse_net_id: int, snapshot: Dictionary) -> void:
	pass

@rpc("authority", "call_remote", "reliable", 5)
func net_plant_removed(net_id: int) -> void:
	pass

@rpc("authority", "call_remote", "unreliable_ordered", 4)
func net_plant_projectile_visual(
	spawn_position: Vector2,
	direction: Vector2,
	speed: float,
	explosion_radius: float,
	lifetime: float
) -> void:
	pass

@rpc("authority", "call_remote", "unreliable_ordered", 4)
func net_corn_machine_gun_burst_batch(
	plant_net_ids: PackedInt32Array,
	action_ids: PackedInt32Array,
	directions: PackedVector2Array,
	host_action_times: PackedFloat64Array
) -> void:
	pass

@rpc("authority", "call_remote", "unreliable_ordered", 7)
func net_enemy_action(
	net_id: int,
	action_name: String,
	direction: Vector2,
	action_position: Vector2,
	action_id: int,
	host_action_timestamp: float = -1.0
) -> void:
	pass

@rpc("authority", "call_remote", "unreliable_ordered", 7)
func net_enemy_target_action(
	net_id: int,
	action_name: String,
	target_peer_id: int,
	action_position: Vector2,
	action_id: int,
	host_action_timestamp: float = -1.0
) -> void:
	pass

@rpc("authority", "call_remote", "reliable", 5)
func net_pickup_removed(net_id: int) -> void:
	pass

@rpc("authority", "call_remote", "reliable", 5)
func net_pickup_spawned(net_id: int, config_path: String, pos_x: float, pos_y: float) -> void:
	pass

@rpc("authority", "call_remote", "reliable", 6)
func net_pickup_collected(
	net_id: int,
	collector_peer_id: int,
	config_path: String,
	applied_immediately: bool,
	inventory_snapshot: Dictionary = {}
) -> void:
	pass

@rpc("authority", "call_remote", "reliable", 5)
func net_merchant_active_changed(active: bool) -> void:
	pass

@rpc("authority", "call_remote", "reliable", 5)
func net_flow_state_changed(step_id: String, state: int, countdown_seconds: int) -> void:
	pass

@rpc("authority", "call_remote", "reliable", 5)
func net_boss_started(net_id: int, boss_config_path: String, spawn_position: Vector2) -> void:
	pass

@rpc("authority", "call_remote", "reliable", 5)
func net_game_defeated() -> void:
	pass

@rpc("authority", "call_remote", "reliable", 5)
func net_game_victory() -> void:
	pass

@rpc("any_peer", "call_remote", "reliable", 6)
func net_upgrade_selected(stat_type: int) -> void:
	pass

@rpc("any_peer", "call_remote", "reliable", 6)
func net_inventory_item_use_requested(
	slot_index: int,
	expected_inventory_revision: int = -1
) -> void:
	pass

@rpc("any_peer", "call_remote", "reliable", 6)
func net_inventory_item_discard_requested(
	slot_index: int,
	expected_inventory_revision: int = -1
) -> void:
	pass

@rpc("any_peer", "call_remote", "reliable", 6)
func net_skill1_purchase_requested() -> void:
	pass

@rpc("any_peer", "call_remote", "reliable", 5)
func net_tower_defense_start_wave_requested() -> void:
	pass

@rpc("any_peer", "call_remote", "reliable", 6)
func net_luoxi_collectible_offer_requested() -> void:
	pass

@rpc("any_peer", "call_remote", "reliable", 6)
func net_luoxi_collectible_choice_requested(
	choice_index: int,
	offer_revision: int = 0
) -> void:
	pass

@rpc("any_peer", "call_remote", "reliable", 6)
func net_luoxi_collectible_refresh_requested(offer_revision: int = 0) -> void:
	pass

@rpc("any_peer", "call_remote", "reliable", 6)
func net_cheat_xirang_requested() -> void:
	pass

@rpc("any_peer", "call_remote", "reliable", 6)
func net_debug_collectible_requested(config_path: String) -> void:
	pass

@rpc("authority", "call_remote", "reliable", 6)
func net_upgrade_confirmed(
	peer_id: int,
	stat_type: int,
	level: int,
	current_xirang: int,
	success: bool,
	free_upgrade: bool = false
) -> void:
	pass

@rpc("authority", "call_remote", "reliable", 6)
func net_inventory_item_used(
	peer_id: int,
	slot_index: int,
	config_path: String,
	success: bool,
	inventory_snapshot: Dictionary = {},
	force_inventory_repair: bool = false
) -> void:
	pass

@rpc("authority", "call_remote", "reliable", 6)
func net_inventory_item_discarded(
	peer_id: int,
	slot_index: int,
	success: bool,
	inventory_snapshot: Dictionary = {},
	force_inventory_repair: bool = false
) -> void:
	pass

@rpc("authority", "call_remote", "reliable", 6)
func net_skill1_purchase_confirmed(
	peer_id: int,
	current_xirang: int,
	skill1_unlocked: bool,
	result_code: int,
	skill1_upgrade_level: int = -1,
	skill1_charge_duration: float = -1.0
) -> void:
	pass

@rpc("authority", "call_remote", "reliable", 6)
func net_luoxi_collectible_offer_state(
	peer_id: int,
	offer_revision: int,
	config_paths: PackedStringArray,
	refresh_count: int,
	current_xirang: int,
	refresh_result_code: int = -1
) -> void:
	pass

@rpc("authority", "call_remote", "reliable", 6)
func net_luoxi_collectible_confirmed(
	peer_id: int,
	choice_index: int,
	config_path: String,
	result_code: int,
	offer_revision: int = 0,
	inventory_snapshot: Dictionary = {}
) -> void:
	pass

@rpc("authority", "call_remote", "reliable", 6)
func net_luoxi_collectible_refresh_confirmed(
	peer_id: int,
	result_code: int,
	refresh_count: int,
	current_xirang: int
) -> void:
	pass

@rpc("authority", "call_remote", "unreliable", 7)
func net_collectible_visual_effect(
	effect_type: String,
	spawn_position: Vector2,
	radius: float,
	color: Color,
	duration: float,
	effect_event_id: int = 0
) -> void:
	pass

@rpc("authority", "call_remote", "unreliable", 7)
func net_collectible_follow_visual_effect(
	effect_type: String,
	owner_peer_id: int,
	radius: float,
	duration: float,
	effect_event_id: int = 0
) -> void:
	pass

@rpc("authority", "call_remote", "reliable", 6)
func net_cheat_xirang_confirmed(peer_id: int, current_xirang: int, added_amount: int) -> void:
	pass

@rpc("authority", "call_remote", "reliable", 6)
func net_debug_collectible_granted(
	peer_id: int,
	config_path: String,
	success: bool,
	inventory_snapshot: Dictionary = {}
) -> void:
	pass
