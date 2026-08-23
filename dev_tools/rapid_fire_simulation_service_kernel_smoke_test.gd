extends SceneTree

const RapidFireSimulationServiceScript := preload(
	"res://scene/combat/simulation/rapid_fire_simulation_service.gd"
)
const TEST_DELTA := 1.0 / 60.0
const LARGE_PROJECTILE_COUNT := 100_000
const FIXED_SEED := 0x5A17C0DE
const CARDINAL_DIRECTIONS := [
	Vector2.RIGHT,
	Vector2.DOWN,
	Vector2.LEFT,
	Vector2.UP,
]

var failures: Array[String] = []


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	await _test_same_frame_activation_and_final_lifetime_step()
	_test_stale_handle_and_generation_reuse()
	_test_frozen_damage_source_storage_and_compaction()
	await _test_stable_tombstone_compaction_and_completion_order()
	await _test_shadow_difference_read_model_and_teardown()
	await _test_fixed_seed_hundred_thousand_projectiles()
	_finish()


func _test_same_frame_activation_and_final_lifetime_step() -> void:
	var service := RapidFireSimulationServiceScript.new()
	_expect(service.reserve_projectile_capacity(4), "Small kernel reserve must succeed.")
	var spawn_frame := Engine.get_physics_frames()
	var lifetime := TEST_DELTA * 0.5
	var handle := service.register_projectile(
		RapidFireSimulationServiceScript.Mode.DATA,
		RapidFireSimulationServiceScript.Profile.AK,
		Vector2(10.0, 20.0),
		Vector2.RIGHT,
		120.0,
		lifetime,
		17,
		101,
		1001,
		2,
		1
	)
	_expect(handle > 0, "A valid DATA projectile must receive a handle.")
	_expect(
		service.get_spawn_physics_frame(handle) == spawn_frame,
		"Registration must capture the current physics frame."
	)
	_expect(
		service.get_direction(handle).is_equal_approx(Vector2.RIGHT),
		"The read-only direction getter must preserve normalized AK direction."
	)
	service._physics_process(TEST_DELTA)
	_expect(
		service.get_position(handle).is_equal_approx(Vector2(10.0, 20.0)),
		"A projectile must not advance in its registration frame."
	)
	_expect(
		service.get_slot_state(handle)
		== RapidFireSimulationServiceScript.SlotState.PENDING_ACTIVATION,
		"Same-frame registration must remain pending."
	)
	_expect(
		service.get_completion_count() == 0,
		"Same-frame registration must not finish even with a short lifetime."
	)

	await physics_frame
	service._physics_process(TEST_DELTA)
	_expect(
		service.get_completion_count() == 1,
		"The short-lifetime projectile must finish on its first active step."
	)
	_expect(
		service.get_completion_handle(0) == handle
		and service.get_completion_projectile_id(0) == 1001
		and service.get_completion_reason(0)
		== RapidFireSimulationServiceScript.CompletionReason.LIFETIME
		and service.get_completion_target_kind(0)
		== RapidFireSimulationServiceScript.TargetKind.NONE
		and service.get_completion_mode(0)
		== RapidFireSimulationServiceScript.Mode.DATA
		and service.get_completion_profile(0)
		== RapidFireSimulationServiceScript.Profile.AK
		and service.get_completion_direction(0).is_equal_approx(Vector2.RIGHT),
		"Completion output must preserve exact identity, mode, profile, and direction."
	)
	var expected_final_position := (
		Vector2(10.0, 20.0) + Vector2.RIGHT * 120.0 * TEST_DELTA
	)
	_expect(
		service.get_completion_position(0).is_equal_approx(expected_final_position),
		"The legacy AK final lifetime tick must still move one full delta."
	)
	_expect(
		not service.is_handle_live(handle)
		and service.get_active_slot_count() == 0
		and service.get_dense_record_count() == 0,
		"A lifetime completion must invalidate its handle and compact its row."
	)
	_expect(
		not service.is_physics_processing(),
		"An empty kernel must disable its physics callback."
	)
	service.prepare_for_runtime_teardown()
	service.free()

	var identity_service := RapidFireSimulationServiceScript.new()
	identity_service.reserve_projectile_capacity(2)
	var identity_handle := identity_service.register_projectile(
		RapidFireSimulationServiceScript.Mode.DATA,
		RapidFireSimulationServiceScript.Profile.AK,
		Vector2.ZERO,
		Vector2.RIGHT,
		60.0,
		1.0,
		10,
		55,
		0,
		2,
		0
	)
	_expect(
		identity_service.assign_projectile_identity(identity_handle, 2001)
		and identity_service.assign_projectile_identity(identity_handle, 2001)
		and not identity_service.assign_projectile_identity(
			identity_handle, 2002
		)
		and identity_service.get_projectile_id(identity_handle) == 2001
		and identity_service.get_world_check_phase(identity_handle) == 1
		and identity_service.get_world_step_index(identity_handle) == 0,
		"Pending identity assignment must be atomic, idempotent, and derive phase without rewinding cadence."
	)
	var preidentified_handle := identity_service.register_projectile(
		RapidFireSimulationServiceScript.Mode.DATA,
		RapidFireSimulationServiceScript.Profile.AK,
		Vector2.ZERO,
		Vector2.RIGHT,
		60.0,
		1.0,
		10,
		55,
		2002,
		2,
		1
	)
	_expect(
		identity_service.assign_projectile_identity(
			preidentified_handle, 2002
		)
		and identity_service.get_world_check_phase(preidentified_handle) == 0
		and identity_service.get_world_step_index(preidentified_handle) == 0,
		"An idempotent pending identity write must converge its phase without resetting the step index."
	)
	await physics_frame
	identity_service._physics_process(TEST_DELTA)
	_expect(
		not identity_service.assign_projectile_identity(identity_handle, 2001),
		"An active projectile must reject even an idempotent identity write."
	)
	identity_service.prepare_for_runtime_teardown()
	identity_service.free()


func _test_stale_handle_and_generation_reuse() -> void:
	var service := RapidFireSimulationServiceScript.new()
	service.reserve_projectile_capacity(2)
	var old_handle := _register_test_projectile(
		service,
		RapidFireSimulationServiceScript.Mode.SHADOW,
		1,
		1.0
	)
	_expect(service.release_projectile(old_handle), "A live handle must release once.")
	_expect(
		not service.is_handle_live(old_handle)
		and not service.release_projectile(old_handle),
		"A released handle must become stale immediately."
	)
	var replacement_handle := _register_test_projectile(
		service,
		RapidFireSimulationServiceScript.Mode.SHADOW,
		2,
		1.0
	)
	_expect(
		service.get_handle_slot(replacement_handle)
		== service.get_handle_slot(old_handle),
		"The free logical slot should be reusable without reusing the old handle."
	)
	_expect(
		service.get_handle_generation(replacement_handle)
		> service.get_handle_generation(old_handle),
		"A reused logical slot must receive a newer generation."
	)
	_expect(
		not service.is_handle_live(old_handle)
		and service.is_handle_live(replacement_handle),
		"Generation validation must distinguish stale and replacement handles."
	)
	service._physics_process(TEST_DELTA)
	_expect(
		service.get_dense_record_count() == 1
		and service.get_handle_at_stable_index(0) == replacement_handle,
		"Frame-end compaction must update indirection for the replacement handle."
	)
	service.prepare_for_runtime_teardown()
	service.free()


func _test_frozen_damage_source_storage_and_compaction() -> void:
	var service := RapidFireSimulationServiceScript.new()
	service.reserve_projectile_capacity(3)
	var launch_snapshot := DamageSourceSnapshot.create(
		6,
		17,
		901,
		44,
		&"frozen_ak_probe"
	)
	var first_handle := service.register_projectile(
		RapidFireSimulationServiceScript.Mode.DATA,
		RapidFireSimulationServiceScript.Profile.AK,
		Vector2.ZERO,
		Vector2.RIGHT,
		60.0,
		1.0,
		10,
		901,
		0,
		2,
		0,
		launch_snapshot
	)
	launch_snapshot.source_faction_id = CombatRelationService.PLAYER_ALLIED
	launch_snapshot.credit_peer_id = 99
	launch_snapshot.instigator_entity_id = 999
	launch_snapshot.event_source_id = 999
	launch_snapshot.source_type = &"mutated_after_registration"
	var frozen_snapshot := service.get_damage_source_snapshot(first_handle)
	_expect(
		frozen_snapshot != null
		and frozen_snapshot.source_faction_id == 6
		and frozen_snapshot.credit_peer_id == 17
		and frozen_snapshot.instigator_entity_id == 901
		and frozen_snapshot.event_source_id == 44
		and frozen_snapshot.source_type == &"frozen_ak_probe",
		"Registration must copy every DamageSourceSnapshot value instead of retaining the caller object."
	)
	_expect(
		service.assign_projectile_identity(first_handle, 7001)
		and service.get_damage_source_snapshot(first_handle).event_source_id == 7001,
		"Pending multiplayer identity assignment must rebind the frozen event source id."
	)

	var survivor_snapshot := DamageSourceSnapshot.create(
		9,
		23,
		902,
		7002,
		&"compacted_ak_probe"
	)
	var survivor_handle := service.register_projectile(
		RapidFireSimulationServiceScript.Mode.SHADOW,
		RapidFireSimulationServiceScript.Profile.AK,
		Vector2.ONE,
		Vector2.RIGHT,
		60.0,
		1.0,
		11,
		902,
		7002,
		2,
		1,
		survivor_snapshot
	)
	service.release_projectile(first_handle)
	service._physics_process(TEST_DELTA)
	var compacted_snapshot := service.get_damage_source_snapshot(survivor_handle)
	_expect(
		compacted_snapshot != null
		and compacted_snapshot.source_faction_id == 9
		and compacted_snapshot.credit_peer_id == 23
		and compacted_snapshot.instigator_entity_id == 902
		and compacted_snapshot.event_source_id == 7002
		and compacted_snapshot.source_type == &"compacted_ak_probe",
		"Stable compaction must move the complete packed damage-source record."
	)

	service.release_projectile(survivor_handle)
	service._physics_process(TEST_DELTA)
	var default_handle := service.register_projectile(
		RapidFireSimulationServiceScript.Mode.DATA,
		RapidFireSimulationServiceScript.Profile.AK,
		Vector2.ZERO,
		Vector2.RIGHT,
		60.0,
		1.0,
		12,
		903,
		7003,
		2,
		1
	)
	var default_snapshot := service.get_damage_source_snapshot(default_handle)
	_expect(
		default_snapshot != null
		and default_snapshot.source_faction_id
		== CombatRelationService.HOSTILE_WAVE
		and default_snapshot.credit_peer_id == 0
		and default_snapshot.instigator_entity_id == 903
		and default_snapshot.event_source_id == 7003
		and default_snapshot.source_type
		== RapidFireSimulationServiceScript.AK_SOURCE_TYPE,
		"An omitted AK snapshot must produce the explicit hostile fallback without leaking a recycled row."
	)
	var invalid_snapshot := DamageSourceSnapshot.create(99)
	_expect(
		service.register_projectile(
			RapidFireSimulationServiceScript.Mode.DATA,
			RapidFireSimulationServiceScript.Profile.AK,
			Vector2.ZERO,
			Vector2.RIGHT,
			60.0,
			1.0,
			12,
			904,
			7004,
			2,
			0,
			invalid_snapshot
		) == RapidFireSimulationServiceScript.INVALID_HANDLE,
		"An explicitly invalid damage-source snapshot must reject registration."
	)
	service.prepare_for_runtime_teardown()
	service.free()


func _test_stable_tombstone_compaction_and_completion_order() -> void:
	var service := RapidFireSimulationServiceScript.new()
	service.reserve_projectile_capacity(5)
	var projectile_ids := PackedInt64Array([50, 10, 40, 20, 30])
	var handles := PackedInt64Array()
	handles.resize(projectile_ids.size())
	for projectile_index in range(projectile_ids.size()):
		handles[projectile_index] = _register_test_projectile(
			service,
			RapidFireSimulationServiceScript.Mode.DATA,
			int(projectile_ids[projectile_index]),
			TEST_DELTA * 0.75
		)
	service.release_projectile(handles[1])
	service.release_projectile(handles[3])
	service._physics_process(TEST_DELTA)
	var expected_survivors := PackedInt64Array([50, 40, 30])
	var stable_after_compaction := service.get_dense_record_count() == 3
	for stable_index in range(expected_survivors.size()):
		var stable_handle := service.get_handle_at_stable_index(stable_index)
		stable_after_compaction = stable_after_compaction and (
			stable_handle > 0
			and service.get_projectile_id(stable_handle)
			== int(expected_survivors[stable_index])
		)
	_expect(
		stable_after_compaction,
		"Tombstone compaction must preserve registration order, not swap-remove."
	)

	await physics_frame
	service._physics_process(TEST_DELTA)
	var completion_order_is_stable := (
		service.get_completion_count() == expected_survivors.size()
	)
	var previous_spawn_sequence := 0
	for completion_index in range(service.get_completion_count()):
		completion_order_is_stable = completion_order_is_stable and (
			service.get_completion_projectile_id(completion_index)
			== int(expected_survivors[completion_index])
			and service.get_completion_spawn_sequence(completion_index)
			> previous_spawn_sequence
		)
		previous_spawn_sequence = service.get_completion_spawn_sequence(
			completion_index
		)
	_expect(
		completion_order_is_stable,
		"Lifetime completions must retain stable spawn order after compaction."
	)
	service.prepare_for_runtime_teardown()
	service.free()


func _test_shadow_difference_read_model_and_teardown() -> void:
	var service := RapidFireSimulationServiceScript.new()
	service.reserve_projectile_capacity(4)
	var shadow_handle := _register_test_projectile(
		service,
		RapidFireSimulationServiceScript.Mode.SHADOW,
		71,
		TEST_DELTA * 4.0,
		0
	)
	var data_handle := _register_test_projectile(
		service,
		RapidFireSimulationServiceScript.Mode.DATA,
		72,
		TEST_DELTA * 4.0,
		1
	)
	service._physics_process(TEST_DELTA)
	await physics_frame
	service._physics_process(TEST_DELTA)
	_expect(
		service.is_world_query_due(shadow_handle)
		and not service.is_world_query_due(data_handle)
		and service.get_world_step_index(shadow_handle) == 1
		and service.get_world_step_index(data_handle) == 1,
		"Step index 0 must select phase 0 and then advance to index 1."
	)
	await physics_frame
	service._physics_process(TEST_DELTA)
	_expect(
		not service.is_world_query_due(shadow_handle)
		and service.is_world_query_due(data_handle)
		and service.get_world_step_index(shadow_handle) == 0
		and service.get_world_step_index(data_handle) == 0,
		"Step index 1 must select phase 1 and wrap the interval to index 0."
	)
	var expected_position := service.get_position(shadow_handle)
	var expected_lifetime := service.get_remaining_lifetime(shadow_handle)
	_expect(
		service.record_shadow_observation(
			shadow_handle,
			expected_position + Vector2(0.25, -0.5),
			expected_lifetime + 0.125
		),
		"A live SHADOW slot must accept a scalar observation."
	)
	_expect(
		not service.record_shadow_observation(
			data_handle,
			service.get_position(data_handle),
			service.get_remaining_lifetime(data_handle)
		),
		"A DATA slot must reject shadow-only observations."
	)
	_expect(
		service.get_difference_count() == 1
		and service.get_difference_handle(0) == shadow_handle
		and service.get_difference_projectile_id(0) == 71
		and service.get_difference_position_delta(0).is_equal_approx(
			Vector2(0.25, -0.5)
		)
		and is_equal_approx(service.get_difference_lifetime_delta(0), 0.125),
		"Difference getters must expose immutable scalar deltas."
	)
	await physics_frame
	service._physics_process(TEST_DELTA)
	_expect(
		service.get_difference_count() == 0,
		"Frame-local SHADOW differences must expire before the next priority-4 simulation tick."
	)
	service.clear_difference_records()
	_expect(
		service.get_difference_count() == 0,
		"Difference records must clear without touching live slots."
	)

	service.prepare_for_runtime_teardown()
	service.prepare_for_runtime_teardown()
	var teardown_metrics := service.get_metrics()
	_expect(
		int(teardown_metrics["active_slots"]) == 0
		and int(teardown_metrics["dense_records"]) == 0
		and int(teardown_metrics["reserved_capacity"]) == 0
		and int(teardown_metrics["completion_records"]) == 0
		and int(teardown_metrics["difference_records"]) == 0
		and not bool(teardown_metrics["physics_processing"]),
		"Teardown must release every packed storage domain and stop physics."
	)
	_expect(
		int(teardown_metrics["teardown_count"]) == 1,
		"Kernel teardown must remain idempotent."
	)
	_expect(
		_register_test_projectile(
			service,
			RapidFireSimulationServiceScript.Mode.DATA,
			73,
			1.0
		) == RapidFireSimulationServiceScript.INVALID_HANDLE,
		"A torn-down kernel must reject all new registrations."
	)
	service.free()


func _test_fixed_seed_hundred_thousand_projectiles() -> void:
	var service := RapidFireSimulationServiceScript.new()
	_expect(
		service.reserve_projectile_capacity(LARGE_PROJECTILE_COUNT),
		"The pure kernel must preallocate the full 100k cohort."
	)
	var random := RandomNumberGenerator.new()
	random.seed = FIXED_SEED
	var handles := PackedInt64Array()
	handles.resize(LARGE_PROJECTILE_COUNT)
	var expected_first_completion_ids := PackedInt64Array()
	var expected_first_completion_positions := PackedVector2Array()
	expected_first_completion_ids.resize(LARGE_PROJECTILE_COUNT)
	expected_first_completion_positions.resize(LARGE_PROJECTILE_COUNT)
	var expected_first_completion_count := 0
	var registration_frame := Engine.get_physics_frames()
	var registration_failed := false
	var first_world_check_interval := 0
	var first_world_check_phase := 0
	for projectile_index in range(LARGE_PROJECTILE_COUNT):
		var direction: Vector2 = CARDINAL_DIRECTIONS[random.randi_range(0, 3)]
		var speed := float(random.randi_range(60, 300))
		var lifetime_ticks := random.randi_range(1, 4)
		var position := Vector2(
			float(projectile_index % 1000),
			float(projectile_index / 1000)
		)
		var projectile_id := projectile_index + 1
		var mode := (
			RapidFireSimulationServiceScript.Mode.SHADOW
			if projectile_index % 2 == 0
			else RapidFireSimulationServiceScript.Mode.DATA
		)
		var world_check_interval := 2
		var world_check_phase := random.randi_range(0, 1)
		var handle := service.register_projectile(
			mode,
			RapidFireSimulationServiceScript.Profile.AK,
			position,
			direction,
			speed,
			TEST_DELTA * (float(lifetime_ticks) - 0.25),
			10 + projectile_index % 7,
			1000 + projectile_index % 300,
			projectile_id,
			world_check_interval,
			world_check_phase
		)
		handles[projectile_index] = handle
		if handle <= 0:
			registration_failed = true
			break
		if projectile_index == 0:
			first_world_check_interval = world_check_interval
			first_world_check_phase = world_check_phase
		if lifetime_ticks == 1:
			expected_first_completion_ids[expected_first_completion_count] = (
				projectile_id
			)
			expected_first_completion_positions[expected_first_completion_count] = (
				position + direction * speed * TEST_DELTA
			)
			expected_first_completion_count += 1
	_expect(
		not registration_failed,
		"Every projectile in the fixed-seed 100k cohort must register."
	)
	if registration_failed:
		service.prepare_for_runtime_teardown()
		service.free()
		return

	var cohort_metrics := service.get_metrics()
	_expect(
		int(cohort_metrics["active_slots"]) == LARGE_PROJECTILE_COUNT
		and int(cohort_metrics["shadow_slots"]) == LARGE_PROJECTILE_COUNT / 2
		and int(cohort_metrics["data_slots"]) == LARGE_PROJECTILE_COUNT / 2
		and int(cohort_metrics["reserved_capacity"]) >= LARGE_PROJECTILE_COUNT,
		"The 100k cohort must occupy preallocated mixed SHADOW/DATA storage."
	)
	_expect(
		service.get_spawn_physics_frame(handles[0]) == registration_frame
		and service.get_slot_profile(handles[0])
		== RapidFireSimulationServiceScript.Profile.AK
		and service.get_damage(handles[0]) == 10
		and service.get_source_enemy_id(handles[0]) == 1000
		and service.get_world_check_interval(handles[0])
		== first_world_check_interval
		and service.get_world_check_phase(handles[0])
		== first_world_check_phase,
		"Packed metadata arrays must preserve the first AK record."
	)
	var first_position_before_same_frame := service.get_position(handles[0])
	service._physics_process(TEST_DELTA)
	_expect(
		service.get_completion_count() == 0
		and service.get_active_slot_count() == LARGE_PROJECTILE_COUNT
		and service.get_position(handles[0]).is_equal_approx(
			first_position_before_same_frame
		),
		"All 100k registrations must remain inert in their spawn frame."
	)

	await physics_frame
	service._physics_process(TEST_DELTA)
	_expect(
		service.get_completion_count() == expected_first_completion_count,
		"First active tick completion count must match the fixed-seed oracle."
	)
	var first_completion_order_valid := true
	for completion_index in range(service.get_completion_count()):
		if (
			service.get_completion_projectile_id(completion_index)
			!= int(expected_first_completion_ids[completion_index])
			or not service.get_completion_position(completion_index).is_equal_approx(
				expected_first_completion_positions[completion_index]
			)
			or service.is_handle_live(
				service.get_completion_handle(completion_index)
			)
		):
			first_completion_order_valid = false
			break
	_expect(
		first_completion_order_valid,
		"The fixed-seed first completion batch must preserve IDs, final steps, and stale handles."
	)

	var remaining_order_valid := true
	var previous_projectile_id := 0
	for stable_index in range(service.get_dense_record_count()):
		var stable_handle := service.get_handle_at_stable_index(stable_index)
		var projectile_id := service.get_projectile_id(stable_handle)
		if stable_handle <= 0 or projectile_id <= previous_projectile_id:
			remaining_order_valid = false
			break
		previous_projectile_id = projectile_id
	_expect(
		remaining_order_valid,
		"Stable compaction must keep the surviving 100k cohort in spawn order."
	)

	var total_completion_count := service.get_completion_count()
	for _active_tick in range(2, 5):
		await physics_frame
		service._physics_process(TEST_DELTA)
		var batch_order_valid := true
		var previous_batch_projectile_id := 0
		for completion_index in range(service.get_completion_count()):
			var projectile_id := service.get_completion_projectile_id(completion_index)
			if projectile_id <= previous_batch_projectile_id:
				batch_order_valid = false
				break
			previous_batch_projectile_id = projectile_id
		_expect(
			batch_order_valid,
			"Every fixed-seed completion batch must remain in spawn order."
		)
		total_completion_count += service.get_completion_count()
	_expect(
		total_completion_count == LARGE_PROJECTILE_COUNT
		and service.get_active_slot_count() == 0
		and service.get_dense_record_count() == 0
		and not service.is_physics_processing(),
		"Four active ticks must finish and compact the complete 100k cohort."
	)

	service.prepare_for_runtime_teardown()
	var teardown_metrics := service.get_metrics()
	_expect(
		int(teardown_metrics["reserved_capacity"]) == 0
		and int(teardown_metrics["active_slots"]) == 0
		and int(teardown_metrics["dense_records"]) == 0,
		"The 100k kernel must release all preallocated storage at teardown."
	)
	service.free()


func _register_test_projectile(
	service: RapidFireSimulationServiceScript,
	mode: int,
	projectile_id: int,
	lifetime: float,
	world_check_phase: int = 0
) -> int:
	return service.register_projectile(
		mode,
		RapidFireSimulationServiceScript.Profile.AK,
		Vector2(float(projectile_id), 0.0),
		Vector2.RIGHT,
		60.0,
		lifetime,
		12,
		500,
		projectile_id,
		2,
		world_check_phase
	)


func _finish() -> void:
	var result := {
		"status": "ok" if failures.is_empty() else "failed",
		"seed": FIXED_SEED,
		"projectile_count": LARGE_PROJECTILE_COUNT,
		"failures": failures.duplicate(),
	}
	print("RAPID_FIRE_SIMULATION_KERNEL_JSON %s" % JSON.stringify(result))
	if failures.is_empty():
		print("RAPID_FIRE_SIMULATION_SERVICE_KERNEL_SMOKE_TEST_OK")
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	quit(1)


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
