extends SceneTree

const SERVICE_SCENE := preload(
	"res://scene/combat/presentation/explosion_presentation_service.tscn"
)
const SERVICE_SCRIPT := preload(
	"res://scene/combat/presentation/explosion_presentation_service.gd"
)
const FLASH_POOL_SCENE := preload(
	"res://scene/lighting/night_vfx_flash_pool.tscn"
)

var failures: Array[String] = []


func _init() -> void:
	call_deferred(&"_run")


func _run() -> void:
	var fixture := Node2D.new()
	root.add_child(fixture)
	current_scene = fixture
	var camera := Camera2D.new()
	camera.enabled = true
	fixture.add_child(camera)
	var flash_pool := FLASH_POOL_SCENE.instantiate() as NightVfxFlashPool
	fixture.add_child(flash_pool)
	await process_frame
	await _test_headless_and_preallocated_queue(fixture)
	await _test_fixed_multimesh_path(fixture, flash_pool)
	current_scene = null
	fixture.queue_free()
	for _cleanup_frame in range(4):
		await process_frame
	if failures.is_empty():
		print("EXPLOSION_PRESENTATION_SERVICE_SMOKE_OK")
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	quit(1)


func _test_headless_and_preallocated_queue(fixture: Node2D) -> void:
	var system := SERVICE_SCENE.instantiate() as SERVICE_SCRIPT
	fixture.add_child(system)
	await process_frame
	var base := system.get_node("ExplosionBase") as MultiMeshInstance2D
	var emission := system.get_node("ExplosionEmission") as MultiMeshInstance2D
	var audio_root := system.get_node("AudioVoices")
	_expect(
		system.get_child_count() == 3
		and base != null
		and emission != null
		and audio_root.get_child_count() == 6
		and not system.is_processing()
		and not system.is_physics_processing(),
		"Scene must author two MultiMesh families and six voices while remaining externally driven."
	)
	for index in range(SERVICE_SCRIPT.PENDING_CAPACITY + 257):
		_expect(system.queue_explosion(
			SERVICE_SCRIPT.Profile.CAPOO_RPG,
			Vector2(index, 0.0)
		), "Valid requests must remain accepted beyond presentation queue capacity.")
	_expect(system.flush_presenter() == 0, "Headless flush must draw nothing.")
	var metrics := system.get_metrics()
	_expect(
		bool(metrics["headless_disabled"])
		and int(metrics["draw_family_count"]) == 2
		and int(metrics["allocated_base_instances"]) == 0
		and int(metrics["allocated_emission_instances"]) == 0
		and int(metrics["headless_omissions"]) == SERVICE_SCRIPT.PENDING_CAPACITY
		and int(metrics["pending_capacity_drops"]) == 257
		and int(metrics["visual_writes"]) == 0,
		"Headless mode must use the preallocated queue without visual storage or writes."
	)
	_expect(
		not system.queue_explosion(SERVICE_SCRIPT.Profile.INVALID, Vector2.ZERO)
		and not system.queue_explosion(
			SERVICE_SCRIPT.Profile.CAPOO_RPG, Vector2(NAN, 0.0)
		),
		"Invalid profile and non-finite positions must be rejected."
	)
	system.prepare_for_runtime_teardown()
	system.prepare_for_runtime_teardown()
	_expect(
		int(system.get_metrics()["teardown_count"]) == 1,
		"Teardown must be idempotent."
	)
	system.queue_free()
	await process_frame


func _test_fixed_multimesh_path(
	fixture: Node2D,
	flash_pool: NightVfxFlashPool
) -> void:
	var system := SERVICE_SCENE.instantiate() as SERVICE_SCRIPT
	system._headless_disabled = false
	fixture.add_child(system)
	await process_frame
	_expect(
		not system.is_processing() and not system.is_physics_processing(),
		"Renderable presentation must not self-flush outside the shared physics driver."
	)
	var child_count_before := system.get_child_count()
	for index in range(100):
		system.queue_explosion(
			SERVICE_SCRIPT.Profile.CAPOO_RPG,
			Vector2(index % 10, index / 10),
			3.5 / SERVICE_SCRIPT.EXPLOSION_FPS if index == 0 else 0.0
		)
	var visible := system.flush_presenter(0.0)
	var metrics := system.get_metrics()
	var base := (system.get_node("ExplosionBase") as MultiMeshInstance2D).multimesh
	var emission := (
		system.get_node("ExplosionEmission") as MultiMeshInstance2D
	).multimesh
	_expect(
		visible == SERVICE_SCRIPT.VISUAL_CAPACITY
		and base.instance_count == SERVICE_SCRIPT.VISUAL_CAPACITY
		and emission.instance_count == SERVICE_SCRIPT.VISUAL_CAPACITY
		and base.visible_instance_count == SERVICE_SCRIPT.VISUAL_CAPACITY
		and emission.visible_instance_count == SERVICE_SCRIPT.VISUAL_CAPACITY
		and int(metrics["visual_capacity_drops"]) == 4,
		"A 100-event burst must fill the fixed 96-slot two-family draw buffer."
	)
	_expect(
		int(metrics["audio_starts"]) <= 6
		and int(metrics["active_audio_voices"]) <= 6
		and flash_pool.get_active_flash_count() <= 8
		and system.get_child_count() == child_count_before,
		"Burst presentation must retain six-audio/eight-light budgets without node growth."
	)
	var base_material := (
		(system.get_node("ExplosionBase") as MultiMeshInstance2D).material
		as ShaderMaterial
	)
	_expect(
		base_material.shader.code.contains("INSTANCE_CUSTOM")
		and base_material.shader.code.contains("* 0.125")
		and base_material.shader.code.contains("* 8.0"),
		"Atlas shader must select one of eight horizontal 96px frames from custom data."
	)
	system.queue_explosion(
		SERVICE_SCRIPT.Profile.CAPOO_RPG,
		Vector2.ZERO,
		SERVICE_SCRIPT.EXPLOSION_DURATION_SECONDS
	)
	system.queue_explosion(
		SERVICE_SCRIPT.Profile.CAPOO_RPG,
		Vector2(100_000.0, 100_000.0)
	)
	system.flush_presenter(0.0)
	metrics = system.get_metrics()
	_expect(
		int(metrics["expired_omissions"]) == 1
		and int(metrics["offscreen_omissions"]) == 1,
		"Expired and offscreen events must be presentation-only omissions."
	)
	system.flush_presenter(SERVICE_SCRIPT.EXPLOSION_DURATION_SECONDS)
	metrics = system.get_metrics()
	_expect(
		int(metrics["active_visuals"]) == 0
		and int(metrics["visual_completions"]) == SERVICE_SCRIPT.VISUAL_CAPACITY,
		"Packed visual ages must retire all 96 slots at the animation duration."
	)
	system.prepare_for_runtime_teardown()
	metrics = system.get_metrics()
	_expect(
		int(metrics["allocated_base_instances"]) == 0
		and int(metrics["allocated_emission_instances"]) == 0
		and int(metrics["active_audio_voices"]) == 0,
		"Teardown must synchronously release fixed visual and audio storage."
	)
	system.queue_free()
	await process_frame


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
