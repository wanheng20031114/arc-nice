extends SceneTree

const SystemScene := preload(
	"res://scene/combat/presentation/enemy_warning_presentation_system.tscn"
)
const SystemScript := preload(
	"res://scene/combat/presentation/enemy_warning_presentation_system.gd"
)
const EnemyCombatServicesScene := preload(
	"res://scene/combat/simulation/enemy_combat_services.tscn"
)

var failures: Array[String] = []


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	await _test_authored_services_mount()
	var system := SystemScene.instantiate() as SystemScript
	root.add_child(system)
	await process_frame
	_test_handles_updates_and_arbitration(system)
	_test_logical_capacity_independent_from_visual_capacity(system)
	_test_headless_and_teardown(system)
	if failures.is_empty():
		print("ENEMY_WARNING_PRESENTATION_SYSTEM_SMOKE_OK")
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	quit(1)


func _test_authored_services_mount() -> void:
	var services := EnemyCombatServicesScene.instantiate() as EnemyCombatServices
	root.add_child(services)
	await process_frame
	var warning_system := services.get_enemy_warning_presentation_system()
	_expect(
		warning_system != null
		and warning_system.get_parent() == services
		and warning_system is SystemScript,
		"EnemyCombatServices must statically author and expose the typed warning system."
	)
	services.prepare_for_runtime_teardown()
	services.queue_free()
	await process_frame


func _test_handles_updates_and_arbitration(system: SystemScript) -> void:
	var lightning := system.acquire_lightning_warning(101)
	var line := system.acquire_sniper_line(201)
	var reticle_low_owner := system.acquire_sniper_reticle(301, 9001)
	var reticle_high_owner := system.acquire_sniper_reticle(302, 9001)
	_expect(
		lightning > 0 and line > 0 and reticle_low_owner > 0 and reticle_high_owner > 0,
		"All three warning families must acquire logical handles."
	)
	_expect(
		system.update_lightning_warning(lightning, Vector2(10, 20), 0.4, 48.0)
		and system.update_sniper_line(line, Vector2.ZERO, Vector2(100, 20), 0.6)
		and system.update_sniper_reticle(reticle_low_owner, Vector2(50, 60), 0.7)
		and system.update_sniper_reticle(reticle_high_owner, Vector2(50, 60), 0.7 + 0.0000001),
		"Valid finite warning updates must succeed."
	)
	_expect(
		system.get_sniper_reticle_winner_handle(9001) == reticle_high_owner,
		"Approximately equal reticle progress must choose the larger stable owner_id."
	)
	_expect(
		system.update_sniper_reticle(reticle_low_owner, Vector2(50, 60), 0.9)
		and system.get_sniper_reticle_winner_handle(9001) == reticle_low_owner,
		"Higher progress must win before owner_id tie-breaking."
	)
	var old_generation := int(lightning >> SystemScript.HANDLE_SLOT_BITS)
	var old_slot := int(lightning & SystemScript.HANDLE_SLOT_MASK)
	_expect(system.release_warning(lightning), "Live warning release must succeed.")
	var reused := system.acquire_lightning_warning(102)
	_expect(
		int(reused & SystemScript.HANDLE_SLOT_MASK) == old_slot
		and int(reused >> SystemScript.HANDLE_SLOT_BITS) != old_generation
		and not system.is_handle_live(lightning)
		and not system.update_lightning_warning(lightning, Vector2.ZERO, 0.0, 48.0),
		"Reused slots must change generation and reject stale updates."
	)
	_expect(
		not system.update_sniper_line(reused, Vector2.ZERO, Vector2.ONE, 0.5),
		"A handle cannot update a different warning family."
	)


func _test_logical_capacity_independent_from_visual_capacity(system: SystemScript) -> void:
	var requested := SystemScript.SNIPER_RETICLE_VISUAL_CAPACITY + 257
	var acquired := 0
	for index in range(requested):
		var handle := system.acquire_sniper_reticle(10_000 + index, 20_000 + index)
		if handle <= 0:
			continue
		acquired += 1
		system.update_sniper_reticle(handle, Vector2(index % 80, index / 80), 0.5)
	var metrics := system.get_metrics()
	_expect(
		acquired == requested
		and int(metrics["logical_capacity"]) > SystemScript.SNIPER_RETICLE_VISUAL_CAPACITY
		and int(metrics["acquisition_rejections"]) == 0,
		"Critical logical handles must grow beyond fixed visual capacity without rejection."
	)


func _test_headless_and_teardown(system: SystemScript) -> void:
	_expect(system.flush_presenter() == 0, "Headless flush must not write visual instances.")
	var metrics := system.get_metrics()
	_expect(
		bool(metrics["headless_disabled"])
		and int(metrics["allocated_lightning_instances"]) == 0
		and int(metrics["allocated_sniper_line_instances"]) == 0
		and int(metrics["allocated_sniper_reticle_instances"]) == 0
		and int(metrics["visual_writes"]) == 0,
		"Headless mode must retain logic while allocating and updating zero instances."
	)
	system.prepare_for_runtime_teardown()
	system.prepare_for_runtime_teardown()
	metrics = system.get_metrics()
	_expect(
		bool(metrics["teardown_prepared"])
		and int(metrics["teardown_count"]) == 1
		and int(metrics["live_warnings"]) == 0,
		"Teardown must be idempotent and clear every logical warning."
	)
	system.queue_free()


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
