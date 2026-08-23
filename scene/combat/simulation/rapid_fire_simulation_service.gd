extends Node
class_name RapidFireSimulationService

## Data-oriented simulation boundary for high-volume rapid-fire projectiles.
## Phase 2 authors only the inert AK profile seam. No projectile, damage,
## networking, presentation, or pool behavior is routed through this service.

enum Mode {
	DISABLED,
	SHADOW,
	DATA,
}

const PROFILE_AK := &"ak"

var _mode: Mode = Mode.DISABLED
var _active_slot_count := 0
var _combat_runtime: CombatRuntimeBase = null
var _enemy_simulation_coordinator: EnemySimulationCoordinator = null
var _teardown_prepared := false
var _teardown_count := 0


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


func get_mode() -> Mode:
	return _mode


func get_active_slot_count() -> int:
	return _active_slot_count


func has_physics_work() -> bool:
	return _mode != Mode.DISABLED and _active_slot_count > 0


func prepare_for_runtime_teardown() -> void:
	if _teardown_prepared:
		return
	_teardown_prepared = true
	_teardown_count += 1
	clear()
	_combat_runtime = null
	_enemy_simulation_coordinator = null


func clear() -> void:
	_mode = Mode.DISABLED
	_active_slot_count = 0
	set_physics_process(false)


func get_metrics() -> Dictionary:
	return {
		"profile": PROFILE_AK,
		"mode": int(_mode),
		"active_slots": _active_slot_count,
		"physics_processing": is_physics_processing(),
		"bound": is_bound(),
		"teardown_prepared": _teardown_prepared,
		"teardown_count": _teardown_count,
	}


func _physics_process(_delta: float) -> void:
	if not has_physics_work():
		set_physics_process(false)


func _exit_tree() -> void:
	prepare_for_runtime_teardown()
