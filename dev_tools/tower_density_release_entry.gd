extends Node

## Release templates ignore --script/--scene. An isolated test project selects
## this native main scene, which starts the same disposable density fixture.
func _ready() -> void:
	_run.call_deferred()


func _run() -> void:
	var fixture_script := load("res://dev_tools/tower_density_fixture.gd")
	var fixture: Node = fixture_script.new()
	var result := {"exit_code": 2}
	fixture.set("result", result)
	get_tree().root.add_child(fixture)
	await fixture.tree_exited
	fixture = null
	fixture_script = null
	for frame in 4:
		await get_tree().process_frame
	get_tree().root.get_node("PublicRoomLease").call("request_application_shutdown", int(result["exit_code"]))
