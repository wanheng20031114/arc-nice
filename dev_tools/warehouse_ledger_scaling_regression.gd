extends SceneTree

func _initialize() -> void:
	_run.call_deferred()

func _run() -> void:
	var fixture_script := load("res://dev_tools/warehouse_ledger_scaling_fixture.gd")
	var fixture: Node = fixture_script.new()
	var result := {"exit_code": 2}
	fixture.set("result", result)
	root.add_child(fixture)
	await fixture.tree_exited
	fixture = null
	fixture_script = null
	for frame in 4:
		await process_frame
	quit(int(result["exit_code"]))
