extends Node
class_name MultiplayerGameplayGateway

## Neutral runtime-to-session boundary. Entity code receives this object
## explicitly; it must never discover networking through SceneTree.current_scene.
signal enemy_spawned(
	net_id: int,
	enemy_config: EnemyConfig,
	spawn_position: Vector2
)
signal enemy_defeated(net_id: int, defeat_position: Vector2)
signal enemy_removed(net_id: int)
signal enemy_escaped(net_id: int)
signal pickup_spawned(
	net_id: int,
	pickup_config: PickupConfig,
	spawn_position: Vector2
)
signal pickup_collected(
	net_id: int,
	collector_peer_id: int,
	pickup_config: PickupConfig,
	applied_immediately: bool
)
signal pickup_removed(net_id: int)
signal player_teleport_requested(peer_id: int, target_position: Vector2)

var runtime: CombatRuntimeBase = null
var multiplayer_session: MultiplayerGameplaySession = null


func _ready() -> void:
	bind_runtime(get_parent() as CombatRuntimeBase)


func bind_runtime(runtime_instance: CombatRuntimeBase) -> void:
	runtime = runtime_instance


func attach_multiplayer_session(
	session: MultiplayerGameplaySession
) -> void:
	multiplayer_session = session


func detach_multiplayer_session(
	session: MultiplayerGameplaySession
) -> void:
	if multiplayer_session == session:
		multiplayer_session = null


func is_bound() -> bool:
	return runtime != null and is_instance_valid(runtime)


func is_client_view() -> bool:
	return (
		is_bound()
		and runtime.runtime_mode == CombatRuntimeBase.RuntimeMode.CLIENT_VIEW
	)


func get_runtime_root() -> CombatRuntimeBase:
	return runtime if is_bound() else null


func get_projectile_parent() -> Node:
	return get_runtime_root()


func allows_enemy_pickup_drops() -> bool:
	var runtime_root := get_runtime_root()
	if runtime_root == null:
		return false
	var mode_adapter := runtime_root.get_multiplayer_mode_adapter()
	return (
		mode_adapter != null
		and mode_adapter.allows_enemy_pickup_drops()
	)


func acquire_session_object(scene: PackedScene, strict: bool = false) -> Node:
	if not is_bound():
		return null
	return runtime.acquire_session_object(scene, strict)


func release_session_object(instance: Node) -> bool:
	return is_bound() and runtime.release_session_object(instance)


func register_local_projectile(
	projectile: Node,
	projectile_type: StringName,
	owner_peer_id: int,
	spawn_position: Vector2,
	direction: Vector2,
	damage: int,
	speed: float,
	lifetime: float,
	pierces_enemies: bool = false,
	target_peer_id: int = 0,
	target_enemy_net_id: int = 0
) -> void:
	if multiplayer_session == null:
		return
	multiplayer_session.register_local_projectile(
		projectile,
		projectile_type,
		owner_peer_id,
		spawn_position,
		direction,
		damage,
		speed,
		lifetime,
		pierces_enemies,
		target_peer_id,
		target_enemy_net_id
	)


func request_enemy_hit_report(
	projectile_id: int,
	owner_peer_id: int,
	enemy_net_id: int,
	damage: int,
	impact_direction: Vector2
) -> bool:
	if multiplayer_session == null:
		return false
	multiplayer_session.request_enemy_hit_report(
		projectile_id,
		owner_peer_id,
		enemy_net_id,
		damage,
		impact_direction
	)
	return true


func request_player_damage(
	source_id: int,
	target_peer_id: int,
	damage: int,
	source_type: StringName,
	damage_type: EnemyConfig.DamageType = EnemyConfig.DamageType.PHYSICAL,
	source_direction: Vector2 = Vector2.ZERO,
	is_ranged: bool = false,
	contact_preconsumed: bool = false
) -> bool:
	if multiplayer_session == null:
		return false
	return multiplayer_session.request_multiplayer_player_damage(
		source_id,
		target_peer_id,
		damage,
		source_type,
		damage_type,
		source_direction,
		is_ranged,
		contact_preconsumed
	)


func broadcast_enemy_action(
	net_id: int,
	action_name: StringName,
	direction: Vector2,
	action_position: Vector2,
	action_id: int
) -> void:
	if multiplayer_session != null:
		multiplayer_session.broadcast_enemy_action(
			net_id,
			action_name,
			direction,
			action_position,
			action_id
		)


func broadcast_enemy_target_action(
	net_id: int,
	action_name: StringName,
	target_peer_id: int,
	action_position: Vector2,
	action_id: int
) -> void:
	if multiplayer_session != null:
		multiplayer_session.broadcast_enemy_target_action(
			net_id,
			action_name,
			target_peer_id,
			action_position,
			action_id
		)


func broadcast_enemy_lightning_chain(points: PackedVector2Array) -> void:
	if multiplayer_session != null:
		multiplayer_session.broadcast_enemy_lightning_chain(points)


func register_local_tango_laser_volley(
	projectiles: Array[Node],
	spawn_positions: PackedVector2Array,
	direction: Vector2,
	owner_peer_id: int,
	damage: int,
	speed: float,
	lifetime: float,
	charge_ratio: float,
	barrage_remaining_seconds: float
) -> bool:
	if multiplayer_session == null:
		return false
	return multiplayer_session.register_local_tango_laser_volley(
		projectiles,
		spawn_positions,
		direction,
		owner_peer_id,
		damage,
		speed,
		lifetime,
		charge_ratio,
		barrage_remaining_seconds
	)


func register_local_linglan_skill1_ring(
	projectiles: Array[Node],
	spawn_positions: PackedVector2Array,
	directions: PackedVector2Array,
	owner_peer_id: int,
	damage: int,
	speed: float,
	lifetime: float
) -> void:
	if multiplayer_session != null:
		multiplayer_session.register_local_linglan_skill1_ring(
			projectiles,
			spawn_positions,
			directions,
			owner_peer_id,
			damage,
			speed,
			lifetime
		)


func request_player_burn_tick(
	player_peer_id: int,
	source_family: StringName
) -> bool:
	return (
		multiplayer_session != null
		and multiplayer_session.request_multiplayer_player_burn_tick(
			player_peer_id,
			source_family
		)
	)


func request_player_damage_over_time_tick(
	player_peer_id: int,
	status_id: StringName,
	source_family: StringName,
	tick_damage: int
) -> bool:
	return (
		multiplayer_session != null
		and multiplayer_session.request_multiplayer_player_damage_over_time_tick(
			player_peer_id,
			status_id,
			source_family,
			tick_damage
		)
	)


func request_player_hit_report(
	source_id: int,
	player_peer_id: int,
	source_type: StringName,
	impact_direction: Vector2,
	damage_flags: int
) -> void:
	if multiplayer_session != null:
		multiplayer_session.request_player_hit_report(
			source_id,
			player_peer_id,
			source_type,
			impact_direction,
			damage_flags
		)


func try_consume_fire_sorcerer_fireball_contact(
	projectile_id: int,
	source_type: StringName
) -> bool:
	return (
		multiplayer_session != null
		and multiplayer_session.try_consume_fire_sorcerer_fireball_contact(
			projectile_id,
			source_type
		)
	)


func try_consume_frost_sorcerer_ice_spike_contact(
	projectile_id: int,
	source_type: StringName
) -> bool:
	return (
		multiplayer_session != null
		and multiplayer_session.try_consume_frost_sorcerer_ice_spike_contact(
			projectile_id,
			source_type
		)
	)


func apply_collectible_enemy_damage(
	enemy: Enemy,
	damage: int,
	impact_direction: Vector2,
	damage_type: EnemyConfig.DamageType = EnemyConfig.DamageType.MAGIC,
	show_hit_particles: bool = true
) -> bool:
	return (
		multiplayer_session != null
		and multiplayer_session.apply_multiplayer_collectible_enemy_damage(
			enemy,
			damage,
			impact_direction,
			int(damage_type),
			show_hit_particles
		)
	)


func apply_player_heal(target_player: Player, heal_amount: int) -> bool:
	return (
		multiplayer_session != null
		and multiplayer_session.apply_multiplayer_player_heal(
			target_player,
			heal_amount
		)
	)


func apply_collectible_player_heal(
	target_player: Player,
	heal_amount: int
) -> bool:
	return (
		multiplayer_session != null
		and multiplayer_session.apply_multiplayer_collectible_player_heal(
			target_player,
			heal_amount
		)
	)


func report_player_healing(
	target_player: Player,
	confirmed_healing: int
) -> void:
	if multiplayer_session != null:
		multiplayer_session.report_multiplayer_player_healing(
			target_player,
			confirmed_healing
		)


func notify_local_player_dash_started(
	direction: Vector2,
	start_move_input: Vector2
) -> void:
	if multiplayer_session != null:
		multiplayer_session.notify_local_player_dash_started(
			direction,
			start_move_input
		)


func request_hoe_primary_attack(direction: Vector2) -> bool:
	return (
		multiplayer_session != null
		and multiplayer_session.request_hoe_primary_attack(direction)
	)


func request_hoe_whirlwind() -> bool:
	return (
		multiplayer_session != null
		and multiplayer_session.request_hoe_whirlwind()
	)


func request_tango_electric_surge() -> bool:
	return (
		multiplayer_session != null
		and multiplayer_session.request_tango_electric_surge()
	)


func spawn_authoritative_tango_electric_surge_field(
	owner_player: Player,
	activation_id: int,
	origin: Vector2
) -> bool:
	return (
		multiplayer_session != null
		and multiplayer_session.spawn_authoritative_tango_electric_surge_field(
			owner_player,
			activation_id,
			origin
		)
	)


func spawn_remote_tango_electric_surge_visual_field(
	activation_id: int,
	origin: Vector2,
	remaining_seconds: float
) -> bool:
	return (
		multiplayer_session != null
		and multiplayer_session.spawn_remote_tango_electric_surge_visual_field(
			activation_id,
			origin,
			remaining_seconds
		)
	)


func request_tango_charge_started(direction: Vector2) -> bool:
	return (
		multiplayer_session != null
		and multiplayer_session.request_tango_charge_started(direction)
	)


func request_tango_charge_released(direction: Vector2) -> bool:
	return (
		multiplayer_session != null
		and multiplayer_session.request_tango_charge_released(direction)
	)


func request_tango_charge_cancelled() -> bool:
	return (
		multiplayer_session != null
		and multiplayer_session.request_tango_charge_cancelled()
	)


func request_tiyi_high_noon() -> bool:
	return (
		multiplayer_session != null
		and multiplayer_session.request_tiyi_high_noon()
	)


func notify_tiyi_high_noon_targets_changed(
	peer_id: int,
	activation_id: int,
	target_ids: PackedInt32Array
) -> void:
	if multiplayer_session != null:
		multiplayer_session.notify_tiyi_high_noon_targets_changed(
			peer_id,
			activation_id,
			target_ids
		)


func resolve_tiyi_high_noon(
	peer_id: int,
	activation_id: int,
	target_ids: PackedInt32Array,
	hit_positions: PackedVector2Array
) -> void:
	if multiplayer_session != null:
		multiplayer_session.resolve_tiyi_high_noon(
			peer_id,
			activation_id,
			target_ids,
			hit_positions
		)


func cancel_tiyi_high_noon(peer_id: int, activation_id: int) -> void:
	if multiplayer_session != null:
		multiplayer_session.cancel_tiyi_high_noon(peer_id, activation_id)


func broadcast_collectible_visual_effect(
	effect_type: StringName,
	spawn_position: Vector2,
	radius: float,
	color: Color,
	duration: float
) -> void:
	if multiplayer_session != null:
		multiplayer_session.broadcast_collectible_visual_effect(
			effect_type,
			spawn_position,
			radius,
			color,
			duration
		)


func broadcast_collectible_follow_visual_effect(
	effect_type: StringName,
	owner_peer_id: int,
	radius: float,
	duration: float
) -> void:
	if multiplayer_session != null:
		multiplayer_session.broadcast_collectible_follow_visual_effect(
			effect_type,
			owner_peer_id,
			radius,
			duration
		)


func request_multiplayer_cheat_xirang() -> bool:
	if multiplayer_session == null:
		return false
	multiplayer_session.request_multiplayer_cheat_xirang()
	return true
