extends RefCounted
class_name ContentValidationContext

enum VisitState {
	ENTERED,
	COMPLETED,
	ACTIVE,
}

var errors := PackedStringArray()

var _active_paths_by_resource_id: Dictionary = {}
var _completed_resource_ids: Dictionary = {}


## 共享访问账本让递归校验既能定位循环，也不会重复报告同一资源。
func begin_resource(resource: Resource, path: String) -> int:
	var resource_id := resource.get_instance_id()
	if _active_paths_by_resource_id.has(resource_id):
		return VisitState.ACTIVE
	if _completed_resource_ids.has(resource_id):
		return VisitState.COMPLETED
	_active_paths_by_resource_id[resource_id] = path
	return VisitState.ENTERED


func complete_resource(resource: Resource) -> void:
	var resource_id := resource.get_instance_id()
	_active_paths_by_resource_id.erase(resource_id)
	_completed_resource_ids[resource_id] = true


func get_active_path(resource: Resource) -> String:
	return String(_active_paths_by_resource_id.get(resource.get_instance_id(), ""))


func add_error(path: String, message: String) -> void:
	errors.append("%s：%s" % [path, message])


static func child_path(parent_path: String, child_name: String) -> String:
	return "%s.%s" % [parent_path, child_name]


static func describe_resource(resource: Resource, fallback: String) -> String:
	if resource != null and not resource.resource_path.is_empty():
		return resource.resource_path
	return fallback
