extends Sprite2D

const CANVAS_MODULATE_PARAMETER := &"canvas_modulate_color"
const NIGHT_FACTOR_PARAMETER := &"night_factor"
const LINEAR_COLOR_SPACE_PARAMETER := &"linear_color_space"
const CONTROLLER_MATERIAL_META := &"guardian_light_emission_runtime_material"

var _controller: DayNightController = null
var _shared_material: ShaderMaterial = null
var _runtime_material: ShaderMaterial = null


func _ready() -> void:
	_shared_material = material as ShaderMaterial
	visibility_changed.connect(_sync_controller_binding)
	call_deferred("_sync_controller_binding")


func _exit_tree() -> void:
	_unbind_controller()


func _sync_controller_binding() -> void:
	if is_visible_in_tree():
		_bind_to_owner_controller()
	else:
		_unbind_controller()


func set_night_factor(value: float) -> void:
	if _runtime_material == null:
		return
	var safe_factor := clampf(value, 0.0, 1.0)
	var environment_color := Color.WHITE.lerp(
		DayNightController.REFERENCE_NIGHT_COLOR,
		safe_factor
	)
	if _controller != null and is_instance_valid(_controller):
		environment_color = _controller.color
	_set_environment(environment_color, safe_factor)


func _set_environment(environment_color: Color, factor: float) -> void:
	_runtime_material.set_shader_parameter(
		CANVAS_MODULATE_PARAMETER,
		environment_color
	)
	_runtime_material.set_shader_parameter(NIGHT_FACTOR_PARAMETER, factor)


func _bind_to_owner_controller() -> void:
	var controller := _find_owner_controller()
	if controller == _controller and _runtime_material != null:
		if _controller != null:
			set_night_factor(_controller.night_factor)
		return
	_unbind_controller()
	_controller = controller
	if _controller == null:
		_runtime_material = _duplicate_runtime_material()
		material = _runtime_material
		_set_environment(Color.WHITE, 0.0)
		return
	_runtime_material = _get_controller_runtime_material(_controller)
	material = _runtime_material
	_controller.night_factor_changed.connect(set_night_factor)
	set_night_factor(_controller.night_factor)


func _get_controller_runtime_material(
	controller: DayNightController
) -> ShaderMaterial:
	var cached_material: ShaderMaterial = null
	if controller.has_meta(CONTROLLER_MATERIAL_META):
		cached_material = controller.get_meta(
			CONTROLLER_MATERIAL_META
		) as ShaderMaterial
	if (
		cached_material != null
		and _shared_material != null
		and cached_material.shader == _shared_material.shader
	):
		return cached_material
	var runtime_material := _duplicate_runtime_material()
	controller.set_meta(CONTROLLER_MATERIAL_META, runtime_material)
	return runtime_material


func _duplicate_runtime_material() -> ShaderMaterial:
	if _shared_material == null:
		return null
	var runtime_material := _shared_material.duplicate() as ShaderMaterial
	runtime_material.set_shader_parameter(
		LINEAR_COLOR_SPACE_PARAMETER,
		1.0
		if RenderingServer.get_current_rendering_method() != &"gl_compatibility"
		else 0.0
	)
	return runtime_material


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
	_runtime_material = null
	if _shared_material != null:
		material = _shared_material
