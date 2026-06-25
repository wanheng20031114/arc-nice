@tool
extends EditorPlugin

const FlowGraphEditorDock := preload("res://addons/flow_graph_editor/flow_graph_editor_dock.gd")

var _dock: Control


func _enter_tree() -> void:
	_dock = FlowGraphEditorDock.new()
	_dock.name = "Flow Graph"
	if _dock.has_method("setup"):
		_dock.call("setup", get_editor_interface())
	add_control_to_dock(DOCK_SLOT_RIGHT_UL, _dock)


func _exit_tree() -> void:
	if _dock != null:
		remove_control_from_docks(_dock)
		_dock.queue_free()
		_dock = null
