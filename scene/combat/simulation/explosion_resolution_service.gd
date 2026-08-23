extends Node2D
class_name ExplosionResolutionService

const EnemyDamageableSpatialIndexScript := preload(
	"res://scene/combat/targeting/enemy_damageable_spatial_index.gd"
)
const CombatTargetIndexScript := preload(
	"res://scene/combat/targeting/combat_target_index.gd"
)

const BROAD_PHASE_CLOSED_BOUNDARY_EPSILON := 0.001

var _combat_runtime: CombatRuntimeBase = null
var _enemy_simulation_coordinator: EnemySimulationCoordinator = null
var _damageable_spatial_index: EnemyDamageableSpatialIndexScript = null
var _combat_target_index: CombatTargetIndexScript = null
var _combat_relation_service: CombatRelationService = null

var _explosion_shape := CircleShape2D.new()
var _indexed_candidates: Array = []
var _overlapping_plants: Array[PlantDefense] = []
var _cached_indexed_candidates: Array = []
var _cached_overlapping_plants: Array[PlantDefense] = []
var _cached_plant_query_position := Vector2(INF, INF)
var _cached_plant_query_radius := -1.0
var _cached_plant_geometry_revision := -1
var _player_candidates: Array[Player] = []
var _enemy_candidates: Array[Enemy] = []
var _accepted_instance_ids: Dictionary[int, bool] = {}

var _resolution_count := 0
var _accepted_damage_count := 0
var _rejected_resolution_count := 0
var _bind_rejection_count := 0
var _direct_attempt_count := 0
var _direct_accept_count := 0
var _indexed_aabb_query_count := 0
var _indexed_candidate_count := 0
var _indexed_exact_test_count := 0
var _indexed_exact_overlap_count := 0
var _player_broad_query_count := 0
var _player_candidate_count := 0
var _player_exact_test_count := 0
var _player_exact_overlap_count := 0
var _enemy_broad_query_count := 0
var _enemy_candidate_count := 0
var _enemy_exact_test_count := 0
var _enemy_exact_overlap_count := 0
var _native_shape_query_count := 0
var _native_candidate_count := 0
var _target_attempt_count := 0
var _duplicate_skip_count := 0
var _admission_rejection_count := 0
var _sink_rejection_count := 0
var _invalid_target_count := 0
var _player_request_count := 0
var _player_request_accept_count := 0
var _singleplayer_player_accept_count := 0
var _plant_accept_count := 0
var _enemy_accept_count := 0
var _active_resolution_count := 0
var _teardown_prepared := false
var _teardown_count := 0
var _metric_plant_query_cache_hits := 0
var _metric_plant_query_cache_misses := 0
var _metric_actual_indexed_aabb_queries := 0
var _metric_actual_indexed_exact_tests := 0


func _init() -> void:
	set_process(false)
	set_physics_process(false)


func bind_context(
	combat_runtime: CombatRuntimeBase,
	coordinator: EnemySimulationCoordinator
) -> bool:
	if (
		_teardown_prepared
		or combat_runtime == null
		or coordinator == null
		or not is_instance_valid(combat_runtime)
		or not is_instance_valid(coordinator)
		or coordinator.get_parent() != combat_runtime
		or (
			_combat_runtime != null
			and (
				_combat_runtime != combat_runtime
				or _enemy_simulation_coordinator != coordinator
			)
		)
	):
		_bind_rejection_count += 1
		return false
	var combat_services := coordinator.get_combat_services()
	if combat_services == null or not is_instance_valid(combat_services):
		_bind_rejection_count += 1
		return false
	var spatial_index := combat_services.get_enemy_damageable_spatial_index()
	if (
		spatial_index == null
		or not is_instance_valid(spatial_index)
		or not spatial_index.is_bound_to(combat_runtime, coordinator)
	):
		_bind_rejection_count += 1
		return false
	_combat_runtime = combat_runtime
	_enemy_simulation_coordinator = coordinator
	_damageable_spatial_index = spatial_index
	_combat_target_index = combat_runtime.combat_target_index
	_combat_relation_service = combat_runtime.get_combat_relation_service()
	if _combat_target_index == null or _combat_relation_service == null:
		_combat_runtime = null
		_enemy_simulation_coordinator = null
		_damageable_spatial_index = null
		_combat_target_index = null
		_combat_relation_service = null
		_bind_rejection_count += 1
		return false
	return true


func is_bound() -> bool:
	return (
		not _teardown_prepared
		and _combat_runtime != null
		and _enemy_simulation_coordinator != null
		and _damageable_spatial_index != null
		and _combat_target_index != null
		and _combat_relation_service != null
		and is_instance_valid(_combat_runtime)
		and is_instance_valid(_enemy_simulation_coordinator)
		and is_instance_valid(_damageable_spatial_index)
		and is_instance_valid(_combat_target_index)
		and _damageable_spatial_index.is_bound_to(
			_combat_runtime,
			_enemy_simulation_coordinator
		)
	)


func is_bound_to(
	combat_runtime: CombatRuntimeBase,
	coordinator: EnemySimulationCoordinator
) -> bool:
	return (
		is_bound()
		and _combat_runtime == combat_runtime
		and _enemy_simulation_coordinator == coordinator
	)


## Resolves one authoritative hostile explosion synchronously. A direct target
## is attempted before radial candidates even when it lies outside the radius.
## Only accepted sinks enter the per-resolution ledger, so a rejection never
## prevents a later, otherwise-valid overlap from being retried.
func resolve_hostile_explosion(
	position: Vector2,
	radius: float,
	damage: int,
	direct_hit: Node2D,
	source_snapshot: DamageSourceSnapshot,
	source_enemy_id: int,
	source_projectile_id: int,
	source_type: StringName,
	damage_type: EnemyConfig.DamageType
) -> int:
	_resolution_count += 1
	if (
		not is_bound()
		or _combat_runtime.runtime_mode == CombatRuntimeBase.RuntimeMode.CLIENT_VIEW
		or not position.is_finite()
		or not is_finite(radius)
		or radius < 0.0
		or damage <= 0
		or source_enemy_id < 0
		or source_projectile_id < 0
		or (source_snapshot != null and not source_snapshot.is_valid())
	):
		_rejected_resolution_count += 1
		return 0

	_active_resolution_count = 1
	_accepted_instance_ids.clear()
	_indexed_candidates.clear()
	_overlapping_plants.clear()
	_player_candidates.clear()
	_enemy_candidates.clear()
	var accepted_before := _accepted_damage_count
	var frozen_snapshot := _freeze_source_snapshot(
		source_snapshot,
		source_enemy_id,
		source_projectile_id,
		source_type
	)

	if direct_hit != null:
		_direct_attempt_count += 1
		if _try_apply_damage(
			direct_hit,
			position,
			damage,
			damage_type,
			source_enemy_id,
			source_projectile_id,
			source_type,
			frozen_snapshot
		):
			_direct_accept_count += 1

	if radius > 0.0:
		_explosion_shape.radius = radius
		var explosion_transform := Transform2D(0.0, position)
		var radius_vector := Vector2.ONE * radius
		var explosion_aabb := Rect2(
			position - radius_vector,
			radius_vector * 2.0
		)
		_resolve_player_overlaps(
			explosion_transform,
			position,
			damage,
			damage_type,
			source_enemy_id,
			source_projectile_id,
			source_type,
			frozen_snapshot
		)
		_resolve_indexed_plant_overlaps(
			explosion_aabb,
			explosion_transform,
			position,
			damage,
			damage_type,
			source_enemy_id,
			source_projectile_id,
			source_type,
			frozen_snapshot
		)
		_resolve_indexed_enemy_overlaps(
			explosion_aabb,
			explosion_transform,
			position,
			damage,
			damage_type,
			source_enemy_id,
			source_projectile_id,
			source_type,
			frozen_snapshot
		)

	_active_resolution_count = 0
	return _accepted_damage_count - accepted_before


func _resolve_player_overlaps(
	explosion_transform: Transform2D,
	explosion_position: Vector2,
	damage: int,
	damage_type: EnemyConfig.DamageType,
	source_enemy_id: int,
	source_projectile_id: int,
	source_type: StringName,
	frozen_snapshot: DamageSourceSnapshot
) -> void:
	_player_broad_query_count += 1
	_combat_runtime.query_living_players_into(_player_candidates)
	_player_candidate_count += _player_candidates.size()
	for player in _player_candidates:
		if (
			player == null
			or not is_instance_valid(player)
			or player.is_dead
			or player.is_queued_for_deletion()
			or player.collision_shape == null
			or player.collision_shape.disabled
			or player.collision_shape.shape == null
		):
			continue
		_player_exact_test_count += 1
		if not _explosion_shape.collide(
			explosion_transform,
			player.collision_shape.shape,
			player.collision_shape.global_transform
		):
			continue
		_player_exact_overlap_count += 1
		_try_apply_damage(
			player,
			explosion_position,
			damage,
			damage_type,
			source_enemy_id,
			source_projectile_id,
			source_type,
			frozen_snapshot
		)


func _resolve_indexed_plant_overlaps(
	explosion_aabb: Rect2,
	explosion_transform: Transform2D,
	explosion_position: Vector2,
	damage: int,
	damage_type: EnemyConfig.DamageType,
	source_enemy_id: int,
	source_projectile_id: int,
	source_type: StringName,
	frozen_snapshot: DamageSourceSnapshot
) -> void:
	_indexed_aabb_query_count += 1
	var geometry_revision := _damageable_spatial_index.get_geometry_revision()
	var cache_hit := (
		_cached_plant_geometry_revision == geometry_revision
		and _cached_plant_query_position == explosion_transform.origin
		and is_equal_approx(_cached_plant_query_radius, _explosion_shape.radius)
	)
	if cache_hit:
		_metric_plant_query_cache_hits += 1
		_indexed_candidates.assign(_cached_indexed_candidates)
		_overlapping_plants.assign(_cached_overlapping_plants)
	else:
		_metric_plant_query_cache_misses += 1
		_metric_actual_indexed_aabb_queries += 1
		_damageable_spatial_index.query_world_aabb_into(
			explosion_aabb,
			_indexed_candidates
		)
		_cached_indexed_candidates.assign(_indexed_candidates)
	_indexed_candidate_count += _indexed_candidates.size()
	_indexed_exact_test_count += _indexed_candidates.size()
	if cache_hit:
		_indexed_exact_overlap_count += _overlapping_plants.size()
	else:
		_overlapping_plants.clear()
		for candidate_variant in _indexed_candidates:
			var plant := candidate_variant as PlantDefense
			if (
				plant == null
				or not is_instance_valid(plant)
			):
				continue
			_metric_actual_indexed_exact_tests += 1
			if not _damageable_spatial_index.damageable_overlaps_shape(
				plant,
				_explosion_shape,
				explosion_transform
			):
				continue
			_indexed_exact_overlap_count += 1
			_overlapping_plants.append(plant)
		_cached_overlapping_plants.assign(_overlapping_plants)
		_cached_plant_query_position = explosion_transform.origin
		_cached_plant_query_radius = _explosion_shape.radius
		_cached_plant_geometry_revision = geometry_revision
	for plant in _overlapping_plants:
		_try_apply_damage(
			plant,
			explosion_position,
			damage,
			damage_type,
			source_enemy_id,
			source_projectile_id,
			source_type,
			frozen_snapshot
		)


func _resolve_indexed_enemy_overlaps(
	explosion_aabb: Rect2,
	explosion_transform: Transform2D,
	explosion_position: Vector2,
	damage: int,
	damage_type: EnemyConfig.DamageType,
	source_enemy_id: int,
	source_projectile_id: int,
	source_type: StringName,
	frozen_snapshot: DamageSourceSnapshot
) -> void:
	var query_aabb := explosion_aabb.grow(
		_combat_target_index.get_maximum_body_collision_extent_radius()
		+ BROAD_PHASE_CLOSED_BOUNDARY_EPSILON
	)
	var source_enemy := (
		_combat_target_index.get_enemy(source_enemy_id)
		if source_enemy_id > 0
		else null
	)
	_enemy_broad_query_count += 1
	_combat_target_index.query_hostile_world_aabb_unordered_into(
		query_aabb,
		frozen_snapshot.source_faction_id,
		_enemy_candidates,
		source_enemy,
		_combat_relation_service
	)
	_enemy_candidate_count += _enemy_candidates.size()
	for enemy in _enemy_candidates:
		if (
			enemy == null
			or not is_instance_valid(enemy)
			or enemy.is_dead
			or enemy.is_queued_for_deletion()
			or _is_source_enemy(enemy, source_enemy_id)
		):
			continue
		_enemy_exact_test_count += 1
		if not _enemy_body_overlaps_explosion(enemy, explosion_transform):
			continue
		_enemy_exact_overlap_count += 1
		_try_apply_damage(
			enemy,
			explosion_position,
			damage,
			damage_type,
			source_enemy_id,
			source_projectile_id,
			source_type,
			frozen_snapshot
		)


func _enemy_body_overlaps_explosion(
	enemy: Enemy,
	explosion_transform: Transform2D
) -> bool:
	for shape_node in enemy.body_collision_shapes:
		if (
			shape_node == null
			or not is_instance_valid(shape_node)
			or shape_node.disabled
			or shape_node.shape == null
		):
			continue
		if _explosion_shape.collide(
			explosion_transform,
			shape_node.shape,
			shape_node.global_transform
		):
			return true
	return false


func _is_source_enemy(enemy: Enemy, source_enemy_id: int) -> bool:
	return source_enemy_id > 0 and (
		enemy.combat_target_index_net_id == source_enemy_id
		or int(enemy.get_instance_id()) == source_enemy_id
	)


func prepare_for_runtime_teardown() -> void:
	if _teardown_prepared:
		return
	_teardown_prepared = true
	_teardown_count += 1
	_active_resolution_count = 0
	_indexed_candidates.clear()
	_overlapping_plants.clear()
	_cached_indexed_candidates.clear()
	_cached_overlapping_plants.clear()
	_cached_plant_query_position = Vector2(INF, INF)
	_cached_plant_query_radius = -1.0
	_cached_plant_geometry_revision = -1
	_player_candidates.clear()
	_enemy_candidates.clear()
	_accepted_instance_ids.clear()
	_combat_relation_service = null
	_combat_target_index = null
	_damageable_spatial_index = null
	_enemy_simulation_coordinator = null
	_combat_runtime = null


func get_metrics() -> Dictionary:
	return {
		"bound": is_bound(),
		"authoritative": (
			is_bound()
			and _combat_runtime.runtime_mode
				!= CombatRuntimeBase.RuntimeMode.CLIENT_VIEW
		),
		"resolution_count": _resolution_count,
		"accepted_damage_count": _accepted_damage_count,
		"rejected_resolution_count": _rejected_resolution_count,
		"bind_rejection_count": _bind_rejection_count,
		"direct_attempt_count": _direct_attempt_count,
		"direct_accept_count": _direct_accept_count,
		"indexed_aabb_query_count": _indexed_aabb_query_count,
		"indexed_candidate_count": _indexed_candidate_count,
		"indexed_exact_test_count": _indexed_exact_test_count,
		"indexed_exact_overlap_count": _indexed_exact_overlap_count,
		"player_broad_query_count": _player_broad_query_count,
		"player_candidate_count": _player_candidate_count,
		"player_exact_test_count": _player_exact_test_count,
		"player_exact_overlap_count": _player_exact_overlap_count,
		"enemy_broad_query_count": _enemy_broad_query_count,
		"enemy_candidate_count": _enemy_candidate_count,
		"enemy_exact_test_count": _enemy_exact_test_count,
		"enemy_exact_overlap_count": _enemy_exact_overlap_count,
		"native_shape_query_count": _native_shape_query_count,
		"native_candidate_count": _native_candidate_count,
		"target_attempt_count": _target_attempt_count,
		"duplicate_skip_count": _duplicate_skip_count,
		"admission_rejection_count": _admission_rejection_count,
		"sink_rejection_count": _sink_rejection_count,
		"invalid_target_count": _invalid_target_count,
		"player_request_count": _player_request_count,
		"player_request_accept_count": _player_request_accept_count,
		"singleplayer_player_accept_count": (
			_singleplayer_player_accept_count
		),
		"plant_accept_count": _plant_accept_count,
		"plant_query_cache_hits": _metric_plant_query_cache_hits,
		"plant_query_cache_misses": _metric_plant_query_cache_misses,
		"actual_indexed_aabb_queries": _metric_actual_indexed_aabb_queries,
		"actual_indexed_exact_tests": _metric_actual_indexed_exact_tests,
		"enemy_accept_count": _enemy_accept_count,
		"active_resolution_count": _active_resolution_count,
		"accepted_ledger_size": _accepted_instance_ids.size(),
		"indexed_candidate_buffer_size": _indexed_candidates.size(),
		"cached_indexed_candidate_count": _cached_indexed_candidates.size(),
		"cached_overlapping_plant_count": _cached_overlapping_plants.size(),
		"player_candidate_buffer_size": _player_candidates.size(),
		"enemy_candidate_buffer_size": _enemy_candidates.size(),
		"circle_shape_instance_id": _explosion_shape.get_instance_id(),
		"teardown_prepared": _teardown_prepared,
		"teardown_count": _teardown_count,
	}


func _try_apply_damage(
	target: Node2D,
	explosion_position: Vector2,
	damage: int,
	damage_type: EnemyConfig.DamageType,
	source_enemy_id: int,
	source_projectile_id: int,
	source_type: StringName,
	frozen_snapshot: DamageSourceSnapshot
) -> bool:
	if (
		target == null
		or not is_instance_valid(target)
		or target.is_queued_for_deletion()
	):
		_invalid_target_count += 1
		return false
	var instance_id := target.get_instance_id()
	if _accepted_instance_ids.has(instance_id):
		_duplicate_skip_count += 1
		return false
	_target_attempt_count += 1
	var target_faction_id := CombatRelationService.NEUTRAL
	if target is Player:
		target_faction_id = (target as Player).get_combat_faction_id()
	elif target is PlantDefense:
		target_faction_id = (target as PlantDefense).get_combat_faction_id()
	elif target is Enemy:
		target_faction_id = (target as Enemy).get_combat_faction_id()
	else:
		_invalid_target_count += 1
		return false

	var shot_direction := explosion_position.direction_to(target.global_position)
	# The resolver owns this freshly frozen immutable snapshot for the complete
	# synchronous resolution. Sharing it across per-target requests avoids a
	# second attribution allocation per hit without exposing mutable caller data.
	var request := DamageRequest.new()
	request.amount = damage
	request.damage_type = CombatTypes.normalize_damage_type(int(damage_type))
	request.source = null
	request.source_enemy_id = maxi(source_enemy_id, 0)
	request.source_projectile_id = maxi(source_projectile_id, 0)
	request.source_id = (
		request.source_projectile_id
		if request.source_projectile_id > 0
		else request.source_enemy_id
	)
	request.source_type = (
		source_type if source_type != &"" else frozen_snapshot.source_type
	)
	request.source_snapshot = frozen_snapshot
	request.source_snapshot_is_explicit = true
	request.impact_direction = shot_direction
	request.source_direction = -shot_direction
	request.flags = CombatTypes.DamageFlag.RANGED
	var plant := target as PlantDefense
	if plant != null:
		if plant.is_dead or plant.is_removing:
			_sink_rejection_count += 1
			return false
		var plant_result := plant.apply_combat_damage(request)
		if not plant_result.accepted:
			if (
				plant_result.rejection_reason
				== CombatTypes.DamageRejectionReason.NON_HOSTILE
				or plant_result.rejection_reason
					== CombatTypes.DamageRejectionReason.INVALID_REQUEST
			):
				_admission_rejection_count += 1
			_sink_rejection_count += 1
			return false
		_plant_accept_count += 1
		_accepted_instance_ids[instance_id] = true
		_accepted_damage_count += 1
		return true
	if CombatDamageAdmission.get_rejection_reason(
		request,
		target_faction_id,
		_combat_relation_service
	) != CombatTypes.DamageRejectionReason.NONE:
		_admission_rejection_count += 1
		return false

	var accepted := false
	var player := target as Player
	if player != null:
		if not player.is_dead:
			accepted = _apply_player_damage(player, request, frozen_snapshot)
	else:
		var enemy := target as Enemy
		if enemy != null and not enemy.is_dead:
			accepted = enemy.apply_combat_damage(request).accepted
			if accepted:
				_enemy_accept_count += 1

	if not accepted:
		_sink_rejection_count += 1
		return false
	_accepted_instance_ids[instance_id] = true
	_accepted_damage_count += 1
	return true


func _apply_player_damage(
	player: Player,
	request: DamageRequest,
	frozen_snapshot: DamageSourceSnapshot
) -> bool:
	if _combat_runtime.runtime_mode == CombatRuntimeBase.RuntimeMode.SINGLEPLAYER:
		var accepted := player.apply_combat_damage(request).accepted
		if accepted:
			_singleplayer_player_accept_count += 1
		return accepted
	var source_id := (
		request.source_projectile_id
		if request.source_projectile_id > 0
		else request.source_enemy_id
	)
	var gateway := _combat_runtime.get_multiplayer_gameplay_gateway()
	_player_request_count += 1
	var accepted := (
		source_id > 0
		and gateway != null
		and is_instance_valid(gateway)
		and gateway.request_player_damage(
			source_id,
			player.peer_id,
			request.amount,
			request.source_type,
			request.damage_type as EnemyConfig.DamageType,
			request.get_safe_source_direction(),
			request.has_flag(CombatTypes.DamageFlag.RANGED),
			false,
			frozen_snapshot
		)
	)
	if accepted:
		_player_request_accept_count += 1
	return accepted


func _freeze_source_snapshot(
	source_snapshot: DamageSourceSnapshot,
	source_enemy_id: int,
	source_projectile_id: int,
	source_type: StringName
) -> DamageSourceSnapshot:
	var event_source_id := (
		source_projectile_id
		if source_projectile_id > 0
		else (
			source_snapshot.event_source_id
			if source_snapshot != null
			else source_enemy_id
		)
	)
	if source_snapshot != null:
		return DamageSourceSnapshot.create(
			source_snapshot.source_faction_id,
			source_snapshot.credit_peer_id,
			source_snapshot.instigator_entity_id,
			maxi(event_source_id, 0),
			source_type if source_type != &"" else source_snapshot.source_type
		)
	return DamageSourceSnapshot.create(
		CombatRelationService.HOSTILE_WAVE,
		0,
		maxi(source_enemy_id, 0),
		maxi(event_source_id, 0),
		source_type
	)


func _exit_tree() -> void:
	prepare_for_runtime_teardown()
