extends PointLight2D
class_name NightPointLight2D

const ENABLE_EPSILON := 0.001

@export_range(0.0, 8.0, 0.01, "or_greater") var night_energy := 0.7
@export var starts_emitting := true

var _night_factor := 0.0
var _emission_allowed := true
var _controller: DayNightController = null


func _ready() -> void:
	_emission_allowed = starts_emitting
	_refresh_emission()
	call_deferred("_bind_to_owner_controller")


func _exit_tree() -> void:
	_unbind_controller()


func set_night_factor(value: float) -> void:
	_night_factor = clampf(value, 0.0, 1.0)
	_refresh_emission()


func set_emission_allowed(allowed: bool) -> void:
	if _emission_allowed == allowed:
		return
	_emission_allowed = allowed
	_refresh_emission()


func set_night_energy(value: float) -> void:
	var safe_energy := maxf(value, 0.0)
	if night_energy == safe_energy:
		return
	night_energy = safe_energy
	_refresh_emission()


func is_emission_allowed() -> bool:
	return _emission_allowed


func _bind_to_owner_controller() -> void:
	var controller := _find_owner_controller()
	if controller == _controller:
		if _controller != null:
			set_night_factor(_controller.night_factor)
		return
	_unbind_controller()
	_controller = controller
	if _controller == null:
		return
	_controller.night_factor_changed.connect(set_night_factor)
	set_night_factor(_controller.night_factor)


func _find_owner_controller() -> DayNightController:
	var branch := get_parent()
	while branch != null:
		if branch is DayNightController:
			return branch as DayNightController
		var controller := branch.get_node_or_null(
			"DayNightController"
		) as DayNightController
		if controller != null:
			return controller
		branch = branch.get_parent()
	return null


func _unbind_controller() -> void:
	if (
		_controller != null
		and is_instance_valid(_controller)
		and _controller.night_factor_changed.is_connected(
			set_night_factor
		)
	):
		_controller.night_factor_changed.disconnect(set_night_factor)
	_controller = null


func _refresh_emission() -> void:
	var effective_factor := _night_factor if _emission_allowed else 0.0
	var next_energy := night_energy * effective_factor
	if energy != next_energy:
		energy = next_energy
	var should_enable := next_energy > ENABLE_EPSILON
	if enabled != should_enable:
		enabled = should_enable
