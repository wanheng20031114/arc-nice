extends Node


func _ready() -> void:
	_run.call_deferred()


func _run() -> void:
	# GameLoadCoordinator replaces current_scene. Keep this test owner alive
	# beside the production runtime until the disposable fixture has finished.
	get_tree().current_scene = null
	var scene := load("res://dev_tools/tower_multiplayer_density_fixture.tscn") as PackedScene
	var fixture := scene.instantiate()
	var result := {"exit_code": 2}
	fixture.set("result", result)
	get_tree().root.add_child(fixture)
	await fixture.tree_exited
	fixture = null
	scene = null
	for frame in 4:
		await get_tree().process_frame
	get_tree().root.get_node("PublicRoomLease").call("request_application_shutdown", int(result["exit_code"]))
