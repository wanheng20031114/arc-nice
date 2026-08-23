extends SceneTree

const PRESENTER_SCENE := preload(
	"res://scene/combat/presentation/capoo_mage_fireball_presenter.tscn"
)
const PRESENTER_SCRIPT := preload(
	"res://scene/combat/presentation/capoo_mage_fireball_presenter.gd"
)
const SIMULATION_SCRIPT := preload(
	"res://scene/combat/simulation/capoo_mage_fireball_simulation_service.gd"
)

const DENSE_COUNT := 600
const VISIBLE_CANDIDATE_COUNT := 520


class FakeSimulation:
	extends SIMULATION_SCRIPT

	var positions := PackedVector2Array()
	var directions := PackedVector2Array()
	var ages := PackedFloat64Array()
	var dense_getter_calls := 0

	func configure() -> void:
		positions.resize(DENSE_COUNT)
		directions.resize(DENSE_COUNT)
		ages.resize(DENSE_COUNT)
		for index in range(DENSE_COUNT):
			positions[index] = (
				Vector2(index % 20, index / 20)
				if index < VISIBLE_CANDIDATE_COUNT
				else Vector2(100_000.0 + index, 100_000.0)
			)
			directions[index] = Vector2.RIGHT
			ages[index] = float(index % 6) / PRESENTER_SCRIPT.ANIMATION_FPS
		directions[0] = Vector2.UP
		ages[0] = 5.5 / PRESENTER_SCRIPT.ANIMATION_FPS

	func get_dense_record_count() -> int:
		dense_getter_calls += 1
		return positions.size()

	func get_handle_at_stable_index(index: int) -> int:
		return index + 1 if index >= 0 and index < positions.size() else 0

	func get_position_at_stable_index(index: int) -> Vector2:
		return positions[index]

	func get_direction_at_stable_index(index: int) -> Vector2:
		return directions[index]

	func get_visual_age_at_stable_index(index: int) -> float:
		return float(ages[index])


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
	var simulation := FakeSimulation.new()
	simulation.configure()
	fixture.add_child(simulation)
	await process_frame
	await _test_headless_contract(fixture, simulation)
	await _test_fixed_multimesh_path(fixture, simulation)
	current_scene = null
	fixture.queue_free()
	for _cleanup_frame in range(4):
		await process_frame
	if failures.is_empty():
		print("CAPOO_MAGE_FIREBALL_PRESENTER_SMOKE_OK")
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	quit(1)


func _test_headless_contract(
	fixture: Node2D,
	simulation: FakeSimulation
) -> void:
	var presenter := PRESENTER_SCENE.instantiate() as PRESENTER_SCRIPT
	fixture.add_child(presenter)
	await process_frame
	_expect(
		presenter.bind_simulation_service(simulation),
		"Presenter must bind the typed Mage simulation service."
	)
	var getter_calls_before := simulation.dense_getter_calls
	_expect(
		presenter.flush_presenter() == 0
		and simulation.dense_getter_calls == getter_calls_before,
		"Headless flush must not scan Mage simulation rows."
	)
	var metrics := presenter.get_metrics()
	_expect(
		bool(metrics["headless_disabled"])
		and int(metrics["allocated_base_instances"]) == 0
		and int(metrics["allocated_emission_instances"]) == 0
		and int(metrics["allocated_halo_instances"]) == 0
		and int(metrics["visual_writes"]) == 0,
		"Headless Mage presentation must allocate and write zero instances."
	)
	presenter.queue_free()
	await process_frame


func _test_fixed_multimesh_path(
	fixture: Node2D,
	simulation: FakeSimulation
) -> void:
	var presenter := PRESENTER_SCENE.instantiate() as PRESENTER_SCRIPT
	presenter._headless_disabled = false
	fixture.add_child(presenter)
	await process_frame
	_expect(presenter.bind_simulation_service(simulation), "Rendered presenter must bind.")
	var child_count_before := presenter.get_child_count()
	var visible_count := presenter.flush_presenter()
	var metrics := presenter.get_metrics()
	var base := (presenter.get_node("FireballBase") as MultiMeshInstance2D).multimesh
	var emission := (
		presenter.get_node("FireballEmission") as MultiMeshInstance2D
	).multimesh
	var halo := (presenter.get_node("FireballHalo") as MultiMeshInstance2D).multimesh
	_expect(
		child_count_before == 3
		and presenter.get_child_count() == 3
		and int(metrics["draw_family_count"]) == 3,
		"Mage presenter must retain exactly three authored MultiMesh families."
	)
	_expect(
		visible_count == PRESENTER_SCRIPT.VISUAL_CAPACITY
		and base.instance_count == PRESENTER_SCRIPT.VISUAL_CAPACITY
		and emission.instance_count == PRESENTER_SCRIPT.VISUAL_CAPACITY
		and halo.instance_count == PRESENTER_SCRIPT.VISUAL_CAPACITY
		and base.visible_instance_count == PRESENTER_SCRIPT.VISUAL_CAPACITY
		and emission.visible_instance_count == PRESENTER_SCRIPT.VISUAL_CAPACITY
		and halo.visible_instance_count == PRESENTER_SCRIPT.VISUAL_CAPACITY,
		"All Mage draw families must share the fixed visible prefix."
	)
	_expect(
		int(metrics["last_offscreen_omissions"])
			== DENSE_COUNT - VISIBLE_CANDIDATE_COUNT
		and int(metrics["last_capacity_drops"])
			== VISIBLE_CANDIDATE_COUNT - PRESENTER_SCRIPT.VISUAL_CAPACITY,
		"Offscreen and over-capacity Mage rows must be presentation-only omissions."
	)
	var presenter_source := FileAccess.get_file_as_string(
		"res://scene/combat/presentation/capoo_mage_fireball_presenter.gd"
	)
	var base_shader := (
		(presenter.get_node("FireballBase") as MultiMeshInstance2D).material
		as ShaderMaterial
	).shader
	_expect(
		presenter_source.contains("visual_age * ANIMATION_FPS")
		and presenter_source.contains("direction.angle()")
		and presenter_source.contains("SPRITE_LOCAL_OFFSET")
		and base_shader.code.contains("INSTANCE_CUSTOM")
		and base_shader.code.contains("* 6.0")
		and base_shader.code.contains("/ 6.0"),
		"Mage presenter must preserve six-frame animation, direction, and local sprite offset."
	)
	presenter.prepare_for_runtime_teardown()
	presenter.prepare_for_runtime_teardown()
	metrics = presenter.get_metrics()
	_expect(
		int(metrics["teardown_count"]) == 1
		and int(metrics["allocated_base_instances"]) == 0
		and int(metrics["allocated_emission_instances"]) == 0
		and int(metrics["allocated_halo_instances"]) == 0
		and int(metrics["visible_fireballs"]) == 0,
		"Mage presenter teardown must synchronously clear all visual storage."
	)
	_expect(
		not presenter.bind_simulation_service(simulation),
		"A torn-down Mage presenter must reject rebind."
	)
	presenter.queue_free()
	await process_frame


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
