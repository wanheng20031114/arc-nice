extends RefCounted
class_name CombatQueryFacade

const TargetDescriptor := preload(
	"res://scene/combat/targeting/combat_target_descriptor.gd"
)
const Relations := preload(
	"res://scene/combat/faction/combat_relation_service.gd"
)

## Single-player has no network peer roster, but descriptors still require a
## positive player ID. Multiplayer peer IDs start at one, so the same canonical
## value can represent the sole local player without creating another namespace.
const SINGLEPLAYER_PLAYER_ID := 1

var _runtime: CombatRuntimeBase = null
var _plant_resolver := Callable()
var _plant_radius_query_into := Callable()
var _plant_aabb_query_into := Callable()
var _plant_id_resolver := Callable()

var _player_scratch: Array[Player] = []
var _enemy_scratch: Array[Enemy] = []
var _plant_scratch: Array[PlantDefense] = []


func _init(runtime: CombatRuntimeBase = null) -> void:
	_runtime = runtime


func bind_runtime(runtime: CombatRuntimeBase) -> void:
	_runtime = runtime


## PlantSystem owns the stationary plant index and net-ID table. These explicit
## callables let the facade cooperate with that owner without reflecting over it
## or copying its storage into the dynamic enemy hash.
##
## Expected signatures:
##   resolver(net_id: int) -> PlantDefense
##   radius_query(center: Vector2, radius: float, result: Array[PlantDefense])
##   aabb_query(world_aabb: Rect2, result: Array[PlantDefense])
##   id_resolver(plant: PlantDefense) -> int
func bind_plant_query_port(
	resolver: Callable,
	radius_query_into: Callable,
	aabb_query_into: Callable = Callable(),
	id_resolver: Callable = Callable()
) -> bool:
	if not resolver.is_valid() or not radius_query_into.is_valid():
		return false
	_plant_resolver = resolver
	_plant_radius_query_into = radius_query_into
	_plant_aabb_query_into = aabb_query_into
	_plant_id_resolver = id_resolver
	return true


func clear_plant_query_port() -> void:
	_plant_resolver = Callable()
	_plant_radius_query_into = Callable()
	_plant_aabb_query_into = Callable()
	_plant_id_resolver = Callable()
	_plant_scratch.clear()


func describe_target(
	target: Node2D,
	target_revision: int = 0
) -> CombatTargetDescriptor:
	if target == null or not is_instance_valid(target) or target_revision < 0:
		return null
	var player_target := target as Player
	if player_target != null:
		return describe_player(player_target, target_revision)
	var plant_target := target as PlantDefense
	if plant_target != null:
		return describe_plant(plant_target, target_revision)
	var enemy_target := target as Enemy
	if enemy_target != null:
		return describe_enemy(enemy_target, target_revision)
	return null


func describe_player(
	target: Player,
	target_revision: int = 0
) -> CombatTargetDescriptor:
	if not _is_living_player(target) or target_revision < 0:
		return null
	var peer_id := _get_player_peer_id(target)
	if peer_id <= 0:
		return null
	return TargetDescriptor.create_player(
		peer_id,
		target_revision,
		target.global_position
	)


func describe_plant(
	target: PlantDefense,
	target_revision: int = 0
) -> CombatTargetDescriptor:
	if not _is_living_plant(target) or target_revision < 0:
		return null
	var net_id := _get_plant_net_id(target)
	if net_id <= 0:
		return null
	return TargetDescriptor.create_plant(
		net_id,
		target_revision,
		target.global_position
	)


func describe_enemy(
	target: Enemy,
	target_revision: int = 0
) -> CombatTargetDescriptor:
	if not CombatTargetIndex.is_enemy_queryable(target) or target_revision < 0:
		return null
	var net_id := _get_enemy_net_id(target)
	if net_id <= 0:
		return null
	return TargetDescriptor.create_enemy(
		net_id,
		target_revision,
		target.global_position
	)


func resolve_target(descriptor: CombatTargetDescriptor) -> Node2D:
	if _runtime == null or descriptor == null or not descriptor.is_valid():
		return null
	match descriptor.kind:
		TargetDescriptor.Kind.NONE:
			return null
		TargetDescriptor.Kind.PLAYER:
			return _resolve_player(descriptor.id)
		TargetDescriptor.Kind.PLANT:
			return _resolve_plant(descriptor.id)
		TargetDescriptor.Kind.ENEMY:
			return _resolve_enemy(descriptor.id)
	return null


func get_target_faction_id(target: Node2D) -> int:
	if target == null or not is_instance_valid(target):
		return Relations.NEUTRAL
	# Known combat families stay on typed calls in the hot query path. The
	# contract fallback keeps future Node2D combatants extensible without
	# hardcoding their faction value in this facade.
	var enemy := target as Enemy
	if enemy != null:
		return Relations.normalize_faction_id(
			enemy.get_combat_faction_id(),
			Relations.NEUTRAL
		)
	var player := target as Player
	if player != null:
		return Relations.normalize_faction_id(
			player.get_combat_faction_id(),
			Relations.NEUTRAL
		)
	var plant := target as PlantDefense
	if plant != null:
		return Relations.normalize_faction_id(
			plant.get_combat_faction_id(),
			Relations.NEUTRAL
		)
	if target.has_method(&"get_combat_faction_id"):
		var faction_variant: Variant = target.call(&"get_combat_faction_id")
		if faction_variant is int:
			return Relations.normalize_faction_id(
				int(faction_variant),
				Relations.NEUTRAL
			)
	return Relations.NEUTRAL


func is_target_hostile(
	source_faction_id: int,
	target: Node2D,
	relation_service: CombatRelationService = null
) -> bool:
	if target == null or not is_instance_valid(target):
		return false
	return _is_hostile_relation(
		source_faction_id,
		get_target_faction_id(target),
		relation_service
	)


## Unified exact-radius query. The three stores remain independent; only the
## caller-owned result is combined and deterministically ordered by distance,
## kind and stable ID. Player count stays a compact direct traversal, plants use
## their injected stationary index, and enemies use CombatTargetIndex.
func query_hostile_radius_into(
	center: Vector2,
	radius: float,
	source_faction_id: int,
	result: Array[Node2D],
	excluded_target: Node2D = null,
	max_count: int = 0,
	relation_service: CombatRelationService = null,
	include_players: bool = true,
	include_plants: bool = true,
	include_enemies: bool = true
) -> void:
	result.clear()
	if (
		_runtime == null
		or not center.is_finite()
		or not is_finite(radius)
		or radius < 0.0
		or not Relations.is_valid_faction_id(source_faction_id)
	):
		return
	var radius_squared := radius * radius
	if include_players and _is_hostile_relation(
		source_faction_id,
		Relations.PLAYER_ALLIED,
		relation_service
	):
		_append_living_players_in_radius(
			center,
			radius_squared,
			result,
			excluded_target
		)
	if (
		include_plants
		and _plant_radius_query_into.is_valid()
		and _is_hostile_relation(
			source_faction_id,
			Relations.PLAYER_ALLIED,
			relation_service
		)
	):
		_plant_scratch.clear()
		_plant_radius_query_into.call(center, radius, _plant_scratch)
		for plant in _plant_scratch:
			if plant == excluded_target or not _is_living_plant(plant):
				continue
			if center.distance_squared_to(plant.global_position) <= radius_squared:
				result.append(plant)
	if include_enemies:
		_enemy_scratch.clear()
		_runtime.combat_target_index.query_hostile_radius_into(
			center,
			radius,
			source_faction_id,
			_enemy_scratch,
			0,
			excluded_target as Enemy,
			relation_service
		)
		for enemy in _enemy_scratch:
			result.append(enemy)
	result.sort_custom(
		func(a: Node2D, b: Node2D) -> bool:
			return _is_radius_candidate_before(a, b, center)
	)
	_limit_result(result, max_count)


## AABB enumeration is intended for client visibility and minimap candidate
## gathering. Final rendering aggregation remains with the caller.
func query_world_aabb_into(
	world_aabb: Rect2,
	result: Array[Node2D],
	excluded_target: Node2D = null,
	max_count: int = 0,
	include_players: bool = true,
	include_plants: bool = true,
	include_enemies: bool = true
) -> void:
	result.clear()
	if (
		_runtime == null
		or not world_aabb.position.is_finite()
		or not world_aabb.size.is_finite()
	):
		return
	var normalized_aabb := world_aabb.abs()
	if normalized_aabb.size.x <= 0.0 or normalized_aabb.size.y <= 0.0:
		return
	if include_players:
		_append_living_players_in_aabb(
			normalized_aabb,
			result,
			excluded_target
		)
	if include_plants and _plant_aabb_query_into.is_valid():
		_plant_scratch.clear()
		_plant_aabb_query_into.call(normalized_aabb, _plant_scratch)
		for plant in _plant_scratch:
			if (
				plant != excluded_target
				and _is_living_plant(plant)
				and normalized_aabb.has_point(plant.global_position)
			):
				result.append(plant)
	if include_enemies:
		_enemy_scratch.clear()
		_runtime.combat_target_index.query_world_aabb_into(
			normalized_aabb,
			_enemy_scratch
		)
		for enemy in _enemy_scratch:
			if enemy != excluded_target:
				result.append(enemy)
	result.sort_custom(
		func(a: Node2D, b: Node2D) -> bool:
			return _is_stable_candidate_before(a, b)
	)
	_limit_result(result, max_count)


## Faction-aware AABB broadphase for contact simulation. Unlike the generic
## visibility query above, enemy candidates are pruned directly by faction
## partitions and are never materialized through an all-enemy intermediate.
func query_hostile_world_aabb_into(
	world_aabb: Rect2,
	source_faction_id: int,
	result: Array[Node2D],
	excluded_target: Node2D = null,
	max_count: int = 0,
	relation_service: CombatRelationService = null,
	include_players: bool = true,
	include_plants: bool = true,
	include_enemies: bool = true
) -> void:
	result.clear()
	if (
		_runtime == null
		or not world_aabb.position.is_finite()
		or not world_aabb.size.is_finite()
		or not Relations.is_valid_faction_id(source_faction_id)
	):
		return
	var normalized_aabb := world_aabb.abs()
	if normalized_aabb.size.x <= 0.0 or normalized_aabb.size.y <= 0.0:
		return
	var allied_is_hostile := _is_hostile_relation(
		source_faction_id,
		Relations.PLAYER_ALLIED,
		relation_service
	)
	if include_players and allied_is_hostile:
		_append_living_players_in_aabb(
			normalized_aabb,
			result,
			excluded_target
		)
	if include_plants and allied_is_hostile and _plant_aabb_query_into.is_valid():
		_plant_scratch.clear()
		_plant_aabb_query_into.call(normalized_aabb, _plant_scratch)
		for plant in _plant_scratch:
			if (
				plant != excluded_target
				and _is_living_plant(plant)
				and normalized_aabb.has_point(plant.global_position)
			):
				result.append(plant)
	if include_enemies:
		_enemy_scratch.clear()
		_runtime.combat_target_index.query_hostile_world_aabb_unordered_into(
			normalized_aabb,
			source_faction_id,
			_enemy_scratch,
			excluded_target as Enemy,
			relation_service
		)
		for enemy in _enemy_scratch:
			result.append(enemy)
	result.sort_custom(
		func(a: Node2D, b: Node2D) -> bool:
			return _is_stable_candidate_before(a, b)
	)
	_limit_result(result, max_count)


func _append_living_players_in_radius(
	center: Vector2,
	radius_squared: float,
	result: Array[Node2D],
	excluded_target: Node2D
) -> void:
	_collect_living_players()
	for candidate in _player_scratch:
		if (
			candidate != excluded_target
			and center.distance_squared_to(candidate.global_position) <= radius_squared
		):
			result.append(candidate)


func _append_living_players_in_aabb(
	world_aabb: Rect2,
	result: Array[Node2D],
	excluded_target: Node2D
) -> void:
	_collect_living_players()
	for candidate in _player_scratch:
		if (
			candidate != excluded_target
			and world_aabb.has_point(candidate.global_position)
		):
			result.append(candidate)


func _collect_living_players() -> void:
	_player_scratch.clear()
	if _is_living_player(_runtime.player):
		_player_scratch.append(_runtime.player)
	for peer_id_variant in _runtime.peer_players:
		var candidate := _runtime.peer_players[peer_id_variant] as Player
		if candidate == _runtime.player or not _is_living_player(candidate):
			continue
		_player_scratch.append(candidate)


func _resolve_player(peer_id: int) -> Player:
	if peer_id <= 0:
		return null
	var candidate: Player = null
	if (
		_runtime.player != null
		and (
			_runtime.multiplayer_local_peer_id == peer_id
			or (
				_runtime.multiplayer_local_peer_id <= 0
				and peer_id == SINGLEPLAYER_PLAYER_ID
			)
		)
	):
		candidate = _runtime.player
	if candidate == null:
		candidate = _runtime.get_player_for_peer(peer_id)
	return candidate if _is_living_player(candidate) else null


func _resolve_plant(net_id: int) -> PlantDefense:
	if net_id <= 0 or not _plant_resolver.is_valid():
		return null
	var candidate := _plant_resolver.call(net_id) as PlantDefense
	return candidate if _is_living_plant(candidate) else null


func _resolve_enemy(net_id: int) -> Enemy:
	if net_id <= 0:
		return null
	var candidate := _runtime.combat_target_index.get_enemy(net_id)
	if candidate == null:
		candidate = _runtime.get_enemy_for_net_id(net_id)
	return candidate if CombatTargetIndex.is_enemy_queryable(candidate) else null


func _get_player_peer_id(target: Player) -> int:
	if _runtime == null:
		return 0
	if target == _runtime.player and _runtime.multiplayer_local_peer_id > 0:
		return _runtime.multiplayer_local_peer_id
	for peer_id_variant in _runtime.peer_players:
		if _runtime.peer_players[peer_id_variant] == target:
			var peer_id := int(peer_id_variant)
			return peer_id if peer_id > 0 else 0
	if target == _runtime.player:
		return SINGLEPLAYER_PLAYER_ID
	return 0


func _get_plant_net_id(target: PlantDefense) -> int:
	if _plant_id_resolver.is_valid():
		var resolved_id := int(_plant_id_resolver.call(target))
		if resolved_id > 0:
			return resolved_id
	var metadata_id := int(target.get_meta(&"net_id", 0))
	return metadata_id if metadata_id > 0 else 0


func _get_enemy_net_id(target: Enemy) -> int:
	var bound_id := target.combat_target_index_net_id
	if bound_id > 0:
		return bound_id
	if _runtime != null:
		var registered_id := _runtime.get_network_enemy_net_id_by_instance_id(
			target.get_instance_id()
		)
		if registered_id > 0:
			return registered_id
	var metadata_id := int(target.get_meta(&"net_id", 0))
	return metadata_id if metadata_id > 0 else 0


func _is_radius_candidate_before(
	a: Node2D,
	b: Node2D,
	center: Vector2
) -> bool:
	var a_distance := center.distance_squared_to(a.global_position)
	var b_distance := center.distance_squared_to(b.global_position)
	if a_distance != b_distance:
		return a_distance < b_distance
	return _is_stable_candidate_before(a, b)


func _is_stable_candidate_before(a: Node2D, b: Node2D) -> bool:
	var a_kind := _get_target_kind(a)
	var b_kind := _get_target_kind(b)
	if a_kind != b_kind:
		return a_kind < b_kind
	return _get_target_stable_id(a) < _get_target_stable_id(b)


func _get_target_kind(target: Node2D) -> int:
	if target is Player:
		return TargetDescriptor.Kind.PLAYER
	if target is PlantDefense:
		return TargetDescriptor.Kind.PLANT
	if target is Enemy:
		return TargetDescriptor.Kind.ENEMY
	return TargetDescriptor.Kind.NONE


func _get_target_stable_id(target: Node2D) -> int:
	var player_target := target as Player
	if player_target != null:
		return _get_player_peer_id(player_target)
	var plant_target := target as PlantDefense
	if plant_target != null:
		return _get_plant_net_id(plant_target)
	var enemy_target := target as Enemy
	if enemy_target != null:
		return _get_enemy_net_id(enemy_target)
	return 0


func _is_hostile_relation(
	source_faction_id: int,
	target_faction_id: int,
	relation_service: CombatRelationService
) -> bool:
	if relation_service != null:
		return relation_service.is_hostile(
			source_faction_id,
			target_faction_id
		)
	return Relations.is_default_hostile(source_faction_id, target_faction_id)


func _is_living_player(candidate: Player) -> bool:
	return (
		candidate != null
		and is_instance_valid(candidate)
		and not candidate.is_dead
		and not candidate.is_queued_for_deletion()
	)


func _is_living_plant(candidate: PlantDefense) -> bool:
	return (
		candidate != null
		and is_instance_valid(candidate)
		and not candidate.is_dead
		and not candidate.is_removing
		and not candidate.is_queued_for_deletion()
	)


func _limit_result(result: Array[Node2D], max_count: int) -> void:
	if max_count > 0 and result.size() > max_count:
		result.resize(max_count)
