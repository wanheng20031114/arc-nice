extends SceneTree

const LIFETIME := preload("res://scene/loading/threaded_resource_lifetime.gd")
const CACHED_TEXTURE := "res://resources/texture/materials/wood.png"
const QUEUED_TEXTURE := "res://resources/texture/materials/water_bottle.png"
const ABANDONED_SCENE := "res://scene/encyclopedia/encyclopedia_screen.tscn"
var _failures: Array[String] = []
var _measure_frames := false
var _drain_frames := 0
var _last_frame_usec := 0
var _maximum_frame_gap_ms := 0.0


func _initialize() -> void:
	_run.call_deferred()


func _process(_delta: float) -> bool:
	if _measure_frames:
		var now := Time.get_ticks_usec()
		if _last_frame_usec > 0:
			_maximum_frame_gap_ms = maxf(_maximum_frame_gap_ms, float(now - _last_frame_usec) / 1000.0)
		_last_frame_usec = now
		_drain_frames += 1
	return false


func _run() -> void:
	_check(LIFETIME.request(CACHED_TEXTURE) == OK, "First request succeeds")
	_check(LIFETIME.request(CACHED_TEXTURE) == OK, "Repeated request succeeds")
	_check(LIFETIME.get_pending_request_count() == 2, "Every successful request owns one claim")
	while LIFETIME.get_status(CACHED_TEXTURE) == ResourceLoader.THREAD_LOAD_IN_PROGRESS:
		await process_frame
	var first := LIFETIME.claim(CACHED_TEXTURE)
	_check(LIFETIME.get_pending_request_count() == 1, "One claim cannot release another request")
	var second := LIFETIME.claim(CACHED_TEXTURE)
	_check(first != null and first == second, "Repeated native requests share the cached resource")
	_check(LIFETIME.get_pending_request_count() == 0, "Balanced claims release the ledger")
	first = null
	second = null
	# A previous scene or a native consumer can have started the shared token.
	_check(ResourceLoader.load_threaded_request(CACHED_TEXTURE) == OK, "External request succeeds")
	while ResourceLoader.load_threaded_get_status(CACHED_TEXTURE) == ResourceLoader.THREAD_LOAD_IN_PROGRESS:
		await process_frame
	var adopted := LIFETIME.claim(CACHED_TEXTURE)
	_check(adopted != null and LIFETIME.get_pending_request_count() == 0,
		"Claiming an existing native token does not invent a ledger reference")
	adopted = null
	# Failed requests still own native tokens, and must be claimed exactly once.
	var invalid_path := "user://threaded_lifetime_invalid_%d.tres" % OS.get_process_id()
	var invalid_file := FileAccess.open(invalid_path, FileAccess.WRITE)
	invalid_file.store_string("invalid resource header\n")
	invalid_file.close()
	print("EXPECTED_RESOURCE_LOAD_FAILURE_BEGIN")
	_check(LIFETIME.request(invalid_path, "Resource") == OK, "Failing request is accepted asynchronously")
	while LIFETIME.get_status(invalid_path) == ResourceLoader.THREAD_LOAD_IN_PROGRESS:
		await process_frame
	_check(LIFETIME.get_status(invalid_path) == ResourceLoader.THREAD_LOAD_FAILED,
		"Invalid payload reaches a failed terminal state")
	_check(LIFETIME.claim(invalid_path) == null, "Failed result is empty")
	_check(LIFETIME.get_pending_request_count() == 0, "Failed claim releases its ledger reference")
	print("EXPECTED_RESOURCE_LOAD_FAILURE_END")
	DirAccess.remove_absolute(ProjectSettings.globalize_path(invalid_path))
	# Canceling a scene does not cancel its native request. A replacement owner
	# may request and consume the same path while the canceled claim remains.
	_check(LIFETIME.request(CACHED_TEXTURE) == OK, "Canceled owner starts a request")
	_check(LIFETIME.request(CACHED_TEXTURE) == OK, "Replacement owner can request the same path")
	while ResourceLoader.load_threaded_get_status(CACHED_TEXTURE) == ResourceLoader.THREAD_LOAD_IN_PROGRESS:
		await process_frame
	var replacement := LIFETIME.claim(CACHED_TEXTURE)
	_check(replacement != null and LIFETIME.get_pending_request_count() == 1,
		"Replacement claim preserves the canceled owner's remaining token")
	replacement = null
	_check(LIFETIME.request(ABANDONED_SCENE, "PackedScene") == OK, "Abandoned-owner request starts")
	_check(LIFETIME.request(QUEUED_TEXTURE) == OK, "Another path can queue behind the cold scene")
	_check(LIFETIME.request(QUEUED_TEXTURE) == OK, "Queued paths preserve duplicate requests")
	if DisplayServer.get_name() == "headless":
		var progress: Array = []
		_check(LIFETIME.get_status(QUEUED_TEXTURE, progress) == ResourceLoader.THREAD_LOAD_IN_PROGRESS
			and progress == [0.0], "Queued headless request reports in-progress without blocking")
		_check(ResourceLoader.load_threaded_get_status(QUEUED_TEXTURE) == ResourceLoader.THREAD_LOAD_INVALID_RESOURCE,
			"Only one top-level headless native load starts at a time")
	_check(LIFETIME.get_pending_request_count() == 4, "Queue and native ownership share an exact ledger")
	LIFETIME.begin_shutdown()
	_check(LIFETIME.request(CACHED_TEXTURE) == ERR_UNAVAILABLE, "Shutdown rejects new work")
	_measure_frames = true
	var drain_started := Time.get_ticks_msec()
	await LIFETIME.drain_pending_requests(self)
	_measure_frames = false
	_check(_drain_frames > 0, "Shutdown keeps the main loop responsive while draining")
	_check(LIFETIME.get_pending_request_count() == 0, "Shutdown consumes abandoned native tokens")
	_check(ResourceLoader.load_threaded_get_status(CACHED_TEXTURE) == ResourceLoader.THREAD_LOAD_INVALID_RESOURCE,
		"Shutdown consumes the canceled claim after a replacement owner finished")
	_check(ResourceLoader.load_threaded_get_status(ABANDONED_SCENE) == ResourceLoader.THREAD_LOAD_INVALID_RESOURCE,
		"Abandoned result was retrieved, not just allowed to finish")
	_check(ResourceLoader.load_threaded_get_status(QUEUED_TEXTURE) == ResourceLoader.THREAD_LOAD_INVALID_RESOURCE,
		"Shutdown consumes both queued native tokens")
	print("THREADED_RESOURCE_LIFETIME ", JSON.stringify({"failures": _failures,
		"drain_ms": Time.get_ticks_msec() - drain_started, "responsive_frames": _drain_frames,
		"maximum_frame_gap_ms": _maximum_frame_gap_ms}))
	quit(0 if _failures.is_empty() else 1)


func _check(condition: bool, message: String) -> void:
	if not condition:
		_failures.append(message)
		push_error(message)
