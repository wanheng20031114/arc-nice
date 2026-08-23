extends Node
class_name EnemyCombatServices

const RapidFireSimulationServiceScript := preload(
	"res://scene/combat/simulation/rapid_fire_simulation_service.gd"
)
const EnemyDamageableSpatialIndexScript := preload(
	"res://scene/combat/targeting/enemy_damageable_spatial_index.gd"
)
const ImmediateHitscanResolverScript := preload(
	"res://scene/combat/simulation/immediate_hitscan_resolver.gd"
)
const RapidProjectilePresenterScript := preload(
	"res://scene/combat/simulation/rapid_projectile_presenter.gd"
)
const RAPID_PROJECTILE_RESERVED_CAPACITY := 4096

## Authored service boundary owned by EnemySimulationCoordinator. These inert
## rapid-fire, hitscan, and presentation seams do not replace existing combat
## writers until their production callers are migrated explicitly.

var _combat_runtime: CombatRuntimeBase = null
var _enemy_simulation_coordinator: EnemySimulationCoordinator = null
var _teardown_prepared := false
var _teardown_count := 0
var _metric_completion_batches := 0
var _metric_consumed_completions := 0
var _metric_network_finish_notifications := 0
var _metric_hit_presentation_requests := 0


func _init() -> void:
	set_physics_process(false)


func bind_context(
	combat_runtime: CombatRuntimeBase,
	coordinator: EnemySimulationCoordinator
) -> bool:
	if _teardown_prepared:
		return false
	if (
		combat_runtime == null
		or coordinator == null
		or not is_instance_valid(combat_runtime)
		or not is_instance_valid(coordinator)
		or get_parent() != coordinator
		or coordinator.get_parent() != combat_runtime
	):
		return false
	if (
		_combat_runtime != null
		and (
			_combat_runtime != combat_runtime
			or _enemy_simulation_coordinator != coordinator
		)
	):
		return false
	var rapid_fire_service := get_rapid_fire_simulation_service()
	var damageable_spatial_index := get_enemy_damageable_spatial_index()
	var immediate_hitscan_resolver := get_immediate_hitscan_resolver()
	var rapid_projectile_presenter := get_rapid_projectile_presenter()
	if (
		rapid_fire_service == null
		or damageable_spatial_index == null
		or immediate_hitscan_resolver == null
		or rapid_projectile_presenter == null
		or not damageable_spatial_index.bind_context(combat_runtime, coordinator)
		or not rapid_fire_service.bind_context(combat_runtime, coordinator)
		or not rapid_fire_service.reserve_projectile_capacity(
			RAPID_PROJECTILE_RESERVED_CAPACITY
		)
		or not immediate_hitscan_resolver.bind_combat_runtime(combat_runtime)
		or not rapid_projectile_presenter.bind_service(rapid_fire_service)
	):
		return false
	_combat_runtime = combat_runtime
	_enemy_simulation_coordinator = coordinator
	if not combat_runtime.cache_enemy_combat_services(self):
		_combat_runtime = null
		_enemy_simulation_coordinator = null
		return false
	set_physics_process(true)
	return true


func _physics_process(_delta: float) -> void:
	var rapid_fire_service := get_rapid_fire_simulation_service()
	if rapid_fire_service == null:
		set_physics_process(false)
		return
	var completion_count := rapid_fire_service.get_completion_count()
	if completion_count <= 0:
		return
	_metric_completion_batches += 1
	var rapid_projectile_presenter := get_rapid_projectile_presenter()
	var gateway := (
		_combat_runtime.get_multiplayer_gameplay_gateway()
		if is_bound()
		else null
	)
	for completion_index in range(completion_count):
		var mode := rapid_fire_service.get_completion_mode(completion_index)
		if mode != RapidFireSimulationServiceScript.Mode.DATA:
			continue
		_metric_consumed_completions += 1
		var profile := rapid_fire_service.get_completion_profile(completion_index)
		var reason := rapid_fire_service.get_completion_reason(completion_index)
		if (
			(
				reason == RapidFireSimulationServiceScript.CompletionReason.WORLD
				or reason == RapidFireSimulationServiceScript.CompletionReason.TARGET
			)
			and
			rapid_projectile_presenter != null
			and rapid_projectile_presenter.queue_completion_hit(
				mode,
				profile,
				reason,
				rapid_fire_service.get_completion_position(completion_index),
				rapid_fire_service.get_completion_direction(completion_index)
			)
		):
			_metric_hit_presentation_requests += 1
		var projectile_id := rapid_fire_service.get_completion_projectile_id(
			completion_index
		)
		if projectile_id > 0 and gateway != null:
			gateway.notify_data_projectile_finished(
				projectile_id,
				rapid_fire_service,
				rapid_fire_service.get_completion_handle(completion_index)
			)
			_metric_network_finish_notifications += 1
	# Completion records are a frame-local transfer buffer. Priority 6 consumes
	# the priority-4 simulation output exactly once before the next physics tick.
	rapid_fire_service.clear_completion_records()


func is_bound() -> bool:
	return (
		_combat_runtime != null
		and _enemy_simulation_coordinator != null
		and is_instance_valid(_combat_runtime)
		and is_instance_valid(_enemy_simulation_coordinator)
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


func get_rapid_fire_simulation_service() -> RapidFireSimulationServiceScript:
	return get_node_or_null(
		"RapidFireSimulationService"
	) as RapidFireSimulationServiceScript


func get_enemy_damageable_spatial_index() -> EnemyDamageableSpatialIndexScript:
	return get_node_or_null(
		"EnemyDamageableSpatialIndex"
	) as EnemyDamageableSpatialIndexScript


func get_immediate_hitscan_resolver() -> ImmediateHitscanResolverScript:
	return get_node_or_null(
		"ImmediateHitscanResolver"
	) as ImmediateHitscanResolverScript


func get_rapid_projectile_presenter() -> RapidProjectilePresenterScript:
	return get_node_or_null(
		"RapidProjectilePresenter"
	) as RapidProjectilePresenterScript


func prepare_for_runtime_teardown() -> void:
	if _teardown_prepared:
		return
	_teardown_prepared = true
	_teardown_count += 1
	set_physics_process(false)
	var rapid_projectile_presenter := get_rapid_projectile_presenter()
	if rapid_projectile_presenter != null:
		rapid_projectile_presenter.prepare_for_runtime_teardown()
	var immediate_hitscan_resolver := get_immediate_hitscan_resolver()
	if immediate_hitscan_resolver != null:
		immediate_hitscan_resolver.prepare_for_runtime_teardown()
	var damageable_spatial_index := get_enemy_damageable_spatial_index()
	if damageable_spatial_index != null:
		damageable_spatial_index.prepare_for_runtime_teardown()
	var rapid_fire_service := get_rapid_fire_simulation_service()
	if rapid_fire_service != null:
		rapid_fire_service.prepare_for_runtime_teardown()
	_combat_runtime = null
	_enemy_simulation_coordinator = null


func get_metrics() -> Dictionary:
	var rapid_fire_service := get_rapid_fire_simulation_service()
	var damageable_spatial_index := get_enemy_damageable_spatial_index()
	var immediate_hitscan_resolver := get_immediate_hitscan_resolver()
	var rapid_projectile_presenter := get_rapid_projectile_presenter()
	return {
		"bound": is_bound(),
		"teardown_prepared": _teardown_prepared,
		"teardown_count": _teardown_count,
		"completion_batches": _metric_completion_batches,
		"consumed_completions": _metric_consumed_completions,
		"network_finish_notifications": _metric_network_finish_notifications,
		"hit_presentation_requests": _metric_hit_presentation_requests,
		"rapid_fire": (
			rapid_fire_service.get_metrics()
			if rapid_fire_service != null
			else {}
		),
		"enemy_damageable_spatial_index": (
			damageable_spatial_index.get_metrics()
			if damageable_spatial_index != null
			else {}
		),
		"immediate_hitscan_resolver": (
			immediate_hitscan_resolver.get_metrics()
			if immediate_hitscan_resolver != null
			else {}
		),
		"rapid_projectile_presenter": (
			rapid_projectile_presenter.get_metrics()
			if rapid_projectile_presenter != null
			else {}
		),
	}


func _exit_tree() -> void:
	prepare_for_runtime_teardown()
