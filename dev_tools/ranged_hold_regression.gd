extends SceneTree


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	var scene := load("res://dev_tools/ranged_hold_fixture.tscn") as PackedScene
	var fixture := scene.instantiate()
	var result := {"exit_code": 2}
	fixture.set("result", result)
	root.add_child(fixture)
	await fixture.tree_exited
	fixture = null
	scene = null
	for frame in 4:
		await process_frame
	root.get_node("PublicRoomLease").call("request_application_shutdown", int(result["exit_code"]))
