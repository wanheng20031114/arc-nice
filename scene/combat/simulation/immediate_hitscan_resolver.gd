extends Node2D
class_name ImmediateHitscanResolver

## Synchronous, allocation-stable ray resolver for authoritative enemy
## hitscans. The caller owns aim/scatter RNG and supplies the final endpoints;
## this service performs exactly one native ray query in the current stack.

enum HitKind {
	NONE,
	WORLD,
	PLAYER,
	PLANT,
	OTHER,
}


class Resolution:
	extends RefCounted

	## Service-owned hot-path storage. Callers must consume fields immediately;
	## the next resolution overwrites this same object in place.
	var resolution_id := 0
	var hit := false
	var visual_hit := false
	var authoritative := false
	var damage := 0
	var damage_applied := false
	var hit_kind := HitKind.NONE
	var collider: Node2D = null
	var position := Vector2.ZERO
	var normal := Vector2.ZERO
	var source_enemy_id := 0
	var source_projectile_id := 0
	var source_type: StringName = &""
	var damage_type := int(EnemyConfig.DamageType.PHYSICAL)


	func reset(
		new_resolution_id: int,
		new_authoritative: bool,
		new_damage: int,
		new_source_enemy_id: int,
		new_source_projectile_id: int,
		new_source_type: StringName,
		new_damage_type: EnemyConfig.DamageType
	) -> void:
		resolution_id = new_resolution_id
		hit = false
		visual_hit = false
		authoritative = new_authoritative
		damage = maxi(new_damage, 0)
		damage_applied = false
		hit_kind = HitKind.NONE
		collider = null
		position = Vector2.ZERO
		normal = Vector2.ZERO
		source_enemy_id = maxi(new_source_enemy_id, 0)
		source_projectile_id = maxi(new_source_projectile_id, 0)
		source_type = new_source_type
		damage_type = int(new_damage_type)


var _combat_runtime: CombatRuntimeBase = null
var _ray_query := PhysicsRayQueryParameters2D.create(
	Vector2.ZERO,
	Vector2.ZERO,
	0
)
var _resolution := Resolution.new()
var _resolution_count := 0
var _query_count := 0
var _authoritative_hit_count := 0
var _client_visual_hit_count := 0
var _damage_application_count := 0
var _rejected_resolution_count := 0
var _bind_rejection_count := 0
var _teardown_prepared := false
var _teardown_count := 0


func _init() -> void:
	set_process(false)
	set_physics_process(false)
	_ray_query.collide_with_bodies = true
	_ray_query.collide_with_areas = false


func bind_combat_runtime(runtime: CombatRuntimeBase) -> bool:
	if (
		_teardown_prepared
		or runtime == null
		or not is_instance_valid(runtime)
		or (_combat_runtime != null and _combat_runtime != runtime)
	):
		_bind_rejection_count += 1
		return false
	_combat_runtime = runtime
	return true


func is_bound() -> bool:
	return (
		_combat_runtime != null
		and is_instance_valid(_combat_runtime)
		and not _teardown_prepared
	)


func is_bound_to(runtime: CombatRuntimeBase) -> bool:
	return is_bound() and _combat_runtime == runtime


func resolve_immediate_hitscan(
	from_position: Vector2,
	to_position: Vector2,
	collision_mask: int,
	damage: int,
	source_enemy_id: int,
	source_projectile_id: int,
	source_type: StringName,
	damage_type: EnemyConfig.DamageType
) -> Resolution:
	_resolution_count += 1
	var authoritative := _has_authority()
	_resolution.reset(
		_resolution_count,
		authoritative,
		damage,
		source_enemy_id,
		source_projectile_id,
		source_type,
		damage_type
	)
	if not is_bound():
		_rejected_resolution_count += 1
		return _resolution
	if (
		not from_position.is_finite()
		or not to_position.is_finite()
		or collision_mask <= 0
		or from_position.is_equal_approx(to_position)
	):
		_rejected_resolution_count += 1
		return _resolution

	_ray_query.from = from_position
	_ray_query.to = to_position
	_ray_query.collision_mask = collision_mask
	_query_count += 1
	var hit := get_world_2d().direct_space_state.intersect_ray(_ray_query)
	if hit.is_empty():
		return _resolution

	var collider := hit.get("collider") as Node2D
	_resolution.hit = true
	_resolution.visual_hit = true
	_resolution.hit_kind = _classify_hit(collider)
	_resolution.collider = collider
	_resolution.position = hit.get("position", to_position) as Vector2
	_resolution.normal = hit.get("normal", Vector2.ZERO) as Vector2
	if authoritative:
		_authoritative_hit_count += 1
	else:
		_client_visual_hit_count += 1
	if authoritative and damage > 0:
		_resolution.damage_applied = _apply_authoritative_damage(
			collider,
			from_position.direction_to(to_position),
			damage,
			source_enemy_id,
			source_projectile_id,
			source_type,
			damage_type
		)
		if _resolution.damage_applied:
			_damage_application_count += 1
	return _resolution


func get_resolution_count() -> int:
	return _resolution_count


func get_query_count() -> int:
	return _query_count


func get_query_instance_id() -> int:
	return _ray_query.get_instance_id()


func get_result_instance_id() -> int:
	return _resolution.get_instance_id()


func prepare_for_runtime_teardown() -> void:
	if _teardown_prepared:
		return
	_teardown_prepared = true
	_teardown_count += 1
	_combat_runtime = null
	_resolution.reset(
		_resolution_count,
		false,
		0,
		0,
		0,
		&"",
		EnemyConfig.DamageType.PHYSICAL
	)


func get_metrics() -> Dictionary:
	return {
		"bound": is_bound(),
		"resolution_count": _resolution_count,
		"query_count": _query_count,
		"authoritative_hit_count": _authoritative_hit_count,
		"client_visual_hit_count": _client_visual_hit_count,
		"damage_application_count": _damage_application_count,
		"rejected_resolution_count": _rejected_resolution_count,
		"bind_rejection_count": _bind_rejection_count,
		"query_instance_id": get_query_instance_id(),
		"result_instance_id": get_result_instance_id(),
		"teardown_prepared": _teardown_prepared,
		"teardown_count": _teardown_count,
	}


func _has_authority() -> bool:
	return (
		is_bound()
		and _combat_runtime.runtime_mode
			!= CombatRuntimeBase.RuntimeMode.CLIENT_VIEW
	)


func _apply_authoritative_damage(
	collider: Node2D,
	shot_direction: Vector2,
	damage: int,
	source_enemy_id: int,
	source_projectile_id: int,
	source_type: StringName,
	damage_type: EnemyConfig.DamageType
) -> bool:
	var hit_plant := collider as PlantDefense
	if hit_plant != null:
		if hit_plant.is_dead or hit_plant.is_removing:
			return false
		var plant_request := _make_damage_request(
			damage,
			damage_type,
			shot_direction,
			source_enemy_id,
			source_projectile_id,
			source_type
		)
		return hit_plant.apply_combat_damage(plant_request).accepted

	var hit_player := collider as Player
	if hit_player == null or hit_player.is_dead:
		return false
	if (
		_combat_runtime.runtime_mode
		== CombatRuntimeBase.RuntimeMode.SINGLEPLAYER
	):
		var player_request := _make_damage_request(
			damage,
			damage_type,
			shot_direction,
			source_enemy_id,
			source_projectile_id,
			source_type
		)
		return hit_player.apply_combat_damage(player_request).accepted

	var source_id := (
		maxi(source_projectile_id, 0)
		if source_projectile_id > 0
		else maxi(source_enemy_id, 0)
	)
	var gateway := _combat_runtime.get_multiplayer_gameplay_gateway()
	return (
		source_id > 0
		and gateway != null
		and is_instance_valid(gateway)
		and gateway.request_player_damage(
			source_id,
			hit_player.peer_id,
			damage,
			source_type,
			damage_type,
			-shot_direction,
			true
		)
	)


func _make_damage_request(
	damage: int,
	damage_type: EnemyConfig.DamageType,
	shot_direction: Vector2,
	source_enemy_id: int,
	source_projectile_id: int,
	source_type: StringName
) -> DamageRequest:
	return (
		DamageRequest.new(damage, int(damage_type))
		.with_stable_source(
			source_enemy_id,
			source_projectile_id,
			source_type
		)
		.with_directions(shot_direction, -shot_direction)
		.with_flag(CombatTypes.DamageFlag.RANGED)
	)


func _classify_hit(collider: Node2D) -> HitKind:
	if collider is Player:
		return HitKind.PLAYER
	if collider is PlantDefense:
		return HitKind.PLANT
	if collider is CollisionObject2D:
		var collision_object := collider as CollisionObject2D
		if (collision_object.collision_layer & 1) != 0:
			return HitKind.WORLD
	return HitKind.OTHER


func _exit_tree() -> void:
	prepare_for_runtime_teardown()
