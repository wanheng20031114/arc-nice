extends SceneTree

## Used by audit_native_resources.py in either Godot project. Only native load
## runs: scripts (including SceneTree test runners) are never instantiated.
var _manifest_path := ""
var _result_path := ""
var _resources: Array[Resource] = []


func _initialize() -> void:
	for argument in OS.get_cmdline_user_args():
		if argument.begins_with("--manifest="):
			_manifest_path = argument.trim_prefix("--manifest=")
		elif argument.begins_with("--result="):
			_result_path = argument.trim_prefix("--result=")
	_run.call_deferred()


func _run() -> void:
	Engine.max_fps = 120
	var manifest: Variant = JSON.parse_string(FileAccess.get_file_as_string(_manifest_path))
	if not manifest is Array:
		push_error("Native resource audit requires an array manifest")
		quit(2)
		return
	var results: Array[Dictionary] = []
	var failures := 0
	for path: String in manifest:
		print("NATIVE_RESOURCE_BEGIN ", path)
		var started := Time.get_ticks_usec()
		var resource := ResourceLoader.load(path, "", ResourceLoader.CACHE_MODE_REUSE)
		var row := {
			"path": path,
			"loaded": resource != null,
			"class": resource.get_class() if resource != null else "",
			"elapsed_usec": Time.get_ticks_usec() - started,
		}
		results.append(row)
		if resource != null:
			_resources.append(resource)
		else:
			failures += 1
		print("NATIVE_RESOURCE_END ", JSON.stringify(row))
		# Service the native rendering queue while its resource owners still live.
		# Loading itself remains synchronous, independent from the game's prewarm.
		if results.size() % 32 == 0:
			await process_frame
	var result := {"results": results, "null_resources": failures}
	var file := FileAccess.open(_result_path, FileAccess.WRITE)
	if file == null:
		push_error("Native resource audit cannot write its result")
		quit(2)
		return
	file.store_string(JSON.stringify(result, "\t"))
	file.close()
	_resources.clear()
	for frame in 4:
		await process_frame
	print("NATIVE_RESOURCE_AUDIT count=", results.size(), " null=", failures)
	if root.has_node("PublicRoomLease"):
		root.get_node("PublicRoomLease").call("request_application_shutdown", 0 if failures == 0 else 1)
	else:
		quit(0 if failures == 0 else 1)
