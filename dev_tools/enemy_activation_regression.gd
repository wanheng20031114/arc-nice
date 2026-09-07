extends SceneTree


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	var script := load("res://dev_tools/enemy_activation_fixture.gd")
	var fixture: Node = script.new()
	var result := {"exit_code": 2}
	fixture.set("result", result)
	root.add_child(fixture)
	await fixture.tree_exited
	fixture = null
	script = null
	for frame in 4:
		await process_frame
	root.get_node("PublicRoomLease").call("request_application_shutdown", int(result["exit_code"]))
