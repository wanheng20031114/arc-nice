extends GPUParticles2D
class_name NightSelfEmissionParticles2D

const NIGHT_FACTOR_PARAMETER := &"night_factor"
const ENVIRONMENT_TINT_PARAMETER := &"environment_tint"

var _controller: DayNightController = null


func _ready() -> void:
	set_night_factor(0.0)
	call_deferred("_bind_to_owner_controller")


func _exit_tree() -> void:
	_unbind_controller()


func set_night_factor(value: float) -> void:
	var safe_factor := clampf(value, 0.0, 1.0)
	var environment_tint := Color.WHITE.lerp(
		DayNightController.REFERENCE_NIGHT_COLOR,
		safe_factor
	)
	if _controller != null and is_instance_valid(_controller):
		environment_tint = _controller.color
	set_instance_shader_parameter(NIGHT_FACTOR_PARAMETER, safe_factor)
	set_instance_shader_parameter(
		ENVIRONMENT_TINT_PARAMETER,
		environment_tint
	)


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
		and _controller.night_factor_changed.is_connected(set_night_factor)
	):
		_controller.night_factor_changed.disconnect(set_night_factor)
	_controller = null
