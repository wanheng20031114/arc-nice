extends Node
class_name EnemyCombatServices

const RapidFireSimulationServiceScript := preload(
	"res://scene/combat/simulation/rapid_fire_simulation_service.gd"
)
const EnemyDamageableSpatialIndexScript := preload(
	"res://scene/combat/targeting/enemy_damageable_spatial_index.gd"
)

## Authored service boundary owned by EnemySimulationCoordinator. This phase
## only exposes an inert rapid-fire seam; existing combat systems remain the
## sole writers of projectile state and gameplay outcomes.

var _combat_runtime: CombatRuntimeBase = null
var _enemy_simulation_coordinator: EnemySimulationCoordinator = null
var _teardown_prepared := false
var _teardown_count := 0


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
	if (
		rapid_fire_service == null
		or damageable_spatial_index == null
		or not rapid_fire_service.bind_context(combat_runtime, coordinator)
		or not damageable_spatial_index.bind_context(combat_runtime, coordinator)
	):
		return false
	_combat_runtime = combat_runtime
	_enemy_simulation_coordinator = coordinator
	return true


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


func prepare_for_runtime_teardown() -> void:
	if _teardown_prepared:
		return
	_teardown_prepared = true
	_teardown_count += 1
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
	return {
		"bound": is_bound(),
		"teardown_prepared": _teardown_prepared,
		"teardown_count": _teardown_count,
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
	}


func _exit_tree() -> void:
	prepare_for_runtime_teardown()
