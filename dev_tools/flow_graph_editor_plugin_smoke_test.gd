extends SceneTree

const FLOW_GRAPH_EDITOR_PLUGIN := preload("res://addons/flow_graph_editor/flow_graph_editor_plugin.gd")
const FLOW_GRAPH_EDITOR_DOCK := preload("res://addons/flow_graph_editor/flow_graph_editor_dock.gd")

var failures: Array[String] = []


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	_expect(FLOW_GRAPH_EDITOR_PLUGIN != null, "Flow graph editor plugin script must preload.")
	_expect(FLOW_GRAPH_EDITOR_DOCK != null, "Flow graph editor dock script must preload.")

	var dock := FLOW_GRAPH_EDITOR_DOCK.new() as Control
	_expect(dock != null, "Flow graph editor dock must instantiate as Control.")
	if dock != null:
		root.add_child(dock)
		await process_frame
		_expect(dock.get_child_count() > 0, "Flow graph editor dock must build its UI.")
		dock.queue_free()
		await process_frame

	if failures.is_empty():
		print("FLOW_GRAPH_EDITOR_PLUGIN_SMOKE_TEST_OK")
		quit()
		return

	for failure in failures:
		push_error(failure)
	quit(1)


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
