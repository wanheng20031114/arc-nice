extends Node2D
class_name ImmediateHitscanResolver

## Synchronous, allocation-stable ray resolver for authoritative enemy
## hitscans. The caller owns aim/scatter RNG and supplies the final endpoints;
## this service performs one native query for an ordinary terminal hit and only
## adds queries when dead or non-hostile combat bodies must be transparent.

enum HitKind {
	NONE,
	WORLD,
	PLAYER,
	PLANT,
	OTHER,
	ENEMY,
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
	var source_faction_id := CombatRelationService.NEUTRAL
	var damage_type := int(EnemyConfig.DamageType.PHYSICAL)
	var query_count := 0
	var transparent_hit_count := 0


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
		source_faction_id = CombatRelationService.NEUTRAL
		damage_type = int(new_damage_type)
		query_count = 0
		transparent_hit_count = 0


var _combat_runtime: CombatRuntimeBase = null
var _ray_query := PhysicsRayQueryParameters2D.create(
	Vector2.ZERO,
	Vector2.ZERO,
	0
)
var _ray_exclude: Array[RID] = []
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
	damage_type: EnemyConfig.DamageType,
	source_snapshot: DamageSourceSnapshot = null,
	source_collider: CollisionObject2D = null
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
	var frozen_snapshot := _freeze_source_snapshot(
		source_snapshot,
		source_enemy_id,
		source_projectile_id,
		source_type
	)
	_resolution.source_faction_id = frozen_snapshot.source_faction_id
	var request := _make_damage_request(
		damage,
		damage_type,
		from_position.direction_to(to_position),
		source_enemy_id,
		source_projectile_id,
		source_type,
		frozen_snapshot
	)

	_ray_query.from = from_position
	_ray_query.to = to_position
	_ray_query.collision_mask = collision_mask
	_ray_exclude.clear()
	if source_collider != null and is_instance_valid(source_collider):
		_exclude_collider(source_collider)
	_ray_query.exclude = _ray_exclude
	while true:
		_query_count += 1
		_resolution.query_count += 1
		var hit := get_world_2d().direct_space_state.intersect_ray(_ray_query)
		if hit.is_empty():
			return _resolution
		var collider := hit.get("collider") as Node2D
		if _is_transparent_target(collider, request):
			if not _exclude_collider(collider):
				_set_resolution_hit(hit, collider, to_position)
				break
			_resolution.transparent_hit_count += 1
			continue
		_set_resolution_hit(hit, collider, to_position)
		break

	if authoritative:
		_authoritative_hit_count += 1
	else:
		_client_visual_hit_count += 1
	if authoritative and damage > 0:
		_resolution.damage_applied = _apply_authoritative_damage(
			_resolution.collider,
			request,
			frozen_snapshot
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
	request: DamageRequest,
	source_snapshot: DamageSourceSnapshot
) -> bool:
	var hit_plant := collider as PlantDefense
	if hit_plant != null:
		if hit_plant.is_dead or hit_plant.is_removing:
			return false
		return hit_plant.apply_combat_damage(request).accepted

	var hit_enemy := collider as Enemy
	if hit_enemy != null:
		if hit_enemy.is_dead:
			return false
		return hit_enemy.apply_combat_damage(request).accepted

	var hit_player := collider as Player
	if hit_player == null or hit_player.is_dead:
		return false
	if (
		_combat_runtime.runtime_mode
		== CombatRuntimeBase.RuntimeMode.SINGLEPLAYER
	):
		return hit_player.apply_combat_damage(request).accepted

	var source_id := (
		maxi(request.source_projectile_id, 0)
		if request.source_projectile_id > 0
		else maxi(request.source_enemy_id, 0)
	)
	var gateway := _combat_runtime.get_multiplayer_gameplay_gateway()
	return (
		source_id > 0
		and gateway != null
		and is_instance_valid(gateway)
		and gateway.request_player_damage(
			source_id,
			hit_player.peer_id,
			request.amount,
			request.source_type,
			request.damage_type as EnemyConfig.DamageType,
			request.get_safe_source_direction(),
			request.has_flag(CombatTypes.DamageFlag.RANGED),
			false,
			source_snapshot
		)
	)


func _make_damage_request(
	damage: int,
	damage_type: EnemyConfig.DamageType,
	shot_direction: Vector2,
	source_enemy_id: int,
	source_projectile_id: int,
	source_type: StringName,
	source_snapshot: DamageSourceSnapshot
) -> DamageRequest:
	return (
		DamageRequest.new(damage, int(damage_type))
		.with_stable_source(
			source_enemy_id,
			source_projectile_id,
			source_type,
			source_snapshot
		)
		.with_directions(shot_direction, -shot_direction)
		.with_flag(CombatTypes.DamageFlag.RANGED)
	)


func _freeze_source_snapshot(
	source_snapshot: DamageSourceSnapshot,
	source_enemy_id: int,
	source_projectile_id: int,
	source_type: StringName
) -> DamageSourceSnapshot:
	if source_snapshot != null:
		return source_snapshot.duplicate_snapshot()
	var event_source_id := (
		maxi(source_projectile_id, 0)
		if source_projectile_id > 0
		else maxi(source_enemy_id, 0)
	)
	# Compatibility calls to this enemy-only service predate explicit snapshots.
	# Freeze them as wave-hostile here instead of letting DamageRequest's global
	# no-source compatibility rule reinterpret them as player-owned damage.
	return DamageSourceSnapshot.create(
		CombatRelationService.HOSTILE_WAVE,
		0,
		maxi(source_enemy_id, 0),
		event_source_id,
		source_type
	)


func _classify_hit(collider: Node2D) -> HitKind:
	if collider is Player:
		return HitKind.PLAYER
	if collider is PlantDefense:
		return HitKind.PLANT
	if collider is Enemy:
		return HitKind.ENEMY
	if collider is CollisionObject2D:
		var collision_object := collider as CollisionObject2D
		if (collision_object.collision_layer & 1) != 0:
			return HitKind.WORLD
	return HitKind.OTHER


func _set_resolution_hit(
	hit: Dictionary,
	collider: Node2D,
	to_position: Vector2
) -> void:
	_resolution.hit = true
	_resolution.visual_hit = true
	_resolution.hit_kind = _classify_hit(collider)
	_resolution.collider = collider
	_resolution.position = hit.get("position", to_position) as Vector2
	_resolution.normal = hit.get("normal", Vector2.ZERO) as Vector2


func _is_transparent_target(
	collider: Node2D,
	request: DamageRequest
) -> bool:
	var plant := collider as PlantDefense
	if plant != null and (plant.is_dead or plant.is_removing):
		return true
	var enemy := collider as Enemy
	if enemy != null and enemy.is_dead:
		return true
	var player := collider as Player
	if player != null and player.is_dead:
		return true
	if request == null or collider == null:
		return false
	if not collider.has_method(&"get_combat_faction_id"):
		return false
	return CombatDamageAdmission.get_rejection_reason(
		request,
		int(collider.call(&"get_combat_faction_id")),
		_combat_runtime.get_combat_relation_service()
	) == CombatTypes.DamageRejectionReason.NON_HOSTILE


func _exclude_collider(collider: Node2D) -> bool:
	var collision_object := collider as CollisionObject2D
	if collision_object == null:
		return false
	var collider_rid := collision_object.get_rid()
	if not collider_rid.is_valid() or _ray_exclude.has(collider_rid):
		return false
	_ray_exclude.append(collider_rid)
	_ray_query.exclude = _ray_exclude
	return true


func _exit_tree() -> void:
	prepare_for_runtime_teardown()
