extends "res://scene/multiplayer/mp_game.gd"
class_name EnemyGameplayGatewayTestSession

const MpProjectileCoordinator := preload(
	"res://scene/multiplayer/projectile/mp_projectile_coordinator.gd"
)

## Typed recording session for entity-to-network boundary tests. It inherits
## the real projectile contact ledger, while player damage requests terminate
## here instead of reaching a fake current-scene game object.

var accept_player_damage_requests := true
var player_damage_requests: Array[Dictionary] = []
var data_projectile_finish_notifications: Array[Dictionary] = []


func _init() -> void:
	var coordinator := MpProjectileCoordinator.new()
	coordinator.name = "ProjectileCoordinator"
	add_child(coordinator)
	projectile_coordinator = coordinator


func request_multiplayer_player_damage(
	source_id: int,
	target_peer_id: int,
	damage: int,
	source_type: StringName,
	damage_type_or_source_direction: Variant = EnemyConfig.DamageType.PHYSICAL,
	source_direction_or_is_ranged: Variant = Vector2.ZERO,
	is_ranged: bool = false,
	contact_preconsumed: bool = false
) -> bool:
	var damage_type := int(EnemyConfig.DamageType.PHYSICAL)
	if damage_type_or_source_direction is int:
		damage_type = int(damage_type_or_source_direction)
	var source_direction := Vector2.ZERO
	if source_direction_or_is_ranged is Vector2:
		source_direction = source_direction_or_is_ranged as Vector2
	player_damage_requests.append({
		"source_id": source_id,
		"target_peer_id": target_peer_id,
		"damage": damage,
		"source_type": source_type,
		"damage_type": damage_type,
		"source_direction": source_direction,
		"is_ranged": is_ranged,
		"contact_preconsumed": contact_preconsumed,
	})
	return accept_player_damage_requests


func notify_data_projectile_finished(
	projectile_id: int,
	service: RapidFireSimulationService,
	handle: int
) -> void:
	data_projectile_finish_notifications.append({
		"projectile_id": projectile_id,
		"service": service,
		"handle": handle,
	})
	super.notify_data_projectile_finished(projectile_id, service, handle)


func request_multiplayer_player_damage_with_source_snapshot(
	source_snapshot: DamageSourceSnapshot,
	target_peer_id: int,
	damage: int,
	damage_type: EnemyConfig.DamageType = EnemyConfig.DamageType.PHYSICAL,
	source_direction: Vector2 = Vector2.ZERO,
	is_ranged: bool = false,
	contact_preconsumed: bool = false
) -> bool:
	if source_snapshot == null or not source_snapshot.is_valid():
		return false
	return request_multiplayer_player_damage(
		source_snapshot.event_source_id,
		target_peer_id,
		damage,
		source_snapshot.source_type,
		damage_type,
		source_direction,
		is_ranged,
		contact_preconsumed
	)


func _is_fire_sorcerer_fireball_contact_consumed(
	projectile_id: int,
	source_type: StringName
) -> bool:
	return projectile_coordinator.is_fire_sorcerer_fireball_contact_consumed(
		projectile_id,
		source_type
	)
