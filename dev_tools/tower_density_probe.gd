extends SceneTree

## Keep gameplay types on a disposable Node, not on the engine's main loop.
## This runner must remain free of gameplay preloads and class annotations.
func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	var fixture_script := load("res://dev_tools/tower_density_fixture.gd")
	var fixture: Node = fixture_script.new()
	var result := {"exit_code": 2}
	fixture.set("result", result)
	root.add_child(fixture)
	await fixture.tree_exited
	fixture = null
	fixture_script = null
	for frame in 4:
		await process_frame
	root.get_node("PublicRoomLease").call("request_application_shutdown", int(result["exit_code"]))
