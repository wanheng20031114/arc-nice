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
		presenter.get_child_count() == 6,
		"Presenter scene must contain base, halo and emission layers for two authored families."
	)
	var normal_instance := presenter.get_normal_multimesh_instance()
	var elite_instance := presenter.get_elite_multimesh_instance()
	_validate_family(normal_instance, "normal")
	_validate_family(elite_instance, "elite")
	_validate_shader(normal_instance)
	_validate_effect_layers(presenter, normal_instance, elite_instance)
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
		and source.contains("? 2.0 : 3.0")
		and source.contains("volley_modulate = COLOR")
		and source.contains("texture(TEXTURE, atlas_uv)")
		and source.contains("* volley_modulate")
		and not source.contains("texture(TEXTURE, atlas_uv) * COLOR"),
		"Atlas shader must select fly/impact/expire frames without multiplying a second default texture sample."
	)


func _validate_effect_layers(
	presenter: PresenterScript,
	normal_instance: MultiMeshInstance2D,
	elite_instance: MultiMeshInstance2D
) -> void:
	var normal_halo := presenter.get_normal_halo_multimesh_instance()
	var normal_emission := presenter.get_normal_emission_multimesh_instance()
	var elite_halo := presenter.get_elite_halo_multimesh_instance()
	var elite_emission := presenter.get_elite_emission_multimesh_instance()
	_expect(
		normal_instance != null
		and elite_instance != null
		and normal_halo != null
		and normal_emission != null
		and elite_halo != null
		and elite_emission != null
		and normal_halo.multimesh == normal_instance.multimesh
		and normal_emission.multimesh == normal_instance.multimesh
		and elite_halo.multimesh == elite_instance.multimesh
		and elite_emission.multimesh == elite_instance.multimesh,
		"Effect layers must share the base MultiMeshes without duplicate transform/custom-data writes."
	)
	if (
		normal_halo == null
		or normal_emission == null
		or elite_halo == null
		or elite_emission == null
	):
		return
	var normal_halo_material := normal_halo.material as ShaderMaterial
	var elite_halo_material := elite_halo.material as ShaderMaterial
	var normal_emission_material := normal_emission.material as ShaderMaterial
	var elite_emission_material := elite_emission.material as ShaderMaterial
	_expect(
		normal_halo.texture_filter == CanvasItem.TEXTURE_FILTER_LINEAR
		and elite_halo.texture_filter == CanvasItem.TEXTURE_FILTER_LINEAR
		and normal_halo.self_modulate.is_equal_approx(
			Color(1.0, 0.32, 0.08, 0.13)
		)
		and elite_halo.self_modulate.is_equal_approx(
			Color(0.15, 0.72, 1.0, 0.14)
		)
		and normal_halo_material != null
		and elite_halo_material != null
		and is_equal_approx(
			float(normal_halo_material.get_shader_parameter("halo_size_ratio")),
			0.6
		)
		and is_equal_approx(
			float(elite_halo_material.get_shader_parameter("halo_size_ratio")),
			0.64
		),
		"Normal and elite halo layers must preserve their legacy tint and 19.2/20.48px diameters."
	)
	_expect(
		normal_emission.texture == normal_instance.texture
		and elite_emission.texture == elite_instance.texture
		and normal_emission.texture_filter == CanvasItem.TEXTURE_FILTER_NEAREST
		and elite_emission.texture_filter == CanvasItem.TEXTURE_FILTER_NEAREST
		and normal_emission.self_modulate.is_equal_approx(
			Color(1.78, 0.88, 0.35, 0.48)
		)
		and elite_emission.self_modulate.is_equal_approx(
			Color(0.62, 1.28, 1.86, 0.52)
		)
		and normal_emission_material != null
		and elite_emission_material == normal_emission_material,
		"Normal and elite emission layers must preserve their legacy additive atlas tint."
	)
	var emission_source := (
		normal_emission_material.shader.code
		if normal_emission_material != null
		and normal_emission_material.shader != null
		else ""
	)
	var halo_source := (
		normal_halo_material.shader.code
		if normal_halo_material != null and normal_halo_material.shader != null
		else ""
	)
	_expect(
		emission_source.contains("render_mode blend_add, unshaded")
		and emission_source.contains("emission_modulate = COLOR")
		and not emission_source.contains("texture(TEXTURE, atlas_uv) * COLOR")
		and halo_source.contains("render_mode blend_add, unshaded")
		and halo_source.contains("VERTEX *= halo_size_ratio")
		and halo_source.contains("halo_modulate = COLOR"),
		"Effect shaders must use additive legacy blending without default-texture double sampling."
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
