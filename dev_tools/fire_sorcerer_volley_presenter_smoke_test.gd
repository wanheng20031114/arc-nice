extends SceneTree

const PresenterScript := preload(
	"res://scene/combat/simulation/fire_sorcerer_volley_presenter.gd"
)
const ServiceScript := preload(
	"res://scene/combat/simulation/fire_sorcerer_volley_simulation_service.gd"
)
const PRESENTER_SCENE := preload(
	"res://scene/combat/simulation/fire_sorcerer_volley_presenter.tscn"
)

var _failures := PackedStringArray()


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var presenter := PRESENTER_SCENE.instantiate() as PresenterScript
	_expect(presenter != null, "Presenter scene must instantiate with its typed script.")
	if presenter == null:
		_finish()
		return
	_expect(
		presenter.get_child_count() == 2,
		"Presenter scene must contain exactly two authored families."
	)
	var normal_instance := presenter.get_normal_multimesh_instance()
	var elite_instance := presenter.get_elite_multimesh_instance()
	_validate_family(normal_instance, "normal")
	_validate_family(elite_instance, "elite")
	_validate_shader(normal_instance)
	_expect(
		PresenterScript.build_instance_transform(
			Vector2(7.0, 9.0),
			Vector2.UP
		).origin == Vector2(7.0, 9.0),
		"Static transform helper must preserve the requested position."
	)
	_expect(
		PresenterScript.is_world_position_visible(
			Vector2(4.0, 4.0),
			Rect2(Vector2.ZERO, Vector2(8.0, 8.0))
		),
		"Static visibility helper must admit positions inside the view AABB."
	)

	var service := ServiceScript.new()
	_expect(presenter.bind_service(service), "Presenter must bind the typed service.")
	root.add_child(service)
	root.add_child(presenter)
	await process_frame
	var metrics := presenter.get_metrics()
	_expect(
		metrics["headless_disabled"]
		and metrics["allocated_normal_instances"] == 0
		and metrics["allocated_elite_instances"] == 0
		and not presenter.is_processing(),
		"Headless ready must release both batches and stop processing."
	)
	presenter.prepare_for_runtime_teardown()
	presenter.queue_free()
	service.queue_free()
	await process_frame
	_finish()


func _validate_family(
	instance: MultiMeshInstance2D,
	family_name: String
) -> void:
	_expect(instance != null, "%s family must be authored." % family_name)
	if instance == null:
		return
	var multimesh := instance.multimesh
	var quad := multimesh.mesh as QuadMesh if multimesh != null else null
	_expect(
		multimesh != null
		and multimesh.instance_count == 0
		and multimesh.visible_instance_count == 0
		and multimesh.transform_format == MultiMesh.TRANSFORM_2D
		and multimesh.use_custom_data,
		"%s family must author an unallocated scene-local 2D batch."
		% family_name
	)
	_expect(
		PresenterScript.FIXED_INSTANCE_CAPACITY == 4096,
		"Each display-enabled family must allocate exactly 4096 instances."
	)
	_expect(
		quad != null and quad.size == Vector2(32.0, 32.0),
		"%s family must use the shared 32x32 QuadMesh." % family_name
	)
	_expect(
		instance.texture_filter == CanvasItem.TEXTURE_FILTER_NEAREST,
		"%s family must use nearest texture filtering." % family_name
	)


func _validate_shader(instance: MultiMeshInstance2D) -> void:
	var shader_material := instance.material as ShaderMaterial
	var source := (
		shader_material.shader.code
		if shader_material != null and shader_material.shader != null
		else ""
	)
	_expect(
		source.contains("INSTANCE_CUSTOM.rgb")
		and source.contains("atlas_row = 0.0")
		and source.contains("? 2.0 : 3.0"),
		"Atlas shader must select fly row 0 and impact/expire rows 2/3."
	)


func _expect(condition: bool, message: String) -> void:
	if not condition:
		_failures.append(message)


func _finish() -> void:
	if _failures.is_empty():
		print("FIRE_SORCERER_VOLLEY_PRESENTER_SMOKE_OK")
		quit(0)
		return
	for failure in _failures:
		push_error(failure)
	quit(1)
