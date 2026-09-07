extends RefCounted

## A threaded request owns a native loader token until its result is retrieved.
## Keep this ledger independent of scene/script graphs so canceled scene owners
## can disappear while application shutdown still waits for their native work.
static var _pending_requests: Dictionary[String, int] = {}
static var _shutting_down := false
static var _headless_queue: Array[Dictionary] = []
static var _headless_queued_counts: Dictionary[String, int] = {}
static var _headless_failed_counts: Dictionary[String, int] = {}
static var _headless_active_path := ""


static func request(
	path: String,
	type_hint: String = "",
	use_sub_threads: bool = false,
	cache_mode: ResourceLoader.CacheMode = ResourceLoader.CACHE_MODE_REUSE
) -> Error:
	if _shutting_down:
		return ERR_UNAVAILABLE
	var headless := DisplayServer.get_name() == "headless"
	if headless:
		_advance_headless_queue()
		var native_status := ResourceLoader.load_threaded_get_status(path)
		if (
			_headless_queued_counts.has(path)
			or (not _headless_active_path.is_empty() and native_status == ResourceLoader.THREAD_LOAD_INVALID_RESOURCE)
		):
			if not ResourceLoader.exists(path, type_hint):
				return ERR_CANT_OPEN
			_headless_queue.append({"path": path, "type_hint": type_hint, "cache_mode": cache_mode})
			_headless_queued_counts[path] = _headless_queued_counts.get(path, 0) + 1
			_pending_requests[path] = _pending_requests.get(path, 0) + 1
			return OK
	var error := ResourceLoader.load_threaded_request(path, type_hint, use_sub_threads and not headless, cache_mode)
	if error == OK:
		_pending_requests[path] = _pending_requests.get(path, 0) + 1
		if headless and _headless_active_path.is_empty():
			_headless_active_path = path
	return error


static func get_status(path: String, progress: Array = []) -> ResourceLoader.ThreadLoadStatus:
	if DisplayServer.get_name() == "headless":
		_advance_headless_queue()
		if _headless_queued_counts.has(path):
			progress.assign([0.0])
			return ResourceLoader.THREAD_LOAD_IN_PROGRESS
		if (
			_headless_failed_counts.has(path)
			and ResourceLoader.load_threaded_get_status(path) == ResourceLoader.THREAD_LOAD_INVALID_RESOURCE
		):
			return ResourceLoader.THREAD_LOAD_FAILED
	return ResourceLoader.load_threaded_get_status(path, progress)


static func claim(path: String) -> Resource:
	# Some existing callers intentionally use native get as a blocking first-use
	# barrier (Player's first Sakura rocket). A queued path must reach the native
	# loader first. Borrow a separate token to wait for the active task, so its
	# original owner still receives the same result with its claim intact.
	while _headless_queued_counts.has(path):
		_advance_headless_queue()
		if not _headless_queued_counts.has(path):
			break
		var blocker := _headless_active_path
		var wait_error := ResourceLoader.load_threaded_request(
			blocker, "", false, ResourceLoader.CACHE_MODE_REUSE
		)
		if wait_error != OK:
			push_error("Cannot retain active native loading task for blocking claim: %s" % blocker)
			return null
		ResourceLoader.load_threaded_get(blocker)
	var resource: Resource
	if (
		_headless_failed_counts.has(path)
		and ResourceLoader.load_threaded_get_status(path) == ResourceLoader.THREAD_LOAD_INVALID_RESOURCE
	):
		var failed_remaining: int = _headless_failed_counts[path] - 1
		if failed_remaining > 0:
			_headless_failed_counts[path] = failed_remaining
		else:
			_headless_failed_counts.erase(path)
	else:
		resource = ResourceLoader.load_threaded_get(path)
	var remaining: int = _pending_requests.get(path, 0) - 1
	if remaining > 0:
		_pending_requests[path] = remaining
	else:
		_pending_requests.erase(path)
	return resource


## Dummy's texture/mesh RID owners are not thread-safe in Godot 4.6.2. Keep
## both top-level requests and their dependencies on one loader worker at a
## time. Real renderers bypass this queue and retain the caller's parallelism.
## Tokens remain owned by ResourceLoader until claim(); no resource cache or
## game graph is retained in this helper. Canceled owners can leave the queue
## idle until another consumer polls it or the application drains it on exit.
static func _advance_headless_queue() -> void:
	if not _headless_active_path.is_empty():
		if ResourceLoader.load_threaded_get_status(_headless_active_path) == ResourceLoader.THREAD_LOAD_IN_PROGRESS:
			return
		_headless_active_path = ""
	while not _headless_queue.is_empty():
		var queued: Dictionary = _headless_queue.pop_front()
		var path: String = queued["path"]
		var count: int = _headless_queued_counts[path] - 1
		if count > 0:
			_headless_queued_counts[path] = count
		else:
			_headless_queued_counts.erase(path)
		var error := ResourceLoader.load_threaded_request(path, queued["type_hint"], false, queued["cache_mode"])
		if error != OK:
			_headless_failed_counts[path] = _headless_failed_counts.get(path, 0) + 1
			continue
		_headless_active_path = path
		if ResourceLoader.load_threaded_get_status(path) == ResourceLoader.THREAD_LOAD_IN_PROGRESS:
			return
		_headless_active_path = ""


static func begin_shutdown() -> void:
	_shutting_down = true


static func is_shutting_down() -> bool:
	return _shutting_down


static func get_pending_request_count() -> int:
	var count := 0
	for references in _pending_requests.values():
		count += int(references)
	return count


## Poll to completion while the SceneTree and script language remain alive.
## Never call get on IN_PROGRESS: that would block the UI/network release loop.
static func drain_pending_requests(tree: SceneTree) -> void:
	var completed_resources: Array[Resource] = []
	while not _pending_requests.is_empty():
		for path: String in _pending_requests.keys():
			var status := get_status(path)
			match status:
				ResourceLoader.THREAD_LOAD_IN_PROGRESS:
					continue
				ResourceLoader.THREAD_LOAD_LOADED, ResourceLoader.THREAD_LOAD_FAILED:
					var resource := claim(path)
					if resource != null:
						completed_resources.append(resource)
				ResourceLoader.THREAD_LOAD_INVALID_RESOURCE:
					# A native consumer may already have claimed a shared request.
					_pending_requests.erase(path)
		if not _pending_requests.is_empty():
			await tree.process_frame
	# Deferred rendering initialization must complete before these last references
	# disappear and before the engine destroys its script/rendering services.
	await tree.process_frame
	completed_resources.clear()
	await tree.process_frame
