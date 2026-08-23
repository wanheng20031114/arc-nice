extends SceneTree

const PresenterScript := preload(
	"res://scene/combat/simulation/rapid_projectile_presenter.gd"
)
const PRESENTER_SCENE := preload(
	"res://scene/combat/simulation/rapid_projectile_presenter.tscn"
)
const RapidFireSimulationServiceScript := preload(
	"res://scene/combat/simulation/rapid_fire_simulation_service.gd"
)
const PRESENTER_SCRIPT_PATH := (
	"res://scene/combat/simulation/rapid_projectile_presenter.gd"
)
const PRESENTER_SHADER_PATH := (
	"res://scene/combat/simulation/rapid_projectile_presenter.gdshader"
)
const HIT_PRESENTER_SHADER_PATH := (
	"res://scene/combat/simulation/rapid_projectile_hit_presenter.gdshader"
)
const TEST_VIEW_RECT := Rect2(-32.0, -32.0, 64.0, 64.0)
const TEST_DELTA := 1.0 / 60.0

var failures: Array[String] = []


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	_test_static_authored_multimesh_contract()
	_test_direction_transforms_and_animation_frames()
	await _test_replica_selection_and_animation_age()
	await _test_offscreen_compaction_and_capacity_do_not_mutate_simulation()
	if DisplayServer.get_name() == "headless":
		await _test_headless_sync_clear_and_teardown()
	else:
		await _test_display_sync_hidden_and_teardown()
	_finish()


func _test_static_authored_multimesh_contract() -> void:
	var presenter := PRESENTER_SCENE.instantiate() as PresenterScript
	_expect(presenter != null, "RapidProjectilePresenter scene must instantiate.")
	if presenter == null:
		return
	var multimesh_nodes := _collect_multimesh_nodes(presenter)
	_expect(
		multimesh_nodes.size() == 4,
		"Presenter scene must author three projectile batches and one hit batch."
	)
	var multimesh_instance := presenter.get_multimesh_instance()
	_expect(
		multimesh_instance != null
		and multimesh_instance.name == &"ProjectileMultiMesh",
		"The unique authored batch must keep the stable ProjectileMultiMesh path."
	)
	if multimesh_instance != null and multimesh_instance.multimesh != null:
		var multimesh := multimesh_instance.multimesh
		var quad := multimesh.mesh as QuadMesh
		_expect(
			multimesh.resource_local_to_scene
			and multimesh.transform_format == MultiMesh.TRANSFORM_2D
			and multimesh.use_custom_data,
			"Authored MultiMesh must be scene-local 2D data with INSTANCE_CUSTOM."
		)
		_expect(
			multimesh.instance_count == 0
			and multimesh.visible_instance_count == 0,
			(
				"The authored batch must stay unallocated until non-headless ready, "
				+ "with an empty visible prefix."
			)
		)
		_expect(
			quad != null and quad.size.is_equal_approx(Vector2(8.0, 8.0)),
			"AK presenter mesh must remain one native 8x8 atlas frame."
		)
		_expect(
			multimesh_instance.texture != null
			and multimesh_instance.texture.get_size().is_equal_approx(
				Vector2(24.0, 8.0)
			),
			"Presenter must reuse the existing 24x8 three-frame AK texture."
		)
		_expect(
			multimesh_instance.texture_filter
			== CanvasItem.TEXTURE_FILTER_NEAREST,
			"AK pixel art must use nearest texture filtering."
		)
		var shader_material := multimesh_instance.material as ShaderMaterial
		_expect(
			shader_material != null
			and shader_material.shader != null
			and is_equal_approx(
				float(shader_material.get_shader_parameter("frame_count")),
				3.0
			)
			and is_equal_approx(
				float(shader_material.get_shader_parameter("animation_fps")),
				16.0
			),
			"The AK batch must author a three-frame 16 FPS material."
		)
	_expect_projectile_batch(
		presenter.get_gunner_multimesh_instance(),
		&"GunnerProjectileMultiMesh",
		Vector2(36.0, 8.0),
		Vector2(12.0, 8.0),
		25.0
	)
	_expect_projectile_batch(
		presenter.get_gunner_elite_multimesh_instance(),
		&"GunnerEliteProjectileMultiMesh",
		Vector2(36.0, 8.0),
		Vector2(12.0, 8.0),
		25.0
	)
	var hit_multimesh_instance := presenter.get_hit_multimesh_instance()
	_expect(
		hit_multimesh_instance != null
		and hit_multimesh_instance.name == &"HitMultiMesh"
		and hit_multimesh_instance.multimesh != null
		and hit_multimesh_instance.multimesh.resource_local_to_scene
		and hit_multimesh_instance.multimesh.transform_format
		== MultiMesh.TRANSFORM_2D
		and hit_multimesh_instance.multimesh.use_custom_data
		and hit_multimesh_instance.multimesh.instance_count == 0
		and hit_multimesh_instance.multimesh.visible_instance_count == 0,
		"Hit presentation must be one authored, empty, scene-local MultiMesh."
	)

	var shader_source := FileAccess.get_file_as_string(PRESENTER_SHADER_PATH)
	_expect(
		shader_source.contains("render_mode unshaded")
		and shader_source.contains("INSTANCE_CUSTOM.r")
		and shader_source.contains("uniform float frame_count")
		and shader_source.contains("uniform float animation_fps"),
		"Shader must use INSTANCE_CUSTOM and per-material atlas cadence uniforms."
	)
	var hit_shader_source := FileAccess.get_file_as_string(
		HIT_PRESENTER_SHADER_PATH
	)
	_expect(
		hit_shader_source.contains("render_mode unshaded, blend_add")
		and hit_shader_source.contains("INSTANCE_CUSTOM.r"),
		"Hit batch shader must animate a procedural unshaded flash from custom data."
	)
	var presenter_source := FileAccess.get_file_as_string(PRESENTER_SCRIPT_PATH)
	_expect(
		not presenter_source.contains("MultiMesh.new()")
		and not presenter_source.contains("MultiMeshInstance2D.new()")
		and not presenter_source.contains("QuadMesh.new()")
		and not presenter_source.contains("add_child(")
		and presenter_source.contains("func _process(delta: float)")
		and presenter_source.contains("viewport.get_canvas_transform()")
		and presenter_source.contains(
			"ak_multimesh.instance_count = FIXED_INSTANCE_CAPACITY"
		)
		and presenter_source.contains(
			"gunner_multimesh.instance_count = GUNNER_FIXED_INSTANCE_CAPACITY"
		)
		and presenter_source.contains(
			"gunner_elite_multimesh.instance_count"
		),
		"Presenter must render-sync from the viewport transform without dynamic nodes."
	)
	var transformed_world_rect := PresenterScript.calculate_world_aabb(
		Rect2(Vector2.ZERO, Vector2(1280.0, 720.0)),
		Transform2D(0.0, Vector2(2.0, 2.0), 0.0, Vector2(100.0, 40.0))
	)
	_expect(
		transformed_world_rect.position.is_equal_approx(Vector2(-50.0, -20.0))
		and transformed_world_rect.size.is_equal_approx(Vector2(640.0, 360.0)),
		"Viewport canvas inversion must derive the complete world-space view AABB."
	)
	presenter.free()


func _test_direction_transforms_and_animation_frames() -> void:
	var position := Vector2(13.0, -7.0)
	for direction in [Vector2.RIGHT, Vector2.DOWN, Vector2.LEFT, Vector2.UP]:
		var transform := PresenterScript.build_instance_transform(
			position,
			direction
		)
		_expect(
			transform.origin.is_equal_approx(position)
			and transform.x.normalized().is_equal_approx(direction),
			"Instance transform must preserve position and face its projectile direction."
		)
	_expect(
		PresenterScript.calculate_animation_frame(0.0) == 0
		and PresenterScript.calculate_animation_frame(0.0624) == 0
		and PresenterScript.calculate_animation_frame(1.0 / 16.0) == 1
		and PresenterScript.calculate_animation_frame(2.0 / 16.0) == 2
		and PresenterScript.calculate_animation_frame(3.0 / 16.0) == 0,
		"Animation frame oracle must advance at 16 FPS and wrap across three frames."
	)
	_expect(
		PresenterScript.calculate_animation_frame_for_profile(
			0.0399,
			RapidFireSimulationServiceScript.Profile.GUNNER
		) == 0
		and PresenterScript.calculate_animation_frame_for_profile(
			1.0 / 25.0,
			RapidFireSimulationServiceScript.Profile.GUNNER
		) == 1
		and PresenterScript.calculate_animation_frame_for_profile(
			3.0 / 25.0,
			RapidFireSimulationServiceScript.Profile.GUNNER_ELITE
		) == 0,
		"Both gunner families must advance their three-frame atlases at 25 FPS."
	)


func _test_replica_selection_and_animation_age() -> void:
	var service := RapidFireSimulationServiceScript.new()
	service.reserve_projectile_capacity(5)
	var data_handle := _register_projectile(
		service,
		Vector2(-4.0, 0.0),
		Vector2.RIGHT,
		8_001
	)
	_register_projectile(
		service,
		Vector2.ZERO,
		Vector2.RIGHT,
		8_002,
		RapidFireSimulationServiceScript.Mode.SHADOW
	)
	var delayed_replica_handle := service.register_replica_projectile(
		RapidFireSimulationServiceScript.Profile.AK,
		Vector2(4.0, 0.0),
		Vector2.RIGHT,
		120.0,
		2.0,
		500,
		8_003,
		TEST_DELTA * 1.5
	)
	var gunner_replica_handle := service.register_replica_projectile(
		RapidFireSimulationServiceScript.Profile.GUNNER,
		Vector2(0.0, 4.0),
		Vector2.DOWN,
		60.0,
		2.0,
		500,
		8_004,
		0.0
	)
	var pending_elite_handle := service.register_replica_projectile(
		RapidFireSimulationServiceScript.Profile.GUNNER_ELITE,
		Vector2(0.0, -4.0),
		Vector2.UP,
		60.0,
		2.0,
		500,
		8_005,
		TEST_DELTA * 10.0
	)
	_expect(
		data_handle > 0
		and delayed_replica_handle > 0
		and gunner_replica_handle > 0
		and pending_elite_handle > 0
		and PresenterScript.count_presentable_projectiles_for_view(
			service,
			TEST_VIEW_RECT,
			PresenterScript.FIXED_INSTANCE_CAPACITY
		) == 0
		and PresenterScript.count_presentable_projectiles_for_profile_and_view(
			service,
			RapidFireSimulationServiceScript.Profile.GUNNER,
			TEST_VIEW_RECT,
			PresenterScript.GUNNER_FIXED_INSTANCE_CAPACITY
		) == 0,
		"DATA and REPLICA records must both stay hidden while pending activation."
	)
	service._physics_process(TEST_DELTA)
	_expect(
		PresenterScript.count_presentable_projectiles_for_view(
			service,
			TEST_VIEW_RECT,
			PresenterScript.FIXED_INSTANCE_CAPACITY
		) == 0,
		"Presenter selection must retain the service's registration-frame gate."
	)

	await physics_frame
	service._physics_process(TEST_DELTA)
	_expect(
		PresenterScript.count_presentable_projectiles_for_view(
			service,
			TEST_VIEW_RECT,
			PresenterScript.FIXED_INSTANCE_CAPACITY
		) == 1
		and PresenterScript.count_presentable_projectiles_for_profile_and_view(
			service,
			RapidFireSimulationServiceScript.Profile.GUNNER,
			TEST_VIEW_RECT,
			PresenterScript.GUNNER_FIXED_INSTANCE_CAPACITY
		) == 1
		and PresenterScript.count_presentable_projectiles_for_profile_and_view(
			service,
			RapidFireSimulationServiceScript.Profile.GUNNER_ELITE,
			TEST_VIEW_RECT,
			PresenterScript.GUNNER_ELITE_FIXED_INSTANCE_CAPACITY
		) == 0
		and service.get_slot_state(delayed_replica_handle)
		== RapidFireSimulationServiceScript.SlotState.PENDING_ACTIVATION
		and service.get_slot_state(gunner_replica_handle)
		== RapidFireSimulationServiceScript.SlotState.ACTIVE
		and is_equal_approx(
			service.get_replica_active_age_seconds(gunner_replica_handle),
			TEST_DELTA
		)
		and service.get_position(gunner_replica_handle).is_equal_approx(
			Vector2(0.0, 5.0)
		),
		"Only ACTIVE DATA/REPLICA rows may enter their profile-specific visual prefixes."
	)

	await physics_frame
	service._physics_process(TEST_DELTA)
	_expect(
		PresenterScript.count_presentable_projectiles_for_view(
			service,
			TEST_VIEW_RECT,
			PresenterScript.FIXED_INSTANCE_CAPACITY
		) == 2
		and PresenterScript.count_presentable_projectiles_for_view(
			service,
			TEST_VIEW_RECT,
			1
		) == 1
		and service.get_slot_state(delayed_replica_handle)
		== RapidFireSimulationServiceScript.SlotState.ACTIVE
		and is_equal_approx(
			service.get_replica_active_age_seconds(delayed_replica_handle),
			TEST_DELTA * 0.5
		)
		and service.get_position(delayed_replica_handle).is_equal_approx(
			Vector2(5.0, 0.0)
		)
		and service.get_slot_state(pending_elite_handle)
		== RapidFireSimulationServiceScript.SlotState.PENDING_ACTIVATION
		and service.get_active_slot_count() == 5,
		"Delay overshoot age must drive REPLICA animation while capacity truncation stays visual-only."
	)
	service.prepare_for_runtime_teardown()
	service.free()


func _test_offscreen_compaction_and_capacity_do_not_mutate_simulation() -> void:
	var culling_service := RapidFireSimulationServiceScript.new()
	culling_service.reserve_projectile_capacity(5)
	var positions := [
		Vector2(-500.0, 0.0),
		Vector2(-10.0, 0.0),
		Vector2(500.0, 0.0),
		Vector2(0.0, 10.0),
		Vector2(10.0, 0.0),
	]
	for projectile_index in range(positions.size()):
		_register_projectile(
			culling_service,
			positions[projectile_index],
			Vector2.RIGHT,
			projectile_index + 1
		)
	_register_projectile(
		culling_service,
		Vector2.ZERO,
		Vector2.RIGHT,
		9_999,
		RapidFireSimulationServiceScript.Mode.SHADOW
	)
	_register_projectile(
		culling_service,
		Vector2(1.0, 1.0),
		Vector2.LEFT,
		10_001,
		RapidFireSimulationServiceScript.Mode.DATA,
		RapidFireSimulationServiceScript.Profile.GUNNER
	)
	_register_projectile(
		culling_service,
		Vector2(500.0, 1.0),
		Vector2.LEFT,
		10_002,
		RapidFireSimulationServiceScript.Mode.DATA,
		RapidFireSimulationServiceScript.Profile.GUNNER
	)
	_register_projectile(
		culling_service,
		Vector2(-1.0, 1.0),
		Vector2.UP,
		10_003,
		RapidFireSimulationServiceScript.Mode.DATA,
		RapidFireSimulationServiceScript.Profile.GUNNER_ELITE
	)
	_expect(
		PresenterScript.count_presentable_projectiles_for_view(
			culling_service,
			TEST_VIEW_RECT,
			PresenterScript.FIXED_INSTANCE_CAPACITY
		) == 0,
		"Pending culling fixtures must not be considered presentable."
	)
	await physics_frame
	culling_service._physics_process(TEST_DELTA)
	var culling_active_before := culling_service.get_active_slot_count()
	var compact_visible_count := PresenterScript.count_presentable_projectiles_for_view(
		culling_service,
		TEST_VIEW_RECT,
		PresenterScript.FIXED_INSTANCE_CAPACITY
	)
	_expect(
		compact_visible_count == 3,
		(
			"Two offscreen DATA records and one visible SHADOW record must be skipped "
			+ "while visible DATA records compact to the prefix."
		)
	)
	_expect(
		PresenterScript.count_presentable_projectiles_for_profile_and_view(
			culling_service,
			RapidFireSimulationServiceScript.Profile.GUNNER,
			TEST_VIEW_RECT,
			PresenterScript.GUNNER_FIXED_INSTANCE_CAPACITY
		) == 1
		and PresenterScript.count_presentable_projectiles_for_profile_and_view(
			culling_service,
			RapidFireSimulationServiceScript.Profile.GUNNER_ELITE,
			TEST_VIEW_RECT,
			PresenterScript.GUNNER_ELITE_FIXED_INSTANCE_CAPACITY
		) == 1,
		"Profile selection must independently compact normal and elite gunner data."
	)
	_expect(
		culling_service.get_active_slot_count() == culling_active_before,
		"View culling must never release or mutate authoritative simulation slots."
	)
	culling_service.prepare_for_runtime_teardown()
	culling_service.free()

	var capacity_service := RapidFireSimulationServiceScript.new()
	var simulated_count := PresenterScript.FIXED_INSTANCE_CAPACITY + 32
	capacity_service.reserve_projectile_capacity(simulated_count)
	for projectile_index in range(simulated_count):
		_register_projectile(
			capacity_service,
			Vector2.ZERO,
			Vector2.RIGHT,
			10_000 + projectile_index
		)
	await physics_frame
	capacity_service._physics_process(TEST_DELTA)
	var capped_visible_count := PresenterScript.count_presentable_projectiles_for_view(
		capacity_service,
		TEST_VIEW_RECT,
		PresenterScript.FIXED_INSTANCE_CAPACITY
	)
	_expect(
		capped_visible_count == PresenterScript.FIXED_INSTANCE_CAPACITY,
		"Presenter selection must clamp to its fixed visual capacity."
	)
	_expect(
		capacity_service.get_active_slot_count() == simulated_count
		and capacity_service.get_dense_record_count() == simulated_count,
		"Visual capacity truncation must leave every simulation record alive."
	)
	capacity_service.prepare_for_runtime_teardown()
	capacity_service.free()


func _test_headless_sync_clear_and_teardown() -> void:
	_expect(
		DisplayServer.get_name() == "headless",
		"Presenter headless smoke must run with the headless display driver."
	)
	var presenter := PRESENTER_SCENE.instantiate() as PresenterScript
	var service := RapidFireSimulationServiceScript.new()
	service.reserve_projectile_capacity(3)
	for projectile_index in range(3):
		_register_projectile(
			service,
			Vector2(float(projectile_index), 0.0),
			Vector2.RIGHT,
			20_000 + projectile_index
		)
	root.add_child(presenter)
	await process_frame
	var multimesh_instance := presenter.get_multimesh_instance()
	var gunner_multimesh_instance := presenter.get_gunner_multimesh_instance()
	var gunner_elite_multimesh_instance := (
		presenter.get_gunner_elite_multimesh_instance()
	)
	var hit_multimesh_instance := presenter.get_hit_multimesh_instance()
	var before_sync_metrics := presenter.get_metrics()
	var active_before_sync := service.get_active_slot_count()
	_expect(
		multimesh_instance != null
		and multimesh_instance.multimesh != null
		and multimesh_instance.multimesh.instance_count == 0
		and multimesh_instance.multimesh.visible_instance_count == 0,
		"Headless ready must release every authored MultiMesh instance."
	)
	_expect(
		gunner_multimesh_instance != null
		and gunner_multimesh_instance.multimesh != null
		and gunner_multimesh_instance.multimesh.instance_count == 0
		and gunner_multimesh_instance.multimesh.visible_instance_count == 0
		and gunner_elite_multimesh_instance != null
		and gunner_elite_multimesh_instance.multimesh != null
		and gunner_elite_multimesh_instance.multimesh.instance_count == 0
		and gunner_elite_multimesh_instance.multimesh.visible_instance_count == 0,
		"Headless ready must release both gunner projectile batches."
	)
	_expect(
		hit_multimesh_instance != null
		and hit_multimesh_instance.multimesh != null
		and hit_multimesh_instance.multimesh.instance_count == 0
		and hit_multimesh_instance.multimesh.visible_instance_count == 0,
		"Headless ready must keep the hit batch fully unallocated."
	)
	var synced_count := presenter.sync_from_service(service, TEST_VIEW_RECT)
	var after_sync_metrics := presenter.get_metrics()
	_expect(
		synced_count == 0
		and int(before_sync_metrics["sync_executions"]) == 0
		and int(after_sync_metrics["sync_executions"]) == 0
		and int(after_sync_metrics["last_scanned_count"]) == 0,
		"Headless sync must return before scanning or uploading simulation records."
	)
	_expect(
		not presenter.queue_completion_hit(
			RapidFireSimulationServiceScript.Mode.DATA,
			RapidFireSimulationServiceScript.Profile.AK,
			RapidFireSimulationServiceScript.CompletionReason.TARGET,
			Vector2.ZERO,
			Vector2.RIGHT
		)
		and int(presenter.get_metrics()["last_hit_scanned_count"]) == 0,
		"Headless hit presentation must reject before allocating or scanning."
	)
	_expect(
		service.get_active_slot_count() == active_before_sync,
		"Headless presentation must not alter simulation lifecycle."
	)

	presenter.visible = false
	presenter.clear()
	_expect(
		multimesh_instance.multimesh.instance_count == 0
		and multimesh_instance.multimesh.visible_instance_count == 0,
		"Hidden clear must retain zero headless instances."
	)
	presenter.prepare_for_runtime_teardown()
	presenter.prepare_for_runtime_teardown()
	var teardown_metrics := presenter.get_metrics()
	_expect(
		int(teardown_metrics["teardown_count"]) == 1
		and int(teardown_metrics["allocated_instances"]) == 0
		and int(teardown_metrics["visible_instances"]) == 0,
		"Presenter teardown must be idempotent and release all instances."
	)
	_expect(
		presenter.sync_from_service(service, TEST_VIEW_RECT) == 0
		and int(presenter.get_metrics()["sync_executions"]) == 0,
		"A torn-down headless presenter must remain inert."
	)

	service.prepare_for_runtime_teardown()
	service.free()
	presenter.queue_free()
	await process_frame
	await physics_frame


func _test_display_sync_hidden_and_teardown() -> void:
	var presenter := PRESENTER_SCENE.instantiate() as PresenterScript
	var service := RapidFireSimulationServiceScript.new()
	service.reserve_projectile_capacity(7)
	_register_projectile(service, Vector2(-10.0, 0.0), Vector2.RIGHT, 30_001)
	_register_projectile(service, Vector2(500.0, 0.0), Vector2.LEFT, 30_002)
	_register_projectile(service, Vector2(0.0, 10.0), Vector2.DOWN, 30_003)
	_register_projectile(
		service,
		Vector2.ZERO,
		Vector2.UP,
		30_004,
		RapidFireSimulationServiceScript.Mode.SHADOW
	)
	_register_projectile(
		service,
		Vector2(5.0, 5.0),
		Vector2.LEFT,
		30_005,
		RapidFireSimulationServiceScript.Mode.DATA,
		RapidFireSimulationServiceScript.Profile.GUNNER
	)
	_register_projectile(
		service,
		Vector2(-5.0, 5.0),
		Vector2.UP,
		30_006,
		RapidFireSimulationServiceScript.Mode.DATA,
		RapidFireSimulationServiceScript.Profile.GUNNER_ELITE
	)
	var replica_handle := service.register_replica_projectile(
		RapidFireSimulationServiceScript.Profile.AK,
		Vector2(10.0, -5.0),
		Vector2.RIGHT,
		60.0,
		2.0,
		500,
		30_007,
		TEST_DELTA * 0.5
	)
	_expect(replica_handle > 0, "Display fixture REPLICA must register.")
	root.add_child(presenter)
	await process_frame
	await physics_frame
	service._physics_process(TEST_DELTA)
	var multimesh_instance := presenter.get_multimesh_instance()
	var multimesh := multimesh_instance.multimesh
	var gunner_multimesh := presenter.get_gunner_multimesh_instance().multimesh
	var gunner_elite_multimesh := (
		presenter.get_gunner_elite_multimesh_instance().multimesh
	)
	var hit_multimesh := presenter.get_hit_multimesh_instance().multimesh
	_expect(
		multimesh.instance_count == PresenterScript.FIXED_INSTANCE_CAPACITY
		and multimesh.visible_instance_count == 0
		and gunner_multimesh.instance_count
		== PresenterScript.GUNNER_FIXED_INSTANCE_CAPACITY
		and gunner_multimesh.visible_instance_count == 0
		and gunner_elite_multimesh.instance_count
		== PresenterScript.GUNNER_ELITE_FIXED_INSTANCE_CAPACITY
		and gunner_elite_multimesh.visible_instance_count == 0
		and hit_multimesh.instance_count == PresenterScript.HIT_INSTANCE_CAPACITY
		and hit_multimesh.visible_instance_count == 0,
		"Display ready must allocate exactly the fixed instance capacity."
	)
	var active_before_sync := service.get_active_slot_count()
	_expect(
		presenter.sync_from_service(service, TEST_VIEW_RECT) == 5
		and multimesh.visible_instance_count == 3
		and gunner_multimesh.visible_instance_count == 1
		and gunner_elite_multimesh.visible_instance_count == 1,
		"Display sync must route visible ACTIVE DATA/REPLICA records into three family prefixes."
	)
	var first_transform := multimesh.get_instance_transform_2d(0)
	var second_transform := multimesh.get_instance_transform_2d(1)
	var replica_transform := multimesh.get_instance_transform_2d(2)
	_expect(
		first_transform.origin.is_equal_approx(Vector2(-10.0, 0.0))
		and first_transform.x.normalized().is_equal_approx(Vector2.RIGHT)
		and second_transform.origin.is_equal_approx(Vector2(0.0, 10.0))
		and second_transform.x.normalized().is_equal_approx(Vector2.DOWN)
		and replica_transform.origin.is_equal_approx(Vector2(10.5, -5.0))
		and replica_transform.x.normalized().is_equal_approx(Vector2.RIGHT)
		and is_equal_approx(
			multimesh.get_instance_custom_data(2).r,
			TEST_DELTA * 0.5
		),
		"Display uploads must retain stable transforms and use active REPLICA age for animation."
	)
	_expect(
		service.get_active_slot_count() == active_before_sync,
		"Display uploads and view culling must not alter simulation slots."
	)
	_expect(
		presenter.queue_completion_hit(
			RapidFireSimulationServiceScript.Mode.DATA,
			RapidFireSimulationServiceScript.Profile.AK,
			RapidFireSimulationServiceScript.CompletionReason.TARGET,
			Vector2.ZERO,
			Vector2.RIGHT
		)
		and not presenter.queue_completion_hit(
			RapidFireSimulationServiceScript.Mode.DATA,
			RapidFireSimulationServiceScript.Profile.AK,
			RapidFireSimulationServiceScript.CompletionReason.LIFETIME,
			Vector2.ZERO,
			Vector2.RIGHT
		)
		and not presenter.queue_completion_hit(
			RapidFireSimulationServiceScript.Mode.SHADOW,
			RapidFireSimulationServiceScript.Profile.AK,
			RapidFireSimulationServiceScript.CompletionReason.WORLD,
			Vector2.ZERO,
			Vector2.RIGHT
		)
		and not presenter.queue_completion_hit(
			RapidFireSimulationServiceScript.Mode.REPLICA,
			RapidFireSimulationServiceScript.Profile.AK,
			RapidFireSimulationServiceScript.CompletionReason.TARGET,
			Vector2.ZERO,
			Vector2.RIGHT
		),
		"Only authoritative DATA world/target completions may enter the fixed hit batch."
	)
	presenter._sync_hits(0.01, TEST_VIEW_RECT)
	_expect(
		hit_multimesh.visible_instance_count == 1
		and int(presenter.get_metrics()["active_hit_count"]) == 1,
		"One accepted completion must render as one batched hit instance."
	)
	presenter._sync_hits(PresenterScript.HIT_LIFETIME_SECONDS, TEST_VIEW_RECT)
	_expect(
		hit_multimesh.visible_instance_count == 0
		and int(presenter.get_metrics()["active_hit_count"]) == 0,
		"Batched hits must expire in-place without creating or freeing nodes."
	)
	presenter.visible = false
	var executions_before_hidden_sync := int(presenter.get_metrics()["sync_executions"])
	_expect(
		presenter.sync_from_service(service, TEST_VIEW_RECT) == 0
		and multimesh.visible_instance_count == 0
		and int(presenter.get_metrics()["sync_executions"])
		== executions_before_hidden_sync,
		"A hidden presenter must clear its prefix without scanning or uploading."
	)
	presenter.prepare_for_runtime_teardown()
	presenter.prepare_for_runtime_teardown()
	_expect(
		multimesh.instance_count == 0
		and multimesh.visible_instance_count == 0
		and gunner_multimesh.instance_count == 0
		and gunner_multimesh.visible_instance_count == 0
		and gunner_elite_multimesh.instance_count == 0
		and gunner_elite_multimesh.visible_instance_count == 0
		and hit_multimesh.instance_count == 0
		and hit_multimesh.visible_instance_count == 0
		and int(presenter.get_metrics()["teardown_count"]) == 1,
		"Display teardown must be idempotent and release its fixed batch."
	)
	service.prepare_for_runtime_teardown()
	service.free()
	presenter.queue_free()
	await process_frame


func _register_projectile(
	service: RapidFireSimulationServiceScript,
	position: Vector2,
	direction: Vector2,
	projectile_id: int,
	mode: RapidFireSimulationServiceScript.Mode = (
		RapidFireSimulationServiceScript.Mode.DATA
	),
	profile: RapidFireSimulationServiceScript.Profile = (
		RapidFireSimulationServiceScript.Profile.AK
	)
) -> int:
	return service.register_projectile(
		mode,
		profile,
		position,
		direction,
		120.0,
		2.0,
		12,
		500,
		projectile_id,
		2,
		projectile_id & 1
	)


func _expect_projectile_batch(
	multimesh_instance: MultiMeshInstance2D,
	expected_name: StringName,
	expected_texture_size: Vector2,
	expected_quad_size: Vector2,
	expected_fps: float
) -> void:
	var valid := (
		multimesh_instance != null
		and multimesh_instance.name == expected_name
		and multimesh_instance.multimesh != null
	)
	_expect(valid, "%s must be a static authored MultiMesh batch." % expected_name)
	if not valid:
		return
	var multimesh := multimesh_instance.multimesh
	var quad := multimesh.mesh as QuadMesh
	var material := multimesh_instance.material as ShaderMaterial
	_expect(
		multimesh.resource_local_to_scene
		and multimesh.transform_format == MultiMesh.TRANSFORM_2D
		and multimesh.use_custom_data
		and multimesh.instance_count == 0
		and multimesh.visible_instance_count == 0
		and quad != null
		and quad.size.is_equal_approx(expected_quad_size)
		and multimesh_instance.texture != null
		and multimesh_instance.texture.get_size().is_equal_approx(
			expected_texture_size
		)
		and multimesh_instance.texture_filter
		== CanvasItem.TEXTURE_FILTER_NEAREST
		and material != null
		and material.shader != null
		and is_equal_approx(
			float(material.get_shader_parameter("frame_count")),
			3.0
		)
		and is_equal_approx(
			float(material.get_shader_parameter("animation_fps")),
			expected_fps
		),
		"%s must preserve its atlas, frame size, and cadence." % expected_name
	)


func _collect_multimesh_nodes(parent: Node) -> Array[MultiMeshInstance2D]:
	var nodes: Array[MultiMeshInstance2D] = []
	for child in parent.get_children():
		var multimesh_instance := child as MultiMeshInstance2D
		if multimesh_instance != null:
			nodes.append(multimesh_instance)
		nodes.append_array(_collect_multimesh_nodes(child))
	return nodes


func _finish() -> void:
	var result := {
		"status": "ok" if failures.is_empty() else "failed",
		"fixed_capacity": PresenterScript.FIXED_INSTANCE_CAPACITY,
		"failures": failures.duplicate(),
	}
	print("RAPID_PROJECTILE_PRESENTER_JSON %s" % JSON.stringify(result))
	if failures.is_empty():
		print("RAPID_PROJECTILE_PRESENTER_SMOKE_TEST_OK")
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	quit(1)


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
