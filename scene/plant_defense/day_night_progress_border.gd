extends MeshInstance2D
class_name DayNightProgressBorder

const ENVIRONMENT_TINT_PARAMETER := &"environment_tint"

var _controller: DayNightController = null


func _ready() -> void:
	_apply_environment_tint(Color.WHITE)
	call_deferred("_bind_to_owner_controller")


func _exit_tree() -> void:
	_unbind_controller()


func _bind_to_owner_controller() -> void:
	var controller := _find_owner_controller()
	if controller == _controller:
		_refresh_environment_tint()
		return
	_unbind_controller()
	_controller = controller
	if _controller == null:
		return
	_controller.night_factor_changed.connect(_on_night_factor_changed)
	_refresh_environment_tint()


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


func _on_night_factor_changed(_night_factor: float) -> void:
	_refresh_environment_tint()


func _refresh_environment_tint() -> void:
	_apply_environment_tint(
		_controller.color if _controller != null else Color.WHITE
	)


func _apply_environment_tint(tint: Color) -> void:
	set_instance_shader_parameter(ENVIRONMENT_TINT_PARAMETER, tint)


func _unbind_controller() -> void:
	if (
		_controller != null
		and is_instance_valid(_controller)
		and _controller.night_factor_changed.is_connected(
			_on_night_factor_changed
		)
	):
		_controller.night_factor_changed.disconnect(
			_on_night_factor_changed
		)
	_controller = null
