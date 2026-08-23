extends SceneTree

const FIXTURE_SCENE := preload(
	"res://dev_tools/fixtures/enemy_gameplay_gateway_test_runtime.tscn"
)
const TEST_SESSION_SCRIPT := preload(
	"res://dev_tools/fixtures/enemy_gameplay_gateway_test_session.gd"
)
const RapidFireService := preload(
	"res://scene/combat/simulation/rapid_fire_simulation_service.gd"
)
const TEST_DELTA := 1.0 / 60.0

var failures: Array[String] = []


func _init() -> void:
	call_deferred(&"_run")


func _run() -> void:
	var runtime := FIXTURE_SCENE.instantiate() as EnemyGameplayGatewayTestRuntime
	_expect(runtime != null, "Completion consumer fixture must instantiate.")
	if runtime == null:
		_finish()
		return
	root.add_child(runtime)
	current_scene = runtime
	await process_frame
	var session := TEST_SESSION_SCRIPT.new() as EnemyGameplayGatewayTestSession
	runtime.attach_gameplay_session(session)
	var services := runtime.get_enemy_combat_services()
	var rapid_fire_service: RapidFireSimulationService = (
		services.get_rapid_fire_simulation_service()
		if services != null
		else null
	)
	var presenter: RapidProjectilePresenter = (
		services.get_rapid_projectile_presenter()
		if services != null
		else null
	)
	_expect(
		services != null
		and rapid_fire_service != null
		and presenter != null,
		"Fixture must expose the complete rapid-fire service tree."
	)
	if services == null or rapid_fire_service == null or presenter == null:
		runtime.queue_free()
		await process_frame
		_finish()
		return

	_expect(
		services.process_physics_priority == 6
		and rapid_fire_service.process_physics_priority == 4,
		"Completion consumer must run later in the same physics frame."
	)
	_expect(
		runtime.get_enemy_combat_services() == services
		and rapid_fire_service.get_reserved_capacity() >= 4096
		and presenter.is_bound_to(rapid_fire_service),
		"Runtime binding must cache services, reserve capacity, and bind presentation."
	)

	# Manual stepping isolates the transfer buffer from SceneTree scheduling.
	services.set_physics_process(false)
	rapid_fire_service.set_physics_process(false)
	var data_handle := _register_short_projectile(
		rapid_fire_service,
		RapidFireService.Mode.DATA,
		81_231
	)
	rapid_fire_service.set_physics_process(false)
	await physics_frame
	rapid_fire_service._physics_process(TEST_DELTA)
	rapid_fire_service.set_physics_process(false)
	_expect(
		rapid_fire_service.get_completion_count() == 1
		and rapid_fire_service.get_completion_handle(0) == data_handle
		and rapid_fire_service.get_completion_projectile_id(0) == 81_231
		and rapid_fire_service.get_completion_mode(0)
		== RapidFireService.Mode.DATA
		and rapid_fire_service.get_completion_profile(0)
		== RapidFireService.Profile.AK
		and rapid_fire_service.get_completion_direction(0).is_equal_approx(
			Vector2(0.6, 0.8)
		),
		"DATA completion must be self-contained after its handle becomes stale."
	)
	services._physics_process(0.0)
	_expect(
		rapid_fire_service.get_completion_count() == 0
		and session.data_projectile_finish_notifications.size() == 1,
		"Priority-6 consumption must notify and clear exactly once."
	)
	if session.data_projectile_finish_notifications.size() == 1:
		var notification := session.data_projectile_finish_notifications[0]
		_expect(
			int(notification["projectile_id"]) == 81_231
			and notification["service"] == rapid_fire_service
			and int(notification["handle"]) == data_handle,
			"Network finish notification must preserve the exact service/handle pair."
		)
	services._physics_process(0.0)
	_expect(
		session.data_projectile_finish_notifications.size() == 1,
		"An already-consumed completion must never be notified twice."
	)
	var service_metrics := services.get_metrics()
	_expect(
		int(service_metrics["completion_batches"]) == 1
		and int(service_metrics["consumed_completions"]) == 1
		and int(service_metrics["network_finish_notifications"]) == 1
		and int(service_metrics["hit_presentation_requests"]) == 0,
		"Lifetime completion must notify networking without requesting a hit visual."
	)

	var shadow_handle := _register_short_projectile(
		rapid_fire_service,
		RapidFireService.Mode.SHADOW,
		81_232
	)
	rapid_fire_service.set_physics_process(false)
	await physics_frame
	rapid_fire_service._physics_process(TEST_DELTA)
	rapid_fire_service.set_physics_process(false)
	_expect(
		rapid_fire_service.get_completion_count() == 1
		and rapid_fire_service.get_completion_handle(0) == shadow_handle
		and rapid_fire_service.get_completion_mode(0)
		== RapidFireService.Mode.SHADOW,
		"SHADOW completion must retain its mode in the transfer record."
	)
	services._physics_process(0.0)
	_expect(
		session.data_projectile_finish_notifications.size() == 1
		and rapid_fire_service.get_completion_count() == 0
		and int(services.get_metrics()["consumed_completions"]) == 1,
		"SHADOW completion must be cleared without networking or presentation."
	)

	var live_handle := rapid_fire_service.register_projectile(
		RapidFireService.Mode.DATA,
		RapidFireService.Profile.AK,
		Vector2(10_000.0, 10_000.0),
		Vector2.RIGHT,
		120.0,
		2.0,
		12,
		500,
		81_233,
		2,
		1
	)
	_expect(
		live_handle > RapidFireService.INVALID_HANDLE,
		"Teardown case must start with one live DATA handle."
	)
	runtime.prepare_for_scene_teardown()
	runtime.prepare_for_scene_teardown()
	_expect(
		rapid_fire_service.get_active_slot_count() == 0
		and rapid_fire_service.get_completion_count() == 0
		and not services.is_physics_processing()
		and not presenter.is_processing()
		and int(presenter.get_metrics()["active_hit_count"]) == 0,
		"Idempotent runtime teardown must clear handles, transfer records, and visuals."
	)

	runtime.detach_gameplay_session(session)
	session.free()
	runtime.queue_free()
	await process_frame
	await physics_frame
	_finish()


func _register_short_projectile(
	service: RapidFireSimulationService,
	mode: RapidFireService.Mode,
	projectile_id: int
) -> int:
	return service.register_projectile(
		mode,
		RapidFireService.Profile.AK,
		Vector2(10_000.0, 10_000.0),
		Vector2(0.6, 0.8),
		120.0,
		0.001,
		12,
		500,
		projectile_id,
		2,
		1
	)


func _finish() -> void:
	var result := {
		"status": "ok" if failures.is_empty() else "failed",
		"failures": failures.duplicate(),
	}
	print("RAPID_FIRE_COMPLETION_CONSUMER_JSON %s" % JSON.stringify(result))
	if failures.is_empty():
		print("RAPID_FIRE_COMPLETION_CONSUMER_SMOKE_TEST_OK")
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	quit(1)


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
