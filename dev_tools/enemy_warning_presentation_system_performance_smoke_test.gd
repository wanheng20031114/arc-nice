extends SceneTree

const SystemScript := preload(
	"res://scene/combat/presentation/enemy_warning_presentation_system.gd"
)
const WARNING_COUNT := 20_000


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	var system := SystemScript.new()
	var handles := PackedInt64Array()
	handles.resize(WARNING_COUNT)
	var started_usec := Time.get_ticks_usec()
	for index in range(WARNING_COUNT):
		var handle := system.acquire_sniper_reticle(index + 1, index / 3 + 1)
		handles[index] = handle
		system.update_sniper_reticle(
			handle,
			Vector2(index % 256, index / 256),
			float(index % 1000) / 999.0
		)
	var elapsed_usec := Time.get_ticks_usec() - started_usec
	var all_live := true
	for index in range(0, WARNING_COUNT, 997):
		all_live = all_live and system.is_handle_live(handles[index])
	var metrics := system.get_metrics()
	var passed := (
		all_live
		and int(metrics["live_warnings"]) == WARNING_COUNT
		and int(metrics["logical_capacity"]) >= WARNING_COUNT
		and int(metrics["acquisition_rejections"]) == 0
		and elapsed_usec < 5_000_000
	)
	system.prepare_for_runtime_teardown()
	system.free()
	if passed:
		print("ENEMY_WARNING_PRESENTATION_SYSTEM_PERFORMANCE_SMOKE_OK usec=", elapsed_usec)
		quit(0)
		return
	push_error("Warning handle growth/update performance invariant failed: %s usec" % elapsed_usec)
	quit(1)
